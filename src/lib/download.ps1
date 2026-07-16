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
#   Test-LokiFileHash -Path <file> -ExpectedSha256 <hex> -> [bool]  (missing file -> $false; case-insensitive).
#   Get-LokiHttpFile -Url <https> -OutFile <path>  -- the raw streaming download (the mock seam; tests replace it).
#   Invoke-LokiVerifiedDownload -Url -ExpectedSha256 -DestPath -> [hashtable]{ Ok; Reason; [Skipped] }
#       not-https -> Ok=$false; already-present+verified -> Ok=$true Skipped; otherwise download to a .part file,
#       verify, then move into place; hash-mismatch or download error -> the .part is deleted and Ok=$false.
# ASCII-only file -> no BOM (CLAUDE.md section 1).
Set-StrictMode -Version Latest

function Test-LokiFileHash {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    # A file we cannot READ is a file we cannot prove matches -> $false, never an exception escaping into a caller
    # that is trying to decide whether something is trustworthy. (Get-FileHash throws on a locked file, and callers
    # run with $ErrorActionPreference='Stop', so without this the throw would blow past their fail-closed handling.)
    try { $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash }
    catch { return $false }
    return ([string]$actual -ieq [string]$ExpectedSha256)
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
        [Parameter(Mandatory = $true)][string]$DestPath
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
    $tmp = $DestPath + '.part'
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
