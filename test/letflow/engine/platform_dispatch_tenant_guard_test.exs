defmodule Letflow.Engine.PlatformDispatchTenantGuardTest do
  @moduledoc """
  S3b of the platform-call authority rule (T-2588, "Register a tenant" pilot,
  gap G2; decision record `docs/migration/decisions/0094-platform-call-authority.md`):
  the dispatcher's own tenant guard.

  The threat: a forged dispatch row in a company schema -- a row that claims a
  platform function and points at a definition the company tenant wrote. The
  rule: the dispatcher checks the instance's tenant AGAIN (INV-10), so the call
  never runs outside the platform tenant, whatever the row claims.

  `async: false`: the platform tenant pin is application configuration, which is
  VM-global.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.PlatformFunctions.Guard
  alias Letflow.Repo
  alias Letflow.Support.PlatformCallFixture, as: Fx
  alias Letflow.Support.PlatformTenantFixture, as: PlatformFx

  setup do
    company = Fx.tenant!("t2588-s3b-company")
    platform = Fx.tenant!("t2588-s3b-platform")
    PlatformFx.pin!(platform.tenant_id)

    %{company: company, platform: platform}
  end

  defp create_call do
    Fx.call("tenant.create", %{
      "slug" => %{"var" => "slug"},
      "name" => %{"const" => "Acme"}
    })
  end

  # A row written straight into a company tenant's schema: the shape a forged
  # dispatch row would have.
  defp forged_definition!(schema_name, name) do
    %ProcessDefinition{}
    |> ProcessDefinition.create_changeset(%{
      name: name,
      version: "1",
      graph: Fx.graph(create_call()),
      created_by: Ecto.UUID.generate()
    })
    |> Repo.insert!(prefix: schema_name)
  end

  test "S3b-a: a forged dispatch row in a company schema is refused", ctx do
    forged = forged_definition!(ctx.company.schema_name, "pcf-s3b")

    assert {:error, :platform_call_tenant_not_allowed} =
             Guard.authorize_dispatch(
               definition: forged,
               prefix: ctx.company.schema_name,
               tenant_id: ctx.company.tenant_id,
               function: "tenant.create"
             )
  end

  test "S3b-b: a row that claims the platform tenant but runs in a company one is refused", ctx do
    forged = forged_definition!(ctx.company.schema_name, "pcf-s3b-b")

    # the row points at the platform tenant (the forged part), the call runs in
    # the company tenant (the instance's own tenant): the instance's tenant wins
    assert {:error, :platform_call_tenant_not_allowed} =
             Guard.authorize_dispatch(
               definition: forged,
               prefix: ctx.company.schema_name,
               tenant_id: ctx.platform.tenant_id,
               function: "tenant.create"
             )

    # and the other way round: the row is in the platform tenant, the instance
    # is not
    assert {:error, :platform_call_tenant_not_allowed} =
             Guard.authorize_dispatch(
               definition: forged,
               prefix: ctx.platform.schema_name,
               tenant_id: ctx.company.tenant_id,
               function: "tenant.create"
             )
  end

  test "S3b-c: a call in a company tenant is refused even without a definition row", ctx do
    assert {:error, :platform_call_tenant_not_allowed} =
             Guard.authorize_dispatch(
               definition: %{},
               prefix: ctx.company.schema_name,
               tenant_id: ctx.company.tenant_id,
               function: "tenant.create"
             )
  end
end
