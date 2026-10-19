defmodule Letflow.ScopeEnforcement.RefusedAudit do
  @moduledoc """
  The audit entry of a REFUSED flip to `on` (REQ-519 2f-a, GH #2535, AC 14; design
  `lib/letflow/design/req519-enforced-writers-and-flag-on.md` sections 4.3 and 9, decision D-9,
  SEC ruling S-6).

  `Letflow.ScopeEnforcement.flip/4` calls `record/6` AFTER `Repo.transaction` returned the
  refusal (`{:on_precondition_failed, ...}` or `:shadow_required`), i.e. OUTSIDE any
  transaction, so the entry is not rolled back with the refused flip. ONE
  `scope.enforcement_refused` entry (`resource_type "tenant"`, `resource_id` the tenant id):
  `before_state %{"mode" => previous}`, `after_state` with `"target"` (`"on"`), `"failed"`
  (the stable codes), and, when the gate was evaluated, `"preconditions"` and `"evidence"`
  (counts, enums and booleans only, `Letflow.ScopeEnforcement.OnGate.audit_state/1`). A
  `shadow_required` refusal carries `"failed" => ["shadow_required"]` and no counts. No flag
  change.

  BEST-EFFORT, like `Letflow.Identity.TenantAdminGuard.refuse/4`: a failed write or a raise
  logs the constant line `scope_enforcement_refusal_not_recorded reason=<tag>` and the caller
  still returns its refusal; called inside an open transaction it writes nothing and logs the
  same line. A server fault (a gate read that raised) is a 500 and is NEVER recorded as a
  refusal: the facts are unknown, so `flip/4` does not call this module for it.
  """

  require Logger

  alias Letflow.Audit
  alias Letflow.Repo
  alias Letflow.ScopeEnforcement
  alias Letflow.ScopeEnforcement.OnGate

  @action "scope.enforcement_refused"

  @doc """
  Records the refusal (see the moduledoc). `failed` is a list of stable code atoms; `detail` is
  an `OnGate.report/0`, or `nil` when the gate was not evaluated (`shadow_required`). Always returns `:ok`.
  """
  @spec record(
          tenant_id :: Ecto.UUID.t(),
          prefix :: String.t(),
          previous :: Letflow.ScopeEnforcement.stored_mode(),
          failed :: [atom()],
          detail :: OnGate.report() | nil,
          attrs :: map()
        ) :: :ok
  def record(tenant_id, prefix, previous, failed, detail, attrs)
      when is_binary(prefix) and is_list(failed) and is_map(attrs) do
    if Repo.in_transaction?() do
      Logger.error("scope_enforcement_refusal_not_recorded reason=inside_transaction")
    else
      write(tenant_id, prefix, previous, failed, detail, attrs)
    end

    :ok
  rescue
    _exception ->
      Logger.error("scope_enforcement_refusal_not_recorded reason=exception")
      :ok
  end

  defp write(tenant_id, prefix, previous, failed, detail, attrs) do
    after_state =
      Map.merge(
        %{"target" => "on", "failed" => Enum.map(failed, &Atom.to_string/1)},
        gate_state(detail)
      )

    entry = %{
      actor_id: Map.get(attrs, :actor_id),
      action: @action,
      resource_type: ScopeEnforcement.flip_resource_type(),
      resource_id: tenant_id,
      before_state: %{"mode" => Atom.to_string(previous)},
      after_state: after_state,
      trace_id: Map.get(attrs, :trace_id)
    }

    result =
      Repo.transaction(fn ->
        case Audit.insert_entry(Repo, entry, prefix) do
          {:ok, _entry} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, :ok} ->
        :ok

      {:error, _reason} ->
        Logger.error("scope_enforcement_refusal_not_recorded reason=audit_failed")
    end
  end

  defp gate_state(nil), do: %{}
  defp gate_state(report), do: OnGate.audit_state(report)
end
