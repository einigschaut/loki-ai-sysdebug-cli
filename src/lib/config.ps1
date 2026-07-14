# lib/config.ps1 - Settings resolution with precedence Flag > Env > Config > Default (CLAUDE.md section 2)
# Contract:
#   Read-LokiConfig -Path <string> -> [hashtable]
#     File missing -> @{}. Valid JSON -> hashtable (recursively converted from PSCustomObject/Array,
#     since ConvertFrom-Json under 5.1 has no -AsHashtable). Broken JSON or a non-object root
#     -> throws a terminating error "Invalid Loki config: <path>".
#   Write-LokiConfig -Path <string> -Config <hashtable> -> void
#     Writes $Config as JSON (ConvertTo-Json -Depth 10) to $Path. Creates the target directory if
#     it's missing. BOM-LESS (data file at runtime, analogous to .env in lib/auth.ps1 -- do NOT confuse with the
#     BOM requirement for .ps1 SOURCE FILES, CLAUDE.md section 1): [System.IO.File]::WriteAllText with UTF8Encoding($false).
#   Resolve-LokiSetting -Key <string> -Flags <hashtable> -Config <hashtable> -Default <object> [-EnvName <string>] -> <object>
#     Order (first defined value wins):
#       1) Flags[$Key]     - only if key present AND value not $null
#       2) $env:<EnvName>  - EnvName default is 'LOKI_' + $Key.ToUpper(); only if set AND not an empty string
#       3) $Config[$Key]   - only if key present (value may be $null/empty)
#       4) $Default
# Used by: commands/engines for settings that are overridable via flag/env/config file.
Set-StrictMode -Version Latest

function Convert-LokiJsonNode {
    param($Node)
    if ($null -eq $Node) { return $null }
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        $ht = @{}
        foreach ($prop in $Node.PSObject.Properties) {
            $ht[$prop.Name] = Convert-LokiJsonNode -Node $prop.Value
        }
        return $ht
    }
    if (($Node -is [System.Collections.IEnumerable]) -and (-not ($Node -is [string]))) {
        $list = @()
        foreach ($item in $Node) { $list += , (Convert-LokiJsonNode -Node $item) }
        return , $list
    }
    return $Node
}

function Read-LokiConfig {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return @{}
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @{}
    }

    try {
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Invalid Loki config: $Path"
    }

    $converted = Convert-LokiJsonNode -Node $parsed
    if ($null -eq $converted) { return @{} }
    if (-not ($converted -is [hashtable])) {
        throw "Invalid Loki config: $Path"
    }
    return $converted
}

function Write-LokiConfig {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Config
    )

    $dir = Split-Path -Path $Path -Parent
    if ((-not [string]::IsNullOrEmpty($dir)) -and (-not (Test-Path -LiteralPath $dir))) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    $json = $Config | ConvertTo-Json -Depth 10
    # Config file is a DATA FILE written at RUNTIME -> BOM-LESS, analogous to Write-LokiEnvFile in
    # lib/auth.ps1 (Set-Content -Encoding utf8 would produce a BOM under 5.1). Does NOT affect the
    # .ps1 SOURCE FILES, which still need a BOM (CLAUDE.md section 1).
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Resolve-LokiSetting {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][hashtable]$Flags,
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][AllowNull()]$Default,
        [string]$EnvName
    )

    if ($Flags.ContainsKey($Key) -and ($null -ne $Flags[$Key])) {
        return $Flags[$Key]
    }

    $resolvedEnvName = $EnvName
    if ([string]::IsNullOrEmpty($resolvedEnvName)) {
        $resolvedEnvName = 'LOKI_' + $Key.ToUpper()
    }
    $envValue = [System.Environment]::GetEnvironmentVariable($resolvedEnvName)
    if (-not [string]::IsNullOrEmpty($envValue)) {
        return $envValue
    }

    if ($Config.ContainsKey($Key)) {
        return $Config[$Key]
    }

    return $Default
}
