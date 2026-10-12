defmodule Letflow.Engine.Req465MeridianRegulatoryDistinctFromTest do
  @moduledoc """
  REQ-465 (regulatory half) -- the shipped Meridian "Regulatory Compliance Review" fixture (v1.10)
  adopts `distinct_from` (REQ-459 rule A, enforced by REQ-463) on its sign-off nodes:
  `findings-sign-off` (role-cro) names `evidence-collection`, `risk-evaluation` and
  `remediation-subprocess`, so the person who collected the evidence, rated the risk or remediated
  the findings does not also sign the findings off.

  Refusals are asserted on the HTTP surface (`Letflow.Routers.Tasks.call/2`): 403
  `application/problem+json`, body exactly `{"detail":"separation of duties","status":403}`, the
  task still open, every instance row byte-for-byte unchanged. Accepted completions are 200.
  Real Postgres via `Letflow.SodSupport`; no mocks.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Letflow.Definitions
  alias Letflow.Req462Adoption, as: A
  alias Letflow.SodSupport, as: S

  @opts Letflow.Routers.Tasks.init([])
  @sod_body ~s({"detail":"separation of duties","status":403})
  @fixture Path.expand(
             "../../fixtures/qa/meridian_regulatory_compliance_review_process_definition.json",
             __DIR__
           )

  # -- fixtures -----------------------------------------------------------------------------

  defp definition_doc, do: @fixture |> File.read!() |> Jason.decode!()

  defp schemas(doc),
    do: Map.new(doc["variable_schemas"], &{&1["variable_key"], &1["json_schema"]})

  defp case! do
    doc = definition_doc()
    S.new_case!(doc["graph"], schemas(doc), %{"review_id" => "rev-465"})
  end

  defp current_nodes(ctx), do: A.projection(ctx.schema_name, ctx.instance_id).current_nodes

  # -- HTTP ----------------------------------------------------------------------------------

  # POST /tasks/:id/complete as `user`; the request body is the output variables.
  defp complete_http(ctx, user, node_id, output) do
    task = S.pending_task!(ctx, node_id)

    conn(:post, "/#{task.id}/complete")
    |> Map.put(:body_params, output)
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{user_id: user.id, tenant_id: ctx.tenant_id, roles: ["TASK_WORKER"]})
    |> assign(:trace_id, "req465-trace")
    |> then(&Letflow.Routers.Tasks.call(&1, @opts))
  end

  defp assert_accepted!(conn),
    do: assert(conn.status == 200, "expected 200, got #{conn.status}: #{conn.resp_body}")

  defp assert_separation!(conn) do
    assert conn.status == 403, "expected 403, got #{conn.status}: #{conn.resp_body}"
    assert [content_type] = get_resp_header(conn, "content-type")
    assert String.starts_with?(content_type, "application/problem+json")
    assert conn.resp_body == @sod_body
  end

  # -- findings-sign-off --------------------------------------------------------------------

  test "findings-sign-off: the user who completed evidence-collection is refused (403, fixed body), nothing changes; a different CRO completes it" do
    ctx = case!()
    a = S.insert_user!(ctx.schema_name, "a")
    b = S.insert_user!(ctx.schema_name, "b")
    c = S.insert_user!(ctx.schema_name, "c")
    S.grant_role!(ctx.schema_name, "role-compliance-officer", [a.id])
    S.grant_role!(ctx.schema_name, "role-cro", [a.id, c.id])
    S.grant_role!(ctx.schema_name, "role-risk-manager", [b.id])

    S.complete_node!(ctx, "evidence-collection", a.id, %{"evidence_summary" => "files gathered"})
    S.complete_node!(ctx, "risk-evaluation", b.id, %{"highest_severity" => "low"})
    assert current_nodes(ctx) == ["findings-sign-off"]

    signoff = S.pending_task!(ctx, "findings-sign-off")
    before = S.rows(ctx)

    assert_separation!(
      complete_http(ctx, a, "findings-sign-off", %{"cro_decision" => "sign_off"})
    )

    assert S.rows(ctx) == before
    assert S.reload_task!(ctx, signoff).status == :pending

    assert_accepted!(complete_http(ctx, c, "findings-sign-off", %{"cro_decision" => "sign_off"}))
    assert current_nodes(ctx) == ["archive-review"]
  end

  test "findings-sign-off: the user who completed risk-evaluation and also holds role-cro is refused (403, fixed body), nothing changes; a different CRO completes it" do
    ctx = case!()
    a = S.insert_user!(ctx.schema_name, "a")
    b = S.insert_user!(ctx.schema_name, "b")
    c = S.insert_user!(ctx.schema_name, "c")
    S.grant_role!(ctx.schema_name, "role-compliance-officer", [a.id])
    S.grant_role!(ctx.schema_name, "role-risk-manager", [b.id])
    S.grant_role!(ctx.schema_name, "role-cro", [b.id, c.id])

    S.complete_node!(ctx, "evidence-collection", a.id, %{"evidence_summary" => "files gathered"})
    S.complete_node!(ctx, "risk-evaluation", b.id, %{"highest_severity" => "low"})
    assert current_nodes(ctx) == ["findings-sign-off"]

    before = S.rows(ctx)

    assert_separation!(
      complete_http(ctx, b, "findings-sign-off", %{"cro_decision" => "sign_off"})
    )

    assert S.rows(ctx) == before

    assert_accepted!(complete_http(ctx, c, "findings-sign-off", %{"cro_decision" => "sign_off"}))
    assert current_nodes(ctx) == ["archive-review"]
  end

  # -- REQ-464 validator on the live, activated definition -----------------------------------

  test "the REQ-464 validator (the function POST /definitions/:id/validate calls) reports the activated regulatory definition valid, with no single-member warning" do
    ctx = case!()

    assert {:ok, %{valid: true, violations: [], warnings: warnings}} =
             Definitions.validate_definition_graph(ctx.definition.id, prefix: ctx.schema_name)

    refute Enum.any?(
             warnings,
             &(is_binary(&1) and String.starts_with?(&1, "distinct_from_single_member_role:"))
           )
  end
end
