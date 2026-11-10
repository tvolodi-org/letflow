defmodule Letflow.Signup.RealmProvisioner do
  @moduledoc """
  T-1593 (TA-SL2b part a, decision 0085): the outbound HTTP client to infra's tenant-provisioner
  (`POST /v1/realms`, `GET /v1/realms/{tenant_id}`). Pure HTTP, no state, no database.

  Letflow holds **no Keycloak credential** (decisions 0072 D1, 0084 D2): the create-realm-only
  credential lives in the provisioner. This module holds only a caller bearer token.

  * **INV-9.** The base URL is operator config, but still checked: `http://` with a loopback or RFC 1918
    IP literal (or exactly `localhost`), explicit port, no userinfo, path, query or fragment. No DNS name
    is resolved, so there is no rebinding surface. `valid_base_url?/1` is also used by `config/runtime.exs`.
  * **INV-4.** The token is read with `System.get_env/1` at call time and never put in `Application` env.
    Every failure is reduced to an atom of a closed set; no request, header, body or exception is logged
    or returned. The response is validated, not trusted (realm name guard of 0072 D3).
  * Uses `:httpc` (started for webhooks, REQ-183): no new dependency.
  """

  @max_body 65_536
  @token_env "LETFLOW_SIGNUP_PROVISIONER_TOKEN"
  @client_id "letflow-web"
  @realm_re ~r/^t-[0-9a-f]{20}$/
  @max_retry_after_ms 30_000

  @type error ::
          :unavailable
          | {:rate_limited, non_neg_integer() | nil}
          | :unauthorized
          | :invalid_request
          | :demo_cap_reached
          | :bad_response
          | :bad_url
          | :not_configured

  @type realm :: %{
          realm: String.t(),
          issuer: String.t(),
          template_version: String.t(),
          username: String.t() | nil,
          password: String.t() | nil
        }

  @doc "Name of the environment variable that holds the caller token (the value is never read into config)."
  @spec token_env() :: String.t()
  def token_env, do: @token_env

  @doc "True for `http://<loopback|RFC 1918 IP|localhost>:<port>` and nothing else."
  @spec valid_base_url?(term()) :: boolean()
  def valid_base_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{
        scheme: "http",
        host: host,
        port: port,
        userinfo: nil,
        query: nil,
        fragment: nil,
        path: path
      }
      when is_binary(host) and is_integer(port) ->
        path in [nil, "", "/"] and Regex.match?(~r{^http://[^/@?#]+:\d+/?$}, url) and
          private_host?(host)

      _other ->
        false
    end
  end

  def valid_base_url?(_other), do: false

  defp private_host?("localhost"), do: true

  defp private_host?(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {10, _, _, _}} -> true
      {:ok, {172, b, _, _}} when b in 16..31 -> true
      {:ok, {192, 168, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _other -> false
    end
  end

  @doc "The realm label derived from a tenant id: `t-` plus the first 20 hex digits of the dashless id."
  @spec label(String.t()) :: String.t()
  def label(tenant_id) do
    "t-" <> (tenant_id |> String.replace("-", "") |> String.downcase() |> binary_part(0, 20))
  end

  @doc """
  Asks the provisioner for the tenant's realm and first admin.

  `{:ok, :created, realm}` on 201 (carries the one-time password), `{:ok, :replay, realm}` on 200 or
  after a 409 resolved through `GET`, otherwise `{:error, code}`.
  """
  @spec create_realm(map(), map()) :: {:ok, :created | :replay, realm()} | {:error, error()}
  def create_realm(%{tenant_id: tenant_id} = request, cfg) do
    body = %{
      tenant_id: tenant_id,
      name: request.company_name,
      language: request.language,
      # Always a demo tenant: production is never provisioned from public sign-up (T-1567 P14).
      tier: "demo",
      owner_email: request.email,
      hostname: label(tenant_id) <> "." <> to_string(cfg.hostname_domain)
    }

    with {:ok, base, token} <- target(cfg),
         {:ok, status, headers, resp} <- http(:post, base <> "/v1/realms", token, body, cfg) do
      case status do
        201 -> validate(resp, tenant_id, :created)
        200 -> validate(resp, tenant_id, :replay)
        409 -> resolve_conflict(resp, tenant_id, base, token, cfg)
        _other -> classify(status, headers, resp)
      end
    end
  end

  defp resolve_conflict(resp, tenant_id, base, token, cfg) do
    if marks_cap?(resp) do
      {:error, :demo_cap_reached}
    else
      case http(:get, base <> "/v1/realms/" <> tenant_id, token, nil, cfg) do
        {:ok, 200, _headers, got} ->
          validate(got, tenant_id, :replay)

        {:ok, 404, _headers, got} ->
          if marks_cap?(got), do: {:error, :demo_cap_reached}, else: {:error, :invalid_request}

        {:ok, _status, _headers, _got} ->
          {:error, :invalid_request}

        {:error, _} = error ->
          error
      end
    end
  end

  defp marks_cap?(resp) do
    case Jason.decode(resp) do
      {:ok, map} when is_map(map) ->
        Enum.any?(["error", "code", "message"], &(Map.get(map, &1) == "demo_cap_reached"))

      _other ->
        false
    end
  end

  defp classify(401, _headers, _resp), do: {:error, :unauthorized}
  defp classify(403, _headers, _resp), do: {:error, :unauthorized}

  defp classify(429, headers, _resp) do
    delay =
      with {_, value} <- List.keyfind(headers, ~c"retry-after", 0),
           {seconds, ""} <- value |> to_string() |> Integer.parse() do
        min(max(seconds, 0) * 1000, @max_retry_after_ms)
      else
        _other -> nil
      end

    {:error, {:rate_limited, delay}}
  end

  defp classify(status, _headers, _resp) when status in 400..499, do: {:error, :invalid_request}
  defp classify(status, _headers, _resp) when status >= 500, do: {:error, :unavailable}
  defp classify(_status, _headers, _resp), do: {:error, :bad_response}

  # ── validation ──────────────────────────────────────────────────────────

  defp validate(resp, tenant_id, kind) do
    expected = label(tenant_id)

    with {:ok, %{} = map} <- Jason.decode(resp),
         true <- same_or_absent?(map, "tenant_id", tenant_id),
         true <- same_or_absent?(map, "tier", "demo"),
         true <- Map.get(map, "realm") == expected and Regex.match?(@realm_re, expected),
         issuer when is_binary(issuer) <- Map.get(map, "issuer"),
         true <- byte_size(issuer) <= 300 and String.starts_with?(issuer, ["https://", "http://"]),
         true <- Map.get(map, "client_id") == @client_id,
         version when is_binary(version) <- Map.get(map, "template_version"),
         true <- byte_size(version) in 1..40,
         {:ok, username, password} <- first_admin(Map.get(map, "first_admin"), kind) do
      {:ok, kind,
       %{
         realm: expected,
         issuer: issuer,
         template_version: version,
         username: username,
         password: password
       }}
    else
      _invalid -> {:error, :bad_response}
    end
  end

  defp same_or_absent?(map, key, expected),
    do: Map.get(map, key) in [nil, expected]

  defp first_admin(%{} = admin, _kind) do
    username = Map.get(admin, "username")
    password = Map.get(admin, "initial_password")

    cond do
      is_binary(password) and byte_size(password) in 1..256 and
          (is_nil(username) or (is_binary(username) and byte_size(username) <= 254)) ->
        {:ok, username, password}

      is_nil(password) and (is_nil(username) or is_binary(username)) ->
        {:ok, nil, nil}

      true ->
        :error
    end
  end

  defp first_admin(nil, _kind), do: {:ok, nil, nil}
  defp first_admin(_other, _kind), do: :error

  # ── transport ───────────────────────────────────────────────────────────

  defp target(cfg) do
    base = cfg.provisioner_url
    token = System.get_env(@token_env)

    cond do
      not is_binary(base) or token in [nil, ""] -> {:error, :not_configured}
      not valid_base_url?(base) -> {:error, :bad_url}
      true -> {:ok, String.trim_trailing(base, "/"), token}
    end
  end

  defp http(method, url, token, body, cfg) do
    headers = [
      {~c"authorization", String.to_charlist("Bearer " <> token)},
      {~c"accept", ~c"application/json"}
    ]

    request =
      if body do
        {String.to_charlist(url), headers, ~c"application/json", Jason.encode!(body)}
      else
        {String.to_charlist(url), headers}
      end

    http_opts = [
      timeout: cfg.http_timeout_ms,
      connect_timeout: cfg.connect_timeout_ms,
      autoredirect: false
    ]

    case :httpc.request(method, request, http_opts, body_format: :binary) do
      {:ok, {{_, status, _}, resp_headers, resp}} when byte_size(resp) <= @max_body ->
        {:ok, status, resp_headers, resp}

      {:ok, {{_, _status, _}, _headers, _oversize}} ->
        {:error, :bad_response}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end
end
