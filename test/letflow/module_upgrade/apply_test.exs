defmodule Letflow.ModuleUpgrade.ApplyTest do
  @moduledoc """
  REQ-770 / T-1396: the pure refusal gate of `Letflow.ModuleUpgrade.Apply.gate/3` (C2..C5) and
  the reader checks of the tenant-id source (T3). No database.
  """

  use ExUnit.Case, async: true

  alias Letflow.ModuleUpgrade.Apply

  @cap 10

  defp row(name, class, reason \\ nil, covered \\ nil),
    do: %{"name" => name, "class" => class, "reason" => reason, "covered_by_steps" => covered}

  defp report(over \\ %{}) do
    Map.merge(
      %{"upgrade_path_available" => true, "entity_types" => [], "steps" => []},
      over
    )
  end

  defp step(id, kind \\ "declarative", op \\ "set_default"),
    do: %{"id" => id, "from" => "1.0.0", "to" => "1.1.0", "kind" => kind, "op" => op}

  test "a path, only class A rows, no steps and no acknowledgement passes" do
    assert Apply.gate(report(%{"entity_types" => [row("t", "A"), row("u", nil)]}), [], @cap) ==
             :ok
  end

  test "C2 a class B row: the acknowledgement must equal the plan's step ids" do
    r =
      report(%{
        "entity_types" => [row("t", "B", "field_removed", true)],
        "steps" => [step("s1"), step("s2")]
      })

    assert {:error, {"ack_mismatch", _}} = Apply.gate(r, [], @cap)
    assert {:error, {"ack_mismatch", _}} = Apply.gate(r, ["s1"], @cap)
    assert {:error, {"ack_mismatch", _}} = Apply.gate(r, ["s1", "s2", "s3"], @cap)
    # an exact set passes the ack check; in-vocabulary steps are runnable (REQ-773)
    assert :ok = Apply.gate(r, ["s2", "s1"], @cap)
  end

  test "C2b an acknowledgement without a class B row is a mismatch" do
    assert {:error, {"ack_mismatch", _}} = Apply.gate(report(), ["s1"], @cap)
  end

  test "C3 a code step or an op outside the executable vocabulary is upgrade_needs_runner" do
    for bad <- [
          step("s1", "code", "code"),
          step("s1", "declarative", "rename_field"),
          step("s1", "declarative", "other")
        ] do
      r = report(%{"steps" => [step("s0"), bad]})
      assert {:error, {"upgrade_needs_runner", %{}}} = Apply.gate(r, [], @cap)
    end

    for op <- ["set_default", "backfill_from_constant", "copy_field"] do
      assert :ok = Apply.gate(report(%{"steps" => [step("s1", "declarative", op)]}), [], @cap)
    end
  end

  test "C3b more records than the cap is upgrade_needs_runner; the cap itself passes" do
    r = report(%{"steps" => [step("s1")]})
    assert :ok = Apply.gate(Map.put(r, "data_step_bound", 10), [], 10)

    assert {:error, {"upgrade_needs_runner", %{}}} =
             Apply.gate(Map.put(r, "data_step_bound", 11), [], 10)
  end

  test "C4 a class B row with no covering step is upgrade_forbidden step_required" do
    r = report(%{"entity_types" => [row("t", "B", "field_removed", false)]})

    assert {:error, {"upgrade_forbidden", %{"reasons" => [reason]}}} = Apply.gate(r, [], @cap)
    assert reason == %{"reason" => "step_required", "subject" => "t"}
  end

  test "a class C row is upgrade_forbidden with its reason code and type name" do
    r = report(%{"entity_types" => [row("t", "C", "type_removed_or_renamed")]})

    assert {:error, {"upgrade_forbidden", %{"reasons" => [reason]}}} = Apply.gate(r, [], @cap)
    assert reason == %{"reason" => "type_removed_or_renamed", "subject" => "t"}
  end

  test "C5 the refusals come in the documented order" do
    everything =
      report(%{
        "upgrade_path_available" => false,
        "entity_types" => [row("c", "C", "owned_by_other"), row("b", "B", "x", false)],
        "steps" => [step("s1")]
      })

    assert {:error, {"no_upgrade_path", _}} = Apply.gate(everything, ["zzz"], @cap)

    path = %{everything | "upgrade_path_available" => true}

    assert {:error, {"upgrade_forbidden", %{"reasons" => [%{"subject" => "c"}]}}} =
             Apply.gate(path, ["zzz"], @cap)

    no_c = %{path | "entity_types" => [row("b", "B", "x", false)]}

    assert {:error, {"upgrade_forbidden", %{"reasons" => [%{"reason" => "step_required"}]}}} =
             Apply.gate(no_c, ["zzz"], @cap)

    covered = %{path | "entity_types" => [row("b", "B", "x", true)]}
    assert {:error, {"ack_mismatch", _}} = Apply.gate(covered, ["zzz"], @cap)
    assert :ok = Apply.gate(covered, ["s1"], @cap)
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
