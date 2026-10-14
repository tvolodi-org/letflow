defmodule Letflow.Engine.ScriptTaskDispatcher.Poller do
  @moduledoc """
  GH 2534 PR 7c-1 (design `lib/letflow/design/gh2534-7c-script-handler.md` 5.1, C2): the
  supervised `GenServer` ticker of the script SERVICE_TASK route, separate from the HTTP
  poller so a script run (<= 7 s with the caller margin) never delays HTTP dispatch and vice
  versa. Same shape as `Letflow.Engine.ServiceTaskDispatcher.Poller`: a zero-delay first tick;
  per tick it lists the provisioned tenant schemas and calls
  `Letflow.Engine.ScriptTaskDispatcher.run_tick/2`.

  This process IS "the dispatcher" whose death the 7a watchdog observes: every script run is
  called from it, so a killed poller kills the worker and releases the admission slot, and
  the row's lease expiry then turns it into an incident (never a re-run).

  Its state holds only the round-robin offset. Child of `Letflow.Supervisor.Pollers`, gated by
  `:start_script_task_dispatcher` (false in `config/test.exs`, same OwnershipError hazard as
  the other pollers). It cannot start before the event types it appends exist: Pollers starts
  after `Letflow.Supervisor.Infrastructure`, whose `MigrationReplayBoot` child seeds every
  existing tenant synchronously (design 0.12, CDV C10).
  """

  use GenServer

  import Ecto.Query

  alias Letflow.Engine.ScriptTaskDispatcher
  alias Letflow.Repo
  alias Letflow.TenantProvisioning.Registration

  @type state :: non_neg_integer()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, 0, name: __MODULE__)
  end

  @impl true
  def init(offset) do
    Process.send_after(self(), :tick, 0)
    {:ok, offset}
  end

  @impl true
  def handle_info(:tick, offset) do
    next_offset =
      case fetch_tenant_schemas() do
        {:ok, schemas} ->
          {_summary, next} = ScriptTaskDispatcher.run_tick(schemas, offset)
          next

        :error ->
          offset
      end

    Process.send_after(self(), :tick, ScriptTaskDispatcher.config(:poll_interval_ms))
    {:noreply, next_offset}
  end

  # A fully unreachable database must not crash this GenServer.
  defp fetch_tenant_schemas do
    schemas =
      Registration
      |> where([r], not is_nil(r.migrations_applied_at))
      |> order_by([r], asc: r.schema_name)
      |> select([r], r.schema_name)
      |> Repo.all()

    {:ok, schemas}
  rescue
    _error -> :error
  end
end
