defmodule Letflow.Modules.Exam.GradingMarkTest do
  @moduledoc """
  GH #3324 / REQ-588 part B: `POST /api/v1/modules/exam/grading-queue/:session_id/:question_id/grade`,
  gated by the manifest-only `:ExamGradingWrite`. Full pipeline dispatch, as `grading_queue_test.exs`.
  Tests G-perm, G-mark, G-final, G-once, G-404, G-tenant, G-rollback of the design.

  The sessions carry a genuine, digest-valid `exam_snapshot` (production builder through
  `ExamFixtures.empty_snapshot!/1`, threshold rewritten with a recomputed digest).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Test
  import Plug.Conn

  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.Record.Latest
  alias Letflow.EventStore.Event
  alias Letflow.ExamFixtures
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User

  @base "/api/v1/modules/exam/grading-queue"
  @denied_roles ~w(CANDIDATE PROCESS_OPERATOR PROCESS_DESIGNER TASK_WORKER AGENT_RUNNER TENANT_AUDITOR)
  @extra_keys ~w(session_id status grading_status max_score user_id tenant_id)

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp request(method, path, ctx, body \\ nil) do
    conn(method, path, body && Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> put_req_header("x-trace-id", "t-3324b")
    |> dispatch()
  end

  defp grade(ctx, session_id, question_id, body),
    do: request(:post, grade_path(session_id, question_id), ctx, body)

  defp grade_path(session_id, question_id), do: "#{@base}/#{session_id}/#{question_id}/grade"

  defp json(conn), do: Jason.decode!(conn.resp_body)

  # The admission plug caps a tenant at global_cap / tracked tenants, and earlier tests in the VM leave
  # their tenants tracked: with enough of them two parallel requests of one tenant would be a 503.
  # Forget every other tenant so the race tests see the full budget.
  defp free_admission_share(keep_schema) do
    for schema <- Map.keys(:sys.get_state(Letflow.Admission).tenants), schema != keep_schema do
      Letflow.Admission.forget_tenant(schema)
    end

    :ok
  end

  defp tenant(slug_prefix) do
    %{tenant_id: tenant_id, schema_name: schema_name} =
      ExamFixtures.provisioned_tenant_with_exam_definitions(slug_prefix)

    %Tenant{slug: slug} = Repo.get(Tenant, tenant_id)
    %{tenant_id: tenant_id, schema_name: schema_name, slug: slug}
  end

  defp user_ctx(tenant, roles) do
    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "gh3324b-user-#{Ecto.UUID.generate()}",
        display_name: "Grader",
        email: "gh3324b-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: tenant.schema_name)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: tenant.schema_name)

    %{schema_name: tenant.schema_name, slug: tenant.slug, plaintext: plaintext, user_id: user.id}
  end

  defp create_exam!(schema, passing) do
    ExamFixtures.create_record!(schema, "exam", %{
      "title" => %{"en" => "Exam"},
      "status" => "active",
      "time_limit_minutes" => 30,
      "passing_score_pct" => passing,
      "max_attempts" => 3,
      "shuffle_questions" => false,
      "shuffle_options" => false,
      "show_answers" => "never",
      "on_tab_switch" => "log",
      "certificate_enabled" => false
    })
  end

  defp create_question!(schema, type) do
    ExamFixtures.create_record!(schema, "question", %{
      "category_id" => Ecto.UUID.generate(),
      "difficulty" => "easy",
      "type" => type,
      "default_locale" => "en",
      "status" => "active",
      "version" => 1,
      "stem" => %{"en" => "Stem " <> type}
    })
  end

  defp score!(schema, session_id, question_id, score, max, status) do
    ExamFixtures.create_record!(schema, "session_question_score", %{
      "session_id" => session_id,
      "question_id" => question_id,
      "score" => score,
      "max_score" => max,
      "grading_status" => status
    })
  end

  # One tenant: a live exam (threshold 61.5), a `grading_pending` session whose snapshot threshold is
  # "50", two pending short-text answers (max 2.0 each) and one graded single-choice score (1.0/1.0).
  defp seed!(tenant) do
    schema = tenant.schema_name
    candidate = user_ctx(tenant, ["CANDIDATE"])
    exam = create_exam!(schema, 61.5)
    short1 = create_question!(schema, "shorttext")
    short2 = create_question!(schema, "shorttext")
    single = create_question!(schema, "single")

    session =
      ExamFixtures.create_record!(schema, "session", %{
        "exam_id" => exam.record_id,
        "user_id" => candidate.user_id,
        "status" => "grading_pending",
        "seed" => 7,
        "started_at" => "2026-10-01T09:00:00Z",
        "expires_at" => "2026-10-01T10:00:00Z",
        "submitted_at" => "2026-10-01T09:50:00Z",
        "passed" => false,
        "exam_snapshot" => ExamFixtures.empty_snapshot!(exam.record_id)
      })

    ExamFixtures.rewrite_snapshot!(schema, session.record_id, fn snapshot ->
      put_in(snapshot, ["exam", "passing_score_pct"], "50")
    end)

    sid = session.record_id
    row1 = score!(schema, sid, short1.record_id, 0.0, 2.0, "pending_manual")
    row2 = score!(schema, sid, short2.record_id, 0.0, 2.0, "pending_manual")
    rows = score!(schema, sid, single.record_id, 1.0, 1.0, "graded")

    %{
      candidate: candidate,
      exam: exam,
      session: session,
      short1: short1,
      short2: short2,
      single: single,
      row1: row1,
      row2: row2,
      single_row: rows
    }
  end

  defp stored(schema, type, id) do
    {:ok, row} = Latest.get(id, type, schema)
    row.field_values
  end

  defp num(%Decimal{} = d), do: Decimal.to_float(d)
  defp num(n) when is_number(n), do: n * 1.0

  defp events_by(schema, user_id),
    do: Repo.aggregate(from(e in Event, where: e.actor_id == ^user_id), :count, prefix: schema)

  # ── G-perm ──────────────────────────────────────────────────────────────

  describe "G-perm" do
    test "G-perm-1: the admin is allowed, every other role gets one 403, no token is 401" do
      tenant = tenant("gh3324b-perm")
      seed = seed!(tenant)
      sid = seed.session.record_id
      path = grade_path(sid, seed.short1.record_id)

      assert Letflow.Api.Authorization.role_allows?(:PLATFORM_ADMIN, :ExamGradingWrite)

      bodies =
        for role <- @denied_roles do
          conn = request(:post, path, user_ctx(tenant, [role]), %{"score" => 1.0})
          assert conn.status == 403, role
          conn.resp_body
        end

      assert length(Enum.uniq(bodies)) == 1

      assert conn(:post, path, Jason.encode!(%{"score" => 1.0}))
             |> put_req_header("content-type", "application/json")
             |> put_req_header("x-tenant-slug", tenant.slug)
             |> dispatch()
             |> Map.fetch!(:status) == 401

      assert stored(tenant.schema_name, "session_question_score", seed.row1.record_id)[
               "grading_status"
             ] ==
               "pending_manual"

      assert grade(user_ctx(tenant, ["TENANT_ADMIN"]), sid, seed.short1.record_id, %{
               "score" => 1.0
             }).status ==
               200
    end

    test "G-perm-2: manifest policy and golden rows" do
      manifest = Letflow.Modules.Exam.manifest()
      assert :ExamGradingWrite in manifest.permissions
      assert Map.keys(manifest.role_grants) == [:CANDIDATE]

      assert {"POST", "/grading-queue/:session_id/:question_id/grade", :ExamGradingWrite} in manifest.route_policies

      lines =
        "priv/permission_matrix/effective.golden"
        |> File.read!()
        |> String.split(~r/\r?\n/)
        |> Enum.filter(&String.contains?(&1, "ExamGradingWrite"))

      assert length(lines) == 8

      for role <- ~w(TENANT_ADMIN PLATFORM_ADMIN),
          do: assert(Enum.any?(lines, &(&1 =~ ~r/#{role}\b.*\btrue/)))

      assert Enum.count(lines, &String.contains?(&1, "true")) == 2
    end
  end

  # ── G-mark ──────────────────────────────────────────────────────────────

  describe "G-mark" do
    test "G-mark-1: 0.75 by a TENANT_ADMIN is stored, with the caller as actor" do
      tenant = tenant("gh3324b-mark")
      seed = seed!(tenant)
      admin = user_ctx(tenant, ["TENANT_ADMIN"])
      before = events_by(tenant.schema_name, admin.user_id)

      conn = grade(admin, seed.session.record_id, seed.short1.record_id, %{"score" => 0.75})
      assert conn.status == 200
      body = json(conn)
      assert body["score"] == 0.75
      assert body["max_score"] == 2.0
      assert body["grading_status"] == "graded"
      assert body["session_status"] == "grading_pending"

      row = stored(tenant.schema_name, "session_question_score", seed.row1.record_id)
      assert num(row["score"]) == 0.75
      assert num(row["max_score"]) == 2.0
      assert row["grading_status"] == "graded"

      assert events_by(tenant.schema_name, admin.user_id) == before + 1

      {:ok, score_instance} =
        EntityTypeInstance.fetch_instance_id("session_question_score", tenant.schema_name)

      mark_events =
        Repo.aggregate(
          from(e in Event,
            where: e.actor_id == ^admin.user_id and e.instance_id == ^score_instance
          ),
          :count,
          prefix: tenant.schema_name
        )

      assert mark_events == 1
    end

    test "G-mark-2: a bad body is 422 and the row is unchanged" do
      tenant = tenant("gh3324b-bad")
      seed = seed!(tenant)
      admin = user_ctx(tenant, ["TENANT_ADMIN"])
      sid = seed.session.record_id
      qid = seed.short1.record_id

      bodies =
        [%{"score" => 2.5}, %{"score" => -0.1}, %{"score" => "0.5"}, %{"score" => true}] ++
          [%{"score" => nil}, %{}, %{"extra" => 1}] ++
          for(key <- @extra_keys, do: %{"score" => 1.0, key => "x"})

      for body <- bodies do
        conn = grade(admin, sid, qid, body)
        assert conn.status == 422, inspect(body)
      end

      row = stored(tenant.schema_name, "session_question_score", seed.row1.record_id)
      assert num(row["score"]) == 0.0
      assert row["grading_status"] == "pending_manual"
      assert stored(tenant.schema_name, "session", sid)["status"] == "grading_pending"
    end

    test "G-mark-3: a body that is not an object is 400" do
      tenant = tenant("gh3324b-arr")
      seed = seed!(tenant)
      admin = user_ctx(tenant, ["TENANT_ADMIN"])

      conn =
        conn(:post, grade_path(seed.session.record_id, seed.short1.record_id), "[1]")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer " <> admin.plaintext)
        |> put_req_header("x-tenant-slug", admin.slug)
        |> dispatch()

      assert conn.status == 400
    end
  end

  # ── G-final ─────────────────────────────────────────────────────────────

  describe "G-final" do
    test "G-final-1: the session stays pending until the last mark, then is scored" do
      tenant = tenant("gh3324b-final")
      schema = tenant.schema_name
      seed = seed!(tenant)
      admin = user_ctx(tenant, ["TENANT_ADMIN"])
      sid = seed.session.record_id

      assert grade(admin, sid, seed.short1.record_id, %{"score" => 1.5}).status == 200
      session = stored(schema, "session", sid)
      assert session["status"] == "grading_pending"
      assert session["passed"] == false
      refute Map.has_key?(session, "score_pct")

      state = request(:get, "/api/v1/modules/exam/exam-sessions/#{sid}", seed.candidate)
      assert state.status == 200
      assert %{"session" => %{"passed" => nil}} = json(state)

      conn = grade(admin, sid, seed.short2.record_id, %{"score" => 0.5})
      assert conn.status == 200
      assert json(conn)["session_status"] == "submitted"

      session = stored(schema, "session", sid)
      assert session["status"] == "submitted"
      assert num(session["score_pct"]) == (1.5 + 0.5 + 1.0) / (2.0 + 2.0 + 1.0) * 100.0
      assert session["passed"] == true
      assert session["submitted_at"] == "2026-10-01T09:50:00Z"
      assert Map.has_key?(session, "exam_snapshot")

      state = request(:get, "/api/v1/modules/exam/exam-sessions/#{sid}", seed.candidate)
      assert %{"session" => %{"passed" => true, "status" => "submitted"}} = json(state)
    end

    test "G-final-2: the frozen snapshot threshold decides, not the live exam" do
      for {live, mark, expected} <- [{10.0, 0.0, false}, {99.0, 2.0, true}] do
        tenant = tenant("gh3324b-frz")
        schema = tenant.schema_name
        seed = seed!(tenant)
        admin = user_ctx(tenant, ["TENANT_ADMIN"])
        sid = seed.session.record_id

        # Snapshot threshold is 50. Total (mark + mark + 1.0) / 5.0: 20% or 100%.
        ExamFixtures.update_record!(schema, "exam", seed.exam.record_id, %{
          "passing_score_pct" => live
        })

        assert grade(admin, sid, seed.short1.record_id, %{"score" => mark}).status == 200
        assert grade(admin, sid, seed.short2.record_id, %{"score" => mark}).status == 200
        assert stored(schema, "session", sid)["passed"] == expected
      end
    end

    test "G-rollback: a snapshot without a threshold at the last mark is a 500 and no mark" do
      tenant = tenant("gh3324b-roll")
      schema = tenant.schema_name
      seed = seed!(tenant)
      admin = user_ctx(tenant, ["TENANT_ADMIN"])
      sid = seed.session.record_id

      assert grade(admin, sid, seed.short1.record_id, %{"score" => 1.0}).status == 200

      ExamFixtures.rewrite_snapshot!(schema, sid, fn snapshot ->
        update_in(snapshot, ["exam"], &Map.delete(&1, "passing_score_pct"))
      end)

      conn = grade(admin, sid, seed.short2.record_id, %{"score" => 1.0})
      assert conn.status == 500
      refute conn.resp_body =~ "threshold"

      row = stored(schema, "session_question_score", seed.row2.record_id)
      assert row["grading_status"] == "pending_manual"
      assert stored(schema, "session", sid)["status"] == "grading_pending"
    end
  end

  # ── G-once ──────────────────────────────────────────────────────────────

  describe "G-once" do
    test "G-once-1: a second mark is 409 with a fixed body and the score is unchanged" do
      tenant = tenant("gh3324b-once")
      seed = seed!(tenant)
      admin = user_ctx(tenant, ["TENANT_ADMIN"])
      sid = seed.session.record_id
      qid = seed.short1.record_id

      assert grade(admin, sid, qid, %{"score" => 1.25}).status == 200
      conn = grade(admin, sid, qid, %{"score" => 0.5})
      assert conn.status == 409
      assert json(conn)["detail"] == "this answer has already been graded"
      refute conn.resp_body =~ "1.25"

      row = stored(tenant.schema_name, "session_question_score", seed.row1.record_id)
      assert num(row["score"]) == 1.25
    end

    test "G-once-4: a re-mark after the session is submitted is still 409" do
      tenant = tenant("gh3324b-once4")
      schema = tenant.schema_name
      seed = seed!(tenant)
      admin = user_ctx(tenant, ["TENANT_ADMIN"])
      sid = seed.session.record_id

      assert grade(admin, sid, seed.short1.record_id, %{"score" => 1.0}).status == 200
      assert grade(admin, sid, seed.short2.record_id, %{"score" => 2.0}).status == 200
      assert stored(schema, "session", sid)["status"] == "submitted"

      conn = grade(admin, sid, seed.short1.record_id, %{"score" => 0.5})
      assert conn.status == 409
      assert json(conn)["detail"] == "this answer has already been graded"
      refute conn.resp_body =~ "1.0"
      assert num(stored(schema, "session_question_score", seed.row1.record_id)["score"]) == 1.0
    end

    test "G-once-5: two concurrent marks on the last pending answer finalise once" do
      tenant = tenant("gh3324b-race3")
      schema = tenant.schema_name
      seed = seed!(tenant)
      admin = user_ctx(tenant, ["TENANT_ADMIN"])
      sid = seed.session.record_id

      assert grade(admin, sid, seed.short1.record_id, %{"score" => 1.0}).status == 200
      before = events_by(schema, admin.user_id)

      free_admission_share(schema)

      statuses =
        [0.5, 1.5]
        |> Enum.map(fn s ->
          Task.async(fn -> grade(admin, sid, seed.short2.record_id, %{"score" => s}).status end)
        end)
        |> Task.await_many(30_000)

      assert Enum.sort(statuses) == [200, 409]
      assert stored(schema, "session", sid)["status"] == "submitted"
      # one mark write and one session write
      assert events_by(schema, admin.user_id) == before + 2
    end

    test "G-once-2: two concurrent marks on one pending answer leave one mark" do
      tenant = tenant("gh3324b-race1")
      seed = seed!(tenant)
      admin = user_ctx(tenant, ["TENANT_ADMIN"])
      sid = seed.session.record_id
      qid = seed.short1.record_id

      free_admission_share(tenant.schema_name)

      statuses =
        [0.5, 1.5]
        |> Enum.map(fn s ->
          Task.async(fn -> grade(admin, sid, qid, %{"score" => s}).status end)
        end)
        |> Task.await_many(30_000)

      assert Enum.sort(statuses) == [200, 409]
      row = stored(tenant.schema_name, "session_question_score", seed.row1.record_id)
      assert row["grading_status"] == "graded"
      assert num(row["score"]) in [0.5, 1.5]
      assert stored(tenant.schema_name, "session", sid)["status"] == "grading_pending"
    end

    test "G-once-3: two concurrent marks on the last two answers finalise once" do
      tenant = tenant("gh3324b-race2")
      schema = tenant.schema_name
      seed = seed!(tenant)
      admin = user_ctx(tenant, ["TENANT_ADMIN"])
      sid = seed.session.record_id
      before = events_by(schema, admin.user_id)

      free_admission_share(schema)

      statuses =
        [{seed.short1, 1.0}, {seed.short2, 2.0}]
        |> Enum.map(fn {q, s} ->
          Task.async(fn -> grade(admin, sid, q.record_id, %{"score" => s}).status end)
        end)
        |> Task.await_many(30_000)

      assert statuses == [200, 200]
      assert num(stored(schema, "session_question_score", seed.row1.record_id)["score"]) == 1.0
      assert num(stored(schema, "session_question_score", seed.row2.record_id)["score"]) == 2.0

      session = stored(schema, "session", sid)
      assert session["status"] == "submitted"
      assert num(session["score_pct"]) == (1.0 + 2.0 + 1.0) / 5.0 * 100.0
      # two marks and one session finalisation
      assert events_by(schema, admin.user_id) == before + 3
    end
  end

  # ── G-404 ───────────────────────────────────────────────────────────────

  describe "G-404" do
    test "G-404-1: every miss on the grade route is the same 404, like the detail read" do
      tenant = tenant("gh3324b-404a")
      other = tenant("gh3324b-404b")
      seed = seed!(tenant)
      other_seed = seed!(other)
      admin = user_ctx(tenant, ["TENANT_ADMIN"])
      sid = seed.session.record_id
      body = %{"score" => 1.0}

      shape = fn conn ->
        {conn.status, conn.resp_body,
         conn.resp_headers
         |> Enum.reject(fn {k, _} -> k in ["x-request-id", "date"] end)
         |> Enum.sort()}
      end

      shapes =
        for {s, q} <- [
              {Ecto.UUID.generate(), seed.short1.record_id},
              {other_seed.session.record_id, other_seed.short1.record_id},
              {sid, seed.single.record_id},
              {sid, Ecto.UUID.generate()},
              {"not-a-uuid", seed.short1.record_id},
              {sid, "not-a-uuid"}
            ] do
          conn = grade(admin, s, q, body)
          assert conn.status == 404, "#{s} #{q}"
          shape.(conn)
        end

      assert length(Enum.uniq(shapes)) == 1

      detail = request(:get, "#{@base}/#{Ecto.UUID.generate()}/#{seed.short1.record_id}", admin)
      assert shape.(detail) == hd(shapes)
    end

    test "G-404-2: an own-tenant graded answer is 409 on grade and 404 on the detail read" do
      tenant = tenant("gh3324b-404c")
      seed = seed!(tenant)
      admin = user_ctx(tenant, ["TENANT_ADMIN"])
      sid = seed.session.record_id
      qid = seed.short1.record_id

      assert grade(admin, sid, qid, %{"score" => 1.0}).status == 200
      assert grade(admin, sid, qid, %{"score" => 1.0}).status == 409
      assert request(:get, "#{@base}/#{sid}/#{qid}", admin).status == 404
    end
  end

  # ── G-tenant ────────────────────────────────────────────────────────────

  describe "G-tenant" do
    test "G-tenant-1: tenant A's admin cannot mark tenant B's answer" do
      a = tenant("gh3324b-tenA")
      b = tenant("gh3324b-tenB")
      seed!(a)
      seed_b = seed!(b)
      admin_a = user_ctx(a, ["TENANT_ADMIN"])

      conn = grade(admin_a, seed_b.session.record_id, seed_b.short1.record_id, %{"score" => 1.0})
      assert conn.status == 404

      row = stored(b.schema_name, "session_question_score", seed_b.row1.record_id)
      assert row["grading_status"] == "pending_manual"
      assert num(row["score"]) == 0.0

      assert stored(b.schema_name, "session", seed_b.session.record_id)["status"] ==
               "grading_pending"

      routes =
        Letflow.Modules.Exam.Router.__authz_routes__()
        |> Enum.filter(fn {_m, path, _k} -> String.contains?(path, "grading-queue") end)

      assert length(routes) == 3
      for {_m, path, _k} <- routes, do: refute(path =~ ~r/tenant/i)
    end

    test "G-tenant-2: the admin's queue lists only its own tenant's rows after a mark" do
      a = tenant("gh3324b-tenC")
      b = tenant("gh3324b-tenD")
      seed_a = seed!(a)
      seed_b = seed!(b)
      admin_a = user_ctx(a, ["TENANT_ADMIN"])

      assert grade(admin_a, seed_a.session.record_id, seed_a.short1.record_id, %{"score" => 1.0}).status ==
               200

      %{"items" => items} = json(request(:get, @base, admin_a))
      ids = Enum.map(items, & &1["session_id"])
      assert ids == [seed_a.session.record_id]
      refute seed_b.session.record_id in ids
    end
  end
end
