defmodule Letflow.Routers.IdentityGh2547AuditTest do
  @moduledoc """
  GH 2547 AC1 at the HTTP layer (design `lib/letflow/design/gh2547-tenant-admin-audit-and-count.md`
  sections 2.3, 3.1-3.4b, 3.9, 4): every `/identity` route that grants or removes a role writes
  its audit entry with the CALLER as actor and the REQUEST's trace id. Spec:
  `test/specs/GH-2547.md`, tests T-01..T-09, T-14a/b, T-19 (HTTP, raising injection), T-19c
  (HTTP), T-30.

  Two request shapes:

    * `Letflow.Routers.Identity.call/2` with the hand-assigned `auth_context` every router test in
      this suite uses (`PlatformTenantFixture.router_conn/5`), with `conn.assigns.trace_id` set to
      a fixed value. The actor is that `auth_context.user_id`.
    * The FULL `Letflow.Router` pipeline with a real `TENANT_ADMIN` API token and an `x-trace-id`
      request header (T-01 header case, T-19c), so the header -> `Api.Context` -> audit row path is
      covered end to end. The actor is then the token's owner.

  Failure injection is real: a Postgres trigger on `audit_entries` that raises for one action (the
  `pending_admin_binding_test.exs` pattern), so `Audit.insert_entry/3` RAISES inside the write's
  transaction.

  `async: false`: the fixture flips the sandbox to `:auto` and the platform pin is VM-global.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import Plug.Conn

  alias Letflow.Audit
  alias Letflow.Audit.Entry
  alias Letflow.Identity
  alias Letflow.Identity.ApiToken
  alias Letflow.Identity.Group
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.TokenMintFixture

  @admin ["TENANT_ADMIN"]
  @trace "6f1c2b9e-2547-4a11-8c20-0000000000a1"
  @header_trace "gh2547-header-trace-0001"

  # `token.create` / `token.revoke` state keys, pinned as literals (T-30). GH 2552 (design
  # section 5) changed them: `issuer_user_id` and `scope` added, `name` (a hash prefix)
  # removed, `token_hash` still excluded.
  @token_state_keys Enum.sort(
                      ~w(id user_id issuer_user_id roles expires_at revoked_at last_used_at inserted_at scope)
                    )

  setup do
    tenants = Fixture.two_tenants!()
    Fixture.unpin!()
    {:ok, _roles} = RoleRegistry.seed_default_platform_role_groups(prefix: tenants.a.schema_name)
    tenants
  end

  # --- helpers ---------------------------------------------------------------------------------

  defp call(method, path, fx, body) do
    method
    |> Fixture.router_conn(path, fx, @admin, body)
    |> assign(:trace_id, @trace)
    |> Letflow.Routers.Identity.call(Letflow.Routers.Identity.init([]))
  end

  # GH 2552: POST /tokens mints through Identity.mint_token/4, which needs a REAL caller
  # holding the roles by group membership; this is `call/4` with that caller's id.
  defp call_as(method, path, fx, user_id, body) do
    method
    |> Fixture.router_conn(path, fx, @admin, body)
    |> assign(:auth_context, %{user_id: user_id, tenant_id: fx.tenant_id, roles: @admin})
    |> assign(:trace_id, @trace)
    |> Letflow.Routers.Identity.call(Letflow.Routers.Identity.init([]))
  end

  defp actor(conn), do: conn.assigns.auth_context.user_id

  defp user!(fx) do
    n = System.unique_integer([:positive])

    %User{}
    |> Ecto.Changeset.change(%{
      username: "gh2547-http-#{n}",
      display_name: "GH2547 Person #{n}",
      email: "gh2547-http-#{n}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: fx.schema_name)
  end

  defp group!(fx) do
    %Group{}
    |> Ecto.Changeset.change(%{name: "gh2547-g-#{System.unique_integer([:positive])}"})
    |> Repo.insert!(prefix: fx.schema_name)
  end

  defp group_of!(fx, role_name) do
    Repo.one!(from(t in TenantRole, where: t.name == ^role_name, select: t.group_id),
      prefix: fx.schema_name
    )
  end

  # A raw membership row: no audit entry, so the entries a test asserts on are its own.
  defp raw_member!(fx, group_id, user) do
    Repo.insert!(%GroupMember{group_id: group_id, user_id: user.id}, prefix: fx.schema_name)
    user
  end

  defp member?(fx, group_id, user_id) do
    Repo.exists?(from(m in GroupMember, where: m.group_id == ^group_id and m.user_id == ^user_id),
      prefix: fx.schema_name
    )
  end

  defp entries(fx, action) do
    Repo.all(from(e in Entry, where: e.action == ^action, order_by: e.timestamp),
      prefix: fx.schema_name
    )
  end

  defp assert_chain_valid(fx), do: assert({:ok, :valid} = Audit.verify_chain(fx.schema_name))

  defp create_fault_trigger!(fx, name, action) do
    schema = fx.schema_name

    Repo.query!(
      ~s|CREATE FUNCTION "#{schema}".#{name}() RETURNS trigger LANGUAGE plpgsql AS $$ | <>
        ~s|BEGIN IF NEW.action = '#{action}' THEN | <>
        ~s|RAISE EXCEPTION 'injected fault (GH 2547 test)'; END IF; RETURN NEW; END $$|
    )

    Repo.query!(
      ~s|CREATE TRIGGER #{name} BEFORE INSERT ON "#{schema}".audit_entries | <>
        ~s|FOR EACH ROW EXECUTE FUNCTION "#{schema}".#{name}()|
    )
  end

  defp drop_fault_trigger!(fx, name) do
    Repo.query!(~s|DROP TRIGGER IF EXISTS #{name} ON "#{fx.schema_name}".audit_entries|)
    Repo.query!(~s|DROP FUNCTION IF EXISTS "#{fx.schema_name}".#{name}()|)
  end

  # A real TENANT_ADMIN API token for a fresh user of `fx`; returns {plaintext, owner_id}.
  defp admin_token!(fx) do
    plaintext = Fixture.mint_token!(fx, @admin)
    hash = Base.encode16(:crypto.hash(:sha256, plaintext), case: :lower)

    %ApiToken{user_id: owner_id} =
      Repo.get_by!(ApiToken, [token_hash: hash], prefix: fx.schema_name)

    {plaintext, owner_id}
  end

  defp api_add_member(fx, token, group_id, user, trace_header) do
    :post
    |> Fixture.api_conn(
      "/api/v1/identity/groups/#{group_id}/members",
      token,
      fx.tenant.slug,
      %{"user_id" => user.id}
    )
    |> put_req_header("x-trace-id", trace_header)
    |> Fixture.dispatch_api()
  end

  # --- (a) add member --------------------------------------------------------------------------

  describe "POST /groups/:id/members (path a)" do
    test "T-01 to the TENANT_ADMIN group: 201, one group_member.added with caller, trace, role delta",
         %{a: a} do
      ta_group = group_of!(a, "TENANT_ADMIN")
      user = user!(a)

      conn = call(:post, "/groups/#{ta_group}/members", a, %{"user_id" => user.id})
      assert conn.status == 201, conn.resp_body

      assert [entry] = entries(a, "group_member.added")
      assert entry.actor_id == actor(conn)
      assert entry.resource_type == "group_member"
      assert entry.resource_id == user.id
      assert entry.trace_id == @trace

      group_roles = [%{"name" => "TENANT_ADMIN", "kind" => "platform_role"}]

      assert entry.before_state == %{
               "group_id" => ta_group,
               "user_id" => user.id,
               "member" => false,
               "group_roles" => group_roles,
               "user_platform_roles" => []
             }

      assert entry.after_state == %{
               "group_id" => ta_group,
               "user_id" => user.id,
               "member" => true,
               "group_roles" => group_roles,
               "user_platform_roles" => ["TENANT_ADMIN"],
               "roles_gained" => ["TENANT_ADMIN"],
               "source" => "api"
             }

      # Ids and role names only (INV-4).
      encoded = Jason.encode!([entry.before_state, entry.after_state])
      refute encoded =~ user.email
      refute encoded =~ user.username
      refute encoded =~ user.display_name

      assert_chain_valid(a)
    end

    test "T-01 through the full pipeline: the x-trace-id header is the row's trace id and the token owner its actor",
         %{a: a} do
      {token, owner_id} = admin_token!(a)
      ta_group = group_of!(a, "TENANT_ADMIN")
      user = user!(a)

      conn = api_add_member(a, token, ta_group, user, @header_trace)
      assert conn.status == 201, conn.resp_body

      assert [entry] = entries(a, "group_member.added")
      assert entry.trace_id == @header_trace
      assert entry.actor_id == owner_id
      assert entry.resource_id == user.id
      assert entry.after_state["roles_gained"] == ["TENANT_ADMIN"]
      assert_chain_valid(a)
    end

    test "T-02 to a group carrying no role and to a routing-role group: one event each, no role gained",
         %{a: a} do
      plain = group!(a)
      routing = group!(a)
      routing_name = "gh2547-approver-#{System.unique_integer([:positive])}"

      {:ok, _role} =
        RoleRegistry.upsert_role(routing_name, :process_routing_role, routing.id,
          prefix: a.schema_name
        )

      u1 = user!(a)
      u2 = user!(a)

      assert call(:post, "/groups/#{plain.id}/members", a, %{"user_id" => u1.id}).status == 201
      assert call(:post, "/groups/#{routing.id}/members", a, %{"user_id" => u2.id}).status == 201

      added = entries(a, "group_member.added")
      assert length(added) == 2
      by_user = Map.new(added, &{&1.resource_id, &1})

      assert by_user[u1.id].after_state["group_roles"] == []
      assert by_user[u1.id].after_state["roles_gained"] == []
      assert by_user[u1.id].after_state["group_id"] == plain.id

      assert by_user[u2.id].after_state["group_roles"] == [
               %{"name" => routing_name, "kind" => "process_routing_role"}
             ]

      assert by_user[u2.id].after_state["roles_gained"] == []
      assert by_user[u2.id].after_state["user_platform_roles"] == []

      for entry <- added do
        assert entry.trace_id == @trace
        assert entry.after_state["source"] == "api"
      end

      assert_chain_valid(a)
    end

    test "T-03 re-adding an existing member: 200 and no new event", %{a: a} do
      ta_group = group_of!(a, "TENANT_ADMIN")
      user = user!(a)

      assert call(:post, "/groups/#{ta_group}/members", a, %{"user_id" => user.id}).status == 201
      assert [_first] = entries(a, "group_member.added")

      conn = call(:post, "/groups/#{ta_group}/members", a, %{"user_id" => user.id})
      assert conn.status == 200, conn.resp_body
      assert [_still_one] = entries(a, "group_member.added")
    end
  end

  # --- (a') remove member ----------------------------------------------------------------------

  describe "DELETE /groups/:id/members/:user_id (path a')" do
    test "T-04 from the TENANT_ADMIN group: 204, one group_member.removed with roles_lost", %{
      a: a
    } do
      ta_group = group_of!(a, "TENANT_ADMIN")
      user = raw_member!(a, ta_group, user!(a))

      conn = call(:delete, "/groups/#{ta_group}/members/#{user.id}", a, nil)
      assert conn.status == 204, conn.resp_body
      refute member?(a, ta_group, user.id)

      assert [entry] = entries(a, "group_member.removed")
      assert entry.actor_id == actor(conn)
      assert entry.resource_type == "group_member"
      assert entry.resource_id == user.id
      assert entry.trace_id == @trace

      group_roles = [%{"name" => "TENANT_ADMIN", "kind" => "platform_role"}]

      assert entry.before_state == %{
               "group_id" => ta_group,
               "user_id" => user.id,
               "member" => true,
               "group_roles" => group_roles,
               "user_platform_roles" => ["TENANT_ADMIN"]
             }

      assert entry.after_state == %{
               "group_id" => ta_group,
               "user_id" => user.id,
               "member" => false,
               "group_roles" => group_roles,
               "user_platform_roles" => [],
               "roles_lost" => ["TENANT_ADMIN"],
               "source" => "api"
             }

      assert_chain_valid(a)
    end

    test "T-04 removing a TA member from a roleless group: one event, roles_lost [], TENANT_ADMIN kept",
         %{a: a} do
      ta_group = group_of!(a, "TENANT_ADMIN")
      plain = group!(a)
      user = raw_member!(a, ta_group, user!(a))
      raw_member!(a, plain.id, user)

      assert call(:delete, "/groups/#{plain.id}/members/#{user.id}", a, nil).status == 204

      assert [entry] = entries(a, "group_member.removed")
      assert entry.after_state["roles_lost"] == []
      assert entry.before_state["user_platform_roles"] == ["TENANT_ADMIN"]
      assert entry.after_state["user_platform_roles"] == ["TENANT_ADMIN"]
      assert entry.after_state["group_roles"] == []
      assert member?(a, ta_group, user.id)
    end

    test "T-05 removing a non-member: 204, no event", %{a: a} do
      ta_group = group_of!(a, "TENANT_ADMIN")
      user = user!(a)

      assert call(:delete, "/groups/#{ta_group}/members/#{user.id}", a, nil).status == 204
      assert entries(a, "group_member.removed") == []
    end
  end

  # --- (b) rebind ------------------------------------------------------------------------------

  test "T-06 POST /roles/:id/rebind of the TENANT_ADMIN binding: role.rebound carries the request trace",
       %{a: a} do
    ta_role = Repo.get_by!(TenantRole, [name: "TENANT_ADMIN"], prefix: a.schema_name)
    target = group!(a)

    conn =
      call(:post, "/roles/#{ta_role.id}/rebind", a, %{
        "group_id" => target.id,
        "reason" => "gh2547 admin desk moves"
      })

    assert conn.status == 200, conn.resp_body

    assert [entry] = entries(a, "role.rebound")
    assert entry.trace_id == @trace
    assert entry.actor_id == actor(conn)
    assert entry.resource_id == ta_role.id

    # Payload unchanged from GH 2524 (identity_role_rebind_test.exs pins the same shape).
    assert entry.before_state == %{
             "name" => "TENANT_ADMIN",
             "kind" => "platform_role",
             "group_id" => ta_role.group_id
           }

    assert entry.after_state == %{
             "name" => "TENANT_ADMIN",
             "kind" => "platform_role",
             "group_id" => target.id,
             "reason" => "gh2547 admin desk moves"
           }

    assert_chain_valid(a)
  end

  # --- (b') binding writes ---------------------------------------------------------------------

  describe "POST /roles (path b')" do
    test "T-07 creating the TENANT_ADMIN binding over a group with two members: one role_binding.created",
         %{a: a} do
      {1, _} =
        Repo.delete_all(from(t in TenantRole, where: t.name == "TENANT_ADMIN"),
          prefix: a.schema_name
        )

      group = group!(a)
      m1 = raw_member!(a, group.id, user!(a))
      m2 = raw_member!(a, group.id, user!(a))

      conn =
        call(:post, "/roles", a, %{
          "name" => "TENANT_ADMIN",
          "kind" => "platform_role",
          "group_id" => group.id
        })

      assert conn.status == 200, conn.resp_body
      role_id = Jason.decode!(conn.resp_body)["id"]

      assert [entry] = entries(a, "role_binding.created")
      assert entry.actor_id == actor(conn)
      assert entry.trace_id == @trace
      assert entry.resource_type == "tenant_role"
      assert entry.resource_id == role_id
      assert entry.before_state == nil

      assert entry.after_state == %{
               "name" => "TENANT_ADMIN",
               "kind" => "platform_role",
               "group_id" => group.id,
               "granted_user_ids" => Enum.sort([m1.id, m2.id]),
               "granted_count" => 2,
               "source" => "api"
             }

      assert_chain_valid(a)
    end

    test "T-08 creating a binding over an empty group writes no event", %{a: a} do
      {1, _} =
        Repo.delete_all(from(t in TenantRole, where: t.name == "TENANT_ADMIN"),
          prefix: a.schema_name
        )

      group = group!(a)

      conn =
        call(:post, "/roles", a, %{
          "name" => "TENANT_ADMIN",
          "kind" => "platform_role",
          "group_id" => group.id
        })

      assert conn.status == 200, conn.resp_body

      assert Repo.get_by(TenantRole, [name: "TENANT_ADMIN"], prefix: a.schema_name).group_id ==
               group.id

      assert entries(a, "role_binding.created") == []
    end

    test "T-09 a kind conversion on a populated group writes one role_binding.kind_changed; on an empty group none",
         %{a: a} do
      operator_group = group_of!(a, "PROCESS_OPERATOR")
      member = raw_member!(a, operator_group, user!(a))

      conn =
        call(:post, "/roles", a, %{
          "name" => "PROCESS_OPERATOR",
          "kind" => "process_routing_role",
          "group_id" => operator_group
        })

      assert conn.status == 200, conn.resp_body
      role = Repo.get_by!(TenantRole, [name: "PROCESS_OPERATOR"], prefix: a.schema_name)
      assert role.kind == :process_routing_role

      assert [entry] = entries(a, "role_binding.kind_changed")
      assert entry.actor_id == actor(conn)
      assert entry.trace_id == @trace
      assert entry.resource_type == "tenant_role"
      assert entry.resource_id == role.id

      assert entry.before_state == %{
               "name" => "PROCESS_OPERATOR",
               "kind" => "platform_role",
               "group_id" => operator_group
             }

      assert entry.after_state == %{
               "name" => "PROCESS_OPERATOR",
               "kind" => "process_routing_role",
               "group_id" => operator_group,
               "affected_user_ids" => [member.id],
               "affected_count" => 1,
               "source" => "api"
             }

      # The same conversion on an empty group (the seeded TASK_WORKER group has no member).
      worker_group = group_of!(a, "TASK_WORKER")

      conn =
        call(:post, "/roles", a, %{
          "name" => "TASK_WORKER",
          "kind" => "process_routing_role",
          "group_id" => worker_group
        })

      assert conn.status == 200, conn.resp_body

      assert Repo.get_by!(TenantRole, [name: "TASK_WORKER"], prefix: a.schema_name).kind ==
               :process_routing_role

      assert [_only_the_first] = entries(a, "role_binding.kind_changed")
      assert_chain_valid(a)
    end
  end

  # --- (f, f') tokens --------------------------------------------------------------------------

  describe "tokens (paths f, f')" do
    test "T-14a/T-30 POST /tokens with TENANT_ADMIN: token.create carries caller and trace; GH 2552 state keys, no token_hash",
         %{a: a} do
      user = user!(a)
      TokenMintFixture.grant_roles!(a.schema_name, user.id, @admin)
      caller = TokenMintFixture.role_holder!(a.schema_name, @admin)

      conn =
        call_as(:post, "/tokens", a, caller.id, %{
          "user_id" => user.id,
          "roles" => ["TENANT_ADMIN"]
        })

      assert conn.status == 201, conn.resp_body
      body = Jason.decode!(conn.resp_body)

      assert [entry] = entries(a, "token.create")
      assert entry.actor_id == actor(conn)
      assert entry.trace_id == @trace
      assert entry.resource_type == "api_token"
      assert entry.resource_id == body["id"]
      assert entry.before_state == nil
      assert Enum.sort(Map.keys(entry.after_state)) == @token_state_keys
      assert entry.after_state["user_id"] == user.id
      assert entry.after_state["issuer_user_id"] == caller.id
      assert entry.after_state["roles"] == ["TENANT_ADMIN"]

      stored = Repo.get!(ApiToken, body["id"], prefix: a.schema_name)
      refute Jason.encode!(entry.after_state) =~ stored.token_hash

      assert is_binary(body["token"])
      refute Jason.encode!(entry.after_state) =~ body["token"]

      assert_chain_valid(a)
    end

    test "T-14b/T-30 DELETE /tokens/:id: token.revoke carries caller and trace; GH 2552 state keys",
         %{a: a} do
      user = user!(a)

      {:ok, %{token: token}} =
        Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
          prefix: a.schema_name
        )

      conn = call(:delete, "/tokens/#{token.id}", a, nil)
      assert conn.status == 200, conn.resp_body

      assert [entry] = entries(a, "token.revoke")
      assert entry.actor_id == actor(conn)
      assert entry.trace_id == @trace
      assert entry.resource_type == "api_token"
      assert entry.resource_id == token.id
      assert Enum.sort(Map.keys(entry.before_state)) == @token_state_keys
      assert Enum.sort(Map.keys(entry.after_state)) == @token_state_keys
      assert entry.before_state["revoked_at"] == nil
      assert is_binary(entry.after_state["revoked_at"])
      refute Jason.encode!([entry.before_state, entry.after_state]) =~ token.token_hash
      assert_chain_valid(a)
    end
  end

  # --- T-19 (HTTP, raising injection) ----------------------------------------------------------

  describe "T-19 an audit insert that raises rolls the write back and answers 500" do
    test "add: 500 and no group_members row", %{a: a} do
      ta_group = group_of!(a, "TENANT_ADMIN")
      user = user!(a)
      create_fault_trigger!(a, "gh2547_fail_added", "group_member.added")

      try do
        conn = call(:post, "/groups/#{ta_group}/members", a, %{"user_id" => user.id})
        assert conn.status == 500, conn.resp_body
        refute member?(a, ta_group, user.id)
        assert entries(a, "group_member.added") == []
      after
        drop_fault_trigger!(a, "gh2547_fail_added")
      end
    end

    test "remove: 500 and the row is still there", %{a: a} do
      ta_group = group_of!(a, "TENANT_ADMIN")
      user = raw_member!(a, ta_group, user!(a))
      create_fault_trigger!(a, "gh2547_fail_removed", "group_member.removed")

      try do
        conn = call(:delete, "/groups/#{ta_group}/members/#{user.id}", a, nil)
        assert conn.status == 500, conn.resp_body
        assert member?(a, ta_group, user.id)
        assert entries(a, "group_member.removed") == []
      after
        drop_fault_trigger!(a, "gh2547_fail_removed")
      end
    end

    test "upsert over a populated group: 500 and no tenant_role row", %{a: a} do
      group = group!(a)
      _member = raw_member!(a, group.id, user!(a))
      name = "gh2547-approver-#{System.unique_integer([:positive])}"
      create_fault_trigger!(a, "gh2547_fail_binding", "role_binding.created")

      try do
        conn =
          call(:post, "/roles", a, %{
            "name" => name,
            "kind" => "process_routing_role",
            "group_id" => group.id
          })

        assert conn.status == 500, conn.resp_body
        assert Repo.get_by(TenantRole, [name: name], prefix: a.schema_name) == nil
        assert entries(a, "role_binding.created") == []
      after
        drop_fault_trigger!(a, "gh2547_fail_binding")
      end
    end
  end

  # --- T-19c (HTTP) ----------------------------------------------------------------------------

  describe "T-19c a hostile x-trace-id header never makes the admin write fail" do
    test "a 300-byte ASCII header (cut to 256 by Api.Context) is stored as its first 255 characters",
         %{a: a} do
      {token, _owner_id} = admin_token!(a)
      user = user!(a)

      conn =
        api_add_member(a, token, group_of!(a, "TENANT_ADMIN"), user, String.duplicate("h", 300))

      assert conn.status == 201, conn.resp_body

      assert [entry] = entries(a, "group_member.added")
      assert entry.trace_id == String.duplicate("h", 255)
      assert_chain_valid(a)
    end

    test "a header whose 256-byte cut ends inside a codepoint is stored as a nil trace, still 201",
         %{a: a} do
      {token, _owner_id} = admin_token!(a)
      user = user!(a)
      header = String.duplicate("h", 255) <> "é"

      conn = api_add_member(a, token, group_of!(a, "TENANT_ADMIN"), user, header)
      assert conn.status == 201, conn.resp_body

      assert [entry] = entries(a, "group_member.added")
      assert entry.trace_id == nil
      assert member?(a, group_of!(a, "TENANT_ADMIN"), user.id)
    end
  end
end
