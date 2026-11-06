Code.require_file("../modules/stock/posting_fixture.exs", __DIR__)

defmodule Letflow.Routers.TenantModulesUpgradeTest do
  @moduledoc """
  REQ-770 / T-1396 (R1a, R1c, R1d, R1e, plus the body validation): the route and its refusals of
  `POST /api/v1/tenant/modules/:module_id/upgrade` through the full `Letflow.Router` with bearer
  tokens. Committed tenants, Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Api.Authorization
  alias Letflow.Modules.TenantModule
  alias Letflow.Repo
  alias Letflow.StockFixture, as: S
  alias Letflow.StockPostingFixture, as: P

  @hash String.duplicate("a", 64)

  setup do
    P.setup!([:a])
  end

  defp upgrade(tok, body, module \\ "stock") do
    Plug.Test.conn(:post, "/api/v1/tenant/modules/#{module}/upgrade", Jason.encode!(body))
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> tok)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Letflow.Router.call(Letflow.Router.init([]))
  end

  defp untraced(conn), do: conn.resp_body |> Jason.decode!() |> Map.delete("trace_id")

  defp written(schema) do
    %{rows: [[journal]]} =
      Repo.query!(~s|SELECT count(*) FROM "#{schema}".tenant_module_upgrades|)

    %{rows: [[audit]]} =
      Repo.query!(
        ~s|SELECT count(*) FROM "#{schema}".audit_entries WHERE action = 'module.upgrade'|
      )

    row = Repo.get_by!(TenantModule, [module_id: "stock"], prefix: schema)
    {journal, audit, row}
  end

  test "R1a the route is an authz_post gated by ModulesManage" do
    assert {"POST", "/:module_id/upgrade", :ModulesManage} in Letflow.Routers.TenantModules.__authz_routes__()

    assert Authorization.endpoint_policy_key("POST", "/tenant/modules/:module_id/upgrade") ==
             :ModulesManage
  end

  test "R1c a missing, blank or non-string rationale is a 422 and writes nothing", ctx do
    before = written(ctx.schema)

    for rationale <- [nil, "", "   ", 5] do
      conn = upgrade(ctx.tok_a, %{"plan_hash" => @hash, "rationale" => rationale})
      assert conn.status == 422
      assert conn.resp_body =~ "rationale is required"
    end

    assert upgrade(ctx.tok_a, %{"plan_hash" => @hash}).status == 422
    assert written(ctx.schema) == before
  end

  test "a missing or malformed plan_hash or a non-list ack is a 422", ctx do
    for hash <- [nil, "", "abc", String.upcase(@hash), 7] do
      conn = upgrade(ctx.tok_a, %{"plan_hash" => hash, "rationale" => "why"})
      assert conn.status == 422
      assert conn.resp_body =~ "plan_hash is required"
    end

    conn =
      upgrade(ctx.tok_a, %{"plan_hash" => @hash, "rationale" => "why", "ack_destructive" => "x"})

    assert conn.status == 422
    assert conn.resp_body =~ "ack_destructive must be a list"
  end

  test "R1d a caller without ModulesManage gets 403 and nothing is written", ctx do
    before = written(ctx.schema)
    worker = S.token(ctx, :a, ["TASK_WORKER"], sub: "worker-upg")

    assert upgrade(worker, %{"plan_hash" => @hash, "rationale" => "why"}).status == 403
    assert written(ctx.schema) == before
  end

  test "R1e unknown, not installed and uninstalled modules answer the same 404", ctx do
    unknown = upgrade(ctx.tok_a, %{"plan_hash" => @hash, "rationale" => "why"}, "no_such_module")
    assert unknown.status == 404

    not_installed =
      upgrade(ctx.tok_a, %{"plan_hash" => @hash, "rationale" => "why"}, "fixture_ledger")

    assert untraced(not_installed) == untraced(unknown)

    {1, _} =
      Repo.update_all(
        from(m in TenantModule, where: m.module_id == "stock"),
        [set: [status: :uninstalled]],
        prefix: ctx.schema
      )

    gone = upgrade(ctx.tok_a, %{"plan_hash" => @hash, "rationale" => "why"})
    assert untraced(gone) == untraced(unknown)
  end

  test "an up-to-date tenant answers 409 plan_mismatch and writes nothing", ctx do
    before = written(ctx.schema)
    conn = upgrade(ctx.tok_a, %{"plan_hash" => @hash, "rationale" => "why"})

    assert conn.status == 409
    assert %{"code" => "plan_mismatch"} = Jason.decode!(conn.resp_body)
    assert written(ctx.schema) == before
  end
end
