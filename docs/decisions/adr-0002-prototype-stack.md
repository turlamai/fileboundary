# ADR-0002: Windows technology stack, pending Windows prototype validation

- **Status:** Proposed
- **Date:** 2026-10-27
- **Related:** [#1](https://github.com/turinglambdaai/fileboundary/issues/1), [#2](https://github.com/turinglambdaai/fileboundary/issues/2), [prototype review](../prototype-review.md)

## Context

The observed FileBoundary v0.1 prototype is a monolithic C# source file with WinForms and console entry points selected by a compile-time `CLI` flag. It uses .NET Framework 4.x compiler locations, built-in cryptography/WinForms/process APIs and `JavaScriptSerializer`. This stack is an **observed fact**, not yet an accepted architectural choice.

The repository requires a separately testable engine, a native Windows GUI, a stable JSON CLI contract, Windows-only deployment, and read-only-by-default operations. Build and runtime support must be evaluated on actual Windows 10/11 machines.

## Proposed direction — not accepted

Retain C# and native WinForms as an initial continuity candidate; strongly prefer dedicated engine, CLI and GUI projects over dual-compiling the same file. Evaluate a currently supported .NET LTS target, packaging footprint, x64 publishing, and reproducibility **after** compiling and testing the original prototype. The shipped app should not silently assume .NET Framework's `csc.exe` is installed.

Use documented Windows diagnostic APIs and fixed read-only system commands where appropriate. Do not create a kernel driver merely to enumerate existing filters. Any new privileged component requires a separate risk/maintenance decision.

## Consequences and decision gate

- Code import (#1) must not silently turn this proposal into an accepted ADR.
- Final selection (#2) needs a Windows build transcript, a small working engine/CLI/GUI split, packaging options, and testability/recovery boundary evidence.
- Once accepted, update `docs/development.md`, `docs/architecture.md`, both READMEs and build/test commands together.

## Alternatives to evaluate

- Keep .NET Framework + WinForms with explicit runtime/toolchain prerequisites (small migration cost; limited packaging and newer testing options).
- Adopt a currently supported .NET LTS + WinForms (modern SDK tooling; runtime packaging and Windows targeting to verify).
- Native C++/Win32 or WinUI (additional complexity without demonstrated benefit for the current file diagnostic and recovery-verification scope).

No option is selected until the above evidence is available.
