defmodule Letflow.Support.MockOidcProvider do
  @moduledoc """
  Minimal local HTTP/1.1 OIDC discovery + JWKS server for REQ-370's AC2/AC3/AC5
  tests (`test/letflow/oidc/provider_registry_multi_realm_test.exs`).

  **Why this exists, not real Keycloak.** REQ-370's own design doc
  (`lib/letflow/design/req370-multi-issuer-oidc-verification.md` §11 "AC2") is
  explicit that the cross-realm-forgery check needs a token "whose `iss` claims
  realm A but whose signature was produced with realm B's own signing key...
  constructing this directly via the test double's/fixture's own key material --
  not obtainable from a real Keycloak, since that would require possessing another
  realm's private key". A real Keycloak instance never hands out its realms'
  private signing keys over any API, so AC2's negative case is only constructible
  against a fixture this suite fully controls the key material of. Having built
  that fixture, AC3 (>=2 realms independently verify) and AC5 (revocation) reuse it
  too, for determinism -- this environment's real Keycloak container (used by
  `test/letflow/integration/keycloak_auth_pipeline_test.exs`) was directly observed
  to `:httpc` `{:transport_error, :timeout}` intermittently against repeated calls
  during this same session, which would make a real-Keycloak-based AC2/AC3/AC5 test
  file flaky in a way unrelated to the property under test.

  **Why a raw `:gen_tcp` server, not `Bandit`/`Plug.Router`.** Mirrors
  `Letflow.WebhookTestServer`'s own established precedent and stated rationale in
  this exact `test/support/` directory: `Bypass`/`Plug.Cowboy` are not in
  `mix.lock`, and reaching for this repo's own production HTTP stack (`Bandit`,
  `Plug.Router`) for one test-only mock server was judged heavier than the ~100
  lines of raw HTTP/1.1 response-writing this needs (GET-only, no request body to
  parse -- simpler than `WebhookTestServer`'s own POST-with-body case). `:gen_tcp`/
  `:inets` are already part of the OTP standard library, so this adds no new
  dependency of any kind, matching `WebhookTestServer`'s own "zero new test
  mechanism" precedent.

  ## What it serves

  For each realm named in `start/1`'s `realms` list, a fresh 2048-bit RSA keypair
  is generated (`JOSE.JWK.generate_key/1`) and this server answers:

    * `GET /realms/<realm>/.well-known/openid-configuration` -- a minimal OIDC
      discovery document (only the fields `oidcc`'s own decoder requires:
      `issuer`, `authorization_endpoint`, `jwks_uri`, `scopes_supported`,
      `response_types_supported`, `subject_types_supported`,
      `id_token_signing_alg_values_supported` -- confirmed against
      `deps/oidcc/src/oidcc_provider_configuration.erl`'s own `extract/2` field
      list). `issuer` is set to exactly `<base_url>/realms/<realm>` -- `oidcc`
      rejects a discovery document whose own `"issuer"` field doesn't match the
      URI it was configured with (`oidcc_provider_configuration.erl`'s
      `issuer_mismatch` check), so this must match byte-for-byte what
      `Letflow.Oidc.ProviderRegistry.start_worker/2` constructs as
      `keycloak_base_url <> "/realms/" <> realm`.
    * `GET /realms/<realm>/protocol/openid-connect/certs` -- `{"keys": [<public
      JWK>]}`, that realm's own public key only (never another realm's) --
      this is what makes AC2's routing-isolation property observable: realm A's
      provider worker only ever learns realm A's own public key from this server,
      so a token signed with realm B's key cannot verify against it.
    * Anything else -- `404`.

  ## Lifecycle

  `start/1` binds an OS-assigned free `127.0.0.1` port (never a fixed one, so
  concurrent/`async: false`-serialized test runs never collide with each other or
  a real service -- same reasoning as `Letflow.WebhookTestServer.start_with_responder/1`),
  spawns a linked, unsupervised accept-loop process (test-only; never added to
  `Letflow.Application`'s supervision tree), and registers `ExUnit.Callbacks.on_exit/1`
  to kill the acceptor and close the listening socket, so no port or process leaks
  into the next test. The acceptor serves for the whole test, however long setup runs
  before the first request; `opts[:accept_timeout]` (default 15 s) is only how often its
  `:gen_tcp.accept/2` call wakes up (`mock_oidc_provider_test.exs` uses a short one).

  Returns `%{base_url:, realms: %{realm => %{issuer:, jwk:, kid:}}}` -- `realms`
  carries each realm's own PRIVATE `JOSE.JWK.t()`, used by `sign_token/3` below to
  mint tokens (this map is test-only fixture state, never served over HTTP -- only
  each realm's derived PUBLIC JWK is ever written to the wire, via the
  `/certs` endpoint above).
  """

  @typedoc "One realm's fixture key material and issuer, as returned by `start/1`."
  @type realm_fixture :: %{issuer: String.t(), jwk: JOSE.JWK.t(), kid: String.t()}

  @spec start(realms :: [String.t()], opts :: keyword()) :: %{
          base_url: String.t(),
          realms: %{String.t() => realm_fixture()}
        }
  def start(realms, opts \\ []) when is_list(realms) and realms != [] do
    accept_timeout = Keyword.get(opts, :accept_timeout, 15_000)

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)
    base_url = "http://127.0.0.1:#{port}"

    realm_fixtures =
      for realm <- realms, into: %{}, do: {realm, build_realm_fixture(base_url, realm)}

    routes = build_routes(base_url, realm_fixtures)

    acceptor = spawn_link(fn -> accept_loop(listen_socket, routes, accept_timeout) end)

    ExUnit.Callbacks.on_exit(fn ->
      Process.exit(acceptor, :kill)
      :gen_tcp.close(listen_socket)
    end)

    %{base_url: base_url, realms: realm_fixtures}
  end

  @doc """
  Mints a compact-serialized RS256 JWT via `JOSE.JWT.sign/3`, real cryptographic
  signature (not a stub/double) against `realm_fixtures`' own key material
  (`start/1`'s return value).

  `claimed_realm`'s issuer is what the token's `"iss"` claim carries.
  `opts[:signing_realm]` (default: `claimed_realm`) selects WHICH realm's private
  key actually signs it -- passing a different `signing_realm` than
  `claimed_realm` is exactly AC2's forgery case: an `iss` claiming realm A,
  signed with realm B's key.

  `opts[:sub]`/`opts[:aud]`/`opts[:exp]`/`opts[:roles]` override the
  corresponding claim (defaults: a realm-derived subject, `"letflow-web"`
  matching `config/test.exs`'s `:oidc, :client_id`, 5 minutes from now, and
  `["VIEWER"]`).
  """
  @spec sign_token(
          realm_fixtures :: %{String.t() => realm_fixture()},
          claimed_realm :: String.t(),
          opts :: keyword()
        ) :: String.t()
  def sign_token(realm_fixtures, claimed_realm, opts \\ []) do
    signing_realm = Keyword.get(opts, :signing_realm, claimed_realm)
    %{jwk: jwk, kid: kid} = Map.fetch!(realm_fixtures, signing_realm)
    %{issuer: issuer} = Map.fetch!(realm_fixtures, claimed_realm)

    now = System.system_time(:second)
    default_sub = "mock-subject-#{claimed_realm}"

    claims = %{
      "iss" => issuer,
      "sub" => Keyword.get(opts, :sub, default_sub),
      "aud" => Keyword.get(opts, :aud, "letflow-web"),
      "exp" => Keyword.get(opts, :exp, now + 300),
      "iat" => now,
      "preferred_username" => Keyword.get(opts, :sub, default_sub),
      "email" => "#{Keyword.get(opts, :sub, default_sub)}@example.invalid",
      "realm_access" => %{"roles" => Keyword.get(opts, :roles, ["VIEWER"])}
    }

    jws_header = %{"alg" => "RS256", "kid" => kid}

    {_jws, compact_token} =
      jwk
      |> JOSE.JWT.sign(jws_header, JOSE.JWT.from_map(claims))
      |> JOSE.JWS.compact()

    compact_token
  end

  # ---------------------------------------------------------------------------------
  # Fixture construction -- one RSA keypair per realm, plus its precomputed
  # discovery/JWKS JSON bodies (static for this server's lifetime; no per-request
  # computation needed).
  # ---------------------------------------------------------------------------------

  defp build_realm_fixture(base_url, realm) do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    kid = "mock-#{realm}"
    issuer = "#{base_url}/realms/#{realm}"

    %{issuer: issuer, jwk: jwk, kid: kid}
  end

  defp build_routes(base_url, realm_fixtures) do
    Enum.reduce(realm_fixtures, %{}, fn {realm, %{issuer: issuer, jwk: jwk, kid: kid}}, acc ->
      discovery_path = "/realms/#{realm}/.well-known/openid-configuration"
      jwks_path = "/realms/#{realm}/protocol/openid-connect/certs"

      discovery_body =
        Jason.encode!(%{
          "issuer" => issuer,
          "authorization_endpoint" => "#{base_url}/realms/#{realm}/protocol/openid-connect/auth",
          "jwks_uri" => "#{base_url}#{jwks_path}",
          "scopes_supported" => ["openid"],
          "response_types_supported" => ["code"],
          "subject_types_supported" => ["public"],
          "id_token_signing_alg_values_supported" => ["RS256"]
        })

      {_module, public_map} = JOSE.JWK.to_public_map(jwk)
      public_jwk = Map.merge(public_map, %{"kid" => kid, "use" => "sig", "alg" => "RS256"})
      jwks_body = Jason.encode!(%{"keys" => [public_jwk]})

      acc
      |> Map.put(discovery_path, discovery_body)
      |> Map.put(jwks_path, jwks_body)
    end)
  end

  # ---------------------------------------------------------------------------------
  # Accept loop -- one connection at a time, GET-only, no request body to parse.
  # ---------------------------------------------------------------------------------

  # An accept timeout is only a polling interval, not an idle limit: the loop keeps
  # serving until `on_exit/1` closes the socket (`:closed`) or kills the acceptor. A test
  # whose setup runs longer than the timeout before its first token check (several
  # tenants with module installs) must still find the server up.
  defp accept_loop(listen_socket, routes, accept_timeout) do
    case :gen_tcp.accept(listen_socket, accept_timeout) do
      {:ok, client_socket} ->
        handle_connection(client_socket, routes)
        accept_loop(listen_socket, routes, accept_timeout)

      {:error, :timeout} ->
        accept_loop(listen_socket, routes, accept_timeout)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp handle_connection(socket, routes) do
    with {:ok, request_line} <- read_request_line(socket) do
      path = parse_path(request_line)
      :ok = :gen_tcp.send(socket, response_for(routes, path))
    end

    :gen_tcp.close(socket)
  end

  # Reads only up to the first CRLF (the request line) -- this server never needs
  # anything past it (GET requests, no body to read), and closes the connection
  # right after responding (`connection: close`), so leaving any remaining
  # header bytes undrained on the socket is safe -- `:gen_tcp.close/1` discards
  # them, and `:httpc`/`oidcc`'s HTTP client only ever reads the response it's
  # waiting for, never the request it just finished sending.
  defp read_request_line(socket, acc \\ "") do
    if String.contains?(acc, "\r\n") do
      [request_line | _rest] = String.split(acc, "\r\n", parts: 2)
      {:ok, request_line}
    else
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, chunk} -> read_request_line(socket, acc <> chunk)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp parse_path(request_line) do
    case String.split(request_line, " ", parts: 3) do
      [_method, path, _version] -> path |> String.split("?", parts: 2) |> hd()
      _other -> "/"
    end
  end

  defp response_for(routes, path) do
    case Map.fetch(routes, path) do
      {:ok, body} -> response_bytes(200, "OK", body)
      :error -> response_bytes(404, "Not Found", Jason.encode!(%{"error" => "not_found"}))
    end
  end

  defp response_bytes(status, reason, body) do
    "HTTP/1.1 #{status} #{reason}\r\n" <>
      "content-type: application/json\r\n" <>
      "content-length: #{byte_size(body)}\r\n" <>
      "connection: close\r\n" <>
      "\r\n" <>
      body
  end
end
