defmodule Letflow.Routers.PlatformModuleRolloutsTest do
  @moduledoc """
  RU-S6 / T-1594 (A2, N1, R1..R4): the HTTP surface of the fleet driver, `/platform-module-rollouts`,
  through the FULL `Letflow.Router` with real bearer tokens. Only the platform tenant's
  `PLATFORM_ADMIN` reaches it (permission `:ModuleRolloutsManage`, PLATFORM scope, INV-10). The
  domain behaviour (upgrade, halt, resume) is in `test/letflow/module_upgrade/fleet_test.exs`.
  `async: false` (VM-global platform tenant pin).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Platform.ModuleRollout.Outcome
  alias Letflow.Platform.ModuleRollout.Rollout
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  @base "/api/v1/platform-module-rollouts"
  @unused_uuid "00000000-0000-4000-8000-000000000001"

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    mine = [tenants.a.tenant_id, tenants.b.tenant_id, tenants.p.tenant_id]

    # The outcomes reference the tenants (no cascade): remove them before the fixture drops the tenants.
    on_exit(fn ->
      Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)

      rollout_ids =
        Repo.all(from(o in Outcome, where: o.tenant_id in ^mine, select: o.rollout_id))

      Repo.delete_all(from(o in Outcome, where: o.rollout_id in ^rollout_ids))
      Repo.delete_all(from(r in Rollout, where: r.id in ^rollout_ids))
    end)

    {:ok,
     Map.merge(tenants, %{
       op: Fixture.mint_token!(tenants.p, ["PLATFORM_ADMIN"]),
       a_admin: Fixture.mint_token!(tenants.a, ["TENANT_ADMIN"]),
       a_legacy_pa: Fixture.mint_token!(tenants.a, ["PLATFORM_ADMIN"])
     })}
  end

  defp call(method, path, token, slug, body \\ nil) do
    Fixture.api_conn(method, path, token, slug, body) |> Fixture.dispatch_api()
  end

  defp op(ctx, method, path, body \\ nil), do: call(method, path, ctx.op, ctx.p.tenant.slug, body)

  defp counts do
    {Repo.aggregate(Rollout, :count, :id), Repo.aggregate(Outcome, :count, :id)}
  end

  defp insert_rollout!(tenant_id, version \\ "9.9.9") do
    rollout =
      Repo.insert!(%Rollout{
        module_id: "t1594-" <> Ecto.UUID.generate(),
        to_version: version,
        status: "halted",
        halt_after: 3,
        consecutive_failures: 3,
        started_by: Ecto.UUID.generate(),
        started_at: ~N[2026-11-10 10:00:00],
        halted_at: ~N[2026-11-10 10:05:00]
      })

    Repo.insert!(%Outcome{
      rollout_id: rollout.id,
      tenant_id: tenant_id,
      status: "failed",
      error_code: "upgrade_needs_ack",
      plan_hash: String.duplicate("a", 64),
      attempted_at: ~N[2026-11-10 10:01:00],
      completed_at: ~N[2026-11-10 10:02:00]
    })

    rollout
  end

  describe "A2 / N1: who may call it (INV-10)" do
    test "the platform tenant's PLATFORM_ADMIN reaches every route; list is 200", ctx do
      assert op(ctx, :get, @base).status == 200
      assert op(ctx, :get, @base <> "/" <> @unused_uuid).status == 404
      assert op(ctx, :post, @base <> "/" <> @unused_uuid <> "/resume").status == 404
      assert op(ctx, :post, @base, %{"module_id" => "no_such_module"}).status == 404
    end

    test "a tenant admin, a PLATFORM_ADMIN of another tenant and a bare token get 403 on all four routes and an unmatched sub-path",
         ctx do
      mine = insert_rollout!(ctx.a.tenant_id)
      before = counts()

      for {token, slug} <- [
            {ctx.a_admin, ctx.a.tenant.slug},
            {ctx.a_legacy_pa, ctx.a.tenant.slug}
          ],
          {method, path, body} <- [
            {:post, @base, %{"module_id" => "stock"}},
            {:get, @base, nil},
            {:get, @base <> "/" <> mine.id, nil},
            {:post, @base <> "/" <> mine.id <> "/resume", nil},
            {:get, @base <> "/x/y/z", nil}
          ] do
        resp = call(method, path, token, slug, body)
        assert resp.status == 403, "#{method} #{path} answered #{resp.status}"
        refute resp.resp_body =~ mine.id
        refute resp.resp_body =~ "stock"
      end

      assert counts() == before
    end

    test "the platform operator token presented with another tenant's slug is rejected", ctx do
      resp = call(:get, @base, ctx.op, ctx.a.tenant.slug)
      assert resp.status in [401, 403]
    end
  end

  describe "R1..R4: read-only status and list" do
    test "R1 status returns exactly the pinned shape and no tenant or schema names", ctx do
      rollout = insert_rollout!(ctx.a.tenant_id)
      resp = op(ctx, :get, @base <> "/" <> rollout.id)
      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)

      assert Enum.sort(Map.keys(body)) == ["outcomes", "rollout"]

      assert Enum.sort(Map.keys(body["rollout"])) ==
               Enum.sort(~w(id module_id to_version status halt_after consecutive_failures
                            started_at completed_at halted_at))

      assert body["rollout"]["status"] == "halted"
      assert body["rollout"]["halted_at"] == "2026-11-10T10:05:00Z"

      assert [outcome] = body["outcomes"]

      assert Enum.sort(Map.keys(outcome)) ==
               Enum.sort(~w(tenant_id status error_code plan_hash attempted_at completed_at))

      assert outcome["tenant_id"] == ctx.a.tenant_id
      assert outcome["error_code"] == "upgrade_needs_ack"

      refute resp.resp_body =~ ctx.a.schema_name
      refute resp.resp_body =~ ctx.a.tenant.slug
    end

    test "R2 list is newest first with outcome counts", ctx do
      older = insert_rollout!(ctx.a.tenant_id)

      newer =
        Repo.insert!(%Rollout{
          module_id: "t1594-" <> Ecto.UUID.generate(),
          to_version: "9.9.10",
          status: "completed",
          halt_after: 3,
          started_by: Ecto.UUID.generate(),
          started_at: ~N[2026-11-11 10:00:00]
        })

      body = op(ctx, :get, @base).resp_body |> Jason.decode!()
      ids = Enum.map(body["rollouts"], & &1["rollout"]["id"])
      assert Enum.find_index(ids, &(&1 == newer.id)) < Enum.find_index(ids, &(&1 == older.id))

      entry = Enum.find(body["rollouts"], &(&1["rollout"]["id"] == older.id))
      assert entry["counts"] == %{"failed" => 1}
    end

    test "R3 a malformed and an unknown id are 404", ctx do
      assert op(ctx, :get, @base <> "/not-a-uuid").status == 404
      assert op(ctx, :get, @base <> "/" <> @unused_uuid).status == 404
      assert op(ctx, :post, @base <> "/not-a-uuid/resume").status == 404
    end

    test "R4 GET writes nothing", ctx do
      rollout = insert_rollout!(ctx.a.tenant_id)
      before = {counts(), Repo.get!(Rollout, rollout.id), Repo.all(Outcome)}
      assert op(ctx, :get, @base).status == 200
      assert op(ctx, :get, @base <> "/" <> rollout.id).status == 200
      assert {counts(), Repo.get!(Rollout, rollout.id), Repo.all(Outcome)} == before
    end
  end

  describe "start validation and a run with no installs" do
    test "a missing or empty module_id is a field error", ctx do
      before = counts()

      for body <- [%{}, %{"module_id" => ""}, %{"module_id" => 5}] do
        resp = op(ctx, :post, @base, body)
        assert resp.status in [400, 422]
        assert Jason.decode!(resp.resp_body)["status"] == resp.status
      end

      assert counts() == before
    end

    test "start for a module no fixture tenant has installed skips every tenant (not_installed)",
         ctx do
      resp = op(ctx, :post, @base, %{"module_id" => "stock"})
      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["rollout"]["module_id"] == "stock"
      assert body["rollout"]["status"] in ["running", "completed"]
      assert Enum.any?(body["outcomes"], &(&1["tenant_id"] == ctx.a.tenant_id))

      own = [ctx.a.tenant_id, ctx.b.tenant_id, ctx.p.tenant_id]
      mine = Enum.filter(body["outcomes"], &(&1["tenant_id"] in own))
      assert length(mine) == 3
      assert Enum.all?(mine, &(&1["status"] in ["skipped", "pending"]))
      assert Enum.all?(mine, &(&1["status"] == "pending" or &1["error_code"] == "not_installed"))

      # a repeat returns the same rollout
      again = op(ctx, :post, @base, %{"module_id" => "stock"}).resp_body |> Jason.decode!()
      assert again["rollout"]["id"] == body["rollout"]["id"]
    end
  end
end
