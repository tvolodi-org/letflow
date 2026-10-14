defmodule Letflow.ClientKeyNamespaceTest do
  @moduledoc """
  GH #2550 -- caller-supplied idempotency keys live in their own namespace
  (design `lib/letflow/design/gh2550-client-idempotency-key-namespace.md` §3).
  Real Postgres, the real HTTP pipeline (`Letflow.Router` with an API token),
  and the real server writers (Scheduler, ServiceTaskDispatcher, Certificate,
  import, Attachments, Lua `emit_event`).

  Squat tests send the server key as a caller key FIRST, then run the server
  writer and assert it still did its work. Legacy tests insert pre-#2550
  rows directly via Repo (EventStore stamps `created_at` with now), dated
  `Idempotency.legacy_cutoff/0` plus or minus one day.

  `async: false`: `TenantFixture.provisioned_tenant!/1` switches the sandbox
  to `:auto`.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query

  alias Letflow.Definitions, as: ProcessDefinitions
  alias Letflow.Engine
  alias Letflow.Engine.Lua.Capabilities
  alias Letflow.Engine.Lua.Platform
  alias Letflow.Engine.Lua.Sandbox
  alias Letflow.Engine.ServiceTaskDispatcher
  alias Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.IdempotencyRecord
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.ExamFixtures
  alias Letflow.Idempotency
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Modules.Exam.Certificate
  alias Letflow.Modules.Exam.Session
  alias Letflow.Repository.Attachments
  alias Letflow.Scheduler
  alias Letflow.Scheduler.Timer
  alias Letflow.TenantFixture

  # ── HTTP ───────────────────────────────────────────────────────────────

  defp request(method, path, ctx, body, headers \\ []) do
    conn =
      case body do
        nil ->
          conn(method, path)

        body ->
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
      end

    headers
    |> Enum.reduce(conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> Letflow.Router.call(Letflow.Router.init([]))
  end

  defp body_of(conn), do: Jason.decode!(conn.resp_body)

  # ── Tenant / caller fixtures ───────────────────────────────────────────

  defp insert_user!(schema_name) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "gh2550-user-#{Ecto.UUID.generate()}",
      display_name: "GH-2550 User",
      email: "gh2550-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema_name)
  end

  # A caller with a real API token in an existing tenant schema.
  defp caller!(tenant_id, schema_name, roles) do
    user = insert_user!(schema_name)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: schema_name)

    %{
      tenant_id: tenant_id,
      schema_name: schema_name,
      slug: Repo.get!(Tenant, tenant_id).slug,
      plaintext: plaintext,
      user_id: user.id
    }
  end

  defp tenant_ctx(slug_prefix, roles \\ ["TENANT_ADMIN"]) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)
    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)
    ctx = caller!(tenant.tenant_id, tenant.schema_name, roles)
    seed_widget!(ctx)
    ctx
  end

  defp other_caller(ctx, roles \\ ["TENANT_ADMIN"]),
    do: caller!(ctx.tenant_id, ctx.schema_name, roles)

  defp seed_widget!(ctx) do
    {:ok, _} =
      Definitions.create_definition(
        %{
          definition: %{
            name: "widget",
            display_name: "Widget",
            fields: [
              %{name: "title", type: :string, required: true},
              %{name: "quantity", type: :integer}
            ]
          },
          created_by: ctx.user_id
        },
        ctx.schema_name
      )

    {:ok, _} = Definitions.activate_definition("widget", ctx.user_id, "gh2550", ctx.schema_name)
    :ok
  end

  defp post_record(ctx, key, field_values \\ %{"title" => "t"}) do
    body = %{"field_values" => field_values}
    body = if key, do: Map.put(body, "idempotency_key", key), else: body
    request(:post, "/api/v1/entities/records/widget", ctx, body)
  end

  defp put_record(ctx, record_id, key, field_values) do
    request(:put, "/api/v1/entities/records/widget/#{record_id}", ctx, %{
      "field_values" => field_values,
      "idempotency_key" => key
    })
  end

  defp seed_record!(ctx, field_values \\ %{"title" => "seeded"}) do
    {:ok, %{record: record}} =
      Records.create_record(
        %{
          entity_type: "widget",
          field_values: field_values,
          actor_id: ctx.user_id,
          idempotency_key: Ecto.UUID.generate()
        },
        ctx.schema_name
      )

    record
  end

  # ── Event reads ────────────────────────────────────────────────────────

  defp event_count(schema), do: Repo.aggregate(Event, :count, prefix: schema)

  defp events_with_key(schema, key),
    do: Repo.all(from(e in Event, where: e.idempotency_key == ^key), prefix: schema)

  defp events_of(schema, instance_id, event_type) do
    Repo.all(
      from(e in Event, where: e.instance_id == ^instance_id and e.event_type == ^event_type),
      prefix: schema
    )
  end

  defp widget_count(schema),
    do:
      Repo.aggregate(from(l in Latest, where: l.entity_type == "widget"), :count, prefix: schema)

  # ── Process fixtures ───────────────────────────────────────────────────

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

  defp active_process!(schema, graph) do
    {:ok, definition} =
      ProcessDefinitions.create(
        %{
          name: unique("gh2550-def"),
          version: "1.0.0",
          graph: graph,
          created_by: Ecto.UUID.generate()
        },
        prefix: schema
      )

    {:ok, %{definition: activated}} = ProcessDefinitions.activate(definition.id, prefix: schema)
    activated
  end

  defp start!(schema, definition) do
    {:ok, result} =
      Engine.create(
        %{
          definition_id: definition.id,
          initial_variables: %{},
          actor_id: Ecto.UUID.generate(),
          idempotency_key: unique("gh2550-start")
        },
        prefix: schema
      )

    result.instance_id
  end

  defp graph(nodes, edges), do: %{"nodes" => nodes, "edges" => edges}

  defp human_task_graph do
    graph(
      [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "task", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "approver"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    )
  end

  defp timer_graph do
    graph(
      [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "timer",
          "node_type" => "TIMER",
          "attributes" => %{"duration_iso8601" => "P1D"}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      [
        %{"id" => "e1", "source" => "start", "target" => "timer"},
        %{"id" => "e2", "source" => "timer", "target" => "end"}
      ]
    )
  end

  defp pending_timer!(schema, instance_id, type) do
    [timer] =
      Repo.all(
        from(t in Timer,
          where: t.instance_id == ^instance_id and t.status == "pending" and t.timer_type == ^type
        ),
        prefix: schema
      )

    timer
  end

  defp status(schema, instance_id),
    do: Repo.get!(InstanceProjection, instance_id, prefix: schema).status

  defp seed_projection!(schema) do
    instance_id = Ecto.UUID.generate()

    %InstanceProjection{}
    |> InstanceProjection.insert_changeset(%{
      instance_id: instance_id,
      status: :active,
      last_event_seq: 0,
      definition_id: Ecto.UUID.generate(),
      variables: %{}
    })
    |> Repo.insert!(prefix: schema)

    instance_id
  end

  # ── Lua emit_event (C6) ────────────────────────────────────────────────

  defp register_event_type!(tenant_id) do
    name = unique("gh2550_evt")

    {:ok, _} =
      Letflow.EventStore.Registry.register_type(
        %{
          "name" => name,
          "schema_version" => 1,
          "json_schema" => %{"type" => "object"},
          "description" => "GH-2550 fixture"
        },
        tenant_id
      )

    name
  end

  defp emit(ctx, instance_id, actor_id, event_type, key_literal) do
    lua =
      Platform.install(
        Sandbox.new(),
        Capabilities.new(["event:emit"]),
        Map.merge(Platform.empty_execution_context(), %{
          instance_id: instance_id,
          prefix: ctx.schema_name,
          actor_id: actor_id
        })
      )

    script = """
    local ok, err = platform.emit_event('#{event_type}', {reason = 'gh2550'}, #{key_literal})
    if ok then return true end
    return ok, err.reason
    """

    {result, _lua} = Lua.eval!(lua, script)
    result
  end

  # ── Legacy rows (D3) ───────────────────────────────────────────────────

  defp legacy_at(days), do: DateTime.add(Idempotency.legacy_cutoff(), days * 86_400, :second)

  # One pre-#2550 events row plus its event_idempotency row, written as the
  # old code would have, but with a chosen created_at.
  defp insert_legacy!(ctx, attrs) do
    {:ok, instance_id} = EntityTypeInstance.get_or_create("widget", ctx.schema_name)
    event_id = Ecto.UUID.generate()
    created_at = Map.fetch!(attrs, :created_at)
    key = Map.fetch!(attrs, :key)

    %Event{}
    |> Event.insert_changeset(%{
      event_id: event_id,
      created_at: created_at,
      instance_id: instance_id,
      event_type: Map.get(attrs, :event_type, "ENTITY_RECORD_CREATED"),
      payload: Map.fetch!(attrs, :payload),
      actor_id: Map.fetch!(attrs, :actor_id),
      sequence_number: 1_000_000 + System.unique_integer([:positive, :monotonic]),
      idempotency_key: key,
      metadata: %{}
    })
    |> Repo.insert!(prefix: ctx.schema_name)

    %IdempotencyRecord{}
    |> IdempotencyRecord.insert_changeset(%{
      idempotency_key: key,
      event_id: event_id,
      event_created_at: created_at
    })
    |> Repo.insert!(prefix: ctx.schema_name)

    event_id
  end

  defp legacy_payload(record_id, field_values) do
    %{
      "entity_type" => "widget",
      "record_id" => record_id,
      "field_values" => field_values,
      "entity_def_version" => "00ff"
    }
  end

  defp assert_too_long!(conn, schema, events_before, field, raw) do
    assert conn.status == 422
    body = body_of(conn)
    assert body["status"] == 422
    assert body["type"] == Letflow.Api.Error.unprocessable("x").type
    assert body["detail"] == "validation failed"

    assert [%{"field" => ^field, "constraint" => "max_length", "received" => nil}] =
             body["errors"]

    refute conn.resp_body =~ raw
    assert event_count(schema) == events_before
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC1 -- a squatted server key does not stop the server writer
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC1 squat: timer_fired:" do
    test "squat timer_fired: via a record POST -- the timer still fires and advances" do
      ctx = tenant_ctx("gh2550-sq-timer")
      instance_id = start!(ctx.schema_name, active_process!(ctx.schema_name, timer_graph()))
      timer = pending_timer!(ctx.schema_name, instance_id, "deadline")
      server_key = "timer_fired:#{timer.id}"

      assert post_record(ctx, server_key).status == 201
      assert {:ok, :fired} = Scheduler.fire_timer(timer.id, ctx.schema_name)

      assert [%Event{event_type: "TIMER_FIRED", instance_id: ^instance_id}] =
               events_with_key(ctx.schema_name, server_key)

      assert status(ctx.schema_name, instance_id) == :completed
    end

    test "squat timer_fired: via the POST /instances header -- the timer still fires" do
      ctx = tenant_ctx("gh2550-sq-timer-hdr")
      definition = active_process!(ctx.schema_name, timer_graph())
      instance_id = start!(ctx.schema_name, definition)
      timer = pending_timer!(ctx.schema_name, instance_id, "deadline")
      server_key = "timer_fired:#{timer.id}"

      squat =
        request(
          :post,
          "/api/v1/instances",
          ctx,
          %{"definition_id" => definition.id, "initial_variables" => %{}},
          [{"idempotency-key", server_key}]
        )

      assert squat.status == 201
      assert {:ok, :fired} = Scheduler.fire_timer(timer.id, ctx.schema_name)

      assert [%Event{event_type: "TIMER_FIRED", instance_id: ^instance_id}] =
               events_with_key(ctx.schema_name, server_key)
    end

    test "squat timer_fired: via Lua emit_event -- the timer still fires" do
      ctx = tenant_ctx("gh2550-sq-timer-lua")
      instance_id = start!(ctx.schema_name, active_process!(ctx.schema_name, timer_graph()))
      timer = pending_timer!(ctx.schema_name, instance_id, "deadline")
      server_key = "timer_fired:#{timer.id}"
      event_type = register_event_type!(ctx.tenant_id)
      other_instance = seed_projection!(ctx.schema_name)

      assert emit(ctx, other_instance, ctx.user_id, event_type, "'#{server_key}'") == [true]
      assert {:ok, :fired} = Scheduler.fire_timer(timer.id, ctx.schema_name)

      assert [%Event{event_type: "TIMER_FIRED", instance_id: ^instance_id}] =
               events_with_key(ctx.schema_name, server_key)
    end
  end

  describe "AC1 squat: escalation_timer_fired:" do
    test "squat escalation_timer_fired: -- the escalation still runs" do
      ctx = tenant_ctx("gh2550-sq-escl")

      graph =
        graph(
          [
            %{"id" => "start", "node_type" => "START"},
            %{
              "id" => "orig-task",
              "node_type" => "HUMAN_TASK",
              "attributes" => %{
                "role" => "approver",
                "escalation_timer_duration" => "P0D",
                "escalation_role" => "role-escalation"
              }
            },
            %{
              "id" => "escalated-task",
              "node_type" => "HUMAN_TASK",
              "attributes" => %{"role" => "role-escalation"}
            },
            %{"id" => "end", "node_type" => "END"}
          ],
          [
            %{"id" => "e1", "source" => "start", "target" => "orig-task"},
            %{"id" => "e2", "source" => "orig-task", "target" => "escalated-task"},
            %{"id" => "e3", "source" => "escalated-task", "target" => "end"}
          ]
        )

      instance_id = start!(ctx.schema_name, active_process!(ctx.schema_name, graph))
      timer = pending_timer!(ctx.schema_name, instance_id, "escalation")

      assert post_record(ctx, "escalation_timer_fired:#{timer.id}").status == 201
      assert post_record(ctx, "timer_fired:#{timer.id}").status == 201
      assert {:ok, :fired} = Scheduler.fire_timer(timer.id, ctx.schema_name)

      tasks = Repo.all(EngineTask, prefix: ctx.schema_name)
      assert Enum.any?(tasks, &(&1.node_id == "orig-task" and &1.status == :cancelled))
      assert Enum.any?(tasks, &(&1.node_id == "escalated-task" and &1.status == :pending))

      assert [%Event{event_type: "TIMER_FIRED", instance_id: ^instance_id}] =
               events_with_key(ctx.schema_name, "timer_fired:#{timer.id}")
    end
  end

  describe "AC1 squat: service_task_dispatch: and service_task:" do
    test "squat both service-task families (attempt 0) -- the dispatcher still completes the give-up" do
      ctx = tenant_ctx("gh2550-sq-svc")

      graph =
        graph(
          [
            %{"id" => "start", "node_type" => "START"},
            %{
              "id" => "svc",
              "node_type" => "SERVICE_TASK",
              "attributes" => %{"endpoint" => "https://127.0.0.1/hook", "timeout_ms" => 5_000}
            },
            %{"id" => "end", "node_type" => "END"}
          ],
          [
            %{"id" => "e1", "source" => "start", "target" => "svc"},
            %{"id" => "e2", "source" => "svc", "target" => "end"}
          ]
        )

      instance_id = start!(ctx.schema_name, active_process!(ctx.schema_name, graph))

      [dispatch] =
        Repo.all(from(d in ServiceTaskDispatch, where: d.instance_id == ^instance_id),
          prefix: ctx.schema_name
        )

      give_up_key =
        Letflow.Engine.ServiceTask.build_idempotency_key(
          instance_id,
          dispatch.node_id,
          dispatch.token_id,
          dispatch.attempt_index
        )

      assert dispatch.attempt_index == 0
      assert post_record(ctx, "service_task_dispatch:#{dispatch.id}").status == 201
      assert post_record(ctx, give_up_key).status == 201

      assert %{claimed: 1, given_up: 1} = ServiceTaskDispatcher.poll_and_dispatch(ctx.schema_name)

      assert status(ctx.schema_name, instance_id) == :error
      assert [%Event{instance_id: ^instance_id}] = events_with_key(ctx.schema_name, give_up_key)
    end
  end

  describe "AC1 squat: certificate:issue:" do
    test "another writer squats certificate:issue:<sid>, issuance still succeeds" do
      %{tenant_id: tenant_id, schema_name: schema} =
        ExamFixtures.provisioned_tenant_with_exam_definitions("gh2550-sq-cert")

      operator = caller!(tenant_id, schema, ["PROCESS_OPERATOR"])
      seed_widget!(caller!(tenant_id, schema, ["TENANT_ADMIN"]))

      category_id = Ecto.UUID.generate()

      exam =
        ExamFixtures.create_record!(schema, "exam", %{
          "title" => %{"en" => "GH-2550 Exam"},
          "status" => "active",
          "time_limit_minutes" => 30,
          "passing_score_pct" => 60.0,
          "max_attempts" => 5,
          "shuffle_questions" => false,
          "shuffle_options" => false,
          "show_answers" => "never",
          "on_tab_switch" => "log",
          "certificate_enabled" => true
        })

      question =
        ExamFixtures.create_record!(schema, "question", %{
          "category_id" => category_id,
          "difficulty" => "easy",
          "type" => "single",
          "default_locale" => "en",
          "status" => "active",
          "version" => 1,
          "stem" => %{"en" => "Stem?"}
        })

      correct =
        ExamFixtures.create_record!(schema, "answer_option", %{
          "question_id" => question.record_id,
          "sort_order" => 0,
          "is_correct" => true,
          "text" => %{"en" => "Yes"}
        })

      ExamFixtures.create_record!(schema, "answer_option", %{
        "question_id" => question.record_id,
        "sort_order" => 1,
        "is_correct" => false,
        "text" => %{"en" => "No"}
      })

      ExamFixtures.create_record!(schema, "exam_question_rule", %{
        "exam_id" => exam.record_id,
        "mode" => "random",
        "category_id" => category_id,
        "count" => 1,
        "sort_order" => 0
      })

      candidate_id = insert_user!(schema).id
      {:ok, view} = Session.create(candidate_id, exam.record_id, schema)

      {:ok, _} =
        Session.autosave_answer(
          view.id,
          candidate_id,
          %{
            question_id: question.record_id,
            selected_option_ids: [correct.record_id],
            time_spent_seconds: 5
          },
          schema
        )

      {:ok, %{status: :submitted, passed: true}} = Session.submit(view.id, candidate_id, schema)

      squat = post_record(operator, "certificate:issue:#{view.id}", %{"title" => "squat"})
      assert squat.status == 201
      squat_id = body_of(squat)["record_id"]

      assert {:ok, cert} = Certificate.issue_or_get_for_user(candidate_id, view.id, schema)
      assert cert.first_issuance == true
      assert cert.session_id == view.id
      assert cert.id != squat_id

      assert [%Event{event_type: "ENTITY_RECORD_CREATED", actor_id: ^candidate_id}] =
               events_with_key(schema, "certificate:issue:#{view.id}")
    end
  end

  describe "AC1 squat: entities-record-import:" do
    test "an import's stored key POSTed as a caller key is a separate write" do
      ctx = tenant_ctx("gh2550-sq-import")
      source_id = Ecto.UUID.generate()
      values = %{"title" => "imported"}

      resp =
        request(:post, "/api/v1/entities/records/widget/import", ctx, %{
          "record_export_schema_version" => "entities/record-export/v1",
          "entity_type" => "widget",
          "exported_at" => "2026-09-12T00:00:00Z",
          "records" => [%{"record_id" => source_id, "field_values" => values, "deleted" => false}]
        })

      assert resp.status == 200

      [import_key] =
        Repo.all(
          from(e in Event,
            where: like(e.idempotency_key, "entities-record-import:%"),
            select: e.idempotency_key
          ),
          prefix: ctx.schema_name
        )

      [imported] =
        Repo.all(from(l in Latest, where: l.entity_type == "widget"), prefix: ctx.schema_name)

      conn = post_record(ctx, import_key, values)
      assert conn.status == 201
      assert body_of(conn)["record_id"] != imported.record_id
      assert widget_count(ctx.schema_name) == 2
    end
  end

  describe "AC1 squat: attachment_removed:" do
    test "squat attachment_removed: -- removing the attachment still records ATTACHMENT_REMOVED" do
      ctx = tenant_ctx("gh2550-sq-attach")
      instance_id = seed_projection!(ctx.schema_name)

      {:ok, attachment} =
        Attachments.upload(
          %{
            instance_id: instance_id,
            raw_bytes: "gh2550 bytes",
            file_name: "note.txt",
            content_type: "text/plain",
            uploaded_by: ctx.user_id,
            description: nil
          },
          prefix: ctx.schema_name
        )

      server_key = "attachment_removed:" <> attachment.id
      assert post_record(ctx, server_key).status == 201
      assert {:ok, _} = Attachments.delete(attachment.id, ctx.user_id, prefix: ctx.schema_name)

      assert [%Event{event_type: "ATTACHMENT_REMOVED", instance_id: ^instance_id}] =
               events_with_key(ctx.schema_name, server_key)
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC2 -- same-request replay stays idempotent (rec, and C6 via EventStore)
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC2 replay" do
    test "POST twice with K -> same record_id, no new event" do
      ctx = tenant_ctx("gh2550-replay-post")
      first = post_record(ctx, "K-post")
      count = event_count(ctx.schema_name)
      second = post_record(ctx, "K-post")

      assert first.status == 201 and second.status == 201
      assert body_of(first)["record_id"] == body_of(second)["record_id"]
      assert event_count(ctx.schema_name) == count
    end

    test "PUT twice with K -> same result, no new event" do
      ctx = tenant_ctx("gh2550-replay-put")
      record = seed_record!(ctx)
      first = put_record(ctx, record.record_id, "K-put", %{"title" => "new"})
      count = event_count(ctx.schema_name)
      second = put_record(ctx, record.record_id, "K-put", %{"title" => "new"})

      assert first.status == 200 and second.status == 200
      assert body_of(first) == body_of(second)
      assert event_count(ctx.schema_name) == count
    end

    test "create then update with one K -> 422 reuse (C1 and C2 share rec)" do
      ctx = tenant_ctx("gh2550-replay-cross")
      record = seed_record!(ctx)
      assert post_record(ctx, "K-shared").status == 201

      conn = put_record(ctx, record.record_id, "K-shared", %{"title" => "t"})
      assert conn.status == 422
      assert body_of(conn)["code"] == "idempotency_key_reuse"
    end

    test "another actor's K is a separate write" do
      ctx = tenant_ctx("gh2550-replay-actor")
      first = post_record(ctx, "K-actor")
      second = post_record(other_caller(ctx), "K-actor")

      assert first.status == 201 and second.status == 201
      assert body_of(first)["record_id"] != body_of(second)["record_id"]
    end

    test "emit_event twice with K -> one event" do
      ctx = tenant_ctx("gh2550-replay-lua")
      event_type = register_event_type!(ctx.tenant_id)
      instance_id = seed_projection!(ctx.schema_name)

      assert emit(ctx, instance_id, ctx.user_id, event_type, "'K-lua'") == [true]
      assert emit(ctx, instance_id, ctx.user_id, event_type, "'K-lua'") == [true]
      assert length(events_of(ctx.schema_name, instance_id, event_type)) == 1
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC4 -- constrained legacy lookup (D3), rec only
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC4 legacy lookup" do
    test "legacy key, same actor, before cutoff -> duplicate" do
      ctx = tenant_ctx("gh2550-legacy-hit")
      record_id = Ecto.UUID.generate()
      values = %{"title" => "legacy"}

      insert_legacy!(ctx, %{
        key: "legacy-k",
        actor_id: ctx.user_id,
        created_at: legacy_at(-1),
        payload: legacy_payload(record_id, values)
      })

      count = event_count(ctx.schema_name)
      conn = post_record(ctx, "legacy-k", values)

      assert conn.status == 201
      assert body_of(conn)["record_id"] == record_id
      assert event_count(ctx.schema_name) == count
    end

    test "legacy PUT key (ENTITY_RECORD_UPDATED), same actor, before cutoff -> duplicate" do
      ctx = tenant_ctx("gh2550-legacy-put")
      record = seed_record!(ctx)
      values = %{"title" => "legacy-update"}

      insert_legacy!(ctx, %{
        key: "legacy-put-k",
        actor_id: ctx.user_id,
        event_type: "ENTITY_RECORD_UPDATED",
        created_at: legacy_at(-1),
        payload: legacy_payload(record.record_id, values)
      })

      count = event_count(ctx.schema_name)
      conn = put_record(ctx, record.record_id, "legacy-put-k", values)

      assert conn.status == 200
      assert body_of(conn)["record_id"] == record.record_id
      assert body_of(conn)["field_values"] == values
      assert event_count(ctx.schema_name) == count

      {:ok, stored} = Latest.get(record.record_id, "widget", ctx.schema_name)
      assert stored.field_values == record.field_values
    end

    test "legacy key with different values -> 422 reuse (match_original still binds)" do
      ctx = tenant_ctx("gh2550-legacy-reuse")

      insert_legacy!(ctx, %{
        key: "legacy-k2",
        actor_id: ctx.user_id,
        created_at: legacy_at(-1),
        payload: legacy_payload(Ecto.UUID.generate(), %{"title" => "legacy"})
      })

      count = event_count(ctx.schema_name)
      conn = post_record(ctx, "legacy-k2", %{"title" => "different"})

      assert conn.status == 422
      assert body_of(conn)["code"] == "idempotency_key_reuse"
      assert event_count(ctx.schema_name) == count
    end

    test "legacy server key from a client is not a duplicate" do
      ctx = tenant_ctx("gh2550-legacy-server")
      values = %{"title" => "legacy"}
      server_key = "timer_fired:#{Ecto.UUID.generate()}"
      fixture_record = Ecto.UUID.generate()

      event_id =
        insert_legacy!(ctx, %{
          key: server_key,
          actor_id: ctx.user_id,
          created_at: legacy_at(-1),
          payload: legacy_payload(fixture_record, values)
        })

      count = event_count(ctx.schema_name)
      conn = post_record(ctx, server_key, values)

      assert conn.status == 201
      assert body_of(conn)["record_id"] != fixture_record
      assert event_count(ctx.schema_name) == count + 1

      assert [%IdempotencyRecord{event_id: ^event_id}] =
               Repo.all(from(i in IdempotencyRecord, where: i.idempotency_key == ^server_key),
                 prefix: ctx.schema_name
               )
    end

    test "legacy key from a different actor -> not a duplicate" do
      ctx = tenant_ctx("gh2550-legacy-actor")
      values = %{"title" => "legacy"}
      fixture_record = Ecto.UUID.generate()

      insert_legacy!(ctx, %{
        key: "legacy-k3",
        actor_id: Ecto.UUID.generate(),
        created_at: legacy_at(-1),
        payload: legacy_payload(fixture_record, values)
      })

      count = event_count(ctx.schema_name)
      conn = post_record(ctx, "legacy-k3", values)

      assert conn.status == 201
      assert body_of(conn)["record_id"] != fixture_record
      assert event_count(ctx.schema_name) == count + 1
    end

    test "legacy row of an event type the route cannot produce -> not a duplicate" do
      ctx = tenant_ctx("gh2550-legacy-type")
      values = %{"title" => "legacy"}
      fixture_record = Ecto.UUID.generate()

      insert_legacy!(ctx, %{
        key: "legacy-k4",
        actor_id: ctx.user_id,
        event_type: "ENTITY_RECORD_DELETED",
        created_at: legacy_at(-1),
        payload: legacy_payload(fixture_record, values)
      })

      count = event_count(ctx.schema_name)
      conn = post_record(ctx, "legacy-k4", values)

      assert conn.status == 201
      assert body_of(conn)["record_id"] != fixture_record
      assert event_count(ctx.schema_name) == count + 1
    end

    test "legacy row after the cutoff -> ignored" do
      ctx = tenant_ctx("gh2550-legacy-cutoff")
      values = %{"title" => "legacy"}
      fixture_record = Ecto.UUID.generate()

      insert_legacy!(ctx, %{
        key: "legacy-k5",
        actor_id: ctx.user_id,
        created_at: legacy_at(1),
        payload: legacy_payload(fixture_record, values)
      })

      count = event_count(ctx.schema_name)
      conn = post_record(ctx, "legacy-k5", values)

      assert conn.status == 201
      assert body_of(conn)["record_id"] != fixture_record
      assert event_count(ctx.schema_name) == count + 1
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC5 -- the stored key, per entry point
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC5 stored key per entry point" do
    test "C1 POST record stores client:rec:<actor>:K" do
      ctx = tenant_ctx("gh2550-c1")
      assert post_record(ctx, "K1").status == 201

      assert [%Event{event_type: "ENTITY_RECORD_CREATED"}] =
               events_with_key(ctx.schema_name, "client:rec:#{ctx.user_id}:K1")

      assert events_with_key(ctx.schema_name, "K1") == []
    end

    test "C2 PUT record stores client:rec:<actor>:K" do
      ctx = tenant_ctx("gh2550-c2")
      record = seed_record!(ctx)
      assert put_record(ctx, record.record_id, "K2", %{"title" => "x"}).status == 200

      assert [%Event{event_type: "ENTITY_RECORD_UPDATED"}] =
               events_with_key(ctx.schema_name, "client:rec:#{ctx.user_id}:K2")
    end

    test "C3 POST /instances stores client:inst_start:<actor>:K" do
      ctx = tenant_ctx("gh2550-c3")
      definition = active_process!(ctx.schema_name, human_task_graph())

      conn =
        request(
          :post,
          "/api/v1/instances",
          ctx,
          %{"definition_id" => definition.id, "initial_variables" => %{}},
          [{"idempotency-key", "K3"}]
        )

      assert conn.status == 201
      instance_id = body_of(conn)["instance_id"]

      assert [%Event{event_type: "INSTANCE_STARTED", instance_id: ^instance_id}] =
               events_with_key(ctx.schema_name, "client:inst_start:#{ctx.user_id}:K3")
    end

    test "C4 cancel stores client:inst_cancel:<actor>:<instance>:K" do
      ctx = tenant_ctx("gh2550-c4")
      instance_id = start!(ctx.schema_name, active_process!(ctx.schema_name, human_task_graph()))

      conn =
        request(:post, "/api/v1/instances/#{instance_id}/cancel", ctx, nil, [
          {"idempotency-key", "K4"}
        ])

      assert conn.status == 200

      assert [%Event{event_type: "INSTANCE_CANCELLED", instance_id: ^instance_id}] =
               events_with_key(
                 ctx.schema_name,
                 "client:inst_cancel:#{ctx.user_id}:#{instance_id}:K4"
               )
    end

    test "C5 rebind stores client:inst_rebind:<actor>:<instance>:K" do
      ctx = tenant_ctx("gh2550-c5")
      definition = active_process!(ctx.schema_name, human_task_graph())
      instance_id = start!(ctx.schema_name, definition)

      assert rebind(ctx, instance_id, definition, "K5").status == 200

      assert [%Event{event_type: "INSTANCE_PINS_REBOUND", instance_id: ^instance_id}] =
               events_with_key(
                 ctx.schema_name,
                 "client:inst_rebind:#{ctx.user_id}:#{instance_id}:K5"
               )
    end

    test "C6 emit_event stores script:<actor>:K" do
      ctx = tenant_ctx("gh2550-c6")
      event_type = register_event_type!(ctx.tenant_id)
      instance_id = seed_projection!(ctx.schema_name)

      assert emit(ctx, instance_id, ctx.user_id, event_type, "'K6'") == [true]

      assert [%Event{event_type: ^event_type}] =
               events_with_key(ctx.schema_name, "script:#{ctx.user_id}:K6")
    end
  end

  defp rebind(ctx, instance_id, definition, key) do
    request(
      :post,
      "/api/v1/instances/#{instance_id}/rebind-pins",
      ctx,
      %{
        "reason" => "GH-2550",
        "entries" => [%{"kind" => "variable_schema", "ref" => definition.name, "version" => "v2"}]
      },
      [{"idempotency-key", key}]
    )
  end

  # ═══════════════════════════════════════════════════════════════════════
  # D6 -- cancel/rebind keys carry the instance
  # ═══════════════════════════════════════════════════════════════════════

  describe "cross-instance" do
    test "same actor, same K, different instance on cancel -> both cancels write INSTANCE_CANCELLED" do
      ctx = tenant_ctx("gh2550-x-cancel")
      definition = active_process!(ctx.schema_name, human_task_graph())
      a = start!(ctx.schema_name, definition)
      b = start!(ctx.schema_name, definition)

      for id <- [a, b] do
        conn =
          request(:post, "/api/v1/instances/#{id}/cancel", ctx, nil, [{"idempotency-key", "Kx"}])

        assert conn.status == 200
      end

      assert [_] = events_of(ctx.schema_name, a, "INSTANCE_CANCELLED")
      assert [_] = events_of(ctx.schema_name, b, "INSTANCE_CANCELLED")
    end

    test "same actor, same K, different instance on rebind -> both write INSTANCE_PINS_REBOUND" do
      ctx = tenant_ctx("gh2550-x-rebind")
      definition = active_process!(ctx.schema_name, human_task_graph())
      a = start!(ctx.schema_name, definition)
      b = start!(ctx.schema_name, definition)

      assert rebind(ctx, a, definition, "Ky").status == 200
      assert rebind(ctx, b, definition, "Ky").status == 200

      assert [_] = events_of(ctx.schema_name, a, "INSTANCE_PINS_REBOUND")
      assert [_] = events_of(ctx.schema_name, b, "INSTANCE_PINS_REBOUND")
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # F1 -- invalid UTF-8 / NUL keys are refused before any DB access
  # (pre-existing 500s), F2 -- `sys:` is reserved
  # ═══════════════════════════════════════════════════════════════════════

  defp idempotency_row_count(schema),
    do: Repo.aggregate(IdempotencyRecord, :count, prefix: schema)

  defp assert_invalid_key!(conn, ctx, {events, rows}, field) do
    assert conn.status == 422
    body = body_of(conn)
    assert body["detail"] == "validation failed"

    assert [%{"field" => ^field, "constraint" => "format", "received" => nil}] = body["errors"]

    assert event_count(ctx.schema_name) == events
    assert idempotency_row_count(ctx.schema_name) == rows
  end

  defp write_counts(ctx),
    do: {event_count(ctx.schema_name), idempotency_row_count(ctx.schema_name)}

  describe "F1 invalid keys" do
    test "body key with NUL -> 422 format on POST and PUT, nothing written" do
      ctx = tenant_ctx("gh2550-nul-body")
      record = seed_record!(ctx)
      before = write_counts(ctx)

      # Over HTTP the body's NUL is already refused by Letflow.Api.Validation's
      # structural no_null_byte check, before Idempotency.from_body/3 (whose own
      # refusal is unit-tested in idempotency_test.exs); either way a 422, never
      # the legacy SELECT.
      for conn <- [
            post_record(ctx, "a" <> <<0>> <> "b"),
            put_record(ctx, record.record_id, "a" <> <<0>> <> "b", %{"title" => "x"})
          ] do
        assert conn.status == 422

        assert [
                 %{
                   "field" => "(root).idempotency_key",
                   "constraint" => "no_null_byte",
                   "received" => nil
                 }
               ] =
                 body_of(conn)["errors"]

        assert write_counts(ctx) == before
      end
    end

    test "header with invalid UTF-8 or NUL -> 422 format on start, cancel and rebind, nothing written" do
      ctx = tenant_ctx("gh2550-bad-hdr")
      definition = active_process!(ctx.schema_name, human_task_graph())
      instance_id = start!(ctx.schema_name, definition)
      before = write_counts(ctx)

      for raw <- [<<0xFF, 0xFE>>, "ok" <> <<0xC3>>, "a" <> <<0>> <> "b"] do
        start =
          request(
            :post,
            "/api/v1/instances",
            ctx,
            %{"definition_id" => definition.id, "initial_variables" => %{}},
            [{"idempotency-key", raw}]
          )

        assert_invalid_key!(start, ctx, before, "idempotency-key")

        cancel =
          request(:post, "/api/v1/instances/#{instance_id}/cancel", ctx, nil, [
            {"idempotency-key", raw}
          ])

        assert_invalid_key!(cancel, ctx, before, "idempotency-key")

        assert_invalid_key!(
          rebind(ctx, instance_id, definition, raw),
          ctx,
          before,
          "idempotency-key"
        )
      end

      assert status(ctx.schema_name, instance_id) == :active
      assert Repo.aggregate(InstanceProjection, :count, prefix: ctx.schema_name) == 1
    end

    test "Lua emit_event with a NUL key -> invalid_arguments, nothing written" do
      ctx = tenant_ctx("gh2550-nul-lua")
      event_type = register_event_type!(ctx.tenant_id)
      instance_id = seed_projection!(ctx.schema_name)
      before = write_counts(ctx)

      assert emit(ctx, instance_id, ctx.user_id, event_type, "'a\\0b'") ==
               [nil, "invalid_arguments"]

      assert write_counts(ctx) == before
    end
  end

  describe "F2 reserved sys:" do
    test "a client sys:step: key on POST/PUT is stored namespaced and never hits a bare sys: row" do
      ctx = tenant_ctx("gh2550-sys")
      values = %{"title" => "sys"}
      fixture_record = Ecto.UUID.generate()

      # A bare row that passes legacy guards (i)-(iii): only the reserved
      # prefix keeps it from being a legacy hit.
      event_id =
        insert_legacy!(ctx, %{
          key: "sys:step:x",
          actor_id: ctx.user_id,
          created_at: legacy_at(-1),
          payload: legacy_payload(fixture_record, values)
        })

      count = event_count(ctx.schema_name)
      conn = post_record(ctx, "sys:step:x", values)

      assert conn.status == 201
      assert body_of(conn)["record_id"] != fixture_record
      assert event_count(ctx.schema_name) == count + 1

      assert [%Event{event_type: "ENTITY_RECORD_CREATED"}] =
               events_with_key(ctx.schema_name, "client:rec:#{ctx.user_id}:sys:step:x")

      assert [%IdempotencyRecord{event_id: ^event_id}] =
               Repo.all(from(i in IdempotencyRecord, where: i.idempotency_key == "sys:step:x"),
                 prefix: ctx.schema_name
               )

      record = seed_record!(ctx)
      assert put_record(ctx, record.record_id, "sys:step:y", %{"title" => "y"}).status == 200

      assert [%Event{event_type: "ENTITY_RECORD_UPDATED"}] =
               events_with_key(ctx.schema_name, "client:rec:#{ctx.user_id}:sys:step:y")

      assert events_with_key(ctx.schema_name, "sys:step:y") == []
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # D5 -- over-long keys are refused, never truncated
  # ═══════════════════════════════════════════════════════════════════════

  describe "D5 length" do
    test "body: 200 bytes -> 422, 199-byte multibyte -> 201 stored within 255 bytes" do
      ctx = tenant_ctx("gh2550-len-body")
      too_long = String.duplicate("é", 100)
      before = event_count(ctx.schema_name)

      conn = post_record(ctx, too_long)
      assert_too_long!(conn, ctx.schema_name, before, "idempotency_key", too_long)

      record = seed_record!(ctx)
      before = event_count(ctx.schema_name)
      conn = put_record(ctx, record.record_id, too_long, %{"title" => "x"})
      assert_too_long!(conn, ctx.schema_name, before, "idempotency_key", too_long)

      fits = String.duplicate("é", 99) <> "a"
      assert byte_size(fits) == 199
      assert post_record(ctx, fits).status == 201

      [stored] = events_with_key(ctx.schema_name, "client:rec:#{ctx.user_id}:" <> fits)
      assert byte_size(stored.idempotency_key) <= 255
    end

    test "start header: 200 bytes -> 422" do
      ctx = tenant_ctx("gh2550-len-start")
      definition = active_process!(ctx.schema_name, human_task_graph())
      too_long = String.duplicate("k", 200)
      before = event_count(ctx.schema_name)

      conn =
        request(
          :post,
          "/api/v1/instances",
          ctx,
          %{"definition_id" => definition.id, "initial_variables" => %{}},
          [{"idempotency-key", too_long}]
        )

      assert_too_long!(conn, ctx.schema_name, before, "idempotency-key", too_long)

      assert Repo.aggregate(InstanceProjection, :count, prefix: ctx.schema_name) == 0
    end

    test "cancel/rebind header: 163 -> 422, 162 -> 200 stored within 255 bytes" do
      ctx = tenant_ctx("gh2550-len-inst")
      definition = active_process!(ctx.schema_name, human_task_graph())
      instance_id = start!(ctx.schema_name, definition)
      k163 = String.duplicate("k", 163)
      k162 = String.duplicate("k", 162)

      before = event_count(ctx.schema_name)

      conn =
        request(:post, "/api/v1/instances/#{instance_id}/cancel", ctx, nil, [
          {"idempotency-key", k163}
        ])

      assert_too_long!(conn, ctx.schema_name, before, "idempotency-key", k163)
      assert status(ctx.schema_name, instance_id) == :active

      conn = rebind(ctx, instance_id, definition, k163)
      assert_too_long!(conn, ctx.schema_name, before, "idempotency-key", k163)

      assert rebind(ctx, instance_id, definition, k162).status == 200

      conn =
        request(:post, "/api/v1/instances/#{instance_id}/cancel", ctx, nil, [
          {"idempotency-key", k162}
        ])

      assert conn.status == 200

      for route <- ["inst_rebind", "inst_cancel"] do
        [stored] =
          events_with_key(
            ctx.schema_name,
            "client:#{route}:#{ctx.user_id}:#{instance_id}:#{k162}"
          )

        assert byte_size(stored.idempotency_key) == 255
      end
    end

    test "script: 300 bytes and empty -> invalid_arguments, nothing written" do
      ctx = tenant_ctx("gh2550-len-lua")
      event_type = register_event_type!(ctx.tenant_id)
      instance_id = seed_projection!(ctx.schema_name)

      assert emit(ctx, instance_id, ctx.user_id, event_type, "string.rep('k', 300)") ==
               [nil, "invalid_arguments"]

      assert emit(ctx, instance_id, ctx.user_id, event_type, "''") == [nil, "invalid_arguments"]
      assert events_of(ctx.schema_name, instance_id, event_type) == []
    end
  end
end
