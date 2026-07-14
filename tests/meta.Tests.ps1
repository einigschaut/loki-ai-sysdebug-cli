# tests/meta.Tests.ps1 — Version resolution (stick layout: VERSION next to loki.ps1; repo: one level up).
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\meta.ps1"
    $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ("loki-meta-" + [System.Guid]::NewGuid().ToString('N'))
}

AfterAll {
    if (Test-Path -LiteralPath $script:Work) { Remove-Item -LiteralPath $script:Work -Recurse -Force }
}

Describe 'Get-LokiVersion' {

    It 'reads VERSION directly in AppRoot (stick layout)' {
        $app = Join-Path $script:Work 'stick'
        New-Item -ItemType Directory -Force -Path $app | Out-Null
        Set-Content -LiteralPath (Join-Path $app 'VERSION') -Value '1.2.3' -Encoding utf8
        Get-LokiVersion -AppRoot $app | Should -Be '1.2.3'
    }

    It 'reads VERSION one level up (repo layout: src\ + ..\VERSION)' {
        $root = Join-Path $script:Work 'repo'
        $src  = Join-Path $root 'src'
        New-Item -ItemType Directory -Force -Path $src | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'VERSION') -Value '9.9.9' -Encoding utf8
        Get-LokiVersion -AppRoot $src | Should -Be '9.9.9'
    }

    It 'trims whitespace/line breaks' {
        $app = Join-Path $script:Work 'trim'
        New-Item -ItemType Directory -Force -Path $app | Out-Null
        Set-Content -LiteralPath (Join-Path $app 'VERSION') -Value "  0.4.2 `r`n" -Encoding utf8
        Get-LokiVersion -AppRoot $app | Should -Be '0.4.2'
    }

    It 'falls back to 0.0.0-unknown when no VERSION exists' {
        $app = Join-Path $script:Work 'empty'
        New-Item -ItemType Directory -Force -Path $app | Out-Null
        Get-LokiVersion -AppRoot $app | Should -Be '0.0.0-unknown'
    }
}
