defmodule Letflow.Entities.ImportRow do
  @moduledoc """
  The row checks the master-data imports share (core extraction slice S3): one row of an import
  file reaches a module's `import_*` function as a map of cells, and every module refuses the
  same shapes in the same order before it writes anything. The four copies
  (`Letflow.Modules.Assets.Import`, `Locations.Import`, `Org.Import`,
  `CatalogItems.LotImport`) now call this module.

  Pure apart from `transact/1`, which is a plain `Repo.transaction` wrapper with no tenant prefix
  of its own (the caller's writes carry theirs). The module reads no tenant data. The error term
  of a missing cell is the caller's: assets `{:asset_field_required, header}`, locations, org and
  catalog lots `{:field_invalid, header}`. Cell text never goes into an error tuple.
  """

  alias Letflow.Repo

  @doc """
  The first key of `attrs` (sorted) that is not in `allowed`: `{:error, {:field_not_allowed, key}}`,
  else `:ok`. One check for the module write paths (create/update key lists).
  """
  @spec check_keys(map(), [String.t()]) :: :ok | {:error, {:field_not_allowed, String.t()}}
  def check_keys(attrs, allowed) do
    case attrs |> Map.keys() |> Enum.reject(&(&1 in allowed)) |> Enum.sort() do
      [] -> :ok
      [key | _] -> {:error, {:field_not_allowed, key}}
    end
  end

  @doc "True for a binary with something other than whitespace in it."
  @spec text?(term()) :: boolean()
  def text?(v), do: is_binary(v) and String.trim(v) != ""

  @doc """
  Refuses a retired-flag column and any column outside `importable` and `ignored`:
  `{:error, {:field_not_allowed, "active"}}` first, then `{:error, :field_not_allowed}`.
  """
  @spec check_cells(map(), [String.t()], [String.t()]) ::
          :ok | {:error, {:field_not_allowed, String.t()} | :field_not_allowed}
  def check_cells(cells, importable, ignored) do
    keys = Map.keys(cells)

    cond do
      "active" in keys ->
        {:error, {:field_not_allowed, "active"}}

      Enum.any?(keys, &(&1 not in importable and &1 not in ignored)) ->
        {:error, :field_not_allowed}

      true ->
        :ok
    end
  end

  @doc """
  The first header of `required` (in list order) whose cell is not non-blank text becomes
  `error_fun.(header)`; `:ok` when all are present.
  """
  @spec check_required(map(), [String.t()], (String.t() -> term())) :: :ok | {:error, term()}
  def check_required(cells, required, error_fun) when is_function(error_fun, 1) do
    case Enum.find(required, &(not text?(Map.get(cells, &1)))) do
      nil -> :ok
      header -> {:error, error_fun.(header)}
    end
  end

  @doc """
  Runs `fun` in a transaction: `{:ok, result}` commits and returns `{:ok, result}`;
  `{:error, reason}` rolls back and returns `{:error, reason}`.
  """
  @spec transact((-> {:ok, term()} | {:error, term()})) :: {:ok, term()} | {:error, term()}
  def transact(fun) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end
end
