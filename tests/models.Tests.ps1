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
            KVCache = @{ Layers = 28; KVHeads = 8; HeadDim = 128 }
        }
        foreach ($k in $Override.Keys) { $e[$k] = $Override[$k] }
        $path = Join-Path (New-ModelsCaseDir) 'manifest.psd1'
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('@{ Models = @(')
        [void]$sb.AppendLine('  @{')
        foreach ($k in $e.Keys) {
            $v = $e[$k]
            if ($v -is [string]) { [void]$sb.AppendLine(("    {0} = '{1}'" -f $k, $v)) }
            elseif ($v -is [System.Collections.IDictionary]) {
                # A nested hashtable (KVCache) -> an inline psd1 literal. Values here are ints; an override can pass a
                # bad one (0/negative/missing field) to drive the KVCache validation, or a non-hashtable via `else`.
                $parts = @(); foreach ($ik in $v.Keys) { $parts += ("{0} = {1}" -f $ik, $v[$ik]) }
                [void]$sb.AppendLine(("    {0} = @{{ {1} }}" -f $k, ($parts -join '; ')))
            }
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
            # ADR-0026: the supply-chain surface must not point at a moving target -- every shipped url pins an
            # immutable 40-hex commit, never /resolve/main/.
            ([string]$m.Url) | Should -Match '/resolve/[0-9a-f]{40}/'
            ([string]$m.Sha256) | Should -Match '^[0-9a-fA-F]{64}$'
            ([string]$m.FileName) | Should -Match '^[A-Za-z0-9._-]+$'
            ([long]$m.SizeBytes) | Should -BeGreaterThan 0
            # ADR-0025: every tier carries a positive KV geometry so the offline window can size to free RAM.
            $m.KVCache | Should -BeOfType [System.Collections.IDictionary]
            foreach ($gk in 'Layers', 'KVHeads', 'HeadDim') { ([int]$m.KVCache[$gk]) | Should -BeGreaterThan 0 }
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

    It 'rejects a huggingface Url that points at a MOVING ref instead of an immutable revision (ADR-0026)' {
        { Get-LokiModelManifest -Path (New-TempManifest @{ Url = 'https://huggingface.co/o/r/resolve/main/m.gguf' }) } | Should -Throw
    }

    It 'ACCEPTS a huggingface Url that pins a 40-hex revision (the rule must not just reject everything)' {
        # The positive half. Without it the guard above would still pass if the rule rejected every huggingface url.
        $u = 'https://huggingface.co/o/r/resolve/' + ('a' * 40) + '/m.gguf'
        { Get-LokiModelManifest -Path (New-TempManifest @{ Url = $u }) } | Should -Not -Throw
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

    It 'rejects a KVCache that is not a hashtable (ADR-0025)' {
        { Get-LokiModelManifest -Path (New-TempManifest @{ KVCache = 5 }) } | Should -Throw
    }

    It 'rejects a KVCache with a non-positive geometry field -- wrong-low is the dangerous direction (ADR-0025)' {
        { Get-LokiModelManifest -Path (New-TempManifest @{ KVCache = @{ Layers = 0; KVHeads = 8; HeadDim = 128 } }) } | Should -Throw
    }

    It 'rejects a KVCache missing a geometry field (ADR-0025)' {
        { Get-LokiModelManifest -Path (New-TempManifest @{ KVCache = @{ Layers = 36; KVHeads = 8 } }) } | Should -Throw
    }
}

Describe 'Read-LokiModelManifestSafe (fail-closed wrapper -> an operator-actionable result, issue #87)' {
    # Wraps the fail-closed validator so a consuming command (offline/hwscan/doctor) can turn a rejected manifest into
    # a "rebuild the stick" hint instead of a raw dispatcher stack trace. The validator itself is UNCHANGED -- these
    # prove the wrapper translates a throw to Ok=$false WITHOUT ever returning a half-validated manifest.

    It 'a valid manifest -> Ok, the models, and an empty Detail' {
        $r = Read-LokiModelManifestSafe -Path $script:ManifestPath
        $r.Ok              | Should -BeTrue
        @($r.Models).Count | Should -BeGreaterThan 0
        $r.Detail          | Should -Be ''
    }

    It 'an OUTDATED stick manifest (a moving /resolve/main/ ref -- the exact #87 case) -> Ok=$false + the validator Detail, never a throw' {
        $bad = New-TempManifest @{ Url = 'https://huggingface.co/o/r/resolve/main/m.gguf' }
        { Read-LokiModelManifestSafe -Path $bad } | Should -Not -Throw   # the wrapper swallows the validator throw
        $r = Read-LokiModelManifestSafe -Path $bad
        $r.Ok              | Should -BeFalse
        $r.Detail          | Should -Match '(?i)immutable|resolve|revision'
        @($r.Models).Count | Should -Be 0
    }

    It 'a missing manifest file -> Ok=$false + Detail, never a throw' {
        $r = Read-LokiModelManifestSafe -Path (Join-Path $script:RootTmp 'does-not-exist\manifest.psd1')
        $r.Ok     | Should -BeFalse
        $r.Detail | Should -Match '(?i)not found'
    }

    It 'BREAK-THE-GUARD: Ok tracks reality -- it neither fails a valid manifest nor passes a broken one' {
        (Read-LokiModelManifestSafe -Path $script:ManifestPath).Ok                            | Should -BeTrue
        (Read-LokiModelManifestSafe -Path (New-TempManifest @{ Sha256 = 'nothex' })).Ok       | Should -BeFalse
    }
}

Describe 'Merge-LokiModelCatalog (shipped + the operator''s own catalog, issue #103)' {

    It 'stamps where each entry came from, keeping catalog order first' {
        # assign FIRST, then wrap: like Get-LokiModelManifest this returns `, @(...)` so a single-entry result stays an
        # array; @(FUNC) directly would collapse it to one element holding the array.
        $merged = Merge-LokiModelCatalog -Catalog @(@{ Id = 'small' }, @{ Id = 'mid' }) -Local @(@{ Id = 'byo' })
        $merged = @($merged)
        $merged.Count | Should -Be 3
        (@($merged | ForEach-Object { $_.Id }) -join ',')     | Should -Be 'small,mid,byo'
        (@($merged | ForEach-Object { $_.Source }) -join ',') | Should -Be 'catalog,catalog,local'
    }

    It 'an ABSENT local catalog is the normal case: the result is exactly the shipped one' {
        $merged = @(Merge-LokiModelCatalog -Catalog @(@{ Id = 'small' }) -Local @())
        $merged.Count  | Should -Be 1
        $merged[0].Id  | Should -Be 'small'
    }

    It 'a DUPLICATE id across the two manifests THROWS -- load order must never decide which weights a tier points at' {
        { Merge-LokiModelCatalog -Catalog @(@{ Id = 'mid' }) -Local @(@{ Id = 'mid' }) } | Should -Throw
    }

    It 'PURE: it copies entries -- stamping never mutates the caller''s manifest objects' {
        $catalog = @(@{ Id = 'small' })
        [void](Merge-LokiModelCatalog -Catalog $catalog -Local @())
        $catalog[0].ContainsKey('Source') | Should -BeFalse
    }
}

Describe 'Get-LokiModelCatalog / Read-LokiModelManifestSafe -LocalPath (the BYO path, issue #103)' {

    It 'no local manifest -> identical to before #103 (absence is not a fault)' {
        $r = Read-LokiModelManifestSafe -Path $script:ManifestPath -LocalPath (Join-Path $script:RootTmp 'nope\manifest.local.psd1')
        $r.Ok | Should -BeTrue
        @($r.Models).Count | Should -BeGreaterThan 0
        @($r.Models | Where-Object { [string]$_.Source -eq 'local' }).Count | Should -Be 0
    }

    It 'a local entry is ADDED to the tier list and marked as local' {
        $local = New-TempManifest @{ Id = 'byo-nemo'; FileName = 'byo.gguf' }
        $r = Read-LokiModelManifestSafe -Path $script:ManifestPath -LocalPath $local
        $r.Ok | Should -BeTrue
        $byo = @($r.Models | Where-Object { [string]$_.Id -eq 'byo-nemo' })
        $byo.Count       | Should -Be 1
        $byo[0].Source   | Should -Be 'local'
    }

    It 'a NON-Apache/MIT license is accepted in the LOCAL catalog -- that is the whole point of #103' {
        # The shipped manifest is held to Apache-2.0/MIT by the test above; the operator's own file is not, because the
        # licence decision there is theirs. Concrete driver: NVIDIA Nemotron (NVIDIA Open Model License).
        $local = New-TempManifest @{ Id = 'byo-nemo'; FileName = 'byo.gguf'; License = 'NVIDIA Open Model License' }
        $r = Read-LokiModelManifestSafe -Path $script:ManifestPath -LocalPath $local
        $r.Ok | Should -BeTrue
        (@($r.Models | Where-Object { [string]$_.Id -eq 'byo-nemo' })[0]).License | Should -Be 'NVIDIA Open Model License'
    }

    It 'PRIVATE IS NOT UNCHECKED: a local entry with a bad sha256 fails the whole load, fail-closed' {
        # The integrity rules are NOT relaxed for the private path -- only the licence test is out of scope there.
        $local = New-TempManifest @{ Id = 'byo-bad'; FileName = 'byo.gguf'; Sha256 = 'nothex' }
        $r = Read-LokiModelManifestSafe -Path $script:ManifestPath -LocalPath $local
        $r.Ok     | Should -BeFalse
        $r.Detail | Should -Match '(?i)sha256'
        @($r.Models).Count | Should -Be 0
    }

    It 'PRIVATE IS NOT UNCHECKED: a local entry on a MOVING huggingface ref fails too (ADR-0026 still applies)' {
        $local = New-TempManifest @{ Id = 'byo-moving'; FileName = 'byo.gguf'; Url = 'https://huggingface.co/o/r/resolve/main/m.gguf' }
        (Read-LokiModelManifestSafe -Path $script:ManifestPath -LocalPath $local).Ok | Should -BeFalse
    }

    It 'a broken local manifest is never SKIPPED -- dropping the operator''s tiers would change which model runs' {
        $local = New-TempManifest @{ Id = 'byo'; FileName = 'byo.gguf'; SizeBytes = 0 }
        $r = Read-LokiModelManifestSafe -Path $script:ManifestPath -LocalPath $local
        $r.Ok | Should -BeFalse   # NOT "Ok=$true with the shipped catalog only"
    }

    It 'Get-LokiModelCatalog THROWS on a broken local manifest (the raw primitive setup relies on)' {
        $local = New-TempManifest @{ Id = 'byo'; FileName = 'byo.gguf'; Sha256 = 'nothex' }
        { Get-LokiModelCatalog -Path $script:ManifestPath -LocalPath $local } | Should -Throw
    }

    It 'Get-LokiModelLayout exposes the local path beside the shipped one' {
        $layout = Get-LokiModelLayout -AppRoot 'C:\stick'
        $layout.ManifestPath      | Should -BeLike '*\models\manifest.psd1'
        $layout.LocalManifestPath | Should -BeLike '*\models\manifest.local.psd1'
    }
}

Describe 'The PUBLIC supply chain stays Apache/MIT-only (the guard #103 must never weaken)' {

    It 'the REPO carries no manifest.local.psd1 -- a committed BYO catalog would push its licence on every user' {
        # .gitignore covers it; this is the belt to that braces. A local catalog may hold a non-Apache/MIT model by
        # design, so one landing in the shipped tree would silently break the licence guarantee the gate exists for.
        $repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
        $found = @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Filter 'manifest.local.psd1' -ErrorAction SilentlyContinue)
        $found.Count | Should -Be 0 -Because 'a private BYO catalog must never be committed'
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
