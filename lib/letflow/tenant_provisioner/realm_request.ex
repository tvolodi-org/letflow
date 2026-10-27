defmodule Letflow.TenantProvisioner.RealmRequest do
  @moduledoc """
  The pure builder of the realm-creation request that infra's provisioner sends to the
  identity provider (REQ-572 criterion 16, decision 0072 D2 and section 9 step 3).

  Letflow holds no identity-provider admin client (D1): this module only builds the JSON
  body; it does no I/O at call time. The template
  (`priv/keycloak/provisioner/v2/tenant-realm.json`, the current version; v1 is frozen) is
  read and decoded at compile time.

  What the builder fills in:

    * the realm name, `Request.realm_for/1`: `t-` + the first 20 hex digits of the canonical
      tenant id, matching `^t-[0-9a-f]{20}$`; any other `tenant_id` gives
      `{:error, :invalid_realm_id}`;
    * the tenant host in the client redirect URIs and web origins. `hostname` must already
      be validated against the suffix allow-list (`Request.hostname/2` at the route); the
      builder only refuses an empty value, a wildcard and anything that is not a host name;
    * `smtpServer`, an argument (INV-4: it carries a secret and is never part of the template);
    * one inline first administrator (D2): `owner_email` trimmed and lower-cased, enabled,
      `emailVerified`, `realmRoles` `["default-roles-<realm>"]`, and no admin role, group,
      client role or credential (P7, P11). The initial password is the provisioner's.

  Errors never echo the SMTP map or the e-mail.
  """

  alias Letflow.Identity.PendingAdminGrants
  alias Letflow.Identity.Tenant
  alias Letflow.TenantProvisioner.Request

  @template_path Path.expand("../../../priv/keycloak/provisioner/v2/tenant-realm.json", __DIR__)
  @external_resource @template_path
  @template @template_path |> File.read!() |> Jason.decode!()

  @canonical_uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @host_regex ~r/\A[a-z0-9]([a-z0-9.-]*[a-z0-9])?\z/
  @placeholder ~r/__[A-Z_]+__/

  @type error :: :invalid_realm_id | :invalid_owner_email | :invalid_hostname | :invalid_smtp

  @doc "The decoded v2 template, with its placeholders (read-only; for tests)."
  @spec template() :: map()
  def template, do: @template

  @doc "Builds the realm request body for `tenant_id`; see the moduledoc."
  @spec build(term(), term(), term(), term()) :: {:ok, map()} | {:error, error()}
  def build(tenant_id, owner_email, hostname, smtp) do
    with {:ok, realm} <- realm(tenant_id),
         {:ok, email} <- email(owner_email),
         {:ok, host} <- host(hostname),
         {:ok, smtp} <- smtp(smtp) do
      body =
        @template
        |> fill(%{"__REALM_ID__" => realm, "__TENANT_HOST__" => host})
        |> Map.update("attributes", %{}, &Map.put(&1, "tenant_id", tenant_id))
        |> Map.put("smtpServer", smtp)
        |> Map.put("users", [admin(realm, email)])

      if leftover?(body), do: {:error, :invalid_hostname}, else: {:ok, body}
    end
  end

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

  defp smtp(%{} = smtp), do: {:ok, smtp}
  defp smtp(_other), do: {:error, :invalid_smtp}

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

  # Only the template part is scanned: the SMTP argument is the caller's own data.
  defp leftover?(body) do
    body |> Map.delete("smtpServer") |> Jason.encode!() |> then(&Regex.match?(@placeholder, &1))
  end
end
