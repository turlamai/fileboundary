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
OUT = Path("D:/Codes/fileboundary-artifacts/t0-samples/说给对方听.decrypted.pdf")


def main() -> int:
    pad = {i: v for i, v in enumerate(json.loads(PAD.read_text())["pad"])
           if v is not None}
    ct = PDF.read_bytes()
    n = len(ct)
    S = bytearray(ct[o] ^ pad[o % 512] for o in range(n))

    # page objects in the intact body
    page_objs = []
    for m in re.finditer(rb"(\d{1,6}) 0 obj", bytes(S[512:])):
        seg = S[512 + m.start():512 + m.start() + 400]
        if re.search(rb"/Type\s*/Page[\s>/]", seg) and \
                not re.search(rb"/Type\s*/Pages", seg):
            page_objs.append(int(m.group(1)))
    page_objs = sorted(set(page_objs))
    print(f"page objects: {len(page_objs)}")

    # does anything reference object 3?
    refs3 = len(re.findall(rb"3 0 R", bytes(S[512:])))
    print(f"references to '3 0 R' in body: {refs3}")

    kids = " ".join(f"{k} 0 R" for k in page_objs)
    head = bytearray()
    head += b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n"
    off1 = len(head)
    head += b"1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"
    off2 = len(head)
    head += (b"2 0 obj\n<< /Type /Pages /Kids[" + kids.encode() +
             b"] /Count " + str(len(page_objs)).encode() +
             b" >>\nendobj\n")
    assert len(head) <= 512, f"head too long: {len(head)}"
    head += b"%" + b".fb-head-reconstruction" + b"\n"
    head += b"%" * (512 - len(head) - 1) + b"\n"
    assert len(head) == 512, len(head)
    print(f"head rebuilt: obj1@{off1} obj2@{off2} total 512")

    # patch xref records 1, 2, 3 in the decoded table
    m = re.search(rb"xref\r\n0 (\d+)\r\n", bytes(S[512:]))
    tstart = 512 + m.end()
    def set_rec(k, off, gen=0, kind=b"n"):
        S[tstart + 20 * k:tstart + 20 * k + 20] = \
            b"%010d %05d %s\r\n" % (off, gen, kind)
    set_rec(1, off1)
    set_rec(2, off2)
    set_rec(3, 0, 65535, b"f")

    original = bytes(head) + bytes(S[512:])
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
