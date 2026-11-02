defmodule Letflow.Integration.KeycloakMobileClientAuthTest do
  @moduledoc """
  REQ-418 — real-Keycloak live checks for the `letflow-mobile` OIDC client
  (`lib/letflow/design/req418-mobile-oidc-client.md` §1, §4 AC3/AC4). These are the two
  acceptance criteria that a static JSON-shape test cannot exercise, because they assert
  on Keycloak's own *behavior* at the authorization endpoint and the admin
  evaluate-scopes endpoint, not on the tracked realm file:

    * AC3 — three authorization-endpoint checks: a valid PKCE request returns the login
      page; a foreign `redirect_uri` is rejected without ever redirecting to it; a
      request missing `code_challenge` is rejected because
      `attributes."pkce.code.challenge.method": "S256"` (design §1.2) makes Keycloak
      enforce PKCE server-side, not just as a client-side convention.
    * AC4 — the admin `evaluate-scopes/generate-example-access-token` endpoint proves the
      `letflow-mobile-audience` mapper (design §1.4) actually produces an `aud` claim
      containing `"letflow-web"` (the ISS-0275 recurrence this design exists to prevent),
      while `azp` is `"letflow-mobile"` (which `Oidcc.Token.validate_jwt/3`'s
      `verify_aud_claim` never checks, per design §1.4's closing paragraph).

  `test/letflow/api/keycloak_realm_mobile_client_test.exs` (static, `async: true`, no
  Keycloak required) already covers REQ-418's AC1/AC2 — the client's declared shape in
  the tracked JSON file. This module never re-asserts that shape; it proves Keycloak
  actually *behaves* according to it once the realm is imported into a running
  container.

  ## Running this suite deliberately

      mix test --include keycloak test/letflow/integration/keycloak_mobile_client_auth_test.exs

  Requires a freshly imported dev Keycloak (`docker compose up -d --force-recreate
  keycloak` — realm import only runs when the realm does not already exist, per REQ-418
  AC3's own wording) and the app's Postgres, though this module makes no database calls
  itself; it is grouped under `test/letflow/integration/` and tagged `:keycloak` for the
  same reason `keycloak_auth_pipeline_test.exs` is.

  ## Following `keycloak_auth_pipeline_test.exs`'s established conventions exactly

  `@moduletag :keycloak` (excluded from every default `mix test` invocation by
  `test/test_helper.exs`'s `ExUnit.start(exclude: [:keycloak, ...])`); `async: false`
  (this module makes real, uncached HTTP calls against a single shared Keycloak
  container and mutates nothing process-global, but async: false is kept for parity with
  every other file in this `:keycloak`-tagged family, and because AC4's admin-token
  acquisition is itself somewhat expensive and gains nothing from concurrency here); and
  a `setup_all` reachability check that **raises a plain `RuntimeError`** rather than
  returning `{:skip, message}` — `keycloak_auth_pipeline_test.exs`'s own moduledoc
  ("Deviation from design §3.1's literal `{:skip, message}` mechanism") explains in full
  why `{:skip, _}` is not accepted by this installed ExUnit version's `setup_all`
  callback (it raises `RuntimeError: expected ExUnit setup_all callback ... to return
  the atom :ok, a keyword, or a map, got {:skip, ...} instead` — strictly more obscure
  than a direct, targeted message). This module reuses that exact reasoning rather than
  rediscovering it.

  ## HTTP client

  `test/support/keycloak_test_client.ex` already settled (design
  `req134-real-keycloak-token-integration.md` §3.2) on Erlang/OTP's built-in `:httpc`
  (the `:inets` application) rather than adding a new `mix.exs` HTTP-client dependency
  for a test file excluded from every default run. This module reuses that same choice
  and `KeycloakTestClient.ensure_started/0` /
  `KeycloakTestClient.discovery_reachable?/1` / `KeycloakTestClient.direct_access_token/4`
  directly — the latter's `token_url`/`username`/`password`/`client_id` signature is
  realm-agnostic, so it is reused unmodified for the master-realm `admin-cli`
  password-grant AC4 needs (there is nothing web/mobile-realm-specific about it). No new
  helper is added to `keycloak_test_client.ex` — the two raw calls this module needs
  beyond that (a no-redirect-follow GET against the authorization endpoint, and a few
  bearer-authenticated GETs against the admin REST API) are specific enough to this one
  file's two acceptance criteria that adding them to the shared support module would
  widen its surface for a single caller; a second live-Keycloak file needing the same
  raw shape would be the point to extract a shared helper (mirrors design §1.5 "OQ-2"'s
  same reasoning for env-var test helpers).
  """

  use ExUnit.Case, async: false

  @moduletag :keycloak

  alias Letflow.Support.KeycloakTestClient

  @realm "bpm-default"
  @mobile_client_id "letflow-mobile"
  @redirect_uri "com.bizdala.letflow:/oauth2redirect"
  @evil_redirect_uri "https://evil.example/cb"

  # Design §3.2-style short, explicit timeouts (same rationale as
  # keycloak_test_client.ex's own @http_options): a down Keycloak should fail this
  # module's own raw :httpc calls fast and clearly, not hang toward ExUnit's default
  # test timeout.
  @http_options [timeout: 5_000, connect_timeout: 2_000]

  # ---------------------------------------------------------------------------------
  # setup_all -- same reachability probe as keycloak_auth_pipeline_test.exs, plus the
  # base URL every test in this module needs to build its own request.
  # ---------------------------------------------------------------------------------

  setup_all do
    {keycloak_port, _bindings} =
      Code.eval_file(Path.expand("../../../config/keycloak_port.exs", __DIR__))

    base_url = "http://localhost:#{keycloak_port}"
    discovery_url = "#{base_url}/realms/#{@realm}/.well-known/openid-configuration"

    unless KeycloakTestClient.discovery_reachable?(discovery_url) do
      raise "Keycloak not ready at #{discovery_url}. Ensure docker-compose services are " <>
              "running (docker compose up -d --force-recreate keycloak) before executing " <>
              "these tests."
    end

    {:ok, base_url: base_url}
  end

  # ---------------------------------------------------------------------------------
  # Shared PKCE fixture -- a freshly generated S256 challenge, same shape a real
  # flutter_appauth call would produce. Keycloak's authorization endpoint only checks
  # the challenge's presence/method at this step (the verifier is checked later, at
  # token exchange, which this module never reaches) -- a random, well-formed
  # verifier/challenge pair is sufficient for every AC3 assertion below.
  # ---------------------------------------------------------------------------------

  defp fresh_pkce_challenge do
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
  end

  defp authorization_url(base_url, params) do
    query = URI.encode_query(params)
    "#{base_url}/realms/#{@realm}/protocol/openid-connect/auth?#{query}"
  end

  # Raw, no-redirect-follow GET -- `autoredirect: false` is the whole point: AC3b/AC3c
  # need to see Keycloak's own 3xx/4xx response (status + headers + body) directly,
  # never a `:httpc`-followed hop to wherever a `Location` header points.
  defp raw_get(url) do
    KeycloakTestClient.ensure_started()

    request = {String.to_charlist(url), []}
    http_options = @http_options ++ [autoredirect: false]

    case :httpc.request(:get, request, http_options, body_format: :binary) do
      {:ok, {{_http_version, status, _reason_phrase}, headers, body}} ->
        {:ok, %{status: status, headers: normalize_headers(headers), body: to_string(body)}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp normalize_headers(headers) do
    Enum.into(headers, %{}, fn {key, value} ->
      {key |> to_string() |> String.downcase(), to_string(value)}
    end)
  end

  # ---------------------------------------------------------------------------------
  # AC3a -- a fully valid PKCE authorization request returns the login page.
  # ---------------------------------------------------------------------------------

  describe "AC3a — valid PKCE authorization request returns the login page" do
    test "client_id=letflow-mobile, registered redirect_uri, response_type=code, S256 code_challenge -> HTTP 200",
         %{base_url: base_url} do
      url =
        authorization_url(base_url, %{
          "client_id" => @mobile_client_id,
          "redirect_uri" => @redirect_uri,
          "response_type" => "code",
          "scope" => "openid",
          "code_challenge" => fresh_pkce_challenge(),
          "code_challenge_method" => "S256"
        })

      assert {:ok, response} = raw_get(url)

      assert response.status == 200,
             "expected the login page (HTTP 200) for a fully valid PKCE request, " <>
               "got status #{response.status}, body: #{String.slice(response.body, 0, 500)}"

      assert response.headers["content-type"] =~ "text/html"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3b -- a redirect_uri that is not on letflow-mobile's registered list must be
  # rejected without ever redirecting to it. redirectUris == ["com.bizdala.letflow:/oauth2redirect"]
  # (design §1.2) is the field this proves is enforced, not merely declared.
  # ---------------------------------------------------------------------------------

  describe "AC3b — mismatched redirect_uri is rejected and never redirected to" do
    test "redirect_uri=https://evil.example/cb -> non-200 error naming redirect_uri, no redirect to evil.example",
         %{base_url: base_url} do
      url =
        authorization_url(base_url, %{
          "client_id" => @mobile_client_id,
          "redirect_uri" => @evil_redirect_uri,
          "response_type" => "code",
          "scope" => "openid",
          "code_challenge" => fresh_pkce_challenge(),
          "code_challenge_method" => "S256"
        })

      assert {:ok, response} = raw_get(url)

      refute response.status == 200,
             "expected a non-200 error response for an unregistered redirect_uri, got 200 " <>
               "(the login page), body: #{String.slice(response.body, 0, 500)}"

      # Keycloak cannot safely redirect an error back to a redirect_uri it does not
      # trust in the first place -- it renders an error page directly instead of a 3xx.
      # Assert both possible shapes never point at evil.example: no Location header
      # naming it, and the response is not itself a redirect to it.
      location = response.headers["location"]

      refute is_binary(location) and String.contains?(location, "evil.example"),
             "response redirected to evil.example via Location header: #{inspect(location)}"

      refute String.contains?(response.body, "evil.example") and
               response.status in [301, 302, 303, 307, 308],
             "response body/status suggests a redirect toward evil.example"

      assert String.downcase(response.body) =~ "redirect_uri",
             "expected the error response body to name redirect_uri, got: " <>
               String.slice(response.body, 0, 500)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3c -- a request with no code_challenge at all must be rejected, proving
  # attributes."pkce.code.challenge.method": "S256" (design §1.2) is enforced
  # server-side, not merely a client-side convention this design assumes.
  # ---------------------------------------------------------------------------------

  describe "AC3c — missing code_challenge is rejected (server-side PKCE enforcement)" do
    test "no code_challenge/code_challenge_method is rejected, not the login page",
         %{base_url: base_url} do
      url =
        authorization_url(base_url, %{
          "client_id" => @mobile_client_id,
          "redirect_uri" => @redirect_uri,
          "response_type" => "code",
          "scope" => "openid"
        })

      assert {:ok, response} = raw_get(url)

      login_page? =
        response.status == 200 and response.headers["content-type"] =~ "text/html" and
          String.downcase(response.body) =~ "kc-form-login"

      refute login_page?,
             "expected PKCE enforcement to reject this request, but got what looks like the " <>
               "login page (status #{response.status})"

      location = response.headers["location"]

      cond do
        # Shape 1: a redirect back to the registered custom-scheme redirect_uri, carrying
        # error=invalid_request in its query string (the AC's explicitly allowed
        # redirect shape).
        is_binary(location) and String.starts_with?(location, @redirect_uri) ->
          assert location =~ "error=invalid_request",
                 "redirected to the registered redirect_uri, but without error=invalid_request: #{location}"

        # Shape 2: an error rendered directly in the response body, naming the missing
        # parameter.
        true ->
          assert String.downcase(response.body) =~ "code_challenge",
                 "expected the error response to name code_challenge or code_challenge_method, " <>
                   "got status #{response.status}, body: #{String.slice(response.body, 0, 500)}, " <>
                   "location: #{inspect(location)}"
      end
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- Keycloak's own admin evaluate-scopes endpoint proves the mandatory
  # oidc-audience-mapper (design §1.4) actually produces the right aud/azp shape.
  # ---------------------------------------------------------------------------------

  describe "AC4 — evaluate-scopes example access token has the right aud/azp shape" do
    test "aud contains letflow-web, azp is letflow-mobile", %{base_url: base_url} do
      admin_token_url = "#{base_url}/realms/master/protocol/openid-connect/token"

      assert {:ok, admin_token} =
               KeycloakTestClient.direct_access_token(admin_token_url, "admin", "admin",
                 client_id: "admin-cli"
               )

      auth_header = {~c"authorization", String.to_charlist("Bearer " <> admin_token)}

      mobile_internal_id = fetch_client_internal_id!(base_url, auth_header, @mobile_client_id)
      admin_user_id = fetch_user_id!(base_url, auth_header, "admin-user")

      evaluate_url =
        "#{base_url}/admin/realms/#{@realm}/clients/#{mobile_internal_id}" <>
          "/evaluate-scopes/generate-example-access-token?userId=#{admin_user_id}"

      assert {:ok, claims} = authenticated_get_json(evaluate_url, auth_header)

      aud = Map.get(claims, "aud")
      azp = Map.get(claims, "azp")

      aud_list = List.wrap(aud)

      assert "letflow-web" in aud_list,
             "expected example access token's aud to contain \"letflow-web\", got: #{inspect(aud)}"

      assert azp == "letflow-mobile",
             "expected example access token's azp to equal \"letflow-mobile\", got: #{inspect(azp)}"
    end
  end

  # ---- AC4 admin-API helpers ----------------------------------------------------

  defp authenticated_get_json(url, auth_header) do
    KeycloakTestClient.ensure_started()

    request = {String.to_charlist(url), [auth_header]}

    case :httpc.request(:get, request, @http_options, body_format: :binary) do
      {:ok, {{_http_version, 200, _reason_phrase}, _headers, body}} ->
        Jason.decode(to_string(body))

      {:ok, {{_http_version, status, _reason_phrase}, _headers, body}} ->
        {:error, {:http_error, status, to_string(body)}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp fetch_client_internal_id!(base_url, auth_header, client_id) do
    url = "#{base_url}/admin/realms/#{@realm}/clients?clientId=#{client_id}"

    assert {:ok, [%{"id" => internal_id} | _rest]} = authenticated_get_json(url, auth_header)

    internal_id
  end

  defp fetch_user_id!(base_url, auth_header, username) do
    url = "#{base_url}/admin/realms/#{@realm}/users?username=#{username}"

    assert {:ok, [%{"id" => user_id} | _rest]} = authenticated_get_json(url, auth_header)

    user_id
  end
end
