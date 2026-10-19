defmodule Letflow.Identity.ServicePrincipal do
  @moduledoc """
  The admin-flagged service principal (REQ-517 / GH #2535 PR 2a, decision 0051 D12; design
  `lib/letflow/design/req517-scoped-grants-admin-plane.md` sections 3.6.2 and 3.12).

  A user carries `users.admin_flagged_service_principal`, set ONLY here (the `User`
  changesets cast it nowhere; `PATCH /users/:id` and the JIT path cannot reach it), by an
  interactive tenant administrator through `PUT /users/:id/service-principal`. Its single
  effect is on the target side of the mint check (`Letflow.Identity.mint_token/4` step 7): a
  flagged target's token roles need only be a subset of the ISSUER's tenant-wide roles.
  `Letflow.Api.Scope.allowed?/3` never reads the flag, and a token that exceeds its owner's
  tenant-wide roles still blocks the scope-enforcement flip even when the owner is flagged.

  `set_flag/5` is one transaction: lock A (`Letflow.Identity.lock_tenant_admins!/1`), the
  user row `FOR UPDATE`, the update, and one `service_principal.flagged` /
  `service_principal.unflagged` audit entry in the same transaction (an audit failure rolls
  everything back). A request equal to the current value writes nothing and no audit entry.

  GH #2869 (a): flagging (never unflagging) removes the user from the interactive count, so
  it is guarded like a removal. In a tenant stored `on`, a flag that takes the interactive
  explicit tenant-wide admin count from at least one to none is refused with
  `{:error, :last_interactive_tenant_wide_admin}`: nothing is written, no
  `service_principal.flagged` entry exists, and one `tenant_admin.guard_refused` entry (action
  `flag_service_principal`) is written in its own transaction. The reason is validated first,
  so a bad reason never reaches the guard.
  """

  import Ecto.Query

  alias Letflow.Audit
  alias Letflow.Audit.Reason
  alias Letflow.Identity
  alias Letflow.Identity.ApiToken
  alias Letflow.Identity.TenantAdminGuard
  alias Letflow.Identity.User
  alias Letflow.Repo

  @typedoc "The authenticated caller: user id, request trace id and credential mechanism."
  @type actor :: %{
          required(:user_id) => Ecto.UUID.t(),
          required(:trace_id) => String.t() | nil,
          optional(:credential) => String.t() | nil
        }

  @type set_result ::
          {:ok, %{user_id: Ecto.UUID.t(), flagged: boolean(), changed: boolean()}}
          | {:error,
             :not_found
             | :reason_required
             | :invalid_reason
             | :last_interactive_tenant_wide_admin
             | {:audit_failed, term()}
             | {:transaction_failed, Exception.t()}}

  @doc """
  Sets or clears the flag of `user_id`. The reason is checked first (missing, non-string or
  blank after trimming: `:reason_required`; failing `Letflow.Audit.Reason`:
  `:invalid_reason`), so a bad reason never reveals whether the user exists.
  """
  @spec set_flag(
          user_id :: String.t(),
          flagged :: boolean(),
          reason :: term(),
          actor(),
          prefix :: String.t()
        ) :: set_result()
  def set_flag(user_id, flagged, reason, actor, prefix)
      when is_boolean(flagged) and is_map(actor) and is_binary(prefix) do
    with {:ok, reason} <- check_reason(reason) do
      try do
        Repo.transaction(fn -> do_set_flag(user_id, flagged, reason, actor, prefix) end,
          prefix: prefix
        )
        |> case do
          {:error, {:tenant_admin_guard, refusal}} ->
            TenantAdminGuard.refuse(prefix, refusal, %{
              actor_id: actor.user_id,
              trace_id: actor.trace_id
            })

          other ->
            other
        end
      rescue
        exception -> {:error, {:transaction_failed, exception}}
      end
    end
  end

  @doc "True when `user` carries the flag. Pure field read; `nil` is not flagged."
  @spec flagged?(User.t() | nil) :: boolean()
  def flagged?(%User{admin_flagged_service_principal: true}), do: true
  def flagged?(_user_or_nil), do: false

  defp check_reason(reason) when is_binary(reason) do
    if String.trim(reason) == "" do
      {:error, :reason_required}
    else
      case Reason.validate(reason) do
        {:ok, trimmed} -> {:ok, trimmed}
        :error -> {:error, :invalid_reason}
      end
    end
  end

  defp check_reason(_missing_or_not_a_string), do: {:error, :reason_required}

  defp do_set_flag(raw_user_id, flagged, reason, actor, prefix) do
    Identity.lock_tenant_admins!(prefix)

    user =
      with {:ok, user_id} <- Ecto.UUID.cast(raw_user_id),
           %User{} = user <-
             Repo.one(from(u in User, where: u.id == ^user_id, lock: "FOR UPDATE"),
               prefix: prefix
             ) do
        user
      else
        _unknown -> Repo.rollback(:not_found)
      end

    if flagged?(user) == flagged do
      %{user_id: user.id, flagged: flagged, changed: false}
    else
      # GH #2869 (a): only a flag (not an unflag) can lower the interactive count.
      interactive_before =
        if flagged, do: TenantAdminGuard.count_before!(prefix, :interactive_explicit)

      user
      |> Ecto.Changeset.change(admin_flagged_service_principal: flagged)
      |> Repo.update!(prefix: prefix)

      if is_integer(interactive_before) do
        :ok =
          TenantAdminGuard.ensure_interactive_admin_remains!(
            prefix,
            :flag_service_principal,
            user.id,
            interactive_before
          )
      end

      case Audit.insert_entry(Repo, audit_attrs(user, flagged, reason, actor, prefix), prefix) do
        {:ok, _entry} -> %{user_id: user.id, flagged: flagged, changed: true}
        {:error, audit_reason} -> Repo.rollback({:audit_failed, audit_reason})
      end
    end
  end

  defp audit_attrs(user, flagged, reason, actor, prefix) do
    base = %{
      "flagged" => flagged,
      "reason" => reason,
      "actor" => actor.user_id,
      "credential" => Map.get(actor, :credential),
      "trace_id" => actor.trace_id
    }

    after_state =
      if flagged,
        do: base,
        else: Map.put(base, "tokens_exceeding_owner", tokens_exceeding_owner(user.id, prefix))

    %{
      actor_id: actor.user_id,
      action: if(flagged, do: "service_principal.flagged", else: "service_principal.unflagged"),
      resource_type: "user",
      resource_id: user.id,
      before_state: %{"flagged" => not flagged},
      after_state: after_state,
      trace_id: actor.trace_id
    }
  end

  # Advisory count only (never ids or values): live tokens of the owner whose roles exceed
  # the owner's tenant-wide roles at unflag time.
  defp tokens_exceeding_owner(user_id, prefix) do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    held = Identity.tenant_wide_role_names(user_id, prefix: prefix)

    from(t in ApiToken,
      where:
        t.user_id == ^user_id and is_nil(t.revoked_at) and
          (is_nil(t.expires_at) or t.expires_at > ^now),
      select: t.roles
    )
    |> Repo.all(prefix: prefix)
    |> Enum.count(fn roles -> not MapSet.subset?(MapSet.new(roles || []), held) end)
  end
end
