# FileBoundary

**Windows-native file encryption diagnostics and authorized recovery toolkit. Local-first, with a native Windows GUI and an agent-friendly CLI.**

**English** · [中文](README.zh-CN.md)

## Status

**Racket core developer preview, not a finished product.** This branch introduces `src/engine/inventory.rkt` and `src/cli.rkt` for read-only file inspection, bounded scanning and a versioned JSON envelope. Windows compilation and test status must be taken from [the real workflow](.github/workflows/windows-core.yml). A native **Rivet/WinUI 3 GUI source preview** is now part of this branch, offering bounded read-only scan summaries and Filter Manager diagnostics. Native compilation/packaging must be checked by [Windows GUI CI](.github/workflows/windows-gui.yml) before the GUI can be described as buildable. Broad diagnostics, manifest persistence, **full independent recovery verification**, and actual vendor-authorized plaintext export remain **not implemented**. Basic read-only export comparison is a preview feature. The historical C#/WinForms v0.1 is a reference prototype outside this repository, not the selected production architecture (see [Issue #1](https://github.com/turinglambdaai/fileboundary/issues/1)).

### Headless developer preview

Requires Racket CS 9.3 on Windows. Invoke from the repository root:

```powershell
racket src/cli.rkt version
racket src/cli.rkt scan "C:\\test-data\\fixture.pdf"
racket src/cli.rkt scan "C:\\test-data" --max-files 500
raco test tests/inventory-test.rkt tests/cli-test.rkt
```

Output is one JSON envelope; no file contents or full paths are emitted by default. Signatures are **not** proof of plaintext or restored data. `doctor` now provides a bounded read-only Filter Manager inventory; `verify` now compares an **operator-provided authorized export** to the original source as a read-only evidence report; it does not create decrypted content or certify recovery. See [implementation limits](docs/implementation-slice.md).

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

FileBoundary exists to make this situation measurable and recoverable: administrator rights are used for diagnosis, and recovery is performed exclusively through authorized mechanisms.

## What FileBoundary does

Planned scope — each capability lands through its tracked issue:

1. **Analyze the encryption mechanism** — enumerate minifilters, filter-driver and service configuration, injected modules, hook heuristics, and file I/O behavior on probe files ([#3](https://github.com/turinglambdaai/fileboundary/issues/3)).
2. **Diagnose** — produce a machine-readable report of the active filter stack and per-process read/write behavior.
3. **Inventory encrypted files** — batch-scan drives, classify files by encryption likelihood, record state, SHA-256 and format information ([#4](https://github.com/turinglambdaai/fileboundary/issues/4)).
4. **Recover through authorized channels** — export or decrypt only via mechanisms the protection system sanctions: its own management console, export paths through whitelisted applications, or keys the owner legitimately holds ([#5](https://github.com/turinglambdaai/fileboundary/issues/5)).
5. **Verify integrity** — a recovered file is `verified` only after the full verification pipeline; a successful copy is not a successful decryption ([#5](https://github.com/turinglambdaai/fileboundary/issues/5)).
6. **Manage the recovery flow** — manifest-driven selection, per-attempt audit trail, reconciliation of recovered set against the manifest ([docs/recovery-workflow.md](docs/recovery-workflow.md)).
7. **Two front ends** — a native Windows GUI and a CLI that speaks a versioned JSON contract for agents and automation ([#7](https://github.com/turinglambdaai/fileboundary/issues/7)).
8. **Engineering rigor** — Windows CI, automated tests and bilingual documentation from day one ([#6](https://github.com/turinglambdaai/fileboundary/issues/6), [#8](https://github.com/turinglambdaai/fileboundary/issues/8)).

## Hard boundaries

FileBoundary is a diagnostics and recovery tool for the machine owner. It is not a protection-defeating tool:

- Original files are opened **read-only**; writes happen only in designated recovery output locations.
- Administrator rights enable diagnosis. They do **not** imply access to encryption keys, and FileBoundary never assumes otherwise.
- FileBoundary does **not** bypass DLP or access controls, extract keys from the key management service or drivers, impersonate whitelist processes, tamper with protection drivers, or attempt to defeat the encryption system.
- Success is claimed **only with evidence**: a successful copy is not decryption; a recognizable file header is not proof of plaintext. The full semantics are defined in [docs/security.md](docs/security.md).

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
| [Security](docs/security.md) | authorization model, hard boundaries, integrity semantics, data safety |
| [Recovery workflow](docs/recovery-workflow.md) | the six-stage authorized recovery process and verdict rules |
| [CLI contract](docs/cli-contract.md) | versioned JSON envelope, commands, exit codes, versioning policy |
| [Testing](docs/testing.md) | test layers, fixtures, red/green rules, CI gates |
| [Development](docs/development.md) | environment, workflow, artifact hygiene |
| [Decisions (ADR)](docs/decisions/) | architecture decision records |

`AGENTS.md` is the binding engineering charter for every contributor, human or AI.

## Roadmap

| Area | Issue | Status |
|---|---|---|
| Import and review the v0.1 prototype | [#1](https://github.com/turinglambdaai/fileboundary/issues/1) | planned |
| Modular Windows application architecture | [#2](https://github.com/turinglambdaai/fileboundary/issues/2) | planned |
| Windows file encryption diagnostics | [#3](https://github.com/turinglambdaai/fileboundary/issues/3) | planned |
| Encrypted file inventory and classification | [#4](https://github.com/turinglambdaai/fileboundary/issues/4) | planned |
| Authorized file recovery verification | [#5](https://github.com/turinglambdaai/fileboundary/issues/5) | planned |
| Windows CI and automated tests | [#6](https://github.com/turinglambdaai/fileboundary/issues/6) | planned |
| Versioned JSON CLI contract | [#7](https://github.com/turinglambdaai/fileboundary/issues/7) | planned |
| Bilingual documentation | [#8](https://github.com/turinglambdaai/fileboundary/issues/8) | planned |
| Windows installer and portable release | [#9](https://github.com/turinglambdaai/fileboundary/issues/9) | planned |

## Development

`main` is the only long-lived branch. All changes land through pull requests; CI is the merge gate. Read [`AGENTS.md`](AGENTS.md) before contributing — human or machine. Workflow details: [docs/development.md](docs/development.md).

## Windows filter diagnostics (developer preview)

Run `racket src/cli.rkt doctor` in a Windows console. This command only invokes bounded, read-only `fltmc.exe filters` and `fltmc.exe instances`; each check records exit status, output truncation and timeout. A nonzero child result or missing elevation is **not** interpreted as no filters. The result can be `partial` with exit code 1. Full driver, service and injection inspection remains planned. `verify` remains unimplemented; no ciphertext recovery is claimed.

## License

Proprietary — internal use only. No license is granted and no LICENSE file exists yet; do not distribute the code or its artifacts outside the owner's control.
