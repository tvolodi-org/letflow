Code.require_file("posting_fixture.exs", __DIR__)
Code.require_file("two_side_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.MasterPostingTest do
  @moduledoc """
  REQ-832 / GH #4535 (ledger slice L7 part 1): master checks at posting.
  Criteria 1..9 of the requirement. Committed tenants, Sandbox `:auto`, `async: false`.
  REQ-904 / GH #4818 (L7 part 2d) adds MI-RET-1..6, MI-TRF-1, MI-TYP-1..4, MI-FROM-1..2, MI-AUTH-1, MI-MAN-1:
  a retired master on a stock-adding side is 409 `master_inactive`; every other refusal stays 422.
  Tests MP-REG-1, MP-TYP-1..7, MP-RET-1..6, MP-RET-5b, MP-FROM-1..2, MP-TRF-1..2,
  MP-CD-1..4, MP-REV-1..2, MP-DED-1, MP-ISO-1.
  """

  use Letflow.DataCase, async: false

  @moduletag timeout: 300_000

  alias Letflow.CatalogItemsFixture, as: Cat
  alias Letflow.Entities.Record.Latest
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Org
  alias Letflow.Modules.Stock
  alias Letflow.Repo
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S
  alias Letflow.StockPostingFixture, as: P
  alias Letflow.StockTwoSideFixture, as: T
  alias Letflow.Support.PlatformTenantFixture, as: Fixture

  setup do
    P.setup!([:a, :b])
  end

  defp opts, do: %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}

  # -- helpers ------------------------------------------------------------------------------------

  defp assert_refused(ctx, id) do
    counts = P.counts(ctx, id)
    assert counts.entries == %{}, "expected no ledger entries, got #{inspect(counts.entries)}"
    assert counts.marks == 0
    assert P.pending_task(ctx, id, "post") != nil, "post task expected to stay pending"
  end

  defp get_instance!(ctx, task) do
    Repo.get!(InstanceProjection, task.instance_id, prefix: ctx.schema)
  end

  defp get_record!(schema, record_id, entity_type) do
    Repo.get_by!(Latest, [record_id: record_id, entity_type: entity_type], prefix: schema)
  end

  defp retire_item!(schema, item_id) do
    r = get_record!(schema, item_id, "catalog_item")
    Cat.update!(schema, r, Map.put(r.field_values, "active", false))
  end

  defp retire_uom!(schema, uom_id) do
    r = get_record!(schema, uom_id, "catalog_uom")
    Cat.update!(schema, r, Map.put(r.field_values, "active", false))
  end

  # The captured SELECTs on entity_record_latest whose bound parameters carry `id` (as text or dumped).
  defp latest_reads(queries, id) do
    {:ok, dumped} = Ecto.UUID.dump(id)

    Enum.filter(queries, fn q ->
      params = List.wrap(q[:params])

      String.contains?(q[:query] || "", "entity_record_latest") and
        (id in params or dumped in params)
    end)
  end

  defp no_balance_for_sku!(ctx, sku) do
    rows = S.get("/balances?sku=#{sku}", ctx.tok_a) |> P.status!(200) |> Map.fetch!("rows")
    assert rows == [], "expected no balance for sku #{sku}"
  end

  defp posting_with(instance, field, value) do
    posting = instance.variables["posting"]
    lines = List.update_at(posting["lines"], 0, &Map.put(&1, field, value))
    %{"posting" => Map.put(posting, "lines", lines)}
  end

  defp posting_with_nested(instance, side_key, field, value) do
    posting = instance.variables["posting"]

    lines =
      List.update_at(posting["lines"], 0, fn l ->
        side = l[side_key] || %{}
        Map.put(l, side_key, Map.put(side, field, value))
      end)

    %{"posting" => Map.put(posting, "lines", lines)}
  end

  defp one_line_body(ctx) do
    D.body(ctx.ma, nil, %{
      "lines" => [
        %{"catalog_item_id" => ctx.ma.item, "catalog_uom_id" => ctx.ma.uom, "quantity" => "2"}
      ]
    })
  end

  defp lot_line_body(ctx) do
    D.body(ctx.ma, nil, %{
      "lines" => [
        %{
          "catalog_item_id" => ctx.ma.lot_item,
          "catalog_uom_id" => ctx.ma.uom,
          "catalog_lot_id" => ctx.ma.lot,
          "quantity" => "5"
        }
      ]
    })
  end

  defp writeoff_body(ctx) do
    %{
      "kind" => "write_off",
      "org_unit_id" => ctx.ma.unit,
      "location_id" => ctx.ma.location,
      "responsible_id" => ctx.ma.employee,
      "event_time" => DateTime.to_iso8601(DateTime.utc_now()),
      "reason_code" => "damaged",
      "note" => "test write off",
      "lines" => [
        %{"catalog_item_id" => ctx.ma.item, "catalog_uom_id" => ctx.ma.uom, "quantity" => "1"}
      ]
    }
  end

  # -- criterion 1: manifest declaration ---------------------------------------------------------

  test "MP-REG-1 handlers declare the right reads, reverse_document none, catalog validates, version > 0.17.0" do
    m = Stock.manifest()
    assert Catalog.validate(m) == :ok

    reads = ~w(catalog_item catalog_uom catalog_lot location_node org_unit org_employee)

    post = Enum.find(m.write_handlers, &(&1.name == "post_document"))
    count = Enum.find(m.write_handlers, &(&1.name == "post_count"))
    kind_out = Enum.find(m.write_handlers, &(&1.name == "post_kind_change_out"))
    reverse = Enum.find(m.write_handlers, &(&1.name == "reverse_document"))

    assert Enum.sort(post.reads) == Enum.sort(reads)
    assert Enum.sort(count.reads) == Enum.sort(reads)
    assert Enum.sort(kind_out.reads) == Enum.sort(reads)
    assert reverse.reads == []

    [major, minor, patch] =
      m.version |> String.split(".") |> Enum.map(&String.to_integer/1)

    assert {major, minor, patch} > {0, 17, 0}
  end

  # -- criterion 2: typo refused -----------------------------------------------------------------

  describe "MP-TYP typo refused (criterion 2)" do
    test "MP-TYP-1 unknown uuid as sku is refused, no entry, no mark, task stays pending", ctx do
      doc = P.issue!(ctx)
      id = doc["id"]
      bad_sku = Ecto.UUID.generate()
      task = P.pending_task(ctx, id, "post")
      output = posting_with(get_instance!(ctx, task), "sku", bad_sku)
      assert {:error, _} = P.complete(ctx, task, variables: output)
      assert_refused(ctx, id)
      no_balance_for_sku!(ctx, bad_sku)
    end

    test "MP-TYP-2 unknown uuid as unit is refused", ctx do
      doc = P.issue!(ctx, one_line_body(ctx))
      id = doc["id"]
      task = P.pending_task(ctx, id, "post")
      output = posting_with(get_instance!(ctx, task), "unit", Ecto.UUID.generate())
      assert {:error, _} = P.complete(ctx, task, variables: output)
      assert_refused(ctx, id)
    end

    test "MP-TYP-3 unknown uuid as lot is refused", ctx do
      doc = P.issue!(ctx, lot_line_body(ctx))
      id = doc["id"]
      task = P.pending_task(ctx, id, "post")
      output = posting_with(get_instance!(ctx, task), "lot", Ecto.UUID.generate())
      assert {:error, _} = P.complete(ctx, task, variables: output)
      assert_refused(ctx, id)
    end

    test "MP-TYP-4 unknown uuid as to.location is refused", ctx do
      doc = P.issue!(ctx, one_line_body(ctx))
      id = doc["id"]
      task = P.pending_task(ctx, id, "post")

      output =
        posting_with_nested(get_instance!(ctx, task), "to", "location", Ecto.UUID.generate())

      assert {:error, _} = P.complete(ctx, task, variables: output)
      assert_refused(ctx, id)
    end

    test "MP-TYP-5 non-uuid sku is refused", ctx do
      doc = P.issue!(ctx, one_line_body(ctx))
      id = doc["id"]
      task = P.pending_task(ctx, id, "post")
      output = posting_with(get_instance!(ctx, task), "sku", "not-a-uuid")
      assert {:error, _} = P.complete(ctx, task, variables: output)
      assert_refused(ctx, id)
    end

    test "MP-TYP-6 id of a live location_node given as sku is refused, no balance for it", ctx do
      doc = P.issue!(ctx, one_line_body(ctx))
      id = doc["id"]
      task = P.pending_task(ctx, id, "post")
      output = posting_with(get_instance!(ctx, task), "sku", ctx.ma.location)
      assert {:error, _} = P.complete(ctx, task, variables: output)
      assert_refused(ctx, id)
      no_balance_for_sku!(ctx, ctx.ma.location)
    end

    test "MP-TYP-7 a lot of another item is refused", ctx do
      n = System.unique_integer([:positive])
      item2 = Cat.item!(ctx.schema, "MP-I2-#{n}", ctx.ma.uom)
      lot2 = Cat.lot!(ctx.schema, item2.record_id, "MP-L2-#{n}")

      doc = P.issue!(ctx, lot_line_body(ctx))
      id = doc["id"]
      task = P.pending_task(ctx, id, "post")
      output = posting_with(get_instance!(ctx, task), "lot", lot2.record_id)
      assert {:error, _} = P.complete(ctx, task, variables: output)
      assert_refused(ctx, id)
    end
  end

  # -- criterion 3: retired master on an adding side ---------------------------------------------

  describe "MP-RET retired master on an adding side (criterion 3)" do
    test "MP-RET-1 retired item is refused", ctx do
      doc = P.issue!(ctx, one_line_body(ctx))
      id = doc["id"]
      retire_item!(ctx.schema, ctx.ma.item)
      assert {:error, _} = P.complete(ctx, P.pending_task(ctx, id, "post"))
      assert_refused(ctx, id)
    end

    test "MP-RET-2 retired unit is refused", ctx do
      doc = P.issue!(ctx, one_line_body(ctx))
      id = doc["id"]
      retire_uom!(ctx.schema, ctx.ma.uom)
      assert {:error, _} = P.complete(ctx, P.pending_task(ctx, id, "post"))
      assert_refused(ctx, id)
    end

    test "MP-RET-3 retired lot is refused", ctx do
      doc = P.issue!(ctx, lot_line_body(ctx))
      id = doc["id"]
      {:ok, _} = CatalogItems.retire_lot(ctx.schema, ctx.ma.lot, opts())
      assert {:error, _} = P.complete(ctx, P.pending_task(ctx, id, "post"))
      assert_refused(ctx, id)
    end

    test "MP-RET-4 retired to location is refused", ctx do
      doc = P.issue!(ctx, one_line_body(ctx))
      id = doc["id"]
      {:ok, _} = Locations.retire_node(ctx.schema, ctx.ma.location, opts())
      assert {:error, _} = P.complete(ctx, P.pending_task(ctx, id, "post"))
      assert_refused(ctx, id)
    end

    test "MP-RET-5 retired org_unit is refused", ctx do
      # a unit with no staff can be retired; the posting variable names it (a completer may change it)
      unit2 = D.unit!(ctx.schema)
      {:ok, _} = Org.retire_unit(ctx.schema, unit2, opts())
      doc = P.issue!(ctx, one_line_body(ctx))
      id = doc["id"]
      task = P.pending_task(ctx, id, "post")
      output = posting_with_nested(get_instance!(ctx, task), "to", "org_unit", unit2)
      assert {:error, _} = P.complete(ctx, task, variables: output)
      assert_refused(ctx, id)
    end

    test "MP-RET-5b the unit of the document retired after issue is refused", ctx do
      doc = P.issue!(ctx, one_line_body(ctx))
      id = doc["id"]
      {:ok, _} = Org.retire_employee(ctx.schema, ctx.ma.employee, opts())
      {:ok, _} = Org.retire_unit(ctx.schema, ctx.ma.unit, opts())
      assert {:error, _} = P.complete(ctx, P.pending_task(ctx, id, "post"))
      assert_refused(ctx, id)
    end

    test "MP-RET-6 retired responsible is refused", ctx do
      doc = P.issue!(ctx, one_line_body(ctx))
      id = doc["id"]
      {:ok, _} = Org.retire_employee(ctx.schema, ctx.ma.employee, opts())
      assert {:error, _} = P.complete(ctx, P.pending_task(ctx, id, "post"))
      assert_refused(ctx, id)
    end
  end

  # -- criterion 4: retired master on a removing side --------------------------------------------

  describe "MP-FROM retired master on a removing side (criterion 4)" do
    test "MP-FROM-1 retired item and from-location: write_off posts (live-only check)", ctx do
      receipt = P.issue!(ctx, one_line_body(ctx))
      P.post_and_complete!(ctx, receipt["id"])

      wof = P.issue!(ctx, writeoff_body(ctx))
      wof_id = wof["id"]

      retire_item!(ctx.schema, ctx.ma.item)
      {:ok, _} = Locations.retire_node(ctx.schema, ctx.ma.location, opts())

      assert {:ok, _} = P.complete(ctx, P.pending_task(ctx, wof_id, "post"))
      counts = P.counts(ctx, wof_id)
      assert Map.has_key?(counts.entries, "write_off")
      assert counts.marks == 1
    end

    test "MP-FROM-2 unknown uuid as from.location in replaced posting is refused", ctx do
      receipt = P.issue!(ctx, one_line_body(ctx))
      P.post_and_complete!(ctx, receipt["id"])

      wof = P.issue!(ctx, writeoff_body(ctx))
      wof_id = wof["id"]
      task = P.pending_task(ctx, wof_id, "post")

      output =
        posting_with_nested(get_instance!(ctx, task), "from", "location", Ecto.UUID.generate())

      assert {:error, _} = P.complete(ctx, task, variables: output)
      assert_refused(ctx, wof_id)
    end
  end

  # -- criterion 5: transfer --------------------------------------------------------------------

  describe "MP-TRF transfer (criterion 5)" do
    setup ctx do
      Map.put(ctx, :m2, T.b2!(ctx))
    end

    test "MP-TRF-1 retired to-location: transfer refused", ctx do
      T.receive!(ctx, ctx.ma, "5")
      body = T.body("transfer", ctx.ma, ctx.ma, ctx.m2, %{"lines" => T.plain(ctx.ma, "3")})
      doc = T.issue!(ctx, body)
      {:ok, _} = Locations.retire_node(ctx.schema, ctx.m2.location, opts())
      assert {:error, _} = P.complete(ctx, P.pending_task(ctx, doc["id"], "post"))
      assert_refused(ctx, doc["id"])
    end

    test "MP-TRF-2 retired from-location: transfer posts (from side is live-only check)", ctx do
      T.receive!(ctx, ctx.ma, "5")
      body = T.body("transfer", ctx.ma, ctx.ma, ctx.m2, %{"lines" => T.plain(ctx.ma, "3")})
      doc = T.issue!(ctx, body)
      {:ok, _} = Locations.retire_node(ctx.schema, ctx.ma.location, opts())
      assert {:ok, _} = P.complete(ctx, P.pending_task(ctx, doc["id"], "post"))
      counts = P.counts(ctx, doc["id"])
      assert Map.has_key?(counts.entries, "transfer")
      assert counts.marks == 1
    end
  end

  # -- criterion 7: reversal reads nothing -------------------------------------------------------

  describe "MP-REV reversal reads nothing (criterion 7)" do
    test "MP-REV-1 posted receipt with retired item and location: reversal writes the entry",
         ctx do
      doc = P.issue!(ctx, one_line_body(ctx))
      P.post_and_complete!(ctx, doc["id"])

      retire_item!(ctx.schema, ctx.ma.item)
      {:ok, _} = Locations.retire_node(ctx.schema, ctx.ma.location, opts())

      conn =
        D.request(:post, "/documents/#{doc["id"]}/reverse", ctx.tok_a, %{
          "reason_code" => "wrong_document"
        })

      assert conn.status == 200
      task = P.pending_task(ctx, doc["id"], "reverse")
      assert task != nil
      assert {:ok, _} = P.complete(ctx, task)
      counts = P.counts(ctx, doc["id"])
      assert Map.has_key?(counts.entries, "reversal")
    end

    test "MP-REV-2 no SELECT on entity_record_latest for item/location during reversal", ctx do
      doc = P.issue!(ctx, one_line_body(ctx))
      P.post_and_complete!(ctx, doc["id"])

      retire_item!(ctx.schema, ctx.ma.item)
      {:ok, _} = Locations.retire_node(ctx.schema, ctx.ma.location, opts())

      conn =
        D.request(:post, "/documents/#{doc["id"]}/reverse", ctx.tok_a, %{
          "reason_code" => "wrong_document"
        })

      assert conn.status == 200
      task = P.pending_task(ctx, doc["id"], "reverse")

      {result, queries} =
        Fixture.capture_repo_queries(fn -> P.complete(ctx, task) end)

      assert {:ok, _} = result

      for id <- [ctx.ma.item, ctx.ma.location] do
        assert latest_reads(queries, id) == [], "expected no read of #{id} during the reversal"
      end
    end
  end

  # -- criterion 8: one read per distinct master ------------------------------------------------

  test "MP-DED-1 one read per distinct (type, id) pair per handler call", ctx do
    lines =
      for _ <- 1..5 do
        %{
          "catalog_item_id" => ctx.ma.item,
          "catalog_uom_id" => ctx.ma.uom,
          "quantity" => "1"
        }
      end

    doc = P.issue!(ctx, D.body(ctx.ma, nil, %{"lines" => lines}))
    id = doc["id"]
    task = P.pending_task(ctx, id, "post")

    {result, queries} =
      Fixture.capture_repo_queries(fn -> P.complete(ctx, task) end)

    assert {:ok, _} = result

    for q <- queries, String.contains?(q[:query] || "", "entity_record_latest") do
      refute q[:query] =~ "FOR UPDATE", "unexpected FOR UPDATE: #{q[:query]}"
      refute q[:query] =~ "FOR SHARE", "unexpected FOR SHARE: #{q[:query]}"
    end

    for master_id <- [ctx.ma.item, ctx.ma.uom, ctx.ma.location, ctx.ma.unit, ctx.ma.employee] do
      assert length(latest_reads(queries, master_id)) == 1,
             "expected exactly one read of #{master_id} on entity_record_latest"
    end
  end

  # -- REQ-904: typed master_inactive at posting ---------------------------------------------------

  defp complete_route(task, token, body) do
    conn =
      Plug.Test.conn(:post, "/api/v1/tasks/#{task.id}/complete", Jason.encode!(body))
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    Letflow.Router.call(conn, Letflow.Router.init([]))
  end

  defp strip_trace(body), do: body |> Jason.decode!() |> Map.drop(["trace_id"]) |> Jason.encode!()

  # The completion is refused with the typed 409 and nothing commits; the body names no slot and no id.
  defp assert_inactive(ctx, id, ids) do
    task = P.pending_task(ctx, id, "post")
    conn = complete_route(task, ctx.tok_a, %{})
    assert conn.status == 409, "expected 409, got #{conn.status}: #{conn.resp_body}"
    assert %{"error" => "master_inactive"} = body = Jason.decode!(conn.resp_body)
    refute Map.has_key?(body, "details")

    for master_id <- ids,
        do: refute(conn.resp_body =~ master_id, "the body names #{master_id}")

    assert_refused(ctx, id)
    [entry | _] = Enum.reverse(Fx.audit_rows(ctx.schema, "entity_write.refused"))
    assert entry.after_state["detail"] == "handler_refused"
  end

  # The master record flagged deleted after the document was issued (a master the read facade no longer finds).
  defp soft_delete!(schema, record_id) do
    Repo.query!(
      ~s|UPDATE "#{schema}".entity_record_latest SET deleted = true WHERE record_id = $1|,
      [Ecto.UUID.dump!(record_id)]
    )
  end

  describe "MI-RET REQ-904 criterion 1: retired master on an adding side is 409 master_inactive" do
    test "MI-RET-1 retired item", ctx do
      doc = P.issue!(ctx, one_line_body(ctx))
      retire_item!(ctx.schema, ctx.ma.item)
      assert_inactive(ctx, doc["id"], [ctx.ma.item])
    end

    test "MI-RET-2 retired unit", ctx do
      doc = P.issue!(ctx, one_line_body(ctx))
      retire_uom!(ctx.schema, ctx.ma.uom)
      assert_inactive(ctx, doc["id"], [ctx.ma.uom])
    end

    test "MI-RET-3 retired lot", ctx do
      doc = P.issue!(ctx, lot_line_body(ctx))
      {:ok, _} = CatalogItems.retire_lot(ctx.schema, ctx.ma.lot, opts())
      assert_inactive(ctx, doc["id"], [ctx.ma.lot])
    end

    test "MI-RET-4 retired to location", ctx do
      doc = P.issue!(ctx, one_line_body(ctx))
      {:ok, _} = Locations.retire_node(ctx.schema, ctx.ma.location, opts())
      assert_inactive(ctx, doc["id"], [ctx.ma.location])
    end

    test "MI-RET-5 retired org unit (its staff retired first)", ctx do
      doc = P.issue!(ctx, one_line_body(ctx))
      {:ok, _} = Org.retire_employee(ctx.schema, ctx.ma.employee, opts())
      {:ok, _} = Org.retire_unit(ctx.schema, ctx.ma.unit, opts())
      assert_inactive(ctx, doc["id"], [ctx.ma.unit])
    end

    test "MI-RET-6 retired responsible", ctx do
      doc = P.issue!(ctx, one_line_body(ctx))
      {:ok, _} = Org.retire_employee(ctx.schema, ctx.ma.employee, opts())
      assert_inactive(ctx, doc["id"], [ctx.ma.employee])
    end

    test "MI-RET-7 the same through the engine: the typed refusal rolls back, the task stays pending",
         ctx do
      doc = P.issue!(ctx, one_line_body(ctx))
      retire_item!(ctx.schema, ctx.ma.item)

      assert {:error, {:entity_write_refused, 0, :master_inactive}} =
               P.complete(ctx, P.pending_task(ctx, doc["id"], "post"))

      assert_refused(ctx, doc["id"])
    end
  end

  describe "MI-TRF REQ-904 criterion 1: the to side of a transfer" do
    setup ctx do
      Map.put(ctx, :m2, T.b2!(ctx))
    end

    test "MI-TRF-1 retired to-location of a transfer is 409; the from side stays live-only",
         ctx do
      T.receive!(ctx, ctx.ma, "5")
      body = T.body("transfer", ctx.ma, ctx.ma, ctx.m2, %{"lines" => T.plain(ctx.ma, "3")})
      doc = T.issue!(ctx, body)
      {:ok, _} = Locations.retire_node(ctx.schema, ctx.m2.location, opts())
      assert_inactive(ctx, doc["id"], [ctx.m2.location])
    end
  end

  describe "MI-TYP REQ-904 criterion 2: what is not an inactive live record stays 422" do
    # REQ-903 binds every master id of a posting to the issued legs, so a changed posting variable answers
    # 409 record_version_conflict before the master checks. A master that no longer exists after the issue
    # reaches the checks with the issued legs: that is the path these tests use.
    defp assert_untyped(ctx, id) do
      task = P.pending_task(ctx, id, "post")
      conn = complete_route(task, ctx.tok_a, %{})
      assert conn.status == 422, "expected 422, got #{conn.status}: #{conn.resp_body}"
      refute conn.resp_body =~ "master_inactive"
      assert_refused(ctx, id)
      [entry | _] = Enum.reverse(Fx.audit_rows(ctx.schema, "entity_write.refused"))
      assert entry.after_state["detail"] == "handler_invalid_arguments"
    end

    test "MI-TYP-1 a soft-deleted item", ctx do
      doc = P.issue!(ctx, one_line_body(ctx))
      soft_delete!(ctx.schema, ctx.ma.item)
      assert_untyped(ctx, doc["id"])
    end

    test "MI-TYP-2 a soft-deleted unit", ctx do
      doc = P.issue!(ctx, one_line_body(ctx))
      soft_delete!(ctx.schema, ctx.ma.uom)
      assert_untyped(ctx, doc["id"])
    end

    test "MI-TYP-3 a soft-deleted lot", ctx do
      doc = P.issue!(ctx, lot_line_body(ctx))
      soft_delete!(ctx.schema, ctx.ma.lot)
      assert_untyped(ctx, doc["id"])
    end

    test "MI-TYP-4 a soft-deleted to location", ctx do
      doc = P.issue!(ctx, one_line_body(ctx))
      soft_delete!(ctx.schema, ctx.ma.location)
      assert_untyped(ctx, doc["id"])
    end

    test "MI-TYP-5 a retired item AND a soft-deleted location: the item is checked first (409)",
         ctx do
      doc = P.issue!(ctx, one_line_body(ctx))
      retire_item!(ctx.schema, ctx.ma.item)
      soft_delete!(ctx.schema, ctx.ma.location)
      assert_inactive(ctx, doc["id"], [ctx.ma.item])
    end

    test "MI-TYP-6 a soft-deleted item AND a retired location: the item is checked first (422)",
         ctx do
      doc = P.issue!(ctx, one_line_body(ctx))
      soft_delete!(ctx.schema, ctx.ma.item)
      {:ok, _} = Locations.retire_node(ctx.schema, ctx.ma.location, opts())
      assert_untyped(ctx, doc["id"])
    end
  end

  describe "MI-FROM REQ-904 criterion 3: removing sides and reversals are unchanged" do
    test "MI-FROM-1 retired item and from-location: a write-off still posts", ctx do
      receipt = P.issue!(ctx, one_line_body(ctx))
      P.post_and_complete!(ctx, receipt["id"])
      wof = P.issue!(ctx, writeoff_body(ctx))
      retire_item!(ctx.schema, ctx.ma.item)
      {:ok, _} = Locations.retire_node(ctx.schema, ctx.ma.location, opts())

      conn = complete_route(P.pending_task(ctx, wof["id"], "post"), ctx.tok_a, %{})
      assert conn.status == 200, "expected 200, got #{conn.status}: #{conn.resp_body}"
      assert P.counts(ctx, wof["id"]).marks == 1
    end

    test "MI-FROM-2 a reversal of a posting whose masters were retired still posts", ctx do
      doc = P.issue!(ctx, one_line_body(ctx))
      P.post_and_complete!(ctx, doc["id"])
      retire_item!(ctx.schema, ctx.ma.item)
      {:ok, _} = Locations.retire_node(ctx.schema, ctx.ma.location, opts())

      D.request(:post, "/documents/#{doc["id"]}/reverse", ctx.tok_a, %{
        "reason_code" => "wrong_document"
      })
      |> P.status!(200)

      conn = complete_route(P.pending_task(ctx, doc["id"], "reverse"), ctx.tok_a, %{})
      assert conn.status == 200, "expected 200, got #{conn.status}: #{conn.resp_body}"
      assert Map.has_key?(P.counts(ctx, doc["id"]).entries, "reversal")
    end
  end

  describe "MI-AUTH REQ-904 criterion 4: authority before release" do
    test "MI-AUTH-1 a TASK_WORKER gets the same bytes for a retired item as for an active one",
         ctx do
      worker = S.token(ctx, :a, ["TASK_WORKER"], sub: "mi-worker")

      active_doc = P.issue!(ctx, one_line_body(ctx))
      baseline = complete_route(P.pending_task(ctx, active_doc["id"], "post"), worker, %{})

      retired_doc = P.issue!(ctx, one_line_body(ctx))
      retire_item!(ctx.schema, ctx.ma.item)
      denied = complete_route(P.pending_task(ctx, retired_doc["id"], "post"), worker, %{})

      assert baseline.status in [403, 404], inspect(baseline.status)
      assert denied.status == baseline.status
      refute denied.resp_body =~ "master_inactive"
      assert strip_trace(denied.resp_body) == strip_trace(baseline.resp_body)
      assert_refused(ctx, retired_doc["id"])
    end
  end

  describe "MI-ISO REQ-904 INV-1: another tenant's master state is not revealed" do
    test "MI-ISO-1 a master retired in tenant B and named in A's posting is 422/409 by A's state",
         ctx do
      extra = P.tenant_b!(ctx)
      retire_item!(extra.b.schema_name, extra.mb.item)

      doc = P.issue!(ctx, one_line_body(ctx))
      task = P.pending_task(ctx, doc["id"], "post")
      output = posting_with(get_instance!(ctx, task), "sku", extra.mb.item)
      conn = complete_route(task, ctx.tok_a, output)

      # REQ-903 refuses the changed legs first; either way tenant B's retired state never surfaces as master_inactive
      assert conn.status in [409, 422]
      refute conn.resp_body =~ "master_inactive"
      assert_refused(ctx, doc["id"])
    end
  end

  describe "MI-MAN REQ-904 criterion 5: the manifest is unchanged" do
    test "MI-MAN-1 the stock manifest hash and version equal the pinned values" do
      m = Stock.manifest()
      assert m.version == "0.24.0"
      # the hash on origin/main at implement time (1b05e0a03); REQ-904 changes no declaration
      assert Catalog.manifest_hash("stock") ==
               {:ok, "6ab71e9063c9dd8be544e9c6d32bde9c05e47ea8e0f3da56c4650f9ea438bf59"}
    end
  end

  # -- criterion 9: tenant isolation -------------------------------------------------------------

  test "MP-ISO-1 posting in tenant A with sku from tenant B is refused", ctx do
    extra = P.tenant_b!(ctx)
    b_item = extra.mb.item

    assert Repo.get_by(Latest, [record_id: b_item, entity_type: "catalog_item"],
             prefix: ctx.schema
           ) == nil

    doc = P.issue!(ctx, one_line_body(ctx))
    id = doc["id"]
    task = P.pending_task(ctx, id, "post")
    output = posting_with(get_instance!(ctx, task), "sku", b_item)
    assert {:error, _} = P.complete(ctx, task, variables: output)
    assert_refused(ctx, id)
  end
end
