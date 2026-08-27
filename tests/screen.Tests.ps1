# tests/screen.Tests.ps1 -- the owned screen (issue #133).
#
# CI runs Pester in a process whose stdout is a pipe, which is exactly the condition under which the
# screen refuses to engage. So every decision lives in a pure function and is tested here; the two
# console primitives are mocked, and what is left over is drawing, which needs a human.
#
# Two tests in this file exist to fail on purpose, and they are the ones worth reading:
#
#   'a [string[]] parameter would silently lose the write'  -- reproduces the trap that
#       Write-LokiScreenCell is shaped to avoid. Measured 2026-08-26: with a [string[]] parameter,
#       every cell write lands in a copy, the model never changes, and the read-back self-check
#       reports ZERO mismatches because it compares two unchanged things. Same wrong-against-wrong
#       failure that let 28 deliberately bad anchors through the first live-region probe.
#
#   'the read-back check goes red when the console disagrees' -- if the self-check at open cannot be
#       made to fail, it is decoration.
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\ui.ps1"
    . "$PSScriptRoot\..\src\lib\liveregion.ps1"   # Get-LokiConsoleFact lives there; see the debt note in screen.ps1
    . "$PSScriptRoot\..\src\lib\screen.ps1"

    # A function, not a global variable: PSAvoidGlobalVars is on, and Pester's BeforeAll scope does
    # not reach into It blocks for variables the way it does for functions.
    function global:Get-LokiTestEsc { return [string][char]27 }
    function global:Get-LokiTestEscPattern { return [regex]::Escape([string][char]27) }

    # The geometry actually measured in the conhost run, so the happy path is not a fantasy.
    function global:New-LokiTestScreenGeometry {
        param([hashtable]$Override = @{})
        $g = @{
            HostName         = 'ConsoleHost'
            OutputRedirected = $false
            InputRedirected  = $false
            Plain            = $false
            VtActive         = $true
            WindowWidth      = 120
            WindowHeight     = 30
        }
        foreach ($k in $Override.Keys) { $g[$k] = $Override[$k] }
        return $g
    }
}

Describe 'Get-LokiScreenCapability' {
    It 'engages on the geometry that was measured' {
        $g = New-LokiTestScreenGeometry
        $c = Get-LokiScreenCapability @g
        $c.Engage | Should -BeTrue
        $c.Reason | Should -Be 'ok'
    }

    It 'engages on the smallest window measured to work' {
        # 63x8 in the ConPTY regime: alternate screen entered and left, 0 of 8 rows changed.
        $g = New-LokiTestScreenGeometry @{ WindowWidth = 63; WindowHeight = 8 }
        (Get-LokiScreenCapability @g).Engage | Should -BeTrue
    }

    It 'refuses without VT, because there is no alternate screen to enter' {
        $g = New-LokiTestScreenGeometry @{ VtActive = $false }
        $c = Get-LokiScreenCapability @g
        $c.Engage | Should -BeFalse
        $c.Reason | Should -Be 'no-vt'
    }

    It 'refuses a redirected handle' {
        # Splat from a VARIABLE. `@(...)` in front of a parenthesis is the array operator, not
        # splatting, so the hashtable arrives as one positional argument and binds to -HostName.
        $out = New-LokiTestScreenGeometry @{ OutputRedirected = $true }
        (Get-LokiScreenCapability @out).Reason | Should -Be 'redirected'
        $in = New-LokiTestScreenGeometry @{ InputRedirected = $true }
        (Get-LokiScreenCapability @in).Reason | Should -Be 'redirected'
    }

    It 'refuses a host that is not ConsoleHost' {
        $g = New-LokiTestScreenGeometry @{ HostName = 'Windows PowerShell ISE Host' }
        (Get-LokiScreenCapability @g).Reason | Should -Be 'host'
    }

    It 'refuses a window smaller than anything measured' {
        $short = New-LokiTestScreenGeometry @{ WindowHeight = 7 }
        (Get-LokiScreenCapability @short).Reason | Should -Be 'window-short'
        $narrow = New-LokiTestScreenGeometry @{ WindowWidth = 39 }
        (Get-LokiScreenCapability @narrow).Reason | Should -Be 'window-narrow'
    }

    It 'lets -Plain beat every capability question, including a broken one' {
        $g = New-LokiTestScreenGeometry @{ Plain = $true; VtActive = $false; OutputRedirected = $true }
        (Get-LokiScreenCapability @g).Reason | Should -Be 'plain'
    }

    It 'asks about the console before it asks about the size' {
        # Order of decisiveness: the operator is better served by "this is a pipe" than by
        # "this window is narrow" when both are true.
        $g = New-LokiTestScreenGeometry @{ OutputRedirected = $true; WindowWidth = 10; WindowHeight = 2 }
        (Get-LokiScreenCapability @g).Reason | Should -Be 'redirected'
    }

    It 'says nothing about the buffer, because both regimes were measured to work' {
        # The live region's gate refuses buffer-short and buffer-wide, because it anchors itself
        # inside someone else's buffer. This owns the screen. If a buffer check ever appears here,
        # it will refuse the conhost scrollback regime that was measured working -- 120x9001 behind
        # a 120x30 window, scrollback marker at the same row before and after.
        $g = New-LokiTestScreenGeometry
        (Get-LokiScreenCapability @g).Engage | Should -BeTrue
        $params = (Get-Command Get-LokiScreenCapability).Parameters.Keys
        $params | Should -Not -Contain 'BufferWidth'
        $params | Should -Not -Contain 'BufferHeight'
    }
}

Describe 'Get-LokiScreenCellWidth' {
    It 'stays one column short of the window' {
        Get-LokiScreenCellWidth -WindowWidth 120 | Should -Be 119
    }
    It 'never returns less than one' {
        Get-LokiScreenCellWidth -WindowWidth 1 | Should -Be 1
        Get-LokiScreenCellWidth -WindowWidth 0 | Should -Be 1
    }
}

Describe 'the virtual screen model' {
    It 'is Height rows of exactly Width spaces' {
        $m = Initialize-LokiScreenModel -Width 10 -Height 3
        @($m).Count | Should -Be 3
        foreach ($row in $m) { $row | Should -Be '          ' }
    }

    It 'is empty for a nonsense size' {
        @(Initialize-LokiScreenModel -Width 0 -Height 5).Count | Should -Be 0
        @(Initialize-LokiScreenModel -Width 5 -Height 0).Count | Should -Be 0
    }

    It 'writes a cell through to the caller array, unguarded' {
        # UNGUARDED on purpose: Initialize-LokiScreenModel returns Object[], and that is exactly what
        # every caller in the codebase hands over. If this ever needs a [string[]] cast to pass, the
        # trap is back.
        $m = Initialize-LokiScreenModel -Width 10 -Height 2
        $m.GetType().FullName | Should -Be 'System.Object[]' -Because 'a return unrolls the array; if this changes the next test stops testing anything'
        Write-LokiScreenCell -Model $m -Row 0 -Col 2 -Text 'AB'
        $m[0] | Should -Be '  AB      '
        $m[1] | Should -Be '          ' -Because 'a cell write touches one row'
    }

    It 'a [string[]] parameter would silently lose the write' {
        # THE MUTATION. This is Write-LokiScreenCell with the one difference that matters, and it
        # proves the trap is real rather than folklore. If this test ever goes green the other way
        # round, PowerShell changed its binding rules and the comment at the top of screen.ps1 is
        # obsolete.
        function Test-LokiMutatedCellWrite {
            param([string[]]$Model, [int]$Row, [int]$Col, [string]$Text)
            $line = $Model[$Row]
            $take = [math]::Min($Text.Length, $line.Length - $Col)
            $Model[$Row] = $line.Substring(0, $Col) + $Text.Substring(0, $take) + $line.Substring($Col + $take)
        }
        $m = Initialize-LokiScreenModel -Width 10 -Height 2
        Test-LokiMutatedCellWrite -Model $m -Row 0 -Col 2 -Text 'AB'
        $m[0] | Should -Be '          ' -Because 'the write landed in a copy, with no error at all'
    }

    It 'clips rather than throws when a widget overruns its box' {
        $m = Initialize-LokiScreenModel -Width 6 -Height 2
        Write-LokiScreenCell -Model $m -Row 0 -Col 4 -Text 'LONGTEXT'
        $m[0] | Should -Be '    LO'
        { Write-LokiScreenCell -Model $m -Row 99 -Col 0 -Text 'x' } | Should -Not -Throw
        { Write-LokiScreenCell -Model $m -Row 0 -Col 99 -Text 'x' } | Should -Not -Throw
        { Write-LokiScreenCell -Model $null -Row 0 -Col 0 -Text 'x' } | Should -Not -Throw
    }
}

Describe 'Format-LokiScreenRow' {
    It 'pads short text to exactly Width' {
        (Format-LokiScreenRow -Text 'ab' -Width 5) | Should -Be 'ab   '
    }
    It 'truncates long text to exactly Width' {
        (Format-LokiScreenRow -Text 'abcdefgh' -Width 3) | Should -Be 'abc'
    }
    It 'turns null and empty into a full row of spaces' {
        (Format-LokiScreenRow -Text $null -Width 4) | Should -Be '    '
        (Format-LokiScreenRow -Text '' -Width 4) | Should -Be '    '
    }
}

Describe 'Test-LokiScreenModelShape' {
    It 'accepts a model of the declared size' {
        Test-LokiScreenModelShape -Model (Initialize-LokiScreenModel -Width 8 -Height 3) -Width 8 -Height 3 | Should -BeTrue
    }
    It 'rejects a wrong row count' {
        Test-LokiScreenModelShape -Model (Initialize-LokiScreenModel -Width 8 -Height 2) -Width 8 -Height 3 | Should -BeFalse
    }
    It 'rejects a single short row' {
        # The dangerous one: one row of the wrong length shifts that row's column arithmetic in the
        # diff and puts text somewhere else, with nothing going red.
        $m = Initialize-LokiScreenModel -Width 8 -Height 3
        $m[1] = 'short'
        Test-LokiScreenModelShape -Model $m -Width 8 -Height 3 | Should -BeFalse
    }
    It 'rejects null and non-arrays' {
        Test-LokiScreenModelShape -Model $null -Width 8 -Height 3 | Should -BeFalse
        Test-LokiScreenModelShape -Model 'not an array' -Width 8 -Height 3 | Should -BeFalse
    }
}

Describe 'Get-LokiScreenDiff' {
    It 'emits nothing when nothing changed' {
        $a = [string[]]@('abcdef', 'xxxxxx')
        (Get-LokiScreenDiff -Old $a -New $a).Length | Should -Be 0
    }

    It 'emits one absolute move and one character for one changed cell' {
        $old = [string[]]@('abcdef', 'xxxxxx')
        $new = [string[]]@('abQdef', 'xxxxxx')
        (Get-LokiScreenDiff -Old $old -New $new) | Should -Be ((Get-LokiTestEsc) + '[1;3HQ')
    }

    It 'covers the whole changed span, not each cell separately' {
        $old = [string[]]@('abcdef')
        $new = [string[]]@('aXYZef')
        (Get-LokiScreenDiff -Old $old -New $new) | Should -Be ((Get-LokiTestEsc) + '[1;2HXYZ')
    }

    It 'addresses rows one-based, like the terminal does' {
        $old = [string[]]@('aaa', 'bbb', 'ccc')
        $new = [string[]]@('aaa', 'bbb', 'cQc')
        (Get-LokiScreenDiff -Old $old -New $new) | Should -Be ((Get-LokiTestEsc) + '[3;2HQ')
    }

    It 'contains no newline and no relative motion, ever' {
        # The reference emits zero relative cursor-ups and zero scroll regions across 1836 frames,
        # and a newline on the last row would scroll the screen the caller believes it owns.
        $old = [string[]]@('aaaa', 'bbbb', 'cccc')
        $new = [string[]]@('aQaa', 'bbbb', 'ccQc')
        $paint = Get-LokiScreenDiff -Old $old -New $new
        $paint | Should -Not -Match "`n"
        $paint | Should -Not -Match "`r"
        $paint | Should -Not -Match ((Get-LokiTestEscPattern) + '\[[0-9]*[ABCD]')
    }

    It 'stays roughly the size the reference frame is' {
        # Measured: 26 bytes per frame on a 120x28 screen, against 3417 for a full repaint. The
        # reference's median frame is 61 bytes. This is a smell test, not a contract -- it exists so
        # that a rewrite which quietly starts repainting whole rows is noticed.
        $old = [string[]]@(Initialize-LokiScreenModel -Width 119 -Height 28)
        $new = [string[]]@($old.Clone())
        $new[27] = (Format-LokiScreenRow -Text '  spinner /   done 12' -Width 119)
        (Get-LokiScreenDiff -Old $old -New $new).Length | Should -BeLessThan 120
    }

    It 'survives null and mismatched lengths without throwing' {
        { Get-LokiScreenDiff -Old $null -New $null } | Should -Not -Throw
        { Get-LokiScreenDiff -Old ([string[]]@('ab')) -New ([string[]]@('ab', 'cd')) } | Should -Not -Throw
    }
}

Describe 'Get-LokiScreenFullPaint' {
    It 'places every row absolutely' {
        $paint = Get-LokiScreenFullPaint -Model ([string[]]@('ab', 'cd'))
        $paint | Should -Be ((Get-LokiTestEsc) + '[1;1Hab' + (Get-LokiTestEsc) + '[2;1Hcd')
    }

    It 'contains no newline anywhere' {
        # The obvious implementation joins rows with CRLF, and the newline after the LAST row scrolls
        # the screen by one -- so the whole frame slides up and every later absolute position is off
        # by a row. It looks fine in a probe that paints WindowHeight-2 rows and breaks the moment the
        # screen is the full window.
        $model = [string[]]@(Initialize-LokiScreenModel -Width 20 -Height 30)
        $paint = Get-LokiScreenFullPaint -Model $model
        $paint | Should -Not -Match "`n"
        $paint | Should -Not -Match "`r"
    }

    It 'is empty for an empty model' {
        (Get-LokiScreenFullPaint -Model ([string[]]@())).Length | Should -Be 0
    }
}

Describe 'the screen lifecycle, against mocked console primitives' {
    BeforeEach {
        $script:written = New-Object System.Collections.Generic.List[string]
        $script:shown = @{}

        Mock -CommandName Get-LokiConsoleFact -MockWith {
            return @{
                HostName = 'ConsoleHost'; OutputRedirected = $false; InputRedirected = $false
                WindowWidth = 120; WindowHeight = 30; BufferWidth = 120; BufferHeight = 9001; CursorTop = 0
            }
        }
        Mock -CommandName Test-LokiVtProcessing -MockWith { return $true }
        Mock -CommandName Write-LokiScreenRaw -MockWith { [void]$script:written.Add($Text); return $true }
        # The console agrees with whatever was last painted: a perfect console.
        Mock -CommandName Get-LokiScreenRow -MockWith {
            if ($script:shown.ContainsKey($Row)) { return $script:shown[$Row] }
            return (' ' * $Width)
        }
        Initialize-LokiScreen
    }

    AfterEach { Initialize-LokiScreen }

    It 'opens, and says so' {
        Open-LokiScreen | Should -BeTrue
        Test-LokiScreenOpen | Should -BeTrue
        Get-LokiScreenRefusal | Should -Be 'ok'
        $size = Get-LokiScreenSize
        $size.Width | Should -Be 119 -Because 'one column short of the window, by design'
        $size.Height | Should -Be 30
    }

    It 'enters the alternate screen, clears exactly once, and hides the cursor' {
        [void](Open-LokiScreen)
        $all = ($script:written.ToArray() -join '')
        $all | Should -Match ((Get-LokiTestEscPattern) + '\[\?1049h')
        $all | Should -Match ((Get-LokiTestEscPattern) + '\[\?25l')
        # ESC[2J exactly once, at entry -- the reference clears once across a 5-minute session.
        ([regex]::Matches($all, (Get-LokiTestEscPattern) + '\[2J')).Count | Should -Be 1
    }

    It 'leaves the alternate screen and shows the cursor again on close' {
        [void](Open-LokiScreen)
        $script:written.Clear()
        Close-LokiScreen
        $all = ($script:written.ToArray() -join '')
        $all | Should -Match ((Get-LokiTestEscPattern) + '\[\?25h')
        $all | Should -Match ((Get-LokiTestEscPattern) + '\[\?1049l')
        Test-LokiScreenOpen | Should -BeFalse
    }

    It 'closing twice is harmless and writes nothing the second time' {
        [void](Open-LokiScreen)
        Close-LokiScreen
        $script:written.Clear()
        Close-LokiScreen
        $script:written.Count | Should -Be 0
    }

    It 'paints only the difference on the second frame' {
        [void](Open-LokiScreen)
        $model = Initialize-LokiScreenModel -Width 119 -Height 30
        Write-LokiScreenFrame -Model $model     # identical to the blank opening frame
        $script:written.Clear()
        Write-LokiScreenCell -Model $model -Row 29 -Col 2 -Text 'working'
        Write-LokiScreenFrame -Model $model
        $script:written.Count | Should -Be 1 -Because 'one frame is one console write'
        $script:written[0] | Should -Be ((Get-LokiTestEsc) + '[30;3Hworking')
    }

    It 'writes nothing at all when the frame is unchanged' {
        [void](Open-LokiScreen)
        $model = Initialize-LokiScreenModel -Width 119 -Height 30
        Write-LokiScreenFrame -Model $model
        $script:written.Clear()
        Write-LokiScreenFrame -Model $model
        $script:written.Count | Should -Be 0
    }

    It 'drops a misshapen frame instead of painting it somewhere wrong' {
        [void](Open-LokiScreen)
        $model = Initialize-LokiScreenModel -Width 119 -Height 30
        $model[4] = 'too short'
        $script:written.Clear()
        Write-LokiScreenFrame -Model $model
        $script:written.Count | Should -Be 0
        Get-LokiScreenRefusal | Should -Be 'bad-shape'
        Test-LokiScreenOpen | Should -BeTrue -Because 'a bad frame is the caller''s bug, not a reason to give up the screen'
    }

    It 'ignores frames when no screen is open' {
        $script:written.Clear()
        Write-LokiScreenFrame -Model (Initialize-LokiScreenModel -Width 119 -Height 30)
        $script:written.Count | Should -Be 0
    }

    It 'refuses without VT, and never enters the alternate screen' {
        Mock -CommandName Test-LokiVtProcessing -MockWith { return $false }
        Open-LokiScreen | Should -BeFalse
        Get-LokiScreenRefusal | Should -Be 'no-vt'
        ($script:written.ToArray() -join '') | Should -Not -Match ((Get-LokiTestEscPattern) + '\[\?1049h')
    }

    It 'does not touch the operator screen with the VT probe for a console it would refuse anyway' {
        # The probe borrows a row and puts it back. That is acceptable for a console about to be
        # taken over, and rude for one that was never eligible.
        Mock -CommandName Get-LokiConsoleFact -MockWith {
            return @{
                HostName = 'ConsoleHost'; OutputRedirected = $true; InputRedirected = $false
                WindowWidth = 120; WindowHeight = 30; BufferWidth = 120; BufferHeight = 30; CursorTop = 0
            }
        }
        Open-LokiScreen | Should -BeFalse
        Get-LokiScreenRefusal | Should -Be 'redirected'
        Should -Invoke Test-LokiVtProcessing -Times 0
    }

    It 'refuses when there is no console to ask' {
        Mock -CommandName Get-LokiConsoleFact -MockWith { return $null }
        Open-LokiScreen | Should -BeFalse
        Get-LokiScreenRefusal | Should -Be 'no-console'
    }

    It 'the read-back check goes red when the console disagrees' {
        # THE OTHER MUTATION. If this cannot be made to fail, the self-check at open is decoration.
        # The console here shows one row that is not what was painted -- exactly what a host whose
        # escape handling differs from this file's model would produce.
        Mock -CommandName Get-LokiScreenRow -MockWith {
            if ($Row -eq 3) { return ('X' * $Width) }
            return (' ' * $Width)
        }
        Open-LokiScreen | Should -BeFalse
        Get-LokiScreenRefusal | Should -Be 'self-check'
        # And it left the alternate screen behind it rather than sitting in it.
        ($script:written.ToArray() -join '') | Should -Match ((Get-LokiTestEscPattern) + '\[\?1049l')
    }

    It 'a refusal by self-check lasts for the rest of the process' {
        Mock -CommandName Get-LokiScreenRow -MockWith {
            if ($Row -eq 3) { return ('X' * $Width) }
            return (' ' * $Width)
        }
        [void](Open-LokiScreen)
        Open-LokiScreen | Should -BeFalse
        Get-LokiScreenRefusal | Should -Be 'disabled' -Because 'reopening would walk into the same trap'
    }

    It 'accepts a console that cannot be read back at all' {
        # -1 means the read failed, not that it disagreed. A host with a stubbed GetBufferContents is
        # unverifiable, not wrong, and the per-frame shape check still guards the arithmetic.
        Mock -CommandName Get-LokiScreenRow -MockWith { return $null }
        Open-LokiScreen | Should -BeTrue
    }

    It 'gives up the screen when a write fails mid-session' {
        [void](Open-LokiScreen)
        $model = Initialize-LokiScreenModel -Width 119 -Height 30
        Write-LokiScreenFrame -Model $model
        Mock -CommandName Write-LokiScreenRaw -MockWith { return $false }
        Write-LokiScreenCell -Model $model -Row 0 -Col 0 -Text 'x'
        Write-LokiScreenFrame -Model $model
        Test-LokiScreenOpen | Should -BeFalse
        Get-LokiScreenRefusal | Should -Be 'write-failed'
    }

    It 'Initialize-LokiScreen clears a lasting refusal, and nothing else does' {
        Mock -CommandName Get-LokiScreenRow -MockWith {
            if ($Row -eq 3) { return ('X' * $Width) }
            return (' ' * $Width)
        }
        [void](Open-LokiScreen)
        Get-LokiScreenRefusal | Should -Be 'self-check'
        Initialize-LokiScreen
        Get-LokiScreenRefusal | Should -Be 'closed'
    }
}

Describe 'Test-LokiScreenPaint' {
    It 'counts the rows the console disagrees about' {
        Mock -CommandName Get-LokiScreenRow -MockWith {
            if ($Row -eq 1) { return 'WRONG ' }
            return 'right '
        }
        Test-LokiScreenPaint -Model ([string[]]@('right ', 'right ', 'right ')) | Should -Be 1
    }
    It 'reports -1 when the console cannot be read' {
        Mock -CommandName Get-LokiScreenRow -MockWith { return $null }
        Test-LokiScreenPaint -Model ([string[]]@('a')) | Should -Be -1
    }
    It 'reports -1 for an empty model rather than a clean bill of health' {
        Test-LokiScreenPaint -Model ([string[]]@()) | Should -Be -1
    }
}
