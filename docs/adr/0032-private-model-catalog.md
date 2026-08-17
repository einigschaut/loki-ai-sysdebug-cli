# ADR-0032: A private model catalog beside the shipped one (bring your own model)

Status: Accepted (2026-08-17)

## Context

The shipped model catalog (`src/models/manifest.psd1`) is restricted to **Apache-2.0 / MIT** models. That is a
deliberate allow-list, the same philosophy as the command gate (ADR-0006): every user of the public supply chain
should inherit only irrevocable, self-contained, OSI-standard licences, and nobody downstream should have to perform a
per-model legal review.

The restriction has a cost, and the tier evaluation on 2026-08-17 made it concrete. `NVIDIA-Nemotron-Nano-12B-v2` was
the **second-best model in the whole field** -- correct diagnosis, four valid native tool calls -- but it ships under
the **NVIDIA Open Model License**, which is *revocable*, carries *externally updatable* "Trustworthy AI" terms, and
terminates on guardrail circumvention. Those properties are the opposite of Loki's pinned, fail-closed supply chain, so
the model cannot enter the shipped catalog no matter how well it performs.

A single operator, on their own machine, may still legitimately accept those terms. Today they cannot: there is one
catalog, and it is the public one.

A second observation shaped the design. `Get-LokiModelManifest` **never validated the licence value** -- `License` is a
required *field*, but its content is unchecked. The Apache/MIT rule lives in `tests/models.Tests.ps1` as an assertion
over the **shipped** manifest. So the licence gate is already exactly where it belongs, and nothing in the validator
needed loosening.

## Decision

**A private catalog, `models/manifest.local.psd1`, sits beside the shipped one and is merged into the tier list.**

- `Get-LokiModelLayout` exposes `LocalManifestPath` next to `ManifestPath`. One concept, one file name, valid both on a
  stick and in the checkout `loki setup` runs from.
- `Merge-LokiModelCatalog` (pure) combines the two and stamps every entry `Source = 'catalog' | 'local'`.
- `Get-LokiModelCatalog` is the raw primitive (throws, like `Get-LokiModelManifest`); `Read-LokiModelManifestSafe` gains
  an **optional** `-LocalPath`, so the change is additive and no existing caller breaks.
- `offline`, `hwscan`, `doctor --engine` and `setup` all load through it, so a private tier behaves like any other --
  including `setup --tier <own-id>`, which downloads and verifies it on the normal pinned path.
- `hwscan` names how many tiers came from the private catalog, and says the licences there are the operator's
  responsibility. An unexplained tier would be worse than no tier.

### What is NOT relaxed

**Private does not mean unchecked.** A local entry runs through the *same* fail-closed `Get-LokiModelManifest`: https
only, an immutable 40-hex huggingface revision (ADR-0026), a real 64-hex SHA256 (verified on download *and* before the
engine loads the weights, ADR-0012), a safe non-reserved filename, positive sizes, and true KV geometry (ADR-0025).

The single thing that does not apply is the Apache/MIT **test**, which covers the shipped manifest only. That is the
entire scope of this ADR, and it is why the licence decision -- and its consequences -- sit with the operator who wrote
the file.

### Protecting the public supply chain

- `manifest.local.psd1` is **gitignored**.
- `tests/models.Tests.ps1` asserts the repo contains **no** such file. A committed private catalog would push a
  non-Apache/MIT licence onto every downstream user -- precisely the failure this ADR must not enable. Belt and braces,
  because the cost of that mistake is borne by people who never made it.
- `src/models/manifest.local.example.psd1` (a template, not a catalog) documents the format and states the rules.

### Rejected alternatives

- **Loosen the licence gate to a broader allow-list.** Every added licence needs its own legal reading, and revocable
  terms would enter the public chain. The gate's value is that downstream never has to think about it.
- **A flag such as `--allow-any-license`.** A runtime switch that widens a supply-chain rule is exactly the shape that
  gets pasted into a script and forgotten. A file the operator must write by hand, on their own machine, is a
  deliberate act with a durable record.
- **Merge into one manifest with a per-entry "private" marker.** The shipped file is attested and reproducible; mixing
  operator content into it destroys that property.

## Consequences

- An operator can evaluate and run models outside Apache/MIT (Nemotron being the concrete driver) while the public
  supply chain stays 100 % Apache/MIT-clean and attestable.
- A **duplicate id across the two catalogs throws.** Letting one silently win would make the effective catalog depend on
  load order, and "which weights does that tier point at" must never be answered with a shrug.
- A local manifest that exists but is broken **fails the whole load** rather than being skipped -- quietly dropping the
  operator's own tiers would change which model runs without saying so.
- An absent local manifest is the normal case and behaves exactly as before this ADR.
- The private catalog is never attested. The verified-download and load-time-hash guarantees still hold for its entries;
  the provenance guarantee (a third party published these weights and anyone can check them) is weaker by construction,
  which is inherent to bringing your own model.
