defmodule Letflow.LoginDiscoveryNotifierDouble do
  @moduledoc """
  REQ-437 test double for `Letflow.LoginDiscovery.Notifier` (set as the adapter in
  `config/test.exs`). Lives in `test/support` (compiled only in `:test`).

  Every call is reported to the owner process as
  `{:deliver_tenant_list, recipient_email, tenants}` (`set_owner/1`; with no owner
  set nothing is reported). Behaviour is switched with `set_behaviour/1`:

    * `:ok` (default) -- returns `:ok`
    * `:error` -- returns `{:error, :boom}`
    * `:raise` -- raises with the recipient in the message (log-leak probing)
    * `:exit` -- exits with the recipient in the reason
    * `{:sleep, ms}` -- sleeps `ms` before returning `:ok`

  State lives in the application env so it is visible from the supervised task;
  tests that use it must be `async: false` and call `reset/0` in `on_exit`.
  """

  @behaviour Letflow.LoginDiscovery.Notifier

  @key :login_discovery_notifier_double

  @doc "Reports every call to `pid`."
  @spec set_owner(pid()) :: :ok
  def set_owner(pid), do: put(:owner, pid)

  @doc "Switches the double's behaviour (see moduledoc)."
  @spec set_behaviour(
          :ok
          | :error
          | {:error, term()}
          | :raise
          | :exit
          | {:sleep, non_neg_integer()}
        ) :: :ok
  def set_behaviour(behaviour), do: put(:behaviour, behaviour)

  @doc "Clears owner and behaviour."
  @spec reset() :: :ok
  def reset, do: Application.delete_env(:letflow, @key)

  @impl true
  def deliver_tenant_list(recipient_email, tenants) do
    state = Application.get_env(:letflow, @key, [])

    case state[:owner] do
      pid when is_pid(pid) -> send(pid, {:deliver_tenant_list, recipient_email, tenants})
      _none -> :ok
    end

    case state[:behaviour] || :ok do
      :ok -> :ok
      :error -> {:error, :boom}
      :raise -> raise "notifier boom for #{recipient_email}"
      :exit -> exit({:notifier_boom, recipient_email})
      {:sleep, ms} -> Process.sleep(ms)
    end
  end

  @doc """
  REQ-584: reports `{:deliver_message, message}` to the owner, then behaves as above. The
  behaviour may also be `{:error, reason}`, returned as is.
  """
  @impl true
  def deliver_message(message) do
    state = Application.get_env(:letflow, @key, [])

    case state[:owner] do
      pid when is_pid(pid) -> send(pid, {:deliver_message, message})
      _none -> :ok
    end

    case state[:behaviour] || :ok do
      :ok -> :ok
      :error -> {:error, :boom}
      {:error, reason} -> {:error, reason}
      :raise -> raise "notifier boom for #{message.to}"
      :exit -> exit({:notifier_boom, message.to})
      {:sleep, ms} -> Process.sleep(ms)
    end
  end

  defp put(key, value) do
    state = Application.get_env(:letflow, @key, [])
    Application.put_env(:letflow, @key, Keyword.put(state, key, value))
  end
end
