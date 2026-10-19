defmodule Letflow.Identity.TenantAdminGuardTest do
  @moduledoc """
  REQ-497 PR 1b / GH #2533, AC9-AC12 (+ GH #2575): the N1 last-tenant-wide-admin guard
  (design `lib/letflow/design/req497-1b-allowed-flag-shadow-n1.md` sections 6.1, 6.2 and 12.6,
  as amended by the supervisor ruling of 2026-10-15 recorded in its section 18). Spec:
  `test/specs/REQ-497-1b.md`, tests T-G1..T-G10.

  Binding rules under test (they supersede the r1 text of 12.6):

    * TRANSITION rule for the unbind (POST /roles kind change), the TA member removal and the
      TA rebind: refused ONLY when the tenant counted > 0 tenant-wide admins before the write
      and 0 after it. A tenant already at 0 is NOT refused (each path has its already-zero
      case, answered with success).
    * `revoke_token`: only a token COUNTED at lock time (not revoked, not expired, owner active,
      `TENANT_ADMIN` in its roles) is guarded, on the after-count.
    * pending-grant revoke: the last OPEN grant is refused while the count is 0.
    * every refusal: 409 `last_tenant_wide_admin` / `{:error, :last_tenant_wide_admin}`,
      nothing changed (incl. the write's own audit entry), and exactly one
      `tenant_admin.guard_refused` entry with EXACTLY the six contract keys, written in its own
      transaction after the rollback. The pending-grant refusal writes the tenant entry with a
      nil actor and trace plus ONE companion entry on the platform chain with the operator.

  Real Postgres, dedicated provisioned tenants, holders written RAW (no audit noise). Lock
  tests use real separate connections (the tenant fixture leaves the sandbox in `:auto`), every
  wait is bounded and every task is stopped in an `after` block.

  `async: false`: committed state, DDL fault triggers, cross-connection locks, the platform pin.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Plug.Conn

  alias Letflow.Audit
  alias Letflow.Audit.Entry
  alias Letflow.Identity
  alias Letflow.Identity.ApiToken
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.PendingAdminGrant
  alias Letflow.Identity.PendingAdminGrants
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.TenantAdminGuard
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User
  alias Letflow.Support.PendingAdminHelper, as: H
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.TenantFixture

  @admin ["TENANT_ADMIN"]
  @trace "req497-1b-guard-trace-0001"
  @event "tenant_admin.guard_refused"
  @contract_keys ~w(action actor counted_admins reason_code target_id trace_id)

  # --- fixtures --------------------------------------------------------------------------------

  defp tenant!(slug_prefix) do
    Fixture.unpin!()
    fx = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)
    {:ok, _roles} = RoleRegistry.seed_default_platform_role_groups(prefix: fx.schema_name)
    fx
  end

  defp ta_group(fx), do: RSG.group_of!(fx.schema_name, "TENANT_ADMIN")
  defp ta_binding(fx), do: RSG.binding(fx.schema_name, "TENANT_ADMIN")

  defp user!(fx, status) do
    user = RSG.user!(fx.schema_name)

    if status == :active do
      user
    else
      {1, _} =
        Repo.update_all(from(u in User, where: u.id == ^user.id), [set: [status: status]],
          prefix: fx.schema_name
        )

      %{user | status: status}
    end
  end

  defp member!(fx, group_id, user), do: RSG.member!(fx.schema_name, group_id, user)
  defp ta_member!(fx, status), do: member!(fx, ta_group(fx), user!(fx, status))

  defp member?(fx, group_id, user_id) do
    Repo.exists?(from(m in GroupMember, where: m.group_id == ^group_id and m.user_id == ^user_id),
      prefix: fx.schema_name
    )
  end

  # A raw token row (no audit); `fields` sets `expires_at` / `revoked_at` (whole seconds).
  defp raw_token!(fx, user, roles, fields) do
    n = System.unique_integer([:positive])

    Repo.insert!(
      struct(
        ApiToken,
        Map.merge(
          %{
            user_id: user.id,
            name: "req497-1b-token-#{n}",
            token_hash: "req497-1b-hash-#{n}-" <> Ecto.UUID.generate(),
            roles: roles,
            expires_at: nil,
            revoked_at: nil
          },
          fields
        )
      ),
      prefix: fx.schema_name
    )
  end

  # A real token through the trusted path, so its plaintext can be verified afterwards.
  defp real_token!(fx, user, roles) do
    {:ok, %{token: token, plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: fx.schema_name)

    {token, plaintext}
  end

  defp seconds_from_now(seconds),
    do: DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)

  defp count(fx), do: Identity.count_tenant_wide_admins(fx.schema_name)

  defp token_row(fx, id), do: Repo.get!(ApiToken, id, prefix: fx.schema_name)

  # --- HTTP ------------------------------------------------------------------------------------

  defp http(method, path, fx, body) do
    method
    |> Fixture.router_conn(path, fx, @admin, body)
    |> assign(:trace_id, @trace)
    |> Letflow.Routers.Identity.call(Letflow.Routers.Identity.init([]))
  end

  defp actor(conn), do: conn.assigns.auth_context.user_id
  defp detail(conn), do: Jason.decode!(conn.resp_body)["detail"]

  # --- audit -----------------------------------------------------------------------------------

  defp entry_ids(schema), do: Repo.all(from(e in Entry, select: e.id), prefix: schema)

  defp new_entries(schema, ids_before) do
    Repo.all(from(e in Entry, where: e.id not in ^ids_before, order_by: e.timestamp),
      prefix: schema
    )
  end

  defp refusals(schema) do
    Repo.all(from(e in Entry, where: e.action == @event, order_by: e.timestamp), prefix: schema)
  end

  # The ONLY new tenant-chain entry since `ids_before` is one guard_refused entry with exactly
  # the six contract keys (the guarded write and its own audit entry were rolled back).
  defp assert_only_refusal!(schema, ids_before, expected) do
    assert [entry] = new_entries(schema, ids_before)
    assert_refusal_entry!(entry, expected)
    assert {:ok, :valid} = Audit.verify_chain(schema)
    entry
  end

  defp assert_refusal_entry!(entry, %{action: action, target_id: target_id} = expected) do
    actor = Map.fetch!(expected, :actor)
    trace = Map.fetch!(expected, :trace)

    assert entry.action == @event
    assert entry.resource_id == target_id
    assert entry.actor_id == actor
    assert entry.trace_id == trace
    assert entry.before_state == nil
    assert entry.after_state |> Map.keys() |> Enum.sort() == @contract_keys

    assert entry.after_state == %{
             "action" => action,
             "actor" => actor,
             "target_id" => target_id,
             # the default reason_code of the N1 paths (GH #2869 adds a second value for the new guard only)
             "reason_code" => "last_tenant_wide_admin",
             "counted_admins" => 0,
             "trace_id" => trace
           }

    entry
  end

  # --- pending grants and the rebind fault (T-G5, T-G9) ------------------------------------

  defp write_opts(w, trace),
    do: [
      prefix: w.tenant.schema_name,
      platform_prefix: w.platform.schema_name,
      trace_id: trace,
      onboarding_id: nil
    ]

  # The tenant seed already binds PROCESS_OPERATOR to its own group (#2537 rebind rules: upserting
  # the name onto another group is :role_already_bound). So group A is the seeded binding's group,
  # and the fault is injected on the rebind to the fresh group B.
  @fault_role "PROCESS_OPERATOR"

  defp fault_setup(slug) do
    fx = tenant!(slug)
    s = fx.schema_name
    role = RSG.binding(s, @fault_role)
    a = %{id: role.group_id}
    b = RSG.fresh_group!(s)
    {fx, role, a, b}
  end

  defp with_update_fault(schema, fun) do
    name = RSG.install_fault_trigger!(schema, "UPDATE")

    try do
      fun.()
    after
      RSG.drop_fault_trigger!(schema, name)
    end
  end

  # --- cross-connection lock helpers (the tenant_wide_admins_test.exs pattern) ----------------

  defp hold_admin_lock(prefix, parent) do
    Task.async(fn ->
      Repo.transaction(fn ->
        :ok = Identity.lock_tenant_admins!(prefix)
        send(parent, {:admin_lock_held, prefix})

        receive do
          :release -> :ok
        after
          10_000 -> :ok
        end

        Repo.rollback(:released)
      end)
    end)
  end

  # Holds ONLY the TENANT_ADMIN tenant_role row FOR UPDATE (no advisory lock); commits on release.
  defp hold_binding_row(prefix, parent) do
    Task.async(fn ->
      Repo.transaction(fn ->
        %TenantRole{} =
          Repo.one!(
            from(t in TenantRole, where: t.name == "TENANT_ADMIN", lock: "FOR UPDATE"),
            prefix: prefix
          )

        send(parent, {:binding_row_held, prefix})

        receive do
          :release -> :ok
        after
          10_000 -> :ok
        end

        :committed
      end)
    end)
  end

  # Bounded poll (at most ~5 s): true once a backend waits on a lock while running a statement
  # matching `pattern`.
  defp lock_waiter?(pattern) do
    Enum.reduce_while(1..500, false, fn _attempt, _acc ->
      %{rows: [[n]]} =
        Repo.query!(
          "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() " <>
            "AND wait_event_type = 'Lock' AND query ILIKE $1",
          ["%" <> pattern <> "%"]
        )

      if n >= 1 do
        {:halt, true}
      else
        Process.sleep(10)
        {:cont, false}
      end
    end)
  end

  defp stop_task(%Task{pid: pid} = task) do
    if Process.alive?(pid), do: Task.shutdown(task, :brutal_kill)
    :ok
  end

  # ===========================================================================================
  describe "T-G1 POST /roles: TENANT_ADMIN platform_role -> process_routing_role (unbind)" do
    test "the last admin in the TA group: 409, the binding and its row unchanged, one unbind_tenant_admin event" do
      fx = tenant!("req497-g1a")
      s = fx.schema_name
      _last = ta_member!(fx, :active)
      binding = ta_binding(fx)
      rows_before = RSG.rows(s)
      before = entry_ids(s)

      conn =
        http(:post, "/roles", fx, %{
          "name" => "TENANT_ADMIN",
          "kind" => "process_routing_role",
          "group_id" => ta_group(fx)
        })

      assert conn.status == 409, conn.resp_body
      assert detail(conn) == "last_tenant_wide_admin"
      assert %TenantRole{kind: :platform_role} = ta_binding(fx)
      assert RSG.rows(s) == rows_before
      assert count(fx) == 1

      assert_only_refusal!(s, before, %{
        action: "unbind_tenant_admin",
        target_id: binding.id,
        actor: actor(conn),
        trace: @trace
      })
    end

    test "two TA members do not help: an unbind removes every member-admin at once, so it is still 409" do
      fx = tenant!("req497-g1b")
      _a = ta_member!(fx, :active)
      _b = ta_member!(fx, :active)

      conn =
        http(:post, "/roles", fx, %{
          "name" => "TENANT_ADMIN",
          "kind" => "process_routing_role",
          "group_id" => ta_group(fx)
        })

      assert conn.status == 409, conn.resp_body
      assert detail(conn) == "last_tenant_wide_admin"
      assert count(fx) == 2
      assert length(refusals(fx.schema_name)) == 1
    end

    test "a TA token owner remains: 200, converted, no event" do
      fx = tenant!("req497-g1c")
      _member = ta_member!(fx, :active)
      _owner = raw_token!(fx, user!(fx, :active), ["TENANT_ADMIN"], %{})

      conn =
        http(:post, "/roles", fx, %{
          "name" => "TENANT_ADMIN",
          "kind" => "process_routing_role",
          "group_id" => ta_group(fx)
        })

      assert conn.status == 200, conn.resp_body
      assert %TenantRole{kind: :process_routing_role} = ta_binding(fx)
      assert count(fx) == 1
      assert refusals(fx.schema_name) == []
    end

    test "already zero (the only TA member is inactive): NOT refused under the transition rule, 200, no event" do
      fx = tenant!("req497-g1d")
      _inactive = ta_member!(fx, :inactive)
      assert count(fx) == 0

      conn =
        http(:post, "/roles", fx, %{
          "name" => "TENANT_ADMIN",
          "kind" => "process_routing_role",
          "group_id" => ta_group(fx)
        })

      assert conn.status == 200, conn.resp_body
      assert %TenantRole{kind: :process_routing_role} = ta_binding(fx)
      assert refusals(fx.schema_name) == []
    end
  end

  # ===========================================================================================
  describe "T-G2 DELETE /groups/:id/members/:user_id" do
    test "the last TA member: 409, still a member, one remove_tenant_admin_member event" do
      fx = tenant!("req497-g2a")
      s = fx.schema_name
      last = ta_member!(fx, :active)
      before = entry_ids(s)

      conn = http(:delete, "/groups/#{ta_group(fx)}/members/#{last.id}", fx, nil)

      assert conn.status == 409, conn.resp_body
      assert detail(conn) == "last_tenant_wide_admin"
      assert member?(fx, ta_group(fx), last.id)
      assert count(fx) == 1

      assert_only_refusal!(s, before, %{
        action: "remove_tenant_admin_member",
        target_id: last.id,
        actor: actor(conn),
        trace: @trace
      })
    end

    test "a non-last TA member: 204, removed, no event" do
      fx = tenant!("req497-g2b")
      leaving = ta_member!(fx, :active)
      _staying = ta_member!(fx, :active)

      conn = http(:delete, "/groups/#{ta_group(fx)}/members/#{leaving.id}", fx, nil)

      assert conn.status == 204, conn.resp_body
      refute member?(fx, ta_group(fx), leaving.id)
      assert count(fx) == 1
      assert refusals(fx.schema_name) == []
    end

    test "the last member-admin who also owns a live TA token: 204 (the token keeps the count above 0)" do
      fx = tenant!("req497-g2c")
      both = ta_member!(fx, :active)
      _token = raw_token!(fx, both, ["TENANT_ADMIN"], %{})

      conn = http(:delete, "/groups/#{ta_group(fx)}/members/#{both.id}", fx, nil)

      assert conn.status == 204, conn.resp_body
      assert count(fx) == 1
      assert refusals(fx.schema_name) == []
    end

    test "already zero (removing the only, inactive, TA member): NOT refused, 204, no event" do
      fx = tenant!("req497-g2d")
      inactive = ta_member!(fx, :inactive)
      assert count(fx) == 0

      conn = http(:delete, "/groups/#{ta_group(fx)}/members/#{inactive.id}", fx, nil)

      assert conn.status == 204, conn.resp_body
      refute member?(fx, ta_group(fx), inactive.id)
      assert refusals(fx.schema_name) == []
    end

    test "a non-TA group in a tenant with 0 admins: 204, no count, no event" do
      fx = tenant!("req497-g2e")
      designers = RSG.group_of!(fx.schema_name, "PROCESS_DESIGNER")
      designer = member!(fx, designers, user!(fx, :active))
      assert count(fx) == 0

      conn = http(:delete, "/groups/#{designers}/members/#{designer.id}", fx, nil)

      assert conn.status == 204, conn.resp_body
      refute member?(fx, designers, designer.id)
      assert refusals(fx.schema_name) == []
    end
  end

  # ===========================================================================================
  describe "T-G3 POST /roles/:id/rebind of the TENANT_ADMIN binding" do
    test "to an empty group with the last admin in the old group: 409, unchanged, one rebind_tenant_admin event" do
      fx = tenant!("req497-g3a")
      s = fx.schema_name
      _last = ta_member!(fx, :active)
      binding = ta_binding(fx)
      empty = RSG.fresh_group!(s)
      rows_before = RSG.rows(s)
      before = entry_ids(s)

      conn =
        http(:post, "/roles/#{binding.id}/rebind", fx, %{
          "group_id" => empty.id,
          "reason" => "REQ-497 1b guard test"
        })

      assert conn.status == 409, conn.resp_body
      assert detail(conn) == "last_tenant_wide_admin"
      assert ta_binding(fx).group_id == binding.group_id
      assert RSG.rows(s) == rows_before
      assert count(fx) == 1

      assert_only_refusal!(s, before, %{
        action: "rebind_tenant_admin",
        target_id: binding.id,
        actor: actor(conn),
        trace: @trace
      })
    end

    test "to a group with an active member: 200, moved, one role.rebound entry, no event" do
      fx = tenant!("req497-g3b")
      s = fx.schema_name
      _old = ta_member!(fx, :active)
      binding = ta_binding(fx)
      target = RSG.fresh_group!(s)
      newcomer = member!(fx, target.id, user!(fx, :active))

      conn =
        http(:post, "/roles/#{binding.id}/rebind", fx, %{
          "group_id" => target.id,
          "reason" => "REQ-497 1b guard test"
        })

      assert conn.status == 200, conn.resp_body
      assert ta_binding(fx).group_id == target.id
      assert Identity.tenant_wide_admin_user_ids(s) == [newcomer.id]
      assert length(RSG.entries(s, "role.rebound")) == 1
      assert refusals(s) == []
    end

    test "already zero (old group holds only an inactive member): NOT refused, 200, no event" do
      fx = tenant!("req497-g3c")
      s = fx.schema_name
      _inactive = ta_member!(fx, :inactive)
      binding = ta_binding(fx)
      empty = RSG.fresh_group!(s)
      assert count(fx) == 0

      conn =
        http(:post, "/roles/#{binding.id}/rebind", fx, %{
          "group_id" => empty.id,
          "reason" => "REQ-497 1b guard test"
        })

      assert conn.status == 200, conn.resp_body
      assert ta_binding(fx).group_id == empty.id
      assert refusals(s) == []
    end
  end

  # ===========================================================================================
  test "T-G4 DELETE /groups/:ta keeps its structural refusal and writes no guard_refused entry" do
    fx = tenant!("req497-g4")
    s = fx.schema_name
    group = ta_group(fx)

    # Memberless bound group: the FK refusal.
    conn = http(:delete, "/groups/#{group}", fx, nil)
    assert conn.status == 409, conn.resp_body

    # With a member: refused as today (members or binding).
    _admin = ta_member!(fx, :active)
    conn = http(:delete, "/groups/#{group}", fx, nil)
    assert conn.status in [404, 409], conn.resp_body

    assert ta_group(fx) == group
    assert count(fx) == 1
    assert refusals(s) == []
  end

  # ===========================================================================================
  describe "T-G5 pending-grant revoke" do
    test "the last OPEN grant while the count is 0: refused, grant still open, nil-actor tenant entry + one platform companion" do
      w = H.world!()
      ts = w.tenant.schema_name
      ps = w.platform.schema_name
      grant = H.create_grant!(w, "last.open@example.com")
      tenant_before = entry_ids(ts)
      platform_before = entry_ids(ps)

      assert {:error, :last_tenant_wide_admin} =
               PendingAdminGrants.revoke(
                 grant.id,
                 %{user_id: w.operator_id},
                 write_opts(w, "t-guard-rev")
               )

      assert PendingAdminGrant.state(H.grant(w, grant.id)) == :open
      assert H.grant(w, grant.id).email_key != nil

      tenant_entry =
        assert_only_refusal!(ts, tenant_before, %{
          action: "revoke_pending_grant",
          target_id: grant.id,
          actor: nil,
          trace: nil
        })

      assert tenant_entry.resource_type == "pending_admin_grant"
      refute inspect(new_entries(ts, tenant_before)) =~ w.operator_id

      platform_entry =
        assert_only_refusal!(ps, platform_before, %{
          action: "revoke_pending_grant",
          target_id: grant.id,
          actor: w.operator_id,
          trace: "t-guard-rev"
        })

      assert platform_entry.resource_type == "pending_admin_grant"
      assert H.entries(ts, "tenant.admin_grant.revoked") == []
      assert H.entries(ps, "platform.tenant_admin_grant.revoked") == []
    end

    test "with another open grant: :ok, no event" do
      w = H.world!()
      grant = H.create_grant!(w, "first@example.com")
      _other = H.create_grant!(w, "second@example.com")

      assert :ok =
               PendingAdminGrants.revoke(grant.id, %{user_id: w.operator_id}, write_opts(w, "t"))

      assert PendingAdminGrant.state(H.grant(w, grant.id)) == :revoked
      assert refusals(w.tenant.schema_name) == []
      assert refusals(w.platform.schema_name) == []
    end

    test "with a counted admin present: :ok, no event" do
      w = H.world!()
      ts = w.tenant.schema_name
      _admin = RSG.member!(ts, H.admin_group_id!(w), RSG.user!(ts))
      grant = H.create_grant!(w, "only@example.com")

      assert :ok =
               PendingAdminGrants.revoke(grant.id, %{user_id: w.operator_id}, write_opts(w, "t"))

      assert PendingAdminGrant.state(H.grant(w, grant.id)) == :revoked
      assert refusals(w.tenant.schema_name) == []
      assert refusals(w.platform.schema_name) == []
    end

    test "HTTP: DELETE /api/v1/onboarding/:id/pending-admins/:grant_id answers 409 last_tenant_wide_admin; the companion carries the operator and the request trace" do
      w = H.world!()
      record = H.onboarding_record!(w)
      grant = H.create_grant!(w, "http.last@example.com")
      token = Fixture.mint_token!(w.platform, ["PLATFORM_ADMIN"])

      operator_id =
        Repo.one!(
          from(u in User, where: like(u.username, "scope-caller-%"), select: u.id),
          prefix: w.platform.schema_name
        )

      ps_before = entry_ids(w.platform.schema_name)
      ts_before = entry_ids(w.tenant.schema_name)

      conn =
        :delete
        |> Fixture.api_conn(
          "/api/v1/onboarding/#{record.id}/pending-admins/#{grant.id}",
          token,
          w.platform.tenant.slug,
          nil
        )
        |> put_req_header("x-trace-id", @trace)
        |> Fixture.dispatch_api()

      assert conn.status == 409, conn.resp_body
      assert detail(conn) == "last_tenant_wide_admin"
      assert PendingAdminGrant.state(H.grant(w, grant.id)) == :open

      assert_only_refusal!(w.tenant.schema_name, ts_before, %{
        action: "revoke_pending_grant",
        target_id: grant.id,
        actor: nil,
        trace: nil
      })

      assert [platform_entry] = refusals(w.platform.schema_name)
      assert platform_entry.id not in ps_before

      assert_refusal_entry!(platform_entry, %{
        action: "revoke_pending_grant",
        target_id: grant.id,
        actor: operator_id,
        trace: @trace
      })
    end
  end

  # ===========================================================================================
  describe "T-G6 revoke_token (Option A)" do
    test "the owner is an admin only through the token: 409, token live and still authenticates, one revoke_token event" do
      fx = tenant!("req497-g6a")
      s = fx.schema_name
      {token, plaintext} = real_token!(fx, user!(fx, :active), ["TENANT_ADMIN"])
      assert count(fx) == 1
      before = entry_ids(s)

      conn = http(:delete, "/tokens/#{token.id}", fx, nil)

      assert conn.status == 409, conn.resp_body
      assert detail(conn) == "last_tenant_wide_admin"
      assert token_row(fx, token.id).revoked_at == nil
      assert {:ok, %{roles: ["TENANT_ADMIN"]}} = Identity.verify_api_token(plaintext, prefix: s)
      assert count(fx) == 1

      assert_only_refusal!(s, before, %{
        action: "revoke_token",
        target_id: token.id,
        actor: actor(conn),
        trace: @trace
      })
    end

    test "the owner is also in the TA group: 200, revoked, no event" do
      fx = tenant!("req497-g6b")
      owner = ta_member!(fx, :active)
      {token, _plaintext} = real_token!(fx, owner, ["TENANT_ADMIN"])

      conn = http(:delete, "/tokens/#{token.id}", fx, nil)

      assert conn.status == 200, conn.resp_body
      assert %DateTime{} = token_row(fx, token.id).revoked_at
      assert refusals(fx.schema_name) == []
    end

    test "a second token-only admin exists: 200, revoked, no event" do
      fx = tenant!("req497-g6c")
      {token, _plaintext} = real_token!(fx, user!(fx, :active), ["TENANT_ADMIN"])
      _other = raw_token!(fx, user!(fx, :active), ["TENANT_ADMIN"], %{})

      conn = http(:delete, "/tokens/#{token.id}", fx, nil)

      assert conn.status == 200, conn.resp_body
      assert %DateTime{} = token_row(fx, token.id).revoked_at
      assert count(fx) == 1
      assert refusals(fx.schema_name) == []
    end

    test "uncounted tokens in a 0-admin tenant revoke without a count: non-TA, EXPIRED TA, INACTIVE-owner TA (200, no event)" do
      fx = tenant!("req497-g6d")
      non_ta = raw_token!(fx, user!(fx, :active), ["PROCESS_DESIGNER"], %{})

      expired =
        raw_token!(fx, user!(fx, :active), ["TENANT_ADMIN"], %{expires_at: seconds_from_now(-60)})

      inactive_owner = user!(fx, :active)
      {inactive_token, _plaintext} = real_token!(fx, inactive_owner, ["TENANT_ADMIN"])

      {1, _} =
        Repo.update_all(
          from(u in User, where: u.id == ^inactive_owner.id),
          [set: [status: :inactive]],
          prefix: fx.schema_name
        )

      assert count(fx) == 0

      for token <- [non_ta, expired, inactive_token] do
        conn = http(:delete, "/tokens/#{token.id}", fx, nil)
        assert conn.status == 200, "#{token.name}: #{conn.status} #{conn.resp_body}"
        assert %DateTime{} = token_row(fx, token.id).revoked_at
      end

      assert refusals(fx.schema_name) == []
    end

    test "SEC A3: a transaction holding ONLY the TA tenant_role row FOR UPDATE blocks revoke_token/2 of a NON-TA token until it commits" do
      fx = tenant!("req497-g6e")
      s = fx.schema_name
      token = raw_token!(fx, user!(fx, :active), ["PROCESS_DESIGNER"], %{})

      holder = hold_binding_row(s, self())
      assert_receive {:binding_row_held, _prefix}, 5_000

      revoker = Task.async(fn -> Identity.revoke_token(token.id, prefix: s) end)

      try do
        assert lock_waiter?(~s("tenant_role")), "revoke_token/2 never queued on the binding row"
        assert Task.yield(revoker, 300) == nil
        assert token_row(fx, token.id).revoked_at == nil

        send(holder.pid, :release)
        assert {:ok, {:ok, :committed}} = Task.yield(holder, 5_000)
        assert {:ok, {:ok, %ApiToken{revoked_at: %DateTime{}}}} = Task.yield(revoker, 5_000)
      after
        stop_task(revoker)
        stop_task(holder)
      end
    end
  end

  # ===========================================================================================
  describe "T-G7 AC12: reactivation and pending-grant revoke take the tenant admin lock first" do
    test "update_user_status/3 (reactivation) waits for a held lock_tenant_admins!/1" do
      fx = tenant!("req497-g7a")
      s = fx.schema_name
      user = user!(fx, :inactive)

      holder = hold_admin_lock(s, self())
      assert_receive {:admin_lock_held, _prefix}, 5_000

      reactivator =
        Task.async(fn ->
          Identity.update_user_status(user.id, :active, prefix: s, login_directory: :skip)
        end)

      try do
        assert lock_waiter?("pg_advisory_xact_lock"), "reactivation never queued on lock A"
        assert Task.yield(reactivator, 300) == nil

        send(holder.pid, :release)
        assert {:ok, {:error, :released}} = Task.yield(holder, 5_000)
        assert {:ok, {:ok, _user}} = Task.yield(reactivator, 5_000)
        assert Repo.get!(User, user.id, prefix: s).status == :active
      after
        stop_task(reactivator)
        stop_task(holder)
      end
    end

    test "PendingAdminGrants.revoke/3 waits for a held lock_tenant_admins!/1" do
      w = H.world!()
      ts = w.tenant.schema_name
      _admin = RSG.member!(ts, H.admin_group_id!(w), RSG.user!(ts))
      grant = H.create_grant!(w, "locked@example.com")

      holder = hold_admin_lock(ts, self())
      assert_receive {:admin_lock_held, _prefix}, 5_000

      opts = [prefix: ts, platform_prefix: w.platform.schema_name, trace_id: "t-g7"]

      revoker =
        Task.async(fn -> PendingAdminGrants.revoke(grant.id, %{user_id: w.operator_id}, opts) end)

      try do
        assert lock_waiter?("pg_advisory_xact_lock"), "revoke/3 never queued on lock A"
        assert Task.yield(revoker, 300) == nil
        assert PendingAdminGrant.state(H.grant(w, grant.id)) == :open

        send(holder.pid, :release)
        assert {:ok, {:error, :released}} = Task.yield(holder, 5_000)
        assert {:ok, :ok} = Task.yield(revoker, 5_000)
        assert PendingAdminGrant.state(H.grant(w, grant.id)) == :revoked
      after
        stop_task(revoker)
        stop_task(holder)
      end
    end
  end

  # ===========================================================================================
  describe "T-G8 TenantAdminGuard helper preconditions" do
    test "refuse/3 inside an open transaction writes nothing (and still returns the error); outside, it writes one entry" do
      fx = tenant!("req497-g8a")
      s = fx.schema_name
      refusal = %{action: :revoke_token, target_id: Ecto.UUID.generate(), counted_admins: 0}
      ctx = %{actor_id: Ecto.UUID.generate(), trace_id: @trace, source: "api"}

      log =
        capture_log(fn ->
          assert {:ok, {:error, :last_tenant_wide_admin}} =
                   Repo.transaction(fn -> TenantAdminGuard.refuse(s, refusal, ctx) end)
        end)

      assert log =~ "tenant_admin_guard_refusal_not_recorded"
      assert refusals(s) == []

      assert {:error, :last_tenant_wide_admin} = TenantAdminGuard.refuse(s, refusal, ctx)
      assert [_one] = refusals(s)
    end

    test "ensure_admins_remain!/3, count_before!/1 and lock_admin_binding!/1 raise ArgumentError outside a transaction" do
      fx = tenant!("req497-g8b")
      s = fx.schema_name
      refute Repo.in_transaction?()

      assert_raise ArgumentError, fn ->
        TenantAdminGuard.ensure_admins_remain!(s, :revoke_token, Ecto.UUID.generate())
      end

      assert_raise ArgumentError, fn -> TenantAdminGuard.count_before!(s) end
      assert_raise ArgumentError, fn -> TenantAdminGuard.lock_admin_binding!(s) end
    end

    test "ensure_admins_remain!/4: transition rule (before 0 -> :ok without refusing; before > 0 and after 0 -> rollback) and state rule (:not_measured)" do
      fx = tenant!("req497-g8c")
      s = fx.schema_name
      assert count(fx) == 0
      expected = %{action: :rebind_tenant_admin, target_id: "t", counted_admins: 0}

      assert {:ok, :ok} =
               Repo.transaction(fn ->
                 TenantAdminGuard.ensure_admins_remain!(s, :rebind_tenant_admin, "t", 0)
               end)

      assert {:error, {:tenant_admin_guard, ^expected}} =
               Repo.transaction(fn ->
                 TenantAdminGuard.ensure_admins_remain!(s, :rebind_tenant_admin, "t", 1)
               end)

      assert {:error, {:tenant_admin_guard, %{action: :revoke_token, counted_admins: 0}}} =
               Repo.transaction(fn ->
                 TenantAdminGuard.ensure_admins_remain!(s, :revoke_token, "t")
               end)

      # With one counted admin, no rule refuses.
      _admin = ta_member!(fx, :active)

      assert {:ok, :ok} =
               Repo.transaction(fn ->
                 TenantAdminGuard.ensure_admins_remain!(s, :rebind_tenant_admin, "t", 1)
               end)

      assert {:ok, :ok} =
               Repo.transaction(fn ->
                 TenantAdminGuard.ensure_admins_remain!(s, :revoke_token, "t")
               end)

      # The helper itself never writes an event.
      assert refusals(s) == []
    end
  end

  # ===========================================================================================
  describe "T-G9 GH #2575: rebind_role/4 rescue" do
    test "function: a raise inside the transaction returns {:error, {:transaction_failed, _}} with binding, rows and audit unchanged" do
      {fx, role, a, b} = fault_setup("req497-g9a")
      s = fx.schema_name
      before = entry_ids(s)

      with_update_fault(s, fn ->
        assert {:error, {:transaction_failed, %Postgrex.Error{}}} =
                 RoleRegistry.rebind_role(role.id, b.id, %{actor_id: nil, reason: "fault"},
                   prefix: s
                 )
      end)

      assert RSG.binding(s, @fault_role).group_id == a.id
      assert RSG.rows(s) |> Enum.member?(RSG.tw(a.id, @fault_role))
      refute RSG.rows(s) |> Enum.member?(RSG.tw(b.id, @fault_role))
      assert new_entries(s, before) == []
    end

    test "router: POST /roles/:id/rebind under the same fault answers the internal_error body (500) with no crash report" do
      {fx, role, a, b} = fault_setup("req497-g9b")
      s = fx.schema_name
      before = entry_ids(s)

      log =
        capture_log(fn ->
          with_update_fault(s, fn ->
            conn =
              http(:post, "/roles/#{role.id}/rebind", fx, %{
                "group_id" => b.id,
                "reason" => "fault"
              })

            send(self(), {:rebind_conn, conn})
          end)
        end)

      assert_received {:rebind_conn, conn}
      assert conn.status == 500, conn.resp_body
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == 500
      refute conn.resp_body =~ "injected"
      refute conn.resp_body =~ b.id
      refute log =~ "** ("
      refute log =~ "Plug.ErrorHandler"
      assert RSG.binding(s, @fault_role).group_id == a.id
      assert new_entries(s, before) == []
    end
  end

  # ===========================================================================================
  test "T-G10 refuse/3,4 writes exactly the six contract keys per action with the 6.1 action string and resource type" do
    w = H.world!()
    ts = w.tenant.schema_name
    ps = w.platform.schema_name
    actor = Ecto.UUID.generate()
    ctx = %{actor_id: actor, trace_id: @trace, source: "api"}

    expected = [
      {:unbind_tenant_admin, "unbind_tenant_admin", "tenant_role"},
      {:remove_tenant_admin_member, "remove_tenant_admin_member", "group_member"},
      {:rebind_tenant_admin, "rebind_tenant_admin", "tenant_role"},
      {:revoke_token, "revoke_token", "api_token"},
      {:deactivate_user, "deactivate_user", "user"}
    ]

    for {action, action_string, resource_type} <- expected do
      target = Ecto.UUID.generate()
      before = entry_ids(ts)

      assert {:error, :last_tenant_wide_admin} =
               TenantAdminGuard.refuse(
                 ts,
                 %{action: action, target_id: target, counted_admins: 0},
                 ctx
               )

      entry =
        assert_only_refusal!(ts, before, %{
          action: action_string,
          target_id: target,
          actor: actor,
          trace: @trace
        })

      assert entry.resource_type == resource_type
    end

    # The pending-grant form: one entry per chain, operator only on the platform chain.
    target = Ecto.UUID.generate()
    ts_before = entry_ids(ts)
    ps_before = entry_ids(ps)

    assert {:error, :last_tenant_wide_admin} =
             TenantAdminGuard.refuse(
               ts,
               %{action: :revoke_pending_grant, target_id: target, counted_admins: 0},
               ctx,
               platform_companion: ps
             )

    tenant_entry =
      assert_only_refusal!(ts, ts_before, %{
        action: "revoke_pending_grant",
        target_id: target,
        actor: nil,
        trace: nil
      })

    platform_entry =
      assert_only_refusal!(ps, ps_before, %{
        action: "revoke_pending_grant",
        target_id: target,
        actor: actor,
        trace: @trace
      })

    assert tenant_entry.resource_type == "pending_admin_grant"
    assert platform_entry.resource_type == "pending_admin_grant"
    refute inspect(tenant_entry) =~ actor
  end
end
