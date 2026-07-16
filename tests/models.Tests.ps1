# tests/models.Tests.ps1 -- offline model acquisition (security core, CLAUDE.md section 5/6, ADR-0011).
# Covers the pure/testable surface of lib/models.ps1 and the REAL src/models/manifest.psd1: manifest validation
# (fail-closed on http/bad-hash/traversal/dup), SHA256 verification, the download plan, and -- the key security
# property -- that a verified download keeps a matching file and DELETES a mismatching one (nothing unverified
# survives). The real network fetch (Get-LokiHttpFile) is Mocked; verification runs against real local temp files.
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\models.ps1"

    $script:ManifestPath = (Resolve-Path "$PSScriptRoot\..\src\models\manifest.psd1").Path
    $script:RootTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("loki-models-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:RootTmp | Out-Null

    # Deterministic known bytes + their real SHA256 (computed, not hardcoded) -- the "good" download.
    $script:GoodBytes = 'loki-verified-model-bytes-v1'
    $seed = Join-Path $script:RootTmp 'seed.bin'
    [System.IO.File]::WriteAllText($seed, $script:GoodBytes, [System.Text.Encoding]::ASCII)
    $script:GoodHash = (Get-FileHash -LiteralPath $seed -Algorithm SHA256).Hash

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
            Sha256 = ('a' * 64); SizeBytes = 123; MinRamGB = 2.0; ContextTokens = 4096
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

Describe 'Test-LokiFileHash' {

    It 'true for a matching file, false for a wrong hash, false for a missing file' {
        $d = New-ModelsCaseDir
        $f = Join-Path $d 'a.bin'
        [System.IO.File]::WriteAllText($f, $script:GoodBytes, [System.Text.Encoding]::ASCII)
        Test-LokiFileHash -Path $f -ExpectedSha256 $script:GoodHash | Should -BeTrue
        Test-LokiFileHash -Path $f -ExpectedSha256 ('b' * 64) | Should -BeFalse
        Test-LokiFileHash -Path (Join-Path $d 'missing.bin') -ExpectedSha256 $script:GoodHash | Should -BeFalse
    }

    It 'is case-insensitive on the hex' {
        $d = New-ModelsCaseDir
        $f = Join-Path $d 'a.bin'
        [System.IO.File]::WriteAllText($f, $script:GoodBytes, [System.Text.Encoding]::ASCII)
        Test-LokiFileHash -Path $f -ExpectedSha256 ($script:GoodHash.ToLower()) | Should -BeTrue
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

Describe 'Invoke-LokiVerifiedDownload (integrity gate; network Mocked)' {

    It 'refuses a non-https url without downloading' {
        Mock Get-LokiHttpFile { throw 'must not download for non-https' }
        $d = New-ModelsCaseDir
        $r = Invoke-LokiVerifiedDownload -Url 'http://example.com/m.gguf' -ExpectedSha256 $script:GoodHash -DestPath (Join-Path $d 'm.gguf')
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'not-https'
    }

    It 'downloads + verifies a matching file -> Ok, file present, no .part left' {
        Mock Get-LokiHttpFile { [System.IO.File]::WriteAllText($OutFile, $script:GoodBytes, [System.Text.Encoding]::ASCII) }
        $d = New-ModelsCaseDir
        $dest = Join-Path $d 'm.gguf'
        $r = Invoke-LokiVerifiedDownload -Url 'https://example.com/m.gguf' -ExpectedSha256 $script:GoodHash -DestPath $dest
        $r.Ok | Should -BeTrue
        Test-Path -LiteralPath $dest | Should -BeTrue
        Test-Path -LiteralPath ($dest + '.part') | Should -BeFalse
    }

    It 'BREAK-THE-GUARD: a tampered download (hash mismatch) is DELETED and never kept' {
        Mock Get-LokiHttpFile { [System.IO.File]::WriteAllText($OutFile, 'TAMPERED-BYTES', [System.Text.Encoding]::ASCII) }
        $d = New-ModelsCaseDir
        $dest = Join-Path $d 'm.gguf'
        $r = Invoke-LokiVerifiedDownload -Url 'https://example.com/m.gguf' -ExpectedSha256 $script:GoodHash -DestPath $dest
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'hash-mismatch'
        Test-Path -LiteralPath $dest | Should -BeFalse            # nothing unverified at the destination
        Test-Path -LiteralPath ($dest + '.part') | Should -BeFalse # and no partial left behind
    }

    It 'skips an already-present, already-verified file (no re-download)' {
        Mock Get-LokiHttpFile { throw 'should not be called when already verified' }
        $d = New-ModelsCaseDir
        $dest = Join-Path $d 'm.gguf'
        [System.IO.File]::WriteAllText($dest, $script:GoodBytes, [System.Text.Encoding]::ASCII)
        $r = Invoke-LokiVerifiedDownload -Url 'https://example.com/m.gguf' -ExpectedSha256 $script:GoodHash -DestPath $dest
        $r.Ok | Should -BeTrue
        $r.Skipped | Should -BeTrue
        Should -Invoke Get-LokiHttpFile -Times 0 -Exactly
    }

    It 'a download error AFTER a partial write -> Ok=$false, the partial is cleaned up' {
        # The mock writes a .part (like a real interrupted transfer) THEN throws, so the catch-block cleanup is
        # actually exercised (not a no-op that would pass even if cleanup were removed).
        Mock Get-LokiHttpFile { [System.IO.File]::WriteAllText($OutFile, 'partial-bytes', [System.Text.Encoding]::ASCII); throw 'network down' }
        $d = New-ModelsCaseDir
        $dest = Join-Path $d 'm.gguf'
        $r = Invoke-LokiVerifiedDownload -Url 'https://example.com/m.gguf' -ExpectedSha256 $script:GoodHash -DestPath $dest
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'download-failed'
        Test-Path -LiteralPath ($dest + '.part') | Should -BeFalse
        Test-Path -LiteralPath $dest | Should -BeFalse
    }
}
