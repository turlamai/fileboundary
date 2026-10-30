# ADR-0007: Real wrapped specimens admitted as decryption test fixtures

- **Status:** accepted
- **Date:** 2026-10-30
- **Deciders:** owner (turinglambdaai), explicit directive in session
- **Supersedes:** [ADR-0005](ADR-0005-personal-pdf-removed-from-head.md) (removal decision only — the specimen is now a wanted test asset; history purge under [#23](https://github.com/turinglambdaai/fileboundary/issues/23) is mooted for this blob)
- **Relates to:** [ADR-0006](ADR-0006-adversarial-recovery-mandate.md), [../adversarial-research.md](../adversarial-research.md)

## Context

The T0 break (ADR-0006 mandate) produced a complete offline decryption
pipeline whose correctness depends on real wrapped specimens. The owner
directively supplied two encrypted files from the operator machine as test
cases: the 25 MB courseware PDF (byte-identical to the ADR-0003 specimen,
SHA-256 `3d91c88f…`) and a 2.9 MB wrapped XLSX. Both were decrypted
successfully end-to-end; the encrypted wrappers are now committed as pinned
fixtures so the pipeline stays regression-tested against real-world data.

## Decision

1. `research/t0/fixtures/` holds real **encrypted** specimens as pinned
   decryption test cases: `esafenet-wrapped-courseware.pdf`,
   `esafenet-wrapped-radar-motor-sheet.xlsx`, with `fixtures.json` pinning
   size, SHA-256, wrapper magic and zone/tail layout per file.
2. This reverses ADR-0005's removal of the personal PDF specimen: the file
   is intentionally in the active tree again, under a research-owned path.
3. **Decrypted outputs are still barred from the repository** — they stay
   in the operator-designated artifacts directory. Only ciphertext is
   committed.
4. Containment note: `research/t0/pad_full.json` (the policy pad —
   effectively a recovery key for this policy) is deliberately kept in the
   repository by owner decision: the repository is private and internal-
   use (ADR-0001 clause 1), and the pad is useless without the wrapped
   files and indicates nothing about keys on other policies.

## Consequences

- The decryption pipeline can be regression-tested in CI against real
  wrappers (size + SHA-256 + magic asserts; full decryption runs stay
  operator-side because they write artifacts outside the repo).
- ADR-0003's archived status and ADR-0005 stand as history; this ADR
  governs the current state of the specimen.
- Issue [#23](https://github.com/turinglambdaai/fileboundary/issues/23)
  scope shrinks to "archive hygiene" — the blob is intentionally retained.

## Scope of effect

`research/t0/fixtures/`, `research/t0/README.md`, this ADR, ADR index.
