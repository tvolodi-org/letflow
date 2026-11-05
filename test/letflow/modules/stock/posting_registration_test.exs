Code.require_file("stock_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.PostingRegistrationTest do
  @moduledoc """
  REQ-713 / GH #3748 criterion 1 (B-REG-1, B-REG-2): the manifest additions (the mark type, the two
  posting write handlers), the two shipped process definitions and their install as module-stamped
  drafts, on a fresh committed tenant. B-REG-3 (the handler's `create/3` of the mark is accepted and the
  record carries the document's org unit) is proved end to end in `posting_test.exs` (B-POST-2).
  Sandbox `:auto`, hence `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Definitions.OwnerStamp
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Stock
  alias Letflow.Modules.Stock.Documents.Posting
  alias Letflow.Repo
  alias Letflow.StockFixture, as: S
  alias Letflow.Support.TokenMintFixture

  @mark_fields ~w(document_id document_type mark org_unit_id reason_code version_no)

  setup do
    ctx = S.setup_oidc!([:a])
    tenant = S.tenant!("stk-preg", ctx.names.a)
    %{tenant: tenant, schema: tenant.schema_name}
  end

  defp source(name) do
    path = Path.join(["priv", "modules", "stock", "entity_definitions", name <> ".json"])
    path |> File.read!() |> Jason.decode!()
  end

  test "B-REG-1 the mark type, the handler specs and the catalog check" do
    m = Stock.manifest()
    assert Catalog.validate(m) == :ok

    mark = source("stock_posting_mark")
    assert mark["fields"] |> Enum.map(& &1["name"]) |> Enum.sort() == @mark_fields
    by_name = Map.new(mark["fields"], &{&1["name"], &1})

    assert by_name["mark"]["type"] == "enum" and
             by_name["mark"]["enum_values"] == ["posted", "reversed"]

    assert by_name["version_no"]["type"] == "integer"
    assert by_name["document_id"]["queried"] and by_name["org_unit_id"]["queried"]
    assert by_name["reason_code"]["required"] != true

    assert mark["constraints"] == [
             %{
               "name" => "uq_stock_posting_mark_doc_mark",
               "type" => "unique",
               "fields" => ["document_id", "mark"]
             }
           ]

    assert [post, reverse] = m.write_handlers
    assert {post.name, reverse.name} == {"post_document", "reverse_document"}

    for spec <- [post, reverse] do
      assert spec.targets == ["stock_posting_mark"]
      assert spec.posts_ledger == "stock"
      assert elem(spec.function, 0) == Letflow.Modules.Stock.Handlers
    end

    base = ~w(document_id document_type mark org_unit_id posting version_no)
    assert post.args |> Map.keys() |> Enum.sort() == base
    assert reverse.args |> Map.keys() |> Enum.sort() == Enum.sort(["reason_code" | base])
    assert Enum.all?(Map.values(post.args) ++ Map.values(reverse.args), & &1.required)
  end

  test "B-REG-2 the pack ships eight definitions (seven one-task), installed as stamped drafts",
       ctx do
    defs =
      File.read!("priv/modules/stock/pack.json") |> Jason.decode!() |> Map.fetch!("definitions")

    assert defs |> Enum.map(& &1["process_key"]) |> Enum.sort() ==
             ~w(stock_handover stock_issue stock_opening stock_receipt stock_return stock_reversal stock_transfer stock_writeoff)

    # stock_opening (REQ-726) has two tasks and is pinned by opening_posting_test.exs
    for %{"graph" => graph} = definition <- defs, definition["process_key"] != "stock_opening" do
      tasks = Enum.filter(graph["nodes"], &(&1["node_type"] == "HUMAN_TASK"))
      assert [%{"attributes" => %{"module_writes" => [line]}}] = tasks
      assert line["module"] == "stock"

      assert line["handler"] ==
               if(definition["process_key"] == "stock_reversal",
                 do: "reverse_document",
                 else: "post_document"
               )
    end

    names = Enum.map(defs, & &1["process_key"])

    rows =
      Repo.all(from(d in ProcessDefinition, where: d.name in ^names),
        prefix: ctx.schema
      )

    assert length(rows) == 8

    for row <- rows do
      assert row.status == :draft
      assert {:ok, %{module_id: "stock"}} = OwnerStamp.from_row(row)
    end

    # activation through the real path passes ModuleWrites with a TENANT_ADMIN activator
    admin = TokenMintFixture.role_holder!(ctx.schema, ["TENANT_ADMIN"])
    activator = Activator.from_auth_context(%{user_id: admin.id, roles: ["TENANT_ADMIN"]}, false)

    for name <- names do
      assert Posting.ensure_active(ctx.schema, name, activator) == :ok
      assert {:ok, %{status: :active}} = Definitions.get_active_by_name(name, prefix: ctx.schema)
      # a second call is a no-op
      assert Posting.ensure_active(ctx.schema, name, nil) == :ok
    end
  end

  test "B-ACT-4 a tenant-made active definition of the same name is not the module's", ctx do
    graph = %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
    }

    admin = TokenMintFixture.role_holder!(ctx.schema, ["TENANT_ADMIN"])
    activator = Activator.from_auth_context(%{user_id: admin.id, roles: ["TENANT_ADMIN"]}, false)

    # the stamped draft keeps its name; a foreign definition of that name is made active first
    draft =
      Repo.one!(from(d in ProcessDefinition, where: d.name == "stock_receipt"),
        prefix: ctx.schema
      )

    {:ok, created} =
      Definitions.create(
        %{name: "stock_receipt", version: "9.9.9", graph: graph, created_by: admin.id},
        prefix: ctx.schema
      )

    id = created.id
    assert {:ok, _} = Definitions.activate(id, prefix: ctx.schema, activator: activator)
    assert id != draft.id
    assert Posting.ensure_active(ctx.schema, "stock_receipt", activator) == :error
  end
end
