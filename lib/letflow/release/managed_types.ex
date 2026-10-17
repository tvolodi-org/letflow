defmodule Letflow.Release.ManagedTypes do
  @moduledoc """
  Release-callable entry points for the exam managed-type stamp and its read-only tamper inventory
  (GH #2596; design `lib/letflow/design/gh2596-exam-managed-types.md` section 6.4).

  `Letflow.Release` (#2567) is not on main yet; this is the one wrapper GH #2596 needs, in the same
  pattern as `Letflow.Identity.RoleScopeGrants.Backfill` plus its Mix task: thin delegates, so a
  release (no Mix) can run them:

      bin/letflow rpc "IO.inspect(Letflow.Release.ManagedTypes.stamp(dry_run: true))"
      bin/letflow rpc "IO.inspect(Letflow.Release.ManagedTypes.tamper_inventory([]))"

  Only `module` and `dry_run` (stamp) or `module` and `scope` (inventory) are forwarded; every other
  key is dropped, so no test seam or tuning option can be passed from a release call. Per the
  rollout in the design, infra runs the inventory first, then the stamp dry run, and requests the
  real stamp only after the session-content-snapshot prerequisite has landed.

  A real `stamp/1` returns `{:error, :snapshot_not_complete}` and stamps nothing while the flag
  `:exam_snapshot_complete` is not `true` (GH #2682 / REQ-511, design 18.3), and with the flag open
  it still stamps only tenants that passed the exam snapshot rollout (per-tenant status
  `:snapshot_prerequisite_missing` otherwise); `dry_run: true` always runs.
  """

  alias Letflow.Entities.ManagedTypes.Stamp
  alias Letflow.Entities.ManagedTypes.TamperInventory

  @doc "Stamps (or with `dry_run: true`, reports) the exam module's six runtime types in every tenant."
  @spec stamp(opts :: [module: String.t(), dry_run: boolean()]) ::
          {:ok, Stamp.report()} | {:error, :unsupported_module | :snapshot_not_complete}
  def stamp(opts) when is_list(opts), do: opts |> Keyword.take([:module, :dry_run]) |> Stamp.run()

  @doc "The read-only tamper inventory (default scope `:runtime`)."
  @spec tamper_inventory(opts :: [module: String.t(), scope: TamperInventory.scope()]) ::
          {:ok, TamperInventory.report()}
  def tamper_inventory(opts) when is_list(opts),
    do: opts |> Keyword.take([:module, :scope]) |> TamperInventory.run()
end
