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

  alias Letflow.Api.Pagination
  alias Letflow.EventStore.PlatformEvents
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

  # Outcome-less rollout at a given start; deleted by id in its own on_exit.
  defp insert_rollout_at!(started_at) do
    rollout =
      Repo.insert!(%Rollout{
        module_id: "req813-" <> Ecto.UUID.generate(),
        to_version: "9.9.9",
        status: "completed",
        halt_after: 3,
        started_by: Ecto.UUID.generate(),
        started_at: started_at
      })

    on_exit(fn ->
      Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)
      Repo.delete_all(from(r in Rollout, where: r.id == ^rollout.id))
    end)

    rollout
  end

  defp get_json(ctx, query) do
    resp = op(ctx, :get, @base <> query)
    {resp.status, Jason.decode!(resp.resp_body)}
  end

  # Leaked rows of other suites would break exact page counts: start from an empty table.
  defp isolate_rollouts! do
    Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo)
    Repo.delete_all(Outcome)
    Repo.delete_all(Rollout)
  end

  defp seed_at!(n, base \\ ~N[2031-02-01 00:00:00]) do
    for i <- 1..n, do: insert_rollout_at!(NaiveDateTime.add(base, div(i, 2) * 60))
  end

  defp raw_cursor(prefix, mint_us, tail) do
    Pagination.encode_cursor("#{prefix}#{mint_us}:#{tail}")
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

  describe "REQ-813: cursor paging of the list" do
    test "P1 pages of 2,2,1 cover every seeded rollout once, in list order", ctx do
      isolate_rollouts!()
      ids = Enum.map(seed_at!(5), & &1.id)

      {200, p1} = get_json(ctx, "?page_size=2")
      {200, p2} = get_json(ctx, "?page_size=2&cursor=" <> p1["next_cursor"])
      {200, p3} = get_json(ctx, "?page_size=2&cursor=" <> p2["next_cursor"])
      assert Enum.map([p1, p2, p3], &length(&1["rollouts"])) == [2, 2, 1]
      assert is_binary(p1["next_cursor"]) and is_binary(p2["next_cursor"])
      assert p3["next_cursor"] == nil

      all = Enum.flat_map([p1, p2, p3], & &1["rollouts"]) |> Enum.map(& &1["rollout"]["id"])
      assert Enum.sort(all) == Enum.sort(ids)

      {200, full} = get_json(ctx, "?page_size=200")
      assert Enum.map(full["rollouts"], & &1["rollout"]["id"]) == all
      assert full["next_cursor"] == nil
    end

    test "P2 exactly page_size rows: last page has a nil next_cursor", ctx do
      isolate_rollouts!()
      seed_at!(4)
      {4, _} = counts()

      {200, p1} = get_json(ctx, "?page_size=2")
      assert length(p1["rollouts"]) == 2
      assert is_binary(p1["next_cursor"])
      {200, p2} = get_json(ctx, "?page_size=2&cursor=" <> p1["next_cursor"])
      assert length(p2["rollouts"]) == 2
      assert p2["next_cursor"] == nil

      {200, whole} = get_json(ctx, "?page_size=4")
      assert length(whole["rollouts"]) == 4
      assert whole["next_cursor"] == nil
    end

    test "P3 default page is 50 with the old item shape", ctx do
      seed_at!(51)
      {200, body} = get_json(ctx, "")
      assert Enum.sort(Map.keys(body)) == ["next_cursor", "rollouts"]
      assert length(body["rollouts"]) == 50
      assert is_binary(body["next_cursor"])
      assert Enum.all?(body["rollouts"], &(Enum.sort(Map.keys(&1)) == ["counts", "rollout"]))
      started = Enum.map(body["rollouts"], & &1["rollout"]["started_at"])
      assert started == Enum.sort(started, :desc)
    end

    test "P4 bad page_size and bad cursors are 400 with the precedent messages", ctx do
      assert {400, %{"detail" => "invalid page_size"}} = get_json(ctx, "?page_size=abc")
      assert {400, %{"detail" => "page_size out of range"}} = get_json(ctx, "?page_size=0")
      assert {400, %{"detail" => "page_size out of range"}} = get_json(ctx, "?page_size=201")
      assert {400, %{"detail" => "invalid cursor"}} = get_json(ctx, "?cursor=not-a-cursor")

      now = System.os_time(:microsecond)
      uuid = Ecto.UUID.generate()
      old = now - Pagination.cursor_expiry_us() - 1_000_000

      for c <- [
            raw_cursor("RO:", old, "1:#{uuid}"),
            raw_cursor("RO:", now, "abc"),
            raw_cursor("RO:", now, "1:not-a-uuid"),
            raw_cursor("RO:", now, "9223372036854775807:#{uuid}")
          ] do
        assert {400, %{"detail" => "invalid cursor"}} = get_json(ctx, "?cursor=" <> c)
      end
    end

    test "P4 a real platform-events cursor is refused", ctx do
      for _ <- 1..2 do
        {:ok, _} =
          PlatformEvents.append_definition_promoted(
            %{
              event_type: "DEFINITION_PROMOTED",
              actor_id: Ecto.UUID.generate(),
              review_id: Ecto.UUID.generate(),
              source_tenant_id: ctx.a.tenant_id,
              target_tenant_id: ctx.b.tenant_id,
              source_definition_id: Ecto.UUID.generate(),
              target_definition_id: Ecto.UUID.generate(),
              process_key: "req813-" <> Ecto.UUID.generate()
            },
            ctx.p.schema_name
          )
      end

      resp =
        Letflow.Routers.Promotions.call(
          Fixture.router_conn(
            :get,
            "/platform-events?page_size=1",
            ctx.p,
            ["PLATFORM_ADMIN"],
            nil
          ),
          Letflow.Routers.Promotions.init([])
        )

      assert resp.status == 200
      pe = Jason.decode!(resp.resp_body)["next_cursor"]
      assert is_binary(pe)
      assert {400, %{"detail" => "invalid cursor"}} = get_json(ctx, "?cursor=" <> pe)
    end

    test "P6 a tenant admin with a valid cursor still gets the bare 403", ctx do
      seed_at!(3)
      {200, p1} = get_json(ctx, "?page_size=1")
      bare = call(:get, @base, ctx.a_admin, ctx.a.tenant.slug)

      resp =
        call(
          :get,
          @base <> "?page_size=2&cursor=" <> p1["next_cursor"],
          ctx.a_admin,
          ctx.a.tenant.slug
        )

      assert resp.status == 403

      assert Map.delete(Jason.decode!(resp.resp_body), "trace_id") ==
               Map.delete(Jason.decode!(bare.resp_body), "trace_id")
    end

    test "R4b a paged read writes nothing", ctx do
      seed_at!(2)
      before = {counts(), Repo.all(Rollout), Repo.all(Outcome)}
      {200, p1} = get_json(ctx, "?page_size=1")
      assert is_binary(p1["next_cursor"])
      {200, _} = get_json(ctx, "?page_size=1&cursor=" <> p1["next_cursor"])
      assert {counts(), Repo.all(Rollout), Repo.all(Outcome)} == before
    end
  end
end
