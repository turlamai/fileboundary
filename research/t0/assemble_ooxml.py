"""Assemble a standalone .xlsx (or any OOXML zip) from a wrapped file.

Generalization of assemble_docx.py: all layout anchors are derived from
the wrapper header and the decoded central directory instead of being
hardcoded (BASE = first intact local header position; entry 0's stripped
data lives in the wrapper metadata zone ending right at BASE).

Verification: zipfile reads every entry and checks its CRC32, then
openpyxl (if available) opens the workbook and reports sheets.
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


def assemble(src_path: Path, out_path: Path) -> int:
    pad = {i: v for i, v in enumerate(json.loads(
        (HERE / "pad_full.json").read_text())["pad"]) if v is not None}
    assert len(pad) == 512, f"pad incomplete: {len(pad)}"
    ct = src_path.read_bytes()
    assert ct[:4] == b"\x62\x14\x23\x65", "not an E-SafeNet wrapper"
    zone = struct.unpack_from("<H", ct, 4)[0]
    tail = struct.unpack_from("<H", ct, 6)[0]
    s = rec.apply_pad(ct, pad)
    first_pk = s.find(b"PK\x03\x04", 512)
    base = first_pk
    print(f"wrapper: zone={zone} tail={tail} first intact PK {base:#x}")

    eocd, cd_off, n = rec.find_cd(s)
    entries, cd_end = rec.parse_cd(s, cd_off, n)
    assert cd_end == eocd
    print(f"CD ok: {n} entries")

    first = entries[0]
    assert first["lho"] < 512, "expected stripped first entry"
    blob = s[base - first["csize"]:base]
    content = zlib.decompressobj(-15).decompress(blob)
    assert len(content) == first["usize"], (len(content), first["usize"])
    assert (zlib.crc32(content) & 0xFFFFFFFF) == first["crc"], "blob CRC"
    print(f"entry0 {first['name']!r}: {len(content)} B CRC OK")

    out = bytearray()
    new_offs = []
    for e in entries:
        if e["lho"] < 512:
            data = blob
            crc, csize, usize = first["crc"], first["csize"], first["usize"]
            name = e["name"]
        else:
            li = e["lho"]
            assert s[li:li + 4] == b"PK\x03\x04", f"bad local magic {li:#x}"
            nl, el = struct.unpack_from("<HH", s, li + 26)
            a = li + 30 + nl + el
            data = s[a:a + e["csize"]]
            crc, csize, usize = e["crc"], e["csize"], e["usize"]
            name = e["name"]
            assert (zlib.decompressobj(-15).decompress(data)
                    if e["method"] == 8 else data) is not None
        new_offs.append(len(out))
        out += (b"PK\x03\x04"
                + struct.pack("<HHHHHIIIHH", e["ver_need"], e["flags"],
                              e["method"], e["mtime"], e["mdate"],
                              crc, csize, usize, len(name), 0)
                + name + data)

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

    out_path.write_bytes(bytes(out))
    print(f"wrote {out_path} ({len(out)} B)")

    zf = zipfile.ZipFile(out_path)
    fails = []
    for zi in zf.infolist():
        try:
            data = zf.read(zi)
            if (zlib.crc32(data) & 0xFFFFFFFF) != zi.CRC:
                fails.append(f"{zi.filename}: crc")
        except Exception as e:
            fails.append(f"{zi.filename}: {e}")
    print(f"zipfile verification: {len(zf.namelist())} entries, "
          f"{'ALL CRC OK' if not fails else fails}")
    try:
        import openpyxl
        wb = openpyxl.load_workbook(out_path, data_only=True)
        print(f"openpyxl: sheets={wb.sheetnames}")
        ws = wb[wb.sheetnames[0]]
        print(f"  sheet1 dims={ws.dimensions} max_row={ws.max_row}")
        for row in ws.iter_rows(min_row=1, max_row=4, max_col=4,
                                values_only=True):
            print("   ", row)
    except ImportError:
        print("openpyxl not installed; skipping workbook read")
    except Exception as e:
        print(f"openpyxl failed: {e}")
    return 0 if not fails else 1


if __name__ == "__main__":
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else None
    dst = Path(sys.argv[2]) if len(sys.argv) > 2 else \
        Path("D:/Codes/fileboundary-artifacts/t0-samples") / \
        (src.stem + ".decrypted" + src.suffix)
    sys.exit(assemble(src, dst))
