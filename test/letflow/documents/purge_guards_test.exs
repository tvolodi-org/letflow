defmodule Letflow.Documents.PurgeGuardsTest do
  @moduledoc """
  REQ-603 part A / GH #3389: the `purge_requests` table and the guarded delete exception in the
  `document_versions` and `repository_artifacts` triggers (decision 0074 P2, P6). Test IDs
  P-C1..P-C4, P-G1a..P-G4, P-X1 of state/tasks/T-1292/design.md section 5.

  Raw SQL against freshly provisioned tenant schemas; no module code exists in part A. The
  setting `letflow.purge_request_id` is transaction-local, so every DELETE that uses it runs in
  a DO block that sets it first (the same method as `triggers_test.exs` A-2).
  """

  use Letflow.DataCase, async: false

  import Letflow.DocumentSqlFixture

  @hash String.duplicate("a", 64)
  @other_hash String.duplicate("b", 64)

  setup do
    %{schema_name: schema, tenant_id: tenant_id} = provisioned_tenant!("req603-guard")
    type_key = insert_type!(schema, tenant_id)
    document_id = insert_document!(schema, tenant_id, type_key)
    %{schema: schema, tenant_id: tenant_id, type_key: type_key, document_id: document_id}
  end

  # A cancelled version (FK-free, hashed): the shape a purge targets.
  defp cancelled_version(%{schema: s, tenant_id: t, document_id: d}, version_no \\ 1) do
    insert_version_at!(s, t, d, version_no, "cancelled", DateTime.utc_now(),
      cancelled_at: DateTime.utc_now()
    )
  end

  defp request(%{schema: s, tenant_id: t, document_id: d}, version_id, opts \\ []),
    do: insert_purge_request!(s, t, d, version_id, opts)

  defp delete_with_setting(delete_sql, setting) do
    attempt("""
    DO $$ BEGIN
      PERFORM set_config('letflow.purge_request_id', '#{setting}', true);
      #{delete_sql};
    END $$
    """)
  end

  defp delete_version(ctx, version_id),
    do: ~s|DELETE FROM #{table(ctx.schema, "document_versions")} WHERE id = '#{version_id}'|

  defp version_exists?(ctx, version_id) do
    %{rows: [[n]]} =
      exec!(
        ~s|SELECT count(*) FROM #{table(ctx.schema, "document_versions")} WHERE id = $1::uuid|,
        [version_id]
      )

    n == 1
  end

  defp insert_artifact!(schema, tenant_id, hex) do
    exec!(
      """
      INSERT INTO #{table(schema, "repository_artifacts")}
        (content_hash, tenant_id, content_type, byte_size, inserted_at, content)
      VALUES (decode($1, 'hex'), $2::uuid, 'text/plain', 3, now(), '\\x616263'::bytea)
      """,
      [hex, tenant_id]
    )
  end

  defp delete_artifact(schema, hex),
    do:
      ~s|DELETE FROM #{table(schema, "repository_artifacts")} WHERE content_hash = decode('#{hex}', 'hex')|

  defp artifact_exists?(schema, hex) do
    %{rows: [[n]]} =
      exec!(
        ~s|SELECT count(*) FROM #{table(schema, "repository_artifacts")} WHERE content_hash = decode($1, 'hex')|,
        [hex]
      )

    n == 1
  end

  describe "P-C: table checks and guard triggers" do
    test "P-C1 approved_by = requested_by is refused by the two-person check", ctx do
      user = Ecto.UUID.generate()
      id = request(ctx, Ecto.UUID.generate(), approve: false, requested_by: user)

      result =
        attempt(
          ~s|UPDATE #{table(ctx.schema, "purge_requests")} SET approved_by = $2::uuid, approved_at = now() WHERE id = $1::uuid|,
          [id, user]
        )

      assert refusal_message(result) =~ "purge_requests_two_person_chk"
    end

    test "P-C2 an insert that is already approved or consumed is refused", ctx do
      for column_sql <- ["approved_by, approved_at", "consumed_at"] do
        values = if column_sql == "consumed_at", do: "now()", else: "$7::uuid, now()"

        result =
          attempt(
            """
            INSERT INTO #{table(ctx.schema, "purge_requests")}
              (id, tenant_id, document_id, version_id, version_no, content_hash, reason_code,
               requested_by, expires_at, #{column_sql})
            VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid, 1, $5, 'legal_erasure', $6::uuid,
                    now() + interval '1 hour', #{values})
            """,
            [
              Ecto.UUID.generate(),
              ctx.tenant_id,
              ctx.document_id,
              Ecto.UUID.generate(),
              @hash,
              Ecto.UUID.generate()
            ] ++ if(column_sql == "consumed_at", do: [], else: [Ecto.UUID.generate()])
          )

        assert refusal_message(result) =~ "inserted unapproved and unconsumed"
      end
    end

    test "P-C3 only the set-once approval and consumption may change", ctx do
      id = request(ctx, Ecto.UUID.generate(), approve: false)
      t = table(ctx.schema, "purge_requests")

      for set <- [
            "reason_code = 'other_reason'",
            "expires_at = expires_at + interval '1 day'",
            "version_id = gen_random_uuid()",
            "content_hash = '#{@other_hash}'",
            "requested_by = gen_random_uuid()",
            "tenant_id = gen_random_uuid()"
          ] do
        result = attempt(~s(UPDATE #{t} SET #{set} WHERE id = $1::uuid), [id])
        assert refusal_message(result) =~ "immutable", set
      end

      # consumed before approval: the CHECK refuses it
      result = attempt(~s|UPDATE #{t} SET consumed_at = now() WHERE id = $1::uuid|, [id])
      assert refusal_message(result) =~ "purge_requests_consumed_chk"

      # approve once
      approver = Ecto.UUID.generate()

      assert :accepted ==
               attempt(
                 ~s|UPDATE #{t} SET approved_by = $2::uuid, approved_at = now() WHERE id = $1::uuid|,
                 [id, approver]
               )

      # a second approval, and clearing the approval, are refused
      result =
        attempt(~s(UPDATE #{t} SET approved_by = $2::uuid WHERE id = $1::uuid), [
          id,
          Ecto.UUID.generate()
        ])

      assert refusal_message(result) =~ "immutable"

      result =
        attempt(~s(UPDATE #{t} SET approved_by = NULL, approved_at = NULL WHERE id = $1::uuid), [
          id
        ])

      assert refusal_message(result) =~ "immutable"

      # consume once, then never change or clear it
      assert :accepted ==
               attempt(~s|UPDATE #{t} SET consumed_at = now() WHERE id = $1::uuid|, [id])

      result =
        attempt(~s|UPDATE #{t} SET consumed_at = now() + interval '1 day' WHERE id = $1::uuid|, [
          id
        ])

      assert refusal_message(result) =~ "immutable"
      result = attempt(~s(UPDATE #{t} SET consumed_at = NULL WHERE id = $1::uuid), [id])
      assert refusal_message(result) =~ "immutable"
    end

    test "P-C4 DELETE and TRUNCATE of a request are refused, also with a valid setting", ctx do
      version_id = cancelled_version(ctx)
      id = request(ctx, version_id)
      t = table(ctx.schema, "purge_requests")

      assert refusal_message(attempt(~s(DELETE FROM #{t} WHERE id = $1::uuid), [id])) =~
               "never deleted"

      assert refusal_message(attempt("TRUNCATE #{t}")) =~ "never deleted"

      assert refusal_message(delete_with_setting(~s(DELETE FROM #{t} WHERE id = '#{id}'), id)) =~
               "never deleted"
    end
  end

  describe "P-G: the guarded delete exception" do
    test "P-G1a a document_versions DELETE without the setting is refused", ctx do
      version_id = cancelled_version(ctx)

      result = attempt(delete_version(ctx, version_id))
      assert refusal_message(result) =~ "document data is immutable"
      assert version_exists?(ctx, version_id)
    end

    test "P-G1b a repository_artifacts DELETE without the setting is refused", ctx do
      insert_artifact!(ctx.schema, ctx.tenant_id, @hash)

      result = attempt(delete_artifact(ctx.schema, @hash))
      assert refusal_message(result) =~ "repository_artifacts is immutable"
      assert artifact_exists?(ctx.schema, @hash)
    end

    test "P-G2a an approved matching request lets exactly that version be deleted", ctx do
      version_id = cancelled_version(ctx, 1)
      other_id = cancelled_version(ctx, 2)
      id = request(ctx, version_id)

      assert :accepted == delete_with_setting(delete_version(ctx, version_id), id)
      refute version_exists?(ctx, version_id)

      # the same request does not authorize another version
      assert refusal_message(delete_with_setting(delete_version(ctx, other_id), id)) =~
               "document data is immutable"

      assert version_exists?(ctx, other_id)
    end

    test "P-G2b an approved matching request lets the artifact be deleted, UPDATE stays refused",
         ctx do
      insert_artifact!(ctx.schema, ctx.tenant_id, @hash)
      id = request(ctx, Ecto.UUID.generate(), artefact_hash: @hash)

      update_sql =
        ~s|UPDATE #{table(ctx.schema, "repository_artifacts")} SET byte_size = 4 WHERE content_hash = decode('#{@hash}', 'hex')|

      assert refusal_message(delete_with_setting(update_sql, id)) =~
               "repository_artifacts is immutable"

      assert artifact_exists?(ctx.schema, @hash)

      assert :accepted == delete_with_setting(delete_artifact(ctx.schema, @hash), id)
      refute artifact_exists?(ctx.schema, @hash)
    end

    test "P-G3 a request that does not match exactly authorizes nothing", ctx do
      version_id = cancelled_version(ctx)
      other_version = Ecto.UUID.generate()

      refused = fn setting ->
        assert refusal_message(delete_with_setting(delete_version(ctx, version_id), setting)) =~
                 "document data is immutable"

        assert version_exists?(ctx, version_id)
      end

      refused.(Ecto.UUID.generate())
      refused.("not-a-uuid")
      refused.("")
      refused.(String.upcase(request(ctx, version_id)))
      refused.(request(ctx, other_version))
      refused.(request(ctx, version_id, content_hash: @other_hash))
      refused.(request(ctx, version_id, expired: true))
      refused.(request(ctx, version_id, consumed: true))
      refused.(request(ctx, version_id, approve: false))

      # status guard: issued, draft and discarded rows are never deleted, even for a valid request
      %{schema: s, tenant_id: t, document_id: d} = ctx
      issued = insert_version!(s, t, d, 10, "issued")
      draft = insert_version!(s, t, d, 11, "draft")
      discarded = insert_version_at!(s, t, d, 12, "discarded", nil)

      for target <- [issued, draft, discarded] do
        id = request(ctx, target)

        assert refusal_message(delete_with_setting(delete_version(ctx, target), id)) =~
                 "document data is immutable"

        assert version_exists?(ctx, target)
      end

      # an artifact request with another hash, or without any artefact hash, is refused
      insert_artifact!(s, t, @hash)

      for id <- [
            request(ctx, version_id, artefact_hash: @other_hash),
            request(ctx, version_id)
          ] do
        assert refusal_message(delete_with_setting(delete_artifact(s, @hash), id)) =~
                 "repository_artifacts is immutable"
      end

      assert artifact_exists?(s, @hash)
    end

    test "P-G4 the setting does not outlive its transaction scope", ctx do
      version_id = cancelled_version(ctx)
      id = request(ctx, version_id)

      # A rolled-back savepoint ends the SET LOCAL scope, like a finished transaction.
      assert {:error, :undo} =
               Repo.transaction(fn ->
                 exec!("SELECT set_config('letflow.purge_request_id', '#{id}', true)")
                 Repo.rollback(:undo)
               end)

      %{rows: [[value]]} = exec!("SELECT current_setting('letflow.purge_request_id', true)")
      assert value in [nil, ""]

      assert refusal_message(attempt(delete_version(ctx, version_id))) =~
               "document data is immutable"
    end

    test "P-X1 a request of tenant A authorizes nothing in tenant B", ctx do
      %{schema_name: schema_b, tenant_id: tenant_b} = provisioned_tenant!("req603-guard-b")
      type_b = insert_type!(schema_b, tenant_b)
      doc_b = insert_document!(schema_b, tenant_b, type_b)

      version_b =
        insert_version_at!(schema_b, tenant_b, doc_b, 1, "cancelled", DateTime.utc_now(),
          cancelled_at: DateTime.utc_now()
        )

      # tenant A holds a valid request naming tenant B's version and artifact hash
      id = request(ctx, version_b, artefact_hash: @hash)
      insert_artifact!(schema_b, tenant_b, @hash)

      sql_b = ~s|DELETE FROM #{table(schema_b, "document_versions")} WHERE id = '#{version_b}'|
      assert refusal_message(delete_with_setting(sql_b, id)) =~ "document data is immutable"

      assert refusal_message(delete_with_setting(delete_artifact(schema_b, @hash), id)) =~
               "repository_artifacts is immutable"

      assert artifact_exists?(schema_b, @hash)
    end
  end
end
