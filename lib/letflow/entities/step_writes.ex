defmodule Letflow.Entities.StepWrites do
  @moduledoc """
  GH 2587 / REQ-499 PR A3 (decision 0054 D2/D3): the write half of the engine's entity port,
  reached through `Letflow.Entities.EntityPortImpl`. Design
  `lib/letflow/design/gh2587-req499-pr-a-prerequisites.md` section 4.3.

  In PR A3 only `prepare/2` is real. `validate_lines/2` and `multi/3` FAIL CLOSED on any
  non-empty line list so nothing can reach a write before PR B replaces their bodies; nothing
  in the engine calls them yet.

  ## `prepare/2` (0054 D3 step 0)

  Runs ONE short transaction, BEFORE the completion transaction, creating the synthetic
  per-type instance (`EntityTypeInstance.get_or_create/2`) of every distinct line type that has
  an ACTIVE definition, in ascending byte order of the type name. The first two statements are
  the constant `SET LOCAL lock_timeout`/`statement_timeout` (2 s each), so a contended wait is
  bounded; exactly the contention exceptions (lock not available, query canceled, deadlock,
  connection error) map to `{:error, :entity_write_contention}`; any other exception is
  re-raised. It refuses to run inside a caller's transaction, because a `SET LOCAL` there would
  leak into the rest of it.
  """

  alias Letflow.Engine.EntityPort
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Repo

  @prepare_lock_timeout "2s"
  @prepare_statement_timeout "2s"

  # Built at compile time from the two constants above: no runtime interpolation (INV-7).
  @set_lock_timeout "SET LOCAL lock_timeout = '#{@prepare_lock_timeout}'"
  @set_statement_timeout "SET LOCAL statement_timeout = '#{@prepare_statement_timeout}'"

  # Postgres condition codes (as Postgrex names them) that mean "waited too long / lost a race".
  @contention_codes [:lock_not_available, :query_canceled, :deadlock_detected]

  @spec prepare([EntityPort.line()], EntityPort.prepare_ctx()) ::
          :ok
          | {:error, :entity_write_contention}
          | {:error, :prepare_inside_transaction}
          | {:error, {:entity_type_prepare_failed, String.t()}}
  def prepare([], %{prefix: prefix}) when is_binary(prefix), do: :ok

  def prepare(lines, %{prefix: prefix}) when is_list(lines) and is_binary(prefix) do
    if Repo.in_transaction?() do
      {:error, :prepare_inside_transaction}
    else
      types =
        lines
        |> Enum.flat_map(fn
          %{"entity_type" => type} when is_binary(type) -> [type]
          _ -> []
        end)
        |> Enum.uniq()
        |> Enum.sort()

      run_prepare(types, prefix)
    end
  end

  defp run_prepare([], _prefix), do: :ok

  defp run_prepare(types, prefix) do
    result =
      try do
        Repo.transaction(fn ->
          Repo.query!(@set_lock_timeout)
          Repo.query!(@set_statement_timeout)
          Enum.each(types, &ensure_instance(&1, prefix))
        end)
      rescue
        e in Postgrex.Error ->
          if match?(%{postgres: %{code: code}} when code in @contention_codes, e),
            do: {:error, :entity_write_contention},
            else: reraise(e, __STACKTRACE__)

        _e in DBConnection.ConnectionError ->
          {:error, :entity_write_contention}
      end

    case result do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_instance(type, prefix) do
    case Definitions.get_active_definition_by_name(type, prefix) do
      {:ok, _definition} ->
        case EntityTypeInstance.get_or_create(type, prefix) do
          {:ok, _instance_id} -> :ok
          {:error, _} -> Repo.rollback({:entity_type_prepare_failed, type})
        end

      # No active definition: skip (D-A3.2); `command_multi/3` refuses the line later.
      {:error, _not_found} ->
        :ok
    end
  end

  @spec validate_lines([EntityPort.line()], EntityPort.definition_ctx()) ::
          :ok | {:error, [EntityPort.line_violation()]}
  def validate_lines([], _ctx), do: :ok

  def validate_lines(lines, _ctx) when is_list(lines) do
    {:error,
     lines
     |> Enum.with_index()
     |> Enum.map(fn {_line, index} -> %{index: index, code: :entity_writes_not_enabled} end)}
  end

  @spec multi(Ecto.Multi.t(), [EntityPort.line()], EntityPort.multi_ctx()) :: Ecto.Multi.t()
  def multi(%Ecto.Multi{} = multi, [], _ctx), do: multi

  def multi(%Ecto.Multi{} = multi, lines, _ctx) when is_list(lines) do
    Ecto.Multi.error(multi, {:line, 0, :build}, :entity_writes_not_enabled)
  end
end
