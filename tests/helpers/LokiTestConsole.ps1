# tests/helpers/LokiTestConsole.ps1 -- a fake console that INTERPRETS what Loki writes (issue #133 review, I1).
#
# Why this exists. The console tests used to mock Write-LokiScreenRaw with "remember the string" and Get-LokiScreenRow
# with "return blanks". A mock like that cannot notice that the alternate screen was never left, that the cursor stayed
# hidden, or that Open painted nothing at all -- an independent review replaced Loki's full paint with "paint nothing"
# and every test stayed green. This double keeps the state a terminal keeps, so a test can ask what the OPERATOR is
# looking at afterwards rather than what Loki tried to send:
#
#   AltOn          is the alternate screen active?
#   CursorVisible  is the cursor shown?
#   CtrlC          is Ctrl+C claimed as input (TreatControlCAsInput)?
#   Main / Alt     the two buffers, row by row. Main starts filled with 'm', so "the operator's screen is untouched"
#                  is a check on Main rather than an assumption.
#
# It interprets only the sequences Loki emits -- CUP (ESC[r;cH), ED (ESC[2J), DECSET/DECRST ?1049 and ?25, and SGR
# (ESC[...m, ignored) -- and records anything else in Unknown, so a new sequence cannot slip past a test unnoticed.
#
# FAULT INJECTION. Every console call goes through Tick(). Set FailAt = N and the N-th call fails in one of three ways:
#   'throw'  BEFORE its effect -- the call never happened
#   'false'  instead of its effect -- the call reports failure, as the real primitives do
#   'after'  AFTER its effect -- the call happened, then a stop landed. This is the case a review found missing: a guard
#            recorded after its own side effect looked correct under 'throw' and was not.
# A property test can then fail the run at every single console call in turn and ask whether the console came back.
#
# THE CURSOR. ?1049h saves the cursor and ?1049l restores it -- and a ?1049l with nothing saved puts it in the top-left
# corner of the window, which is 0,0 here because this double has no scrollback. That is what a real conhost does
# (measured 2026-10-05: a bare leave moved the cursor from 8,7 to 0,0 with the window at the top of the buffer, and from
# 8,60 to 0,31 with the window scrolled to row 31; a second leave after a
# successful one jumped back to the position saved at enter). The operator's cursor starts at row 7, column 8, so a leave
# that should not have been sent shows up as a moved cursor.
#
# Enters, Leaves and SpuriousLeaves count what TOOK EFFECT, not what was attempted: Log records attempts, and an attempt
# that failed before its effect left nothing behind.
#
# NOT MODELLED, and so NOT covered by anything green here:
#   - a real Ctrl+C stop. It cannot be caught by a script's catch; the injected faults can, so a fault inside a restore
#     step lets the next step run where a real stop would not.
#   - SGR attributes (ignored -- the leave sequence's reset is checked directly instead).
#   - output between a leave whose effect happened but was reported as failed, and the retry: the retry is a second
#     leave and jumps the cursor back to where it was at enter. The walk prints nothing in between, so it cannot see
#     that -- and a [Console]::Write that reports failure after its bytes went out is not a failure mode that was ever
#     observed.
#   - ordinary output. Write-LokiLine and the one-shot fallback menu write to the REAL console, not into this double --
#     so a line that falls through a capture sink which failed while the screen was up is invisible here.
#   - line wrapping, a main buffer reflowed by a resize, and anything specific to Windows Terminal / ConPTY.
#
# State lives on the returned OBJECT, used through its script methods -- not in $script: variables. A global function
# reading $script: under Pester reads the global scope, not the test file's; an object carries its state with it.

function global:New-LokiTestConsole {
    param(
        [int]$Width = 60,
        [int]$Height = 12,
        [bool]$CtrlC = $false
    )
    $console = [pscustomobject]@{
        Width         = $Width
        Height        = $Height
        # What Get-LokiConsoleFact reports. A test changes these to make the window "resize" between two reads.
        ReportWidth   = $Width + 1
        ReportHeight  = $Height
        Main          = $null
        Alt           = $null
        AltOn         = $false
        CursorVisible = $true
        Row           = 7
        Col           = 8
        StartRow      = 7
        StartCol      = 8
        SavedRow      = -1
        SavedCol      = -1
        CtrlC         = $CtrlC
        CtrlCAtStart  = $CtrlC
        Calls         = 0
        PendingStop   = $false
        # What actually TOOK EFFECT. The log records attempts, and an attempt that failed before its effect left nothing --
        # counting attempts reported "two leaves for one enter" where only one had happened.
        Enters        = 0
        Leaves        = 0
        # Leaves applied while the alternate screen was NOT active: the damage a real conhost shows as a jumped cursor.
        SpuriousLeaves = 0
        FailAt        = 0
        FailMode      = 'throw'
        Unknown       = (New-Object System.Collections.Generic.List[string])
        Log           = (New-Object System.Collections.Generic.List[string])
    }
    $console.Main = New-Object string[] $Height
    $console.Alt = New-Object string[] $Height
    for ($r = 0; $r -lt $Height; $r++) {
        $console.Main[$r] = ('m' * $Width)
        $console.Alt[$r] = (' ' * $Width)
    }

    # One console call. Returns $true when the call should go ahead and $false when it should report failure; throws
    # when the injected fault is a throw.
    Add-Member -InputObject $console -MemberType ScriptMethod -Name Tick -Value {
        param([string]$What)
        $this.Calls++
        $this.Log.Add($What)
        if ($this.FailAt -gt 0 -and $this.Calls -eq $this.FailAt) {
            if ($this.FailMode -ceq 'throw') { throw "injected fault at console call $($this.Calls) ($What)" }
            if ($this.FailMode -ceq 'false') { return $false }
            # 'after': let the effect happen; AfterEffect() throws once it has.
            $this.PendingStop = $true
        }
        return $true
    }

    Add-Member -InputObject $console -MemberType ScriptMethod -Name AfterEffect -Value {
        if ($this.PendingStop) {
            $this.PendingStop = $false
            throw "injected stop AFTER the effect of console call $($this.Calls)"
        }
    }

    Add-Member -InputObject $console -MemberType ScriptMethod -Name PutChar -Value {
        param([char]$Ch)
        $buf = $this.Main
        if ($this.AltOn) { $buf = $this.Alt }
        if ($this.Row -lt 0 -or $this.Row -ge $this.Height -or $this.Col -lt 0 -or $this.Col -ge $this.Width) {
            $this.Col++
            return
        }
        $line = $buf[$this.Row]
        $buf[$this.Row] = $line.Substring(0, $this.Col) + [string]$Ch + $line.Substring($this.Col + 1)
        $this.Col++
    }

    Add-Member -InputObject $console -MemberType ScriptMethod -Name ApplyCsi -Value {
        param([string]$Params, [char]$Final)
        if ($Final -ceq [char]'H') {
            $parts = $Params.Split(';')
            $r = 1; $c = 1
            if ($parts.Count -ge 1 -and $parts[0].Length -gt 0) { $r = [int]$parts[0] }
            if ($parts.Count -ge 2 -and $parts[1].Length -gt 0) { $c = [int]$parts[1] }
            $this.Row = $r - 1
            $this.Col = $c - 1
            return
        }
        if ($Final -ceq [char]'J' -and $Params -ceq '2') {
            $buf = $this.Main
            if ($this.AltOn) { $buf = $this.Alt }
            for ($i = 0; $i -lt $this.Height; $i++) { $buf[$i] = (' ' * $this.Width) }
            return
        }
        if ($Final -ceq [char]'m') { return }
        if ($Params -ceq '?1049' -and $Final -ceq [char]'h') {
            if (-not $this.AltOn) { $this.SavedRow = $this.Row; $this.SavedCol = $this.Col }
            $this.Enters++
            $this.AltOn = $true
            for ($i = 0; $i -lt $this.Height; $i++) { $this.Alt[$i] = (' ' * $this.Width) }
            return
        }
        if ($Params -ceq '?1049' -and $Final -ceq [char]'l') {
            if ($this.AltOn) { $this.Leaves++ } else { $this.SpuriousLeaves++ }
            $this.AltOn = $false
            if ($this.SavedRow -ge 0) { $this.Row = $this.SavedRow; $this.Col = $this.SavedCol }
            else { $this.Row = 0; $this.Col = 0 }
            return
        }
        if ($Params -ceq '?25' -and $Final -ceq [char]'h') { $this.CursorVisible = $true; return }
        if ($Params -ceq '?25' -and $Final -ceq [char]'l') { $this.CursorVisible = $false; return }
        $this.Unknown.Add("CSI $Params$Final")
    }

    # What Write-LokiScreenRaw would have sent. Interpreted only if the call goes ahead.
    Add-Member -InputObject $console -MemberType ScriptMethod -Name Write -Value {
        param([string]$Text)
        # The text goes into the log, so an ordering test can ask WHICH write came first, not just how many.
        if (-not $this.Tick('write:' + $Text)) { return $false }
        $esc = [char]27
        $i = 0
        while ($i -lt $Text.Length) {
            $ch = $Text[$i]
            if ($ch -ceq $esc -and ($i + 1) -lt $Text.Length -and $Text[$i + 1] -ceq [char]'[') {
                $j = $i + 2
                while ($j -lt $Text.Length -and ([int]$Text[$j] -lt 0x40 -or [int]$Text[$j] -gt 0x7E)) { $j++ }
                if ($j -ge $Text.Length) { $this.Unknown.Add('unterminated CSI'); break }
                $this.ApplyCsi($Text.Substring($i + 2, $j - $i - 2), $Text[$j])
                $i = $j + 1
                continue
            }
            if ($ch -ceq $esc) { $this.Unknown.Add('ESC not followed by ['); $i++; continue }
            $this.PutChar($ch)
            $i++
        }
        $this.AfterEffect()
        return $true
    }

    # What Get-LokiScreenRow would have read back: the ACTIVE buffer, exactly as painted.
    Add-Member -InputObject $console -MemberType ScriptMethod -Name ReadRow -Value {
        param([int]$Row, [int]$Width)
        if (-not $this.Tick('read-row')) { return $null }
        if ($Row -lt 0 -or $Row -ge $this.Height) { return $null }
        $buf = $this.Main
        if ($this.AltOn) { $buf = $this.Alt }
        $line = [string]$buf[$Row]
        $this.AfterEffect()
        if ($Width -le $line.Length) { return $line.Substring(0, $Width) }
        return $line.PadRight($Width)
    }

    Add-Member -InputObject $console -MemberType ScriptMethod -Name SetCtrlC -Value {
        param([bool]$Enabled)
        if (-not $this.Tick("ctrl-c=$Enabled")) { return $false }
        $this.CtrlC = $Enabled
        $this.AfterEffect()
        return $true
    }

    Add-Member -InputObject $console -MemberType ScriptMethod -Name GetCtrlC -Value {
        [void]$this.Tick('ctrl-c?')
        $this.AfterEffect()
        return $this.CtrlC
    }

    # What a direct cursor move (SetCursorPosition) does.
    Add-Member -InputObject $console -MemberType ScriptMethod -Name MoveCursor -Value {
        param([int]$Row, [int]$Col)
        if (-not $this.Tick("cursor=$Row,$Col")) { return $false }
        $this.Row = $Row
        $this.Col = $Col
        $this.AfterEffect()
        return $true
    }

    # The geometry Get-LokiConsoleFact reports for a real interactive console.
    Add-Member -InputObject $console -MemberType ScriptMethod -Name Fact -Value {
        [void]$this.Tick('fact')
        $this.AfterEffect()
        return @{
            HostName = 'ConsoleHost'; OutputRedirected = $false; InputRedirected = $false
            WindowWidth = $this.ReportWidth; WindowHeight = $this.ReportHeight
            BufferWidth = $this.ReportWidth; BufferHeight = $this.ReportHeight
            CursorTop = $this.Row; CursorLeft = $this.Col
        }
    }

    # True when the operator gets their console back the way they had it -- I1, as one question.
    Add-Member -InputObject $console -MemberType ScriptMethod -Name IsRestored -Value {
        if ($this.AltOn) { return $false }
        if (-not $this.CursorVisible) { return $false }
        if ($this.CtrlC -ne $this.CtrlCAtStart) { return $false }
        if ($this.Row -ne $this.StartRow -or $this.Col -ne $this.StartCol) { return $false }
        for ($r = 0; $r -lt $this.Height; $r++) { if ($this.Main[$r] -cne ('m' * $this.Width)) { return $false } }
        return $true
    }

    Add-Member -InputObject $console -MemberType ScriptMethod -Name Describe -Value {
        $mainOk = $true
        for ($r = 0; $r -lt $this.Height; $r++) { if ($this.Main[$r] -cne ('m' * $this.Width)) { $mainOk = $false } }
        return ('alt={0} cursorVisible={1} ctrlC={2} (was {3}) cursor={4},{5} (was {6},{7}) mainUntouched={8}' -f
            $this.AltOn, $this.CursorVisible, $this.CtrlC, $this.CtrlCAtStart, $this.Row, $this.Col, $this.StartRow, $this.StartCol, $mainOk)
    }

    return $console
}
