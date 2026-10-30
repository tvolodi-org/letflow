defmodule Letflow.Engine.CompleteTaskFormHookTest do
  @moduledoc """
  REQ-605 / GH #3409 (decision 0067 D1, D8, D9, slice F-3 part A): the `:form_validation_hook` step
  of `Engine.complete_task/3`. Tests T1..T6, T11 of the T-0828 design. `async: false` (tenant
  provisioning, application env). A stub runner records every sandbox call and its input.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Engine
  alias Letflow.Engine.PinResolver
  alias Letflow.Support.ScriptTaskFixture, as: F

  @placeholder "__field_redacted__"
  @label "customer.salary"
  @secret "TOPSECRET-77"

  defmodule StubRunner do
    @moduledoc false
    def start, do: Agent.start_link(fn -> %{calls: [], reply: nil} end, name: __MODULE__)

    def stop do
      Agent.stop(__MODULE__)
    catch
      :exit, _already_gone -> :ok
    end

    def reply(value), do: Agent.update(__MODULE__, &%{&1 | reply: value})
    def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

    def run(source, input, opts) do
      Agent.update(__MODULE__, &%{&1 | calls: [{source, input, opts} | &1.calls]})
      Agent.get(__MODULE__, & &1.reply)
    end
  end

  defp manifest do
    %{
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "amount" => %{"type" => "integer"},
          "note" => %{"type" => "string"},
          "salary" => %{"type" => "string"}
        }
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

  defp refuse(value \\ "too_small"),
    do:
      {:ok,
       %{
         output: %{
           "ok" => false,
           "code" => value,
           "fields" => [%{"field" => "amount", "code" => value}]
         },
         stats: stats()
       }}

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

  # START -> review (HUMAN_TASK, optional hook and extra attributes) -> END
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

  defp start!(t, attributes, variables \\ %{}, schemas \\ []) do
    definition = F.definition!(t.schema_name, graph(attributes), schemas)
    F.start!(t.schema_name, definition, variables, Ecto.UUID.generate())
  end

  defp pending_task!(t, instance_id) do
    Repo.one!(
      from(x in Letflow.Engine.Task,
        where: x.instance_id == ^instance_id and x.status == :pending
      ),
      prefix: t.schema_name
    )
  end

  defp complete(t, instance_id, output, opts \\ []) do
    task = pending_task!(t, instance_id)
    actor = Ecto.UUID.generate()

    Engine.complete_task(
      task.id,
      %{output_variables: output, actor_id: actor, idempotency_key: "f3-#{actor}"},
      Keyword.put(opts, :prefix, t.schema_name)
    )
  end

  defp label!(t, instance_id) do
    Repo.update_all(
      from(p in Letflow.EventStore.InstanceProjection, where: p.instance_id == ^instance_id),
      [set: [variables: %{"salary" => @secret}, variable_labels: %{"salary" => [@label]}]],
      prefix: t.schema_name
    )
  end

  defp count_queries(fun) do
    test_pid = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:letflow, :repo, :query],
      fn _event, _m, _meta, _ -> if self() == test_pid, do: send(test_pid, :query) end,
      nil
    )

    result = fun.()
    :telemetry.detach(handler)
    {result, drain(0)}
  end

  defp drain(n) do
    receive do
      :query -> drain(n + 1)
    after
      0 -> n
    end
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

  defp delta(before_counts, after_counts) do
    for {name, n} <- after_counts, n != Map.get(before_counts, name), into: %{} do
      {name, n - Map.get(before_counts, name, 0)}
    end
  end

  setup do
    t = F.tenant!("f3a")
    set_env(:form_validation_hook_enabled, true)
    {:ok, _pid} = StubRunner.start()
    on_exit(&StubRunner.stop/0)
    set_env(:form_validation_script_runner, StubRunner)
    StubRunner.reply(accept())

    rule =
      F.published!(t.schema_name, "fv_f3", "return { ok = true }", manifest(),
        hook_kind: "form_validation"
      )

    %{t: t, rule: rule}
  end

  describe "step order (criterion 1)" do
    test "T1 the hook step follows the guards and the sentinel check, precedes reevaluation",
         %{t: t, rule: rule} do
      hooked = start!(t, hook_attrs(rule))
      plain = start!(t, %{})
      hooked_task = pending_task!(t, hooked)
      plain_task = pending_task!(t, plain)
      actor = Ecto.UUID.generate()
      schema = t.schema_name

      {:ok, no_hook} = Engine.__complete_task_multi_step_names__(plain_task.id, actor, schema)
      {:ok, with_hook} = Engine.__complete_task_multi_step_names__(hooked_task.id, actor, schema)

      refute :form_validation_hook in no_hook
      assert List.delete(with_hook, :form_validation_hook) == no_hook

      guards = Enum.find_index(with_hook, &(&1 == :completion_guards))
      hook = Enum.find_index(with_hook, &(&1 == :form_validation_hook))
      assert hook == guards + 1
      assert Enum.at(with_hook, hook + 1) == :form_expression_reevaluation

      {:ok, checked} =
        Engine.__complete_task_multi_step_names__(hooked_task.id, actor, schema, {:check, nil})

      sentinel = Enum.find_index(checked, &(&1 == :redacted_sentinel))
      assert Enum.at(checked, sentinel + 1) == :form_validation_hook
      assert Enum.at(checked, sentinel + 2) == :form_expression_reevaluation
    end
  end

  describe "accept (criteria 2, 3)" do
    test "T2 run/4 gets the prefix, the pin and the facts; one extra ScriptRule query beyond the pins",
         %{t: t, rule: rule} do
      hooked = start!(t, hook_attrs(rule))
      plain = start!(t, %{})

      {{:ok, _}, without_hook} = count_queries(fn -> complete(t, plain, %{"amount" => 5}) end)
      {{:ok, _}, with_hook} = count_queries(fn -> complete(t, hooked, %{"amount" => 5}) end)

      {{:ok, _pins}, reconstruct_alone} =
        count_queries(fn ->
          PinResolver.reconstruct_effective_pins(hooked, prefix: t.schema_name)
        end)

      # The pins exist only in the INSTANCE_STARTED payload, so they are read (before the
      # transaction) in addition to the one ScriptRule row load: see the design, finding 1.
      # GH #3524 (F-4 part B): the hook run also writes its audit row and looks up the HMAC key: 7
      # more queries (audit chain lock and tail reads, the insert, tenant and secret reads; measured).
      assert with_hook == without_hook + reconstruct_alone + 1 + 7

      assert [{"return { ok = true }", input, opts}] = StubRunner.calls()
      assert opts[:tenant] == t.schema_name
      assert input["output"] == %{"amount" => 5}
      assert input["form"]["node_id"] == "review"
      assert input["form"]["definition_version"] == "1.0.0"
      assert input["task"]["node_id"] == "review"
      assert input["task"]["assignee_kind"] == "ROLE"
      assert opts[:ctx].instance_id == hooked
    end

    test "T3 an accepting hook leaves result, events and rows equal to a node without a hook",
         %{t: t, rule: rule} do
      hooked = start!(t, hook_attrs(rule))
      plain = start!(t, %{})
      events_before = {F.event_types(t.schema_name, hooked), F.event_types(t.schema_name, plain)}
      rows_before = table_counts(t)

      assert {:ok, plain_result} = complete(t, plain, %{"amount" => 5})
      plain_delta = delta(rows_before, table_counts(t))
      rows_mid = table_counts(t)
      assert {:ok, hook_result} = complete(t, hooked, %{"amount" => 5})
      hook_delta = delta(rows_mid, table_counts(t))

      strip = &Map.drop(&1, [:task_id, :instance_id, :completed_at])
      assert strip.(hook_result) == strip.(plain_result)
      # GH #3524 (F-4 part B): the accepted run adds exactly one audit row (task.form_hook_run).
      assert Map.delete(hook_delta, "audit_entries") == Map.delete(plain_delta, "audit_entries")
      assert hook_delta["audit_entries"] == plain_delta["audit_entries"] + 1

      {hooked_before, plain_before} = events_before

      assert Enum.drop(F.event_types(t.schema_name, hooked), length(hooked_before)) ==
               Enum.drop(F.event_types(t.schema_name, plain), length(plain_before))

      assert length(StubRunner.calls()) == 1
    end

    test "T2b a node whose pin does not match its binding is refused; nothing runs",
         %{t: t, rule: rule} do
      id = start!(t, hook_attrs(rule))

      # The pin (INSTANCE_STARTED payload) and the snapshot node are written together at start;
      # a hand-edited snapshot is the only way to make them disagree.
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
      before_events = F.event_types(t.schema_name, id)

      assert {:error, {:form_hook_failed, :script_rejected}} = complete(t, id, %{"amount" => 5})

      assert StubRunner.calls() == []
      assert pending_task!(t, id).status == :pending
      assert F.event_types(t.schema_name, id) == before_events
    end

    test "a hook node that also has entity lines still gets its hook",
         %{t: t, rule: rule} do
      attrs = Map.put(hook_attrs(rule), "entity_writes", [])
      id = start!(t, attrs)
      assert {:ok, _} = complete(t, id, %{"amount" => 5})
      assert length(StubRunner.calls()) == 1
    end
  end

  describe "refuse (criterion 4)" do
    test "T4 the refusing verdict is returned; the task stays pending, one hook audit row",
         %{t: t, rule: rule} do
      StubRunner.reply(refuse())
      id = start!(t, hook_attrs(rule))
      events = F.event_types(t.schema_name, id)
      projection = F.projection(t.schema_name, id)
      audit_before = table_counts(t)["audit_entries"]

      assert {:error,
              {:form_hook_refused,
               %{code: "too_small", fields: [%{field: "amount", code: "too_small"}]}}} =
               complete(t, id, %{"amount" => 1})

      assert pending_task!(t, id).status == :pending
      assert F.event_types(t.schema_name, id) == events
      assert F.projection(t.schema_name, id).last_event_seq == projection.last_event_seq
      assert F.projection(t.schema_name, id).variables == projection.variables
      # GH #3524 (F-4 part B): a refused run writes exactly one task.form_hook_run row.
      assert table_counts(t)["audit_entries"] == audit_before + 1
    end
  end

  describe "guard and sentinel order (criteria 5, 6)" do
    test "T5a a failing required-output guard keeps its answer; the sandbox never runs",
         %{t: t, rule: rule} do
      id =
        start!(
          t,
          Map.put(hook_attrs(rule), "required_outputs", ["amount"]),
          %{},
          F.integer_schemas(["amount"])
        )

      assert {:error, {:output_refused, %{missing_keys: ["amount"], rejected_keys: []}}} =
               complete(t, id, %{})

      assert StubRunner.calls() == []
    end

    test "T5c passing guards and a refusing hook give the hook answer",
         %{t: t, rule: rule} do
      StubRunner.reply(refuse())

      id =
        start!(
          t,
          Map.put(hook_attrs(rule), "required_outputs", ["amount"]),
          %{},
          F.integer_schemas(["amount"])
        )

      assert {:error, {:form_hook_refused, %{code: "too_small"}}} =
               complete(t, id, %{"amount" => 1})

      assert length(StubRunner.calls()) == 1
    end

    test "T6 a submitted placeholder for an unreadable variable is refused before the sandbox",
         %{t: t, rule: rule} do
      id = start!(t, hook_attrs(rule))
      label!(t, id)

      assert {:error, {:redacted_value_submitted, ["salary"]}} =
               complete(t, id, %{"salary" => @placeholder}, hidden_labels: MapSet.new([@label]))

      assert StubRunner.calls() == []
    end
  end

  describe "restricted values (criterion 11)" do
    test "T11 a labelled variable never reaches the script input or the refusal",
         %{t: t, rule: rule} do
      StubRunner.reply(refuse())
      id = start!(t, hook_attrs(rule))
      label!(t, id)

      result = complete(t, id, %{"salary" => @secret, "amount" => 1})

      assert {:error, {:form_hook_refused, _}} = result
      refute inspect(result) =~ @secret
      assert [{_source, input, _opts}] = StubRunner.calls()
      refute inspect(input) =~ @secret
      refute Map.has_key?(input["output"], "salary")
      assert input["output"]["amount"] == 1
    end
  end
end
