# tests/footprint.Tests.ps1 -- footprint gate (security core, CLAUDE.md section 5/6, ADR-0010). Release blocker.
# Covers: the PURE diff (Compare) as a table, the target list, the non-recursive fingerprint/snapshot against real
# temp dirs, the REAL isolation self-probe run once for real (CLAUDE.md section 6), and a break-the-guard proving a
# leak into a host probe-target is caught (and that a soft standing change is reported but does NOT fail the gate).
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\env-isolate.ps1"
    . "$PSScriptRoot\..\src\lib\footprint.ps1"

    $script:RootTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("loki-footprint-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:RootTmp | Out-Null

    # A fresh temp tree per case. Returns a "host" root (with empty appdata/local/temp subdirs to watch) and a
    # separate "stick" AppRoot -- deliberately distinct so a working redirect writes to the stick, not the host.
    function global:New-FootprintCase {
        $case = Join-Path $script:RootTmp ([System.Guid]::NewGuid().ToString('N'))
        $hostProfile = Join-Path $case 'host'
        $hostAppData = Join-Path $hostProfile 'AppData\Roaming'
        $hostLocal = Join-Path $hostProfile 'AppData\Local'
        $hostTemp = Join-Path $hostProfile 'Temp'
        $appRoot = Join-Path $case 'stick'
        foreach ($d in @($hostProfile, $hostAppData, $hostLocal, $hostTemp, (Join-Path $appRoot 'home'))) {
            New-Item -ItemType Directory -Force -Path $d | Out-Null
        }
        return [pscustomobject]@{
            HostProfile = $hostProfile; HostAppData = $hostAppData; HostLocal = $hostLocal; HostTemp = $hostTemp; AppRoot = $appRoot
        }
    }
}

AfterAll {
    if (Test-Path -LiteralPath $script:RootTmp) { Remove-Item -LiteralPath $script:RootTmp -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item Function:\New-FootprintCase -ErrorAction SilentlyContinue
}

Describe 'Compare-LokiFootprintSnapshot (pure diff)' {

    It 'identical snapshots -> Clean, nothing added/changed' {
        $s = @{ a = @{ Exists = $true; Kind = 'dir'; ChildCount = 0; LastWriteUtcTicks = 100 } }
        $r = Compare-LokiFootprintSnapshot -Before $s -After $s
        $r.Clean | Should -BeTrue
        $r.Added.Count | Should -Be 0
        $r.Changed.Count | Should -Be 0
    }

    It 'a target that gained existence -> Added, not Clean' {
        $before = @{ a = @{ Exists = $false } }
        $after = @{ a = @{ Exists = $true; Kind = 'dir'; ChildCount = 1; LastWriteUtcTicks = 100 } }
        $r = Compare-LokiFootprintSnapshot -Before $before -After $after
        $r.Clean | Should -BeFalse
        $r.Added | Should -Contain 'a'
    }

    It 'a fingerprint that differs -> Changed, not Clean' {
        $before = @{ a = @{ Exists = $true; Kind = 'dir'; ChildCount = 0; LastWriteUtcTicks = 100 } }
        $after = @{ a = @{ Exists = $true; Kind = 'dir'; ChildCount = 1; LastWriteUtcTicks = 200 } }
        $r = Compare-LokiFootprintSnapshot -Before $before -After $after
        $r.Clean | Should -BeFalse
        $r.Changed | Should -Contain 'a'
    }

    It 'a removal is NOT a footprint -> Clean' {
        $before = @{ a = @{ Exists = $true; Kind = 'file'; Length = 5; LastWriteUtcTicks = 100 } }
        $after = @{ a = @{ Exists = $false } }
        $r = Compare-LokiFootprintSnapshot -Before $before -After $after
        $r.Clean | Should -BeTrue
        $r.Added.Count | Should -Be 0
        $r.Changed.Count | Should -Be 0
    }

    It 'a file changing kind to dir -> Changed' {
        $before = @{ a = @{ Exists = $true; Kind = 'file'; Length = 5; LastWriteUtcTicks = 100 } }
        $after = @{ a = @{ Exists = $true; Kind = 'dir'; ChildCount = 0; LastWriteUtcTicks = 100 } }
        (Compare-LokiFootprintSnapshot -Before $before -After $after).Changed | Should -Contain 'a'
    }

    It 'a file whose length/mtime is unchanged -> Clean' {
        $s = @{ a = @{ Exists = $true; Kind = 'file'; Length = 5; LastWriteUtcTicks = 100 } }
        (Compare-LokiFootprintSnapshot -Before $s -After $s).Clean | Should -BeTrue
    }
}

Describe 'Get-LokiFootprintTargets (pure watch-list)' {

    It 'builds probe- and host- targets from the given roots' {
        $t = Get-LokiFootprintTargets -UserProfile 'C:\u' -AppData 'C:\u\ad' -LocalAppData 'C:\u\la' -Temp 'C:\u\tmp'
        $t.Contains('probe-userprofile') | Should -BeTrue
        $t.Contains('probe-appdata') | Should -BeTrue
        $t.Contains('probe-localappdata') | Should -BeTrue
        $t.Contains('probe-temp') | Should -BeTrue
        $t.Contains('host-userprofile-claude') | Should -BeTrue
        $t.Contains('host-appdata-claude') | Should -BeTrue
        $t.Contains('host-psreadline-history') | Should -BeTrue
    }

    It 'every probe target ends in the loki-footprint-probe dir' {
        $t = Get-LokiFootprintTargets -UserProfile 'C:\u' -AppData 'C:\u\ad' -LocalAppData 'C:\u\la' -Temp 'C:\u\tmp'
        foreach ($k in @($t.Keys)) {
            if (([string]$k).StartsWith('probe-')) { ([string]$t[$k]) | Should -BeLike '*loki-footprint-probe' }
        }
    }

    It 'skips the targets of an empty root' {
        $t = Get-LokiFootprintTargets -UserProfile 'C:\u' -AppData '' -LocalAppData '' -Temp ''
        $t.Contains('probe-userprofile') | Should -BeTrue
        $t.Contains('probe-appdata') | Should -BeFalse
        $t.Contains('probe-temp') | Should -BeFalse
    }
}

Describe 'Get-LokiFootprintSnapshot / fingerprint (against real temp dirs)' {

    It 'a missing path -> Exists false' {
        $c = New-FootprintCase
        $snap = Get-LokiFootprintSnapshot -Targets ([ordered]@{ x = (Join-Path $c.HostProfile 'does-not-exist') })
        $snap['x'].Exists | Should -BeFalse
    }

    It 'a file -> Exists true, Kind file, with length' {
        $c = New-FootprintCase
        $f = Join-Path $c.HostProfile 'file.txt'
        Set-Content -LiteralPath $f -Value 'hello' -Encoding utf8
        $snap = Get-LokiFootprintSnapshot -Targets ([ordered]@{ x = $f })
        $snap['x'].Exists | Should -BeTrue
        $snap['x'].Kind | Should -Be 'file'
        $snap['x'].Length | Should -BeGreaterThan 0
    }

    It 'a directory -> Exists true, Kind dir, and adding a child is seen as Changed' {
        $c = New-FootprintCase
        $d = Join-Path $c.HostProfile 'watched'
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        $targets = [ordered]@{ x = $d }
        $before = Get-LokiFootprintSnapshot -Targets $targets
        $before['x'].Kind | Should -Be 'dir'
        $before['x'].ChildCount | Should -Be 0
        Set-Content -LiteralPath (Join-Path $d 'new.txt') -Value 'leak' -Encoding utf8
        $after = Get-LokiFootprintSnapshot -Targets $targets
        (Compare-LokiFootprintSnapshot -Before $before -After $after).Changed | Should -Contain 'x'
    }
}

Describe 'Invoke-LokiFootprintProbe -- real isolation self-probe (CLAUDE.md section 6)' {

    It 'the isolated write-probe lands on the stick and the host profile stays CLEAN (redirect holds)' {
        $c = New-FootprintCase
        $res = Invoke-LokiFootprintProbe -AppRoot $c.AppRoot -HostUserProfile $c.HostProfile -HostAppData $c.HostAppData -HostLocalAppData $c.HostLocal -HostTemp $c.HostTemp
        $res.ProbeVerified | Should -BeTrue    # positive control: markers reached the stick (not a vacuous pass)
        $res.Clean | Should -BeTrue            # host probe-targets stayed absent
        $res.Leaked.Count | Should -Be 0
    }

    It 'leaves no host probe-dir behind afterwards (cleanup / redirect both correct)' {
        $c = New-FootprintCase
        Invoke-LokiFootprintProbe -AppRoot $c.AppRoot -HostUserProfile $c.HostProfile -HostAppData $c.HostAppData -HostLocalAppData $c.HostLocal -HostTemp $c.HostTemp | Out-Null
        Test-Path -LiteralPath (Join-Path $c.HostAppData 'loki-footprint-probe') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $c.HostProfile 'loki-footprint-probe') | Should -BeFalse
    }
}

Describe 'Invoke-LokiFootprintProbe -- break-the-guard (a leak IS caught)' {

    It 'BREAK-THE-GUARD: an operation that writes into a host PROBE target -> Leaked, not Clean' {
        $c = New-FootprintCase
        $leakDir = Join-Path $c.HostAppData 'loki-footprint-probe'
        $op = {
            New-Item -ItemType Directory -Force -Path $leakDir | Out-Null
            Set-Content -LiteralPath (Join-Path $leakDir 'leak.txt') -Value 'leaked' -Encoding utf8
        }.GetNewClosure()
        $res = Invoke-LokiFootprintProbe -AppRoot $c.AppRoot -HostUserProfile $c.HostProfile -HostAppData $c.HostAppData -HostLocalAppData $c.HostLocal -HostTemp $c.HostTemp -Operation $op
        $res.Clean | Should -BeFalse
        $res.Leaked | Should -Contain 'probe-appdata'
    }

    It 'STATE CHECK: a pre-existing host probe dir (stale from a prior broken run) -> Leaked, not Clean' {
        $c = New-FootprintCase
        $stale = Join-Path $c.HostAppData 'loki-footprint-probe'
        New-Item -ItemType Directory -Force -Path $stale | Out-Null
        Set-Content -LiteralPath (Join-Path $stale 'stale.txt') -Value 'old leak' -Encoding utf8
        # A no-op operation: nothing changes during the window, so ONLY the state check (pre-existing host probe dir)
        # can flag it -- proving the gate is state-based for the hard targets, not merely a window diff.
        $noop = { }
        $res = Invoke-LokiFootprintProbe -AppRoot $c.AppRoot -HostUserProfile $c.HostProfile -HostAppData $c.HostAppData -HostLocalAppData $c.HostLocal -HostTemp $c.HostTemp -Operation $noop
        $res.Clean | Should -BeFalse
        $res.Leaked | Should -Contain 'probe-appdata'
    }

    It 'a change in a SOFT standing location is Observed but does NOT fail the gate' {
        $c = New-FootprintCase
        $claimDir = Join-Path $c.HostProfile '.claude'   # host-userprofile-claude standing target
        $op = {
            New-Item -ItemType Directory -Force -Path $claimDir | Out-Null
            Set-Content -LiteralPath (Join-Path $claimDir 'session.txt') -Value 'x' -Encoding utf8
        }.GetNewClosure()
        $res = Invoke-LokiFootprintProbe -AppRoot $c.AppRoot -HostUserProfile $c.HostProfile -HostAppData $c.HostAppData -HostLocalAppData $c.HostLocal -HostTemp $c.HostTemp -Operation $op
        $res.Observed | Should -Contain 'host-userprofile-claude'
        $res.Clean | Should -BeTrue    # standing change is soft -> the hard gate still passes
    }
}
