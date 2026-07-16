# lib/models.ps1 -- offline model acquisition (security core, CLAUDE.md section 5, ADR-0011).
# `loki setup` (run on the internet-connected machine where the stick is prepared) uses this to fetch the chosen
# GGUF model(s) onto the stick and VERIFY each against the pinned SHA256 in src/models/manifest.psd1. This is a
# supply-chain surface (we download large binaries the offline engine will later load), so the rules are hard:
#   * the manifest is the trusted source; every entry pins a Url (HTTPS), byte Size, and SHA256.
#   * a fresh download is verified against its pinned SHA256 and only THEN moved into place; a mismatch or a download
#     error deletes the partial -- an unverified download is never moved into place. (A stale pre-existing file at the
#     destination that fails re-verification is reported as a failure, not trusted; the engine slice must verify a
#     model's hash before loading it.)
#   * HTTPS only; a non-https Url is refused (no plaintext / downgrade).
#   * filenames come only from the manifest and are validated (no path traversal); paths stay under the dest dir.
#   * this module DOWNLOADS and VERIFIES only -- it never executes a downloaded file (that is the engine slice).
# Contract:
#   Get-LokiModelManifest -Path <psd1> -> [object[]] validated model entries (throws fail-closed on any bad entry).
#   Test-LokiFileHash -Path <file> -ExpectedSha256 <hex> -> [bool]  (missing file -> $false; case-insensitive compare).
#   Get-LokiModelDownloadPlan -Models <entries> -SelectedIds <string[]> -DestDir <dir> -> [pscustomobject[]]
#       { Id; Model; Url; Sha256; SizeBytes; DestPath }  (throws on an unknown id).
#   Get-LokiHttpFile -Url <https> -OutFile <path>  -- the raw streaming download (the mock seam; tests replace it).
#   Invoke-LokiVerifiedDownload -Url -ExpectedSha256 -DestPath -> [hashtable]{ Ok; Reason; [Skipped] }
#       not-https -> Ok=$false; already-present+verified -> Ok=$true Skipped; download to a .part file, verify, then
#       move into place; hash-mismatch or download error -> the .part is deleted and Ok=$false.
# ASCII-only file -> no BOM (CLAUDE.md section 1).
Set-StrictMode -Version Latest

$script:LokiModelRequiredKeys = @('Id', 'Model', 'Tier', 'License', 'Url', 'FileName', 'Sha256', 'SizeBytes', 'MinRamGB', 'ContextTokens')

function Get-LokiModelManifest {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Model manifest not found: $Path" }
    $data = Import-PowerShellDataFile -LiteralPath $Path
    if (($null -eq $data) -or (-not $data.ContainsKey('Models'))) { throw "Model manifest malformed: missing 'Models'." }
    $models = @($data.Models)
    $seen = @{}
    foreach ($m in $models) {
        foreach ($k in $script:LokiModelRequiredKeys) {
            if (-not $m.ContainsKey($k)) { throw "Model manifest entry is missing key '$k'." }
        }
        $id = [string]$m.Id
        if ([string]$m.Url -notmatch '^https://') { throw "Model '$id': Url must be https." }
        if ([string]$m.Sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw "Model '$id': Sha256 must be 64 hex chars." }
        # Filename comes from the (trusted) manifest but is validated anyway (defense in depth): safe charset, no
        # path separators, and NOT an all-dots name ('.'/'..') or a reserved device name -> no traversal / odd target.
        $fn = [string]$m.FileName
        if ($fn -notmatch '^[A-Za-z0-9._-]+$') { throw "Model '$id': FileName has unsafe characters." }
        $fnBase = (($fn.ToUpperInvariant()) -split '\.')[0]
        if (($fn -match '^\.+$') -or ($fnBase -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$')) { throw "Model '$id': FileName is a reserved or invalid name." }
        if ([long]$m.SizeBytes -le 0) { throw "Model '$id': SizeBytes must be a positive integer." }
        if ($seen.ContainsKey($id)) { throw "Model manifest: duplicate id '$id'." }
        $seen[$id] = $true
    }
    return , $models   # leading comma: keep it an array even for a single entry (no pipeline unwrap)
}

function Test-LokiFileHash {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    return ([string]$actual -ieq [string]$ExpectedSha256)
}

function Get-LokiModelDownloadPlan {
    param(
        [Parameter(Mandatory = $true)]$Models,
        [Parameter(Mandatory = $true)][string[]]$SelectedIds,
        [Parameter(Mandatory = $true)][string]$DestDir
    )
    $plan = New-Object System.Collections.Generic.List[object]
    foreach ($id in $SelectedIds) {
        $m = $Models | Where-Object { [string]$_.Id -eq [string]$id } | Select-Object -First 1
        if ($null -eq $m) { throw "Unknown model id '$id'." }
        $plan.Add([pscustomobject]@{
                Id        = [string]$m.Id
                Model     = [string]$m.Model
                Url       = [string]$m.Url
                Sha256    = [string]$m.Sha256
                SizeBytes = [long]$m.SizeBytes
                DestPath  = (Join-Path $DestDir ([string]$m.FileName))
            })
    }
    return , $plan.ToArray()   # leading comma: keep it an array even for a single-item plan (no pipeline unwrap)
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
    # HTTPS only -- never fetch a model over plaintext (integrity + no downgrade).
    if ($Url -notmatch '^https://') { return @{ Ok = $false; Reason = 'not-https' } }
    # Idempotent / resumable across runs: an already-present, already-verified file is a no-op.
    if (Test-LokiFileHash -Path $DestPath -ExpectedSha256 $ExpectedSha256) { return @{ Ok = $true; Reason = 'already-verified'; Skipped = $true } }

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

    # Verified -> atomically replace any stale file at the destination.
    if (Test-Path -LiteralPath $DestPath) { Remove-Item -LiteralPath $DestPath -Force -ErrorAction SilentlyContinue }
    Move-Item -LiteralPath $tmp -Destination $DestPath -Force
    return @{ Ok = $true; Reason = 'verified' }
}
