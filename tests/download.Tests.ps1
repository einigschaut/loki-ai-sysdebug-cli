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
}

Describe 'Invoke-LokiVerifiedDownload (integrity gate; network Mocked)' {

    It 'refuses a non-https url without downloading' {
        Mock Get-LokiHttpFile { throw 'must not download for non-https' }
        $d = New-DownloadCaseDir
        $r = Invoke-LokiVerifiedDownload -Url 'http://example.com/m.bin' -ExpectedSha256 $script:GoodHash -DestPath (Join-Path $d 'm.bin')
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'not-https'
    }

    It 'downloads + verifies a matching file -> Ok, file present, no .part left' {
        Mock Get-LokiHttpFile { [System.IO.File]::WriteAllText($OutFile, $script:GoodBytes, [System.Text.Encoding]::ASCII) }
        $d = New-DownloadCaseDir
        $dest = Join-Path $d 'm.bin'
        $r = Invoke-LokiVerifiedDownload -Url 'https://example.com/m.bin' -ExpectedSha256 $script:GoodHash -DestPath $dest
        $r.Ok | Should -BeTrue
        Test-Path -LiteralPath $dest | Should -BeTrue
        Test-Path -LiteralPath ($dest + '.part') | Should -BeFalse
    }

    It 'BREAK-THE-GUARD: a tampered download (hash mismatch) is DELETED and never kept' {
        Mock Get-LokiHttpFile { [System.IO.File]::WriteAllText($OutFile, 'TAMPERED-BYTES', [System.Text.Encoding]::ASCII) }
        $d = New-DownloadCaseDir
        $dest = Join-Path $d 'm.bin'
        $r = Invoke-LokiVerifiedDownload -Url 'https://example.com/m.bin' -ExpectedSha256 $script:GoodHash -DestPath $dest
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
        $r = Invoke-LokiVerifiedDownload -Url 'https://example.com/m.bin' -ExpectedSha256 $script:GoodHash -DestPath $dest
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
        $r = Invoke-LokiVerifiedDownload -Url 'https://example.com/m.bin' -ExpectedSha256 $script:GoodHash -DestPath $dest
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
            $r = Invoke-LokiVerifiedDownload -Url 'https://example.com/m.bin' -ExpectedSha256 $script:GoodHash -DestPath $dest
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
        $r = Invoke-LokiVerifiedDownload -Url 'https://example.com/m.bin' -ExpectedSha256 $script:GoodHash -DestPath $dest
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'download-failed'
        Test-Path -LiteralPath ($dest + '.part') | Should -BeFalse
        Test-Path -LiteralPath $dest | Should -BeFalse
    }
}
