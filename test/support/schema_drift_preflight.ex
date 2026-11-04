defmodule Letflow.Test.SchemaDriftPreflight do
  @moduledoc """
  GH #2498: fail-fast probe for a test database that drifted from the schemas.

  A migration edited in place after it ran locally leaves the database without the new
  column while `mix ecto.migrate` sees nothing pending, and the failure then shows up
  as unrelated 500s in other suites. This compares, for every Ecto schema of the app whose
  table exists in the `public` schema, the schema's persisted fields with the live
  columns, and reports the missing ones with the reset instruction.
  """

  @reset_hint "run `MIX_ENV=test mix ecto.reset` (or drop and recreate the test database) and retry"

  @spec drift(module()) :: [{module(), String.t(), [String.t()]}]
  def drift(repo) do
    live = live_columns(repo)

    for mod <- schema_modules(),
        table = mod.__schema__(:source),
        is_binary(table),
        cols = Map.get(live, table),
        cols != nil,
        missing =
          mod.__schema__(:fields)
          |> Enum.filter(&(mod.__schema__(:type, &1) != :virtual))
          |> Enum.map(&to_string(mod.__schema__(:field_source, &1)))
          |> Enum.reject(&(&1 in cols)),
        missing != [] do
      {mod, table, missing}
    end
  end

  @doc "Raises with a fixed instruction when `drift/1` finds anything."
  @spec check!(module()) :: :ok
  def check!(repo) do
    case drift(repo) do
      [] ->
        :ok

      found ->
        lines =
          Enum.map_join(found, "\n", fn {m, t, cols} ->
            "  #{inspect(m)} (public.#{t}): missing columns #{Enum.join(cols, ", ")}"
          end)

        raise "test database schema drift detected:\n#{lines}\n#{@reset_hint}"
    end
  end

  defp live_columns(repo) do
    %{rows: rows} =
      repo.query!(
        "SELECT table_name, column_name FROM information_schema.columns WHERE table_schema = 'public'"
      )

    Enum.reduce(rows, %{}, fn [t, c], acc -> Map.update(acc, t, [c], &[c | &1]) end)
  end

  defp schema_modules do
    {:ok, mods} = :application.get_key(:letflow, :modules)

    Enum.filter(mods, fn m ->
      Code.ensure_loaded?(m) and function_exported?(m, :__schema__, 1) and
        m.__schema__(:source) != nil
    end)
  end
end
