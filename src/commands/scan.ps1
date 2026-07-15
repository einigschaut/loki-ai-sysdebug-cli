# commands/scan.ps1 -- `loki scan [area]` (scaffolded by build/New-LokiCommand.ps1, then implemented)
# The proactive counterpart to `ask`: a structured, read-only diagnostic sweep of a chosen area, run by the
# online engine against the local machine. Thin wiring only -- lib/claude.ps1 (Invoke-LokiClaude) owns
# enforcement + orchestration, the allow-list gate (lib/allowlist.ps1) via the PreToolUse hook decides which
# commands may run, and every mutation is blocked (read-only scope). The area is validated against a FIXED set
# before it reaches the prompt, so a caller can never inject arbitrary engine instructions through it.
# User-facing text goes through Get-LokiText (CLAUDE.md section 10). ADR-0002/0007.
Set-StrictMode -Version Latest

# Area -> diagnostic objective. These are ENGINE-facing prompt fragments (not user output), so they are plain
# English constants and are NOT localized -- same rule as the read-only charter in lib/claude.ps1. 'general' is
# the no-argument default. Later these objectives can move to data-driven src/playbooks/ without changing callers.
$script:LokiScanAreas = [ordered]@{
    general     = 'Perform a general read-only health sweep of this Windows machine: overall stability signals, recent error and warning patterns in the event logs, resource pressure, and anything clearly abnormal.'
    network     = 'Diagnose this machine''s network health read-only: adapters and link state, IP configuration, DNS resolution, default-gateway reachability, and any listening or established connections that look abnormal.'
    storage     = 'Diagnose this machine''s storage read-only: per-volume free space and pressure, disk health where available, and filesystem-level warnings in the event logs.'
    boot        = 'Diagnose this machine''s boot and startup read-only: recent boot behaviour, boot-critical service failures, and auto-start entries that look abnormal.'
    performance = 'Diagnose this machine''s performance read-only: CPU and memory pressure, the top resource consumers, and recent performance-related warnings.'
    security    = 'Report this machine''s security posture read-only: firewall state, Defender/antivirus status, pending updates, and account or logon anomalies. Do not change any setting.'
}

function Get-LokiCmdMeta_scan {
    @{
        Name     = 'scan'
        Group    = 'Online'
        Summary  = 'scan.summary'
        Usage    = 'loki scan [area]'
        Examples = @('loki scan', 'loki scan network')
        Flags    = @()
    }
}

function Invoke-LokiCmd_scan {
    param($Context)

    # Area = first positional arg; no arg -> 'general'. Validated against the fixed set so the value that shapes
    # the prompt is always one Loki chose, never arbitrary caller text.
    $area = @($Context.Args) | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace([string]$area)) { $area = 'general' }
    $area = ([string]$area).ToLowerInvariant()
    if (-not $script:LokiScanAreas.Contains($area)) {
        Write-LokiErr (Get-LokiText 'scan.invalidArea' -ArgumentList @(($script:LokiScanAreas.Keys -join ', ')))
        return (Get-LokiExitCode 'Usage')
    }

    # Online engine -> requires reachability. Fail fast and clearly when offline (exit 4), pointing at the offline path.
    if (-not (Test-LokiConnectivity)) {
        Write-LokiErr (Get-LokiText 'scan.offline')
        return (Get-LokiExitCode 'NetworkRequired')
    }

    $cfg = Read-LokiConfig -Path (Join-Path $Context.AppRoot 'loki.config.json')

    # Build the engine prompt from the vetted objective + a structured-report framing. Read-only is enforced by
    # the gate regardless of the prompt; the framing only shapes how the answer is presented.
    $objective = [string]$script:LokiScanAreas[$area]
    $prompt = "Diagnostic scan (area: $area). $objective Use only read-only commands. Report the findings as a short structured summary: what you checked, what is healthy, what looks suspicious (with the evidence for it), and concrete next steps. Do not change anything on the system."

    Write-LokiInfo (Get-LokiText 'scan.working' -ArgumentList @($area))
    $res = Invoke-LokiClaude -Prompt $prompt -AppRoot $Context.AppRoot -Config $cfg

    if (-not $res.Ok) {
        if ($res.Reason -eq 'auth-missing') {
            Write-LokiErr (Get-LokiText 'scan.authMissing')
            return (Get-LokiExitCode 'AuthMissing')
        }
        if ($res.Reason -eq 'claude-not-found') {
            Write-LokiErr (Get-LokiText 'scan.engineMissing')
            return (Get-LokiExitCode 'GeneralError')
        }
        if ($res.Reason -eq 'timeout') {
            Write-LokiErr (Get-LokiText 'scan.timeout')
            return (Get-LokiExitCode 'GeneralError')
        }
        # engine-error / bad-output / an is_error result: generic failure; raw engine stderr only with --verbose.
        Write-LokiErr (Get-LokiText 'scan.failed')
        # StrictMode-safe: Flags may not carry every key in every caller (real dispatcher sets them all; tests may not).
        $verbose = ($Context.Flags -is [hashtable]) -and $Context.Flags.ContainsKey('Verbose') -and $Context.Flags['Verbose']
        if ($verbose -and (-not [string]::IsNullOrEmpty([string]$res.ErrorText))) {
            Write-LokiLine ([string]$res.ErrorText)
        }
        return (Get-LokiExitCode 'GeneralError')
    }

    Write-LokiLine ''
    Write-LokiLine ([string]$res.Result)
    if ($null -ne $res.CostUsd) {
        Write-LokiLine ''
        Write-LokiInfo (Get-LokiText 'scan.cost' -ArgumentList @([string]$res.CostUsd))
    }
    return (Get-LokiExitCode 'Ok')
}
