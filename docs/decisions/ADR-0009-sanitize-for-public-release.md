# ADR-0009: Sanitize for public release — real specimens withdrawn, synthetic wrappers adopted

- **Status:** accepted
- **Date:** 2026-11-01
- **Deciders:** owner (turinglambdaai), explicit directive in session
- **Supersedes:** the fixture admission of [ADR-0007](ADR-0007-real-wrapped-decryption-fixtures.md) (the two real company specimens are withdrawn from the repository); ADR-0007 remains as the historical record of the T0 verification phase
- **Relates to:** [ADR-0006](ADR-0006-adversarial-recovery-mandate.md), [ADR-0008](ADR-0008-release-channel-and-self-update.md)

## Context

The repository is being published. Its tree currently contains, besides code and documentation:

- two **real company wrapped documents** committed as decryption fixtures under `research/t0/fixtures/` (a 25 MB courseware PDF and a 2.9 MB radar-motor XLSX, per ADR-0007);
- `research/t0/pad_full.json` — the **policy pad**: the 512-byte XOR pad that decrypts every file wrapped under the deployed policy.

Publishing these would make every file wrapped under that policy decryptable by anyone who obtains one — including files that leave the company by ordinary channels. The owner has reviewed this and directed: real company specimens are deleted, test specimens stay, everything else publishes.

## Decision

1. **Real company specimens are removed** from the tree and from all git history (`research/t0/fixtures/*`, plus the historically committed ADR-0003 specimen path and all superseded pad JSON variants). History is rewritten before the repository becomes public; the v0.2.0 release assets (whose zip contained the specimens and the pad) are withdrawn and re-published sanitized.
2. **Test coverage goes synthetic.** A deterministic wrapper *generator* builds E-SafeNet-format fixtures from arbitrary plaintext using a fixed test pad; the decrypt pipeline is tested end-to-end against synthetic wrappers. No real specimen or policy pad is required by any test.
3. **The policy pad leaves the repository.** The public project ships a clearly-labeled example pad for tests; production pads are recovered per operator environment via `pad twin` (FIELD_PROTOCOL step 2). The committed-pad exception recorded in ADR-0007 is withdrawn with the fixtures.
4. **The repository becomes public.** The charter's privacy statements move from "repository is private" to "no company data in the repository"; the machine-scope rule (only operator-owned machines) is unchanged and remains the primary containment.
5. The twin-pair fixtures under `tests/fixtures/real-samples/` (content `123 abc`, created as test samples) are retained.

## Consequences

- Decrypt tests no longer depend on real specimens; the real-specimen verification of the T0 phase is recorded in ADR-0007 and the research notes as history.
- The policy pad being public is a deliberate, owner-accepted trade-off: the deployed policy is a test system scheduled for upgrade, and no company document is distributed with the repository. The upgrade plan supersedes the published pad.
- CI runs on free hosted runners once the repository is public; the billing block disappears.
- Distribution rules from ADR-0001 are amended accordingly: the repository is public; decrypted recovered files still never enter the repository.

## Scope of effect

`research/t0/fixtures/` (removed), `research/t0/pad_full.json` and superseded pad JSONs (removed from tree and history), `src/engine/decrypt.rkt` tests (synthetic wrappers), `docs/security.md` and both READMEs (privacy wording), ADR-0007 (status annotation), release v0.2.0 assets (withdrawn; sanitized re-publish).
