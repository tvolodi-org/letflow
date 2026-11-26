defmodule Letflow.Instances.StepRetry do
  @moduledoc """
  The RETRY of a failed step of an instance (pilot gap G7 of the "Register a
  tenant" pilot -- owner item 7: "step failures visible and retryable").

  A step that failed leaves two things behind: the instance is in ERROR and
  the step's own row carries the failure. This module finds that step and
  runs it AGAIN -- once, deliberately, at an operator's request.

  ## What a retry is allowed to touch

  Only the two step kinds the pilot has, and only the step that failed:

    * a PLATFORM step (a call of the compiled catalogue) -- the retry re-arms
      the step's own dispatch row and runs the call again
      (`Letflow.PlatformFunctions.Dispatcher.retry_failed_step/2`);
    * a NOTIFICATION step (a registered template) -- the retry sends the
      template again, but only when the step did not already do its work
      (`Letflow.NotificationSteps.Dispatcher.retry/3`).

  A step of any other kind (a human task, a timer, an HTTP service task) is
  refused with `step_kind_unknown`: this slice retries what the pilot's step
  library can re-run, and it does not guess.

  ## The idempotency of a retry

  "A retry of a step that already did its work changes NOTHING" (owner item 7).

    * a platform step whose row already RAN (`advanced`) is not run again: the
      stored outputs are returned and the answer is `already_final`;
    * a notification step whose delivery already SUCCEEDED (a mail that was
      sent, a file that was written) is not sent again: the answer is
      `already_done`.

  The platform functions are idempotent by contract (gap G1), so re-running a
  failed one is safe: the same call key returns the first result and writes
  nothing a second time.

  ## The tenant of every read and write (INV-1)

  Every function takes `opts :: [prefix: String.t()]`, the tenant schema the
  instance and its step live in. The instance of another tenant is invisible
  here: its dispatch row is in another schema and its events are read from
  this one.

  ## What it never does

  It never raises: every failure is an error tuple (INV-8). A platform
  step that ran again hands its outputs to the engine
  (`Letflow.Engine.apply_platform_step_result/3`), which merges them, lifts the
  instance's ERROR and continues it off the node exactly once (T-2703); the
  engine owns every write of the instance itself.
  """

  import Ecto.Query

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.NotifyCalls
  alias Letflow.Definitions.SnapshotStore
  alias Letflow.Dlq.Entry
  alias Letflow.Engine
  alias Letflow.Engine.NotifyStepRunner
  alias Letflow.Engine.Reconstruction
  alias Letflow.EventStore
  alias Letflow.NotificationSteps.Dispatcher, as: NotifyDispatcher
  alias Letflow.PlatformFunctions.Dispatcher
  alias Letflow.PlatformFunctions.Dispatcher.StepDispatch
  alias Letflow.Repo

  @typedoc "The options every function here takes: the tenant `:prefix` (INV-1)."
  @type opts :: [prefix: String.t()]

  @typedoc """
  The step that failed. `kind` is the step's kind (`:platform` or `:notify`).
  """
  @type failed_step :: %{
          required(:instance_id) => Ecto.UUID.t(),
          required(:node_id) => String.t(),
          required(:kind) => :platform | :notify,
          optional(:dispatch_id) => Ecto.UUID.t(),
          optional(:declaration) => map()
        }

  @typedoc "The outcome of a retry."
  @type retry_result :: %{
          required(:kind) => :platform | :notify,
          required(:node_id) => String.t(),
          required(:status) => String.t(),
          optional(:outputs) => map() | nil,
          optional(:reason) => String.t() | nil
        }

  # The DLQ entry types a step failure lands under. The names are exported
  # (`platform_step_entry_type/0`, `notify_step_entry_type/0`) so the slice
  # that RUNS a step and lands its DLQ entry uses the same names this retry
  # listens to.
  @platform_step_entry_type "platform_step"
  @notify_step_entry_type "notify_step"

  @doc "The DLQ entry type of a failed platform step."
  @spec platform_step_entry_type() :: String.t()
  def platform_step_entry_type, do: @platform_step_entry_type

  @doc "The DLQ entry type of a failed notification step."
  @spec notify_step_entry_type() :: String.t()
  def notify_step_entry_type, do: @notify_step_entry_type

  @doc """
  The DLQ entry types a retry answers to -- the two step kinds of the pilot.
  An entry of any other type is not a step failure: its retry is the plain
  state transition of the row (the DLQ's own `retry/2`).
  """
  @spec retryable_entry_types() :: [String.t()]
  def retryable_entry_types, do: [@platform_step_entry_type, @notify_step_entry_type]

  @doc """
  Whether this DLQ entry names a step this module can retry.
  """
  @spec retryable_entry_type?(String.t() | nil) :: boolean()
  def retryable_entry_type?(entry_type) when is_binary(entry_type),
    do: entry_type in retryable_entry_types()

  def retryable_entry_type?(_other), do: false

  @doc """
  The failed step of an instance: the platform step whose row carries the
  failure, or -- when the instance has no failed platform step -- the node of
  its last `EXECUTION_ERROR` when that node is a notification step.

  `{:error, :no_failed_step}` when the instance has no failed step at all.
  """
  @spec failed_step(Ecto.UUID.t(), opts()) :: {:ok, failed_step()} | {:error, term()}
  def failed_step(instance_id, opts) when is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, id} <- cast_instance_id(instance_id) do
      case failed_platform_dispatch(id, prefix) do
        {:ok, row} ->
          {:ok,
           %{
             instance_id: id,
             node_id: row.node_id,
             kind: :platform,
             dispatch_id: row.id
           }}

        {:error, :not_found} ->
          failed_notify_step(id, prefix)
      end
    end
  end

  @doc """
  Retries the failed step of an instance: the step is run again, once.

  `{:ok, result}` carries the OUTCOME of the step: `advanced` (a platform
  call returned its outputs), `already_final` (the step had already run -- the
  retry changed nothing), `already_done` (a notification step had already
  sent), or the delivery status of a notification step. `{:error, reason}`
  when the step could not be retried at all.
  """
  @spec retry_step(Ecto.UUID.t(), opts()) :: {:ok, retry_result()} | {:error, term()}
  def retry_step(instance_id, opts) when is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, step} <- failed_step(instance_id, opts) do
      retry_failed(step, prefix)
    end
  end

  @doc """
  Retries the step a DLQ entry names: the entry's `instance_id` and
  `reference_id` (the node) say which step failed.

  This is the wiring of the DLQ's own `retry/2` (pilot gap G7: "Dlq.retry/2 is
  wired to it for these entry types"). An entry of another type is refused
  with `step_kind_unknown` -- its retry is the plain state transition of the
  row.
  """
  @spec retry_entry(Entry.t(), opts()) :: {:ok, retry_result()} | {:error, term()}
  def retry_entry(%Entry{} = entry, opts) when is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    case entry.entry_type do
      @platform_step_entry_type -> retry_platform_entry(entry, prefix)
      @notify_step_entry_type -> retry_notify_entry(entry, prefix)
      _other -> {:error, :step_kind_unknown}
    end
  end

  # ── the platform step ───────────────────────────────────────────────────────

  # The retry of the step that failed, by its kind.
  defp retry_failed(%{kind: :platform, dispatch_id: dispatch_id, node_id: node_id}, prefix) do
    with {:ok, row} <- fetch_dispatch_by_id(dispatch_id, prefix) do
      run_platform(row, node_id, prefix)
    end
  end

  defp retry_failed(%{kind: :notify, node_id: node_id, declaration: declaration} = step, prefix) do
    run_notify(step.instance_id, node_id, declaration, prefix)
  end

  # The entry names the instance and the node: the step's own dispatch row is
  # looked up in THIS tenant's schema (INV-1), so an entry of another tenant
  # names a step that does not exist here.
  defp retry_platform_entry(entry, prefix) do
    with {:ok, instance_id} <- cast_instance_id(entry.instance_id),
         {:ok, node_id} <- cast_node_id(entry.reference_id),
         {:ok, row} <- fetch_dispatch(instance_id, node_id, prefix) do
      run_platform(row, node_id, prefix)
    end
  end

  defp run_platform(row, node_id, prefix) do
    case Dispatcher.retry_failed_step(row.id, prefix) do
      {:ok, %{status: :advanced, outputs: outputs}} ->
        with :ok <- resume_instance(row, prefix) do
          {:ok, %{kind: :platform, node_id: node_id, status: "advanced", outputs: outputs}}
        end

      {:ok, %{status: :already_final, outputs: outputs}} ->
        with :ok <- resume_instance(row, prefix) do
          {:ok,
           %{
             kind: :platform,
             node_id: node_id,
             status: "already_final",
             outputs: outputs,
             reason: nil
           }}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # T-2703: the step ran, so the instance CONTINUES off its node (the engine's apply merges the
  # outputs and lifts the ERROR). The apply's completion key is the dispatch id, so a retry that
  # finds the work done resumes nothing a second time (`:already_final`).
  defp resume_instance(row, prefix) do
    case Engine.apply_platform_step_result(row.id, prefix, resume: true) do
      {:ok, _outcome} -> :ok
      # A row with no instance behind it (armed by a caller that is not the engine) has nothing to
      # resume: the step's own outcome is the whole answer.
      {:error, :instance_not_found} -> :ok
      {:error, reason} -> {:error, resume_code(reason)}
    end
  end

  # The code is a closed atom, never a term that could carry tenant data (INV-4).
  defp resume_code(:platform_step_not_found), do: :platform_step_not_found

  defp resume_code({:instance_not_active, _status}), do: :instance_not_active
  defp resume_code(_reason), do: :platform_step_resume_failed

  # The dispatch row of the step: the most recent one of that node. The call
  # key is unique per call, so a node visited twice with other arguments has
  # two rows, and the most recent one is the step that failed.
  defp fetch_dispatch_by_id(dispatch_id, prefix) do
    case Repo.get(StepDispatch, dispatch_id, prefix: prefix) do
      nil -> {:error, :step_not_found}
      %StepDispatch{} = row -> {:ok, row}
    end
  rescue
    _exception -> {:error, :step_not_found}
  end

  defp fetch_dispatch(instance_id, node_id, prefix) do
    query =
      StepDispatch
      |> where(
        [d],
        d.instance_id == ^instance_id and d.node_id == ^node_id and
          d.function_name != ^NotifyStepRunner.function_name()
      )
      |> order_by([d], desc: d.created_at, desc: d.id)
      |> limit(1)

    case Repo.one(query, prefix: prefix) do
      nil -> {:error, :step_not_found}
      %StepDispatch{} = row -> {:ok, row}
    end
  rescue
    # A tenant schema that has no dispatch table at all (it was provisioned
    # before the newest migration) cannot hold the step: the answer is the
    # same as for a step that does not exist (INV-8: no raw database error).
    _exception -> {:error, :step_not_found}
  end

  # The failed platform step of an instance: the most recent row that carries
  # a failure (`given_up`).
  defp failed_platform_dispatch(instance_id, prefix) do
    query =
      StepDispatch
      |> where(
        [d],
        d.instance_id == ^instance_id and d.status == :given_up and
          d.function_name != ^NotifyStepRunner.function_name()
      )
      |> order_by([d], desc: d.created_at, desc: d.id)
      |> limit(1)

    case Repo.one(query, prefix: prefix) do
      nil -> {:error, :not_found}
      %StepDispatch{} = row -> {:ok, row}
    end
  rescue
    _exception -> {:error, :not_found}
  end

  # ── the notification step ───────────────────────────────────────────────────

  defp retry_notify_entry(entry, prefix) do
    with {:ok, instance_id} <- cast_instance_id(entry.instance_id),
         {:ok, node_id} <- cast_node_id(entry.reference_id) do
      case notify_declaration(instance_id, node_id, prefix) do
        {:ok, declaration} -> run_notify(instance_id, node_id, declaration, prefix)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # The failed notification step of an instance: the node of its last
  # `EXECUTION_ERROR`, when that node is a notification step.
  defp failed_notify_step(instance_id, prefix) do
    with {:ok, node_id} <- failed_node(instance_id, prefix),
         {:ok, declaration} <- notify_declaration(instance_id, node_id, prefix) do
      {:ok,
       %{
         instance_id: instance_id,
         node_id: node_id,
         kind: :notify,
         declaration: declaration
       }}
    end
  end

  # T-2810: a step the ENGINE ran has its own row; its retry re-runs that row and resumes the
  # instance. A step with no row (run by a caller outside the engine) is sent directly.
  defp run_notify(instance_id, node_id, declaration, prefix) do
    case NotifyStepRunner.fetch_row(instance_id, node_id, prefix) do
      %StepDispatch{} = row ->
        case NotifyStepRunner.retry(row, prefix) do
          {:ok, %{status: status, reason: reason}} ->
            {:ok, %{kind: :notify, node_id: node_id, status: status, reason: reason}}

          {:error, code} ->
            {:error, code}
        end

      nil ->
        run_notify_direct(instance_id, node_id, declaration, prefix)
    end
  end

  defp run_notify_direct(instance_id, node_id, declaration, prefix) do
    with {:ok, state} <- instance_state(instance_id, prefix) do
      case NotifyDispatcher.retry(declaration, state.variables,
             prefix: prefix,
             trigger_ref: instance_id,
             labels: state.variable_labels
           ) do
        {:ok, %{status: status, reason: reason}} ->
          {:ok, %{kind: :notify, node_id: node_id, status: status, reason: reason}}

        {:error, code} ->
          {:error, code}
      end
    end
  end

  # The node of the instance's last `EXECUTION_ERROR`: the step the engine was
  # in when it failed.
  defp failed_node(instance_id, prefix) do
    case EventStore.read(instance_id, prefix: prefix) do
      {:ok, events} ->
        node_id =
          events
          |> Enum.reverse()
          |> Enum.find_value(fn event -> error_node(event) end)

        if is_binary(node_id), do: {:ok, node_id}, else: {:error, :no_failed_step}

      {:error, _reason} ->
        {:error, :no_failed_step}
    end
  end

  # The engine names the affected resource under `affected`
  # (`{"kind": "node", "node_id": ...}`), not in a top-level `node_id`
  # (`Letflow.Engine.ExecutionError`).
  defp error_node(%{event_type: "EXECUTION_ERROR", payload: payload}) when is_map(payload) do
    case Map.get(payload, "affected") do
      %{"kind" => "node", "node_id" => node_id} when is_binary(node_id) -> node_id
      _other -> nil
    end
  end

  defp error_node(_event), do: nil

  # The `notify` declaration of the node, read out of the instance's OWN
  # definition snapshot -- the graph the instance runs, not the definition's
  # current version.
  @doc false
  @spec notify_declaration(Ecto.UUID.t(), String.t(), String.t()) ::
          {:ok, term()} | {:error, atom()}
  def notify_declaration(instance_id, node_id, prefix) do
    with {:ok, snapshot} <- SnapshotStore.get_by_instance_id(instance_id, prefix: prefix),
         {:ok, nodes} <- graph_nodes(snapshot.graph),
         {:ok, node} <- fetch_node(nodes, node_id),
         {:ok, raw} <- node_notify(node),
         {:ok, _declaration} <- NotifyCalls.parse(raw) do
      {:ok, raw}
    else
      {:error, :snapshot_not_found} -> {:error, :step_not_found}
      {:error, :node_not_found} -> {:error, :step_not_found}
      {:error, :notify_malformed} -> {:error, :notify_malformed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp graph_nodes(graph) when is_map(graph) do
    case Graph.from_map(graph) do
      {:ok, %Graph{nodes: nodes}} -> {:ok, nodes}
      _not_a_graph -> {:error, :step_not_found}
    end
  end

  defp graph_nodes(_other), do: {:error, :step_not_found}

  defp fetch_node(nodes, node_id) do
    case Enum.find(nodes, &(&1.id == node_id)) do
      nil -> {:error, :node_not_found}
      node -> {:ok, node}
    end
  end

  defp node_notify(%Graph.Node{attributes: attributes}) when is_map(attributes) do
    case Map.get(attributes, "notify") do
      nil -> {:error, :node_not_found}
      raw -> {:ok, raw}
    end
  end

  defp node_notify(_node), do: {:error, :node_not_found}

  # The instance's own state (its variables and its variable labels), rebuilt
  # from its event log. The labels matter: a notification step refuses a
  # value the engine marked as sensitive, so a retry that cannot see the
  # labels cannot refuse it either -- the step is refused instead.
  defp instance_state(instance_id, prefix) do
    case Reconstruction.reconstruct_instance(instance_id, prefix: prefix) do
      {:ok, %{instance_state: state}} -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── the guards ──────────────────────────────────────────────────────────────

  defp cast_instance_id(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_instance_id}
    end
  end

  defp cast_instance_id(_other), do: {:error, :invalid_instance_id}

  # The node id is a caller-supplied string that goes into a `varchar(255)`
  # column: it is byte-bounded before it is compared (SF-01).
  defp cast_node_id(value) when is_binary(value) do
    if byte_size(value) <= 255 do
      {:ok, value}
    else
      {:error, :step_not_found}
    end
  end

  defp cast_node_id(_other), do: {:error, :step_not_found}
end
