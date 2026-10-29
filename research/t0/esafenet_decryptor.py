"""E-SafeNet wrapper decryptor (offline phase).

Implements the reverse-engineered wrapper model measured on the committed
twin specimens (see research/t0/FIELD_PROTOCOL.md and
docs/adversarial-research.md T0):

- File layout: [wrapper header][pre-body zone][body]. Header bytes 4-5
  (LE16) size the pre-body zone, bytes 6-7 the zone's tail inside the first
  512-byte block (zone + tail = 512 for all measured specimens).
- The whole file is XORed with a 512-byte repeating pad K, indexed by
  absolute file offset mod 512. The pad is policy-global (the docx pad
  decrypts the 25 MB PDF specimen's prose). ~53% of the pad is proven here
  by structure constraints + CRC-verified entries; the rest is completed on
  the field machine from minted known-plaintext twins (protocol step 2).
- Under the pad, the body is a rebuilt zip: the first entry's local header
  is stripped (CD keeps lho=0) and its content is stored as a raw-deflate
  blob inside the wrapper's metadata zone; all later entries, the central
  directory and the EOCD are intact.
- Entry payloads are raw-deflate compressed WITH A PRESET DICTIONARY
  (zlib `invalid distance too far back` without it; dictionary = fixed
  constant inside the E-SafeNet client driver — field-extractable, step 3).
  Entries whose streams avoid dictionary references (small files like
  _rels/.rels) decrypt completely without it.

Usage:
    python research/t0/esafenet_decryptor.py <wrapped-file> [--pad pad.json]
        [--out DIR]

Outputs a recovery report (stdout) and, for each entry that fully inflates,
the extracted member files under --out. Never writes into the repository by
default; originals are opened read-only.
"""
import collections
import json
import struct
import sys
import zlib
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DEFAULT_PAD = Path(__file__).parent / "pad.json"
MAGIC = b"\x62\x14\x23\x65"


def load_pad(path: Path):
    data = json.loads(path.read_text())
    pad = {}
    for c, v in enumerate(data["pad"]):
        if v is not None:
            pad[c] = v
    return pad, data.get("proven", {})


def parse_header(ct: bytes):
    if ct[:4] != MAGIC:
        raise ValueError(f"not an E-SafeNet wrapper: {ct[:8].hex()}")
    zone = struct.unpack_from("<H", ct, 4)[0]
    tail = struct.unpack_from("<H", ct, 6)[0]
    return zone, tail


def parse_cd(s: bytes):
    eocd = s.rfind(b"PK\x05\x06")
    if eocd == -1:
        raise ValueError("no EOCD under this pad")
    n_total = struct.unpack_from("<H", s, eocd + 10)[0]
    cd_off = struct.unpack_from("<I", s, eocd + 16)[0]

    def parse_at(off):
        entries = []
        o = off
        for _ in range(n_total):
            if s[o:o + 4] != b"PK\x01\x02":
                raise ValueError("bad CD chain")
            (ver_need, flags, method, mtime, mdate, crc, csize, usize,
             name_len, extra, comment, _d1, _d2, _d3, lho) = struct.unpack(
                "<HHHHHIIIHHHHHII", s[o + 6:o + 46])
            name = s[o + 46:o + 46 + name_len]
            entries.append(dict(ver_need=ver_need, flags=flags, method=method,
                                mtime=mtime, mdate=mdate, crc=crc,
                                csize=csize, usize=usize, name=name, lho=lho,
                                tail=extra + comment))
            o += 46 + name_len + extra + comment
        if o != eocd:
            raise ValueError("CD chain does not reach EOCD")
        return entries

    try:
        return eocd, parse_at(cd_off), "stored cd_offset"
    except (ValueError, struct.error):
        pass
    for cand in reversed([m for m in range(eocd) if s[m:m + 4] == b"PK\x01\x02"]):
        try:
            return eocd, parse_at(cand), f"chain walk from {cand:#x}"
        except (ValueError, struct.error):
            continue
    raise ValueError("no valid CD chain under this pad")


def inflate_entry(ct: bytes, pad: dict, start: int, end: int, want_crc: int,
                  want_size: int, zdict: bytes | None = None):
    """Inflate [start, end) under the pad; returns (status, out).

    status: 'verified' (len+crc match), 'clean' (decodes, no crc match),
    'needs-dictionary', 'derailed:<offset>'.
    """
    data = bytes(ct[o] ^ pad[o % 512] for o in range(start, end))
    for dz in (zlib.decompressobj(-15, zdict=zdict) if zdict else
               zlib.decompressobj(-15),):
        try:
            out = dz.decompress(data)
        except zlib.error as e:
            if "invalid distance too far back" in str(e):
                return "needs-dictionary", b""
            return f"derailed", b""
        if len(out) == want_size and (zlib.crc32(out) & 0xFFFFFFFF) == want_crc:
            return "verified", out
        return "clean", out
    return "derailed", b""


def decrypt(path: Path, pad: dict, out_dir: Path | None):
    ct = path.read_bytes()
    zone, tail = parse_header(ct)
    print(f"wrapper: zone={zone} tail={tail} (sum {zone + tail}, "
          f"file {len(ct)} B)")
    s = bytes(ct[o] ^ pad[o % 512] for o in range(zone + tail - 512,
                                               len(ct)))
    # scan from the first 512-aligned offset at/after the zone for PK\x03\x04
    first_pk = s.find(b"PK\x03\x04", 512)
    if first_pk == -1:
        print("pad insufficient: no local file headers visible")
        return 1
    body_start = zone + tail - 512 + first_pk
    print(f"first intact local header at {body_start:#x} "
          f"(pad columns from {body_start % 512})")
    try:
        eocd, entries, how = parse_cd(s)
    except ValueError as e:
        print(f"central directory not recoverable under this pad: {e}")
        return 1
    cd_abs = None
    print(f"CD located ({how}), {len(entries)} entries")

    results = []
    for e in entries:
        if e["lho"] < 512:
            results.append((e, "stripped-first-entry", b""))
            continue
        li = e["lho"]
        nl, el = struct.unpack_from("<HH", s, li + 26)
        a = li + 30 + nl + el
        status, out = inflate_entry(ct, pad, a, a + e["csize"],
                                    e["crc"], e["usize"])
        results.append((e, status, out))

    ok = 0
    for e, status, out in results:
        name = e["name"].decode("utf-8", "replace")
        mark = {"verified": "VERIFIED", "clean": "clean-no-crc"}.get(
            status, status)
        print(f"  {name}: {mark} ({len(out)} B)")
        if status == "verified":
            ok += 1
            if out_dir and not name.endswith("/"):
                dest = out_dir / name
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(out)
    print(f"{ok}/{len(entries)} entries fully verified")
    if any(st == "needs-dictionary" for _, st, _ in results):
        print("preset dictionary required for remaining entries — "
              "run FIELD_PROTOCOL step 3 on the operator machine")
    return 0


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = {a.split("=")[0] for a in sys.argv[1:] if a.startswith("--")}
    if not args:
        print(__doc__)
        return 2
    path = Path(args[0])
    pad_path = DEFAULT_PAD
    out_dir = None
    for a in sys.argv[1:]:
        if a.startswith("--pad="):
            pad_path = Path("=".join(a.split("=")[1:]))
        if a.startswith("--out="):
            out_dir = Path("=".join(a.split("=")[1:]))
    pad, proven = load_pad(pad_path)
    return decrypt(path, pad, out_dir)


if __name__ == "__main__":
    sys.exit(main())
