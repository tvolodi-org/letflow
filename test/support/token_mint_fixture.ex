defmodule Letflow.Support.TokenMintFixture do
  @moduledoc """
  GH 2552 (decision 0051 M2, design `lib/letflow/design/gh2552-api-token-issuer-and-roles.md`
  sections 3 and 7): `POST /identity/tokens` now mints through `Letflow.Identity.mint_token/4`,
  which requires the CALLER to be an active user holding `TENANT_ADMIN` (or, in the platform
  tenant, `PLATFORM_ADMIN`) by GROUP MEMBERSHIP, and requires the token's roles to be held by
  both the caller and the target the same way. A hand-assigned `auth_context` with a random
  `user_id` therefore gets 403. These helpers give a test a real caller and target.

  Group membership only: a token's roles never count as held (supervisor OQ1 ruling).
  """

  import Ecto.Query

  alias Letflow.Identity.Group
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.RoleScopeGrants
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User
  alias Letflow.Repo

  @doc """
  Makes `user_id` a member of the group each name in `roles` is bound to
  (`kind: :platform_role`) in the tenant schema `schema_name`. A role with no binding yet
  gets a fresh group and a raw binding row (the default seed keeps an existing binding,
  so a later `RoleRegistry.seed_default_platform_role_groups/1` still works). Memberships
  are raw rows: no audit entry. Idempotent. Returns `user_id`.
  """
  @spec grant_roles!(String.t(), Ecto.UUID.t(), [String.t()]) :: Ecto.UUID.t()
  def grant_roles!(schema_name, user_id, roles) when is_binary(schema_name) do
    for role <- roles do
      group_id = binding_group_id!(schema_name, role)

      Repo.insert!(%GroupMember{group_id: group_id, user_id: user_id},
        prefix: schema_name,
        on_conflict: :nothing
      )
    end

    user_id
  end

  @doc """
  Inserts an active internal user in `schema_name` and grants it `roles` by group
  membership (`grant_roles!/3`). Returns the `%User{}`.
  """
  @spec role_holder!(String.t(), [String.t()], keyword()) :: User.t()
  def role_holder!(schema_name, roles, attrs \\ []) when is_binary(schema_name) do
    n = Ecto.UUID.generate()

    user =
      %User{}
      |> Ecto.Changeset.change(
        Map.merge(
          %{
            username: "gh2552-holder-#{n}",
            display_name: "GH2552 Role Holder",
            email: "gh2552-holder-#{n}@example.com",
            password_hash: "__NO_PASSWORD_SET__",
            status: :active,
            auth_source: :internal
          },
          Map.new(attrs)
        )
      )
      |> Repo.insert!(prefix: schema_name)

    grant_roles!(schema_name, user.id, roles)
    user
  end

  defp binding_group_id!(schema_name, role) do
    query =
      from(t in TenantRole,
        where: t.name == ^role and t.kind == :platform_role,
        select: t.group_id
      )

    case Repo.one(query, prefix: schema_name) do
      # REQ-497 PR 1b (design section 11): a new binding gets its tenant-wide group row in
      # the same transaction, so the fixture leaves no T9 gap. Still raw rows, no audit.
      nil ->
        {:ok, group_id} =
          Repo.transaction(fn ->
            group =
              %Group{}
              |> Ecto.Changeset.change(%{name: "gh2552-#{role}-#{Ecto.UUID.generate()}"})
              |> Repo.insert!(prefix: schema_name)

            %TenantRole{}
            |> Ecto.Changeset.change(%{name: role, kind: :platform_role, group_id: group.id})
            |> Repo.insert!(prefix: schema_name)

            _ = RoleScopeGrants.ensure_tenant_wide_group_row!(group.id, role, schema_name)
            group.id
          end)

        group_id

      group_id ->
        group_id
    end
  end
end
