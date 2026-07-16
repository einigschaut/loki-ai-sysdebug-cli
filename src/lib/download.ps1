# lib/download.ps1 -- verified file acquisition (security core, CLAUDE.md section 5, ADR-0011/ADR-0012).
# The ONE way Loki brings a remote file onto the stick. Two consumers: lib/models.ps1 (GGUF data) and
# lib/engine.ps1 (the llama.cpp engine archive, which is CODE we later execute) -- so this lives in lib/
# per CLAUDE.md section 2 (shared logic has exactly one home), not inside either caller.
# The rules are hard, because this is the supply-chain surface:
#   * HTTPS only -- a non-https Url is refused (no plaintext / downgrade).
#   * every fetch is verified against a SHA256 pinned in a manifest BEFORE it is moved into place;
#     a mismatch or a download error deletes the partial -- an unverified download is never kept.
#   * this module downloads and verifies only -- it NEVER executes or expands what it fetched.
# Contract:
#   Get-LokiFileHashState -Path <file> -ExpectedSha256 <hex> -> 'match' | 'differ' | 'unreadable' | 'missing'
#       (never throws; case-insensitive compare). The tri-state primitive -- use it when you must REPORT a fact.
#   Test-LokiFileHash -Path <file> -ExpectedSha256 <hex> -> [bool]  (missing file -> $false; case-insensitive).
#       "is this PROVEN to be the pinned bytes?" -- use it when you must DECIDE.
#   Get-LokiHttpFile -Url <https> -OutFile <path>  -- the raw streaming download (the mock seam; tests replace it).
#   Invoke-LokiVerifiedDownload -Url -ExpectedSha256 -DestPath [-StagingDir <dir>] -> [hashtable]{ Ok; Reason; [Skipped] }
#       not-https -> Ok=$false; already-present+verified -> Ok=$true Skipped; otherwise download to a .part file,
#       verify, then move into place; hash-mismatch or download error -> the .part is deleted and Ok=$false.
#       -StagingDir puts the .part somewhere other than next to its destination (see the note there).
# ASCII-only file -> no BOM (CLAUDE.md section 1).
Set-StrictMode -Version Latest

function Get-LokiFileHashState {
    <#
        Tri-state, because a bool cannot say "I do not know".

        "the bytes differ" and "I could not read the bytes" are different facts, and the difference is the difference
        between telling an operator their stick was TAMPERED WITH and telling them their stick is FAILING. Collapsing
        both into $false is exactly right for the download path (anything not proven is refused) and exactly wrong for
        the reporting path (lib/integrity.ps1), whose entire job is to say what is actually true.

        Unreadable is not an exotic case here -- Loki lives on a USB stick, so it is the medium's own failure mode:
        a bad sector, an AV/EDR scanner holding a brief exclusive handle, a deny-read ACE on an NTFS-formatted stick,
        an unhydratable cloud placeholder. (A RUNNING executable is NOT one of these: Windows maps images with
        share-read, so llama-server.exe hashes fine while it is running -- measured, not assumed.)
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )
    # -PathType Leaf: a DIRECTORY carrying the file's name is not a file we failed to read, it is a file that is not
    # there. (Get-FileHash on a directory throws, so without this it would report 'unreadable'.)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'missing' }
    # Never let this exception escape into a caller that is trying to decide whether something is trustworthy:
    # Get-FileHash throws on a locked file, and callers run with $ErrorActionPreference='Stop', so a throw here would
    # blow straight past their fail-closed handling.
    try { $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash }
    catch { return 'unreadable' }
    if ([string]$actual -ieq [string]$ExpectedSha256) { return 'match' }
    return 'differ'
}

function Test-LokiFileHash {
    # The fail-closed question, unchanged: is this file PROVEN to be the pinned bytes? Anything else -- absent,
    # unreadable, different -- is $false. Every acquisition decision in this module rests on this and must keep
    # treating "could not tell" as "no".
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )
    return ((Get-LokiFileHashState -Path $Path -ExpectedSha256 $ExpectedSha256) -eq 'match')
}

function Get-LokiHttpFile {
    # The raw streaming download -- isolated so tests can Mock it (no real network in unit tests). WebClient.DownloadFile
    # streams to disk (no whole-file buffering) and uses the system proxy + certificate store, so a corporate
    # TLS-inspection proxy with its CA trusted (domain machine) works transparently. TLS 1.2 forced for old defaults.
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutFile
    )
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $wc = New-Object System.Net.WebClient
    # Give the default proxy the caller's credentials so an AUTHENTICATED corporate proxy (HTTP 407) works; harmless
    # when there is no proxy or a transparent one.
    if ($null -ne $wc.Proxy) { $wc.Proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials }
    try { $wc.DownloadFile($Url, $OutFile) } finally { $wc.Dispose() }
}

function Invoke-LokiVerifiedDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [Parameter(Mandatory = $true)][string]$DestPath,
        [string]$StagingDir
    )
    # Set INSIDE the function (function-scoped, so it neither leaks to the caller nor depends on them): Copy-Item /
    # Move-Item / Remove-Item failures are NON-terminating by default, so without this the catch blocks below never
    # fire and this function reports Ok=$true 'verified' while the stale bytes are still on disk. Proven, not
    # theoretical -- adversarial review reproduced exactly that with a locked destination.
    $ErrorActionPreference = 'Stop'

    # HTTPS only -- never fetch over plaintext (integrity + no downgrade).
    if ($Url -notmatch '^https://') { return @{ Ok = $false; Reason = 'not-https' } }
    # Idempotent / resumable across runs: an already-present, already-verified file is a no-op.
    if (Test-LokiFileHash -Path $DestPath -ExpectedSha256 $ExpectedSha256) { return @{ Ok = $true; Reason = 'already-verified'; Skipped = $true } }

    # Past this point the destination is absent or does NOT match the pin. Drop a non-matching file NOW rather than
    # only on the success path: otherwise a failed download leaves the stale/tampered file sitting there, and
    # "an unverified download is never kept" would be false the moment the network drops.
    # No -ErrorAction SilentlyContinue here: if the stale file CANNOT be removed we must say so, not carry on and
    # later report success over bytes we never replaced.
    if (Test-Path -LiteralPath $DestPath) {
        try { Remove-Item -LiteralPath $DestPath -Force }
        catch { return @{ Ok = $false; Reason = 'dest-locked'; Error = $_.Exception.Message } }
    }

    $dir = Split-Path -Parent $DestPath
    if (-not [string]::IsNullOrEmpty($dir) -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    # Where the partial download lives, and why it is a parameter. When the destination directory is a VERIFIED one,
    # a `.part` must not be dropped into it: lib/integrity.ps1 reconciles engine-offline\ against the pinned archive,
    # so a partial left behind by a HARD interrupt (Ctrl-C on a slow 200 MB download -- the catch blocks below handle
    # every ordinary failure) is correctly seen as "a file the pinned build does not contain" and reported as
    # tampering. The stick would be accused of being hostile because setup littered in it. Staging elsewhere keeps the
    # verified directory a place where only verified bytes ever exist.
    # Default = the old behaviour, deliberately: the model tiers download into models\, which nothing reconciles, and
    # inventing a staging directory for them would be ceremony without a defect to fix.
    # Callers pass a SIBLING on the same volume, so the commit below stays a rename. A staging directory on another
    # volume would silently turn Move-Item into a copy -- slow, and no longer atomic.
    $tmp = $DestPath + '.part'
    if (-not [string]::IsNullOrEmpty($StagingDir)) {
        if (-not (Test-Path -LiteralPath $StagingDir)) { New-Item -ItemType Directory -Force -Path $StagingDir | Out-Null }
        $tmp = Join-Path $StagingDir ((Split-Path -Leaf $DestPath) + '.part')
    }
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }

    try {
        Get-LokiHttpFile -Url $Url -OutFile $tmp
    }
    catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        return @{ Ok = $false; Reason = 'download-failed'; Error = $_.Exception.Message }
    }

    if (-not (Test-LokiFileHash -Path $tmp -ExpectedSha256 $ExpectedSha256)) {
        # A freshly downloaded file that fails verification is NEVER moved into place -- delete the partial.
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return @{ Ok = $false; Reason = 'hash-mismatch' }
    }

    # Verified -> move into place. This move is the ONLY thing that makes the file real, so a failure here must be
    # reported as a failure: returning 'verified' while the move silently failed is the worst possible lie this
    # module could tell.
    try {
        if (Test-Path -LiteralPath $DestPath) { Remove-Item -LiteralPath $DestPath -Force }
        Move-Item -LiteralPath $tmp -Destination $DestPath -Force
    }
    catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return @{ Ok = $false; Reason = 'move-failed'; Error = $_.Exception.Message }
    }
    return @{ Ok = $true; Reason = 'verified' }
}
