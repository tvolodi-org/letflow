defmodule Letflow.LoginDiscovery.Notifier.Noop do
  @moduledoc """
  Default notifier adapter (REQ-437): delivers nothing and returns `:ok`. It
  logs only a fixed, non-identifying line at `:debug` -- no recipient, no
  tenant, no count (INV-4). Until a real mail adapter exists (REQ-441), every
  email-delivering path is therefore inert and the HTTP response stays neutral.
  """

  @behaviour Letflow.LoginDiscovery.Notifier

  require Logger

  @impl true
  def deliver_tenant_list(_recipient_email, _tenants) do
    Logger.debug("login discovery: tenant list delivery skipped (noop notifier)")
    :ok
  end

  @impl true
  def deliver_message(_message) do
    Logger.debug("notifications: message delivery skipped (noop notifier)")
    :ok
  end
end
