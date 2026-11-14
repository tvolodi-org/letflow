#!/usr/bin/env python3
"""forms_compare.py: structure summary and diff of .docx files (stdlib only, T-1965).

Used to compare the official forms we print with the Ministry reference templates
(see docs/status/official-forms-vs-templates.md). Run as `python3 -I -B`.

  forms_compare.py summary FILE.docx [--json]
  forms_compare.py diff REF.docx GEN.docx [--json]
  forms_compare.py text GEN.docx REF.txt [--from MARKER] [--to MARKER] [--json]

Exit 0: ran (differences are output, not failure). Exit 2: unreadable input, one
`forms_compare: error:` line on stderr, no traceback. Units stay in twips (1/20 pt) and
half-points as in the XML. The same bytes that are read are the ones parsed; no entry
over 32 MiB is read.
"""

import argparse
import difflib
import json
import os
import re
import sys
import unicodedata
import xml.etree.ElementTree as ET
import zipfile

W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
MAX_ENTRY = 32 * 1024 * 1024


class InputError(Exception):
    pass


def q(tag):
    return "{%s}%s" % (W, tag)


def wval(el, attr="val"):
    return None if el is None else el.get(q(attr))


def to_int(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


# ---------------------------------------------------------------- reading


def read_entry(zf, name, required):
    try:
        info = zf.getinfo(name)
    except KeyError:
        if required:
            raise InputError("missing %s" % name)
        return None
    if info.file_size > MAX_ENTRY:
        raise InputError("%s is larger than the size cap" % name)
    data = zf.read(name)
    try:
        return ET.fromstring(data)
    except ET.ParseError as e:
        raise InputError("%s: %s" % (name, e))


def load(path):
    try:
        with zipfile.ZipFile(path) as zf:
            doc = read_entry(zf, "word/document.xml", True)
            styles = read_entry(zf, "word/styles.xml", False)
            parts = []
            rels = read_entry(zf, "word/_rels/document.xml.rels", False)
            if rels is not None:
                for rel in rels:
                    t = rel.get("Type", "")
                    if t.endswith("/header") or t.endswith("/footer"):
                        tgt = rel.get("Target", "")
                        name = "word/" + tgt.lstrip("/") if not tgt.startswith("word/") else tgt
                        el = read_entry(zf, name, False)
                        if el is not None:
                            parts.append((rel.get("Id"), t.rsplit("/", 1)[1], el))
            return doc, styles, parts
    except zipfile.BadZipFile:
        raise InputError("not a zip/docx file")
    except OSError as e:
        raise InputError(str(e.strerror or e))


# ---------------------------------------------------------------- text helpers


def para_text(p):
    out = []
    for el in p.iter():
        if el.tag == q("t"):
            out.append(el.text or "")
        elif el.tag in (q("tab"), q("br")):
            out.append(" ")
    return re.sub(r"\s+", " ", "".join(out)).strip()


QUOTES = {"«": '"', "»": '"', "“": '"', "”": '"', "‘": "'", "’": "'",
          "–": "-", "—": "-", "−": "-", " ": " "}


def norm(s):
    s = unicodedata.normalize("NFC", s or "").lower().replace("ё", "е")
    s = "".join(QUOTES.get(c, c) for c in s)
    s = re.sub(r"[_.\s]{2,}", " ", s)
    s = re.sub(r"\s+", " ", s)
    return s.strip(" \t.,;:-\"'()")


# ---------------------------------------------------------------- summary


def run_props(r, pstyle_rpr, default):
    rpr = r.find(q("rPr"))
    name = size = None
    bold = False
    if rpr is not None:
        f = rpr.find(q("rFonts"))
        if f is not None:
            name = f.get(q("ascii")) or f.get(q("hAnsi"))
        size = to_int(wval(rpr.find(q("sz"))))
        b = rpr.find(q("b"))
        bold = b is not None and wval(b) not in ("0", "false")
    return (name or default["name"], size or default["size_half_pt"], bold)


def default_font(styles):
    d = {"name": None, "size_half_pt": None}
    if styles is None:
        return d
    rpr = styles.find("./%s/%s/%s" % (q("docDefaults"), q("rPrDefault"), q("rPr")))
    if rpr is not None:
        f = rpr.find(q("rFonts"))
        if f is not None:
            d["name"] = f.get(q("ascii")) or f.get(q("hAnsi"))
        d["size_half_pt"] = to_int(wval(rpr.find(q("sz"))))
    # the default paragraph style (Normal) overrides docDefaults
    for st in styles.findall(q("style")):
        if st.get(q("type")) == "paragraph" and st.get(q("default")) == "1":
            rp = st.find(q("rPr"))
            if rp is not None:
                f = rp.find(q("rFonts"))
                if f is not None and (f.get(q("ascii")) or f.get(q("hAnsi"))):
                    d["name"] = f.get(q("ascii")) or f.get(q("hAnsi"))
                if rp.find(q("sz")) is not None:
                    d["size_half_pt"] = to_int(wval(rp.find(q("sz"))))
    return d


def section(sp, rel_ids):
    pg = sp.find(q("pgSz"))
    mar = sp.find(q("pgMar"))
    w = to_int(wval(pg, "w")) if pg is not None else None
    h = to_int(wval(pg, "h")) if pg is not None else None
    land = (wval(pg, "orient") == "landscape") or (w is not None and h is not None and w > h)
    keys = ("top", "right", "bottom", "left", "header", "footer")
    margins = {k: (to_int(wval(mar, k)) if mar is not None else None) for k in keys}
    refs = {el.tag: el.get("{%s}id" % R) for el in sp if el.tag in (q("headerReference"), q("footerReference"))}
    return {
        "page_w": w, "page_h": h, "orientation": "landscape" if land else "portrait",
        "margins": margins,
        "has_header": q("headerReference") in refs,
        "has_footer": q("footerReference") in refs,
    }


def summarize_table(tbl, index, nested_in, default):
    grid = [to_int(wval(g, "w")) or 0 for g in tbl.findall("./%s/%s" % (q("tblGrid"), q("gridCol")))]
    rows = tbl.findall(q("tr"))
    span = vmerge = hdr = 0
    heights, texts, head = [], [], []
    max_cols = 0
    for ri, tr in enumerate(rows):
        trpr = tr.find(q("trPr"))
        if trpr is not None and trpr.find(q("tblHeader")) is not None:
            hdr += 1
        h = trpr.find(q("trHeight")) if trpr is not None else None
        heights.append(to_int(wval(h)) if h is not None else None)
        cols = 0
        rowtexts = []
        for tc in tr.findall(q("tc")):
            tcpr = tc.find(q("tcPr"))
            gs = to_int(wval(tcpr.find(q("gridSpan")))) if tcpr is not None and tcpr.find(q("gridSpan")) is not None else 1
            if gs and gs > 1:
                span += 1
            cols += gs or 1
            if tcpr is not None and tcpr.find(q("vMerge")) is not None:
                vmerge += 1
            t = " ".join(para_text(p) for p in tc.findall(q("p")) if para_text(p))
            rowtexts.append(t)
            if t:
                texts.append(norm(t))
        max_cols = max(max_cols, cols)
        if ri < 3:
            head.append(rowtexts)
    return {
        "index": index, "nested_in": nested_in, "grid": grid, "columns": len(grid) or max_cols,
        "rows": len(rows), "header_rows": hdr,
        "merged": {"gridspan": span, "vmerge": vmerge}, "row_heights": heights,
        "head_text": head, "cell_text": texts,
    }


def summarize(path):
    doc, styles, parts = load(path)
    default = default_font(styles)
    body = doc.find(q("body"))
    if body is None:
        raise InputError("no w:body")
    ids = {p[0] for p in parts}
    sections = [section(sp, ids) for sp in body.iter(q("sectPr"))]
    # a header/footer reference only counts when its part exists
    fonts, sizes, blocks, tables = {}, {}, [], []

    def count_runs(p):
        for r in p.iter(q("r")):
            if not "".join(t.text or "" for t in r.iter(q("t"))).strip():
                continue
            name, size, _ = run_props(r, None, default)
            if name:
                fonts[name] = fonts.get(name, 0) + 1
            if size:
                sizes[str(size)] = sizes.get(str(size), 0) + 1

    seen = set()

    def collect(tbl, nested_in):
        if id(tbl) in seen:
            return
        seen.add(id(tbl))
        idx = len(tables)
        tables.append(summarize_table(tbl, idx, nested_in, default))
        for tc in tbl.iter(q("tc")):
            for inner in tc.findall(q("tbl")):
                collect(inner, idx)
        return idx

    for el in body:
        if el.tag == q("p"):
            t = para_text(el)
            ppr = el.find(q("pPr"))
            st = wval(ppr.find(q("pStyle"))) if ppr is not None and ppr.find(q("pStyle")) is not None else None
            al = wval(ppr.find(q("jc"))) if ppr is not None and ppr.find(q("jc")) is not None else None
            runs = [run_props(r, None, default) for r in el.iter(q("r"))
                    if "".join(x.text or "" for x in r.iter(q("t"))).strip()]
            sz = runs[0][1] if runs else None
            blocks.append({"kind": "p", "text": t, "style": st, "align": al,
                           "bold": bool(runs) and all(r[2] for r in runs), "size_half_pt": sz,
                           "has_nonbold": any(not r[2] for r in runs)})
            count_runs(el)
        elif el.tag == q("tbl"):
            idx = collect(el, None)
            blocks.append({"kind": "table", "index": idx})
            for p in el.iter(q("p")):
                count_runs(p)
    hf = [para_text(p) for _, _, el in parts for p in el.iter(q("p")) if para_text(p)]
    # a section's header/footer flags come from existing parts
    kinds = {k for _, k, _ in parts}
    for s in sections:
        s["has_header"] = s["has_header"] and "header" in kinds
        s["has_footer"] = s["has_footer"] and "footer" in kinds
    return {
        "file": os.path.basename(path), "sections": sections, "default_font": default,
        "fonts": fonts, "sizes": sizes, "blocks": blocks, "tables": tables,
        "header_footer_text": hf,
    }


def mm(t):
    return "-" if t is None else "%.1f" % (t * 25.4 / 1440)


def text_report(s):
    out = []
    for i, sec in enumerate(s["sections"]):
        out.append("PAGE\tsection %d: %s x %s twips (%s x %s mm) %s header=%s footer=%s" % (
            i, sec["page_w"], sec["page_h"], mm(sec["page_w"]), mm(sec["page_h"]),
            sec["orientation"], sec["has_header"], sec["has_footer"]))
        m = sec["margins"]
        out.append("MARGIN\tsection %d: top %s right %s bottom %s left %s twips (mm %s/%s/%s/%s)" % (
            i, m["top"], m["right"], m["bottom"], m["left"],
            mm(m["top"]), mm(m["right"]), mm(m["bottom"]), mm(m["left"])))
    d = s["default_font"]
    out.append("FONT\tdefault %s %s half-pt; runs fonts %s sizes %s" % (d["name"], d["size_half_pt"], s["fonts"], s["sizes"]))
    n = 0
    for b in s["blocks"]:
        if b["kind"] == "p":
            if b["text"]:
                out.append("P\t%d style=%s align=%s size=%s %s" % (n, b["style"], b["align"], b["size_half_pt"], b["text"][:120]))
            n += 1
        else:
            out.append("TABLE\t#%d" % b["index"])
    for t in s["tables"]:
        out.append("TABLE %d\tcolumns=%d rows=%d header_rows=%d merged=%s grid_mm=%s nested_in=%s" % (
            t["index"], t["columns"], t["rows"], t["header_rows"], t["merged"],
            [mm(g) for g in t["grid"]], t["nested_in"]))
        for r in t["head_text"]:
            out.append("TABLE %d\trow: %s" % (t["index"], " | ".join(c[:40] for c in r)))
    return out


# ---------------------------------------------------------------- diff


def ratio(a, b):
    return difflib.SequenceMatcher(None, a, b, autojunk=False).ratio()


def cell_overlap(a, b):
    """Share of the smaller table's non-trivial cells that the other table has (pairing score)."""
    ca = {c for c in a if len(c) >= 3 and not c.isdigit()}
    cb = {c for c in b if len(c) >= 3 and not c.isdigit()}
    if not ca or not cb:
        return 0.0
    hit = sum(1 for c in ca if c in cb or any(ratio(c, d) >= 0.85 for d in cb))
    return hit / min(len(ca), len(cb))


def lines_of(s):
    out = []
    for b in s["blocks"]:
        if b["kind"] == "p" and len(norm(b["text"])) >= 3 and not norm(b["text"]).isdigit():
            out.append(norm(b["text"]))
    for t in s["tables"]:
        for c in t["cell_text"]:
            if len(c) >= 3 and not c.isdigit():
                out.append(c)
    return out


def first_paras(s, n=4):
    return [b["text"] for b in s["blocks"] if b["kind"] == "p" and b["text"]][:n]


def title_facts(s):
    texts = [norm(t) for t in first_paras(s)]
    # include the title block when it sits in a layout table
    for t in s["tables"][:3]:
        texts += t["cell_text"][:6]
    annex = form = None
    for t in texts:
        if annex is None and re.search(r"приложени|қосымша", t) and re.search(r"\d", t):
            m = re.search(r"(\d+)", t)
            annex = m.group(1) if m else ""
        if form is None and re.search(r"форм|нысан", t):
            m = re.search(r"(?:форма|нысан)\s*(.+)$", t)
            form = (m.group(1) if m else t).strip()
    return annex, form


def add(out, cat, ref, gen, detail):
    out.append({"category": cat, "ref": ref, "gen": gen, "detail": detail})


def top_key(d):
    return max(d.items(), key=lambda kv: kv[1])[0] if d else None


def diff(ref, gen):
    out = []
    rs, gs = ref["sections"], gen["sections"]
    if rs and gs:
        a, b = rs[0], gs[0]
        if len(rs) != len(gs):
            add(out, "PAGE", len(rs), len(gs), "section count differs: ref %d, gen %d" % (len(rs), len(gs)))
        if a["orientation"] != b["orientation"] or any(
                abs((a[k] or 0) - (b[k] or 0)) > 20 for k in ("page_w", "page_h")):
            add(out, "PAGE", "%sx%s %s" % (a["page_w"], a["page_h"], a["orientation"]),
                "%sx%s %s" % (b["page_w"], b["page_h"], b["orientation"]),
                "page ref %s x %s mm %s, gen %s x %s mm %s" % (
                    mm(a["page_w"]), mm(a["page_h"]), a["orientation"], mm(b["page_w"]), mm(b["page_h"]), b["orientation"]))
        for k in ("top", "right", "bottom", "left"):
            x, y = a["margins"][k], b["margins"][k]
            if x is not None and y is not None and abs(x - y) > 57:
                add(out, "MARGIN", x, y, "%s margin ref %s mm, gen %s mm" % (k, mm(x), mm(y)))
        for k in ("has_header", "has_footer"):
            if a[k] != b[k]:
                add(out, "HEADER_FOOTER", a[k], b[k], "%s: ref %s, gen %s" % (k, a[k], b[k]))
    rd, gd = ref["default_font"], gen["default_font"]
    for k, label in (("name", "default font"), ("size_half_pt", "default size (half-pt)")):
        if rd[k] is not None and gd[k] is not None and rd[k] != gd[k]:
            add(out, "FONT", rd[k], gd[k], "%s ref %s, gen %s" % (label, rd[k], gd[k]))
    for key, label in (("fonts", "most used run font"), ("sizes", "most used run size (half-pt)")):
        x, y = top_key(ref[key]), top_key(gen[key])
        if x and y and x != y:
            add(out, "FONT", x, y, "%s ref %s, gen %s" % (label, x, y))
    ra, rf = title_facts(ref)
    ga, gf = title_facts(gen)
    if ra is not None or ga is not None:
        if ra is None or ga is None:
            add(out, "TITLE", ra, ga, "annex line found only in %s" % ("ref" if ga is None else "gen"))
        elif ra != ga:
            add(out, "TITLE", ra, ga, "annex number ref %s, gen %s" % (ra, ga))
    if rf is not None or gf is not None:
        if rf is None or gf is None:
            add(out, "TITLE", rf, gf, "form-code line found only in %s" % ("ref" if gf is None else "gen"))
        elif rf != gf:
            add(out, "TITLE", rf, gf, "form code ref '%s', gen '%s'" % (rf, gf))
    rt = [t for t in ref["tables"] if t["nested_in"] is None]
    gt = [t for t in gen["tables"] if t["nested_in"] is None]
    if len(rt) != len(gt):
        add(out, "TABLE_COUNT", len(rt), len(gt), "top-level tables ref %d, gen %d" % (len(rt), len(gt)))
    cand = sorted(((cell_overlap(a["cell_text"], b["cell_text"]), i, j)
                   for i, a in enumerate(rt) for j, b in enumerate(gt)), reverse=True)
    used_r, used_g, pairs = set(), set(), []
    for r_, i, j in cand:
        if r_ >= 0.3 and i not in used_r and j not in used_g:
            used_r.add(i)
            used_g.add(j)
            pairs.append((i, j))
    for i, a in enumerate(rt):
        if i not in used_r:
            add(out, "TABLE", a["index"], None, "TABLE ref#%d unmatched (%d cols x %d rows)" % (a["index"], a["columns"], a["rows"]))
    for j, b in enumerate(gt):
        if j not in used_g:
            add(out, "TABLE", None, b["index"], "TABLE gen#%d extra (%d cols x %d rows)" % (b["index"], b["columns"], b["rows"]))
    for i, j in sorted(pairs):
        a, b = rt[i], gt[j]
        tag = "TABLE ref#%d~gen#%d" % (a["index"], b["index"])
        if a["columns"] != b["columns"]:
            add(out, "TABLE", a["columns"], b["columns"], "%s columns ref %d, gen %d" % (tag, a["columns"], b["columns"]))
        elif a["grid"] and b["grid"] and sum(a["grid"]) and sum(b["grid"]):
            pa = [g / sum(a["grid"]) for g in a["grid"]]
            pb = [g / sum(b["grid"]) for g in b["grid"]]
            if max(abs(x - y) for x, y in zip(pa, pb)) > 0.05:
                add(out, "TABLE", pa, pb, "%s relative widths %% ref %s, gen %s" % (
                    tag, [round(x * 100) for x in pa], [round(x * 100) for x in pb]))
        if a["merged"] != b["merged"]:
            add(out, "TABLE", a["merged"], b["merged"], "%s merged cells ref %s, gen %s" % (tag, a["merged"], b["merged"]))
        if a["header_rows"] != b["header_rows"]:
            add(out, "TABLE", a["header_rows"], b["header_rows"], "%s header rows ref %d, gen %d" % (tag, a["header_rows"], b["header_rows"]))
        ghead = [norm(c) for r in b["head_text"] for c in r]
        miss = [c for r in a["head_text"] for c in r if norm(c) and not any(
            norm(c) == g or ratio(norm(c), g) >= 0.85 for g in ghead)]
        if miss:
            add(out, "TABLE", miss, None, "%s header cells of ref not in gen: %s" % (tag, "; ".join(m[:50] for m in miss[:8])))
    rl, gl = lines_of(ref), lines_of(gen)
    for l in rl:
        if not any(l == g or ratio(l, g) >= 0.85 for g in gl):
            add(out, "TEXT_MISSING", l, None, l[:160])
    for l in gl:
        if not any(l == g or ratio(l, g) >= 0.85 for g in rl):
            add(out, "TEXT_EXTRA", None, l, l[:160])
    return out


# ---------------------------------------------------------------- text check


def text_check(gen, ref_text, marker_from, marker_to):
    if marker_from:
        i = ref_text.find(marker_from)
        if i < 0:
            raise InputError("marker not found: %s" % marker_from)
        ref_text = ref_text[i:]
        if marker_to:
            k = ref_text.find(marker_to, len(marker_from))
            if k >= 0:
                ref_text = ref_text[:k]
    ref_n = norm(ref_text)
    ref_lines = [norm(l) for l in ref_text.splitlines() if len(norm(l)) >= 3]
    cands = [b["text"] for b in gen["blocks"] if b["kind"] == "p" and b["text"] and b["has_nonbold"]]
    cands += [c for t in gen["tables"] for r in t["head_text"][:1] for c in r]
    out = []
    for c in cands:
        n = norm(c)
        if len(n) < 3 or n.isdigit() or n in ref_n:
            continue
        # label: value paragraphs: check the label part before the first colon
        head = norm(c.split(":", 1)[0]) if ":" in c else n
        if len(head) >= 3 and head in ref_n:
            continue
        if any(ratio(n, l) >= 0.85 for l in ref_lines):
            continue
        out.append({"category": "TEXT_NOT_IN_REF", "ref": None, "gen": c, "detail": c[:160]})
    return out


# ---------------------------------------------------------------- cli


def emit(items, as_json):
    if as_json:
        print(json.dumps(items, ensure_ascii=False))
    else:
        for it in items:
            print("%s\t%s" % (it["category"], it["detail"]))


def main(argv):
    ap = argparse.ArgumentParser(prog="forms_compare")
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("summary")
    a.add_argument("file")
    a.add_argument("--json", action="store_true")
    b = sub.add_parser("diff")
    b.add_argument("ref")
    b.add_argument("gen")
    b.add_argument("--json", action="store_true")
    c = sub.add_parser("text")
    c.add_argument("gen")
    c.add_argument("reftxt")
    c.add_argument("--from", dest="mfrom")
    c.add_argument("--to", dest="mto")
    c.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    path = getattr(args, "file", None) or getattr(args, "gen", None)
    try:
        if args.cmd == "summary":
            s = summarize(args.file)
            if args.json:
                print(json.dumps(s, ensure_ascii=False))
            else:
                print("\n".join(text_report(s)))
        elif args.cmd == "diff":
            path = args.ref
            r = summarize(args.ref)
            path = args.gen
            g = summarize(args.gen)
            emit(diff(r, g), args.json)
        else:
            g = summarize(args.gen)
            path = args.reftxt
            try:
                with open(args.reftxt, "rb") as fh:
                    raw = fh.read(MAX_ENTRY + 1)
            except OSError as e:
                raise InputError(str(e.strerror or e))
            if len(raw) > MAX_ENTRY:
                raise InputError("reference text larger than the size cap")
            emit(text_check(g, raw.decode("utf-8", "replace"), args.mfrom, args.mto), args.json)
    except InputError as e:
        sys.stderr.write("forms_compare: error: %s: %s\n" % (path, e))
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
