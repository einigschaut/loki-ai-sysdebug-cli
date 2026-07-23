# tests/meta.Tests.ps1 — Version resolution (stick layout: version.txt next to loki.ps1; repo: one level up)
# plus the repo version-state gate (version.txt must be valid SemVer). See ADR-0005.
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\meta.ps1"
    $script:Work    = Join-Path ([System.IO.Path]::GetTempPath()) ("loki-meta-" + [System.Guid]::NewGuid().ToString('N'))
    $script:RepoVer = Join-Path $PSScriptRoot '..\version.txt'
}

AfterAll {
    if (Test-Path -LiteralPath $script:Work) { Remove-Item -LiteralPath $script:Work -Recurse -Force }
}

Describe 'Get-LokiVersion' {

    It 'reads version.txt directly in AppRoot (stick layout)' {
        $app = Join-Path $script:Work 'stick'
        New-Item -ItemType Directory -Force -Path $app | Out-Null
        Set-Content -LiteralPath (Join-Path $app 'version.txt') -Value '1.2.3' -Encoding utf8
        Get-LokiVersion -AppRoot $app | Should -Be '1.2.3'
    }

    It 'reads version.txt one level up (repo layout: src\ + ..\version.txt)' {
        $root = Join-Path $script:Work 'repo'
        $src  = Join-Path $root 'src'
        New-Item -ItemType Directory -Force -Path $src | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'version.txt') -Value '9.9.9' -Encoding utf8
        Get-LokiVersion -AppRoot $src | Should -Be '9.9.9'
    }

    It 'trims whitespace/line breaks' {
        $app = Join-Path $script:Work 'trim'
        New-Item -ItemType Directory -Force -Path $app | Out-Null
        Set-Content -LiteralPath (Join-Path $app 'version.txt') -Value "  0.4.2 `r`n" -Encoding utf8
        Get-LokiVersion -AppRoot $app | Should -Be '0.4.2'
    }

    It 'falls back to 0.0.0-unknown when no version.txt exists' {
        $app = Join-Path $script:Work 'empty'
        New-Item -ItemType Directory -Force -Path $app | Out-Null
        Get-LokiVersion -AppRoot $app | Should -Be '0.0.0-unknown'
    }
}

Describe 'version.txt (repo version state)' {

    It 'exists at the repo root' {
        Test-Path -LiteralPath $script:RepoVer | Should -BeTrue
    }

    It 'is a single line of valid SemVer (no drift into non-SemVer)' {
        # Guards the "version state in documents" problem: the shipped version must always be
        # machine-parseable SemVer (major.minor.patch[-prerelease][+build]) -- release-please
        # depends on this, and the CLI prints it verbatim. See ADR-0005.
        $raw   = (Get-Content -LiteralPath $script:RepoVer -Raw -Encoding utf8).Trim()
        $semver = '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
        $raw | Should -Match $semver
    }

    It 'is carried through by Get-LokiVersion (source of truth == what the CLI reports)' {
        $expected = (Get-Content -LiteralPath $script:RepoVer -Raw -Encoding utf8).Trim()
        # AppRoot = src\; Get-LokiVersion resolves ..\version.txt (repo layout).
        Get-LokiVersion -AppRoot (Join-Path $PSScriptRoot '..\src') | Should -Be $expected
    }
}

Describe 'Get-LokiStickAgeDays (#91 -- PURE, deterministic: Now is passed in, never Get-Date)' {
    # UTC DateTimes throughout so there is no timezone ambiguity in the arithmetic.
    It 'counts whole days between the build stamp and now' {
        $now = [datetime]::new(2026, 1, 11, 0, 0, 0, [System.DateTimeKind]::Utc)
        Get-LokiStickAgeDays -BuiltUtc '2026-01-01T00:00:00Z' -Now $now | Should -Be 10
    }
    It 'is 0 on the day it was built' {
        $now = [datetime]::new(2026, 1, 1, 18, 0, 0, [System.DateTimeKind]::Utc)
        Get-LokiStickAgeDays -BuiltUtc '2026-01-01T06:00:00Z' -Now $now | Should -Be 0
    }
    It 'clamps a future build stamp (skewed clock) to 0, never negative' {
        $now = [datetime]::new(2026, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
        Get-LokiStickAgeDays -BuiltUtc '2026-06-01T00:00:00Z' -Now $now | Should -Be 0
    }
    It 'honours an explicit offset (not just Z)' {
        # 2026-01-01T02:00:00+02:00 == 00:00Z; one day before 2026-01-02T00:00Z.
        $now = [datetime]::new(2026, 1, 2, 0, 0, 0, [System.DateTimeKind]::Utc)
        Get-LokiStickAgeDays -BuiltUtc '2026-01-01T02:00:00+02:00' -Now $now | Should -Be 1
    }
    It 'BREAK-THE-GUARD: returns $null on an unparseable stamp rather than throwing' {
        $now = [datetime]::new(2026, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
        Get-LokiStickAgeDays -BuiltUtc 'not-a-date' -Now $now | Should -BeNullOrEmpty
        Get-LokiStickAgeDays -BuiltUtc '' -Now $now            | Should -BeNullOrEmpty
    }
}

Describe 'Get-LokiStickBuildInfo (#91 -- reads stick-build.json, silent on absence)' {
    It 'reads a well-formed stamp' {
        $app = Join-Path $script:Work 'stamp-ok'
        New-Item -ItemType Directory -Force -Path $app | Out-Null
        Set-Content -LiteralPath (Join-Path $app 'stick-build.json') -Encoding utf8 `
            -Value '{"builtUtc":"2026-07-23T14:32:05Z","sourceVersion":"0.14.0"}'
        $info = Get-LokiStickBuildInfo -AppRoot $app
        $info.BuiltUtc      | Should -Be '2026-07-23T14:32:05Z'
        $info.SourceVersion | Should -Be '0.14.0'
    }
    It 'returns $null when there is no stamp (the ordinary repo-checkout case)' {
        $app = Join-Path $script:Work 'stamp-none'
        New-Item -ItemType Directory -Force -Path $app | Out-Null
        Get-LokiStickBuildInfo -AppRoot $app | Should -BeNullOrEmpty
    }
    It 'returns $null on a corrupt stamp rather than failing a write-free status' {
        $app = Join-Path $script:Work 'stamp-bad'
        New-Item -ItemType Directory -Force -Path $app | Out-Null
        Set-Content -LiteralPath (Join-Path $app 'stick-build.json') -Value '{ this is not json' -Encoding utf8
        Get-LokiStickBuildInfo -AppRoot $app | Should -BeNullOrEmpty
    }
    It 'returns $null when the stamp has no builtUtc (nothing to age)' {
        $app = Join-Path $script:Work 'stamp-nodate'
        New-Item -ItemType Directory -Force -Path $app | Out-Null
        Set-Content -LiteralPath (Join-Path $app 'stick-build.json') -Value '{"sourceVersion":"0.14.0"}' -Encoding utf8
        Get-LokiStickBuildInfo -AppRoot $app | Should -BeNullOrEmpty
    }
}
