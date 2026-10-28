# Vendor-authorized recovery channel (E-SafeNet)

**Status:** the authorized export **verification** code exists as a developer preview. **FileBoundary cannot produce plaintext from E-SafeNet ciphertext on its own yet.** The vendor's approved decryption/authorization is the **preferred first path** when it is available ([ADR-0006](decisions/ADR-0006-adversarial-recovery-mandate.md)); when it is not — the common case for the historical backlog — recovery continues through the adversarial tracks in [adversarial-research.md](adversarial-research.md) under the same evidence pipeline. No decrypted content is created, modified, copied, or transmitted by the `verify` command: it only compares evidence.

## Evidence and product identification

The single owner-approved, private regression fixture is recognized by its `E-SafeNet` and `LOCK` wrapper and is `encrypted-recognized`, not plaintext. This identifies a *format family*, not an exact vendor build, licensing status, decryption key, or authorized export facility.

Vendor documentation describes CDG's configurable **document decryption/approval workflow** and optional **encryption/decryption integration middleware**, but the actual endpoints, policy, approvals, keys, and rights depend on the installed deployment. See:

- Official product capability overview: https://www.esafenet.com/html/2025/11_0810/23.html
- CDG product documentation and integration description: https://www.esafenet.com/html/2025/11_0810/22.html

Decryptors of unverified third-party provenance are **never** used — anything that decrypts must be built and audited in this repository or run under direct operator control. The adversarial tracks named in [ADR-0006](decisions/ADR-0006-adversarial-recovery-mandate.md) — key-scheme analysis, whitelist study and ride-along, driver-state experiments, extraction from protected processes — are **in scope**, but only through the gated, audited protocol in [security.md](security.md#technique-scope) and the experiment designs in [adversarial-research.md](adversarial-research.md). Ad-hoc runs outside that protocol are a process violation, not a shortcut.

## Operator workflow for a single file

1. **Keep the encrypted original unchanged** and create a safe backup according to the organization's policy. Do not upload original documents or decrypted copies to issues or CI.
2. Identify the E-SafeNet/CDG client version and whether the owner or administrator is **authorized to request document decryption**. Consult the deployed CDG administrator or the product's official support for the *document decryption workflow* or available supported integration API.
3. Use that **approved, auditable** decryption/export method to create a separate file **outside this repository and outside the protected source tree**. While executing this vendor channel, FileBoundary does not launch arbitrary whitelist programs or alter security policies to produce the export — scripted automation of whitelisted applications is a separate research track (T1 in [adversarial-research.md](adversarial-research.md)) with its own evidence rules.
4. Run the following read-only verification on the Windows machine with the Racket developer environment:

```powershell
racket src/cli.rkt verify --original "C:\\Encrypted\\document.pdf" --exported "D:\\ApprovedExports\\document.pdf"
```

If you have a **trusted original plaintext SHA-256** recorded before encryption (not a hash of a ciphertext read view), append:

```powershell
  --trusted-plaintext-sha256 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
```

The above 64-digit digest is an **illustrative placeholder**; substitute your own known pre-encryption digest, do not copy the sample hash into production commands.

5. Inspect the JSON output. `source` and `export` contain **basenames**, size, SHA-256, and recognized headers, not file bytes or full paths. `trustedPlaintextSha256Comparison` is `matched`, `mismatched`, or `notProvided`. `pdfStructureHints` checks only basic PDF header/EOF/xref markers (not full PDF structural validation).
6. Have the exported PDF independently rendered/opened in a permitted reader, validate the full structure with a trusted parser, and record the result in a local recovery audit. These checks are **not implemented or attested by this preview** and are therefore **not marked verified** by the command.
7. Keep the result `unverified` until every required evidence gate in [security.md](security.md) passes. Do not delete the encrypted original.

## Exit codes and failures

| Exit | Condition | Meaning |
| --- | --- | --- |
| **1** / `partial` | Export exists; no explicit wrapper or trusted-hash mismatch detected | **Unverified**. The export is merely a candidate pending independent checks. |
| **4** / `error` | Export is still recognized as E-SafeNet wrapped or differs from the trusted pre-encryption SHA-256 | **Failed** candidate; retry via the vendor exporter, or escalate along the path ordering in [recovery-workflow.md](recovery-workflow.md); never overwrite the original. |
| **2** / `error` | Arguments missing/malformed | Fix local invocation. |
| **3** / `error` | Unreadable/missing input or other runtime failure | Fix local permissions/path or stop; source remains untouched. |

Do not assume successful PDF header detection means that the document has been decrypted. SHA-256 reflects only **the current process's read view**; an installed transparent decryption layer may supply a different read view to another process.

## Missing capabilities

To achieve end-to-end verified recovery for existing files, FileBoundary still needs a **supported vendor export adapter** (only with the deployed owner's authorization and official API documentation), independent full-format verification, manual or auditable independent-reader evidence, persistent per-file recovery manifests and Windows installer validation. These are separately tracked in Issue #5 and the recovery roadmap. Product success is defined by **verified recovery** ([security.md](security.md#integrity-semantics)): through this channel when the vendor grants it, through the adversarial tracks ([adversarial-research.md](adversarial-research.md)) when it does not — either way, only the evidence pipeline issues verdicts.
