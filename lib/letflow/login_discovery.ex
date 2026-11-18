defmodule Letflow.LoginDiscovery do
  @moduledoc """
  Pure decision and delivery rules of the public email-first login-discovery
  endpoint (REQ-437; design `lib/letflow/design/req434-email-first-login-directory.md`
  s7, D21/D28, decision 0043 D-A).

  `mode` is the DEPLOYMENT mode, read by exactly one function,
  `Letflow.LoginDirectory.deployment_mode/0`, which `mode/0` delegates to; this
  module defines no vocabulary list, validator or converter. The per-tenant
  disclosure arrives inside the lookup result as each match's `disclose`
  boolean (already folded with the deployment mode in the lookup's SQL); `decide/2`
  also forces `:neutral` under any mode other than `:redirect_single`
  (defence in depth, the ceiling).

  `disclose` is stripped here (`Map.take([:slug, :display_name, :hostname])`) before any
  response body or notifier call is built: no tenant id, realm id or stored mode
  ever leaves this module.

  Config: `config :letflow, Letflow.LoginDiscovery, mode:, max_body_bytes:`
  (a key distinct from `Letflow.Routers.LoginDiscovery`'s mount switch, D21).
  No `Logger` output here (INV-4).
  """

  alias Letflow.LoginDirectory

  @default_max_body_bytes 2048

  @type mode :: LoginDirectory.disclosure_mode()
  @type result :: {:ok, [LoginDirectory.tenant_match()]} | {:error, :lookup_failed}
  @type decision :: :neutral | {:match, LoginDirectory.tenant_ref()}
  @type delivery :: :none | {:deliver, [LoginDirectory.tenant_ref(), ...]}

  @doc "The deployment disclosure mode (delegates to the single reader)."
  @spec mode() :: mode()
  defdelegate mode(), to: LoginDirectory, as: :deployment_mode

  @doc """
  Body read timeout in ms (`read_timeout:`, default 5000); a timeout is a
  malformed-class read failure.
  """
  @spec read_timeout() :: pos_integer()
  def read_timeout do
    case :letflow |> Application.get_env(__MODULE__, []) |> Keyword.get(:read_timeout) do
      n when is_integer(n) and n > 0 -> n
      _other -> 5_000
    end
  end

  @doc """
  Maximum request-body bytes the endpoint reads; a non-positive-integer
  configured value falls back to 2048 (no log).
  """
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes do
    case :letflow |> Application.get_env(__MODULE__, []) |> Keyword.get(:max_body_bytes) do
      n when is_integer(n) and n > 0 -> n
      _other -> @default_max_body_bytes
    end
  end

  @doc """
  `{:match, tenant_ref}` iff `mode == :redirect_single`, exactly one match and
  that match's `disclose` is `true`; otherwise `:neutral`.
  """
  @spec decide(mode(), result()) :: decision()
  def decide(:redirect_single, {:ok, [%{disclose: true} = match]}), do: {:match, strip(match)}
  def decide(_mode, _result), do: :neutral

  @doc """
  `:none` for a failed or empty lookup and for a disclosed single match;
  otherwise `{:deliver, list}` of ALL matches stripped to `slug` and
  `display_name` plus the optional company `hostname`, query order preserved.
  """
  @spec delivery(mode(), result()) :: delivery()
  def delivery(_mode, {:error, :lookup_failed}), do: :none
  def delivery(_mode, {:ok, []}), do: :none

  def delivery(mode, {:ok, [_ | _] = matches} = result) do
    case decide(mode, result) do
      {:match, _tenant} -> :none
      :neutral -> {:deliver, Enum.map(matches, &strip/1)}
    end
  end

  def delivery(_mode, _other), do: :none

  defp strip(match), do: Map.take(match, [:slug, :display_name, :hostname])
end
