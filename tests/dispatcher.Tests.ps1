# tests/dispatcher.Tests.ps1 — Integration: dispatcher as a fresh Windows PowerShell 5.1 child process (as on the stick).
# Tests routing, exit codes, and the consistency guarantees (did-you-mean, exit 2) end-to-end.
Set-StrictMode -Version Latest

BeforeAll {
    $lokiPath = (Resolve-Path "$PSScriptRoot\..\src\loki.ps1").Path
    # Always launch the real Windows PowerShell 5.1 as a child (target runtime), regardless of which host runs Pester.
    $ps51Path = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps51Path)) { throw "Windows PowerShell 5.1 nicht gefunden: $ps51Path" }

    # Bake paths in via closure -> no $script: scope resolution needed at call time
    # (a 'global:' helper would read $script: from the GLOBAL scope, not from the Pester container -> $null,
    #  when Pester is run from a script like Invoke-Checks).
    $script:InvokeLoki = {
        param([string[]]$LokiArgs)
        # stderr to a file (not 2>&1): under $ErrorActionPreference='Stop' the child's native
        # stderr output would otherwise become a terminating error (PS 5.1 quirk).
        $errFile = [System.IO.Path]::GetTempFileName()
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        # Pin the child process locale deterministically to English (auto-detect would otherwise output
        # DE or EN depending on OS culture -> non-reproducible text assertions across machines/CI).
        $prevLang = $env:LOKI_LANG
        $env:LOKI_LANG = 'en'
        try {
            $out  = & $ps51Path -NoProfile -ExecutionPolicy Bypass -File $lokiPath @LokiArgs 2>$errFile
            $code = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $prevEap
            if ($null -eq $prevLang) { Remove-Item Env:\LOKI_LANG -ErrorAction SilentlyContinue } else { $env:LOKI_LANG = $prevLang }
        }
        $err = ''
        if (Test-Path -LiteralPath $errFile) {
            $err = Get-Content -LiteralPath $errFile -Raw
            Remove-Item -LiteralPath $errFile -Force
        }
        [pscustomobject]@{
            Code = $code
            Text = (($out | Out-String) + "`n" + $err)
        }
    }.GetNewClosure()
}

Describe 'Dispatcher routing & exit codes (PS 5.1 child process)' {

    It 'bare loki => menu, exit 0' {
        $r = & $script:InvokeLoki @()
        $r.Code | Should -Be 0
        $r.Text | Should -BeLike '*loki help*'
    }

    It 'version => exit 0, shows version' {
        $r = & $script:InvokeLoki @('version')
        $r.Code | Should -Be 0
        $r.Text | Should -BeLike '*loki*0.1.0*'
    }

    It 'help => exit 0, lists commands from the registry' {
        $r = & $script:InvokeLoki @('help')
        $r.Code | Should -Be 0
        $r.Text | Should -BeLike '*HEALTH*'
        $r.Text | Should -BeLike '*status*'
        $r.Text | Should -BeLike '*version*'
    }

    It 'status => exit 0, write-free environment check' {
        $r = & $script:InvokeLoki @('status')
        $r.Code | Should -Be 0
        $r.Text | Should -BeLike '*App-Root:*'
    }

    It 'status --help => command help, exit 0' {
        $r = & $script:InvokeLoki @('status', '--help')
        $r.Code | Should -Be 0
        $r.Text | Should -BeLike '*Usage: loki status*'
    }

    # Consistency guarantee: typo -> did-you-mean + exit 2 (not 0!)
    It 'typo => exit 2 + did-you-mean' {
        $r = & $script:InvokeLoki @('verion')
        $r.Code | Should -Be 2
        $r.Text | Should -BeLike "*Did you mean 'loki version'?*"
    }

    It 'unknown command => exit 2' {
        $r = & $script:InvokeLoki @('help', 'bogus')
        $r.Code | Should -Be 2
    }
}
