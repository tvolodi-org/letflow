#!/usr/bin/env python3
"""qoimeks_masters_compare.py -- P8.10 REQ-881: compare master data (places, units, items) between the Qoimeks CSV extract and the Letflow records export.

Read-only and offline: opens files, prints a report, writes nothing, opens no network connection and reads no secret.
Run it on QA copies only (docs/runbooks/qoimeks-rehearsal.md, step 8).

  python3 -I scripts/pilot/qoimeks_masters_compare.py \\
      --locations locations.csv --items items.csv \\
      --export-dir DIR [--mapping map.json]

--locations  Qoimeks extract file (loc_code, loc_name); same read rules as qoimeks_convert.py.
--items      Qoimeks extract file (sku, sku_name, unit); same read rules.
--export-dir directory of saved JSON pages (POST /api/v1/entities/records/<type>/export, format json);
             file names <type>-<anything>.json; several pages per type allowed.
             Types needed: location_node, catalog_uom, catalog_item.
--mapping    optional JSON object {"<extract column>": "<neutral name>"}; applied to both CSV files.

For each of the three tables (locations, units, items) it prints one DIFF line per code that differs or is on one
side only, ROWS and one sha256 HASH per side (over sorted "code TAB name" lines), and RESULT for that table.
Final line: RESULT equal|different.  Exit 0 all equal, 1 any difference, 2 bad input.
No cell text appears in an error message.
"""

import argparse
import csv
import glob
import hashlib
import io
import json
import sys
from pathlib import Path

TABLES = [
    ("locations", "location_node"),
    ("units", "catalog_uom"),
    ("items", "catalog_item"),
]


def fail(msg):
    print("qoimeks_masters_compare: " + msg, file=sys.stderr)
    sys.exit(2)


def read_csv(path, mapping, needed):
    p = Path(path)
    if not p.is_file():
        fail("missing input file %s" % p.name)
    text = p.read_text(encoding="utf-8-sig")
    first = text.splitlines()[0] if text.strip() else ""
    delim = ";" if first.count(";") > first.count(",") else ","
    rd = csv.DictReader(io.StringIO(text), delimiter=delim)
    cols = [mapping.get(c, c) for c in (rd.fieldnames or [])]
    for need in needed:
        if need not in cols:
            fail("%s lacks column %s" % (p.name, need))
    rows = []
    for raw in rd:
        rows.append({mapping.get(k, k): (v or "").strip() for k, v in raw.items() if k is not None})
    return rows


def read_export(export_dir, entity_type):
    """Return dict code -> name from all JSON pages of entity_type in export_dir."""
    pattern = str(Path(export_dir) / (entity_type + "-*.json"))
    pages = sorted(glob.glob(pattern))
    if not pages:
        fail("no export page found for %s (expected %s-*.json in %s)" % (entity_type, entity_type, export_dir))
    result = {}
    for page_path in pages:
        try:
            with open(page_path, encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError):
            fail("export page is not readable JSON: %s" % Path(page_path).name)
        if not isinstance(data, dict) or "records" not in data:
            fail("export page has no records list: %s" % Path(page_path).name)
        for rec in data["records"]:
            if not isinstance(rec, dict):
                fail("export page has no records list: %s" % Path(page_path).name)
            if rec.get("deleted"):
                continue
            fv = rec.get("field_values", {})
            code = str(fv.get("code", "")).strip()
            name = str(fv.get("name", "")).strip()
            if code:
                result[code] = name
    return result


def digest(table):
    """sha256 over sorted lines 'code TAB name\\n', UTF-8."""
    lines = sorted("%s\t%s\n" % (code, name) for code, name in table.items())
    return hashlib.sha256("".join(lines).encode("utf-8")).hexdigest()


def compare_table(table_name, csv_side, export_side):
    """Print DIFF/ROWS/HASH/RESULT lines for one table. Returns True if equal."""
    all_codes = sorted(set(csv_side) | set(export_side))
    diffs = []
    for code in all_codes:
        in_csv = code in csv_side
        in_exp = code in export_side
        if in_csv and in_exp:
            if csv_side[code] != export_side[code]:
                diffs.append("DIFF %s %s name" % (table_name, code))
        elif in_csv:
            diffs.append("DIFF %s %s only_csv" % (table_name, code))
        else:
            diffs.append("DIFF %s %s only_export" % (table_name, code))
    for d in diffs:
        print(d)
    h_csv = digest(csv_side)
    h_exp = digest(export_side)
    print("ROWS %s csv %d" % (table_name, len(csv_side)))
    print("ROWS %s export %d" % (table_name, len(export_side)))
    print("HASH %s csv %s" % (table_name, h_csv))
    print("HASH %s export %s" % (table_name, h_exp))
    equal = not diffs and h_csv == h_exp
    print("RESULT %s %s" % (table_name, "equal" if equal else "different"))
    return equal


def main():
    ap = argparse.ArgumentParser(description="REQ-881 master data compare")
    ap.add_argument("--locations", required=True)
    ap.add_argument("--items", required=True)
    ap.add_argument("--export-dir", required=True)
    ap.add_argument("--mapping")
    a = ap.parse_args()

    mapping = {}
    if a.mapping:
        try:
            mapping = json.loads(Path(a.mapping).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            fail("mapping is not readable JSON")
        if not isinstance(mapping, dict):
            fail("mapping must be a JSON object")

    if not Path(a.export_dir).is_dir():
        fail("export-dir is not a directory: %s" % a.export_dir)

    loc_rows = read_csv(a.locations, mapping, ["loc_code", "loc_name"])
    item_rows = read_csv(a.items, mapping, ["sku", "sku_name", "unit"])

    places_csv = {r["loc_code"]: r["loc_name"] for r in loc_rows if r.get("loc_code")}
    units_csv = {r["unit"]: r["unit"] for r in item_rows if r.get("unit")}
    items_csv = {r["sku"]: r["sku_name"] for r in item_rows if r.get("sku")}

    places_exp = read_export(a.export_dir, "location_node")
    units_exp = read_export(a.export_dir, "catalog_uom")
    items_exp = read_export(a.export_dir, "catalog_item")

    all_equal = True
    all_equal = compare_table("locations", places_csv, places_exp) and all_equal
    all_equal = compare_table("units", units_csv, units_exp) and all_equal
    all_equal = compare_table("items", items_csv, items_exp) and all_equal
    print("RESULT %s" % ("equal" if all_equal else "different"))
    sys.exit(0 if all_equal else 1)


if __name__ == "__main__":
    main()
