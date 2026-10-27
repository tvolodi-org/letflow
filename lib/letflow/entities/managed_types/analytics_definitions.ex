defmodule Letflow.Entities.ManagedTypes.AnalyticsDefinitions do
  @moduledoc """
  Gives tenants that installed the exam module BEFORE REQ-594 the analytics-ready versions of
  `session` (`score_pct` and `passed` queried) and `session_question_score` (new optional queried
  `exam_id` and `correct`). A release step: no route, flag or permission, and no column promotion.

  Shape follows `Letflow.Entities.ManagedTypes.AssignmentDefinition`: sequential over
  `Letflow.TenantProvisioning.list_registrations/0`, ONE transaction per tenant, none across
  tenants. A per-tenant failure is recorded in that tenant's report (a tag or exception module
  only, INV-4/INV-8) and the sweep continues.

  The new version is derived from the tenant's own ACTIVE definition plus exactly the analytics
  changes, not built from the pack file (precedent: `Letflow.Modules.Exam.Snapshot.Rollout`). So a
  tenant's extra fields survive, stripped foreign keys and constraints stay stripped, and
  activation (which promotes constrained fields only) registers no promotion. Stamped tenants get
  the exam module's `managed_by`; unstamped tenants get owner `:tenant`, so
  `Letflow.Entities.ManagedTypes.Stamp` still finds a compatible row afterwards.

  Per tenant, in order:

    * called inside an open transaction: `status: :failed, error: :nested_transaction`;
    * unknown tenant schema: `:skipped_schema_missing`;
    * the exam module is not installed: `:exam_not_installed`, nothing written;
    * a type managed by another module, or an analytics field of another type, or a missing
      `score_pct`/`passed`: `:conflict`, nothing written for either type;
    * every type already current (or without an active version): `:nothing_to_do`, nothing
      written, no audit entry (this makes a second run a no-op);
    * otherwise ONE transaction creates and activates the new versions and writes one audit
      entry: `:created`.

  The schema is always the registration's own (server-side, INV-1).

  In a release, once per deploy after REQ-594 part A merges:
  `bin/letflow rpc "IO.inspect(Letflow.Release.ManagedTypes.ensure_exam_analytics_definitions([]))"`.
  """

  alias Letflow.Audit
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Identity.AuditContext
  alias Letflow.Modules.Installs
  alias Letflow.Repo
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @module_id "exam"
  @types ["session", "session_question_score"]

  # Type of each analytics field, as the pack file declares it (test A-def pins this).
  @analytics_fields %{
    "session" => %{"score_pct" => "decimal", "passed" => "boolean"},
    "session_question_score" => %{"exam_id" => "string", "correct" => "boolean"}
  }

  # Fields the old shape lacks and this step appends (never invented for `session`).
  @appended_fields %{
    "exam_id" => %{
      "name" => "exam_id",
      "type" => "string",
      "queried" => true,
      "required" => false
    },
    "correct" => %{
      "name" => "correct",
      "type" => "boolean",
      "queried" => true,
      "required" => false
    }
  }

  # The release actor for `created_by` / `activator_user_id` (NOT NULL binary_id, no foreign key).
  @release_actor_id "00000000-0000-0000-0000-000000000000"
  @rationale "REQ-594 release ensure"

  @type status ::
          :created
          | :nothing_to_do
          | :exam_not_installed
          | :skipped_schema_missing
          | :conflict
          | :failed

  @type tenant_report :: %{
          tenant_id: Ecto.UUID.t() | nil,
          schema_name: String.t(),
          status: status(),
          types: [String.t()],
          error:
            nil
            | :nested_transaction
            | {:audit_failed, atom()}
            | {:ensure_failed, atom()}
            | {:conflict, String.t(), atom()}
            | {:unexpected_exception, module()}
        }

  @type report :: %{
          module: String.t(),
          tenants: [tenant_report()],
          created_total: non_neg_integer(),
          failed_total: non_neg_integer(),
          conflict_total: non_neg_integer()
        }

  @doc "The analytics fields per type this step supplies, as `%{type => %{field => type}}`."
  @spec analytics_fields() :: %{String.t() => %{String.t() => String.t()}}
  def analytics_fields, do: @analytics_fields

  @doc "Sweeps every registered tenant with `run_tenant/2` under one trace id. Never halts on one tenant's failure."
  @spec run(keyword()) :: {:ok, report()}
  def run(opts \\ []) when is_list(opts) do
    tenants =
      Letflow.Obs.Logger.with_trace(fn ->
        for %Registration{schema_name: schema} <- TenantProvisioning.list_registrations() do
          run_tenant(schema, opts)
        end
      end)

    {:ok,
     %{
       module: @module_id,
       tenants: tenants,
       created_total: Enum.count(tenants, &(&1.status == :created)),
       failed_total: Enum.count(tenants, &(&1.status == :failed)),
       conflict_total: Enum.count(tenants, &(&1.status == :conflict))
     }}
  end

  @doc """
  Ensures the definitions in one tenant schema. Never raises: any failure is a `status: :failed`
  report carrying a tag or an exception module (never a message).
  """
  @spec run_tenant(schema_name :: String.t(), keyword()) :: tenant_report()
  def run_tenant(schema_name, _opts \\ []) when is_binary(schema_name) do
    tenant_id = tenant_id_or_nil(schema_name)

    report = %{
      tenant_id: tenant_id,
      schema_name: schema_name,
      status: :nothing_to_do,
      types: [],
      error: nil
    }

    cond do
      Repo.in_transaction?() -> %{report | status: :failed, error: :nested_transaction}
      tenant_id == nil -> %{report | status: :skipped_schema_missing}
      true -> guarded_run(report, schema_name)
    end
  end

  @doc false
  # Maps the per-tenant transaction result. A rollback inside the nested create/activate
  # transaction poisons the outer one, which then reports a bare `:rollback`.
  @spec map_result({:ok, :ok} | {:error, term()}) :: :created | {:failed, term()}
  def map_result({:ok, :ok}), do: :created
  def map_result({:error, {:audit_failed, _tag} = error}), do: {:failed, error}
  def map_result({:error, {:ensure_failed, _tag} = error}), do: {:failed, error}
  def map_result({:error, _rolled_back}), do: {:failed, {:ensure_failed, :rolled_back}}

  defp guarded_run(report, schema) do
    if Installs.installed?(@module_id, prefix: schema) do
      case plan(schema) do
        {:conflict, type, reason} ->
          %{report | status: :conflict, error: {:conflict, type, reason}}

        [] ->
          report

        steps ->
          create(report, schema, steps)
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

  # [{type, owner_kind, derived_definition_json}] for the types that need a new version, or the
  # first conflict (both types or neither).
  defp plan(schema) do
    Enum.reduce_while(@types, [], fn type, acc ->
      case plan_type(type, schema) do
        :skip -> {:cont, acc}
        {:conflict, reason} -> {:halt, {:conflict, type, reason}}
        step -> {:cont, [step | acc]}
      end
    end)
    |> case do
      {:conflict, _type, _reason} = conflict -> conflict
      steps -> Enum.reverse(steps)
    end
  end

  defp plan_type(type, schema) do
    with {:ok, active} <- Definitions.get_active_definition_by_name(type, schema),
         {:ok, owner_kind} <- owner_kind(type, schema),
         {:ok, derived} <- derive(type, active.definition_json) do
      if derived == active.definition_json, do: :skip, else: {type, owner_kind, derived}
    else
      {:error, :not_found} -> :skip
      {:error, :managed_by_other} -> {:conflict, :managed_by_other}
      {:error, {:conflict, reason}} -> {:conflict, reason}
    end
  end

  defp owner_kind(type, schema) do
    case ManagedTypes.owner_of(type, schema) do
      {:ok, @module_id} -> {:ok, :module}
      :unmanaged -> {:ok, :tenant}
      {:ok, _other} -> {:error, :managed_by_other}
      {:error, :invalid_schema_name} -> {:error, :not_found}
    end
  end

  defp derive(type, %{"fields" => fields} = json) when is_list(fields) do
    wanted = Map.fetch!(@analytics_fields, type)

    result =
      Enum.reduce_while(wanted, {:ok, fields}, fn {name, field_type}, {:ok, current} ->
        case Enum.find_index(current, &(&1["name"] == name)) do
          nil when type == "session" ->
            {:halt, {:error, {:conflict, :field_missing}}}

          nil ->
            {:cont, {:ok, current ++ [Map.fetch!(@appended_fields, name)]}}

          index ->
            field = Enum.at(current, index)

            if field["type"] == field_type,
              do:
                {:cont, {:ok, List.replace_at(current, index, Map.put(field, "queried", true))}},
              else: {:halt, {:error, {:conflict, :field_type}}}
        end
      end)

    with {:ok, new_fields} <- result, do: {:ok, Map.put(json, "fields", new_fields)}
  end

  defp derive(_type, _json), do: {:error, {:conflict, :field_missing}}

  defp create(report, schema, steps) do
    result =
      Repo.transaction(fn ->
        Enum.each(steps, fn {type, owner_kind, derived} ->
          write_version!(type, owner_kind, derived, schema)
        end)

        audit!(schema, report.tenant_id, Enum.map(steps, &elem(&1, 0)))
      end)

    types = Enum.map(steps, &elem(&1, 0))

    case map_result(result) do
      :created -> %{report | status: :created, types: types}
      {:failed, error} -> %{report | status: :failed, types: types, error: error}
    end
  end

  defp write_version!(type, owner_kind, derived, schema) do
    with {:ok, _created} <-
           Installs.upgrade_entity_definition_version(
             @module_id,
             type,
             derived,
             owner_kind,
             @release_actor_id,
             prefix: schema
           ),
         {:ok, _activated} <-
           Definitions.activate_definition(type, @release_actor_id, @rationale, schema) do
      :ok
    else
      {:error, reason} -> Repo.rollback({:ensure_failed, reason_tag(reason)})
    end
  end

  defp audit!(schema, tenant_id, types) do
    attrs = %{
      actor_id: nil,
      action: "entity_type.exam_analytics_definitions_ensured",
      resource_type: "entity_definitions",
      resource_id: tenant_id || schema,
      before_state: nil,
      after_state: %{"module" => @module_id, "types" => types, "source" => "release_ensure"},
      trace_id: AuditContext.current_trace_id()
    }

    case Audit.insert_entry(Repo, attrs, schema) do
      {:ok, _entry} -> :ok
      {:error, reason} -> Repo.rollback({:audit_failed, reason_tag(reason)})
    end
  end

  # A tag or the exception module only, never the raw reason term (INV-4).
  defp reason_tag(%{__exception__: true, __struct__: module}), do: module
  defp reason_tag(%Ecto.Changeset{}), do: :invalid_changeset
  defp reason_tag(tag) when is_atom(tag), do: tag
  defp reason_tag({tag, _detail}) when is_atom(tag), do: tag
  defp reason_tag(_other), do: :unexpected_error

  defp tenant_id_or_nil(schema) do
    case TenantProvisioning.tenant_id_for_schema_name(schema) do
      {:ok, tenant_id} -> tenant_id
      {:error, _reason} -> nil
    end
  end
end
