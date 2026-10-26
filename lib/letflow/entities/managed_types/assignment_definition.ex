defmodule Letflow.Entities.ManagedTypes.AssignmentDefinition do
  @moduledoc """
  Gives tenants that installed the exam module BEFORE `exam_assignment` joined its pack the
  `exam_assignment` entity definition (REQ-582 part A, criterion 11). It is a release step: no
  route, flag or permission, and `exam_assignment` is deliberately NOT in `Stamp.stamp_names/0`
  (the stamp migrations' frozen sixteen); this module supplies the row instead of stamping one.

  Shape follows `Letflow.Entities.ManagedTypes.Stamp`: sequential over
  `Letflow.TenantProvisioning.list_registrations/0`, ONE transaction per tenant, none across
  tenants. A per-tenant failure is recorded in that tenant's report (a tag or exception module
  only, INV-4/INV-8) and the sweep continues.

  Per tenant, in order:

    * called inside an open transaction: `status: :failed, error: :nested_transaction`;
    * unknown tenant schema: `:skipped_schema_missing`;
    * the exam module is not installed: `:exam_not_installed`, nothing written;
    * a definition row named `exam_assignment` exists (any owner, status or version):
      `:nothing_to_do`, nothing written and never overwritten. This is what makes a second run a
      no-op, audit entry included. A hand-made, unstamped row is left as it is (not reported as a
      conflict), and a tenant that installs the pack after REQ-582 already carries an inactive row
      and is not activated here (its activation stays the install flow's);
    * otherwise ONE transaction creates the pack's definition owner-stamped
      (`Letflow.Modules.Installs.ensure_pack_entity_definition/4`, the only compliant route for
      `managed_types_callers_test`), activates it and writes one audit entry: `:created`.

  The schema is always the registration's own (server-side, INV-1); nothing else selects a tenant.

  In a release (no Mix), through the wrapper, once per deploy after REQ-582 part A merges:
  `bin/letflow rpc "IO.inspect(Letflow.Release.ManagedTypes.ensure_assignment_definition([]))"`.
  """

  alias Letflow.Audit
  alias Letflow.Identity.AuditContext
  alias Letflow.Modules.Installs
  alias Letflow.Repo
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @module_id "exam"
  @type_name "exam_assignment"

  # The release actor for `created_by` / `activator_user_id`: both columns are NOT NULL
  # binary_id with no foreign key, and a release step has no user.
  @release_actor_id "00000000-0000-0000-0000-000000000000"
  @rationale "REQ-582 release ensure"

  @type status ::
          :created | :nothing_to_do | :exam_not_installed | :skipped_schema_missing | :failed

  @type tenant_report :: %{
          tenant_id: Ecto.UUID.t() | nil,
          schema_name: String.t(),
          status: status(),
          error:
            nil
            | :nested_transaction
            | {:audit_failed, atom()}
            | {:ensure_failed, atom()}
            | {:unexpected_exception, module()}
        }

  @type report :: %{
          module: String.t(),
          tenants: [tenant_report()],
          created_total: non_neg_integer(),
          failed_total: non_neg_integer()
        }

  @doc "The managed type name this step supplies."
  @spec type_name() :: String.t()
  def type_name, do: @type_name

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
       failed_total: Enum.count(tenants, &(&1.status == :failed))
     }}
  end

  @doc """
  Ensures the definition in one tenant schema. Never raises: any failure is a `status: :failed`
  report carrying a tag or an exception module (never a message).
  """
  @spec run_tenant(schema_name :: String.t(), keyword()) :: tenant_report()
  def run_tenant(schema_name, _opts \\ []) when is_binary(schema_name) do
    tenant_id = tenant_id_or_nil(schema_name)
    report = %{tenant_id: tenant_id, schema_name: schema_name, status: :nothing_to_do, error: nil}

    cond do
      Repo.in_transaction?() -> %{report | status: :failed, error: :nested_transaction}
      tenant_id == nil -> %{report | status: :skipped_schema_missing}
      true -> guarded_run(report, schema_name)
    end
  end

  defp guarded_run(report, schema) do
    cond do
      not Installs.installed?(@module_id, prefix: schema) ->
        %{report | status: :exam_not_installed}

      definition_exists?(schema) ->
        report

      true ->
        create(report, schema)
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

  defp definition_exists?(schema) do
    match?({:ok, _row}, Letflow.Entities.Definitions.get_definition_by_name(@type_name, schema))
  end

  defp create(report, schema) do
    result =
      Repo.transaction(fn ->
        with {:ok, _created} <-
               Installs.ensure_pack_entity_definition(
                 @module_id,
                 @type_name,
                 @release_actor_id,
                 prefix: schema
               ),
             {:ok, _activated} <-
               Letflow.Entities.Definitions.activate_definition(
                 @type_name,
                 @release_actor_id,
                 @rationale,
                 schema
               ) do
          audit!(schema, report.tenant_id)
        else
          {:error, reason} -> Repo.rollback({:ensure_failed, reason_tag(reason)})
        end
      end)

    case result do
      {:ok, :ok} -> %{report | status: :created}
      {:error, {:audit_failed, _tag} = error} -> %{report | status: :failed, error: error}
      {:error, {:ensure_failed, _tag} = error} -> %{report | status: :failed, error: error}
    end
  end

  defp audit!(schema, tenant_id) do
    attrs = %{
      actor_id: nil,
      action: "entity_type.assignment_definition_ensured",
      resource_type: "entity_definitions",
      resource_id: tenant_id || schema,
      before_state: nil,
      after_state: %{"module" => @module_id, "type" => @type_name, "source" => "release_ensure"},
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
