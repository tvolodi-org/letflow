defmodule Letflow.Identity.RoleScopeGrants.Backfill do
  @moduledoc """
  The release-callable repair sweep for `role_scope_grants` (REQ-497 / GH #2533 PR 1a; design
  `lib/letflow/design/req497-1a-role-scope-grants-table-backfill-writers.md` section 4).

  The migration `CreateRoleScopeGrants` backfills every tenant once. During a rolling deploy a
  pre-release node can still write a binding without its row; this sweep closes every such T9
  gap afterwards. It inserts a tenant-wide group row only for a `:platform_role` binding with
  no row at all (`Letflow.Identity.RoleScopeGrants.repair_group_row!/3`), so a group holding
  only scoped rows is never widened, and a re-run that inserts nothing writes nothing (no
  audit entry either). The migration does not call this module.

  Sequential over `Letflow.TenantProvisioning.list_registrations/0`, one transaction per
  tenant, none across tenants (same shape as `Letflow.Identity.RoleBackfill`).

  REQ-519 2e-a (design 3.6a): a tenant whose scope enforcement is `on` is SKIPPED, not repaired
  and not an error. A binding writer there creates no tenant-wide row by design, so the gap
  (T9) is expected to remain; the sweep attempts no repair, skips the gap check, writes no
  `scope.backfill_completed` entry, reports `skipped_enforced: true` with the current gap in
  `bindings_without_row_after`, and carries on with the next tenant. A mode that cannot be read
  is that tenant's error (`{:unexpected_exception, ModeUnavailableError}`).

  In a release (no Mix), printing the result:
  `bin/letflow rpc "IO.inspect(Letflow.Identity.RoleScopeGrants.Backfill.run([]))"`.
  """

  import Ecto.Query

  require Logger

  alias Letflow.Audit
  alias Letflow.Identity
  alias Letflow.Identity.AuditContext
  alias Letflow.Identity.RoleScopeGrants
  alias Letflow.Identity.TenantRole
  alias Letflow.Repo
  alias Letflow.ScopeEnforcement
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @typedoc """
  The only error reasons `run_tenant/2` returns. `{:audit_failed, tag}` carries a tag (an
  atom reason, `:invalid_changeset`, `:unexpected_error`) or the exception module only, never
  the raw reason term (the result can be returned through `rpc`, INV-4).
  """
  @type run_tenant_error :: :gap_remains | {:audit_failed, atom()}

  @type tenant_report :: %{
          tenant_id: Ecto.UUID.t(),
          platform_role_bindings: non_neg_integer(),
          group_rows_inserted: non_neg_integer(),
          bindings_without_row_after: non_neg_integer(),
          skipped_enforced: boolean()
        }

  @type dry_run_tenant_report :: %{
          tenant_id: Ecto.UUID.t() | nil,
          platform_role_bindings: non_neg_integer(),
          bindings_without_row_before: non_neg_integer(),
          skipped_enforced: boolean()
        }

  @type skipped :: %{
          tenant_id: Ecto.UUID.t(),
          schema_name: String.t(),
          reason: :tenant_schema_missing
        }

  @type report :: %{
          dry_run: boolean(),
          tenants: [tenant_report()] | [dry_run_tenant_report()],
          skipped: [skipped()],
          inserted_total: non_neg_integer(),
          skipped_enforced_tenants: [Ecto.UUID.t() | nil]
        }

  @doc """
  Sweeps every registered tenant with `run_tenant/2` under one trace id.

  A registration whose schema (or whose `role_scope_grants` table) is missing, up front or
  mid-sweep (`undefined_table` / `invalid_schema_name`), is reported in `skipped` and the
  sweep continues. The first `{:error, reason}` from `run_tenant/2` halts the sweep with
  `{:backfill_failed, tenant_id, reason}`; any other exception halts it with
  `{:backfill_failed, tenant_id, {:unexpected_exception, module}}` (the module only, never
  the message, INV-4).

  In a release (no Mix), printing the result:
  `bin/letflow rpc "IO.inspect(Letflow.Identity.RoleScopeGrants.Backfill.run([]))"`.
  """
  @spec run(opts :: [dry_run: boolean()]) ::
          {:ok, report()}
          | {:error,
             {:backfill_failed, tenant_id :: Ecto.UUID.t(),
              reason :: run_tenant_error() | {:unexpected_exception, module()}}}
  def run(opts) do
    dry_run? = Keyword.get(opts, :dry_run, false) == true

    initial = %{
      dry_run: dry_run?,
      tenants: [],
      skipped: [],
      inserted_total: 0,
      skipped_enforced_tenants: []
    }

    Letflow.Obs.Logger.with_trace(fn ->
      TenantProvisioning.list_registrations()
      |> Enum.reduce_while({:ok, initial}, fn registration, {:ok, acc} ->
        process_registration(registration, acc, dry_run?)
      end)
      |> case do
        {:ok, acc} ->
          {:ok,
           %{
             acc
             | tenants: Enum.reverse(acc.tenants),
               skipped: Enum.reverse(acc.skipped),
               skipped_enforced_tenants: Enum.reverse(acc.skipped_enforced_tenants)
           }}

        {:error, _reason} = error ->
          error
      end
    end)
  end

  @doc """
  Repairs one tenant schema.

  Real run, one transaction: the tenant admin lock first; a `repair_group_row!/3` for every
  row of `RoleScopeGrants.bindings_without_row/1`; T9 must then be 0, else it rolls back with
  `:gap_remains`; only when it inserted something, one `scope.backfill_completed` audit entry
  (`"source" => "backfill_task"`), whose failure rolls back with `{:audit_failed, tag}` (a
  tag or the exception module, never the raw reason, see `t:run_tenant_error/0`).

  Dry run (`dry_run: true`): read-only, no transaction, no lock, no audit; reports the gap
  as `bindings_without_row_before` and whether the tenant is `on` as `skipped_enforced` (read
  with `ScopeEnforcement.get_mode/1`, no transaction; an unreadable or absent mode reports
  `false`) and never returns `{:error, _}`.

  A raise (DB error, missing schema) propagates to the caller.
  """
  @spec run_tenant(schema_name :: String.t(), opts :: [dry_run: boolean()]) ::
          {:ok, tenant_report() | dry_run_tenant_report()} | {:error, run_tenant_error()}
  def run_tenant(schema_name, opts) when is_binary(schema_name) do
    tenant_id = tenant_id_or_nil(schema_name)

    if Keyword.get(opts, :dry_run, false) == true do
      {:ok,
       %{
         tenant_id: tenant_id,
         platform_role_bindings: binding_count(schema_name, :platform_role),
         bindings_without_row_before: RoleScopeGrants.bindings_without_row_count(schema_name),
         skipped_enforced: enforced_snapshot?(tenant_id)
       }}
    else
      repair_tenant(schema_name, tenant_id)
    end
  end

  # --- per registration --------------------------------------------------------

  defp process_registration(%Registration{tenant_id: tid, schema_name: schema}, acc, dry_run?) do
    if table_present?(schema) do
      case run_tenant(schema, dry_run: dry_run?) do
        {:ok, tenant_report} -> {:cont, {:ok, add_tenant(acc, tenant_report)}}
        {:error, reason} -> {:halt, {:error, {:backfill_failed, tid, reason}}}
      end
    else
      {:cont, {:ok, add_skipped(acc, tid, schema)}}
    end
  rescue
    # The ISS-0343 race: the schema vanished mid-sweep (role_backfill.ex precedent).
    error in Postgrex.Error ->
      case error do
        %Postgrex.Error{postgres: %{code: code}}
        when code in [:undefined_table, :invalid_schema_name] ->
          {:cont, {:ok, add_skipped(acc, tid, schema)}}

        _other ->
          {:halt, {:error, {:backfill_failed, tid, {:unexpected_exception, Postgrex.Error}}}}
      end

    exception ->
      {:halt, {:error, {:backfill_failed, tid, {:unexpected_exception, exception.__struct__}}}}
  end

  defp add_tenant(acc, tenant_report) do
    enforced =
      if tenant_report.skipped_enforced,
        do: [tenant_report.tenant_id | acc.skipped_enforced_tenants],
        else: acc.skipped_enforced_tenants

    %{
      acc
      | tenants: [tenant_report | acc.tenants],
        inserted_total: acc.inserted_total + Map.get(tenant_report, :group_rows_inserted, 0),
        skipped_enforced_tenants: enforced
    }
  end

  defp add_skipped(acc, tenant_id, schema) do
    skipped = %{tenant_id: tenant_id, schema_name: schema, reason: :tenant_schema_missing}
    %{acc | skipped: [skipped | acc.skipped]}
  end

  # The qualified name is a bound parameter (INV-7); NULL when the schema or table is gone.
  defp table_present?(schema) do
    %Postgrex.Result{rows: [[present?]]} =
      Repo.query!("SELECT to_regclass($1) IS NOT NULL", [~s("#{schema}".role_scope_grants)])

    present?
  end

  # --- per tenant ------------------------------------------------------------

  defp repair_tenant(schema, tenant_id) do
    Repo.transaction(
      fn ->
        Identity.lock_tenant_admins!(schema)

        platform_role_bindings = binding_count(schema, :platform_role)

        case ScopeEnforcement.mode_under_lock!(schema) do
          :on -> enforced_report(schema, tenant_id, platform_role_bindings)
          _off_or_shadow -> repair_rows!(schema, tenant_id, platform_role_bindings)
        end
      end,
      prefix: schema
    )
  end

  # REQ-519 design 3.6a: no repair, no gap check, no audit entry.
  defp enforced_report(schema, tenant_id, platform_role_bindings) do
    Logger.info("binding_row_skipped reason=enforced writer=backfill")

    %{
      tenant_id: tenant_id,
      platform_role_bindings: platform_role_bindings,
      group_rows_inserted: 0,
      bindings_without_row_after: RoleScopeGrants.bindings_without_row_count(schema),
      skipped_enforced: true
    }
  end

  defp enforced_snapshot?(nil), do: false

  defp enforced_snapshot?(tenant_id),
    do: match?({:ok, :on}, ScopeEnforcement.get_mode(tenant_id))

  defp repair_rows!(schema, tenant_id, platform_role_bindings) do
    inserted =
      schema
      |> RoleScopeGrants.bindings_without_row()
      |> Enum.count(fn %{group_id: group_id, name: name} ->
        RoleScopeGrants.repair_group_row!(group_id, name, schema) == :inserted
      end)

    if RoleScopeGrants.bindings_without_row_count(schema) != 0 do
      Repo.rollback(:gap_remains)
    end

    if inserted > 0 do
      audit!(schema, tenant_id, platform_role_bindings, inserted)
    end

    %{
      tenant_id: tenant_id,
      platform_role_bindings: platform_role_bindings,
      group_rows_inserted: inserted,
      bindings_without_row_after: 0,
      skipped_enforced: false
    }
  end

  defp audit!(schema, tenant_id, platform_role_bindings, inserted) do
    attrs = %{
      actor_id: nil,
      action: "scope.backfill_completed",
      resource_type: "role_scope_grants",
      resource_id: tenant_id || schema,
      before_state: nil,
      after_state: %{
        "source" => "backfill_task",
        "platform_role_bindings" => platform_role_bindings,
        "group_rows_inserted" => inserted,
        "user_rows_inserted" => 0,
        "process_routing_bindings_skipped" => binding_count(schema, :process_routing_role),
        "bindings_without_row_after" => 0
      },
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

  defp binding_count(schema, kind) do
    Repo.aggregate(from(t in TenantRole, where: t.kind == ^kind), :count, prefix: schema)
  end

  defp tenant_id_or_nil(schema) do
    case TenantProvisioning.tenant_id_for_schema_name(schema) do
      {:ok, tenant_id} -> tenant_id
      {:error, _reason} -> nil
    end
  end
end
