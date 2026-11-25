defmodule Letflow.PlatformProcesses.RegistrationMask do
  @moduledoc """
  Field authorisation of the registration process's personal variables on the
  instance reads (T-2704, INV-2 / INV-4).

  `platform.register_tenant` is started with an administrator e-mail and a
  realm id. Before the process, those values were readable only behind
  `:TenantsManage` (the onboarding routes). An instance read is gated by
  `:InstancesRead`, which more roles hold, so the two values are LABELLED here
  and the instance reads redact them through the engine's own variable-label
  redaction (`Letflow.Engine.VariableLabels`, decision 0062 R8): a label the
  caller's hidden set contains is replaced by the redaction placeholder.

  The hidden set of the engine is grant-driven (entity field grants). This
  module adds the registration labels to a caller's hidden set unless the
  caller holds `:TenantsManage`, and supplies the labels, which the start does
  not store, at read time. It acts only in the platform tenant's schema, the
  only place `platform.register_tenant` lives, so a tenant's own variable named
  `admin_email` is untouched.

  Pure: no `Repo`, no clock.
  """

  alias Letflow.Api.Authorization
  alias Letflow.PlatformTenant

  @labels %{
    "admin_email" => ["platform_registration.admin_email"],
    "realm_id" => ["platform_registration.realm_id"]
  }

  # The value maps of a stored event payload and the label field of each
  # (the same pairs `VariableLabels.redact_event_payload/2` reads).
  @payload_fields [
    {"variables", "labels"},
    {"output_variables", "output_labels"},
    {"initial_variables", "initial_labels"}
  ]

  @doc "The registration variables' label map."
  @spec labels() :: %{String.t() => [String.t()]}
  def labels, do: @labels

  @doc """
  The hidden set for a read: `hidden` plus the registration labels, unless the
  schema is not the platform tenant's or the caller holds `:TenantsManage`.
  """
  @spec hide(MapSet.t() | nil, map(), String.t() | nil) :: MapSet.t() | nil
  def hide(nil, _auth_context, _prefix), do: nil

  def hide(%MapSet{} = hidden, auth_context, prefix) do
    if applies?(prefix) and not manages_tenants?(auth_context) do
      @labels |> Map.values() |> List.flatten() |> Enum.into(hidden)
    else
      hidden
    end
  end

  @doc "A projection's label map with the registration labels merged in."
  @spec put_labels(map(), String.t() | nil) :: map()
  def put_labels(variable_labels, prefix) do
    if applies?(prefix), do: merge_labels(variable_labels || %{}), else: variable_labels
  end

  # Union per variable: a label the stored data already carries (an entity
  # sensitivity label) stays effective next to the registration label.
  defp merge_labels(existing) when is_map(existing) do
    Map.merge(existing, @labels, fn _key, old, new ->
      Enum.uniq(List.wrap(old) ++ new)
    end)
  end

  defp merge_labels(_other), do: @labels

  @doc "A stored event payload with the registration labels added to its value maps."
  @spec put_payload_labels(term(), String.t() | nil) :: term()
  def put_payload_labels(payload, prefix) when is_map(payload) do
    if applies?(prefix) do
      Enum.reduce(@payload_fields, payload, fn {vars_key, labels_key}, acc ->
        case acc do
          %{^vars_key => vars} when is_map(vars) ->
            Map.put(acc, labels_key, merge_labels(Map.get(acc, labels_key) || %{}))

          _other ->
            acc
        end
      end)
    else
      payload
    end
  end

  def put_payload_labels(payload, _prefix), do: payload

  @doc """
  An audit entry's stored states with the registration values replaced by the
  redaction placeholder, unless the schema is not the platform tenant's or the
  caller holds `:TenantsManage`. The engine stores the whole instance row
  (its `variables`) in the `instance.create` audit row, so the audit read is a
  second read path of the same values; the stored row itself is unchanged.
  """
  @spec mask_audit_states(map(), map(), String.t() | nil) :: map()
  def mask_audit_states(%{before_state: b, after_state: a} = entry, auth_context, prefix) do
    if applies?(prefix) and not manages_tenants?(auth_context) do
      %{entry | before_state: scrub(b), after_state: scrub(a)}
    else
      entry
    end
  end

  defp scrub(%{} = map) when not is_struct(map) do
    Map.new(map, fn {k, v} ->
      if k in Map.keys(@labels),
        do: {k, Letflow.Engine.VariableLabels.representation()},
        else: {k, scrub(v)}
    end)
  end

  defp scrub(list) when is_list(list), do: Enum.map(list, &scrub/1)
  defp scrub(other), do: other

  defp applies?(prefix) when is_binary(prefix) do
    case PlatformTenant.platform_prefix() do
      {:ok, ^prefix} -> true
      _other -> false
    end
  end

  defp applies?(_prefix), do: false

  # Recomputed from the database-resolved tenant, as the authorize plug does.
  defp manages_tenants?(auth_context) do
    platform? = PlatformTenant.platform_tenant?(Map.get(auth_context, :tenant_id))

    roles =
      auth_context
      |> Map.get(:roles, [])
      |> Authorization.effective_roles(platform?)

    Authorization.has_permission_in_scope?(roles, :TenantsManage, platform?)
  end
end
