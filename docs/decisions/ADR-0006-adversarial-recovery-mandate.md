# ADR-0006: Adversarial recovery mandate — technique prohibitions lifted, scope and evidence rules fixed

- **Status:** accepted
- **Date:** 2026-10-28
- **Deciders:** owner (turinglambdaai), explicit directive in session
- **Supersedes:** clause 4 of [ADR-0001](ADR-0001-project-scope-and-boundaries.md) (authorized mechanisms only; permanent prohibition list). All other ADR-0001 clauses remain in force.

## Context

ADR-0001 chartered FileBoundary as a diagnostics tool restricted to mechanisms the protection system itself sanctions (vendor console, whitelisted-application export, owner-held keys), and placed key extraction, whitelist impersonation, driver tampering and encryption-defeating reverse engineering permanently out of scope.

That boundary defeats the project's purpose. The historical backlog is encrypted **now**; most of it has no sanctioned export channel at all, so the old Stage-3 rule ("no escalation") dead-ended the workflow exactly where recovery is actually needed. A research program that pre-declares its hardest problems unsolvable has no research value.

The owner's directive: FileBoundary is an **adversarial recovery research program**. Extracting keys from drivers and the key management service, studying and adopting the whitelist, riding or impersonating whitelisted processes, breaking the wrapper's crypto — all of it is legitimate work on this project. What makes it legitimate is unchanged and must stay written down: the operator is the machine owner recovering **their own files** on **a machine they own and administer**, in a **private, internal-use, unlicensed** repository ([ADR-0001](ADR-0001-project-scope-and-boundaries.md) clauses 1–2). The authorization basis does not move; only the technique scope does.

## Decision

1. **All technique prohibitions on the operator-owned machine are lifted.** In scope, explicitly: reverse-engineering the on-disk wrapper format and its cryptography (including known- and chosen-plaintext experiments using fixture twins); extracting or inferring key material from the key management service, drivers, service configuration, or process memory; studying the process-whitelist mechanism and impersonating, riding, or automating whitelisted processes; probing or modifying protection driver and service state; every other technique that serves recovery. The research program itself is defined in [../../docs/adversarial-research.md](../adversarial-research.md).
2. **The fixed rules do not change** — they are what make the mandate safe and the results trustworthy:
   - **Machine scope.** Techniques apply only to machines the operator owns and administers. Nothing in this repository is for use against anyone else's systems.
   - **Containment.** The repository stays private and unlicensed. Recovered plaintext, extracted keys, decryptors and bypass tooling stay under operator control and are never committed, published, or redistributed (hygiene rules in [../../docs/security.md](../security.md) unchanged).
   - **Data safety.** Originals default to read-only. Experiments that mutate protection-system state (driver unload/patch, service stop/reconfiguration, registry writes) run under the gated protocol in [../../docs/security.md](../security.md#technique-scope): recorded plan first, disposable copies where feasible, audit-logged.
   - **Evidence discipline.** Copy success ≠ decryption success. The verification pipeline and its three verdicts are unchanged ([../../docs/security.md](../security.md#integrity-semantics)); no technique, however effective, produces a `verified` verdict except through the pipeline.
3. **The recovery workflow gains escalation.** The "no escalation" rule and the sanctioned-channels-only adapter list are retired. Paths are ordered cheapest-first (sanctioned channel → ride-along export → key extraction → standalone decryption); every path change is an audit-logged decision, and "unrecoverable" now means *all known paths exhausted* ([../../docs/recovery-workflow.md](../recovery-workflow.md)).
4. **Diagnostics keep their read-only default.** Enumeration and observation remain non-mutating; deliberate state-mutating work is a separate, gated, audit-logged experiment class — not something a diagnostic command does incidentally.

## Alternatives considered

- **Keep the sanctioned-only boundary** — rejected: it makes the project structurally unable to solve its core problem; the backlog mostly has no sanctioned channel.
- **Spin the adversarial work out into a separate repository** — rejected: it splits evidence, fixtures and context from the diagnostics that feed the research, and creates two charters to keep in sync.
- **Lift the boundary without rewriting the charter documents** — rejected: ADR-0001 and [security.md](../security.md) explicitly bind every contributor line-by-line; leaving contradictory prohibition language in force would make every adversarial PR a charter violation by construction.

## Consequences

- Same-PR document updates: [security.md](../security.md) (authorization basis + technique scope rewrite), [adversarial-research.md](../adversarial-research.md) (new research program), [architecture.md](../architecture.md) (recovery adapters, diagnostics principle), [recovery-workflow.md](../recovery-workflow.md) (escalation), [../../README.md](../../README.md) and [../../README.zh-CN.md](../../README.zh-CN.md) (positioning), [../../AGENTS.md](../../AGENTS.md) (charter repositioning).
- Issue [#5](https://github.com/turlamai/fileboundary/issues/5) is renamed in docs to "File recovery and verification": it now covers all recovery paths, not only sanctioned ones.
- Future slices may contain adversarial capabilities (memory scanning, injection harnesses, IOCTL replay, decryptors); each lands with the same test and evidence bars as any other slice, plus the state-mutation gate where applicable.
- The verification pipeline gains importance, not less: the wider the technique surface, the more the single evidence gate matters.

## Scope of effect

All modules and documents that referenced the prohibition list: [security.md](../security.md), [architecture.md](../architecture.md), [recovery-workflow.md](../recovery-workflow.md), [implementation-slice.md](../implementation-slice.md), both READMEs, [../../AGENTS.md](../../AGENTS.md), [ADR-0001](ADR-0001-project-scope-and-boundaries.md) (status annotation).
