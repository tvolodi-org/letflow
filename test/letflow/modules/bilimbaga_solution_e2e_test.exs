defmodule Letflow.Modules.BilimbagaSolutionE2ETest do
  @moduledoc """
  REQ-416 — P3 close-out: installs the bilimbaga solution into a fresh tenant
  and exercises the full exam-tenant path end-to-end (steps 1-7 in order):

    1. Provision a brand-new tenant via `TenantFixture.provisioned_tenant!`.
    2. As the tenant's TENANT_ADMIN (REQ-447 PR 2: an ordinary tenant has no PLATFORM_ADMIN),
       `POST /api/v1/tenant/solutions` → 201.
    3. Assert `GET /api/v1/me/modules` lists `exam`, entity definitions are
       present, and answer-key field restrictions from `on_install/2` exist.
    4. Seed a category, questions, and one active exam via the same
       `Letflow.Entities.Records.create_record/2` path `ExamFixtures` uses
       (no direct SQL, no `Repo.insert_all`, no `Ecto.Adapters.SQL.query`).
    5. Candidate path: list available exams, start, save, submit, read scored
       session, issue certificate — assert 201/200 at each step and
       `passed: true` for a fully correct answer set.
    6. As a TASK_WORKER token in the same tenant, `POST /entities/query` on
       `answer_option` — assert `is_correct`, `likert_weight`,
       `likert_polarity`, `explanation` are redacted.
    7. Second fresh tenant WITHOUT the solution: assert `POST
       /api/v1/modules/exam/exam-sessions` returns 404 for every role in
       `Authorization.roles/0`.

  `async: false` — tenant provisioning needs `Sandbox.mode(:auto)`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Query.FieldGrants
  alias Letflow.ExamFixtures
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Modules.Exam
  alias Letflow.Repo
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning.ColumnPromotion

  # ── Full-pipeline dispatch (mirrors exam_sessions_test.exs) ───────────────

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp request(method, path, ctx, body \\ nil) do
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

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp insert_user!(schema, suffix) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "req416-#{suffix}-#{Ecto.UUID.generate()}",
      display_name: "REQ-416 #{suffix} user",
      email: "req416-#{suffix}-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema)
  end

  defp user_ctx(schema, slug, roles, suffix) do
    user = insert_user!(schema, suffix)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: schema)

    %{schema_name: schema, slug: slug, plaintext: plaintext, user_id: user.id}
  end

  # Register the extra global-table cleanup that must run BEFORE
  # TenantFixture's own on_exit deletes the tenant row (ExUnit on_exit is
  # LIFO, so registering this AFTER TenantFixture.provisioned_tenant! means
  # it runs first).
  defp register_solution_cleanup(tenant_id) do
    on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant_id))
      Repo.delete_all(from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant_id))
      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant_id))
    end)
  end

  # Creates an exam record via the real Records API.
  defp create_exam!(schema, attrs \\ %{}) do
    defaults = %{
      "title" => %{"en" => "REQ-416 End-to-End Exam"},
      "status" => "active",
      "time_limit_minutes" => 30,
      "passing_score_pct" => 60.0,
      "max_attempts" => 3,
      "shuffle_questions" => false,
      "shuffle_options" => false,
      "show_answers" => "never",
      "on_tab_switch" => "log",
      "certificate_enabled" => true
    }

    exam = ExamFixtures.create_record!(schema, "exam", Map.merge(defaults, attrs))
    # REQ-582: the start check is enforced, so an exam under test is assigned to everyone.
    ExamFixtures.assign_all!(schema, exam.record_id)
    exam
  end

  defp create_question!(schema, category_id, attrs \\ %{}) do
    defaults = %{
      "category_id" => category_id,
      "difficulty" => "easy",
      "type" => "single",
      "default_locale" => "en",
      "status" => "active",
      "version" => 1,
      "stem" => %{"en" => "What is 2 + 2?"},
      "explanation" => %{"en" => "Two plus two equals four."}
    }

    ExamFixtures.create_record!(schema, "question", Map.merge(defaults, attrs))
  end

  defp create_option!(schema, question_id, sort_order, is_correct, attrs \\ %{}) do
    defaults = %{
      "question_id" => question_id,
      "sort_order" => sort_order,
      "is_correct" => is_correct,
      "text" => %{"en" => "Option #{sort_order}"},
      # Seed answer-key fields so the TASK_WORKER redaction assertion in step 6
      # is meaningful (a nil from a missing field would pass vacuously).
      "likert_weight" => if(is_correct, do: 4.0, else: 1.0),
      "likert_polarity" => "positive"
    }

    ExamFixtures.create_record!(schema, "answer_option", Map.merge(defaults, attrs))
  end

  defp create_rule!(schema, exam_id, category_id, count) do
    ExamFixtures.create_record!(schema, "exam_question_rule", %{
      "exam_id" => exam_id,
      "mode" => "random",
      "category_id" => category_id,
      "count" => count,
      "sort_order" => 0
    })
  end

  # ── The end-to-end test ────────────────────────────────────────────────────

  describe "REQ-416 — bilimbaga solution end-to-end" do
    test "steps 1-7: install solution, verify state, seed data, run candidate flow, check redaction, verify 404 without solution" do
      # ── Step 1: Provision a fresh tenant ─────────────────────────────────
      %{tenant_id: tenant_id, schema_name: schema_name, tenant: %Tenant{slug: slug}} =
        TenantFixture.provisioned_tenant!(
          slug_prefix: "req416-bilimbaga-e2e",
          display_name: "REQ-416 Bilimbaga E2E Test Tenant"
        )

      # Register extra cleanup AFTER TenantFixture's on_exit so our hook runs
      # FIRST (LIFO), deleting SolutionPackInstall / SolutionPackArtefactBase /
      # ColumnPromotion FK rows before the tenant row itself is deleted.
      register_solution_cleanup(tenant_id)

      {:ok, _seeded} = EventTypes.seed!(schema_name)

      # ── Step 2: POST /api/v1/tenant/solutions as TENANT_ADMIN → 201 ──────
      # REQ-447 PR 2: a PLATFORM_ADMIN token cannot be minted for (nor honoured in) an
      # ordinary tenant; the tenant administrator is TENANT_ADMIN.
      admin_ctx = user_ctx(schema_name, slug, ["TENANT_ADMIN"], "admin")

      install_conn =
        request(:post, "/api/v1/tenant/solutions", admin_ctx, %{
          "solution_id" => "bilimbaga",
          "rationale" => "test: bilimbaga e2e install"
        })

      assert install_conn.status == 201,
             "expected 201 from POST /tenant/solutions, got #{install_conn.status}: #{install_conn.resp_body}"

      body = json_body(install_conn)
      installed_ids = Enum.map(body["installed_modules"], & &1["module_id"])
      assert "exam" in installed_ids

      # ── Step 3: Verify post-install state ────────────────────────────────

      # 3a: GET /api/v1/me/modules lists "exam"
      modules_conn = request(:get, "/api/v1/me/modules", admin_ctx)
      assert modules_conn.status == 200
      installed_modules = json_body(modules_conn)["installed_modules"]

      assert Enum.any?(installed_modules, &(&1["module_id"] == "exam")),
             "expected 'exam' in /me/modules, got: #{inspect(installed_modules)}"

      # 3b: Exam pack's entity definitions are present (installed as :inactive)
      entity_types_present =
        Repo.all(from(ed in EntityDefinition, select: ed.name), prefix: schema_name)

      for expected_type <- ~w(category question answer_option exam exam_question_rule) do
        assert expected_type in entity_types_present,
               "expected entity definition '#{expected_type}' to exist after bilimbaga install"
      end

      # All installed definitions are :inactive (pack install invariant)
      statuses =
        Repo.all(from(ed in EntityDefinition, select: ed.status), prefix: schema_name)

      assert Enum.all?(statuses, &(&1 == :inactive)),
             "expected all entity definitions to be :inactive after pack install, got: #{inspect(statuses |> Enum.uniq())}"

      # 3c: Answer-key field restrictions from on_install/2 are present
      restrictions =
        Repo.all(
          from(r in "entity_field_restrictions", select: {r.entity_type, r.field_name}),
          prefix: schema_name
        )

      for {entity_type, field_name} <- Exam.answer_key_fields() do
        assert {entity_type, field_name} in restrictions,
               "expected field restriction for #{entity_type}.#{field_name} after bilimbaga install"
      end

      # ── Step 4: Activate definitions and seed exam content ───────────────
      # GH #2596: the install stamped the six runtime types managed (`managed_by = 'exam'`), so a
      # tenant `create_definition/2` of them is refused. The fixture creates + activates v2 of the
      # authoring entities and ACTIVATES the pack's own stamped runtime rows. No SQL — uses
      # Definitions.create_definition/2 and Definitions.activate_definition/4.
      ExamFixtures.activate_exam_definitions_after_pack_install!(schema_name)

      # Seed a category, one question with a correct and a wrong option,
      # and one exam with a rule drawing that question. Uses the same
      # Records.create_record/2 path ExamFixtures.create_record!/4 wraps.
      category =
        ExamFixtures.create_record!(schema_name, "category", %{
          "name" => %{"en" => "Mathematics", "kk" => "Математика", "ru" => "Математика"},
          "sort_order" => 1
        })

      question = create_question!(schema_name, category.record_id)
      correct = create_option!(schema_name, question.record_id, 0, true)
      _wrong = create_option!(schema_name, question.record_id, 1, false)
      exam = create_exam!(schema_name)
      _rule = create_rule!(schema_name, exam.record_id, category.record_id, 1)

      # ── Step 5: Candidate path ────────────────────────────────────────────
      candidate_ctx = user_ctx(schema_name, slug, ["CANDIDATE"], "candidate")

      # 5a: List available exams
      avail_conn = request(:get, "/api/v1/modules/exam/exam-sessions/available", candidate_ctx)
      assert avail_conn.status == 200

      # 5b: Start a session → 201
      start_conn =
        request(:post, "/api/v1/modules/exam/exam-sessions", candidate_ctx, %{
          "exam_id" => exam.record_id
        })

      assert start_conn.status == 201,
             "expected 201 from POST /exam-sessions, got #{start_conn.status}: #{start_conn.resp_body}"

      started = json_body(start_conn)
      session_id = started["session"]["id"]
      assert started["session"]["status"] == "in_progress"
      assert started["session"]["exam_id"] == exam.record_id
      assert is_integer(started["remaining_seconds"])

      question_id_expected = question.record_id

      assert [%{"question_id" => ^question_id_expected}] = started["questions"],
             "expected the seeded question in the started session"

      # 5c: Save a correct answer → 200
      save_conn =
        request(
          :put,
          "/api/v1/modules/exam/exam-sessions/#{session_id}/answers/#{question.record_id}",
          candidate_ctx,
          %{"selected_option_ids" => [correct.record_id], "time_spent_seconds" => 5}
        )

      assert save_conn.status == 200,
             "expected 200 from PUT .../answers/..., got #{save_conn.status}: #{save_conn.resp_body}"

      # 5d: Submit → 200, passed: true for fully correct answers
      submit_conn =
        request(
          :post,
          "/api/v1/modules/exam/exam-sessions/#{session_id}/submit",
          candidate_ctx
        )

      assert submit_conn.status == 200,
             "expected 200 from POST .../submit, got #{submit_conn.status}: #{submit_conn.resp_body}"

      submitted = json_body(submit_conn)

      assert submitted["status"] == "submitted",
             "expected status 'submitted', got #{inspect(submitted["status"])}"

      assert submitted["passed"] == true,
             "expected passed: true for a fully correct answer, got: #{inspect(submitted["passed"])}"

      # 5e: Read the scored session → 200, passed true confirmed via GET
      get_conn =
        request(:get, "/api/v1/modules/exam/exam-sessions/#{session_id}", candidate_ctx)

      assert get_conn.status == 200,
             "expected 200 from GET .../exam-sessions/:id, got #{get_conn.status}"

      session_state = json_body(get_conn)
      assert session_state["session"]["status"] == "submitted"
      assert session_state["session"]["passed"] == true

      # 5f: Issue certificate → 200 (exam has certificate_enabled: true)
      cert_conn =
        request(
          :post,
          "/api/v1/modules/exam/exam-sessions/#{session_id}/certificate",
          candidate_ctx
        )

      assert cert_conn.status == 200,
             "expected 200 from POST .../certificate, got #{cert_conn.status}: #{cert_conn.resp_body}"

      cert = json_body(cert_conn)
      assert cert["session_id"] == session_id
      assert is_binary(cert["id"])

      # ── Step 6: TASK_WORKER answer-key redaction ──────────────────────────
      # Mirrors test/letflow/routers/entities_answer_key_field_leak_test.exs
      # Part 2 (regression: fix closes the leak).
      tw_ctx = user_ctx(schema_name, slug, ["TASK_WORKER"], "tw")

      sentinel = Atom.to_string(FieldGrants.redacted_sentinel())

      # answer_option: is_correct, likert_weight, likert_polarity redacted
      ao_conn =
        request(:post, "/api/v1/entities/query", tw_ctx, %{"entity_type" => "answer_option"})

      assert ao_conn.status == 200,
             "expected 200 from POST /entities/query for answer_option, got #{ao_conn.status}"

      ao_items = json_body(ao_conn)["items"]
      # At least the one correct answer_option we seeded
      assert length(ao_items) >= 1

      for item <- ao_items do
        fv = item["field_values"]

        assert fv["is_correct"] == sentinel,
               "expected is_correct redacted to #{sentinel}, got #{inspect(fv["is_correct"])}"

        assert fv["likert_weight"] == sentinel,
               "expected likert_weight redacted to #{sentinel}, got #{inspect(fv["likert_weight"])}"

        assert fv["likert_polarity"] == sentinel,
               "expected likert_polarity redacted to #{sentinel}, got #{inspect(fv["likert_polarity"])}"

        # Unrestricted field on the same record is NOT over-redacted
        assert fv["text"] != sentinel,
               "expected 'text' to be readable, but got sentinel #{sentinel}"
      end

      # question: explanation redacted
      q_conn =
        request(:post, "/api/v1/entities/query", tw_ctx, %{"entity_type" => "question"})

      assert q_conn.status == 200

      q_items = json_body(q_conn)["items"]
      assert length(q_items) >= 1

      for item <- q_items do
        fv = item["field_values"]

        assert fv["explanation"] == sentinel,
               "expected explanation redacted to #{sentinel}, got #{inspect(fv["explanation"])}"
      end

      # ── Step 7: Second tenant WITHOUT the solution → 404 for every role ──
      %{tenant_id: tenant_id2, schema_name: schema_name2, tenant: %Tenant{slug: slug2}} =
        TenantFixture.provisioned_tenant!(
          slug_prefix: "req416-no-solution",
          display_name: "REQ-416 No-Solution Tenant"
        )

      {:ok, _} = EventTypes.seed!(schema_name2)

      # REQ-447 PR 2: PLATFORM_ADMIN is not issuable for an ordinary tenant any more
      # (`create_token/3` -> {:error, :invalid_role_set}), so it is not in this loop; the
      # tenant's own administrator, TENANT_ADMIN, is (and stays covered).
      for role <- Letflow.Api.Authorization.roles() -- [:PLATFORM_ADMIN] do
        role_str = Atom.to_string(role)
        role_user = insert_user!(schema_name2, "role-#{role_str}")

        {:ok, %{plaintext: role_plaintext}} =
          Identity.create_token(role_user.id, %{roles: [role_str], expires_at: nil},
            prefix: schema_name2
          )

        role_ctx = %{
          schema_name: schema_name2,
          slug: slug2,
          plaintext: role_plaintext
        }

        conn =
          request(:post, "/api/v1/modules/exam/exam-sessions", role_ctx, %{
            "exam_id" => Ecto.UUID.generate()
          })

        assert conn.status == 404,
               "expected 404 for role #{role_str} in tenant without bilimbaga solution, " <>
                 "got #{conn.status}"
      end

      # Suppress the unused variable warning for tenant_id2 — it's used
      # implicitly via the role loop above but the on_exit it owns is
      # registered by TenantFixture.provisioned_tenant! for schema_name2.
      _ = tenant_id2
    end
  end
end
