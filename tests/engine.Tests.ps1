# tests/engine.Tests.ps1 -- offline engine acquisition + MSVC runtime staging (security core, CLAUDE.md section 5/6,
# ADR-0012). The engine archive is CODE the target executes, so the properties under test are the hard ones:
#   * the shipped src/engine/manifest.psd1 is https + 64-hex + MIT and validates fail-closed on every bad field.
#   * an archive whose hash does NOT match the pin is never expanded (BREAK-THE-GUARD).
#   * a zip-slip entry ('../evil') aborts the expansion and writes NOTHING (BREAK-THE-GUARD).
#   * the runtime is never staged from a source that is incomplete, unreadable, or too old (fail-closed).
# Real local zips + real versioned files are used (no mocks) -- the version tests borrow kernel32.dll, which always
# exists and carries a real FileVersion, so they are deterministic on any Windows host instead of depending on
# whatever VC++ runtime the test machine happens to have.
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\download.ps1"   # Test-LokiFileHash -- Expand-LokiVerifiedArchive verifies through it
    . "$PSScriptRoot\..\src\lib\engine.ps1"
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $script:ManifestPath = (Resolve-Path "$PSScriptRoot\..\src\engine\manifest.psd1").Path
    $script:RootTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("loki-engine-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:RootTmp | Out-Null
    # A real, versioned Windows binary -- stand-in for a runtime dll so version logic is host-independent.
    $script:VersionedSource = Join-Path $env:SystemRoot 'System32\kernel32.dll'

    function global:New-EngineCaseDir {
        $d = Join-Path $script:RootTmp ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        return $d
    }

    # Builds a zip with the given entryName -> content, and returns @{ Path; Hash }.
    function global:New-TestZip {
        param([hashtable]$Entries)
        $path = Join-Path (New-EngineCaseDir) 'a.zip'
        $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew)
        try {
            $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
            try {
                foreach ($name in $Entries.Keys) {
                    $entry = $zip.CreateEntry([string]$name)
                    $sw = New-Object System.IO.StreamWriter($entry.Open())
                    try { $sw.Write([string]$Entries[$name]) } finally { $sw.Dispose() }
                }
            }
            finally { $zip.Dispose() }
        }
        finally { $fs.Dispose() }
        return @{ Path = $path; Hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
    }

    # Writes a temp engine manifest, overriding Engine/Runtime fields to force validation failures.
    function global:New-TempEngineManifest {
        param([hashtable]$Engine = @{}, [hashtable]$Runtime = @{}, [switch]$OmitRuntime)
        $e = @{
            Id = 'llama.cpp'; Version = 'b1'; Platform = 'win-cpu-x64'; License = 'MIT'
            Url = 'https://example.com/e.zip'; FileName = 'e.zip'
            Sha256 = ('a' * 64); SizeBytes = 123; ServerExe = 'llama-server.exe'
        }
        foreach ($k in $Engine.Keys) { $e[$k] = $Engine[$k] }
        $r = @{ Files = @('VCRUNTIME140.dll'); MinVersion = '14.30'; RegistryKey = 'HKLM:\x' }
        foreach ($k in $Runtime.Keys) { $r[$k] = $Runtime[$k] }

        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('@{')
        [void]$sb.AppendLine('  Engine = @{')
        foreach ($k in $e.Keys) {
            $v = $e[$k]
            if ($v -is [string]) { [void]$sb.AppendLine(("    {0} = '{1}'" -f $k, $v)) }
            else { [void]$sb.AppendLine(("    {0} = {1}" -f $k, $v)) }
        }
        [void]$sb.AppendLine('  }')
        if (-not $OmitRuntime) {
            [void]$sb.AppendLine('  Runtime = @{')
            $fileList = @($r.Files) | ForEach-Object { "'" + $_ + "'" }
            [void]$sb.AppendLine('    Files = @(' + ($fileList -join ', ') + ')')
            [void]$sb.AppendLine(("    MinVersion = '{0}'" -f $r.MinVersion))
            [void]$sb.AppendLine(("    RegistryKey = '{0}'" -f $r.RegistryKey))
            [void]$sb.AppendLine('  }')
        }
        [void]$sb.AppendLine('}')
        $path = Join-Path (New-EngineCaseDir) 'manifest.psd1'
        [System.IO.File]::WriteAllText($path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
        return $path
    }
}

AfterAll {
    if (Test-Path -LiteralPath $script:RootTmp) { Remove-Item -LiteralPath $script:RootTmp -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item Function:\New-EngineCaseDir -ErrorAction SilentlyContinue
    Remove-Item Function:\New-TestZip -ErrorAction SilentlyContinue
    Remove-Item Function:\New-TempEngineManifest -ErrorAction SilentlyContinue
}

Describe 'Get-LokiEngineManifest (real manifest + fail-closed validation)' {

    It 'loads the shipped engine manifest: https, 64-hex sha256, positive size, free license' {
        $d = Get-LokiEngineManifest -Path $script:ManifestPath
        ([string]$d.Engine.Url) | Should -Match '^https://'
        ([string]$d.Engine.Sha256) | Should -Match '^[0-9a-fA-F]{64}$'
        ([long]$d.Engine.SizeBytes) | Should -BeGreaterThan 0
        @('MIT', 'Apache-2.0') | Should -Contain ([string]$d.Engine.License)
        ([string]$d.Engine.ServerExe) | Should -Be 'llama-server.exe'
    }

    It 'the shipped Url actually points at the pinned FileName (url and name cannot drift apart)' {
        $d = Get-LokiEngineManifest -Path $script:ManifestPath
        ([string]$d.Engine.Url) | Should -BeLike ('*/' + [string]$d.Engine.FileName)
    }

    It 'the shipped runtime spec names only plain dlls and a parsable MinVersion' {
        $d = Get-LokiEngineManifest -Path $script:ManifestPath
        @($d.Runtime.Files).Count | Should -BeGreaterThan 0
        foreach ($f in @($d.Runtime.Files)) { ([string]$f) | Should -Match '\.dll$' }
        (ConvertTo-LokiRuntimeVersion -Text ([string]$d.Runtime.MinVersion)) | Should -Not -BeNullOrEmpty
    }

    It 'rejects a non-https Url' {
        { Get-LokiEngineManifest -Path (New-TempEngineManifest -Engine @{ Url = 'http://example.com/e.zip' }) } | Should -Throw
    }

    It 'rejects a malformed sha256' {
        { Get-LokiEngineManifest -Path (New-TempEngineManifest -Engine @{ Sha256 = 'nothex' }) } | Should -Throw
    }

    It 'rejects a non-positive SizeBytes' {
        { Get-LokiEngineManifest -Path (New-TempEngineManifest -Engine @{ SizeBytes = 0 }) } | Should -Throw
    }

    It 'rejects an unsafe FileName / ServerExe: <fn>' -ForEach @(
        @{ fn = '..\evil.zip' }, @{ fn = 'a/b.zip' }, @{ fn = '..' }, @{ fn = 'CON' }, @{ fn = 'NUL.zip' }
    ) {
        { Get-LokiEngineManifest -Path (New-TempEngineManifest -Engine @{ FileName = $fn }) } | Should -Throw
        { Get-LokiEngineManifest -Path (New-TempEngineManifest -Engine @{ ServerExe = $fn }) } | Should -Throw
    }

    It 'rejects a manifest without a Runtime section' {
        { Get-LokiEngineManifest -Path (New-TempEngineManifest -OmitRuntime) } | Should -Throw
    }

    It 'rejects an empty runtime file list and a non-dll runtime file' {
        { Get-LokiEngineManifest -Path (New-TempEngineManifest -Runtime @{ Files = @() }) } | Should -Throw
        { Get-LokiEngineManifest -Path (New-TempEngineManifest -Runtime @{ Files = @('evil.exe') }) } | Should -Throw
        { Get-LokiEngineManifest -Path (New-TempEngineManifest -Runtime @{ Files = @('..\x.dll') }) } | Should -Throw
    }

    It 'rejects an unparsable MinVersion' {
        { Get-LokiEngineManifest -Path (New-TempEngineManifest -Runtime @{ MinVersion = 'latest' }) } | Should -Throw
    }
}

Describe 'Get-LokiEngineLayout (pure)' {

    It 'puts the engine in engine-offline\ next to its archive and server exe' {
        $l = Get-LokiEngineLayout -AppRoot 'C:\stick' -Engine @{ FileName = 'e.zip'; ServerExe = 'llama-server.exe' }
        $l.Dir | Should -Be 'C:\stick\engine-offline'
        $l.ArchivePath | Should -Be 'C:\stick\engine-offline\e.zip'
        $l.ServerExePath | Should -Be 'C:\stick\engine-offline\llama-server.exe'
    }
}

Describe 'Test-LokiArchiveEntrySafe (the zip-slip gate; pure + table-tested)' {

    It 'accepts a normal entry: <n>' -ForEach @(
        @{ n = 'llama-server.exe' }, @{ n = 'sub/dir/file.dll' }, @{ n = 'a.b-c_d.txt' }
    ) {
        Test-LokiArchiveEntrySafe -EntryName $n | Should -BeTrue
    }

    It 'rejects an escaping / hostile entry: <n>' -ForEach @(
        @{ n = '' }, @{ n = '   ' },
        @{ n = '../evil.txt' }, @{ n = '..\evil.txt' }, @{ n = 'a/../../evil.txt' }, @{ n = 'a/..' },
        @{ n = '/etc/passwd' }, @{ n = '\windows\system32\evil.dll' },
        @{ n = 'C:\windows\evil.dll' }, @{ n = '//server/share/x' },
        @{ n = 'ok.txt:hidden' }, @{ n = 'wild*.txt' },
        # Adversarial review: Win32 strips trailing dots/spaces, so .NET and the PowerShell provider can disagree
        # about what the name even is. Reject rather than rely on both normalizers failing the safe way.
        @{ n = '.. /evil.txt' }, @{ n = '.. /.. /evil.txt' }, @{ n = 'a/b /c.txt' }, @{ n = 'trailing.' },
        # Device names are not files: extracting to them hits \\.\NUL and fails partway through the tree.
        @{ n = 'NUL' }, @{ n = 'CON' }, @{ n = 'COM1' }, @{ n = 'sub/NUL' }, @{ n = 'NUL.dll' },
        @{ n = 'a//b' }
    ) {
        Test-LokiArchiveEntrySafe -EntryName $n | Should -BeFalse
    }
}

Describe 'ConvertTo-LokiRuntimeVersion (pure + table-tested)' {

    It 'parses <t> -> <e>' -ForEach @(
        @{ t = '14.51.36247.0'; e = '14.51.36247.0' }
        @{ t = 'v14.51.36247.00'; e = '14.51.36247.0' }      # the registry shape
        @{ t = '14.30'; e = '14.30' }
        @{ t = '14.29.30139.0 built by: someone'; e = '14.29.30139.0' }
    ) {
        (ConvertTo-LokiRuntimeVersion -Text $t).ToString() | Should -Be $e
    }

    It 'returns $null for text without a version: <t>' -ForEach @(
        @{ t = '' }, @{ t = '   ' }, @{ t = 'latest' }, @{ t = $null }
    ) {
        ConvertTo-LokiRuntimeVersion -Text $t | Should -BeNullOrEmpty
    }

    It 'REGRESSION: returns $null instead of THROWING on an out-of-range component: <t>' -ForEach @(
        @{ t = '14.99999999999' }, @{ t = '2147483648.0' }, @{ t = '14.30.99999999999.0' }
    ) {
        # Contract is "$null on anything unparsable" so the caller fails closed; a [int] cast used to throw here and
        # the exception escaped Copy-LokiVcRuntimeAppLocal entirely (adversarial review).
        { ConvertTo-LokiRuntimeVersion -Text $t } | Should -Not -Throw
        ConvertTo-LokiRuntimeVersion -Text $t | Should -BeNullOrEmpty
    }

    It 'never reports a HIGHER version than the text says (truncating is the safe direction)' {
        (ConvertTo-LokiRuntimeVersion -Text '14.30.1.2.3.4').ToString() | Should -Be '14.30.1.2'
        (ConvertTo-LokiRuntimeVersion -Text '14.30.0.0-beta').ToString() | Should -Be '14.30.0.0'
    }
}

Describe 'Expand-LokiVerifiedArchive (integrity + zip-slip)' {

    It 'expands a verified archive and reports the file count' {
        $z = New-TestZip @{ 'llama-server.exe' = 'exe-bytes'; 'sub/ggml.dll' = 'dll-bytes' }
        $dest = New-EngineCaseDir
        $r = Expand-LokiVerifiedArchive -ArchivePath $z.Path -DestDir $dest -ExpectedSha256 $z.Hash
        $r.Ok | Should -BeTrue
        $r.Count | Should -Be 2
        Test-Path -LiteralPath (Join-Path $dest 'llama-server.exe') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $dest 'sub\ggml.dll') | Should -BeTrue
    }

    It 'is idempotent: expanding twice overwrites and stays Ok' {
        $z = New-TestZip @{ 'a.txt' = 'v1' }
        $dest = New-EngineCaseDir
        (Expand-LokiVerifiedArchive -ArchivePath $z.Path -DestDir $dest -ExpectedSha256 $z.Hash).Ok | Should -BeTrue
        $r = Expand-LokiVerifiedArchive -ArchivePath $z.Path -DestDir $dest -ExpectedSha256 $z.Hash
        $r.Ok | Should -BeTrue
        Get-Content -LiteralPath (Join-Path $dest 'a.txt') -Raw -Encoding UTF8 | Should -BeLike 'v1*'
    }

    It 'BREAK-THE-GUARD: an archive whose hash does not match the pin is NEVER expanded' {
        $z = New-TestZip @{ 'llama-server.exe' = 'exe-bytes' }
        $dest = New-EngineCaseDir
        $r = Expand-LokiVerifiedArchive -ArchivePath $z.Path -DestDir $dest -ExpectedSha256 ('b' * 64)
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'archive-unverified'
        Test-Path -LiteralPath (Join-Path $dest 'llama-server.exe') | Should -BeFalse
    }

    It 'BREAK-THE-GUARD: a tampered archive (verified pin, bytes changed after) is refused' {
        $z = New-TestZip @{ 'llama-server.exe' = 'exe-bytes' }
        $pinned = $z.Hash
        # Mutate the archive on disk after pinning -- exactly the "someone swapped the file on the stick" case.
        [System.IO.File]::AppendAllText($z.Path, 'TAMPER')
        $dest = New-EngineCaseDir
        $r = Expand-LokiVerifiedArchive -ArchivePath $z.Path -DestDir $dest -ExpectedSha256 $pinned
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'archive-unverified'
        @(Get-ChildItem -LiteralPath $dest -Force).Count | Should -Be 0
    }

    It 'REGRESSION: a planted file next to the engine is REMOVED by re-running the expansion' {
        # The whole point of re-running setup on a suspect stick. A planted ggml-cpu-<arch>.dll sits in
        # llama-server.exe's own directory -- first in the DLL search order -- and verifying the archive can never
        # detect it, because it is not in the archive. Found by adversarial review.
        $z = New-TestZip @{ 'llama-server.exe' = 'exe'; 'ggml-base.dll' = 'base' }
        $dest = New-EngineCaseDir
        (Expand-LokiVerifiedArchive -ArchivePath $z.Path -DestDir $dest -ExpectedSha256 $z.Hash).Ok | Should -BeTrue
        $planted = Join-Path $dest 'ggml-cpu-zen4.dll'
        [System.IO.File]::WriteAllText($planted, 'PWNED', [System.Text.Encoding]::ASCII)

        $r = Expand-LokiVerifiedArchive -ArchivePath $z.Path -DestDir $dest -ExpectedSha256 $z.Hash
        $r.Ok | Should -BeTrue
        $r.Pruned | Should -Be 1
        Test-Path -LiteralPath $planted | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $dest 'llama-server.exe') | Should -BeTrue
    }

    It 'REGRESSION: a pin bump removes the previous build''s orphaned files' {
        # If a bump exists to drop a vulnerable binary, that binary must not linger on an existing stick.
        $v1 = New-TestZip @{ 'llama-server.exe' = 'v1'; 'ggml-cpu-haswell.dll' = 'v1-VULNERABLE' }
        $dest = New-EngineCaseDir
        (Expand-LokiVerifiedArchive -ArchivePath $v1.Path -DestDir $dest -ExpectedSha256 $v1.Hash).Ok | Should -BeTrue

        $v2 = New-TestZip @{ 'llama-server.exe' = 'v2' }   # new build no longer ships that variant
        $r = Expand-LokiVerifiedArchive -ArchivePath $v2.Path -DestDir $dest -ExpectedSha256 $v2.Hash
        $r.Ok | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $dest 'ggml-cpu-haswell.dll') | Should -BeFalse
        Get-Content -LiteralPath (Join-Path $dest 'llama-server.exe') -Raw -Encoding UTF8 | Should -BeLike 'v2*'
    }

    It 'REGRESSION: the reconcile keeps the verified archive and the staged runtime (PreserveNames)' {
        # A naive prune would delete the operator-staged Microsoft runtime and the archive that IS the chain to the pin.
        $z = New-TestZip @{ 'llama-server.exe' = 'exe' }
        $dest = New-EngineCaseDir
        $archiveInDest = Join-Path $dest (Split-Path -Leaf $z.Path)
        Copy-Item -LiteralPath $z.Path -Destination $archiveInDest -Force
        $rt = Join-Path $dest 'VCRUNTIME140.dll'
        [System.IO.File]::WriteAllText($rt, 'ms-runtime', [System.Text.Encoding]::ASCII)

        $r = Expand-LokiVerifiedArchive -ArchivePath $archiveInDest -DestDir $dest -ExpectedSha256 $z.Hash -PreserveNames @('VCRUNTIME140.dll')
        $r.Ok | Should -BeTrue
        $r.Pruned | Should -Be 0
        Test-Path -LiteralPath $rt | Should -BeTrue
        Test-Path -LiteralPath $archiveInDest | Should -BeTrue
    }

    It 'REGRESSION: a failure during the swap leaves the OLD tree intact (not pruned-and-half-moved)' {
        # An earlier version pruned the destination and then moved files in one by one, so a failure in between left a
        # tree that was both pruned AND half-populated -- worse than doing nothing, while the ADR claimed the
        # destination was untouched. Adversarial review reproduced it. Now the new tree is built in a sibling and
        # swapped in, so a failure at the swap must leave the old tree exactly as it was.
        $v1 = New-TestZip @{ 'llama-server.exe' = 'V1'; 'ggml-base.dll' = 'V1' }
        $dest = New-EngineCaseDir
        (Expand-LokiVerifiedArchive -ArchivePath $v1.Path -DestDir $dest -ExpectedSha256 $v1.Hash).Ok | Should -BeTrue
        $orphan = Join-Path $dest 'ggml-cpu-zen4.dll'
        [System.IO.File]::WriteAllText($orphan, 'ORPHAN', [System.Text.Encoding]::ASCII)

        $v2 = New-TestZip @{ 'llama-server.exe' = 'V2' }
        Mock Move-Item { throw 'simulated swap failure' } -ParameterFilter { $LiteralPath -eq (Resolve-Path -LiteralPath $dest).ProviderPath }

        $r = Expand-LokiVerifiedArchive -ArchivePath $v2.Path -DestDir $dest -ExpectedSha256 $v2.Hash
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'expand-failed'
        # The old tree is untouched: nothing pruned, nothing replaced, no .new-/.old- leftovers.
        Get-Content -LiteralPath (Join-Path $dest 'llama-server.exe') -Raw -Encoding UTF8 | Should -BeLike 'V1*'
        Test-Path -LiteralPath $orphan | Should -BeTrue
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $dest) -Directory -Force | Where-Object { $_.Name -like '*.new-*' -or $_.Name -like '*.old-*' }).Count | Should -Be 0
    }

    It 'BREAK-THE-GUARD: a zip-slip entry aborts the expansion and writes NOTHING' {
        # A verified archive can still be hostile in principle -- the entry gate is the second line of defence.
        $z = New-TestZip @{ 'good.txt' = 'fine'; '../evil.txt' = 'pwned' }
        $dest = New-EngineCaseDir
        $r = Expand-LokiVerifiedArchive -ArchivePath $z.Path -DestDir $dest -ExpectedSha256 $z.Hash
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'unsafe-entry'
        # Neither the escaping file nor the innocent sibling was written: validation happens before ANY write.
        Test-Path -LiteralPath (Join-Path (Split-Path -Parent $dest) 'evil.txt') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $dest -Force).Count | Should -Be 0
    }
}

Describe 'Get-LokiVcRuntimeStatus' {

    It 'reports Present when every file is there, and lists what is missing when not' {
        $d = New-EngineCaseDir
        Copy-Item -LiteralPath $script:VersionedSource -Destination (Join-Path $d 'VCRUNTIME140.dll') -Force
        $ok = Get-LokiVcRuntimeStatus -Directory $d -Files @('VCRUNTIME140.dll')
        $ok.Present | Should -BeTrue
        @($ok.Found).Count | Should -Be 1
        @($ok.Found)[0].Version | Should -Not -BeNullOrEmpty

        $bad = Get-LokiVcRuntimeStatus -Directory $d -Files @('VCRUNTIME140.dll', 'MSVCP140.dll')
        $bad.Present | Should -BeFalse
        @($bad.Missing) | Should -Contain 'MSVCP140.dll'
    }
}

Describe 'Get-LokiVcRuntimeFloorCheck (one floor, used by both the staging and the reporting path)' {

    It 'passes a version at or above the floor, refuses one below' {
        $found = @([pscustomobject]@{ File = 'a.dll'; Version = '14.51.36247.0' })
        (Get-LokiVcRuntimeFloorCheck -Found $found -MinVersion '14.30').Ok | Should -BeTrue
        $old = @([pscustomobject]@{ File = 'a.dll'; Version = '14.0.24215.1' })
        $r = Get-LokiVcRuntimeFloorCheck -Found $old -MinVersion '14.30'
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'too-old'
    }

    It 'the WEAKEST file decides -- one ancient dll fails the whole set' {
        $mixed = @(
            [pscustomobject]@{ File = 'new.dll'; Version = '14.51.36247.0' }
            [pscustomobject]@{ File = 'old.dll'; Version = '14.0.24215.1' }
        )
        $r = Get-LokiVcRuntimeFloorCheck -Found $mixed -MinVersion '14.30'
        $r.Ok | Should -BeFalse
        $r.Version | Should -Be '14.0.24215.1'
    }

    It 'refuses an unreadable version and an invalid floor rather than passing them' {
        (Get-LokiVcRuntimeFloorCheck -Found @([pscustomobject]@{ File = 'a.dll'; Version = '' }) -MinVersion '14.30').Reason | Should -Be 'version-unreadable'
        (Get-LokiVcRuntimeFloorCheck -Found @() -MinVersion 'latest').Reason | Should -Be 'min-version-invalid'
        (Get-LokiVcRuntimeFloorCheck -Found @() -MinVersion '14.30').Ok | Should -BeFalse
    }
}

Describe 'Copy-LokiVcRuntimeAppLocal (fail-closed staging)' {

    It 'stages every required file when the source is complete and new enough' {
        $src = New-EngineCaseDir
        Copy-Item -LiteralPath $script:VersionedSource -Destination (Join-Path $src 'VCRUNTIME140.dll') -Force
        $dest = New-EngineCaseDir
        $r = Copy-LokiVcRuntimeAppLocal -SourceDir $src -DestDir $dest -Files @('VCRUNTIME140.dll') -MinVersion '1.0'
        $r.Ok | Should -BeTrue
        $r.Reason | Should -Be 'staged'
        @($r.Staged).Count | Should -Be 1
        Test-Path -LiteralPath (Join-Path $dest 'VCRUNTIME140.dll') | Should -BeTrue
    }

    It 'BREAK-THE-GUARD: refuses and copies NOTHING when a required file is missing at the source' {
        $src = New-EngineCaseDir
        Copy-Item -LiteralPath $script:VersionedSource -Destination (Join-Path $src 'VCRUNTIME140.dll') -Force
        $dest = New-EngineCaseDir
        $r = Copy-LokiVcRuntimeAppLocal -SourceDir $src -DestDir $dest -Files @('VCRUNTIME140.dll', 'MSVCP140.dll') -MinVersion '1.0'
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'source-missing'
        @($r.Missing) | Should -Contain 'MSVCP140.dll'
        # Partial staging is the failure we refuse: the file that WAS present must not have been copied either.
        Test-Path -LiteralPath (Join-Path $dest 'VCRUNTIME140.dll') | Should -BeFalse
    }

    It 'BREAK-THE-GUARD: refuses a runtime older than MinVersion and copies NOTHING' {
        $src = New-EngineCaseDir
        Copy-Item -LiteralPath $script:VersionedSource -Destination (Join-Path $src 'VCRUNTIME140.dll') -Force
        $dest = New-EngineCaseDir
        $r = Copy-LokiVcRuntimeAppLocal -SourceDir $src -DestDir $dest -Files @('VCRUNTIME140.dll') -MinVersion '9999.0'
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'too-old'
        $r.MinVersion | Should -Be '9999.0'
        Test-Path -LiteralPath (Join-Path $dest 'VCRUNTIME140.dll') | Should -BeFalse
    }

    It 'REGRESSION: a failure in the MOVE phase is rolled back -- no mixed set, no leftovers' {
        # The previous version of this test only ever tripped the dest-locked pre-flight, so it stayed green even with
        # the entire staging+move mechanism deleted (proven by mutation in adversarial review). This one drives the
        # move phase itself: the first file lands, the second fails, and the first MUST be put back.
        $src = New-EngineCaseDir
        foreach ($n in @('VCRUNTIME140.dll', 'MSVCP140.dll')) {
            Copy-Item -LiteralPath $script:VersionedSource -Destination (Join-Path $src $n) -Force
        }
        $dest = New-EngineCaseDir
        [System.IO.File]::WriteAllText((Join-Path $dest 'VCRUNTIME140.dll'), 'old-v1', [System.Text.Encoding]::ASCII)
        [System.IO.File]::WriteAllText((Join-Path $dest 'MSVCP140.dll'), 'old-v2', [System.Text.Encoding]::ASCII)

        # Fail only the move that puts a .staging file into place, and only for the second file. Everything else does
        # the real thing via [IO.File] -- NOT by calling back into Move-Item, which would re-enter this mock.
        $script:MoveCount = 0
        Mock Move-Item {
            if ($LiteralPath -like '*.staging') {
                $script:MoveCount++
                if ($script:MoveCount -ge 2) { throw 'simulated move failure' }
            }
            if (Test-Path -LiteralPath $Destination) { [System.IO.File]::Delete($Destination) }
            [System.IO.File]::Move($LiteralPath, $Destination)
        }

        $r = Copy-LokiVcRuntimeAppLocal -SourceDir $src -DestDir $dest -Files @('VCRUNTIME140.dll', 'MSVCP140.dll') -MinVersion '1.0'
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'copy-failed'
        # Both originals are back: the landed file was un-done, not left as half a runtime.
        Get-Content -LiteralPath (Join-Path $dest 'VCRUNTIME140.dll') -Raw -Encoding UTF8 | Should -BeLike 'old-v1*'
        Get-Content -LiteralPath (Join-Path $dest 'MSVCP140.dll') -Raw -Encoding UTF8 | Should -BeLike 'old-v2*'
        @(Get-ChildItem -LiteralPath $dest -Force | Where-Object { $_.Name -like '*.staging' -or $_.Name -like '*.bak' }).Count | Should -Be 0
    }

    It 'REGRESSION: a NON-TERMINATING copy failure is not reported as success, whatever the caller''s $ErrorActionPreference' {
        # Copy-Item/Move-Item failures are non-terminating by DEFAULT, so a catch block only fires if the preference
        # says Stop. The library must not depend on its caller for that: adversarial review proved the whole suite was
        # exercising the fail-OPEN configuration, where these functions returned Ok=$true over files they never wrote.
        # Write-Error here is exactly a non-terminating failure -- the case a locked-file test can never reach,
        # because .NET throws terminating exceptions regardless of the preference.
        $ErrorActionPreference = 'Continue'
        # Build the fixture BEFORE mocking Copy-Item, or the mock eats the fixture too and the function would fail
        # with 'source-missing' -- green for the wrong reason, which is the trap this whole test exists to avoid.
        $src = New-EngineCaseDir
        Copy-Item -LiteralPath $script:VersionedSource -Destination (Join-Path $src 'VCRUNTIME140.dll') -Force
        $dest = New-EngineCaseDir

        Mock Copy-Item { Write-Error 'simulated non-terminating copy failure' }
        $r = Copy-LokiVcRuntimeAppLocal -SourceDir $src -DestDir $dest -Files @('VCRUNTIME140.dll') -MinVersion '1.0'
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'copy-failed'   # pins WHY: it got past the source + floor checks and the copy failed
        Test-Path -LiteralPath (Join-Path $dest 'VCRUNTIME140.dll') | Should -BeFalse
    }

    It 'REGRESSION: a locked destination is refused before anything is copied' {
        # Found by adversarial review, reproduced: file 1 landed, file 2 threw, and the "fail-closed" return left a
        # new VCRUNTIME140 next to a stale MSVCP140 -- exactly the mixed set the module says it refuses.
        # Trigger here is the real one: an existing destination file held open (llama-server running from the stick).
        $src = New-EngineCaseDir
        foreach ($n in @('VCRUNTIME140.dll', 'MSVCP140.dll')) {
            Copy-Item -LiteralPath $script:VersionedSource -Destination (Join-Path $src $n) -Force
        }
        $dest = New-EngineCaseDir
        $locked = Join-Path $dest 'MSVCP140.dll'
        [System.IO.File]::WriteAllText($locked, 'stale', [System.Text.Encoding]::ASCII)
        $hold = [System.IO.File]::Open($locked, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            $r = Copy-LokiVcRuntimeAppLocal -SourceDir $src -DestDir $dest -Files @('VCRUNTIME140.dll', 'MSVCP140.dll') -MinVersion '1.0'
            $r.Ok | Should -BeFalse
            # Nothing new landed, and no .staging leftovers.
            Test-Path -LiteralPath (Join-Path $dest 'VCRUNTIME140.dll') | Should -BeFalse
            @(Get-ChildItem -LiteralPath $dest -Filter '*.staging' -Force).Count | Should -Be 0
        }
        finally { $hold.Close() }
        # Only readable once we drop our own exclusive handle: the stale file must be exactly as it was.
        Get-Content -LiteralPath $locked -Raw -Encoding UTF8 | Should -BeLike 'stale*'
    }

    It 'refuses a source file with no readable version rather than staging it blindly' {
        $src = New-EngineCaseDir
        [System.IO.File]::WriteAllText((Join-Path $src 'VCRUNTIME140.dll'), 'not-a-real-dll', [System.Text.Encoding]::ASCII)
        $dest = New-EngineCaseDir
        $r = Copy-LokiVcRuntimeAppLocal -SourceDir $src -DestDir $dest -Files @('VCRUNTIME140.dll') -MinVersion '1.0'
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'version-unreadable'
        Test-Path -LiteralPath (Join-Path $dest 'VCRUNTIME140.dll') | Should -BeFalse
    }

    It 'rejects an invalid MinVersion instead of silently staging' {
        $src = New-EngineCaseDir
        Copy-Item -LiteralPath $script:VersionedSource -Destination (Join-Path $src 'VCRUNTIME140.dll') -Force
        $r = Copy-LokiVcRuntimeAppLocal -SourceDir $src -DestDir (New-EngineCaseDir) -Files @('VCRUNTIME140.dll') -MinVersion 'latest'
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'min-version-invalid'
    }
}
