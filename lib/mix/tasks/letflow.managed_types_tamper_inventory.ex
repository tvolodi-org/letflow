defmodule Mix.Tasks.Letflow.ManagedTypesTamperInventory do
  @shortdoc "Read-only inventory of non-module writes to the exam types (GH #2596)"

  @moduledoc """
  Runs `Letflow.Release.ManagedTypes.tamper_inventory/1`: per exam tenant, the record events of the
  exam types that were probably written through the generic records routes or import rather than the
  exam module's own paths (design `lib/letflow/design/gh2596-exam-managed-types.md` section 8).
  Strictly read-only. Infra runs it BEFORE the stamp.

  ## Usage

      mix letflow.managed_types_tamper_inventory [--module exam] [--scope runtime|authoring|all]

  Default scope is `runtime` (the six types being stamped). Findings go to stdout only (ids, event
  type, actor id, timestamp, evidence); no field values are ever read.

  In a release (no Mix):
  `bin/letflow rpc "IO.inspect(Letflow.Release.ManagedTypes.tamper_inventory([]))"`.
  """

  use Mix.Task

  alias Letflow.Release.ManagedTypes

  @usage "usage: mix letflow.managed_types_tamper_inventory [--module exam] [--scope runtime|authoring|all]"
  @scopes %{"runtime" => :runtime, "authoring" => :authoring, "all" => :all}

  @impl Mix.Task
  @spec run(argv :: [String.t()]) :: :ok
  def run(argv) do
    opts =
      case OptionParser.parse(argv, strict: [module: :string, scope: :string]) do
        {parsed, [], []} -> parse_scope(parsed)
        _invalid -> Mix.raise(@usage)
      end

    if Keyword.get(opts, :module, "exam") != "exam" do
      Mix.raise("unsupported module (only \"exam\" is supported)\n" <> @usage)
    end

    Mix.Task.run("app.start")

    {:ok, report} = ManagedTypes.tamper_inventory(opts)
    print_report(report)
    :ok
  end

  defp parse_scope(parsed) do
    case Keyword.fetch(parsed, :scope) do
      :error ->
        parsed

      {:ok, scope} ->
        case Map.fetch(@scopes, scope) do
          {:ok, atom} -> Keyword.put(parsed, :scope, atom)
          :error -> Mix.raise(@usage)
        end
    end
  end

  defp print_report(report) do
    Mix.shell().info(
      "tamper inventory (scope #{report.scope}): #{length(report.tenants)} tenant(s), " <>
        "#{report.finding_total} finding(s)"
    )

    Enum.each(report.tenants, fn tenant ->
      skipped = if tenant.skipped, do: " (skipped: #{tenant.skipped})", else: ""
      truncated = if tenant.truncated, do: " (truncated)", else: ""

      Mix.shell().info(
        "  tenant #{tenant.tenant_id || tenant.schema_name}: " <>
          "#{length(tenant.findings)} finding(s)#{truncated}#{skipped}"
      )

      Enum.each(tenant.findings, fn finding ->
        Mix.shell().info(
          "    #{finding.entity_type} #{finding.record_id} #{finding.event_type} " <>
            "actor=#{finding.actor_id} at=#{DateTime.to_iso8601(finding.occurred_at)} " <>
            "evidence=#{finding.evidence}"
        )
      end)
    end)
  end
end
