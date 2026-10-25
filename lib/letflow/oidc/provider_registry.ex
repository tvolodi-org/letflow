defmodule Letflow.Oidc.ProviderRegistry do
  @moduledoc """
  REQ-370 (`lib/letflow/design/req370-multi-issuer-oidc-verification.md` §4):
  owns the lifecycle of one `Oidcc.ProviderConfiguration.Worker` per
  **trusted** realm, started lazily on first verification attempt against
  that realm, rather than enumerated eagerly at boot.

  A `DynamicSupervisor` (not a fixed child list) because the trusted-realm
  set is exactly the `tenants` table's current contents, which changes at
  runtime as tenants are created — see the design doc §4.1 for the full
  "why lazy-on-demand" reasoning (no DB read inside `init/1`, matching
  `Letflow.Admission`'s and `Letflow.Engine.Wasm.InvocationLease`'s own
  established placement precedent).

  Each per-realm worker is registered under `{:via, Registry,
  {Letflow.Registry, {:oidc_provider, realm}}}` — reusing the
  already-supervised generic `Letflow.Registry`, not a second `Registry`
  process.

  **Trust gate, not a cache.** `ensure_started/1` always re-resolves the
  realm against the `tenants` table (`Letflow.Identity.resolve_tenant_by_realm/1`)
  BEFORE consulting whether a worker is already running — never the other
  way around. This ordering is what makes revocation hold (design doc §2/§4.3):
  a live worker for a since-revoked realm must not be trusted merely because
  it is already running. Worker liveness is purely a JWKS-fetch performance
  cache; it carries no trust decision.
  """

  use DynamicSupervisor

  alias Letflow.Identity

  @type realm :: String.t()
  @type provider_ref :: {:via, Registry, {Letflow.Registry, {:oidc_provider, realm()}}}

  @doc "Starts this registry's `DynamicSupervisor`, `strategy: :one_for_one`."
  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Idempotently ensures a running, JWKS-fetching provider worker exists for
  `realm`, after first confirming — freshly, from the database, on this very
  call — that a tenant row is actually bound to it (the trust check that
  must precede any worker start or reuse; see moduledoc).
  """
  @spec ensure_started(realm()) ::
          {:ok, provider_ref()} | {:error, :unknown_realm | term()}
  def ensure_started(realm) when is_binary(realm) do
    case Identity.resolve_tenant_by_realm(realm) do
      {:error, :not_found} ->
        {:error, :unknown_realm}

      {:ok, %{status: :inactive}} ->
        {:error, :unknown_realm}

      {:ok, _tenant} ->
        do_ensure_worker(realm)
    end
  end

  @doc """
  Stops the provider worker for `realm`, if one is running. Idempotent: `:ok`
  when none runs. Called when a tenant is deactivated so its realm stops being
  trusted for already-cached keys (the oidcc worker keeps its last JWKS and, on
  a 404 refresh, only retries with random 1-30 s backoff forever, never stopping).
  Reactivation needs no call: `ensure_started/1` restarts the worker lazily.
  """
  @spec stop(realm()) :: :ok
  def stop(realm) when is_binary(realm) do
    case Registry.lookup(Letflow.Registry, {:oidc_provider, realm}) do
      [{pid, _value}] ->
        _ = DynamicSupervisor.terminate_child(__MODULE__, pid)
        :ok

      [] ->
        :ok
    end
  end

  defp do_ensure_worker(realm) do
    name = via_name(realm)

    case Registry.lookup(Letflow.Registry, {:oidc_provider, realm}) do
      [{_pid, _value}] ->
        {:ok, name}

      [] ->
        start_worker(realm, name)
    end
  end

  defp start_worker(realm, name) do
    oidc_config = Application.fetch_env!(:letflow, :oidc)
    issuer = "#{keycloak_base_url(oidc_config)}/realms/#{realm}"

    child_spec =
      {Oidcc.ProviderConfiguration.Worker,
       %{
         issuer: issuer,
         name: name,
         backoff_type: :random,
         provider_configuration_opts: %{
           quirks: %{allow_unsafe_http: Keyword.get(oidc_config, :allow_unsafe_http, false)}
         }
       }}

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, _pid} -> {:ok, name}
      {:error, {:already_started, _pid}} -> {:ok, name}
      {:error, reason} -> {:error, reason}
    end
  end

  defp keycloak_base_url(oidc_config), do: Keyword.fetch!(oidc_config, :keycloak_base_url)

  @doc """
  Pure name construction — no process lookup, no I/O. Exposed so
  `Letflow.Oidc.TokenVerifier.Oidcc` (and tests) can compute the same
  via-tuple a prior `ensure_started/1` call registered a worker under,
  without duplicating the tuple shape.
  """
  @spec via_name(realm()) :: provider_ref()
  def via_name(realm) do
    {:via, Registry, {Letflow.Registry, {:oidc_provider, realm}}}
  end
end
