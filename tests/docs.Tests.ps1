# tests/docs.Tests.ps1 — docs gate: the README command table stays in sync with the command registry
# (the generated-docs half of CLAUDE.md §7 — previously promised but never enforced, the cause of doc drift).
# Regeneration lives in build\Update-LokiDocs.ps1; this test runs it in -Check mode (process-isolated, the real
# gate) and additionally proves the generator is registry-driven and that the comparison can actually fail.
Set-StrictMode -Version Latest

BeforeAll {
    $src = (Resolve-Path "$PSScriptRoot\..\src").Path
    # Bootstrap like the dispatcher; compute registry + table HERE (parent scope) where the dot-sourced
    # Get-LokiCmdMeta_* functions are visible to Get-Command, then assert on the resulting data in It blocks.
    Get-ChildItem -LiteralPath (Join-Path $src 'lib') -Filter '*.ps1' -File | Sort-Object Name | ForEach-Object { . $_.FullName }
    Get-ChildItem -LiteralPath (Join-Path $src 'commands') -Filter '*.ps1' -File | Sort-Object Name | ForEach-Object { . $_.FullName }
    Initialize-LokiI18n -AppRoot $src -Locale 'en' | Out-Null
    $script:Registry       = Get-LokiCommandRegistry
    $script:GeneratedTable = Format-LokiCommandTable -Registry $script:Registry
    $script:UpdateScript   = (Resolve-Path "$PSScriptRoot\..\build\Update-LokiDocs.ps1").Path
}

Describe 'Docs gate: README command table vs registry' {

    It 'README is in sync with the registry (Update-LokiDocs.ps1 -Check passes)' {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:UpdateScript -Check 2>&1
        $code = $LASTEXITCODE
        $code | Should -Be 0 -Because (($out | Out-String).Trim())
    }

    It 'the generated table is registry-driven: it lists every registered command' {
        $script:Registry.Count | Should -BeGreaterThan 0
        foreach ($c in $script:Registry) {
            $needle = '`' + $c.Name + '`'
            $script:GeneratedTable.Contains($needle) | Should -BeTrue -Because "table must list command '$($c.Name)'"
        }
    }

    It 'BREAK-THE-GATE: the sync comparison can fail (guard is not a constant pass)' {
        # A single changed cell must register as different under the case-sensitive comparison the gate uses.
        $stale = $script:GeneratedTable -replace '\| Health \|', '| CHANGED |'
        $stale | Should -Not -Be $script:GeneratedTable
        ($stale -ceq $script:GeneratedTable) | Should -BeFalse
    }
}
