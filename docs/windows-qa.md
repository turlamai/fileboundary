# FileBoundary — Windows hands-on acceptance (developer preview)

**Status: authorized-scope decryption only.** This test checks the packaged Windows GUI, read-only detection, comparison against a **separately, officially authorized** exported file, and — where the operator owns the policy pad and is authorized to recover that content — decryption of wrapped files per [ADR-0006](decisions/). The GUI never bypasses the product's protections; the pad is operator key material that is not shipped with the package.

## Download and launch

1. Sign in to GitHub with access to `turlamai/fileboundary`.
2. Open [FileBoundary native Windows GUI workflow](https://github.com/turlamai/fileboundary/actions/workflows/windows-gui.yml).
3. Select the latest **successful `main` run**, and download the artifact named `FileBoundary-Windows-x64-dev` from its **Artifacts** section. A feature-branch run is only for PR review.
4. Unpack **the entire ZIP** to a local folder such as `D:\Tools\FileBoundary`. Keep `runtime/`, `res/`, DLLs and `RivetHost.exe` together; do not run the executable from inside a ZIP viewer.
5. Start `RivetHost.exe`. This is an unsigned, portable *development* package; it is not an installer or production release. If Windows blocks execution, check the actual warning, file provenance and your local software policy; do **not** disable Windows security software or enterprise controls.

## Three non-destructive checks

1. **Read-only inventory**: Put an encrypted test file in the first path field; select **Scan**. The result should show `Known encryption-wrapper signatures: 1` if this process sees the known E-SafeNet wrapper. If it reports 0, capture only sanitized status and ask whether the client supplies a different file view to this process.
2. **System diagnostics**: Select **Diagnostics**. The result should display filter/instance command status. Non-elevated access errors are not evidence that the machine has no filters. Try elevated mode **only if your local policy authorizes it**, and do not change drivers.
3. **Approved export comparison**: Put the encrypted original path in the first box and the **already-authorized exported candidate** in the second box. Select **Check Export**. 
   - `FAILED` means the candidate remains recognized as E-SafeNet-wrapped, or (in the CLI) mismatches a trusted plaintext baseline.
   - `UNVERIFIED` means no clear blocker was found, but it is **not** a statement of successful decryption.
   - The GUI creates **no** exported plaintext, alters **no** source file, and does **not** bypass the product's protections.

## Controlled decryption (pad available, ADR-0006 scope)

Only where recovery of the specific content is authorized **and** the operator owns the policy pad:

1. Set the pad for the session before launching the app (the package never contains pad material):
   ```powershell
   $env:FILEBOUNDARY_PAD = "D:\keys\pad_full.json"
   ```
2. Put the wrapped input path in the **Decrypt** panel's first box and the output destination in the second. Select **Decrypt**.
3. Acceptance:
   - OOXML (`kind: "ooxml"`): `verified` equals `total` and every entry reports `crcOk: true`; `output` names the written file.
   - PDF (`kind: "pdf"`): `headRebuilt: true` and `xrefBad: 0`.
   - Open the output in a strict consumer (Explorer zip view / Office / a PDF reader) — the original stays byte-identical and untouched.
   - With no pad configured, the panel must show a bounded error (no partial output file), never a guess.

## Controlled pad recovery (aligned twin pair available, ADR-0006 scope)

Only where recovering the policy pad is authorized:

1. Produce an aligned twin pair per [FIELD_PROTOCOL](../research/t0/FIELD_PROTOCOL.md): save one file through a whitelisted app (plaintext view), copy the same byte range through a non-whitelisted tool (wrapped view). Documents that merely share content are **not** twins — a misaligned pair must return `complete: false` with a high `missingCount`, never a guessed pad.
2. Fill the twin plaintext, twin ciphertext and pad output paths; select **Pad Twin**.
3. Acceptance: `covered: 512, complete: true`; the pad file exists at the operator-supplied path only; no pad material appears in the result panel. A recovered pad may then feed the Decrypt panel (set it via `$FILEBOUNDARY_PAD`).

## Controlled twin sample

The repository contains an owner-approved encrypted/plaintext DOCX twin pair under ADR-0004. CI verifies the known wrapper classification, file sizes/hashes, and the fact that comparing the already-plaintext twin **does not claim decryption**. The QA process on the operator machine should use copies outside the repository and only where approved. Do not upload additional real protected or plaintext documents to GitHub.

## Report checklist

- OS build (Windows 10/11 x64), launch success or exact failure message
- UI loads and buttons become enabled after embedded Racket initializes
- Scan output (counts, signature classification only, no personal paths)
- Diagnostic result codes (redact service names/hostnames as needed)
- Authorized export available: **yes/no**; export format and result: `FAILED`/`UNVERIFIED`
- Can the exported file independently open in an allowed normal reader outside the encrypting application? **yes/no/not attempted**
- Any crashes, packaging missing files, and exact error codes, with filenames/paths redacted

**Never delete the original based on a FileBoundary result.** If no authorized plaintext export route exists, that is a **blocked recovery prerequisite**, not a pass or a silent failure of the UI.
