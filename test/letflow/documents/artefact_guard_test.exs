defmodule Letflow.Documents.ArtefactGuardTest do
  @moduledoc """
  REQ-623 / GH #3474 criterion 4 (decision 0075 R3): `guard_document_versions()` opens
  `artefact_hash` exactly once on an issued row. Raw SQL, no context. Design tests G1..G4, G6;
  G5 is `triggers_test.exs` and `constraints_test.exs` run unchanged.
  """

  use Letflow.DataCase, async: false

  import Letflow.DocumentSqlFixture

  alias Letflow.TenantProvisioning

  @hex String.duplicate("b", 64)
  @other String.duplicate("c", 64)

  setup do
    %{schema_name: schema, tenant_id: tenant_id} = provisioned_tenant!("req623-gd")
    type_key = insert_type!(schema, tenant_id)
    doc = insert_document!(schema, tenant_id, type_key)
    version = insert_version!(schema, tenant_id, doc, 1)
    issue!(schema, version)
    %{schema: schema, version: version}
  end

  defp set(ctx, sql_set, params \\ []) do
    attempt(
      "UPDATE #{table(ctx.schema, "document_versions")} SET #{sql_set} WHERE id = $1::uuid",
      [ctx.version | params]
    )
  end

  test "G1: NULL to a 64-hex value is accepted on an issued row", ctx do
    assert :accepted = set(ctx, "artefact_hash = $2", [@hex])

    assert %{rows: [[@hex]]} =
             exec!(
               "SELECT artefact_hash FROM #{table(ctx.schema, "document_versions")} WHERE id = $1::uuid",
               [ctx.version]
             )
  end

  test "G2: once set, the value cannot change or be cleared", ctx do
    assert :accepted = set(ctx, "artefact_hash = $2", [@hex])
    assert {:refused, _} = set(ctx, "artefact_hash = $2", [@other])
    assert {:refused, _} = set(ctx, "artefact_hash = NULL")
    assert {:refused, error} = set(ctx, "artefact_hash = $2", [@hex])
    assert refusal_message({:refused, error}) =~ "not allowed"
  end

  test "G3: nothing else on an issued row changes, alone or with the artefact hash", ctx do
    assert {:refused, _} = set(ctx, "cancel_reason = 'x'")
    assert {:refused, _} = set(ctx, "content = '{\"a\":1}'::jsonb")
    assert {:refused, _} = set(ctx, "cancel_reason = 'x', artefact_hash = $2", [@hex])
    assert {:refused, _} = set(ctx, "content_hash = $2", [@hex])
    assert {:refused, _} = set(ctx, "status = 'issued'")
  end

  test "G4: a value that is not 64 lowercase hex is refused", ctx do
    for bad <- ["abc", String.upcase(@hex), @hex <> "0", ""] do
      assert {:refused, _} = set(ctx, "artefact_hash = $2", [bad])
    end

    assert {:refused, _} = set(ctx, "artefact_hash = NULL")
  end

  test "G4b: old transitions are unchanged: a draft cannot take an artefact hash", ctx do
    %{rows: [[tenant]]} =
      exec!("SELECT tenant_id::text FROM #{table(ctx.schema, "document_versions")} LIMIT 1")

    doc = insert_document!(ctx.schema, tenant, "purchase_request")
    draft = insert_version!(ctx.schema, tenant, doc, 1)

    assert {:refused, _} =
             attempt(
               "UPDATE #{table(ctx.schema, "document_versions")} SET artefact_hash = $2 WHERE id = $1::uuid",
               [draft, @hex]
             )

    assert {:refused, _} = set(ctx, "status = 'draft'")
  end

  test "G5: the three triggers stay ENABLE ALWAYS", ctx do
    %{rows: rows} =
      exec!(
        """
        SELECT t.tgname, t.tgenabled FROM pg_trigger t
          JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = $1 AND c.relname = 'document_versions' AND NOT t.tgisinternal
        """,
        [ctx.schema]
      )

    assert length(rows) == 3
    assert Enum.all?(rows, fn [_name, enabled] -> enabled == "A" end)
  end

  test "G6: the migration is in the replay manifest and the provisioned body has the branch",
       ctx do
    assert {20_261_105_200_001, Letflow.Repo.Migrations.OpenDocumentArtefactHashWriteOnce} in TenantProvisioning.tenant_scoped_migrations()

    assert %{rows: [[true]]} =
             exec!(
               """
               SELECT p.prosrc LIKE '%artefact_hash%' FROM pg_proc p
                 JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = $1 AND p.proname = 'guard_document_versions'
               """,
               [ctx.schema]
             )
  end
end
