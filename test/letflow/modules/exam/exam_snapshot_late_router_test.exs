defmodule Letflow.Modules.Exam.ExamSnapshotLateRouterTest do
  @moduledoc """
  GH #2682 / REQ-511 PR b, design `lib/letflow/design/req511-exam-content-snapshot.md` sections 6,
  7.4, 12.1 (T-09), 12.2 (T-20b), 17.6 and 18.6 (spec `test/specs/GH2682-exam-snapshot-pr-b.md`):
  how `Letflow.Modules.Exam.Router` serves the certificate and download routes from the session
  snapshot and renders the snapshot failures, through the real `Letflow.Router` pipeline with a
  real CANDIDATE bearer token (DIRECTIVE T-1, T-2).

    * T-20b: `{:grading_error, _}` on the certificate and download routes is the constant 500
      ("exam grading failed; the session was not scored"), `{:snapshot_error, _}` the constant 503
      ("exam service is being upgraded; retry shortly"), never a reason, an id or a value, and the
      bodies of different reasons are byte-identical (INV-4, INV-5).
    * T-09 over HTTP: the certificate flag edited after the start does not change the response.
    * A legacy (pre-cutover) session is served: state read, autosave and submit take the late
      snapshot, and a legacy submitted session gets its certificate and PDF from
      `late_certificate` facts.
    * R6 over HTTP: in a tenant that is not rolled out, a non-owner and a nonexistent session id
      get the SAME 404 bytes on every session route, never the 503 only the owner sees.

  Query-count parity is asserted at the context level (`snapshot_late_test.exs`), where no API token
  `last_used_at` write (the second-boundary flake of GH #2729) is in the way.

  Runs outside the sandbox transaction: `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.Entities.Record.Latest
  alias Letflow.ExamFixtures, as: Fx
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User

  @base "/api/v1/modules/exam/exam-sessions"
  @fixed_trace "00000000-0000-4000-8000-0000000000cc"

  @grading_detail "exam grading failed; the session was not scored"
  @upgrading_detail "exam service is being upgraded; retry shortly"

  # Every reason atom, wrapper name and snapshot word that must never reach a response body.
  @leaky_words ~w(snapshot_missing snapshot_corrupt threshold_missing exam_section_missing
                  certificate_facts_missing grading_error snapshot_error definition_missing
                  restrictions_missing audit_failed late_certificate exam_snapshot sha256 nonce
                  correct_option_ids)

  # ── helpers ────────────────────────────────────────────────────────────────────────────────

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp request(method, path, ctx, body) do
    base =
      case body do
        nil ->
          conn(method, path)

        body ->
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
      end

    base
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> put_req_header("x-trace-id", @fixed_trace)
    |> dispatch()
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp tenant(slug_prefix) do
    %{tenant_id: tenant_id, schema_name: schema_name} =
      Fx.provisioned_tenant_with_exam_definitions(slug_prefix)

    %Tenant{slug: slug} = Repo.get(Tenant, tenant_id)
    %{schema_name: schema_name, slug: slug}
  end

  defp candidate_ctx(tenant) do
    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "gh2682-late-router-#{Ecto.UUID.generate()}",
        display_name: "GH2682 Late Router Test User",
        email: "gh2682-late-router-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: tenant.schema_name)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: ["CANDIDATE"], expires_at: nil},
        prefix: tenant.schema_name
      )

    %{schema_name: tenant.schema_name, slug: tenant.slug, plaintext: plaintext, user_id: user.id}
  end

  defp build_exam!(schema, exam_attrs) do
    category_id = Ecto.UUID.generate()

    exam =
      Fx.create_record!(
        schema,
        "exam",
        Map.merge(
          %{
            "title" => %{"en" => "Router Exam"},
            "status" => "active",
            "time_limit_minutes" => 30,
            "passing_score_pct" => 60.0,
            "max_attempts" => 10,
            "shuffle_questions" => false,
            "shuffle_options" => false,
            "show_answers" => "never",
            "on_tab_switch" => "log",
            "certificate_enabled" => true
          },
          exam_attrs
        )
      )

    question =
      Fx.create_record!(schema, "question", %{
        "category_id" => category_id,
        "difficulty" => "easy",
        "type" => "single",
        "default_locale" => "en",
        "status" => "active",
        "version" => 1,
        "stem" => %{"en" => "Stem?"}
      })

    [correct, _wrong] =
      for {sort_order, correct?} <- [{0, true}, {1, false}] do
        Fx.create_record!(schema, "answer_option", %{
          "question_id" => question.record_id,
          "sort_order" => sort_order,
          "is_correct" => correct?,
          "text" => %{"en" => "Option #{sort_order}"}
        }).record_id
      end

    Fx.create_record!(schema, "exam_question_rule", %{
      "exam_id" => exam.record_id,
      "mode" => "random",
      "category_id" => category_id,
      "count" => 1,
      "sort_order" => 0
    })

    %{exam: exam, question_id: question.record_id, correct_id: correct}
  end

  defp assert_constant_problem!(conn, status, detail) do
    assert conn.status == status
    assert json(conn)["detail"] == detail

    body = String.downcase(conn.resp_body)
    leaked = Enum.filter(@leaky_words, &String.contains?(body, &1))
    assert leaked == []
  end

  # A fresh tenant with a candidate who started, answered correctly and submitted over HTTP.
  defp passed!(slug, exam_attrs) do
    tenant = tenant(slug)
    ctx = candidate_ctx(tenant)
    content = build_exam!(tenant.schema_name, exam_attrs)

    created = request("POST", @base, ctx, %{"exam_id" => content.exam.record_id})
    assert created.status == 201
    session_id = json(created)["session"]["id"]

    answered =
      request("PUT", "#{@base}/#{session_id}/answers/#{content.question_id}", ctx, %{
        "selected_option_ids" => [content.correct_id],
        "time_spent_seconds" => 0
      })

    assert answered.status == 200

    submitted = request("POST", "#{@base}/#{session_id}/submit", ctx, nil)
    assert submitted.status == 200
    assert %{"status" => "submitted", "passed" => true} = json(submitted)

    %{tenant: tenant, ctx: ctx, content: content, session_id: session_id}
  end

  defp certificate(run),
    do: request("POST", "#{@base}/#{run.session_id}/certificate", run.ctx, nil)

  defp download(run),
    do: request("GET", "#{@base}/#{run.session_id}/certificate/download", run.ctx, nil)

  # ── T-09 over HTTP ─────────────────────────────────────────────────────────────────────────

  describe "T-09 the certificate flag edited after the start" do
    test "enabled at start, disabled after the submit: the certificate (200) and the PDF are served" do
      run = passed!("gh2682-b-http-t09-on", %{"certificate_enabled" => true})

      Fx.update_record!(run.tenant.schema_name, "exam", run.content.exam.record_id, %{
        "certificate_enabled" => false
      })

      assert certificate(run).status == 200
      pdf = download(run)
      assert pdf.status == 200
      assert binary_part(pdf.resp_body, 0, 5) == "%PDF-"
    end

    test "disabled at start, enabled after the submit: still the 409 'this exam does not issue certificates'" do
      run = passed!("gh2682-b-http-t09-off", %{"certificate_enabled" => false})

      Fx.update_record!(run.tenant.schema_name, "exam", run.content.exam.record_id, %{
        "certificate_enabled" => true
      })

      for conn <- [certificate(run), download(run)] do
        assert conn.status == 409
        assert json(conn)["detail"] == "this exam does not issue certificates"
      end
    end

    test "the live exam removed after the submit: the certificate is still served (T-11)" do
      run = passed!("gh2682-b-http-t11", %{})

      exam_id = run.content.exam.record_id

      assert {1, _} =
               Repo.delete_all(
                 from(l in Latest, where: l.entity_type == "exam" and l.record_id == ^exam_id),
                 prefix: run.tenant.schema_name
               )

      assert certificate(run).status == 200
    end
  end

  # ── T-20b: the render clauses of the certificate and download routes ───────────────────────

  describe "T-20b {:grading_error, _} on the certificate and download routes" do
    test "a corrupt snapshot, a missing certificate fact and a missing snapshot are the SAME constant 500 on both routes, byte for byte" do
      run = passed!("gh2682-b-http-t20b-500", %{})
      schema = run.tenant.schema_name
      pristine = Fx.session_snapshot(schema, run.session_id)

      reasons = [
        {:snapshot_corrupt,
         fn ->
           Fx.update_record!(schema, "session", run.session_id, %{
             "exam_snapshot" => put_in(pristine, ["exam", "title"], %{"en" => "Forged"})
           })
         end},
        {:certificate_facts_missing,
         fn ->
           Fx.update_record!(schema, "session", run.session_id, %{"exam_snapshot" => pristine})

           Fx.rewrite_snapshot!(
             schema,
             run.session_id,
             &put_in(&1, ["exam", "certificate_enabled"], "yes")
           )
         end},
        {:snapshot_missing,
         fn ->
           Fx.update_record!(schema, "session", run.session_id, %{"exam_snapshot" => pristine})
           Fx.force_field!(schema, "session", run.session_id, "exam_snapshot", :delete)
         end}
      ]

      bodies =
        for {reason, arrange} <- reasons, route <- [:certificate, :download] do
          arrange.()
          conn = if route == :certificate, do: certificate(run), else: download(run)
          assert {reason, route, conn.status} == {reason, route, 500}
          assert_constant_problem!(conn, 500, @grading_detail)
          {route, conn.resp_body}
        end

      # the three reasons are indistinguishable from the outside, route by route
      for route <- [:certificate, :download] do
        assert bodies |> Enum.filter(&(elem(&1, 0) == route)) |> Enum.uniq() |> length() == 1
      end
    end

    test "a snapshot failure (the tenant is not rolled out) is the constant 503 on both routes; a PDF is never produced" do
      run = passed!("gh2682-b-http-t20b-503", %{})
      schema = run.tenant.schema_name
      :ok = Fx.legacy_session!(schema, run.session_id)
      Fx.downgrade_session_definition!(schema)

      certificate_conn = certificate(run)
      assert_constant_problem!(certificate_conn, 503, @upgrading_detail)

      download_conn = download(run)
      assert_constant_problem!(download_conn, 503, @upgrading_detail)
      refute List.keymember?(download_conn.resp_headers, "content-disposition", 0)

      assert Fx.session_snapshot(schema, run.session_id) == nil
    end

    test "a restriction row missing is the same constant 503" do
      run = passed!("gh2682-b-http-t20b-503r", %{})
      schema = run.tenant.schema_name
      :ok = Fx.legacy_session!(schema, run.session_id)
      assert Fx.delete_answer_key_restrictions!(schema) == 5

      assert_constant_problem!(certificate(run), 503, @upgrading_detail)
      assert_constant_problem!(download(run), 503, @upgrading_detail)
    end

    test "T-61 a submitted session of a post-cutover record that lost its snapshot is the constant 500, never healed from the live exam" do
      run = passed!("gh2682-b-http-t61", %{})
      schema = run.tenant.schema_name
      Fx.force_field!(schema, "session", run.session_id, "exam_snapshot", :delete)

      assert_constant_problem!(certificate(run), 500, @grading_detail)
      assert_constant_problem!(download(run), 500, @grading_detail)
      assert Fx.session_snapshot(schema, run.session_id) == nil
    end
  end

  # ── the legacy candidate flow over HTTP ────────────────────────────────────────────────────

  describe "a legacy (pre-cutover) session is served" do
    test "state read, autosave and submit take the late snapshot; the certificate is then served from the snapshot" do
      tenant = tenant("gh2682-b-http-legacy")
      ctx = candidate_ctx(tenant)
      schema = tenant.schema_name
      content = build_exam!(schema, %{})

      created = request("POST", @base, ctx, %{"exam_id" => content.exam.record_id})
      session_id = json(created)["session"]["id"]
      :ok = Fx.legacy_session!(schema, session_id)
      assert Fx.session_snapshot(schema, session_id) == nil

      # the first touch is a state read
      state = request("GET", "#{@base}/#{session_id}", ctx, nil)
      assert state.status == 200
      assert %{"origin" => "late"} = Fx.session_snapshot(schema, session_id)
      refute String.contains?(state.resp_body, "exam_snapshot")

      answered =
        request("PUT", "#{@base}/#{session_id}/answers/#{content.question_id}", ctx, %{
          "selected_option_ids" => [content.correct_id],
          "time_spent_seconds" => 0
        })

      assert answered.status == 200

      submitted = request("POST", "#{@base}/#{session_id}/submit", ctx, nil)
      assert %{"status" => "submitted", "passed" => true} = json(submitted)

      assert %{"origin" => "late"} = Fx.session_snapshot(schema, session_id)
      run = %{ctx: ctx, session_id: session_id}
      assert certificate(run).status == 200
    end

    test "a legacy submitted session gets its certificate and PDF from late_certificate facts; no body ever carries snapshot content" do
      run = passed!("gh2682-b-http-latecert", %{})
      schema = run.tenant.schema_name
      :ok = Fx.legacy_session!(schema, run.session_id)

      issued = certificate(run)
      assert issued.status == 200

      body = String.downcase(issued.resp_body)

      for word <- ~w(exam_snapshot nonce sha256 correct_option_ids late_certificate) do
        refute {word, String.contains?(body, word)} == {word, true}
      end

      assert %{"origin" => "late_certificate"} = Fx.session_snapshot(schema, run.session_id)

      pdf = download(run)
      assert pdf.status == 200
      assert binary_part(pdf.resp_body, 0, 5) == "%PDF-"
    end
  end

  # ── R6 over HTTP ───────────────────────────────────────────────────────────────────────────

  describe "R6 ownership before prerequisites, over HTTP" do
    test "in a tenant that is not rolled out a non-owner and a random id get byte-identical 404s on every session route; the owner gets the constant 503" do
      tenant = tenant("gh2682-b-http-r6")
      schema = tenant.schema_name
      owner = candidate_ctx(tenant)
      stranger = candidate_ctx(tenant)
      content = build_exam!(schema, %{})

      created = request("POST", @base, owner, %{"exam_id" => content.exam.record_id})
      session_id = json(created)["session"]["id"]
      :ok = Fx.legacy_session!(schema, session_id)
      Fx.downgrade_session_definition!(schema)
      random_id = Ecto.UUID.generate()

      routes = [
        {"GET", "", nil},
        {"PUT", "/answers/#{content.question_id}",
         %{"selected_option_ids" => [], "time_spent_seconds" => 0}},
        {"POST", "/submit", nil},
        {"POST", "/events", %{"type" => "tab_switch"}},
        {"POST", "/certificate", nil},
        {"GET", "/certificate/download", nil}
      ]

      for {method, suffix, body} <- routes do
        real = request(method, "#{@base}/#{session_id}#{suffix}", stranger, body)
        missing = request(method, "#{@base}/#{random_id}#{suffix}", stranger, body)

        assert {method, suffix, real.status} == {method, suffix, 404}

        assert {method, suffix, String.replace(real.resp_body, session_id, "<ID>")} ==
                 {method, suffix, String.replace(missing.resp_body, random_id, "<ID>")}
      end

      # the owner is the only one who learns the tenant is not rolled out
      assert_constant_problem!(
        request("GET", "#{@base}/#{session_id}", owner, nil),
        503,
        @upgrading_detail
      )

      assert_constant_problem!(
        request("POST", "#{@base}/#{session_id}/submit", owner, nil),
        503,
        @upgrading_detail
      )

      assert Fx.session_snapshot(schema, session_id) == nil
    end
  end
end
