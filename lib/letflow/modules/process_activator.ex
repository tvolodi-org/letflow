defmodule Letflow.Modules.ProcessActivator do
  @moduledoc """
  The tenant-local system actor that activates UNMODIFIED module-stamped process definitions
  (T-2253 at first use of stock, T-2353 at module upgrade) when no human with `DefinitionsActivate`
  is in the call.

  The actor is an internal user with the fixed id below: no password, no role, no group, no
  membership, no login-directory entry. A fixed id stops a pre-existing same-name tenant user from
  becoming the system activator; an existing inactive or changed user is never reactivated or
  trusted (`{:error, :system_activator_unavailable}`). The row is created in the tenant schema
  `prefix` only (INV-1) and its first creation writes one `stock.process_activator_created` audit
  entry (the action name predates the extraction and is kept so existing tenants audit alike).

  The authority it returns is NOT a general permission: the callers (`Letflow.Modules.EnsureSeeds`,
  `Letflow.Modules.Stock.Documents.Posting`) hand it to `Letflow.Definitions.activate/2` only after
  their own closed checks (module-owned stamp, unmodified graph, no tenant-created version of the
  name), and the ordinary activation validators and `definition.activate` audit still run.
  A definition activated by this actor is tied to it (`activated_by`), not to a human; a tenant
  request to reactivate a module-owned row is refused (T-3014).
  """

  alias Letflow.Audit
  alias Letflow.Identity
  alias Letflow.Repo

  @id "00000000-0000-0000-0000-000000007130"
  @username "__stock_process_activator__"
  @no_password "__NO_PASSWORD_SET__"

  @doc "The authority map for `Definitions.activate/2`, creating the system user in `prefix` if absent."
  @spec system_authority(String.t()) :: {:ok, map()} | {:error, term()}
  def system_authority(prefix) when is_binary(prefix) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    {created, _} =
      Repo.insert_all(
        Identity.User,
        [
          %{
            id: @id,
            username: @username,
            display_name: "Stock process activator",
            email: "stock-process-activator@system.invalid",
            password_hash: @no_password,
            auth_source: :internal,
            status: :active,
            inserted_at: now,
            updated_at: now
          }
        ],
        prefix: prefix,
        on_conflict: :nothing
      )

    with :ok <- audit_created(created, prefix),
         %Identity.User{
           status: :active,
           auth_source: :internal,
           username: @username,
           password_hash: @no_password
         } <- Repo.get(Identity.User, @id, prefix: prefix),
         [] <- Identity.list_effective_role_names(@id, prefix: prefix) do
      {:ok,
       %{
         user_id: @id,
         roles: [],
         permissions: ["DefinitionsActivate", "EntitiesRecordsWrite"],
         entities_records_write?: true,
         credential: "none"
       }}
    else
      _refused -> {:error, :system_activator_unavailable}
    end
  end

  defp audit_created(0, _prefix), do: :ok

  defp audit_created(1, prefix) do
    case Audit.insert_entry(
           Repo,
           %{
             actor_id: nil,
             action: "stock.process_activator_created",
             resource_type: "user",
             resource_id: @id,
             before_state: nil,
             after_state: %{"username" => @username, "roles" => []}
           },
           prefix
         ) do
      {:ok, _entry} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
