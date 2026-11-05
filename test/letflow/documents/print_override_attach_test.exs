defmodule Letflow.Documents.PrintOverrideAttachTest.PdfProbe do
  @moduledoc false
  # Test-side reader of the S1 renderer's PDF: the text items in page order (same reader as
  # print_layout/render_test.exs).

  def items(bin) do
    streams = streams(bin)
    {8, cmap_text, _} = List.keyfind(streams, 8, 0)

    cmap =
      ~r/<([0-9A-F]{4})> <([0-9A-F]+)>/
      |> Regex.scan(cmap_text)
      |> Map.new(fn [_, cid, hex] ->
        {String.to_integer(cid, 16),
         :unicode.characters_to_binary(Base.decode16!(hex), {:utf16, :big})}
      end)

    streams
    |> Enum.filter(fn {n, _, _} -> n >= 10 and rem(n, 2) == 0 end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {_, text, _} ->
      for [_, group] <- Regex.scan(~r/BT\n(.*?)ET\n/s, text) do
        for [_, hex] <- Regex.scan(~r/<([0-9A-F]*)> Tj/, group), into: "" do
          for <<cid::binary-4 <- hex>>, into: "", do: Map.fetch!(cmap, String.to_integer(cid, 16))
        end
      end
    end)
  end

  defp streams(bin) do
    for [{s, l}, {ns, nl}, {ds, dl}] <-
          Regex.scan(~r/(\d+) 0 obj\n<< ([^>]*)>>\nstream\n/, bin, return: :index) do
      n = bin |> binary_part(ns, nl) |> String.to_integer()
      [_, len] = Regex.run(~r/\/Length (\d+)/, binary_part(bin, ds, dl))
      {n, :zlib.uncompress(binary_part(bin, s + l, String.to_integer(len))), nil}
    end
  end
end

defmodule Letflow.Documents.PrintOverrideAttachTest do
  @moduledoc """
  REQ-624 / GH #3485 (decision 0068 D8 S3), render half: `attach_artefact/2` prints the override
  pinned on the version, never the active one. Design: state/tasks/T-1281/design.md, tests
  C3-render, L1, U1, U2, PJ1.
  """

  use Letflow.DataCase, async: false

  import Letflow.DocumentSqlFixture

  alias Letflow.Documents
  alias Letflow.Documents.PrintOverride
  alias Letflow.Documents.PrintOverrideAttachTest.PdfProbe
  alias Letflow.Documents.PrintOverrides
  alias Letflow.Documents.TestRenderer
  alias Letflow.Repo
  alias Letflow.ScopeNodePaths

  @actor "99999999-9999-4999-8999-999999999999"
  @alice "0d5f6f55-5a3c-4b2e-9a27-6a7d7a4a1c11"
  @bob "1e6a7a66-6b4d-4c3f-8b38-7b8e8b5b2d22"
  @sentinel "SENTINEL-HIDDEN-VALUE-31"

  defp tenant!(slug, template_ref \\ nil) do
    %{schema_name: schema, tenant_id: tenant_id} = provisioned_tenant!(slug)

    {:ok, _} =
      Documents.register_type(
        schema,
        Map.merge(
          %{
            key: "invoice",
            owner_module: "procurement",
            numbering_scope: :year,
            number_prefix: "IN",
            number_pad: 4,
            legal_entity_required: false,
            declared_fields: %{"order" => ["number", "total"]}
          },
          if(template_ref, do: %{template_ref: template_ref}, else: %{})
        ),
        %{actor_id: @actor}
      )

    unit = Ecto.UUID.generate()
    {:ok, _} = ScopeNodePaths.write({:insert, unit, nil}, schema)
    %{schema: schema, tenant_id: tenant_id, unit: unit}
  end

  setup do
    TestRenderer.install!()
    %{a: tenant!("req624-at-a"), b: tenant!("req624-at-b", TestRenderer.ref())}
  end

  defp layout(text) do
    %{
      "layout_schema_version" => 1,
      "blocks" => [
        %{"type" => "page", "size" => "A4", "margin_mm" => 10, "font" => "dejavu-sans"},
        %{"type" => "text", "text" => text},
        %{"type" => "field", "entity_type" => "order", "field_name" => "number"}
      ]
    }
  end

  defp save!(ctx, text) do
    {:ok, row} =
      PrintOverrides.save_draft(
        ctx.schema,
        %{type_key: "invoice", locale: "default", layout: layout(text)},
        @alice
      )

    row
  end

  defp active!(ctx, text) do
    row = save!(ctx, text)
    {:ok, row} = PrintOverrides.activate(ctx.schema, row.id, %{reason_code: "go_live"}, @bob)
    row
  end

  defp retire!(ctx, row),
    do: {:ok, _} = PrintOverrides.retire(ctx.schema, row.id, %{reason_code: "stop"}, @alice)

  defp issued!(ctx, content \\ %{}) do
    content =
      Map.merge(%{"order" => %{"number" => "N-1", "total" => 5, "secret" => @sentinel}}, content)

    {:ok, %{document: d}} =
      Documents.create_draft(
        ctx.schema,
        %{type_key: "invoice", issuing_org_unit_id: ctx.unit, content: content},
        @actor
      )

    {:ok, %{version: v}} = Documents.issue(ctx.schema, %{document_id: d.id, actor_id: @actor})
    {d.id, v.version_no}
  end

  defp attach(ctx, {id, no}),
    do:
      Documents.attach_artefact(ctx.schema, %{document_id: id, version_no: no, actor_id: @actor})

  defp pdf!(ctx, {id, no}) do
    {:ok, %{bytes: bytes}} = Documents.fetch_artefact(ctx.schema, id, no)
    bytes
  end

  defp row(ctx, {id, no}) do
    exec!(
      """
      SELECT artefact_hash, print_override_id::text, print_override_version,
             print_override_layout_hash, template_version
      FROM #{table(ctx.schema, "document_versions")} WHERE document_id = $1::uuid AND version_no = $2
      """,
      [id, no]
    ).rows
    |> hd()
  end

  defp add_restriction!(ctx) do
    exec!(
      "INSERT INTO #{table(ctx.schema, "entity_field_restrictions")} (id, entity_type, field_name, inserted_at, updated_at) VALUES (gen_random_uuid(), 'order', 'total', now(), now())"
    )
  end

  test "C3-render only the tenant that has an override prints it", %{a: a, b: b} do
    active!(a, "LITERAL-A")
    doc_a = issued!(a)
    doc_b = issued!(b)

    assert {:ok, _} = attach(a, doc_a)
    assert {:ok, _} = attach(b, doc_b)

    assert "LITERAL-A" in PdfProbe.items(pdf!(a, doc_a))
    assert [hash_b, nil, nil, nil, nil] = row(b, doc_b)
    assert is_binary(hash_b)
    refute pdf!(b, doc_b) =~ "LITERAL-A"

    assert [after_b] =
             exec!(
               "SELECT after_state FROM #{table(b.schema, "audit_entries")} WHERE action = 'document.issued'"
             ).rows
             |> List.flatten()

    refute Map.has_key?(after_b, "print_override_id")
    pinned = Enum.at(row(a, doc_a), 1)

    # B's schema does not hold A's override row at all
    assert Repo.get(PrintOverride, pinned, prefix: b.schema) == nil
    assert %PrintOverride{} = Repo.get(PrintOverride, pinned, prefix: a.schema)
  end

  test "L1 a later retire or activation never changes an issued version", %{a: a} do
    first = active!(a, "FIRST-LAYOUT")
    doc = issued!(a)
    assert {:ok, _} = attach(a, doc)
    before = row(a, doc)
    bytes = pdf!(a, doc)

    retire!(a, first)
    second = active!(a, "SECOND-LAYOUT")

    assert row(a, doc) == before
    assert pdf!(a, doc) == bytes
    assert {:ok, %{version: %{artefact_hash: hash}}} = attach(a, doc)
    assert hash == hd(before)
    assert "FIRST-LAYOUT" in PdfProbe.items(bytes)

    {id, _} = doc

    assert {:ok, _} =
             Documents.new_version_from_current(a.schema, %{document_id: id, actor_id: @actor})

    {:ok, %{version: v2}} = Documents.issue(a.schema, %{document_id: id, actor_id: @actor})
    assert v2.print_override_id == second.id
    assert v2.template_version == "print-layout-v1"
  end

  test "U1 a pending version prints the pinned override, not the one active at attach", %{a: a} do
    first = active!(a, "PINNED-LAYOUT")
    doc = issued!(a)
    retire!(a, first)
    active!(a, "NEWER-LAYOUT")

    assert {:ok, _} = attach(a, doc)
    items = PdfProbe.items(pdf!(a, doc))
    assert "PINNED-LAYOUT" in items
    refute "NEWER-LAYOUT" in items
  end

  test "U2 a restriction added before attach gives render_failed and writes nothing", %{a: a} do
    active!(a, "LAYOUT")
    doc = issued!(a)
    add_restriction!(a)

    assert {:error, :render_failed} = attach(a, doc)
    assert [nil, _, _, _, _] = row(a, doc)
  end

  test "U3 a pin whose row hash differs from the stored one fails closed", %{a: a} do
    row = active!(a, "LAYOUT")
    doc = issued!(a)
    {id, no} = doc

    # the guard refuses a column change on an issued row, so forge the mismatch on the override side
    exec!(
      "ALTER TABLE #{table(a.schema, "document_print_overrides")} DISABLE TRIGGER document_print_overrides_guard_update"
    )

    exec!(
      "UPDATE #{table(a.schema, "document_print_overrides")} SET layout_hash = $2 WHERE id = $1::uuid",
      [row.id, String.duplicate("e", 64)]
    )

    exec!(
      "ALTER TABLE #{table(a.schema, "document_print_overrides")} ENABLE ALWAYS TRIGGER document_print_overrides_guard_update"
    )

    assert {:error, :render_failed} =
             Documents.attach_artefact(a.schema, %{
               document_id: id,
               version_no: no,
               actor_id: @actor
             })
  end

  test "PJ1 an undeclared content key and a restricted field never reach the PDF", %{a: a} do
    active!(a, "LAYOUT")
    doc = issued!(a, %{"extra" => %{"x" => @sentinel}})
    assert {:ok, _} = attach(a, doc)
    bytes = pdf!(a, doc)
    items = PdfProbe.items(bytes)
    assert "N-1" in items
    refute Enum.any?(items, &(&1 =~ @sentinel))
    refute bytes =~ @sentinel
  end
end
