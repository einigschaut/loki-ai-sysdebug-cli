# lib/teardown.ps1 -- giving the operator's console back, in one place (issue #133 review, invariant I1).
#
# I1: after Loki ends by any path short of a hard kill -- including an exception or a stop at any instruction -- the
# operator's console is as Loki found it: main screen visible, cursor visible, Ctrl+C handled the way it was.
#
# Contract:
#   Restore-LokiConsole            undo everything Loki may have done to the console. Idempotent, never throws.
#   Get-LokiRestoreFailure         the steps that failed since Initialize-LokiRestore, as "step: message".
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

function Restore-LokiConsole {
    # THE ORDER IS THE POINT, and every Close-* below is a no-op when its part was never opened.
    #
    #   1. The capture sink. Anything written from here on -- including the error message the dispatcher is about to
    #      print -- must reach the real console, not a transcript nobody draws any more.
    #   2. The screen, while Ctrl+C is STILL claimed: a Ctrl+C pressed now arrives as a key, not as a stop that could
    #      interrupt the leave halfway.
    #   3. The live region, which also writes, and so also goes before the keyboard.
    #   4. The session, which re-runs 1-2 for itself and is then marked closed.
    #   5. The keyboard, LAST: once Ctrl+C is PowerShell's again, a second press stops everything, and by then there is
    #      nothing left on the console to leave half done.
    #
    # The plain scriptblocks below keep this file's session state, so the Close-* calls resolve here as they would at
    # the call site; none of them captures anything.
    Invoke-LokiRestoreStep -Name 'sink' -Step { Register-LokiWriteSink -Sink $null }
    Invoke-LokiRestoreStep -Name 'capture' -Step { Close-LokiSessionCapture }
    Invoke-LokiRestoreStep -Name 'screen' -Step { Close-LokiScreen }
    Invoke-LokiRestoreStep -Name 'region' -Step { Close-LokiRegion }
    Invoke-LokiRestoreStep -Name 'session' -Step { Close-LokiSession }
    Invoke-LokiRestoreStep -Name 'keyboard' -Step { Close-LokiKeyread }
}
