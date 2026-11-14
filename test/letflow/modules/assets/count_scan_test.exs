Code.require_file("counts_fixture.exs", __DIR__)
Code.require_file("../codes/codes_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.CountScanTest do
  @moduledoc """
  REQ-818 / GH #4373 (asset count K3) through `Letflow.Modules.Assets.CountSheet.scan/4`: K3-1..K3-10 (the five
  criteria and the refusals), K3-A (audit), U1 (the entry definition change is class A). Committed tenants,
  Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit.Entry
  alias Letflow.AssetsCountsFixture, as: F
  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.CodesFixture, as: K
  alias Letflow.Entities.Record.Latest
  alias Letflow.Ledger
  alias Letflow.Modules.Assets.CountSheet
  alias Letflow.Modules.Assets.Counts
  alias Letflow.Modules.ReadApi

  setup do
    ctx = D.setup!([:a])
    {:ok, Map.merge(ctx, %{sw: F.sheet_world!(ctx.schema, ctx.ma)})}
  end

  # --- helpers ----------------------------------------------------------------------------------

  defp authorized!(ctx) do
    fx = %{tenant_id: ctx.a.tenant_id, schema_name: ctx.schema}
    user = Letflow.LedgerFixture.user!(fx, ["TENANT_ADMIN"])
    conn = Letflow.LedgerFixture.conn_for(fx, user, ["TENANT_ADMIN"])
    {:ok, auth} = Ledger.authorize(conn, "assets", :read)
    auth
  end

  defp commission!(ctx, lines) do
    D.commission!(ctx, D.body(ctx.ma, %{"lines" => lines}))
  end

  # An opened count of the given kinds over the roots `m.location` and `loc2`.
  defp opened!(ctx, kinds \\ ["fixed", "low_value", "intangible"]) do
    input =
      F.input(
        ctx.sw.w,
        F.window(%{"kinds" => kinds, "location_ids" => [ctx.ma.location, ctx.sw.loc2]})
      )

    {:ok, %{"id" => id}} = Counts.create(ctx.schema, input, F.opts())
    {:ok, _} = Counts.issue(ctx.schema, id, F.opts())
    opts = %{actor_id: ctx.sw.chair_user, authorized: authorized!(ctx)}
    assert {:ok, %{"status" => "counting"}} = CountSheet.open(ctx.schema, id, opts)
    id
  end

  defp member(ctx), do: %{actor_id: ctx.sw.member_user}

  defp scan(ctx, id, text, who \\ nil),
    do: CountSheet.scan(ctx.schema, id, %{"text" => text}, who || member(ctx))

  defp number(ctx, card) do
    {:ok, c} = ReadApi.lookup(ctx.schema, card, ["assets_card"])
    c["inventory_number"]
  end

  defp code!(ctx, type, target) do
    value = "C-#{System.unique_integer([:positive])}"
    tag = K.tag!(ctx.schema, value, %{"status" => "assigned"})
    K.assign!(ctx.schema, tag, type, target)
    value
  end

  defp lines!(ctx, id) do
    {:ok, %{rows: rows}} =
      CountSheet.lines(ctx.schema, id, %{"limit" => "200"}, %{actor_id: ctx.sw.chair_user})

    rows
  end

  defp entries!(ctx, id) do
    {:ok, %{rows: rows}} = CountSheet.entries(ctx.schema, id, %{}, %{actor_id: ctx.sw.chair_user})
    rows
  end

  defp live(s, type),
    do:
      Repo.aggregate(from(l in Latest, where: l.entity_type == ^type and not l.deleted), :count,
        prefix: s
      )

  defp audits(s, id),
    do: Repo.all(from(e in Entry, where: e.resource_id == ^id, order_by: e.timestamp), prefix: s)

  defp state(ctx, id),
    do: {live(ctx.schema, "assets_count_entry"), lines!(ctx, id), length(audits(ctx.schema, id))}

  defp line_of(ctx, id, card), do: Enum.find(lines!(ctx, id), &(&1["asset_id"] == card))

  defp fixed_world(ctx) do
    commission!(ctx, [%{"asset_id" => ctx.ma.fixed, "quantity" => "1"}])
    opened!(ctx, ["fixed"])
  end

  # --- criteria ---------------------------------------------------------------------------------

  describe "criterion 1: location then inventory number" do
    test "K3-1: a location code sets the current location, then the number counts the asset",
         ctx do
      id = fixed_world(ctx)
      loc = code!(ctx, "location_node", ctx.sw.loc2)

      assert {:ok, first} = scan(ctx, id, loc)
      assert first["outcome"] == "location_set" and first["location_id"] == ctx.sw.loc2
      assert is_binary(first["location_code"]) and first["location_name"] == "L"
      assert first["line"] == nil

      assert {:ok, second} = scan(ctx, id, number(ctx, ctx.ma.fixed))
      assert second["outcome"] == "counted"
      assert second["line"]["counted_quantity"] == "1"
      assert second["line"]["observed_location_id"] == ctx.sw.loc2
      assert line_of(ctx, id, ctx.ma.fixed)["observed_location_id"] == ctx.sw.loc2

      assert [e1, e2] = entries!(ctx, id)
      assert e1["scan_outcome"] == "location_set" and e1["method"] == "scan"
      assert e1["line_no"] == nil and e1["location_id"] == ctx.sw.loc2
      assert e2["scan_outcome"] == "counted" and e2["scanned_text"] == number(ctx, ctx.ma.fixed)
    end
  end

  describe "criterion 2: repeated scans" do
    test "K3-2: a fixed asset scanned twice stays 1 and is answered already_counted", ctx do
      id = fixed_world(ctx)
      n = number(ctx, ctx.ma.fixed)
      assert {:ok, %{"outcome" => "counted"}} = scan(ctx, id, n)
      view = line_of(ctx, id, ctx.ma.fixed)
      assert {:ok, %{"outcome" => "already_counted"}} = scan(ctx, id, "  " <> n <> "\r\n")
      assert line_of(ctx, id, ctx.ma.fixed) == view and view["counted_quantity"] == "1"

      assert [a, b] = entries!(ctx, id)
      assert {a["method"], a["scan_outcome"]} == {"scan", "counted"}
      assert {b["method"], b["scan_outcome"]} == {"scan", "already_counted"}
      assert b["value_before"] == b["value_after"]
    end

    test "K3-3: a low value asset scanned three times adds 3", ctx do
      commission!(ctx, [%{"asset_id" => ctx.ma.low, "quantity" => "5"}])
      id = opened!(ctx, ["low_value"])
      n = number(ctx, ctx.ma.low)

      for want <- ["1", "2", "3"] do
        assert {:ok, %{"outcome" => "counted", "line" => %{"counted_quantity" => ^want}}} =
                 scan(ctx, id, n)
      end

      assert length(entries!(ctx, id)) == 3
    end
  end

  describe "criterion 3: unknown and out of scope" do
    test "K3-4: a location outside the scope and an unknown text answer unknown_code", ctx do
      id = fixed_world(ctx)
      outside = code!(ctx, "location_node", D.location!(ctx.schema, ctx.ma.unit))
      before = state(ctx, id)

      assert {:error, :unknown_code} = scan(ctx, id, outside)
      assert {:error, :unknown_code} = scan(ctx, id, "NO-SUCH-TEXT-1")
      assert state(ctx, id) == before
    end

    test "K3-5: a catalog item code and a lot code answer not_countable_here", ctx do
      id = fixed_world(ctx)
      before = state(ctx, id)

      for type <- ["catalog_item", "catalog_lot"] do
        assert {:error, :not_countable_here} =
                 scan(ctx, id, code!(ctx, type, Ecto.UUID.generate()))
      end

      assert state(ctx, id) == before
    end
  end

  describe "criterion 4: surplus" do
    test "K3-6: an active card with no line adds a surplus line; a retired card is unknown",
         ctx do
      id = fixed_world(ctx)
      extra = D.card!(ctx.schema, "fixed", ctx.ma.unit)
      retired = D.card!(ctx.schema, "fixed", ctx.ma.unit, %{"active" => false})

      assert {:ok, _} = scan(ctx, id, code!(ctx, "location_node", ctx.sw.loc2))
      lines_before = length(lines!(ctx, id))
      assert {:ok, res} = scan(ctx, id, number(ctx, extra))
      assert res["outcome"] == "surplus_added"
      assert res["line"]["kind"] == "surplus" and res["line"]["counted_quantity"] == "1"
      assert res["line"]["observed_location_id"] == ctx.sw.loc2
      assert res["line"]["line_no"] == lines_before + 1
      assert length(lines!(ctx, id)) == lines_before + 1

      before = state(ctx, id)
      assert {:error, :unknown_code} = scan(ctx, id, number(ctx, retired))
      assert state(ctx, id) == before
    end
  end

  describe "criterion 5: state" do
    test "K3-7: a scan on a counted count is refused count_state_invalid", ctx do
      id = fixed_world(ctx)
      assert {:ok, _} = scan(ctx, id, number(ctx, ctx.ma.fixed))
      assert {:ok, _} = CountSheet.close(ctx.schema, id, %{actor_id: ctx.sw.chair_user})
      before = state(ctx, id)
      assert {:error, :count_state_invalid} = scan(ctx, id, number(ctx, ctx.ma.fixed))
      assert state(ctx, id) == before
    end
  end

  describe "refusals" do
    test "K3-8: retired, not assigned and conflicting codes", ctx do
      id = fixed_world(ctx)
      before = state(ctx, id)

      retired = "R-#{System.unique_integer([:positive])}"
      K.tag!(ctx.schema, retired, %{"status" => "retired"})
      assert {:error, :code_retired} = scan(ctx, id, retired)

      free = "F-#{System.unique_integer([:positive])}"
      K.tag!(ctx.schema, free, %{"status" => "not_assigned"})
      assert {:error, :code_not_assigned} = scan(ctx, id, free)

      twice = "T-#{System.unique_integer([:positive])}"
      tag = K.tag!(ctx.schema, twice, %{"status" => "assigned"})
      K.assign!(ctx.schema, tag, "location_node", ctx.sw.loc2)
      K.assign!(ctx.schema, tag, "location_node", ctx.ma.location)
      assert {:error, :code_assignment_conflict} = scan(ctx, id, twice)

      assert state(ctx, id) == before
    end

    test "K3-9: no location, ambiguous low value line, kind not in the count", ctx do
      id = fixed_world(ctx)
      extra = D.card!(ctx.schema, "fixed", ctx.ma.unit)
      before = state(ctx, id)
      assert {:error, :location_not_set} = scan(ctx, id, number(ctx, extra))
      assert state(ctx, id) == before

      # kind not in the order
      low_extra = D.card!(ctx.schema, "low_value", ctx.ma.unit)
      assert {:error, :kind_not_in_count} = scan(ctx, id, number(ctx, low_extra))
    end

    test "K3-9b: a low value card with two book lines is ambiguous until a location is scanned",
         ctx do
      commission!(ctx, [%{"asset_id" => ctx.ma.low, "quantity" => "2"}])

      D.commission!(
        ctx,
        D.body(ctx.ma, %{
          "location_id" => ctx.sw.loc2,
          "lines" => [%{"asset_id" => ctx.ma.low, "quantity" => "3"}]
        })
      )

      id2 = opened!(ctx, ["low_value"])
      n = number(ctx, ctx.ma.low)
      assert length(lines!(ctx, id2)) == 2
      assert {:error, :scan_ambiguous} = scan(ctx, id2, n)
      assert {:ok, _} = scan(ctx, id2, code!(ctx, "location_node", ctx.sw.loc2))
      assert {:ok, %{"outcome" => "counted", "line" => line}} = scan(ctx, id2, n)
      assert line["book_location_id"] == ctx.sw.loc2 and line["counted_quantity"] == "1"
      assert Enum.count(lines!(ctx, id2), &(&1["counted_quantity"] != nil)) == 1
    end

    test "K3-10: not a member, bad input", ctx do
      id = fixed_world(ctx)
      before = state(ctx, id)
      other = %{actor_id: ctx.sw.other_user}
      assert {:error, :not_commission_member} = scan(ctx, id, "X", other)
      assert {:error, {:field_invalid, "text"}} = scan(ctx, id, "  ")
      assert {:error, {:field_invalid, "text"}} = scan(ctx, id, String.duplicate("a", 501))
      assert {:error, {:field_invalid, "text"}} = scan(ctx, id, <<255, 254>>)

      assert {:error, {:field_not_allowed, "x"}} =
               CountSheet.scan(ctx.schema, id, %{"text" => "A", "x" => 1}, member(ctx))

      assert {:error, :not_found} = scan(ctx, Ecto.UUID.generate(), "A")
      assert state(ctx, id) == before
    end
  end

  describe "audit" do
    test "K3-A: one entry_recorded audit per accepted scan, no quantity, none per refusal", ctx do
      id = fixed_world(ctx)
      base = length(audits(ctx.schema, id))
      assert {:ok, _} = scan(ctx, id, code!(ctx, "location_node", ctx.sw.loc2))
      assert {:ok, _} = scan(ctx, id, number(ctx, ctx.ma.fixed))
      assert {:error, :unknown_code} = scan(ctx, id, "NOPE")

      new = Enum.drop(audits(ctx.schema, id), base)
      assert length(new) == 2
      assert Enum.all?(new, &(&1.action == "assets_count.entry_recorded"))
      assert List.last(new).after_state["line_no"] == 1
      refute Enum.any?(new, &Map.has_key?(&1.after_state, "counted_quantity"))
    end
  end

  # The K2 definition of the entry log (main at da3c74af6), as written then.
  @k2_entry ~S"""
  {
    "name": "assets_count_entry",
    "display_name": "Asset count entry",
    "description": "REQ-817 / GH #4374 (asset count K2, D-128). One entry of the append-only log of an asset count order: who typed which input on which sheet line and when, with the value before and after. entry_no is 1..n per order. No function of module assets updates or deletes an entry. method is typed now; scan is declared for K3 so that slice needs no enum widening. count_order_id is a real foreign key onto assets_count_order; org_unit_id is a copy of the header's, the scope column.",
    "fields": [
      {"name": "count_order_id", "type": "string", "required": true, "queried": true},
      {"name": "entry_no", "type": "integer", "required": true, "queried": true},
      {"name": "line_no", "type": "integer", "required": true},
      {"name": "org_unit_id", "type": "string", "required": true, "queried": true},
      {"name": "action", "type": "enum", "required": true, "enum_values": ["recorded", "surplus_added"]},
      {"name": "method", "type": "enum", "required": true, "enum_values": ["typed", "scan"]},
      {"name": "value_before", "type": "json"},
      {"name": "value_after", "type": "json", "required": true},
      {"name": "entered_by", "type": "string", "required": true},
      {"name": "entered_by_employee_id", "type": "string"},
      {"name": "entered_at", "type": "datetime", "required": true}
    ],
    "foreign_keys": [
      {"name": "fk_assets_count_entry_order_id", "field": "count_order_id", "references_entity": "assets_count_order"}
    ],
    "indexes": [
      {"name": "idx_assets_count_entry_order_entry", "fields": ["count_order_id", "entry_no"]}
    ]
  }
  """

  describe "upgrade safety" do
    test "U1: the K2 entry definition to the current one is class A", _ctx do
      current =
        "priv/modules/assets/entity_definitions/assets_count_entry.json"
        |> File.read!()
        |> Jason.decode!()

      assert {"A", _} =
               Letflow.Modules.UpgradePlan.classify_entity(Jason.decode!(@k2_entry), current)
    end
  end
end
