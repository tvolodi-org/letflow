defmodule Letflow.Routers.AdminServices do
  @moduledoc """
  Admin service-catalog sub-router (REQ-192, design
  `lib/letflow/design/req192-service-catalog-routes.md`). Mounted at
  `/admin/services` by `Letflow.Plugs.ApiPipeline`, so the full paths under
  `/api/v1` are `GET /api/v1/admin/services`, `POST /api/v1/admin/services`,
  `PATCH /api/v1/admin/services/:service_id`, and
  `DELETE /api/v1/admin/services/:service_id` — matching
  `web/src/api/services.ts`'s `servicesApi.listAll`/`register`/
  `updateScope`/`delete` calls exactly. Route/controller layer only, atop
  REQ-191's already-shipped `Letflow.ServiceCatalog` context module — no
  change to that module, `Letflow.ServiceCatalog.Entry`, or the
  `service_catalog` migration.

  ## Contract source

  See `Letflow.Routers.Services`'s moduledoc §0 — the same statement applies
  verbatim to this router's four routes.

  ## Two routers, one per mount prefix

  See `Letflow.Routers.Services`'s moduledoc — this router is deliberately
  separate from it (not a single router mounted at two prefixes), matching
  `test/letflow/api/authorization_enforcement_test.exs`'s strict
  one-router-to-one-mount-prefix `@mount_prefix` mechanism.

  ## Authorization (REQ-069, REQ-131)

  `GET /` is declared with the already-shipped `:AdminServicesRead` policy
  key; `POST /`, `PATCH /:service_id`, `DELETE /:service_id` are each
  declared with the already-shipped `:AdminServicesManage` policy key.
  `Letflow.Api.Authorization.endpoint_policy_key/2` already maps
  `GET "/admin/services"` to `:AdminServicesRead` and any `POST`/`PATCH`/
  `DELETE` on a path starting with `"/admin/services"` to
  `:AdminServicesManage`; `required_permission/1` maps both keys to
  `:PlatformServicesManage` (ISS-0993), a PLATFORM-scope permission. The
  global service catalogue is classified PLATFORM because `list_all/1`
  performs no tenant filtering (every tenant's entries with `owner_tenant_id`
  are visible and writable) and the table is global. It is honoured only for a
  `PLATFORM_ADMIN` whose database-resolved tenant is the configured platform
  tenant (`Letflow.PlatformTenant`); a `PLATFORM_ADMIN` of any other tenant
  gets `403` and never sees another tenant's `owner_tenant_id`. (These keys
  used to map to the tenant permission `:UsersGroupsRolesManage` by accident.)
  The tenant-facing catalogue is the separate, tenant-filtered `GET /services`.
  Enforcement is live (A2): a non-operator gets the same fixed 403 whether the path matches a route or not; the platform-tenant operator keeps the router's 404 on an unmatched path. No handler here names an existing tenant (no `authorize_target_tenant/2` call is needed): the platform gate runs before any handler.

  ## `GET /` — `Letflow.ServiceCatalog.list_all/1` (design §5, REVISED in
  ## rework iteration 2 — FLAGGED FOR REVIEWER SIGN-OFF, not pre-approved)

  Delegates to `Letflow.ServiceCatalog.list_all/1`, a new, additive,
  read-only function added to that context module by this requirement
  (see the module's own moduledoc for the full reasoning). This handler
  itself performs **no** direct `Ecto.Query`/`Letflow.Repo` access — the
  original iteration-1 design specified exactly that (a router-local query
  against `Letflow.ServiceCatalog.Entry`, bypassing the context module
  entirely), but implementing it caused
  `test/letflow/routers/req078_supporting_routes_test.exs`'s T-19
  (`INV-RT-1`, "no `Repo.` call anywhere under `lib/letflow/routers/`") to
  fail — a hard, allowlist-free, repo-wide invariant with no exception
  mechanism. `list_all/1` resolves that conflict by moving the
  tenant-agnostic query into the context module instead, so this router
  goes back to being a pure context-module-delegating router, same shape as
  every other router in `lib/letflow/routers/`.

  `list_all/1` performs **no** tenant or scope filtering whatsoever — see
  its own `@doc` in `lib/letflow/service_catalog.ex`. This router's own
  `:AdminServicesRead` policy key (`PLATFORM_ADMIN`-only, per
  `Letflow.Api.Authorization`) is what actually restricts this endpoint;
  `list_all/1` itself trusts the caller entirely.

  **REVIEWER must independently evaluate and sign off on this
  `Letflow.ServiceCatalog` scope expansion at Step 2d — it is not to be
  treated as routine or pre-approved by analogy to anything already in the
  codebase.**

  ## `auth_method` -> `:required_auth` translation (design §6)

  `RegisterServiceBody`'s own field is named `auth_method`, while
  `ServiceRecord`'s corresponding output field (and `Entry`'s column, and
  `register_attrs()`'s key) is `required_auth` — this asymmetry already
  exists in the frozen `web/src/api/services.ts` wire contract; this
  router's job is exactly to bridge it, the same way every other POST
  handler in this codebase translates a JSON body into a context module's
  expected attrs map. `max_retries` (in `RegisterServiceBody`) has no
  `register_attrs()` key and is dropped, never passed through (design §8
  finding 1).

  ## 409 problem-details bodies (REQ-066, design §11)

  Three `Letflow.Api.Error` constructors,
  `service_referenced_by_active_definitions/1` (delete-blocked by ACTIVE
  definitions), `service_referenced_by_active_instances/1` (delete-blocked by
  non-terminal pinned instances, ISS-0923) and
  `service_scope_narrowing_conflict/1` (narrow-blocked), modeled on the
  existing `Error.promotion_conflict/2`'s real RFC 9457 extensions-map
  shape. A duplicate `service_id` on register maps to plain
  `Response.conflict/2` instead (no structured extension needed — there is
  nothing to list beyond the one conflicting id already named in the
  request body).

  ## 422 `endpoint_url_reserved_variable` (GH #2623)

  `POST /` (register) and `POST /:service_id/versions` (publish) answer 422
  `{"error": "endpoint_url_reserved_variable", "field": "endpoint_url"}` when the supplied (or,
  on publish, inherited) `endpoint_url` references the reserved engine variable namespace
  (`{{variables._sys}}`, `{{variables._sys.<anything>}}`). The body echoes neither the URL nor
  the matched name. Every other changeset error on these two routes keeps the generic 422
  "validation failed" (including `:endpoint_url_not_allowed`).

  ## Cross-tenant-404 (design §10)

  None of the four routes here is tenant-filtered — every row is visible
  regardless of the caller's own tenant, by design (that is exactly what
  distinguishes this admin surface from `Letflow.Routers.Services`). A 404
  on `PATCH`/`DELETE` here means only "no such `service_id` exists at all",
  never a disguised cross-tenant-ownership check — REQ-072's
  cross-tenant-non-disclosure rule applies to the non-admin list endpoint
  instead (`Letflow.Routers.Services`), which is the only place a
  tenant-visibility distinction exists in this route set.

  ## POST /:service_id/versions, POST /:service_id/retire (REQ-373, design
  ## lib/letflow/design/req373-service-catalog-version-lifecycle.md §7)

  Two new routes, delegating to `Letflow.ServiceCatalog.publish/3` and
  `Letflow.ServiceCatalog.retire/1` respectively. Both `POST`, not `PATCH` --
  neither is a partial update of the existing resource's own fields (the
  existing `PATCH /:service_id` already owns `scope`/`owner_tenant_id`
  updates); each is an action that creates a new fact (a new version; a
  status transition).

  Gated by the already-shipped `:AdminServicesManage` policy key -- no new
  permission atom, no `lib/letflow/api/authorization.ex` change. That
  module's `endpoint_policy_key/2` already maps any `POST`/`PATCH`/`DELETE`
  path starting with `"/admin/services"` to `:AdminServicesManage` (design
  doc §0), so these two new `POST` paths are covered by the existing
  prefix-match clause automatically.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Error
  alias Letflow.Api.Pagination
  alias Letflow.Api.Response
  alias Letflow.ServiceCatalog
  alias Letflow.ServiceCatalog.Entry

  authz_get "/", :AdminServicesRead do
    handle_list(conn)
  end

  authz_post "/", :AdminServicesManage do
    handle_register(conn)
  end

  authz_patch "/:service_id", :AdminServicesManage do
    handle_update_scope(conn, conn.params["service_id"])
  end

  authz_delete "/:service_id", :AdminServicesManage do
    handle_delete(conn, conn.params["service_id"])
  end

  authz_post "/:service_id/versions", :AdminServicesManage do
    handle_publish(conn, conn.params["service_id"])
  end

  authz_post "/:service_id/retire", :AdminServicesManage do
    handle_retire(conn, conn.params["service_id"])
  end

  authz_unmatched(:platform_prefix)

  # ── GET /admin/services (design §5, revised) ──────────────────────────────
  #
  # Delegates to Letflow.ServiceCatalog.list_all/1 -- see moduledoc. No
  # Repo/Ecto.Query access in this router.

  defp handle_list(conn) do
    conn = fetch_query_params(conn)
    query = conn.query_params

    with {:ok, raw_page_size} <- Pagination.parse_page_size_param(Map.get(query, "page_size")),
         {:ok, page_size} <- Pagination.validate_page_size(raw_page_size) do
      params = %{
        cursor: non_empty(Map.get(query, "cursor")),
        page_size: page_size
      }

      params
      |> ServiceCatalog.list_all()
      |> handle_list_result(conn)
    else
      {:error, :invalid_page_size} ->
        Response.bad_request(conn, "invalid page_size")

      {:error, :page_size_too_large} ->
        Response.bad_request(conn, Letflow.Api.Pagination.page_size_error_message())
    end
  end

  defp handle_list_result({:ok, %{items: items, next_cursor: next_cursor}}, conn) do
    Response.ok(conn, %{
      "items" => Enum.map(items, &service_record_json/1),
      "next_cursor" => next_cursor
    })
  end

  defp handle_list_result({:error, reason}, conn)
       when reason in [:invalid_cursor, :wrong_endpoint, :expired] do
    Response.bad_request(conn, "invalid cursor")
  end

  # ── POST /admin/services (design §6) ──────────────────────────────────────

  defp handle_register(conn) do
    with {:ok, body} <- object_body(conn) do
      attrs =
        %{}
        |> maybe_put(body, "service_id", :service_id)
        |> maybe_put(body, "endpoint_url", :endpoint_url)
        |> maybe_put(body, "scope", :scope)
        |> maybe_put(body, "owner_tenant_id", :owner_tenant_id)
        |> maybe_put(body, "auth_method", :required_auth)
        |> maybe_put(body, "timeout_ms", :timeout_ms)
        |> maybe_put(body, "request_schema", :request_schema)
        |> maybe_put(body, "response_schema", :response_schema)

      case ServiceCatalog.register(attrs) do
        {:ok, entry} ->
          Response.created(conn, service_record_json(entry))

        {:error, :tenant_not_found} ->
          Response.unprocessable(conn, "owner_tenant_id does not name an existing tenant")

        {:error, :duplicate_service_id} ->
          Response.conflict(conn, "service_id already registered")

        {:error, %Ecto.Changeset{} = changeset} ->
          if reserved_endpoint_url?(changeset),
            do: Response.endpoint_url_reserved_variable(conn),
            else: Response.unprocessable(conn, "validation failed")
      end
    else
      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")
    end
  end

  # ── PATCH /admin/services/:service_id (design §9) ─────────────────────────

  defp handle_update_scope(conn, service_id) do
    with {:ok, body} <- object_body(conn) do
      attrs =
        %{}
        |> maybe_put(body, "scope", :scope)
        |> maybe_put(body, "owner_tenant_id", :owner_tenant_id)

      case ServiceCatalog.update_scope(service_id, attrs) do
        {:ok, entry} ->
          Response.ok(conn, service_record_json(entry))

        {:error, :not_found} ->
          Response.not_found(conn)

        {:error, {:referenced_by_active_definitions, conflicts}} ->
          Response.send_problem(conn, Error.service_scope_narrowing_conflict(conflicts))

        {:error, %Ecto.Changeset{}} ->
          Response.unprocessable(conn, "validation failed")
      end
    else
      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")
    end
  end

  # ── DELETE /admin/services/:service_id (design §12) ───────────────────────

  defp handle_delete(conn, service_id) do
    case ServiceCatalog.delete(service_id) do
      :ok ->
        Response.no_content(conn)

      {:error, :not_found} ->
        Response.not_found(conn)

      {:error, {:referenced_by_active_definitions, definition_ids}} ->
        Response.send_problem(
          conn,
          Error.service_referenced_by_active_definitions(definition_ids)
        )

      {:error, {:referenced_by_active_instances, refs}} ->
        Response.send_problem(conn, Error.service_referenced_by_active_instances(refs))
    end
  end

  # ── POST /admin/services/:service_id/versions (REQ-373 design §7) ─────────

  defp handle_publish(conn, service_id) do
    with {:ok, body} <- object_body(conn),
         {:ok, version} <- fetch_version(body) do
      attrs =
        %{}
        |> maybe_put(body, "endpoint_url", :endpoint_url)
        |> maybe_put(body, "request_schema", :request_schema)
        |> maybe_put(body, "response_schema", :response_schema)
        |> maybe_put(body, "auth_method", :required_auth)
        |> maybe_put(body, "timeout_ms", :timeout_ms)
        |> maybe_put(body, "retry_policy", :retry_policy)

      case ServiceCatalog.publish(service_id, version, attrs) do
        {:ok, entry} ->
          Response.created(conn, service_record_json(entry))

        {:error, :not_found} ->
          Response.not_found(conn)

        {:error, :duplicate_version} ->
          Response.conflict(conn, "version already exists for this service_id")

        {:error, %Ecto.Changeset{} = changeset} ->
          if reserved_endpoint_url?(changeset),
            do: Response.endpoint_url_reserved_variable(conn),
            else: Response.unprocessable(conn, "validation failed")
      end
    else
      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")

      {:error, :missing_version} ->
        Response.bad_request(conn, "version is required")
    end
  end

  defp fetch_version(body) do
    case Map.get(body, "version") do
      version when is_binary(version) and version != "" -> {:ok, version}
      _missing_or_invalid -> {:error, :missing_version}
    end
  end

  # ── POST /admin/services/:service_id/retire (REQ-373 design §7) ───────────

  defp handle_retire(conn, service_id) do
    case ServiceCatalog.retire(service_id) do
      {:ok, entry} ->
        Response.ok(conn, service_record_json(entry))

      {:error, :not_found} ->
        Response.not_found(conn)

      {:error, :already_retired} ->
        Response.conflict(conn, "service_id is already retired")
    end
  end

  # ── Request-body helpers ───────────────────────────────────────────────────

  defp object_body(conn) do
    case conn.body_params do
      %{"_json" => _non_object} -> {:error, :malformed_json}
      body when is_map(body) -> {:ok, body}
      _other -> {:error, :malformed_json}
    end
  end

  # GH #2623 / #2638: the stable reserved-variable code, from the validator or the DB CHECK.
  defp reserved_endpoint_url?(%Ecto.Changeset{} = changeset),
    do: Entry.reserved_endpoint_url_error?(changeset)

  defp maybe_put(attrs, body, body_key, attrs_key) do
    case Map.fetch(body, body_key) do
      {:ok, value} -> Map.put(attrs, attrs_key, value)
      :error -> attrs
    end
  end

  # ── Query-param parsing helpers ───────────────────────────────────────────

  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(value) when is_binary(value), do: value

  # ── Response allowlist (INV-2, design §7/§8) ──────────────────────────────
  #
  # Duplicated from Letflow.Routers.Services rather than shared -- matching
  # this codebase's one-router-per-mount-prefix precedent of each router
  # owning its own private response-allowlist function (dlq.ex/webhooks.ex),
  # not introducing a cross-router dependency the design does not call for.

  # REQ-373 design §7/§9 OQ-3 -- `version`/`version_id`/`status`/
  # `published_at`/`retired_at` are new fields with no frozen
  # web/src/api/services.ts wire contract yet; this follows the same
  # snake_case/ISO-8601-timestamp convention every existing field above
  # already uses.
  @spec service_record_json(Entry.t()) :: map()
  defp service_record_json(%Entry{} = entry) do
    %{
      "service_id" => entry.service_id,
      "endpoint_url" => entry.endpoint_url,
      "request_schema" => entry.request_schema,
      "response_schema" => entry.response_schema,
      "required_auth" => Atom.to_string(entry.required_auth),
      "timeout_ms" => entry.timeout_ms,
      "retry_policy" => entry.retry_policy,
      "scope" => Atom.to_string(entry.scope),
      "owner_tenant_id" => entry.owner_tenant_id,
      "version" => entry.version,
      "version_id" => entry.version_id,
      "status" => Atom.to_string(entry.status),
      "published_at" => DateTime.to_iso8601(entry.published_at),
      "retired_at" => optional_iso8601(entry.retired_at),
      "created_at" => DateTime.to_iso8601(entry.created_at),
      "updated_at" => DateTime.to_iso8601(entry.updated_at)
    }
  end

  defp optional_iso8601(nil), do: nil
  defp optional_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
