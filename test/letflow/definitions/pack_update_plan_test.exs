defmodule Letflow.Definitions.PackUpdatePlanTest do
  use ExUnit.Case, async: true

  alias Letflow.Definitions
  alias Letflow.Definitions.PackUpdatePlan

  test "PK2 Definitions keeps the pack-update plan API as delegates" do
    Code.ensure_loaded!(Definitions)
    assert function_exported?(Definitions, :compute_pack_update_plan, 5)
    assert function_exported?(Definitions, :blocking_conflict?, 1)
    assert function_exported?(Definitions, :classify_artefact, 3)
  end

  test "PK2 delegate and PackUpdatePlan agree on the truth table" do
    cases = [
      {nil, "a", "a", :conflict},
      {"a", "a", "a", :unchanged},
      {"a", "a", "b", :clean_update},
      {"a", "b", "a", :local_only},
      {"a", "b", "c", :conflict}
    ]

    for {base, theirs, incoming, expected} <- cases do
      assert Definitions.classify_artefact(base, theirs, incoming) == expected
      assert PackUpdatePlan.classify_artefact(base, theirs, incoming) == expected
    end
  end

  test "PK2 empty artefact set and blocking predicate delegate" do
    assert Definitions.compute_pack_update_plan(Ecto.UUID.generate(), "p", "1", [], []) ==
             {:error, :empty_artefact_set}

    entry = %{classification: :conflict, resolved: false, override: nil}
    assert Definitions.blocking_conflict?(entry)
    refute Definitions.blocking_conflict?(%{entry | resolved: true})
  end
end
