# Adversarial Research Program

The working research plan for defeating the transparent-encryption constraint on the operator machine. It implements the adversarial mandate of [ADR-0006](decisions/ADR-0006-adversarial-recovery-mandate.md); the fixed rules it operates under are in [security.md](security.md) (machine scope, containment, data safety, evidence discipline). Every claim here is evidence-classed the same way diagnostics output is: **measured**, **heuristic**, or **inferred**.

## Goal

One sentence: **produce verified plaintext of the encrypted backlog, by any effective path, with every step auditable and reproducible.**

Success is defined by the verification pipeline ([security.md](security.md#integrity-semantics)), not by any particular technique winning. A path counts as solved when it produces `verified` verdicts at batch scale without operator babysitting. A technique is only a means; there is no prestige in a hard path when a cheap one works.

## Ground rules (short)

- Operator-owned machine only; private repository; nothing published.
- Originals default read-only. State-mutating experiments follow the gated protocol ([security.md](security.md#technique-scope)): recorded plan → copies first → post-verification → audit trail.
- Every experiment = written hypothesis + minimal repro + measured evidence + artifact hashes. A negative result is a result: it is recorded and linked from the track, never silently dropped.
- Findings become engine recovery adapters only after their output passes the verification pipeline.

## Measured facts so far

From the recorded specimen measurements ([ADR-0003](decisions/ADR-0003-real-encrypted-sample-exception.md), [ADR-0004](decisions/ADR-0004-real-sample-twin-pair-and-deferred-removal.md)). The in-tree fixture is the encrypted/plaintext DOCX twin pair pinned in `baseline.json` ([ADR-0004](decisions/ADR-0004-real-sample-twin-pair-and-deferred-removal.md)); the earlier personal PDF specimen was retired from the tracked tree per [ADR-0005](decisions/ADR-0005-personal-pdf-removed-from-head.md) (history purge pending in [#23](https://github.com/turlamai/fileboundary/issues/23)) — its measurements below remain recorded evidence, and the file must not be re-fetched for builds.

- **Wrapper signature (measured):** 8-byte magic prefix `62 14 23 65` plus ASCII markers `E-SafeNet` and `LOCK` within the first 4096 bytes; body entropy 7.9–8.0 bits/byte; no native format structures visible (`%PDF-`, `PK` absent).
- **Type-portable wrapper (measured):** the same signature family wraps both a PDF and an OOXML docx; prefix bytes 4–7 differ per file (inferred: type/version/length metadata — unverified).
- **Constant 16-byte region at offset 0x28 (measured):** `bd41a84053766b3b8a061e67576e926d` is byte-identical across the PDF and docx specimens. A file-independent region in a per-file header is a high-value T0 target: candidate identities include a global format constant, a product/license identifier, or fixed key material (wrapped or raw). Resolving it is cheap and could shortcut the whole key question.
- **Known-plaintext oracle in hand (measured):** we hold a plaintext/ciphertext twin pair (same logical content, one written through the transparent-encryption path, one as plaintext), and we can mint additional twins on the operator machine at will — a chosen-plaintext setup against the real system.
- **Protection stack shape (measured at genre level, per-component identification pending):** minifilter + user-process DLL injection/API hooks + process whitelist + key management service ([architecture.md](architecture.md#context)). `doctor` today covers only bounded Filter Manager enumeration; service, module and hook inventory is still [#3](https://github.com/turlamai/fileboundary/issues/3) work.

## Measured results — T0 (2026-10-28, offline)

The wrapper is **broken at the format layer**; full findings and the
field-completion protocol live in [../research/t0/FIELD_PROTOCOL.md](../research/t0/FIELD_PROTOCOL.md).
Headlines (all measured on the committed twin + the retired PDF specimen):

- Cipher: XOR with a **512-byte repeating pad keyed by absolute file
  offset**, shared policy-wide across files — no per-file key exists at
  this layer.
- Header fields 4–5/6–7 size the wrapper's metadata zone (zone + tail = 512
  across all three specimens: docx 444+68, PDF 155+357, OS3 2013 112+400).
- The body is a rebuilt zip: first local header stripped (CD lho=0), its
  content relocated into the wrapper's metadata zone as a raw-deflate blob;
  everything else intact.
- Entry payloads are deflate **with a preset dictionary** — a fixed
  constant inside the client driver; small entries that avoid dictionary
  references decrypt outright (one entry already VERIFIED offline with the
  pad at 421/512 proven columns).
- Consequence (updated 2026-10-29): the break is **end-to-end offline**.
  The pad completed 512/512 using the wrapped file's own structure
  (object headers × xref records cross-vote — no twins needed for
  PDF-class files), and a full 25 MB specimen was recovered and verified
  (pypdf, 29 pages; see [../research/t0/README.md](../research/t0/README.md)).
  OOXML packages additionally need the driver's dictionary blob for
  entry-level byte-exactness (FIELD_PROTOCOL step 3); plain files do not.
  T1/T2 remain useful for OOXML fidelity and speed, but are no longer on
  the critical path.

## Attack surface

| # | Surface | Question it answers |
|---|---|---|
| S1 | On-disk wrapper format | What exactly is stored? Where does ciphertext start? Is a key (or wrapped key) in the header? |
| S2 | Process whitelist | What makes a process "whitelisted" — image name, path, signature, hash, driver-side callback logic? |
| S3 | Injected DLLs + API hooks | Which module decrypts, when, into which buffer, for which processes? |
| S4 | Key management service | Where do keys live — service memory, files, registry, derived from machine fingerprint? |
| S5 | Filter view semantics | Which byte view does a given open get — plaintext, ciphertext, or refusal? Does the view depend on process, path, or handle type? |

The single most strategy-deciding unknown: **are per-file keys stored in the file header (wrapped) or only in the key management service?** If in-header, offline decryption without driver or service is possible (S1+S4 → T4). If service-only, every path must route through S3 or S4. S5's view matrix decides whether we can even acquire guaranteed raw ciphertext for offline work.

## Research tracks

### T0 — Wrapper format analysis (offline, zero-risk, always available)

Pure static analysis of the pinned twin pair, recorded specimen measurements, and newly minted twins. No interaction with the protection system; runs anywhere, on copies.

- **Header field map:** parse the first kilobytes field-by-field across all samples — magic, bytes 4–7 semantics, fixed vs variable-length fields, offset where high entropy starts, trailer if any.
- **Twin arithmetic:** ciphertext−plaintext length deltas across many twins immediately expose block size, padding scheme, and per-file header length.
- **Algorithm identification:** alignment behavior, entropy profile, byte-distribution tests; candidate constructions (AES/SM4 in common modes, stream ciphers, XOR-PRNG schemes) tested against twins with key hypotheses derived from header bytes and machine fingerprint material — every candidate is verifiable, because we hold plaintext and ciphertext for the same content.
- **Chosen-plaintext minting:** create twins with adversarial plaintext (all-zero blocks, counter patterns, single-byte deltas) through the whitelisted-app write path; diff ciphertexts to fingerprint the mode (ECB block reuse, CBC chaining, CTR keystream) and test key reuse across files.
- **Output:** a header field map plus an algorithm hypothesis with a reproducible test against every pinned fixture (`baseline.json`) and every minted twin.

### T1 — Whitelist mechanism study and ride-along (interactive; usually the first real win)

- **Identify the whitelist basis (S2):** run own probe binaries under varied image names, paths, and signatures; observe which get plaintext views, using the probe-file protocol from [architecture.md](architecture.md#diagnostics-module--planned-3). Repeat for `CreateProcess` chains to test parentage effects.
- **Ride-along experiments, escalating in invasiveness — all on our own machine, our own processes:**
  1. **Scripted automation of a whitelisted app** (COM/UI automation): open target → save-as / export / print-to-PDF / clipboard / mail-out. Measures which output channels the filter re-encrypts and which it misses — genre products commonly re-encrypt ordinary writes but leak plaintext through export, print, or clipboard paths.
  2. **Injection into a whitelisted process we launch:** our DLL inside a whitelisted reader reads the target file (the filter hands it plaintext) and writes plaintext to our output directory. The process identity is genuine — nothing is spoofed.
  3. **Identity adoption** for our own binary, whatever S2 shows the whitelist keys on: image name, install path, signature. Each adoption is validated with the probe protocol, not assumed.
- **Output:** a measured channel × byte-view matrix, and the cheapest reliable ride-along adapter for `engine.recovery`.

### T2 — Key material extraction (decisive for offline decryption)

- **Inventory the KMS surface (S4):** service binaries and arguments, config/registry blobs, driver device objects and IOCTLs, named pipes/ALPC endpoints, key cache files. Diagnostics (#3) output feeds this directly.
- **Memory-scrape with twin verification:** open a twin's file in a whitelisted app, then scan that process's memory for key candidates by *testing* each high-entropy blob against the twin ciphertext — we hold plaintext, ciphertext, and (from T0) the algorithm hypothesis, so candidate keys are verifiable by decryption, not guessable. The same scan works against the KMS service process.
- **Interface replay:** enumerate driver IOCTLs and service endpoints, replay observed exchanges, map which call returns key material or unwrapped views.
- **Fingerprint-derivation test:** re-mint twins after controlled environment changes (hostname, volume serial, user) to determine whether keys derive from machine fingerprint — this answers whether extracted keys decrypt the whole backlog, and what migration would cost.
- **Output:** located key store(s), a repeatable extraction procedure, a verified key per fixture.

### T3 — Filter view semantics and raw acquisition (decides the whole strategy; cheapest first run)

- **Map the byte-view matrix (S5):** for a probe file, enumerate open contexts — normal opens from whitelisted and non-whitelisted processes, alternate device paths, raw volume handles, VSS shadow-copy reads, named streams, memory-mapped sections — and record the returned view for each.
- **Raw/shadow-copy acquisition:** volume and VSS reads bypass per-open filter decisions; if the backlog is readable raw, we obtain guaranteed on-disk ciphertext for the entire corpus — the safe input for T0/T2 — independent of live-filter behavior.
- **Offline extreme:** reading the volume from outside the running system (WinRE / offline NTFS access) has no filter instances and no injected DLLs at all; combined with T4 it is the cleanest possible recovery path.
- **Output:** the view matrix plus a raw-ciphertext acquisition path for the backlog.

### T4 — Standalone decryptor (endgame)

- Combine T0's format map with T2's key material into an offline decryptor: ciphertext + extracted key material → plaintext, no protection components involved at runtime.
- **Validation bar:** byte-exact reconstruction of the in-tree twin pair (the wrapped docx against its plaintext twin), then freshly minted twins of richer formats (including PDF) validated the same way before batch runs against the inventory manifest with the full verification pipeline. The retired PDF's recorded invariants ([ADR-0003](decisions/ADR-0003-real-encrypted-sample-exception.md)) serve as historical cross-checks, not as an in-tree fixture.
- If keys turn out to be service-wrapped per file, T4 absorbs T2 as a runtime dependency (extract-then-decrypt per batch) instead of failing.

## Experiment protocol

1. Write hypothesis and plan **before** running anything (experiment log issue or this document).
2. State-mutating experiments: recorded plan → operator sign-off → disposable copies/snapshots → post-verification of the round-trip fixture → full audit trail ([security.md](security.md#technique-scope)).
3. Every experiment records: environment (elevation, filter-stack snapshot), inputs (hashes), procedure, raw output, evidence class per conclusion.
4. Negative results are recorded and linked from the track. Dead ends are assets — they prune the tree for the next attempt.
5. Anything producing candidate plaintext goes through the standard verification pipeline before anyone calls it recovered.

## Priority and sequencing

1. **T3 first** — cheapest, and its view matrix decides whether offline ciphertext acquisition exists (shapes everything else).
2. **T0 in parallel** — offline analysis of material already in hand; zero risk, no machine interaction.
3. **T1 next** — the ride-along matrix usually yields the first recovered files fastest.
4. **T2 once T1/T3 evidence locates the key stores; T4 last** — the industrialization of whichever path proved out.
5. **Sanctioned channels when available** (vendor console/export functions): cheapest legitimate path, and their observed behavior is itself evidence for T3. Absence of sanctioned channels is the normal case for the historical backlog — which is exactly why this program exists.

## Relationship to the engine

Research produces knowledge; the engine productizes it:

- Each proven path becomes an `engine.recovery` adapter with the same audit-log and verification obligations as every other path — no privileged "research backdoor" bypassing the pipeline.
- The verification pipeline is technique-neutral and unchanged: whatever produced the candidate plaintext, only pipeline evidence yields `verified`.
- Diagnostics (#3) feeds every track: the view matrix (T3), module inventory (T1/T2), and hook findings are diagnostics features first, attack inputs second.
