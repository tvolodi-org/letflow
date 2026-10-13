defmodule Letflow.Api.PlatformAdminRoleBindingTest do
  @moduledoc """
  ISS-0993 / ISS-0994 design section 10 (hardening H1) and section 12 item 10(a), 10(g) (spec
  `test/specs/ISS-0993-A2.md`): binding the `PLATFORM_ADMIN` name to a group is a PLATFORM-scope
  action. Platform authority rests on that binding, so a role that holds `:RolesManage`
  (`PROCESS_DESIGNER`) must not be able to rebind it, in any tenant.

  `POST /identity/roles` (here dispatched to `Letflow.Routers.Identity` as `POST /roles`):

    * `PROCESS_DESIGNER` of an ordinary tenant (A) and of the platform tenant (P): 403 for the name
      `PLATFORM_ADMIN` and every variant, for BOTH kinds (`platform_role`, `process_routing_role`);
    * `TENANT_ADMIN` of an ordinary tenant (A): the same 403 (it has `:RolesManage` but not platform
      scope); a legacy `PLATFORM_ADMIN` of A holds nothing at all since REQ-447 PR 2 (403 as well);
    * `PLATFORM_ADMIN` of the platform tenant (P): unchanged success for the exact name as a
      `platform_role`; the variants are never accepted as a `platform_role` (the registry only knows
      the exact literal), see the last group of cases;
    * in every refused case no `tenant_role` row is written or changed and the 403 body names no role;
    * a name that is not a `PLATFORM_ADMIN` name stays allowed for `PROCESS_DESIGNER` (H1 does not
      over-block), and the platform tenant with no pin configured gives nobody platform scope.

  Unit level: `Letflow.Api.Authorization.platform_admin_name?/1` is pinned to
  `Authorization.roles_from_strings/1` (the parser that turns stored and token role strings into
  roles): for each of the six role literals they agree; any binary the parser maps to
  `:PLATFORM_ADMIN` is true; the defensive fold (trim, upper-case) catches case and whitespace
  variants; a non-binary is false.

  INV-10 check, enforced from the merge of Q-960 PR A. `async: false` (VM-global pin).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Api.Authorization
  alias Letflow.Identity.Group
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.TenantRole
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  # exact, lower case, mixed case, leading/trailing blanks, tab/newline padding
  @variants [
    "PLATFORM_ADMIN",
    "platform_admin",
    "Platform_Admin",
    " platform_admin ",
    " PLATFORM_ADMIN",
    "PLATFORM_ADMIN ",
    "\tPLATFORM_ADMIN\n",
    "\nplatform_admin\t"
  ]

  @kinds ["platform_role", "process_routing_role"]

  defp post_role(fixture, roles, body) do
    Letflow.Routers.Identity.call(
      Fixture.router_conn(:post, "/roles", fixture, roles, body),
      Letflow.Routers.Identity.init([])
    )
  end

  defp group!(fixture, name) do
    {:ok, %Group{} = group} =
      RoleRegistry.get_or_create_group_by_name(name, prefix: fixture.schema_name)

    group
  end

  defp role_rows(fixture) do
    TenantRole
    |> Repo.all(prefix: fixture.schema_name)
    |> Enum.map(&{&1.name, &1.kind, &1.group_id})
    |> Enum.sort()
  end

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, tenants}
  end

  describe "unit: Authorization.platform_admin_name?/1" do
    test "agrees with roles_from_strings/1 for each of the eight role literals" do
      for literal <-
            ~w(PLATFORM_ADMIN PROCESS_DESIGNER PROCESS_OPERATOR TASK_WORKER AGENT_RUNNER CANDIDATE TENANT_ADMIN TENANT_AUDITOR) do
        parser_says = :PLATFORM_ADMIN in Authorization.roles_from_strings([literal])

        assert Authorization.platform_admin_name?(literal) == parser_says,
               "#{literal}: predicate and parser disagree"
      end

      assert length(Authorization.roles()) == 8
    end

    test "any string the parser maps to :PLATFORM_ADMIN is a platform-admin name" do
      candidates =
        @variants ++ ["PROCESS_DESIGNER", "PLATFORM_ADMINS", "ADMIN", "platform admin", ""]

      for name <- candidates,
          :PLATFORM_ADMIN in Authorization.roles_from_strings([name]) do
        assert Authorization.platform_admin_name?(name), inspect(name)
      end

      # the parser really accepts at least the exact literal (the loop above is not vacuous)
      assert :PLATFORM_ADMIN in Authorization.roles_from_strings(["PLATFORM_ADMIN"])
    end

    test "the defensive fold catches case and whitespace variants even where the parser would not" do
      for name <- @variants, do: assert(Authorization.platform_admin_name?(name), inspect(name))
    end

    test "other names and non-binaries are false" do
      for name <- [
            "PROCESS_DESIGNER",
            "PLATFORM_ADMINS",
            "PLATFORM-ADMIN",
            "PLATFORM ADMIN",
            "ADMIN",
            "",
            "   ",
            "my-routing-role"
          ] do
        refute Authorization.platform_admin_name?(name), inspect(name)
      end

      for other <- [nil, :PLATFORM_ADMIN, 1, 1.5, %{}, ["PLATFORM_ADMIN"], {:ok}] do
        refute Authorization.platform_admin_name?(other), inspect(other)
      end
    end
  end

  describe "H1: a non-platform-scope caller cannot bind the PLATFORM_ADMIN name (403, no row)" do
    test "PROCESS_DESIGNER of A or P, exact name, either kind (item 10(a))", ctx do
      for fixture <- [ctx.a, ctx.p], kind <- @kinds do
        group = group!(fixture, "decoy-group")
        before = role_rows(fixture)

        resp =
          post_role(fixture, ["PROCESS_DESIGNER"], %{
            "name" => "PLATFORM_ADMIN",
            "kind" => kind,
            "group_id" => group.id
          })

        assert resp.status == 403, "#{kind}: #{resp.status} #{resp.resp_body}"
        assert role_rows(fixture) == before
        refute resp.resp_body =~ "PLATFORM_ADMIN"
      end
    end

    test "every name variant, both kinds, A TENANT_ADMIN / A legacy PLATFORM_ADMIN / A PROCESS_DESIGNER / P PROCESS_DESIGNER (item 10(g))",
         ctx do
      for {fixture, roles} <- [
            {ctx.a, ["PROCESS_DESIGNER"]},
            {ctx.a, ["TENANT_ADMIN"]},
            {ctx.a, ["PLATFORM_ADMIN"]},
            {ctx.p, ["PROCESS_DESIGNER"]}
          ],
          name <- @variants,
          kind <- @kinds do
        group = group!(fixture, "decoy-group")
        before = role_rows(fixture)

        resp =
          post_role(fixture, roles, %{"name" => name, "kind" => kind, "group_id" => group.id})

        assert resp.status == 403,
               "#{inspect(roles)} #{inspect(name)} #{kind}: #{resp.status} #{resp.resp_body}"

        assert role_rows(fixture) == before,
               "#{inspect(roles)} #{inspect(name)} #{kind}: a role row changed"

        refute resp.resp_body =~ ~r/platform.?admin/i
      end
    end

    test "the refusal is the same bytes for every caller, name and kind", ctx do
      group_a = group!(ctx.a, "decoy-group")
      group_p = group!(ctx.p, "decoy-group")

      bodies =
        for {fixture, group, roles} <- [
              {ctx.a, group_a, ["PROCESS_DESIGNER"]},
              {ctx.a, group_a, ["TENANT_ADMIN"]},
              {ctx.a, group_a, ["PLATFORM_ADMIN"]},
              {ctx.p, group_p, ["PROCESS_DESIGNER"]}
            ],
            name <- @variants,
            kind <- @kinds do
          resp =
            post_role(fixture, roles, %{"name" => name, "kind" => kind, "group_id" => group.id})

          resp.resp_body
        end

      assert length(Enum.uniq(bodies)) == 1
    end

    test "pin unset: the would-be operator (P PLATFORM_ADMIN) has no platform scope and is refused",
         ctx do
      Fixture.unpin!()
      group = group!(ctx.p, "PLATFORM_ADMIN")
      before = role_rows(ctx.p)

      resp =
        post_role(ctx.p, ["PLATFORM_ADMIN"], %{
          "name" => "PLATFORM_ADMIN",
          "kind" => "platform_role",
          "group_id" => group.id
        })

      assert resp.status == 403
      assert role_rows(ctx.p) == before
    end
  end

  describe "H1: the platform operator and unrelated names" do
    test "P PLATFORM_ADMIN rebinds the exact PLATFORM_ADMIN name as a platform_role (unchanged success)",
         ctx do
      group = group!(ctx.p, "operators-group")

      resp =
        post_role(ctx.p, ["PLATFORM_ADMIN"], %{
          "name" => "PLATFORM_ADMIN",
          "kind" => "platform_role",
          "group_id" => group.id
        })

      assert resp.status == 200, resp.resp_body
      assert Jason.decode!(resp.resp_body)["name"] == "PLATFORM_ADMIN"

      assert {"PLATFORM_ADMIN", :platform_role, group.id} in role_rows(ctx.p)
    end

    test "P PLATFORM_ADMIN: a name variant is never accepted as a platform_role (no row written)",
         ctx do
      group = group!(ctx.p, "operators-group")
      before = role_rows(ctx.p)

      for name <- @variants -- ["PLATFORM_ADMIN"] do
        resp =
          post_role(ctx.p, ["PLATFORM_ADMIN"], %{
            "name" => name,
            "kind" => "platform_role",
            "group_id" => group.id
          })

        assert resp.status in [403, 422], "#{inspect(name)}: #{resp.status}"
        refute resp.status == 200
      end

      assert role_rows(ctx.p) == before
    end

    test "a PROCESS_DESIGNER may still bind an ordinary routing role (H1 does not over-block)",
         ctx do
      for fixture <- [ctx.a, ctx.p] do
        group = group!(fixture, "routing-group")

        resp =
          post_role(fixture, ["PROCESS_DESIGNER"], %{
            "name" => "iss0993-routing-role",
            "kind" => "process_routing_role",
            "group_id" => group.id
          })

        assert resp.status == 200, resp.resp_body
        assert {"iss0993-routing-role", :process_routing_role, group.id} in role_rows(fixture)
      end
    end

    test "a role that is not PROCESS_DESIGNER or PLATFORM_ADMIN still gets 403 for any name",
         ctx do
      group = group!(ctx.a, "decoy-group")

      resp =
        post_role(ctx.a, ["TASK_WORKER"], %{
          "name" => "iss0993-routing-role",
          "kind" => "process_routing_role",
          "group_id" => group.id
        })

      assert resp.status == 403
    end
  end
end
