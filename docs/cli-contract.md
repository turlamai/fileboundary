# CLI Contract

**Status: four command envelopes implemented; artifact persistence is not implemented.** The Windows core workflow executes a real Racket CLI process for `version`, `scan`, `doctor` and `verify` against [Draft 2020-12 envelope and command schemas](../contracts/). It validates both normal/degraded/failure exits, plus negative schema controls that must be rejected. This is contract validation, **not** decryption or independent format verification.

## Principles

- **stdout is data, stderr is logs.** Every invocation writes exactly one JSON document to stdout; human-readable progress and logs go to stderr. An agent can consume stdout without ever parsing prose.
- **Stable envelope.** All commands share one response envelope; consumers code against it once.
- **Exit codes that never lie.** Documented below; success is `0` only when `status` is `ok`.
- **Agent parity.** Every GUI capability has a CLI command with the same contract.

## Envelope (v1)

```json
{
  "schemaVersion": "1.0",
  "command": "doctor",
  "invocationId": "b0e6f6b2-…",
  "status": "ok | partial | error",
  "data": { },
  "warnings": [
    { "code": "requiresElevation", "message": "filter enumeration needs admin; run elevated for full results" }
  ],
  "errors": [
    { "code": "accessDenied", "message": "…", "details": { "path": "…" } }
  ],
  "durationMs": 0
}
```

Field rules:

- `schemaVersion` — envelope schema version, present on every response, including errors.
- `status` — `ok` (complete success), `partial` (completed with degraded results; see `warnings`), `error` (command failed; see `errors`).
- `warnings` — non-fatal degradations (e.g. `requiresElevation`, `accessDenied` per path). Never silently empty when something was skipped.
- `errors` — structured, coded failures. `code` values are documented and stable.
- `data` — command-specific payload, schema-checked against `contracts/` once implemented.
- `invocationId` — correlates stdout with the stderr log and audit records.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | `status: ok` |
| `1` | `status: partial` — completed with warnings |
| `2` | Usage error (unknown command/flag, bad arguments) |
| `3` | Runtime error — `status: error` |
| `4` | Verification failed (recovery pipeline verdict) |
| `10`–`19` | Reserved for module-specific codes; documented here before first use |

## Implemented commands (developer preview)

Run from the repository root on Windows with Racket CS 9.3, or use the packaged CLI if one is provided separately:

| Command | Result | Exit code |
| --- | --- | --- |
| `racket src/cli.rkt version` | Version, runtime, schema | 0 |
| `racket src/cli.rkt scan <path> [--max-files N]` | Bounded read-only file metadata records; symlinks skipped with `skippedCount` and `partial`; **no saved manifest** | 0 / 1 / 2 / 3 |
| `racket src/cli.rkt doctor` | Bounded, read-only `fltmc` filters/instances checks | 0 / 1 / 2 / 3 |
| `racket src/cli.rkt verify --original <file> --exported <file> [--trusted-plaintext-sha256 HEX]` | Comparison of an **already authorized** export; never decrypts and never returns `verified` | 1 (`unverified`), 4 (`failed`), 2 / 3 on errors |
| `racket src/cli.rkt decrypt --in FILE --out FILE [--pad PATH]` | Decrypt an E-SafeNet-wrapped file with the policy pad: OOXML reassembled with per-entry CRC verification, PDF with semantic head rebuild + xref spot-check ([ADR-0006](decisions/ADR-0006-adversarial-recovery-mandate.md)) | 0, 3 (pad/format mismatch) |
| `racket src/cli.rkt pad twin --plain FILE --cipher FILE --out FILE [--pad PATH]` | Recover a policy pad from an aligned plaintext/ciphertext twin pair (FIELD_PROTOCOL step 2); exit 1 with `padIncomplete` when columns remain unknown | 0, 1 (partial), 2 / 3 |
| `racket src/cli.rkt update status` | Report running version, installed version and install root | 0, 2 / 3 on errors |
| `racket src/cli.rkt update check [--manifest URL\|PATH]` | Fetch the release manifest (default: the GitHub Releases channel) and compare against the running version; the only implicitly networked command, operator-initiated ([ADR-0008](decisions/ADR-0008-release-channel-and-self-update.md)) | 0, 2 / 3 on errors |
| `racket src/cli.rkt update apply --package PATH --manifest PATH [--url URL] [--root DIR]` | Verify the package hash, apply (full or guarded delta) into the install root, bump the `current` marker; `--url` downloads the package explicitly | 0, 4 (verification/guard failure), 2 / 3 on errors |

For `scan` and `verify`, an explicitly supplied symbolic-link path (including a linked ancestor) is refused with exit code `3`, `status: "error"`, and `errors[0].code: "unsafeScanPath"`. The error message does not include the supplied path or link target. An ordinary missing/inaccessible path remains `runtimeError`; links discovered during a directory scan are counted under `skippedCount` with `skippedEntries` and a `partial` status. This distinction is additive within envelope v1; it does not promise race-free protection or recognition of every Windows reparse tag (Issue #10).

CLI stdout contains only one JSON envelope. A zero exit code does **not** mean original ciphertext was decrypted: the scanner and diagnostics don't attempt it. The `verify` command conservatively reports `unverified` even after a trusted hash matches because independent format and reader checks are not performed.

**Planned:** persistent `.fbmanifest.json`, `.fbreport.json` and `.fbaudit.jsonl` artifacts; manifest/resume and recovery reconciliation; independent full structure validation. These are not created by the present CLI and require subsequent Issue #3–#5 implementation.

## Schema validation

- `contracts/envelope-v1.schema.json` — shared versioned JSON envelope.
- `contracts/command-data-v1.schema.json` — concrete `version`, `scan`, `doctor`, `verify` data structures.
- `tests/validate_contract.py` — Windows CI integration script running the real Racket CLI and validating output with `jsonschema==4.23.0` (test-only Python dependency). It also deliberately mutates envelope keys and recovery verdicts to prove invalid JSON payloads fail schema validation.

The CLI emits no sensitive input file contents or full paths in response metadata. Filenames and hashes may still be sensitive and must be retained locally.

## Reserved artifact extensions

| Extension | Artifact |
|---|---|
| `.fbreport.json` | diagnostics report |
| `.fbmanifest.json` | inventory manifest (scan state + per-file records) |
| `.fbaudit.jsonl` | append-only audit log |

These are git-ignored; artifacts live outside the repository ([security.md](security.md#data-safety)).

## Versioning policy

- The envelope follows semver: additive fields = minor bump; breaking changes (removal, type change, semantic change) = major bump with a migration note in this document.
- `schemaVersion` is echoed by every command; consumers gate on it.
- Machine-readable schemas live in `contracts/` once #7 lands; contract tests (golden JSON + schema validation) lock the envelope in CI.
- A change to the contract without a same-PR update to this document and both READMEs is rejected in review.

## Contract example (illustration, not recorded test output)

A version response has these fields, with `invocationId` and `durationMs` generated at runtime. For **actual** evidence, use the Windows CI run linked from the PR or invoke the CLI locally:

```json
{"schemaVersion":"1.0","command":"version","invocationId":"example-not-a-real-invocation","status":"ok","data":{"version":"0.1.0+dev","runtime":"Racket CS","interface":"headless","schemaVersion":"1.0"},"warnings":[],"errors":[],"durationMs":0}
```

Any future response/schema change must include a versioning review, test updates, migration notes for breaking changes, and corresponding README updates.
