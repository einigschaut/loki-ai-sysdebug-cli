# tests/update-loki.Tests.ps1 -- the pure judgements inside build/Update-Loki.ps1.
#
# The script guards its body with `if ($MyInvocation.InvocationName -ne '.')`, so dot-sourcing it
# here exposes the pure functions WITHOUT running the network orchestration (verified: dot-source
# sets InvocationName to '.'). The impure half (download, gh attestation verify, expand) is not
# reachable without a real release and is deliberately not mocked here -- it is kept thin precisely
# because it cannot be unit-tested; everything that decides an outcome lives in the pure functions
# below and IS tested, including the fail-closed refusals (CLAUDE.md 6: break every guard once).
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\build\Update-Loki.ps1"
}

Describe 'Get-LokiUpdateExpectedHash (read the checksum sidecar, fail-closed)' {
    It 'reads the human-readable sidecar the release workflow writes' {
        # CONTRACT: this fixture mirrors, line for line, what .github/workflows/release-please.yml
        # writes into loki-<tag>.zip.sha256. If that workflow's format changes, this is the test that
        # should be updated alongside it (producer + consumer move together).
        $sidecar = @"
sha256:  e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
bytes:   573842
file:    loki-v0.14.0.zip
verify:  gh attestation verify loki-v0.14.0.zip -R einigschaut/loki-ai-sysdebug-cli
"@
        Get-LokiUpdateExpectedHash -SidecarText $sidecar | Should -Be 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
    }
    It 'also reads a plain sha256sum-style sidecar (digest then filename)' {
        Get-LokiUpdateExpectedHash -SidecarText '5d41402abc4b2a76b9719d911017c592abc4b2a76b9719d911017c592abcdef0  loki-v0.14.0.zip' |
            Should -Be '5d41402abc4b2a76b9719d911017c592abc4b2a76b9719d911017c592abcdef0'
    }
    It 'lower-cases the digest so the later comparison is spelling-agnostic' {
        Get-LokiUpdateExpectedHash -SidecarText ('sha256:  ' + ('ABCDEF01' * 8)) | Should -Be ('abcdef01' * 8)
    }
    It 'BREAK-THE-GUARD: throws when there is NO hash rather than proceeding unverified' {
        { Get-LokiUpdateExpectedHash -SidecarText 'file: loki.zip (no digest here)' } | Should -Throw '*SHA256*'
    }
    It 'BREAK-THE-GUARD: an almost-hash (63 hex) is not accepted as one' {
        { Get-LokiUpdateExpectedHash -SidecarText ('a' * 63) } | Should -Throw
    }
}

Describe 'Test-LokiHashMatch (ordinal, case-insensitive)' {
    It 'matches identical digests regardless of case' {
        Test-LokiHashMatch -Expected ('abc123' * 10 + 'abcd') -Actual ('ABC123' * 10 + 'ABCD') | Should -BeTrue
    }
    It 'BREAK-THE-GUARD: a one-character difference does NOT match' {
        $a = 'a' * 64
        $b = ('a' * 63) + 'b'
        Test-LokiHashMatch -Expected $a -Actual $b | Should -BeFalse
    }
    It 'an empty side never matches (a missing hash is not a pass)' {
        Test-LokiHashMatch -Expected '' -Actual ('a' * 64) | Should -BeFalse
        Test-LokiHashMatch -Expected ('a' * 64) -Actual '' | Should -BeFalse
    }
}

Describe 'Resolve-LokiUpdateTarget (expand BESIDE, never over the running tree)' {
    It 'places the new tree in a loki-<tag> sibling under the destination' {
        $plan = Resolve-LokiUpdateTarget -Destination 'C:\tools' -Tag 'v0.14.0' -RepoRoot 'C:\tools\loki-ai-sysdebug-cli'
        $plan.TargetDir   | Should -Be 'C:\tools\loki-v0.14.0'
        $plan.ArchiveName | Should -Be 'loki-v0.14.0.zip'
    }
    It 'BREAK-THE-GUARD: refuses when the target equals the running checkout' {
        { Resolve-LokiUpdateTarget -Destination 'C:\tools' -Tag 'v0.14.0' -RepoRoot 'C:\tools\loki-v0.14.0' } |
            Should -Throw '*running checkout*'
    }
    It 'BREAK-THE-GUARD: refuses when the target would sit inside the running checkout' {
        # A destination under the checkout (e.g. someone points it at the repo's own build\ dir):
        # target C:\repo\build\loki-v1 sits inside C:\repo -> refuse.
        { Resolve-LokiUpdateTarget -Destination 'C:\repo\build' -Tag 'v1' -RepoRoot 'C:\repo' } |
            Should -Throw '*running checkout*'
    }
    It 'BREAK-THE-GUARD: refuses when the running checkout sits inside the target' {
        # Destination is an ancestor and the checkout happens to live under the new tree's name:
        # target C:\a\loki-v0.14.0 contains the running C:\a\loki-v0.14.0\inner -> refuse.
        { Resolve-LokiUpdateTarget -Destination 'C:\a' -Tag 'v0.14.0' -RepoRoot 'C:\a\loki-v0.14.0\inner' } |
            Should -Throw '*running checkout*'
    }
    It 'does NOT treat a name-prefix sibling as nested (loki vs loki-v0.14.0)' {
        # The trailing-separator guard: 'C:\p\loki\' is not a prefix of 'C:\p\loki-v0.14.0\', so a
        # checkout named plain "loki" does not block a v0.14.0 sibling next to it.
        $plan = Resolve-LokiUpdateTarget -Destination 'C:\p' -Tag 'v0.14.0' -RepoRoot 'C:\p\loki'
        $plan.TargetDir | Should -Be 'C:\p\loki-v0.14.0'
    }
}
