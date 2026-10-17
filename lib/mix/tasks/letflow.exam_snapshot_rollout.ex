defmodule Mix.Tasks.Letflow.ExamSnapshotRollout do
  @shortdoc "Adds the exam_snapshot field and its restriction rows to every exam tenant (GH #2682)"

  @moduledoc """
  Runs `Letflow.Release.ExamSnapshot.rollout/1` over every tenant registered in
  `Letflow.TenantProvisioning.list_registrations/0` (design
  `lib/letflow/design/req511-exam-content-snapshot.md` section 10.3).

  ## Usage

      mix letflow.exam_snapshot_rollout [--dry-run]

  `--dry-run` reports what would change without writing. Idempotent: a re-run reports
  `already_current` for every tenant. Exits 1 when any tenant failed or ended in a conflict.

  In a release (no Mix):
  `bin/letflow rpc "IO.inspect(Letflow.Release.ExamSnapshot.rollout(dry_run: false))"`.
  """

  use Mix.Task

  alias Letflow.Release.ExamSnapshot

  @usage "usage: mix letflow.exam_snapshot_rollout [--dry-run]"

  @impl Mix.Task
  @spec run(argv :: [String.t()]) :: :ok
  def run(argv) do
    opts =
      case OptionParser.parse(argv, strict: [dry_run: :boolean]) do
        {parsed, [], []} -> parsed
        _invalid -> Mix.raise(@usage)
      end

    Mix.Task.run("app.start")

    report = ExamSnapshot.rollout(opts)
    print_report(report)

    if report.failed_total > 0 or report.conflict_total > 0, do: System.halt(1), else: :ok
  end

  defp print_report(report) do
    mode = if report.dry_run, do: " (dry run)", else: ""

    Mix.shell().info(
      "exam snapshot rollout complete#{mode}: #{length(report.tenants)} tenant(s), " <>
        "#{report.upgraded_total} upgraded, #{report.restrictions_added_total} restriction row(s) " <>
        "added, #{report.conflict_total} conflict(s), #{report.failed_total} failed"
    )

    Enum.each(report.tenants, &print_tenant/1)
  end

  defp print_tenant(%{status: :exam_not_installed}), do: :ok

  defp print_tenant(tenant) do
    Mix.shell().info(
      "  tenant #{tenant.tenant_id || tenant.schema_name}: #{tenant.status}" <>
        ", definition #{tenant.definition}, #{tenant.restrictions_added} restriction(s) added" <>
        error_text(tenant.error)
    )
  end

  # The error TAG only, never a payload (INV-4).
  defp error_text(nil), do: ""

  defp error_text({:unexpected_exception, module}),
    do: ", error: unexpected_exception #{inspect(module)}"

  defp error_text({tag, detail}) when is_atom(tag) and is_atom(detail),
    do: ", error: #{tag} #{detail}"

  defp error_text(tag) when is_atom(tag), do: ", error: #{tag}"
end
