defmodule Letflow.Definitions.Reactivation do
  @moduledoc """
  GH #2692 / REQ-515 (decision 0054 D4a.4, open point 9): marks an ACTIVE definition
  `needs_reactivation` when the principal whose authority it was activated under
  (`process_definitions.activated_by`) is gone, deactivated, or no longer holds
  `EntitiesRecordsWrite`.

  The state is a flag on the active row (`needs_reactivation_at` / `needs_reactivation_reason`,
  both NULL when ok), not a fifth `status` value: every reader of `status == :active` and the
  unique active-name index stay untouched. The API shows it as `activation_state`.

  `reconcile_user/2` is public and idempotent. It runs inside the writer's transaction at each
  site that can remove a principal's authority (user deactivation, group member removal, group
  delete, IdP sync, role binding writers), so the mark is atomic with its cause. The application
  has no user-delete path; an ABSENT activator is reachable only out of band, and tooling that
  removes a user row calls this function. `Letflow.Engine` stays the fail-closed backstop: its
  run-time check treats an absent or inactive activator as `entity_write_needs_reactivation`.

  Reasons are a closed set (no ids, no free text): `activator_absent`, `activator_deactivated`,
  `activator_lost_entities_records_write`. The audit rows carry `actor_id: nil` (REQ-195's
  convention for definition lifecycle rows); the state projection carries the reason.
  """

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Identity
  alias Letflow.PlatformTenant
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @type reason ::
          :activator_absent | :activator_deactivated | :activator_lost_entities_records_write

  @doc """
  Marks every ACTIVE, un-flagged definition of tenant schema `prefix` whose recorded activator
  is `user_id` and who no longer qualifies. Returns the ids of the rows marked. A user who still
  holds the authority marks nothing. Idempotent: an already flagged row keeps its first reason.
  """
  @spec reconcile_user(Ecto.UUID.t() | String.t(), String.t()) ::
          {:ok, [Ecto.UUID.t()]} | {:error, term()}
  def reconcile_user(user_id, prefix) when is_binary(user_id) and is_binary(prefix) do
    with {:ok, user_uuid} <- Ecto.UUID.cast(user_id),
         {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      Repo.transaction(fn -> mark_rows(user_uuid, tenant_id, prefix) end)
    else
      :error -> {:error, :invalid_user_id}
      {:error, _reason} = error -> error
    end
  end

  @doc "`reconcile_user/2` for each id; stops at the first error."
  @spec reconcile_users([Ecto.UUID.t() | String.t()], String.t()) ::
          {:ok, [Ecto.UUID.t()]} | {:error, term()}
  def reconcile_users(user_ids, prefix) when is_list(user_ids) do
    Enum.reduce_while(Enum.uniq(user_ids), {:ok, []}, fn user_id, {:ok, acc} ->
      case reconcile_user(user_id, prefix) do
        {:ok, ids} -> {:cont, {:ok, acc ++ ids}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  `reconcile_users/2` for every current member of group `group_id`. Used by the binding
  writers when a group loses a platform role.
  """
  @spec reconcile_group(Ecto.UUID.t() | String.t(), String.t()) ::
          {:ok, [Ecto.UUID.t()]} | {:error, term()}
  def reconcile_group(group_id, prefix) when is_binary(prefix) do
    user_ids =
      Repo.all(
        from(m in Letflow.Identity.GroupMember,
          where: m.group_id == ^group_id,
          select: m.user_id
        ),
        prefix: prefix
      )

    reconcile_users(user_ids, prefix)
  end

  defp mark_rows(user_id, tenant_id, prefix) do
    rows =
      ProcessDefinition
      |> where([d], d.status == :active and is_nil(d.needs_reactivation_at))
      |> where([d], fragment("?->>'user_id' = ?", d.activated_by, ^user_id))
      |> lock("FOR UPDATE")
      |> Repo.all(prefix: prefix)

    case rows do
      [] ->
        []

      rows ->
        case lost_reason(user_id, tenant_id, prefix) do
          nil -> []
          reason -> Enum.map(rows, &mark_row!(&1, reason, tenant_id, prefix))
        end
    end
  end

  defp lost_reason(user_id, tenant_id, prefix) do
    case Identity.get_user(user_id, prefix: prefix) do
      {:error, :not_found} ->
        :activator_absent

      {:ok, %{status: status}} when status != :active ->
        :activator_deactivated

      {:ok, _user} ->
        roles = Identity.list_effective_role_names(user_id, prefix: prefix)

        case Activator.from_auth_context(
               %{user_id: user_id, roles: roles},
               PlatformTenant.platform_tenant?(tenant_id)
             ) do
          %{entities_records_write?: true} -> nil
          _lost -> :activator_lost_entities_records_write
        end
    end
  end

  defp mark_row!(%ProcessDefinition{id: id} = before, reason, tenant_id, prefix) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    seq =
      case Definitions.assign_sequence(tenant_id, prefix) do
        {:ok, seq} -> seq
        {:error, error} -> Repo.rollback(error)
      end

    {1, [updated]} =
      ProcessDefinition
      |> where([d], d.id == ^id)
      |> select([d], d)
      |> Repo.update_all(
        [
          set: [
            needs_reactivation_at: now,
            needs_reactivation_reason: Atom.to_string(reason),
            updated_at: now,
            sequence_number: seq
          ]
        ],
        prefix: prefix
      )

    case Definitions.record_audit(
           "definition.mark_needs_reactivation",
           id,
           before,
           updated,
           prefix
         ) do
      {:ok, _entry} -> id
      {:error, error} -> Repo.rollback(error)
    end
  end
end
