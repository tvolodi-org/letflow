defmodule Letflow.Documents.DocumentsCancelVerifyTest do
  @moduledoc """
  REQ-543 / GH #3163 part 2b, criteria 3, 4, 5, 5b (read half): `Letflow.Documents.cancel/3` and
  `verify_binding/4` (decision 0056 D3, D4, D9). Design: state/tasks/T-0636/design.md, tests
  C1..C5, V1..V3, I1..I5, T1, T2, R1. T3 (forced audit insert failure at top level) is dropped:
  it needs DDL on the audit table inside the sandbox and cannot be forced without poisoning the
  shared test transaction. The refusal counter tests are in `refusals_counter_test.exs`.
  """

  use Letflow.DataCase, async: false

  import Letflow.DocumentSqlFixture

  alias Letflow.Audit
  alias Letflow.Documents
  alias Letflow.Repo
  alias Letflow.ScopeNodePaths

  @actor "99999999-9999-4999-8999-999999999999"
  @secret "SENTINEL-CONTENT-VALUE"

  setup do
    %{schema_name: schema, tenant_id: tenant_id} = provisioned_tenant!("req543-cv")

    {:ok, _} =
      Documents.register_type(
        schema,
        %{
          key: "purchase_request",
          owner_module: "procurement",
          numbering_scope: :year,
          number_prefix: "PR",
          number_pad: 4,
          legal_entity_required: false,
          declared_fields: %{}
        },
        %{actor_id: @actor}
      )

    unit = Ecto.UUID.generate()
    {:ok, _} = ScopeNodePaths.write({:insert, unit, nil}, schema)
    %{schema: schema, tenant_id: tenant_id, unit: unit}
  end

  defp issued!(ctx) do
    {:ok, %{document: d}} =
      Documents.create_draft(
        ctx.schema,
        %{
          type_key: "purchase_request",
          issuing_org_unit_id: ctx.unit,
          content: %{"amount" => 10, "note" => @secret}
        },
        @actor
      )

    {:ok, %{version: v}} = Documents.issue(ctx.schema, %{document_id: d.id, actor_id: @actor})
    {d.id, v}
  end

  defp cancel(ctx, id, n \\ 1, reason \\ "wrong supplier"),
    do:
      Documents.cancel(
        ctx.schema,
        %{document_id: id, version_no: n, reason: reason},
        @actor
      )

  defp count(schema, tbl),
    do: exec!("SELECT count(*) FROM #{table(schema, tbl)}").rows |> hd() |> hd()

  defp entries(schema, action) do
    exec!(
      "SELECT after_state::text FROM #{table(schema, "audit_entries")} WHERE action = $1 ORDER BY timestamp, id",
      [action]
    ).rows
    |> List.flatten()
  end

  defp statuses(schema, id) do
    exec!(
      "SELECT status FROM #{table(schema, "document_versions")} WHERE document_id = $1::uuid ORDER BY version_no",
      [id]
    ).rows
    |> List.flatten()
  end

  defp tamper_content!(ctx, id) do
    exec!("ALTER TABLE #{table(ctx.schema, "document_versions")} DISABLE TRIGGER USER")

    exec!(
      "UPDATE #{table(ctx.schema, "document_versions")} SET content = '{\"amount\":999}'::jsonb WHERE document_id = $1::uuid",
      [id]
    )
  end

  describe "cancel/3" do
    test "C1: cancels an issued version and audits the reason without content", ctx do
      {id, v} = issued!(ctx)
      assert {:ok, c} = cancel(ctx, id)
      assert c.status == :cancelled and c.cancelled_by == @actor
      assert c.cancel_reason == "wrong supplier" and c.cancelled_at
      assert [json] = entries(ctx.schema, "document.cancelled")
      assert json =~ "wrong supplier" and json =~ v.content_hash
      refute json =~ @secret
      refute Enum.any?(entries(ctx.schema, "document.issued"), &(&1 =~ @secret))
      assert {:ok, :valid} = Audit.verify_chain(ctx.schema)
    end

    test "C2: a blank reason is refused and changes nothing", ctx do
      {id, _} = issued!(ctx)
      before = count(ctx.schema, "audit_entries")

      for reason <- ["", "   ", nil, 5] do
        assert {:error, {:unprocessable, :reason_required}} = cancel(ctx, id, 1, reason)
      end

      assert {:error, {:unprocessable, :reason_too_long}} =
               cancel(ctx, id, 1, String.duplicate("x", 501))

      assert statuses(ctx.schema, id) == ["issued"]
      assert count(ctx.schema, "audit_entries") == before
    end

    test "C3: a draft, superseded, discarded or cancelled version is not cancelled", ctx do
      {id, _} = issued!(ctx)

      {:ok, _} =
        Documents.new_version_from_current(ctx.schema, %{document_id: id, actor_id: @actor})

      before = count(ctx.schema, "audit_entries")
      assert {:error, :not_issued} = cancel(ctx, id, 2)
      {:ok, %{version: _}} = Documents.issue(ctx.schema, %{document_id: id, actor_id: @actor})
      assert {:error, :not_issued} = cancel(ctx, id, 1)

      {:ok, _} =
        Documents.new_version_from_current(ctx.schema, %{document_id: id, actor_id: @actor})

      {:ok, _} = Documents.discard_draft(ctx.schema, id, @actor)
      assert {:error, :not_issued} = cancel(ctx, id, 3)

      assert {:ok, _} = cancel(ctx, id, 2)
      assert {:error, :not_issued} = cancel(ctx, id, 2)
      assert statuses(ctx.schema, id) == ["superseded", "cancelled", "discarded"]
      assert Enum.count(entries(ctx.schema, "document.cancelled")) == 1
      assert count(ctx.schema, "audit_entries") > before
    end

    test "C4: absent version, malformed id and another tenant's id give :not_found", ctx do
      {id, _} = issued!(ctx)
      %{schema_name: other} = provisioned_tenant!("req543-cx")

      assert {:error, :not_found} = cancel(ctx, id, 7)
      assert {:error, :not_found} = cancel(ctx, "nope")
      assert {:error, :not_found} = cancel(%{ctx | schema: other}, id)
      assert statuses(ctx.schema, id) == ["issued"]
    end

    test "C5: a cancelled version is readable and never issued again", ctx do
      {id, v} = issued!(ctx)
      {:ok, _} = cancel(ctx, id)
      assert %{status: :cancelled} = Repo.get(Documents.DocumentVersion, v.id, prefix: ctx.schema)

      assert {:error, :no_issued_version} =
               Documents.new_version_from_current(ctx.schema, %{document_id: id, actor_id: @actor})

      sql =
        "UPDATE #{table(ctx.schema, "document_versions")} SET status = 'issued' WHERE id = $1::uuid"

      assert {:refused, _} = attempt(sql, [v.id])
    end
  end

  describe "verify_binding/4" do
    test "V1: true for an issued version with the matching hash", ctx do
      {id, v} = issued!(ctx)
      assert Documents.verify_binding(ctx.schema, id, 1, v.content_hash) == true
      assert entries(ctx.schema, "document.integrity_failed") == []
    end

    test "V2: every other case is the same bare false", ctx do
      {id, v} = issued!(ctx)
      {other_id, other_v} = issued!(ctx)
      %{schema_name: other} = provisioned_tenant!("req543-vx")

      {:ok, _} =
        Documents.new_version_from_current(ctx.schema, %{document_id: id, actor_id: @actor})

      {:ok, _} = Documents.issue(ctx.schema, %{document_id: id, actor_id: @actor})
      s = ctx.schema

      assert false == Documents.verify_binding(s, id, 2, String.duplicate("0", 64))
      assert false == Documents.verify_binding(s, id, 1, v.content_hash)
      assert false == Documents.verify_binding(s, id, 2, other_v.content_hash)
      assert false == Documents.verify_binding(s, id, 9, v.content_hash)
      assert false == Documents.verify_binding(other, id, 2, v.content_hash)
      assert false == Documents.verify_binding(s, "nope", 1, v.content_hash)
      assert false == Documents.verify_binding(s, id, "1", v.content_hash)
      assert false == Documents.verify_binding(s, id, 1, nil)
      assert false == Documents.verify_binding(nil, id, 1, v.content_hash)

      {:ok, _} = cancel(ctx, other_id)
      assert false == Documents.verify_binding(s, other_id, 1, other_v.content_hash)
    end

    test "V3: tenant B probing tenant A's document id learns nothing", ctx do
      {id, v} = issued!(ctx)
      %{schema_name: other} = provisioned_tenant!("req543-vb")
      a_audit = count(ctx.schema, "audit_entries")

      assert false == Documents.verify_binding(other, id, 1, v.content_hash)
      assert count(ctx.schema, "audit_entries") == a_audit
      assert entries(other, "document.integrity_failed") == []
      assert entries(ctx.schema, "document.integrity_failed") == []
      assert true == Documents.verify_binding(ctx.schema, id, 1, v.content_hash)
    end
  end

  describe "integrity" do
    test "I1: tampered content gives false and one integrity_failed entry", ctx do
      {id, v} = issued!(ctx)
      tamper_content!(ctx, id)
      assert false == Documents.verify_binding(ctx.schema, id, 1, v.content_hash)
      assert [json] = entries(ctx.schema, "document.integrity_failed")
      assert json =~ v.content_hash
      refute json =~ "amount"
      refute json =~ @secret
      assert {:ok, :valid} = Audit.verify_chain(ctx.schema)
    end

    test "I2: a tampered document number is detected", ctx do
      {id, v} = issued!(ctx)
      exec!("ALTER TABLE #{table(ctx.schema, "documents")} DISABLE TRIGGER USER")
      exec!("UPDATE #{table(ctx.schema, "documents")} SET number = 77 WHERE id = $1::uuid", [id])
      assert false == Documents.verify_binding(ctx.schema, id, 1, v.content_hash)
      assert [_] = entries(ctx.schema, "document.integrity_failed")
    end

    test "I3: a tampered stored hash is detected", ctx do
      {id, _} = issued!(ctx)
      exec!("ALTER TABLE #{table(ctx.schema, "document_versions")} DISABLE TRIGGER USER")
      fake = String.duplicate("b", 64)

      exec!(
        "UPDATE #{table(ctx.schema, "document_versions")} SET content_hash = $1 WHERE document_id = $2::uuid",
        [fake, id]
      )

      assert false == Documents.verify_binding(ctx.schema, id, 1, fake)
      assert [_] = entries(ctx.schema, "document.integrity_failed")
    end

    test "I4: production code has no trigger bypass" do
      files = ["lib/letflow/documents.ex" | Path.wildcard("lib/letflow/documents/**/*.ex")]

      for f <- files, bad <- ["DISABLE TRIGGER", "session_replication_role", "ALTER TABLE"] do
        refute File.read!(f) =~ bad, "#{f} contains #{bad}"
      end
    end

    test "I5: an untouched version writes no integrity entry however often it is verified", ctx do
      {id, v} = issued!(ctx)
      for _ <- 1..5, do: assert(Documents.verify_binding(ctx.schema, id, 1, v.content_hash))
      assert entries(ctx.schema, "document.integrity_failed") == []
    end

    test "T1: inside a caller's transaction that commits, the entry persists", ctx do
      {id, v} = issued!(ctx)
      tamper_content!(ctx, id)

      assert {:ok, false} =
               Repo.transaction(fn ->
                 Documents.verify_binding(ctx.schema, id, 1, v.content_hash)
               end)

      assert [_] = entries(ctx.schema, "document.integrity_failed")
      assert {:ok, :valid} = Audit.verify_chain(ctx.schema)
    end

    test "T2: a caller that rolls back loses the entry; its transaction is not poisoned", ctx do
      {id, v} = issued!(ctx)
      tamper_content!(ctx, id)

      assert {:error, :refused} =
               Repo.transaction(fn ->
                 false = Documents.verify_binding(ctx.schema, id, 1, v.content_hash)
                 assert count(ctx.schema, "documents") == 1
                 Repo.rollback(:refused)
               end)

      assert entries(ctx.schema, "document.integrity_failed") == []
    end
  end

  defmodule Boom do
    @behaviour Letflow.Documents.OrgResolver
    @impl true
    def unit_exists?(_prefix, _unit), do: raise("unit_exists? must not be called")
    @impl true
    def legal_entity_of(_prefix, _unit), do: raise("legal_entity_of must not be called")
  end

  test "R1: verify_binding and reads do not consult the org resolver for a retired unit", ctx do
    {id, v} = issued!(ctx)
    {:ok, _} = ScopeNodePaths.write({:retire, ctx.unit}, ctx.schema)
    Process.put(:letflow_document_org_resolver, Boom)

    assert true == Documents.verify_binding(ctx.schema, id, 1, v.content_hash)
    assert %{} = Repo.get(Documents.Document, id, prefix: ctx.schema)
    assert %{} = Repo.get(Documents.DocumentVersion, v.id, prefix: ctx.schema)
    assert {:ok, _} = cancel(ctx, id)
  end
end
