defmodule Letflow.Routers.IdentityRoleRebindTest do
  @moduledoc """
  GH 2524 (`lib/letflow/design/gh2524-role-rebind-explicit.md`): `POST /roles` no longer moves an
  existing role binding to another group; moving one is the explicit, audited
  `POST /roles/:id/rebind` for the tenant admin permission, with a mandatory reason.

    * create stays (200);
    * same name, same group: idempotent, nothing written, no audit entry;
    * same name, different group: 409 `role_already_bound`, nothing changes, the body names no group;
    * rebind: TENANT_ADMIN 200, group moved, one `role.rebound` entry (actor, old/new group, reason,
      UTC timestamp); same-group rebind is a no-op without audit;
    * PROCESS_DESIGNER (and the other non-admin roles) 403 on the rebind, nothing changes;
    * id/group/reason validation (404 / 422, one code each, never echoing the value);
    * H1 on the rebind: the PLATFORM_ADMIN binding needs platform scope;
    * the platform-role seed keeps a rebound binding and fails closed on a routing row with a
      seedable name.

  `async: false`: the platform tenant pin is VM-global.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.Identity.Group
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.TenantRole
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  @admin ["TENANT_ADMIN"]
  @designer ["PROCESS_DESIGNER"]
  @operator ["PLATFORM_ADMIN"]

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, tenants}
  end

  # --- helpers ------------------------------------------------------------------------------------

  defp call(method, path, fixture, roles, body) do
    Letflow.Routers.Identity.call(
      Fixture.router_conn(method, path, fixture, roles, body),
      Letflow.Routers.Identity.init([])
    )
  end

  defp group!(fixture) do
    %Group{}
    |> Ecto.Changeset.change(%{name: "gh2524-g-#{System.unique_integer([:positive])}"})
    |> Repo.insert!(prefix: fixture.schema_name)
  end

  defp routing_role!(fixture, group) do
    name = "gh2524-approver-#{System.unique_integer([:positive])}"

    {:ok, role} =
      RoleRegistry.upsert_role(name, :process_routing_role, group.id, prefix: fixture.schema_name)

    role
  end

  defp role_rows(fixture) do
    TenantRole
    |> Repo.all(prefix: fixture.schema_name)
    |> Enum.map(&{&1.id, &1.name, &1.kind, &1.group_id})
    |> Enum.sort()
  end

  defp rebound_entries(fixture) do
    Entry
    |> where([e], e.action == "role.rebound")
    |> Repo.all(prefix: fixture.schema_name)
  end

  defp role_body(name, group),
    do: %{"name" => name, "kind" => "process_routing_role", "group_id" => group.id}

  defp detail(conn), do: Jason.decode!(conn.resp_body)["detail"]

  # --- POST /roles: create, idempotent, refused ---------------------------------------------------

  describe "POST /roles on an existing name" do
    test "create stays 200; the same group again is idempotent with no audit entry", ctx do
      group = group!(ctx.a)
      name = "gh2524-create-#{System.unique_integer([:positive])}"

      conn = call(:post, "/roles", ctx.a, @designer, role_body(name, group))
      assert conn.status == 200, conn.resp_body
      id = Jason.decode!(conn.resp_body)["id"]
      before = role_rows(ctx.a)

      conn = call(:post, "/roles", ctx.a, @designer, role_body(name, group))
      assert conn.status == 200, conn.resp_body
      assert Jason.decode!(conn.resp_body)["id"] == id
      assert role_rows(ctx.a) == before
      assert rebound_entries(ctx.a) == []
    end

    test "a different group is 409 role_already_bound for PROCESS_DESIGNER and TENANT_ADMIN; nothing changes and no group id is in the body",
         ctx do
      legit = group!(ctx.a)
      other = group!(ctx.a)
      role = routing_role!(ctx.a, legit)
      before = role_rows(ctx.a)

      for roles <- [@designer, @admin] do
        conn = call(:post, "/roles", ctx.a, roles, role_body(role.name, other))

        assert conn.status == 409, "#{inspect(roles)}: #{conn.status} #{conn.resp_body}"
        assert detail(conn) == "role_already_bound"
        refute conn.resp_body =~ legit.id
        refute conn.resp_body =~ other.id
        assert role_rows(ctx.a) == before
      end

      assert rebound_entries(ctx.a) == []
    end
  end

  # --- POST /roles/:id/rebind ---------------------------------------------------------------------

  describe "POST /roles/:id/rebind" do
    test "TENANT_ADMIN moves the binding: group only, one role.rebound entry with actor, old/new group, trimmed reason, UTC time",
         ctx do
      legit = group!(ctx.a)
      other = group!(ctx.a)
      role = routing_role!(ctx.a, legit)
      started = DateTime.utc_now()

      conn =
        call(:post, "/roles/#{role.id}/rebind", ctx.a, @admin, %{
          "group_id" => other.id,
          "reason" => "  approvals move to the regional desk  "
        })

      assert conn.status == 200, conn.resp_body
      body = Jason.decode!(conn.resp_body)
      assert body["id"] == role.id
      assert body["group_id"] == other.id
      assert {role.id, role.name, :process_routing_role, other.id} in role_rows(ctx.a)

      assert [entry] = rebound_entries(ctx.a)
      assert entry.actor_id == conn.assigns.auth_context.user_id
      assert entry.resource_type == "tenant_role"
      assert entry.resource_id == role.id

      assert entry.before_state == %{
               "name" => role.name,
               "kind" => "process_routing_role",
               "group_id" => legit.id
             }

      assert entry.after_state == %{
               "name" => role.name,
               "kind" => "process_routing_role",
               "group_id" => other.id,
               "reason" => "approvals move to the regional desk"
             }

      assert DateTime.compare(entry.timestamp, started) in [:gt, :eq]
    end

    test "a rebind to the group it already has is 200, nothing written, no audit entry", ctx do
      legit = group!(ctx.a)
      role = routing_role!(ctx.a, legit)
      before = role_rows(ctx.a)

      conn =
        call(:post, "/roles/#{role.id}/rebind", ctx.a, @admin, %{
          "group_id" => legit.id,
          "reason" => "no-op"
        })

      assert conn.status == 200, conn.resp_body
      assert role_rows(ctx.a) == before
      assert rebound_entries(ctx.a) == []
    end

    test "PROCESS_DESIGNER (and PROCESS_OPERATOR, TASK_WORKER, TENANT_AUDITOR) get 403; nothing changes, no audit",
         ctx do
      legit = group!(ctx.a)
      other = group!(ctx.a)
      role = routing_role!(ctx.a, legit)
      before = role_rows(ctx.a)

      for roles <- [@designer, ["PROCESS_OPERATOR"], ["TASK_WORKER"], ["TENANT_AUDITOR"]] do
        conn =
          call(:post, "/roles/#{role.id}/rebind", ctx.a, roles, %{
            "group_id" => other.id,
            "reason" => "designer tries to move approvals"
          })

        assert conn.status == 403, "#{inspect(roles)}: #{conn.status} #{conn.resp_body}"
        assert detail(conn) =~ "insufficient permissions"
        assert role_rows(ctx.a) == before
      end

      assert rebound_entries(ctx.a) == []
    end

    test "every unacceptable reason is 422 invalid_reason, the value is not echoed, nothing changes",
         ctx do
      legit = group!(ctx.a)
      other = group!(ctx.a)
      role = routing_role!(ctx.a, legit)
      before = role_rows(ctx.a)

      bad = [
        :missing,
        nil,
        123,
        "",
        "   ",
        String.duplicate("r", 501),
        "line one\nline two",
        "tab\there",
        "spoof\u202Eedoc",
        "zero\u200Bwidth",
        "bom\uFEFFhere",
        "c1\u0085char"
      ]

      for reason <- bad do
        body =
          if reason == :missing,
            do: %{"group_id" => other.id},
            else: %{"group_id" => other.id, "reason" => reason}

        conn = call(:post, "/roles/#{role.id}/rebind", ctx.a, @admin, body)

        assert conn.status == 422, "#{inspect(reason)}: #{conn.status} #{conn.resp_body}"
        assert detail(conn) == "invalid_reason"

        if is_binary(reason) and String.trim(reason) != "",
          do: refute(conn.resp_body =~ String.slice(reason, 0, 4))

        assert role_rows(ctx.a) == before
      end

      assert rebound_entries(ctx.a) == []
    end

    test "a 500-codepoint reason (after trim) is accepted; codepoints, not graphemes, are counted",
         ctx do
      legit = group!(ctx.a)
      other = group!(ctx.a)
      role = routing_role!(ctx.a, legit)

      # "e" + combining acute accent: 2 codepoints, 1 grapheme. 250 of them = 500 codepoints.
      at_limit = String.duplicate("e\u0301", 250)
      over_limit = at_limit <> "e"

      conn =
        call(:post, "/roles/#{role.id}/rebind", ctx.a, @admin, %{
          "group_id" => other.id,
          "reason" => over_limit
        })

      assert conn.status == 422, conn.resp_body

      conn =
        call(:post, "/roles/#{role.id}/rebind", ctx.a, @admin, %{
          "group_id" => other.id,
          "reason" => at_limit
        })

      assert conn.status == 200, conn.resp_body
      assert [entry] = rebound_entries(ctx.a)
      assert entry.after_state["reason"] == at_limit
    end

    test "group_id: missing, non-string or malformed is 422 invalid_group_id; an unknown group is 404",
         ctx do
      legit = group!(ctx.a)
      role = routing_role!(ctx.a, legit)
      before = role_rows(ctx.a)

      for body <- [
            %{"reason" => "r"},
            %{"group_id" => 5, "reason" => "r"},
            %{"group_id" => "nope", "reason" => "r"}
          ] do
        conn = call(:post, "/roles/#{role.id}/rebind", ctx.a, @admin, body)
        assert conn.status == 422, "#{inspect(body)}: #{conn.status} #{conn.resp_body}"
        assert detail(conn) == "invalid_group_id"
      end

      conn =
        call(:post, "/roles/#{role.id}/rebind", ctx.a, @admin, %{
          "group_id" => Ecto.UUID.generate(),
          "reason" => "r"
        })

      assert conn.status == 404, conn.resp_body
      assert role_rows(ctx.a) == before
      assert rebound_entries(ctx.a) == []
    end

    test "role id: malformed, unknown, or another tenant's is the same plain 404", ctx do
      group_b = group!(ctx.b)
      role_b = routing_role!(ctx.b, group_b)
      other = group!(ctx.a)
      body = %{"group_id" => other.id, "reason" => "r"}

      statuses =
        for id <- ["not-a-uuid", Ecto.UUID.generate(), role_b.id] do
          conn = call(:post, "/roles/#{id}/rebind", ctx.a, @admin, body)
          {conn.status, conn.resp_body}
        end

      assert [{404, same}, {404, same}, {404, same}] = statuses
      assert {role_b.id, role_b.name, :process_routing_role, group_b.id} in role_rows(ctx.b)
    end

    test "the body is checked after the role is found: a bad body on an unknown role is 404, not 422",
         ctx do
      conn = call(:post, "/roles/#{Ecto.UUID.generate()}/rebind", ctx.a, @admin, %{})
      assert conn.status == 404, conn.resp_body
    end

    test "H1: the TENANT_ADMIN of P cannot rebind the PLATFORM_ADMIN binding; the operator can",
         ctx do
      legit = group!(ctx.p)
      other = group!(ctx.p)

      {:ok, pa} =
        RoleRegistry.upsert_role("PLATFORM_ADMIN", :platform_role, legit.id,
          prefix: ctx.p.schema_name
        )

      before = role_rows(ctx.p)
      body = %{"group_id" => other.id, "reason" => "move operator binding"}

      conn = call(:post, "/roles/#{pa.id}/rebind", ctx.p, @admin, body)
      assert conn.status == 403, conn.resp_body
      assert detail(conn) =~ "insufficient permissions"
      refute conn.resp_body =~ ~r/platform.?admin/i
      assert role_rows(ctx.p) == before
      assert rebound_entries(ctx.p) == []

      conn = call(:post, "/roles/#{pa.id}/rebind", ctx.p, @operator, body)
      assert conn.status == 200, conn.resp_body
      assert {pa.id, "PLATFORM_ADMIN", :platform_role, other.id} in role_rows(ctx.p)
      assert [_entry] = rebound_entries(ctx.p)
    end
  end

  # --- RoleRegistry.rebind_role/4 directly ----------------------------------------------------------

  describe "RoleRegistry.rebind_role/4" do
    test "H1 is decided inside on the stored name and fails closed without platform_scope", ctx do
      legit = group!(ctx.a)
      other = group!(ctx.a)

      # A legacy row (REQ-447 PR 2 refuses to create one outside P), inserted raw.
      pa =
        %TenantRole{}
        |> TenantRole.changeset(%{
          name: "PLATFORM_ADMIN",
          kind: :platform_role,
          group_id: legit.id
        })
        |> Repo.insert!(prefix: ctx.a.schema_name)

      attrs = %{actor_id: nil, reason: "r"}
      opts = [prefix: ctx.a.schema_name]

      assert {:error, :platform_admin_outside_platform_tenant} =
               RoleRegistry.rebind_role(pa.id, other.id, attrs, opts)

      assert {:error, :platform_admin_outside_platform_tenant} =
               RoleRegistry.rebind_role(
                 pa.id,
                 other.id,
                 attrs,
                 Keyword.put(opts, :platform_scope, "true")
               )

      assert Repo.get!(TenantRole, pa.id, prefix: ctx.a.schema_name).group_id == legit.id
    end
  end

  # --- seed ---------------------------------------------------------------------------------------

  describe "seed_default_platform_role_groups/1 after GH 2524" do
    test "keeps a platform-role binding an admin rebound, and stays idempotent", ctx do
      opts = [prefix: ctx.a.schema_name]
      assert {:ok, _roles} = RoleRegistry.seed_default_platform_role_groups(opts)

      [ta] = Enum.filter(RoleRegistry.list_roles(opts), &(&1.name == "TENANT_ADMIN"))
      chosen = group!(ctx.a)

      assert {:ok, _} =
               RoleRegistry.rebind_role(ta.id, chosen.id, %{actor_id: nil, reason: "r"}, opts)

      assert {:ok, roles} = RoleRegistry.seed_default_platform_role_groups(opts)
      assert Enum.find(roles, &(&1.name == "TENANT_ADMIN")).group_id == chosen.id
      assert {:ok, _roles} = RoleRegistry.seed_default_platform_role_groups(opts)
    end

    test "a routing row named PROCESS_DESIGNER bound to group X fails closed; X gains nothing",
         ctx do
      opts = [prefix: ctx.a.schema_name]
      x = group!(ctx.a)

      {:ok, _} = RoleRegistry.upsert_role("PROCESS_DESIGNER", :process_routing_role, x.id, opts)
      before = role_rows(ctx.a)

      assert {:error, {:role_name_taken_by_routing_role, "PROCESS_DESIGNER"}} =
               RoleRegistry.seed_default_platform_role_groups(opts)

      assert role_rows(ctx.a) == before
    end

    test "in the platform tenant, a routing row named PLATFORM_ADMIN fails closed; X gains nothing",
         ctx do
      opts = [prefix: ctx.p.schema_name]
      x = group!(ctx.p)

      {:ok, _} = RoleRegistry.upsert_role("PLATFORM_ADMIN", :process_routing_role, x.id, opts)
      before = role_rows(ctx.p)

      assert {:error, {:role_name_taken_by_routing_role, "PLATFORM_ADMIN"}} =
               RoleRegistry.seed_default_platform_role_groups(opts)

      assert role_rows(ctx.p) == before
    end
  end
end
