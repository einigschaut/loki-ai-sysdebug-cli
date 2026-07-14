# tests/ui.Tests.ps1 — color decision (Initialize-LokiUi) + write functions do not throw.
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\ui.ps1"
    $script:SavedNoColor = $env:NO_COLOR
}

Describe 'Initialize-LokiUi / Get-LokiUseColor' {

    AfterEach {
        # Reset NO_COLOR after each test (no leak between cases)
        if ($null -eq $script:SavedNoColor) { Remove-Item Env:\NO_COLOR -ErrorAction SilentlyContinue }
        else { $env:NO_COLOR = $script:SavedNoColor }
    }

    It 'default (no flag, no NO_COLOR) => color on' {
        Remove-Item Env:\NO_COLOR -ErrorAction SilentlyContinue
        Initialize-LokiUi
        Get-LokiUseColor | Should -BeTrue
    }

    It '-NoColor => color off' {
        Remove-Item Env:\NO_COLOR -ErrorAction SilentlyContinue
        Initialize-LokiUi -NoColor
        Get-LokiUseColor | Should -BeFalse
    }

    It 'NO_COLOR set => color off (even without the flag)' {
        $env:NO_COLOR = '1'
        Initialize-LokiUi
        Get-LokiUseColor | Should -BeFalse
    }
}

Describe 'Write-Loki* write functions' {
    BeforeAll { Initialize-LokiUi -NoColor }

    It '<Fn> does not throw' -ForEach @(
        @{ Fn = 'Write-LokiLine' }
        @{ Fn = 'Write-LokiInfo' }
        @{ Fn = 'Write-LokiOk' }
        @{ Fn = 'Write-LokiHeading' }
        @{ Fn = 'Write-LokiWarn' }
        @{ Fn = 'Write-LokiErr' }
    ) {
        { & $Fn 'text' } | Should -Not -Throw
    }
}
