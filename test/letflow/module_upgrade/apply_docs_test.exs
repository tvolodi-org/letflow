defmodule Letflow.ModuleUpgrade.ApplyDocsTest do
  @moduledoc """
  REQ-770 / T-1396 (D1): the runbooks name the upgrade action. Pure file reads.
  """

  use ExUnit.Case, async: true

  test "D1 the Recovery section names the upgrade action, not a revert" do
    doc = File.read!("docs/runbooks/module-write-handlers-manifest-hash.md")
    [_, recovery] = String.split(doc, "## Recovery", parts: 2)
    [recovery | _] = String.split(recovery, "## Related", parts: 2)

    assert recovery =~ "/upgrade"
    assert recovery =~ "plan_hash"
    refute recovery =~ "revert the deploy"
  end

  test "D1b the WMS runbook item 11 names the plan and apply routes" do
    doc = File.read!("docs/runbooks/wms-foundation.md")
    [_, item] = String.split(doc, "11. **Tenants that installed org before 0.2.0", parts: 2)
    [item | _] = String.split(item, "12. **", parts: 2)

    assert item =~ "/upgrade/plan"
    assert item =~ "Letflow.ModuleUpgrade.Apply"
  end
end
