defmodule Letflow.Identity.Gh2547TaAuditPathsTest do
  @moduledoc """
  GH 2547 (design `lib/letflow/design/gh2547-tenant-admin-audit-and-count.md`): the grant and
  removal paths of TENANT_ADMIN that are not plain `/identity` routes, plus the failure, lock and
  opt-out behaviour of the audited writes. Spec: `test/specs/GH-2547.md`.

    * AC1: T-10 (pending bind, trace), T-11 (IdP sync), T-12 (RoleBackfill marker reset),
      T-13 (TenantAdminMigration), T-19 (non-raising and raising audit failures roll back),
      T-19b (group-row lock pins), T-36 (pending bind under the tenant admin lock), SEC-A5
      (revoke re-reads under the lock), SEC-A6 (sync under the lock), `delete_group/2`.
    * AC2: T-15, T-16 (sync never strips a membership).
    * AC4: T-17 (the pending bind writes exactly its two events), T-18 (the opt-out and the source
      scan pinning its single caller), T-31 (seeding a fresh tenant writes no binding event).

  The HTTP-route paths (T-01..T-09, T-14) are in `test/letflow/routers/identity_gh2547_audit_test.exs`;
  the count helper and the lock key are in `test/letflow/identity/tenant_wide_admins_test.exs`.

  Real Postgres, real provisioned tenant schemas. Failure injection is real: a trigger on
  `audit_entries` that RAISES (so `Audit.insert_entry/3` raises), or a tenant schema renamed to a
  name that is not `tenant_<32 hex>` (so `Audit.insert_entry/3` returns
  `{:error, :invalid_schema_name}` without raising) and renamed back in an `after` block.
  Concurrency uses real separate connections (the tenant fixture leaves the sandbox in `:auto`);
  every wait is bounded and every task is stopped in an `after` block.

  `async: false`: schema renames, cross-connection locks, the platform pin, the OIDC verifier
  selection and the Logger metadata of a CLI run are all global or cross-process.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Letflow.Audit
  alias Letflow.Audit.Entry
  alias Letflow.Identity
  alias Letflow.Identity.ApiToken
  alias Letflow.Identity.Group
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.PendingAdminGrant
  alias Letflow.Identity.PendingAdminGrants
  alias Letflow.Identity.RoleBackfill
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.TenantAdminMigration
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User
  alias Letflow.Oidc.IdentityContext
  alias Letflow.Oidc.JitProvisioningConfig
  alias Letflow.Support.PendingAdminHelper, as: H
  alias Letflow.Support.PendingAdminTokenVerifierDouble, as: Double
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.TenantAdminMigrationFixture, as: Mig
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning.Registration

  @header_trace "gh2547-login-trace-0001"

  # --- fixtures --------------------------------------------------------------------------------

  # A provisioned tenant with the platform roles seeded (TENANT_ADMIN, PROCESS_DESIGNER, ...).
  defp tenant!(slug_prefix) do
    fx = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)
    {:ok, _roles} = RoleRegistry.seed_default_platform_role_groups(prefix: fx.schema_name)
    fx
  end

  defp group_of!(schema, role_name) do
    Repo.one!(from(t in TenantRole, where: t.name == ^role_name, select: t.group_id),
      prefix: schema
    )
  end

  defp user!(schema) do
    n = System.unique_integer([:positive])

    %User{}
    |> Ecto.Changeset.change(%{
      username: "gh2547-path-#{n}",
      display_name: "GH2547 Path #{n}",
      email: "gh2547-path-#{n}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema)
  end

  defp plain_group!(schema) do
    %Group{}
    |> Ecto.Changeset.change(%{name: "gh2547-pg-#{System.unique_integer([:positive])}"})
    |> Repo.insert!(prefix: schema)
  end

  defp raw_member!(schema, group_id, user) do
    Repo.insert!(%GroupMember{group_id: group_id, user_id: user.id}, prefix: schema)
    user
  end

  defp member?(schema, group_id, user_id) do
    Repo.exists?(from(m in GroupMember, where: m.group_id == ^group_id and m.user_id == ^user_id),
      prefix: schema
    )
  end

  defp memberships(schema, user_id) do
    Repo.all(from(m in GroupMember, where: m.user_id == ^user_id, select: m.group_id),
      prefix: schema
    )
  end

  defp entries(schema, action), do: H.entries(schema, action)

  defp entry_ids(schema), do: Repo.all(from(e in Entry, select: e.id), prefix: schema)

  defp new_entries(schema, ids_before) do
    Repo.all(from(e in Entry, where: e.id not in ^ids_before, order_by: e.timestamp),
      prefix: schema
    )
  end

  defp marker(schema, user_id), do: Repo.get!(User, user_id, prefix: schema).role_claims_synced_at

  defp uuid?(value), do: is_binary(value) and match?({:ok, _}, Ecto.UUID.cast(value))

  # The identity context a token carrying `roles` produces (all enforced keys, as
  # `PendingAdminHelper.identity_context/2` builds it).
  defp claims_context(roles) do
    sub = "sub-" <> Ecto.UUID.generate()

    %IdentityContext{
      external_user_id: sub,
      tenant_id: nil,
      realm: "gh2547-sync-realm",
      roles: roles,
      email: sub <> "@example.com",
      preferred_username: "user-" <> sub,
      display_name: "Display " <> sub,
      email_verified: true
    }
  end

  defp create_fault_trigger!(schema, name, condition) do
    Repo.query!(
      ~s|CREATE FUNCTION "#{schema}".#{name}() RETURNS trigger LANGUAGE plpgsql AS $$ | <>
        ~s|BEGIN IF #{condition} THEN RAISE EXCEPTION 'injected fault (GH 2547 test)'; END IF; | <>
        ~s|RETURN NEW; END $$|
    )

    Repo.query!(
      ~s|CREATE TRIGGER #{name} BEFORE INSERT ON "#{schema}".audit_entries | <>
        ~s|FOR EACH ROW EXECUTE FUNCTION "#{schema}".#{name}()|
    )
  end

  defp drop_fault_trigger!(schema, name) do
    Repo.query!(~s|DROP TRIGGER IF EXISTS #{name} ON "#{schema}".audit_entries|)
    Repo.query!(~s|DROP FUNCTION IF EXISTS "#{schema}".#{name}()|)
  end

  # Non-raising injection: every table is still there under the new name, but the prefix is no
  # longer `tenant_<32 hex>`, so `Audit.insert_entry/3` returns `{:error, :invalid_schema_name}`.
  # The rename is real (committed) DDL and is reversed in `after`, even when an assertion fails.
  defp with_renamed_schema(schema, fun) do
    "tenant_" <> hex = schema
    renamed = "gh2547_" <> hex
    Repo.query!(~s|ALTER SCHEMA "#{schema}" RENAME TO "#{renamed}"|)

    try do
      fun.(renamed)
    after
      Repo.query!(~s|ALTER SCHEMA "#{renamed}" RENAME TO "#{schema}"|)
    end
  end

  # RoleBackfill.run/0 and TenantAdminMigration.run/1 sweep EVERY registration: keep only
  # `keep` for this test and restore the others in on_exit (the `TenantAdminMigrationFixture`
  # pattern, for more than one kept tenant).
  defp isolate_registrations!(keep) do
    keep_ids = Enum.map(keep, & &1.tenant_id)

    others =
      Repo.all(
        from(r in Registration,
          where: r.tenant_id not in ^keep_ids,
          select: %{
            id: r.id,
            tenant_id: r.tenant_id,
            schema_name: r.schema_name,
            migrations_applied_at: r.migrations_applied_at,
            provisioned_at: r.provisioned_at
          }
        )
      )

    Repo.delete_all(from(r in Registration, where: r.id in ^Enum.map(others, & &1.id)))
    on_exit(fn -> Repo.insert_all(Registration, others, on_conflict: :nothing) end)
    :ok
  end

  # The real auth pipeline with a test-chosen-claims bearer token and an x-trace-id header.
  defp oidc_request(token, trace) do
    conn(:get, "/api/v1/identity/users")
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("x-trace-id", trace)
    |> Letflow.Router.call(Letflow.Router.init([]))
  end

  defp oidc_user!(w, sub) do
    Repo.one!(from(u in User, where: u.external_id == ^sub), prefix: w.tenant.schema_name)
  end

  # --- cross-connection lock helpers -----------------------------------------------------------

  # Bounded poll (at most ~5 s): true once some backend waits on a lock while running a
  # statement matching `pattern`.
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

  # A process that runs `locker` inside an open transaction, reports `:held`, and then waits for
  # `:release` (runs nothing) or `{:release, fun}` (runs `fun` in the same transaction) before
  # committing. It gives up on its own after 10 s.
  defp hold_in_transaction(locker) do
    parent = self()

    Task.async(fn ->
      Repo.transaction(fn ->
        locker.()
        send(parent, :held)

        receive do
          :release -> :released
          {:release, fun} -> fun.()
        after
          10_000 -> :gave_up
        end
      end)
    end)
  end

  defp stop_task(%Task{pid: pid} = task) do
    if Process.alive?(pid), do: Task.shutdown(task, :brutal_kill)
    :ok
  end

  # =============================================================================================
  # (c) pending-admin-grant bind -- T-10, T-17, T-36
  # =============================================================================================

  describe "pending-admin-grant first-login bind (path c)" do
    test "T-10 through the real pipeline: both bound entries carry the request's x-trace-id; payloads unchanged" do
      H.use_double!()
      w = H.world!()
      grant = H.create_grant!(w, "owner@example.com")
      sub = "sub-gh2547-t10"

      conn =
        w.realm
        |> Double.token(sub: sub, email: "owner@example.com", email_verified: true)
        |> oidc_request(@header_trace)

      assert conn.status < 500, conn.resp_body
      user = oidc_user!(w, sub)

      assert [tenant_entry] = entries(w.tenant.schema_name, "tenant.admin_grant.bound")

      assert [platform_entry] =
               entries(w.platform.schema_name, "platform.tenant_admin_grant.bound")

      assert tenant_entry.trace_id == @header_trace
      assert platform_entry.trace_id == @header_trace

      # The pre-change pins (pending_admin_binding_test.exs) are unchanged.
      assert tenant_entry.actor_id == user.id
      assert tenant_entry.resource_type == "pending_admin_grant"
      assert tenant_entry.resource_id == grant.id
      assert tenant_entry.before_state == nil

      assert tenant_entry.after_state == %{
               "grant_id" => grant.id,
               "role" => "TENANT_ADMIN",
               "bound_user_id" => user.id,
               "created_via" => "platform_operator_onboarding",
               "email_basis" => "verified_claim"
             }

      assert platform_entry.actor_id == user.id
      assert platform_entry.resource_id == grant.id

      assert platform_entry.after_state == %{
               "grant_id" => grant.id,
               "tenant_id" => w.tenant.tenant_id,
               "bound_user_id" => user.id
             }

      assert "TENANT_ADMIN" in H.roles(w, user.id)
    end

    test "T-17 AC4: the bind adds exactly tenant.admin_grant.bound to the tenant chain and platform.tenant_admin_grant.bound to the platform chain, no group_member.added" do
      w = H.world!()
      _grant = H.create_grant!(w, "owner@example.com")
      ctx = H.identity_context(w, sub: "sub-gh2547-t17", email: "owner@example.com")
      jit = JitProvisioningConfig.for_realm(w.realm)

      {:ok, provisioned} =
        Identity.provision_oidc_user(ctx, w.tenant.tenant_id, jit, prefix: w.tenant.schema_name)

      tenant_before = entry_ids(w.tenant.schema_name)
      platform_before = entry_ids(w.platform.schema_name)

      assert :bound =
               PendingAdminGrants.bind_on_login(H.tenant_row(w), provisioned, ctx, jit,
                 prefix: w.tenant.schema_name,
                 trace_id: "gh2547-t17-trace"
               )

      tenant_new = new_entries(w.tenant.schema_name, tenant_before)
      platform_new = new_entries(w.platform.schema_name, platform_before)

      assert Enum.map(tenant_new, & &1.action) == ["tenant.admin_grant.bound"]
      assert Enum.map(platform_new, & &1.action) == ["platform.tenant_admin_grant.bound"]
      assert Enum.all?(tenant_new ++ platform_new, &(&1.trace_id == "gh2547-t17-trace"))

      assert entries(w.tenant.schema_name, "group_member.added") == []
      assert member?(w.tenant.schema_name, H.admin_group_id!(w), provisioned.user.id)
      assert {:ok, :valid} = Audit.verify_chain(w.tenant.schema_name)
    end

    test "T-36 a held tenant admin lock makes the bind time out (lock_timeout 2s) into :noop; the grant stays open; the next login binds" do
      w = H.world!()
      grant = H.create_grant!(w, "owner@example.com")
      sub = "sub-gh2547-t36"

      holder = hold_in_transaction(fn -> Identity.lock_tenant_admins!(w.tenant.schema_name) end)
      assert_receive :held, 5_000

      try do
        {result, _log} =
          with_log(fn -> H.login(w, sub: sub, email: "owner@example.com", verified: true) end)

        assert %{result: :noop, provisioned: %{user: user}} = result
        assert PendingAdminGrant.state(H.grant(w, grant.id)) == :open
        assert H.grant(w, grant.id).email_key != nil
        assert marker(w.tenant.schema_name, user.id) == nil
        refute member?(w.tenant.schema_name, H.admin_group_id!(w), user.id)
        assert entries(w.tenant.schema_name, "tenant.admin_grant.bound") == []

        send(holder.pid, :release)
        assert {:ok, {:ok, :released}} = Task.yield(holder, 5_000)

        assert %{result: :bound} =
                 H.login(w, sub: sub, email: "owner@example.com", verified: true)

        assert PendingAdminGrant.state(H.grant(w, grant.id)) == :bound
        assert "TENANT_ADMIN" in H.roles(w, user.id)
      after
        stop_task(holder)
      end
    end
  end

  # =============================================================================================
  # (d) IdP role-claim sync -- T-11, T-15, T-16 (AC2), SEC-A6
  # =============================================================================================

  describe "IdP role-claim sync (path d)" do
    test "T-11 first OIDC login with a TA claim and a PROCESS_DESIGNER claim: one group_member.added per inserted row, actor = the user, source idp_sync, trace = header" do
      H.use_double!()
      w = H.world!()
      sub = "sub-gh2547-t11"
      unresolved_claim = "gh2547-unmapped-claim"

      conn =
        w.realm
        |> Double.token(
          sub: sub,
          email: "t11-person@example.com",
          roles: ["TENANT_ADMIN", "PROCESS_DESIGNER", unresolved_claim]
        )
        |> oidc_request(@header_trace)

      assert conn.status < 500, conn.resp_body
      user = oidc_user!(w, sub)
      schema = w.tenant.schema_name

      added = entries(schema, "group_member.added")
      assert length(added) == 2

      assert Enum.sort(Enum.map(added, & &1.after_state["group_id"])) ==
               Enum.sort([
                 group_of!(schema, "TENANT_ADMIN"),
                 group_of!(schema, "PROCESS_DESIGNER")
               ])

      for entry <- added do
        assert entry.actor_id == user.id
        assert entry.resource_type == "group_member"
        assert entry.resource_id == user.id
        assert entry.trace_id == @header_trace
        assert entry.after_state["source"] == "idp_sync"
        assert entry.after_state["member"] == true
        assert entry.before_state["member"] == false
      end

      gained = added |> Enum.flat_map(& &1.after_state["roles_gained"]) |> Enum.sort()
      assert gained == ["PROCESS_DESIGNER", "TENANT_ADMIN"]

      # No claim string other than a tenant_role name, and no user attribute, in any payload.
      encoded = Jason.encode!(Enum.map(added, &[&1.before_state, &1.after_state]))
      refute encoded =~ unresolved_claim
      refute encoded =~ sub
      refute encoded =~ "t11-person@example.com"
      refute encoded =~ user.username

      assert %DateTime{} = marker(schema, user.id)
      assert {:ok, :valid} = Audit.verify_chain(schema)
    end

    test "T-15 AC2 no-strip: a synced TA user whose next token lacks the claim keeps TENANT_ADMIN; that login writes no group_member event" do
      w = H.world!()
      schema = w.tenant.schema_name
      sub = "sub-gh2547-t15"

      %{provisioned: %{user: user}} =
        H.login(w, sub: sub, email: "t15@example.com", roles: ["TENANT_ADMIN"])

      assert %DateTime{} = marker(schema, user.id)
      assert "TENANT_ADMIN" in H.roles(w, user.id)
      assert [_one] = entries(schema, "group_member.added")

      %{provisioned: %{user: again, created: false}} =
        H.login(w, sub: sub, email: "t15@example.com", roles: ["PROCESS_DESIGNER"])

      assert again.id == user.id
      assert H.roles(w, user.id) == ["TENANT_ADMIN"]
      assert member?(schema, group_of!(schema, "TENANT_ADMIN"), user.id)
      assert [_still_one] = entries(schema, "group_member.added")
      assert entries(schema, "group_member.removed") == []
    end

    test "T-16 AC2: a manual TA member's first OIDC login with only a PROCESS_DESIGNER claim keeps TA and adds PROCESS_DESIGNER (one event), no removal" do
      w = H.world!()
      schema = w.tenant.schema_name
      sub = "sub-gh2547-t16"
      email = "t16@example.com"
      user = H.insert_user!(w, email: email, external_id: sub)
      ta_group = H.admin_group_id!(w)

      # The manual grant, through the route (marker still nil afterwards).
      conn =
        Letflow.Routers.Identity.call(
          Fixture.router_conn(:post, "/groups/#{ta_group}/members", w.tenant, ["TENANT_ADMIN"], %{
            "user_id" => user.id
          }),
          Letflow.Routers.Identity.init([])
        )

      assert conn.status == 201, conn.resp_body
      assert marker(schema, user.id) == nil

      %{provisioned: %{user: logged_in, created: false}} =
        H.login(w, sub: sub, email: email, roles: ["PROCESS_DESIGNER"])

      assert logged_in.id == user.id
      assert H.roles(w, user.id) |> Enum.sort() == ["PROCESS_DESIGNER", "TENANT_ADMIN"]
      assert member?(schema, ta_group, user.id)

      added = entries(schema, "group_member.added")
      assert length(added) == 2
      assert [sync_entry] = Enum.filter(added, &(&1.after_state["source"] == "idp_sync"))
      assert sync_entry.after_state["group_id"] == group_of!(schema, "PROCESS_DESIGNER")
      assert sync_entry.actor_id == user.id
      assert entries(schema, "group_member.removed") == []
    end

    test "SEC-A6 a held tenant admin lock makes the sync time out: the original user comes back, no membership, marker nil; the next sync works" do
      fx = tenant!("gh2547-seca6")
      user = user!(fx.schema_name)
      ctx = claims_context(["TASK_WORKER"])

      holder = hold_in_transaction(fn -> Identity.lock_tenant_admins!(fx.schema_name) end)
      assert_receive :held, 5_000

      try do
        {result, log} =
          with_log(fn ->
            Identity.sync_role_claims_from_token(user, ctx, prefix: fx.schema_name)
          end)

        assert result == user
        assert memberships(fx.schema_name, user.id) == []
        assert marker(fx.schema_name, user.id) == nil

        own = log |> String.split("\n") |> Enum.filter(&(&1 =~ "sync_role_claims_from_token/3"))
        assert Enum.any?(own, &(&1 =~ "Postgrex.Error"))
        refute Enum.any?(own, &(&1 =~ "lock timeout"))

        send(holder.pid, :release)
        assert {:ok, {:ok, :released}} = Task.yield(holder, 5_000)

        synced = Identity.sync_role_claims_from_token(user, ctx, prefix: fx.schema_name)
        assert %DateTime{} = synced.role_claims_synced_at
        assert memberships(fx.schema_name, user.id) == [group_of!(fx.schema_name, "TASK_WORKER")]
      after
        stop_task(holder)
      end
    end
  end

  # =============================================================================================
  # (d') RoleBackfill marker reset -- T-12, T-31, T-19 (marker reset raise)
  # =============================================================================================

  describe "RoleBackfill marker reset (path d')" do
    test "T-12 a :seeded tenant gets one role_claims_sync.reset (2 marked users, 3 reset, run trace); an :unchanged tenant none; return shape unchanged" do
      seeded = TenantFixture.provisioned_tenant!(slug_prefix: "gh2547-t12s")
      unchanged = tenant!("gh2547-t12u")
      isolate_registrations!([seeded, unchanged])

      stamp = DateTime.utc_now() |> DateTime.add(-3_600, :second)

      [m1, m2, never] =
        for _ <- 1..3, do: user!(seeded.schema_name)

      for u <- [m1, m2] do
        u
        |> Ecto.Changeset.change(role_claims_synced_at: stamp)
        |> Repo.update!(prefix: seeded.schema_name)
      end

      kept = user!(unchanged.schema_name)

      kept
      |> Ecto.Changeset.change(role_claims_synced_at: stamp)
      |> Repo.update!(prefix: unchanged.schema_name)

      Logger.metadata(trace_id: "gh2547-caller-trace")

      assert {:ok, result} = RoleBackfill.run()

      assert Enum.sort(Map.keys(result)) == [
               :role_claims_markers_reset,
               :seeded,
               :skipped_enforced,
               :unchanged
             ]

      assert result.seeded == [seeded.tenant_id]
      assert result.unchanged == [unchanged.tenant_id]
      assert result.role_claims_markers_reset == 3

      assert [entry] = entries(seeded.schema_name, "role_claims_sync.reset")
      assert entry.actor_id == nil
      assert entry.resource_type == "tenant"
      assert entry.resource_id == seeded.tenant_id
      assert uuid?(entry.trace_id)
      refute entry.trace_id == "gh2547-caller-trace"

      assert entry.before_state == %{
               "users_with_marker" => Enum.sort([m1.id, m2.id]),
               "count" => 2
             }

      assert entry.after_state == %{
               "reset_user_ids" => Enum.sort([m1.id, m2.id, never.id]),
               "reset_count" => 3,
               "revocation_honored_user_ids" => [],
               "revocation_honored_count" => 0,
               "source" => "role_backfill",
               "effect" => "next_login_resyncs_idp_role_claims"
             }

      for u <- [m1, m2, never], do: assert(marker(seeded.schema_name, u.id) == nil)

      # The :unchanged tenant: no event, marker kept.
      assert entries(unchanged.schema_name, "role_claims_sync.reset") == []
      refute marker(unchanged.schema_name, kept.id) == nil

      # with_trace/1 gave the caller's trace back.
      assert Logger.metadata()[:trace_id] == "gh2547-caller-trace"

      # T-31: seeding a tenant's (empty) platform-role groups wrote no binding event.
      assert entries(seeded.schema_name, "role_binding.created") == []
      assert {:ok, :valid} = Audit.verify_chain(seeded.schema_name)
    end

    test "T-19 a raising reset audit returns {:backfill_failed, tid, {:unexpected_exception, %Postgrex.Error{}}} and leaves every marker unchanged" do
      fx = TenantFixture.provisioned_tenant!(slug_prefix: "gh2547-t19rb")
      isolate_registrations!([fx])
      tid = fx.tenant_id

      stamp = DateTime.utc_now() |> DateTime.add(-600, :second) |> DateTime.truncate(:microsecond)
      user = user!(fx.schema_name)

      user
      |> Ecto.Changeset.change(role_claims_synced_at: stamp)
      |> Repo.update!(prefix: fx.schema_name)

      create_fault_trigger!(
        fx.schema_name,
        "gh2547_fail_reset",
        "NEW.action = 'role_claims_sync.reset'"
      )

      try do
        assert {:error, {:backfill_failed, ^tid, {:unexpected_exception, %Postgrex.Error{}}}} =
                 RoleBackfill.run()

        assert marker(fx.schema_name, user.id) == stamp
        assert entries(fx.schema_name, "role_claims_sync.reset") == []
      after
        drop_fault_trigger!(fx.schema_name, "gh2547_fail_reset")
      end
    end

    test "T-31 seeding the platform roles of a fresh tenant writes no role_binding.created" do
      fx = TenantFixture.provisioned_tenant!(slug_prefix: "gh2547-t31")
      {:ok, roles} = RoleRegistry.seed_default_platform_role_groups(prefix: fx.schema_name)

      assert "TENANT_ADMIN" in Enum.map(roles, & &1.name)
      assert entries(fx.schema_name, "role_binding.created") == []
      assert entries(fx.schema_name, "role_binding.kind_changed") == []
    end
  end

  # =============================================================================================
  # (e) TenantAdminMigration -- T-13
  # =============================================================================================

  test "T-13 every entry of a migration run shares one generated trace, actor nil; a populated TA group without binding gets role_binding.created; payload pins unchanged" do
    p = Mig.operator_tenant!()
    a = Mig.tenant!("gh2547-t13")
    %{users: [legacy_user]} = Mig.legacy!(a, 1)
    ta_group = Mig.group!(a.schema_name, "TENANT_ADMIN")
    pre_member = Mig.member!(a.schema_name, ta_group, Mig.new_user!(a.schema_name))
    token = Mig.token!(a.schema_name, legacy_user, ["PLATFORM_ADMIN"])

    ids_before = entry_ids(a.schema_name)
    Logger.metadata(trace_id: "gh2547-operator-trace")

    assert {:ok, report} = TenantAdminMigration.run(Mig.good_opts(p))
    assert [_rep] = Enum.filter(report.migrated, &(&1.tenant_id == a.tenant_id))

    new = new_entries(a.schema_name, ids_before)

    assert Enum.sort(Enum.uniq(Enum.map(new, & &1.action))) ==
             [
               "group_member.copied",
               "role_binding.created",
               "role_binding.removed",
               "token.roles_migrated"
             ]

    [trace] = new |> Enum.map(& &1.trace_id) |> Enum.uniq()
    assert uuid?(trace)
    refute trace == "gh2547-operator-trace"
    assert Enum.all?(new, &(&1.actor_id == nil))
    assert Logger.metadata()[:trace_id] == "gh2547-operator-trace"

    assert [created] = Enum.filter(new, &(&1.action == "role_binding.created"))
    assert created.resource_type == "tenant_role"
    assert created.before_state == nil

    assert created.after_state == %{
             "name" => "TENANT_ADMIN",
             "kind" => "platform_role",
             "group_id" => ta_group.id,
             "granted_user_ids" => [pre_member.id],
             "granted_count" => 1,
             "source" => "tenant_admin_migration"
           }

    # The pre-change payloads (tenant_admin_migration_test.exs) are unchanged.
    assert [copied] = Enum.filter(new, &(&1.action == "group_member.copied"))
    assert copied.resource_id == legacy_user.id
    assert copied.before_state == nil
    assert copied.after_state == %{"user_id" => legacy_user.id}

    assert [removed] = Enum.filter(new, &(&1.action == "role_binding.removed"))
    assert removed.before_state == %{"name" => "PLATFORM_ADMIN"}
    assert removed.after_state == nil

    assert [migrated] = Enum.filter(new, &(&1.action == "token.roles_migrated"))
    assert migrated.resource_id == token.id
    assert migrated.after_state == %{"roles" => ["TENANT_ADMIN"]}

    assert {:ok, :valid} = Audit.verify_chain(a.schema_name)
  end

  # =============================================================================================
  # T-18 -- the opt-out and the source scan pinning its single caller
  # =============================================================================================

  describe "T-18 group_member_audit: :caller_audits" do
    test "outside a transaction it is refused before any write" do
      fx = tenant!("gh2547-t18a")
      ta_group = group_of!(fx.schema_name, "TENANT_ADMIN")
      user = user!(fx.schema_name)

      refute Repo.in_transaction?()

      assert {:error, :caller_audit_requires_transaction} =
               Identity.add_group_member(ta_group, user.id,
                 prefix: fx.schema_name,
                 group_member_audit: :caller_audits
               )

      refute member?(fx.schema_name, ta_group, user.id)
      assert entries(fx.schema_name, "group_member.added") == []
    end

    test "inside a transaction the row is written and no group_member.added is" do
      fx = tenant!("gh2547-t18b")
      ta_group = group_of!(fx.schema_name, "TENANT_ADMIN")
      user = user!(fx.schema_name)

      assert {:ok, {:ok, %{created: true}}} =
               Repo.transaction(fn ->
                 Identity.add_group_member(ta_group, user.id,
                   prefix: fx.schema_name,
                   group_member_audit: :caller_audits
                 )
               end)

      assert member?(fx.schema_name, ta_group, user.id)
      assert entries(fx.schema_name, "group_member.added") == []
    end

    test "an unknown value (:bogus) or the default is treated as :emit: one event each" do
      fx = tenant!("gh2547-t18c")
      ta_group = group_of!(fx.schema_name, "TENANT_ADMIN")
      u1 = user!(fx.schema_name)
      u2 = user!(fx.schema_name)

      assert {:ok, %{created: true}} =
               Identity.add_group_member(ta_group, u1.id,
                 prefix: fx.schema_name,
                 group_member_audit: :bogus
               )

      assert {:ok, %{created: true}} =
               Identity.add_group_member(ta_group, u2.id, prefix: fx.schema_name)

      assert entries(fx.schema_name, "group_member.added")
             |> Enum.map(& &1.resource_id)
             |> Enum.sort() == Enum.sort([u1.id, u2.id])
    end

    test "source scan: the key appears only in identity.ex and pending_admin_grants.ex, where it is exactly once the literal :caller_audits" do
      lib = Path.expand("../../../lib", __DIR__)
      design = Path.join(lib, "letflow/design")

      files =
        lib
        |> Path.join("**/*.ex")
        |> Path.wildcard()
        |> Enum.reject(&String.starts_with?(&1, design <> "/"))

      assert length(files) > 50, "the scan found too few lib files: #{length(files)}"

      mentioning =
        files
        |> Enum.filter(&(File.read!(&1) =~ "group_member_audit"))
        |> Enum.map(&Path.relative_to(&1, lib))
        |> Enum.sort()

      assert mentioning == ["letflow/identity.ex", "letflow/identity/pending_admin_grants.ex"]

      source = File.read!(Path.join(lib, "letflow/identity/pending_admin_grants.ex"))
      all = Regex.scan(~r/group_member_audit/, source)
      literal = Regex.scan(~r/(?<![:\w])group_member_audit:\s*:caller_audits(?![\w?!@])/, source)

      assert length(all) == 1,
             "pending_admin_grants.ex mentions group_member_audit #{length(all)} times"

      assert length(literal) == 1,
             "the opt-out value in pending_admin_grants.ex is not the literal :caller_audits"
    end
  end

  # =============================================================================================
  # T-19 -- audit failures roll the write back (context level)
  # =============================================================================================

  describe "T-19 non-raising audit failure ({:error, :invalid_schema_name}) rolls back" do
    test "add_group_member/3 -> {:audit_failed, :invalid_schema_name}, no row" do
      fx = tenant!("gh2547-t19a")
      ta_group = group_of!(fx.schema_name, "TENANT_ADMIN")
      user = user!(fx.schema_name)

      result =
        with_renamed_schema(fx.schema_name, fn renamed ->
          Identity.add_group_member(ta_group, user.id, prefix: renamed)
        end)

      assert result == {:error, {:audit_failed, :invalid_schema_name}}
      refute member?(fx.schema_name, ta_group, user.id)
      assert entries(fx.schema_name, "group_member.added") == []
    end

    test "remove_group_member/3 -> {:audit_failed, :invalid_schema_name}, row kept" do
      fx = tenant!("gh2547-t19b")
      ta_group = group_of!(fx.schema_name, "TENANT_ADMIN")
      user = raw_member!(fx.schema_name, ta_group, user!(fx.schema_name))
      # REQ-497 PR 1b N1: a second counted admin, so the N1 guard passes and the audit fails.
      _remaining_admin = raw_member!(fx.schema_name, ta_group, user!(fx.schema_name))

      result =
        with_renamed_schema(fx.schema_name, fn renamed ->
          Identity.remove_group_member(ta_group, user.id, prefix: renamed)
        end)

      assert result == {:error, {:audit_failed, :invalid_schema_name}}
      assert member?(fx.schema_name, ta_group, user.id)
      assert entries(fx.schema_name, "group_member.removed") == []
    end

    test "upsert_role/4 over a populated group -> {:audit_failed, :invalid_schema_name}, no binding" do
      fx = tenant!("gh2547-t19c")
      group = plain_group!(fx.schema_name)
      _member = raw_member!(fx.schema_name, group.id, user!(fx.schema_name))
      name = "gh2547-approver-#{System.unique_integer([:positive])}"

      result =
        with_renamed_schema(fx.schema_name, fn renamed ->
          RoleRegistry.upsert_role(name, :process_routing_role, group.id, prefix: renamed)
        end)

      assert result == {:error, {:audit_failed, :invalid_schema_name}}
      assert Repo.get_by(TenantRole, [name: name], prefix: fx.schema_name) == nil
    end

    test "sync (iii): the original user comes back, no membership, marker nil" do
      fx = tenant!("gh2547-t19d")
      user = user!(fx.schema_name)

      {result, _log} =
        with_log(fn ->
          with_renamed_schema(fx.schema_name, fn renamed ->
            Identity.sync_role_claims_from_token(user, claims_context(["TASK_WORKER"]),
              prefix: renamed
            )
          end)
        end)

      assert result == user
      assert memberships(fx.schema_name, user.id) == []
      assert marker(fx.schema_name, user.id) == nil
    end
  end

  describe "T-19 raising audit failure in the IdP sync" do
    test "(i) a raise on the first audit: the original user, no membership, marker nil, no exception message logged" do
      fx = tenant!("gh2547-t19e")
      user = user!(fx.schema_name)

      create_fault_trigger!(
        fx.schema_name,
        "gh2547_fail_sync",
        "NEW.action = 'group_member.added'"
      )

      try do
        {result, log} =
          with_log(fn ->
            Identity.sync_role_claims_from_token(user, claims_context(["TASK_WORKER"]),
              prefix: fx.schema_name
            )
          end)

        assert result == user
        assert memberships(fx.schema_name, user.id) == []
        assert marker(fx.schema_name, user.id) == nil

        own = log |> String.split("\n") |> Enum.filter(&(&1 =~ "sync_role_claims_from_token/3"))
        assert Enum.any?(own, &(&1 =~ "Postgrex.Error"))
        refute Enum.any?(own, &(&1 =~ "injected fault"))
      after
        drop_fault_trigger!(fx.schema_name, "gh2547_fail_sync")
      end
    end

    test "(ii) SEC-A3: the SECOND group's audit raises after the first insert and audit: neither membership remains; with the fault gone both are written" do
      fx = tenant!("gh2547-t19f")
      schema = fx.schema_name
      user = user!(schema)
      ctx = claims_context(["TASK_WORKER", "PROCESS_DESIGNER"])

      # Raises only when an earlier group_member.added for the same user is already visible in
      # this transaction, i.e. exactly on the second one.
      create_fault_trigger!(
        schema,
        "gh2547_fail_second",
        ~s|NEW.action = 'group_member.added' AND EXISTS (SELECT 1 FROM "#{schema}".audit_entries a | <>
          ~s|WHERE a.action = 'group_member.added' AND a.resource_id = NEW.resource_id)|
      )

      try do
        {result, _log} =
          with_log(fn -> Identity.sync_role_claims_from_token(user, ctx, prefix: schema) end)

        assert result == user
        assert memberships(schema, user.id) == []
        assert marker(schema, user.id) == nil
        assert entries(schema, "group_member.added") == []
      after
        drop_fault_trigger!(schema, "gh2547_fail_second")
      end

      # Control: the same claims sync both groups once the fault is gone.
      synced = Identity.sync_role_claims_from_token(user, ctx, prefix: schema)
      assert %DateTime{} = synced.role_claims_synced_at
      assert length(memberships(schema, user.id)) == 2
      assert length(entries(schema, "group_member.added")) == 2
    end
  end

  # =============================================================================================
  # T-19b -- lock pins (group row)
  # =============================================================================================

  describe "T-19b the group row serialises membership changes with binding writes" do
    test "a group held FOR UPDATE blocks add_group_member/3 (FK KEY SHARE) and remove_group_member/3 (explicit KEY SHARE) until released" do
      fx = tenant!("gh2547-t19ba")
      schema = fx.schema_name
      group = plain_group!(schema)
      newcomer = user!(schema)
      leaver = raw_member!(schema, group.id, user!(schema))

      holder =
        hold_in_transaction(fn ->
          Repo.one!(from(g in Group, where: g.id == ^group.id, lock: "FOR UPDATE"),
            prefix: schema
          )
        end)

      assert_receive :held, 5_000

      adder =
        Task.async(fn -> Identity.add_group_member(group.id, newcomer.id, prefix: schema) end)

      try do
        assert lock_waiter?("group_members"), "add_group_member/3 never queued on the group row"
        assert Task.yield(adder, 300) == nil

        send(holder.pid, :release)
        assert {:ok, {:ok, :released}} = Task.yield(holder, 5_000)
        assert {:ok, {:ok, %{created: true}}} = Task.yield(adder, 5_000)
      after
        stop_task(adder)
        stop_task(holder)
      end

      holder =
        hold_in_transaction(fn ->
          Repo.one!(from(g in Group, where: g.id == ^group.id, lock: "FOR UPDATE"),
            prefix: schema
          )
        end)

      assert_receive :held, 5_000

      remover =
        Task.async(fn -> Identity.remove_group_member(group.id, leaver.id, prefix: schema) end)

      try do
        assert lock_waiter?("FOR KEY SHARE"),
               "remove_group_member/3 never queued on the group row"

        assert Task.yield(remover, 300) == nil

        send(holder.pid, :release)
        assert {:ok, {:ok, :released}} = Task.yield(holder, 5_000)
        assert {:ok, :ok} = Task.yield(remover, 5_000)
        refute member?(schema, group.id, leaver.id)
      after
        stop_task(remover)
        stop_task(holder)
      end
    end

    test "a binding written in an open transaction blocks a member add until commit; the add then records the new role in group_roles" do
      fx = tenant!("gh2547-t19bb")
      schema = fx.schema_name
      group = plain_group!(schema)
      user = user!(schema)
      role_name = "gh2547-approver-#{System.unique_integer([:positive])}"

      binder =
        hold_in_transaction(fn ->
          {:ok, _role} =
            RoleRegistry.upsert_role(role_name, :process_routing_role, group.id, prefix: schema)
        end)

      assert_receive :held, 5_000

      adder = Task.async(fn -> Identity.add_group_member(group.id, user.id, prefix: schema) end)

      try do
        assert lock_waiter?("pg_advisory_xact_lock"), "add_group_member/3 never queued"
        assert Task.yield(adder, 300) == nil

        send(binder.pid, :release)
        assert {:ok, {:ok, :released}} = Task.yield(binder, 5_000)
        assert {:ok, {:ok, %{created: true}}} = Task.yield(adder, 5_000)
      after
        stop_task(adder)
        stop_task(binder)
      end

      assert [entry] = entries(schema, "group_member.added")

      assert entry.after_state["group_roles"] == [
               %{"name" => role_name, "kind" => "process_routing_role"}
             ]
    end
  end

  # =============================================================================================
  # Section 10c -- SEC-A5 (revoke under the lock) and delete_group/2
  # =============================================================================================

  test "SEC-A5 a token revoked concurrently while revoke_token/2 waits for the lock is returned unchanged with no token.revoke event" do
    fx = tenant!("gh2547-seca5")
    schema = fx.schema_name
    owner = user!(schema)

    {:ok, %{token: token}} =
      Identity.create_token(owner.id, %{roles: ["TENANT_ADMIN"], expires_at: nil}, prefix: schema)

    concurrent_revoked_at =
      DateTime.utc_now() |> DateTime.add(-30, :second) |> DateTime.truncate(:second)

    holder = hold_in_transaction(fn -> Identity.lock_tenant_admins!(schema) end)
    assert_receive :held, 5_000

    revoker = Task.async(fn -> Identity.revoke_token(token.id, prefix: schema) end)

    try do
      assert lock_waiter?("pg_advisory_xact_lock"), "revoke_token/2 never queued on the lock"

      # The lock holder revokes the token itself, then commits.
      send(
        holder.pid,
        {:release,
         fn ->
           Repo.update_all(
             from(t in ApiToken, where: t.id == ^token.id),
             [set: [revoked_at: concurrent_revoked_at]],
             prefix: schema
           )
         end}
      )

      assert {:ok, {:ok, {1, _}}} = Task.yield(holder, 5_000)
      assert {:ok, {:ok, %ApiToken{} = returned}} = Task.yield(revoker, 5_000)
      assert returned.revoked_at == concurrent_revoked_at
    after
      stop_task(revoker)
      stop_task(holder)
    end

    assert entries(schema, "token.revoke") == []
    assert Repo.get!(ApiToken, token.id, prefix: schema).revoked_at == concurrent_revoked_at
  end

  test "delete_group/2 under its new transaction keeps its results: :ok, :not_found_or_has_members, :bound_to_role" do
    fx = tenant!("gh2547-delgrp")
    schema = fx.schema_name

    empty = plain_group!(schema)
    assert :ok = Identity.delete_group(empty.id, prefix: schema)

    populated = plain_group!(schema)
    raw_member!(schema, populated.id, user!(schema))

    assert {:error, :not_found_or_has_members} =
             Identity.delete_group(populated.id, prefix: schema)

    bound = plain_group!(schema)

    bound_name = "gh2547-bound-#{System.unique_integer([:positive])}"

    {:ok, _role} =
      RoleRegistry.upsert_role(bound_name, :process_routing_role, bound.id, prefix: schema)

    assert {:error, :bound_to_role} = Identity.delete_group(bound.id, prefix: schema)
    assert Repo.get(Group, bound.id, prefix: schema)
  end
end
