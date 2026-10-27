defmodule Letflow.TenantProvisioner.Config do
  @moduledoc """
  REQ-572 / decision 0072 D6: the pure parser behind `config/runtime.exs` for the provisioner
  credential. It takes a map of the OS environment and returns the application config to write, or
  `{:error, variable_name}`; a raise in `runtime.exs` names the variable and never a value (INV-4).

  | Variable | Meaning | Unset |
  |---|---|---|
  | `LETFLOW_PROVISIONER_CREDENTIAL_SHA256` | SHA-256 (64 lowercase hex) of the write credential | `/admin/v1` answers 404 |
  | `LETFLOW_PROVISIONER_READONLY_CREDENTIAL_SHA256` | the same, for the read-only class (GET only) | no read class |
  | `LETFLOW_PROVISIONER_ALLOWED_HOSTNAME_SUFFIXES` | comma-separated suffixes a tenant hostname must end in | every hostname refused |
  | `LETFLOW_PROVISIONER_DEMO_LIFETIME_DAYS` | default `expires_at` offset (1..3650) | 14 |
  | `LETFLOW_PROVISIONER_RETENTION_DAYS` | days a deactivated tenant's data is kept before purge (0..3650) | 30 |
  | `LETFLOW_PROVISIONER_DEMO_CAP` | most demo tenants (lifecycle not deleted) before a create answers 409 (0..100000) | 30 |
  | `LETFLOW_PROVISIONER_DEMO_ALARM_THRESHOLD` | demo count at which a create logs one warning (0..100000) | 25 |
  | `LETFLOW_PROVISIONER_SWEEP_INTERVAL_MINUTES` | minutes between scheduled sweeps (1..10080) | 60 |
  | `LETFLOW_PROVISIONER_DEMO_CAP` | most demo tenants (lifecycle not deleted) before a create answers 409 (0..100000) | 30 |
  | `LETFLOW_PROVISIONER_DEMO_ALARM_THRESHOLD` | demo count at which a create logs one warning (0..100000) | 25 |
  | `LETFLOW_PROVISIONER_SWEEP_INTERVAL_MINUTES` | minutes between scheduled sweeps (1..10080) | 60 |
  | `LETFLOW_PUBLIC_BASE_URL` | the `server_url` of the create answer (the REQ-441 variable) | create answers 500 |

  The write and read hashes must differ (otherwise the write class would silently win).
  """

  alias Letflow.LoginDiscovery.Notifier.Smtp.Config, as: SmtpConfig

  @hash_vars [
    {"LETFLOW_PROVISIONER_CREDENTIAL_SHA256", :write_sha256},
    {"LETFLOW_PROVISIONER_READONLY_CREDENTIAL_SHA256", :read_sha256}
  ]
  @suffixes_var "LETFLOW_PROVISIONER_ALLOWED_HOSTNAME_SUFFIXES"
  @days_var "LETFLOW_PROVISIONER_DEMO_LIFETIME_DAYS"
  @retention_var "LETFLOW_PROVISIONER_RETENTION_DAYS"
  @default_retention_days 30
  @demo_cap_var "LETFLOW_PROVISIONER_DEMO_CAP"
  @alarm_var "LETFLOW_PROVISIONER_DEMO_ALARM_THRESHOLD"
  @interval_var "LETFLOW_PROVISIONER_SWEEP_INTERVAL_MINUTES"
  @default_demo_cap 30
  @default_alarm_threshold 25
  @default_sweep_interval_minutes 60
  @url_var "LETFLOW_PUBLIC_BASE_URL"

  @type parsed :: %{
          auth: keyword(),
          provisioner: keyword(),
          public_base_url: String.t() | nil
        }

  @doc "Parses the provisioner variables of `env` (a map of name => value or nil)."
  @spec parse(map(), atom()) :: {:ok, parsed()} | {:error, String.t()}
  def parse(env, config_env) do
    with {:ok, auth} <- parse_hashes(env),
         {:ok, suffixes} <- parse_suffixes(env),
         {:ok, days} <- parse_days(env),
         {:ok, retention} <- parse_retention(env),
         {:ok, demo_cap} <- parse_int(env, @demo_cap_var, 0..100_000),
         {:ok, alarm} <- parse_int(env, @alarm_var, 0..100_000),
         {:ok, interval} <- parse_int(env, @interval_var, 1..10_080),
         {:ok, url} <- parse_url(env, config_env) do
      provisioner =
        Enum.reject(
          [
            allowed_hostname_suffixes: suffixes,
            demo_lifetime_days: days,
            retention_days: retention,
            demo_cap: demo_cap,
            demo_alarm_threshold: alarm,
            sweep_interval_minutes: interval
          ],
          fn {_key, value} -> is_nil(value) end
        )

      {:ok, %{auth: auth, provisioner: provisioner, public_base_url: url}}
    end
  end

  @doc "True for exactly 64 lowercase hexadecimal characters."
  @spec valid_hash?(term()) :: boolean()
  def valid_hash?(value) when is_binary(value), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  def valid_hash?(_other), do: false

  defp parse_hashes(env) do
    hashes =
      Enum.reduce_while(@hash_vars, {:ok, []}, fn {name, key}, {:ok, acc} ->
        case blank_to_nil(Map.get(env, name)) do
          nil ->
            {:cont, {:ok, acc}}

          value ->
            if valid_hash?(value),
              do: {:cont, {:ok, [{key, value} | acc]}},
              else: {:halt, {:error, name}}
        end
      end)

    with {:ok, auth} <- hashes do
      if Keyword.has_key?(auth, :write_sha256) and
           Keyword.get(auth, :write_sha256) == Keyword.get(auth, :read_sha256) do
        {:error, "LETFLOW_PROVISIONER_READONLY_CREDENTIAL_SHA256"}
      else
        {:ok, Enum.sort(auth)}
      end
    end
  end

  defp parse_suffixes(env) do
    case blank_to_nil(Map.get(env, @suffixes_var)) do
      nil ->
        {:ok, nil}

      text ->
        suffixes =
          text
          |> String.split(",", trim: true)
          |> Enum.map(&(&1 |> String.trim() |> String.downcase()))

        if suffixes != [] and Enum.all?(suffixes, &suffix?/1),
          do: {:ok, suffixes},
          else: {:error, @suffixes_var}
    end
  end

  defp suffix?(value),
    do:
      byte_size(value) <= 200 and
        Regex.match?(
          ~r/\A([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+\z/,
          value
        )

  defp parse_days(env) do
    case blank_to_nil(Map.get(env, @days_var)) do
      nil ->
        {:ok, nil}

      text ->
        case Integer.parse(text) do
          {n, ""} when n in 1..3650 -> {:ok, n}
          _other -> {:error, @days_var}
        end
    end
  end

  # 0..3650, unlike the demo lifetime (1..3650): 0 means "purge as soon as the tenant is deactivated".
  defp parse_retention(env) do
    case blank_to_nil(Map.get(env, @retention_var)) do
      nil ->
        {:ok, nil}

      text ->
        case Integer.parse(text) do
          {n, ""} when n in 0..3650 -> {:ok, n}
          _other -> {:error, @retention_var}
        end
    end
  end

  @doc "REQ-580: days a deactivated tenant's data is kept before purge (setting, default 30)."
  @spec retention_days() :: non_neg_integer()
  def retention_days do
    :letflow
    |> Application.get_env(Letflow.TenantProvisioner, [])
    |> Keyword.get(:retention_days, @default_retention_days)
  end

  defp parse_int(env, var, range) do
    case blank_to_nil(Map.get(env, var)) do
      nil ->
        {:ok, nil}

      text ->
        case Integer.parse(text) do
          {n, ""} -> if n in range, do: {:ok, n}, else: {:error, var}
          _other -> {:error, var}
        end
    end
  end

  @doc "REQ-572 criterion 19: most demo tenants (lifecycle not `deleted`) before a create answers 409 (default 30)."
  @spec demo_cap() :: non_neg_integer()
  def demo_cap, do: setting(:demo_cap, @default_demo_cap)

  @doc "REQ-572 criterion 19: demo count at which a create logs one warning (default 25)."
  @spec demo_alarm_threshold() :: non_neg_integer()
  def demo_alarm_threshold, do: setting(:demo_alarm_threshold, @default_alarm_threshold)

  @doc "REQ-572 criterion 19: minutes between scheduled sweeps (default 60)."
  @spec sweep_interval_minutes() :: pos_integer()
  def sweep_interval_minutes,
    do: setting(:sweep_interval_minutes, @default_sweep_interval_minutes)

  defp setting(key, default) do
    :letflow
    |> Application.get_env(Letflow.TenantProvisioner, [])
    |> Keyword.get(key, default)
  end

  defp parse_url(env, config_env) do
    case blank_to_nil(Map.get(env, @url_var)) do
      nil ->
        {:ok, nil}

      url ->
        case SmtpConfig.validate_base_url(url, config_env) do
          {:ok, trimmed} -> {:ok, trimmed}
          :error -> {:error, @url_var}
        end
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_other), do: nil
end
