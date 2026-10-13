defmodule Letflow.Plugs.Cors do
  @moduledoc """
  CORS handling for the browser-origin SPA (REQ-118).

  In development the SPA runs on `:5173` (Vite dev server) and Letflow on
  `:4000`; the Vite dev proxy hides this for `npm run dev`, but nothing hides
  it for a built SPA served from any other origin, nor for the Playwright
  e2e suite (`web/playwright.config.ts` serves the built app on `:4173`).
  This plug is what makes those cross-origin calls work.

  See `lib/letflow/design/req118-cors.md` for the full design and reasoning
  (CODE-DESIGN-VALIDATOR-approved) — summarized here:

  * **No credentials, ever.** `web/src/api/client.ts` holds its bearer token
    in memory and sends it as an `Authorization: Bearer <token>` header —
    never cookies, never `credentials: 'include'`. `access-control-allow-credentials`
    is therefore never emitted by this plug, in any code path.
  * **Allowed origins come from config, never hardcoded, and default to no
    wildcard.** `Application.get_env(:letflow, :cors_allowed_origins,
    @default_origins)`, read **at request time** (not `compile_env` — origins
    differ per deploy environment and must not require a rebuild to change;
    this deliberately does NOT mirror `Letflow.Api.Error`'s `:problems_base_uri`
    compile-time pattern). `@default_origins` (dev/test) covers both the
    `:5173` dev-server and `:4173` preview-server ports in both their
    `localhost` and `127.0.0.1` spellings — browsers treat those as distinct
    origins, and ISS-0529 confirmed that omitting `localhost:4173` specifically
    blocks the SPA's `/api/tenant-config` bootstrap with a silent fallback to a
    hardcoded Keycloak authority. No `*`, ever. `config/runtime.exs` overrides
    this in prod via `CORS_ALLOWED_ORIGINS`, fail-closed to `[]` when unset.
  * **Rejection is silent, not a 403.** CORS is a browser-enforced,
    response-header-driven mechanism — the server's only lever is which
    headers it emits. An unlisted `Origin` gets no CORS headers at all and
    the request proceeds through the normal pipeline unchanged (so
    non-browser callers — curl, server-to-server, the mobile tier — are
    never blocked by this plug); the browser is what then refuses to expose
    the response to the calling JS.
  * **Preflight (`OPTIONS`) is implemented, not skipped.** `Authorization` is
    not a CORS-safelisted header, so the browser preflights every
    authenticated call. A matched-origin preflight is short-circuited here
    with `204` + the preflight header set, before `Letflow.Router`'s
    `plug(:match)`/`plug(:dispatch)` ever runs.

  Mounted in `Letflow.Router` itself (not `Letflow.Plugs.ApiPipeline`), ahead
  of both the `/api/tenant-config` and `/api/v1` forwards — `/api/tenant-config`
  is the SPA's login-bootstrap call and is cross-origin too, before any token
  exists to send.
  """

  @behaviour Plug

  import Plug.Conn

  # Both ports × both host spellings. ISS-0529: localhost:4173 was missing;
  # its absence silently blocked the SPA's /api/tenant-config bootstrap.
  @default_origins [
    "http://localhost:5173",
    "http://localhost:4173",
    "http://127.0.0.1:5173",
    "http://127.0.0.1:4173"
  ]

  # The method set Letflow's routers actually use (write methods per
  # `Letflow.Plugs.TenantStatus`'s `@write_methods`, plus GET/OPTIONS).
  @allow_methods "GET, POST, PUT, PATCH, DELETE, OPTIONS"

  # The request headers the SPA actually sends, audited against web/src in full
  # (ISS-0780) -- keep it that way. Deliberately an explicit allowlist, not an
  # echo of the request's `access-control-request-headers` value:
  #   * authorization    -- bearer token, every authenticated request (client.ts)
  #   * content-type     -- JSON body (client.ts)
  #   * idempotency-key  -- no SPA call sends it any more (POST /api/v1/onboarding stopped in
  #                         ISS-1091); kept allowed so a browser-based operator tool that sends it
  #                         on the instances routes still passes preflight (ISS-0780 regression test)
  #   * if-match         -- optimistic-concurrency PUT (web/src/api/entities.ts,
  #                         REQ-336, via client.putWithHeaders)
  #   * x-bpm-user-id    -- JWT `sub` claim, every authenticated request
  #                         (client.ts) -- the header ISS-0780 was filed over
  @allow_headers "authorization, content-type, idempotency-key, if-match, x-bpm-user-id"

  # 10 minutes — bounds how often a browser re-preflights. No correctness
  # dependency on the exact value.
  @max_age "600"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn
    |> get_req_header("origin")
    |> List.first()
    |> handle(conn)
  end

  defp handle(nil, conn), do: conn

  defp handle(origin, conn) do
    if origin_allowed?(origin) do
      handle_allowed(conn, origin)
    else
      conn
    end
  end

  defp handle_allowed(conn, origin) do
    conn = put_cors_headers(conn, origin)

    if preflight_request?(conn) do
      conn
      |> put_resp_header("access-control-allow-methods", @allow_methods)
      |> put_resp_header("access-control-allow-headers", @allow_headers)
      |> put_resp_header("access-control-max-age", @max_age)
      |> send_resp(204, "")
      |> halt()
    else
      conn
    end
  end

  defp put_cors_headers(conn, origin) do
    conn
    |> put_resp_header("access-control-allow-origin", origin)
    |> update_resp_header("vary", "origin", fn existing -> merge_vary(existing, "origin") end)
  end

  defp merge_vary(existing, value) do
    values = existing |> String.split(",") |> Enum.map(&String.trim/1)
    if value in values, do: existing, else: existing <> ", " <> value
  end

  @spec allowed_origins() :: [String.t()]
  defp allowed_origins do
    Application.get_env(:letflow, :cors_allowed_origins, @default_origins)
  end

  @spec origin_allowed?(String.t()) :: boolean()
  defp origin_allowed?(origin), do: origin in allowed_origins()

  @spec preflight_request?(Plug.Conn.t()) :: boolean()
  defp preflight_request?(conn) do
    conn.method == "OPTIONS" and get_req_header(conn, "access-control-request-method") != []
  end
end
