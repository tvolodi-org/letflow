defmodule Letflow.Engine.ServiceTask do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  EXT-01 (REQ-056) — service task configuration parsing, HTTP failure
  classification, retry backoff/decision, and idempotency-key construction.
  Ports `service_task.zig`'s engine-side pure logic per
  `lib/letflow/design/service_task.md` (the gate-approved design this module
  implements, 3rd-pass PASS) — every function here is **pure**: no
  `Letflow.Repo`, no `Logger.*`, no HTTP/file call, no clock read.

  ## Scope boundary — injectable transport and catalog lookup, no DLQ built here

  The actual outbound HTTP transport is INJECTABLE (`transport_fun/0`, a
  function value the caller supplies) -- this module wires no concrete HTTP
  client. The `service_catalog` lookup `route_kind: :catalog_service`
  originally needed was modelled as INJECTABLE (`catalog_lookup_fun/0`);
  that seam is superseded by activation-time resolution in `Letflow.Engine`
  (ISS-0917), which resolves the instance's pinned catalog version via
  `Letflow.ServiceCatalog.resolve_pinned_version/3` and freezes the rendered
  URL into the dispatch row. `catalog_lookup_fun/0` is no longer consumed by
  the dispatcher and is kept only as a documented historical type.

  Every `decide_failure/3` `:give_up` outcome (whether from exhausted retries
  or an immediately non-retriable failure) is handed to
  `Letflow.Engine.set_instance_error/2` (REQ-061) via
  `build_service_task_give_up_error_attrs/1` -- it does NOT land in a
  dead-letter queue here. R-Co's OBS-05 dead-letter API (`src/dlq/`) is the
  eventual operator-facing retry/discard surface for an instance parked in
  `ERROR`, and it belongs to stage S6 (operational cross-cutting) -- NOT YET
  BUILT. No partial DLQ (no retry-queue table, no discard endpoint, no
  background sweep of `ERROR`-status instances) is introduced by this
  module. `instance_projections.status == :error` plus its `error_detail`
  column, already written by `set_instance_error/2`, is the durable record
  OBS-05's future dead-letter listing will query -- no additional table is
  needed for S6 to find every `ERROR`-halted service-task instance once it
  exists.

  ## Not wired to a dispatch loop yet

  This module offers no HTTP/Plug route and no dispatch-orchestration
  process (a `gen_statem`/`Task` that actually sleeps for backoff and calls
  the transport in a loop) — that belongs to S4 (routes) or a future
  requirement (design doc §1). `compute_service_task_backoff_ms/3` is
  deliberately a pure, no-sleep function so a future orchestration caller
  can unit-test its own retry loop's *decisions* without any real waiting.

  ## Purity

  `parse_config_from_node_attributes/1`, `validate_rendered_url/1`,
  `classify_failure_kind/1`, `is_retriable_failure/1`,
  `compute_service_task_backoff_ms/3`, `decide_failure/3`,
  `build_idempotency_key/4`, `build_service_task_give_up_error_attrs/1`, and
  `build_empty_url_error_attrs/1` are all pure — no `Letflow.Repo`, no
  `Logger.*`, no HTTP/file call, no clock read except where a caller
  supplies a value explicitly.
  """

  alias Letflow.Definitions.Graph

  defmodule Config do
    @moduledoc """
    Parsed SERVICE_TASK dispatch configuration — design doc §3.1. Plain
    struct, not `Ecto.Schema`, mirrors `Graph.Node`/`Graph.Edge`'s
    nested-plain-struct convention.
    """

    @enforce_keys [:node_id, :route_kind, :method, :timeout_ms, :retry_limit]
    defstruct [
      :node_id,
      :route_kind,
      :url_template,
      :service_id,
      :method,
      :body_template,
      :script_key,
      :script_version,
      headers: %{},
      timeout_ms: 30_000,
      retry_limit: 3,
      warnings: []
    ]

    @type route_kind :: :inline_url | :catalog_service | :script
    @type http_method :: :GET | :POST | :PUT | :PATCH | :DELETE
    @type warning :: :both_url_and_service_id_provided_url_ignored

    @type t :: %__MODULE__{
            node_id: String.t(),
            route_kind: route_kind(),
            url_template: String.t() | nil,
            service_id: String.t() | nil,
            method: http_method(),
            body_template: String.t() | nil,
            script_key: String.t() | nil,
            script_version: pos_integer() | nil,
            headers: %{optional(String.t()) => String.t()},
            timeout_ms: pos_integer(),
            retry_limit: non_neg_integer(),
            warnings: [warning()]
          }
  end

  @typedoc "Closed, 7-member failure-kind union — EXT-01's own fixed outcome taxonomy."
  @type failure_kind ::
          :timeout
          | :network
          | :http_non_2xx
          | :http_redirect_3xx
          | :rate_limited_429
          | :invalid_2xx_body
          | :request_build_error

  @typedoc "The shape a `transport_fun()` implementation returns."
  @type raw_outcome ::
          :timeout
          | {:network, reason :: term()}
          | {:request_build_error, reason :: term()}
          | {:http, status :: pos_integer(), body :: String.t() | nil}

  @typedoc """
  Not a `@behaviour` — a plain 3-arity function value, matching REQ-031's
  `Lookup` struct-of-functions rationale: a caller/test supplies a different
  transport per call without `Application.put_env/3` cross-test coupling.
  **No concrete implementation of this type exists in this codebase yet.**
  """
  @type transport_fun ::
          (Config.t(), rendered_url :: String.t(), rendered_body :: String.t() | nil ->
             raw_outcome())

  @typedoc """
  Historical contract: resolves `route_kind: :catalog_service`'s `service_id`
  to a URL template. **Superseded by activation-time resolution in
  `Letflow.Engine` (ISS-0917)** -- no longer consumed by the dispatcher.
  This module's own functions never call this type; it is kept (not
  deleted) as a documented contract only.
  """
  @type catalog_lookup_fun ::
          (service_id :: String.t(), tenant_id :: Ecto.UUID.t() ->
             {:ok, url_template :: String.t()} | {:error, :not_registered})

  @typedoc "0 = first attempt, never retried yet."
  @type attempt_index :: non_neg_integer()

  @type retry_decision :: :retry | :give_up

  @type config_parse_error ::
          :missing_node_id
          | :missing_url_and_service_id
          | {:invalid_method, term()}
          | {:invalid_timeout_ms, term()}
          | {:invalid_retry_limit, term()}
          | :conflicting_routes
          | {:invalid_script_reference, :key | :version}

  @type empty_url_context :: %{
          required(:instance_id) => Ecto.UUID.t(),
          required(:node_id) => String.t(),
          required(:actor_id) => Ecto.UUID.t() | nil,
          required(:idempotency_key) => String.t(),
          required(:variables) => map(),
          optional(:details) => map()
        }

  @type catalog_unresolved_context :: %{
          required(:instance_id) => Ecto.UUID.t(),
          required(:node_id) => String.t(),
          required(:actor_id) => Ecto.UUID.t() | nil,
          required(:idempotency_key) => String.t(),
          required(:variables) => map(),
          required(:reason) => term()
        }

  @type service_task_give_up_context :: %{
          required(:instance_id) => Ecto.UUID.t(),
          required(:node_id) => String.t(),
          required(:actor_id) => Ecto.UUID.t() | nil,
          required(:idempotency_key) => String.t(),
          required(:variables) => map(),
          required(:last_failure_kind) => failure_kind(),
          required(:attempt_index) => attempt_index(),
          required(:retry_limit) => non_neg_integer()
        }

  @valid_methods ~w(GET POST PUT PATCH DELETE)a
  @default_timeout_ms 30_000
  @default_retry_limit 3
  @default_method :POST

  # ===========================================================================
  # §4 parse_config_from_node_attributes/1 — design doc §5.1 field derivation
  # ===========================================================================

  @doc """
  Builds a `Config.t()` from a SERVICE_TASK `Graph.Node.t()`'s `id` and
  `attributes` (string-keyed map). Pure, no I/O. `timeout_ms` defaults to
  `30_000` and `retry_limit` defaults to `3` when the node omits them (AC1);
  both, when present, are read but not re-validated against REQ-029's
  `[1, 300_000]` range here — REQ-029's CHK-11 already gates this at
  graph-validation time (design doc §9 OQ-2).
  """
  @spec parse_config_from_node_attributes(node :: Graph.Node.t()) ::
          {:ok, Config.t()} | {:error, config_parse_error()}
  def parse_config_from_node_attributes(%Graph.Node{id: node_id, attributes: attributes}) do
    attrs = attributes || %{}

    # GH 2534 PR 7c-1 (design gh2534-7c-script-handler.md 4.1): a node binding a tenant
    # script (non-empty "script_key") is route :script; the HTTP branch is unchanged.
    case ref_id(attrs, "script_key") do
      nil -> parse_http_config(node_id, attrs)
      script_key -> parse_script_config(node_id, script_key, attrs)
    end
  end

  # method/timeout_ms/retry_limit/headers/body_template are ignored for :script; the struct's
  # enforced keys get the HTTP defaults (never read on this route).
  defp parse_script_config(node_id, script_key, attrs) do
    with {:ok, node_id} <- fetch_node_id(node_id) do
      version = Map.get(attrs, "script_version")

      cond do
        ref_id(attrs, "endpoint") != nil or ref_id(attrs, "service_id") != nil ->
          {:error, :conflicting_routes}

        not Letflow.Scripts.Runtime.script_key?(script_key) ->
          {:error, {:invalid_script_reference, :key}}

        not (is_integer(version) and version >= 1) ->
          {:error, {:invalid_script_reference, :version}}

        true ->
          {:ok,
           %Config{
             node_id: node_id,
             route_kind: :script,
             method: @default_method,
             timeout_ms: @default_timeout_ms,
             retry_limit: 0,
             script_key: script_key,
             script_version: version
           }}
      end
    end
  end

  defp parse_http_config(node_id, attrs) do
    with {:ok, node_id} <- fetch_node_id(node_id),
         {:ok, method} <- parse_method(attrs),
         {:ok, timeout_ms} <- parse_timeout_ms(attrs),
         {:ok, retry_limit} <- parse_retry_limit(attrs) do
      service_id = ref_id(attrs, "service_id")
      url_template = ref_id(attrs, "endpoint")

      case {service_id, url_template} do
        {nil, nil} ->
          {:error, :missing_url_and_service_id}

        {service_id, url_template} ->
          route_kind = if service_id, do: :catalog_service, else: :inline_url

          warnings =
            if service_id && url_template,
              do: [:both_url_and_service_id_provided_url_ignored],
              else: []

          {:ok,
           %Config{
             node_id: node_id,
             route_kind: route_kind,
             url_template: url_template,
             service_id: service_id,
             method: method,
             body_template: Map.get(attrs, "body_template"),
             headers: parse_headers(attrs),
             timeout_ms: timeout_ms,
             retry_limit: retry_limit,
             warnings: warnings
           }}
      end
    end
  end

  defp fetch_node_id(node_id) when is_binary(node_id) do
    if String.trim(node_id) == "" do
      {:error, :missing_node_id}
    else
      {:ok, node_id}
    end
  end

  defp fetch_node_id(_other), do: {:error, :missing_node_id}

  defp parse_method(attrs) do
    case Map.get(attrs, "method") do
      nil ->
        {:ok, @default_method}

      value when is_binary(value) ->
        case value |> String.upcase() |> safe_to_existing_atom() do
          method when method in @valid_methods -> {:ok, method}
          _other -> {:error, {:invalid_method, value}}
        end

      other ->
        {:error, {:invalid_method, other}}
    end
  end

  defp safe_to_existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp parse_timeout_ms(attrs) do
    case Map.get(attrs, "timeout_ms") do
      nil -> {:ok, @default_timeout_ms}
      value when is_integer(value) -> {:ok, value}
      other -> {:error, {:invalid_timeout_ms, other}}
    end
  end

  defp parse_retry_limit(attrs) do
    case Map.get(attrs, "retry_limit") do
      nil -> {:ok, @default_retry_limit}
      value when is_integer(value) and value >= 0 -> {:ok, value}
      other -> {:error, {:invalid_retry_limit, other}}
    end
  end

  defp parse_headers(attrs) do
    case Map.get(attrs, "headers") do
      value when is_map(value) -> value
      _other -> %{}
    end
  end

  # Mirrors ServiceScopeValidator.ref_id/2 (design doc §0) — a missing key,
  # nil, non-string, or "" value is treated as "not provided."
  defp ref_id(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and byte_size(value) > 0 -> value
      _other -> nil
    end
  end

  # ===========================================================================
  # Template placeholder grammar (GH #2587 PR A1b, design 2A.2 L5-L6)
  # ===========================================================================

  @doc """
  The ONE source of the `{{variables.KEY}}` placeholder grammar: `Letflow.Engine`'s URL and
  body renderers substitute with it and `Letflow.Definitions.ReservedReferences` parses
  templates with it. KEY is `[a-zA-Z0-9_]+`: it has no dot, so a placeholder can only ever
  name a flat top-level key.

  Invariant I-13 (SEC F1 on the A1b gate): any change to this pattern must ship, in the same
  PR, the service-catalog-version `endpoint_url` reserved-name check (GH #2623), because a
  catalog template is rendered with this grammar but is not part of a definition, so
  activation-time checks cannot see it. It must also ship a NEW migration replacing the two
  catalog CHECK constraints (GH #2638, `*_endpoint_url_no_reserved_ref`) and the parity table.
  A function, not a module attribute, so the compiled regex is never stored in a module attribute.
  """
  @spec template_placeholder() :: Regex.t()
  def template_placeholder, do: ~r/\{\{\s*variables\.([a-zA-Z0-9_]+)\s*\}\}/

  @doc """
  The KEYs captured by `template_placeholder/0` in `template`, in order (duplicates kept);
  `nil` -> `[]`. Pure.
  """
  @spec template_variable_keys(String.t() | nil) :: [String.t()]
  def template_variable_keys(nil), do: []

  def template_variable_keys(template) when is_binary(template) do
    template_placeholder()
    |> Regex.scan(template, capture: :all_but_first)
    |> Enum.map(fn [key] -> key end)
  end

  @doc """
  The strict `template_placeholder/0` with its KEY class widened to admit a dot (GH #2623,
  invariant I-13). DERIVED from `Regex.source(template_placeholder())`, never hand-copied, so
  the braces, the `variables.` literal and the whitespace handling cannot drift. It exists only
  for the service-catalog `endpoint_url` reserved-name refusal: the renderer does NOT use it, so
  rendering output is unchanged. If the strict KEY class is edited so the replacement matches
  nothing, the derived pattern equals the strict one.
  """
  @spec template_reference_placeholder() :: Regex.t()
  def template_reference_placeholder do
    template_placeholder()
    |> Regex.source()
    |> String.replace("[a-zA-Z0-9_]+", "[a-zA-Z0-9_.]+")
    |> Regex.compile!(Regex.opts(template_placeholder()))
  end

  @doc """
  The KEYs captured by `template_reference_placeholder/0` in `template`, in order (duplicates
  kept); `nil` and a non-binary -> `[]`. Pure, total.
  """
  @spec template_reference_keys(String.t() | nil) :: [String.t()]
  def template_reference_keys(template) when is_binary(template) do
    template_reference_placeholder()
    |> Regex.scan(template, capture: :all_but_first)
    |> Enum.map(fn [key] -> key end)
  end

  def template_reference_keys(_not_a_template), do: []

  # ===========================================================================
  # validate_rendered_url/1 (AC6)
  # ===========================================================================

  @doc """
  Trims `rendered_url` and rejects `nil` or an all-whitespace/empty result
  (AC6). Pure. Called by a future activation-time caller after template
  rendering and before any dispatch attempt.
  """
  @spec validate_rendered_url(rendered_url :: String.t() | nil) ::
          :ok | {:error, :empty_rendered_url}
  def validate_rendered_url(nil), do: {:error, :empty_rendered_url}

  def validate_rendered_url(rendered_url) when is_binary(rendered_url) do
    if String.trim(rendered_url) == "" do
      {:error, :empty_rendered_url}
    else
      :ok
    end
  end

  @doc """
  AC6's concrete routing element — builds the exact
  `Letflow.Engine.standalone_error_attrs()` shape `Letflow.Engine.set_instance_error/2`
  requires, for the "URL template rendered to an empty string" case. See §6
  of the design doc for the full routing statement.
  """
  @spec build_empty_url_error_attrs(empty_url_context()) ::
          Letflow.Engine.standalone_error_attrs()
  def build_empty_url_error_attrs(%{} = context) do
    %{
      instance_id: Map.fetch!(context, :instance_id),
      error_type: :service_task_url_rendered_empty,
      affected: {:node, Map.fetch!(context, :node_id)},
      reason: "service task URL template rendered to an empty string",
      variables: Map.fetch!(context, :variables),
      details: Map.get(context, :details, %{}),
      actor_id: Map.fetch!(context, :actor_id),
      idempotency_key: Map.fetch!(context, :idempotency_key)
    }
  end

  @doc """
  ISS-0917 -- builds the `Letflow.Engine.standalone_error_attrs()` shape for a
  catalog-referencing SERVICE_TASK whose pinned `service_catalog` version
  could not be resolved at activation. `reason` is one of the closed
  `Letflow.Engine` catalog-resolution reasons; only its atom CLASS is
  persisted in `details`, and `reason` text is a fixed sentence per class --
  never an interpolation of variables, headers, URLs or the service id.
  Pure, same contract as `build_empty_url_error_attrs/1`.
  """
  @spec build_catalog_unresolved_error_attrs(catalog_unresolved_context()) ::
          Letflow.Engine.standalone_error_attrs()
  def build_catalog_unresolved_error_attrs(%{} = context) do
    reason_class = catalog_reason_class(Map.fetch!(context, :reason))

    %{
      instance_id: Map.fetch!(context, :instance_id),
      error_type: :service_task_catalog_unresolved,
      affected: {:node, Map.fetch!(context, :node_id)},
      reason: catalog_reason_sentence(reason_class),
      variables: Map.fetch!(context, :variables),
      details: %{reason: reason_class},
      actor_id: Map.fetch!(context, :actor_id),
      idempotency_key: Map.fetch!(context, :idempotency_key)
    }
  end

  @doc """
  The `EXECUTION_ERROR` attrs for a SERVICE_TASK whose URL or body would render a labelled variable
  (decision 0062 R12, GH #2616 part 2). `keys` are the placeholder names only; no value is carried.
  `variable_labels` travel as `labels`, so the event's own snapshot carries the labels the refusal
  was decided on (R8h).
  """
  @spec build_restricted_outbound_error_attrs(map()) :: map()
  def build_restricted_outbound_error_attrs(%{} = context) do
    %{
      instance_id: Map.fetch!(context, :instance_id),
      error_type: :service_task_restricted_variable_outbound,
      affected: {:node, Map.fetch!(context, :node_id)},
      reason: "service task would send a restricted variable to an outbound endpoint",
      variables: Map.fetch!(context, :variables),
      labels: Map.fetch!(context, :variable_labels),
      details: %{keys: Enum.sort(Map.fetch!(context, :keys))},
      actor_id: Map.fetch!(context, :actor_id),
      idempotency_key: Map.fetch!(context, :idempotency_key)
    }
  end

  defp catalog_reason_class({class, _detail}) when is_atom(class), do: class
  defp catalog_reason_class({class, _kind, _ref}) when is_atom(class), do: class
  defp catalog_reason_class(class) when is_atom(class), do: class

  defp catalog_reason_sentence(:pin_missing),
    do: "service task catalog service has no pin recorded for this instance"

  defp catalog_reason_sentence(:pin_has_no_identity),
    do: "service task catalog pin carries no version identity"

  defp catalog_reason_sentence(:pins_unavailable),
    do: "service task catalog pins could not be read for this instance"

  defp catalog_reason_sentence(:version_not_found),
    do: "service task catalog service version could not be resolved"

  defp catalog_reason_sentence(:required_auth_unsupported),
    do: "service task catalog service requires authentication, which is not supported"

  defp catalog_reason_sentence(_other),
    do: "service task catalog service could not be resolved"

  # ===========================================================================
  # classify_failure_kind/1 (AC2, AC3, AC5) — design doc §5.2
  # ===========================================================================

  @doc """
  Maps a `raw_outcome()` to either `{:success, decoded_body}` (a 2xx response
  whose body decodes as a JSON object, AC5) or one of the 7 `failure_kind()`
  atoms. Never raises on a JSON-decode failure — a body that fails to
  decode, or decodes to a non-map, classifies as `:invalid_2xx_body` (AC5).
  """
  @spec classify_failure_kind(raw_outcome()) :: {:success, decoded_body :: map()} | failure_kind()
  def classify_failure_kind(:timeout), do: :timeout
  def classify_failure_kind({:network, _reason}), do: :network
  def classify_failure_kind({:request_build_error, _reason}), do: :request_build_error

  def classify_failure_kind({:http, status, body}) when status in 200..299 do
    case decode_json_object(body) do
      {:ok, decoded_map} -> {:success, decoded_map}
      :error -> :invalid_2xx_body
    end
  end

  def classify_failure_kind({:http, 429, _body}), do: :rate_limited_429

  def classify_failure_kind({:http, status, _body}) when status in 300..399,
    do: :http_redirect_3xx

  def classify_failure_kind({:http, status, _body}) when is_integer(status), do: :http_non_2xx

  defp decode_json_object(nil), do: :error

  defp decode_json_object(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _other -> :error
    end
  end

  defp decode_json_object(_other), do: :error

  # ===========================================================================
  # is_retriable_failure/1 / decide_failure/3 (AC2, AC3) — design doc §5.3
  # ===========================================================================

  @doc "Pure, total function over the closed `failure_kind()` union."
  @spec is_retriable_failure(failure_kind()) :: boolean()
  def is_retriable_failure(:timeout), do: true
  def is_retriable_failure(:network), do: true
  def is_retriable_failure(:rate_limited_429), do: true
  def is_retriable_failure(:http_redirect_3xx), do: false
  def is_retriable_failure(:http_non_2xx), do: false
  def is_retriable_failure(:invalid_2xx_body), do: false
  def is_retriable_failure(:request_build_error), do: false

  @doc """
  `:give_up` immediately if `is_retriable_failure(kind)` is `false`
  (regardless of `attempt_index`/`retry_limit`); otherwise `:retry` while
  `attempt_index < retry_limit`, else `:give_up`.
  """
  @spec decide_failure(
          kind :: failure_kind(),
          attempt_index :: attempt_index(),
          retry_limit :: non_neg_integer()
        ) :: retry_decision()
  def decide_failure(kind, attempt_index, retry_limit) do
    cond do
      not is_retriable_failure(kind) -> :give_up
      attempt_index < retry_limit -> :retry
      true -> :give_up
    end
  end

  # ===========================================================================
  # compute_service_task_backoff_ms/3 (AC4) — design doc §5's exponential/cap
  # ===========================================================================

  @doc """
  Pure, deterministic: `min(base_ms * 2^attempt_index, cap_ms)`. No jitter.
  No sleep, no clock read.
  """
  @spec compute_service_task_backoff_ms(
          attempt_index :: attempt_index(),
          base_ms :: pos_integer(),
          cap_ms :: pos_integer()
        ) :: non_neg_integer()
  def compute_service_task_backoff_ms(attempt_index, base_ms, cap_ms)
      when is_integer(attempt_index) and attempt_index >= 0 and is_integer(base_ms) and
             base_ms > 0 and is_integer(cap_ms) and cap_ms > 0 do
    min(base_ms * Integer.pow(2, attempt_index), cap_ms)
  end

  # ===========================================================================
  # build_idempotency_key/4 — design doc §5.4
  # ===========================================================================

  @doc """
  Pure, deterministic string concatenation only — no hashing, no clock, no
  randomness. Two calls with identical arguments produce the identical key.
  """
  @spec build_idempotency_key(
          instance_id :: Ecto.UUID.t(),
          node_id :: String.t(),
          token_id :: Ecto.UUID.t() | String.t(),
          attempt_index :: attempt_index()
        ) :: String.t()
  def build_idempotency_key(instance_id, node_id, token_id, attempt_index) do
    "service_task:" <>
      instance_id <>
      ":" <> node_id <> ":" <> to_string(token_id) <> ":" <> Integer.to_string(attempt_index)
  end

  # ===========================================================================
  # build_service_task_give_up_error_attrs/1 (AC5(b), AC8) — design doc §4, §6
  # ===========================================================================

  @doc """
  The single routing target for every `decide_failure/3` `:give_up` outcome,
  regardless of cause — a retriable kind whose `attempt_index` reached
  `retry_limit` (the "exhausted retry" case AC8 names), or a kind
  `is_retriable_failure/1` says is not retriable at all, which gives up on
  attempt 0 regardless of `retry_limit` (AC5(b)'s "2xx JSON array/bare
  string does not merge" case). Builds the exact map shape
  `Letflow.Engine.set_instance_error/2` requires as its own `attrs` argument.
  This module never calls `ExecutionError.append_multi/3` directly and never
  writes its own `instance_projections` update — a future dispatch-
  orchestration caller is expected to call `Letflow.Engine.set_instance_error/2`
  with this function's return value directly.
  """
  @spec build_service_task_give_up_error_attrs(service_task_give_up_context()) ::
          Letflow.Engine.standalone_error_attrs()
  def build_service_task_give_up_error_attrs(%{} = context) do
    last_failure_kind = Map.fetch!(context, :last_failure_kind)
    attempt_index = Map.fetch!(context, :attempt_index)
    retry_limit = Map.fetch!(context, :retry_limit)

    cause_text =
      if is_retriable_failure(last_failure_kind) do
        "retries exhausted after #{retry_limit} attempts"
      else
        "not retriable"
      end

    %{
      instance_id: Map.fetch!(context, :instance_id),
      error_type: :service_task_retries_exhausted,
      affected: {:node, Map.fetch!(context, :node_id)},
      reason: "service task failed (#{last_failure_kind}): #{cause_text}",
      variables: Map.fetch!(context, :variables),
      details: %{
        last_failure_kind: last_failure_kind,
        attempt_index: attempt_index,
        retry_limit: retry_limit
      },
      actor_id: Map.fetch!(context, :actor_id),
      idempotency_key: Map.fetch!(context, :idempotency_key)
    }
  end
end
