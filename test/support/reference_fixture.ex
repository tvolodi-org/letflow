defmodule Letflow.ReferenceFixture do
  @moduledoc """
  Test support (REQ-636, GH #3556): a fresh tenant with `fixture_ref_targets` installed and one
  tenant-owned type `ref_holder` whose string fields `target`, `other` and `ghost` declare a
  module reference to `frt_target`, `frt_other` (not opted in) and a module that does not exist.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.Modules.FixtureRefTargets
  alias Letflow.Modules.Installs
  alias Letflow.Repo
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning.ColumnPromotion

  @holder "ref_holder"

  def holder, do: @holder

  @doc "A tenant context map: `:schema_name`, `:slug`, `:plaintext` (a TENANT_ADMIN token), `:user_id`."
  def tenant!(slug_prefix) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)

    cleanup_on_exit(tenant.tenant_id)

    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)

    {:ok, _} =
      Installs.install("fixture_ref_targets", Ecto.UUID.generate(),
        prefix: tenant.schema_name,
        rationale: "REQ-636 reference test"
      )

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "req636-user-#{Ecto.UUID.generate()}",
        display_name: "REQ-636 test user",
        email: "req636-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: tenant.schema_name)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
        prefix: tenant.schema_name
      )

    ctx = %{
      schema_name: tenant.schema_name,
      slug: tenant.tenant.slug,
      plaintext: plaintext,
      user_id: user.id
    }

    holder!(ctx)
    ctx
  end

  @doc "Deletes the module-install rows of the tenant at test exit (they reference the tenant)."
  def cleanup_on_exit(tenant_id) do
    ExUnit.Callbacks.on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant_id))

      Repo.delete_all(from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant_id))

      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant_id))
    end)
  end

  defp holder!(ctx) do
    ref = fn module_id, type -> %{"module_id" => module_id, "entity_type" => type} end

    {:ok, _} =
      Definitions.create_definition(
        %{
          definition: %{
            name: @holder,
            display_name: "Reference holder",
            fields: [
              %{name: "title", type: :string},
              %{
                name: "target",
                type: :string,
                reference: ref.("fixture_ref_targets", "frt_target")
              },
              %{
                name: "other",
                type: :string,
                reference: ref.("fixture_ref_targets", "frt_other")
              },
              %{name: "ghost", type: :string, reference: ref.("no_such_module", "frt_target")}
            ]
          },
          created_by: ctx.user_id
        },
        ctx.schema_name
      )

    {:ok, _} = Definitions.activate_definition(@holder, ctx.user_id, "req636", ctx.schema_name)
    :ok
  end

  @doc "Creates a target-module record (default `frt_target`, active) and returns its id."
  def target!(ctx, type \\ "frt_target", active \\ true) do
    {:ok, %{record: record}} =
      FixtureRefTargets.create_record(
        type,
        %{"name" => "t-#{System.unique_integer([:positive])}", "active" => active},
        ctx.schema_name
      )

    record.record_id
  end
end
