# lib/teardown.ps1 -- giving the operator's console back, in one place (issue #133 review, invariant I1).
#
# I1: after Loki ends by any path short of a hard kill -- including an exception or a stop at any instruction -- the
# operator's console is as Loki found it: main screen visible and untouched, cursor visible and where it was, Ctrl+C
# handled the way it was, attributes reset.
#
# Contract:
#   Restore-LokiConsole            undo everything Loki may have done to the console. Idempotent, never throws.
#   Get-LokiRestoreFailure         what the LAST Restore-LokiConsole could not give back: "step" for a part still not
#                                  given back afterwards, "step: message" for a step that threw.
#   Get-LokiRestoreExitCode -ExitCode -> [int]   the exit code once restore failures are counted: Ok becomes
#                                  GeneralError, any other code stays -- the command's own reason comes first.
#   Write-LokiRestoreWarning       one localized warning per such failure. Best effort, never throws.
#   Initialize-LokiRestore         forget earlier failures; run once at start-up, like the other Initialize-* calls.
#
# WHY A FUNCTION OF ITS OWN, AND NOT FOUR LINES IN THE DISPATCHER'S finally. An independent review found three things
# wrong with the four lines that were there:
#   - the error path printed its message BEFORE the finally left the alternate screen, so the message landed in the
#     alternate buffer and vanished with it: exit code 1 and nothing on screen. The dispatcher now calls this from its
#     catch first, then prints, then calls it again from the finally -- which is why it has to be idempotent.
#   - the steps were not guarded one by one. Close-LokiRegion writes to the console under ErrorActionPreference Stop;
#     if it threw, the screen and the keyboard after it were never given back.
#   - removing all four lines left every test green. tests/teardown.Tests.ps1 now walks a full open/frame/close cycle
#     and fails it at every single console call, and the dispatcher's wiring is pinned by a test of its syntax tree.
Set-StrictMode -Version Latest

$script:LokiRestoreFailure = New-Object System.Collections.Generic.List[string]

function Initialize-LokiRestore {
    $script:LokiRestoreFailure.Clear()
}

function Get-LokiRestoreFailure {
    return @($script:LokiRestoreFailure.ToArray())
}

function Get-LokiRestoreExitCode {
    param([Parameter(Mandatory = $true)][int]$ExitCode)
    # A run that could not give the console back does not end with exit code 0 -- that would be a failure that looks
    # like success. A run that already failed keeps its own code: it is the more useful of the two reasons.
    if (@(Get-LokiRestoreFailure).Count -eq 0) { return $ExitCode }
    if ($ExitCode -eq (Get-LokiExitCode 'Ok')) { return (Get-LokiExitCode 'GeneralError') }
    return $ExitCode
}

function Invoke-LokiRestoreStep {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Step
    )
    # One step, on its own. A step that throws is recorded and the next step runs anyway: one broken handle must not
    # cost the operator the other three things this gives back.
    try { & $Step }
    catch { $script:LokiRestoreFailure.Add($Name + ': ' + [string]$_.Exception.Message) }
}

function Write-LokiRestoreWarning {
    # It runs in the dispatcher's finally, where the console is likely broken if there is anything to report at all --
    # and an exception escaping a finally would replace the exit code with PowerShell's own error text on a screen
    # that may not show it. So it never throws, and it stops at the first warning that cannot be written: the rest
    # would not get through either.
    foreach ($failed in @(Get-LokiRestoreFailure)) {
        try { Write-LokiWarn (Get-LokiText 'restore.failed' -ArgumentList @([string]$failed)) }
        catch { return }
    }
}

function Restore-LokiConsole {
    # THE ORDER IS THE POINT, and every Close-* below is a no-op when its part was never opened.
    #
    #   1. The capture sink. Anything written from here on -- including the error message the dispatcher is about to
    #      print -- must reach the real console, not a transcript nobody draws any more.
    #   2. The live region, BEFORE the screen. It closes by blanking its rows at an anchor read from the console, and
    #      while the alternate screen is up that is the alternate buffer, discarded with it. After the leave it is the
    #      operator's main buffer: an independent review measured four of the operator's rows blanked and the cursor
    #      moved on a real conhost, with this step after the screen. With it first: nothing changed.
    #   3. The screen, while Ctrl+C is STILL claimed: a Ctrl+C pressed now arrives as a key, not as a stop that could
    #      interrupt the leave halfway.
    #   4. The session, which re-runs 1-3 for itself and is then marked closed.
    #   5. The keyboard, LAST: once Ctrl+C is PowerShell's again, a second press stops everything, and by then there is
    #      nothing left on the console to leave half done.
    #
    # The plain scriptblocks below keep this file's session state, so the Close-* calls resolve here as they would at
    # the call site; none of them captures anything.
    #
    # It reports its OWN outcome only. The dispatcher restores from its catch and again from its finally, and what it
    # reports is the second, final one: a leave the first attempt could not write and the second one did is not a
    # failure the operator needs to hear about.
    $script:LokiRestoreFailure.Clear()
    Invoke-LokiRestoreStep -Name 'sink' -Step { Register-LokiWriteSink -Sink $null }
    Invoke-LokiRestoreStep -Name 'capture' -Step { Close-LokiSessionCapture }
    Invoke-LokiRestoreStep -Name 'region' -Step { Close-LokiRegion }
    Invoke-LokiRestoreStep -Name 'screen' -Step { Close-LokiScreen }
    Invoke-LokiRestoreStep -Name 'session' -Step { Close-LokiSession }
    Invoke-LokiRestoreStep -Name 'keyboard' -Step { Close-LokiKeyread }

    # The Close functions report a failure by KEEPING their state, not by throwing -- so a step that "succeeded" may
    # still have given nothing back. An independent review measured it on a real console: alternate screen still
    # active, exit code 0, no warning. So the outcome is asked of the state, after every step has run. The entries are
    # step names, not prose: the localized sentence around them (restore.failed) says what they mean. A step that
    # already threw is reported once, not twice.
    $named = @($script:LokiRestoreFailure | ForEach-Object { ([string]$_ -split ':', 2)[0] })
    if ((Test-LokiScreenMustLeave) -and $named -notcontains 'screen') { $script:LokiRestoreFailure.Add('screen') }
    if ((Test-LokiKeyreadOpen) -and $named -notcontains 'keyboard') { $script:LokiRestoreFailure.Add('keyboard') }
}
