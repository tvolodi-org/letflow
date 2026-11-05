defmodule Letflow.Entities.ScopeDeclarations do
  @moduledoc """
  The tenant-owned scope declarations -- REQ-635 / GH #3549, decision 0070 D3 (slice B, Q1
  option (a): a core table set by a tenant-wide TENANT_ADMIN).

  A row in `entity_scope_declarations` says how a scoped caller's read of a tenant-owned entity
  type is filtered: `tenant_wide`, or `column` on a field that an active constraint promotes to an
  indexed column. `Letflow.Entities.ScopeDeclaration` reads it as its third source, only for a
  type that no module manifest names and no module manages. This module is the writer.

  No function takes a tenant id: the tenant is the schema `prefix` (INV-1). One row per type; a
  second PUT replaces it. A write is one transaction with an advisory lock, the upsert and the
  audit entry, so a failed audit leaves the old row.
  """

  import Ecto.Query

  require Logger

  alias Ecto.Multi
  alias Letflow.Audit
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.ScopeDeclaration
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @kinds ["column", "tenant_wide"]

  @type actor :: %{
          optional(:user_id) => String.t() | nil,
          optional(:trace_id) => String.t() | nil
        }

  @doc """
  Sets (or replaces) the declaration of `attrs["entity_type"]`. Checks, in order and before any
  write: shape (`:invalid_input`), managed type (`:entity_type_managed`), no active definition
  (`:not_found`), a `column` field named in a constraint of the active definition
  (`:invalid_input`).
  """
  @spec put_audited(map(), actor(), prefix :: String.t()) :: {:ok, map()} | {:error, term()}
  def put_audited(attrs, actor, prefix)
      when is_map(attrs) and is_map(actor) and is_binary(prefix) do
    with {:ok, _tenant_id} <- tenant_id(prefix),
         {:ok, type, kind, field} <- check_shape(attrs),
         :ok <- check_not_managed(type, prefix),
         {:ok, definition} <- check_exists(type, prefix),
         :ok <- check_field(kind, field, definition) do
      write(type, kind, field, actor, prefix)
    end
  end

  @doc "All declarations of the tenant, ordered by entity type."
  @spec list(prefix :: String.t()) :: [map()]
  def list(prefix) when is_binary(prefix) do
    case tenant_id(prefix) do
      {:ok, _} ->
        from(r in "entity_scope_declarations",
          order_by: r.entity_type,
          select: %{
            "entity_type" => r.entity_type,
            "kind" => r.kind,
            "field" => r.field,
            "set_at" => r.updated_at
          }
        )
        |> Repo.all(prefix: prefix)

      _ ->
        []
    end
  end

  @doc """
  `%{entity_type => {kind, field}}` for the requested types that have a row: one query, names
  bound as a typed array parameter (INV-7).
  """
  @spec for_types_rows([String.t()], prefix :: String.t()) :: %{
          String.t() => {String.t(), String.t() | nil}
        }
  def for_types_rows([], _prefix), do: %{}

  def for_types_rows(types, prefix) when is_list(types) and is_binary(prefix) do
    from(r in "entity_scope_declarations",
      where: r.entity_type in type(^types, {:array, :string}),
      select: {r.entity_type, r.kind, r.field}
    )
    |> Repo.all(prefix: prefix)
    |> Map.new(fn {type, kind, field} -> {type, {kind, field}} end)
  end

  # --- checks ---------------------------------------------------------------------------

  defp tenant_id(prefix) do
    case TenantProvisioning.tenant_id_for_schema_name(prefix) do
      {:ok, id} -> {:ok, id}
      {:error, :invalid_schema_name} -> {:error, :not_found}
    end
  end

  defp check_shape(attrs) do
    type = Map.get(attrs, "entity_type")
    kind = Map.get(attrs, "kind")
    field = Map.get(attrs, "field")

    cond do
      not ManagedTypes.managed_name?(type) -> {:error, :invalid_input}
      kind not in @kinds -> {:error, :invalid_input}
      kind == "tenant_wide" and not is_nil(field) -> {:error, :invalid_input}
      kind == "column" and not ManagedTypes.managed_name?(field) -> {:error, :invalid_input}
      true -> {:ok, type, kind, field}
    end
  end

  defp check_not_managed(type, prefix) do
    case ManagedTypes.owner_of(type, prefix) do
      :unmanaged ->
        if ScopeDeclaration.manifest_named?(type), do: {:error, :entity_type_managed}, else: :ok

      _managed_or_error ->
        {:error, :entity_type_managed}
    end
  end

  defp check_exists(type, prefix) do
    case Definitions.get_active_definition_by_name(type, prefix) do
      {:ok, definition} -> {:ok, definition}
      _ -> {:error, :not_found}
    end
  end

  defp check_field("tenant_wide", _field, _definition), do: :ok

  defp check_field("column", field, %{definition_json: json}) do
    constrained? =
      json
      |> Map.get("constraints", [])
      |> Enum.any?(fn
        %{"fields" => fields} when is_list(fields) -> field in fields
        _ -> false
      end)

    if constrained?, do: :ok, else: {:error, :invalid_input}
  end

  # --- write ----------------------------------------------------------------------------

  defp write(type, kind, field, actor, prefix) do
    user_id = Map.get(actor, :user_id)

    Multi.new()
    |> Multi.run(:lock, fn _repo, _changes ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
        prefix <> ":entity_scope_declarations:" <> type
      ])

      {:ok, :locked}
    end)
    |> Multi.run(:current, fn repo, _changes ->
      {:ok,
       repo.one(
         from(r in "entity_scope_declarations",
           where: r.entity_type == ^type,
           select: %{kind: r.kind, field: r.field}
         ),
         prefix: prefix
       )}
    end)
    |> Multi.run(:row, fn repo, _changes -> upsert(repo, type, kind, field, user_id, prefix) end)
    |> Multi.merge(fn %{row: row, current: current} ->
      Audit.append_multi(
        Multi.new(),
        :audit,
        %{
          actor_id: user_id,
          action: "entity_scope_declaration.set",
          resource_type: "entity_scope_declaration",
          resource_id: row.id,
          before_state: current && %{kind: current.kind, field: current.field},
          after_state: %{entity_type: type, kind: row.kind, field: row.field},
          trace_id: Map.get(actor, :trace_id)
        },
        prefix
      )
    end)
    |> run(prefix)
  end

  defp upsert(repo, type, kind, field, user_id, prefix) do
    now = DateTime.utc_now()

    {1, [row]} =
      repo.insert_all(
        "entity_scope_declarations",
        [
          %{
            id: Ecto.UUID.bingenerate(),
            entity_type: type,
            kind: kind,
            field: field,
            set_by: Ecto.UUID.dump!(user_id),
            inserted_at: now,
            updated_at: now
          }
        ],
        prefix: prefix,
        on_conflict: {:replace, [:kind, :field, :set_by, :updated_at]},
        conflict_target: [:entity_type],
        returning: [:id, :entity_type, :kind, :field, :updated_at]
      )

    {:ok, %{row | id: Ecto.UUID.load!(row.id)}}
  end

  # Audit.insert_entry raises on a database failure and Repo.transaction does not convert a
  # raise, so it is rescued here (INV-8); only the exception module is logged (INV-4).
  defp run(multi, prefix) do
    case Repo.transaction(multi, prefix: prefix) do
      {:ok, %{row: row}} ->
        {:ok,
         %{
           "entity_type" => row.entity_type,
           "kind" => row.kind,
           "field" => row.field,
           "set_at" => row.updated_at
         }}

      {:error, _step, reason, _changes} ->
        {:error, {:transaction_failed, reason}}
    end
  rescue
    error ->
      Logger.error("entity scope declaration set failed: #{inspect(error.__struct__)}")
      {:error, {:transaction_failed, error}}
  end
end
