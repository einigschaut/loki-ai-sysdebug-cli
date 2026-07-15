# lib/footprint.ps1 -- footprint gate (security core, CLAUDE.md section 5, DESIGN.md section 5.4).
# Turns Loki's core guarantee -- "no app-level write lands in the host user profile; everything is redirected onto
# the stick" (ADR-0003) -- into a FALSIFIABLE claim rather than an assertion. It is the INVERSE of the isolation:
# the isolation redirects USERPROFILE/APPDATA/LOCALAPPDATA/TEMP onto the stick; this gate verifies the HOST versions
# of those locations stay clean when an isolated child runs.
#
# Design (Stage 1 -- deterministic self-probe; see ADR-0010):
#   * PROBE targets (hard gate): a Loki-exclusive `loki-footprint-probe` dir under each host redirect root. A
#     self-probe spawns an isolated child that writes a marker into each redirect root; if the redirect holds the
#     marker lands on the STICK and the host probe-dir stays absent. If the redirect broke, the marker appears in the
#     HOST probe-dir -> the before/after diff flags it (exit FootprintGuard). These dirs are ours alone, so there is
#     no concurrent-writer false positive -> the check is deterministic and CI-safe. And because they must NEVER exist
#     on the host, the check is STATE-based, not just a window diff: a probe-dir already present at snapshot time
#     (stale from a prior broken/crashed run -- present before AND after, so the diff alone would miss it) is itself a
#     leak and is seeded straight into Leaked.
#   * STANDING targets (soft / observational): curated, attributable host locations Loki/Claude Code could leak into
#     (host `.claude`, `%APPDATA%\Claude`, `%LOCALAPPDATA%\claude`, the PSReadLine history file). A change here during
#     the probe window is REPORTED (it may be unrelated concurrent activity, e.g. the operator's own claude session)
#     but does NOT fail the gate on the self-probe -- the falsifiable guarantee is the redirect proof above. They are
#     the correct watch-list for a future real-session operation (Stage 2), passed via -Operation.
#   * NOT covered (documented residual, ADR-0010): Windows Known-Folder APIs (SHGetKnownFolderPath) that ignore env
#     redirection; a full chat/scan/offline session end-to-end; a Process Monitor cross-check. And explicitly NOT a
#     forensic-invisibility claim -- OS/USB-level traces are deliberately out of scope (README honest-scope section).
#
# Contract:
#   Get-LokiFootprintTargets [-UserProfile] [-AppData] [-LocalAppData] [-Temp] -> [ordered]@{ name -> path }
#       The curated watch-list built from the given host roots (empty root -> its targets are skipped). Names prefixed
#       'probe-' are the hard-gate redirect checks; 'host-' are the soft standing locations. PURE.
#   Get-LokiFootprintSnapshot -Targets <ordered> -> @{ name -> fingerprint }
#       A cheap, NON-recursive fingerprint per target (file: exists+length+mtime; dir: exists+immediate-child-count+
#       mtime). Non-recursive is deliberate: the probe leak is an existence transition (caught at any depth), and a
#       shallow dir fingerprint both avoids the cost of snapshotting a large host `.claude` twice and does not
#       false-positive on deep concurrent writes into a watched dir.
#   Compare-LokiFootprintSnapshot -Before <snap> -After <snap> -> @{ Clean; Added; Changed }
#       PURE diff. Added = a target that gained existence; Changed = existed in both but the fingerprint differs; a
#       removal is NOT a footprint. Clean = no additions and no changes.
#   Invoke-LokiFootprintProbe -AppRoot <string> [-HostUserProfile ...] [-Operation <scriptblock>]
#       -> @{ Clean; Leaked; Observed; Added; Changed; ProbeVerified }
#       Snapshot host targets -> run the probe (default: the isolated self-probe; or a caller -Operation) -> snapshot
#       again -> diff. Leaked = probe-target changes (hard footprint). Observed = standing-target changes (soft).
#       Clean is gated on Leaked only. ProbeVerified = the default self-probe's markers reached the stick (so a clean
#       host is not a vacuous pass). The spawn is live-adjacent but deterministic (powershell.exe, no network).
# CLAUDE.md section 5: security core -> mandatory review. ASCII-only file -> no BOM (CLAUDE.md section 1).
Set-StrictMode -Version Latest

# The Loki-exclusive marker directory name written under each redirect root by the self-probe (and watched, per host
# root, as a hard-gate target). Single source of truth so the probe writer and the target list can never drift.
$script:LokiFootprintProbeDirName = 'loki-footprint-probe'

# The redirect roots (env var names) the isolation covers and the self-probe exercises -- exactly the vars DESIGN.md
# section 4 calls out as leak-prone (APPDATA/LOCALAPPDATA are independent of USERPROFILE; TEMP is separate).
$script:LokiFootprintProbeRoots = @('USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'TEMP')

function Get-LokiFootprintTargets {
    # 'Targets' names a set (the watch-list), not a single target -- suppress rather than distort the name (same
    # precedent as ConvertTo-LokiDoctorChecks in lib/posture.ps1, CLAUDE.md section 3).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns a set of watch targets (a list), not one target; the plural is the accurate name.')]
    param(
        [AllowEmptyString()][string]$UserProfile = $env:USERPROFILE,
        [AllowEmptyString()][string]$AppData = $env:APPDATA,
        [AllowEmptyString()][string]$LocalAppData = $env:LOCALAPPDATA,
        [AllowEmptyString()][string]$Temp = $env:TEMP
    )
    $probe = $script:LokiFootprintProbeDirName
    $t = [ordered]@{}
    if (-not [string]::IsNullOrEmpty($UserProfile)) {
        $t['host-userprofile-claude'] = Join-Path $UserProfile '.claude'          # standing (soft)
        $t['probe-userprofile'] = Join-Path $UserProfile $probe                   # hard-gate redirect check
    }
    if (-not [string]::IsNullOrEmpty($AppData)) {
        $t['host-appdata-claude'] = Join-Path $AppData 'Claude'                    # standing (soft)
        $t['host-psreadline-history'] = Join-Path $AppData 'Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt'
        $t['probe-appdata'] = Join-Path $AppData $probe                            # hard-gate
    }
    if (-not [string]::IsNullOrEmpty($LocalAppData)) {
        $t['host-localappdata-claude'] = Join-Path $LocalAppData 'claude'          # standing (soft)
        $t['probe-localappdata'] = Join-Path $LocalAppData $probe                  # hard-gate
    }
    if (-not [string]::IsNullOrEmpty($Temp)) {
        $t['probe-temp'] = Join-Path $Temp $probe                                  # hard-gate
    }
    return $t
}

function Get-LokiPathFingerprint {
    # Internal: a cheap, NON-recursive fingerprint of one path. Missing path -> @{ Exists = $false }.
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrEmpty($Path) -or -not (Test-Path -LiteralPath $Path)) { return @{ Exists = $false } }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return @{ Exists = $false } }
    if (-not $item.PSIsContainer) {
        return @{ Exists = $true; Kind = 'file'; Length = [long]$item.Length; LastWriteUtcTicks = [long]$item.LastWriteTimeUtc.Ticks }
    }
    # Directory: immediate children only. NTFS bumps a directory's own mtime on an immediate child add/remove, so
    # (child count + own mtime) catches a top-level change; a deep write is intentionally not chased here (see header).
    $children = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
    return @{ Exists = $true; Kind = 'dir'; ChildCount = [int]$children.Count; LastWriteUtcTicks = [long]$item.LastWriteTimeUtc.Ticks }
}

function Get-LokiFootprintSnapshot {
    param([Parameter(Mandatory = $true)]$Targets)
    $snap = @{}
    foreach ($name in $Targets.Keys) {
        $snap[[string]$name] = Get-LokiPathFingerprint -Path ([string]$Targets[$name])
    }
    return $snap
}

function Test-LokiFingerprintEqual {
    # Internal: are two fingerprints equal? Fail-closed on any field mismatch.
    param([Parameter(Mandatory = $true)]$A, [Parameter(Mandatory = $true)]$B)
    $aExists = [bool]$A.Exists
    $bExists = [bool]$B.Exists
    if ($aExists -ne $bExists) { return $false }
    if (-not $aExists) { return $true }
    if ([string]$A.Kind -ne [string]$B.Kind) { return $false }
    if ([string]$A.Kind -eq 'file') {
        return (([long]$A.Length -eq [long]$B.Length) -and ([long]$A.LastWriteUtcTicks -eq [long]$B.LastWriteUtcTicks))
    }
    return (([int]$A.ChildCount -eq [int]$B.ChildCount) -and ([long]$A.LastWriteUtcTicks -eq [long]$B.LastWriteUtcTicks))
}

function Compare-LokiFootprintSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Before,
        [Parameter(Mandatory = $true)]$After
    )
    $added = New-Object System.Collections.Generic.List[string]
    $changed = New-Object System.Collections.Generic.List[string]
    foreach ($name in $After.Keys) {
        $a = $After[$name]
        $b = $null
        if ($Before.ContainsKey($name)) { $b = $Before[$name] }
        $aExists = ($null -ne $a) -and [bool]$a.Exists
        $bExists = ($null -ne $b) -and [bool]$b.Exists
        if ($aExists -and (-not $bExists)) {
            [void]$added.Add([string]$name)
            continue
        }
        if ($aExists -and $bExists) {
            if (-not (Test-LokiFingerprintEqual -A $a -B $b)) { [void]$changed.Add([string]$name) }
        }
        # aExists=$false (a removal, or never present) is not a footprint -> ignored.
    }
    return @{
        Clean   = (($added.Count -eq 0) -and ($changed.Count -eq 0))
        Added   = @($added.ToArray())
        Changed = @($changed.ToArray())
    }
}

function Invoke-LokiFootprintSelfProbe {
    # Internal: the deterministic probe. Spawns an isolated child (New-LokiChildEnvBlock, ADR-0003) that writes a
    # marker into each redirect root's `loki-footprint-probe` dir. If the isolation holds the markers land on the
    # STICK (isolated roots); we verify that (positive control -- a clean host must not be a vacuous pass), then
    # clean the stick markers up. No network, no `claude` -- just powershell.exe writing files, so it is deterministic.
    param([Parameter(Mandatory = $true)][string]$AppRoot)

    $isolated = Get-LokiIsolatedEnv -StickRoot $AppRoot
    $childEnv = New-LokiChildEnvBlock -Isolated $isolated
    # The probe child only writes marker files -- it needs no credential. Strip any auth var the parent env carried so
    # the probe runs with the minimal env it needs (defense in depth; these are never in argv/logs regardless).
    foreach ($authVar in @('ANTHROPIC_API_KEY', 'CLAUDE_CODE_OAUTH_TOKEN', 'ANTHROPIC_AUTH_TOKEN')) { [void]$childEnv.Remove($authVar) }
    $probe = $script:LokiFootprintProbeDirName
    $id = [System.Guid]::NewGuid().ToString('N')

    $tempDir = Join-Path $AppRoot 'temp'
    if (-not (Test-Path -LiteralPath $tempDir)) { New-Item -ItemType Directory -Force -Path $tempDir | Out-Null }
    $scriptPath = Join-Path $tempDir ('loki-footprint-probe-' + $id + '.ps1')

    # Child body: for each redirect root, write a marker file into <root>\<probe>\<id>.txt. The child resolves the
    # env vars from the isolated block it is handed, so <root> is a stick path when isolation is intact.
    $body = @'
$ErrorActionPreference = 'Stop'
$markerId = '__ID__'
$probeDir = '__PROBE__'
foreach ($v in @('USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'TEMP')) {
    $base = [Environment]::GetEnvironmentVariable($v)
    if ([string]::IsNullOrEmpty($base)) { continue }
    $dir = Join-Path $base $probeDir
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Set-Content -LiteralPath (Join-Path $dir ($markerId + '.txt')) -Value 'loki footprint probe marker' -Encoding utf8
}
'@
    $body = $body.Replace('__ID__', $id).Replace('__PROBE__', $probe)
    [System.IO.File]::WriteAllText($scriptPath, $body, (New-Object System.Text.UTF8Encoding($false)))

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    # The only argument that can contain a space is the script path; it can never contain a quote (guid-named), so a
    # simple double-quote wrap is CommandLineToArgvW-correct here without pulling in the argv quoter from another lib.
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $scriptPath + '"'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $AppRoot
    # Install the isolated child env block (this is what redirects the roots onto the stick).
    $psi.EnvironmentVariables.Clear()
    foreach ($k in $childEnv.Keys) { $psi.EnvironmentVariables[[string]$k] = [string]$childEnv[$k] }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $exited = $proc.WaitForExit(60000)   # generous: a cold powershell.exe start on a loaded CI runner
        if (-not $exited) { try { $proc.Kill() } catch { $null = $_ } }
        [void]$outTask.Result
        [void]$errTask.Result
    }
    finally {
        $proc.Dispose()
    }

    # Positive control: every redirect root's marker must exist on the STICK (the isolated root). If any is missing,
    # the probe did not actually write -> the result is inconclusive, NOT a clean pass.
    $verified = $true
    foreach ($v in $script:LokiFootprintProbeRoots) {
        $base = [string]$isolated[$v]
        if ([string]::IsNullOrEmpty($base)) { $verified = $false; continue }
        $marker = Join-Path (Join-Path $base $probe) ($id + '.txt')
        if (-not (Test-Path -LiteralPath $marker)) { $verified = $false }
    }

    # Cleanup (best-effort): remove THIS run's probe script and ITS OWN markers, then the probe dir only if it is now
    # empty. Deliberately NOT a wholesale `-Recurse` of the dir: a concurrent same-stick run's marker must survive, or
    # its positive control would spuriously fail (its marker deleted -> ProbeVerified=$false -> a false "inconclusive").
    if (Test-Path -LiteralPath $scriptPath) { Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue }
    foreach ($v in $script:LokiFootprintProbeRoots) {
        $base = [string]$isolated[$v]
        if ([string]::IsNullOrEmpty($base)) { continue }
        $d = Join-Path $base $probe
        $marker = Join-Path $d ($id + '.txt')
        if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $d) {
            $remaining = @(Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue)
            if ($remaining.Count -eq 0) { Remove-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue }
        }
    }

    return @{ Verified = $verified }
}

function Invoke-LokiFootprintProbe {
    param(
        [Parameter(Mandatory = $true)][string]$AppRoot,
        [string]$HostUserProfile = $env:USERPROFILE,
        [string]$HostAppData = $env:APPDATA,
        [string]$HostLocalAppData = $env:LOCALAPPDATA,
        [string]$HostTemp = $env:TEMP,
        # A caller-supplied operation to measure instead of the default self-probe (tests; a future real session).
        # When supplied, ProbeVerified is reported as $true (the caller owns what "the operation ran" means).
        [scriptblock]$Operation
    )

    $targets = Get-LokiFootprintTargets -UserProfile $HostUserProfile -AppData $HostAppData -LocalAppData $HostLocalAppData -Temp $HostTemp
    $before = Get-LokiFootprintSnapshot -Targets $targets

    # STATE check (not just the window diff): a 'probe-' target is Loki-exclusive and must NEVER exist on the host. One
    # already present at snapshot time (stale from a prior broken/crashed run) is itself a leak the before/after diff
    # alone would miss (present before AND after -> neither Added nor Changed). Seed it into Leaked -- flag it, never
    # delete it: removing a leaked host artifact is destroying evidence, not the gate's job.
    $preLeaked = New-Object System.Collections.Generic.List[string]
    foreach ($name in $targets.Keys) {
        if (-not ([string]$name).StartsWith('probe-')) { continue }
        $fp = $before[[string]$name]
        if (($null -ne $fp) -and [bool]$fp.Exists) { [void]$preLeaked.Add([string]$name) }
    }

    $probeVerified = $true
    if ($PSBoundParameters.ContainsKey('Operation') -and ($null -ne $Operation)) {
        & $Operation | Out-Null
    }
    else {
        $selfProbe = Invoke-LokiFootprintSelfProbe -AppRoot $AppRoot
        $probeVerified = [bool]$selfProbe.Verified
    }

    $after = Get-LokiFootprintSnapshot -Targets $targets
    $cmp = Compare-LokiFootprintSnapshot -Before $before -After $after

    # Split the diff: 'probe-*' targets are the hard gate (a leak means the redirect broke); 'host-*' standing targets
    # are soft/observational (a change may be unrelated concurrent activity). Clean is gated on the hard set only.
    $leaked = New-Object System.Collections.Generic.List[string]
    $observed = New-Object System.Collections.Generic.List[string]
    foreach ($name in (@($cmp.Added) + @($cmp.Changed))) {
        if (([string]$name).StartsWith('probe-')) { [void]$leaked.Add([string]$name) }
        else { [void]$observed.Add([string]$name) }
    }
    # Fold in the pre-existing host probe targets (dedup): they are leaks regardless of the window diff.
    foreach ($p in $preLeaked) { if (-not $leaked.Contains([string]$p)) { [void]$leaked.Add([string]$p) } }

    return @{
        Clean         = ($leaked.Count -eq 0)
        Leaked        = @($leaked.ToArray())
        Observed      = @($observed.ToArray())
        Added         = @($cmp.Added)
        Changed       = @($cmp.Changed)
        ProbeVerified = $probeVerified
    }
}
