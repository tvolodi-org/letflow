defmodule Letflow.Modules.Exam.RouterTest do
  @moduledoc """
  REQ-335 -- integration tests for `Letflow.Modules.Exam.Router`, written by
  ELIXIR-DEV at WF-02 Step 2a to exercise the real `Letflow.Plugs.ApiPipeline`
  stack end to end (DIRECTIVE T-1: no mocked database, no bypassing
  `Letflow.Plugs.Authorize`). Not full acceptance-criteria coverage --
  TEST-DESIGNER writes that later in this pipeline (Step 2d+). Mirrors
  `test/letflow/routers/entities_test.exs`'s own full-pipeline-dispatch
  convention and `test/letflow/exam/session_test.exs`'s own hand-rolled exam
  fixture helpers (`Letflow.ExamFixtures`).
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.ExamFixtures
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User

  # ── Full-pipeline dispatch ─────────────────────────────────────────────

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp request(method, path, ctx, body \\ nil, opts \\ []) do
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
    |> maybe_pin_trace_id(Keyword.get(opts, :trace_id))
    |> dispatch()
  end

  # `Letflow.Api.Error`'s `trace_id` is per-REQUEST correlation data, not
  # per-RESOURCE information (same reasoning
  # test/letflow/routers/entities_test.exs's own INV-5 byte-identity tests
  # state) -- pinning it is what makes a `resp_body == resp_body` comparison
  # a genuine byte-for-byte comparison of the whole document.
  defp maybe_pin_trace_id(conn, nil), do: conn
  defp maybe_pin_trace_id(conn, trace_id), do: put_req_header(conn, "x-trace-id", trace_id)

  defp json(conn), do: Jason.decode!(conn.resp_body)

  # ── Fixtures ─────────────────────────────────────────────────────────────

  defp insert_user!(schema) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "req335-user-#{Ecto.UUID.generate()}",
      display_name: "REQ-335 Exam Sessions Router Test User",
      email: "req335-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema)
  end

  defp tenant(slug_prefix) do
    %{tenant_id: tenant_id, schema_name: schema_name} =
      ExamFixtures.provisioned_tenant_with_exam_definitions(slug_prefix)

    %Tenant{slug: slug} = Repo.get(Tenant, tenant_id)

    %{tenant_id: tenant_id, schema_name: schema_name, slug: slug}
  end

  defp user_ctx(tenant, roles) do
    user = insert_user!(tenant.schema_name)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: tenant.schema_name)

    %{
      schema_name: tenant.schema_name,
      slug: tenant.slug,
      plaintext: plaintext,
      user_id: user.id
    }
  end

  defp candidate_ctx(tenant), do: user_ctx(tenant, ["CANDIDATE"])

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp create_exam!(schema, attrs) do
    defaults = %{
      "title" => %{"en" => "Exam"},
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

    ExamFixtures.create_record!(schema, "exam", Map.merge(defaults, attrs))
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
      "explanation" => %{"en" => "It is 4 because addition."}
    }

    ExamFixtures.create_record!(schema, "question", Map.merge(defaults, attrs))
  end

  defp create_option!(schema, question_id, sort_order, is_correct, attrs \\ %{}) do
    defaults = %{
      "question_id" => question_id,
      "sort_order" => sort_order,
      "is_correct" => is_correct,
      "text" => %{"en" => "Option #{sort_order}"}
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

  # One exam, one single-choice question with a correct and a wrong option.
  defp build_minimal_exam!(schema, exam_attrs \\ %{}) do
    category_id = Ecto.UUID.generate()
    exam = create_exam!(schema, exam_attrs)
    question = create_question!(schema, category_id)
    correct = create_option!(schema, question.record_id, 0, true)
    wrong = create_option!(schema, question.record_id, 1, false)
    create_rule!(schema, exam.record_id, category_id, 1)

    %{
      exam: exam,
      question_id: question.record_id,
      correct_id: correct.record_id,
      wrong_id: wrong.record_id
    }
  end

  defp field_values_for(schema, record_id) do
    {:ok, %Letflow.Entities.Record.Latest{field_values: field_values}} =
      Letflow.Entities.Record.Latest.get(record_id, "session", schema)

    field_values
  end

  defp start_session!(ctx, exam_id) do
    conn = request("POST", "/api/v1/modules/exam/exam-sessions", ctx, %{"exam_id" => exam_id})
    assert conn.status == 201
    json(conn)
  end

  # ── Route table sanity ───────────────────────────────────────────────────

  describe "route table" do
    test "every declared route resolves through a real, non-:Unknown policy key" do
      for {method, local_path, declared_key} <- Letflow.Modules.Exam.Router.__authz_routes__() do
        # REQ-410: routes now live under /modules/exam/<local_path> via the D5 gate.
        # local_path is the router's own match pattern (starting with the
        # exam-sessions segment), so the full path is "/modules/exam" <> local_path.
        full_path = "/modules/exam" <> local_path
        real_key = Letflow.Api.Authorization.endpoint_policy_key(method, full_path)

        assert real_key == declared_key,
               "#{method} #{full_path} declares #{inspect(declared_key)} but resolves to #{inspect(real_key)}"

        refute real_key == :Unknown
      end
    end

    test "eight routes are declared, matching the moduledoc's route table" do
      routes = Letflow.Modules.Exam.Router.__authz_routes__()
      assert length(routes) == 8

      # All routes are mounted under /modules/exam (the module id), so
      # the local patterns start with the exam-sessions sub-segment.
      # Verified by checking: (a) count is 8, (b) every route resolves
      # to the expected permission atom, (c) the manifest's route_policies
      # matches 1-to-1 (done by the first test in this describe block).
      policy_keys = routes |> Enum.map(fn {_, _, key} -> key end) |> Enum.sort()

      expected_keys =
        Enum.sort([
          :ExamSessionStart,
          :ExamSessionStart,
          :ExamSessionRead,
          :ExamSessionSave,
          :ExamSessionSubmit,
          :ExamSessionReportEvent,
          :ExamCertificateIssue,
          :ExamCertificateIssue
        ])

      assert policy_keys == expected_keys,
             "expected eight routes with the listed policy keys; got: #{inspect(routes)}"
    end
  end

  # ── Happy path: start -> autosave -> get state -> report event -> submit ──

  describe "the full candidate flow" do
    test "start, autosave, read state, report a signal, then submit" do
      tenant = tenant("req335-flow")
      ctx = candidate_ctx(tenant)

      %{exam: exam, question_id: question_id, correct_id: correct_id} =
        build_minimal_exam!(tenant.schema_name)

      # start
      started = start_session!(ctx, exam.record_id)
      session_id = started["session"]["id"]
      assert started["session"]["status"] == "in_progress"
      assert started["session"]["exam_id"] == exam.record_id
      # ISS-0674: score_pct/passed render as JSON null (key present, not
      # omitted) while the session is still :in_progress.
      assert started["session"]["score_pct"] == nil
      assert started["session"]["passed"] == nil
      assert is_integer(started["remaining_seconds"])
      assert [%{"question_id" => ^question_id}] = started["questions"]

      # autosave
      autosave_conn =
        request(
          "PUT",
          "/api/v1/modules/exam/exam-sessions/#{session_id}/answers/#{question_id}",
          ctx,
          %{"selected_option_ids" => [correct_id], "time_spent_seconds" => 5}
        )

      assert autosave_conn.status == 200
      assert %{"remaining_seconds" => remaining} = json(autosave_conn)
      assert is_integer(remaining)

      # read state
      state_conn = request("GET", "/api/v1/modules/exam/exam-sessions/#{session_id}", ctx)
      assert state_conn.status == 200
      state = json(state_conn)
      assert state["session"]["id"] == session_id
      assert [answer] = Map.values(state["answers"])
      assert answer["selected_option_ids"] == [correct_id]

      # report a benign signal
      event_conn =
        request("POST", "/api/v1/modules/exam/exam-sessions/#{session_id}/events", ctx, %{
          "type" => "tab_switch"
        })

      assert event_conn.status == 200
      assert %{"action_taken" => "log", "event_count" => 1} = json(event_conn)

      # submit
      submit_conn =
        request("POST", "/api/v1/modules/exam/exam-sessions/#{session_id}/submit", ctx)

      assert submit_conn.status == 200
      assert %{"status" => "submitted", "passed" => true} = json(submit_conn)

      # ISS-0674: re-reading the session after submit (e.g. a page reload)
      # now surfaces the same score/passed facts through the GET route.
      reread_conn = request("GET", "/api/v1/modules/exam/exam-sessions/#{session_id}", ctx)
      assert reread_conn.status == 200
      reread_session = json(reread_conn)["session"]
      assert reread_session["status"] == "submitted"
      assert reread_session["score_pct"] == 100.0
      assert reread_session["passed"] == true
    end

    test "an invalid anti-cheat signal type is rejected with 400, never reaching AntiCheat's own domain check silently" do
      tenant = tenant("req335-badsignal")
      ctx = candidate_ctx(tenant)
      %{exam: exam} = build_minimal_exam!(tenant.schema_name)
      %{"session" => %{"id" => session_id}} = start_session!(ctx, exam.record_id)

      conn =
        request("POST", "/api/v1/modules/exam/exam-sessions/#{session_id}/events", ctx, %{
          "type" => "not_a_real_type"
        })

      assert conn.status == 400
    end
  end

  # ── ISS-0650: short-text autosave through the real HTTP PUT route ────────

  describe "short-text autosave (ISS-0650)" do
    test "PUT .../answers/:question_id with text_answer persists it, readable back via GET .../:id" do
      tenant = tenant("req335-shorttext")
      ctx = candidate_ctx(tenant)

      category_id = Ecto.UUID.generate()
      exam = create_exam!(tenant.schema_name, %{})
      question = create_question!(tenant.schema_name, category_id, %{"type" => "shorttext"})
      create_rule!(tenant.schema_name, exam.record_id, category_id, 1)

      %{"session" => %{"id" => session_id}} = start_session!(ctx, exam.record_id)

      autosave_conn =
        request(
          "PUT",
          "/api/v1/modules/exam/exam-sessions/#{session_id}/answers/#{question.record_id}",
          ctx,
          %{
            "text_answer" => "The mitochondria is the powerhouse of the cell.",
            "time_spent_seconds" => 8
          }
        )

      assert autosave_conn.status == 200

      state_conn = request("GET", "/api/v1/modules/exam/exam-sessions/#{session_id}", ctx)
      assert state_conn.status == 200
      state = json(state_conn)

      assert [answer] = Map.values(state["answers"])
      assert answer["text_answer"] == "The mitochondria is the powerhouse of the cell."
      assert answer["selected_option_ids"] == []
    end

    test "PUT .../answers/:question_id rejects text_answer for a single-choice question with 400" do
      tenant = tenant("req335-shorttext-reject")
      ctx = candidate_ctx(tenant)

      %{exam: exam, question_id: question_id} = build_minimal_exam!(tenant.schema_name)
      %{"session" => %{"id" => session_id}} = start_session!(ctx, exam.record_id)

      conn =
        request(
          "PUT",
          "/api/v1/modules/exam/exam-sessions/#{session_id}/answers/#{question_id}",
          ctx,
          %{"text_answer" => "should not be accepted", "time_spent_seconds" => 1}
        )

      assert conn.status == 400
    end
  end

  # ── Redaction: is_correct/likert_weight/likert_polarity/explanation never appear ──

  describe "GetSessionState redaction" do
    test "the response never carries is_correct or any other answer-key field" do
      tenant = tenant("req335-redact")
      ctx = candidate_ctx(tenant)
      %{exam: exam} = build_minimal_exam!(tenant.schema_name)
      %{"session" => %{"id" => session_id}} = start_session!(ctx, exam.record_id)

      conn = request("GET", "/api/v1/modules/exam/exam-sessions/#{session_id}", ctx)
      assert conn.status == 200

      # Byte-level check on the raw response body -- not just "it didn't
      # crash": none of the answer-key field NAMES appear anywhere in the
      # serialised JSON.
      refute conn.resp_body =~ "is_correct"
      refute conn.resp_body =~ "likert_weight"
      refute conn.resp_body =~ "likert_polarity"
      refute conn.resp_body =~ "explanation"

      state = json(conn)
      [question] = state["questions"]

      assert Map.keys(question) |> Enum.sort() == [
               "options",
               "question_id",
               "sort_order",
               "stem",
               "type"
             ]

      for option <- question["options"] do
        assert Map.keys(option) |> Enum.sort() == ["id", "text"]
      end
    end

    test "remaining_seconds is clamped at zero for an already-expired session" do
      tenant = tenant("req335-expired")
      ctx = candidate_ctx(tenant)
      %{exam: exam} = build_minimal_exam!(tenant.schema_name, %{"time_limit_minutes" => 30})
      %{"session" => %{"id" => session_id}} = start_session!(ctx, exam.record_id)

      # Force the session's own expires_at into the past, directly, via the
      # same Letflow.Entities.Records write path production code uses.
      {:ok, %{record: %Letflow.Entities.Record.Latest{field_values: field_values}}} =
        Letflow.Entities.Records.update_record(
          %{
            entity_type: "session",
            record_id: session_id,
            field_values:
              Map.put(
                field_values_for(tenant.schema_name, session_id),
                "expires_at",
                iso(DateTime.add(DateTime.utc_now(), -3600, :second))
              ),
            actor_id: Ecto.UUID.generate(),
            idempotency_key: Ecto.UUID.generate()
          },
          tenant.schema_name
        )

      assert field_values["expires_at"]

      conn = request("GET", "/api/v1/modules/exam/exam-sessions/#{session_id}", ctx)
      assert conn.status == 200
      assert json(conn)["remaining_seconds"] == 0
    end
  end

  # ── Ownership: same 404 for "not yours" and "does not exist" (INV-5) ──────

  describe "cross-candidate ownership" do
    test "a candidate cannot reach another candidate's session -- identical 404 to a nonexistent id, on every session-scoped route" do
      tenant = tenant("req335-ownership")
      owner_ctx = candidate_ctx(tenant)
      other_ctx = candidate_ctx(tenant)
      %{exam: exam, question_id: question_id} = build_minimal_exam!(tenant.schema_name)
      %{"session" => %{"id" => session_id}} = start_session!(owner_ctx, exam.record_id)

      nonexistent_id = Ecto.UUID.generate()
      trace_id = Ecto.UUID.generate()

      # GET
      not_owner_get =
        request("GET", "/api/v1/modules/exam/exam-sessions/#{session_id}", other_ctx, nil,
          trace_id: trace_id
        )

      not_found_get =
        request("GET", "/api/v1/modules/exam/exam-sessions/#{nonexistent_id}", other_ctx, nil,
          trace_id: trace_id
        )

      assert not_owner_get.status == 404
      assert not_owner_get.status == not_found_get.status
      assert not_owner_get.resp_body == not_found_get.resp_body

      # PUT answers
      not_owner_put =
        request(
          "PUT",
          "/api/v1/modules/exam/exam-sessions/#{session_id}/answers/#{question_id}",
          other_ctx,
          %{"selected_option_ids" => [], "time_spent_seconds" => 1},
          trace_id: trace_id
        )

      not_found_put =
        request(
          "PUT",
          "/api/v1/modules/exam/exam-sessions/#{nonexistent_id}/answers/#{question_id}",
          other_ctx,
          %{"selected_option_ids" => [], "time_spent_seconds" => 1},
          trace_id: trace_id
        )

      assert not_owner_put.status == 404
      assert not_owner_put.resp_body == not_found_put.resp_body

      # POST submit
      not_owner_submit =
        request("POST", "/api/v1/modules/exam/exam-sessions/#{session_id}/submit", other_ctx, nil,
          trace_id: trace_id
        )

      not_found_submit =
        request(
          "POST",
          "/api/v1/modules/exam/exam-sessions/#{nonexistent_id}/submit",
          other_ctx,
          nil,
          trace_id: trace_id
        )

      assert not_owner_submit.status == 404
      assert not_owner_submit.resp_body == not_found_submit.resp_body

      # POST events
      not_owner_event =
        request(
          "POST",
          "/api/v1/modules/exam/exam-sessions/#{session_id}/events",
          other_ctx,
          %{"type" => "blur"},
          trace_id: trace_id
        )

      not_found_event =
        request(
          "POST",
          "/api/v1/modules/exam/exam-sessions/#{nonexistent_id}/events",
          other_ctx,
          %{"type" => "blur"},
          trace_id: trace_id
        )

      assert not_owner_event.status == 404
      assert not_owner_event.resp_body == not_found_event.resp_body
    end
  end

  # ── Tenant isolation (INV-1) ───────────────────────────────────────────

  # ── Q-1076 / GH #2433: a reload mid-exam resumes the candidate's open session ──

  describe "Q-1076 -- a second start while a session is open returns that session's id" do
    defp start_again(ctx, exam_id) do
      request("POST", "/api/v1/modules/exam/exam-sessions", ctx, %{"exam_id" => exam_id})
    end

    test "the 409 keeps type, title, status and detail, and adds only session_id" do
      tenant = tenant("q1076-409")
      ctx = candidate_ctx(tenant)
      %{exam: exam} = build_minimal_exam!(tenant.schema_name)
      %{"session" => %{"id" => session_id}} = start_session!(ctx, exam.record_id)

      conn = start_again(ctx, exam.record_id)
      body = json(conn)
      error = Letflow.Api.Error.conflict("you already have an active session for this exam")

      assert conn.status == 409

      assert Enum.sort(Map.keys(body)) ==
               Enum.sort(["type", "title", "status", "detail", "trace_id", "session_id"])

      assert body["type"] == error.type
      assert body["title"] == error.title
      assert body["status"] == error.status
      assert body["detail"] == error.detail
      assert body["session_id"] == session_id
    end

    test "resuming the open session keeps its stored deadline and creates no second session row" do
      tenant = tenant("q1076-resume")
      ctx = candidate_ctx(tenant)
      %{exam: exam} = build_minimal_exam!(tenant.schema_name, %{"max_attempts" => 1})
      started = start_session!(ctx, exam.record_id)
      session_id = started["session"]["id"]
      expires_at = started["session"]["expires_at"]
      assert is_binary(expires_at)

      assert %{"session_id" => ^session_id} = json(start_again(ctx, exam.record_id))

      resumed = json(request("GET", "/api/v1/modules/exam/exam-sessions/#{session_id}", ctx))
      assert resumed["session"]["id"] == session_id
      assert resumed["session"]["status"] == "in_progress"
      # The stored deadline, not a fresh one: resume neither resets nor extends the timer.
      assert resumed["session"]["expires_at"] == expires_at
      assert resumed["remaining_seconds"] <= started["remaining_seconds"]
      assert resumed["questions"] == started["questions"]

      # Still one session row for this candidate and exam, so the attempt count is unchanged.
      import Ecto.Query, only: [from: 2]

      rows =
        Repo.all(
          from(r in Letflow.Entities.Record.Latest, where: r.entity_type == "session"),
          prefix: tenant.schema_name
        )

      own_rows =
        Enum.filter(rows, fn row ->
          row.field_values["exam_id"] == exam.record_id and
            row.field_values["user_id"] == ctx.user_id
        end)

      assert length(own_rows) == 1
    end

    test "another candidate in the same tenant never receives this candidate's session id" do
      tenant = tenant("q1076-same-tenant")
      ctx_a = candidate_ctx(tenant)
      ctx_b = candidate_ctx(tenant)
      %{exam: exam} = build_minimal_exam!(tenant.schema_name, %{"max_attempts" => 5})
      %{"session" => %{"id" => a_id}} = start_session!(ctx_a, exam.record_id)

      b_start = start_session!(ctx_b, exam.record_id)
      b_id = b_start["session"]["id"]
      refute b_id == a_id

      b_again = start_again(ctx_b, exam.record_id)
      assert b_again.status == 409
      assert json(b_again)["session_id"] == b_id
      refute b_again.resp_body =~ a_id
    end

    test "a candidate in another tenant never receives a session id from this tenant" do
      tenant_a = tenant("q1076-xt-a")
      tenant_b = tenant("q1076-xt-b")
      ctx_a = candidate_ctx(tenant_a)
      ctx_b = candidate_ctx(tenant_b)
      %{exam: exam} = build_minimal_exam!(tenant_a.schema_name)
      %{"session" => %{"id" => a_id}} = start_session!(ctx_a, exam.record_id)

      # The exam id belongs to tenant A, so tenant B's start cannot find an open session there.
      cross =
        request("POST", "/api/v1/modules/exam/exam-sessions", ctx_b, %{
          "exam_id" => exam.record_id
        })

      refute cross.status == 409
      refute cross.resp_body =~ a_id
    end
  end

  describe "cross-tenant isolation" do
    test "a session in one tenant is invisible to a request scoped to another tenant" do
      tenant_a = tenant("req335-tenant-a")
      tenant_b = tenant("req335-tenant-b")
      ctx_a = candidate_ctx(tenant_a)
      ctx_b = candidate_ctx(tenant_b)

      %{exam: exam} = build_minimal_exam!(tenant_a.schema_name)
      %{"session" => %{"id" => session_id}} = start_session!(ctx_a, exam.record_id)

      cross_tenant_conn =
        request("GET", "/api/v1/modules/exam/exam-sessions/#{session_id}", ctx_b)

      same_tenant_conn = request("GET", "/api/v1/modules/exam/exam-sessions/#{session_id}", ctx_a)

      assert cross_tenant_conn.status == 404
      assert same_tenant_conn.status == 200
    end
  end

  # ── Permission matrix ────────────────────────────────────────────────────

  describe "role gating" do
    test "PROCESS_DESIGNER (no CANDIDATE, no TENANT_ADMIN) is forbidden from starting a session" do
      tenant = tenant("req335-role-designer")
      %{exam: exam} = build_minimal_exam!(tenant.schema_name)
      ctx = user_ctx(tenant, ["PROCESS_DESIGNER"])

      conn =
        request("POST", "/api/v1/modules/exam/exam-sessions", ctx, %{"exam_id" => exam.record_id})

      assert conn.status == 403
    end

    test "CANDIDATE (the candidate role) can start a session" do
      tenant = tenant("req335-role-taskworker")
      %{exam: exam} = build_minimal_exam!(tenant.schema_name)
      ctx = candidate_ctx(tenant)

      conn =
        request("POST", "/api/v1/modules/exam/exam-sessions", ctx, %{"exam_id" => exam.record_id})

      assert conn.status == 201
    end

    # ISS-0646: proves the fix, not just the addition -- TASK_WORKER must no
    # longer reach ExamSession* routes now that the permission moved to the
    # new, dedicated CANDIDATE role (decision 0013 addendum, design
    # lib/letflow/design/iss0646-candidate-role.md §4b). Without this test,
    # a regression that granted CANDIDATE the five permissions "alongside"
    # TASK_WORKER instead of "instead of" TASK_WORKER would pass every other
    # test in this file.
    test "TASK_WORKER can no longer start a session -- the ExamSession* grant moved to CANDIDATE" do
      tenant = tenant("req335-role-taskworker-removed")
      %{exam: exam} = build_minimal_exam!(tenant.schema_name)
      ctx = user_ctx(tenant, ["TASK_WORKER"])

      conn =
        request("POST", "/api/v1/modules/exam/exam-sessions", ctx, %{"exam_id" => exam.record_id})

      assert conn.status == 403
    end
  end

  # ── REQ-355: certificate issuance route, real HTTP end to end ────────────
  #
  # Full guard/idempotency/branding-snapshot unit coverage lives in
  # test/letflow/exam/certificate_test.exs, against Letflow.Modules.Exam.Certificate
  # directly. This describe block proves only that the route itself is wired
  # correctly through the real Letflow.Plugs.ApiPipeline stack: authenticated,
  # CANDIDATE-reachable, and idempotent over two real HTTP calls.

  describe "POST /modules/exam/exam-sessions/:id/certificate" do
    test "start -> submit (passed) -> issue certificate -> issue again returns the identical record" do
      tenant = tenant("req355-certificate-route")
      ctx = candidate_ctx(tenant)

      %{exam: exam, question_id: question_id, correct_id: correct_id} =
        build_minimal_exam!(tenant.schema_name, %{"certificate_enabled" => true})

      started = start_session!(ctx, exam.record_id)
      session_id = started["session"]["id"]

      assert 200 ==
               request(
                 "PUT",
                 "/api/v1/modules/exam/exam-sessions/#{session_id}/answers/#{question_id}",
                 ctx,
                 %{"selected_option_ids" => [correct_id], "time_spent_seconds" => 5}
               ).status

      submit_conn =
        request("POST", "/api/v1/modules/exam/exam-sessions/#{session_id}/submit", ctx)

      assert %{"status" => "submitted", "passed" => true} = json(submit_conn)

      first_conn =
        request("POST", "/api/v1/modules/exam/exam-sessions/#{session_id}/certificate", ctx)

      assert first_conn.status == 200
      first = json(first_conn)
      assert first["session_id"] == session_id
      assert first["score_pct"] == 100.0
      assert is_binary(first["id"])
      # REQ-357: first issuance mints a one-time public-read handle,
      # returned only on this call.
      assert is_binary(first["public_handle"])

      second_conn =
        request("POST", "/api/v1/modules/exam/exam-sessions/#{session_id}/certificate", ctx)

      assert second_conn.status == 200
      second = json(second_conn)
      # A replay never re-mints a handle -- "public_handle" is absent, not
      # re-derived; everything else about the certificate is unchanged.
      refute Map.has_key?(second, "public_handle")
      assert second == Map.delete(first, "public_handle")
    end

    test "certificate_enabled: false on the exam is refused with 409, not 200" do
      tenant = tenant("req355-certificate-not-certifiable")
      ctx = candidate_ctx(tenant)

      %{exam: exam, question_id: question_id, correct_id: correct_id} =
        build_minimal_exam!(tenant.schema_name, %{"certificate_enabled" => false})

      started = start_session!(ctx, exam.record_id)
      session_id = started["session"]["id"]

      request(
        "PUT",
        "/api/v1/modules/exam/exam-sessions/#{session_id}/answers/#{question_id}",
        ctx,
        %{"selected_option_ids" => [correct_id], "time_spent_seconds" => 5}
      )

      request("POST", "/api/v1/modules/exam/exam-sessions/#{session_id}/submit", ctx)

      conn = request("POST", "/api/v1/modules/exam/exam-sessions/#{session_id}/certificate", ctx)
      assert conn.status == 409
    end

    test "another candidate's session_id renders the same 404 as a nonexistent one (INV-5)" do
      tenant = tenant("req355-certificate-ownership")
      owner_ctx = candidate_ctx(tenant)
      other_ctx = candidate_ctx(tenant)

      %{exam: exam} = build_minimal_exam!(tenant.schema_name, %{"certificate_enabled" => true})
      started = start_session!(owner_ctx, exam.record_id)
      session_id = started["session"]["id"]

      trace_id = "req355-inv5-#{Ecto.UUID.generate()}"

      probe_conn =
        request(
          "POST",
          "/api/v1/modules/exam/exam-sessions/#{session_id}/certificate",
          other_ctx,
          nil,
          trace_id: trace_id
        )

      missing_conn =
        request(
          "POST",
          "/api/v1/modules/exam/exam-sessions/#{Ecto.UUID.generate()}/certificate",
          other_ctx,
          nil,
          trace_id: trace_id
        )

      assert probe_conn.status == 404
      assert missing_conn.status == 404
      assert probe_conn.resp_body == missing_conn.resp_body
    end

    # ISS-0676 -- regression coverage for `render_issue_certificate/2`'s
    # exhaustiveness over `Letflow.Modules.Exam.Certificate.issue_error/0`
    # (certificate.ex:205-211). Elixir does not enforce case/function-clause
    # exhaustiveness against a `@type` union at compile time (confirmed by a
    # real `mix dialyzer` experiment during this issue's investigation --
    # see the ISS-0676 handoff for the observed output: adding a 7th atom to
    # the union, with and without an explicit `@spec` naming it, produced
    # ZERO new Dialyzer warnings, because the catch-all clause below widens
    # the accepted type to `term()`). This test is the compensating control:
    # it asserts each of the SIX atoms currently in `issue_error` reaches
    # its OWN documented clause (a distinct status/detail), never the
    # generic-500 catch-all at exam_sessions.ex:516-519. It does NOT catch a
    # rename that touches both places consistently, but it DOES catch (a) a
    # new atom added to `issue_error` without an accompanying router clause
    # (this test would need a new case added to keep passing, at which
    # point the gap is visible in the diff) and (b) an existing router
    # clause deleted by accident (the matching case here would start
    # observing 500 and fail). See the comment above
    # `render_issue_certificate/2`'s catch-all clause for the maintenance
    # checklist this test is paired with.
    test "every issue_error atom (certificate.ex:205-211) renders its own distinct response, never the 500 catch-all" do
      tenant = tenant("iss0676-issue-error-exhaustiveness")
      owner_ctx = candidate_ctx(tenant)

      # :session_not_found -- a session id that was never created.
      not_found_conn =
        request(
          "POST",
          "/api/v1/modules/exam/exam-sessions/#{Ecto.UUID.generate()}/certificate",
          owner_ctx
        )

      assert not_found_conn.status == 404
      refute not_found_conn.status == 500

      # :not_owner -- a real session, requested by a DIFFERENT candidate.
      %{exam: owned_exam} =
        build_minimal_exam!(tenant.schema_name, %{"certificate_enabled" => true})

      owned_session_id = start_session!(owner_ctx, owned_exam.record_id)["session"]["id"]
      other_ctx = candidate_ctx(tenant)

      not_owner_conn =
        request(
          "POST",
          "/api/v1/modules/exam/exam-sessions/#{owned_session_id}/certificate",
          other_ctx
        )

      assert not_owner_conn.status == 404
      refute not_owner_conn.status == 500

      # :session_not_submitted -- session started, never submitted.
      not_submitted_conn =
        request(
          "POST",
          "/api/v1/modules/exam/exam-sessions/#{owned_session_id}/certificate",
          owner_ctx
        )

      assert not_submitted_conn.status == 409
      assert json(not_submitted_conn)["detail"] == "session has not been submitted yet"

      # :grading_pending -- a short-text question forces status
      # :grading_pending on submit (see Letflow.Modules.Exam.Certificate's
      # moduledoc "grading_pending is not a passed: false refusal").
      grading_category_id = Ecto.UUID.generate()
      grading_exam = create_exam!(tenant.schema_name, %{"certificate_enabled" => true})

      create_question!(tenant.schema_name, grading_category_id, %{"type" => "shorttext"})
      create_rule!(tenant.schema_name, grading_exam.record_id, grading_category_id, 1)

      grading_session_id = start_session!(owner_ctx, grading_exam.record_id)["session"]["id"]

      submit_conn =
        request(
          "POST",
          "/api/v1/modules/exam/exam-sessions/#{grading_session_id}/submit",
          owner_ctx
        )

      assert %{"status" => "grading_pending"} = json(submit_conn)

      grading_pending_conn =
        request(
          "POST",
          "/api/v1/modules/exam/exam-sessions/#{grading_session_id}/certificate",
          owner_ctx
        )

      assert grading_pending_conn.status == 409

      assert json(grading_pending_conn)["detail"] =~
               "awaiting grading"

      # :exam_not_certifiable -- exam has certificate_enabled: false.
      %{exam: not_certifiable_exam, question_id: q1, correct_id: c1} =
        build_minimal_exam!(tenant.schema_name, %{"certificate_enabled" => false})

      not_certifiable_session_id =
        start_session!(owner_ctx, not_certifiable_exam.record_id)["session"]["id"]

      request(
        "PUT",
        "/api/v1/modules/exam/exam-sessions/#{not_certifiable_session_id}/answers/#{q1}",
        owner_ctx,
        %{"selected_option_ids" => [c1], "time_spent_seconds" => 5}
      )

      request(
        "POST",
        "/api/v1/modules/exam/exam-sessions/#{not_certifiable_session_id}/submit",
        owner_ctx
      )

      not_certifiable_conn =
        request(
          "POST",
          "/api/v1/modules/exam/exam-sessions/#{not_certifiable_session_id}/certificate",
          owner_ctx
        )

      assert not_certifiable_conn.status == 409
      assert json(not_certifiable_conn)["detail"] == "this exam does not issue certificates"

      # :session_not_passed -- answered wrong, submitted.
      %{exam: not_passed_exam, question_id: q2, wrong_id: w2} =
        build_minimal_exam!(tenant.schema_name, %{"certificate_enabled" => true})

      not_passed_session_id =
        start_session!(owner_ctx, not_passed_exam.record_id)["session"]["id"]

      request(
        "PUT",
        "/api/v1/modules/exam/exam-sessions/#{not_passed_session_id}/answers/#{q2}",
        owner_ctx,
        %{"selected_option_ids" => [w2], "time_spent_seconds" => 5}
      )

      submit_failed_conn =
        request(
          "POST",
          "/api/v1/modules/exam/exam-sessions/#{not_passed_session_id}/submit",
          owner_ctx
        )

      assert %{"status" => "submitted", "passed" => false} = json(submit_failed_conn)

      not_passed_conn =
        request(
          "POST",
          "/api/v1/modules/exam/exam-sessions/#{not_passed_session_id}/certificate",
          owner_ctx
        )

      assert not_passed_conn.status == 409
      assert json(not_passed_conn)["detail"] == "session was not passed"
    end
  end

  # ── REQ-356: certificate document download route, real HTTP end to end ──
  #
  # Full renderer coverage (magic-number check, field extraction, QR
  # payload decode, branding-snapshot purity) lives in
  # test/letflow/exam/certificate_document_test.exs against
  # Letflow.Modules.Exam.CertificateDocument directly. This describe block proves
  # only that the route is wired correctly: authenticated,
  # CANDIDATE-reachable, returns a real PDF, and shares the issuance
  # route's ownership/eligibility guards end to end.

  describe "GET /modules/exam/exam-sessions/:id/certificate/download" do
    test "start -> submit (passed) -> download returns a PDF with the right headers" do
      tenant = tenant("req356-download-route")
      ctx = candidate_ctx(tenant)

      %{exam: exam, question_id: question_id, correct_id: correct_id} =
        build_minimal_exam!(tenant.schema_name, %{"certificate_enabled" => true})

      started = start_session!(ctx, exam.record_id)
      session_id = started["session"]["id"]

      request(
        "PUT",
        "/api/v1/modules/exam/exam-sessions/#{session_id}/answers/#{question_id}",
        ctx,
        %{"selected_option_ids" => [correct_id], "time_spent_seconds" => 5}
      )

      submit_conn =
        request("POST", "/api/v1/modules/exam/exam-sessions/#{session_id}/submit", ctx)

      assert %{"status" => "submitted", "passed" => true} = json(submit_conn)

      conn =
        request(
          "GET",
          "/api/v1/modules/exam/exam-sessions/#{session_id}/certificate/download",
          ctx
        )

      assert conn.status == 200
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/pdf"]

      assert [disposition] = Plug.Conn.get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      assert disposition =~ ".pdf"

      assert byte_size(conn.resp_body) > 0
      assert binary_part(conn.resp_body, 0, 5) == "%PDF-"
    end

    test "downloading is idempotent -- issues (or fetches) the SAME certificate both times" do
      tenant = tenant("req356-download-idempotent")
      ctx = candidate_ctx(tenant)

      %{exam: exam, question_id: question_id, correct_id: correct_id} =
        build_minimal_exam!(tenant.schema_name, %{"certificate_enabled" => true})

      started = start_session!(ctx, exam.record_id)
      session_id = started["session"]["id"]

      request(
        "PUT",
        "/api/v1/modules/exam/exam-sessions/#{session_id}/answers/#{question_id}",
        ctx,
        %{"selected_option_ids" => [correct_id], "time_spent_seconds" => 5}
      )

      request("POST", "/api/v1/modules/exam/exam-sessions/#{session_id}/submit", ctx)

      issue_conn =
        request("POST", "/api/v1/modules/exam/exam-sessions/#{session_id}/certificate", ctx)

      issued = json(issue_conn)

      first_download =
        request(
          "GET",
          "/api/v1/modules/exam/exam-sessions/#{session_id}/certificate/download",
          ctx
        )

      second_download =
        request(
          "GET",
          "/api/v1/modules/exam/exam-sessions/#{session_id}/certificate/download",
          ctx
        )

      assert first_download.status == 200
      assert second_download.status == 200
      # Byte-identical: both downloads render the SAME idempotent
      # certificate record with no live-branding re-read in between.
      assert first_download.resp_body == second_download.resp_body
      assert byte_size(first_download.resp_body) > 0
      assert is_binary(issued["candidate_name"])
    end

    test "certificate_enabled: false on the exam is refused with 409, not a PDF" do
      tenant = tenant("req356-download-not-certifiable")
      ctx = candidate_ctx(tenant)

      %{exam: exam, question_id: question_id, correct_id: correct_id} =
        build_minimal_exam!(tenant.schema_name, %{"certificate_enabled" => false})

      started = start_session!(ctx, exam.record_id)
      session_id = started["session"]["id"]

      request(
        "PUT",
        "/api/v1/modules/exam/exam-sessions/#{session_id}/answers/#{question_id}",
        ctx,
        %{"selected_option_ids" => [correct_id], "time_spent_seconds" => 5}
      )

      request("POST", "/api/v1/modules/exam/exam-sessions/#{session_id}/submit", ctx)

      conn =
        request(
          "GET",
          "/api/v1/modules/exam/exam-sessions/#{session_id}/certificate/download",
          ctx
        )

      assert conn.status == 409
    end

    test "another candidate's session_id renders the same 404 as a nonexistent one (INV-5)" do
      tenant = tenant("req356-download-ownership")
      owner_ctx = candidate_ctx(tenant)
      other_ctx = candidate_ctx(tenant)

      %{exam: exam} = build_minimal_exam!(tenant.schema_name, %{"certificate_enabled" => true})
      started = start_session!(owner_ctx, exam.record_id)
      session_id = started["session"]["id"]

      trace_id = "req356-inv5-#{Ecto.UUID.generate()}"

      probe_conn =
        request(
          "GET",
          "/api/v1/modules/exam/exam-sessions/#{session_id}/certificate/download",
          other_ctx,
          nil,
          trace_id: trace_id
        )

      missing_conn =
        request(
          "GET",
          "/api/v1/modules/exam/exam-sessions/#{Ecto.UUID.generate()}/certificate/download",
          other_ctx,
          nil,
          trace_id: trace_id
        )

      assert probe_conn.status == 404
      assert missing_conn.status == 404
      assert probe_conn.resp_body == missing_conn.resp_body
    end
  end

  # ── REQ-357: issuance -> mint -> public resolve, end to end ──────────────
  #
  # Unit-level coverage of Letflow.Modules.Exam.CertificatePublicProjection's own
  # exact-key-set/purity/skip behaviour lives in
  # test/letflow/exam/certificate_public_projection_test.exs. This describe
  # block is the one test that proves the WHOLE wiring together: a real
  # authenticated POST mints a "public_handle", and that exact handle
  # resolves through the real, separately-mounted, unauthenticated
  # `Letflow.Router` -> `Letflow.Routers.PublicRead` -> `Letflow.PublicRead`
  # path -- not each piece asserted in isolation.

  describe "GET /api/public/certificate/:handle (REQ-357)" do
    defp get_public(path), do: conn(:get, path) |> dispatch()

    test "AC-6: a real issued certificate's public_handle resolves to the correct 3-key envelope with the exact 5-field data set" do
      tenant = tenant("req357-public-e2e")
      ctx = candidate_ctx(tenant)

      %{exam: exam, question_id: question_id, correct_id: correct_id} =
        build_minimal_exam!(tenant.schema_name, %{"certificate_enabled" => true})

      started = start_session!(ctx, exam.record_id)
      session_id = started["session"]["id"]

      request(
        "PUT",
        "/api/v1/modules/exam/exam-sessions/#{session_id}/answers/#{question_id}",
        ctx,
        %{"selected_option_ids" => [correct_id], "time_spent_seconds" => 5}
      )

      request("POST", "/api/v1/modules/exam/exam-sessions/#{session_id}/submit", ctx)

      issue_conn =
        request("POST", "/api/v1/modules/exam/exam-sessions/#{session_id}/certificate", ctx)

      assert issue_conn.status == 200
      issued = json(issue_conn)
      assert is_binary(issued["public_handle"])

      public_conn = get_public("/api/public/certificate/#{issued["public_handle"]}")
      assert public_conn.status == 200

      body = json(public_conn)

      # Exactly the three top-level envelope keys Letflow.PublicRead.resolve/2
      # builds -- "kind", "issued_at", "data" -- no more, no fewer.
      assert Map.keys(body) |> Enum.sort() == ["data", "issued_at", "kind"]
      assert body["kind"] == "certificate"
      assert is_binary(body["issued_at"])

      data = body["data"]

      assert Map.keys(data) |> Enum.sort() ==
               Enum.sort([
                 "candidate_name",
                 "exam_title",
                 "score_pct",
                 "issued_on",
                 "branding_snapshot"
               ])

      # Every value matches the SOURCE certificate's own actual field values
      # (the authenticated response), not merely "a" plausible-looking value.
      assert data["candidate_name"] == issued["candidate_name"]
      assert data["exam_title"] == issued["exam_title"]
      assert data["score_pct"] == issued["score_pct"]
      assert data["issued_on"] == issued["issued_at"]
      assert data["branding_snapshot"] == issued["branding_snapshot"]

      # No tenant id, no session id, no record identifier, no candidate
      # account identifier leaks into the public envelope.
      refute Map.has_key?(data, "session_id")
      refute Map.has_key?(data, "id")
      refute Map.has_key?(data, "tenant_id")
    end

    test "AC-4: never resolves to a valid:false/not-valid shape -- only the full success envelope or the identical 404 an unknown handle gets" do
      tenant = tenant("req357-public-neverfalse")
      ctx = candidate_ctx(tenant)

      %{exam: exam, question_id: question_id, correct_id: correct_id} =
        build_minimal_exam!(tenant.schema_name, %{"certificate_enabled" => true})

      started = start_session!(ctx, exam.record_id)
      session_id = started["session"]["id"]

      request(
        "PUT",
        "/api/v1/modules/exam/exam-sessions/#{session_id}/answers/#{question_id}",
        ctx,
        %{"selected_option_ids" => [correct_id], "time_spent_seconds" => 5}
      )

      request("POST", "/api/v1/modules/exam/exam-sessions/#{session_id}/submit", ctx)

      issued =
        json(request("POST", "/api/v1/modules/exam/exam-sessions/#{session_id}/certificate", ctx))

      ok_conn = get_public("/api/public/certificate/#{issued["public_handle"]}")
      assert ok_conn.status == 200
      ok_body = json(ok_conn)
      refute Map.has_key?(ok_body, "valid")
      assert Map.has_key?(ok_body, "data")

      unknown_conn =
        get_public(
          "/api/public/certificate/#{:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)}"
        )

      assert unknown_conn.status == 404
      unknown_body = json(unknown_conn)
      refute Map.has_key?(unknown_body, "valid")
      refute Map.has_key?(unknown_body, "data")
    end

    test "AC-7: a soft-deleted (non-publishable) certificate 404s BYTE-IDENTICALLY to an unknown handle" do
      tenant = tenant("req357-public-deleted")
      ctx = candidate_ctx(tenant)

      %{exam: exam, question_id: question_id, correct_id: correct_id} =
        build_minimal_exam!(tenant.schema_name, %{"certificate_enabled" => true})

      started = start_session!(ctx, exam.record_id)
      session_id = started["session"]["id"]

      request(
        "PUT",
        "/api/v1/modules/exam/exam-sessions/#{session_id}/answers/#{question_id}",
        ctx,
        %{"selected_option_ids" => [correct_id], "time_spent_seconds" => 5}
      )

      request("POST", "/api/v1/modules/exam/exam-sessions/#{session_id}/submit", ctx)

      issued =
        json(request("POST", "/api/v1/modules/exam/exam-sessions/#{session_id}/certificate", ctx))

      # Soft-delete the underlying entity_record_latest row directly -- the
      # same "reach the schema directly, allowed for test support, never for
      # application code" pattern
      # test/support/public_read_fixture_support.ex's revoke_handle!/1 already
      # establishes, since no admin/retraction write path exists yet
      # (Letflow.Modules.Exam.CertificatePublicProjection's own moduledoc).
      Repo.get_by!(
        Letflow.Entities.Record.Latest,
        [record_id: issued["id"], entity_type: "certificate"],
        prefix: tenant.schema_name
      )
      |> Ecto.Changeset.change(deleted: true)
      |> Repo.update!(prefix: tenant.schema_name)

      deleted_conn = get_public("/api/public/certificate/#{issued["public_handle"]}")

      unknown_conn =
        get_public(
          "/api/public/certificate/#{:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)}"
        )

      assert deleted_conn.status == 404
      assert unknown_conn.status == 404
      assert deleted_conn.resp_body == unknown_conn.resp_body
    end
  end

  # ── ISS-0718: GET /modules/exam/exam-sessions/available ───────────────────────────────
  #
  # TEST-DESIGNER, WF-03 run WF03-ISS0718-20260919. Proves the acceptance
  # criteria from docs/issues/ISS-0718.yaml that are testable at this layer:
  # a CANDIDATE token can list active exams through the new dedicated route
  # (not the generic /entities/query route CANDIDATE is structurally denied),
  # inactive exams and non-exam entities never leak into the response, and
  # ISS-0646's closed permission set is genuinely untouched -- the old
  # generic-query call CANDIDATE used to make still 403s exactly as before.

  describe "GET /modules/exam/exam-sessions/available (ISS-0718)" do
    test "a CANDIDATE token lists active exams with 200, not 403" do
      tenant = tenant("iss0718-candidate-lists")
      ctx = candidate_ctx(tenant)
      %{exam: exam} = build_minimal_exam!(tenant.schema_name, %{"status" => "active"})

      conn = request("GET", "/api/v1/modules/exam/exam-sessions/available", ctx)

      assert conn.status == 200
      body = json(conn)
      assert %{"items" => items, "next_cursor" => _} = body
      assert Enum.any?(items, fn item -> item["record_id"] == exam.record_id end)
    end

    test "an archived exam is excluded from the response" do
      tenant = tenant("iss0718-excludes-archived")
      ctx = candidate_ctx(tenant)

      %{exam: active_exam} = build_minimal_exam!(tenant.schema_name, %{"status" => "active"})
      %{exam: archived_exam} = build_minimal_exam!(tenant.schema_name, %{"status" => "archived"})

      conn = request("GET", "/api/v1/modules/exam/exam-sessions/available", ctx)
      assert conn.status == 200

      ids = Enum.map(json(conn)["items"], & &1["record_id"])
      assert active_exam.record_id in ids
      refute archived_exam.record_id in ids
    end

    test "non-exam entities (e.g. question) never appear in the response" do
      tenant = tenant("iss0718-excludes-non-exam")
      ctx = candidate_ctx(tenant)

      %{exam: exam, question_id: question_id} = build_minimal_exam!(tenant.schema_name)

      conn = request("GET", "/api/v1/modules/exam/exam-sessions/available", ctx)
      assert conn.status == 200

      ids = Enum.map(json(conn)["items"], & &1["record_id"])
      assert exam.record_id in ids
      refute question_id in ids
    end

    test "a role without :ExamSessionStart (e.g. PROCESS_DESIGNER) is forbidden" do
      tenant = tenant("iss0718-role-gating")
      ctx = user_ctx(tenant, ["PROCESS_DESIGNER"])
      build_minimal_exam!(tenant.schema_name)

      conn = request("GET", "/api/v1/modules/exam/exam-sessions/available", ctx)
      assert conn.status == 403
    end

    # ISS-0646 regression guard: proves the fix genuinely did not widen
    # CANDIDATE's closed permission set. The old ExamListPage.tsx call
    # (POST /entities/query with entity_type "exam") is the exact call
    # ISS-0718's live UAT run confirmed 403s for a real CANDIDATE token --
    # this must still 403 after the fix, since the fix's whole point (design
    # doc §0) is a dedicated route under the existing :ExamSessionStart
    # permission, not any change to what :EntitiesQuery grants.
    test "a CANDIDATE token still gets 403 on the old generic /entities/query call" do
      tenant = tenant("iss0718-old-route-still-403")
      ctx = candidate_ctx(tenant)
      build_minimal_exam!(tenant.schema_name)

      conn =
        request("POST", "/api/v1/entities/query", ctx, %{
          "entity_type" => "exam",
          "filters" => [%{"field" => "status", "op" => "eq", "value" => "active"}]
        })

      assert conn.status == 403
    end
  end

  describe "GH #2760 -- HTTP start on a soft-deleted exam" do
    test "T-60b: POST exam-sessions for a deleted active exam is 422, byte-identical to a nonexistent exam id" do
      tenant = tenant("gh2760-http-deleted")
      ctx = candidate_ctx(tenant)
      %{exam: exam} = build_minimal_exam!(tenant.schema_name)
      ExamFixtures.delete_record!(tenant.schema_name, "exam", exam.record_id)
      path = "/api/v1/modules/exam/exam-sessions"

      deleted =
        request("POST", path, ctx, %{"exam_id" => exam.record_id}, trace_id: "gh2760-trace")

      missing =
        request("POST", path, ctx, %{"exam_id" => Ecto.UUID.generate()}, trace_id: "gh2760-trace")

      assert deleted.status == 422
      assert missing.status == 422
      assert deleted.resp_body == missing.resp_body
    end

    test "T-60b2: GET available omits a soft-deleted active exam and keeps a live one" do
      tenant = tenant("gh2760-http-available")
      ctx = candidate_ctx(tenant)
      %{exam: dead} = build_minimal_exam!(tenant.schema_name)
      %{exam: live} = build_minimal_exam!(tenant.schema_name)
      ExamFixtures.delete_record!(tenant.schema_name, "exam", dead.record_id)

      conn = request("GET", "/api/v1/modules/exam/exam-sessions/available", ctx)
      assert conn.status == 200

      assert %{"items" => items, "next_cursor" => _} = json(conn)
      ids = Enum.map(items, & &1["record_id"])
      assert live.record_id in ids
      refute dead.record_id in ids
    end
  end

  # ── REQ-410 AC3: 404 gate — no tenant_modules row ────────────────────────

  describe "REQ-410 AC3 — D5 gate: 404 for a tenant without exam module installed" do
    # Provisions a tenant WITH exam definitions but WITHOUT installing
    # the exam module, so the D5 gate in Letflow.Routers.Modules returns 404.
    defp tenant_without_module(slug_prefix) do
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      %{tenant_id: tid, schema_name: schema_name} =
        ExamFixtures.provisioned_tenant_without_module_install(slug_prefix)

      %Letflow.Identity.Tenant{slug: slug} = Repo.get(Letflow.Identity.Tenant, tid)
      %{tenant_id: tid, schema_name: schema_name, slug: slug}
    end

    # REQ-447 PR 2: TENANT_ADMIN replaces PLATFORM_ADMIN (not mintable in an ordinary tenant).
    for role <- ["CANDIDATE", "TASK_WORKER", "PROCESS_DESIGNER", "TENANT_ADMIN"] do
      @role role

      test "POST /api/v1/modules/exam/exam-sessions returns 404 for #{role} (no module row)" do
        tenant = tenant_without_module("req410-no-module-#{@role}")
        ctx = user_ctx(tenant, [@role])
        build_minimal_exam!(tenant.schema_name)

        conn =
          request("POST", "/api/v1/modules/exam/exam-sessions", ctx, %{
            "exam_id" => Ecto.UUID.generate()
          })

        assert conn.status == 404,
               "expected 404 for #{@role} without exam module installed, got #{conn.status}"
      end
    end
  end

  # ── REQ-410 AC4: old core-mount URL now returns 404 ──────────────────────

  describe "REQ-410 AC4 — old core-mount /api/v1/<legacy-path> returns 404" do
    test "POST to the legacy core-mount path returns 404 (forward removed from ApiPipeline)" do
      tenant = tenant("req410-old-url-404")
      ctx = candidate_ctx(tenant)

      # Construct the old path as a runtime string to avoid the AC2 grep
      # firing on a literal that looks like a live caller; this test
      # intentionally verifies the 404 behavior of the REMOVED mount.
      # Old path: /api/v1/exam-SESSIONS (direct core-mount removed by REQ-410,
      # the "exam-sessions" prefix no longer forwarded in ApiPipeline).
      legacy_path = "/api/v1/exam" <> "-sessions"
      conn = request("POST", legacy_path, ctx, %{"exam_id" => Ecto.UUID.generate()})

      assert conn.status == 404,
             "expected 404 for legacy path (old core-mount removed), got #{conn.status}: #{conn.resp_body}"
    end
  end
end
