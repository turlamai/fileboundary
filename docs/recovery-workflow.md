# Recovery Workflow

The recovery process has six stages. Each stage produces records; nothing advances on assumption. The workflow is driven identically by the GUI and the CLI (agent parity) — the CLI is the normative interface ([cli-contract.md](cli-contract.md)).

## Stage 0 — Preconditions

- Recovery output directory chosen by the operator, **outside** any protected path and outside this repository.
- Operator confirms they own the files and accepts the security model ([security.md](security.md)).
- The tool records these preconditions in the audit log before any scan or recovery action.

## Stage 1 — Assess (diagnostics, [#3](https://github.com/turinglambdaai/fileboundary/issues/3))

Run the diagnostics module. Record: the minifilter stack (filters, altitudes, instances), filter-driver and service configuration, per-process module inventory, hook heuristic findings (labeled `heuristic`), and probe-file I/O behavior. Probe files answer the load-bearing question early: *what happens to content written by a non-whitelisted process, and what reads back?*

**Output:** diagnostics report (`.fbreport.json`), evidence-classed.

## Stage 2 — Inventory ([#4](https://github.com/turinglambdaai/fileboundary/issues/4))

Batch-scan the target locations. For every file: size, timestamps, SHA-256, format sniff, classification label with confidence and evidence ([architecture.md](architecture.md#inventory-module--planned-4)). The scan is resumable; results persist in a manifest.

**Output:** inventory manifest (`.fbmanifest.json`) — the working set for everything that follows.

## Stage 3 — Select path

The operator selects files from the manifest and chooses, per selection, the recovery path:

- vendor management console / export function,
- export path through a whitelisted application,
- owner-held key (where legitimately available),
- adversarial adapters validated by the research program: whitelist ride-along, extracted-key decryption, standalone decryptor ([adversarial-research.md](adversarial-research.md)).

The path basis is recorded per batch in the audit log **before** recovery starts. Ordering rule: cheapest first — sanctioned channels when they exist, then adversarial paths in the research program's order. A selection with no available path stays open, not closed: new research results reopen it.

## Stage 4 — Recover ([#5](https://github.com/turinglambdaai/fileboundary/issues/5))

Run the selected path through the engine's recovery adapter. State-mutating steps (driver/service interaction beyond read-only enumeration) follow the gated experiment protocol ([security.md](security.md#technique-scope)). Outputs land only in the Stage-0 directory. Every attempt — success or failure — produces exactly one audit record with: timestamp, file identity, path, parameters, outcome, and pointers to evidence.

**Output:** recovered files (outside the repo) + audit records (`.fbaudit.jsonl`).

## Stage 5 — Verify

**Implementation progress:** `racket src/cli.rkt verify --original <file> --exported <file> [--trusted-plaintext-sha256 HEX]` now performs read-only, per-file comparison of an **operator-provided authorized export**, with conservative `unverified` (exit 1) or `failed` (exit 4) outcomes. It does **not** decrypt, run a third-party exporter, persist an audit log, or certify full structure or independent reader evidence; see [authorized recovery guide](authorized-recovery.md). The remainder of Stage 5 below is the required future acceptance contract.

Each recovered file goes through the verification pipeline ([security.md](security.md#integrity-semantics)): format validation, independent open test, content-level check, fixture round-trip where a baseline exists. The pipeline emits `verified`, `unverified`, or `failed` — with evidence. `unverified` never auto-promotes.

**Output:** verification records appended to the audit log; verdicts reflected in the manifest.

## Stage 6 — Reconcile

Compare the manifest against the recovered-and-verified set. Produce a gap report: files not recovered, files `unverified`, files `failed`. Unresolved files are explicitly listed and closed as *unrecoverable via all currently known paths* — never silently dropped; future research results can reopen them. The operator archives the audit log alongside the recovery output.

**Output:** reconciliation report + archived audit log.

## Verdict decision table

| Observation | Verdict |
|---|---|
| Export/copy completed, no validation run | `unverified` |
| Output header/magic recognized | `unverified` — header ≠ plaintext proof |
| Format validates + independent reader opens + content checks pass | `verified` (file-level) |
| Fixture round-trip hash matches original plaintext | `verified` (pipeline-level; strongest evidence) |
| Recovery mechanism errored or refused | `failed`, reason recorded |
| No recovery path available | selection stays open at Stage 3, reason recorded |

## Retry and escalation policy

- Retry the **same** path at most three times per file; record each attempt.
- Escalation follows the ordering defined in [adversarial-research.md](adversarial-research.md) (sanctioned channel → ride-along export → key extraction → standalone decryption). Every escalation is an audit-logged path change, not a silent retry.
- State-mutating steps during recovery follow the gated experiment protocol ([security.md](security.md#technique-scope)).
- If recovery behavior contradicts Stage-1 diagnostics (e.g. a "whitelisted" export path suddenly reads ciphertext), stop, record, re-assess before continuing.
