# lib/download.ps1 -- verified file acquisition (security core, CLAUDE.md section 5, ADR-0011/ADR-0012).
# The ONE way Loki brings a remote file onto the stick. Two consumers: lib/models.ps1 (GGUF data) and
# lib/engine.ps1 (the llama.cpp engine archive, which is CODE we later execute) -- so this lives in lib/
# per CLAUDE.md section 2 (shared logic has exactly one home), not inside either caller.
# The rules are hard, because this is the supply-chain surface:
#   * HTTPS only, END TO END -- the caller's Url must be https AND the FINAL response (after redirects) must still
#     be https. Measured: every shipped host 302s to a CDN (release-assets.githubusercontent.com / us.aws.cdn.hf.co),
#     so redirects are the NORMAL path and checking only the caller's Url never covered where the bytes came from.
#   * the pinned SIZE is enforced, not decorative (ADR-0026): a declared Content-Length that disagrees is refused
#     before the first byte, and the copy is HARD-CAPPED at the pin so a lying server cannot fill the stick. The
#     SHA256 cannot do this job -- it is only computable once the whole file has already been written to disk.
#   * every fetch is verified against a SHA256 pinned in a manifest BEFORE it is moved into place;
#     a mismatch or a download error deletes the partial -- an unverified download is never kept.
#   * a stalled transfer fails instead of hanging setup forever (read timeout, not a total-time limit: a multi-GB
#     download over a slow link is legitimate, two minutes without a single byte is not).
#   * this module downloads and verifies only -- it NEVER executes or expands what it fetched.
# Contract:
#   Get-LokiFileHashState -Path <file> -ExpectedSha256 <hex> -> 'match' | 'differ' | 'unreadable' | 'missing'
#       (never throws; case-insensitive compare). The tri-state primitive -- use it when you must REPORT a fact.
#   Test-LokiFileHash -Path <file> -ExpectedSha256 <hex> -> [bool]  (missing file -> $false; case-insensitive).
#       "is this PROVEN to be the pinned bytes?" -- use it when you must DECIDE.
#   Test-LokiDownloadResponse -ResponseScheme <string> -DeclaredLength <long> -ExpectedBytes <long>
#       -> [hashtable]{ Ok; Reason }   PURE + table-tested. May we read this response body at all?
#       Reasons: ok | not-https-final | length-mismatch. Split out so the judgement is testable without a network.
#   Copy-LokiCappedStream -Source <Stream> -Destination <Stream> -MaxBytes <long> -> [long] bytes copied
#       Streams Source into Destination and THROWS the moment more than MaxBytes arrives. PURE stream logic --
#       unit-tested with MemoryStreams, no network. This is the disk-fill guard.
#   Get-LokiHttpFile -Url <https> -OutFile <path> -MaxBytes <long>  -- the raw streaming download
#       (the mock seam; tests replace it). Thin wiring over the two pure helpers above.
#   Invoke-LokiVerifiedDownload -Url -ExpectedSha256 -ExpectedBytes -DestPath [-StagingDir <dir>]
#       -> [hashtable]{ Ok; Reason; [Skipped] }
#       not-https -> Ok=$false; already-present+verified -> Ok=$true Skipped; otherwise download to a .part file,
#       check its SIZE against the pin, verify the hash, then move into place; size-mismatch, hash-mismatch or a
#       download error deletes the .part and returns Ok=$false.
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

# Timeouts are STALL detection, deliberately not a total-time limit: a multi-GB tier over a slow link is legitimate
# and must not be killed for being slow, but a transfer that produces no byte at all for minutes is wedged.
$script:LokiDownloadHeaderTimeoutMs = 60000     # to get response headers (connect + redirects)
$script:LokiDownloadReadTimeoutMs   = 120000    # between two reads; longer than any real stall-free gap
$script:LokiDownloadBufferBytes     = 131072    # 128 KB copy buffer

function Test-LokiDownloadResponse {
    <#
        PURE + table-tested. May we read this response body at all? Split out of the transport precisely so the
        judgement is testable without a network (the transport itself is the mock seam and therefore untestable).

        Two refusals, both learned from measuring the real hosts:
        * not-https-final -- the caller checked ITS url, but every shipped host 302s to a CDN, so the scheme that
          actually carries the bytes is the redirected one. Without this, "HTTPS only" was a claim about hop 0.
        * length-mismatch -- a declared Content-Length that disagrees with the pin cannot be the pinned file, and
          saying so before the first byte is written is free. A length of -1 means "not declared": not an error,
          just no early answer -- the hard cap in Copy-LokiCappedStream still bounds it.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ResponseScheme,
        [Parameter(Mandatory = $true)][long]$DeclaredLength,
        [Parameter(Mandatory = $true)][long]$ExpectedBytes
    )
    if ($ResponseScheme -ine 'https') { return @{ Ok = $false; Reason = 'not-https-final' } }
    if (($DeclaredLength -ge 0) -and ($DeclaredLength -ne $ExpectedBytes)) { return @{ Ok = $false; Reason = 'length-mismatch' } }
    return @{ Ok = $true; Reason = 'ok' }
}

function Copy-LokiCappedStream {
    <#
        Stream Source into Destination and THROW the moment more than MaxBytes has arrived. PURE stream logic, so it
        is unit-tested with MemoryStreams and never needs a network.

        This is the disk-fill guard, and it is the one thing the SHA256 pin CANNOT do: a hash is only computable once
        the whole file is already on disk, so without a cap a hostile or broken server can write until the stick is
        full and only then be told its bytes were wrong. The cap makes the pinned size a limit rather than a label.
        Returns the byte count so the caller can assert on it.
    #>
    param(
        [Parameter(Mandatory = $true)]$Source,
        [Parameter(Mandatory = $true)]$Destination,
        [Parameter(Mandatory = $true)][long]$MaxBytes
    )
    if ($MaxBytes -le 0) { throw 'Download: MaxBytes must be positive.' }
    $buf = New-Object byte[] $script:LokiDownloadBufferBytes
    $total = [long]0
    while ($true) {
        $n = $Source.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        $total += [long]$n
        # Checked BEFORE the write, so the over-limit bytes never reach the disk at all.
        if ($total -gt $MaxBytes) { throw ("Download: stream exceeded the pinned " + $MaxBytes + " bytes -- aborted.") }
        $Destination.Write($buf, 0, $n)
    }
    return $total
}

function Get-LokiHttpFile {
    <#
        The raw streaming download -- isolated so tests can Mock it (no real network in unit tests). Thin wiring:
        every judgement lives in the two pure helpers above.

        The proxy/TLS story is UNCHANGED from the WebClient it replaces, deliberately -- it is what makes Loki work
        behind a corporate TLS-inspection proxy: the system proxy is used with the caller's DefaultCredentials (so an
        authenticated proxy's HTTP 407 succeeds) and the system certificate store validates the chain (so an
        inspection CA trusted by a domain machine is accepted). TLS 1.2 is forced for old defaults. WebClient is gone
        because DownloadFile offers no seam to cap, time out, or inspect the final URI (ADR-0026).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [Parameter(Mandatory = $true)][long]$MaxBytes
    )
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.Method = 'GET'
    $req.AllowAutoRedirect = $true
    $req.Timeout = $script:LokiDownloadHeaderTimeoutMs
    $req.ReadWriteTimeout = $script:LokiDownloadReadTimeoutMs
    if ($null -ne $req.Proxy) { $req.Proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials }

    $resp = $req.GetResponse()
    try {
        $verdict = Test-LokiDownloadResponse -ResponseScheme ([string]$resp.ResponseUri.Scheme) `
            -DeclaredLength ([long]$resp.ContentLength) -ExpectedBytes $MaxBytes
        if (-not $verdict.Ok) { throw ("Download: refused (" + $verdict.Reason + ") for " + $resp.ResponseUri) }

        $in = $resp.GetResponseStream()
        try {
            if ($in.CanTimeout) { $in.ReadTimeout = $script:LokiDownloadReadTimeoutMs }
            $out = [System.IO.File]::Open($OutFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try { [void](Copy-LokiCappedStream -Source $in -Destination $out -MaxBytes $MaxBytes) }
            finally { $out.Close() }
        }
        finally { $in.Close() }
    }
    finally { $resp.Close() }
}

function Invoke-LokiVerifiedDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        # MANDATORY on purpose (contract break, ADR-0026): the manifests have carried SizeBytes all along and both
        # call sites already read it -- to PRINT it. A pin a caller may silently omit is the decorative pin this
        # change exists to remove, so there is no "unenforced" default to fall into.
        [Parameter(Mandatory = $true)][long]$ExpectedBytes,
        [Parameter(Mandatory = $true)][string]$DestPath,
        [string]$StagingDir
    )
    # Set INSIDE the function (function-scoped, so it neither leaks to the caller nor depends on them): Copy-Item /
    # Move-Item / Remove-Item failures are NON-terminating by default, so without this the catch blocks below never
    # fire and this function reports Ok=$true 'verified' while the stale bytes are still on disk. Proven, not
    # theoretical -- adversarial review reproduced exactly that with a locked destination.
    $ErrorActionPreference = 'Stop'

    # HTTPS only -- never fetch over plaintext. This covers the caller's Url; the FINAL (post-redirect) scheme is
    # checked in the transport, because every shipped host redirects to a CDN (Test-LokiDownloadResponse).
    if ($Url -notmatch '^https://') { return @{ Ok = $false; Reason = 'not-https' } }
    # A non-positive size pin is a broken manifest, not a download problem -- refuse before touching the network.
    if ($ExpectedBytes -le 0) { return @{ Ok = $false; Reason = 'bad-size-pin' } }
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
        Get-LokiHttpFile -Url $Url -OutFile $tmp -MaxBytes $ExpectedBytes
    }
    catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        return @{ Ok = $false; Reason = 'download-failed'; Error = $_.Exception.Message }
    }

    # SIZE before HASH. A file of the wrong length cannot be the pinned file, and a stat costs nothing next to a
    # SHA256 pass over multiple gigabytes -- so the cheap, certain refusal comes first. This is also what makes the
    # pinned SizeBytes enforced rather than decorative: the transport caps the stream, this rejects a SHORT one
    # (a truncated transfer the cap cannot see).
    $partLen = [long](-1)
    try { $partLen = [long](Get-Item -LiteralPath $tmp).Length } catch { $partLen = [long](-1) }
    if ($partLen -ne $ExpectedBytes) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return @{ Ok = $false; Reason = 'size-mismatch' }
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
