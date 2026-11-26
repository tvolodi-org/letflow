defmodule Letflow.PlatformFunctions.Impl.TenantRecordOnboarding do
  @moduledoc """
  The body of `tenant.record_onboarding` (T-2727, pilot gap G17c;
  `docs/platform-register-tenant-v2.md` section 4, row 5).

  It writes the tenant's onboarding record (its hostname) -- the write `Letflow.TenantProvisioner`
  makes in its `ensure_onboarding` step, through `Letflow.Identity.create_onboarding/1`.

    * no `hostname`: a no-op (routes 1 and 2 without a hostname);
    * a record for the tenant exists with the SAME hostname: ok, nothing written (a repeat);
    * a record exists with ANOTHER hostname: `platform_call_hostname_mismatch` (the step never moves a
      tenant's host);
    * the hostname belongs to another tenant: `platform_call_hostname_taken`.

  The hostname is byte-bounded (253 bytes) before anything else touches it (SF-01). It never raises
  (INV-8).
  """

  alias Letflow.Identity
  alias Letflow.Identity.OnboardingRecord
  alias Letflow.Repo

  @max_hostname_bytes 253

  @typedoc "The stable code of a refused step."
  @type refusal ::
          :platform_call_arg_invalid
          | :platform_call_hostname_taken
          | :platform_call_hostname_mismatch
          | :platform_call_onboarding_failed

  @doc """
  Runs the step over the resolved arguments. Returns `{:ok, %{}}` or `{:error, refusal}`.
  """
  @spec run(map()) :: {:ok, map()} | {:error, refusal()}
  def run(%{inputs: inputs}) when is_map(inputs) do
    with {:ok, tenant_id} <- cast_uuid(Map.get(inputs, "tenant_id")),
         :ok <- record(tenant_id, Map.get(inputs, "hostname")) do
      {:ok, %{}}
    end
  end

  def run(_other), do: {:error, :platform_call_arg_invalid}

  defp record(_tenant_id, nil), do: :ok

  defp record(tenant_id, hostname) when is_binary(hostname) do
    if byte_size(hostname) > @max_hostname_bytes or hostname == "" do
      {:error, :platform_call_arg_invalid}
    else
      ensure(tenant_id, hostname)
    end
  end

  defp record(_tenant_id, _other), do: {:error, :platform_call_arg_invalid}

  defp ensure(tenant_id, hostname) do
    case Repo.get_by(OnboardingRecord, tenant_id: tenant_id) do
      %OnboardingRecord{hostname: ^hostname} -> :ok
      %OnboardingRecord{} -> {:error, :platform_call_hostname_mismatch}
      nil -> insert(tenant_id, hostname)
    end
  rescue
    _error -> {:error, :platform_call_onboarding_failed}
  end

  defp insert(tenant_id, hostname) do
    case Repo.get(Identity.Tenant, tenant_id) do
      nil ->
        {:error, :platform_call_onboarding_failed}

      tenant ->
        case Identity.create_onboarding(%{
               tenant_id: tenant_id,
               slug: tenant.slug,
               hostname: hostname
             }) do
          {:ok, _record} -> :ok
          {:error, :duplicate_hostname} -> {:error, :platform_call_hostname_taken}
          {:error, _other} -> {:error, :platform_call_onboarding_failed}
        end
    end
  end

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :platform_call_arg_invalid}
    end
  end

  defp cast_uuid(_value), do: {:error, :platform_call_arg_invalid}
end
