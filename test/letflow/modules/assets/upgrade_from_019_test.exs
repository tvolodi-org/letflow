Code.require_file("documents_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.UpgradeFrom019Test do
  @moduledoc """
  REQ-826 criterion 5 (PM rule D-139): a tenant that holds assets 0.19.0 takes the upgrade to
  0.20.0 (C4: directory-based currency check, code only, pack byte-identical) through the real
  tenant routes. Cards survive untouched. `upgrade_path_available` is true because
  `min_upgradable_from` covers 0.19.0. Committed tenants, Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test
  import Ecto.Query, only: [from: 2]

  alias Letflow.AssetsFixture, as: Cards
  alias Letflow.AssetsRegisterFixture, as: S
  alias Letflow.Modules.ReadApi
  alias Letflow.Modules.TenantModule

  @old_hash String.duplicate("8", 64)

  setup do
    ctx = S.setup_oidc!([:a])
    schema = S.tenant!("req826u", ctx.names.a).schema_name

    {1, _} =
      Repo.update_all(
        from(m in TenantModule, where: m.module_id == "assets"),
        [set: [version: "0.19.0", manifest_hash: @old_hash]],
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

  test "U1 a tenant at 0.19.0 upgrades in place; cards are untouched; upgrade_path_available true",
       ctx do
    plain = Cards.card!(ctx.schema, "U19-1", %{"currency" => "KZT"}).record_id

    {:ok, entry} = Letflow.Modules.Catalog.fetch("assets")
    assert entry.manifest().version == "0.20.0"

    plan = post("/api/v1/tenant/modules/assets/upgrade/plan", ctx.tok_a, %{})
    assert plan.status == 200, plan.resp_body
    report = Jason.decode!(plan.resp_body)
    assert report["from_version"] == "0.19.0"
    assert report["upgrade_path_available"] == true
    refute Enum.any?(report["entity_types"], &(&1["class"] in ["B", "C"]))

    up =
      post("/api/v1/tenant/modules/assets/upgrade", ctx.tok_a, %{
        "plan_hash" => report["plan_hash"],
        "rationale" => "T-1897 assets 0.19.0 upgrade"
      })

    assert up.status == 200, up.resp_body

    assert Repo.get_by!(TenantModule, [module_id: "assets"], prefix: ctx.schema).version ==
             "0.20.0"

    assert {:ok, %{"currency" => "KZT"}} = ReadApi.lookup(ctx.schema, plain, ["assets_card"])
  end
end
