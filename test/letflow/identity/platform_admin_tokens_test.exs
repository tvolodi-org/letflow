defmodule Letflow.Identity.PlatformAdminTokensTest do
  @moduledoc """
  GH 2579: the inventory of standing PLATFORM_ADMIN tokens with no expiry, and the explicit
  re-mint act (`reissue/4`). Spec: `test/specs/GH-2579.md`.

  The act is tested through the core function. Its audit entries, its refusals and its
  file handling are the contract the runbook relies on.

  `async: false`: the platform tenant pin is VM-global (`Letflow.Support.PlatformTenantFixture`).
  """

  use Letflow.DataCase, async: false

  import Bitwise
  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.Identity
  alias Letflow.Identity.ApiToken
  alias Letflow.Identity.PlatformAdminTokens
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.TokenMintFixture, as: Mint

  # GH 2579 design section 5: the token.create and token.revoke state keys (no hash, no name).
  @audit_keys Enum.sort(
                ~w(id user_id issuer_user_id roles expires_at revoked_at last_used_at inserted_at scope)
              )

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    tenants
  end

  # --- helpers ---------------------------------------------------------------------------------

  defp owner!(p), do: Mint.role_holder!(p.schema_name, ["PLATFORM_ADMIN"])
  defp operator!(p), do: Mint.role_holder!(p.schema_name, ["PLATFORM_ADMIN"])

  # A legacy row: non-expiring PLATFORM_ADMIN with NO issuer (the trusted `create_token/3` path).
  defp legacy_pa_token!(p, owner) do
    {:ok, %{token: token, plaintext: plaintext}} =
      Identity.create_token(owner.id, %{roles: ["PLATFORM_ADMIN"], expires_at: nil},
        prefix: p.schema_name
      )

    {token, plaintext}
  end

  defp expiring_pa_token!(p, owner, days) do
    expires_at =
      DateTime.utc_now() |> DateTime.add(days * 86_400, :second) |> DateTime.truncate(:second)

    {:ok, %{token: token, plaintext: plaintext}} =
      Identity.mint_token(
        owner.id,
        owner.id,
        %{roles: ["PLATFORM_ADMIN"], expires_at: expires_at},
        prefix: p.schema_name
      )

    {token, plaintext}
  end

  defp token!(p, id), do: Repo.get!(ApiToken, id, prefix: p.schema_name)

  defp token_count(p), do: Repo.aggregate(ApiToken, :count, prefix: p.schema_name)

  defp audit_count(p), do: Repo.aggregate(Entry, :count, prefix: p.schema_name)

  defp entries(p, action, resource_id) do
    Repo.all(
      from(e in Entry, where: e.action == ^action and e.resource_id == ^resource_id),
      prefix: p.schema_name
    )
  end

  defp opts(tmp_dir, extra \\ []) do
    Keyword.merge(
      [cause: "rotate legacy token", plaintext_file: Path.join(tmp_dir, "new-token.txt")],
      extra
    )
  end

  defp cap, do: Identity.platform_admin_token_max_ttl_days()

  # --- inventory (AC1, AC4) ----------------------------------------------------------------------

  describe "inventory/1" do
    test "T1: lists a seeded non-expiring PLATFORM_ADMIN token with its owner, legacy issuer and timestamps",
         %{p: p} do
      owner = owner!(p)
      {token, _plaintext} = legacy_pa_token!(p, owner)

      assert [row] = PlatformAdminTokens.inventory(p.schema_name)
      assert row.id == token.id
      assert row.owner_user_id == owner.id
      assert row.issuer_user_id == nil
      assert %DateTime{} = row.created_at
      assert row.last_used_at == nil
    end

    test "T2: ignores a PLATFORM_ADMIN token that expires", %{p: p} do
      owner = owner!(p)
      {_token, _} = expiring_pa_token!(p, owner, 30)

      assert PlatformAdminTokens.inventory(p.schema_name) == []
    end

    test "T3: ignores a non-expiring token that does not carry PLATFORM_ADMIN", %{p: p} do
      owner = owner!(p)

      {:ok, _} =
        Identity.create_token(owner.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
          prefix: p.schema_name
        )

      assert PlatformAdminTokens.inventory(p.schema_name) == []
    end

    test "T4: ignores a revoked non-expiring PLATFORM_ADMIN token (it cannot authenticate)", %{
      p: p
    } do
      owner = owner!(p)
      {token, _} = legacy_pa_token!(p, owner)
      {:ok, _} = Identity.revoke_token(token.id, prefix: p.schema_name)

      assert PlatformAdminTokens.inventory(p.schema_name) == []
    end

    test "T5: a non-expiring token that has an issuer is listed with that issuer, not as legacy",
         %{p: p} do
      owner = owner!(p)
      operator = operator!(p)
      {token, _} = legacy_pa_token!(p, owner)

      # Only the database can produce this row: the HTTP mint refuses a PLATFORM_ADMIN token with
      # no expiry, so the issuer is set directly on the legacy row.
      token
      |> Ecto.Changeset.change(issuer_user_id: operator.id)
      |> Repo.update!(prefix: p.schema_name)

      assert [row] = PlatformAdminTokens.inventory(p.schema_name)
      assert row.issuer_user_id == operator.id
    end

    test "T6: the rows carry no token value, hash or name and only the reported fields", %{p: p} do
      owner = owner!(p)
      {_token, plaintext} = legacy_pa_token!(p, owner)

      rows = PlatformAdminTokens.inventory(p.schema_name)
      [row] = rows

      assert Enum.sort(Map.keys(row)) ==
               Enum.sort([:id, :owner_user_id, :issuer_user_id, :created_at, :last_used_at])

      refute inspect(rows) =~ plaintext
      refute inspect(rows) =~ "lf_tok_"
      refute inspect(rows) =~ "token-"
    end
  end

  # --- the act (AC2) -------------------------------------------------------------------------

  describe "reissue/4 refusals" do
    @tag :tmp_dir
    test "T8: every refusal before the act writes no token, no audit entry and no file",
         %{p: p, tmp_dir: tmp_dir} do
      owner = owner!(p)
      operator = operator!(p)
      {token, _} = legacy_pa_token!(p, owner)
      {expiring, _} = expiring_pa_token!(p, owner, 30)
      plain_operator = Mint.role_holder!(p.schema_name, ["TENANT_ADMIN"])
      inactive_operator = Mint.role_holder!(p.schema_name, ["PLATFORM_ADMIN"], status: :inactive)
      tenant_id = p.tenant_id
      unknown_tenant = Ecto.UUID.generate()

      tokens_before = token_count(p)
      audit_before = audit_count(p)

      cases = [
        {:unknown_tenant, unknown_tenant, token.id, operator.id, opts(tmp_dir)},
        {:not_found, tenant_id, Ecto.UUID.generate(), operator.id, opts(tmp_dir)},
        {:not_found, tenant_id, "not-a-uuid", operator.id, opts(tmp_dir)},
        {:not_non_expiring_platform_admin, tenant_id, expiring.id, operator.id, opts(tmp_dir)},
        {:operator_not_platform_admin, tenant_id, token.id, plain_operator.id, opts(tmp_dir)},
        {:operator_not_platform_admin, tenant_id, token.id, inactive_operator.id, opts(tmp_dir)},
        {:operator_not_platform_admin, tenant_id, token.id, "not-a-uuid", opts(tmp_dir)},
        {:invalid_cause, tenant_id, token.id, operator.id, opts(tmp_dir, cause: "")},
        {:invalid_cause, tenant_id, token.id, operator.id,
         opts(tmp_dir, cause: String.duplicate("x", 201))},
        {:invalid_cause, tenant_id, token.id, operator.id,
         opts(tmp_dir, cause: "bad\u0007cause")},
        {:invalid_cause, tenant_id, token.id, operator.id, opts(tmp_dir, cause: nil)},
        {:invalid_days, tenant_id, token.id, operator.id, opts(tmp_dir, days: 0)},
        {:invalid_days, tenant_id, token.id, operator.id, opts(tmp_dir, days: cap() + 1)},
        {:invalid_plaintext_file, tenant_id, token.id, operator.id,
         opts(tmp_dir, plaintext_file: "")}
      ]

      for {reason, tenant, token_id, operator_id, case_opts} <- cases do
        assert {:error, ^reason} =
                 PlatformAdminTokens.reissue(tenant, token_id, operator_id, case_opts),
               "expected #{inspect(reason)}"
      end

      assert token_count(p) == tokens_before
      assert audit_count(p) == audit_before
      assert File.ls!(tmp_dir) == []
      assert token!(p, token.id).revoked_at == nil
    end

    @tag :tmp_dir
    test "T8b: a token that is already revoked is refused as :already_revoked", %{
      p: p,
      tmp_dir: tmp_dir
    } do
      owner = owner!(p)
      operator = operator!(p)
      {token, _} = legacy_pa_token!(p, owner)
      {:ok, _} = Identity.revoke_token(token.id, prefix: p.schema_name)

      assert {:error, :already_revoked} =
               PlatformAdminTokens.reissue(p.tenant_id, token.id, operator.id, opts(tmp_dir))

      assert File.ls!(tmp_dir) == []
    end
  end

  describe "reissue/4 success" do
    @tag :tmp_dir
    test "T9: mints a replacement inside the cap, revokes the old token, and audits both with cause, actor and one trace id",
         %{p: p, tmp_dir: tmp_dir} do
      owner = owner!(p)
      operator = operator!(p)
      {old, _} = legacy_pa_token!(p, owner)

      assert {:ok, done} =
               PlatformAdminTokens.reissue(p.tenant_id, old.id, operator.id, opts(tmp_dir))

      assert done.old_token_id == old.id
      assert done.owner_user_id == owner.id
      assert done.new_token_id != old.id

      # The replacement expires within the cap, and not in the past.
      new = token!(p, done.new_token_id)
      assert DateTime.compare(new.expires_at, DateTime.utc_now()) == :gt

      assert DateTime.compare(
               new.expires_at,
               DateTime.utc_now() |> DateTime.add(cap() * 86_400 + 60, :second)
             ) == :lt

      assert new.user_id == owner.id
      assert new.issuer_user_id == owner.id

      # The old token is revoked.
      assert token!(p, old.id).revoked_at != nil

      # token.create: the issuer is the owner, the actor is the operator, and the cause is recorded.
      [created] = entries(p, "token.create", new.id)
      assert created.actor_id == operator.id
      assert created.after_state["issuer_user_id"] == owner.id
      assert created.after_state["cause"] == "rotate legacy token"
      assert Enum.sort(Map.keys(created.after_state)) == Enum.sort(["cause" | @audit_keys])

      # token.revoke: the same actor, the same cause, and the same trace id as the create.
      [revoked] = entries(p, "token.revoke", old.id)
      assert revoked.actor_id == operator.id
      assert revoked.after_state["cause"] == "rotate legacy token"
      assert is_binary(created.trace_id) and created.trace_id != ""
      assert revoked.trace_id == created.trace_id

      # No token value or hash reaches either audit entry, or the returned map.
      for entry <- [created, revoked] do
        refute inspect(entry.after_state) =~ "lf_tok_"
        refute Map.has_key?(entry.after_state, "token_hash")
      end

      refute inspect(done) =~ "lf_tok_"
    end

    @tag :tmp_dir
    test "T10: writes the new value to the file after the mint; the file's value works and the old one is refused",
         %{p: p, tmp_dir: tmp_dir} do
      owner = owner!(p)
      operator = operator!(p)
      {old, old_plaintext} = legacy_pa_token!(p, owner)
      path = Path.join(tmp_dir, "new-token.txt")

      assert {:ok, _done} =
               PlatformAdminTokens.reissue(p.tenant_id, old.id, operator.id, opts(tmp_dir))

      new_plaintext = File.read!(path)
      assert String.starts_with?(new_plaintext, "lf_tok_")

      assert {:ok, %{user_id: user_id, roles: ["PLATFORM_ADMIN"]}} =
               Identity.verify_api_token(new_plaintext, prefix: p.schema_name)

      assert user_id == owner.id
      assert {:error, :revoked} = Identity.verify_api_token(old_plaintext, prefix: p.schema_name)
    end

    @tag :tmp_dir
    test "T10b: the file check runs first: a pre-existing file refuses the act with no row, no audit entry, and the old token live",
         %{p: p, tmp_dir: tmp_dir} do
      owner = owner!(p)
      operator = operator!(p)
      {old, old_plaintext} = legacy_pa_token!(p, owner)
      path = Path.join(tmp_dir, "new-token.txt")
      File.write!(path, "earlier run, keep me")

      tokens_before = token_count(p)
      audit_before = audit_count(p)

      assert {:error, :plaintext_file_exists} =
               PlatformAdminTokens.reissue(p.tenant_id, old.id, operator.id, opts(tmp_dir))

      assert token_count(p) == tokens_before
      assert audit_count(p) == audit_before
      assert token!(p, old.id).revoked_at == nil
      assert {:ok, _} = Identity.verify_api_token(old_plaintext, prefix: p.schema_name)
      assert File.read!(path) == "earlier run, keep me"
    end

    @tag :tmp_dir
    test "T15: a write failure after the mint revokes the NEW token with the cause, keeps the old one, and removes the file",
         %{p: p, tmp_dir: tmp_dir} do
      owner = owner!(p)
      operator = operator!(p)
      {old, old_plaintext} = legacy_pa_token!(p, owner)
      path = Path.join(tmp_dir, "new-token.txt")
      test_pid = self()

      # The seam sees the state at the moment of the write: the token.create entry must exist.
      writer = fn _io, _plaintext ->
        creates =
          Repo.aggregate(from(e in Entry, where: e.action == "token.create"), :count,
            prefix: p.schema_name
          )

        send(test_pid, {:creates_at_write, creates})
        {:error, :enospc}
      end

      creates_before =
        Repo.aggregate(from(e in Entry, where: e.action == "token.create"), :count,
          prefix: p.schema_name
        )

      assert {:error, {:plaintext_write_failed, new_id, :enospc}} =
               PlatformAdminTokens.reissue(
                 p.tenant_id,
                 old.id,
                 operator.id,
                 opts(tmp_dir, write_plaintext: writer)
               )

      assert_received {:creates_at_write, creates}
      assert creates == creates_before + 1

      new = token!(p, new_id)
      assert new.revoked_at != nil
      [revoked] = entries(p, "token.revoke", new_id)
      assert revoked.after_state["cause"] == "rotate legacy token"

      assert token!(p, old.id).revoked_at == nil
      assert {:ok, _} = Identity.verify_api_token(old_plaintext, prefix: p.schema_name)
      refute File.exists?(path)
    end

    @tag :tmp_dir
    @tag skip:
           if(match?({:win32, _}, :os.type()),
             do: "POSIX file modes do not exist on Windows; the 0600 check runs on Linux CI",
             else: false
           )
    test "T16: the plaintext file is restricted to its owner (0600) after a successful act",
         %{p: p, tmp_dir: tmp_dir} do
      owner = owner!(p)
      operator = operator!(p)
      {old, _old_plaintext} = legacy_pa_token!(p, owner)
      path = Path.join(tmp_dir, "new-token.txt")

      assert {:ok, _} =
               PlatformAdminTokens.reissue(p.tenant_id, old.id, operator.id, opts(tmp_dir))

      assert (File.stat!(path).mode &&& 0o777) == 0o600
    end
  end

  # --- the revoke audit keys (D4, pins) ----------------------------------------------------------

  describe "token.revoke cause" do
    test "T12: a revoke without a cause keeps the exact audit keys; with a cause the key is added",
         %{p: p} do
      owner = owner!(p)

      {:ok, %{token: plain, plaintext: _}} =
        Identity.create_token(owner.id, %{roles: ["PLATFORM_ADMIN"], expires_at: nil},
          prefix: p.schema_name
        )

      {:ok, _} = Identity.revoke_token(plain.id, prefix: p.schema_name)
      [no_cause] = entries(p, "token.revoke", plain.id)
      assert Enum.sort(Map.keys(no_cause.after_state)) == @audit_keys

      {:ok, %{token: with_cause}} = mint_pa(p, owner)
      {:ok, _} = Identity.revoke_token(with_cause.id, prefix: p.schema_name, cause: "rotation")
      [caused] = entries(p, "token.revoke", with_cause.id)
      assert Enum.sort(Map.keys(caused.after_state)) == Enum.sort(["cause" | @audit_keys])
      assert caused.after_state["cause"] == "rotation"
    end
  end

  defp mint_pa(p, owner) do
    expires_at = DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.truncate(:second)

    Identity.mint_token(owner.id, owner.id, %{roles: ["PLATFORM_ADMIN"], expires_at: expires_at},
      prefix: p.schema_name
    )
  end
end
