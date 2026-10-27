# Real samples

This directory holds **real-world specimens** — the recorded exception to the synthetic-only fixture rule, owner-approved and pinned by SHA-256. Two authorizations currently apply:

- **[ADR-0004](../../../docs/decisions/ADR-0004-real-sample-twin-pair-and-deferred-removal.md)** — the controlled encrypted/plaintext twin pair below (`baseline-twins.json`).
- **[ADR-0003](../../../docs/decisions/ADR-0003-real-encrypted-sample-exception.md)** — a single encrypted PDF specimen (`baseline.json`); the owner has requested its removal, deferred and coordinated under ADR-0004.

The exception is file-specific (each specimen pinned by SHA-256) and does not generalize.

## Twin pair: `encrypted-sample.docx` / `plaintext-sample.docx` (ADR-0004)

A controlled pair built by the owner on the operator machine: **the same logical content (`123 abc`) saved twice** — once through the transparent-encryption mechanism (wrapped on disk) and once as plaintext. The plaintext twin is the ground truth that makes this pair usable for classification tests *and* recovery round-trip verification.

All evidence below is `measured` (read-only inspection + copy verification, 2026-10-27; pinned in [baseline-twins.json](baseline-twins.json)):

| Property | `encrypted-sample.docx` | `plaintext-sample.docx` |
|---|---|---|
| Size | 12,111 bytes | 10,198 bytes |
| SHA-256 | `ea2eb7d89667e115f7edf217d853955dda49c0b4a35bfe8ebbba2699d9979ccd` | `9526968c5da4980e838c96085cff735947ffe90b41a0c929827b926f97d30272` |
| On-disk header | magic `62 14 23 65 bc 01 44 00`, ASCII markers `E-SafeNet`, `LOCK` | `PK\x03\x04` — valid OOXML (ZIP) container |
| ZIP (`PK`) structures visible | **none** (0 occurrences in the entire file) | yes, full entry listing incl. `word/document.xml` |
| Entropy (whole file, Shannon) | 7.899 bits/byte | 7.759 bits/byte |
| Expected classification | `encrypted-recognized` | `plaintext` |

### What this pair teaches (measured, with classifier implications)

1. **The wrapper magic prefix is stable across file types.** Bytes 0–3 are `62 14 23 65` for both this docx and the PDF specimen below; ASCII markers `E-SafeNet` / `LOCK` and the 16-byte constant region at offset 0x28 (`bd41a84053766b3b8a061e67576e926d`) also match. Bytes 4–7 differ per file (`9b006501` PDF vs `bc014400` docx) — semantic unknown, possibly type/version metadata (inferred, unverified).
2. **Entropy alone cannot classify OOXML.** The *plaintext* docx measures 7.759 bits/byte because ZIP/DEFLATE compression is already near-ciphertext entropy. The discriminator for wrapped OOXML is the wrapper signature and the absence of container structure, never entropy, and never the extension.
3. **Copy integrity held:** both copies were re-hashed identical to their sources immediately after copying into the repository working tree — the transparent-encryption layer did not re-encrypt the copies on write to the repository working tree.

## Single specimen: `esafenet-locked-sample.pdf` (ADR-0003 — removal deferred)

A real encrypted PDF from the operator machine: 26,516,346 bytes, SHA-256 `3d91c88f9d089d59e6e993849327b6ef97609fb200a7c7399e6f7b3b542338e1`, same E-SafeNet/LOCK wrapper, no plaintext PDF structure on disk, body entropy 7.997 bits/byte. Pinned in [baseline.json](baseline.json); `tests/real-wrapper-baseline-test.rkt` asserts it read-only. **The owner has requested this specimen's removal**; the removal is deferred because main gained dependent work (#18, draft PR #20) and must land as a coordinated history purge per [ADR-0004](../../../docs/decisions/ADR-0004-real-sample-twin-pair-and-deferred-removal.md). Until then it stays pinned and tested.

## How to use

- **Classifier tests (#4)**: wrapped specimens must classify `encrypted-recognized` (driven by wrapper signature, not extension — both `.pdf`/`.docx` names are not their claimed formats on disk); the plaintext twin must classify `plaintext` via end-to-end OOXML validation. Neither may be classified by entropy alone.
- **Recovery round-trip (#5)**: recovering the encrypted twin through an authorized path should produce content containing the fingerprint `123 abc`. The strongest outcome is byte-identity with `plaintext-sample.docx`; because vendor export may rewrite container metadata, **semantic verification (fingerprint present + OOXML validates) is the required check**, byte-identity is a bonus signal. Never promote `unverified` on byte-identity alone being absent.
- **Baseline comparison**: re-hash fixtures against their baseline before use; on mismatch, stop and treat as a diagnostic finding, never silently proceed.

## Warnings

- The repository is private and unlicensed; do not redistribute these files outside the owner's control.
- Real specimens must never be attached to issues, pasted into reports, or committed anywhere else.
