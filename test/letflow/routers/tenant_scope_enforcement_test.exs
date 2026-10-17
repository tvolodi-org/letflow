defmodule Letflow.Routers.TenantScopeEnforcementTest do
  @moduledoc """
  REQ-497 PR 1b / GH #2533, AC7, AC14, AC16 at the HTTP layer:
  `Letflow.Routers.TenantScopeEnforcement` (`GET|PUT /tenant/scope-enforcement`,
  `GET /tenant/scope-enforcement/integrity`, `GET /tenant/scope-enforcement/token-preconditions`).
  Design `lib/letflow/design/req497-1b-allowed-flag-shadow-n1.md` sections 3.4, 7.2, 7.3, 8 and the
  section 18 rulings; spec `test/specs/REQ-497-1b.md`, T-F1..T-F3, T-F8..T-F10 (HTTP), T-I1,
  T-L1..T-L4.

  Request shapes:

    * `Letflow.Routers.TenantScopeEnforcement.call/2` (so `Letflow.Plugs.Authorize` runs and sets
      `scoped_opts`) with a hand-assigned `auth_context` that carries `credential: :oidc` and the
      id of a REAL user: `Letflow.Api.Scope.require_tenant_wide/2` builds a principal from it and
      loads that user's applicable grant rows, so the caller must actually be a member of the
      TENANT_ADMIN group with its tenant-wide row (`TokenMintFixture.role_holder!/2`).
    * The FULL `Letflow.Router` pipeline with a real TENANT_ADMIN API token, to pin the mount in
      `Letflow.Plugs.ApiPipeline`.

  Every tenant is a dedicated `TenantFixture.provisioned_tenant!/1` tenant (the pool snapshots
  `public.tenants`). Tokens for the listing are inserted RAW with a known plaintext, so the test
  can prove neither the plaintext, its hash, nor the `lf_tok_` prefix ever reaches the response or
  the `token.listed` entry.

  `async: false`: committed writes, DDL (audit fault triggers), VM-global platform pin.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import Plug.Conn

  alias Letflow.Audit.Entry
  alias Letflow.Identity.ApiToken
  alias Letflow.Identity.GroupMember
  alias Letflow.ScopeEnforcement
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.TokenMintFixture
  alias Letflow.TenantFixture

  @router Letflow.Routers.TenantScopeEnforcement
  @trace "6f1c2b9e-0497-4a11-8c20-0000000002b1"
  @token_keys Enum.sort(
                ~w(id name user_id issuer_user_id roles status created_at expires_at revoked_at last_used_at)
              )

  setup do
    Fixture.unpin!()
    :ok
  end

  # --- helpers ---------------------------------------------------------------------------------

  defp tenant!(slug_prefix), do: TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)

  defp admin_tenant!(slug_prefix) do
    fx = tenant!(slug_prefix)
    Map.put(fx, :admin, TokenMintFixture.role_holder!(fx.schema_name, ["TENANT_ADMIN"]))
  end

  defp call(method, path, fx, user_id, roles, body) do
    method
    |> Fixture.router_conn(path, fx, roles, body)
    |> assign(:auth_context, %{
      user_id: user_id,
      tenant_id: fx.tenant_id,
      roles: roles,
      credential: :oidc
    })
    |> assign(:trace_id, @trace)
    |> @router.call(@router.init([]))
  end

  defp as_admin(method, path, fx, body),
    do: call(method, path, fx, fx.admin.id, ["TENANT_ADMIN"], body)

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp mode!(fx) do
    {:ok, mode} = ScopeEnforcement.get_mode(fx.tenant_id)
    mode
  end

  defp entries(fx, action) do
    Repo.all(from(e in Entry, where: e.action == ^action, order_by: e.timestamp),
      prefix: fx.schema_name
    )
  end

  defp flip_entries(fx),
    do: entries(fx, "scope.enforcement_enabled") ++ entries(fx, "scope.enforcement_disabled")

  defp seconds_from_now(seconds),
    do: DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)

  # A raw token with a known plaintext; returns `{token, plaintext}`.
  defp token!(schema, owner_id, roles, fields) do
    n = System.unique_integer([:positive])
    plaintext = "lf_tok_" <> Base.encode16(:crypto.hash(:sha256, "req497-rt-#{n}"), case: :lower)

    token =
      Repo.insert!(
        struct(
          ApiToken,
          Map.merge(
            %{
              user_id: owner_id,
              name: "req497-rt-#{n}",
              token_hash: Base.encode16(:crypto.hash(:sha256, plaintext), case: :lower),
              roles: roles,
              issuer_user_id: owner_id,
              expires_at: nil,
              revoked_at: nil
            },
            fields
          )
        ),
        prefix: schema
      )

    {token, plaintext}
  end

  defp drop_memberships!(schema, user_id) do
    {_n, _} =
      Repo.delete_all(from(m in GroupMember, where: m.user_id == ^user_id), prefix: schema)

    :ok
  end

  defp with_audit_fault(fx, action, fun) do
    schema = fx.schema_name
    name = "req497_rt_audit_fault"

    Repo.query!(
      ~s|CREATE FUNCTION "#{schema}".#{name}() RETURNS trigger LANGUAGE plpgsql AS $$ | <>
        ~s|BEGIN IF NEW.action = '#{action}' THEN | <>
        ~s|RAISE EXCEPTION 'injected audit fault (REQ-497 test)'; END IF; RETURN NEW; END $$|
    )

    Repo.query!(
      ~s|CREATE TRIGGER #{name} BEFORE INSERT ON "#{schema}".audit_entries | <>
        ~s|FOR EACH ROW EXECUTE FUNCTION "#{schema}".#{name}()|
    )

    try do
      fun.()
    after
      Repo.query!(~s|DROP TRIGGER IF EXISTS #{name} ON "#{schema}".audit_entries|)
      Repo.query!(~s|DROP FUNCTION IF EXISTS "#{schema}".#{name}()|)
    end
  end

  defp item_ids(items), do: items |> Enum.map(& &1["id"]) |> Enum.sort()

  # --- GET / ---------------------------------------------------------------------------------

  test "GET / returns the mode and the stage-1 modes only" do
    fx = admin_tenant!("req497-rt-get")
    conn = as_admin(:get, "/", fx, nil)

    assert conn.status == 200
    assert body(conn) == %{"mode" => "off", "available_modes" => ["off", "shadow"]}
  end

  # --- T-F1 ------------------------------------------------------------------------------------

  describe "T-F1 only off | shadow" do
    test "PUT with on, ON, enforce, 1, null or a missing mode is 422 invalid_enforcement_mode and changes nothing" do
      fx = admin_tenant!("req497-rt-f1")

      bodies = [
        %{"mode" => "on"},
        %{"mode" => "ON"},
        %{"mode" => "enforce"},
        %{"mode" => 1},
        %{"mode" => nil},
        %{"reason" => "no mode"},
        %{}
      ]

      for b <- bodies do
        conn = as_admin(:put, "/", fx, b)
        assert conn.status == 422, inspect(b)
        assert body(conn)["detail"] == "invalid_enforcement_mode", inspect(b)
      end

      assert mode!(fx) == :off
      assert flip_entries(fx) == []
    end

    # REQ-517 2b widened the CHECK to off | shadow | on: `on` is a STORED value now (no route
    # can set it), any other spelling still violates the constraint.
    test "a direct SQL write of 'ON' violates tenants_scope_enforcement_check" do
      fx = tenant!("req497-rt-f1-sql")

      assert {:error, %Postgrex.Error{postgres: %{constraint: "tenants_scope_enforcement_check"}}} =
               Repo.query(
                 "UPDATE public.tenants SET scope_enforcement = 'ON' WHERE id = $1",
                 [Ecto.UUID.dump!(fx.tenant_id)]
               )

      assert mode!(fx) == :off
    end
  end

  # --- T-F2 ------------------------------------------------------------------------------------

  describe "T-F2 the flag is not settable elsewhere" do
    test "PATCH /tenant/settings with scope_enforcement in the body leaves the flag off" do
      fx = admin_tenant!("req497-rt-f2-set")

      conn =
        :patch
        |> Fixture.router_conn("/", fx, ["TENANT_ADMIN"], %{
          "scope_enforcement" => "shadow",
          "app_name" => "REQ-497"
        })
        |> Letflow.Routers.TenantSettings.call(Letflow.Routers.TenantSettings.init([]))

      # The route applied the recognised key and dropped the unknown one.
      assert conn.status == 200
      assert mode!(fx) == :off
      {:ok, tenant} = Letflow.Identity.get_tenant(fx.tenant_id)
      assert tenant.settings["app_name"] == "REQ-497"
      refute Map.has_key?(tenant.settings, "scope_enforcement")
    end

    test "PATCH /tenants/:slug (platform operator) with scope_enforcement in the body leaves the flag off" do
      p = tenant!("req497-rt-f2-p")
      fx = tenant!("req497-rt-f2-t")
      operator = RSG.user!(p.schema_name)

      conn =
        :patch
        |> Fixture.router_conn("/#{fx.tenant.slug}", p, ["PLATFORM_ADMIN"], %{
          "display_name" => "REQ-497 renamed",
          "scope_enforcement" => "shadow"
        })
        |> assign(
          :auth_context,
          Fixture.operator_auth_context(operator.id, p.tenant_id, ["PLATFORM_ADMIN"])
        )
        |> Letflow.Routers.Tenants.call(Letflow.Routers.Tenants.init([]))

      # The route applies the patch (display_name) and drops the flag key: admin_patch_changeset/2
      # does not cast it (T-F7 pins the changesets).
      assert conn.status == 200
      assert {:ok, %{display_name: "REQ-497 renamed"}} = Letflow.Identity.get_tenant(fx.tenant_id)
      assert mode!(fx) == :off
    end
  end

  # --- T-F3 ------------------------------------------------------------------------------------

  describe "T-F3 who may read and flip" do
    test "a caller without :UsersGroupsRolesManage (PROCESS_DESIGNER) gets the plug's 403 on every route" do
      fx = admin_tenant!("req497-rt-f3-pd")
      designer = TokenMintFixture.role_holder!(fx.schema_name, ["PROCESS_DESIGNER"])

      for {method, path, b} <- [
            {:get, "/", nil},
            {:put, "/", %{"mode" => "shadow"}},
            {:get, "/integrity", nil},
            {:get, "/token-preconditions", nil}
          ] do
        conn = call(method, path, fx, designer.id, ["PROCESS_DESIGNER"], b)
        assert conn.status == 403, "#{method} #{path}"
      end

      assert mode!(fx) == :off
      assert entries(fx, "token.listed") == []
    end

    test "a TENANT_ADMIN whose TA group holds only a scoped row gets 403 insufficient permissions" do
      fx = admin_tenant!("req497-rt-f3-scoped")

      _node =
        RSG.make_group_scoped_only!(
          fx.schema_name,
          RSG.group_of!(fx.schema_name, "TENANT_ADMIN"),
          "TENANT_ADMIN"
        )

      for {method, path, b} <- [
            {:get, "/", nil},
            {:put, "/", %{"mode" => "shadow"}},
            {:get, "/integrity", nil},
            {:get, "/token-preconditions", nil}
          ] do
        conn = as_admin(method, path, fx, b)
        assert conn.status == 403, "#{method} #{path}"
        assert body(conn)["detail"] == "insufficient permissions"
      end

      assert mode!(fx) == :off
      assert entries(fx, "token.listed") == []
    end

    test "a tenant-wide TENANT_ADMIN flips to shadow (200)" do
      fx = admin_tenant!("req497-rt-f3-ta")
      conn = as_admin(:put, "/", fx, %{"mode" => "shadow"})

      assert conn.status == 200
      assert body(conn) == %{"mode" => "shadow", "previous" => "off", "changed" => true}
      assert mode!(fx) == :shadow

      assert [%{actor_id: actor, trace_id: @trace}] = entries(fx, "scope.enforcement_enabled")
      assert actor == fx.admin.id
    end

    test "a platform-tenant PLATFORM_ADMIN flips the platform tenant's own flag (200)" do
      p = tenant!("req497-rt-f3-p")
      :ok = Fixture.pin!(p.tenant_id)
      operator = RSG.user!(p.schema_name)

      conn = call(:put, "/", p, operator.id, ["PLATFORM_ADMIN"], %{"mode" => "shadow"})

      assert conn.status == 200
      assert {:ok, :shadow} = ScopeEnforcement.get_mode(p.tenant_id)
    end

    test "full pipeline: a TENANT_ADMIN API token reaches GET /api/v1/tenant/scope-enforcement (mount)" do
      fx = tenant!("req497-rt-f3-pipe")
      token = Fixture.mint_token!(fx, ["TENANT_ADMIN"])

      conn =
        :get
        |> Fixture.api_conn("/api/v1/tenant/scope-enforcement", token, fx.tenant.slug, nil)
        |> Fixture.dispatch_api()

      assert conn.status == 200
      assert body(conn)["mode"] == "off"
    end
  end

  # --- T-F4 / T-F9 / T-F10 (HTTP) -----------------------------------------------------------------

  test "T-F4 a precondition refusal is 409 enforcement_precondition_failed naming the checks, with counts only" do
    fx = admin_tenant!("req497-rt-f4")
    g = RSG.fresh_group!(fx.schema_name)
    _gap = RSG.raw_binding!(fx.schema_name, "PROCESS_OPERATOR", :platform_role, g.id)

    conn = as_admin(:put, "/", fx, %{"mode" => "shadow"})

    assert conn.status == 409
    b = body(conn)
    assert b["detail"] == "enforcement_precondition_failed"
    assert b["failed"] == ["bindings_without_row"]

    assert b["report"] == %{
             "bindings_without_row" => 1,
             "org_consistency" => "ok",
             "tokens_exceeding_owner" => 0
           }

    # INV-2: no ids or names of the offending records.
    refute conn.resp_body =~ g.id
    refute conn.resp_body =~ "PROCESS_OPERATOR"
    assert mode!(fx) == :off
    assert flip_entries(fx) == []
  end

  test "T-F9 a forced audit failure answers 500 and the mode is unchanged" do
    fx = admin_tenant!("req497-rt-f9")

    conn =
      with_audit_fault(fx, "scope.enforcement_enabled", fn ->
        as_admin(:put, "/", fx, %{"mode" => "shadow"})
      end)

    assert conn.status == 500
    assert mode!(fx) == :off
    assert flip_entries(fx) == []
  end

  test "T-F10 a same-mode PUT is 200 changed: false with no audit, even with a T9 gap" do
    fx = admin_tenant!("req497-rt-f10")
    assert as_admin(:put, "/", fx, %{"mode" => "shadow"}).status == 200
    before = flip_entries(fx)
    g = RSG.fresh_group!(fx.schema_name)
    _gap = RSG.raw_binding!(fx.schema_name, "PROCESS_OPERATOR", :platform_role, g.id)

    conn = as_admin(:put, "/", fx, %{"mode" => "shadow"})
    assert conn.status == 200
    assert body(conn) == %{"mode" => "shadow", "previous" => "shadow", "changed" => false}
    assert flip_entries(fx) == before
  end

  # --- T-F8 ------------------------------------------------------------------------------------

  describe "T-F8 turning the flag off needs a reason" do
    test "no reason -> 422 reason_required; invalid -> 422 invalid_reason; valid -> 200" do
      fx = admin_tenant!("req497-rt-f8")
      assert as_admin(:put, "/", fx, %{"mode" => "shadow"}).status == 200

      conn = as_admin(:put, "/", fx, %{"mode" => "off"})
      assert conn.status == 422
      assert body(conn)["detail"] == "reason_required"

      for bad <- ["", "two\nlines", "bidi\u202Etext", 7] do
        conn = as_admin(:put, "/", fx, %{"mode" => "off", "reason" => bad})
        assert conn.status == 422, inspect(bad)
        assert body(conn)["detail"] == "invalid_reason", inspect(bad)
      end

      assert mode!(fx) == :shadow

      conn = as_admin(:put, "/", fx, %{"mode" => "off", "reason" => "shadow review done"})
      assert conn.status == 200
      assert body(conn) == %{"mode" => "off", "previous" => "shadow", "changed" => true}
      assert [entry] = entries(fx, "scope.enforcement_disabled")
      assert entry.after_state == %{"mode" => "off", "reason" => "shadow review done"}
    end

    test "SEC advisory 3 (pins CURRENT behaviour): PUT off with no reason on an already-off tenant is 422 reason_required" do
      fx = admin_tenant!("req497-rt-sec3")

      conn = as_admin(:put, "/", fx, %{"mode" => "off"})

      assert conn.status == 422
      assert body(conn)["detail"] == "reason_required"
      assert mode!(fx) == :off
      assert flip_entries(fx) == []
    end
  end

  # --- T-I1 ------------------------------------------------------------------------------------

  describe "T-I1 GET /integrity" do
    test "a clean writer-built tenant reports zeros and no findings" do
      fx = admin_tenant!("req497-rt-i1-clean")
      conn = as_admin(:get, "/integrity", fx, nil)

      assert conn.status == 200

      assert body(conn) == %{
               "bindings_without_row" => 0,
               "items" => [],
               "orphan_group_rows" => 0,
               "truncated" => false,
               "findings" => []
             }
    end

    test "a seeded gap is listed with role id, name and group id; writes no audit entry" do
      fx = admin_tenant!("req497-rt-i1-gap")
      g = RSG.fresh_group!(fx.schema_name)
      gap = RSG.raw_binding!(fx.schema_name, "PROCESS_OPERATOR", :platform_role, g.id)
      audit_before = Repo.aggregate(Entry, :count, prefix: fx.schema_name)

      conn = as_admin(:get, "/integrity", fx, nil)

      assert conn.status == 200
      b = body(conn)
      assert b["bindings_without_row"] == 1

      assert b["items"] == [
               %{"role_id" => gap.id, "name" => "PROCESS_OPERATOR", "group_id" => g.id}
             ]

      assert b["findings"] == []
      assert Repo.aggregate(Entry, :count, prefix: fx.schema_name) == audit_before
    end

    test "the tenant comes from auth only: a tenant_id in the query or body is ignored" do
      a = admin_tenant!("req497-rt-i1-a")
      other = tenant!("req497-rt-i1-b")
      g = RSG.fresh_group!(other.schema_name)
      _gap = RSG.raw_binding!(other.schema_name, "PROCESS_OPERATOR", :platform_role, g.id)

      conn =
        as_admin(:get, "/integrity?tenant_id=#{other.tenant_id}", a, %{
          "tenant_id" => other.tenant_id
        })

      assert conn.status == 200
      assert body(conn)["bindings_without_row"] == 0
      refute conn.resp_body =~ g.id
    end

    test "zero_tenant_wide_admins is an informational finding (platform operator on a tenant with no TA admin)" do
      p = tenant!("req497-rt-i1-zero")
      :ok = Fixture.pin!(p.tenant_id)
      operator = RSG.user!(p.schema_name)
      assert Letflow.Identity.count_tenant_wide_admins(p.schema_name) == 0

      conn = call(:get, "/integrity", p, operator.id, ["PLATFORM_ADMIN"], nil)
      assert conn.status == 200
      assert body(conn)["findings"] == ["zero_tenant_wide_admins"]

      # Informational: it does not block the off -> shadow flip.
      conn = call(:put, "/", p, operator.id, ["PLATFORM_ADMIN"], %{"mode" => "shadow"})
      assert conn.status == 200
      assert {:ok, :shadow} = ScopeEnforcement.get_mode(p.tenant_id)
    end
  end

  # --- T-L1..T-L4 ------------------------------------------------------------------------------

  describe "T-L GET /token-preconditions" do
    setup do
      fx = admin_tenant!("req497-rt-l")
      s = fx.schema_name
      lost = TokenMintFixture.role_holder!(s, ["PROCESS_DESIGNER"])
      holder = TokenMintFixture.role_holder!(s, ["PROCESS_DESIGNER"])
      inactive = TokenMintFixture.role_holder!(s, ["PROCESS_DESIGNER"], status: :inactive)

      {exceeding, p1} = token!(s, lost.id, ["PROCESS_DESIGNER"], %{})

      {_revoked, p2} =
        token!(s, lost.id, ["PROCESS_DESIGNER"], %{revoked_at: seconds_from_now(-60)})

      {_expired, p3} =
        token!(s, lost.id, ["PROCESS_DESIGNER"], %{expires_at: seconds_from_now(-60)})

      {compliant, p4} = token!(s, holder.id, ["PROCESS_DESIGNER"], %{})
      {null_issuer, p5} = token!(s, holder.id, ["PROCESS_DESIGNER"], %{issuer_user_id: nil})
      {inactive_null, p6} = token!(s, inactive.id, ["PROCESS_DESIGNER"], %{issuer_user_id: nil})

      :ok = drop_memberships!(s, lost.id)

      tokens = Repo.all(ApiToken, prefix: s)

      %{
        fx: fx,
        exceeding: exceeding,
        compliant: compliant,
        null_issuer: null_issuer,
        inactive_null: inactive_null,
        plaintexts: [p1, p2, p3, p4, p5, p6],
        hashes: Enum.map(tokens, & &1.token_hash)
      }
    end

    test "T-L1 each seeded token is in its list; compliant, revoked and expired ones are absent; flip_blocked",
         ctx do
      conn = as_admin(:get, "/token-preconditions", ctx.fx, nil)

      assert conn.status == 200
      b = body(conn)
      assert b["flip_blocked"] == true
      assert item_ids(b["blocking"]["roles_exceed_owner"]) == [ctx.exceeding.id]

      assert item_ids(b["information"]["null_issuer"]) ==
               Enum.sort([ctx.null_issuer.id, ctx.inactive_null.id])

      assert b["information"]["non_expiring_platform_admin"] == []
      assert b["count"] == 3
      refute conn.resp_body =~ ctx.compliant.id
    end

    test "T-L1 flip_blocked is false when only informational findings remain", ctx do
      {1, _} =
        Repo.delete_all(from(t in ApiToken, where: t.id == ^ctx.exceeding.id),
          prefix: ctx.fx.schema_name
        )

      b = body(as_admin(:get, "/token-preconditions", ctx.fx, nil))
      assert b["flip_blocked"] == false
      assert b["blocking"]["roles_exceed_owner"] == []
      assert length(b["information"]["null_issuer"]) == 2
    end

    test "T-L2 item keys are exactly the 10 #2552 keys; status is effective; no plaintext, hash or lf_tok_",
         ctx do
      conn = as_admin(:get, "/token-preconditions", ctx.fx, nil)
      b = body(conn)

      items =
        b["blocking"]["roles_exceed_owner"] ++
          b["information"]["null_issuer"] ++ b["information"]["non_expiring_platform_admin"]

      assert items != []

      for item <- items do
        assert item |> Map.keys() |> Enum.sort() == @token_keys
      end

      statuses = Map.new(items, &{&1["id"], &1["status"]})
      assert statuses[ctx.exceeding.id] == "active"
      assert statuses[ctx.null_issuer.id] == "active"
      assert statuses[ctx.inactive_null.id] == "owner_inactive"

      for secret <- ctx.plaintexts ++ ctx.hashes do
        refute conn.resp_body =~ secret
      end

      refute conn.resp_body =~ "lf_tok_"
      refute conn.resp_body =~ "token_hash"
    end

    test "T-L3 one token.listed entry per call, after_state exactly {actor, count, token_ids}",
         ctx do
      fx = ctx.fx
      assert as_admin(:get, "/token-preconditions", fx, nil).status == 200
      assert as_admin(:get, "/token-preconditions", fx, nil).status == 200

      listed = entries(fx, "token.listed")
      assert length(listed) == 2

      expected_ids = Enum.sort([ctx.exceeding.id, ctx.null_issuer.id, ctx.inactive_null.id])

      for entry <- listed do
        assert entry.after_state |> Map.keys() |> Enum.sort() == ["actor", "count", "token_ids"]
        assert entry.after_state["actor"] == fx.admin.id
        assert entry.after_state["count"] == 3
        assert entry.after_state["token_ids"] == expected_ids
        assert entry.actor_id == fx.admin.id
        assert entry.trace_id == @trace
        assert entry.resource_type == "api_token_listing"
        assert entry.resource_id == fx.tenant_id
        assert entry.before_state == nil

        encoded = Jason.encode!(Map.take(entry, [:after_state, :before_state, :resource_id]))
        refute encoded =~ "lf_tok_"

        for secret <- ctx.plaintexts ++ ctx.hashes do
          refute encoded =~ secret
        end
      end
    end

    test "T-L3 an audit failure answers 500 with no token data and no entry", ctx do
      fx = ctx.fx

      conn =
        with_audit_fault(fx, "token.listed", fn ->
          as_admin(:get, "/token-preconditions", fx, nil)
        end)

      assert conn.status == 500

      for id <- [ctx.exceeding.id, ctx.null_issuer.id, ctx.inactive_null.id] do
        refute conn.resp_body =~ id
      end

      refute conn.resp_body =~ "roles_exceed_owner"
      assert entries(fx, "token.listed") == []
    end

    test "T-L4 403 without the permission and 403 for a scoped TENANT_ADMIN; no token.listed",
         ctx do
      fx = ctx.fx
      designer = TokenMintFixture.role_holder!(fx.schema_name, ["PROCESS_DESIGNER"])

      conn = call(:get, "/token-preconditions", fx, designer.id, ["PROCESS_DESIGNER"], nil)
      assert conn.status == 403

      _node =
        RSG.make_group_scoped_only!(
          fx.schema_name,
          RSG.group_of!(fx.schema_name, "TENANT_ADMIN"),
          "TENANT_ADMIN"
        )

      conn = as_admin(:get, "/token-preconditions", fx, nil)
      assert conn.status == 403
      refute conn.resp_body =~ ctx.exceeding.id
      assert entries(fx, "token.listed") == []
    end
  end

  test "T-L1 platform tenant: a non-expiring PLATFORM_ADMIN token is informational and does not block" do
    p = tenant!("req497-rt-l-p")
    :ok = Fixture.pin!(p.tenant_id)
    pa = TokenMintFixture.role_holder!(p.schema_name, ["PLATFORM_ADMIN"])
    {pa_token, _plaintext} = token!(p.schema_name, pa.id, ["PLATFORM_ADMIN"], %{})

    conn = call(:get, "/token-preconditions", p, pa.id, ["PLATFORM_ADMIN"], nil)

    assert conn.status == 200
    b = body(conn)
    assert b["flip_blocked"] == false
    assert item_ids(b["information"]["non_expiring_platform_admin"]) == [pa_token.id]
    assert b["blocking"]["roles_exceed_owner"] == []
  end
end
