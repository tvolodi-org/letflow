defmodule Letflow.Routers.Entities do
  @moduledoc """
  Entity-subsystem sub-router, mounted at `/entities` by
  `Letflow.Plugs.ApiPipeline`. Built to
  `lib/letflow/design/req308-entity-http-surface.md` — §1 is the route table,
  §2 settles one-router-not-two, §5 the security posture, §6 pagination, §7
  the error mapping per delegate.

  REQ-310 created this module with the nine definition and record routes
  below; REQ-311 appended §1's tenth row, `POST /entities/query`, to this
  same module — an append, not a restructure. REQ-315 appended an eleventh
  row, `POST /entities/query/aggregate` — the aggregation/reporting query
  route, per `lib/letflow/design/req312-query-aggregation.md`. Its handler
  calls `Letflow.Entities.Query.Compiler.run_aggregate/2`, a thin wrapper
  around `compile_aggregate/2` plus the query's own execution (and, GH #2654, the
  padding of a `decimal_strict` field's `sum`/`min`/`max`/group key), added
  specifically so this route stays composition-only, same as every other
  route here — this module executes no query of its own (INV-1, below).
  REQ-317 appended a twelfth-through-fifteenth set of rows, the four
  record-attachment routes, per
  `lib/letflow/design/req313-entity-record-attachments.md` §3 — delegating
  to `Letflow.Repository.EntityAttachments` (REQ-316), mirroring
  `Letflow.Routers.Instances`' own REQ-212 instance-attachment routes.

  GH #2833: the record write handlers (create, update, delete, and the shared renderer of a
  record command) live in `Letflow.Routers.Entities.RecordWrites`, the record import handler in
  `Letflow.Routers.Entities.RecordImport` and the record attachment handlers in
  `Letflow.Routers.Entities.RecordAttachments`. Request helpers shared by them and this router
  (`prefix!/1`, `object_body/1`, `validate_schema/2`, `violation_map/1`, ...) live in
  `Letflow.Routers.Entities.Support`. This module keeps the route table, the definition and
  query handlers and the restriction import; each route calls its handler by module-qualified
  name, so the route table reads the same as before the split.

  Its permission vocabulary (`:EntitiesDefinitionsRead`,
  `:EntitiesDefinitionsWrite`, `:EntitiesRecordsWrite`, and REQ-311's
  `:EntitiesQuery`) was minted ahead of this router by REQ-309 — every route
  below resolves through a real `Letflow.Api.Authorization.endpoint_policy_key/2`
  clause, so none is on `test/letflow/api/authorization_enforcement_test.exs`'s
  allowlist and none evaluates as `:Unknown`.

  REQ-319 appends a twelfth row, `POST /entities/records/:entity_type/export`
  — bulk, query-selected-set record export, per
  `lib/letflow/design/req314-entity-record-bulk-export-import.md` (built to
  that document's final, SECURITY-REVIEWER-cleared §6 INV-2 mechanism, not its
  original FAILed pass). Its route-level permission, `:EntitiesRecordsExport`,
  and its in-handler-only escalation permission,
  `:EntitiesRecordsExportUnredacted`, were both minted ahead of this router by
  REQ-318, the same "added ahead of its consuming route" state REQ-309's own
  four `Entities*` atoms sat in before REQ-310 created this module.

  REQ-496 (decision 0050 D7, design
  `lib/letflow/design/req496-managed-by-and-scope-node-paths.md` §3.1-§3.2):
  `activate_definition` refuses a module-managed entity type as its FIRST step
  (`DefinitionAccess.activate/3`, before the body, path id or query string is read),
  and `create_definition` right after the body parse; every refusal is the one
  constant 403 `Letflow.Api.Error.entity_type_managed/0`.

  GH #2808: `create_definition` (TypeAccess on the body `name`, constant 403), `activate_definition`
  (`Letflow.Entities.DefinitionAccess.activate/3`: a denied name is the absent 404) and
  `import_restrictions` (TypeAccess over every named type, constant 403, nothing written) apply
  TypeAccess; `Definitions` and `Restrictions` stay ungated for system callers.

  GH #2784 (design `lib/letflow/design/gh2784-write-routes-typeaccess.md`): the four generic
  record WRITE routes (`create_record`, `update_record`, `delete_record`, `import_records`) go
  through ONE gate, `Letflow.Entities.RecordAccess.write/3`, which replaced their
  former `guard_tenant_write/3` call. It makes four reads unconditionally (managed stamp, TypeAccess,
  active definition, field restrictions) and returns `:hidden` (denied, absent, or a failed
  read), `:managed` or `{:open, restricted}`. The decision is computed FIRST and applied LAST:

    * `:managed` is the constant 403 before the body is read (visible types only, so it never
      reveals a denied type);
    * `:hidden` runs the SAME validation an absent type runs and, at the exact point where
      `Records` would be called, substitutes `RecordAccess.hidden_result/1` (the result `Records`
      gives an absent type), so a denied type answers byte-identically to an absent one and
      writes nothing;
    * `{:open, restricted}`: POST or PUT naming a restricted key is the constant 403 of GH #2697
      (GH #2812: a PUT naming none keeps the stored restricted values server-side);
      each import entry naming a restricted key is `field_restricted`; the POST/PUT/DELETE
      response `field_values` are redacted for such an actor (`render_record_command/4`).

  **Inheritance rule:** any future generic record write route MUST call
  `Letflow.Entities.RecordAccess.write/3` first and apply its decision as above; any future
  entity-definition write route MUST call `Letflow.Entities.ManagedTypes.check_tenant_write/2`
  first. The list and content GET attachment routes use the lighter `RecordAccess.attachment/3`
  (one TypeAccess read, no managed or field check; GH #2784 PR B). The upload and delete routes
  use `RecordAccess.attachment_write/3`, which adds the managed stamp (GH #2582): a visible
  managed type gets the constant 403 `entity_type_managed` before the record id is read, and a
  hidden type still takes the fresh-UUID absent path. Any future attachment WRITE route MUST call
  `attachment_write/3`. For the four routes, a denied type runs the same code
  with freshly generated UUIDs for `record_id` (and `attachment_id` on content GET and delete),
  so it answers exactly like an absent record (upload 404, list the empty 200 page, content GET
  and delete 404) and nothing persists (a denied upload still attempts its write inside a transaction that rolls back at COMMIT).

  | Handler | Method/path | Delegate | Permission | Response |
  |---|---|---|---|---|
  | create_definition | `POST /entities/definitions` | `Letflow.Entities.Definitions.create_definition/2` | `EntitiesDefinitionsWrite` | 201 / 422 / 409 |
  | activate_definition | `POST /entities/definitions/:name/activate` | `Letflow.Entities.Definitions.activate_definition/4` | `EntitiesDefinitionsWrite` | 200 / 404 / 422 |
  | get_active_definition_by_name | `GET /entities/definitions/active/:name` | `Letflow.Entities.Definitions.get_active_definition_by_name/2` | `EntitiesDefinitionsRead` | 200 / 404 |
  | get_definition_by_name | `GET /entities/definitions/by-name/:name` | `Letflow.Entities.Definitions.get_definition_by_name/2` | `EntitiesDefinitionsRead` | 200 / 404 |
  | get_definition | `GET /entities/definitions/:id` | `Letflow.Entities.Definitions.get_definition/2` | `EntitiesDefinitionsRead` | 200 / 404 |
  | list_definitions | `GET /entities/definitions` | `Letflow.Entities.Definitions.list_definitions/3` | `EntitiesDefinitionsRead` | 200 / 400 |
  | create_record | `POST /entities/records/:entity_type` | `Letflow.Entities.Records.create_record/2` | `EntitiesRecordsWrite` | 201 / 404 / 422 (422 also `idempotency_key_reuse`, GH #2543; `idempotency_key` over 199 bytes -> 422 `max_length`, not valid UTF-8 or containing NUL -> 422 `format`, GH #2550) |
  | update_record | `PUT /entities/records/:entity_type/:record_id` | `Letflow.Entities.Records.update_record/2` | `EntitiesRecordsWrite` | 200 / 404 / 409 / 422 (422 also `idempotency_key_reuse`, GH #2543; `idempotency_key` over 199 bytes -> 422 `max_length`, not valid UTF-8 or containing NUL -> 422 `format`, GH #2550) |
  | delete_record | `DELETE /entities/records/:entity_type/:record_id` | `Letflow.Entities.Records.delete_record/2` | `EntitiesRecordsWrite` | 200 / 400 / 404 / 409 / 422 (a fresh key per request, so never `idempotency_key_reuse`) |
  | query | `POST /entities/query` | `Letflow.Entities.RequestAccess.check/4` (type gate over the primary and every join target, then the restricted-field guard) then `Letflow.Entities.Query.Compiler.compile/2` then `Letflow.Entities.Query.Allowlist.load/2` then `Letflow.Entities.Query.Cursor.paginate/5` then a `Letflow.Entities.Query.FieldGrants` redaction step | `EntitiesQuery` | 200 / 400 / 404 / 422 |
  | query_aggregate | `POST /entities/query/aggregate` | `Letflow.Entities.RequestAccess.check/4` (kind `:aggregate`: type gate over the primary and every join target, then the shared restricted-field walker covering every field and join fk) then `Letflow.Entities.Query.Compiler.run_aggregate/2` | `EntitiesAggregate` | 200 / 400 / 403 / 404 / 422 |
  | create_record_attachment | `POST /entities/records/:entity_type/:record_id/attachments` | `Letflow.Repository.EntityAttachments.upload/2` | `EntitiesAttachmentsManage` | 201 / 404 / 422 |
  | list_record_attachments | `GET /entities/records/:entity_type/:record_id/attachments` | `Letflow.Repository.EntityAttachments.list/2` | `EntitiesAttachmentsRead` | 200 / 400 / 404 |
  | get_record_attachment_content | `GET /entities/records/:entity_type/:record_id/attachments/:attachment_id` | `Letflow.Repository.EntityAttachments.get_content/2` | `EntitiesAttachmentsRead` | 200 (raw bytes) / 404 / 500 |
  | delete_record_attachment | `DELETE /entities/records/:entity_type/:record_id/attachments/:attachment_id` | `Letflow.Repository.EntityAttachments.delete/2` | `EntitiesAttachmentsManage` | 204 / 404 |
  | export_records | `POST /entities/records/:entity_type/export` | `Letflow.Entities.RequestAccess.check/4` (the unredacted permission never lifts type denial), then the identical `Letflow.Entities.Query.Allowlist.load/2` → `Letflow.Entities.Query.Compiler.compile/2` → `Letflow.Entities.Query.Cursor.paginate/5` sequence `query` uses above, then EITHER a `Letflow.Entities.Query.FieldGrants` redaction step (default) OR a second, in-handler `Letflow.Api.Authorization.evaluate_access/2` check against `:EntitiesRecordsExportUnredacted` that skips redaction entirely on success (`unredacted: true`) | `EntitiesRecordsExport` (route-level); `EntitiesRecordsExportUnredacted` (in-handler only, see below) | 200 / 400 / 403 / 404 / 422 |
  | import_records | `POST /entities/records/:entity_type/import` | `Letflow.Entities.Records.create_record/2` per entry (REQ-320); with the optional `"upsert_by": "external_ref"`, `Letflow.Entities.ImportUpsert` (one pre-check, then `Records.upsert_record_by_external_ref/2` per entry, GH #2659) | `EntitiesRecordsImport` (alone, also for the upsert's update branch) | 200 / 404 / 413 / 422 / 503 (`event_schema_outdated`, upsert mode only) |
  | import_restrictions | `POST /entities/restrictions/import` | `Letflow.Entities.Restrictions.import_restrictions/2` (ISS-0935) | `EntitiesRestrictionsManage` | 200 / 400 / 403 / 422 |

  ## `POST .../export`'s two-tier redaction mechanism (REQ-319, design §6 INV-2)

  Default mode (`unredacted` absent or `false` in the request body): the
  route-level `:EntitiesRecordsExport` check is the ONLY check. The handler
  then calls `FieldGrants.load_restrictions/3` and redacts exactly as `query`
  above does — this route's own `redact/4` clauses are reused verbatim, not
  duplicated — so default-mode export's disclosure strength is identical to
  `:EntitiesQuery`'s.

  Escalated mode (`unredacted: true`): AFTER the route-level check already
  passed, the handler calls `Letflow.Api.Authorization.evaluate_access/2` a
  SECOND time, positionally, against `:EntitiesRecordsExportUnredacted`
  directly — a request-body-derived permission check no route's
  `endpoint_policy_key/2` clause could ever express, since it depends on a
  field inside the body, not the method/path pair. Failing that check is a
  `403` returned **before the export selection query is even compiled** —
  never a silent fallback to the redacted default. Succeeding it skips
  `FieldGrants` entirely for that call. See `check_unredacted_permission/2`
  and `run_export/5` below for the concrete `with`-chain ordering.

  REQ-320 appended `import_records`, per
  `lib/letflow/design/req314-entity-record-bulk-export-import.md` §3/§4/§6/§7
  — the import half of that document's export/import pair (the export half,
  §2/§4, is REQ-319's own separate requirement and is not implemented by this
  route). Per-record partial-success batch semantics (§3): each entry in the
  request's `records` list is imported independently via
  `Letflow.Entities.Records.create_record/2`, unmodified, and the response
  carries a per-entry result rather than an all-or-nothing outcome. See
  `RecordImport.handle_import_records/2`'s own comment for the exact check ordering (the
  200-record cap, then the schema-version gate, then the path/body
  `entity_type` match, all three before any `create_record/2` call).

  ISS-0935 appended `import_restrictions`, `POST /entities/restrictions/import`
  — per `lib/letflow/design/iss0935-vortex-entity-seed.md` §1.3, the first
  write path into `entity_field_restrictions`/`user_entity_grants`
  (REQ-231)/`entity_type_restrictions`/`user_entity_type_grants` (REQ-394),
  all four of which were read-only tables before this. Gated by a NEW,
  distinct permission, `:EntitiesRestrictionsManage` — deliberately not a
  reuse of `:EntitiesDefinitionsWrite` (design §1.3's own justification).
  Delegates to `Letflow.Entities.Restrictions.import_restrictions/2`, the
  one new context module this change adds; `FieldGrants`/`TypeAccess`
  themselves stay read-only and unmodified.

  ## Route ordering — load-bearing, not cosmetic (design §1)

  `Plug.Router` is first-match-wins. `GET /definitions/active/:name` and
  `GET /definitions/by-name/:name` are declared **above**
  `GET /definitions/:id`. Declared below it, the bare `:id` route would match
  first with `id` bound to the literal string `"active"`/`"by-name"`, the
  intended handler never reached, and the request would 404 from a
  non-existent-UUID lookup — with no compile error and no warning anywhere.
  Same hazard class `Letflow.Routers.Definitions`' own moduledoc documents for
  its `/active/:name`/`/search`/`/delta` routes.

  `POST /definitions/:name/activate` is a three-segment path that cannot
  compete with the one-segment `POST /definitions`, and GET/POST/PUT/DELETE
  are independent dispatch tables in `Plug.Router` (so the `/definitions/...`
  GETs never compete with the `/records/...` writes) — but the activate route
  is still declared above `POST /definitions` for readability, matching
  `Letflow.Routers.Definitions`' own precedent.

  ## No route reads a record by id, and none lists records (design §1)

  `Letflow.Entities.Records` is a command-only context module —
  `create_record/2`, `update_record/2`, `delete_record/2` and **no read
  function**. Record reads are exclusively `POST /entities/query`
  (REQ-311); there is deliberately no `GET /entities/records/...` route here
  and no read function was added to `Letflow.Entities.Records` to support one.

  ## INV-1 — the only source of prefix is `conn.assigns.scoped_opts`

  No route below accepts a caller-supplied tenant id, schema name, or slug in
  its path, query string, or body. Every delegate's `prefix` comes from
  `conn.assigns.scoped_opts` (`Letflow.Api.Context.scoped_repo_opts/1`'s
  output, resolved by `Letflow.Plugs.Authorize` from the authenticated
  caller's own token), exactly as `Letflow.Routers.Definitions` and
  `Letflow.Routers.Instances` already do. An actor id comes from
  `conn.assigns.auth_context.user_id`, never from a body or query field.
  This module performs **no `Repo` call of any kind** — every read and write
  happens inside a context module.

  ## INV-2 — `POST /query` redacts on BOTH branches, by two different calls

  Redaction happens before `Letflow.Api.Response.ok/2` ever serialises a
  page, and which redactor runs is decided by `request.join` — the SAME
  field `Letflow.Entities.Query.Compiler.compile/2` itself branches on to
  pick `compile_plain` vs `compile_joined`. Branching on the same input
  makes it structurally impossible for the redactor to disagree with the
  row shape it is redacting.

    * **join-bearing** (`join: [_ | _]`) →
      `Letflow.Entities.Query.FieldGrants.redact_joined_page/2`, given a
      `restriction_sets()` map built from ONE
      `FieldGrants.load_restrictions/3` call per EXPOSED entity type:
      `:primary` for the primary's own type, plus each
      `join_clause().entity_type` keyed by that string. A `through`
      entity's type is deliberately NOT among them — its row is never
      exposed in a `Compiler.joined_row()` (that type's own typedoc), so
      no key of a joined row could ever be looked up against it.
    * **non-join** → `Letflow.Entities.Query.FieldGrants.redact_page/2`,
      given the ONE `restriction_set()` for `request.entity_type`.

  Both branches now call `FieldGrants` directly, and neither redacts
  anything here in the router. ⛔ Keep it that way: a redaction policy
  (what counts as restricted, what the sentinel is) belongs to
  `FieldGrants` alone, and a second copy in a router is how the two
  drift apart.

  ### Build record — the ISS-0600 detour, now closed

  REQ-311 shipped the non-join branch against a router-local
  `redact_plain_page/2` instead, because `FieldGrants.redact_page/2`'s
  private `redact_item/2` matched `%Letflow.Entities.Record.Latest{}`
  only, while `Compiler.compile_plain/5` emits a plain
  `Compiler.entity_row()` MAP whenever the entity type has a promoted
  per-entity-type table — so `redact_page/2` raised `FunctionClauseError`
  on exactly the rows a promoted type produces, surfacing through this
  route as a 500 on a read that must instead be redacted. This route was
  the first caller to reach that gap. REQ-311's scope fence forbade
  touching `lib/letflow/entities/`, so the shape adapter lived here and
  the real gap was filed as **ISS-0600**
  (`docs/issues/ISS-0600.yaml`) against `FieldGrants` itself; both gates
  made filing it a condition of their PASS. ISS-0600's fix has since
  landed: `redact_item/2` now carries a second clause,
  `%{field_values: _} when is_map(item)`, so `redact_page/2` handles both
  row shapes natively. The adapter was deleted and this branch points at
  `redact_page/2` again — same redaction outcome on both shapes, one
  policy owner.

  ## INV-5 — not-found and cross-tenant are the same bytes

  `{:error, :not_found}` from the three definition getters and
  `{:error, {:definition_not_found, _}}`/`{:error, {:record_not_found, _}}`
  from `Letflow.Entities.Records` all fold to `Letflow.Api.Response.not_found/1`,
  which takes no detail — so there is no slot through which a cross-tenant
  probe and a genuinely-absent id could differ. They are the same call on the
  same code path: the prefix-scoped lookup makes another tenant's row
  structurally invisible. **No handler adds a cross-tenant existence
  pre-check** to produce a nicer or more specific message — that would
  reintroduce exactly the "exists but forbidden" signal INV-5 forbids.

  ## INV-8 — every error union is mapped exhaustively

  Each delegate's error union is mapped per design §7, each with a catch-all
  `term() -> 500` clause via `Letflow.Api.Response.internal_error/1` (which
  takes no detail, per INV-4). `:invalid_schema_name` and
  `:tenant_not_provisioned` are unreachable through this router (INV-1 makes
  `prefix` server-resolved only) but are mapped for completeness, the same
  "unreachable but mapped" discipline every other router here already uses.
  `:empty_group`, `:duplicate_artifact_in_group` and
  `{:payload_validation_failed, _}` are unreachable for their own separate
  reasons, each stated at its own clause.

  **No handler catches an exception to produce a 4xx.** A caller-error is
  detected by an explicit check and named; an unexpected exception is left
  to propagate, so it surfaces as a logged, detail-free 500 rather than
  being mis-reported to the caller as a validation failure. See
  `build_definition_document/1`'s own comment for the full statement of why
  (REQ-310 rework round 1, REVIEWER blocker 2).
  """

  use Letflow.Api.AuthorizedRouter

  require Logger

  alias Letflow.Api.Authorization
  alias Letflow.Api.Error
  alias Letflow.Api.Pagination
  alias Letflow.Api.Response
  alias Letflow.Api.ScopeGate
  alias Letflow.Api.Validation
  alias Letflow.Api.Validation.FieldConstraint
  alias Letflow.Api.Validation.FieldError
  alias Letflow.Entities.DefinitionAccess
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Query.Allowlist
  alias Letflow.Entities.Query.Compiler
  alias Letflow.Entities.Query.Cursor
  alias Letflow.Entities.Query.FieldGrants
  alias Letflow.Entities.Query.RequestGuard
  alias Letflow.Entities.Query.Types
  alias Letflow.Entities.Record.Decimals
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.RequestAccess
  alias Letflow.Entities.Restrictions
  alias Letflow.Entities.ScopeResolver
  alias Letflow.Entities.TypeAccess
  alias Letflow.Routers.Entities.RecordAttachments
  alias Letflow.Routers.Entities.RecordImport
  alias Letflow.Routers.Entities.RecordWrites

  import Letflow.Routers.Entities.Support

  # ── Definition write routes ───────────────────────────────────────────
  #
  # "/:name/activate" is a two-segment pattern that cannot collide with the
  # one-segment "/" below regardless of order -- declared above it anyway,
  # matching Letflow.Routers.Definitions' own readability precedent.

  authz_post "/definitions/:name/activate", :EntitiesDefinitionsWrite, scope: :tenant_wide do
    handle_activate_definition(conn, conn.params["name"])
  end

  authz_post "/definitions", :EntitiesDefinitionsWrite, scope: :tenant_wide do
    handle_create_definition(conn)
  end

  # ── Definition read routes ────────────────────────────────────────────
  #
  # ⛔ "/definitions/active/:name" and "/definitions/by-name/:name" MUST stay
  # ABOVE "/definitions/:id" -- see this module's moduledoc "Route ordering".
  # Moving either below the bare :id route silently breaks it with no compile
  # error and no warning.

  authz_get "/definitions/active/:name", :EntitiesDefinitionsRead, scope: :tenant_wide do
    handle_get_active_definition_by_name(conn, conn.params["name"])
  end

  authz_get "/definitions/by-name/:name", :EntitiesDefinitionsRead, scope: :tenant_wide do
    handle_get_definition_by_name(conn, conn.params["name"])
  end

  authz_get "/definitions/:id", :EntitiesDefinitionsRead, scope: :tenant_wide do
    handle_get_definition(conn, conn.params["id"])
  end

  authz_get "/definitions", :EntitiesDefinitionsRead, scope: :tenant_wide do
    handle_list_definitions(conn)
  end

  # ── Record command routes ─────────────────────────────────────────────
  #
  # No GET route under /records exists, by design -- see this module's
  # moduledoc "No route reads a record by id".

  # REQ-518 PR 2c-ii: the record write and attachment routes are `{:resolver, _}` routes (AC 19):
  # their handlers apply the caller's scope through `ScopeGate` (set), `ScopedLookup` (by id) and
  # `ScopedWrites` (type gate, old and new value). `ScopeResolver.record_scope/1` is the exported
  # resolver the route walk requires.

  authz_post "/records/:entity_type",
             :EntitiesRecordsWrite,
             scope: {:resolver, {ScopeResolver, :record_scope}} do
    RecordWrites.handle_create_record(conn, conn.params["entity_type"])
  end

  authz_put "/records/:entity_type/:record_id",
            :EntitiesRecordsWrite,
            scope: {:resolver, {ScopeResolver, :record_scope}} do
    RecordWrites.handle_update_record(conn, conn.params["entity_type"], conn.params["record_id"])
  end

  authz_delete "/records/:entity_type/:record_id",
               :EntitiesRecordsWrite,
               scope: {:resolver, {ScopeResolver, :record_scope}} do
    RecordWrites.handle_delete_record(conn, conn.params["entity_type"], conn.params["record_id"])
  end

  # ── Record import route (REQ-320) ─────────────────────────────────────
  #
  # Sibling of the three record-command routes above, at the same path
  # depth as `POST /records/:entity_type` -- declared after them for
  # readability, matching this module's own listing convention (no ordering
  # hazard: `Plug.Router` position-by-position matching cannot confuse a
  # 3-segment "/records/:entity_type/import" path with the 2-segment
  # "/records/:entity_type" route above it).

  authz_post "/records/:entity_type/import",
             :EntitiesRecordsImport,
             scope: {:resolver, {ScopeResolver, :record_scope}} do
    RecordImport.handle_import_records(conn, conn.params["entity_type"])
  end

  # ── Restriction/grant bulk-import route (ISS-0935) ────────────────────
  #
  # The one write path into entity_field_restrictions/user_entity_grants/
  # entity_type_restrictions/user_entity_type_grants -- see
  # lib/letflow/design/iss0935-vortex-entity-seed.md §1.3 and this module's
  # moduledoc table. Gated by the NEW, distinct :EntitiesRestrictionsManage
  # permission, not a reuse of :EntitiesDefinitionsWrite (design §1.3's own
  # justification). Declared at the same "/restrictions/..." path prefix,
  # a sibling of "/records/..." and "/definitions/..." above -- no ordering
  # hazard with either (distinct first path segment).

  authz_post "/restrictions/import", :EntitiesRestrictionsManage, scope: :tenant_wide do
    handle_import_restrictions(conn)
  end

  # ── Query route ───────────────────────────────────────────────────────
  #
  # POST for a NON-mutating read: the query DSL is an unboundedly nested
  # structure (a list of typed filter clauses, a list of sort clauses, up
  # to four join clauses each with an optional `through`) with no flat
  # query-string encoding in this codebase and no way to express it as
  # repeated ?field=op:value pairs without inventing a mini-language
  # design §4 declines to invent. Gated by the READ permission
  # :EntitiesQuery -- the same read-permission-on-a-POST-route shape
  # Letflow.Routers.Definitions' own POST /definitions/:id/validate uses,
  # for the same reason.

  authz_post "/query", :EntitiesQuery, scope: :filter do
    handle_query(conn)
  end

  # ── Aggregation/reporting query route (REQ-315) ──────────────────────
  #
  # A SIBLING route, not a field on the query DSL above -- design §2's own
  # justification: an aggregate result is not row-shaped (no next_cursor, no
  # per-row redaction), so it gets its own route rather than smuggling a
  # second, structurally incompatible response shape through handle_query/1.
  # Gated by the DISTINCT :EntitiesAggregate permission, not :EntitiesQuery
  # (design §3).

  authz_post "/query/aggregate", :EntitiesAggregate, scope: :filter do
    handle_query_aggregate(conn)
  end

  # ── Record-attachment routes (REQ-317) ────────────────────────────────
  #
  # Nested under the same "/records/:entity_type/:record_id" prefix as the
  # three record-command routes above, but at a strictly greater path depth
  # (3+ segments after "/records" vs. 2) -- design §3 "Route ordering"
  # confirms Plug.Router's position-by-position matching makes an ordering
  # collision with those routes structurally impossible regardless of
  # declaration order. Declared after them anyway, for readability, matching
  # this module's own listing convention.

  authz_post "/records/:entity_type/:record_id/attachments",
             :EntitiesAttachmentsManage,
             scope: {:resolver, {ScopeResolver, :record_scope}} do
    RecordAttachments.handle_create_record_attachment(
      conn,
      conn.params["entity_type"],
      conn.params["record_id"]
    )
  end

  authz_get "/records/:entity_type/:record_id/attachments",
            :EntitiesAttachmentsRead,
            scope: {:resolver, {ScopeResolver, :record_scope}} do
    RecordAttachments.handle_list_record_attachments(
      conn,
      conn.params["entity_type"],
      conn.params["record_id"]
    )
  end

  authz_get "/records/:entity_type/:record_id/attachments/:attachment_id",
            :EntitiesAttachmentsRead,
            scope: {:resolver, {ScopeResolver, :record_scope}} do
    RecordAttachments.handle_get_record_attachment_content(
      conn,
      conn.params["entity_type"],
      conn.params["record_id"],
      conn.params["attachment_id"]
    )
  end

  authz_delete "/records/:entity_type/:record_id/attachments/:attachment_id",
               :EntitiesAttachmentsManage,
               scope: {:resolver, {ScopeResolver, :record_scope}} do
    RecordAttachments.handle_delete_record_attachment(
      conn,
      conn.params["entity_type"],
      conn.params["record_id"],
      conn.params["attachment_id"]
    )
  end

  # ── Bulk record export route (REQ-319) ────────────────────────────────
  #
  # POST for the same reason `POST /query` above is POST, not GET: an
  # unboundedly nested filters/sort/join selection body, no flat
  # query-string encoding in this codebase (design req314 §4). Gated at the
  # ROUTE level by :EntitiesRecordsExport, the base/default,
  # FieldGrants-respecting export permission -- a SECOND, in-handler-only
  # check against :EntitiesRecordsExportUnredacted runs only when the
  # request body carries `unredacted: true` (moduledoc section above,
  # design §6 INV-2). `:EntitiesRecordsExportUnredacted` deliberately has no
  # `endpoint_policy_key/2` clause of its own and could never be declared as
  # this route's OWN policy key -- it is checked a second time, manually,
  # from inside the handler.

  authz_post "/records/:entity_type/export", :EntitiesRecordsExport, scope: :filter do
    handle_export_records(conn, conn.params["entity_type"])
  end

  authz_unmatched(:ordinary)

  # The record command renderer lives in RecordWrites; this delegate keeps it reachable here
  # for the tests that render a record command directly.
  @doc false
  defdelegate render_record_command(conn, result, status, restricted), to: RecordWrites

  # ══ POST /entities/definitions ════════════════════════════════════════
  #
  # Body carries the REQ-225 `Letflow.Entities.Definition.t()` document
  # itself. `created_by` is NEVER read from the body -- it is
  # conn.assigns.auth_context.user_id (INV-1, design §5).

  @create_definition_schema [
    %FieldConstraint{name: "name", required: true, type: :string, reject_empty_string: true},
    %FieldConstraint{
      name: "display_name",
      required: true,
      type: :string,
      reject_empty_string: true
    },
    %FieldConstraint{name: "description", required: false, type: :string},
    %FieldConstraint{name: "fields", required: true, type: :array},
    %FieldConstraint{name: "indexes", required: false, type: :array},
    %FieldConstraint{name: "foreign_keys", required: false, type: :array},
    %FieldConstraint{name: "constraints", required: false, type: :array}
  ]

  defp handle_create_definition(conn) do
    prefix = prefix!(conn)
    actor_id = conn.assigns.auth_context.user_id

    with {:ok, body} <- object_body(conn),
         :ok <- check_definition_type_access(body, actor_id, prefix),
         :ok <- check_definition_body_unmanaged(body, prefix),
         {:ok, _attrs} <- validate_schema(@create_definition_schema, body),
         {:ok, document} <- build_definition_document(body) do
      render_create_definition(
        conn,
        Definitions.create_definition(%{definition: document, created_by: actor_id}, prefix)
      )
    else
      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")

      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))

      {:error, :entity_type_managed} ->
        Response.send_problem(conn, Error.entity_type_managed())

      {:error, :type_denied} ->
        Response.forbidden(conn, "insufficient permissions")

      {:error, :invalid_schema_name} ->
        Response.internal_error(conn)
    end
  end

  # GH #2808: a name TypeAccess hides from the caller is refused with the constant
  # route-level 403 (the bytes of the permission plug), before the managed check and the
  # schema validation. An absent name answers 201, so "denied == absent" cannot hold here.
  # A non-binary or absent `name` skips the check; the existing 422 path answers.
  defp check_definition_type_access(%{"name" => name}, user_id, prefix) when is_binary(name) do
    case DefinitionAccess.create(user_id, name, prefix) do
      :open -> :ok
      :denied -> {:error, :type_denied}
    end
  end

  defp check_definition_type_access(_body, _user_id, _prefix), do: :ok

  # REQ-496 (design §3.2, Revision 1 B1): decided before schema validation, so a
  # managed name gets the uniform 403 whatever else the body holds. A body
  # carrying `managed_by` (any value, null included) is refused outright; a
  # non-binary or absent `name` skips the lookup and the existing 422 path answers.
  defp check_definition_body_unmanaged(%{"managed_by" => _any}, _prefix),
    do: {:error, :entity_type_managed}

  defp check_definition_body_unmanaged(%{"name" => name}, prefix) when is_binary(name),
    do: ManagedTypes.check_tenant_write(name, prefix)

  defp check_definition_body_unmanaged(_body, _prefix), do: :ok

  # `Letflow.Entities.Definition.t()` is an ATOM-keyed document whose `type`
  # members are atoms from closed sets -- but a JSON body decodes
  # string-keyed with string `"type"` values. This transliterates the one
  # into the other and does NOTHING ELSE.
  #
  # ## ⛔ This function is TOTAL: it never raises, and it never rejects
  #
  # It returns a document unconditionally. Judging whether that document is
  # a valid entity definition is `Letflow.Entities.Definition.Validator`'s
  # job alone, reached via `Definitions.create_definition/2` ->
  # `{:error, {:validation, violations}}` -> a 422 carrying the real
  # violation list with a per-field `path`.
  #
  # This replaces (REQ-310 rework round 1, REVIEWER blocker 2) an earlier
  # shape that wrapped the whole builder in a bare `rescue` producing one
  # detail-free `{:error, :invalid_definition_document}` -> 422 with NO
  # `errors` key. That was wrong three ways:
  #
  #   1. Its stated premise -- that the Validator would "silently read as
  #      empty" an unconverted value -- is FALSE. `field_shape_violations/1`
  #      tests `Map.get(field, :type) not in @field_types`, a MEMBERSHIP
  #      test that rejects the raw string `"strng"` exactly as it rejects a
  #      wrong atom; `check_required_list_of_maps/3` likewise already emits
  #      "fields entries must all be maps" for a non-map entry. Every
  #      malformation the rescue was catching already had a real, better
  #      violation waiting one layer down.
  #   2. `String.to_existing_atom/1` raising made the caller's error contract
  #      a function of UNRELATED GLOBAL VM STATE: `"type": "strng"` (no such
  #      atom) got the detail-free 422, while `"type": "ok"` (an atom some
  #      other module happens to have loaded) survived conversion and got a
  #      proper field error. Which error a typo produced depended on whether
  #      it collided with an atom loaded elsewhere in the BEAM.
  #   3. The `rescue` had no clause filter, so it would also have caught a
  #      genuine BUG anywhere in this builder and reported it to the caller
  #      as a 422 caller-validation failure, unlogged -- inverting INV-8,
  #      which requires an internal fault to surface as a detail-free 500 AND
  #      be logged. With no raise left to catch, that inversion is gone: an
  #      unexpected exception now propagates to the pipeline's own error
  #      handler as a logged 500, which is the correct INV-8 behaviour.
  #
  # So the conversions below are gated, not rescued: `closed_set_atom/2`
  # checks membership in a compile-time list FIRST and only then calls
  # `String.to_existing_atom/1`, exactly as `Letflow.Routers.Identity`'s
  # `handle_status_update/3` gates its own status conversion behind a
  # `FieldConstraint`'s `allowed_values` before converting. The atom can
  # therefore never be minted and the call can never raise. A value outside
  # the set is passed through UNCHANGED (still a string), where the
  # Validator's membership test rejects it by name and path.
  @spec build_definition_document(map()) :: {:ok, map()}
  defp build_definition_document(body) do
    document =
      %{
        name: Map.get(body, "name"),
        display_name: Map.get(body, "display_name"),
        fields: map_document_list(body, "fields", &definition_field_document/1)
      }
      |> maybe_put_optional(:description, body, "description")
      |> maybe_put_document_list(:indexes, body, "indexes", &index_document/1)
      |> maybe_put_document_list(:foreign_keys, body, "foreign_keys", &fk_document/1)
      |> maybe_put_document_list(:constraints, body, "constraints", &constraint_document/1)
      |> maybe_put_optional(:append_only, body, "append_only")
      |> maybe_put_optional(:writable_by_process, body, "writable_by_process")

    {:ok, document}
  end

  # The closed sets, duplicated from `Letflow.Entities.Definition`'s
  # `field_type/0` typespec and `constraint_def/0`'s `required(:type) =>
  # :unique` (a typespec cannot be read at runtime) and kept in step with
  # `Letflow.Entities.Definition.Validator`'s own `@field_types`. If they
  # ever drift, the Validator -- not this module -- remains the authority:
  # a type this list omits is passed through as a string and rejected there
  # by name, which is a correct, well-formed error rather than a wrong one.
  @field_type_strings ~w(string integer decimal boolean date datetime enum json localized_text)
  @search_strategy_strings ~w(plain fulltext)
  @constraint_type_strings ~w(unique)

  # `field` is whatever JSON decoded -- possibly not a map at all
  # ("fields": ["not-a-map"]). A non-map entry is returned UNTOUCHED for
  # `check_required_list_of_maps/3` to reject as "fields entries must all be
  # maps"; converting or rejecting it here would replace that precise,
  # path-carrying violation with a vaguer one.
  defp definition_field_document(field) when is_map(field) do
    %{
      name: Map.get(field, "name"),
      type: closed_set_atom(Map.get(field, "type"), @field_type_strings)
    }
    |> maybe_put_optional(:required, field, "required")
    |> maybe_put_optional(:queried, field, "queried")
    |> maybe_put_optional(:enum_values, field, "enum_values")
    |> maybe_put_optional(:decimal_precision, field, "decimal_precision")
    |> maybe_put_optional(:decimal_scale, field, "decimal_scale")
    # GH #2654: opt-in exact decimal strings (decision 0060); false passes through, null is absent.
    |> maybe_put_optional(:decimal_strict, field, "decimal_strict")
    |> maybe_put_optional(:default, field, "default")
    |> maybe_put_optional(:locales, field, "locales")
    # GH #2532: numeric range keys. A JSON null is dropped (absent); any
    # other value passes through unchanged for Validator Rule 12 to judge.
    |> maybe_put_optional(:min, field, "min")
    |> maybe_put_optional(:max, field, "max")
    |> maybe_put_optional(:non_negative, field, "non_negative")
    |> maybe_put_search_strategy(field)
  end

  defp definition_field_document(not_a_map), do: not_a_map

  defp maybe_put_search_strategy(document, field) do
    case Map.get(field, "search_strategy") do
      nil -> document
      raw -> Map.put(document, :search_strategy, closed_set_atom(raw, @search_strategy_strings))
    end
  end

  defp index_document(index) when is_map(index) do
    %{name: Map.get(index, "name"), fields: Map.get(index, "fields")}
    |> maybe_put_optional(:unique, index, "unique")
  end

  defp index_document(not_a_map), do: not_a_map

  defp fk_document(fk) when is_map(fk) do
    %{
      name: Map.get(fk, "name"),
      field: Map.get(fk, "field"),
      references_entity: Map.get(fk, "references_entity")
    }
    |> maybe_put_optional(:references_field, fk, "references_field")
  end

  defp fk_document(not_a_map), do: not_a_map

  defp constraint_document(constraint) when is_map(constraint) do
    %{
      name: Map.get(constraint, "name"),
      type: closed_set_atom(Map.get(constraint, "type"), @constraint_type_strings),
      fields: Map.get(constraint, "fields")
    }
  end

  defp constraint_document(not_a_map), do: not_a_map

  # ⛔ The membership test comes FIRST and is what makes
  # `String.to_existing_atom/1` total here: it is only ever reached with a
  # binary drawn from a compile-time literal list, every member of which is
  # an atom already existing in `Letflow.Entities.Definition.Validator`'s own
  # compiled `@field_types`. A non-member -- or a non-binary, e.g.
  # `"type": 7` -- is returned unchanged for the Validator to reject.
  @spec closed_set_atom(term(), [String.t()]) :: atom() | term()
  defp closed_set_atom(raw, allowed) when is_binary(raw) do
    if raw in allowed, do: String.to_existing_atom(raw), else: raw
  end

  defp closed_set_atom(other, _allowed), do: other

  defp maybe_put_optional(document, atom_key, source, string_key) do
    case Map.get(source, string_key) do
      nil -> document
      value -> Map.put(document, atom_key, value)
    end
  end

  # A non-list `fields`/`indexes`/... is passed through unchanged rather than
  # mapped, so the Validator's own "must be a list" violation is what the
  # caller sees. (`@create_definition_schema`'s `type: :array` constraint
  # already catches this first for a top-level key, but this function does
  # not depend on that having run.)
  defp map_document_list(source, string_key, mapper) do
    case Map.get(source, string_key) do
      entries when is_list(entries) -> Enum.map(entries, mapper)
      other -> other
    end
  end

  defp maybe_put_document_list(document, atom_key, source, string_key, mapper) do
    case Map.get(source, string_key) do
      nil -> document
      _present -> Map.put(document, atom_key, map_document_list(source, string_key, mapper))
    end
  end

  # design §7, create_error(): {:validation, violations} -> 422 with the
  # violation list rendered the same way Letflow.Routers.Definitions'
  # render_validation/2 renders a Graph.Violation; {:persistence, changeset}
  # -> 409 (the (tenant_id, name, logical_shape_version) UNIQUE hit is a
  # duplicate); {:repository, _} -> 500; :invalid_schema_name -> 500
  # (unreachable, INV-1).
  defp render_create_definition(conn, {:ok, %EntityDefinition{} = definition}),
    do: Response.created(conn, definition_map(definition))

  defp render_create_definition(conn, {:error, {:validation, violations}}) do
    Response.send_problem(
      conn,
      %{
        Error.unprocessable("entity definition failed validation")
        | errors: Enum.map(violations, &violation_map/1)
      }
    )
  end

  defp render_create_definition(conn, {:error, {:persistence, %Ecto.Changeset{}}}),
    do:
      Response.conflict(
        conn,
        "an entity definition with this name and logical shape already exists"
      )

  # REQ-496 backstop: the core check in `create_definition/2` (reachable only on a
  # race with a module install).
  defp render_create_definition(conn, {:error, :entity_type_managed}),
    do: Response.send_problem(conn, Error.entity_type_managed())

  defp render_create_definition(conn, {:error, {:repository, reason}}) do
    Logger.warning("entity definition create failed in repository pipeline: #{inspect(reason)}")
    Response.internal_error(conn)
  end

  defp render_create_definition(conn, {:error, _common_error}), do: Response.internal_error(conn)

  # ══ POST /entities/definitions/:name/activate ═════════════════════════
  #
  # activate_definition/4 is (name, activator_user_id, rationale, prefix) --
  # `activator_user_id` is conn.assigns.auth_context.user_id, NEVER a body
  # field (INV-1). `rationale` IS caller-supplied (it is descriptive text
  # recorded against the activation, carrying no authority).
  #
  # ⛔ `rationale` is `required: true`, and that is not a stylistic choice.
  # The delegate chain REJECTS a blank one: `Letflow.Repository.Activation.
  # activate_group/5` feeds it to `Letflow.Repository.ActivationGroup.
  # changeset/2`, whose `validate_required/2` rejects `nil`, `""` and any
  # whitespace-only string (cast/4 collapses all three to `nil`), with a
  # DB-level `CHECK (rationale <> '')` behind it. So an "optional" rationale
  # is not actually optional anywhere below this line -- declaring it
  # optional here and defaulting to `""` (REQ-310 rework round 1, REVIEWER
  # blocker 1) made an omission fail as `{:group, %Ecto.Changeset{}}`, which
  # this module's render clause collapses into an opaque, field-less 422
  # reading "entity definition could not be activated" and logs as an
  # activation failure rather than a validation one.
  #
  # The alternative -- keeping it optional and substituting a non-blank
  # server-side default -- was rejected: `rationale` is REPO-10's free-text
  # JUSTIFICATION requirement (`Letflow.Repository.Activation`'s moduledoc
  # names it the one mandatory field that table has and REQ-195's
  # `audit_entries` does not). Writing a synthesised justification nobody
  # authored into an append-only compliance trail defeats the field's only
  # purpose. `required: true` instead makes an omission take the SAME RFC
  # 9457 field-error path as every other missing required field in this
  # module, naming `rationale`.
  @activate_definition_schema [
    %FieldConstraint{
      name: "rationale",
      required: true,
      type: :string,
      reject_empty_string: true
    }
  ]

  # ⛔ `reject_empty_string`/`required` are NOT sufficient on their own, and
  # this extra check is not belt-and-braces. `Letflow.Api.Validation`'s
  # `reject_empty_string` tests `value == ""` -- an EXACT comparison -- so
  # `{"rationale": "   "}` passes the schema untouched and then fails three
  # layers down in `ActivationGroup.changeset/2` (whose `cast/4` trims and
  # collapses it to `nil`), landing in this module's
  # `{_tag, %Ecto.Changeset{}}` arm as the very same opaque, field-less 422
  # blocker 1 is about. Found by the blank-rationale test below, which
  # reproduced the defect for `"   "` after `""` was already fixed.
  #
  # Trimming here, against the SAME `String.trim/1` semantics `cast/4`
  # applies, is what makes the router's contract match the delegate's: every
  # string the router accepts, the delegate accepts. The emitted
  # `FieldError` is the same struct `Letflow.Api.Validation` itself returns,
  # so it serialises through the identical `Validation.problem/1` path and a
  # caller cannot tell which of the two produced it.
  #
  # GH #2808: `DefinitionAccess.activate/3` is computed FIRST and applied LAST. `:managed` is the
  # constant 403 before the body (visible types only); `:hidden` (denied by TypeAccess) runs the
  # same body validation an absent name runs and then answers the absent 404 instead of calling
  # `Definitions.activate_definition/4`.
  defp handle_activate_definition(conn, name) do
    case DefinitionAccess.activate(
           conn.assigns.auth_context.user_id,
           name,
           prefix!(conn)
         ) do
      :managed -> Response.send_problem(conn, Error.entity_type_managed())
      decision -> activate_definition_with_access(conn, name, decision)
    end
  end

  defp activate_definition_with_access(conn, name, decision) do
    prefix = prefix!(conn)
    actor_id = conn.assigns.auth_context.user_id

    with {:ok, body} <- object_body(conn),
         {:ok, attrs} <- validate_schema(@activate_definition_schema, body),
         {:ok, rationale} <- non_blank_rationale(Map.fetch!(attrs, "rationale")) do
      result =
        case decision do
          :hidden -> {:error, :not_found}
          :open -> Definitions.activate_definition(name, actor_id, rationale, prefix)
        end

      render_activate_definition(conn, result)
    else
      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")

      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))
    end
  end

  # Returns `{:errors, [FieldError.t()]}` -- deliberately the SAME tagged
  # shape `Letflow.Api.Validation.validate/2` returns, so the `with`'s
  # existing `{:errors, field_errors}` else-arm renders it without a
  # dedicated branch and the caller sees one uniform contract. The
  # `constraint`/`message` pair matches what `validate_field/2` itself emits
  # for a required field that is present-but-blank.
  @spec non_blank_rationale(String.t()) :: {:ok, String.t()} | {:errors, [FieldError.t(), ...]}
  defp non_blank_rationale(rationale) do
    if String.trim(rationale) == "" do
      {:errors,
       [
         %FieldError{
           field: "rationale",
           constraint: "required",
           message: "field is required"
         }
       ]}
    else
      {:ok, rationale}
    end
  end

  # design §7, activate_definition/4: :not_found -> 404 (INV-5 -- a name in
  # another tenant's schema takes this exact path); :empty_group /
  # :duplicate_artifact_in_group -> 422; {:group, _} / {:persistence, _} /
  # {atom(), Ecto.Changeset.t()} -> 422 with ONE generic detail, the real
  # reason logged server-side only (the same collapse
  # Letflow.Routers.Definitions.render_activate/2 already applies to a
  # ServiceScopeValidator violation); :invalid_schema_name -> 500.
  #
  # ⛔ :empty_group and :duplicate_artifact_in_group are UNREACHABLE through
  # this route, and no test drives them (REQ-310 rework round 1, REVIEWER).
  # Both are `Letflow.Repository.Activation.activate_group/5`'s own guards on
  # its `activations` LIST, and `Definitions.activate_definition/4` always
  # builds that list as exactly one element -- a single-element list is never
  # empty and can never contain a duplicate. They are mapped here for
  # completeness only, the same "unreachable but mapped, for defence-in-depth
  # / future-readiness" discipline this module's moduledoc states for
  # :invalid_schema_name and Letflow.Routers.Definitions' own handle_activate
  # states for {:service_scope_violation, _}. If a later requirement lets a
  # caller activate several entity definitions as one group, these become
  # reachable and MUST gain tests then.
  defp render_activate_definition(conn, {:ok, %EntityDefinition{} = definition}),
    do: Response.ok(conn, definition_map(definition))

  defp render_activate_definition(conn, {:error, :not_found}), do: Response.not_found(conn)

  defp render_activate_definition(conn, {:error, :empty_group}),
    do: Response.unprocessable(conn, "activation group is empty")

  defp render_activate_definition(conn, {:error, :duplicate_artifact_in_group}),
    do: Response.unprocessable(conn, "activation group names the same artifact twice")

  defp render_activate_definition(conn, {:error, :invalid_schema_name}),
    do: Response.internal_error(conn)

  # GH #2654 (decision 0060): the decimal_strict flag cannot change while the type has
  # records. Fixed message plus the field NAMES (definition metadata, never values).
  defp render_activate_definition(conn, {:error, {:decimal_strict_change, fields}})
       when is_list(fields),
       do:
         Response.conflict(
           conn,
           "decimal_strict cannot change while records exist: " <> Enum.join(fields, ", ")
         )

  defp render_activate_definition(conn, {:error, {_tag, %Ecto.Changeset{}} = reason}) do
    Logger.warning("entity definition activation failed: #{inspect(reason)}")
    Response.unprocessable(conn, "entity definition could not be activated")
  end

  defp render_activate_definition(conn, {:error, _common_error}),
    do: Response.internal_error(conn)

  # ══ GET /entities/definitions/active/:name ════════════════════════════

  defp handle_get_active_definition_by_name(conn, name) do
    render_get_definition(
      conn,
      conn.assigns.auth_context.user_id,
      Definitions.get_active_definition_by_name(name, prefix!(conn))
    )
  end

  # ══ GET /entities/definitions/by-name/:name ═══════════════════════════

  defp handle_get_definition_by_name(conn, name) do
    render_get_definition(
      conn,
      conn.assigns.auth_context.user_id,
      Definitions.get_definition_by_name(name, prefix!(conn))
    )
  end

  # ══ GET /entities/definitions/:id ═════════════════════════════════════
  #
  # `:id` is cast before the delegate call: Definitions.get_definition/2
  # passes it straight to its own repo fetch, which RAISES
  # Ecto.Query.CastError on a non-UUID string rather than returning
  # {:error, :not_found} (unlike Letflow.Definitions.get_by_id/2, which casts
  # internally -- see that module's own OQ-2 note). Casting here
  # collapses malformed-uuid into the SAME zero-detail 404 a
  # well-formed-but-absent id produces -- the stronger INV-5 guarantee, and
  # the reason a mis-ordered "/definitions/active/:name" route (id bound to
  # the literal "active") would 404 rather than 500.

  defp handle_get_definition(conn, raw_id) do
    case Ecto.UUID.cast(raw_id) do
      {:ok, id} ->
        render_get_definition(
          conn,
          conn.assigns.auth_context.user_id,
          Definitions.get_definition(id, prefix!(conn))
        )

      :error ->
        Response.not_found(conn)
    end
  end

  # design §7/REQ-394 design §3.1: {:error, :not_found} -> 404 (INV-5 -- a
  # cross-tenant id and a nonexistent id are the SAME call producing the SAME
  # zero-detail bytes); {:error, :invalid_schema_name} -> 500 (unreachable).
  #
  # REQ-394: the success clause gains a per-type authorization check
  # (design §3.1). `{:ok, :denied}` renders EXACTLY what the
  # `{:error, :not_found}` clause below already renders -- not a new
  # response shape, the existing 404 this route already produces for a
  # genuinely nonexistent name/id (design §3.2 explains why this route
  # reuses 404 rather than the query path's 200-empty shape). The denied
  # branch never reaches `definition_map/1`, so no field of the restricted
  # definition -- including its schema -- is ever serialized (design §3.1's
  # own AC2 note, INV-2).
  @spec render_get_definition(Plug.Conn.t(), user_id :: String.t(), result) :: Plug.Conn.t()
        when result: {:ok, EntityDefinition.t()} | {:error, :not_found | :invalid_schema_name}
  defp render_get_definition(conn, user_id, {:ok, %EntityDefinition{name: name} = definition}) do
    case TypeAccess.authorized?(user_id, name, prefix!(conn)) do
      {:ok, :allowed} -> Response.ok(conn, definition_map(definition))
      {:ok, :denied} -> Response.not_found(conn)
      {:error, _common_error} -> Response.internal_error(conn)
    end
  end

  defp render_get_definition(conn, _user_id, {:error, :not_found}), do: Response.not_found(conn)

  defp render_get_definition(conn, _user_id, {:error, _common_error}),
    do: Response.internal_error(conn)

  # ══ GET /entities/definitions ═════════════════════════════════════════
  #
  # `cursor`/`page_size` are flat query-string parameters, matching every
  # other paginated GET route in this codebase
  # (Letflow.Routers.Definitions.handle_list/1). Response envelope is
  # {"items": [...], "next_cursor": ...} -- no "count" key (design §6).

  defp handle_list_definitions(conn) do
    prefix = prefix!(conn)
    conn = fetch_query_params(conn)
    query = conn.query_params

    case Pagination.parse_page_size_param(Map.get(query, "page_size")) do
      {:ok, page_size} ->
        filters = %{cursor: Map.get(query, "cursor"), page_size: page_size}

        render_list_definitions(
          conn,
          Definitions.list_definitions(conn.assigns.auth_context.user_id, filters, prefix)
        )

      {:error, :invalid_page_size} ->
        Response.bad_request(conn, "invalid page_size")
    end
  end

  # design §7, list_definitions/3: :page_size_too_large/:invalid_cursor/
  # :wrong_endpoint -> 400 (matching render_list_result/2's own identical
  # mapping in Letflow.Routers.Definitions); :expired -> the dedicated
  # cursor-expired problem document every other cursor-consuming route uses;
  # :invalid_schema_name -> 500 (unreachable).
  defp render_list_definitions(conn, {:ok, %{items: items, next_cursor: next_cursor}}) do
    Response.ok(conn, %{
      "items" => Enum.map(items, &definition_map/1),
      "next_cursor" => next_cursor
    })
  end

  defp render_list_definitions(conn, {:error, :page_size_too_large}),
    do: Response.bad_request(conn, "page_size out of range")

  defp render_list_definitions(conn, {:error, :invalid_cursor}),
    do: Response.bad_request(conn, "invalid cursor")

  defp render_list_definitions(conn, {:error, :wrong_endpoint}),
    do: Response.bad_request(conn, "cursor is not valid for this endpoint")

  defp render_list_definitions(conn, {:error, :expired}),
    do: Response.send_problem(conn, Error.cursor_expired())

  defp render_list_definitions(conn, {:error, _common_error}), do: Response.internal_error(conn)

  # ══ POST /entities/restrictions/import (ISS-0935) ═════════════════════
  #
  # Body carries up to four optional arrays -- `field_restrictions`,
  # `field_grants`, `type_restrictions`, `type_grants`
  # (`Letflow.Entities.Restrictions.import_restrictions/2`'s own moduledoc
  # has the full per-row shape/validation contract). The route-level
  # :EntitiesRestrictionsManage check (the `authz_post` macro) is the permission 403;
  # since GH #2808 this handler also emits the SAME constant 403 when any row names an
  # entity type TypeAccess hides from the caller (nothing is written). `actor_id`
  # is read from conn.assigns but not forwarded to the delegate: these rows
  # carry no "created_by" column (design §1.3's table shapes), matching
  # entity_field_restrictions/user_entity_grants' own already-shipped,
  # audit-column-free shape.

  defp handle_import_restrictions(conn) do
    prefix = prefix!(conn)
    user_id = conn.assigns.auth_context.user_id

    with {:ok, body} <- object_body(conn) do
      # GH #2808: any named type TypeAccess hides from the caller (or a failed read) refuses the
      # whole request with the constant 403, before row validation and before any write.
      with {:ok, denied} <-
             TypeAccess.denied_types(user_id, Restrictions.entity_types(body), prefix),
           true <- MapSet.size(denied) == 0 do
        import_restrictions_rows(conn, body, prefix)
      else
        _denied_or_failed -> Response.forbidden(conn, "insufficient permissions")
      end
    else
      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")
    end
  end

  defp import_restrictions_rows(conn, body, prefix) do
    case Restrictions.import_restrictions(body, prefix) do
      {:ok, counts} ->
        Response.ok(conn, %{"inserted" => restrictions_counts_json(counts)})

      {:error, {:invalid_rows, errors}} ->
        Response.unprocessable(conn, restriction_rows_error_detail(errors))
    end
  end

  defp restrictions_counts_json(%{
         field_restrictions: field_restrictions,
         field_grants: field_grants,
         type_restrictions: type_restrictions,
         type_grants: type_grants
       }) do
    %{
      "field_restrictions" => field_restrictions,
      "field_grants" => field_grants,
      "type_restrictions" => type_restrictions,
      "type_grants" => type_grants
    }
  end

  defp restriction_rows_error_detail(errors) do
    detail =
      Enum.map_join(errors, "; ", fn %{table: table, index: index, reason: reason} ->
        "#{table}[#{index}]: #{reason}"
      end)

    "invalid restriction row(s): " <> detail
  end

  # ══ POST /entities/query ══════════════════════════════════════════════
  #
  # The one route in this module that composes several delegate calls
  # rather than fronting one. That is not a router-local business-logic
  # layer: Compiler/Allowlist/Cursor/FieldGrants is the existing
  # REQ-230/231/300 division of labour, and design §1 specifies exactly
  # this sequence -- no new combining context module is introduced.
  #
  # INV-1: `prefix` is prefix!/1's output and NOTHING else; `user_id` is
  # conn.assigns.auth_context.user_id and NOTHING else. A body carrying
  # "tenant_id"/"schema"/"slug"/"prefix"/"user_id" is inert -- those keys
  # are never read anywhere below.

  defp handle_query(conn) do
    user_id = conn.assigns.auth_context.user_id

    case object_body(conn) do
      {:ok, body} ->
        run_query(conn, body, user_id, prefix!(conn))

      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")
    end
  end

  # ⛔ `run_query/4`'s `with` chain IS the composition design §1 specifies,
  # and test/letflow/entities/query_cursor_field_grants_test.exs extracts
  # exactly this chain (comments stripped) to assert its order. Keep the
  # five steps here, in this order.
  #
  # GH #2700 (supersedes REQ-394's after-compile TypeAccess step):
  # `RequestAccess.check/4` runs BEFORE `Compiler.compile/2` and covers the
  # primary type AND every join `entity_type`/`through` -- type denial, then
  # existence of every named type, then the restricted-field guard. A denied
  # type and an absent one are the same `{:error, :entity_type_not_found}`,
  # mapped in the `else` below to the 200-empty envelope (REQ-394 design
  # §2.2) -- deliberately indistinguishable, not a 403/404.
  #
  # `Allowlist.load/2` is called here even though `compile/2` loads one
  # internally, and that is DELIBERATE, not an oversight to optimise away.
  # `Cursor.paginate/5` takes the allowlist as its own third positional
  # argument (it re-resolves every sort field's type/source against it),
  # and `compile/2` does not return the one it built -- threading it out
  # would mean changing `compile/2`'s public signature, which this route
  # has no business doing. The cost is real and is accepted: `load/2`
  # performs a genuine SECOND definition fetch
  # (`Definitions.get_active_definition_by_name/2`) plus its own
  # information_schema column-existence probes. It is idempotent, so the
  # second call agrees with the first, but it is not free.
  @spec run_query(Plug.Conn.t(), map(), String.t(), String.t()) :: Plug.Conn.t()
  defp run_query(conn, body, user_id, prefix) do
    # REQ-518: the caller's allowed node set, read through the ONE gate (`ScopeGate` returns the
    # conn that carries the "scope applied" marker; every response below is sent on it).
    {conn, scope_set} = ScopeGate.scope_set(conn, :EntitiesQuery)

    with {:ok, request} <- build_query_request(body),
         {:ok, opts} <- build_paginate_opts(body),
         {:ok, %{sets: sets}} <-
           RequestAccess.check(%{user_id: user_id, prefix: prefix}, :row, request, %{
             exempt?: false
           }),
         {:ok, compiled} <- Compiler.compile(request, prefix, scope_set),
         {:ok, allowlist, primary_specs} <-
           Allowlist.load(request.entity_type, prefix, :with_specs),
         {:ok, page} <- Cursor.paginate(request, compiled, allowlist, opts, prefix),
         {:ok, redacted} <- redact(page, request, sets) do
      specs = read_specs(request, primary_specs, prefix)

      Response.ok(conn, %{
        "items" => Enum.map(redacted.items, &query_item_map(&1, specs)),
        "next_cursor" => redacted.next_cursor
      })
    else
      # REQ-394 (design §2.2), GH #2700: "the type (or any join target) does
      # not exist" and "the caller is denied by TypeAccess" arrive as the SAME
      # `:entity_type_not_found` and collapse to the SAME 200-empty envelope,
      # on THIS route only. This is a local override of render_query_error/2's
      # own :entity_type_not_found clause (a 404, shared with the aggregate
      # and export routes, whose shipped 404 contract is unchanged).
      {:error, :entity_type_not_found} -> render_type_hidden(conn)
      {:error, reason} -> render_query_error(conn, reason)
    end
  end

  # ══ INV-2 -- the two redaction branches ═══════════════════════════════
  #
  # ⛔ TWO clauses, branching on `request.join` -- the SAME field
  # `Compiler.compile/2` branches on to choose compile_plain vs
  # compile_joined. Not one clause with an optional argument, and not a
  # branch on the page's runtime item shape: deriving the branch from the
  # same input the compiler used is what makes it impossible for the
  # redactor to disagree with the shape it is handed.
  #
  # ⛔ Both clauses delegate to FieldGrants and neither redacts anything
  # here: redact_joined_page/2 for the joined shape, redact_page/2 for the
  # plain one. No redaction policy lives in this module. (A router-local
  # shape adapter stood in for redact_page/2 until ISS-0600's fix gave
  # FieldGrants.redact_item/2 its plain-map clause -- see this module's
  # moduledoc "INV-2" section for that build record.)

  # `request` is typed as the built `Types.query_request()`, not a bare `map()`:
  # this function's branch selection reads `request.join`, and typing it lets
  # dialyzer catch a request assembled without that key rather than deferring
  # the whole class to `Compiler.compile/2`'s runtime rejection (REVIEWER's
  # type-safety note on the REQ-311 rebuild). `run_query/4`'s own second
  # argument stays `map()` because it is the RAW caller body, pre-validation.
  # GH #2697 (design 5.4): the restriction sets come from the request-side
  # guard (`RequestAccess.check/4`, which ends in `FieldPolicy.check_request/4`),
  # keyed by entity type -- ONE load per entity type per request, so the
  # request is refused and the response redacted from one consistent snapshot
  # of the grants. Page shaping stays in FieldGrants; this module keeps no
  # redaction logic. A type-denied request never reaches here (the gate
  # refuses it earlier); a page is never passed through unredacted.
  @spec redact(
          Pagination.Page.t(term()),
          Types.query_request(),
          RequestGuard.restriction_sets()
        ) :: {:ok, Pagination.Page.t(term())}
  defp redact(page, %{join: [_ | _] = joins} = request, sets) when is_map(sets) do
    # One set per EXPOSED entity type: :primary for the primary's own type,
    # plus each join clause's own entity_type. A `through` entity's type is
    # NOT here -- its row never appears as a key of a Compiler.joined_row().
    keyed =
      Enum.reduce(joins, %{primary: Map.fetch!(sets, request.entity_type)}, fn join, acc ->
        Map.put(acc, join.entity_type, Map.fetch!(sets, join.entity_type))
      end)

    {:ok, FieldGrants.redact_joined_page(page, keyed)}
  end

  defp redact(page, request, sets) when is_map(sets) do
    # FieldGrants.redact_page/2 covers BOTH shapes compile_plain/5 can
    # emit -- %Latest{} (unpromoted) and a plain Compiler.entity_row()
    # map (promoted) -- via redact_item/2's two clauses. It has no
    # third, permissive clause: a shape neither matches RAISES (a
    # logged, detail-free 500 via the pipeline's own error handler)
    # rather than falling through UNREDACTED, which is the one failure
    # mode INV-2 cannot tolerate. Do not add a rescue here.
    {:ok, FieldGrants.redact_page(page, Map.fetch!(sets, request.entity_type))}
  end

  # ══ Request parsing (design §4) ═══════════════════════════════════════
  #
  # ⛔ `Types.parse_filter_op/1`/`parse_sort_dir/1` run on the RAW strings
  # HERE, before the Types.query_request() map is built -- so an
  # unrecognised literal is a 400 (malformed primitive) while compile/2's
  # own semantic rejections are 422. A handler that skipped this step and
  # let compile/2 reject the operator would answer 422 to both and
  # collapse design §4's error-class distinction.

  defp build_query_request(body) do
    with {:ok, entity_type} <- query_entity_type(body),
         {:ok, filters} <- parse_filters(Map.get(body, "filters")),
         {:ok, sort} <- parse_sorts(Map.get(body, "sort")),
         {:ok, join} <- parse_joins(Map.get(body, "join")) do
      {:ok, %{entity_type: entity_type, filters: filters, sort: sort, join: join}}
    end
  end

  defp query_entity_type(body) do
    case Map.get(body, "entity_type") do
      entity_type when is_binary(entity_type) and entity_type != "" -> {:ok, entity_type}
      _other -> {:error, {:query_field_invalid, "entity_type"}}
    end
  end

  defp parse_filters(nil), do: {:ok, []}

  defp parse_filters(filters) when is_list(filters) do
    map_while_ok(filters, &parse_filter_clause/1)
  end

  defp parse_filters(_other), do: {:error, {:query_field_invalid, "filters"}}

  defp parse_filter_clause(%{"field" => field, "op" => raw_op} = clause)
       when is_binary(field) and is_binary(raw_op) do
    with {:ok, op} <- Types.parse_filter_op(raw_op) do
      # ⛔ Map.has_key?/2, NOT Map.get/2. `:is_null`/`:is_not_null` carry NO
      # value at all, while `:eq` REQUIRES one -- and `Map.get/2` returns
      # `nil` for both "absent" and "present as JSON null", which would make
      # an omitted `:eq` value indistinguishable from a legitimately-null
      # one and silently hide the {:value_arity_mismatch, _} compile/2
      # rejects it with (design §4, 422).
      if Map.has_key?(clause, "value") do
        {:ok, %{field: field, op: op, value: Map.fetch!(clause, "value")}}
      else
        {:ok, %{field: field, op: op}}
      end
    end
  end

  defp parse_filter_clause(_other), do: {:error, {:query_field_invalid, "filters"}}

  defp parse_sorts(nil), do: {:ok, []}

  defp parse_sorts(sorts) when is_list(sorts), do: map_while_ok(sorts, &parse_sort_clause/1)
  defp parse_sorts(_other), do: {:error, {:query_field_invalid, "sort"}}

  defp parse_sort_clause(%{"field" => field, "dir" => raw_dir})
       when is_binary(field) and is_binary(raw_dir) do
    with {:ok, dir} <- Types.parse_sort_dir(raw_dir) do
      {:ok, %{field: field, dir: dir}}
    end
  end

  defp parse_sort_clause(_other), do: {:error, {:query_field_invalid, "sort"}}

  defp parse_joins(nil), do: {:ok, []}

  defp parse_joins(joins) when is_list(joins), do: map_while_ok(joins, &parse_join_clause/1)
  defp parse_joins(_other), do: {:error, {:query_field_invalid, "join"}}

  # `through` and `type` are optional and only put when present, so
  # `Compiler.check_join_shape/1`'s own Map.has_key? tests see exactly what
  # the caller sent. No parse step of this router's own applies to them --
  # they are entity-type/relation NAMES, resolved by compile/2 against the
  # tenant's own definitions (a wrong one is one of its 422s), not closed
  # atom vocabularies like `op`/`dir`.
  defp parse_join_clause(%{"entity_type" => entity_type, "fk" => fk} = clause)
       when is_binary(entity_type) and is_binary(fk) do
    join =
      %{entity_type: entity_type, fk: fk}
      |> maybe_put_optional(:through, clause, "through")
      |> maybe_put_optional(:type, clause, "type")

    {:ok, join}
  end

  defp parse_join_clause(_other), do: {:error, {:query_field_invalid, "join"}}

  defp map_while_ok(list, mapper) do
    Enum.reduce_while(list, {:ok, []}, fn element, {:ok, acc} ->
      case mapper.(element) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      {:error, _reason} = error -> error
    end
  end

  # `cursor`/`page_size` are Cursor.paginate/5's own paginate_opts() fields,
  # carried FLAT at the top level of the same body (design §4/§6) -- the
  # same shape every other paginated route in this codebase uses for them,
  # differing only in arriving as body fields rather than query params.
  #
  # `page_size` is type-checked HERE because Pagination.validate_page_size/1
  # has clauses for `nil` and positive integers only -- handing it a string
  # or a float from a JSON body would raise FunctionClauseError rather than
  # return its own {:error, :page_size_too_large}.
  defp build_paginate_opts(body) do
    with {:ok, cursor} <- query_cursor(body),
         {:ok, page_size} <- query_page_size(body) do
      {:ok, %{cursor: cursor, page_size: page_size}}
    end
  end

  defp query_cursor(body) do
    case Map.get(body, "cursor") do
      nil -> {:ok, nil}
      cursor when is_binary(cursor) -> {:ok, cursor}
      _other -> {:error, {:query_field_invalid, "cursor"}}
    end
  end

  defp query_page_size(body) do
    case Map.get(body, "page_size") do
      nil -> {:ok, nil}
      page_size when is_integer(page_size) and page_size > 0 -> {:ok, page_size}
      _other -> {:error, {:query_field_invalid, "page_size"}}
    end
  end

  # ══ POST /entities/query/aggregate (REQ-315) ══════════════════════════
  #
  # INV-1: same discipline as handle_query/1 -- `prefix` is prefix!/1's
  # output and NOTHING else; `user_id` is conn.assigns.auth_context.user_id
  # and NOTHING else. A body carrying "tenant_id"/"schema"/"slug"/"prefix"/
  # "user_id" is inert -- those keys are never read anywhere below.
  #
  # ⛔ GH #2700: `RequestAccess.check/4` (kind `:aggregate`) first refuses a
  # type-denied or absent primary/join/through type with the not-found 404,
  # then runs the shared restricted-field walker (INV-2), all BEFORE `Compiler.run_aggregate/2` is ever
  # called, against EVERY field named anywhere in the request -- every
  # aggregate target's `:field`, every `group_by` field, every `filters`
  # field, AND every `join` hop's fk/on field (each governed by the entity
  # that declares it), with NO exemption on this route. A single restricted
  # reference anywhere rejects the WHOLE request with 403, before any query
  # is built. The guard's loaded sets are unused: this route returns no
  # restricted values to redact.

  defp handle_query_aggregate(conn) do
    user_id = conn.assigns.auth_context.user_id

    case object_body(conn) do
      {:ok, body} ->
        run_query_aggregate(conn, body, user_id, prefix!(conn))

      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")
    end
  end

  @spec run_query_aggregate(Plug.Conn.t(), map(), String.t(), String.t()) :: Plug.Conn.t()
  defp run_query_aggregate(conn, body, user_id, prefix) do
    {conn, scope_set} = ScopeGate.scope_set(conn, :EntitiesAggregate)

    with {:ok, request} <- build_aggregate_request(body),
         {:ok, _guard_ok} <-
           RequestAccess.check(
             %{user_id: user_id, prefix: prefix},
             :aggregate,
             request,
             %{exempt?: false}
           ),
         {:ok, rows} <- Compiler.run_aggregate(request, prefix, scope_set) do
      Response.ok(conn, %{"results" => Enum.map(rows, &aggregate_result_map/1)})
    else
      {:error, reason} -> render_aggregate_error(conn, reason)
    end
  end

  # ══ Aggregate request parsing (design §1) ═════════════════════════════
  #
  # Mirrors build_query_request/1's own discipline: every raw string is
  # parsed against a closed enum HERE (never String.to_atom/1 on caller
  # input, INV-7) before the Compiler.aggregate_request() map is built.

  defp build_aggregate_request(body) do
    with {:ok, entity_type} <- query_entity_type(body),
         {:ok, aggregates} <- parse_aggregates(Map.get(body, "aggregates")),
         {:ok, group_by} <- parse_group_by(Map.get(body, "group_by")),
         {:ok, filters} <- parse_filters(Map.get(body, "filters")),
         {:ok, join} <- parse_joins(Map.get(body, "join")) do
      {:ok,
       %{
         entity_type: entity_type,
         aggregates: aggregates,
         group_by: group_by,
         filters: filters,
         join: join
       }}
    end
  end

  defp parse_aggregates(aggregates) when is_list(aggregates) and aggregates != [] do
    map_while_ok(aggregates, &parse_aggregate_target/1)
  end

  defp parse_aggregates(_other), do: {:error, {:query_field_invalid, "aggregates"}}

  defp parse_aggregate_target(%{"fn" => raw_fn} = clause) when is_binary(raw_fn) do
    with {:ok, fn_} <- parse_aggregate_fn(raw_fn) do
      case Map.get(clause, "field") do
        nil -> {:ok, %{fn: fn_}}
        field when is_binary(field) -> {:ok, %{fn: fn_, field: field}}
        _other -> {:error, {:query_field_invalid, "aggregates"}}
      end
    end
  end

  defp parse_aggregate_target(_other), do: {:error, {:query_field_invalid, "aggregates"}}

  defp parse_aggregate_fn("count"), do: {:ok, :count}
  defp parse_aggregate_fn("sum"), do: {:ok, :sum}
  defp parse_aggregate_fn("avg"), do: {:ok, :avg}
  defp parse_aggregate_fn("min"), do: {:ok, :min}
  defp parse_aggregate_fn("max"), do: {:ok, :max}
  defp parse_aggregate_fn(_other), do: {:error, {:query_field_invalid, "aggregates"}}

  defp parse_group_by(nil), do: {:ok, []}

  defp parse_group_by(group_by) when is_list(group_by),
    do: map_while_ok(group_by, &parse_group_by_clause/1)

  defp parse_group_by(_other), do: {:error, {:query_field_invalid, "group_by"}}

  defp parse_group_by_clause(%{"field" => field}) when is_binary(field),
    do: {:ok, %{field: field}}

  defp parse_group_by_clause(_other), do: {:error, {:query_field_invalid, "group_by"}}

  # ══ Aggregate response shaping (design §5) ════════════════════════════
  #
  # Compiler.compile_aggregate/2's own select produces one FLAT map per row,
  # each key prefixed "group__"/"agg__" (compiler.ex's own comment on
  # apply_aggregate_select/3 for why: two namespaces that can never collide,
  # built via one select + select_merge per remaining key). This is the one
  # place that reshapes it into design §5's
  # {"group": {...}, "values": {...}} envelope -- "group" is present only
  # when the request carried group_by, matching design §5 exactly.

  defp aggregate_result_map(row) when is_map(row) do
    {group_pairs, value_pairs} =
      Enum.split_with(row, fn {key, _value} -> String.starts_with?(key, "group__") end)

    values =
      Map.new(value_pairs, fn {key, value} -> {String.replace_prefix(key, "agg__", ""), value} end)

    case group_pairs do
      [] ->
        %{"values" => values}

      _ ->
        group =
          Map.new(group_pairs, fn {key, value} ->
            {String.replace_prefix(key, "group__", ""), value}
          end)

        %{"group" => group, "values" => values}
    end
  end

  # design §2's aggregate_compile_error() union: the three aggregate-specific
  # members map to 422 here; every compile_error() member it inherits, plus
  # every parse-level rejection (query_field_invalid/unknown_operator/
  # unknown_sort_dir), is mapped IDENTICALLY to POST /entities/query's own
  # render_query_error/2 (design §2/§5, "unchanged"). The one member with no
  # row-query analogue at all. A restricted field or join fk is refused by the
  # shared walker (`:request_field_restricted` / `:request_clause_unwalked`),
  # which falls through to render_query_error/2's identical 403.
  defp render_aggregate_error(conn, {:aggregate_field_required, fn_}),
    do: Response.unprocessable(conn, "aggregate function #{inspect(fn_)} requires a field")

  defp render_aggregate_error(conn, {:aggregate_field_not_allowed, fn_}),
    do: Response.unprocessable(conn, "aggregate function #{inspect(fn_)} does not accept a field")

  defp render_aggregate_error(conn, {:aggregate_type_not_valid, fn_, type}),
    do:
      Response.unprocessable(
        conn,
        "aggregate function #{inspect(fn_)} is not valid for a field of type #{inspect(type)}"
      )

  defp render_aggregate_error(conn, reason), do: render_query_error(conn, reason)

  # ══ POST /entities/records/:entity_type/export (REQ-319) ══════════════
  #
  # design req314 §1 (document shape), §2 (selection mechanism), §4 (route
  # shape), §6 FINAL VERDICT (the two-tier default-redacted/escalated-
  # unredacted mechanism -- NOT the original FAILed pass earlier in that
  # document), §7 (size cap).
  #
  # INV-1: `prefix` is prefix!/1's output and NOTHING else; `user_id` is
  # conn.assigns.auth_context.user_id and NOTHING else -- identical
  # discipline to handle_query/1 above.

  @record_export_schema_version "entities/record-export/v1"

  defp handle_export_records(conn, entity_type) do
    user_id = conn.assigns.auth_context.user_id

    case object_body(conn) do
      {:ok, body} ->
        run_export(conn, body, entity_type, user_id, prefix!(conn))

      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")
    end
  end

  # ⛔ THE ORDER BELOW IS THE TWO-TIER MECHANISM ITSELF, not incidental:
  #
  #   1. path-vs-body entity_type match (422) -- cheapest, most structural
  #      check first, before anything else runs (mirrors
  #      ExportImport.import/3's own schema-version-gate-first ordering,
  #      design §7's citation of it).
  #   2. parse `unredacted` (400 if present but not a boolean).
  #   3. IF `unredacted: true`, the second, in-handler
  #      `:EntitiesRecordsExportUnredacted` permission check -- 403
  #      immediately, BEFORE `build_export_query_request/2` or ANY of
  #      Compiler.compile/2, Allowlist.load/2, Cursor.paginate/5 ever runs.
  #      Never a silent fallback to redacted output.
  #   3b. GH #2700: `RequestAccess.check/4` -- a type-denied or absent
  #      primary/join/through type is the route's not-found 404, and
  #      `unredacted: true` never lifts it (it only exempts restricted
  #      FIELDS, step 4 of the gate). No audit row, no log line on denial.
  #   4. Only past all of the above does the identical
  #      Allowlist.load/2 -> Compiler.compile/2 -> Cursor.paginate/5
  #      sequence handle_query/1's own run_query/4 uses run, unmodified.
  #   5. `export_redact/5` -- skips `FieldGrants` entirely when `unredacted?`
  #      is true (already authorized at step 3); otherwise defers to THE
  #      SAME `redact/4` clauses handle_query/1 already uses, no second
  #      redaction policy introduced.
  @spec run_export(Plug.Conn.t(), map(), String.t(), String.t(), String.t()) :: Plug.Conn.t()
  defp run_export(conn, body, path_entity_type, user_id, prefix) do
    {conn, scope_set} = ScopeGate.scope_set(conn, :EntitiesRecordsExport)

    with :ok <- check_export_entity_type_match(body, path_entity_type),
         {:ok, unredacted?} <- parse_unredacted_flag(body),
         :ok <- check_unredacted_permission(conn, unredacted?),
         {:ok, request} <- build_export_query_request(body, path_entity_type),
         {:ok, opts} <- build_export_paginate_opts(body),
         {:ok, guard} <-
           RequestAccess.check(
             %{user_id: user_id, prefix: prefix},
             :row,
             request,
             %{exempt?: unredacted?}
           ),
         {:ok, compiled} <- Compiler.compile(request, prefix, scope_set),
         :ok <- audit_exempted(user_id, path_entity_type, prefix, guard.exempted),
         {:ok, allowlist, primary_specs} <-
           Allowlist.load(request.entity_type, prefix, :with_specs),
         {:ok, page} <- Cursor.paginate(request, compiled, allowlist, opts, prefix),
         {:ok, redacted} <- export_redact(page, request, guard.sets, unredacted?) do
      specs = read_specs(request, primary_specs, prefix)

      Response.ok(conn, %{
        "record_export_schema_version" => @record_export_schema_version,
        "entity_type" => path_entity_type,
        "exported_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "records" => Enum.map(redacted.items, &export_record_map(&1, specs)),
        "next_cursor" => redacted.next_cursor
      })
    else
      {:error, reason} -> render_export_error(conn, reason)
    end
  end

  # design req314 §4: "the document's own entity_type field must match the
  # path segment exactly, or the request is rejected 422 before any
  # create_record/selection call" -- export's own half of that rule. `nil`
  # (the body omits entity_type entirely) is explicitly NOT a mismatch: §2's
  # own "entity_type from the route's own path segment rather than
  # duplicated in the body" phrasing makes the body's copy optional.
  defp check_export_entity_type_match(body, path_entity_type) do
    case Map.get(body, "entity_type") do
      nil -> :ok
      ^path_entity_type -> :ok
      other when is_binary(other) -> {:error, {:entity_type_mismatch, other}}
      _other -> {:error, {:query_field_invalid, "entity_type"}}
    end
  end

  # design §2: "one additional, export-specific optional field ...
  # `unredacted :: boolean()` (default `false`)". A present-but-non-boolean
  # value is a malformed literal, mapped 400 via the SAME
  # {:query_field_invalid, _} -> render_query_error/2 clause build_query_request/1
  # already relies on for its own malformed-literal rejections -- no second
  # error vocabulary for this route.
  defp parse_unredacted_flag(body) do
    case Map.get(body, "unredacted") do
      nil -> {:ok, false}
      flag when is_boolean(flag) -> {:ok, flag}
      _other -> {:error, {:query_field_invalid, "unredacted"}}
    end
  end

  defp check_unredacted_permission(_conn, false), do: :ok

  # design §6 INV-2, the escalation check: `evaluate_access/2` is a pure,
  # two-argument function (`AccessContext.t()`, `endpoint_policy_key()`)
  # with no dependency on route resolution -- nothing requires the atom
  # passed here to be the one `endpoint_policy_key/2` itself would resolve
  # for this route (that atom, `:EntitiesRecordsExport`, was ALREADY checked
  # by `authz_post`'s own `Letflow.Plugs.Authorize` pass before this handler
  # ever ran). The `AccessContext` is built exactly as `Letflow.Plugs.Authorize`
  # itself builds one, from the SAME `conn.assigns.auth_context` -- never a
  # second, divergent identity source.
  defp check_unredacted_permission(conn, true) do
    # REQ-447 PR 2 (design 3.5, OQ-10): the recomputed platform flag is passed
    # and PLATFORM_ADMIN is dropped outside the platform tenant.
    platform_tenant? =
      Letflow.PlatformTenant.platform_tenant?(Map.get(conn.assigns.auth_context, :tenant_id))

    ctx = %Authorization.AccessContext{
      user_id: conn.assigns.auth_context.user_id,
      roles: Authorization.effective_roles(conn.assigns.auth_context.roles, platform_tenant?),
      platform_tenant?: platform_tenant?
    }

    case Authorization.evaluate_access(ctx, :EntitiesRecordsExportUnredacted) do
      %Authorization.AccessDecision{kind: :Deny403} -> {:error, :unredacted_not_authorized}
      %Authorization.AccessDecision{} -> :ok
    end
  end

  # `entity_type` comes from the PATH (already validated against the body's
  # own copy above) -- never re-read from `body` here, so this function has
  # no second, potentially-diverging source for it.
  defp build_export_query_request(body, path_entity_type) do
    with {:ok, filters} <- parse_filters(Map.get(body, "filters")),
         {:ok, sort} <- parse_sorts(Map.get(body, "sort")),
         {:ok, join} <- parse_joins(Map.get(body, "join")) do
      {:ok, %{entity_type: path_entity_type, filters: filters, sort: sort, join: join}}
    end
  end

  # design §2/§7: export is capped at Pagination.max_page_size/0 (200)
  # PER CALL, the same ceiling Cursor.paginate/5 already enforces for
  # `POST /query` (a caller-requested `page_size` above it is still rejected
  # by Cursor.paginate/5 itself, unmodified -- no new cap is introduced
  # here). Unlike `POST /query` (default 50, design's own read-one-page-at-
  # a-time shape), an ABSENT `page_size` here defaults to the full 200-record
  # cap instead -- design §2's "capped ... instead of the caller-chosen
  # page_size the plain query route accepts": export's own purpose is bulk
  # transfer, so its default page is the largest single call already permits,
  # not query's smaller interactive default.
  defp build_export_paginate_opts(body) do
    with {:ok, cursor} <- query_cursor(body),
         {:ok, page_size} <- query_page_size(body) do
      {:ok, %{cursor: cursor, page_size: page_size || Pagination.max_page_size()}}
    end
  end

  # `unredacted? == true` -> FieldGrants is skipped ENTIRELY (already
  # authorized by check_unredacted_permission/2 above) -- full field_values,
  # unredacted. `unredacted? == false` -> defers to THE SAME `redact/4`
  # clauses handle_query/1 already uses (both the join and non-join
  # branches), so default-mode export's disclosure strength is
  # STRUCTURALLY identical to :EntitiesQuery's, not a second, possibly-
  # diverging redaction policy for this route.
  @spec export_redact(
          Pagination.Page.t(term()),
          Types.query_request(),
          RequestGuard.restriction_sets(),
          boolean()
        ) :: {:ok, Pagination.Page.t(term())}
  defp export_redact(page, _request, _sets, true), do: {:ok, page}

  defp export_redact(page, request, sets, false), do: redact(page, request, sets)

  # GH #2697 (design 6): the unredacted-export exemption lets a holder of the
  # exact :EntitiesRecordsExportUnredacted permission filter/sort by a field
  # that is restricted for them (they already read every value in the
  # response). Each exercise is audited with field NAMES only (never filter
  # values), AFTER Compiler.compile/2 succeeded and BEFORE Cursor.paginate/5
  # runs, so a request that would 4xx leaves no row and no query executes
  # without a recorded audit entry. Fail closed: an audit failure refuses the
  # export (detail-free 500). No exempted refs -> no entry.
  @spec audit_exempted(String.t(), String.t(), String.t(), [RequestGuard.field_ref()]) ::
          :ok | {:error, {:export_audit_failed, term()}}
  defp audit_exempted(_user_id, _entity_type, _prefix, []), do: :ok

  defp audit_exempted(user_id, entity_type, prefix, exempted) do
    names = fn clauses ->
      exempted |> Enum.filter(&(&1.clause in clauses)) |> Enum.map(& &1.field) |> Enum.uniq()
    end

    attrs = %{
      actor_id: user_id,
      action: "entities.export.unredacted_restricted_clause",
      resource_type: "entity_type",
      resource_id: entity_type,
      before_state: nil,
      after_state: %{
        "filter_fields" => names.([:filter, :join_on]),
        "sort_fields" => names.([:sort]),
        "restricted_fields_used" => names.([:filter, :sort, :join_on])
      }
    }

    try do
      case Letflow.Audit.insert_entry(Letflow.Repo, attrs, prefix) do
        {:ok, _entry} -> :ok
        {:error, reason} -> {:error, {:export_audit_failed, reason}}
      end
    rescue
      exception -> {:error, {:export_audit_failed, exception}}
    end
  end

  # design §1's export_record_entry(): {record_id, field_values, deleted}
  # only -- no entity_def_version, no last_event_global_seq (unlike
  # query_item_map/1's own entity_row_map/1 above). Three item shapes reach
  # here, same as query_item_map/1: %Latest{} (unpromoted, non-join), a
  # Compiler.entity_row() map (promoted, non-join), and a
  # Compiler.joined_row() map keyed :primary + each joined entity_type
  # (join). A joined row's export entry carries ONLY the primary side's
  # {record_id, field_values, deleted} -- export_record_entry() (design §1)
  # has no per-joined-entity-type slot to carry the far side's own fields in,
  # so a join clause in an export request narrows the selection without
  # widening what gets exported. This is a deliberate, named scope note for
  # this requirement, not a silent behaviour: no acceptance criterion for
  # REQ-319 exercises export with a join, and design req314 nowhere revises
  # export_record_entry()'s own shape to accommodate one.
  defp export_record_map(%Latest{} = record, specs) do
    %{
      "record_id" => record.record_id,
      "field_values" => Decimals.render_field_values(record.field_values, specs.primary),
      "deleted" => record.deleted
    }
  end

  defp export_record_map(%{field_values: _field_values} = entity_row, specs) do
    %{
      "record_id" => entity_row.record_id,
      "field_values" => Decimals.render_field_values(entity_row.field_values, specs.primary),
      "deleted" => entity_row.deleted
    }
  end

  defp export_record_map(joined_row, specs) when is_map(joined_row) do
    export_record_map(Map.fetch!(joined_row, :primary), specs)
  end

  # design §6/§7 error mapping: the two NEW error atoms this route
  # introduces get their own clauses; every compile_error()/Cursor error/
  # parse-level rejection this route can ALSO produce (identical pipeline to
  # `POST /query`) falls through to render_query_error/2 UNCHANGED -- no
  # second copy of that mapping.
  defp render_export_error(conn, {:entity_type_mismatch, _body_entity_type}),
    do: Response.unprocessable(conn, "entity_type in the request body does not match the path")

  defp render_export_error(conn, :unredacted_not_authorized),
    do:
      Response.forbidden(
        conn,
        "unredacted export requires a separate, independently-granted permission"
      )

  defp render_export_error(conn, {:export_audit_failed, reason}) do
    # Log only the failure class/tag, never the term (it can carry changeset data).
    tag =
      case reason do
        %{__exception__: true, __struct__: module} -> inspect(module)
        {tag, _} when is_atom(tag) -> inspect(tag)
        atom when is_atom(atom) -> inspect(atom)
        _other -> "unknown"
      end

    Logger.error("unredacted export audit entry failed: #{tag}")
    Response.internal_error(conn)
  end

  defp render_export_error(conn, reason), do: render_query_error(conn, reason)

  # ══ Query error mapping (design §4) ═══════════════════════════════════
  #
  # Both unions this route can return are mapped exhaustively, terminating
  # in a logged, detail-free 500 catch-all (INV-8).
  #
  # compile_error(), all 15 members:
  #   :entity_type_not_found              -> 404 (INV-5) via THIS clause, for every
  #                                          caller of render_query_error/2 (aggregate,
  #                                          export). REQ-394 (design §2.2) changes this
  #                                          to 200 {"items":[],"next_cursor":null} for
  #                                          POST /entities/query ONLY -- handled locally
  #                                          in run_query/4's own `with`/`else`, before
  #                                          this shared function is ever reached for that
  #                                          reason on that route.
  #   {:unknown_operator, _}              -> 400 (pre-parsed above; mapped)
  #   {:unknown_sort_dir, _}              -> 400 (pre-parsed above; mapped)
  #   {:field_not_allowed, _}             -> 422
  #   {:value_arity_mismatch, _}          -> 422
  #   {:invalid_in_value, _}              -> 422
  #   {:invalid_decimal_value, _}         -> 422 (GH #2654; a strict decimal field, constant body)
  #   {:operator_not_valid_for_type,_,_}  -> 422
  #   :entity_table_not_found             -> 422
  #   {:too_many_joins, _}                -> 422
  #   :join_depth_exceeded                -> 422
  #   {:no_through_relation, _, _}        -> 422
  #   {:ambiguous_through_relation, _}    -> 422
  #   {:duplicate_join_target, _}         -> 422
  #   {:relation_column_not_found, _, _}  -> 422
  #   :invalid_schema_name                -> 500 (unreachable, INV-1)
  #
  # GH #2700: a TypeAccess denial is NOT a distinct reason -- it arrives as
  # `:entity_type_not_found` from RequestAccess.check/4, so aggregate and
  # export render it with the 404 clause below; run_query/4 maps it locally
  # to the 200 {"items":[],"next_cursor":null} envelope.
  #
  # Cursor.paginate/5's own union:
  #   :page_size_too_large / :invalid_cursor / :wrong_endpoint /
  #   :resume_key_arity_mismatch          -> 400
  #   :expired                            -> the dedicated cursor-expired
  #                                          problem document
  #   {:field_not_allowed, _}             -> 422 (shared clause above)

  # GH #2697: ONE refusal for every restricted-field position and for an
  # unwalked request clause -- same status, same detail as the aggregate
  # route's, and never a field, entity type or clause name.
  defp render_query_error(conn, reason)
       when reason in [:request_field_restricted, :request_clause_unwalked],
       do: restricted_fields_refusal(conn)

  defp render_query_error(conn, {:query_field_invalid, field}),
    do: Response.bad_request(conn, "#{field} is missing or malformed")

  defp render_query_error(conn, {:unknown_operator, raw}),
    do: Response.bad_request(conn, "unknown filter operator: #{inspect(raw)}")

  defp render_query_error(conn, {:unknown_sort_dir, raw}),
    do: Response.bad_request(conn, "unknown sort direction: #{inspect(raw)}")

  # NOTE (REQ-394): this clause stays a plain 404 -- render_query_error/2 is
  # shared by render_aggregate_error/2 and render_export_error/2's own
  # fallthrough clauses, and REQ-394's design only changes this reason's
  # handling for POST /entities/query specifically (handled locally in
  # run_query/4's own `with`/`else`, not here) -- see that function's
  # comment for the full reasoning.
  defp render_query_error(conn, :entity_type_not_found), do: Response.not_found(conn)

  defp render_query_error(conn, {:field_not_allowed, field}),
    do: Response.unprocessable(conn, "field is not queryable: #{inspect(field)}")

  defp render_query_error(conn, {:value_arity_mismatch, op}),
    do: Response.unprocessable(conn, "wrong value arity for operator #{inspect(op)}")

  defp render_query_error(conn, {:invalid_in_value, field}),
    do: Response.unprocessable(conn, "value must be a list for field #{inspect(field)}")

  defp render_query_error(conn, {:invalid_decimal_value, field}),
    do:
      Response.unprocessable(
        conn,
        "value must be a decimal string or an integer for field #{inspect(field)}"
      )

  defp render_query_error(conn, {:operator_not_valid_for_type, op, type}),
    do:
      Response.unprocessable(
        conn,
        "operator #{inspect(op)} is not valid for a field of type #{inspect(type)}"
      )

  defp render_query_error(conn, :entity_table_not_found),
    do: Response.unprocessable(conn, "entity type has no queryable table for this request")

  defp render_query_error(conn, {:too_many_joins, count}),
    do: Response.unprocessable(conn, "too many joins: #{count}")

  defp render_query_error(conn, :join_depth_exceeded),
    do: Response.unprocessable(conn, "a join clause may not itself carry a join")

  defp render_query_error(conn, {:no_through_relation, through, primary}),
    do:
      Response.unprocessable(
        conn,
        "no relation from #{inspect(through)} to #{inspect(primary)}"
      )

  defp render_query_error(conn, {:ambiguous_through_relation, through}),
    do: Response.unprocessable(conn, "ambiguous through relation: #{inspect(through)}")

  defp render_query_error(conn, {:duplicate_join_target, entity_type}),
    do: Response.unprocessable(conn, "duplicate join target: #{inspect(entity_type)}")

  defp render_query_error(conn, {:relation_column_not_found, entity_type, column}),
    do:
      Response.unprocessable(
        conn,
        "relation column #{inspect(column)} is not available on #{inspect(entity_type)}"
      )

  defp render_query_error(conn, :page_size_too_large),
    do: Response.bad_request(conn, "page_size out of range")

  defp render_query_error(conn, :invalid_cursor), do: Response.bad_request(conn, "invalid cursor")

  defp render_query_error(conn, :wrong_endpoint),
    do: Response.bad_request(conn, "cursor is not valid for this endpoint")

  defp render_query_error(conn, :resume_key_arity_mismatch),
    do: Response.bad_request(conn, "cursor does not match this request's sort clause")

  defp render_query_error(conn, :expired), do: Response.send_problem(conn, Error.cursor_expired())

  # INV-8 terminal catch-all: :invalid_schema_name (unreachable -- INV-1
  # makes prefix server-resolved) and any term() no clause above names.
  # Logged server-side, detail-free on the wire.
  defp render_query_error(conn, reason) do
    Logger.warning("entity query failed: #{inspect(reason)}")
    Response.internal_error(conn)
  end

  # Shared by both render_query_error/2 clauses above so they cannot drift
  # apart in body shape over time -- one function, two call sites (design
  # §2.2).
  defp render_type_hidden(conn), do: Response.ok(conn, %{"items" => [], "next_cursor" => nil})

  # ══ Query response allowlist (INV-2) ══════════════════════════════════
  #
  # Three item shapes reach here: a %Latest{} struct (unpromoted, non-join),
  # a Compiler.entity_row() map (promoted, non-join), and a
  # Compiler.joined_row() map keyed :primary + each joined entity_type
  # (join). The joined clause is matched FIRST -- a joined_row() has no
  # :field_values key of its own, so an entity-row clause could never match
  # it, but ordering it first states the intent rather than relying on that.

  defp query_item_map(%Latest{} = record, specs), do: record_map(record, specs.primary)

  defp query_item_map(%{field_values: _field_values} = entity_row, specs),
    do: entity_row_map(entity_row, specs.primary)

  defp query_item_map(joined_row, specs) when is_map(joined_row) do
    Map.new(joined_row, fn {key, entity_row} ->
      {joined_key_string(key), entity_row_map(entity_row, joined_specs(specs, key))}
    end)
  end

  defp joined_specs(specs, :primary), do: specs.primary
  defp joined_specs(specs, entity_type), do: Map.get(specs.joined, entity_type, %{})

  # GH #2654 (design 2.6): the strict decimal specs for a read response come from the ACTIVE
  # DEFINITION of each exposed entity type (the primary and every join target), never from the
  # query allowlist: a strict field that is not queried must still be rendered. One lookup per
  # distinct type per request; `%{}` (a no-op renderer) when the type has no strict field or has
  # no active definition.
  #
  # GH #2773: the primary's specs arrive from `Allowlist.load/3` (the definition row it already
  # read for the allowlist); the router reads only the join targets, once per distinct type other
  # than the primary.
  defp read_specs(request, primary_specs, prefix) do
    joined_types =
      request
      |> Map.get(:join, [])
      |> Enum.map(& &1.entity_type)
      |> Enum.uniq()

    %{
      primary: primary_specs,
      joined:
        Map.new(joined_types, fn
          entity_type when entity_type == request.entity_type -> {entity_type, primary_specs}
          entity_type -> {entity_type, strict_specs_for(entity_type, prefix)}
        end)
    }
  end

  defp joined_key_string(:primary), do: "primary"
  defp joined_key_string(entity_type) when is_binary(entity_type), do: entity_type

  # Same allowlist record_map/1 applies to a %Latest{}, so a promotion is
  # not observable in a response body. `Compiler.select_entity_row/1`
  # (and the joined-select equivalents) now cast `record_id` to a real
  # `String.t()` at the query source (ISS-0652) -- it is always a string
  # here regardless of whether this row came from `entity_record_latest`
  # or a promoted per-type table, so no local normalisation is needed.
  defp entity_row_map(entity_row, specs) do
    %{
      "record_id" => entity_row.record_id,
      "field_values" => Decimals.render_field_values(entity_row.field_values, specs),
      "deleted" => entity_row.deleted,
      "entity_def_version" => encode_entity_def_version(entity_row.entity_def_version),
      "last_event_global_seq" => entity_row.last_event_global_seq
    }
  end

  defp encode_entity_def_version(nil), do: nil

  defp encode_entity_def_version(version) when is_binary(version),
    do: Base.encode16(version, case: :lower)

  # ══ Response allowlists (INV-2) ═══════════════════════════════════════

  @spec definition_map(EntityDefinition.t()) :: map()
  defp definition_map(%EntityDefinition{} = definition) do
    %{
      "id" => definition.id,
      "name" => definition.name,
      "display_name" => definition.display_name,
      "definition" => definition.definition_json,
      "content_hash" => Base.encode16(definition.content_hash, case: :lower),
      "logical_shape_version" => Base.encode16(definition.logical_shape_version, case: :lower),
      "artifact_version_id" => definition.artifact_version_id,
      "status" => Atom.to_string(definition.status),
      "inserted_at" => DateTime.to_iso8601(definition.inserted_at)
    }
  end
end
