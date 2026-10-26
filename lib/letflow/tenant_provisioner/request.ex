defmodule Letflow.TenantProvisioner.Request do
  @moduledoc """
  REQ-572 / decision 0072: the pure validation of the create body of `POST /admin/v1/tenants`.
  No I/O, no `Repo`. Every rule is checked before any write; an error names the FIELD only and never
  echoes the value (INV-4, INV-8).

  | Field | Rule |
  |---|---|
  | `tenant_id` | a UUID (`Ecto.UUID.cast/1`); the canonical lowercase form is used everywhere (P8) |
  | `name` | string, trimmed, 1..200 graphemes and code points |
  | `language` | `ru`, `kk` or `en` |
  | `tier` | `demo` only; `production` is refused (P14, decision 0072 D6) |
  | `owner_email` | `PendingAdminGrants.normalize_email/1` |
  | `hostname` | one label + `.` + a configured suffix (D5b) |
  | `idp_realm_id` | `t-` + the first 20 hex digits of the tenant id (P13) |
  | `expires_at` | optional ISO 8601 UTC in the future; default now + the demo lifetime |
  """

  alias Letflow.Identity.PendingAdminGrants
  alias Letflow.Identity.Tenant

  @keys ~w(tenant_id name language tier owner_email hostname idp_realm_id expires_at)
  @required ~w(tenant_id name language tier owner_email hostname idp_realm_id)
  @languages ~w(ru kk en)
  @label_regex ~r/\A[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\z/
  @canonical_uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @default_lifetime_days 14

  @type t :: %{
          tenant_id: String.t(),
          name: String.t(),
          language: String.t(),
          tier: String.t(),
          email_key: String.t(),
          hostname: String.t(),
          idp_realm_id: String.t(),
          expires_at: DateTime.t()
        }

  @doc """
  Validates a decoded JSON body. `{:ok, request}` or `{:error, field}` (the first failing field, as a
  string; `"body"` for a body that is not an object or has an unknown key).
  """
  @spec parse(term(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def parse(body, opts \\ [])

  def parse(%{} = body, opts) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    with :ok <- known_keys(body),
         :ok <- required_keys(body),
         {:ok, tenant_id} <- tenant_id(body["tenant_id"]),
         {:ok, name} <- name(body["name"]),
         {:ok, language} <- language(body["language"]),
         {:ok, tier} <- tier(body["tier"]),
         {:ok, email_key} <- email(body["owner_email"]),
         {:ok, hostname} <- hostname(body["hostname"], suffixes()),
         {:ok, realm} <- realm(body["idp_realm_id"], tenant_id),
         {:ok, expires_at} <- expires_at(Map.get(body, "expires_at"), now) do
      {:ok,
       %{
         tenant_id: tenant_id,
         name: name,
         language: language,
         tier: tier,
         email_key: email_key,
         hostname: hostname,
         idp_realm_id: realm,
         expires_at: expires_at
       }}
    end
  end

  def parse(_other, _opts), do: {:error, "body"}

  @doc "The slug of a provisioned tenant: `t-` + the 32 hex digits of its id."
  @spec slug(String.t()) :: String.t()
  def slug(tenant_id), do: "t-" <> String.replace(tenant_id, "-", "")

  @doc "The realm a tenant id must bind: `t-` + the first 20 hex digits (decision 0072 P13)."
  @spec realm_for(String.t()) :: String.t()
  def realm_for(tenant_id), do: "t-" <> String.slice(String.replace(tenant_id, "-", ""), 0, 20)

  @doc "Validates a hostname against `suffixes` (a list of lowercase suffixes)."
  @spec hostname(term(), [String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def hostname(raw, suffixes) when is_binary(raw) do
    host = raw |> String.trim() |> String.downcase()

    with true <- byte_size(host) in 1..253,
         [suffix] <- Enum.filter(suffixes, &String.ends_with?(host, "." <> &1)) |> Enum.take(1),
         label = binary_part(host, 0, byte_size(host) - byte_size(suffix) - 1),
         true <- Regex.match?(@label_regex, label) do
      {:ok, host}
    else
      _invalid -> {:error, "hostname"}
    end
  end

  def hostname(_raw, _suffixes), do: {:error, "hostname"}

  defp suffixes do
    :letflow
    |> Application.get_env(Letflow.TenantProvisioner, [])
    |> Keyword.get(:allowed_hostname_suffixes, [])
  end

  defp known_keys(body),
    do: if(Enum.all?(Map.keys(body), &(&1 in @keys)), do: :ok, else: {:error, "body"})

  defp required_keys(body) do
    case Enum.find(@required, &(not Map.has_key?(body, &1))) do
      nil -> :ok
      missing -> {:error, missing}
    end
  end

  defp tenant_id(raw) when is_binary(raw) do
    # Decision 0072 P8: only the canonical lower-case form; Ecto.UUID.cast would accept
    # upper-case, braced or unhyphenated forms and normalise them.
    with true <- Regex.match?(@canonical_uuid, raw),
         {:ok, uuid} <- Ecto.UUID.cast(raw) do
      {:ok, uuid}
    else
      _other -> {:error, "tenant_id"}
    end
  end

  defp tenant_id(_raw), do: {:error, "tenant_id"}

  defp name(raw) when is_binary(raw) do
    trimmed = String.trim(raw)

    if String.length(trimmed) in 1..200 and length(String.to_charlist(trimmed)) <= 200,
      do: {:ok, trimmed},
      else: {:error, "name"}
  end

  defp name(_raw), do: {:error, "name"}

  defp language(raw) when raw in @languages, do: {:ok, raw}
  defp language(_raw), do: {:error, "language"}

  defp tier("demo"), do: {:ok, "demo"}
  defp tier(_raw), do: {:error, "tier"}

  defp email(raw) do
    case PendingAdminGrants.normalize_email(raw) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, "owner_email"}
    end
  end

  defp realm(raw, tenant_id) when is_binary(raw) do
    trimmed = String.trim(raw)

    if Tenant.realm_id_format?(trimmed) and not Tenant.reserved_realm_id?(trimmed) and
         trimmed == realm_for(tenant_id),
       do: {:ok, trimmed},
       else: {:error, "idp_realm_id"}
  end

  defp realm(_raw, _tenant_id), do: {:error, "idp_realm_id"}

  defp expires_at(nil, now), do: {:ok, DateTime.add(now, lifetime_days() * 86_400, :second)}

  defp expires_at(raw, now) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, at, 0} ->
        if DateTime.compare(at, now) == :gt, do: {:ok, at}, else: {:error, "expires_at"}

      _invalid ->
        {:error, "expires_at"}
    end
  end

  defp expires_at(_raw, _now), do: {:error, "expires_at"}

  defp lifetime_days do
    :letflow
    |> Application.get_env(Letflow.TenantProvisioner, [])
    |> Keyword.get(:demo_lifetime_days, @default_lifetime_days)
  end
end
