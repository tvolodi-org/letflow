defmodule Letflow.TenantProvisioner.RealmRequest do
  @moduledoc """
  The pure builder of the realm-creation request that infra's provisioner sends to the
  identity provider (REQ-572 criterion 16, decision 0072 D2 and section 9 step 3).

  Letflow holds no identity-provider admin client (D1): this module only builds the JSON
  body; it does no I/O at call time. The template
  (`priv/keycloak/provisioner/v3/tenant-realm.json`, the current version; v1 and v2 are frozen) is
  read and decoded at compile time.

  What the builder fills in:

    * the realm name, `Request.realm_for/1`: `t-` + the first 20 hex digits of the canonical
      tenant id, matching `^t-[0-9a-f]{20}$`; any other `tenant_id` gives
      `{:error, :invalid_realm_id}`;
    * the full 32-hex tenant slug (`Request.slug/1`) in the query-bearing exact callback,
      distinct from the 20-hex IdP realm name;
    * the tenant host in the client redirect URIs and web origins. `hostname` must already
      be validated against the suffix allow-list (`Request.hostname/2` at the route); the
      builder only refuses an empty value, a wildcard and anything that is not a host name;
    * the `letflow-mobile` client (T-2207, template v3): public, standard flow, PKCE `S256`, the native
      redirect plus, when `build/5` gets a `:pwa_uri`, that one exact PWA URI (and its origin as web
      origin, the same URI as post-logout redirect). The PWA URI must be `https://<host>[:port]/<path>/`
      with a host name, no wildcard, userinfo, query or fragment; without `:pwa_uri` the client carries
      the native redirect only. `ensure_mobile_client/2` is the idempotent form for an EXISTING realm:
      it returns the client to create when the realm has none, and `[]` otherwise, so an existing
      client is never overwritten;
    * `smtpServer`, an argument and never part of the template. INV-4 / P11: the output holds
      no plaintext secret, so a secret-named SMTP key (password, secret, key, token,
      credential) is accepted only with a Keycloak vault reference `${vault.<name>}` as its
      value; anything else gives `{:error, :invalid_smtp}` without echoing the value;
    * one inline first administrator (D2): `owner_email` trimmed and lower-cased, enabled,
      `emailVerified`, `realmRoles` `["default-roles-<realm>"]`, and no admin role, group,
      client role or credential (P7, P11). The initial password is the provisioner's.

  Errors never echo the SMTP map or the e-mail.
  """

  alias Letflow.Identity.PendingAdminGrants
  alias Letflow.Identity.Tenant
  alias Letflow.TenantProvisioner.Request

  @template_path Path.expand("../../../priv/keycloak/provisioner/v3/tenant-realm.json", __DIR__)
  @external_resource @template_path
  @template @template_path |> File.read!() |> Jason.decode!()

  @canonical_uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @host_regex ~r/\A[a-z0-9]([a-z0-9.-]*[a-z0-9])?\z/
  @placeholder ~r/__[A-Z_]+__/
  @vault_ref ~r/\A\$\{vault\.[A-Za-z0-9_.-]+\}\z/
  @secret_key_parts ["pass", "secret", "key", "token", "credential"]

  @type error ::
          :invalid_realm_id
          | :invalid_owner_email
          | :invalid_hostname
          | :invalid_smtp
          | :invalid_pwa_uri

  @mobile_client_id "letflow-mobile"
  @pwa_uri_regex ~r|\Ahttps://([a-z0-9]([a-z0-9.-]*[a-z0-9])?)(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?\z|

  @doc "The decoded v3 template, with its placeholders (read-only; for tests)."
  @spec template() :: map()
  def template, do: @template

  @doc "Builds the realm request body for `tenant_id`; see the moduledoc."
  @spec build(term(), term(), term(), term(), keyword()) :: {:ok, map()} | {:error, error()}
  def build(tenant_id, owner_email, hostname, smtp, opts \\ []) do
    with {:ok, realm} <- realm(tenant_id),
         {:ok, email} <- email(owner_email),
         {:ok, host} <- host(hostname),
         {:ok, smtp} <- smtp(smtp),
         {:ok, pwa} <- pwa_uri(Keyword.get(opts, :pwa_uri)) do
      body =
        @template
        |> fill(%{
          "__REALM_ID__" => realm,
          "__TENANT_HOST__" => host,
          "__TENANT_SLUG__" => Request.slug(tenant_id)
        })
        |> fill_pwa(pwa)
        |> Map.update("attributes", %{}, &Map.put(&1, "tenant_id", tenant_id))
        |> Map.put("smtpServer", smtp)
        |> Map.put("users", [admin(realm, email)])

      if leftover?(body), do: {:error, :invalid_hostname}, else: {:ok, body}
    end
  end

  @doc """
  The `letflow-mobile` client to create in an existing realm: `[client]` when `existing_client_ids`
  (the realm's current client ids) does not list it, `[]` when it does. Never an overwrite.
  """
  @spec ensure_mobile_client([String.t()], String.t() | nil) ::
          {:ok, [map()]} | {:error, :invalid_pwa_uri}
  def ensure_mobile_client(existing_client_ids, pwa_uri) when is_list(existing_client_ids) do
    with {:ok, pwa} <- pwa_uri(pwa_uri) do
      if @mobile_client_id in existing_client_ids do
        {:ok, []}
      else
        client = Enum.find(@template["clients"], &(&1["clientId"] == @mobile_client_id))
        {:ok, [fill_pwa_client(client, pwa)]}
      end
    end
  end

  defp pwa_uri(nil), do: {:ok, nil}

  defp pwa_uri(uri) when is_binary(uri) do
    with true <- byte_size(uri) <= 300 and Regex.match?(@pwa_uri_regex, uri),
         %URI{host: host, port: port} <- URI.parse(uri),
         true <- is_integer(port) and port in 1..65_535 do
      {:ok, {uri, "https://" <> host <> if(port == 443, do: "", else: ":#{port}")}}
    else
      _invalid -> {:error, :invalid_pwa_uri}
    end
  end

  defp pwa_uri(_other), do: {:error, :invalid_pwa_uri}

  defp fill_pwa(body, pwa) do
    Map.update!(body, "clients", fn clients ->
      Enum.map(clients, fn
        %{"clientId" => @mobile_client_id} = client -> fill_pwa_client(client, pwa)
        other -> other
      end)
    end)
  end

  defp fill_pwa_client(client, nil) do
    client
    |> Map.update!("redirectUris", &Enum.reject(&1, fn u -> u == "__PWA_URI__" end))
    |> Map.put("webOrigins", [])
    |> put_in(["attributes", "post.logout.redirect.uris"], "com.bizdala.letflow:/oauth2redirect")
  end

  defp fill_pwa_client(client, {uri, origin}),
    do: fill(client, %{"__PWA_URI__" => uri, "__PWA_ORIGIN__" => origin})

  defp realm(tenant_id) when is_binary(tenant_id) do
    realm = Request.realm_for(tenant_id)

    if Regex.match?(@canonical_uuid, tenant_id) and Tenant.realm_id_format?(realm) and
         not Tenant.reserved_realm_id?(realm),
       do: {:ok, realm},
       else: {:error, :invalid_realm_id}
  end

  defp realm(_other), do: {:error, :invalid_realm_id}

  defp email(raw) do
    case PendingAdminGrants.normalize_email(raw) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, :invalid_owner_email}
    end
  end

  defp host(raw) when is_binary(raw) do
    if Regex.match?(@host_regex, raw), do: {:ok, raw}, else: {:error, :invalid_hostname}
  end

  defp host(_other), do: {:error, :invalid_hostname}

  defp smtp(%{} = smtp),
    do: if(plain_secret?(smtp), do: {:error, :invalid_smtp}, else: {:ok, smtp})

  defp smtp(_other), do: {:error, :invalid_smtp}

  # A secret-named key is accepted only with a Keycloak vault reference as its value.
  defp plain_secret?(%{} = map) do
    Enum.any?(map, fn {k, v} ->
      if secret_key?(k), do: not vault_ref?(v), else: plain_secret?(v)
    end)
  end

  defp plain_secret?(list) when is_list(list), do: Enum.any?(list, &plain_secret?/1)
  defp plain_secret?(_other), do: false

  defp secret_key?(key),
    do: key |> to_string() |> String.downcase() |> String.contains?(@secret_key_parts)

  defp vault_ref?(value), do: is_binary(value) and Regex.match?(@vault_ref, value)

  defp admin(realm, email) do
    %{
      "username" => email,
      "email" => email,
      "enabled" => true,
      "emailVerified" => true,
      "realmRoles" => ["default-roles-" <> realm]
    }
  end

  defp fill(value, subs) when is_binary(value),
    do: Enum.reduce(subs, value, fn {from, to}, acc -> String.replace(acc, from, to) end)

  defp fill(%{} = map, subs), do: Map.new(map, fn {k, v} -> {k, fill(v, subs)} end)
  defp fill(list, subs) when is_list(list), do: Enum.map(list, &fill(&1, subs))
  defp fill(other, _subs), do: other

  defp leftover?(body), do: body |> Jason.encode!() |> then(&Regex.match?(@placeholder, &1))
end
