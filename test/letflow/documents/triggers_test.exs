defmodule Letflow.Documents.TriggersTest do
  @moduledoc """
  REQ-500 / GH #2588, PR A: the database triggers that make the document tables immutable
  (decision 0056 D4). Design: state/tasks/T-0077/design.md section 10, test IDs A-1..A-14.

  Every test runs raw SQL against a freshly provisioned tenant schema, bypassing any
  context (design D-15). A test that attempts a change asserts the database refused it,
  and where the refusal comes from our own trigger the message is checked too, so an FK
  error cannot pass as a trigger refusal.

  Not yet run: a mutation check (drop one trigger, expect its test to fail). The design asks
  for it; this PR run did not perform it, and the summary says so.
  """

  use Letflow.DataCase, async: false

  import Letflow.DocumentSqlFixture

  @document_tables ~w(document_types documents document_versions document_sequences document_external_registrations)

  @expected_triggers ~w(
    document_types_guard_update document_types_guard_delete document_types_guard_truncate
    documents_guard_update documents_guard_delete documents_guard_truncate
    document_versions_guard_update document_versions_guard_delete document_versions_guard_truncate
    document_sequences_guard_update document_sequences_guard_delete document_sequences_guard_truncate
    document_external_registrations_guard_update document_external_registrations_guard_delete
    document_external_registrations_guard_truncate
  )

  setup do
    %{schema_name: schema, tenant_id: tenant_id} = provisioned_tenant!("req500-trig")
    %{schema: schema, tenant_id: tenant_id}
  end

  # A type, a document and one draft version, the common starting point.
  defp draft_document(%{schema: s, tenant_id: t}) do
    type_key = insert_type!(s, t)
    document_id = insert_document!(s, t, type_key)
    version_id = insert_version!(s, t, document_id, 1)
    %{type_key: type_key, document_id: document_id, version_id: version_id}
  end

  # The same, with the draft issued and the document numbered (the state PR B produces).
  defp issued_document(ctx) do
    %{document_id: document_id, version_id: version_id} = draft = draft_document(ctx)
    issue!(ctx.schema, version_id)
    set_number!(ctx.schema, document_id, 1)
    draft
  end

  describe "A-1: every document trigger exists and is ENABLE ALWAYS" do
    test "pg_trigger lists the expected triggers on the document tables, all with tgenabled = 'A'",
         ctx do
      %{rows: rows} =
        exec!(
          """
          SELECT c.relname, t.tgname, t.tgenabled
            FROM pg_trigger t
            JOIN pg_class c ON c.oid = t.tgrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = $1 AND NOT t.tgisinternal AND c.relname = ANY($2)
          """,
          [ctx.schema, @document_tables]
        )

      names = rows |> Enum.map(fn [_table, name, _enabled] -> name end) |> Enum.sort()
      assert names == Enum.sort(@expected_triggers)

      for [_table, name, enabled] <- rows do
        assert enabled == "A",
               "trigger #{name} is tgenabled=#{enabled}, expected 'A' (ENABLE ALWAYS)"
      end
    end

    test "an issued version's content UPDATE is refused under session_replication_role = replica (A-2)",
         ctx do
      %{version_id: version_id} = issued_document(ctx)

      %{rows: [[can_set]]} =
        exec!("SELECT has_parameter_privilege('session_replication_role', 'SET')")

      # Branch taken is reported, never skipped silently (design F3). This CI database role
      # is a superuser, so the replica branch runs; if a role cannot set it, the test asserts
      # that and the branch is named in the output.
      if can_set do
        result =
          attempt(
            """
            DO $$ BEGIN
              SET LOCAL session_replication_role = replica;
              UPDATE #{table(ctx.schema, "document_versions")} SET content = '{"x":1}'::jsonb
               WHERE id = '#{version_id}';
            END $$
            """,
            []
          )

        # issued -> issued is not a transition (D-8), so the version trigger names that rule.
        assert refusal_message(result) =~ "transition is not allowed"
      else
        IO.puts("A-2: role cannot SET session_replication_role; replica branch not exercised")
        assert can_set == false
      end
    end
  end

  describe "A-3: an issued version's content is frozen" do
    test "UPDATE of content, content_hash, issued_at, issued_by and version_no is refused on an issued row",
         ctx do
      %{version_id: version_id} = issued_document(ctx)
      t = table(ctx.schema, "document_versions")

      for set <- [
            ~s(content = '{"amount":"99.00"}'::jsonb),
            "content_hash = '#{String.duplicate("b", 64)}'",
            "issued_at = now() + interval '1 day'",
            "issued_by = '#{Ecto.UUID.generate()}'::uuid",
            "version_no = 99"
          ] do
        assert {:refused, _} = attempt("UPDATE #{t} SET #{set} WHERE id = '#{version_id}'"),
               "expected refusal for: #{set}"
      end
    end

    test "the same content change is allowed on a draft (drafts are editable)", ctx do
      %{version_id: version_id} = draft_document(ctx)

      assert :accepted =
               attempt(
                 ~s(UPDATE #{table(ctx.schema, "document_versions")} SET content = '{"amount":"5.00"}'::jsonb WHERE id = '#{version_id}')
               )
    end
  end

  describe "A-4: number and period are write-once after the first issue" do
    test "once set, number and period cannot be changed or cleared", ctx do
      %{document_id: document_id} = issued_document(ctx)
      t = table(ctx.schema, "documents")

      assert {:refused, _} = attempt("UPDATE #{t} SET number = 2 WHERE id = '#{document_id}'")

      assert {:refused, _} =
               attempt("UPDATE #{t} SET number = NULL, period = NULL WHERE id = '#{document_id}'")

      assert {:refused, _} =
               attempt("UPDATE #{t} SET period = '2027' WHERE id = '#{document_id}'")
    end

    test "number and period can be set only together with an issue (none on a draft-only document)",
         ctx do
      %{document_id: document_id} = draft_document(ctx)

      assert {:refused, error} =
               attempt(
                 "UPDATE #{table(ctx.schema, "documents")} SET number = 1, period = '2026' WHERE id = '#{document_id}'"
               )

      assert refusal_message({:refused, error}) =~ "only by an issue"
    end
  end

  describe "A-5: identity fields are frozen" do
    test "type_key, issuing_org_unit_id, document_id, legal_entity_id cannot change once set",
         ctx do
      %{document_id: document_id, type_key: type_key} = issued_document(ctx)
      insert_type!(ctx.schema, ctx.tenant_id, "other_type")
      documents = table(ctx.schema, "documents")
      versions = table(ctx.schema, "document_versions")
      other_document = insert_document!(ctx.schema, ctx.tenant_id, "other_type")

      assert type_key != "other_type"

      assert {:refused, _} =
               attempt(
                 "UPDATE #{documents} SET type_key = 'other_type' WHERE id = '#{document_id}'"
               )

      assert {:refused, _} =
               attempt(
                 "UPDATE #{documents} SET issuing_org_unit_id = '#{Ecto.UUID.generate()}'::uuid WHERE id = '#{document_id}'"
               )

      assert {:refused, _} =
               attempt(
                 "UPDATE #{documents} SET id = '#{Ecto.UUID.generate()}'::uuid WHERE id = '#{document_id}'"
               )

      # legal_entity_id is written once, NULL to value, because an issued version exists;
      # a second write (value to another value) is refused.
      assert :accepted =
               attempt(
                 "UPDATE #{documents} SET legal_entity_id = '#{Ecto.UUID.generate()}'::uuid WHERE id = '#{document_id}'"
               )

      assert {:refused, _} =
               attempt(
                 "UPDATE #{documents} SET legal_entity_id = '#{Ecto.UUID.generate()}'::uuid WHERE id = '#{document_id}'"
               )

      assert {:refused, _} =
               attempt(
                 "UPDATE #{versions} SET document_id = '#{other_document}'::uuid WHERE document_id = '#{document_id}'"
               )
    end
  end

  describe "A-6: source_ref" do
    test "changes before the first issue succeed; changes after it are refused", ctx do
      %{document_id: document_id, version_id: version_id} = draft_document(ctx)
      documents = table(ctx.schema, "documents")

      assert :accepted =
               attempt(
                 ~s(UPDATE #{documents} SET source_ref = '{"ref":"a"}'::jsonb WHERE id = '#{document_id}')
               )

      issue!(ctx.schema, version_id)

      assert {:refused, _} =
               attempt(
                 ~s(UPDATE #{documents} SET source_ref = '{"ref":"b"}'::jsonb WHERE id = '#{document_id}')
               )
    end
  end

  describe "A-7: DELETE of any row of any document table is refused, drafts included" do
    test "each table refuses DELETE, including a draft version", ctx do
      %{document_id: document_id, version_id: version_id, type_key: type_key} =
        draft_document(ctx)

      s = ctx.schema

      external = Ecto.UUID.generate()

      # An issued version is needed for the external registration (it names a version).
      issued_id = insert_version!(s, ctx.tenant_id, document_id, 2, "issued")

      exec!(
        """
        INSERT INTO #{table(s, "document_external_registrations")}
          (id, tenant_id, document_id, version_id, system, external_ref, registered_at)
        VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid, 'erp', 'ref-1', now())
        """,
        [external, ctx.tenant_id, document_id, issued_id]
      )

      exec!(
        "INSERT INTO #{table(s, "document_sequences")} (tenant_id, type_key, legal_entity_key, period, counter) VALUES ($1::uuid, $2, 'none', '2026', 3)",
        [ctx.tenant_id, type_key]
      )

      draft_refusal =
        attempt("DELETE FROM #{table(s, "document_versions")} WHERE id = '#{version_id}'")

      assert refusal_message(draft_refusal) =~ "immutable"

      assert refusal_message(
               attempt(
                 "DELETE FROM #{table(s, "document_external_registrations")} WHERE id = '#{external}'"
               )
             ) =~
               "immutable"

      assert refusal_message(
               attempt(
                 "DELETE FROM #{table(s, "document_sequences")} WHERE type_key = '#{type_key}'"
               )
             ) =~
               "immutable"

      assert refusal_message(
               attempt("DELETE FROM #{table(s, "document_types")} WHERE key = '#{type_key}'")
             ) =~
               "immutable"
    end
  end

  describe "A-8: TRUNCATE is refused by a statement trigger" do
    test "each document table refuses TRUNCATE, and the refusal names our rule where no FK intervenes",
         ctx do
      draft_document(ctx)
      s = ctx.schema

      # Tables nothing references: the refusal can only come from our trigger.
      for name <- ~w(document_external_registrations document_sequences) do
        assert refusal_message(attempt("TRUNCATE #{table(s, name)}")) =~ "immutable",
               "TRUNCATE #{name} should be refused by the statement trigger"
      end

      # Tables referenced by foreign keys (document_types, documents, document_versions):
      # PostgreSQL may refuse on the FK before the trigger runs, so any refusal is enough here.
      for name <- ~w(document_types documents document_versions) do
        assert {:refused, _} = attempt("TRUNCATE #{table(s, name)}")
      end
    end
  end

  describe "A-9: a sequence counter cannot be lowered" do
    test "counter decreases are refused, increases and no-op updates are accepted", ctx do
      s = ctx.schema
      type_key = insert_type!(s, ctx.tenant_id)
      seq = table(s, "document_sequences")

      exec!(
        "INSERT INTO #{seq} (tenant_id, type_key, legal_entity_key, period, counter) VALUES ($1::uuid, $2, 'none', '2026', 5)",
        [ctx.tenant_id, type_key]
      )

      where = "WHERE type_key = '#{type_key}' AND legal_entity_key = 'none' AND period = '2026'"

      assert {:refused, _} = attempt("UPDATE #{seq} SET counter = 4 #{where}")
      assert :accepted = attempt("UPDATE #{seq} SET counter = 6 #{where}")
      assert :accepted = attempt("UPDATE #{seq} SET counter = 6 #{where}")
    end
  end

  describe "A-10: allowed transitions only, with their column sets" do
    test "draft->issued, draft->discarded, issued->superseded and issued->cancelled succeed",
         ctx do
      s = ctx.schema
      %{document_id: document_id, version_id: v1} = draft_document(ctx)

      assert :accepted =
               attempt(
                 "UPDATE #{table(s, "document_versions")} SET status = 'issued', issued_at = now(), issued_by = '#{Ecto.UUID.generate()}'::uuid, content_hash = '#{String.duplicate("c", 64)}' WHERE id = '#{v1}'"
               )

      v2 = insert_version!(s, ctx.tenant_id, document_id, 2)

      assert :accepted =
               attempt(
                 "UPDATE #{table(s, "document_versions")} SET status = 'superseded', superseded_by_version = '#{v2}'::uuid WHERE id = '#{v1}'"
               )

      assert :accepted =
               attempt(
                 "UPDATE #{table(s, "document_versions")} SET status = 'discarded', discarded_at = now(), discarded_by = '#{Ecto.UUID.generate()}'::uuid WHERE id = '#{v2}'"
               )

      v3 = insert_version!(s, ctx.tenant_id, document_id, 3, "issued")

      assert :accepted =
               attempt(
                 "UPDATE #{table(s, "document_versions")} SET status = 'cancelled', cancelled_at = now(), cancelled_by = '#{Ecto.UUID.generate()}'::uuid, cancel_reason = 'entered in error' WHERE id = '#{v3}'"
               )
    end

    test "forbidden pairs and column sets are refused", ctx do
      s = ctx.schema
      %{document_id: document_id, version_id: draft} = draft_document(ctx)
      v = table(s, "document_versions")

      # draft -> issued that also changes content
      assert {:refused, _} =
               attempt(
                 "UPDATE #{v} SET status = 'issued', issued_at = now(), issued_by = '#{Ecto.UUID.generate()}'::uuid, content_hash = '#{String.duplicate("d", 64)}', content = '{}'::jsonb WHERE id = '#{draft}'"
               )

      # draft -> superseded is not a transition
      assert {:refused, _} =
               attempt(
                 "UPDATE #{v} SET status = 'superseded', superseded_by_version = '#{draft}'::uuid WHERE id = '#{draft}'"
               )

      issued = insert_version!(s, ctx.tenant_id, document_id, 2, "issued")

      # issued -> cancelled with a blank reason is refused by the row CHECK, and a
      # cancellation that also changes content is refused by the trigger
      assert {:refused, _} =
               attempt(
                 "UPDATE #{v} SET status = 'cancelled', cancelled_at = now(), cancelled_by = '#{Ecto.UUID.generate()}'::uuid, cancel_reason = '   ' WHERE id = '#{issued}'"
               )

      assert {:refused, _} =
               attempt(
                 "UPDATE #{v} SET status = 'cancelled', cancelled_at = now(), cancelled_by = '#{Ecto.UUID.generate()}'::uuid, cancel_reason = 'x', content = '{}'::jsonb WHERE id = '#{issued}'"
               )

      # issued -> superseded with no superseding version is refused by the row CHECK
      assert {:refused, _} =
               attempt("UPDATE #{v} SET status = 'superseded' WHERE id = '#{issued}'")
    end
  end

  describe "A-11: a discarded row is frozen" do
    test "no change at all is accepted from discarded, and it cannot be deleted", ctx do
      s = ctx.schema
      %{version_id: version_id} = draft_document(ctx)
      v = table(s, "document_versions")

      assert :accepted =
               attempt(
                 "UPDATE #{v} SET status = 'discarded', discarded_at = now(), discarded_by = '#{Ecto.UUID.generate()}'::uuid WHERE id = '#{version_id}'"
               )

      assert {:refused, _} =
               attempt(
                 "UPDATE #{v} SET status = 'draft', discarded_at = NULL, discarded_by = NULL WHERE id = '#{version_id}'"
               )

      assert {:refused, _} =
               attempt("UPDATE #{v} SET status = 'issued' WHERE id = '#{version_id}'")

      assert {:refused, _} =
               attempt("UPDATE #{v} SET content = '{}'::jsonb WHERE id = '#{version_id}'")

      assert {:refused, _} = attempt("DELETE FROM #{v} WHERE id = '#{version_id}'")
    end
  end

  describe "A-12: document types are frozen once a document of the type exists" do
    test "before any document, a type can be updated; after one, UPDATE, DELETE and TRUNCATE are refused",
         ctx do
      s = ctx.schema
      key = insert_type!(s, ctx.tenant_id)
      types = table(s, "document_types")

      assert :accepted = attempt("UPDATE #{types} SET number_prefix = 'PX' WHERE key = '#{key}'")

      insert_document!(s, ctx.tenant_id, key)

      assert refusal_message(
               attempt("UPDATE #{types} SET number_prefix = 'PY' WHERE key = '#{key}'")
             ) =~
               "frozen"

      assert refusal_message(attempt("DELETE FROM #{types} WHERE key = '#{key}'")) =~ "immutable"
      assert {:refused, _} = attempt("TRUNCATE #{types}")
    end
  end

  describe "A-13: current_version names an issued version of the same document" do
    test "a draft, a superseded, a nonexistent and another document's version are each refused",
         ctx do
      s = ctx.schema
      type_key = insert_type!(s, ctx.tenant_id)
      documents = table(s, "documents")

      # draft target
      doc_draft = insert_document!(s, ctx.tenant_id, type_key)
      v_draft = insert_version!(s, ctx.tenant_id, doc_draft, 1)

      assert {:refused, _} =
               attempt(
                 "UPDATE #{documents} SET current_version = '#{v_draft}'::uuid WHERE id = '#{doc_draft}'"
               )

      # superseded target
      doc_sup = insert_document!(s, ctx.tenant_id, type_key)
      v1 = insert_version!(s, ctx.tenant_id, doc_sup, 1, "issued")
      v2 = insert_version!(s, ctx.tenant_id, doc_sup, 2)

      exec!(
        "UPDATE #{table(s, "document_versions")} SET status = 'superseded', superseded_by_version = $2::uuid WHERE id = $1::uuid",
        [v1, v2]
      )

      assert {:refused, _} =
               attempt(
                 "UPDATE #{documents} SET current_version = '#{v1}'::uuid WHERE id = '#{doc_sup}'"
               )

      # nonexistent target
      assert {:refused, _} =
               attempt(
                 "UPDATE #{documents} SET current_version = '#{Ecto.UUID.generate()}'::uuid WHERE id = '#{doc_sup}'"
               )

      # another document's issued version
      doc_other = insert_document!(s, ctx.tenant_id, type_key)
      v_other = insert_version!(s, ctx.tenant_id, doc_other, 1, "issued")

      assert {:refused, _} =
               attempt(
                 "UPDATE #{documents} SET current_version = '#{v_other}'::uuid WHERE id = '#{doc_sup}'"
               )

      # the positive case: this document's own issued version
      v3 = insert_version!(s, ctx.tenant_id, doc_sup, 3, "issued")

      assert :accepted =
               attempt(
                 "UPDATE #{documents} SET current_version = '#{v3}'::uuid WHERE id = '#{doc_sup}'"
               )
    end
  end

  describe "A-14: a later-cancelled current version keeps the pointer" do
    test "cancelling the current version leaves documents.current_version in place", ctx do
      %{document_id: document_id, version_id: version_id} = issued_document(ctx)
      set_current!(ctx.schema, document_id, version_id)

      assert :accepted =
               attempt(
                 "UPDATE #{table(ctx.schema, "document_versions")} SET status = 'cancelled', cancelled_at = now(), cancelled_by = '#{Ecto.UUID.generate()}'::uuid, cancel_reason = 'entered in error' WHERE id = '#{version_id}'"
               )

      assert [_number, _period, _entity, current] = document_row(ctx.schema, document_id)
      assert current == version_id
    end
  end
end
