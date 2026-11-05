defmodule Letflow.CreateEntityScopeDeclarationsTest do
  @moduledoc """
  REQ-635 / GH #3549 criteria 6 and 10 (tests X4, G1): the tenant migration that creates the
  empty `entity_scope_declarations` table. `async: false` (tenant provisioning and DDL).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Repo.Migrations.CreateEntityScopeDeclarations
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @version 20_261_105_200_001

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "r635-mig")
    {:ok, schema: tenant.schema_name}
  end

  defp columns(schema) do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns " <>
          "WHERE table_schema = $1 AND table_name = 'entity_scope_declarations'",
        [schema]
      )

    rows |> List.flatten() |> Enum.sort()
  end

  test "G1 registered second to last (REQ-623 follows); the table starts empty", %{schema: schema} do
    assert {@version, CreateEntityScopeDeclarations} =
             Enum.at(TenantProvisioning.tenant_scoped_migrations(), -2)

    assert %{rows: [[0]]} =
             Repo.query!(~s|SELECT count(*) FROM "#{schema}".entity_scope_declarations|)
  end

  test "X4 the table has no tenant_id column and is not in the public schema", %{schema: schema} do
    assert columns(schema) ==
             ~w(entity_type field id inserted_at kind set_by updated_at)

    assert columns("public") == []
  end

  test "the kind/field check constraint refuses an inconsistent row", %{schema: schema} do
    insert = fn kind, field ->
      Repo.query(
        ~s|INSERT INTO "#{schema}".entity_scope_declarations| <>
          ~s| (id, entity_type, kind, field, set_by, inserted_at, updated_at)| <>
          ~s| VALUES (gen_random_uuid(), $1, $2, $3, gen_random_uuid(), now(), now())|,
        ["t_" <> Integer.to_string(System.unique_integer([:positive])), kind, field]
      )
    end

    assert {:error, _} = insert.("tenant_wide", "f")
    assert {:error, _} = insert.("column", nil)
    assert {:ok, _} = insert.("tenant_wide", nil)
    assert {:ok, _} = insert.("column", "f")
  end
end
