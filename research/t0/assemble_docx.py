"""Assemble the standalone .docx from a wrapped E-SafeNet file (final).

Pipeline (requires the completed pad, research/t0/pad_full.json):
1. de-XOR the whole file;
2. locate the rebuilt zip's central directory (the wrapper stripped the
   first entry's local header: CD keeps lho=0; its data survives as a raw
   deflate blob in the wrapper's metadata zone ending at zone_end);
3. re-emit a clean standalone zip: every entry gets a FRESH local header
   (extra field length = 0; the wrapped file's 520-byte extra zones are
   decrypt-to-zero padding, not data) followed by its pure deflate stream;
   then a freshly written central directory and EOCD.

Verification: zipfile reads every entry and checks its CRC32, plus the
content fingerprint in word/document.xml.
"""
import importlib.util
import json
import struct
import sys
import zipfile
import zlib
from pathlib import Path

HERE = Path(__file__).parent
spec = importlib.util.spec_from_file_location(
    "rec", HERE / "recover_docx_final.py")
rec = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rec)

CT = rec.CT
PAD = HERE / "pad_full.json"
OUT = Path("D:/Codes/fileboundary-artifacts/t0-samples/"
           "recovered-esafenet-sample-v2.docx")
BASE = 0x39E  # first byte of the wrapped zip's intact part


def main() -> int:
    pad = {i: v for i, v in enumerate(json.loads(PAD.read_text())["pad"])
           if v is not None}
    assert len(pad) == 512, f"pad incomplete: {len(pad)}"
    ct = CT.read_bytes()
    s = rec.apply_pad(ct, pad)
    eocd, cd_off, n = rec.find_cd(s)
    entries, cd_end = rec.parse_cd(s, cd_off, n)
    assert cd_end == eocd
    print(f"CD ok: {n} entries")

    first = entries[0]
    assert first["lho"] < 512
    blob = s[BASE - first["csize"]:BASE]
    content = zlib.decompressobj(-15).decompress(blob)
    assert len(content) == first["usize"]
    assert (zlib.crc32(content) & 0xFFFFFFFF) == first["crc"], "blob CRC"
    print(f"entry0 content verified: {len(content)} B")

    out = bytearray()
    new_offs = []
    for e in entries:
        if e["lho"] < 512:
            data = blob
            crc, csize, usize = first["crc"], first["csize"], first["usize"]
        else:
            li = e["lho"]
            nl, el = struct.unpack_from("<HH", s, li + 26)
            a = li + 30 + nl + el
            data = s[a:a + e["csize"]]
            crc, csize, usize = e["crc"], e["csize"], e["usize"]
            assert s[li:li + 4] == b"PK\x03\x04", f"bad local magic {li:#x}"
            probe = zlib.decompressobj(-15).decompress(data)
            assert len(probe) == e["usize"], f"probe fail {e['name']!r}"
        new_offs.append(len(out))
        out += (b"PK\x03\x04"
                + struct.pack("<HHHHHIIIHH", e["ver_need"], e["flags"],
                              e["method"], e["mtime"], e["mdate"],
                              crc, csize, usize, len(e["name"]), 0)
                + e["name"] + data)

    cd_start = len(out)
    for e, no in zip(entries, new_offs):
        csize = e["csize"] if e["lho"] >= 512 else first["csize"]
        out += (b"PK\x01\x02"
                + struct.pack("<HHHHHHIIIHHHHHII", 0x14, e["ver_need"],
                              e["flags"], e["method"], e["mtime"],
                              e["mdate"], e["crc"], csize, e["usize"],
                              len(e["name"]), 0, 0, 0, 0, 0, no)
                + e["name"])
    cd_size = len(out) - cd_start
    out += (b"PK\x05\x06"
            + struct.pack("<HHHHIIH", 0, 0, len(entries), len(entries),
                          cd_size, cd_start, 0))

    OUT.write_bytes(bytes(out))
    print(f"wrote {OUT} ({len(out)} B)")

    zf = zipfile.ZipFile(OUT)
    fails = []
    for zi in zf.infolist():
        try:
            data = zf.read(zi)
            if (zlib.crc32(data) & 0xFFFFFFFF) != zi.CRC:
                fails.append(f"{zi.filename}: crc")
        except Exception as e:
            fails.append(f"{zi.filename}: {e}")
    print(f"zipfile verification: "
          f"{'ALL 12 ENTRIES CRC OK' if not fails else fails}")
    import re as _re
    doc = zf.read("word/document.xml").decode("utf-8", errors="replace")
    plain = _re.sub(r"<[^>]+>", "", doc)
    hit = "123abc" in plain.replace(" ", "")
    print(f"fingerprint '123 abc' in plain text: {hit}")
    return 0 if not fails and hit else 1


if __name__ == "__main__":
    sys.exit(main())
