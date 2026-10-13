defmodule Letflow.Identity.PendingAdminBindingTest do
  @moduledoc """
  ISS-1030 PR 2 -- `Letflow.Identity.PendingAdminGrants.bind_on_login/5`, the first-login
  binding of a pending tenant-administrator grant (design section 7; decision 0048).

  Real Postgres, real tenant schemas. Every "login" here is the shipped path minus HTTP:
  `Identity.provision_oidc_user/4` (JIT) followed by `bind_on_login/5` with the realm's real
  `JitProvisioningConfig` (`Letflow.Support.PendingAdminHelper.login/2`); the full-pipeline
  cases (the very request that binds already sees `TENANT_ADMIN`, byte-identical responses) are in
  `test/letflow/plugs/pending_admin_login_response_test.exs`.

  Concurrency tests follow `tenant_realm_bind_test.exs`: a lock-holder (a raw `FOR UPDATE` in an
  open transaction) forces the interleaving and `pg_stat_activity` is polled until every binder
  is actually blocked, so no sleep is involved.

  Failure injection is real, not stubbed: a Postgres trigger that raises on one action, a
  platform prefix that names no schema, a dropped table, a deleted role binding.

  `async: false`: the fixture flips the sandbox to `:auto`, and the platform pin, the OIDC
  config and the logger level are VM-global.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit.ChainLock
  alias Letflow.Identity
  alias Letflow.Identity.PendingAdminGrant
  alias Letflow.Identity.PendingAdminGrants
  alias Letflow.Identity.PendingAdminGrants.FaultThrottle
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User
  alias Letflow.Oidc.JitProvisioningConfig
  alias Letflow.Support.PendingAdminHelper, as: H
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  setup do
    %{w: H.world!()}
  end

  # --- helpers ---------------------------------------------------------------

  defp user!(w, user_id), do: Repo.get!(User, user_id, prefix: w.tenant.schema_name)

  # `bind_on_login/5` on a row that did not come through JIT (an inactive user, a user whose
  # stored e-mail is empty), with the context a token for that user would carry.
  defp bind_raw(w, user, attrs) do
    ctx = H.identity_context(w, [sub: user.external_id, username: user.username] ++ attrs)
    jit = JitProvisioningConfig.for_realm(w.realm)

    PendingAdminGrants.bind_on_login(
      H.tenant_row(w),
      %{user: user, created: true},
      ctx,
      jit,
      prefix: w.tenant.schema_name
    )
  end

  defp assert_untouched(w, grant) do
    stored = H.grant(w, grant.id)
    assert PendingAdminGrant.state(stored) == :open
    assert stored.email_key != nil
    assert stored.consumed_by_user_id == nil
    assert H.member_count(w) == 0
    assert H.entries(w.tenant.schema_name, "tenant.admin_grant.bound") == []
    assert H.entries(w.platform.schema_name, "platform.tenant_admin_grant.bound") == []
  end

  defp assert_bound(w, grant, user_id) do
    stored = H.grant(w, grant.id)
    assert PendingAdminGrant.state(stored) == :bound
    assert stored.consumed_by_user_id == user_id
    assert "TENANT_ADMIN" in H.roles(w, user_id)
  end

  defp create_trigger!(w, name, table, event, condition) do
    schema = w.tenant.schema_name

    Repo.query!(
      ~s|CREATE FUNCTION "#{schema}".#{name}() RETURNS trigger LANGUAGE plpgsql AS $$ | <>
        ~s|BEGIN IF #{condition} THEN RAISE EXCEPTION 'injected fault (ISS-1030 test)'; END IF; | <>
        ~s|RETURN NEW; END $$|
    )

    Repo.query!(
      ~s|CREATE TRIGGER #{name} BEFORE #{event} ON "#{schema}".#{table} | <>
        ~s|FOR EACH ROW EXECUTE FUNCTION "#{schema}".#{name}()|
    )
  end

  defp drop_trigger!(w, name, table) do
    Repo.query!(~s|DROP TRIGGER #{name} ON "#{w.tenant.schema_name}".#{table}|)
  end

  # Lines Letflow's own code logged about the bind (Ecto's SQL debug lines carry query
  # parameters, which is Ecto's, not this feature's, output).
  defp own_lines(log) do
    log |> String.split("\n") |> Enum.filter(&(&1 =~ "pending administrator"))
  end

  defp fault_lines(log, tenant_id) do
    log
    |> String.split("\n")
    |> Enum.filter(&(&1 =~ "pending administrator bind failed (tenant_id=#{inspect(tenant_id)})"))
  end

  defp hold_row_lock(w, grant_id, parent) do
    schema = w.tenant.schema_name

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.one!(from(g in PendingAdminGrant, where: g.id == ^grant_id, lock: "FOR UPDATE"),
            prefix: schema
          )

          send(parent, :locked)

          receive do
            :release -> :released
          end
        end)
      end)

    assert_receive :locked, 10_000
    holder
  end

  # --- the happy path --------------------------------------------------------

  test "binds when a verified e-mail equals the pending key through the tenant's own realm",
       %{w: w} do
    grant = H.create_grant!(w, "owner@example.com")

    %{result: result, provisioned: %{user: user, created: created}} =
      H.login(w, email: "owner@example.com", verified: true)

    assert result == :bound
    assert created == true
    assert_bound(w, grant, user.id)

    # Both audit entries exist, in the one transaction (more in the atomicity tests below).
    assert [_] = H.entries(w.tenant.schema_name, "tenant.admin_grant.bound")
    assert [_] = H.entries(w.platform.schema_name, "platform.tenant_admin_grant.bound")
  end

  test "the bound user holds TENANT_ADMIN and no other group membership", %{w: w} do
    _grant = H.create_grant!(w, "owner@example.com")

    # A claim naming a second role would be synced by the claim path; this user claims nothing,
    # so the ONLY membership the bind itself can add is the one the grant row allows.
    %{result: :bound, provisioned: %{user: user}} = H.login(w, email: "owner@example.com")

    assert H.memberships(w, user.id) == ["TENANT_ADMIN"]
    assert H.member_count(w) == 1
    assert H.roles(w, user.id) == ["TENANT_ADMIN"]
    refute "PLATFORM_ADMIN" in H.roles(w, user.id)

    # The table itself cannot hold anything but TENANT_ADMIN (CHECK constraint, migration test).
    assert H.grant(w, hd(H.grants(w)).id).role_name == "TENANT_ADMIN"
  end

  test "a user created in this request whose stored e-mail equals the claim e-mail binds",
       %{w: w} do
    grant = H.create_grant!(w, "owner@example.com")

    %{result: result, provisioned: %{user: user, created: true}} =
      H.login(w, email: "Owner@Example.com ", verified: true)

    assert result == :bound
    # Stored as the claim carried it; equality is decided after the shared trim + lower-case.
    assert user.email == "Owner@Example.com "
    assert_bound(w, grant, user.id)
  end

  # --- what must NOT bind ----------------------------------------------------

  test "an unverified e-mail does not bind", %{w: w} do
    grant = H.create_grant!(w, "owner@example.com")

    assert %{result: :noop} = H.login(w, email: "owner@example.com", verified: false)
    assert_untouched(w, grant)

    # Through the real claim mapping: the JSON boolean false.
    assert %{result: :noop} =
             H.login_from_claims(w, %{"email" => "owner@example.com", "email_verified" => false})

    assert_untouched(w, grant)
  end

  test "an email_verified claim of the string true does not bind", %{w: w} do
    grant = H.create_grant!(w, "owner@example.com")
    # One person throughout (a second account with the same address would be a duplicate holder).
    sub = "sub-string-true"

    for value <- ["true", "TRUE", 1, "yes", ["true"], %{"v" => true}] do
      assert %{result: :noop, ctx: ctx} =
               H.login_from_claims(w, %{
                 "sub" => sub,
                 "email" => "owner@example.com",
                 "email_verified" => value
               })

      assert ctx.email_verified == false, inspect(value)
    end

    assert_untouched(w, grant)

    # Control: the JSON boolean true, same person, same address, same path, binds.
    assert %{result: :bound} =
             H.login_from_claims(w, %{
               "sub" => sub,
               "email" => "owner@example.com",
               "email_verified" => true
             })

    assert H.grant(w, grant.id).consumed_at != nil
  end

  test "a missing email_verified claim does not bind", %{w: w} do
    grant = H.create_grant!(w, "owner@example.com")

    assert %{result: :noop, ctx: ctx} =
             H.login_from_claims(w, %{"email" => "owner@example.com", "email_verified" => :omit})

    assert ctx.email_verified == false
    assert_untouched(w, grant)
  end

  test "a different e-mail does not bind", %{w: w} do
    grant = H.create_grant!(w, "owner@example.com")

    for email <- ["someone.else@example.com", "owner@example.org", "owner@example.com.evil.test"] do
      assert %{result: :noop} = H.login(w, email: email, verified: true)
    end

    assert_untouched(w, grant)
  end

  test "preferred_username equal to the pending e-mail does not bind", %{w: w} do
    grant = H.create_grant!(w, "owner@example.com")

    # The username is the pending address; the e-mail claim is somebody else's, verified.
    assert %{result: :noop} =
             H.login(w,
               username: "owner@example.com",
               email: "someone.else@example.com",
               verified: true
             )

    # Verified or not, and through the claim mapping too.
    assert %{result: :noop} =
             H.login(w, username: "Owner@Example.com", email: "x@example.com", verified: false)

    assert %{result: :noop} =
             H.login_from_claims(w, %{
               "preferred_username" => "OWNER@EXAMPLE.COM",
               "email" => "someone.else@example.org",
               "email_verified" => true
             })

    assert_untouched(w, grant)
  end

  test "preferred_username equal to the pending e-mail does not bind even when the e-mail claim is empty",
       %{w: w} do
    grant = H.create_grant!(w, "owner@example.com")

    # JIT refuses an empty e-mail (`email` is required), so a user whose stored e-mail is empty is
    # inserted directly: the shape of any row that predates that rule.
    user = H.insert_user!(w, email: "", username: "owner@example.com")

    for claim_email <- ["", "   "] do
      assert :noop == bind_raw(w, user, email: claim_email, verified: true)
    end

    assert_untouched(w, grant)
  end

  test "matching ignores case and surrounding whitespace of the claim but not plus tags or dots",
       %{w: w} do
    grant = H.create_grant!(w, "owner.name@example.com")

    # Plus tag and dot variants are different addresses: none of them binds.
    for email <- [
          "owner.name+admin@example.com",
          "ownername@example.com",
          "o.wner.name@example.com",
          "owner..name@example.com"
        ] do
      assert %{result: :noop} = H.login(w, email: email, verified: true), email
    end

    assert_untouched(w, grant)

    # Case and surrounding whitespace are the only normalisation.
    assert %{result: :bound, provisioned: %{user: user}} =
             H.login(w, email: "  OWNER.Name@Example.COM\t", verified: true)

    assert_bound(w, grant, user.id)
  end

  test "a token from another tenant's realm with the pending e-mail does not bind", %{w: w} do
    grant = H.create_grant!(w, "owner@example.com")
    other = H.second_tenant!(w)

    # Tenant B has no grant: the same verified address through B's own realm binds nothing in B,
    # and A's grant is untouched.
    assert %{result: :noop} = H.login(other, email: "owner@example.com", verified: true)
    assert H.member_count(other) == 0
    assert_untouched(w, grant)

    # Defence in depth, below the pipeline's own ownership guard: a context whose realm is not the
    # tenant's bound realm never binds, even with the right address and a verified claim.
    assert %{result: :noop} =
             H.login(w, email: "owner@example.com", verified: true, realm: other.realm)

    assert_untouched(w, grant)
  end

  test "a tenant without idp_realm_id cannot bind", %{w: _w} do
    bare = H.world!(idp_realm_id: nil)
    grant = H.create_grant!(bare, "owner@example.com")
    assert H.tenant_row(bare).idp_realm_id == nil

    # A context claiming any realm: the tenant has none, so nothing matches it.
    assert %{result: :noop} =
             H.login(bare, email: "owner@example.com", verified: true, realm: bare.realm)

    assert_untouched(bare, grant)
  end

  test "an inactive user does not bind", %{w: w} do
    grant = H.create_grant!(w, "owner@example.com")
    inactive = H.insert_user!(w, email: "owner@example.com", status: :inactive)

    assert :noop == bind_raw(w, inactive, email: "owner@example.com", verified: true)
    assert_untouched(w, grant)

    # Control: the same row once active binds (the gate is the status, nothing else).
    active =
      inactive
      |> Ecto.Changeset.change(%{status: :active})
      |> Repo.update!(prefix: w.tenant.schema_name)

    assert :bound == bind_raw(w, active, email: "owner@example.com", verified: true)
    assert_bound(w, grant, active.id)
  end

  test "a revoked grant does not bind", %{w: w} do
    grant = H.create_grant!(w, "owner@example.com")

    assert :ok =
             PendingAdminGrants.revoke(grant.id, %{user_id: w.operator_id},
               prefix: w.tenant.schema_name,
               platform_prefix: w.platform.schema_name
             )

    assert %{result: :noop} = H.login(w, email: "owner@example.com", verified: true)

    stored = H.grant(w, grant.id)
    assert PendingAdminGrant.state(stored) == :revoked
    assert H.member_count(w) == 0
    assert H.entries(w.tenant.schema_name, "tenant.admin_grant.bound") == []
  end

  # --- exactly once ----------------------------------------------------------

  test "a second login does not re-bind", %{w: w} do
    grant = H.create_grant!(w, "owner@example.com")
    sub = "sub-second-login"

    assert %{result: :bound, provisioned: %{user: user}} =
             H.login(w, sub: sub, email: "owner@example.com")

    assert_bound(w, grant, user.id)

    # A new grant for the same address is possible (the unique key was freed by the scrub); the
    # same person's later logins still never re-apply anything: the marker ended the retry.
    assert %{role_claims_synced_at: %DateTime{}} = user!(w, user.id)
    again = H.create_grant!(w, "owner@example.com")

    assert %{result: :noop, provisioned: %{created: false}} =
             H.login(w, sub: sub, email: "owner@example.com")

    assert H.member_count(w) == 1
    assert [_one] = H.entries(w.tenant.schema_name, "tenant.admin_grant.bound")
    assert PendingAdminGrant.state(H.grant(w, again.id)) == :open
  end

  test "removing the TENANT_ADMIN membership after binding is permanent: a later login does not re-apply the grant",
       %{w: w} do
    grant = H.create_grant!(w, "owner@example.com")
    sub = "sub-removed"
    group_id = H.admin_group_id!(w)

    assert %{result: :bound, provisioned: %{user: user}} =
             H.login(w, sub: sub, email: "owner@example.com")

    assert_bound(w, grant, user.id)

    assert :ok = Identity.remove_group_member(group_id, user.id, prefix: w.tenant.schema_name)
    assert H.roles(w, user.id) == []

    assert %{result: :noop} = H.login(w, sub: sub, email: "owner@example.com")

    assert H.roles(w, user.id) == []
    assert H.member_count(w) == 0
    # The grant stays consumed: nothing re-opened it.
    assert PendingAdminGrant.state(H.grant(w, grant.id)) == :bound
  end

  test "two concurrent first logins of the same user bind exactly once: one membership, one consumed row, one audit entry",
       %{w: w} do
    grant = H.create_grant!(w, "owner@example.com")
    schema = w.tenant.schema_name
    ctx = H.identity_context(w, sub: "sub-concurrent", email: "owner@example.com")
    jit = JitProvisioningConfig.for_realm(w.realm)

    {:ok, %{user: user, created: true} = provisioned} =
      Identity.provision_oidc_user(ctx, w.tenant.tenant_id, jit, prefix: schema)

    tenant = H.tenant_row(w)
    holder = hold_row_lock(w, grant.id, self())

    binders =
      for _attempt <- 1..2 do
        Task.async(fn ->
          PendingAdminGrants.bind_on_login(tenant, provisioned, ctx, jit, prefix: schema)
        end)
      end

    assert H.lock_waiters?("pending_tenant_admin_grants", 2),
           "the two binders never both queued on the grant row lock"

    send(holder.pid, :release)
    assert {:ok, :released} = Task.await(holder, 10_000)

    results = Task.await_many(binders, 30_000)

    assert Enum.sort(results) == [:bound, :noop]
    assert_bound(w, grant, user.id)
    assert H.member_count(w) == 1
    assert [_one] = H.entries(schema, "tenant.admin_grant.bound")
    assert [_one] = H.entries(w.platform.schema_name, "platform.tenant_admin_grant.bound")
  end

  test "two users presenting the same verified e-mail: exactly one binds", %{w: w} do
    grant = H.create_grant!(w, "shared@example.com")

    # The realm allowed a duplicate address: two accounts, same verified e-mail. The first to log in
    # while it is the only holder binds; the second finds the grant consumed.
    assert %{result: :bound, provisioned: %{user: first}} =
             H.login(w, sub: "sub-first", email: "shared@example.com", username: "first")

    assert %{result: :noop, provisioned: %{user: second}} =
             H.login(w, sub: "sub-second", email: "shared@example.com", username: "second")

    assert_bound(w, grant, first.id)
    assert H.roles(w, second.id) == []
    assert H.member_count(w) == 1
  end

  test "two users presenting the same verified e-mail concurrently never both bind (fail closed)",
       %{w: w} do
    grant = H.create_grant!(w, "shared@example.com")
    schema = w.tenant.schema_name
    jit = JitProvisioningConfig.for_realm(w.realm)
    tenant = H.tenant_row(w)

    # Both accounts exist (committed) before either bind runs, so each sees the other as a holder
    # of the same stored address: the duplicate check abandons both (design 7 step 5b).
    users =
      for {sub, name} <- [{"sub-conc-a", "conc-a"}, {"sub-conc-b", "conc-b"}] do
        ctx = H.identity_context(w, sub: sub, username: name, email: "shared@example.com")

        {:ok, provisioned} =
          Identity.provision_oidc_user(ctx, w.tenant.tenant_id, jit, prefix: schema)

        {ctx, provisioned}
      end

    holder = hold_row_lock(w, grant.id, self())

    binders =
      for {ctx, provisioned} <- users do
        Task.async(fn ->
          PendingAdminGrants.bind_on_login(tenant, provisioned, ctx, jit, prefix: schema)
        end)
      end

    assert H.lock_waiters?("pending_tenant_admin_grants", 2)
    send(holder.pid, :release)
    assert {:ok, :released} = Task.await(holder, 10_000)

    assert Task.await_many(binders, 30_000) == [:noop, :noop]
    assert_untouched(w, grant)
  end

  # --- fail-closed duplicate and consistency checks (F3, F5, N4) --------------

  test "a user whose stored users.email differs from the claim e-mail does not bind", %{w: w} do
    sub = "sub-changed-address"

    # First login with the address the person had when the account was created: no grant for it.
    assert %{result: :noop, provisioned: %{user: user}} =
             H.login(w, sub: sub, email: "old.address@example.com")

    assert user.email == "old.address@example.com"

    # The operator then names the NEW address; the realm now issues it for the same account.
    grant = H.create_grant!(w, "new.address@example.com")

    assert %{result: :noop, provisioned: %{created: false}} =
             H.login(w, sub: sub, email: "new.address@example.com", verified: true)

    assert_untouched(w, grant)
    assert user!(w, user.id).email == "old.address@example.com"
  end

  test "a tenant where another user holds the same stored e-mail does not bind and the grant stays open",
       %{w: w} do
    grant = H.create_grant!(w, "owner@example.com")

    # A pre-registered holder of the address, spelled differently (case and padding).
    _holder = H.insert_user!(w, email: "  OWNER@example.com  ")

    assert %{result: :noop} = H.login(w, email: "owner@example.com", verified: true)
    assert_untouched(w, grant)
  end

  test "a tenant where another user holds a non-ASCII stored e-mail that case-folds onto the key does not bind",
       %{w: w} do
    grant = H.create_grant!(w, "kay@example.com")

    # U+212A lower-cases onto an ASCII "k"; the shared normaliser folds it onto the key, which
    # Postgres lower() may or may not do depending on collation: the check is made in Elixir.
    assert String.downcase("Kay@example.com") == "kay@example.com"
    _holder = H.insert_user!(w, email: "Kay@example.com")

    assert %{result: :noop} = H.login(w, email: "kay@example.com", verified: true)
    assert_untouched(w, grant)
  end

  test "a claim e-mail containing a non-ASCII character that case-folds onto the key (U+212A) does not bind",
       %{w: w} do
    grant = H.create_grant!(w, "kay@example.com")
    lookalike = "Kay@example.com"

    # The premise of the attack: a naive normaliser maps the look-alike onto the key.
    assert String.downcase(lookalike) == "kay@example.com"

    assert %{result: :noop} = H.login(w, email: lookalike, verified: true)
    assert %{result: :noop} = H.login(w, email: "  " <> lookalike <> " ", verified: true)
    assert_untouched(w, grant)
  end

  test "a later claim whose non-ASCII e-mail folds onto the key does not bind even when the stored e-mail is the ASCII key (step 4 on its own)",
       %{w: w} do
    sub = "sub-fold-later"

    # The account was created with the plain ASCII address (no grant existed yet) ...
    assert %{result: :noop, provisioned: %{user: user}} =
             H.login(w, sub: sub, email: "kay@example.com", verified: true)

    assert user.email == "kay@example.com"
    grant = H.create_grant!(w, "kay@example.com")

    # ... and the realm now issues the Kelvin-sign look-alike for the same account: the stored
    # address (step 4b) folds onto the key, so only the claim's own ASCII rule (step 4) refuses it.
    assert %{result: :noop, provisioned: %{created: false}} =
             H.login(w, sub: sub, email: "Kay@example.com", verified: true)

    assert_untouched(w, grant)
  end

  test "an upper-case ASCII claim e-mail equal to the key binds (control for the U+212A test)",
       %{w: w} do
    grant = H.create_grant!(w, "kay@example.com")

    assert %{result: :bound, provisioned: %{user: user}} =
             H.login(w, email: "KAY@example.com", verified: true)

    assert_bound(w, grant, user.id)
  end

  test "a user who already has synced role claims is not offered the bind", %{w: w} do
    # The first login carries a role claim that resolves to a real binding, so the claim sync
    # grants it and stamps `role_claims_synced_at`.
    assert %{result: :noop, provisioned: %{user: user, created: true}} =
             H.login(w, sub: "sub-synced", email: "someone@example.com", roles: ["TASK_WORKER"])

    assert %DateTime{} = user.role_claims_synced_at
    assert H.memberships(w, user.id) == ["TASK_WORKER"]

    # Only now is a grant named for that address; the same person logs in again, verified.
    grant = H.create_grant!(w, "someone@example.com")

    assert %{result: :noop, provisioned: %{created: false}} =
             H.login(w, sub: "sub-synced", email: "someone@example.com", roles: ["TASK_WORKER"])

    stored = H.grant(w, grant.id)
    assert PendingAdminGrant.state(stored) == :open
    assert H.memberships(w, user.id) == ["TASK_WORKER"]
  end

  # --- state of the grant row ------------------------------------------------

  test "binding scrubs email_key to NULL and a revoke scrubs it too", %{w: w} do
    bound = H.create_grant!(w, "bound@example.com")
    revoked = H.create_grant!(w, "revoked@example.com")

    assert H.grant(w, bound.id).email_key == "bound@example.com"

    assert %{result: :bound, provisioned: %{user: user}} = H.login(w, email: "bound@example.com")

    stored = H.grant(w, bound.id)
    assert stored.email_key == nil
    assert %DateTime{} = stored.consumed_at
    assert stored.consumed_by_user_id == user.id
    assert stored.revoked_at == nil

    assert :ok =
             PendingAdminGrants.revoke(revoked.id, %{user_id: w.operator_id},
               prefix: w.tenant.schema_name,
               platform_prefix: w.platform.schema_name
             )

    stored = H.grant(w, revoked.id)
    assert stored.email_key == nil
    assert %DateTime{} = stored.revoked_at
    assert stored.consumed_at == nil
  end

  test "hard-deleting the bound user nulls consumed_by_user_id and does not fail", %{w: w} do
    grant = H.create_grant!(w, "owner@example.com")
    group_id = H.admin_group_id!(w)

    assert %{result: :bound, provisioned: %{user: user}} = H.login(w, email: "owner@example.com")
    assert H.grant(w, grant.id).consumed_by_user_id == user.id

    # The operational erasure: membership first (its own FK), then the user row.
    assert :ok = Identity.remove_group_member(group_id, user.id, prefix: w.tenant.schema_name)
    Repo.delete!(user, prefix: w.tenant.schema_name)

    stored = H.grant(w, grant.id)
    assert stored.consumed_by_user_id == nil
    assert PendingAdminGrant.state(stored) == :bound
    assert stored.email_key == nil
  end

  test "the consumed update must change exactly one row: a grant revoked between select and update rolls the bind back",
       %{w: w} do
    grant = H.create_grant!(w, "owner@example.com")
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      [:letflow, :repo, :query],
      &__MODULE__.revoke_after_grant_select/4,
      {self(), w.tenant.schema_name, grant.id}
    )

    {result, _log} =
      try do
        with_log(fn -> H.login(w, email: "owner@example.com", verified: true) end)
      after
        :telemetry.detach(handler_id)
      end

    assert Process.get(:iss1030_revoke_injected) == true, "the injection point was never reached"
    assert %{result: :noop, provisioned: %{user: user}} = result

    # The revoke ran INSIDE the bind's transaction (same process, same connection), after the row was
    # selected and before the consuming update: that update changed zero rows. Everything the bind had
    # done by then -- the membership above all -- must be gone with it.
    assert H.member_count(w) == 0
    assert H.roles(w, user.id) == []
    assert H.entries(w.tenant.schema_name, "tenant.admin_grant.bound") == []
    assert H.entries(w.platform.schema_name, "platform.tenant_admin_grant.bound") == []

    stored = H.grant(w, grant.id)
    assert stored.consumed_at == nil
    assert stored.consumed_by_user_id == nil
    assert user!(w, user.id).role_claims_synced_at == nil
  end

  @doc false
  def revoke_after_grant_select(_event, _measurements, metadata, {test_pid, schema, grant_id}) do
    query = to_string(Map.get(metadata, :query) || "")

    if self() == test_pid and Process.get(:iss1030_revoke_injected) != true and
         String.starts_with?(query, "SELECT") and String.contains?(query, "FOR UPDATE") and
         String.contains?(query, "pending_tenant_admin_grants") do
      Process.put(:iss1030_revoke_injected, true)

      # An update, not a select: it does not re-enter this branch.
      Repo.update_all(
        from(g in PendingAdminGrant, where: g.id == ^grant_id),
        [set: [revoked_at: DateTime.utc_now(), email_key: nil]],
        prefix: schema
      )
    end

    :ok
  end

  # --- missing pieces and injected failures: nothing changes, nothing is hinted --------

  test "a bind with a missing TENANT_ADMIN binding does nothing and leaves the grant open",
       %{w: w} do
    grant = H.create_grant!(w, "owner@example.com")

    Repo.delete_all(from(r in TenantRole, where: r.name == "TENANT_ADMIN"),
      prefix: w.tenant.schema_name
    )

    {result, _log} =
      with_log(fn -> H.login(w, email: "owner@example.com", verified: true) end)

    assert %{result: :noop} = result
    assert_untouched(w, grant)
  end

  test "a failure injected at the tenant audit step rolls back the membership, the consumed mark, the marker stamp and writes no platform entry",
       %{w: w} do
    grant = H.create_grant!(w, "owner@example.com")
    sub = "sub-audit-fault"

    create_trigger!(
      w,
      "iss1030_fail_bound_audit",
      "audit_entries",
      "INSERT",
      "NEW.action = 'tenant.admin_grant.bound'"
    )

    {result, _log} =
      with_log(fn -> H.login(w, sub: sub, email: "owner@example.com", verified: true) end)

    assert %{result: :noop, provisioned: %{user: user}} = result

    # The membership insert, the consume update and the marker stamp all ran BEFORE the failing
    # audit step; none of them survived.
    assert_untouched(w, grant)
    assert H.roles(w, user.id) == []
    assert user!(w, user.id).role_claims_synced_at == nil

    # Self-healing: with the fault gone, the SAME person's next login binds.
    drop_trigger!(w, "iss1030_fail_bound_audit", "audit_entries")

    assert %{result: :bound} = H.login(w, sub: sub, email: "owner@example.com", verified: true)
    assert_bound(w, grant, user.id)
    assert %DateTime{} = user!(w, user.id).role_claims_synced_at
  end

  test "bind: tenant-chain and platform-chain entries exist in the same transaction (forced failure of the platform write leaves no membership, no consumed grant, no tenant entry)",
       %{w: w} do
    grant = H.create_grant!(w, "owner@example.com")
    sub = "sub-platform-fault"

    # A platform tenant id whose schema does not exist: the derivation succeeds (it is pure), so
    # every pre-check passes and the failure happens at the LAST step, after the membership, the
    # consume update, the stamp and the tenant entry were written.
    Fixture.pin!(Ecto.UUID.generate())

    {result, _log} =
      with_log(fn -> H.login(w, sub: sub, email: "owner@example.com", verified: true) end)

    assert %{result: :noop} = result
    assert_untouched(w, grant)

    # With the platform chain reachable again the same login binds, writing BOTH entries.
    Fixture.pin!(w.platform.tenant_id)
    assert %{result: :bound} = H.login(w, sub: sub, email: "owner@example.com", verified: true)
    assert [_] = H.entries(w.tenant.schema_name, "tenant.admin_grant.bound")
    assert [_] = H.entries(w.platform.schema_name, "platform.tenant_admin_grant.bound")
  end

  test "a bind with no configured platform tenant is a silent no-op and the grant stays open",
       %{w: w} do
    grant = H.create_grant!(w, "owner@example.com")

    Fixture.unpin!()

    {result, _log} =
      with_log(fn -> H.login(w, email: "owner@example.com", verified: true) end)

    assert %{result: :noop} = result
    assert_untouched(w, grant)
  end

  test "a missing grants table is a silent no-op", %{w: w} do
    Repo.query!(~s|DROP TABLE "#{w.tenant.schema_name}".pending_tenant_admin_grants|)

    {result, log} =
      with_log(fn -> H.login(w, email: "owner@example.com", verified: true) end)

    # No raise, no error: the user is provisioned and the request would continue unchanged.
    assert %{result: :noop, provisioned: %{user: user}} = result
    assert H.roles(w, user.id) == []

    # A real fault, so it is visible to the operator: fixed text and the tenant id only.
    assert [line] = fault_lines(log, w.tenant.tenant_id)
    assert line =~ "[warning]"
  end

  test "a bind waiting on the platform chain lock past the lock timeout is a silent no-op and the grant stays open",
       %{w: w} do
    grant = H.create_grant!(w, "owner@example.com")
    sub = "sub-lock-timeout"
    platform_schema = w.platform.schema_name
    platform_tenant_id = w.platform.tenant_id
    parent = self()

    # Hold the PLATFORM chain's lock row (the one contended point of design 7 step 9).
    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.insert!(ChainLock.insert_changeset(%ChainLock{}, %{tenant_id: platform_tenant_id}),
            on_conflict: :nothing,
            conflict_target: :tenant_id,
            prefix: platform_schema
          )

          Repo.one!(
            from(l in ChainLock, where: l.tenant_id == ^platform_tenant_id, lock: "FOR UPDATE"),
            prefix: platform_schema
          )

          send(parent, :locked)

          receive do
            :release -> :released
          end
        end)
      end)

    assert_receive :locked, 10_000

    # The bind queues on the platform lock and gives up after its own 2 s `lock_timeout`; the login
    # request is not held longer than that, and nothing is changed.
    {result, log} =
      with_log(fn -> H.login(w, sub: sub, email: "owner@example.com", verified: true) end)

    assert %{result: :noop, provisioned: %{user: user}} = result
    assert_untouched(w, grant)
    assert H.roles(w, user.id) == []
    assert [line] = fault_lines(log, w.tenant.tenant_id)
    assert line =~ "[warning]"

    # With the lock released, the very same login binds: the grant was never touched.
    send(holder.pid, :release)
    assert {:ok, :released} = Task.await(holder, 10_000)

    assert %{result: :bound} = H.login(w, sub: sub, email: "owner@example.com", verified: true)
    assert_bound(w, grant, user.id)
  end

  # --- audit entries of a bind -------------------------------------------------

  test "the bind audit entry carries the created_via class and the bound user and no operator id",
       %{w: w} do
    grant = H.create_grant!(w, "owner@example.com")

    assert %{result: :bound, provisioned: %{user: user}} =
             H.login(w, email: "owner@example.com", verified: true)

    assert [entry] = H.entries(w.tenant.schema_name, "tenant.admin_grant.bound")
    assert entry.actor_id == user.id
    assert entry.resource_type == "pending_admin_grant"
    assert entry.resource_id == grant.id
    assert entry.before_state == nil
    assert entry.trace_id == nil

    assert entry.after_state == %{
             "grant_id" => grant.id,
             "role" => "TENANT_ADMIN",
             "bound_user_id" => user.id,
             "created_via" => "platform_operator_onboarding",
             "email_basis" => "verified_claim"
           }

    encoded = Jason.encode!(entry.after_state) <> to_string(entry.actor_id)
    refute encoded =~ w.operator_id
    refute encoded =~ w.platform.tenant_id
    refute encoded =~ "owner@example.com"
  end

  test "the platform bind entry contains only grant_id, tenant_id and bound_user_id and no e-mail",
       %{w: w} do
    grant = H.create_grant!(w, "owner@example.com")

    assert %{result: :bound, provisioned: %{user: user}} =
             H.login(w, email: "owner@example.com", verified: true)

    assert [entry] = H.entries(w.platform.schema_name, "platform.tenant_admin_grant.bound")
    assert entry.actor_id == user.id
    assert entry.resource_type == "pending_admin_grant"
    assert entry.resource_id == grant.id
    assert entry.before_state == nil

    assert entry.after_state == %{
             "grant_id" => grant.id,
             "tenant_id" => w.tenant.tenant_id,
             "bound_user_id" => user.id
           }

    refute inspect(entry) =~ "owner@example.com"
  end

  test "tenant-chain and platform-chain entries carry the same grant_id", %{w: w} do
    created = H.create_grant!(w, "created.and.bound@example.com")
    revoked = H.create_grant!(w, "revoked@example.com")

    assert %{result: :bound} = H.login(w, email: "created.and.bound@example.com")

    assert :ok =
             PendingAdminGrants.revoke(revoked.id, %{user_id: w.operator_id},
               prefix: w.tenant.schema_name,
               platform_prefix: w.platform.schema_name
             )

    pairs = [
      {"tenant.admin_grant.created", "platform.tenant_admin_grant.created", created.id},
      {"tenant.admin_grant.bound", "platform.tenant_admin_grant.bound", created.id},
      {"tenant.admin_grant.revoked", "platform.tenant_admin_grant.revoked", revoked.id}
    ]

    for {tenant_action, platform_action, grant_id} <- pairs do
      [tenant_entry] =
        w.tenant.schema_name
        |> H.entries(tenant_action)
        |> Enum.filter(&(&1.resource_id == grant_id))

      [platform_entry] =
        w.platform.schema_name
        |> H.entries(platform_action)
        |> Enum.filter(&(&1.resource_id == grant_id))

      assert tenant_entry.resource_id == platform_entry.resource_id
      assert tenant_entry.after_state["grant_id"] == grant_id
      assert platform_entry.after_state["grant_id"] == grant_id
    end

    # Realm-bound: the shared reference is the tenant id.
    bare = Letflow.TenantFixture.provisioned_tenant!(slug_prefix: "iss1030-bind-bare")

    assert {:ok, _tenant} =
             Identity.bind_tenant_realm(
               bare.tenant_id,
               Letflow.TenantSlugFixture.unique_realm("iss1030rb"),
               actor_id: w.operator_id,
               platform_prefix: w.platform.schema_name,
               trace_id: nil
             )

    assert [tenant_entry] = H.entries(bare.schema_name, "tenant.idp_realm.bound")

    assert [platform_entry] =
             w.platform.schema_name
             |> H.entries("platform.tenant_idp_realm.bound")
             |> Enum.filter(&(&1.resource_id == bare.tenant_id))

    assert tenant_entry.resource_id == bare.tenant_id
    assert platform_entry.resource_id == bare.tenant_id
    assert platform_entry.after_state["tenant_id"] == bare.tenant_id
  end

  # --- logging (INV-4, F7, N5) ---------------------------------------------------

  test "an expected no-op bind logs only fixed text and the tenant id at debug level", %{w: w} do
    _grant = H.create_grant!(w, "owner@example.com")
    claim_email = "nobody.waits.for.me@example.com"

    {result, log} =
      with_log(fn -> H.login(w, email: claim_email, verified: true) end)

    assert %{result: :noop} = result

    lines = own_lines(log)
    assert lines != [], "the no-op left no debug line at all"

    for line <- lines do
      assert line =~
               ~r/\[debug\] pending administrator bind skipped \(tenant_id="[0-9a-f-]{36}"\)$/,
             line

      assert line =~ w.tenant.tenant_id
      refute line =~ claim_email
      refute line =~ "owner@example.com"
    end

    # And nothing at warning or error level mentions the feature.
    refute log =~ ~r/\[(warning|error)\][^\n]*pending administrator/
  end

  test "a bind with no configured platform tenant logs the fixed warning for that tenant at most once per hour",
       %{w: w} do
    _grant = H.create_grant!(w, "owner@example.com")
    Fixture.unpin!()

    {results, log} =
      with_log(fn ->
        for n <- 1..3 do
          H.login(w, sub: "sub-nopin-#{n}", email: "owner@example.com", verified: true)
        end
      end)

    assert Enum.all?(results, &(&1.result == :noop))

    assert [line] = fault_lines(log, w.tenant.tenant_id)
    assert line =~ "[warning]"
    assert line =~ ~r/pending administrator bind failed \(tenant_id="[0-9a-f-]{36}"\)$/
    refute line =~ "owner@example.com"
  end

  test "a real fault in the bind (missing TENANT_ADMIN binding, database error, platform chain failure, missing table) logs fixed text and the tenant id at warning, at most once per tenant per hour, and never the e-mail",
       %{w: w} do
    email = "owner@example.com"
    grant = H.create_grant!(w, email)
    tenant_id = w.tenant.tenant_id
    schema = w.tenant.schema_name

    # Each scenario is a distinct fault; the per-tenant throttle is reset between them so each is
    # observed on its own, and within a scenario two attempts must still yield ONE line.
    scenarios = [
      {"missing TENANT_ADMIN binding",
       fn ->
         Repo.delete_all(from(r in TenantRole, where: r.name == "TENANT_ADMIN"), prefix: schema)
       end,
       fn ->
         {:ok, _roles} =
           Letflow.Identity.RoleRegistry.seed_default_platform_role_groups(prefix: schema)
       end},
      {"database error",
       fn ->
         create_trigger!(
           w,
           "iss1030_fail_consume",
           "pending_tenant_admin_grants",
           "UPDATE",
           "TRUE"
         )
       end, fn -> drop_trigger!(w, "iss1030_fail_consume", "pending_tenant_admin_grants") end},
      {"platform chain failure", fn -> Fixture.pin!(Ecto.UUID.generate()) end,
       fn -> Fixture.pin!(w.platform.tenant_id) end},
      {"missing table",
       fn -> Repo.query!(~s|DROP TABLE "#{schema}".pending_tenant_admin_grants|) end,
       fn -> :ok end}
    ]

    for {name, break, restore} <- scenarios do
      :ets.delete(FaultThrottle.table(), tenant_id)
      break.()

      {results, log} =
        with_log(fn ->
          for _attempt <- 1..2 do
            H.login(w, sub: "sub-fault", email: email, verified: true)
          end
        end)

      assert Enum.all?(results, &(&1.result == :noop)), name

      lines = fault_lines(log, tenant_id)
      assert length(lines) == 1, "#{name}: expected one warning, got #{length(lines)}"
      assert hd(lines) =~ "[warning]", name

      assert hd(lines) =~ ~r/pending administrator bind failed \(tenant_id="[0-9a-f-]{36}"\)$/,
             name

      # Nothing the feature itself logged, at any level, carries the address or the exception text.
      for line <- own_lines(log) do
        refute String.downcase(line) =~ email, name
        refute line =~ "injected fault", name
      end

      refute log =~ ~r/\[(warning|error)\][^\n]*owner@example\.com/, name

      # The fault changed nothing: the grant is still open (the table scenario is last and
      # leaves no table to read).
      if name != "missing table" do
        assert PendingAdminGrant.state(H.grant(w, grant.id)) == :open, name
        assert H.member_count(w) == 0, name
      end

      restore.()
    end
  end

  test "the fault throttle allows one warning per tenant per hour and tracks tenants independently" do
    first = Ecto.UUID.generate()
    second = Ecto.UUID.generate()

    on_exit(fn ->
      :ets.delete(FaultThrottle.table(), first)
      :ets.delete(FaultThrottle.table(), second)
    end)

    assert FaultThrottle.allow?(first)
    refute FaultThrottle.allow?(first)
    refute FaultThrottle.allow?(first)
    assert FaultThrottle.allow?(second)

    # A line older than the one-hour window no longer suppresses the next one.
    :ets.insert(FaultThrottle.table(), {first, System.monotonic_time(:second) - 3_601})
    assert FaultThrottle.allow?(first)
    refute FaultThrottle.allow?(first)
  end

  # A platform prefix that names no schema: the platform write fails AFTER the grant row and the
  # tenant entry were written, which is the interesting place for a failure.
  defp missing_platform_prefix, do: "tenant_" <> String.duplicate("0", 32)

  # --- forced failures of the platform write on the operator side (letflow-9a condition 1) -----

  test "created: a forced failure of the platform write leaves no grant row and no tenant entry",
       %{w: w} do
    {result, log} =
      with_log(fn ->
        PendingAdminGrants.create(
          "owner@example.com",
          %{user_id: w.operator_id},
          prefix: w.tenant.schema_name,
          platform_prefix: missing_platform_prefix(),
          trace_id: nil,
          onboarding_id: nil
        )
      end)

    assert result == {:error, :audit_failed}
    assert H.grants(w) == []
    assert H.entries(w.tenant.schema_name, "tenant.admin_grant.created") == []
    assert H.all_entries(w.platform.schema_name) == []

    # The failure line is fixed text: no address, no operator id (Ecto's own SQL echo, which
    # prints bound parameters, is not the feature's output).
    own = H.non_sql_entries(log)
    assert Enum.any?(own, &(&1 =~ "pending administrator grant create failed"))
    refute Enum.any?(own, &(&1 =~ "owner@example.com"))
    refute Enum.any?(own, &(&1 =~ w.operator_id))
  end

  test "revoked: a forced failure of the platform write leaves the grant open, the e-mail present and no tenant entry",
       %{w: w} do
    grant = H.create_grant!(w, "owner@example.com")

    {result, _log} =
      with_log(fn ->
        PendingAdminGrants.revoke(
          grant.id,
          %{user_id: w.operator_id},
          prefix: w.tenant.schema_name,
          platform_prefix: missing_platform_prefix(),
          trace_id: nil,
          onboarding_id: nil
        )
      end)

    assert result == {:error, :audit_failed}

    stored = H.grant(w, grant.id)
    assert PendingAdminGrant.state(stored) == :open
    assert stored.email_key == "owner@example.com"
    assert H.entries(w.tenant.schema_name, "tenant.admin_grant.revoked") == []
  end

  # --- round 2 (SECURITY-REVIEWER L1-L3): tenant status gate, locked user re-check, lock-free probe ---

  defp set_tenant_status!(w, status) do
    w
    |> H.tenant_row()
    |> Letflow.Identity.Tenant.status_changeset(%{status: status})
    |> Repo.update!()
  end

  defp all_actions(w) do
    Enum.map(H.all_entries(w.tenant.schema_name), & &1.action) ++
      Enum.map(H.all_entries(w.platform.schema_name), & &1.action)
  end

  for status <- [:migrating, :inactive] do
    test "L1: a #{status} tenant never binds: the grant stays open, no membership, no entry in either chain; an active tenant binds",
         %{w: w} do
      status = unquote(status)
      grant = H.create_grant!(w, "owner@example.com")
      actions_before = all_actions(w)

      set_tenant_status!(w, status)

      assert %{result: :noop, provisioned: %{user: user, created: true}} =
               H.login(w, sub: "sub-l1", email: "owner@example.com", verified: true)

      assert_untouched(w, grant)
      assert H.roles(w, user.id) == []
      assert user!(w, user.id).role_claims_synced_at == nil
      assert all_actions(w) == actions_before

      # Control: the same person, same grant, once the tenant is `:active` again.
      set_tenant_status!(w, :active)

      assert %{result: :bound, provisioned: %{user: %{id: same_id}}} =
               H.login(w, sub: "sub-l1", email: "owner@example.com", verified: true)

      assert same_id == user.id
      assert_bound(w, grant, user.id)
    end
  end

  test "L1 control: an active tenant binds on the very first login", %{w: w} do
    grant = H.create_grant!(w, "owner@example.com")
    assert H.tenant_row(w).status == :active

    assert %{result: :bound, provisioned: %{user: user}} =
             H.login(w, email: "owner@example.com", verified: true)

    assert_bound(w, grant, user.id)
  end

  # Runs one login of `sub` with a telemetry hook that, INSIDE the bind transaction right after
  # the grant row is locked (so after the precheck and before the user row is locked), applies
  # `changes` to that user's row. Deterministic: no sleep, no second connection.
  defp login_with_user_change(w, sub, changes, attrs) do
    handler_id = {__MODULE__, make_ref()}
    Process.delete(:iss1030_user_change_injected)

    :telemetry.attach(
      handler_id,
      [:letflow, :repo, :query],
      &__MODULE__.change_user_after_grant_select/4,
      {self(), w.tenant.schema_name, sub, changes}
    )

    result =
      try do
        H.login(w, [sub: sub] ++ attrs)
      after
        :telemetry.detach(handler_id)
      end

    assert Process.get(:iss1030_user_change_injected) == true,
           "the injection point was never reached"

    result
  end

  @doc false
  def change_user_after_grant_select(_event, _measurements, metadata, {pid, schema, sub, changes}) do
    query = to_string(Map.get(metadata, :query) || "")

    if self() == pid and Process.get(:iss1030_user_change_injected) != true and
         String.starts_with?(query, "SELECT") and String.contains?(query, "FOR UPDATE") and
         String.contains?(query, "pending_tenant_admin_grants") do
      Process.put(:iss1030_user_change_injected, true)

      Repo.update_all(from(u in User, where: u.external_id == ^sub), [set: changes],
        prefix: schema
      )
    end

    :ok
  end

  test "L2: a user deactivated between the precheck and the locked read does not bind (silent noop, nothing written)",
       %{w: w} do
    grant = H.create_grant!(w, "owner@example.com")

    assert %{result: :noop, provisioned: %{user: user}} =
             login_with_user_change(w, "sub-l2-status", [status: :inactive],
               email: "owner@example.com",
               verified: true
             )

    assert_untouched(w, grant)
    assert H.roles(w, user.id) == []
    assert user!(w, user.id).role_claims_synced_at == nil
  end

  test "L2: a stored e-mail changed between the precheck and the locked read does not bind (silent noop, nothing written)",
       %{w: w} do
    grant = H.create_grant!(w, "owner@example.com")

    assert %{result: :noop, provisioned: %{user: user}} =
             login_with_user_change(w, "sub-l2-email", [email: "someone.else@example.com"],
               email: "owner@example.com",
               verified: true
             )

    assert_untouched(w, grant)
    assert H.roles(w, user.id) == []
  end

  test "L2: a role-claim sync stamped between the precheck and the locked read does not bind an existing user",
       %{w: w} do
    sub = "sub-l2-synced"

    # First login: no grant waits for this address yet, so nothing binds and the marker stays NIL.
    assert %{result: :noop, provisioned: %{user: %{id: user_id}, created: true}} =
             H.login(w, sub: sub, email: "owner@example.com", verified: true)

    grant = H.create_grant!(w, "owner@example.com")

    assert %{result: :noop, provisioned: %{created: false}} =
             login_with_user_change(w, sub, [role_claims_synced_at: DateTime.utc_now()],
               email: "owner@example.com",
               verified: true
             )

    assert_untouched(w, grant)
    assert H.roles(w, user_id) == []
  end

  test "L2 control: a user row whose bind-irrelevant fields change in the same window still binds",
       %{w: w} do
    grant = H.create_grant!(w, "owner@example.com")

    assert %{result: :bound, provisioned: %{user: user}} =
             login_with_user_change(w, "sub-l2-control", [display_name: "Renamed Meanwhile"],
               email: "owner@example.com",
               verified: true
             )

    assert_bound(w, grant, user.id)
    assert user!(w, user.id).display_name == "Renamed Meanwhile"
  end

  test "L2: a user created in this request that already carries the role-claim stamp still binds",
       %{w: w} do
    grant = H.create_grant!(w, "owner@example.com")

    assert %{result: :bound, provisioned: %{user: user, created: true}} =
             H.login(w, email: "owner@example.com", verified: true, roles: ["TASK_WORKER"])

    # The claim sync stamped the marker before the bind ran: the stamp step is the no-op path.
    assert %DateTime{} = user.role_claims_synced_at
    assert_bound(w, grant, user.id)
    assert H.memberships(w, user.id) == ["TASK_WORKER", "TENANT_ADMIN"]
    assert [_] = H.entries(w.tenant.schema_name, "tenant.admin_grant.bound")
    assert [_] = H.entries(w.platform.schema_name, "platform.tenant_admin_grant.bound")
  end

  # Provisions the user (JIT) and returns what `bind_on_login/5` needs, so the bind itself can be
  # wrapped in a query capture.
  defp provision!(w, attrs) do
    ctx = H.identity_context(w, attrs)
    jit = JitProvisioningConfig.for_realm(ctx.realm)

    {:ok, provisioned} =
      Identity.provision_oidc_user(ctx, w.tenant.tenant_id, jit, prefix: w.tenant.schema_name)

    {ctx, jit, provisioned, H.tenant_row(w)}
  end

  defp captured_bind(w, attrs) do
    {ctx, jit, provisioned, tenant} = provision!(w, attrs)

    {result, queries} =
      Fixture.capture_repo_queries(fn ->
        PendingAdminGrants.bind_on_login(tenant, provisioned, ctx, jit,
          prefix: w.tenant.schema_name
        )
      end)

    {result, Enum.map(queries, &to_string(Map.get(&1, :query) || ""))}
  end

  test "L3: with no open grant for the key the bind issues only the lock-free probe: no transaction statement, no lock_timeout, no FOR UPDATE",
       %{w: w} do
    # A grant for ANOTHER address exists: the probe is keyed, it is not "the table is empty".
    other = H.create_grant!(w, "someone.else@example.com")

    {result, queries} = captured_bind(w, email: "nobody.waits@example.com", verified: true)

    assert result == :noop
    assert Enum.filter(queries, &(&1 =~ "pending_tenant_admin_grants")) |> length() == 1
    refute Enum.any?(queries, &(&1 =~ "FOR UPDATE"))
    refute Enum.any?(queries, &(&1 =~ ~r/lock_timeout|SET LOCAL/i))
    refute Enum.any?(queries, &(&1 =~ ~r/INSERT|UPDATE|DELETE/))
    assert PendingAdminGrant.state(H.grant(w, other.id)) == :open
  end

  test "L3: with no open grant because the grant is already revoked the bind is still only the probe",
       %{w: w} do
    grant = H.create_grant!(w, "owner@example.com")

    :ok =
      PendingAdminGrants.revoke(grant.id, %{user_id: w.operator_id},
        prefix: w.tenant.schema_name,
        platform_prefix: w.platform.schema_name,
        trace_id: nil,
        onboarding_id: nil
      )

    {result, queries} = captured_bind(w, email: "owner@example.com", verified: true)

    assert result == :noop
    refute Enum.any?(queries, &(&1 =~ "FOR UPDATE"))
    refute Enum.any?(queries, &(&1 =~ ~r/lock_timeout|SET LOCAL/i))
  end

  test "L3 control: with an open grant the probe is followed by the bounded transaction (SET LOCAL lock_timeout, FOR UPDATE) and the bind commits",
       %{w: w} do
    grant = H.create_grant!(w, "owner@example.com")

    {result, queries} = captured_bind(w, email: "owner@example.com", verified: true)

    assert result == :bound

    probe = Enum.find_index(queries, &(&1 =~ "pending_tenant_admin_grants"))
    set_local = Enum.find_index(queries, &(&1 =~ ~r/SET LOCAL lock_timeout/))
    lock = Enum.find_index(queries, &(&1 =~ "FOR UPDATE" and &1 =~ "pending_tenant_admin_grants"))

    assert is_integer(probe) and is_integer(set_local) and is_integer(lock)
    assert probe < set_local and set_local < lock
    refute Enum.at(queries, probe) =~ "FOR UPDATE"

    assert PendingAdminGrant.state(H.grant(w, grant.id)) == :bound
  end
end
