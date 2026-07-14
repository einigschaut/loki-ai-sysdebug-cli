# tests/config.Tests.ps1 - Settings precedence Flag > Env > Config > Default + JSON config reading.
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\config.ps1"
    $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ("loki-config-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:Work | Out-Null
}

AfterAll {
    if (Test-Path -LiteralPath $script:Work) { Remove-Item -LiteralPath $script:Work -Recurse -Force }
    # Safety net: in case a test fails early and AfterEach did not run.
    foreach ($n in @('LOKI_TESTKEY', 'LOKI_ENGINETIER', 'LOKI_CUSTOMNAME')) {
        if (Test-Path "Env:\$n") { Remove-Item "Env:\$n" -Force }
    }
}

Describe 'Read-LokiConfig' {

    It 'returns @{} when the file is missing' {
        $missing = Join-Path $script:Work 'does-not-exist.json'
        $result = Read-LokiConfig -Path $missing
        $result | Should -BeOfType [hashtable]
        $result.Count | Should -Be 0
    }

    It 'returns @{} for an empty file' {
        $empty = Join-Path $script:Work 'empty.json'
        Set-Content -LiteralPath $empty -Value '' -Encoding utf8
        $result = Read-LokiConfig -Path $empty
        $result | Should -BeOfType [hashtable]
        $result.Count | Should -Be 0
    }

    It 'reads valid JSON as a hashtable' {
        $file = Join-Path $script:Work 'valid.json'
        Set-Content -LiteralPath $file -Value '{"engine": "cloud", "retries": 3, "verbose": true}' -Encoding utf8
        $result = Read-LokiConfig -Path $file
        $result | Should -BeOfType [hashtable]
        $result['engine'] | Should -Be 'cloud'
        $result['retries'] | Should -Be 3
        $result['verbose'] | Should -Be $true
    }

    It 'converts nested objects and arrays recursively into hashtables/arrays' {
        $file = Join-Path $script:Work 'nested.json'
        Set-Content -LiteralPath $file -Value '{"auth": {"mode": "oauth"}, "tags": ["a", "b"]}' -Encoding utf8
        $result = Read-LokiConfig -Path $file
        $result['auth'] | Should -BeOfType [hashtable]
        $result['auth']['mode'] | Should -Be 'oauth'
        , $result['tags'] | Should -BeOfType [array]
        $result['tags'][0] | Should -Be 'a'
        $result['tags'][1] | Should -Be 'b'
    }

    It 'keeps an explicit JSON null value as $null in the result (key stays present)' {
        $file = Join-Path $script:Work 'nullvalue.json'
        Set-Content -LiteralPath $file -Value '{"engine": null}' -Encoding utf8
        $result = Read-LokiConfig -Path $file
        $result.ContainsKey('engine') | Should -BeTrue
        $result['engine'] | Should -Be $null
    }

    It 'throws a clear, terminating error on broken JSON' {
        $file = Join-Path $script:Work 'broken.json'
        Set-Content -LiteralPath $file -Value '{ "engine": ' -Encoding utf8
        { Read-LokiConfig -Path $file } | Should -Throw "Invalid Loki config: $file"
    }

    It 'throws when the JSON root is not an object (e.g. an array)' {
        $file = Join-Path $script:Work 'array-root.json'
        Set-Content -LiteralPath $file -Value '["a", "b"]' -Encoding utf8
        { Read-LokiConfig -Path $file } | Should -Throw "Invalid Loki config: $file"
    }
}

Describe 'Write-LokiConfig' {

    It 'writes a hashtable as JSON that Read-LokiConfig reads back unchanged (round-trip)' {
        $file = Join-Path $script:Work 'roundtrip.json'
        $cfg = @{ AuthMethod = 'sub'; retries = 3; verbose = $true }
        Write-LokiConfig -Path $file -Config $cfg

        $result = Read-LokiConfig -Path $file
        $result | Should -BeOfType [hashtable]
        $result['AuthMethod'] | Should -Be 'sub'
        $result['retries'] | Should -Be 3
        $result['verbose'] | Should -Be $true
    }

    It 'round-trips nested objects/arrays through Write- + Read-LokiConfig' {
        $file = Join-Path $script:Work 'roundtrip-nested.json'
        $cfg = @{ auth = @{ mode = 'oauth' }; tags = @('a', 'b') }
        Write-LokiConfig -Path $file -Config $cfg

        $result = Read-LokiConfig -Path $file
        $result['auth'] | Should -BeOfType [hashtable]
        $result['auth']['mode'] | Should -Be 'oauth'
        $result['tags'][0] | Should -Be 'a'
        $result['tags'][1] | Should -Be 'b'
    }

    It 'writes the JSON file without a BOM (first byte != 0xEF)' {
        $file = Join-Path $script:Work 'nobom.json'
        Write-LokiConfig -Path $file -Config @{ engine = 'cloud' }

        $bytes = [System.IO.File]::ReadAllBytes($file)
        $bytes.Length | Should -BeGreaterThan 0
        $bytes[0] | Should -Not -Be 0xEF
    }

    It 'creates a not-yet-existing target directory when writing' {
        $subDir = Join-Path $script:Work ('newdir-' + [System.Guid]::NewGuid().ToString('N'))
        $file = Join-Path $subDir 'loki.config.json'
        Test-Path -LiteralPath $subDir | Should -BeFalse

        Write-LokiConfig -Path $file -Config @{ engine = 'cloud' }

        Test-Path -LiteralPath $subDir | Should -BeTrue
        Test-Path -LiteralPath $file | Should -BeTrue
        (Read-LokiConfig -Path $file)['engine'] | Should -Be 'cloud'
    }

    It 'fully overwrites an existing config file (no merge)' {
        $file = Join-Path $script:Work 'overwrite.json'
        Write-LokiConfig -Path $file -Config @{ old = 'value' }
        Write-LokiConfig -Path $file -Config @{ new = 'value' }

        $result = Read-LokiConfig -Path $file
        $result.ContainsKey('old') | Should -BeFalse
        $result['new'] | Should -Be 'value'
    }
}

Describe 'Resolve-LokiSetting - Precedence (Flag > Env > Config > Default)' {

    AfterEach {
        foreach ($n in @('LOKI_TESTKEY', 'LOKI_ENGINETIER', 'LOKI_CUSTOMNAME')) {
            if (Test-Path "Env:\$n") { Remove-Item "Env:\$n" -Force }
        }
    }

    It 'flag wins, even when Env and Config are set' {
        $env:LOKI_TESTKEY = 'env-value'
        $flags = @{ testkey = 'flag-value' }
        $config = @{ testkey = 'config-value' }
        Resolve-LokiSetting -Key 'testkey' -Flags $flags -Config $config -Default 'default-value' | Should -Be 'flag-value'
    }

    It 'Env wins when no flag is set but Config is set' {
        $env:LOKI_TESTKEY = 'env-value'
        $flags = @{}
        $config = @{ testkey = 'config-value' }
        Resolve-LokiSetting -Key 'testkey' -Flags $flags -Config $config -Default 'default-value' | Should -Be 'env-value'
    }

    It 'Config wins when neither flag nor Env is set' {
        $flags = @{}
        $config = @{ testkey = 'config-value' }
        Resolve-LokiSetting -Key 'testkey' -Flags $flags -Config $config -Default 'default-value' | Should -Be 'config-value'
    }

    It 'Default wins when nothing else is set' {
        $flags = @{}
        $config = @{}
        Resolve-LokiSetting -Key 'testkey' -Flags $flags -Config $config -Default 'default-value' | Should -Be 'default-value'
    }
}

Describe 'Resolve-LokiSetting - missing levels fall through' {

    AfterEach {
        foreach ($n in @('LOKI_TESTKEY', 'LOKI_ENGINETIER', 'LOKI_CUSTOMNAME')) {
            if (Test-Path "Env:\$n") { Remove-Item "Env:\$n" -Force }
        }
    }

    It 'flags without the key falls through to Env' {
        $env:LOKI_TESTKEY = 'env-value'
        Resolve-LokiSetting -Key 'testkey' -Flags @{} -Config @{ testkey = 'config-value' } -Default 'default-value' | Should -Be 'env-value'
    }

    It 'Flags[$Key] = $null counts as not set and falls through' {
        $env:LOKI_TESTKEY = 'env-value'
        $flags = @{ testkey = $null }
        Resolve-LokiSetting -Key 'testkey' -Flags $flags -Config @{ testkey = 'config-value' } -Default 'default-value' | Should -Be 'env-value'
    }

    It 'Env as empty string counts as not set and falls through to Config' {
        $env:LOKI_TESTKEY = ''
        Resolve-LokiSetting -Key 'testkey' -Flags @{} -Config @{ testkey = 'config-value' } -Default 'default-value' | Should -Be 'config-value'
    }

    It 'Config without the key falls through to Default' {
        Resolve-LokiSetting -Key 'testkey' -Flags @{} -Config @{} -Default 'default-value' | Should -Be 'default-value'
    }

    It 'falsy-but-not-null flag values (0, $false, empty string) count as set' {
        Resolve-LokiSetting -Key 'testkey' -Flags @{ testkey = 0 } -Config @{ testkey = 'config-value' } -Default 'default-value' | Should -Be 0
        Resolve-LokiSetting -Key 'testkey' -Flags @{ testkey = $false } -Config @{ testkey = 'config-value' } -Default 'default-value' | Should -Be $false
        Resolve-LokiSetting -Key 'testkey' -Flags @{ testkey = '' } -Config @{ testkey = 'config-value' } -Default 'default-value' | Should -Be ''
    }

    It 'Config[$Key] = $null counts as present and wins over Default' {
        Resolve-LokiSetting -Key 'testkey' -Flags @{} -Config @{ testkey = $null } -Default 'default-value' | Should -Be $null
    }
}

Describe 'Resolve-LokiSetting - Env name derivation' {

    AfterEach {
        foreach ($n in @('LOKI_TESTKEY', 'LOKI_ENGINETIER', 'LOKI_CUSTOMNAME')) {
            if (Test-Path "Env:\$n") { Remove-Item "Env:\$n" -Force }
        }
    }

    It 'derives the Env name without -EnvName as LOKI_ + key in uppercase' {
        $env:LOKI_ENGINETIER = 'from-derived-env'
        Resolve-LokiSetting -Key 'engineTier' -Flags @{} -Config @{} -Default 'default-value' | Should -Be 'from-derived-env'
    }

    It 'uses an explicit -EnvName instead of the derivation' {
        $env:LOKI_CUSTOMNAME = 'from-custom-env'
        Resolve-LokiSetting -Key 'testkey' -Flags @{} -Config @{} -Default 'default-value' -EnvName 'LOKI_CUSTOMNAME' | Should -Be 'from-custom-env'
    }
}
