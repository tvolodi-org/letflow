defmodule Letflow.Routers.ServicePrincipalRouteTest do
  @moduledoc """
  REQ-517 / GH #2535 PR 2a, AC 12 (design `lib/letflow/design/req517-scoped-grants-admin-plane.md`
  sections 3.6.2 and 3.12; spec `test/specs/REQ-517-2a.md`, T-A5, T-P1..T-P8):
  `PUT /users/:id/service-principal` on `Letflow.Routers.Identity` and
  `Letflow.Identity.ServicePrincipal`.

  Gate under test, every refusal the same uniform 403 `insufficient permissions`: (1) the plug
  (`:UsersGroupsRolesManage`); (2) an interactive (`:oidc`) credential, so an API token, even a
  TENANT_ADMIN one, is refused while the same token may write a grant; (3) the permission held
  TENANT-WIDE; (4) TENANT_ADMIN among the caller's roles, tenant-wide (a platform-tenant
  PLATFORM_ADMIN alone is refused). Then the body: exactly `flagged` (boolean) and `reason`;
  `invalid_body` before `reason_required` / `invalid_reason`, and an unknown user is a 404 only
  after the reason passed (a bad reason never reveals whether the user exists).

  `async: false`: committed writes, DDL (audit fault triggers), cross-connection locks.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Identity
  alias Letflow.Identity.ServicePrincipal
  alias Letflow.Identity.User
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopedGrantsFixture, as: S
  alias Letflow.Support.TokenMintFixture

  @identity Letflow.Routers.Identity
  @enforcement Letflow.Routers.TenantScopeEnforcement
  @admin_role "TENANT_ADMIN"
  @reason "service account for the nightly integration"

  # --- helpers ---------------------------------------------------------------------------------

  defp path(user_id), do: "/users/#{user_id}/service-principal"

  defp flag(fx, user_id, body), do: S.as_admin(@identity, :put, path(user_id), fx, body)

  defp flag_as(fx, caller_ctx, user_id, body),
    do: S.call(@identity, :put, path(user_id), fx, caller_ctx, body)

  defp flagged?(fx, user_id),
    do: Repo.get!(User, user_id, prefix: fx.schema_name).admin_flagged_service_principal

  defp actor(fx), do: %{user_id: fx.admin.id, trace_id: S.trace(), credential: "oidc"}

  defp set_flag!(fx, user_id, flagged) do
    assert {:ok, %{changed: true}} =
             ServicePrincipal.set_flag(user_id, flagged, @reason, actor(fx), fx.schema_name)
  end

  # ===========================================================================================
  describe "T-A5 / T-P1 flag and unflag" do
    test "an interactive tenant-wide TENANT_ADMIN flags: 200 with exactly {user_id, admin_flagged_service_principal}, the column, one audit entry with actor, user, reason and trace" do
      fx = S.tenant!("r517-p1")
      user = RSG.user!(fx.schema_name)
      refute flagged?(fx, user.id)

      conn = flag(fx, user.id, %{"flagged" => true, "reason" => @reason})

      assert conn.status == 200, conn.resp_body

      assert S.body(conn) == %{
               "user_id" => user.id,
               "admin_flagged_service_principal" => true
             }

      assert flagged?(fx, user.id)
      assert [entry] = S.entries(fx, "service_principal.flagged")
      assert entry.resource_type == "user"
      assert entry.resource_id == user.id
      assert entry.actor_id == fx.admin.id
      assert entry.trace_id == S.trace()
      assert entry.before_state == %{"flagged" => false}

      assert entry.after_state == %{
               "flagged" => true,
               "reason" => @reason,
               "actor" => fx.admin.id,
               "credential" => "oidc",
               "trace_id" => S.trace()
             }
    end

    test "unflag: 200, the column is false, and the event carries tokens_exceeding_owner as a count of the owner's LIVE tokens beyond the owner's roles (never ids or values)" do
      fx = S.tenant!("r517-p1-unflag")
      s = fx.schema_name
      # The owner holds PROCESS_DESIGNER (tenant-wide, by group), so exceeding and non-exceeding
      # live tokens coexist: only roles BEYOND the owner's count.
      user = TokenMintFixture.role_holder!(s, ["PROCESS_DESIGNER"])
      set_flag!(fx, user.id, true)

      {:ok, %{token: _exceeding_ta}} =
        Identity.create_token(user.id, %{roles: [@admin_role], expires_at: nil}, prefix: s)

      {:ok, %{token: _exceeding_mixed}} =
        Identity.create_token(
          user.id,
          %{roles: ["PROCESS_DESIGNER", "TASK_WORKER"], expires_at: nil},
          prefix: s
        )

      {:ok, %{token: _within_pd}} =
        Identity.create_token(user.id, %{roles: ["PROCESS_DESIGNER"], expires_at: nil}, prefix: s)

      {:ok, %{token: _within_pd_again}} =
        Identity.create_token(user.id, %{roles: ["PROCESS_DESIGNER"], expires_at: nil}, prefix: s)

      {:ok, %{token: revoked}} =
        Identity.create_token(user.id, %{roles: [@admin_role], expires_at: nil}, prefix: s)

      {:ok, _} = Identity.revoke_token(revoked.id, prefix: s)

      conn = flag(fx, user.id, %{"flagged" => false, "reason" => @reason})

      assert conn.status == 200
      assert S.body(conn) == %{"user_id" => user.id, "admin_flagged_service_principal" => false}
      refute flagged?(fx, user.id)

      assert [entry] = S.entries(fx, "service_principal.unflagged")
      assert entry.before_state == %{"flagged" => true}

      assert entry.after_state |> Map.keys() |> Enum.sort() ==
               ~w(actor credential flagged reason tokens_exceeding_owner trace_id)

      # 4 live tokens, 2 exceed the owner (TENANT_ADMIN; PROCESS_DESIGNER + TASK_WORKER), the
      # revoked exceeding one is not live: the exact count separates "exceeding" from "all live".
      assert entry.after_state["tokens_exceeding_owner"] == 2
      refute Jason.encode!(entry.after_state) =~ "lf_tok_"
    end

    test "unflag records tokens_exceeding_owner 0 when no live token exceeds the owner" do
      fx = S.tenant!("r517-p1-unflag-none")
      s = fx.schema_name
      user = TokenMintFixture.role_holder!(s, ["PROCESS_DESIGNER"])
      set_flag!(fx, user.id, true)

      {:ok, %{token: _a}} =
        Identity.create_token(user.id, %{roles: ["PROCESS_DESIGNER"], expires_at: nil}, prefix: s)

      {:ok, %{token: _b}} =
        Identity.create_token(user.id, %{roles: ["PROCESS_DESIGNER"], expires_at: nil}, prefix: s)

      assert flag(fx, user.id, %{"flagged" => false, "reason" => @reason}).status == 200
      assert [entry] = S.entries(fx, "service_principal.unflagged")
      assert entry.after_state["tokens_exceeding_owner"] == 0
    end
  end

  # ===========================================================================================
  describe "T-P2 the uniform 403" do
    test "a non-admin, an admin role claim with no tenant-wide grant row and a scoped-only TENANT_ADMIN get the same bytes; nothing is written" do
      fx = S.tenant!("r517-p2")
      s = fx.schema_name
      target = RSG.user!(s)
      worker = TokenMintFixture.role_holder!(s, ["TASK_WORKER"])
      norow = RSG.user!(s)
      body = %{"flagged" => true, "reason" => @reason}

      plug_denied = flag_as(fx, S.ctx(fx, worker.id, ["TASK_WORKER"], :oidc), target.id, body)
      handler_denied = flag_as(fx, S.ctx(fx, norow.id, [@admin_role], :oidc), target.id, body)

      for conn <- [plug_denied, handler_denied] do
        assert conn.status == 403
        assert S.body(conn)["detail"] == "insufficient permissions"
      end

      assert plug_denied.resp_body == handler_denied.resp_body
      refute flagged?(fx, target.id)
      assert S.entries(fx, "service_principal.flagged") == []
    end

    test "a TENANT_ADMIN whose group holds only a scoped row gets the 403" do
      fx = S.tenant!("r517-p2-scoped")
      s = fx.schema_name
      target = RSG.user!(s)
      _node = RSG.make_group_scoped_only!(s, RSG.group_of!(s, @admin_role), @admin_role)

      conn = flag(fx, target.id, %{"flagged" => true, "reason" => @reason})

      assert conn.status == 403
      refute flagged?(fx, target.id)
    end

    test "a platform-tenant PLATFORM_ADMIN alone (no TENANT_ADMIN grant) is refused" do
      p = S.tenant!("r517-p2-plat")
      :ok = Fixture.pin!(p.tenant_id)
      target = RSG.user!(p.schema_name)
      operator = RSG.user!(p.schema_name)

      conn =
        flag_as(
          p,
          S.ctx(p, operator.id, ["PLATFORM_ADMIN"], :oidc),
          target.id,
          %{"flagged" => true, "reason" => @reason}
        )

      assert conn.status == 403
      refute flagged?(p, target.id)
    end

    test "an API-token principal holding TENANT_ADMIN gets 403 on the flag route, 2xx on a grant write, and nothing is flagged" do
      fx = S.tenant!("r517-p2-token")
      s = fx.schema_name
      target = RSG.user!(s)
      owner = RSG.user!(s)
      group = S.rowless_group!(fx, "TASK_WORKER")
      node = RSG.node!(s)

      {:ok, %{plaintext: token}} =
        Identity.create_token(owner.id, %{roles: [@admin_role], expires_at: nil}, prefix: s)

      conn =
        :put
        |> Fixture.api_conn("/api/v1/identity" <> path(target.id), token, fx.tenant.slug, %{
          "flagged" => true,
          "reason" => @reason
        })
        |> Fixture.dispatch_api()

      assert conn.status == 403, conn.resp_body
      assert Jason.decode!(conn.resp_body)["detail"] == "insufficient permissions"
      refute flagged?(fx, target.id)
      assert S.entries(fx, "service_principal.flagged") == []

      conn =
        :post
        |> Fixture.api_conn(
          "/api/v1/tenant/role-scope-grants",
          token,
          fx.tenant.slug,
          S.create_body(:group, group, "TASK_WORKER", node)
        )
        |> Fixture.dispatch_api()

      assert conn.status == 201, conn.resp_body
      assert [entry] = S.entries(fx, "grant.created")
      assert entry.after_state["credential"] == "api_token"
    end
  end

  # ===========================================================================================
  describe "T-P3 / T-P8 body, reason and unknown users" do
    test "a missing, blank or non-string reason is 422 reason_required for flag and unflag; nothing is written" do
      fx = S.tenant!("r517-p3")
      user = RSG.user!(fx.schema_name)

      for state <- [false, true] do
        if state, do: set_flag!(fx, user.id, true)
        target = not state

        for reason <- [:missing, "", "   ", "\n\t", 123, nil, ["x"]] do
          body =
            if reason == :missing,
              do: %{"flagged" => target},
              else: %{"flagged" => target, "reason" => reason}

          conn = flag(fx, user.id, body)
          assert conn.status == 422, inspect(body)
          assert S.body(conn)["detail"] == "reason_required"
        end

        assert flagged?(fx, user.id) == state
      end

      # only the one explicit set_flag! above wrote an event
      assert length(S.entries(fx, "service_principal.flagged")) == 1
      assert S.entries(fx, "service_principal.unflagged") == []
    end

    test "a control character, a format character or an over-long reason is 422 invalid_reason" do
      fx = S.tenant!("r517-p3-invalid")
      user = RSG.user!(fx.schema_name)

      for reason <- ["bad\u0007reason", "zero​width", String.duplicate("x", 501)] do
        conn = flag(fx, user.id, %{"flagged" => true, "reason" => reason})
        assert conn.status == 422
        assert S.body(conn)["detail"] == "invalid_reason"
      end

      refute flagged?(fx, user.id)
    end

    test "a missing or non-boolean flagged, an extra key and a non-map body are 422 invalid_body, decided before the reason" do
      fx = S.tenant!("r517-p3-body")
      user = RSG.user!(fx.schema_name)

      for body <- [
            %{},
            %{"reason" => @reason},
            %{"flagged" => "true", "reason" => @reason},
            %{"flagged" => 1, "reason" => @reason},
            %{"flagged" => nil},
            %{"flagged" => true, "reason" => @reason, "user_id" => user.id},
            %{"flagged" => "yes"}
          ] do
        conn = flag(fx, user.id, body)
        assert conn.status == 422, inspect(body)
        assert S.body(conn)["detail"] == "invalid_body"
      end

      conn = S.as_admin(@identity, :put, path(user.id), fx, [])
      assert conn.status == 422
      refute flagged?(fx, user.id)
    end

    test "T-P8 an unknown user and a non-UUID id are the same 404, answered only after the reason passed" do
      fx = S.tenant!("r517-p8")

      unknown = flag(fx, Ecto.UUID.generate(), %{"flagged" => true, "reason" => @reason})
      malformed = flag(fx, "not-a-uuid", %{"flagged" => true, "reason" => @reason})
      assert unknown.status == 404
      assert malformed.status == 404
      assert unknown.resp_body == malformed.resp_body

      # a bad reason on an unknown user is the reason error, not a 404 (no existence oracle)
      conn = flag(fx, Ecto.UUID.generate(), %{"flagged" => true, "reason" => ""})
      assert conn.status == 422
      assert S.body(conn)["detail"] == "reason_required"
    end
  end

  # ===========================================================================================
  describe "T-P4 atomicity and no-op" do
    test "a forced audit failure rolls the flag back (500)" do
      fx = S.tenant!("r517-p4")
      user = RSG.user!(fx.schema_name)

      conn =
        S.with_audit_fault(fx, "service_principal.flagged", fn ->
          flag(fx, user.id, %{"flagged" => true, "reason" => @reason})
        end)

      assert conn.status == 500
      refute flagged?(fx, user.id)
      assert S.entries(fx, "service_principal.flagged") == []
    end

    test "a request equal to the current value is 200 and writes no audit entry" do
      fx = S.tenant!("r517-p4-noop")
      user = RSG.user!(fx.schema_name)

      assert flag(fx, user.id, %{"flagged" => true, "reason" => @reason}).status == 200
      conn = flag(fx, user.id, %{"flagged" => true, "reason" => "again"})

      assert conn.status == 200
      assert S.body(conn)["admin_flagged_service_principal"] == true
      assert length(S.entries(fx, "service_principal.flagged")) == 1

      assert {:ok, %{changed: false, flagged: true}} =
               ServicePrincipal.set_flag(user.id, true, "again", actor(fx), fx.schema_name)

      # the unflag of an unflagged user is also a no-op
      other = RSG.user!(fx.schema_name)
      conn = flag(fx, other.id, %{"flagged" => false, "reason" => @reason})
      assert conn.status == 200
      assert S.entries(fx, "service_principal.unflagged") == []
    end
  end

  # ===========================================================================================
  describe "T-P5 the flag has no other writer" do
    test "mints (refused and successful), token create and revoke, and PATCH /users/:id never set the flag" do
      fx = S.tenant!("r517-p5")
      s = fx.schema_name
      target = RSG.user!(s)
      second_admin = TokenMintFixture.role_holder!(s, [@admin_role])

      # a refused mint (the target does not hold the role)
      assert {:error, :roles_not_held} =
               Identity.mint_token(
                 fx.admin.id,
                 target.id,
                 %{roles: [@admin_role], expires_at: nil},
                 prefix: s
               )

      refute flagged?(fx, target.id)

      # a successful mint (the target holds the role by group membership)
      assert {:ok, %{token: minted}} =
               Identity.mint_token(
                 fx.admin.id,
                 second_admin.id,
                 %{roles: [@admin_role], expires_at: nil},
                 prefix: s
               )

      refute flagged?(fx, second_admin.id)

      # create and revoke of a token for the unflagged target
      {:ok, %{token: created}} =
        Identity.create_token(target.id, %{roles: ["TASK_WORKER"], expires_at: nil}, prefix: s)

      refute flagged?(fx, target.id)
      {:ok, _} = Identity.revoke_token(created.id, prefix: s)
      {:ok, _} = Identity.revoke_token(minted.id, prefix: s)
      refute flagged?(fx, target.id)

      # PATCH /users/:id with the column in the body
      conn =
        S.as_admin(@identity, :patch, "/users/#{target.id}", fx, %{
          "display_name" => "Renamed",
          "admin_flagged_service_principal" => true
        })

      assert conn.status in [200, 400, 422], conn.resp_body
      refute flagged?(fx, target.id)

      # a flagged user stays flagged through the same operations
      set_flag!(fx, target.id, true)

      {:ok, %{token: other}} =
        Identity.create_token(target.id, %{roles: ["TASK_WORKER"], expires_at: nil}, prefix: s)

      {:ok, _} = Identity.revoke_token(other.id, prefix: s)
      assert flagged?(fx, target.id)
      assert S.entries(fx, "service_principal.unflagged") == []
    end
  end

  # ===========================================================================================
  describe "T-P6 serialisation with lock A" do
    test "a held lock A blocks the flag route and a concurrent mint until it is released; both then complete" do
      fx = S.tenant!("r517-p6")
      s = fx.schema_name
      user = RSG.user!(s)
      second_admin = TokenMintFixture.role_holder!(s, [@admin_role])

      holder = S.hold_admin_lock(s, self())
      assert_receive {:admin_lock_held, _prefix}, 5_000

      flagger = Task.async(fn -> flag(fx, user.id, %{"flagged" => true, "reason" => @reason}) end)

      minter =
        Task.async(fn ->
          Identity.mint_token(
            fx.admin.id,
            second_admin.id,
            %{roles: [@admin_role], expires_at: nil},
            prefix: s
          )
        end)

      try do
        assert S.lock_waiter?("pg_advisory_xact_lock"), "neither request queued on lock A"
        assert Task.yield(flagger, 300) == nil
        assert Task.yield(minter, 100) == nil
        refute flagged?(fx, user.id)

        send(holder.pid, :release)
        assert {:ok, {:error, :released}} = Task.yield(holder, 5_000)
        assert {:ok, conn} = Task.yield(flagger, 5_000)
        assert conn.status == 200
        assert {:ok, {:ok, %{token: _token}}} = Task.yield(minter, 5_000)
        assert flagged?(fx, user.id)
      after
        S.stop_task(flagger)
        S.stop_task(minter)
        S.stop_task(holder)
      end
    end
  end

  # ===========================================================================================
  describe "T-P7 the informational token-preconditions category" do
    test "GET token-preconditions lists service_principal_owner {user_id, token_ids}; token.listed carries the ids; no token value; it does not block" do
      fx = S.tenant!("r517-p7")
      s = fx.schema_name
      owner = TokenMintFixture.role_holder!(s, ["PROCESS_DESIGNER"])
      plain = TokenMintFixture.role_holder!(s, ["PROCESS_DESIGNER"])

      {:ok, %{token: flagged_token, plaintext: plaintext}} =
        Identity.create_token(owner.id, %{roles: ["PROCESS_DESIGNER"], expires_at: nil},
          prefix: s
        )

      {:ok, %{token: unflagged_token}} =
        Identity.create_token(plain.id, %{roles: ["PROCESS_DESIGNER"], expires_at: nil},
          prefix: s
        )

      {:ok, %{token: revoked}} =
        Identity.create_token(owner.id, %{roles: ["PROCESS_DESIGNER"], expires_at: nil},
          prefix: s
        )

      {:ok, _} = Identity.revoke_token(revoked.id, prefix: s)
      set_flag!(fx, owner.id, true)

      conn = S.as_admin(@enforcement, :get, "/token-preconditions", fx, nil)

      assert conn.status == 200
      b = S.body(conn)

      assert b["information"]["service_principal_owner"] == [
               %{"user_id" => owner.id, "token_ids" => [flagged_token.id]}
             ]

      assert b["flip_blocked"] == false
      assert b["blocking"]["roles_exceed_owner"] == []

      # create_token/3 is the trusted path (no issuer recorded), so both live tokens are also in the
      # null_issuer information list: the listing audits the union of the ids.
      assert b["count"] == 2
      refute conn.resp_body =~ plaintext
      refute conn.resp_body =~ "lf_tok_"

      assert [entry] = S.entries(fx, "token.listed")
      assert entry.after_state["token_ids"] == Enum.sort([flagged_token.id, unflagged_token.id])
      assert entry.after_state["count"] == 2
    end

    test "a tenant with no flagged owner has an empty service_principal_owner list" do
      fx = S.tenant!("r517-p7-empty")

      b = S.as_admin(@enforcement, :get, "/token-preconditions", fx, nil) |> S.body()

      assert b["information"]["service_principal_owner"] == []
    end
  end

  test "list_tokens/1 items carry owner_flagged next to token and owner_active" do
    fx = S.tenant!("r517-p-list")
    s = fx.schema_name
    flagged = RSG.user!(s)
    plain = RSG.user!(s)

    {:ok, %{token: ft}} =
      Identity.create_token(flagged.id, %{roles: ["TASK_WORKER"], expires_at: nil}, prefix: s)

    {:ok, %{token: pt}} =
      Identity.create_token(plain.id, %{roles: ["TASK_WORKER"], expires_at: nil}, prefix: s)

    set_flag!(fx, flagged.id, true)

    assert {:ok, items} = Identity.list_tokens(prefix: s)
    by_id = Map.new(items, &{&1.token.id, &1})

    assert by_id[ft.id].owner_flagged == true
    assert by_id[pt.id].owner_flagged == false
    assert Enum.all?(items, &(Enum.sort(Map.keys(&1)) == [:owner_active, :owner_flagged, :token]))
  end
end
