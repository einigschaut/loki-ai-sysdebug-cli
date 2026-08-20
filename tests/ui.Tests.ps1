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

Describe 'glyph capability (issue #121)' {
    It 'a round trip is the only reliable probe: CP850 best-fits U+2713 to a LETTER, not to "?"' {
        # This is the whole reason the check is a round trip. A probe that looked for '?' would report the tick as
        # supported on CP850 and ship the bug straight back.
        $cp850 = [System.Text.Encoding]::GetEncoding(850)
        $roundTripped = $cp850.GetString($cp850.GetBytes([string][char]0x2713))
        $roundTripped | Should -Be 'V' -Because 'CP850 substitutes a plausible letter, which is invisible to a "?" check'
        Test-LokiEncodingSupport -Encoding $cp850 -Text ([string][char]0x2713) | Should -BeFalse
    }

    It '<label> resolves to tier <tier>' -ForEach @(
        @{ label = 'UTF-8';  cp = 65001; tier = 'rich' }
        @{ label = 'CP850';  cp = 850;   tier = 'oem' }
        @{ label = 'CP437';  cp = 437;   tier = 'oem' }
        @{ label = 'CP1252'; cp = 1252;  tier = 'ascii' }
    ) {
        Resolve-LokiGlyphTier -Encoding ([System.Text.Encoding]::GetEncoding($cp)) | Should -Be $tier
    }

    It 'FAIL-CLOSED: no encoding at all resolves to ascii, never to rich' {
        Resolve-LokiGlyphTier -Encoding $null | Should -Be 'ascii'
        Test-LokiEncodingSupport -Encoding $null -Text 'plain' | Should -BeFalse
    }

    It 'REGRESSION #121: on an OEM console the success marker is NOT the tick' {
        # The defect this issue was opened for: `loki` printed "V Modell verifiziert" on a stock German console.
        Initialize-LokiUi -NoColor -Encoding ([System.Text.Encoding]::GetEncoding(850))
        Get-LokiGlyphTier | Should -Be 'oem'
        $marker = Get-LokiGlyph 'ok'
        $marker | Should -Not -Be ([string][char]0x2713)
        $marker | Should -Not -Be 'V'
        Test-LokiEncodingSupport -Encoding ([System.Text.Encoding]::GetEncoding(850)) -Text $marker |
            Should -BeTrue -Because 'a replacement that itself cannot be encoded would be the same bug again'
    }

    It 'every tier offers a marker its own encoding can actually represent' {
        # The table and the tiers must not drift apart: a glyph is only allowed in a tier that can encode it.
        foreach ($case in @(
                @{ cp = 65001; tier = 'rich' }, @{ cp = 850; tier = 'oem' }, @{ cp = 1252; tier = 'ascii' })) {
            $enc = [System.Text.Encoding]::GetEncoding($case.cp)
            Initialize-LokiUi -NoColor -Encoding $enc
            Get-LokiGlyphTier | Should -Be $case.tier
            Test-LokiEncodingSupport -Encoding $enc -Text (Get-LokiGlyph 'ok') |
                Should -BeTrue -Because "tier $($case.tier) must not offer a glyph its own encoding cannot hold"
        }
    }

    It 'BREAK-THE-GUARD: an unknown glyph name throws instead of returning an empty string' {
        # Silently rendering nothing would make a missing glyph look like a layout bug forever.
        { Get-LokiGlyph -Name 'no-such-glyph' } | Should -Throw
    }

    It 'the tier is ascii until Initialize-LokiUi has run' {
        # Fresh dot-source in a child scope: the fail-closed default must hold before anything detects anything.
        $tier = & powershell.exe -NoProfile -NonInteractive -Command ". '$PSScriptRoot\..\src\lib\ui.ps1'; Get-LokiGlyphTier"
        ([string]$tier).Trim() | Should -Be 'ascii'
    }
}
