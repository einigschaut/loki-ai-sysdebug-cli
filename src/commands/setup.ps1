# commands/setup.ps1 -- `loki setup` (structurally identical to a scaffolded command; hand-written like commands/auth.ps1
# because it pairs with the hand-curated src/models/manifest.psd1 + src/engine/manifest.psd1). ADR-0002/0011/0012.
# Run on the internet-connected machine where the stick is prepared: put the offline ENGINE and the chosen MODEL
# tier(s) on the stick, each verified against a pinned SHA256. Thin wiring -- lib/engine.ps1 and lib/models.ps1 own the
# manifests, lib/download.ps1 owns the verified fetch.
Set-StrictMode -Version Latest

function Get-LokiCmdMeta_setup {
    @{
        Name     = 'setup'
        Group    = 'Setup'
        Summary  = 'setup.summary'
        Usage    = 'loki setup [--tier <id,...|default|all>] [--stage-runtime]'
        Examples = @('loki setup', 'loki setup --tier default', 'loki setup --tier small,mid --stage-runtime')
        Flags    = @(
            @{ Flag = '--tier'; Desc = 'Model tier ids to download (comma-separated), or "default"/"all"; skips the picker' },
            @{ Flag = '--stage-runtime'; Desc = "Also copy this machine's Microsoft C/C++ runtime next to the engine (see ADR-0012)" }
        )
    }
}

function Invoke-LokiCmd_setup {
    param($Context)

    # Selection tokens from args (--tier <ids> or bare ids); empty -> interactive picker below.
    # --stage-runtime is a flag, not a tier: it must be consumed here or it would be read as a tier id.
    $stageRuntime = $false
    $tokens = New-Object System.Collections.Generic.List[string]
    foreach ($a in $Context.Args) {
        $s = [string]$a
        if ($s -eq '--stage-runtime') { $stageRuntime = $true; continue }
        if ($s -eq '--tier') { continue }
        $s = $s -replace '^--tier=', ''
        foreach ($part in ($s -split '[,\s]+')) {
            if (-not [string]::IsNullOrWhiteSpace($part)) { $tokens.Add($part.Trim().ToLowerInvariant()) }
        }
    }

    # ---- Selection first --------------------------------------------------------------------------------------------
    # Everything the user picks is resolved and validated BEFORE any network work: an unknown tier id must cost a usage
    # error, not an engine download followed by a usage error.
    $modelLayout = Get-LokiModelLayout -AppRoot $Context.AppRoot
    $models = Get-LokiModelManifest -Path $modelLayout.ManifestPath
    $destDir = $modelLayout.Dir

    # Always show the catalog (sizes let the user pick to fit their stick + RAM -- the whole point of the picker).
    Write-LokiHeading (Get-LokiText 'setup.heading')
    Write-LokiLine (Get-LokiText 'setup.tiersHint')
    foreach ($m in $models) {
        $gb = [math]::Round(([double]$m.SizeBytes / 1GB), 2)
        $star = ''
        if ($m.Default) { $star = ' *' }
        # Through Get-LokiText, not the -f operator: -f formats in the ambient CurrentCulture, so on a machine with a
        # German regional format this row printed "2,33 GB" three lines above setup.downloading's "2.33 GB" -- same
        # number, same run, two separators (measured). The sizes are passed as numbers, not [string]: formatting them
        # is Get-LokiText's job, and it does it in the locale Loki chose rather than the one the machine happens to be
        # set to. The two ids stay [string] because a catalog id is not a number.
        Write-LokiLine (Get-LokiText 'setup.tierRow' -ArgumentList @(
                [string]$m.Id, [string]$m.Model, $gb, $m.ResidentGB, $m.ContextTokens, [string]$m.License, $star))
    }

    if ($tokens.Count -eq 0) {
        $choice = [string](Read-Host -Prompt (Get-LokiText 'setup.choosePrompt'))
        foreach ($part in ($choice -split '[,\s]+')) {
            if (-not [string]::IsNullOrWhiteSpace($part)) { $tokens.Add($part.Trim().ToLowerInvariant()) }
        }
    }

    # Resolve keywords (default/all) + validate ids against the manifest.
    $validIds = @($models | ForEach-Object { [string]$_.Id })
    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($t in $tokens) {
        if ($t -eq 'default') {
            foreach ($m in $models) { if ($m.Default) { if (-not $ids.Contains([string]$m.Id)) { $ids.Add([string]$m.Id) } } }
        }
        elseif ($t -eq 'all') {
            foreach ($m in $models) { if (-not $ids.Contains([string]$m.Id)) { $ids.Add([string]$m.Id) } }
        }
        elseif ($validIds -contains $t) {
            if (-not $ids.Contains($t)) { $ids.Add($t) }
        }
        else {
            Write-LokiErr (Get-LokiText 'setup.badSelection' -ArgumentList @($t))
            return (Get-LokiExitCode 'Usage')
        }
    }

    # ---- Engine (always) -------------------------------------------------------------------------------------------
    # The engine is required for every offline use and is small + idempotent (an already-verified archive is a no-op),
    # so setup always ensures it -- there is no way to end up with models and no engine.
    $engineData = Get-LokiEngineManifest -Path (Join-Path $Context.AppRoot 'engine\manifest.psd1')
    $engine = $engineData.Engine
    $runtimeSpec = $engineData.Runtime
    $layout = Get-LokiEngineLayout -AppRoot $Context.AppRoot -Engine $engine

    Write-LokiHeading (Get-LokiText 'setup.engineHeading')

    # The engine comes from GitHub, the models from Hugging Face -- probe the host we are about to use, so a network
    # that allows one and blocks the other fails fast and says which.
    if (-not (Test-LokiConnectivity -TargetHost 'github.com')) {
        Write-LokiErr (Get-LokiText 'setup.engineOffline')
        return (Get-LokiExitCode 'NetworkRequired')
    }

    Write-LokiInfo (Get-LokiText 'setup.engineDownloading' -ArgumentList @([string]$engine.Id, [string]$engine.Version, [math]::Round(([double]$engine.SizeBytes / 1MB), 1)))
    # -StagingDir: the .part must not be written into engine-offline\, which lib/integrity.ps1 reconciles against the
    # pinned archive. A Ctrl-C on this download (200 MB over a slow link is where operators actually reach for it)
    # would otherwise leave a partial that makes `loki doctor --engine` report the stick as tampered with.
    $dl = Invoke-LokiVerifiedDownload -Url ([string]$engine.Url) -ExpectedSha256 ([string]$engine.Sha256) `
        -ExpectedBytes ([long]$engine.SizeBytes) -DestPath $layout.ArchivePath -StagingDir $layout.StagingDir
    if (-not $dl.Ok) {
        Write-LokiErr (Get-LokiText 'setup.engineFailed' -ArgumentList @([string]$dl.Reason))
        return (Get-LokiExitCode 'GeneralError')
    }
    if ($dl.ContainsKey('Skipped') -and $dl.Skipped) { Write-LokiOk (Get-LokiText 'setup.engineSkipped' -ArgumentList @([string]$engine.Id, [string]$engine.Version)) }
    else { Write-LokiOk (Get-LokiText 'setup.engineVerified' -ArgumentList @([string]$engine.Id, [string]$engine.Version)) }

    # PreserveNames = the staged Microsoft runtime: it legitimately lives next to the engine but is not in the archive,
    # so the reconcile must not sweep it away.
    $runtimeFiles = @($runtimeSpec.Files)
    $exp = Expand-LokiVerifiedArchive -ArchivePath $layout.ArchivePath -DestDir $layout.Dir -ExpectedSha256 ([string]$engine.Sha256) -PreserveNames $runtimeFiles
    if (-not $exp.Ok) {
        Write-LokiErr (Get-LokiText 'setup.engineExpandFailed' -ArgumentList @([string]$exp.Reason))
        return (Get-LokiExitCode 'GeneralError')
    }
    Write-LokiOk (Get-LokiText 'setup.engineExpanded' -ArgumentList @([int]$exp.Count))
    # ContainsKey, not a bare property read: under StrictMode Latest a missing hashtable key THROWS.
    if ($exp.ContainsKey('Pruned') -and ([int]$exp.Pruned -gt 0)) {
        Write-LokiWarn (Get-LokiText 'setup.enginePruned' -ArgumentList @([int]$exp.Pruned))
    }

    # ---- Microsoft C/C++ runtime ------------------------------------------------------------------------------------
    # Not part of Windows, not in the archive, and NOT ours to ship (ADR-0012). Source is always this machine's real
    # System32 -- fixed here, never taken from user input.
    $systemDir = Join-Path $env:SystemRoot 'System32'
    if ((-not [Environment]::Is64BitProcess) -and [Environment]::Is64BitOperatingSystem) {
        # WOW64 silently redirects a 32-bit process's System32 to SysWOW64, which holds the 32-BIT dlls -- the wrong
        # architecture for the pinned win-cpu-x64 engine. Sysnative is the documented escape hatch to the real one.
        $systemDir = Join-Path $env:SystemRoot 'Sysnative'
    }
    if ($stageRuntime) {
        Write-LokiInfo (Get-LokiText 'setup.runtimeNotice')
        $st = Copy-LokiVcRuntimeAppLocal -SourceDir $systemDir -DestDir $layout.Dir -Files $runtimeFiles `
            -MinVersion ([string]$runtimeSpec.MinVersion) -StagingDir $layout.StagingDir
        if ($st.Ok) {
            Write-LokiOk (Get-LokiText 'setup.runtimeStaged' -ArgumentList @(@($st.Staged).Count, [string]$st.Version))
        }
        else {
            switch ([string]$st.Reason) {
                'source-missing' { Write-LokiErr (Get-LokiText 'setup.runtimeSourceMissing' -ArgumentList @((@($st.Missing) -join ', '))) }
                'too-old' { Write-LokiErr (Get-LokiText 'setup.runtimeTooOld' -ArgumentList @([string]$st.Version, [string]$st.MinVersion)) }
                'version-unreadable' { Write-LokiErr (Get-LokiText 'setup.runtimeUnreadable' -ArgumentList @([string]$st.File)) }
                default { Write-LokiErr (Get-LokiText 'setup.runtimeStageFailed' -ArgumentList @([string]$st.Reason)) }
            }
            return (Get-LokiExitCode 'GeneralError')
        }
    }
    else {
        # Presence alone is not "fine": a runtime below MinVersion is refused when we stage it, so reporting the same
        # runtime as OK just because the file exists would hand the operator a green check and a target-side loader
        # failure. Same floor, same answer, both paths.
        $stagedStatus = Get-LokiVcRuntimeStatus -Directory $layout.Dir -Files $runtimeFiles
        if ($stagedStatus.Present) {
            $floor = Get-LokiVcRuntimeFloorCheck -Found $stagedStatus.Found -MinVersion ([string]$runtimeSpec.MinVersion)
            if ($floor.Ok) { Write-LokiOk (Get-LokiText 'setup.runtimePresent' -ArgumentList @([string]$floor.Version)) }
            else { Write-LokiWarn (Get-LokiText 'setup.runtimeStale' -ArgumentList @([string]$runtimeSpec.MinVersion)) }
        }
        else { Write-LokiInfo (Get-LokiText 'setup.runtimeHint') }
    }

    # ---- Models -----------------------------------------------------------------------------------------------------
    # The engine above is done either way; picking no model is a legitimate outcome (engine-only stick), not an error.
    if ($ids.Count -eq 0) {
        Write-LokiWarn (Get-LokiText 'setup.noneSelected')
        return (Get-LokiExitCode 'Ok')
    }

    if (-not (Test-LokiConnectivity -TargetHost 'huggingface.co')) {
        Write-LokiErr (Get-LokiText 'setup.offline')
        return (Get-LokiExitCode 'NetworkRequired')
    }

    $plan = Get-LokiModelDownloadPlan -Models $models -SelectedIds $ids.ToArray() -DestDir $destDir

    $failed = 0
    foreach ($p in $plan) {
        Write-LokiInfo (Get-LokiText 'setup.downloading' -ArgumentList @($p.Model, [math]::Round(([double]$p.SizeBytes / 1GB), 2)))
        $res = Invoke-LokiVerifiedDownload -Url $p.Url -ExpectedSha256 $p.Sha256 `
            -ExpectedBytes ([long]$p.SizeBytes) -DestPath $p.DestPath
        if ($res.Ok) {
            if ($res.ContainsKey('Skipped') -and $res.Skipped) { Write-LokiOk (Get-LokiText 'setup.skipped' -ArgumentList @($p.Model)) }
            else { Write-LokiOk (Get-LokiText 'setup.verified' -ArgumentList @($p.Model)) }
        }
        else {
            $failed++
            Write-LokiErr (Get-LokiText 'setup.verifyFailed' -ArgumentList @($p.Model, [string]$res.Reason))
        }
    }

    if ($failed -gt 0) { return (Get-LokiExitCode 'GeneralError') }
    Write-LokiOk (Get-LokiText 'setup.done' -ArgumentList @($plan.Count))
    Write-LokiInfo (Get-LokiText 'setup.engineNote')
    return (Get-LokiExitCode 'Ok')
}
