defmodule Letflow.Api.PlatformAdminOutsidePlatformTest do
  @moduledoc """
  REQ-447 PR 2, AC4 (`lib/letflow/design/req447-tenant-admin-role.md` sections 2.2, 3.4, 3.5 and
  the "PR 2" test plan of section 11; spec `test/specs/REQ-447-PR2.md`): `PLATFORM_ADMIN` exists
  only in the platform tenant.

  WRITE side (rejected outside the platform tenant):

    * `RoleRegistry.upsert_role/4` with a `:platform_role` named `PLATFORM_ADMIN` and a
      non-platform prefix returns `{:error, :platform_admin_outside_platform_tenant}` before any
      `Repo` call (asserted with captured query telemetry); the platform tenant's prefix still
      accepts it. Over HTTP `POST /identity/roles` answers 403 (the H1 guard runs first; the 422
      arm of the router is defence in depth for non-HTTP callers and is NOT reachable over HTTP,
      so it has no HTTP test here).
    * `POST /identity/tokens` with `PLATFORM_ADMIN` answers 403 from the router (unchanged from PR 1)
      for a non-operator; a DIRECT call of `Identity.create_token/3` with a non-platform prefix
      returns `{:error, :invalid_role_set}` (unit test: it is reachable only that way) while the
      platform tenant's prefix still succeeds.

  READ side (dropped, not honoured):

    * A legacy stored binding plus membership, a stored API token row and a claim, each carrying
      `PLATFORM_ADMIN` in an ordinary tenant, confer nothing: 403 on platform routes AND no
      catch-all on tenant routes AND no `:UnmatchedRoute` 404 pass-through. The platform tenant's
      own `PLATFORM_ADMIN` is unchanged (control on every test).
    * `sync_role_claims_from_token/3` resolves no group for a claimed `PLATFORM_ADMIN` outside the
      platform schema (a legacy binding is present, so only the new rule can explain it).
    * A hand-assigned context carrying `PLATFORM_ADMIN` + `TASK_WORKER` in an ordinary tenant does
      not get the unfiltered `GET /tasks/inbox` (`routers/tasks.ex`).
    * `routers/entities.ex` hands the recomputed platform flag to the unredacted-export check
      (OQ-10): the platform operator keeps unredacted export.
    * The `:UnmatchedRoute` rule needs `platform_tenant? == true`.
    * The C6 switch is deleted: no function, no config key anywhere in `lib/` or `config/`.

  Real Postgres, `async: false` (VM-global platform tenant pin).
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog

  alias Letflow.Api.Authorization
  alias Letflow.Api.Authorization.AccessContext
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Engine.TokenRecord
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Identity
  alias Letflow.Identity.ApiToken
  alias Letflow.Identity.Group
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User
  alias Letflow.Oidc.IdentityContext
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.TokenMintFixture

  @unused_uuid "00000000-0000-4000-8000-000000000005"

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    {:ok, tenants}
  end

  # --- helpers --------------------------------------------------------------------------------

  defp call(router, method, path, fixture, roles, body) do
    router.call(Fixture.router_conn(method, path, fixture, roles, body), router.init([]))
  end

  # GH 2552: `call/6` as a REAL caller `user_id` (Identity.mint_token/4 checks the caller).
  defp call_as(router, method, path, fixture, user_id, roles, body) do
    conn =
      method
      |> Fixture.router_conn(path, fixture, roles, body)
      |> Plug.Conn.assign(:auth_context, %{
        user_id: user_id,
        tenant_id: fixture.tenant_id,
        roles: roles
      })

    router.call(conn, router.init([]))
  end

  defp insert_user!(fixture) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "req447-pr2-#{Ecto.UUID.generate()}",
      display_name: "REQ-447 PR2 User",
      email: "req447-pr2-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: fixture.schema_name)
  end

  defp group!(fixture, name) do
    {:ok, %Group{} = group} =
      RoleRegistry.get_or_create_group_by_name(name, prefix: fixture.schema_name)

    group
  end

  # A LEGACY `PLATFORM_ADMIN` binding, as it exists in a tenant onboarded before REQ-447: a raw
  # insert, because `upsert_role/4` can no longer create one outside the platform tenant.
  defp legacy_platform_admin_binding!(fixture) do
    group = group!(fixture, "PLATFORM_ADMIN")

    %TenantRole{}
    |> TenantRole.changeset(%{name: "PLATFORM_ADMIN", kind: :platform_role, group_id: group.id})
    |> Repo.insert!(prefix: fixture.schema_name)

    group
  end

  # An API token row written directly, simulating one minted by `create_token/3` before the PR 2
  # rule existed. Returns the plaintext.
  defp raw_token!(fixture, user, roles) do
    plaintext = "lf_tok_" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    token_hash = :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)

    %ApiToken{}
    |> ApiToken.insert_changeset(%{
      user_id: user.id,
      name: "raw-" <> String.slice(token_hash, 0, 8),
      token_hash: token_hash,
      roles: roles,
      expires_at: nil
    })
    |> Repo.insert!(prefix: fixture.schema_name)

    plaintext
  end

  defp role_names(fixture) do
    [prefix: fixture.schema_name] |> RoleRegistry.list_roles() |> Enum.map(& &1.name)
  end

  defp token_count(fixture) do
    {:ok, tokens} = Identity.list_tokens(prefix: fixture.schema_name)
    length(tokens)
  end

  defp insert_task!(fixture, assignee_user_id) do
    instance_id = Ecto.UUID.generate()

    %InstanceProjection{}
    |> InstanceProjection.insert_changeset(%{
      instance_id: instance_id,
      status: :active,
      definition_id: Ecto.UUID.generate()
    })
    |> Repo.insert!(prefix: fixture.schema_name)

    token =
      %TokenRecord{}
      |> TokenRecord.insert_changeset(%{
        instance_id: instance_id,
        node_id: "review",
        branch_id: "b1"
      })
      |> Repo.insert!(prefix: fixture.schema_name)

    %EngineTask{}
    |> EngineTask.insert_changeset(%{
      instance_id: instance_id,
      token_id: token.id,
      node_id: "review",
      node_name: "Review",
      assignee_type: "USER",
      assignee_ref: assignee_user_id
    })
    |> Repo.insert!(prefix: fixture.schema_name)
  end

  # One representative request per platform router, and per tenant-scope surface.
  defp platform_specs do
    [
      {Letflow.Routers.Tenants, :get, "/", nil},
      {Letflow.Routers.Onboarding, :get, "/", nil},
      {Letflow.Routers.PlatformMigrations, :get, "/rollouts/" <> @unused_uuid, nil},
      {Letflow.Routers.EventRetention, :get, "/summary", nil},
      {Letflow.Routers.AdminServices, :get, "/", nil}
    ]
  end

  defp tenant_specs do
    [
      {Letflow.Routers.Identity, :get, "/users", nil},
      {Letflow.Routers.Identity, :get, "/groups", nil},
      {Letflow.Routers.Identity, :get, "/roles", nil},
      {Letflow.Routers.Identity, :get, "/tokens", nil},
      {Letflow.Routers.Audit, :get, "/", nil},
      {Letflow.Routers.TenantSettings, :patch, "/", %{"app_name" => "Renamed"}}
    ]
  end

  defp statuses(specs, fixture, roles) do
    for {router, method, path, body} <- specs do
      {"#{inspect(router)} #{method} #{path}",
       call(router, method, path, fixture, roles, body).status}
    end
  end

  defp assert_all_status(specs, fixture, roles, expected) do
    for {label, status} <- statuses(specs, fixture, roles) do
      assert status == expected,
             "roles #{inspect(roles)}, #{label}: expected #{expected}, got #{status}"
    end
  end

  # --- AC4 write side: upsert_role/4 ----------------------------------------------------------

  describe "AC4: RoleRegistry.upsert_role/4 with PLATFORM_ADMIN" do
    test "is rejected in an ordinary tenant with the exact tag, writing nothing", ctx do
      for fixture <- [ctx.a, ctx.b] do
        group = group!(fixture, "req447-pr2-g")

        assert {:error, :platform_admin_outside_platform_tenant} =
                 RoleRegistry.upsert_role("PLATFORM_ADMIN", :platform_role, group.id,
                   prefix: fixture.schema_name
                 )

        refute "PLATFORM_ADMIN" in role_names(fixture)
      end
    end

    test "is rejected before any Repo call (a nonexistent group id still yields the tag, zero queries)",
         ctx do
      {result, queries} =
        Fixture.capture_repo_queries(fn ->
          RoleRegistry.upsert_role("PLATFORM_ADMIN", :platform_role, Ecto.UUID.generate(),
            prefix: ctx.a.schema_name
          )
        end)

      assert result == {:error, :platform_admin_outside_platform_tenant}
      assert queries == []
    end

    test "fails closed in the would-be platform tenant when NO pin is configured", ctx do
      Fixture.unpin!()
      group = group!(ctx.p, "req447-pr2-g")

      assert {:error, :platform_admin_outside_platform_tenant} =
               RoleRegistry.upsert_role("PLATFORM_ADMIN", :platform_role, group.id,
                 prefix: ctx.p.schema_name
               )
    end

    test "is accepted in the platform tenant (control), and other built-in names stay accepted in an ordinary tenant",
         ctx do
      group_p = group!(ctx.p, "req447-pr2-gp")

      assert {:ok, %TenantRole{name: "PLATFORM_ADMIN", kind: :platform_role}} =
               RoleRegistry.upsert_role("PLATFORM_ADMIN", :platform_role, group_p.id,
                 prefix: ctx.p.schema_name
               )

      group_a = group!(ctx.a, "req447-pr2-ga")

      for name <- ["TENANT_ADMIN", "PROCESS_DESIGNER", "TASK_WORKER"] do
        assert {:ok, %TenantRole{name: ^name}} =
                 RoleRegistry.upsert_role(name, :platform_role, group_a.id,
                   prefix: ctx.a.schema_name
                 )
      end
    end
  end

  describe "AC4: POST /identity/roles with PLATFORM_ADMIN over HTTP" do
    test "is 403 with the fixed body in an ordinary tenant, for every kind and every caller who reaches the route",
         ctx do
      group = group!(ctx.a, "req447-pr2-g")

      for roles <- [["TENANT_ADMIN"], ["TENANT_ADMIN", "PLATFORM_ADMIN"]],
          kind <- ["platform_role", "process_routing_role"] do
        resp =
          call(Letflow.Routers.Identity, :post, "/roles", ctx.a, roles, %{
            "name" => "PLATFORM_ADMIN",
            "kind" => kind,
            "group_id" => group.id
          })

        assert resp.status == 403, "#{inspect(roles)} #{kind}: #{resp.resp_body}"
        assert resp.resp_body =~ "insufficient permissions"
        refute "PLATFORM_ADMIN" in role_names(ctx.a)
      end

      # a lone legacy PLATFORM_ADMIN caller is dropped entirely: 403 as well, nothing written
      legacy =
        call(Letflow.Routers.Identity, :post, "/roles", ctx.a, ["PLATFORM_ADMIN"], %{
          "name" => "PLATFORM_ADMIN",
          "kind" => "platform_role",
          "group_id" => group.id
        })

      assert legacy.status == 403
      refute "PLATFORM_ADMIN" in role_names(ctx.a)
    end

    test "the platform operator can still bind PLATFORM_ADMIN in the platform tenant (control)",
         ctx do
      group = group!(ctx.p, "req447-pr2-gp")

      resp =
        call(Letflow.Routers.Identity, :post, "/roles", ctx.p, ["PLATFORM_ADMIN"], %{
          "name" => "PLATFORM_ADMIN",
          "kind" => "platform_role",
          "group_id" => group.id
        })

      assert resp.status == 200, resp.resp_body
      assert "PLATFORM_ADMIN" in role_names(ctx.p)
    end
  end

  # --- AC4 write side: tokens -----------------------------------------------------------------

  describe "AC4: PLATFORM_ADMIN tokens" do
    test "POST /identity/tokens with PLATFORM_ADMIN is 403 in an ordinary tenant (router), no token written",
         ctx do
      user = insert_user!(ctx.a)
      before = token_count(ctx.a)

      for roles <- [["PLATFORM_ADMIN"], ["TENANT_ADMIN", "PLATFORM_ADMIN"]] do
        resp =
          call(Letflow.Routers.Identity, :post, "/tokens", ctx.a, ["TENANT_ADMIN"], %{
            "user_id" => user.id,
            "roles" => roles
          })

        assert resp.status == 403, "#{inspect(roles)}: #{resp.resp_body}"
        assert resp.resp_body =~ "insufficient permissions"
      end

      assert token_count(ctx.a) == before
    end

    test "POST /identity/tokens with PLATFORM_ADMIN by the platform operator in the platform tenant is 201 (control)",
         ctx do
      # GH 2552: the operator holds PLATFORM_ADMIN by membership; a PA token is self-targeted
      # and expiring (advisor conditions 1 and 2).
      operator = TokenMintFixture.role_holder!(ctx.p.schema_name, ["PLATFORM_ADMIN"])

      expires_at =
        DateTime.utc_now() |> DateTime.add(7 * 86_400, :second) |> DateTime.to_iso8601()

      resp =
        call_as(
          Letflow.Routers.Identity,
          :post,
          "/tokens",
          ctx.p,
          operator.id,
          ["PLATFORM_ADMIN"],
          %{
            "user_id" => operator.id,
            "roles" => ["PLATFORM_ADMIN"],
            "expires_at" => expires_at
          }
        )

      assert resp.status == 201, resp.resp_body
    end

    test "create_token/3 DIRECT call: {:error, :invalid_role_set} for PLATFORM_ADMIN with a non-platform prefix, nothing written",
         ctx do
      for fixture <- [ctx.a, ctx.b] do
        user = insert_user!(fixture)
        before = token_count(fixture)

        for roles <- [["PLATFORM_ADMIN"], ["TENANT_ADMIN", "PLATFORM_ADMIN"]] do
          assert {:error, :invalid_role_set} =
                   Identity.create_token(user.id, %{roles: roles, expires_at: nil},
                     prefix: fixture.schema_name
                   )
        end

        assert token_count(fixture) == before
      end
    end

    test "create_token/3 with the platform tenant's prefix still succeeds for PLATFORM_ADMIN; an ordinary tenant still gets TENANT_ADMIN tokens",
         ctx do
      user_p = insert_user!(ctx.p)

      assert {:ok, %{token: %ApiToken{roles: ["PLATFORM_ADMIN"]}, plaintext: "lf_tok_" <> _}} =
               Identity.create_token(user_p.id, %{roles: ["PLATFORM_ADMIN"], expires_at: nil},
                 prefix: ctx.p.schema_name
               )

      user_a = insert_user!(ctx.a)

      assert {:ok, %{token: %ApiToken{roles: ["TENANT_ADMIN"]}}} =
               Identity.create_token(user_a.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
                 prefix: ctx.a.schema_name
               )
    end

    test "create_token/3 with no pin configured rejects PLATFORM_ADMIN even for the would-be platform tenant (fail closed)",
         ctx do
      Fixture.unpin!()
      user = insert_user!(ctx.p)

      assert {:error, :invalid_role_set} =
               Identity.create_token(user.id, %{roles: ["PLATFORM_ADMIN"], expires_at: nil},
                 prefix: ctx.p.schema_name
               )
    end
  end

  # --- AC4 read side: stored binding, token row, claim ----------------------------------------

  describe "AC4: stored legacy PLATFORM_ADMIN binding confers nothing" do
    test "403 on every platform route, 403 (not a catch-all) on tenant routes, 403 (not 404) on an unmatched path",
         ctx do
      user = insert_user!(ctx.a)
      group = legacy_platform_admin_binding!(ctx.a)

      assert {:ok, _member} =
               Identity.add_group_member(group.id, user.id, prefix: ctx.a.schema_name)

      # the stored state really is there: reads of stored rows are unchanged ...
      roles = Identity.list_effective_role_names(user.id, prefix: ctx.a.schema_name)
      assert roles == ["PLATFORM_ADMIN"]

      # ... and what a request resolves from it confers nothing
      assert_all_status(platform_specs(), ctx.a, roles, 403)
      assert_all_status(tenant_specs(), ctx.a, roles, 403)

      assert call(Letflow.Routers.Identity, :get, "/no-such-path", ctx.a, roles, nil).status ==
               403
    end

    test "controls: TENANT_ADMIN routes are 200, a mixed list keeps only TENANT_ADMIN, the operator still passes",
         ctx do
      assert_all_status(
        Enum.filter(tenant_specs(), &(elem(&1, 1) == :get)),
        ctx.a,
        ["TENANT_ADMIN"],
        200
      )

      assert_all_status(
        Enum.filter(tenant_specs(), &(elem(&1, 1) == :get)),
        ctx.a,
        ["PLATFORM_ADMIN", "TENANT_ADMIN"],
        200
      )

      assert_all_status(platform_specs(), ctx.a, ["PLATFORM_ADMIN", "TENANT_ADMIN"], 403)

      # platform tenant's own PLATFORM_ADMIN: platform route 200, and the router's 404 pass-through
      assert call(Letflow.Routers.Tenants, :get, "/", ctx.p, ["PLATFORM_ADMIN"], nil).status ==
               200

      assert call(Letflow.Routers.Identity, :get, "/no-such-path", ctx.p, ["PLATFORM_ADMIN"], nil).status ==
               404

      # a TENANT_ADMIN gets 403 on the same unmatched path, in either tenant
      for fixture <- [ctx.a, ctx.p] do
        assert call(
                 Letflow.Routers.Identity,
                 :get,
                 "/no-such-path",
                 fixture,
                 ["TENANT_ADMIN"],
                 nil
               ).status ==
                 403
      end
    end
  end

  describe "AC4: legacy PLATFORM_ADMIN token row is dropped at resolution" do
    test "auth_context.roles never carries it; platform routes and tenant routes are 403; unmatched is 403",
         ctx do
      user = insert_user!(ctx.a)
      plaintext = raw_token!(ctx.a, user, ["PLATFORM_ADMIN"])
      slug = ctx.a.tenant.slug

      for path <- ["/api/v1/tenants", "/api/v1/identity/users", "/api/v1/identity/no-such-path"] do
        resp = Fixture.api_conn(:get, path, plaintext, slug, nil) |> Fixture.dispatch_api()

        assert resp.status == 403, "#{path}: #{resp.status} #{resp.resp_body}"
        assert resp.assigns.auth_context.roles == []
      end
    end

    test "only the PLATFORM_ADMIN entry is dropped: TASK_WORKER and TENANT_ADMIN entries of the same token survive",
         ctx do
      user = insert_user!(ctx.a)
      slug = ctx.a.tenant.slug

      worker = raw_token!(ctx.a, user, ["PLATFORM_ADMIN", "TASK_WORKER"])

      resp =
        Fixture.api_conn(:get, "/api/v1/identity/users", worker, slug, nil)
        |> Fixture.dispatch_api()

      assert resp.assigns.auth_context.roles == ["TASK_WORKER"]
      assert resp.status == 403

      admin = raw_token!(ctx.a, user, ["PLATFORM_ADMIN", "TENANT_ADMIN"])

      resp =
        Fixture.api_conn(:get, "/api/v1/identity/users", admin, slug, nil)
        |> Fixture.dispatch_api()

      assert resp.assigns.auth_context.roles == ["TENANT_ADMIN"]
      assert resp.status == 200

      resp =
        Fixture.api_conn(:get, "/api/v1/tenants", admin, slug, nil) |> Fixture.dispatch_api()

      assert resp.status == 403
    end

    test "control: the platform tenant's PLATFORM_ADMIN token keeps its role and platform scope",
         ctx do
      plaintext = Fixture.mint_token!(ctx.p, ["PLATFORM_ADMIN"])

      resp =
        Fixture.api_conn(:get, "/api/v1/tenants", plaintext, ctx.p.tenant.slug, nil)
        |> Fixture.dispatch_api()

      assert resp.status == 200
      assert resp.assigns.auth_context.roles == ["PLATFORM_ADMIN"]
    end
  end

  describe "AC4: claimed PLATFORM_ADMIN ignored by claim sync (ordinary tenant)" do
    defp claimed(user, roles) do
      %IdentityContext{
        external_user_id: Ecto.UUID.generate(),
        tenant_id: nil,
        realm: "claims-realm-#{Ecto.UUID.generate()}",
        roles: roles,
        email: user.email,
        preferred_username: user.username,
        display_name: user.display_name
      }
    end

    test "with a legacy binding present, a lone claim resolves no group (no membership, marker left nil)",
         ctx do
      assert {:ok, _} = RoleRegistry.seed_default_platform_role_groups(prefix: ctx.a.schema_name)
      legacy_platform_admin_binding!(ctx.a)
      user = insert_user!(ctx.a)

      # the sync logs a warning when a non-empty claim resolves to zero groups
      capture_log(fn ->
        synced =
          Identity.sync_role_claims_from_token(user, claimed(user, ["PLATFORM_ADMIN"]),
            prefix: ctx.a.schema_name
          )

        send(self(), {:synced, synced})
      end)

      assert_received {:synced, %User{role_claims_synced_at: nil}}
      assert Identity.list_effective_role_names(user.id, prefix: ctx.a.schema_name) == []
    end

    test "a claim of PLATFORM_ADMIN + TENANT_ADMIN grants only TENANT_ADMIN", ctx do
      assert {:ok, _} = RoleRegistry.seed_default_platform_role_groups(prefix: ctx.a.schema_name)
      legacy_platform_admin_binding!(ctx.a)
      user = insert_user!(ctx.a)

      synced =
        Identity.sync_role_claims_from_token(
          user,
          claimed(user, ["PLATFORM_ADMIN", "TENANT_ADMIN"]),
          prefix: ctx.a.schema_name
        )

      assert synced.role_claims_synced_at != nil

      assert Identity.list_effective_role_names(user.id, prefix: ctx.a.schema_name) == [
               "TENANT_ADMIN"
             ]
    end

    test "control: in the platform tenant's schema the same claim is honoured", ctx do
      assert {:ok, _} = RoleRegistry.seed_default_platform_role_groups(prefix: ctx.p.schema_name)
      user = insert_user!(ctx.p)

      synced =
        Identity.sync_role_claims_from_token(user, claimed(user, ["PLATFORM_ADMIN"]),
          prefix: ctx.p.schema_name
        )

      assert synced.role_claims_synced_at != nil

      assert Identity.list_effective_role_names(user.id, prefix: ctx.p.schema_name) == [
               "PLATFORM_ADMIN"
             ]
    end
  end

  # --- hand-assigned contexts -----------------------------------------------------------------

  describe "AC4: hand-assigned PLATFORM_ADMIN + TASK_WORKER context (ordinary tenant)" do
    # A hand-assigned context for a SPECIFIC user id (the fixture helper draws a random one).
    defp tasks_conn(path, fixture, user_id, roles) do
      Fixture.router_conn(:get, path, fixture, roles, nil)
      |> Plug.Conn.assign(:auth_context, %{
        user_id: user_id,
        tenant_id: fixture.tenant_id,
        roles: roles
      })
    end

    defp task_ids(path, fixture, user_id, roles) do
      resp =
        Letflow.Routers.Tasks.call(
          tasks_conn(path, fixture, user_id, roles),
          Letflow.Routers.Tasks.init([])
        )

      assert resp.status == 200, "#{path}: #{resp.resp_body}"
      resp.resp_body |> Jason.decode!() |> Map.fetch!("items") |> Enum.map(& &1["id"])
    end

    test "does not get the unfiltered GET /tasks/inbox (or GET /tasks) in an ordinary tenant",
         ctx do
      user_x = insert_user!(ctx.a).id
      user_y = insert_user!(ctx.a).id
      task_x = insert_task!(ctx.a, user_x)
      task_y = insert_task!(ctx.a, user_y)

      for path <- ["/inbox?page_size=50", "/?page_size=50"] do
        ids = task_ids(path, ctx.a, user_x, ["PLATFORM_ADMIN", "TASK_WORKER"])

        assert task_x.id in ids, "#{path}: the caller's own task is visible"

        refute task_y.id in ids,
               "#{path}: a non-platform PLATFORM_ADMIN + TASK_WORKER must stay row-filtered"
      end
    end

    test "control: in the platform tenant the same roles see the whole queue", ctx do
      user_x = insert_user!(ctx.p).id
      user_y = insert_user!(ctx.p).id
      task_x = insert_task!(ctx.p, user_x)
      task_y = insert_task!(ctx.p, user_y)

      for path <- ["/inbox?page_size=50", "/?page_size=50"] do
        ids = task_ids(path, ctx.p, user_x, ["PLATFORM_ADMIN", "TASK_WORKER"])
        assert task_x.id in ids and task_y.id in ids, path
      end
    end
  end

  # --- the :UnmatchedRoute rule ---------------------------------------------------------------

  describe "AC4: the :UnmatchedRoute rule needs platform_tenant? == true" do
    test "a hand-built PLATFORM_ADMIN context with platform_tenant? false is Deny403, with true Allow" do
      assert %{kind: :Deny403} =
               Authorization.evaluate_access(
                 %AccessContext{user_id: "u", roles: [:PLATFORM_ADMIN], platform_tenant?: false},
                 :UnmatchedRoute
               )

      assert %{kind: :Allow} =
               Authorization.evaluate_access(
                 %AccessContext{user_id: "u", roles: [:PLATFORM_ADMIN], platform_tenant?: true},
                 :UnmatchedRoute
               )

      # a default-built context (flag absent) is the false case
      assert %{kind: :Deny403} =
               Authorization.evaluate_access(
                 %AccessContext{user_id: "u", roles: [:PLATFORM_ADMIN]},
                 :UnmatchedRoute
               )
    end
  end

  # --- entities.ex (OQ-10) --------------------------------------------------------------------

  describe "OQ-10: the unredacted-export check gets the recomputed platform flag" do
    test "the platform operator is not refused the unredacted escalation; a TENANT_ADMIN is not either; an ordinary tenant's PLATFORM_ADMIN token is 403 at the route",
         ctx do
      body = %{"unredacted" => true}
      path = "/api/v1/entities/records/no_such_widget/export"

      operator = Fixture.mint_token!(ctx.p, ["PLATFORM_ADMIN"])

      resp =
        Fixture.api_conn(:post, path, operator, ctx.p.tenant.slug, body) |> Fixture.dispatch_api()

      refute resp.resp_body =~ "independently-granted",
             "operator: #{resp.status} #{resp.resp_body}"

      tenant_admin = Fixture.mint_token!(ctx.a, ["TENANT_ADMIN"])

      resp =
        Fixture.api_conn(:post, path, tenant_admin, ctx.a.tenant.slug, body)
        |> Fixture.dispatch_api()

      refute resp.resp_body =~ "independently-granted",
             "tenant admin: #{resp.status} #{resp.resp_body}"

      legacy = raw_token!(ctx.a, insert_user!(ctx.a), ["PLATFORM_ADMIN"])

      resp =
        Fixture.api_conn(:post, path, legacy, ctx.a.tenant.slug, body) |> Fixture.dispatch_api()

      assert resp.status == 403
    end
  end

  # --- the C6 deletion ------------------------------------------------------------------------

  describe "the C6 switch is deleted" do
    test "no function and no application config key remain" do
      Code.ensure_loaded!(Authorization)
      refute function_exported?(Authorization, :tenant_platform_admin_own_tenant_powers?, 0)

      # a value set for the old key is ignored: nothing in the decision reads it
      original = Application.fetch_env(:letflow, :tenant_platform_admin_own_tenant_powers)

      on_exit(fn ->
        case original do
          {:ok, value} ->
            Application.put_env(:letflow, :tenant_platform_admin_own_tenant_powers, value)

          :error ->
            Application.delete_env(:letflow, :tenant_platform_admin_own_tenant_powers)
        end
      end)

      Application.put_env(:letflow, :tenant_platform_admin_own_tenant_powers, true)

      refute Authorization.has_permission_in_scope?([:PLATFORM_ADMIN], :AuditRead, false)
    end

    test "grep contract: neither the function name nor the config key appears in lib/ or config/" do
      files = Path.wildcard("lib/**/*.ex") ++ Path.wildcard("config/**/*.exs")
      assert files != []

      offenders =
        for file <- files,
            {line, number} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
            line =~ "tenant_platform_admin_own_tenant_powers",
            do: "#{file}:#{number}"

      assert offenders == []
    end
  end
end
