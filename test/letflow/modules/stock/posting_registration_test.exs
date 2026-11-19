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

    # REQ-718 added `post_count` (same arguments as `post_document`)
    # REQ-760 added `post_kind_change_out` (same arguments again)
    assert [post, reverse, count, kind_out] = m.write_handlers

    assert {post.name, reverse.name, count.name, kind_out.name} ==
             {"post_document", "reverse_document", "post_count", "post_kind_change_out"}

    assert kind_out.args == post.args

    assert count.args == post.args

    for spec <- [post, reverse, count] do
      assert spec.targets == ["stock_posting_mark"]
      assert spec.posts_ledger == "stock"
      assert elem(spec.function, 0) == Letflow.Modules.Stock.Handlers
    end

    base = ~w(document_id document_type mark org_unit_id posting version_no)
    assert post.args |> Map.keys() |> Enum.sort() == base
    assert reverse.args |> Map.keys() |> Enum.sort() == Enum.sort(["reason_code" | base])
    assert Enum.all?(Map.values(post.args) ++ Map.values(reverse.args), & &1.required)
  end

  test "B-REG-2 the pack ships ten definitions (eight one-task), installed as stamped drafts",
       ctx do
    defs =
      File.read!("priv/modules/stock/pack.json") |> Jason.decode!() |> Map.fetch!("definitions")

    assert defs |> Enum.map(& &1["process_key"]) |> Enum.sort() ==
             ~w(stock_count_posting stock_handover stock_issue stock_opening stock_quick_count stock_receipt stock_return stock_reversal stock_transfer stock_writeoff)

    # stock_opening (REQ-726) has two tasks and is pinned by opening_posting_test.exs
    for %{"graph" => graph} = definition <- defs,
        definition["process_key"] not in ["stock_opening", "stock_quick_count"] do
      tasks = Enum.filter(graph["nodes"], &(&1["node_type"] == "HUMAN_TASK"))
      assert [%{"attributes" => %{"module_writes" => [line]}}] = tasks
      assert line["module"] == "stock"

      expected =
        case definition["process_key"] do
          "stock_reversal" -> "reverse_document"
          "stock_count_posting" -> "post_count"
          _ -> "post_document"
        end

      assert line["handler"] == expected
    end

    names = Enum.map(defs, & &1["process_key"])

    rows =
      Repo.all(from(d in ProcessDefinition, where: d.name in ^names),
        prefix: ctx.schema
      )

    assert length(rows) == 10

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

  @tag timeout: 30_000
  test "SYS-1 unmodified stock drafts activate without caller authority, once and audited", ctx do
    names =
      ~w(stock_receipt stock_issue stock_transfer stock_return stock_handover stock_writeoff stock_reversal stock_count_posting stock_opening stock_quick_count)

    for name <- names do
      caller =
        if name == "stock_receipt",
          do: nil,
          else: %{permissions: [], entities_records_write?: true}

      assert :ok = Posting.ensure_active(ctx.schema, name, caller)
      assert {:ok, row} = Definitions.get_active_by_name(name, prefix: ctx.schema)
      assert is_map(row.activated_by["signature"])
      assert row.activated_by["roles"] == []

      assert {:ok, user} =
               Letflow.Identity.get_user(row.activated_by["user_id"], prefix: ctx.schema)

      assert user.auth_source == :internal
      assert user.password_hash == "__NO_PASSWORD_SET__"
      assert Letflow.Identity.list_effective_role_names(user.id, prefix: ctx.schema) == []
      assert :ok = Posting.ensure_active(ctx.schema, name, nil)
      assert {:ok, ^row} = Definitions.get_active_by_name(name, prefix: ctx.schema)

      assert Repo.aggregate(
               from(a in Letflow.Audit.Entry,
                 where: a.action == "definition.activate" and a.resource_id == ^row.id
               ),
               :count,
               prefix: ctx.schema
             ) == 1
    end

    assert Repo.aggregate(
             from(a in Letflow.Audit.Entry,
               where: a.action == "stock.process_activator_created"
             ),
             :count,
             prefix: ctx.schema
           ) == 1
  end

  test "SYS-2 a tenant-created draft blocks automatic activation of the shipped draft", ctx do
    graph = %{
      "nodes" => [%{"id" => "s", "node_type" => "START"}, %{"id" => "e", "node_type" => "END"}],
      "edges" => [%{"id" => "edge", "source" => "s", "target" => "e"}]
    }

    assert {:ok, custom} =
             Definitions.create(
               %{
                 name: "stock_receipt",
                 version: "9.0.0",
                 graph: graph,
                 created_by: Ecto.UUID.generate()
               },
               prefix: ctx.schema
             )

    assert Posting.ensure_active(ctx.schema, "stock_receipt", nil) == :error
    admin = TokenMintFixture.role_holder!(ctx.schema, ["TENANT_ADMIN"])
    authority = Activator.from_auth_context(%{user_id: admin.id, roles: ["TENANT_ADMIN"]}, false)
    assert Posting.ensure_active(ctx.schema, "stock_receipt", authority) == :error

    assert {:ok, %{status: :draft}} = Definitions.get_by_id(custom.id, prefix: ctx.schema)

    assert Repo.aggregate(
             from(a in Letflow.Audit.Entry, where: a.action == "definition.activate"),
             :count,
             prefix: ctx.schema
           ) == 0
  end

  test "SYS-4 concurrent first use activates only once", ctx do
    tasks =
      for _ <- 1..2,
          do: Task.async(fn -> Posting.ensure_active(ctx.schema, "stock_receipt", nil) end)

    assert Enum.map(tasks, &Task.await(&1, 30_000)) == [:ok, :ok]

    assert Repo.aggregate(
             from(a in Letflow.Audit.Entry, where: a.action == "definition.activate"),
             :count,
             prefix: ctx.schema
           ) == 1
  end

  test "SYS-5 a deactivated internal activator stays inactive", ctx do
    assert :ok = Posting.ensure_active(ctx.schema, "stock_receipt", nil)
    assert {:ok, row} = Definitions.get_active_by_name("stock_receipt", prefix: ctx.schema)
    id = row.activated_by["user_id"]

    Repo.update_all(
      from(u in Letflow.Identity.User, where: u.id == ^id),
      [set: [status: :inactive]],
      prefix: ctx.schema
    )

    assert :error = Posting.ensure_active(ctx.schema, "stock_issue", nil)
    assert {:ok, %{status: :inactive}} = Letflow.Identity.get_user(id, prefix: ctx.schema)

    assert {:error, :not_found} =
             Definitions.get_active_by_name("stock_issue", prefix: ctx.schema)
  end

  test "SYS-6 audit failure rolls back activation and the internal user", ctx do
    users = Repo.aggregate(Letflow.Identity.User, :count, prefix: ctx.schema)

    Repo.query!(
      ~s(ALTER TABLE "#{ctx.schema}".audit_entries RENAME TO activation_audit_unavailable)
    )

    try do
      assert :error = Posting.ensure_active(ctx.schema, "stock_receipt", nil)
    after
      Repo.query!(
        ~s(ALTER TABLE "#{ctx.schema}".activation_audit_unavailable RENAME TO audit_entries)
      )
    end

    assert Repo.aggregate(Letflow.Identity.User, :count, prefix: ctx.schema) == users

    assert {:error, :not_found} =
             Definitions.get_active_by_name("stock_receipt", prefix: ctx.schema)

    assert Repo.aggregate(
             from(a in Letflow.Audit.Entry, where: a.action == "definition.activate"),
             :count,
             prefix: ctx.schema
           ) == 0
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
