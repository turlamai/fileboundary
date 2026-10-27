# v0.1 prototype review — 2026-10-27

**Status: reviewed locally, not imported or built.** This is evidence for [#1](https://github.com/turinglambdaai/fileboundary/issues/1), not an acceptance or release report. The ZIP is a prior conversation artifact named `FileBoundary-v0.1-source.zip`; do not commit sample encrypted documents, machine reports or user data. Its Windows behavior has **not** been executed or verified in this review environment.

## Source provenance and inventory

The ZIP contains one C# source file (`src/FileBoundary.cs`, 633 lines / 31,803 UTF-8 bytes), `build.cmd`, `launch.cmd`, `tests/smoke.cmd`, a Windows Actions YAML file, `AGENTS.md` and English/Chinese READMEs.

The source-file SHA-256, calculated on the ZIP member itself, is:

`e650bfa08eac3bf54302f7ae88bae3ca150585a6446b0d4a685c6b35217bba3e`

This digest identifies **only this observed prototype**. It must be rechecked before a future import. The prototype does not contain a project/solution file, pinned NuGet dependencies, an installation package, independent unit tests or a schema file.

## Observed behavior (source inspection, not runtime evidence)

| Concern | Prototype behavior | Review verdict |
| --- | --- | --- |
| Engine | `Engine` static class in the same file as GUI and CLI | Requires separation in #2 |
| CLI | `scan`, `diagnose`, `verify`, `help`, `selftest` | Useful prototype, **does not implement** the normative CLI v1 contract (#7) |
| GUI | WinForms tabs for scanning, `fltmc` diagnostics and export comparison | Prototype only; not Windows-tested |
| Scanner | File length, 16-byte magic signature, SHA-256 through ordinary `FileStream`; recursion skips directory reparse points | Read-view evidence only; signature alone cannot identify ciphertext or validate a full document |
| Diagnostics | Executes `fltmc.exe filters` and `fltmc.exe instances`; observes named process executable path | Does **not** inspect loaded DLL lists, hook status, key services or I/O transformation |
| Export comparison | Matches filenames by relative path, then checks candidate header and SHA-256 | Never reports a successful decryption; **no full structural/content validation** |
| Report output | `CreateNew` refuses overwrites; GUI defaults to Documents/FileBoundary/Reports | Output location needs explicit operator control and protected-root collision safeguards |
| Tests | `selftest` writes a synthetic PDF-looking prefix and other fixtures to a temporary directory | Only a smoke test; its PDF fixture is **not** a structurally valid PDF |

## Safety boundary — explicit source review

The inspected code contains no DLP allowlist spoofing, process injection, key extraction, driver unload, hook installation, registry modification or privileged persistence. Original inputs are opened with `FileAccess.Read`. `SaveReport` writes a **new** report with `FileMode.CreateNew`, and `SelfTest` creates/removes its own synthetic temporary directory. No direct decryption algorithm is present. These facts are from source inspection alone; runtime behavior and third-party interactions are not established.

Gaps to resolve **before** treating this as a trustworthy diagnostic tool:

1. **Input boundary.** Directory enumeration skips directory reparse points but not reparse-point **files**. A leaf symlink can read outside the intended scan root. Avoid implicit traversal and record exclusions. Do not let the reporting destination resolve within an input root.
2. **Process timeout.** `RunReadOnlyCommand` calls blocking `ReadToEnd()` on stdout and stderr before `WaitForExit(15000)`. A hung process can keep the read blocked, defeating the intended timeout. Drain streams asynchronously with bounded termination handling; never kill or modify the inspected protection services.
3. **CLI drift.** The prototype uses `SchemaVersion`, `Action`, `Files` and capitalized properties, prints non-JSON help/selftest, and uses exit codes `0/1/2` with semantics that conflict with `docs/cli-contract.md`. Do not mark #7 implemented until fixed and tested.
4. **Diagnostics evidence.** Raw `fltmc` text and generic warnings are not structured evidence. A failed `fltmc` command must not be interpreted as “no filters”; capture command success/exit code, elevation and errors distinctly.
5. **Verification semantics.** Magic bytes and two hashes from the same transparently filtered read view are insufficient for a “verified” or “decrypted” verdict. Keep `candidate-header-recognized` distinct from recovery success, and require independent validation and an authorized export provenance record for #5.
6. **Privacy / output.** Full root paths, process executable paths and exception messages can be present in JSON; reports are sensitive. Add opt-in path inclusion/redaction and prevent test/report data from being committed.
7. **Build claims.** The prototype compiles via installed Framework `csc.exe` and references `System.Web.Extensions`. Presence of that compiler and Windows execution were **not** tested here. The checked-in prototype workflow is not evidence that this new repository's CI exists or passes.

## Implementation sequencing

- **#1** Import the exact, hashed source and build scripts on a fresh branch only **after** this review; quarantine unsafe behavior where necessary. Do not merge untested code or old README/AGENTS content over this repository's charter. Run `build.cmd` and `tests\\smoke.cmd` on Windows, attach verbatim results and a CLI behavior transcript.
- **#2** Record the accepted stack in ADR-0002 and split engine/diagnostics/inventory/recovery/contracts/CLI/GUI so interfaces can be tested without opening a desktop window.
- **#6 / #7** Establish a real Windows CI build, structural synthetic fixtures and versioned JSON contract tests before calling the imported prototype deployable.
- **#5** Treat recovery as an authorized export **plus independent verification**, not a signature or same-process hash match.

## Evidence limits

Review performed by inspecting the existing source ZIP; local static checks confirmed its 633-line entry file and named I/O call sites. No Windows C# compiler, WinForms session, Windows filter manager or real encrypted files were available. Therefore **no build, functional, diagnostic or recovery success is claimed**.
