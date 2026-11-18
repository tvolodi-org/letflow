#!/usr/bin/env python3
"""qoimeks_balances_compare.py -- RH-7: quantity per item and place, Letflow balances vs Qoimeks balances.csv. T-2024.

Read-only and offline: it opens files, prints a report, writes nothing, opens no network connection and reads no secret.
Run it on QA copies only (docs/runbooks/qoimeks-rehearsal.md, step 8).

  python3 -I scripts/pilot/qoimeks_balances_compare.py --xlsx stock-balances.xlsx --csv balances.csv \\
      [--items items.csv] [--locations locations.csv] [--mapping map.json] [--keep-nonpositive]
  python3 -I scripts/pilot/qoimeks_balances_compare.py --json-pages PAGES --csv balances.csv \\
      [--items items.csv] [--locations locations.csv] [--mapping map.json] [--keep-nonpositive]

--xlsx   the Letflow stock balances export (sheet "balances", columns sku, location, quantity; lots of one item and place are summed).
--json-pages  a directory of every saved JSON page of GET /api/v1/modules/stock/balances, named page-001.json,
              page-002.json, ... in cursor order. Every page but the last must have a non-null next_cursor; the last
              must have next_cursor null, so a partial export is refused instead of reported as a partial difference.
--csv    the Qoimeks extract (columns sku, loc, qty), the same one `qoimeks_convert.py convert` reads; --mapping as there.
--items / --locations  optional extract files (sku, sku_name / loc_code, loc_name): only used to print names next to the codes.

Rows with a quantity of zero or below are left out on BOTH sides by default and counted in the summary;
--keep-nonpositive compares them too. The runbook's step 6 checks the negative keys that REQ-837 loads.
Duplicate (item, place) rows are summed on both sides.

Output: one `DIFF <kind> <item> <place> csv=<q> xlsx=<q>` line per difference (kind: only_csv, only_xlsx, quantity), with
names when given, then `HASH csv|xlsx <sha256>` and `ROWS csv|xlsx N`. With --json-pages the Letflow side is labelled
`letflow` instead of `xlsx` in DIFF, HASH, ROWS and LEFT_OUT lines. The hash is over the sorted lines
`item TAB place TAB quantity` (quantity as a plain decimal with no trailing zeros, newline after each line).
Exit codes: 0 no difference and equal hashes, 1 differences, 2 bad input.
"""

import argparse
import csv
import hashlib
import io
import json
import re
import sys
import zipfile
from decimal import Decimal, InvalidOperation
from pathlib import Path
from xml.etree import ElementTree as ET

NS = {
    "m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
    "r": "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
    "pr": "http://schemas.openxmlformats.org/package/2006/relationships",
}
MAX_BYTES = 50 * 1024 * 1024  # uncompressed size cap per xlsx part (zip bombs)
SHEET = "balances"


def fail(msg):
    print("qoimeks_balances_compare: " + msg, file=sys.stderr)
    sys.exit(2)


def dec(text, where):
    try:
        d = Decimal(str(text).strip())
    except InvalidOperation:
        fail("%s: quantity is not a number" % where)
    if not d.is_finite():
        fail("%s: quantity is not a number" % where)
    return d


def plain(d):
    """Canonical text of a quantity: plain decimal, no exponent, no trailing zeros, no '-0'."""
    s = format(d.normalize(), "f")
    return "0" if s in ("-0", "") else s


# ---------------------------------------------------------------- xlsx (stdlib reader, one pass)

def _read(z, name):
    info = z.getinfo(name)
    if info.file_size > MAX_BYTES:
        fail("xlsx part %s is too large" % name)
    return z.read(name)


def _col_index(ref):
    letters = re.match(r"[A-Z]+", ref).group(0)
    n = 0
    for ch in letters:
        n = n * 26 + ord(ch) - 64
    return n - 1


def read_xlsx(path):
    """Rows of sheet `balances` as lists of cell texts (numbers as their stored text)."""
    try:
        z = zipfile.ZipFile(path)
        wb = ET.fromstring(_read(z, "xl/workbook.xml"))
        rels = ET.fromstring(_read(z, "xl/_rels/workbook.xml.rels"))
        targets = {r.get("Id"): r.get("Target") for r in rels.findall("pr:Relationship", NS)}
        target = None
        for s in wb.findall("m:sheets/m:sheet", NS):
            if s.get("name") == SHEET:
                target = targets[s.get("{%s}id" % NS["r"])]
        if target is None:
            fail('xlsx has no sheet "%s"' % SHEET)
        target = target.lstrip("/")
        sheet_path = target if target.startswith("xl/") else "xl/" + target
        shared = []
        if "xl/sharedStrings.xml" in z.namelist():
            sst = ET.fromstring(_read(z, "xl/sharedStrings.xml"))
            for si in sst.findall("m:si", NS):
                shared.append("".join(t.text or "" for t in si.iter("{%s}t" % NS["m"])))
        sheet = ET.fromstring(_read(z, sheet_path))
    except (zipfile.BadZipFile, KeyError, ET.ParseError, OSError):
        fail("xlsx is not readable")
    rows = []
    for row in sheet.findall("m:sheetData/m:row", NS):
        cells = {}
        for c in row.findall("m:c", NS):
            t = c.get("t")
            if t == "s":
                v = c.find("m:v", NS)
                val = shared[int(v.text)] if v is not None and v.text else ""
            elif t == "inlineStr":
                val = "".join(x.text or "" for x in c.iter("{%s}t" % NS["m"]))
            else:
                v = c.find("m:v", NS)
                val = v.text if v is not None and v.text else ""
            cells[_col_index(c.get("r"))] = val
        rows.append([cells.get(i, "") for i in range(max(cells) + 1)] if cells else [])
    return rows


def xlsx_totals(path):
    rows = read_xlsx(path)
    if not rows:
        fail("xlsx sheet is empty")
    head = [h.strip() for h in rows[0]]
    for need in ("sku", "location", "quantity"):
        if need not in head:
            fail("xlsx header lacks column %s" % need)
    i_sku, i_loc, i_qty = head.index("sku"), head.index("location"), head.index("quantity")
    out = {}
    for n, r in enumerate(rows[1:], 2):
        r = r + [""] * (len(head) - len(r))
        if not any(c.strip() for c in r):
            continue
        sku, loc = r[i_sku].strip(), r[i_loc].strip()
        if not sku or not loc:
            fail("xlsx row %d: item or place is empty" % n)
        key = (sku, loc)
        out[key] = out.get(key, Decimal(0)) + dec(r[i_qty], "xlsx row %d" % n)
    return out


# ---------------------------------------------------------------- paged JSON balances

def json_pages_totals(path):
    """Totals of one complete, filename-ordered cursor chain of balances JSON pages."""
    directory = Path(path)
    if not directory.is_dir():
        fail("json-pages is not a directory")
    pages = sorted(directory.glob("page-*.json"))
    if not pages:
        fail("no balance pages found (expected page-*.json)")
    expected = ["page-%03d.json" % n for n in range(1, len(pages) + 1)]
    if [page.name for page in pages] != expected:
        fail("balance pages must be named page-001.json, page-002.json, ... without gaps")
    out = {}
    for page_no, page in enumerate(pages):
        try:
            data = json.loads(page.read_text(encoding="utf-8"), parse_float=Decimal)
        except (OSError, ValueError):
            fail("balance page is not readable JSON: %s" % page.name)
        if not isinstance(data, dict) or not isinstance(data.get("rows"), list) or "next_cursor" not in data:
            fail("balance page has no rows list and next_cursor: %s" % page.name)
        cursor = data["next_cursor"]
        if page_no < len(pages) - 1:
            if not isinstance(cursor, str) or not cursor:
                fail("incomplete balance page sequence before %s" % page.name)
        elif cursor is not None:
            fail("incomplete balance page sequence: last page has next_cursor")
        for row_no, row in enumerate(data["rows"], 1):
            where = "json page %s row %d" % (page.name, row_no)
            if not isinstance(row, dict):
                fail("%s: balance row is not an object" % where)
            sku, loc = row.get("sku"), row.get("location")
            if not isinstance(sku, str) or not isinstance(loc, str):
                fail("%s: item or place is not text" % where)
            sku, loc = sku.strip(), loc.strip()
            if not sku or not loc:
                fail("%s: item or place is empty" % where)
            key = (sku, loc)
            out[key] = out.get(key, Decimal(0)) + dec(row.get("quantity"), where)
    return out


# ---------------------------------------------------------------- csv

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


def csv_totals(path, mapping):
    out = {}
    for n, r in enumerate(read_csv(path, mapping, ["sku", "loc", "qty"]), 2):
        if not r["sku"] or not r["loc"]:
            fail("csv row %d: item or place is empty" % n)
        q = r["qty"]
        if "," in q and "." not in q:
            q = q.replace(",", ".")  # the converter refuses comma decimals; here a read-only check may accept them
        key = (r["sku"], r["loc"])
        out[key] = out.get(key, Decimal(0)) + dec(q, "csv row %d" % n)
    return out


def names(path, mapping, code_col, name_col):
    if not path:
        return {}
    return {r[code_col]: r[name_col] for r in read_csv(path, mapping, [code_col, name_col])}


# ---------------------------------------------------------------- compare

def digest(totals):
    lines = sorted("%s\t%s\t%s\n" % (k[0], k[1], plain(q)) for k, q in totals.items())
    return hashlib.sha256("".join(lines).encode("utf-8")).hexdigest()


def label(code, table):
    return "%s (%s)" % (code, table[code]) if code in table else code


def main():
    ap = argparse.ArgumentParser(description="RH-7 balances compare")
    source = ap.add_mutually_exclusive_group(required=True)
    source.add_argument("--xlsx")
    source.add_argument("--json-pages")
    ap.add_argument("--csv", required=True)
    ap.add_argument("--items")
    ap.add_argument("--locations")
    ap.add_argument("--mapping")
    ap.add_argument("--keep-nonpositive", action="store_true")
    a = ap.parse_args()

    mapping = {}
    if a.mapping:
        try:
            mapping = json.loads(Path(a.mapping).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            fail("mapping is not readable JSON")
        if not isinstance(mapping, dict):
            fail("mapping must be a JSON object")
    if a.xlsx and not Path(a.xlsx).is_file():
        fail("missing xlsx file")

    side = "xlsx" if a.xlsx else "letflow"
    letflow = xlsx_totals(a.xlsx) if a.xlsx else json_pages_totals(a.json_pages)
    sides = {"csv": csv_totals(a.csv, mapping), side: letflow}
    left_out = {}
    if not a.keep_nonpositive:
        for s in sides:
            left_out[s] = sum(1 for q in sides[s].values() if q <= 0)
            sides[s] = {k: q for k, q in sides[s].items() if q > 0}
    item_names = names(a.items, mapping, "sku", "sku_name")
    loc_names = names(a.locations, mapping, "loc_code", "loc_name")

    diffs = []
    for key in sorted(set(sides["csv"]) | set(sides[side])):
        c, x = sides["csv"].get(key), sides[side].get(key)
        if c is not None and x is not None and c == x:
            continue
        kind = "only_" + side if c is None else "only_csv" if x is None else "quantity"
        diffs.append("DIFF %s %s %s csv=%s %s=%s" % (
            kind, label(key[0], item_names), label(key[1], loc_names),
            "-" if c is None else plain(c), side, "-" if x is None else plain(x)))
    for d in diffs:
        print(d)
    h = {s: digest(sides[s]) for s in sides}
    for s in ("csv", side):
        print("ROWS %s %d" % (s, len(sides[s])))
        print("HASH %s %s" % (s, h[s]))
    for s, n in left_out.items():
        print("LEFT_OUT %s nonpositive %d" % (s, n))
    print("RESULT %s" % ("equal" if not diffs and h["csv"] == h[side] else "different"))
    sys.exit(0 if not diffs and h["csv"] == h[side] else 1)


if __name__ == "__main__":
    main()
