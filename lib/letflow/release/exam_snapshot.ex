defmodule Letflow.Release.ExamSnapshot do
  @moduledoc """
  Release-callable entry points for the exam content snapshot rollout (GH #2682 / REQ-511; design
  `lib/letflow/design/req511-exam-content-snapshot.md` sections 10.3 and 17.2), in the same pattern
  as `Letflow.Release.ManagedTypes`: thin delegates, so a release (no Mix) can run them:

      bin/letflow rpc "IO.inspect(Letflow.Release.ExamSnapshot.rollout(dry_run: false))"
      bin/letflow rpc "IO.inspect(Letflow.Release.ExamSnapshot.verify())"

  Only `dry_run` is forwarded to the rollout; every other key is dropped, so no tuning or test
  option can be passed from a release call. Run the rollout right after the deploy of the code
  that reads the snapshot; until it has run, an exam start answers 503 (design 9.3).

  The exam module's own code is reached through `Letflow.Modules.Catalog`, the one sanctioned
  route into a module directory (`mix letflow.check_boundaries`, rule 5), exactly as
  `Letflow.Entities.ManagedTypes.Stamp` reaches the exam manifest.
  """

  alias Letflow.Modules.Catalog

  @type report :: %{
          dry_run: boolean(),
          tenants: [map()],
          upgraded_total: non_neg_integer(),
          conflict_total: non_neg_integer(),
          failed_total: non_neg_integer(),
          restrictions_added_total: non_neg_integer()
        }

  @type tenant_check :: %{
          schema_name: String.t(),
          session_definition: boolean(),
          answer_key_restrictions: boolean()
        }

  @doc "Runs (or, with `dry_run: true`, only reports) the rollout over every tenant."
  @spec rollout(opts :: [dry_run: boolean()]) :: report()
  def rollout(opts \\ []) when is_list(opts) do
    {:ok, report} = exam_module().snapshot_rollout(Keyword.take(opts, [:dry_run]))
    report
  end

  @doc """
  Read-only readiness check: for every exam-installed tenant, whether its active `session`
  definition declares `exam_snapshot` and whether all answer-key restriction rows exist. `ready`
  is true when every such tenant has both.
  """
  @spec verify() :: %{ready: boolean(), tenants: [tenant_check()]}
  def verify, do: exam_module().snapshot_verify()

  defp exam_module do
    {:ok, module} = Catalog.fetch("exam")
    module
  end
end
