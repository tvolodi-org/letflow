# Official form templates: fixed legal fields, a tenant's own docx, the first step

Task T-1966 (2026-11-14, design check, docs only, QA only). Nothing is built by this note. The business decision note
for UAT is `docs/uat/ba-decisions/T-1966.md`. Marks: **V** = verified in the file named, on origin/main `cbe12af93`;
**M** = measured in this task (command in the appendix); **G** = guess or proposal; **A** = UAT assumption, to be
confirmed by the process owner.

## Summary in plain words

The owner says the printed official forms do not look like the Ministry's docx templates. That is true and measured:
the Ministry's Z-1, Z-2 and Inv-10 templates are A4 **portrait** pages with wide margins and the header laid out as
several small tables (5 to 8 tables per form); our docx prints are A4 **landscape** with narrow margins and **one**
table, the header as plain lines (M, appendix A). The separate compare task T-1965 lists every difference and queues
the fixes to the platform's own forms. This note answers the second half of the request: **a template editor**.

The answer, in short:

1. **A form has a fixed legal skeleton and a free skin.** The skeleton is what the order prescribes: title, form code
   and annex line, column headings and their order, signature roles, and (for a Kazakh machine-draft text) the draft
   notice. The skin is everything else: page size and orientation, margins, fonts, logo, header text, extra lines,
   column widths, borders. The platform owns the skeleton; a company may change the skin.
2. **The first step is "upload your own Word template per form".** The company downloads a starter docx that the
   platform makes for each form, changes it in Word, and uploads it back. Legal texts are not typed by the company:
   they are **locked placeholders** such as `{{legal.title}}` that the platform fills from its own catalog in ru or kk.
   The upload is refused unless every legal placeholder and every data placeholder of the form is there, in the right
   place and order, and the file is clean (no macros, no embedded objects, no external links, size limits). Versions
   are kept; the company can roll back.
3. **The docx is made from the company's template; the PDF stays the platform's layout in the first step.** Our PDF
   writer embeds a font with every Kazakh letter (DejaVu Sans, V); turning a company's Word file into a PDF needs an
   office converter on the server, a new heavy dependency that parses untrusted files. That is a later, separate
   slice with its own decision and security review.
4. **Open and closed.** Upload, check, versions and rollback are **open base**: a company must be able to print
   correct legal forms in every build. A visual drag-and-drop designer on top of the same storage stays the **closed
   candidate** already listed (candidate 4 of `docs/design/open-core-closed-candidates.md`).
5. **The audit sentence "official forms cannot be changed by a tenant" changes** once the slices land to: "a tenant
   may change the presentation of an official form through its own template; it cannot change or remove the legal
   skeleton." Until then the sentence stays true.
6. **One open conflict:** decision 0068 D2 rejected both a substitution-marker language (its option (b), the "template
   injection" threat T10 of decision 0056) and uploaded files (its option (c)) as templates. Option A below is both: an
   uploaded docx with `{{name}}` markers. This design keeps 0068 for the generic renderer and needs a **new decision
   record** for official forms before any code (slice S0); that record states its difference to both rejected options
   of 0068 D2 and addresses 0056 T10.

## Options table

| # | Option | What the company can change | Legal fields stay fixed by | PDF | Effort (G) | Risk | Chosen |
|---|---|---|---|---|---|---|---|
| A | **Upload own docx per form, legal texts as locked placeholders, checked at upload** | Everything a Word user can change except the legal texts, their order and the signature roles | the upload check (every `legal.*` and data placeholder present, columns in order, nothing unknown) and the platform filling legal texts from its catalog | platform layout (as today) until S6 | M to L over 6 slices | docx parsing of untrusted files (mitigated: allow-list, caps, one parse); Word splits placeholders across runs | **yes: first step** |
| B | Extend the platform's JSON layout with a "skin" block (orientation, margins, font from an allowed set, logo, header lines), edited in a form on the admin screen | only what the skin block lists | the layout file (`priv/print_forms/<form>.json`) is not editable; the skin cannot remove blocks | the same layout gives PDF and docx, fonts and signatures exactly right | M | low; but the company cannot reproduce its own Word layout, which is what the owner asked | no for the first step; **yes as the PDF path** of a later slice (S6 alternative) |
| C | Reuse the Print templates screen (decision 0068 overrides) for official forms | wording, columns, blocks of the generic renderer | nothing: an override can drop or reword a block; the official forms do not read overrides today (V, audit D7) | generic renderer | L (official forms would have to move to the generic renderer) | a company could reword a legal form; contradicts 0068 D6 "no official wording ships before the owner answers" | no |
| D | Visual designer (drag and drop) | layout by mouse | same skeleton check as A | as A | L | big UI; closed candidate 4 | later, closed extra on top of A |
| E | Company uploads a finished docx (no placeholders), Letflow attaches it | nothing is filled | nothing | none | S | the rejected option (c) of 0068 D2: no substitution, no check | no |

## 1. Fixed legal fields versus what a company may adjust

### 1.1 The legal skeleton (platform-owned, never editable by a company)

Taken from the shipped layout files, which already encode the order's arrangement as our own data
(`lib/letflow/documents/form_print.ex` moduledoc, "A form is DATA", V):

| Part of the skeleton | Where it lives today (V) | In a company template it appears as |
|---|---|---|
| Annex reference line ("Приложение 26 к приказу ...") | `text` block with label `<form>.annex` | `{{legal.annex}}` |
| Form code ("Форма З-2" / "Қ-2 нысаны") | `text` block `<form>.form_code` | `{{legal.form_code}}` |
| Title ("Накладная на отпуск запасов на сторону") | `title` block `<form>.title` | `{{legal.title}}` |
| Header field labels (organisation, BIN, number, date, ...) | `field` block `label` | `{{legal.label.<key>}}` next to `{{<key>}}` |
| Column headings, their number and order, the group header | `table` block `columns[].label`, `no` | header row: `{{legal.col.<table>.<n>}}` in cells 1..N, left to right |
| Column numbers row (1, 2, 3 ...) | `table` block, column position or `no` | `{{legal.colno.<table>.<n>}}` |
| Totals label | `table.totals.label` | `{{legal.total.<table>}}` |
| Signature roles and parts (position, signature, name) and the stamp place | `signature` blocks (`key`, `parts`, `stamp`) | `{{legal.sig.<key>}}` with `{{sig.<key>.position}}`, `{{sig.<key>.name}}` per declared part |
| Power of attorney block | `proxy` block | `{{legal.proxy}}` |
| Kazakh machine-draft notice (for labels with `kk_status = machine_draft`) | catalog `draft_notice`, added by `FormPrint` as the last kk line (V) | not a placeholder: the filler appends it after the template body; it cannot be removed |

The platform fills every `legal.*` placeholder from `priv/print_forms/messages.json` for the language of the print
(ru or kk). So **one company template serves both languages**; the company never types a legal word. A company may
add its own text anywhere (it prints as typed, in both languages; its correctness is the company's responsibility, A).

### 1.2 The skin (company-owned)

Page size and orientation, margins, header and footer, fonts and sizes, bold and italics, borders and shading, column
widths and row heights, the logo (its own image in the file, or `{{tenant.logo}}`, which the platform fills from the
company logo of REQ-590, `lib/letflow/identity/tenant_logo.ex`, V), header text lines, extra free lines (for example
"Утверждаю" with a director's name typed by the company), the position of every block on the page.

### 1.3 What the check refuses (the "legal-fields check")

The upload is accepted only when all of these hold, for the form named:

1. Every `legal.*` placeholder of the form occurs **exactly once** (`legal.col.*` once per header row of its table).
2. Every data placeholder of the form (appendix B) occurs at least once. A field the company does not want filled
   cannot be dropped: the order prescribes it (A: "blank is allowed, missing is not").
3. No unknown placeholder (a name outside appendix B or the `legal.*`, `sig.*`, `tenant.logo` sets). This is the
   field-authorisation boundary: a template can show only the data map the form mapper already builds (as 0068 D5
   does for overrides).
4. For each table of the form: exactly one header row holds `legal.col.<table>.1 .. N` in ascending order, one cell
   each, and exactly one **repeat row** holds the line placeholders `{{<table>.<column key>}}` in the same cell
   positions. The repeat row is copied once per line at print.
5. Every signature role of the form has its `legal.sig.<key>` and one placeholder per declared part.
6. The package passes the sanitizer (section 4.4).

Every refusal names a rule code and a place (paragraph or table cell index), never document data.

## 2. Relation to Print templates (decision 0068) and to the closed designer (D-126)

* **Print templates stays what it is.** Decision 0068 governs overrides of the generic document renderer
  (`lib/letflow/documents/override_render.ex`, `print_overrides.ex`, screen `web/src/pages/admin/PrintTemplatesPage.tsx`,
  permission `DocumentPrintTemplatesManage`, V). The stock and asset official forms are built by
  `Letflow.Documents.FormPrint` from `priv/print_forms/*.json` and never read an override (V, audit D7). Nothing in
  this design changes 0068 for the generic renderer.
* **Official form templates are a new, separate kind**, shown as a second section "Official forms" under the same
  admin menu entry (G: one place for "how our papers look"), with its own permission (section 4.6).
* **Conflict to settle first.** 0068 D2 ("Reasons", V) rejected two options, and option A of this design is both of them:
  an uploaded docx (option (c)) filled through `{{name}}` substitution markers (option (b)).
  - **Rejected (b)**, quoted: "a substitution-marker language is an expression surface, the 'template injection' threat
    0056 T10 names; it needs its own escaping and sandbox and gives no static proof that only projected fields are
    used." (0056 T10, `docs/migration/decisions/0056-versioned-documents.md`, threat list: "Template injection: module
    template output from untrusted field values (PDF text only; no active content).") Answer, reason by reason:
    1. *Expression surface:* the markers are bare names only, with no expressions, filters, conditions or loops
       (section 4.2); the one repetition is the table repeat row, fixed by rule 4 of section 1.3, not by template
       syntax. Nothing in a marker is evaluated.
    2. *Own escaping and sandbox:* no new escaping is invented; every value goes in as a plain text run through the
       existing `Docx.escape/1` and `FormPrint.clean/1` rules (section 4.2), the same path the platform docx uses
       today, so a field value cannot open a new XML element, field code or relationship. No sandbox is needed
       because nothing runs.
    3. *No static proof that only projected fields are used:* the proof is the upload check, rule 3 of section 1.3:
       a template holding any name outside the form's closed key list (appendix B plus the `legal.*`, `sig.*`,
       `tenant.logo` sets) is refused before it is stored, and the key list is the data map the form mapper already
       builds.
  - **Rejected (c)**, quoted: "an uploaded file is an opaque artefact that may carry active content (PDF JavaScript,
    macros), needs a scanner, cannot be checked against the projection, and is a finished form with no field
    substitution rather than a template." Answer: active content and the scanner are the sanitizer, which re-writes
    the package from an allow-list of parts (section 4.4); the projection check is rules 1 to 5 of section 1.3; the
    markers are the field substitution.
  - These answers make the choice defensible, but it is still a different choice for a different object, so it goes
    into a **new decision record** (slice S0), scoped to official forms, with SECURITY-REVIEWER sign-off. That record
    states its difference to **both** rejected options of 0068 D2 and addresses 0056 T10. 0068 is not edited; 0068 is
    itself still PROPOSED (its status line, V).
* **Open base versus closed extra.** The closed-candidate list (`docs/design/open-core-closed-candidates.md`, row 4,
  V) names a "Print template designer: a visual designer ... on top of today's layout format", where the open build
  keeps "per-tenant print-template overrides ... the JSON layout editor with live preview". Applied to official forms:
  - open base: the starter docx, upload, legal-fields check, sanitizer, versions, rollback, the docx print from the
    company template, the structure report (sections 4 and 5);
  - closed extra (candidate 4, unchanged in spirit): a visual designer that edits the company template in the browser
    and saves through the same open upload route and the same check.
  Reason: a company that cannot make its legal forms correct without paying is a defect, not an upsell; a convenience
  designer is. The portfolio record D-126 itself was not opened (not reachable from the worktree); this follows the
  candidate list's own wording.

## 3. The audit statement (official-forms-audit D7)

Today (V, `docs/status/official-forms-audit.md` D7 and summary): "The Print templates screen does not change any of
these forms ... A tenant cannot adjust an official form today." That stays **true until slice S3 (print integration) merges**, the first change after which an uploaded template reaches a print. The slice
that ships the screen (S5) appends to the audit file:

> Since S5 (task id): a tenant may replace the presentation of an official form with its own docx template (permission
> `OfficialFormTemplatesManage`). The legal skeleton (title, form code, annex line, column headings and order,
> signature roles, the kk draft notice) cannot be changed or removed: it is filled by the platform from its catalog and
> the upload is refused without it. The PDF still prints the platform layout until S6.

The Print templates part of D7 (overrides do not reach module prints) stays true.

## 4. First step: upload your own docx per form

### 4.1 The flow for a company administrator

1. Admin, Print templates, section "Official forms": a list of the forms the company's modules print (from
   `FormPrint.forms/0`, V: `da1, da3, da4, inv10, inv18, z1, z2, z3, z5, z6`), each with its state: "standard" or
   "own template vN".
2. "Download starter" gives a docx made by the platform: today's layout (`FormPrint.Docx`, V) with placeholders in
   place of values and legal texts. A company may also start from the Ministry's own docx and add placeholders.
3. The admin edits in Word and uploads. The answer is either "accepted as draft vN" with a structure report, or a list
   of refusals (rule code, place, plain-language hint, for example "column 5 of the lines table is missing").
4. "Preview" downloads the draft filled with a **synthetic sample** (fixed fake data per form, no company data),
   ru or kk. There is no in-browser docx rendering in the first step (it needs the converter of S6).
5. "Activate" makes the draft the one used for prints; a reason is required (A). "Roll back" activates an earlier
   version again (section 4.5).

### 4.2 Placeholder syntax (one implementation)

`{{name}}`: lower-case letters, digits, `_` and `.`; `<table>` in `legal.col.<table>.<n>`, `legal.colno.*` and
`legal.total.*` is the table's position in the layout file (1, 2, 3); line placeholders are `{{<rows>.<key>}}` with the
column key, which is unique within each form (appendix B). No spaces, no expressions, no filters, no conditions. Values are
inserted as text runs with XML escaping (the existing `Docx.escape/1` rule) and the existing `FormPrint.clean/1` rule
(XML-illegal characters dropped, line breaks to spaces, 500 characters cap, V). A missing value prints as the blank
line `____________` (`FormPrint.Pdf.blank/0`, V), as today. The repeat row of a table is the row whose cells hold
`{{<table>.<key>}}` placeholders. Word often splits typed text across several runs; the sanitizer joins the runs of a
paragraph whose joined text contains a placeholder (the first run's formatting is kept) and stores the joined form.

### 4.3 The data model each form exposes

The placeholder names are the keys of the data map the pure form mappers already build for `FormPrint.build/5`
(`lib/letflow/modules/stock/form_z*.ex`, `form_count_inv*.ex`, `lib/letflow/modules/assets/form_da*.ex`, V), read from
the layout files: appendix B lists them per form (M). A new form (DA-2, Z-7, not built yet) brings its list with its
layout file. A template refers to keys only; it never widens the map.

### 4.4 File safety (the sanitizer)

One parse, and the render reads only the verified bytes (skill rule after T-1122): the sanitizer writes a **new**
package from the allowed parts and that package is what is stored and later filled.

| Rule | Value | Source |
|---|---|---|
| Upload size (compressed) | at most 1 MiB | A (the three Ministry templates measured are 157 to 164 KB uncompressed, M) |
| Uncompressed total; entries; ratio per entry | at most 10 MiB; at most 200 entries; at most 100:1 | A (zip-bomb caps) |
| Content type | `application/vnd.openxmlformats-officedocument.wordprocessingml.document` only; `.docm`, `.dotm`, `.doc`, `.rtf` refused | A |
| Parts kept | `[Content_Types].xml`, `_rels/.rels`, `word/document.xml`, `word/styles.xml`, `word/settings.xml`, `word/fontTable.xml`, `word/numbering.xml`, `word/theme/theme1.xml`, `word/header*.xml`, `word/footer*.xml`, their `_rels`, `word/media/*.png|jpg|jpeg` | A (the Ministry templates hold 19 parts and no risky part, M) |
| Parts refused (upload refused, not silently dropped) | `vbaProject.bin`, `activeX/*`, `embeddings/*`, `oleObject*`, any `.bin`, `customXml/*`, `altChunk`, `attachedTemplate` | A |
| Relationships | any `TargetMode="External"` refused (links, remote images, remote templates) | A |
| Field codes | every `w:fldSimple` / `w:instrText` refused except `PAGE` and `NUMPAGES` | A |
| Images | PNG or JPEG by magic bytes, each at most 524 288 bytes | the same cap as the company logo (`TenantLogo.max_bytes/0`, V) |
| Embedded fonts (`w:embedTrueTypeFonts`, `word/fonts/*`) | refused in the first step | A (font files are parsed by readers; not needed for TNR) |
| Malware scan | the attachment scanner seam `TenantLogo.validate/2` already calls (V); a scanner error refuses | V |
| docProps | dropped and not re-written (author names, as `FormPrint.Docx` writes none, V) | V |

### 4.5 Storage, versions, rollback, printing

* One tenant-schema table (name chosen by S4; proposal `official_form_templates`): form id, locale (`default`, `ru`,
  `kk`; `default` serves both, a language row wins), version_no (monotone per form and locale), status
  (`draft | active | retired`), the sanitized bytes, sha256, structure report, created_by, activated_by, reason,
  timestamps. At most one active row per (form, locale). A row's bytes never change; no DELETE (as 0068 D3). Every
  access path takes the tenant `:prefix` (INV-1), the tenant never comes from the request (INV-10).
* **Rollback** writes a new version row whose bytes are a copy of the chosen earlier version (same sha256,
  `rollback_of` set) and activates it; history stays monotone.
* **Printing:** official forms are rendered on demand from the issued document (the stock router calls
  `FormPrint.build/4` (the default-opts form of `build/5`) per request, V, `lib/letflow/modules/stock/router.ex`), not stored. So a print uses the template
  active **at print time**, as a release changes the layout today. The activation audit trail shows which version was
  active when.
* **Invalid at print** (a later release added a placeholder the form needs): fail closed with a plain message
  "your template for this form is out of date; upload a new version or switch back to standard" (as 0068 D3 fails
  closed); never a silent fallback to the standard form (A).
* Audit events in the same transaction: template uploaded, activated, retired, rolled back (form, locale, version,
  sha256, actor, reason; never the bytes or text).

### 4.6 Permission

One new tenant-scope atom, proposal `OfficialFormTemplatesManage` (does not exist in code; S4 chooses the final name).
Through the two computed catch-alls in `lib/letflow/api/authorization.ex` (V): `core_role_allows?(:TENANT_ADMIN,
permission), do: permission_scope(permission) == :tenant` grants it to TENANT_ADMIN, and `core_role_allows?(:PLATFORM_ADMIN,
_permission), do: true` grants it to PLATFORM_ADMIN. No other ready-made role holds it; a company-defined role may be
given it under decision 0088. Not `DocumentPrintTemplatesManage`: that atom changes generic prints; separating them lets
a company give one without the other. Printing a form keeps the module's own read permission (for example `AssetsRead`
on the asset print route, V audit section 2).

### 4.7 Languages

ru and kk only; English is refused as today (`{:error, :lang_not_supported}`, V `FormPrint` moduledoc). Legal texts
come from the catalog per language; free text typed by the company prints as typed in both.

### 4.8 PDF: decided

| Path | Kazakh letters | Signature blocks | New dependency | Decision |
|---|---|---|---|---|
| PDF from the platform layout JSON (`FormPrint.Pdf` over `PrintLayout`, DejaVu Sans embedded, V) | right: the font has the letters and is embedded (V, `print_layout.ex` moduledoc) | right: built from the `signature` blocks | none | **first step: PDF always from this path**, also when a company template is active |
| PDF converted from the filled company docx (office converter on the server) | depends on fonts installed on the server; the runtime image has none beyond the base (`deploy/Dockerfile` installs `libstdc++6 openssl libncurses6 locales ca-certificates`, V) | as laid out in Word | yes: a large office suite parsing untrusted files | later slice S6, own decision record and security review, owner's call (it changes the runtime image) |

So in the first step the docx follows the company's template and the PDF follows the standard layout. The screen says
so next to the PDF button of a form with an own template (A: "PDF: standard layout"). The docx relies on the reader's
fonts; the starter uses Times New Roman, which the Ministry templates use too (M).

## 5. How a generated form is checked against the reference structure

* The compare tool of task T-1965, `scripts/forms_compare.py` (planned, not yet on main; T-1965 is in its design step),
  extracts a structure summary from a docx (sections, page setup, fonts, tables with grid widths, paragraphs) and diffs
  two of them.
* Reuse: (1) at upload, the structure report shown to the admin is the same summary, computed in Elixir by the
  sanitizer from the same parse (the Python tool cannot run inside the release); (2) in the repository, a test per form
  fills the **starter** template with the synthetic sample and compares its summary with a checked-in **reference
  summary** (our own derived numbers: page size, orientation, column count and order, signature roles; never the
  Ministry file itself); (3) for QA, the operator runs `forms_compare.py` on a filled company template against the
  Ministry file when a company asks "is my form right".
* What the comparison may fail on: skeleton facts only (column count and order, legal texts, signature roles). Skin
  facts (margins, fonts) are reported, not failed, because the company owns them.

## 6. Slices

Each is one change; SECURITY-REVIEWER on S0, S1, S3, S4 (untrusted file input, tenant data, a new permission and route).

| # | Slice | Contents | Effort (G) | After |
|---|---|---|---|---|
| S0 | Decision record | official-form templates: skeleton and skin, locked placeholders, sanitizer rules, storage, PDF stays platform; amends nothing in 0068, states the difference to both rejected options (b) and (c) of 0068 D2 and addresses 0056 T10 (template injection) | S | none |
| S1 | Sanitizer and legal-fields check (pure) | parse once, allow-list, caps, run joining, placeholder scan, rules 1.3, structure summary; tests on synthetic docx (macro part, external link, split placeholder, missing column, unknown name, zip bomb) | M | S0 |
| S2 | Starter templates and filler (pure) | starter docx per form from the layout; fill = legal texts from the catalog, values, repeat rows, totals, kk draft notice appended | M | S1 |
| S3 | Print integration | `FormPrint.build` uses the active company template for docx when present, fails closed when invalid; PDF unchanged | S | S2, S4 |
| S4 | Storage, routes, permission, audit | table and migration, upload / list / download / preview / activate / retire / rollback routes, `OfficialFormTemplatesManage`, cross-tenant negative test (INV-10, INV-5), route pins | M to L | S1 |
| S5 | Web section "Official forms" | list, starter download, upload with refusal list, preview, activate with reason, rollback, version history; ru/kk/en screen texts; screenshot matrix; audit D7 line (section 3) | M | S4 |
| S6 | PDF from the company template | owner decision on a converter in the runtime image, sandboxing, fonts; or option B (skin block) instead | L | owner |
| S7 | Reference-summary guard | checked-in reference summaries per form, test comparing the filled starter (section 5) | S | S2, T-1965 |

The platform's own layout fixes from the T-1965 difference table (portrait pages, header grids, margins) are queued from
that table, not here; they improve the starter templates of S2 for free.

## 7. Risks

* Word-produced XML varies (runs, bookmarks, proofing marks, tracked changes); the run joining and the check must be
  tested on files saved by Word and LibreOffice (G: the largest effort item of S1). Tracked changes (`w:ins`, `w:del`)
  are refused in the first step (A).
* A company template that looks fine but puts a column placeholder in the wrong visual place: the check proves order and
  presence, not visual correctness; the preview and the structure report are the company's look.
* docx and PDF of the same form differ while S6 is not built.
* A release that adds a placeholder makes active company templates fail closed (section 4.5); the release note and the
  screen must say so.
* Kazakh legal texts that are still machine drafts (`kk_status`) stay drafts in a company template too.

## 8. Not covered

* Changing legal wording, column sets or signature roles (only by a platform release, after an accountant confirms).
* The generic renderer and its overrides (0068), the plain machine-draft acts (`document_print.ex`), xlsx paperwork.
* PDF from a company template (S6), in-browser docx preview, a visual designer (closed candidate).
* Forms not built yet (DA-2, Z-7): they join when their layout file lands.
* Production: QA only; the process owner configures production.

## Appendix A. Measurements (M)

Command (read only, script kept in the task folder `state/tasks/T-1966/peek.py`, standard library `zipfile` and `re`):
`python3 -I peek.py <Ministry ru25, ru26, ru41> <state/form-samples Z-1_ru, Z-2_ru, Inv-10_ru>.docx`. Output:

| File | Page (twips) | Margins top/right/bottom/left | Tables (grid columns) | Fonts in styles | Parts; risky parts; external links |
|---|---|---|---|---|---|
| Ministry annex 25 (Z-1) | 11906 x 16838, portrait | 1418/851/1418/1418 | 5 (1, 3, 1, 7, 11) | Calibri, Segoe UI, Times New Roman | 19; none; 0 |
| Letflow Z-1 ru | 16838 x 11906, landscape | 720/720/720/720 | 1 (11) | Times New Roman | 5; none; 0 |
| Ministry annex 26 (Z-2) | 11906 x 16838, portrait | 1134/850/1134/1276 | 8 (1, 2, 3, 1, 2, 5, 9, 4) | Calibri, Segoe UI, Times New Roman | 19; none; 0 |
| Letflow Z-2 ru | 16838 x 11906, landscape | 720/720/720/720 | 1 (9) | Times New Roman | 5; none; 0 |
| Ministry annex 41 (Inv-10) | 11906 x 16838, portrait | 1418/851/1418/1418 | 5 (1, 5, 1, 2, 10) | Calibri, Segoe UI, Times New Roman | 19; none; 0 |
| Letflow Inv-10 ru | 16838 x 11906, landscape | 720/720/720/720 | 1 (10) | Times New Roman | 5; none; 0 |

Uncompressed sizes: Ministry 156 821, 163 628, 160 377 bytes; Letflow 12 671, 12 539, 17 095 bytes. The Ministry
files were read in place and are not copied into the repository.

## Appendix B. Placeholder names per form (M)

Read from `priv/print_forms/<form>.json` (blocks `field` key, `signature` key and parts, `table` rows and column keys).
Each data field is `{{key}}`; each table column `{{<rows>.<key>}}`; each signature part `{{sig.<key>.<part>}}`.

| Form (annex) | Fields | Tables: rows -> columns | Signatures (parts: p = position, s = signature line, n = name) |
|---|---|---|---|
| z1 (25) | org_name, warehouse, org_bin, number, date, operation, supplier, account, accomp_doc, payment_doc | lines -> name, nom, unit, qty_doc, mass_doc, qty, mass, price, sum, passport, card_no | accepted_by (s, n), handed_by (s, n) |
| z2 (26) | org_name, org_bin, number, date, sender, receiver, responsible, transport, ttn, words_qty, words_sum | lines -> no, name, nom, unit, qty_plan, qty_issued, price, sum_vat, vat | allowed_by (p, s, n), chief_acc (s, n), released (s, n), received (s, n) |
| z3 (27) | org_name, org_bin, struct_unit, prod_kind, mark, sort, profile, size, account, nom, unit, price, shelf, responsible, shop, executor, item_name, precious | rows -> date, doc_number, no, party, unit_out, income, expense, balance, control | none |
| z5 (29) | org_name, org_bin, number, date, sender_unit, receiver_unit, basis, responsible, words_qty, words_sum | lines -> no, name, nom, unit, qty_plan, qty_issued, price, sum | allowed_by, checked_by, released, received (all p, s, n) |
| z6 (30) | org_name, org_bin, number, date, unit, basis, responsible, guilty_qty, guilty_damage, guilty_shortage, org_sum, org_damage, org_shortage, decision, scrap_sum | lines -> no, name, nom, acquired, life, unit, qty, price, sum, reason; scrap -> s_no, s_name, s_nom, s_unit, s_qty, s_price, s_sum, s_order | approver (s, n), chair, member1, member2, mol (p, s, n) |
| inv10 (41) | org_name, org_bin, number, date, stock_kind, order_date, order_no, account, cut_off, started, ended, total_nos, total_nos_words, total_qty, total_qty_words, total_sum, total_sum_words, resp_date | lines -> no, name, acct, nom, unit, price, qty_fact, sum_fact, qty_book, sum_book | resp1, resp2, chair, member1, member2, resp_end (all p, s, n) |
| inv18 (49) | org_name, org_bin, number, date, count_date, order | lines -> no, name, nom, unit, surplus_qty, surplus_sum, shortage_qty, shortage_sum, adj_surplus_qty, adj_surplus_sum, adj_surplus_acct, adj_shortage_qty, adj_shortage_sum, adj_shortage_acct; regrade -> r15 .. r26 | responsible (p, s, n), accountant (s, n), mol (p, s, n) |
| da1 (16) | org_bin, sender_name, receiver_name, location, basis, brief, precious, conform, rework, tests, conclusion, docs | lines -> b_name, b_no, b_date, mol, name, acquired, cost; and a second lines table -> depr_life, depr, book, inv, factory, debit, credit, passport, sale | approver_sender, approver_receiver, chair, member1, member2, handed, accepted, custody (p, s, n); acc_out, acc_open (s, n) |
| da3 (18) | org_name, org_bin, number, date, reason, state, conclusion, docs, income | lines -> no, name, released, acquired, life, cost, depr, book, factory, inv; accessories -> a_name, a_qty, a_metal, a_nom, a_unit, a_mass; costs -> e_work, e_doc, e_item, e_sum, i_doc, i_name, i_nom, i_qty, i_sum | approver (s, n), chair, member1, member2, mol (p, s, n), chief_acc (s, n) |
| da4 (19) | org_name, org_bin, sender_unit, receiver_unit, responsible, basis, number, date, words_qty, words_sum, note | lines -> no, name, acquired, inv, factory, passport, unit, qty, price, cost | handed, accepted (p, s, n), chief_acc (s, n) |

DA-1 has two tables over the same `lines` rows (two halves of one line). Their column keys differ, so `{{lines.<key>}}`
stays unique; each of the two tables has its own repeat row and its own `legal.col.1.*` / `legal.col.2.*` header row.
