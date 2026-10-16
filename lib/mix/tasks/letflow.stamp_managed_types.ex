defmodule Mix.Tasks.Letflow.StampManagedTypes do
  @shortdoc "Stamps the exam module's six runtime entity types as managed (GH #2596)"

  @moduledoc """
  Runs `Letflow.Release.ManagedTypes.stamp/1` over every tenant registered in
  `Letflow.TenantProvisioning.list_registrations/0` (design
  `lib/letflow/design/gh2596-exam-managed-types.md` section 6).

  ## Usage

      mix letflow.stamp_managed_types [--module exam] [--dry-run]

  `--dry-run` reports what would be stamped without writing. Idempotent: a re-run stamps 0 rows.
  No `LETFLOW_DEV_DB_CONFIRMED` guard (same precedent as `mix letflow.backfill_role_scope_grants`).
  Conflicts and absent types are printed per tenant and counted but do not change the exit status;
  any failed tenant exits 1.

  Do NOT run the real stamp on a shared environment until the session-content-snapshot
  prerequisite issue has landed (design section 17.5).

  In a release (no Mix):
  `bin/letflow rpc "IO.inspect(Letflow.Release.ManagedTypes.stamp(dry_run: true))"`.
  """

  use Mix.Task

  alias Letflow.Release.ManagedTypes

  @usage "usage: mix letflow.stamp_managed_types [--module exam] [--dry-run]"

  @impl Mix.Task
  @spec run(argv :: [String.t()]) :: :ok
  def run(argv) do
    opts =
      case OptionParser.parse(argv, strict: [module: :string, dry_run: :boolean]) do
        {parsed, [], []} -> parsed
        _invalid -> Mix.raise(@usage)
      end

    Mix.Task.run("app.start")

    case ManagedTypes.stamp(opts) do
      {:ok, report} ->
        print_report(report)
        if report.failed_total > 0, do: System.halt(1), else: :ok

      {:error, :unsupported_module} ->
        Mix.raise("unsupported module (only \"exam\" is supported)\n" <> @usage)
    end
  end

  defp print_report(report) do
    mode = if report.dry_run, do: " (dry run)", else: ""

    Mix.shell().info(
      "managed-type stamp complete#{mode}: #{length(report.tenants)} tenant(s), " <>
        "#{report.rows_stamped_total} row(s) stamped, #{report.conflict_total} conflict(s), " <>
        "#{report.failed_total} failed"
    )

    Enum.each(report.tenants, &print_tenant/1)
  end

  defp print_tenant(%{status: :nothing_to_stamp, conflicts: [], types_absent: []}), do: :ok

  defp print_tenant(tenant) do
    Mix.shell().info(
      "  tenant #{tenant.tenant_id || tenant.schema_name}: #{tenant.status}" <>
        ", #{tenant.rows_stamped} stamped, #{tenant.rows_already_stamped} already" <>
        error_text(tenant.error)
    )

    Enum.each(tenant.conflicts, fn conflict ->
      Mix.shell().info(
        "    conflict: #{conflict.type} (#{conflict.reason}, #{conflict.rows} row(s))"
      )
    end)

    if tenant.types_absent != [] do
      Mix.shell().info("    absent: #{Enum.join(tenant.types_absent, ", ")}")
    end

    if tenant.exam_named_types_present != [] do
      Mix.shell().info(
        "    exam-named types present: #{Enum.join(tenant.exam_named_types_present, ", ")}"
      )
    end

    Enum.each(tenant.differences, fn diff ->
      Mix.shell().info(
        "    differs: #{diff.type} extra_fields=#{inspect(diff.extra_fields)} " <>
          "differing=#{inspect(diff.differing)}"
      )
    end)
  end

  # The error TAG only, never a payload (INV-4).
  defp error_text(nil), do: ""

  defp error_text({:unexpected_exception, module}),
    do: ", error: unexpected_exception #{inspect(module)}"

  defp error_text({tag, _detail}) when is_atom(tag), do: ", error: #{tag}"
  defp error_text(tag) when is_atom(tag), do: ", error: #{tag}"
end
