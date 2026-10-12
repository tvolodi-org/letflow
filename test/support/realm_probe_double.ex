defmodule Letflow.Oidc.RealmProbeDouble do
  @moduledoc """
  Deterministic `Letflow.Oidc.RealmProbe` double installed by `config/test.exs`
  (ISS-1030), so router tests never need a real Keycloak.

  The answer depends only on the realm name: a name starting with `unknown`
  is `{:error, :not_found}`, a name starting with `unreachable` is
  `{:error, :unreachable}`, anything else is `:ok`. The default adapter
  (`Letflow.Oidc.RealmProbe.Httpc`) is tested directly against a local HTTP
  server (`Letflow.Support.RealmProbeTestServer`), not through this double.

  Two test seams, both per calling process (the probe runs in the process that
  handles the request, which for the router tests is the test process itself):

    * every call sends `{:realm_probe, realm}` to the calling process, so a test
      can `assert_received`/`refute_received` that the probe was (not) asked
      about a realm, and in which order relative to other effects;
    * `put_override/1` makes the calling process's next calls answer a fixed
      result (or the result of a 1-arity function of the realm) regardless of
      the realm name. It is stored in the process dictionary, so it never leaks
      into another test or process.
  """

  @behaviour Letflow.Oidc.RealmProbe

  @override_key {__MODULE__, :override}

  @type override ::
          :ok
          | {:error, :not_found}
          | {:error, :unreachable}
          | (String.t() -> :ok | {:error, :not_found} | {:error, :unreachable})

  @doc "Makes this process's `verify/1` answer `override` until `clear_override/0`."
  @spec put_override(override()) :: :ok
  def put_override(override) do
    Process.put(@override_key, override)
    :ok
  end

  @doc "Removes this process's override."
  @spec clear_override() :: :ok
  def clear_override do
    Process.delete(@override_key)
    :ok
  end

  @impl true
  def verify(realm) when is_binary(realm) do
    send(self(), {:realm_probe, realm})

    case Process.get(@override_key) do
      nil -> by_name(realm)
      fun when is_function(fun, 1) -> fun.(realm)
      fixed -> fixed
    end
  end

  defp by_name("unknown" <> _rest), do: {:error, :not_found}
  defp by_name("unreachable" <> _rest), do: {:error, :unreachable}
  defp by_name(_realm), do: :ok
end
