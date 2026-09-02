#!/usr/bin/env python3
from __future__ import annotations

import argparse
import collections
import csv
import re
from pathlib import Path

ARCHIVE_RE = re.compile(r'lib(?P<kind>crypto|ssl)\.a\((?P<member>[^)]+)\)')
SECTION_RE = re.compile(
    r'\b0x[0-9A-Fa-f]+\s+(?P<size>0x[0-9A-Fa-f]+)\s+'
    r'(?P<object>.*?lib(?:crypto|ssl)\.a\([^)]+\))\s*$'
)

def family(kind: str, member: str) -> str:
    m = member.lower()
    if kind == "ssl":
        return "libssl / TLS"
    if any(x in m for x in ("mlkem", "ml_kem", "mldsa", "ml_dsa", "slh", "sphincs")):
        return "PQC"
    if "legacy" in m:
        return "legacy provider"
    if any(x in m for x in ("x509", "asn1", "pem", "pkcs", "ocsp", "cms", "ts_", "ess_")):
        return "ASN.1 / X.509 / PEM / PKI"
    if any(x in m for x in ("provider", "evp", "core", "fetch", "namemap", "property")):
        return "EVP / provider / core"
    if any(x in m for x in ("bignum", "bn_", "ec_", "rsa", "dsa", "dh_", "ffc", "curve25519")):
        return "BIGNUM / EC / RSA / DSA / DH"
    if any(x in m for x in ("des", "rc2", "rc4", "md4", "mdc2", "idea", "bf_", "blowfish", "cast", "seed", "whirlpool")):
        return "historical algorithms"
    if any(x in m for x in ("aes", "chacha", "poly1305", "sha", "sm3", "sm4", "camellia")):
        return "modern symmetric / digest"
    if "err" in m:
        return "error / diagnostics"
    return "other libcrypto"

def parse_reasons(lines: list[str]) -> dict[tuple[str, str], str]:
    """
    GNU ld places archive-extraction reasons before the memory-map input-section
    records. Do not depend on the English heading: stop at the first actual
    OpenSSL input-section record instead.
    """
    first_section = next((i for i, line in enumerate(lines) if SECTION_RE.search(line)), len(lines))
    reasons: dict[tuple[str, str], str] = {}
    pending: tuple[str, str] | None = None

    for raw in lines[:first_section]:
        line = raw.rstrip("\n")
        match = ARCHIVE_RE.search(line)
        if match:
            key = (match.group("kind"), match.group("member"))
            trailing = line[match.end():].strip()
            if trailing:
                reasons.setdefault(key, trailing)
                pending = None
            else:
                pending = key
            continue

        if pending and line.strip():
            # Wrapped GNU ld reason lines are indented and contain the referring
            # file/symbol. Ignore obvious headings/separators.
            stripped = line.strip()
            if not set(stripped) <= {"-", "="} and not stripped.endswith(":"):
                reasons.setdefault(pending, stripped)
            pending = None

    return reasons

def parse_sizes(lines: list[str]) -> dict[tuple[str, str], int]:
    sizes: dict[tuple[str, str], int] = collections.defaultdict(int)
    for line in lines:
        match = SECTION_RE.search(line)
        if not match:
            continue
        archive = ARCHIVE_RE.search(match.group("object"))
        if not archive:
            continue
        sizes[(archive.group("kind"), archive.group("member"))] += int(match.group("size"), 16)
    return dict(sizes)

def main() -> int:
    ap = argparse.ArgumentParser(
        description="Attribute Babet GNU ld map bytes to OpenSSL static archive members."
    )
    ap.add_argument("map", type=Path)
    ap.add_argument("--out-dir", type=Path, default=None)
    args = ap.parse_args()

    if not args.map.is_file():
        ap.error(f"map file not found: {args.map}")

    out = args.out_dir or args.map.parent
    out.mkdir(parents=True, exist_ok=True)
    lines = args.map.read_text(errors="replace").splitlines(keepends=True)

    reasons = parse_reasons(lines)
    sizes = parse_sizes(lines)
    all_keys = set(reasons) | set(sizes)

    rows = []
    for kind, member in all_keys:
        rows.append({
            "archive": f"lib{kind}.a",
            "member": member,
            "family": family(kind, member),
            "mapped_bytes": sizes.get((kind, member), 0),
            "included_because": reasons.get((kind, member), ""),
        })
    rows.sort(key=lambda r: (-int(r["mapped_bytes"]), r["archive"], r["member"]))

    objects_tsv = out / "openssl-objects.tsv"
    with objects_tsv.open("w", newline="") as fh:
        writer = csv.DictWriter(
            fh,
            fieldnames=["archive", "member", "family", "mapped_bytes", "included_because"],
            delimiter="\t",
        )
        writer.writeheader()
        writer.writerows(rows)

    fam = collections.defaultdict(lambda: {"bytes": 0, "members": 0})
    archive_totals = collections.defaultdict(int)
    zero_size = 0
    reason_count = 0
    for row in rows:
        size = int(row["mapped_bytes"])
        fam[row["family"]]["bytes"] += size
        fam[row["family"]]["members"] += 1
        archive_totals[row["archive"]] += size
        zero_size += size == 0
        reason_count += bool(row["included_because"])

    fam_rows = sorted(
        ((name, data["bytes"], data["members"]) for name, data in fam.items()),
        key=lambda x: (-x[1], x[0]),
    )

    families_tsv = out / "openssl-families.tsv"
    with families_tsv.open("w", newline="") as fh:
        writer = csv.writer(fh, delimiter="\t")
        writer.writerow(["family", "mapped_bytes", "members"])
        writer.writerows(fam_rows)

    review_names = {"PQC", "legacy provider", "historical algorithms"}
    review_upper_bound = sum(nbytes for name, nbytes, _ in fam_rows if name in review_names)

    report = out / "openssl-map-report.txt"
    with report.open("w") as fh:
        fh.write("Babet Candidate 9 — OpenSSL static-link composition\n")
        fh.write("===================================================\n\n")
        fh.write(f"Map: {args.map}\n")
        fh.write(f"Archive members seen: {len(rows)}\n")
        fh.write(f"Members with GNU ld inclusion reason captured: {reason_count}\n")
        fh.write(f"Members with reason but no parsed mapped bytes: {zero_size}\n\n")

        fh.write("Mapped input-section bytes by archive\n")
        fh.write("-------------------------------------\n")
        for archive in ("libcrypto.a", "libssl.a"):
            fh.write(f"{archive:12s} {archive_totals.get(archive, 0):12d}\n")
        fh.write(f"{'TOTAL':12s} {sum(archive_totals.values()):12d}\n\n")

        fh.write("Families (heuristic classification; not an automatic removal decision)\n")
        fh.write("---------------------------------------------------------------------\n")
        for name, nbytes, members in fam_rows:
            fh.write(f"{name:38s} {nbytes:12d}  {members:5d} members\n")

        fh.write("\nReview-only upper bound\n")
        fh.write("-----------------------\n")
        fh.write(
            f"PQC + legacy-provider + historical-algorithm families: "
            f"{review_upper_bound} mapped bytes\n"
        )
        fh.write(
            "This is deliberately an upper bound for review, NOT a predicted "
            "Configure saving and NOT a safe-removal claim.\n"
        )

        fh.write("\nLargest archive members\n")
        fh.write("-----------------------\n")
        for row in rows[:100]:
            fh.write(
                f"{int(row['mapped_bytes']):10d}  {row['archive']:11s}  "
                f"{row['member'][:48]:48s}  {row['family']}\n"
            )

        fh.write("\nInterpretation guardrails\n")
        fh.write("-------------------------\n")
        fh.write("- mapped_bytes comes from GNU ld input-section records, not .a file sizes.\n")
        fh.write(
            "- included_because is captured from the pre-map archive-extraction "
            "records without relying on an English GNU ld heading.\n"
        )
        fh.write(
            "- family classification is filename-based and heuristic; it identifies "
            "review targets only.\n"
        )
        fh.write(
            "- no Configure option is accepted from this report alone; deterministic "
            "TLS capability tests must stay green and diagnostics must not regress.\n"
        )
        fh.write(
            "- Candidate 9 does not enable --gc-sections or otherwise change link "
            "semantics from the baseline.\n"
        )

    print(report)
    print(objects_tsv)
    print(families_tsv)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
