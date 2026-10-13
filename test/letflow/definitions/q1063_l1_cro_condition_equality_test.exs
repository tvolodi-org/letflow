defmodule Letflow.Definitions.Q1063L1CroConditionEqualityTest do
  @moduledoc """
  Q-1063 / GH #2416 (ISS-1066) -- the L1 CRO escalation node `escalate-l1-approval-to-cro`
  (Q-1051 / ISS-1051) copies `l1-approval`'s conditioned outgoing edges by hand, in the QA
  definition and in its simulation copy. Nothing else ties the two sets together, so a later
  edit to one set could silently make the L1 CRO path decide differently from the L1 path.

  This test pins the two conditioned edge sets equal, by condition string and target, for both
  the QA JSON and the simulation YAML. Unconditioned edges (the timeout and fallback edges) are
  excluded on purpose: they are the engine's timer path, not the approve / escalate / reject
  decision that the two nodes share. Both sides must be non-empty, so the check cannot pass
  vacuously. Pure file I/O, no DB.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  @fixtures Path.expand("../../fixtures", __DIR__)

  @defs [
    %{
      label: "loan (QA JSON)",
      kind: :json,
      path: Path.join(@fixtures, "qa/meridian_loan_origination_process_definition.json")
    },
    %{
      label: "loan (simulation YAML)",
      kind: :yaml,
      path: Path.join(@fixtures, "simulation/meridian/process_claim_intake.yaml")
    }
  ]

  for d <- @defs do
    test "#{d.label}: the L1 CRO node's conditioned edges equal l1-approval's, by condition and target" do
      doc = load(unquote(Macro.escape(d)))

      l1 = conditioned_edges(doc, "l1-approval")
      cro = conditioned_edges(doc, "escalate-l1-approval-to-cro")

      assert l1 != [], "l1-approval has no conditioned outgoing edges to compare"
      assert cro != [], "escalate-l1-approval-to-cro has no conditioned outgoing edges to compare"

      assert cro == l1,
             "escalate-l1-approval-to-cro's conditioned edges diverge from l1-approval's " <>
               "(condition, target): l1-approval #{inspect(l1)} vs CRO node #{inspect(cro)}"
    end
  end

  defp load(%{kind: :json, path: path}), do: path |> File.read!() |> Jason.decode!()
  defp load(%{kind: :yaml, path: path}), do: YamlElixir.read_from_file!(path)

  # Conditioned outgoing edges of one node, as sorted {condition, target} pairs.
  defp conditioned_edges(doc, node_id) do
    doc
    |> edges()
    |> Enum.filter(&(&1["source"] == node_id))
    |> Enum.reject(&is_nil(&1["condition"]))
    |> Enum.map(&{&1["condition"], &1["target"]})
    |> Enum.sort()
  end

  defp edges(doc), do: get_in(doc, ["graph", "edges"]) || []
end
