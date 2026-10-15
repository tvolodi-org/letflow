defmodule Letflow.Routers.Gh2564DeactivationRevokesTokensTest do
  @moduledoc """
  GH 2564 (ruling: issue #2564 comment 6174049298, option 3; design
  `lib/letflow/design/gh2564-deactivation-revokes-tokens.md` section 7): deactivating a
  user revokes every non-revoked API token of that user in the same transaction, one
  `token.revoke` each with `cause: "owner_deactivated"`; reactivation restores none; and
  the 0051 N1 guard refuses a deactivation that takes the tenant from at least one
  tenant-wide admin to none (409 `last_tenant_wide_admin`, audited afterwards as
  `tenant_admin.guard_refused`). Spec: `test/specs/GH-2564.md`.

  HTTP tests dispatch `Letflow.Routers.Identity.call/2` with a hand-assigned
  `auth_context` (`call_as/5`). The caller is a REAL user of the tenant who holds no
  admin source of its own, so it never counts as a tenant-wide admin: the guard sees
  exactly the admins each test sets up. Old plaintexts are checked through the full
  `Letflow.Router` pipeline.

  `async: false`: `TenantFixture.provisioned_tenant!/1` flips the sandbox to `:auto` (real
  commits, needed by the lock-order tests). The fault-injection tests instead use
  `sandboxed_tenant!/0` (the `audit_dispositions_test.exs` pattern): provisioning under
  `:auto`, then the test body inside its own sandbox transaction, so the DDL they run is
  undone when the test ends.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.Identity
  alias Letflow.Identity.ApiToken
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.TokenMintFixture, as: Mint
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration
  alias Letflow.Test.LoggerCollector
  alias Letflow.Test.SandboxAutoMode

  @admin ["TENANT_ADMIN"]
  @trace "gh2564-trace-0001"

  # token_audit_state/1 keys (GH 2552 design section 5)
  @audit_keys Enum.sort(
                ~w(id user_id issuer_user_id roles expires_at revoked_at last_used_at inserted_at scope)
              )
  @refusal_keys Enum.sort(~w(action actor target_id reason_code counted_admins trace_id))

  # --- fixtures --------------------------------------------------------------------------------

  defp committed_tenant!, do: TenantFixture.provisioned_tenant!(slug_prefix: "gh2564")

  # audit_dispositions_test.exs's provisioned_tenant/0: real provisioning, then the test
  # body runs in its own (manual-mode) sandbox transaction, rolled back at test exit.
  defp sandboxed_tenant! do
    SandboxAutoMode.provision!(Letflow.Repo, fn ->
      fx = TenantFixture.provisioned_tenant!(slug_prefix: "gh2564-sbx", teardown: false)
      tenant_id = fx.tenant_id

      on_exit(fn ->
        Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

        case TenantProvisioning.schema_name_for_tenant(tenant_id) do
          {:ok, schema_name} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
          {:error, :invalid_tenant_id} -> :ok
        end

        Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant_id))
        Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))
        SandboxAutoMode.exit_auto_mode!(Letflow.Repo)
      end)

      fx
    end)
  end

  # A real user with no admin source: the HTTP caller.
  defp caller!(fx), do: Mint.role_holder!(fx.schema_name, [])
  defp plain_user!(fx), do: Mint.role_holder!(fx.schema_name, [])
  # Tenant-wide admin through the TENANT_ADMIN group.
  defp group_admin!(fx), do: Mint.role_holder!(fx.schema_name, @admin)

  defp token!(fx, %User{} = user, roles, expires_at \\ nil) do
    {:ok, %{token: token, plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: expires_at},
        prefix: fx.schema_name
      )

    {token, plaintext}
  end

  # Tenant-wide admin only through a live TENANT_ADMIN token.
  defp token_admin!(fx) do
    user = plain_user!(fx)
    {token, plaintext} = token!(fx, user, @admin)
    {user, token, plaintext}
  end

  defp expire!(fx, %ApiToken{} = token) do
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
    token |> Ecto.Changeset.change(expires_at: past) |> Repo.update!(prefix: fx.schema_name)
  end

  defp call_as(method, path, fx, %User{} = caller, body) do
    method
    |> Fixture.router_conn(path, fx, @admin, body)
    |> Plug.Conn.assign(:auth_context, %{
      user_id: caller.id,
      tenant_id: fx.tenant_id,
      roles: @admin
    })
    |> Plug.Conn.assign(:trace_id, @trace)
    |> Letflow.Routers.Identity.call(Letflow.Routers.Identity.init([]))
  end

  defp set_status(fx, caller, user, status, :post),
    do: call_as(:post, "/users/#{user.id}/status", fx, caller, %{"status" => status})

  defp set_status(fx, caller, user, status, :patch),
    do: call_as(:patch, "/users/#{user.id}", fx, caller, %{"status" => status})

  defp audit_action(:post), do: "user.update_status"
  defp audit_action(:patch), do: "user.update_profile"

  defp entries(fx, action) do
    Repo.all(from(e in Entry, where: e.action == ^action, order_by: e.timestamp),
      prefix: fx.schema_name
    )
  end

  defp reload(fx, %ApiToken{id: id}), do: Repo.get!(ApiToken, id, prefix: fx.schema_name)
  defp reload(fx, %User{id: id}), do: Repo.get!(User, id, prefix: fx.schema_name)

  defp old_plaintext_status(fx, plaintext) do
    "/api/v1/me/memberships"
    |> then(&Fixture.api_conn(:get, &1, plaintext, fx.tenant.slug, nil))
    |> Fixture.dispatch_api()
    |> Map.fetch!(:status)
  end

  defp detail(conn), do: Jason.decode!(conn.resp_body)["detail"]

  defp assert_no_leak!(states, tokens_and_plaintexts) do
    encoded = Jason.encode!(states)
    refute encoded =~ "lf_tok_"
    refute encoded =~ "token_hash"

    for {token, plaintext} <- tokens_and_plaintexts do
      refute encoded =~ token.token_hash
      refute encoded =~ String.slice(token.token_hash, 0, 8)
      refute encoded =~ token.name
      refute encoded =~ plaintext
    end
  end

  # Holds the tenant admin lock in a separate committed transaction until released.
  defp hold_tenant_admin_lock!(fx) do
    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Identity.lock_tenant_admins!(fx.schema_name)
          send(parent, :tenant_admin_locked)

          receive do
            :release -> :ok
          after
            15_000 -> Repo.rollback(:timeout)
          end
        end)
      end)

    assert_receive :tenant_admin_locked, 5_000
    holder
  end

  defp release!(holder) do
    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder, 10_000)
  end

  # --- AC1/AC2: revoke every non-revoked token in the same transaction --------------------------

  describe "deactivation revokes all the user's tokens" do
    for path <- [:post, :patch] do
      test "#{path}: status inactive revokes all unrevoked tokens (TA, plain, expired); an already-revoked revoked_at is unchanged" do
        fx = committed_tenant!()
        caller = caller!(fx)
        _other_admin = group_admin!(fx)
        target = plain_user!(fx)

        {ta, _} = token!(fx, target, @admin)
        {plain, _} = token!(fx, target, ["TASK_WORKER"])

        {expiring, _} =
          token!(fx, target, ["TASK_WORKER"], DateTime.add(DateTime.utc_now(), 86_400))

        expired = expire!(fx, expiring)
        {old, _} = token!(fx, target, ["TASK_WORKER"])
        {:ok, old} = Identity.revoke_token(old.id, prefix: fx.schema_name)
        other_user = plain_user!(fx)
        {untouched, _} = token!(fx, other_user, ["TASK_WORKER"])

        conn = set_status(fx, caller, target, "inactive", unquote(path))
        assert conn.status == 200, conn.resp_body
        assert reload(fx, target).status == :inactive

        revoked_ats = for t <- [ta, plain, expired], do: reload(fx, t).revoked_at
        assert Enum.all?(revoked_ats, &match?(%DateTime{}, &1))
        assert revoked_ats |> Enum.uniq() |> length() == 1
        assert reload(fx, old).revoked_at == old.revoked_at
        assert reload(fx, untouched).revoked_at == nil

        assert length(entries(fx, "token.revoke")) == 1 + 3
        [user_entry] = entries(fx, audit_action(unquote(path)))
        assert user_entry.after_state["revoked_token_count"] == 3
      end
    end

    test "N tokens -> N token.revoke with cause owner_deactivated, actor, user_id, id, roles, trace_id; no hash, name or lf_tok_; user entry counts N" do
      fx = committed_tenant!()
      caller = caller!(fx)
      _other_admin = group_admin!(fx)
      target = plain_user!(fx)

      minted = [
        token!(fx, target, @admin),
        token!(fx, target, ["TASK_WORKER"]),
        token!(fx, target, ["TENANT_ADMIN", "TASK_WORKER"])
      ]

      conn = set_status(fx, caller, target, "inactive", :post)
      assert conn.status == 200, conn.resp_body

      revokes = entries(fx, "token.revoke")
      assert length(revokes) == length(minted)

      assert Enum.sort(Enum.map(revokes, & &1.resource_id)) ==
               Enum.sort(Enum.map(minted, fn {t, _} -> t.id end))

      by_id = Map.new(minted, fn {t, _} -> {t.id, t} end)

      for entry <- revokes do
        token = Map.fetch!(by_id, entry.resource_id)
        assert entry.resource_type == "api_token"
        assert entry.actor_id == caller.id
        assert entry.trace_id == @trace
        assert Enum.sort(Map.keys(entry.before_state)) == @audit_keys
        assert Enum.sort(Map.keys(entry.after_state)) == Enum.sort(["cause" | @audit_keys])
        assert entry.after_state["cause"] == "owner_deactivated"
        refute Map.has_key?(entry.before_state, "cause")
        assert entry.after_state["id"] == token.id
        assert entry.after_state["user_id"] == target.id
        assert entry.after_state["roles"] == token.roles
        assert entry.before_state["revoked_at"] == nil
        assert is_binary(entry.after_state["revoked_at"])
      end

      assert_no_leak!(Enum.map(revokes, &[&1.before_state, &1.after_state]), minted)

      [user_entry] = entries(fx, "user.update_status")
      assert user_entry.actor_id == caller.id
      assert user_entry.trace_id == @trace
      assert user_entry.after_state["revoked_token_count"] == 3
      assert user_entry.after_state["status"] == "inactive"
    end

    for path <- [:post, :patch] do
      test "#{path}: audit table dropped -> 500, user still active, every token revoked_at nil" do
        fx = sandboxed_tenant!()
        caller = caller!(fx)
        _other_admin = group_admin!(fx)
        target = plain_user!(fx)
        tokens = for roles <- [@admin, ["TASK_WORKER"]], do: elem(token!(fx, target, roles), 0)

        Repo.query!(~s(DROP TABLE "#{fx.schema_name}".audit_entries))

        conn = set_status(fx, caller, target, "inactive", unquote(path))
        assert conn.status == 500
        assert reload(fx, target).status == :active
        for t <- tokens, do: assert(reload(fx, t).revoked_at == nil)
      end
    end

    test "revoke step returns {:error, r}: {:error, {:token_revocation_failed, :invalid_schema_name}}, all rolled back" do
      fx = sandboxed_tenant!()
      _other_admin = group_admin!(fx)
      target = plain_user!(fx)
      tokens = for roles <- [@admin, ["TASK_WORKER"]], do: elem(token!(fx, target, roles), 0)

      # Transactional DDL inside this test's own sandbox transaction (undone at test
      # exit). Every step before the revoke works on the renamed schema; the first
      # token's Audit.insert_entry/3 cannot map the name to a tenant and returns
      # {:error, :invalid_schema_name}.
      renamed = "gh2564_revfail_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      Repo.query!(~s(ALTER SCHEMA "#{fx.schema_name}" RENAME TO "#{renamed}"))

      assert {:error, {:token_revocation_failed, :invalid_schema_name}} =
               Identity.update_user_status(target.id, :inactive,
                 prefix: renamed,
                 login_directory: :skip
               )

      assert Repo.get!(User, target.id, prefix: renamed).status == :active

      for t <- tokens do
        assert Repo.get!(ApiToken, t.id, prefix: renamed).revoked_at == nil
      end
    end
  end

  # --- AC3: reactivation resurrects none -------------------------------------------------------

  describe "reactivation restores no token" do
    for deactivate <- [:post, :patch], reactivate <- [:post, :patch] do
      test "deactivate via #{deactivate}, reactivate via #{reactivate}: TA token stays revoked, old plaintext 401" do
        fx = committed_tenant!()
        caller = caller!(fx)
        _group_admin = group_admin!(fx)
        {target, token, plaintext} = token_admin!(fx)

        assert old_plaintext_status(fx, plaintext) == 200

        assert set_status(fx, caller, target, "inactive", unquote(deactivate)).status == 200
        revoked_at = reload(fx, token).revoked_at
        assert %DateTime{} = revoked_at

        conn = set_status(fx, caller, target, "active", unquote(reactivate))
        assert conn.status == 200, conn.resp_body
        assert reload(fx, target).status == :active
        assert reload(fx, token).revoked_at == revoked_at
        assert old_plaintext_status(fx, plaintext) == 401
        assert length(entries(fx, "token.revoke")) == 1
      end
    end

    test "legacy: inactive user (Repo.update!) with a live token; POST active -> token revoked, 401" do
      fx = committed_tenant!()
      caller = caller!(fx)
      _group_admin = group_admin!(fx)
      target = plain_user!(fx)
      {token, plaintext} = token!(fx, target, ["TASK_WORKER"])
      target |> Ecto.Changeset.change(status: :inactive) |> Repo.update!(prefix: fx.schema_name)

      conn = set_status(fx, caller, target, "active", :post)
      assert conn.status == 200, conn.resp_body
      assert reload(fx, target).status == :active
      assert %DateTime{} = reload(fx, token).revoked_at
      assert old_plaintext_status(fx, plaintext) == 401

      assert [entry] = entries(fx, "token.revoke")
      assert entry.resource_id == token.id
      assert entry.after_state["cause"] == "owner_deactivated"
      [user_entry] = entries(fx, "user.update_status")
      assert user_entry.after_state["revoked_token_count"] == 1
    end

    test "POST inactive on an already-inactive user with a leftover live token -> token revoked, one token.revoke" do
      fx = committed_tenant!()
      caller = caller!(fx)
      target = plain_user!(fx)
      {token, _plaintext} = token!(fx, target, ["TASK_WORKER"])
      target |> Ecto.Changeset.change(status: :inactive) |> Repo.update!(prefix: fx.schema_name)

      conn = set_status(fx, caller, target, "inactive", :post)
      assert conn.status == 200, conn.resp_body
      assert %DateTime{} = reload(fx, token).revoked_at
      assert [entry] = entries(fx, "token.revoke")
      assert entry.resource_id == token.id
    end
  end

  # --- AC4: the token list shows revoked -------------------------------------------------------

  describe "token list" do
    test "GET /tokens after deactivation: status revoked, not owner_inactive; after reactivation still revoked" do
      fx = committed_tenant!()
      caller = caller!(fx)
      _group_admin = group_admin!(fx)
      target = plain_user!(fx)
      {token, _} = token!(fx, target, ["TASK_WORKER"])

      status_of = fn ->
        conn = call_as(:get, "/tokens", fx, caller, nil)
        assert conn.status == 200, conn.resp_body
        items = Jason.decode!(conn.resp_body)["items"]
        Enum.find_value(items, fn item -> item["id"] == token.id && item["status"] end)
      end

      assert status_of.() == "active"
      assert set_status(fx, caller, target, "inactive", :post).status == 200
      assert status_of.() == "revoked"
      assert set_status(fx, caller, target, "active", :post).status == 200
      assert status_of.() == "revoked"
    end
  end

  # --- AC5: 0051 N1 counts across deactivation and reactivation --------------------------------

  describe "zero-tenant-wide-admin guard" do
    for path <- [:post, :patch], holder <- [:group, :token] do
      test "#{path}: the last tenant-wide admin (#{holder}-held) -> 409, nothing changed, one guard_refused" do
        fx = committed_tenant!()
        caller = caller!(fx)

        target =
          case unquote(holder) do
            :group -> group_admin!(fx)
            :token -> fx |> token_admin!() |> elem(0)
          end

        {other_token, _} = token!(fx, target, ["TASK_WORKER"])
        assert Identity.count_tenant_wide_admins(fx.schema_name) == 1

        conn = set_status(fx, caller, target, "inactive", unquote(path))
        assert conn.status == 409, conn.resp_body
        assert detail(conn) == "last_tenant_wide_admin"
        refute conn.resp_body =~ target.id
        refute conn.resp_body =~ caller.id

        assert reload(fx, target).status == :active
        assert reload(fx, other_token).revoked_at == nil
        assert Identity.count_tenant_wide_admins(fx.schema_name) == 1
        assert entries(fx, "token.revoke") == []
        assert entries(fx, audit_action(unquote(path))) == []

        assert [refusal] = entries(fx, "tenant_admin.guard_refused")
        assert refusal.resource_type == "user"
        assert refusal.resource_id == target.id
        assert refusal.actor_id == caller.id
        assert refusal.trace_id == @trace
        assert refusal.before_state == nil
        assert Enum.sort(Map.keys(refusal.after_state)) == @refusal_keys

        assert refusal.after_state == %{
                 "action" => "deactivate_user",
                 "actor" => caller.id,
                 "target_id" => target.id,
                 "reason_code" => "last_tenant_wide_admin",
                 "counted_admins" => 0,
                 "trace_id" => @trace
               }
      end
    end

    test "two group-held admins: first deactivation 200, second 409; reactivate the first -> second 200" do
      fx = committed_tenant!()
      caller = caller!(fx)
      a1 = group_admin!(fx)
      a2 = group_admin!(fx)
      assert Identity.count_tenant_wide_admins(fx.schema_name) == 2

      assert set_status(fx, caller, a1, "inactive", :post).status == 200
      assert Identity.count_tenant_wide_admins(fx.schema_name) == 1

      conn = set_status(fx, caller, a2, "inactive", :post)
      assert conn.status == 409
      assert detail(conn) == "last_tenant_wide_admin"

      assert set_status(fx, caller, a1, "active", :patch).status == 200
      assert Identity.count_tenant_wide_admins(fx.schema_name) == 2
      assert set_status(fx, caller, a2, "inactive", :post).status == 200
      assert Identity.count_tenant_wide_admins(fx.schema_name) == 1
    end

    test "token-only admin T plus group admin G: deactivate T 200, reactivate T not counted, deactivate G 409" do
      fx = committed_tenant!()
      caller = caller!(fx)
      g = group_admin!(fx)
      {t, t_token, _} = token_admin!(fx)
      assert Identity.count_tenant_wide_admins(fx.schema_name) == 2

      assert set_status(fx, caller, t, "inactive", :post).status == 200
      assert %DateTime{} = reload(fx, t_token).revoked_at
      assert set_status(fx, caller, t, "active", :post).status == 200
      assert Identity.count_tenant_wide_admins(fx.schema_name) == 1
      assert Identity.tenant_wide_admin_user_ids(fx.schema_name) == [g.id]

      conn = set_status(fx, caller, g, "inactive", :post)
      assert conn.status == 409
      assert detail(conn) == "last_tenant_wide_admin"
      assert reload(fx, g).status == :active
    end

    test "a tenant with no tenant-wide admin: deactivating a plain user is 200" do
      fx = committed_tenant!()
      caller = caller!(fx)
      target = plain_user!(fx)
      assert Identity.count_tenant_wide_admins(fx.schema_name) == 0

      assert set_status(fx, caller, target, "inactive", :post).status == 200
      assert reload(fx, target).status == :inactive
      assert entries(fx, "tenant_admin.guard_refused") == []
    end

    test "the guard_refused write fails -> still 409, logged with error_kind, no value logged" do
      fx = sandboxed_tenant!()
      caller = caller!(fx)
      target = group_admin!(fx)

      # Inside this test's own sandbox transaction (undone at test exit): refuse exactly
      # the guard_refused insert.
      Repo.query!("""
      CREATE FUNCTION "#{fx.schema_name}".gh2564_refuse_guard_entry() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.action = 'tenant_admin.guard_refused' THEN
          RAISE EXCEPTION 'gh2564 forced guard_refused failure';
        END IF;
        RETURN NEW;
      END $$
      """)

      Repo.query!("""
      CREATE TRIGGER gh2564_refuse_guard_entry BEFORE INSERT ON "#{fx.schema_name}".audit_entries
      FOR EACH ROW EXECUTE FUNCTION "#{fx.schema_name}".gh2564_refuse_guard_entry()
      """)

      {conn, logs} =
        LoggerCollector.capture(
          fn -> set_status(fx, caller, target, "inactive", :post) end,
          raw: true,
          attribute_to: self()
        )

      assert conn.status == 409
      assert detail(conn) == "last_tenant_wide_admin"
      assert reload(fx, target).status == :active
      assert entries(fx, "tenant_admin.guard_refused") == []

      [line] =
        Enum.filter(logs, &(&1.text =~ "tenant_admin.guard_refused audit write failed"))

      assert line.level == :error
      assert line.text =~ "error_kind"
      assert line.text =~ "Postgrex.Error"
      assert line.text =~ target.id
      assert line.text =~ "deactivate_user"
      refute line.text =~ "gh2564 forced guard_refused failure"
    end

    test "record_guard_refused/2 inside Repo.transaction raises ArgumentError, no row written" do
      fx = sandboxed_tenant!()
      target = plain_user!(fx)

      refusal = %{
        action: "deactivate_user",
        actor: nil,
        target_id: target.id,
        reason_code: "last_tenant_wide_admin",
        counted_admins: 0,
        trace_id: nil
      }

      assert_raise ArgumentError, fn ->
        Repo.transaction(fn -> Identity.record_guard_refused(fx.schema_name, refusal) end)
      end

      assert entries(fx, "tenant_admin.guard_refused") == []

      # Outside a transaction the same call writes the row.
      assert :ok = Identity.record_guard_refused(fx.schema_name, refusal)
      assert [_] = entries(fx, "tenant_admin.guard_refused")
    end
  end

  # --- lock order -------------------------------------------------------------------------------

  describe "lock order" do
    test "POST status inactive, PATCH status inactive and PATCH status active each wait for the tenant admin lock" do
      fx = committed_tenant!()
      caller = caller!(fx)
      _group_admin = group_admin!(fx)
      u1 = plain_user!(fx)
      u2 = plain_user!(fx)

      for {user, status, path} <- [
            {u1, "inactive", :post},
            {u2, "inactive", :patch},
            {u1, "active", :patch}
          ] do
        holder = hold_tenant_admin_lock!(fx)
        write = Task.async(fn -> set_status(fx, caller, user, status, path) end)

        assert Task.yield(write, 500) == nil, "#{path} #{status} did not wait for the lock"
        release!(holder)
        conn = Task.await(write, 10_000)
        assert conn.status == 200, conn.resp_body
        assert Atom.to_string(reload(fx, user).status) == status
      end
    end

    test "PATCH display_name only does not wait for the lock; its entry has no revoked_token_count" do
      fx = committed_tenant!()
      caller = caller!(fx)
      target = plain_user!(fx)

      holder = hold_tenant_admin_lock!(fx)

      write =
        Task.async(fn ->
          call_as(:patch, "/users/#{target.id}", fx, caller, %{"display_name" => "Renamed"})
        end)

      conn = Task.await(write, 5_000)
      release!(holder)

      assert conn.status == 200, conn.resp_body
      assert reload(fx, target).display_name == "Renamed"
      [entry] = entries(fx, "user.update_profile")
      refute Map.has_key?(entry.after_state, "revoked_token_count")
      assert entry.actor_id == caller.id
    end

    test "concurrent deactivation of U and DELETE /tokens of U's token: both complete, one token.revoke" do
      fx = committed_tenant!()
      caller = caller!(fx)
      _group_admin = group_admin!(fx)
      target = plain_user!(fx)
      {token, _} = token!(fx, target, ["TASK_WORKER"])

      [deactivation, deletion] =
        [
          Task.async(fn -> set_status(fx, caller, target, "inactive", :post) end),
          Task.async(fn -> call_as(:delete, "/tokens/#{token.id}", fx, caller, nil) end)
        ]
        |> Enum.map(&Task.await(&1, 10_000))

      assert deactivation.status == 200, deactivation.resp_body
      assert deletion.status == 200, deletion.resp_body
      assert reload(fx, target).status == :inactive
      assert %DateTime{} = reload(fx, token).revoked_at
      assert [entry] = entries(fx, "token.revoke")
      assert entry.resource_id == token.id
    end

    test "race: concurrent deactivations of the only two group-held admins A and B -> one 200, one 409, one admin left" do
      fx = committed_tenant!()
      # The caller holds no admin source, so exactly A and B are counted.
      caller = caller!(fx)
      a = group_admin!(fx)
      b = group_admin!(fx)
      assert Identity.count_tenant_wide_admins(fx.schema_name) == 2

      tasks =
        for target <- [a, b] do
          Task.async(fn -> set_status(fx, caller, target, "inactive", :post) end)
        end

      results =
        tasks
        |> Task.yield_many(10_000)
        |> Enum.map(fn {task, res} ->
          case res || Task.shutdown(task, :brutal_kill) do
            {:ok, conn} -> conn
            other -> flunk("deactivation did not complete within 10 s: #{inspect(other)}")
          end
        end)

      [a_conn, b_conn] = results

      assert Enum.sort(Enum.map(results, & &1.status)) == [200, 409],
             "statuses #{a_conn.status} / #{b_conn.status}"

      [refused] = Enum.filter(results, &(&1.status == 409))
      assert detail(refused) == "last_tenant_wide_admin"

      {winner, loser} = if a_conn.status == 200, do: {a, b}, else: {b, a}
      assert reload(fx, winner).status == :inactive
      assert reload(fx, loser).status == :active
      assert Identity.count_tenant_wide_admins(fx.schema_name) == 1
      assert Identity.tenant_wide_admin_user_ids(fx.schema_name) == [loser.id]

      assert [refusal] = entries(fx, "tenant_admin.guard_refused")
      assert refusal.resource_id == loser.id
    end
  end
end
