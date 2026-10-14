defmodule Letflow.Idempotency do
  @moduledoc """
  The one reader and shaper of caller-supplied idempotency keys (GH #2550,
  design `lib/letflow/design/gh2550-client-idempotency-key-namespace.md`).

  Every event append claims its key in the tenant's `event_idempotency` table,
  whose unique index has no origin column. Server writers key their appends
  with fixed families (`server_prefixes/0`), so a caller who could store a raw
  key could pre-claim (squat) a server key and make the server writer skip its
  work. Every caller key is therefore stored namespaced, by route, actor and,
  for cancel/rebind, instance:

    * `client:rec:<actor>:<K>` -- entity record create/update (body)
    * `client:inst_start:<actor>:<K>` -- instance start (header)
    * `client:inst_cancel:<actor>:<instance_id>:<K>` -- cancel (header)
    * `client:inst_rebind:<actor>:<instance_id>:<K>` -- pin rebind (header)
    * `script:<actor>:<K>` -- Lua `platform.emit_event/3`

  A raw key over `raw_max/1` bytes is refused (a stable 422, or
  `invalid_arguments` for a script), never truncated, so a stored key always
  fits `varchar(255)`. An absent key (or an empty header) gives a bare
  server-minted UUID, which no caller ever sees.

  Routers must not read the caller's key themselves; a source scan in
  `test/letflow/idempotency_test.exs` enforces that.

  ## One-release legacy lookup (entity records only)

  Keys written before this change were stored bare. For one release,
  `legacy_original/3` lets a same-actor replay of such a key on the record
  routes still be a duplicate, under guards: the key matches no server or
  caller family (checked without I/O in `from_body/3`), the row was written
  before `legacy_cutoff/0`, by the same actor, as an entity-record create or
  update. Removal is tracked by GH #2578.
  """

  alias Letflow.Api.Validation.FieldError
  alias Letflow.Entities.Records
  alias Letflow.EventStore
  alias Letflow.EventStore.Event

  @type route :: :rec | :inst_start | :inst_cancel | :inst_rebind

  @type resolved :: %{key: String.t(), legacy_raw: String.t() | nil}

  @body_field "idempotency_key"
  @header "idempotency-key"

  @caller_prefixes ["client:", "script:"]

  # Design §1b, verbatim. Derived `<base>::sub_process_*::<uuid>` keys keep the
  # base first, so they take the base's family and are not listed separately.
  @server_prefixes [
    "timer_fired:",
    "escalation_timer_fired:",
    "service_task_dispatch:",
    "service_task:",
    "certificate:issue:",
    "entities-record-import:",
    "attachment_attached:",
    "attachment_removed:",
    "effect_applied:",
    "ordering_lag_exceeded:",
    "definition_promoted:",
    "definition_version_rolled_back:",
    "promotion_assertion_teardown_failed:",
    "req345-seed-"
  ]

  # 255 - byte_size("client:inst_cancel:") - 36 - 1 - 36 - 1 = 162.
  @raw_max_long 199
  @raw_max_instance 162

  # GH #2578: placeholder removal date (#2550's production deploy plus one
  # release), moved once the deploy date is known. Pinned by the test
  # "legacy cutoff is pinned". Deliberately not app env: a per-environment
  # value could drift and misconfigure silently.
  @legacy_cutoff ~U[2026-11-16 00:00:00.000000Z]

  @doc "The largest accepted raw caller key, in bytes, for `route`."
  @spec raw_max(route() | :script) :: 199 | 162
  def raw_max(route) when route in [:rec, :inst_start, :script], do: @raw_max_long
  def raw_max(route) when route in [:inst_cancel, :inst_rebind], do: @raw_max_instance

  @doc """
  Builds the stored key for a caller key `raw` on `route`. `instance_id` is
  `nil` for `:rec`/`:inst_start` and required for `:inst_cancel`/`:inst_rebind`.
  Raises `FunctionClauseError` on a wrong instance arity, a non-36-byte uuid,
  or an empty or over-long `raw`.
  """
  @spec client_key(route(), Ecto.UUID.t(), Ecto.UUID.t() | nil, String.t()) :: String.t()
  def client_key(route, actor_id, nil, raw)
      when route in [:rec, :inst_start] and is_binary(actor_id) and byte_size(actor_id) == 36 and
             is_binary(raw) and byte_size(raw) > 0 and byte_size(raw) <= @raw_max_long do
    "client:" <> route_token(route) <> ":" <> actor_id <> ":" <> raw
  end

  def client_key(route, actor_id, instance_id, raw)
      when route in [:inst_cancel, :inst_rebind] and is_binary(actor_id) and
             byte_size(actor_id) == 36 and is_binary(instance_id) and
             byte_size(instance_id) == 36 and is_binary(raw) and byte_size(raw) > 0 and
             byte_size(raw) <= @raw_max_instance do
    "client:" <> route_token(route) <> ":" <> actor_id <> ":" <> instance_id <> ":" <> raw
  end

  @doc """
  Resolves the key for a record write from its validated body `attrs`. Absent
  gives a bare minted UUID; a supplied key within `raw_max/1` gives the
  namespaced key, plus `legacy_raw` when the key could be a pre-#2550 caller
  key (it matches no server or caller family, guard (iv)).
  """
  @spec from_body(map(), :rec, Ecto.UUID.t()) ::
          {:ok, resolved()} | {:error, :idempotency_key_too_long}
  def from_body(attrs, :rec, actor_id) when is_map(attrs) do
    case Map.get(attrs, @body_field) do
      raw when is_binary(raw) and byte_size(raw) > @raw_max_long ->
        {:error, :idempotency_key_too_long}

      raw when is_binary(raw) and byte_size(raw) > 0 ->
        {:ok, %{key: client_key(:rec, actor_id, nil, raw), legacy_raw: legacy_raw(raw)}}

      _absent ->
        {:ok, %{key: Ecto.UUID.generate(), legacy_raw: nil}}
    end
  end

  @doc """
  Resolves the key for an instance route from the first `idempotency-key`
  header value. Absent or empty gives a bare minted UUID.
  """
  @spec from_header(Plug.Conn.t(), route(), Ecto.UUID.t(), Ecto.UUID.t() | nil) ::
          {:ok, String.t()} | {:error, :idempotency_key_too_long}
  def from_header(%Plug.Conn{} = conn, route, actor_id, instance_id) do
    case Plug.Conn.get_req_header(conn, @header) do
      [raw | _rest] when byte_size(raw) > 0 ->
        if byte_size(raw) > raw_max(route),
          do: {:error, :idempotency_key_too_long},
          else: {:ok, client_key(route, actor_id, instance_id, raw)}

      _absent_or_empty ->
        {:ok, Ecto.UUID.generate()}
    end
  end

  @doc "Namespaces a Lua script's `emit_event` key. No legacy lookup."
  @spec script_key(term(), Ecto.UUID.t()) ::
          {:ok, String.t()} | {:error, :invalid_idempotency_key}
  def script_key(raw, actor_id)
      when is_binary(raw) and byte_size(raw) > 0 and byte_size(raw) <= @raw_max_long and
             is_binary(actor_id) do
    {:ok, "script:" <> actor_id <> ":" <> raw}
  end

  def script_key(_raw, _actor_id), do: {:error, :invalid_idempotency_key}

  @doc """
  The stable 422 field error for an over-long key. `field` names the body
  field or the header; no `received` echo.
  """
  @spec too_long_error(:body | :header) :: FieldError.t()
  def too_long_error(:body), do: too_long(@body_field)
  def too_long_error(:header), do: too_long(@header)

  @doc "Caller-key families. Never produced by a server writer."
  @spec caller_prefixes() :: [String.t()]
  def caller_prefixes, do: @caller_prefixes

  @doc "Server-built key families (design §1b)."
  @spec server_prefixes() :: [String.t()]
  def server_prefixes, do: @server_prefixes

  @doc "Legacy guard (i): only rows written before this instant count. GH #2578."
  @spec legacy_cutoff() :: DateTime.t()
  def legacy_cutoff, do: @legacy_cutoff

  @doc """
  The one-release legacy lookup (design D3, entity records only): the
  same-actor ENTITY_RECORD_CREATED/UPDATED event written before
  `legacy_cutoff/0` under the bare key `legacy_raw`, or `:none`. Removed by
  GH #2578.
  """
  @spec legacy_original(resolved(), Ecto.UUID.t(), prefix: String.t()) :: {:ok, Event.t()} | :none
  def legacy_original(%{legacy_raw: nil}, _actor_id, _opts), do: :none

  def legacy_original(%{legacy_raw: raw}, actor_id, opts) when is_binary(raw) do
    event_types = Records.legacy_lookup_event_types()

    case EventStore.get_legacy_original(raw, actor_id, event_types, @legacy_cutoff, opts) do
      {:ok, %Event{} = event} -> {:ok, event}
      {:error, :not_found} -> :none
    end
  end

  defp legacy_raw(raw) do
    if String.starts_with?(raw, @server_prefixes ++ @caller_prefixes), do: nil, else: raw
  end

  defp route_token(:rec), do: "rec"
  defp route_token(:inst_start), do: "inst_start"
  defp route_token(:inst_cancel), do: "inst_cancel"
  defp route_token(:inst_rebind), do: "inst_rebind"

  defp too_long(field) do
    %FieldError{field: field, constraint: "max_length", message: "length must be ≤ maximum"}
  end
end
