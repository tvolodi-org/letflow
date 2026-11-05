defmodule Letflow.Documents.FetchArtefactTest do
  @moduledoc """
  REQ-623 / GH #3474 criteria 9 and 10, `Letflow.Documents.fetch_artefact/3` (decision 0075 R5, R8,
  R9). Design tests FA1..FA4, FI1..FI3. The integrity cases corrupt a row inside the test's own
  sandbox transaction (`DISABLE TRIGGER USER`), which the rollback at the end of the test undoes.
  """

  use Letflow.DataCase, async: false

  import Letflow.DocumentSqlFixture

  alias Letflow.Documents
  alias Letflow.Documents.TestRenderer
  alias Letflow.ScopeNodePaths

  @actor "99999999-9999-4999-8999-999999999999"

  setup do
    %{schema_name: schema, tenant_id: tenant_id} = provisioned_tenant!("req623-fe")

    {:ok, _} =
      Documents.register_type(
        schema,
        %{
          key: "purchase_request",
          owner_module: "procurement",
          numbering_scope: :none,
          number_prefix: "PR",
          number_pad: 4,
          legal_entity_required: false,
          declared_fields: %{"_free" => ["amount"]},
          sensitivity: %{"amount" => :public},
          template_ref: TestRenderer.ref()
        },
        %{actor_id: @actor}
      )

    unit = Ecto.UUID.generate()
    {:ok, _} = ScopeNodePaths.write({:insert, unit, nil}, schema)
    TestRenderer.install!()
    %{schema: schema, tenant_id: tenant_id, unit: unit}
  end

  defp draft!(ctx) do
    {:ok, %{document: d}} =
      Documents.create_draft(
        ctx.schema,
        %{type_key: "purchase_request", issuing_org_unit_id: ctx.unit, content: %{"amount" => 1}},
        @actor
      )

    d.id
  end

  defp issued!(ctx) do
    id = draft!(ctx)
    {:ok, _} = Documents.issue(ctx.schema, %{document_id: id, actor_id: @actor})
    id
  end

  defp attached!(ctx) do
    id = issued!(ctx)

    {:ok, _} =
      Documents.attach_artefact(ctx.schema, %{document_id: id, version_no: 1, actor_id: @actor})

    id
  end

  defp integrity_entries(ctx) do
    exec!(
      "SELECT after_state FROM #{table(ctx.schema, "audit_entries")} WHERE action = 'document.integrity_failed'"
    ).rows
    |> List.flatten()
  end

  test "FA1: the stored bytes come back with no hash, and nothing is rendered again", ctx do
    test_pid = self()
    id = attached!(ctx)
    TestRenderer.set_fun(fn _, _, _ -> send(test_pid, :called) && {:ok, "x", "v"} end)

    assert {:ok, %{bytes: "%PDF-1.4 test", content_type: "application/pdf"} = result} =
             Documents.fetch_artefact(ctx.schema, id, 1)

    assert result |> Map.keys() |> Enum.sort() == [:bytes, :content_type]
    refute_received :called
  end

  test "FA2: every absent case is the same :not_found, with no audit entry (FI3)", ctx do
    pending = issued!(ctx)
    draft = draft!(ctx)

    for {id, no} <- [
          {Ecto.UUID.generate(), 1},
          {pending, 1},
          {pending, 2},
          {draft, 1},
          {"junk", 1},
          {pending, "1"},
          {nil, nil}
        ] do
      assert {:error, :not_found} = Documents.fetch_artefact(ctx.schema, id, no)
    end

    assert {:error, :not_found} = Documents.fetch_artefact(nil, pending, 1)
    assert integrity_entries(ctx) == []
  end

  test "FA3: another tenant's prefix finds nothing, and attach there writes nothing", ctx do
    id = attached!(ctx)
    other = provisioned_tenant!("req623-fo")
    assert {:error, :not_found} = Documents.fetch_artefact(other.schema_name, id, 1)

    assert {:error, :not_found} =
             Documents.attach_artefact(other.schema_name, %{
               document_id: id,
               version_no: 1,
               actor_id: @actor
             })

    for schema <- [ctx.schema, other.schema_name] do
      expected = if schema == ctx.schema, do: 1, else: 0

      assert [[^expected]] =
               exec!("SELECT count(*)::int FROM #{table(schema, "repository_artifacts")}").rows
    end
  end

  test "FA4: a version superseded or cancelled after the attach stays readable", ctx do
    id = attached!(ctx)

    {:ok, _} =
      Documents.new_version_from_current(ctx.schema, %{document_id: id, actor_id: @actor})

    {:ok, _} = Documents.issue(ctx.schema, %{document_id: id, actor_id: @actor})
    assert {:ok, %{bytes: "%PDF-1.4 test"}} = Documents.fetch_artefact(ctx.schema, id, 1)

    id2 = attached!(ctx)

    {:ok, _} =
      Documents.cancel(ctx.schema, %{document_id: id2, version_no: 1, reason: "r"}, @actor)

    assert {:ok, %{bytes: "%PDF-1.4 test"}} = Documents.fetch_artefact(ctx.schema, id2, 1)
  end

  test "FI1: corrupt stored content is :not_found with one content integrity entry", ctx do
    id = attached!(ctx)
    exec!("ALTER TABLE #{table(ctx.schema, "document_versions")} DISABLE TRIGGER USER")

    exec!(
      "UPDATE #{table(ctx.schema, "document_versions")} SET content = '{\"amount\": 2}'::jsonb"
    )

    assert {:error, :not_found} = Documents.fetch_artefact(ctx.schema, id, 1)
    assert [%{"check" => "content", "version_no" => 1}] = integrity_entries(ctx)
  end

  test "FI2: corrupt artefact bytes are :not_found with one artefact integrity entry", ctx do
    id = attached!(ctx)
    exec!("ALTER TABLE #{table(ctx.schema, "repository_artifacts")} DISABLE TRIGGER USER")
    exec!("UPDATE #{table(ctx.schema, "repository_artifacts")} SET content = 'tampered'::bytea")

    assert {:error, :not_found} = Documents.fetch_artefact(ctx.schema, id, 1)
    assert [%{"check" => "artefact", "artefact_hash" => hash}] = integrity_entries(ctx)
    assert byte_size(hash) == 64
  end

  test "FI2b: a missing artefact row is :not_found with one artefact integrity entry", ctx do
    id = attached!(ctx)
    exec!("ALTER TABLE #{table(ctx.schema, "repository_artifacts")} DISABLE TRIGGER USER")
    exec!("DELETE FROM #{table(ctx.schema, "repository_artifacts")}")

    assert {:error, :not_found} = Documents.fetch_artefact(ctx.schema, id, 1)
    assert [%{"check" => "artefact", "recomputed_hash" => nil}] = integrity_entries(ctx)
  end
end
