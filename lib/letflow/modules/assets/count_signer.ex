defmodule Letflow.Modules.Assets.CountSigner do
  @moduledoc """
  REQ-819 / GH #4372 (asset count slice K4, owner decision D-128, spec `docs/assets/asset-count.md`
  section 5): who may decide the lines of a count result and sign it.

  The signer is a member of the group of a `tenant_role` row of kind `process_routing_role` whose
  name is the tenant setting `count_signer_role` (default `accountant`, `Settings.count_signer_role/1`).
  There is no fallback to another role and no administrator bypass: the roles of the token are never
  read. `Letflow.Tasks.resolve_principal_scope/2` lists the role names of every kind, so this module
  checks the kind itself: a `platform_role` row of the same name makes the role "not configured".
  Role names are unique per tenant schema, so a name is either a routing role or a platform role.
  The tenant is the `prefix` only (INV-1); every value is a bound parameter (INV-7).
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Identity.TenantRole
  alias Letflow.Modules.Assets.Settings
  alias Letflow.Repo
  alias Letflow.Tasks

  @doc "The configured role name of the tenant."
  @spec role(String.t()) :: String.t()
  def role(prefix) when is_binary(prefix), do: Settings.count_signer_role(prefix)

  @doc "`%{\"name\", \"configured\", \"held\"}`: whether the role is set up and whether `user_id` holds it."
  @spec status(String.t(), term()) :: map()
  def status(prefix, user_id) when is_binary(prefix) do
    name = role(prefix)
    configured = configured?(prefix, name)

    %{
      "name" => name,
      "configured" => configured,
      "held" => configured and held?(prefix, user_id, name)
    }
  end

  @doc "`:ok`, `{:error, :signer_role_not_configured}` or `{:error, :signer_role_not_held}`."
  @spec check(String.t(), term()) ::
          :ok | {:error, :signer_role_not_configured | :signer_role_not_held}
  def check(prefix, user_id) when is_binary(prefix) do
    case status(prefix, user_id) do
      %{"configured" => false} -> {:error, :signer_role_not_configured}
      %{"held" => false} -> {:error, :signer_role_not_held}
      _ -> :ok
    end
  end

  defp configured?(prefix, name) do
    Repo.exists?(
      from(t in TenantRole, where: t.name == ^name and t.kind == :process_routing_role),
      prefix: prefix
    )
  end

  defp held?(prefix, user_id, name) when is_binary(user_id) do
    name in Tasks.resolve_principal_scope(user_id, prefix: prefix).role_names
  end

  defp held?(_prefix, _user_id, _name), do: false
end
