# tests/download.Tests.ps1 -- verified file acquisition (security core, CLAUDE.md section 5/6, ADR-0011/ADR-0012).
# Covers lib/download.ps1, the ONE path by which a remote file reaches the stick (models AND the engine binary).
# The key security property under test: a verified download keeps a matching file and DELETES a mismatching or
# interrupted one -- nothing unverified ever survives at the destination. The real network fetch (Get-LokiHttpFile)
# is Mocked; verification runs against real local temp files.
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\download.ps1"

    $script:RootTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("loki-download-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:RootTmp | Out-Null

    # Deterministic known bytes + their real SHA256 (computed, not hardcoded) -- the "good" download.
    $script:GoodBytes = 'loki-verified-bytes-v1'
    $seed = Join-Path $script:RootTmp 'seed.bin'
    [System.IO.File]::WriteAllText($seed, $script:GoodBytes, [System.Text.Encoding]::ASCII)
    $script:GoodHash = (Get-FileHash -LiteralPath $seed -Algorithm SHA256).Hash
    # Measured, not hardcoded -- the pinned SIZE is now enforced alongside the hash (ADR-0026), so every call below
    # must state it exactly like a real manifest entry does.
    $script:GoodSize = [long](Get-Item -LiteralPath $seed).Length

    function global:New-DownloadCaseDir {
        $d = Join-Path $script:RootTmp ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        return $d
    }
}

AfterAll {
    if (Test-Path -LiteralPath $script:RootTmp) { Remove-Item -LiteralPath $script:RootTmp -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item Function:\New-DownloadCaseDir -ErrorAction SilentlyContinue
}

Describe 'Test-LokiFileHash' {

    It 'true for a matching file, false for a wrong hash, false for a missing file' {
        $d = New-DownloadCaseDir
        $f = Join-Path $d 'a.bin'
        [System.IO.File]::WriteAllText($f, $script:GoodBytes, [System.Text.Encoding]::ASCII)
        Test-LokiFileHash -Path $f -ExpectedSha256 $script:GoodHash | Should -BeTrue
        Test-LokiFileHash -Path $f -ExpectedSha256 ('b' * 64) | Should -BeFalse
        Test-LokiFileHash -Path (Join-Path $d 'missing.bin') -ExpectedSha256 $script:GoodHash | Should -BeFalse
    }

    It 'is case-insensitive on the hex' {
        $d = New-DownloadCaseDir
        $f = Join-Path $d 'a.bin'
        [System.IO.File]::WriteAllText($f, $script:GoodBytes, [System.Text.Encoding]::ASCII)
        Test-LokiFileHash -Path $f -ExpectedSha256 ($script:GoodHash.ToLower()) | Should -BeTrue
    }

    It 'BREAK-THE-GUARD: an UNREADABLE file is not a match -- "could not tell" must stay "no" here' {
        # The tri-state below exists so a reporting caller can distinguish these. This test pins the half that must
        # NOT change with it: every acquisition decision in this module rests on Test-LokiFileHash, so the moment
        # unreadable stops being $false, an unverifiable download becomes an accepted one.
        $d = New-DownloadCaseDir
        $f = Join-Path $d 'a.bin'
        [System.IO.File]::WriteAllText($f, $script:GoodBytes, [System.Text.Encoding]::ASCII)
        $hold = [System.IO.File]::Open($f, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        try { Test-LokiFileHash -Path $f -ExpectedSha256 $script:GoodHash | Should -BeFalse }
        finally { $hold.Close() }
        # Sanity: the SAME file passes once the lock is gone, so the assertion above is about readability and not
        # about a fixture that never matched in the first place.
        Test-LokiFileHash -Path $f -ExpectedSha256 $script:GoodHash | Should -BeTrue
    }
}

Describe 'Get-LokiFileHashState (tri-state)' {

    It 'tells the four states apart' {
        $d = New-DownloadCaseDir
        $f = Join-Path $d 'a.bin'
        [System.IO.File]::WriteAllText($f, $script:GoodBytes, [System.Text.Encoding]::ASCII)

        Get-LokiFileHashState -Path $f -ExpectedSha256 $script:GoodHash | Should -Be 'match'
        Get-LokiFileHashState -Path $f -ExpectedSha256 ('b' * 64) | Should -Be 'differ'
        Get-LokiFileHashState -Path (Join-Path $d 'missing.bin') -ExpectedSha256 $script:GoodHash | Should -Be 'missing'

        # The whole point: a file we cannot read is 'unreadable', NOT 'differ'. On a USB stick this is a bad sector or
        # an AV handle far more often than an attacker, and calling it 'differ' is what made lib/integrity.ps1 accuse
        # a failing stick of being tampered with.
        $hold = [System.IO.File]::Open($f, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        try { Get-LokiFileHashState -Path $f -ExpectedSha256 $script:GoodHash | Should -Be 'unreadable' }
        finally { $hold.Close() }
    }

    It 'a directory wearing the file''s name is missing, not unreadable' {
        # Get-FileHash throws on a directory, so the naive try/catch would call this 'unreadable' and send an operator
        # hunting for a hardware fault. There is no file there to read.
        $d = New-DownloadCaseDir
        New-Item -ItemType Directory -Force -Path (Join-Path $d 'a.bin') | Out-Null
        Get-LokiFileHashState -Path (Join-Path $d 'a.bin') -ExpectedSha256 $script:GoodHash | Should -Be 'missing'
    }

    It 'is case-insensitive on the hex, like the bool it backs' {
        $d = New-DownloadCaseDir
        $f = Join-Path $d 'a.bin'
        [System.IO.File]::WriteAllText($f, $script:GoodBytes, [System.Text.Encoding]::ASCII)
        Get-LokiFileHashState -Path $f -ExpectedSha256 ($script:GoodHash.ToLower()) | Should -Be 'match'
    }
}

Describe 'Invoke-LokiVerifiedDownload (integrity gate; network Mocked)' {

    It 'refuses a non-https url without downloading' {
        Mock Get-LokiHttpFile { throw 'must not download for non-https' }
        $d = New-DownloadCaseDir
        $r = Invoke-LokiVerifiedDownload -Url 'http://example.com/m.bin' -ExpectedSha256 $script:GoodHash `
            -ExpectedBytes $script:GoodSize -DestPath (Join-Path $d 'm.bin')
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'not-https'
    }

    It 'downloads + verifies a matching file -> Ok, file present, no .part left' {
        Mock Get-LokiHttpFile { [System.IO.File]::WriteAllText($OutFile, $script:GoodBytes, [System.Text.Encoding]::ASCII) }
        $d = New-DownloadCaseDir
        $dest = Join-Path $d 'm.bin'
        $r = Invoke-LokiVerifiedDownload -Url 'https://example.com/m.bin' -ExpectedSha256 $script:GoodHash -ExpectedBytes $script:GoodSize -DestPath $dest
        $r.Ok | Should -BeTrue
        Test-Path -LiteralPath $dest | Should -BeTrue
        Test-Path -LiteralPath ($dest + '.part') | Should -BeFalse
    }

    It '-StagingDir keeps the .part out of the destination directory, and still commits the file' {
        # engine-offline\ is reconciled against the pinned archive (lib/integrity.ps1), so a .part written there IS a
        # file the archive does not account for. The mock asserts on the .part's location at the moment it exists --
        # after a successful run it is gone either way, which is exactly how this defect stayed invisible.
        $d = New-DownloadCaseDir
        $stage = Join-Path $d 'staging'
        $dest = Join-Path $d 'verified\m.bin'
        $script:SeenPart = $null
        Mock Get-LokiHttpFile {
            $script:SeenPart = $OutFile
            [System.IO.File]::WriteAllText($OutFile, $script:GoodBytes, [System.Text.Encoding]::ASCII)
        }
        $r = Invoke-LokiVerifiedDownload -Url 'https://example.com/m.bin' -ExpectedSha256 $script:GoodHash -ExpectedBytes $script:GoodSize -DestPath $dest -StagingDir $stage
        $r.Ok | Should -BeTrue
        $script:SeenPart | Should -Be (Join-Path $stage 'm.bin.part')
        Test-Path -LiteralPath $dest | Should -BeTrue
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $dest) -Force | ForEach-Object { $_.Name }) | Should -Be @('m.bin')
    }

    It 'a .part abandoned by an earlier run is replaced, not resumed' {
        # A hard interrupt (the case -StagingDir exists for) cannot be simulated by throwing -- a thrown download runs
        # the catch and tidies up, a killed process runs nothing. So this pins the state such a kill LEAVES BEHIND:
        # stale bytes under the .part name. They must be overwritten wholesale; a resume that appended to them would
        # produce a file that fails its pin for a reason nobody could explain.
        $d = New-DownloadCaseDir
        $stage = Join-Path $d 'staging'
        $dest = Join-Path $d 'verified\m.bin'
        New-Item -ItemType Directory -Force -Path $stage | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $stage 'm.bin.part'), 'JUNK-FROM-A-KILLED-RUN', [System.Text.Encoding]::ASCII)
        Mock Get-LokiHttpFile { [System.IO.File]::WriteAllText($OutFile, $script:GoodBytes, [System.Text.Encoding]::ASCII) }
        $r = Invoke-LokiVerifiedDownload -Url 'https://example.com/m.bin' -ExpectedSha256 $script:GoodHash -ExpectedBytes $script:GoodSize -DestPath $dest -StagingDir $stage
        $r.Ok | Should -BeTrue
        $r.Reason | Should -Be 'verified'
        @(Get-ChildItem -LiteralPath $stage -Force).Count | Should -Be 0
    }

    It 'BREAK-THE-GUARD: a tampered download (hash mismatch) is DELETED and never kept' {
        # The payload is deliberately the SAME LENGTH as the pin (ADR-0026 added a size check that now runs first).
        # That keeps this test on the HASH guard where it belongs -- and it is the realistic attack anyway: a swap
        # that changes the length is caught by arithmetic, a length-preserving one only by the hash.
        Mock Get-LokiHttpFile { [System.IO.File]::WriteAllText($OutFile, 'TAMPERED-BYTES-SAMELEN', [System.Text.Encoding]::ASCII) }
        $d = New-DownloadCaseDir
        $dest = Join-Path $d 'm.bin'
        $r = Invoke-LokiVerifiedDownload -Url 'https://example.com/m.bin' -ExpectedSha256 $script:GoodHash -ExpectedBytes $script:GoodSize -DestPath $dest
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'hash-mismatch'
        Test-Path -LiteralPath $dest | Should -BeFalse            # nothing unverified at the destination
        Test-Path -LiteralPath ($dest + '.part') | Should -BeFalse # and no partial left behind
    }

    It 'skips an already-present, already-verified file (no re-download)' {
        Mock Get-LokiHttpFile { throw 'should not be called when already verified' }
        $d = New-DownloadCaseDir
        $dest = Join-Path $d 'm.bin'
        [System.IO.File]::WriteAllText($dest, $script:GoodBytes, [System.Text.Encoding]::ASCII)
        $r = Invoke-LokiVerifiedDownload -Url 'https://example.com/m.bin' -ExpectedSha256 $script:GoodHash -ExpectedBytes $script:GoodSize -DestPath $dest
        $r.Ok | Should -BeTrue
        $r.Skipped | Should -BeTrue
        Should -Invoke Get-LokiHttpFile -Times 0 -Exactly
    }

    It 'REGRESSION: a STALE file already at the destination does not survive a failed download' {
        # The old code only removed the destination on the success path, so a failed download left the stale/tampered
        # file sitting there -- making the module's own "an unverified download is never kept" false. The original test
        # passed only because $dest never pre-existed (adversarial review: vacuous coverage).
        Mock Get-LokiHttpFile { throw 'network down' }
        $d = New-DownloadCaseDir
        $dest = Join-Path $d 'm.bin'
        [System.IO.File]::WriteAllText($dest, 'STALE-ATTACKER-CONTROLLED-BYTES', [System.Text.Encoding]::ASCII)
        $r = Invoke-LokiVerifiedDownload -Url 'https://example.com/m.bin' -ExpectedSha256 $script:GoodHash -ExpectedBytes $script:GoodSize -DestPath $dest
        $r.Ok | Should -BeFalse
        Test-Path -LiteralPath $dest | Should -BeFalse
    }

    It 'REGRESSION: reports FAILURE (not "verified") when the destination cannot actually be replaced' {
        # The worst lie this module could tell. Move-Item's failure is non-terminating, so before the function set
        # $ErrorActionPreference itself, this returned Ok=$true Reason='verified' with the stale bytes still on disk --
        # reproduced by adversarial review, and the same logic already sits on main in the model download path.
        # Runs under 'Continue' on purpose: the guard must not depend on the caller's preference.
        $ErrorActionPreference = 'Continue'
        Mock Get-LokiHttpFile { [System.IO.File]::WriteAllText($OutFile, $script:GoodBytes, [System.Text.Encoding]::ASCII) }
        $d = New-DownloadCaseDir
        $dest = Join-Path $d 'm.bin'
        [System.IO.File]::WriteAllText($dest, 'STALE-UNVERIFIED-BYTES', [System.Text.Encoding]::ASCII)
        $hold = [System.IO.File]::Open($dest, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            $r = Invoke-LokiVerifiedDownload -Url 'https://example.com/m.bin' -ExpectedSha256 $script:GoodHash -ExpectedBytes $script:GoodSize -DestPath $dest
            $r.Ok | Should -BeFalse
            $r.Reason | Should -Be 'dest-locked'
        }
        finally { $hold.Close() }
        # And it did not silently leave the caller believing the stale bytes were the verified ones.
        Get-Content -LiteralPath $dest -Raw -Encoding UTF8 | Should -BeLike 'STALE-UNVERIFIED-BYTES*'
        Test-Path -LiteralPath ($dest + '.part') | Should -BeFalse
    }

    It 'a download error AFTER a partial write -> Ok=$false, the partial is cleaned up' {
        # The mock writes a .part (like a real interrupted transfer) THEN throws, so the catch-block cleanup is
        # actually exercised (not a no-op that would pass even if cleanup were removed).
        Mock Get-LokiHttpFile { [System.IO.File]::WriteAllText($OutFile, 'partial-bytes', [System.Text.Encoding]::ASCII); throw 'network down' }
        $d = New-DownloadCaseDir
        $dest = Join-Path $d 'm.bin'
        $r = Invoke-LokiVerifiedDownload -Url 'https://example.com/m.bin' -ExpectedSha256 $script:GoodHash -ExpectedBytes $script:GoodSize -DestPath $dest
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'download-failed'
        Test-Path -LiteralPath ($dest + '.part') | Should -BeFalse
        Test-Path -LiteralPath $dest | Should -BeFalse
    }

    It 'BREAK-THE-GUARD: a SHORT download is rejected on SIZE, before the hash is computed (ADR-0026)' {
        # A truncated transfer is the half the stream cap cannot see -- the cap only bounds the upper end. The pinned
        # size catches it, and nothing unverified may reach the destination.
        Mock Get-LokiHttpFile { [System.IO.File]::WriteAllText($OutFile, 'short', [System.Text.Encoding]::ASCII) }
        $d = New-DownloadCaseDir
        $dest = Join-Path $d 'm.bin'
        $r = Invoke-LokiVerifiedDownload -Url 'https://example.com/m.bin' -ExpectedSha256 $script:GoodHash `
            -ExpectedBytes $script:GoodSize -DestPath $dest
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'size-mismatch'
        Test-Path -LiteralPath $dest | Should -BeFalse
        Test-Path -LiteralPath ($dest + '.part') | Should -BeFalse
    }

    It 'passes the size pin to the transport as its hard cap (proves the disk-fill guard is actually wired)' {
        # Without this the -MaxBytes argument could be dropped and every other test would stay green: a mock never
        # streams more than it was told to. Assert the transport RECEIVES the pin.
        $script:SeenMax = $null
        Mock Get-LokiHttpFile {
            $script:SeenMax = $MaxBytes
            [System.IO.File]::WriteAllText($OutFile, $script:GoodBytes, [System.Text.Encoding]::ASCII)
        }
        $d = New-DownloadCaseDir
        $dest = Join-Path $d 'm.bin'
        $r = Invoke-LokiVerifiedDownload -Url 'https://example.com/m.bin' -ExpectedSha256 $script:GoodHash `
            -ExpectedBytes $script:GoodSize -DestPath $dest
        $r.Ok | Should -BeTrue
        $script:SeenMax | Should -Be $script:GoodSize
    }

    It 'a non-positive size pin is a broken manifest -> refused without touching the network' {
        Mock Get-LokiHttpFile { throw 'must not download with a broken size pin' }
        $d = New-DownloadCaseDir
        $r = Invoke-LokiVerifiedDownload -Url 'https://example.com/m.bin' -ExpectedSha256 $script:GoodHash `
            -ExpectedBytes 0 -DestPath (Join-Path $d 'm.bin')
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'bad-size-pin'
        Should -Invoke Get-LokiHttpFile -Times 0 -Exactly
    }
}

Describe 'Test-LokiDownloadResponse (pure: may we read this response body at all? ADR-0026)' {

    It 'accepts an https response whose declared length matches the pin' {
        $v = Test-LokiDownloadResponse -ResponseScheme 'https' -DeclaredLength 100 -ExpectedBytes 100
        $v.Ok | Should -BeTrue
        $v.Reason | Should -Be 'ok'
    }

    It 'accepts an https response that declares NO length (-1) -- the stream cap still bounds it' {
        (Test-LokiDownloadResponse -ResponseScheme 'https' -DeclaredLength -1 -ExpectedBytes 100).Ok | Should -BeTrue
    }

    It 'accepts HTTPS in any casing' {
        (Test-LokiDownloadResponse -ResponseScheme 'HTTPS' -DeclaredLength 100 -ExpectedBytes 100).Ok | Should -BeTrue
    }

    It 'BREAK-THE-GUARD: refuses a FINAL scheme that left https: <scheme>' -ForEach @(
        @{ scheme = 'http' }, @{ scheme = 'ftp' }, @{ scheme = '' }
    ) {
        # Measured: both shipped hosts 302 to a CDN, so this is the scheme that actually carries the bytes. Checking
        # only the caller's url was a claim about hop 0.
        $v = Test-LokiDownloadResponse -ResponseScheme $scheme -DeclaredLength 100 -ExpectedBytes 100
        $v.Ok | Should -BeFalse
        $v.Reason | Should -Be 'not-https-final'
    }

    It 'BREAK-THE-GUARD: refuses a declared length that disagrees with the pin, either way: <declared>' -ForEach @(
        @{ declared = 99 }, @{ declared = 101 }, @{ declared = 10000000 }
    ) {
        $v = Test-LokiDownloadResponse -ResponseScheme 'https' -DeclaredLength $declared -ExpectedBytes 100
        $v.Ok | Should -BeFalse
        $v.Reason | Should -Be 'length-mismatch'
    }

    It 'checks the SCHEME before the length -- a downgraded response is reported as a downgrade, not as a size' {
        # The order is the message: "length-mismatch" for an http response sends the operator after the wrong problem.
        (Test-LokiDownloadResponse -ResponseScheme 'http' -DeclaredLength 999 -ExpectedBytes 100).Reason |
            Should -Be 'not-https-final'
    }
}

Describe 'Copy-LokiCappedStream (pure: the disk-fill guard; ADR-0026)' {

    It 'copies a stream that fits and reports the byte count' {
        $src = New-Object System.IO.MemoryStream -ArgumentList (, [byte[]](1..50))
        $dst = New-Object System.IO.MemoryStream
        try {
            Copy-LokiCappedStream -Source $src -Destination $dst -MaxBytes 50 | Should -Be 50
            $dst.Length | Should -Be 50
        }
        finally { $src.Close(); $dst.Close() }
    }

    It 'BREAK-THE-GUARD: THROWS as soon as the source exceeds the cap -- the SHA256 cannot do this job' {
        # A hash is only computable once the whole file is already on disk, so without a cap a hostile or broken
        # server writes until the stick is full and only then gets told its bytes were wrong.
        $src = New-Object System.IO.MemoryStream -ArgumentList (, [byte[]](1..200))
        $dst = New-Object System.IO.MemoryStream
        try { { Copy-LokiCappedStream -Source $src -Destination $dst -MaxBytes 50 } | Should -Throw }
        finally { $src.Close(); $dst.Close() }
    }

    It 'never writes a byte past the cap -- the over-limit bytes never reach the destination' {
        $src = New-Object System.IO.MemoryStream -ArgumentList (, [byte[]](1..200))
        $dst = New-Object System.IO.MemoryStream
        try {
            $threw = $false
            try { [void](Copy-LokiCappedStream -Source $src -Destination $dst -MaxBytes 50) } catch { $threw = $true }
            $threw | Should -BeTrue -Because 'the cap must ABORT, not silently truncate to the limit'
            $dst.Length | Should -BeLessOrEqual 50
        }
        finally { $src.Close(); $dst.Close() }
    }

    It 'rejects a non-positive cap rather than copying unbounded' {
        $src = New-Object System.IO.MemoryStream -ArgumentList (, [byte[]](1..10))
        $dst = New-Object System.IO.MemoryStream
        try { { Copy-LokiCappedStream -Source $src -Destination $dst -MaxBytes 0 } | Should -Throw }
        finally { $src.Close(); $dst.Close() }
    }
}
