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

    # Engine + model come from the pinned manifests on the stick (shared by both modes). If the machine cannot run the
    # model, the preflight inside the engine harness says so (a clear message, not a crash).
    $engineData = Get-LokiEngineManifest -Path (Join-Path $Context.AppRoot 'engine\manifest.psd1')
    $models = Get-LokiModelManifest -Path (Get-LokiModelLayout -AppRoot $Context.AppRoot).ManifestPath  # assign FIRST
    $modelList = @($models)                                                                             # THEN wrap
    $model = $modelList | Where-Object { $_.Default } | Select-Object -First 1
    if ($null -eq $model) { $model = $modelList | Select-Object -First 1 }
    if ($null -eq $model) {
        Write-LokiErr (Get-LokiText 'offline.notSetup')
        return (Get-LokiExitCode 'OfflineEngineMissing')
    }

    if ($wantAgent) {
        # The agent LOOP needs a model at or above the ~8B floor (the `mid` tier, DESIGN.md section 3 / ADR-0021).
        # Below it, decline and point at --analyze rather than run a loop DESIGN.md itself calls unreliable there.
        if (-not (Test-LokiOfflineAgentCapable -Model $model)) {
            Write-LokiErr (Get-LokiText 'offline.agentTooSmall' -ArgumentList @([string]$model.Model))
            return (Get-LokiExitCode 'OfflineEngineMissing')
        }
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
        return (Get-LokiExitCode $agentFail.ExitName)
    }

    # --- --analyze (Slice 1) ---
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