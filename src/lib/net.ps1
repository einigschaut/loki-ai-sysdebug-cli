# lib/net.ps1 — network helpers (shared; exactly ONE source of truth for reachability)
# Contract:
#   Test-LokiConnectivity [-TargetHost <name>] [-Port <int>] [-TimeoutMs <int>] -> [bool]
#     TCP connect with a short timeout. NEVER blocks for long (guard against the 30s "freeze" on an offline host).
#     No reliance on DNS: connect fails OR the timeout elapses -> $false (never throws outward).
# Used by: status (stage 0); later scan/ask/chat for the online/offline branch.
Set-StrictMode -Version Latest

function Test-LokiConnectivity {
    param(
        [string]$TargetHost = 'api.anthropic.com',
        [int]$Port = 443,
        [int]$TimeoutMs = 1500
    )
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $async = $client.BeginConnect($TargetHost, $Port, $null, $null)
        $ok = $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($ok -and $client.Connected) {
            $client.EndConnect($async)
            return $true
        }
        return $false
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $client) { $client.Close() }
    }
}
