defmodule Letflow.Routers.IdentityTest do
  @moduledoc """
  Tests for `Letflow.Routers.Identity` (REQ-073) — the five real user-CRUD
  handlers. See `lib/letflow/design/req073-identity-user-routes.md` §4/§5/§6
  for the test-case rationale this file implements directly, and §6b for the
  dispatch-mechanism rationale (direct `Letflow.Routers.Identity.call/2`
  dispatch with `conn.assigns[:auth_context]` set directly, bypassing the
  full `Letflow.Router` -> `Letflow.Plugs.ApiPipeline` -> `AuthPipeline`
  chain — neither existing OIDC token double can mint a non-`"VIEWER"`-role
  token).

  Uses `Letflow.DataCase` (real Postgres, per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1) and `Letflow.TenantFixture` for real provisioned tenant
  schemas, matching `test/letflow/api/context_test.exs`'s own established
  pattern for this class of test. `async: false` for the whole module, same
  reasoning as that file: tenant provisioning/migration replay needs
  `Sandbox.mode(Letflow.Repo, :auto)`.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Identity.Group
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.User
  alias Letflow.Support.TokenMintFixture
  alias Letflow.TenantFixture

  @opts Letflow.Routers.Identity.init([])

  # ── Shared test dispatch helper (design §6b) ────────────────────────────

  defp build_conn(method, path, tenant, fields) do
    roles = Keyword.get(fields, :roles, [])
    body = Keyword.get(fields, :body, nil)
    # GH 2552: POST /tokens needs a real caller (Identity.mint_token/4); `user_id:` names one.
    user_id = Keyword.get_lazy(fields, :user_id, &Ecto.UUID.generate/0)

    conn = conn(method, path)

    conn =
      if body do
        %{conn | body_params: body}
        |> put_req_header("content-type", "application/json")
      else
        conn
      end

    conn
    |> assign(:auth_context, %{
      user_id: user_id,
      tenant_id: tenant.tenant_id,
      roles: roles
    })
    |> assign(:trace_id, "fixed-test-trace-id")
  end

  # GH 2552 (design section 7): a TENANT_ADMIN caller that also holds TASK_WORKER by group
  # membership, so it may mint a TASK_WORKER token for a target that holds it too.
  defp token_minter!(tenant) do
    TokenMintFixture.role_holder!(tenant.schema_name, ["TENANT_ADMIN", "TASK_WORKER"])
  end

  defp task_worker!(tenant, username) do
    user = insert_user!(tenant, username: username)
    TokenMintFixture.grant_roles!(tenant.schema_name, user.id, ["TASK_WORKER"])
    user
  end

  defp dispatch(conn), do: Letflow.Routers.Identity.call(conn, @opts)

  defp insert_user!(tenant, attrs) do
    default = %{
      username: "user-#{Ecto.UUID.generate()}",
      display_name: "A User",
      email: "user-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    }

    %User{}
    |> Ecto.Changeset.change(Map.merge(default, Map.new(attrs)))
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  defp insert_group!(tenant, attrs) do
    default = %{
      name: "group-#{Ecto.UUID.generate()}",
      display_name: "A Group",
      description: nil
    }

    %Group{}
    |> Ecto.Changeset.change(Map.merge(default, Map.new(attrs)))
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  defp insert_group_member!(tenant, group_id, user_id) do
    %GroupMember{}
    |> Ecto.Changeset.change(%{group_id: group_id, user_id: user_id})
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  # ── AC1: five basic end-to-end tests ────────────────────────────────────

  describe "AC1: basic end-to-end coverage for all five routes" do
    setup do
      %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req073-e2e")}
    end

    test "POST /users creates a user and returns 201 with the allowlisted shape", %{
      tenant: tenant
    } do
      conn =
        build_conn(:post, "/users", tenant,
          roles: ["TENANT_ADMIN"],
          body: %{
            "username" => "alice",
            "display_name" => "Alice Anderson",
            "email" => "alice@example.com"
          }
        )
        |> dispatch()

      assert conn.status == 201
      body = Jason.decode!(conn.resp_body)

      assert body["username"] == "alice"
      assert body["display_name"] == "Alice Anderson"
      assert body["email"] == "alice@example.com"
      assert body["status"] == "active"
      assert body["auth_source"] == "internal"
      assert is_binary(body["id"])
      assert is_binary(body["inserted_at"])
      assert is_binary(body["updated_at"])
      refute Map.has_key?(body, "password_hash")
      refute Map.has_key?(body, "external_id")
      refute Map.has_key?(body, "external_realm")

      # AC5 — full key-set assertion (not just presence/exclusion checks):
      # a stray 9th key under any other name would be caught here.
      assert Map.keys(body) |> Enum.sort() == [
               "auth_source",
               "display_name",
               "email",
               "id",
               "inserted_at",
               "status",
               "updated_at",
               "username"
             ]

      assert Repo.get_by!(User, [username: "alice"], prefix: tenant.schema_name)
    end

    test "GET /users returns a cursor page", %{tenant: tenant} do
      insert_user!(tenant, username: "bob")

      conn =
        build_conn(:get, "/users", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      assert Map.has_key?(body, "items")
      assert Map.has_key?(body, "next_cursor")
      assert Map.has_key?(body, "count")
      assert body["count"] == length(body["items"])
      assert Enum.any?(body["items"], &(&1["username"] == "bob"))

      # AC5 — full key-set assertion on each item's user_map/1 shape.
      for item <- body["items"] do
        assert Map.keys(item) |> Enum.sort() == [
                 "auth_source",
                 "display_name",
                 "email",
                 "id",
                 "inserted_at",
                 "status",
                 "updated_at",
                 "username"
               ]
      end
    end

    test "GET /users/:id returns 200 with the user", %{tenant: tenant} do
      user = insert_user!(tenant, username: "carol")

      conn =
        build_conn(:get, "/users/#{user.id}", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["id"] == user.id
      assert body["username"] == "carol"

      # AC5 — full key-set assertion.
      assert Map.keys(body) |> Enum.sort() == [
               "auth_source",
               "display_name",
               "email",
               "id",
               "inserted_at",
               "status",
               "updated_at",
               "username"
             ]
    end

    test "PATCH /users/:id returns the updated user", %{tenant: tenant} do
      user = insert_user!(tenant, username: "dave", display_name: "Dave Original")

      conn =
        build_conn(:patch, "/users/#{user.id}", tenant,
          roles: ["TENANT_ADMIN"],
          body: %{"display_name" => "Dave Updated"}
        )
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["display_name"] == "Dave Updated"

      # AC5 — full key-set assertion.
      assert Map.keys(body) |> Enum.sort() == [
               "auth_source",
               "display_name",
               "email",
               "id",
               "inserted_at",
               "status",
               "updated_at",
               "username"
             ]

      assert Repo.get!(User, user.id, prefix: tenant.schema_name).display_name == "Dave Updated"
    end

    test "POST /users/:id/status changes persisted status", %{tenant: tenant} do
      user = insert_user!(tenant, username: "erin", status: :active)

      conn =
        build_conn(:post, "/users/#{user.id}/status", tenant,
          roles: ["TENANT_ADMIN"],
          body: %{"status" => "inactive"}
        )
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "inactive"

      # AC5 — full key-set assertion.
      assert Map.keys(body) |> Enum.sort() == [
               "auth_source",
               "display_name",
               "email",
               "id",
               "inserted_at",
               "status",
               "updated_at",
               "username"
             ]

      assert Repo.get!(User, user.id, prefix: tenant.schema_name).status == :inactive
    end
  end

  # ── AC2/INV-5: cross-tenant 404 is byte-identical (design §4) ───────────

  describe "AC2/INV-5: cross-tenant 404 is byte-identical to a never-existed 404" do
    setup do
      %{
        tenant_a: TenantFixture.provisioned_tenant!(slug_prefix: "req073-cross-a"),
        tenant_b: TenantFixture.provisioned_tenant!(slug_prefix: "req073-cross-b")
      }
    end

    test "GET /users/:id: a caller in tenant A probing a tenant-B-only id gets the same 404 bytes as a never-existed id",
         %{tenant_a: tenant_a, tenant_b: tenant_b} do
      tenant_b_user = insert_user!(tenant_b, username: "only-in-b")

      resp_cross_tenant =
        build_conn(:get, "/users/#{tenant_b_user.id}", tenant_a, roles: ["TENANT_ADMIN"])
        |> dispatch()

      resp_never_existed =
        build_conn(:get, "/users/#{Ecto.UUID.generate()}", tenant_a, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert resp_cross_tenant.status == 404
      assert resp_cross_tenant.status == resp_never_existed.status
      assert resp_cross_tenant.resp_body == resp_never_existed.resp_body
    end
  end

  # ── AC4: permission-denial, DB-unchanged (design §5) ────────────────────

  describe "AC4: permission-denial on the three write routes, database unchanged" do
    setup do
      %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req073-403")}
    end

    for {roles_label, roles} <- [
          {"no roles at all", []},
          {"a role that exists but lacks UsersGroupsRolesManage", ["TASK_WORKER"]}
        ] do
      test "POST /users -> 403 and no row inserted (#{roles_label})", %{tenant: tenant} do
        count_before = Repo.aggregate(User, :count, prefix: tenant.schema_name)

        conn =
          build_conn(:post, "/users", tenant,
            roles: unquote(roles),
            body: %{"username" => "x", "display_name" => "X", "email" => "x@example.com"}
          )
          |> dispatch()

        assert conn.status == 403
        assert Repo.aggregate(User, :count, prefix: tenant.schema_name) == count_before
      end

      test "PATCH /users/:id -> 403 and the row is byte-identical to before (#{roles_label})", %{
        tenant: tenant
      } do
        user = insert_user!(tenant, username: "patch-denied-#{unquote(roles_label)}")
        before = Repo.get!(User, user.id, prefix: tenant.schema_name)

        conn =
          build_conn(:patch, "/users/#{user.id}", tenant,
            roles: unquote(roles),
            body: %{"display_name" => "Should Not Apply"}
          )
          |> dispatch()

        assert conn.status == 403
        assert Repo.get!(User, user.id, prefix: tenant.schema_name) == before
      end

      test "POST /users/:id/status -> 403 and the row is byte-identical to before (#{roles_label})",
           %{tenant: tenant} do
        user =
          insert_user!(tenant, username: "status-denied-#{unquote(roles_label)}", status: :active)

        before = Repo.get!(User, user.id, prefix: tenant.schema_name)

        conn =
          build_conn(:post, "/users/#{user.id}/status", tenant,
            roles: unquote(roles),
            body: %{"status" => "inactive"}
          )
          |> dispatch()

        assert conn.status == 403
        assert Repo.get!(User, user.id, prefix: tenant.schema_name) == before
      end
    end
  end

  # ── REQ-131 AC2 gap-fill: insufficient-role denial on every remaining ────
  # identity.ex call site not already covered above. Written by TEST-DESIGNER
  # during REQ-131's coverage-verification pass: pre-existing REQ-073/074/076
  # test blocks above/below only ever exercised the SUFFICIENT-role half for
  # GET /users, GET /users/:id, all six group routes, GET /tokens,
  # DELETE /tokens/:id, and GET /roles -- 11 of the 16 identity.ex call sites
  # REQ-131's AC2 requires both halves for. This block is the missing
  # insufficient-role half for those 11, each naming its route.

  describe "REQ-131 AC2: insufficient-role denial on the remaining identity.ex routes" do
    setup do
      %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req131-ac2")}
    end

    test "GET /users -> 403 for TASK_WORKER (lacks :UsersManage)", %{tenant: tenant} do
      conn = build_conn(:get, "/users", tenant, roles: ["TASK_WORKER"]) |> dispatch()
      assert conn.status == 403
    end

    test "GET /users/:id -> 403 for TASK_WORKER (lacks :UsersManage)", %{tenant: tenant} do
      user = insert_user!(tenant, username: "req131-get-user-denied")

      conn =
        build_conn(:get, "/users/#{user.id}", tenant, roles: ["TASK_WORKER"]) |> dispatch()

      assert conn.status == 403
    end

    test "POST /groups -> 403 for TASK_WORKER (lacks :GroupsManage), no row inserted", %{
      tenant: tenant
    } do
      count_before = Repo.aggregate(Group, :count, prefix: tenant.schema_name)

      conn =
        build_conn(:post, "/groups", tenant,
          roles: ["TASK_WORKER"],
          body: %{"name" => "req131-denied-group"}
        )
        |> dispatch()

      assert conn.status == 403
      assert Repo.aggregate(Group, :count, prefix: tenant.schema_name) == count_before
    end

    test "GET /groups -> 403 for TASK_WORKER (lacks :GroupsManage)", %{tenant: tenant} do
      conn = build_conn(:get, "/groups", tenant, roles: ["TASK_WORKER"]) |> dispatch()
      assert conn.status == 403
    end

    test "DELETE /groups/:id -> 403 for TASK_WORKER (lacks :GroupsManage), group not deleted", %{
      tenant: tenant
    } do
      group = insert_group!(tenant, name: "req131-delete-denied-group")

      conn =
        build_conn(:delete, "/groups/#{group.id}", tenant, roles: ["TASK_WORKER"]) |> dispatch()

      assert conn.status == 403
      assert Repo.get!(Group, group.id, prefix: tenant.schema_name)
    end

    test "POST /groups/:id/members -> 403 for TASK_WORKER (lacks :GroupsManage), no membership inserted",
         %{tenant: tenant} do
      group = insert_group!(tenant, name: "req131-members-denied-group")
      user = insert_user!(tenant, username: "req131-member-denied")

      conn =
        build_conn(:post, "/groups/#{group.id}/members", tenant,
          roles: ["TASK_WORKER"],
          body: %{"user_id" => user.id}
        )
        |> dispatch()

      assert conn.status == 403

      refute Repo.get_by(GroupMember, [group_id: group.id, user_id: user.id],
               prefix: tenant.schema_name
             )
    end

    test "GET /groups/:id/members -> 403 for TASK_WORKER (lacks :GroupsManage)", %{
      tenant: tenant
    } do
      group = insert_group!(tenant, name: "req131-members-list-denied-group")

      conn =
        build_conn(:get, "/groups/#{group.id}/members", tenant, roles: ["TASK_WORKER"])
        |> dispatch()

      assert conn.status == 403
    end

    test "DELETE /groups/:id/members/:user_id -> 403 for TASK_WORKER (lacks :GroupsManage), membership not removed",
         %{tenant: tenant} do
      group = insert_group!(tenant, name: "req131-member-remove-denied-group")
      user = insert_user!(tenant, username: "req131-member-remove-denied")
      insert_group_member!(tenant, group.id, user.id)

      conn =
        build_conn(:delete, "/groups/#{group.id}/members/#{user.id}", tenant,
          roles: ["TASK_WORKER"]
        )
        |> dispatch()

      assert conn.status == 403

      assert Repo.get_by(GroupMember, [group_id: group.id, user_id: user.id],
               prefix: tenant.schema_name
             )
    end

    test "GET /tokens -> 403 for TASK_WORKER (lacks :TokensManage)", %{tenant: tenant} do
      conn = build_conn(:get, "/tokens", tenant, roles: ["TASK_WORKER"]) |> dispatch()
      assert conn.status == 403
    end

    test "DELETE /tokens/:id -> 403 for TASK_WORKER (lacks :TokensManage), token not revoked", %{
      tenant: tenant
    } do
      user = task_worker!(tenant, "req131-token-owner-denied")

      created =
        build_conn(:post, "/tokens", tenant,
          roles: ["TENANT_ADMIN"],
          user_id: token_minter!(tenant).id,
          body: %{"user_id" => user.id, "roles" => ["TASK_WORKER"]}
        )
        |> dispatch()

      assert created.status == 201
      token_id = Jason.decode!(created.resp_body)["id"]

      conn =
        build_conn(:delete, "/tokens/#{token_id}", tenant, roles: ["TASK_WORKER"]) |> dispatch()

      assert conn.status == 403

      assert is_nil(
               Repo.get!(Letflow.Identity.ApiToken, token_id, prefix: tenant.schema_name).revoked_at
             )
    end

    test "GET /roles -> 403 for TASK_WORKER (lacks :RolesManage)", %{tenant: tenant} do
      conn = build_conn(:get, "/roles", tenant, roles: ["TASK_WORKER"]) |> dispatch()
      assert conn.status == 403
    end
  end

  # ── AC3/INV-1: tenant-isolation on list (design §6) ─────────────────────

  describe "AC3/INV-1: listing is tenant-isolated" do
    test "listing users as tenant A returns only tenant A's users, even with similarly-named tenant B users" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req073-iso-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req073-iso-b")

      insert_user!(tenant_a, username: "alice", display_name: "Alice Anderson")
      insert_user!(tenant_b, username: "alice", display_name: "Alice Anderson")
      insert_user!(tenant_b, username: "alice2", display_name: "Alice Anderson 2")

      conn =
        build_conn(:get, "/users", tenant_a, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert length(body["items"]) == 1
      assert Enum.map(body["items"], & &1["username"]) == ["alice"]
    end
  end

  # ── Additional coverage: search/status filters, pagination, validation ──

  describe "list_users/2 filters and pagination, exercised through the router" do
    setup do
      %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req073-filters")}
    end

    test "status filter narrows results", %{tenant: tenant} do
      insert_user!(tenant, username: "active-1", status: :active)
      insert_user!(tenant, username: "inactive-1", status: :inactive)

      conn =
        build_conn(:get, "/users?status=inactive", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert Enum.map(body["items"], & &1["username"]) == ["inactive-1"]
    end

    test "an invalid status query param is rejected with 422", %{tenant: tenant} do
      conn =
        build_conn(:get, "/users?status=bogus", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert conn.status == 422
    end

    test "search filters across username/display_name/email", %{tenant: tenant} do
      insert_user!(tenant, username: "zeb", display_name: "Zeb Zoro", email: "zeb@example.com")

      insert_user!(tenant,
        username: "other",
        display_name: "Someone Else",
        email: "other@example.com"
      )

      conn =
        build_conn(:get, "/users?search=zeb", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert Enum.map(body["items"], & &1["username"]) == ["zeb"]
    end

    test "page_size limits the page and next_cursor is set when more rows exist", %{
      tenant: tenant
    } do
      for i <- 1..3, do: insert_user!(tenant, username: "page-user-#{i}")

      conn =
        build_conn(:get, "/users?page_size=2", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert length(body["items"]) == 2
      assert is_binary(body["next_cursor"])

      conn2 =
        build_conn(
          :get,
          "/users?page_size=2&cursor=#{URI.encode_www_form(body["next_cursor"])}",
          tenant,
          roles: ["TENANT_ADMIN"]
        )
        |> dispatch()

      assert conn2.status == 200
      body2 = Jason.decode!(conn2.resp_body)
      assert length(body2["items"]) == 1
      assert body2["next_cursor"] == nil

      returned_usernames =
        (body["items"] ++ body2["items"]) |> Enum.map(& &1["username"]) |> Enum.sort()

      assert returned_usernames == ["page-user-1", "page-user-2", "page-user-3"]
    end

    test "an invalid cursor is rejected with 400", %{tenant: tenant} do
      conn =
        build_conn(:get, "/users?cursor=not-a-valid-cursor!!!", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert conn.status == 400
    end
  end

  describe "validation failures (422) on the write routes" do
    setup do
      %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req073-validation")}
    end

    test "POST /users with a missing required field returns 422", %{tenant: tenant} do
      conn =
        build_conn(:post, "/users", tenant,
          roles: ["TENANT_ADMIN"],
          body: %{"display_name" => "No Username", "email" => "x@example.com"}
        )
        |> dispatch()

      assert conn.status == 422
    end

    test "POST /users/:id/status with an invalid status value returns 422", %{tenant: tenant} do
      user = insert_user!(tenant, username: "bad-status-target")

      conn =
        build_conn(:post, "/users/#{user.id}/status", tenant,
          roles: ["TENANT_ADMIN"],
          body: %{"status" => "not-a-real-status"}
        )
        |> dispatch()

      assert conn.status == 422
    end

    test "POST /users with a duplicate username returns 409", %{tenant: tenant} do
      insert_user!(tenant, username: "dupe")

      conn =
        build_conn(:post, "/users", tenant,
          roles: ["TENANT_ADMIN"],
          body: %{"username" => "dupe", "display_name" => "Dupe", "email" => "dupe@example.com"}
        )
        |> dispatch()

      assert conn.status == 409
    end
  end

  describe "GET/PATCH/status-update on a genuinely-absent id return 404" do
    setup do
      %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req073-notfound")}
    end

    test "PATCH /users/:id 404s for an absent id", %{tenant: tenant} do
      conn =
        build_conn(:patch, "/users/#{Ecto.UUID.generate()}", tenant,
          roles: ["TENANT_ADMIN"],
          body: %{"display_name" => "Nope"}
        )
        |> dispatch()

      assert conn.status == 404
    end

    test "POST /users/:id/status 404s for an absent id", %{tenant: tenant} do
      conn =
        build_conn(:post, "/users/#{Ecto.UUID.generate()}/status", tenant,
          roles: ["TENANT_ADMIN"],
          body: %{"status" => "inactive"}
        )
        |> dispatch()

      assert conn.status == 404
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # REQ-074 — group and group-membership routes
  # ══════════════════════════════════════════════════════════════════════

  # ── AC1: basic end-to-end coverage for all six new routes ───────────────

  describe "REQ-074 AC1: basic end-to-end coverage for all six group routes" do
    setup do
      %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req074-e2e")}
    end

    test "POST /groups creates a group and returns 201 with the allowlisted shape", %{
      tenant: tenant
    } do
      conn =
        build_conn(:post, "/groups", tenant,
          roles: ["TENANT_ADMIN"],
          body: %{"name" => "engineers", "description" => "Eng team"}
        )
        |> dispatch()

      assert conn.status == 201
      body = Jason.decode!(conn.resp_body)

      assert body["name"] == "engineers"
      assert body["display_name"] == "engineers"
      assert body["description"] == "Eng team"
      assert is_binary(body["id"])
      assert is_binary(body["created_at"])

      assert Map.keys(body) |> Enum.sort() == [
               "created_at",
               "description",
               "display_name",
               "id",
               "name"
             ]

      assert Repo.get_by!(Group, [name: "engineers"], prefix: tenant.schema_name)
    end

    test "POST /groups defaults display_name to name when omitted", %{tenant: tenant} do
      conn =
        build_conn(:post, "/groups", tenant,
          roles: ["TENANT_ADMIN"],
          body: %{"name" => "support"}
        )
        |> dispatch()

      assert conn.status == 201
      body = Jason.decode!(conn.resp_body)
      assert body["display_name"] == "support"
      assert body["description"] == nil
    end

    # Router-level validation (design §3.1's own field-constraint schema)
    # rejects an empty display_name/description string with 422 --
    # Group.create_changeset/2's own "empty defaults to name/nil"
    # normalization (design §3.1 point 3) is exercised directly at the
    # Letflow.Identity level (see identity_test.exs), not reachable through
    # this router for an EMPTY string specifically, only for an OMITTED key.
    test "POST /groups rejects an empty display_name with 422", %{tenant: tenant} do
      conn =
        build_conn(:post, "/groups", tenant,
          roles: ["TENANT_ADMIN"],
          body: %{"name" => "reject-empty", "display_name" => ""}
        )
        |> dispatch()

      assert conn.status == 422
    end

    test "GET /groups returns a flat list", %{tenant: tenant} do
      insert_group!(tenant, name: "alpha")

      conn =
        build_conn(:get, "/groups", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      assert Map.has_key?(body, "items")
      assert Map.has_key?(body, "total")
      assert body["total"] == length(body["items"])
      assert Enum.any?(body["items"], &(&1["name"] == "alpha"))
    end

    test "DELETE /groups/:id deletes an empty group and returns 204", %{tenant: tenant} do
      group = insert_group!(tenant, name: "empty-group")

      conn =
        build_conn(:delete, "/groups/#{group.id}", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert conn.status == 204
      assert Repo.get(Group, group.id, prefix: tenant.schema_name) == nil
    end

    test "POST /groups/:id/members adds a member and returns 201 on genuine insert", %{
      tenant: tenant
    } do
      group = insert_group!(tenant, name: "members-group")
      user = insert_user!(tenant, username: "member-1")

      conn =
        build_conn(:post, "/groups/#{group.id}/members", tenant,
          roles: ["TENANT_ADMIN"],
          body: %{"user_id" => user.id}
        )
        |> dispatch()

      assert conn.status == 201
      body = Jason.decode!(conn.resp_body)
      assert body["group_id"] == group.id
      assert body["user_id"] == user.id
      assert body["created"] == true

      assert Repo.get_by!(GroupMember, [group_id: group.id, user_id: user.id],
               prefix: tenant.schema_name
             )
    end

    test "POST /groups/:id/members is idempotent -- re-adding the same member returns 200, created: false",
         %{tenant: tenant} do
      group = insert_group!(tenant, name: "idempotent-group")
      user = insert_user!(tenant, username: "member-2")

      conn_for = fn ->
        build_conn(:post, "/groups/#{group.id}/members", tenant,
          roles: ["TENANT_ADMIN"],
          body: %{"user_id" => user.id}
        )
        |> dispatch()
      end

      first = conn_for.()
      assert first.status == 201

      second = conn_for.()
      assert second.status == 200
      body = Jason.decode!(second.resp_body)
      assert body["created"] == false

      assert Repo.aggregate(GroupMember, :count, prefix: tenant.schema_name) == 1
    end

    test "GET /groups/:id/members returns a cursor page of members", %{tenant: tenant} do
      group = insert_group!(tenant, name: "listing-group")
      user = insert_user!(tenant, username: "member-3")
      insert_group_member!(tenant, group.id, user.id)

      conn =
        build_conn(:get, "/groups/#{group.id}/members", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      assert Map.has_key?(body, "items")
      assert Map.has_key?(body, "next_cursor")
      assert Map.has_key?(body, "count")
      assert Enum.any?(body["items"], &(&1["id"] == user.id))

      # Members are reused user_map/1 shape (design §3.5) -- full key-set check.
      for item <- body["items"] do
        assert Map.keys(item) |> Enum.sort() == [
                 "auth_source",
                 "display_name",
                 "email",
                 "id",
                 "inserted_at",
                 "status",
                 "updated_at",
                 "username"
               ]
      end
    end

    test "DELETE /groups/:id/members/:user_id removes a member and returns 204", %{
      tenant: tenant
    } do
      group = insert_group!(tenant, name: "remove-group")
      user = insert_user!(tenant, username: "member-4")
      insert_group_member!(tenant, group.id, user.id)

      conn =
        build_conn(:delete, "/groups/#{group.id}/members/#{user.id}", tenant,
          roles: ["TENANT_ADMIN"]
        )
        |> dispatch()

      assert conn.status == 204

      refute Repo.get_by(GroupMember, [group_id: group.id, user_id: user.id],
               prefix: tenant.schema_name
             )
    end

    test "DELETE /groups/:id/members/:user_id is idempotent -- removing a non-member of an existing group still returns 204",
         %{tenant: tenant} do
      group = insert_group!(tenant, name: "idempotent-remove-group")

      conn =
        build_conn(:delete, "/groups/#{group.id}/members/#{Ecto.UUID.generate()}", tenant,
          roles: ["TENANT_ADMIN"]
        )
        |> dispatch()

      assert conn.status == 204
    end

    test "DELETE /groups/:id/members/:user_id 404s for a nonexistent group", %{tenant: tenant} do
      conn =
        build_conn(
          :delete,
          "/groups/#{Ecto.UUID.generate()}/members/#{Ecto.UUID.generate()}",
          tenant,
          roles: ["TENANT_ADMIN"]
        )
        |> dispatch()

      assert conn.status == 404
    end
  end

  # ── AC2/INV-1/INV-5: cross-tenant-membership (design §4) -- load-bearing ─

  describe "REQ-074 AC2/INV-1/INV-5: cross-tenant-membership" do
    test "adding a tenant-B-only user id to a tenant-A group fails exactly like a nonexistent user id, and inserts no membership row" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req074-cross-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req074-cross-b")

      group_a = insert_group!(tenant_a, name: "engineers")
      tenant_b_user = insert_user!(tenant_b, username: "bob")

      conn_for = fn user_id ->
        build_conn(:post, "/groups/#{group_a.id}/members", tenant_a,
          roles: ["TENANT_ADMIN"],
          body: %{"user_id" => user_id}
        )
        |> dispatch()
      end

      resp_cross_tenant = conn_for.(tenant_b_user.id)
      resp_never_existed = conn_for.(Ecto.UUID.generate())

      assert resp_cross_tenant.status == 404
      assert resp_cross_tenant.status == resp_never_existed.status
      assert resp_cross_tenant.resp_body == resp_never_existed.resp_body

      # The load-bearing DB-level check (AC2): no membership row inserted.
      assert Repo.aggregate(GroupMember, :count, prefix: tenant_a.schema_name) == 0
    end
  end

  # ── AC5: delete-with-members (design §5) ────────────────────────────────

  describe "REQ-074 AC5: delete-with-members" do
    test "deleting a group with existing members returns the same 404 as deleting a nonexistent group, and the group row survives" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req074-delete-members")
      group = insert_group!(tenant, name: "has-members")
      user = insert_user!(tenant, username: "carol")
      insert_group_member!(tenant, group.id, user.id)

      resp =
        build_conn(:delete, "/groups/#{group.id}", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      resp_never_existed =
        build_conn(:delete, "/groups/#{Ecto.UUID.generate()}", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert resp.status == 404
      assert resp.status == resp_never_existed.status
      assert resp.resp_body == resp_never_existed.resp_body

      # Row survives -- refused, not cascaded.
      assert Repo.get!(Group, group.id, prefix: tenant.schema_name)
    end

    test "deleting an empty group succeeds" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req074-delete-empty")
      group = insert_group!(tenant, name: "no-members")

      resp =
        build_conn(:delete, "/groups/#{group.id}", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert resp.status == 204
      assert Repo.get(Group, group.id, prefix: tenant.schema_name) == nil
    end
  end

  # ── AC3: tenant-isolation on both group-listing and group-member-listing ─

  describe "REQ-074 AC3: tenant isolation" do
    test "listing groups as tenant A returns only tenant A's groups, even with an identically-named tenant B group" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req074-iso-groups-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req074-iso-groups-b")

      insert_group!(tenant_a, name: "engineers")
      insert_group!(tenant_b, name: "engineers")

      conn =
        build_conn(:get, "/groups", tenant_a, roles: ["TENANT_ADMIN"])
        |> dispatch()

      body = Jason.decode!(conn.resp_body)
      assert length(body["items"]) == 1
    end

    test "listing a group's members as tenant A returns only tenant A's member rows, even when tenant B has a group with the same shaped members" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req074-iso-members-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req074-iso-members-b")

      group_a = insert_group!(tenant_a, name: "engineers")
      group_b = insert_group!(tenant_b, name: "engineers")
      user_a = insert_user!(tenant_a, username: "alice")
      user_b = insert_user!(tenant_b, username: "alice")
      insert_group_member!(tenant_a, group_a.id, user_a.id)
      insert_group_member!(tenant_b, group_b.id, user_b.id)

      conn =
        build_conn(:get, "/groups/#{group_a.id}/members", tenant_a, roles: ["TENANT_ADMIN"])
        |> dispatch()

      body = Jason.decode!(conn.resp_body)
      assert length(body["items"]) == 1
      assert hd(body["items"])["id"] == user_a.id
    end
  end

  # ── AC4: pagination -- at least two pages (design §7) ───────────────────

  describe "REQ-074 AC4: group-member listing pages via cursor" do
    test "listing group members pages via cursor across at least two pages" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req074-page-members")
      group = insert_group!(tenant, name: "big-team")
      user_1 = insert_user!(tenant, username: "u1")
      user_2 = insert_user!(tenant, username: "u2")
      insert_group_member!(tenant, group.id, user_1.id)
      insert_group_member!(tenant, group.id, user_2.id)

      conn_1 =
        build_conn(:get, "/groups/#{group.id}/members?page_size=1", tenant,
          roles: ["TENANT_ADMIN"]
        )
        |> dispatch()

      body_1 = Jason.decode!(conn_1.resp_body)
      assert length(body_1["items"]) == 1
      refute is_nil(body_1["next_cursor"])

      conn_2 =
        build_conn(
          :get,
          "/groups/#{group.id}/members?page_size=1&cursor=#{URI.encode_www_form(body_1["next_cursor"])}",
          tenant,
          roles: ["TENANT_ADMIN"]
        )
        |> dispatch()

      body_2 = Jason.decode!(conn_2.resp_body)
      assert length(body_2["items"]) == 1
      assert hd(body_1["items"])["id"] != hd(body_2["items"])["id"]
      assert is_nil(body_2["next_cursor"])

      returned_ids = [hd(body_1["items"])["id"], hd(body_2["items"])["id"]] |> Enum.sort()
      assert returned_ids == Enum.sort([user_1.id, user_2.id])
    end

    test "an invalid cursor on group-member listing is rejected with 400" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req074-bad-cursor")
      group = insert_group!(tenant, name: "cursor-group")

      conn =
        build_conn(:get, "/groups/#{group.id}/members?cursor=not-a-valid-cursor!!!", tenant,
          roles: ["TENANT_ADMIN"]
        )
        |> dispatch()

      assert conn.status == 400
    end
  end

  # ── Additional coverage: validation, duplicate name, 404s ───────────────

  describe "REQ-074: validation and error coverage" do
    setup do
      %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req074-validation")}
    end

    test "POST /groups with a missing required name returns 422", %{tenant: tenant} do
      conn =
        build_conn(:post, "/groups", tenant, roles: ["TENANT_ADMIN"], body: %{})
        |> dispatch()

      assert conn.status == 422
    end

    test "POST /groups with a duplicate name returns 409", %{tenant: tenant} do
      insert_group!(tenant, name: "dupe-group")

      conn =
        build_conn(:post, "/groups", tenant,
          roles: ["TENANT_ADMIN"],
          body: %{"name" => "dupe-group"}
        )
        |> dispatch()

      assert conn.status == 409
    end

    test "POST /groups/:id/members with neither user_id nor user_ids returns 422", %{
      tenant: tenant
    } do
      group = insert_group!(tenant, name: "no-body-group")

      conn =
        build_conn(:post, "/groups/#{group.id}/members", tenant,
          roles: ["TENANT_ADMIN"],
          body: %{}
        )
        |> dispatch()

      assert conn.status == 422
    end

    test "POST /groups/:id/members falls back to user_ids[0] (OQ-2)", %{tenant: tenant} do
      group = insert_group!(tenant, name: "fallback-group")
      user = insert_user!(tenant, username: "fallback-user")

      conn =
        build_conn(:post, "/groups/#{group.id}/members", tenant,
          roles: ["TENANT_ADMIN"],
          body: %{"user_ids" => [user.id]}
        )
        |> dispatch()

      assert conn.status == 201
      body = Jason.decode!(conn.resp_body)
      assert body["user_id"] == user.id
    end

    test "POST /groups/:id/members for a nonexistent group returns 404", %{tenant: tenant} do
      user = insert_user!(tenant, username: "orphan-add-target")

      conn =
        build_conn(:post, "/groups/#{Ecto.UUID.generate()}/members", tenant,
          roles: ["TENANT_ADMIN"],
          body: %{"user_id" => user.id}
        )
        |> dispatch()

      assert conn.status == 404
    end

    test "GET /groups/:id/members for a nonexistent group returns 404", %{tenant: tenant} do
      conn =
        build_conn(:get, "/groups/#{Ecto.UUID.generate()}/members", tenant,
          roles: ["TENANT_ADMIN"]
        )
        |> dispatch()

      assert conn.status == 404
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # REQ-076 — API tokens (POST/GET /tokens, DELETE /tokens/:id) and the role
  # registry HTTP routes (GET/POST /roles). See test/specs/REQ-076.md for the
  # full AC-to-test mapping this section implements.
  # ══════════════════════════════════════════════════════════════════════

  describe "REQ-076 AC1/AC2/AC3: token issue/list/revoke plaintext discipline" do
    setup do
      %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req076-tokens")}
    end

    test "POST /tokens returns 201 with a plaintext token field matching the lf_tok_ shape (AC1a)",
         %{tenant: tenant} do
      user = task_worker!(tenant, "token-owner-1")
      minter = token_minter!(tenant)

      conn =
        build_conn(:post, "/tokens", tenant,
          roles: ["TENANT_ADMIN"],
          user_id: minter.id,
          body: %{"user_id" => user.id, "roles" => ["TASK_WORKER"]}
        )
        |> dispatch()

      assert conn.status == 201
      body = Jason.decode!(conn.resp_body)

      assert is_binary(body["token"])
      assert body["token"] =~ ~r/^lf_tok_[0-9a-f]{64}$/
      assert body["user_id"] == user.id
      assert body["roles"] == ["TASK_WORKER"]
      assert is_binary(body["id"])
      assert is_binary(body["name"])
      assert body["expires_at"] == nil
      assert is_binary(body["created_at"])

      # GH 2552: "issuer_user_id" (the caller) joins the created key set.
      assert body["issuer_user_id"] == minter.id

      assert Map.keys(body) |> Enum.sort() == [
               "created_at",
               "expires_at",
               "id",
               "issuer_user_id",
               "name",
               "roles",
               "token",
               "user_id"
             ]
    end

    test "GET /tokens after creation has no token field and no value equal to the plaintext anywhere in the response (AC1b)",
         %{tenant: tenant} do
      user = task_worker!(tenant, "token-owner-2")
      minter = token_minter!(tenant)

      create_conn =
        build_conn(:post, "/tokens", tenant,
          roles: ["TENANT_ADMIN"],
          user_id: minter.id,
          body: %{"user_id" => user.id, "roles" => ["TASK_WORKER"]}
        )
        |> dispatch()

      assert create_conn.status == 201
      plaintext = Jason.decode!(create_conn.resp_body)["token"]

      list_conn =
        build_conn(:get, "/tokens", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert list_conn.status == 200
      body = Jason.decode!(list_conn.resp_body)

      for item <- body["items"] do
        refute Map.has_key?(item, "token")
        refute Map.has_key?(item, "token_hash")
      end

      refute list_conn.resp_body =~ plaintext

      # AC5, INV-2-equivalent -- full key-set assertion, so a stray leaked field
      # under any other name is caught here too.
      for item <- body["items"] do
        # GH 2552: "issuer_user_id" joins the list key set.
        # GH 2579: "no_expiry" joins it too.
        assert Map.keys(item) |> Enum.sort() == [
                 "created_at",
                 "expires_at",
                 "id",
                 "issuer_user_id",
                 "last_used_at",
                 "name",
                 "no_expiry",
                 "revoked_at",
                 "roles",
                 "status",
                 "user_id"
               ]
      end
    end

    test "DELETE /tokens/:id's response also has no token field and no plaintext value (AC1b companion)",
         %{tenant: tenant} do
      user = task_worker!(tenant, "token-owner-3")
      minter = token_minter!(tenant)

      create_conn =
        build_conn(:post, "/tokens", tenant,
          roles: ["TENANT_ADMIN"],
          user_id: minter.id,
          body: %{"user_id" => user.id, "roles" => ["TASK_WORKER"]}
        )
        |> dispatch()

      created_body = Jason.decode!(create_conn.resp_body)
      plaintext = created_body["token"]
      token_id = created_body["id"]

      revoke_conn =
        build_conn(:delete, "/tokens/#{token_id}", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert revoke_conn.status == 200
      revoked_body = Jason.decode!(revoke_conn.resp_body)

      refute Map.has_key?(revoked_body, "token")
      refute Map.has_key?(revoked_body, "token_hash")
      refute revoke_conn.resp_body =~ plaintext
      assert revoked_body["status"] == "revoked"
      refute is_nil(revoked_body["revoked_at"])
    end

    test "the persisted row's own columns never equal the plaintext, checked across every field (AC2, router-level)",
         %{tenant: tenant} do
      user = task_worker!(tenant, "token-owner-4")
      minter = token_minter!(tenant)

      conn =
        build_conn(:post, "/tokens", tenant,
          roles: ["TENANT_ADMIN"],
          user_id: minter.id,
          body: %{"user_id" => user.id, "roles" => ["TASK_WORKER"]}
        )
        |> dispatch()

      body = Jason.decode!(conn.resp_body)
      plaintext = body["token"]

      persisted = Repo.get!(Letflow.Identity.ApiToken, body["id"], prefix: tenant.schema_name)

      persisted
      |> Map.from_struct()
      |> Enum.each(fn {field, value} ->
        refute value == plaintext,
               "field #{inspect(field)} on the persisted row equals the plaintext -- AC2 violation"
      end)
    end

    test "a token's plaintext never appears in captured logs or in either response body, across a successful creation and a deliberately failed one (AC3)",
         %{tenant: tenant} do
      user = task_worker!(tenant, "token-owner-5")
      minter = token_minter!(tenant)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          success_conn =
            build_conn(:post, "/tokens", tenant,
              roles: ["TENANT_ADMIN"],
              user_id: minter.id,
              body: %{"user_id" => user.id, "roles" => ["TASK_WORKER"]}
            )
            |> dispatch()

          assert success_conn.status == 201
          plaintext = Jason.decode!(success_conn.resp_body)["token"]

          # A deliberately-failed creation -- an unrecognized role string, per
          # design §3.1 step 2 ({:error, :invalid_role_set}, 422). This second
          # request's response body must ALSO never carry the first request's
          # plaintext (nor any plaintext of its own, since it never generates one).
          failed_conn =
            build_conn(:post, "/tokens", tenant,
              roles: ["TENANT_ADMIN"],
              user_id: minter.id,
              body: %{"user_id" => user.id, "roles" => ["NOT_A_REAL_ROLE"]}
            )
            |> dispatch()

          assert failed_conn.status == 422

          # The FAILED request's error body must never carry the first
          # request's plaintext (nor any plaintext of its own, since it never
          # generates one) -- AC3's "no error body" clause. The successful
          # creation's OWN response body legitimately contains the plaintext
          # once (AC1's own exception) and is deliberately NOT asserted
          # against here.
          refute failed_conn.resp_body =~ plaintext

          send(self(), {:captured_plaintext, plaintext})
        end)

      assert_received {:captured_plaintext, plaintext}
      refute log =~ plaintext
    end
  end

  describe "REQ-076: token permission gating (:TokensManage, TENANT_ADMIN only)" do
    test "POST /tokens -> 403 for a role without :TokensManage, no row inserted" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req076-tokens-403")
      user = insert_user!(tenant, username: "token-owner-403")
      count_before = Repo.aggregate(Letflow.Identity.ApiToken, :count, prefix: tenant.schema_name)

      conn =
        build_conn(:post, "/tokens", tenant,
          roles: ["TASK_WORKER"],
          body: %{"user_id" => user.id, "roles" => ["TASK_WORKER"]}
        )
        |> dispatch()

      assert conn.status == 403

      assert Repo.aggregate(Letflow.Identity.ApiToken, :count, prefix: tenant.schema_name) ==
               count_before
    end
  end

  describe "REQ-076 AC6: role registry routes" do
    # Letflow.Identity.RoleRegistry (REQ-020, unchanged by REQ-076) takes no
    # `:prefix`/`opts` parameter at all -- design doc §5.2/OQ-2 flags this as a
    # known, un-fixed cross-tenant gap: `groups`/`tenant_role` resolve via
    # whatever the connection's own Postgres `search_path` happens to be, not an
    # explicit schema argument. Mirrors test/letflow/role_registry_test.exs's own
    # setup exactly (see that file's moduledoc "Sandbox mode: what ACTUALLY
    # protects against cross-test leakage" section for the full reasoning this
    # reuses rather than re-derives): after TenantFixture.provisioned_tenant!/1
    # leaves the sandbox in :auto mode, switch back to a single :manual-mode
    # checkout BEFORE issuing `SET search_path`, so every unprefixed RoleRegistry
    # query this describe block's dispatched requests make (including inside
    # Letflow.Routers.Identity.call/2 itself, run synchronously in this same
    # process) resolves against the SAME one physical connection carrying that
    # GUC -- not a random pool connection under :auto mode, which would make the
    # SET search_path a no-op for most queries.
    setup do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req076-roles")

      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :manual)
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Letflow.Repo)

      # Registered AFTER provisioned_tenant!/1's own on_exit/1 (teardown), so
      # LIFO ordering runs this FIRST -- forcing :auto mode back on before that
      # teardown's DROP SCHEMA / DELETE cleanup needs a real, checked-in
      # connection, exactly like role_registry_test.exs's own on_exit/1 does.
      on_exit(fn -> Letflow.Test.SandboxAutoMode.enter_auto_mode!(Letflow.Repo) end)

      Repo.query!(~s(SET search_path TO "#{tenant.schema_name}", public))

      %{tenant: tenant}
    end

    test "GET /roles returns a list with the role_map/1 shape", %{tenant: tenant} do
      group = insert_group!(tenant, name: "role-registry-group")

      {:ok, _role} =
        Letflow.Identity.RoleRegistry.upsert_role(
          "listed-role-#{System.unique_integer([:positive])}",
          :process_routing_role,
          group.id,
          prefix: tenant.schema_name
        )

      conn =
        build_conn(:get, "/roles", tenant, roles: ["TENANT_ADMIN"])
        |> dispatch()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert Map.has_key?(body, "items")

      for item <- body["items"] do
        assert Map.keys(item) |> Enum.sort() == ["created_at", "group_id", "id", "kind", "name"]
      end
    end

    test "POST /roles accepts a role name outside the five-role enum and returns 200, not 201 (AC6, OQ-5)",
         %{tenant: tenant} do
      group = insert_group!(tenant, name: "custom-role-group")

      conn =
        build_conn(:post, "/roles", tenant,
          roles: ["TENANT_ADMIN"],
          body: %{
            "name" => "CUSTOM_APPROVER",
            "kind" => "process_routing_role",
            "group_id" => group.id
          }
        )
        |> dispatch()

      # 200, NOT 201 -- an upsert, matching R-Co's own handleUpsertRole literal
      # status code (design §6.1/§10 OQ-5), not this codebase's usual 201-for-create
      # convention.
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["name"] == "CUSTOM_APPROVER"
      assert body["group_id"] == group.id
    end

    test "POST /roles rejects an invalid role name with 422", %{tenant: tenant} do
      group = insert_group!(tenant, name: "invalid-role-group")

      conn =
        build_conn(:post, "/roles", tenant,
          roles: ["TENANT_ADMIN"],
          body: %{"name" => "", "kind" => "process_routing_role", "group_id" => group.id}
        )
        |> dispatch()

      assert conn.status == 422
    end

    test "POST /roles -> 403 for TASK_WORKER (lacks :RolesManage)", %{tenant: tenant} do
      group = insert_group!(tenant, name: "denied-role-group")

      conn =
        build_conn(:post, "/roles", tenant,
          roles: ["TASK_WORKER"],
          body: %{
            "name" => "some-role",
            "kind" => "process_routing_role",
            "group_id" => group.id
          }
        )
        |> dispatch()

      assert conn.status == 403
    end

    test "POST /roles -> 200 for PROCESS_DESIGNER, who holds :RolesManage (design §4 point 2)",
         %{tenant: tenant} do
      group = insert_group!(tenant, name: "designer-role-group")

      conn =
        build_conn(:post, "/roles", tenant,
          roles: ["PROCESS_DESIGNER"],
          body: %{
            "name" => "designer-granted-role",
            "kind" => "process_routing_role",
            "group_id" => group.id
          }
        )
        |> dispatch()

      assert conn.status == 200
    end
  end
end
