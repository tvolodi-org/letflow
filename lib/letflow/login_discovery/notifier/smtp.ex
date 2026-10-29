defmodule Letflow.LoginDiscovery.Notifier.Smtp do
  @moduledoc """
  SMTP adapter behind the login-discovery notifier port (REQ-441; design
  `req441-mail-notifier-adapter.md`; decision 0045 -- `:gen_smtp` alone).

  Composes the fixed message (`Smtp.Message`), reads the NON-SECRET operator
  settings at call time (`Smtp.Config.runtime/0`), resolves the SMTP credentials
  from the OS environment at the point of use, and hands everything to
  `Smtp.Transport`. It logs nothing, emits nothing and never inspects a library
  return: `Letflow.LoginDiscovery.Dispatch` is the single emitter of the
  notifier event and runs this inside an isolated, time-limited task (INV-8).

  Credentials are NOT in the application env, a struct or a return value
  (INV-4): `LETFLOW_SMTP_USERNAME` / `LETFLOW_SMTP_PASSWORD` are read with
  `System.get_env/1` here and live only as an argument of one transport call.

  The returned reason is a closed set used by tests; transport-level outcomes
  (SMTP rejection, connection, TLS, auth, timeout) are deliberately NOT
  classified -- a classification would be a per-address signal.
  """

  @behaviour Letflow.LoginDiscovery.Notifier

  alias Letflow.LoginDiscovery.Notifier.Smtp.Config
  alias Letflow.LoginDiscovery.Notifier.Smtp.Message
  alias Letflow.LoginDiscovery.Notifier.Smtp.Transport

  @type reason :: :not_configured | :invalid_recipient | :invalid_message | :failed

  @impl true
  @spec deliver_tenant_list(String.t(), [Letflow.LoginDirectory.tenant_ref(), ...]) ::
          :ok | {:error, reason()}
  def deliver_tenant_list(recipient_email, tenants) do
    with {:ok, config} <- Config.runtime(),
         {:ok, composed} <-
           Message.compose(recipient_email, tenants, %{
             from: config.from,
             base_url: config.base_url
           }),
         {:ok, credentials} <- credentials() do
      Transport.send_message(composed, connection(config), credentials, [])
    else
      {:error, reason} when reason in [:not_configured, :invalid_recipient, :invalid_message] ->
        {:error, reason}

      _other ->
        {:error, :failed}
    end
  rescue
    _exception -> {:error, :failed}
  catch
    _kind, _reason -> {:error, :failed}
  end

  @impl true
  @spec deliver_message(%{to: String.t(), subject: String.t(), body: String.t()}) ::
          :ok | {:error, reason()}
  def deliver_message(message) do
    with {:ok, config} <- Config.runtime(),
         {:ok, composed} <- Message.compose_message(message, %{from: config.from}),
         {:ok, credentials} <- credentials() do
      Transport.send_message(composed, connection(config), credentials, [])
    else
      {:error, reason} when reason in [:not_configured, :invalid_recipient, :invalid_message] ->
        {:error, reason}
    end
  rescue
    _exception -> {:error, :failed}
  catch
    _kind, _reason -> {:error, :failed}
  end

  defp connection(config) do
    Map.take(config, [:host, :port, :tls, :socket_timeout_ms])
  end

  defp credentials do
    case {System.get_env("LETFLOW_SMTP_USERNAME"), System.get_env("LETFLOW_SMTP_PASSWORD")} do
      {username, password}
      when is_binary(username) and username != "" and is_binary(password) and password != "" ->
        {:ok, {username, password}}

      _missing ->
        {:error, :not_configured}
    end
  end
end
