# Windows native GUI — first implementation slice

**Status:** development preview; Windows build and package must pass the [GUI CI workflow](../.github/workflows/windows-gui.yml) before merging. This is not a production release or a recovery tool.

The [Rivet v0.13.0](https://github.com/turinglambdaai/rivet/releases/tag/v0.13.0) Windows host is checked into `windows/` and owned UI code uses XAML/C++/WinRT. Racket code in `app/backend.rkt` connects the typed Rivet RPC layer to `src/engine/summary.rkt`, which reuses the **same** read-only scanner and bounded diagnostic code as the CLI. The CLI does not depend on Rivet or WinUI.

## Windows development

Install Racket CS 9.3, Visual Studio 2022 C++ desktop tools, Windows SDK, and the pinned Rivet release:

```powershell
raco pkg install --auto --no-docs 'https://github.com/turinglambdaai/rivet.git#v0.13.0'
raco rivet inspect --json
raco rivet doctor --json
raco rivet schema check rivet-schema.json --json
raco test tests/summary-test.rkt
raco rivet dev
```

Development packaging:

```powershell
raco rivet build
raco rivet package
raco rivet verify
```

`doctor` runs fixed, read-only `fltmc.exe filters` and `fltmc.exe instances`; it does not change drivers. `scan` reads the requested file or directory and inspects at most **200** files in one GUI operation, returning only a summary without source paths or document content. Invalid files, skipped entries and permission failures must not be conflated with plaintext. A path can contain sensitive data; do not paste GUI screenshots showing real paths into public issues.

## Authorized-export UI (development preview)

The FileBoundary WinUI window now has two path boxes: the first selects the encrypted original (also used for scanning), and the second selects an **already authorized exported file**. `Check Export` calls `verify-export-summary` over Rivet's typed, asynchronous RPC. It uses the same `assess-authorized-export` Racket engine as the CLI and displays `FAILED` or `UNVERIFIED`, never `verified`. No path, key material or document contents are returned to the UI in the RPC summary. The app never exports or decrypts files. Full acceptance instructions: [Windows QA](windows-qa.md).

## Not yet supported

No GUI progress/cancel UI, persistent manifest, independent PDF/7z structural verification, authorized export validation, or installer is delivered by this slice. A successful build alone is not evidence of successful data recovery. GUI smoke on an interactive Windows 10/11 desktop is a separate gate before release. The package target may need a runtime prerequisite unless clean-machine tests establish otherwise.

## Architecture note

The `windows/` sources originate from the published Rivet v0.13.0 scaffold under Rivet's license; native WinUI edits stay in `windows/MainWindow.xaml[.h,.cpp]`, not in generated `windows/GeneratedBackend.hpp`. Regenerate typed clients with `raco rivet build` after changing `app/backend.rkt`. Contract changes must update `rivet-schema.json` intentionally, and the versioned JSON CLI remains independent. Reusable Racket libraries require separate review before publication.
