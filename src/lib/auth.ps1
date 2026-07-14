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
