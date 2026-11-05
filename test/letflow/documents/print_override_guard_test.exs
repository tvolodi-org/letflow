defmodule Letflow.Documents.PrintOverrideGuardTest do
  @moduledoc """
  REQ-624 / GH #3485 criterion 5: `guard_document_versions()` lets the four print-override pin
  columns be set on the draft -> issued transition and nowhere else. Raw SQL, no context.
  Design: state/tasks/T-1281/design.md, test G1.
  """

  use Letflow.DataCase, async: false

  import Letflow.DocumentSqlFixture

  alias Letflow.TenantProvisioning

  @pin "template_version = 'print-layout-v1', print_override_id = gen_random_uuid(), print_override_version = 1, print_override_layout_hash = repeat('a', 64)"
  @hex String.duplicate("b", 64)

  setup do
    %{schema_name: schema, tenant_id: tenant_id} = provisioned_tenant!("req624-gd")
    type_key = insert_type!(schema, tenant_id)
    doc = insert_document!(schema, tenant_id, type_key)
    version = insert_version!(schema, tenant_id, doc, 1)
    %{schema: schema, version: version}
  end

  defp set(ctx, sql_set, params \\ []) do
    attempt(
      "UPDATE #{table(ctx.schema, "document_versions")} SET #{sql_set} WHERE id = $1::uuid",
      [ctx.version | params]
    )
  end

  defp issue_sql(extra),
    do:
      "status = 'issued', issued_at = now(), issued_by = gen_random_uuid(), content_hash = repeat('f', 64)" <>
        extra

  test "G1a the pin may be set while the draft is issued", ctx do
    assert :accepted = set(ctx, issue_sql(", " <> @pin))

    assert %{rows: [["print-layout-v1", 1]]} =
             exec!(
               "SELECT template_version, print_override_version FROM #{table(ctx.schema, "document_versions")} WHERE id = $1::uuid",
               [ctx.version]
             )
  end

  test "G1b the pin cannot be set on a draft that stays a draft", ctx do
    assert {:refused, _} = set(ctx, @pin)
  end

  test "G1c the pin cannot change once the version is issued, artefact_hash still opens", ctx do
    assert :accepted = set(ctx, issue_sql(", " <> @pin))
    assert {:refused, _} = set(ctx, "print_override_version = 2")
    assert {:refused, _} = set(ctx, "print_override_id = NULL")
    assert {:refused, _} = set(ctx, "template_version = 'x'")
    assert {:refused, _} = set(ctx, "print_override_layout_hash = repeat('b', 64)")
    assert {:refused, _} = set(ctx, "artefact_hash = $2, print_override_version = 2", [@hex])
    assert :accepted = set(ctx, "artefact_hash = $2", [@hex])
  end

  test "G1d the migration is in the replay manifest", _ctx do
    assert {20_261_105_400_001, Letflow.Repo.Migrations.AddPrintOverridePinToDocumentVersions} in TenantProvisioning.tenant_scoped_migrations()
  end
end
