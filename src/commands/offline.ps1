# commands/offline.ps1 — `loki offline` (scaffolded by build/New-LokiCommand.ps1)
# Metadata (Get-LokiCmdMeta_offline) is the single source of truth; handler (Invoke-LokiCmd_offline) executes it. ADR-0002.
# Note: Summary should be an i18n catalog key (add it to src/i18n/*.psd1); user-facing output goes through Get-LokiText (CLAUDE.md §10).
Set-StrictMode -Version Latest

function Get-LokiCmdMeta_offline {
    @{
        Name     = 'offline'
        Group    = 'Offline'
        Summary  = 'offline.summary'
        Usage    = 'loki offline --analyze <dump>'
        Examples = @('loki offline --analyze <dump>')
        Flags    = @()
    }
}

function Invoke-LokiCmd_offline {
    param($Context)

    # Slice 1: `loki offline --analyze <dump>`. --agent is Slice 2; anything without --analyze is a usage error.
    if (-not (@($Context.Args) -contains '--analyze')) {
        Write-LokiErr (Get-LokiText 'offline.usage')
        return (Get-LokiExitCode 'Usage')
    }
    $dumpPath = @($Context.Args | Where-Object { $_ -ne '--analyze' }) | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace([string]$dumpPath)) {
        Write-LokiErr (Get-LokiText 'offline.usage')
        return (Get-LokiExitCode 'Usage')
    }

    # Read-only: analyze must not write (the footprint guarantee). A collect .json is rendered, a .txt used as-is.
    $dump = Read-LokiOfflineDump -Path ([string]$dumpPath)
    if (-not $dump.Ok) {
        Write-LokiErr (Get-LokiText 'offline.dumpUnreadable' -ArgumentList @([string]$dumpPath))
        return (Get-LokiExitCode 'Usage')
    }

    # Engine + model come from the pinned manifests on the stick. Default tier is the analyze model; if the machine
    # cannot run it, the preflight inside Invoke-LokiOfflineAnalyze says so (a clear message, not a crash).
    $engineData = Get-LokiEngineManifest -Path (Join-Path $Context.AppRoot 'engine\manifest.psd1')
    $models = Get-LokiModelManifest -Path (Get-LokiModelLayout -AppRoot $Context.AppRoot).ManifestPath  # assign FIRST
    $modelList = @($models)                                                                             # THEN wrap
    $model = $modelList | Where-Object { $_.Default } | Select-Object -First 1
    if ($null -eq $model) { $model = $modelList | Select-Object -First 1 }
    if ($null -eq $model) {
        Write-LokiErr (Get-LokiText 'offline.notSetup')
        return (Get-LokiExitCode 'OfflineEngineMissing')
    }

    Write-LokiInfo (Get-LokiText 'offline.working' -ArgumentList @([string]$model.Model))
    $res = Invoke-LokiOfflineAnalyze -AppRoot $Context.AppRoot -Engine $engineData.Engine `
        -Runtime $engineData.Runtime -Model $model -DumpText ([string]$dump.Text)

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