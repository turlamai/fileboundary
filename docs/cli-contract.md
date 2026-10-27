# CLI Contract

**Status: normative specification, partially implemented in an experimental Racket CLI.** `version` and read-only `scan` emit the common envelope; `doctor` now returns read-only Windows filter enumeration with explicit per-check status, and `verify` performs read-only comparison of an already-authorized export. This is not a decryption engine. Full schema validation and artifact persistence remain for [Issue #7](https://github.com/turinglambdaai/fileboundary/issues/7). No Windows runtime success is claimed until CI has run. See [first implementation slice](implementation-slice.md).

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

## Commands (planned unless explicitly stated)

In the developer preview, `version`, `scan <path> [--max-files N]`, and bounded read-only `doctor` are implemented. Scan returns file records directly in `data.files`; it does **not** write a manifest or verify plaintext. Doctor returns the `filters` and `instances` check results with measured exit status, stdout/stderr, timeout and truncation indicators; failed/incomplete checks produce `partial` / exit 1. On non-Windows systems both checks return `unsupportedPlatform`, not an empty success. `verify --original <path> --exported <path> [--trusted-plaintext-sha256 HEX]` now implements **read-only authorized export comparison**, returning `unverified` / exit 1 for incomplete evidence or `failed` / exit 4 for an export still bearing the known encryption wrapper or mismatching the trusted digest. It **does not decrypt**, invoke third-party applications, or pronounce `verified`.  All remaining behavior in the table below is planned.

| Command | Purpose | Issue |
|---|---|---|
| `fileboundary version` | build/commit, envelope schema version | #7 |
| `fileboundary doctor` | run diagnostics, emit report | #3, #7 |
| `fileboundary scan <path>` | inventory scan, write manifest | #4, #7 |
| `fileboundary verify --manifest <p> --recovered-dir <d>` | verification pipeline, update verdicts | #5, #7 |

`doctor` / `scan` / `verify` write their primary artifacts (`.fbreport.json`, `.fbmanifest.json`, `.fbaudit.jsonl`) to operator-specified output locations; defaults are under the current working directory's designated output folder, never inside the repository.

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

## Example (specification illustration)

The shape below illustrates the contract; it is not output from a shipped build.

```console
$ fileboundary doctor --output D:\recovery\reports
{"schemaVersion":"1.0","command":"doctor","invocationId":"…","status":"partial","data":{ "…":"…" },"warnings":[{ "code":"requiresElevation","message":"…" }],"errors":[],"durationMs":0}
```

Warnings in `data` items always carry an `evidence` class (`measured`, `heuristic`, `inferred`) — heuristic findings are never presented as measured facts ([security.md](security.md#integrity-semantics)).
