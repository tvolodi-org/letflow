defmodule Letflow.Engine.ScriptTaskReplayTest do
  @moduledoc """
  GH 2534 PR 7c-1 AC15 (decision 0053 D5, MUST 11; SEC S4; design
  `lib/letflow/design/gh2534-7c-script-handler.md` section 6): replay applies the RECORDED
  script outputs and never runs a script. A definition with TWO CONSECUTIVE script tasks and
  no HTTP task (residual R6) is replayed with the kill switch ON and both versions revoked.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Engine.Reconstruction
  alias Letflow.Support.ScriptPolicyFixture
  alias Letflow.Support.ScriptTaskFixture, as: F

  test "T-R-two-scripts: replay reproduces the state with zero runs, zero script lookups, zero arming" do
    t = F.tenant!("gh2534-7c-replay")
    k2 = "k2#{System.unique_integer([:positive])}"

    rule2 =
      F.published!(
        t.schema_name,
        k2,
        "return { total = ctx.input.amount + 1 }",
        F.closed_manifest()
      )

    b =
      F.bound_graph!(
        t,
        "return { amount = ctx.input.amount * 2 }",
        F.closed_manifest()
        |> put_in(["output_schema", "properties"], %{"amount" => %{"type" => "integer"}})
        |> put_in(["output_schema", "required"], ["amount"]),
        %{"amount" => 5},
        fn k1, v1 -> F.two_script_graph(k1, v1, k2, rule2.version) end,
        []
      )

    # the first script doubles `amount` (5 -> 10); the second writes total = amount + 1
    b_rule1 = b.rule
    {_r1, {:ok, :applied}} = F.run_next!(t.schema_name)
    {_r2, {:ok, :applied}} = F.run_next!(t.schema_name)

    projection = F.projection(t.schema_name, b.instance_id)
    assert projection.status == :completed
    assert projection.variables == %{"amount" => 10, "total" => 11}

    # Replay conditions: the kill switch ON and both versions revoked.
    ScriptPolicyFixture.kill_switch!(t.schema_name, true)
    F.revoke_raw!(t.schema_name, b_rule1)
    F.revoke_raw!(t.schema_name, rule2)
    F.count_runner_calls!()

    test_pid = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:letflow, :repo, :query],
      fn _event, _m, meta, _ ->
        if self() == test_pid, do: send(test_pid, {:query, meta[:query]})
      end,
      nil
    )

    result = Reconstruction.reconstruct_instance(b.instance_id, prefix: t.schema_name)
    :telemetry.detach(handler)

    assert {:ok, %{instance_state: state}} = result
    assert state.variables == projection.variables
    assert Enum.map(state.tokens, & &1.node_id) == projection.current_nodes
    assert state.status == :completed

    refute_received {:script_runner_called, _, _}

    queries = collect_queries([])
    assert queries != []

    for q <- queries do
      refute q =~ "script_rules"
      refute q =~ "script_policy"
      refute q =~ "script_readable_masters"
      refute q =~ ~r/INSERT INTO "[^"]+"\."script_task_dispatches"/
    end
  end

  test "reconstruction.ex source scan: no script runtime reference" do
    source = File.read!("lib/letflow/engine/reconstruction.ex")
    assert source =~ "SCRIPT_TASK_COMPLETED"

    for forbidden <- ["ScriptRunner", "ScriptTaskDispatcher", "ScriptReadPort", "Letflow.Scripts"] do
      refute source =~ forbidden, forbidden
    end
  end

  defp collect_queries(acc) do
    receive do
      {:query, q} when is_binary(q) -> collect_queries([q | acc])
      {:query, _} -> collect_queries(acc)
    after
      0 -> acc
    end
  end
end
