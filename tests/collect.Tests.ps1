# tests/collect.Tests.ps1 -- the raw collector (src/lib/collect.ps1), ADR-0018.
# The pure half (ISO timestamps, the row-list guard, scalar formatting, the document/JSON/text shaping) is
# table-tested without touching a machine; the impure half is tested for the one property that matters most --
# it never throws, whatever the probe does.
#
# Two of these are REGRESSION tests for defects this module actually had, not hypotheticals:
#   * the renderer died with "Insufficient stack" on Get-LokiMemoryConsumer's HASHTABLE rows (a dictionary is
#     IEnumerable but @($h) wraps it into a single element that is the same object -> infinite recursion);
#   * ConvertTo-Json emits \/Date(ms)\/ for a raw DateTime under 5.1, which no consumer of this dump can read.
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\hwscan.ps1"
    . "$PSScriptRoot\..\src\lib\posture.ps1"
    . "$PSScriptRoot\..\src\lib\net.ps1"
    . "$PSScriptRoot\..\src\lib\collect.ps1"

    # A dump with every shape the batteries really produce: a flat object, a list of object rows, an object holding
    # a nested list, and -- deliberately -- a list of HASHTABLE rows, the shape that ran the renderer into the ground.
    # Every number carries a fractional part on purpose: a test whose numbers are whole cannot tell "38.4" from
    # "38,4" and would pass under any culture, which is exactly the failure mode PR #36 was about.
    function global:New-FakeCollectDump {
        param($CreatedAt = ([datetime]'2026-07-16 14:30:00'))
        [pscustomobject]@{
            CreatedAt = $CreatedAt
            Batteries = @(
                [pscustomobject]@{
                    Id = 'os'; Status = 'ok'; DurationMs = 441; Error = $null
                    Data = [pscustomobject]@{
                        Caption        = 'Microsoft Windows 11 Pro'
                        UptimeHours    = 34.2
                        LastBootUpTime = '2026-07-15T13:54:14.5000000+02:00'
                    }
                },
                [pscustomobject]@{
                    Id = 'storage'; Status = 'ok'; DurationMs = 404; Error = $null
                    Data = @(
                        [pscustomobject]@{ Drive = 'C:'; SizeGB = 473.88; PercentFree = 40.1 },
                        [pscustomobject]@{ Drive = 'D:'; SizeGB = 114.53; PercentFree = 99.9 }
                    )
                },
                [pscustomobject]@{
                    Id = 'network'; Status = 'ok'; DurationMs = 115; Error = $null
                    Data = [pscustomobject]@{
                        Reachable = $true
                        Adapters  = @(
                            [pscustomobject]@{
                                Description = 'Realtek USB GbE'
                                IpAddress   = @('192.168.20.107', 'fe80::1')
                                DnsServers  = @('192.168.20.11')
                            }
                        )
                    }
                },
                [pscustomobject]@{
                    # HASHTABLE rows -- the regression shape. Get-LokiMemoryConsumer really returns these.
                    Id = 'processes'; Status = 'ok'; DurationMs = 63; Error = $null
                    Data = @(
                        @{ Name = 'firefox'; ProcessCount = 21; ResidentGB = 2.41 },
                        @{ Name = 'svchost'; ProcessCount = 104; ResidentGB = 1.55 }
                    )
                },
                [pscustomobject]@{
                    Id = 'services'; Status = 'timeout'; DurationMs = 10004; Data = $null
                    Error = 'Timed out'
                }
            )
        }
    }
}

AfterAll {
    Remove-Item Function:\New-FakeCollectDump -ErrorAction SilentlyContinue
}

Describe 'Get-LokiCollectBatteryId' {
    It 'returns the documented battery set, in report order' {
        # ASSIGN, then count. @(Get-LokiCollectBatteryId) would report 1 whatever the real length is -- the
        # `return ,` landmine this module was bitten by (see Get-LokiCollectProcessData).
        $ids = Get-LokiCollectBatteryId
        @($ids).Count | Should -Be 7
        @($ids)[0] | Should -Be 'os'
        $ids | Should -Contain 'services'
        $ids | Should -Contain 'posture'
    }

    It 'does not include the event-log battery (deferred to its own PR, ADR-0018)' {
        $ids = Get-LokiCollectBatteryId
        $ids | Should -Not -Contain 'eventlog'
    }

    It 'ids are lowercase machine tokens, never prose' {
        foreach ($id in (Get-LokiCollectBatteryId)) {
            $id | Should -Match '^[a-z]+$'
        }
    }
}

Describe 'ConvertTo-LokiIsoTimestamp' {
    It 'renders a DateTime as ISO-8601 with an explicit offset' {
        $r = ConvertTo-LokiIsoTimestamp -Value ([datetime]'2026-07-16 14:30:00')
        $r | Should -Match '^2026-07-16T14:30:00'
        # The offset must be present -- a bare local wall-clock is ambiguous to every consumer of the dump.
        $r | Should -Match '(\+|\-)\d{2}:\d{2}$'
    }

    It 'round-trips exactly (the property /Date(ms)/ does NOT have)' {
        $original = [datetime]'2026-07-16 14:30:00'
        $iso = ConvertTo-LokiIsoTimestamp -Value $original
        $parsed = [datetime]::Parse($iso, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind)
        $parsed | Should -Be $original
    }

    It 'passes $null through as $null rather than inventing a time' {
        ConvertTo-LokiIsoTimestamp -Value $null | Should -BeNullOrEmpty
    }

    It 'is identical under de-DE and en-US (the artifact must not depend on who ran it)' {
        $original = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
            $de = ConvertTo-LokiIsoTimestamp -Value ([datetime]'2026-07-16 14:30:00')
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
            $en = ConvertTo-LokiIsoTimestamp -Value ([datetime]'2026-07-16 14:30:00')
            $de | Should -Be $en
        }
        finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $original
        }
    }

    It 'degrades to $null instead of throwing on something that is not a time' {
        ConvertTo-LokiIsoTimestamp -Value 'not-a-timestamp' | Should -BeNullOrEmpty
    }
}

Describe 'Get-LokiCollectStamp' {
    It 'is sortable, filename-safe, and free of culture-replaced separators' {
        $stamp = Get-LokiCollectStamp
        $stamp | Should -Match '^\d{8}-\d{6}$'
        # ':' and '/' are culture-REPLACED placeholders in a .NET format string and are both illegal in a filename.
        $stamp | Should -Not -Match '[:/\\]'
    }

    It 'is identical in shape under de-DE' {
        $original = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
            (Get-LokiCollectStamp) | Should -Match '^\d{8}-\d{6}$'
        }
        finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $original
        }
    }
}

Describe 'Get-LokiCollectPath' {
    It 'puts both artifacts in reports\ under the app root, sharing one stamp' {
        $p = Get-LokiCollectPath -AppRoot 'X:\stick\app' -Stamp '20260716-143000'
        $p.Dir | Should -Be 'X:\stick\app\reports'
        $p.JsonPath | Should -Be 'X:\stick\app\reports\collect-20260716-143000.json'
        $p.TextPath | Should -Be 'X:\stick\app\reports\collect-20260716-143000.txt'
    }

    It 'never points at the host profile (the whole footprint guarantee)' {
        $p = Get-LokiCollectPath -AppRoot 'X:\stick\app' -Stamp '20260716-143000'
        $p.JsonPath | Should -Not -Match ([regex]::Escape($env:USERPROFILE))
    }
}

Describe 'Test-LokiCollectRowList' {
    # The guard that keeps the renderer's recursion bounded. Getting this wrong is not cosmetic: the first version
    # answered "yes" for a hashtable and the renderer died with "Insufficient stack" on the first live run.
    It 'says NO for a dictionary -- it is one row, not a list of them (the stack-overflow guard)' {
        Test-LokiCollectRowList -Value @{ Name = 'firefox'; ResidentGB = 2.41 } | Should -BeFalse
    }

    It 'says YES for a list of object rows' {
        Test-LokiCollectRowList -Value @([pscustomobject]@{ A = 1.5; B = 2.5 }) | Should -BeTrue
    }

    It 'says YES for a list of dictionary rows (what Get-LokiMemoryConsumer really returns)' {
        Test-LokiCollectRowList -Value @(@{ Name = 'firefox'; ResidentGB = 2.41 }) | Should -BeTrue
    }

    It 'says NO for a list of scalars -- those render as one joined line' {
        Test-LokiCollectRowList -Value @('192.168.20.107', 'fe80::1') | Should -BeFalse
    }

    It 'says NO for a bare string, an int, $null and an empty list' {
        Test-LokiCollectRowList -Value 'Microsoft Windows 11 Pro' | Should -BeFalse
        Test-LokiCollectRowList -Value 42 | Should -BeFalse
        Test-LokiCollectRowList -Value $null | Should -BeFalse
        Test-LokiCollectRowList -Value @() | Should -BeFalse
    }
}

Describe 'Format-LokiCollectScalar' {
    It 'renders $null as an explicit marker rather than an empty line' {
        Format-LokiCollectScalar -Value $null | Should -Be '(none)'
    }

    It 'renders booleans as JSON-ish lowercase, not PowerShell True/False' {
        Format-LokiCollectScalar -Value $true | Should -Be 'true'
        Format-LokiCollectScalar -Value $false | Should -Be 'false'
    }

    It 'joins a scalar list' {
        Format-LokiCollectScalar -Value @('192.168.20.107', 'fe80::1') | Should -Be '192.168.20.107, fe80::1'
    }

    It 'renders an empty list as (none), not as an empty string' {
        Format-LokiCollectScalar -Value @() | Should -Be '(none)'
    }

    It 'renders a dictionary as pairs, never as DictionaryEntry' {
        $r = Format-LokiCollectScalar -Value ([ordered]@{ Name = 'firefox'; ResidentGB = 2.41 })
        $r | Should -Be 'Name=firefox; ResidentGB=2.41'
        $r | Should -Not -Match 'DictionaryEntry'
    }

    It 'keeps a decimal point under de-DE (the artifact must not follow the machine culture)' {
        $original = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
            # Proof the culture really is active -- otherwise this test would pass on a machine where it is not set
            # and prove nothing at all.
            ('{0}' -f 38.4) | Should -Be '38,4'
            Format-LokiCollectScalar -Value 38.4 | Should -Be '38.4'
        }
        finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $original
        }
    }
}

Describe 'ConvertTo-LokiCollectDocument' {
    It 'stamps the envelope and carries the batteries through' {
        $doc = ConvertTo-LokiCollectDocument -Dump (New-FakeCollectDump) -LokiVersion '0.8.0'
        $doc.SchemaVersion | Should -Be 1
        $doc.Tool | Should -Be 'loki collect'
        $doc.LokiVersion | Should -Be '0.8.0'
        @($doc.Batteries).Count | Should -Be 5
    }

    It 'leaves no DateTime in the document -- CreatedAt is an ISO string' {
        $doc = ConvertTo-LokiCollectDocument -Dump (New-FakeCollectDump) -LokiVersion '0.8.0'
        $doc.CreatedAt | Should -BeOfType [string]
        $doc.CreatedAt | Should -Match '^2026-07-16T14:30:00'
    }
}

Describe 'ConvertTo-LokiCollectJson' {
    It 'never emits the legacy /Date(ms)/ form (the regression guard for every future battery)' {
        $doc = ConvertTo-LokiCollectDocument -Dump (New-FakeCollectDump) -LokiVersion '0.8.0'
        $json = ConvertTo-LokiCollectJson -Document $doc
        $json | Should -Not -Match '/Date\('
    }

    It 'does not truncate the nested rows to "System.Object[]" (the -Depth default is 2)' {
        $doc = ConvertTo-LokiCollectDocument -Dump (New-FakeCollectDump) -LokiVersion '0.8.0'
        $json = ConvertTo-LokiCollectJson -Document $doc
        $json | Should -Not -Match 'System\.Object\[\]'
        # The deepest real value: Batteries[] -> Data -> Adapters[] -> IpAddress[] -> a string.
        $json | Should -Match '192\.168\.20\.107'
    }

    It 'round-trips to the same numbers' {
        $doc = ConvertTo-LokiCollectDocument -Dump (New-FakeCollectDump) -LokiVersion '0.8.0'
        $back = (ConvertTo-LokiCollectJson -Document $doc) | ConvertFrom-Json
        $os = @($back.Batteries | Where-Object { $_.Id -eq 'os' })[0]
        $os.Data.UptimeHours | Should -Be 34.2
    }

    It 'writes a decimal POINT under de-DE (a JSON with 34,2 is not JSON)' {
        $original = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
            ('{0}' -f 34.2) | Should -Be '34,2'   # the culture really is active
            $doc = ConvertTo-LokiCollectDocument -Dump (New-FakeCollectDump) -LokiVersion '0.8.0'
            $json = ConvertTo-LokiCollectJson -Document $doc
            $json | Should -Match '34\.2'
            $json | Should -Not -Match '34,2'
        }
        finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $original
        }
    }
}

Describe 'ConvertTo-LokiCollectText' {
    It 'renders hashtable rows without running out of stack (the reproduced regression)' {
        # This is the exact shape that killed the first live run. If the row-list guard regresses, this does not
        # fail politely -- it takes the whole Pester process down, which is itself an unmissable signal.
        $doc = ConvertTo-LokiCollectDocument -Dump (New-FakeCollectDump) -LokiVersion '0.8.0'
        $lines = ConvertTo-LokiCollectText -Document $doc
        ($lines -join "`n") | Should -Match 'firefox'
        ($lines -join "`n") | Should -Match '2\.41'
    }

    It 'renders every battery with its status and duration' {
        $doc = ConvertTo-LokiCollectDocument -Dump (New-FakeCollectDump) -LokiVersion '0.8.0'
        $text = (ConvertTo-LokiCollectText -Document $doc) -join "`n"
        $text | Should -Match '\[ok\] os \(441 ms\)'
        $text | Should -Match '\[timeout\] services \(10004 ms\)'
    }

    It 'records a failed battery reason instead of a silent gap' {
        $doc = ConvertTo-LokiCollectDocument -Dump (New-FakeCollectDump) -LokiVersion '0.8.0'
        $text = (ConvertTo-LokiCollectText -Document $doc) -join "`n"
        $text | Should -Match 'error: Timed out'
    }

    It 'renders a scalar list on one line rather than as a block' {
        $doc = ConvertTo-LokiCollectDocument -Dump (New-FakeCollectDump) -LokiVersion '0.8.0'
        $text = (ConvertTo-LokiCollectText -Document $doc) -join "`n"
        $text | Should -Match '192\.168\.20\.107, fe80::1'
    }

    It 'renders a bare string value as itself, not as its Length property' {
        # A string's PSObject.Properties is 1 (Length) -- iterating it would print "Length: 24" for an OS caption.
        $doc = ConvertTo-LokiCollectDocument -Dump (New-FakeCollectDump) -LokiVersion '0.8.0'
        $text = (ConvertTo-LokiCollectText -Document $doc) -join "`n"
        $text | Should -Match 'Microsoft Windows 11 Pro'
        $text | Should -Not -Match 'Length\s+:'
    }

    It 'is byte-identical under de-DE and en-US (the artifact does not follow the operator)' {
        $original = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            $doc = ConvertTo-LokiCollectDocument -Dump (New-FakeCollectDump) -LokiVersion '0.8.0'
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
            $de = (ConvertTo-LokiCollectText -Document $doc) -join "`n"
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
            $en = (ConvertTo-LokiCollectText -Document $doc) -join "`n"
            $de | Should -Be $en
        }
        finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $original
        }
    }
}

Describe 'Get-LokiCollectFailureStatus' {
    It 'calls a CIM timeout a timeout, by MessageId rather than by message text' {
        # The text is localizable; the MessageId is not. Build the real shape rather than a stand-in, so the test
        # would notice if the discriminator ever moved.
        $fake = [pscustomobject]@{ Exception = [pscustomobject]@{ MessageId = 'HRESULT 0x40004'; Message = 'whatever' } }
        Get-LokiCollectFailureStatus -ErrorRecord $fake | Should -Be 'timeout'
    }

    It 'calls anything else a failure, including an error with no MessageId at all' {
        $noId = [pscustomobject]@{ Exception = [pscustomobject]@{ Message = 'Access denied' } }
        Get-LokiCollectFailureStatus -ErrorRecord $noId | Should -Be 'failed'

        $otherId = [pscustomobject]@{ Exception = [pscustomobject]@{ MessageId = 'HRESULT 0x80041010'; Message = 'Invalid class' } }
        Get-LokiCollectFailureStatus -ErrorRecord $otherId | Should -Be 'failed'
    }

    It 'never throws, even on $null' {
        Get-LokiCollectFailureStatus -ErrorRecord $null | Should -Be 'failed'
    }
}

Describe 'Invoke-LokiCollectBattery' {
    It 'records an unknown battery as failed instead of throwing (never lose the other six)' {
        $r = Invoke-LokiCollectBattery -Id 'no-such-battery'
        $r.Id | Should -Be 'no-such-battery'
        $r.Status | Should -Be 'failed'
        $r.Data | Should -BeNullOrEmpty
        $r.Error | Should -Match 'unknown battery'
    }

    It 'reports the documented shape and a duration for a real battery' {
        $r = Invoke-LokiCollectBattery -Id 'posture'
        $r.PSObject.Properties.Name | Should -Contain 'Id'
        $r.PSObject.Properties.Name | Should -Contain 'Status'
        $r.PSObject.Properties.Name | Should -Contain 'DurationMs'
        $r.PSObject.Properties.Name | Should -Contain 'Data'
        $r.PSObject.Properties.Name | Should -Contain 'Error'
        $r.DurationMs | Should -BeOfType [int]
        $r.DurationMs | Should -BeGreaterOrEqual 0
    }

    It 'does not throw when the probe itself explodes -- it records the reason' {
        # Break the guard on purpose (CLAUDE.md section 6): a probe that throws must become a recorded failure,
        # never an escaped exception. Get-LokiHostPosture is the `posture` battery's only call.
        $backup = ${function:Get-LokiHostPosture}
        try {
            Set-Item Function:\Get-LokiHostPosture -Value { throw 'probe exploded' }
            $r = Invoke-LokiCollectBattery -Id 'posture'
            $r.Status | Should -Be 'failed'
            $r.Error | Should -Match 'probe exploded'
            $r.Data | Should -BeNullOrEmpty
        }
        finally {
            Set-Item Function:\Get-LokiHostPosture -Value $backup
        }
    }
}

Describe 'Invoke-LokiCollect' {
    It 'runs every battery by default, in report order' {
        $dump = Invoke-LokiCollect
        @($dump.Batteries).Count | Should -Be 7
        @($dump.Batteries)[0].Id | Should -Be 'os'
    }

    It 'honours -Only' {
        $dump = Invoke-LokiCollect -Only @('os', 'posture')
        @($dump.Batteries).Count | Should -Be 2
        @($dump.Batteries).Id | Should -Contain 'os'
        @($dump.Batteries).Id | Should -Not -Contain 'services'
    }

    It 'silently drops an unknown id -- refusing an argument is the command''s job, not the library''s' {
        $dump = Invoke-LokiCollect -Only @('os', 'no-such-battery')
        @($dump.Batteries).Count | Should -Be 1
        @($dump.Batteries)[0].Id | Should -Be 'os'
    }
}
