defmodule Letflow.Documents.DocumentsDraftTest do
  @moduledoc """
  REQ-542 / GH #3164 criteria 4 to 7 and 9: `Letflow.Documents.create_draft/3`, `edit_draft/4`,
  `discard_draft/3`, `new_version_from_current/2` (decision 0056 D1, D3, D9).
  Design: state/tasks/T-0474/design.md, tests T7, T8, D1..D8.
  """

  use Letflow.DataCase, async: false

  import Letflow.DocumentSqlFixture

  alias Letflow.Audit
  alias Letflow.Documents
  alias Letflow.Documents.TestResolvers
  alias Letflow.ScopeNodePaths

  @actor "99999999-9999-4999-8999-999999999999"
  @secret "SENTINEL-CONTENT-VALUE"

  setup do
    %{schema_name: schema, tenant_id: tenant_id} = provisioned_tenant!("req542-dr")
    {:ok, _} = Documents.register_type(schema, type_attrs(), %{actor_id: @actor})
    unit = Ecto.UUID.generate()
    {:ok, _} = ScopeNodePaths.write({:insert, unit, nil}, schema)
    %{schema: schema, tenant_id: tenant_id, unit: unit}
  end

  defp type_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        key: "purchase_request",
        owner_module: "procurement",
        numbering_scope: :year,
        number_prefix: "PR",
        number_pad: 4,
        legal_entity_required: false,
        declared_fields: %{}
      },
      overrides
    )
  end

  defp draft_attrs(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        type_key: "purchase_request",
        issuing_org_unit_id: ctx.unit,
        content: %{"amount" => 10, "note" => @secret}
      },
      overrides
    )
  end

  defp create!(ctx, overrides \\ %{}) do
    {:ok, result} = Documents.create_draft(ctx.schema, draft_attrs(ctx, overrides), @actor)
    result
  end

  defp count(schema, table),
    do: exec!("SELECT count(*) FROM #{table(schema, table)}").rows |> hd() |> hd()

  defp audit(schema, action) do
    exec!(
      "SELECT before_state::text, after_state::text FROM #{table(schema, "audit_entries")} WHERE action = $1 ORDER BY timestamp, id",
      [action]
    ).rows
  end

  # The shared fixture binds JSON text as a jsonb string scalar; a map-valued content needs ::text::jsonb.
  defp issued_document(ctx, content \\ ~s({"amount":10})) do
    doc =
      insert_document!(ctx.schema, ctx.tenant_id, "purchase_request",
        issuing_org_unit_id: ctx.unit
      )

    v1 = Ecto.UUID.generate()

    exec!(
      """
      INSERT INTO #{table(ctx.schema, "document_versions")}
        (id, tenant_id, document_id, version_no, status, content, content_hash, issued_at, issued_by, inserted_at)
      VALUES ($1::uuid, $2::uuid, $3::uuid, 1, 'issued', $4::text::jsonb, $5, now(), $6::uuid, now())
      """,
      [v1, ctx.tenant_id, doc, content, String.duplicate("a", 64), @actor]
    )

    set_current!(ctx.schema, doc, v1)
    {doc, v1}
  end

  test "D1: stores document and version 1, no number or hash, one audit entry", ctx do
    %{document: d, version: v} = create!(ctx)
    assert d.type_key == "purchase_request"
    assert d.issuing_org_unit_id == ctx.unit
    assert d.tenant_id == ctx.tenant_id
    assert d.number == nil and d.period == nil and d.current_version == nil
    assert d.legal_entity_id == nil
    assert v.version_no == 1 and v.status == :draft and v.content_hash == nil
    assert v.content == %{"amount" => 10, "note" => @secret}

    assert [[nil, after_state]] = audit(ctx.schema, "document.draft_created")
    refute after_state =~ @secret
    assert after_state =~ ctx.unit
    assert {:ok, :valid} = Audit.verify_chain(ctx.schema)
  end

  test "D2: unknown, retired, blank and malformed units store nothing", ctx do
    {:ok, _} = ScopeNodePaths.write({:retire, ctx.unit}, ctx.schema)
    absent = Ecto.UUID.generate()

    assert {:error, :org_unit_not_found} =
             Documents.create_draft(ctx.schema, draft_attrs(ctx), @actor)

    assert {:error, :org_unit_not_found} =
             Documents.create_draft(
               ctx.schema,
               draft_attrs(ctx, %{issuing_org_unit_id: absent}),
               @actor
             )

    assert {:error, :org_unit_not_found} =
             Documents.create_draft(
               ctx.schema,
               draft_attrs(ctx, %{issuing_org_unit_id: "x"}),
               @actor
             )

    for blank <- [nil, "", "  "] do
      assert {:error, :org_unit_required} =
               Documents.create_draft(
                 ctx.schema,
                 draft_attrs(ctx, %{issuing_org_unit_id: blank}),
                 @actor
               )
    end

    assert {:error, :type_not_found} =
             Documents.create_draft(ctx.schema, draft_attrs(ctx, %{type_key: "nope"}), @actor)

    assert count(ctx.schema, "documents") == 0
    assert audit(ctx.schema, "document.draft_created") == []
  end

  test "D3: a caller-supplied hash is refused", ctx do
    expected = {:error, {:unprocessable, :content_hash_not_accepted}}

    for key <- [:content_hash, "content_hash"] do
      assert expected ==
               Documents.create_draft(ctx.schema, draft_attrs(ctx, %{key => "a"}), @actor)

      assert expected ==
               Documents.create_draft(
                 ctx.schema,
                 draft_attrs(ctx, %{content: %{key => "a"}}),
                 @actor
               )
    end

    %{document: d} = create!(ctx)
    assert expected == Documents.edit_draft(ctx.schema, d.id, %{"content_hash" => "a"}, @actor)
    assert count(ctx.schema, "documents") == 1
  end

  test "content that Canonical refuses is refused at draft time", ctx do
    assert {:error, {:unprocessable, :float_not_allowed}} =
             Documents.create_draft(
               ctx.schema,
               draft_attrs(ctx, %{content: %{"a" => 1.5}}),
               @actor
             )

    assert {:error, {:unprocessable, :invalid_content}} =
             Documents.create_draft(ctx.schema, draft_attrs(ctx, %{content: "text"}), @actor)

    assert count(ctx.schema, "documents") == 0
  end

  describe "legal entity" do
    test "T7: a legal-entity type fails closed under the default resolver", ctx do
      insert_type!(ctx.schema, ctx.tenant_id, "bound")

      exec!(
        "UPDATE #{table(ctx.schema, "document_types")} SET legal_entity_required = true WHERE key = 'bound'"
      )

      assert {:error, :legal_entity_resolver_unavailable} =
               Documents.create_draft(ctx.schema, draft_attrs(ctx, %{type_key: "bound"}), @actor)

      assert count(ctx.schema, "documents") == 0
    end

    test "T8: a type without one stores none and never asks the resolver", ctx do
      Process.put(:letflow_document_org_resolver, TestResolvers.Entity)
      %{document: d} = create!(ctx)
      assert d.legal_entity_id == nil
      refute_received :legal_entity_of_called
    end

    test "T9: a legal-entity type stores the resolver's entity", ctx do
      Process.put(:letflow_document_org_resolver, TestResolvers.Entity)

      {:ok, _} =
        Documents.register_type(
          ctx.schema,
          type_attrs(%{key: "bound", legal_entity_required: true}),
          %{actor_id: @actor}
        )

      %{document: d} = create!(ctx, %{type_key: "bound"})
      assert d.legal_entity_id == TestResolvers.Entity.entity_id()
      assert_received :legal_entity_of_called
    end
  end

  test "D4: edit changes the content in place and writes no audit entry", ctx do
    %{document: d, version: v} = create!(ctx)
    before = count(ctx.schema, "audit_entries")
    assert {:ok, edited} = Documents.edit_draft(ctx.schema, d.id, %{"amount" => 20}, @actor)
    assert edited.id == v.id and edited.content == %{"amount" => 20}
    assert count(ctx.schema, "audit_entries") == before

    assert {:error, {:unprocessable, :float_not_allowed}} =
             Documents.edit_draft(ctx.schema, d.id, %{"a" => 0.5}, @actor)
  end

  test "D5: discard marks the draft, audits, leaves the document unnumbered", ctx do
    %{document: d} = create!(ctx)
    assert {:ok, v} = Documents.discard_draft(ctx.schema, d.id, @actor)
    assert v.status == :discarded and v.discarded_at != nil and v.discarded_by == @actor
    assert [[nil, after_state]] = audit(ctx.schema, "document.draft_discarded")
    refute after_state =~ @secret
    assert [[nil, nil, _, nil]] = [document_row(ctx.schema, d.id)]
    assert count(ctx.schema, "document_sequences") == 0

    assert {:error, :no_draft} = Documents.edit_draft(ctx.schema, d.id, %{"a" => 1}, @actor)
    assert {:error, :no_draft} = Documents.discard_draft(ctx.schema, d.id, @actor)
    assert {:ok, :valid} = Audit.verify_chain(ctx.schema)
  end

  test "D6: a draft version cannot be deleted", ctx do
    %{version: v} = create!(ctx)

    assert {:refused, error} =
             attempt(
               "DELETE FROM #{table(ctx.schema, "document_versions")} WHERE id = $1::uuid",
               [v.id]
             )

    assert error.postgres.code == :restrict_violation
    assert count(ctx.schema, "document_versions") == 1
  end

  describe "new_version_from_current" do
    test "D7: copies the content into draft 2 and leaves version 1 alone", ctx do
      {doc, v1} = issued_document(ctx)
      row_before = version_row(ctx.schema, v1)

      assert {:ok, v2} =
               Documents.new_version_from_current(ctx.schema, %{
                 document_id: doc,
                 actor_id: @actor
               })

      assert v2.version_no == 2 and v2.status == :draft
      assert v2.content == %{"amount" => 10}
      assert v2.content_hash == nil
      assert version_row(ctx.schema, v1) == row_before
      assert [[nil, nil, _, ^v1]] = [document_row(ctx.schema, doc)]
      assert [[_, after_state]] = audit(ctx.schema, "document.draft_created")
      assert after_state =~ ~s("version_no": 2)
      assert {:ok, :valid} = Audit.verify_chain(ctx.schema)
    end

    test "D8: refusals", ctx do
      args = fn doc -> %{document_id: doc, actor_id: @actor} end

      bare = insert_document!(ctx.schema, ctx.tenant_id, "purchase_request")

      assert {:error, :no_issued_version} =
               Documents.new_version_from_current(ctx.schema, args.(bare))

      %{document: d} = create!(ctx)

      assert {:error, :no_issued_version} =
               Documents.new_version_from_current(ctx.schema, args.(d.id))

      {doc, _v1} = issued_document(ctx)
      assert {:ok, _} = Documents.new_version_from_current(ctx.schema, args.(doc))
      assert {:error, :draft_exists} = Documents.new_version_from_current(ctx.schema, args.(doc))

      assert {:error, :not_found} =
               Documents.new_version_from_current(ctx.schema, args.(Ecto.UUID.generate()))

      assert {:error, :not_found} =
               Documents.new_version_from_current(ctx.schema, %{actor_id: "bad", document_id: "x"})

      assert {:error, {:unprocessable, :invalid_actor}} =
               Documents.new_version_from_current(ctx.schema, %{document_id: doc, actor_id: "bad"})
    end

    test "the next draft after a discarded one skips its number", ctx do
      {doc, _v1} = issued_document(ctx)
      args = %{document_id: doc, actor_id: @actor}
      {:ok, _} = Documents.new_version_from_current(ctx.schema, args)
      {:ok, _} = Documents.discard_draft(ctx.schema, doc, @actor)
      assert {:ok, %{version_no: 3}} = Documents.new_version_from_current(ctx.schema, args)
    end
  end
end
