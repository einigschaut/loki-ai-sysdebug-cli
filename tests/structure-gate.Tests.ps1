# tests/structure-gate.Tests.ps1 — the anti-drift/dead-code gate must be green AND be ABLE to fail.
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\build\Test-LokiStructure.ps1"
    $script:RealSrc  = (Resolve-Path "$PSScriptRoot\..\src").Path
    $script:RealTest = (Resolve-Path "$PSScriptRoot\..").Path + '\tests'
}

Describe 'Test-LokiStructure' {

    It 'is green on the real src/tests tree (no dead code, naming convention satisfied)' {
        $r = Test-LokiStructure -SrcPath $script:RealSrc -TestPath $script:RealTest
        if (-not $r.Ok) { $r.Issues | ForEach-Object { Write-Host "  ! $_" } }
        $r.Ok | Should -BeTrue
    }

    # Guard fails on dead code (deliberate, CLAUDE.md §6)
    It 'detects dead function (defined, never called)' {
        $src = Join-Path $TestDrive 'n1\src\lib'
        New-Item -ItemType Directory -Force -Path $src | Out-Null
        Set-Content -LiteralPath (Join-Path $src 'x.ps1') -Value "function Get-Used { 1 }`nfunction Get-Dead { 2 }" -Encoding utf8
        Set-Content -LiteralPath (Join-Path $src 'y.ps1') -Value "Get-Used" -Encoding utf8
        $r = Test-LokiStructure -SrcPath (Join-Path $TestDrive 'n1\src') -TestPath (Join-Path $TestDrive 'n1\tests')
        $r.Ok | Should -BeFalse
        ($r.Issues -join ';') | Should -BeLike '*Get-Dead*'
        ($r.Issues -join ';') | Should -Not -BeLike '*Get-Used*'
    }

    # Guard fails on command without handler (deliberate)
    It 'detects command file without a matching handler' {
        $cmds = Join-Path $TestDrive 'n2\src\commands'
        New-Item -ItemType Directory -Force -Path $cmds | Out-Null
        Set-Content -LiteralPath (Join-Path $cmds 'foo.ps1') -Value "function Get-LokiCmdMeta_foo { @{ Name = 'foo' } }" -Encoding utf8
        $r = Test-LokiStructure -SrcPath (Join-Path $TestDrive 'n2\src') -TestPath (Join-Path $TestDrive 'n2\tests')
        $r.Ok | Should -BeFalse
        ($r.Issues -join ';') | Should -BeLike '*Invoke-LokiCmd_foo*'
    }

    Context 'the -Run entry point (standalone invocation, not dot-sourced)' {
        # The tests above call the FUNCTION; the -Run block -- the actual entry point the script documents -- was
        # entirely untested. These invoke the REAL script in a child process (dot-sourcing would set
        # $MyInvocation.InvocationName to '.' and skip the block), asserting its exit-code contract. Assertions match
        # only the script's own hard-coded English output, never locale-dependent system error text (dev runs on a
        # German host). The block now also sets $ErrorActionPreference='Stop' (CLAUDE.md section 1, defence-in-depth);
        # that is not separately asserted because the scan is written so no constructible tree makes it emit a
        # non-terminating error (Get-ChildItem over a missing path returns empty; every Get-Content is -File-guarded),
        # so a Stop-vs-Continue difference is not observable today -- the guard is for future scan code.
        BeforeAll {
            $script:StructScript = (Resolve-Path "$PSScriptRoot\..\build\Test-LokiStructure.ps1").Path
        }

        It 'runs green on the real repo: exit 0 and prints the OK line' {
            $out  = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:StructScript -Run 2>&1
            $code = $LASTEXITCODE
            $code | Should -Be 0 -Because (($out | Out-String).Trim())
            ($out | Out-String) | Should -Match 'STRUCTURE GATE: OK'
        }

        It 'reports a drifted tree: exit 1 and names the offending function' {
            $root = Join-Path $TestDrive 'run-bad'
            New-Item -ItemType Directory -Force -Path (Join-Path $root 'build') | Out-Null
            New-Item -ItemType Directory -Force -Path (Join-Path $root 'src\lib') | Out-Null
            Copy-Item -LiteralPath $script:StructScript -Destination (Join-Path $root 'build\Test-LokiStructure.ps1') -Force
            Set-Content -LiteralPath (Join-Path $root 'src\lib\x.ps1') -Value 'function Get-OnlyDead { 42 }' -Encoding utf8
            $out  = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'build\Test-LokiStructure.ps1') -Run 2>&1
            $code = $LASTEXITCODE
            $code | Should -Be 1 -Because (($out | Out-String).Trim())
            ($out | Out-String) | Should -Match 'Get-OnlyDead'
        }
    }
}
