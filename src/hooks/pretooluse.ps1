# src/hooks/pretooluse.ps1 -- Claude Code PreToolUse hook entry point (online engine enforcement, security core).
# Claude Code (headless `-p`) spawns this per Bash tool call: it pipes the hook input JSON on STDIN and reads the
# permission decision envelope from STDOUT (exit 0). All real logic lives in the unit-tested lib/claude.ps1
# (Get-LokiPreToolUseDecision); this shim is only I/O glue plus an ultimate fail-closed fallback.
# Registered via lib/claude.ps1 -> New-LokiHookSettingsObject as:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File <this script>
# ASCII-only, no BOM (CLAUDE.md section 1). Prints NOTHING to stdout except the single compact JSON envelope
# (a stray stdout line would corrupt the decision -- hence -NoProfile and no other output).
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    . (Join-Path $PSScriptRoot '..\lib\allowlist.ps1')
    . (Join-Path $PSScriptRoot '..\lib\claude.ps1')

    $stdin = [Console]::In.ReadToEnd()
    $decision = Get-LokiPreToolUseDecision -HookInputJson $stdin
    [Console]::Out.Write(($decision | ConvertTo-Json -Depth 5 -Compress))
    exit 0
}
catch {
    # Ultimate fail-closed: if dot-sourcing or classification ever throws, deny the tool call. Hardcoded envelope
    # so this path depends on nothing that could itself be broken.
    [Console]::Out.Write('{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"loki-deny-hook-exception"}}')
    exit 0
}
