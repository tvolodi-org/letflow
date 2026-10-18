defmodule Letflow.Dlq do
  @moduledoc """
  Context module for the `dlq_entries` table's core lifecycle:
  `enqueue/2`, `list/2`, `get/2`, `retry/2`, `discard/2`. See
  `lib/letflow/design/req176-dlq-core.md` for the full design this module
  implements. Plain Ecto context module, no process — same shape as
  `Letflow.Tasks`/`Letflow.Identity`.

  **Scope boundary, restated from the design (§0):** this module covers only
  the schema/migration and these five functions. No route, no controller, no
  Plug module — that is REQ-178. No wiring from REQ-056/REQ-061's existing
  hooks — that is REQ-177. No webhook-origin entries — REQ-180. `retry/2`
  manages only the `dlq_entries` row's own state: it has no knowledge of,
  and never calls, whatever would actually re-dispatch a `SERVICE_TASK` or
  resume an ERRORed instance (design §4).

  ## Tenant scoping (INV-1)

  Every function below takes `opts :: [prefix: String.t()]`, `prefix` always
  supplied by the caller (the future REQ-178 route, via
  `Letflow.Api.Context.scoped_repo_opts/1`) — this module never itself
  decides tenant scope, matching every REQ-072+ context module's own
  precedent.

  `tenant_id` is never accepted from caller-supplied attrs (`enqueue/2`'s own
  `enqueue_attrs()` type has no `:tenant_id` key at all) — it is always
  derived from `opts[:prefix]` via
  `Letflow.TenantProvisioning.tenant_id_for_schema_name/1`, the same
  "derived, never accepted" discipline `Letflow.EventStore`/`Letflow.Engine`
  already establish for every tenant-scoped write in this codebase (design
  §5 OQ-1 — `Letflow.Api.Context.scoped_repo_opts/1` itself returns only
  `[prefix: schema_name]`, no `tenant_id` key, so this module re-derives it
  from the schema name it already has, rather than requiring a second `opts`
  key no caller can currently supply).
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Letflow.Api.Pagination
  alias Letflow.Dlq.Entry
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @typedoc "Threaded into every `Repo` call below — `:prefix` derived by the caller from `Letflow.Api.Context.scoped_repo_opts/1`, never from request data."
  @type opts :: [prefix: String.t()]

  @list_cursor_prefix "D:"

  # ===========================================================================
  # enqueue/2 (design §3.1)
  # ===========================================================================

  @type enqueue_attrs :: %{
          required(:entry_type) => String.t(),
          optional(:instance_id) => Ecto.UUID.t() | nil,
          optional(:reference_id) => String.t() | nil,
          optional(:reason) => String.t() | nil,
          optional(:full_reason) => String.t() | nil,
          optional(:error_detail) => map() | nil,
          optional(:error_chain) => [map()] | nil,
          optional(:source_payload) => map() | nil,
          optional(:context_json) => map() | nil,
          optional(:retry_limit) => pos_integer() | nil,
          optional(:first_failed_at) => DateTime.t() | nil,
          optional(:last_failed_at) => DateTime.t() | nil
        }

  @doc """
  Inserts a new `dlq_entries` row. Always sets `status: :pending`,
  `retry_count: 0`, `retry_history: []`, and `created_at` to the current UTC
  wall-clock time (second precision), read inside this function — none of
  the four is caller-settable through `enqueue_attrs()` (design §3.1). Every
  other field inserts as provided, `nil` where the caller omits an optional
  key.

  `tenant_id` is derived from `opts[:prefix]`, never accepted from `attrs`
  (see this module's moduledoc).
  """
  @spec enqueue(enqueue_attrs(), opts()) :: {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
  def enqueue(attrs, opts) when is_map(attrs) and is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      insert_attrs =
        attrs
        |> Map.take([
          :entry_type,
          :instance_id,
          :reference_id,
          :reason,
          :full_reason,
          :error_detail,
          :error_chain,
          :source_payload,
          :context_json,
          :retry_limit,
          :first_failed_at,
          :last_failed_at
        ])
        |> Map.merge(%{
          tenant_id: tenant_id,
          status: :pending,
          retry_count: 0,
          retry_history: [],
          created_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      %Entry{}
      |> Entry.insert_changeset(insert_attrs)
      |> Repo.insert(prefix: prefix)
    end
  end

  # ===========================================================================
  # count_entries/1 (REQ-201 OQ-2 — read-only aggregate for alert threshold)
  # ===========================================================================

  @doc """
  Returns the total count of all `dlq_entries` rows in the given tenant
  schema. Used by `Letflow.Obs.Alerts` to measure DLQ depth for the
  `dlq_depth_threshold` alert trigger. No status/type filter — the alert
  fires on total depth, regardless of status.
  """
  @spec count_entries(opts()) :: non_neg_integer()
  def count_entries(opts) when is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    Repo.aggregate(Entry, :count, prefix: prefix)
  end

  # ===========================================================================
  # list/2 (design §3.2)
  # ===========================================================================

  @type list_params :: %{
          optional(:status) => String.t() | nil,
          optional(:entry_type) => String.t() | nil,
          optional(:search) => String.t() | nil,
          optional(:instance_id) => Ecto.UUID.t() | nil,
          cursor: String.t() | nil,
          page_size: pos_integer()
        }

  @doc """
  Cursor-paginated listing of `dlq_entries`, ordered `(created_at DESC, id
  DESC)`. Mirrors `Letflow.Tasks.list_tasks/2`'s own keyset idiom exactly
  (design §3.2): cursor prefix `"D:"`, `page_size + 1` fetch with the extra
  row dropped, `next_cursor` built from the last row kept (or `nil` when the
  page is not full).

  `status`/`entry_type`/`instance_id`/`search` are independent filters, each
  a no-op when its param is `nil` — any combination narrows the result set
  without interacting.
  """
  @spec list(list_params(), opts()) ::
          {:ok, %{items: [Entry.t()], next_cursor: String.t() | nil}}
          | {:error, :invalid_cursor | :wrong_endpoint | :expired | :invalid_filter}
  def list(params, opts) when is_map(params) and is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    page_size = Map.fetch!(params, :page_size)

    with {:ok, status} <- cast_status_filter(Map.get(params, :status)),
         {:ok, instance_id} <- cast_instance_id_filter(Map.get(params, :instance_id)),
         {:ok, cursor_seek} <- decode_list_cursor(Map.get(params, :cursor)) do
      query =
        Entry
        |> filter_by_status(status)
        |> filter_by_entry_type(Map.get(params, :entry_type))
        |> filter_by_instance_id(instance_id)
        |> filter_by_search(Map.get(params, :search))
        |> filter_by_list_cursor(cursor_seek)
        |> order_by([d], desc: d.created_at, desc: d.id)
        |> limit(^(page_size + 1))

      rows = Repo.all(query, prefix: prefix)
      {page, next_cursor} = split_list_page(rows, page_size)

      {:ok, %{items: page, next_cursor: next_cursor}}
    end
  end

  # ===========================================================================
  # get/2 (design §3.3)
  # ===========================================================================

  @doc """
  Fetches a single `dlq_entries` row by id, scoped to `opts[:prefix]`.
  `Ecto.UUID.cast/1` is checked first — an invalid UUID never reaches the DB
  (`{:error, :invalid_id}`, no round-trip). A genuinely nonexistent id and a
  real id belonging to a different tenant's own schema both resolve through
  the same `{:error, :not_found}` branch, the identical structural
  cross-tenant-404-by-construction mechanism REQ-072 established.
  """
  @spec get(id :: String.t(), opts()) :: {:ok, Entry.t()} | {:error, :invalid_id | :not_found}
  def get(id, opts) when is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    case Ecto.UUID.cast(id) do
      :error ->
        {:error, :invalid_id}

      {:ok, id} ->
        case Repo.get(Entry, id, prefix: prefix) do
          nil -> {:error, :not_found}
          %Entry{} = entry -> {:ok, entry}
        end
    end
  end

  # ===========================================================================
  # retry/2 (design §3.4)
  # ===========================================================================

  @doc """
  State machine (exhaustive over `DlqStatus`'s four values, design §3.4):

    * `:pending`/`:retrying` — transitions to `:retrying`; appends one
      `DlqRetryAttempt`-shaped map to `retry_history`; increments
      `retry_count` by 1.
    * `:resolved`/`:discarded` — conflict, `{:error, {:invalid_state,
      current_status}}`; the row is read but not written — `status`,
      `retry_count`, and `retry_history` all remain byte-for-byte unchanged.

  Row-locked via `SELECT ... FOR UPDATE` (`Ecto.Query.lock/3`) then an
  in-Elixir status check then a conditional update, inside one
  `Ecto.Multi`/`Repo.transaction/1` — the same lock-then-check idiom
  `Letflow.Tasks.claim_task/3`/`assign_task/4`/`reassign_task/4` already
  establish. Lock scope: this row only, filtered by its own `id`.
  """
  @spec retry(id :: String.t(), opts()) ::
          {:ok, Entry.t()}
          | {:error, :invalid_id}
          | {:error, :not_found}
          | {:error, {:invalid_state, current_status :: :resolved | :discarded}}
  def retry(id, opts) when is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, id} <- cast_entry_id(id) do
      Multi.new()
      |> Multi.run(:entry, fn repo, _changes -> fetch_and_lock_entry(repo, id, prefix) end)
      |> Multi.run(:apply, fn _repo, %{entry: entry} -> apply_retry(entry, prefix) end)
      |> Repo.transaction()
      |> unwrap_write_result()
    end
  end

  defp apply_retry(%Entry{status: status} = entry, prefix) when status in [:pending, :retrying] do
    attempt_no = entry.retry_count + 1

    attempt = %{
      attempt_no: attempt_no,
      attempted_at: DateTime.to_iso8601(DateTime.utc_now()),
      outcome: "failed",
      error_message: nil
    }

    entry
    |> Entry.retry_changeset(%{
      status: :retrying,
      retry_count: attempt_no,
      retry_history: entry.retry_history ++ [attempt]
    })
    |> Repo.update(prefix: prefix)
  end

  defp apply_retry(%Entry{status: status}, _prefix) do
    {:error, {:invalid_state, status}}
  end

  # ===========================================================================
  # discard/2 (design §3.5)
  # ===========================================================================

  @doc """
  State machine (design §3.5):

    * `:pending`/`:retrying` — transitions to `:discarded` (terminal).
    * `:resolved`/`:discarded` — conflict, `{:error, {:invalid_state,
      current_status}}`; unchanged — calling `discard/2` twice never
      silently succeeds a second time.

  Same lock-then-check-then-write mechanics as `retry/2`. Does not touch
  `retry_history`, `retry_count`, or any `*_failed_at` column — only
  `status` changes.
  """
  @spec discard(id :: String.t(), opts()) ::
          {:ok, Entry.t()}
          | {:error, :invalid_id}
          | {:error, :not_found}
          | {:error, {:invalid_state, current_status :: :resolved | :discarded}}
  def discard(id, opts) when is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, id} <- cast_entry_id(id) do
      Multi.new()
      |> Multi.run(:entry, fn repo, _changes -> fetch_and_lock_entry(repo, id, prefix) end)
      |> Multi.run(:apply, fn _repo, %{entry: entry} -> apply_discard(entry, prefix) end)
      |> Repo.transaction()
      |> unwrap_write_result()
    end
  end

  defp apply_discard(%Entry{status: status} = entry, prefix)
       when status in [:pending, :retrying] do
    entry
    |> Entry.discard_changeset(%{status: :discarded})
    |> Repo.update(prefix: prefix)
  end

  defp apply_discard(%Entry{status: status}, _prefix) do
    {:error, {:invalid_state, status}}
  end

  # ── retry/2, discard/2 shared helpers ───────────────────────────────────

  defp fetch_and_lock_entry(repo, id, prefix) do
    Entry
    |> where([d], d.id == ^id)
    |> lock("FOR UPDATE")
    |> repo.one(prefix: prefix)
    |> case do
      nil -> {:error, :not_found}
      %Entry{} = entry -> {:ok, entry}
    end
  end

  defp cast_entry_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_id}
    end
  end

  defp unwrap_write_result({:ok, %{apply: entry}}), do: {:ok, entry}
  defp unwrap_write_result({:error, _failed_step, reason, _changes}), do: {:error, reason}

  # ── list/2 private helpers ──────────────────────────────────────────────

  defp cast_status_filter(nil), do: {:ok, nil}

  defp cast_status_filter(status) when is_binary(status) do
    case Ecto.Enum.cast_value(Entry, :status, status) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, :invalid_filter}
    end
  end

  defp cast_instance_id_filter(nil), do: {:ok, nil}

  defp cast_instance_id_filter(instance_id) when is_binary(instance_id) do
    case Ecto.UUID.cast(instance_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_filter}
    end
  end

  defp filter_by_status(query, nil), do: query
  defp filter_by_status(query, status), do: from(d in query, where: d.status == ^status)

  defp filter_by_entry_type(query, nil), do: query
  defp filter_by_entry_type(query, ""), do: query

  defp filter_by_entry_type(query, entry_type) do
    from(d in query, where: d.entry_type == ^entry_type)
  end

  defp filter_by_instance_id(query, nil), do: query

  defp filter_by_instance_id(query, instance_id) do
    from(d in query, where: d.instance_id == ^instance_id)
  end

  # Free-text search across `reason` plus `instance_id`/`id` cast to text for
  # ILIKE (design §3.2 — a new pattern this design introduces, no existing
  # precedent for a UUID-column-cast-to-text-for-ILIKE idiom anywhere else in
  # this codebase). Wrapping idiom (`"%...%"`) matches `Letflow.Identity`'s
  # own `filter_by_search/2`/`filter_tenants_by_search/2`.
  defp filter_by_search(query, nil), do: query
  defp filter_by_search(query, ""), do: query

  defp filter_by_search(query, search) do
    like = "%#{search}%"

    from(d in query,
      where:
        ilike(d.reason, ^like) or
          fragment("? ILIKE ?", type(d.instance_id, :string), ^like) or
          fragment("? ILIKE ?", type(d.id, :string), ^like)
    )
  end

  defp filter_by_list_cursor(query, nil), do: query

  defp filter_by_list_cursor(query, {ts, id}) do
    from(d in query, where: {d.created_at, d.id} < {^ts, ^id})
  end

  @spec decode_list_cursor(String.t() | nil) ::
          {:ok, {DateTime.t(), Ecto.UUID.t()} | nil}
          | {:error, :invalid_cursor | :wrong_endpoint | :expired}
  defp decode_list_cursor(nil), do: {:ok, nil}

  defp decode_list_cursor(raw) when is_binary(raw) do
    case Pagination.decode_cursor(raw, @list_cursor_prefix, byte_size(@list_cursor_prefix)) do
      {:ok, %Pagination.Cursor{} = cursor} -> decode_seek(cursor)
      {:error, :wrong_endpoint} -> {:error, :wrong_endpoint}
      {:error, :expired} -> {:error, :expired}
      {:error, _invalid_base64_or_invalid_cursor} -> {:error, :invalid_cursor}
    end
  end

  defp decode_seek(%Pagination.Cursor{inner: inner}) do
    case Pagination.decode_seek_parts(inner, @list_cursor_prefix, [:datetime_us, :uuid]) do
      {:ok, [created_at, id]} -> {:ok, {created_at, id}}
      {:error, :invalid_cursor} = error -> error
    end
  end

  defp split_list_page(rows, page_size) when length(rows) > page_size do
    {page, [_extra_row]} = Enum.split(rows, page_size)
    {page, build_list_next_cursor(List.last(page))}
  end

  defp split_list_page(rows, _page_size), do: {rows, nil}

  defp build_list_next_cursor(%Entry{id: id, created_at: created_at}) do
    created_at_us = DateTime.to_unix(created_at, :microsecond)

    @list_cursor_prefix
    |> Pagination.build_raw_cursor(created_at_us, id)
    |> Pagination.encode_cursor()
  end
end
