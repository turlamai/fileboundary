---
name: Feature / capability
about: Propose a capability within the project's security model
title: "[feat] "
labels: enhancement
---

## Problem

What workflow or need is currently unmet? Link related issues.

## Proposed capability

What should the engine / CLI / GUI do? If it changes the CLI contract, link [docs/cli-contract.md](../docs/cli-contract.md) and state the envelope impact.

## Scope and safety check

How does this stay inside the fixed rules of [docs/security.md](../docs/security.md) ([ADR-0006](../docs/decisions/ADR-0006-adversarial-recovery-mandate.md))? Capabilities must: apply only to operator-owned machines, keep originals read-only (or follow the gated state-mutation protocol), keep recovered data and key material outside the repository, and produce claims only through the verification pipeline. Adversarial techniques are in scope; uncontained ones are not.

## Acceptance criteria

Concrete, checkable conditions — including tests and documentation that must exist when this is done.
