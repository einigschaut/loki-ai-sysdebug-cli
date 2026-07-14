# tests/new-command.Tests.ps1 — the scaffolding generator must produce consistent, gate-passing commands.
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\build\Test-LokiStructure.ps1"
    $ps51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps51)) { throw "Windows PowerShell 5.1 nicht gefunden: $ps51" }
    $gen = (Resolve-Path "$PSScriptRoot\..\build\New-LokiCommand.ps1").Path

    # Generator as an isolated child process (its `exit` would otherwise terminate Pester).
    $script:InvokeGen = {
        param([string[]]$GenArgs)
        $errFile = [System.IO.Path]::GetTempFileName()
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $out = & $ps51 -NoProfile -ExecutionPolicy Bypass -File $gen @GenArgs 2>$errFile; $code = $LASTEXITCODE }
        finally { $ErrorActionPreference = $prev }
        $err = ''
        if (Test-Path -LiteralPath $errFile) { $err = Get-Content -LiteralPath $errFile -Raw; Remove-Item -LiteralPath $errFile -Force }
        [pscustomobject]@{ Code = $code; Text = (($out | Out-String) + "`n" + $err) }
    }.GetNewClosure()

    function global:Test-HasBom {
        param([string]$Path)
        $b = [System.IO.File]::ReadAllBytes($Path)
        return ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    }
}

AfterAll { Remove-Item Function:\Test-HasBom -ErrorAction SilentlyContinue }

Describe 'New-LokiCommand (scaffolding)' {

    It 'generates command + test (with BOM), exit 0, and the tree passes the structure gate' {
        $repo = Join-Path $TestDrive 'r1'
        New-Item -ItemType Directory -Force -Path (Join-Path $repo 'src\commands') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $repo 'tests') | Out-Null

        $r = & $script:InvokeGen @('-Name', 'genfoo', '-Summary', 'Test Cmd', '-Group', 'Health', '-RepoRoot', $repo)
        $r.Code | Should -Be 0

        $cmd  = Join-Path $repo 'src\commands\genfoo.ps1'
        $test = Join-Path $repo 'tests\genfoo.Tests.ps1'
        Test-Path -LiteralPath $cmd  | Should -BeTrue
        Test-Path -LiteralPath $test | Should -BeTrue

        (Get-Content -LiteralPath $cmd -Raw) | Should -BeLike '*function Get-LokiCmdMeta_genfoo*'
        (Get-Content -LiteralPath $cmd -Raw) | Should -BeLike '*function Invoke-LokiCmd_genfoo*'
        Test-HasBom -Path $cmd  | Should -BeTrue
        Test-HasBom -Path $test | Should -BeTrue

        (Test-LokiStructure -SrcPath (Join-Path $repo 'src') -TestPath (Join-Path $repo 'tests')).Ok | Should -BeTrue
    }

    It 'refuses overwrite without -Force (exit 2), allows it with -Force (exit 0)' {
        $repo = Join-Path $TestDrive 'r2'
        New-Item -ItemType Directory -Force -Path (Join-Path $repo 'src\commands') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $repo 'tests') | Out-Null

        (& $script:InvokeGen @('-Name', 'dup', '-Summary', 'x', '-Group', 'Health', '-RepoRoot', $repo)).Code | Should -Be 0
        (& $script:InvokeGen @('-Name', 'dup', '-Summary', 'x', '-Group', 'Health', '-RepoRoot', $repo)).Code | Should -Be 2
        (& $script:InvokeGen @('-Name', 'dup', '-Summary', 'x', '-Group', 'Health', '-RepoRoot', $repo, '-Force')).Code | Should -Be 0
    }

    It 'rejects invalid command names (exit != 0)' {
        $repo = Join-Path $TestDrive 'r3'
        New-Item -ItemType Directory -Force -Path (Join-Path $repo 'src\commands') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $repo 'tests') | Out-Null
        (& $script:InvokeGen @('-Name', 'Bad Name', '-Summary', 'x', '-Group', 'Health', '-RepoRoot', $repo)).Code | Should -Not -Be 0
    }
}
