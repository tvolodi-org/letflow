defmodule Letflow.Engine.CompleteTaskFormHookAuditTest do
  @moduledoc """
  REQ-632 / GH #3524 (decision 0067 D9, slice F-4 part B): the `task.form_hook_run` audit row of
  `Engine.complete_task/3`. Tests F4B-01..12 of the T-0966 design. One row per hook run: an accepted
  run writes it inside the completion transaction, a refused or failed run after the rollback; the
  audit-failure policy (a failed post-rollback write is logged and never changes the answer, a
  failed accepted-row write aborts the completion). `async: false` (tenant provisioning,
  application env, DDL on the test tenant's schema). A stub runner stands in for the sandbox.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit
  alias Letflow.Engine
  alias Letflow.Scripts.HmacSecret
  alias Letflow.Support.ScriptTaskFixture, as: F

  @secret_value "TOPSECRET-4242"
  @row_keys ~w(script_key script_version script_sha256 input_hmac input_hmac_key_version outcome
               duration_us instructions_used heap_words_at_end)

  defmodule StubRunner do
    @moduledoc false
    # Replies are consumed one per call; the last one repeats.
    def start, do: Agent.start_link(fn -> %{calls: 0, replies: []} end, name: __MODULE__)

    def stop do
      Agent.stop(__MODULE__)
    catch
      :exit, _already_gone -> :ok
    end

    def replies(list), do: Agent.update(__MODULE__, &%{&1 | replies: list})
    def calls, do: Agent.get(__MODULE__, & &1.calls)

    def run(_source, _input, _opts) do
      Agent.get_and_update(__MODULE__, fn %{calls: n, replies: replies} = state ->
        {reply, rest} =
          case replies do
            [last] -> {last, [last]}
            [head | tail] -> {head, tail}
          end

        {reply, %{state | calls: n + 1, replies: rest}}
      end)
      |> case do
        :raise -> raise "stub runner failure"
        reply -> reply
      end
    end
  end

  defp manifest do
    %{
      "input_schema" => %{
        "type" => "object",
        "properties" => %{"amount" => %{"type" => "integer"}, "note" => %{"type" => "string"}}
      },
      "output_schema" => %{
        "type" => "object",
        "properties" => %{
          "ok" => %{"type" => "boolean"},
          "code" => %{"type" => "string"},
          "fields" => %{"type" => "array"}
        },
        "additionalProperties" => false
      },
      "fail_codes" => [],
      "refusal_codes" => ["too_small"],
      "fields" => ["amount", "note"],
      "limits" => %{"timeout_ms" => 50}
    }
  end

  defp stats, do: %{duration_us: 7, instructions_used: 3, heap_words_at_end: 9}
  defp accept, do: {:ok, %{output: %{"ok" => true}, stats: stats()}}
  defp busy, do: {:error, :script_busy, %{}}

  defp refuse do
    {:ok,
     %{
       output: %{
         "ok" => false,
         "code" => "too_small",
         "fields" => [%{"field" => "amount", "code" => "too_small"}]
       },
       stats: stats()
     }}
  end

  defp set_env(key, value) do
    previous = Application.fetch_env(:letflow, key)
    Application.put_env(:letflow, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:letflow, key, old)
        :error -> Application.delete_env(:letflow, key)
      end
    end)
  end

  defp graph(attributes) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "review",
          "node_type" => "HUMAN_TASK",
          "attributes" => Map.put(attributes, "role", "REVIEWER")
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "review"},
        %{"id" => "e2", "source" => "review", "target" => "end"}
      ]
    }
  end

  defp hook_attrs(rule),
    do: %{"validation_script_key" => rule.key, "validation_script_version" => rule.version}

  defp start!(t, attributes, schemas \\ []) do
    definition = F.definition!(t.schema_name, graph(attributes), schemas)
    F.start!(t.schema_name, definition, %{}, Ecto.UUID.generate())
  end

  defp pending_task!(t, instance_id) do
    Repo.one!(
      from(x in Letflow.Engine.Task,
        where: x.instance_id == ^instance_id and x.status == :pending
      ),
      prefix: t.schema_name
    )
  end

  defp complete(t, instance_id, output \\ %{"amount" => 5}) do
    task = pending_task!(t, instance_id)
    actor = Ecto.UUID.generate()

    Engine.complete_task(
      task.id,
      %{output_variables: output, actor_id: actor, idempotency_key: "f4b-#{actor}"},
      prefix: t.schema_name
    )
  end

  defp actions(t, action) do
    Repo.all(
      from(a in Audit.Entry, where: a.action == ^action, order_by: a.timestamp),
      prefix: t.schema_name
    )
  end

  defp hook_rows(t), do: actions(t, "task.form_hook_run")

  defp assert_row(row, outcome) do
    assert Enum.sort(Map.keys(row.after_state)) == Enum.sort(@row_keys)
    assert row.after_state["outcome"] == outcome
    assert row.resource_type == "task"
    assert is_nil(row.before_state)
  end

  defp add_constraint!(t, table, name, check) do
    Repo.query!(
      "ALTER TABLE \"#{t.schema_name}\".\"#{table}\" ADD CONSTRAINT #{name} CHECK (#{check}) NOT VALID"
    )
  end

  # The published script row is immutable (LF001 triggers): the pin problems are provoked with the
  # triggers off for the one statement (the sandbox transaction is rolled back at the end).
  defp raw_row_change!(t, sql) do
    Repo.query!(~s(ALTER TABLE "#{t.schema_name}".script_rules DISABLE TRIGGER USER))
    Repo.query!(sql)
    Repo.query!(~s(ALTER TABLE "#{t.schema_name}".script_rules ENABLE TRIGGER USER))
  end

  defp status!(t, instance_id), do: pending_task!(t, instance_id).status

  setup do
    t = F.tenant!("f4b")
    set_env(:form_validation_hook_enabled, true)
    {:ok, _pid} = StubRunner.start()
    on_exit(&StubRunner.stop/0)
    set_env(:form_validation_script_runner, StubRunner)
    StubRunner.replies([accept()])

    rule =
      F.published!(t.schema_name, "fv_f4b", "return { ok = true }", manifest(),
        hook_kind: "form_validation"
      )

    %{t: t, rule: rule}
  end

  describe "one row per run (criterion 5)" do
    test "F4B-01 an accepted run writes exactly one row inside the completion", %{
      t: t,
      rule: rule
    } do
      id = start!(t, hook_attrs(rule))
      task_id = pending_task!(t, id).id

      assert {:ok, _} = complete(t, id)
      assert [row] = hook_rows(t)
      assert_row(row, "accepted")
      assert row.resource_id == task_id
      assert is_binary(row.actor_id)
      assert row.after_state["script_key"] == rule.key
      assert row.after_state["script_version"] == rule.version
      assert row.after_state["script_sha256"] == rule.sha256
      assert row.after_state["duration_us"] == 7
      assert row.after_state["instructions_used"] == 3
      assert row.after_state["heap_words_at_end"] == 9
      assert is_binary(row.after_state["input_hmac"])
      assert is_integer(row.after_state["input_hmac_key_version"])
    end

    test "F4B-02 a refusing verdict writes one row after the rollback, without the verdict",
         %{t: t, rule: rule} do
      StubRunner.replies([refuse()])
      id = start!(t, hook_attrs(rule))

      assert {:error, {:form_hook_refused, %{code: "too_small"}}} = complete(t, id)
      assert status!(t, id) == :pending
      assert [row] = hook_rows(t)
      assert_row(row, "refused")
      refute inspect(row) =~ "too_small"
      refute inspect(row) =~ "amount"
    end

    for code <- [:script_error, :budget_exceeded, :memory_limit_exceeded, :timeout, :script_busy] do
      test "F4B-03 #{code}: one row, outcome #{code}", %{t: t, rule: rule} do
        StubRunner.replies([{:error, unquote(code), %{}}])
        id = start!(t, hook_attrs(rule))

        assert {:error, {:form_hook_failed, unquote(code)}} = complete(t, id)
        assert status!(t, id) == :pending
        assert [row] = hook_rows(t)
        assert_row(row, Atom.to_string(unquote(code)))

        # The runner reported no instructions or heap: stored as 0; the duration is the measured one.
        assert is_integer(row.after_state["duration_us"]) and row.after_state["duration_us"] >= 0
        assert row.after_state["instructions_used"] == 0
        assert row.after_state["heap_words_at_end"] == 0
        assert is_binary(row.after_state["input_hmac"])
      end
    end

    test "F4B-03 output_invalid: one row", %{t: t, rule: rule} do
      StubRunner.replies([{:ok, %{output: %{"ok" => "yes"}, stats: stats()}}])
      id = start!(t, hook_attrs(rule))

      assert {:error, {:form_hook_failed, :output_invalid}} = complete(t, id)
      assert [row] = hook_rows(t)
      assert_row(row, "output_invalid")
      assert row.after_state["instructions_used"] == 3
    end

    test "F4B-03k the kill switch: no run, one script_rejected row of zeros", %{t: t, rule: rule} do
      id = start!(t, hook_attrs(rule))
      set_env(:form_validation_hook_enabled, false)

      assert {:error, {:form_hook_failed, :script_rejected}} = complete(t, id)
      assert StubRunner.calls() == 0
      assert [row] = hook_rows(t)
      assert_row(row, "script_rejected")
      assert row.after_state["duration_us"] == 0
      assert row.after_state["instructions_used"] == 0
      assert row.after_state["heap_words_at_end"] == 0
      assert row.after_state["input_hmac"] == nil
      assert row.after_state["input_hmac_key_version"] == nil
      assert row.after_state["script_sha256"] == rule.sha256
    end

    test "F4B-03p an unresolved pin: one script_rejected row without a sha256", %{
      t: t,
      rule: rule
    } do
      id = start!(t, hook_attrs(rule))

      # The snapshot node and the INSTANCE_STARTED pin are written together; a hand-edited snapshot
      # (as in F-3 test T2b) is the only way to make them disagree, which leaves the pin unresolved.
      snapshot =
        Repo.get!(Letflow.Definitions.InstanceDefinitionSnapshot, id, prefix: t.schema_name)

      graph =
        update_in(snapshot.graph, ["nodes"], fn nodes ->
          Enum.map(nodes, fn
            %{"id" => "review"} = node ->
              put_in(node, ["attributes", "validation_script_version"], rule.version + 5)

            node ->
              node
          end)
        end)

      snapshot |> Ecto.Changeset.change(graph: graph) |> Repo.update!(prefix: t.schema_name)

      assert {:error, {:form_hook_failed, :script_rejected}} = complete(t, id)
      assert StubRunner.calls() == 0
      assert [row] = hook_rows(t)
      assert_row(row, "script_rejected")
      assert row.after_state["script_sha256"] == nil
      assert row.after_state["duration_us"] == 0
      assert row.after_state["input_hmac"] == nil
    end

    test "F4B-03c the five script_rejected causes leave rows equal but for the stats", %{
      t: t,
      rule: rule
    } do
      ids = for _ <- 1..5, do: start!(t, hook_attrs(rule))
      [kill, revoked, mismatch, missing, other_tenant] = ids
      set_env(:form_validation_hook_enabled, false)
      assert {:error, {:form_hook_failed, :script_rejected}} = complete(t, kill)
      set_env(:form_validation_hook_enabled, true)

      F.revoke_raw!(t.schema_name, rule)
      assert {:error, {:form_hook_failed, :script_rejected}} = complete(t, revoked)
      raw_row_change!(t, "UPDATE \"#{t.schema_name}\".script_rules SET status = 'published'")

      raw_row_change!(
        t,
        "UPDATE \"#{t.schema_name}\".script_rules SET sha256 = '#{String.duplicate("0", 64)}'"
      )

      assert {:error, {:form_hook_failed, :script_rejected}} = complete(t, mismatch)
      raw_row_change!(t, "UPDATE \"#{t.schema_name}\".script_rules SET sha256 = '#{rule.sha256}'")

      raw_row_change!(t, "DELETE FROM \"#{t.schema_name}\".script_rules")
      assert {:error, {:form_hook_failed, :script_rejected}} = complete(t, missing)

      # The version exists only in another tenant: indistinguishable from the absent row.
      other = F.tenant!("f4b-other")

      F.published!(other.schema_name, rule.key, "return { ok = true }", manifest(),
        hook_kind: "form_validation"
      )

      assert {:error, {:form_hook_failed, :script_rejected}} = complete(t, other_tenant)

      assert StubRunner.calls() == 0
      rows = hook_rows(t)
      assert length(rows) == 5
      volatile = ~w(outcome duration_us instructions_used heap_words_at_end input_hmac)

      for row <- rows do
        assert row.after_state["outcome"] == "script_rejected"
        assert row.after_state["duration_us"] == 0
        assert row.after_state["instructions_used"] == 0
        assert row.after_state["heap_words_at_end"] == 0
        assert row.after_state["input_hmac"] == nil
      end

      assert rows |> Enum.map(&Map.drop(&1.after_state, volatile)) |> Enum.uniq() |> length() == 1
    end

    test "F4B-04 input_invalid: one row, no hash", %{t: t, rule: rule} do
      id = start!(t, hook_attrs(rule))

      assert {:error, {:form_hook_failed, :input_invalid}} =
               complete(t, id, %{"amount" => "not-a-number"})

      assert StubRunner.calls() == 0
      assert [row] = hook_rows(t)
      assert_row(row, "input_invalid")
      assert row.after_state["input_hmac"] == nil
      assert row.after_state["duration_us"] == 0
    end

    test "F4B-05 the HMAC covers the input; no submitted value reaches the row", %{
      t: t,
      rule: rule
    } do
      set_env(:script_task_hmac_fun_override, fn _tenant ->
        {:ok, HmacSecret.build_hmac_fun("f4b-test-key", 7)}
      end)

      a = start!(t, hook_attrs(rule))
      b = start!(t, hook_attrs(rule))
      assert {:ok, _} = complete(t, a, %{"amount" => 5, "note" => @secret_value})
      assert {:ok, _} = complete(t, b, %{"amount" => 6, "note" => @secret_value})

      assert [one, two] = hook_rows(t)
      assert one.after_state["input_hmac"] =~ ~r/^[0-9a-f]{64}$/
      assert one.after_state["input_hmac"] != two.after_state["input_hmac"]
      assert one.after_state["input_hmac_key_version"] == 7
      assert two.after_state["input_hmac_key_version"] == 7
      refute inspect(hook_rows(t)) =~ @secret_value
    end

    test "F4B-06 a tenant without an HMAC key: both columns nil, completion accepted", %{
      t: t,
      rule: rule
    } do
      set_env(:script_task_hmac_fun_override, fn _tenant -> {:error, :missing} end)
      id = start!(t, hook_attrs(rule))

      assert {:ok, _} = complete(t, id)
      assert [row] = hook_rows(t)
      assert row.after_state["input_hmac"] == nil
      assert row.after_state["input_hmac_key_version"] == nil
    end

    test "F4B-08 busy then accepted writes one row; busy three times writes one row", %{
      t: t,
      rule: rule
    } do
      StubRunner.replies([busy(), accept()])
      id = start!(t, hook_attrs(rule))
      assert {:ok, _} = complete(t, id)
      assert StubRunner.calls() == 2
      assert [row] = hook_rows(t)
      assert_row(row, "accepted")

      StubRunner.replies([busy()])
      second = start!(t, hook_attrs(rule))
      assert {:error, {:form_hook_failed, :script_busy}} = complete(t, second)
      assert StubRunner.calls() == 5
      assert [_first, busy_row] = hook_rows(t)
      assert_row(busy_row, "script_busy")
    end

    test "F4B-09 a raising runner: script_error and one row", %{t: t, rule: rule} do
      StubRunner.replies([:raise])
      id = start!(t, hook_attrs(rule))

      assert {:error, {:form_hook_failed, :script_error}} = complete(t, id)
      assert [row] = hook_rows(t)
      assert_row(row, "script_error")
      assert is_integer(row.after_state["duration_us"]) and row.after_state["duration_us"] >= 0
    end
  end

  describe "audit-failure policy (criterion 6)" do
    test "F4B-07 the accepted row is part of the transaction", %{t: t, rule: rule} do
      # Fails the TASK_COMPLETED event, a step AFTER the hook row.
      add_constraint!(t, "events", "t0966_no_task_completed", "event_type <> 'TASK_COMPLETED'")
      id = start!(t, hook_attrs(rule))

      assert {:error, {:transaction_failed, _}} = complete(t, id)
      assert StubRunner.calls() == 1
      assert status!(t, id) == :pending
      assert hook_rows(t) == []
      assert actions(t, "task.complete") == []
    end

    test "F4B-10 a failing post-rollback write is logged and the answer is unchanged", %{
      t: t,
      rule: rule
    } do
      StubRunner.replies([refuse()])
      control = start!(t, hook_attrs(rule))
      expected = complete(t, control)
      assert {:error, {:form_hook_refused, _}} = expected
      assert length(hook_rows(t)) == 1

      add_constraint!(t, "audit_entries", "t0966_no_hook_row", "action <> 'task.form_hook_run'")
      id = start!(t, hook_attrs(rule))
      task_id = pending_task!(t, id).id

      log = capture_log(fn -> assert complete(t, id) == expected end)

      assert StubRunner.calls() == 2
      assert length(hook_rows(t)) == 1
      assert log =~ "[warning]"
      assert log =~ "task.form_hook_run"
      assert log =~ task_id
      refute log =~ "too_small"
      assert status!(t, id) == :pending
    end

    test "F4B-11 a failing accepted row aborts the completion", %{t: t, rule: rule} do
      add_constraint!(t, "audit_entries", "t0966_no_hook_row", "action <> 'task.form_hook_run'")
      id = start!(t, hook_attrs(rule))

      assert {:error, {:transaction_failed, _}} = complete(t, id)
      assert StubRunner.calls() == 1
      assert status!(t, id) == :pending
      assert hook_rows(t) == []
      # Rolled back with the hook row, so only the hook row can have failed.
      assert actions(t, "task.complete") == []
      refute "TASK_COMPLETED" in F.event_types(t.schema_name, id)
    end

    test "F4B-12 completions refused before the hook write no hook row", %{t: t, rule: rule} do
      id =
        start!(
          t,
          Map.put(hook_attrs(rule), "required_outputs", ["amount"]),
          F.integer_schemas(["amount"])
        )

      assert {:error, {:output_refused, %{missing_keys: ["amount"]}}} = complete(t, id, %{})
      assert StubRunner.calls() == 0
      assert hook_rows(t) == []
    end
  end

  describe "run_measured/4 (criterion 10)" do
    test "F4B-15 run/4 keeps its return; run_measured/4 adds stats and the canonical input", %{
      t: t,
      rule: rule
    } do
      alias Letflow.Scripts.FormValidation

      facts = %{
        variables: %{"amount" => 5},
        variable_labels: %{},
        instance_id: Ecto.UUID.generate(),
        token_id: Ecto.UUID.generate(),
        form: %{
          definition_id: Ecto.UUID.generate(),
          definition_version: "1.0.0",
          node_id: "review",
          schema_version_hash: "h"
        },
        task: %{
          id: Ecto.UUID.generate(),
          node_id: "review",
          assignee_kind: "ROLE",
          now: DateTime.utc_now()
        }
      }

      pin = %{script_key: rule.key, script_version: rule.version, script_sha256: rule.sha256}

      assert {:ok, :accepted} = FormValidation.run(t.schema_name, pin, facts)

      assert %{result: {:ok, :accepted}, stats: %{instructions_used: 3}, canonical: canonical} =
               FormValidation.run_measured(t.schema_name, pin, facts)

      assert is_binary(canonical)

      bad = %{pin | script_sha256: String.duplicate("0", 64)}

      assert %{result: {:error, :script_rejected, _}, canonical: nil} =
               FormValidation.run_measured(t.schema_name, bad, facts)
    end
  end
end
