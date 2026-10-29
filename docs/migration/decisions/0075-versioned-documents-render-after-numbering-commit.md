# 0075 -- Versioned documents, slice 2 part 3: PDF render after the numbering commit, artefact attach, write-once column opening, integrity recheck on download (binds 0056 D5)

Status: PROPOSED by the designer of GH #3475 (task T-0904, REQ-622), 2026-10-28. Not binding until the
owner or REVIEWER signs it (see Sign-off). REQ-623 (GH #3474) is not built before that. (Number 0075:
the highest on origin/main is 0074; no team branch holds a higher one.)

Amends: [0056](0056-versioned-documents.md) D5 (the rendering direction becomes BINDING for REQ-623).
Consumes, by section: 0056 D2 (the numbering transaction holds no render and no byte-store I/O, and the
lock order is sequence row first, audit chain second); D4 (immutability triggers, `artefact_hash`
write-once, `ENABLE ALWAYS`); D5 (the render rulings of 2026-10-15); D8 (access, "Field restrictions
versus the PDF", download and read routes); D9 (`document.artefact_attached` reserved,
`document.integrity_failed` binding); acceptance-criteria candidates 10, 12 and 23 of 0056. Also
consumes D3 (stored bytes are authoritative; hash recheck on read paths, binding).
Everything else in 0056, 0063 and 0074 is unchanged. This record writes no code, seed, migration,
test, route or permission.

## Context

Sources, read on origin/main:

- `Letflow.Documents.issue/2` (`lib/letflow/documents.ex`) renders nothing; its doc says "Nothing here
  renders or stores bytes". `document_versions.artefact_hash` exists and is NULL on every issued row.
- `guard_document_versions()` (`priv/repo/migrations/20261022100002_create_document_immutability_triggers.exs`)
  allows no transition that sets `artefact_hash` on an issued row. 0056 D4 says the column is write-once
  "in the slice-2 attach transaction (D5)"; the guard has to be opened to exactly that change.
- `Letflow.Repository.upsert_content/6` (`lib/letflow/repository.ex`) stores content-addressed bytes.
- `verify_binding/4` and its private `verify`/`recompute_hash` path recompute `content_hash` from the stored
  content and audit `document.integrity_failed` on a mismatch.
- `Letflow.Documents.DocumentType` has `template_ref` and `declared_fields`; `DocumentVersion` has no
  `template_version` column.
- `lib/letflow/modules/exam/certificate_document.ex` is a code-built renderer on the `pdf` library;
  `Letflow.Documents.PrintLayout` (0068 S1) is the later declarative layout. Both stay out of this record.

0056 D5 was ruled by the advisor on 2026-10-15 but marked direction until a follow-up record binds it.
This is that record for the render half of slice 2. Signatures (D6) are not here; retention and purge
are 0063 and 0074.

## Rulings

Each ruling is binding text once the record is signed.

### R1. Render order (binds 0056 D5, point a; 0056 D2)

The render runs after transaction 1 (`Documents.issue/2`) has committed. When it runs, no database lock is
held by the render path, and it runs outside any transaction of the caller: `attach_artefact/2` returns
`{:error, :in_transaction}` if `Repo.in_transaction?/0` is true on entry, so the guarantee cannot be lost
by a caller that wraps it. `issue/2` is unchanged: it renders nothing, stores no bytes and leaves
`artefact_hash` NULL.
Reason: the PDF prints the number (0056 D2 ruling), so it cannot be rendered earlier, and a render under
the sequence row lock or the audit lock would block all issuing of the tenant behind file work.

The optional 0056 D5 variant (render BEFORE transaction 1 for a type whose template does not print the
number) is NOT adopted. Reason: two code paths double the test matrix and the no-renderer and failure
rulings below; no type needs it.

### R2. Transaction 2 (binds 0056 D5, point b; 0056 D4, D9)

Before the render, with no transaction and no lock, `attach_artefact/2` makes an unlocked read of the version:
unknown or other-tenant gives `{:error, :not_found}`; a status other than `issued` gives
`{:error, :not_issuable_for_artefact}`; an `artefact_hash` already set returns `{:ok, _}` with no render call.
Only then does it render. The locked re-read in transaction 2 below stays as the race guard.

Transaction 2 opens after the render returned bytes. In order: lock the version row `FOR UPDATE` and re-read
it; refuse (R6) if it is not `issued`; if `artefact_hash` is already set, return `{:ok, _}` with no change,
no new bytes and no second audit entry; otherwise store the bytes with `upsert_content/6` (key
`content_hash` = SHA-256 of the bytes), set `artefact_hash` to its lowercase hex form once, and write
`document.artefact_attached` to the audit chain in the same transaction. Lock order is the version row
first, then the audit chain lock (the audit entry is the last write), the 0056 D2 order extended; transaction 2
takes no `document_sequences` lock at all. Two concurrent calls yield one attach: the second waits on the row
lock, re-reads, and returns the already-attached outcome.
The payload carries only document id, version number, `content_hash`, `artefact_hash`, byte size,
template reference and template version (0056 D9: no field values).
Reason: the row lock plus re-read is what makes "set once" true under concurrency; the database guard (R7)
is the backstop, not the first line.

### R3. Render failure (binds 0056 D5, point c)

A render failure, whether the renderer returns `{:error, _}` or raises or exits, returns `{:error, :render_failed}`
to the caller. The renderer's term is never returned. The failure does not raise to the caller, does not
release the number (the `document_sequences` counter and the version number are unchanged; gap-free is
kept), leaves the version `issued` with `artefact_hash` NULL, and writes no `repository_artifacts` row and no
`document.artefact_attached` entry. The failure is logged as a reason code only: no renderer message, no
field value and no content in the log, the error or telemetry metadata (INV-4 shape). A later successful call
attaches; `attach_artefact/2` is safe to repeat on a pending version.
Reason: the number is already committed and legal; only the artefact is missing.

### R4. Projection only (binds 0056 D5, point d; D8; candidate 12)

The renderer receives only the projection of the version `content` onto the type's `declared_fields`, plus
`meta` (number, period, version number, issue time; no content). It never receives the full content, the
entity record or the version row. A template that needs a key outside the projection finds it absent and
fails closed; that is `:render_failed`.
Restriction added after issue: `attach_artefact/2` re-checks, at attach time, that no declared field is
restricted for the source entity type (the same check 0056 D8 runs at every issue), and if one is, returns
`{:error, :render_failed}` with no bytes stored and the version left pending. This EXTENDS 0056 D8, which
rules only that such a restriction refuses the next issue. Reason: D8 states that the restricted fields are
never rendered; an artefact produced after a restriction was added would put a now-restricted field into one
immutable byte string that every reader can download. The cost (a pending artefact for a version issued
before the restriction) is accepted; the version and its number are not harmed, and the type is revised under
a new type key as D8 already says. REQ-623 criterion 8 is therefore kept.

### R5. Pending is not downloadable (binds 0056 D5, point e; D8)

A version whose artefact is pending is not downloadable. The read function `Documents.fetch_artefact/3`
(prefix, document id, version number) gives the same not-found value as an unknown version, `{:error, :not_found}`,
for: an unknown version, an issued version with `artefact_hash` NULL, a draft, a superseded, cancelled or
discarded version without an attached artefact, a malformed argument, and a document of another tenant (INV-5;
no reason is distinguishable by the caller, the reason only in telemetry metadata). It returns the STORED
bytes (`{:ok, %{bytes: binary, content_type: "application/pdf"}}`), never a fresh render (0056 D3 primary rule).
A superseded or cancelled version whose artefact was attached before keeps its artefact readable by this
function; whether the route shows it is the route record's call (R10).

### R6. Names, registration and no-renderer behaviour

One-line rulings, each with its reason.

- **Entry function:** `Letflow.Documents.attach_artefact(prefix, %{document_id:, version_no:, actor_id:})`,
  returning `{:ok, %{version: version}}` or `{:error, atom}`. Reason: same map-argument shape as
  `new_version_from_current/2` (the map form is chosen over `cancel/3`'s separate actor argument); `actor_id` is audit-only, the function checks no permission (like the rest of
  the module; the first caller owns that).
- **Read function:** `Letflow.Documents.fetch_artefact(prefix, document_id, version_no)`, three arguments, no
  scope. Reason: scope belongs to the later download route (R10).
- **Error atoms:** `:render_failed` for every render outcome other than success (renderer error, raise, exit,
  timeout, fail-closed projection, restriction added after issue, no renderer); `:not_issuable_for_artefact`
  for a version whose status is not `issued` (draft, superseded, cancelled, discarded; also one cancelled or
  superseded between issue and attach), with no render call and no write; `:in_transaction` (R1); `:not_found`
  for an unknown or other-tenant version, shape as `cancel/3`. Reason: one atom per caller decision; the reason
  for a render failure stays in the log as a code, so no atom leaks template internals.
- **Renderer behaviour:** `Letflow.Documents.Renderer` with exactly one callback `render(template_ref, projection,
  meta)` returning `{:ok, binary, template_version}` or `{:error, term}`, where `template_version` is a non-empty
  `String.t()` naming the template revision that produced the bytes. The version travels in the return value;
  there is no second callback and no version in the registry, so REQ-623 criterion 7 ("one callback") holds
  unchanged. A test renderer returns any fixed non-empty string (for example `"test-1"`); a return of
  `{:ok, binary}` without a version, or an empty or non-string version, is a contract violation and is treated as
  `{:error, :render_failed}` (log code `bad_renderer_return`). Reason: smallest surface that lets a test renderer
  stand in and lets 0068 S3 plug in without changing the entry function (the type's `template_ref` is passed
  through); the module that renders knows its own revision, and returning it with the bytes cannot drift from them.
- **Registration per `template_ref`:** a renderer module is registered by code shipped with the owning module,
  as a compile-time map `template_ref => renderer module`, read through one function in a core module
  (`Letflow.Documents.Renderers`, new in REQ-623) that owns the lookup; a module adds its entry the way it
  registers its document types. There is no tenant-supplied renderer, no runtime registration, no module name
  taken from data. A test replaces the map through an application-config override that exists only in the test
  environment. Reason: 0056 D5 says "module-provided templates only for now" (code, not tenant data); a
  lookup from `template_ref` to a module name stored in a row would be dynamic code selection from tenant
  data (INV-3, INV-9 shape).
- **No renderer for a `template_ref`:** `attach_artefact/2` returns `{:error, :render_failed}` with nothing
  stored and the version left pending; the log code is `no_renderer`. This confirms the proposed ruling of
  REQ-622. Reason: an issued legal number without an artefact is still correct and pending, and failing closed is
  the same outcome as any other failed render, so one retry path serves both; the alternative (a silent skip
  marking the version as "no artefact needed") would let a misconfigured type pass unnoticed.
- **`template_version`:** NOT a column of `document_versions` in REQ-623. The `template_version` returned by
  `render/3` (see Renderer behaviour) is recorded by `attach_artefact/2` in the `document.artefact_attached` payload (audit is
  append-only and in transaction 2). This amends 0056 D5 and D9 ("recorded on the version row"). Reason: a new
  column on `document_versions` would need its own write-once rule in the guard next to `artefact_hash` and
  would widen REQ-623 beyond one guard change; the audit payload already ties the artefact to the template
  version, and a stored artefact is never regenerated (0056 D3), so the version row does not need it for
  correctness. A column is for the 0068 S3 slice if per-tenant overrides need a queryable template version.

### R7. Opening the write-once column (binds 0056 D4)

The database guard `guard_document_versions()` is replaced by one new TENANT-scoped migration (next free
version at implement time; added to `@tenant_scoped_migration_manifest` of `lib/letflow/tenant_provisioning.ex`;
replayed into existing tenants; the triggers stay `ENABLE ALWAYS`, 0056 D4, candidate 18). The new body keeps
every transition of the old guard unchanged and adds exactly one: on an issued row whose `status` does not
change, only `artefact_hash` may change, and only from NULL to a value. The following stay refused: value to
another value, value to NULL, NULL to NULL combined with a change of any other column, and a change of any
other column on an issued row that has no status transition. The status transitions that touch an issued row
(`issued -> superseded`, `issued -> cancelled`) are unchanged and do not set `artefact_hash` in the same
statement. No new table and no new trigger; only the function body is replaced.
Existing rows: every existing issued row has `artefact_hash` NULL and stays pending until a call of
`attach_artefact/2`; nothing is back-filled by the migration. The migration is auto-deployed to QA with main;
QA's issued versions stay pending and not downloadable, which is the correct state.
The test `constraints_test.exs` case "A-19: artefact_hash stays NULL" is amended in REQ-623 to hold for
versions on which `attach_artefact/2` was never called.
Reason: the database, not module code, is the control for immutability (0056 D4); the narrow rule means a
bug or a compromised caller of the write path still cannot change an attached hash.

### R8. Integrity recheck on download (binds 0056 D3)

`fetch_artefact/3` recomputes `content_hash` from the stored content, tenant uuid, document id, type key,
legal entity, number and version number through the same recompute path `verify_binding/4` uses (no third
hash code), before it returns any bytes. On a mismatch it returns `{:error, :not_found}` (the not-found value
of R5) and audits `document.integrity_failed` (ids and hashes only, actor nil), once per read, under the
transaction contract of `verify_binding/4`'s doc. It also checks that the stored bytes hash to
`artefact_hash` before returning them; a mismatch is refused the same way and audited the same way.
The `document.integrity_failed` payload carries ids and hashes only and a `check` key that tells the cases
apart: `"content"` with `stored_hash` and `recomputed_hash` (the existing `content_hash` shape), or
`"artefact"` with `artefact_hash` (stored) and `recomputed_hash` (SHA-256 of the stored bytes).
Reason: 0056 D3 makes the recheck binding on read paths that feed a decision, and a download is one; serving
corrupted bytes to a recipient who then relies on them is the failure the recheck exists for. A failed
read writes an audit entry only on a hash mismatch (an integrity event), never for an ordinary not-found, so a
caller cannot grow the audit chain with probes (0056 D9 refusal rule).

### R9. Who sees `artefact_hash` (binds 0056 D8)

`fetch_artefact/3` does not return `artefact_hash` or `content_hash`. A later read view returns `artefact_hash`
only to a principal with the all-fields grant, as 0056 D8 already rules for `content_hash`: the hash covers
unredacted content and a low-entropy field can be guessed against a visible hash. Reason: INV-2.

### R10. What stays direction

Not decided here; each is bound only by the named later record.

- **Bounded retry job for pending artefacts:** its schedule, bound and the principal it runs as. Bound by a
  later record; `attach_artefact/2` is already safe to call again, so the job needs no new write path.
- **Download route and `document.downloaded`:** route path, scope proof, headers and the audit of successful
  downloads (0056 D8 states the shape: no ETag, no Last-Modified, `Cache-Control: no-store`). Bound by a later
  download-route record.
- **Permission for download and for triggering an attach:** a new tenant-scope atom and its classification
  (INV-10, 0046) have no source. Bound by the download-route record. `attach_artefact/2` adds no permission here.
- **Template overrides, Cyrillic and Kazakh glyphs:** 0068 S3 (and the 0033 amendment named in 0068 as its
  prerequisite). The renderer takes the type's `template_ref` so this plugs in without changing R6.
- **Signatures (D6):** a later signature record; a signed artefact is a different byte string from the one
  attached here.
- **Which of `Letflow.Documents.PrintLayout` and a code-built template renders a `template_ref`:** 0068 S3.

## Tests pinned as build criteria for REQ-623

- **Numbering-transaction test (0056 acceptance candidate 23).** A test calls `Documents.issue/2` with a
  renderer configured that fails the test (`flunk`) if invoked at all; `issue/2` returns `{:ok, _}` with the
  renderer never called. In the same file the same renderer invoked through `attach_artefact/2` records its
  call, and the test asserts it was called once.
- **Lock check in sandbox auto mode.** A test in the style of `test/letflow/documents/issue_lock_order_test.exs`
  (`SandboxAutoMode.enter_auto_mode!(Repo)`, `async: false`, `Letflow.LockOrderHelpers`) calls
  `attach_artefact/2` after `issue/2` returned `{:ok, _}`, with a test renderer that reads `pg_locks` filtered
  by the test's tenant schema name and fails if, during the render call, any lock is held on
  `document_sequences`, `documents` or the audit chain, or `Repo.in_transaction?/0` is true. Under the default
  sandbox the row locks of `issue/2` would stay held until the test ends, so the check proves nothing there;
  auto mode is part of the criterion.
- **Artefact hash (0056 candidate 10).** The stored bytes of an attached version hash to `artefact_hash`; a
  second `attach_artefact/2` yields no second `document.artefact_attached` entry.
- **Renderer projection (0056 candidate 12, renderer half).** A test renderer reading a key that is in `content`
  but not in `declared_fields` finds it absent; when it fails closed, the attach returns `{:error, :render_failed}`
  and the number is not released.
- **Write-once at the database** and **integrity recheck** tests as R7 and R8 state them, including the
  two-tenant test of R5 and a corrupted stored content that gives `:not_found` and exactly one
  `document.integrity_failed` entry.

## Consequences

- REQ-623 builds exactly R1 to R9 and reads its criteria with this record's names where they differ. Its
  criterion 8 is kept (R4).
- After the migration of R7 a role able to call the write path can set `artefact_hash` once on a pending issued
  row; the audit entry holds both hashes (0056 D4 residual-risk stance), and R8 detects later corruption.
- REQ-623 pins that move: the migration version and the manifest count of `tenant_provisioning.ex` by +1. No
  new table, route or permission, so the table-list, route-scope and permission-matrix pins do not move.
- SECURITY-REVIEWER reviews REQ-623 as a stated step (tenant data path, migration).

## Not decided here (for the owner)

- Whether the owner accepts REVIEWER sign-off alone for this record, as for 0063 and 0074, or wants the
  owner's own signature. The record states which one it received (Sign-off).
- The schedule and permission of the retry job and of the download route (R10).

## Sign-off

- Designer: T-0904 designer, 2026-10-28 (this document).
- CODE-DESIGN-VALIDATOR: pending.
- REVIEWER: pending.
- Ratification: pending the owner or REVIEWER. Until then GH #3474 (REQ-623) is not built.
