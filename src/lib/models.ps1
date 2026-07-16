# lib/models.ps1 -- the offline MODEL catalog (security core, CLAUDE.md section 5, ADR-0011).
# `loki setup` (run on the internet-connected machine where the stick is prepared) uses this to decide WHICH GGUF
# model(s) to fetch onto the stick and WHAT each must hash to. The fetching itself belongs to lib/download.ps1
# (shared with the engine slice, ADR-0012) -- this file owns the manifest and the plan, nothing else.
# This is a supply-chain surface (the offline engine later loads these files), so the rules are hard:
#   * the manifest is the trusted source; every entry pins a Url (HTTPS), byte Size, and SHA256.
#   * filenames come only from the manifest and are validated anyway (no path traversal); paths stay under the dest dir.
#   * a manifest that is malformed in ANY way throws -- fail-closed, never "skip the bad entry and carry on".
#   * models are DATA: nothing here (or in the engine) ever executes them; the engine must verify a model's hash
#     before loading it (load-time verify, ADR-0012).
# Contract:
#   Get-LokiModelLayout -AppRoot <dir> -> [hashtable]{ Dir; ManifestPath }  (pure path math; the models\ sibling of
#       engine-offline\, DESIGN.md section 2.2). The counterpart of Get-LokiEngineLayout -- so where the tiers live is
#       stated once, not re-spelled by every command that needs them.
#   Get-LokiModelManifest -Path <psd1> -> [object[]] validated model entries (throws fail-closed on any bad entry).
#   Get-LokiModelDownloadPlan -Models <entries> -SelectedIds <string[]> -DestDir <dir> -> [pscustomobject[]]
#       { Id; Model; Url; Sha256; SizeBytes; DestPath }  (throws on an unknown id).
# ASCII-only file -> no BOM (CLAUDE.md section 1).
Set-StrictMode -Version Latest

$script:LokiModelRequiredKeys = @('Id', 'Model', 'Tier', 'License', 'Url', 'FileName', 'Sha256', 'SizeBytes', 'ResidentGB', 'ContextTokens')

function Get-LokiModelLayout {
    # Path math only -- it reads no manifest and touches no file. (Join-Path is provider-aware, so it is not strictly
    # pure: an AppRoot on a drive that does not exist throws. Every caller passes a real AppRoot.)
    # models\ is a SIBLING of engine-offline\, not a child: the tiers are pinned and verified on
    # their own lifecycle, and living under engine-offline\ would mean the next `loki setup` reconcile deletes them
    # (ADR-0012 section 2b -- measured, not reasoned: it reported Pruned: 2).
    param([Parameter(Mandatory = $true)][string]$AppRoot)
    $dir = Join-Path $AppRoot 'models'
    return @{
        Dir          = $dir
        ManifestPath = (Join-Path $dir 'manifest.psd1')
    }
}

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
        # -cnotmatch, not -notmatch: case-insensitive matching folds by CURRENT CULTURE, and in tr-TR 'I' becomes the
        # dotless 'i' (U+0131), outside [A-Za-z]. Our own 'Qwen3-4B-Instruct-2507-Q4_K_M.gguf' would be rejected as
        # unsafe on a Turkish machine. The class is explicitly cased, so a case-sensitive match is correct here.
        if ($fn -cnotmatch '^[A-Za-z0-9._-]+$') { throw "Model '$id': FileName has unsafe characters." }
        $fnBase = (($fn.ToUpperInvariant()) -split '\.')[0]
        if (($fn -match '^\.+$') -or ($fnBase -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$')) { throw "Model '$id': FileName is a reserved or invalid name." }
        if ([long]$m.SizeBytes -le 0) { throw "Model '$id': SizeBytes must be a positive integer." }
        # ResidentGB is what the tier selection budgets against (DESIGN.md section 3.2 / ADR-0013). A value at or below
        # the weights on disk cannot be right -- the weights alone are resident, plus KV cache -- and an under-stated
        # figure is the dangerous direction: it makes a model that does not fit look like it does, and the host swaps.
        $residentGB = [double]$m.ResidentGB
        if ($residentGB -le 0) { throw "Model '$id': ResidentGB must be a positive number." }
        if ($residentGB -lt ([double]$m.SizeBytes / 1GB)) { throw "Model '$id': ResidentGB is smaller than the weights on disk." }
        if ($seen.ContainsKey($id)) { throw "Model manifest: duplicate id '$id'." }
        $seen[$id] = $true
    }
    return , $models   # leading comma: keep it an array even for a single entry (no pipeline unwrap)
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
