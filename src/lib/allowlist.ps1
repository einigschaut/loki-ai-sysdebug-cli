# lib/allowlist.ps1 - command allow-list gate (security core, CLAUDE.md section 5, DESIGN.md section 5.1)
# Contract:
#   Get-LokiCommandClass -CommandLine <string> -> 'read' | 'mutate' | 'denied'
#     Classifies a PROPOSED command line. Conservative: only 'read' when provably read-only;
#     anything unrecognized -> 'mutate'. Order of checks (FIRST match wins):
#       1) Trim(); empty/whitespace-only -> 'denied'.
#       2) READ, ONLY IF the command is provably read-only: (a) it contains NONE of the unsafe
#          characters ; | & ` $ ( ) { } < > and no CR/LF, AND (b) its first whitespace token matches
#          a curated read pattern (Get-*, the pure-read list, or the arg-aware ipconfig/arp/route
#          rules). READ is checked BEFORE the deny list ON PURPOSE: a genuine read whose ARGUMENTS
#          merely contain a scary substring (a file named iex.log, a host named ii, 'cmd' inside a
#          path) must stay 'read', not fail closed. A clean read cannot execute or mutate regardless
#          of its argument text -- its command name is a read-only cmdlet/tool and there is no
#          separator/pipe/subexpression left (step 2a) to smuggle a second command.
#       3) DENY (defense-in-depth) for anything NOT a clean read: eval/dynamic-exec, encoded-command,
#          and shell-escape/arbitrary-exec patterns ($script:LokiDenyPatterns) -> 'denied'.
#       4) Otherwise -> 'mutate' (conservative default; a bare mutation like Remove-Item, or a bare
#          download, lands here and requires confirmation -- it is not blocked outright).
#     Arg-awareness: the FULL argument list is scanned, not just the first token, so a mutating switch
#     hidden after a read-looking flag cannot pass as read. ipconfig: read only bare or '/all'. arp:
#     read only when no -d/-s switch is present (and bare or -a/-g). route: read only when 'print' is
#     present and no -f/-p/add/delete/change token is -- 'arp -a -d x' and 'route print -f' (which
#     real arp.exe/route.exe still act on) are correctly 'mutate'.
#     KNOWN RESIDUAL (ADR-0006): Get-* is trusted by naming convention; a same-named hijacked
#     function/alias/executable on PATH could mutate. The pure string classifier cannot detect that;
#     the enforcement layer (lib/claude.ps1, next slice) adds a runtime Get-Command resolution check
#     (honor Get-* auto-read only for a real Cmdlet, not a Function/Alias/Application) as defense-in-depth.
#     Reason values returned by Get-LokiAllowDecision are STABLE MACHINE TOKENS (English) -- this
#     module does no i18n and produces no user-facing output; the caller renders/localizes.
#   Get-LokiAllowDecision -CommandLine <string> -> [pscustomobject]{ CommandLine; Class;
#     AutoAllowed; RequiresConfirm; Blocked; Reason }
#     Thin caller-facing wrapper around Get-LokiCommandClass. AutoAllowed = (Class -eq 'read'),
#     RequiresConfirm = (Class -eq 'mutate'), Blocked = (Class -eq 'denied'). Reason is one of
#     'read-allowlisted' | 'mutation-requires-confirm' | 'denied'. This is what the future engine
#     wiring (online + offline, DESIGN.md section 5.1: "one allow-list engine for both") calls to
#     gate a proposed command before it runs.
# CLAUDE.md section 5: allow-list, not deny-list, is the gate (read-only automatic, anything
# mutating requires confirmation); deny only defense-in-depth. This module is PURE LOGIC: no
# environment calls, no external processes, no user-facing output -- it only classifies strings.
# ASCII-only file (CLAUDE.md section 1: BOM only required for non-ASCII source) -- no BOM.
Set-StrictMode -Version Latest

# --- DENY patterns (defense-in-depth, checked AFTER the read allow-list so they can never fail-close
#     a genuine read whose arguments merely contain one of these as a substring). Case-insensitive:
#     PowerShell's -match is case-insensitive by default. Each entry is its own array element with a
#     comment so a reviewer can audit the security boundary at a glance. ---
$script:LokiDenyPatterns = @(
    # -- eval / dynamic execution: running a string or scriptblock as code --
    'Invoke-Expression',
    '\biex\b',
    'Invoke-Command',
    '\bicm\b',
    '\[scriptblock\]',
    'ScriptBlock\]::Create',
    '\.invoke\s*\(',

    # -- encoded / obfuscated command: hides the real payload from this classifier --
    '-enc\b',
    '-encodedcommand\b',
    '-e\s',
    'FromBase64String',

    # -- shell-escape / arbitrary process exec: hands off to a different, unfiltered process --
    '\bcmd(\.exe)?\b',
    '\bStart-Process\b',
    '\bsaps\b',
    'Invoke-Item',
    '\bii\b',
    '^start(\.exe)?(\s|$)',      # the `start` alias for Start-Process (launches a program); Start-* cmdlets are unaffected
    '^&',                        # leading call operator: & <path> runs an arbitrary, un-gated program
    '^\.'                        # leading dot: dot-source (. script) or relative-path exec (.\foo) -- arbitrary code
)

# --- Curated read-only command names (first token only, ANY arguments allowed -- these native tools
#     and cmdlets have no state-changing invocation). Membership test (-in) is case-insensitive. ---
$script:LokiPureReadCommands = @(
    'hostname', 'whoami', 'getmac', 'systeminfo', 'ver',
    'netstat', 'nbtstat', 'tracert', 'pathping', 'nslookup', 'ping',
    'tasklist', 'driverquery',
    'Test-NetConnection', 'Test-Connection', 'Resolve-DnsName',
    'Test-Path', 'Resolve-Path', 'Select-String'
)

function Get-LokiCommandClass {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$CommandLine
    )

    # Step 1: empty/whitespace-only -> denied.
    $c = $CommandLine.Trim()
    if ([string]::IsNullOrEmpty($c)) {
        return 'denied'
    }

    # Step 2: READ (checked BEFORE deny -- see header). Only if both (a) and (b) hold.
    # (a) No unsafe separator/pipe/subexpression/redirection/scriptblock character, and no newline.
    $hasUnsafeChar = $c -match '[;|&`$(){}<>]'
    $hasNewline = $c -match '[\r\n]'

    if ((-not $hasUnsafeChar) -and (-not $hasNewline)) {
        # Safe to tokenize by whitespace now: step 2a guaranteed no separator hides a second command.
        $tokens = $c -split '\s+'
        $first = $tokens[0]
        $cmdArgs = @()
        if ($tokens.Count -gt 1) {
            $cmdArgs = $tokens[1..($tokens.Count - 1)]
        }

        $isRead = $false

        # (b) the first token matches a curated read-only pattern.
        # CultureInvariant is load-bearing, not decoration: -match folds case using the CURRENT CULTURE, and in
        # tr-TR/az 'I' folds to the dotless 'i' (U+0131), which is NOT in [A-Za-z]. On a Turkish host 'Get-ChildItem'
        # / 'Get-CimInstance' / 'Get-Item' therefore stopped matching and were classified 'mutate' -- Loki's own
        # read-only diagnostics denied on the machine it was brought to diagnose. Case-insensitivity itself is
        # INTENDED here (PowerShell command names are case-insensitive: 'get-process' is a legal invocation), so
        # -cmatch would be the wrong fix -- it would reject the lowercase spelling instead. Keep IgnoreCase, drop the
        # culture. Verified in a real tr-TR process, before and after.
        if ([regex]::IsMatch($first, '^Get-[A-Za-z][A-Za-z0-9]*$', 'IgnoreCase,CultureInvariant')) {
            # Any Get-* cmdlet, any arguments -- Get is the read verb. See KNOWN RESIDUAL in header.
            $isRead = $true
        }
        elseif ($first -in $script:LokiPureReadCommands) {
            # Pure-read command, any arguments.
            $isRead = $true
        }
        elseif ($first -ieq 'ipconfig') {
            # No args, or the only arg is /all. /release /renew /flushdns /registerdns -> NOT read.
            if ($cmdArgs.Count -eq 0) {
                $isRead = $true
            }
            elseif (($cmdArgs.Count -eq 1) -and ($cmdArgs[0] -ieq '/all')) {
                $isRead = $true
            }
        }
        elseif ($first -ieq 'arp') {
            # -d (delete) and -s (add) are the only mutating arp switches. Scan the WHOLE arg list so
            # 'arp -a -d <ip>' -- which arp.exe still processes -- is not mis-read as read.
            $arpMutates = @($cmdArgs | Where-Object { ($_ -ieq '-d') -or ($_ -ieq '-s') }).Count -gt 0
            if (-not $arpMutates) {
                if ($cmdArgs.Count -eq 0) {
                    $isRead = $true
                }
                elseif (($cmdArgs[0] -ieq '-a') -or ($cmdArgs[0] -ieq '-g')) {
                    $isRead = $true
                }
            }
        }
        elseif ($first -ieq 'route') {
            # 'print' is the only read subcommand; -f (flush) mutates even alongside print, and
            # -p/add/delete/change mutate. Scan the whole arg list, not just the first token.
            $routeMutates = @($cmdArgs | Where-Object {
                    ($_ -ieq '-f') -or ($_ -ieq '-p') -or ($_ -ieq 'add') -or ($_ -ieq 'delete') -or ($_ -ieq 'change')
                }).Count -gt 0
            $routeHasPrint = @($cmdArgs | Where-Object { $_ -ieq 'print' }).Count -gt 0
            if ($routeHasPrint -and (-not $routeMutates)) {
                $isRead = $true
            }
        }

        if ($isRead) {
            return 'read'
        }
    }

    # Step 3: DENY (defense-in-depth) for anything that is NOT a clean read. First match wins.
    foreach ($pattern in $script:LokiDenyPatterns) {
        if ($c -match $pattern) {
            return 'denied'
        }
    }

    # Step 4: conservative default -- anything not provably read-only is a mutation candidate.
    return 'mutate'
}

function Get-LokiAllowDecision {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$CommandLine
    )

    $class = Get-LokiCommandClass -CommandLine $CommandLine

    $reason = 'denied'
    if ($class -eq 'read') {
        $reason = 'read-allowlisted'
    }
    elseif ($class -eq 'mutate') {
        $reason = 'mutation-requires-confirm'
    }

    return [pscustomobject]@{
        CommandLine     = $CommandLine
        Class           = $class
        AutoAllowed     = ($class -eq 'read')
        RequiresConfirm = ($class -eq 'mutate')
        Blocked         = ($class -eq 'denied')
        Reason          = $reason
    }
}
