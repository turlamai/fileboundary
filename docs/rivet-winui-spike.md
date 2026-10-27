# Windows-native GUI feasibility: Rivet / WinUI 3

**Status:** experimental CI validation; not shipped FileBoundary GUI.

Tracks [#13](https://github.com/turinglambdaai/fileboundary/issues/13) and proposed [ADR-0002](decisions/adr-0002-prototype-stack.md).

## Goal

Prove that **this repository's Windows CI runner** can install pinned Rivet, generate a genuine first-party WinUI 3 host, embed a matching Racket CS backend, compile the native host, and check a development package. A headless `raco test` result from FileBoundary's CLI does not prove any WinUI code compiles.

## Validation environment

- GitHub Actions `windows-latest` (specific runner image and Visual Studio toolset recorded by the run).
- Racket CS **9.3** via `Bogdanp/setup-racket@v1.15`.
- Rivet **v0.13.0**, pinned using a Git tag source as documented in Rivet's `docs/ci.md`. This is a reproducible version preference, not an assertion that the tag is the newest release.
- A disposable scaffold created by `raco rivet new fb-rivet-spike` inside the CI workspace. The generated sample application is never committed.
- Actual `raco rivet inspect --json`, `doctor --json`, `build`, `package`, `verify`, all required to return zero.

## Nonclaims and remaining acceptance gates

Passing this workflow establishes **CI toolchain feasibility for a generated WinUI host only**. It does not prove FileBoundary application UI, structured RPC contract to `src/engine`, progress/cancellation, Windows elevation prompts, actual encrypted file recovery, accessibility, installation on a clean Windows 10/11 x64 machine, or real GUI interaction.

Those belong to separately tested product code under #2 and #13. Do not mark ADR-0002 accepted or claim GUI complete based on scaffold success alone.

If the spike fails, preserve exact toolchain errors and document the blocker. Before proposing a different language, compare a Glaze/WebView2 prototype with equivalent evidence.

The action compiles generated synthetic scaffold code only and does not open or publish any personal encrypted PDF fixture, diagnostic report or recovery artifact.
