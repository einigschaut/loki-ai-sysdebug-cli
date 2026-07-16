# lib/i18n.ps1 — CLI localization (user-facing runtime strings only). Repo/base language is English.
# Scope: ONLY the CLI's user-facing OUTPUT is localized. Code, comments, docs and build/tooling
# output stay English. Catalogs live in src/i18n/<locale>.psd1 (data-only, Import-PowerShellDataFile).
# English ('en') is the base catalog and the guaranteed fallback for any missing key. See ADR-0004.
# Contract:
#   Import-LokiCatalog -AppRoot <string>
#       Loads every i18n/<xx>.psd1 into the in-memory store (filename = locale code). Returns the store.
#   Resolve-LokiLocale [-Flags <hashtable>] [-Config <hashtable>]  -> 2-letter locale code
#       Precedence: Flag('Lang', i.e. --lang) > Env(LOKI_LANG) > Config('Language') > OS UI culture > 'en'.
#       Only returns a locale that was actually loaded; otherwise falls back to 'en'.
#   Set-LokiLocale -Locale <string>   -> activates a loaded locale (else the fallback). Returns the active code.
#   Get-LokiLocale                    -> the active locale code.
#   Get-LokiLocaleCulture -Locale <string> -> [CultureInfo] for that locale, InvariantCulture if unusable.
#   Get-LokiText -Key <string> [-ArgumentList <object[]>]  -> localized string
#       Lookup order: active locale -> 'en' fallback -> the key itself (unknown key is rendered verbatim,
#       so synthetic/pass-through values are safe). Formatted in the ACTIVE LOCALE's culture when
#       ArgumentList is supplied (see the note below) -- NOT the ambient culture.
#   Initialize-LokiI18n -AppRoot <string> [-Flags] [-Config] [-Locale]  -> load + activate in one call
#       The dispatcher's single entry point. Tests pass -Locale to pin a language deterministically.
#
# NUMBER FORMATTING FOLLOWS THE MESSAGE, NOT THE MACHINE.
# `-f` formats with the ambient CurrentCulture (measured: forcing an en-US thread culture flips '38,4' to '38.4'),
# which is NOT the same thing as the locale this catalog was selected for. The two disagree on real machines --
# the dev box this was found on runs CurrentUICulture=en-GB with CurrentCulture=de-DE, so Resolve-LokiLocale picks
# 'en' from $PSUICulture and then rendered "up to 38,4 GB" inside an English sentence. It also made every test that
# asserts on a decimal green on a GitHub runner (en-US) and red on a German dev box, which is exactly the
# determinism CLAUDE.md section 10 promises. So the ACTIVE LOCALE governs the whole message, numbers included.
Set-StrictMode -Version Latest

$script:LokiI18nFallback = 'en'
$script:LokiI18nCatalogs = @{}
$script:LokiI18nLocale   = 'en'
$script:LokiI18nCulture  = [System.Globalization.CultureInfo]::GetCultureInfo('en')

function Import-LokiCatalog {
    param([Parameter(Mandatory = $true)][string]$AppRoot)

    $dir = Join-Path $AppRoot 'i18n'
    $store = @{}
    if (Test-Path -LiteralPath $dir) {
        foreach ($file in (Get-ChildItem -LiteralPath $dir -Filter '*.psd1' -File | Sort-Object Name)) {
            $code = ([System.IO.Path]::GetFileNameWithoutExtension($file.Name)).ToLowerInvariant()
            $data = Import-PowerShellDataFile -LiteralPath $file.FullName
            if ($null -ne $data) { $store[$code] = $data }
        }
    }
    $script:LokiI18nCatalogs = $store
    return $store
}

function Resolve-LokiLocale {
    param([hashtable]$Flags, [hashtable]$Config)

    $candidate = $null
    if ($Flags -and $Flags.ContainsKey('Lang') -and -not [string]::IsNullOrWhiteSpace([string]$Flags['Lang'])) {
        $candidate = [string]$Flags['Lang']
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:LOKI_LANG)) {
        $candidate = $env:LOKI_LANG
    }
    elseif ($Config -and $Config.ContainsKey('Language') -and -not [string]::IsNullOrWhiteSpace([string]$Config['Language'])) {
        $candidate = [string]$Config['Language']
    }
    elseif (-not [string]::IsNullOrWhiteSpace($PSUICulture)) {
        $candidate = $PSUICulture
    }
    else {
        $candidate = $script:LokiI18nFallback
    }

    # Normalize 'de-DE' / 'DE' -> 'de'; only accept locales we actually loaded.
    $code = (($candidate -split '-')[0]).ToLowerInvariant()
    if ($script:LokiI18nCatalogs.ContainsKey($code)) { return $code }
    return $script:LokiI18nFallback
}

function Get-LokiLocaleCulture {
    <#
        The CultureInfo a locale's numbers should be rendered in. Loki's locale codes are 2-letter (the catalog
        FILENAME), which makes them NEUTRAL cultures -- measured, those format perfectly well: GetCultureInfo('en')
        gives '38.4' and ('de') gives '38,4', and for dates neutral 'en' is identical to en-US.

        Deliberately NOT InvariantCulture for 'en': measured, invariant renders a DateTime as '07/16/2026 14:30:00',
        which is nobody's convention, where neutral 'en' gives '7/16/2026 2:30:00 PM'. No message passes a DateTime
        today, but picking invariant would bake in the wrong answer for the first one that does.

        The guard is not theory: GetCultureInfo THROWS on a malformed name ('a b c', '!!!', an over-long one), and
        locale codes here come from filenames, so a stray src\i18n\<junk>.psd1 reaches this. It does NOT throw for a
        well-formed unknown like 'xx' -- that silently yields a pseudo-culture which formats invariant-like, which is
        a fine answer for a locale nobody has translated numbers for.
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Locale)
    try { return [System.Globalization.CultureInfo]::GetCultureInfo($Locale) }
    catch { return [System.Globalization.CultureInfo]::InvariantCulture }
}

function Set-LokiLocale {
    # Sets only the in-memory active-locale variable (no external/system state) -> ShouldProcess would be
    # semantically wrong here; suppress the state-changing-verb rule rather than fake a -WhatIf surface.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'In-memory active-locale setter; no external state to gate.')]
    param([Parameter(Mandatory = $true)][string]$Locale)
    $code = $Locale.ToLowerInvariant()
    if ($script:LokiI18nCatalogs.ContainsKey($code)) { $script:LokiI18nLocale = $code }
    else { $script:LokiI18nLocale = $script:LokiI18nFallback }
    # Resolved once here rather than per Get-LokiText call: not for the cost (measured 1.12 us, CultureInfo caches),
    # but so a catalog with an unusable filename degrades at activation instead of on every output line.
    $script:LokiI18nCulture = Get-LokiLocaleCulture -Locale $script:LokiI18nLocale
    return $script:LokiI18nLocale
}

function Get-LokiLocale { return $script:LokiI18nLocale }

function Get-LokiText {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [object[]]$ArgumentList
    )

    $text = $null
    $active = $script:LokiI18nCatalogs[$script:LokiI18nLocale]
    if ($null -ne $active -and $active.ContainsKey($Key)) {
        $text = [string]$active[$Key]
    }
    else {
        $fallback = $script:LokiI18nCatalogs[$script:LokiI18nFallback]
        if ($null -ne $fallback -and $fallback.ContainsKey($Key)) { $text = [string]$fallback[$Key] }
    }
    if ($null -eq $text) { $text = $Key }

    if ($ArgumentList -and $ArgumentList.Count -gt 0) {
        # NOT `$text -f $ArgumentList`: the -f operator formats in the ambient CurrentCulture, which is a property of
        # the machine, not of the message. See the note at the top of this file.
        return [string]::Format($script:LokiI18nCulture, $text, $ArgumentList)
    }
    return $text
}

function Initialize-LokiI18n {
    param(
        [Parameter(Mandatory = $true)][string]$AppRoot,
        [hashtable]$Flags,
        [hashtable]$Config,
        [string]$Locale
    )

    Import-LokiCatalog -AppRoot $AppRoot | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($Locale)) {
        Set-LokiLocale -Locale $Locale | Out-Null
    }
    else {
        Set-LokiLocale -Locale (Resolve-LokiLocale -Flags $Flags -Config $Config) | Out-Null
    }
    return $script:LokiI18nLocale
}
