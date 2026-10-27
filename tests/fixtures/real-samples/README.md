# Real samples

This directory holds **real-world encrypted specimens** — the one recorded exception to the synthetic-only fixture rule ([ADR-0003](../../../docs/decisions/ADR-0003-real-encrypted-sample-exception.md), owner-approved 2026-10-27). The exception is file-specific: it covers exactly the file pinned by `baseline.json` and does not generalize.

## Specimen: `esafenet-locked-sample.pdf`

A real encrypted file from the operator's machine, in the transparent-encryption wrapper form that FileBoundary targets. The `.pdf` extension is intentional and preserved from the real condition: **the file is not a PDF on disk** — this extension/structure mismatch is precisely what the classifier must handle without ever claiming `plaintext` from an extension.

All evidence below is `measured` (read-only inspection, 2026-10-27; pinned in [baseline.json](baseline.json)):

| Property | Value |
|---|---|
| Size | 26,516,346 bytes (~25.3 MB) |
| SHA-256 | `3d91c88f9d089d59e6e993849327b6ef97609fb200a7c7399e6f7b3b542338e1` |
| Header magic (first 8 bytes) | `62 14 23 65 9b 00 65 01` |
| ASCII markers in header | `E-SafeNet`, `LOCK` (commercial transparent-encryption wrapper signature) |
| `%PDF-` markers | absent from the entire file — no plaintext PDF structure on disk |
| Body entropy | 7.997 bits/byte (Shannon, 64 KiB samples at 1 MiB / 8 MiB / 20 MiB offsets) — ciphertext-grade |
| Expected classification | `encrypted-recognized` (known wrapper identified) |

Integrity note: the copy committed here was verified byte-identical to the original immediately after copying (same SHA-256) — the transparent-encryption layer did not re-encrypt the copy on write to the repository working tree.

## How to use

- **Classifier tests (#4)**: the scanner must classify this file `encrypted-recognized`, must not emit `plaintext`, and the classification must be driven by the wrapper signature and entropy — never by the `.pdf` extension.
- **Baseline comparison**: before use, re-hash the fixture and compare against `baseline.json.sha256`; on mismatch, stop and treat it as a diagnostic finding (possible re-encryption on copy), never silently proceed.
- **Recovery verification (#5)**: this is a candidate for the operator-machine manual protocol as a real specimen; verdicts follow [docs/security.md](../../../docs/security.md#integrity-semantics).

## Warnings

- This is the ciphertext of a real personal document. The repository is private and unlicensed; do not redistribute the file or its decrypted form.
- This file must never be committed anywhere else, embedded in reports, or attached to issues.
