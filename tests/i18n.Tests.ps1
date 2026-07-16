# tests/i18n.Tests.ps1 — CLI localization: catalog loading, fallback, locale precedence, and the
# key-parity gate that keeps every shipped locale complete (a missing translation fails CI). See
# src/lib/i18n.ps1 and ADR-0004. Only the CLI's user-facing output is localized; repo text stays English.
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\i18n.ps1"
    $script:SrcRoot = (Resolve-Path "$PSScriptRoot\..\src").Path
    $script:I18nDir = Join-Path $script:SrcRoot 'i18n'
    Import-LokiCatalog -AppRoot $script:SrcRoot | Out-Null

    # Kataloge zusaetzlich dateibasiert laden, um Schluessel-/Platzhalter-Paritaet direkt zu pruefen.
    $script:Catalogs = @{}
    foreach ($f in (Get-ChildItem -LiteralPath $script:I18nDir -Filter '*.psd1' -File)) {
        $code = ([System.IO.Path]::GetFileNameWithoutExtension($f.Name)).ToLowerInvariant()
        $script:Catalogs[$code] = Import-PowerShellDataFile -LiteralPath $f.FullName
    }
}

Describe 'Get-LokiText - lookup, fallback, formatting' {

    It 'returns the English base text for locale en' {
        Set-LokiLocale -Locale 'en' | Out-Null
        Get-LokiText -Key 'auth.notSet' | Should -Be '(not set)'
    }

    It 'returns the German text for locale de' {
        Set-LokiLocale -Locale 'de' | Out-Null
        Get-LokiText -Key 'auth.notSet' | Should -Be '(nicht gesetzt)'
    }

    It 'falls back to en when the requested locale is not loaded' {
        Set-LokiLocale -Locale 'zz' | Out-Null   # not present -> activates the fallback
        Get-LokiLocale | Should -Be 'en'
    }

    It 'returns the key itself for an unknown key (pass-through)' {
        Set-LokiLocale -Locale 'en' | Out-Null
        Get-LokiText -Key 'this.key.does.not.exist' | Should -Be 'this.key.does.not.exist'
    }

    It 'formats placeholders via -ArgumentList' {
        Set-LokiLocale -Locale 'en' | Out-Null
        Get-LokiText -Key 'error.didYouMean' -ArgumentList @('version') | Should -Be "Did you mean 'loki version'?"
    }

    Context 'numbers follow the MESSAGE locale, not the machine' {
        # Every value here has a FRACTIONAL PART on purpose. This whole bug survived because the one pre-existing
        # test that formatted numbers used 44 and 16 -- both whole -- so en-US and de-DE rendered identically and the
        # assertion could never have caught it. A test with an integer here would be decoration.

        It 'locale en renders a decimal POINT even on a machine whose culture uses a comma' {
            Set-LokiLocale -Locale 'en' | Out-Null
            # Unknown key -> rendered verbatim, so this asserts the FORMATTING and nothing about a catalog entry.
            Get-LokiText -Key '{0}' -ArgumentList @([double]38.4) | Should -Be '38.4'
        }

        It 'locale de renders a decimal COMMA even on a machine whose culture uses a point' {
            Set-LokiLocale -Locale 'de' | Out-Null
            Get-LokiText -Key '{0}' -ArgumentList @([double]38.4) | Should -Be '38,4'
        }

        It 'BREAK-THE-GUARD: the same input renders DIFFERENTLY per locale (proves the culture is actually applied)' {
            # Without this, both assertions above could pass on a machine whose ambient culture happens to match --
            # which is precisely how a GitHub runner (en-US) stayed green while the dev box (de-DE) went red.
            Set-LokiLocale -Locale 'en' | Out-Null
            $en = Get-LokiText -Key '{0}' -ArgumentList @([double]4.5)
            Set-LokiLocale -Locale 'de' | Out-Null
            $de = Get-LokiText -Key '{0}' -ArgumentList @([double]4.5)
            $en | Should -Not -Be $de
            $en | Should -Be '4.5'
            $de | Should -Be '4,5'
        }

        It 'does not depend on the AMBIENT culture: forcing the thread either way changes nothing' {
            # The actual regression. -f followed CurrentCulture; [string]::Format(<locale culture>, ...) must not.
            $orig = [System.Threading.Thread]::CurrentThread.CurrentCulture
            try {
                Set-LokiLocale -Locale 'en' | Out-Null
                foreach ($ambient in @('de-DE', 'en-US', 'fr-FR')) {
                    [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo($ambient)
                    Get-LokiText -Key '{0}' -ArgumentList @([double]38.4) | Should -Be '38.4' -Because "ambient $ambient must not leak into an 'en' message"
                }
                Set-LokiLocale -Locale 'de' | Out-Null
                foreach ($ambient in @('de-DE', 'en-US', 'fr-FR')) {
                    [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo($ambient)
                    Get-LokiText -Key '{0}' -ArgumentList @([double]38.4) | Should -Be '38,4' -Because "ambient $ambient must not leak into a 'de' message"
                }
            }
            finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $orig }
        }

        It 'a real catalog message carrying a decimal is coherent end to end' {
            # The message the finding was made on, asserted whole rather than as a loose number.
            Set-LokiLocale -Locale 'en' | Out-Null
            Get-LokiText -Key 'hwscan.limits' -ArgumentList @([double]38.4, [double]58.5) |
                Should -Be 'Limits:    a model may use up to 38.4 GB on this machine; 58.5 GB is free enough right now'
        }

        It 'integers and strings are untouched by the culture (the change stays scoped to real numbers)' {
            # Measured across every -ArgumentList call site: int/long/string/bool render identically in en and de,
            # so counts and paths must not move. This pins that.
            foreach ($loc in @('en', 'de')) {
                Set-LokiLocale -Locale $loc | Out-Null
                Get-LokiText -Key '{0}' -ArgumentList @([int]1234) | Should -Be '1234'
                Get-LokiText -Key '{0}' -ArgumentList @([long]19762149696) | Should -Be '19762149696'
                Get-LokiText -Key '{0}' -ArgumentList @('C:\models\a.gguf') | Should -Be 'C:\models\a.gguf'
            }
        }
    }

    Context 'Get-LokiLocaleCulture' {
        It 'maps a 2-letter locale to a culture that formats it: <locale> -> <expect>' -ForEach @(
            @{ locale = 'en'; expect = '38.4' }
            @{ locale = 'de'; expect = '38,4' }
        ) {
            $c = Get-LokiLocaleCulture -Locale $locale
            [string]::Format($c, '{0}', [double]38.4) | Should -Be $expect
        }

        It 'BREAK-THE-GUARD: a malformed locale name degrades to invariant instead of throwing' {
            # Not theory: locale codes come from catalog FILENAMES, and GetCultureInfo throws on names like these
            # (measured). A stray src\i18n\<junk>.psd1 must not take the whole CLI down on its first message.
            foreach ($bad in @('a b c', '!!!', 'toolongtobeaculturename')) {
                { Get-LokiLocaleCulture -Locale $bad } | Should -Not -Throw
                (Get-LokiLocaleCulture -Locale $bad) | Should -Be ([System.Globalization.CultureInfo]::InvariantCulture)
            }
        }

        It 'a well-formed but unknown locale yields an invariant-like culture rather than an error' {
            # Measured: GetCultureInfo('xx') does NOT throw, it returns a pseudo-culture. Documented, not assumed.
            { Get-LokiLocaleCulture -Locale 'xx' } | Should -Not -Throw
            [string]::Format((Get-LokiLocaleCulture -Locale 'xx'), '{0}', [double]38.4) | Should -Be '38.4'
        }
    }
}

Describe 'Resolve-LokiLocale - precedence Flag > Env > Config > OS > en' {

    BeforeEach {
        $script:PrevLang = $env:LOKI_LANG
        Remove-Item Env:\LOKI_LANG -ErrorAction SilentlyContinue
    }
    AfterEach {
        if ($null -eq $script:PrevLang) { Remove-Item Env:\LOKI_LANG -ErrorAction SilentlyContinue }
        else { $env:LOKI_LANG = $script:PrevLang }
    }

    It 'flag --lang beats env and config' {
        $env:LOKI_LANG = 'en'
        Resolve-LokiLocale -Flags @{ Lang = 'de' } -Config @{ Language = 'en' } | Should -Be 'de'
    }

    It 'env beats config when no flag is set' {
        $env:LOKI_LANG = 'de'
        Resolve-LokiLocale -Flags @{} -Config @{ Language = 'en' } | Should -Be 'de'
    }

    It 'config applies when there is no flag and no env' {
        Resolve-LokiLocale -Flags @{} -Config @{ Language = 'de' } | Should -Be 'de'
    }

    It 'normalizes de-DE to de' {
        Resolve-LokiLocale -Flags @{ Lang = 'de-DE' } -Config @{} | Should -Be 'de'
    }

    It 'falls back to en when the requested locale is not shipped' {
        Resolve-LokiLocale -Flags @{ Lang = 'fr' } -Config @{} | Should -Be 'en'
    }
}

Describe 'Catalog parity gate - every locale is complete' {

    It 'en exists (the base locale)' {
        $script:Catalogs.ContainsKey('en') | Should -BeTrue
    }

    It 'every non-en locale has exactly the same keys as en (no missing or extra key)' {
        $enKeys = @($script:Catalogs['en'].Keys) | Sort-Object
        foreach ($code in ($script:Catalogs.Keys | Where-Object { $_ -ne 'en' })) {
            $locKeys = @($script:Catalogs[$code].Keys) | Sort-Object
            $missing = @($enKeys  | Where-Object { $_ -notin $locKeys })
            $extra   = @($locKeys | Where-Object { $_ -notin $enKeys })
            ($missing -join ',') | Should -Be '' -Because "locale '$code' is missing keys present in en"
            ($extra   -join ',') | Should -Be '' -Because "locale '$code' has keys that do not exist in en"
        }
    }

    It 'every value has the same placeholder set in every locale as in en' {
        $enData = $script:Catalogs['en']
        foreach ($code in ($script:Catalogs.Keys | Where-Object { $_ -ne 'en' })) {
            $locData = $script:Catalogs[$code]
            foreach ($key in $enData.Keys) {
                $enPh  = @([regex]::Matches([string]$enData[$key],  '\{\d+\}')  | ForEach-Object { $_.Value } | Sort-Object -Unique)
                $locPh = @([regex]::Matches([string]$locData[$key], '\{\d+\}')  | ForEach-Object { $_.Value } | Sort-Object -Unique)
                ($locPh -join ',') | Should -Be ($enPh -join ',') -Because "placeholders for '$key' differ in '$code'"
            }
        }
    }
}
