# Development

## Environment

- Windows 10 / 11 x64 for development and testing; administrator rights needed to exercise full diagnostics ([#3](https://github.com/turlamai/fileboundary/issues/3)).
- Toolchain: **Racket-first preferred**, with Rivet/WinUI 3 as the initial native Windows GUI candidate and Glaze/WebView2 as a fallback, as documented by [proposed ADR-0002](decisions/adr-0002-prototype-stack.md). The C#/WinForms v0.1 prototype is not the default stack. Pin a concrete Racket CS version, package commit/release and native SDK only after actual Windows spikes (#1/#2). Until that decision is accepted, this document defines the **workflow**, not invented build commands; verified commands arrive with the accepted ADR.
- Editor and line-ending hygiene: [.editorconfig](../.editorconfig) + [.gitattributes](../.gitattributes) (LF in the repository).

## Workflow

1. **Sync.** `git pull --rebase` on `main`; clean worktree; `main` matches the remote before you branch.
2. **Branch.** Short-lived branch: `feat/<topic>`, `fix/<topic>`, `docs/<topic>`. `main` is the only long-lived branch.
3. **Slice.** Work in small, individually acceptable slices; each slice records its scope, dependencies, and verification evidence. Multiple worktrees if running parallel sessions.
4. **Test.** Red/green for bug fixes; full suite before pushing; evidence goes in the PR ([testing.md](testing.md)).
5. **PR.** Use the PR template; state what/why/how-verified; check the [security.md](security.md) boundaries if touching diagnostics, recovery, permissions, or output writing.
6. **Merge.** CI green required; squash merge to keep history linear; delete the branch after merge. `main` always green: whoever breaks it fixes or reverts immediately.

The PR path applies to everyone, including administrators. Server-side enforcement (branch protection / rulesets) requires GitHub Pro on private repositories — until the plan allows it, the rule is enforced by review discipline, and it gets configured the moment the plan does ([#6](https://github.com/turlamai/fileboundary/issues/6)).

## Coding standards

The binding charter is [`AGENTS.md`](../AGENTS.md). Highlights:

- Domain logic only in the engine; CLI and GUI are thin adapters ([architecture.md](architecture.md)).
- Dependencies point downward per the module map; `contracts` depends on nothing.
- Code comments in English; docs English normative + zh-CN mirror for user-facing paths.
- Architecture decisions go through [ADRs](decisions/) — a decision that isn't recorded doesn't exist.

## Artifact hygiene

Recovery outputs, scan manifests, diagnostics reports, and audit logs are sensitive and **never** live inside the repository:

- Write them to operator-designated directories outside the repo (reserved extensions: `.fbreport.json`, `.fbmanifest.json`, `.fbaudit.jsonl` — see [cli-contract.md](cli-contract.md)).
- `.gitignore` ignores them as belt-and-suspenders; the real rule is operator discipline.
- Issues and PRs may contain sanitized diagnostics output: no file content, no keys, no unnecessary personal paths ([security.md](security.md#data-safety)).

## Decisions

Any decision affecting architecture, the CLI contract, security boundaries, or the release process is recorded as an ADR in [docs/decisions/](decisions/) using the [template](decisions/adr-template.md), in the same PR as the change that implements it.
