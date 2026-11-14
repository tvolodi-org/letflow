defmodule Letflow.Modules.Assets.DocumentsRegistrationTest do
  @moduledoc """
  GH #3891 / #3890 (assets C10), R1: the manifest and the pack of the asset documents, value by value:
  three record types with the org-unit scope declaration, the exact field sets, no price / value /
  number / status / posted_at field, the foreign key of the line, the unique mark rule, two write
  handlers that post to the `assets` ledger, two process definitions with one HUMAN_TASK each and no
  assignee, seven route policies and the document type of the module.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  alias Letflow.Modules.Assets

  @pack Path.join([File.cwd!(), "priv", "modules", "assets", "pack.json"])

  defp pack, do: @pack |> File.read!() |> Jason.decode!()

  defp definition(name) do
    pack()["entity_definitions"]
    |> Enum.find(&(&1["name"] == name))
    |> Map.fetch!("definition_json")
  end

  defp field_names(name), do: definition(name)["fields"] |> Enum.map(& &1["name"])

  test "R1 the manifest declares the three types, scoped by org_unit_id" do
    m = Assets.manifest()
    new = ["assets_commission", "assets_commission_line", "assets_posting_mark"]

    for type <- new do
      assert type in m.manages_entity_types
      assert m.scope_declarations[type] == {:column, "org_unit_id"}
    end
  end

  test "R1 the module version is above 0.5.0 (the version before C10)" do
    assert Version.compare(Assets.manifest().version, "0.5.0") == :gt
  end

  test "R1 two write handlers post to the assets ledger and write only the mark type" do
    handlers = Assets.manifest().write_handlers

    assert Enum.map(handlers, & &1.name) == [
             "post_document",
             "reverse_document",
             "post_kind_change"
           ]

    for h <- Enum.take(handlers, 2) do
      assert h.posts_ledger == "assets"
      # G2 (T-1489): the card is also a target, updated on its org unit field only
      assert h.targets == ["assets_posting_mark", "assets_card"]
      assert h.updates == %{"assets_card" => ["org_unit_id"]}
      assert {Letflow.Modules.Assets.Handlers, fun} = h.function
      assert fun == String.to_existing_atom(h.name)
    end

    [post, reverse | _] = handlers

    assert post.args |> Map.keys() |> Enum.sort() ==
             ~w(document_id document_type mark org_unit_id posting version_no)

    assert Map.keys(reverse.args) -- Map.keys(post.args) == ["reason_code"]
  end

  test "R1 nine document route policies (incl. print, T-1915), no new permission atom" do
    m = Assets.manifest()

    docs =
      Enum.filter(m.route_policies, fn {_, path, _} -> String.starts_with?(path, "/documents") end)

    assert length(docs) == 9

    assert Enum.uniq(for {_, _, perm} <- docs, do: perm) |> Enum.sort() == [
             :AssetsPost,
             :AssetsRead,
             :AssetsReverse
           ]

    assert m.permissions ==
             [:AssetsCardWrite, :AssetsPost, :AssetsReverse, :AssetsRead, :AssetsReconcile]
  end

  test "R1 the exact field sets, and no price, value, number, status or posted_at field" do
    assert field_names("assets_commission") ==
             ~w(document_id event_time org_unit_id location_id material_responsible_id actual_user_id note)

    assert field_names("assets_commission_line") ==
             ~w(header_id org_unit_id line_no asset_id quantity)

    assert field_names("assets_posting_mark") ==
             ~w(document_id document_type version_no mark org_unit_id reason_code)

    forbidden = ~r/price|value|cost|number|status|posted_at/

    for type <- ["assets_commission", "assets_commission_line"] do
      refute Enum.any?(field_names(type), &Regex.match?(forbidden, &1))
    end
  end

  test "R1 the line quantity is a strict decimal, the line has a foreign key to its header" do
    line = definition("assets_commission_line")
    qty = Enum.find(line["fields"], &(&1["name"] == "quantity"))
    assert %{"decimal_precision" => 24, "decimal_scale" => 9, "decimal_strict" => true} = qty

    assert [%{"field" => "header_id", "references_entity" => "assets_commission"} = fk] =
             line["foreign_keys"]

    assert fk["name"] == "fk_assets_commission_line_header_id"
  end

  test "R1 the mark type allows one posted and one reversed mark per document" do
    assert [
             %{
               "name" => "uq_assets_posting_mark_doc_mark",
               "type" => "unique",
               "fields" => fields
             }
           ] =
             definition("assets_posting_mark")["constraints"]

    assert fields == ["document_id", "mark"]
  end

  test "R1 two process definitions, one HUMAN_TASK each, no assignee, bound to the handlers" do
    defs = pack()["definitions"]

    assert Enum.map(defs, & &1["process_key"]) == [
             "assets_commission",
             "assets_reversal",
             "assets_change",
             "assets_handover",
             "assets_writeoff",
             "assets_kind_change",
             "assets_opening"
           ]

    for {d, node, handler} <- [
          {Enum.at(defs, 0), "post", "post_document"},
          {Enum.at(defs, 1), "reverse", "reverse_document"}
        ] do
      tasks = Enum.filter(d["graph"]["nodes"], &(&1["node_type"] == "HUMAN_TASK"))
      assert [%{"id" => ^node, "attributes" => attrs}] = tasks
      refute Map.has_key?(attrs, "assignee")
      assert [%{"module" => "assets", "handler" => ^handler}] = attrs["module_writes"]
    end
  end

  test "R1 the commission document type: prefix ACM, yearly, pad 6, owned by assets" do
    assert [type | _kinds] = Assets.document_types()
    assert type.key == "assets_commission" and type.owner_module == "assets"
    assert {type.number_prefix, type.number_pad, type.numbering_scope} == {"ACM", 6, :year}
    refute type.legal_entity_required
  end

  test "the entry file keeps no Repo alias (handler_writes scan) and settings moved" do
    source = File.read!("lib/letflow/modules/assets/assets.ex")
    refute source =~ ~r/alias Letflow\.Repo/
    assert function_exported?(Letflow.Modules.Assets.Settings, :currency, 1)

    assert function_exported?(Assets, :currency, 1) and
             function_exported?(Assets, :expiry_lead_days, 1)
  end
end
