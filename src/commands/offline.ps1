# commands/offline.ps1 — `loki offline` (scaffolded by build/New-LokiCommand.ps1)
# Metadata (Get-LokiCmdMeta_offline) is the single source of truth; handler (Invoke-LokiCmd_offline) executes it. ADR-0002.
# Note: Summary should be an i18n catalog key (add it to src/i18n/*.psd1); user-facing output goes through Get-LokiText (CLAUDE.md §10).
Set-StrictMode -Version Latest

function Get-LokiCmdMeta_offline {
    @{
        Name     = 'offline'
        Group    = 'Offline'
        Summary  = 'offline.summary'
        Usage    = 'loki offline (--analyze <dump> | --agent)'
        Examples = @('loki offline --analyze <dump>', 'loki offline --agent')
        Flags    = @()
    }
}

function Invoke-LokiCmd_offline {
    param($Context)

    # Two modes, exactly one per invocation: `--analyze <dump>` (Slice 1) reads a dump, `--agent` (Slice 2a) runs the
    # read-only diagnose loop. Neither flag, or BOTH (ambiguous), is a usage error.
    $cmdArgs     = @($Context.Args)
    $wantAgent   = $cmdArgs -contains '--agent'
    $wantAnalyze = $cmdArgs -contains '--analyze'
    if ($wantAgent -eq $wantAnalyze) {   # both true (ambiguous) OR both false (no mode chosen)
        Write-LokiErr (Get-LokiText 'offline.usage')
        return (Get-LokiExitCode 'Usage')
    }

    # --analyze needs its dump up front; --agent gathers its own data live (ADR-0021), so it takes no dump argument.
    # Read-only either way: analyze must not write (the footprint guarantee). A collect .json is rendered, a .txt as-is.
    $dumpText = $null
    if ($wantAnalyze) {
        $dumpPath = @($cmdArgs | Where-Object { $_ -ne '--analyze' }) | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace([string]$dumpPath)) {
            Write-LokiErr (Get-LokiText 'offline.usage')
            return (Get-LokiExitCode 'Usage')
        }
        $dump = Read-LokiOfflineDump -Path ([string]$dumpPath)
        if (-not $dump.Ok) {
            Write-LokiErr (Get-LokiText 'offline.dumpUnreadable' -ArgumentList @([string]$dumpPath))
            return (Get-LokiExitCode 'Usage')
        }
        $dumpText = [string]$dump.Text
    }

    # Engine + model catalog come from the pinned manifests on the stick (shared by both modes).
    $engineData = Get-LokiEngineManifest -Path (Join-Path $Context.AppRoot 'engine\manifest.psd1')
    $modelLayout = Get-LokiModelLayout -AppRoot $Context.AppRoot
    # #87: a stick OLDER than the code carries a pre-#79 model manifest (a moving /resolve/main/ ref) the validator
    # rejects fail-closed. Catch that here and tell the operator to rebuild the stick, instead of letting the raw
    # validation throw reach the dispatcher as a stack trace. The engine load above stays raw -- its manifest lacks the
    # 40-hex pin, so an old stick still validates it; the MODEL manifest is what bites (issue #87).
    $modelMf = Read-LokiModelManifestSafe -Path $modelLayout.ManifestPath
    if (-not $modelMf.Ok) {
        Write-LokiErr (Get-LokiText 'offline.stickOutdated' -ArgumentList @([string]$modelMf.Detail))
        return (Get-LokiExitCode 'OfflineEngineMissing')
    }
    $modelList = @($modelMf.Models)

    if ($wantAgent) {
        # The agent needs the recommended INSTALLED agent-capable tier -- NOT the catalog Default (which is `small`,
        # below the ~8B floor). Selecting by Default made --agent decline on every default stick even with mid/large
        # installed (review 2026-07-18); pick the smallest capable tier whose weights are present, decline if none.
        $installedFiles = @(Get-ChildItem -LiteralPath $modelLayout.Dir -Filter '*.gguf' -File -ErrorAction SilentlyContinue |
                ForEach-Object { $_.Name })
        $model = Select-LokiOfflineAgentModel -Models $modelList -InstalledFileNames $installedFiles
        if ($null -eq $model) {
            Write-LokiErr (Get-LokiText 'offline.agentTooSmall')
            return (Get-LokiExitCode 'OfflineEngineMissing')
        }
        # --agent is experimental and measured NOT field-viable as built (ADR-0029/#84): even with the truncation
        # fixed it runs for many minutes and may never reach a conclusion. Say so BEFORE the operator waits, and point
        # them at --analyze, which gives a fast reliable verdict. This is a notice, not a gate -- the operator asked.
        Write-LokiWarn (Get-LokiText 'offline.agentExperimental')
        # Capable model -> the read-only agent loop. Ok -> print the answer; otherwise map the harness Reason through
        # the SAME Get-LokiOfflineFailure that --analyze uses, so the two offline modes cannot drift apart.
        Write-LokiInfo (Get-LokiText 'offline.agentWorking' -ArgumentList @([string]$model.Model))
        $agent = Invoke-LokiOfflineAgent -AppRoot $Context.AppRoot -Engine $engineData.Engine `
            -Runtime $engineData.Runtime -Model $model
        if ($agent.Ok) {
            Write-LokiLine ''
            Write-LokiLine ([string]$agent.Answer)
            return (Get-LokiExitCode 'Ok')
        }
        $agentDetail = ''
        if (($agent -is [hashtable]) -and $agent.ContainsKey('Detail')) { $agentDetail = [string]$agent.Detail }
        $agentFail = Get-LokiOfflineFailure -Reason ([string]$agent.Reason) -Detail $agentDetail
        Write-LokiErr (Get-LokiText $agentFail.MessageKey)
        if ($agentFail.MessageKey -eq 'offline.engineFailed') {
            # llama-server says WHY on stderr; show it only with --verbose -- matching --analyze so the modes do not drift (A5).
            $verbose = ($Context.Flags -is [hashtable]) -and $Context.Flags.ContainsKey('Verbose') -and $Context.Flags['Verbose']
            if ($verbose -and ($agent -is [hashtable]) -and $agent.ContainsKey('EngineLog') -and (-not [string]::IsNullOrWhiteSpace([string]$agent.EngineLog))) {
                Write-LokiLine ([string]$agent.EngineLog)
            }
        }
        return (Get-LokiExitCode $agentFail.ExitName)
    }

    # --- --analyze (Slice 1): the catalog Default is the analyze model. ---
    $model = $modelList | Where-Object { $_.Default } | Select-Object -First 1
    if ($null -eq $model) { $model = $modelList | Select-Object -First 1 }
    if ($null -eq $model) {
        Write-LokiErr (Get-LokiText 'offline.notSetup')
        return (Get-LokiExitCode 'OfflineEngineMissing')
    }
    Write-LokiInfo (Get-LokiText 'offline.working' -ArgumentList @([string]$model.Model))
    $res = Invoke-LokiOfflineAnalyze -AppRoot $Context.AppRoot -Engine $engineData.Engine `
        -Runtime $engineData.Runtime -Model $model -DumpText $dumpText

    if ($res.Ok) {
        Write-LokiLine ''
        Write-LokiLine ([string]$res.Analysis)
        return (Get-LokiExitCode 'Ok')
    }

    # ONE pure place maps the harness Reason to an exit code + message (Get-LokiOfflineFailure), so the code the
    # script sees and the words the operator reads cannot drift apart.
    $detail = ''
    if (($res -is [hashtable]) -and $res.ContainsKey('Detail')) { $detail = [string]$res.Detail }
    $fail = Get-LokiOfflineFailure -Reason ([string]$res.Reason) -Detail $detail
    Write-LokiErr (Get-LokiText $fail.MessageKey)
    if ($fail.MessageKey -eq 'offline.engineFailed') {
        # llama-server says WHY it would not start on stderr; show it only with --verbose (noisy, path-bearing).
        $verbose = ($Context.Flags -is [hashtable]) -and $Context.Flags.ContainsKey('Verbose') -and $Context.Flags['Verbose']
        if ($verbose -and ($res -is [hashtable]) -and $res.ContainsKey('EngineLog') -and (-not [string]::IsNullOrWhiteSpace([string]$res.EngineLog))) {
            Write-LokiLine ([string]$res.EngineLog)
        }
    }
    return (Get-LokiExitCode $fail.ExitName)
}