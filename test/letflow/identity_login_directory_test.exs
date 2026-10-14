defmodule Letflow.IdentityLoginDirectoryTest do
  @moduledoc """
  REQ-435 -- the population hooks inside `Letflow.Identity`: `create_user/2`,
  `update_user_profile/3`, `update_user_status/3` and `provision_oidc_user/4`
  maintain `tenant_login_directory` in the same transaction as the user write.
  See `test/specs/REQ-435.md`.

  `async: false`: real tenant schemas, global key-config swaps and a global Logger
  level change (all restored in `on_exit/1`).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Identity
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.User
  alias Letflow.Oidc.IdentityContext
  alias Letflow.Oidc.JitProvisioningConfig
  alias Letflow.Test.LoggerCollector
  alias Letflow.Test.LoginDirectoryFixture, as: Fx

  # ── helpers ─────────────────────────────────────────────────────────────

  defp with_pepper(:unset), do: Fx.swap_keys!(:unset, nil)

  defp unique_username(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

  defp create!(tenant, email) do
    assert {:ok, user} =
             Identity.create_user(
               %{
                 "username" => unique_username("u"),
                 "display_name" => "Person",
                 "email" => email
               },
               prefix: tenant.schema_name,
               tenant_id: tenant.tenant_id
             )

    user
  end

  defp opts(tenant), do: [prefix: tenant.schema_name, tenant_id: tenant.tenant_id]

  defp keys(tenant), do: tenant.tenant_id |> Fx.entries() |> Enum.map(& &1.email_key)

  defp identity_context(overrides \\ %{}) do
    struct(
      %IdentityContext{
        external_user_id: Ecto.UUID.generate(),
        tenant_id: nil,
        realm: Letflow.TenantSlugFixture.unique_realm("jit"),
        roles: [],
        email: Fx.unique_email("jit"),
        preferred_username: unique_username("jit"),
        display_name: "Jit Person"
      },
      overrides
    )
  end

  defp jit_config(overrides \\ %{}) do
    struct(
      %JitProvisioningConfig{
        realm: "unused",
        enabled: true,
        default_status: :active,
        default_roles: []
      },
      overrides
    )
  end

  # A call window is the 600 bytes after each call site; it must mention the opt.
  defp callers_missing_tenant_id(files) do
    pattern = ~r/Identity\.(?:create_user|update_user_profile|update_user_status)\(/

    for file <- files,
        source = File.read!(file),
        [{start, _len}] <- Regex.scan(pattern, source, return: :index),
        window = binary_part(source, start, min(600, byte_size(source) - start)),
        not (window =~ "tenant_id" or window =~ "login_directory: :skip") do
      {file, String.slice(window, 0, 80)}
    end
  end

  # The text of a call's argument list, from just after its "(" to the matching ")".
  defp balanced_args(source, from, depth) do
    rest = binary_part(source, from, byte_size(source) - from)
    take_balanced(rest, depth, [])
  end

  defp take_balanced(<<>>, _depth, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp take_balanced(<<")", _::binary>>, 1, acc),
    do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp take_balanced(<<")", r::binary>>, d, acc), do: take_balanced(r, d - 1, [")" | acc])
  defp take_balanced(<<"(", r::binary>>, d, acc), do: take_balanced(r, d + 1, ["(" | acc])
  defp take_balanced(<<c, r::binary>>, d, acc), do: take_balanced(r, d, [<<c>> | acc])

  defp drop_audit_entries!(schema_name),
    do: Repo.query!(~s(DROP TABLE "#{schema_name}".audit_entries))

  # ── AC2 / AC3: create_user/2 ────────────────────────────────────────────

  describe "create_user/2" do
    test "creates exactly one entry for the normalised key of 'Alice@Example.com ' for the caller's tenant" do
      tenant = Fx.tenant!()
      user = create!(tenant, "Alice@Example.com ")

      assert user.email == "Alice@Example.com "
      assert keys(tenant) == [Fx.key!("alice@example.com")]
    end

    test "two users with the same email in one tenant still yield exactly one entry" do
      tenant = Fx.tenant!()
      create!(tenant, "same@example.test")
      create!(tenant, "SAME@example.test")

      assert [_] = Fx.entries(tenant.tenant_id)
    end

    test "tenant_id source: the entry belongs to the tenant_id passed, and the other tenant gets nothing" do
      a = Fx.tenant!()
      b = Fx.tenant!()
      create!(a, "only-a@example.test")

      assert [_] = Fx.entries(a.tenant_id)
      assert Fx.entries(b.tenant_id) == []
    end

    test "an invalid email shape or a non-active status writes no entry (the user is still created)" do
      tenant = Fx.tenant!()
      create!(tenant, "not-an-email")

      assert {:ok, _inactive} =
               Identity.create_user(
                 %{
                   "username" => unique_username("inact"),
                   "display_name" => "X",
                   "email" => Fx.unique_email("inact"),
                   "status" => "inactive"
                 },
                 opts(tenant)
               )

      assert Fx.user_count(tenant.schema_name) == 2
      assert Fx.entries(tenant.tenant_id) == []
    end

    test "a duplicate username fails and leaves no entry for the rejected row" do
      tenant = Fx.tenant!()
      username = unique_username("dup")

      attrs = fn email ->
        %{"username" => username, "display_name" => "D", "email" => email}
      end

      assert {:ok, _} = Identity.create_user(attrs.("first@example.test"), opts(tenant))

      assert {:error, :duplicate_username} =
               Identity.create_user(attrs.("second@example.test"), opts(tenant))

      assert keys(tenant) == [Fx.key!("first@example.test")]
    end

    test "a directory failure (pepper unavailable) fails the create and leaves no user" do
      tenant = Fx.tenant!()
      with_pepper(:unset)

      assert {:error, {:login_directory, :pepper_unavailable}} =
               Identity.create_user(
                 %{
                   "username" => unique_username("nopepper"),
                   "display_name" => "P",
                   "email" => "p@example.test"
                 },
                 opts(tenant)
               )

      assert Fx.user_count(tenant.schema_name) == 0
      assert Fx.entries(tenant.tenant_id) == []
    end

    test "a forced audit failure (after the directory step) leaves neither the user nor the entry" do
      tenant = Fx.tenant!()
      drop_audit_entries!(tenant.schema_name)

      assert {:error, {:transaction_failed, %Postgrex.Error{}}} =
               Identity.create_user(
                 %{
                   "username" => unique_username("auditfail"),
                   "display_name" => "A",
                   "email" => "auditfail@example.test"
                 },
                 opts(tenant)
               )

      assert Fx.user_count(tenant.schema_name) == 0
      assert Fx.entries(tenant.tenant_id) == []
    end
  end

  # ── AC3: fail-closed guard ──────────────────────────────────────────────

  describe "fail-closed tenant_id guard (create/profile/status)" do
    setup do
      a = Fx.tenant!()
      b = Fx.tenant!()
      user = create!(a, "guard-user@example.test")
      %{a: a, b: b, user: user}
    end

    test "create_user/2: malformed, mismatched and missing tenant_id write neither user nor entry",
         %{a: a, b: b} do
      attrs = %{
        "username" => unique_username("g"),
        "display_name" => "G",
        "email" => "g@example.test"
      }

      assert {:error, :invalid_tenant_id} =
               Identity.create_user(attrs, prefix: a.schema_name, tenant_id: "not-a-uuid")

      assert {:error, :tenant_prefix_mismatch} =
               Identity.create_user(attrs, prefix: a.schema_name, tenant_id: b.tenant_id)

      assert {:error, :tenant_id_required} = Identity.create_user(attrs, prefix: a.schema_name)

      # only the setup user exists in A, and nothing was written for g@example.test anywhere
      assert Fx.user_count(a.schema_name) == 1
      assert keys(a) == [Fx.key!("guard-user@example.test")]
      assert Fx.entries(b.tenant_id) == []
    end

    test "update_user_profile/3: guard errors write nothing", %{a: a, b: b, user: user} do
      changes = %{"email" => "changed@example.test"}

      assert {:error, :invalid_tenant_id} =
               Identity.update_user_profile(user.id, changes,
                 prefix: a.schema_name,
                 tenant_id: "zzz"
               )

      assert {:error, :tenant_prefix_mismatch} =
               Identity.update_user_profile(user.id, changes,
                 prefix: a.schema_name,
                 tenant_id: b.tenant_id
               )

      assert {:error, :tenant_id_required} =
               Identity.update_user_profile(user.id, changes, prefix: a.schema_name)

      assert Repo.get!(User, user.id, prefix: a.schema_name).email == "guard-user@example.test"
      assert keys(a) == [Fx.key!("guard-user@example.test")]
      assert Fx.entries(b.tenant_id) == []
    end

    test "update_user_status/3: guard errors write nothing", %{a: a, b: b, user: user} do
      assert {:error, :invalid_tenant_id} =
               Identity.update_user_status(user.id, :inactive,
                 prefix: a.schema_name,
                 tenant_id: "zzz"
               )

      assert {:error, :tenant_prefix_mismatch} =
               Identity.update_user_status(user.id, :inactive,
                 prefix: a.schema_name,
                 tenant_id: b.tenant_id
               )

      assert {:error, :tenant_id_required} =
               Identity.update_user_status(user.id, :inactive, prefix: a.schema_name)

      assert Repo.get!(User, user.id, prefix: a.schema_name).status == :active
      assert keys(a) == [Fx.key!("guard-user@example.test")]
    end

    test "tenant_id is accepted in non-canonical (uppercase) form and stored canonically", %{b: b} do
      user =
        create!(b, "canon@example.test")

      assert user.id
      assert [%{tenant_id: stored}] = Fx.entries(b.tenant_id)
      assert stored == b.tenant_id

      upper = String.upcase(b.tenant_id)

      assert {:ok, _} =
               Identity.create_user(
                 %{
                   "username" => unique_username("upper"),
                   "display_name" => "U",
                   "email" => "upper@example.test"
                 },
                 prefix: b.schema_name,
                 tenant_id: upper
               )

      assert Enum.all?(Fx.entries(b.tenant_id), &(&1.tenant_id == b.tenant_id))
      assert length(Fx.entries(b.tenant_id)) == 2
    end

    test "login_directory: :skip writes the user but no entry (test-only escape; no tenant_id needed)",
         %{a: a} do
      assert {:ok, _} =
               Identity.create_user(
                 %{
                   "username" => unique_username("skip"),
                   "display_name" => "S",
                   "email" => "skipped@example.test"
                 },
                 prefix: a.schema_name,
                 login_directory: :skip
               )

      refute Fx.key!("skipped@example.test") in keys(a)
    end
  end

  describe "grep guards (static)" do
    test "`login_directory: :skip` appears in no .ex/.exs file under lib/" do
      offenders =
        ["lib/**/*.ex", "lib/**/*.exs"]
        |> Enum.flat_map(&Path.wildcard/1)
        |> Enum.filter(&(File.read!(&1) =~ "login_directory: :skip"))

      assert offenders == []
    end

    test "every lib/ caller of the three user-write functions passes :tenant_id" do
      router = File.read!("lib/letflow/routers/identity.ex")

      assert router =~ "handle_create(conn, user_write_opts(conn))"
      assert router =~ ~s|handle_patch(conn, conn.params["id"], user_write_opts(conn))|
      assert router =~ ~s|handle_status_update(conn, conn.params["id"], user_write_opts(conn))|
      assert router =~ "conn.assigns.auth_context.tenant_id"

      assert callers_missing_tenant_id(["lib/mix/tasks/letflow.seed.exam_fixtures.ex"]) == []
    end

    test "every test/ caller of the three functions passes :tenant_id or login_directory: :skip" do
      files =
        Path.wildcard("test/**/*.{ex,exs}")
        |> Enum.reject(&String.contains?(&1, "login_directory"))
        |> Enum.reject(&String.starts_with?(&1, "test/specs/"))

      assert callers_missing_tenant_id(files) == []
    end

    test "no directory module builds SQL by string interpolation of a schema name (INV-7)" do
      for path <- [
            "lib/letflow/login_directory.ex",
            "lib/letflow/login_directory/backfill.ex",
            "lib/mix/tasks/letflow.backfill_login_directory.ex"
          ] do
        source = File.read!(path)
        refute source =~ ~r/Repo\.query!?\(\s*"[^"]*#\{/, "#{path} interpolates into SQL"
        refute source =~ ~r/fragment\(\s*"[^"]*#\{/, "#{path} interpolates into a fragment"
        refute source =~ ~r/search_path|DROP SCHEMA/i, "#{path} touches search_path/DDL"
      end
    end

    test "every Repo call in the directory modules carries log: false (INV-4)" do
      for path <- ["lib/letflow/login_directory.ex", "lib/letflow/login_directory/backfill.ex"] do
        source = File.read!(path)

        calls =
          Regex.scan(~r/Repo\.(?:all|exists\?|insert_all|delete_all|query!)\(/, source,
            return: :index
          )

        assert calls != []

        # Each call's balanced argument list must contain log: false.
        for [{start, len}] <- calls do
          args = balanced_args(source, start + len, 1)
          assert args =~ "log: false", "#{path}: a Repo call at byte #{start} lacks log: false"
        end
      end
    end
  end

  # ── AC4: JIT ────────────────────────────────────────────────────────────

  describe "provision_oidc_user/4 (JIT)" do
    test "first login writes the entry (normalised key, caller tenant); a second login adds none" do
      tenant = Fx.tenant!()
      ctx = identity_context(%{email: "  Jit.User@Example.TEST "})

      assert {:ok, %{user: %User{id: id}, created: true}} =
               Identity.provision_oidc_user(ctx, tenant.tenant_id, jit_config(),
                 prefix: tenant.schema_name
               )

      assert keys(tenant) == [Fx.key!("jit.user@example.test")]

      # Remove the entry out-of-band: a genuine second login (created: false)
      # must NOT write one -- only a created row writes an entry.
      Repo.delete_all(
        from(d in Letflow.Identity.TenantLoginDirectoryEntry,
          where: d.tenant_id == ^tenant.tenant_id
        )
      )

      assert {:ok, %{user: %User{id: ^id}, created: false}} =
               Identity.provision_oidc_user(ctx, tenant.tenant_id, jit_config(),
                 prefix: tenant.schema_name
               )

      assert Fx.entries(tenant.tenant_id) == []
    end

    test "two logins leave exactly one entry (idempotent)" do
      tenant = Fx.tenant!()
      ctx = identity_context()

      for _ <- 1..2,
          do:
            assert(
              {:ok, _} =
                Identity.provision_oidc_user(ctx, tenant.tenant_id, jit_config(),
                  prefix: tenant.schema_name
                )
            )

      assert [_] = Fx.entries(tenant.tenant_id)
    end

    test "a forced directory failure leaves no user row and returns {:error, {:login_directory, _}}" do
      tenant = Fx.tenant!()
      with_pepper(:unset)
      ctx = identity_context()

      assert {:error, {:login_directory, :pepper_unavailable}} =
               Identity.provision_oidc_user(ctx, tenant.tenant_id, jit_config(),
                 prefix: tenant.schema_name
               )

      assert Fx.user_count(tenant.schema_name) == 0
      assert Fx.entries(tenant.tenant_id) == []
    end

    test "a tenant_id/prefix mismatch fails closed: no user, no entry anywhere" do
      a = Fx.tenant!()
      b = Fx.tenant!()
      ctx = identity_context()

      assert {:error, {:login_directory, :tenant_prefix_mismatch}} =
               Identity.provision_oidc_user(ctx, b.tenant_id, jit_config(), prefix: a.schema_name)

      assert Fx.user_count(a.schema_name) == 0
      assert Fx.entries(a.tenant_id) == []
      assert Fx.entries(b.tenant_id) == []
    end

    test "an ineligible email (invalid shape) or non-active default status creates the user but no entry" do
      tenant = Fx.tenant!()

      assert {:ok, %{created: true}} =
               Identity.provision_oidc_user(
                 identity_context(%{email: "not-an-email"}),
                 tenant.tenant_id,
                 jit_config(),
                 prefix: tenant.schema_name
               )

      assert {:ok, %{created: true}} =
               Identity.provision_oidc_user(
                 identity_context(),
                 tenant.tenant_id,
                 jit_config(%{default_status: :inactive}),
                 prefix: tenant.schema_name
               )

      assert Fx.user_count(tenant.schema_name) == 2
      assert Fx.entries(tenant.tenant_id) == []
    end

    test "a user without an email creates no user and no entry" do
      tenant = Fx.tenant!()

      assert {:error, %Ecto.Changeset{}} =
               Identity.provision_oidc_user(
                 identity_context(%{email: nil}),
                 tenant.tenant_id,
                 jit_config(),
                 prefix: tenant.schema_name
               )

      assert Fx.user_count(tenant.schema_name) == 0
      assert Fx.entries(tenant.tenant_id) == []
    end

    test "sync_role_claims_from_token/3 still runs after the transaction: role grant written and marker stamped" do
      tenant = Fx.tenant!()
      role = "REQ435_ROLE"

      {:ok, group} =
        Identity.create_group(%{"name" => "req435-#{Ecto.UUID.generate()}"},
          prefix: tenant.schema_name
        )

      {:ok, _} =
        %Letflow.Identity.TenantRole{}
        |> Letflow.Identity.TenantRole.changeset(%{
          name: role,
          kind: :platform_role,
          group_id: group.id
        })
        |> Repo.insert(prefix: tenant.schema_name)

      ctx = identity_context(%{roles: [role]})

      assert {:ok, %{user: user, created: true}} =
               Identity.provision_oidc_user(ctx, tenant.tenant_id, jit_config(),
                 prefix: tenant.schema_name
               )

      assert %DateTime{} = user.role_claims_synced_at

      assert [%GroupMember{group_id: gid}] =
               Repo.all(from(m in GroupMember, where: m.user_id == ^user.id),
                 prefix: tenant.schema_name
               )

      assert gid == group.id
      assert [_] = Fx.entries(tenant.tenant_id)
    end

    test "source order: the role-claims sync is called after, not inside, the JIT transaction" do
      source = File.read!("lib/letflow/identity.ex")

      {tx_pos, _} =
        :binary.match(
          source,
          "defp insert_or_fetch(identity_context, tenant_id, jit_config, opts) do"
        )

      {sync_pos, _} =
        :binary.match(
          source,
          "synced_user = sync_role_claims_from_token(inserted, identity_context, opts)"
        )

      {inner_pos, _} = :binary.match(source, "defp insert_or_fetch_in_tx(")

      assert tx_pos < sync_pos and sync_pos < inner_pos
      inner_body = binary_part(source, inner_pos, 4000)
      refute inner_body =~ "sync_role_claims_from_token(inserted"
    end

    test "JIT username collision with a DIFFERENT identity: original changeset error, no abort, no entry, transaction usable" do
      tenant = Fx.tenant!()
      username = unique_username("taken")

      # A different identity (no external id) already holds the username.
      {:ok, _holder} =
        Identity.create_user(
          %{"username" => username, "display_name" => "H", "email" => "holder@example.test"},
          opts(tenant)
        )

      ctx = identity_context(%{preferred_username: username, email: "newcomer@example.test"})

      assert {:error, %Ecto.Changeset{errors: errors}} =
               Identity.provision_oidc_user(ctx, tenant.tenant_id, jit_config(),
                 prefix: tenant.schema_name
               )

      assert Keyword.has_key?(errors, :username)
      assert Fx.user_count(tenant.schema_name) == 1
      assert keys(tenant) == [Fx.key!("holder@example.test")]
    end
  end

  # ── AC4 / AC5: status and profile ───────────────────────────────────────

  describe "update_user_status/3" do
    test "inactive removes the entry; reactivating adds it back" do
      tenant = Fx.tenant!()
      user = create!(tenant, "status@example.test")
      assert [_] = Fx.entries(tenant.tenant_id)

      assert {:ok, %{status: :inactive}} =
               Identity.update_user_status(user.id, :inactive, opts(tenant))

      assert Fx.entries(tenant.tenant_id) == []

      assert {:ok, %{status: :active}} =
               Identity.update_user_status(user.id, :active, opts(tenant))

      assert keys(tenant) == [Fx.key!("status@example.test")]
    end

    test "a forced failure after the status write (audit table missing) leaves entry and status unchanged" do
      tenant = Fx.tenant!()
      user = create!(tenant, "atomic@example.test")
      drop_audit_entries!(tenant.schema_name)

      assert {:error, {:transaction_failed, %Postgrex.Error{}}} =
               Identity.update_user_status(user.id, :inactive, opts(tenant))

      assert Repo.get!(User, user.id, prefix: tenant.schema_name).status == :active
      assert keys(tenant) == [Fx.key!("atomic@example.test")]
    end

    test "a directory failure leaves the status unchanged and returns {:error, {:login_directory, _}}" do
      tenant = Fx.tenant!()
      user = create!(tenant, "dirfail@example.test")
      with_pepper(:unset)

      assert {:error, {:login_directory, :pepper_unavailable}} =
               Identity.update_user_status(user.id, :inactive, opts(tenant))

      assert Repo.get!(User, user.id, prefix: tenant.schema_name).status == :active
      assert [_] = Fx.entries(tenant.tenant_id)
    end

    test "unknown user id is {:error, :not_found} and touches nothing" do
      tenant = Fx.tenant!()
      create!(tenant, "bystander@example.test")

      assert {:error, :not_found} =
               Identity.update_user_status(Ecto.UUID.generate(), :inactive, opts(tenant))

      assert [_] = Fx.entries(tenant.tenant_id)
    end

    test "a status call that changes nothing (active -> active) leaves the entry" do
      tenant = Fx.tenant!()
      user = create!(tenant, "noop@example.test")

      assert {:ok, _} = Identity.update_user_status(user.id, :active, opts(tenant))
      assert [_] = Fx.entries(tenant.tenant_id)
    end
  end

  describe "other-active-user rule" do
    test "U1/U2 share 'dup@x.com': deactivating U1 keeps the entry, deactivating U2 removes it" do
      tenant = Fx.tenant!()
      u1 = create!(tenant, "dup@x.com")
      u2 = create!(tenant, "DUP@x.com ")
      assert [_] = Fx.entries(tenant.tenant_id)

      assert {:ok, _} = Identity.update_user_status(u1.id, :inactive, opts(tenant))
      assert keys(tenant) == [Fx.key!("dup@x.com")]

      assert {:ok, _} = Identity.update_user_status(u2.id, :inactive, opts(tenant))
      assert Fx.entries(tenant.tenant_id) == []
    end

    test "changing U2's email when U1 is inactive removes the old entry and adds the new one" do
      tenant = Fx.tenant!()
      u1 = create!(tenant, "dup@x.com")
      u2 = create!(tenant, "dup@x.com")
      assert {:ok, _} = Identity.update_user_status(u1.id, :inactive, opts(tenant))
      assert [_] = Fx.entries(tenant.tenant_id)

      assert {:ok, _} =
               Identity.update_user_profile(u2.id, %{"email" => "new@x.com"}, opts(tenant))

      assert keys(tenant) == [Fx.key!("new@x.com")]
    end

    test "changing U2's email while U1 is still active keeps the old entry and adds the new one" do
      tenant = Fx.tenant!()
      create!(tenant, "dup@x.com")
      u2 = create!(tenant, "dup@x.com")

      assert {:ok, _} =
               Identity.update_user_profile(u2.id, %{"email" => "new@x.com"}, opts(tenant))

      assert Enum.sort(keys(tenant)) == Enum.sort([Fx.key!("dup@x.com"), Fx.key!("new@x.com")])
    end
  end

  describe "update_user_profile/3" do
    test "a case-only or whitespace-only email change leaves the single entry in place" do
      tenant = Fx.tenant!()
      user = create!(tenant, "case@example.test")

      assert {:ok, _} =
               Identity.update_user_profile(
                 user.id,
                 %{"email" => " CASE@example.test"},
                 opts(tenant)
               )

      assert keys(tenant) == [Fx.key!("case@example.test")]
    end

    test "a display_name-only change touches no entry" do
      tenant = Fx.tenant!()
      user = create!(tenant, "name@example.test")

      assert {:ok, _} =
               Identity.update_user_profile(user.id, %{"display_name" => "New"}, opts(tenant))

      assert keys(tenant) == [Fx.key!("name@example.test")]
    end

    test "clearing the email (nil) is rejected by the NOT NULL column atomically: entry and email unchanged" do
      tenant = Fx.tenant!()
      user = create!(tenant, "clear@example.test")

      assert {:error, {:transaction_failed, %Postgrex.Error{}}} =
               Identity.update_user_profile(user.id, %{"email" => nil}, opts(tenant))

      assert Repo.get!(User, user.id, prefix: tenant.schema_name).email == "clear@example.test"
      assert keys(tenant) == [Fx.key!("clear@example.test")]
    end

    test "an invalid new email removes the old entry and adds none" do
      tenant = Fx.tenant!()
      user = create!(tenant, "valid@example.test")

      assert {:ok, _} =
               Identity.update_user_profile(user.id, %{"email" => "not-an-email"}, opts(tenant))

      assert Fx.entries(tenant.tenant_id) == []
    end

    test "an email change on an inactive user writes no entry" do
      tenant = Fx.tenant!()
      user = create!(tenant, "old@example.test")
      {:ok, _} = Identity.update_user_status(user.id, :inactive, opts(tenant))

      assert {:ok, _} =
               Identity.update_user_profile(
                 user.id,
                 %{"email" => "later@example.test"},
                 opts(tenant)
               )

      assert Fx.entries(tenant.tenant_id) == []
    end

    test "deactivating through the profile (status) path also removes the entry" do
      tenant = Fx.tenant!()
      user = create!(tenant, "viaprofile@example.test")

      assert {:ok, _} =
               Identity.update_user_profile(user.id, %{"status" => "inactive"}, opts(tenant))

      assert Fx.entries(tenant.tenant_id) == []
    end

    test "unknown id is :not_found; a forced audit failure leaves email and entry unchanged" do
      tenant = Fx.tenant!()
      user = create!(tenant, "before@example.test")

      assert {:error, :not_found} =
               Identity.update_user_profile(
                 Ecto.UUID.generate(),
                 %{"email" => "x@example.test"},
                 opts(tenant)
               )

      drop_audit_entries!(tenant.schema_name)

      assert {:error, {:transaction_failed, %Postgrex.Error{}}} =
               Identity.update_user_profile(
                 user.id,
                 %{"email" => "after@example.test"},
                 opts(tenant)
               )

      assert Repo.get!(User, user.id, prefix: tenant.schema_name).email == "before@example.test"
      assert keys(tenant) == [Fx.key!("before@example.test")]
    end
  end

  # ── AC10 (logging half): INV-4 ──────────────────────────────────────────

  describe "query logging (INV-4)" do
    setup do
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)
      %{tenant: Fx.tenant!()}
    end

    test "harness control: an ordinary Repo query binding an email IS logged at :debug", %{
      tenant: tenant
    } do
      email = "control-logged@example.test"

      {_, entries} =
        LoggerCollector.capture(
          fn ->
            Repo.exists?(from(u in User, where: u.email == ^email), prefix: tenant.schema_name)
          end,
          attribute_to: self()
        )

      log = LoggerCollector.text(entries)

      assert log =~ email
    end

    test "create, email change, deactivation and JIT log no directory query, email-key or advisory-lock parameter",
         %{tenant: tenant} do
      email = "Logged-Person@Example.TEST "
      lower = "logged-person@example.test"
      changed = "logged-changed@example.test"
      key = Fx.key!(lower)
      key2 = Fx.key!(changed)

      jit_ctx = identity_context(%{email: "jit-logged@example.test"})
      jit_key = Fx.key!("jit-logged@example.test")

      {_, entries} =
        LoggerCollector.capture(
          fn ->
            user = create!(tenant, email)
            {:ok, _} = Identity.update_user_profile(user.id, %{"email" => changed}, opts(tenant))
            {:ok, _} = Identity.update_user_status(user.id, :inactive, opts(tenant))

            {:ok, _} =
              Identity.provision_oidc_user(jit_ctx, tenant.tenant_id, jit_config(),
                prefix: tenant.schema_name
              )
          end,
          attribute_to: self()
        )

      log = LoggerCollector.text(entries)

      # The harness is capturing: the user write itself logs (pre-existing, not a directory query).
      assert log =~ "users"

      refute log =~ "tenant_login_directory"
      # The directory's (tenant_id, email_key) lock is never logged. GH 2564: a status
      # write now also takes the tenant admin lock (`lock_tenant_admins!/1`, a single
      # bigint derived from the schema prefix only, no address or key), which is logged
      # like any other query; only the directory's two-int form is refused here.
      refute log =~ "pg_advisory_xact_lock($1::int, $2::int)"
      refute log =~ "btrim"

      for k <- [key, key2, jit_key] do
        refute log =~ Base.encode16(k, case: :lower)
        refute log =~ Base.encode16(k, case: :upper)
        refute log =~ Base.encode64(k)
        refute log =~ Base.url_encode64(k)
        refute log =~ inspect(k, limit: :infinity)
      end

      # Any logged statement mentioning an address is a users/audit_entries write, never a directory one.
      # One collector entry per log event, so the check is per statement (the collector text has
      # no level prefix to split a joined string on).
      address_entries =
        Enum.filter(entries, fn %{text: t} ->
          t =~ lower or t =~ changed or t =~ "jit-logged@example.test"
        end)

      # Non-vacuity: the writes above really did log statements mentioning an address.
      assert address_entries != []

      for %{text: t} <- address_entries do
        assert t =~ ~r/users|audit_entries/,
               "address-bearing entry is not a users/audit write: #{t}"
      end
    end

    test "telemetry fires for a directory write even though it is not logged", %{tenant: tenant} do
      ref = make_ref()
      me = self()

      :telemetry.attach(
        {__MODULE__, ref},
        [:letflow, :repo, :query],
        fn _e, _m, meta, _c ->
          if self() == me, do: send(me, {:q, ref, meta.source})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

      create!(tenant, "telemetry@example.test")

      assert_received {:q, ^ref, "tenant_login_directory"}
    end
  end
end
