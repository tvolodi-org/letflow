defmodule Letflow.Repository.EntityAttachmentsTest do
  @moduledoc """
  Tests for REQ-316's `Letflow.Repository.EntityAttachments` context module
  and the `entity_record_attachments` migration/schema it sits on top of.
  See `lib/letflow/design/req313-entity-record-attachments.md` for the full
  design these tests exercise -- especially §1 (the deferred composite FK)
  and §2 (the context module's five functions).

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Record.Latest
  alias Letflow.Repository
  alias Letflow.Repository.Artifact
  alias Letflow.Repository.Attachments
  alias Letflow.Repository.EntityAttachment
  alias Letflow.Repository.EntityAttachments

  defp provisioned_tenant(slug_prefix) do
    Letflow.TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "REQ-316 EntityAttachments Test Tenant"
    )
  end

  # Inserts a bare entity_record_latest row directly -- bypasses
  # Letflow.Entities.Records/entity-definition resolution entirely, since
  # this FK only depends on the (entity_type, record_id) pair existing in
  # entity_record_latest, not on any definition relationship.
  defp insert_latest_record!(schema, entity_type, record_id) do
    %Latest{}
    |> Latest.insert_changeset(%{
      entity_type: entity_type,
      record_id: record_id,
      field_values: %{},
      entity_def_version: "v1",
      last_event_global_seq: 1
    })
    |> Repo.insert!(prefix: schema)
  end

  defp upload_attrs(overrides) do
    Map.merge(
      %{
        entity_type: "widget",
        record_id: Ecto.UUID.generate(),
        raw_bytes: "hello entity attachment bytes",
        file_name: "note.txt",
        content_type: "text/plain",
        uploaded_by: Ecto.UUID.generate(),
        description: nil
      },
      Map.new(overrides)
    )
  end

  # Convenience: provisions a tenant, inserts a real parent
  # entity_record_latest row, and returns {schema, entity_type, record_id}.
  defp provisioned_tenant_with_record(slug_prefix) do
    %{schema_name: schema} = provisioned_tenant(slug_prefix)
    entity_type = "widget"
    record_id = Ecto.UUID.generate()
    insert_latest_record!(schema, entity_type, record_id)
    {schema, entity_type, record_id}
  end

  # ---------------------------------------------------------------------------------
  # AC: the migration runs cleanly and creates entity_record_attachments with
  # every column, both indexes, and the composite deferred FK.
  # ---------------------------------------------------------------------------------

  describe "migration: entity_record_attachments -- schema-per-tenant, columns/indexes/FK" do
    test "the table exists in the tenant's own schema with every column, both NOT NULL where specified, and is absent from public" do
      %{schema_name: schema} = provisioned_tenant("ac-migration")

      %{rows: tenant_columns} =
        Repo.query!(
          "SELECT column_name, is_nullable FROM information_schema.columns " <>
            "WHERE table_schema = $1 AND table_name = 'entity_record_attachments'",
          [schema]
        )

      columns = Map.new(tenant_columns, fn [name, nullable] -> {name, nullable} end)

      assert columns["id"] == "NO"
      assert columns["tenant_id"] == "NO"
      assert columns["entity_type"] == "NO"
      assert columns["record_id"] == "NO"
      assert columns["content_hash"] == "NO"
      assert columns["file_name"] == "NO"
      assert columns["content_type"] == "NO"
      assert columns["byte_size"] == "NO"
      assert columns["uploaded_by"] == "NO"
      assert columns["description"] == "YES"
      assert columns["scan_status"] == "NO"
      assert columns["created_at"] == "NO"

      %{rows: public_rows} =
        Repo.query!(
          "SELECT 1 FROM information_schema.tables " <>
            "WHERE table_schema = 'public' AND table_name = 'entity_record_attachments'"
        )

      assert public_rows == []
    end

    test "both indexes exist" do
      %{schema_name: schema} = provisioned_tenant("ac-indexes")

      %{rows: index_rows} =
        Repo.query!(
          "SELECT indexname FROM pg_indexes WHERE schemaname = $1 AND tablename = 'entity_record_attachments'",
          [schema]
        )

      index_names = List.flatten(index_rows)

      assert "entity_record_attachments_type_record_created_at_idx" in index_names
      assert Enum.any?(index_names, &String.contains?(&1, "content_hash"))
    end

    test "the composite FK constraint exists, is a foreign key, and is DEFERRABLE INITIALLY DEFERRED" do
      %{schema_name: schema} = provisioned_tenant("ac-fk-shape")

      %{rows: [[condeferrable, condeferred, contype]]} =
        Repo.query!(
          """
          SELECT c.condeferrable, c.condeferred, c.contype
          FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE n.nspname = $1
            AND t.relname = 'entity_record_attachments'
            AND c.conname = 'entity_record_attachments_record_fkey'
          """,
          [schema]
        )

      assert condeferrable == true
      assert condeferred == true
      assert contype == "f"

      # sanity: this constraint genuinely lives on this tenant's own table,
      # by re-deriving the same result scoped through the schema explicitly.
      %{rows: rows} =
        Repo.query!(
          """
          SELECT c.conname
          FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE n.nspname = $1 AND t.relname = 'entity_record_attachments' AND c.contype = 'f'
          """,
          [schema]
        )

      assert ["entity_record_attachments_record_fkey"] in rows
    end
  end

  # ---------------------------------------------------------------------------------
  # AC: the deferred FK proof -- delete-then-reinsert inside one transaction
  # does not raise, while a genuinely nonexistent pair on upload/2 does
  # produce {:error, %Ecto.Changeset{}}.
  # ---------------------------------------------------------------------------------

  describe "deferred composite FK (design §1)" do
    test "upload/2 against a genuinely nonexistent (entity_type, record_id) pair returns {:error, %Ecto.Changeset{}} via foreign_key_constraint, not a raised error" do
      %{schema_name: schema} = provisioned_tenant("ac-fk-reject")

      assert {:error, %Ecto.Changeset{} = changeset} =
               EntityAttachments.upload(
                 upload_attrs(entity_type: "does-not-exist", record_id: Ecto.UUID.generate()),
                 prefix: schema
               )

      assert {"does not exist", constraint_opts} = changeset.errors[:record_id]
      assert Keyword.get(constraint_opts, :constraint) == :foreign

      assert Repo.aggregate(EntityAttachment, :count, prefix: schema) == 0
    end

    test "within one Repo.transaction/1, deleting then reinserting entity_record_latest rows for an entity_type with an existing attachment does not raise mid-transaction (mirrors the promotion-backfill trace)" do
      {schema, entity_type, record_id} = provisioned_tenant_with_record("ac-fk-defer")

      assert {:ok, _attachment} =
               EntityAttachments.upload(
                 upload_attrs(entity_type: entity_type, record_id: record_id),
                 prefix: schema
               )

      # Mirrors write_snapshots/3 (req297 §9): delete every entity_record_latest
      # row for the entity type, then reinsert it, inside ONE transaction. A
      # plain (non-deferred) FK would raise on the delete_all the instant any
      # entity_record_attachments row exists for this entity type.
      result =
        Repo.transaction(fn ->
          {1, _} =
            Repo.delete_all(
              from(r in Latest, where: r.entity_type == ^entity_type),
              prefix: schema
            )

          insert_latest_record!(schema, entity_type, record_id)
          :ok
        end)

      assert result == {:ok, :ok}

      # The attachment row itself, and the restored parent row, both survive.
      assert Repo.aggregate(EntityAttachment, :count, prefix: schema) == 1
      assert {:ok, %Latest{}} = Latest.get(record_id, entity_type, schema)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC: upload/2's documented outcomes.
  # ---------------------------------------------------------------------------------

  describe "upload/2" do
    test "success: hashes bytes independently, upserts repository_artifacts, and creates one entity_record_attachments row" do
      {schema, entity_type, record_id} = provisioned_tenant_with_record("ac-upload-ok")

      assert {:ok, %EntityAttachment{} = attachment} =
               EntityAttachments.upload(
                 upload_attrs(entity_type: entity_type, record_id: record_id),
                 prefix: schema
               )

      assert attachment.entity_type == entity_type
      assert attachment.record_id == record_id
      assert attachment.file_name == "note.txt"
      assert attachment.content_type == "text/plain"
      assert attachment.byte_size == byte_size("hello entity attachment bytes")
      assert attachment.scan_status == :clean

      expected_hash = :crypto.hash(:sha256, "hello entity attachment bytes")
      assert attachment.content_hash == expected_hash

      stored_artifact = Repo.get!(Artifact, expected_hash, prefix: schema)
      assert stored_artifact.content == "hello entity attachment bytes"
    end

    test ":file_too_large -- an oversized upload is rejected before any persistence" do
      {schema, entity_type, record_id} = provisioned_tenant_with_record("ac-upload-toolarge")

      oversized = :binary.copy("a", 26_214_401)

      assert EntityAttachments.upload(
               upload_attrs(entity_type: entity_type, record_id: record_id, raw_bytes: oversized),
               prefix: schema
             ) == {:error, :file_too_large}

      assert Repo.aggregate(EntityAttachment, :count, prefix: schema) == 0
      assert Repo.aggregate(Artifact, :count, prefix: schema) == 0
    end

    test ":infected -- an EICAR-signature upload is rejected and nothing is persisted" do
      {schema, entity_type, record_id} = provisioned_tenant_with_record("ac-upload-infected")

      eicar = "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"

      assert {:error, :infected, verdict} =
               EntityAttachments.upload(
                 upload_attrs(entity_type: entity_type, record_id: record_id, raw_bytes: eicar),
                 prefix: schema
               )

      assert verdict == "eicar-test-signature"
      assert Repo.aggregate(EntityAttachment, :count, prefix: schema) == 0
      assert Repo.aggregate(Artifact, :count, prefix: schema) == 0
    end

    defmodule RaisingScanner do
      @moduledoc false
      @behaviour Letflow.Repository.AttachmentScanner

      @impl true
      def scan(_raw_bytes, _content_type), do: raise("simulated scanner crash")
    end

    defp put_attachment_scanner!(module) do
      previous = Application.get_env(:letflow, :attachment_scanner)
      Application.put_env(:letflow, :attachment_scanner, module)

      on_exit(fn ->
        if previous do
          Application.put_env(:letflow, :attachment_scanner, previous)
        else
          Application.delete_env(:letflow, :attachment_scanner)
        end
      end)

      :ok
    end

    test ":scan_unavailable -- an adapter that raises fails closed, never a false :clean" do
      {schema, entity_type, record_id} = provisioned_tenant_with_record("ac-upload-scanraise")
      put_attachment_scanner!(RaisingScanner)

      assert EntityAttachments.upload(
               upload_attrs(entity_type: entity_type, record_id: record_id),
               prefix: schema
             ) == {:error, :scan_unavailable}

      assert Repo.aggregate(EntityAttachment, :count, prefix: schema) == 0
      assert Repo.aggregate(Artifact, :count, prefix: schema) == 0
    end

    test "changeset FK violation -- covered by the dedicated deferred-FK describe block above (nonexistent pair test)" do
      # Explicit no-op marker test: the actual assertion lives in
      # "deferred composite FK (design §1)" above, kept there rather than
      # duplicated here since it is the same scenario.
      assert true
    end

    test "tenant_id is derived from opts[:prefix], never accepted from caller-supplied attrs" do
      {schema, entity_type, record_id} = provisioned_tenant_with_record("ac-upload-tenantid")

      attrs =
        upload_attrs(entity_type: entity_type, record_id: record_id)
        |> Map.put(:tenant_id, Ecto.UUID.generate())

      assert {:ok, attachment} = EntityAttachments.upload(attrs, prefix: schema)

      {:ok, expected_tenant_id} = Letflow.TenantProvisioning.tenant_id_for_schema_name(schema)

      assert attachment.tenant_id == expected_tenant_id
      refute attachment.tenant_id == attrs.tenant_id
    end
  end

  # ---------------------------------------------------------------------------------
  # AC: list/2's cursor pagination and the empty-page-for-nonexistent-pair case.
  # ---------------------------------------------------------------------------------

  describe "list/2" do
    test "tenant-scoped and filtered by (entity_type, record_id)" do
      {schema_a, entity_type, record_id} = provisioned_tenant_with_record("ac-list-a")
      %{schema_name: schema_b} = provisioned_tenant("ac-list-b")

      assert {:ok, _} =
               EntityAttachments.upload(
                 upload_attrs(entity_type: entity_type, record_id: record_id),
                 prefix: schema_a
               )

      assert {:ok, %{items: items_cross_tenant}} =
               EntityAttachments.list(
                 %{entity_type: entity_type, record_id: record_id, cursor: nil, page_size: 10},
                 prefix: schema_b
               )

      assert items_cross_tenant == []

      assert {:ok, %{items: items_same_tenant}} =
               EntityAttachments.list(
                 %{entity_type: entity_type, record_id: record_id, cursor: nil, page_size: 10},
                 prefix: schema_a
               )

      assert length(items_same_tenant) == 1
    end

    test "rows older than 24 hours remain pageable" do
      {schema, entity_type, record_id} =
        provisioned_tenant_with_record("cursor-issue-time-entity")

      entries =
        for n <- 1..3 do
          assert {:ok, entry} =
                   EntityAttachments.upload(
                     upload_attrs(
                       entity_type: entity_type,
                       record_id: record_id,
                       raw_bytes: "old-#{n}"
                     ),
                     prefix: schema
                   )

          entry
        end

      old =
        DateTime.utc_now()
        |> DateTime.add(-2 * 86_400, :second)
        |> DateTime.truncate(:microsecond)

      ids = Enum.map(entries, & &1.id)

      Repo.update_all(from(a in EntityAttachment, where: a.id in ^ids), [set: [created_at: old]],
        prefix: schema
      )

      params = %{entity_type: entity_type, record_id: record_id, page_size: 1}

      assert {:ok, %{items: [_], next_cursor: cursor1}} =
               EntityAttachments.list(Map.put(params, :cursor, nil), prefix: schema)

      assert {:ok, %{items: [_], next_cursor: cursor2}} =
               EntityAttachments.list(Map.put(params, :cursor, cursor1), prefix: schema)

      assert {:ok, %{items: [_], next_cursor: nil}} =
               EntityAttachments.list(Map.put(params, :cursor, cursor2), prefix: schema)
    end

    test "cursor pagination walks at least two pages with no repeated ids, next_cursor is nil on the final page" do
      {schema, entity_type, record_id} = provisioned_tenant_with_record("ac-list-cursor")

      for n <- 1..5 do
        assert {:ok, _} =
                 EntityAttachments.upload(
                   upload_attrs(
                     entity_type: entity_type,
                     record_id: record_id,
                     raw_bytes: "content-#{n}"
                   ),
                   prefix: schema
                 )
      end

      assert {:ok, page_1} =
               EntityAttachments.list(
                 %{entity_type: entity_type, record_id: record_id, cursor: nil, page_size: 2},
                 prefix: schema
               )

      assert length(page_1.items) == 2
      assert is_binary(page_1.next_cursor)

      assert {:ok, page_2} =
               EntityAttachments.list(
                 %{
                   entity_type: entity_type,
                   record_id: record_id,
                   cursor: page_1.next_cursor,
                   page_size: 2
                 },
                 prefix: schema
               )

      assert length(page_2.items) == 2

      assert {:ok, page_3} =
               EntityAttachments.list(
                 %{
                   entity_type: entity_type,
                   record_id: record_id,
                   cursor: page_2.next_cursor,
                   page_size: 2
                 },
                 prefix: schema
               )

      assert length(page_3.items) == 1
      assert page_3.next_cursor == nil

      ids_1 = Enum.map(page_1.items, & &1.id)
      ids_2 = Enum.map(page_2.items, & &1.id)
      ids_3 = Enum.map(page_3.items, & &1.id)

      all_ids = ids_1 ++ ids_2 ++ ids_3
      assert length(Enum.uniq(all_ids)) == 5
    end

    test "a nonexistent (entity_type, record_id) pair returns an EMPTY page, not an error" do
      %{schema_name: schema} = provisioned_tenant("ac-list-nonexistent")

      assert {:ok, %{items: [], next_cursor: nil}} =
               EntityAttachments.list(
                 %{
                   entity_type: "no-such-type",
                   record_id: Ecto.UUID.generate(),
                   cursor: nil,
                   page_size: 10
                 },
                 prefix: schema
               )
    end
  end

  # ---------------------------------------------------------------------------------
  # AC: get/2, get_content/2, delete/2 -- invalid-id/not-found cases.
  # ---------------------------------------------------------------------------------

  describe "get/2" do
    test "invalid id returns :invalid_id without a DB round-trip" do
      %{schema_name: schema} = provisioned_tenant("ac-get-invalid")
      assert EntityAttachments.get("not-a-uuid", prefix: schema) == {:error, :invalid_id}
    end

    test "well-formed but absent id returns :not_found" do
      %{schema_name: schema} = provisioned_tenant("ac-get-notfound")
      assert EntityAttachments.get(Ecto.UUID.generate(), prefix: schema) == {:error, :not_found}
    end
  end

  describe "get_content/2" do
    test "invalid id returns :invalid_id without a DB round-trip" do
      %{schema_name: schema} = provisioned_tenant("ac-getcontent-invalid")
      assert EntityAttachments.get_content("not-a-uuid", prefix: schema) == {:error, :invalid_id}
    end

    test "well-formed but absent id returns :not_found" do
      %{schema_name: schema} = provisioned_tenant("ac-getcontent-notfound")

      assert EntityAttachments.get_content(Ecto.UUID.generate(), prefix: schema) ==
               {:error, :not_found}
    end

    test "a clean attachment's content is fetchable" do
      {schema, entity_type, record_id} = provisioned_tenant_with_record("ac-getcontent-ok")

      assert {:ok, attachment} =
               EntityAttachments.upload(
                 upload_attrs(entity_type: entity_type, record_id: record_id),
                 prefix: schema
               )

      assert {:ok, ^attachment, artifact} =
               EntityAttachments.get_content(attachment.id, prefix: schema)

      assert artifact.content == "hello entity attachment bytes"
    end
  end

  describe "delete/2" do
    test "invalid id returns :invalid_id without a DB round-trip" do
      %{schema_name: schema} = provisioned_tenant("ac-delete-invalid")
      assert EntityAttachments.delete("not-a-uuid", prefix: schema) == {:error, :invalid_id}
    end

    test "well-formed but absent id returns :not_found" do
      %{schema_name: schema} = provisioned_tenant("ac-delete-notfound")

      assert EntityAttachments.delete(Ecto.UUID.generate(), prefix: schema) ==
               {:error, :not_found}
    end

    test "removes the entity_record_attachments row only -- repository_artifacts row survives" do
      {schema, entity_type, record_id} = provisioned_tenant_with_record("ac-delete-ok")

      assert {:ok, attachment} =
               EntityAttachments.upload(
                 upload_attrs(entity_type: entity_type, record_id: record_id),
                 prefix: schema
               )

      assert {:ok, _deleted} = EntityAttachments.delete(attachment.id, prefix: schema)
      assert EntityAttachments.get(attachment.id, prefix: schema) == {:error, :not_found}
      assert Repo.get!(Artifact, attachment.content_hash, prefix: schema)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC: repository_artifacts dedup is shared between instance and entity-record
  # attachments.
  # ---------------------------------------------------------------------------------

  describe "shared repository_artifacts dedup with Letflow.Repository.Attachments" do
    test "uploading byte-identical content once as an instance attachment and once as an entity-record attachment results in exactly one repository_artifacts row" do
      {schema, entity_type, record_id} = provisioned_tenant_with_record("ac-shared-dedup")

      shared_bytes = "shared bytes across attachment tables"

      assert {:ok, instance_attachment} =
               Attachments.upload(
                 %{
                   instance_id: Ecto.UUID.generate(),
                   raw_bytes: shared_bytes,
                   file_name: "a.txt",
                   content_type: "text/plain",
                   uploaded_by: Ecto.UUID.generate(),
                   description: nil
                 },
                 prefix: schema
               )

      assert {:ok, entity_attachment} =
               EntityAttachments.upload(
                 upload_attrs(
                   entity_type: entity_type,
                   record_id: record_id,
                   raw_bytes: shared_bytes
                 ),
                 prefix: schema
               )

      assert instance_attachment.content_hash == entity_attachment.content_hash
      assert Repo.aggregate(Artifact, :count, prefix: schema) == 1
    end
  end

  # ---------------------------------------------------------------------------------
  # Cross-tenant isolation (mirrors Letflow.Repository.Attachments' own coverage).
  # ---------------------------------------------------------------------------------

  describe "cross-tenant isolation" do
    test "an attachment uploaded in tenant A's schema is not reachable from tenant B's schema" do
      {schema_a, entity_type, record_id} = provisioned_tenant_with_record("ac-iso-a")
      %{schema_name: schema_b} = provisioned_tenant("ac-iso-b")

      assert {:ok, attachment} =
               EntityAttachments.upload(
                 upload_attrs(entity_type: entity_type, record_id: record_id),
                 prefix: schema_a
               )

      assert EntityAttachments.get(attachment.id, prefix: schema_b) == {:error, :not_found}
      assert {:ok, _} = EntityAttachments.get(attachment.id, prefix: schema_a)
    end
  end

  describe "Repository.upsert_content/6 (shared upsert path)" do
    test "is a public function on Letflow.Repository" do
      Code.ensure_loaded?(Repository)
      assert function_exported?(Repository, :upsert_content, 6)
    end
  end
end
