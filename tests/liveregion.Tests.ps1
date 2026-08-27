# tests/liveregion.Tests.ps1 -- the pure half of the bottom-anchored live region (issue #130).
#
# The whole point of putting the decisions in pure functions is that CI can never see the console:
# build/Invoke-Checks.ps1 runs Pester in a process whose stdout is a pipe, which is precisely the
# condition under which the region refuses to engage. So everything that decides anything is tested
# here, and what is left over is drawing -- which needs a human and is listed as such.
#
# The most important test in this file is the LAST one: it fails on purpose if the anchor's refusal
# is turned back into a clamp. That mutation is here because the probe this design rests on was
# measured, with 28 deliberately wrong anchors, to report a flawless run -- a check nobody can make
# go red is not a check.
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\ui.ps1"
    . "$PSScriptRoot\..\src\lib\liveregion.ps1"

    # The geometry actually measured in Windows Terminal, so the happy path is not a fantasy.
    function global:New-LokiTestGeometry {
        param([hashtable]$Override = @{})
        $g = @{
            HostName         = 'ConsoleHost'
            OutputRedirected = $false
            InputRedirected  = $false
            Plain            = $false
            WindowWidth      = 209
            WindowHeight     = 51
            BufferWidth      = 209
            BufferHeight     = 51
            RegionHeight     = 2
        }
        foreach ($k in $Override.Keys) { $g[$k] = $Override[$k] }
        return $g
    }
}

Describe 'Get-LokiRegionCapability' {

    It 'engages on the geometry that was actually measured' {
        $g = New-LokiTestGeometry
        $r = Get-LokiRegionCapability @g
        $r.Engage | Should -BeTrue
        $r.Reason | Should -Be 'ok'
    }

    It 'refuses for exactly one stated reason per hostile condition' {
        # Table-driven, one row per Reason token, so a new refusal cannot be added without naming it.
        $cases = @(
            @{ Reason = 'plain';         Override = @{ Plain = $true } },
            @{ Reason = 'redirected';    Override = @{ OutputRedirected = $true } },
            @{ Reason = 'redirected';    Override = @{ InputRedirected = $true } },
            @{ Reason = 'host';          Override = @{ HostName = 'Windows PowerShell ISE Host' } },
            @{ Reason = 'host';          Override = @{ HostName = '' } },
            @{ Reason = 'region-height'; Override = @{ RegionHeight = 0 } },
            @{ Reason = 'buffer-short';  Override = @{ BufferHeight = 40 } },
            @{ Reason = 'buffer-wide';   Override = @{ BufferWidth = 240 } },
            @{ Reason = 'window-short';  Override = @{ WindowHeight = 3; BufferHeight = 3 } },
            @{ Reason = 'window-narrow'; Override = @{ WindowWidth = 39; BufferWidth = 39 } }
        )
        foreach ($c in $cases) {
            $g = New-LokiTestGeometry -Override $c.Override
            $r = Get-LokiRegionCapability @g
            $r.Engage | Should -BeFalse -Because "$($c.Reason) must refuse"
            $r.Reason | Should -Be $c.Reason
        }
    }

    It 'ALLOWS a buffer taller than its window -- the conhost scrollback regime' {
        # Load-bearing, and the opposite of what the first design draft proposed. This is the
        # configuration measured with the hardened probe (3000-row buffer behind a 50-row window,
        # anchor row constant at 2997 across 200 repaints and 20 scroll events). Refusing it would
        # switch the region off in the console a portable diagnostic stick most often lands in.
        $g = New-LokiTestGeometry -Override @{ WindowWidth = 120; WindowHeight = 50; BufferWidth = 120; BufferHeight = 3000 }
        $r = Get-LokiRegionCapability @g
        $r.Engage | Should -BeTrue
        $r.Reason | Should -Be 'ok'
    }

    It 'answers the operator before it answers anything else' {
        # Order matters because Reason is what gets shown. --plain on a hopeless console must still
        # say 'plain': the operator asked, and that is the more useful answer.
        $g = New-LokiTestGeometry -Override @{ Plain = $true; OutputRedirected = $true; HostName = 'Nope'; WindowWidth = 10; BufferWidth = 10 }
        (Get-LokiRegionCapability @g).Reason | Should -Be 'plain'
    }

    It 'returns the same shape for every answer' {
        $ge = New-LokiTestGeometry
        $gr = New-LokiTestGeometry -Override @{ Plain = $true }
        $engaged = Get-LokiRegionCapability @ge
        $refused = Get-LokiRegionCapability @gr
        @($engaged.PSObject.Properties.Name | Sort-Object) -join ',' | Should -Be 'Engage,Reason'
        @($refused.PSObject.Properties.Name | Sort-Object) -join ',' | Should -Be 'Engage,Reason'
    }
}

Describe 'Get-LokiRegionCellWidth' {
    It 'stays one column short of the window' {
        Get-LokiRegionCellWidth -WindowWidth 209 | Should -Be 208
        Get-LokiRegionCellWidth -WindowWidth 120 | Should -Be 119
        Get-LokiRegionCellWidth -WindowWidth 80  | Should -Be 79
    }

    It 'never returns a width that cannot hold a character' {
        Get-LokiRegionCellWidth -WindowWidth 1 | Should -Be 1
        Get-LokiRegionCellWidth -WindowWidth 0 | Should -Be 1
    }
}

Describe 'Get-LokiRegionAnchor' {
    It 'is the cursor row minus the height' {
        Get-LokiRegionAnchor -CursorTop 50 -RegionHeight 2 | Should -Be 48
        Get-LokiRegionAnchor -CursorTop 25 -RegionHeight 2 | Should -Be 23
        Get-LokiRegionAnchor -CursorTop 2999 -RegionHeight 2 | Should -Be 2997
    }

    It 'REFUSES rather than clamps when the region does not fit' {
        # -1, not 0. See the mutation test at the bottom of this file for why that distinction is
        # not a matter of taste.
        Get-LokiRegionAnchor -CursorTop 1 -RegionHeight 2 | Should -Be -1
        Get-LokiRegionAnchor -CursorTop 0 -RegionHeight 1 | Should -Be -1
        Get-LokiRegionAnchor -CursorTop 50 -RegionHeight 0 | Should -Be -1
    }

    It 'is exact at the boundary' {
        Get-LokiRegionAnchor -CursorTop 2 -RegionHeight 2 | Should -Be 0
    }
}

Describe 'Format-LokiRegionLine' {
    It 'always returns exactly CellWidth characters' {
        foreach ($text in @('', 'short', ('x' * 300))) {
            (Format-LokiRegionLine -Text $text -CellWidth 40).Length | Should -Be 40 -Because "'$text' must be padded or cut to the cell width"
        }
    }

    It 'pads on the right so nothing survives underneath' {
        Format-LokiRegionLine -Text 'ab' -CellWidth 5 | Should -Be 'ab   '
    }

    It 'truncates rather than wrapping' {
        Format-LokiRegionLine -Text 'abcdef' -CellWidth 3 | Should -Be 'abc'
    }

    It 'survives a null and a nonsensical width' {
        Format-LokiRegionLine -Text $null -CellWidth 3 | Should -Be '   '
        Format-LokiRegionLine -Text 'abc' -CellWidth 0 | Should -Be ''
    }
}

Describe 'Format-LokiRegionFrame' {
    It 'is ONE string that carries its own trailing newline' {
        # The flicker fix, asserted rather than hoped for: the frame and the scroll it causes must be
        # able to reach the console in a single write. Reported symptom was a flicker on exactly the
        # frames where the footer slid down a row, i.e. the frames where Write-Host's separate
        # trailing newline triggered the scroll.
        $frame = Format-LokiRegionFrame -Lines @('a', 'b') -CellWidth 4
        $frame | Should -Be "a   `r`nb   `r`n"
    }

    It 'joins with CRLF and never with a bare LF' {
        # A bare LF moves down without resetting the column, so the next line of a padded full-width
        # frame would start at the right-hand edge.
        $frame = Format-LokiRegionFrame -Lines @('a', 'b', 'c') -CellWidth 2
        ([regex]::Matches($frame, "`r`n")).Count | Should -Be 3
        ([regex]::Matches($frame, "(?<!`r)`n")).Count | Should -Be 0
    }

    It 'pads every line to the same width' {
        $frame = Format-LokiRegionFrame -Lines @('x', 'longer text') -CellWidth 6
        foreach ($line in ($frame -split "`r`n" | Where-Object { $_ -ne '' })) {
            $line.Length | Should -Be 6
        }
    }

    It 'returns nothing for nothing' {
        Format-LokiRegionFrame -Lines @() -CellWidth 10 | Should -Be ''
        Format-LokiRegionFrame -Lines $null -CellWidth 10 | Should -Be ''
    }
}

Describe 'Test-LokiRegionTextSafe' {
    BeforeAll {
        $script:cp850 = [System.Text.Encoding]::GetEncoding(850)
    }

    It 'accepts the ASCII the region actually draws' {
        Test-LokiRegionTextSafe -Text '  [ok] battery 3 collected' -Encoding $script:cp850 | Should -BeTrue
        Test-LokiRegionTextSafe -Text '' -Encoding $script:cp850 | Should -BeTrue
    }

    It 'rejects a character whose console width is not its string length' {
        # PadRight counts UTF-16 units, so each of these makes the line the wrong number of CELLS --
        # and a line one cell too wide can wrap and add a row the anchor knows nothing about.
        Test-LokiRegionTextSafe -Text ('a' + [char]0x0301) -Encoding $script:cp850 | Should -BeFalse  # combining acute
        Test-LokiRegionTextSafe -Text ([string][char]0x4E2D) -Encoding $script:cp850 | Should -BeFalse  # CJK ideograph
        Test-LokiRegionTextSafe -Text ([string][char]0xFF21) -Encoding $script:cp850 | Should -BeFalse  # fullwidth A
    }

    It 'rejects control characters, which are cursor motion in disguise' {
        Test-LokiRegionTextSafe -Text "a`tb" -Encoding $script:cp850 | Should -BeFalse
        Test-LokiRegionTextSafe -Text "a`rb" -Encoding $script:cp850 | Should -BeFalse
        Test-LokiRegionTextSafe -Text "a`nb" -Encoding $script:cp850 | Should -BeFalse
    }

    It 'rejects text this console would silently substitute' {
        # The issue #121 failure mode: CP850 does not refuse U+2713, it best-fits it to the letter V.
        Test-LokiRegionTextSafe -Text ([string][char]0x2713) -Encoding $script:cp850 | Should -BeFalse
        Test-LokiRegionTextSafe -Text ([string][char]0x2713) -Encoding ([System.Text.Encoding]::UTF8) | Should -BeTrue
    }

    It 'refuses when it cannot tell -- a null encoding is not a yes' {
        Test-LokiRegionTextSafe -Text 'plain ascii' -Encoding $null | Should -BeFalse
    }
}

Describe 'Test-LokiRegionGeometryChanged' {
    It 'notices a change on EITHER axis' {
        # The probe polled only the width, so a purely vertical resize would have passed straight
        # through it -- and a vertical resize is exactly what moves a bottom-anchored region.
        Test-LokiRegionGeometryChanged -Width 209 -Height 51 -KnownWidth 209 -KnownHeight 51 | Should -BeFalse
        Test-LokiRegionGeometryChanged -Width 208 -Height 51 -KnownWidth 209 -KnownHeight 51 | Should -BeTrue
        Test-LokiRegionGeometryChanged -Width 209 -Height 50 -KnownWidth 209 -KnownHeight 51 | Should -BeTrue
    }
}

Describe 'the anchor refusal, mutated' {
    It 'goes red if the refusal is turned back into a clamp' {
        # THE DELIBERATE BREAK (CLAUDE.md section 6). The probe that this whole design rests on
        # clamped a negative anchor to row 0, and with 28 deliberately wrong anchors injected it
        # still reported zero drifted cells -- the region simply drew over the top of the screen and
        # every cell comparison agreed with itself. So this asserts the difference between refusing
        # and relocating, in the one place where the distinction is invisible to every other check.
        $clamped = {
            param($CursorTop, $RegionHeight)
            $a = $CursorTop - $RegionHeight
            if ($a -lt 0) { return 0 }   # the mutation: relocate instead of refuse
            return $a
        }
        $real = Get-LokiRegionAnchor -CursorTop 1 -RegionHeight 2
        $mut  = & $clamped 1 2
        $real | Should -Be -1
        $mut  | Should -Be 0
        $real | Should -Not -Be $mut -Because 'if these ever agree, this test has stopped measuring the difference'
    }
}

Describe 'the region state machine' {
    # Everything below drives the three impure primitives through mocks, so every path runs headless
    # -- including the ones a real console would never reach on a build agent. Get-LokiConsoleFact is
    # the single point where the console is read, which is what makes that possible.
    BeforeEach {
        # Initialize, not Close: 'disabled' outlives a close on purpose, so without this the resize
        # and unsafe-text cases would silently switch the region off for every test after them.
        Initialize-LokiRegion
        $script:written = New-Object System.Collections.ArrayList
        $script:moved = New-Object System.Collections.ArrayList
        Mock -CommandName Get-LokiConsoleFact -MockWith {
            @{
                HostName = 'ConsoleHost'; OutputRedirected = $false; InputRedirected = $false
                WindowWidth = 209; WindowHeight = 51; BufferWidth = 209; BufferHeight = 51
                CursorTop = 50
            }
        }
        Mock -CommandName Write-LokiConsole -MockWith { [void]$script:written.Add($Text) }
        Mock -CommandName Move-LokiCursor -MockWith { [void]$script:moved.Add($Row); return $true }
    }

    AfterAll { Initialize-LokiRegion }

    It 'opens on a measured console and reserves exactly Height rows' {
        Open-LokiRegion -Height 2 | Should -BeTrue
        Test-LokiRegionOpen | Should -BeTrue
        Get-LokiRegionRefusal | Should -Be 'ok'
        $script:written.Count | Should -Be 1
        # two padded lines of 208 characters, each followed by CRLF
        $script:written[0].Length | Should -Be (2 * (208 + 2))
    }

    It 'refuses without writing anything at all when the console is hostile' {
        Mock -CommandName Get-LokiConsoleFact -MockWith {
            @{
                HostName = 'ConsoleHost'; OutputRedirected = $true; InputRedirected = $false
                WindowWidth = 209; WindowHeight = 51; BufferWidth = 209; BufferHeight = 51
                CursorTop = 50
            }
        }
        Open-LokiRegion -Height 2 | Should -BeFalse
        Test-LokiRegionOpen | Should -BeFalse
        Get-LokiRegionRefusal | Should -Be 'redirected'
        $script:written.Count | Should -Be 0 -Because 'a refusal that still prints is not a refusal'
        $script:moved.Count | Should -Be 0
    }

    It 'refuses when the console cannot be read at all' {
        Mock -CommandName Get-LokiConsoleFact -MockWith { return $null }
        Open-LokiRegion -Height 2 | Should -BeFalse
        Get-LokiRegionRefusal | Should -Be 'no-console'
    }

    It 'repaints with ONE console write, at the anchor, and nowhere else' {
        Open-LokiRegion -Height 2 | Should -BeTrue
        $script:written.Clear(); $script:moved.Clear()
        Write-LokiRegion -Lines @('serpent', 'progress')
        $script:written.Count | Should -Be 1 -Because 'the frame and the scroll it causes must reach the console together'
        $script:moved.Count | Should -Be 1
        $script:moved[0] | Should -Be 48 -Because 'CursorTop 50 minus a height of 2'
        $script:written[0] | Should -BeLike 'serpent*progress*'
    }

    It 'does nothing at all when no region is open' {
        Write-LokiRegion -Lines @('ignored')
        $script:written.Count | Should -Be 0
        $script:moved.Count | Should -Be 0
    }

    It 'closes for good on a resize instead of repainting into reflowed rows' {
        Open-LokiRegion -Height 2 | Should -BeTrue
        Mock -CommandName Get-LokiConsoleFact -MockWith {
            @{
                HostName = 'ConsoleHost'; OutputRedirected = $false; InputRedirected = $false
                WindowWidth = 100; WindowHeight = 51; BufferWidth = 100; BufferHeight = 51
                CursorTop = 50
            }
        }
        Write-LokiRegion -Lines @('a', 'b')
        Test-LokiRegionOpen | Should -BeFalse
        Get-LokiRegionRefusal | Should -Be 'resized'
        # and it stays refused for the rest of the process rather than reopening into the same trap
        Open-LokiRegion -Height 2 | Should -BeFalse
        Get-LokiRegionRefusal | Should -Be 'disabled'
    }

    It 'stops drawing rather than draw text whose width it cannot predict' {
        Open-LokiRegion -Height 2 | Should -BeTrue
        Write-LokiRegion -Lines @(([string][char]0x4E2D), 'b')
        Test-LokiRegionOpen | Should -BeFalse
        Get-LokiRegionRefusal | Should -Be 'unsafe-text'
    }

    It 'closes when the cursor refuses to move' {
        Open-LokiRegion -Height 2 | Should -BeTrue
        Mock -CommandName Move-LokiCursor -MockWith { return $false }
        Write-LokiRegion -Lines @('a', 'b')
        Test-LokiRegionOpen | Should -BeFalse
        Get-LokiRegionRefusal | Should -Be 'cursor'
    }

    It 'erases on close and parks the cursor back at the top of the region' {
        Open-LokiRegion -Height 2 | Should -BeTrue
        $script:written.Clear(); $script:moved.Clear()
        Close-LokiRegion
        Test-LokiRegionOpen | Should -BeFalse
        $script:written.Count | Should -Be 1
        $script:written[0].Trim() | Should -Be '' -Because 'closing writes blanks, not text'
        @($script:moved) | Should -Be @(48, 48) -Because 'once to erase, once to park'
    }

    It 'is idempotent -- closing twice is not an error and writes nothing the second time' {
        Open-LokiRegion -Height 2 | Should -BeTrue
        Close-LokiRegion
        $script:written.Clear()
        Close-LokiRegion
        $script:written.Count | Should -Be 0
    }
}

Describe 'the write seam' {
    # The whole answer to "ordinary output landed on top of the footer". Asserted rather than trusted,
    # because Write-LokiWarn and Write-LokiErr bypass Write-Host entirely and appear on dozens of
    # source lines -- one unguarded path is enough to print straight through an open region.
    BeforeEach {
        Initialize-LokiRegion
        Register-LokiWriteHook -Hook $null
    }

    It 'fires the hook before ordinary output and exactly once' {
        $script:fired = 0
        Register-LokiWriteHook -Hook { $script:fired++ }
        Mock -CommandName Write-LokiConsole -MockWith { }
        Write-LokiRaw -Text 'hello'
        Write-LokiRaw -Text 'again'
        $script:fired | Should -Be 1 -Because 'the region closes once, not once per line'
    }

    It 'does NOT fire the hook for the region own writes' {
        $script:fired = 0
        Register-LokiWriteHook -Hook { $script:fired++ }
        Mock -CommandName Write-LokiConsole -MockWith { }
        Write-LokiConsole -Text 'the region drawing itself'
        $script:fired | Should -Be 0 -Because 'a region redrawing through a hook that closes it is a loop'
    }

    It 'records a throwing hook instead of taking the output down with it' {
        Register-LokiWriteHook -Hook { throw 'the region broke' }
        Mock -CommandName Write-LokiConsole -MockWith { }
        { Write-LokiRaw -Text 'must still print' } | Should -Not -Throw
        Get-LokiWriteHookError | Should -BeLike '*the region broke*'
    }

    It 'closes an open region before stderr, not only before stdout' {
        Mock -CommandName Get-LokiConsoleFact -MockWith {
            @{
                HostName = 'ConsoleHost'; OutputRedirected = $false; InputRedirected = $false
                WindowWidth = 209; WindowHeight = 51; BufferWidth = 209; BufferHeight = 51
                CursorTop = 50
            }
        }
        Mock -CommandName Write-LokiConsole -MockWith { }
        Mock -CommandName Move-LokiCursor -MockWith { return $true }
        Open-LokiRegion -Height 2 | Should -BeTrue
        Write-LokiWarn -Text 'something is wrong'
        Test-LokiRegionOpen | Should -BeFalse -Because 'Write-LokiErr alone appears on dozens of source lines'
    }
}

Describe 'Get-LokiRegionWidth' {
    It 'is 0 when nothing is open and the cell width when something is' {
        Initialize-LokiRegion
        Get-LokiRegionWidth | Should -Be 0
        Mock -CommandName Get-LokiConsoleFact -MockWith {
            @{
                HostName = 'ConsoleHost'; OutputRedirected = $false; InputRedirected = $false
                WindowWidth = 209; WindowHeight = 51; BufferWidth = 209; BufferHeight = 51
                CursorTop = 50
            }
        }
        Mock -CommandName Write-LokiConsole -MockWith { }
        Mock -CommandName Move-LokiCursor -MockWith { return $true }
        Open-LokiRegion -Height 4 | Should -BeTrue
        Get-LokiRegionWidth | Should -Be 208 -Because 'one column short of the window, as Get-LokiRegionCellWidth decides'
        Close-LokiRegion
        Get-LokiRegionWidth | Should -Be 0
    }
}