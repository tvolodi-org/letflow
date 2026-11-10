defmodule Letflow.Signup.Mailer do
  @moduledoc """
  T-1579: sends the verification mail through the existing `Letflow.LoginDiscovery.Notifier` adapter
  (`deliver_message/1`), off the request path, after the sign-up transaction committed.

  The HTTP answer never depends on the outcome (INV-8): the task runs the adapter in an inner
  supervised task under the adapter timeout; an error, raise, exit or timeout only records
  `last_error: "mail_failed"` on the row. The recipient, link and token appear in no log line (INV-4).
  The link base is operator config (`LETFLOW_SIGNUP_BASE_URL`), never derived from the request (INV-9).
  """

  import Ecto.Query

  alias Letflow.Repo
  alias Letflow.Signup
  alias Letflow.Signup.{Messages, Request}

  @supervisor Letflow.LoginDiscovery.TaskSupervisor
  @notifier Letflow.LoginDiscovery.Notifier
  @default_adapter Letflow.LoginDiscovery.Notifier.Noop
  @default_timeout_ms 5_000

  @doc "Starts the delivery task; always `:ok` (a refused start only records the failure)."
  @spec deliver_async(Request.t(), String.t()) :: :ok
  def deliver_async(%Request{} = request, token) do
    message = build(request, token)
    tenant_id = request.tenant_id

    case Task.Supervisor.start_child(@supervisor, fn -> run(tenant_id, message) end) do
      {:ok, _pid} -> :ok
      _refused -> record_failure(tenant_id)
    end
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  @doc "Renders the message for a request and token."
  @spec build(Request.t(), String.t()) :: %{to: String.t(), subject: String.t(), body: String.t()}
  def build(%Request{} = request, token) do
    base = Signup.config().base_url |> to_string() |> String.trim_trailing("/")
    link = base <> "/signup/verify?token=" <> token
    %{subject: subject, body: body} = Messages.verification(request.language, link)
    %{to: request.email, subject: subject, body: body}
  end

  defp run(tenant_id, message) do
    case deliver_now(message) do
      :ok -> :ok
      {:error, :failed} -> record_failure(tenant_id)
    end
  end

  @doc """
  T-1593: delivers one rendered message synchronously through the adapter under the adapter timeout
  (an inner supervised task), for the caller that must know the outcome (the credential mail). Never
  raises; the message is not logged (INV-4).
  """
  @spec deliver_now(map()) :: :ok | {:error, :failed}
  def deliver_now(message) do
    config = Application.get_env(:letflow, @notifier, [])
    adapter = Keyword.get(config, :adapter, @default_adapter)
    timeout = Keyword.get(config, :timeout_ms, @default_timeout_ms)

    inner =
      Task.Supervisor.async_nolink(@supervisor, fn ->
        try do
          adapter.deliver_message(message)
        rescue
          _exception -> {:error, :failed}
        catch
          _kind, _reason -> {:error, :failed}
        end
      end)

    case Task.yield(inner, timeout) || Task.shutdown(inner, :brutal_kill) do
      {:ok, :ok} -> :ok
      _failure -> {:error, :failed}
    end
  rescue
    _exception -> {:error, :failed}
  catch
    _kind, _reason -> {:error, :failed}
  end

  defp record_failure(tenant_id) do
    Repo.update_all(from(r in Request, where: r.tenant_id == ^tenant_id),
      set: [last_error: "mail_failed"]
    )

    :ok
  rescue
    _exception -> :ok
  end
end
