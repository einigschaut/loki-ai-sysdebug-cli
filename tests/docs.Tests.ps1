# tests/docs.Tests.ps1 — docs gate: the README command table stays in sync with the command registry
# (the generated-docs half of CLAUDE.md §7 — previously promised but never enforced, the cause of doc drift).
# Regeneration lives in build\Update-LokiDocs.ps1; this test runs it in -Check mode (process-isolated, the real
# gate) against the real repo, proves the generator is registry-driven, and drives the SAME -Check against a
# throwaway sandbox repo root to prove it actually exits non-zero on drift (not merely that two strings differ).
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

    Context 'BREAK-THE-GATE: the real -Check fails on drift (a throwaway sandbox repo root)' {
        # The assertion that used to live here mutated the table string in memory and checked string != string --
        # tautological, and it never ran the gate. This instead builds a sandbox repo root (a copy of src\ plus a
        # README synced by the REAL generator), then drives the SAME Update-LokiDocs.ps1 -Check the CI gate runs and
        # asserts its exit CODE: 0 while in sync, 1 once the README drifts from the registry. Nothing here touches the
        # tracked README -- the sandbox is a temp directory, removed in AfterAll.
        BeforeAll {
            $srcPath = (Resolve-Path "$PSScriptRoot\..\src").Path
            $script:DocsSandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("loki-docsgate-" + [System.Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path (Join-Path $script:DocsSandbox 'src') | Out-Null
            # Only the registry inputs are needed: lib (functions), commands (the Get-LokiCmdMeta_* fns), i18n (en).
            foreach ($d in 'lib', 'commands', 'i18n') {
                Copy-Item -LiteralPath (Join-Path $srcPath $d) -Destination (Join-Path $script:DocsSandbox 'src') -Recurse -Force
            }
            $beginMarker = '<!-- BEGIN GENERATED COMMANDS (build/Update-LokiDocs.ps1 -- do not edit by hand) -->'
            $endMarker   = '<!-- END GENERATED COMMANDS -->'
            $script:DocsReadmePath = Join-Path $script:DocsSandbox 'README.md'
            $seed = "# Loki (docs-gate sandbox)`n`n" + $beginMarker + "`n`nplaceholder`n`n" + $endMarker + "`n"
            [System.IO.File]::WriteAllText($script:DocsReadmePath, $seed, (New-Object System.Text.UTF8Encoding($false)))
            # Sync the sandbox README with the real generator (write mode) so the baseline is genuinely in step.
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:UpdateScript -RepoRoot $script:DocsSandbox 2>&1 | Out-Null
            $script:DocsSyncedReadme = Get-Content -LiteralPath $script:DocsReadmePath -Raw -Encoding UTF8
        }

        AfterAll {
            if ($script:DocsSandbox -and (Test-Path -LiteralPath $script:DocsSandbox)) {
                Remove-Item -LiteralPath $script:DocsSandbox -Recurse -Force
            }
        }

        BeforeEach {
            # Every test starts from the in-sync baseline; the break tests overwrite their own copy on disk.
            [System.IO.File]::WriteAllText($script:DocsReadmePath, $script:DocsSyncedReadme, (New-Object System.Text.UTF8Encoding($false)))
        }

        It 'PRECONDITION: the real -Check PASSES (exit 0) on the in-sync sandbox -- so a red below is drift, not a broken harness' {
            $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:UpdateScript -RepoRoot $script:DocsSandbox -Check 2>&1
            $LASTEXITCODE | Should -Be 0 -Because (($out | Out-String).Trim())
        }

        It 'a case-only cell change makes the real -Check FAIL (exit 1) -- proving the gate compares case-sensitively (-ceq, not -eq)' {
            $cmd    = [string]$script:Registry[0].Name
            $needle = '`' + $cmd + '`'
            $stale  = $script:DocsSyncedReadme -creplace [regex]::Escape($needle), ('`' + $cmd.ToUpperInvariant() + '`')
            ($stale -ceq $script:DocsSyncedReadme) | Should -BeFalse -Because 'the mutation must be a real, case-only difference for this test to mean anything'
            [System.IO.File]::WriteAllText($script:DocsReadmePath, $stale, (New-Object System.Text.UTF8Encoding($false)))
            $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:UpdateScript -RepoRoot $script:DocsSandbox -Check 2>&1
            $LASTEXITCODE | Should -Be 1 -Because (($out | Out-String).Trim())
        }

        It 'an unregenerated structural edit inside the generated block makes the real -Check FAIL (exit 1)' {
            $beginMarker = '<!-- BEGIN GENERATED COMMANDS (build/Update-LokiDocs.ps1 -- do not edit by hand) -->'
            $stale = $script:DocsSyncedReadme -replace [regex]::Escape($beginMarker), ($beginMarker + "`nDRIFT: a hand edit that was never regenerated")
            $stale | Should -Not -Be $script:DocsSyncedReadme
            [System.IO.File]::WriteAllText($script:DocsReadmePath, $stale, (New-Object System.Text.UTF8Encoding($false)))
            $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:UpdateScript -RepoRoot $script:DocsSandbox -Check 2>&1
            $LASTEXITCODE | Should -Be 1 -Because (($out | Out-String).Trim())
        }
    }
}
