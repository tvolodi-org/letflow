defmodule Letflow.Documents.DocumentsTenancyAuditTest do
  @moduledoc """
  REQ-542 / GH #3164 criterion 10: tenant prefix on every function, a cross-tenant call is
  indistinguishable from an absent id, and the audit chain verifies. Design:
  state/tasks/T-0474/design.md, tests A1..A3.
  """

  use Letflow.DataCase, async: false

  import Letflow.DocumentSqlFixture

  alias Letflow.Audit
  alias Letflow.Documents

  @actor "99999999-9999-4999-8999-999999999999"
  @secret "SENTINEL-CONTENT-VALUE"

  setup do
    %{schema_name: a, tenant_id: ta} = provisioned_tenant!("req542-ta")
    %{schema_name: b} = provisioned_tenant!("req542-tb")

    type = %{
      key: "purchase_request",
      owner_module: "procurement",
      numbering_scope: :year,
      number_prefix: "PR",
      number_pad: 4,
      legal_entity_required: false,
      declared_fields: %{}
    }

    {:ok, _} = Documents.register_type(a, type, %{actor_id: @actor})
    unit = Ecto.UUID.generate()
    {:ok, _} = Letflow.ScopeNodePaths.write({:insert, unit, nil}, a)

    {:ok, %{document: doc}} =
      Documents.create_draft(
        a,
        %{type_key: "purchase_request", issuing_org_unit_id: unit, content: %{"n" => @secret}},
        @actor
      )

    %{a: a, b: b, ta: ta, doc: doc, unit: unit}
  end

  defp snapshot(schema) do
    exec!(
      "SELECT status, content::text FROM #{table(schema, "document_versions")} ORDER BY version_no"
    ).rows
  end

  test "A1: tenant B gets the same :not_found for A's document id as for a random id", ctx do
    absent = Ecto.UUID.generate()
    before = snapshot(ctx.a)

    calls = [
      fn id -> Documents.edit_draft(ctx.b, id, %{"n" => "x"}, @actor) end,
      fn id -> Documents.discard_draft(ctx.b, id, @actor) end,
      fn id -> Documents.new_version_from_current(ctx.b, %{document_id: id, actor_id: @actor}) end
    ]

    for call <- calls do
      assert {:error, :not_found} = call.(ctx.doc.id)
      assert call.(ctx.doc.id) == call.(absent)
    end

    assert snapshot(ctx.a) == before
  end

  test "A1b: a type that exists only in tenant A is unknown in tenant B", ctx do
    assert {:error, :type_not_found} =
             Documents.create_draft(
               ctx.b,
               %{type_key: "purchase_request", issuing_org_unit_id: ctx.unit, content: %{}},
               @actor
             )
  end

  test "A2: the chain verifies and no audit payload holds content", ctx do
    {:ok, _} = Documents.discard_draft(ctx.a, ctx.doc.id, @actor)
    assert {:ok, :valid} = Audit.verify_chain(ctx.a)

    rows =
      exec!(
        "SELECT action, before_state::text, after_state::text FROM #{table(ctx.a, "audit_entries")} WHERE action LIKE 'document.%'"
      ).rows

    assert Enum.map(rows, &hd/1) |> Enum.sort() ==
             ["document.draft_created", "document.draft_discarded", "document.type_registered"]

    refute inspect(rows) =~ @secret
  end

  test "A3: every Repo call in the context carries a prefix" do
    source = File.read!("lib/letflow/documents.ex")

    calls =
      Regex.scan(
        ~r/Repo\.(?:insert_all|insert!|one!|one|get!|get|exists\?|update_all)\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)/s,
        source
      )

    assert length(calls) >= 15
    for [call] <- calls, do: assert(call =~ "prefix", call)
    refute source =~ "Repo.query"
  end
end
