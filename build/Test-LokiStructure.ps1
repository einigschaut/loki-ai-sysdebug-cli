# build/Test-LokiStructure.ps1 — static anti-drift/dead-code gate (CLAUDE.md §3/§7).
# Contract:
#   Test-LokiStructure -SrcPath <dir> -TestPath <dir> -> [pscustomobject]@{ Ok=[bool]; Issues=[string[]] }
# Checks WITHOUT loading (purely static, fast, side-effect-free):
#   1) Naming convention: every commands\<x>.ps1 defines Get-LokiCmdMeta_<x> AND Invoke-LokiCmd_<x> (scaffold form).
#   2) Dead code: every function defined in src\ is referenced somewhere (src\ OR tests\).
#      Exception: dynamically dispatched entry points (Get-LokiCmdMeta_* / Invoke-LokiCmd_*) — the registry calls those by name.
# Heuristic note: reference counting is text-based (conservative) — it prefers under-reporting over false positives.
Set-StrictMode -Version Latest

function Test-LokiStructure {
    param(
        [Parameter(Mandatory = $true)][string]$SrcPath,
        [Parameter(Mandatory = $true)][string]$TestPath
    )

    $issues = New-Object System.Collections.Generic.List[string]

    $srcFiles = @(Get-ChildItem -Path $SrcPath -Recurse -Filter *.ps1 -File)
    $refFiles = @($srcFiles)
    if (Test-Path -LiteralPath $TestPath) {
        $refFiles += @(Get-ChildItem -Path $TestPath -Recurse -Filter *.ps1 -File)
    }
    $allText = ($refFiles | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"

    # --- Check 1: command naming convention ---
    $commandsDir = Join-Path $SrcPath 'commands'
    if (Test-Path -LiteralPath $commandsDir) {
        foreach ($cmd in @(Get-ChildItem -Path $commandsDir -Filter *.ps1 -File)) {
            $name = $cmd.BaseName
            $text = Get-Content -LiteralPath $cmd.FullName -Raw
            $esc = [regex]::Escape($name)
            if ($text -notmatch ('(?im)function\s+Get-LokiCmdMeta_' + $esc + '\b')) {
                $issues.Add("commands\$($cmd.Name): missing metadata function 'Get-LokiCmdMeta_$name'")
            }
            if ($text -notmatch ('(?im)function\s+Invoke-LokiCmd_' + $esc + '\b')) {
                $issues.Add("commands\$($cmd.Name): missing handler 'Invoke-LokiCmd_$name'")
            }
        }
    }

    # --- Check 2: dead-code scan ---
    $defined = New-Object System.Collections.Generic.HashSet[string]
    foreach ($f in $srcFiles) {
        $t = Get-Content -LiteralPath $f.FullName -Raw
        foreach ($m in [regex]::Matches($t, '(?im)^\s*function\s+(?:global:)?([A-Za-z][\w-]*)')) {
            [void]$defined.Add($m.Groups[1].Value)
        }
    }
    foreach ($name in $defined) {
        if ($name -match '^(Get-LokiCmdMeta_|Invoke-LokiCmd_)') { continue }  # dynamic dispatch
        $esc = [regex]::Escape($name)
        $total = [regex]::Matches($allText, '\b' + $esc + '\b').Count
        $defs  = [regex]::Matches($allText, '(?im)function\s+(?:global:)?' + $esc + '\b').Count
        if (($total - $defs) -le 0) {
            $issues.Add("dead code: function '$name' is defined but never called anywhere")
        }
    }

    return [pscustomobject]@{
        Ok     = ($issues.Count -eq 0)
        Issues = $issues.ToArray()
    }
}

# Directly runnable: build\Test-LokiStructure.ps1 -Run  (uses repo default paths relative to this file)
if ($MyInvocation.InvocationName -ne '.' -and $args -contains '-Run') {
    $repo = Split-Path $PSScriptRoot -Parent
    $r = Test-LokiStructure -SrcPath (Join-Path $repo 'src') -TestPath (Join-Path $repo 'tests')
    if ($r.Ok) { Write-Host 'STRUCTURE GATE: OK'; exit 0 }
    $r.Issues | ForEach-Object { Write-Host "STRUCTURE GATE: $_" }
    exit 1
}
