# tests/module-pin.Tests.ps1 -- a version pin is only a decision if something enforces it. This is that something.
# ASCII -> no BOM (CLAUDE.md section 1).
Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot   = (Resolve-Path "$PSScriptRoot\..").Path
    $script:PinPath    = Join-Path $script:RepoRoot 'build\module-versions.psd1'
    $script:Pins       = Import-PowerShellDataFile -LiteralPath $script:PinPath
    $script:CiPath     = Join-Path $script:RepoRoot '.github\workflows\ci.yml'
    $script:ChecksPath = Join-Path $script:RepoRoot 'build\Invoke-Checks.ps1'

    # The tools build/Invoke-Checks.ps1 imports. Importing a third one without pinning it is exactly the drift these
    # tests exist to catch, so the list is stated here rather than derived from the pin file (which would agree with
    # itself no matter what it contained).
    $script:Tools = @('Pester', 'PSScriptAnalyzer')

    # A version literal spelled out next to Install-Module / Import-Module. Deliberately also catches one written in
    # a comment: the history of these versions belongs in build/module-versions.psd1, which is the one file a reader
    # should have to open to learn what the gate runs on. (It caught the ci.yml comment on its first run, which is
    # how this rule earned its keep.)
    $script:VersionLiteral = '-(Minimum|Required|Maximum)Version\s+["'']?\d'

    # Any quoted x.y.z, flag or no flag -- an inlined `@{ Pester = '6.0.0' }` restates the pin without ever writing
    # one of the words above. Applied only to ci.yml: Invoke-Checks.ps1 legitimately quotes non-version strings, and
    # a rule that fires on those would train people to work around it.
    $script:QuotedSemver = '["'']\d+\.\d+\.\d+["'']'
}

Describe 'dev-tool version pin' {

    Context 'the pin file' {

        It 'pins a version for every tool the gate imports' {
            foreach ($name in $script:Tools) {
                $script:Pins.ContainsKey($name) | Should -BeTrue -Because "build/Invoke-Checks.ps1 imports $name"
            }
        }

        It 'pins an exact version, never a range' {
            # '6.0' or '6.*' would float again and give back the problem the pin was written to remove.
            foreach ($name in $script:Tools) {
                ([string]$script:Pins[$name]) | Should -Match '^\d+\.\d+\.\d+$'
            }
        }
    }

    Context 'the gate actually runs on the pinned version' {

        It 'is running the pinned Pester at this very moment' {
            # The assertion the whole pin exists for, and the one thing here that cannot be faked: inside a Pester
            # run, Get-Module Pester IS the module executing this test. If CI ever installs a version the pin does
            # not name -- which is precisely how Pester 6 arrived unannounced -- this line is what says so.
            $loaded = @(Get-Module Pester)
            $loaded.Count | Should -Be 1
            $loaded[0].Version.ToString() | Should -Be ([string]$script:Pins.Pester)
        }

        It 'has the pinned PSScriptAnalyzer installed' {
            # -ListAvailable rather than Get-Module, measured: PSScriptAnalyzer is only imported when the suite runs
            # through build/Invoke-Checks.ps1, and Get-Module returns nothing for it under a bare Invoke-Pester. A
            # test that fails depending on how it was launched is worse than a slightly weaker one. Invoke-Checks
            # imports it with -RequiredVersion, so "this exact version is installed" is what makes it the one used.
            $found = @(Get-Module -ListAvailable PSScriptAnalyzer |
                        Where-Object { $_.Version.ToString() -eq [string]$script:Pins.PSScriptAnalyzer })
            $found.Count | Should -BeGreaterThan 0
        }
    }

    Context 'nothing else states a version' {
        # One source of truth stays single only while it is the ONLY place a number lives.

        It 'ci.yml loads the pin file' {
            # The CALL, not a mention: a first cut asserted only that 'module-versions.psd1' appeared somewhere in
            # the file, and a mutation that replaced the load with an inline hashtable sailed through -- the string
            # was still there, in the comment explaining the load. A test a comment can satisfy tests nothing.
            $loads = @(Get-Content -LiteralPath $script:CiPath |
                        Where-Object { $_ -match 'Import-PowerShellDataFile.*module-versions\.psd1' })
            $loads.Count | Should -BeGreaterThan 0
        }

        It 'ci.yml writes no module version of its own' {
            $bad = @(Get-Content -LiteralPath $script:CiPath | Where-Object { $_ -match $script:VersionLiteral })
            $bad.Count | Should -Be 0 -Because "these lines belong in build/module-versions.psd1: $($bad -join ' | ')"
        }

        It 'ci.yml spells out no version literal at all' {
            # Wider than the -...Version check above, because the inline-hashtable mutation carried no flag to catch:
            # `$pins = @{ Pester = '6.0.0' }` restates the pin just as thoroughly, and agrees with it right up until
            # the day someone bumps one of the two.
            $bad = @(Get-Content -LiteralPath $script:CiPath | Where-Object { $_ -match $script:QuotedSemver })
            $bad.Count | Should -Be 0 -Because "these lines belong in build/module-versions.psd1: $($bad -join ' | ')"
        }

        It 'Invoke-Checks.ps1 loads the pin file' {
            $loads = @(Get-Content -LiteralPath $script:ChecksPath |
                        Where-Object { $_ -match 'Import-PowerShellDataFile.*module-versions\.psd1' })
            $loads.Count | Should -BeGreaterThan 0
        }

        It 'Invoke-Checks.ps1 writes no module version of its own' {
            $bad = @(Get-Content -LiteralPath $script:ChecksPath | Where-Object { $_ -match $script:VersionLiteral })
            $bad.Count | Should -Be 0 -Because "these lines belong in build/module-versions.psd1: $($bad -join ' | ')"
        }

        It 'Invoke-Checks.ps1 imports every tool from the loaded pin file' {
            # Loading the pin file and then not using it at a call site is drift the file-level checks cannot see:
            # `-Pins @{ Pester = '5.6.1' }` reads nothing and looks fine. The suite would still catch it -- the tests
            # would be running on a Pester the pin does not name -- but only after CI burned a full run to say so.
            #
            # -notmatch '^\s*#' is load-bearing and was measured, not foreseen: without it a commented-out import
            # still counts as an import, so the count stayed right while the gate imported one tool fewer. The two
            # checks above deliberately DO read comments -- a restated version is wrong wherever it is written -- but
            # a test that claims to count call sites has to count call sites.
            $calls = @(Get-Content -LiteralPath $script:ChecksPath |
                        Where-Object { $_ -notmatch '^\s*#' -and $_ -match 'Import-RequiredModule\s+-Name' })
            $calls.Count | Should -Be $script:Tools.Count
            foreach ($call in $calls) { $call | Should -Match '-Pins\s+\$pins\s*$' }
        }
    }
}
