defmodule Letflow.Documents.RefusalsCounterTest do
  @moduledoc """
  REQ-543 / GH #3163 part 2b, criterion 8: a refused `issue/2`, `cancel/3` or `verify_binding/4`
  emits `[:letflow, :documents, :refused]` and writes no audit row. Design tests F1..F4.
  """

  use Letflow.DataCase, async: false

  import Letflow.DocumentSqlFixture

  alias Letflow.Documents
  alias Letflow.ScopeNodePaths

  @actor "99999999-9999-4999-8999-999999999999"
  @secret "SENTINEL-CONTENT-VALUE"
  @event [:letflow, :documents, :refused]

  setup do
    %{schema_name: schema} = provisioned_tenant!("req543-rc")

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

    {:ok, %{document: d}} =
      Documents.create_draft(
        schema,
        %{type_key: "purchase_request", issuing_org_unit_id: unit, content: %{"note" => @secret}},
        @actor
      )

    me = self()
    id = "rc-#{System.unique_integer([:positive])}"
    :telemetry.attach(id, @event, fn _e, m, meta, _ -> send(me, {:refused, m, meta}) end, nil)
    on_exit(fn -> :telemetry.detach(id) end)
    %{schema: schema, doc: d.id}
  end

  defp audit_count(schema),
    do: exec!("SELECT count(*) FROM #{table(schema, "audit_entries")}").rows |> hd() |> hd()

  test "F1: each kind of refusal emits one event and writes no audit row", ctx do
    s = ctx.schema
    before = audit_count(s)

    assert {:error, {:unprocessable, :invalid_actor}} =
             Documents.issue(s, %{document_id: ctx.doc, actor_id: "x"})

    assert_receive {:refused, %{count: 1}, %{action: :issue, reason: :invalid_actor}}

    assert {:ok, %{version: v}} = Documents.issue(s, %{document_id: ctx.doc, actor_id: @actor})
    refute_received {:refused, _, _}

    assert {:error, :no_draft} = Documents.issue(s, %{document_id: ctx.doc, actor_id: @actor})
    assert_receive {:refused, %{count: 1}, %{action: :issue, reason: :no_draft}}

    assert {:error, {:unprocessable, :reason_required}} =
             Documents.cancel(s, %{document_id: ctx.doc, version_no: 1, reason: " "}, @actor)

    assert_receive {:refused, %{count: 1}, %{action: :cancel, reason: :reason_required}}

    assert false == Documents.verify_binding(s, ctx.doc, 1, String.duplicate("0", 64))
    assert_receive {:refused, %{count: 1}, %{action: :verify_binding, reason: :hash_mismatch}}

    assert false == Documents.verify_binding(s, ctx.doc, 5, v.content_hash)
    assert_receive {:refused, %{count: 1}, %{action: :verify_binding, reason: :absent}}
    refute_received {:refused, _, _}

    # only the successful issue wrote audit rows
    assert audit_count(s) > before
    after_issue = audit_count(s)
    Documents.cancel(s, %{document_id: ctx.doc, version_no: 1, reason: ""}, @actor)
    assert audit_count(s) == after_issue
  end

  test "F2: many refused verifies write no audit row; successes emit no event", ctx do
    {:ok, %{version: v}} = Documents.issue(ctx.schema, %{document_id: ctx.doc, actor_id: @actor})
    n = audit_count(ctx.schema)
    for _ <- 1..20, do: Documents.verify_binding(ctx.schema, ctx.doc, 1, "bad")
    assert audit_count(ctx.schema) == n
    assert Documents.verify_binding(ctx.schema, ctx.doc, 1, v.content_hash)
    for _ <- 1..20, do: assert_receive({:refused, _, _})
    refute_received {:refused, _, _}
  end

  test "F3: the metadata holds exactly action, prefix and reason, no content or hash", ctx do
    {:ok, %{version: v}} = Documents.issue(ctx.schema, %{document_id: ctx.doc, actor_id: @actor})
    Documents.verify_binding(ctx.schema, ctx.doc, 1, "bad")
    assert_receive {:refused, _, meta}
    assert meta |> Map.keys() |> Enum.sort() == [:action, :prefix, :reason]
    refute inspect(meta) =~ @secret
    refute inspect(meta) =~ v.content_hash
  end

  test "F4: refusals_summary is not built" do
    refute File.read!("lib/letflow/documents.ex") =~ "def refusals_summary"
  end
end
