defmodule Letflow.Routers.Gh2552TokenIssuerTest do
  @moduledoc """
  GH 2552 (decision 0051 M2; design `lib/letflow/design/gh2552-api-token-issuer-and-roles.md`
  section 10): API tokens record their issuer, token roles must be held by BOTH the minter and
  the target, only a tenant-wide TENANT_ADMIN mints (plus the confirmed PLATFORM_ADMIN
  exception in the platform tenant, with its self-target and expiry conditions), the audit
  carries issuer/target/roles/expiry and never the hash or its prefix, and the token list
  reports an effective status including `owner_inactive`. Spec: `test/specs/GH-2552.md`.

  HTTP tests dispatch `Letflow.Routers.Identity.call/2` with a hand-assigned `auth_context`
  whose `user_id` is a REAL user of the tenant (`call_as/6`); roles are held by group
  membership (`Letflow.Support.TokenMintFixture`).

  `async: false`: the fixture flips the sandbox to `:auto` (real commits, needed by the race
  test) and the platform pin is VM-global.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit
  alias Letflow.Audit.Entry
  alias Letflow.Identity
  alias Letflow.Identity.ApiToken
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.TokenMintFixture, as: Mint

  @admin ["TENANT_ADMIN"]
  @operator ["PLATFORM_ADMIN"]
  @trace "gh2552-trace-0001"

  # design section 5: token.create / token.revoke state keys
  @audit_keys Enum.sort(
                ~w(id user_id issuer_user_id roles expires_at revoked_at last_used_at inserted_at scope)
              )

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, tenants}
  end

  # --- helpers ---------------------------------------------------------------------------------

  defp call_as(method, path, fx, user_id, roles, body) do
    method
    |> Fixture.router_conn(path, fx, roles, body)
    |> Plug.Conn.assign(:auth_context, %{user_id: user_id, tenant_id: fx.tenant_id, roles: roles})
    |> Plug.Conn.assign(:trace_id, @trace)
    |> Letflow.Routers.Identity.call(Letflow.Routers.Identity.init([]))
  end

  defp post_token(fx, caller, body), do: call_as(:post, "/tokens", fx, caller.id, @admin, body)

  defp holder!(fx, roles), do: Mint.role_holder!(fx.schema_name, roles)

  defp deactivate!(fx, %User{} = user) do
    user |> Ecto.Changeset.change(status: :inactive) |> Repo.update!(prefix: fx.schema_name)
  end

  defp token_count(fx), do: Repo.aggregate(ApiToken, :count, prefix: fx.schema_name)

  defp entries(fx, action) do
    Repo.all(from(e in Entry, where: e.action == ^action, order_by: e.timestamp),
      prefix: fx.schema_name
    )
  end

  defp code(conn), do: Jason.decode!(conn.resp_body)["detail"] || conn.resp_body

  defp assert_422(conn, code) do
    assert conn.status == 422, conn.resp_body
    assert conn.resp_body =~ code, conn.resp_body
  end

  defp in_days(days, extra_seconds \\ 0) do
    DateTime.utc_now()
    |> DateTime.add(days * 86_400 + extra_seconds, :second)
    |> DateTime.truncate(:second)
  end

  # Registers ONE on_exit that restores :platform_admin_token_max_ttl_days to its value at
  # the time of the call (or deletes it if it was unset), so a test may put_env freely.
  defp restore_ttl_env_on_exit do
    previous = Application.fetch_env(:letflow, :platform_admin_token_max_ttl_days)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:letflow, :platform_admin_token_max_ttl_days, value)
        :error -> Application.delete_env(:letflow, :platform_admin_token_max_ttl_days)
      end
    end)
  end

  defp post_pa_token(p, operator, expires_at) do
    call_as(:post, "/tokens", p, operator.id, @operator, %{
      "user_id" => operator.id,
      "roles" => @operator,
      "expires_at" => DateTime.to_iso8601(expires_at)
    })
  end

  defp list_items(fx, caller) do
    conn = call_as(:get, "/tokens", fx, caller.id, @admin, nil)
    assert conn.status == 200, conn.resp_body
    Jason.decode!(conn.resp_body)["items"]
  end

  # --- AC: issuer column, server-set, legacy NULL ------------------------------------------------

  describe "issuer_user_id" do
    test "mint records caller as issuer_user_id", %{a: a} do
      minter = holder!(a, ["TENANT_ADMIN", "TASK_WORKER"])
      target = holder!(a, ["TASK_WORKER"])

      conn = post_token(a, minter, %{"user_id" => target.id, "roles" => ["TASK_WORKER"]})
      assert conn.status == 201, conn.resp_body
      body = Jason.decode!(conn.resp_body)

      assert body["issuer_user_id"] == minter.id
      assert body["user_id"] == target.id
      row = Repo.get!(ApiToken, body["id"], prefix: a.schema_name)
      assert row.issuer_user_id == minter.id
      assert row.user_id == target.id
    end

    test "body issuer_user_id -> 422 issuer_user_id_not_allowed, no row, no audit", %{a: a} do
      minter = holder!(a, ["TENANT_ADMIN", "TASK_WORKER"])
      target = holder!(a, ["TASK_WORKER"])
      before = token_count(a)

      for value <- [minter.id, target.id, nil, "x"] do
        conn =
          post_token(a, minter, %{
            "user_id" => target.id,
            "roles" => ["TASK_WORKER"],
            "issuer_user_id" => value
          })

        assert_422(conn, "issuer_user_id_not_allowed")
      end

      assert token_count(a) == before
      assert entries(a, "token.create") == []
    end

    test "create_token/3 row has NULL issuer, authenticates via verify_api_token/2, lists with issuer_user_id null",
         %{a: a} do
      owner = holder!(a, ["TASK_WORKER"])
      admin = holder!(a, @admin)

      {:ok, %{token: token, plaintext: plaintext}} =
        Identity.create_token(owner.id, %{roles: ["TASK_WORKER"], expires_at: nil},
          prefix: a.schema_name
        )

      assert token.issuer_user_id == nil
      assert Repo.get!(ApiToken, token.id, prefix: a.schema_name).issuer_user_id == nil

      assert {:ok, %{user_id: owner_id, roles: ["TASK_WORKER"]}} =
               Identity.verify_api_token(plaintext, prefix: a.schema_name)

      assert owner_id == owner.id

      item = Enum.find(list_items(a, admin), &(&1["id"] == token.id))
      assert Map.has_key?(item, "issuer_user_id")
      assert item["issuer_user_id"] == nil
      assert item["status"] == "active"
    end

    test "information_schema: api_tokens.issuer_user_id is_nullable YES, column_default NULL",
         %{a: a} do
      %{rows: rows} =
        Repo.query!(
          "SELECT is_nullable, column_default, data_type FROM information_schema.columns " <>
            "WHERE table_schema = $1 AND table_name = 'api_tokens' AND column_name = 'issuer_user_id'",
          [a.schema_name]
        )

      assert rows == [["YES", nil, "uuid"]]
    end
  end

  # --- AC: roles subset of minter AND target --------------------------------------------------

  describe "roles subset (0051 M2)" do
    test "role not held by target -> 422 roles_invalid", %{a: a} do
      minter = holder!(a, ["TENANT_ADMIN", "TASK_WORKER", "PROCESS_DESIGNER"])
      target = holder!(a, ["TASK_WORKER"])

      conn =
        post_token(a, minter, %{
          "user_id" => target.id,
          "roles" => ["TASK_WORKER", "PROCESS_DESIGNER"]
        })

      assert_422(conn, "roles_invalid")
      assert token_count(a) == 0

      assert {:error, :roles_not_held} =
               Identity.mint_token(
                 minter.id,
                 target.id,
                 %{roles: ["PROCESS_DESIGNER"], expires_at: nil},
                 prefix: a.schema_name
               )
    end

    test "role not held by minter -> 422 roles_invalid", %{a: a} do
      minter = holder!(a, @admin)
      target = holder!(a, ["TASK_WORKER"])

      conn = post_token(a, minter, %{"user_id" => target.id, "roles" => ["TASK_WORKER"]})
      assert_422(conn, "roles_invalid")
      assert token_count(a) == 0
    end

    test "role held only via target's token -> 422", %{a: a} do
      minter = holder!(a, ["TENANT_ADMIN", "TASK_WORKER"])
      target = holder!(a, [])

      {:ok, _} =
        Identity.create_token(target.id, %{roles: ["TASK_WORKER"], expires_at: nil},
          prefix: a.schema_name
        )

      conn = post_token(a, minter, %{"user_id" => target.id, "roles" => ["TASK_WORKER"]})
      assert_422(conn, "roles_invalid")
      assert token_count(a) == 1
    end

    test "empty roles -> 422 roles_invalid", %{a: a} do
      minter = holder!(a, @admin)
      target = holder!(a, @admin)

      conn = post_token(a, minter, %{"user_id" => target.id, "roles" => []})
      assert_422(conn, "roles_invalid")
      assert token_count(a) == 0
    end

    test "the 422 body is fixed: identical for the target, minter and empty cases", %{a: a} do
      minter = holder!(a, ["TENANT_ADMIN", "TASK_WORKER"])
      target = holder!(a, ["TASK_WORKER"])

      bodies =
        for roles <- [["PROCESS_DESIGNER"], ["TENANT_ADMIN"], []] do
          conn = post_token(a, minter, %{"user_id" => target.id, "roles" => roles})
          assert conn.status == 422
          conn.resp_body
        end

      assert length(Enum.uniq(bodies)) == 1
      refute hd(bodies) =~ target.id
      refute hd(bodies) =~ minter.id
    end

    test "non-admin caller with bad roles -> 403, not 422", %{a: a} do
      caller = holder!(a, ["TASK_WORKER"])
      target = holder!(a, ["TASK_WORKER"])
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_iso8601()

      for body <- [
            %{"user_id" => target.id, "roles" => ["NOT_A_ROLE"]},
            %{"user_id" => target.id, "roles" => []},
            %{"user_id" => target.id, "roles" => ["PROCESS_DESIGNER"]},
            %{"user_id" => Ecto.UUID.generate(), "roles" => ["TASK_WORKER"]},
            %{"user_id" => target.id, "roles" => ["TASK_WORKER"], "expires_at" => past}
          ] do
        conn = post_token(a, caller, body)
        assert conn.status == 403, "#{inspect(body)}: #{conn.status} #{conn.resp_body}"
      end

      assert token_count(a) == 0
    end
  end

  # --- AC: audit metadata ----------------------------------------------------------------------

  describe "audit" do
    test "token.create after_state has issuer_user_id,user_id,roles,expires_at,scope; actor/trace columns set; no token_hash, name or lf_tok_",
         %{a: a} do
      minter = holder!(a, ["TENANT_ADMIN", "TASK_WORKER"])
      target = holder!(a, ["TASK_WORKER"])
      expires_at = in_days(30)

      conn =
        post_token(a, minter, %{
          "user_id" => target.id,
          "roles" => ["TASK_WORKER"],
          "expires_at" => DateTime.to_iso8601(expires_at)
        })

      assert conn.status == 201, conn.resp_body
      body = Jason.decode!(conn.resp_body)
      row = Repo.get!(ApiToken, body["id"], prefix: a.schema_name)

      assert [entry] = entries(a, "token.create")
      assert entry.actor_id == minter.id
      assert entry.trace_id == @trace
      assert entry.resource_id == row.id
      assert entry.before_state == nil
      assert Enum.sort(Map.keys(entry.after_state)) == @audit_keys
      assert entry.after_state["issuer_user_id"] == minter.id
      assert entry.after_state["user_id"] == target.id
      assert entry.after_state["roles"] == ["TASK_WORKER"]
      assert entry.after_state["scope"] == "tenant_wide"
      {:ok, audited_expiry, 0} = DateTime.from_iso8601(entry.after_state["expires_at"])
      assert DateTime.compare(audited_expiry, expires_at) == :eq

      encoded = Jason.encode!(entry.after_state)
      refute encoded =~ row.token_hash
      refute encoded =~ String.slice(row.token_hash, 0, 8)
      refute encoded =~ row.name
      refute encoded =~ "lf_tok_"
      refute encoded =~ body["token"]
      assert {:ok, :valid} = Audit.verify_chain(a.schema_name)
    end

    test "token.revoke before/after have the same keys; actor is the revoker; no token_hash, name or lf_tok_",
         %{a: a} do
      minter = holder!(a, ["TENANT_ADMIN", "TASK_WORKER"])
      target = holder!(a, ["TASK_WORKER"])
      revoker = holder!(a, @admin)

      {:ok, %{token: token, plaintext: plaintext}} =
        Identity.mint_token(minter.id, target.id, %{roles: ["TASK_WORKER"], expires_at: nil},
          prefix: a.schema_name
        )

      conn = call_as(:delete, "/tokens/#{token.id}", a, revoker.id, @admin, nil)
      assert conn.status == 200, conn.resp_body
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "revoked"
      assert body["issuer_user_id"] == minter.id

      assert [entry] = entries(a, "token.revoke")
      assert entry.actor_id == revoker.id
      assert entry.trace_id == @trace
      assert Enum.sort(Map.keys(entry.before_state)) == @audit_keys
      assert Enum.sort(Map.keys(entry.after_state)) == @audit_keys
      assert entry.after_state["issuer_user_id"] == minter.id
      assert entry.after_state["user_id"] == target.id
      assert entry.after_state["scope"] == "tenant_wide"
      assert entry.before_state["revoked_at"] == nil
      assert is_binary(entry.after_state["revoked_at"])

      encoded = Jason.encode!([entry.before_state, entry.after_state])
      refute encoded =~ token.token_hash
      refute encoded =~ String.slice(token.token_hash, 0, 8)
      refute encoded =~ token.name
      refute encoded =~ "lf_tok_"
      refute encoded =~ plaintext
    end

    test "create_token/3 audit shows issuer_user_id nil", %{a: a} do
      owner = holder!(a, [])

      {:ok, _} =
        Identity.create_token(owner.id, %{roles: ["TASK_WORKER"], expires_at: nil},
          prefix: a.schema_name
        )

      assert [entry] = entries(a, "token.create")
      assert Enum.sort(Map.keys(entry.after_state)) == @audit_keys
      assert entry.after_state["issuer_user_id"] == nil
    end
  end

  # --- AC: effective status, owner_inactive -----------------------------------------------------

  describe "effective status" do
    test "deactivated owner -> owner_inactive; revoked -> revoked; expired -> expired; revoked+inactive -> revoked; expired+inactive -> expired; active -> active",
         %{a: a} do
      admin = holder!(a, @admin)
      active_owner = holder!(a, [])
      inactive_owner = holder!(a, [])
      opts = [prefix: a.schema_name]

      mk = fn owner, expires_at ->
        {:ok, %{token: t}} =
          Identity.create_token(owner.id, %{roles: ["TASK_WORKER"], expires_at: expires_at}, opts)

        t
      end

      expire! = fn t ->
        past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
        t |> Ecto.Changeset.change(expires_at: past) |> Repo.update!(opts)
      end

      active = mk.(active_owner, nil)
      revoked = mk.(active_owner, nil)
      expired = mk.(active_owner, in_days(1)) |> expire!.()
      owner_inactive = mk.(inactive_owner, nil)
      revoked_inactive = mk.(inactive_owner, nil)
      expired_inactive = mk.(inactive_owner, in_days(1)) |> expire!.()

      {:ok, _} = Identity.revoke_token(revoked.id, opts)
      {:ok, _} = Identity.revoke_token(revoked_inactive.id, opts)
      deactivate!(a, inactive_owner)

      status = Map.new(list_items(a, admin), &{&1["id"], &1["status"]})

      assert status[active.id] == "active"
      assert status[revoked.id] == "revoked"
      assert status[expired.id] == "expired"
      assert status[owner_inactive.id] == "owner_inactive"
      assert status[revoked_inactive.id] == "revoked"
      assert status[expired_inactive.id] == "expired"

      assert {:ok, items} = Identity.list_tokens(opts)
      owner_active = Map.new(items, &{&1.token.id, &1.owner_active})
      assert owner_active[active.id] == true
      assert owner_active[owner_inactive.id] == false
    end

    test "unit table for token_effective_status/3" do
      now = ~U[2026-10-15 12:00:00Z]
      past = ~U[2026-10-15 11:59:59Z]
      future = ~U[2026-10-15 12:00:01Z]

      cases = [
        {%ApiToken{revoked_at: nil, expires_at: nil}, true, :active},
        {%ApiToken{revoked_at: nil, expires_at: future}, true, :active},
        {%ApiToken{revoked_at: nil, expires_at: nil}, false, :owner_inactive},
        {%ApiToken{revoked_at: nil, expires_at: future}, false, :owner_inactive},
        {%ApiToken{revoked_at: nil, expires_at: past}, true, :expired},
        {%ApiToken{revoked_at: nil, expires_at: now}, true, :expired},
        {%ApiToken{revoked_at: nil, expires_at: past}, false, :expired},
        {%ApiToken{revoked_at: past, expires_at: nil}, true, :revoked},
        {%ApiToken{revoked_at: past, expires_at: past}, false, :revoked},
        {%ApiToken{revoked_at: past, expires_at: nil}, false, :revoked}
      ]

      for {token, owner_active, expected} <- cases do
        assert Identity.token_effective_status(token, owner_active, now) == expected,
               "#{inspect({token.revoked_at, token.expires_at, owner_active})}"
      end
    end
  end

  # --- AC: list exposes issuer, never value -----------------------------------------------------

  describe "list" do
    test "item has issuer_user_id (null for legacy), no token/token_hash", %{a: a} do
      minter = holder!(a, ["TENANT_ADMIN", "TASK_WORKER"])
      target = holder!(a, ["TASK_WORKER"])

      minted_conn = post_token(a, minter, %{"user_id" => target.id, "roles" => ["TASK_WORKER"]})
      assert minted_conn.status == 201
      minted = Jason.decode!(minted_conn.resp_body)

      {:ok, %{token: legacy, plaintext: legacy_plain}} =
        Identity.create_token(target.id, %{roles: ["TASK_WORKER"], expires_at: nil},
          prefix: a.schema_name
        )

      conn = call_as(:get, "/tokens", a, minter.id, @admin, nil)
      assert conn.status == 200
      items = Jason.decode!(conn.resp_body)["items"]
      by_id = Map.new(items, &{&1["id"], &1})

      assert by_id[minted["id"]]["issuer_user_id"] == minter.id
      assert Map.has_key?(by_id[legacy.id], "issuer_user_id")
      assert by_id[legacy.id]["issuer_user_id"] == nil

      for item <- items do
        refute Map.has_key?(item, "token")
        refute Map.has_key?(item, "token_hash")
      end

      refute conn.resp_body =~ minted["token"]
      refute conn.resp_body =~ legacy_plain
      refute conn.resp_body =~ legacy.token_hash
    end
  end

  # --- AC: only a tenant-wide TENANT_ADMIN mints ------------------------------------------------

  describe "mint authority" do
    test "TA token but not in TA group -> 403", %{a: a} do
      caller = holder!(a, ["TASK_WORKER"])
      target = holder!(a, ["TASK_WORKER"])

      {:ok, _} =
        Identity.create_token(caller.id, %{roles: @admin, expires_at: nil}, prefix: a.schema_name)

      before = token_count(a)
      conn = post_token(a, caller, %{"user_id" => target.id, "roles" => ["TASK_WORKER"]})
      assert conn.status == 403, conn.resp_body
      assert token_count(a) == before

      assert {:error, :issuer_not_authorized} =
               Identity.mint_token(caller.id, target.id, %{roles: ["TASK_WORKER"]},
                 prefix: a.schema_name
               )
    end

    test "inactive minter -> 403", %{a: a} do
      minter = holder!(a, ["TENANT_ADMIN", "TASK_WORKER"])
      target = holder!(a, ["TASK_WORKER"])
      deactivate!(a, minter)

      conn = post_token(a, minter, %{"user_id" => target.id, "roles" => ["TASK_WORKER"]})
      assert conn.status == 403, conn.resp_body
      assert token_count(a) == 0
    end

    test "unknown or non-UUID issuer -> :issuer_not_authorized", %{a: a} do
      target = holder!(a, ["TASK_WORKER"])

      for issuer <- [Ecto.UUID.generate(), "not-a-uuid"] do
        assert {:error, :issuer_not_authorized} =
                 Identity.mint_token(issuer, target.id, %{roles: ["TASK_WORKER"]},
                   prefix: a.schema_name
                 )
      end
    end

    test "TA mints in customer and platform tenant, no PA binding anywhere (passes unchanged with the PA clause deleted)",
         %{a: a, p: p} do
      for fx <- [a, p] do
        Repo.delete_all(from(t in TenantRole, where: t.name == "PLATFORM_ADMIN"),
          prefix: fx.schema_name
        )

        minter = holder!(fx, ["TENANT_ADMIN", "TASK_WORKER"])
        target = holder!(fx, ["TASK_WORKER"])

        refute Repo.exists?(from(t in TenantRole, where: t.name == "PLATFORM_ADMIN"),
                 prefix: fx.schema_name
               )

        conn = post_token(fx, minter, %{"user_id" => target.id, "roles" => ["TASK_WORKER"]})
        assert conn.status == 201, "#{fx.schema_name}: #{conn.resp_body}"
        assert Jason.decode!(conn.resp_body)["issuer_user_id"] == minter.id
      end
    end

    test "PA in a customer tenant cannot mint -> 403", %{a: a} do
      # a legacy PLATFORM_ADMIN binding plus membership in ordinary tenant A
      caller = holder!(a, @operator ++ ["TASK_WORKER"])
      target = holder!(a, ["TASK_WORKER"])

      conn =
        call_as(:post, "/tokens", a, caller.id, @operator, %{
          "user_id" => target.id,
          "roles" => ["TASK_WORKER"]
        })

      assert conn.status == 403, conn.resp_body

      assert {:error, :issuer_not_authorized} =
               Identity.mint_token(caller.id, target.id, %{roles: ["TASK_WORKER"]},
                 prefix: a.schema_name
               )

      assert MapSet.new(["TASK_WORKER"]) ==
               Identity.tenant_wide_role_names(caller.id, prefix: a.schema_name)

      assert token_count(a) == 0
    end

    test "PA in platform tenant mints own expiring PA token -> 201", %{p: p} do
      operator = holder!(p, @operator)

      conn =
        call_as(:post, "/tokens", p, operator.id, @operator, %{
          "user_id" => operator.id,
          "roles" => @operator,
          "expires_at" => DateTime.to_iso8601(in_days(30))
        })

      assert conn.status == 201, conn.resp_body
      body = Jason.decode!(conn.resp_body)
      assert body["issuer_user_id"] == operator.id
      assert body["user_id"] == operator.id
      assert body["roles"] == @operator
    end
  end

  # --- PA conditions (advisor) ------------------------------------------------------------------

  describe "PLATFORM_ADMIN token conditions" do
    test "PA mints a PA token for another user -> 422 roles_invalid", %{p: p} do
      operator = holder!(p, @operator)
      other = holder!(p, @operator)

      conn =
        call_as(:post, "/tokens", p, operator.id, @operator, %{
          "user_id" => other.id,
          "roles" => @operator,
          "expires_at" => DateTime.to_iso8601(in_days(30))
        })

      assert_422(conn, "roles_invalid")

      assert {:error, :platform_admin_token_not_self} =
               Identity.mint_token(
                 operator.id,
                 other.id,
                 %{roles: @operator, expires_at: in_days(30)},
                 prefix: p.schema_name
               )

      assert token_count(p) == 0
    end

    test "PA token without expires_at -> 422 platform_admin_token_expiry_invalid", %{p: p} do
      operator = holder!(p, @operator)

      conn =
        call_as(:post, "/tokens", p, operator.id, @operator, %{
          "user_id" => operator.id,
          "roles" => @operator
        })

      assert_422(conn, "platform_admin_token_expiry_invalid")
      assert token_count(p) == 0
    end

    test "PA token past the cap -> 422", %{p: p} do
      operator = holder!(p, @operator)

      conn =
        call_as(:post, "/tokens", p, operator.id, @operator, %{
          "user_id" => operator.id,
          "roles" => @operator,
          "expires_at" => DateTime.to_iso8601(in_days(90, 60))
        })

      assert_422(conn, "platform_admin_token_expiry_invalid")
      assert token_count(p) == 0
    end

    test "PA token at the cap -> 201 (now + 90 d - 5 s)", %{p: p} do
      operator = holder!(p, @operator)

      conn =
        call_as(:post, "/tokens", p, operator.id, @operator, %{
          "user_id" => operator.id,
          "roles" => @operator,
          "expires_at" => DateTime.to_iso8601(in_days(90, -5))
        })

      assert conn.status == 201, conn.resp_body
    end

    test "the cap is read from :platform_admin_token_max_ttl_days at call time", %{p: p} do
      operator = holder!(p, @operator)
      restore_ttl_env_on_exit()
      Application.put_env(:letflow, :platform_admin_token_max_ttl_days, 1)

      assert {:error, :platform_admin_token_expiry} =
               Identity.mint_token(
                 operator.id,
                 operator.id,
                 %{roles: @operator, expires_at: in_days(2)},
                 prefix: p.schema_name
               )
    end

    test "unit: validate_platform_admin_expiry/4 at exactly the cap :ok, cap + 1 s error" do
      now = ~U[2026-10-15 12:00:00Z]
      cap = DateTime.add(now, 90 * 86_400, :second)
      pa = ["PLATFORM_ADMIN"]

      assert :ok = Identity.validate_platform_admin_expiry(pa, cap, now, 90)

      assert {:error, :platform_admin_token_expiry} =
               Identity.validate_platform_admin_expiry(pa, DateTime.add(cap, 1, :second), now, 90)

      assert {:error, :platform_admin_token_expiry} =
               Identity.validate_platform_admin_expiry(pa, nil, now, 90)

      # whole seconds: a sub-second excess over the cap is truncated away
      assert :ok =
               Identity.validate_platform_admin_expiry(
                 pa,
                 DateTime.add(cap, 500_000, :microsecond),
                 now,
                 90
               )

      # any other role set is not capped
      assert :ok = Identity.validate_platform_admin_expiry(["TENANT_ADMIN"], nil, now, 90)

      assert :ok =
               Identity.validate_platform_admin_expiry(
                 ["TENANT_ADMIN"],
                 DateTime.add(cap, 86_400, :second),
                 now,
                 90
               )
    end

    # REVIEWER fix 8034c1a6: the private guard platform_admin_token_max_ttl_days/0 raises on a
    # value outside 1..366 (or a non-integer). insert_token/5's rescue turns the raise into
    # {:transaction_failed, _}, which the router maps to 500. Fail closed: never a token.
    test "misconfigured :platform_admin_token_max_ttl_days (0, -1, \"90\", 367, 10_000) fails closed: raise -> :transaction_failed, HTTP 500, no row, no audit",
         %{p: p} do
      operator = holder!(p, @operator)
      restore_ttl_env_on_exit()

      for bad <- [0, -1, "90", 367, 10_000] do
        Application.put_env(:letflow, :platform_admin_token_max_ttl_days, bad)

        assert {:error, {:transaction_failed, %ArgumentError{message: message}}} =
                 Identity.mint_token(
                   operator.id,
                   operator.id,
                   %{roles: @operator, expires_at: in_days(1)},
                   prefix: p.schema_name
                 ),
               "value #{inspect(bad)} did not raise"

        assert message =~ ":platform_admin_token_max_ttl_days must be an integer in 1..366"
        assert message =~ inspect(bad)

        conn = post_pa_token(p, operator, in_days(1))
        assert conn.status == 500, "value #{inspect(bad)}: #{conn.status} #{conn.resp_body}"
      end

      assert token_count(p) == 0
      assert entries(p, "token.create") == []
    end

    test "valid :platform_admin_token_max_ttl_days bounds 1 and 366 mint; unset env uses the default 90",
         %{p: p} do
      operator = holder!(p, @operator)
      restore_ttl_env_on_exit()

      for days <- [1, 366] do
        Application.put_env(:letflow, :platform_admin_token_max_ttl_days, days)
        conn = post_pa_token(p, operator, in_days(days, -5))
        assert conn.status == 201, "value #{days}: #{conn.resp_body}"
      end

      # Unset: the code default (config.exs pins 90 explicitly, so this is the only test of
      # the get_env/3 fallback). 90 d - 5 s mints, 90 d + 60 s is refused, so the default is 90.
      Application.delete_env(:letflow, :platform_admin_token_max_ttl_days)
      assert post_pa_token(p, operator, in_days(90, -5)).status == 201

      assert_422(
        post_pa_token(p, operator, in_days(90, 60)),
        "platform_admin_token_expiry_invalid"
      )

      assert token_count(p) == 3
    end
  end

  # --- SoD identity (advisor condition 3) ------------------------------------------------------

  describe "SoD identity" do
    test "a minted token authenticates as its OWNER (the target) with its roles, never as the issuer",
         %{a: a} do
      minter = holder!(a, ["TENANT_ADMIN", "TASK_WORKER"])
      target = holder!(a, ["TASK_WORKER"])

      conn = post_token(a, minter, %{"user_id" => target.id, "roles" => ["TASK_WORKER"]})
      assert conn.status == 201, conn.resp_body
      body = Jason.decode!(conn.resp_body)

      assert {:ok, %{user_id: acting_id, roles: ["TASK_WORKER"]}} =
               Identity.verify_api_token(body["token"], prefix: a.schema_name)

      assert acting_id == target.id
      refute acting_id == minter.id
    end
  end

  # --- structural: the HTTP mint path is mint_token/4 only (REVIEWER finding 7) ----------------

  describe "structural" do
    # create_token/3 is the trusted non-HTTP path (NULL issuer, no 0051 M2 checks). A router
    # calling it would be a sibling mint path that bypasses the issuer and the subset rule
    # (docs/anti-patterns.md, sibling-path). The lookbehind excludes this router's own
    # handle_/validate_and_/do_create_token helpers and @create_token_schema.
    @create_token_call ~r/(?<![A-Za-z0-9_])create_token\s*[(\/]|\.create_token\b|:create_token\b/

    test "no file under lib/letflow/routers/ calls create_token; POST /tokens calls Identity.mint_token" do
      root = Path.expand("../../../lib/letflow/routers", __DIR__)
      files = Path.wildcard(Path.join(root, "**/*.{ex,exs}"))
      assert Path.join(root, "identity.ex") in files, "router dir not found at #{root}"

      hits =
        for file <- files,
            {line, n} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
            Regex.match?(@create_token_call, line) do
          "#{Path.relative_to_cwd(file)}:#{n}: #{String.trim(line)}"
        end

      assert hits == [],
             "routers must mint through Identity.mint_token/4, not create_token:\n" <>
               Enum.join(hits, "\n")

      assert File.read!(Path.join(root, "identity.ex")) =~ "Identity.mint_token("
    end
  end

  # --- race ------------------------------------------------------------------------------------

  describe "race" do
    test "concurrent remove_group_member vs mint: either 422 or the token commits before the removal",
         %{a: a} do
      minter = holder!(a, ["TENANT_ADMIN", "TASK_WORKER"])
      target = holder!(a, ["TASK_WORKER"])

      tw_group =
        Repo.one!(
          from(t in TenantRole,
            where: t.name == "TASK_WORKER" and t.kind == :platform_role,
            select: t.group_id
          ),
          prefix: a.schema_name
        )

      # Deterministic half: a membership removal holding the tenant admin lock blocks the mint;
      # once it commits, the mint re-reads the roles under the lock and refuses.
      parent = self()

      remover =
        Task.async(fn ->
          Repo.transaction(fn ->
            Identity.lock_tenant_admins!(a.schema_name)

            Repo.delete_all(
              from(m in GroupMember,
                where: m.group_id == ^tw_group and m.user_id == ^target.id
              ),
              prefix: a.schema_name
            )

            send(parent, :removed_uncommitted)

            receive do
              :commit -> :ok
            after
              10_000 -> Repo.rollback(:timeout)
            end
          end)
        end)

      assert_receive :removed_uncommitted, 5_000

      minting =
        Task.async(fn ->
          Identity.mint_token(minter.id, target.id, %{roles: ["TASK_WORKER"]},
            prefix: a.schema_name
          )
        end)

      # the mint waits on the advisory lock
      assert Task.yield(minting, 500) == nil
      send(remover.pid, :commit)
      assert {:ok, :ok} = Task.await(remover, 10_000)
      assert {:error, :roles_not_held} = Task.await(minting, 10_000)
      assert token_count(a) == 0

      # Concurrent half: either outcome is allowed, but a committed token must precede the
      # removal in the audit log.
      Mint.grant_roles!(a.schema_name, target.id, ["TASK_WORKER"])

      results =
        [
          Task.async(fn ->
            {:remove, Identity.remove_group_member(tw_group, target.id, prefix: a.schema_name)}
          end),
          Task.async(fn ->
            {:mint,
             Identity.mint_token(minter.id, target.id, %{roles: ["TASK_WORKER"]},
               prefix: a.schema_name
             )}
          end)
        ]
        |> Enum.map(&Task.await(&1, 10_000))
        |> Map.new()

      assert :ok = results.remove

      case results.mint do
        {:error, :roles_not_held} ->
          assert token_count(a) == 0

        {:ok, %{token: token}} ->
          [created] = entries(a, "token.create")
          [removed] = entries(a, "group_member.removed")
          assert created.resource_id == token.id
          assert DateTime.compare(created.timestamp, removed.timestamp) == :lt
      end
    end
  end

  # --- inactive target --------------------------------------------------------------------------

  describe "target" do
    test "inactive target -> 422 user_inactive, no row", %{a: a} do
      minter = holder!(a, ["TENANT_ADMIN", "TASK_WORKER"])
      target = holder!(a, ["TASK_WORKER"])
      deactivate!(a, target)

      conn = post_token(a, minter, %{"user_id" => target.id, "roles" => ["TASK_WORKER"]})
      assert_422(conn, "user_inactive")
      assert token_count(a) == 0
      assert entries(a, "token.create") == []
    end

    test "unknown target -> 404 for an authorized minter", %{a: a} do
      minter = holder!(a, ["TENANT_ADMIN", "TASK_WORKER"])

      conn =
        post_token(a, minter, %{"user_id" => Ecto.UUID.generate(), "roles" => ["TASK_WORKER"]})

      assert conn.status == 404, code(conn)
    end
  end
end
