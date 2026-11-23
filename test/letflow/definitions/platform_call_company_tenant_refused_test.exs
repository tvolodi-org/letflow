defmodule Letflow.Definitions.PlatformCallCompanyTenantRefusedTest do
  @moduledoc """
  S3 of the platform-call authority rule (T-2588, "Register a tenant" pilot, gap
  G2; decision record `docs/migration/decisions/0094-platform-call-authority.md`,
  decision (b)): a COMPANY tenant may not carry a `platform_call` step at all.

  The threat S3 names: a company-tenant definition (imported, or drawn by its
  admin) carries a `platform_call` step and reaches the platform's code.

  The rule: the answer is ONE fixed code, `:platform_call_not_allowed`, on every
  path -- the write path of a draft, the import, the designer's validate route,
  the activation and the promotion -- and the same answer whether the function
  exists or not (INV-5: a stranger may not learn which platform functions
  exist).

  `async: false`: the platform tenant pin is application configuration, which is
  VM-global.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Definitions.ExportImport
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.Promotion
  alias Letflow.Definitions.PromotionDigest
  alias Letflow.Definitions.PromotionReview
  alias Letflow.Repo
  alias Letflow.Support.PlatformCallFixture, as: Fx
  alias Letflow.Support.PlatformTenantFixture, as: PlatformFx

  setup do
    company = Fx.tenant!("t2588-s3-company")
    platform = Fx.tenant!("t2588-s3-platform")
    PlatformFx.pin!(platform.tenant_id)

    %{company: company, platform: platform}
  end

  defp create_call do
    Fx.call("tenant.create", %{
      "slug" => %{"var" => "slug"},
      "name" => %{"const" => "Acme"}
    })
  end

  # A definition row written straight into the company tenant's schema, the way a
  # row that predates the rule (or a forged row) would be there. The write path
  # itself refuses such a graph, so the validate route is exercised with a row
  # that exists.
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

  test "S3a: the write path refuses a company-tenant definition with a platform_call", ctx do
    assert {:error, {:platform_calls_invalid, [%{code: :platform_call_not_allowed}]}} =
             Definitions.create(
               %{
                 name: "pcf-s3a",
                 version: "1",
                 graph: Fx.graph(create_call()),
                 created_by: Ecto.UUID.generate()
               },
               prefix: ctx.company.schema_name
             )

    assert Repo.aggregate(from(d in ProcessDefinition, where: d.name == "pcf-s3a"), :count,
             prefix: ctx.company.schema_name
           ) == 0
  end

  test "S3b: the import path refuses it with the same one code", ctx do
    document = %ExportImport.ExportDocument{
      bpm_export_schema_version: ExportImport.export_schema_version(),
      id: Ecto.UUID.generate(),
      name: "pcf-s3b",
      version: "1",
      graph: Fx.graph(create_call()),
      exported_at: DateTime.utc_now()
    }

    assert {:error, {:platform_calls_invalid, [%{code: :platform_call_not_allowed}]}} =
             ExportImport.import(document, Ecto.UUID.generate(), prefix: ctx.company.schema_name)
  end

  test "S3c: the designer's validate route refuses it with the same one code", ctx do
    forged = forged_definition!(ctx.company.schema_name, "pcf-s3c")

    assert {:ok, %{valid: false, violations: violations}} =
             Definitions.validate_definition_graph(forged.id, prefix: ctx.company.schema_name)

    assert [%{code: :platform_call_not_allowed}] = violations
  end

  test "S3d: the activation refuses it with the same one code", ctx do
    forged = forged_definition!(ctx.company.schema_name, "pcf-s3d")

    assert {:error, {:platform_calls_invalid, [%{code: :platform_call_not_allowed}]}} =
             Definitions.activate(forged.id, prefix: ctx.company.schema_name)

    assert %{status: :draft} =
             Repo.get!(ProcessDefinition, forged.id, prefix: ctx.company.schema_name)
  end

  test "S3e: the promotion path refuses the copy in the target tenant", ctx do
    key = "pcf-s3e"

    source =
      Fx.definition!(ctx.platform.schema_name, Fx.graph(create_call()), key)

    {1, _} =
      Repo.update_all(
        from(d in ProcessDefinition, where: d.id == ^source.id),
        [set: [status: :active]],
        prefix: ctx.platform.schema_name
      )

    plan = %{
      source_tenant_id: ctx.platform.tenant_id,
      target_tenant_id: ctx.company.tenant_id,
      process_key: key,
      source_definition_id: source.id,
      target_definition_id: nil,
      base_version: nil,
      entries: []
    }

    review =
      struct(PromotionReview, %{
        id: Ecto.UUID.generate(),
        plan_digest: PromotionDigest.compute_plan_digest(plan),
        def_id: key,
        serialised_plan: Jason.encode!(plan),
        requested_by: Ecto.UUID.generate(),
        status: :approved,
        row_version: 2
      })

    assert {:error, {:platform_calls_invalid, [%{code: :platform_call_not_allowed}]}} =
             Promotion.promote_definition(Ecto.UUID.generate(), review,
               activator: nil,
               permission_checker: fn _actor, _tenant -> true end,
               event_appender: fn _attrs, _prefix -> {:ok, %{event_id: Ecto.UUID.generate()}} end
             )

    assert Repo.aggregate(from(d in ProcessDefinition, where: d.name == ^key), :count,
             prefix: ctx.company.schema_name
           ) == 0
  end

  test "S3f: the platform tenant may DRAFT the step (drawing it is a DefinitionsWrite matter)",
       ctx do
    assert {:ok, definition} =
             Definitions.create(
               %{
                 name: "pcf-s3f",
                 version: "1",
                 graph: Fx.graph(create_call()),
                 created_by: Ecto.UUID.generate()
               },
               prefix: ctx.platform.schema_name
             )

    assert definition.status == :draft
  end
end
