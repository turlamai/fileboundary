"""Rebuild research/t0/pad_pdf_tier.json — the tail-grammar seed tier.

Reimplements the constraint pass that the (removed) tail-experiment
scripts contributed to the working pad: every classic xref record is a
20-byte cell 'NNNNNNNNNN GGGGG n<CRLF>' whose per-position alphabets
constrain the pad column at each covered offset, together with the digit
runs after /Prev, /Size, /XRefStm, startxref, the hex /ID strings and the
%%EOF suffix. Columns resolved here seed the object-header cross-vote in
pad_from_objects2.py (the two oracles are complementary: the tail pins
columns the object scan cannot reach and vice versa).
"""
import json
import re
from pathlib import Path

PAD = Path("D:/Codes/fileboundary/research/t0/pad.json")
PDF = Path("D:/Codes/fileboundary-artifacts/t0-samples/esafenet-locked-sample.pdf")
OUT = Path("D:/Codes/fileboundary/research/t0/pad_pdf_tier.json")
TAIL = 65536
TABLE = re.compile(rb"(?:\d{10} \d{5} [nf]\r\n){2,}")
DIGITS = set(b"0123456789")
HEX = set(b"0123456789ABCDEFabcdef")


def main() -> None:
    d = json.loads(PAD.read_text())
    pad = {i: v for i, v in enumerate(d["pad"]) if v is not None}
    ct = PDF.read_bytes()
    n = len(ct)
    tail_off = n - TAIL
    base_tail = bytes(ct[o] ^ pad[o % 512] for o in range(tail_off, n))

    regions = []  # (abs_lo, abs_hi, alpha or None=record grid)
    for m in TABLE.finditer(base_tail):
        regions.append((tail_off + m.start(), tail_off + m.end(), None))
    for pat, cont, alpha in ((rb"/Prev \d+", 10, DIGITS),
                             (rb"/Size \d+", 6, DIGITS),
                             (rb"/XRefStm \d+", 6, DIGITS),
                             (rb"startxref\r\n\d+", 8, DIGITS)):
        m = re.search(pat, base_tail)
        if m:
            lo = tail_off + m.end()
            regions.append((lo, min(lo + cont, n), alpha))
    m = re.search(rb"/ID\[<[0-9A-Fa-f]+>", base_tail)
    if m:
        gt = ct.find(b">", tail_off + m.end(), tail_off + m.end() + 80)
        if gt != -1:
            regions.append((tail_off + m.end(), gt, HEX))

    resolved = {}
    for col in range(512):
        cands = set(range(256))
        hit = False
        for lo, hi, alpha in regions:
            for o in range(lo, hi):
                if o % 512 != col:
                    continue
                hit = True
                if alpha is None:
                    back = base_tail.rfind(b"\r\n", 0, o - tail_off)
                    r = (o - tail_off) - back - 2 if back != -1 else None
                    if r is None or not (0 <= r < 20):
                        continue
                    allowed = (DIGITS if (r <= 9 or 11 <= r <= 15) else
                               {0x20} if r in (10, 16) else
                               {ord("n"), ord("f")} if r == 17 else
                               {0x0D, 0x0A})
                else:
                    allowed = alpha
                cands &= {v for v in cands if (ct[o] ^ v) in allowed}
                if not cands:
                    break
            if not cands:
                break
        for k, want in enumerate(b"%%EOF"):
            if (n - 5 + k) % 512 == col:
                hit = True
                cands &= {ct[n - 5 + k] ^ want}
        if len(cands) == 1 and hit:
            resolved[col] = cands.pop()
    print(f"tail-grammar tier: {len(resolved)} columns resolved")
    OUT.write_text(json.dumps(
        {"pad": [resolved.get(c) for c in range(512)],
         "resolved": sorted(resolved)}, indent=1))
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
