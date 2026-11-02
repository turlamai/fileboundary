"""T0/T4 finisher: content-gated pad repair and docx reassembly.

Key measured finding on top of recover_docx.py's model: the central
directory's crc/csize/usize fields are THEMSELVES pad-corrupted for several
entries (chain repair validated only magic/name/offsets), so CD-side gates
are unreliable. The verification gate is therefore CONTENT-side: an entry is
recovered when its deflate stream fully decodes into well-formed XML
(xml.etree parse). The decoded content then supplies the true crc/sizes,
which are patched back into the rebuilt zip.

Repair loop: per region (entry data span, or the blob for the stripped
first entry), map the failure point (inflate error or ET parse error,
via a per-input-byte output trace) to candidate pad columns, flip them
through all 256 values, accept flips that turn the region into well-formed
XML, lock the columns globally, and restart all regions — a confirmed fix
helps every other region sharing those columns.
"""
import collections
import io
import struct
import sys
import xml.etree.ElementTree as ET
import zipfile
import zlib
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CT = REPO / "tests/fixtures/real-samples/encrypted-sample.docx"
DEFAULT_OUT = REPO.parent / "fileboundary-artifacts" / "t0-samples"
BODY_START = 0x1BC
BLOB_END = 0x39E
FINGERPRINT = b"123 abc"


def seed_pad(ct: bytes, start: int):
    cols = collections.defaultdict(collections.Counter)
    for off in range(start, len(ct)):
        cols[off % 512][ct[off]] += 1
    pad, votes = {}, {}
    for c, counter in cols.items():
        val, cnt = counter.most_common(1)[0]
        pad[c] = val
        votes[c] = cnt
    return pad, votes


def apply_pad(ct: bytes, pad: dict) -> bytes:
    return bytes(ct[o] ^ pad[o % 512] for o in range(len(ct)))


def parse_cd(s: bytes, cd_off: int, count: int):
    entries = []
    o = cd_off
    for _ in range(count):
        if s[o:o + 4] != b"PK\x01\x02":
            raise ValueError(f"CD entry bad magic at {o}")
        (ver_made, ver_need, flags, method, mtime, mdate, crc, csize, usize,
         name_len, extra_len, comment_len, disk_start, int_attr, ext_attr,
         lho) = struct.unpack("<HHHHHHIIIHHHHHII", s[o + 4:o + 46])
        entries.append(dict(ver_need=ver_need, flags=flags, method=method,
                            mtime=mtime, mdate=mdate, crc=crc, csize=csize,
                            usize=usize, name=s[o + 46:o + 46 + name_len],
                            lho=lho, tail_len=extra_len + comment_len))
        o += 46 + name_len + extra_len + comment_len
    return entries, o


def find_cd(s: bytes):
    eocd = s.rfind(b"PK\x05\x06")
    if eocd == -1:
        raise ValueError("no EOCD")
    n_total = struct.unpack("<H", s[eocd + 10:eocd + 12])[0]
    cd_off = struct.unpack("<I", s[eocd + 16:eocd + 20])[0]
    if s[cd_off:cd_off + 4] == b"PK\x01\x02":
        try:
            entries, cd_end = parse_cd(s, cd_off, n_total)
            if cd_end == eocd:
                return eocd, cd_off, n_total
        except (ValueError, struct.error):
            pass
    for cand in reversed([m for m in range(eocd) if s[m:m + 4] == b"PK\x01\x02"]):
        try:
            entries, cd_end = parse_cd(s, cand, n_total)
        except (ValueError, struct.error):
            continue
        if cd_end == eocd:
            return eocd, cand, n_total
    raise ValueError(f"no CD chain reaches EOCD at {eocd}")


def repair_structure(ct: bytes, pad: dict, s: bytes, max_rounds: int = 8):
    total = 0
    for round_no in range(max_rounds):
        fixes = 0
        try:
            eocd, cd_off, n_total = find_cd(s)
            entries, _ = parse_cd(s, cd_off, n_total)
        except (ValueError, struct.error) as e:
            return total, f"structure unresolved: {e}"

        def fix(off, want):
            nonlocal fixes
            col = off % 512
            if pad[col] != want:
                pad[col] = want
                fixes += 1

        for e in entries:
            li = e["lho"]
            if li < 512 or li + 30 + len(e["name"]) > len(s):
                continue
            for k in range(4):
                if s[li + k] != b"PK\x03\x04"[k]:
                    fix(li + k, b"PK\x03\x04"[k])
            name_got = s[li + 30:li + 30 + len(e["name"])]
            for k in range(len(e["name"])):
                if name_got[k] != e["name"][k]:
                    fix(li + 30 + k, e["name"][k])
        cd_size = eocd - cd_off
        for k in range(4):
            fix(eocd + 12 + k, (cd_size >> (8 * k)) & 0xFF)
            fix(eocd + 16 + k, (cd_off >> (8 * k)) & 0xFF)
        if fixes == 0:
            return total, f"converged after {round_no} round(s)"
        total += fixes
        s = apply_pad(ct, pad)
    return total, "max rounds reached"


def entry_data_region(s: bytes, e: dict):
    li = e["lho"]
    nl, el = struct.unpack("<HH", s[li + 26:li + 30])
    return li + 30 + nl + el, li + 30 + nl + el + e["csize"]


def decode_span(ct: bytes, pad: dict, a: int, b: int):
    """Whole-span inflate; returns (out, eof, err_at) with err_at=None when
    the stream decoded to completion."""
    reg = bytes(ct[o] ^ pad[o % 512] for o in range(a, b))
    d = zlib.decompressobj(-15)
    try:
        return d.decompress(reg), d.eof, None
    except zlib.error:
        pass
    d2 = zlib.decompressobj(-15)
    out = bytearray()
    last = a
    for i in range(a, b):
        try:
            out += d2.decompress(ct[i:i + 1] and bytes(
                [ct[i] ^ pad[i % 512]]))
            last = i + 1
        except zlib.error:
            break
    return bytes(out), False, last


def trace_map(ct: bytes, pad: dict, a: int, b: int):
    """Input index -> cumulative output length while feeding byte-wise."""
    d = zlib.decompressobj(-15)
    acc = 0
    marks = []
    for i in range(a, b):
        marks.append((i, acc))
        try:
            acc += len(d.decompress(bytes([ct[i] ^ pad[i % 512]])))
        except zlib.error:
            break
    return marks


def in_for(marks, j):
    lo = marks[0][0] if marks else 0
    for i, o0 in marks:
        if o0 <= j:
            lo = i
        else:
            break
    return lo


def region_gate(out: bytes, eof: bool) -> bool:
    """Content-side gate: complete decode into well-formed XML."""
    if not eof or not out:
        return False
    try:
        ET.fromstring(out)
        return True
    except ET.ParseError:
        return False


def repair_region(ct, pad, votes, locked, a, b, label, budget=20000):
    """Iteratively flip columns near the failure point until the region
    parses as well-formed XML. Progress gradient: commit flips that advance
    the decode frontier (or move the XML error later), not only full gates.
    Returns True on success."""
    best_front = -1
    tried = set()
    for _ in range(80):
        out, eof, err_at = decode_span(ct, pad, a, b)
        if region_gate(out, eof):
            return True
        marks = trace_map(ct, pad, a, b)
        if eof:
            try:
                ET.fromstring(out)
            except ET.ParseError as pe:
                pos = pe.position[1] if pe.position else 0
                jout = max(0, pos - 2)
            jout = min(jout, max(0, len(out) - 1))
            i_fail = in_for(marks, jout)
        else:
            i_fail = err_at if err_at is not None else b - 1
        front = b if eof else i_fail
        cand_cols = []
        for off in range(max(a, i_fail - 10), min(b, i_fail + 4)):
            c = off % 512
            if c not in locked:
                cand_cols.append(c)
        cand_cols = sorted(set(cand_cols), key=lambda c: votes.get(c, 999))
        step = None  # (score, col, v); score = decode depth + XML depth
        for col in cand_cols:
            for v in range(256):
                if v == pad[col] or (col, v) in tried:
                    continue
                trial = dict(pad)
                trial[col] = v
                t_out, t_eof, t_err = decode_span(ct, trial, a, b)
                if region_gate(t_out, t_eof):
                    pad[col] = v
                    locked.add(col)
                    print(f"    [{label}] col {col} -> {v:#04x} XML OK")
                    return True
                if t_eof:
                    # secondary gradient: how deep does the XML parse get?
                    try:
                        ET.fromstring(t_out)
                        et_pos = len(t_out)
                    except ET.ParseError as pe:
                        et_pos = pe.position[1] if pe.position else 0
                    score = b + et_pos
                    if step is None or score > step[0]:
                        step = (score, col, v)
                else:
                    t_front = t_err if t_err is not None else b - 1
                    if t_front > front and (step is None or t_front > step[0]):
                        step = (t_front, col, v)
                budget -= 1
                if budget <= 0:
                    return False
            if step and step[0] >= b + len(t_out):
                break
        if step is None:
            # fallback: sweep low-trust columns across the whole span
            span = sorted({o % 512 for o in range(a, b)} - locked,
                          key=lambda c: votes.get(c, 999))
            for col in span[:60]:
                for v in range(256):
                    if v == pad[col]:
                        continue
                    trial = dict(pad)
                    trial[col] = v
                    t_out, t_eof, _ = decode_span(ct, trial, a, b)
                    if region_gate(t_out, t_eof):
                        pad[col] = v
                        locked.add(col)
                        print(f"    [{label}] sweep col {col} -> {v:#04x} "
                              f"XML OK")
                        return True
                    budget -= 1
                    if budget <= 0:
                        return False
            return False
        _, col, v = step
        tried.add((col, v))
        pad[col] = v
        print(f"    [{label}] progress: col {col} -> {v:#04x} "
              f"(score {step[0]})")
    return False


def main() -> int:
    out_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_OUT
    ct = CT.read_bytes()

    pad, votes = seed_pad(ct, BODY_START)
    s = apply_pad(ct, pad)
    fixes, msg = repair_structure(ct, pad, s)
    s = apply_pad(ct, pad)
    print(f"structure repair: {msg} (columns changed: {fixes})")

    # cross-file known plaintext: the PDF body's own wrapper zone proved the
    # pad is global, but its phase differs per file; only structure-verified
    # columns from THIS file are seeded here.
    pad[203] = 199
    pad[204] = 246
    locked = {203, 204}

    eocd, cd_off, n_total = find_cd(s)
    entries, _ = parse_cd(s, cd_off, n_total)
    first = entries[0]
    blob_start = BLOB_END - first["csize"]

    regions = [(blob_start, BLOB_END, first, "<blob>")]
    for e in entries[1:]:
        a, b = entry_data_region(s, e)
        regions.append((a, b, e, e["name"].decode("utf-8", "replace")))

    for rnd in range(6):
        print(f"== round {rnd + 1} ==")
        pending = []
        for a, b, e, label in regions:
            if repair_region(ct, pad, votes, locked, a, b, label):
                print(f"  {label}: XML OK")
            else:
                pending.append((a, b, e, label))
                print(f"  {label}: unresolved")
        if not pending:
            break
        if len(pending) == len(regions):
            print("no progress; stopping")
            break
        regions = pending

    # final status + content metadata
    truths = {}
    all_ok = True
    for a, b, e, label in regions:
        out, eof, _ = decode_span(ct, pad, a, b)
        ok = region_gate(out, eof)
        all_ok &= ok
        truths[e["name"]] = (out, zlib.crc32(out) & 0xFFFFFFFF, len(out))
        print(f"final {label}: {'XML OK' if ok else 'FAILED'}")
    s = apply_pad(ct, pad)
    if not all_ok:
        print("refusing to claim recovery")
        return 1

    # reassemble with content-derived crc/sizes patched into the CD
    blob_out = truths[first["name"]][0]
    shift = 30 + len(first["name"]) + len(blob_out)
    rest = bytearray(s[BLOB_END:])
    o = cd_off
    for e in entries:
        rel = o - BLOB_END
        true_crc, true_len = truths[e["name"]][1], truths[e["name"]][2]
        true_csz = e["csize"] if e["lho"] >= 512 else len(blob_out)
        if e["lho"] >= 512:
            a, b = entry_data_region(s, e)
            true_csz = b - a
        struct.pack_into("<I", rest, rel + 16, true_crc)
        struct.pack_into("<I", rest, rel + 20, true_csz)
        struct.pack_into("<I", rest, rel + 24, true_len)
        if e["lho"] >= 512:
            struct.pack_into("<I", rest, rel + 42, e["lho"] + shift)
        else:
            struct.pack_into("<I", rest, rel + 42, 0)
        o += 46 + len(e["name"]) + e["tail_len"]
    struct.pack_into("<I", rest, eocd - BLOB_END + 16, cd_off + shift)

    lfh = (b"PK\x03\x04"
           + struct.pack("<HHHHHIIIHH", first["ver_need"], first["flags"],
                         first["method"], first["mtime"], first["mdate"],
                         truths[first["name"]][1], len(blob_out),
                         truths[first["name"]][2], len(first["name"]), 0)
           + first["name"])
    out = lfh + blob_out + bytes(rest)
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / "recovered-esafenet-sample.docx"
    out_path.write_bytes(out)
    print(f"wrote {out_path} ({len(out)} bytes)")

    zf = zipfile.ZipFile(io.BytesIO(out))
    bad = zf.testzip()
    doc = zf.read("word/document.xml")
    hit = FINGERPRINT in doc
    print(f"zipfile testzip: {'CLEAN' if bad is None else f'CORRUPT: {bad}'}")
    print(f"fingerprint {FINGERPRINT!r} in word/document.xml: {hit}")
    if hit:
        i = doc.find(FINGERPRINT)
        ctx = doc[max(0, i - 60):i + 60]
        print(f"context: ...{ctx.decode('utf-8', errors='replace')}...")
    return 0 if (bad is None and hit) else 1


if __name__ == "__main__":
    sys.exit(main())
