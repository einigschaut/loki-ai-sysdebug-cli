# tests/agent.Tests.ps1 -- the offline engine harness (security core, CLAUDE.md section 5/6; ADR-0015).
#
# The environment cases below are not hypotheticals: every variable they set was measured reaching the real b10038
# binary on 2026-07-16 (llama-server documents 132 LLAMA_ARG_* twins; AIP_* exists in the dll and in no --help). The
# process-lifecycle cases use REAL processes where a real process is the thing under test, and mocks only where the
# assertion is about wiring.
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\src\lib\exitcodes.ps1"
    . "$PSScriptRoot\..\src\lib\auth.ps1"        # Remove-LokiCredentialEnv -- the one credential list (ADR-0027)
    . "$PSScriptRoot\..\src\lib\env-isolate.ps1"
    . "$PSScriptRoot\..\src\lib\download.ps1"
    . "$PSScriptRoot\..\src\lib\engine.ps1"
    . "$PSScriptRoot\..\src\lib\models.ps1"
    . "$PSScriptRoot\..\src\lib\hwscan.ps1"
    . "$PSScriptRoot\..\src\lib\integrity.ps1"
    . "$PSScriptRoot\..\src\lib\agent.ps1"
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $script:RootTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("loki-agent-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:RootTmp | Out-Null

    # A stick laid out like a real one: engine-offline\ with the archive + its expanded contents, a staged runtime, and
    # a model at its pinned hash. Real files -- the thing under test IS the filesystem + process interaction.
    function global:New-AgentStick {
        param([switch]$NoModel, [switch]$TamperEngine, [switch]$NoRuntime)
        $root = Join-Path $script:RootTmp ([System.Guid]::NewGuid().ToString('N'))
        $dir = Join-Path $root 'engine-offline'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'models') | Out-Null

        $zipPath = Join-Path $root 'build.zip'
        $zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
        foreach ($n in @('llama-server.exe', 'ggml-base.dll')) {
            $e = $zip.CreateEntry($n); $sw = New-Object System.IO.StreamWriter($e.Open()); $sw.Write("bytes-of-$n"); $sw.Dispose()
        }
        $zip.Dispose()
        $engine = @{ FileName = 'engine.zip'; ServerExe = 'llama-server.exe'; Version = 'b10038'
            Sha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
        }
        Copy-Item -LiteralPath $zipPath -Destination (Join-Path $dir 'engine.zip') -Force
        Remove-Item -LiteralPath $zipPath -Force
        foreach ($n in @('llama-server.exe', 'ggml-base.dll')) {
            [System.IO.File]::WriteAllText((Join-Path $dir $n), "bytes-of-$n")
        }
        if ($TamperEngine) { [System.IO.File]::WriteAllText((Join-Path $dir 'llama-server.exe'), 'EVIL') }
        # kernel32.dll paired with MinVersion 1.0: a real signed versioned binary on every Windows host, so the
        # runtime leg is satisfied without depending on the CI machine's VC++ redist.
        if (-not $NoRuntime) {
            Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\kernel32.dll') -Destination (Join-Path $dir 'VCRUNTIME140.dll') -Force
        }
        $runtime = @{ Files = @('VCRUNTIME140.dll'); MinVersion = '1.0'; RegistryKey = 'HKLM:\SOFTWARE\Loki\DoesNotExist\Ever' }

        $model = @{ Id = 'nano'; FileName = 'nano.gguf'; ResidentGB = 2.5; ContextTokens = 32768; Sha256 = ('0' * 64) }
        if (-not $NoModel) {
            $mp = Join-Path $root 'models\nano.gguf'
            [System.IO.File]::WriteAllText($mp, 'weights')
            $model.Sha256 = (Get-FileHash -LiteralPath $mp -Algorithm SHA256).Hash
        }
        return @{ AppRoot = $root; Engine = $engine; Runtime = $runtime; Model = $model }
    }
}

AfterAll {
    if (Test-Path -LiteralPath $script:RootTmp) { Remove-Item -LiteralPath $script:RootTmp -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item Function:\New-AgentStick -ErrorAction SilentlyContinue
}

Describe 'Get-LokiLlamaServerArgs (pure; the security surface)' {

    It 'binds loopback only -- a diagnostic LLM is never reachable from the target network' {
        $a = Get-LokiLlamaServerArgs -ModelPath 'C:\m.gguf' -Port 8080 -CtxSize 4096 -Threads 4
        $i = [array]::IndexOf($a, '--host')
        $i | Should -BeGreaterThan -1
        $a[$i + 1] | Should -Be '127.0.0.1'
        $a | Should -Not -Contain '0.0.0.0'
    }

    It 'passes <flag>, because it is default-<default> and the environment must not get a vote' -ForEach @(
        # Measured against b10038's --help, not recalled. The first two are ON unless we say otherwise; --jinja is on
        # today and passed anyway, because a flag we do not pass is a flag LLAMA_ARG_* decides.
        @{ flag = '--no-webui'; default = 'enabled' }
        @{ flag = '--no-slots'; default = 'enabled' }
        @{ flag = '--jinja'; default = 'enabled-today' }
    ) {
        $a = Get-LokiLlamaServerArgs -ModelPath 'C:\m.gguf' -Port 8080 -CtxSize 4096 -Threads 4
        $a | Should -Contain $flag
    }

    It 'states ctx-size and threads explicitly rather than inheriting a default' {
        $a = Get-LokiLlamaServerArgs -ModelPath 'C:\m.gguf' -Port 9001 -CtxSize 4096 -Threads 6
        $a[([array]::IndexOf($a, '--ctx-size')) + 1] | Should -Be '4096'
        $a[([array]::IndexOf($a, '--threads')) + 1] | Should -Be '6'
        $a[([array]::IndexOf($a, '--port')) + 1] | Should -Be '9001'
        $a[([array]::IndexOf($a, '--model')) + 1] | Should -Be 'C:\m.gguf'
    }

    It 'BREAK-THE-GUARD: refuses <case>, which would hand the decision to the model or the environment' -ForEach @(
        # ctx 0 = "take it from the model": the `small` tier declares 262144 tokens and Loki runs on whatever machine
        # it is plugged into. threads -1 = "auto", which LLAMA_ARG_THREADS can move.
        @{ case = 'ctx-size 0'; ctx = 0; threads = 4; port = 8080 }
        @{ case = 'threads -1 (auto)'; ctx = 4096; threads = -1; port = 8080 }
        @{ case = 'port 0'; ctx = 4096; threads = 4; port = 0 }
        @{ case = 'port out of range'; ctx = 4096; threads = 4; port = 70000 }
    ) {
        { Get-LokiLlamaServerArgs -ModelPath 'C:\m.gguf' -Port $port -CtxSize $ctx -Threads $threads } | Should -Throw
    }

    It 'is an array, not an unrolled string (regression: return $a would reach the caller as loose items)' {
        $a = Get-LokiLlamaServerArgs -ModelPath 'C:\m.gguf' -Port 8080 -CtxSize 4096 -Threads 4
        $a -is [array] | Should -BeTrue
        $a.Count | Should -BeGreaterThan 10
    }
}

Describe 'Get-LokiEngineChildEnv (the environment the target does not get to configure)' {

    It 'strips the engine namespace a hostile target could set' {
        # Every name here was measured reaching the real binary. LLAMA_ARG_HOST would be beaten by our explicit
        # --host anyway; LLAMA_ARG_ENDPOINT_METRICS would NOT be, because --metrics has no negated form -- which is
        # exactly why stripping exists next to the flags rather than instead of them.
        $hostile = @{
            'PATH'                        = 'C:\Windows'
            'LLAMA_ARG_HOST'              = '0.0.0.0'
            'LLAMA_ARG_PORT'              = '9999'
            'LLAMA_ARG_ENDPOINT_SLOTS'    = '1'
            'LLAMA_ARG_ENDPOINT_METRICS'  = '1'
            'LLAMA_ARG_ENDPOINT_PROPS'    = '1'
            'LLAMA_ARG_UI'                = '1'
            'LLAMA_API_KEY'               = 'someones-key'
            'HF_TOKEN'                    = 'someones-hf-token'
            'AIP_HTTP_PORT'               = '8198'
            'AIP_MODE'                    = 'true'
            'AIP_HEALTH_ROUTE'            = '/pwned'
        }
        $e = Get-LokiEngineChildEnv -AppRoot 'C:\stick' -BaseEnv $hostile
        foreach ($k in @('LLAMA_ARG_HOST', 'LLAMA_ARG_PORT', 'LLAMA_ARG_ENDPOINT_SLOTS', 'LLAMA_ARG_ENDPOINT_METRICS',
                'LLAMA_ARG_ENDPOINT_PROPS', 'LLAMA_ARG_UI', 'LLAMA_API_KEY', 'HF_TOKEN',
                'AIP_HTTP_PORT', 'AIP_MODE', 'AIP_HEALTH_ROUTE')) {
            $e.ContainsKey($k) | Should -BeFalse -Because "$k reaches llama-server from the target machine otherwise"
        }
    }

    It 'hands llama-server NO credential -- not one of the eight, not LOKI_SECRET (ADR-0027)' {
        # The gap this test was written for. Until 2026-07-21 this function stripped LLAMA_* and nothing else, so the
        # block it handed llama-server.exe carried every credential the operator's shell had -- measured: all eight.
        # llama-server reads none of them, so nothing was exploitable through the engine itself; but Loki had already
        # accepted the opposite rule for the offline read child (S6), and this is the largest third-party binary Loki
        # executes. The credential names come from lib/auth.ps1, so adding one there extends this test automatically.
        $shell = @{ 'PATH' = 'C:\Windows' }
        foreach ($n in (Get-LokiCredentialVarNames)) { $shell[$n] = "leaked-$n" }
        $e = Get-LokiEngineChildEnv -AppRoot 'C:\stick' -BaseEnv $shell
        foreach ($n in (Get-LokiCredentialVarNames)) {
            $e.ContainsKey($n) | Should -BeFalse -Because "$n would reach llama-server from the operator's shell"
        }
        $e.ContainsKey('PATH') | Should -BeTrue
    }

    It 'keeps what the child actually needs -- this is a strip, not an allow-list' {
        $e = Get-LokiEngineChildEnv -AppRoot 'C:\stick' -BaseEnv @{ 'PATH' = 'C:\Windows'; 'SystemRoot' = 'C:\Windows' }
        $e.ContainsKey('SystemRoot') | Should -BeTrue
        $e.ContainsKey('PATH') | Should -BeTrue
        # And Loki's own redirects are still overlaid (env-isolate's job, asserted here so a refactor cannot drop it).
        $e['USERPROFILE'] | Should -BeLike 'C:\stick*'
    }

    It 'strips case-insensitively and culture-invariantly (llama_arg_host is the same variable)' {
        # Windows env var names are case-insensitive, so a lowercase spelling is the SAME variable, not a near miss.
        # OrdinalIgnoreCase, never -like/-match: 'LLAMA_ARG_' carries an I, and under tr-TR a culture-sensitive fold
        # turns it dotless and the prefix stops matching -- the exact bug fixed in #29.
        $e = Get-LokiEngineChildEnv -AppRoot 'C:\stick' -BaseEnv @{ 'llama_arg_host' = '0.0.0.0'; 'Llama_Arg_Port' = '1'; 'aip_http_port' = '2' }
        $e.ContainsKey('llama_arg_host') | Should -BeFalse
        $e.ContainsKey('Llama_Arg_Port') | Should -BeFalse
        $e.ContainsKey('aip_http_port') | Should -BeFalse
    }

    It 'does not strip a variable that merely starts similarly' {
        # The prefix is a prefix, not a substring: LLAMA_ARGUMENTS is not in the engine's namespace, and a strip that
        # is too eager is as much a bug as one that is too shy.
        $e = Get-LokiEngineChildEnv -AppRoot 'C:\stick' -BaseEnv @{ 'MY_LLAMA_ARG_HOST' = 'x'; 'AIPHONE' = 'y' }
        $e.ContainsKey('MY_LLAMA_ARG_HOST') | Should -BeTrue
        $e.ContainsKey('AIPHONE') | Should -BeTrue
    }
}

Describe 'Get-LokiFreeLoopbackPort' {

    It 'returns a port that is genuinely bindable on loopback' {
        $port = Get-LokiFreeLoopbackPort
        $port | Should -BeGreaterThan 0
        $port | Should -BeLessOrEqual 65535
        # The claim is "free", so bind it for real rather than trust the number.
        $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $port)
        { $l.Start() } | Should -Not -Throw
        $l.Stop()
    }

    It 'hands out a different port while one is held (it reads the OS, it does not count up)' {
        $first = Get-LokiFreeLoopbackPort
        $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $first)
        $l.Start()
        try { (Get-LokiFreeLoopbackPort) | Should -Not -Be $first }
        finally { $l.Stop() }
    }
}

Describe 'Get-LokiEngineOrphan (identity by image path, never by a remembered PID)' {

    It 'finds a process running exactly this executable' {
        # The current PowerShell process is a real, running, known-path process -- no spawning needed, and it proves
        # the match works against a live one rather than a fixture.
        $self = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $found = @(Get-LokiEngineOrphan -ServerExePath $self)
        @($found | Where-Object { $_.Id -eq $PID }).Count | Should -Be 1
    }

    It 'matches the path case-insensitively, as Windows does' {
        $self = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $found = @(Get-LokiEngineOrphan -ServerExePath $self.ToUpperInvariant())
        @($found | Where-Object { $_.Id -eq $PID }).Count | Should -Be 1
    }

    It 'BREAK-THE-GUARD: a same-NAMED process from a DIFFERENT path is not ours' {
        # The whole point of matching on the path: another powershell.exe elsewhere on the machine (or another Loki
        # stick) must never be mistaken for this stick's engine and reported as an orphan to kill.
        $fake = Join-Path $script:RootTmp 'nowhere\powershell.exe'
        @(Get-LokiEngineOrphan -ServerExePath $fake).Count | Should -Be 0
    }

    It 'an executable nobody is running yields nothing, not an error' {
        @(Get-LokiEngineOrphan -ServerExePath (Join-Path $script:RootTmp 'llama-server.exe')).Count | Should -Be 0
    }
}

Describe 'Resolve-LokiEnginePreflight (may we start?)' {

    It 'a verified stick with a fitting model says yes' {
        $s = New-AgentStick
        Mock Get-LokiHardwareProfile { @{ TotalRamGB = 32.0; AvailableRamGB = 24.0; CpuName = 'x'; CpuCores = 8; Is64BitOs = $true } }
        $r = Resolve-LokiEnginePreflight -AppRoot $s.AppRoot -Engine $s.Engine -Runtime $s.Runtime -Model $s.Model
        $r.Ok | Should -BeTrue
        $r.ModelPath | Should -BeLike '*nano.gguf'
        $r.ServerExePath | Should -BeLike '*engine-offline\llama-server.exe'
    }

    It 'BREAK-THE-GUARD: a tampered engine is never started' {
        $s = New-AgentStick -TamperEngine
        Mock Get-LokiHardwareProfile { @{ TotalRamGB = 32.0; AvailableRamGB = 24.0; CpuName = 'x'; CpuCores = 8; Is64BitOs = $true } }
        $r = Resolve-LokiEnginePreflight -AppRoot $s.AppRoot -Engine $s.Engine -Runtime $s.Runtime -Model $s.Model
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'engine-unverified'
        $r.Detail | Should -Be 'file-mismatch'
    }

    It 'BREAK-THE-GUARD: an ABSENT model is fatal here, though lib/integrity.ps1 calls it normal' {
        # ADR-0014 wrote this obligation down and left it for this slice: `not-installed` is legitimate on a stick that
        # carries a subset of tiers (ADR-0013), and it is fatal to a harness that is about to load THAT model. If this
        # ever passes, the engine starts with --model pointing at nothing.
        $s = New-AgentStick -NoModel
        Mock Get-LokiHardwareProfile { @{ TotalRamGB = 32.0; AvailableRamGB = 24.0; CpuName = 'x'; CpuCores = 8; Is64BitOs = $true } }
        $r = Resolve-LokiEnginePreflight -AppRoot $s.AppRoot -Engine $s.Engine -Runtime $s.Runtime -Model $s.Model
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'model-unverified'
        $r.Detail | Should -Be 'not-installed'
    }

    It 'BREAK-THE-GUARD: a swapped model is never loaded' {
        $s = New-AgentStick
        [System.IO.File]::WriteAllText((Join-Path $s.AppRoot 'models\nano.gguf'), 'EVIL-WEIGHTS')
        Mock Get-LokiHardwareProfile { @{ TotalRamGB = 32.0; AvailableRamGB = 24.0; CpuName = 'x'; CpuCores = 8; Is64BitOs = $true } }
        $r = Resolve-LokiEnginePreflight -AppRoot $s.AppRoot -Engine $s.Engine -Runtime $s.Runtime -Model $s.Model
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'model-unverified'
        $r.Detail | Should -Be 'mismatch'
    }

    It 'refuses a model that does not fit THIS machine, whatever the setup machine decided' {
        # The tier was chosen where the stick was prepared. The RAM is re-measured here because the stick was carried.
        # 4 GB total -> the ballast cap is 2.4 GB, so nano's 2.5 GB is too much for this box permanently.
        $s = New-AgentStick
        Mock Get-LokiHardwareProfile { @{ TotalRamGB = 4.0; AvailableRamGB = 1.5; CpuName = 'x'; CpuCores = 2; Is64BitOs = $true } }
        $r = Resolve-LokiEnginePreflight -AppRoot $s.AppRoot -Engine $s.Engine -Runtime $s.Runtime -Model $s.Model
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'insufficient-ram'
        $r.Verdict | Should -Be 'too-big'
        $r.NeedGB | Should -Be 2.5
    }

    It 'a model blocked only by BUSY memory is refused differently from one too big for the box (ADR-0017)' {
        # Same refusal, different advice: this one says "close something and retry", and carries the number to close.
        # A harness that collapsed the two would send the operator after memory that could never be enough.
        $s = New-AgentStick
        Mock Get-LokiHardwareProfile { @{ TotalRamGB = 16.0; AvailableRamGB = 3.0; CpuName = 'x'; CpuCores = 8; Is64BitOs = $true } }
        $r = Resolve-LokiEnginePreflight -AppRoot $s.AppRoot -Engine $s.Engine -Runtime $s.Runtime -Model $s.Model
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'insufficient-ram'
        $r.Verdict | Should -Be 'fits-if-freed'
        $r.NeedFreeGB | Should -Be 1.0      # 2.5 + 1.5 - 3.0
    }

    It 'an unreadable machine is refused as unknown, not as "this machine has no RAM"' {
        # Get-LokiHardwareProfile's contract is that a field may be $null. A [double] cast would turn that into 0.0
        # and report a plausible-looking lie about the host instead of admitting the probe failed.
        $s = New-AgentStick
        Mock Get-LokiHardwareProfile { @{ TotalRamGB = $null; AvailableRamGB = $null; CpuName = $null; CpuCores = $null; Is64BitOs = $true } }
        $r = Resolve-LokiEnginePreflight -AppRoot $s.AppRoot -Engine $s.Engine -Runtime $s.Runtime -Model $s.Model
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'insufficient-ram'
        $r.Verdict | Should -Be 'ram-unknown'
    }

    It 'the RAM check is LIVE, not a value stored at setup time' {
        # Proves the probe is actually called: a harness that trusted a stored hwscan would pass this without ever
        # asking the machine it is standing on.
        $s = New-AgentStick
        Mock Get-LokiHardwareProfile { @{ TotalRamGB = 32.0; AvailableRamGB = 24.0; CpuName = 'x'; CpuCores = 8; Is64BitOs = $true } }
        Resolve-LokiEnginePreflight -AppRoot $s.AppRoot -Engine $s.Engine -Runtime $s.Runtime -Model $s.Model | Out-Null
        Should -Invoke Get-LokiHardwareProfile -Times 1 -Exactly
    }

    It 'an engine already serving from this stick is reported BEFORE anything else' {
        # It explains the port collision and the missing RAM that every later reason would blame on the machine.
        $s = New-AgentStick
        Mock Get-LokiEngineOrphan { @([pscustomobject]@{ Id = 4242 }) }
        Mock Get-LokiHardwareProfile { @{ TotalRamGB = 32.0; AvailableRamGB = 24.0; CpuName = 'x'; CpuCores = 8; Is64BitOs = $true } }
        $r = Resolve-LokiEnginePreflight -AppRoot $s.AppRoot -Engine $s.Engine -Runtime $s.Runtime -Model $s.Model
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'engine-already-running'
        $r.Pids | Should -Contain 4242
    }

    It 'a runtime the engine cannot load is refused before the Windows loader says something unactionable' {
        $s = New-AgentStick -NoRuntime
        Mock Get-LokiHardwareProfile { @{ TotalRamGB = 32.0; AvailableRamGB = 24.0; CpuName = 'x'; CpuCores = 8; Is64BitOs = $true } }
        $r = Resolve-LokiEnginePreflight -AppRoot $s.AppRoot -Engine $s.Engine -Runtime $s.Runtime -Model $s.Model
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'runtime-unavailable'
    }
}

Describe 'Stop-LokiEngineServer / Wait-LokiEngineReady' {

    It 'stopping is idempotent and true once the process is gone' {
        $p = [System.Diagnostics.Process]::Start('cmd.exe', '/c exit 0')
        $p.WaitForExit(10000) | Out-Null
        Stop-LokiEngineServer -Process $p | Should -BeTrue
        Stop-LokiEngineServer -Process $p | Should -BeTrue   # again: already dead is a success, not an error
        Stop-LokiEngineServer -Process $null | Should -BeTrue
    }

    It 'really kills a live process' {
        $p = [System.Diagnostics.Process]::Start('cmd.exe', '/c pause')
        try {
            $p.HasExited | Should -BeFalse
            Stop-LokiEngineServer -Process $p | Should -BeTrue
            $p.HasExited | Should -BeTrue
        }
        finally { if (-not $p.HasExited) { $p.Kill() } }
    }

    It 'an engine that DIES during load is reported as exited, not waited out to the timeout' {
        # The failure that matters most: a model too big for the machine crashes in seconds. Without watching the
        # process, that becomes a full timeout of silence and then the wrong diagnosis.
        $p = [System.Diagnostics.Process]::Start('cmd.exe', '/c exit 3')
        $p.WaitForExit(10000) | Out-Null
        $r = Wait-LokiEngineReady -Port 1 -Process $p -TimeoutSec 30
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'exited'
        $r.ExitCode | Should -Be 3
        $r.ElapsedMs | Should -BeLessThan 5000   # it did NOT sit out the 30s
    }

    It 'a live process that never serves /health times out (and says so)' {
        $p = [System.Diagnostics.Process]::Start('cmd.exe', '/c pause')
        try {
            $r = Wait-LokiEngineReady -Port (Get-LokiFreeLoopbackPort) -Process $p -TimeoutSec 2
            $r.Ok | Should -BeFalse
            $r.Reason | Should -Be 'timeout'
        }
        finally { if (-not $p.HasExited) { $p.Kill() } }
    }
}

Describe 'ConvertTo-LokiArgumentString (pure; Windows quoting)' {

    # NOT 'args' as the -ForEach key: $args is an AUTOMATIC PowerShell variable, so inside the It block Pester's own
    # bound parameters land in it and every case compares against the wrong input. It fails loudly here; in a test
    # that merely asserted "does not throw" it would have passed while testing nothing.
    It 'quotes <label> as <expected>' -ForEach @(
        @{ label = 'a plain flag'; argv = @('--jinja'); expected = '"--jinja"' }
        @{ label = 'a path with spaces'; argv = @('C:\Users\Chris Veit\m.gguf'); expected = '"C:\Users\Chris Veit\m.gguf"' }
        # The rule that bites: a trailing backslash would escape the closing quote, so the run is doubled.
        @{ label = 'a trailing backslash'; argv = @('C:\dir\'); expected = '"C:\dir\\"' }
        @{ label = 'two trailing backslashes'; argv = @('C:\dir\\'); expected = '"C:\dir\\\\"' }
        @{ label = 'an embedded quote'; argv = @('a"b'); expected = '"a\"b"' }
        @{ label = 'a backslash before a quote'; argv = @('a\"b'); expected = '"a\\\"b"' }
        @{ label = 'an empty argument'; argv = @(''); expected = '""' }
    ) {
        (ConvertTo-LokiArgumentString -ArgList $argv) | Should -Be $expected
    }

    It 'joins with spaces and keeps order' {
        (ConvertTo-LokiArgumentString -ArgList @('--port', '8080')) | Should -Be '"--port" "8080"'
    }
}

Describe 'Start-LokiEngineServer (argv and env survive a REAL process)' {

    BeforeAll {
        # A probe that parses its command line the way llama-server does -- i.e. with CommandLineToArgvW.
        # NOT cmd.exe: cmd's /c handling is its own non-standard parser, so a test written against it would be
        # measuring cmd rather than the quoting under test. Found the hard way; this note is the reason it stays.
        $script:EchoArgs = Join-Path $script:RootTmp 'echo-args.ps1'
        Set-Content -LiteralPath $script:EchoArgs -Encoding utf8 -Value @'
foreach ($a in $args) { Write-Output ("[" + $a + "]") }
Write-Output ("CANARY=[" + $env:LOKI_TEST_CANARY + "]")
'@
        $script:Ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }

    It 'a path with SPACES arrives as ONE argument' {
        $r = Start-LokiEngineServer -ServerExePath $script:Ps51 `
            -ArgList @('-NoProfile', '-File', $script:EchoArgs, 'C:\Users\Chris Veit\models\nano.gguf') `
            -ChildEnv @{ SystemRoot = $env:SystemRoot; PATH = $env:PATH }
        $r.Ok | Should -BeTrue
        $r.Process.WaitForExit(30000) | Out-Null
        $r.StdOut.Wait(5000) | Out-Null
        [string]$r.StdOut.Result | Should -Match '\[C:\\Users\\Chris Veit\\models\\nano\.gguf\]'
    }

    It 'a path ending in a BACKSLASH does not swallow the argument after it' {
        $r = Start-LokiEngineServer -ServerExePath $script:Ps51 `
            -ArgList @('-NoProfile', '-File', $script:EchoArgs, 'C:\dir\', 'SECOND') `
            -ChildEnv @{ SystemRoot = $env:SystemRoot; PATH = $env:PATH }
        $r.Process.WaitForExit(30000) | Out-Null
        $r.StdOut.Wait(5000) | Out-Null
        $text = [string]$r.StdOut.Result
        $text | Should -Match '\[C:\\dir\\\]'
        $text | Should -Match '\[SECOND\]'   # not eaten by an escaped quote
    }

    It 'the child gets EXACTLY the handed env block -- the parent''s value does not leak' {
        # The whole reason this uses ProcessStartInfo instead of Start-Process.
        $env:LOKI_TEST_CANARY = 'parent-value-that-must-not-leak'
        try {
            $r = Start-LokiEngineServer -ServerExePath $script:Ps51 `
                -ArgList @('-NoProfile', '-File', $script:EchoArgs) `
                -ChildEnv @{ SystemRoot = $env:SystemRoot; PATH = $env:PATH }
            $r.Process.WaitForExit(30000) | Out-Null
            $r.StdOut.Wait(5000) | Out-Null
            [string]$r.StdOut.Result | Should -Match 'CANARY=\[\]'
        }
        finally { Remove-Item Env:\LOKI_TEST_CANARY -ErrorAction SilentlyContinue }
    }

    It 'a handed variable DOES reach the child (the block is applied, not just emptied)' {
        # Without this, "the canary did not leak" would also pass if the env block were simply broken.
        $r = Start-LokiEngineServer -ServerExePath $script:Ps51 `
            -ArgList @('-NoProfile', '-File', $script:EchoArgs) `
            -ChildEnv @{ SystemRoot = $env:SystemRoot; PATH = $env:PATH; LOKI_TEST_CANARY = 'from-the-block' }
        $r.Process.WaitForExit(30000) | Out-Null
        $r.StdOut.Wait(5000) | Out-Null
        [string]$r.StdOut.Result | Should -Match 'CANARY=\[from-the-block\]'
    }

    It 'a missing executable is reported, not thrown' {
        $r = Start-LokiEngineServer -ServerExePath (Join-Path $script:RootTmp 'no-such-engine.exe') `
            -ArgList @('--model', 'x') -ChildEnv @{ }
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'server-exe-missing'
    }
}

Describe 'Get-LokiProcessOutputTail (turning "it died" into why)' {

    It 'returns the last lines of a completed pipe' {
        $t = [System.Threading.Tasks.Task]::FromResult("line1`nline2`nline3`nline4")
        (Get-LokiProcessOutputTail -Task $t -MaxLines 2) | Should -Be "line3`nline4"
    }

    It 'returns everything when there is less than MaxLines' {
        $t = [System.Threading.Tasks.Task]::FromResult("only one")
        (Get-LokiProcessOutputTail -Task $t -MaxLines 12) | Should -Be 'only one'
    }

    It 'drops blank lines rather than padding the tail with them' {
        # llama-server pads its output; a tail of 12 blank lines would be a worse answer than no tail.
        $t = [System.Threading.Tasks.Task]::FromResult("real`n`n`n`n")
        (Get-LokiProcessOutputTail -Task $t -MaxLines 3) | Should -Be 'real'
    }

    It 'never throws and never blocks on a pipe that is still open' {
        # The failure this guards: reading .Result on a live process hangs the tool forever, and it would hang in the
        # error path -- i.e. exactly when someone is already having a bad day.
        $tcs = New-Object 'System.Threading.Tasks.TaskCompletionSource[string]'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        (Get-LokiProcessOutputTail -Task $tcs.Task -TimeoutMs 300) | Should -Be ''
        $sw.ElapsedMilliseconds | Should -BeLessThan 3000
        (Get-LokiProcessOutputTail -Task $null) | Should -Be ''
        (Get-LokiProcessOutputTail -Task ([System.Threading.Tasks.Task]::FromResult(''))) | Should -Be ''
    }
}

Describe 'Invoke-LokiWithEngine (the no-leaked-process guarantee)' {

    It 'a failed preflight starts NOTHING' {
        $s = New-AgentStick -TamperEngine
        Mock Get-LokiHardwareProfile { @{ TotalRamGB = 32.0; AvailableRamGB = 24.0; CpuName = 'x'; CpuCores = 8; Is64BitOs = $true } }
        Mock Start-LokiEngineServer { throw 'must not be reached' }
        $r = Invoke-LokiWithEngine -AppRoot $s.AppRoot -Engine $s.Engine -Runtime $s.Runtime -Model $s.Model `
            -CtxSize 4096 -Threads 4 -Body { 'never' }
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'engine-unverified'
        Should -Invoke Start-LokiEngineServer -Times 0 -Exactly
    }

    It 'BREAK-THE-GUARD: a Body that THROWS still stops the engine' {
        # The reason Body is a parameter instead of something a caller sequences itself. A leaked llama-server is a
        # multi-GB process holding a model open on someone else's machine after the tool has exited.
        $s = New-AgentStick
        $fake = [pscustomobject]@{ Id = 1; HasExited = $false }
        Mock Get-LokiHardwareProfile { @{ TotalRamGB = 32.0; AvailableRamGB = 24.0; CpuName = 'x'; CpuCores = 8; Is64BitOs = $true } }
        Mock Start-LokiEngineServer {
            @{ Ok = $true; Reason = 'started'; Process = $fake
                StdOut = [System.Threading.Tasks.Task]::FromResult(''); StdErr = [System.Threading.Tasks.Task]::FromResult('')
            }
        }
        Mock Wait-LokiEngineReady { @{ Ok = $true; Reason = 'ready'; ElapsedMs = 10 } }
        Mock Stop-LokiEngineServer { $true }

        { Invoke-LokiWithEngine -AppRoot $s.AppRoot -Engine $s.Engine -Runtime $s.Runtime -Model $s.Model `
                -CtxSize 4096 -Threads 4 -Body { throw 'the body exploded' } } | Should -Throw 'the body exploded'
        Should -Invoke Stop-LokiEngineServer -Times 1 -Exactly
    }

    It 'an engine that never becomes ready is stopped, not abandoned' {
        $s = New-AgentStick
        $fake = [pscustomobject]@{ Id = 1; HasExited = $false }
        Mock Get-LokiHardwareProfile { @{ TotalRamGB = 32.0; AvailableRamGB = 24.0; CpuName = 'x'; CpuCores = 8; Is64BitOs = $true } }
        Mock Start-LokiEngineServer {
            @{ Ok = $true; Reason = 'started'; Process = $fake
                StdOut = [System.Threading.Tasks.Task]::FromResult(''); StdErr = [System.Threading.Tasks.Task]::FromResult('')
            }
        }
        Mock Wait-LokiEngineReady { @{ Ok = $false; Reason = 'timeout'; ElapsedMs = 300000 } }
        Mock Stop-LokiEngineServer { $true }

        $r = Invoke-LokiWithEngine -AppRoot $s.AppRoot -Engine $s.Engine -Runtime $s.Runtime -Model $s.Model `
            -CtxSize 4096 -Threads 4 -Body { 'never' }
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'engine-not-ready:timeout'
        # Stopped twice is fine and is the point: once to close the pipes so the log can be read, once by the finally.
        # Idempotence is what makes that safe, and 'at least once' is the property that matters.
        Should -Invoke Stop-LokiEngineServer -Times 1
    }

    It 'an engine that dies during load reports WHY, not just that it did' {
        # 'engine-not-ready:exited' alone is a dead end for whoever has to act on it. llama-server says what went
        # wrong on stderr -- a model too large, an unsupported quant, a dll it could not load -- and this is the only
        # place that answer survives, because the process is gone a line later.
        $s = New-AgentStick
        $fake = [pscustomobject]@{ Id = 1; HasExited = $true; ExitCode = 1 }
        Mock Get-LokiHardwareProfile { @{ TotalRamGB = 32.0; AvailableRamGB = 24.0; CpuName = 'x'; CpuCores = 8; Is64BitOs = $true } }
        Mock Start-LokiEngineServer {
            @{ Ok = $true; Reason = 'started'; Process = $fake
                StdOut = [System.Threading.Tasks.Task]::FromResult('')
                StdErr = [System.Threading.Tasks.Task]::FromResult("loading model`nerror: failed to allocate KV cache")
            }
        }
        Mock Wait-LokiEngineReady { @{ Ok = $false; Reason = 'exited'; ExitCode = 1; ElapsedMs = 900 } }
        Mock Stop-LokiEngineServer { $true }

        $r = Invoke-LokiWithEngine -AppRoot $s.AppRoot -Engine $s.Engine -Runtime $s.Runtime -Model $s.Model `
            -CtxSize 4096 -Threads 4 -Body { 'never' }
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Be 'engine-not-ready:exited'
        $r.EngineLog | Should -Match 'failed to allocate KV cache'
    }

    It 'the happy path hands Body a loopback base uri and returns its result' {
        $s = New-AgentStick
        $fake = [pscustomobject]@{ Id = 1; HasExited = $false }
        Mock Get-LokiHardwareProfile { @{ TotalRamGB = 32.0; AvailableRamGB = 24.0; CpuName = 'x'; CpuCores = 8; Is64BitOs = $true } }
        Mock Start-LokiEngineServer {
            @{ Ok = $true; Reason = 'started'; Process = $fake
                StdOut = [System.Threading.Tasks.Task]::FromResult(''); StdErr = [System.Threading.Tasks.Task]::FromResult('')
            }
        }
        Mock Wait-LokiEngineReady { @{ Ok = $true; Reason = 'ready'; ElapsedMs = 10 } }
        Mock Stop-LokiEngineServer { $true }

        $r = Invoke-LokiWithEngine -AppRoot $s.AppRoot -Engine $s.Engine -Runtime $s.Runtime -Model $s.Model `
            -CtxSize 4096 -Threads 4 -Body { param($ctx) $ctx.BaseUri }
        $r.Ok | Should -BeTrue
        $r.Result | Should -BeLike 'http://127.0.0.1:*'
        Should -Invoke Stop-LokiEngineServer -Times 1 -Exactly
    }
}
