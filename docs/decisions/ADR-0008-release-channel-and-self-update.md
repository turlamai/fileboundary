# ADR-0008: Release channel and explicit self-update

- **Status:** accepted; installer rejection revised by [ADR-0010](ADR-0010-windows-msi-install-face.md) (2026-11-03): the MSI is now the primary Windows install face, channel and explicit-update rules unchanged
- **Date:** 2026-10-30
- **Deciders:** owner (turlamai), explicit directive in session
- **Relates to:** [ADR-0001](ADR-0001-project-scope-and-boundaries.md) (local-first clause), benchmark: Taskly's `X.Y.Z+<commit>` versioning and `current/` install layout

## Context

Distribution today is a CI-built portable package re-downloaded in full for
every change; there is no release channel and no update path. The owner
directed: add online updates modeled on Taskly — no full-installer
downloads for every iteration.

One charter line moves: [security.md](../../docs/security.md) says
"local-first: no telemetry, no network calls". An update channel needs
network. The amendment is narrow: **no background traffic and no telemetry
— every network access is an explicit operator-initiated update command.**
Local-first (no accounts, no cloud component, nothing leaves the machine)
is unchanged.

## Decision

1. **Channel: GitHub Releases** (the project's only distribution channel).
   Every release ships: the full portable package zip and a
   `manifest.json`.
2. **Version format:** `X.Y.Z` with optional `+<short-commit>` build
   metadata (Taskly convention), surfaced by `racket src/cli.rkt version`.
3. **Manifest v1:** `{schemaVersion, channel, version, commit, created,
   package:{kind:"full", name, bytes, sha256, url},
   deltas:[{kind:"delta", baseVersion, name, bytes, sha256, url}]}`.
   The engine validates the schema before trusting anything.
4. **Packages:**
   - *Full:* portable zip that embeds `manifest.json` with the per-file
     SHA-256 table; apply = verify package hash → extract to
     `releases/<version>/` → verify every embedded file hash → atomically
     bump the `current` marker.
   - *Delta:* zip against one base version containing only changed files
     (`payload/<path>` + `delta.json` operations `add`/`replace`/`delete`,
     every replace/delete guarded by the base file's SHA-256) plus the
     full target file table. Apply verifies all guards first; **any guard
     mismatch aborts the delta** and the operator falls back to the full
     package. This is what keeps updates from re-downloading everything.
5. **Install layout (Windows):** `%LOCALAPPDATA%\FileBoundary\releases\<ver>\`
   with `%LOCALAPPDATA%\FileBoundary\current.txt` as the plain-file
   version marker (no symlinks — they need elevation).
6. **CLI (normative interface, agent parity):**
   - `update check [--manifest URL|PATH]` — fetch manifest, compare against
     the running version, report `updateAvailable` + package metadata.
   - `update apply --package PATH --manifest PATH` — verify hashes, apply
     into the install root, bump `current`. Network use in v1 is confined
     to `check` and to an explicit `--url` download flag; apply-from-file
     is fully offline and is the form the tests exercise.
7. **Integrity:** SHA-256 everywhere (package, per-file, delta guards).
   The engine carries a dependency-free SHA-256 (`engine/sha256.rkt`,
   FIPS 180-4 test vectors in CI) — no new packages.

## Alternatives considered

- **Squirrel/velo-style background auto-update** — rejected: conflicts with
  local-first; updates must be operator-initiated.
- **msi/msix + store-style servicing** — rejected: outside the
  GitHub-Releases-only channel; portable-dir layout is Taskly-proven.
- **Binary diffs (bsdiff)** — deferred: file-level deltas reach the goal
  (no full re-downloads) without native diff tooling in CI.

## Consequences

- `update check` is the first sanctioned network call in the product;
  security.md is amended in the same PR (explicit-only traffic).
- Release engineering gains a manifest step
  (`tools/make_update_manifest.py`) — the release workflow must attach
  manifest + packages; CI is the gate.
- Delta updates only apply to a verified base; a drifted install falls
  back to full — the tool reports this instead of improvising.
- The WinUI GUI surfaces the same engine calls via the typed RPC boundary
  (follow-up slice); the CLI remains normative.

## Scope of effect

`src/engine/sha256.rkt`, `src/engine/update.rkt`, `src/cli.rkt`,
`tests/update-test.rkt`, `docs/cli-contract.md`, `docs/security.md`
(local-first wording), `tools/make_update_manifest.py`, release workflow
(follow-up).
