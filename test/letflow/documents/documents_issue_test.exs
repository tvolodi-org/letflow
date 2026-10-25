defmodule Letflow.Documents.DocumentsIssueTest do
  @moduledoc """
  REQ-543 / GH #3163 part 2a, criteria 1, 2, 5a, 5b (issue half), 6, 7: `Letflow.Documents.issue/2`
  (decision 0056 D2, D3, D4, D8). Design: state/tasks/T-0635/design.md, tests N1..N3, S1..S4,
  R1, R2, O1, O2, U1, X1, T1, E1. The forced-overlap cases N4 and B1 are in `issue_lock_order_test.exs`.
  """

  use Letflow.DataCase, async: false

  import Letflow.DocumentSqlFixture

  alias Letflow.Documents
  alias Letflow.Documents.Canonical
  alias Letflow.Documents.PrintLayout
  alias Letflow.Repo
  alias Letflow.ScopeNodePaths

  @actor "99999999-9999-4999-8999-999999999999"
  @secret "SENTINEL-CONTENT-VALUE"

  setup do
    %{schema_name: schema, tenant_id: tenant_id} = provisioned_tenant!("req543-is")
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

  defp create!(ctx, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          type_key: "purchase_request",
          issuing_org_unit_id: ctx.unit,
          content: %{"amount" => 10, "note" => @secret}
        },
        overrides
      )

    {:ok, %{document: d}} = Documents.create_draft(ctx.schema, attrs, @actor)
    d.id
  end

  defp issue(ctx, id), do: Documents.issue(ctx.schema, %{document_id: id, actor_id: @actor})

  defp year, do: DateTime.utc_now() |> DateTime.add(5 * 3600, :second) |> Map.fetch!(:year)

  defp counters(schema, type \\ "purchase_request") do
    exec!(
      "SELECT legal_entity_key, period, counter FROM #{table(schema, "document_sequences")} WHERE type_key = $1 ORDER BY period",
      [type]
    ).rows
  end

  defp count(schema, tbl),
    do: exec!("SELECT count(*) FROM #{table(schema, tbl)}").rows |> hd() |> hd()

  defp audit(schema, action) do
    exec!(
      "SELECT after_state::text FROM #{table(schema, "audit_entries")} WHERE action = $1 ORDER BY timestamp, id",
      [action]
    ).rows
    |> List.flatten()
  end

  defp status_of(schema, id),
    do:
      exec!(
        "SELECT status FROM #{table(schema, "document_versions")} WHERE document_id = $1::uuid ORDER BY version_no",
        [id]
      ).rows
      |> List.flatten()

  defp restrict!(schema, type, field) do
    exec!(
      "INSERT INTO #{table(schema, "entity_field_restrictions")} (id, entity_type, field_name, inserted_at, updated_at) VALUES (gen_random_uuid(), $1, $2, now(), now())",
      [type, field]
    )
  end

  test "N1: the first issue in a new scope gets 1, the next document 2", ctx do
    assert counters(ctx.schema) == []
    a = create!(ctx)
    b = create!(ctx)

    assert {:ok, %{document: da, version: va}} = issue(ctx, a)

    assert da.number == 1 and da.period == Integer.to_string(year()) and
             da.current_version == va.id

    assert va.status == :issued

    key = Canonical.legal_entity_sentinel()
    assert [[^key, _, 1]] = counters(ctx.schema)
    assert {:ok, %{document: db}} = issue(ctx, b)
    assert db.number == 2
    assert [[^key, _, 2]] = counters(ctx.schema)
  end

  test "N2: an issue that rolls back releases its number", ctx do
    a = create!(ctx)

    assert {:error, :rolled_back} =
             Repo.transaction(fn ->
               assert {:ok, %{document: %{number: 1}}} = issue(ctx, a)
               Repo.rollback(:rolled_back)
             end)

    assert counters(ctx.schema) == []
    assert status_of(ctx.schema, a) == ["draft"]
    assert {:ok, %{document: %{number: 1}}} = issue(ctx, a)
  end

  test "N3: the sequence row is inserted, then locked, then read and incremented" do
    src = File.read!("lib/letflow/documents.ex")
    [_, fun] = String.split(src, "defp allocate_number!", parts: 2)
    {insert, _} = :binary.match(fun, "Repo.insert_all(")
    {lock, _} = :binary.match(fun, ~s(lock: "FOR UPDATE"))
    {read, _} = :binary.match(fun, "row.counter")
    {write, _} = :binary.match(fun, "set: [counter: number]")
    assert insert < lock and lock < read and read < write
  end

  test "S1: version 2 supersedes version 1, keeps the number, one issued version", ctx do
    id = create!(ctx)
    {:ok, %{version: v1}} = issue(ctx, id)

    {:ok, v2} =
      Documents.new_version_from_current(ctx.schema, %{document_id: id, actor_id: @actor})

    assert {:ok, %{document: doc, version: issued2}} = issue(ctx, id)
    assert issued2.id == v2.id and issued2.status == :issued
    assert doc.current_version == v2.id and doc.number == 1
    assert status_of(ctx.schema, id) == ["superseded", "issued"]
    assert [[_, _, 1]] = counters(ctx.schema)

    assert Repo.get!(Letflow.Documents.DocumentVersion, v1.id, prefix: ctx.schema).superseded_by_version ==
             v2.id
  end

  test "S2: the stored hash has the allocated number as an input", ctx do
    id = create!(ctx)
    assert {:ok, %{document: d, version: v}} = issue(ctx, id)
    {:ok, bytes} = Canonical.canonicalize(v.content)

    inputs = %{
      tenant_uuid: ctx.tenant_id,
      document_id: id,
      type_key: "purchase_request",
      legal_entity_id: nil,
      number: d.number,
      version_no: 1,
      canonical_content: bytes
    }

    assert {:ok, hash} = Canonical.content_hash(inputs)
    assert v.content_hash == hash
    assert {:ok, other} = Canonical.content_hash(%{inputs | number: d.number + 1})
    assert other != hash
  end

  test "S3: document.issued and document.superseded carry no field value", ctx do
    id = create!(ctx)
    {:ok, _} = issue(ctx, id)

    {:ok, _} =
      Documents.new_version_from_current(ctx.schema, %{document_id: id, actor_id: @actor})

    {:ok, _} = issue(ctx, id)

    issued = audit(ctx.schema, "document.issued")
    superseded = audit(ctx.schema, "document.superseded")
    assert length(issued) == 2 and length(superseded) == 1
    assert hd(issued) =~ "PR-#{year()}-0001"
    for text <- issued ++ superseded, do: refute(text =~ @secret)
    assert {:ok, :valid} = Letflow.Audit.verify_chain(ctx.schema)
  end

  test "S4: issued_at is the server clock, a supplied hash or number is refused or ignored",
       ctx do
    id = create!(ctx)
    before = DateTime.utc_now()

    assert {:error, {:unprocessable, :content_hash_not_accepted}} =
             Documents.issue(ctx.schema, %{document_id: id, actor_id: @actor, content_hash: "x"})

    assert {:ok, %{document: d, version: v}} =
             Documents.issue(ctx.schema, %{
               document_id: id,
               actor_id: @actor,
               number: 99,
               issued_at: ~U[2000-01-01 00:00:00.000000Z]
             })

    assert d.number == 1
    assert DateTime.compare(v.issued_at, DateTime.add(before, -1, :second)) == :gt
    assert DateTime.compare(v.issued_at, DateTime.add(DateTime.utc_now(), 1, :second)) == :lt
    assert v.issued_by == @actor
  end

  test "R1: a restriction on a declared field refuses, allocates nothing, number stays consecutive",
       ctx do
    {:ok, _} =
      Documents.register_type(
        ctx.schema,
        type_attrs(%{
          key: "invoice",
          number_prefix: "INV",
          declared_fields: %{"order" => ["total"]}
        }),
        %{actor_id: @actor}
      )

    ok = create!(ctx, %{type_key: "invoice"})
    refused = create!(ctx, %{type_key: "invoice"})
    later = create!(ctx, %{type_key: "invoice"})
    assert {:ok, %{document: %{number: 1}}} = issue(ctx, ok)
    before = counters(ctx.schema, "invoice")

    restrict!(ctx.schema, "order", "total")
    assert {:error, {:restricted_field, "order", "total"}} = issue(ctx, refused)
    assert counters(ctx.schema, "invoice") == before
    assert status_of(ctx.schema, refused) == ["draft"]

    exec!("DELETE FROM #{table(ctx.schema, "entity_field_restrictions")}")
    assert {:ok, %{document: %{number: 2}}} = issue(ctx, later)
  end

  test "R2: a free field whose stored mark is not public refuses", ctx do
    {:ok, _} =
      Documents.register_type(
        ctx.schema,
        type_attrs(%{
          key: "memo",
          number_prefix: "M",
          declared_fields: %{"_free" => ["note"]},
          sensitivity: %{"note" => "public"}
        }),
        %{actor_id: @actor}
      )

    exec!(
      "UPDATE #{table(ctx.schema, "document_types")} SET declared_fields = '{\"_free\":{\"note\":\"secret\"}}'::jsonb WHERE key = 'memo'"
    )

    id = create!(ctx, %{type_key: "memo"})
    assert {:error, {:restricted_field, "_free", "note"}} = issue(ctx, id)
    assert counters(ctx.schema, "memo") == []
  end

  defmodule Retired do
    @moduledoc false
    @behaviour Letflow.Documents.OrgResolver
    @impl true
    def unit_exists?(_prefix, _unit), do: false
    @impl true
    def legal_entity_of(_prefix, _unit), do: {:error, :unit_not_found}
  end

  test "O1: a retired or unknown org unit refuses and allocates nothing", ctx do
    id = create!(ctx)
    {:ok, _} = ScopeNodePaths.write({:retire, ctx.unit}, ctx.schema)
    assert {:error, :org_unit_not_found} = issue(ctx, id)
    assert counters(ctx.schema) == []
    assert status_of(ctx.schema, id) == ["draft"]

    Process.put(:letflow_document_org_resolver, Retired)
    assert {:error, :org_unit_not_found} = issue(ctx, id)
    assert counters(ctx.schema) == []
  end

  test "O2: a legal-entity type forced in by SQL fails closed; another type is unaffected", ctx do
    exec!("""
    INSERT INTO #{table(ctx.schema, "document_types")}
      (key, tenant_id, owner_module, numbering_scope, number_prefix, number_pad,
       legal_entity_required, declared_fields, inserted_at)
    VALUES ('forced', '#{ctx.tenant_id}'::uuid, 'procurement', 'year', 'F', 4, true, '{}'::jsonb, now())
    """)

    doc = insert_document!(ctx.schema, ctx.tenant_id, "forced", issuing_org_unit_id: ctx.unit)

    exec!(
      """
      INSERT INTO #{table(ctx.schema, "document_versions")}
        (id, tenant_id, document_id, version_no, status, content, inserted_at)
      VALUES (gen_random_uuid(), $1::uuid, $2::uuid, 1, 'draft', '{"a":1}'::text::jsonb, now())
      """,
      [ctx.tenant_id, doc]
    )

    assert {:error, :legal_entity_resolver_unavailable} = issue(ctx, doc)
    assert counters(ctx.schema, "forced") == []
    assert count(ctx.schema, "document_sequences") == 0

    assert {:ok, %{document: %{number: 1}}} = issue(ctx, create!(ctx))
  end

  defp issued_raw!(ctx, number, period) do
    doc =
      insert_document!(ctx.schema, ctx.tenant_id, "purchase_request",
        issuing_org_unit_id: ctx.unit
      )

    v = insert_version!(ctx.schema, ctx.tenant_id, doc, 1, "issued")
    set_current!(ctx.schema, doc, v)
    set_number!(ctx.schema, doc, number, period)
    doc
  end

  test "U1: a duplicate (type, period, number) with a null entity is an error tuple", ctx do
    period = Integer.to_string(year())
    issued_raw!(ctx, 1, period)

    other =
      insert_document!(ctx.schema, ctx.tenant_id, "purchase_request",
        issuing_org_unit_id: ctx.unit
      )

    v = insert_version!(ctx.schema, ctx.tenant_id, other, 1, "issued")
    set_current!(ctx.schema, other, v)

    assert {:refused, _} =
             attempt(
               "UPDATE #{table(ctx.schema, "documents")} SET number = 1, period = $2 WHERE id = $1::uuid",
               [other, period]
             )

    assert {:error, :version_conflict} = issue(ctx, create!(ctx))
    assert counters(ctx.schema) == []
  end

  test "X1: issue calls no renderer and no byte store", ctx do
    Code.ensure_loaded!(PrintLayout)
    id = create!(ctx)
    :erlang.trace_pattern({PrintLayout, :_, :_}, true, [:local])
    :erlang.trace(self(), true, [:call])
    result = issue(ctx, id)
    :erlang.trace(self(), false, [:call])
    :erlang.trace_pattern({PrintLayout, :_, :_}, false, [:local])

    assert {:ok, _} = result
    refute_received {:trace, _, :call, _}

    src = File.read!("lib/letflow/documents.ex")
    [_, rest] = String.split(src, "  def issue(prefix", parts: 2)
    [region, _] = String.split(rest, "  # helpers", parts: 2)

    for word <- ["PrintLayout", "Attachment", "File.", ":file", "Req."],
        do: refute(region =~ word)
  end

  test "T1: another tenant's document id is not_found, like a random id", ctx do
    id = create!(ctx)
    %{schema_name: other} = provisioned_tenant!("req543-ot")

    assert {:error, :not_found} = Documents.issue(other, %{document_id: id, actor_id: @actor})

    assert {:error, :not_found} =
             Documents.issue(other, %{document_id: Ecto.UUID.generate(), actor_id: @actor})

    assert status_of(ctx.schema, id) == ["draft"]
    assert counters(ctx.schema) == []
  end

  test "E1: no draft, a second issue and a discarded draft are refused without a number", ctx do
    id = create!(ctx)
    assert {:ok, _} = issue(ctx, id)
    assert {:error, :no_draft} = issue(ctx, id)
    assert [[_, _, 1]] = counters(ctx.schema)

    gone = create!(ctx)
    {:ok, _} = Documents.discard_draft(ctx.schema, gone, @actor)
    assert {:error, :no_draft} = issue(ctx, gone)
    assert [[_, _, 1]] = counters(ctx.schema)
  end
end
