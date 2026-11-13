defmodule Letflow.Release.Currencies do
  @moduledoc """
  Release-callable entry point of the currency migration (REQ-825, slice C3, design
  `docs/design/currency-directory.md` section 6), in the pattern of
  `Letflow.Release.ExamParentId`: a thin delegate, so a release (no Mix) can run it:

      bin/letflow rpc "IO.inspect(Letflow.Release.Currencies.normalize(dry_run: true))"
      bin/letflow rpc "IO.inspect(Letflow.Release.Currencies.normalize(dry_run: false, actor_id: \\"<operator user id>\\"))"

  Only `dry_run` and `actor_id` are forwarded. QA only: the operator runs it after the deploy, and a
  run on a real tenant is announced to the portfolio manager first. Nothing runs at boot. The
  assets module is reached through `Letflow.Modules.Catalog` (`mix letflow.check_boundaries`, rule 5).
  """

  alias Letflow.Modules.Catalog

  @doc "Runs (or, with `dry_run: true`, only reports) the migration over every tenant with assets."
  @spec normalize(opts :: [dry_run: boolean(), actor_id: String.t()]) :: map()
  def normalize(opts \\ []) when is_list(opts) do
    {:ok, report} = assets_module().currency_migration(Keyword.take(opts, [:dry_run, :actor_id]))
    report
  end

  defp assets_module do
    {:ok, module} = Catalog.fetch("assets")
    module
  end
end
