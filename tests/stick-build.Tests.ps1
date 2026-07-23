# tests/stick-build.Tests.ps1 -- the deployed artifact: src\loki.cmd (the entry point) and build\New-LokiStick.ps1
# (the build script). DESIGN.md section 2 specified both and neither existed, so a stick was assembled by hand --
# and the first hand-assembly stripped a UTF-8 BOM off an i18n catalog. These tests pin the two properties that
# matter most: the build moves BYTES (no BOM loss), and it cannot destroy what `loki setup` and the operator put
# on the stick (multi-GB models, the credential in home\.env).
Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path
    $script:SrcDir = Join-Path $script:RepoRoot 'src'
    $script:Builder = Join-Path $script:RepoRoot 'build\New-LokiStick.ps1'
    $script:Shim = Join-Path $script:SrcDir 'loki.cmd'
    $script:RootTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("loki-stick-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:RootTmp | Out-Null

    # Runs a native command and returns { Output; ExitCode } WITHOUT letting its stderr become a terminating error.
    # The CI runner sets $ErrorActionPreference='Stop', and under Stop a native process writing to stderr through
    # `2>&1` throws -- so these tests passed standalone and failed in the gate. stderr goes to a FILE (not the
    # success stream) and Stop is lifted only around the call; both halves are needed.
    function global:Invoke-LokiNative {
        param([Parameter(Mandatory = $true)][string]$Exe, [string[]]$Arguments = @())
        $errFile = [System.IO.Path]::GetTempFileName()
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $stdout = & $Exe @Arguments 2>$errFile | Out-String
            $code = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $prevEap }
        $stderr = ''
        if (Test-Path -LiteralPath $errFile) {
            $stderr = (Get-Content -Raw -LiteralPath $errFile -ErrorAction SilentlyContinue)
            Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
        }
        return @{ Output = ([string]$stdout + [string]$stderr); ExitCode = $code }
    }

    # Builds into a fresh directory and returns its path. The builder runs in its own 5.1 process, exactly as an
    # operator invokes it -- an in-process dot-source would not exercise the param block or the exit code.
    function global:New-TestStick {
        param([switch]$Prune, [string]$Into)
        if ([string]::IsNullOrEmpty($Into)) {
            $Into = Join-Path $script:RootTmp ([System.Guid]::NewGuid().ToString('N'))
        }
        $psExe = Join-Path ([System.Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
        $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:Builder, '-Destination', $Into)
        if ($Prune) { $psArgs += '-Prune' }
        $r = Invoke-LokiNative -Exe $psExe -Arguments $psArgs
        return @{ Path = $Into; Output = $r.Output; ExitCode = $r.ExitCode }
    }
}

AfterAll {
    if (Test-Path -LiteralPath $script:RootTmp) { Remove-Item -LiteralPath $script:RootTmp -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item Function:\New-TestStick -ErrorAction SilentlyContinue
    Remove-Item Function:\Invoke-LokiNative -ErrorAction SilentlyContinue
}

Describe 'src\loki.cmd -- the entry point DESIGN.md section 2 specifies' {

    It 'exists next to the dispatcher, so the build drops it at the stick root' {
        Test-Path -LiteralPath $script:Shim -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:SrcDir 'loki.ps1') -PathType Leaf | Should -BeTrue
    }

    It 'uses CRLF line endings -- cmd.exe is not reliable with LF-only batch files' {
        $bytes = [System.IO.File]::ReadAllBytes($script:Shim)
        $text = [System.Text.Encoding]::ASCII.GetString($bytes)
        $lf = ([regex]::Matches($text, "`n")).Count
        $crlf = ([regex]::Matches($text, "`r`n")).Count
        $crlf | Should -Be $lf -Because 'every LF must be part of a CRLF pair'
    }

    It 'anchors the dispatcher on its OWN directory, not the working directory' {
        # %~dp0 is what makes `E:\loki.cmd` work from any cwd. A bare 'loki.ps1' would resolve against the caller's
        # directory and fail everywhere except the stick root.
        (Get-Content -Raw -LiteralPath $script:Shim) | Should -Match '%~dp0loki\.ps1'
    }

    It 'passes the dispatcher exit code through -- exit codes are a public interface (CLAUDE.md section 4)' {
        # A real invocation, not a string check: `offline` with no arguments is a Usage error, which the dispatcher
        # maps to 2. A shim that swallowed the code would report 0 here and silently break every caller that scripts
        # against the exit codes.
        (Invoke-LokiNative -Exe $script:Shim -Arguments @('offline')).ExitCode | Should -Be 2
    }

    It 'exits 0 on a command that succeeds (the pass-through is not a constant 2)' {
        (Invoke-LokiNative -Exe $script:Shim -Arguments @('version')).ExitCode | Should -Be 0
    }

    It 'REGRESSION: starts even when the caller is PowerShell 7 (PSModulePath pin)' {
        # Measured before this pin existed: launched from a pwsh 7 session through cmd.exe, 5.1 inherits pwsh's
        # PSModulePath verbatim, finds PowerShell 7's Microsoft.PowerShell.Utility ahead of the system one, cannot
        # load it, and the dispatcher dies on its first Import-PowerShellDataFile with "not recognized". Loki did not
        # start at all on any machine with PowerShell 7 -- which is most of them.
        $saved = $env:PSModulePath
        try {
            $env:PSModulePath = 'C:\Program Files\PowerShell\7\Modules;' + $saved
            $r = Invoke-LokiNative -Exe $script:Shim -Arguments @('version')
            $r.ExitCode | Should -Be 0
            $r.Output | Should -Not -Match 'not recognized'
            $r.Output | Should -Match 'loki'
        }
        finally { $env:PSModulePath = $saved }
    }
}

Describe 'build\New-LokiStick.ps1 -- the deployed artifact, produced not assembled' {

    It 'produces the layout DESIGN.md section 2 specifies, and the result RUNS' {
        $s = New-TestStick
        $s.ExitCode | Should -Be 0
        foreach ($entry in 'loki.cmd', 'loki.ps1', 'version.txt') {
            Test-Path -LiteralPath (Join-Path $s.Path $entry) -PathType Leaf | Should -BeTrue -Because "$entry belongs at the stick root"
        }
        foreach ($dir in 'lib', 'commands', 'hooks', 'i18n', 'models') {
            Test-Path -LiteralPath (Join-Path $s.Path $dir) -PathType Container | Should -BeTrue -Because "$dir belongs on the stick"
        }
        # The point of a build script is a stick that works, so run the artifact rather than trusting the file list.
        (Invoke-LokiNative -Exe (Join-Path $s.Path 'loki.cmd') -Arguments @('version')).ExitCode | Should -Be 0
    }

    It 'copies BYTES -- EVERY file is byte-identical (the failure that motivated this script)' {
        # A hand-assembled stick lost the BOM off a non-ASCII catalog, and 5.1 then reads it as ANSI -> mojibake in
        # the operator's own language (CLAUDE.md section 1). Byte equality is the only assertion that catches it.
        #
        # EVERY file, not a sample: an earlier version of this test compared only i18n\*.psd1 and a mutation proved it
        # toothless -- swapping Copy-Item for a Get-Content/Set-Content round trip left those particular files
        # byte-identical (5.1's `-Encoding utf8` re-adds the BOM they already had) and the test stayed green. The round
        # trip is still wrong: it ADDS a BOM to the ASCII files that must not have one, rewrites line endings, and
        # drops or adds a trailing newline. Only comparing the whole tree catches all three.
        $s = New-TestStick
        $mismatched = New-Object System.Collections.Generic.List[string]
        foreach ($f in (Get-ChildItem -LiteralPath $script:SrcDir -Recurse -File)) {
            $relative = $f.FullName.Substring($script:SrcDir.Length).TrimStart('\')
            $built = Join-Path $s.Path $relative
            if (-not (Test-Path -LiteralPath $built)) { [void]$mismatched.Add($relative + ' (missing)'); continue }
            if ((Get-FileHash -LiteralPath $built -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash) {
                [void]$mismatched.Add($relative)
            }
        }
        ($mismatched -join '; ') | Should -BeNullOrEmpty -Because 'the build must move bytes, not re-encode them'
    }

    It 'NEVER destroys what setup and the operator put there: engine, models, and the credential' {
        # THE guarantee. Those cost gigabytes of download and a credential to recreate, and a rebuild is the routine
        # operation -- so a build script that can delete them is one that eventually will.
        $s = New-TestStick
        New-Item -ItemType Directory -Force -Path (Join-Path $s.Path 'engine-offline'), (Join-Path $s.Path 'home') | Out-Null
        Set-Content -LiteralPath (Join-Path $s.Path 'engine-offline\llama-server.exe') -Value 'ENGINE' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $s.Path 'models\tier.gguf') -Value 'WEIGHTS' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $s.Path 'home\.env') -Value 'LOKI_SECRET=dGVzdA==' -Encoding utf8

        $again = New-TestStick -Into $s.Path
        $again.ExitCode | Should -Be 0
        (Get-Content -Raw -LiteralPath (Join-Path $s.Path 'engine-offline\llama-server.exe')).Trim() | Should -Be 'ENGINE'
        (Get-Content -Raw -LiteralPath (Join-Path $s.Path 'models\tier.gguf')).Trim() | Should -Be 'WEIGHTS'
        (Get-Content -Raw -LiteralPath (Join-Path $s.Path 'home\.env')).Trim() | Should -Be 'LOKI_SECRET=dGVzdA=='
    }

    It 'REPORTS a stale auto-loaded file rather than silently leaving it -- the dispatcher LOADS it' {
        $s = New-TestStick
        Set-Content -LiteralPath (Join-Path $s.Path 'lib\zz-removed.ps1') -Value '# no longer in src' -Encoding utf8
        $again = New-TestStick -Into $s.Path
        $again.Output | Should -Match 'zz-removed\.ps1'
        Test-Path -LiteralPath (Join-Path $s.Path 'lib\zz-removed.ps1') | Should -BeTrue -Because 'reporting is not deleting; -Prune is opt-in'
    }

    It '-Prune removes the reported orphan, and ONLY that' {
        $s = New-TestStick
        Set-Content -LiteralPath (Join-Path $s.Path 'lib\zz-removed.ps1') -Value '# no longer in src' -Encoding utf8
        New-Item -ItemType Directory -Force -Path (Join-Path $s.Path 'models') | Out-Null
        Set-Content -LiteralPath (Join-Path $s.Path 'models\tier.gguf') -Value 'WEIGHTS' -Encoding utf8
        [void](New-TestStick -Into $s.Path -Prune)
        Test-Path -LiteralPath (Join-Path $s.Path 'lib\zz-removed.ps1') | Should -BeFalse
        # -Prune must not wander outside the auto-loaded directories: a model is not an orphan.
        Test-Path -LiteralPath (Join-Path $s.Path 'models\tier.gguf') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $s.Path 'lib\auth.ps1') | Should -BeTrue
    }

    It 'BREAK-THE-GUARD: refuses to build into the repository itself: <target>' -ForEach @(
        @{ target = 'repo' }, @{ target = 'src' }
    ) {
        # Runs against a THROWAWAY copy of the builder in a temp repo skeleton, never against this checkout -- and
        # that is not caution for its own sake. A mutation run that disabled this very guard made the earlier version
        # of this test build a whole stick into the real repository root, ~9900 lines of duplicated code that then got
        # committed. A test whose safety depends on the guard it is testing has no safety at all: when the guard
        # breaks, so does the test's containment, and that is precisely the run where containment is needed.
        $fakeRepo = Join-Path $script:RootTmp ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $fakeRepo 'build'), (Join-Path $fakeRepo 'src') | Out-Null
        Copy-Item -LiteralPath $script:Builder -Destination (Join-Path $fakeRepo 'build\New-LokiStick.ps1')
        Set-Content -LiteralPath (Join-Path $fakeRepo 'src\loki.ps1') -Value '# stand-in dispatcher' -Encoding utf8

        $dest = if ($target -eq 'repo') { $fakeRepo } else { (Join-Path $fakeRepo 'src') }
        $psExe = Join-Path ([System.Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
        $r = Invoke-LokiNative -Exe $psExe -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
            (Join-Path $fakeRepo 'build\New-LokiStick.ps1'), '-Destination', $dest)

        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -Match 'Refusing to build into the repository'
        # ...and it refused BEFORE writing: the skeleton still holds exactly what was put there.
        Test-Path -LiteralPath (Join-Path $fakeRepo 'lib') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $fakeRepo 'src\lib') | Should -BeFalse
    }
}

Describe 'build stamp -- stick-build.json records WHEN the stick was built (#91)' {

    It 'writes a well-formed stamp at the stick root' {
        $stick = New-TestStick
        $stick.ExitCode | Should -Be 0
        $stampPath = Join-Path $stick.Path 'stick-build.json'
        Test-Path -LiteralPath $stampPath -PathType Leaf | Should -BeTrue

        $obj = (Get-Content -LiteralPath $stampPath -Raw -Encoding utf8) | ConvertFrom-Json
        # An ISO-8601 UTC instant the age math can parse, and the version this stick was built from.
        $dto = [System.DateTimeOffset]::MinValue
        [System.DateTimeOffset]::TryParse($obj.builtUtc, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$dto) | Should -BeTrue
        $obj.builtUtc | Should -Match 'Z$'
        $repoVersion = (Get-Content -LiteralPath (Join-Path $script:RepoRoot 'version.txt') -Raw -Encoding utf8).Trim()
        $obj.sourceVersion | Should -Be $repoVersion
    }

    It 'writes it BOM-free (a BOM in JSON is grit some parsers choke on)' {
        $stick = New-TestStick
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $stick.Path 'stick-build.json'))
        # Not EF BB BF at the front.
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
    }

    It 'is fresh, so status reads it back as age 0 right after a build' {
        . "$PSScriptRoot\..\src\lib\meta.ps1"
        $stick = New-TestStick
        $info = Get-LokiStickBuildInfo -AppRoot $stick.Path
        $info | Should -Not -BeNullOrEmpty
        Get-LokiStickAgeDays -BuiltUtc $info.BuiltUtc -Now (Get-Date) | Should -Be 0
    }

    It 'a rebuild refreshes the stamp rather than leaving the old one' {
        $into = Join-Path $script:RootTmp ([System.Guid]::NewGuid().ToString('N'))
        $null = New-TestStick -Into $into
        $first = (Get-Content -LiteralPath (Join-Path $into 'stick-build.json') -Raw -Encoding utf8)
        Start-Sleep -Seconds 1   # the stamp has 1-second resolution; ensure the clock advances
        $null = New-TestStick -Into $into
        $second = (Get-Content -LiteralPath (Join-Path $into 'stick-build.json') -Raw -Encoding utf8)
        $second | Should -Not -Be $first
    }
}
