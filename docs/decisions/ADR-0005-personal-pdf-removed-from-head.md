# ADR-0005: Retire personal PDF specimen from the active repository tree

- **Status:** Accepted
- **Date:** 2026-10-27
- **Related:** [ADR-0003](ADR-0003-real-encrypted-sample-exception.md), [ADR-0004](ADR-0004-real-sample-twin-pair-and-deferred-removal.md), [Issue #23](https://github.com/turinglambdaai/fileboundary/issues/23)

## Context

The owner previously requested removal of a large personal encrypted PDF. ADR-0004 introduced a small approved encrypted/plaintext DOCX pair as an alternative. Tests depended on separate baseline manifests.

## Decision

Remove the personal PDF from **current tracked files**, migrate all wrapper tests to the DOCX pair, and consolidate fixture metadata into `tests/fixtures/real-samples/baseline.json`. Keep classifier, SHA-256 and no-false-decryption tests.

Historical decisions remain as archive records. **ADR-0003 no longer authorizes use or redistribution of the personal PDF in current or future source trees**. Only the controlled DOCX pair governed by ADR-0004 remains as an active fixture exception.

## Limits

Normal Git deletion does **not** remove historical blobs from commits, forks, clones, GitHub caches or downloaded artifacts. Therefore this decision does **not** claim historical erasure, and [Issue #23](https://github.com/turinglambdaai/fileboundary/issues/23) remains open.

A complete history purge requires coordinated maintenance, no in-flight PRs, all contributors informed to resync, lease-checked ref updates and separate audit. Do not reproduce the old blob, path or document title in new build outputs.

## Verification

Windows core CI must execute both `tests/real-wrapper-baseline-test.rkt` and `tests/recovery-twin-baseline-test.rkt` using the consolidated baseline. Their evidence remains read-only and the recovery comparison verdict remains `unverified`.
