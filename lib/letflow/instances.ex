defmodule Letflow.Instances do
  @moduledoc """
  Context module for the instance read surface. REQ-080
  (`lib/letflow/design/req080-instance-routes-read.md`) builds this backing
  `GET /instances`, `GET /instances/:id`, `GET /instances/:id/history`,
  `GET /instances/:id/timeline` (`GET /instances/:id/pins` delegates
  directly to `Letflow.Engine.PinResolver.reconstruct_effective_pins/2` from
  the router, no wrapper here — see the design doc).

  Mirrors `Letflow.Tasks`'s established shape (`get_task/2`, `list_tasks/2`)
  — the cursor-pagination idiom below (`Letflow.Api.Pagination`, keyset
  cursors, `split_*_page/2`) is reused verbatim from that module, not
  reinvented.

  Every function takes `prefix` via `opts` and every `Repo` call passes it
  explicitly (INV-1) — no query in this module omits it.
  """

  import Ecto.Query

  alias Letflow.Api.Pagination
  alias Letflow.Engine.VariableMerge
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Identity.User
  alias Letflow.Repo

  @type opts :: [prefix: String.t()]

  # PROVENANCE (historical, not current decision authority):
  # `InstanceProjection.status`'s Ecto.Enum values, as the four uppercase
  # strings the HTTP layer accepts -- source of truth is that schema
  # (instance_projection.ex:125-128), not hand-duplicated as a separate
  # list needing its own upkeep.
  # The R-Co source (`instances.zig`) has a 5th value, RESTORED_ORPHAN -- an
  # already-closed, earlier-shipped 4-vs-5 divergence (design doc's own
  # "Open question resolved" section), not this module's to widen.
  @valid_statuses ~w(ACTIVE COMPLETED CANCELLED ERROR)

  @list_cursor_prefix "IL:"
  @history_cursor_prefix "IH:"
  @timeline_cursor_prefix "IT:"

  # ── get_by_id/2 ──────────────────────────────────────────────────────────

  @doc """
  Fetches a single instance's `InstanceProjection` row by id. An invalid
  UUID never reaches the DB (`{:error, :invalid_id}`, no round-trip); a
  cross-tenant id and a genuinely nonexistent id resolve through this same
  single code path to `{:error, :not_found}` -- no branch could tell them
  apart (INV-5), matching `Letflow.Tasks.get_task/2`'s established
  convention.
  """
  @spec get_by_id(id :: String.t(), opts()) ::
          {:ok, InstanceProjection.t()} | {:error, :not_found | :invalid_id}
  def get_by_id(id, opts) when is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    case Ecto.UUID.cast(id) do
      :error ->
        {:error, :invalid_id}

      {:ok, id} ->
        case Repo.get(InstanceProjection, id, prefix: prefix) do
          nil -> {:error, :not_found}
          %InstanceProjection{} = projection -> {:ok, projection}
        end
    end
  end

  # ── list/2 ───────────────────────────────────────────────────────────────

  @doc """
  Returns `{:error, :invalid_status}` for a `status` filter value outside
  `#{inspect(@valid_statuses)}` -- validated before any query runs, never
  passed through to an `Ecto.Enum` cast failure.

  Filters: `status`, `definition_id`, `correlation_key`, `started_after`/
  `started_before` (a Letflow addition beyond the original filter set of
  `status`/`definition_id` -- see the design doc). Sorted
  `started_at` DESC, `instance_id` DESC (keyset pagination), same shape as
  `Letflow.Tasks.list_tasks/2`'s `(inserted_at, id)` cursor key.
  """
  @spec list(params :: map(), opts()) ::
          {:ok, %{items: [InstanceProjection.t()], next_cursor: String.t() | nil}}
          | {:error, :invalid_status | :invalid_cursor | :wrong_endpoint | :expired}
  def list(params, opts) when is_map(params) and is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    page_size = Map.fetch!(params, :page_size)

    with :ok <- validate_status_filter(Map.get(params, :status)),
         {:ok, cursor_seek} <- decode_list_cursor(Map.get(params, :cursor)) do
      query =
        InstanceProjection
        |> filter_by_status(Map.get(params, :status))
        |> filter_by_definition_id(Map.get(params, :definition_id))
        |> filter_by_correlation_key(Map.get(params, :correlation_key))
        |> filter_by_started_after(Map.get(params, :started_after))
        |> filter_by_started_before(Map.get(params, :started_before))
        |> filter_by_list_cursor(cursor_seek)
        |> order_by([p], desc: p.started_at, desc: p.instance_id)
        |> limit(^(page_size + 1))

      rows = Repo.all(query, prefix: prefix)
      {page, next_cursor} = split_list_page(rows, page_size)

      {:ok, %{items: page, next_cursor: next_cursor}}
    end
  end

  defp validate_status_filter(nil), do: :ok
  defp validate_status_filter(status) when status in @valid_statuses, do: :ok
  defp validate_status_filter(_invalid), do: {:error, :invalid_status}

  # ── history/2 ────────────────────────────────────────────────────────────

  @doc """
  Cursor-paginated raw event log for one instance, ascending
  `sequence_number` (append order). Existence-checked first
  (`instance_exists?/2`) so a cross-tenant/nonexistent `instance_id` 404s
  before any `events` query runs -- same INV-5 shape as `get_by_id/2`.

  Filters: `event_type`, `from`/`to` (on `created_at`). No
  `pipeline_run_id` filter -- see the design doc's "Deliberate non-port"
  note (no ADP-06 concept exists in Letflow).
  """
  @spec history(instance_id :: String.t(), params :: map(), opts()) ::
          {:ok, %{items: [Event.t()], next_cursor: String.t() | nil}}
          | {:error, :not_found | :invalid_id | :invalid_cursor | :wrong_endpoint | :expired}
  def history(instance_id, params, opts) when is_map(params) and is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    page_size = Map.fetch!(params, :page_size)

    with {:ok, id} <- cast_instance_id(instance_id),
         :ok <- ensure_instance_exists(id, prefix),
         {:ok, cursor_seek} <-
           decode_seq_cursor(Map.get(params, :cursor), @history_cursor_prefix) do
      query =
        Event
        |> where([e], e.instance_id == ^id)
        |> exclude_hidden_event_types()
        |> filter_by_event_type(Map.get(params, :event_type))
        |> filter_by_created_after(Map.get(params, :from))
        |> filter_by_created_before(Map.get(params, :to))
        |> filter_by_seq_cursor(cursor_seek)
        |> order_by([e], asc: e.sequence_number)
        |> limit(^(page_size + 1))

      rows = Repo.all(query, prefix: prefix)
      {page, next_cursor} = split_seq_page(rows, page_size, @history_cursor_prefix)

      {:ok, %{items: page, next_cursor: next_cursor}}
    end
  end

  @doc """
  Batched `actor_id => display_name` lookup for the events on a history page
  (one query for all distinct non-nil `actor_id`s, never one per event). An
  actor with no resolvable non-blank display name is absent from the map.
  """
  @spec actor_display_names([Event.t()], opts()) :: %{Ecto.UUID.t() => String.t()}
  def actor_display_names(events, opts) when is_list(events) and is_list(opts) do
    events
    |> Enum.map(& &1.actor_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> fetch_display_names_by_actor_id(Keyword.fetch!(opts, :prefix))
  end

  # ── timeline/2 ───────────────────────────────────────────────────────────

  @doc """
  Same underlying query/pagination as `history/2`, response projection per
  `lib/letflow/design/req200-instance-timeline-rendering.md`: `event_type`,
  `sequence_num` (renamed from `sequence_number`), `timestamp` (renamed from
  `created_at`), `event_id`, `instance_id`, `metadata`, `node_id`/`task_id`
  extracted from `payload` where present, plus `actor_display_name` (§2's
  total 4-level fallback) and `description` (§3's per-event-type renderer).
  The distinct non-nil `actor_id`s on the page are resolved in one batched
  query (§4) -- never one lookup per event.
  """
  @spec timeline(instance_id :: String.t(), params :: map(), opts()) ::
          {:ok, %{items: [map()], next_cursor: String.t() | nil}}
          | {:error, :not_found | :invalid_id | :invalid_cursor | :wrong_endpoint | :expired}
  def timeline(instance_id, params, opts) when is_map(params) and is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    page_size = Map.fetch!(params, :page_size)

    with {:ok, id} <- cast_instance_id(instance_id),
         :ok <- ensure_instance_exists(id, prefix),
         {:ok, cursor_seek} <-
           decode_seq_cursor(Map.get(params, :cursor), @timeline_cursor_prefix) do
      query =
        Event
        |> where([e], e.instance_id == ^id)
        |> exclude_hidden_event_types()
        |> filter_by_seq_cursor(cursor_seek)
        |> order_by([e], asc: e.sequence_number)
        |> limit(^(page_size + 1))

      rows = Repo.all(query, prefix: prefix)
      {page, next_cursor} = split_seq_page(rows, page_size, @timeline_cursor_prefix)

      distinct_actor_ids =
        page
        |> Enum.map(& &1.actor_id)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      display_names_by_id = fetch_display_names_by_actor_id(distinct_actor_ids, prefix)

      items = Enum.map(page, &timeline_item(&1, display_names_by_id))

      {:ok, %{items: items, next_cursor: next_cursor}}
    end
  end

  # ── timeline/3 private: actor display-name batch lookup (design §4) ──────

  # N+1 avoidance: one bounded query per page (zero if no event on the page
  # carries a non-nil actor_id), never one lookup per event.
  @spec fetch_display_names_by_actor_id(actor_ids :: [Ecto.UUID.t()], prefix :: String.t()) ::
          %{optional(Ecto.UUID.t()) => String.t()}
  defp fetch_display_names_by_actor_id([], _prefix), do: %{}

  defp fetch_display_names_by_actor_id(actor_ids, prefix) do
    query =
      from(u in User,
        where: u.id in ^actor_ids,
        select: {u.id, u.display_name}
      )

    query
    |> Repo.all(prefix: prefix)
    |> Enum.reduce(%{}, fn {id, display_name}, acc ->
      if blank?(display_name), do: acc, else: Map.put(acc, id, display_name)
    end)
  end

  # ── timeline/3 private: actor display-name resolution (design §2) ────────

  # Total function: every input combination returns a non-nil, non-blank
  # String.t(). `display_names_by_id` holds only ids that resolved to a
  # non-blank display_name (see `fetch_display_names_by_actor_id/2`), so an
  # `actor_id` absent from the map -- whether it was never looked up (nil)
  # or looked up and not found (deleted user, platform sentinel) -- falls
  # through uniformly to the metadata-based fallbacks, then to "system".
  @spec resolve_actor_display_name(
          actor_id :: Ecto.UUID.t() | nil,
          metadata :: map(),
          display_names_by_id :: %{optional(Ecto.UUID.t()) => String.t()}
        ) :: String.t()
  defp resolve_actor_display_name(actor_id, metadata, display_names_by_id) do
    cond do
      actor_id != nil and Map.has_key?(display_names_by_id, actor_id) ->
        Map.fetch!(display_names_by_id, actor_id)

      not blank?(Map.get(metadata, "token_description")) ->
        Map.get(metadata, "token_description")

      not blank?(Map.get(metadata, "actor_label")) ->
        Map.get(metadata, "actor_label")

      true ->
        "system"
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_non_binary), do: true

  # ── timeline/3 private: per-event-type description rendering (design §3) ─

  # One clause per real event type this codebase can append (design §1),
  # plus a mandatory trailing fallback clause for any other event_type
  # string -- lua/platform.ex's emit_event hook lets a tenant script append
  # an arbitrary event_type with no whitelist, so this must never raise on
  # an unrecognised value (AC5).
  @spec render_description(event :: Event.t(), actor_display_name :: String.t(), payload :: map()) ::
          String.t()
  defp render_description(%Event{event_type: "INSTANCE_STARTED"}, actor, _payload) do
    "Instance started by #{actor}"
  end

  defp render_description(%Event{event_type: "TASK_COMPLETED"}, actor, payload) do
    node_id = Map.get(payload, "node_id")
    "Task #{node_id} completed by #{actor}"
  end

  defp render_description(%Event{event_type: "INSTANCE_CANCELLED"}, actor, _payload) do
    "Instance cancelled by #{actor}"
  end

  defp render_description(%Event{event_type: "INSTANCE_PINS_REBOUND"}, actor, _payload) do
    "Instance pins rebound by #{actor}"
  end

  defp render_description(%Event{event_type: "SUB_PROCESS_COMPLETED"}, actor, payload) do
    child_instance_id = Map.get(payload, "child_instance_id")
    "Sub-process #{child_instance_id} completed by #{actor}"
  end

  defp render_description(%Event{event_type: "EXECUTION_ERROR"}, actor, payload) do
    error_type = Map.get(payload, "error_type") || "unknown"
    "Execution error (#{error_type}) reported by #{actor}"
  end

  defp render_description(%Event{event_type: "ATTACHMENT_ATTACHED"}, actor, payload) do
    file_name = Map.get(payload, "file_name")
    "#{file_name} attached by #{actor}"
  end

  defp render_description(%Event{event_type: "ATTACHMENT_REMOVED"}, actor, payload) do
    file_name = Map.get(payload, "file_name")
    "#{file_name} removed by #{actor}"
  end

  defp render_description(%Event{event_type: "TIMER_FIRED"}, _actor, payload) do
    # Deliberately does not name the actor -- it is always the platform
    # sentinel (design §1), so appending "by system" on every row would add
    # no information. `actor_display_name` is still populated in the item.
    timer_id = Map.get(payload, "timer_id")
    "Timer #{timer_id} fired"
  end

  defp render_description(%Event{event_type: event_type}, actor, _payload) do
    "Event #{event_type} by #{actor}"
  end

  # ── timeline/3 private: response-item assembly (design §5) ───────────────

  @spec timeline_item(
          event :: Event.t(),
          display_names_by_id :: %{optional(Ecto.UUID.t()) => String.t()}
        ) :: map()
  defp timeline_item(%Event{} = event, display_names_by_id) do
    actor_display_name =
      resolve_actor_display_name(event.actor_id, event.metadata, display_names_by_id)

    %{
      event_id: event.event_id,
      event_type: event.event_type,
      sequence_num: event.sequence_number,
      instance_id: event.instance_id,
      timestamp: event.created_at,
      node_id: Map.get(event.payload, "node_id"),
      task_id: Map.get(event.payload, "task_id"),
      metadata: event.metadata,
      actor_display_name: actor_display_name,
      description: render_description(event, actor_display_name, event.payload)
    }
  end

  # ── shared: existence check (INV-5) ────────────────────────────────────

  defp ensure_instance_exists(id, prefix) do
    query = from(p in InstanceProjection, where: p.instance_id == ^id, select: 1)

    if Repo.exists?(query, prefix: prefix) do
      :ok
    else
      {:error, :not_found}
    end
  end

  defp cast_instance_id(raw_id) do
    case Ecto.UUID.cast(raw_id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_id}
    end
  end

  # ── list/2 private filter helpers (INV-7: Ecto.Query composition only) ───

  defp filter_by_status(query, nil), do: query

  defp filter_by_status(query, status),
    do: from(p in query, where: p.status == ^normalize_status(status))

  defp normalize_status(status), do: status |> String.downcase() |> String.to_existing_atom()

  defp filter_by_definition_id(query, nil), do: query

  defp filter_by_definition_id(query, definition_id) do
    from(p in query, where: p.definition_id == ^definition_id)
  end

  defp filter_by_correlation_key(query, nil), do: query

  defp filter_by_correlation_key(query, correlation_key) do
    from(p in query, where: p.correlation_key == ^correlation_key)
  end

  defp filter_by_started_after(query, nil), do: query

  defp filter_by_started_after(query, %DateTime{} = ts) do
    from(p in query, where: p.started_at >= ^ts)
  end

  defp filter_by_started_before(query, nil), do: query

  defp filter_by_started_before(query, %DateTime{} = ts) do
    from(p in query, where: p.started_at <= ^ts)
  end

  defp filter_by_list_cursor(query, nil), do: query

  defp filter_by_list_cursor(query, {started_at_us, instance_id}) do
    ts = DateTime.from_unix!(started_at_us, :microsecond)
    from(p in query, where: {p.started_at, p.instance_id} < {^ts, ^instance_id})
  end

  defp decode_list_cursor(nil), do: {:ok, nil}

  defp decode_list_cursor(raw) when is_binary(raw) do
    case Pagination.decode_cursor(raw, @list_cursor_prefix, byte_size(@list_cursor_prefix)) do
      {:ok, %Pagination.Cursor{} = cursor} -> {:ok, decode_list_seek(cursor)}
      {:error, :wrong_endpoint} -> {:error, :wrong_endpoint}
      {:error, :expired} -> {:error, :expired}
      {:error, _invalid_base64_or_invalid_cursor} -> {:error, :invalid_cursor}
    end
  end

  defp decode_list_seek(%Pagination.Cursor{inner: inner}) do
    prefix_len = byte_size(@list_cursor_prefix)
    rest = binary_part(inner, prefix_len, byte_size(inner) - prefix_len)
    [ts_str, id_str] = String.split(rest, ":", parts: 2)
    {String.to_integer(ts_str), id_str}
  end

  defp split_list_page(rows, page_size) when length(rows) > page_size do
    {page, [_extra_row]} = Enum.split(rows, page_size)
    {page, build_list_next_cursor(List.last(page))}
  end

  defp split_list_page(rows, _page_size), do: {rows, nil}

  defp build_list_next_cursor(%InstanceProjection{instance_id: id, started_at: started_at}) do
    started_at_us = DateTime.to_unix(started_at, :microsecond)

    @list_cursor_prefix
    |> Pagination.build_raw_cursor(started_at_us, id)
    |> Pagination.encode_cursor()
  end

  # ── history/timeline shared: event-log filters + sequence-number cursor ──

  # GH #2587 PR B3 (CO-1, INV-2): engine-only bookkeeping events never appear in the client
  # history or timeline. Excluded in the query (not after the page is cut), so `page_size`
  # and the sequence cursor stay exact; the stored event is untouched.
  defp exclude_hidden_event_types(query) do
    hidden = [VariableMerge.sys_event_type()]
    from(e in query, where: e.event_type not in ^hidden)
  end

  defp filter_by_event_type(query, nil), do: query

  defp filter_by_event_type(query, event_type),
    do: from(e in query, where: e.event_type == ^event_type)

  defp filter_by_created_after(query, nil), do: query

  defp filter_by_created_after(query, %DateTime{} = ts) do
    from(e in query, where: e.created_at >= ^ts)
  end

  defp filter_by_created_before(query, nil), do: query

  defp filter_by_created_before(query, %DateTime{} = ts) do
    from(e in query, where: e.created_at <= ^ts)
  end

  defp filter_by_seq_cursor(query, nil), do: query

  defp filter_by_seq_cursor(query, seq) do
    from(e in query, where: e.sequence_number > ^seq)
  end

  # `sequence_number` is unique per instance (REQ-025) -- a single-value
  # seek, no tie-break needed, unlike list/2's compound
  # (started_at, instance_id) key.
  defp decode_seq_cursor(nil, _prefix), do: {:ok, nil}

  defp decode_seq_cursor(raw, prefix) when is_binary(raw) do
    case Pagination.decode_cursor(raw, prefix, byte_size(prefix)) do
      {:ok, %Pagination.Cursor{} = cursor} -> {:ok, decode_seq_seek(cursor, prefix)}
      {:error, :wrong_endpoint} -> {:error, :wrong_endpoint}
      {:error, :expired} -> {:error, :expired}
      {:error, _invalid_base64_or_invalid_cursor} -> {:error, :invalid_cursor}
    end
  end

  # `inner` is `"<prefix><now_us>:<seq>"` -- the segment BEFORE the colon is
  # the real wall-clock timestamp `decode_cursor/4` already validated for
  # expiry; the seek key (`seq`) is everything AFTER it.
  defp decode_seq_seek(%Pagination.Cursor{inner: inner}, prefix) do
    prefix_len = byte_size(prefix)
    rest = binary_part(inner, prefix_len, byte_size(inner) - prefix_len)
    colon_pos = elem(:binary.match(rest, ":"), 0)
    seq_str = binary_part(rest, colon_pos + 1, byte_size(rest) - colon_pos - 1)
    String.to_integer(seq_str)
  end

  defp split_seq_page(rows, page_size, cursor_prefix) when length(rows) > page_size do
    {page, [_extra_row]} = Enum.split(rows, page_size)
    {page, build_seq_next_cursor(List.last(page), cursor_prefix)}
  end

  defp split_seq_page(rows, _page_size, _cursor_prefix), do: {rows, nil}

  defp build_seq_next_cursor(%Event{sequence_number: seq}, cursor_prefix) do
    now_us = System.system_time(:microsecond)

    cursor_prefix
    |> Pagination.build_raw_cursor(now_us, Integer.to_string(seq))
    |> Pagination.encode_cursor()
  end
end
