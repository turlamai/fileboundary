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
| [ADR-0001](ADR-0001-project-scope-and-boundaries.md) | Project scope and boundaries | Accepted |
| [ADR-0003](ADR-0003-real-encrypted-sample-exception.md) | One-time exception — commit a real encrypted specimen as a fixture | Accepted (removal deferred — see ADR-0004) |
| [ADR-0004](ADR-0004-real-sample-twin-pair-and-deferred-removal.md) | Real encrypted/plaintext twin pair; ADR-0003 specimen removal deferred | Accepted |
| ADR-0002 | Technology stack (pending prototype review) | Proposed placeholder — see [#2](https://github.com/turinglambdaai/fileboundary/issues/2) |
