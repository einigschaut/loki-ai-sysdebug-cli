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
