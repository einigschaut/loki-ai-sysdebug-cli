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
}
