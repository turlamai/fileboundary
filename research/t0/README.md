# T0 — offline wrapper break: end-to-end pipeline

Decrypts E-SafeNet-wrapped files **fully offline** (no protection stack, no
driver, no vendor tooling). Demonstrated end-to-end on the retired 25 MB PDF
specimen: 29 pages recovered, text extraction and object-level checks pass.

## Model (all measured; see FIELD_PROTOCOL.md for the full table)

- The whole file is XORed with a **512-byte repeating pad** keyed by
  absolute file offset; the pad is **policy-global** across files.
- The wrapper overwrites original bytes `0..zone+tail` (zone = header field
  4–5, tail = field 6–7; zone+tail = 512) with its own header + metadata
  zone. Body bytes stay at **identical offsets** (no shift).
- Entry compression is **standard, dictionary-free raw deflate**. (An
  earlier hypothesis of a zlib preset dictionary was an artifact of an
  incomplete pad: with pad columns missing the decoder derails and zlib
  reports misleading errors like `invalid distance too far back`. With
  the completed pad every entry inflates cleanly and CRC-verifies.) For
  plain files (PDF etc.) the overwritten first 512 bytes are
  **reconstructed semantically**; for OOXML packages everything decrypts
  outright.

## Pipeline

```
python research/t0/build_pad.py            # 421/512 columns from the twin fixture (crc/struct/chain tiers)
python research/t0/pad_from_objects2.py    # complete the pad: object headers x xref records cross-vote (needs a wrapped PDF with a classic xref); emits pad_full.json
python research/t0/reconstruct_head.py     # PDF: rebuild the overwritten 512-byte head (catalog + pages tree), patch xref records
python research/t0/assemble_docx.py        # OOXML: reassemble a standalone .docx, all 12 entries CRC-verified
```

`decrypt_pdf.py` is the non-reconstructing variant (usable when the zone
blob inflates, e.g. once the driver dictionary is available).

Provenance of every pad column is recorded in the artifacts:
`pad.json` (base tiers) and `pad_full.json` (completed; the decisive tier
is the object-header ↔ xref-record cross-vote, ~2460 known-plaintext bytes
over ~1400 objects with zero conflicts).

## Results on the retired PDF specimen (26,516,346 B wrapped)

- Pad completed 512/512 offline.
- Body decrypts byte-exact from offset 512; xref spot-check 126/126 record
  offsets land on `N 0 obj`.
- Head rebuilt semantically; pypdf opens the result: **28 pages in the
  correct order** (cover page first), ~4.5 KB extractable text plus image
  XObjects. The cover page object (object 3) straddles the overwrite
  boundary at offset 512 — its surviving tail carries StructParents 0
  (first page) and /Contents 4 0 R, so the lost 82 dict bytes are
  reconstructed as filler + /X joined to the surviving '/XObject...' text,
  and the pages tree is rebuilt xref-driven (never crossing object
  boundaries — a naive content scan misclassifies FontDescriptor objects
  as pages and inserts blank pages).
- The first version of the document's own head (exact bytes of objects
  1–3) remains recoverable with the driver dictionary (FIELD_PROTOCOL
  step 3); the semantic reconstruction renders identically.

Originals are opened read-only; recovered plaintext stays in the
operator-designated artifacts directory, never in the repository.
