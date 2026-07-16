# tests/collect-command.Tests.ps1 -- Command `loki collect`: metadata, arg parsing, artifacts, exit codes.
# A lib and a command share the name, so the command tests live here and the lib tests in tests/collect.Tests.ps1 --
# same split as auth / auth-command and hwscan / hwscan-command.
# Invoke-LokiCollect is Mocked throughout: these tests pin the WIRING (parse -> collect -> shape -> write -> exit
# code) deterministically, without spending ~4 s probing a CI runner whose real hardware would decide the outcome.
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\i18n.ps1"
    . "$PSScriptRoot\..\src\lib\ui.ps1"
    . "$PSScriptRoot\..\src\lib\exitcodes.ps1"
    . "$PSScriptRoot\..\src\lib\hwscan.ps1"
    . "$PSScriptRoot\..\src\lib\posture.ps1"
    . "$PSScriptRoot\..\src\lib\net.ps1"
    . "$PSScriptRoot\..\src\lib\collect.ps1"
    . "$PSScriptRoot\..\src\commands\collect.ps1"
    Initialize-LokiUi -NoColor
    $script:SrcRoot = (Resolve-Path "$PSScriptRoot\..\src").Path
    Initialize-LokiI18n -AppRoot $script:SrcRoot -Locale 'en' | Out-Null

    # A real directory per test run: `loki collect` WRITES, so an AppRoot pointing at src\ would drop dumps into the
    # working copy (which is exactly why reports/ is gitignored -- ADR-0018).
    $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ("loki-collect-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:Work | Out-Null

    function global:New-TestCollectContext {
        param([string[]]$CmdArgs = @(), [string]$AppRoot = $script:Work)
        return @{ AppRoot = $AppRoot; Version = '9.9.9'; Args = $CmdArgs; Flags = @{}; Registry = @() }
    }

    function global:Invoke-CollectCommand {
        param([Parameter(Mandatory = $true)][hashtable]$Context)
        $swErr = New-Object System.IO.StringWriter
        $origErr = [Console]::Error
        [Console]::SetError($swErr)
        try { $raw = @(Invoke-LokiCmd_collect $Context 6>&1) }
        finally { [Console]::SetError($origErr) }
        $code = [int]($raw | Select-Object -Last 1)
        $lineCount = [Math]::Max(0, $raw.Count - 1)
        $stdText = (@($raw | Select-Object -First $lineCount) | Out-String)
        $errText = $swErr.ToString()
        [pscustomobject]@{ Code = $code; Text = $stdText; ErrText = $errText; AllText = ($stdText + $errText) }
    }
}

AfterAll {
    if (Test-Path -LiteralPath $script:Work) { Remove-Item -LiteralPath $script:Work -Recurse -Force }
    Remove-Item Function:\New-TestCollectContext -ErrorAction SilentlyContinue
    Remove-Item Function:\Invoke-CollectCommand -ErrorAction SilentlyContinue
}

Describe 'Command collect' {

    BeforeAll {
        # Durations are deliberately distinct and NOT round (441 / 1483), and no duration shares digits with a
        # battery count -- the neighbouring hwscan suite has a note about an assertion that matched the wrong line
        # because two unrelated numbers happened to be equal. Keep them tellable apart.
        Mock Invoke-LokiCollect {
            [pscustomobject]@{
                CreatedAt = ([datetime]'2026-07-16 14:30:00')
                Batteries = @(
                    [pscustomobject]@{
                        Id = 'os'; Status = 'ok'; DurationMs = 441; Error = $null
                        Data = [pscustomobject]@{ Caption = 'Microsoft Windows 11 Pro'; UptimeHours = 34.2 }
                    },
                    [pscustomobject]@{
                        Id = 'hardware'; Status = 'ok'; DurationMs = 1483; Error = $null
                        Data = [pscustomobject]@{ CpuName = 'Test CPU'; TotalRamGB = 31.46 }
                    }
                )
            }
        }
    }

    It 'metadata is complete (Name == file name) and the handler exists' {
        $m = Get-LokiCmdMeta_collect
        $m.Name | Should -Be 'collect'
        $m.Group | Should -Not -BeNullOrEmpty
        $m.Usage | Should -Not -BeNullOrEmpty
        # Summary is a CATALOG KEY, not prose (CLAUDE.md section 10 / ADR-0004).
        $m.Summary | Should -Be 'collect.summary'
        (Get-Command Invoke-LokiCmd_collect -CommandType Function) | Should -Not -BeNullOrEmpty
    }

    It 'writes both artifacts into reports\ under the app root and reports Ok' {
        $ctx = New-TestCollectContext
        $r = Invoke-CollectCommand -Context $ctx
        $r.Code | Should -Be 0

        $reports = Join-Path $script:Work 'reports'
        @(Get-ChildItem -LiteralPath $reports -Filter 'collect-*.json').Count | Should -BeGreaterThan 0
        @(Get-ChildItem -LiteralPath $reports -Filter 'collect-*.txt').Count | Should -BeGreaterThan 0
    }

    It 'writes only under the app root (the footprint guarantee)' {
        $isolated = Join-Path ([System.IO.Path]::GetTempPath()) ("loki-iso-" + [System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $isolated | Out-Null
        try {
            $null = Invoke-CollectCommand -Context (New-TestCollectContext -AppRoot $isolated)

            # Asserted against the FILESYSTEM, not against the printed text. The first version scraped the paths out
            # of the command's output with a regex and passed locally, then failed on CI with "Expected 2, but got 0"
            # -- Out-String wraps at the HOST's console width, and a CI runner (powershell.EXE -command, no real
            # console) is narrow enough to break a long path across two lines, leaving neither half matchable.
            # A footprint test must not depend on how wide someone's terminal is.
            $everything = @(Get-ChildItem -LiteralPath $isolated -Recurse -File -Force)
            @($everything).Count | Should -Be 2
            foreach ($f in $everything) {
                $f.DirectoryName | Should -Be (Join-Path $isolated 'reports')
            }
            # NOT asserted as "outside $env:USERPROFILE": the temp AppRoot above lives under the user profile on
            # Windows, so that check would look like a footprint proof and could never be one. "Everything this run
            # created sits under AppRoot, and nowhere else" is the property that actually carries the guarantee.
        }
        finally {
            Remove-Item -LiteralPath $isolated -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'the JSON artifact carries the version and the schema, and no /Date(ms)/' {
        $ctx = New-TestCollectContext
        $null = Invoke-CollectCommand -Context $ctx
        $json = Get-ChildItem -LiteralPath (Join-Path $script:Work 'reports') -Filter 'collect-*.json' |
            Sort-Object LastWriteTime | Select-Object -Last 1
        $raw = Get-Content -LiteralPath $json.FullName -Raw
        $raw | Should -Match '"LokiVersion":\s+"9\.9\.9"'
        $raw | Should -Match '"SchemaVersion":\s+1'
        $raw | Should -Not -Match '/Date\('
    }

    It 'refuses a misspelled battery with Usage rather than writing an empty dump' {
        # The library filters unknown ids silently; if the command does not check, `--only stroage` writes a dump
        # with nothing in it and reports success. That is the guard this test exists for.
        $r = Invoke-CollectCommand -Context (New-TestCollectContext -CmdArgs @('--only', 'stroage'))
        $r.Code | Should -Be 2
        $r.AllText | Should -Match 'stroage'
        # ...and it names what IS valid, rather than leaving the operator guessing.
        $r.AllText | Should -Match 'storage'
    }

    It 'refuses --only without a value' {
        $r = Invoke-CollectCommand -Context (New-TestCollectContext -CmdArgs @('--only'))
        $r.Code | Should -Be 2
    }

    It 'refuses an unknown argument' {
        $r = Invoke-CollectCommand -Context (New-TestCollectContext -CmdArgs @('--wat'))
        $r.Code | Should -Be 2
        $r.AllText | Should -Match '--wat'
    }

    It 'accepts the separated and the equals form of --only' {
        # The name must not contain angle brackets: Pester 5 treats <name> in a test name as a -ForEach data
        # placeholder and tries to expand it, so 'accepts --only <v>' fails with "The variable '$v' ... has not
        # been set" before the body ever runs. Measured here, not read somewhere.
        foreach ($form in @(@('--only', 'os'), @('--only=os'))) {
            $r = Invoke-CollectCommand -Context (New-TestCollectContext -CmdArgs $form)
            $r.Code | Should -Be 0
        }
    }

    It 'reports each battery with its duration' {
        $r = Invoke-CollectCommand -Context (New-TestCollectContext)
        $r.AllText | Should -Match 'os'
        $r.AllText | Should -Match '441'
        $r.AllText | Should -Match '1483'
    }
}

Describe 'Command collect -- a failed battery is content, not a failed run (ADR-0018)' {

    It 'still exits Ok when a battery times out' {
        Mock Invoke-LokiCollect {
            [pscustomobject]@{
                CreatedAt = ([datetime]'2026-07-16 14:30:00')
                Batteries = @(
                    [pscustomobject]@{ Id = 'os'; Status = 'ok'; DurationMs = 441; Error = $null
                        Data = [pscustomobject]@{ Caption = 'Windows' } },
                    [pscustomobject]@{ Id = 'services'; Status = 'timeout'; DurationMs = 10004; Data = $null
                        Error = 'Timed out' }
                )
            }
        }
        $r = Invoke-CollectCommand -Context (New-TestCollectContext)
        $r.Code | Should -Be 0
        $r.AllText | Should -Match 'Timed out'
        $r.AllText | Should -Match '1 ok, 1 failed'
    }

    It 'still exits Ok when EVERY battery fails -- "nothing answers here" is a diagnosis' {
        Mock Invoke-LokiCollect {
            [pscustomobject]@{
                CreatedAt = ([datetime]'2026-07-16 14:30:00')
                Batteries = @(
                    [pscustomobject]@{ Id = 'os'; Status = 'failed'; DurationMs = 12; Data = $null; Error = 'Access denied' },
                    [pscustomobject]@{ Id = 'services'; Status = 'failed'; DurationMs = 14; Data = $null; Error = 'Access denied' }
                )
            }
        }
        $r = Invoke-CollectCommand -Context (New-TestCollectContext)
        $r.Code | Should -Be 0
        $r.AllText | Should -Match '0 ok, 2 failed'
    }

    It 'names a reason even when the probe gave none' {
        Mock Invoke-LokiCollect {
            [pscustomobject]@{
                CreatedAt = ([datetime]'2026-07-16 14:30:00')
                Batteries = @(
                    [pscustomobject]@{ Id = 'os'; Status = 'failed'; DurationMs = 12; Data = $null; Error = $null }
                )
            }
        }
        $r = Invoke-CollectCommand -Context (New-TestCollectContext)
        $r.Code | Should -Be 0
        $r.AllText | Should -Match 'no reason given'
    }
}

Describe 'Command collect -- an unwritable dump IS an error' {

    BeforeAll {
        Mock Invoke-LokiCollect {
            [pscustomobject]@{
                CreatedAt = ([datetime]'2026-07-16 14:30:00')
                Batteries = @(
                    [pscustomobject]@{ Id = 'os'; Status = 'ok'; DurationMs = 441; Error = $null
                        Data = [pscustomobject]@{ Caption = 'Windows' } }
                )
            }
        }
    }

    It 'returns GeneralError when a FILE sits where reports\ must be' {
        # Break the guard on purpose (CLAUDE.md section 6), through the same code path a full or write-protected
        # stick takes -- the failure is real, not mocked. Note this case never reaches New-Item: Test-Path says True
        # for a file (measured), so the refusal comes from Set-Content. See the next test for the other half.
        $blocked = Join-Path ([System.IO.Path]::GetTempPath()) ("loki-blocked-" + [System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $blocked | Out-Null
        try {
            Set-Content -LiteralPath (Join-Path $blocked 'reports') -Value 'I am a file, not a directory' -Encoding utf8
            $r = Invoke-CollectCommand -Context (New-TestCollectContext -AppRoot $blocked)
            $r.Code | Should -Be 1
            $r.AllText | Should -Match ([regex]::Escape('reports'))
        }
        finally {
            Remove-Item -LiteralPath $blocked -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns GeneralError when reports\ cannot be created at all' {
        # The OTHER half of the write guard, and the reason this test exists: a mutation that dropped
        # -ErrorAction Stop from New-Item SURVIVED the whole suite, because the file-in-the-way test above never
        # reaches New-Item at all. Measured: Test-Path on a missing drive returns $false (it does not throw the way
        # Join-Path does), so New-Item really runs and really fails -- and without -ErrorAction Stop that failure is
        # NON-terminating, so the command would report a written dump over a directory that does not exist.
        $used = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Name })
        $free = @([char[]]'QWXYZ' | Where-Object { $used -notcontains [string]$_ })
        if ($free.Count -eq 0) { Set-ItResult -Skipped -Because 'this machine has no free drive letter to test with' }
        $ctx = New-TestCollectContext -AppRoot (([string]$free[0]) + ':\no-such-drive\app')
        $r = Invoke-CollectCommand -Context $ctx
        $r.Code | Should -Be 1
    }
}
