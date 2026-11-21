defmodule Letflow.Support.PlatformCallFixture do
  @moduledoc """
  Fixtures for the platform-call authority rule (T-2588, "Register a tenant"
  pilot, gap G2; decision record
  `docs/migration/decisions/0094-platform-call-authority.md`).

  A `platform_call` step is a SERVICE_TASK bound to a platform function of the
  compiled catalogue. These helpers build the pieces the authority rule needs:

    * `tenant!/1` -- a provisioned tenant (the platform tenant is pinned by the
      caller, so `Letflow.PlatformTenant.platform_prefix?/1` answers for it);
    * `user!/2` -- an active user;
    * `platform_admin!/2` -- a user holding the `PLATFORM_ADMIN` platform role
      (a `:platform_role` binding, the only role that holds `:TenantsManage`);
    * `graph/1` -- START -> the platform-call SERVICE_TASK -> END;
    * `definition!/3` -- a DRAFT carrying that graph.

  Real Postgres, no mocks. Every helper takes no optional argument (the
  project's anti-pattern ISS-0069).
  """

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Identity.Group
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User
  alias Letflow.Repo
  alias Letflow.TenantFixture

  @doc "A provisioned tenant: `%{tenant_id, schema_name}`."
  @spec tenant!(String.t()) :: %{tenant_id: String.t(), schema_name: String.t()}
  def tenant!(slug_prefix) do
    %{tenant_id: tenant_id, schema_name: schema_name} =
      TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)

    %{tenant_id: tenant_id, schema_name: schema_name}
  end

  @doc "An active user of `schema_name`."
  @spec user!(String.t(), String.t()) :: User.t()
  def user!(schema_name, label) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "pcf-#{label}-#{Ecto.UUID.generate()}",
      display_name: "PCF #{label}",
      email: "pcf-#{label}-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema_name)
  end

  @doc """
  Gives `user` the `PLATFORM_ADMIN` platform role in `schema_name` (a
  `:platform_role` binding -- the kind `Identity.list_effective_role_names/2`
  reads).
  """
  @spec platform_admin!(String.t(), User.t()) :: :ok
  def platform_admin!(schema_name, user) do
    group =
      %Group{}
      |> Ecto.Changeset.change(%{
        name: "pcf-platform-admin-#{Ecto.UUID.generate()}",
        display_name: "PCF Platform Admin"
      })
      |> Repo.insert!(prefix: schema_name)

    %TenantRole{}
    |> Ecto.Changeset.change(%{name: "PLATFORM_ADMIN", kind: :platform_role, group_id: group.id})
    |> Repo.insert!(prefix: schema_name)

    %GroupMember{}
    |> Ecto.Changeset.change(%{group_id: group.id, user_id: user.id})
    |> Repo.insert!(prefix: schema_name)

    :ok
  end

  @doc "Removes every platform-role binding of `user` in `schema_name` (a revoked role)."
  @spec revoke_platform_roles!(String.t(), User.t()) :: :ok
  def revoke_platform_roles!(schema_name, user) do
    Repo.delete_all(
      from(gm in GroupMember, where: gm.user_id == ^user.id),
      prefix: schema_name
    )

    :ok
  end

  @doc """
  The `platform_call` attribute of a step: `%{"function" => name, "args" => args}`.
  """
  @spec call(String.t(), map()) :: map()
  def call(function, args), do: %{"function" => function, "args" => args}

  @doc """
  START -> a SERVICE_TASK carrying the `platform_call` `call` -> END. `extra`
  is merged into the SERVICE_TASK's attributes.
  """
  @spec graph(map(), map()) :: map()
  def graph(call, extra \\ %{}) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "call",
          "node_type" => "SERVICE_TASK",
          "attributes" => Map.merge(%{"platform_call" => call}, extra)
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "call"},
        %{"id" => "e2", "source" => "call", "target" => "end"}
      ]
    }
  end

  @doc """
  A DRAFT definition carrying `graph`. `name` must be unique in the tenant.
  """
  @spec definition!(String.t(), map(), String.t()) :: Definitions.ProcessDefinition.t()
  def definition!(schema_name, graph, name) do
    {:ok, definition} =
      Definitions.create(
        %{
          name: name,
          version: "1",
          graph: graph,
          created_by: Ecto.UUID.generate()
        },
        prefix: schema_name
      )

    definition
  end
end
