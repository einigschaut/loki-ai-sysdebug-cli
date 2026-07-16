# tests/models.Tests.ps1 -- the offline MODEL catalog (security core, CLAUDE.md section 5/6, ADR-0011).
# Covers lib/models.ps1 and the REAL src/models/manifest.psd1: fail-closed manifest validation (http / bad hash /
# traversal / reserved name / dup id / non-positive size) and the download plan. The verified fetch itself lives in
# lib/download.ps1 and is covered by tests/download.Tests.ps1 -- one test file per module, same split as the code.
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\models.ps1"

    $script:ManifestPath = (Resolve-Path "$PSScriptRoot\..\src\models\manifest.psd1").Path
    $script:RootTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("loki-models-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:RootTmp | Out-Null

    function global:New-ModelsCaseDir {
        $d = Join-Path $script:RootTmp ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        return $d
    }

    # Writes a temp manifest .psd1 with one entry, overriding fields to force validation failures.
    function global:New-TempManifest {
        param([hashtable]$Override = @{})
        $e = @{
            Id = 'x'; Model = 'M'; Tier = 'T'; License = 'Apache-2.0'
            Url = 'https://example.com/m.gguf'; FileName = 'm.gguf'
            Sha256 = ('a' * 64); SizeBytes = 123; ResidentGB = 2.0; ContextTokens = 4096
        }
        foreach ($k in $Override.Keys) { $e[$k] = $Override[$k] }
        $path = Join-Path (New-ModelsCaseDir) 'manifest.psd1'
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('@{ Models = @(')
        [void]$sb.AppendLine('  @{')
        foreach ($k in $e.Keys) {
            $v = $e[$k]
            if ($v -is [string]) { [void]$sb.AppendLine(("    {0} = '{1}'" -f $k, $v)) }
            else { [void]$sb.AppendLine(("    {0} = {1}" -f $k, $v)) }
        }
        [void]$sb.AppendLine('  }')
        [void]$sb.AppendLine(') }')
        [System.IO.File]::WriteAllText($path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
        return $path
    }
}

AfterAll {
    if (Test-Path -LiteralPath $script:RootTmp) { Remove-Item -LiteralPath $script:RootTmp -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item Function:\New-ModelsCaseDir -ErrorAction SilentlyContinue
    Remove-Item Function:\New-TempManifest -ErrorAction SilentlyContinue
}

Describe 'Get-LokiModelManifest (real manifest + fail-closed validation)' {

    It 'loads the shipped manifest: every entry is https, 64-hex sha256, safe filename, unique id' {
        $models = Get-LokiModelManifest -Path $script:ManifestPath
        $models.Count | Should -BeGreaterThan 0
        $ids = @()
        foreach ($m in $models) {
            ([string]$m.Url) | Should -Match '^https://'
            ([string]$m.Sha256) | Should -Match '^[0-9a-fA-F]{64}$'
            ([string]$m.FileName) | Should -Match '^[A-Za-z0-9._-]+$'
            ([long]$m.SizeBytes) | Should -BeGreaterThan 0
            $ids += [string]$m.Id
        }
        ($ids | Select-Object -Unique).Count | Should -Be $ids.Count
        # Free-license only (Apache/MIT) -- no research/community-restricted models slipped in.
        foreach ($m in $models) { @('Apache-2.0', 'MIT') | Should -Contain ([string]$m.License) }
    }

    It 'exactly one model is marked Default' {
        $models = Get-LokiModelManifest -Path $script:ManifestPath
        @($models | Where-Object { $_.Default }).Count | Should -Be 1
    }

    It 'rejects a non-https Url (no plaintext / downgrade)' {
        { Get-LokiModelManifest -Path (New-TempManifest @{ Url = 'http://example.com/m.gguf' }) } | Should -Throw
    }

    It 'rejects a malformed sha256' {
        { Get-LokiModelManifest -Path (New-TempManifest @{ Sha256 = 'nothex' }) } | Should -Throw
    }

    It 'rejects a traversal / unsafe / reserved filename: <fn>' -ForEach @(
        @{ fn = '..\evil.gguf' }, @{ fn = 'a/b.gguf' }, @{ fn = 'x.gguf; rm' },
        @{ fn = '..' }, @{ fn = '.' }, @{ fn = 'CON' }, @{ fn = 'NUL.gguf' }, @{ fn = 'COM1' }
    ) {
        { Get-LokiModelManifest -Path (New-TempManifest @{ FileName = $fn }) } | Should -Throw
    }

    It 'rejects a non-positive SizeBytes' {
        { Get-LokiModelManifest -Path (New-TempManifest @{ SizeBytes = 0 }) } | Should -Throw
    }
}

Describe 'Get-LokiModelDownloadPlan' {

    It 'maps selected ids to url + sha256 + dest path; throws on an unknown id' {
        $models = Get-LokiModelManifest -Path $script:ManifestPath
        $plan = Get-LokiModelDownloadPlan -Models $models -SelectedIds @('small') -DestDir 'C:\stick\models'
        $plan.Count | Should -Be 1
        $plan[0].DestPath | Should -BeLike '*\models\Qwen3-4B-Instruct-2507-Q4_K_M.gguf'
        $plan[0].Url | Should -Match '^https://'
        { Get-LokiModelDownloadPlan -Models $models -SelectedIds @('does-not-exist') -DestDir 'C:\x' } | Should -Throw
    }
}
