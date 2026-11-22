defmodule Letflow.Plugs.Cors do
  @moduledoc """
  CORS handling for the browser-origin SPA (REQ-118).

  In development the SPA runs on `:5173` (Vite dev server) and Letflow on
  `:4000`; the Vite dev proxy hides this for `npm run dev`, but nothing hides
  it for a built SPA served from any other origin, nor for the Playwright
  e2e suite (`web/playwright.config.ts` serves the built app on `:4173`).
  This plug is what makes those cross-origin calls work.

  See `lib/letflow/design/req118-cors.md` for the full design and reasoning
  (CODE-DESIGN-VALIDATOR-approved) — summarized here. The per-host rule of
  T-2621 below supersedes that record's decision-table row "Origin present,
  not in allowlist → pass through unchanged — no CORS headers added, no halt
  (§0.5)": a host now grants its OWN origin even though that origin is not in
  the allowlist. (The record carries no company-suffix rule; the guarded
  suffix list it predates grants no CORS allowance at all — the defect this
  change fixes.)

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
    These are the app's OWN origins (the platform host, the PWA host the SPA is
    served from); a listed origin is allowed on every host.
  * **The allow decision is taken PER HOST (T-2621).** An origin is allowed
    only when it is one of the app's own fixed origins (above) or when it IS
    the host the request is addressed to — `https://<that host>`, the origin OF
    that host. The comparison is on the HOST NAME alone (the origin must be a
    serialized `https://<host>` origin, default port 443), so this is a "same
    host" grant, not a "same origin" one: behind the TLS-terminating proxy the
    public scheme and port are not knowable from the conn. Nothing else is
    allowed: another company's origin, an origin that is not this host, a
    lookalike suffix (`evil-<suffix>`, `<suffix>.evil.test`) and every
    malformed origin get the SAME answer an unknown origin gets. Before T-2621
    the guarded provisioner suffix list
    (`LETFLOW_PROVISIONER_ALLOWED_HOSTNAME_SUFFIXES`) permitted HTTPS company
    origins, which meant "any origin under an allowed suffix is allowed on
    EVERY host that reaches the app": a preflight from one company passed on
    another company's host and on the platform host. The suffix list is a
    PROVISIONING policy (which hostname a company may be given); it grants no
    CORS allowance at all now, and the decision does not depend on it — a host
    grants an origin only when that origin is the host itself. A preflight
    carries no tenant context, so the host is the only thing the decision can
    be taken on.
  * **Rejection is silent, not a 403.** CORS is a browser-enforced,
    response-header-driven mechanism — the server's only lever is which
    headers it emits. An unlisted `Origin` gets no CORS headers at all and
    the request proceeds through the normal pipeline unchanged (so
    non-browser callers — curl, server-to-server, the mobile tier — are
    never blocked by this plug); the browser is what then refuses to expose
    the response to the calling JS. Every refused origin gets that one answer
    — the same status and the same body an unknown origin gets — so the
    refusal reveals nothing about the company the origin names (INV-5).
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
  #   * idempotency-key  -- the stock document create, issue and post routes (POST
  #                         /api/v1/modules/stock/documents[/:id/issue|/:id/post]); the web client
  #                         sends it from REQ-848 on (REQ-846, REQ-847 accept it); also kept for browser-based operator tools
  #                         that use it on the instances routes (ISS-0780 regression)
  #   * if-match         -- optimistic-concurrency PUT (web/src/api/entities.ts,
  #                         REQ-336, via client.putWithHeaders)
  #   * x-bpm-user-id    -- JWT `sub` claim, every authenticated request
  #                         (client.ts) -- the header ISS-0780 was filed over
  @allow_headers "authorization, content-type, idempotency-key, if-match, x-bpm-user-id"

  # 10 minutes — bounds how often a browser re-preflights. No correctness
  # dependency on the exact value.
  @max_age "600"

  # The Origin header is unauthenticated input and this plug runs before every
  # route: anything longer than this is refused before URI.new/1 parses it
  # (INV-8, and a bound on the work one request can ask for).
  @max_origin_bytes 300

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
    if origin_allowed?(origin, conn) do
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

  # T-2621: the decision is taken PER HOST. An origin is allowed when it is one
  # of the app's own fixed origins, or when it IS the host this request is
  # addressed to — the origin of the company that owns the host. Every other
  # origin (another company's, a non-suffix host, a lookalike suffix, a
  # malformed one) is refused with the answer an unknown origin gets.
  @spec origin_allowed?(String.t(), Plug.Conn.t()) :: boolean()
  defp origin_allowed?(origin, conn) do
    origin in allowed_origins() or own_origin?(origin, conn)
  end

  # The origin IS the host this request is addressed to: the only company origin
  # a host ever grants. A request whose host is not usable text grants nothing.
  @spec own_origin?(String.t(), Plug.Conn.t()) :: boolean()
  defp own_origin?(origin, conn) do
    with host when is_binary(host) <- request_host(conn),
         origin_host when is_binary(origin_host) <- origin_host(origin) do
      origin_host == host
    else
      _other -> false
    end
  end

  # The host this request is addressed to (the Host header; Letflow never
  # resolves a tenant from it — see `Letflow.Routers.TenantConfig`'s moduledoc).
  # A host that is not usable text is no host at all: String.downcase/1 raises on
  # invalid UTF-8, so the check comes first (INV-8).
  @spec request_host(Plug.Conn.t()) :: String.t() | nil
  defp request_host(conn) do
    case conn.host do
      host when is_binary(host) ->
        if String.valid?(host) do
          case host |> String.trim() |> String.downcase() do
            "" -> nil
            host -> host
          end
        else
          nil
        end

      _other ->
        nil
    end
  end

  # The host of an HTTPS origin (default port, no userinfo, path, query or
  # fragment), or nil when the Origin header is not such an origin. The Origin
  # header is unauthenticated input and this plug runs before every route:
  # anything that is not a short printable-ASCII string is refused before
  # URI.new/1, which raises on a non-UTF-8 byte (INV-8). Fails closed.
  @spec origin_host(String.t()) :: String.t() | nil
  defp origin_host(origin) when byte_size(origin) > @max_origin_bytes, do: nil

  defp origin_host(origin) do
    if Regex.match?(~r/\A[\x21-\x7e]+\z/, origin) do
      case URI.new(origin) do
        {:ok,
         %URI{
           scheme: "https",
           host: host,
           port: 443,
           userinfo: nil,
           path: nil,
           query: nil,
           fragment: nil
         }}
        when is_binary(host) ->
          # URI parsers normalize an empty port to 443, so "https://host:" parses like
          # "https://host": accept only a serialized origin, as the URL spec does.
          if origin in ["https://" <> host, "https://" <> host <> ":443"],
            do: String.downcase(host),
            else: nil

        _other ->
          nil
      end
    else
      nil
    end
  end

  @spec preflight_request?(Plug.Conn.t()) :: boolean()
  defp preflight_request?(conn) do
    conn.method == "OPTIONS" and get_req_header(conn, "access-control-request-method") != []
  end
end
