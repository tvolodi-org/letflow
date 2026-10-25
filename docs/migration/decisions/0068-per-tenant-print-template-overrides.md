# 0068 -- Per-tenant print-template overrides: a closed declarative layout stored per tenant, pinned to the issued version, never regenerated, with Kazakhstan print forms held for the owner

Status: PROPOSED by the developer of GH #3202 (REQ-564 slice 0, task T-0512), 2026-10-25. Needs SECURITY-REVIEWER and REVIEWER sign-off (see Sign-off). Changes no code: every implementation slice is its own requirement (see D8).

Date: 2026-10-25

Requirement: REQ-564 (GH #3202).

Depends on: REQ-550, REQ-542.

Scope: print-template overrides only. Form overrides and list overrides are OUT OF SCOPE here and belong to REQ-550 and its follow-ups; the split is stated in [0067](0067-tenant-x-extension-layer-over-module-entity-types.md) D1, paragraph "Override kinds split", and is cited here, not repeated. The one coupling it names (the presentation item may show an `x_` field, never adds one) is honoured in D5.

Relation to 0056: this record **builds on 0056 and amends no sentence of it.** 0056 D5 says "Per-tenant print-template overrides are a later customization candidate ... and are NOT decided here. This record only reserves `template_ref`"; that stays true of 0056 itself, and this record is the decision it points to. One strict extension is flagged for REVIEWER (D4): the version-row column list of 0056 D1 gains write-once columns. If REVIEWER rules that an amendment, the sentence extended is 0056 D1: "`artefact_hash` (sha256 of the rendered PDF bytes, null while draft)"; the column list it belongs to is extended, no existing column changes meaning.

## Sources

Files and records opened for this record:

- `docs/migration/core-roadmap-20261014.md`, row "Customization beyond scripts" (print-template overrides including KZ print forms).
- [0056](0056-versioned-documents.md) Context, D1, D3, D4, D5, D8, D9, T10 and open points 6 and 15.
- [0053](0053-tenant-scripted-rules.md), "Customization beyond scripts" candidate list and hook 1.
- REQ-550 as registered in `docs/requirements.yaml`, and its record [0067](0067-tenant-x-extension-layer-over-module-entity-types.md) D1 "Override kinds split".
- REQ-564 as registered in `docs/requirements.yaml`.
- `lib/letflow/modules/exam/certificate_document.ex`.
- `lib/letflow/documents/document_type.ex`, `lib/letflow/documents/document_version.ex`, `lib/letflow/documents.ex`.
- [0033](0033-pdf-qr-rendering-dependencies.md), [0003](0003-ecto-schema-strategy.md), [0046](0046-admin-scopes-and-role-charter.md), `docs/agents/instructions/security-invariants.md`.

Facts read in the code that the decisions rely on:

- `document_types` freezes every column once a document of the type exists (0056 D4), so `template_ref` cannot carry an override.
- `document_version.ex` has `content`, `content_hash`, `artefact_hash`, `issued_at` and no `template_version` column, although 0056 D5 and D9 say the template version is recorded on the version row and in `document.issued`. `grep -rn template_version lib` finds nothing. This record carries the gap into the implementing slice (D4).
- `documents.ex` has `template_ref` validation at type registration only and no issue-time render path yet. Any slice that renders at issue depends on the 0056 D5 render slice (its REQ id is not in the sources; the BA registers it).
- `certificate_document.ex` is a pure code-built renderer on the `pdf` library; its moduledoc records that the library cannot render non-Latin-1 glyphs (a `?` appears), "a real, load-bearing gap" for `kk` and `ru`.

## Decisions

### D1. What an override replaces and what it never touches

**Decision.** An override changes the presentation of the PDF only: labels and wording per language (RU, KK), column order and visibility of line tables, header and footer text, logo, page layout (size, margins, fonts from an allowed set). It never touches:

- `content`, the snapshot, and `content_hash`: the hash input is content, number, version, type and tenant (0056 D3) and contains no template, so an override cannot change it.
- the number and period: core prints them. An override positions a core-locked block set (number, version, issue date, issuer legal entity) and cannot remove it. Which blocks are core-locked per type is not settled by the source; this record decides that the module declares the set at type registration and the owner may veto (Q5).
- signatures: 0056 D6 stays direction; an override cannot add a block that implies a signature.
- `declared_fields` (D5).

`artefact_hash` does differ with an override, as it differs with any template; it is not an integrity input to the content.

**Reasons.** 0056 D3 makes content plus `content_hash` the authoritative record and the PDF its human form; a presentation layer must not be able to move either.

**Source.** 0056 D3, D6, D8; roadmap row.

### D2. Template form and authoring

**Decision.** Options: (a) a structured declarative layout stored as tenant data and interpreted by core; (b) a template language with substitution markers; (c) an uploaded file (PDF, DOCX or similar). Chosen: **(a)**. The layout is a closed JSON document (`layout_schema_version`, blocks `text`, `field`, `table`, `image`, `spacer`, `page`) validated against a closed schema. `field` and table-column references are names from the type's `declared_fields` only. Literal text is a plain string with a length cap. There is no URL, no expression and no conditional beyond a closed `show_if_nonempty`. Images come only from the tenant byte store with an allow-listed content type and a size cap; whether the `pdf` library can embed those types is not verified here, and the first slice proves it or drops `image`.

Output is PDF text and vector shapes only, with no active content or embedded script (0056 T10; 0056 D5 "Template output is PDF text only"). A tenant script (0053 hook 1) does not author, validate or run a print template; the render runs in core, outside the script host (0053; 0056 D8 "Scripts" bullet). Authoring is by API (JSON) in the management slice; a web editor is a later slice.

Technical prerequisite, not an owner question: the Cyrillic and Kazakh letters (Ә, Ғ, Қ, Ң, Ө, Ұ, Ү, Һ, І) are not renderable by the `pdf` dependency today. The first slice spikes a font-embedding path through an amendment of 0033 or another renderer decision, and no RU or KK layout ships before it passes.

**Reasons.** Rejected (b): a substitution-marker language is an expression surface, the "template injection" threat 0056 T10 names; it needs its own escaping and sandbox and gives no static proof that only projected fields are used. Rejected (c): an uploaded file is an opaque artefact that may carry active content (PDF JavaScript, macros), needs a scanner, cannot be checked against the projection, and is a finished form with no field substitution rather than a template. The cost of (a) is flexibility for the tenant; that trade-off is put to the owner as Q2.

**Source.** 0056 T10, D5, D8; 0053; `certificate_document.ex` moduledoc.

### D3. Storage, resolution and `:prefix`

**Decision.** A new tenant-schema table (name chosen by the implementing requirement; here `document_print_overrides`): `id`, `tenant_id` (kept inside the row, INV-1), `type_key`, `locale` (`ru`, `kk` or `default`), `version_no` (monotone per `(type_key, locale)`), `status` (`draft | active | retired`), `layout` (map), `layout_hash` (sha256 over the canonical bytes as 0056 D3), `layout_schema_version`, `created_by`, `activated_by`, timestamps. At most one `active` row per `(type_key, locale)` (partial unique index). A row is immutable once it leaves `draft` except `active -> retired` (column-aware trigger modelled on 0056 D4). No DELETE. Every access path takes the tenant `:prefix` (INV-1; 0003); `tenant_id` is never a request field. `template_ref` is not changed (0056 D4 freezes it).

**Resolution order at issue:** (1) the active tenant override for `(type_key, locale)`, else the tenant's `default`-locale override of that type; (2) the module default named by `template_ref`.

**Invalid override at issue: fail closed, no fallback to the module default.** An override is invalid when its layout no longer validates against the current `declared_fields` and restricted set (D5), or cannot be rendered. The pre-check runs before the numbering transaction, so a bad override refuses the issue with no number allocated (0056 D5 "validation before lock"). If a render fails after the number is committed (unreachable after the pre-check), the 0056 D5 rule applies: `{:error, _}`, the version stays `issued` with the artefact pending and is retried by the bounded job against the same pinned override (D4); no field values in errors or logs. The tenant repairs the case by retiring or replacing the override.

**Reasons.** A silent fallback would print a legal form in wording or language the tenant did not approve and would hide the fault; failing before the number is taken keeps the sequence gap-free (0056 D2).

**Source.** 0056 D2, D4, D5; 0003; INV-1.

**Later tests (names are IDs).** **C3-render**: a tenant A override is never used to render tenant B's document (two tenants, same `type_key` and locale, A active with a distinguishing literal; B's PDF text and `print_override_id` show the module default). **C3-manage**: a request to read, activate or retire tenant B's override with a tenant A credential gets a response indistinguishable (status, headers, body) from the response for a non-existent override id (INV-10, INV-5), and the route has no tenant parameter.

### D4. Binding to document versions

**Decision.** The override used is pinned at issue: it is resolved before the numbering transaction and written in it. New write-once columns on `document_versions`: `template_version` (which 0056 D5 and D9 already say is recorded), `print_override_id`, `print_override_version`, `print_override_layout_hash` (null when the module default is used). The same values (ids, versions, hashes; no layout content) go into `document.issued`. A later activation, retirement or edit of an override never alters an issued version: the pinned row is immutable and retired rows are never deleted. The stored artefact is authoritative and is never regenerated (0056 D5 and the PRIMARY RULE of 0056 D3: "the STORED BYTES ARE AUTHORITATIVE and are NEVER REGENERATED").

**Reprint** of an issued version is a download of the stored artefact (0056 D8 download rules); there is no re-render route. A tenant that wants an old document in a new layout issues a new version (0056 D4 supersede), which resolves anew. Whether the owner wants a labelled, non-authoritative copy re-rendered in the new layout is not settled by the source (Q4); default: none.

The implementing slice extends the 0056 D4 trigger for the new write-once columns; this is the one extension named in the header.

**Reasons.** An issued legal document must stay reproducible as issued; the pin records which layout produced it without storing it twice.

**Source.** 0056 D3, D4, D5, D8, D9.

### D5. Field restrictions in rendered output

**Decision.** An override receives only the projection of `content` onto the type's `declared_fields` (0056 D8), the same value the module template receives, and cannot widen it: an override cannot change `declared_fields` or `restricted_fields_allowed`, both frozen by the type row. Because `declared_fields` is frozen per type, an `x_` field of 0067 reaches an override only through a new type key. Layout validation at save and at activation rejects any `field` or table column that names a field outside the projection. The issue pre-check re-checks the restriction set (0056 D8: the restriction set is re-checked at every issue), so a restriction added after an override was saved makes the next issue refuse, with no number allocated, until the override or the type is revised; issued versions are untouched. Error responses carry a rule code and the layout path, never a field value.

**Reasons.** The projection is the only field-authorisation boundary the render has (INV-2); a layout that cannot name a field outside it cannot leak one.

**Source.** 0056 D8, D5; INV-2; 0067 D1.

**Later tests.** **D5-redact**: an override referencing a restricted field, and one referencing a field outside the projection, each fails closed (save or activation refused; through a test seam the render itself fails), and the PDF text, error and log output contain no value of that field (INV-2). **D5-later-restriction**: a restriction added after activation makes the next issue refuse with no number allocated.

### D6. Kazakhstan print forms

**Decision.** The forms meant are those in the Context section of 0056: З-1, З-2, З-5, Р-1, СНТ and ТТН. For СНТ, issuing and registration of СНТ/ЭСФ/ЕСУТД is assigned to an external system by the customer draft, so Letflow prints evidence, not the registered form. The type key `kz.z1` is the example key of 0056 D1; the keys of the other forms are not named by any source (not settled by the source; the type-registering requirement names them). Languages: RU and KK. The wording owner is the customer's accounting and legal function (0056 open point 6, NF-07); no person is named by the source. Per 0067 D1 the forms are module code and belong to this item, but who approves their official wording is not derivable from the sources.

**Open owner question Q1 (customer decision required).** Who owns and signs off the official RU and KK wording, and which form applies to which transaction. Options:

- (A) The tenant authors every official layout through the override mechanism; the platform ships no official wording and the tenant carries the legal responsibility.
- (B) The platform ships a neutral DRAFT layout per form, marked "draft, not official", for the tenant to review and activate.
- (C) The customer supplies official wording as files and the team ships it as the module default in code (version-controlled and reviewed, but every wording change is a release).

**Recommendation: A**, with B considered once the customer names its owner; C only if the customer wants one certified layout shared by all its legal entities.

**No official wording ships before the owner answers.** The first implementation slices carry the mechanism and a neutral non-official fixture used only in tests.

**Reasons.** Official form wording has legal weight and no source gives the team authority to author it.

**Source.** 0056 Context, D1, open point 6; `document_type.ex`; `certificate_document.ex`; 0067 D1.

### D7. Authority and audit

**Decision.** One new tenant-scope permission, classified TENANT-scope under INV-10 and 0046 (an unclassified permission fails the build, as in 0056 D8). The atom is chosen by the implementing requirement; this record proposes `DocumentPrintTemplatesManage` (a proposal, it does not exist in code). Role: TENANT_ADMIN only; no new role; `docs/roles.md` is updated by the slice. Holding the issue permission proposed by 0056 D8 grants nothing over overrides, and the reverse.

Authoring versus issuing: holding the issue permission does not allow authoring an override. Separation of authoring and activation (author is not the activator, enforced by a CHECK `activated_by <> created_by`, as 0056 D7 purge) is recommended but not settled by the source, and it conflicts with a tenant that has a single administrator: Q3, options (1) two-principal activation (recommended), (2) mandatory reason only.

Audit events, written in the same transaction as the change (0056 D9 shape, 0051 D8): `document.print_override_saved`, `document.print_override_activated`, `document.print_override_retired`. Payloads carry override id, type key, locale, version, `layout_hash`, actor id and reason code. No audit payload carries template content (no layout text, no wording). Refusals follow the 0056 D9 refusal rule (telemetry and an aggregated counter, no per-attempt audit row).

The management routes take the tenant from the auth context only (INV-10): no tenant id in path, query or body. A route-scope entry and the cross-tenant negative test C3-manage (D3) are required.

**Reasons.** Overrides change legal output, so only the tenant's top administrative role manages them, and the chain records who activated which layout without copying the layout.

**Source.** 0056 D7, D8, D9; 0046; 0051 D8; INV-5, INV-10.

### D8. Slice plan

Common to all slices: `depends_on` includes REQ-564, REQ-550 and REQ-542, each slice is sized to one change, and SECURITY-REVIEWER is a mandatory gate for every slice (tenant data, INV-1, INV-2, INV-10). REQ ids are not assigned; the BA registers them after sign-off.

- **S1 Layout schema and pure renderer.** Closed schema, validator, `render(layout, projection)` to PDF bytes with an embedded font (the Cyrillic/KK spike and the 0033 note). No database, no route. Tests: S1-schema (unknown block, expression and URL rejected), S1-text-only (no JS, Launch or URI action markers), S1-glyph (RU and KK samples render without `?`), D5-redact at byte level.
- **S2 Storage, management API and audit.** Table, migration and trigger, context, tenant routes, the permission, `docs/roles.md`, audit events. Tests: C3-manage (the first slice with a route), D5-redact at activation (outside-projection and restricted fields refused, no value in the response), S2-immutable (trigger), S2-sod (per Q3), S2-audit (no content in payload), and the route-inventory pins (`__authz_routes__`, `length(snapshot)`, `tenant_wide_default_routes.txt`), whose new values that slice's design states.
- **S3 Resolution and issue integration.** Resolution order, pre-check before the numbering transaction, pinned columns, `document.issued` payload, fail closed. Depends also on the 0056 D5 render slice. C3-render sits here and not in S1 because S1 is a pure function of (layout, projection) with no tenant input and no database, so a cross-tenant render test has nothing to cross; S3 is the first tenant-aware render path (S2 carries C3-manage for the first route, and D5-redact covers the render in S1 and S2). Tests: C3-render, D4-pinned (a later activation does not alter an issued version and the artefact is not regenerated), D5-later-restriction, S3-invalid-fails-closed (no number allocated).
- **S4 Web authoring screen** (FRONTEND-DEV). JSON layout editor with preview from synthetic content. After S2. Tests: component tests of the editor and the preview.
- **S5 KZ forms.** Type registrations and layouts per the owner's answer to Q1. Blocked until the owner answers. Tests: registration and render tests per form, per the answer.

**Source.** Roadmap row; REQ-564; 0056 D5.

## Open owner questions

1. **Q1 KZ wording owner and forms** (D6): options A, B, C; recommendation A.
2. **Q2 Template form** (D2): (a) closed declarative layout, recommended; (b) a template language, only later through its own record if tenant flexibility outweighs safety.
3. **Q3 Activation separation** (D7): (1) two-principal activation, recommended; (2) mandatory reason only.
4. **Q4 Reprint in a new layout** (D4): (1) none, default; (2) a labelled non-authoritative copy.
5. **Q5 Core-locked block set per type and the type keys of the other forms** (D1, D6): module declares at type registration (this record's default) or the owner lists them; low priority.

## Tests the implementation slices must add

C3-render, C3-manage, D5-redact, D5-later-restriction, D4-pinned, S1-schema, S1-text-only, S1-glyph, S2-immutable, S2-sod, S2-audit, S3-invalid-fails-closed (placement in D8).

## Threats for SECURITY-REVIEWER

- Cross-tenant use or management of an override (D3, D7; INV-1, INV-5, INV-10).
- A layout that names a restricted or unprojected field and leaks its value into the PDF, an error or a log (D5; INV-2).
- Template injection or active content in the PDF (D2; 0056 T10).
- Tampering with an issued version by changing an override afterwards (D4).
- Template content in audit payloads (D7).

## Sign-off

- SECURITY-REVIEWER: pending, not yet reviewed (content of D3, D5, D7).
- REVIEWER: pending, not yet reviewed.
