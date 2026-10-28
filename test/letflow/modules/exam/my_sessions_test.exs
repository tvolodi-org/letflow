defmodule Letflow.Modules.Exam.MySessionsTest do
  @moduledoc """
  GH #3321 / REQ-587 part A: the candidate's own results list,
  `GET /api/v1/modules/exam/exam-sessions/mine`, gated by `:ExamSessionRead`. Full pipeline
  dispatch with real bearer tokens. Tests M-perm, M-own, M-inv5, M-tenant, M-shape, M-cert and
  M-page of the design; M-pins is covered by the edited pin tests (route table, snapshot lengths).
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.ExamFixtures
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User

  @base "/api/v1/modules/exam/exam-sessions"
  @mine @base <> "/mine"
  @denied_roles ~w(PROCESS_OPERATOR PROCESS_DESIGNER TASK_WORKER AGENT_RUNNER)

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp request(method, path, ctx) do
    conn(method, path)
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> put_req_header("x-trace-id", "t-3321")
    |> dispatch()
  end

  defp get(path, ctx), do: request(:get, path, ctx)
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
        username: "gh3321-user-#{Ecto.UUID.generate()}",
        display_name: "Candidate Display Name",
        email: "gh3321-#{Ecto.UUID.generate()}@example.com",
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
      user_id: user.id
    }
  end

  defp create_exam!(schema, title) do
    ExamFixtures.create_record!(schema, "exam", %{
      "title" => title,
      "status" => "active",
      "time_limit_minutes" => 30,
      "passing_score_pct" => 60.0,
      "max_attempts" => 3,
      "shuffle_questions" => false,
      "shuffle_options" => false,
      "show_answers" => "never",
      "on_tab_switch" => "log",
      "certificate_enabled" => true
    })
  end

  defp create_session!(schema, exam_id, user_id, status, opts \\ []) do
    base = %{
      "exam_id" => exam_id,
      "user_id" => user_id,
      "status" => status,
      "seed" => 7,
      "started_at" => "2026-10-01T09:00:00Z",
      "expires_at" => Keyword.get(opts, :expires_at, "2026-10-01T10:00:00Z"),
      "passed" => Keyword.get(opts, :passed, false),
      "exam_snapshot" => %{"secret" => "SECRET-SNAPSHOT"}
    }

    fv =
      base
      |> then(
        &if status == "in_progress",
          do: &1,
          else: Map.put(&1, "submitted_at", "2026-10-01T09:50:00Z")
      )
      |> then(&if opts[:score], do: Map.put(&1, "score_pct", opts[:score]), else: &1)

    ExamFixtures.create_record!(schema, "session", fv)
  end

  defp create_certificate!(schema, session_id) do
    ExamFixtures.create_record!(schema, "certificate", %{
      "session_id" => session_id,
      "issued_at" => "2026-10-01T10:00:00Z",
      "candidate_name" => "Candidate",
      "exam_title" => %{"en" => "Exam"},
      "score_pct" => 90.0,
      "branding_snapshot" => %{}
    })
  end

  defp ids(body), do: Enum.map(body["items"], & &1["session_id"])

  defp count_rows(schema, table) do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM \"#{schema}\".\"#{table}\"")
    n
  end

  # ── M-perm ──────────────────────────────────────────────────────────────

  describe "M-perm" do
    test "candidate 200, roles without ExamSessionRead 403, auditor same 403 body, no token 401" do
      t = tenant("gh3321-perm")
      candidate = user_ctx(t, ["CANDIDATE"])

      assert get(@mine, candidate).status == 200

      bodies =
        for role <- @denied_roles ++ ["TENANT_AUDITOR"] do
          resp = get(@mine, user_ctx(t, [role]))
          assert resp.status == 403, "#{role} got #{resp.status}"
          resp.resp_body
        end

      assert bodies |> Enum.uniq() |> length() == 1

      assert conn(:get, @mine)
             |> put_req_header("x-tenant-slug", t.slug)
             |> dispatch()
             |> Map.get(:status) ==
               401
    end
  end

  # ── M-own ───────────────────────────────────────────────────────────────

  describe "M-own" do
    test "each candidate gets only their own finished sessions; owner params are ignored" do
      t = tenant("gh3321-own")
      a = user_ctx(t, ["CANDIDATE"])
      b = user_ctx(t, ["CANDIDATE"])
      exam = create_exam!(t.schema_name, %{"en" => "Exam"})
      a1 = create_session!(t.schema_name, exam.record_id, a.user_id, "submitted")
      a2 = create_session!(t.schema_name, exam.record_id, a.user_id, "submitted")
      _a3 = create_session!(t.schema_name, exam.record_id, a.user_id, "in_progress")
      b1 = create_session!(t.schema_name, exam.record_id, b.user_id, "submitted")

      assert Enum.sort(ids(json(get(@mine, a)))) == Enum.sort([a1.record_id, a2.record_id])
      assert ids(json(get(@mine, b))) == [b1.record_id]

      forged =
        @mine <>
          "?user_id=#{b.user_id}&candidate_id=#{b.user_id}&tenant_id=#{Ecto.UUID.generate()}"

      assert Enum.sort(ids(json(get(forged, a)))) == Enum.sort([a1.record_id, a2.record_id])
    end

    test "the delegate filters on the opts user_id and the router takes it from auth_context" do
      t = tenant("gh3321-ownd")
      a = user_ctx(t, ["CANDIDATE"])
      b = user_ctx(t, ["CANDIDATE"])
      exam = create_exam!(t.schema_name, %{"en" => "Exam"})
      a1 = create_session!(t.schema_name, exam.record_id, a.user_id, "submitted")
      b1 = create_session!(t.schema_name, exam.record_id, b.user_id, "submitted")

      list = fn uid ->
        {:ok, %{items: items}} =
          Letflow.Modules.Exam.Session.list_own_sessions(t.schema_name, scope: :all, user_id: uid)

        Enum.map(items, & &1["session_id"])
      end

      assert list.(a.user_id) == [a1.record_id]
      assert list.(b.user_id) == [b1.record_id]

      src = File.read!("lib/letflow/modules/exam/router.ex")
      [_, mine_src] = String.split(src, "defp handle_list_my_sessions(conn) do", parts: 2)
      [mine_src | _] = String.split(mine_src, "defp render_list_my_sessions", parts: 2)
      assert mine_src =~ "conn.assigns.auth_context.user_id"
      refute mine_src =~ "Map.get(query, \"user_id\")"
      refute mine_src =~ "Map.get(query, \"candidate_id\")"
      refute mine_src =~ "Map.get(query, \"tenant_id\")"
    end
  end

  # ── M-inv5 ──────────────────────────────────────────────────────────────

  describe "M-inv5" do
    test "a foreign session id answers exactly like a random one; the list never shows it" do
      t = tenant("gh3321-inv5")
      a = user_ctx(t, ["CANDIDATE"])
      b = user_ctx(t, ["CANDIDATE"])
      exam = create_exam!(t.schema_name, %{"en" => "Exam"})
      b1 = create_session!(t.schema_name, exam.record_id, b.user_id, "submitted", passed: true)
      cert = create_certificate!(t.schema_name, b1.record_id)
      random = Ecto.UUID.generate()

      volatile = ~w(x-trace-id x-request-id date)

      shape = fn conn ->
        {conn.status, Enum.reject(conn.resp_headers, fn {k, _} -> k in volatile end),
         conn.resp_body}
      end

      for {method, suffix} <- [
            {:get, ""},
            {:post, "/certificate"},
            {:get, "/certificate/download"}
          ] do
        foreign = request(method, "#{@base}/#{b1.record_id}#{suffix}", a)
        unknown = request(method, "#{@base}/#{random}#{suffix}", a)
        assert shape.(foreign) == shape.(unknown), "#{method} #{suffix} differs"
      end

      body = get(@mine, a) |> json()
      refute inspect(body) =~ b1.record_id
      refute inspect(body) =~ cert.record_id

      assert get(@mine <> "?exam_id=not-a-uuid", a).status == 400
      other = get(@mine <> "?exam_id=#{Ecto.UUID.generate()}", a)
      assert other.status == 200
      assert json(other)["items"] == []
    end
  end

  # ── M-tenant ────────────────────────────────────────────────────────────

  describe "M-tenant" do
    test "another tenant's sessions and certificates never appear; no tenant segment" do
      ta = tenant("gh3321-ta")
      tb = tenant("gh3321-tb")
      a = user_ctx(ta, ["CANDIDATE"])
      b = user_ctx(tb, ["CANDIDATE"])
      admin = user_ctx(ta, ["TENANT_ADMIN"])
      exam_b = create_exam!(tb.schema_name, %{"en" => "B exam"})
      sb = create_session!(tb.schema_name, exam_b.record_id, b.user_id, "submitted", passed: true)
      create_certificate!(tb.schema_name, sb.record_id)
      # Same user id as candidate A, in tenant B's schema: still not A's data.
      _sb2 = create_session!(tb.schema_name, exam_b.record_id, a.user_id, "submitted")

      assert json(get(@mine, a))["items"] == []
      assert ids(json(get(@mine, b))) == [sb.record_id]
      assert json(get(@mine, admin))["items"] == []

      route =
        Letflow.Modules.Exam.Router.__authz_routes__()
        |> Enum.find(fn {m, p, _} -> m == "GET" and String.ends_with?(to_string(p), "/mine") end)

      refute is_nil(route)
      refute inspect(route) =~ "tenant"
    end
  end

  # ── M-shape ─────────────────────────────────────────────────────────────

  describe "M-shape" do
    test "exactly the ten keys, no snapshot leak, grading_pending passed nil, missing exam title nil" do
      t = tenant("gh3321-shape")
      a = user_ctx(t, ["CANDIDATE"])
      exam = create_exam!(t.schema_name, %{"en" => "Shape exam"})
      gone = create_exam!(t.schema_name, %{"en" => "Gone exam"})

      s1 =
        create_session!(t.schema_name, exam.record_id, a.user_id, "submitted",
          passed: true,
          score: 80.0
        )

      s2 =
        create_session!(t.schema_name, exam.record_id, a.user_id, "auto_submitted", score: 10.0)

      s3 = create_session!(t.schema_name, exam.record_id, a.user_id, "grading_pending")
      s4 = create_session!(t.schema_name, gone.record_id, a.user_id, "submitted")
      # fk_session_exam_id is ON DELETE RESTRICT, so "missing" is a soft-deleted exam.
      ExamFixtures.delete_record!(t.schema_name, "exam", gone.record_id)

      resp = get(@mine, a)
      assert resp.status == 200
      refute resp.resp_body =~ "SECRET-SNAPSHOT"
      items = Map.new(json(resp)["items"], &{&1["session_id"], &1})

      keys =
        ~w(session_id exam_id exam_title status started_at submitted_at score_pct passed certificate_issued certificate_id)
        |> Enum.sort()

      assert map_size(items) == 4
      for {_, item} <- items, do: assert(Enum.sort(Map.keys(item)) == keys)

      assert items[s1.record_id]["exam_title"] == %{"en" => "Shape exam"}
      assert items[s1.record_id]["passed"] == true
      assert items[s1.record_id]["score_pct"] == 80.0
      assert items[s2.record_id]["status"] == "auto_submitted"
      assert items[s3.record_id]["passed"] == nil
      assert items[s4.record_id]["exam_title"] == nil
    end
  end

  # ── M-cert ──────────────────────────────────────────────────────────────

  describe "M-cert" do
    test "flag and id, no writes, one certificate query per page" do
      t = tenant("gh3321-cert")
      a = user_ctx(t, ["CANDIDATE"])
      exam = create_exam!(t.schema_name, %{"en" => "Exam"})
      schema = t.schema_name

      passed_cert = create_session!(schema, exam.record_id, a.user_id, "submitted", passed: true)
      passed_none = create_session!(schema, exam.record_id, a.user_id, "submitted", passed: true)
      failed = create_session!(schema, exam.record_id, a.user_id, "submitted")
      _p4 = create_session!(schema, exam.record_id, a.user_id, "submitted", passed: true)
      _p5 = create_session!(schema, exam.record_id, a.user_id, "auto_submitted")
      cert = create_certificate!(schema, passed_cert.record_id)

      events_before = count_rows(schema, "events")
      audit_before = count_rows(schema, "audit_entries")

      test_pid = self()
      handler = "gh3321-cert-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        Letflow.Repo.config()[:telemetry_prefix] ++ [:query],
        fn _event, _measure, meta, _cfg ->
          # Entity rows are read from one generic table: a certificate read is a row query whose
          # bound parameters carry the entity type "certificate".
          if String.contains?(meta.query, "field_values") and
               "certificate" in List.flatten(meta.params),
             do: send(test_pid, {:cert_query, meta.query})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      resp = get(@mine <> "?page_size=5", a)
      assert resp.status == 200
      items = Map.new(json(resp)["items"], &{&1["session_id"], &1})
      assert length(Map.keys(items)) == 5

      assert items[passed_cert.record_id]["certificate_issued"] == true
      assert items[passed_cert.record_id]["certificate_id"] == cert.record_id
      assert items[passed_none.record_id]["certificate_issued"] == false
      assert items[passed_none.record_id]["certificate_id"] == nil
      assert items[failed.record_id]["certificate_issued"] == false

      assert count_rows(schema, "events") == events_before
      assert count_rows(schema, "audit_entries") == audit_before

      assert_received {:cert_query, _}
      refute_received {:cert_query, _}

      # An empty page runs no certificate query.
      empty = get(@mine <> "?exam_id=#{Ecto.UUID.generate()}", a)
      assert json(empty)["items"] == []
      refute_received {:cert_query, _}
    end
  end

  # ── M-page ──────────────────────────────────────────────────────────────

  describe "M-page" do
    test "cursor walk over 7 sessions, expires_at descending, exam_id filter, bad page_size" do
      t = tenant("gh3321-page")
      a = user_ctx(t, ["CANDIDATE"])
      schema = t.schema_name
      exam = create_exam!(schema, %{"en" => "Exam"})
      other = create_exam!(schema, %{"en" => "Other"})

      # Distinct instants, plus two sessions sharing one (the tiebreaker case).
      stamps = for d <- 1..6, do: "2026-10-0#{d}T10:00:00Z"
      stamps = stamps ++ ["2026-10-03T10:00:00Z"]

      created =
        for s <- stamps,
            do: create_session!(schema, exam.record_id, a.user_id, "submitted", expires_at: s)

      odd =
        create_session!(schema, other.record_id, a.user_id, "submitted",
          expires_at: "2026-10-09T10:00:00Z"
        )

      walk = fn path, acc, walk ->
        body = get(path, a) |> json()
        acc = acc ++ body["items"]

        case body["next_cursor"] do
          nil ->
            acc

          cursor ->
            walk.(@mine <> "?page_size=3&exam_id=#{exam.record_id}&cursor=#{cursor}", acc, walk)
        end
      end

      all = walk.(@mine <> "?page_size=3&exam_id=#{exam.record_id}", [], walk)
      all_ids = Enum.map(all, & &1["session_id"])

      assert length(all_ids) == 7
      assert all_ids == Enum.uniq(all_ids)
      assert Enum.sort(all_ids) == created |> Enum.map(& &1.record_id) |> Enum.sort()
      refute odd.record_id in all_ids

      sorted_stamps =
        created
        |> Map.new(&{&1.record_id, &1.field_values["expires_at"]})
        |> then(fn m -> Enum.map(all_ids, &Map.fetch!(m, &1)) end)

      assert sorted_stamps == Enum.sort(sorted_stamps, :desc)

      unfiltered = get(@mine, a) |> json()
      assert hd(unfiltered["items"])["session_id"] == odd.record_id

      assert get(@mine <> "?page_size=0", a).status == 400
      assert get(@mine <> "?page_size=abc", a).status == 400
    end

    test "the session entity definition is unchanged and still has no queried flag for the new route" do
      session = File.read!("priv/modules/exam/entity_definitions/session.json") |> Jason.decode!()
      text = inspect(session)

      for field <- ~w(exam_snapshot seed) do
        assert text =~ field
      end

      fields = session["fields"] || session["field_definitions"] || []
      by_name = Map.new(fields, &{&1["name"], &1})

      for f <- ~w(submitted_at started_at seed exam_snapshot), Map.has_key?(by_name, f) do
        refute by_name[f]["queried"] == true, "#{f} must stay unqueried"
      end
    end
  end
end
