defmodule Letflow.Oidc.RealmProbeDouble do
  @moduledoc """
  Deterministic `Letflow.Oidc.RealmProbe` double installed by `config/test.exs`
  (ISS-1030), so router tests never need a real Keycloak.

  The answer depends only on the realm name: a name starting with `unknown`
  is `{:error, :not_found}`, a name starting with `unreachable` is
  `{:error, :unreachable}`, anything else is `:ok`. The default adapter
  (`Letflow.Oidc.RealmProbe.Httpc`) is tested directly against a local HTTP
  server, not through this double.
  """

  @behaviour Letflow.Oidc.RealmProbe

  @impl true
  def verify("unknown" <> _rest), do: {:error, :not_found}
  def verify("unreachable" <> _rest), do: {:error, :unreachable}
  def verify(_realm), do: :ok
end
