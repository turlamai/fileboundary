# ADR-0004: Controlled encrypted/plaintext twin pair; removal of the ADR-0003 specimen deferred

- **Status:** accepted
- **Date:** 2026-10-27
- **Deciders:** owner (turlamai), explicit approval in session
- **Relates to:** [ADR-0003](ADR-0003-real-encrypted-sample-exception.md)

## Context

The owner built a controlled pair on the operator machine — the same logical content (`123 abc`) saved twice, once through the transparent-encryption mechanism and once as plaintext — and asked for (1) the pair to be committed and (2) the ADR-0003 specimen (a 25.3 MB personal-ciphertext PDF) to be removed from the repository.

While that instruction was being executed, `main` gained six commits of active development ([#14](https://github.com/turlamai/fileboundary/issues/14)–[#19](https://github.com/turlamai/fileboundary/issues/19)), including `tests/real-wrapper-baseline-test.rkt` (#18), which asserts the PDF specimen's size, SHA-256, wrapper signature, and classification against `baseline.json`; a draft PR (#20) and two feature branches now build on that history. An immediate history rewrite would break the regression test, invalidate the draft PR and both branches, and desync the other contributor's clone.

Measured evidence for the pair (pinned in `tests/fixtures/real-samples/baseline-twins.json`):

- `encrypted-sample.docx` (orig. 加密文档.docx): 12,111 B; SHA-256 `ea2eb7d89667e115f7edf217d853955dda49c0b4a35bfe8ebbba2699d9979ccd`; E-SafeNet/LOCK wrapper, magic prefix `62142365` — matching the ADR-0003 PDF specimen across file types (bytes 4–7 differ per file; semantic unknown, inferred: type/version metadata, unverified); zero `PK` structures visible; whole-file entropy 7.899 bpb.
- `plaintext-sample.docx` (orig. 未加密文档.docx): 10,198 B; SHA-256 `9526968c5da4980e838c96085cff735947ffe90b41a0c929827b926f97d30272`; valid OOXML; whole-file entropy 7.759 bpb — compressed plaintext measures near ciphertext entropy, so entropy alone must never classify OOXML.

## Decision

1. Commit the twin pair under `tests/fixtures/real-samples/` as the file-specific fixture exception, pinned by both SHA-256s in `baseline-twins.json`. `baseline.json` is intentionally left untouched — the #18 regression test consumes it.
2. **Defer** the owner-requested removal of the ADR-0003 specimen. ADR-0003 remains in effect until a coordinated purge lands. The purge, when the owner confirms its timing, must:
   - rewrite full branch history to drop the PDF blob everywhere (owner-directed force push — a further one-time exception to the no-force-push rule in [`AGENTS.md`](../../AGENTS.md), executed only with no open PRs, branches rebased or deleted, and all contributors re-synced);
   - migrate `real-wrapper-baseline-test.rkt` to the encrypted twin (point `baseline.json` at the twin entry and update the `exception` assertion to `ADR-0004` — the wrapper-signature and classification assertions carry over unchanged);
   - consolidate `baseline-twins.json` into `baseline.json` and update docs pointers.
3. The exception remains pinned to exactly these files; it does not generalize.

## Consequences

- Temporarily two real-fixture sets coexist; CI stays green throughout.
- The twins give the classifier a ground-truth pair and recovery verification a round-trip target: recovering the encrypted twin must contain the fingerprint `123 abc` and validate as OOXML; byte-identity with the plaintext twin is a bonus signal — its absence alone must not demote a verdict.
- Docs synced in the same PR: [`AGENTS.md`](../../AGENTS.md), [docs/testing.md](../testing.md), [docs/security.md](../security.md), [decisions index](README.md), fixture README.

## Scope of effect

`tests/fixtures/real-samples/` (README, baseline-twins.json, the twin pair), [`AGENTS.md`](../../AGENTS.md), [docs/testing.md](../testing.md), [docs/security.md](../security.md), [decisions index](README.md), this ADR.
