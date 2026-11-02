defmodule Letflow.Support.Req290CapabilityCheckTest do
  @moduledoc """
  REQ-290 AC3: proves the fail-loud / not-skip / not-guess client-behaviour contract
  (`req289-expr-conformance-corpus.md` §13) by distinguishing three outcomes
  explicitly on the SAME incompatible input — not merely asserting
  "succeeds/fails" in the abstract.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Support.Req290CapabilityCheck, as: CapabilityCheck

  describe "compatible manifest" do
    test "evaluation proceeds and returns the thunk's own {:ok, _}" do
      client_caps = MapSet.new(["cmp:eq", "lit:integer", "var:simple"])
      manifest_caps = ["cmp:eq", "lit:integer"]

      assert :compatible = CapabilityCheck.check_compatibility(client_caps, manifest_caps)

      assert {:ok, 42} =
               CapabilityCheck.evaluate_or_fail(:compatible, fn -> {:ok, 42} end)
    end
  end

  describe "incompatible manifest" do
    test "fails loudly with the specific unsupported tag(s), never :ok, and never runs the thunk" do
      client_caps = MapSet.new(["cmp:eq", "lit:integer", "var:simple"])
      manifest_caps = ["cmp:eq", "builtin:regexMatch"]

      assert {:incompatible, ["builtin:regexMatch"]} =
               CapabilityCheck.check_compatibility(client_caps, manifest_caps)

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      thunk = fn ->
        Agent.update(counter, &(&1 + 1))
        {:ok, :should_never_be_reached}
      end

      result =
        CapabilityCheck.evaluate_or_fail({:incompatible, ["builtin:regexMatch"]}, thunk)

      assert {:error, {:stale_version, ["builtin:regexMatch"]}} = result
      assert Agent.get(counter, & &1) == 0, "evaluate_thunk must never run on the fail-loud path"

      Agent.stop(counter)
    end

    test "the incompatible case is neither a silent-skip shape nor a silent-guess shape" do
      client_caps = MapSet.new(["cmp:eq", "lit:integer", "var:simple"])
      manifest_caps = ["cmp:eq", "builtin:regexMatch"]

      compatibility = CapabilityCheck.check_compatibility(client_caps, manifest_caps)
      result = CapabilityCheck.evaluate_or_fail(compatibility, fn -> {:ok, :unreachable} end)

      # Not a silent skip: no :skip atom is ever producible by evaluate_or_fail/2's
      # closed @spec -- asserted operationally here, not only inferred from the type.
      refute match?(:skip, result)

      # Not a silent guess: the SAME incompatible input that produced
      # {:error, {:stale_version, _}} above must never also be able to produce
      # {:ok, _} -- ruled out by measurement on the actual return value.
      refute match?({:ok, _}, result)

      assert match?({:error, {:stale_version, _}}, result)
    end
  end
end
