"""Final decryption of the wrapped PDF with the completed pad.

Layout (measured): [wrapper header 0..154][zone 155..511][body 512..].
Body byte p corresponds to original-file byte p-155; the zone holds the
original file's first 357 bytes as a raw-deflate blob. Recovery =
inflate(zone blob) + S[512:] → the original PDF, byte-exact if the blob
inflates.

Verification: xref records must point at '<obj> 0 obj' under the ORIGINAL
coordinate system (S position - 155), and pypdf must open the result.
"""
import json
import re
import zlib
from pathlib import Path

PAD = Path("D:/Codes/fileboundary/research/t0/pad_full.json")
PDF = Path("D:/Codes/fileboundary-artifacts/t0-samples/esafenet-locked-sample.pdf")
OUT = Path("D:/Codes/fileboundary-artifacts/t0-samples/说给对方听.decrypted.pdf")
ZONE_LO, ZONE_HI = 155, 512
SHIFT = 155  # S position p  <->  original position p - 155


def main() -> int:
    pad = {i: v for i, v in enumerate(json.loads(PAD.read_text())["pad"])
           if v is not None}
    assert len(pad) == 512, f"pad incomplete: {len(pad)}/512"
    ct = PDF.read_bytes()
    n = len(ct)
    S = bytes(ct[o] ^ pad[o % 512] for o in range(n))

    # 1) recover the original head from the wrapper zone
    head = None
    for start in range(ZONE_LO, 300):
        d = zlib.decompressobj(-15)
        try:
            out = d.decompress(S[start:ZONE_HI])
        except zlib.error:
            continue
        if out.startswith(b"%PDF"):
            head = out
            print(f"zone blob inflated from {start:#x}: {len(head)} B "
                  f"eof={d.eof} unused={len(d.unused_data)}")
            print("  head:", head[:80])
            break
    if head is None:
        print("zone blob did not inflate; will need head reconstruction")
        print("  zone bytes:", S[ZONE_LO:ZONE_LO + 64])

    # 2) reassemble
    if head is not None and len(head) == ZONE_HI - SHIFT:
        original = head + S[ZONE_HI:]
    else:
        # pad the head to the exact original length if short
        head2 = (head or b"%PDF-1.\n") + b"\x00" * max(
            0, ZONE_HI - SHIFT - len(head or b""))
        original = head2[:ZONE_HI - SHIFT] + S[ZONE_HI:]
        print("WARNING: head reconstructed with padding (not byte-exact)")
    print(f"original size: {len(original)} (wrapped {n}, shift {SHIFT})")

    # 3) verify: xref offsets must land on '<obj> 0 obj' in original coords
    tail = original[-65536:]
    rec = re.compile(rb"(\d{10}) (\d{5}) ([nf])\r\n")
    checked = bad = 0
    for m in list(rec.finditer(tail))[:200]:
        if m.group(3) != b"n":
            continue
        off = int(m.group(1))
        num = None
        if off + 32 <= len(original):
            window = original[off:off + 32]
            mm = re.match(rb"(\d{1,6}) 0 obj", window)
            checked += 1
            if not mm:
                bad += 1
    print(f"xref spot-check: {checked - bad}/{checked} offsets land on "
          f"object headers")

    # 4) write and open with pypdf
    OUT.write_bytes(original)
    print(f"wrote {OUT}")
    try:
        from pypdf import PdfReader
        r = PdfReader(str(OUT))
        print(f"pypdf: {len(r.pages)} pages, encrypted={r.is_encrypted}")
        info = r.metadata
        if info:
            print(f"  metadata: title={info.title!r} author={info.author!r} "
                  f"created={info.creation_date}")
        text = r.pages[0].extract_text() or ""
        print(f"  page 1 text ({len(text)} chars): {text[:160]!r}")
    except ImportError:
        print("pypdf not installed; skipping reader verification")
    except Exception as e:
        print(f"pypdf failed: {e}")
    return 0


if __name__ == "__main__":
    main()
