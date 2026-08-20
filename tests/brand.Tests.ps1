# tests/brand.Tests.ps1 -- Loki's visual identity. The point of these tests is NOT that the picture is pretty; it
# is that the picture can be DRAWN on the consoles Loki actually meets. Issue #121 was found by discovering that
# three of three mascot drafts used characters CP850 silently replaces, so the central assertion here is that every
# tier only ever emits characters its own encoding can hold.
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\ui.ps1"
    . "$PSScriptRoot\..\src\lib\brand.ps1"
    Initialize-LokiUi -NoColor

    function global:Test-LokiArtFitsEncoding {
        param([string[]]$Lines, [int]$CodePage)
        $enc = [System.Text.Encoding]::GetEncoding($CodePage)
        foreach ($l in @($Lines)) {
            if ($enc.GetString($enc.GetBytes([string]$l)) -ne [string]$l) { return $false }
        }
        return $true
    }
}

Describe 'Get-LokiBrandArt' {
    It 'the oem banner uses ONLY characters CP850 and CP437 can both hold' {
        # The guard that would have caught the original drafts. If someone reaches for a rounded corner again, this
        # goes red before it ever reaches an operator's console.
        $art = Get-LokiBrandArt -Tier 'oem' -Width 80
        @($art).Count | Should -BeGreaterThan 1 -Because 'an empty banner would satisfy any encoding vacuously'
        Test-LokiArtFitsEncoding -Lines $art -CodePage 850 | Should -BeTrue
        Test-LokiArtFitsEncoding -Lines $art -CodePage 437 | Should -BeTrue
    }

    It 'BREAK-THE-GUARD: the encoding check really rejects a character CP850 lacks' {
        # 9581 = U+256D, a rounded corner -- exactly what the first mascot draft used.
        Test-LokiArtFitsEncoding -Lines @([string][char]9581) -CodePage 850 | Should -BeFalse
    }

    It 'the ascii banner is pure ASCII, so it survives ANY code page' {
        $art = Get-LokiBrandArt -Tier 'ascii' -Width 80
        foreach ($l in @($art)) {
            foreach ($ch in ([string]$l).ToCharArray()) { ([int][char]$ch) | Should -BeLessThan 128 }
        }
        Test-LokiArtFitsEncoding -Lines $art -CodePage 1252 | Should -BeTrue
    }

    It 'rich and oem draw the SAME picture (one design, deliberately)' {
        $rich = Get-LokiBrandArt -Tier 'rich' -Width 80
        $oem = Get-LokiBrandArt -Tier 'oem' -Width 80
        (@($rich) -join '|') | Should -Be (@($oem) -join '|')
    }

    It 'a narrow console gets ONE line instead of a wrapped ruin' -ForEach @(
        @{ tier = 'oem' }, @{ tier = 'ascii' }
    ) {
        $narrow = Get-LokiBrandArt -Tier $tier -Width 30
        @($narrow).Count | Should -Be 1
        ([string]@($narrow)[0]).Length | Should -BeLessThan 30
    }

    It 'no banner line is wider than the console it was asked for' -ForEach @(
        @{ w = 34 }, @{ w = 40 }, @{ w = 80 }, @{ w = 120 }
    ) {
        foreach ($tier in @('oem', 'ascii')) {
            foreach ($l in @(Get-LokiBrandArt -Tier $tier -Width $w)) {
                ([string]$l).Length | Should -BeLessOrEqual $w -Because "tier $tier at width $w must not overflow"
            }
        }
    }

    It 'BREAK-THE-GUARD: an unknown tier is refused, never drawn as something else' {
        { Get-LokiBrandArt -Tier 'fantasy' -Width 80 } | Should -Throw
    }
}

Describe 'the serpent (spinner)' {
    It 'frames are equal width, so the line never jitters' -ForEach @(
        @{ tier = 'oem' }, @{ tier = 'ascii' }
    ) {
        $produced = Get-LokiSpinnerFrameSet -Tier $tier
        $frames = @($produced)
        $frames.Count | Should -BeGreaterThan 1
        $widths = @($frames | ForEach-Object { $_.Length } | Sort-Object -Unique)
        $widths.Count | Should -Be 1 -Because 'a changing width makes the spinner flicker sideways'
    }

    It 'frames use only characters their own tier can encode' {
        Test-LokiArtFitsEncoding -Lines @(Get-LokiSpinnerFrameSet -Tier 'oem') -CodePage 850 | Should -BeTrue
        Test-LokiArtFitsEncoding -Lines @(Get-LokiSpinnerFrameSet -Tier 'ascii') -CodePage 1252 | Should -BeTrue
    }

    It 'the coil actually MOVES: consecutive frames differ' {
        $produced = Get-LokiSpinnerFrameSet -Tier 'oem'
        $frames = @($produced)
        for ($i = 1; $i -lt $frames.Count; $i++) {
            $frames[$i] | Should -Not -Be $frames[$i - 1]
        }
    }

    It 'any index is legal, including a negative one' {
        # A caller counting down, or an int that wrapped, must not take the display with it.
        (Get-LokiSpinnerFrame -Tier 'oem' -Index 0) | Should -Not -BeNullOrEmpty
        (Get-LokiSpinnerFrame -Tier 'oem' -Index 999) | Should -Not -BeNullOrEmpty
        (Get-LokiSpinnerFrame -Tier 'oem' -Index -1) | Should -Not -BeNullOrEmpty
        (Get-LokiSpinnerFrame -Tier 'oem' -Index 6) | Should -Be (Get-LokiSpinnerFrame -Tier 'oem' -Index 0)
    }
}

Describe 'Get-LokiGuideState -OnStep' {
    It 'reports one step per probe, and a throwing callback cannot break the diagnosis' {
        # The callback is decoration. Decoration that can fail the thing it decorates is worse than no decoration.
        . "$PSScriptRoot\..\src\lib\guide.ps1"
        $missing = Join-Path ([System.IO.Path]::GetTempPath()) ('loki-brand-' + [guid]::NewGuid().ToString('N'))
        $count = [ref]0
        $state = Get-LokiGuideState -AppRoot $missing -Config @{} -SkipNetwork -OnStep { $count.Value++ }.GetNewClosure()
        $count.Value | Should -BeGreaterThan 0 -Because 'the spinner would never move otherwise'
        $state.EngineOk | Should -BeFalse

        $boom = Get-LokiGuideState -AppRoot $missing -Config @{} -SkipNetwork -OnStep { throw 'decorative failure' }
        $boom.EngineOk | Should -BeFalse -Because 'a broken spinner must not take the state with it'
        # Swallowed on purpose, but NOT discarded: a spinner that has been broken for months and left no
        # trace anywhere is a bug nobody would ever go looking for.
        $boom.StepError | Should -Be 'decorative failure'
        $state.StepError | Should -Be '' -Because 'a healthy run records no failure'
    }
}

Describe 'spinner throttle (issue #125)' {
    # 1 ms = 10,000 ticks.
    It 'the first tick always draws' {
        Test-LokiSpinnerDue -LastTicks 0 -NowTicks 123456789 | Should -BeTrue
    }

    It 'inside the interval it does NOT draw' {
        $now = [long]10000000000
        Test-LokiSpinnerDue -LastTicks ($now - 400000) -NowTicks $now -MinIntervalMs 80 | Should -BeFalse
    }

    It 'past the interval it draws' {
        $now = [long]10000000000
        Test-LokiSpinnerDue -LastTicks ($now - 1000000) -NowTicks $now -MinIntervalMs 80 | Should -BeTrue
    }

    It 'a clock that ran backwards draws instead of freezing' {
        # DST, a corrected system time, a VM resuming from a snapshot. Waiting for the difference to be made up
        # would leave the spinner dead for exactly as long as the jump.
        Test-LokiSpinnerDue -LastTicks 20000000000 -NowTicks 10000000000 | Should -BeTrue
    }

    It 'WHY the throttle exists: the best tick point calls the writer tens of thousands of times' {
        # A 5 GB model through the 128 KB copy loop. Unthrottled, drawing the spinner would cost more than the
        # download it reports on.
        [int](5GB / 131072) | Should -BeGreaterThan 30000
    }
}
