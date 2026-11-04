# ADR-0002: Racket-first Windows stack and native-interop validation

- **Status:** Accepted (2026-11-04, issue #13 closed) — the Racket + Rivet/WinUI 3 vertical slice is proven end to end: headless JSON CLI with 345-test suite, native WinUI 3 host with typed RPC round-trip (live-tested), bounded read-only diagnostics with explicit elevation/error/timeout semantics, MSI + portable packaging smoke on clean CI runners
- **Date:** 2026-10-27
- **Related:** [#1](https://github.com/turlamai/fileboundary/issues/1), [#2](https://github.com/turlamai/fileboundary/issues/2), [prototype review](../prototype-review.md)

## Context and owner preference

The observed FileBoundary v0.1 prototype is one C# / WinForms file, dual-compiled into a GUI and CLI via a `CLI` flag. It uses .NET Framework 4.x compiler paths, WinForms, cryptography and process APIs. This is **prototype provenance**, not a mandate to stay with C#.

The owner's desired implementation prioritizes **Racket**, preferably the existing first-party desktop family:
- [Rivet](https://github.com/turlamai/rivet): Racket backend and a native Windows **WinUI 3** front end with typed RPC.
- [Glaze](https://github.com/turlamai/glaze): Racket backend, Windows **WebView2** interface, typed API bridge and scoped capabilities.

The product is Windows-only, local-first, agent-native, read-only by default and intended for personal internal use; **no product website** is required. The owner is willing to use a second language where real platform constraints justify it, and favors extracting reusable Racket libraries for possible Racket Package Catalog submission.

## Candidate architecture (proposal, not implementation)

```text
    CLI (Racket)           GUI (Rivet WinUI 3 preferred; Glaze fallback)
          \                                /
           \---- versioned contracts -----/
                       |
                 Racket engine
       inventory / evidence / tasks / verification
                       |
           Windows diagnostic boundary
       Racket FFI / fixed read-only OS commands
                       |
       optional narrow C/C++ user-mode helper
       (only if a documented API cannot be used safely via FFI)
```

- **Default domain/CLI language: Racket.** Keep filesystem inventories, SHA-256, format checks, JSON schema output, state transitions, evidence classification, audit metadata and synthetic tests in separately testable Racket libraries. Do not couple the CLI to a GUI runtime.
- **GUI first choice: Rivet/WinUI 3.** The repo already has Windows native hosting, embedding and typed RPC described in its README. Validate real Windows 10/11 packaging and application-specific build behavior rather than inferring suitability from the framework's own CI.
- **GUI alternate: Glaze/WebView2.** If a quick diagnostic dashboard or packaging/maintenance trade-off materially favors a shared HTML UI, document evidence and change the selection through this ADR. Glaze is a desktop window, not a product homepage.
- **Windows integration:** use documented read-only Filter Manager / SCM APIs via Racket FFI where feasible; a narrowly scoped, auditable **user-mode** C/C++ helper is acceptable when ABI, COM/threading or API support makes direct FFI fragile. Start with fixed read-only `fltmc` and other documented diagnostics only where results and errors are captured with bounded execution. No kernel driver is justified for the initial inventory/authorized-recovery scope.
- **Kernel code:** if a future requirement demonstrably needs WDK/kernel development, handle it in a **separate ADR and risk review** with real driver signing/install/uninstall testing; never imply Racket can implement a Windows kernel driver.
- **Prototype handling:** keep the C# prototype as a frozen, provenance-hashed reference until tested. Port behavior and tests by slice. Do not force an unreviewed C# monolith into the production architecture and do not rewrite functional code without a validated equivalent.

## Selection gates (must be observed on Windows)

Before accepting this ADR in #2:

1. **Rivet Windows spike:** create a small Windows application using the published Rivet project workflow; demonstrate a native window, generated typed RPC, progress/cancel, persistent list or table view, error display, and a package that launches on a clean Windows 10/11 x64 machine. Record precise tools and test transcripts.
2. **Headless Racket spike:** run an independent Racket CLI with the versioned JSON envelope and exit codes, test SHA-256/format validation on synthetic data, and demonstrate no GUI dependency.
3. **Diagnostic FFI boundary spike:** query/filter-enumerate using a read-only API or bounded `fltmc` command, with explicit elevation/access-denied/unavailable outcomes; test low privilege, timeouts, Unicode paths, and cancel without modifying protection components.
4. **Compare Glaze only where warranted:** demonstrate a comparable small GUI if Rivet blocks a required interaction, packaging, accessibility or maintenance requirement. Record the cost (WebView2 dependency) and agent test support.
5. **Distribution/CI gate:** pin Racket + framework + native SDK versions; Windows CI can compile and run engine/CLI tests; generated/native GUI build and portable/installer packaging are tested. Do not require users of a packaged app to install Racket separately unless documented as a deliberate limitation.
6. **Evidence and data safety:** benchmark scans on representative synthetic PDF, 7z, ZIP and arbitrary binary fixtures, with memory/cancellation and no source modifications; ensure no heuristic is falsely labeled as proven recovery.

Failure of one spike can justify C#/WinForms or another native component for that **specific responsibility**. A wholesale C# rewrite requires recorded evidence that a Racket-first stack is not viable.

## Potential Racket package extraction

Prefer an internal collection/module first. Consider upstreaming only genuinely general-purpose, documented and tested abstractions, e.g.:
- a **Windows Filter Manager read-only enumeration** wrapper with structured errors, isolated from FileBoundary product logic;
- a **portable file-format/structure identification** library or a bounded Windows process diagnostic helper, if it fills a real ecosystem gap.

A public Racket Package Catalog submission is **optional and separate**. It requires a general API, Racket CS/Windows tests, Scribble docs/examples, independent versioning, license and ownership review, and explicit owner approval **before** making any private code public. Never publish user documents, encrypted samples or vendor-specific handling.

## Consequences

- Racket and Rivet become the **first candidates**, not unverified shipped implementation.
- A small native Windows helper is not a failure of the Racket-first design; it is an intentionally isolated platform boundary.
- Include a clear toolchain, reproducible commands, and real Windows evidence in the implementation PR that accepts this ADR.
- Update [development](../development.md), [architecture](../architecture.md), both READMEs and `AGENTS.md` alongside a final decision.
- Keep recovery restricted to authorized export/decryption pathways and independent evidence-based verification ([security](../security.md)).

## Alternatives considered

| Option | Advantages | Trade-offs / decision |
| --- | --- | --- |
| **Racket + Rivet (WinUI 3)** | Owner preference, first-party Windows UI, typed RPC, one Racket domain/CLI | **First spike candidate; unvalidated for this app** |
| **Racket + Glaze (WebView2)** | Faster HTML/CSS UX iteration, scoped APIs, agent window verification | Fallback if actual Windows spike supports it; native WebView runtime required |
| **Racket + narrow C/C++ helper** | Isolates difficult Win32 ABI or API access | A supplement to either UI, not a replacement for Racket |
| C# + WinForms / modern .NET | Existing prototype, familiar Windows SDK path | Viable evidence-based fallback if Racket-first proves unsuitable |
| Entirely native C++ / WinUI 3 | Lowest-level integration | Higher code/maintenance burden for a diagnostic tool; no demonstrated necessity |

**Decision not yet accepted.** No Windows spike, native integration test, or package release has been performed.
