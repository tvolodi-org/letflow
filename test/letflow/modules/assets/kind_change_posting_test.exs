Code.require_file("kind_change_fixture.exs", __DIR__)
Code.require_file("../stock/stock_fixture.exs", __DIR__)
Code.require_file("../stock/documents_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.KindChangePostingTest do
  @moduledoc """
  GH #3901 / REQ-760 part A (assets C15): posting a change of kind through the REAL HTTP path (rule
  D-098): stock is received through the stock document routes, the change of kind is created and issued
  through the assets document routes, its `post` task is claimed and completed through
  `/api/v1/tasks/:id/claim` and `/complete` with a bearer token.

  P1 the whole path (two cards, one stock entry, one asset entry, both marks, derived `asset_card_id`,
  balances); P2 the cards; B1 insufficient stock, B2 an unauthorised completer, B3 an inventory number
  taken after issue, B4 a second instance, B5 the second line fails: each leaves NOTHING (both or
  neither); P3 `posting_check` detects a changed variable; R3 the reverse route refuses a posted change
  of kind; T1 and T2 tenancy and authority. Committed tenants, Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.AssetsFixture, as: Cards
  alias Letflow.CatalogItemsFixture, as: Cat
  alias Letflow.Engine
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.KindChangeFixture, as: K
  alias Letflow.Modules.Assets.Documents
  alias Letflow.Modules.Assets.Documents.Posting
  alias Letflow.Repo
  alias Letflow.StockDocsFixture, as: SD
  alias Letflow.StockFixture, as: SF
  alias Letflow.Support.TokenMintFixture

  @tag_timeout 300_000

  setup do
    ctx = D.setup!([:a, :b])
    ctx = Map.merge(ctx, D.tenant_b!(ctx))
    {:ok, Map.merge(ctx, %{ka: K.masters!(ctx.schema), kb: K.masters!(ctx.b.schema_name)})}
  end

  # -- helpers ------------------------------------------------------------------------------------

  # Receives `qty` of the item `m.item` at `m.location` through the stock routes (issue, claim, complete).
  defp receive_stock!(schema, token, m, qty) do
    supplier = Cat.counterparty!(schema, "SUP#{System.unique_integer([:positive])}")

    body = %{
      "kind" => "receipt",
      "org_unit_id" => m.unit,
      "location_id" => m.location,
      "responsible_id" => m.employee,
      "event_time" => DateTime.to_iso8601(DateTime.utc_now()),
      "counterparty_id" => supplier.record_id,
      "lines" => [%{"catalog_item_id" => m.item, "catalog_uom_id" => m.uom, "quantity" => qty}]
    }

    doc = SD.request(:post, "/documents", token, body) |> status!(201)
    SD.request(:post, "/documents/#{doc["id"]}/issue", token) |> status!(200)

    task = pending(schema, doc["id"])
    conn = D.claim_and_complete(task, token)
    assert conn.status == 200, conn.resp_body
  end

  defp pending(schema, id) do
    Repo.one!(
      from(t in Letflow.Engine.Task,
        join: p in InstanceProjection,
        on: p.instance_id == t.instance_id,
        where:
          t.status == :pending and t.node_id == "post" and
            fragment("?->>'document_id' = ?", p.variables, ^id)
      ),
      prefix: schema
    )
  end

  defp status!(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    if conn.resp_body == "", do: nil, else: Jason.decode!(conn.resp_body)
  end

  defp qty(leg),
    do: leg["quantity"] |> Decimal.new() |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp two_lines(m) do
    [
      K.line(m, %{"quantity" => "20", "target_kind" => "low_value"}),
      K.line(m, %{"quantity" => "1", "target_kind" => "fixed", "asset_name" => "Server"})
    ]
  end

  defp issue!(ctx, m, lines \\ nil) do
    D.issue!(ctx, K.body(m, %{}, lines || two_lines(m)))
  end

  # What a posting could write: entries of the document, marks of both modules, and all cards.
  defp snapshot(ctx, id) do
    %{rows: entries} =
      Repo.query!(
        ~s|SELECT cause, count(*) FROM "#{ctx.schema}".ledger_entry WHERE document_id = $1 GROUP BY cause|,
        [id]
      )

    %{rows: [[marks]]} =
      Repo.query!(
        ~s|SELECT count(*) FROM "#{ctx.schema}".entity_record_latest WHERE entity_type IN ('assets_posting_mark', 'stock_posting_mark') AND NOT deleted AND field_values->>'document_id' = $1|,
        [id]
      )

    %{rows: [[cards]]} =
      Repo.query!(
        ~s|SELECT count(*) FROM "#{ctx.schema}".entity_record_latest WHERE entity_type = 'assets_card' AND NOT deleted|
      )

    {Enum.sort(entries), marks, cards}
  end

  defp stock_total(_ctx, m, token) do
    rows =
      (SF.get("/balances?sku=#{m.item}", token) |> status!(200))["rows"]

    rows |> Enum.map(&Decimal.new(&1["quantity"])) |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
  end

  defp complete_as(ctx, task, user, output \\ %{}) do
    Engine.complete_task(
      task.id,
      %{output_variables: output, actor_id: user.id, idempotency_key: Ecto.UUID.generate()},
      prefix: ctx.schema,
      credential: :oidc
    )
  end

  defp admin(ctx), do: TokenMintFixture.role_holder!(ctx.schema, ["TENANT_ADMIN"])

  # -- the happy path -----------------------------------------------------------------------------

  @tag timeout: @tag_timeout
  test "P1 D-098: issue, claim and complete over HTTP posts two entries and creates two cards",
       ctx do
    m = ctx.ka
    receive_stock!(ctx.schema, ctx.tok_a, m, "25")
    issued = issue!(ctx, m)
    id = issued["id"]
    assert issued["state"] == "issued" and issued["posting_check"] == nil
    {_none, 0, cards_before} = snapshot(ctx, id)

    posted = D.run_task!(ctx, id)
    assert posted["state"] == "posted" and is_binary(posted["entry_id"])
    assert snapshot(ctx, id) |> elem(0) == [["kind_change_in", 1], ["kind_change_out", 1]]
    assert {_entries, 2, cards_after} = snapshot(ctx, id)
    assert cards_after == cards_before + 2

    # the read as the TENANT_ADMIN: stock readable, so the check runs on both registers
    assert posted["posting_check"] == "ok"

    [asset_entry] = D.movements(ctx, id)
    assert asset_entry["cause"] == "kind_change_in"
    assert asset_entry["document_type"] == "assets_kind_change"
    stock_entry = (SF.get("/movements?document_id=#{id}", ctx.tok_a) |> status!(200))["rows"]
    assert [%{"cause" => "kind_change_out"} = stock_entry] = stock_entry
    assert stock_entry["document_type"] == "assets_kind_change"
    assert stock_entry["document_id"] == id
    assert asset_entry["correlation_id"] == stock_entry["correlation_id"]
    assert is_binary(asset_entry["correlation_id"])

    # two negative stock legs (the uom id is the unit), two positive asset legs at the new cards
    assert stock_entry["legs"] |> Enum.map(&{&1["unit_ref"], qty(&1)}) |> Enum.sort() ==
             Enum.sort([{m.uom, "-20"}, {m.uom, "-1"}])

    assert asset_entry["legs"] |> Enum.map(&{&1["unit_ref"], qty(&1)}) |> Enum.sort() ==
             Enum.sort([{"pcs", "20"}, {"pcs", "1"}])

    card_ids = Enum.map(asset_entry["legs"], & &1["asset"])
    assert length(Enum.uniq(card_ids)) == 2

    # each line's asset_card_id is the card its leg names; the cards exist
    by_line = Map.new(asset_entry["legs"], &{&1["document_line_id"], &1["asset"]})

    for line <- posted["lines"] do
      assert line["asset_card_id"] == by_line[line["line_id"]]
    end

    # stock: 25 received, 21 moved out; assets: 20 and 1 on hand at the new cards
    assert Decimal.equal?(stock_total(ctx, m, ctx.tok_a), Decimal.new(4))

    for line <- posted["lines"] do
      assert [row] = D.balances(ctx, line["asset_card_id"])
      assert Decimal.equal?(Decimal.new(row["quantity"]), Decimal.new(line["quantity"]))
    end
  end

  test "P2 the created cards carry the line values, are active and have no money fields", ctx do
    m = ctx.ka
    receive_stock!(ctx.schema, ctx.tok_a, m, "25")
    lines = two_lines(m)
    posted = D.run_task!(ctx, issue!(ctx, m, lines)["id"])

    for {line, sent} <- Enum.zip(posted["lines"], lines) do
      %{field_values: fv} =
        Repo.one!(
          from(r in Letflow.Entities.Record.Latest,
            where: r.entity_type == "assets_card" and r.record_id == ^line["asset_card_id"]
          ),
          prefix: ctx.schema
        )

      assert fv["inventory_number"] == sent["inventory_number"]
      assert fv["name"] == sent["asset_name"]
      assert fv["kind"] == sent["target_kind"]
      assert fv["org_unit_id"] == m.unit
      assert fv["active"] == true
      refute Map.has_key?(fv, "acquisition_cost") or Map.has_key?(fv, "acquisition_date")
    end
  end

  # -- both or neither ----------------------------------------------------------------------------

  defp assert_nothing(ctx, id, before, task) do
    assert snapshot(ctx, id) == before
    assert Repo.get!(Letflow.Engine.Task, task.id, prefix: ctx.schema).status == :pending
    assert D.get!(ctx, id)["state"] == "issued"
  end

  test "B1 insufficient stock: nothing is committed", ctx do
    m = ctx.ka
    receive_stock!(ctx.schema, ctx.tok_a, m, "10")
    id = issue!(ctx, m)["id"]
    before = snapshot(ctx, id)
    task = pending(ctx.schema, id)

    assert {:error, refusal} = complete_as(ctx, task, admin(ctx))
    assert inspect(refusal) =~ "insufficient"
    assert_nothing(ctx, id, before, task)
    assert Decimal.equal?(stock_total(ctx, m, ctx.tok_a), Decimal.new(10))
  end

  test "B2 a completer who may post stock but not assets is refused: nothing is committed", ctx do
    m = ctx.ka
    receive_stock!(ctx.schema, ctx.tok_a, m, "25")
    id = issue!(ctx, m)["id"]
    before = snapshot(ctx, id)
    task = pending(ctx.schema, id)

    for roles <- [["STOREKEEPER"], ["TASK_WORKER"]] do
      holder = TokenMintFixture.role_holder!(ctx.schema, roles)
      assert {:error, _refusal} = complete_as(ctx, task, holder)
      assert_nothing(ctx, id, before, task)
    end
  end

  test "B3 an inventory number taken after issue: nothing is committed", ctx do
    m = ctx.ka
    receive_stock!(ctx.schema, ctx.tok_a, m, "25")
    lines = two_lines(m)
    id = issue!(ctx, m, lines)["id"]

    Cards.card!(ctx.schema, List.last(lines)["inventory_number"], %{
      "kind" => "fixed",
      "org_unit_id" => m.unit
    })

    before = snapshot(ctx, id)
    task = pending(ctx.schema, id)

    assert {:error, _refusal} = complete_as(ctx, task, admin(ctx))
    assert_nothing(ctx, id, before, task)
  end

  test "B4 a second instance with the same variables writes nothing more", ctx do
    m = ctx.ka
    receive_stock!(ctx.schema, ctx.tok_a, m, "60")
    id = issue!(ctx, m)["id"]
    {:ok, view} = Documents.fetch(ctx.schema, id)
    version = Posting.issued(ctx.schema, id)
    assert {:ok, _second} = Posting.start_post(ctx.schema, view, version, Ecto.UUID.generate())

    {_none, 0, cards_before} = snapshot(ctx, id)
    D.run_task!(ctx, id)
    after_first = snapshot(ctx, id)
    assert {_entries, 2, cards_after} = after_first
    assert cards_after == cards_before + 2

    other = pending(ctx.schema, id)

    assert {:error, _refusal} = complete_as(ctx, other, admin(ctx))
    assert snapshot(ctx, id) == after_first
    assert Decimal.equal?(stock_total(ctx, m, ctx.tok_a), Decimal.new(39))
  end

  test "B5 the second line fails: the first line's card is not created either", ctx do
    m = ctx.ka
    receive_stock!(ctx.schema, ctx.tok_a, m, "20")

    lines = [
      K.line(m, %{"quantity" => "15"}),
      K.line(m, %{"quantity" => "10", "asset_name" => "Second"})
    ]

    id = issue!(ctx, m, lines)["id"]
    before = snapshot(ctx, id)
    task = pending(ctx.schema, id)

    assert {:error, _refusal} = complete_as(ctx, task, admin(ctx))
    assert_nothing(ctx, id, before, task)
  end

  # -- binding detection, reverse, tenancy ----------------------------------------------------------

  test "P3 posting_check reads mismatch when the posting variable names another inventory number",
       ctx do
    m = ctx.ka
    receive_stock!(ctx.schema, ctx.tok_a, m, "25")
    id = issue!(ctx, m)["id"]
    task = pending(ctx.schema, id)
    instance = Repo.get!(InstanceProjection, task.instance_id, prefix: ctx.schema)
    posting = instance.variables["posting"]

    lines =
      List.update_at(
        posting["lines"],
        0,
        &Map.put(&1, "inventory_number", "FORGED-#{&1["quantity"]}")
      )

    assert {:ok, _} =
             complete_as(ctx, task, admin(ctx), %{"posting" => Map.put(posting, "lines", lines)})

    read = D.get!(ctx, id)
    assert read["state"] == "posted" and read["posting_check"] == "mismatch"
  end

  test "R3 reverse of a posted change of kind is 409 posting_inconsistent; nothing changes",
       ctx do
    m = ctx.ka
    receive_stock!(ctx.schema, ctx.tok_a, m, "25")
    id = issue!(ctx, m)["id"]
    posted = D.run_task!(ctx, id)
    before = snapshot(ctx, id)

    conn =
      D.request(:post, "/documents/#{id}/reverse", ctx.tok_a, %{"reason_code" => "wrong_document"})

    assert status!(conn, 409)["reason"] == "posting_inconsistent"
    assert snapshot(ctx, id) == before
    assert D.get!(ctx, id) == posted
    assert D.pending_task(ctx, id, "reverse") == nil
  end

  test "T1 tenant B sees nothing of tenant A's posted change of kind (INV-1, INV-5)", ctx do
    m = ctx.ka
    receive_stock!(ctx.schema, ctx.tok_a, m, "25")
    id = issue!(ctx, m)["id"]
    posted = D.run_task!(ctx, id)

    assert D.request(:get, "/documents/#{id}", ctx.tok_b) |> status!(404)

    for {path, body} <- [{"/issue", nil}, {"/reverse", %{"reason_code" => "wrong_document"}}] do
      assert D.request(:post, "/documents/#{id}" <> path, ctx.tok_b, body) |> status!(404)
    end

    assert (SF.get("/movements?document_id=#{id}", ctx.tok_b) |> status!(200))["rows"] == []

    assert (Letflow.AssetsRegisterFixture.get("/movements?document_id=#{id}", ctx.tok_b)
            |> status!(200))["rows"] == []

    assert Decimal.equal?(stock_total(ctx, ctx.kb, ctx.tok_b), Decimal.new(0))
    assert D.get!(ctx, id) == posted
  end

  test "T2 a task worker cannot issue or reverse; the document is unchanged", ctx do
    m = ctx.ka
    receive_stock!(ctx.schema, ctx.tok_a, m, "25")
    draft = D.save!(ctx, K.body(m, %{}, two_lines(m)))
    worker = Letflow.AssetsRegisterFixture.token(ctx, :a, ["TASK_WORKER"], sub: "worker-kc")

    for path <- ["/issue", "/reverse"] do
      conn =
        D.request(:post, "/documents/#{draft["id"]}" <> path, worker, %{"reason_code" => "other"})

      assert conn.status == 403, "got #{conn.status}"
    end

    assert D.get!(ctx, draft["id"])["state"] == "draft"
  end
end
