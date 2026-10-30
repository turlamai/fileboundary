"""Rebuild the lost head of the wrapped PDF and produce the original file.

The wrapper overwrote original bytes 0..511 in place (header + metadata
zone; the zone's deflate uses the driver dictionary, unavailable offline),
so objects 1 (catalog), 2 (pages tree) and 3 are lost. Everything from
offset 512 on decrypts byte-exact under the completed pad.

Reconstruction: emit a minimal-but-valid head (header comment, catalog,
flat pages tree built from the scanned page objects), pad to exactly 512
bytes, patch the classic xref records 1/2 to the new offsets (record 3 →
free), and splice with the decrypted body. Verified with pypdf (page count,
text extraction) and an xref spot-check.
"""
import json
import re
import zlib
from pathlib import Path

PAD = Path("D:/Codes/fileboundary/research/t0/pad_full.json")
PDF = Path("D:/Codes/fileboundary-artifacts/t0-samples/esafenet-locked-sample.pdf")
OUT = Path("D:/Codes/fileboundary-artifacts/t0-samples/说给对方听.decrypted.v2.pdf")


def main() -> int:
    pad = {i: v for i, v in enumerate(json.loads(PAD.read_text())["pad"])
           if v is not None}
    ct = PDF.read_bytes()
    n = len(ct)
    S = bytearray(ct[o] ^ pad[o % 512] for o in range(n))

    # page objects, driven by the xref table (never crosses object
    # boundaries): for each table entry, check the object's OWN dict for
    # /Type /Page (excluding /Pages). Object-number order == generation
    # order == page order (verified: xref-offset order is identical).
    m = re.search(rb"xref\r\n0 (\d+)\r\n", bytes(S[512:]))
    tstart = 512 + m.end()
    count = int(m.group(1))
    page_objs = []
    for k in range(count):
        rec = S[tstart + 20 * k:tstart + 20 * (k + 1)]
        if rec[17:18] != b"n":
            continue
        off = int(rec[:10])
        if off < 512 or off + 200 > n:
            continue  # lost-head objects are rebuilt explicitly below
        if not re.match(rb"\d{1,6} 0 obj", S[off:off + 16]):
            continue
        seg = S[off:off + 4096].split(b"endobj")[0]
        if re.search(rb"/Type\s*/Page(?![s])", seg):
            page_objs.append(k)
    print(f"page objects (xref-driven): {len(page_objs)}: {page_objs}")

    # does anything reference object 3?
    refs3 = len(re.findall(rb"(?<!\d)3 0 R", bytes(S[512:])))
    print(f"references to '3 0 R' in body (word-boundary): {refs3}")

    kids = " ".join(f"{k} 0 R" for k in page_objs)
    # object 3 (the cover page) spans the overwrite boundary at 512: its
    # dict tail survives from 512 (StructParents 0 -> it IS page 1), only
    # the first 82 bytes were lost. Rebuild them so the head chunk ends
    # exactly at 512 and joins the surviving '/XObject' text.
    lost = bytes(S[512:729])
    assert lost.startswith(b"Object<</Image6 6 0 R>>/Font"), lost[:40]
    assert lost.endswith(b"endobj\r\n"), lost[-20:]
    prefix = b"3 0 obj\r\n<</Type/Page/Parent 2 0 R/Resources<<"
    pad_len = (729 - 430) - len(prefix) - 2 - len(lost)
    assert pad_len >= 0
    obj3 = prefix + b" " * pad_len + b"/X" + lost
    assert len(obj3) == 729 - 430, len(obj3)
    print(f"object 3 (cover page) rebuilt at 430, {len(obj3)} B, "
          f"StructParents 0")

    head = bytearray()
    head += b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n"
    off1 = len(head)
    head += b"1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"
    off2 = len(head)
    full_kids = [3] + page_objs
    kids = " ".join(f"{k} 0 R" for k in full_kids)
    head += (b"2 0 obj\n<< /Type /Pages /Kids[" + kids.encode() +
             b"] /Count " + str(len(full_kids)).encode() +
             b" >>\nendobj\n")
    assert len(head) + (729 - 430) <= 512 + 217, "layout mismatch"
    # obj3 lives at ORIGINAL offset 430..728 — i.e. it straddles the head
    # boundary. Head buffer: bytes 0..429 = header+obj1+obj2, then obj3
    # occupies 430..728 which overlaps the S body region 512..728 (kept).
    # So: emitted = head[0:430] + obj3[0:82] + S[512:]. Simpler: build
    # head up to 430, then place the first 82 bytes of obj3, then S[512:].
    assert len(head) <= 430, f"head prefix too long: {len(head)}"
    head += b"%" * (430 - len(head) - 1) + b"\n"
    assert len(head) == 430, len(head)
    print(f"head rebuilt: obj1@{off1} obj2@{off2} total 512")

    # patch xref records 1, 2 (rebuilt offsets) — record 3 already points
    # at 430 and is valid again now that object 3 is restored.
    m = re.search(rb"xref\r\n0 (\d+)\r\n", bytes(S[512:]))
    tstart = 512 + m.end()
    def set_rec(k, off, gen=0, kind=b"n"):
        S[tstart + 20 * k:tstart + 20 * k + 20] = \
            b"%010d %05d %s\r\n" % (off, gen, kind)
    set_rec(1, off1)
    set_rec(2, off2)

    original = bytes(head) + obj3 + bytes(S[729:])
    assert len(original) == n, (len(original), n)
    OUT.write_bytes(original)
    print(f"wrote {OUT} ({len(original)} B)")

    # verification
    tail = original[-65536:]
    rec = re.compile(rb"(\d{10}) (\d{5}) ([nf])\r\n")
    checked = bad = 0
    for mm in list(rec.finditer(tail)):
        if mm.group(3) != b"n":
            continue
        off = int(mm.group(1))
        if off < 512:
            continue
        checked += 1
        if not re.match(rb"\d{1,6} 0 obj", original[off:off + 32]):
            bad += 1
    print(f"xref spot-check: {checked - bad}/{checked} land on object headers")
    assert original[430:440] == b"3 0 obj\r\n<", original[430:445]
    try:
        from pypdf import PdfReader
        r = PdfReader(str(OUT))
        print(f"pypdf: {len(r.pages)} pages, encrypted={r.is_encrypted}")
        text = r.pages[0].extract_text() or ""
        print(f"page 1: {len(text)} chars extracted")
        print(f"  begins: {text[:120]!r}")
    except ImportError:
        print("pypdf missing: pip install pypdf")
    except Exception as e:
        print(f"pypdf failed: {e}")
    return 0


if __name__ == "__main__":
    main()
