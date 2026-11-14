Code.require_file("documents_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.UpgradeFrom018Test do
  @moduledoc """
  REQ-825 criterion 5 (PM rule D-139): a tenant that holds assets 0.18.0 WITH real cards (legacy
  currency texts) takes the upgrade to 0.26.0 (C3 migration release task + C4 directory check,
  code only, pack byte-identical) through the real tenant routes, and the cards survive untouched:
  the migration itself is a separate operator run. Committed tenants, Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test
  import Ecto.Query, only: [from: 2]

  alias Letflow.AssetsFixture, as: Cards
  alias Letflow.AssetsRegisterFixture, as: S
  alias Letflow.Modules.ReadApi
  alias Letflow.Modules.TenantModule

  @old_hash String.duplicate("7", 64)

  setup do
    ctx = S.setup_oidc!([:a])
    schema = S.tenant!("req825u", ctx.names.a).schema_name

    {1, _} =
      Repo.update_all(
        from(m in TenantModule, where: m.module_id == "assets"),
        [set: [version: "0.18.0", manifest_hash: @old_hash]],
        prefix: schema
      )

    Map.merge(ctx, %{schema: schema, tok_a: S.token(ctx, :a, ["TENANT_ADMIN"])})
  end

  defp post(path, tok, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> tok)
    |> Letflow.Router.call(Letflow.Router.init([]))
  end

  test "U1 a tenant at 0.18.0 with real cards upgrades in place; the cards are untouched", ctx do
    legacy = Cards.card!(ctx.schema, "U-1", %{"currency" => " Тенге "}).record_id
    plain = Cards.card!(ctx.schema, "U-2", %{"currency" => "KZT"}).record_id

    {:ok, entry} = Letflow.Modules.Catalog.fetch("assets")
    assert entry.manifest().version == "0.26.0"

    plan = post("/api/v1/tenant/modules/assets/upgrade/plan", ctx.tok_a, %{})
    assert plan.status == 200, plan.resp_body
    report = Jason.decode!(plan.resp_body)
    assert report["from_version"] == "0.18.0"
    assert report["upgrade_path_available"] == true
    refute Enum.any?(report["entity_types"], &(&1["class"] in ["B", "C"]))

    up =
      post("/api/v1/tenant/modules/assets/upgrade", ctx.tok_a, %{
        "plan_hash" => report["plan_hash"],
        "rationale" => "T-1896 assets 0.18.0 upgrade"
      })

    assert up.status == 200, up.resp_body

    assert Repo.get_by!(TenantModule, [module_id: "assets"], prefix: ctx.schema).version ==
             "0.26.0"

    assert {:ok, %{"currency" => " Тенге "}} = ReadApi.lookup(ctx.schema, legacy, ["assets_card"])
    assert {:ok, %{"currency" => "KZT"}} = ReadApi.lookup(ctx.schema, plain, ["assets_card"])
  end
end
