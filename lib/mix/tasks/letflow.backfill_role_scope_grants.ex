defmodule Mix.Tasks.Letflow.BackfillRoleScopeGrants do
  @shortdoc "Repairs missing role_scope_grants group rows in every tenant (REQ-497 / GH #2533)"

  @moduledoc """
  Runs `Letflow.Identity.RoleScopeGrants.Backfill.run/1` over every tenant registered in
  `Letflow.TenantProvisioning.list_registrations/0`: every `:platform_role` binding with no
  `role_scope_grants` row gets its tenant-wide group row (design
  `lib/letflow/design/req497-1a-role-scope-grants-table-backfill-writers.md` section 4).
  Run it once after a rolling deploy that applied the `CreateRoleScopeGrants` migration has
  finished, so a binding written by a pre-release node gets its row.

  ## Usage

      mix letflow.backfill_role_scope_grants [--dry-run]

  `--dry-run` reports each tenant's gap without writing. Idempotent: a re-run that finds no
  gap writes nothing. No `LETFLOW_DEV_DB_CONFIRMED` guard (same precedent as
  `mix letflow.backfill_platform_roles`). A tenant whose schema is missing is reported and
  skipped without changing the exit status; any tenant failure exits non-zero.

  In a release (no Mix), printing the result:
  `bin/letflow rpc "IO.inspect(Letflow.Identity.RoleScopeGrants.Backfill.run([]))"`.
  """

  use Mix.Task

  alias Letflow.Identity.RoleScopeGrants.Backfill

  @usage "usage: mix letflow.backfill_role_scope_grants [--dry-run]"

  @impl Mix.Task
  @spec run(argv :: [String.t()]) :: :ok
  def run(argv) do
    dry_run? =
      case OptionParser.parse(argv, strict: [dry_run: :boolean]) do
        {parsed, [], []} -> Keyword.get(parsed, :dry_run, false)
        _invalid -> Mix.raise(@usage)
      end

    Mix.Task.run("app.start")

    case Backfill.run(dry_run: dry_run?) do
      {:ok, report} ->
        print_report(report)
        :ok

      {:error, {:backfill_failed, tenant_id, reason}} ->
        Mix.shell().error(
          "role_scope_grants backfill failed for tenant #{tenant_id}: #{reason_tag(reason)}"
        )

        System.halt(1)
    end
  end

  defp print_report(%{dry_run: dry_run?, tenants: tenants, skipped: skipped} = report) do
    mode = if dry_run?, do: " (dry run)", else: ""

    Mix.shell().info(
      "role_scope_grants backfill complete#{mode}: #{length(tenants)} tenant(s), " <>
        "#{report.inserted_total} row(s) inserted, #{length(skipped)} skipped"
    )

    Enum.each(tenants, &print_tenant/1)

    Enum.each(skipped, fn %{tenant_id: tenant_id} ->
      Mix.shell().info("  tenant #{tenant_id}: skipped (tenant_schema_missing)")
    end)
  end

  defp print_tenant(%{bindings_without_row_before: gap} = tenant) when gap > 0 do
    Mix.shell().info(
      "  tenant #{tenant.tenant_id}: #{gap} binding(s) without a row " <>
        "(#{tenant.platform_role_bindings} platform-role binding(s))"
    )
  end

  defp print_tenant(%{group_rows_inserted: inserted} = tenant) when inserted > 0 do
    Mix.shell().info(
      "  tenant #{tenant.tenant_id}: #{inserted} row(s) inserted " <>
        "(#{tenant.platform_role_bindings} platform-role binding(s))"
    )
  end

  defp print_tenant(_tenant), do: :ok

  # The reason TAG only, never a payload (INV-4).
  defp reason_tag({:unexpected_exception, module}), do: "unexpected_exception #{inspect(module)}"
  defp reason_tag({tag, _detail}) when is_atom(tag), do: Atom.to_string(tag)
  defp reason_tag(tag) when is_atom(tag), do: Atom.to_string(tag)
  defp reason_tag(_other), do: "unexpected_error"
end
