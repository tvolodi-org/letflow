defmodule Letflow.Routers.Dlq do
  @moduledoc """
  Dead-letter-queue sub-router (REQ-178, design
  `lib/letflow/design/req178-dlq-routes.md`). Mounted at `/dlq` by
  `Letflow.Plugs.ApiPipeline`, so the full paths under `/api/v1` are
  `GET /api/v1/dlq`, `GET /api/v1/dlq/:id`, `POST /api/v1/dlq/:id/retry`, and
  `POST /api/v1/dlq/:id/discard` — matching `web/src/api/dlq.ts`'s `dlqApi`
  calls exactly. Route/controller layer only, atop REQ-176's `Letflow.Dlq`
  context module — no change to `Letflow.Dlq`, `Letflow.Dlq.Entry`, or the
  `dlq_entries` migration.

  ## Contract source

  PROVENANCE (historical, not current decision authority):
  R-Co's `dlq.zig` (337 lines, catalogued in
  `docs/migration/stage-4-api-surface.md`'s fronting-subsystem table) was
  **not inspected** while drafting this route layer — R-Co is at a Windows
  path unreachable from this sandbox, verified absent, not assumed covered.
  The binding contract instead is the already-shipped SPA consumer:
  `web/src/api/dlq.ts`'s `dlqApi` object and `web/src/types/api.ts`'s
  `DlqEntry`/`CursorPage<T>` types. A future reader must not assume this
  route layer's shape was cross-checked against R-Co's — it was not; the
  SPA consumer above is the only contract this router is bound to.

  ## Authorization (REQ-131, REQ-069)

  Every route below is declared via `authz_get`/`authz_post`
  (`Letflow.Api.AuthorizedRouter`) with the existing `:DlqReadRetryDiscard`
  policy key — `Letflow.Api.Authorization.endpoint_policy_key/2` already maps
  any `/dlq`-prefixed `GET`/`POST` path to it, and `required_permission/1`
  already maps `:DlqReadRetryDiscard` to the `:DlqOperate` permission (both
  clauses shipped under REQ-069, unchanged here). No new
  `endpoint_policy_key`/`required_permission` clause and no new permission
  atom are added by this requirement — `Letflow.Plugs.Authorize` evaluates
  `:DlqReadRetryDiscard` before any handler below ever runs.

  Per the real `role_allows?/2` matrix, `:DlqOperate` is held by
  `:PLATFORM_ADMIN` (catch-all clause) and `:PROCESS_OPERATOR` (explicit
  grant) — `:PROCESS_DESIGNER`, `:TASK_WORKER`, `:AGENT_RUNNER` do not hold
  it, so such a caller gets 403 before any handler runs. This matches
  `web/src/pages/dlq/DlqPage.tsx`'s client-side `OPERATE_ROLES` constant.

  ## Cross-tenant-404 (AC3, INV-5)

  No new mechanism — this router inherits `Letflow.Dlq.get/2`/`retry/2`/
  `discard/2`'s existing, gate-approved (REQ-176) behavior verbatim: every
  handler's only tenant input is `conn.assigns.scoped_opts`, itself derived
  solely from `conn.assigns.auth_context.tenant_id` by
  `Letflow.Plugs.Authorize`, before this router's code ever runs. A row that
  exists only in a different tenant's schema is indistinguishable, at the
  `Repo` level, from a row that does not exist anywhere — both resolve to
  `{:error, :not_found}` inside `Letflow.Dlq`, and this router maps that one
  tuple to `Response.not_found/1` for both cases, so the response bytes are
  identical by construction. `:invalid_id` (a malformed UUID) folds into the
  same `Response.not_found/1` call rather than a 400, deliberately diverging
  from `Letflow.Routers.Tasks`'s own `:invalid_id` -> 400 precedent: DLQ ids
  are cross-tenant-probeable UUIDs, so a malformed id and a genuinely-absent
  id must stay indistinguishable to the caller (design §4/§7 OQ-3).

  ## Terminal-state conflict (AC4)

  `retry/2`/`discard/2`'s `{:error, {:invalid_state, current_status}}` —
  returned exactly when the entry is already `:resolved` or `:discarded` —
  maps to `Response.conflict/2` with a fixed, non-interpolated detail
  string, never falling through to a generic 500. `Letflow.Dlq.retry/2`/
  `discard/2`'s own `@spec`s enumerate exactly four return shapes (no
  `Ecto.Changeset.t()` in that union), so this router's `case` is already
  exhaustive over the real contract.

  ## The retry of a step failure (pilot gap G7)

  An entry that names a step failure of the pilot's step library (a platform
  step or a notification step) is wired to the retry of that step: the row's
  own transition happens first and the step is run again afterwards
  (`Letflow.Dlq.retry/2`). That retry is a PLATFORM act -- it runs a platform
  function again -- so it carries an extra check the route's own
  `:DlqOperate` permission does not give: the caller must be in the platform
  tenant AND hold `:PLATFORM_ADMIN` there. A `:PROCESS_OPERATOR` (which holds
  `:DlqOperate`) is refused with a 403 for a step entry and keeps the old
  behaviour for every other entry.

  ## Response allowlist (INV-2)

  `dlq_entry_json/1` is a hand-built allowlist over every `Letflow.Dlq.Entry`
  column, matching `Letflow.Routers.Audit`'s own `audit_item/1` precedent —
  never a raw `Jason.Encoder` derivation over the Ecto struct, which would
  leak `__meta__`/`tenant_id`. `DlqEntry`'s TS type also declares
  `item_type`/`original_payload`/`processor_metadata`/`max_retries` as
  optional fields with no corresponding `Letflow.Dlq.Entry` column — these
  are **not emitted** (no schema-backed source, design §7 OQ-2). The list
  body is an exactly-two-key map, `{"items", "next_cursor"}` — no `has_more`
  key, matching `dlqApi.list`'s actual binding usage rather than
  `CursorPage<T>`'s full TS shape (design §7 OQ-1).
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Pagination
  alias Letflow.Api.Response
  alias Letflow.Dlq
  alias Letflow.Dlq.Entry
  alias Letflow.Instances.StepRetry
  alias Letflow.PlatformTenant

  authz_get "/", :DlqReadRetryDiscard do
    handle_list(conn)
  end

  authz_get "/:id", :DlqReadRetryDiscard do
    handle_get(conn, conn.params["id"], conn.assigns.scoped_opts)
  end

  authz_post "/:id/retry", :DlqReadRetryDiscard do
    handle_retry(conn, conn.params["id"], conn.assigns.scoped_opts)
  end

  authz_post "/:id/discard", :DlqReadRetryDiscard do
    handle_discard(conn, conn.params["id"], conn.assigns.scoped_opts)
  end

  authz_unmatched(:ordinary)

  # ── GET /dlq (design §3) ──────────────────────────────────────────────────

  defp handle_list(conn) do
    conn = fetch_query_params(conn)
    query = conn.query_params

    with {:ok, raw_page_size} <- Pagination.parse_page_size_param(Map.get(query, "page_size")),
         {:ok, page_size} <- Pagination.validate_page_size(raw_page_size) do
      params = %{
        status: non_empty(Map.get(query, "status")),
        entry_type: non_empty(Map.get(query, "source_type")),
        search: non_empty(Map.get(query, "search")),
        instance_id: non_empty(Map.get(query, "instance_id")),
        cursor: non_empty(Map.get(query, "cursor")),
        page_size: page_size
      }

      params
      |> Dlq.list(conn.assigns.scoped_opts)
      |> handle_list_result(conn)
    else
      {:error, :invalid_page_size} ->
        Response.bad_request(conn, "invalid page_size")

      {:error, :page_size_too_large} ->
        Response.bad_request(conn, "page_size out of range")
    end
  end

  defp handle_list_result({:ok, %{items: items, next_cursor: next_cursor}}, conn) do
    Response.ok(conn, %{
      "items" => Enum.map(items, &dlq_entry_json/1),
      "next_cursor" => next_cursor
    })
  end

  defp handle_list_result({:error, :invalid_filter}, conn) do
    Response.unprocessable(conn, "invalid filter")
  end

  defp handle_list_result({:error, reason}, conn)
       when reason in [:invalid_cursor, :wrong_endpoint, :expired] do
    Response.bad_request(conn, "invalid cursor")
  end

  # ── GET /dlq/:id (design §4) ──────────────────────────────────────────────

  defp handle_get(conn, id, opts) do
    case Dlq.get(id, opts) do
      {:ok, entry} ->
        Response.ok(conn, dlq_entry_json(entry))

      {:error, :not_found} ->
        Response.not_found(conn)

      {:error, :invalid_id} ->
        Response.not_found(conn)
    end
  end

  # ── POST /dlq/:id/retry, POST /dlq/:id/discard (design §6) ────────────────

  # The retry of a STEP failure (pilot gap G7) is a platform act: it runs a
  # platform function again, and only the platform admin may do that. The
  # `:DlqOperate` permission of this route is wider than that (it is held by
  # `:PROCESS_OPERATOR` too), so the step entries carry an EXTRA check: the
  # caller must be in the platform tenant AND hold `:PLATFORM_ADMIN` there
  # (`Letflow.PlatformTenant.scope_facts_for/1` recomputes both facts from
  # the server-resolved context -- never from a stored flag).
  #
  # The refusal is a 403 with a fixed detail: the entry's own state says
  # whether it names a step, so the answer does not depend on what the caller
  # may see.
  defp handle_retry(conn, id, opts) do
    with {:ok, entry} <- Dlq.get(id, opts) do
      if StepRetry.retryable_entry_type?(entry.entry_type) and
           not platform_scope?(Map.get(conn.assigns, :auth_context)) do
        Response.forbidden(conn, "forbidden")
      else
        id
        |> Dlq.retry(opts)
        |> handle_write_result(conn)
      end
    else
      {:error, :not_found} -> Response.not_found(conn)
      {:error, :invalid_id} -> Response.not_found(conn)
    end
  end

  # The platform scope of the caller: the platform tenant AND `:PLATFORM_ADMIN`
  # in it. A hand-assigned context without the keys stays fail-closed (both
  # facts false), so a caller that is not the platform admin is refused.
  defp platform_scope?(auth_context) when is_map(auth_context) do
    PlatformTenant.scope_facts_for(auth_context).platform_scope?
  end

  defp platform_scope?(_other), do: false

  defp handle_discard(conn, id, opts) do
    id
    |> Dlq.discard(opts)
    |> handle_write_result(conn)
  end

  defp handle_write_result({:ok, entry}, conn) do
    Response.ok(conn, dlq_entry_json(entry))
  end

  defp handle_write_result({:error, :not_found}, conn) do
    Response.not_found(conn)
  end

  defp handle_write_result({:error, :invalid_id}, conn) do
    Response.not_found(conn)
  end

  defp handle_write_result({:error, {:invalid_state, _current_status}}, conn) do
    Response.conflict(conn, "dlq entry is already terminal")
  end

  # ── Query-param parsing helpers ───────────────────────────────────────────

  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(value) when is_binary(value), do: value

  # ── Response allowlist (INV-2) ────────────────────────────────────────────

  # Hand-built, every Letflow.Dlq.Entry column -- never a Jason.Encoder
  # derivation over %Letflow.Dlq.Entry{}, which would leak `__meta__`/
  # `tenant_id`.
  @spec dlq_entry_json(Entry.t()) :: map()
  defp dlq_entry_json(%Entry{} = entry) do
    %{
      "id" => entry.id,
      "entry_type" => entry.entry_type,
      "instance_id" => entry.instance_id,
      "reference_id" => entry.reference_id,
      "reason" => entry.reason,
      "full_reason" => entry.full_reason,
      "error_detail" => entry.error_detail,
      "error_chain" => entry.error_chain,
      "source_payload" => entry.source_payload,
      "context_json" => entry.context_json,
      "retry_history" => entry.retry_history,
      "retry_count" => entry.retry_count,
      "retry_limit" => entry.retry_limit,
      "next_retry_at" => iso8601(entry.next_retry_at),
      "status" => Atom.to_string(entry.status),
      "created_at" => iso8601(entry.created_at),
      "first_failed_at" => iso8601(entry.first_failed_at),
      "last_failed_at" => iso8601(entry.last_failed_at)
    }
  end

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(nil), do: nil
end
