# ADR-0001: Project scope and boundaries

- **Status:** accepted
- **Date:** 2026-10-27
- **Deciders:** owner (turinglambdaai)

## Context

The owner's Windows machine runs third-party transparent file encryption software (minifilter + DLL injection + API hooks + process whitelist + key management service). Historical files are already encrypted. The owner holds administrator rights and needs: (1) measurement of how the mechanism behaves, (2) an inventory of encrypted files, (3) recovery through channels the protection system itself sanctions, and (4) verification that recovered files are genuine plaintext.

## Decision

1. FileBoundary is a **private, internal-use** repository: no open-source license, no website, no GitHub Pages, no marketing pages, no public releases until decided otherwise.
2. Target platform is **Windows 10/11 x64** only.
3. Product shape: one testable **engine**, two front ends — native **GUI** and **agent-friendly CLI** with a versioned JSON contract. Agent parity is an invariant.
4. Recovery uses **authorized mechanisms only** (vendor console, whitelisted-application export, owner-held keys). Bypassing DLP, extracting keys, impersonating whitelisted processes, and tampering with protection drivers are permanently out of scope ([../security.md](../security.md)).
5. Integrity semantics: copy success ≠ decryption success; `verified` requires the evidence pipeline ([../security.md](../security.md#integrity-semantics)).
6. Originals are read-only; artifacts are written only to operator-designated locations outside the repository.
7. Engineering rules live in [`../../AGENTS.md`](../../AGENTS.md); `main` is the only long-lived branch; all changes go through PRs gated by CI.

## Alternatives considered

- **A general-purpose encryption-analysis toolkit** — rejected: broader scope invites boundary erosion; the tool serves one owner's recovery need.
- **Recovery via non-sanitized mechanisms** (key extraction, whitelist spoofing) — rejected outright, permanently: prohibited by the authorization model.
- **Public open-source repository** — rejected for now: sensitive context (protection-product analysis) and no licensing decision made.

## Consequences

- The repository starts without a LICENSE file; distribution rights are withheld by default.
- No Releases exist until the release train ([#9](https://github.com/turinglambdaai/fileboundary/issues/9)) lands with evidence.
- The technology stack is deliberately undecided until ADR-0002; no production code is written before it is accepted.
- Every contributor inherits the hard boundaries above; changes to them require a superseding ADR.

## Scope of effect

All modules and documents; [`../../README.md`](../../README.md) and [`../../README.zh-CN.md`](../../README.zh-CN.md) mirror this decision in their Status / Hard boundaries / License sections.
