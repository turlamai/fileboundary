"""Complete the policy pad via object-scan ↔ xref-record cross-reference.

Forward direction: scan the decoded file for every '<num> 0 obj' — each
match yields (object_number, absolute_offset). Reverse direction: the
classic xref table header 'xref\\r\\n0 <count>\\r\\n' pins the table start;
record k (object k) sits at table_start + 20*k and must contain
'%010d 00000 n\\r\\n' with the scanned offset. Crossing the two gives ~11
known bytes per object over ~1400 objects — tens of votes per column.
"""
import collections
import json
import re
import zlib
from pathlib import Path

PAD = Path("D:/Codes/fileboundary/research/t0/pad.json")
PAD_TIER = Path("D:/Codes/fileboundary/research/t0/pad_pdf_tier.json")
PDF = Path("D:/Codes/fileboundary-artifacts/t0-samples/esafenet-locked-sample.pdf")
OUT = Path("D:/Codes/fileboundary/research/t0/pad_full.json")
STREAM_ANCHOR = re.compile(rb"stream\r\n")
OBJ = re.compile(rb"\r\n(\d{1,6}) 0 obj")
TABLE_HDR = re.compile(rb"xref\r\n0 (\d{1,6})\r\n")


def load_pad():
    d = json.loads(PAD.read_text())
    prov = set(d["proven"]["crc_tier"]) | set(d["proven"]["struct_tier"]) \
        | set(d["proven"]["chain_tier"])
    pad = {i: v for i, v in enumerate(d["pad"]) if v is not None}
    if PAD_TIER.exists():
        tier = json.loads(PAD_TIER.read_text())
        for c, v in enumerate(tier["pad"]):
            if v is not None and c not in pad:
                pad[c] = v
    return pad, prov


def main() -> int:
    pad, prov = load_pad()
    ct = PDF.read_bytes()
    n = len(ct)
    S = bytes(ct[o] ^ pad[o % 512] for o in range(n))

    # collect (object_number, offset) from object headers
    objs = {}
    for m in OBJ.finditer(S):
        num = int(m.group(1))
        objs.setdefault(num, m.start() + 1)  # +1: skip the leading \r\n? no —
    # OBJ matched '\r\n<num> 0 obj': the object body starts at the digit.
    objs = {}
    for m in OBJ.finditer(S):
        num = int(m.group(1))
        objs.setdefault(num, m.start() + 2)
    print(f"object headers located: {len(objs)}")

    # locate xref table headers (classic tables only)
    tables = list(TABLE_HDR.finditer(S))
    print(f"xref table headers: {len(tables)}")
    votes = collections.defaultdict(collections.Counter)
    votes_cast = 0
    for th in tables:
        count = int(th.group(1))
        tstart = th.end()
        for k in range(count):
            obj_num = k
            if obj_num not in objs:
                continue
            rp = tstart + 20 * k
            if rp + 20 > n:
                break
            want = b"%010d 00000 n\r\n" % objs[obj_num]
            for j, w in enumerate(want):
                o = rp + j
                votes[o % 512][ct[o] ^ w] += 1
                votes_cast += 1
    print(f"votes cast: {votes_cast}")

    resolved = {}
    conflicts = 0
    for col, counter in sorted(votes.items()):
        (val, cnt), = counter.most_common(1)
        total = sum(counter.values())
        if cnt >= max(5, total * 0.9):
            resolved[col] = val
        elif cnt < total * 0.5:
            conflicts += 1
    print(f"columns resolved (>=90% agreement): {len(resolved)}; "
          f"conflicted: {conflicts}")

    full = dict(pad)
    full.update(resolved)
    missing = sorted(set(range(512)) - set(full))
    print(f"missing after objects+xref: {len(missing)} {missing[:24]}")

    # validate: streams + tail
    anchors = [m.end() for m in STREAM_ANCHOR.finditer(S)]
    infl = 0
    for a in anchors:
        data = bytes(ct[o] ^ full[o % 512] for o in range(a, min(a + 8192, n)))
        try:
            if len(zlib.decompressobj(15).decompress(data, 64)) > 16:
                infl += 1
        except zlib.error:
            pass
    print(f"streams inflating: {infl}/{len(anchors)}")
    S2_tail = bytes(ct[o] ^ full[o % 512] for o in range(n - 4096, n))
    print("tail:", S2_tail[-140:])

    OUT.write_text(json.dumps(
        {"pad": [full.get(c) for c in range(512)],
         "tiers": {"base": sorted(prov), "obj_xref": sorted(resolved)},
         "missing": missing,
         "streams_inflating": [infl, len(anchors)]},
        indent=1))
    print(f"wrote {OUT}")
    return 0


if __name__ == "__main__":
    main()
