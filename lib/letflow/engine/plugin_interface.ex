defmodule Letflow.Engine.PluginInterface do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  REQ-057 (EXT-03) — the plugin handler contract: a `@behaviour` every
  in-process plugin handler module implements, plus `invoke/2,3`, the single
  crash-safe entry point every future caller must use instead of calling a
  handler's `handle_node/1` directly. Ports `plugin_interface.zig`'s handler
  contract (a function-pointer union type) as the idiomatic BEAM equivalent —
  see `lib/letflow/design/req057-plugin-interface-registry.md` §2.3 for why a
  `@behaviour` + one `@callback` returning a plain two-member tagged tuple is
  the closest structural analogue Elixir has to a C-ABI tagged union: exactly
  one required entry point, exactly one of two possible tagged outcomes, no
  third "did not respond" state representable at the type level (that third
  state — crash/timeout — is handled entirely outside the type system, by
  `invoke/2,3` below, never by adding a third tuple member to `outcome()`).

  ## Scope boundary — no WASM host, no dynamic loading, no runtime dispatch wiring

  `Letflow.Engine.PluginInterface` supports **only in-process Elixir modules**
  implementing this behaviour directly — no dynamic code-loading, no WASM
  sandboxing (R-Co's `src/wasm/`, S5, needs its own build-vs-bind decision
  record first), no network-fetched plugin of any kind. Every handler module
  must already be compiled into the running release (AC4's "startup-only, no
  dynamic loading"). This module also does **not** wire `resolve_*` or
  `invoke/2,3` into the engine's actual node-dispatch path (i.e. no call site
  inside whatever function ends up executing a `:SERVICE_TASK`/plugin-claimed
  node at runtime) — that belongs to whichever future requirement builds
  runtime plugin/service-task dispatch (most plausibly REQ-056, `pending`).
  §7/§8 of the design doc name the exact call shapes that future requirement's
  own CODE-DESIGNER should reuse rather than reinvent.

  ## Crash safety — why a bare `try/rescue` is insufficient

  `try/rescue` catches a `raise` (an exception) but has no clause that
  observes a linked/monitored process's abnormal `exit` — `rescue` runs
  inside the *same* process as the code that raised; an `exit/1` call, or an
  external `Process.exit(pid, reason)`, terminates the process without ever
  running a `rescue` clause in the caller. `invoke/2,3` is built specifically
  so a plugin handler crash (AC3) is not left in that gap — the same
  "observe an exit via a monitor-based signal, not a `rescue` clause"
  principle `Letflow.SandboxPool`'s own `Process.monitor`/`handle_info({:DOWN,
  ...})` mechanism uses for a different purpose (a different primitive here —
  `Task.Supervisor` + `Task.yield/2`, not a bare `Process.monitor` — but the
  same principle).

  **Covers:** a handler's own deliberate `{:error, _}` return, an uncaught
  `raise` anywhere in the handler's call graph, an explicit `exit/1` call, a
  handler process being sent `Process.exit(pid, :kill)` by something else, and
  a handler that simply hangs past its timeout. All five surface as
  `{:error, reason}` from `invoke/2,3` — never as an exception or exit
  propagating into the caller.

  **Does NOT cover:** a hard kill of the BEAM node itself, or `System.halt/0`
  — no monitor, task, or supervisor observes either from inside the same
  node. This is an accepted, stated limitation (the same residual class
  `lib/letflow/definitions.ex`'s own moduledoc discloses for sandbox
  teardown), not a gap this module papers over.

  ## I/O-free with respect to Letflow's own persistence layer (INV-PR-8)

  Neither the behaviour nor `invoke/2,3` nor `build_error_args/3` makes a
  `Letflow.Repo` call, a `Letflow.EventStore.append/2` call, or opens an
  `Ecto.Multi`/transaction of its own — this module is a pure
  dispatch-and-observe mechanism over whatever the handler itself does.
  Persisting the outcome (a merge on `{:complete, _}` via
  `Letflow.Engine.VariableMerge.merge/3`, an `EXECUTION_ERROR` append on
  `{:error, _}` via `build_error_args/3` + `Letflow.Engine.set_instance_error/2`
  or `Letflow.Engine.ExecutionError.append_multi/3`) is the future
  dispatch-integration caller's own job.

  See `lib/letflow/design/req057-plugin-interface-registry.md` (gate-approved,
  1 rework iteration) for the full design this module ports verbatim.
  """

  alias Letflow.Engine.ExecutionError
  alias Letflow.Engine.VariableLabels

  defmodule ExecutionContext do
    @moduledoc """
    The context every plugin handler receives on `handle_node/1`. See the
    design doc §2.2 for the per-field rationale — in particular, `node_type`
    is deliberately `String.t()`, not `Letflow.Definitions.Graph.node_type()`'s
    atom union, so this struct never needs a dependency on `Graph`'s
    atom-mapping module (a future dispatch-integration caller converts
    `Graph.Node.node_type()` to its string form via `to_string/1` when
    building this struct).
    """

    @enforce_keys [
      :instance_id,
      :definition_id,
      :node_id,
      :node_type,
      :variables,
      :node_config,
      :trace_id
    ]
    # GH #2616 part 2 (decision 0062 R8): `variable_labels` and `hidden_labels` are filled by the
    # builder that constructs the context. A missing `hidden_labels` (`nil`) hides every labelled
    # variable, so an unfilled context fails closed. Neither field is required.
    defstruct [
      :instance_id,
      :definition_id,
      :node_id,
      :node_type,
      :variables,
      :node_config,
      :trace_id,
      variable_labels: %{},
      hidden_labels: nil
    ]

    @type t :: %__MODULE__{
            instance_id: Ecto.UUID.t(),
            definition_id: Ecto.UUID.t(),
            node_id: String.t(),
            node_type: String.t(),
            variables: map(),
            node_config: map(),
            trace_id: String.t(),
            variable_labels: %{optional(String.t()) => [String.t()]},
            hidden_labels: MapSet.t(String.t()) | nil
          }
  end

  @typedoc """
  A handler's own two possible outcomes. `output_variables` is a plain
  `map()`, the shape `Letflow.Engine.VariableMerge.merge/3`'s
  `incoming_variables` parameter already expects verbatim — no adapter. A
  handler MAY encode more detail into `reason`; this behaviour does not
  define a machine-parsable sub-format.
  """
  @type outcome :: {:complete, output_variables :: map()} | {:error, reason :: String.t()}

  @doc """
  The single required entry point every plugin handler module implements.
  Never call this directly — always go through `invoke/2,3` (below), which
  is the only crash-safe caller of this callback.
  """
  @callback handle_node(context :: ExecutionContext.t()) :: outcome()

  @typedoc "Options accepted by `invoke/3`."
  @type invoke_opts :: [timeout_ms: pos_integer()]

  @typedoc "`build_error_args/3`'s caller-supplied metadata, not derivable from `ExecutionContext.t()` alone."
  @type error_meta :: %{
          required(:actor_id) => Ecto.UUID.t() | nil,
          required(:idempotency_key) => String.t()
        }

  # design doc §10 OQ-6 — no existing timeout constant in lib/letflow/ to cite
  # as precedent; a reasonable default for HTTP-call-shaped SERVICE_TASK/plugin
  # latencies.
  @default_timeout_ms 30_000

  @doc """
  Invokes `handler.handle_node/1` with `context`, using `@default_timeout_ms`.
  See `invoke/3`.
  """
  @spec invoke(handler :: module(), context :: ExecutionContext.t()) :: outcome()
  def invoke(handler, %ExecutionContext{} = context) when is_atom(handler) do
    invoke(handler, context, [])
  end

  @doc """
  The single crash-safe entry point every future dispatch call site must use
  to call a handler — never `handler.handle_node(context)` directly.

  Always returns `outcome()` — `{:complete, _}` or `{:error, _}` — and never
  raises, never exits, never times out silently (INV-PR-1). A handler
  returning `{:error, reason}` on purpose, a handler that `raise`s, a handler
  that calls `exit/1` (or is itself killed for any reason), and a handler
  that simply never returns within `opts[:timeout_ms]` are all folded into
  the same `{:error, reason}` shape — `reason` differs, the outcome tag never
  does (AC3).

  Algorithm (design doc §2.4.1):

    1. Start the handler call as a supervised, unlinked task via
       `Task.Supervisor.async_nolink/2` under `Letflow.Engine.PluginTaskSupervisor`
       — deliberately unlinked so a handler crash cannot propagate an `:EXIT`
       signal into the caller's own process at all.
    2. `Task.yield/2`, bounded by `opts[:timeout_ms] || @default_timeout_ms` —
       observes the task's actual termination (return, exit, or timeout), the
       same class of signal `Letflow.SandboxPool`'s own
       `handle_info({:DOWN, ...})` observes for a different purpose.
    3. Branch on `Task.yield/2`'s return (see private clauses below).
  """
  @spec invoke(handler :: module(), context :: ExecutionContext.t(), opts :: invoke_opts()) ::
          outcome()
  def invoke(handler, %ExecutionContext{} = context, opts)
      when is_atom(handler) and is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    # GH #2616 part 2 (decision 0062 R8): a handler never receives a value its caller may not read.
    context = %{
      context
      | variables:
          VariableLabels.redact_map(
            context.variables,
            context.variable_labels,
            context.hidden_labels
          )
    }

    task =
      Task.Supervisor.async_nolink(Letflow.Engine.PluginTaskSupervisor, fn ->
        handler.handle_node(context)
      end)

    task
    |> Task.yield(timeout_ms)
    |> handle_yield_result(task, handler, timeout_ms)
  end

  defp handle_yield_result(
         {:ok, {:complete, output_variables} = outcome},
         _task,
         _handler,
         _timeout_ms
       )
       when is_map(output_variables) do
    outcome
  end

  defp handle_yield_result({:ok, {:error, reason} = outcome}, _task, _handler, _timeout_ms)
       when is_binary(reason) do
    outcome
  end

  defp handle_yield_result({:ok, other}, _task, handler, _timeout_ms) do
    {:error,
     "plugin handler #{inspect(handler)} returned a value outside its outcome() contract: " <>
       inspect(other)}
  end

  defp handle_yield_result({:exit, reason}, _task, handler, _timeout_ms) do
    {:error, "plugin handler #{inspect(handler)} crashed: " <> format_exit_reason(reason)}
  end

  defp handle_yield_result(nil, task, handler, timeout_ms) do
    Task.shutdown(task, :brutal_kill)
    {:error, "plugin handler #{inspect(handler)} did not respond within #{timeout_ms}ms"}
  end

  defp format_exit_reason({exception, stacktrace}) when is_list(stacktrace) do
    Exception.format(:error, exception, stacktrace)
  rescue
    _ -> inspect({exception, stacktrace})
  end

  defp format_exit_reason(reason), do: inspect(reason)

  @doc """
  The pure `outcome() → ExecutionError.error_args()` mapper (AC8, INV-PR-10).
  Given the `ExecutionContext` a handler was invoked with, the `reason`
  string `invoke/2,3` returned on an `{:error, reason}` outcome, and the
  caller's own `actor_id`/`idempotency_key`, returns exactly the
  `error_args()` map REQ-061's `set_instance_error/2` /
  `ExecutionError.append_multi/3` expects. A pure function — no
  `Repo`/`EventStore` call. This is the **only** function this module (or
  `Letflow.Engine.PluginRegistry`) defines that constructs an
  `ExecutionError.error_args()` value.
  """
  @spec build_error_args(
          context :: ExecutionContext.t(),
          reason :: String.t(),
          meta :: error_meta()
        ) :: ExecutionError.error_args()
  def build_error_args(%ExecutionContext{} = context, reason, %{} = meta)
      when is_binary(reason) do
    %{
      instance_id: context.instance_id,
      error_type: :plugin_error_outcome,
      affected: {:node, context.node_id},
      reason: reason,
      variables: context.variables,
      details: %{node_type: context.node_type, trace_id: context.trace_id},
      actor_id: Map.get(meta, :actor_id),
      idempotency_key: Map.fetch!(meta, :idempotency_key)
    }
  end
end
