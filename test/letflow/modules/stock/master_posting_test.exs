Code.require_file("posting_fixture.exs", __DIR__)
Code.require_file("two_side_fixture.exs", __DIR__)
Code.require_file("counts_fixture.exs", __DIR__)
Code.require_file("../assets/kind_change_fixture.exs", __DIR__)
Code.require_file("../assets/documents_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.MasterPostingTest do
  @moduledoc """
  REQ-832 / GH #4535 (ledger slice L7 part 1): master checks at posting.
  Criteria 1..9 of the requirement. Committed tenants, Sandbox `:auto`, `async: false`.
  Tests MP-REG-1, MP-TYP-1..7, MP-RET-1..6, MP-FROM-1..2, MP-TRF-1..2,
  MP-CD-1..4, MP-REV-1..2, MP-DED-1, MP-ISO-1.
  """

  use Letflow.DataCase, async: false

  @moduletag timeout: 300_000

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.CatalogItemsFixture, as: Cat
  alias Letflow.CountsFixture, as: CF
  alias Letflow.Engine
  alias Letflow.Entities.Record.Latest
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Identity.User
  alias Letflow.KindChangeFixture, as: KC
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.Installs
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Org
  alias Letflow.Modules.Stock
  alias Letflow.Repo
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S
  alias Letflow.StockPostingFixture, as: P
  alias Letflow.StockTwoSideFixture, as: T
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.TokenMintFixture

  setup do
    P.setup!()
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
      "reason_code" => "damage",
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
      assert {:error, _} = P.complete(ctx, task, output: output)
      assert_refused(ctx, id)
      no_balance_for_sku!(ctx, bad_sku)
    end

    test "MP-TYP-2 unknown uuid as unit is refused", ctx do
      doc = P.issue!(ctx, one_line_body(ctx))
      id = doc["id"]
      task = P.pending_task(ctx, id, "post")
      output = posting_with(get_instance!(ctx, task), "unit", Ecto.UUID.generate())
      assert {:error, _} = P.complete(ctx, task, output: output)
      assert_refused(ctx, id)
    end

    test "MP-TYP-3 unknown uuid as lot is refused", ctx do
      doc = P.issue!(ctx, lot_line_body(ctx))
      id = doc["id"]
      task = P.pending_task(ctx, id, "post")
      output = posting_with(get_instance!(ctx, task), "lot", Ecto.UUID.generate())
      assert {:error, _} = P.complete(ctx, task, output: output)
      assert_refused(ctx, id)
    end

    test "MP-TYP-4 unknown uuid as to.location is refused", ctx do
      doc = P.issue!(ctx, one_line_body(ctx))
      id = doc["id"]
      task = P.pending_task(ctx, id, "post")
      output = posting_with_nested(get_instance!(ctx, task), "to", "location", Ecto.UUID.generate())
      assert {:error, _} = P.complete(ctx, task, output: output)
      assert_refused(ctx, id)
    end

    test "MP-TYP-5 non-uuid sku is refused", ctx do
      doc = P.issue!(ctx, one_line_body(ctx))
      id = doc["id"]
      task = P.pending_task(ctx, id, "post")
      output = posting_with(get_instance!(ctx, task), "sku", "not-a-uuid")
      assert {:error, _} = P.complete(ctx, task, output: output)
      assert_refused(ctx, id)
    end

    test "MP-TYP-6 id of a live location_node given as sku is refused, no balance for it", ctx do
      doc = P.issue!(ctx, one_line_body(ctx))
      id = doc["id"]
      task = P.pending_task(ctx, id, "post")
      output = posting_with(get_instance!(ctx, task), "sku", ctx.ma.location)
      assert {:error, _} = P.complete(ctx, task, output: output)
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
      assert {:error, _} = P.complete(ctx, task, output: output)
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
      doc = P.issue!(ctx, one_line_body(ctx))
      id = doc["id"]
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
      output = posting_with_nested(get_instance!(ctx, task), "from", "location", Ecto.UUID.generate())
      assert {:error, _} = P.complete(ctx, task, output: output)
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

  # -- criterion 6a: count_difference -----------------------------------------------------------

  describe "MP-CD count_difference (criterion 6a)" do
    setup ctx do
      x = build_count_world!(ctx)
      {:ok, x}
    end

    test "MP-CD-1 surplus item retired after signing: post task is refused", x do
      {count_id, surplus_item} = signed_count_with_surplus!(x)
      count_post!(x, count_id)
      diff_id = get_diff_id!(x, count_id)
      task = P.pending_task(x, diff_id, "post")
      retire_item!(x.schema, surplus_item)
      assert {:error, _} = P.complete(x, task)
      assert P.counts(x, diff_id).entries == %{}
      assert P.pending_task(x, diff_id, "post") != nil
    end

    test "MP-CD-2 shortage item retired after signing: post succeeds (from side only)", x do
      {count_id, shortage_item} = signed_count_with_shortage_only!(x)
      count_post!(x, count_id)
      diff_id = get_diff_id!(x, count_id)
      task = P.pending_task(x, diff_id, "post")
      retire_item!(x.schema, shortage_item)
      assert {:ok, _} = P.complete(x, task)
      counts = P.counts(x, diff_id)
      assert Map.has_key?(counts.entries, "count_difference")
      assert counts.marks == 1
    end
  end

  # -- criterion 6b: kind_change_out ------------------------------------------------------------

  describe "MP-KCO kind_change_out (criterion 6b)" do
    setup ctx do
      kc = build_kind_change_ctx!(ctx)
      {:ok, kc}
    end

    test "MP-KCO-1 item retired after start: post_kind_change_out posts (from side only)", kc do
      kc_receive_stock!(kc)
      doc = kc_issue!(kc)
      id = doc["id"]
      retire_item!(kc.schema, kc.m.item)
      task = kc_pending_task!(kc, id)
      assert {:ok, _} = kc_complete!(kc, task)
      counts = kc_stock_counts(kc, id)
      assert Map.has_key?(counts.entries, "kind_change_out")
    end

    test "MP-KCO-2 unknown uuid as sku in replaced posting is refused", kc do
      kc_receive_stock!(kc)
      doc = kc_issue!(kc)
      id = doc["id"]
      task = kc_pending_task!(kc, id)
      instance = Repo.get!(InstanceProjection, task.instance_id, prefix: kc.schema)
      bad_posting = posting_with(instance, "sku", Ecto.UUID.generate())
      assert {:error, _} = kc_complete!(kc, task, bad_posting)
      assert kc_stock_counts(kc, id).entries == %{}
    end
  end

  # -- criterion 7: reversal reads nothing -------------------------------------------------------

  describe "MP-REV reversal reads nothing (criterion 7)" do
    test "MP-REV-1 posted receipt with retired item and location: reversal writes the entry", ctx do
      doc = P.issue!(ctx, one_line_body(ctx))
      P.post_and_complete!(ctx, doc["id"])

      retire_item!(ctx.schema, ctx.ma.item)
      {:ok, _} = Locations.retire_node(ctx.schema, ctx.ma.location, opts())

      conn = D.request(:post, "/documents/#{doc["id"]}/reverse",
        ctx.tok_a, %{"reason_code" => "wrong_document"})
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

      conn = D.request(:post, "/documents/#{doc["id"]}/reverse",
        ctx.tok_a, %{"reason_code" => "wrong_document"})
      assert conn.status == 200
      task = P.pending_task(ctx, doc["id"], "reverse")

      {result, queries} =
        Fixture.capture_repo_queries(fn -> P.complete(ctx, task) end)

      assert {:ok, _} = result

      erl_queries =
        Enum.filter(queries, fn q ->
          String.contains?(q[:query] || "", "entity_record_latest")
        end)

      for id <- [ctx.ma.item, ctx.ma.location] do
        reads_with_id =
          Enum.filter(erl_queries, fn q ->
            id in List.wrap(q[:params])
          end)

        assert reads_with_id == [],
          "expected no reads for #{id} during reversal"
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

    erl_queries =
      Enum.filter(queries, fn q ->
        String.contains?(q[:query] || "", "entity_record_latest")
      end)

    for q <- erl_queries do
      sql = q[:query] || ""
      refute String.contains?(sql, "FOR UPDATE"), "unexpected FOR UPDATE: #{sql}"
      refute String.contains?(sql, "FOR SHARE"), "unexpected FOR SHARE: #{sql}"
    end

    for master_id <- [ctx.ma.item, ctx.ma.uom, ctx.ma.location, ctx.ma.unit, ctx.ma.employee] do
      count =
        Enum.count(erl_queries, fn q ->
          params = List.wrap(q[:params])
          master_id in params or
            (match?({:ok, _}, Ecto.UUID.dump(master_id)) and
               (fn -> {:ok, dumped} = Ecto.UUID.dump(master_id); dumped in params end).())
        end)

      assert count == 1,
        "expected exactly 1 SELECT for #{master_id} in entity_record_latest, got #{count}"
    end
  end

  # -- criterion 9: tenant isolation -------------------------------------------------------------

  test "MP-ISO-1 posting in tenant A with sku from tenant B is refused", ctx do
    extra = P.tenant_b!(ctx)
    b_item = extra.mb.item

    assert Repo.get_by(Latest, [record_id: b_item, entity_type: "catalog_item"],
             prefix: ctx.schema) == nil

    doc = P.issue!(ctx, one_line_body(ctx))
    id = doc["id"]
    task = P.pending_task(ctx, id, "post")
    output = posting_with(get_instance!(ctx, task), "sku", b_item)
    assert {:error, _} = P.complete(ctx, task, output: output)
    assert_refused(ctx, id)
  end

  # -- count_difference helpers ------------------------------------------------------------------

  defp build_count_world!(ctx) do
    s = ctx.schema
    n = System.unique_integer([:positive])

    unit = CF.unit!(s)

    {:ok, loc} =
      Locations.create_node(s, %{"code" => "MCL#{n}", "name" => "MCL", "node_kind" => "zone"}, opts())
    {:ok, _} = Locations.link_unit_location(s, unit, loc["record_id"], opts())
    loc_id = loc["record_id"]

    uom = Cat.uom!(s, "MPCS#{n}")
    shortage_item = Cat.item!(s, "MSI#{n}", uom.record_id)
    surplus_item = Cat.item!(s, "MSS#{n}", uom.record_id)

    chair_sub = "count-chair-#{n}"
    chair_tok = S.token(ctx, :a, ["TENANT_ADMIN"], sub: chair_sub)
    stock_route!(:get, "/counts", chair_tok)
    chair_user = Repo.one!(from(u in User, where: u.username == ^chair_sub), prefix: s)
    chair = CF.employee!(s, unit, user: chair_user.id)

    %{
      schema: s,
      unit: unit,
      location: loc_id,
      uom: uom.record_id,
      shortage_item: shortage_item.record_id,
      surplus_item: surplus_item.record_id,
      chair: chair,
      chair_tok: chair_tok,
      tok_a: chair_tok,
      holder: ctx.holder
    }
  end

  defp signed_count_with_surplus!(x) do
    s = x.schema
    S.post!(s, "receipt", %{lines: [S.line(x.shortage_item, "10", %{to: S.side(x.unit, x.location)})]})
    id = create_and_sign_count!(x, surplus?: true)
    {id, x.surplus_item}
  end

  defp signed_count_with_shortage_only!(x) do
    s = x.schema
    S.post!(s, "receipt", %{lines: [S.line(x.shortage_item, "10", %{to: S.side(x.unit, x.location)})]})
    id = create_and_sign_count!(x, surplus?: false)
    {id, x.shortage_item}
  end

  defp create_and_sign_count!(x, opts) do
    window = %{
      "planned_start" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -3600)),
      "planned_end" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 72 * 3600))
    }

    count_body = %{
      "org_unit_id" => x.unit,
      "kind" => "selective",
      "planned_start" => window["planned_start"],
      "planned_end" => window["planned_end"],
      "chair_employee_id" => x.chair,
      "member_employee_ids" => [],
      "location_ids" => [x.location],
      "note" => "master test"
    }

    created = stock_route!(x, :post, "/counts", count_body, 201)
    id = created["id"]
    stock_route!(x, :post, "/counts/#{id}/issue", %{}, 200)
    stock_route!(x, :post, "/counts/#{id}/open", %{}, 200)

    lines = stock_route!(x, :get, "/counts/#{id}/lines", nil, 200)["rows"]

    for l <- lines do
      stock_route!(x, :put, "/counts/#{id}/lines/#{l["line_no"]}/count",
        %{"counted_quantity" => "3"}, 200)
    end

    if Keyword.get(opts, :surplus?, false) do
      stock_route!(x, :post, "/counts/#{id}/surplus-lines", %{
        "location_id" => x.location,
        "catalog_item_id" => x.surplus_item,
        "unit_ref" => x.uom,
        "counted_quantity" => "2"
      }, 201)
    end

    stock_route!(x, :post, "/counts/#{id}/close", %{}, 200)

    signer_ids = %{"signer_employee_ids" => [x.chair]}
    stock_route!(x, :post, "/counts/#{id}/sheet-signatures", signer_ids, 200)
    stock_route!(x, :post, "/counts/#{id}/differences", %{}, 200)
    stock_route!(x, :post, "/counts/#{id}/differences-signatures", signer_ids, 200)

    id
  end

  defp count_post!(x, count_id) do
    stock_route!(x, :post, "/counts/#{count_id}/post", %{}, 200)
  end

  defp get_diff_id!(x, count_id) do
    stock_route!(x, :get, "/counts/#{count_id}", nil, 200)["differences_document_id"]
  end

  defp stock_route!(x_or_tok, method, path, body, expected_status \\ 200)

  defp stock_route!(tok, method, path, body, expected_status) when is_binary(tok) do
    stock_route!(%{tok_a: tok}, method, path, body, expected_status)
  end

  defp stock_route!(x, method, path, body, expected_status) when is_map(x) do
    base = "/api/v1/modules/stock"
    tok = Map.fetch!(x, :tok_a)

    conn =
      case body do
        nil -> Plug.Test.conn(method, base <> path)
        b -> Plug.Test.conn(method, base <> path, Jason.encode!(b))
      end

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> tok)
      |> put_req_header("content-type", "application/json")
      |> Letflow.Router.call(Letflow.Router.init([]))

    assert conn.status == expected_status,
      "#{method} #{path} expected #{expected_status}, got #{conn.status}: #{conn.resp_body}"

    if conn.resp_body == "", do: %{}, else: S.json(conn)
  end

  # -- kind_change helpers -----------------------------------------------------------------------

  defp build_kind_change_ctx!(ctx) do
    s = ctx.schema

    {:ok, _} =
      Installs.install("assets", Ecto.UUID.generate(),
        prefix: s,
        rationale: "test: REQ-832 MP-KCO"
      )

    m = KC.masters!(s)

    %{
      schema: s,
      m: m,
      tok_a: ctx.tok_a,
      holder: ctx.holder
    }
  end

  defp kc_receive_stock!(kc) do
    n = System.unique_integer([:positive])
    supplier = Cat.counterparty!(kc.schema, "KC-SUP#{n}")
    m = kc.m

    body = %{
      "kind" => "receipt",
      "org_unit_id" => m.unit,
      "location_id" => m.location,
      "responsible_id" => m.employee,
      "event_time" => DateTime.to_iso8601(DateTime.utc_now()),
      "counterparty_id" => supplier.record_id,
      "lines" => [
        %{"catalog_item_id" => m.item, "catalog_uom_id" => m.uom, "quantity" => "25"}
      ]
    }

    stock_conn = assets_or_stock_route!(:post, "/documents", kc.tok_a, :stock, body, 201)
    doc = S.json(stock_conn)

    stock_conn2 =
      assets_or_stock_route!(:post, "/documents/#{doc["id"]}/issue", kc.tok_a, :stock, nil, 200)

    issued = S.json(stock_conn2)
    task = kc_find_pending_task!(kc, issued["id"])

    assert {:ok, _} =
             Engine.complete_task(
               task.id,
               %{
                 output_variables: %{},
                 actor_id: kc.holder.id,
                 idempotency_key: Ecto.UUID.generate()
               },
               prefix: kc.schema,
               credential: :oidc
             )
  end

  defp kc_issue!(kc) do
    m = kc.m
    body = KC.body(m, %{}, [KC.line(m, %{"quantity" => "20", "target_kind" => "low_value"})])
    conn = assets_or_stock_route!(:post, "/documents", kc.tok_a, :assets, body, 201)
    doc = S.json(conn)
    conn2 =
      assets_or_stock_route!(:post, "/documents/#{doc["id"]}/issue", kc.tok_a, :assets, nil, 200)
    S.json(conn2)
  end

  defp assets_or_stock_route!(method, path, tok, module, body, expected_status) do
    base =
      case module do
        :stock -> "/api/v1/modules/stock"
        :assets -> "/api/v1/modules/assets"
      end

    conn =
      case body do
        nil -> Plug.Test.conn(method, base <> path)
        b -> Plug.Test.conn(method, base <> path, Jason.encode!(b))
      end

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> tok)
      |> put_req_header("content-type", "application/json")
      |> Letflow.Router.call(Letflow.Router.init([]))

    assert conn.status == expected_status,
      "#{method} #{base}#{path} expected #{expected_status}, got #{conn.status}: #{conn.resp_body}"

    conn
  end

  defp kc_pending_task!(kc, id) do
    Repo.one!(
      from(t in Letflow.Engine.Task,
        join: p in InstanceProjection,
        on: p.instance_id == t.instance_id,
        where:
          t.status == :pending and t.node_id == "post" and
            fragment("?->>'document_id' = ?", p.variables, ^id)
      ),
      prefix: kc.schema
    )
  end

  defp kc_find_pending_task!(kc, id) do
    kc_pending_task!(kc, id)
  end

  defp kc_complete!(kc, task, output \\ %{}) do
    Engine.complete_task(
      task.id,
      %{output_variables: output, actor_id: kc.holder.id, idempotency_key: Ecto.UUID.generate()},
      prefix: kc.schema,
      credential: :oidc
    )
  end

  defp kc_stock_counts(kc, id) do
    %{rows: rows} =
      Repo.query!(
        ~s|SELECT cause, count(*) FROM "#{kc.schema}".ledger_entry WHERE document_id = $1 GROUP BY cause|,
        [id]
      )

    %{rows: [[marks]]} =
      Repo.query!(
        ~s|SELECT count(*) FROM "#{kc.schema}".entity_record_latest WHERE entity_type = 'stock_posting_mark' AND NOT deleted AND field_values->>'document_id' = $1|,
        [id]
      )

    %{entries: Map.new(rows, fn [cause, n] -> {cause, n} end), marks: marks}
  end
end
