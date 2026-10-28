defmodule Letflow.Modules.Exam.ExamAnalyticsReportsTest do
  @moduledoc """
  REQ-594 part C (GH #3350, T-0751), tests R-summary, R-histogram, R-question, R-perm, R-tenant: the
  three BilimBaga exam reports (summary, score histogram, per-question correct rate) answered by the
  existing `POST /api/v1/entities/query/aggregate` route, through the full `Letflow.Router` with
  real API tokens. Rows are written directly (the writer is covered by A-write in
  `session_score_fields_test.exs` and `session_test.exs`).

  R-scope (criterion 9) is in `exam_analytics_reports_scope_test.exs`: it needs a scoped OIDC tenant.

  `async: false`: the exam fixtures switch the sandbox to `:auto`; R-tenant pins the platform tenant
  (VM-global application config).
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Letflow.ExamFixtures, as: Fx
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Support.PlatformTenantFixture, as: PT

  @aggregate "/api/v1/entities/query/aggregate"

  # ── helpers ────────────────────────────────────────────────────────────────────────────────

  defp tenant!(prefix) do
    %{tenant_id: tenant_id, schema_name: schema} =
      Fx.provisioned_tenant_with_exam_definitions(
        "#{prefix}-#{System.unique_integer([:positive])}"
      )

    %Tenant{slug: slug} = Repo.get(Tenant, tenant_id)
    %{tenant_id: tenant_id, schema: schema, slug: slug}
  end

  defp mint_token!(schema, roles) do
    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "req594-#{Ecto.UUID.generate()}",
        display_name: "REQ-594 Report Test User",
        email: "req594-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: schema)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: schema)

    plaintext
  end

  defp post(token, slug, body) do
    conn(:post, @aggregate, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("x-tenant-slug", slug)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp report(token, slug, body) do
    conn = post(token, slug, body)
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp ok_results!(token, slug, body) do
    assert {200, %{"results" => results}} = report(token, slug, body)
    results
  end

  defp flt(field, op, value), do: %{"field" => field, "op" => op, "value" => value}

  defp finished_filters(exam_id),
    do: [flt("exam_id", "eq", exam_id), flt("status", "in", ["submitted", "auto_submitted"])]

  defp summary_request(exam_id, extra_filters \\ []) do
    %{
      "entity_type" => "session",
      "filters" => finished_filters(exam_id) ++ extra_filters,
      "aggregates" => [%{"fn" => "count"}, %{"fn" => "avg", "field" => "score_pct"}]
    }
  end

  # bucket i of the histogram: [10i, 10(i+1)), the last one [90, 100]
  defp bucket_request(exam_id, i) do
    upper =
      if i == 9, do: flt("score_pct", "lte", 100), else: flt("score_pct", "lt", 10 * (i + 1))

    %{
      "entity_type" => "session",
      "filters" => finished_filters(exam_id) ++ [flt("score_pct", "gte", 10 * i), upper],
      "aggregates" => [%{"fn" => "count"}]
    }
  end

  defp question_request(exam_id, extra_filters \\ []) do
    %{
      "entity_type" => "session_question_score",
      "filters" =>
        [flt("exam_id", "eq", exam_id), flt("grading_status", "eq", "graded")] ++ extra_filters,
      "group_by" => [%{"field" => "question_id"}],
      "aggregates" => [%{"fn" => "count"}]
    }
  end

  defp count_of([]), do: 0
  defp count_of([%{"values" => %{"count_none" => n}}]), do: n

  defp counts_by_question(results),
    do: Map.new(results, &{&1["group"]["question_id"], &1["values"]["count_none"]})

  defp dec(%Decimal{} = d), do: d
  defp dec(n) when is_integer(n), do: Decimal.new(n)
  defp dec(n) when is_float(n), do: Decimal.from_float(n)
  defp dec(s) when is_binary(s), do: Decimal.new(s)

  defp session!(schema, exam_id, status, score, passed) do
    fields = %{
      "exam_id" => exam_id,
      "user_id" => Ecto.UUID.generate(),
      "status" => status,
      "seed" => 1,
      "started_at" => "2026-10-01T10:00:00",
      "expires_at" => "2026-10-01T11:00:00",
      "passed" => passed
    }

    fields = if score, do: Map.put(fields, "score_pct", score), else: fields
    Fx.create_record!(schema, "session", fields).record_id
  end

  defp score_row!(schema, session_id, question_id, exam_id, status, correct) do
    fields = %{
      "session_id" => session_id,
      "question_id" => question_id,
      "score" => if(correct, do: 1, else: 0),
      "max_score" => 1,
      "grading_status" => status,
      "exam_id" => exam_id
    }

    fields = if is_boolean(correct), do: Map.put(fields, "correct", correct), else: fields
    Fx.create_record!(schema, "session_question_score", fields)
  end

  # ── Report 1 ───────────────────────────────────────────────────────────────────────────────

  describe "R-summary" do
    test "finished sessions are counted, passed ones too, and the average ignores in_progress" do
      t = tenant!("r594-sum")
      token = mint_token!(t.schema, ["TENANT_ADMIN"])
      exam = Ecto.UUID.generate()

      session!(t.schema, exam, "submitted", 80, true)
      session!(t.schema, exam, "submitted", 60.5, true)
      session!(t.schema, exam, "submitted", 100, true)
      session!(t.schema, exam, "auto_submitted", 40, false)
      # would move the mean from 70.125 to 56.1 if it were counted
      session!(t.schema, exam, "in_progress", 0, false)

      [all] = ok_results!(token, t.slug, summary_request(exam))
      assert all["values"]["count_none"] == 4

      [passed] = ok_results!(token, t.slug, summary_request(exam, [flt("passed", "eq", true)]))
      assert passed["values"]["count_none"] == 3

      mean = Decimal.div(Decimal.new("280.5"), 4)
      assert Decimal.equal?(dec(all["values"]["avg_score_pct"]), mean)
    end
  end

  # ── Report 2 ───────────────────────────────────────────────────────────────────────────────

  describe "R-histogram" do
    test "ten ranges add up to the finished sessions and exactly 100 is in the last one" do
      t = tenant!("r594-his")
      token = mint_token!(t.schema, ["TENANT_ADMIN"])
      exam = Ecto.UUID.generate()

      for score <- [0, 9.99, 10, 55, 99.99, 100],
          do: session!(t.schema, exam, "submitted", score, true)

      # an unfinished session in the range of bucket 6 must not be counted
      session!(t.schema, exam, "in_progress", 55, false)

      counts =
        for i <- 0..9, do: count_of(ok_results!(token, t.slug, bucket_request(exam, i)))

      assert counts == [2, 1, 0, 0, 0, 1, 0, 0, 0, 2]
      assert Enum.sum(counts) == 6

      [all] = ok_results!(token, t.slug, summary_request(exam))
      assert Enum.sum(counts) == all["values"]["count_none"]
    end
  end

  # ── Report 3 ───────────────────────────────────────────────────────────────────────────────

  describe "R-question" do
    test "correct rate per question, pending_manual and another exam excluded" do
      t = tenant!("r594-qst")
      token = mint_token!(t.schema, ["TENANT_ADMIN"])
      exam = Ecto.UUID.generate()
      other_exam = Ecto.UUID.generate()
      qa = Ecto.UUID.generate()
      qb = Ecto.UUID.generate()

      for b_correct <- [true, false, false] do
        s = session!(t.schema, exam, "submitted", 50, true)
        score_row!(t.schema, s, qa, exam, "graded", true)
        score_row!(t.schema, s, qb, exam, "graded", b_correct)
      end

      # a manual question still waiting for a grader: carries the exam, no `correct`
      pending = session!(t.schema, exam, "grading_pending", nil, false)
      score_row!(t.schema, pending, qa, exam, "pending_manual", nil)

      # another exam, same question
      for _ <- 1..2 do
        s = session!(t.schema, other_exam, "submitted", 50, true)
        score_row!(t.schema, s, qa, other_exam, "graded", false)
      end

      total = counts_by_question(ok_results!(token, t.slug, question_request(exam)))
      right = ok_results!(token, t.slug, question_request(exam, [flt("correct", "eq", true)]))
      right = counts_by_question(right)

      assert total == %{qa => 3, qb => 3}
      assert right == %{qa => 3, qb => 1}
      assert {right[qa] / total[qa], right[qb] / total[qb]} == {1.0, 1 / 3}
    end
  end

  # ── Access ─────────────────────────────────────────────────────────────────────────────────

  describe "R-perm" do
    test "auditor and worker read the reports, candidate and agent runner do not" do
      t = tenant!("r594-prm")
      exam = Ecto.UUID.generate()
      session!(t.schema, exam, "submitted", 70, true)

      for role <- ["TENANT_AUDITOR", "TASK_WORKER"] do
        assert {200, %{"results" => [_]}} =
                 report(mint_token!(t.schema, [role]), t.slug, summary_request(exam))
      end

      for role <- ["CANDIDATE", "AGENT_RUNNER"] do
        assert {403, body} = report(mint_token!(t.schema, [role]), t.slug, summary_request(exam))
        refute Map.has_key?(body, "results")
      end
    end

    test "naming session.exam_snapshot as filter or group-by is refused with no data" do
      t = tenant!("r594-snp")
      exam = Ecto.UUID.generate()
      session!(t.schema, exam, "submitted", 70, true)

      filter = %{
        "entity_type" => "session",
        "aggregates" => [%{"fn" => "count"}],
        "filters" => [flt("exam_snapshot", "eq", "x")]
      }

      group = %{
        "entity_type" => "session",
        "aggregates" => [%{"fn" => "count"}],
        "group_by" => [%{"field" => "exam_snapshot"}]
      }

      for role <- ["TENANT_AUDITOR", "TASK_WORKER", "TENANT_ADMIN"], body <- [filter, group] do
        assert {^role, {403, decoded}} =
                 {role, report(mint_token!(t.schema, [role]), t.slug, body)}

        refute Map.has_key?(decoded, "results")
      end
    end
  end

  # ── Tenant isolation (INV-1, INV-10) ───────────────────────────────────────────────────────

  describe "R-tenant" do
    test "a TENANT_ADMIN sees only its own tenant, with the same exam id in both" do
      a = tenant!("r594-ta")
      b = tenant!("r594-tb")
      exam = Ecto.UUID.generate()
      qa = Ecto.UUID.generate()

      # tenant B holds finished sessions and score rows for the very same exam id
      for score <- [90, 95, 100] do
        s = session!(b.schema, exam, "submitted", score, true)
        score_row!(b.schema, s, qa, exam, "graded", true)
      end

      token_a = mint_token!(a.schema, ["TENANT_ADMIN"])

      # no tenant identifier anywhere in the three requests
      requests = [summary_request(exam), bucket_request(exam, 9), question_request(exam)]

      for body <- requests do
        refute Jason.encode!(body) =~ "tenant"
      end

      assert [%{"values" => %{"count_none" => 0}}] = ok_results!(token_a, a.slug, hd(requests))
      assert count_of(ok_results!(token_a, a.slug, Enum.at(requests, 1))) == 0
      assert [] = ok_results!(token_a, a.slug, Enum.at(requests, 2))

      # tenant A gets one session: its own number, never B's
      s = session!(a.schema, exam, "submitted", 30, true)
      score_row!(a.schema, s, qa, exam, "graded", false)

      [summary] = ok_results!(token_a, a.slug, hd(requests))
      assert summary["values"]["count_none"] == 1
      assert Decimal.equal?(dec(summary["values"]["avg_score_pct"]), 30)
      assert count_of(ok_results!(token_a, a.slug, Enum.at(requests, 1))) == 0

      assert [%{"values" => %{"count_none" => 1}}] =
               ok_results!(token_a, a.slug, Enum.at(requests, 2))

      # the same caller's token does not open tenant B
      token_b = mint_token!(b.schema, ["TENANT_ADMIN"])
      [b_summary] = ok_results!(token_b, b.slug, hd(requests))
      assert b_summary["values"]["count_none"] == 3
      assert {401, _} = report(token_a, b.slug, hd(requests))
    end

    test "a PLATFORM_ADMIN token sees its own tenant's data only" do
      a = tenant!("r594-pa")
      b = tenant!("r594-pb")
      exam = Ecto.UUID.generate()
      qa = Ecto.UUID.generate()

      for score <- [90, 95, 100] do
        s = session!(b.schema, exam, "submitted", score, true)
        score_row!(b.schema, s, qa, exam, "graded", true)
      end

      s = session!(a.schema, exam, "submitted", 30, true)
      score_row!(a.schema, s, qa, exam, "graded", false)

      # tenant A becomes the platform tenant FIRST: create_token/3 refuses PLATFORM_ADMIN elsewhere
      :ok = PT.pin!(a.tenant_id)
      token = PT.mint_token!(%{schema_name: a.schema}, ["PLATFORM_ADMIN"])

      run = fn slug, body ->
        PT.api_conn(:post, @aggregate, token, slug, body)
        |> PT.dispatch_api()
        |> then(&{&1.status, Jason.decode!(&1.resp_body)})
      end

      assert {200, %{"results" => [summary]}} = run.(a.slug, summary_request(exam))
      assert summary["values"]["count_none"] == 1
      assert Decimal.equal?(dec(summary["values"]["avg_score_pct"]), 30)

      assert {200, %{"results" => [%{"values" => %{"count_none" => 1}}]}} =
               run.(a.slug, question_request(exam))

      # the platform role is not a key to another tenant: the token is unknown in B's schema
      assert {401, body} = run.(b.slug, summary_request(exam))
      refute Map.has_key?(body, "results")
    end
  end
end
