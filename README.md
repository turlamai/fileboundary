# FileBoundary

**Windows-native file encryption diagnostics and adversarial recovery research toolkit. Local-first, with a native Windows GUI and an agent-friendly CLI.**

**English** · [中文](README.zh-CN.md)

## Status

**v0.2.0 released** — the adversarial recovery core is productized on the headless CLI ([release](https://github.com/turlamai/fileboundary/releases/tag/v0.2.0)). Three-layer accounting, per the engineering charter:

- **Shipped (v0.2.0)**: `decrypt` (wrapped OOXML reassembled with per-entry CRC verification; wrapped PDFs rebuilt with a semantic head + xref spot-check), `pad twin` (policy-pad recovery from one aligned plaintext/ciphertext pair), and the self-update channel (`update now` against GitHub Releases with authenticated private-asset access and guarded delta packages). The release ships the source distribution + manifest; a bare directory updates 0.0.0 → 0.2.0 through the live channel (end-to-end verified).
- **Implemented and locally verified**: the full test suite (194 tests + JSON Schema contract validation) is green on Windows, including end-to-end decryption of three pinned real specimens ([ADR-0007](docs/decisions/ADR-0007-real-wrapped-decryption-fixtures.md)). CI runs are temporarily blocked by an account billing issue — merge gates are handled by review until it is restored.
- **Release train** ([#9](https://github.com/turlamai/fileboundary/issues/9), [ADR-0008](docs/decisions/ADR-0008-release-channel-and-self-update.md)): a tag-triggered [release workflow](.github/workflows/release.yml) builds the portable package, the update-channel full package + `manifest.json`, a source tarball, `SHA256SUMS.txt` and per-file checksums, smoke-tests the artifacts (clean extraction, GUI boot probe, CLI envelopes, update-apply into a clean install root) and publishes the private release with English notes. Per ADR-0010 (revising ADR-0008) the **MSI is the primary install face**; the portable zip and the explicit self-update commands remain.
- The GUI ships read-only scan, Filter Manager diagnostics, Check Export, the **Decrypt panel** and the **Pad Twin panel** over the same engine entries as the CLI ([#34](https://github.com/turlamai/fileboundary/issues/34), closed).

The historical C#/WinForms v0.1 is a reference prototype outside this repository, not the selected production architecture (see [Issue #1](https://github.com/turlamai/fileboundary/issues/1)).

### Headless developer preview

The Windows core CI now also checks `version`, `scan`, `doctor` and `verify` against [machine-readable JSON Schema contracts](contracts/command-data-v1.schema.json), using the actual Racket subprocess. These are **metadata/verification contracts**, not claims of standalone decryption, manifest storage or installer completeness.



### Install (Windows)

- **Installer (recommended)** — run `fileboundary-<version>-windows-x64.msi` from [Releases](https://github.com/turlamai/fileboundary/releases): per-machine install with Start-menu and desktop shortcuts ([ADR-0010](docs/decisions/ADR-0010-windows-msi-install-face.md)).
- **Portable GUI (no prerequisites)** — download `fileboundary-<version>-windows-x64.zip`, unzip anywhere, and run `RivetHost.exe` (or `FileBoundary.cmd`); the `README.txt` inside explains the panels.
- **Update channel** — an existing install moves to a new version with `update now` (or offline `update apply --package <zip> --manifest <manifest.json>`); installs live under `%LOCALAPPDATA%\FileBoundary\releases\<version>\`. There is no MSI/MSIX by design ([ADR-0008](docs/decisions/ADR-0008-release-channel-and-self-update.md)).
- **Headless CLI** — requires Racket CS 9.3; use the source distribution (`FileBoundary-v<version>-source.tar.gz`).

### Headless CLI from source

Requires Racket CS 9.3 on Windows (Windows 10/11 x64). Invoke from the repository root — or unzip a release and use `fileboundary.cmd`, which wraps the same CLI:

```powershell
# inventory & diagnostics (read-only)
racket src/cli.rkt scan "C:\\test-data" --max-files 500
racket src/cli.rkt doctor

# decryption (ADR-0006; policy pad defaults to research/t0/pad_full.json)
racket src/cli.rkt decrypt --in "C:\\Encrypted\\doc.docx" --out "D:\\Recovered\\doc.docx"
racket src/cli.rkt pad twin --plain "P:\\plain.xlsx" --cipher "C:\\ct.xlsx" --out "D:\\keys\\new-policy-pad.json"

# self-update (GitHub Releases; private repo -> set a read-only PAT)
$env:FILEBOUNDARY_GH_TOKEN = "<fine-grained PAT, contents:read-only>"
racket src/cli.rkt update now
```

Every command emits one versioned JSON envelope on stdout ([contract](docs/cli-contract.md)); machine-readable output is the normative interface.

Output is one JSON envelope; no file contents or full paths are emitted by default. Signatures are **not** proof of plaintext or restored data. `doctor` now provides a timestamped, bounded read-only Filter Manager inventory (fixed commands, 64 KiB/stream, 8 s timeout); `verify` now compares an **operator-provided authorized export** to the original source as a read-only evidence report; it does not create decrypted content or certify recovery. See [implementation limits](docs/implementation-slice.md).

The scanner rejects symbolic-link roots and skips linked leaf files/directories, recording skipped entries as a `partial` result. Explicit linked inputs return exit code `3` with a sanitized JSON `unsafeScanPath` error (also for `verify`); missing or inaccessible paths still return `runtimeError`. This is a path-level safeguard, **not** a guarantee against all Windows reparse-point types or concurrent link swaps; those remain open under [#10](https://github.com/turlamai/fileboundary/issues/10).

### Authorized export verification (read-only preview)

After an approved vendor/administrator export has **already** produced a separate candidate file, compare it against the encrypted original:

```powershell
racket src/cli.rkt verify --original "C:\\Encrypted\\document.pdf" --exported "D:\\ApprovedExports\\document.pdf"
```

This does **not decrypt** E-SafeNet ciphertext. Exit 1 means **unverified** and further independent checks are required; exit 4 rejects a still-encrypted wrapper or trusted-plaintext-hash mismatch. Read the [authorized recovery guide](docs/authorized-recovery.md) for vendor prerequisites and evidence requirements. Never delete originals based on this result.

### Windows GUI test package

The portable **FileBoundary-Windows-x64-dev** artifact is produced by [Windows GUI CI](.github/workflows/windows-gui.yml). The GUI supports a read-only scan, Filter Manager diagnostics and now **Check Export**, which compares an operator-supplied, already-authorized export with an encrypted original. Its `FAILED` or `UNVERIFIED` status is **not** a standalone decryption result. Follow the [Windows QA guide](docs/windows-qa.md) before testing on a protected machine; do not delete encrypted originals.

## Background

The target machine runs third-party transparent file encryption software that combines mechanisms typical of the genre:

- a Windows file-system **minifilter** driver intercepting file I/O,
- **DLL injection** and **API hooking** inside user processes,
- a **process whitelist** deciding which programs read plaintext,
- a **key management service** holding the encryption keys,
- transparent encryption on write and decryption on read.

Observed symptoms: whitelisted PDF readers open and save normally; files written to disk may be transparently encrypted; non-whitelisted software may fail to read those files. A backlog of historical files is already encrypted and needs analysis and recovery.

FileBoundary exists to make this situation measurable and beatable: the owner studies the mechanism, attempts every recovery path — sanctioned channels first when they exist, then the adversarial tracks — and accepts a verdict only from the evidence pipeline ([ADR-0006](docs/decisions/ADR-0006-adversarial-recovery-mandate.md)).

## What FileBoundary does

Planned scope — each capability lands through its tracked issue:

1. **Analyze the encryption mechanism** — enumerate minifilters, filter-driver and service configuration, injected modules, hook heuristics, and file I/O behavior on probe files ([#3](https://github.com/turlamai/fileboundary/issues/3)).
2. **Diagnose** — produce a machine-readable report of the active filter stack and per-process read/write behavior.
3. **Inventory encrypted files** — batch-scan drives, classify files by encryption likelihood, record state, SHA-256 and format information ([#4](https://github.com/turlamai/fileboundary/issues/4)).
4. **Recover — by any effective path, offline** — the T0 break productized: `decrypt` reassembles wrapped OOXML (docx/xlsx/pptx) with per-entry CRC verification and rebuilds wrapped PDFs (semantic head + xref spot-check) using the policy pad; `pad twin` recovers a policy pad from one aligned plaintext/ciphertext pair ([#5](https://github.com/turlamai/fileboundary/issues/5), [research program](docs/adversarial-research.md)).
5. **Verify integrity** — a recovered file is `verified` only after the full verification pipeline; a successful copy is not a successful decryption ([#5](https://github.com/turlamai/fileboundary/issues/5)).
6. **Manage the recovery flow** — manifest-driven selection, per-attempt audit trail, reconciliation of recovered set against the manifest ([docs/recovery-workflow.md](docs/recovery-workflow.md)).
7. **Two front ends** — a native Windows GUI and a CLI that speaks a versioned JSON contract for agents and automation ([#7](https://github.com/turlamai/fileboundary/issues/7)).
8. **Engineering rigor** — Windows CI, automated tests and bilingual documentation from day one ([#6](https://github.com/turlamai/fileboundary/issues/6), [#8](https://github.com/turlamai/fileboundary/issues/8)).
9. **Self-update** — an Ed25519-signed release feed checked silently at launch (throttled, off-switchable), with consent-gated in-app download and install plus rollback on failure ([ADR-0011](docs/decisions/ADR-0011-rivet-signed-update-pipeline.md)).

## Research mandate

FileBoundary is an adversarial recovery research program for the machine owner ([ADR-0006](docs/decisions/ADR-0006-adversarial-recovery-mandate.md)). There are no technique prohibitions on the operator-owned machine — key extraction, whitelist study and impersonation, driver probing, crypto analysis are all legitimate research subjects here. What is fixed is scope and evidence:

- **Scope** — only machines the operator owns and administers; the repository is private, internal-use, and nothing is published.
- **Data safety** — originals open read-only by default; experiments that mutate protection-system state require a recorded plan and run against disposable copies first ([docs/security.md](docs/security.md)).
- **Evidence** — a successful copy is not decryption; a recognizable header is not plaintext. Every recovery verdict comes from the pipeline in [docs/security.md](docs/security.md), regardless of which technique produced the candidate plaintext.

## Product shape

- **Engine** — all domain logic (diagnostics, inventory, recovery orchestration, verification) lives in a testable core, independent of any UI.
- **CLI** — thin adapter over the engine: JSON on stdout, human logs on stderr; contract defined in [docs/cli-contract.md](docs/cli-contract.md).
- **GUI** — native Windows presentation layer with no business logic of its own.
- **Contracts** — versioned JSON schemas shared by the CLI, the GUI, the tests, and agent consumers.

Anything the GUI can do, the CLI can do — agent parity is an architectural invariant, not a feature.

## Technology direction

The current experimental core and JSON CLI use **Racket**. The intended Windows-native GUI first candidate is **Rivet / WinUI 3**, with **Glaze / WebView2** as an evidence-based alternative. Low-level Windows work may use Racket FFI or narrowly scoped C/C++ user-mode components. See the [proposed ADR-0002](docs/decisions/adr-0002-prototype-stack.md) and [C#/WinForms source audit](docs/prototype-review.md). The source-controlled WinUI host now targets Rivet v0.13.0; see [Windows GUI development](docs/gui-development.md) and the actual GUI CI for build evidence. Interactive Windows acceptance and recovery are not yet complete. Extracting general-purpose Racket packages is optional and requires separate public release approval.

## Platform requirements

- Windows 10 / 11 x64.
- Administrator rights for diagnostics operations (minifilter and driver enumeration). Every diagnostic that requires elevation reports `requiresElevation` instead of failing silently.
- Local-first: no telemetry, no cloud component, no account.

## Documentation

| Document | Contents |
|---|---|
| [Architecture](docs/architecture.md) | module map, data flow, classification semantics, technology posture |
| [Security](docs/security.md) | authorization basis, technique scope, fixed rules, integrity semantics, data safety |
| [Adversarial research](docs/adversarial-research.md) | attack surface, research tracks, experiment protocol, priority |
| [Recovery workflow](docs/recovery-workflow.md) | the six-stage recovery process and verdict rules |
| [Vendor-authorized recovery](docs/authorized-recovery.md) | the vendor export channel and its verification workflow |
| [CLI contract](docs/cli-contract.md) | versioned JSON envelope, commands, exit codes, versioning policy |
| [Testing](docs/testing.md) | test layers, fixtures, red/green rules, CI gates |
| [Development](docs/development.md) | environment, workflow, artifact hygiene |
| [Decisions (ADR)](docs/decisions/) | architecture decision records |

`AGENTS.md` is the binding engineering charter for every contributor, human or AI.

## Roadmap

| Area | Issue | Status |
|---|---|---|
| Import and review the v0.1 prototype | [#1](https://github.com/turlamai/fileboundary/issues/1) | done (source audit in [docs/prototype-review.md](docs/prototype-review.md)) |
| Modular Windows application architecture | [#2](https://github.com/turlamai/fileboundary/issues/2) | done (engine/CLI/GUI split per [ADR-0002](docs/decisions/adr-0002-prototype-stack.md)) |
| Windows file encryption diagnostics | [#3](https://github.com/turlamai/fileboundary/issues/3) | core shipped (`doctor`); driver/service/module inspection planned |
| Encrypted file inventory and classification | [#4](https://github.com/turlamai/fileboundary/issues/4) | core shipped (`scan`); persistent manifest planned |
| File recovery and verification | [#5](https://github.com/turlamai/fileboundary/issues/5) | core shipped (T0 decrypt + per-entry verification; [research program](docs/adversarial-research.md)) |
| Windows CI and automated tests | [#6](https://github.com/turlamai/fileboundary/issues/6) | done (workflows live; runner temporarily blocked by account billing) |
| Versioned JSON CLI contract | [#7](https://github.com/turlamai/fileboundary/issues/7) | done (schemas + [CI contract gate](contracts/command-data-v1.schema.json)) |
| Bilingual documentation | [#8](https://github.com/turlamai/fileboundary/issues/8) | done (README mirror + ADR/decision records) |
| Windows release train (MSI + portable) | [#9](https://github.com/turlamai/fileboundary/issues/9), [#42](https://github.com/turlamai/fileboundary/issues/42) | release workflow + smoke live (tag-triggered); MSI install face per [ADR-0010](docs/decisions/ADR-0010-windows-msi-install-face.md) rides the next version |

## Development

`main` is the only long-lived branch. All changes land through pull requests; CI is the merge gate. Read [`AGENTS.md`](AGENTS.md) before contributing — human or machine. Workflow details: [docs/development.md](docs/development.md).

## Windows filter diagnostics (developer preview)

Run `racket src/cli.rkt doctor` in a Windows console. This command only invokes bounded, read-only `fltmc.exe filters` and `fltmc.exe instances`; each check records exit status, output truncation and timeout. A nonzero child result or missing elevation is **not** interpreted as no filters. The result can be `partial` with exit code 1. Full driver, service and injection inspection remains planned.

## License

Proprietary — internal use only. No license is granted and no LICENSE file exists yet; do not distribute the code or its artifacts outside the owner's control.
