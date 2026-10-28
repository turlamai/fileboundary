# Security Model

This document defines the authorization basis of FileBoundary, the technique scope of its adversarial mandate ([ADR-0006](decisions/ADR-0006-adversarial-recovery-mandate.md)), the fixed safety rules the mandate operates under, and what counts as evidence. It is binding for every contributor (see [`AGENTS.md`](../AGENTS.md)); PRs touching diagnostics, recovery, permissions, or output writing must be checked line-by-line against this page.

## Authorization basis

The operator is the machine owner, with administrator rights, recovering access to their own files on a machine they own and administer. The repository is private and unlicensed; nothing in it is published or distributed ([ADR-0001](decisions/ADR-0001-project-scope-and-boundaries.md)).

Two containment rules follow from this basis and are not negotiable:

1. **Machine scope.** Every technique in this repository applies only to machines the operator owns and administers. Nothing here is for use against anyone else's systems, and no capability is built with such use in mind.
2. **Containment of results.** Recovered plaintext, extracted key material, decryptors, and bypass tooling stay under operator control. They are never committed, attached to issues, or redistributed (see Data safety).

## Technique scope (adversarial mandate)

Per [ADR-0006](decisions/ADR-0006-adversarial-recovery-mandate.md), there are **no technique prohibitions** on the operator-owned machine. The previous "hard boundaries" list — key extraction, whitelist impersonation, driver tampering, defeating reverse engineering — is retired: these are now legitimate research and recovery subjects, organized as the tracks in [adversarial-research.md](adversarial-research.md).

| Technique area | Status |
|---|---|
| Analyze own system state (enumeration, observation, probing) | In scope |
| Reverse-engineer the wrapper format and crypto (static analysis, known/chosen-plaintext experiments) | In scope |
| Extract or infer keys from the key management service, drivers, service config, or process memory | In scope |
| Study the whitelist mechanism; automate, ride along with, or impersonate whitelisted processes | In scope |
| Probe or modify protection driver/service state (unload, patch, reconfigure) | In scope, **gated** |
| Export/decrypt via vendor-sanctioned mechanisms | In scope — cheapest legitimate path, always tried first when available |

The one gated row exists for data protection, not technique restriction. Mutating protection-system state is dangerous in a transparent-encryption environment: a filter that decrypts on read can also encrypt on write, and a half-tampered stack is exactly the state that corrupts files. A state-mutating experiment requires, in order:

1. a **recorded plan** (hypothesis, procedure, rollback) written before execution;
2. **disposable copies/snapshots** as the experiment surface wherever feasible — never first-touch on originals;
3. **post-verification** of the round-trip fixture afterwards, to prove the environment still behaves as measured;
4. a **full audit trail** (`.fbaudit.jsonl` conventions), whatever the outcome.

## Fixed rules

1. **Originals default read-only.** The engine opens protected files with read access only; writes go exclusively to operator-designated recovery output directories. The gated-experiment protocol above is the only carve-out.
2. **Administrator rights are a diagnostic capability, not a key capability.** Elevation never implies access to key material, and a successful privileged operation never implies decryption is possible. Keys come from measured extraction, not assumed authority.
3. **Machine scope and containment** (Authorization basis) hold for every module and every experiment.
4. **Evidence discipline** (Integrity semantics) holds for every recovery claim, regardless of which technique produced the candidate plaintext.

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
3. **Content-level check** — where possible, a **fixture round-trip**: a known plaintext written through the transparent-encryption mechanism earlier, recovered through the same recovery path, hash-compared against the original. A file-level verdict without a round-trip baseline is issued as `verified` only with checks 1–2 plus explicit recorded reasoning.

### Verdicts

| Verdict | Meaning |
|---|---|
| `verified` | Checks above passed; evidence recorded |
| `unverified` | Output produced but evidence is incomplete — never promoted silently |
| `failed` | The recovery mechanism errored or refused; reason recorded |

## Data safety

- **Originals are read-only** (Fixed rules; the gated experiment protocol is the only exception).
- **No content in artifacts.** Manifests, reports, and audit logs contain metadata, hashes, paths, verdicts and evidence references — never file content. The same applies to extracted key material and decryptor internals: they live outside the repository, referenced by hash, never pasted in.
- **Repository hygiene.** Never commit: recovered files, diagnostic dumps containing file data, key or credential material, scan databases, or real personal data (current exception: only the controlled, approved DOCX encrypted/plaintext twin pair per [ADR-0004](decisions/ADR-0004-real-sample-twin-pair-and-deferred-removal.md); the earlier personal encrypted PDF was removed from HEAD per [ADR-0005](decisions/ADR-0005-personal-pdf-removed-from-head.md), but Git history still requires coordinated purging in [#23](https://github.com/turinglambdaai/fileboundary/issues/23)). Reserved artifact extensions (`.fbmanifest.json`, `.fbreport.json`, `.fbaudit.jsonl`) are git-ignored as belt-and-suspenders; the real rule is "sensitive artifacts live outside the repository".
- **Issue hygiene.** Diagnostics output, experiment logs, and memory/IOCTL dumps pasted into issues must be sanitized first: no file content, no keys, no personal paths that aren't needed for the report.
- **Local-first.** No telemetry, no network calls, no accounts. Nothing leaves the machine.

## Elevation and degradation

Diagnostics that require administrator rights must run in one of two modes: elevated (with elevation recorded in the report) or degraded (each affected check reports `requiresElevation`). Failing silently, returning empty results, or guessing is a correctness bug, not a graceful degradation.

## Incident handling

If diagnostics or experiments reveal unexpected tampering, unknown drivers, or behavior suggesting the environment differs from the operator's description: stop, record the finding in the audit log, and surface it to the operator before continuing. A measurement that contradicts the current model of the protection stack invalidates conclusions drawn from it — re-assess first, experiment second.
