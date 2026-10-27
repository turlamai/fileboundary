# First Racket vertical slice — code and evidence boundaries

**Status: implementation submitted for Windows CI; not a release.** Tracks [#4](https://github.com/turinglambdaai/fileboundary/issues/4), [#7](https://github.com/turinglambdaai/fileboundary/issues/7), [#13](https://github.com/turinglambdaai/fileboundary/issues/13).

## Executable commands

Requires **Racket CS 9.3** on Windows (development only):

```powershell
racket src/cli.rkt version
racket src/cli.rkt scan "C:\\test-data\\fixture.pdf"
racket src/cli.rkt scan "C:\\test-data" --max-files 500
raco make src/engine/inventory.rkt src/cli.rkt
raco test tests/inventory-test.rkt tests/cli-test.rkt
```

Exactly one JSON envelope on stdout; process exit code: 0 complete, 1 partial, 2 invalid arguments, 3 runtime/unimplemented. Commands `doctor` and `verify` currently return a structured **notImplemented** error (3) — not faux diagnostics or decryption.

## Deliberate nonclaims

- PDF, ZIP and 7z **header recognition** does not prove end-to-end format validity, plaintext or successful restoration. Such files classify as `unknown`.
- The specific observed wrapper signature (8-byte prefix plus `E-SafeNet` and `LOCK` marker in the first 4096 bytes) is labelled `encrypted-recognized` **heuristically**. It does not identify the encryption key, recovery feasibility or the vendor's implementation.
- SHA-256 hashes what this process can **read**. An intervening transparent-encryption system may serve different byte views to different processes; the hash is not a guaranteed raw-on-disk ciphertext digest.
- The output contains filename/size/hash/signature but not full source paths or file contents. Filenames and hashes can themselves be sensitive; keep all CLI output local and out of the repository.
- The scanner excludes file/directory links by type, catches unreadable entries, reports counts, enforces a 1000-file default and configurable 1–100000 limit. This is **not** a hardened forensic snapshot against races from concurrent filesystem mutation, nor a replacement for VSS.
- No output manifest is persisted in this initial slice. `.fbmanifest.json` is reserved for a later opt-in output implementation that enforces output location separation.
- No kernel driver, user-mode hook, process impersonation or key extraction is present.

## Follow-up work

- Build the full inventory manifest/resume pipeline (#4), an independent structural verifier (#5), and user-approved diagnostics (#3).
- Separate domain engine from UI, validate a native Rivet Windows host and packaged runtime (#2/#13).
- Strengthen Windows filesystem traversal against races and long/Unicode paths; add resilience and cancellation for large directory scans (#10).
- Schema tests currently assert the output envelope keys and exit code behavior; independent JSON Schema validator integration remains pending (#7).

**Windows validation:** local Linux/container environment lacks Racket. Do not assert the code compiles or tests pass until the new Windows Action provides real results.
