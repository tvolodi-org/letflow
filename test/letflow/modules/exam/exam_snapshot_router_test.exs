defmodule Letflow.Modules.Exam.ExamSnapshotRouterTest do
  @moduledoc """
  GH #2682 / REQ-511 PR a, design `lib/letflow/design/req511-exam-content-snapshot.md` section 7.4
  and test T-20 (spec `test/specs/GH2682-exam-snapshot-pr-a.md`): how `Letflow.Modules.Exam.Router`
  renders the snapshot failures, through the real `Letflow.Router` pipeline with a real CANDIDATE
  bearer token (DIRECTIVE T-1, T-2).

    * `{:grading_error, _}`: HTTP 500 with a CONSTANT detail, never the reason, the question id
      or any value; the submit/autosave/state/event routes say "exam grading failed; the session
      was not scored", the start route says "exam content is invalid; the session was not
      started".
    * `{:snapshot_error, _}` (the rollout has not reached the tenant): HTTP 503 with a constant
      detail.
    * A manual pin naming a missing, inactive or malformed question: HTTP 422 with a constant
      detail that does not carry the id.
    * Ownership is decided before the snapshot is read: a non-owner gets the same 404 as for a
      nonexistent session, never a 500 or a 503.

  The certificate and download render cases of T-20 belong to PR b.
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
  @fixed_trace "00000000-0000-4000-8000-0000000000bb"

  @grading_detail "exam grading failed; the session was not scored"
  @content_detail "exam content is invalid; the session was not started"
  @upgrading_detail "exam service is being upgraded; retry shortly"
  @pin_detail "exam pins an unavailable question"

  # Every reason atom and wrapper name that must never reach a response body.
  @leaky_words ~w(snapshot_missing snapshot_corrupt threshold_missing threshold_invalid
                  exam_section_missing question_item_missing question_type_invalid key_missing
                  grading_error snapshot_error definition_missing restrictions_missing
                  question_not_found sha256 nonce)

  # ── helpers ────────────────────────────────────────────────────────────────────────────────

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp request(method, path, ctx, body \\ nil) do
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
        username: "gh2682-router-#{Ecto.UUID.generate()}",
        display_name: "GH2682 Router Test User",
        email: "gh2682-router-#{Ecto.UUID.generate()}@example.com",
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
            "certificate_enabled" => false
          },
          exam_attrs
        )
      )

    Fx.assign_all!(schema, exam.record_id)

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

    options =
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

    %{exam: exam, question_id: question.record_id, option_ids: options}
  end

  defp start_session!(ctx, exam_id) do
    conn = request("POST", @base, ctx, %{"exam_id" => exam_id})
    assert conn.status == 201
    json(conn)["session"]["id"]
  end

  defp assert_constant_problem!(conn, status, detail) do
    assert conn.status == status
    assert json(conn)["detail"] == detail

    body = String.downcase(conn.resp_body)
    leaked = Enum.filter(@leaky_words, &String.contains?(body, &1))
    assert leaked == []
  end

  defp assert_session_untouched!(schema, session_id) do
    assert {:ok, %{field_values: fv}} = Latest.get(session_id, "session", schema)
    assert fv["status"] == "in_progress"
    refute Map.has_key?(fv, "score_pct")
  end

  # A session of a fresh tenant: {tenant, ctx, exam context, session id, pristine snapshot}.
  defp started!(slug, exam_attrs) do
    tenant = tenant(slug)
    ctx = candidate_ctx(tenant)
    content = build_exam!(tenant.schema_name, exam_attrs)
    session_id = start_session!(ctx, content.exam.record_id)

    %{
      tenant: tenant,
      ctx: ctx,
      content: content,
      session_id: session_id,
      snapshot: Fx.session_snapshot(tenant.schema_name, session_id)
    }
  end

  # ── submit ─────────────────────────────────────────────────────────────────────────────────

  describe "T-20 submit" do
    test "each reason: status 500, the constant detail, no reason text, no id, and the session stays in progress" do
      %{tenant: tenant, ctx: ctx, content: content, session_id: session_id, snapshot: pristine} =
        started!("gh2682-t20-submit", %{})

      q = content.question_id
      unknown = Ecto.UUID.generate()

      forgeries = [
        {:threshold_missing,
         &update_in(&1, ["exam"], fn e -> Map.delete(e, "passing_score_pct") end)},
        {:threshold_invalid, &put_in(&1, ["exam", "passing_score_pct"], "abc")},
        {:exam_section_missing, &Map.delete(&1, "exam")},
        {:question_item_missing, &Map.update!(&1, "order", fn o -> o ++ [unknown] end)},
        {:key_missing, &put_in(&1, ["questions", q, "correct_option_ids"], [])},
        {:question_type_invalid, &put_in(&1, ["questions", q, "type"], "essay")}
      ]

      for {reason, forge} <- forgeries do
        Fx.update_record!(tenant.schema_name, "session", session_id, %{
          "exam_snapshot" => pristine
        })

        Fx.rewrite_snapshot!(tenant.schema_name, session_id, forge)

        conn = request("POST", "#{@base}/#{session_id}/submit", ctx)
        assert {reason, conn.status} == {reason, 500}
        assert_constant_problem!(conn, 500, @grading_detail)
        refute conn.resp_body =~ unknown
        assert_session_untouched!(tenant.schema_name, session_id)
      end

      # stale digest
      stale = put_in(pristine, ["questions", q, "correct_option_ids"], [])
      Fx.update_record!(tenant.schema_name, "session", session_id, %{"exam_snapshot" => stale})

      assert_constant_problem!(
        request("POST", "#{@base}/#{session_id}/submit", ctx),
        500,
        @grading_detail
      )

      # no snapshot at all
      Fx.force_field!(tenant.schema_name, "session", session_id, "exam_snapshot", :delete)

      assert_constant_problem!(
        request("POST", "#{@base}/#{session_id}/submit", ctx),
        500,
        @grading_detail
      )

      assert_session_untouched!(tenant.schema_name, session_id)
    end

    test "CONTROL: with an intact snapshot the same route scores (200)" do
      %{ctx: ctx, content: content, session_id: session_id} = started!("gh2682-t20-control", %{})

      conn =
        request("PUT", "#{@base}/#{session_id}/answers/#{content.question_id}", ctx, %{
          "selected_option_ids" => [hd(content.option_ids)],
          "time_spent_seconds" => 0
        })

      assert conn.status == 200

      submit = request("POST", "#{@base}/#{session_id}/submit", ctx)
      assert submit.status == 200
      assert %{"status" => "submitted", "passed" => true} = json(submit)
    end
  end

  # ── autosave, state, event ─────────────────────────────────────────────────────────────────

  describe "T-20 autosave and state" do
    test "a session without a usable snapshot: PUT answer, GET state and POST events (policy submit) are the constant 500" do
      %{tenant: tenant, ctx: ctx, content: content, session_id: session_id} =
        started!("gh2682-t20-others", %{"on_tab_switch" => "submit"})

      Fx.force_field!(tenant.schema_name, "session", session_id, "exam_snapshot", :delete)

      put =
        request("PUT", "#{@base}/#{session_id}/answers/#{content.question_id}", ctx, %{
          "selected_option_ids" => [hd(content.option_ids)],
          "time_spent_seconds" => 0
        })

      assert_constant_problem!(put, 500, @grading_detail)

      assert_constant_problem!(
        request("GET", "#{@base}/#{session_id}", ctx),
        500,
        @grading_detail
      )

      assert_constant_problem!(
        request("POST", "#{@base}/#{session_id}/events", ctx, %{"type" => "tab_switch"}),
        500,
        @grading_detail
      )

      assert_session_untouched!(tenant.schema_name, session_id)
    end
  end

  # ── start ──────────────────────────────────────────────────────────────────────────────────

  describe "T-20 start" do
    test "a live exam whose threshold is nil is the constant 500 for start, and creates no session" do
      tenant = tenant("gh2682-t20-start")
      ctx = candidate_ctx(tenant)
      %{exam: exam} = build_exam!(tenant.schema_name, %{})

      Fx.force_field!(
        tenant.schema_name,
        "exam",
        exam.record_id,
        "passing_score_pct",
        {:put, nil}
      )

      conn = request("POST", @base, ctx, %{"exam_id" => exam.record_id})
      assert_constant_problem!(conn, 500, @content_detail)

      assert Repo.aggregate(
               from(l in Latest, where: l.entity_type == "session"),
               :count,
               prefix: tenant.schema_name
             ) == 0
    end

    test "the rollout has not reached the tenant (no exam_snapshot field): the constant 503" do
      tenant = tenant("gh2682-t20-503-field")
      ctx = candidate_ctx(tenant)
      %{exam: exam} = build_exam!(tenant.schema_name, %{})
      Fx.downgrade_session_definition!(tenant.schema_name)

      conn = request("POST", @base, ctx, %{"exam_id" => exam.record_id})
      assert_constant_problem!(conn, 503, @upgrading_detail)
    end

    test "the snapshot restriction row is missing: the constant 503" do
      tenant = tenant("gh2682-t20-503-restriction")
      ctx = candidate_ctx(tenant)
      %{exam: exam} = build_exam!(tenant.schema_name, %{})
      assert Fx.delete_answer_key_restrictions!(tenant.schema_name) == 5

      conn = request("POST", @base, ctx, %{"exam_id" => exam.record_id})
      assert_constant_problem!(conn, 503, @upgrading_detail)
    end

    test "a manual pin naming a missing, inactive or malformed question: 422 with a constant detail that does not carry the id" do
      tenant = tenant("gh2682-t20-pin")
      ctx = candidate_ctx(tenant)

      archived =
        Fx.create_record!(tenant.schema_name, "question", %{
          "category_id" => Ecto.UUID.generate(),
          "difficulty" => "easy",
          "type" => "single",
          "default_locale" => "en",
          "status" => "archived",
          "version" => 1,
          "stem" => %{"en" => "Old"}
        })

      for pinned_id <- [Ecto.UUID.generate(), archived.record_id, "not-a-uuid"] do
        exam =
          Fx.create_record!(tenant.schema_name, "exam", %{
            "title" => %{"en" => "Pin Exam"},
            "status" => "active",
            "time_limit_minutes" => 30,
            "passing_score_pct" => 60.0,
            "max_attempts" => 10,
            "shuffle_questions" => false,
            "shuffle_options" => false,
            "show_answers" => "never",
            "on_tab_switch" => "log",
            "certificate_enabled" => false
          })

        Fx.assign_all!(tenant.schema_name, exam.record_id)

        rule =
          Fx.create_record!(tenant.schema_name, "exam_question_rule", %{
            "exam_id" => exam.record_id,
            "mode" => "manual",
            "category_id" => Ecto.UUID.generate(),
            "count" => 1,
            "sort_order" => 0
          })

        Fx.create_record!(tenant.schema_name, "exam_manual_question", %{
          "rule_id" => rule.record_id,
          "question_id" => pinned_id,
          "sort_order" => 0
        })

        conn = request("POST", @base, ctx, %{"exam_id" => exam.record_id})
        assert {pinned_id, conn.status} == {pinned_id, 422}
        assert json(conn)["detail"] == @pin_detail
        refute conn.resp_body =~ pinned_id
      end
    end
  end

  # ── GH #2762: soft-deleted answer options on the start route ───────────────────────────────

  describe "GH #2762 T-62o start with soft-deleted answer options" do
    test "a drawn question left without a live correct option is the existing constant 500 for start (no reason, no id), and creates no session" do
      tenant = tenant("gh2762-t62o-refused")
      ctx = candidate_ctx(tenant)
      %{exam: exam, option_ids: [correct_id, _wrong]} = build_exam!(tenant.schema_name, %{})
      :ok = Fx.delete_record!(tenant.schema_name, "answer_option", correct_id)

      conn = request("POST", @base, ctx, %{"exam_id" => exam.record_id})
      assert_constant_problem!(conn, 500, @content_detail)
      refute conn.resp_body =~ correct_id

      assert Repo.aggregate(
               from(l in Latest, where: l.entity_type == "session"),
               :count,
               prefix: tenant.schema_name
             ) == 0
    end

    test "SWAP (delete the old correct option, add a new one) starts with 201" do
      tenant = tenant("gh2762-t62o-swap")
      ctx = candidate_ctx(tenant)

      %{exam: exam, question_id: question_id, option_ids: [correct_id, _wrong]} =
        build_exam!(tenant.schema_name, %{})

      Fx.create_record!(tenant.schema_name, "answer_option", %{
        "question_id" => question_id,
        "sort_order" => 2,
        "is_correct" => true,
        "text" => %{"en" => "New correct"}
      })

      :ok = Fx.delete_record!(tenant.schema_name, "answer_option", correct_id)

      conn = request("POST", @base, ctx, %{"exam_id" => exam.record_id})
      assert conn.status == 201
      refute conn.resp_body =~ correct_id
    end
  end

  # ── ownership before the snapshot (R6) ─────────────────────────────────────────────────────

  describe "R6 ownership" do
    test "a non-owner of a snapshotless session gets exactly the 404 of a nonexistent session on every session route, never a 500 or 503" do
      %{tenant: tenant, content: content, session_id: session_id} =
        started!("gh2682-t20-owner", %{})

      Fx.force_field!(tenant.schema_name, "session", session_id, "exam_snapshot", :delete)
      stranger = candidate_ctx(tenant)
      random_id = Ecto.UUID.generate()

      routes = [
        {"GET", "", nil},
        {"PUT", "/answers/#{content.question_id}",
         %{"selected_option_ids" => [], "time_spent_seconds" => 0}},
        {"POST", "/submit", nil},
        {"POST", "/events", %{"type" => "tab_switch"}}
      ]

      for {method, suffix, body} <- routes do
        real = request(method, "#{@base}/#{session_id}#{suffix}", stranger, body)
        missing = request(method, "#{@base}/#{random_id}#{suffix}", stranger, body)

        assert {method, real.status} == {method, 404}

        assert {method, String.replace(real.resp_body, session_id, "<ID>")} ==
                 {method, String.replace(missing.resp_body, random_id, "<ID>")}
      end
    end
  end
end
