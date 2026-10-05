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
# FAULT INJECTION. Every console call goes through Tick(). Set FailAt = N and the N-th call throws (FailMode 'throw')
# or reports failure (FailMode 'false', for the calls that return a bool). A property test can then fail the run at
# every single console call in turn and ask whether the console still came back.
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
        Main          = $null
        Alt           = $null
        AltOn         = $false
        CursorVisible = $true
        Row           = 0
        Col           = 0
        CtrlC         = $CtrlC
        CtrlCAtStart  = $CtrlC
        Calls         = 0
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
            return $false
        }
        return $true
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
            $this.AltOn = $true
            for ($i = 0; $i -lt $this.Height; $i++) { $this.Alt[$i] = (' ' * $this.Width) }
            return
        }
        if ($Params -ceq '?1049' -and $Final -ceq [char]'l') { $this.AltOn = $false; return }
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
        if ($Width -le $line.Length) { return $line.Substring(0, $Width) }
        return $line.PadRight($Width)
    }

    Add-Member -InputObject $console -MemberType ScriptMethod -Name SetCtrlC -Value {
        param([bool]$Enabled)
        if (-not $this.Tick("ctrl-c=$Enabled")) { return $false }
        $this.CtrlC = $Enabled
        return $true
    }

    Add-Member -InputObject $console -MemberType ScriptMethod -Name GetCtrlC -Value {
        [void]$this.Tick('ctrl-c?')
        return $this.CtrlC
    }

    # The geometry Get-LokiConsoleFact reports for a real interactive console.
    Add-Member -InputObject $console -MemberType ScriptMethod -Name Fact -Value {
        [void]$this.Tick('fact')
        return @{
            HostName = 'ConsoleHost'; OutputRedirected = $false; InputRedirected = $false
            WindowWidth = $this.Width + 1; WindowHeight = $this.Height
            BufferWidth = $this.Width + 1; BufferHeight = $this.Height; CursorTop = 0
        }
    }

    # True when the operator gets their console back the way they had it -- I1, as one question.
    Add-Member -InputObject $console -MemberType ScriptMethod -Name IsRestored -Value {
        if ($this.AltOn) { return $false }
        if (-not $this.CursorVisible) { return $false }
        if ($this.CtrlC -ne $this.CtrlCAtStart) { return $false }
        for ($r = 0; $r -lt $this.Height; $r++) { if ($this.Main[$r] -cne ('m' * $this.Width)) { return $false } }
        return $true
    }

    Add-Member -InputObject $console -MemberType ScriptMethod -Name Describe -Value {
        $mainOk = $true
        for ($r = 0; $r -lt $this.Height; $r++) { if ($this.Main[$r] -cne ('m' * $this.Width)) { $mainOk = $false } }
        return ('alt={0} cursorVisible={1} ctrlC={2} (was {3}) mainUntouched={4}' -f
            $this.AltOn, $this.CursorVisible, $this.CtrlC, $this.CtrlCAtStart, $mainOk)
    }

    return $console
}
