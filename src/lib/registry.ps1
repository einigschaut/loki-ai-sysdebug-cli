# lib/registry.ps1 — command registry = single source of truth (CLAUDE.md section 3)
# Prerequisite: the dispatcher has dot-sourced all commands/*.ps1 into script scope.
#   Every command file defines:  Get-LokiCmdMeta_<name>  (returns a hashtable) and  Invoke-LokiCmd_<name>  (param $Context).
# Contract:
#   Get-LokiCommandRegistry            -> [pscustomobject[]] validated command metadata (throws on violation = consistency gate)
#   Get-LokiSuggestion -Name -Registry -> closest matching command name (or $null)
#   Format-LokiHelp -Registry [-CommandName] [-AppVersion] -> help text (string)
#   Get-LokiLevenshtein -A -B          -> int edit distance
Set-StrictMode -Version Latest

$script:LokiRequiredMetaKeys = @('Name', 'Summary', 'Usage', 'Group')

function Get-LokiCommandRegistry {
    $reg = @()
    $metaFns = Get-Command -CommandType Function -Name 'Get-LokiCmdMeta_*' -ErrorAction SilentlyContinue
    foreach ($fn in ($metaFns | Sort-Object Name)) {
        $meta = & $fn.Name
        if ($null -eq $meta -or -not ($meta -is [hashtable])) {
            throw "Registry: $($fn.Name) does not return a metadata hashtable."
        }
        foreach ($k in $script:LokiRequiredMetaKeys) {
            if (-not $meta.ContainsKey($k) -or [string]::IsNullOrWhiteSpace([string]$meta[$k])) {
                throw "Registry: command metadata incomplete (field '$k' missing) in $($fn.Name)."
            }
        }
        $handler = "Invoke-LokiCmd_$($meta.Name)"
        if (-not (Get-Command -CommandType Function -Name $handler -ErrorAction SilentlyContinue)) {
            throw "Registry: handler '$handler' missing for command '$($meta.Name)' (dead/orphaned command?)."
        }
        $reg += [pscustomobject]@{
            Name     = [string]$meta.Name
            Summary  = [string]$meta.Summary
            Usage    = [string]$meta.Usage
            Group    = [string]$meta.Group
            Examples = @($meta['Examples'])
            Flags    = @($meta['Flags'])
            Handler  = $handler
        }
    }
    return , ($reg | Sort-Object Group, Name)
}

function Get-LokiLevenshtein {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$A,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$B
    )
    $la = $A.Length; $lb = $B.Length
    if ($la -eq 0) { return $lb }
    if ($lb -eq 0) { return $la }
    $d = New-Object 'int[,]' ($la + 1), ($lb + 1)
    for ($i = 0; $i -le $la; $i++) { $d[$i, 0] = $i }
    for ($j = 0; $j -le $lb; $j++) { $d[0, $j] = $j }
    for ($i = 1; $i -le $la; $i++) {
        for ($j = 1; $j -le $lb; $j++) {
            $cost = 1
            if ($A[$i - 1] -eq $B[$j - 1]) { $cost = 0 }
            $del = $d[($i - 1), $j] + 1
            $ins = $d[$i, ($j - 1)] + 1
            $sub = $d[($i - 1), ($j - 1)] + $cost
            $d[$i, $j] = [Math]::Min([Math]::Min($del, $ins), $sub)
        }
    }
    return $d[$la, $lb]
}

function Get-LokiSuggestion {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)]$Registry)
    $best = $null; $bestDist = [int]::MaxValue
    $threshold = [Math]::Max(2, [Math]::Ceiling($Name.Length / 3.0))
    foreach ($c in $Registry) {
        $dist = Get-LokiLevenshtein -A $Name.ToLower() -B $c.Name.ToLower()
        if ($dist -lt $bestDist) { $bestDist = $dist; $best = $c.Name }
    }
    if ($bestDist -le $threshold) { return $best }
    return $null
}

function Format-LokiHelp {
    param([Parameter(Mandatory = $true)]$Registry, [string]$CommandName, [string]$AppVersion = '')

    if (-not [string]::IsNullOrEmpty($CommandName)) {
        $cmd = $Registry | Where-Object { $_.Name -eq $CommandName } | Select-Object -First 1
        if ($null -eq $cmd) { return (Get-LokiText 'help.unknownCommand' -ArgumentList @($CommandName)) }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine("loki $($cmd.Name) - $(Get-LokiText $cmd.Summary)")
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine((Get-LokiText 'help.usage' -ArgumentList @($cmd.Usage)))
        if ($cmd.Flags -and $cmd.Flags.Count -gt 0) {
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine((Get-LokiText 'help.flagsHeading'))
            foreach ($f in $cmd.Flags) { [void]$sb.AppendLine(("  {0,-18} {1}" -f $f.Flag, $f.Desc)) }
        }
        if ($cmd.Examples -and $cmd.Examples.Count -gt 0) {
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine((Get-LokiText 'help.examplesHeading'))
            foreach ($e in $cmd.Examples) { [void]$sb.AppendLine("  $e") }
        }
        return $sb.ToString().TrimEnd()
    }

    $sb = New-Object System.Text.StringBuilder
    $head = "loki - $(Get-LokiText 'app.tagline')"
    if (-not [string]::IsNullOrEmpty($AppVersion)) { $head = "$head (v$AppVersion)" }
    [void]$sb.AppendLine($head)
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine((Get-LokiText 'help.usageGeneric'))
    [void]$sb.AppendLine('')
    foreach ($group in ($Registry | Select-Object -ExpandProperty Group -Unique | Sort-Object)) {
        [void]$sb.AppendLine($group.ToUpper())
        foreach ($c in ($Registry | Where-Object { $_.Group -eq $group })) {
            [void]$sb.AppendLine(("  {0,-14} {1}" -f $c.Name, (Get-LokiText $c.Summary)))
        }
        [void]$sb.AppendLine('')
    }
    [void]$sb.AppendLine((Get-LokiText 'help.footer'))
    return $sb.ToString().TrimEnd()
}
