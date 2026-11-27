defmodule Letflow.PlatformFunctions.Impl.TenantSetScriptPolicy do
  @moduledoc """
  The body of `tenant.set_script_policy` (T-3020, BP-PLATFORM-04 G1;
  `docs/design-bp-platform-04.md` sections 3 to 5).

  It sets one PLATFORM-owned script policy of a tenant, by tenant id: `setting` `"kill_switch"`
  (`Letflow.Scripts.Policy.set_platform_kill_switch/5`) or `"solo_audited"`
  (`set_platform_solo_audited/5`). It does not copy route code: the same two setters the
  `PUT /tenants/:slug/script-policy/*` routes call do the write and the two audit entries (a
  tenant-chain entry with NO operator id, a platform-chain entry with the starter's id).

  ## Who the operator is (PM answer Q1, option A)

  A platform step has no request, so no person. The person is the STARTER of the instance, read here
  from the engine's own `INSTANCE_STARTED` event of `dispatch.instance_id` in the platform tenant
  (its `actor_id`), never from a variable a starter or a completer can set. The setters get it as an
  operator with `credential: :platform_process`, a class only the two platform setters accept. An
  instance with no recorded starter is refused `platform_call_permission_required`.

  ## What is refused

  A tenant id that is not a UUID, not a registered tenant, or the platform tenant itself (PM answer
  Q3: its own policy is refused) is `platform_call_tenant_not_found` or
  `platform_call_tenant_not_allowed`; an unknown `setting`, a non-boolean `value` or a bad `reason`
  is `platform_call_arg_invalid`; a missing policy row or a failed audit write is
  `platform_call_script_policy_failed` (nothing written). A failure never carries the reason text or
  a tenant value. Idempotent: setting the value a tenant already has writes and audits nothing.
  It never raises (INV-8).
  """

  alias Letflow.EventStore
  alias Letflow.PlatformFunctions.Impl.SystemCaller
  alias Letflow.PlatformTenant
  alias Letflow.Scripts.Policy
  alias Letflow.Scripts.ScriptPolicy
  alias Letflow.TenantProvisioning

  @typedoc "The stable code of a refused step."
  @type refusal ::
          :platform_call_arg_invalid
          | :platform_call_tenant_not_found
          | :platform_call_tenant_not_allowed
          | :platform_call_permission_required
          | :platform_call_script_policy_failed

  @spec run(map()) :: {:ok, map()} | {:error, refusal()}
  def run(%{inputs: inputs, dispatch: dispatch}) when is_map(inputs) and is_map(dispatch) do
    with {:ok, setting} <- setting(Map.get(inputs, "setting")),
         {:ok, value} <- boolean(Map.get(inputs, "value")),
         {:ok, tenant_id} <- cast_uuid(Map.get(inputs, "tenant_id")),
         :ok <- not_platform(tenant_id),
         {:ok, prefix} <- tenant_schema(tenant_id),
         {:ok, platform_prefix} <- platform_prefix(),
         {:ok, starter} <- starter(Map.get(dispatch, :instance_id), platform_prefix) do
      operator = %{
        user_id: starter,
        credential: :platform_process,
        trace_id: nil,
        platform_prefix: platform_prefix
      }

      apply_setting(setting, prefix, tenant_id, value, Map.get(inputs, "reason"), operator)
    end
  rescue
    _error -> {:error, :platform_call_script_policy_failed}
  catch
    _kind, _reason -> {:error, :platform_call_script_policy_failed}
  end

  def run(_other), do: {:error, :platform_call_arg_invalid}

  defp apply_setting("kill_switch", prefix, tenant_id, value, reason, operator),
    do: finish(Policy.set_platform_kill_switch(prefix, tenant_id, value, reason, operator))

  defp apply_setting("solo_audited", prefix, tenant_id, value, reason, operator),
    do: finish(Policy.set_platform_solo_audited(prefix, tenant_id, value, reason, operator))

  defp finish({:ok, %ScriptPolicy{} = policy}) do
    {:ok,
     %{
       "kill_switch_on" => to_string(ScriptPolicy.effective?(policy)),
       "solo_audited_allowed" => to_string(policy.platform_solo_audited_allowed)
     }}
  end

  defp finish({:error, code}) when code in [:invalid_state, :invalid_reason],
    do: {:error, :platform_call_arg_invalid}

  defp finish({:error, :api_token_not_allowed}), do: {:error, :platform_call_permission_required}

  defp finish({:error, _policy_missing_audit_failed_or_other}),
    do: {:error, :platform_call_script_policy_failed}

  defp setting(value) when value in ["kill_switch", "solo_audited"], do: {:ok, value}
  defp setting(_other), do: {:error, :platform_call_arg_invalid}

  defp boolean(value) when is_boolean(value), do: {:ok, value}
  defp boolean(_other), do: {:error, :platform_call_arg_invalid}

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :platform_call_arg_invalid}
    end
  end

  defp cast_uuid(_other), do: {:error, :platform_call_arg_invalid}

  defp not_platform(tenant_id) do
    if PlatformTenant.platform_tenant?(tenant_id),
      do: {:error, :platform_call_tenant_not_allowed},
      else: :ok
  end

  defp tenant_schema(tenant_id) do
    case TenantProvisioning.registered_schema(tenant_id) do
      {:ok, schema} -> {:ok, schema}
      {:error, _not_found} -> {:error, :platform_call_tenant_not_found}
    end
  end

  defp platform_prefix do
    case SystemCaller.platform_prefix() do
      {:ok, prefix} -> {:ok, prefix}
      :error -> {:error, :platform_call_script_policy_failed}
    end
  end

  # The starter: the `actor_id` of the instance's own start event (engine-owned).
  defp starter(instance_id, platform_prefix) when is_binary(instance_id) do
    with {:ok, events} <-
           EventStore.read(instance_id, prefix: platform_prefix, up_to_sequence: 1),
         %{actor_id: actor_id} when is_binary(actor_id) <-
           Enum.find(events, &(&1.event_type == "INSTANCE_STARTED")) do
      {:ok, actor_id}
    else
      _no_starter -> {:error, :platform_call_permission_required}
    end
  end

  defp starter(_instance_id, _prefix), do: {:error, :platform_call_permission_required}
end
