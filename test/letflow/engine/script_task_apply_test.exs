defmodule Letflow.Engine.ScriptTaskApplyTest do
  @moduledoc """
  GH 2534 PR 7c-1 (design `lib/letflow/design/gh2534-7c-script-handler.md` 5.3 step 8, 5.4,
  8.1, 8.2; C4, C11, C11a): the apply transaction's CAS (AC6), the output rules -- only
  declared keys merged (AC2b), output schema / variable schema / non-object outputs (AC9) and
  the `$` write-channel fence (AC10).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Engine
  alias Letflow.Engine.ScriptTaskDispatcher
  alias Letflow.Support.ScriptTaskFixture, as: F

  setup do
    %{t: F.tenant!("gh2534-7c-apply")}
  end

  # input {amount, add_extra, attempt_write}, output CLOSED {total}
  defp manifest do
    F.closed_manifest()
    |> put_in(["input_schema", "properties", "add_extra"], %{"type" => "boolean"})
    |> put_in(["input_schema", "properties", "attempt_write"], %{"type" => "boolean"})
  end

  @extra_source """
  local out = { total = ctx.input.amount }
  if ctx.input.add_extra then out.approval_tier = "board" end
  if ctx.input.attempt_write then
    out["$writes"] = { { entity_type = "purchase_order", command = "create" } }
  end
  return out
  """

  defp snapshot(t, instance_id) do
    %{
      events: F.event_types(t.schema_name, instance_id),
      variables: F.projection(t.schema_name, instance_id).variables,
      status: F.projection(t.schema_name, instance_id).status,
      rows:
        Enum.map(
          F.rows(t.schema_name, instance_id),
          &Map.take(&1, [:status, :attempt, :outcome, :outcome_detail, :updated_at])
        ),
      dlq: F.dlq_count(t.schema_name)
    }
  end

  defp success_result(row, output) do
    {:ok, output,
     %{row: row, phase: :ran, outcome: :ok, detail: nil, fail_code: nil, hmac: nil, stats: nil}}
  end

  # ── AC2b ────────────────────────────────────────────────────────────────────

  describe "AC2b (SEC S1)" do
    test "undeclared key refused, the targeted variable unchanged", %{t: t} do
      b =
        F.bound!(t, @extra_source, manifest(), %{
          "amount" => 5,
          "add_extra" => true,
          "approval_tier" => "auto"
        })

      {row, result} = F.run_next!(t.schema_name)
      assert result == {:ok, :failed}
      done = F.reload(t.schema_name, row)
      assert {done.outcome, done.outcome_detail} == {"output_invalid", "output_schema"}

      variables = F.projection(t.schema_name, b.instance_id).variables
      assert variables["approval_tier"] == "auto"
      refute Map.has_key?(variables, "total")
    end

    test "only declared keys merged", %{t: t} do
      initial = %{"amount" => 5, "add_extra" => false, "approval_tier" => "auto"}
      b = F.bound!(t, @extra_source, manifest(), initial)
      assert {_row, {:ok, :applied}} = F.run_next!(t.schema_name)

      variables = F.projection(t.schema_name, b.instance_id).variables
      assert Map.keys(variables) -- Map.keys(initial) == ["total"]
      assert variables["total"] == 5
    end
  end

  # ── AC6 ─────────────────────────────────────────────────────────────────────

  describe "AC6 (F-E): the CAS" do
    test "T-CAS-dup: a second apply of the same result is stale and changes nothing", %{t: t} do
      b = F.bound!(t, F.doubling_source(), manifest(), %{"amount" => 2})
      {:ok, row} = ScriptTaskDispatcher.claim_next(t.schema_name)
      result = success_result(row, %{"total" => 4})

      assert Engine.apply_script_task_result(F.claim(row), result, t.schema_name) ==
               {:ok, :applied}

      before = snapshot(t, b.instance_id)

      assert Engine.apply_script_task_result(F.claim(row), result, t.schema_name) ==
               {:ok, :stale}

      assert snapshot(t, b.instance_id) == before
    end

    test "T-CAS-old-attempt: an apply keyed by an older attempt is stale", %{t: t} do
      b = F.bound!(t, F.doubling_source(), manifest(), %{"amount" => 2})
      holders = F.hold_all_slots!(t.schema_name)
      {first, {:ok, :rescheduled}} = F.run_next!(t.schema_name)
      Enum.each(holders, &Process.exit(&1, :kill))
      assert F.eventually(fn -> F.slots_in_use(t.schema_name) == 0 end, 100)
      F.make_due!(t.schema_name, F.reload(t.schema_name, first))
      {:ok, second} = ScriptTaskDispatcher.claim_next(t.schema_name)
      assert {first.attempt, second.attempt} == {1, 2}

      before = snapshot(t, b.instance_id)

      assert Engine.apply_script_task_result(
               F.claim(first),
               success_result(first, %{"total" => 999}),
               t.schema_name
             ) == {:ok, :stale}

      assert snapshot(t, b.instance_id) == before
      assert ScriptTaskDispatcher.run_claimed(second, t.schema_name) == {:ok, :applied}
      assert F.projection(t.schema_name, b.instance_id).variables["total"] == 4
    end

    test "T-CAS-after-sweep: an apply after the lease sweep is stale", %{t: t} do
      b = F.bound!(t, F.doubling_source(), manifest(), %{"amount" => 2})
      {:ok, row} = ScriptTaskDispatcher.claim_next(t.schema_name)
      F.expire_lease!(t.schema_name, row)
      assert %{swept: 1} = ScriptTaskDispatcher.sweep_expired_leases(t.schema_name, 64)
      before = snapshot(t, b.instance_id)

      assert Engine.apply_script_task_result(
               F.claim(row),
               success_result(row, %{"total" => 4}),
               t.schema_name
             ) == {:ok, :stale}

      assert snapshot(t, b.instance_id) == before
      assert before.status == :error
    end
  end

  # ── AC9 ─────────────────────────────────────────────────────────────────────

  describe "AC9" do
    test "output_schema", %{t: t} do
      b = F.bound!(t, "return { total = 'x' }", manifest(), %{"amount" => 2})
      dlq_before = F.dlq_count(t.schema_name)
      {row, {:ok, :failed}} = F.run_next!(t.schema_name)
      done = F.reload(t.schema_name, row)
      assert {done.outcome, done.outcome_detail} == {"output_invalid", "output_schema"}
      assert F.projection(t.schema_name, b.instance_id).status == :error
      assert F.dlq_count(t.schema_name) == dlq_before + 1
    end

    test "variable_schema_rejected", %{t: t} do
      schemas = [%{variable_key: "total", json_schema: %{"type" => "integer", "maximum" => 10}}]

      b =
        F.bound_graph!(
          t,
          F.doubling_source(),
          manifest(),
          %{"amount" => 21},
          &F.script_graph/2,
          schemas
        )

      {row, {:ok, :failed}} = F.run_next!(t.schema_name)
      done = F.reload(t.schema_name, row)
      assert {done.outcome, done.outcome_detail} == {"output_invalid", "variable_schema_rejected"}

      projection = F.projection(t.schema_name, b.instance_id)
      assert projection.status == :error
      assert projection.variables == %{"amount" => 21}

      [record] = F.payloads(t.schema_name, b.instance_id, "SCRIPT_RUN_RECORDED")
      assert record["detail"] == "variable_schema_rejected"
      # the rejected value (42) is recorded nowhere in the run record
      refute 42 in Map.values(record)
    end

    test "output_not_object", %{t: t} do
      b = F.bound!(t, "return { 1, 2, 3 }", manifest(), %{"amount" => 2})
      {row, {:ok, :failed}} = F.run_next!(t.schema_name)
      done = F.reload(t.schema_name, row)
      assert {done.outcome, done.outcome_detail} == {"output_invalid", "output_not_object"}
      assert F.projection(t.schema_name, b.instance_id).status == :error
    end
  end

  # ── AC10 ────────────────────────────────────────────────────────────────────

  describe "AC10 (fence)" do
    test "T-writes-refused: a top-level `$` key is writes_not_allowed, nothing changed", %{t: t} do
      count_entities = fn ->
        Repo.aggregate("entity_record_latest", :count, prefix: t.schema_name)
      end

      entities_before = count_entities.()

      b =
        F.bound!(t, @extra_source, manifest(), %{
          "amount" => 7,
          "attempt_write" => true,
          "approval_tier" => "auto"
        })

      {row, {:ok, :failed}} = F.run_next!(t.schema_name)
      done = F.reload(t.schema_name, row)
      # the `$` check runs BEFORE the schema check
      assert {done.outcome, done.outcome_detail} == {"output_invalid", "writes_not_allowed"}

      assert F.projection(t.schema_name, b.instance_id).variables == %{
               "amount" => 7,
               "attempt_write" => true,
               "approval_tier" => "auto"
             }

      assert count_entities.() == entities_before
    end

    test "check_output/2 order and nested `$` keys (pure)" do
      m = manifest()
      assert Letflow.Scripts.Runtime.check_output([1], m) == {:error, :output_not_object}

      assert Letflow.Scripts.Runtime.check_output(%{"$x" => 1}, m) ==
               {:error, :writes_not_allowed}

      assert Letflow.Scripts.Runtime.check_output(%{"$writes" => [], "total" => "x"}, m) ==
               {:error, :writes_not_allowed}

      assert Letflow.Scripts.Runtime.check_output(%{"total" => 1, "extra" => 2}, m) ==
               {:error, :output_schema}

      assert Letflow.Scripts.Runtime.check_output(%{"total" => 1}, m) == {:ok, %{"total" => 1}}

      # the undeclared-key refusal stands on its own, even where the schema would admit the key
      open = update_in(m, ["output_schema"], &Map.delete(&1, "additionalProperties"))

      assert Letflow.Scripts.Runtime.check_output(%{"total" => 1, "extra" => 2}, open) ==
               {:error, :output_schema}

      refute Letflow.Scripts.Runtime.writes_key?(%{"total" => %{"$nested" => 1}})
    end
  end
end
