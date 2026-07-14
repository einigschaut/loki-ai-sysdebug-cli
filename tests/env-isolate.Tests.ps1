# tests/env-isolate.Tests.ps1 -- Process environment isolation (security focus, CLAUDE.md paragraph 6).
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\env-isolate.ps1"
}

Describe 'Get-LokiIsolatedEnv' {

    BeforeAll {
        $script:Root     = 'C:\LokiStickTest'
        $script:BasePath = 'C:\Windows;C:\Windows\System32'
        $script:Env      = Get-LokiIsolatedEnv -StickRoot $script:Root -BasePath $script:BasePath
        $script:RequiredKeys = @(
            'USERPROFILE', 'HOME', 'CLAUDE_CONFIG_DIR', 'APPDATA', 'LOCALAPPDATA',
            'TEMP', 'TMP', 'TMPDIR',
            'HOMEDRIVE', 'HOMEPATH', 'USERNAME', 'USERDOMAIN', 'PSModulePath', 'OneDrive',
            'CLAUDE_CODE_SKIP_PROMPT_HISTORY', 'DISABLE_TELEMETRY', 'DO_NOT_TRACK', 'DISABLE_UPDATES',
            'DISABLE_AUTOUPDATER',
            'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC', 'CLAUDE_CODE_DISABLE_AUTO_MEMORY', 'CLAUDE_CODE_CERT_STORE',
            'PATH'
        )
        $script:PathKeys = @('USERPROFILE', 'HOME', 'CLAUDE_CONFIG_DIR', 'APPDATA', 'LOCALAPPDATA', 'TEMP', 'TMP', 'TMPDIR')
        $script:HardeningFlagKeys = @(
            'CLAUDE_CODE_SKIP_PROMPT_HISTORY', 'DISABLE_TELEMETRY', 'DO_NOT_TRACK', 'DISABLE_UPDATES',
            'DISABLE_AUTOUPDATER', 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC', 'CLAUDE_CODE_DISABLE_AUTO_MEMORY'
        )
    }

    It 'contains all required keys' {
        foreach ($key in $script:RequiredKeys) {
            $script:Env.ContainsKey($key) | Should -BeTrue -Because "key '$key' is missing from the result"
        }
    }

    It 'hardening flags are exactly "1" (value check, not just ContainsKey)' {
        foreach ($key in $script:HardeningFlagKeys) {
            $script:Env[$key] | Should -Be '1' -Because "flag '$key' must be exactly '1'"
        }
        $script:Env['CLAUDE_CODE_CERT_STORE'] | Should -Be 'system'
    }

    It 'HOMEDRIVE + HOMEPATH combine back into the isolated home path' {
        ($script:Env['HOMEDRIVE'] + $script:Env['HOMEPATH']) | Should -Be (Join-Path $script:Root 'home')
    }

    It 'USERNAME/USERDOMAIN are neutralized and are NOT the real host identity (leak guard)' {
        $script:Env['USERNAME']   | Should -Be 'loki'
        $script:Env['USERDOMAIN'] | Should -Be 'LOKI'
        if (-not [string]::IsNullOrEmpty($env:USERNAME)) {
            $script:Env['USERNAME'] | Should -Not -Be $env:USERNAME -Because 'the real host identity must never leak into the child block'
        }
    }

    It 'PSModulePath and OneDrive live under StickRoot (no host-user module/OneDrive path)' {
        $script:Env['PSModulePath'] | Should -BeLike "$($script:Root)*"
        $script:Env['OneDrive']     | Should -BeLike "$($script:Root)*"
    }

    It 'every path value starts with StickRoot' {
        foreach ($key in $script:PathKeys) {
            $script:Env[$key] | Should -BeLike "$($script:Root)*" -Because "key '$key' must live under StickRoot"
        }
    }

    It 'APPDATA is a standalone value, not derived from USERPROFILE' {
        $script:Env['APPDATA'] | Should -Not -Be $script:Env['USERPROFILE']
        $script:Env['APPDATA'] | Should -Be (Join-Path $script:Root 'home\appdata')
        $script:Env['LOCALAPPDATA'] | Should -Be (Join-Path $script:Root 'home\appdata\local')
    }

    It 'TEMP/TMP/TMPDIR all point consistently to the same isolated temp path' {
        $expectedTemp = Join-Path $script:Root 'temp'
        $script:Env['TEMP']   | Should -Be $expectedTemp
        $script:Env['TMP']    | Should -Be $expectedTemp
        $script:Env['TMPDIR'] | Should -Be $expectedTemp
    }

    It 'PATH starts with the tool directories (bin, dns, wireshark, sysinternals) in this order' {
        $expectedPrefix = (Join-Path $script:Root 'tools\bin') + ';' +
                           (Join-Path $script:Root 'tools\dns') + ';' +
                           (Join-Path $script:Root 'tools\wireshark') + ';' +
                           (Join-Path $script:Root 'tools\sysinternals') + ';'
        $script:Env['PATH'] | Should -BeLike ($expectedPrefix + '*')
    }

    It 'PATH ends with the given BasePath' {
        $script:Env['PATH'] | Should -Match ([regex]::Escape($script:BasePath) + '$')
    }

    It 'uses $env:PATH as the BasePath default when none is passed' {
        $withDefault = Get-LokiIsolatedEnv -StickRoot $script:Root
        $withDefault['PATH'] | Should -Match ([regex]::Escape($env:PATH) + '$')
    }

    It 'is pure: two calls with the same parameters return identical results (no global side effect)' {
        $again = Get-LokiIsolatedEnv -StickRoot $script:Root -BasePath $script:BasePath
        ($again.Keys | Sort-Object) -join ',' | Should -Be (($script:Env.Keys | Sort-Object) -join ',')
        foreach ($k in $script:Env.Keys) {
            $again[$k] | Should -Be $script:Env[$k]
        }
    }
}

Describe 'New-LokiChildEnvBlock' {

    It 'layers the isolated overlay over a copy of BaseEnv' {
        $base     = @{ FOO = 'base-foo'; PATH = 'C:\base' }
        $isolated = @{ PATH = 'C:\isoliert'; TEMP = 'C:\isoliert\temp' }

        $child = New-LokiChildEnvBlock -Isolated $isolated -BaseEnv $base

        $child['FOO']  | Should -Be 'base-foo'
        $child['PATH'] | Should -Be 'C:\isoliert'
        $child['TEMP'] | Should -Be 'C:\isoliert\temp'
    }

    It 'does NOT mutate the passed BaseEnv object (copy, not an alias)' {
        $base     = @{ FOO = 'base-foo'; PATH = 'C:\base' }
        $isolated = @{ PATH = 'C:\isoliert' }

        $null = New-LokiChildEnvBlock -Isolated $isolated -BaseEnv $base

        $base['PATH'] | Should -Be 'C:\base'
        $base['FOO']  | Should -Be 'base-foo'
        $base.Count   | Should -Be 2
    }

    It 'uses the current process environment as a copy when BaseEnv is missing' {
        $isolated = @{ LOKI_TEST_MARKER_XYZ = 'gesetzt' }
        $child = New-LokiChildEnvBlock -Isolated $isolated
        $child['LOKI_TEST_MARKER_XYZ'] | Should -Be 'gesetzt'
        if (-not [string]::IsNullOrEmpty($env:WINDIR)) {
            $child['WINDIR'] | Should -Be $env:WINDIR
        }
    }
}

Describe 'Purity across module boundaries (no Env: mutation leak)' {

    It 'Get-LokiIsolatedEnv and New-LokiChildEnvBlock (without -BaseEnv) change not a single real Env: variable' {
        $before = @{}
        foreach ($item in (Get-ChildItem -Path 'Env:')) {
            $before[$item.Name] = $item.Value
        }

        $null = Get-LokiIsolatedEnv -StickRoot 'C:\LokiPurityTest'
        $null = New-LokiChildEnvBlock -Isolated @{ FOO = 'bar' }

        $after = @{}
        foreach ($item in (Get-ChildItem -Path 'Env:')) {
            $after[$item.Name] = $item.Value
        }

        ($after.Keys | Sort-Object) -join ',' | Should -Be (($before.Keys | Sort-Object) -join ',') -Because 'no Env: variable may appear or disappear'
        foreach ($key in $before.Keys) {
            $after[$key] | Should -Be $before[$key] -Because "Env:$key must not change from pure calls"
        }
    }
}

Describe 'New-LokiTeardownStack' {

    It 'returns an empty LIFO collection' {
        $stack = New-LokiTeardownStack
        $stack.Count | Should -Be 0
    }
}

Describe 'Teardown discipline (Set-LokiProcessEnvTracked / Invoke-LokiTeardown) -- no env leak' {

    BeforeEach {
        $script:PreExistingName = 'LOKI_TEST_PREEXISTING'
        $script:UnsetName       = 'LOKI_TEST_UNSET_' + [System.Guid]::NewGuid().ToString('N')
        Set-Item -LiteralPath "Env:\$script:PreExistingName" -Value 'urspruenglicher-wert'
    }

    AfterEach {
        Remove-Item -LiteralPath "Env:\$script:PreExistingName" -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "Env:\$script:UnsetName" -ErrorAction SilentlyContinue
    }

    It 'restores a previously set value byte-exactly after Invoke-LokiTeardown' {
        $stack = New-LokiTeardownStack
        Set-LokiProcessEnvTracked -Stack $stack -Name $script:PreExistingName -Value 'geaenderter-wert'

        (Get-Item -LiteralPath "Env:\$script:PreExistingName").Value | Should -Be 'geaenderter-wert'

        Invoke-LokiTeardown -Stack $stack

        (Get-Item -LiteralPath "Env:\$script:PreExistingName").Value | Should -Be 'urspruenglicher-wert'
    }

    It 'restores a previously UNSET variable back to unset after Invoke-LokiTeardown (not an empty string)' {
        Test-Path -LiteralPath "Env:\$script:UnsetName" | Should -BeFalse

        $stack = New-LokiTeardownStack
        Set-LokiProcessEnvTracked -Stack $stack -Name $script:UnsetName -Value 'temporaer'
        (Get-Item -LiteralPath "Env:\$script:UnsetName").Value | Should -Be 'temporaer'

        Invoke-LokiTeardown -Stack $stack

        Test-Path -LiteralPath "Env:\$script:UnsetName" | Should -BeFalse
    }

    It 'LIFO with repeated tracking of the same variable: rolls back step by step to the original value' {
        $stack = New-LokiTeardownStack
        Set-LokiProcessEnvTracked -Stack $stack -Name $script:PreExistingName -Value 'zwischenwert'
        Set-LokiProcessEnvTracked -Stack $stack -Name $script:PreExistingName -Value 'endwert'

        (Get-Item -LiteralPath "Env:\$script:PreExistingName").Value | Should -Be 'endwert'

        Invoke-LokiTeardown -Stack $stack

        (Get-Item -LiteralPath "Env:\$script:PreExistingName").Value | Should -Be 'urspruenglicher-wert'
    }

    It 'accepts an empty string as Value (AllowEmptyString) and restores correctly afterwards' {
        $stack = New-LokiTeardownStack
        { Set-LokiProcessEnvTracked -Stack $stack -Name $script:PreExistingName -Value '' } | Should -Not -Throw

        # Windows quirk (not a module bug): Set-Item Env:\X -Value '' effectively removes the variable --
        # Windows does not distinguish between "empty string" and "unset".
        # AllowEmptyString still permits the call without loss; the undo remains correct.
        Test-Path -LiteralPath "Env:\$script:PreExistingName" | Should -BeFalse

        Invoke-LokiTeardown -Stack $stack

        (Get-Item -LiteralPath "Env:\$script:PreExistingName").Value | Should -Be 'urspruenglicher-wert'
    }

    It '-WhatIf branch: $env:NAME is NOT changed and the undo stack does not grow' {
        Test-Path -LiteralPath "Env:\$script:UnsetName" | Should -BeFalse

        $stack = New-LokiTeardownStack
        Set-LokiProcessEnvTracked -Stack $stack -Name $script:UnsetName -Value 'sollte-nicht-passieren' -WhatIf

        Test-Path -LiteralPath "Env:\$script:UnsetName" | Should -BeFalse -Because '-WhatIf must not make a real change'
        $stack.Count | Should -Be 0 -Because '-WhatIf must not record an undo entry'
    }

    It 'LIFO with a previously UNSET var and repeated tracking: fully removed after teardown (no intermediate value)' {
        Test-Path -LiteralPath "Env:\$script:UnsetName" | Should -BeFalse

        $stack = New-LokiTeardownStack
        Set-LokiProcessEnvTracked -Stack $stack -Name $script:UnsetName -Value 'a'
        Set-LokiProcessEnvTracked -Stack $stack -Name $script:UnsetName -Value 'b'

        (Get-Item -LiteralPath "Env:\$script:UnsetName").Value | Should -Be 'b'

        Invoke-LokiTeardown -Stack $stack

        Test-Path -LiteralPath "Env:\$script:UnsetName" | Should -BeFalse
    }

    # Proof that the "no leak" assert is not a never-failing guard (CLAUDE.md paragraph 6):
    # WITHOUT the Invoke-LokiTeardown call the mutation stays visible -- this is exactly what
    # would turn the corresponding assert in the tests above red. AfterEach cleans up the variable regardless.
    It 'PROOF: without Invoke-LokiTeardown the change stays visible (guard can actually fail)' {
        Test-Path -LiteralPath "Env:\$script:UnsetName" | Should -BeFalse

        $stack = New-LokiTeardownStack
        Set-LokiProcessEnvTracked -Stack $stack -Name $script:UnsetName -Value 'ohne-teardown'

        # No Invoke-LokiTeardown here -- the variable stays set.
        Test-Path -LiteralPath "Env:\$script:UnsetName" | Should -BeTrue
        (Get-Item -LiteralPath "Env:\$script:UnsetName").Value | Should -Be 'ohne-teardown'
    }
}
