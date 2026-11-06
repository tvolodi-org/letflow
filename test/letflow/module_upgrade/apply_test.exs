defmodule Letflow.ModuleUpgrade.ApplyTest do
  @moduledoc """
  REQ-770 / T-1396: the pure refusal gate of `Letflow.ModuleUpgrade.Apply.gate/2` (C2..C5) and
  the reader checks of the tenant-id source (T3). No database.
  """

  use ExUnit.Case, async: true

  alias Letflow.ModuleUpgrade.Apply

  defp row(name, class, reason \\ nil, covered \\ nil),
    do: %{"name" => name, "class" => class, "reason" => reason, "covered_by_steps" => covered}

  defp report(over \\ %{}) do
    Map.merge(
      %{"upgrade_path_available" => true, "entity_types" => [], "steps" => []},
      over
    )
  end

  defp step(id), do: %{"id" => id, "from" => "1.0.0", "to" => "1.1.0", "kind" => "declarative"}

  test "a path, only class A rows, no steps and no acknowledgement passes" do
    assert Apply.gate(report(%{"entity_types" => [row("t", "A"), row("u", nil)]}), []) == :ok
  end

  test "C2 a class B row: the acknowledgement must equal the plan's step ids" do
    r =
      report(%{
        "entity_types" => [row("t", "B", "field_removed", true)],
        "steps" => [step("s1"), step("s2")]
      })

    assert {:error, {"ack_mismatch", _}} = Apply.gate(r, [])
    assert {:error, {"ack_mismatch", _}} = Apply.gate(r, ["s1"])
    assert {:error, {"ack_mismatch", _}} = Apply.gate(r, ["s1", "s2", "s3"])
    # an exact set passes the ack check and meets the next rule
    assert {:error, {"upgrade_needs_runner", _}} = Apply.gate(r, ["s2", "s1"])
  end

  test "C2b an acknowledgement without a class B row is a mismatch" do
    assert {:error, {"ack_mismatch", _}} = Apply.gate(report(), ["s1"])
  end

  test "C3 any step is refused as upgrade_needs_runner" do
    r = report(%{"steps" => [step("s1")]})
    assert {:error, {"upgrade_needs_runner", %{}}} = Apply.gate(r, [])
  end

  test "C4 a class B row with no covering step is upgrade_forbidden step_required" do
    r = report(%{"entity_types" => [row("t", "B", "field_removed", false)]})

    assert {:error, {"upgrade_forbidden", %{"reasons" => [reason]}}} = Apply.gate(r, [])
    assert reason == %{"reason" => "step_required", "subject" => "t"}
  end

  test "a class C row is upgrade_forbidden with its reason code and type name" do
    r = report(%{"entity_types" => [row("t", "C", "type_removed_or_renamed")]})

    assert {:error, {"upgrade_forbidden", %{"reasons" => [reason]}}} = Apply.gate(r, [])
    assert reason == %{"reason" => "type_removed_or_renamed", "subject" => "t"}
  end

  test "C5 the refusals come in the documented order" do
    everything =
      report(%{
        "upgrade_path_available" => false,
        "entity_types" => [row("c", "C", "owned_by_other"), row("b", "B", "x", false)],
        "steps" => [step("s1")]
      })

    assert {:error, {"no_upgrade_path", _}} = Apply.gate(everything, ["zzz"])

    path = %{everything | "upgrade_path_available" => true}

    assert {:error, {"upgrade_forbidden", %{"reasons" => [%{"subject" => "c"}]}}} =
             Apply.gate(path, ["zzz"])

    no_c = %{path | "entity_types" => [row("b", "B", "x", false)]}

    assert {:error, {"upgrade_forbidden", %{"reasons" => [%{"reason" => "step_required"}]}}} =
             Apply.gate(no_c, ["zzz"])

    covered = %{path | "entity_types" => [row("b", "B", "x", true)]}
    assert {:error, {"ack_mismatch", _}} = Apply.gate(covered, ["zzz"])
    assert {:error, {"upgrade_needs_runner", _}} = Apply.gate(covered, ["s1"])
  end

  test "T3 the tenant comes from opts[:prefix] only; the body is not asked for a tenant" do
    source = File.read!("lib/letflow/module_upgrade/apply.ex")

    refute source =~ "tenant_id"
    refute source =~ "body_params"
    refute source =~ ~r/params\[/
    assert source =~ "Keyword.fetch!(opts, :prefix)"

    for key <- ["rationale", "plan_hash", "ack_destructive"] do
      assert source =~ "Map.get(params, \"" <> key <> "\"", key
    end

    # the global-table writers it reaches derive the tenant from the schema name
    assert File.read!("lib/letflow/audit.ex") =~ "tenant_id_for_schema_name"
    assert File.read!("lib/letflow/definitions/solution_pack.ex") =~ "tenant_id_for_schema_name"
  end
end
