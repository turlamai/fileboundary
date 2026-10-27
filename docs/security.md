# Security Model

This document defines what FileBoundary is authorized to do, what it will never do, and what counts as evidence. It is binding for every contributor (see [`AGENTS.md`](../AGENTS.md)); PRs touching diagnostics, recovery, permissions, or output writing must be checked line-by-line against this page.

## Scope of authority

The operator is the machine owner, with administrator rights, recovering access to their own files. **"Authorized"** means exactly one of:

1. mechanisms the protection vendor itself provides (management console, export/decrypt functions, official documentation);
2. export paths through applications the protection system whitelists;
3. keys the owner legitimately holds.

Anything outside this list is out of scope for this repository, permanently — not "later", not "opt-in".

## Hard boundaries

| Action | Status |
|---|---|
| Bypass DLP or access controls | **Prohibited** |
| Extract or infer keys from the key management service, drivers, or process memory | **Prohibited** |
| Impersonate or masquerade as a whitelisted process | **Prohibited** |
| Unload, patch, disable, or tamper with protection drivers | **Prohibited** |
| Reverse-engineer the encryption system in order to defeat it | **Prohibited** |
| Analyze own system state for diagnosis (enumeration, observation) | In scope |
| Read own files, read-only, for inventory and verification | In scope |
| Export/decrypt via sanctioned mechanisms, then verify | In scope |

Administrator rights are a diagnostic capability, not a key capability. The tool never treats elevation as access to key material, and never assumes that a successful privileged operation implies decryption is possible.

## Integrity semantics

The core integrity rule: **copy success is not decryption success**. A copied file can be ciphertext; a ciphertext file can have a perfectly recognizable container header; an archive can list entries that do not decode.

### What is NOT evidence of recovery

- The copy/export operation completed without error.
- The output file exists and has plausible size.
- A file header/magic number is recognizable (wrapper formats survive round trips).
- An archive lists entries, or a PDF reader opens a *different*, never-encrypted file.

### What IS required for a `verified` verdict

All of the following, recorded as evidence in the audit log:

1. **Format validation** — the output file's structure validates end-to-end for its claimed format (not just a header match).
2. **Independent open test** — a reader application that is *not* among the whitelisted processes opens the file and renders/reads content.
3. **Content-level check** — where possible, a **fixture round-trip**: a known plaintext written through the transparent-encryption mechanism earlier, recovered through the same authorized path, hash-compared against the original. A file-level verdict without a round-trip baseline is issued as `verified` only with checks 1–2 plus explicit recorded reasoning.

### Verdicts

| Verdict | Meaning |
|---|---|
| `verified` | Checks above passed; evidence recorded |
| `unverified` | Output produced but evidence is incomplete — never promoted silently |
| `failed` | The authorized mechanism errored or refused; reason recorded |

## Data safety

- **Originals are read-only.** The engine opens protected files with read access only; writes go exclusively to operator-designated recovery output directories.
- **No content in artifacts.** Manifests, reports, and audit logs contain metadata, hashes, paths, verdicts and evidence references — never file content.
- **Repository hygiene.** Never commit: recovered files, diagnostic dumps containing file data, key or credential material, scan databases, or real personal data (recorded exception: the single owner-approved real encrypted specimen in [`tests/fixtures/real-samples/`](../tests/fixtures/real-samples/README.md), per [ADR-0003](decisions/ADR-0003-real-encrypted-sample-exception.md)). Reserved artifact extensions (`.fbmanifest.json`, `.fbreport.json`, `.fbaudit.jsonl`) are git-ignored as belt-and-suspenders; the real rule is "sensitive artifacts live outside the repository".
- **Issue hygiene.** Diagnostics output pasted into issues must be sanitized first: no file content, no keys, no personal paths that aren't needed for the report.
- **Local-first.** No telemetry, no network calls, no accounts. Nothing leaves the machine.

## Elevation and degradation

Diagnostics that require administrator rights must run in one of two modes: elevated (with elevation recorded in the report) or degraded (each affected check reports `requiresElevation`). Failing silently, returning empty results, or guessing is a correctness bug, not a graceful degradation.

## Incident handling

If diagnostics reveal unexpected tampering, unknown drivers, or behavior that suggests the environment differs from the owner's description: stop, record the finding in the audit log, and surface it to the owner before continuing. FileBoundary reports; it does not react.
