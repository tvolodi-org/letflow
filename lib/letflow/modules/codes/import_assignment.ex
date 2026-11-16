defmodule Letflow.Modules.Codes.ImportAssignment do
  @moduledoc """
  The import function of `code_assignment` (G12 part 2, GH #4568 / REQ-851, manifest `:import_functions`):
  one row of a file, called by the core through `Letflow.Modules.Catalog.call_import_function/5` as
  `row(prefix, entry, ctx)`. Route: `POST /api/v1/entities/records/code_assignment/import`; access is the
  core rule (TENANT_ADMIN imports, a STOREKEEPER is refused).

  A row has the cells `code_id`, `target_type`, `target_id` and the external ref pair. `code_id` holds the
  VALUE of a code of this tenant (a code has no external id); `target_id` holds the external id of the
  target under the row's OWN external ref system, resolved with `Letflow.Modules.ReadApi`
  (`lookup_by_external_ref/5`, `prefix` is the only tenant datum). The ref pair is only the row key.

  Per row, in this order (the first refusal wins, a refused row writes nothing):

    1. a cell `assigned_at`, `assigned_by`, `released_at` or `released_by` is `{:field_not_allowed, field}`
       (the server sets them, as `assign_code/5` does); any other foreign column is `:field_not_allowed`;
    2. `target_type` must be `location_node`, `catalog_item` or `catalog_lot`, else `:target_type_not_allowed`;
    3. no live code with that value is `{:reference_not_found, "code_id"}`;
    4. no live target of that type with that external id is `{:reference_not_found, "target_id"}`
       (a record id is not an external id); an inactive target is `{:reference_inactive, "target_id"}`;
    5. a retired code is `:code_retired`; a code whose open assignment names this same target is
       `:unchanged` (nothing written); one whose open assignment names another record is `:code_assigned`;
    6. otherwise `Letflow.Modules.Codes.assign_code/5` assigns it (one open `code_assignment`, status
       `assigned`, one `code.assigned` audit entry, same transaction, same advisory lock).

  No release, retire or value change by import. Refusal atoms are constants (rendered by the core
  without cell text). `ctx.dry_run` is accepted and unused: the core owns the rollback.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.ExternalRef
  alias Letflow.Entities.ImportRow
  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.Codes
  alias Letflow.Modules.ReadApi
  alias Letflow.Repo

  @targets ~w(location_node catalog_item catalog_lot)
  @server_set ~w(assigned_at assigned_by released_at released_by)
  @importable ~w(code_id target_type target_id)
  @ignored ~w(external_ref_system external_ref_id)

  @spec row(prefix :: String.t(), entry :: map(), ctx :: map()) ::
          {:ok, %{record_id: Ecto.UUID.t(), outcome: :created | :unchanged}} | {:error, term()}
  def row(
        prefix,
        %{entity_type: "code_assignment", external_ref: %ExternalRef{} = ref} = entry,
        ctx
      )
      when is_binary(prefix) do
    cells = entry.field_values |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
    type = Map.get(cells, "target_type")

    with :ok <- check_cells(cells),
         :ok <- check_type(type),
         {:ok, tag} <- find_code(prefix, Map.get(cells, "code_id")),
         {:ok, target_id} <- find_target(prefix, type, ref.system, Map.get(cells, "target_id")) do
      persist(prefix, tag, type, target_id, ctx)
    end
  end

  defp check_cells(cells) do
    case Enum.find(@server_set, &Map.has_key?(cells, &1)) do
      nil -> ImportRow.check_cells(cells, @importable, @ignored)
      field -> {:error, {:field_not_allowed, field}}
    end
  end

  defp check_type(type) when type in @targets, do: :ok
  defp check_type(_type), do: {:error, :target_type_not_allowed}

  defp find_code(prefix, value) do
    with true <- is_binary(value) and value != "" and String.valid?(value),
         false <- String.contains?(value, <<0>>),
         %Latest{} = tag <- tag_by_value(prefix, value) do
      {:ok, tag}
    else
      _ -> {:error, {:reference_not_found, "code_id"}}
    end
  end

  defp tag_by_value(prefix, value) do
    Repo.one(
      from(l in Latest,
        where:
          l.entity_type == "code_tag" and l.deleted == false and
            fragment("?->>'value' = ?", l.field_values, ^value),
        limit: 1
      ),
      prefix: prefix
    )
  end

  defp find_target(prefix, type, system, cell) do
    with true <- is_binary(cell) and cell != "",
         {:ok, target} <- ReadApi.lookup_by_external_ref(prefix, type, system, cell, [type]) do
      if target["active"] == true,
        do: {:ok, target["record_id"]},
        else: {:error, {:reference_inactive, "target_id"}}
    else
      _ -> {:error, {:reference_not_found, "target_id"}}
    end
  end

  # One transaction under the codes advisory lock (the one `Writes` takes, re-entrant for the same
  # connection), so the open-assignment check and the write are one step.
  defp persist(prefix, tag, type, target_id, ctx) do
    result =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [prefix <> ":codes"])
        decide(prefix, tag, type, target_id, ctx)
      end)

    case result do
      {:ok, inner} -> inner
      {:error, {:error, _} = err} -> err
      {:error, other} -> {:error, other}
    end
  end

  defp decide(prefix, tag, type, target_id, ctx) do
    code_id = tag.record_id

    case {Map.get(tag.field_values, "status"), open(prefix, code_id)} do
      {"retired", _} ->
        {:error, :code_retired}

      {_, [%{"target_type" => ^type, "target_id" => ^target_id, "assignment_id" => aid}]} ->
        {:ok, %{record_id: aid, outcome: :unchanged}}

      {_, [_ | _]} ->
        {:error, :code_assigned}

      {_, []} ->
        opts = %{actor_id: ctx.actor_id, idempotency_key: ctx.idempotency_key}

        case Codes.assign_code(prefix, code_id, type, target_id, opts) do
          {:ok, %{"assignment_id" => aid}} -> {:ok, %{record_id: aid, outcome: :created}}
          {:error, reason} -> Repo.rollback({:error, reason})
        end
    end
  end

  defp open(prefix, code_id) do
    prefix |> Codes.assignment_history(code_id) |> Enum.filter(&is_nil(&1["released_at"]))
  end
end
