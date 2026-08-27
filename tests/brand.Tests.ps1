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
        # Derived, not hardcoded: this pins that the index WRAPS, which is the contract, rather than how many
        # frames the animation happens to have. The literal 6 that used to stand here went red the day the coil
        # was redrawn, and the number was never what the test was about.
        #
        # ASSIGN FIRST, then wrap. Get-LokiSpinnerFrameSet ends in `return , @(...)`, so @(FUNC).Count is 1 -- the
        # wrapper, not the frames. Written the short way this test went red against a perfectly correct animation.
        $produced = Get-LokiSpinnerFrameSet -Tier 'oem'
        $count = @($produced).Count
        $count | Should -BeGreaterThan 1 -Because 'a count of 1 here means the comma trap bit again, not that there is one frame'
        (Get-LokiSpinnerFrame -Tier 'oem' -Index $count) | Should -Be (Get-LokiSpinnerFrame -Tier 'oem' -Index 0)
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

Describe 'Get-LokiBoxArt' {
    It 'the oem frame uses ONLY characters CP850 and CP437 can both hold' {
        # The same guard as the banner above, and for the same reason: the rounded corners this frame would
        # otherwise use (U+256D..U+2570) are absent from CP850, which is what a German Windows console runs.
        # That is the shape issue #121 took. If someone reaches for a rounded corner, this goes red first.
        $box = Get-LokiBoxArt -Tier 'oem' -Width 40 -Lines @('working', '[####------]  4/10')
        @($box).Count | Should -Be 4 -Because 'two content lines plus a top and a bottom'
        Test-LokiArtFitsEncoding -Lines $box -CodePage 850 | Should -BeTrue
        Test-LokiArtFitsEncoding -Lines $box -CodePage 437 | Should -BeTrue
    }

    It 'BREAK-THE-GUARD: the encoding check can actually fail' {
        # Without this, the assertion above would be equally green if Test-LokiArtFitsEncoding always said yes.
        Test-LokiArtFitsEncoding -Lines @('rounded ' + [char]0x256D) -CodePage 850 | Should -BeFalse
    }

    It 'the ascii frame is pure ASCII' {
        $box = Get-LokiBoxArt -Tier 'ascii' -Width 40 -Lines @('working')
        foreach ($line in $box) {
            foreach ($ch in $line.ToCharArray()) { [int][char]$ch | Should -BeLessThan 128 }
        }
    }

    It 'every line is exactly the requested width' {
        foreach ($tier in @('rich', 'oem', 'ascii')) {
            foreach ($width in @(12, 40, 80, 209)) {
                $box = Get-LokiBoxArt -Tier $tier -Width $width -Lines @('a', 'bb')
                foreach ($line in $box) {
                    $line.Length | Should -Be $width -Because "$tier at $width must not be ragged"
                }
            }
        }
    }

    It 'truncates content rather than letting it wrap' {
        # A frame line one character too long wraps onto the next row, and a region that is one row taller
        # than its anchor thinks is a region that eats the line above it.
        $box = Get-LokiBoxArt -Tier 'ascii' -Width 20 -Lines @('x' * 200)
        foreach ($line in $box) { $line.Length | Should -Be 20 }
    }

    It 'collapses to the bare lines when there is no room to frame them' {
        $box = Get-LokiBoxArt -Tier 'oem' -Width 8 -Lines @('abc', 'de')
        @($box) | Should -Be @('abc', 'de') -Because 'all border and no content is worse than no border'
    }

    It 'survives empty and null content' {
        @(Get-LokiBoxArt -Tier 'oem' -Width 20 -Lines @()).Count | Should -Be 2
        @(Get-LokiBoxArt -Tier 'oem' -Width 20 -Lines $null).Count | Should -Be 2
        @(Get-LokiBoxArt -Tier 'oem' -Width 20 -Lines @('')).Count | Should -Be 3
    }

    It 'pads short content so nothing survives underneath it' {
        $box = Get-LokiBoxArt -Tier 'ascii' -Width 20 -Lines @('hi')
        $box[1] | Should -Be '| hi               |'
    }
}

Describe 'the oem art is actually oem art' {
    # These exist because the encoding assertions elsewhere in this file CANNOT catch the obvious regression.
    # "Does it fit CP850" is satisfied perfectly by plain ASCII, so a frame or a serpent quietly rewritten to
    # +---+ and -~-- would pass every other check in the suite while losing the entire point of having tiers.
    #
    # Found the hard way: a review agent mutated exactly that, to demonstrate a test could fail, and nothing
    # went red. The gap was real and it was mine.

    It 'the frame is drawn from box-drawing characters, not ASCII lookalikes' {
        $box = Get-LokiBoxArt -Tier 'oem' -Width 40 -Lines @('x')
        [int][char]$box[0][0] | Should -Be 0x250C -Because 'top-left must be a real corner'
        [int][char]$box[0][1] | Should -Be 0x2500 -Because 'the rule must be a real horizontal line'
        [int][char]$box[1][0] | Should -Be 0x2502 -Because 'the side must be a real vertical line'
        $last = @($box)[-1]
        [int][char]$last[0] | Should -Be 0x2514 -Because 'bottom-left must be a real corner'
    }

    It 'the frame uses NO rounded corner, at any tier' {
        # U+256D..U+2570 are absent from CP850 -- the shape issue #121 took. Assert it directly rather than
        # trusting that nobody reaches for the prettier character later.
        foreach ($tier in @('rich', 'oem', 'ascii')) {
            $box = Get-LokiBoxArt -Tier $tier -Width 40 -Lines @('x')
            foreach ($line in $box) {
                foreach ($ch in $line.ToCharArray()) {
                    [int][char]$ch | Should -Not -BeIn @(0x256D, 0x256E, 0x256F, 0x2570)
                }
            }
        }
    }

    It 'the serpent head is the square the mascot already owns' {
        # ASSIGN FIRST, then wrap: Get-LokiSpinnerFrameSet ends in `return , @(...)`.
        $produced = Get-LokiSpinnerFrameSet -Tier 'oem'
        $frames = @($produced)
        $frames.Count | Should -BeGreaterThan 1
        foreach ($f in $frames) {
            $f.IndexOf([char]0x25A0) | Should -BeGreaterOrEqual 0 -Because 'every frame carries the head'
        }
    }

    It 'the serpent head shares no character with the frame' {
        # The whole reason the coil was redrawn: a head made of border characters, printed next to a border,
        # reads as broken border. If someone reintroduces one, this is where it stops.
        $frameChars = @(0x250C, 0x2510, 0x2514, 0x2518, 0x2502)
        $produced = Get-LokiSpinnerFrameSet -Tier 'oem'
        foreach ($f in @($produced)) {
            foreach ($ch in $f.ToCharArray()) {
                [int][char]$ch | Should -Not -BeIn $frameChars
            }
        }
    }
}
