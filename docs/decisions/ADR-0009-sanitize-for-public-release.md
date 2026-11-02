# ADR-0009: Sanitize for public release — real specimens withdrawn, synthetic wrappers adopted

- **Status:** accepted
- **Date:** 2026-11-01
- **Deciders:** owner (turlamai), explicit directive in session
- **Supersedes:** the fixture admission of [ADR-0007](ADR-0007-real-wrapped-decryption-fixtures.md)
- **Relates to:** [ADR-0006](ADR-0006-adversarial-recovery-mandate.md), [ADR-0008](ADR-0008-release-channel-and-self-update.md)

## Context

The repository is being published. Its tree currently contains real company wrapped documents (decryption fixtures) and the policy pad. Publishing these would make every file wrapped under the deployed policy decryptable by anyone who obtains one.

The owner has reviewed this and directed: real company specimens are deleted, test specimens stay, everything else publishes, and the repository transitions to public visibility.

## Decision

1. Real company specimens are removed from the tree and from all git history.
2. The policy pad leaves the repository. Production pads are recovered via `pad twin` per operator environment.
3. Test coverage goes synthetic: a deterministic wrapper generator builds E-SafeNet-format fixtures from arbitrary plaintext using a fixed test pad.
4. The repository becomes public. CI moves to free hosted runners.
5. The project is positioned as an engineering showcase and collaborative research platform.

## Consequences

- Decrypt tests use synthetic wrappers; no real specimen or policy pad is required.
- The policy pad being public is a deliberate trade-off: the deployed policy is a test system scheduled for upgrade.
- No company document is distributed with the repository.
- CI runs on free hosted runners once the repository is public.
