# 0089 -- Official form templates: a company's own docx per official form, with locked legal placeholders, a closed key list and a re-writing sanitizer

Status: PROPOSED (T-1980, 2026-11-14; slice S0 of `docs/design/form-template-editor.md`, section 6). QA only; production
is not approved by this record. Changes no code, no migration, no permission and no screen: slices S1 to S5 of the design
are each their own change with their own review.
**SECURITY-REVIEWER sign-off:** required before slice S1 merges; given or refused by the T-1980 gate (its verdict is in the
Gates block of the merged PR). The threat list is at the end of this record.
**REVIEWER sign-off:** pending (the T-1980 gate).
The number 0089 was the next free one on origin/main `dc03badc8` at T-1980 (0088 is the highest; no open team branch or
sibling worktree adds a decision record: `git diff --name-only --diff-filter=A origin/main...<branch> -- docs/migration/decisions/`
over every `origin/team/*` branch printed nothing).

Scope: the official forms printed by `Letflow.Documents.FormPrint` from `priv/print_forms/<form>.json` (today
`FormPrint.forms/0` = `da1, da3, da4, inv10, inv18, z1, z2, z3, z5, z6`). The generic document renderer and its
overrides stay governed by [0068](0068-per-tenant-print-template-overrides.md); **this record amends no sentence of 0068
and none of [0056](0056-versioned-documents.md).**

## Sources

Opened for this record (V = read on origin/main `dc03badc8`):

- `docs/design/form-template-editor.md` (T-1966), whole file, V: option A, sections 1.1 to 1.3, 2, 3, 4.1 to 4.8, 6, 7,
  appendix B.
- `docs/uat/ba-decisions/T-1966.md`, V.
- [0068](0068-per-tenant-print-template-overrides.md) D1, D2 (decision and "Reasons"), D3, D5, D6, D7, V. 0068 is itself
  PROPOSED (its status line).
- [0056](0056-versioned-documents.md) D5 "Rendering and templates (DIRECTION, non-binding)" and the threat list (T10), V.
- `docs/status/official-forms-audit.md` summary and row D7, V.
- Code, V: `lib/letflow/documents/form_print.ex` (`forms/0`, `clean/1`), `lib/letflow/documents/form_print/docx.ex`
  (`escape/1`; moduledoc "There is no `docProps`"), `lib/letflow/documents/form_print/pdf.ex` (`blank/0`),
  `lib/letflow/identity/tenant_logo.ex` (`max_bytes/0`, `validate/2` and its scanner seam), `lib/letflow/api/authorization.ex`
  (`core_role_allows?/2`: the `:PLATFORM_ADMIN, _permission` catch-all and the `:TENANT_ADMIN, permission` clause
  `permission_scope(permission) == :tenant`), `lib/letflow/modules/stock/router.ex` (`FormPrint.build/4` per request).

## Decisions

### D1. Skeleton and skin

**Decision.** Each official form has a **legal skeleton** owned by the platform and a **skin** owned by the company.

- Skeleton (never editable by a company): annex reference line, form code, title, header field labels, column headings
  with their number and order and the group header, the column numbers row, the totals label, signature roles and their
  parts and the stamp place, the power-of-attorney block, and the Kazakh machine-draft notice. These are the blocks the
  layout files already hold (design section 1.1).
- Skin (the company's): page size and orientation, margins, header and footer, fonts and sizes, emphasis, borders and
  shading, column widths, row heights, logo, extra free text lines, and where each block sits on the page (design 1.2).

The texts of the skeleton come only from the platform's catalog `priv/print_forms/messages.json` in the print language
(ru or kk); a company never types a legal word. Free text typed by the company prints as typed, in both languages; its
correctness is the company's responsibility (UAT assumption, to be confirmed by the process owner).

**Reasons.** The owner wants the printed forms to follow the company's Word layout; the order prescribes the wording, the
columns and the signatures, not the margins. Keeping the wording in one reviewed catalog is the rule the mapping already
follows (design section 1.1).

### D2. Template form: a docx with locked placeholders (bare names only)

**Decision.** A company template is a `.docx` (WordprocessingML) package per form and locale, holding placeholders
`{{name}}`. A name is lower-case letters, digits, `_` and `.`; no spaces, no expressions, no filters, no conditions, no
loops, no includes, nothing evaluated. Three name sets exist, and the union is the form's **closed key list**:

1. `legal.*` (locked): `legal.annex`, `legal.form_code`, `legal.title`, `legal.label.<key>`, `legal.col.<table>.<n>`,
   `legal.colno.<table>.<n>`, `legal.total.<table>`, `legal.sig.<key>`, `legal.proxy`. The platform fills each from the
   catalog for the print language.
2. Data names: the keys of the data map the form mapper already builds for `FormPrint.build/5`, listed per form in
   appendix B of the design (`<key>`, `<rows>.<column key>`, `sig.<key>.<part>`).
3. `tenant.logo`: the company logo already stored by `Letflow.Identity.TenantLogo`.

The only repetition is the table **repeat row**: the one row whose cells hold `{{<rows>.<key>}}` names is copied once per
line. That is a fixed structural rule (design 1.3 rule 4), not template syntax. The kk draft notice is not a placeholder:
the filler appends it after the template body and the template cannot remove it.

Filling: every value (catalog text, data value, company name) goes in as a plain text run through the existing
`FormPrint.clean/1` (invalid UTF-8 refused as empty, XML-illegal characters dropped, line breaks and tabs to spaces,
length cap) and then `FormPrint.Docx.escape/1` (`& < > " '`). A missing value prints as `FormPrint.Pdf.blank/0`. A value
never becomes a new XML element, attribute, field code, relationship or part.

### D3. The upload check (the legal-fields check)

**Decision.** An upload is stored only when all of these hold for the named form (design 1.3), checked on the sanitized
package of D4:

1. every `legal.*` name occurs exactly once (`legal.col.*` once per header row of its table);
2. every data name occurs at least once ("blank is allowed, missing is not": UAT assumption, to be confirmed by the
   process owner);
3. no name outside the closed key list;
4. per table: exactly one header row with `legal.col.<table>.1 .. N` in ascending cell order, one per cell, and exactly
   one repeat row with the line names in the same cell positions;
5. every signature role has its `legal.sig.<key>` and one name per declared part;
6. the package passed the sanitizer (D4).

A refusal names a rule code and a place (paragraph or table-cell index), never document or company data. The check
proves presence and order, not visual placement; the preview (synthetic sample data only) and the structure report are
the company's look at the result.

### D4. Sanitizer: one parse, a re-written package, allow-list only

**Decision.** The upload is parsed once; the sanitizer writes a **new** package from allowed parts only, and those
verified bytes are what the check of D3 reads, what is stored and what the filler later fills (the consumer never
re-parses the original upload). Rules (values from design 4.4; each marked A is a UAT assumption, to be confirmed by the
process owner, and S1 may only tighten it):

| Rule | Value |
|---|---|
| Upload size, compressed | at most 1 MiB (A) |
| Uncompressed total; entries; ratio per entry | at most 10 MiB; at most 200 entries; at most 100:1 (A) |
| Content type | WordprocessingML document only; `.docm`, `.dotm`, `.doc`, `.rtf` refused (A) |
| Parts kept | `[Content_Types].xml`, `_rels/.rels`, `word/document.xml`, `word/styles.xml`, `word/settings.xml`, `word/fontTable.xml`, `word/numbering.xml`, `word/theme/theme1.xml`, `word/header*.xml`, `word/footer*.xml`, their `_rels`, `word/media/*.png|jpg|jpeg` (A) |
| Parts that refuse the upload (never silently dropped) | `vbaProject.bin`, `activeX/*`, `embeddings/*`, `oleObject*`, any `.bin`, `customXml/*`, `altChunk`, `attachedTemplate`, embedded fonts (`w:embedTrueTypeFonts`, `word/fonts/*`) (A) |
| Relationships | any `TargetMode="External"` refuses (links, remote images, remote templates) (A) |
| Field codes | every `w:fldSimple` / `w:instrText` refuses except `PAGE` and `NUMPAGES` (A) |
| Tracked changes | `w:ins`, `w:del` refuse (A; design section 7) |
| XML declarations | a `<!DOCTYPE` or entity declaration in any part refuses (A, added by this record: no DTD, no entity expansion, so no external-entity read and no entity bomb) |
| Content controls bound to data | `w:dataBinding` refuses (A, added by this record: it reads `customXml`, which is refused) |
| Images | PNG or JPEG by magic bytes, each at most `TenantLogo.max_bytes/0` (524 288 bytes) |
| Malware scan | the attachment scanner seam that `TenantLogo.validate/2` calls; a scanner error or exception refuses |
| docProps | dropped, not re-written (as `FormPrint.Docx` writes none) |
| Split placeholders | the runs of a paragraph whose joined text holds a placeholder are joined (first run's formatting kept) and the joined form is stored |

### D5. Storage, versions, rollback, printing

**Decision.**

- One tenant-schema table (final name by S4; proposal `official_form_templates`): form id, locale (`default`, `ru`, `kk`;
  a language row wins over `default`), `version_no` monotone per (form, locale), status `draft | active | retired`, the
  sanitized bytes, their sha256, the structure report, `created_by`, `activated_by`, reason, timestamps. At most one
  `active` row per (form, locale). A row's bytes never change; there is no DELETE (as 0068 D3). Every access path takes
  the tenant `:prefix` (INV-1); the tenant comes from the auth context only, never from path, query or body (INV-10).
- Activation requires a reason (UAT assumption, to be confirmed by the process owner). **Rollback** writes a new version
  whose bytes copy the chosen earlier version (same sha256, `rollback_of` set) and activates it.
- Official forms are rendered on demand from the issued document (`FormPrint.build/4` per request in the stock router), not
  stored; a print uses the template active **at print time**. The activation audit trail shows which version was active
  when. (This differs from 0068 D4, which pins an override to an issued 0056 document version; FormPrint forms are not
  0056 artefacts and have no stored bytes to pin.)
- A template that no longer passes D3 at print (a later release added a name the form needs) **fails closed** with a plain
  message; never a silent fallback to the standard form (as 0068 D3).
- Audit events in the same transaction: template uploaded, activated, retired, rolled back, with form, locale, version,
  sha256, actor, reason; never the bytes or any text of the template.
- Permission: one new tenant-scope atom, proposal `OfficialFormTemplatesManage` (does not exist in code; S4 chooses the
  final name). Through `core_role_allows?/2` in `lib/letflow/api/authorization.ex` it is held by TENANT_ADMIN (the
  `permission_scope(permission) == :tenant` clause) and by PLATFORM_ADMIN (the `_permission` catch-all, which applies to every
  atom without an explicit `false` clause above it); not granted to any other ready-made role; a company-defined role may
  be given it under [0088](0088-permission-only-access-tenant-defined-roles.md). It is distinct from 0068's
  `DocumentPrintTemplatesManage`. Printing keeps the module's own read permission.

### D6. PDF stays the platform layout

**Decision.** The docx print follows the active company template; the PDF print keeps the platform layout
(`FormPrint.Pdf`, DejaVu Sans embedded) also when a company template is active. A PDF made from the company's docx needs an
office converter in the runtime image that parses untrusted files: that is slice S6, with its own decision record, its own
security review and the owner's call. The screen says "PDF: standard layout" next to such a form (UAT assumption).

### D7. Difference to the options 0068 D2 rejected

0068 D2 listed (a) a closed declarative layout, (b) a template language with substitution markers, (c) an uploaded file,
and chose (a) for the **generic renderer**. Option A of the design looks like (b) and (c) at once. It is neither, for an
object 0068 does not govern:

**Against (b)**, 0068 D2 Reasons: "a substitution-marker language is an expression surface, the 'template injection' threat
0056 T10 names; it needs its own escaping and sandbox and gives no static proof that only projected fields are used."

1. *Expression surface.* There is no language: a placeholder is a bare name matched against a closed list (D2). Nothing in a
   marker is parsed as an expression or evaluated; the one repetition is a structural rule (D3 rule 4).
2. *Own escaping and sandbox.* No new escaping: values go through the existing `FormPrint.clean/1` and `Docx.escape/1`,
   the same path today's platform docx uses (D2). No sandbox is needed because no template code runs.
3. *No static proof of projected fields.* The proof is D3 rule 3: a template naming anything outside the form's closed key
   list (the mapper's data map plus `legal.*`, `sig.*`, `tenant.logo`) is refused before it is stored, and again at print
   (D5 fail closed). The key list is the same boundary 0068 D5 sets for overrides: a template can show only what the form
   mapper already gives.

**Against (c)**, 0068 D2 Reasons: "an uploaded file is an opaque artefact that may carry active content (PDF JavaScript,
macros), needs a scanner, cannot be checked against the projection, and is a finished form with no field substitution
rather than a template."

1. *Opaque, active content.* The upload is not kept as uploaded: the sanitizer re-writes it from an allow-list of parts and
   refuses macros, ActiveX, OLE, embedded objects, external relationships, field codes other than page numbers, DTDs and
   data bindings (D4). Only the re-written bytes are stored and filled.
2. *Needs a scanner.* It has one: the existing attachment scanner seam, failing closed (D4).
3. *Cannot be checked against the projection.* It is checked: D3 rules 1 to 5.
4. *Finished form, no substitution.* The placeholders are the substitution; a finished docx without them fails D3 rules 1
   and 2. (The design's option E, a finished docx attached as is, stays rejected for the reason 0068 gave.)

**Why a separate record and not an amendment of 0068.** The object differs: 0068 governs presentation overrides of
generic 0056 documents, pinned to an issued version; this record governs the docx skin of fixed official forms rendered on
demand. 0068 D2 stays as decided for the generic renderer. 0068 D6 ("no official wording ships before the owner answers")
is not touched: under this record a company adds no official wording; the legal texts are the platform's existing catalog.

### D8. How 0056 T10 (template injection) is closed

0056 T10: "Template injection: module template output from untrusted field values (PDF text only; no active content)." 0056
D5 (direction, non-binding): "Template output is PDF text only, no active content or embedded scripts (T10)."

- **Untrusted field values** (document data, company free text in data fields): inserted only as text runs after
  `clean/1` and `escape/1`; they cannot open an element, a field code, a hyperlink or a relationship (D2).
- **Untrusted template** (the new input this record adds): closed by the allow-list of placeholder names (D3 rule 3), the
  absence of any expression syntax (D2), and the sanitizer (D4), so the stored template holds no code and no active
  content, and the filler adds none.
- **Output.** The PDF stays the platform layout (D6), so the 0056 D5 PDF rule holds unchanged. The docx output holds only
  the allow-listed parts of D4 plus text the filler wrote; no macro, ActiveX, OLE, external link or non-page field code
  can be present, which is the docx form of "no active content or embedded scripts".

### D9. The audit sentence

Today `docs/status/official-forms-audit.md` (summary and row D7) says: "A tenant cannot adjust an official form today."
That stays true until slice S3 (print integration) merges. The slice that ships the screen (S5) appends to that file
(design section 3):

> Since S5 (task id): a tenant may replace the presentation of an official form with its own docx template (permission
> `OfficialFormTemplatesManage`). The legal skeleton (title, form code, annex line, column headings and order,
> signature roles, the kk draft notice) cannot be changed or removed: it is filled by the platform from its catalog and
> the upload is refused without it. The PDF still prints the platform layout until S6.

The Print-templates part of row D7 (overrides do not reach module prints) stays true. If the final atom name chosen by S4
differs, S5 writes that name in the sentence.

### D10. Open base and closed extra

Upload, check, sanitizer, versions, rollback and the docx print are open base (a company must be able to print correct
legal forms in every build). A visual designer on top of the same storage and check stays the closed candidate 4 of
`docs/design/open-core-closed-candidates.md`, saving through the same open route and check.

## Slices (from the design, section 6)

S1 sanitizer and check (pure) -> S2 starter templates and filler (pure) -> S4 storage, routes, permission, audit -> S3
print integration -> S5 web section and the D9 sentence. S6 (PDF from the company docx) waits for the owner. SECURITY-REVIEWER
runs on S1, S3 and S4.

## Tests the slices must add

- **S1-macro**, **S1-ole**, **S1-external-link**, **S1-field-code**, **S1-doctype**, **S1-databinding**, **S1-tracked**:
  each refuses, naming a rule code and no document text.
- **S1-zip-caps**: compressed size, uncompressed total, entry count and ratio each refuse at their cap + 1 and accept at the cap.
- **S1-one-parse**: the stored bytes equal the sanitizer's output, and the filler reads only stored bytes.
- **S1-split**: a placeholder split over three runs is found and stored joined.
- **S1-unknown-name**, **S1-missing-legal**, **S1-missing-data**, **S1-column-order**, **S1-duplicate-legal**: D3 rules.
- **S2-escape**: a data value `</w:t><w:fldSimple w:instr="INCLUDETEXT x"/>` prints as literal text and adds no element.
- **S3-fail-closed**: an active template missing a newly required name refuses the docx print; no fallback.
- **S4-cross-tenant**: tenant A's credential on tenant B's template id gets a response indistinguishable from an unknown id
  (INV-5, INV-10); the routes take no tenant parameter.
- **S4-audit**: audit payloads carry no template bytes or text.

## Threats for SECURITY-REVIEWER

- Template injection through field values or through the template itself (D2, D3, D8; 0056 T10).
- Active content or remote references in the stored or printed docx (D4).
- Parser attacks on untrusted OOXML: zip bombs, DTD/entity expansion, path tricks in zip entry names (D4: re-written
  package, only allow-listed names written).
- A guard and a consumer that parse differently (D4: one parse, verified bytes only).
- Cross-tenant use or management of a template (D5; INV-1, INV-5, INV-10).
- A template that names a field outside the mapper's data map (D3 rule 3; INV-2).
- Template bytes or text in audit, logs or errors (D3, D5).
