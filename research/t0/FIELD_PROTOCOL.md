# Field protocol — completing the offline break on the operator machine

The offline phase (this repository, no protection stack installed) measured
and modeled the E-SafeNet wrapper end-to-end. Two small pieces of ground
truth remain, and both live on the machine where the protection software
actually runs. This protocol collects them; after step 3 the entire
encrypted backlog decrypts **offline**, file by file, with no interaction
with the protection system.

Status legend: every step is read-only against originals, writes only to
designated output directories, and records evidence per
[docs/security.md](../docs/security.md). Steps 2b/3 are T1/T2-track work
under the ADR-0006 mandate; nothing here mutates protection-system state.

## Measured wrapper model (offline results, all `measured`)

| Property | Value |
|---|---|
| Header magic | `62 14 23 65` + `E-SafeNet` + `LOCK` |
| Header bytes 4–5 (LE16) | size of the pre-body zone (docx 444, PDF 155, OS3 2013 sample 112) |
| Header bytes 6–7 (LE16) | zone tail inside the first 512-block (docx 68, PDF 357, OS3 400); zone + tail = 512 always |
| Body encryption | XOR with a **512-byte repeating pad** indexed by absolute file offset mod 512 |
| Pad scope | **policy-global** — the pad recovered from one file decrypts other files' prose (verified across docx + 25 MB PDF) |
| Body content | a rebuilt zip: first entry's local header stripped (CD keeps lho=0), its content stored as a raw-deflate blob in the wrapper's metadata zone; all later entries + CD + EOCD intact |
| Entry compression | raw deflate **with a preset dictionary** (`invalid distance too far back` without it) — the dictionary is a fixed constant inside the E-SafeNet client driver |
| Offline status | pad 421/512 columns proven (`research/t0/pad.json`); `_rels/.rels` fully VERIFIED; document/settings identified as dictionary-dependent; the rest derailed on unproven pad columns |

Reproduced by: `python research/t0/build_pad.py` then
`python research/t0/esafenet_decryptor.py <file> --pad=research/t0/pad.json`.

## Step 1 — Baseline diagnostics on the operator machine

```powershell
racket src/cli.rkt doctor
racket src/cli.rkt scan "C:\path\to\encrypted-backup" --max-files 500
```

Record the filter stack and specimen inventory. No elevation side effects.

## Step 2 — Mint known-plaintext twins and complete the pad

1. Pick a small test document. Open it in a **whitelisted** application,
   save-as under a new name (e.g. `twin1.docx`), then copy the file with a
   non-whitelisted tool (e.g. `cmd /c copy`) to `twin1.ct`. The whitelisted
   save yields the plaintext view; the copy from a non-whitelisted process
   yields the wrapped ciphertext of the same bytes (verify: header magic).
   Repeat with 3–4 different contents, including one all-zero-ish file
   (e.g. a text file of spaces) — zero-rich plaintext leaks pad columns
   directly.
2. For each pair, align plaintext to ciphertext (both known), compute
   `K[o mod 512] = ct[o] ^ plain[o]` per offset, and merge votes across
   pairs. Every column gets hundreds of votes — the pad completes to
   512/512 with overwhelming majorities.
3. Validate: run `esafenet_decryptor.py` with the completed pad against a
   held-out twin; all entries must report `VERIFIED` (CRC32 through the
   full pipeline, not just a readable header).

Record the completed pad as `pad-full.json` **outside the repository**
(containment rule: it is a recovery key).

## Step 3 — Extract the preset dictionary

Three independent routes, cheapest first:

1. **Config/driver scan**: locate the E-SafeNet install directory and its
   driver/DLL files; search for the dictionary buffer passed to
   `inflateInit2`/`uncompress`-style imports. A zlib dictionary is a plain
   byte blob; candidates validate by decoding `word/document.xml` of a
   twin into well-formed XML.
2. **Memory read**: open a wrapped file in a whitelisted app; the filter's
   decompressor holds the dictionary in memory. Dump the whitelisted
   process (own process, owner machine) and scan for the same blob.
3. **Reconstruct from references**: not needed if 1 or 2 succeeds.

Validate the dictionary the same way as step 2.3: twin entries must reach
`VERIFIED`, including byte-identity with the known plaintext twin.

## Step 4 — Batch offline recovery

With `pad-full.json` + dictionary:

```powershell
python research/t0/esafenet_decryptor.py <wrapped-file> `
    --pad=pad-full.json --out=D:\recovered\<case>
```

Run per file from the inventory manifest; every output goes through the
standard verification pipeline ([docs/security.md](../docs/security.md))
before any `verified` verdict is recorded. Batch results reconcile against
the manifest per [docs/recovery-workflow.md](../docs/recovery-workflow.md).

## Expected outcome

- Wrapper fully modeled; both missing constants collected in minutes.
- Offline decryptor reaches `VERIFIED` on twins (strongest evidence:
  byte-identity with plaintext twins), then on backlog files at batch
  scale — track T0+T4 of [docs/adversarial-research.md](../docs/adversarial-research.md) complete.
- If the live policy pad differs per policy revision (check: a backlog
  file that fails CRC under the completed pad), repeat step 2 against one
  file of that revision — the pad is per-policy, not per-file.
