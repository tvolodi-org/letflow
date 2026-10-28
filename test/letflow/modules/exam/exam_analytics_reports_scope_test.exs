defmodule Letflow.Modules.Exam.ExamAnalyticsReportsScopeTest do
  @moduledoc """
  REQ-594 part C (GH #3350, T-0751), test R-scope (criterion 9): a caller whose REQ-518 scope does not
  declare `session` or `session_question_score` gets an EMPTY result from the report requests, not an
  error. The user holds TENANT_ADMIN only at the subtree `a` of a `fixture_scoped` OIDC tenant (the set
  up of `entities_scope_http_test.exs`); the exam definitions are added to that tenant, and the exam
  manifest declares no `scope_declarations`, so both types are undeclared.

  The control that makes the emptiness mean something: under scope enforcement `off` the same user
  sends the same requests and gets the real counts.

  `async: false`: dedicated provisioned OIDC tenant (sandbox `:auto`), the VM-global `:oidc` config swap.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Letflow.ExamFixtures, as: Fx
  alias Letflow.Oidc.ConfigurableTokenVerifierDouble
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopeEnforcementFixture
  alias Letflow.Support.ScopeSetFixture, as: F
  alias Letflow.Support.TokenMintFixture

  @aggregate "/api/v1/entities/query/aggregate"
  @exam "11111111-1111-4111-8111-111111111111"

  setup do
    original = Application.fetch_env!(:letflow, :oidc)

    Application.put_env(
      :letflow,
      :oidc,
      Keyword.put(original, :token_verifier, ConfigurableTokenVerifierDouble)
    )

    on_exit(fn -> Application.put_env(:letflow, :oidc, original) end)

    realm = Letflow.TenantSlugFixture.unique_realm("r594-scope")
    fx = F.provision!("r594-scope", oidc_mode: :enabled, idp_realm_id: realm)
    fx = Map.put(fx, :realm, realm)
    schema = fx.schema_name

    :ok = Fx.activate_exam_definitions!(schema)

    session =
      Fx.create_record!(schema, "session", %{
        "exam_id" => @exam,
        "user_id" => "u-1",
        "status" => "submitted",
        "seed" => 1,
        "started_at" => "2026-10-01T10:00:00",
        "expires_at" => "2026-10-01T11:00:00",
        "passed" => true,
        "score_pct" => 70
      })

    Fx.create_record!(schema, "session_question_score", %{
      "session_id" => session.record_id,
      "question_id" => "q-1",
      "score" => 1,
      "max_score" => 1,
      "grading_status" => "graded",
      "exam_id" => @exam,
      "correct" => true
    })

    first = request(fx, %{"entity_type" => "session", "aggregates" => [%{"fn" => "count"}]})
    assert first.status in [200, 403]
    user_id = first.assigns.auth_context.user_id
    TokenMintFixture.grant_roles!(schema, user_id, ["TENANT_ADMIN"])
    group = RSG.group_of!(schema, "TENANT_ADMIN")
    _removed = RSG.raw_delete_rows!(schema, group, "TENANT_ADMIN")
    :ok = RSG.raw_user_row!(schema, user_id, "TENANT_ADMIN", F.nodes().a)

    {:ok, fx: fx}
  end

  defp request(fx, body) do
    conn(:post, @aggregate, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer realm-token:" <> fx.realm)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp summary,
    do: %{
      "entity_type" => "session",
      "filters" => [
        %{"field" => "exam_id", "op" => "eq", "value" => @exam},
        %{"field" => "status", "op" => "in", "value" => ["submitted", "auto_submitted"]}
      ],
      "aggregates" => [%{"fn" => "count"}, %{"fn" => "avg", "field" => "score_pct"}]
    }

  defp per_question,
    do: %{
      "entity_type" => "session_question_score",
      "filters" => [
        %{"field" => "exam_id", "op" => "eq", "value" => @exam},
        %{"field" => "grading_status", "op" => "eq", "value" => "graded"}
      ],
      "group_by" => [%{"field" => "question_id"}],
      "aggregates" => [%{"fn" => "count"}]
    }

  defp results(conn) do
    assert conn.status == 200, conn.resp_body
    Jason.decode!(conn.resp_body)["results"]
  end

  defp count_of([]), do: 0
  defp count_of([%{"values" => %{"count_none" => n}}]), do: n

  test "R-scope: undeclared session types answer empty under scope enforcement, full without it",
       %{
         fx: fx
       } do
    # control: unscoped (enforcement off) the same user sees the data
    ScopeEnforcementFixture.set_stored_mode!(fx.tenant_id, :off)
    assert count_of(results(request(fx, summary()))) == 1
    assert [%{"values" => %{"count_none" => 1}}] = results(request(fx, per_question()))

    # scoped: empty, 200, no error
    ScopeEnforcementFixture.set_stored_mode!(fx.tenant_id, :on)
    assert count_of(results(request(fx, summary()))) == 0
    assert [] = results(request(fx, per_question()))
  end
end
