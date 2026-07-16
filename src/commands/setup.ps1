# commands/setup.ps1 -- `loki setup` (structurally identical to a scaffolded command; hand-written like commands/auth.ps1
# because it pairs with the hand-curated src/models/manifest.psd1 + lib/models.ps1). ADR-0002/0011.
# Run on the internet-connected machine where the stick is prepared: pick offline model tier(s) and download+verify
# them onto the stick. Thin wiring -- lib/models.ps1 owns the manifest, the plan, and the verified download.
Set-StrictMode -Version Latest

function Get-LokiCmdMeta_setup {
    @{
        Name     = 'setup'
        Group    = 'Setup'
        Summary  = 'setup.summary'
        Usage    = 'loki setup [--tier <id,...|default|all>]'
        Examples = @('loki setup', 'loki setup --tier default', 'loki setup --tier small,mid')
        Flags    = @( @{ Flag = '--tier'; Desc = 'Model tier ids to download (comma-separated), or "default"/"all"; skips the picker' } )
    }
}

function Invoke-LokiCmd_setup {
    param($Context)

    # Prep-time command: it downloads from Hugging Face, so probe THAT host (not the default api.anthropic.com) --
    # a network that allows Anthropic but blocks HF must fail fast here, not deep in the download loop.
    if (-not (Test-LokiConnectivity -TargetHost 'huggingface.co')) {
        Write-LokiErr (Get-LokiText 'setup.offline')
        return (Get-LokiExitCode 'NetworkRequired')
    }

    $manifestPath = Join-Path $Context.AppRoot 'models\manifest.psd1'
    $models = Get-LokiModelManifest -Path $manifestPath
    $destDir = Join-Path $Context.AppRoot 'models'

    # Selection tokens from args (--tier <ids> or bare ids); empty -> interactive picker below.
    $tokens = New-Object System.Collections.Generic.List[string]
    foreach ($a in $Context.Args) {
        $s = [string]$a
        if ($s -eq '--tier') { continue }
        $s = $s -replace '^--tier=', ''
        foreach ($part in ($s -split '[,\s]+')) {
            if (-not [string]::IsNullOrWhiteSpace($part)) { $tokens.Add($part.Trim().ToLowerInvariant()) }
        }
    }

    # Always show the catalog (sizes let the user pick to fit their stick + RAM -- the whole point of the picker).
    Write-LokiHeading (Get-LokiText 'setup.heading')
    Write-LokiLine (Get-LokiText 'setup.tiersHint')
    foreach ($m in $models) {
        $gb = [math]::Round(([double]$m.SizeBytes / 1GB), 2)
        $star = ''
        if ($m.Default) { $star = ' *' }
        Write-LokiLine ("  {0,-14} {1,-26} {2,6} GB  RAM~{3}GB  ctx {4}  {5}{6}" -f $m.Id, $m.Model, $gb, $m.MinRamGB, $m.ContextTokens, $m.License, $star)
    }

    if ($tokens.Count -eq 0) {
        $choice = [string](Read-Host -Prompt (Get-LokiText 'setup.choosePrompt'))
        foreach ($part in ($choice -split '[,\s]+')) {
            if (-not [string]::IsNullOrWhiteSpace($part)) { $tokens.Add($part.Trim().ToLowerInvariant()) }
        }
    }

    # Resolve keywords (default/all) + validate ids against the manifest.
    $validIds = @($models | ForEach-Object { [string]$_.Id })
    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($t in $tokens) {
        if ($t -eq 'default') {
            foreach ($m in $models) { if ($m.Default) { if (-not $ids.Contains([string]$m.Id)) { $ids.Add([string]$m.Id) } } }
        }
        elseif ($t -eq 'all') {
            foreach ($m in $models) { if (-not $ids.Contains([string]$m.Id)) { $ids.Add([string]$m.Id) } }
        }
        elseif ($validIds -contains $t) {
            if (-not $ids.Contains($t)) { $ids.Add($t) }
        }
        else {
            Write-LokiErr (Get-LokiText 'setup.badSelection' -ArgumentList @($t))
            return (Get-LokiExitCode 'Usage')
        }
    }

    if ($ids.Count -eq 0) {
        Write-LokiWarn (Get-LokiText 'setup.noneSelected')
        return (Get-LokiExitCode 'Ok')
    }

    $plan = Get-LokiModelDownloadPlan -Models $models -SelectedIds $ids.ToArray() -DestDir $destDir

    $failed = 0
    foreach ($p in $plan) {
        Write-LokiInfo (Get-LokiText 'setup.downloading' -ArgumentList @($p.Model, [math]::Round(([double]$p.SizeBytes / 1GB), 2)))
        $res = Invoke-LokiVerifiedDownload -Url $p.Url -ExpectedSha256 $p.Sha256 -DestPath $p.DestPath
        if ($res.Ok) {
            if ($res.ContainsKey('Skipped') -and $res.Skipped) { Write-LokiOk (Get-LokiText 'setup.skipped' -ArgumentList @($p.Model)) }
            else { Write-LokiOk (Get-LokiText 'setup.verified' -ArgumentList @($p.Model)) }
        }
        else {
            $failed++
            Write-LokiErr (Get-LokiText 'setup.verifyFailed' -ArgumentList @($p.Model, [string]$res.Reason))
        }
    }

    if ($failed -gt 0) { return (Get-LokiExitCode 'GeneralError') }
    Write-LokiOk (Get-LokiText 'setup.done' -ArgumentList @($plan.Count))
    Write-LokiInfo (Get-LokiText 'setup.engineNote')
    return (Get-LokiExitCode 'Ok')
}
