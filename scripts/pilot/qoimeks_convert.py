#!/usr/bin/env python3
"""qoimeks_convert.py -- dry-run converter: Qoimeks extract (CSV) -> Letflow stock import files (xlsx). T-1616, B4#11.

Prepared, not started: this tool only reads CSV files and writes files. It opens no network connection, reads no
secret and touches no database. Run it on a copy of the data, QA only (docs/runbooks/qoimeks-rehearsal.md).

  python3 -I scripts/pilot/qoimeks_convert.py convert --in DIR --out DIR --system S \\
      --org-unit-ext ID --responsible-ext ID --received-on YYYY-MM-DD [--mapping map.json] [--allow-drops]
  python3 -I scripts/pilot/qoimeks_convert.py headers --out DIR --responses DIR \\
      --org-unit-id UUID --responsible-id UUID

`convert` reads locations.csv (loc_code, loc_name, loc_parent), items.csv (sku, sku_name, unit, [home_loc], [alt_loc],
[barcode]) and balances.csv (sku, loc, qty, [as_of]) from --in. The optional codes.csv holds active code rows
(object_type, object_code, code_type, code) for SKUs and places. `home_loc` (the usual place, a loc_code) goes into
the items file as `default_location_id` (G3); `alt_loc` (the second place) is NOT carried: the report counts the rows
that had one. `--mapping` is a JSON object {"<column in the extract>": "<neutral name>"}.
It writes into --out: 01-locations-NN.xlsx, 02-uoms.xlsx, 03-items-NN.xlsx, 06-codes-NN.xlsx,
07-code-assignments-NN.xlsx, 04-opening-lines-NN.xlsx, manifest.json, report.txt and expected_counts.txt. Code files are
written only when at least one code survives and are ordered before the opening lines; a file type with no rows is
not written. Positive opening lines are chunked first; negative lines follow in all-negative files (REQ-837). Zero
balances are skipped as `quantity_zero`, not dropped. The barcode column and codes.csv code types ean13, ean8,
code128 and manual become kind barcode; qr becomes kind qr. A repeated code for the same object is kept once; a code
already kept for another object is dropped.

`headers` reads manifest.json and the saved JSON responses of the first three uploads (RDIR/<file stem>.json, the
`results[]` with `line` and `record_id`) and writes headers/QOI-HDR-NN.json, one `POST /documents` body per opening
header. A header needs 1..100 lines with record UUIDs, so it is created with its first real balance (its bootstrap
line); the later upload of the lines file then reports that row unchanged and the others created.

report.txt carries row numbers and constant reasons, never cell text. --out inside the repository checkout is refused
(no customer data in git). Exit codes: 0 ok, 3 rows were dropped (convert), 2 bad input.
"""

import argparse
import csv
import io
import json
import re
import sys
import unicodedata
import zipfile
from decimal import Decimal, InvalidOperation
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
MAX_ROWS = 200  # rows per import file (the record import route)
MAX_LINES = 100  # lines per opening document

LOC_COLS = ["code", "name", "node_kind", "parent_id", "external_ref_system", "external_ref_id"]
UOM_COLS = ["code", "name", "active", "external_ref_system", "external_ref_id"]
ITEM_COLS = ["code", "name", "base_uom_id", "kind", "active", "external_ref_system", "external_ref_id"]
ITEM_COLS_PLACE = ITEM_COLS + ["default_location_id"]  # G3: used when at least one kept item has a usual place
LINE_COLS = [
    "header_id", "org_unit_id", "location_id", "responsible_id", "catalog_item_id",
    "catalog_uom_id", "quantity", "received_on", "external_ref_system", "external_ref_id",
]
CODE_COLS = ["value", "kind", "external_ref_system", "external_ref_id"]
ASSIGNMENT_COLS = ["code_id", "target_type", "target_id", "external_ref_system", "external_ref_id"]
CODE_TYPES = {"ean13", "ean8", "code128", "qr", "manual"}
NEEDED = {
    "locations": ["loc_code", "loc_name", "loc_parent"],
    "items": ["sku", "sku_name", "unit"],
    "balances": ["sku", "loc", "qty"],
    "codes": ["object_type", "object_code", "code_type", "code"],
}
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def fail(msg):
    print("qoimeks_convert: " + msg, file=sys.stderr)
    sys.exit(2)


def check_out(out):
    p = Path(out).resolve()
    if p == REPO_ROOT or REPO_ROOT in p.parents:
        fail("--out is inside the repository checkout; choose a directory outside it")
    return p


# ---------------------------------------------------------------- xlsx

def _esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _col(i):
    return chr(ord("A") + i)


def write_xlsx(path, header, rows):
    """All cells are shared strings (leading zeros and `=` text stay text). Fixed timestamps: reproducible bytes."""
    table = [header] + rows
    strings, index = [], {}
    for r in table:
        for c in r:
            if c not in index:
                index[c] = len(strings)
                strings.append(c)
    body = "".join(
        '<row r="%d">%s</row>' % (
            n, "".join('<c r="%s%d" t="s"><v>%d</v></c>' % (_col(i), n, index[c]) for i, c in enumerate(r) if c != "")
        )
        for n, r in enumerate(table, 1)
    )
    decl = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    ns = 'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
    rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    parts = [
        ("[Content_Types].xml", decl + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
         '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
         '<Default Extension="xml" ContentType="application/xml"/>'
         '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
         '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
         '<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>'
         '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>'),
        ("_rels/.rels", decl + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
         '<Relationship Id="rId1" Type="%s/officeDocument" Target="xl/workbook.xml"/></Relationships>' % rel),
        ("xl/workbook.xml", decl + '<workbook %s xmlns:r="%s"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>' % (ns, rel)),
        ("xl/_rels/workbook.xml.rels", decl + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
         '<Relationship Id="rId1" Type="%s/worksheet" Target="worksheets/sheet1.xml"/>'
         '<Relationship Id="rId2" Type="%s/styles" Target="styles.xml"/>'
         '<Relationship Id="rId3" Type="%s/sharedStrings" Target="sharedStrings.xml"/></Relationships>' % (rel, rel, rel)),
        ("xl/styles.xml", decl + '<styleSheet %s><cellStyleXfs count="1"><xf numFmtId="0"/></cellStyleXfs>'
         '<cellXfs count="1"><xf numFmtId="0" xfId="0"/></cellXfs></styleSheet>' % ns),
        ("xl/sharedStrings.xml", decl + '<sst %s count="%d" uniqueCount="%d">%s</sst>' % (
            ns, len(strings), len(strings),
            "".join('<si><t xml:space="preserve">%s</t></si>' % _esc(s) for s in strings))),
        ("xl/worksheets/sheet1.xml", decl + '<worksheet %s><sheetData>%s</sheetData></worksheet>' % (ns, body)),
    ]
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in parts:
            zi = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            zi.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(zi, data)


# ---------------------------------------------------------------- csv

def read_csv(path, mapping, kind):
    p = Path(path)
    if not p.is_file():
        fail("missing input file %s" % p.name)
    text = p.read_text(encoding="utf-8-sig")
    first = text.splitlines()[0] if text.strip() else ""
    delim = ";" if first.count(";") > first.count(",") else ","
    rd = csv.DictReader(io.StringIO(text, newline=""), delimiter=delim)
    names = [mapping.get(h, h) for h in (rd.fieldnames or [])]
    for need in NEEDED[kind]:
        if need not in names:
            fail("%s.csv has no column %s (see --mapping)" % (kind, need))
    rows = []
    for rec in rd:
        row = {}
        for h, v in rec.items():
            if h is None:
                row["_surplus"] = True
            else:
                row[mapping.get(h, h)] = (v or "").strip()
        rows.append(row)
    return rows


def read_optional_csv(path, mapping, kind):
    return read_csv(path, mapping, kind) if Path(path).is_file() else []


def bal_ref(sku, loc):
    """Unambiguous balance reference: the sku length prefixes the pair, so (A, B:C) and (A:B, C) differ."""
    return "BAL:%d:%s:%s" % (len(sku), sku, loc)


def chunks(seq, n):
    return [seq[i:i + n] for i in range(0, len(seq), n)]


# ---------------------------------------------------------------- convert

def order_locations(rows, drops):
    """Rows with code, name, unique code; parents before children (depth order). Rejects are counted by row number."""
    ok, seen = [], set()
    for n, r in enumerate(rows, 1):
        if r.get("_surplus"):
            drops.append(("locations", n, "too_many_fields"))
        elif not r["loc_code"]:
            drops.append(("locations", n, "missing_code"))
        elif not r["loc_name"]:
            drops.append(("locations", n, "missing_name"))
        elif r["loc_code"] in seen:
            drops.append(("locations", n, "duplicate_code"))
        else:
            seen.add(r["loc_code"])
            ok.append((n, r))
    placed, out, pending = set(), [], ok
    while pending:
        nxt = [(n, r) for n, r in pending if not r["loc_parent"] or r["loc_parent"] in placed]
        if not nxt:
            break
        for n, r in nxt:
            placed.add(r["loc_code"])
            out.append(r)
        pending = [x for x in pending if x not in nxt]
    for n, r in pending:
        known = r["loc_parent"] in seen
        drops.append(("locations", n, "parent_rejected_or_cycle" if known else "unknown_parent"))
    return out


def collect_codes(items, code_rows, item_codes, loc_codes, drops):
    """Keep the first owner of each valid code; item barcodes precede rows of codes.csv."""
    kept, owners = [], {}

    def add(source, n, object_type, object_code, code_type, code):
        if source == "codes" and object_type not in ("sku", "location"):
            drops.append((source, n, "code_object_type_unknown"))
            return
        if source == "codes" and code_type not in CODE_TYPES:
            drops.append((source, n, "code_type_unknown"))
            return
        if not code:
            return
        if any(c.isspace() or unicodedata.category(c) == "Cc" for c in code):
            drops.append((source, n, "code_invalid"))
            return
        target_type = "catalog_item" if object_type == "sku" else "location_node"
        known = object_code in (item_codes if object_type == "sku" else loc_codes)
        if not known:
            reason = "code_unknown_item" if object_type == "sku" else "code_unknown_location"
            drops.append((source, n, reason))
            return
        target = (target_type, object_code)
        if code in owners:
            if owners[code] != target:
                drops.append((source, n, "code_taken"))
            return
        owners[code] = target
        kept.append((code, "qr" if code_type == "qr" else "barcode", target_type, object_code))

    for r in items:
        add("items", r["_source_row"], "sku", r["sku"], "barcode", r.get("barcode", ""))
    for n, r in enumerate(code_rows, 1):
        if r.get("_surplus"):
            drops.append(("codes", n, "too_many_fields"))
        else:
            add("codes", n, r["object_type"], r["object_code"], r["code_type"], r["code"])
    return kept


def cmd_convert(a):
    out = check_out(a.out)
    if not DATE_RE.match(a.received_on):
        fail("--received-on must be YYYY-MM-DD")
    mapping = {}
    if a.mapping:
        try:
            mapping = json.loads(Path(a.mapping).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            fail("--mapping is not readable JSON")
        if not isinstance(mapping, dict):
            fail("--mapping must be a JSON object")
    src = Path(a.indir)
    locs = read_csv(src / "locations.csv", mapping, "locations")
    items = read_csv(src / "items.csv", mapping, "items")
    bals = read_csv(src / "balances.csv", mapping, "balances")
    code_rows = read_optional_csv(src / "codes.csv", mapping, "codes")

    drops = []
    sysn = a.system

    locations = order_locations(locs, drops)
    loc_codes = {r["loc_code"] for r in locations}

    good_items, seen = [], set()
    second_places = 0  # kept items that had a second place; it is not imported (G3), so it is counted, not silent
    for n, r in enumerate(items, 1):
        if r.get("_surplus"):
            drops.append(("items", n, "too_many_fields"))
        elif not r["sku"]:
            drops.append(("items", n, "missing_sku"))
        elif not r["sku_name"]:
            drops.append(("items", n, "missing_name"))
        elif not r["unit"]:
            drops.append(("items", n, "missing_unit"))
        elif r["sku"] in seen:
            drops.append(("items", n, "duplicate_sku"))
        elif r.get("home_loc") and r["home_loc"] not in loc_codes:
            drops.append(("items", n, "unknown_default_location"))
        else:
            seen.add(r["sku"])
            r["_source_row"] = n
            good_items.append(r)
            if r.get("alt_loc"):
                second_places += 1
    units = sorted({r["unit"] for r in good_items})
    if len(units) > MAX_ROWS:
        fail("more than %d distinct units" % MAX_ROWS)
    unit_of = {r["sku"]: r["unit"] for r in good_items}
    codes = collect_codes(good_items, code_rows, set(unit_of), loc_codes, drops)

    positive_lines, negative_lines, skipped, keys = [], [], [], set()
    for n, r in enumerate(bals, 1):
        q = r["qty"]
        if r.get("_surplus"):
            drops.append(("balances", n, "too_many_fields"))
            continue
        if "," in q:
            drops.append(("balances", n, "quantity_comma_decimal"))
            continue
        try:
            d = Decimal(q)
            if not d.is_finite():
                raise InvalidOperation
        except InvalidOperation:
            drops.append(("balances", n, "quantity_invalid"))
            continue
        asof = r.get("as_of", "") or a.received_on
        if d == 0:
            skipped.append(("balances", n, "quantity_zero"))
        elif r["sku"] not in unit_of:
            drops.append(("balances", n, "unknown_item"))
        elif r["loc"] not in loc_codes:
            drops.append(("balances", n, "unknown_location"))
        elif not DATE_RE.match(asof):
            drops.append(("balances", n, "date_invalid"))
        elif (r["sku"], r["loc"]) in keys:
            drops.append(("balances", n, "duplicate_balance"))
        else:
            keys.add((r["sku"], r["loc"]))
            line = (r["sku"], r["loc"], format(d.normalize(), "f"), asof)
            (negative_lines if d < 0 else positive_lines).append(line)

    out.mkdir(parents=True, exist_ok=True)
    files, report = [], []

    def emit(name, etype, header, rows):
        write_xlsx(out / name, header, rows)
        files.append({"file": name, "entity_type": etype, "rows": len(rows)})

    loc_rows = [[r["loc_code"], r["loc_name"], "location", r["loc_parent"], sysn, r["loc_code"]] for r in locations]
    loc_pos = {}  # code -> (file, sheet row)
    for i, part in enumerate(chunks(loc_rows, MAX_ROWS), 1):
        name = "01-locations-%02d.xlsx" % i
        emit(name, "location_node", LOC_COLS, part)
        for j, row in enumerate(part):
            loc_pos[row[0]] = (name, j + 2)
    if units:
        emit("02-uoms.xlsx", "catalog_uom", UOM_COLS, [[u, u, "true", sysn, u] for u in units])
    uom_pos = {u: ("02-uoms.xlsx", j + 2) for j, u in enumerate(units)}
    with_place = [r for r in good_items if r.get("home_loc")]
    item_cols = ITEM_COLS_PLACE if with_place else ITEM_COLS
    item_rows = [[r["sku"], r["sku_name"], r["unit"], "material", "true", sysn, r["sku"]]
                 + ([r.get("home_loc", "")] if with_place else []) for r in good_items]
    item_pos = {}
    for i, part in enumerate(chunks(item_rows, MAX_ROWS), 1):
        name = "03-items-%02d.xlsx" % i
        emit(name, "catalog_item", item_cols, part)
        for j, row in enumerate(part):
            item_pos[row[0]] = (name, j + 2)

    code_rows_out = [[code, kind, sysn, code] for code, kind, _, _ in codes]
    assignment_rows_out = [[code, target_type, target, sysn, code]
                           for code, _, target_type, target in codes]
    for prefix, etype, header, rows in (
            ("06-codes", "code_tag", CODE_COLS, code_rows_out),
            ("07-code-assignments", "code_assignment", ASSIGNMENT_COLS, assignment_rows_out)):
        for i, part in enumerate(chunks(rows, MAX_ROWS), 1):
            emit("%s-%02d.xlsx" % (prefix, i), etype, header, part)

    headers = []
    line_groups = chunks(positive_lines, MAX_LINES) + chunks(negative_lines, MAX_LINES)
    for i, part in enumerate(line_groups, 1):
        hid = "QOI-HDR-%02d" % i
        name = "04-opening-lines-%02d.xlsx" % i
        rows = [[hid, a.org_unit_ext, loc, a.responsible_ext, sku, unit_of[sku], qty, asof, sysn, bal_ref(sku, loc)]
                for sku, loc, qty, asof in part]
        emit(name, "stock_opening_line", LINE_COLS, rows)
        sku, loc, qty, asof = part[0]
        headers.append({
            "id": hid, "file": name, "rows": len(rows),
            "bootstrap": {
                "external_ref_system": sysn, "external_ref_id": bal_ref(sku, loc),
                "quantity": qty, "received_on": asof,
                "location": dict(zip(("file", "row"), loc_pos[loc])),
                "item": dict(zip(("file", "row"), item_pos[sku])),
                "uom": dict(zip(("file", "row"), uom_pos[unit_of[sku]])),
            },
        })

    counts = {
        "documents": len(headers),
        "records.catalog_item": len(item_rows),
        "records.catalog_uom": len(units),
        "records.code_assignment": len(assignment_rows_out),
        "records.code_tag": len(code_rows_out),
        "records.location_node": len(loc_rows),
        "records.stock_opening_line": len(positive_lines) + len(negative_lines),
        "items_with_default_location": len(with_place),
    }
    (out / "expected_counts.txt").write_text("".join("%s %d\n" % kv for kv in sorted(counts.items())), encoding="utf-8")
    manifest = {
        "system": sysn, "org_unit_ext": a.org_unit_ext, "responsible_ext": a.responsible_ext,
        "received_on": a.received_on, "upload_order": [f["file"] for f in files],
        "files": files, "headers": headers,
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    report.append("qoimeks_convert report (row numbers are data rows of the input CSV; no cell text)")
    for k, v in sorted(counts.items()):
        report.append("%s %d" % (k, v))
    for kind, label in (("locations", "records.location_node"), ("uoms", "records.catalog_uom"),
                        ("items", "records.catalog_item"), ("lines", "records.stock_opening_line")):
        if counts[label] == 0:
            report.append("no rows for %s: no file written" % label.split(".")[1])
    report.append("items with a second place, not imported (G3) %d" % second_places)
    if skipped:
        report.append("skipped:")
        for kind, n, reason in sorted(skipped, key=lambda d: (d[0], d[1])):
            report.append("skipped %s row %d: %s" % (kind, n, reason))
        report.append("skipped total %d" % len(skipped))
    for kind, n, reason in sorted(drops, key=lambda d: (d[0], d[1])):
        report.append("dropped %s row %d: %s" % (kind, n, reason))
    report.append("dropped total %d" % len(drops))
    (out / "report.txt").write_text("\n".join(report) + "\n", encoding="utf-8")

    print("\n".join(report))
    if drops and not a.allow_drops:
        sys.exit(3)


# ---------------------------------------------------------------- headers

UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")


def record_id(resp_dir, ref):
    path = resp_dir / (Path(ref["file"]).stem + ".json")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        for res in data["results"]:
            if res.get("line") == ref["row"]:
                rid = res.get("record_id")
                if isinstance(rid, str) and UUID_RE.match(rid):
                    return rid
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        pass
    fail("no usable response for %s row %s" % (ref["file"], ref["row"]))


def cmd_headers(a):
    out = check_out(a.out)
    try:
        manifest = json.loads((out / "manifest.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        fail("manifest.json missing or unreadable in --out")
    for v in (a.org_unit_id, a.responsible_id):
        if not UUID_RE.match(v):
            fail("--org-unit-id and --responsible-id must be record UUIDs")
    rdir = Path(a.responses)
    dest = out / "headers"
    bodies = []
    for h in manifest.get("headers", []):
        b = h["bootstrap"]
        bodies.append((h["id"], {
            "kind": "opening",
            "org_unit_id": a.org_unit_id,
            "external_ref_system": manifest["system"],
            "external_ref_id": h["id"],
            "lines": [{
                "location_id": record_id(rdir, b["location"]),
                "responsible_id": a.responsible_id,
                "catalog_item_id": record_id(rdir, b["item"]),
                "catalog_uom_id": record_id(rdir, b["uom"]),
                "quantity": b["quantity"],
                "received_on": b["received_on"],
                "external_ref_system": b["external_ref_system"],
                "external_ref_id": b["external_ref_id"],
            }],
        }))
    dest.mkdir(exist_ok=True)
    for hid, body in bodies:
        (dest / (hid + ".json")).write_text(json.dumps(body, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("wrote %d header bodies to %s" % (len(bodies), dest.name))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("convert")
    c.add_argument("--in", dest="indir", required=True)
    c.add_argument("--out", required=True)
    c.add_argument("--system", required=True)
    c.add_argument("--org-unit-ext", required=True)
    c.add_argument("--responsible-ext", required=True)
    c.add_argument("--received-on", required=True)
    c.add_argument("--mapping")
    c.add_argument("--allow-drops", action="store_true")
    h = sub.add_parser("headers")
    h.add_argument("--out", required=True)
    h.add_argument("--responses", required=True)
    h.add_argument("--org-unit-id", required=True)
    h.add_argument("--responsible-id", required=True)
    a = ap.parse_args(argv)
    (cmd_convert if a.cmd == "convert" else cmd_headers)(a)


if __name__ == "__main__":
    main()
