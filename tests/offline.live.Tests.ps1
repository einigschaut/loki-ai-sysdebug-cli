# tests/offline.live.Tests.ps1 -- the ONE real-engine run for `offline --analyze` (ADR-0015 section 6, CLAUDE.md 6:
# "the real engine starts at least once for real"). Every other offline test mocks the harness; this one does not.
#
# OPT-IN, because it starts a multi-GB llama-server and loads a real model -- it must never run in CI or slow the
# default gate. It SKIPS unless BOTH are set:
#     $env:LOKI_LIVE_OFFLINE = '1'
#     $env:LOKI_LIVE_STICK   = <path to a real Loki stick with the engine + Qwen3-4B installed>
#
# The RAM-fit verdict is the ONE thing stubbed (Get-LokiTierFit -> fits), exactly as ADR-0015's live-gate did: the
# 25%-of-installed reserve is a DESIGN.md/ADR-0013 question, not this slice's, and on a healthy dev box it refuses
# the small tier by a few hundred MB while the machine can plainly run it. Everything else is REAL -- the integrity
# preflight (engine + model hashed against their pins), the runtime check, the model load, the chat, the clean kill.
Set-StrictMode -Version Latest

BeforeAll {
    # The full lib graph, like the dispatcher loads it -- the live path exercises the real Resolve-LokiEnginePreflight
    # and everything under it, so nothing may be mocked away except the one RAM verdict below.
    Get-ChildItem "$PSScriptRoot\..\src\lib" -Filter *.ps1 | ForEach-Object { . $_.FullName }
    Initialize-LokiI18n -AppRoot (Resolve-Path "$PSScriptRoot\..\src").Path -Locale 'en' | Out-Null

    $script:liveStick = [string]$env:LOKI_LIVE_STICK
    $script:liveOn = ($env:LOKI_LIVE_OFFLINE -eq '1') -and (-not [string]::IsNullOrWhiteSpace($script:liveStick)) -and
        (Test-Path -LiteralPath $script:liveStick)

    # --- Minimal GGUF header reader (test-only), for the ADR-0025 cross-check: prove the manifest's pinned KV geometry
    # matches the geometry the SHIPPING model file actually declares. We read only the metadata KV section (near the
    # file start), skipping every value type -- including arrays -- so we can walk to the keys we need.
    function global:Read-LokiGgufString($reader) {
        $len = $reader.ReadUInt64()
        return [System.Text.Encoding]::UTF8.GetString($reader.ReadBytes([int]$len))
    }
    function global:Read-LokiGgufValue($reader, [uint32]$type) {
        switch ($type) {
            0  { return [long]$reader.ReadByte() }
            1  { return [long]$reader.ReadSByte() }
            2  { return [long]$reader.ReadUInt16() }
            3  { return [long]$reader.ReadInt16() }
            4  { return [long]$reader.ReadUInt32() }
            5  { return [long]$reader.ReadInt32() }
            6  { [void]$reader.ReadSingle(); return $null }
            7  { return [long]$reader.ReadByte() }
            8  { return (Read-LokiGgufString $reader) }
            9  { $et = $reader.ReadUInt32(); $n = $reader.ReadUInt64(); for ($i = 0; $i -lt [long]$n; $i++) { [void](Read-LokiGgufValue $reader $et) }; return $null }
            10 { return [long]$reader.ReadUInt64() }
            11 { return [long]$reader.ReadInt64() }
            12 { [void]$reader.ReadDouble(); return $null }
            default { throw "GGUF: unknown value type $type" }
        }
    }
    function global:Read-LokiGgufKvGeometry {
        param([Parameter(Mandatory = $true)][string]$Path)
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'Read')
        $br = New-Object System.IO.BinaryReader($fs)
        $vals = @{}
        try {
            $magic = [System.Text.Encoding]::ASCII.GetString($br.ReadBytes(4))
            if ($magic -ne 'GGUF') { throw "not a GGUF file: $Path" }
            [void]$br.ReadUInt32()      # version
            [void]$br.ReadUInt64()      # tensor count
            $kvCount = $br.ReadUInt64()
            for ($k = 0; $k -lt [long]$kvCount; $k++) {
                $key = Read-LokiGgufString $br
                $vt = $br.ReadUInt32()
                $vals[$key] = Read-LokiGgufValue $br $vt
            }
        }
        finally { $br.Close(); $fs.Close() }
        $layers = $null; $kvh = $null; $keylen = $null; $emb = $null; $heads = $null
        foreach ($kk in $vals.Keys) {
            if ($kk -like '*.block_count') { $layers = [int]$vals[$kk] }
            elseif ($kk -like '*.attention.head_count_kv') { $kvh = [int]$vals[$kk] }
            elseif ($kk -like '*.attention.key_length') { $keylen = [int]$vals[$kk] }
            elseif ($kk -like '*.embedding_length') { $emb = [int]$vals[$kk] }
            elseif ($kk -like '*.attention.head_count') { $heads = [int]$vals[$kk] }
        }
        # HeadDim is key_length when the model declares it, else embedding_length / head_count -- exactly how llama.cpp
        # derives it (this is the same fallback the manifest values were pinned with).
        $headDim = $keylen
        if (($null -eq $headDim) -and ($null -ne $emb) -and ($null -ne $heads) -and ($heads -gt 0)) { $headDim = [int]($emb / $heads) }
        return @{ Layers = $layers; KVHeads = $kvh; HeadDim = $headDim }
    }
}

AfterAll {
    Remove-Item Function:\Read-LokiGgufString -ErrorAction SilentlyContinue
    Remove-Item Function:\Read-LokiGgufValue -ErrorAction SilentlyContinue
    Remove-Item Function:\Read-LokiGgufKvGeometry -ErrorAction SilentlyContinue
}

Describe 'offline --analyze against the REAL engine (opt-in; ADR-0015 section 6)' {
    It 'loads Qwen3-4B, analyzes a real dump, returns a verdict, and leaves ZERO orphans' {
        if (-not $script:liveOn) {
            Set-ItResult -Skipped -Because 'opt-in: set LOKI_LIVE_OFFLINE=1 and LOKI_LIVE_STICK=<real stick> to run it'
            return
        }
        # Stub ONLY the RAM-fit verdict (ADR-0015). Integrity, runtime, model load, chat and kill all stay real.
        Mock Get-LokiTierFit { @{ Verdict = 'fits'; NeedFreeGB = 0 } }

        $engineData = Get-LokiEngineManifest -Path (Join-Path $script:liveStick 'engine\manifest.psd1')
        $models = Get-LokiModelManifest -Path (Get-LokiModelLayout -AppRoot $script:liveStick).ManifestPath
        $model = @($models) | Where-Object { $_.Id -eq 'small' } | Select-Object -First 1
        $model | Should -Not -BeNullOrEmpty -Because 'the small tier (Qwen3-4B) must be installed on the live stick'

        $serverExe = (Get-LokiEngineLayout -AppRoot $script:liveStick -Engine $engineData.Engine).ServerExePath
        @(Get-LokiEngineOrphan -ServerExePath $serverExe).Count |
            Should -Be 0 -Because 'no engine from this stick may already be running when the test starts'

        # A realistic multi-battery dump (what the real collector renders), carrying an unambiguous C: fault so the
        # run is a plausible analyze -- but note the assertions below test the HARNESS, not the diagnosis.
        $dumpText = @'
loki collect -- raw diagnostic dump
  tool         : loki collect 0.9.1
  created      : 2026-07-18T09:00:00.0000000+02:00
  schema       : 1

[collected] os (120 ms)
  Caption            : Microsoft Windows 11 Pro
  UptimeHours        : 52.4

[collected] storage (100 ms)
  Disks:
    Drive              : C:
    SizeGB             : 476.3
    FreeGB             : 1.8
    PercentFree        : 0.4

    Drive              : D:
    SizeGB             : 931.5
    FreeGB             : 640.2
    PercentFree        : 68.7

[collected] network (90 ms)
  Reachable          : true
'@

        $res = Invoke-LokiOfflineAnalyze -AppRoot $script:liveStick -Engine $engineData.Engine `
            -Runtime $engineData.Runtime -Model $model -DumpText $dumpText -TimeoutSec 300

        $res.Ok | Should -BeTrue -Because ('the real engine should answer; got ' + ($res | ConvertTo-Json -Depth 4 -Compress))
        $res.Analysis | Should -Not -BeNullOrEmpty
        # This proves the ROUND-TRIP through the real engine, not the model's accuracy (that is the tier eval's job,
        # and coupling a harness test to what a model concludes on a given day makes it flaky). A well-formed contract
        # answer -- system prompt -> dump -> model -> the shape we asked for, parsed back -- is the bar here.
        $res.Analysis | Should -Match '(?i)VERDICT'
        $res.Analysis | Should -Match '(?i)CONFIDENCE'

        # THE guarantee this whole harness exists to make: no llama-server from this stick survives the call.
        @(Get-LokiEngineOrphan -ServerExePath $serverExe).Count |
            Should -Be 0 -Because 'Invoke-LokiWithEngine must clean-kill the engine in its finally block'
    }
}

Describe 'manifest KV geometry matches the installed GGUF headers (opt-in cross-check; ADR-0025)' {
    It 'every INSTALLED tier''s KVCache equals its GGUF header (block_count / head_count_kv / key_length)' {
        if (-not $script:liveOn) {
            Set-ItResult -Skipped -Because 'opt-in: set LOKI_LIVE_OFFLINE=1 and LOKI_LIVE_STICK=<real stick> to run it'
            return
        }
        # The manifest pins KV geometry from each model's config.json; this closes the loop against the SHIPPING file:
        # a wrong-low pin (the dangerous direction, it would over-fill KV-cache RAM) fails here the first time that
        # tier's GGUF is on a stick. Only tiers actually installed are checked -- an absent GGUF is not a failure.
        $layout = Get-LokiModelLayout -AppRoot $script:liveStick
        $models = Get-LokiModelManifest -Path $layout.ManifestPath
        $checked = 0
        foreach ($m in @($models)) {
            $gguf = Join-Path $layout.Dir ([string]$m.FileName)
            if (-not (Test-Path -LiteralPath $gguf)) { continue }
            $geom = Read-LokiGgufKvGeometry -Path $gguf
            $geom.Layers  | Should -Be ([int]$m.KVCache.Layers)  -Because ("Layers for tier '" + [string]$m.Id + "'")
            $geom.KVHeads | Should -Be ([int]$m.KVCache.KVHeads) -Because ("KVHeads for tier '" + [string]$m.Id + "'")
            $geom.HeadDim | Should -Be ([int]$m.KVCache.HeadDim) -Because ("HeadDim for tier '" + [string]$m.Id + "'")
            $checked++
        }
        $checked | Should -BeGreaterThan 0 -Because 'at least the small tier (Qwen3-4B) GGUF must be installed on the live stick'
    }
}
