defmodule Letflow.Plugs.CorsTest do
  @moduledoc """
  Tests for `Letflow.Plugs.Cors` (REQ-118, `test/specs/REQ-118.md`).

  Router-level end-to-end tests via `Plug.Test`, dispatched through
  `Letflow.Router.call/2` — NOT `Letflow.Plugs.Cors.call/2` in isolation. This
  matches `test/letflow/router_test.exs`'s established convention (AC4 requires this
  explicitly: "a test exercises a cross-origin request end-to-end through the
  router"), and lives in its own file (rather than appended to `router_test.exs`)
  because `Letflow.Plugs.Cors` is cross-cutting middleware with its own focused set of
  cases, matching `test/letflow/plugs/tenant_status_test.exs`'s precedent of a
  dedicated per-plug test file that still exercises the plug through real dispatch.

  `Letflow.Plugs.Cors` itself reads only `Application.get_env/3` and the request's
  headers, but the `/api/tenant-config` requests below reach the route handler, which
  looks up the default-realm tenant in Postgres. `Letflow.DataCase` gives each test its
  own sandbox connection. Without it, that lookup used whatever sandbox mode the
  previous sync module left behind: right after a `DataCase` sync module, the shared
  owner can still be registered while it exits, and the lookup then exits with
  "owner #PID<...> exited", which `Identity.safe_get_tenant_by_slug/2` does not rescue
  (GH #2380 step 2, CI shard 4/4, partition 16, after `Letflow.EventStore.MigrationsTest`).

  Design reference: `lib/letflow/design/req118-cors.md`, especially §0.5 (rejection
  is "omit the header," never a distinct HTTP status) and §1 (the exact header-value
  table this file's assertions are pinned to).

  T-2621 (the per-host rule): the allow decision is taken PER HOST, so an origin is
  allowed only when it is one of the app's own fixed origins or when it IS the host
  the request is addressed to. The hosts, the pairs and the expected answers below are
  the QA topology of the infra baseline that found the defect
  (`ai-dala-infra/runs/2026-11-22-qa-mail-adapter-001/cors-failing-pairs.md`): the
  two failing pairs of that baseline are reproduced verbatim, and every refusal is
  compared with the answer for an origin the app knows nothing about (the "uniform
  refusal" the requirement asks for: same status, same body, no allow-origin, no
  oracle on whether the other company exists).
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  @opts Letflow.Router.init([])

  @allowed_origin "http://localhost:5173"
  @other_allowed_origin "http://127.0.0.1:4173"
  @unlisted_origin "http://evil.example.com"
  # ISS-0529 regression pins: localhost:4173 was missing and 127.0.0.1:5173
  # was missing; both must stay in @default_origins.
  @iss0529_origin_a "http://localhost:4173"
  @iss0529_origin_b "http://127.0.0.1:5173"

  # ── the QA topology of the infra baseline (2026-11-22) ──────────────────────
  @tenant_host "sss-rehearsal2.letflow.qa.bizdala.com"
  @other_tenant_host "qoimeks-qa2.letflow.qa.bizdala.com"
  @third_tenant_host "qoimeks-qa.letflow.qa.bizdala.com"
  @tenant_host_other_suffix "sss-rehearsal2.qa.ai-letflow.com"
  @other_tenant_host_other_suffix "qoimeks-qa2.qa.ai-letflow.com"
  @platform_host "qa.bizdala.com"
  @pwa_host "pwa.letflow.qa.bizdala.com"

  # The app's own fixed origins, as QA has them (CORS_ALLOWED_ORIGINS): the
  # platform host and the host the PWA is served from.
  @fixed_origins ["https://qa.bizdala.com", "https://pwa.letflow.qa.bizdala.com"]

  # The guarded suffix policy of QA (LETFLOW_PROVISIONER_ALLOWED_HOSTNAME_SUFFIXES).
  @suffixes ["qa.ai-letflow.com", "letflow.qa.bizdala.com"]

  defp call(conn), do: Letflow.Router.call(conn, @opts)

  # ── AC1 + AC4: matched-origin actual request, dispatched through the router ──

  describe "AC1 + AC4: matched-origin cross-origin GET through Letflow.Router" do
    test "GET /api/tenant-config with an allowed Origin gets access-control-allow-origin echoed back" do
      conn =
        conn(:get, "/api/tenant-config")
        |> put_req_header("origin", @allowed_origin)
        |> call()

      assert get_resp_header(conn, "access-control-allow-origin") == [@allowed_origin]
    end

    test "GET /health with an allowed Origin gets access-control-allow-origin echoed back, and the route still runs" do
      conn =
        conn(:get, "/health")
        |> put_req_header("origin", @allowed_origin)
        |> call()

      assert conn.status == 200

      assert Jason.decode!(conn.resp_body) == %{
               "status" => "ok",
               "sha" => Letflow.BuildInfo.sha()
             }

      assert get_resp_header(conn, "access-control-allow-origin") == [@allowed_origin]
    end

    test "the second compiled-in default origin (127.0.0.1:4173, Playwright preview) is also matched" do
      conn =
        conn(:get, "/health")
        |> put_req_header("origin", @other_allowed_origin)
        |> call()

      assert get_resp_header(conn, "access-control-allow-origin") == [@other_allowed_origin]
    end

    test "matched-origin response carries vary: origin (§1)" do
      conn =
        conn(:get, "/health")
        |> put_req_header("origin", @allowed_origin)
        |> call()

      assert get_resp_header(conn, "vary") == ["origin"]
    end
  end

  # ── AC2 + AC4: unlisted origin — no headers, request still proceeds normally ──

  describe "AC2 + AC4: unlisted origin gets no CORS headers (rejection = silent omission, not a status code)" do
    test "GET /health with an unlisted Origin gets NO access-control-allow-origin header" do
      conn =
        conn(:get, "/health")
        |> put_req_header("origin", @unlisted_origin)
        |> call()

      assert get_resp_header(conn, "access-control-allow-origin") == []
    end

    test "the underlying route still executes normally for an unlisted origin (status/body unaffected, per §0.5)" do
      conn =
        conn(:get, "/health")
        |> put_req_header("origin", @unlisted_origin)
        |> call()

      assert conn.status == 200

      assert Jason.decode!(conn.resp_body) == %{
               "status" => "ok",
               "sha" => Letflow.BuildInfo.sha()
             }
    end

    test "an unlisted-origin request is not halted -- a 404 route still 404s normally" do
      conn =
        conn(:get, "/definitely/not/a/route")
        |> put_req_header("origin", @unlisted_origin)
        |> call()

      assert conn.status == 404
      assert get_resp_header(conn, "access-control-allow-origin") == []
    end
  end

  # ── AC1: allowed-origin list is genuinely config-driven, not hardcoded ──────

  describe "AC1: allowed-origin list is read from Application config at request time" do
    test "overriding :cors_allowed_origins accepts a previously-unlisted origin and rejects a previously-listed one" do
      custom_origin = "https://staging.example.org"

      Application.put_env(:letflow, :cors_allowed_origins, [custom_origin])

      on_exit(fn ->
        Application.delete_env(:letflow, :cors_allowed_origins)
      end)

      # Now-configured origin is accepted, though it was never in @default_origins.
      accepted_conn =
        conn(:get, "/health")
        |> put_req_header("origin", custom_origin)
        |> call()

      assert get_resp_header(accepted_conn, "access-control-allow-origin") == [custom_origin]

      # The compiled-in default origin, no longer in the (overridden) allowlist, is
      # now rejected -- proving the module reads config rather than a hardcoded list.
      now_rejected_conn =
        conn(:get, "/health")
        |> put_req_header("origin", @allowed_origin)
        |> call()

      assert get_resp_header(now_rejected_conn, "access-control-allow-origin") == []
    end
  end

  # ── ISS-0529 regression: localhost:4173 and 127.0.0.1:5173 are in the allowlist ──

  describe "ISS-0529 regression: localhost:4173 and 127.0.0.1:5173 are allowed" do
    test "localhost:4173 (vite preview) gets access-control-allow-origin" do
      conn =
        conn(:get, "/api/tenant-config")
        |> put_req_header("origin", @iss0529_origin_a)
        |> call()

      assert get_resp_header(conn, "access-control-allow-origin") == [@iss0529_origin_a]
    end

    test "127.0.0.1:5173 (vite dev server, loopback) gets access-control-allow-origin" do
      conn =
        conn(:get, "/api/tenant-config")
        |> put_req_header("origin", @iss0529_origin_b)
        |> call()

      assert get_resp_header(conn, "access-control-allow-origin") == [@iss0529_origin_b]
    end
  end

  # ── AC3: preflight OPTIONS handling ─────────────────────────────────────────

  describe "AC3: preflight OPTIONS request, matched origin" do
    test "gets 204 with the full preflight header set, and does not reach a route handler" do
      conn =
        conn(:options, "/api/v1/anything")
        |> put_req_header("origin", @allowed_origin)
        |> put_req_header("access-control-request-method", "POST")
        |> call()

      assert conn.status == 204
      assert conn.resp_body == ""

      assert get_resp_header(conn, "access-control-allow-origin") == [@allowed_origin]
      assert get_resp_header(conn, "vary") == ["origin"]

      assert get_resp_header(conn, "access-control-allow-methods") ==
               ["GET, POST, PUT, PATCH, DELETE, OPTIONS"]

      assert get_resp_header(conn, "access-control-allow-headers") ==
               ["authorization, content-type, idempotency-key, if-match, x-bpm-user-id"]

      assert get_resp_header(conn, "access-control-max-age") == ["600"]
    end

    test "ISS-0780 regression: x-bpm-user-id, if-match, and idempotency-key are all allowed on preflight" do
      conn =
        conn(:options, "/api/v1/anything")
        |> put_req_header("origin", @allowed_origin)
        |> put_req_header("access-control-request-method", "POST")
        |> put_req_header(
          "access-control-request-headers",
          "x-bpm-user-id, if-match, idempotency-key"
        )
        |> call()

      assert conn.status == 204

      [allow_headers] = get_resp_header(conn, "access-control-allow-headers")
      allowed = allow_headers |> String.split(", ") |> Enum.map(&String.trim/1)

      assert "x-bpm-user-id" in allowed
      assert "if-match" in allowed
      assert "idempotency-key" in allowed
    end

    test "preflight response is neither the 404 catch-all nor a normal 200 route response" do
      conn =
        conn(:options, "/health")
        |> put_req_header("origin", @allowed_origin)
        |> put_req_header("access-control-request-method", "GET")
        |> call()

      # A same-origin/unhandled OPTIONS would fall through to the catch-all (404) or,
      # if some route handled OPTIONS explicitly, some other status -- neither
      # applies here: the preflight is short-circuited with 204 before :match runs.
      refute conn.status == 404
      refute conn.status == 200
      assert conn.status == 204
    end

    test "an OPTIONS request without access-control-request-method is NOT treated as preflight (falls through to normal dispatch)" do
      conn =
        conn(:options, "/health")
        |> put_req_header("origin", @allowed_origin)
        |> call()

      # No access-control-request-method header -- not a CORS preflight, so it is not
      # short-circuited with 204; it proceeds to normal routing (no OPTIONS route
      # exists for /health, so it falls through to the 404 catch-all).
      assert conn.status == 404
    end

    test "an OPTIONS preflight from an unlisted origin is not short-circuited, and falls through to the 404 catch-all unchanged" do
      conn =
        conn(:options, "/api/v1/anything")
        |> put_req_header("origin", @unlisted_origin)
        |> put_req_header("access-control-request-method", "POST")
        |> call()

      refute conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == []
    end
  end

  # ── Regression: no Origin header at all -- behaves exactly as before this change ──

  describe "no Origin header (same-origin / non-browser caller) -- unaffected by this change" do
    test "GET /health with no Origin header returns 200 + the existing JSON body, and carries no CORS headers" do
      conn = conn(:get, "/health") |> call()

      assert conn.status == 200

      assert Jason.decode!(conn.resp_body) == %{
               "status" => "ok",
               "sha" => Letflow.BuildInfo.sha()
             }

      assert get_resp_header(conn, "access-control-allow-origin") == []
      assert get_resp_header(conn, "vary") == []
    end
  end

  # ── Invariant pin: access-control-allow-credentials is never emitted ───────

  describe "access-control-allow-credentials is never emitted (§0.1)" do
    test "not present on a matched-origin actual request" do
      conn =
        conn(:get, "/health")
        |> put_req_header("origin", @allowed_origin)
        |> call()

      assert get_resp_header(conn, "access-control-allow-credentials") == []
    end

    test "not present on a matched-origin preflight response" do
      conn =
        conn(:options, "/api/v1/anything")
        |> put_req_header("origin", @allowed_origin)
        |> put_req_header("access-control-request-method", "POST")
        |> call()

      assert get_resp_header(conn, "access-control-allow-credentials") == []
    end

    test "not present on an unlisted-origin request" do
      conn =
        conn(:get, "/health")
        |> put_req_header("origin", @unlisted_origin)
        |> call()

      assert get_resp_header(conn, "access-control-allow-credentials") == []
    end
  end

  # ── T-2621: the allow decision is taken PER HOST ───────────────────────────

  describe "T-2621: the CORS allow decision is per host" do
    setup do
      old_origins = Application.get_env(:letflow, :cors_allowed_origins)
      old_provisioner = Application.get_env(:letflow, Letflow.TenantProvisioner)

      Application.put_env(:letflow, :cors_allowed_origins, @fixed_origins)

      Application.put_env(:letflow, Letflow.TenantProvisioner,
        allowed_hostname_suffixes: @suffixes
      )

      on_exit(fn ->
        restore_env(:cors_allowed_origins, old_origins)
        restore_env(Letflow.TenantProvisioner, old_provisioner)
      end)
    end

    test "a tenant host answers its OWN origin's preflight with 204 and the allow-origin header" do
      conn = preflight(@tenant_host, "https://#{@tenant_host}")

      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == ["https://#{@tenant_host}"]
      assert get_resp_header(conn, "vary") == ["origin"]
      assert get_resp_header(conn, "access-control-max-age") == ["600"]
    end

    test "the platform host answers its OWN origin's preflight with 204 and the allow-origin header" do
      conn = preflight(@platform_host, "https://#{@platform_host}")

      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == ["https://#{@platform_host}"]
    end

    # The five failing pairs of the infra baseline (cors-failing-pairs.md): a
    # preflight from ANOTHER company's origin on a tenant host and on the platform
    # host. Expected: the unknown-origin answer -- 401 and no allow-origin.
    test "infra pair 1: a foreign company's origin on another company's host is refused" do
      assert_uniform_refusal(
        preflight(@other_tenant_host, "https://#{@tenant_host}"),
        preflight(@other_tenant_host, "https://evil.example")
      )
    end

    test "infra pair 2: the same pair the other way round is refused too" do
      assert_uniform_refusal(
        preflight(@tenant_host, "https://#{@other_tenant_host}"),
        preflight(@tenant_host, "https://evil.example")
      )
    end

    test "infra pair 3: a sibling company under the same suffix is refused" do
      assert_uniform_refusal(
        preflight(@third_tenant_host, "https://#{@other_tenant_host}"),
        preflight(@third_tenant_host, "https://evil.example")
      )
    end

    test "infra pair 4: a company under the other allowed suffix is refused" do
      assert_uniform_refusal(
        preflight(@tenant_host_other_suffix, "https://#{@other_tenant_host_other_suffix}"),
        preflight(@tenant_host_other_suffix, "https://evil.example")
      )
    end

    test "infra pair 5: the platform host refuses a company's origin" do
      assert_uniform_refusal(
        preflight(@platform_host, "https://#{@tenant_host}"),
        preflight(@platform_host, "https://evil.example")
      )
    end

    test "the app's own fixed origin (the PWA host) stays allowed on a tenant host" do
      conn = preflight(@tenant_host, "https://#{@pwa_host}")

      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == ["https://#{@pwa_host}"]
    end

    test "a lookalike suffix origin is refused on a tenant host" do
      for origin <- [
            "https://evil-letflow.qa.bizdala.com",
            "https://evil-qa.ai-letflow.com",
            "https://letflow.qa.bizdala.com.evil.test",
            "https://qa.ai-letflow.com.evil.test"
          ] do
        assert_uniform_refusal(
          preflight(@tenant_host, origin),
          preflight(@tenant_host, "https://evil.example"),
          origin
        )
      end
    end

    test "a non-suffix origin is refused on a tenant host" do
      for origin <- ["https://evil.example", "https://evil.example.com", "http://#{@tenant_host}"] do
        assert_uniform_refusal(
          preflight(@tenant_host, origin),
          preflight(@tenant_host, "https://evil.example"),
          origin
        )
      end
    end

    test "a preflight without a resolvable host gets the unknown-origin answer" do
      conn =
        conn(:options, "https://#{@tenant_host}/api/v1/me")
        |> put_req_header("origin", "https://#{@tenant_host}")
        |> put_req_header("access-control-request-method", "GET")
        |> Map.put(:host, "")
        |> call()

      unknown =
        conn(:options, "https://#{@tenant_host}/api/v1/me")
        |> put_req_header("origin", "https://evil.example")
        |> put_req_header("access-control-request-method", "GET")
        |> Map.put(:host, "")
        |> call()

      assert_uniform_refusal(conn, unknown)
    end

    test "a real GET with a foreign origin gets no allow-origin and the unknown-origin answer" do
      conn = get(@tenant_host, "https://#{@other_tenant_host}", "/health")
      unknown = get(@tenant_host, "https://evil.example", "/health")

      assert conn.status == 200
      assert get_resp_header(conn, "access-control-allow-origin") == []
      assert conn.resp_body == unknown.resp_body
    end

    test "the suffix policy decides no CORS allowance at all: the answers are the same for any policy" do
      for policy <- [nil, [], "letflow.qa.bizdala.com", ["bad suffix"], @suffixes] do
        Application.put_env(:letflow, Letflow.TenantProvisioner,
          allowed_hostname_suffixes: policy
        )

        own = preflight(@tenant_host, "https://#{@tenant_host}")
        assert own.status == 204, inspect(policy)
        assert get_resp_header(own, "access-control-allow-origin") == ["https://#{@tenant_host}"]

        foreign = preflight(@tenant_host, "https://#{@other_tenant_host}")
        assert get_resp_header(foreign, "access-control-allow-origin") == [], inspect(policy)
        refute foreign.status == 204, inspect(policy)
      end
    end
  end

  # ── company origins under the per-host rule (the C2-C4 coverage, re-pinned) ──

  describe "company namespace C2-C4 under the per-host rule" do
    setup do
      old_origins = Application.get_env(:letflow, :cors_allowed_origins)
      old_provisioner = Application.get_env(:letflow, Letflow.TenantProvisioner)

      Application.put_env(:letflow, Letflow.TenantProvisioner,
        allowed_hostname_suffixes: ~w(ai-letflow.com qa.ai-letflow.com qa.bizdala.com)
      )

      on_exit(fn ->
        restore_env(:cors_allowed_origins, old_origins)
        restore_env(Letflow.TenantProvisioner, old_provisioner)
      end)
    end

    test "C2 a company origin is allowed on its OWN host and on no other host" do
      for host <- ~w(acme.ai-letflow.com acme.qa.ai-letflow.com acme.qa.bizdala.com) do
        origin = "https://#{host}"

        actual =
          conn(:get, "https://#{host}/health") |> put_req_header("origin", origin) |> call()

        assert actual.status == 200
        assert get_resp_header(actual, "access-control-allow-origin") == [origin]

        preflight =
          conn(:options, "https://#{host}/health")
          |> put_req_header("origin", origin)
          |> put_req_header("access-control-request-method", "POST")
          |> call()

        assert preflight.status == 204
        assert get_resp_header(preflight, "access-control-allow-origin") == [origin]
        assert get_resp_header(preflight, "vary") == ["origin"]
        assert get_resp_header(preflight, "access-control-max-age") == ["600"]

        assert get_resp_header(preflight, "access-control-allow-methods") == [
                 "GET, POST, PUT, PATCH, DELETE, OPTIONS"
               ]

        assert get_resp_header(preflight, "access-control-allow-headers") == [
                 "authorization, content-type, idempotency-key, if-match, x-bpm-user-id"
               ]
      end
    end

    test "C2 the same company origin on ANOTHER company's host is refused" do
      for {host, origin_host} <- [
            {"other.ai-letflow.com", "acme.ai-letflow.com"},
            {"acme.qa.ai-letflow.com", "acme.ai-letflow.com"},
            {"other.qa.bizdala.com", "acme.qa.bizdala.com"}
          ] do
        actual =
          conn(:get, "https://#{host}/health")
          |> put_req_header("origin", "https://#{origin_host}")
          |> call()

        assert get_resp_header(actual, "access-control-allow-origin") == [], host

        preflight =
          conn(:options, "https://#{host}/health")
          |> put_req_header("origin", "https://#{origin_host}")
          |> put_req_header("access-control-request-method", "POST")
          |> call()

        refute preflight.status == 204, host
        assert get_resp_header(preflight, "access-control-allow-origin") == [], host
      end
    end

    test "C3 malformed, reserved and foreign origins get no CORS allowance" do
      for origin <-
            ~w(https://evil.example https://ai-letflow.com https://a.b.ai-letflow.com https://*.ai-letflow.com http://acme.ai-letflow.com https://user@acme.ai-letflow.com https://acme.ai-letflow.com/ https://acme.ai-letflow.com?x=1 https://acme.ai-letflow.com#x https://acme.ai-letflow.com:444 https://auth.ai-letflow.com https://qa.ai-letflow.com https://acme.ai-letflow.com.evil.example) do
        actual =
          conn(:get, "https://acme.ai-letflow.com/health")
          |> put_req_header("origin", origin)
          |> call()

        assert get_resp_header(actual, "access-control-allow-origin") == [], origin

        preflight =
          conn(:options, "https://acme.ai-letflow.com/health")
          |> put_req_header("origin", origin)
          |> put_req_header("access-control-request-method", "POST")
          |> call()

        refute preflight.status == 204, origin
        assert get_resp_header(preflight, "access-control-allow-origin") == [], origin
      end
    end

    test "C3 whitespace in an origin host is not a company origin" do
      for origin <- ["https://acme.ai-letflow.com ", "https:// acme.ai-letflow.com"] do
        actual =
          conn(:get, "https://acme.ai-letflow.com/health")
          |> put_req_header("origin", origin)
          |> call()

        assert get_resp_header(actual, "access-control-allow-origin") == []
      end
    end

    test "C3 non-UTF-8 and oversized origins are refused without raising (INV-8)" do
      long = "https://" <> String.duplicate("a", 400) <> ".qa.ai-letflow.com"

      for origin <- [<<"https://", 0xFF, ".qa.ai-letflow.com">>, <<0xC3>>, long] do
        actual =
          conn(:get, "https://acme.ai-letflow.com/health")
          |> put_req_header("origin", origin)
          |> call()

        refute actual.halted
        assert actual.status == 200
        assert get_resp_header(actual, "access-control-allow-origin") == []

        preflight =
          conn(:options, "https://acme.ai-letflow.com/health")
          |> put_req_header("origin", origin)
          |> put_req_header("access-control-request-method", "POST")
          |> call()

        refute preflight.status == 204
        assert get_resp_header(preflight, "access-control-allow-origin") == []
      end
    end

    test "C3 malformed ports are refused even if URI parsing defaults to 443" do
      for origin <- ["https://acme.ai-letflow.com:bad", "https://acme.ai-letflow.com:"] do
        actual =
          conn(:get, "https://acme.ai-letflow.com/health")
          |> put_req_header("origin", origin)
          |> call()

        assert get_resp_header(actual, "access-control-allow-origin") == []
      end
    end

    test "C4 a request whose host is not usable is refused like an unknown origin (INV-8)" do
      for host <- ["", <<0xFF>>, nil] do
        actual =
          conn(:get, "https://acme.ai-letflow.com/health")
          |> put_req_header("origin", "https://acme.ai-letflow.com")
          |> Map.put(:host, host)
          |> call()

        refute actual.halted
        assert actual.status == 200
        assert get_resp_header(actual, "access-control-allow-origin") == []
      end
    end
  end

  # ── the allow-origin header has exactly one writer ──────────────────────────

  describe "access-control-allow-origin has exactly one writer" do
    test "only lib/letflow/plugs/cors.ex sets the header" do
      writers =
        for path <- Path.wildcard("lib/**/*.ex"),
            File.read!(path) =~ "access-control-allow-origin",
            do: path

      assert writers == ["lib/letflow/plugs/cors.ex"],
             "a new code path sets access-control-allow-origin: classify it here"
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  # A CORS preflight addressed to `host`, exactly as the infra probe sent it:
  # OPTIONS <host>/api/v1/me with an Origin and an Access-Control-Request-Method.
  defp preflight(host, origin) do
    conn(:options, "https://#{host}/api/v1/me")
    |> put_req_header("origin", origin)
    |> put_req_header("access-control-request-method", "GET")
    |> call()
  end

  defp get(host, origin, path) do
    conn(:get, "https://#{host}#{path}")
    |> put_req_header("origin", origin)
    |> call()
  end

  # The refusal must be indistinguishable from the answer for an origin the app
  # knows nothing about: the same status, the same body, and no allow-origin.
  defp assert_uniform_refusal(conn, unknown, origin \\ nil) do
    assert get_resp_header(conn, "access-control-allow-origin") == [], origin || "origin"
    assert conn.status == unknown.status, origin || "status"
    assert conn.resp_body == unknown.resp_body, origin || "body"
    refute conn.status == 204, origin || "status"
  end

  defp restore_env(key, nil), do: Application.delete_env(:letflow, key)
  defp restore_env(key, value), do: Application.put_env(:letflow, key, value)
end
