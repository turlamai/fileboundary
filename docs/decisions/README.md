# Architecture Decision Records

Significant decisions for FileBoundary are recorded here as short, numbered documents. A decision that isn't recorded doesn't exist.

## Process

1. Copy [`adr-template.md`](adr-template.md) to `ADR-NNNN-short-title.md` (next number in sequence).
2. Fill it in **in the same PR** that implements the decision.
3. Status lifecycle: `proposed` → `accepted` / `rejected` → `superseded` (by ADR-XXXX).
4. Accepted ADRs are immutable; to change course, write a new ADR that supersedes the old one and link both directions.

## What requires an ADR

- Technology or toolchain selection (framework, language, host shell, packaging).
- Changes to the CLI contract's envelope or versioning policy.
- Anything that moves a boundary in [../security.md](../security.md).
- New top-level modules or changes to the dependency rules in [../architecture.md](../architecture.md).
- Weakening any gate defined in [`../../AGENTS.md`](../../AGENTS.md) — these additionally require owner approval.

## Index

| ADR | Title | Status |
|---|---|---|
| [ADR-0001](ADR-0001-project-scope-and-boundaries.md) | Project scope and boundaries | Accepted (boundary clauses superseded by ADR-0006) |
| [ADR-0003](ADR-0003-real-encrypted-sample-exception.md) | Historical one-time personal specimen exception | Archived: retired from HEAD by ADR-0005; history purge pending |
| [ADR-0004](ADR-0004-real-sample-twin-pair-and-deferred-removal.md) | Controlled encrypted/plaintext twin pair | Accepted |
| [ADR-0005](ADR-0005-personal-pdf-removed-from-head.md) | Remove prior personal specimen from active tree | Accepted; history purge pending (#23) |
| [ADR-0006](ADR-0006-adversarial-recovery-mandate.md) | Adversarial recovery mandate — technique prohibitions lifted, scope and evidence rules fixed | Accepted |
| ADR-0002 | Technology stack (pending prototype review) | Proposed placeholder — see [#2](https://github.com/turlamai/fileboundary/issues/2) |
