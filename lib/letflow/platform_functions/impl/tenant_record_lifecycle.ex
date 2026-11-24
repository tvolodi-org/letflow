defmodule Letflow.PlatformFunctions.Impl.TenantRecordLifecycle do
  @moduledoc """
  The body of `tenant.record_lifecycle` (T-2727, pilot gap G17c;
  `docs/platform-register-tenant-v2.md` section 4, row 4).

  It turns the ADMISSION row of a tenant (the reservation the front gate made under the demo-cap
  lock, `Letflow.TenantProvisioner.Admission`) into the `tenant_lifecycles` row, once the tenant row
  exists. Tier, language, expiry and both digests come from the admission, never from the instance
  variables, so no person can set them.

  Order inside the step:

    1. a lifecycle row for the tenant exists -- ok, nothing written (a repeat);
    2. no lifecycle row, a `requested_tenant_id` was sent and no admission exists -- the tenant would
       exist without lifecycle and budget accounting, so the step FAILS CLOSED
       (`platform_call_lifecycle_failed`);
    3. no lifecycle row and no `requested_tenant_id` (routes 1 and 2, operator tenants) -- a no-op, as
       today (an operator tenant has no lifecycle row);
    4. an admission exists -- the lifecycle row is inserted from it (`default_modules_state` is
       `pending`, or `done` when no default module is configured).

  It never raises (INV-8): every failure is an `{:error, code}`.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Repo
  alias Letflow.TenantProvisioner.Admission
  alias Letflow.TenantProvisioner.Config
  alias Letflow.TenantProvisioner.Lifecycle

  @typedoc "The stable code of a refused step."
  @type refusal :: :platform_call_arg_invalid | :platform_call_lifecycle_failed

  @doc """
  Runs the step over the resolved arguments. Returns `{:ok, %{}}` (the entry declares no output) or
  `{:error, refusal}`.
  """
  @spec run(map()) :: {:ok, map()} | {:error, refusal()}
  def run(%{inputs: inputs}) when is_map(inputs) do
    with {:ok, tenant_id} <- cast_uuid(Map.get(inputs, "tenant_id")),
         {:ok, requested?} <- requested?(Map.get(inputs, "requested_tenant_id")) do
      record(tenant_id, requested?)
    end
  end

  def run(_other), do: {:error, :platform_call_arg_invalid}

  defp record(tenant_id, requested?) do
    cond do
      Repo.exists?(from(l in Lifecycle, where: l.tenant_id == ^tenant_id)) ->
        {:ok, %{}}

      true ->
        case Repo.get(Admission, tenant_id) do
          nil when requested? -> {:error, :platform_call_lifecycle_failed}
          nil -> {:ok, %{}}
          %Admission{} = admission -> insert(admission)
        end
    end
  rescue
    _error -> {:error, :platform_call_lifecycle_failed}
  end

  defp insert(admission) do
    row =
      struct(Lifecycle, %{
        tenant_id: admission.tenant_id,
        lifecycle: "active",
        tier: admission.tier,
        language: admission.language,
        expires_at: admission.expires_at,
        source_ip_key: admission.source_ip_key,
        email_domain_key: admission.email_domain_key,
        default_modules_state: if(Config.default_modules() == [], do: "done", else: "pending")
      })

    # `on_conflict: :nothing`: a concurrent repeat of the step writes nothing the second time.
    case Repo.insert(row, on_conflict: :nothing, conflict_target: :tenant_id) do
      {:ok, _row} -> {:ok, %{}}
      {:error, _changeset} -> {:error, :platform_call_lifecycle_failed}
    end
  end

  defp requested?(nil), do: {:ok, false}
  defp requested?(value), do: with({:ok, _id} <- cast_uuid(value), do: {:ok, true})

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :platform_call_arg_invalid}
    end
  end

  defp cast_uuid(_value), do: {:error, :platform_call_arg_invalid}
end
