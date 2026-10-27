defmodule Letflow.Release.ExamParentId do
  @moduledoc """
  Release-callable entry points for the exam `parent_id` rollout (GH #3315 / REQ-586 part C), in
  the same pattern as `Letflow.Release.ExamSnapshot`: thin delegates, so a release (no Mix) can
  run them:

      bin/letflow rpc "IO.inspect(Letflow.Release.ExamParentId.rollout(dry_run: true))"
      bin/letflow rpc "IO.inspect(Letflow.Release.ExamParentId.rollout(dry_run: false))"
      bin/letflow rpc "IO.inspect(Letflow.Release.ExamParentId.verify())"

  Only `dry_run` is forwarded to the rollout; every other key is dropped. Run it once per
  environment after the deploy of part A: a tenant that installed the pack earlier keeps its old
  `category` and `question` definitions until it has run.

  The exam module's own code is reached through `Letflow.Modules.Catalog`, the one sanctioned
  route into a module directory (`mix letflow.check_boundaries`, rule 5).
  """

  alias Letflow.Modules.Catalog

  @type report :: %{
          dry_run: boolean(),
          tenants: [map()],
          upgraded_total: non_neg_integer(),
          conflict_total: non_neg_integer(),
          failed_total: non_neg_integer()
        }

  @type tenant_check :: %{schema_name: String.t(), category: boolean(), question: boolean()}

  @doc "Runs (or, with `dry_run: true`, only reports) the rollout over every tenant."
  @spec rollout(opts :: [dry_run: boolean()]) :: report()
  def rollout(opts \\ []) when is_list(opts) do
    {:ok, report} = exam_module().parent_rollout(Keyword.take(opts, [:dry_run]))
    report
  end

  @doc """
  Read-only readiness check: per exam-installed tenant, whether `category` and `question` have the
  `parent_id` definition, a complete promotion and the index. `ready` is true when all do.
  """
  @spec verify() :: %{ready: boolean(), tenants: [tenant_check()]}
  def verify, do: exam_module().parent_rollout_verify()

  defp exam_module do
    {:ok, module} = Catalog.fetch("exam")
    module
  end
end
