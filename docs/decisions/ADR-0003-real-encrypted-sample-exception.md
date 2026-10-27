# ADR-0003: One-time exception — commit a real encrypted specimen as a fixture

- **Status:** accepted
- **Date:** 2026-10-27
- **Deciders:** owner (turinglambdaai), explicit approval in session

## Context

The owner provided a real encrypted file ("说给对方听.pdf" from the operator machine's Downloads) to serve as a test specimen. Inspection (measured evidence): 26,516,346 bytes; SHA-256 `3d91c88f9d089d59e6e993849327b6ef97609fb200a7c7399e6f7b3b542338e1`; header magic `62 14 23 65 9b 00 65 01` with ASCII markers `E-SafeNet` and `LOCK` (a commercial transparent-encryption wrapper); no `%PDF-` markers anywhere; body entropy 7.997 bits/byte across three sample offsets. The file is genuine ciphertext of a personal document in a recognizable wrapper — exactly the real-world condition the inventory classifier ([#4](https://github.com/turinglambdaai/fileboundary/issues/4)) must handle.

[ADR-0001](ADR-0001-project-scope-and-boundaries.md) and [`AGENTS.md`](../../AGENTS.md) prohibit committing real encrypted production files or personal data; [docs/testing.md](../testing.md) requires synthetic-only fixtures.

## Decision

Commit this **one** file as `tests/fixtures/real-samples/esafenet-locked-sample.pdf` (ASCII fixture name; original filename recorded in `baseline.json`), with pinned baseline metadata, as a **file-specific exception** to the synthetic-only rule:

1. The exception is pinned by the file's SHA-256 above. It covers this file and nothing else.
2. It does not generalize. Any future real sample defaults back to the charter rule (metadata-only, content stays on the operator machine, per [docs/testing.md](../testing.md) round-trip-baseline pattern) unless a superseding ADR is accepted.
3. The sidecar `baseline.json` pins hash, size, wrapper signature, entropy samples, and the expected classification (`encrypted-recognized`, never `plaintext`), so tests assert against evidence rather than a loose binary blob.
4. Alternatives (metadata-only baseline; synthetic analog with the same signature) were offered and the owner explicitly chose committing the real file, acknowledging the ciphertext of a personal document enters git history and GitHub storage.

## Consequences

- A 25.3 MB binary enters git history permanently; removal later would require history rewrite and does not undo the upload.
- Risk accepted: the file is ciphertext of a personal document. Mitigations: repository stays private and unlicensed ([ADR-0001](ADR-0001-project-scope-and-boundaries.md)); the file must not be redistributed or attached to issues.
- Documentation updated in the same commit: [`AGENTS.md`](../../AGENTS.md) fixture bullet, [docs/testing.md](../testing.md) fixtures section, [docs/security.md](../security.md) repository-hygiene bullet now reference this exception.
- Tests consuming this fixture must re-hash against `baseline.json` before use and treat any mismatch as a diagnostic finding (possible re-encryption on copy), never silently proceed.

## Scope of effect

`tests/fixtures/real-samples/` (README, baseline.json, the specimen), [`AGENTS.md`](../../AGENTS.md), [docs/testing.md](../testing.md), [docs/security.md](../security.md), this ADR.
