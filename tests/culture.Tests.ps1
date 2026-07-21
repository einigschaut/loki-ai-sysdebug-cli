# tests/culture.Tests.ps1 -- the classification gate must not depend on the machine's LOCALE.
#
# The bug this exists for (found by adversarial review, 2026-07-16): PowerShell's -match / -notmatch fold case using
# the CURRENT CULTURE. In tr-TR / az-Latn the regex engine folds 'I' to the dotless 'i' (U+0131), which is NOT in
# [A-Za-z]. So '^Get-[A-Za-z][A-Za-z0-9]*$' stopped matching 'Get-ChildItem' / 'Get-CimInstance' / 'Get-Item' on a
# Turkish host: Loki's own read-only diagnostics were classified 'mutate' and denied on the very machine it was
# brought to diagnose. lib/allowlist.ps1 now carries BOTH copies of this pattern -- Get-LokiCommandClass (the pure
# classifier) and Resolve-LokiCommandDecision (whose copy decides whether the ADR-0006 runtime Cmdlet check runs at
# all) -- so fixing only one would leave a hijacking Function named Get-ChildItem classified 'read'. Both use
# [regex]::IsMatch(..., 'IgnoreCase,CultureInvariant').
#
# WHY A CHILD PROCESS, and why this file exists at all instead of a few extra rows in allowlist.Tests.ps1:
# the culture must be set BEFORE the pattern is first compiled. PowerShell caches compiled regexes by
# pattern+options and NOT by culture, so flipping the culture inside a process that has already run the pattern
# yields a FALSE PASS -- the test would go green against the broken code. Each case therefore runs in its own
# powershell.exe with the culture set at the top, before anything dot-sources the libs.
Set-StrictMode -Version Latest

BeforeAll {
    # LOCAL variables, deliberately: GetNewClosure() below captures the LOCAL scope, not $script: -- a closure that
    # reads $script:Tmp gets $null and every case dies on a null Join-Path. (Same Pester-5 scope trap as the helper in
    # tests/footprint.Tests.ps1.) $script:Tmp is kept only so AfterAll can clean up.
    $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $libDir = (Resolve-Path "$PSScriptRoot\..\src\lib").Path
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("loki-culture-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $script:Tmp = $tmp

    # Runs $Body in a FRESH PS 5.1 process under $Culture and returns its trimmed stdout.
    $script:InCulture = {
        param([string]$Culture, [string]$Body)
        $file = Join-Path $tmp ([System.Guid]::NewGuid().ToString('N') + '.ps1')
        $content = @"
param([string]`$Culture)
[System.Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo(`$Culture)
[Globalization.CultureInfo]::DefaultThreadCurrentCulture = [Globalization.CultureInfo]::GetCultureInfo(`$Culture)
Set-StrictMode -Version Latest
. '$libDir\auth.ps1'
. '$libDir\allowlist.ps1'
$Body
"@
        [System.IO.File]::WriteAllText($file, $content, (New-Object System.Text.UTF8Encoding($false)))
        $out = & $ps51 -NoProfile -File $file -Culture $Culture 2>&1 | Out-String
        return $out.Trim()
    }.GetNewClosure()
}

AfterAll {
    if (Test-Path -LiteralPath $script:Tmp) { Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Locale independence of the command classifier (tr-TR dotless-i)' {

    # en-US is the control: if a case ever fails HERE the test is broken, not the locale handling.
    It 'Get-LokiCommandClass classifies <cmd> as read under <culture>' -ForEach @(
        @{ culture = 'en-US'; cmd = 'Get-ChildItem C:\' }
        @{ culture = 'en-US'; cmd = 'Get-CimInstance Win32_BIOS' }
        @{ culture = 'en-US'; cmd = 'Get-Item C:\x' }
        @{ culture = 'en-US'; cmd = 'Get-Process' }
        # The regression: every one of these was 'mutate' on a Turkish host. Get-Process is the control that always
        # worked (no letter I in the name) -- if IT ever fails, something much more basic broke.
        @{ culture = 'tr-TR'; cmd = 'Get-ChildItem C:\' }
        @{ culture = 'tr-TR'; cmd = 'Get-CimInstance Win32_BIOS' }
        @{ culture = 'tr-TR'; cmd = 'Get-Item C:\x' }
        @{ culture = 'tr-TR'; cmd = 'Get-Process' }
    ) {
        $out = & $script:InCulture $culture "Write-Output (Get-LokiCommandClass -CommandLine '$cmd')"
        $out | Should -Be 'read'
    }

    It 'Resolve-LokiCommandDecision keeps <cmd> read under <culture> (the ADR-0006 runtime check still runs)' -ForEach @(
        @{ culture = 'en-US'; cmd = 'Get-ChildItem C:\' }
        @{ culture = 'tr-TR'; cmd = 'Get-ChildItem C:\' }
        @{ culture = 'tr-TR'; cmd = 'Get-CimInstance Win32_BIOS' }
    ) {
        $out = & $script:InCulture $culture "Write-Output ((Resolve-LokiCommandDecision -CommandLine '$cmd').Reason)"
        $out | Should -Be 'read-allowlisted'
    }

    It 'the lowercase spelling still works under <culture> (-cmatch would have broken this)' -ForEach @(
        @{ culture = 'en-US' }
        @{ culture = 'tr-TR' }
    ) {
        # PowerShell command names ARE case-insensitive, so 'get-childitem' is a legal invocation. This is why the fix
        # is CultureInvariant rather than a case-SENSITIVE match: -cmatch fixes the locale bug by breaking this.
        $out = & $script:InCulture $culture "Write-Output (Get-LokiCommandClass -CommandLine 'get-childitem C:\')"
        $out | Should -Be 'read'
    }

    It 'a hijacking non-cmdlet named Get-* is still downgraded under tr-TR (the guard is not skipped)' {
        # The security half: if the pattern stops matching, the runtime Cmdlet verification never runs and a
        # hijacking Function keeps 'read'. Define a Function named Get-ChildItem in the child process and prove the
        # downgrade still fires under the Turkish locale.
        $body = @'
function Get-ChildItem { 'hijacked' }
Write-Output ((Resolve-LokiCommandDecision -CommandLine 'Get-ChildItem C:\').Reason)
'@
        $out = & $script:InCulture 'tr-TR' $body
        $out | Should -Be 'read-downgraded-noncmdlet'
    }

    It 'the deny list still fires under tr-TR' {
        $out = & $script:InCulture 'tr-TR' "Write-Output (Get-LokiCommandClass -CommandLine 'Get-Content x | iex')"
        $out | Should -Be 'denied'
    }
}
