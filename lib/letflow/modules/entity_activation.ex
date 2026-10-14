defmodule Letflow.Modules.EntityActivation do
  @moduledoc """
  Decision 0052 D2/D5/D6 (GH 2531): the shared helper a module's reviewed
  `on_install/3` calls to make its packed entity definitions writable and
  constrained straight after install, inside the install transaction.

  `activate_and_promote(prefix, ctx, names)` walks `names` in the order given,
  which the caller states as its pack's FK-DAG order (FK targets before
  referrers; the order is pack content, not computed here). For each name:

    1. **D6 precondition.** The tenant must hold exactly one entity definition of
       that name: the one the module's pack just inserted, inside this same install
       transaction. No row -> `{:error, {:entity_definition_missing, name}}`; more
       than one row (a tenant-created definition of the same name, or an earlier
       active one) -> `{:error, {:entity_name_conflict, name}}`, so install never
       activates over, and never silently supersedes, a tenant's own type.
    2. **Activate** an `:inactive` row with `Entities.Definitions.activate_definition/4`,
       the installer as activator and the installer-supplied rationale verbatim
       (`ctx`, 0052 D3). An already `:active` row is skipped (D6).
    3. **Promote** every promoted column of the definition (FK fields and `queried`
       fields, `DDL.promoted_columns/1`) that has no `entity_column_promotions` row
       yet: `register_column_promotion/4`, then `run_column_promotion/1`, which
       creates the per-entity-type table with its real `REFERENCES` and unique
       constraints. Activation alone creates no table (0052 facts 5, 6).

  **D5.** After the walk, every `entity_column_promotions` row of this tenant for
  these entity types must be complete: a `pending` or `ddl_failed` row returns
  `{:error, {:promotion_incomplete, [{entity_type, attribute, status}]}}`, so the
  install rolls back instead of leaving a writable but unconstrained type
  (`activate_definition/4` itself never fails over a promotion, 0052 fact 5).

  Returns `:ok` or the first `{:error, reason}`; the caller (`on_install/3`) returns
  it unchanged and `Letflow.Modules.Installs` rolls the whole install back.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Definition.DDL
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Repo
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.ColumnPromotion

  @incomplete_statuses ["pending", "ddl_failed"]

  @type error_reason ::
          {:entity_definition_missing, String.t()}
          | {:entity_name_conflict, String.t()}
          | {:activation_failed, String.t(), term()}
          | {:promotion_failed, String.t(), String.t(), term()}
          | {:promotion_incomplete, [{String.t(), String.t(), String.t()}]}
          | :invalid_schema_name

  @spec activate_and_promote(
          prefix :: String.t(),
          ctx :: Letflow.Modules.Module.install_ctx(),
          names :: [String.t()]
        ) :: :ok | {:error, error_reason()}
  def activate_and_promote(prefix, %{actor_id: actor_id, rationale: rationale}, names)
      when is_binary(prefix) and is_list(names) do
    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         :ok <- walk(names, prefix, tenant_id, actor_id, rationale) do
      check_promotions_complete(tenant_id, names)
    end
  end

  defp walk(names, prefix, tenant_id, actor_id, rationale) do
    Enum.reduce_while(names, :ok, fn name, :ok ->
      with {:ok, definition} <- single_definition(name, prefix),
           {:ok, active} <- ensure_active(definition, actor_id, rationale, prefix),
           :ok <- promote_columns(active, tenant_id) do
        {:cont, :ok}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp single_definition(name, prefix) do
    case Repo.all(from(d in EntityDefinition, where: d.name == ^name), prefix: prefix) do
      [] -> {:error, {:entity_definition_missing, name}}
      [%EntityDefinition{} = definition] -> {:ok, definition}
      [_ | _] -> {:error, {:entity_name_conflict, name}}
    end
  end

  defp ensure_active(
         %EntityDefinition{status: :active} = definition,
         _actor,
         _rationale,
         _prefix
       ),
       do: {:ok, definition}

  defp ensure_active(%EntityDefinition{name: name}, actor_id, rationale, prefix) do
    case Definitions.activate_definition(name, actor_id, rationale, prefix) do
      {:ok, %EntityDefinition{} = active} -> {:ok, active}
      {:error, reason} -> {:error, {:activation_failed, name, reason}}
    end
  end

  defp promote_columns(%EntityDefinition{name: entity_type} = definition, tenant_id) do
    definition
    |> TenantProvisioning.document_from_persisted()
    |> DDL.promoted_columns()
    |> Enum.reduce_while(:ok, fn column, :ok ->
      case promote_column(entity_type, column, tenant_id) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp promote_column(entity_type, column, tenant_id) do
    attribute = Map.fetch!(column, :name)

    if TenantProvisioning.column_promotion_registered?(tenant_id, entity_type, attribute) do
      :ok
    else
      spec = %{
        pg_type: Map.fetch!(column, :pg_type),
        nullable: true,
        references_entity: Map.get(column, :references_entity),
        generated_as: Map.get(column, :generated_as)
      }

      with {:ok, [row]} <-
             TenantProvisioning.register_column_promotion(entity_type, attribute, spec, [
               tenant_id
             ]),
           {:ok, %ColumnPromotion{}} <- TenantProvisioning.run_column_promotion(row.id) do
        :ok
      else
        {:error, reason} -> {:error, {:promotion_failed, entity_type, attribute, reason}}
      end
    end
  end

  # D5: entity_column_promotions is a global table (no tenant prefix); rows are scoped by
  # tenant_id. Every row for these types counts, including ones activate_definition/4's
  # own constraint pass registered and left failed.
  defp check_promotions_complete(tenant_id, names) do
    query =
      from(p in ColumnPromotion,
        where:
          p.tenant_id == ^tenant_id and p.entity_type in ^names and
            p.status in ^@incomplete_statuses,
        order_by: [p.entity_type, p.attribute],
        select: {p.entity_type, p.attribute, p.status}
      )

    case Repo.all(query) do
      [] -> :ok
      incomplete -> {:error, {:promotion_incomplete, incomplete}}
    end
  end
end
