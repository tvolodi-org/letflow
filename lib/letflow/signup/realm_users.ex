defmodule Letflow.Signup.RealmUsers do
  @moduledoc """
  T-1730 (REQ-807, decision 0072 section 8b, 0085 D3/D4/D11): the outbound HTTP client to infra's
  tenant-provisioner for ONE call: create a login for one user inside the tenant's own realm.
  Pure HTTP, no state, no database. Off unless `LETFLOW_REALM_USERS_ENABLED=true`.

  **Flagged assumption.** Infra has not published the wire contract. The path and the field names are
  module attributes below (`@path`, `@req_*`, `@resp_*`): `POST {base}/v1/realms/{tenant_id}/users`,
  request `{username, email, display_name}`, success 201 `{realm, user_id, temporary_password}`. Whoever
  turns the flag on must first check them against infra's published contract.

  * **INV-9.** The base URL is operator config but is re-checked on every call with
    `RealmProvisioner.valid_base_url?/1` before any request.
  * **INV-4.** The token is read with `System.get_env/1` at call time, never kept in `Application` env.
    The temporary password is returned to the caller and nowhere else: this module has no `Logger` call
    and returns no request, header, body or exception. Every failure is an atom of a closed set.
  * No retries: a retry after a lost 201 would meet `:login_exists`; the administrator retries by hand.
  """

  alias Letflow.Signup.RealmProvisioner

  @max_body 65_536
  @token_env "LETFLOW_REALM_USERS_PROVISIONER_TOKEN"
  @path "/v1/realms/"
  @path_suffix "/users"
  @req_username "username"
  @req_email "email"
  @req_display_name "display_name"
  @resp_realm "realm"
  @resp_user_id "user_id"
  @resp_password "temporary_password"

  @type error ::
          :not_configured
          | :bad_url
          | :unavailable
          | :rate_limited
          | :unauthorized
          | :login_exists
          | :realm_not_provisioned
          | :invalid_request
          | :bad_response

  @doc "Name of the environment variable that holds the caller token (never read into config)."
  @spec token_env() :: String.t()
  def token_env, do: @token_env

  @doc "True only when the boot-time flag is exactly `true`."
  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.get(config(), :enabled) == true

  @doc "Flag on, base URL set and token present. Presence only; the token value is never exposed."
  @spec configured?() :: boolean()
  def configured? do
    url = Keyword.get(config(), :provisioner_url)
    enabled?() and is_binary(url) and url != "" and System.get_env(@token_env) not in [nil, ""]
  end

  @doc "Asks the provisioner to create the login. See the moduledoc for the closed error set."
  @spec create_login(String.t(), %{
          username: String.t(),
          email: String.t(),
          display_name: String.t()
        }) ::
          {:ok, %{user_id: String.t(), temporary_password: String.t()}} | {:error, error()}
  def create_login(tenant_id, %{username: username, email: email, display_name: display_name})
      when is_binary(tenant_id) do
    body = %{
      @req_username => username,
      @req_email => email,
      @req_display_name => display_name
    }

    with {:ok, base, token} <- target() do
      url = base <> @path <> tenant_id <> @path_suffix

      case http(url, token, body) do
        {:ok, 201, resp} -> validate(resp, tenant_id)
        {:ok, status, _resp} -> classify(status)
        {:error, _} = error -> error
      end
    end
  end

  defp classify(409), do: {:error, :login_exists}
  defp classify(404), do: {:error, :realm_not_provisioned}
  defp classify(status) when status in [401, 403], do: {:error, :unauthorized}
  defp classify(429), do: {:error, :rate_limited}
  defp classify(status) when status in 400..499, do: {:error, :invalid_request}
  defp classify(status) when status >= 500, do: {:error, :unavailable}
  defp classify(_status), do: {:error, :bad_response}

  defp validate(resp, tenant_id) do
    expected = RealmProvisioner.label(tenant_id)

    with {:ok, %{} = map} <- Jason.decode(resp),
         true <- Map.get(map, @resp_realm) == expected,
         user_id when is_binary(user_id) <- Map.get(map, @resp_user_id),
         {:ok, cast} <- Ecto.UUID.cast(user_id),
         true <- cast == String.downcase(user_id),
         password when is_binary(password) <- Map.get(map, @resp_password),
         true <- byte_size(password) in 1..256 do
      {:ok, %{user_id: cast, temporary_password: password}}
    else
      _invalid -> {:error, :bad_response}
    end
  end

  defp config, do: Application.get_env(:letflow, __MODULE__, [])

  defp target do
    base = Keyword.get(config(), :provisioner_url)
    token = System.get_env(@token_env)

    cond do
      not is_binary(base) or token in [nil, ""] -> {:error, :not_configured}
      not RealmProvisioner.valid_base_url?(base) -> {:error, :bad_url}
      true -> {:ok, String.trim_trailing(base, "/"), token}
    end
  end

  defp http(url, token, body) do
    headers = [
      {~c"authorization", String.to_charlist("Bearer " <> token)},
      {~c"accept", ~c"application/json"}
    ]

    request = {String.to_charlist(url), headers, ~c"application/json", Jason.encode!(body)}

    http_opts = [
      timeout: Keyword.get(config(), :http_timeout_ms, 5_000),
      connect_timeout: Keyword.get(config(), :connect_timeout_ms, 2_000),
      autoredirect: false
    ]

    case :httpc.request(:post, request, http_opts, body_format: :binary) do
      {:ok, {{_, status, _}, _headers, resp}} when byte_size(resp) <= @max_body ->
        {:ok, status, resp}

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
