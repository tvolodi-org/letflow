defmodule Letflow.Documents.ConstraintsTest do
  @moduledoc """
  REQ-500 / GH #2588, PR A: the shape-level constraints of the document tables (design
  section 6, test IDs A-15, A-16, A-18, A-19). These hold without any trigger: a unique
  index, a composite foreign key, a check or a NOT NULL. Raw SQL, no context (design D-15).

  The unique index on documents is partial (`WHERE number IS NOT NULL`, design D-6): drafts
  have no number, so `NULLS NOT DISTINCT` must not make two drafts collide. The index test
  lives here, not in a numbering test, because it is a property of the schema (design F4).
  """

  use Letflow.DataCase, async: false

  import Letflow.DocumentSqlFixture

  setup do
    %{schema_name: schema, tenant_id: tenant_id} = provisioned_tenant!("req500-cons")
    type_key = insert_type!(schema, tenant_id)
    %{schema: schema, tenant_id: tenant_id, type_key: type_key}
  end

  # An issued, numbered document of the type: the row the number index sees.
  # The legal entity is written with the number, as the issue will do: the index sees the
  # whole key at the moment the number is set.
  defp numbered_document(ctx, number, legal_entity_id \\ nil) do
    document_id = insert_document!(ctx.schema, ctx.tenant_id, ctx.type_key)
    version_id = insert_version!(ctx.schema, ctx.tenant_id, document_id, 1)
    issue!(ctx.schema, version_id)

    exec!(
      "UPDATE #{table(ctx.schema, "documents")} SET number = $2, period = '2026', legal_entity_id = $3::uuid WHERE id = $1::uuid",
      [document_id, number, legal_entity_id]
    )

    document_id
  end

  describe "A-15: at most one issued version per document" do
    test "a second issued version is refused by the partial unique index, inserted or issued",
         ctx do
      document_id = insert_document!(ctx.schema, ctx.tenant_id, ctx.type_key)
      insert_version!(ctx.schema, ctx.tenant_id, document_id, 1, "issued")

      assert {:refused, error} =
               attempt(
                 "INSERT INTO #{table(ctx.schema, "document_versions")} (id, tenant_id, document_id, version_no, status, content, content_hash, issued_at, issued_by, inserted_at) VALUES ($1::uuid, $2::uuid, $3::uuid, 2, 'issued', '{}'::jsonb, $4, now(), $5::uuid, now())",
                 [
                   Ecto.UUID.generate(),
                   ctx.tenant_id,
                   document_id,
                   String.duplicate("e", 64),
                   Ecto.UUID.generate()
                 ]
               )

      assert error.postgres.code == :unique_violation

      draft = insert_version!(ctx.schema, ctx.tenant_id, document_id, 3)

      assert {:refused, error} =
               attempt(
                 "UPDATE #{table(ctx.schema, "document_versions")} SET status = 'issued', issued_at = now(), issued_by = $2::uuid, content_hash = $3 WHERE id = $1::uuid",
                 [draft, Ecto.UUID.generate(), String.duplicate("f", 64)]
               )

      assert error.postgres.code == :unique_violation
    end
  end

  describe "A-16: NULLS NOT DISTINCT number index" do
    test "two issued rows with the same type, period and number are rejected, NULL entity included",
         ctx do
      numbered_document(ctx, 7)

      doc2 = insert_document!(ctx.schema, ctx.tenant_id, ctx.type_key)
      v2 = insert_version!(ctx.schema, ctx.tenant_id, doc2, 1)
      issue!(ctx.schema, v2)

      assert {:refused, error} =
               attempt(
                 "UPDATE #{table(ctx.schema, "documents")} SET number = 7, period = '2026' WHERE id = $1::uuid",
                 [doc2]
               )

      assert error.postgres.code == :unique_violation
    end

    test "the same number under a NULL entity and under a set entity are different keys", ctx do
      numbered_document(ctx, 3)
      numbered_document(ctx, 3, Ecto.UUID.generate())

      # Same type and period, number 3, entity NULL vs entity set: two keys, both accepted.
      assert %{rows: [[2]]} =
               exec!(
                 "SELECT count(*)::int FROM #{table(ctx.schema, "documents")} WHERE number = 3"
               )
    end

    test "drafts with no number coexist for one type", ctx do
      insert_document!(ctx.schema, ctx.tenant_id, ctx.type_key)
      insert_document!(ctx.schema, ctx.tenant_id, ctx.type_key)

      assert %{rows: [[2]]} =
               exec!(
                 "SELECT count(*)::int FROM #{table(ctx.schema, "documents")} WHERE number IS NULL"
               )
    end

    test "the index is NULLS NOT DISTINCT and partial on number IS NOT NULL", ctx do
      %{rows: [[definition]]} =
        exec!(
          "SELECT pg_get_indexdef(i.oid) FROM pg_index x JOIN pg_class i ON i.oid = x.indexrelid " <>
            "JOIN pg_class t ON t.oid = x.indrelid JOIN pg_namespace n ON n.oid = t.relnamespace " <>
            "WHERE n.nspname = $1 AND i.relname = 'documents_number_key'",
          [ctx.schema]
        )

      assert definition =~ "NULLS NOT DISTINCT"
      assert definition =~ "WHERE (number IS NOT NULL)"
    end
  end

  describe "A-18: the scope column is NOT NULL" do
    test "issuing_org_unit_id cannot be NULL on insert", ctx do
      assert {:refused, error} =
               attempt(
                 "INSERT INTO #{table(ctx.schema, "documents")} (id, tenant_id, type_key, issuing_org_unit_id, inserted_at) VALUES ($1::uuid, $2::uuid, $3, NULL, now())",
                 [Ecto.UUID.generate(), ctx.tenant_id, ctx.type_key]
               )

      assert error.postgres.code == :not_null_violation
    end
  end

  describe "A-19: artefact_hash stays NULL and no slice-2 column exists" do
    test "documents has no hold column and document_versions.artefact_hash is NULL on every row",
         ctx do
      %{rows: columns} =
        exec!(
          "SELECT column_name FROM information_schema.columns WHERE table_schema = $1 AND table_name = 'documents'",
          [ctx.schema]
        )

      refute ["hold"] in columns

      document_id = insert_document!(ctx.schema, ctx.tenant_id, ctx.type_key)
      insert_version!(ctx.schema, ctx.tenant_id, document_id, 1)

      assert %{rows: [[0]]} =
               exec!(
                 "SELECT count(*)::int FROM #{table(ctx.schema, "document_versions")} WHERE artefact_hash IS NOT NULL"
               )
    end
  end

  describe "composite foreign keys tie a version to its own document" do
    test "superseded_by_version must belong to the same document", ctx do
      doc_a = insert_document!(ctx.schema, ctx.tenant_id, ctx.type_key)
      doc_b = insert_document!(ctx.schema, ctx.tenant_id, ctx.type_key)
      v_a1 = insert_version!(ctx.schema, ctx.tenant_id, doc_a, 1, "issued")
      v_b2 = insert_version!(ctx.schema, ctx.tenant_id, doc_b, 2)

      assert {:refused, error} =
               attempt(
                 "UPDATE #{table(ctx.schema, "document_versions")} SET status = 'superseded', superseded_by_version = $2::uuid WHERE id = $1::uuid",
                 [v_a1, v_b2]
               )

      assert error.postgres.code == :foreign_key_violation
    end
  end
end
