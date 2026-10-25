defmodule Letflow.LoginDiscovery.Notifier.Smtp.Config do
  @moduledoc """
  Pure parse/validate of the mail-adapter environment (REQ-441; design
  `req441-mail-notifier-adapter.md` s2.2, s3), plus `runtime/0`, which reads the
  already-validated NON-SECRET application env at call time.

  `parse/2` is called from `config/runtime.exs`. It receives a map of
  variable name to raw string (or `nil`), EXCEPT for `LETFLOW_SMTP_USERNAME` and
  `LETFLOW_SMTP_PASSWORD`, which arrive as presence markers (`true`/`false`)
  computed by the caller: no credential value ever enters this module (INV-4,
  design M1; an unexpected `FunctionClauseError` would otherwise print its
  arguments to boot output). Every error is `{:missing | :invalid, "VAR_NAME"}`:
  the variable NAME only, never a value.

  Credentials are NOT part of the application env and are never returned from
  here (design s3.5); `Letflow.LoginDiscovery.Notifier.Smtp` reads them with
  `System.get_env/1` at the point of use.
  """

  alias Letflow.LoginDiscovery.Notifier.Smtp.Message

  @smtp_adapter Letflow.LoginDiscovery.Notifier.Smtp
  @noop_adapter Letflow.LoginDiscovery.Notifier.Noop

  @default_timeout_ms 15_000
  @min_timeout_ms 2_000
  @max_timeout_ms 30_000
  @max_base_url_bytes 200

  @type tls_mode :: :starttls | :tls | :none
  @type secret_marker :: boolean()
  @type env_input :: %{optional(String.t()) => String.t() | secret_marker() | nil}
  @type smtp_parsed :: %{
          notifier: [adapter: module(), timeout_ms: pos_integer()],
          smtp: [
            host: String.t(),
            port: 1..65535,
            tls: tls_mode(),
            from: String.t(),
            base_url: String.t(),
            socket_timeout_ms: pos_integer()
          ]
        }
  @type runtime_config :: %{
          host: String.t(),
          port: 1..65535,
          tls: tls_mode(),
          from: String.t(),
          base_url: String.t(),
          socket_timeout_ms: pos_integer()
        }

  @spec parse(env_input(), atom()) ::
          {:ok, :unset}
          | {:ok, {:noop, %{notifier: [adapter: module()]}}}
          | {:ok, {:smtp, smtp_parsed()}}
          | {:error, {:missing | :invalid, String.t()}}
  def parse(env, config_env) when is_map(env) and is_atom(config_env) do
    case env |> Map.get("LETFLOW_MAIL_ADAPTER") |> trim() do
      "" -> {:ok, :unset}
      "noop" -> {:ok, {:noop, %{notifier: [adapter: @noop_adapter]}}}
      "smtp" -> parse_smtp(env, config_env)
      _unknown -> {:error, {:invalid, "LETFLOW_MAIL_ADAPTER"}}
    end
  end

  defp parse_smtp(env, config_env) do
    with {:ok, host} <- host(env),
         {:ok, port} <- port(env),
         :ok <- secret_marker(env, "LETFLOW_SMTP_USERNAME"),
         :ok <- secret_marker(env, "LETFLOW_SMTP_PASSWORD"),
         {:ok, tls} <- tls(env, host, config_env),
         {:ok, from} <- from(env),
         {:ok, base_url} <- base_url(env, config_env),
         {:ok, timeout_ms} <- timeout_ms(env) do
      {:ok,
       {:smtp,
        %{
          notifier: [adapter: @smtp_adapter, timeout_ms: timeout_ms],
          smtp: [
            host: host,
            port: port,
            tls: tls,
            from: from,
            base_url: base_url,
            socket_timeout_ms: max(1_000, div(timeout_ms, 4))
          ]
        }}}
    end
  end

  @doc """
  The non-secret SMTP settings, read at call time from the application env
  (written by `config/runtime.exs`). `{:error, :not_configured}` if any is absent.
  """
  @spec runtime() :: {:ok, runtime_config()} | {:error, :not_configured}
  def runtime do
    env = Application.get_env(:letflow, @smtp_adapter, [])

    with host when is_binary(host) <- Keyword.get(env, :host),
         port when is_integer(port) <- Keyword.get(env, :port),
         tls when tls in [:starttls, :tls, :none] <- Keyword.get(env, :tls),
         from when is_binary(from) <- Keyword.get(env, :from),
         base_url when is_binary(base_url) <- Keyword.get(env, :base_url),
         socket_timeout_ms when is_integer(socket_timeout_ms) <-
           Keyword.get(env, :socket_timeout_ms) do
      {:ok,
       %{
         host: host,
         port: port,
         tls: tls,
         from: from,
         base_url: base_url,
         socket_timeout_ms: socket_timeout_ms
       }}
    else
      _incomplete -> {:error, :not_configured}
    end
  end

  # -- per-variable parsing -------------------------------------------------

  defp host(env) do
    name = "LETFLOW_SMTP_HOST"

    case env |> Map.get(name) |> trim() do
      "" -> {:error, {:missing, name}}
      host -> if valid_host?(host), do: {:ok, host}, else: {:error, {:invalid, name}}
    end
  end

  defp port(env) do
    name = "LETFLOW_SMTP_PORT"

    case env |> Map.get(name) |> trim() do
      "" ->
        {:error, {:missing, name}}

      text ->
        case Integer.parse(text) do
          {n, ""} when n in 1..65535 -> {:ok, n}
          _other -> {:error, {:invalid, name}}
        end
    end
  end

  # Only presence markers are accepted; anything but `true` is "missing".
  defp secret_marker(env, name) do
    if Map.get(env, name) === true, do: :ok, else: {:error, {:missing, name}}
  end

  defp tls(env, host, config_env) do
    name = "LETFLOW_SMTP_TLS"

    mode =
      case env |> Map.get(name) |> trim() do
        "" -> {:ok, :starttls}
        "starttls" -> {:ok, :starttls}
        "tls" -> {:ok, :tls}
        "none" -> {:ok, :none}
        _other -> {:error, {:invalid, name}}
      end

    with {:ok, mode} <- mode do
      cond do
        mode == :none and (config_env == :prod or not loopback?(host)) ->
          {:error, {:invalid, name}}

        mode != :none and ip_literal?(host) ->
          {:error, {:invalid, "LETFLOW_SMTP_HOST"}}

        true ->
          {:ok, mode}
      end
    end
  end

  defp from(env) do
    name = "LETFLOW_MAIL_FROM"

    case env |> Map.get(name) |> trim() do
      "" -> {:error, {:missing, name}}
      from -> if Message.valid_address?(from), do: {:ok, from}, else: {:error, {:invalid, name}}
    end
  end

  defp base_url(env, config_env) do
    name = "LETFLOW_PUBLIC_BASE_URL"

    case env |> Map.get(name) |> trim() do
      "" ->
        {:error, {:missing, name}}

      url ->
        if valid_base_url?(url, config_env),
          do: {:ok, String.trim_trailing(url, "/")},
          else: {:error, {:invalid, name}}
    end
  end

  defp timeout_ms(env) do
    name = "LETFLOW_MAIL_TIMEOUT_MS"

    case env |> Map.get(name) |> trim() do
      "" ->
        {:ok, @default_timeout_ms}

      text ->
        case Integer.parse(text) do
          {n, ""} when n >= @min_timeout_ms and n <= @max_timeout_ms -> {:ok, n}
          _other -> {:error, {:invalid, name}}
        end
    end
  end

  # -- validators -----------------------------------------------------------

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_other), do: ""

  defp valid_host?(host) do
    byte_size(host) <= 253 and (ip_literal?(host) or dns_name?(host))
  end

  defp dns_name?(host) do
    host
    |> String.split(".")
    |> Enum.all?(&Regex.match?(~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\z/, &1))
  end

  defp ip_literal?(host) do
    match?({:ok, _ip}, :inet.parse_address(String.to_charlist(host)))
  end

  defp loopback?("localhost"), do: true

  defp loopback?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _other -> false
    end
  end

  @doc """
  The base-URL rule of `LETFLOW_PUBLIC_BASE_URL`, reachable for other readers of that variable
  (REQ-572's provisioner `server_url`). `{:ok, url_without_trailing_slash}` or `:error`.
  """
  @spec validate_base_url(String.t(), atom()) :: {:ok, String.t()} | :error
  def validate_base_url(url, config_env) when is_binary(url) do
    if valid_base_url?(url, config_env), do: {:ok, String.trim_trailing(url, "/")}, else: :error
  end

  defp valid_base_url?(url, config_env) do
    allowed_schemes = if config_env == :prod, do: ["https"], else: ["https", "http"]

    byte_size(url) <= @max_base_url_bytes and Regex.match?(~r/\A[\x21-\x7E]+\z/, url) and
      case URI.parse(url) do
        %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil}
        when is_binary(scheme) and is_binary(host) and host != "" ->
          scheme in allowed_schemes and valid_host?(host)

        _other ->
          false
      end
  end
end
