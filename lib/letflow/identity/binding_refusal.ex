defmodule Letflow.Identity.BindingRefusal do
  @moduledoc """
  Records a refused binding write (REQ-519 2e-a, design section 3.5, decision D-4).

  A binding writer in a tenant whose scope enforcement is `on` cannot create a binding that
  needs a tenant-wide grant row (`nil -> platform_role`, `routing -> platform_role`): its
  transaction rolls back with `{:binding_refused, refusal}` and the caller then calls
  `refuse/3` OUTSIDE any transaction, the `Letflow.Identity.TenantAdminGuard.refuse/4`
  pattern. One `binding.refused` entry is written in its own transaction: the binding row does
  not exist, so `resource_id` is the role NAME. The `after_state` holds exactly
  `actor`, `role`, `group`, `case`, `trace_id` (ids and fixed strings; no claim value, INV-4).

  A failed audit write or a raise logs one constant line and the refusal is STILL returned;
  called inside an open transaction it writes nothing (an inner write would roll back with the
  caller) and logs one constant line.
  """

  require Logger

  alias Letflow.Audit
  alias Letflow.Identity.AuditContext
  alias Letflow.Repo

  @type refusal :: %{
          case: :nil_to_platform | :routing_to_platform,
          role: String.t(),
          group_id: Ecto.UUID.t()
        }

  @doc "Writes the `binding.refused` entry (see the moduledoc) and returns the refusal."
  @spec refuse(prefix :: String.t(), refusal(), AuditContext.t()) :: {:error, :scope_required}
  def refuse(prefix, %{case: refusal_case, role: role, group_id: group_id}, ctx)
      when is_binary(prefix) do
    if Repo.in_transaction?() do
      Logger.error("binding_refusal_not_recorded reason=inside_transaction")
    else
      write(prefix, refusal_case, role, group_id, ctx)
    end

    {:error, :scope_required}
  rescue
    _exception ->
      Logger.error("binding_refusal_not_recorded reason=exception")
      {:error, :scope_required}
  end

  defp write(prefix, refusal_case, role, group_id, ctx) do
    actor = Map.get(ctx, :actor_id)
    trace_id = Map.get(ctx, :trace_id)

    attrs = %{
      actor_id: actor,
      action: "binding.refused",
      resource_type: "tenant_role",
      resource_id: role,
      before_state: nil,
      after_state: %{
        "actor" => actor,
        "role" => role,
        "group" => group_id,
        "case" => Atom.to_string(refusal_case),
        "trace_id" => trace_id
      },
      trace_id: trace_id
    }

    result =
      Repo.transaction(fn ->
        case Audit.insert_entry(Repo, attrs, prefix) do
          {:ok, _entry} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, _reason} -> Logger.error("binding_refusal_not_recorded reason=audit_failed")
    end
  end
end
