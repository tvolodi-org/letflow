defmodule Letflow.Routers.Definitions do
  @moduledoc """
  Process-definition sub-router, mounted at `/definitions` by
  `Letflow.Plugs.ApiPipeline`.

  PROVENANCE (historical, not current decision authority):
  REQ-078 adds **exactly one** route to it — the definition-graph validation
  endpoint. REQ-081 adds the five read routes below. REQ-082 adds the eight
  write/lifecycle routes below that. REQ-077 adds **exactly one** route —
  `POST /:process_key/rollback` (PRM-08, ports
  `src/api/routes/definition_rollback.zig`) — placed here only because
  `Letflow.Plugs.ApiPipeline` forwards `/definitions` here and `Plug.Router`
  permits one forward per prefix (`lib/letflow/design/req077-promotion-pipeline-routes.md`
  §2.3). REQ-081/082 own every other route under `/definitions` and must
  not treat this one route as precedent for their own design, nor remove
  it. Its handler, validation schema and response allowlist are specified
  in that design doc's §7.6. None of the four requirements touches the
  `match _` catch-all or modifies a route another of them added.

  `POST /:process_key/rollback` is declared with `authz_post` and the explicit
  key `:DefinitionsRollback` (ISS-0993, TENANT scope): it acts on the caller's
  OWN tenant schema only (`scoped_opts`), no tenant identifier is read from the
  request (REQ-446: named permission, TENANT scope, own-schema key lookup;
  a key absent from the caller's schema is the zero-detail 404).

  | Handler               | Method/path                       | Delegate                                              | Permission        | Response |
  |------------------------|-----------------------------------|--------------------------------------------------------|-------------------|----------|
  | validate               | `POST /definitions/:id/validate`  | `Letflow.Definitions.validate_definition_graph/2`       | none in REQ-078 (REQ-131) | 200 valid / 422 findings |
  | get_active_by_name     | `GET /definitions/active/:name`   | `Letflow.Definitions.get_active_by_name/2`              | `DefinitionsRead` | 200 / 404 |
  | search                 | `GET /definitions/search`         | `Letflow.Definitions.search_paginated/3`                | `DefinitionsRead` | 200 / 400 |
  | export                 | `GET /definitions/:id/export`     | `Letflow.Definitions.ExportImport.export/2`             | `DefinitionsRead` | 200 / 404 |
  | get_by_id              | `GET /definitions/:id`            | `Letflow.Definitions.get_by_id/2`                       | `DefinitionsRead` | 200 / 404 |
  | list                   | `GET /definitions`                | `Letflow.Definitions.list_paginated/2`                  | `DefinitionsRead` | 200 |
  | delta                  | `GET /definitions/delta`          | `Letflow.Definitions.delta/2`                           | `DefinitionsRead` | 200 / 400 |
  | create                 | `POST /definitions`               | `Letflow.Definitions.create_with_variable_schemas/3`    | `DefinitionsWrite` | 201 / 422 / 409 |
  | put                    | `PUT /definitions/:id`            | `Letflow.Definitions.update/3`                          | `DefinitionsWrite` | 200 / 404 / 409 / 422 |
  | patch                  | `PATCH /definitions/:id`          | `Letflow.Definitions.update/3`                          | `DefinitionsWrite` | 200 / 404 / 409 / 422 |
  | delete                 | `DELETE /definitions/:id`         | `hard_delete/2` (DRAFT) or `deprecate/2`+`archive/2` (ACTIVE/DEPRECATED) | `DefinitionsWrite` | 204 / 200 / 404 / 409 |
  | activate               | `POST /definitions/:id/activate`  | `Letflow.Definitions.activate/2`                        | `DefinitionsWrite` | 200 / 404 / 409 / 422 |
  | deprecate              | `POST /definitions/:id/deprecate` | `Letflow.Definitions.deprecate/2`                       | `DefinitionsWrite` (REQ-082 divergence — see below) | 200 / 404 / 409 |
  | archive                | `POST /definitions/:id/archive`   | `Letflow.Definitions.archive/2`                         | `DefinitionsWrite` (REQ-082 divergence — see below) | 200 / 404 / 409 |
  | import                 | `POST /definitions/import`        | `Letflow.Definitions.ExportImport.import_with_variable_schemas/4` | `DefinitionsWrite` (REQ-082 divergence — see below) | 201 / 422 |

  ## REQ-082 — write/lifecycle routes: a permission-gate divergence from R-Co

  PROVENANCE (historical, not current decision authority):
  These four routes have no pre-existing permission-gate precedent to
  inherit — confirmed by grepping R-Co's `authorization.zig` for
  `endpoint_policy_key` entries covering deprecate/archive/delete/import,
  zero hits, the same
  "no clause, not permission-gated" shape REQ-078/079 already established
  for rebind-pins/reconstruct. REQ-082's own acceptance criterion 7 ("a
  caller without DefinitionsWrite receives 403 on all eight endpoints") is
  what requires gating these four — see `Letflow.Api.Authorization`'s own
  comment at its four new clauses for the full reasoning.

  ## REQ-081 — read routes (design: `lib/letflow/design/req081-definition-routes-read.md`)

  Five `GET` handlers, all delegating into `Letflow.Definitions`/
  `Letflow.Definitions.ExportImport` (both already shipped, except
  `list_paginated/2`/`search_paginated/3` which REQ-081 adds). Every one is
  wrapped in `with_authorized_scope/4`, copied structurally from
  `Letflow.Routers.Instances`'s own private helper of the same name and
  shape (temporary direct duplication, pending REQ-131's consolidation —
  same precedent, not a shared/imported module).

  ### Route ordering

  PROVENANCE (historical, not current decision authority):
  `/active/:name`, `/search`, `/:id/export`, and (REQ-125) `/delta` are
  declared **above** `/:id`, which is declared above `/` (this registration
  order also appears in `main.zig`), for the same
  reason `Letflow.Routers.Instances`'s `/:id/history`-before-`/:id` note
  documents:
  `Plug.Router` is first-match-wins, so a bare `GET "/:id"` declared above any
  of these would swallow it with `id` bound to the literal suffix (`"delta"`
  for `/delta`).

  ## REQ-125 — `GET /definitions/delta` (design: `lib/letflow/design/req125-definitions-delta-sync.md`)

  Delegates to `Letflow.Definitions.delta/2` — see that function's `@doc` and
  this module's own moduledoc addendum for the cursor-semantics reasoning
  (AC2). `since` is read from `conn.query_params["since"]`: absent -> `nil`
  (full history); a decimal-digit string -> the parsed integer;
  present-but-non-numeric -> `{:error, :invalid_since}`, the same 400
  `delta/2`'s own syntactic-validity check (a negative integer) produces.
  Parsing uses `Integer.parse/1` requiring full-string consumption — the same
  idiom `Letflow.Api.Pagination.parse_page_size_param/1` already uses. `items`
  is rendered through the **existing** `definition_map/1` allowlist — no new
  response shape to audit for INV-2, `status` included (AC3: a deprecated or
  archived definition is representable in the delta response by its `status`
  field, no separate tombstone type).

  ### `handle_search`'s three-way HTTP contract (AC2/AC3)

  `Definitions.search_paginated/3` returns `{:error, :query_empty}`/
  `{:error, :query_too_long}` for a validation failure (mapped to **400**,
  matching REQ-081's acceptance criteria text verbatim — both are
  malformed-input errors, not semantic-validation failures, so 400 is the
  correct class for both), and a genuinely-valid,
  zero-match query returns `{:ok, %{items: [], next_cursor: nil}}` (**200**,
  empty array) — never conflated. `render_search_result/1`'s clause list
  keeps these as three separate code paths.

  ### `get_by_id`/`export` inherit `get_by_id/2`'s not-found collapse (OQ-2)

  Neither handler pre-casts `:id` to a UUID the way `Letflow.Routers.Instances`
  does for `instance_id` — `Letflow.Definitions.get_by_id/2` (REQ-030) already
  internally maps a cast failure to `{:error, :not_found}` (its own
  `cast_uuid/1`), so a malformed UUID and a genuinely-absent-but-well-formed
  UUID collapse to the same 404 — the **stronger** INV-5 guarantee, since a
  caller gets no signal distinguishing "malformed" from "absent" either way,
  flagged in the design doc for REVIEWER sign-off rather than silently
  decided.

  PROVENANCE (historical, not current decision authority):
  ## Two different R-Co files are called `validation.zig`. They are unrelated.

    PROVENANCE (historical, not current decision authority):
    * `src/api/routes/validation.zig` (173 lines) is the **definition-graph
      validation endpoint** — `POST /api/v1/definitions/:id/validate`,
      VLD-01/02/03, which runs validators over a *stored process-definition
      graph*. **That is what is ported here, by REQ-078.**
    PROVENANCE (historical, not current decision authority):
    * `src/api/validation.zig` (592 lines) is the **request-body validator** —
      API-07, which checks an *incoming JSON request payload* against a
      field-constraint schema and returns RFC 9457 field errors. It has
      nothing to do with process definitions. **That is ported by REQ-068, as
      `Letflow.Api.Validation` (`lib/letflow/api/validation.ex`).**

  Both appear in this module — the second as the `Letflow.Api.Validation`
  calls that check request bodies, the first as this endpoint's own delegate.
  Do not conflate them, and do not "consolidate" them: they validate different
  things at different layers. `Letflow.Api.Validation`'s own moduledoc carries
  a pointer back to this section, so a reader arriving from either side finds
  the distinction.

  ## The `/validation` sub-router stub was DELETED, not left unused

  PROVENANCE (historical, not current decision authority):
  REQ-070 reserved a `Letflow.Routers.Validation` at `/validation`, grouping
  by Zig **filename** (`routes/validation.zig`) rather than by URL. **R-Co has
  no `/validation` URL prefix anywhere**; the real path is
  `POST /api/v1/definitions/:id/validate` (`main.zig:777-784`,
  `validation.zig:6`), which is a `/definitions` route. Since
  `Plug.Router.forward/2` is prefix-exclusive, two sub-routers cannot both own
  `/definitions`, so a `/validation`-mounted module could never carry R-Co's
  real path. The stub's own moduledoc promised "Routes added by REQ-078", so
  leaving it in place unused would have left behind a module documenting a
  promise it did not keep. It and its forward are gone.

  ## The route adds no validation rule of its own (AC4)

  Everything this handler does after casting `:id` is
  `Letflow.Definitions.validate_definition_graph/2`, which runs exactly
  `Graph.validate_graph/1`, `validate_node_attributes/1` and
  `validate_edge_conditions/1` and concatenates their violations in that
  order. The route contains **no** validation logic, so "the endpoint agrees
  with the validators called directly" is structural, not merely tested.

  `Letflow.Definitions.ServiceScopeValidator.validate/3` is **deliberately
  excluded** — it needs an injected `Lookup.t()` this endpoint has no source
  for, and including it would break that equality.
  `Letflow.Definitions.activate/2` remains its owning path.

  ## `"valid"`, not `"semantically_valid"` — a deliberate divergence

  PROVENANCE (historical, not current decision authority):
  R-Co emits `"status":"semantically_valid"` plus `"compiler_version"`
  (`validation.zig:115-118`), because its VLD-01/02/03 pipeline performs
  expression type-checking and its VLD-04 gate persists a verdict with a
  compiler version. **Letflow has ported neither.** Claiming
  `"semantically_valid"` would overclaim what was actually checked, and
  `compiler_version` has no value to report. Letflow emits `"valid"` and omits
  `compiler_version`.

  Violations live under a **different key per outcome**, by construction:

  | Outcome | Status | Where violations live |
  |---|---|---|
  | valid   | 200 | `"findings"` — always `[]`; `"warnings"` — advisory unbound-task-role lines (REQ-455) |
  | invalid | 422 | `"errors"`, the RFC 9457 extension member |

  A success body is not a problem document and must not carry
  problem-document members.

  ## INV-5 — cross-tenant is 404, and it is the same 404

  PROVENANCE (historical, not current decision authority):
  An `:id` belonging to another tenant is invisible in the caller's
  prefix-scoped schema, so `get_by_id/2` returns `{:error, :not_found}` — the
  **same call, same code path, same query count and same response bytes** as a
  genuinely absent id. `Letflow.Api.Response.not_found/1` takes no detail, so
  there is no slot through which the two could differ. This matches
  `validation.zig:31`'s own documented behaviour: "cross-tenant reads fall
  through as `DefinitionNotFound` (HTTP 404)". No handler may add a
  cross-tenant existence check to produce a nicer message.

  ## Authorization gap — REQ-131 closes it

  PROVENANCE (historical, not current decision authority):
  This route does not call `Letflow.Api.Authorization.evaluate_access/2`.
  `endpoint_policy_key/2` has no clause for
  `POST /definitions/:id/validate` — there is no existing policy clause to
  extend (R-Co's `authorization.zig` has no entry for it either, so there
  is no precedent to port from there either), and deciding what permission
  a definition validation requires is a policy question belonging to
  **REQ-130/REQ-131**. Inventing a route-local permission check here was
  explicitly ruled out. The route is authenticated and tenant-scoped but not
  permission-gated; **REQ-131 is the closer.**

  ## Ordering guarantee

  Honours the contract stated in `Letflow.Routers.Tenants`'s moduledoc section
  **"Ordering guarantee (design §6.1)"**: no `Repo` call of any kind happens
  before the scoped prefix has been resolved. Structural here — **this module
  performs no `Repo` call at all**; the one read is inside
  `Letflow.Definitions.validate_definition_graph/2`, whose `opts` argument
  *is* the prefix.
  """

  use Letflow.Api.AuthorizedRouter

  require Logger

  alias Letflow.Api.Error
  alias Letflow.Api.Pagination
  alias Letflow.Api.Response
  alias Letflow.Api.Validation
  alias Letflow.Api.Validation.FieldConstraint
  alias Letflow.Definitions
  alias Letflow.Definitions.ExportImport
  alias Letflow.Definitions.ExportImport.ExportDocument
  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.ServiceScopeValidator

  # REQ-082 -- must precede `post "/:id/activate"` etc below: "/import" is a
  # literal one-segment suffix distinct from any `/:id/...` two-segment
  # pattern, so it cannot actually collide with them regardless of
  # declaration order today -- but it is declared first anyway, so that if a
  # bare `post "/:id"` is ever added to this file (there is none today; see
  # this module's moduledoc "Route ordering"), it is visibly obvious this
  # route must stay above it.
  authz_post "/import", :DefinitionsImport do
    handle_import(conn)
  end

  authz_post "/", :DefinitionsCreate do
    handle_create(conn)
  end

  # REQ-082 write/lifecycle routes. MUST precede `get "/:id"`/`put "/:id"`
  # sharing the same `:id` wildcard segment is fine (different HTTP methods
  # are independent dispatch tables in `Plug.Router`, same note REQ-080's
  # moduledoc makes for GET vs POST) -- the three `/:id/<verb>` routes below
  # only need to stay ABOVE a hypothetical bare `post "/:id"`, which this
  # file does not have.
  authz_post "/:id/activate", :DefinitionsActivate do
    handle_activate(conn, conn.params["id"])
  end

  authz_post "/:id/deprecate", :DefinitionsDeprecate do
    handle_deprecate(conn, conn.params["id"])
  end

  authz_post "/:id/archive", :DefinitionsArchive do
    handle_archive(conn, conn.params["id"])
  end

  authz_put "/:id", :DefinitionsUpdate do
    handle_put(conn, conn.params["id"])
  end

  authz_patch "/:id", :DefinitionsPatch do
    handle_patch(conn, conn.params["id"])
  end

  authz_delete "/:id", :DefinitionsDelete do
    handle_delete(conn, conn.params["id"])
  end

  # REQ-081 read routes. MUST precede `get "/:id"` below -- see this
  # module's moduledoc "Route ordering".
  authz_get "/active/:name", :DefinitionsRead do
    handle_get_active_by_name(conn, conn.params["name"])
  end

  authz_get "/search", :DefinitionsRead do
    handle_search(conn)
  end

  # REQ-125 -- MUST precede `get "/:id"` below, same ordering hazard as
  # `/active/:name`/`/search`/`/:id/export` (see this module's moduledoc
  # "Route ordering"): a literal path segment declared below `/:id` would be
  # swallowed with `id => "delta"`.
  authz_get "/delta", :DefinitionsRead do
    handle_delta(conn)
  end

  authz_get "/:id/export", :DefinitionsRead do
    handle_export(conn, conn.params["id"])
  end

  authz_get "/:id", :DefinitionsRead do
    handle_get_by_id(conn, conn.params["id"])
  end

  authz_get "/", :DefinitionsRead do
    handle_list(conn)
  end

  # REQ-131: endpoint_policy_key/2 has no ("POST", "/definitions/:id/validate")
  # clause (see "Authorization gap" above) -- :DefinitionsRead is a
  # route-declared policy key (read access is sufficient to run a
  # read-only, non-mutating validation pass over an already-stored graph),
  # not derived from Authorization.endpoint_policy_key/2. Named on the
  # enforcement test's explicit allowlist (design §4) -- flagged for
  # REVIEWER as a judgment call, not silently decided.
  authz_post "/:id/validate", :DefinitionsRead do
    handle_validate(conn, conn.params["id"])
  end

  # REQ-077 R9 -- the ONE route this requirement contributes to this router
  # (design §2.3): own-tenant TENANT scope, key :DefinitionsRollback (ISS-0993,
  # no longer :Unknown). See
  # Letflow.Routers.Promotions' moduledoc for the full reasoning this route
  # shares with all ten REQ-077 routes. `:process_key` is a free-form
  # string (process_definitions.name has no numeric/UUID shape), so there
  # is nothing to pre-cast here, unlike `/:id`'s UUID segments above.
  authz_post "/:process_key/rollback", :DefinitionsRollback do
    handle_rollback(conn, conn.params["process_key"])
  end

  authz_unmatched(:ordinary)

  # PROVENANCE (historical, not current decision authority):
  # ── POST /definitions/:id/validate (design §7) ────────────────────────────
  #
  # Bodyless, like Letflow.Routers.Tenants's deactivate/reactivate:
  # `conn.body_params` is ignored. R-Co's handleValidate takes no body either
  # (validation.zig:75-80).

  defp handle_validate(conn, raw_id) do
    case cast_id(raw_id) do
      {:ok, id} ->
        render_validation(
          conn,
          Definitions.validate_definition_graph(id, conn.assigns.scoped_opts)
        )

      {:error, :invalid_id_format} ->
        Response.unprocessable(conn, "invalid id format")
    end
  end

  defp render_validation(conn, {:ok, %{valid: true, definition_id: definition_id} = result}) do
    Response.ok(conn, %{
      "status" => "valid",
      "findings" => [],
      "warnings" => Map.get(result, :warnings, []),
      "definition_id" => definition_id,
      "validated_at" => DateTime.to_iso8601(DateTime.utc_now())
    })
  end

  defp render_validation(conn, {:ok, %{valid: false, violations: violations}}) do
    # The constructor-then-override idiom Letflow.Api.Validation.problem/1
    # already uses: `@problems_base` is a PRIVATE compile-env attribute on
    # Letflow.Api.Error and is not referenceable from here, so the `type`
    # field cannot be written literally -- it must come from the constructor.
    Response.send_problem(
      conn,
      %{
        Error.unprocessable("definition graph failed validation")
        | errors: Enum.map(violations, &violation_map/1)
      }
    )
  end

  # INV-5: absent and another tenant's are the same bytes because they are the
  # same call.
  defp render_validation(conn, {:error, :not_found}), do: Response.not_found(conn)

  defp render_validation(conn, {:error, :graph_structure_invalid}),
    do: Response.unprocessable(conn, "definition graph is not well-formed")

  # {:error, :invalid_schema_name} / {:error, {:transaction_failed, _}}.
  # No 503 branch -- Ecto surfaces pool exhaustion as a raised
  # DBConnection.ConnectionError, never an error tuple.
  defp render_validation(conn, {:error, _common_error}), do: Response.internal_error(conn)

  # ── GET /definitions/:id (design §4.3) ─────────────────────────────────
  #
  # No pre-cast of `:id` -- see this module's moduledoc "get_by_id/export
  # inherit get_by_id/2's not-found collapse (OQ-2)".

  defp handle_get_by_id(conn, raw_id) do
    render_get_by_id(conn, Definitions.get_by_id(raw_id, conn.assigns.scoped_opts))
  end

  defp render_get_by_id(conn, {:ok, definition}),
    do: Response.ok(conn, definition_map(definition))

  defp render_get_by_id(conn, {:error, :not_found}), do: Response.not_found(conn)
  defp render_get_by_id(conn, {:error, _common_error}), do: Response.internal_error(conn)

  # ── GET /definitions (design §4.3) ─────────────────────────────────────

  defp handle_list(conn) do
    opts = conn.assigns.scoped_opts
    conn = fetch_query_params(conn)
    query = conn.query_params

    with {:ok, raw_page_size} <- Pagination.parse_page_size_param(Map.get(query, "page_size")),
         {:ok, page_size} <- Pagination.validate_page_size(raw_page_size) do
      filters = %{
        name: Map.get(query, "name"),
        status: parse_status(Map.get(query, "status")),
        stage: Map.get(query, "stage"),
        cursor: Map.get(query, "cursor"),
        page_size: page_size
      }

      render_list_result(conn, Definitions.list_paginated(filters, opts))
    else
      {:error, :invalid_page_size} -> Response.bad_request(conn, "invalid page_size")
      {:error, :page_size_too_large} -> Response.bad_request(conn, "page_size out of range")
    end
  end

  # `status` is compared against ProcessDefinition.status/0's lowercase atoms
  # inside Definitions.list_paginated/2's where_status/2 (unchanged, existing
  # helper) -- absent/unrecognised values pass through as a plain lowercased
  # string/atom-cast attempt is deliberately NOT done here: where_status/2
  # itself does a plain `==` comparison against the stored (already-atom)
  # column, so an unrecognised string simply matches no rows rather than
  # raising, matching this module's existing no-extra-validation-layer style.
  defp parse_status(nil), do: nil

  defp parse_status(status) when is_binary(status) do
    status |> String.downcase() |> safe_to_existing_atom()
  end

  defp safe_to_existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp render_list_result(conn, {:ok, %{items: items, next_cursor: next_cursor}}) do
    Response.ok(conn, %{
      "items" => Enum.map(items, &definition_map/1),
      "next_cursor" => next_cursor
    })
  end

  defp render_list_result(conn, {:error, :invalid_cursor}),
    do: Response.bad_request(conn, "invalid cursor")

  defp render_list_result(conn, {:error, :wrong_endpoint}),
    do: Response.bad_request(conn, "cursor is not valid for this endpoint")

  defp render_list_result(conn, {:error, :expired}),
    do: Response.send_problem(conn, Error.cursor_expired())

  defp render_list_result(conn, {:error, _common_error}), do: Response.internal_error(conn)

  # ── GET /definitions/delta (REQ-125, MOB-3 delta sync) ─────────────────

  defp handle_delta(conn) do
    opts = conn.assigns.scoped_opts
    conn = fetch_query_params(conn)

    case parse_since_param(Map.get(conn.query_params, "since")) do
      {:ok, since} -> render_delta_result(conn, Definitions.delta(since, opts))
      {:error, :invalid_since} -> Response.bad_request(conn, "invalid since")
    end
  end

  # Absent `since` -> nil (full history, per Definitions.delta/2). A present
  # value must parse as a decimal integer with no remainder -- the same
  # full-string-consumption idiom Pagination.parse_page_size_param/1 already
  # uses -- otherwise {:error, :invalid_since}, the same 400 Definitions.delta/2
  # itself returns for a syntactically-invalid (e.g. negative) since. No
  # separate int-parsing validation layer beyond this.
  defp parse_since_param(nil), do: {:ok, nil}

  defp parse_since_param(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {int, ""} -> {:ok, int}
      _not_a_clean_integer -> {:error, :invalid_since}
    end
  end

  defp render_delta_result(conn, {:ok, %{items: items, next_since: next_since}}) do
    Response.ok(conn, %{
      "items" => Enum.map(items, &definition_map/1),
      "next_since" => next_since
    })
  end

  defp render_delta_result(conn, {:error, :invalid_since}),
    do: Response.bad_request(conn, "invalid since")

  defp render_delta_result(conn, {:error, _common_error}), do: Response.internal_error(conn)

  # ── GET /definitions/active/:name (design §4.3) ────────────────────────

  defp handle_get_active_by_name(conn, name) do
    render_get_by_id(conn, Definitions.get_active_by_name(name, conn.assigns.scoped_opts))
  end

  # ── GET /definitions/search (design §4.4 -- the requirement's stated trap) ──

  defp handle_search(conn) do
    opts = conn.assigns.scoped_opts
    conn = fetch_query_params(conn)
    query = conn.query_params

    with {:ok, raw_page_size} <- Pagination.parse_page_size_param(Map.get(query, "page_size")),
         {:ok, page_size} <- Pagination.validate_page_size(raw_page_size) do
      q = Map.get(query, "q") || ""
      params = %{cursor: Map.get(query, "cursor"), page_size: page_size}

      render_search_result(conn, Definitions.search_paginated(q, params, opts))
    else
      {:error, :invalid_page_size} -> Response.bad_request(conn, "invalid page_size")
      {:error, :page_size_too_large} -> Response.bad_request(conn, "page_size out of range")
    end
  end

  # Five clauses, one per outcome -- query_empty/query_too_long are
  # validation failures (400), never routed through the {:ok, ...} clause's
  # empty-array path and never mapped to 404. See this module's moduledoc.
  defp render_search_result(conn, {:ok, %{items: items, next_cursor: next_cursor}}) do
    Response.ok(conn, %{
      "items" => Enum.map(items, &search_result_map/1),
      "next_cursor" => next_cursor
    })
  end

  defp render_search_result(conn, {:error, :query_empty}),
    do: Response.bad_request(conn, "q must not be empty")

  defp render_search_result(conn, {:error, :query_too_long}),
    do: Response.bad_request(conn, "q must not exceed 512 bytes")

  defp render_search_result(conn, {:error, :invalid_cursor}),
    do: Response.bad_request(conn, "invalid cursor")

  defp render_search_result(conn, {:error, :wrong_endpoint}),
    do: Response.bad_request(conn, "cursor is not valid for this endpoint")

  # REVIEWER fix (WF02-REQ081): use the dedicated cursor-expired problem
  # type, matching handle_list's own :expired clause above and
  # Letflow.Routers.Instances's established idiom -- a plain bad_request/2
  # here (as the design doc's §4.4 prose literally read) would give this
  # error condition a different wire-level `type` than every other
  # cursor-expired response in the API, for no reason.
  defp render_search_result(conn, {:error, :expired}),
    do: Response.send_problem(conn, Error.cursor_expired())

  # search_paginated exception hardening -- also covers
  # Definitions.search_paginated/3's own {:error, {:query_failed, exception}}
  # tuple (its try/rescue catch-all): `_common_error` is a variable name, not
  # a type constraint, so it already structurally matches any {:error, _}
  # two-tuple; no code change was needed here for that fix, only this note.
  defp render_search_result(conn, {:error, _common_error}), do: Response.internal_error(conn)

  defp search_result_map(%{definition: definition, rank: rank}) do
    %{"definition" => definition_map(definition), "rank" => rank}
  end

  # ── GET /definitions/:id/export (design §4.3) ──────────────────────────
  #
  # No pre-cast of `:id` -- same OQ-2 rationale as handle_get_by_id/2, since
  # ExportImport.export/2 delegates its own read entirely to
  # Definitions.get_by_id/2.

  defp handle_export(conn, raw_id) do
    render_export(conn, ExportImport.export(raw_id, conn.assigns.scoped_opts))
  end

  defp render_export(conn, {:ok, document}), do: Response.ok(conn, export_document_map(document))
  defp render_export(conn, {:error, :not_found}), do: Response.not_found(conn)
  defp render_export(conn, {:error, _common_error}), do: Response.internal_error(conn)

  # ── POST /definitions (REQ-082, design §"write routes"/create) ─────────

  @create_schema [
    %FieldConstraint{name: "name", required: true, type: :string, reject_empty_string: true},
    %FieldConstraint{name: "version", required: true, type: :string, reject_empty_string: true},
    %FieldConstraint{name: "description", required: false, type: :string},
    %FieldConstraint{name: "graph", required: true, type: :object},
    %FieldConstraint{name: "stage", required: false, type: :string},
    %FieldConstraint{name: "variable_schemas", required: false, type: :array}
  ]

  defp handle_create(conn) do
    opts = conn.assigns.scoped_opts
    actor_id = conn.assigns.auth_context.user_id

    with {:ok, body} <- object_body(conn),
         {:ok, attrs} <- validate_schema(@create_schema, body),
         {:ok, entries} <- normalise_variable_schema_entries(Map.get(attrs, "variable_schemas")) do
      create_attrs = %{
        name: Map.fetch!(attrs, "name"),
        version: Map.fetch!(attrs, "version"),
        description: Map.get(attrs, "description"),
        graph: Map.fetch!(attrs, "graph"),
        stage: Map.get(attrs, "stage"),
        created_by: actor_id
      }

      render_write(
        conn,
        Definitions.create_with_variable_schemas(create_attrs, entries || [], opts),
        :created
      )
    else
      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")

      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))

      {:error, :invalid_variable_schemas} ->
        Response.unprocessable(conn, "variable_schemas entries are malformed")
    end
  end

  # ── PUT /definitions/:id (REQ-082, design §"write routes"/put) ─────────
  #
  # Full replacement: name/version/graph
  # are structurally required by this schema; description/stage are read
  # directly from the raw body afterward (not through this schema, which
  # would treat an explicit `null` identically to "absent" -- see
  # Letflow.Api.Validation.validate_field/2's `present? = value != :missing
  # and value != nil`) so that PUT always touches both, defaulting to `nil`
  # when the caller omits them entirely -- the semantic difference from
  # PATCH's has-key-based touch below, per this module's own judgment call
  # (R-Co's PutDefinitionBody carries no `variable_schemas` field at all --
  # a Letflow-only addition, so has-key semantics for it, same as PATCH).

  @put_schema [
    %FieldConstraint{name: "name", required: true, type: :string, reject_empty_string: true},
    %FieldConstraint{name: "version", required: true, type: :string, reject_empty_string: true},
    %FieldConstraint{name: "graph", required: true, type: :object}
  ]

  defp handle_put(conn, raw_id) do
    opts = conn.assigns.scoped_opts

    with {:ok, body} <- object_body(conn),
         {:ok, attrs} <- validate_schema(@put_schema, body),
         {:ok, description} <- optional_string(Map.get(body, "description")),
         {:ok, stage} <- optional_string(Map.get(body, "stage")),
         {:ok, entries} <- normalise_variable_schema_entries(Map.get(body, "variable_schemas")) do
      update_attrs =
        %{
          name: Map.fetch!(attrs, "name"),
          version: Map.fetch!(attrs, "version"),
          description: description,
          graph: Map.fetch!(attrs, "graph"),
          stage: stage
        }
        |> maybe_put_variable_schemas(entries)

      render_write(conn, Definitions.update(raw_id, update_attrs, opts), :ok)
    else
      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")

      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))

      {:error, :invalid_optional_string} ->
        Response.unprocessable(conn, "request body failed validation")

      {:error, :invalid_variable_schemas} ->
        Response.unprocessable(conn, "variable_schemas entries are malformed")
    end
  end

  # ── PATCH /definitions/:id (REQ-082, design §"write routes"/patch) ─────
  #
  # Every field optional; a key's PRESENCE in the request body (including an
  # explicit `null`) is what controls whether `Definitions.update/3` touches
  # that column -- see this module's `patch_attrs/1` and
  # `Letflow.Definitions.update_attrs()`'s own typedoc.

  @patch_schema [
    %FieldConstraint{name: "name", required: false, type: :string, reject_empty_string: true},
    %FieldConstraint{name: "version", required: false, type: :string, reject_empty_string: true},
    %FieldConstraint{name: "graph", required: false, type: :object}
  ]

  defp handle_patch(conn, raw_id) do
    opts = conn.assigns.scoped_opts

    with {:ok, body} <- object_body(conn),
         {:ok, attrs} <- validate_schema(@patch_schema, body),
         {:ok, entries} <- normalise_variable_schema_entries(Map.get(body, "variable_schemas")) do
      update_attrs = patch_attrs(body, attrs) |> maybe_put_variable_schemas(entries)
      render_write(conn, Definitions.update(raw_id, update_attrs, opts), :ok)
    else
      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")

      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))

      {:error, :invalid_variable_schemas} ->
        Response.unprocessable(conn, "variable_schemas entries are malformed")
    end
  end

  # `attrs` (from @patch_schema) carries name/version/graph only when both
  # present AND non-nil (Validation.validate_field/2's own present? check) --
  # description/stage are NOT in @patch_schema at all (it has no type
  # constraint to offer beyond "is a string", which a bare
  # `Map.has_key?/Map.get` check does not need), so they are read directly
  # from `body` here, has-key-based, preserving an explicit `null` as "clear".
  defp patch_attrs(body, attrs) do
    %{}
    |> maybe_put_present(:name, attrs, "name")
    |> maybe_put_present(:version, attrs, "version")
    |> maybe_put_present(:graph, attrs, "graph")
    |> maybe_put_present(:description, body, "description")
    |> maybe_put_present(:stage, body, "stage")
  end

  defp maybe_put_present(map, atom_key, source, string_key) do
    if Map.has_key?(source, string_key),
      do: Map.put(map, atom_key, Map.get(source, string_key)),
      else: map
  end

  defp maybe_put_variable_schemas(map, nil), do: map
  defp maybe_put_variable_schemas(map, entries), do: Map.put(map, :variable_schemas, entries)

  # A shared write-outcome renderer for create_with_variable_schemas/3's,
  # update/3's, and (below) hard_delete's non-deleted overlap. `success_status`
  # is `:created` (POST) or `:ok` (PUT/PATCH) -- create/update never share a
  # status code, so it is threaded through rather than guessed from the
  # outcome shape.
  defp render_write(conn, {:ok, %ProcessDefinition{} = definition}, :created),
    do: Response.created(conn, definition_map(definition))

  defp render_write(conn, {:ok, %ProcessDefinition{} = definition}, :ok),
    do: Response.ok(conn, definition_map(definition))

  # import-only: create/2 (and therefore create_with_variable_schemas/3) never
  # returns this reason -- only ExportImport.import_with_variable_schemas/4's
  # own schema-version gate does.
  defp render_write(conn, {:error, {:unknown_schema_version, _actual}}, :created),
    do: Response.unprocessable(conn, "unknown bpm_export_schema_version")

  defp render_write(conn, {:error, :not_found}, _success_status), do: Response.not_found(conn)

  defp render_write(conn, {:error, :not_draft}, _success_status),
    do: Response.conflict(conn, "only a DRAFT definition can be modified")

  defp render_write(conn, {:error, reason}, _success_status)
       when reason in [:name_invalid, :version_empty, :graph_structure_invalid],
       do: Response.unprocessable(conn, "request body failed validation")

  defp render_write(conn, {:error, {:graph_validation_failed, violations}}, _success_status) do
    Response.send_problem(
      conn,
      %{
        Error.unprocessable("definition graph failed validation")
        | errors: Enum.map(violations, &violation_map/1)
      }
    )
  end

  defp render_write(conn, {:error, :duplicate_name_version}, _success_status),
    do: Response.conflict(conn, "a definition with this name and version already exists")

  defp render_write(
         conn,
         {:error, {:variable_schema_registration_failed, reason}},
         _success_status
       ),
       do: render_variable_schema_error(conn, reason)

  defp render_write(conn, {:error, reason}, _success_status),
    do: render_variable_schema_error_or_500(conn, reason)

  # register_variable_schemas/3's own error union, reachable both tagged (via
  # create_with_variable_schemas/3's rollback) and untagged (via update/3's
  # own maybe_replace_variable_schemas/3, whose reason propagates through
  # update_error() untagged since it is update/3's OWN registration call, not
  # a nested one). Both land here.
  defp render_variable_schema_error(conn, {:duplicate_variable_key, _key}),
    do: Response.unprocessable(conn, "variable_schemas contains a duplicate variable_key")

  defp render_variable_schema_error(conn, {:blank_variable_key, _index}),
    do:
      Response.unprocessable(conn, "variable_schemas entries must have a non-blank variable_key")

  defp render_variable_schema_error(conn, {:variable_key_too_long, _index}),
    do: Response.unprocessable(conn, "a variable_key exceeds the maximum length")

  defp render_variable_schema_error(conn, {:not_well_formed, _key, _path}),
    do: Response.unprocessable(conn, "a variable_schemas entry's json_schema is not well-formed")

  defp render_variable_schema_error(conn, {:schema_too_deep, _key}),
    do:
      Response.unprocessable(conn, "a variable_schemas entry's json_schema is nested too deeply")

  defp render_variable_schema_error(conn, reason)
       when reason in [:missing_prefix, :invalid_definition_id],
       do: Response.internal_error(conn)

  defp render_variable_schema_error(conn, _other), do: Response.internal_error(conn)

  defp render_variable_schema_error_or_500(conn, reason)
       when is_tuple(reason) or reason in [:missing_prefix, :invalid_definition_id] do
    render_variable_schema_error(conn, reason)
  end

  defp render_variable_schema_error_or_500(conn, _internal), do: Response.internal_error(conn)

  defp optional_string(nil), do: {:ok, nil}
  defp optional_string(value) when is_binary(value), do: {:ok, value}
  defp optional_string(_invalid), do: {:error, :invalid_optional_string}

  # Per-element shape (variable_key present+string, json_schema present) has
  # no FieldConstraint vocabulary, so it is checked here -- mirrors
  # Letflow.Routers.Instances's normalise_entries/1 precedent exactly.
  # `nil` (key absent from the request) passes through unchanged so callers
  # can distinguish "absent" from "present, empty list" (see
  # Letflow.Definitions.update/3's own variable_schemas-touch contract).
  defp normalise_variable_schema_entries(nil), do: {:ok, nil}

  defp normalise_variable_schema_entries(entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case entry do
        %{"variable_key" => key} = e when is_binary(key) ->
          normalised = %{
            variable_key: key,
            json_schema: Map.get(e, "json_schema"),
            description: Map.get(e, "description")
          }

          {:cont, {:ok, [normalised | acc]}}

        _malformed ->
          {:halt, {:error, :invalid_variable_schemas}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  defp normalise_variable_schema_entries(_not_a_list), do: {:error, :invalid_variable_schemas}

  # ── DELETE /definitions/:id (REQ-082, design §"write routes"/delete) ───
  #
  # Status-dependent (PD-04): DRAFT -> hard delete (204). ACTIVE -> deprecate
  # then archive, TWO separate Definitions calls in the same request ("both
  # run in the same request; the second call receives DEPRECATED status")
  # -- reuses REQ-030's deprecate/2 and archive/2 exactly, no second state
  # machine. DEPRECATED -> archive. ARCHIVED -> 409. A get_by_id-then-act
  # read determines which branch to take -- a non-atomic two-step structure
  # (reads `current.status` then dispatches) that is an existing race in
  # the underlying status model, not one this router introduces.

  defp handle_delete(conn, raw_id) do
    opts = conn.assigns.scoped_opts

    case Definitions.get_by_id(raw_id, opts) do
      {:ok, %ProcessDefinition{status: :draft}} ->
        render_delete(conn, Definitions.hard_delete(raw_id, opts))

      {:ok, %ProcessDefinition{status: :active}} ->
        case Definitions.deprecate(raw_id, opts) do
          {:ok, _deprecated} ->
            render_transition(
              conn,
              Definitions.archive(raw_id, opts),
              "definition status changed concurrently; retry"
            )

          {:error, _reason} = error ->
            render_delete(conn, error)
        end

      {:ok, %ProcessDefinition{status: :deprecated}} ->
        render_transition(
          conn,
          Definitions.archive(raw_id, opts),
          "definition status changed concurrently; retry"
        )

      {:ok, %ProcessDefinition{status: :archived}} ->
        Response.conflict(conn, "definition is already archived")

      {:error, :not_found} ->
        Response.not_found(conn)

      {:error, _common_error} ->
        Response.internal_error(conn)
    end
  end

  defp render_delete(conn, {:ok, :deleted}), do: Response.no_content(conn)
  defp render_delete(conn, {:error, :not_found}), do: Response.not_found(conn)

  defp render_delete(conn, {:error, :not_draft}),
    do: Response.conflict(conn, "only a DRAFT definition can be hard-deleted")

  defp render_delete(conn, {:error, :invalid_status_transition}),
    do: Response.conflict(conn, "definition status changed concurrently; retry")

  defp render_delete(conn, {:error, _common_error}), do: Response.internal_error(conn)

  # ── POST /definitions/:id/activate (REQ-082, design §"write routes"/activate) ──
  #
  # ISS-0037/GH#112 -- the service-existence oracle. `opts[:service_scope_validator]`
  # is sourced from Application env, defaulting to `nil` (the SVC-03 injection
  # point's own documented default -- "there is no default, production-ready
  # Lookup in this codebase yet", Letflow.Definitions.ServiceScopeValidator's
  # moduledoc "Scope gap" section). Production therefore runs with the
  # {:service_scope_violation, _} branch below structurally unreachable today
  # (matching this codebase's own established "unreachable but mapped, for
  # defence-in-depth / future-readiness" pattern) until a real Lookup ships
  # (S6). Tests exercise it by setting
  # `Application.put_env(:letflow, :definitions_service_scope_validator, fun)`
  # before making the HTTP request and resetting it after -- this is the ONLY
  # seam through which the real router's handler can be driven end-to-end with
  # an injected validator, since `conn.assigns.scoped_opts` carries no
  # per-request override slot.

  defp handle_activate(conn, raw_id) do
    validator = Application.get_env(:letflow, :definitions_service_scope_validator, nil)
    activate_opts = Keyword.put(conn.assigns.scoped_opts, :service_scope_validator, validator)
    render_activate(conn, Definitions.activate(raw_id, activate_opts))
  end

  defp render_activate(conn, {:ok, %{definition: definition}}),
    do: Response.ok(conn, definition_map(definition))

  defp render_activate(conn, {:error, :not_found}), do: Response.not_found(conn)

  defp render_activate(conn, {:error, :not_draft}),
    do: Response.conflict(conn, "only a DRAFT definition can be activated")

  defp render_activate(conn, {:error, :graph_structure_invalid}),
    do: Response.unprocessable(conn, "definition graph is not well-formed")

  # ISS-0037/GH#112's own collapse: ONE generic 422 detail regardless of
  # which of the two internal reasons produced it -- never :service_not_registered
  # vs :service_not_available_to_tenant in the response body, never the raw
  # service_id substring. The distinct internal reason is logged (server-side
  # only) so diagnosability is not lost, just not externally observable.
  defp render_activate(
         conn,
         {:error, {:service_scope_violation, %ServiceScopeValidator.Violation{} = violation}}
       ) do
    Logger.warning(
      "definition activation blocked by service-scope violation " <>
        "node_id=#{inspect(violation.node_id)} kind=#{inspect(violation.kind)} " <>
        "reason=#{inspect(violation.reason)}"
    )

    Response.unprocessable(conn, "a referenced service is not usable by this tenant")
  end

  # ISS-0912 -- REQ-372's semantic decision-rule violations reaching activate.
  # Mirrors render_validation/2's {:ok, %{valid: false, violations: violations}}
  # clause (~L370-381) exactly: same 422, same violation_map/1 shape, so a
  # client renders both the standalone validate endpoint's and activate's
  # failures identically.
  defp render_activate(conn, {:error, {:semantic_validation_failed, violations}}) do
    Response.send_problem(
      conn,
      %{
        Error.unprocessable("definition graph failed semantic validation")
        | errors: Enum.map(violations, &violation_map/1)
      }
    )
  end

  # ISS-0912 -- run_semantic_validation/2 (lib/letflow/definitions.ex ~2354-2379)
  # could not even attempt the semantic pass (missing tenant prefix, or an
  # unparsable definition id reaching VariableSchema.fetch_schemas/3). This is
  # not a concurrent-state conflict (contrast :not_draft's 409 above) -- it is
  # a request/environment precondition the semantic check itself depends on,
  # so it gets the same 422 family as every other "activate could not
  # validate" branch in this function, with the internal reason surfaced
  # verbatim since it is not tenant-sensitive (an atom naming a missing
  # server-side precondition, never definition content).
  defp render_activate(conn, {:error, {:semantic_validation_precondition_failed, reason}}) do
    Response.unprocessable(
      conn,
      "semantic validation could not run (#{inspect(reason)})"
    )
  end

  # GH 2534 PR 7c-1 (decision 0053 D2; design gh2534-7c-script-handler.md 4.5): a graph binding a
  # tenant script that is not runnable as bound. The node id is the caller's own graph; the
  # reason is a closed code.
  defp render_activate(conn, {:error, {:script_binding_invalid, node_id, reason}}),
    do: script_binding_invalid(conn, node_id, reason)

  # GH #2587 PR A1b (design gh2587-req499-pr-a-prerequisites.md 2A.4): the graph names the
  # reserved engine namespace. Every echoed value comes from the caller's own graph (or a
  # property name of a script the same tenant published); no variable value.
  defp render_activate(conn, {:error, {:expression_references_reserved_variable, references}}),
    do: expression_references_reserved_variable(conn, references)

  defp render_activate(conn, {:error, _common_error}), do: Response.internal_error(conn)

  defp script_binding_invalid(conn, node_id, reason),
    do:
      Response.send_json(conn, 422, %{
        "error" => "script_binding_invalid",
        "node_id" => node_id,
        "reason" => Atom.to_string(reason)
      })

  defp expression_references_reserved_variable(conn, references),
    do:
      Response.send_json(conn, 422, %{
        "error" => "expression_references_reserved_variable",
        "references" => Enum.map(references, &reserved_reference_map/1)
      })

  defp reserved_reference_map(%{
         element: element,
         id: id,
         location: location,
         field: field,
         name: name
       }),
       do: %{
         "element" => Atom.to_string(element),
         "id" => id,
         "location" => Atom.to_string(location),
         "field" => field,
         "name" => name
       }

  # ── POST /definitions/:id/deprecate (REQ-082) ───────────────────────────

  defp handle_deprecate(conn, raw_id) do
    render_transition(
      conn,
      Definitions.deprecate(raw_id, conn.assigns.scoped_opts),
      "only an ACTIVE definition can be deprecated"
    )
  end

  # ── POST /definitions/:id/archive (REQ-082) ─────────────────────────────

  defp handle_archive(conn, raw_id) do
    render_transition(
      conn,
      Definitions.archive(raw_id, conn.assigns.scoped_opts),
      "only a DEPRECATED definition can be archived"
    )
  end

  defp render_transition(conn, {:ok, %ProcessDefinition{} = definition}, _conflict_detail),
    do: Response.ok(conn, definition_map(definition))

  defp render_transition(conn, {:error, :not_found}, _conflict_detail),
    do: Response.not_found(conn)

  defp render_transition(conn, {:error, :invalid_status_transition}, conflict_detail),
    do: Response.conflict(conn, conflict_detail)

  defp render_transition(conn, {:error, _common_error}, _conflict_detail),
    do: Response.internal_error(conn)

  # ── POST /definitions/import (REQ-082, design §"write routes"/import) ──
  #
  # Body shape mirrors Letflow.Definitions.ExportImport.ExportDocument's own
  # fields (bpm_export_schema_version/name/version/description/graph),
  # `id`/`exported_at` accepted but IGNORED (informational only --
  # ExportImport.import/3 never reads document.id when building its
  # create/2 call, so accepting-but-discarding these fields is consistent
  # with that contract), plus REQ-082's own `variable_schemas` addition.

  defp handle_import(conn) do
    opts = conn.assigns.scoped_opts
    actor_id = conn.assigns.auth_context.user_id

    with {:ok, body} <- object_body(conn),
         {:ok, schema_version} <- required_string(body, "bpm_export_schema_version"),
         {:ok, name} <- required_string(body, "name"),
         {:ok, version} <- required_string(body, "version"),
         {:ok, graph} <- required_object(body, "graph"),
         {:ok, entries} <- normalise_variable_schema_entries(Map.get(body, "variable_schemas")) do
      document = %ExportDocument{
        bpm_export_schema_version: schema_version,
        id: Map.get(body, "id"),
        name: name,
        version: version,
        description: Map.get(body, "description"),
        graph: graph,
        exported_at: Map.get(body, "exported_at")
      }

      render_write(
        conn,
        ExportImport.import_with_variable_schemas(document, entries || [], actor_id, opts),
        :created
      )
    else
      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")

      {:error, {:missing_field, field}} ->
        Response.unprocessable(conn, "#{field} is required")

      {:error, :invalid_variable_schemas} ->
        Response.unprocessable(conn, "variable_schemas entries are malformed")
    end
  end

  defp required_string(body, key) do
    case Map.get(body, key) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _missing_or_invalid -> {:error, {:missing_field, key}}
    end
  end

  defp required_object(body, key) do
    case Map.get(body, key) do
      value when is_map(value) and not is_struct(value) -> {:ok, value}
      _missing_or_invalid -> {:error, {:missing_field, key}}
    end
  end

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

  # ── Response allowlists (INV-2, design §6) ─────────────────────────────

  @spec definition_map(ProcessDefinition.t()) :: map()
  defp definition_map(%ProcessDefinition{} = definition) do
    %{
      "id" => definition.id,
      "name" => definition.name,
      "version" => definition.version,
      "description" => definition.description,
      "status" => status_string(definition.status),
      "graph" => definition.graph,
      "created_by" => definition.created_by,
      "created_at" => DateTime.to_iso8601(definition.created_at),
      "updated_at" => DateTime.to_iso8601(definition.updated_at),
      "archived_at" => optional_iso8601(definition.archived_at),
      "stage" => definition.stage
    }
  end

  @spec export_document_map(ExportDocument.t()) :: map()
  defp export_document_map(%ExportDocument{} = document) do
    %{
      "bpm_export_schema_version" => document.bpm_export_schema_version,
      "id" => document.id,
      "name" => document.name,
      "version" => document.version,
      "description" => document.description,
      "graph" => document.graph,
      "exported_at" => document.exported_at
    }
  end

  defp optional_iso8601(nil), do: nil
  defp optional_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp status_string(:draft), do: "DRAFT"
  defp status_string(:active), do: "ACTIVE"
  defp status_string(:deprecated), do: "DEPRECATED"
  defp status_string(:archived), do: "ARCHIVED"

  # ── POST /definitions/:process_key/rollback -- REQ-077 R9 ──────────────

  @rollback_schema [
    %FieldConstraint{
      name: "target_version",
      required: true,
      type: :string,
      reject_empty_string: true,
      max_length: 64
    }
  ]

  defp handle_rollback(conn, process_key) do
    opts = conn.assigns.scoped_opts
    actor_id = conn.assigns.auth_context.user_id

    case Validation.validate(@rollback_schema, conn.body_params) do
      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))

      {:ok, attrs} ->
        result =
          Definitions.rollback_definition_version(
            process_key,
            attrs["target_version"],
            actor_id,
            Keyword.merge(opts,
              permission_checker:
                Letflow.Definitions.PromotionAccess.checker_for(conn.assigns.auth_context),
              event_appender:
                &Letflow.EventStore.PlatformEvents.append_definition_version_rolled_back/2
            )
          )

        render_rollback(conn, result)
    end
  end

  defp render_rollback(conn, {:ok, result}), do: Response.ok(conn, rollback_map(result))

  defp render_rollback(conn, {:error, :forbidden}),
    do: Response.forbidden(conn, "insufficient permissions")

  # process_key with no ACTIVE definition in the caller's tenant is the same
  # fact as one that never existed -- zero-detail 404, matching §5's
  # cross-tenant/nonexistent byte-identity.
  defp render_rollback(conn, {:error, :process_key_not_found}), do: Response.not_found(conn)

  defp render_rollback(conn, {:error, :version_never_active}),
    do: Response.unprocessable(conn, "target_version was never active")

  defp render_rollback(conn, {:error, :already_active}),
    do: Response.unprocessable(conn, "target_version is already the active version")

  # GH 2534 PR 7c-1 (design 4.5): the re-activated graph's script bindings.
  defp render_rollback(conn, {:error, {:script_binding_invalid, node_id, reason}}),
    do: script_binding_invalid(conn, node_id, reason)

  # GH #2587 PR A1b (design 2A.4): the re-activated graph names the reserved namespace.
  defp render_rollback(conn, {:error, {:expression_references_reserved_variable, references}}),
    do: expression_references_reserved_variable(conn, references)

  defp render_rollback(conn, {:error, :invalid_schema_name}), do: Response.internal_error(conn)
  defp render_rollback(conn, {:error, _other}), do: Response.internal_error(conn)

  # PROVENANCE (historical, not current decision authority):
  # Exactly 5 keys (REQ-077 design §7.6), ported from
  # definition_rollback.zig:96-114. `version`/`rolled_back_from_version` are
  # STRINGS, not JSON numbers like R-Co -- process_definitions.version is
  # free-form text here (PromotionConflict.version_greater?/2's own
  # int-then-lexicographic fallback already documents this), so porting
  # R-Co's integer typing would reject versions this codebase permits.
  @doc false
  @spec rollback_map(Definitions.rollback_result()) :: map()
  defp rollback_map(result) do
    %{
      "definition_id" => result.definition_id,
      "version" => result.version,
      "rolled_back_from_version" => result.rolled_back_from_version,
      "superseded_review_id" => result.superseded_review_id,
      "event_id" => result.event_id
    }
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  # PROVENANCE (historical, not current decision authority):
  # Checked in the route before any call, matching validation.zig:83-85.
  defp cast_id(raw_id) do
    case Ecto.UUID.cast(raw_id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_id_format}
    end
  end

  # Total, not a redaction: %Graph.Violation{} has exactly two fields.
  # Letflow.Api.Error.serialise/1's `errors: [_ | _]` clause passes the list
  # straight to Jason.encode!/1, so these must already be plain string-keyed
  # maps -- never %Violation{} structs.
  @spec violation_map(Graph.Violation.t()) :: map()
  defp violation_map(%Graph.Violation{code: code, message: message}) do
    %{"code" => Atom.to_string(code), "message" => message}
  end
end
