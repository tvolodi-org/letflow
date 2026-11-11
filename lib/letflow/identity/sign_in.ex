defmodule Letflow.Identity.SignIn do
  @moduledoc """
  T-1730 (REQ-807, decision 0072 section 8b, 0085 D11): creates the realm login for ONE internal user of
  the caller's own company and binds the row. Behind `LETFLOW_REALM_USERS_ENABLED` (off).

  Order: refuse while off or not configured; read the user (tenant `:prefix` scoped, INV-1); refuse an
  inactive, already bound or email-less row; check the tenant's `idp_realm_id` equals the label derived
  from the AUTHENTICATED tenant id (never from the request, INV-10); call the provisioner **outside any
  transaction**; then lock the row, re-check it, bind it and write one audit entry in one transaction.

  The temporary password lives in one local variable and in the returned tuple. It is never in a Multi
  change, an audit map or a log (INV-4). Residual, as written in 0072 section 8b: if the provisioner
  answers 201 and the bind then fails (a race, a lost audit insert), the realm account exists without a
  bound row and the password is lost; the administrator sees a fixed error.
  """

  import Ecto.Query

  alias Letflow.Audit
  alias Letflow.Identity
  alias Letflow.Identity.AuditContext
  alias Letflow.Identity.User
  alias Letflow.Repo
  alias Letflow.Signup.RealmProvisioner
  alias Letflow.Signup.RealmUsers

  @spec run(Ecto.UUID.t() | String.t(), keyword()) ::
          {:ok, User.t(), String.t()} | {:error, atom()}
  def run(user_id, opts) do
    with :ok <- check_configured(),
         {:ok, user} <- Identity.get_user(user_id, opts),
         :ok <- check_row(user),
         {:ok, realm} <- check_realm(Keyword.get(opts, :tenant_id)),
         {:ok, %{user_id: external_id, temporary_password: password}} <-
           call_provisioner(Keyword.fetch!(opts, :tenant_id), user),
         {:ok, bound} <- bind(user.id, realm, external_id, opts) do
      {:ok, bound, password}
    end
  rescue
    _exception -> {:error, :bind_failed}
  end

  defp check_configured do
    if RealmUsers.configured?(), do: :ok, else: {:error, :sign_in_creation_off}
  end

  defp check_row(%User{status: status}) when status != :active, do: {:error, :user_inactive}
  defp check_row(%User{auth_source: :oidc}), do: {:error, :sign_in_exists}

  defp check_row(%User{email: email}) do
    if is_binary(email) and String.trim(email) != "", do: :ok, else: {:error, :no_email}
  end

  defp check_realm(tenant_id) when is_binary(tenant_id) do
    expected = RealmProvisioner.label(tenant_id)

    case Identity.resolve_realm_by_tenant(tenant_id) do
      {:ok, ^expected} -> {:ok, expected}
      _other -> {:error, :realm_not_provisioned}
    end
  end

  defp check_realm(_other), do: {:error, :realm_not_provisioned}

  defp call_provisioner(tenant_id, user) do
    attrs = %{username: user.username, email: user.email, display_name: user.display_name}

    case RealmUsers.create_login(tenant_id, attrs) do
      {:ok, _login} = ok ->
        ok

      {:error, :login_exists} ->
        {:error, :login_exists_in_realm}

      {:error, reason} when reason in [:unavailable, :rate_limited] ->
        {:error, :provisioner_unavailable}

      {:error, _other} ->
        {:error, :provisioner_refused}
    end
  end

  defp bind(id, realm, external_id, opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    ctx = AuditContext.from_opts(opts)

    result =
      Repo.transaction(fn ->
        locked = Repo.one(from(u in User, where: u.id == ^id, lock: "FOR UPDATE"), prefix: prefix)

        case locked do
          nil ->
            Repo.rollback(:not_found)

          %User{} = row ->
            case check_row(row) do
              :ok -> :ok
              {:error, reason} -> Repo.rollback(reason)
            end

            changeset = User.bind_realm_login_changeset(row, realm, external_id)

            case Repo.update(changeset, prefix: prefix) do
              {:ok, bound} -> append_audit(bound, ctx, prefix)
              {:error, _changeset} -> Repo.rollback(:bind_failed)
            end
        end
      end)

    case result do
      {:ok, bound} -> {:ok, bound}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _other -> {:error, :bind_failed}
    end
  end

  defp append_audit(bound, ctx, prefix) do
    attrs = %{
      actor_id: ctx.actor_id,
      action: "user.sign_in_created",
      resource_type: "user",
      resource_id: bound.id,
      before_state: nil,
      after_state: Audit.struct_state(bound, [:password_hash]),
      trace_id: ctx.trace_id
    }

    case Audit.insert_entry(Repo, attrs, prefix) do
      {:ok, _entry} -> bound
      _failed -> Repo.rollback(:bind_failed)
    end
  end
end
