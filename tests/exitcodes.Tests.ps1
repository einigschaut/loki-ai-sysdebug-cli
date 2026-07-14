# tests/exitcodes.Tests.ps1 — exit codes are a stable interface (CLAUDE.md §4).
# Pester 5. Dot-source in BeforeAll (discovery/run separation).
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\exitcodes.ps1"
}

Describe 'Get-LokiExitCode' {

    It 'returns code <Code> for <Name>' -ForEach @(
        @{ Name = 'Ok';                   Code = 0 }
        @{ Name = 'GeneralError';         Code = 1 }
        @{ Name = 'Usage';                Code = 2 }
        @{ Name = 'AuthMissing';          Code = 3 }
        @{ Name = 'NetworkRequired';      Code = 4 }
        @{ Name = 'OfflineEngineMissing'; Code = 5 }
        @{ Name = 'FootprintGuard';       Code = 6 }
        @{ Name = 'VolumeLocked';         Code = 7 }
        @{ Name = 'UserAborted';          Code = 8 }
        @{ Name = 'Interrupted';          Code = 130 }
    ) {
        Get-LokiExitCode -Name $Name | Should -Be $Code
    }

    It 'returns an [int]' {
        (Get-LokiExitCode -Name 'Ok') | Should -BeOfType [int]
    }

    # Guard: a mistyped/unknown name MUST throw (no silent 0 fallback).
    It 'throws on an unknown name' {
        { Get-LokiExitCode -Name 'DoesNotExist' } | Should -Throw
    }

    It 'the error message names the allowed names' {
        { Get-LokiExitCode -Name 'Nope' } | Should -Throw -ExpectedMessage '*allowed*'
    }
}
