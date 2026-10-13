defmodule Letflow.Routers.IdentityRolesGuardTest do
  @moduledoc """
  REQ-447 PR 1, H2 (`lib/letflow/design/req447-tenant-admin-role.md` section 3.6; spec
  `test/specs/REQ-447-PR1.md` PART C): `POST /roles` binds a role NAME to a group, and
  `RoleRegistry.upsert_role/4` overwrites `kind` and `group_id` on a name conflict. Binding ANY built-in
  role name (all eight of `Authorization.roles/0`, either `kind`, after the same trim + upcase fold as
  H1) therefore needs `:UsersGroupsRolesManage` in the caller's tenant, decided BEFORE `upsert_role/4`;
  `:RolesManage` alone (`PROCESS_DESIGNER`) only covers a `process_routing_role` whose name is not a
  built-in name. H1 stays stricter for `PLATFORM_ADMIN` (recomputed platform scope).

    * `PROCESS_DESIGNER` (ordinary tenant A and platform tenant P): 403 for EVERY built-in name, both
      kinds, case and whitespace variants, binding rows unchanged; the TENANT_ADMIN name with kind
      `process_routing_role` is the kind-overwrite case (403 and the existing `platform_role` binding
      keeps its kind and group); an ordinary routing role is still 2xx (no over-block).
    * `TENANT_ADMIN` (A and P): may bind the built-in platform roles other than `PLATFORM_ADMIN`
      (2xx), never `PLATFORM_ADMIN` (403, also on P where it has no platform scope).
    * Legacy tenant `PLATFORM_ADMIN` of A (REQ-447 PR 2, C6 removed): holds nothing, 403 for every name
      and kind. The platform operator may bind everything.

  `async: false`: the platform tenant pin is VM-global.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Identity.Group
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.TenantRole
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  @builtin ~w(PLATFORM_ADMIN PROCESS_DESIGNER PROCESS_OPERATOR TASK_WORKER AGENT_RUNNER CANDIDATE TENANT_ADMIN)
  @non_platform_admin @builtin -- ["PLATFORM_ADMIN"]
  @kinds ["platform_role", "process_routing_role"]

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, tenants}
  end

  defp post_role(fixture, roles, body) do
    Letflow.Routers.Identity.call(
      Fixture.router_conn(:post, "/roles", fixture, roles, body),
      Letflow.Routers.Identity.init([])
    )
  end

  defp group!(fixture) do
    %Group{}
    |> Ecto.Changeset.change(%{name: "h2-g-#{System.unique_integer([:positive])}"})
    |> Repo.insert!(prefix: fixture.schema_name)
  end

  defp bind!(fixture, name, kind, group) do
    {:ok, _} = RoleRegistry.upsert_role(name, kind, group.id, prefix: fixture.schema_name)
    :ok
  end

  defp role_rows(fixture) do
    TenantRole
    |> Repo.all(prefix: fixture.schema_name)
    |> Enum.map(&{&1.name, &1.kind, &1.group_id})
    |> Enum.sort()
  end

  defp variants(name), do: [name, String.downcase(name), " " <> name <> " ", "\t" <> name <> "\n"]

  defp body(name, kind, group), do: %{"name" => name, "kind" => kind, "group_id" => group.id}

  describe "H2: PROCESS_DESIGNER cannot bind a built-in role name" do
    test "every built-in name, both kinds, case and whitespace variants, in A and in P: 403, no row changes",
         ctx do
      for fixture <- [ctx.a, ctx.p] do
        group = group!(fixture)
        # pre-existing bindings, so an overwrite (not just an insert) would be visible
        for name <- @non_platform_admin, do: bind!(fixture, name, :platform_role, group!(fixture))
        before = role_rows(fixture)

        for name <- @builtin, variant <- variants(name), kind <- @kinds do
          conn = post_role(fixture, ["PROCESS_DESIGNER"], body(variant, kind, group))

          assert conn.status == 403,
                 "#{inspect(variant)} #{kind}: #{conn.status} #{conn.resp_body}"

          assert Jason.decode!(conn.resp_body)["detail"] =~ "insufficient permissions"
          refute conn.resp_body =~ ~r/tenant.?admin|platform.?admin|process.?designer/i
          assert role_rows(fixture) == before, "#{inspect(variant)} #{kind}: a role row changed"
        end
      end
    end

    test "the TENANT_ADMIN name with kind process_routing_role is refused BEFORE upsert_role: the platform_role binding keeps its kind and group (kind-overwrite case)",
         ctx do
      for fixture <- [ctx.a, ctx.p] do
        legit = group!(fixture)
        attacker = group!(fixture)
        bind!(fixture, "TENANT_ADMIN", :platform_role, legit)
        before = role_rows(fixture)
        assert {"TENANT_ADMIN", :platform_role, legit.id} in before

        conn =
          post_role(
            fixture,
            ["PROCESS_DESIGNER"],
            body("TENANT_ADMIN", "process_routing_role", attacker)
          )

        assert conn.status == 403, conn.resp_body
        assert role_rows(fixture) == before
      end
    end

    test "CONTROL: the kind overwrite is real (a holder of :UsersGroupsRolesManage converts the binding), so the 403 above is what protects it",
         ctx do
      legit = group!(ctx.a)
      other = group!(ctx.a)
      bind!(ctx.a, "TENANT_ADMIN", :platform_role, legit)

      conn =
        post_role(ctx.a, ["TENANT_ADMIN"], body("TENANT_ADMIN", "process_routing_role", other))

      assert conn.status == 200, conn.resp_body
      assert {"TENANT_ADMIN", :process_routing_role, other.id} in role_rows(ctx.a)
    end

    test "a PROCESS_DESIGNER still gets 2xx for an ordinary routing role, including names that merely contain a built-in name",
         ctx do
      for fixture <- [ctx.a, ctx.p],
          name <- ["h2-routing-role", "TENANT_ADMINS", "TASK_WORKER_2", "my TENANT_ADMIN"] do
        group = group!(fixture)
        conn = post_role(fixture, ["PROCESS_DESIGNER"], body(name, "process_routing_role", group))

        assert conn.status == 200, "#{inspect(name)}: #{conn.status} #{conn.resp_body}"
        assert {name, :process_routing_role, group.id} in role_rows(fixture)
      end
    end
  end

  describe "H2: who may bind built-in names" do
    test "TENANT_ADMIN of A and of P binds the built-in names other than PLATFORM_ADMIN (platform_role) and refuses PLATFORM_ADMIN",
         ctx do
      for fixture <- [ctx.a, ctx.p] do
        for name <- @non_platform_admin do
          group = group!(fixture)
          conn = post_role(fixture, ["TENANT_ADMIN"], body(name, "platform_role", group))

          assert conn.status == 200, "#{name}: #{conn.status} #{conn.resp_body}"
          assert {name, :platform_role, group.id} in role_rows(fixture)
        end

        group = group!(fixture)
        before = role_rows(fixture)

        for variant <- variants("PLATFORM_ADMIN"), kind <- @kinds do
          conn = post_role(fixture, ["TENANT_ADMIN"], body(variant, kind, group))
          assert conn.status == 403, "#{inspect(variant)} #{kind}: #{conn.status}"
          assert role_rows(fixture) == before
        end
      end
    end

    test "a legacy tenant PLATFORM_ADMIN of A (own-tenant power removed, REQ-447 PR 2) is refused for every built-in name",
         ctx do
      group = group!(ctx.a)
      before = role_rows(ctx.a)

      for name <- @builtin, kind <- @kinds do
        conn = post_role(ctx.a, ["PLATFORM_ADMIN"], body(name, kind, group))
        assert conn.status == 403, "#{name} #{kind}: #{conn.status} #{conn.resp_body}"
        assert role_rows(ctx.a) == before, "#{name} #{kind}: a role row changed"
      end
    end

    test "CONTROL: the platform operator binds TENANT_ADMIN and PLATFORM_ADMIN in P", ctx do
      for name <- ["TENANT_ADMIN", "PLATFORM_ADMIN"] do
        group = group!(ctx.p)
        conn = post_role(ctx.p, ["PLATFORM_ADMIN"], body(name, "platform_role", group))
        assert conn.status == 200, "#{name}: #{conn.status} #{conn.resp_body}"
        assert {name, :platform_role, group.id} in role_rows(ctx.p)
      end
    end

    test "a role without :RolesManage (TASK_WORKER) is still refused by the permission gate for any name",
         ctx do
      group = group!(ctx.a)
      before = role_rows(ctx.a)

      for name <- ["h2-routing-role", "TENANT_ADMIN"] do
        conn = post_role(ctx.a, ["TASK_WORKER"], body(name, "process_routing_role", group))
        assert conn.status == 403
      end

      assert role_rows(ctx.a) == before
    end
  end
end
