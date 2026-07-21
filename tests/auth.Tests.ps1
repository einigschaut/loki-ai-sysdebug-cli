# tests/auth.Tests.ps1 — auth variable & secret handling: exactly-ONE-var, masking, no secret leak (CLAUDE.md §5/§6).
# Uses exclusively fake values (no real secret). Temp directory per run, cleaned up in AfterAll.
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\i18n.ps1"
    . "$PSScriptRoot\..\src\lib\auth.ps1"
    Initialize-LokiI18n -AppRoot (Resolve-Path "$PSScriptRoot\..\src").Path -Locale 'en' | Out-Null
    $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ("loki-auth-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:Work | Out-Null
    $script:FakeSecret = 'sk-test-1234567890abcd'
    # LOKI_SECRET is now base64-encoded in the .env (see src\lib\auth.ps1) -- helper value for tests
    # that pre-populate the .env data file directly instead of writing via Set-LokiSecret.
    $script:FakeSecretB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($script:FakeSecret))
    # Builds a [securestring] from plaintext WITHOUT ConvertTo-SecureString -AsPlainText
    # (PSAvoidUsingConvertToSecureStringWithPlainText). For fake test values only.
    $script:NewSecure = {
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Plain)
        $ss = New-Object System.Security.SecureString
        foreach ($ch in $Plain.ToCharArray()) { $ss.AppendChar($ch) }
        $ss.MakeReadOnly()
        $ss
    }
}

AfterAll {
    if (Test-Path -LiteralPath $script:Work) { Remove-Item -LiteralPath $script:Work -Recurse -Force }
}

Describe 'Read-LokiEnvFile' {

    It 'returns @{} when the file is missing' {
        $p = Join-Path $script:Work 'missing.env'
        $r = Read-LokiEnvFile -Path $p
        $r | Should -BeOfType [hashtable]
        $r.Count | Should -Be 0
    }

    It 'skips empty lines and comment lines' {
        $p = Join-Path $script:Work 'comments.env'
        Set-Content -LiteralPath $p -Encoding utf8 -Value @(
            '# Kommentarzeile',
            '',
            'FOO=bar',
            '   ',
            '# noch ein Kommentar'
        )
        $r = Read-LokiEnvFile -Path $p
        $r.Count | Should -Be 1
        $r['FOO'] | Should -Be 'bar'
    }

    It 'strips surrounding double and single quotes from the value' {
        $p = Join-Path $script:Work 'quotes.env'
        Set-Content -LiteralPath $p -Encoding utf8 -Value @(
            'A="doppelt"',
            "B='einfach'",
            'C=ohne_quotes'
        )
        $r = Read-LokiEnvFile -Path $p
        $r['A'] | Should -Be 'doppelt'
        $r['B'] | Should -Be 'einfach'
        $r['C'] | Should -Be 'ohne_quotes'
    }

    It 'splits only on the FIRST equals sign (value may contain =)' {
        $p = Join-Path $script:Work 'equals.env'
        Set-Content -LiteralPath $p -Encoding utf8 -Value 'KEY=a=b=c'
        $r = Read-LokiEnvFile -Path $p
        $r['KEY'] | Should -Be 'a=b=c'
    }

    It 'trims key and value' {
        $p = Join-Path $script:Work 'trim.env'
        Set-Content -LiteralPath $p -Encoding utf8 -Value '  KEY  =  value  '
        $r = Read-LokiEnvFile -Path $p
        $r.ContainsKey('KEY') | Should -BeTrue
        $r['KEY'] | Should -Be 'value'
    }

    It 'ignores lines without an equals sign and lines with an empty key' {
        $p = Join-Path $script:Work 'malformed.env'
        Set-Content -LiteralPath $p -Encoding utf8 -Value @(
            'GARBAGE',
            '=orphan',
            'FOO=bar'
        )
        $r = Read-LokiEnvFile -Path $p
        $r.Count | Should -Be 1
        $r['FOO'] | Should -Be 'bar'
    }
}

Describe 'Get-LokiAuthMethod' {

    It 'returns default api without a config key' {
        Get-LokiAuthMethod -Config @{} | Should -Be 'api'
    }

    It 'returns sub for an explicit config value' {
        Get-LokiAuthMethod -Config @{ AuthMethod = 'sub' } | Should -Be 'sub'
    }

    It 'returns api for an explicit config value' {
        Get-LokiAuthMethod -Config @{ AuthMethod = 'api' } | Should -Be 'api'
    }

    It 'safely falls back to api on an unknown config value (no silent sub fallback)' {
        Get-LokiAuthMethod -Config @{ AuthMethod = 'wat' } | Should -Be 'api'
    }

    It 'normalizes case and surrounding whitespace to sub' {
        Get-LokiAuthMethod -Config @{ AuthMethod = 'SUB' } | Should -Be 'sub'
        Get-LokiAuthMethod -Config @{ AuthMethod = ' sub ' } | Should -Be 'sub'
    }
}

Describe 'Get-LokiAuthVarName' {

    It 'returns ANTHROPIC_API_KEY for api' {
        Get-LokiAuthVarName -Method 'api' | Should -Be 'ANTHROPIC_API_KEY'
    }

    It 'returns CLAUDE_CODE_OAUTH_TOKEN for sub' {
        Get-LokiAuthVarName -Method 'sub' | Should -Be 'CLAUDE_CODE_OAUTH_TOKEN'
    }

    It 'throws on an unknown method' {
        { Get-LokiAuthVarName -Method 'unbekannt' } | Should -Throw
    }
}

Describe 'Read-LokiSecret' {

    It 'returns $null when the file is missing' {
        $p = Join-Path $script:Work 'nosuch.env'
        Read-LokiSecret -EnvFilePath $p | Should -Be $null
    }

    It 'returns $null when the key is missing' {
        $p = Join-Path $script:Work 'nokey.env'
        Set-Content -LiteralPath $p -Encoding utf8 -Value 'OTHER=value'
        Read-LokiSecret -EnvFilePath $p | Should -Be $null
    }

    It 'reads LOKI_SECRET (base64-encoded) from the .env and decodes it to plaintext' {
        $p = Join-Path $script:Work 'withsecret.env'
        Set-Content -LiteralPath $p -Encoding utf8 -Value "LOKI_SECRET=$($script:FakeSecretB64)"
        Read-LokiSecret -EnvFilePath $p | Should -Be $script:FakeSecret
    }

    It 'returns $null on invalid base64 in LOKI_SECRET (corrupt .env)' {
        $p = Join-Path $script:Work 'corrupt.env'
        Set-Content -LiteralPath $p -Encoding utf8 -Value 'LOKI_SECRET=not-valid-base64!!'
        Read-LokiSecret -EnvFilePath $p | Should -Be $null
    }
}

Describe 'Get-LokiAuthEnv — exactly ONE auth variable' {

    It 'returns exactly one key' {
        $result = Get-LokiAuthEnv -Method 'api' -Secret $script:FakeSecret
        $result.Keys.Count | Should -Be 1
    }

    It 'sets ANTHROPIC_API_KEY for method api' {
        $result = Get-LokiAuthEnv -Method 'api' -Secret $script:FakeSecret
        $result.ContainsKey('ANTHROPIC_API_KEY') | Should -BeTrue
        $result['ANTHROPIC_API_KEY'] | Should -Be $script:FakeSecret
    }

    It 'sets CLAUDE_CODE_OAUTH_TOKEN for method sub (still exactly one key)' {
        $result = Get-LokiAuthEnv -Method 'sub' -Secret $script:FakeSecret
        $result.ContainsKey('CLAUDE_CODE_OAUTH_TOKEN') | Should -BeTrue
        $result['CLAUDE_CODE_OAUTH_TOKEN'] | Should -Be $script:FakeSecret
        $result.Keys.Count | Should -Be 1
    }

    It 'returns @{} for an empty secret' {
        $result = Get-LokiAuthEnv -Method 'api' -Secret ''
        $result.Count | Should -Be 0
    }

    It 'returns @{} for a $null secret' {
        $result = Get-LokiAuthEnv -Method 'api' -Secret $null
        $result.Count | Should -Be 0
    }
}

Describe 'Format-LokiMaskedSecret' {

    It 'masks long values as first 3 + ... + last 4, raw value not contained in the output' {
        $masked = Format-LokiMaskedSecret -Value $script:FakeSecret
        $masked | Should -Be 'sk-...abcd'
        $masked.Contains($script:FakeSecret) | Should -BeFalse
    }

    It 'masks short values as ****' {
        Format-LokiMaskedSecret -Value 'abcd' | Should -Be '****'
    }

    It 'masks a 15-character value (below the threshold) as ****' {
        Format-LokiMaskedSecret -Value ('1' * 15) | Should -Be '****'
    }

    It 'masks a 16-character value (threshold) as first 3 + ... + last 4' {
        Format-LokiMaskedSecret -Value 'abcdefghijklmnop' | Should -Be 'abc...mnop'
    }

    It 'shows (not set) for an empty value' {
        Format-LokiMaskedSecret -Value '' | Should -Be '(not set)'
    }

    It 'shows (not set) for $null' {
        Format-LokiMaskedSecret -Value $null | Should -Be '(not set)'
    }
}

Describe 'Get-LokiAuthStatus — never contains the raw secret' {

    It 'reports Present=$false and masked (not set) when no secret exists' {
        $p = Join-Path $script:Work 'status-empty.env'
        $status = Get-LokiAuthStatus -EnvFilePath $p -Config @{}
        $status.Method  | Should -Be 'api'
        $status.VarName | Should -Be 'ANTHROPIC_API_KEY'
        $status.Present | Should -BeFalse
        $status.Masked  | Should -Be '(not set)'
    }

    It 'reports Present=$true and masks the value without containing the raw secret' {
        $p = Join-Path $script:Work 'status-set.env'
        Set-Content -LiteralPath $p -Encoding utf8 -Value "LOKI_SECRET=$($script:FakeSecretB64)"
        $status = Get-LokiAuthStatus -EnvFilePath $p -Config @{ AuthMethod = 'sub' }
        $status.Method  | Should -Be 'sub'
        $status.VarName | Should -Be 'CLAUDE_CODE_OAUTH_TOKEN'
        $status.Present | Should -BeTrue
        $status.Masked  | Should -Not -Be $script:FakeSecret

        # Security gate: none of the status values may contain the raw secret.
        foreach ($v in $status.Values) {
            ([string]$v).Contains($script:FakeSecret) | Should -BeFalse
        }
    }
}

Describe 'Set-LokiSecret / Clear-LokiSecret — round-trip via SecureString' {

    It 'writes and reads the secret via a SecureString round-trip' {
        $p = Join-Path $script:Work 'roundtrip.env'
        $secure = & $script:NewSecure $script:FakeSecret
        Set-LokiSecret -EnvFilePath $p -SecureValue $secure
        Read-LokiSecret -EnvFilePath $p | Should -Be $script:FakeSecret
    }

    It 'keeps other keys when writing the secret (LOKI_SECRET is stored encoded, not raw)' {
        $p = Join-Path $script:Work 'preserve.env'
        Set-Content -LiteralPath $p -Encoding utf8 -Value 'FOO=bar'
        $secure = & $script:NewSecure $script:FakeSecret
        Set-LokiSecret -EnvFilePath $p -SecureValue $secure
        $envMap = Read-LokiEnvFile -Path $p
        $envMap['FOO'] | Should -Be 'bar'
        $envMap['LOKI_SECRET'] | Should -Not -Be $script:FakeSecret
        Read-LokiSecret -EnvFilePath $p | Should -Be $script:FakeSecret
    }

    It 'round-trips a secret with quotes and spaces byte-exactly through Set-/Read-LokiSecret' {
        $p = Join-Path $script:Work 'edgechar.env'
        $weird = '"  weird=secret  "'
        $secure = & $script:NewSecure $weird
        Set-LokiSecret -EnvFilePath $p -SecureValue $secure
        Read-LokiSecret -EnvFilePath $p | Should -Be $weird
    }

    It 'preserves a quoted neighboring line with spaces faithfully across a Set-LokiSecret rewrite' {
        $p = Join-Path $script:Work 'neighbor.env'
        Set-Content -LiteralPath $p -Encoding utf8 -Value 'FOO="  x  "'
        $secure = & $script:NewSecure $script:FakeSecret
        Set-LokiSecret -EnvFilePath $p -SecureValue $secure
        (Read-LokiEnvFile -Path $p)['FOO'] | Should -Be '  x  '
    }

    It 'creates a not-yet-existing target directory when writing' {
        $subDir = Join-Path $script:Work ('newdir-' + [System.Guid]::NewGuid().ToString('N'))
        $p = Join-Path $subDir 'nested.env'
        Test-Path -LiteralPath $subDir | Should -BeFalse

        $secure = & $script:NewSecure $script:FakeSecret
        Set-LokiSecret -EnvFilePath $p -SecureValue $secure

        Test-Path -LiteralPath $subDir | Should -BeTrue
        Test-Path -LiteralPath $p | Should -BeTrue
        Read-LokiSecret -EnvFilePath $p | Should -Be $script:FakeSecret
    }

    It 'removes the secret via Clear-LokiSecret, other keys remain' {
        $p = Join-Path $script:Work 'clear.env'
        Set-Content -LiteralPath $p -Encoding utf8 -Value @('FOO=bar', "LOKI_SECRET=$($script:FakeSecret)")
        Clear-LokiSecret -EnvFilePath $p
        Read-LokiSecret -EnvFilePath $p | Should -Be $null
        (Read-LokiEnvFile -Path $p)['FOO'] | Should -Be 'bar'
    }

    It 'Clear-LokiSecret on a missing file does not throw' {
        $p = Join-Path $script:Work 'nope.env'
        { Clear-LokiSecret -EnvFilePath $p } | Should -Not -Throw
    }
}

# ===================================================================================================================
# The ONE credential list (ADR-0027). This list is the reason four child-process env blocks used to disagree about
# what a credential is; these tests pin its contents, its scrub, and -- structurally -- that no second copy comes back.
# ===================================================================================================================

Describe 'Get-LokiCredentialVarNames (the single source of truth)' {

    # Pinned here ON PURPOSE. Tests are specification (CLAUDE.md section 6): if someone drops a name from the list in
    # lib/auth.ps1, that is a silently narrowed security boundary, and this is what says so out loud.
    It 'contains exactly the eight credential variables Loki knows about' {
        $names = Get-LokiCredentialVarNames
        $expected = @(
            'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN',
            'AWS_BEARER_TOKEN_BEDROCK', 'ANTHROPIC_AWS_API_KEY',
            'ANTHROPIC_FOUNDRY_API_KEY', 'ANTHROPIC_FOUNDRY_AUTH_TOKEN',
            'LOKI_SECRET'
        )
        ($names | Sort-Object) -join ',' | Should -Be (($expected | Sort-Object) -join ',')
    }

    It 'returns a COPY -- a caller cannot edit the single source of truth' {
        $first = Get-LokiCredentialVarNames
        $first[0] = 'MUTATED_BY_CALLER'
        (Get-LokiCredentialVarNames)[0] | Should -Not -Be 'MUTATED_BY_CALLER'
    }
}

Describe 'Remove-LokiCredentialEnv (the child-env scrub)' {

    BeforeAll {
        # A parent environment exactly like an operator's shell that has used Claude Code, a cloud provider, and Loki.
        function global:New-TestCredEnv {
            $h = @{}
            foreach ($n in (Get-LokiCredentialVarNames)) { $h[$n] = "value-of-$n" }
            $h['PATH'] = 'C:\Windows\System32'
            $h['USERNAME'] = 'loki'
            return $h
        }
    }

    AfterAll { Remove-Item Function:\New-TestCredEnv -ErrorAction SilentlyContinue }

    It 'removes every credential and leaves everything else alone' {
        $env2 = New-TestCredEnv
        $removed = Remove-LokiCredentialEnv -ChildEnv $env2
        $removed.Count | Should -Be 8
        foreach ($n in (Get-LokiCredentialVarNames)) { $env2.ContainsKey($n) | Should -BeFalse }
        $env2['PATH'] | Should -Be 'C:\Windows\System32'
        $env2['USERNAME'] | Should -Be 'loki'
    }

    It 'keeps exactly the one credential named in -Keep (the online engine holds one)' {
        $env2 = New-TestCredEnv
        [void](Remove-LokiCredentialEnv -ChildEnv $env2 -Keep @('ANTHROPIC_API_KEY'))
        $env2['ANTHROPIC_API_KEY'] | Should -Be 'value-of-ANTHROPIC_API_KEY'
        $env2.ContainsKey('CLAUDE_CODE_OAUTH_TOKEN') | Should -BeFalse
        $env2.ContainsKey('AWS_BEARER_TOKEN_BEDROCK') | Should -BeFalse
        $env2.ContainsKey('LOKI_SECRET') | Should -BeFalse
    }

    It 'is case-insensitive in BOTH directions -- Windows env names are' {
        # A CASE-SENSITIVE dictionary, deliberately: a PowerShell hashtable folds case for us, so it cannot show
        # whether the scrub does. Dictionary[string,string] uses an ordinal comparer -- if the scrub compared keys
        # naively, the lowercase name would survive here and the test would go red.
        $d = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $d.Add('anthropic_api_key', 'lowercase-key')
        $d.Add('Aws_Bearer_Token_Bedrock', 'mixed-case-key')
        $d.Add('PATH', 'C:\Windows\System32')
        $removed = Remove-LokiCredentialEnv -ChildEnv $d
        $removed.Count | Should -Be 2
        $d.Count | Should -Be 1
        $d['PATH'] | Should -Be 'C:\Windows\System32'
    }

    It '-Keep matches case-insensitively too (the kept name may be spelled either way)' {
        $d = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $d.Add('anthropic_api_key', 'lowercase-key')
        $d.Add('LOKI_SECRET', 'stick-secret')
        [void](Remove-LokiCredentialEnv -ChildEnv $d -Keep @('ANTHROPIC_API_KEY'))
        $d.ContainsKey('anthropic_api_key') | Should -BeTrue
        $d.ContainsKey('LOKI_SECRET') | Should -BeFalse
    }

    It 'on a block with no credential: removes nothing, throws nothing' {
        $env2 = @{ PATH = 'C:\Windows\System32' }
        (Remove-LokiCredentialEnv -ChildEnv $env2).Count | Should -Be 0
        $env2.Count | Should -Be 1
    }
}

Describe 'Test-LokiCredentialTarget (culture-proof credential-name match)' {

    It 'finds the credential name anywhere in a command line: <name>' -ForEach @(
        @{ name = 'ANTHROPIC_API_KEY' }, @{ name = 'ANTHROPIC_AUTH_TOKEN' }, @{ name = 'CLAUDE_CODE_OAUTH_TOKEN' }
        @{ name = 'AWS_BEARER_TOKEN_BEDROCK' }, @{ name = 'ANTHROPIC_AWS_API_KEY' }
        @{ name = 'ANTHROPIC_FOUNDRY_API_KEY' }, @{ name = 'ANTHROPIC_FOUNDRY_AUTH_TOKEN' }, @{ name = 'LOKI_SECRET' }
    ) {
        Test-LokiCredentialTarget -Text ('Select-String -Path C:\dump.txt -Pattern ' + $name) | Should -BeTrue
        Test-LokiCredentialTarget -Text ('Select-String -Path C:\dump.txt -Pattern ' + $name.ToLowerInvariant()) | Should -BeTrue
    }

    It 'says no to an unrelated command and to an empty string (targeted, not a blanket deny)' {
        Test-LokiCredentialTarget -Text 'Get-ChildItem C:\Windows' | Should -BeFalse
        Test-LokiCredentialTarget -Text 'Select-String -Path C:\dump.txt -Pattern error' | Should -BeFalse
        Test-LokiCredentialTarget -Text '' | Should -BeFalse
    }

    It 'still matches under tr-TR, where a case-insensitive REGEX would not (measured, ADR-0027)' {
        # In tr-TR ToLower('I') is the dotless U+0131, so a regex built from 'ANTHROPIC_API_KEY' with IgnoreCase does
        # NOT match 'anthropic_api_key' -- proven in a fresh 5.1 process before this was written. Both names below
        # carry that 'I'. An ordinal comparison never folds anything, which is why this must stay ordinal.
        $prev = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('tr-TR')
            Test-LokiCredentialTarget -Text 'Select-String -Path C:\dump.txt -Pattern anthropic_api_key' | Should -BeTrue
            Test-LokiCredentialTarget -Text 'Select-String -Path C:\dump.txt -Pattern loki_secret' | Should -BeTrue
        }
        finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $prev }
    }
}

Describe 'ANTI-DRIFT: the credential names live in exactly one file' {

    # The structural gate this whole change exists for. The list had FOUR homes, they disagreed, and the 2026-07-16
    # cloud-provider fix reached one of them. A second copy is not a style problem -- it is the mechanism by which the
    # next fix goes missing. So: a credential name may appear as a QUOTED STRING LITERAL only in lib/auth.ps1.
    # Prose mentions in comments are fine and deliberately still allowed (they explain the rule at the call site).
    It 'no src file other than lib/auth.ps1 contains a credential name as a string literal' {
        $srcDir = (Resolve-Path "$PSScriptRoot\..\src").Path
        $owner = (Resolve-Path "$PSScriptRoot\..\src\lib\auth.ps1").Path
        $offenders = New-Object System.Collections.Generic.List[string]
        foreach ($file in (Get-ChildItem -LiteralPath $srcDir -Filter '*.ps1' -File -Recurse)) {
            if ($file.FullName -eq $owner) { continue }
            $text = Get-Content -Raw -LiteralPath $file.FullName
            foreach ($name in (Get-LokiCredentialVarNames)) {
                # Quoted literal only: 'NAME' or "NAME". Ordinal, so this guard cannot be culture-folded away either.
                foreach ($q in @("'$name'", """$name""")) {
                    if ($text.IndexOf($q, [System.StringComparison]::Ordinal) -ge 0) {
                        [void]$offenders.Add(('{0} -> {1}' -f $file.Name, $q))
                    }
                }
            }
        }
        ($offenders -join '; ') | Should -BeNullOrEmpty
    }
}
