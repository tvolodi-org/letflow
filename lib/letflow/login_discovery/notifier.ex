defmodule Letflow.LoginDiscovery.Notifier do
  @moduledoc """
  Port for delivering mail from the platform (REQ-437 tenant list; REQ-584 notification
  messages; design `req434-email-first-login-directory.md` s13).

  The adapter is selected by `config :letflow, Letflow.LoginDiscovery.Notifier,
  adapter: <module>` (default `Letflow.LoginDiscovery.Notifier.Noop`; the test
  config sets the test double). The real mail adapter is `Notifier.Smtp` (REQ-441).

  `recipient_email` is the normalised address the caller typed in THIS request,
  never a stored value. An adapter must never log or raise with the recipient,
  a slug or a display name in any message (INV-4); the caller isolates failures
  (INV-8), so an adapter may return `{:error, term}` or raise freely.

  `deliver_message/1` (REQ-584) sends one already-rendered message
  (`%{to, subject, body}`); `Letflow.Notifications` is its caller and writes the
  delivery log row. The same logging and isolation rules apply.
  """

  @callback deliver_tenant_list(
              recipient_email :: String.t(),
              tenants :: [Letflow.LoginDirectory.tenant_ref(), ...]
            ) :: :ok | {:error, term()}

  @callback deliver_message(message :: %{to: String.t(), subject: String.t(), body: String.t()}) ::
              :ok | {:error, term()}
end
