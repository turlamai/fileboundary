# ADR-0010: Windows MSI as the primary install face

- **Status:** accepted
- **Date:** 2026-11-03
- **Deciders:** owner (turlamai), explicit directive in session
- **Revises:** [ADR-0008](ADR-0008-release-channel-and-self-update.md) (installer rejection)
- **Relates to:** issue #42, family precedent: shuttle 1.1.0, taskly 0.2.6

## Context

ADR-0008 rejected msi/msix and standardized on the portable package plus the
explicit self-update channel. In practice that made the portable zip the only
first-run experience: 300+ files unpacked flat into whatever folder the user
chose, with `RivetHost.exe` indistinguishable from runtime noise, no top-level
directory, and no README. The owner unpacked v0.2.1 and could not tell how to
start the product — "比 shuttle 的打包差多了" — and directed the packaging to
match taskly.

The family evidence is unambiguous: shuttle and taskly both ship an MSI as the
primary Windows install face (Start-menu entry solves discoverability) and a
zip for advanced users; their zips are equally bare inside, but almost nobody
meets the product through them. And the pinned rivet toolchain (v0.13.0)
already builds the MSI — `raco rivet release` wraps WiX 5 with a stable
UpgradeCode derived from the project identifier, Start-menu and desktop
shortcuts, major-upgrade handling and clean uninstall. The earlier rejection
predated that capability being this turnkey.

## Decision

1. **The MSI becomes the primary Windows install face**, produced by the
   release train via `raco rivet release --development --without-updates`
   (WiX 5.0.2 prerequisite; extensions self-install on demand). Start-menu and
   desktop shortcuts point at `RivetHost.exe`.
2. **Scope is perMachine** (Program Files, HKLM, elevation prompt) — the rivet
   family standard. A per-user variant would fork FileBoundary from the
   shared installer code for no product gain; flagged in #42 for owner review.
3. **The portable zip remains**, now required to be self-explanatory: a single
   top-level directory, a bilingual `README.txt` at its root stating how to
   start the app and what the GUI panels do, and a `FileBoundary.cmd`
   launcher beside the exe.
4. **ADR-0008's unchanged parts stay unchanged**: GitHub Releases is the only
   distribution channel; every network access is an explicit operator-initiated
   update command; the update channel consumes FileBoundary's own
   `manifest.json` format (rivet's signed update manifest is not adopted);
   SHA-256 everywhere.
5. **Asset naming follows the family convention** (`fileboundary-<version>-windows-x64.{msi,zip}`)
   so cross-product release tooling stays uniform.

## Consequences

- The release train installs the WiX prerequisite and runs the rivet release
  flow; the previously hand-rolled portable-zip step becomes a post-process
  (inject README/launcher, deterministic timestamps) over the rivet-produced
  tree.
- The unpacked app directory no longer exists after `raco rivet release`
  (it deletes the staging tree); the update manifest is built from a staging
  extraction of the rivet portable zip instead.
- Users get a Start-menu entry with elevation on install; portable users get
  a zip that explains itself.
- The smoke gate gains zip-layout and MSI install/uninstall assertions.

## Alternatives considered

- **Stay zip-only, add README** — rejected: discoverability of a Start-menu
  install is the actual fix; the zip stays for locked-down machines.
- **Hand-rolled per-user WiX authoring** — rejected: forks the family
  installer for a marginal scope preference; revisit only if owner asks.
- **Adopt rivet's signed update manifest** — deferred: FileBoundary's update
  engine and manifest tooling work and are tested; migrating the channel
  format is a separate slice.
