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
