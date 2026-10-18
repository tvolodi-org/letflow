defmodule Letflow.Routers.Audit do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Audit-list sub-router (REQ-078, design
  `lib/letflow/design/req078-supporting-routes.md` §6). Ports
  `src/api/routes/audit.zig`'s `handleList` (L21). Mounted at `/audit` by
  `Letflow.Plugs.ApiPipeline`, so the full path under `/api/v1` is
  `GET /api/v1/audit` — byte-identical to R-Co, and to the path
  `web/src/api/audit.ts` already calls.

  | Handler | Method/path         | Delegate                            | Permission   | Response                          |
  |---------|---------------------|--------------------------------------|--------------|-----------------------------------|
  | list    | `GET /audit`        | `Letflow.Audit.list_entries/1`       | `:AuditRead` | 200, `{items, next_cursor, count}` |

  ## Served from `audit_entries` (REQ-196), not the event store

  `GET /audit` reads from REQ-195's `audit_entries` table
  (`Letflow.Audit.Entry`) via `Letflow.Audit.list_entries/1` — see
  `lib/letflow/design/req195-audit-entry-storage.md` for the table's schema
  and hash-chain design, and `lib/letflow/design/req196-audit-route.md` for
  this route's own design. Before REQ-196, this route read the tenant-scoped
  `events` table via `Letflow.EventStore.read_global/1`, because Letflow had
  no dedicated audit-entry table yet; REQ-195 built one and REQ-196 repointed
  this route onto it.

  Consequences for the response body, now the inverse of what this moduledoc
  used to say:

    * `resource_type` carries the real, per-row resource kind (e.g.
      `"definition"`, `"instance"`, `"task"`, `"user"`) — no longer the
      constant `"instance"` a caller could get from the old event-store-backed
      implementation.
    * `before_state` and `after_state` carry the real prior/resulting state
      REQ-195's capture mechanism recorded for the mutation, when the covered
      operation has one — no longer always `null`.
    * `pipeline_run_id` has no equivalent column on `Entry` at all (REQ-195's
      schema has no such concept — it was `event.metadata["pipeline_run_id"]`,
      an `events`-table-specific idea). The query parameter is still
      422-rejected if supplied non-empty (see the filter table below) — there
      is no writer to wait on this time, because there is no column to write
      to.
    * **`payload` is removed entirely.** It existed only because
      `before_state`/`after_state` were always `null` and the response
      otherwise carried no information about *what* changed — `after_state`
      now supplies that, more structurally, on every row. Confirmed safe
      against `web/src/api/audit.ts`'s `RawAuditEntry` (no `payload` field)
      and `web/src/pages/admin/AuditLogPage.tsx` (no reference to `.payload`)
      before removing it (design §4).

  ## Filter disposition — what has backing, and what does not

  PROVENANCE (historical, not current decision authority):
  R-Co's `ListAuditParams` (`audit.zig:10-19`) carries eight query params.
  None is silently dropped:

  | Param | Letflow | How |
  |---|---|---|
  | `cursor` | supported | opaque cursor over `(timestamp, id)` |
  | `page_size` | supported | `Letflow.Api.Pagination`, then `list_entries/1`'s `:page_size` |
  | `from` / `to` | supported | `list_entries/1`'s `:from`/`:to`, inclusive bounds on `audit_entries.timestamp` |
  | `actor_id` | supported | `list_entries/1`'s `:actor_id` |
  | `resource_id` | supported | `list_entries/1`'s `:resource_id` — the `audit_entries.resource_id` column directly |
  | `resource_type` | **supported — a real, index-backed equality filter** | `list_entries/1`'s `:resource_type`, `WHERE resource_type = $1` when present, unfiltered when absent — backed by REQ-195's index #3 (`resource_type, resource_id, timestamp DESC, id DESC`). Before REQ-196, `events` had exactly one resource type and this filter was a no-op (a truthful empty page for anything but `"instance"`, no query issued); against `audit_entries` it genuinely discriminates. |
  | `pipeline_run_id` | **not supported — 422 if supplied non-empty** | `audit_entries` has no such column at all (see above) — an explicit 422 is honest; a silent empty page is not. |

  PROVENANCE (historical, not current decision authority):
  `from > to` is checked **in this route**, before any query, returning 422 —
  a syntactic-validity check that belongs at the route boundary, not the
  store layer, so a bad range never even reaches a query (`audit.zig:26-30`).

  ## Two deliberate cursor divergences from R-Co, and one non-port

    PROVENANCE (historical, not current decision authority):
    * R-Co maps `InvalidCursor` -> **422** (`audit.zig:42`); **Letflow returns
      400.** Uniform cursor-error handling across the whole Letflow API beats
      per-endpoint R-Co fidelity: `lib/letflow/routers/tenants.ex:276`,
      `lib/letflow/routers/identity.ex:295` and `identity.ex:550` are all
      `Response.bad_request(conn, "invalid cursor")`, and `/audit` matches
      them.
    PROVENANCE (historical, not current decision authority):
    * R-Co maps `CursorExpired` -> **410** (`audit.zig:43`); **Letflow returns
      the same 400.** Expiry is already inside the
      `Letflow.Api.Pagination.decode_cursor/4` collapse, and `/audit` must not
      become the only Letflow endpoint that emits 410.
    PROVENANCE (historical, not current decision authority):
    * **503 `PoolExhausted`** (`audit.zig:45`) is a deliberate **non-port**,
      not an omission. Ecto/DBConnection surfaces pool exhaustion as a raised
      `DBConnection.ConnectionError`, not an `{:error, :pool_exhausted}`
      tuple, so there is no tuple to match and the clause would be a branch
      nothing can reach.

  `list_entries/1`'s own `has_more` is documented there as a heuristic, not a
  proof: if exactly `page_size` more rows exist and no others, `has_more`
  reports `true` and the very next page returns zero new rows. That ordinary
  cursor-pagination boundary case is inherited here unchanged.

  ## Authorization (REQ-131)

  `GET /audit` is declared via `authz_get "/", :AuditRead do ... end`
  (`Letflow.Api.AuthorizedRouter`) — `Letflow.Plugs.Authorize` evaluates
  `:AuditRead` before this module's handler ever runs. The route-local
  `with_authorization/4` copy that used to live here (a third copy of the
  helper also in `lib/letflow/routers/tenants.ex` and
  `lib/letflow/routers/identity.ex` before this requirement) is deleted, not
  adapted, per REQ-130's design §2.4.

  `Letflow.Api.Authorization.endpoint_policy_key("GET", "/audit")` already
  returns `:AuditRead`. Per `role_allows?/2`, `PLATFORM_ADMIN`, `TENANT_ADMIN`, `TENANT_AUDITOR` and
  `PROCESS_OPERATOR` hold it; `PROCESS_DESIGNER`, `TASK_WORKER` and
  `AGENT_RUNNER` do not — so such a caller gets **403**, never a 404 and never
  an empty 200.

  ## Ordering guarantee

  Honours the contract stated in `Letflow.Routers.Tenants`'s moduledoc section
  **"Ordering guarantee (design §6.1)"**: no `Repo` call of any kind —
  including a pre-fetch read — happens before the preamble has resolved the
  scoped prefix and before `evaluate_access/2` has returned a
  non-`:Deny403` decision. A denied caller reaches no query at all. Here this
  is additionally structural: **this module performs no `Repo` call**; the one
  read is inside `Letflow.Audit.list_entries/1`, which cannot be reached
  without the prefix, because the prefix is a required key of its `params`
  argument.

  ## INV-1 — the sharpest case in REQ-078

  The **only** tenant input is `Letflow.Api.Context.scoped_repo_opts/1`'s
  prefix, derived solely from `conn.assigns[:auth_context][:tenant_id]`. There
  is no query parameter, header, or body field through which another tenant's
  audit entries could be selected: every filter this route passes narrows the
  query further, never widens it, and `list_entries/1`'s `prefix` is always
  this route's own resolved value, never anything request-derived. An audit
  list that escaped scoping would disclose another tenant's **entire activity
  history in one response** — this is the sharpest INV-1 case in this
  requirement, and the reason the tenant is not merely filtered but physically
  unreachable.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Audit
  alias Letflow.Audit.Entry
  alias Letflow.Api.Pagination
  alias Letflow.Api.Response

  # A new endpoint prefix, distinct from "T:" (tenants) and "U:" (identity);
  # `decode_cursor/4`'s {:error, :wrong_endpoint} is what makes a cursor
  # minted by another endpoint fail here.
  @audit_cursor_prefix "A:"

  authz_get "/", :AuditRead do
    handle_list(conn)
  end

  authz_unmatched(:ordinary)

  # ── GET /audit (design §6) ────────────────────────────────────────────────

  defp handle_list(conn) do
    conn = fetch_query_params(conn)
    query = conn.query_params

    with :ok <- reject_pipeline_run_id(Map.get(query, "pipeline_run_id")),
         {:ok, raw_page_size} <- Pagination.parse_page_size_param(Map.get(query, "page_size")),
         {:ok, page_size} <- Pagination.validate_page_size(raw_page_size),
         {:ok, cursor_seek} <- parse_cursor_param(Map.get(query, "cursor")),
         {:ok, from} <- parse_timestamp_param(Map.get(query, "from")),
         {:ok, to} <- parse_timestamp_param(Map.get(query, "to")),
         :ok <- check_time_range(from, to),
         {:ok, scope} <- {:ok, conn.assigns.scoped_opts} do
      params = %{
        prefix: Keyword.fetch!(scope, :prefix),
        page_size: page_size,
        cursor: cursor_seek,
        actor_id: non_empty(Map.get(query, "actor_id")),
        resource_id: non_empty(Map.get(query, "resource_id")),
        resource_type: non_empty(Map.get(query, "resource_type")),
        from: from,
        to: to
      }

      render_page(conn, Audit.list_entries(params))
    else
      {:error, :invalid_page_size} ->
        Response.bad_request(conn, "invalid page_size")

      {:error, :page_size_too_large} ->
        Response.bad_request(conn, "page_size out of range")

      {:error, :invalid_cursor} ->
        Response.bad_request(conn, "invalid cursor")

      {:error, :invalid_time_range} ->
        Response.unprocessable(conn, "invalid time range")

      {:error, :invalid_filter} ->
        Response.unprocessable(conn, "invalid filter")
    end
  end

  defp render_page(conn, {:ok, %{items: items, has_more: has_more}}) do
    Response.ok(conn, page_body(items, next_cursor(items, has_more)))
  end

  # `Letflow.Audit.list_entries/1`'s only error return is `{:error,
  # :invalid_actor_id}` (its @spec) -- unlike the former
  # `EventStore.read_global/1`, there is no `:invalid_instance_id` (resource_id
  # is a plain :string column, no cast-error risk, design §1.2/§8 OQ-1) and no
  # other `{:error, _}` shape reaches this function, so there is no remaining
  # catch-all `render_page/2` clause (INV-4's "no Postgrex/internal detail
  # leaks to the body" concern doesn't arise here because no such shape exists
  # to leak).
  defp render_page(conn, {:error, :invalid_actor_id}) do
    Response.unprocessable(conn, "invalid filter")
  end

  # ── Parameter parsing ─────────────────────────────────────────────────────

  defp reject_pipeline_run_id(nil), do: :ok
  defp reject_pipeline_run_id(""), do: :ok
  defp reject_pipeline_run_id(_supplied), do: {:error, :invalid_filter}

  # Step 1 -- the COLLAPSE. Every decode_cursor/4 failure (:invalid_base64,
  # :wrong_endpoint, :expired, :invalid_cursor) folds into one route-level
  # error. Step 2 -- the STATUS -- is decided in handle_list/1's else block,
  # and it is 400, matching every other cursor call site in this codebase.
  defp parse_cursor_param(nil), do: {:ok, nil}
  defp parse_cursor_param(""), do: {:ok, nil}

  defp parse_cursor_param(raw) when is_binary(raw) do
    with {:ok, %Pagination.Cursor{inner: inner}} <-
           Pagination.decode_cursor(raw, @audit_cursor_prefix, byte_size(@audit_cursor_prefix)),
         {:ok, seek} <- cursor_seek_from_cursor(inner) do
      {:ok, seek}
    else
      _invalid_base64_or_wrong_endpoint_or_expired_or_invalid_cursor ->
        {:error, :invalid_cursor}
    end
  end

  # The raw payload is "A:<mint_time_us>:<entry_timestamp_us>:<entry_id>"
  # (REQ-196 -- was "A:<mint_time_us>:<global_seq>" before this requirement).
  # This is the ONLY place the cursor's internal layout is interpreted; no
  # other module in REQ-078/REQ-196 parses it.
  defp cursor_seek_from_cursor(inner) do
    case Pagination.decode_seek_parts(inner, @audit_cursor_prefix, [:skip, :datetime_us, :uuid]) do
      {:ok, [entry_ts, entry_id]} -> {:ok, {entry_ts, entry_id}}
      {:error, :invalid_cursor} = error -> error
    end
  end

  defp parse_timestamp_param(nil), do: {:ok, nil}
  defp parse_timestamp_param(""), do: {:ok, nil}

  defp parse_timestamp_param(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, datetime, _utc_offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, :invalid_time_range}
    end
  end

  defp check_time_range(nil, _to), do: :ok
  defp check_time_range(_from, nil), do: :ok

  defp check_time_range(from, to) do
    case DateTime.compare(from, to) do
      :gt -> {:error, :invalid_time_range}
      _lt_or_eq -> :ok
    end
  end

  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(value) when is_binary(value), do: value

  # ── Cursor minting ────────────────────────────────────────────────────────

  defp next_cursor([], _has_more), do: nil
  defp next_cursor(_items, false), do: nil

  defp next_cursor(items, true) do
    last = List.last(items)
    mint_time_us = System.system_time(:microsecond)
    entry_ts_us = DateTime.to_unix(last.timestamp, :microsecond)
    seek_key = "#{entry_ts_us}:#{last.id}"

    @audit_cursor_prefix
    |> Pagination.build_raw_cursor(mint_time_us, seek_key)
    |> Pagination.encode_cursor()
  end

  # ── Response allowlist (INV-2) ────────────────────────────────────────────

  defp page_body(entries, next_cursor) do
    items = Enum.map(entries, &audit_item/1)

    %{
      "items" => items,
      "next_cursor" => next_cursor,
      # PROVENANCE (historical, not current decision authority):
      # length(items), NOT a total -- matching audit.zig:54-77 and
      # web/src/api/audit.ts:36-40.
      "count" => length(items)
    }
  end

  # Hand-built, exactly eight keys, per design §2.1 -- never a Jason.Encoder
  # derivation over %Letflow.Audit.Entry{}, which would leak `tenant_id`,
  # `chain_hash`, `prev_chain_hash`, `trace_id` and the schema's own
  # `inserted_at` timestamp.
  @spec audit_item(Entry.t()) :: map()
  defp audit_item(%Entry{} = entry) do
    %{
      "audit_id" => entry.id,
      "actor_id" => entry.actor_id,
      "action" => entry.action,
      "resource_type" => entry.resource_type,
      "resource_id" => entry.resource_id,
      "timestamp" => iso8601(entry.timestamp),
      "before_state" => entry.before_state,
      "after_state" => entry.after_state
    }
  end

  # `Entry.timestamp` is :utc_datetime_usec, so this is the %DateTime{}
  # clause of the same iso8601/1 convention Letflow.Routers.Tenants
  # establishes for NaiveDateTime columns.
  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(nil), do: nil
end
