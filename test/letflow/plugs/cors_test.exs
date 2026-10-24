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
end
