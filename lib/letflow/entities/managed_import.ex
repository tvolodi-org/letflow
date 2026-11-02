defmodule Letflow.Entities.ManagedImport do
  @moduledoc """
  The core half of the import of a module-managed type (GH #3602 / REQ-651, decision 0077 D5-D7).

  The route (`Letflow.Routers.Entities.RecordImport`) calls `run/8` for a managed type that some
  module registered in `:import_functions` (`Letflow.Modules.Catalog.import_function/2`). The row
  checks are those of `Letflow.Entities.ImportUpsert` (external ref, duplicate ref, field
  restrictions); only the write differs: instead of `Records` the module's own function is called,
  once per row in file order, as `f(prefix, entry, ctx)` through
  `Letflow.Modules.Catalog.call_import_function/5`. **This module holds no Owner** and never builds
  one: the module's function writes through its own owner (0050 D7).

  ## Real import

  Rows run sequentially, each its own transaction inside `Records`, partial success, exactly like
  the generic upsert. A function that raises answers `{:error, :import_function_failed}` for its
  row (rendered `internal_error`); only the exception module is logged (INV-8).

  ## Dry run (D7)

  The whole file runs inside ONE `Repo.transaction` that always ends in a rollback, so a row sees
  the writes of the rows before it (an item can refer to a unit created earlier in the same file)
  and nothing is kept. The Records call path matters here: `DBConnection` ignores
  `mode: :savepoint` inside an outer transaction, and a nested `Records` multi that fails (a
  unique violation, for example) marks the connection aborted, so every later statement of the
  outer transaction would fail. A row refused BEFORE the database (reference, validation,
  restriction, ref errors) does not do that. After every refused row the runner therefore sends a
  probe statement; if the connection is aborted it throws out of the transaction (everything is
  rolled back) and replays the whole file in a fresh transaction with that row's result fixed:
  a fixed row is not called and writes nothing, as in the real import where the failed row's own
  transaction rolled back. Rows before and after it get the results the real import gives. Replays
  are capped at 20 (`@max_replays`); beyond it the dry run is `{:error, :dry_run_unavailable}`
  and nothing was written.

  The function contract: no effects outside `prefix`'s database, in a dry run or not.
  """

  require Logger

  alias Letflow.Entities.ImportUpsert
  alias Letflow.Modules.Catalog
  alias Letflow.Repo

  @max_replays 20

  @doc "The replay cap of a dry run."
  @spec max_replays() :: pos_integer()
  def max_replays, do: @max_replays

  @spec run(
          module_id :: String.t(),
          entries :: [term()],
          entity_type :: String.t(),
          actor_id :: String.t(),
          request_id :: String.t(),
          restricted :: MapSet.t(String.t()),
          prefix :: String.t(),
          dry_run? :: boolean()
        ) :: {:ok, [ImportUpsert.entry_result()]} | {:error, :dry_run_unavailable}
  def run(module_id, entries, entity_type, actor_id, request_id, restricted, prefix, dry_run?) do
    args = {module_id, entries, entity_type, actor_id, request_id, restricted, prefix}

    if dry_run? do
      dry_run(args, %{}, 0)
    else
      {:ok, import_file(args, %{}, false)}
    end
  end

  defp import_file(
         {module_id, entries, entity_type, actor_id, request_id, restricted, prefix},
         forced,
         probe?
       ) do
    counter = :counters.new(1, [])

    writer = fn entry, ctx ->
      :counters.add(counter, 1, 1)
      index = :counters.get(counter, 1)

      case Map.fetch(forced, index) do
        {:ok, result} ->
          result

        :error ->
          result = call(module_id, entity_type, prefix, entry, Map.put(ctx, :dry_run, probe?))

          if probe? and match?({:error, _}, result) and poisoned?(),
            do: throw({:poisoned, index, result})

          result
      end
    end

    ImportUpsert.run(entries, entity_type, actor_id, request_id, restricted, prefix, writer)
  end

  defp dry_run(args, forced, replays) do
    outcome =
      Repo.transaction(fn ->
        try do
          Repo.rollback({:dry_run, import_file(args, forced, true)})
        catch
          {:poisoned, index, result} -> Repo.rollback({:poisoned, index, result})
        end
      end)

    case outcome do
      {:error, {:dry_run, results}} ->
        {:ok, results}

      {:error, {:poisoned, _index, _result}} when replays >= @max_replays ->
        {:error, :dry_run_unavailable}

      {:error, {:poisoned, index, result}} ->
        dry_run(args, Map.put(forced, index, result), replays + 1)
    end
  end

  # One cheap statement: an aborted connection answers an error tuple or raises.
  @doc false
  @spec poisoned?() :: boolean()
  def poisoned? do
    case Repo.query("SELECT 1") do
      {:ok, _} -> false
      _error -> true
    end
  rescue
    _ -> true
  end

  defp call(module_id, entity_type, prefix, entry, ctx) do
    case Catalog.call_import_function(module_id, entity_type, prefix, entry, ctx) do
      {:ok, %{record_id: _, outcome: outcome} = ok}
      when outcome in [:created, :updated, :unchanged] ->
        {:ok, ok}

      {:error, {:external_ref_record_deleted, _ref}} ->
        {:error, :external_ref_record_deleted}

      {:error, _reason} = error ->
        error

      _other ->
        {:error, :import_function_failed}
    end
  rescue
    exception ->
      Logger.warning("managed import function failed: #{inspect(exception.__struct__)}")
      {:error, :import_function_failed}
  end
end
