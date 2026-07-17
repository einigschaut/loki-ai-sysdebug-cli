# build/module-versions.psd1 -- the EXACT versions of the dev tools every gate runs on (data only;
# Import-PowerShellDataFile). ASCII -> no BOM.
#
# ONE source of truth (CLAUDE.md section 2 + section 9): .github/workflows/ci.yml installs exactly these versions and
# build/Invoke-Checks.ps1 imports exactly these versions. Neither writes a version number of its own, and
# tests/module-pin.Tests.ps1 goes red if one starts to.
#
# Why an EXACT version and not a floor: a floor is not a decision. Until this file existed, the gate that decides
# "red = no merge" installed with `-MinimumVersion 5.5.0` and imported with `-MinimumVersion 5.0.0` -- two different
# floors, no ceiling, in three places. So when Pester 6.0.0 shipped, CI silently moved a MAJOR version while the
# workflow step was still named "Install modules (Pester 5 ...)" and the maintainer's own machine kept running 5.6.1.
# Nobody decided that, and nobody could see it. Measured 2026-07-17, both green on 989 tests and therefore invisible:
#
#   CI    Pester 6.0.0   PSScriptAnalyzer 1.25.0
#   local Pester 5.6.1   PSScriptAnalyzer 1.22.0
#
# A gate is only worth its red when everyone runs the same one. An exact pin makes an upgrade a PR with a green CI
# behind it instead of a side effect of PSGallery publishing.
#
# To bump: change the version here, install it locally, run build\Invoke-Checks.ps1, open a PR. The PR is the
# decision; its CI run is the evidence. There is no second place to keep in sync.
@{
    # Pester 6 supports the runtime that actually ships: its manifest declares PowerShellVersion 5.1, and the full
    # suite is green on it under Windows PowerShell 5.1 (989 tests) -- both checked, not assumed (CLAUDE.md section 1).
    Pester           = '6.0.0'
    PSScriptAnalyzer = '1.25.0'
}
