# src/engine/manifest.psd1 -- the pinned OFFLINE ENGINE (data only; Import-PowerShellDataFile). ADR-0012.
# Validated fail-closed by Get-LokiEngineManifest (lib/engine.ps1) and fetched by lib/download.ps1.
#
# Why llama.cpp win-cpu-x64 (verified 2026-07-16, not assumed):
#   * MIT, ~18 MB, ships the OpenAI-compatible `llama-server`.
#   * ONE artifact fits any target CPU: the archive carries 15 ggml-cpu-<arch>.dll variants (sse42 ... zen4,
#     sapphirerapids) and ggml-base.dll selects at runtime -- so we never have to detect the CPU at download time.
#   * The archive is CODE we later execute, so Url/SizeBytes/Sha256 are pinned exactly like a model.
#
# How these values were pinned (reproducible, no hand-typing):
#   gh api repos/ggml-org/llama.cpp/releases/tags/b10038 --jq '.assets[] | {name,size,digest}'
#   -> the GitHub release API returns `digest: "sha256:..."` per asset = the SHA256 of the file. Re-verified here
#      by downloading the asset and comparing Get-FileHash: match.
# To bump the engine: re-run the command above for the new tag and replace Version/Url/FileName/Sha256/SizeBytes
# together. Never hand-edit a hash on its own.
@{
    Engine  = @{
        Id        = 'llama.cpp'
        Version   = 'b10038'
        Platform  = 'win-cpu-x64'
        License   = 'MIT'
        Url       = 'https://github.com/ggml-org/llama.cpp/releases/download/b10038/llama-b10038-bin-win-cpu-x64.zip'
        FileName  = 'llama-b10038-bin-win-cpu-x64.zip'
        Sha256    = '873ac4411cd28da67ea8ce55ec1c1b0fe25a6ed4d0b657e998f15406a0d55332'
        SizeBytes = 18418645
        ServerExe = 'llama-server.exe'
    }

    # The MSVC C/C++ runtime the engine imports and Windows does NOT ship. Verified by reading the PE import strings
    # of llama-server.exe / llama-server-impl.dll / ggml-*.dll from the pinned archive (2026-07-16):
    #   needed + missing from Windows : VCRUNTIME140.dll, VCRUNTIME140_1.dll, MSVCP140.dll
    #   needed + part of Windows 10/11: api-ms-win-crt-*.dll (the Universal CRT / ucrtbase.dll)
    #   needed + inside the archive   : libomp140.x86_64.dll
    # Loki NEVER distributes the Microsoft files: Microsoft limits distribution of the redistributable binaries to
    # licensed Visual Studio users. `loki setup --stage-runtime` copies them from the OPERATOR's own machine onto the
    # OPERATOR's own stick (app-local deployment, which Microsoft documents as supported). See ADR-0012.
    Runtime = @{
        Files       = @('VCRUNTIME140.dll', 'VCRUNTIME140_1.dll', 'MSVCP140.dll')
        # Conservative floor. Microsoft: "the latest Redistributable is binary compatible with previous versions back
        # to 2015" -> a NEWER runtime than the engine was built against is always safe, an OLDER one can be missing
        # exports. 14.30 is the Visual Studio 2022 (v143 toolset) baseline. We refuse to stage anything below it
        # rather than let the engine fail later with a cryptic loader error. (The PE linker field reads a generic
        # "14.0" on these binaries and is NOT a usable signal -- checked, so it is deliberately not used.)
        MinVersion  = '14.30'
        # Documented by Microsoft as the place to read the installed redistributable version on the target.
        RegistryKey = 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'
    }
}
