"""Build research/t0/pad.json from the committed twin specimen.

Reuses the battle-tested repair pipeline from recover_docx_final.py
(seed vote -> structure repair -> CRC anchors) and records per-column
provenance tiers:

- 'crc'    : covered by the _rels/.rels data span, which inflates to a
             CRC32-verified stream under these values (CRC32 is decisive);
- 'struct' : covered by an entry's local-header magic + name bytes, which
             must match the central directory record exactly;
- 'chain'  : covered by the central directory + EOCD, whose entry chain
             must close exactly on the EOCD.

Columns without evidence are emitted as null and are completed on the field
machine from minted known-plaintext twins (FIELD_PROTOCOL step 2).
"""
import collections
import json
import struct
import zlib
from pathlib import Path

import recover_docx_final as rec

REPO = Path(__file__).resolve().parents[2]
OUT = Path(__file__).parent / "pad.json"
CRC_ANCHOR = {203: 199, 204: 246}  # from the CRC-verified _rels repair


def main() -> None:
    ct = rec.CT.read_bytes()
    pad, votes = rec.seed_pad(ct, rec.BODY_START)
    s = rec.apply_pad(ct, pad)
    fixes, msg = rec.repair_structure(ct, pad, s)
    print(f"structure repair: {msg} ({fixes} columns)")
    pad.update(CRC_ANCHOR)
    s = rec.apply_pad(ct, pad)

    eocd, cd_off, n_total = rec.find_cd(s)
    entries, cd_end = rec.parse_cd(s, cd_off, n_total)
    print(f"CD@{cd_off:#x} EOCD@{eocd:#x}, {n_total} entries")

    proven = collections.defaultdict(set)
    for e in entries:
        lho = e["lho"]
        if lho < 512:
            continue
        magic_ok = all(s[lho + k] == b"PK\x03\x04"[k] for k in range(4))
        name_ok = all(s[lho + 30 + k] == e["name"][k]
                      for k in range(len(e["name"])))
        if magic_ok and name_ok:
            cols = {(lho + k) % 512 for k in range(4)}
            cols |= {(lho + 30 + k) % 512 for k in range(len(e["name"]))}
            proven["struct"] |= cols
    # chain tier: only bytes that participate in walk closure — per-entry
    # magic, the six length fields, and the name bytes; plus EOCD fields.
    o = cd_off
    for _ in range(n_total):
        name_len, extra, comment = struct.unpack_from("<HHH", s, o + 28)
        if s[o:o + 4] == b"PK\x01\x02":
            proven["chain"] |= {(o + k) % 512 for k in range(4)}
            proven["chain"] |= {(o + 28 + k) % 512 for k in range(6)}
            proven["chain"] |= {(o + 46 + k) % 512 for k in range(name_len)}
        o += 46 + name_len + extra + comment
    for k in range(2):
        proven["chain"] |= {(eocd + 8 + k) % 512}   # n_total
    for k in range(4):
        proven["chain"] |= {(eocd + 12 + k) % 512}  # cd_size
        proven["chain"] |= {(eocd + 16 + k) % 512}  # cd_offset
    for e in entries:
        if e["name"] != b"_rels/.rels" or e["lho"] < 512:
            continue
        lho = e["lho"]
        nl, el = struct.unpack_from("<HH", s, lho + 26)
        a, b = lho + 30 + nl + el, lho + 30 + nl + el + e["csize"]
        try:
            out = zlib.decompressobj(-15).decompress(
                bytes(ct[x] ^ pad[x % 512] for x in range(a, b)))
        except zlib.error:
            print("_rels did not inflate; crc tier empty")
            break
        if len(out) == e["usize"] and (zlib.crc32(out) & 0xFFFFFFFF) == e["crc"]:
            proven["crc"] |= {x % 512 for x in range(a, b)}
            print(f"_rels CRC-verified ({len(out)} B): "
                  f"{len(proven['crc'])} columns at crc tier")
        else:
            print("_rels inflated but CRC mismatch; crc tier empty")
        break

    all_proven = proven["crc"] | proven["struct"] | proven["chain"]
    doc = {
        "pad": [pad.get(c) for c in range(512)],
        "proven": {
            "count": len(all_proven),
            "crc_tier": sorted(proven["crc"]),
            "struct_tier": sorted(proven["struct"]),
            "chain_tier": sorted(proven["chain"]),
            "basis": "crc = _rels/.rels data span CRC32-verified; "
                     "struct = local-header magic+name must match CD; "
                     "chain = CD/EOCD entry chain must close exactly",
        },
        "specimen": {
            "file": "tests/fixtures/real-samples/encrypted-sample.docx",
            "sha256": "ea2eb7d89667e115f7edf217d853955dda49c0b4a35bfe8ebb"
                      "ba2699d9979ccd",
        },
    }
    OUT.write_text(json.dumps(doc, indent=1))
    print(f"pad.json: {len(all_proven)}/512 columns proven "
          f"(crc {len(proven['crc'])}, struct {len(proven['struct'])}, "
          f"chain {len(proven['chain'])})")


if __name__ == "__main__":
    main()
