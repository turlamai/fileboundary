# FileBoundary — Windows hands-on acceptance (developer preview)

**Status: not a standalone E-SafeNet decryptor.** This test checks the packaged Windows GUI, read-only detection, and comparison against a **separately, officially authorized** exported file. Direct decryption of existing E-SafeNet ciphertext is not implemented.

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
