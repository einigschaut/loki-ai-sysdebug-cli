# lib/offline-agent.ps1 -- the offline AGENT loop (security core, CLAUDE.md section 5, ADR-0021).
# `offline --agent` is the multi-turn, READ-ONLY, tool-calling loop DESIGN.md section 3 promises from the ~8B tier.
# This file owns the loop, the run_command tool protocol, and the gated read-only execution; the `offline` command
# (commands/offline.ps1) only ROUTES --agent here (thin dispatcher, CLAUDE.md section 2). It REUSES, never
# re-implements: Invoke-LokiEngineChat / Protect-LokiOfflineDumpText / Get-LokiOfflineFailure (lib/offline.ps1) and
# Get-LokiAllowDecision (lib/allowlist.ps1).
#
# SECURITY (ADR-0021): Slice 2a is READ-ONLY. Every model-proposed command goes through the ONE allow-list engine and
# only a `read` decision executes; `mutate`/`denied` are refused this slice (confirm-gated mutation is 2b). The model
# proposes commands (ACTIONS, not data), so command OUTPUT is untrusted too and is neutralized before it re-enters the
# model context; the loop carries hard iteration + time caps. The dangerous parts -- grammar-constrained tool args
# (#20), gated isolated execution + the Get-Command cmdlet-resolution check (#21), and the capped loop (#22) -- land on
# this branch and get the mandatory Opus adversarial review before it merges.
#
# Contract (this scaffold slice, #19):
#   Test-LokiOfflineAgentCapable -Model <entry> -> [bool]
#       PURE. True iff the model's tier is at or above the ~8B agent floor (the `mid` tier, DESIGN.md section 3).
#       Fails safe: an unranked/unknown tier id is treated as BELOW the floor.
#   Get-LokiOfflineTierRank -> [string[]]
#       PURE. The tier-capability ranking (smallest first). Exposed so the drift test can assert every manifest tier
#       id is ranked -- a new tier nobody classified fails a test instead of silently declining.
#   Invoke-LokiOfflineAgent -AppRoot -Engine -Runtime -Model [-MaxIterations -TimeBudgetSec] -> [hashtable]{ Ok; Reason; Answer? }
#       The loop entry the command calls for a CAPABLE model. #20-#22 implement it; in this scaffold it is an explicit
#       WIP throw so a half-built loop can never masquerade as a working one (CLAUDE.md section 9).
# ASCII-only file -> no BOM (CLAUDE.md section 1).
Set-StrictMode -Version Latest

# Capability rank of the model tiers, smallest first -- the manifest tier ids (DESIGN.md section 3 table:
# nano 1.7B / small 4B / mid 8B / large 14B / max 32B). The agent LOOP needs a model that can plan multi-turn tool
# calls reliably; DESIGN.md puts that floor at the ~8B tier ('mid') and the local tier eval agreed. This is an ORDERED
# floor, not a fixed allow-set: a larger tier added to the catalog later is agent-capable automatically, while a NEW
# tier id that is not ranked here fails tests\offline-agent.Tests.ps1 (which asserts every manifest id is ranked)
# rather than silently passing. Below the floor, `offline --agent` declines and points at --analyze (ADR-0021) -- it
# does not run a loop DESIGN.md itself calls unreliable there.
$script:LokiOfflineTierRank = @('nano', 'small', 'mid', 'large', 'large-longctx', 'max', 'max-ceiling')
$script:LokiOfflineAgentFloorTierId = 'mid'

function Get-LokiOfflineTierRank {
    # Return a COPY (the leading comma keeps a single-element result an array) so a caller cannot mutate the policy.
    return , @($script:LokiOfflineTierRank)
}

function Test-LokiOfflineAgentCapable {
    param([Parameter(Mandatory = $true)]$Model)

    $id = [string]$Model.Id
    $rank  = $script:LokiOfflineTierRank.IndexOf($id)
    $floor = $script:LokiOfflineTierRank.IndexOf($script:LokiOfflineAgentFloorTierId)
    # Fail safe: an id not in the rank (unknown or renamed tier) is -1 -> below the floor -> not agent-capable.
    if ($rank -lt 0) { return $false }
    return ($rank -ge $floor)
}

function Invoke-LokiOfflineAgent {
    <#
        The read-only agent loop entry for a CAPABLE model (Test-LokiOfflineAgentCapable already said yes). Slice 2a
        builds this across #20 (run_command tool + grammar), #21 (gated isolated execution + the Get-Command
        cmdlet-resolution check), and #22 (the capped multi-turn loop). Until then it is an explicit WIP throw, on
        purpose: a security core must never ship a loop that only looks like it runs (CLAUDE.md section 9, "never mark
        a stub as done"). The whole slice merges as one reviewed unit, so this throw is replaced before any PR.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$AppRoot,
        [Parameter(Mandatory = $true)]$Engine,
        [Parameter(Mandatory = $true)]$Runtime,
        [Parameter(Mandatory = $true)]$Model,
        [int]$MaxIterations = 8,
        [int]$TimeBudgetSec = 300
    )
    throw 'offline --agent loop is not yet wired (Slice 2a: #20 tool protocol, #21 gated execution, #22 the loop).'
}
