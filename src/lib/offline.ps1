# lib/offline.ps1 -- the offline command's shared logic (commands/offline.ps1 stays thin wiring, CLAUDE.md section 2).
# This slice adds ONLY the pure context-size policy that ADR-0015 deliberately left to the command slice:
# Get-LokiLlamaServerArgs takes -CtxSize but refuses to invent it ("the POLICY belongs to the caller"). The engine
# orchestration (Invoke-LokiOfflineAnalyze: integrity preflight + engine chat) lands in the next slice and shares
# this file.
#
# Contract:
#   Get-LokiOfflineContextSize -ModelMaxContext <int> -DumpChars <int> [-AnswerTokens <int>] -> [int]
#       The --ctx-size to start llama-server with for a single `offline --analyze` turn. PURE; sized to the task;
#       never 0 (Get-LokiLlamaServerArgs throws on 0 by design); never above the model's declared max context.
# ASCII-only file -> no BOM (CLAUDE.md section 1).
Set-StrictMode -Version Latest

# For `offline --analyze` the window must hold the system prompt + the whole dump + the answer, and nothing more --
# a larger window is only KV cache we pay RAM for and never fill. The heavy RAM guard (model WEIGHTS vs available)
# is the engine preflight (Resolve-LokiEnginePreflight); this ceiling bounds the KV-cache side, so a model that can
# do 262144 tokens does not reserve a quarter-million-token window to summarise a 3 KB dump. A RAM-aware reduction
# below the ceiling would need the model's KV geometry (n_layer / n_kv_head / head_dim), which is not in the
# manifest; deferred deliberately rather than guessed.
$script:LokiOfflineCtxFloor        = 2048    # never ship a trivially small window; too-small is its own failure mode
$script:LokiOfflineCtxCeiling      = 16384   # analyze never needs more; caps KV-cache RAM regardless of model max
$script:LokiOfflineCtxSystemTokens = 256     # the analyze system prompt + role/formatting overhead (generous)
$script:LokiOfflineCtxMargin       = 256     # BOS/template tokens and rounding slack
$script:LokiOfflineCharsPerToken   = 3.0     # ~4 is the English rule of thumb; divide by 3 so a number/path-dense
                                             # dump is OVER-estimated rather than truncated -- truncating the dump
                                             # would hide the very evidence the model is there to read.

function Get-LokiOfflineContextSize {
    param(
        [Parameter(Mandatory = $true)][int]$ModelMaxContext,
        [Parameter(Mandatory = $true)][int]$DumpChars,
        [int]$AnswerTokens = 768
    )
    if ($ModelMaxContext -le 0) { throw 'Offline: ModelMaxContext must be positive (the manifest ContextTokens).' }
    if ($DumpChars -lt 0) { throw 'Offline: DumpChars cannot be negative.' }

    $dumpTokens = [int][math]::Ceiling($DumpChars / $script:LokiOfflineCharsPerToken)
    $needed = $dumpTokens + $script:LokiOfflineCtxSystemTokens + [math]::Max(0, $AnswerTokens) + $script:LokiOfflineCtxMargin

    # Cap by BOTH the model's real max and the analyze ceiling, size to the task above the floor, then never exceed
    # the cap -- so a model whose declared context is smaller than our floor still wins (we cannot ask for more than
    # exists), and a giant dump is capped rather than allowed to reserve the model's whole window.
    $cap = [math]::Min($ModelMaxContext, $script:LokiOfflineCtxCeiling)
    $ctx = [math]::Max($script:LokiOfflineCtxFloor, $needed)
    if ($ctx -gt $cap) { $ctx = $cap }

    # Round UP to a multiple of 256 for a clean, reproducible window, then re-clamp (rounding may cross the cap).
    $ctx = [int]([math]::Ceiling($ctx / 256.0) * 256)
    if ($ctx -gt $cap) { $ctx = $cap }
    return $ctx
}
