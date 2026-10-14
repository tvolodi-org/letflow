defmodule Letflow.Routers.ModulesTest do
  @moduledoc """
  Tests for `Letflow.Routers.Modules` (REQ-404) — the D4/D5 module-router
  dispatch mount. See `lib/letflow/design/req404-module-router-mount.md`
  §4.2 for the full design these tests implement. ELIXIR-DEV inline
  coverage (this project's established convention when the design is fully
  specified — no separate TEST-DESIGNER dispatch).

  Covers AC1 (404 before any permission check, every role that can hold a
  token in an ordinary tenant -- REQ-447 PR 2: a PLATFORM_ADMIN token can no
  longer be minted outside the platform tenant, so TENANT_ADMIN is the
  tenant-admin identity), AC2 (200/403 split once installed, via the fixture's own
  `role_grants`), AC3 (byte-identical 404 body for an unknown module id vs
  an uninstalled known module), AC4 (two-tenant install isolation — still
  404, not 403, for a tenant that never installed it).

  ## Full-pipeline dispatch, not the router in isolation

  Dispatched via `Letflow.Router.call/2` with a real
  `Authorization: Bearer lf_tok_...` + `X-Tenant-Slug` credential, mirroring
  `test/letflow/routers/entities_test.exs`'s own established convention --
  so `AuthPipeline -> TenantStatus -> Letflow.Routers.Modules -> (module's
  own) Authorize` genuinely all run. A preset `:scoped_opts` would prove
  nothing about the real dispatch path.

  `async: false` — `TenantFixture.provisioned_tenant!/1` switches the
  sandbox to global `:auto` mode (matching `tenant_modules_test.exs`'s own
  justification).
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Api.Authorization
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.Modules.Fixture
  alias Letflow.Modules.Installs
  alias Letflow.TenantFixture

  # ── Full-pipeline dispatch ─────────────────────────────────────────────

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp request(method, path, ctx, trace_id \\ nil) do
    conn(method, path)
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> maybe_pin_trace_id(trace_id)
    |> dispatch()
  end

  # AC3's byte-identity assertion compares resp_body across two SEPARATE
  # requests; Letflow.Api.Error's trace_id is per-request correlation data,
  # not per-resource information, so it must be pinned to the same value
  # across the pair being compared -- otherwise every 404 would differ by
  # trace_id alone and the comparison would prove nothing. Mirrors
  # test/letflow/routers/entities_test.exs's own established convention.
  defp maybe_pin_trace_id(conn, nil), do: conn
  defp maybe_pin_trace_id(conn, trace_id), do: put_req_header(conn, "x-trace-id", trace_id)

  # ── Fixtures ───────────────────────────────────────────────────────────

  defp insert_user!(schema_name) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "req404-user-#{Ecto.UUID.generate()}",
      display_name: "REQ-404 Modules Router Test User",
      email: "req404-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema_name)
  end

  defp tenant_ctx(slug_prefix) do
    tenant =
      TenantFixture.provisioned_tenant!(
        slug_prefix: slug_prefix,
        display_name: "REQ-404 Modules Router Test Tenant"
      )

    %{tenant_id: tenant.tenant_id, schema_name: tenant.schema_name, slug: tenant.tenant.slug}
  end

  defp token_for(ctx, role) do
    user = insert_user!(ctx.schema_name)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: [Atom.to_string(role)], expires_at: nil},
        prefix: ctx.schema_name
      )

    Map.merge(ctx, %{plaintext: plaintext, user_id: user.id})
  end

  defp install_fixture!(ctx) do
    {:ok, _tenant_module} =
      Installs.install("fixture", Ecto.UUID.generate(),
        prefix: ctx.schema_name,
        rationale: "test: module install"
      )

    ctx
  end

  # Attaches a `:telemetry` handler to Ecto's own `[:letflow, :repo, :query]`
  # event (same attach convention as
  # `test/letflow/plugs/http_metrics_test.exs`) and counts how many queries
  # against the `tenant_modules` table `fun.()` triggers -- used by the
  # INV-5 timing-parity regression test below to assert
  # `Installs.installed?/2` actually ran, not merely that the response body
  # looks right.
  defp count_tenant_modules_queries(fun) do
    test_pid = self()
    handler_id = "req404-inv5-query-count-#{System.unique_integer([:positive, :monotonic])}"

    :telemetry.attach(
      handler_id,
      [:letflow, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if metadata.source == "tenant_modules" do
          send(test_pid, :tenant_modules_query)
        end
      end,
      nil
    )

    result = fun.()
    Process.sleep(20)
    :telemetry.detach(handler_id)

    count =
      Stream.repeatedly(fn ->
        receive do
          :tenant_modules_query -> :hit
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(&(&1 != nil))
      |> length()

    {result, count}
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC1 — 404 for every mintable role, including TENANT_ADMIN, when not installed
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC1 -- 404 for every role when the fixture is not installed, before any permission check" do
    test "GET /api/v1/modules/fixture/items/42 is 404 for every role in Authorization.roles/0" do
      ctx = tenant_ctx("req404-ac1")

      # REQ-447 PR 2: `Identity.create_token/3` refuses a PLATFORM_ADMIN token in an ordinary
      # tenant (`:invalid_role_set`), so it is excluded from the minting loop; TENANT_ADMIN stays.
      for role <- Authorization.roles(), role != :PLATFORM_ADMIN do
        role_ctx = token_for(ctx, role)

        conn = request(:get, "/api/v1/modules/fixture/items/42", role_ctx)

        assert conn.status == 404,
               "expected 404 for role #{inspect(role)}, got #{conn.status}"
      end
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC2 — 200/403 split once installed, driven by the fixture's own
  # role_grants
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC2 -- 200 for the fixture's own granted role, 403 for a role it doesn't grant, once installed" do
    test "200 with the fixture body for a role_grants role, 403 for a role not granted" do
      ctx = tenant_ctx("req404-ac2") |> install_fixture!()

      [granted_role | _rest] = Map.keys(Fixture.manifest().role_grants)
      granted_ctx = token_for(ctx, granted_role)

      granted_conn = request(:get, "/api/v1/modules/fixture/items/42", granted_ctx)

      assert granted_conn.status == 200
      assert Jason.decode!(granted_conn.resp_body) == %{"fixture" => true, "id" => "42"}

      # PLATFORM_ADMIN (cannot be minted in an ordinary tenant, REQ-447 PR 2) and
      # TENANT_ADMIN (holds every tenant-scope permission) must be excluded here --
      # this needs a role the fixture's own role_grants does NOT name AND whose
      # core matrix does not separately grant :FixtureRead.
      ungranted_role =
        Enum.find(Authorization.roles(), fn role ->
          role not in [:PLATFORM_ADMIN, :TENANT_ADMIN] and
            role not in Map.keys(Fixture.manifest().role_grants)
        end)

      ungranted_ctx = token_for(ctx, ungranted_role)

      ungranted_conn = request(:get, "/api/v1/modules/fixture/items/42", ungranted_ctx)

      assert ungranted_conn.status == 403
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC3 — byte-identical 404 body for an unknown module id vs an
  # uninstalled known module
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC3 -- 404 body is byte-identical regardless of which branch produced it" do
    test "unknown module id and uninstalled known module produce the exact same resp_body" do
      ctx = tenant_ctx("req404-ac3")
      role_ctx = token_for(ctx, :TENANT_ADMIN)

      trace_id = "req404-ac3-shared-trace-id"

      unknown_conn = request(:get, "/api/v1/modules/does-not-exist/anything", role_ctx, trace_id)
      uninstalled_conn = request(:get, "/api/v1/modules/fixture/items/42", role_ctx, trace_id)

      assert unknown_conn.status == 404
      assert uninstalled_conn.status == 404
      assert unknown_conn.resp_body == uninstalled_conn.resp_body
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC4 — two-tenant isolation: installing into A doesn't leak into B
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC4 -- installing the fixture into tenant A does not make it reachable for tenant B" do
    test "tenant B's TASK_WORKER still gets 404, not 403, after tenant A installs the fixture" do
      _ctx_a = tenant_ctx("req404-ac4-a") |> install_fixture!()
      ctx_b = tenant_ctx("req404-ac4-b")

      role_ctx_b = token_for(ctx_b, :TASK_WORKER)

      conn = request(:get, "/api/v1/modules/fixture/items/42", role_ctx_b)

      assert conn.status == 404
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # INV-5 timing-parity regression guard (design §9.7 -- amendment closing
  # a SECURITY-REVIEWER BLOCKER, commit 31fc03d6 -> follow-up fix).
  #
  # Plain response-body/status assertions (AC1/AC3 above) cannot catch a
  # regression back to a short-circuiting `with`-chain: both the fixed and
  # the broken code return byte-identical 404s for these two requests, the
  # ONLY observable difference is whether Installs.installed?/2's
  # `tenant_modules` query actually ran. This asserts on that directly, via
  # `:telemetry.attach/4` on Ecto's own `[:letflow, :repo, :query]` event
  # (same test-handler-attach convention as
  # `test/letflow/plugs/http_metrics_test.exs`) -- counting query events
  # whose `metadata.source == "tenant_modules"` for BOTH an unknown module
  # id and a known-but-uninstalled module id. If `gate/2`'s `resolve/2`
  # ever regresses to short-circuiting the DB check behind the free
  # catalog/router-export checks (design §9.4), the unknown-module-id case
  # would drop to zero `tenant_modules` queries while the known-uninstalled
  # case stays at one -- this test fails on that asymmetry even though
  # both requests would still return the same 404 body.
  # ═══════════════════════════════════════════════════════════════════════

  describe "INV-5 timing parity -- Installs.installed?/2 runs unconditionally, not short-circuited by the free catalog checks" do
    test "an unknown module id still pays exactly one tenant_modules query, same as a known-uninstalled id" do
      ctx = tenant_ctx("req404-inv5")
      role_ctx = token_for(ctx, :TENANT_ADMIN)

      {unknown_conn, unknown_count} =
        count_tenant_modules_queries(fn ->
          request(:get, "/api/v1/modules/does-not-exist/anything", role_ctx)
        end)

      {uninstalled_conn, uninstalled_count} =
        count_tenant_modules_queries(fn ->
          request(:get, "/api/v1/modules/fixture/items/42", role_ctx)
        end)

      assert unknown_conn.status == 404
      assert uninstalled_conn.status == 404

      assert unknown_count == 1,
             "expected exactly 1 tenant_modules query for an unknown module id " <>
               "(Installs.installed?/2 must run unconditionally, design §9.2/§9.3), got #{unknown_count}"

      assert uninstalled_count == 1,
             "expected exactly 1 tenant_modules query for a known-uninstalled module id, got #{uninstalled_count}"

      assert unknown_count == uninstalled_count,
             "DB round-trip count must be identical across both branches (INV-5 timing parity)"
    end
  end
end
