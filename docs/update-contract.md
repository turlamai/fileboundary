# FileBoundary update contract

Online updates are the release vehicle. This document is the behavior
contract for the self-update pipeline (ADR-0011); the implementation is
rivet's signed update pipeline (the same one taskly runs) plus the
FileBoundary Windows hosts' install handoff. It replaces the ADR-0008
SHA-256-only `manifest.json` channel, which is retired.

## Trust and transfer (backend-owned)

- The channel feed is the rivet signed-manifest wrapper
  (`update-stable.json`): an inner rivet update manifest, base64-wrapped
  with an Ed25519 signature and key id. The trust root (SPKI DER, base64)
  is embedded in `app/update.rkt`; the key id is `fileboundary-2026-11`.
- The payload is attacker-controlled until the signature verifies: the
  wrapper is authenticated *before* semantic parsing (rivet
  `verify-signed-manifest` semantics; HTTP feeds are rejected outright).
- Artifacts are size- and SHA-256-verified against the *signed* manifest
  before the download is renamed into place. Downloads land under
  `%LOCALAPPDATA%\FileBoundary\updates\` and operator documents are never
  touched.
- Download watchdogs: the transfer breaks after 120 s without byte
  progress or 30 minutes total (rivet defaults), and the host adds its own
  30-minute cap.

## Triggers

- **Silent check shortly after launch**: 3 s after the backend is ready,
  throttled to once per 4 h via the persisted `last-update-check` stamp.
  The stamp is written only when a check *settles* — an answer or a
  definitive failure — so one offline launch cannot silence four hours of
  launches. Silent mode never nags: failures are ignored, an available
  update is the only thing that surfaces.
- **Manual check** (`检查更新` button): bypasses the throttle and the
  auto-check toggle; every outcome is reported, with the GitHub Releases
  page as the escape hatch when the feed cannot be reached.
- **Auto-check toggle** (`auto-check-updates`, default on): when off,
  silent checks skip entirely. The toggle lives in the update panel.
- Dev copies (no packaged `res/core.zo`, or running from a temp path)
  never phone home.

## Check → download → install flow

1. The host stamps `install-flavor` (`msi` when the executable sits under
   Program Files, `zip` otherwise) **before** every check — the backend
   selects the matching signed artifact; a fire-and-forget startup stamp
   must not race the first check.
2. An available update surfaces as a consent dialog (version + size).
   Nothing downloads before the user accepts.
3. The download runs in the backend with a progress phase the host polls
   (400 ms); the start/cancel RPC is a toggle while a transfer is active.
4. A downloaded update surfaces an install consent — installing is a
   separate, explicit step, and only the user's confirmation closes the
   app.

## Install handoff (host-owned, per install face)

- **MSI face** (Program Files): a generated batch waits (≤ 30 s) for this
  process to exit, runs `msiexec /passive /norestart /i` with a verbose
  log into `%TEMP%\fileboundary-update\msiexec.log`, and relaunches the
  app. Per-machine installs surface exactly one UAC consent (unavoidable
  under `/passive`); msiexec exit codes 0/1641/3010 count as success.
- **Portable zip face**: a generated batch waits for exit, extracts the
  zip to a scratch dir (`tar -xf`), moves the install dir to `.old`,
  `robocopy /E /MOVE`s the new files in, relaunches, and writes the
  success marker. The extract happens **before** the old install is
  touched, so a corrupt archive can never break the running copy; any
  failure restores `.old`, relaunches the old build and leaves the failure
  marker.
- **Next launch**: a success marker retires the `.old` fallback copy; a
  failure marker is reported once (with the recorded reason) and cleared.
- The updater never deletes or touches operator data: settings and
  downloads live under `%LOCALAPPDATA%\FileBoundary`, swaps touch only the
  application tree.

## Release channel

- Feed URL: `https://github.com/turlamai/fileboundary/releases/latest/download/update-stable.json`
  (fetch); artifact URLs inside the manifest are pinned to the concrete
  release tag (immutable).
- Single `stable` channel; staged rollout is supported by the pipeline
  (sticky per-install 0-99 bucket vs the manifest `rollout` percentage)
  and left at 100% unless a bad release needs throttling.
- Downgrades are refused (SemVer comparison against the running version).
- `scripts/update-keys.sh` generates the signing keypair (private PEM in
  the operator key directory + GitHub secret `RIVET_UPDATE_PRIVATE_KEY`);
  `scripts/check-release-signing-key.sh` runs before packaging and again
  before publication and fails closed on any mismatch with the embedded
  trust root.
- Key rotation: ship a build that trusts the next key first (dual-trust
  window, `#:trusted-keys`), then switch the signing key, then drop the
  old trust root in a later release.

## Failure UX

Update errors must be user-capturable: every failure dialog carries a
`复制错误` button (clipboard), and install failures also land in
`%TEMP%\fileboundary-update\update-failed.txt` for the next-launch report.
