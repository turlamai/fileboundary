#!/usr/bin/env python
"""Release engineering for ADR-0008 update channels.

Builds, from a packaged application directory:

- the full package zip (embeds filetable.json with per-file SHA-256 and
  manifest.json — the release manifest describing the zip itself);
- optionally a delta package against a previous version directory:
  only changed files (payload/) + delta.json (add/replace/delete with
  base-hash guards) + the target filetable;
- manifest.json (release manifest) referencing both with bytes/SHA-256.

Usage:
  python tools/make_update_manifest.py --dir <built-app> --version 0.2.0 \
      --commit <sha> --out dist/ \
      [--channel stable] [--base-dir <prev-built>] [--base-version 0.1.0] \
      [--package-url-base https://github.com/.../download/v0.2.0/]
"""
import argparse
import hashlib
import json
import os
import zipfile
from pathlib import Path


def sha256_file(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def file_table(root: Path, version: str, skip=frozenset()):
    files = []
    for p in sorted(root.rglob("*")):
        if p.is_dir():
            continue
        rel = p.relative_to(root).as_posix()
        if rel in skip:
            continue
        files.append({"path": rel, "sha256": sha256_file(p)})
    return {"version": version, "files": files}


def make_zip(root: Path, dest: Path, embed: dict):
    with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as z:
        for p in sorted(root.rglob("*")):
            if p.is_dir():
                continue
            z.write(p, p.relative_to(root).as_posix())
        # embedded tables live inside the zip but are excluded from the
        # file table (the engine ignores them during verification)
        for name, obj in embed.items():
            z.writestr(name, json.dumps(obj, indent=1))


def tree_diff(old: Path, new: Path):
    old_files = {p.relative_to(old).as_posix(): p for p in old.rglob("*")
                 if p.is_file()}
    new_files = {p.relative_to(new).as_posix(): p for p in new.rglob("*")
                 if p.is_file()}
    ops = []
    payload = {}
    for rel, p in new_files.items():
        if rel not in old_files:
            ops.append({"action": "add", "path": rel,
                        "sha256": sha256_file(p)})
            payload[rel] = p
        elif sha256_file(old_files[rel]) != sha256_file(p):
            ops.append({"action": "replace", "path": rel,
                        "baseSha256": sha256_file(old_files[rel]),
                        "sha256": sha256_file(p)})
            payload[rel] = p
    for rel in old_files:
        if rel not in new_files:
            ops.append({"action": "delete", "path": rel,
                        "baseSha256": sha256_file(old_files[rel])})
    return ops, payload


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True, help="built application directory")
    ap.add_argument("--version", required=True, help="X.Y.Z")
    ap.add_argument("--commit", required=True, help="short commit sha")
    ap.add_argument("--out", required=True, help="output directory")
    ap.add_argument("--channel", default="stable")
    ap.add_argument("--base-dir", help="previous version dir for delta")
    ap.add_argument("--base-version")
    ap.add_argument("--package-url-base", default="")
    args = ap.parse_args()

    src = Path(args.dir)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    # family naming (ADR-0010); "-update" distinguishes the update-channel
    # full package from the portable zip of the same version
    stem = f"fileboundary-{args.version}-windows-x64-update"
    full_zip = out / f"{stem}.zip"
    table = file_table(src, args.version, skip={"filetable.json"})
    make_zip(src, full_zip, embed={"filetable.json": table})
    print(f"full package: {full_zip} ({full_zip.stat().st_size} B)")

    package = {
        "kind": "full", "name": full_zip.name,
        "bytes": full_zip.stat().st_size, "sha256": sha256_file(full_zip),
        "url": args.package_url_base + full_zip.name,
    }
    deltas = []
    if args.base_dir and args.base_version:
        old = Path(args.base_dir)
        ops, payload = tree_diff(old, src)
        if ops:
            delta_stem = f"fileboundary-delta-{args.base_version}-to-{args.version}"
            delta_zip = out / f"{delta_stem}.zip"
            with zipfile.ZipFile(delta_zip, "w", zipfile.ZIP_DEFLATED) as z:
                for rel, p in payload.items():
                    z.write(p, "payload/" + rel)
                z.writestr("delta.json", json.dumps({
                    "schemaVersion": 1,
                    "baseVersion": args.base_version,
                    "targetVersion": args.version,
                    "operations": ops}, indent=1))
            deltas.append({
                "kind": "delta", "baseVersion": args.base_version,
                "name": delta_zip.name, "bytes": delta_zip.stat().st_size,
                "sha256": sha256_file(delta_zip),
                "url": args.package_url_base + delta_zip.name,
            })
            print(f"delta package: {delta_zip} ({len(ops)} operations)")
        else:
            print("no differences; delta skipped")

    manifest = {
        "schemaVersion": 1,
        "channel": args.channel,
        "version": args.version,
        "commit": args.commit,
        "package": package,
        "deltas": deltas,
    }
    (out / "manifest.json").write_text(
        json.dumps(manifest, indent=1), newline="\n")
    print(f"manifest: {out / 'manifest.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
