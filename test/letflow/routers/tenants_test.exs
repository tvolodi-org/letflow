defmodule Letflow.Routers.TenantsTest do
  @moduledoc """
  Tests for `Letflow.Routers.Tenants` (REQ-075) — the six tenant-administration
  handlers. See `lib/letflow/design/req075-tenant-administration-routes.md`
  §3/§4.3/§5/§6/§7.1 for the test-case rationale this file implements directly.

  Uses `Letflow.DataCase` (real Postgres, per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1) and `Letflow.TenantFixture` for real provisioned tenant schemas.
  `async: false` — tenant provisioning/migration replay needs
  `Sandbox.mode(Letflow.Repo, :auto)`, matching `test/letflow/routers/identity_test.exs`'s
  own established pattern for this class of test.

  Dispatch is direct `Letflow.Routers.Tenants.call/2` with `conn.assigns[:auth_context]`
  set directly (bypassing the full `Letflow.Router` -> `Letflow.Plugs.ApiPipeline` ->
  `AuthPipeline` chain) — this router's own `with_authorization/4` preamble reads
  `conn.assigns.auth_context` directly, so nothing about the handlers under test depends
  on how that assign got populated. `Letflow.Plugs.TenantStatus`'s own REQ-075 AC5
  behavior (a plug mounted ABOVE this router, not inside it) is tested separately in
  `test/letflow/plugs/tenant_status_test.exs` — dispatching through this router alone
  would never invoke that plug at all.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query, only: [from: 2]

  alias Letflow.Admission
  alias Letflow.Identity.Tenant
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Test.SandboxAutoMode
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @opts Letflow.Routers.Tenants.init([])

  # ── Shared test dispatch helper ─────────────────────────────────────────

  # `tenant_fixture` may be `nil` (the caller's own tenant identity is irrelevant to
  # this router's authorization -- only `roles` matters, per the design's pure-role
  # gate, §7.1's own note on this exact point).
  defp build_conn(method, path, tenant_fixture, fields) do
    roles = Keyword.get(fields, :roles, [])
    body = Keyword.get(fields, :body, nil)

    conn = conn(method, path)

    conn =
      if body do
        %{conn | body_params: body}
        |> put_req_header("content-type", "application/json")
      else
        conn
      end

    tenant_id = if tenant_fixture, do: tenant_fixture.tenant_id, else: Ecto.UUID.generate()

    # ISS-0993 (A2): the registry routes are PLATFORM scope, honoured only for a
    # PLATFORM_ADMIN of the configured platform tenant. A request built here with
    # PLATFORM_ADMIN is therefore the platform operator's: pin the caller's own
    # tenant as the platform tenant (restored by the fixture's on_exit). The
    # tenant-admin denial is covered by the platform-scope test files.
    if "PLATFORM_ADMIN" in roles, do: PlatformTenantFixture.pin!(tenant_id)

    conn
    |> assign(:auth_context, %{user_id: Ecto.UUID.generate(), tenant_id: tenant_id, roles: roles})
    |> assign(:trace_id, "fixed-test-trace-id")
  end

  defp dispatch(conn), do: Letflow.Routers.Tenants.call(conn, @opts)

  # ── AC1: full-body 403 for a non-PLATFORM_ADMIN caller, zero tenant data ───

  describe "AC1: GET /tenants as a non-PLATFORM_ADMIN caller" do
    setup do
      %{
        tenant: TenantFixture.provisioned_tenant!(slug_prefix: "req075-list-403"),
        other: TenantFixture.provisioned_tenant!(slug_prefix: "req075-list-403-other")
      }
    end

    test "returns 403 and no tenant data whatsoever, full-body assertion", %{
      tenant: tenant,
      other: other
    } do
      resp = build_conn(:get, "/", tenant, roles: ["PROCESS_DESIGNER"]) |> dispatch()

      assert resp.status == 403

      assert Jason.decode!(resp.resp_body) == %{
               "type" => "https://bpm.example.com/problems/forbidden",
               "title" => "Forbidden",
               "status" => 403,
               "detail" => "insufficient permissions",
               "trace_id" => "fixed-test-trace-id"
             }

      refute resp.resp_body =~ other.tenant.slug
      refute resp.resp_body =~ "items"
      refute resp.resp_body =~ "count"
    end
  end

  # ── AC2: cross-tenant rejection, four verbs, row unchanged ──────────────

  describe "AC2: cross-tenant rejection on all four write/read verbs, row unchanged" do
    setup do
      %{
        tenant_a: TenantFixture.provisioned_tenant!(slug_prefix: "req075-cross-a"),
        tenant_b: TenantFixture.provisioned_tenant!(slug_prefix: "req075-cross-b")
      }
    end

    test "GET /tenants/:slug on another tenant's record is rejected, row unchanged", %{
      tenant_a: tenant_a,
      tenant_b: tenant_b
    } do
      before = Repo.get!(Tenant, tenant_b.tenant_id)

      resp =
        build_conn(:get, "/#{tenant_b.tenant.slug}", tenant_a, roles: ["PROCESS_DESIGNER"])
        |> dispatch()

      assert resp.status == 403
      assert Repo.get!(Tenant, tenant_b.tenant_id) == before
    end

    test "PATCH /tenants/:slug on another tenant's record is rejected, row unchanged despite a well-formed body",
         %{tenant_a: tenant_a, tenant_b: tenant_b} do
      before = Repo.get!(Tenant, tenant_b.tenant_id)

      resp =
        build_conn(:patch, "/#{tenant_b.tenant.slug}", tenant_a,
          roles: ["PROCESS_DESIGNER"],
          body: %{"display_name" => "Hijacked"}
        )
        |> dispatch()

      assert resp.status == 403
      assert Repo.get!(Tenant, tenant_b.tenant_id) == before
    end

    test "POST /tenants/:slug/deactivate on another tenant's record is rejected, row unchanged",
         %{tenant_a: tenant_a, tenant_b: tenant_b} do
      before = Repo.get!(Tenant, tenant_b.tenant_id)

      resp =
        build_conn(:post, "/#{tenant_b.tenant.slug}/deactivate", tenant_a,
          roles: ["PROCESS_DESIGNER"]
        )
        |> dispatch()

      assert resp.status == 403
      assert Repo.get!(Tenant, tenant_b.tenant_id) == before
    end

    test "POST /tenants/:slug/reactivate on another (pre-deactivated) tenant's record is rejected, status unchanged",
         %{tenant_a: tenant_a, tenant_b: tenant_b} do
      tenant_b.tenant |> Tenant.status_changeset(%{status: :inactive}) |> Repo.update!()

      resp =
        build_conn(:post, "/#{tenant_b.tenant.slug}/reactivate", tenant_a,
          roles: ["PROCESS_DESIGNER"]
        )
        |> dispatch()

      assert resp.status == 403
      assert Repo.get!(Tenant, tenant_b.tenant_id).status == :inactive
    end
  end

  # ── AC3: own-tenant access rule, both directions ────────────────────────

  describe "AC3: own-tenant access is not a carve-out" do
    test "PLATFORM_ADMIN can GET/PATCH their own home tenant's record, same as any other" do
      admin_tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req075-own-admin")

      get_resp =
        build_conn(:get, "/#{admin_tenant.tenant.slug}", admin_tenant, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert get_resp.status == 200

      patch_resp =
        build_conn(:patch, "/#{admin_tenant.tenant.slug}", admin_tenant,
          roles: ["PLATFORM_ADMIN"],
          body: %{"display_name" => "Renamed By Self"}
        )
        |> dispatch()

      assert patch_resp.status == 200
      assert Jason.decode!(patch_resp.resp_body)["display_name"] == "Renamed By Self"
    end

    test "a non-PLATFORM_ADMIN caller is denied GET/PATCH on their OWN home tenant's record" do
      own_tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req075-own-denied")
      before = Repo.get!(Tenant, own_tenant.tenant_id)

      get_resp =
        build_conn(:get, "/#{own_tenant.tenant.slug}", own_tenant, roles: ["PROCESS_DESIGNER"])
        |> dispatch()

      assert get_resp.status == 403

      patch_resp =
        build_conn(:patch, "/#{own_tenant.tenant.slug}", own_tenant,
          roles: ["PROCESS_DESIGNER"],
          body: %{"display_name" => "Should Not Apply"}
        )
        |> dispatch()

      assert patch_resp.status == 403
      assert Repo.get!(Tenant, own_tenant.tenant_id) == before
    end
  end

  # ── GET /tenants/:slug, PATCH /tenants/:slug — PLATFORM_ADMIN happy paths ──

  describe "GET /tenants/:slug as PLATFORM_ADMIN" do
    test "returns the allowlisted 8-key shape" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req075-get")

      resp =
        build_conn(:get, "/#{tenant.tenant.slug}", tenant, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)

      assert Map.keys(body) |> Enum.sort() ==
               Enum.sort([
                 "id",
                 "slug",
                 "display_name",
                 "status",
                 "login_disclosure_mode",
                 "tenant_type",
                 "inserted_at",
                 "updated_at"
               ])

      assert body["slug"] == tenant.tenant.slug
      assert body["status"] == "active"
    end

    test "a non-existent slug is 404" do
      resp =
        build_conn(:get, "/does-not-exist-#{Ecto.UUID.generate()}", nil,
          roles: ["PLATFORM_ADMIN"]
        )
        |> dispatch()

      assert resp.status == 404
    end
  end

  describe "PATCH /tenants/:slug as PLATFORM_ADMIN" do
    test "updates display_name only -- a status key in the body is silently dropped, never applied" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req075-patch")

      resp =
        build_conn(:patch, "/#{tenant.tenant.slug}", tenant,
          roles: ["PLATFORM_ADMIN"],
          body: %{"display_name" => "New Name", "status" => "inactive"}
        )
        |> dispatch()

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["display_name"] == "New Name"
      # status structurally cannot be written via PATCH -- still :active.
      assert body["status"] == "active"
      assert Repo.get!(Tenant, tenant.tenant_id).status == :active
    end

    # GH #3252 / REQ-572: deactivation stops the tenant's realm key provider.
    test "deactivate stops the tenant's running realm provider" do
      realm = "t3252-" <> Integer.to_string(System.unique_integer([:positive]))
      %{base_url: base_url} = Letflow.Support.MockOidcProvider.start([realm])
      original = Application.fetch_env!(:letflow, :oidc)

      Application.put_env(
        :letflow,
        :oidc,
        Keyword.merge(original, keycloak_base_url: base_url)
      )

      on_exit(fn -> Application.put_env(:letflow, :oidc, original) end)

      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh3252-stop")
      operator = TenantFixture.provisioned_tenant!(slug_prefix: "gh3252-stop-op")

      Repo.update_all(from(t in Tenant, where: t.id == ^tenant.tenant_id),
        set: [idp_realm_id: realm]
      )

      assert {:ok, _via} = Letflow.Oidc.ProviderRegistry.ensure_started(realm)
      assert [{pid, _}] = Registry.lookup(Letflow.Registry, {:oidc_provider, realm})
      ref = Process.monitor(pid)

      resp =
        build_conn(:post, "/#{tenant.tenant.slug}/deactivate", operator,
          roles: ["PLATFORM_ADMIN"]
        )
        |> dispatch()

      assert resp.status == 200
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      # Registry removes the key asynchronously after the process dies.
      deadline = System.monotonic_time(:millisecond) + 2_000

      wait_unregistered = fn wait ->
        cond do
          Registry.lookup(Letflow.Registry, {:oidc_provider, realm}) == [] ->
            :ok

          System.monotonic_time(:millisecond) >= deadline ->
            flunk("realm provider key still registered 2s after the process went DOWN")

          true ->
            Process.sleep(10)
            wait.(wait)
        end
      end

      wait_unregistered.(wait_unregistered)
    end

    test "an empty display_name is rejected 422" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req075-patch-empty")

      resp =
        build_conn(:patch, "/#{tenant.tenant.slug}", tenant,
          roles: ["PLATFORM_ADMIN"],
          body: %{"display_name" => ""}
        )
        |> dispatch()

      assert resp.status == 422
    end
  end

  # ── POST /tenants/:slug/deactivate, /reactivate ─────────────────────────

  describe "deactivate/reactivate as PLATFORM_ADMIN" do
    test "deactivate sets status to :inactive, reactivate sets it back to :active" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req075-lifecycle")
      operator = TenantFixture.provisioned_tenant!(slug_prefix: "req075-lifecycle-op")

      deactivate_resp =
        build_conn(:post, "/#{tenant.tenant.slug}/deactivate", operator,
          roles: ["PLATFORM_ADMIN"]
        )
        |> dispatch()

      assert deactivate_resp.status == 200
      assert Jason.decode!(deactivate_resp.resp_body)["status"] == "inactive"
      assert Repo.get!(Tenant, tenant.tenant_id).status == :inactive

      reactivate_resp =
        build_conn(:post, "/#{tenant.tenant.slug}/reactivate", operator,
          roles: ["PLATFORM_ADMIN"]
        )
        |> dispatch()

      assert reactivate_resp.status == 200
      assert Jason.decode!(reactivate_resp.resp_body)["status"] == "active"
      assert Repo.get!(Tenant, tenant.tenant_id).status == :active
    end

    # OQ-2: re-deactivating an already-:inactive tenant is a no-op success, not
    # :invalid_transition.
    test "re-deactivating an already-:inactive tenant is an idempotent no-op success" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req075-idempotent")
      operator = TenantFixture.provisioned_tenant!(slug_prefix: "req075-idempotent-op")
      tenant.tenant |> Tenant.status_changeset(%{status: :inactive}) |> Repo.update!()

      resp =
        build_conn(:post, "/#{tenant.tenant.slug}/deactivate", operator,
          roles: ["PLATFORM_ADMIN"]
        )
        |> dispatch()

      assert resp.status == 200
      assert Jason.decode!(resp.resp_body)["status"] == "inactive"
    end

    test "deactivate/reactivate on a non-existent slug is 404" do
      resp =
        build_conn(:post, "/does-not-exist-#{Ecto.UUID.generate()}/deactivate", nil,
          roles: ["PLATFORM_ADMIN"]
        )
        |> dispatch()

      assert resp.status == 404
    end

    # ISS-0437: confirms Letflow.Admission.forget_tenant/1 is actually invoked
    # on a successful deactivation. Per
    # lib/letflow/design/iss0437-admission-tenant-eviction.md §6/§7, this
    # router handler has no `server` seam to substitute an isolated test
    # instance, so this exercises the REAL, application-supervised
    # `Letflow.Admission` singleton -- safe here because this module is
    # already `async: false` (line 23) and every `async: false` module runs
    # sequentially, one at a time (matching `test/letflow/plugs/admission_test.exs`'s
    # own documented convention for the same singleton). This test only
    # tracks a schema unique to its own freshly-provisioned tenant fixture,
    # so it cannot corrupt another test's counters.
    test "deactivate evicts the tenant's Admission entry (forget_tenant/1 is invoked)" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req075-admission-evict")
      operator = TenantFixture.provisioned_tenant!(slug_prefix: "req075-admission-evict-op")
      {:ok, schema} = TenantProvisioning.schema_name_for_tenant(tenant.tenant_id)

      # establish tracking on the real singleton for this schema
      assert {:ok, ref} = Admission.try_acquire({:tenant, schema})
      assert Map.has_key?(:sys.get_state(Admission).tenants, schema)

      resp =
        build_conn(:post, "/#{tenant.tenant.slug}/deactivate", operator,
          roles: ["PLATFORM_ADMIN"]
        )
        |> dispatch()

      assert resp.status == 200

      # forget_tenant/1 evicted this schema's entry
      refute Map.has_key?(:sys.get_state(Admission).tenants, schema)

      # the still-live, pre-eviction ref remains safely releasable (no raise)
      assert :ok = Admission.release(ref)
    end
  end

  # ── GET /tenants as PLATFORM_ADMIN ───────────────────────────────────────

  describe "GET /tenants as PLATFORM_ADMIN" do
    test "lists tenants in the paginated allowlisted shape" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req075-list-ok")

      resp =
        build_conn(:get, "/?search=#{tenant.tenant.slug}", tenant, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert is_list(body["items"])
      assert is_integer(body["count"])
      assert Enum.any?(body["items"], &(&1["slug"] == tenant.tenant.slug))
    end

    test "search filters by slug/display_name substring" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req075-search-match")

      resp =
        build_conn(:get, "/?search=req075-search-match", tenant, roles: ["PLATFORM_ADMIN"])
        |> dispatch()

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert Enum.all?(body["items"], &String.contains?(&1["slug"], "req075-search-match"))
    end
  end

  # ── AC4/AC7: POST /tenants full orchestration ───────────────────────────

  describe "AC4/AC7: POST /tenants as PLATFORM_ADMIN" do
    test "creates a tenant row, provisions a real schema, and replays real migrations" do
      # Real schema creation (CREATE SCHEMA) + migration replay needs :auto sandbox
      # mode, same as Letflow.TenantFixture.provisioned_tenant!/1 -- DDL run under
      # the default per-test :manual/:shared sandbox transaction is not reliably
      # visible to Ecto.Migrator.run/4's own connection checkout.
      SandboxAutoMode.provision!(Letflow.Repo, fn ->
        slug = "req075-create-e2e-#{Ecto.UUID.generate()}"

        resp =
          build_conn(:post, "/", nil,
            roles: ["PLATFORM_ADMIN"],
            body: %{"slug" => slug, "display_name" => "Create E2E"}
          )
          |> dispatch()

        assert resp.status == 201
        body = Jason.decode!(resp.resp_body)
        assert body["slug"] == slug
        tenant_id = body["id"]

        on_exit(fn ->
          SandboxAutoMode.enter_auto_mode!(Letflow.Repo)

          case TenantProvisioning.schema_name_for_tenant(tenant_id) do
            {:ok, schema_name} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
            {:error, :invalid_tenant_id} -> :ok
          end

          Repo.delete_all(
            from(r in TenantProvisioning.Registration, where: r.tenant_id == ^tenant_id)
          )

          Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))
        end)

        {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(tenant_id)

        # AC4's own wording: "querying information_schema for a table in the new
        # schema -- not by trusting the 201." `events` is tenant_scoped_migrations/0's
        # first manifest entry.
        %{rows: rows} =
          Repo.query!(
            "SELECT table_name FROM information_schema.tables WHERE table_schema = $1 AND table_name = 'events'",
            [schema_name]
          )

        assert rows != []
      end)
    end

    test "a duplicate slug is rejected 409" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req075-dup")

      resp =
        build_conn(:post, "/", nil,
          roles: ["PLATFORM_ADMIN"],
          body: %{"slug" => tenant.tenant.slug, "display_name" => "Duplicate"}
        )
        |> dispatch()

      assert resp.status == 409
    end

    test "a missing required field is rejected 422" do
      resp =
        build_conn(:post, "/", nil, roles: ["PLATFORM_ADMIN"], body: %{"slug" => "no-name"})
        |> dispatch()

      assert resp.status == 422
    end
  end

  describe "POST /tenants as a non-PLATFORM_ADMIN caller" do
    test "is rejected 403 before any Repo call -- no row created" do
      slug = "req075-create-denied-#{Ecto.UUID.generate()}"

      resp =
        build_conn(:post, "/", nil,
          roles: ["PROCESS_DESIGNER"],
          body: %{"slug" => slug, "display_name" => "Should Not Be Created"}
        )
        |> dispatch()

      assert resp.status == 403
      refute Repo.get_by(Tenant, slug: slug)
    end
  end
end

defmodule Letflow.Routers.TenantsIss0705SandboxModeRegressionTest do
  @moduledoc """
  ISS-0705 regression test. See `test/specs/ISS-0705.md` for the full design
  rationale, including a documented empirical finding from designing this test
  that changed its shape: a black-box probe comparing the true pre-ISS-0705
  commit against the fixed tip (both wrapped in `Letflow.DataCase`'s own
  `{:shared, self()}`-tracked setup) turned out to behave IDENTICALLY in both
  cases, because `DBConnection.Ownership` has its own built-in safety net —
  "a connection's mode reverts to :manual if its owner terminates" (the exact
  wording `DBConnection.OwnershipError` itself reports) — that silently
  papers over a leaked `:auto` flip once the owning (`{:shared, self()}`)
  process exits, for ANY test using `Letflow.DataCase`'s standard setup.
  That finding is *why* this test targets the actual, still-real hazard
  underneath instead: the fix's own on_exit/1 callback — registered from
  *inside* `SandboxAutoMode.provision!/2`'s wrapped function, so it runs in a
  separate `ExUnit.OnExitHandler` process, after `provision!/2`'s own
  synchronous restore (mode `:manual` + a fresh checkout for the now-finished
  test process) has already run and is already stale — must re-enter `:auto`
  mode ITSELF (`SandboxAutoMode.enter_auto_mode!/1`) before making its own
  `Letflow.Repo` calls, or those calls raise `DBConnection.OwnershipError`.
  This is not a theoretical trap: ELIXIR-DEV's own WF03-ISS0705-20260917 Step 3
  attempt hit exactly this crash for real
  (`handoffs/WF03-ISS0705-20260917/step-03-elixir-dev.json`), which is what
  rework-1 (commit `5a8da536`) added the `enter_auto_mode!/1` line to fix.

  This test reproduces that exact shape directly — `SandboxAutoMode.provision!/2`
  wrapping a real `Letflow.Repo` write, with an `on_exit/1` registered from
  inside the wrapped function that itself needs `Letflow.Repo` — rather than
  depending on `Letflow.Routers.TenantsTest`'s own test or any cross-test
  ordering, so it is self-contained and needs no special `mix test` invocation.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.Test.SandboxAutoMode

  test "ISS-0705 regression: an on_exit/1 callback registered inside " <>
         "SandboxAutoMode.provision!/2 can still reach Letflow.Repo for its own cleanup" do
    tenant_id =
      SandboxAutoMode.provision!(Letflow.Repo, fn ->
        tenant =
          Tenant.create_changeset(
            %Tenant{},
            %{
              slug: "iss0705-regress-#{Ecto.UUID.generate()}",
              display_name: "ISS-0705 regression probe"
            },
            :disabled
          )
          |> Repo.insert!()

        on_exit(fn ->
          # This is the ISS-0705 fix itself: without re-entering :auto mode
          # here, this callback's own Repo.delete_all/1 below raises
          # DBConnection.OwnershipError -- provision!/2's own `after`-block
          # restore (mode :manual + a fresh checkout) already ran, synchronously,
          # for the ORIGINAL test process, the instant the wrapped fn above
          # returned -- well before this on_exit/1 callback runs, in a
          # SEPARATE OnExitHandler process, after that original process has
          # already exited. Comment this line out to see the regression: it
          # reproduces the exact DBConnection.OwnershipError ELIXIR-DEV's own
          # Step 3 attempt hit (step-03-elixir-dev.json).
          SandboxAutoMode.enter_auto_mode!(Letflow.Repo)

          Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
        end)

        tenant.id
      end)

    assert is_binary(tenant_id)
  end
end
