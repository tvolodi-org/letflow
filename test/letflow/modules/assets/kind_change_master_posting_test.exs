Code.require_file("kind_change_fixture.exs", __DIR__)
Code.require_file("../stock/stock_fixture.exs", __DIR__)
Code.require_file("../stock/documents_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.KindChangeMasterPostingTest do
  @moduledoc """
  REQ-832 / GH #4535 (ledger slice L7 part 1), criterion 6 (second half): the stock side of a change of
  kind (`post_kind_change_out`, a from side only) checks its masters at posting. The flow is the one of
  `kind_change_posting_test.exs`: stock is received through the stock routes, the change of kind is issued
  through the assets routes and its `post` task is claimed and completed with a bearer token.

  MK-1 an item set to `active false` after the start still posts (a removing side accepts a retired
  master); MK-2 an unknown uuid as the sku of the replaced `stock_posting` variable is refused and BOTH
  sides roll back (no stock entry, no asset entry, no mark, the task stays pending).
  Committed tenants, Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.CatalogItemsFixture, as: Cat
  alias Letflow.Engine
  alias Letflow.Entities.Record.Latest
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.KindChangeFixture, as: K
  alias Letflow.Repo
  alias Letflow.StockDocsFixture, as: SD
  alias Letflow.Support.TokenMintFixture

  setup do
    ctx = D.setup!([:a])
    {:ok, Map.put(ctx, :ka, K.masters!(ctx.schema))}
  end

  defp status!(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    if conn.resp_body == "", do: nil, else: Jason.decode!(conn.resp_body)
  end

  # Receives `qty` of the item `m.item` at `m.location` through the stock routes (issue, claim, complete).
  defp receive_stock!(ctx, m, qty) do
    supplier = Cat.counterparty!(ctx.schema, "SUP#{System.unique_integer([:positive])}")

    body = %{
      "kind" => "receipt",
      "org_unit_id" => m.unit,
      "location_id" => m.location,
      "responsible_id" => m.employee,
      "event_time" => DateTime.to_iso8601(DateTime.utc_now()),
      "counterparty_id" => supplier.record_id,
      "lines" => [%{"catalog_item_id" => m.item, "catalog_uom_id" => m.uom, "quantity" => qty}]
    }

    doc = SD.request(:post, "/documents", ctx.tok_a, body) |> status!(201)
    SD.request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_a) |> status!(200)
    task = pending(ctx, doc["id"])
    conn = D.claim_and_complete(task, ctx.tok_a)
    assert conn.status == 200, conn.resp_body
  end

  defp pending(ctx, id) do
    Repo.one!(
      from(t in Letflow.Engine.Task,
        join: p in InstanceProjection,
        on: p.instance_id == t.instance_id,
        where:
          t.status == :pending and t.node_id == "post" and
            fragment("?->>'document_id' = ?", p.variables, ^id),
        order_by: [desc: t.inserted_at],
        limit: 1
      ),
      prefix: ctx.schema
    )
  end

  defp issue!(ctx, m) do
    line = K.line(m, %{"quantity" => "20", "target_kind" => "low_value"})
    D.issue!(ctx, K.body(m, %{}, [line]))
  end

  defp retire_item!(ctx, item_id) do
    r =
      Repo.get_by!(Latest, [record_id: item_id, entity_type: "catalog_item"], prefix: ctx.schema)

    Cat.update!(ctx.schema, r, Map.put(r.field_values, "active", false))
  end

  # Entries of the document by cause, and the marks of both modules.
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

    {Enum.sort(entries), marks}
  end

  test "MK-1 an item retired after the start: the stock side (from only) still posts", ctx do
    m = ctx.ka
    receive_stock!(ctx, m, "25")
    id = issue!(ctx, m)["id"]
    retire_item!(ctx, m.item)

    posted = D.run_task!(ctx, id)
    assert posted["state"] == "posted"
    assert {[["kind_change_in", 1], ["kind_change_out", 1]], 2} = snapshot(ctx, id)
  end

  test "MK-2 an unknown uuid as sku of the stock posting is refused, both sides roll back", ctx do
    m = ctx.ka
    receive_stock!(ctx, m, "25")
    id = issue!(ctx, m)["id"]
    task = D.pending_task(ctx, id, "post")
    instance = Repo.get!(InstanceProjection, task.instance_id, prefix: ctx.schema)
    stock_posting = instance.variables["stock_posting"]
    assert is_map(stock_posting) and stock_posting["lines"] != []

    lines =
      List.update_at(stock_posting["lines"], 0, &Map.put(&1, "sku", Ecto.UUID.generate()))

    output = %{"stock_posting" => Map.put(stock_posting, "lines", lines)}
    holder = TokenMintFixture.role_holder!(ctx.schema, ["TENANT_ADMIN"])

    assert {:error, _} =
             Engine.complete_task(
               task.id,
               %{
                 output_variables: output,
                 actor_id: holder.id,
                 idempotency_key: Ecto.UUID.generate()
               },
               prefix: ctx.schema,
               credential: :oidc
             )

    assert {[], 0} = snapshot(ctx, id)
    assert D.pending_task(ctx, id, "post") != nil
  end
end
