# tests/net.Tests.ps1 — Reachability probe: returns [bool], never throws, never blocks past the timeout.
# Deterministic without external network: closed localhost port (fast RST) + unroutable TEST-NET-IP (RFC5737).
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\net.ps1"
}

Describe 'Test-LokiConnectivity' {

    It 'returns a [bool]' {
        $r = Test-LokiConnectivity -TargetHost '127.0.0.1' -Port 9 -TimeoutMs 300
        $r | Should -BeOfType [bool]
    }

    It 'closed localhost port => $false' {
        # Port 1 is practically never bound -> connection refused -> $false
        Test-LokiConnectivity -TargetHost '127.0.0.1' -Port 1 -TimeoutMs 500 | Should -BeFalse
    }

    It 'unroutable address => $false, returns within the timeout (no 30s freeze)' {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Test-LokiConnectivity -TargetHost '192.0.2.1' -Port 443 -TimeoutMs 400
        $sw.Stop()
        $r | Should -BeFalse
        # generous upper bound: timeout 400ms + slack; proves it doesn't wait for the OS default (~21s)
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 5
    }

    It 'does not throw on an unresolvable hostname' {
        { Test-LokiConnectivity -TargetHost 'nope.invalid.loki.test' -Port 443 -TimeoutMs 300 } | Should -Not -Throw
    }
}
