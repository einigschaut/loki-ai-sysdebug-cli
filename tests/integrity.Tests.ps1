# tests/integrity.Tests.ps1 -- load-time verification of the offline engine + models (security core,
# CLAUDE.md section 5/6, ADR-0014). The engine is CODE the target executes, so the properties under test are the
# adversarial ones, not the happy path:
#   * a tampered expanded FILE is caught even though the archive still matches the pin (BREAK-THE-GUARD) -- this is
#     the whole reason the check hashes files against archive entries instead of just re-checking the archive.
#   * a PLANTED file that is in no archive is caught (BREAK-THE-GUARD) -- the hole hashes structurally cannot see.
#   * a runtime staged app-local but too old FAILS even when the host's is fine (it shadows the host).
#   * "we verified nothing" never renders as "nothing is wrong".
# Real zips + real files on disk, no mocks: the thing under test IS the filesystem interaction.
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\exitcodes.ps1"   # Get-LokiIntegrityExitCode maps onto the central definition
    . "$PSScriptRoot\..\src\lib\download.ps1"    # Test-LokiFileHash -- the primitive the chain is built on
    . "$PSScriptRoot\..\src\lib\engine.ps1"      # layout, entry gate, expected set, runtime status/floor
    . "$PSScriptRoot\..\src\lib\models.ps1"      # Get-LokiModelLayout
    . "$PSScriptRoot\..\src\lib\integrity.ps1"
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $script:RootTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("loki-integrity-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:RootTmp | Out-Null

    function global:New-IntegrityCaseDir {
        $d = Join-Path $script:RootTmp ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        return $d
    }

    # Builds an AppRoot laid out like the real stick: engine-offline\ holding the archive + its expanded contents.
    # $Entries is name -> content. Returns @{ AppRoot; Layout; Engine }.
    function global:New-EngineStick {
        param([hashtable]$Entries, [switch]$SkipExpand)
        $appRoot = New-IntegrityCaseDir
        $dir = Join-Path $appRoot 'engine-offline'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null

        $zipPath = Join-Path (New-IntegrityCaseDir) 'engine.zip'
        $zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
        foreach ($k in $Entries.Keys) {
            $e = $zip.CreateEntry([string]$k)
            $sw = New-Object System.IO.StreamWriter($e.Open())
            $sw.Write([string]$Entries[$k])
            $sw.Dispose()
        }
        $zip.Dispose()

        $engine = @{
            FileName  = 'engine.zip'
            ServerExe = 'llama-server.exe'
            Sha256    = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
            Version   = 'b10038'
        }
        Copy-Item -LiteralPath $zipPath -Destination (Join-Path $dir 'engine.zip') -Force
        if (-not $SkipExpand) {
            foreach ($k in $Entries.Keys) {
                $target = Join-Path $dir ([string]$k -replace '/', '\')
                $parent = Split-Path -Parent $target
                if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
                [System.IO.File]::WriteAllText($target, [string]$Entries[$k])
            }
        }
        return @{
            AppRoot = $appRoot
            Layout  = (Get-LokiEngineLayout -AppRoot $appRoot -Engine $engine)
            Engine  = $engine
        }
    }
}

AfterAll {
    if (Test-Path -LiteralPath $script:RootTmp) { Remove-Item -LiteralPath $script:RootTmp -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item Function:\New-IntegrityCaseDir -ErrorAction SilentlyContinue
    Remove-Item Function:\New-EngineStick -ErrorAction SilentlyContinue
}

Describe 'Get-LokiEngineExpectedSet (pure; the ONE definition shared by expand and verify)' {

    It 'contains the archive contents, the archive itself and the preserved runtime' {
        $s = Get-LokiEngineExpectedSet -EntryNames @('llama-server.exe', 'ggml-base.dll') `
            -ArchiveFileName 'engine.zip' -PreserveNames @('MSVCP140.dll')
        $s.Contains('llama-server.exe') | Should -BeTrue
        $s.Contains('ggml-base.dll') | Should -BeTrue
        $s.Contains('engine.zip') | Should -BeTrue
        $s.Contains('MSVCP140.dll') | Should -BeTrue
        $s.Count | Should -Be 4
    }

    It 'is a HashSet, not an unrolled array (regression: return $set would unroll and .Contains would vanish)' {
        $s = Get-LokiEngineExpectedSet -EntryNames @('a.dll') -ArchiveFileName 'e.zip'
        $s.GetType().Name | Should -BeLike 'HashSet*'
    }

    It 'compares case-insensitively, because Windows paths do' {
        $s = Get-LokiEngineExpectedSet -EntryNames @('GGML-Base.DLL') -ArchiveFileName 'engine.zip'
        $s.Contains('ggml-base.dll') | Should -BeTrue
    }

    It 'normalizes the zip separator to the Windows one' {
        $s = Get-LokiEngineExpectedSet -EntryNames @('sub/dir/a.dll') -ArchiveFileName 'e.zip'
        $s.Contains('sub\dir\a.dll') | Should -BeTrue
    }

    It 'a directory entry produces no expected FILE' {
        $s = Get-LokiEngineExpectedSet -EntryNames @('sub/', 'sub/a.dll') -ArchiveFileName 'e.zip'
        $s.Contains('sub') | Should -BeFalse
        $s.Contains('sub\a.dll') | Should -BeTrue
    }

    It 'ignores blank preserve names rather than expecting a file called ""' {
        $s = Get-LokiEngineExpectedSet -EntryNames @('a.dll') -ArchiveFileName 'e.zip' -PreserveNames @('', '  ')
        $s.Count | Should -Be 2
    }
}

Describe 'Test-LokiEngineIntegrity' {

    It 'verifies a stick that setup produced' {
        $s = New-EngineStick -Entries @{ 'llama-server.exe' = 'MZ-server'; 'ggml-base.dll' = 'dll-bytes' }
        $r = Test-LokiEngineIntegrity -Layout $s.Layout -Engine $s.Engine
        $r.Ok | Should -BeTrue
        $r.Reason | Should -Be 'verified'
        $r.Checked | Should -Be 2
    }

    It 'BREAK-THE-GUARD: a TAMPERED expanded file is caught although the archive still matches its pin' {
        # The reason this whole function exists. Verifying only the archive would report Ok here -- the archive is
        # untouched. The bytes Windows would actually load are not.
        $s = New-EngineStick -Entries @{ 'llama-server.exe' = 'MZ-server'; 'ggml-base.dll' = 'dll-bytes' }
        [System.IO.File]::WriteAllText((Join-Path $s.Layout.Dir 'llama-server.exe'), 'MZ-EVIL')

        # Precondition: the archive itself is still pristine, so this is genuinely the file check firing.
        (Test-LokiFileHash -Path $s.Layout.ArchivePath -ExpectedSha256 $s.Engine.Sha256) | Should -BeTrue

        $r = Test-LokiEngineIntegrity -Layout $s.Layout -Engine $s.Engine
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'file-mismatch'
        $r.Mismatched | Should -Contain 'llama-server.exe'
    }

    It 'BREAK-THE-GUARD: a PLANTED dll the archive does not contain is caught (hashes cannot see it)' {
        # ADR-0012 section 2b at load time: ggml-base.dll picks CPU variants BY NAME out of this very directory.
        $s = New-EngineStick -Entries @{ 'llama-server.exe' = 'MZ-server' }
        [System.IO.File]::WriteAllText((Join-Path $s.Layout.Dir 'ggml-cpu-haswell.dll'), 'PLANTED')
        $r = Test-LokiEngineIntegrity -Layout $s.Layout -Engine $s.Engine
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'unexpected-file'
        $r.Unexpected | Should -Contain 'ggml-cpu-haswell.dll'
    }

    It 'finds a planted file in a SUBDIRECTORY too' {
        $s = New-EngineStick -Entries @{ 'llama-server.exe' = 'MZ-server' }
        $sub = Join-Path $s.Layout.Dir 'sub'
        New-Item -ItemType Directory -Force -Path $sub | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $sub 'evil.dll'), 'PLANTED')
        $r = Test-LokiEngineIntegrity -Layout $s.Layout -Engine $s.Engine
        $r.Reason | Should -Be 'unexpected-file'
        $r.Unexpected | Should -Contain 'sub\evil.dll'
    }

    It 'BREAK-THE-GUARD: a directory JUNCTION hiding a plant is reported (enumeration stops at reparse points)' {
        # Adversarial review: `mklink /J` needs no admin, and Get-ChildItem -Recurse does NOT descend into a
        # junction under PS 5.1 -- so a plant behind one was invisible and the stick reported `verified`.
        $s = New-EngineStick -Entries @{ 'llama-server.exe' = 'MZ-server' }
        $outside = New-IntegrityCaseDir
        [System.IO.File]::WriteAllText((Join-Path $outside 'ggml-cpu-haswell.dll'), 'PLANTED')
        $link = Join-Path $s.Layout.Dir 'stash'
        & "$env:SystemRoot\System32\cmd.exe" /c mklink /J "$link" "$outside" | Out-Null
        if (-not (Test-Path -LiteralPath $link)) { Set-ItResult -Skipped -Because 'the junction could not be created' }

        # Precondition: the plant really is reachable through the stick, so this proves the reconcile, not the setup.
        (Test-Path -LiteralPath (Join-Path $link 'ggml-cpu-haswell.dll')) | Should -BeTrue

        $r = Test-LokiEngineIntegrity -Layout $s.Layout -Engine $s.Engine
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'unexpected-file'
        $r.Unexpected | Should -Contain 'stash'
    }

    It 'a plain (non-reparse) subdirectory holding only expected files is not itself an anomaly' {
        # Guards the fix above from over-firing: directories as such must not be flagged, or a future pinned archive
        # with subdirectories would report every honest stick as tampered.
        $s = New-EngineStick -Entries @{ 'llama-server.exe' = 'MZ-server'; 'sub/a.dll' = 'a-bytes' }
        $r = Test-LokiEngineIntegrity -Layout $s.Layout -Engine $s.Engine
        $r.Ok | Should -BeTrue
    }

    It 'a hidden planted file is still a planted file' {
        $s = New-EngineStick -Entries @{ 'llama-server.exe' = 'MZ-server' }
        $p = Join-Path $s.Layout.Dir 'quiet.dll'
        [System.IO.File]::WriteAllText($p, 'PLANTED')
        (Get-Item -LiteralPath $p).Attributes = 'Hidden'
        $r = Test-LokiEngineIntegrity -Layout $s.Layout -Engine $s.Engine
        $r.Reason | Should -Be 'unexpected-file'
    }

    It 'does NOT flag the verified archive itself (it is the chain back to the pin)' {
        $s = New-EngineStick -Entries @{ 'llama-server.exe' = 'MZ-server' }
        $r = Test-LokiEngineIntegrity -Layout $s.Layout -Engine $s.Engine
        $r.Ok | Should -BeTrue
    }

    It 'does NOT flag the operator-staged Microsoft runtime when it is passed as -PreserveNames' {
        $s = New-EngineStick -Entries @{ 'llama-server.exe' = 'MZ-server' }
        [System.IO.File]::WriteAllText((Join-Path $s.Layout.Dir 'VCRUNTIME140.dll'), 'ms-runtime')
        (Test-LokiEngineIntegrity -Layout $s.Layout -Engine $s.Engine).Reason | Should -Be 'unexpected-file'
        $r = Test-LokiEngineIntegrity -Layout $s.Layout -Engine $s.Engine -PreserveNames @('VCRUNTIME140.dll')
        $r.Ok | Should -BeTrue
    }

    It 'a MISSING file from the pinned build is reported' {
        $s = New-EngineStick -Entries @{ 'llama-server.exe' = 'MZ-server'; 'ggml-base.dll' = 'dll-bytes' }
        [System.IO.File]::Delete((Join-Path $s.Layout.Dir 'ggml-base.dll'))
        $r = Test-LokiEngineIntegrity -Layout $s.Layout -Engine $s.Engine
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'file-missing'
        $r.Missing | Should -Contain 'ggml-base.dll'
    }

    It 'an archive that does not match the pin is refused BEFORE it is opened' {
        $s = New-EngineStick -Entries @{ 'llama-server.exe' = 'MZ-server' }
        $bad = $s.Engine.Clone()
        $bad.Sha256 = '0' * 64
        $r = Test-LokiEngineIntegrity -Layout $s.Layout -Engine $bad
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'archive-mismatch'
    }

    It 'a missing archive is a failure, not a pass: without it nothing can be established' {
        $s = New-EngineStick -Entries @{ 'llama-server.exe' = 'MZ-server' }
        [System.IO.File]::Delete($s.Layout.ArchivePath)
        (Test-LokiEngineIntegrity -Layout $s.Layout -Engine $s.Engine).Reason | Should -Be 'archive-missing'
    }

    It 'a stick with no engine at all says so (distinct from a broken one)' {
        $appRoot = New-IntegrityCaseDir
        $engine = @{ FileName = 'engine.zip'; ServerExe = 'llama-server.exe'; Sha256 = '0' * 64; Version = 'b1' }
        $layout = Get-LokiEngineLayout -AppRoot $appRoot -Engine $engine
        (Test-LokiEngineIntegrity -Layout $layout -Engine $engine).Reason | Should -Be 'engine-not-installed'
    }

    It 'an archive with no file entries is "nothing-verified", never a silent pass' {
        $s = New-EngineStick -Entries @{}
        $r = Test-LokiEngineIntegrity -Layout $s.Layout -Engine $s.Engine
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'nothing-verified'
    }

    It 'writes nothing to the stick it is inspecting (a checker you can run on a stick you distrust)' {
        $s = New-EngineStick -Entries @{ 'llama-server.exe' = 'MZ-server'; 'ggml-base.dll' = 'dll-bytes' }
        # Measured before/after, not "we mocked the writer and it was not called" -- that proves the mock, not the code.
        # Directories are included by PATH (a stray staging dir is a write too), but NOT by timestamp: NTFS updates
        # directory mtimes lazily, so an unflushed `before` reading can "change" on its own and fail a test that
        # nothing actually wrote to. Files are compared by size AND mtime, which is where the property lives.
        $snapshot = {
            @(Get-ChildItem -LiteralPath $s.AppRoot -Recurse -Force | ForEach-Object {
                    if ($_.PSIsContainer) { '{0}|dir' -f $_.FullName }
                    else { '{0}|{1}|{2}' -f $_.FullName, $_.Length, $_.LastWriteTimeUtc.Ticks }
                }) -join "`n"
        }
        $before = & $snapshot
        Test-LokiEngineIntegrity -Layout $s.Layout -Engine $s.Engine | Out-Null
        $after = & $snapshot
        $after | Should -Be $before
    }

    It 'BREAK-THE-GUARD: a directory that cannot be ENUMERATED is never reported as verified' {
        # ADR-0012 section 4b, the sharpest lesson of that slice, now guarded here: Get-ChildItem's failures are
        # NON-TERMINATING by default, so without the function-scoped $ErrorActionPreference='Stop' the catch never
        # fires and a directory we could not read is reported as having no unexpected files -- Ok=$true over a tree
        # that could be hiding anything. A locked-file test canNOT cover this (.NET throws terminating regardless);
        # only a genuinely non-terminating failure does, which is what Write-Error produces.
        $s = New-EngineStick -Entries @{ 'llama-server.exe' = 'MZ-server' }
        Mock Get-ChildItem { Write-Error 'Access to the path is denied.' }
        $r = Test-LokiEngineIntegrity -Layout $s.Layout -Engine $s.Engine
        Should -Invoke Get-ChildItem -Times 1 -Exactly   # sanity: the mock really fired, so this is not vacuous
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'verify-failed'
    }

    It 'BREAK-THE-GUARD: the verify-side zip-slip gate refuses a hostile entry name' {
        # A hash-verified archive can still carry a hostile name, and we are about to Join-Path it onto a real
        # directory. Verified != safe to interpret.
        $s = New-EngineStick -Entries @{ '../evil.dll' = 'payload' } -SkipExpand
        $r = Test-LokiEngineIntegrity -Layout $s.Layout -Engine $s.Engine
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'unsafe-entry'
        $r.Entry | Should -Be '../evil.dll'
    }

    It 'releases the archive: a verify must not lock the file setup needs to replace' {
        $s = New-EngineStick -Entries @{ 'llama-server.exe' = 'MZ-server' }
        Test-LokiEngineIntegrity -Layout $s.Layout -Engine $s.Engine | Out-Null
        { [System.IO.File]::Delete($s.Layout.ArchivePath) } | Should -Not -Throw
    }
}

Describe 'Test-LokiModelIntegrity' {

    It 'verifies a model against its pin' {
        $d = New-IntegrityCaseDir
        [System.IO.File]::WriteAllText((Join-Path $d 'nano.gguf'), 'weights')
        $entry = @{ Id = 'nano'; FileName = 'nano.gguf'
            Sha256 = (Get-FileHash -LiteralPath (Join-Path $d 'nano.gguf') -Algorithm SHA256).Hash
        }
        $r = Test-LokiModelIntegrity -Entry $entry -ModelsDir $d
        $r.Ok | Should -BeTrue
        $r.Reason | Should -Be 'verified'
        $r.Id | Should -Be 'nano'
    }

    It 'BREAK-THE-GUARD: a swapped model is refused' {
        $d = New-IntegrityCaseDir
        $p = Join-Path $d 'nano.gguf'
        [System.IO.File]::WriteAllText($p, 'weights')
        $entry = @{ Id = 'nano'; FileName = 'nano.gguf'; Sha256 = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash }
        [System.IO.File]::WriteAllText($p, 'EVIL-weights')
        $r = Test-LokiModelIntegrity -Entry $entry -ModelsDir $d
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'mismatch'
    }

    It 'an absent tier is "not-installed", not a failure (setup lets you pick a subset)' {
        $entry = @{ Id = 'max'; FileName = 'max.gguf'; Sha256 = '0' * 64 }
        $r = Test-LokiModelIntegrity -Entry $entry -ModelsDir (New-IntegrityCaseDir)
        $r.Reason | Should -Be 'not-installed'
    }

    It 'BREAK-THE-GUARD: a model whose presence cannot even be determined is never verified' {
        # The same non-terminating fail-open as the engine side: without the function-scoped preference, a
        # Test-Path that errors is swallowed and the model sails through.
        $d = New-IntegrityCaseDir
        [System.IO.File]::WriteAllText((Join-Path $d 'nano.gguf'), 'weights')
        $entry = @{ Id = 'nano'; FileName = 'nano.gguf'
            Sha256 = (Get-FileHash -LiteralPath (Join-Path $d 'nano.gguf') -Algorithm SHA256).Hash
        }
        Mock Test-Path { Write-Error 'Access to the path is denied.' }
        { Test-LokiModelIntegrity -Entry $entry -ModelsDir $d } | Should -Throw
        Should -Invoke Test-Path -Times 1 -Exactly
    }
}

Describe 'Test-LokiMicrosoftSignature (the ONLY check available for the staged MSVC runtime)' {

    BeforeAll {
        # The real runtime DLLs are embedded-Authenticode signed, so a copy keeps a valid signature. Verified rather
        # than assumed: if this machine lacks them the tests below Skip rather than pass silently.
        $script:RealRuntime = Join-Path $env:SystemRoot 'System32\VCRUNTIME140.dll'
        $script:HaveRuntime = Test-Path -LiteralPath $script:RealRuntime
    }

    It 'a genuine Microsoft binary passes, and still passes after being copied to the stick' -Skip:(-not (Test-Path (Join-Path $env:SystemRoot 'System32\VCRUNTIME140.dll'))) {
        $d = New-IntegrityCaseDir
        $copy = Join-Path $d 'VCRUNTIME140.dll'
        Copy-Item -LiteralPath $script:RealRuntime -Destination $copy -Force
        $r = Test-LokiMicrosoftSignature -Path $copy
        $r.Ok | Should -BeTrue
        $r.Reason | Should -Be 'ok'
    }

    It 'BREAK-THE-GUARD: patched bytes are caught although the version resource still reads fine' -Skip:(-not (Test-Path (Join-Path $env:SystemRoot 'System32\VCRUNTIME140.dll'))) {
        # This is the exact attack an adversarial review landed: 64 bytes of code replaced, version untouched, and
        # the old version-only check reported the engine as verified with exit 0.
        $d = New-IntegrityCaseDir
        $copy = Join-Path $d 'VCRUNTIME140.dll'
        Copy-Item -LiteralPath $script:RealRuntime -Destination $copy -Force
        $bytes = [System.IO.File]::ReadAllBytes($copy)
        for ($i = 0; $i -lt 64; $i++) { $bytes[0x1200 + $i] = 0x90 }
        [System.IO.File]::WriteAllBytes($copy, $bytes)

        # The metadata the floor check reads is STILL intact -- that is the whole point.
        [string](Get-Item -LiteralPath $copy).VersionInfo.FileVersion | Should -Not -BeNullOrEmpty

        $r = Test-LokiMicrosoftSignature -Path $copy
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'hash-mismatch'
    }

    It 'BREAK-THE-GUARD: a real, valid PE that is simply NOT signed is refused' -Skip:(-not (Test-Path (Join-Path $env:SystemRoot 'System32\VCRUNTIME140.dll'))) {
        # A genuine PE with its certificate-table entry zeroed: structurally valid, just unsigned. This is the
        # attacker's other option once patching is caught -- ship your own DLL rather than tamper with Microsoft's.
        $d = New-IntegrityCaseDir
        $p = Join-Path $d 'VCRUNTIME140.dll'
        Copy-Item -LiteralPath $script:RealRuntime -Destination $p -Force
        $b = [System.IO.File]::ReadAllBytes($p)
        $pe = [BitConverter]::ToInt32($b, 0x3C)
        $magic = [BitConverter]::ToUInt16($b, $pe + 24)
        $dd = if ($magic -eq 0x20b) { $pe + 24 + 112 } else { $pe + 24 + 96 }   # PE32+ vs PE32 data-directory offset
        $certOff = $dd + 4 * 8                                                   # directory entry 4 = certificate table
        for ($i = 0; $i -lt 8; $i++) { $b[$certOff + $i] = 0 }
        [System.IO.File]::WriteAllBytes($p, $b)

        $r = Test-LokiMicrosoftSignature -Path $p
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'not-signed'
    }

    It 'BREAK-THE-GUARD: a genuine DLL in a path containing [brackets] is not accused of being forged' -Skip:(-not (Test-Path (Join-Path $env:SystemRoot 'System32\VCRUNTIME140.dll'))) {
        # Adversarial review: Get-AuthenticodeSignature -FilePath is WILDCARD-expanding, and [ ] are legal Windows
        # filename characters. A stick in 'loki [backup]' made this report three real Microsoft DLLs as unverifiable
        # -- exit 1, "do not trust this stick", on a perfectly honest stick.
        $d = Join-Path $script:RootTmp ('loki [backup] ' + [System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        $p = Join-Path $d 'VCRUNTIME140.dll'
        Copy-Item -LiteralPath $script:RealRuntime -Destination $p -Force
        $r = Test-LokiMicrosoftSignature -Path $p
        $r.Ok | Should -BeTrue
        $r.Reason | Should -Be 'ok'
    }

    It 'BREAK-THE-GUARD: a VALIDLY signed binary from a non-Microsoft publisher is refused' {
        # The one that makes pinning the root necessary rather than decorative: Status='Valid' only means "signed by
        # someone this machine trusts", which any attacker holding a public code-signing certificate also achieves.
        # So we need a real file that is genuinely Valid but not Microsoft's -- found on the host rather than
        # hardcoded, and skipped honestly when the host has none.
        $victim = $null
        foreach ($dir in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
            if ($victim -or (-not $dir) -or (-not (Test-Path -LiteralPath $dir))) { continue }
            foreach ($f in @(Get-ChildItem -LiteralPath $dir -Recurse -Include *.dll, *.exe -File -ErrorAction SilentlyContinue | Select-Object -First 400)) {
                $s = $null
                try { $s = Get-AuthenticodeSignature -LiteralPath $f.FullName -ErrorAction Stop } catch { continue }
                if (($s.Status -ne 'Valid') -or ($null -eq $s.SignerCertificate)) { continue }
                if ([string]$s.SignerCertificate.Subject -match 'O=Microsoft Corporation') { continue }
                $victim = $f.FullName
                break
            }
        }
        if (-not $victim) { Set-ItResult -Skipped -Because 'this host has no validly signed non-Microsoft binary to test with' }

        # Precondition: Windows really does consider it Valid -- otherwise this proves nothing about the root pin.
        (Get-AuthenticodeSignature -LiteralPath $victim).Status | Should -Be 'Valid'

        $r = Test-LokiMicrosoftSignature -Path $victim
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'not-microsoft-signed'
    }

    It 'a file that is not a PE at all is refused (fail-closed, whatever Windows makes of it)' {
        # Windows reports UnknownError rather than NotSigned for a non-PE; the token differs, the refusal must not.
        $d = New-IntegrityCaseDir
        $p = Join-Path $d 'VCRUNTIME140.dll'
        [System.IO.File]::WriteAllText($p, 'not-a-signed-pe')
        (Test-LokiMicrosoftSignature -Path $p).Ok | Should -BeFalse
    }

    It 'never throws on a file that is not there' {
        { Test-LokiMicrosoftSignature -Path (Join-Path (New-IntegrityCaseDir) 'gone.dll') } | Should -Not -Throw
        (Test-LokiMicrosoftSignature -Path (Join-Path (New-IntegrityCaseDir) 'gone.dll')).Ok | Should -BeFalse
    }
}

Describe 'Get-LokiVcRuntimeHostStatus' {

    It 'a key that does not exist -> not-installed (never a throw)' {
        $r = Get-LokiVcRuntimeHostStatus -RegistryKey 'HKLM:\SOFTWARE\Loki\DoesNotExist\Ever' -MinVersion '14.30'
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'not-installed'
    }

    It 'a key outside the one documented hive is refused rather than hunted for' {
        (Get-LokiVcRuntimeHostStatus -RegistryKey 'HKCU:\SOFTWARE\X' -MinVersion '14.30').Reason | Should -Be 'registry-key-invalid'
        (Get-LokiVcRuntimeHostStatus -RegistryKey 'nonsense' -MinVersion '14.30').Reason | Should -Be 'registry-key-invalid'
    }

    It 'never throws whatever it is handed' {
        { Get-LokiVcRuntimeHostStatus -RegistryKey 'HKLM:\' -MinVersion 'not-a-version' } | Should -Not -Throw
    }
}

Describe 'Resolve-LokiVcRuntimeAvailability' {

    BeforeAll {
        # kernel32.dll is a real, versioned Windows binary that exists on every host -> the version logic is
        # deterministic here instead of depending on whatever VC++ runtime the CI machine happens to have.
        $script:Versioned = Join-Path $env:SystemRoot 'System32\kernel32.dll'
        $script:RealVersion = [string](Get-Item -LiteralPath $script:Versioned).VersionInfo.FileVersion
    }

    It 'app-local runtime at/above the floor -> ok, sourced app-local' {
        $d = New-IntegrityCaseDir
        Copy-Item -LiteralPath $script:Versioned -Destination (Join-Path $d 'VCRUNTIME140.dll') -Force
        $r = Resolve-LokiVcRuntimeAvailability -Directory $d -Files @('VCRUNTIME140.dll') -MinVersion '1.0' `
            -RegistryKey 'HKLM:\SOFTWARE\Loki\DoesNotExist'
        $r.Ok | Should -BeTrue
        $r.Source | Should -Be 'app-local'
    }

    It 'BREAK-THE-GUARD: a too-old app-local runtime FAILS even though the host leg is genuinely OK' {
        # The counter-intuitive one, and the reason this function exists: the exe directory is searched FIRST, so the
        # good system runtime is never reached. A fallback here would be a bug, not a kindness.
        #
        # This test was VACUOUS in review and the way it failed is worth keeping: it used -MinVersion 9999.0, which
        # made the HOST leg unsatisfiable too. Adding the exact forbidden fallback changed nothing, because there was
        # no good host runtime to fall back TO -- and the host leg's Reason under that floor was 'too-old', the very
        # token being asserted. So: mock the host probe to be genuinely OK, and use kernel32's real 10.0.x version
        # against a 14.30 floor so the app-local leg is genuinely below it on any Windows host.
        Mock Get-LokiVcRuntimeHostStatus { @{ Ok = $true; Reason = 'ok'; Version = '14.44' } }
        $d = New-IntegrityCaseDir
        Copy-Item -LiteralPath $script:Versioned -Destination (Join-Path $d 'VCRUNTIME140.dll') -Force

        # Precondition: the host really WOULD have been fine. Without this the test proves nothing again.
        (Get-LokiVcRuntimeHostStatus -RegistryKey 'HKLM:\SOFTWARE\Whatever' -MinVersion '14.30').Ok | Should -BeTrue

        $r = Resolve-LokiVcRuntimeAvailability -Directory $d -Files @('VCRUNTIME140.dll') -MinVersion '14.30' `
            -RegistryKey 'HKLM:\SOFTWARE\Whatever'
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'too-old'
        $r.Source | Should -Be 'app-local'   # the discriminator: a fallback would have made this 'host'
    }

    It 'BREAK-THE-GUARD: a staged runtime with patched bytes is refused (the review attack, end to end)' -Skip:(-not (Test-Path (Join-Path $env:SystemRoot 'System32\VCRUNTIME140.dll'))) {
        # Adversarial review: -PreserveNames spares these from the reconcile and nothing hashed them, so patched
        # bytes in the first DLL on llama-server's search path reported runtime=ok/app-local, exit 0.
        $d = New-IntegrityCaseDir
        $p = Join-Path $d 'VCRUNTIME140.dll'
        Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\VCRUNTIME140.dll') -Destination $p -Force
        $bytes = [System.IO.File]::ReadAllBytes($p)
        for ($i = 0; $i -lt 64; $i++) { $bytes[0x1200 + $i] = 0x90 }
        [System.IO.File]::WriteAllBytes($p, $bytes)

        $r = Resolve-LokiVcRuntimeAvailability -Directory $d -Files @('VCRUNTIME140.dll') -MinVersion '14.30' `
            -RegistryKey 'HKLM:\SOFTWARE\Loki\DoesNotExist'
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'hash-mismatch'
        $r.Source | Should -Be 'app-local'
    }

    It 'a PARTIALLY staged set is diagnosed, not silently mixed with the host' {
        $d = New-IntegrityCaseDir
        Copy-Item -LiteralPath $script:Versioned -Destination (Join-Path $d 'VCRUNTIME140.dll') -Force
        $r = Resolve-LokiVcRuntimeAvailability -Directory $d -Files @('VCRUNTIME140.dll', 'MSVCP140.dll') `
            -MinVersion '1.0' -RegistryKey 'HKLM:\SOFTWARE\Loki\DoesNotExist'
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'partially-staged'
        $r.Missing | Should -Contain 'MSVCP140.dll'
    }

    It 'nothing staged -> the host decides, and an absent host runtime is not-installed' {
        $r = Resolve-LokiVcRuntimeAvailability -Directory (New-IntegrityCaseDir) -Files @('VCRUNTIME140.dll') `
            -MinVersion '14.30' -RegistryKey 'HKLM:\SOFTWARE\Loki\DoesNotExist'
        $r.Ok | Should -BeFalse
        $r.Source | Should -Be 'host'
        $r.Reason | Should -Be 'not-installed'
    }
}

Describe 'Get-LokiIntegrityExitCode (pure; 1 = the stick is WRONG, 5 = the stick is INCOMPLETE)' {

    BeforeAll {
        function global:New-ExitReport {
            param([string]$EngineReason = 'verified', [bool]$RuntimeOk = $true, [string[]]$ModelReasons = @('verified'),
                [string]$RuntimeReason)
            $models = @()
            foreach ($m in $ModelReasons) { $models += @{ Ok = ($m -eq 'verified'); Reason = $m; Id = 't' } }
            if (-not $PSBoundParameters.ContainsKey('RuntimeReason')) {
                $RuntimeReason = if ($RuntimeOk) { 'ok' } else { 'not-installed' }
            }
            return @{
                Engine = @{ Ok = ($EngineReason -eq 'verified'); Reason = $EngineReason }
                Runtime = @{ Ok = $RuntimeOk; Reason = $RuntimeReason; Source = 'host' }
                Models = $models; EngineVersion = 'b1'; MinVersion = '14.30'
            }
        }
    }
    AfterAll { Remove-Item Function:\New-ExitReport -ErrorAction SilentlyContinue }

    It 'engine <engineReason> / runtimeOk <runtimeOk> / models <modelReasons> -> <expected>' -ForEach @(
        # Usable.
        @{ engineReason = 'verified'; runtimeOk = $true; modelReasons = @('verified'); expected = 0 }
        # An absent tier is normal -- setup lets you take a subset.
        @{ engineReason = 'verified'; runtimeOk = $true; modelReasons = @('not-installed'); expected = 0 }
        # INCOMPLETE: nothing suspicious, just not set up. Must never read as tampering.
        @{ engineReason = 'engine-not-installed'; runtimeOk = $true; modelReasons = @('not-installed'); expected = 5 }
        @{ engineReason = 'verified'; runtimeOk = $false; modelReasons = @('verified'); expected = 5 }
        # WRONG: bytes do not match the pin.
        @{ engineReason = 'archive-mismatch'; runtimeOk = $true; modelReasons = @('verified'); expected = 1 }
        @{ engineReason = 'file-mismatch'; runtimeOk = $true; modelReasons = @('verified'); expected = 1 }
        @{ engineReason = 'unexpected-file'; runtimeOk = $true; modelReasons = @('verified'); expected = 1 }
        @{ engineReason = 'file-missing'; runtimeOk = $true; modelReasons = @('verified'); expected = 1 }
        @{ engineReason = 'archive-missing'; runtimeOk = $true; modelReasons = @('verified'); expected = 1 }
        @{ engineReason = 'unsafe-entry'; runtimeOk = $true; modelReasons = @('verified'); expected = 1 }
        @{ engineReason = 'nothing-verified'; runtimeOk = $true; modelReasons = @('verified'); expected = 1 }
        @{ engineReason = 'verify-failed'; runtimeOk = $true; modelReasons = @('verified'); expected = 1 }
        # A swapped model is a "do not trust this stick" on its own.
        @{ engineReason = 'verified'; runtimeOk = $true; modelReasons = @('mismatch'); expected = 1 }
        @{ engineReason = 'verified'; runtimeOk = $true; modelReasons = @('verified', 'mismatch'); expected = 1 }
        # WRONG beats INCOMPLETE: if anything does not match its pin, that is the answer.
        @{ engineReason = 'file-mismatch'; runtimeOk = $false; modelReasons = @('mismatch'); expected = 1 }
        @{ engineReason = 'engine-not-installed'; runtimeOk = $false; modelReasons = @('mismatch'); expected = 1 }
    ) {
        $r = New-ExitReport -EngineReason $engineReason -RuntimeOk $runtimeOk -ModelReasons $modelReasons
        Get-LokiIntegrityExitCode -Report $r | Should -Be $expected
    }

    It 'an unknown engine reason is treated as WRONG, never as fine (fail-closed on a token we do not know)' {
        Get-LokiIntegrityExitCode -Report (New-ExitReport -EngineReason 'some-future-reason') | Should -Be 1
    }

    # The runtime is the one input that lands in BOTH buckets, so it gets its own table. A staged DLL that fails its
    # signature is loaded code that is not what it claims to be -> WRONG(1). Absent/stale/half-staged is a stick that
    # is merely not ready -> INCOMPLETE(5). Filing a patched DLL under "not set up yet" is exactly the cry-wolf
    # inversion this split exists to prevent.
    It 'runtime reason <reason> -> <expected>' -ForEach @(
        @{ reason = 'hash-mismatch'; expected = 1 }
        @{ reason = 'not-signed'; expected = 1 }
        @{ reason = 'not-microsoft-signed'; expected = 1 }
        @{ reason = 'signature-invalid'; expected = 1 }
        # NOT 1: 'could not determine' is not 'forged'. Reporting "do not trust this stick" because a signature was
        # unreadable is the mirror of the lie ADR-0014 section 4 forbids. It still cannot reach 0.
        @{ reason = 'signature-unreadable'; expected = 5 }
        @{ reason = 'not-installed'; expected = 5 }
        @{ reason = 'too-old'; expected = 5 }
        @{ reason = 'partially-staged'; expected = 5 }
        @{ reason = 'registry-unreadable'; expected = 5 }
    ) {
        $r = New-ExitReport -RuntimeOk $false -RuntimeReason $reason
        Get-LokiIntegrityExitCode -Report $r | Should -Be $expected
    }
}

Describe 'ConvertTo-LokiIntegrityChecks (pure)' {

    BeforeAll {
        function global:New-Report {
            param($Engine, $Runtime, $Models)
            return @{ Engine = $Engine; Runtime = $Runtime; Models = @($Models)
                EngineVersion = 'b10038'; MinVersion = '14.30'
            }
        }
        $script:OkRuntime = @{ Ok = $true; Reason = 'ok'; Source = 'host'; Version = '14.44' }
        $script:OkModels = @(@{ Ok = $true; Reason = 'verified'; Id = 'nano' })
    }

    AfterAll { Remove-Item Function:\New-Report -ErrorAction SilentlyContinue }

    It 'a fully verified stick has no failing check' {
        $rep = New-Report -Engine @{ Ok = $true; Reason = 'verified'; Checked = 51 } -Runtime $script:OkRuntime -Models $script:OkModels
        $checks = ConvertTo-LokiIntegrityChecks -Report $rep
        @($checks | Where-Object { $_.Severity -eq 'fail' }).Count | Should -Be 0
    }

    It 'engine reason <reason> -> severity <severity>' -ForEach @(
        @{ reason = 'verified'; severity = 'ok' }
        @{ reason = 'engine-not-installed'; severity = 'warn' }
        @{ reason = 'archive-missing'; severity = 'fail' }
        @{ reason = 'archive-mismatch'; severity = 'fail' }
        @{ reason = 'file-mismatch'; severity = 'fail' }
        @{ reason = 'unexpected-file'; severity = 'fail' }
        @{ reason = 'file-missing'; severity = 'fail' }
        @{ reason = 'unsafe-entry'; severity = 'fail' }
        @{ reason = 'nothing-verified'; severity = 'fail' }
        @{ reason = 'verify-failed'; severity = 'fail' }
    ) {
        $e = @{ Ok = ($reason -eq 'verified'); Reason = $reason; Checked = 1
            Mismatched = @('a.dll'); Unexpected = @('b.dll'); Missing = @('c.dll')
        }
        $checks = ConvertTo-LokiIntegrityChecks -Report (New-Report -Engine $e -Runtime $script:OkRuntime -Models $script:OkModels)
        $engineCheck = @($checks | Where-Object { $_.Id -eq 'engine' })[0]
        $engineCheck.Severity | Should -Be $severity
    }

    # NOTE on the shape of these three: the checks are ASSIGNED first and filtered afterwards, never piped straight
    # out of the function. ConvertTo-LokiIntegrityChecks returns `, $array` (the house convention, same as
    # ConvertTo-LokiDoctorChecks), so piping it hands Where-Object the whole array as ONE item; `$_.Id -eq 'runtime'`
    # then member-enumerates and returns a non-empty -> truthy -> the filter passes EVERYTHING through and the test
    # asserts against the wrong object. Found the hard way; keep the assignment.
    It 'a missing runtime is a FAILURE when an engine is installed that needs it' {
        $rep = New-Report -Engine @{ Ok = $true; Reason = 'verified'; Checked = 1 } `
            -Runtime @{ Ok = $false; Reason = 'not-installed'; Source = 'host' } -Models $script:OkModels
        $checks = ConvertTo-LokiIntegrityChecks -Report $rep
        $c = @($checks | Where-Object { $_.Id -eq 'runtime' })[0]
        $c.Severity | Should -Be 'fail'
    }

    It 'but only a warning when there is no engine to need it' {
        $rep = New-Report -Engine @{ Ok = $false; Reason = 'engine-not-installed' } `
            -Runtime @{ Ok = $false; Reason = 'not-installed'; Source = 'host' } -Models $script:OkModels
        $checks = ConvertTo-LokiIntegrityChecks -Report $rep
        $c = @($checks | Where-Object { $_.Id -eq 'runtime' })[0]
        $c.Severity | Should -Be 'warn'
    }

    It 'an undeterminable runtime is "unknown" -- never a clean OK' {
        $rep = New-Report -Engine @{ Ok = $true; Reason = 'verified'; Checked = 1 } `
            -Runtime @{ Ok = $false; Reason = 'registry-unreadable'; Source = 'host' } -Models $script:OkModels
        $checks = ConvertTo-LokiIntegrityChecks -Report $rep
        $c = @($checks | Where-Object { $_.Id -eq 'runtime' })[0]
        $c.Severity | Should -Be 'unknown'
    }

    It 'absent tiers are not listed one by one, but a mismatched one always is' {
        $models = @(
            @{ Ok = $false; Reason = 'not-installed'; Id = 'max' }
            @{ Ok = $false; Reason = 'mismatch'; Id = 'mid' }
            @{ Ok = $true; Reason = 'verified'; Id = 'nano' }
        )
        $checks = ConvertTo-LokiIntegrityChecks -Report (New-Report -Engine @{ Ok = $true; Reason = 'verified'; Checked = 1 } -Runtime $script:OkRuntime -Models $models)
        @($checks | Where-Object { $_.Id -eq 'model:max' }).Count | Should -Be 0
        @($checks | Where-Object { $_.Id -eq 'model:mid' })[0].Severity | Should -Be 'fail'
        @($checks | Where-Object { $_.Id -eq 'model:nano' })[0].Severity | Should -Be 'ok'
    }

    It 'a stick with no tiers says so once' {
        $models = @(@{ Ok = $false; Reason = 'not-installed'; Id = 'nano' })
        $checks = ConvertTo-LokiIntegrityChecks -Report (New-Report -Engine @{ Ok = $true; Reason = 'verified'; Checked = 1 } -Runtime $script:OkRuntime -Models $models)
        $c = @($checks | Where-Object { $_.Id -eq 'models' })[0]
        $c.Severity | Should -Be 'warn'
        $c.DetailKey | Should -Be 'integrity.model.noneInstalled'
    }

    It 'every emitted check carries the keys doctor.ps1 renders (StrictMode would throw on a missing one)' {
        $rep = New-Report -Engine @{ Ok = $true; Reason = 'verified'; Checked = 1 } -Runtime $script:OkRuntime -Models $script:OkModels
        foreach ($c in ConvertTo-LokiIntegrityChecks -Report $rep) {
            foreach ($k in @('Id', 'Severity', 'LabelKey', 'DetailKey', 'DetailArgs', 'DetailRaw')) {
                $c.ContainsKey($k) | Should -BeTrue
            }
        }
    }
}
