defmodule Letflow.EngineRequiredOutputsTest do
  @moduledoc """
  REQ-460 -- rule C of the REQ-459 design (`required_outputs` + schema-rejection refusal
  on the HUMAN_TASK completion path), driven through the real
  `Letflow.Engine.complete_task/3` against real Postgres (`test_developer_guide.md` T-1).
  Covers design section 12.1 cases C-1 .. C-12, C-15 and the audit half of C-16.
  The router-level cases (C-13, C-14, the HTTP body, caller-email PII grep) live in
  `test/letflow/routers/tasks_required_outputs_test.exs`.

  Every test builds its own inline definition in its own provisioned tenant (no shipped
  fixture adopts `required_outputs`). "Unchanged" assertions compare the FULL instance
  projection row (including `updated_at`), every token row, the task row, the event
  count and the audit count, read before and after the refused call.

  See `test/specs/REQ-460.md` for the criterion -> case map and why each case exists.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Letflow.Audit
  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Engine.TokenRecord
  alias Letflow.Engine.VariableSchema
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.TenantFixture

  # ---------------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------------

  defp provisioned_tenant do
    TenantFixture.provisioned_tenant!(
      slug_prefix: "req460-eng",
      display_name: "REQ-460 Engine Test Tenant"
    )
  end

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  # START -> task(HUMAN_TASK) -> gw(EXCLUSIVE_GATEWAY)
  #   -> approved_task (HUMAN_TASK)  when variables.decision == "approved"
  #   -> fallback_task (HUMAN_TASK)  default (the fail-closed route)
  # followed by END. `attrs` are merged into the first task's attributes; it is assigned
  # to USER `assignee` so a test can really claim it afterwards. The downstream tasks make
  # the route taken observable (the active token's node id) without completing the
  # instance.
  defp graph(assignee, task_attrs) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "task",
          "node_type" => "HUMAN_TASK",
          "attributes" => Map.merge(%{"role" => assignee, "assignee_type" => "USER"}, task_attrs)
        },
        %{"id" => "gw", "node_type" => "EXCLUSIVE_GATEWAY"},
        %{
          "id" => "approved_task",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "reviewer"}
        },
        %{
          "id" => "fallback_task",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "reviewer"}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "gw"},
        %{
          "id" => "e3",
          "source" => "gw",
          "target" => "approved_task",
          "condition" => "variables.decision == \"approved\""
        },
        %{"id" => "e4", "source" => "gw", "target" => "fallback_task", "is_default" => true},
        %{"id" => "e5", "source" => "approved_task", "target" => "end"},
        %{"id" => "e6", "source" => "fallback_task", "target" => "end"}
      ]
    }
  end

  defp decision_form do
    %{
      "type" => "object",
      "properties" => %{
        "decision" => %{"type" => "string"},
        "note" => %{"type" => "string"},
        "score" => %{"type" => "number"}
      }
    }
  end

  defp decision_enum, do: %{"type" => "string", "enum" => ["approved", "rejected"]}

  # REQ-461 check 2 refuses to activate a definition whose HUMAN_TASK `required_outputs`
  # names a key with no variable_schema, so the schema rows are registered BEFORE
  # activation (`schemas` is `%{key => json_schema}`).
  defp active_definition!(schema_name, graph, schemas \\ %{}) do
    attrs = %{
      name: unique("req460-def"),
      version: "1.0.0",
      graph: graph,
      created_by: Ecto.UUID.generate()
    }

    assert {:ok, definition} = Definitions.create(attrs, prefix: schema_name)

    if schemas != %{} do
      entries =
        for {key, json_schema} <- schemas, do: %{variable_key: key, json_schema: json_schema}

      assert {:ok, _count} =
               Definitions.register_variable_schemas(definition.id, entries, prefix: schema_name)
    end

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    activated
  end

  defp seed_schema_row!(schema_name, definition_id, variable_key, json_schema) do
    %VariableSchema{}
    |> VariableSchema.changeset(%{
      definition_id: definition_id,
      variable_key: variable_key,
      json_schema: json_schema
    })
    |> Repo.insert!(prefix: schema_name)
  end

  # Provisions a tenant, an active definition with `task_attrs` on the first task, the
  # given variable_schemas (`%{key => json_schema}`), and a started instance. Returns a
  # context map.
  defp setup_case!(opts) do
    task_attrs = Keyword.get(opts, :task_attrs, %{})
    schemas = Keyword.get(opts, :schemas, %{})
    initial = Keyword.get(opts, :initial_variables, %{"seed" => "value"})
    graph_fun = Keyword.get(opts, :graph, &graph/2)

    %{schema_name: schema_name} = provisioned_tenant()
    assignee = Ecto.UUID.generate()

    # The default graph's gateway edge reads `variables.decision`, and REQ-461 check 2
    # refuses to activate a `required_outputs` key without a variable_schema, so `decision`
    # plus every listed required key gets a plain string schema unless the test supplies
    # its own. A non-list `required_outputs` has no keys to declare.
    required_keys =
      case Map.get(task_attrs, "required_outputs") do
        keys when is_list(keys) -> ["decision" | keys]
        _not_a_list -> ["decision"]
      end

    schemas = Map.merge(Map.new(required_keys, &{&1, %{"type" => "string"}}), schemas)
    definition = active_definition!(schema_name, graph_fun.(assignee, task_attrs), schemas)

    # A malformed `required_outputs` is refused by Definitions.create/2 (graph shape
    # check), so the engine's tolerance of one is exercised by rewriting the stored graph
    # of an already-activated definition before any instance starts.
    with poisoned when is_map(poisoned) <- Keyword.get(opts, :stored_graph_attrs) do
      Repo.update_all(
        from(d in Definitions.ProcessDefinition, where: d.id == ^definition.id),
        [set: [graph: graph_fun.(assignee, poisoned)]],
        prefix: schema_name
      )
    end

    assert {:ok, created} =
             Engine.create(
               %{
                 definition_id: definition.id,
                 initial_variables: initial,
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique("start")
               },
               prefix: schema_name
             )

    task =
      EngineTask
      |> where([t], t.instance_id == ^created.instance_id and t.node_id == "task")
      |> Repo.one!(prefix: schema_name)

    %{
      schema_name: schema_name,
      assignee: assignee,
      definition: definition,
      instance_id: created.instance_id,
      task: task
    }
  end

  defp complete_attrs(output_variables) do
    %{
      output_variables: output_variables,
      actor_id: Ecto.UUID.generate(),
      idempotency_key: unique("complete")
    }
  end

  defp event_count(ctx) do
    Repo.aggregate(from(e in Event, where: e.instance_id == ^ctx.instance_id), :count,
      prefix: ctx.schema_name
    )
  end

  defp events_of_type(ctx, type) do
    Event
    |> where([e], e.instance_id == ^ctx.instance_id and e.event_type == ^type)
    |> Repo.all(prefix: ctx.schema_name)
  end

  defp refusal_audit_rows(schema_name) do
    Audit.Entry
    |> where([a], a.action == "task.completion_refused")
    |> Repo.all(prefix: schema_name)
  end

  defp audit_count(schema_name), do: Repo.aggregate(Audit.Entry, :count, prefix: schema_name)

  # Everything a refused completion must leave byte-for-byte alone.
  defp rows(ctx) do
    %{
      projection: Repo.get!(InstanceProjection, ctx.instance_id, prefix: ctx.schema_name),
      tokens:
        TokenRecord
        |> where([t], t.instance_id == ^ctx.instance_id)
        |> order_by([t], t.id)
        |> Repo.all(prefix: ctx.schema_name),
      task: Repo.get!(EngineTask, ctx.task.id, prefix: ctx.schema_name),
      event_count: event_count(ctx)
    }
  end

  defp active_node_ids(ctx) do
    TokenRecord
    |> where([t], t.instance_id == ^ctx.instance_id and t.status == :active)
    |> select([t], t.node_id)
    |> Repo.all(prefix: ctx.schema_name)
    |> Enum.sort()
  end

  # Asserts the refusal and that every row a refused completion must not touch is equal to
  # its pre-call snapshot.
  defp assert_refused_untouched!(ctx, before, result, expected_missing, expected_rejected) do
    assert {:error, {:output_refused, refusal}} = result
    assert refusal == %{missing_keys: expected_missing, rejected_keys: expected_rejected}

    assert rows(ctx) == before
    assert before.task.status == :pending
    assert before.projection.status == :active
    assert events_of_type(ctx, "EXECUTION_ERROR") == []
    assert events_of_type(ctx, "TASK_COMPLETED") == []
  end

  # The task is still open for its assignee: a real claim succeeds.
  defp assert_claimable!(ctx) do
    assert {:ok, claimed} =
             Letflow.Tasks.claim_task(ctx.task.id, %{actor_id: ctx.assignee},
               prefix: ctx.schema_name
             )

    assert claimed.status == :pending
  end

  # ---------------------------------------------------------------------------------
  # C-1 / C-2 / C-3 -- the required key is missing from the SUBMITTED output
  # ---------------------------------------------------------------------------------

  describe "C-1 -- required key absent" do
    test "422-shaped refusal naming the key; every row unchanged; exactly one audit row; task claimable" do
      ctx =
        setup_case!(
          task_attrs: %{"required_outputs" => ["decision"], "form_schema" => decision_form()}
        )

      before = rows(ctx)
      audit_before = audit_count(ctx.schema_name)

      result =
        Engine.complete_task(ctx.task.id, complete_attrs(%{"note" => "TOP-SECRET-NOTE"}),
          prefix: ctx.schema_name
        )

      # the refusal carries key NAMES only: the submitted value is nowhere in it
      refute inspect(result) =~ "TOP-SECRET-NOTE"
      assert_refused_untouched!(ctx, before, result, ["decision"], [])

      assert audit_count(ctx.schema_name) == audit_before + 1
      assert [entry] = refusal_audit_rows(ctx.schema_name)
      assert entry.resource_type == "task"
      assert entry.resource_id == ctx.task.id
      assert entry.before_state == nil

      assert entry.after_state == %{
               "rule" => "output_refused",
               "instance_id" => ctx.instance_id,
               "node_id" => "task",
               "missing_keys" => ["decision"],
               "rejected_keys" => []
             }

      refute inspect(entry, limit: :infinity) =~ "TOP-SECRET-NOTE"
      assert_claimable!(ctx)
    end

    test "every refused request writes exactly one record (two refusals, two rows)" do
      ctx = setup_case!(task_attrs: %{"required_outputs" => ["decision"]})

      for _ <- 1..2 do
        assert {:error, {:output_refused, _}} =
                 Engine.complete_task(ctx.task.id, complete_attrs(%{}), prefix: ctx.schema_name)
      end

      assert length(refusal_audit_rows(ctx.schema_name)) == 2
    end

    test "several required keys: all missing ones are named, sorted ascending" do
      ctx = setup_case!(task_attrs: %{"required_outputs" => ["reason", "decision", "alpha"]})
      before = rows(ctx)

      result =
        Engine.complete_task(ctx.task.id, complete_attrs(%{"alpha" => 1}),
          prefix: ctx.schema_name
        )

      assert_refused_untouched!(ctx, before, result, ["decision", "reason"], [])
    end

    test "the refused task can then be completed once the key is supplied (retryable)" do
      ctx = setup_case!(task_attrs: %{"required_outputs" => ["decision"]})

      assert {:error, {:output_refused, _}} =
               Engine.complete_task(ctx.task.id, complete_attrs(%{}), prefix: ctx.schema_name)

      assert {:ok, result} =
               Engine.complete_task(ctx.task.id, complete_attrs(%{"decision" => "approved"}),
                 prefix: ctx.schema_name
               )

      assert result.instance_status == :active
      assert active_node_ids(ctx) == ["approved_task"]
    end
  end

  describe "C-2 -- required key submitted as null" do
    test "null counts as missing: the same refusal" do
      ctx = setup_case!(task_attrs: %{"required_outputs" => ["decision"]})
      before = rows(ctx)

      result =
        Engine.complete_task(ctx.task.id, complete_attrs(%{"decision" => nil}),
          prefix: ctx.schema_name
        )

      assert_refused_untouched!(ctx, before, result, ["decision"], [])
    end
  end

  describe "C-3 -- rework loop: only SUBMITTED output counts" do
    test "the instance already holds decision, the resubmission omits it: still refused" do
      ctx =
        setup_case!(
          task_attrs: %{"required_outputs" => ["decision"]},
          initial_variables: %{"seed" => "value", "decision" => "approved"}
        )

      assert ctx.instance_id
             |> then(&Repo.get!(InstanceProjection, &1, prefix: ctx.schema_name))
             |> Map.get(:variables) ==
               %{"seed" => "value", "decision" => "approved"}

      before = rows(ctx)

      result =
        Engine.complete_task(ctx.task.id, complete_attrs(%{"note" => "n"}),
          prefix: ctx.schema_name
        )

      assert_refused_untouched!(ctx, before, result, ["decision"], [])
    end
  end

  # ---------------------------------------------------------------------------------
  # C-4 / C-4a / C-5 / C-6 -- a value a variable_schema rejects
  # ---------------------------------------------------------------------------------

  describe "C-4 -- enum-rejected value on a required key" do
    test "refusal names the key only; no ERROR, no EXECUTION_ERROR; an immediate valid retry completes and routes" do
      ctx =
        setup_case!(
          task_attrs: %{"required_outputs" => ["decision"], "form_schema" => decision_form()},
          schemas: %{"decision" => decision_enum()}
        )

      before = rows(ctx)

      result =
        Engine.complete_task(ctx.task.id, complete_attrs(%{"decision" => "maybe-LEAKCHECK"}),
          prefix: ctx.schema_name
        )

      refute inspect(result) =~ "maybe-LEAKCHECK"
      refute inspect(result) =~ "approved"
      assert_refused_untouched!(ctx, before, result, [], ["decision"])

      assert [entry] = refusal_audit_rows(ctx.schema_name)
      assert entry.after_state["rejected_keys"] == ["decision"]
      assert entry.after_state["missing_keys"] == []
      refute inspect(entry, limit: :infinity) =~ "maybe-LEAKCHECK"
      assert_claimable!(ctx)

      # immediate retry with a valid value: completes and routes to the approved branch
      assert {:ok, retry} =
               Engine.complete_task(ctx.task.id, complete_attrs(%{"decision" => "approved"}),
                 prefix: ctx.schema_name
               )

      assert retry.variables["decision"] == "approved"

      assert Repo.get!(InstanceProjection, ctx.instance_id, prefix: ctx.schema_name).status ==
               :active

      assert active_node_ids(ctx) == ["approved_task"]
      assert events_of_type(ctx, "EXECUTION_ERROR") == []
    end

    test "the whole batch is refused: a valid sibling key submitted with the rejected one is not merged" do
      ctx =
        setup_case!(
          task_attrs: %{"required_outputs" => ["decision"], "form_schema" => decision_form()},
          schemas: %{"decision" => decision_enum()}
        )

      before = rows(ctx)

      result =
        Engine.complete_task(
          ctx.task.id,
          complete_attrs(%{"decision" => "nope", "note" => "sibling"}),
          prefix: ctx.schema_name
        )

      assert_refused_untouched!(ctx, before, result, [], ["decision"])
      refute Map.has_key?(rows(ctx).projection.variables, "note")
    end
  end

  describe "C-4a -- rejection on a key that is neither in the form nor required_outputs" do
    test "still refused (whole batch), but BOTH lists are empty and the key name appears nowhere" do
      ctx =
        setup_case!(
          task_attrs: %{"required_outputs" => ["decision"], "form_schema" => decision_form()},
          schemas: %{"zz_probe_key" => %{"type" => "number"}}
        )

      before = rows(ctx)

      result =
        Engine.complete_task(
          ctx.task.id,
          complete_attrs(%{"decision" => "approved", "zz_probe_key" => "not-a-number"}),
          prefix: ctx.schema_name
        )

      refute inspect(result) =~ "zz_probe_key"
      assert_refused_untouched!(ctx, before, result, [], [])

      assert [entry] = refusal_audit_rows(ctx.schema_name)
      refute inspect(entry, limit: :infinity) =~ "zz_probe_key"
      assert entry.after_state["missing_keys"] == []
      assert entry.after_state["rejected_keys"] == []
    end

    test "a task with no form_schema at all behaves the same (nothing outside required_outputs is nameable)" do
      ctx =
        setup_case!(
          task_attrs: %{"required_outputs" => ["decision"]},
          schemas: %{"amount" => %{"type" => "number"}}
        )

      before = rows(ctx)

      result =
        Engine.complete_task(
          ctx.task.id,
          complete_attrs(%{"decision" => "approved", "amount" => "x"}),
          prefix: ctx.schema_name
        )

      assert_refused_untouched!(ctx, before, result, [], [])
    end
  end

  describe "C-5 -- wrong-type value on a typed in-form key" do
    test "refusal names the in-form key, not its value" do
      ctx =
        setup_case!(
          task_attrs: %{"required_outputs" => ["decision"], "form_schema" => decision_form()},
          schemas: %{"score" => %{"type" => "number"}}
        )

      before = rows(ctx)

      result =
        Engine.complete_task(
          ctx.task.id,
          complete_attrs(%{"decision" => "approved", "score" => "very-high-LEAKCHECK"}),
          prefix: ctx.schema_name
        )

      refute inspect(result) =~ "LEAKCHECK"
      assert_refused_untouched!(ctx, before, result, [], ["score"])
    end

    test "an in-form key is nameable even when it is not in required_outputs, and a task with required_outputs off still refuses a rejected in-form value" do
      ctx =
        setup_case!(
          task_attrs: %{"form_schema" => decision_form()},
          schemas: %{"score" => %{"type" => "number"}}
        )

      before = rows(ctx)

      result =
        Engine.complete_task(ctx.task.id, complete_attrs(%{"score" => "x"}),
          prefix: ctx.schema_name
        )

      assert_refused_untouched!(ctx, before, result, [], ["score"])
    end
  end

  describe "C-6 -- empty string on a required key is judged by the schema, not as missing" do
    test "an enum without the empty string rejects it: rejected_keys, not missing_keys" do
      ctx =
        setup_case!(
          task_attrs: %{"required_outputs" => ["decision"], "form_schema" => decision_form()},
          schemas: %{"decision" => decision_enum()}
        )

      before = rows(ctx)

      result =
        Engine.complete_task(ctx.task.id, complete_attrs(%{"decision" => ""}),
          prefix: ctx.schema_name
        )

      assert_refused_untouched!(ctx, before, result, [], ["decision"])
    end

    test "a schema that allows the empty string accepts it (the task completes)" do
      ctx =
        setup_case!(
          task_attrs: %{"required_outputs" => ["decision"], "form_schema" => decision_form()},
          schemas: %{"decision" => %{"type" => "string"}}
        )

      assert {:ok, result} =
               Engine.complete_task(ctx.task.id, complete_attrs(%{"decision" => ""}),
                 prefix: ctx.schema_name
               )

      assert result.variables["decision"] == ""
      assert refusal_audit_rows(ctx.schema_name) == []
    end
  end

  # ---------------------------------------------------------------------------------
  # C-7 -- a required key present when submitted but dropped by the server's
  # form-expression correction (design step 6b-ii)
  # ---------------------------------------------------------------------------------

  describe "C-7 -- required key dropped by visible_when false" do
    test "refused with missing_keys although the SUBMITTED map carried it; nothing written" do
      form = %{
        "type" => "object",
        "properties" => %{
          "amount" => %{"type" => "number"},
          "decision" => %{
            "type" => "string",
            "x-ui" => %{"visible_when" => "amount > 0"}
          }
        }
      }

      ctx = setup_case!(task_attrs: %{"required_outputs" => ["decision"], "form_schema" => form})
      before = rows(ctx)

      result =
        Engine.complete_task(
          ctx.task.id,
          complete_attrs(%{"amount" => 0, "decision" => "approved"}),
          prefix: ctx.schema_name
        )

      assert_refused_untouched!(ctx, before, result, ["decision"], [])
    end

    test "control: the same submission completes when the field stays visible" do
      form = %{
        "type" => "object",
        "properties" => %{
          "amount" => %{"type" => "number"},
          "decision" => %{"type" => "string", "x-ui" => %{"visible_when" => "amount > 0"}}
        }
      }

      ctx = setup_case!(task_attrs: %{"required_outputs" => ["decision"], "form_schema" => form})

      assert {:ok, result} =
               Engine.complete_task(
                 ctx.task.id,
                 complete_attrs(%{"amount" => 5, "decision" => "approved"}),
                 prefix: ctx.schema_name
               )

      assert result.variables["decision"] == "approved"
    end
  end

  # ---------------------------------------------------------------------------------
  # C-8 / C-9 -- unchanged behaviour
  # ---------------------------------------------------------------------------------

  describe "C-8 -- all required keys present and valid" do
    test "completes as before, routes on the value, writes no refusal audit row" do
      ctx =
        setup_case!(
          task_attrs: %{"required_outputs" => ["decision"], "form_schema" => decision_form()},
          schemas: %{"decision" => decision_enum()}
        )

      assert {:ok, result} =
               Engine.complete_task(ctx.task.id, complete_attrs(%{"decision" => "rejected"}),
                 prefix: ctx.schema_name
               )

      assert result.variables["decision"] == "rejected"
      assert Repo.get!(EngineTask, ctx.task.id, prefix: ctx.schema_name).status == :completed
      assert active_node_ids(ctx) == ["fallback_task"]
      assert refusal_audit_rows(ctx.schema_name) == []
    end
  end

  describe "C-9 -- default-off: no required_outputs" do
    test "the key may be omitted: the task completes and the fail-closed route is taken, exactly as today" do
      ctx = setup_case!(task_attrs: %{"form_schema" => decision_form()})

      assert {:ok, result} =
               Engine.complete_task(ctx.task.id, complete_attrs(%{"note" => "n"}),
                 prefix: ctx.schema_name
               )

      refute Map.has_key?(result.variables, "decision")
      assert active_node_ids(ctx) == ["fallback_task"]
      assert refusal_audit_rows(ctx.schema_name) == []
    end

    test "an empty required_outputs list is off as well" do
      ctx = setup_case!(task_attrs: %{"required_outputs" => []})

      assert {:ok, _result} =
               Engine.complete_task(ctx.task.id, complete_attrs(%{}), prefix: ctx.schema_name)
    end

    test "a malformed required_outputs attribute reads as off (logged), it never crashes a completion" do
      ctx = setup_case!(stored_graph_attrs: %{"required_outputs" => "decision"})

      log =
        capture_log(fn ->
          assert {:ok, _result} =
                   Engine.complete_task(ctx.task.id, complete_attrs(%{}), prefix: ctx.schema_name)
        end)

      assert log =~ "malformed required_outputs"
    end
  end

  # ---------------------------------------------------------------------------------
  # C-10 / C-11 -- form-expression re-evaluation precedence
  # ---------------------------------------------------------------------------------

  defp cross_field_form do
    %{
      "type" => "object",
      "properties" => %{
        "decision" => %{"type" => "string"},
        "amount" => %{"type" => "number"},
        "confirm" => %{
          "type" => "boolean",
          "x-ui" => %{
            "cross_field_validation" => %{
              "expression" => "amount > 0",
              "message" => "amount must be positive"
            }
          }
        }
      }
    }
  end

  describe "C-10 -- re-evaluation domain error with every required key present" do
    test "is still an EXECUTION_ERROR (unchanged), not an output refusal" do
      ctx =
        setup_case!(
          task_attrs: %{"required_outputs" => ["decision"], "form_schema" => cross_field_form()}
        )

      assert {:error,
              {:instance_execution_error, :form_cross_field_validation_failed,
               {:field, "confirm"}}} =
               Engine.complete_task(
                 ctx.task.id,
                 complete_attrs(%{"decision" => "approved", "amount" => -5, "confirm" => true}),
                 prefix: ctx.schema_name
               )

      assert Repo.get!(InstanceProjection, ctx.instance_id, prefix: ctx.schema_name).status ==
               :error

      assert [_event] = events_of_type(ctx, "EXECUTION_ERROR")
      assert refusal_audit_rows(ctx.schema_name) == []
    end
  end

  describe "C-11 -- missing required key AND a failing cross-field validation" do
    test "the output refusal wins: no EXECUTION_ERROR, instance stays active, nothing written" do
      ctx =
        setup_case!(
          task_attrs: %{"required_outputs" => ["decision"], "form_schema" => cross_field_form()}
        )

      before = rows(ctx)

      result =
        Engine.complete_task(
          ctx.task.id,
          complete_attrs(%{"amount" => -5, "confirm" => true}),
          prefix: ctx.schema_name
        )

      assert_refused_untouched!(ctx, before, result, ["decision"], [])
    end

    test "C-3/C-11 combined: a decision HELD by the instance does not satisfy the guard, so the refusal still precedes the cross-field EXECUTION_ERROR" do
      ctx =
        setup_case!(
          task_attrs: %{"required_outputs" => ["decision"], "form_schema" => cross_field_form()},
          initial_variables: %{"seed" => "value", "decision" => "approved"}
        )

      before = rows(ctx)

      result =
        Engine.complete_task(
          ctx.task.id,
          complete_attrs(%{"amount" => -5, "confirm" => true}),
          prefix: ctx.schema_name
        )

      assert_refused_untouched!(ctx, before, result, ["decision"], [])
    end
  end

  # ---------------------------------------------------------------------------------
  # C-12 -- engine-internal merges still reach EXECUTION_ERROR: the SUB_PROCESS
  # completion merge. (A service-task merge passes nil validations and cannot be
  # schema-rejected, so it is not a regression case: REQ-459 design 11.1.)
  # ---------------------------------------------------------------------------------

  describe "C-12 -- SUB_PROCESS completion merge still ends the parent in ERROR" do
    test "a child output the parent's variable_schema rejects: parent ERROR + EXECUTION_ERROR, nothing refused" do
      %{schema_name: schema_name} = provisioned_tenant()

      child_graph = %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{"id" => "work", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "worker"}},
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [
          %{"id" => "e1", "source" => "start", "target" => "work"},
          %{"id" => "e2", "source" => "work", "target" => "end"}
        ]
      }

      child_def = active_definition!(schema_name, child_graph)

      interface = %{
        "outputs" => [%{"name" => "result", "json_schema" => %{"type" => "boolean"}}]
      }

      parent_graph = %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{
            "id" => "sp",
            "node_type" => "SUB_PROCESS",
            "attributes" => %{"definition_name" => child_def.name, "interface" => interface}
          },
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [
          %{"id" => "e1", "source" => "start", "target" => "sp"},
          %{"id" => "e2", "source" => "sp", "target" => "end"}
        ]
      }

      parent_def = active_definition!(schema_name, parent_graph)
      seed_schema_row!(schema_name, parent_def.id, "result", %{"type" => "string"})

      parent_initial = %{"seed" => 1, "result" => "placeholder"}

      assert {:ok, created} =
               Engine.create(
                 %{
                   definition_id: parent_def.id,
                   initial_variables: parent_initial,
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: unique("start")
                 },
                 prefix: schema_name
               )

      child =
        InstanceProjection
        |> where([p], p.parent_instance_id == ^created.instance_id)
        |> Repo.one!(prefix: schema_name)

      child_task =
        EngineTask
        |> where([t], t.instance_id == ^child.instance_id and t.status == :pending)
        |> Repo.one!(prefix: schema_name)

      # The CHILD's HUMAN_TASK completion is accepted; the PARENT's merge rejects.
      assert {:ok, child_result} =
               Engine.complete_task(child_task.id, complete_attrs(%{"result" => true}),
                 prefix: schema_name
               )

      assert child_result.instance_status == :completed

      parent = Repo.get!(InstanceProjection, created.instance_id, prefix: schema_name)
      assert parent.status == :error
      assert parent.variables == parent_initial

      assert [event] =
               Event
               |> where(
                 [e],
                 e.instance_id == ^created.instance_id and e.event_type == "EXECUTION_ERROR"
               )
               |> Repo.all(prefix: schema_name)

      assert event.payload["error_type"] == "variable_schema_rejected"
      assert event.payload["affected"] == %{"kind" => "field", "key" => "result"}
      assert refusal_audit_rows(schema_name) == []
    end
  end

  # ---------------------------------------------------------------------------------
  # C-15 -- audit-write robustness (DROP-TABLE regression, ISS-0969 idiom)
  # ---------------------------------------------------------------------------------

  describe "C-15 -- the audit store is unavailable" do
    test "the refusal is the same {:error, {:output_refused, _}}, does not raise, and logs one warning; state untouched" do
      ctx = setup_case!(task_attrs: %{"required_outputs" => ["decision"]})
      before = rows(ctx)

      Repo.query!(~s(DROP TABLE "#{ctx.schema_name}".audit_entries))

      on_exit(fn ->
        Repo.query!(~s"""
        CREATE TABLE "#{ctx.schema_name}".audit_entries (
          id uuid PRIMARY KEY,
          tenant_id uuid NOT NULL,
          actor_id uuid,
          actor_kind text,
          action text NOT NULL,
          resource_type text NOT NULL,
          resource_id text NOT NULL,
          "timestamp" timestamp(6) without time zone NOT NULL,
          before_state jsonb,
          after_state jsonb,
          trace_id text,
          chain_hash text NOT NULL,
          prev_chain_hash text,
          inserted_at timestamp(6) without time zone NOT NULL
        )
        """)
      end)

      {result, log} =
        with_log(fn ->
          Engine.complete_task(ctx.task.id, complete_attrs(%{"note" => "SECRET-NOTE"}),
            prefix: ctx.schema_name
          )
        end)

      assert result ==
               {:error, {:output_refused, %{missing_keys: ["decision"], rejected_keys: []}}}

      assert rows(ctx) == before

      warnings = Regex.scan(~r/recording task\.completion_refused/, log)
      assert length(warnings) == 1
      assert log =~ ctx.task.id
      refute log =~ "SECRET-NOTE"
    end
  end
end
