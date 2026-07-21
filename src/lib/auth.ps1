# lib/auth.ps1 — auth variable & secret handling (security core, CLAUDE.md section 5)
# Contract:
#   Read-LokiEnvFile -Path <string>                              -> [hashtable]  READ-ONLY .env parser, sets NO env var.
#       File missing -> @{}. Blank lines + lines starting with '#' are skipped; each line is split on the
#       FIRST '=', key/value trimmed, surrounding single/double quotes on the value removed.
#       Pattern modeled on rajivharris/Set-PsEnv, deliberately WITHOUT its SetEnvironmentVariable side effect.
#   Get-LokiAuthMethod -Config <hashtable>                        -> 'api' | 'sub'
#       Reads the optional config key 'AuthMethod'. Missing key or unknown value -> default 'api'
#       (ADR-0001 #4: API key is the safe default, no silent fallback to a subscription token).
#   Get-LokiAuthVarName -Method <string>                          -> env var name for the method; throws on an unknown method.
#   Get-LokiCredentialVarNames                                     -> [string[]] EVERY env var name that carries a
#       credential (see the list below). The SINGLE SOURCE OF TRUTH; returns a copy, so no caller can edit it.
#   Remove-LokiCredentialEnv -ChildEnv <IDictionary> [-Keep <string[]>] -> [string[]] the names actually removed.
#       Strips every credential var from a child env block IN PLACE, except the ones named in -Keep. Case-insensitive
#       for any IDictionary (not only a PowerShell hashtable), because Windows env var names are case-insensitive.
#   Test-LokiCredentialTarget -Text <string>                        -> [bool] does this text name a credential var?
#       ORDINAL comparison (see the culture note on the list) -- for the allow-list gate's secret-target deny.
#   Read-LokiSecret -EnvFilePath <string>                         -> [string] plaintext secret from 'LOKI_SECRET'
#       (stored as base64 in the .env, decoded here), or $null if the file is missing, the key isn't
#       present, OR the value isn't valid base64 (corrupt .env). Writes the secret NOWHERE.
#   Get-LokiAuthEnv -Method <string> -Secret <string>             -> [hashtable] with EXACTLY ONE key (= var name) -> secret.
#       Secret $null/empty -> @{} (caller turns this into exit 3, see lib/exitcodes.ps1 'AuthMissing').
#   Format-LokiMaskedSecret -Value <string>                       -> masked display, NEVER the raw value.
#       Long (>=16 chars) -> first 3 + '...' + last 4. Short -> '****'. Empty/$null -> '(not set)'.
#   Get-LokiAuthStatus -EnvFilePath <string> -Config <hashtable>   -> [hashtable]{ Method; VarName; Present; Masked }.
#       NEVER contains the raw secret — only the masked string and a present flag.
#   Set-LokiSecret -EnvFilePath <string> -SecureValue <securestring>
#       Writes 'LOKI_SECRET' to the .env. Accepts ONLY [securestring] (never plaintext via argv); internally
#       converts briefly to plaintext, encodes as base64 (byte-exact round-trip, not human-readable), writes,
#       and clears the plaintext variable afterward (reference set to $null).
#   Clear-LokiSecret -EnvFilePath <string>
#       Removes 'LOKI_SECRET' from the .env (other keys are preserved).
# CLAUDE.md section 5: secret NEVER in argv/logs; exactly ONE auth variable is set; the allow list remains the
# actual gate (this is just auth resolution + masking). Scanned/external values are data, not instructions.
Set-StrictMode -Version Latest

function Read-LokiEnvFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $result = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return $result
    }

    $lines = Get-Content -LiteralPath $Path -Encoding utf8
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrEmpty($trimmed)) { continue }
        if ($trimmed.StartsWith('#')) { continue }

        $idx = $trimmed.IndexOf('=')
        if ($idx -lt 0) { continue }

        $key = $trimmed.Substring(0, $idx).Trim()
        if ([string]::IsNullOrEmpty($key)) { continue }

        $value = $trimmed.Substring($idx + 1).Trim()
        if ($value.Length -ge 2) {
            $first = $value.Substring(0, 1)
            $last = $value.Substring($value.Length - 1, 1)
            $bothDouble = ($first -eq '"') -and ($last -eq '"')
            $bothSingle = ($first -eq "'") -and ($last -eq "'")
            if ($bothDouble -or $bothSingle) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }

        $result[$key] = $value
    }

    return $result
}

function Get-LokiAuthMethod {
    param([Parameter(Mandatory = $true)][hashtable]$Config)

    if ($Config.ContainsKey('AuthMethod')) {
        $normalized = ([string]$Config['AuthMethod']).Trim().ToLowerInvariant()
        if ($normalized -eq 'sub') { return 'sub' }
        if ($normalized -eq 'api') { return 'api' }
    }
    return 'api'
}

function Get-LokiAuthVarName {
    param([Parameter(Mandatory = $true)][string]$Method)

    switch ($Method) {
        'api' { return 'ANTHROPIC_API_KEY' }
        'sub' { return 'CLAUDE_CODE_OAUTH_TOKEN' }
        default { throw "Unknown auth method '$Method' (allowed: api, sub)." }
    }
}

# ===================================================================================================================
# THE credential names -- one list, one home (ADR-0027). Every env var that carries a credential: the seven Claude
# Code authenticates on, plus Loki's own secret-at-rest key. Loki sets exactly ONE of them (api -> the API key,
# sub -> the OAuth token, above); the rest are credentials a TARGET MACHINE's environment may already carry.
#
# Why it lives in auth.ps1: this file already owns "which env var carries the credential" (Get-LokiAuthVarName). It is
# also the file every consumer can reach -- lib/*.ps1 is dot-sourced alphabetically, and every reference to these
# functions is inside a FUNCTION body, so it resolves at call time and no load order can break it.
#
# Why ONE list. This list existed FOUR times (lib/claude.ps1 7 names, lib/offline-agent.ps1 4, lib/footprint.ps1 3
# inline, lib/allowlist.ps1 3), and that is not an aesthetic complaint: on 2026-07-16 the four cloud-provider
# credentials were added because Claude Code's precedence puts provider auth FIRST -- an inherited Bedrock bearer
# token does not merely sit in the block, it WINS over the key Loki injected. That fix landed in exactly one of the
# four copies. Measured on the real code before this change: llama-server's child block kept all 8, the gated read
# child kept 4, the footprint probe kept 5, and the gate auto-allowed a dump grep for 5 of the 8 names.
# One list is what makes the next such fix arrive everywhere. tests/auth.Tests.ps1 fails any other src file that
# quotes one of these names, so a second copy cannot come back quietly.
#
# CULTURE (proven, not reasoned): the names must be compared ORDINALLY. Under tr-TR, ToLower of a capital I is the
# dotless U+0131, so a case-insensitive REGEX built from a name carrying that letter does NOT match its own lowercase
# form -- measured in a fresh 5.1 process: -match False, ordinal IndexOf True. Same class of bug lib/allowlist.ps1
# already fixed for its Get-* pattern with CultureInvariant. Ordinal never folds anything.
#
# Provenance of the seven: code.claude.com/docs/en/authentication.md (precedence) + env-vars.md -- verified, not recalled.
$script:LokiCredentialVarNames = @(
    'ANTHROPIC_API_KEY',            # precedence 3 -> x-api-key
    'ANTHROPIC_AUTH_TOKEN',         # precedence 2 -> Authorization: Bearer (LLM gateways)
    'CLAUDE_CODE_OAUTH_TOKEN',      # precedence 5 -> the token `claude setup-token` generates
    'AWS_BEARER_TOKEN_BEDROCK',     # precedence 1 (cloud provider) -- beats everything above
    'ANTHROPIC_AWS_API_KEY',        # precedence 1 -- Claude Platform on AWS
    'ANTHROPIC_FOUNDRY_API_KEY',    # precedence 1 -- Microsoft Foundry
    'ANTHROPIC_FOUNDRY_AUTH_TOKEN', # precedence 1 -- Microsoft Foundry, bearer variant
    'LOKI_SECRET'                   # Loki's own secret-at-rest key (home\.env). No child of Loki's ever needs it.
)

function Get-LokiCredentialVarNames {
    # 'Names' is a set, not one name -- the whole point is that there are eight. Same precedent as
    # Get-LokiFootprintTargets / Get-LokiInstalledTiers: suppress rather than distort an accurate name.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns the LIST of credential variable names; the plural is the accurate name.')]
    # A COPY, deliberately: a caller that sorted or trimmed the returned array in place would silently edit the single
    # source of truth for every other consumer in the same session.
    param()
    return , ([string[]]$script:LokiCredentialVarNames.Clone())
}

function Remove-LokiCredentialEnv {
    <#
        Strip every credential from a child's environment block, except the ones the caller explicitly keeps.

        lib/env-isolate.ps1 hands a child a COPY of the FULL parent environment ("redirect instead of clean up",
        ADR-0003). That is right for PATH and wrong for credentials: the parent is the OPERATOR's shell, on a machine
        Loki does not control. Every Loki child either needs exactly one credential (the online engine, -Keep it) or
        none at all (llama-server, the footprint probe, a gated read child, `claude setup-token`).

        -Keep is a whitelist of names to preserve, matched case-insensitively like the removal itself. It exists for
        the single caller that legitimately holds a credential; everything else calls this with no -Keep.

        Mutates $ChildEnv in place (matching Remove-LokiClaudeRoutingEnv's shape) and returns the names it removed, so
        a caller -- or a test -- can assert on what was actually stripped rather than trust that it happened.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Mutates the caller''s in-memory dictionary only -- no external state. -WhatIf would report a scrubbed block while leaving the credentials in it, which is the exact failure this function exists to prevent.')]
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$ChildEnv,
        [string[]]$Keep = @()
    )
    $removed = New-Object System.Collections.Generic.List[string]
    # Snapshot the keys first: removing from a hashtable while enumerating its keys throws under 5.1.
    foreach ($key in @($ChildEnv.Keys)) {
        $name = [string]$key
        foreach ($cred in $script:LokiCredentialVarNames) {
            if (-not [string]::Equals($name, $cred, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $keepThis = $false
            foreach ($k in $Keep) {
                if ([string]::Equals($name, [string]$k, [System.StringComparison]::OrdinalIgnoreCase)) { $keepThis = $true; break }
            }
            if (-not $keepThis) {
                [void]$ChildEnv.Remove($key)
                [void]$removed.Add($name)
            }
            break
        }
    }
    return , $removed.ToArray()
}

function Test-LokiCredentialTarget {
    # Does this text name a credential variable? Ordinal (see the culture note above), substring -- the caller passes a
    # whole command line, so the name can sit anywhere in it (a -Pattern argument, a path, a here-string).
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    foreach ($cred in $script:LokiCredentialVarNames) {
        if ($Text.IndexOf($cred, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    return $false
}

function Read-LokiSecret {
    param([Parameter(Mandatory = $true)][string]$EnvFilePath)

    $envMap = Read-LokiEnvFile -Path $EnvFilePath
    if (-not $envMap.ContainsKey('LOKI_SECRET')) {
        return $null
    }

    # Secret base64 at rest -> exact round-trip + not human-readable (Opus review).
    # Invalid base64 (corrupt .env) -> $null instead of an exception, see contract header.
    try {
        $bytes = [Convert]::FromBase64String([string]$envMap['LOKI_SECRET'])
        return [System.Text.Encoding]::UTF8.GetString($bytes)
    }
    catch {
        return $null
    }
}

function Get-LokiAuthEnv {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Secret
    )

    if ([string]::IsNullOrEmpty($Secret)) {
        return @{}
    }

    $varName = Get-LokiAuthVarName -Method $Method
    $result = @{}
    $result[$varName] = $Secret
    return $result
}

function Format-LokiMaskedSecret {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrEmpty($Value)) {
        return (Get-LokiText 'auth.notSet')
    }
    if ($Value.Length -ge 16) {
        $head = $Value.Substring(0, 3)
        $tail = $Value.Substring($Value.Length - 4, 4)
        return "$head...$tail"
    }
    return '****'
}

function Get-LokiAuthStatus {
    param(
        [Parameter(Mandatory = $true)][string]$EnvFilePath,
        [Parameter(Mandatory = $true)][hashtable]$Config
    )

    $method = Get-LokiAuthMethod -Config $Config
    $varName = Get-LokiAuthVarName -Method $method
    $secret = Read-LokiSecret -EnvFilePath $EnvFilePath
    $present = -not [string]::IsNullOrEmpty($secret)
    $masked = Format-LokiMaskedSecret -Value $secret

    return @{
        Method  = $method
        VarName = $varName
        Present = $present
        Masked  = $masked
    }
}

# Internal helper: shared .env rewrite logic for Set-/Clear-LokiSecret (one source of truth, no duplicates).
function Write-LokiEnvFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$EnvMap
    )

    $dir = Split-Path -Path $Path -Parent
    if ((-not [string]::IsNullOrEmpty($dir)) -and (-not (Test-Path -LiteralPath $dir))) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    $lines = @()
    foreach ($key in $EnvMap.Keys) {
        $value = [string]$EnvMap[$key]
        $needsQuoting = $false

        if (($value.Length -gt 0) -and ($value -ne $value.Trim())) {
            $needsQuoting = $true
        }
        if ($value.Length -ge 2) {
            $first = $value.Substring(0, 1)
            $last = $value.Substring($value.Length - 1, 1)
            $bothDouble = ($first -eq '"') -and ($last -eq '"')
            $bothSingle = ($first -eq "'") -and ($last -eq "'")
            if ($bothDouble -or $bothSingle) {
                $needsQuoting = $true
            }
        }

        if ($needsQuoting) {
            $lines += "$key=`"$value`""
        }
        else {
            $lines += "$key=$value"
        }
    }

    # .env is a DATA FILE written at RUNTIME -> BOM-LESS (5.1 trap: Set-Content -Encoding utf8
    # produces a BOM). Applies ONLY to this data file -- the .ps1 SOURCE still needs a BOM (file header).
    [System.IO.File]::WriteAllLines($Path, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
}

function Set-LokiSecret {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$EnvFilePath,
        [Parameter(Mandatory = $true)][securestring]$SecureValue
    )

    if (-not $PSCmdlet.ShouldProcess($EnvFilePath, 'write LOKI_SECRET')) {
        return
    }

    # The PtrToStringBSTR plaintext copy lands on the managed heap -- inherent to .NET (strings are immutable,
    # cannot be actively zeroed). The BSTR itself is zeroed immediately via ZeroFreeBSTR; the remaining
    # managed copy is an accepted residual risk (process memory), not a leak to file/log/variable.
    $plain = $null
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try {
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    try {
        # Secret base64 at rest -> exact round-trip + not human-readable (Opus review).
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($plain))
        $existing = Read-LokiEnvFile -Path $EnvFilePath
        $existing['LOKI_SECRET'] = $encoded
        Write-LokiEnvFile -Path $EnvFilePath -EnvMap $existing
    }
    finally {
        $plain = $null
    }
}

function Clear-LokiSecret {
    param([Parameter(Mandatory = $true)][string]$EnvFilePath)

    if (-not (Test-Path -LiteralPath $EnvFilePath)) {
        return
    }

    $existing = Read-LokiEnvFile -Path $EnvFilePath
    if ($existing.ContainsKey('LOKI_SECRET')) {
        $existing.Remove('LOKI_SECRET')
    }
    Write-LokiEnvFile -Path $EnvFilePath -EnvMap $existing
}
