## What

## Why

## How tested

- [ ] New/updated tests cover the change (red/green evidence for bug fixes)
- [ ] Full local suite run — command and output:

## Security boundary check

- [ ] Touches diagnostics / recovery / permissions / output writing — checked line-by-line against [docs/security.md](docs/security.md) (if untouched, say so)

## Checklist

- [ ] Docs updated in the same PR (`README.md` + `README.zh-CN.md`, plus affected `docs/`)
- [ ] ADR added for any architecture/contract/security decision ([docs/decisions/](docs/decisions/))
- [ ] No secrets, recovered files, diagnostic dumps, or scan databases committed
- [ ] No changes that weaken CI, tests, or review gates (those require an ADR + owner approval)
- [ ] Every completion claim in this PR is backed by evidence above
