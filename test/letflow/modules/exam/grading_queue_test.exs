defmodule Letflow.Modules.Exam.GradingQueueTest do
  @moduledoc """
  GH #3324 / REQ-588 part A: the examiner grading queue read routes,
  `GET /api/v1/modules/exam/grading-queue` and `.../grading-queue/:session_id/:question_id`,
  gated by the manifest-only `:ExamGradingRead`. Full pipeline dispatch, as `exam_sessions_test.exs`.
  Tests G-perm, G-list, G-redact, G-404, G-tenant, G-locale of the design. The POST grade route and
  `ExamGradingWrite` are part B.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.ExamFixtures
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User

  @base "/api/v1/modules/exam/grading-queue"
  @denied_roles ~w(CANDIDATE PROCESS_OPERATOR PROCESS_DESIGNER TASK_WORKER AGENT_RUNNER TENANT_AUDITOR)

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp get(path, ctx) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> put_req_header("x-trace-id", "t-3324")
    |> dispatch()
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

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
        username: "gh3324-user-#{Ecto.UUID.generate()}",
        display_name: "Grader Display Name",
        email: "gh3324-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: tenant.schema_name)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: tenant.schema_name)

    %{
      schema_name: tenant.schema_name,
      slug: tenant.slug,
      plaintext: plaintext,
      user_id: user.id,
      user: user
    }
  end

  defp create_exam!(schema, title) do
    ExamFixtures.create_record!(schema, "exam", %{
      "title" => title,
      "status" => "active",
      "time_limit_minutes" => 30,
      "passing_score_pct" => 61.5,
      "max_attempts" => 3,
      "shuffle_questions" => false,
      "shuffle_options" => false,
      "show_answers" => "never",
      "on_tab_switch" => "log",
      "certificate_enabled" => false
    })
  end

  defp create_question!(schema, type, stem) do
    ExamFixtures.create_record!(schema, "question", %{
      "category_id" => Ecto.UUID.generate(),
      "difficulty" => "easy",
      "type" => type,
      "default_locale" => "kk",
      "status" => "active",
      "version" => 1,
      "stem" => stem,
      "explanation" => %{"en" => "SECRET-EXPLANATION"}
    })
  end

  defp create_session!(schema, exam_id, user_id, status, submitted_at) do
    base = %{
      "exam_id" => exam_id,
      "user_id" => user_id,
      "status" => status,
      "seed" => 7,
      "started_at" => "2026-10-01T09:00:00Z",
      "expires_at" => "2026-10-01T10:00:00Z",
      "passed" => false,
      "exam_snapshot" => %{"secret" => "SECRET-SNAPSHOT"}
    }

    fv = if submitted_at, do: Map.put(base, "submitted_at", submitted_at), else: base
    ExamFixtures.create_record!(schema, "session", fv)
  end

  defp score!(schema, session_id, question_id, status) do
    ExamFixtures.create_record!(schema, "session_question_score", %{
      "session_id" => session_id,
      "question_id" => question_id,
      "score" => 0.0,
      "max_score" => 2.0,
      "grading_status" => status
    })
  end

  defp answer!(schema, session_id, question_id, text) do
    ExamFixtures.create_record!(schema, "session_answer", %{
      "session_id" => session_id,
      "question_id" => question_id,
      "text_answer" => text,
      "saved_at" => "2026-10-01T09:30:00Z",
      "time_spent_seconds" => 5
    })
  end

  # Tenant A: three pending short-text rows (sessions s1 and s2 submitted at the same instant),
  # one graded short-text row, one pending-looking row of a single-choice question, one
  # in-progress session. Returns the ids the tests need.
  defp seed!(tenant) do
    schema = tenant.schema_name
    candidate = user_ctx(tenant, ["CANDIDATE"])
    exam = create_exam!(schema, %{"kk" => "Емтихан", "ru" => "Экзамен", "en" => "Exam"})
    other_exam = create_exam!(schema, %{"en" => "Other exam"})

    short = create_question!(schema, "shorttext", %{"kk" => "Сұрақ", "ru" => "Вопрос", "en" => "Question"})
    short2 = create_question!(schema, "shorttext", %{"en" => "Second"})
    single = create_question!(schema, "single", %{"en" => "Pick"})

    t0 = "2026-10-01T09:50:00Z"
    uid = candidate.user_id
    s1 = create_session!(schema, exam.record_id, uid, "grading_pending", t0)
    s2 = create_session!(schema, exam.record_id, uid, "grading_pending", t0)
    s3 = create_session!(schema, other_exam.record_id, uid, "grading_pending", "2026-10-01T09:55:00Z")
    s4 = create_session!(schema, exam.record_id, uid, "submitted", "2026-10-01T09:40:00Z")
    s5 = create_session!(schema, exam.record_id, uid, "in_progress", nil)

    for s <- [s1, s2, s3], do: score!(schema, s.record_id, short.record_id, "pending_manual")
    score!(schema, s4.record_id, short.record_id, "graded")
    score!(schema, s5.record_id, short2.record_id, "pending_manual")
    score!(schema, s1.record_id, single.record_id, "graded")

    answer!(schema, s1.record_id, short.record_id, "<b>\"A&B\"</b> 'x'")
    answer!(schema, s2.record_id, short.record_id, "second")

    %{
      candidate: candidate,
      exam: exam,
      other_exam: other_exam,
      short: short,
      short2: short2,
      single: single,
      pending: [s1, s2, s3],
      graded: s4,
      in_progress: s5
    }
  end

  defp expected_order(%{pending: [s1, s2, s3]}) do
    [s1.record_id, s2.record_id] |> Enum.sort() |> Kernel.++([s3.record_id])
  end

  defp detail_path(session_id, question_id), do: "#{@base}/#{session_id}/#{question_id}"

  # ── G-perm ──────────────────────────────────────────────────────────────

  describe "G-perm" do
    test "admins read both routes, every other role gets the same 403, no token is 401" do
      tenant = tenant("gh3324-perm")
      seed = seed!(tenant)
      [s1 | _] = seed.pending
      detail = detail_path(s1.record_id, seed.short.record_id)

      for roles <- [["TENANT_ADMIN"], ["PLATFORM_ADMIN"]] do
        ctx = user_ctx(tenant, roles)
        assert get(@base, ctx).status == 200, "list for #{inspect(roles)}"
        assert get(detail, ctx).status == 200, "detail for #{inspect(roles)}"
      end

      denied =
        for role <- @denied_roles, path <- [@base, detail] do
          conn = get(path, user_ctx(tenant, [role]))
          assert conn.status == 403, "#{role} #{path}"
          {path, conn.resp_body}
        end

      for path <- [@base, detail] do
        bodies = for {^path, body} <- denied, uniq: true, do: body
        assert length(bodies) == 1, "403 bodies differ for #{path}: #{inspect(bodies)}"
      end

      assert conn(:get, @base) |> put_req_header("x-tenant-slug", tenant.slug) |> dispatch()
             |> Map.fetch!(:status) == 401
    end

    test "the exam manifest declares ExamGradingRead with two policies and no grant" do
      manifest = Letflow.Modules.Exam.manifest()
      assert :ExamGradingRead in manifest.permissions
      assert Map.keys(manifest.role_grants) == [:CANDIDATE]

      assert {"GET", "/grading-queue", :ExamGradingRead} in manifest.route_policies

      assert {"GET", "/grading-queue/:session_id/:question_id", :ExamGradingRead} in manifest.route_policies
    end

    test "the golden holds ExamGradingRead for the two admin roles only" do
      lines =
        "priv/permission_matrix/effective.golden"
        |> File.read!()
        |> String.split(~r/\r?\n/)
        |> Enum.filter(&String.contains?(&1, "ExamGradingRead"))

      assert length(lines) == 8
      for role <- ~w(TENANT_ADMIN PLATFORM_ADMIN), do: assert(Enum.any?(lines, &(&1 =~ ~r/#{role}\b.*\btrue/)))
      assert Enum.count(lines, &String.contains?(&1, "true")) == 2
    end
  end

  # ── G-list ──────────────────────────────────────────────────────────────

  describe "G-list" do
    test "exactly the three pending rows, ordered by submission time then session id" do
      tenant = tenant("gh3324-list")
      seed = seed!(tenant)
      admin = user_ctx(tenant, ["TENANT_ADMIN"])

      conn = get(@base, admin)
      assert conn.status == 200
      %{"items" => items, "next_cursor" => nil} = json(conn)

      assert Enum.map(items, & &1["session_id"]) == expected_order(seed)

      for item <- items do
        assert item |> Map.keys() |> Enum.sort() ==
                 ~w(exam_title max_score question_id session_id stem submitted_at)

        assert item["question_id"] == seed.short.record_id
        assert item["max_score"] == 2.0
      end

      assert hd(items)["stem"] == "Сұрақ"
      assert hd(items)["exam_title"] == "Емтихан"
    end

    test "paging by cursor repeats nothing and the filter and errors behave" do
      tenant = tenant("gh3324-page")
      seed = seed!(tenant)
      admin = user_ctx(tenant, ["TENANT_ADMIN"])
      order = expected_order(seed)

      %{"items" => [first], "next_cursor" => cursor} = json(get("#{@base}?page_size=1", admin))
      assert first["session_id"] == Enum.at(order, 0)
      assert is_binary(cursor)

      %{"items" => rest, "next_cursor" => nil} =
        json(get("#{@base}?page_size=5&cursor=#{cursor}", admin))

      assert Enum.map(rest, & &1["session_id"]) == tl(order)

      %{"items" => [only]} = json(get("#{@base}?exam_id=#{seed.other_exam.record_id}", admin))
      assert only["session_id"] == List.last(order)

      %{"items" => none} = json(get("#{@base}?exam_id=#{Ecto.UUID.generate()}", admin))
      assert none == []

      assert get("#{@base}?exam_id=not-a-uuid", admin).status == 400

      for bad <- ["abc", "-1", "0", "201"] do
        assert get("#{@base}?page_size=#{bad}", admin).status == 400, "page_size=#{bad}"
      end

      assert get("#{@base}?cursor=garbage", admin).status == 400
    end
  end

  # ── G-redact ────────────────────────────────────────────────────────────

  describe "G-redact" do
    test "list and detail carry none of the forbidden fields and the answer is data" do
      tenant = tenant("gh3324-redact")
      seed = seed!(tenant)
      admin = user_ctx(tenant, ["TENANT_ADMIN"])
      [s1 | _] = seed.pending

      list = get(@base, admin)
      detail = get(detail_path(s1.record_id, seed.short.record_id), admin)
      assert list.status == 200 and detail.status == 200

      forbidden =
        ~w(is_correct likert explanation exam_snapshot passing_score_pct user_id candidate_id
           SECRET-EXPLANATION SECRET-SNAPSHOT) ++
          [seed.candidate.user.email, seed.candidate.user.display_name, "61.5"]

      for body <- [list.resp_body, detail.resp_body], word <- forbidden do
        refute String.contains?(body, word), "#{word} leaked"
      end

      assert json(detail)["text_answer"] == "<b>\"A&B\"</b> 'x'"
      assert json(detail)["max_score"] == 2.0
    end

    test "a pending row with no answer shows an empty text_answer" do
      tenant = tenant("gh3324-noans")
      seed = seed!(tenant)
      admin = user_ctx(tenant, ["TENANT_ADMIN"])
      [_, _, s3] = seed.pending

      conn = get(detail_path(s3.record_id, seed.short.record_id), admin)
      assert conn.status == 200
      assert json(conn)["text_answer"] == ""
    end
  end

  # ── G-404 ───────────────────────────────────────────────────────────────

  describe "G-404" do
    test "every miss on the detail route is the same 404" do
      tenant = tenant("gh3324-404a")
      other = tenant("gh3324-404b")
      seed = seed!(tenant)
      other_seed = seed!(other)
      admin = user_ctx(tenant, ["TENANT_ADMIN"])
      [s1 | _] = seed.pending
      [o1 | _] = other_seed.pending

      paths = [
        detail_path(Ecto.UUID.generate(), seed.short.record_id),
        detail_path(o1.record_id, other_seed.short.record_id),
        detail_path(s1.record_id, seed.single.record_id),
        detail_path(seed.graded.record_id, seed.short.record_id),
        detail_path(s1.record_id, Ecto.UUID.generate()),
        detail_path("not-a-uuid", seed.short.record_id),
        detail_path(s1.record_id, "not-a-uuid")
      ]

      shapes =
        for path <- paths do
          conn = get(path, admin)
          assert conn.status == 404, path

          {conn.status, conn.resp_body,
           conn.resp_headers
           |> Enum.reject(fn {k, _} -> k in ["x-request-id", "date"] end)
           |> Enum.sort()}
        end

      assert length(Enum.uniq(shapes)) == 1
    end
  end

  # ── G-tenant ────────────────────────────────────────────────────────────

  describe "G-tenant" do
    test "tenant A sees none of tenant B's rows, and gets 404 on their detail" do
      a = tenant("gh3324-tenA")
      b = tenant("gh3324-tenB")
      seed_a = seed!(a)
      seed_b = seed!(b)
      admin_a = user_ctx(a, ["TENANT_ADMIN"])

      %{"items" => items} = json(get(@base, admin_a))
      ids = Enum.map(items, & &1["session_id"])
      assert ids == expected_order(seed_a)
      assert Enum.all?(seed_b.pending, &(&1.record_id not in ids))

      [b1 | _] = seed_b.pending
      assert get(detail_path(b1.record_id, seed_b.short.record_id), admin_a).status == 404

      platform = user_ctx(a, ["PLATFORM_ADMIN"])
      %{"items" => platform_items} = json(get(@base, platform))
      assert Enum.map(platform_items, & &1["session_id"]) == ids
    end

    test "the compiled routes take no tenant parameter" do
      routes =
        Letflow.Modules.Exam.Router.__authz_routes__()
        |> Enum.filter(fn {_method, path, _key} -> String.contains?(path, "grading-queue") end)

      assert length(routes) == 2
      for {_method, path, _key} <- routes, do: refute(path =~ ~r/tenant/i)
    end
  end

  # ── G-locale ────────────────────────────────────────────────────────────

  describe "G-locale" do
    test "?locale picks the language, absent uses the default, unknown falls back" do
      tenant = tenant("gh3324-locale")
      seed = seed!(tenant)
      admin = user_ctx(tenant, ["TENANT_ADMIN"])
      [s1 | _] = seed.pending

      stem = fn query -> hd(json(get(@base <> query, admin))["items"])["stem"] end
      assert stem.("") == "Сұрақ"
      assert stem.("?locale=ru") == "Вопрос"
      assert stem.("?locale=en") == "Question"
      assert stem.("?locale=zz") == "Сұрақ"

      detail = detail_path(s1.record_id, seed.short.record_id)
      assert json(get(detail <> "?locale=ru", admin))["stem"] == "Вопрос"
    end
  end
end
