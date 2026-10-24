defmodule Letflow.Routers.EntitiesAnswerKeyFieldLeakTest do
  @moduledoc """
  ISS-0647 -- SECURITY-REVIEWER's finding while reviewing REQ-335: `TASK_WORKER`
  (this codebase's only non-privileged, ordinary-tenant-user role, and the
  role REQ-335 grants every exam-session permission to) already held
  `:EntitiesQuery`/`:EntitiesAggregate` BEFORE REQ-335 existed. REQ-335's own
  `GET /modules/exam/exam-sessions/:id` route hand-assembles its response to exclude
  `question.explanation` and `answer_option.is_correct`/`likert_weight`/
  `likert_polarity` -- but that redaction only ever protected THAT route. If
  the GENERIC `POST /entities/query`/`POST /entities/query/aggregate` routes
  were also reachable, with no `entity_field_restrictions` row configured for
  those same fields, a TASK_WORKER-scoped caller could read them in clear
  through a completely different, already-existing route.

  ## Part 1 (fact-finding) -- empirically confirms the leak existed

  Before ISS-0647's fix, a tenant with the real bilimbaga
  `question`/`answer_option` shape and NO field-restriction rows configured
  -- exactly `priv/modules/exam/entity_definitions/answer_option.json`'s
  own documented state before this issue ("This pack does not configure a
  field grant") -- returns `is_correct`/`likert_weight`/`likert_polarity`/
  `explanation` in clear to a TASK_WORKER-scoped caller via the generic
  query route. This is real, no mocking: a real Postgres tenant, a real API
  token carrying only `TASK_WORKER`, dispatched through the real
  `Letflow.Router`/`Letflow.Plugs.ApiPipeline` stack.

  ## Part 2 (regression) -- proves the fix closes it, without breaking
  legitimate TASK_WORKER use of `:EntitiesQuery` against other fields/types

  Calling `Letflow.Modules.Exam.on_install/2` against the SAME tenant makes
  every one of those four fields redact to
  `Letflow.Entities.Query.FieldGrants`'s sentinel for the SAME TASK_WORKER
  caller and the SAME request -- while an unrestricted field on the SAME
  record (`answer_option.text`) and an unrelated entity type/role-holder
  remain fully readable, proving the fix is scoped to exactly the four
  answer-key fields and does not silently over-redact.

  REQ-411: Part 2 now calls `Letflow.Modules.Exam.on_install/2` instead of
  the deleted `Letflow.Packs.Bilimbaga.seed_answer_key_field_restrictions!/1`.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Query.FieldGrants
  alias Letflow.Entities.Records
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.Modules.Exam
  alias Letflow.TenantFixture

  # ── Full-pipeline dispatch (mirrors test/letflow/routers/entities_test.exs) ──

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp request(method, path, ctx, body) do
    conn =
      case body do
        nil ->
          conn(method, path)

        body ->
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
      end

    conn
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> dispatch()
  end

  defp query(ctx, body), do: request(:post, "/api/v1/entities/query", ctx, body)

  defp query_aggregate(ctx, body),
    do: request(:post, "/api/v1/entities/query/aggregate", ctx, body)

  defp body_of(conn), do: Jason.decode!(conn.resp_body)

  defp wire_sentinel, do: Atom.to_string(FieldGrants.redacted_sentinel())

  # ── Fixtures ──────────────────────────────────────────────────────────

  defp insert_user!(tenant) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "iss0647-user-#{Ecto.UUID.generate()}",
      display_name: "ISS-0647 Test User",
      email: "iss0647-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  defp tenant_ctx(slug_prefix, roles) do
    tenant =
      TenantFixture.provisioned_tenant!(
        slug_prefix: slug_prefix,
        display_name: "ISS-0647 Answer-Key Leak Test Tenant"
      )

    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)
    user = insert_user!(tenant)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: tenant.schema_name)

    %{
      tenant_id: tenant.tenant_id,
      schema_name: tenant.schema_name,
      slug: tenant.tenant.slug,
      plaintext: plaintext,
      user_id: user.id
    }
  end

  defp create_active_definition!(ctx, definition) do
    {:ok, entity_definition} =
      Letflow.ManagedTypesSupport.create_definition(
        %{definition: definition, created_by: ctx.user_id},
        ctx.schema_name
      )

    {:ok, activated} =
      Definitions.activate_definition(
        entity_definition.name,
        ctx.user_id,
        "iss0647 go-live",
        ctx.schema_name
      )

    activated
  end

  # Mirrors the REAL shape of priv/packs/bilimbaga/entity_definitions/
  # question.json and answer_option.json for exactly the fields this issue
  # is about (localized_text collapsed to plain :string -- irrelevant to
  # field-grant redaction, which operates on field_values keys regardless of
  # declared type). No column promotion: entity_record_latest's JSONB
  # `field_values` is read directly (Compiler.compile_plain/5's `:latest`
  # branch), which needs no promoted table for an unfiltered query.
  defp seed_bilimbaga_shape!(ctx) do
    create_active_definition!(ctx, %{
      name: "question",
      display_name: "Question",
      fields: [
        %{name: "stem", type: :string, queried: true},
        %{name: "explanation", type: :string, queried: false}
      ]
    })

    create_active_definition!(ctx, %{
      name: "answer_option",
      display_name: "Answer Option",
      fields: [
        %{name: "question_id", type: :string, queried: true},
        %{name: "text", type: :string, queried: true},
        %{name: "is_correct", type: :boolean, queried: true},
        %{
          name: "likert_weight",
          type: :decimal,
          decimal_precision: 5,
          decimal_scale: 2,
          queried: false
        },
        %{
          name: "likert_polarity",
          type: :enum,
          enum_values: ["positive", "negative"],
          queried: false
        }
      ]
    })

    :ok
  end

  defp seed_record!(ctx, entity_type, field_values) do
    {:ok, %{record: record}} =
      Records.create_record(
        %{
          entity_type: entity_type,
          field_values: field_values,
          actor_id: ctx.user_id,
          idempotency_key: Ecto.UUID.generate()
        },
        ctx.schema_name
      )

    record
  end

  # ═══════════════════════════════════════════════════════════════════════
  # PART 1 -- fact-finding: empirically confirm the leak, unmocked.
  # ═══════════════════════════════════════════════════════════════════════

  describe "ISS-0647 fact-finding -- TASK_WORKER reachability of answer-key fields via POST /entities/query" do
    test "⛔ with NO entity_field_restrictions row configured, a TASK_WORKER-scoped caller reads is_correct, likert_weight, likert_polarity and explanation completely unredacted" do
      ctx = tenant_ctx("iss0647-leak-answer-option", ["TASK_WORKER"])
      seed_bilimbaga_shape!(ctx)

      question =
        seed_record!(ctx, "question", %{"stem" => "2 + 2 = ?", "explanation" => "Basic addition."})

      seed_record!(ctx, "answer_option", %{
        "question_id" => question.record_id,
        "text" => "4",
        "is_correct" => true,
        "likert_weight" => 3.5,
        "likert_polarity" => "positive"
      })

      # The exact route REQ-335's hand-redacted GET /modules/exam/exam-sessions/:id was
      # never meant to be the only guard for -- a TASK_WORKER caller hits it
      # directly, no exam-session machinery involved at all.
      conn = query(ctx, %{"entity_type" => "answer_option"})

      assert conn.status == 200
      assert [item] = body_of(conn)["items"]
      field_values = item["field_values"]

      # THE LEAK, empirically: real answer-key data, in clear.
      assert field_values["is_correct"] == true
      assert field_values["likert_weight"] == 3.5
      assert field_values["likert_polarity"] == "positive"
      refute field_values["is_correct"] == wire_sentinel()

      question_conn = query(ctx, %{"entity_type" => "question"})
      assert question_conn.status == 200
      assert [q_item] = body_of(question_conn)["items"]
      assert q_item["field_values"]["explanation"] == "Basic addition."
    end

    test "⛔ the same leak is reachable via POST /entities/query/aggregate (filtering by is_correct)" do
      ctx = tenant_ctx("iss0647-leak-aggregate", ["TASK_WORKER"])
      seed_bilimbaga_shape!(ctx)

      question = seed_record!(ctx, "question", %{"stem" => "2 + 2 = ?"})

      seed_record!(ctx, "answer_option", %{
        "question_id" => question.record_id,
        "text" => "4",
        "is_correct" => true
      })

      seed_record!(ctx, "answer_option", %{
        "question_id" => question.record_id,
        "text" => "5",
        "is_correct" => false
      })

      conn =
        query_aggregate(ctx, %{
          "entity_type" => "answer_option",
          "aggregates" => [%{"fn" => "count"}],
          "filters" => [%{"field" => "is_correct", "op" => "eq", "value" => true}]
        })

      # Before the fix: succeeds, and the filtered count (1, not 2) proves
      # `is_correct` was genuinely evaluated as a real, live query predicate
      # -- confirming :EntitiesAggregate is an equally live path to the same
      # answer-key field, not just the query route above.
      assert conn.status == 200
      assert [%{"values" => %{"count_none" => 1}}] = body_of(conn)["results"]
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # PART 2 -- regression: the fix closes it, without over-redacting.
  # ═══════════════════════════════════════════════════════════════════════

  describe "ISS-0647 regression -- Exam.on_install/2 closes the leak" do
    test "is_correct/likert_weight/likert_polarity/explanation redact to the FieldGrants sentinel for the SAME TASK_WORKER caller, while an unrestricted field on the SAME record stays visible" do
      ctx = tenant_ctx("iss0647-fixed-answer-option", ["TASK_WORKER"])
      seed_bilimbaga_shape!(ctx)
      :ok = Exam.on_install(ctx.schema_name, %{})

      question =
        seed_record!(ctx, "question", %{"stem" => "2 + 2 = ?", "explanation" => "Basic addition."})

      seed_record!(ctx, "answer_option", %{
        "question_id" => question.record_id,
        "text" => "4",
        "is_correct" => true,
        "likert_weight" => 3.5,
        "likert_polarity" => "positive"
      })

      conn = query(ctx, %{"entity_type" => "answer_option"})
      assert conn.status == 200
      assert [item] = body_of(conn)["items"]
      field_values = item["field_values"]

      # THE FIX -- every answer-key field now redacts.
      assert field_values["is_correct"] == wire_sentinel()
      assert field_values["likert_weight"] == wire_sentinel()
      assert field_values["likert_polarity"] == wire_sentinel()

      # NOT over-redacted -- an unrestricted field on the exact same row
      # keeps its real value. Without this assertion, a handler that
      # redacted the whole entity type would pass just as well.
      assert field_values["text"] == "4"
      assert field_values["question_id"] == question.record_id

      question_conn = query(ctx, %{"entity_type" => "question"})
      assert question_conn.status == 200
      assert [q_item] = body_of(question_conn)["items"]
      assert q_item["field_values"]["explanation"] == wire_sentinel()
      assert q_item["field_values"]["stem"] == "2 + 2 = ?"
    end

    test "the aggregate route now rejects filtering by is_correct with 403, instead of leaking it" do
      ctx = tenant_ctx("iss0647-fixed-aggregate", ["TASK_WORKER"])
      seed_bilimbaga_shape!(ctx)
      :ok = Exam.on_install(ctx.schema_name, %{})

      question = seed_record!(ctx, "question", %{"stem" => "2 + 2 = ?"})

      seed_record!(ctx, "answer_option", %{
        "question_id" => question.record_id,
        "text" => "4",
        "is_correct" => true
      })

      conn =
        query_aggregate(ctx, %{
          "entity_type" => "answer_option",
          "aggregates" => [%{"fn" => "count"}],
          "filters" => [%{"field" => "is_correct", "op" => "eq", "value" => true}]
        })

      assert conn.status == 403

      # An aggregate over an UNRESTRICTED field on the same entity type
      # still works -- proving the fix targets the named field, not the
      # whole entity type's aggregate access.
      unrestricted_conn =
        query_aggregate(ctx, %{
          "entity_type" => "answer_option",
          "aggregates" => [%{"fn" => "count"}],
          "group_by" => [%{"field" => "text"}]
        })

      assert unrestricted_conn.status == 200

      assert [%{"group" => %{"text" => "4"}, "values" => %{"count_none" => 1}}] =
               body_of(unrestricted_conn)["results"]
    end

    test "seeding is idempotent -- calling it twice against the same tenant does not raise" do
      ctx = tenant_ctx("iss0647-idempotent", ["TASK_WORKER"])
      seed_bilimbaga_shape!(ctx)

      assert :ok = Exam.on_install(ctx.schema_name, %{})
      assert :ok = Exam.on_install(ctx.schema_name, %{})
    end

    test "does not break legitimate TASK_WORKER use of :EntitiesQuery against an unrelated entity type" do
      ctx = tenant_ctx("iss0647-unrelated-entity", ["TASK_WORKER"])
      seed_bilimbaga_shape!(ctx)
      :ok = Exam.on_install(ctx.schema_name, %{})

      create_active_definition!(ctx, %{
        name: "widget",
        display_name: "Widget",
        fields: [%{name: "title", type: :string, queried: true}]
      })

      seed_record!(ctx, "widget", %{"title" => "an ordinary, unrelated record"})

      conn = query(ctx, %{"entity_type" => "widget"})
      assert conn.status == 200
      assert [item] = body_of(conn)["items"]
      assert item["field_values"]["title"] == "an ordinary, unrelated record"
    end
  end
end
