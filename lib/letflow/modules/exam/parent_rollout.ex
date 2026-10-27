defmodule Letflow.Modules.Exam.ParentRollout do
  @moduledoc """
  GH #3315 / REQ-586 part C -- brings an exam-installed tenant that has the pack from BEFORE part A
  to the `parent_id` shape of the shipped `category` and `question` definitions (decision 0052
  fact 8: an installed tenant keeps its old definitions), per tenant, idempotently:

    1. the ACTIVE definition declares `parent_id` (string, queried, not required), the foreign key
       `fk_<type>_parent_id` onto its own table and the index `idx_<type>_parent_id` (a new
       definition version = the tenant's active definition plus exactly those three entries,
       created and activated only through `Definitions.create_definition/3` and
       `activate_definition/4`, under the exam owner `ManagedTypes.owner_for!/1`);
    2. the `parent_id` column is promoted (uuid, nullable, self-FK `ON DELETE RESTRICT`), existing
       rows keep a null parent; and
    3. the index physically exists (`TenantProvisioning.ensure_entity_indexes/4`).

  Shape of `Letflow.Modules.Exam.Snapshot.Rollout`: sequential over
  `TenantProvisioning.list_registrations/0`, a per-tenant failure recorded as a tag (never a
  message or a value, INV-4) while the sweep continues, `dry_run: true` writes nothing, `tenant_id`
  only from `TenantProvisioning.tenant_id_for_schema_name/1`. Two differences, both forced by the
  code: `category` and `question` are exam-managed types, so the owner is passed (the
  `:managed_cannot_upgrade` branch of the snapshot rollout does not apply); and activation promotes
  only constrained columns, so the rollout registers and runs the column promotion itself, the way
  `Letflow.Modules.EntityActivation` does.

  ONE transaction per tenant, under the schema advisory lock: definitions, promotion rows, DDL and
  indexes commit or roll back together (Postgres DDL is transactional). So no write can carry
  `parent_id` before its column exists, and a failed tenant is left exactly as it was. A tenant is
  all-or-nothing: if either type is blocked (unstamped name, another module's type, a `parent_id`
  of another shape) nothing is written for the tenant.

  Run it from a release through `Letflow.Release.ExamParentId.rollout/1`.
  """

  import Ecto.Query

  alias Letflow.Entities.Definition.DDL
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Modules.Exam
  alias Letflow.Modules.Exam.DefinitionDocument
  alias Letflow.Repo
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.ColumnPromotion
  alias Letflow.TenantProvisioning.Registration

  @system_actor_id "00000000-0000-0000-0000-000000000000"
  @attribute "parent_id"
  @types ["category", "question"]
  @complete_statuses ["ddl_applied", "backfilling", "backfilled", "active"]
  @rationale "REQ-586: add parent_id, its self foreign key and index (exam parent_id rollout)"

  @type opts :: [dry_run: boolean()]

  @type tenant_status ::
          :upgraded
          | :already_current
          | :exam_not_installed
          | :skipped_schema_missing
          | :conflict
          | :managed_name_taken
          | :failed

  @type type_status ::
          :added
          | :completed
          | :already_current
          | :conflict
          | :managed_name_taken
          | :other_module_managed
          | :skipped

  @type tenant_report :: %{
          tenant_id: Ecto.UUID.t() | nil,
          schema_name: String.t(),
          status: tenant_status(),
          types: %{String.t() => type_status()},
          error:
            nil
            | :nested_transaction
            | {:definition_write_failed, atom()}
            | {:promotion_failed, String.t(), atom()}
            | {:unexpected_exception, module()}
        }

  @type report :: %{
          dry_run: boolean(),
          tenants: [tenant_report()],
          upgraded_total: non_neg_integer(),
          conflict_total: non_neg_integer(),
          failed_total: non_neg_integer()
        }

  @type tenant_check :: %{
          schema_name: String.t(),
          category: boolean(),
          question: boolean()
        }

  @doc "Sweeps every registered tenant with `run_tenant/2`. Never halts on one tenant's failure."
  @spec run(opts()) :: {:ok, report()}
  def run(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false) == true

    tenants =
      Letflow.Obs.Logger.with_trace(fn ->
        for %Registration{schema_name: schema} <- TenantProvisioning.list_registrations() do
          run_tenant(schema, opts)
        end
      end)

    {:ok,
     %{
       dry_run: dry_run?,
       tenants: tenants,
       upgraded_total: Enum.count(tenants, &(&1.status == :upgraded)),
       conflict_total: Enum.count(tenants, &(&1.status in [:conflict, :managed_name_taken])),
       failed_total: Enum.count(tenants, &(&1.status == :failed))
     }}
  end

  @doc """
  Rolls out one tenant schema. Never raises: any failure is a `status: :failed` report carrying a
  tag or an exception module. Inside an open transaction it returns `error: :nested_transaction`.
  """
  @spec run_tenant(schema_name :: String.t(), opts()) :: tenant_report()
  def run_tenant(schema_name, opts \\ []) when is_binary(schema_name) do
    tenant_id = tenant_id_or_nil(schema_name)
    report = base_report(tenant_id, schema_name)

    cond do
      Repo.in_transaction?() -> %{report | status: :failed, error: :nested_transaction}
      tenant_id == nil -> %{report | status: :skipped_schema_missing}
      true -> guarded_run(report, schema_name, tenant_id, opts)
    end
  end

  @doc """
  Read-only readiness check: for every exam-installed tenant, per type whether the active
  definition has the `parent_id` shape, its promotion is complete and its index exists. `ready`
  is true when every such tenant is true for both types.
  """
  @spec verify() :: %{ready: boolean(), tenants: [tenant_check()]}
  def verify do
    tenants =
      for %Registration{schema_name: schema, tenant_id: tenant_id} <-
            TenantProvisioning.list_registrations(),
          check = check_tenant(schema, tenant_id),
          do: check

    %{ready: Enum.all?(tenants, &(&1.category and &1.question)), tenants: tenants}
  end

  defp check_tenant(schema, tenant_id) do
    if exam_installed?(schema) do
      %{
        schema_name: schema,
        category: type_ready?(schema, tenant_id, "category"),
        question: type_ready?(schema, tenant_id, "question")
      }
    end
  rescue
    error in Postgrex.Error ->
      case error do
        %Postgrex.Error{postgres: %{code: code}}
        when code in [:undefined_table, :invalid_schema_name] ->
          nil

        _other ->
          reraise error, __STACKTRACE__
      end
  end

  defp type_ready?(schema, tenant_id, type) do
    case Definitions.get_active_definition_by_name(type, schema) do
      {:ok, active} -> classify(active, schema, tenant_id) == :current
      {:error, _reason} -> false
    end
  end

  # -- classification of the ACTIVE definition -----------------------------------------------

  # :current | :completing | :upgradable | :managed_name_taken | :conflict
  # | :other_module_managed
  defp classify(%EntityDefinition{} = active, schema, tenant_id) do
    type = active.name

    case parent_state(active.definition_json, type) do
      :present ->
        if promotion_complete?(tenant_id, type) and index_present?(schema, type),
          do: :current,
          else: :completing

      :different_shape ->
        :conflict

      :absent ->
        case active.managed_by do
          "exam" -> :upgradable
          nil -> :managed_name_taken
          _other_module -> :other_module_managed
        end
    end
  end

  defp parent_state(%{"fields" => fields} = json, type) when is_list(fields) do
    field = Enum.find(fields, &(is_map(&1) and &1["name"] == @attribute))

    fks =
      json
      |> Map.get("foreign_keys", [])
      |> List.wrap()
      |> Enum.filter(&(is_map(&1) and &1["field"] == @attribute))

    cond do
      field == nil and fks == [] ->
        :absent

      is_map(field) and field["type"] == "string" and
          match?([%{"references_entity" => ^type}], fks) ->
        :present

      true ->
        :different_shape
    end
  end

  defp parent_state(_malformed, _type), do: :absent

  defp promotion_complete?(tenant_id, type) do
    case Repo.get_by(ColumnPromotion,
           tenant_id: tenant_id,
           entity_type: type,
           attribute: @attribute
         ) do
      %ColumnPromotion{status: status} -> status in @complete_statuses
      nil -> false
    end
  end

  defp index_present?(schema, type),
    do: TenantProvisioning.entity_index_exists?(schema, index_name(type))

  defp index_name(type), do: "idx_#{type}_parent_id"
  defp fk_name(type), do: "fk_#{type}_parent_id"

  # -- run -------------------------------------------------------------------------------------

  defp guarded_run(report, schema, tenant_id, opts) do
    dry_run? = Keyword.get(opts, :dry_run, false) == true

    if exam_installed?(schema) do
      case fetch_actives(schema) do
        {:ok, actives} -> plan_and_run(report, schema, tenant_id, actives, dry_run?)
        {:error, tag} -> %{report | status: :failed, error: {:definition_write_failed, tag}}
      end
    else
      %{report | status: :exam_not_installed}
    end
  rescue
    error in Postgrex.Error ->
      case error do
        %Postgrex.Error{postgres: %{code: code}}
        when code in [:undefined_table, :invalid_schema_name] ->
          %{report | status: :skipped_schema_missing}

        _other ->
          %{report | status: :failed, error: {:unexpected_exception, Postgrex.Error}}
      end

    exception ->
      %{report | status: :failed, error: {:unexpected_exception, exception.__struct__}}
  end

  defp fetch_actives(schema) do
    Enum.reduce_while(@types, {:ok, []}, fn type, {:ok, acc} ->
      case Definitions.get_active_definition_by_name(type, schema) do
        {:ok, active} -> {:cont, {:ok, acc ++ [active]}}
        {:error, _reason} -> {:halt, {:error, :no_active_definition}}
      end
    end)
  end

  defp plan_and_run(report, schema, tenant_id, actives, dry_run?) do
    plan = for active <- actives, do: {active, classify(active, schema, tenant_id)}
    states = Enum.map(plan, &elem(&1, 1))

    cond do
      Enum.any?(states, &(&1 == :managed_name_taken)) ->
        blocked(report, plan, :managed_name_taken)

      Enum.any?(states, &(&1 in [:conflict, :other_module_managed])) ->
        blocked(report, plan, :conflict)

      Enum.all?(states, &(&1 == :current)) ->
        %{report | status: :already_current, types: planned_types(plan)}

      dry_run? ->
        %{report | status: :upgraded, types: planned_types(plan)}

      true ->
        real_run(report, schema, tenant_id, plan)
    end
  end

  defp blocked(report, plan, status) do
    types =
      Map.new(plan, fn {active, state} ->
        {active.name,
         if(state in [:current, :completing, :upgradable], do: :skipped, else: state)}
      end)

    %{report | status: status, types: types}
  end

  defp planned_types(plan) do
    Map.new(plan, fn {active, state} ->
      {active.name,
       case state do
         :current -> :already_current
         :completing -> :completed
         :upgradable -> :added
       end}
    end)
  end

  defp real_run(report, schema, tenant_id, plan) do
    owner = ManagedTypes.owner_for!(Exam)

    result =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [schema])

        Enum.each(plan, fn {active, state} ->
          case upgrade_type(state, active, schema, tenant_id, owner) do
            :ok -> :ok
            {:error, error} -> Repo.rollback(error)
          end
        end)
      end)

    case result do
      {:ok, _done} ->
        %{report | status: :upgraded, types: planned_types(plan)}

      {:error, {:definition_write_failed, _tag} = error} ->
        failed(report, error)

      {:error, {:promotion_failed, _type, _tag} = error} ->
        failed(report, error)

      # A rollback inside a nested transaction poisons the outer one, which then reports a bare
      # `:rollback` instead of the tagged value.
      {:error, _rolled_back} ->
        failed(report, {:definition_write_failed, :rolled_back})
    end
  rescue
    error in Postgrex.Error ->
      %{report | status: :failed, error: {:unexpected_exception, error.__struct__}}
  end

  defp failed(report, error),
    do: %{report | status: :failed, types: skipped_types(), error: error}

  defp skipped_types, do: Map.new(@types, &{&1, :skipped})

  defp upgrade_type(:current, _active, _schema, _tenant_id, _owner), do: :ok

  defp upgrade_type(:completing, active, schema, tenant_id, _owner),
    do: complete_type(active, schema, tenant_id)

  defp upgrade_type(:upgradable, active, schema, tenant_id, owner) do
    type = active.name

    with {:ok, document} <- DefinitionDocument.from_stored(active.definition_json),
         {:ok, _created} <-
           Definitions.create_definition(
             %{definition: with_parent(document, type), created_by: @system_actor_id},
             schema,
             owner
           ),
         {:ok, new_active} <-
           Definitions.activate_definition(type, @system_actor_id, @rationale, schema) do
      complete_type(new_active, schema, tenant_id)
    else
      {:error, reason} -> {:error, {:definition_write_failed, reason_tag(reason)}}
    end
  end

  defp with_parent(document, type) do
    document
    |> Map.update!(
      :fields,
      &(&1 ++ [%{name: @attribute, type: :string, required: false, queried: true}])
    )
    |> Map.update(
      :foreign_keys,
      [fk(type)],
      &(&1 ++ [fk(type)])
    )
    |> Map.update(:indexes, [index(type)], &(&1 ++ [index(type)]))
  end

  defp fk(type), do: %{name: fk_name(type), field: @attribute, references_entity: type}
  defp index(type), do: %{name: index_name(type), fields: [@attribute]}

  # Steps 2 and 3 for a type whose active definition already declares parent_id.
  defp complete_type(%EntityDefinition{name: type} = active, schema, tenant_id) do
    document = TenantProvisioning.document_from_persisted(active)

    with :ok <- ensure_promotion(type, document, tenant_id),
         :ok <- ensure_index(type, document, schema) do
      :ok
    end
  end

  defp ensure_promotion(type, document, tenant_id) do
    existing =
      Repo.get_by(ColumnPromotion,
        tenant_id: tenant_id,
        entity_type: type,
        attribute: @attribute
      )

    case existing do
      %ColumnPromotion{status: status} when status in @complete_statuses ->
        :ok

      %ColumnPromotion{id: id} ->
        run_promotion(type, id)

      nil ->
        column = document |> DDL.promoted_columns() |> Enum.find(&(&1.name == @attribute))

        spec = %{
          pg_type: column.pg_type,
          nullable: true,
          references_entity: column.references_entity,
          generated_as: nil
        }

        case TenantProvisioning.register_column_promotion(type, @attribute, spec, [tenant_id]) do
          {:ok, [row]} -> run_promotion(type, row.id)
          {:error, reason} -> {:error, {:promotion_failed, type, reason_tag(reason)}}
        end
    end
  end

  defp run_promotion(type, promotion_id) do
    case TenantProvisioning.run_column_promotion(promotion_id) do
      {:ok, %ColumnPromotion{}} -> :ok
      {:error, reason} -> {:error, {:promotion_failed, type, reason_tag(reason)}}
    end
  end

  defp ensure_index(type, document, schema) do
    case TenantProvisioning.ensure_entity_indexes(schema, type, document, [index_name(type)]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:promotion_failed, type, reason_tag(reason)}}
    end
  end

  defp exam_installed?(schema) do
    Repo.exists?(from(m in "tenant_modules", where: m.module_id == "exam"), prefix: schema)
  end

  # A tag or the exception module only, never the raw term (INV-4).
  defp reason_tag(%{__exception__: true, __struct__: module}), do: module
  defp reason_tag(%Ecto.Changeset{}), do: :invalid_changeset
  defp reason_tag(tag) when is_atom(tag), do: tag

  defp reason_tag(tuple)
       when is_tuple(tuple) and tuple_size(tuple) > 0 and is_atom(elem(tuple, 0)),
       do: elem(tuple, 0)

  defp reason_tag(_other), do: :unexpected_error

  defp base_report(tenant_id, schema_name) do
    %{
      tenant_id: tenant_id,
      schema_name: schema_name,
      status: :already_current,
      types: skipped_types(),
      error: nil
    }
  end

  defp tenant_id_or_nil(schema) do
    case TenantProvisioning.tenant_id_for_schema_name(schema) do
      {:ok, tenant_id} -> tenant_id
      {:error, _reason} -> nil
    end
  end
end
