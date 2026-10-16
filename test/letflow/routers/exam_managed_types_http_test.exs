defmodule Letflow.Routers.ExamManagedTypesHttpTest do
  @moduledoc """
  GH #2596 T-12, T-13, T-20, T-22, T-23 (AC3 sub, AC5, AC8), design
  `lib/letflow/design/gh2596-exam-managed-types.md` sections 4.4 and 10 (spec
  `test/specs/GH2596-exam-managed.md`): the generic HTTP surface on an exam tenant AFTER the stamp.

    * T-20: each of the six runtime types refuses generic POST / PUT / DELETE / import with the
      constant 403 `entity_type_managed`, for a write-permission role AND TENANT_ADMIN; the record
      is unchanged and no `ENTITY_RECORD_*` event is appended. Fails on main, where the six are
      unmanaged and the writes succeed.
    * T-23 (control, the ruling): the ten AUTHORING types stay writable through the same routes for
      both caller kinds, and the stamp touched none of their definition rows.
    * T-22: reads (query, aggregate, definitions, answer-key field restriction) behave as before.
    * T-12: the definitions API (create / activate) still cannot stamp or unstamp, even with a
      `managed_by` key in the body, after the exception exists.
    * T-13: a pack document carrying `managed_by` is rejected, and a tenant pack install over the
      stamped names changes nothing.

  Requests go straight into `Letflow.Routers.Entities` with a hand-assigned `auth_context` (the
  `Authorize` pass inside the router still runs), with `trace_id` pinned so a refusal body compares
  byte for byte with `Error.serialise/1` of the constant problem (the technique of
  `Letflow.Routers.EntitiesManagedByTest`).

  Runs OUTSIDE the Ecto sandbox transaction: `async: false`, the fixture switches the sandbox to
  `:auto` because `Stamp` refuses to run inside a transaction.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.Api.Error
  alias Letflow.Definitions.SolutionPack
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.ManagedTypes.Stamp
  alias Letflow.Entities.Record.Latest
  alias Letflow.EventStore.Event
  alias Letflow.ExamFixtures
  alias Letflow.ExamStampFixtures, as: Fx
  alias Letflow.Identity.User

  @entities_opts Letflow.Routers.Entities.init([])
  @trace "gh2596-fixed-trace"

  @operator ["PROCESS_OPERATOR"]
  @admin ["TENANT_ADMIN"]
  @designer ["PROCESS_DESIGNER"]
  @task_worker ["TASK_WORKER"]

  @six Fx.runtime_types()
  @ten Fx.authoring_types()

  # ── helpers ─────────────────────────────────────────────────────────────────────────────────

  defp insert_user!(schema) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "gh2596-http-#{Ecto.UUID.generate()}",
      display_name: "GH2596 HTTP Test User",
      email: "gh2596-http-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema)
  end

  defp call_entities(ctx, roles, method, path, body) do
    conn = Plug.Test.conn(method, path)

    conn =
      case body do
        nil -> conn
        body -> %{conn | body_params: body} |> put_req_header("content-type", "application/json")
      end

    conn
    |> assign(:auth_context, %{user_id: ctx.actor_id, tenant_id: ctx.tenant_id, roles: roles})
    |> assign(:trace_id, @trace)
    |> Letflow.Routers.Entities.call(@entities_opts)
  end

  defp managed_body, do: Error.serialise(%{Error.entity_type_managed() | trace_id: @trace})

  defp assert_managed!(conn, label) do
    assert conn.status == 403, "#{label}: #{conn.status} #{conn.resp_body}"
    assert conn.resp_body == managed_body(), "#{label}: #{conn.resp_body}"
  end

  defp body_of(conn), do: Jason.decode!(conn.resp_body)

  defp event_count(schema), do: Repo.aggregate(Event, :count, prefix: schema)

  defp record_count(schema, type) do
    Repo.aggregate(from(l in Latest, where: l.entity_type == ^type), :count, prefix: schema)
  end

  defp stored(ctx, type, id) do
    {:ok, record} = Latest.get(id, type, ctx.schema)
    Map.take(record, [:field_values, :deleted, :last_event_global_seq])
  end

  defp definition_count(schema, name),
    do:
      Repo.aggregate(from(d in EntityDefinition, where: d.name == ^name), :count, prefix: schema)

  defp iso(offset),
    do: DateTime.utc_now() |> DateTime.add(offset, :second) |> DateTime.to_iso8601()

  # Valid field_values for every one of the sixteen types.
  defp values("session", _n) do
    %{
      "exam_id" => Ecto.UUID.generate(),
      "user_id" => Ecto.UUID.generate(),
      "status" => "in_progress",
      "seed" => 1,
      "started_at" => iso(0),
      "expires_at" => iso(3600),
      "passed" => false
    }
  end

  defp values("session_question", n) do
    %{
      "session_id" => Ecto.UUID.generate(),
      "question_id" => Ecto.UUID.generate(),
      "sort_order" => n,
      "options_order" => ["a", "b"]
    }
  end

  defp values("session_answer", n) do
    %{
      "session_id" => Ecto.UUID.generate(),
      "question_id" => Ecto.UUID.generate(),
      "saved_at" => iso(0),
      "time_spent_seconds" => n
    }
  end

  defp values("session_event", _n) do
    %{
      "session_id" => Ecto.UUID.generate(),
      "occurred_at" => iso(0),
      "action_taken" => "log",
      "event_type" => "blur"
    }
  end

  defp values("session_question_score", _n) do
    %{
      "session_id" => Ecto.UUID.generate(),
      "question_id" => Ecto.UUID.generate(),
      "score" => 1.0,
      "max_score" => 1.0,
      "grading_status" => "graded"
    }
  end

  defp values("certificate", _n) do
    %{
      "session_id" => Ecto.UUID.generate(),
      "issued_at" => iso(0),
      "candidate_name" => "GH2596 Candidate",
      "exam_title" => %{"en" => "Exam"},
      "score_pct" => 90.0,
      "branding_snapshot" => %{}
    }
  end

  defp values("category", n),
    do: %{"name" => %{"kk" => "k#{n}", "ru" => "r#{n}", "en" => "e#{n}"}, "sort_order" => n}

  defp values("tag", n), do: %{"name" => "tag-#{n}-#{System.unique_integer([:positive])}"}

  defp values("exam", n) do
    %{
      "title" => %{"en" => "Exam #{n}"},
      "status" => "active",
      "time_limit_minutes" => 30,
      "passing_score_pct" => 60.0,
      "max_attempts" => 3,
      "shuffle_questions" => false,
      "shuffle_options" => false,
      "show_answers" => "never",
      "on_tab_switch" => "log",
      "certificate_enabled" => false
    }
  end

  defp values("exam_section", n),
    do: %{"exam_id" => Ecto.UUID.generate(), "title" => %{"en" => "S#{n}"}, "sort_order" => n}

  defp values("exam_question_rule", n) do
    %{
      "exam_id" => Ecto.UUID.generate(),
      "mode" => "random",
      "category_id" => Ecto.UUID.generate(),
      "count" => 1,
      "sort_order" => n
    }
  end

  defp values("exam_question_rule_tag", _n),
    do: %{"rule_id" => Ecto.UUID.generate(), "tag_id" => Ecto.UUID.generate()}

  defp values("exam_manual_question", n) do
    %{"rule_id" => Ecto.UUID.generate(), "question_id" => Ecto.UUID.generate(), "sort_order" => n}
  end

  defp values("question", n) do
    %{
      "category_id" => Ecto.UUID.generate(),
      "difficulty" => "easy",
      "type" => "single",
      "default_locale" => "en",
      "status" => "active",
      "version" => n,
      "stem" => %{"en" => "Stem #{n}?"}
    }
  end

  defp values("answer_option", n) do
    %{
      "question_id" => Ecto.UUID.generate(),
      "sort_order" => n,
      "is_correct" => true,
      "text" => %{"en" => "Option #{n}"}
    }
  end

  defp values("question_tag", _n),
    do: %{"question_id" => Ecto.UUID.generate(), "tag_id" => Ecto.UUID.generate()}

  defp import_document(type, count) do
    %{
      "record_export_schema_version" => "entities/record-export/v1",
      "entity_type" => type,
      "exported_at" => "2026-10-16T00:00:00Z",
      "records" =>
        for i <- 1..count do
          %{
            "record_id" => Ecto.UUID.generate(),
            "field_values" => values(type, i),
            "deleted" => false
          }
        end
    }
  end

  # An exam tenant with all sixteen definitions active, one record per type created BEFORE the
  # stamp, then stamped. Returns the context plus %{type => record_id}.
  setup do
    %{tenant_id: tenant_id, schema_name: schema} = Fx.full_tenant!("gh2596-http")
    actor = insert_user!(schema)

    records =
      for type <- @six ++ @ten, into: %{} do
        {type, ExamFixtures.create_record!(schema, type, values(type, 1)).record_id}
      end

    ten_before_stamp = Fx.dump(schema, @ten)

    items_before =
      for type <- @six, into: %{}, do: {type, query_items(tenant_id, actor.id, schema, type)}

    assert %{status: :stamped, rows_stamped: 6, error: nil} = Stamp.run_tenant(schema, [])

    {:ok,
     tenant_id: tenant_id,
     schema: schema,
     actor_id: actor.id,
     records: records,
     ten_before_stamp: ten_before_stamp,
     items_before: items_before}
  end

  defp query_items(tenant_id, actor_id, schema, type) do
    ctx = %{tenant_id: tenant_id, actor_id: actor_id, schema: schema}
    conn = call_entities(ctx, @admin, :post, "/query", %{"entity_type" => type})
    assert conn.status == 200, conn.resp_body
    body_of(conn)["items"]
  end

  # ── T-20 ────────────────────────────────────────────────────────────────────────────────────

  describe "T-20 (AC5): generic writes of the six runtime types are refused on a stamped tenant" do
    test "POST, PUT and DELETE -> the constant 403 for a write-permission role and TENANT_ADMIN; record unchanged; no event",
         ctx do
      events_before = event_count(ctx.schema)

      for type <- @six, roles <- [@operator, @admin] do
        id = ctx.records[type]
        before = stored(ctx, type, id)
        count_before = record_count(ctx.schema, type)
        label = "#{type} as #{inspect(roles)}"

        assert_managed!(
          call_entities(ctx, roles, :post, "/records/#{type}", %{
            "field_values" => values(type, 2)
          }),
          "POST #{label}"
        )

        assert_managed!(
          call_entities(ctx, roles, :put, "/records/#{type}/#{id}", %{
            "field_values" => values(type, 3)
          }),
          "PUT #{label}"
        )

        assert_managed!(
          call_entities(ctx, roles, :delete, "/records/#{type}/#{id}", nil),
          "DELETE #{label}"
        )

        assert stored(ctx, type, id) == before, label
        assert record_count(ctx.schema, type) == count_before, label
        refute before.deleted
      end

      assert event_count(ctx.schema) == events_before
    end

    test "POST /records/:type/import (TENANT_ADMIN) -> the constant 403, zero records, no event",
         ctx do
      events_before = event_count(ctx.schema)

      for type <- @six do
        count_before = record_count(ctx.schema, type)

        assert_managed!(
          call_entities(ctx, @admin, :post, "/records/#{type}/import", import_document(type, 2)),
          "import #{type}"
        )

        assert record_count(ctx.schema, type) == count_before
      end

      assert event_count(ctx.schema) == events_before
    end

    test "POST /query still returns each pre-existing record unchanged after the refused writes",
         ctx do
      for type <- @six, roles <- [@operator, @admin] do
        call_entities(ctx, roles, :post, "/records/#{type}", %{"field_values" => values(type, 2)})
        call_entities(ctx, roles, :delete, "/records/#{type}/#{ctx.records[type]}", nil)
      end

      for type <- @six do
        assert query_items(ctx.tenant_id, ctx.actor_id, ctx.schema, type) ==
                 ctx.items_before[type],
               type
      end
    end
  end

  # ── T-23 ────────────────────────────────────────────────────────────────────────────────────

  describe "T-23 (AC5 control, the ruling): the ten authoring types stay writable" do
    test "the stamp touched none of the ten authoring definition rows", ctx do
      assert Fx.dump(ctx.schema, @ten) == ctx.ten_before_stamp
      for name <- @ten, do: assert(Fx.managed_by_map(ctx.schema)[name] == [nil], name)
    end

    test "POST, PUT, DELETE and import succeed for each authoring type, for both caller kinds",
         ctx do
      for type <- @ten, roles <- [@operator, @admin] do
        label = "#{type} as #{inspect(roles)}"

        created =
          call_entities(ctx, roles, :post, "/records/#{type}", %{
            "field_values" => values(type, 5)
          })

        assert created.status == 201, "POST #{label}: #{created.resp_body}"
        new_id = body_of(created)["record_id"]

        updated =
          call_entities(ctx, roles, :put, "/records/#{type}/#{new_id}", %{
            "field_values" => values(type, 6)
          })

        assert updated.status == 200, "PUT #{label}: #{updated.resp_body}"

        deleted = call_entities(ctx, roles, :delete, "/records/#{type}/#{new_id}", nil)
        assert deleted.status == 200, "DELETE #{label}: #{deleted.resp_body}"
      end

      for type <- @ten do
        imported =
          call_entities(ctx, @admin, :post, "/records/#{type}/import", import_document(type, 1))

        assert imported.status == 200, "import #{type}: #{imported.resp_body}"
        refute imported.resp_body == managed_body()
      end
    end
  end

  # ── T-22 ────────────────────────────────────────────────────────────────────────────────────

  describe "T-22 (AC8): reads are unchanged on a stamped tenant" do
    test "query and aggregate return the pre-stamp records; definitions are readable", ctx do
      for type <- @six do
        assert query_items(ctx.tenant_id, ctx.actor_id, ctx.schema, type) ==
                 ctx.items_before[type],
               type

        aggregate =
          call_entities(ctx, @admin, :post, "/query/aggregate", %{
            "entity_type" => type,
            "aggregates" => [%{"fn" => "count"}]
          })

        assert aggregate.status == 200, aggregate.resp_body

        active = call_entities(ctx, @admin, :get, "/definitions/active/#{type}", nil)
        assert active.status == 200, active.resp_body
        assert body_of(active)["name"] == type
      end

      listed = call_entities(ctx, @admin, :get, "/definitions", nil)
      assert listed.status == 200
    end

    test "the answer-key field restriction still redacts is_correct for a TASK_WORKER caller",
         ctx do
      conn =
        call_entities(ctx, @task_worker, :post, "/query", %{"entity_type" => "answer_option"})

      assert conn.status == 200, conn.resp_body

      assert [item] = body_of(conn)["items"]
      refute item["field_values"]["is_correct"] == true
    end
  end

  # ── T-12 ────────────────────────────────────────────────────────────────────────────────────

  describe "T-12 (AC3 sub): the definitions API cannot stamp or unstamp after the exception exists" do
    test "POST /definitions: a managed name, an authoring name carrying managed_by, and a brand-new name carrying managed_by are all refused",
         ctx do
      body = fn name ->
        %{
          "name" => name,
          "display_name" => "Tenant attempt",
          "fields" => [%{"name" => "name", "type" => "string", "required" => true}]
        }
      end

      cases = [
        {"session", Map.put(body.("session"), "managed_by", "exam")},
        {"session", body.("session")},
        {"tag", Map.put(body.("tag"), "managed_by", "exam")},
        {"tag", Map.put(body.("tag"), "managed_by", nil)},
        {"brand_new_exam_type", Map.put(body.("brand_new_exam_type"), "managed_by", "exam")}
      ]

      for {name, request_body} <- cases do
        before = definition_count(ctx.schema, name)

        assert_managed!(
          call_entities(ctx, @designer, :post, "/definitions", request_body),
          "create #{name} #{inspect(Map.keys(request_body))}"
        )

        assert definition_count(ctx.schema, name) == before
      end

      # Control: a plain NEW VERSION of the unmanaged authoring name is accepted and stays unstamped.
      created = call_entities(ctx, @designer, :post, "/definitions", body.("tag"))
      assert created.status == 201, created.resp_body
      assert Fx.managed_by_map(ctx.schema)["tag"] == [nil]

      assert_stamps_intact!(ctx)
    end

    test "POST /definitions/:name/activate on a stamped name is refused; an authoring name is not stamped by activation",
         ctx do
      for name <- @six do
        assert_managed!(
          call_entities(ctx, @designer, :post, "/definitions/#{name}/activate", %{
            "rationale" => "x"
          }),
          "activate #{name}"
        )
      end

      activated =
        call_entities(ctx, @designer, :post, "/definitions/tag/activate", %{"rationale" => "x"})

      refute activated.resp_body == managed_body()
      assert Fx.managed_by_map(ctx.schema)["tag"] == [nil]
      assert_stamps_intact!(ctx)
    end
  end

  defp assert_stamps_intact!(ctx) do
    map = Fx.managed_by_map(ctx.schema)
    for name <- @six, do: assert(map[name] == ["exam"], name)
    for name <- @ten, do: assert(map[name] == [nil], name)
  end

  # ── T-13 ────────────────────────────────────────────────────────────────────────────────────

  describe "T-13 (AC3 sub): pack documents cannot stamp or unstamp" do
    test "a managed_by key at the top level, on an entity entry and inside definition_json is rejected as an invalid pack document",
         ctx do
      document = Fx.pack_document()

      top = Map.put(document, "managed_by", "exam")

      entry =
        Map.update!(document, "entity_definitions", fn [first | rest] ->
          [Map.put(first, "managed_by", "exam") | rest]
        end)

      nested =
        Map.update!(document, "entity_definitions", fn [first | rest] ->
          [put_in(first, ["definition_json", "managed_by"], "exam") | rest]
        end)

      for {label, bad} <- [top: top, entry: entry, nested: nested] do
        assert {:error, :invalid_pack_document} =
                 SolutionPack.install(bad, ctx.actor_id, prefix: ctx.schema),
               to_string(label)
      end

      assert_stamps_intact!(ctx)
    end

    test "a tenant (non-owner) install of the real exam pack over the stamped names changes nothing",
         ctx do
      before = Fx.dump(ctx.schema, @six ++ @ten)

      assert {:error, _reason} =
               SolutionPack.install(Fx.pack_document(), ctx.actor_id, prefix: ctx.schema)

      assert Fx.dump(ctx.schema, @six ++ @ten) == before
      assert_stamps_intact!(ctx)
      assert match?({:ok, _}, Definitions.get_active_definition_by_name("session", ctx.schema))
    end
  end
end
