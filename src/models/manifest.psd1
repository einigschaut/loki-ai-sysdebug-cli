# src/models/manifest.psd1 -- offline model catalog (data-only, Import-PowerShellDataFile). ASCII -> no BOM.
#
# The single source of truth for `loki setup`: which GGUF models Loki can fetch onto the stick, one per
# performance tier, ALL freely licensed (Apache-2.0 / MIT). Each entry pins the exact download URL, byte SIZE, and
# SHA256 so the downloader can verify integrity (security core, ADR-0011) -- a mismatch is rejected, never run.
#
# PROVENANCE (how the Sha256/SizeBytes were pinned -- reproducible, NOT hand-guessed): the values are the
# Hugging Face LFS object id + size, read live from the HF tree API. To re-verify any entry:
#   (Invoke-RestMethod "https://huggingface.co/api/models/<repo>/tree/main" |
#      Where-Object path -match 'Q4_K_M.*\.gguf$') | Select-Object path, size, @{n='sha256';e={$_.lfs.oid}}
# The LFS oid IS the sha256 of the file content, so downloading + hashing yields the same value.
#
# Quant = Q4_K_M throughout (community size/quality knee; best fit for CPU diagnostics). Model picks are the
# best-in-class FREE model per size class as of 2026-07 (see ADR-0011 for the benchmark rationale + alternates).
@{
    Models = @(
        @{
            Id            = 'nano'
            Model         = 'Qwen3-1.7B'
            Tier          = 'Nano'
            License       = 'Apache-2.0'
            Url           = 'https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M.gguf'
            FileName      = 'Qwen3-1.7B-Q4_K_M.gguf'
            Sha256        = 'b139949c5bd74937ad8ed8c8cf3d9ffb1e99c866c823204dc42c0d91fa181897'
            SizeBytes     = 1107409472
            MinRamGB      = 2.5
            ContextTokens = 32768
            Default       = $false
            Note          = 'Low-RAM fallback. Universal llama.cpp support (pure transformer).'
        },
        @{
            Id            = 'small'
            Model         = 'Qwen3-4B-Instruct-2507'
            Tier          = 'Small'
            License       = 'Apache-2.0'
            Url           = 'https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf'
            FileName      = 'Qwen3-4B-Instruct-2507-Q4_K_M.gguf'
            Sha256        = '3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597'
            SizeBytes     = 2497281120
            MinRamGB      = 4.5
            ContextTokens = 262144
            Default       = $true
            Note          = 'Recommended default. Best small free model; non-thinking (concise); 262K context.'
        },
        @{
            Id            = 'mid'
            Model         = 'Qwen3-8B'
            Tier          = 'Mid'
            License       = 'Apache-2.0'
            Url           = 'https://huggingface.co/unsloth/Qwen3-8B-GGUF/resolve/main/Qwen3-8B-Q4_K_M.gguf'
            FileName      = 'Qwen3-8B-Q4_K_M.gguf'
            Sha256        = '120307ba529eb2439d6c430d94104dabd578497bc7bfe7e322b5d9933b449bd4'
            SizeBytes     = 5027784512
            MinRamGB      = 7.0
            ContextTokens = 32768
            Default       = $false
            Note          = 'Higher-accuracy mid tier. Best verified free ~8B (IFEval/MMLU-Pro).'
        },
        @{
            Id            = 'large'
            Model         = 'Phi-4'
            Tier          = 'Large'
            License       = 'MIT'
            Url           = 'https://huggingface.co/bartowski/phi-4-GGUF/resolve/main/phi-4-Q4_K_M.gguf'
            FileName      = 'phi-4-Q4_K_M.gguf'
            Sha256        = '009aba717c09d4a35890c7d35eb59d54e1dba884c7c526e7197d9c13ab5911d9'
            SizeBytes     = 9053114816
            MinRamGB      = 12.0
            ContextTokens = 16384
            Default       = $false
            Note          = 'Best reasoning-per-token at 14B (MIT). 16K context -> chunk long logs.'
        },
        @{
            Id            = 'large-longctx'
            Model         = 'Qwen3-14B'
            Tier          = 'Large (long context)'
            License       = 'Apache-2.0'
            Url           = 'https://huggingface.co/bartowski/Qwen_Qwen3-14B-GGUF/resolve/main/Qwen_Qwen3-14B-Q4_K_M.gguf'
            FileName      = 'Qwen_Qwen3-14B-Q4_K_M.gguf'
            Sha256        = '915913e22399475dbe6c968ac014d9f1fbe08975e489279aede9d5c7b2c98eb6'
            SizeBytes     = 9001753632
            MinRamGB      = 12.0
            ContextTokens = 131072
            Default       = $false
            Note          = 'Large alternative for long / German logs (131K context, Apache).'
        },
        @{
            Id            = 'max'
            Model         = 'Mistral-Small-24B-2501'
            Tier          = 'Max'
            License       = 'Apache-2.0'
            Url           = 'https://huggingface.co/bartowski/Mistral-Small-24B-Instruct-2501-GGUF/resolve/main/Mistral-Small-24B-Instruct-2501-Q4_K_M.gguf'
            FileName      = 'Mistral-Small-24B-Instruct-2501-Q4_K_M.gguf'
            Sha256        = 'd1a6d049f09730c3f8ba26cf6b0b60c89790b5fdafa9a59c819acdfe93fffd1b'
            SizeBytes     = 14333908672
            MinRamGB      = 18.0
            ContextTokens = 32768
            Default       = $false
            Note          = 'Practical CPU ceiling: text-only 24B, top instruction-following (IFEval 82.9), Apache.'
        },
        @{
            Id            = 'max-ceiling'
            Model         = 'Qwen3-32B'
            Tier          = 'Max (32B ceiling)'
            License       = 'Apache-2.0'
            Url           = 'https://huggingface.co/bartowski/Qwen_Qwen3-32B-GGUF/resolve/main/Qwen_Qwen3-32B-Q4_K_M.gguf'
            FileName      = 'Qwen_Qwen3-32B-Q4_K_M.gguf'
            Sha256        = 'e41ec56ddd376963a116da97506fadfccb50fb402bb6f3cb4be0bc179a582bd6'
            SizeBytes     = 19762149696
            MinRamGB      = 24.0
            ContextTokens = 32768
            Default       = $false
            Note          = 'Highest free reasoning ceiling. Slow on CPU (~1-2 tok/s); needs ~24-32 GB RAM.'
        }
    )
}
