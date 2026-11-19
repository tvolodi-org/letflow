#!/usr/bin/env python3
"""Makes a synthetic Qoimeks-layout balances workbook of a given size for the size scenarios of UAT
(qoimeks-import-8 and qoimeks-import-9, T-2327). Standard library only; no customer data.

Usage: python3 -B uat_size_workbook.py OUT.xlsx TARGET_BYTES [ROWS]

The first worksheet holds the header row ("Артикул", name, quantity, zone, rack, shelf) and ROWS data rows
(default 2000, at most 10000) with invented article codes ZZSIZE-00001... and the place A-1-1: the check
answers "unknown article" remarks for them and writes nothing, which is fine for a size walk. The file is
brought to TARGET_BYTES (+- 1 percent) with a second worksheet of random text, stored without compression
(the check reads the first worksheet only). The bytes written are printed.
"""
import base64
import os
import sys
import zipfile
from xml.sax.saxutils import escape

HEADER = ["Артикул", "Наименование", "Количество", "Зона", "Стеллаж", "Полка"]


def build(path, target, rows):
    strings = list(HEADER)
    sheet1 = ['<row r="1">' + "".join(
        '<c r="%s1" t="s"><v>%d</v></c>' % ("ABCDEF"[i], i) for i in range(6)) + "</row>"]
    for n in range(1, rows + 1):
        r = n + 1
        code = "ZZSIZE-%05d" % n
        strings.append(code)
        strings.append("Synthetic size item %d" % n)
        a, b = len(strings) - 2, len(strings) - 1
        strings.append("A")
        strings.append("1")
        strings.append("1")
        z, k, s = len(strings) - 3, len(strings) - 2, len(strings) - 1
        sheet1.append(
            '<row r="%d"><c r="A%d" t="s"><v>%d</v></c><c r="B%d" t="s"><v>%d</v></c>'
            '<c r="C%d"><v>%d</v></c><c r="D%d" t="s"><v>%d</v></c><c r="E%d" t="s"><v>%d</v></c>'
            '<c r="F%d" t="s"><v>%d</v></c></row>' % (r, r, a, r, b, r, n % 50 + 1, r, z, r, k, r, s))
    ns = 'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
    rel = 'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"'
    ct = ('<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
          '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
          '<Default Extension="xml" ContentType="application/xml"/>'
          '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
          '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
          '<Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
          '<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>'
          '</Types>')
    rels = ('<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>')
    wb = ('<?xml version="1.0" encoding="UTF-8"?><workbook %s %s><sheets><sheet name="Stock" sheetId="1" r:id="rId1"/>'
          '<sheet name="Filler" sheetId="2" r:id="rId2"/></sheets></workbook>' % (ns, rel))
    wbrels = ('<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
              '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
              '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>'
              '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/></Relationships>')
    sst = ('<?xml version="1.0" encoding="UTF-8"?><sst %s count="%d" uniqueCount="%d">%s</sst>'
           % (ns, len(strings), len(strings), "".join("<si><t>%s</t></si>" % escape(s) for s in strings)))
    s1 = '<?xml version="1.0" encoding="UTF-8"?><worksheet %s><sheetData>%s</sheetData></worksheet>' % (ns, "".join(sheet1))

    def make(filler_bytes):
        text = base64.b64encode(os.urandom(max(filler_bytes, 0) * 3 // 4 + 3)).decode()[: max(filler_bytes, 0)]
        s2 = ('<?xml version="1.0" encoding="UTF-8"?><worksheet %s><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>%s</t></is></c></row>'
              '</sheetData></worksheet>' % (ns, text))
        with zipfile.ZipFile(path, "w", zipfile.ZIP_STORED) as z:
            for name, data in [("[Content_Types].xml", ct), ("_rels/.rels", rels), ("xl/workbook.xml", wb),
                               ("xl/_rels/workbook.xml.rels", wbrels), ("xl/sharedStrings.xml", sst),
                               ("xl/worksheets/sheet1.xml", s1), ("xl/worksheets/sheet2.xml", s2)]:
                z.writestr(name, data)
        return os.path.getsize(path)

    base = make(0)
    size = make(target - base)
    # one correction pass: the zip overhead is constant, so the size is exact after the first pass
    if abs(size - target) > target // 100:
        size = make(target - base - (size - target))
    return size


if __name__ == "__main__":
    out, target = sys.argv[1], int(sys.argv[2])
    nrows = int(sys.argv[3]) if len(sys.argv) > 3 else 2000
    if not 1 <= nrows <= 10000:
        sys.exit("ROWS must be 1..10000")
    print(build(out, target, nrows))
