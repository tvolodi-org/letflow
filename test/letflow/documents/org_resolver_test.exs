defmodule Letflow.Documents.OrgResolverTest do
  @moduledoc """
  REQ-542 / GH #3164 criteria 3 and 4a: the org-resolver contract and the default resolver.
  Design: state/tasks/T-0474/design.md, tests O1..O3.
  """

  use Letflow.DataCase, async: false

  import Letflow.DocumentSqlFixture

  alias Letflow.Documents.OrgResolver.Default
  alias Letflow.Documents.OrgResolverContract
  alias Letflow.Documents.TestResolvers
  alias Letflow.ScopeNodePaths

  setup do
    %{schema_name: schema, tenant_id: tenant_id} = provisioned_tenant!("req542-or")
    active = Ecto.UUID.generate()
    retired = Ecto.UUID.generate()
    {:ok, _} = ScopeNodePaths.write({:insert, active, nil}, schema)
    {:ok, _} = ScopeNodePaths.write({:insert, retired, nil}, schema)
    {:ok, _} = ScopeNodePaths.write({:retire, retired}, schema)

    %{
      schema: schema,
      tenant_id: tenant_id,
      units: %{prefix: schema, active: active, retired: retired, absent: Ecto.UUID.generate()}
    }
  end

  test "O1: the default resolver meets the contract and has no legal entity", ctx do
    assert :ok = OrgResolverContract.run(Default, ctx.units)
    assert {:error, :no_legal_entity} = Default.legal_entity_of(ctx.schema, ctx.units.active)
    assert {:error, :no_legal_entity} = Default.legal_entity_of(ctx.schema, ctx.units.absent)
    refute Default.unit_exists?(ctx.schema, "not-a-uuid")
  end

  test "O2: the contract fails a resolver that hides a retired unit's entity", ctx do
    assert_raise ExUnit.AssertionError, fn ->
      OrgResolverContract.run(TestResolvers.RetiredWrong, ctx.units)
    end
  end

  test "O3: an issued document keeps its unit and entity when the unit is retired", ctx do
    type = insert_type!(ctx.schema, ctx.tenant_id)

    doc =
      insert_document!(ctx.schema, ctx.tenant_id, type, issuing_org_unit_id: ctx.units.retired)

    v = insert_version!(ctx.schema, ctx.tenant_id, doc, 1, "issued")
    set_current!(ctx.schema, doc, v)

    assert [[unit]] =
             exec!(
               "SELECT issuing_org_unit_id::text FROM #{table(ctx.schema, "documents")} WHERE id = $1::uuid",
               [doc]
             ).rows

    assert unit == ctx.units.retired
    assert [nil, nil, nil, ^v] = document_row(ctx.schema, doc)
  end
end
