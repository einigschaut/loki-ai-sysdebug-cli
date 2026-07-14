# commands/version.ps1 — `loki version`
# Metadata (Get-LokiCmdMeta_version) is the single source of truth; handler (Invoke-LokiCmd_version) executes it.
# CLAUDE.md §3: the registry enumerates these functions; the name/handler pair must be consistent.
Set-StrictMode -Version Latest

function Get-LokiCmdMeta_version {
    @{
        Name     = 'version'
        Group    = 'Health'
        Summary  = 'version.summary'
        Usage    = 'loki version'
        Examples = @('loki version')
        Flags    = @()
    }
}

function Invoke-LokiCmd_version {
    param($Context)
    Write-LokiLine ("{0,-12} {1}" -f 'loki', $Context.Version)
    Write-LokiLine ("{0,-12} {1}" -f 'PowerShell', $PSVersionTable.PSVersion.ToString())
    Write-LokiLine ("{0,-12} {1}" -f 'OS', [System.Environment]::OSVersion.VersionString)
    # Later (F6): claude.exe, llama-server, and model versions + integrity checksums from the manifest.
    return (Get-LokiExitCode 'Ok')
}
