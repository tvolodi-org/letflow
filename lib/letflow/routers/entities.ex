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
  around `compile_aggregate/2` plus the query's own execution, added
  specifically so this route stays composition-only, same as every other
  route here — this module executes no query of its own (INV-1, below).
  REQ-317 appended a twelfth-through-fifteenth set of rows, the four
  record-attachment routes, per
  `lib/letflow/design/req313-entity-record-attachments.md` §3 — delegating
  to `Letflow.Repository.EntityAttachments` (REQ-316), mirroring
  `Letflow.Routers.Instances`' own REQ-212 instance-attachment routes.

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

  | Handler | Method/path | Delegate | Permission | Response |
  |---|---|---|---|---|
  | create_definition | `POST /entities/definitions` | `Letflow.Entities.Definitions.create_definition/2` | `EntitiesDefinitionsWrite` | 201 / 422 / 409 |
  | activate_definition | `POST /entities/definitions/:name/activate` | `Letflow.Entities.Definitions.activate_definition/4` | `EntitiesDefinitionsWrite` | 200 / 404 / 422 |
  | get_active_definition_by_name | `GET /entities/definitions/active/:name` | `Letflow.Entities.Definitions.get_active_definition_by_name/2` | `EntitiesDefinitionsRead` | 200 / 404 |
  | get_definition_by_name | `GET /entities/definitions/by-name/:name` | `Letflow.Entities.Definitions.get_definition_by_name/2` | `EntitiesDefinitionsRead` | 200 / 404 |
  | get_definition | `GET /entities/definitions/:id` | `Letflow.Entities.Definitions.get_definition/2` | `EntitiesDefinitionsRead` | 200 / 404 |
  | list_definitions | `GET /entities/definitions` | `Letflow.Entities.Definitions.list_definitions/2` | `EntitiesDefinitionsRead` | 200 / 400 |
  | create_record | `POST /entities/records/:entity_type` | `Letflow.Entities.Records.create_record/2` | `EntitiesRecordsWrite` | 201 / 404 / 422 (422 also `idempotency_key_reuse`, GH #2543) |
  | update_record | `PUT /entities/records/:entity_type/:record_id` | `Letflow.Entities.Records.update_record/2` | `EntitiesRecordsWrite` | 200 / 404 / 409 / 422 (422 also `idempotency_key_reuse`, GH #2543) |
  | delete_record | `DELETE /entities/records/:entity_type/:record_id` | `Letflow.Entities.Records.delete_record/2` | `EntitiesRecordsWrite` | 200 / 400 / 404 / 409 / 422 (a fresh key per request, so never `idempotency_key_reuse`) |
  | query | `POST /entities/query` | `Letflow.Entities.Query.Compiler.compile/2` then `Letflow.Entities.Query.Allowlist.load/2` then `Letflow.Entities.Query.Cursor.paginate/5` then a `Letflow.Entities.Query.FieldGrants` redaction step | `EntitiesQuery` | 200 / 400 / 404 / 422 |
  | query_aggregate | `POST /entities/query/aggregate` | a `Letflow.Entities.Query.FieldGrants.load_restrictions/3` field-restriction check then `Letflow.Entities.Query.Compiler.run_aggregate/2` | `EntitiesAggregate` | 200 / 400 / 403 / 404 / 422 |
  | create_record_attachment | `POST /entities/records/:entity_type/:record_id/attachments` | `Letflow.Repository.EntityAttachments.upload/2` | `EntitiesAttachmentsManage` | 201 / 404 / 422 |
  | list_record_attachments | `GET /entities/records/:entity_type/:record_id/attachments` | `Letflow.Repository.EntityAttachments.list/2` | `EntitiesAttachmentsRead` | 200 / 400 / 404 |
  | get_record_attachment_content | `GET /entities/records/:entity_type/:record_id/attachments/:attachment_id` | `Letflow.Repository.EntityAttachments.get_content/2` | `EntitiesAttachmentsRead` | 200 (raw bytes) / 404 / 500 |
  | delete_record_attachment | `DELETE /entities/records/:entity_type/:record_id/attachments/:attachment_id` | `Letflow.Repository.EntityAttachments.delete/2` | `EntitiesAttachmentsManage` | 204 / 404 |
  | export_records | `POST /entities/records/:entity_type/export` | the identical `Letflow.Entities.Query.Allowlist.load/2` → `Letflow.Entities.Query.Compiler.compile/2` → `Letflow.Entities.Query.Cursor.paginate/5` sequence `query` uses above, then EITHER a `Letflow.Entities.Query.FieldGrants` redaction step (default) OR a second, in-handler `Letflow.Api.Authorization.evaluate_access/2` check against `:EntitiesRecordsExportUnredacted` that skips redaction entirely on success (`unredacted: true`) | `EntitiesRecordsExport` (route-level); `EntitiesRecordsExportUnredacted` (in-handler only, see below) | 200 / 400 / 403 / 404 / 422 |
  | import_records | `POST /entities/records/:entity_type/import` | `Letflow.Entities.Records.create_record/2` per entry (REQ-320) | `EntitiesRecordsImport` | 200 / 404 / 413 / 422 |
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
  `handle_import_records/2`'s own comment for the exact check ordering (the
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
  alias Letflow.Api.Validation
  alias Letflow.Api.Validation.FieldConstraint
  alias Letflow.Api.Validation.FieldError
  alias Letflow.Entities.Definition.Validator.Violation, as: DefinitionViolation
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.Query.Allowlist
  alias Letflow.Entities.Query.Compiler
  alias Letflow.Entities.Query.Cursor
  alias Letflow.Entities.Query.FieldGrants
  alias Letflow.Entities.Query.Types
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.Entities.Restrictions
  alias Letflow.Entities.TypeAccess
  alias Letflow.EventStore.Registry.ValidationFailure
  alias Letflow.Repository.Artifact
  alias Letflow.Repository.EntityAttachment
  alias Letflow.Repository.EntityAttachments

  # ── Definition write routes ───────────────────────────────────────────
  #
  # "/:name/activate" is a two-segment pattern that cannot collide with the
  # one-segment "/" below regardless of order -- declared above it anyway,
  # matching Letflow.Routers.Definitions' own readability precedent.

  authz_post "/definitions/:name/activate", :EntitiesDefinitionsWrite do
    handle_activate_definition(conn, conn.params["name"])
  end

  authz_post "/definitions", :EntitiesDefinitionsWrite do
    handle_create_definition(conn)
  end

  # ── Definition read routes ────────────────────────────────────────────
  #
  # ⛔ "/definitions/active/:name" and "/definitions/by-name/:name" MUST stay
  # ABOVE "/definitions/:id" -- see this module's moduledoc "Route ordering".
  # Moving either below the bare :id route silently breaks it with no compile
  # error and no warning.

  authz_get "/definitions/active/:name", :EntitiesDefinitionsRead do
    handle_get_active_definition_by_name(conn, conn.params["name"])
  end

  authz_get "/definitions/by-name/:name", :EntitiesDefinitionsRead do
    handle_get_definition_by_name(conn, conn.params["name"])
  end

  authz_get "/definitions/:id", :EntitiesDefinitionsRead do
    handle_get_definition(conn, conn.params["id"])
  end

  authz_get "/definitions", :EntitiesDefinitionsRead do
    handle_list_definitions(conn)
  end

  # ── Record command routes ─────────────────────────────────────────────
  #
  # No GET route under /records exists, by design -- see this module's
  # moduledoc "No route reads a record by id".

  authz_post "/records/:entity_type", :EntitiesRecordsWrite do
    handle_create_record(conn, conn.params["entity_type"])
  end

  authz_put "/records/:entity_type/:record_id", :EntitiesRecordsWrite do
    handle_update_record(conn, conn.params["entity_type"], conn.params["record_id"])
  end

  authz_delete "/records/:entity_type/:record_id", :EntitiesRecordsWrite do
    handle_delete_record(conn, conn.params["entity_type"], conn.params["record_id"])
  end

  # ── Record import route (REQ-320) ─────────────────────────────────────
  #
  # Sibling of the three record-command routes above, at the same path
  # depth as `POST /records/:entity_type` -- declared after them for
  # readability, matching this module's own listing convention (no ordering
  # hazard: `Plug.Router` position-by-position matching cannot confuse a
  # 3-segment "/records/:entity_type/import" path with the 2-segment
  # "/records/:entity_type" route above it).

  authz_post "/records/:entity_type/import", :EntitiesRecordsImport do
    handle_import_records(conn, conn.params["entity_type"])
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

  authz_post "/restrictions/import", :EntitiesRestrictionsManage do
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

  authz_post "/query", :EntitiesQuery do
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

  authz_post "/query/aggregate", :EntitiesAggregate do
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

  authz_post "/records/:entity_type/:record_id/attachments", :EntitiesAttachmentsManage do
    handle_create_record_attachment(conn, conn.params["entity_type"], conn.params["record_id"])
  end

  authz_get "/records/:entity_type/:record_id/attachments", :EntitiesAttachmentsRead do
    handle_list_record_attachments(conn, conn.params["entity_type"], conn.params["record_id"])
  end

  authz_get "/records/:entity_type/:record_id/attachments/:attachment_id",
            :EntitiesAttachmentsRead do
    handle_get_record_attachment_content(
      conn,
      conn.params["entity_type"],
      conn.params["record_id"],
      conn.params["attachment_id"]
    )
  end

  authz_delete "/records/:entity_type/:record_id/attachments/:attachment_id",
               :EntitiesAttachmentsManage do
    handle_delete_record_attachment(
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

  authz_post "/records/:entity_type/export", :EntitiesRecordsExport do
    handle_export_records(conn, conn.params["entity_type"])
  end

  authz_unmatched(:ordinary)

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
    end
  end

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
    |> maybe_put_optional(:default, field, "default")
    |> maybe_put_optional(:locales, field, "locales")
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
  defp handle_activate_definition(conn, name) do
    prefix = prefix!(conn)
    actor_id = conn.assigns.auth_context.user_id

    with {:ok, body} <- object_body(conn),
         {:ok, attrs} <- validate_schema(@activate_definition_schema, body),
         {:ok, rationale} <- non_blank_rationale(Map.fetch!(attrs, "rationale")) do
      render_activate_definition(
        conn,
        Definitions.activate_definition(name, actor_id, rationale, prefix)
      )
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
        render_list_definitions(conn, Definitions.list_definitions(filters, prefix))

      {:error, :invalid_page_size} ->
        Response.bad_request(conn, "invalid page_size")
    end
  end

  # design §7, list_definitions/2: :page_size_too_large/:invalid_cursor/
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

  # ══ POST /entities/records/:entity_type ═══════════════════════════════
  #
  # create_record/2's create_attrs() is
  # %{entity_type, field_values, actor_id, idempotency_key} -- `entity_type`
  # comes from the PATH segment (never a body field), `actor_id` from
  # conn.assigns.auth_context.user_id (INV-1), `idempotency_key` from the
  # body when the caller supplies one (the caller's own replay token, bound
  # to (command, entity_type, record_id, field_values, actor) -- GH #2543)
  # and otherwise freshly minted so the delegate's
  # required key is always present.

  @record_write_schema [
    %FieldConstraint{name: "field_values", required: true, type: :object},
    %FieldConstraint{
      name: "idempotency_key",
      required: false,
      type: :string,
      reject_empty_string: true
    }
  ]

  defp handle_create_record(conn, entity_type) do
    prefix = prefix!(conn)

    with {:ok, body} <- object_body(conn),
         {:ok, attrs} <- validate_schema(@record_write_schema, body) do
      command_attrs = %{
        entity_type: entity_type,
        field_values: Map.fetch!(attrs, "field_values"),
        actor_id: conn.assigns.auth_context.user_id,
        idempotency_key: idempotency_key(attrs)
      }

      render_record_command(conn, Records.create_record(command_attrs, prefix), :created)
    else
      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")

      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))
    end
  end

  # ══ PUT /entities/records/:entity_type/:record_id ═════════════════════
  #
  # Full replacement of `field_values` (update_record/2's own whole-document
  # semantics).
  #
  # GH #2528: PUT alone accepts the optional `expected_last_event_global_seq`
  # (POST keeps @record_write_schema byte-for-byte). `type: :integer` rejects
  # 1.0 / "5" / true with 422; JSON null arrives as nil, which the domain
  # treats as absent. `max_value` keeps a JSON bignum away from Postgrex's
  # int8 encoder (INV-8). The value is passed through untouched -- no cast.
  # `If-Match` stays ignored.
  #
  # GH #2529: an append-only entity type gives 422 entity-append-only for any
  # record id (the domain refuses before the record lookup, INV-5).

  @max_int8 9_223_372_036_854_775_807

  @record_update_schema @record_write_schema ++
                          [
                            %FieldConstraint{
                              name: "expected_last_event_global_seq",
                              required: false,
                              type: :integer,
                              min_value: 0,
                              max_value: @max_int8
                            }
                          ]

  defp handle_update_record(conn, entity_type, raw_record_id) do
    prefix = prefix!(conn)

    with {:ok, record_id} <- cast_record_id(raw_record_id),
         {:ok, body} <- object_body(conn),
         {:ok, attrs} <- validate_schema(@record_update_schema, body) do
      command_attrs = %{
        entity_type: entity_type,
        record_id: record_id,
        field_values: Map.fetch!(attrs, "field_values"),
        actor_id: conn.assigns.auth_context.user_id,
        idempotency_key: idempotency_key(attrs),
        expected_last_event_global_seq: Map.get(attrs, "expected_last_event_global_seq")
      }

      render_record_command(conn, Records.update_record(command_attrs, prefix), :ok)
    else
      # INV-5: a malformed record id takes the same zero-detail 404 a
      # well-formed-but-absent (or cross-tenant) one takes.
      {:error, :invalid_record_id} ->
        Response.not_found(conn)

      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")

      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))
    end
  end

  # ══ DELETE /entities/records/:entity_type/:record_id ══════════════════
  #
  # Bodyless. delete_record/2 treats an already-deleted record as a no-op
  # success (its own documented domain-level idempotency), so
  # {:record_already_deleted, _} is unreachable through this route (still
  # mapped below, on the shared renderer, for completeness). A 409 IS
  # reachable (GH #2528): an optional
  # `?expected_last_event_global_seq=<n>` query param that no longer matches
  # the stored row gives 409 record-version-conflict. An invalid value is a
  # 400 (query-string errors are 400 in this router, like `page_size`),
  # checked after the record id cast (malformed id -> 404 first) and before
  # any lookup, so it does not depend on record existence (INV-5).
  # GH #2529: an append-only entity type gives 422 entity-append-only for any
  # record id, live, deleted or absent (refused before the record lookup).

  defp handle_delete_record(conn, entity_type, raw_record_id) do
    with {:ok, record_id} <- cast_record_id(raw_record_id),
         conn = fetch_query_params(conn),
         {:ok, expected} <-
           parse_expected_seq_param(Map.get(conn.query_params, "expected_last_event_global_seq")) do
      command_attrs = %{
        entity_type: entity_type,
        record_id: record_id,
        actor_id: conn.assigns.auth_context.user_id,
        idempotency_key: Ecto.UUID.generate(),
        expected_last_event_global_seq: expected
      }

      render_record_command(conn, Records.delete_record(command_attrs, prefix!(conn)), :ok)
    else
      {:error, :invalid_record_id} ->
        Response.not_found(conn)

      {:error, :invalid_expected_seq} ->
        Response.bad_request(conn, "invalid expected_last_event_global_seq")
    end
  end

  # Absent -> {:ok, nil}; a string Integer.parse/1 consumes fully, within
  # 0..max int8 -> {:ok, n}; anything else ("abc", "", "-1", "1.5", "1x",
  # overflow, a repeated/array param) -> {:error, :invalid_expected_seq}.
  @spec parse_expected_seq_param(nil | String.t() | list() | map()) ::
          {:ok, non_neg_integer() | nil} | {:error, :invalid_expected_seq}
  defp parse_expected_seq_param(nil), do: {:ok, nil}

  defp parse_expected_seq_param(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n >= 0 and n <= @max_int8 -> {:ok, n}
      _other -> {:error, :invalid_expected_seq}
    end
  end

  defp parse_expected_seq_param(_other), do: {:error, :invalid_expected_seq}

  # Casting here (rather than letting Latest.get/3 receive a non-UUID string)
  # keeps a malformed id on the same zero-detail 404 path as an absent one.
  defp cast_record_id(raw) do
    case Ecto.UUID.cast(raw) do
      {:ok, record_id} -> {:ok, record_id}
      :error -> {:error, :invalid_record_id}
    end
  end

  defp idempotency_key(attrs) do
    case Map.get(attrs, "idempotency_key") do
      key when is_binary(key) -> key
      nil -> Ecto.UUID.generate()
    end
  end

  # ══ POST /entities/records/:entity_type/import (REQ-320) ═════════════
  #
  # Design doc: req314-entity-record-bulk-export-import.md §3 (write path
  # and per-batch failure semantics), §4 (route shape), §6/INV-5 (tenant
  # scoping, not-found folding), §7 (the 200-record cap and its 413).
  #
  # ⛔ Check ordering is load-bearing, not cosmetic (§7's own "cheapest,
  # most structural check first" discipline):
  #
  #   1. the 200-record cap (§7) -- before entity-type/definition resolution
  #      or ANY per-entry validation, never a silent truncation;
  #   2. the `record_export_schema_version` gate (§1/§3) -- before tenant
  #      resolution or any database touch, a distinct 422 from a generic
  #      validation failure;
  #   3. the `entity_type` path-vs-body match (§4) -- before any
  #      `create_record/2` call.
  #
  # Only after all three pass does any entry reach `create_record/2`.
  @record_export_schema_version "entities/record-export/v1"

  defp handle_import_records(conn, entity_type) do
    prefix = prefix!(conn)
    actor_id = conn.assigns.auth_context.user_id

    with {:ok, body} <- object_body(conn),
         {:ok, records} <- records_within_cap(body),
         :ok <- check_record_export_schema_version(body),
         :ok <- check_import_entity_type_match(body, entity_type) do
      import_request_id = Ecto.UUID.generate()

      case run_import(records, entity_type, actor_id, import_request_id, prefix) do
        {:ok, results} ->
          Response.ok(conn, %{"results" => Enum.map(results, &import_entry_result_json/1)})

        # §6/INV-5, AC: a definition_not_found from the FIRST entry -- the
        # only entry this handler ever inspects for this outcome, since
        # entity_type/tenant are constant across the whole batch -- folds
        # to the SAME 404 create_record/2's own single-write path already
        # produces. No cross-tenant-specific pre-check is added here.
        {:error, {:definition_not_found, _entity_type}} ->
          Response.not_found(conn)
      end
    else
      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")

      {:error, :records_not_an_array} ->
        Response.unprocessable(conn, "records must be an array")

      {:error, :too_many_records, count} ->
        Response.payload_too_large(
          conn,
          "import batch of #{count} records exceeds the 200-record cap"
        )

      {:error, :unknown_record_export_schema_version, actual} ->
        Response.unprocessable(
          conn,
          "unknown record_export_schema_version: #{inspect(actual)}"
        )

      {:error, :import_entity_type_mismatch} ->
        Response.unprocessable(
          conn,
          "entity_type in the request body does not match the route's :entity_type path segment"
        )
    end
  end

  # §7: rejects the WHOLE request past the 200-record cap, before entity-
  # type/definition resolution or any per-entry validation -- never a
  # silent truncation to the first 200.
  @import_record_cap 200

  defp records_within_cap(body) do
    case Map.get(body, "records") do
      records when is_list(records) ->
        count = length(records)

        if count > @import_record_cap do
          {:error, :too_many_records, count}
        else
          {:ok, records}
        end

      _not_a_list ->
        {:error, :records_not_an_array}
    end
  end

  # §1/§3's ExportImport precedent: checked before tenant resolution or any
  # database touch, a distinct, NAMED error -- never conflated with a
  # generic validation failure.
  defp check_record_export_schema_version(body) do
    case Map.get(body, "record_export_schema_version") do
      @record_export_schema_version -> :ok
      other -> {:error, :unknown_record_export_schema_version, other}
    end
  end

  # §4: the document's own `entity_type` must match the route's
  # `:entity_type` path segment exactly, or 422 before any create_record/2
  # call.
  defp check_import_entity_type_match(body, entity_type) do
    case Map.get(body, "entity_type") do
      ^entity_type -> :ok
      _mismatch -> {:error, :import_entity_type_mismatch}
    end
  end

  # §3: per-record partial success, not whole-batch atomicity --
  # create_record/2 commits its own transaction per call and is never
  # composed into an outer Multi here. The FIRST entry is inspected
  # specially only for the definition_not_found short-circuit (see
  # handle_import_records/2's comment); every entry (first included) still
  # contributes its own result to the accumulated list on every other
  # outcome.
  defp run_import([], _entity_type, _actor_id, _import_request_id, _prefix), do: {:ok, []}

  defp run_import([first | rest], entity_type, actor_id, import_request_id, prefix) do
    case import_one_entry(first, entity_type, actor_id, import_request_id, prefix) do
      {:error, _source_record_id, {:error, {:definition_not_found, _} = reason}} ->
        {:error, reason}

      first_result ->
        rest_results =
          Enum.map(rest, &import_one_entry(&1, entity_type, actor_id, import_request_id, prefix))

        {:ok, [first_result | rest_results]}
    end
  end

  # §3: `entry.record_id` is NEVER used to address/update an existing row --
  # create_record/2 always mints its own fresh record_id; `source_record_id`
  # is carried through purely for the caller's own reconciliation.
  # `deleted: true` on an entry is imported as a live create, identically to
  # a non-deleted one -- no create-then-delete reproduction (§3's explicit
  # scope cut). `idempotency_key` is derived from `(import_request_id,
  # source_record_id)` -- `import_request_id` is minted once per HTTP call
  # in handle_import_records/2, NEVER read from the document or the entry --
  # so two entries sharing a `record_id` WITHIN one call collide onto the
  # same key (intra-call dedup, via create_record/2's own duplicate-key
  # contract; GH #2543: only identical field_values dedupe, differing ones
  # give a per-entry idempotency_key_reuse), while two separate calls -- even a byte-identical re-POST --
  # each mint their own import_request_id and share no relationship at all.
  defp import_one_entry(entry, entity_type, actor_id, import_request_id, prefix) do
    source_record_id = Map.get(entry, "record_id")
    field_values = Map.get(entry, "field_values", %{})
    idempotency_key = import_idempotency_key(import_request_id, source_record_id)

    command_attrs = %{
      entity_type: entity_type,
      field_values: field_values,
      actor_id: actor_id,
      idempotency_key: idempotency_key
    }

    case Records.create_record(command_attrs, prefix) do
      {:ok, %{record: %Latest{record_id: record_id}}} ->
        {:ok, %{record_id: record_id, source_record_id: source_record_id}}

      {:error, _reason} = error ->
        {:error, source_record_id, error}
    end
  end

  defp import_idempotency_key(import_request_id, source_record_id) do
    "entities-record-import:#{import_request_id}:#{inspect(source_record_id)}"
  end

  defp import_entry_result_json(
         {:ok, %{record_id: record_id, source_record_id: source_record_id}}
       ) do
    %{"status" => "ok", "record_id" => record_id, "source_record_id" => source_record_id}
  end

  defp import_entry_result_json({:error, source_record_id, {:error, reason}}) do
    %{
      "status" => "error",
      "source_record_id" => source_record_id,
      "reason" => import_reason_json(reason)
    }
  end

  # Mirrors render_record_command/3's own Records.command_error() mapping
  # (unmodified reasons, just JSON-shaped instead of turned into an HTTP
  # status) -- so a failing entry's "reason" carries the same information a
  # standalone POST /entities/records/:entity_type call for that same entry
  # would surface.
  defp import_reason_json({:record_payload_invalid, violations}) do
    %{"type" => "record_payload_invalid", "violations" => Enum.map(violations, &violation_map/1)}
  end

  defp import_reason_json({:definition_not_found, entity_type}) do
    %{"type" => "definition_not_found", "entity_type" => entity_type}
  end

  defp import_reason_json({:payload_validation_failed, _errors}) do
    %{"type" => "payload_validation_failed"}
  end

  # GH #2543: two entries in one call sharing a `record_id` (so a key) but
  # with different field_values -- the second is refused, not dropped.
  defp import_reason_json(:idempotency_key_reuse) do
    %{"type" => "idempotency_key_reuse"}
  end

  defp import_reason_json(reason)
       when reason in [:tenant_not_provisioned, :invalid_schema_name] do
    %{"type" => Atom.to_string(reason)}
  end

  defp import_reason_json(other) do
    Logger.warning("entity record import entry failed: #{inspect(other)}")
    %{"type" => "internal_error"}
  end

  # ══ POST /entities/restrictions/import (ISS-0935) ═════════════════════
  #
  # Body carries up to four optional arrays -- `field_restrictions`,
  # `field_grants`, `type_restrictions`, `type_grants`
  # (`Letflow.Entities.Restrictions.import_restrictions/2`'s own moduledoc
  # has the full per-row shape/validation contract). 403 is handled entirely
  # by the route-level :EntitiesRestrictionsManage check above (the
  # `authz_post` macro) -- this handler never emits its own 403. `actor_id`
  # is read from conn.assigns but not forwarded to the delegate: these rows
  # carry no "created_by" column (design §1.3's table shapes), matching
  # entity_field_restrictions/user_entity_grants' own already-shipped,
  # audit-column-free shape.

  defp handle_import_restrictions(conn) do
    prefix = prefix!(conn)

    with {:ok, body} <- object_body(conn) do
      case Restrictions.import_restrictions(body, prefix) do
        {:ok, counts} ->
          Response.ok(conn, %{"inserted" => restrictions_counts_json(counts)})

        {:error, {:invalid_rows, errors}} ->
          Response.unprocessable(conn, restriction_rows_error_detail(errors))
      end
    else
      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")
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

  # design §7, Records.command_error(), mapped exhaustively:
  #   {:definition_not_found, _}     -> 404  (INV-5)
  #   {:record_not_found, _}         -> 404  (INV-5)
  #   {:record_payload_invalid, v}   -> 422 with the violation list
  #   {:payload_validation_failed,_} -> 422
  #   {:record_already_deleted, _}   -> 409
  #   :record_version_conflict       -> 409 (record-version-conflict, GH #2528;
  #                                     constant body, no record data/seq)
  #   {:entity_append_only, _}       -> 422 (entity-append-only, GH #2529;
  #                                     constant body)
  #   :idempotency_key_reuse         -> 422 (idempotency-key-reuse, GH #2543;
  #                                     constant body, no original data)
  #   :tenant_not_provisioned        -> 500  (unreachable, INV-1)
  #   :invalid_schema_name           -> 500  (unreachable, INV-1)
  #   any other term()               -> 500  (INV-8 catch-all, no detail)
  defp render_record_command(conn, {:ok, %{record: %Latest{} = record}}, :created),
    do: Response.created(conn, record_map(record))

  defp render_record_command(conn, {:ok, %{record: %Latest{} = record}}, :ok),
    do: Response.ok(conn, record_map(record))

  defp render_record_command(conn, {:error, {:definition_not_found, _entity_type}}, _status),
    do: Response.not_found(conn)

  defp render_record_command(conn, {:error, {:record_not_found, _record_id}}, _status),
    do: Response.not_found(conn)

  defp render_record_command(conn, {:error, {:record_payload_invalid, violations}}, _status) do
    Response.send_problem(
      conn,
      %{
        Error.unprocessable("entity record payload failed validation")
        | errors: Enum.map(violations, &violation_map/1)
      }
    )
  end

  # ⛔ UNREACHABLE through these three routes, and no test drives it
  # (REQ-310 rework round 1, REVIEWER). This is REQ-024's OUTER envelope
  # check firing inside `EventStore.append_multi/3` -- it reports that the
  # EVENT PAYLOAD this router's own delegate constructed violates the
  # registered event-type schema, not that the caller's `field_values` are
  # wrong (that is `{:record_payload_invalid, _}` above, which IS reachable
  # and IS tested). `Letflow.Entities.Records` always builds an envelope
  # satisfying its own registered schema, so reaching this clause would mean
  # an internal construction bug or a schema tightening, not caller input --
  # exactly the framing `req228`'s own design table gives it. Mapped for
  # completeness, per this module's "unreachable but mapped" discipline; it
  # stays a 422 rather than a 500 because design §7's table assigns it one.
  defp render_record_command(conn, {:error, {:payload_validation_failed, _errors}}, _status),
    do: Response.unprocessable(conn, "entity record payload failed validation")

  defp render_record_command(conn, {:error, {:record_already_deleted, _record_id}}, _status),
    do: Response.conflict(conn, "entity record is already deleted")

  defp render_record_command(conn, {:error, :record_version_conflict}, _status),
    do: Response.send_problem(conn, Error.record_version_conflict())

  defp render_record_command(conn, {:error, {:entity_append_only, _entity_type}}, _status),
    do: Response.send_problem(conn, Error.entity_append_only())

  defp render_record_command(conn, {:error, :idempotency_key_reuse}, _status),
    do: Response.send_problem(conn, Error.idempotency_key_reuse())

  defp render_record_command(conn, {:error, reason}, _status)
       when reason in [:tenant_not_provisioned, :invalid_schema_name],
       do: Response.internal_error(conn)

  defp render_record_command(conn, {:error, reason}, _status) do
    Logger.warning("entity record command failed: #{inspect(reason)}")
    Response.internal_error(conn)
  end

  # ══ POST /entities/records/:entity_type/:record_id/attachments (REQ-317) ══
  #
  # Multipart upload, same shape as Letflow.Routers.Instances' own
  # POST /instances/:id/attachments (REQ-212 design §5.4): the file arrives
  # as a %Plug.Upload{} body part named "file". `uploaded_by` is the
  # authenticated caller (conn.assigns.auth_context.user_id), never a body
  # field (design §5 INV-1). `entity_type`/`record_id` come from the path.

  defp handle_create_record_attachment(conn, entity_type, raw_record_id) do
    opts = conn.assigns.scoped_opts

    with {:ok, record_id} <- cast_record_id(raw_record_id),
         {:ok, attrs} <- record_attachment_upload_attrs_from_conn(conn, entity_type, record_id) do
      render_create_record_attachment(conn, EntityAttachments.upload(attrs, opts))
    else
      # INV-5: a malformed record id folds to the same zero-detail 404 as an
      # absent (or cross-tenant) one -- matching cast_record_id/1's existing
      # use on the record-command routes above.
      {:error, :invalid_record_id} ->
        Response.not_found(conn)

      {:error, :missing_file} ->
        Response.unprocessable(conn, "a file part named \"file\" is required")
    end
  end

  @spec record_attachment_upload_attrs_from_conn(Plug.Conn.t(), String.t(), Ecto.UUID.t()) ::
          {:ok, EntityAttachments.upload_attrs()} | {:error, :missing_file}
  defp record_attachment_upload_attrs_from_conn(conn, entity_type, record_id) do
    case conn.body_params["file"] do
      %Plug.Upload{path: path, filename: filename, content_type: content_type} ->
        attrs = %{
          entity_type: entity_type,
          record_id: record_id,
          raw_bytes: File.read!(path),
          file_name: filename,
          content_type: content_type,
          uploaded_by: conn.assigns.auth_context.user_id,
          description: record_attachment_description(conn.body_params["description"])
        }

        {:ok, attrs}

      _missing_or_not_a_file ->
        {:error, :missing_file}
    end
  end

  defp record_attachment_description(value) when is_binary(value) and byte_size(value) > 0,
    do: value

  defp record_attachment_description(_absent_or_empty), do: nil

  defp render_create_record_attachment(conn, {:ok, attachment}) do
    Response.created(conn, record_attachment_json(attachment))
  end

  defp render_create_record_attachment(conn, {:error, :file_too_large}) do
    Response.payload_too_large(conn, "uploaded file exceeds the maximum allowed size")
  end

  defp render_create_record_attachment(conn, {:error, :infected, verdict}) do
    Response.unprocessable(conn, "uploaded file failed a content scan (#{verdict})")
  end

  defp render_create_record_attachment(conn, {:error, :scan_unavailable}) do
    Response.service_unavailable(conn, "content scan is temporarily unavailable, please retry")
  end

  # AC5 (design §7 OQ-1, closed): an (entity_type, record_id) pair with no
  # matching entity_record_latest row surfaces here as an ordinary
  # Ecto.Changeset error (EntityAttachment.changeset/2's
  # foreign_key_constraint/3 clause on :record_id) -- mapped to 404, never a
  # raised, unhandled Postgres error and never a 422. Any OTHER changeset
  # error (e.g. file_name over 255 characters) is a genuine validation
  # failure and stays 422.
  defp render_create_record_attachment(conn, {:error, %Ecto.Changeset{} = changeset}) do
    if Keyword.has_key?(changeset.errors, :record_id) do
      Response.not_found(conn)
    else
      Response.unprocessable(conn, "request failed validation")
    end
  end

  # ══ GET /entities/records/:entity_type/:record_id/attachments (REQ-317) ══
  #
  # Cursor-paginated JSON metadata list, same page-size/cursor contract as
  # Letflow.Routers.Instances' own GET /instances/:id/attachments (REQ-212
  # design §5.2). No existence check against entity_record_latest -- a
  # nonexistent (or cross-tenant) (entity_type, record_id) pair returns an
  # EMPTY 200 page, matching design §2/§5's own stated INV-5 behavior. A
  # malformed record id still folds to 404, matching this router's own
  # cast_record_id/1 convention for the record-command routes.

  defp handle_list_record_attachments(conn, entity_type, raw_record_id) do
    opts = conn.assigns.scoped_opts
    conn = fetch_query_params(conn)
    query = conn.query_params

    with {:ok, record_id} <- cast_record_id(raw_record_id),
         {:ok, raw_page_size} <- Pagination.parse_page_size_param(Map.get(query, "page_size")),
         {:ok, page_size} <- Pagination.validate_page_size(raw_page_size) do
      params = %{
        entity_type: entity_type,
        record_id: record_id,
        cursor: Map.get(query, "cursor"),
        page_size: page_size
      }

      render_list_record_attachments(conn, EntityAttachments.list(params, opts))
    else
      {:error, :invalid_record_id} ->
        Response.not_found(conn)

      {:error, :invalid_page_size} ->
        Response.bad_request(conn, "invalid page_size")

      {:error, :page_size_too_large} ->
        Response.bad_request(conn, "page_size out of range")
    end
  end

  # Deliberately NOT render_page_result/3 -- that shared helper adds a
  # "count" key this route's own {items, next_cursor} shape (matching
  # Letflow.Routers.Instances' own list-attachments precedent) must not
  # carry.
  defp render_list_record_attachments(conn, {:ok, %{items: items, next_cursor: next_cursor}}) do
    Response.ok(conn, %{
      "items" => Enum.map(items, &record_attachment_json/1),
      "next_cursor" => next_cursor
    })
  end

  defp render_list_record_attachments(conn, {:error, reason})
       when reason in [:invalid_cursor, :wrong_endpoint],
       do: Response.unprocessable(conn, "cursor is not valid for this endpoint")

  defp render_list_record_attachments(conn, {:error, :expired}),
    do: Response.send_problem(conn, Error.cursor_expired())

  defp render_list_record_attachments(conn, {:error, :page_size_too_large}),
    do: Response.bad_request(conn, "page_size out of range")

  # ══ GET /entities/records/:entity_type/:record_id/attachments/:attachment_id
  # ══ (REQ-317) ══════════════════════════════════════════════════════════
  #
  # Raw-bytes response, same INV-RT-1 discipline as Letflow.Routers.Instances'
  # own GET /instances/:id/attachments/:attachment_id (REQ-212 design §4/§5.3):
  # neither the byte-content lookup nor this handler's own cross-record 404
  # check ever issues a direct Ecto Repo call -- both are delegated to (or
  # folded through) Letflow.Repository.EntityAttachments. Both the
  # cross-tenant check (structural, via opts[:prefix]) and the
  # cross-record-same-tenant check (explicit, in-handler, mirroring
  # Letflow.Routers.Instances' own cross-instance check) fold to the same
  # {:error, :not_found} -- design §5 INV-5. `Content-Type` is set from the
  # stored (caller-declared, untrusted per design §6 INV-a) content_type
  # field -- no MIME-sniffing.

  defp handle_get_record_attachment_content(conn, entity_type, raw_record_id, raw_attachment_id) do
    opts = conn.assigns.scoped_opts

    with {:ok, record_id} <- cast_record_id(raw_record_id),
         {:ok, attachment, artifact} <-
           fetch_scoped_record_attachment_content(raw_attachment_id, entity_type, record_id, opts) do
      send_record_attachment_content(conn, attachment, artifact)
    else
      {:error, :invalid_record_id} ->
        Response.not_found(conn)

      {:error, :not_found} ->
        Response.not_found(conn)

      {:error, :content_missing} ->
        Response.internal_error(conn)

      {:error, :not_available} ->
        Response.conflict(conn, "attachment content is not currently available")
    end
  end

  @spec fetch_scoped_record_attachment_content(String.t(), String.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, EntityAttachment.t(), Artifact.t()}
          | {:error, :not_found | :content_missing | :not_available}
  defp fetch_scoped_record_attachment_content(raw_attachment_id, entity_type, record_id, opts) do
    case EntityAttachments.get_content(raw_attachment_id, opts) do
      {:ok, %EntityAttachment{entity_type: ^entity_type, record_id: ^record_id} = attachment,
       artifact} ->
        {:ok, attachment, artifact}

      {:ok, %EntityAttachment{}, _artifact} ->
        {:error, :not_found}

      {:error, :invalid_id} ->
        {:error, :not_found}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :content_missing} ->
        {:error, :content_missing}

      {:error, :not_available} ->
        {:error, :not_available}
    end
  end

  defp send_record_attachment_content(
         conn,
         %EntityAttachment{} = attachment,
         %Artifact{} = artifact
       ) do
    conn
    |> put_resp_content_type(attachment.content_type)
    |> put_resp_header(
      "content-disposition",
      record_attachment_content_disposition(attachment.file_name)
    )
    |> send_resp(200, artifact.content)
  end

  # Escapes literal `"` and `\` (Content-Disposition's own quoting rules) and
  # strips CR/LF/other C0 control characters before interpolating a
  # caller-supplied file_name into a raw HTTP header value, matching
  # Letflow.Routers.Instances' own content_disposition/1 precedent -- this
  # never affects the stored/returned file_name value itself, only this
  # one header's rendering.
  @spec record_attachment_content_disposition(String.t()) :: String.t()
  defp record_attachment_content_disposition(file_name) do
    sanitized =
      file_name
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> strip_record_attachment_control_characters()

    "attachment; filename=\"#{sanitized}\""
  end

  defp strip_record_attachment_control_characters(value) do
    String.replace(value, ~r/[\x00-\x1F\x7F]/, "")
  end

  # ══ DELETE /entities/records/:entity_type/:record_id/attachments/:attachment_id
  # ══ (REQ-317) ══════════════════════════════════════════════════════════

  defp handle_delete_record_attachment(conn, entity_type, raw_record_id, raw_attachment_id) do
    opts = conn.assigns.scoped_opts

    with {:ok, record_id} <- cast_record_id(raw_record_id),
         {:ok, _attachment} <-
           fetch_scoped_record_attachment_metadata(
             raw_attachment_id,
             entity_type,
             record_id,
             opts
           ),
         {:ok, _deleted} <- EntityAttachments.delete(raw_attachment_id, opts) do
      Response.no_content(conn)
    else
      {:error, :invalid_record_id} -> Response.not_found(conn)
      {:error, :not_found} -> Response.not_found(conn)
    end
  end

  # Metadata-only sibling of fetch_scoped_record_attachment_content/4, for
  # DELETE -- same cross-record/cross-tenant 404 checks, no
  # repository_artifacts lookup (DELETE never needs the byte content).
  @spec fetch_scoped_record_attachment_metadata(String.t(), String.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, EntityAttachment.t()} | {:error, :not_found}
  defp fetch_scoped_record_attachment_metadata(raw_attachment_id, entity_type, record_id, opts) do
    case EntityAttachments.get(raw_attachment_id, opts) do
      {:ok, %EntityAttachment{entity_type: ^entity_type, record_id: ^record_id} = attachment} ->
        {:ok, attachment}

      {:ok, %EntityAttachment{}} ->
        {:error, :not_found}

      {:error, :invalid_id} ->
        {:error, :not_found}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # ── Response allowlist (INV-2) — shared by create/list (REQ-317) ────────
  #
  # Hand-built allowlist, matching Letflow.Routers.Instances' own
  # attachment_json/1 precedent -- never a raw Jason.Encoder derivation over
  # %EntityAttachment{}, which would leak __meta__/tenant_id/content_hash.
  # No FieldGrants redaction step (design §5 INV-2) -- this is a fixed,
  # code-defined column set, not a tenant-authored field_values document.
  @spec record_attachment_json(EntityAttachment.t()) :: map()
  defp record_attachment_json(%EntityAttachment{} = attachment) do
    %{
      "id" => attachment.id,
      "entity_type" => attachment.entity_type,
      "record_id" => attachment.record_id,
      "file_name" => attachment.file_name,
      "content_type" => attachment.content_type,
      "byte_size" => attachment.byte_size,
      "uploaded_by" => attachment.uploaded_by,
      "description" => attachment.description,
      "created_at" => DateTime.to_iso8601(attachment.created_at)
    }
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
  # REQ-394: `TypeAccess.authorized?/3` runs AFTER `Compiler.compile/2` has
  # already confirmed the entity type exists (design §2.1) -- it is only
  # ever asked about a real entity type, never a nonexistent one. Its
  # `{:ok, :denied}` result does not match the `{:ok, :allowed}` pattern
  # below, so it falls into this `with`'s implicit `else` as the bare value
  # `{:ok, :denied}`, mapped by `render_query_error/2`'s own clause for it
  # (design §2.2) to the same 200-empty envelope a genuinely-empty type
  # produces -- deliberately indistinguishable, not a 403/404.
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
    with {:ok, request} <- build_query_request(body),
         {:ok, opts} <- build_paginate_opts(body),
         {:ok, compiled} <- Compiler.compile(request, prefix),
         {:ok, :allowed} <- TypeAccess.authorized?(user_id, request.entity_type, prefix),
         {:ok, allowlist} <- Allowlist.load(request.entity_type, prefix),
         {:ok, page} <- Cursor.paginate(request, compiled, allowlist, opts, prefix),
         {:ok, redacted} <- redact(page, request, user_id, prefix) do
      Response.ok(conn, %{
        "items" => Enum.map(redacted.items, &query_item_map/1),
        "next_cursor" => redacted.next_cursor
      })
    else
      # REQ-394 (design §2.2): both "the type does not exist at all" and
      # "the type exists but this caller is denied by TypeAccess" collapse
      # to the SAME 200-empty envelope, on THIS route only. This is a
      # local override of render_query_error/2's own :entity_type_not_found
      # clause (which stays a 404 below, unchanged) -- render_query_error/2
      # is shared with the aggregate (render_aggregate_error/2) and export
      # (render_export_error/2) routes' own fallthrough clauses, and
      # REQ-394's acceptance criteria name only POST /entities/query and the
      # three definitions-read routes; changing the shared function's own
      # :entity_type_not_found clause would silently change those two
      # unrelated routes' already-shipped 404 behavior too.
      {:ok, :denied} -> render_type_hidden(conn)
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
  @spec redact(Pagination.Page.t(term()), Types.query_request(), String.t(), String.t()) ::
          {:ok, Pagination.Page.t(term())} | {:error, :invalid_schema_name}
  defp redact(page, %{join: [_ | _] = joins} = request, user_id, prefix) do
    # One load_restrictions/3 per EXPOSED entity type: :primary for the
    # primary's own type, plus each join clause's own entity_type. A
    # `through` entity's type is NOT here -- its row never appears as a key
    # of a Compiler.joined_row(), so a restriction set keyed for it could
    # never be fetched, and including it would signal that the key list was
    # mis-derived (the failure mode being a MISSING exposed key, which
    # redact_joined_item/2's Map.fetch!/2 turns into a 500).
    keys = [{:primary, request.entity_type} | Enum.map(joins, &{&1.entity_type, &1.entity_type})]

    Enum.reduce_while(keys, {:ok, %{}}, fn {key, entity_type}, {:ok, acc} ->
      case FieldGrants.load_restrictions(user_id, entity_type, prefix) do
        {:ok, set} -> {:cont, {:ok, Map.put(acc, key, set)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, restriction_sets} -> {:ok, FieldGrants.redact_joined_page(page, restriction_sets)}
      {:error, _reason} = error -> error
    end
  end

  defp redact(page, request, user_id, prefix) do
    with {:ok, restriction_set} <-
           FieldGrants.load_restrictions(user_id, request.entity_type, prefix) do
      # FieldGrants.redact_page/2 covers BOTH shapes compile_plain/5 can
      # emit -- %Latest{} (unpromoted) and a plain Compiler.entity_row()
      # map (promoted) -- via redact_item/2's two clauses. ⛔ It has no
      # third, permissive clause: a shape neither matches RAISES (a
      # logged, detail-free 500 via the pipeline's own error handler)
      # rather than falling through UNREDACTED, which is the one failure
      # mode INV-2 cannot tolerate. Do not add a rescue here.
      {:ok, FieldGrants.redact_page(page, restriction_set)}
    end
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
  # ⛔ INV-2, THE HARD PART (design §4's reworked, SECURITY-REVIEWER-cleared
  # mechanism): `check_aggregate_field_restrictions/2` runs BEFORE
  # `Compiler.compile_aggregate/2` is ever called, against EVERY field named
  # anywhere in the request -- every aggregate target's `:field`, every
  # `group_by` field, AND every `filters` field, with NO exemption for
  # `filters` on this route (unlike `POST /entities/query`, untouched by this
  # section). A single restricted field anywhere rejects the WHOLE request
  # with 403, before any query is built.

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
    with {:ok, request} <- build_aggregate_request(body),
         {:ok, restriction_set} <-
           FieldGrants.load_restrictions(user_id, request.entity_type, prefix),
         :ok <- check_aggregate_field_restrictions(request, restriction_set),
         {:ok, rows} <- Compiler.run_aggregate(request, prefix) do
      Response.ok(conn, %{"results" => Enum.map(rows, &aggregate_result_map/1)})
    else
      {:error, reason} -> render_aggregate_error(conn, reason)
    end
  end

  # Every field named ANYWHERE in the request -- aggregate targets, group_by,
  # AND filters alike (design §4's final, reworked mechanism -- no exemption
  # for filters on THIS route). `restriction_set` is raw field-name strings
  # (Letflow.Entities.Query.FieldGrants.load_restrictions/3's own output) --
  # this check runs against caller-supplied strings directly, before any
  # allowlist resolution, so it cannot be bypassed by a field that would
  # otherwise fail allowlisting for an unrelated reason.
  defp check_aggregate_field_restrictions(request, restriction_set) do
    request
    |> aggregate_request_field_names()
    |> Enum.find(&MapSet.member?(restriction_set, &1))
    |> case do
      nil -> :ok
      field_name -> {:error, {:aggregate_field_restricted, field_name}}
    end
  end

  defp aggregate_request_field_names(request) do
    aggregate_fields =
      Enum.flat_map(request.aggregates, fn target -> List.wrap(Map.get(target, :field)) end)

    group_by_fields = Enum.map(request.group_by, & &1.field)
    filter_fields = Enum.map(request.filters, & &1.field)

    aggregate_fields ++ group_by_fields ++ filter_fields
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
  # row-query analogue at all, {:aggregate_field_restricted, _} (design §4),
  # maps to 403 -- the field named exists and is allowlisted, but this caller
  # specifically lacks read access to it.
  defp render_aggregate_error(conn, {:aggregate_field_restricted, _field_name}),
    do: Response.forbidden(conn, "one or more requested fields are restricted for this caller")

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
  #   4. Only past all of the above does the identical
  #      Allowlist.load/2 -> Compiler.compile/2 -> Cursor.paginate/5
  #      sequence handle_query/1's own run_query/4 uses run, unmodified.
  #   5. `export_redact/5` -- skips `FieldGrants` entirely when `unredacted?`
  #      is true (already authorized at step 3); otherwise defers to THE
  #      SAME `redact/4` clauses handle_query/1 already uses, no second
  #      redaction policy introduced.
  @spec run_export(Plug.Conn.t(), map(), String.t(), String.t(), String.t()) :: Plug.Conn.t()
  defp run_export(conn, body, path_entity_type, user_id, prefix) do
    with :ok <- check_export_entity_type_match(body, path_entity_type),
         {:ok, unredacted?} <- parse_unredacted_flag(body),
         :ok <- check_unredacted_permission(conn, unredacted?),
         {:ok, request} <- build_export_query_request(body, path_entity_type),
         {:ok, opts} <- build_export_paginate_opts(body),
         {:ok, compiled} <- Compiler.compile(request, prefix),
         {:ok, allowlist} <- Allowlist.load(request.entity_type, prefix),
         {:ok, page} <- Cursor.paginate(request, compiled, allowlist, opts, prefix),
         {:ok, redacted} <- export_redact(page, request, user_id, prefix, unredacted?) do
      Response.ok(conn, %{
        "record_export_schema_version" => @record_export_schema_version,
        "entity_type" => path_entity_type,
        "exported_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "records" => Enum.map(redacted.items, &export_record_map/1),
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
          String.t(),
          String.t(),
          boolean()
        ) ::
          {:ok, Pagination.Page.t(term())} | {:error, :invalid_schema_name}
  defp export_redact(page, _request, _user_id, _prefix, true), do: {:ok, page}

  defp export_redact(page, request, user_id, prefix, false),
    do: redact(page, request, user_id, prefix)

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
  defp export_record_map(%Latest{} = record) do
    %{
      "record_id" => record.record_id,
      "field_values" => record.field_values,
      "deleted" => record.deleted
    }
  end

  defp export_record_map(%{field_values: _field_values} = entity_row) do
    %{
      "record_id" => entity_row.record_id,
      "field_values" => entity_row.field_values,
      "deleted" => entity_row.deleted
    }
  end

  defp export_record_map(joined_row) when is_map(joined_row) do
    export_record_map(Map.fetch!(joined_row, :primary))
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
  # TypeAccess.authorized?/3's `{:ok, :denied}` result (REQ-394 design
  # §2.1/§2.2) is NOT a member of this union and never reaches this
  # function -- it is handled locally in run_query/4's own `with`/`else`,
  # mapped to the same 200 {"items":[],"next_cursor":null} envelope as
  # :entity_type_not_found gets on that one route.
  #
  # Cursor.paginate/5's own union:
  #   :page_size_too_large / :invalid_cursor / :wrong_endpoint /
  #   :resume_key_arity_mismatch          -> 400
  #   :expired                            -> the dedicated cursor-expired
  #                                          problem document
  #   {:field_not_allowed, _}             -> 422 (shared clause above)

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

  defp query_item_map(%Latest{} = record), do: record_map(record)

  defp query_item_map(%{field_values: _field_values} = entity_row),
    do: entity_row_map(entity_row)

  defp query_item_map(joined_row) when is_map(joined_row) do
    Map.new(joined_row, fn {key, entity_row} ->
      {joined_key_string(key), entity_row_map(entity_row)}
    end)
  end

  defp joined_key_string(:primary), do: "primary"
  defp joined_key_string(entity_type) when is_binary(entity_type), do: entity_type

  # Same allowlist record_map/1 applies to a %Latest{}, so a promotion is
  # not observable in a response body. `Compiler.select_entity_row/1`
  # (and the joined-select equivalents) now cast `record_id` to a real
  # `String.t()` at the query source (ISS-0652) -- it is always a string
  # here regardless of whether this row came from `entity_record_latest`
  # or a promoted per-type table, so no local normalisation is needed.
  defp entity_row_map(entity_row) do
    %{
      "record_id" => entity_row.record_id,
      "field_values" => entity_row.field_values,
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

  # `tenant_id` is deliberately NOT in this allowlist -- a caller is already
  # scoped to exactly one tenant and echoing the id back adds nothing but a
  # tenant identifier on the wire.
  @spec record_map(Latest.t()) :: map()
  defp record_map(%Latest{} = record) do
    %{
      "record_id" => record.record_id,
      "entity_type" => record.entity_type,
      "field_values" => record.field_values,
      "deleted" => record.deleted,
      "entity_def_version" => Base.encode16(record.entity_def_version, case: :lower),
      "last_event_global_seq" => record.last_event_global_seq
    }
  end

  # ══ Helpers ═══════════════════════════════════════════════════════════

  # INV-1: the ONE source of prefix on every route in this module. Never a
  # path, query or body value.
  #
  # Every delegate in `Letflow.Entities.*` takes a BARE `prefix ::
  # String.t()` positional argument (see each one's own @spec), not the
  # `[prefix: schema]` keyword list `Letflow.Routers.Definitions`/
  # `Letflow.Routers.Instances` hand straight to their own
  # `Letflow.Definitions.*`/`Letflow.Repository.*` delegates as `opts`. So
  # this router unwraps `conn.assigns.scoped_opts` here rather than passing
  # it through -- the difference is in the delegates' signatures, not in
  # where the value comes from, which is identical to every other router.
  # `Keyword.fetch!/2` deliberately raises rather than defaulting: reaching a
  # handler without `:scoped_opts` assigned is structurally impossible
  # (`Letflow.Plugs.Authorize` assigns it before `:dispatch` or halts), and a
  # silent default would be a tenant-scoping bug, not a recoverable one.
  @spec prefix!(Plug.Conn.t()) :: String.t()
  defp prefix!(conn), do: Keyword.fetch!(conn.assigns.scoped_opts, :prefix)

  defp object_body(conn) do
    case conn.body_params do
      %{"_json" => _non_object} -> {:error, :malformed_json}
      body when is_map(body) -> {:ok, body}
      _other -> {:error, :malformed_json}
    end
  end

  defp validate_schema(schema, body) do
    case Validation.validate(schema, body) do
      {:ok, attrs} -> {:ok, attrs}
      {:errors, field_errors} -> {:errors, field_errors}
    end
  end

  # The two violation shapes this module can receive have DISJOINT fields, so
  # each gets its own clause rather than one Map.get-based reader that would
  # silently emit nils for whichever shape it was not written against:
  #
  #   * Letflow.Entities.Definition.Validator.Violation -- rule/path/message
  #     (from create_definition/2's {:validation, violations});
  #   * Letflow.EventStore.Registry.ValidationFailure -- field_path/
  #     constraint/actual (from Records' {:record_payload_invalid, violations}).
  #
  # Both become plain string-keyed maps: Letflow.Api.Error.serialise/1's
  # `errors: [_ | _]` clause hands the list straight to Jason.encode!/1.
  # `actual` (the caller's own rejected value) is deliberately NOT echoed --
  # it adds nothing the caller does not already have and keeps this body free
  # of arbitrary tenant data.
  @spec violation_map(DefinitionViolation.t() | ValidationFailure.t()) :: map()
  defp violation_map(%DefinitionViolation{rule: rule, path: path, message: message}) do
    %{
      "code" => Atom.to_string(rule),
      "path" => Enum.map(path, &to_string/1),
      "message" => message
    }
  end

  defp violation_map(%ValidationFailure{field_path: field_path, constraint: constraint}) do
    %{
      "code" => constraint,
      "path" => field_path,
      "message" => "#{field_path} violates #{constraint}"
    }
  end
end
