@echo off
REM loki.cmd -- THE entry point (DESIGN.md section 2). Lives next to loki.ps1, so it sits at the stick root
REM in the deployed artifact and next to the dispatcher in a repo checkout; both work identically.
REM
REM Why a .cmd and not "just run the .ps1": an interactive PowerShell session on the TARGET machine writes the
REM operator's command line into that host's PSReadLine history (%APPDATA%\Microsoft\Windows\PowerShell\PSReadLine\
REM ConsoleHost_history.txt) -- a trace on a machine Loki promises to leave clean. cmd.exe keeps no such history,
REM and the PowerShell it starts is non-interactive (-File), so nothing is recorded. lib/footprint.ps1 watches that
REM very history file as a standing target, which is how the guarantee stays falsifiable rather than asserted.
REM
REM -NoProfile: no profile script on the target can redefine a cmdlet or an alias underneath the dispatcher.
REM -ExecutionPolicy Bypass: the stick is not code-signed yet; the policy would otherwise refuse the .ps1 outright.
REM Deliberately NOT -NonInteractive: `auth login` and `chat` need the console.
REM
REM %~dp0 anchors loki.ps1 to THIS file's directory, so the working directory the operator happens to be in is
REM irrelevant. The trailing backslash is part of %~dp0, hence "%~dp0loki.ps1" without a separator.
REM
REM HONEST RESIDUAL (issue #55 / ADR-0016): everything Loki spawns LATER resolves system binaries through
REM [System.Environment]::SystemDirectory, the OS's own answer, so a poisoned %SystemRoot% cannot steer it. This file
REM cannot do that -- cmd.exe has no access to that API, and it runs before any of Loki does. The explicit path below
REM is still strictly better than a bare `powershell` (which would search PATH, and PATH on a compromised target is
REM attacker-controlled). What it cannot do is bootstrap its own trust: the first thing you run on a machine you do
REM not control is chosen by that machine. That is a property of the situation, not a defect to be commented away.
setlocal
set "LOKI_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%LOKI_PS%" set "LOKI_PS=powershell.exe"

REM PSModulePath is PINNED to the Windows PowerShell system module directory, and this is not tidiness -- without it
REM Loki does not start at all on a machine that has PowerShell 7. MEASURED, not reasoned: launched from a pwsh 7
REM session via cmd.exe, 5.1 inherits pwsh's PSModulePath verbatim, and `C:\Program Files\PowerShell\7\Modules` sits
REM AHEAD of the system path. 5.1 then finds PowerShell 7's Microsoft.PowerShell.Utility, cannot load it, and the very
REM first thing the dispatcher does -- Import-PowerShellDataFile -- fails with "not recognized". Running the .ps1
REM DIRECTLY happens to work, because powershell.exe repairs the variable when it is launched as the child itself;
REM that accident is why nobody noticed until the entry point existed.
REM
REM Pinned to the SYSTEM directory only, not merely repaired to the 5.1 default: a module planted in an inherited
REM module path can shadow a cmdlet the dispatcher depends on, and the machine Loki runs on is by assumption not
REM trustworthy. This is the module-path twin of the System32 PATH pin (issue #50) and of the PSModulePath redirect
REM Get-LokiIsolatedEnv already applies to every CHILD process -- the entry point simply had no such protection.
REM Verified against the real commands (version, help, status, hwscan, doctor) before being pinned this narrowly.
set "PSModulePath=%SystemRoot%\System32\WindowsPowerShell\v1.0\Modules"

"%LOKI_PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0loki.ps1" %*
REM Exit codes are a stable public interface (CLAUDE.md section 4: 3 = auth, 5 = offline engine missing, ...), so the
REM shim MUST pass the dispatcher's code through -- a wrapper that always exits 0 would silently break every caller
REM that scripts against them. %ERRORLEVEL% expands when THIS line is parsed, i.e. after the call above returned,
REM and before endlocal discards the scope.
endlocal & exit /b %ERRORLEVEL%
