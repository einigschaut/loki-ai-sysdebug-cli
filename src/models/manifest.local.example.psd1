# manifest.local.example.psd1 -- TEMPLATE for a private "bring your own model" catalog (issue #103).
#
# WHAT THIS IS
#   Loki's shipped catalog (manifest.psd1) is deliberately restricted to Apache-2.0 / MIT models, so that every user of
#   the public supply chain inherits only irrevocable, self-contained, OSI-standard licences. Some models are permissive
#   in practice but do not carry one of those two licences -- NVIDIA's Nemotron family, for example, ships under the
#   NVIDIA Open Model License, which is revocable and carries externally updatable terms. Those cannot enter the shipped
#   catalog. A single operator may still legitimately accept such terms FOR THEIR OWN stick.
#
# HOW TO USE IT
#   1. Copy this file to  models\manifest.local.psd1  (on your stick, and/or in the checkout you run `loki setup` from).
#   2. Fill in one entry per model. Every field is required -- the same validator that guards the shipped catalog runs
#      over this file.
#   3. `loki setup --tier <your-id>` then downloads and verifies it exactly like a shipped tier.
#
#   `manifest.local.psd1` is gitignored and must NEVER be committed: it may name a model whose licence the public
#   supply chain must not carry. Its entries are shown by `loki hwscan` as coming from your own catalog.
#
# WHAT IS *NOT* RELAXED HERE
#   Private does not mean unchecked. A local entry is held to exactly the same rules as a shipped one:
#     * Url must be https, and a huggingface.co Url must pin an immutable 40-hex revision (never /resolve/main/)
#     * Sha256 must be the real 64-hex digest of the file -- it is verified on download AND before the engine loads it
#     * FileName must be a safe, non-reserved name (no path separators, no traversal)
#     * SizeBytes / ResidentGB / ContextTokens must be positive, and ResidentGB must exceed the on-disk size
#     * KVCache must carry the model's true attention geometry (a wrong-low value over-fills RAM: ADR-0025)
#   The ONE thing that does not apply here is the Apache/MIT licence assertion -- and therefore the licence decision,
#   and its consequences, are yours.
#
#   Ids must not collide with the shipped catalog (nano/small/mid/large/max...). A duplicate id fails fail-closed
#   rather than letting load order decide which weights a tier points at.
@{
    Models = @(
        @{
            Id            = 'byo-example'                  # your own id -- must not collide with a shipped tier
            Model         = 'Vendor Model Name 9B'
            Tier          = 'byo'
            License       = 'CHANGE-ME (e.g. NVIDIA Open Model License) -- yours to accept'
            Url           = 'https://huggingface.co/<org>/<repo>/resolve/0000000000000000000000000000000000000000/model-Q4_K_M.gguf'
            FileName      = 'model-Q4_K_M.gguf'
            Sha256        = '0000000000000000000000000000000000000000000000000000000000000000'
            SizeBytes     = 1
            ResidentGB    = 1.0
            ContextTokens = 4096
            KVCache       = @{ Layers = 1; KVHeads = 1; HeadDim = 1 }
        }
    )
}
