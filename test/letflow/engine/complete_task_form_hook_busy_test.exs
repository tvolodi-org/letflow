defmodule Letflow.Engine.CompleteTaskFormHookBusyTest do
  @moduledoc """
  REQ-605 / GH #3409 (decision 0067 D9, slice F-3 part B): `script_busy` retries the whole
  completion (at most 3 attempts), every other infrastructure code ends the completion as
  `{:error, {:form_hook_failed, code}}` without a raise, a commit or a retry. Tests B1..B5 of the
  T-0829 design. `async: false` (tenant provisioning, application env).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Engine
  alias Letflow.Support.ScriptTaskFixture, as: F

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

  defp accept, do: {:ok, %{output: %{"ok" => true}, stats: stats()}}
  defp busy, do: {:error, :script_busy, %{}}
  defp stats, do: %{duration_us: 7, instructions_used: 3, heap_words_at_end: 9}

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

  defp start!(t, rule) do
    attributes = %{
      "validation_script_key" => rule.key,
      "validation_script_version" => rule.version
    }

    definition = F.definition!(t.schema_name, graph(attributes), [])
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

  defp complete(t, instance_id, output) do
    task = pending_task!(t, instance_id)
    actor = Ecto.UUID.generate()

    Engine.complete_task(
      task.id,
      %{output_variables: output, actor_id: actor, idempotency_key: "f3b-#{actor}"},
      prefix: t.schema_name
    )
  end

  defp table_counts(t) do
    %{rows: tables} =
      Repo.query!(
        "SELECT table_name FROM information_schema.tables WHERE table_schema = $1 AND table_type = 'BASE TABLE'",
        [t.schema_name]
      )

    for [name] <- tables, into: %{} do
      %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM \"#{t.schema_name}\".\"#{name}\"")
      {name, n}
    end
  end

  setup do
    t = F.tenant!("f3b")
    set_env(:form_validation_hook_enabled, true)
    {:ok, _pid} = StubRunner.start()
    on_exit(&StubRunner.stop/0)
    set_env(:form_validation_script_runner, StubRunner)
    StubRunner.replies([accept()])

    rule =
      F.published!(t.schema_name, "fv_f3b", "return { ok = true }", manifest(),
        hook_kind: "form_validation"
      )

    %{t: t, rule: rule}
  end

  defp assert_nothing_committed(t, id, events, projection, counts) do
    assert pending_task!(t, id).status == :pending
    assert F.event_types(t.schema_name, id) == events
    assert F.projection(t.schema_name, id).last_event_seq == projection.last_event_seq
    assert F.projection(t.schema_name, id).variables == projection.variables
    assert table_counts(t) == counts
  end

  describe "script_busy (criterion 8)" do
    test "B1 busy once, then accept: the whole completion re-runs and commits", %{
      t: t,
      rule: rule
    } do
      StubRunner.replies([busy(), accept()])
      id = start!(t, rule)

      assert {:ok, _} = complete(t, id, %{"amount" => 5})
      assert StubRunner.calls() == 2

      assert Repo.all(from(x in Letflow.Engine.Task, where: x.status == :pending),
               prefix: t.schema_name
             ) == []
    end

    test "B2 always busy: 3 attempts in total, then script_busy; nothing committed",
         %{t: t, rule: rule} do
      StubRunner.replies([busy()])
      id = start!(t, rule)
      events = F.event_types(t.schema_name, id)
      projection = F.projection(t.schema_name, id)
      counts = table_counts(t)

      assert {:error, {:form_hook_failed, :script_busy}} = complete(t, id, %{"amount" => 5})
      assert StubRunner.calls() == 3
      assert_nothing_committed(t, id, events, projection, counts)
    end

    test "B3a busy twice, then accept: succeeds on the third attempt", %{t: t, rule: rule} do
      StubRunner.replies([busy(), busy(), accept()])
      id = start!(t, rule)

      assert {:ok, _} = complete(t, id, %{"amount" => 5})
      assert StubRunner.calls() == 3
    end

    test "B3b busy, then another code: that code, no further retry", %{t: t, rule: rule} do
      StubRunner.replies([busy(), {:error, :timeout, %{}}])
      id = start!(t, rule)

      assert {:error, {:form_hook_failed, :timeout}} = complete(t, id, %{"amount" => 5})
      assert StubRunner.calls() == 2
    end

    test "B3c a refusing verdict is final after one call", %{t: t, rule: rule} do
      StubRunner.replies([
        {:ok,
         %{
           output: %{
             "ok" => false,
             "code" => "too_small",
             "fields" => [%{"field" => "amount", "code" => "too_small"}]
           },
           stats: stats()
         }}
      ])

      id = start!(t, rule)

      assert {:error, {:form_hook_refused, %{code: "too_small"}}} =
               complete(t, id, %{"amount" => 1})

      assert StubRunner.calls() == 1
    end

    test "B5 a raising runner ends as script_error after one call, no raise", %{t: t, rule: rule} do
      StubRunner.replies([:raise])
      id = start!(t, rule)

      assert {:error, {:form_hook_failed, :script_error}} = complete(t, id, %{"amount" => 5})
      assert StubRunner.calls() == 1
      assert pending_task!(t, id).status == :pending
    end
  end

  describe "infrastructure codes (criterion 9)" do
    for code <- [:script_error, :budget_exceeded, :memory_limit_exceeded, :timeout] do
      test "B4 #{code}: form_hook_failed, nothing committed, one call", %{t: t, rule: rule} do
        StubRunner.replies([{:error, unquote(code), %{}}])
        id = start!(t, rule)
        events = F.event_types(t.schema_name, id)
        projection = F.projection(t.schema_name, id)
        counts = table_counts(t)

        assert {:error, {:form_hook_failed, unquote(code)}} = complete(t, id, %{"amount" => 5})
        assert StubRunner.calls() == 1
        assert_nothing_committed(t, id, events, projection, counts)
      end
    end

    test "B4 output_invalid: an output breaking the closed schema", %{t: t, rule: rule} do
      StubRunner.replies([{:ok, %{output: %{"ok" => "yes"}, stats: stats()}}])
      id = start!(t, rule)
      events = F.event_types(t.schema_name, id)
      projection = F.projection(t.schema_name, id)
      counts = table_counts(t)

      assert {:error, {:form_hook_failed, :output_invalid}} = complete(t, id, %{"amount" => 5})
      assert StubRunner.calls() == 1
      assert_nothing_committed(t, id, events, projection, counts)
    end

    test "B4 script_rejected: the flag turned off after the instance started; the stub is not called",
         %{t: t, rule: rule} do
      id = start!(t, rule)
      events = F.event_types(t.schema_name, id)
      projection = F.projection(t.schema_name, id)
      counts = table_counts(t)
      set_env(:form_validation_hook_enabled, false)

      assert {:error, {:form_hook_failed, :script_rejected}} = complete(t, id, %{"amount" => 5})
      assert StubRunner.calls() == 0
      assert_nothing_committed(t, id, events, projection, counts)
    end

    test "B4 input_invalid: a submitted value breaking the manifest input_schema; the stub is not called",
         %{t: t, rule: rule} do
      id = start!(t, rule)
      events = F.event_types(t.schema_name, id)
      projection = F.projection(t.schema_name, id)
      counts = table_counts(t)

      assert {:error, {:form_hook_failed, :input_invalid}} =
               complete(t, id, %{"amount" => "not-a-number"})

      assert StubRunner.calls() == 0
      assert_nothing_committed(t, id, events, projection, counts)
    end
  end
end
