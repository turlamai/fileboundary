# Approved controlled encrypted/plaintext test twins

**Current repository fixtures:** Only the owner-approved DOCX encrypted/plaintext pair from [ADR-0004](../../../docs/decisions/ADR-0004-real-sample-twin-pair-and-deferred-removal.md), pinned in [baseline.json](baseline.json).

| Specimen | Purpose |
| --- | --- |
| `encrypted-sample.docx` | Wrapped sample expected to classify as `encrypted-recognized` |
| `plaintext-sample.docx` | Independent, already-plaintext control for the same synthetic content |

The previous large personal PDF specimen was **removed from the current tracked tree** under [ADR-0005](../../../docs/decisions/ADR-0005-personal-pdf-removed-from-head.md). Ordinary deletion does not purge the historical Git blob; [Issue #23](https://github.com/turinglambdaai/fileboundary/issues/23) tracks separately coordinated history removal. Do not fetch that historical specimen for new builds.

Tests use `baseline.json` for SHA-256 and classification only. They never decrypt. A matching plaintext fingerprint without independent format and reader evidence remains `unverified`.

Never add real protected documents without another explicit security review and owner approval. Do not attach these fixtures or their content to issues, logs, releases, or exports.
