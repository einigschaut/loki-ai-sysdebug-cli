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
#   Get-LokiModelLayout -AppRoot <dir> -> [hashtable]{ Dir; ManifestPath; LocalManifestPath }  (pure path math; the
#       models\ sibling of engine-offline\, DESIGN.md section 2.2). The counterpart of Get-LokiEngineLayout -- so where
#       the tiers live is stated once, not re-spelled by every command that needs them. LocalManifestPath is the
#       operator's OWN catalog (issue #103): never shipped, never committed, usually absent.
#   Get-LokiModelManifest -Path <psd1> -> [object[]] validated model entries (throws fail-closed on any bad entry).
#   Merge-LokiModelCatalog -Catalog <entries> -Local <entries> -> [object[]]   (#103)
#       PURE. One tier list from the shipped + private catalogs, each entry stamped Source='catalog'|'local'. A
#       duplicate id ACROSS the two throws (load order must never decide which weights a tier points at). Copies
#       entries; validates nothing -- both inputs must already have passed Get-LokiModelManifest.
#   Get-LokiModelCatalog -Path <psd1> [-LocalPath <psd1>] -> [object[]]   (#103)
#       The tiers an operator actually has: shipped + private, merged and stamped. THROWS like Get-LokiModelManifest.
#       An ABSENT local manifest is normal (result identical to pre-#103); one that exists but is broken throws.
#   Read-LokiModelManifestSafe -Path <psd1> [-LocalPath <psd1>] -> [hashtable]{ Ok; Models; Detail }. Wraps Get-LokiModelManifest so a
#       validation THROW becomes Ok=$false + Detail (the validator's message) instead of a raw stack trace at the
#       dispatcher -- the "this stick is older than the code, rebuild it" hint path (issue #87). Fail-closed preserved:
#       Ok=$false is never a usable manifest; the caller must refuse.
#   Get-LokiModelDownloadPlan -Models <entries> -SelectedIds <string[]> -DestDir <dir> -> [pscustomobject[]]
#       { Id; Model; Url; Sha256; SizeBytes; DestPath }  (throws on an unknown id).
# ASCII-only file -> no BOM (CLAUDE.md section 1).
Set-StrictMode -Version Latest

$script:LokiModelRequiredKeys = @('Id', 'Model', 'Tier', 'License', 'Url', 'FileName', 'Sha256', 'SizeBytes', 'ResidentGB', 'ContextTokens', 'KVCache')

function Get-LokiModelLayout {
    # Path math only -- it reads no manifest and touches no file. (Join-Path is provider-aware, so it is not strictly
    # pure: an AppRoot on a drive that does not exist throws. Every caller passes a real AppRoot.)
    # models\ is a SIBLING of engine-offline\, not a child: the tiers are pinned and verified on
    # their own lifecycle, and living under engine-offline\ would mean the next `loki setup` reconcile deletes them
    # (ADR-0012 section 2b -- measured, not reasoned: it reported Pruned: 2).
    param([Parameter(Mandatory = $true)][string]$AppRoot)
    $dir = Join-Path $AppRoot 'models'
    return @{
        Dir               = $dir
        ManifestPath      = (Join-Path $dir 'manifest.psd1')
        # The operator's OWN catalog (issue #103), never shipped and never committed: a model whose license is
        # permissive in practice but is not Apache-2.0/MIT cannot enter the public manifest, yet a single operator may
        # legitimately accept those terms for their own stick. Sitting BESIDE the public manifest keeps one concept in
        # one place -- the same file name works on the stick and in the setup checkout. Absence is the normal case.
        LocalManifestPath = (Join-Path $dir 'manifest.local.psd1')
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
        # A Hugging Face Url must pin an IMMUTABLE revision (ADR-0026). /resolve/main/ is a moving ref: the repo can
        # replace the file under it, and while the SHA256 pin makes that a FAILED download rather than a poisoned one,
        # a supply-chain surface should not point at a moving target in the first place. Scoped to huggingface.co so
        # the rule stays precise about the host shape it actually understands, instead of constraining every future host.
        if (([string]$m.Url -match '^https://huggingface\.co/') -and ([string]$m.Url -notmatch '/resolve/[0-9a-f]{40}/')) {
            throw "Model '$id': a huggingface.co Url must pin an immutable 40-hex revision, not a moving ref like /resolve/main/."
        }
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
        # KVCache is the attention geometry the offline context window sizes against (ADR-0025): the F16 KV-cache cost
        # of one token is 2 * Layers * KVHeads * HeadDim * 2. A wrong-LOW field is the dangerous direction -- it makes
        # the window look cheaper than it is and lets a big dump over-fill KV-cache RAM -- so each must be a positive
        # int, validated fail-closed here rather than trusted. (Presence is already enforced by the required-keys loop.)
        $kv = $m.KVCache
        if ($kv -isnot [System.Collections.IDictionary]) { throw "Model '$id': KVCache must be a hashtable { Layers; KVHeads; HeadDim }." }
        foreach ($gk in @('Layers', 'KVHeads', 'HeadDim')) {
            if (-not $kv.Contains($gk)) { throw "Model '$id': KVCache is missing '$gk'." }
            $gv = $kv[$gk]
            if (($gv -isnot [int]) -or ([int]$gv -le 0)) { throw "Model '$id': KVCache.$gk must be a positive integer." }
        }
        if ($seen.ContainsKey($id)) { throw "Model manifest: duplicate id '$id'." }
        $seen[$id] = $true
    }
    return , $models   # leading comma: keep it an array even for a single entry (no pipeline unwrap)
}

function Merge-LokiModelCatalog {
    <#
        PURE. Combine the shipped catalog with the operator's own entries (issue #103) into ONE tier list, and stamp
        each entry with where it came from: Source='catalog' for the shipped manifest, Source='local' for the private
        one. The stamp is what lets a command tell the operator why a tier they never installed from the catalog is on
        their stick -- an unexplained tier is worse than no tier.

        A DUPLICATE id across the two manifests THROWS. Silently letting one win would make the effective catalog depend
        on load order, and "which weights did that tier actually point at" is precisely the question a supply chain must
        never answer with a shrug. Fail-closed, exactly like the duplicate check inside a single manifest.

        Entries are COPIED, not mutated: the caller's arrays (and the hashtables Import-PowerShellDataFile handed back)
        stay untouched, so stamping cannot leak back into a manifest object another caller is still reading.

        This function does NOT validate -- both inputs must already have come through Get-LokiModelManifest, which is
        unchanged and still fail-closed. "Private" never means "unchecked": a local entry is held to the same SHA256
        pin, KV geometry, safe filename and https rules as a shipped one. The one thing the local path does NOT inherit
        is the Apache/MIT license test, which is a CI assertion over the SHIPPED manifest only -- that is the whole
        point of #103, and the reason the license responsibility sits with the operator who wrote the file.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Catalog,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Local
    )
    $merged = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($pair in @(@{ Items = @($Catalog); Source = 'catalog' }, @{ Items = @($Local); Source = 'local' })) {
        foreach ($m in $pair.Items) {
            $id = [string]$m.Id
            if ($seen.ContainsKey($id)) {
                throw "Model catalog: duplicate id '$id' -- it is in both the shipped manifest and the local one."
            }
            $seen[$id] = $true
            $copy = @{}
            foreach ($k in @($m.Keys)) { $copy[[string]$k] = $m[$k] }
            $copy['Source'] = [string]$pair.Source
            $merged.Add($copy)
        }
    }
    return , @($merged.ToArray())
}

function Get-LokiModelCatalog {
    <#
        The full tier list an operator actually has: the shipped manifest plus, when present, their own (issue #103).
        THROWS on any validation failure, exactly like Get-LokiModelManifest -- this is the raw primitive; the
        "turn it into an operator-actionable message" job belongs to Read-LokiModelManifestSafe, which wraps this.

        An ABSENT local manifest is the normal case, not a fault: it loads the shipped catalog alone and the result is
        identical to before #103. A local manifest that EXISTS but is broken throws -- it is never skipped, because
        quietly dropping the operator's own tiers would change which model runs without saying so.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyString()][string]$LocalPath = ''
    )
    # ASSIGN FIRST, then wrap. Get-LokiModelManifest ends in `return , $models` (so a single-entry catalog does not
    # collapse to a scalar), which means @(FUNC) yields ONE element containing the whole array -- the merge would then
    # iterate a single array-shaped "entry" and stamp nothing. Measured, twice; hence this note.
    $catalog = Get-LokiModelManifest -Path $Path
    $local = @()
    if ((-not [string]::IsNullOrWhiteSpace($LocalPath)) -and (Test-Path -LiteralPath $LocalPath)) {
        $local = Get-LokiModelManifest -Path $LocalPath
    }
    return Merge-LokiModelCatalog -Catalog @($catalog) -Local @($local)
}

function Read-LokiModelManifestSafe {
    # Load the model manifest through the fail-closed validator Get-LokiModelManifest (above), but turn a validation
    # THROW into a structured result instead of letting the raw RuntimeException surface at the dispatcher as a stack
    # trace (loki.ps1 prints $_.Exception.Message + a GeneralError exit). The overwhelmingly likely cause is a stick
    # OLDER than the code -- e.g. a pre-#79 manifest whose huggingface.co Url still carries /resolve/main/ -- so a
    # consuming command (offline/hwscan/doctor) can print an operator-actionable "rebuild the stick" hint plus this
    # Detail (issue #87). The validator is UNCHANGED and still fail-closed: Ok=$false is NOT a usable manifest and the
    # caller must refuse -- never "skip the bad entry and carry on". Both keys are always present (StrictMode-safe read).
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        # OPTIONAL private catalog (issue #103). Omitting it, or pointing it at a file that does not exist, is the
        # normal case and behaves exactly as before -- so every existing caller is unaffected. When the file IS there it
        # goes through the SAME fail-closed validator: a broken local manifest makes the whole load Ok=$false rather
        # than being skipped, because "carry on without the operator's own tiers" would silently change which model runs.
        [AllowEmptyString()][string]$LocalPath = ''
    )
    try {
        $models = Get-LokiModelCatalog -Path $Path -LocalPath $LocalPath
        return @{ Ok = $true; Models = $models; Detail = '' }
    }
    catch {
        return @{ Ok = $false; Models = @(); Detail = [string]$_.Exception.Message }
    }
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
