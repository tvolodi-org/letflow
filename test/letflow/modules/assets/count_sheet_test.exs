Code.require_file("counts_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.CountSheetTest do
  @moduledoc """
  REQ-817 / GH #4374 (asset count K2) through `Letflow.Modules.Assets.CountSheet`, over a real posted
  register (documents through the real routes). Criterion 1: K2-B1. Criterion 2: K2-B2, K2-B3.
  Criterion 3: K2-T1..T5. Criterion 4: K2-S1..S3. Criterion 5: K2-C1, K2-M1..M3. Criterion 6: K2-R1..R3.
  Also K2-D1 (period), K2-Z1 (freeze order), K2-A1, K2-A2 (audit). Committed tenants, Sandbox `:auto`,
  `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit.Entry
  alias Letflow.AssetsCountsFixture, as: F
  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.Entities.Record.Latest
  alias Letflow.Ledger
  alias Letflow.Modules.Assets.CountSheet
  alias Letflow.Modules.Assets.Counts
  alias Letflow.Modules.Assets.Documents.Posting
  alias Letflow.Modules.ReadApi

  setup do
    ctx = D.setup!([:a])
    s = ctx.schema

    # the cards carry book data that must come into the lines unchanged
    for card <- [ctx.ma.fixed, ctx.ma.fixed2] do
      card_values!(s, card, %{"acquisition_cost" => "1200", "book_value" => "800"})
    end

    {:ok, Map.merge(ctx, %{sw: F.sheet_world!(s, ctx.ma)})}
  end

  # --- helpers ----------------------------------------------------------------------------------

  defp card_values!(s, id, extra) do
    {:ok, card} = ReadApi.lookup(s, id, ["assets_card"])

    attrs = %{
      entity_type: "assets_card",
      record_id: id,
      field_values: card |> Map.drop(["record_id", "entity_type"]) |> Map.merge(extra),
      actor_id: Ecto.UUID.generate(),
      idempotency_key: Ecto.UUID.generate()
    }

    # scope-all: SEC-518-R1 (test fixture, the owner path of the assets module)
    {:ok, _} =
      Letflow.Entities.Records.update_record(
        attrs,
        s,
        Letflow.Entities.ManagedTypes.owner_for!(Letflow.Modules.Assets)
      )
  end

  # A real TENANT_ADMIN user of the tenant, as the router would hand to `Ledger.authorize/3`.
  defp authorized!(ctx) do
    fx = %{tenant_id: ctx.a.tenant_id, schema_name: ctx.schema}
    user = Letflow.LedgerFixture.user!(fx, ["TENANT_ADMIN"])
    conn = Letflow.LedgerFixture.conn_for(fx, user, ["TENANT_ADMIN"])
    {:ok, auth} = Ledger.authorize(conn, "assets", :read)
    auth
  end

  defp ordered!(ctx, extra \\ %{}) do
    s = ctx.schema
    input = F.input(ctx.sw.w, F.window(extra))
    {:ok, %{"id" => id}} = Counts.create(s, input, F.opts())
    {:ok, %{"status" => "ordered"}} = Counts.issue(s, id, F.opts())
    id
  end

  defp open!(ctx, id) do
    opts = %{actor_id: ctx.sw.chair_user, authorized: authorized!(ctx)}
    assert {:ok, %{"status" => "counting"} = v} = CountSheet.open(ctx.schema, id, opts)
    v
  end

  defp chair, do: fn ctx -> %{actor_id: ctx.sw.chair_user} end
  defp member, do: fn ctx -> %{actor_id: ctx.sw.member_user} end

  defp lines!(ctx, id) do
    {:ok, %{rows: rows}} =
      CountSheet.lines(ctx.schema, id, %{"limit" => "200"}, %{actor_id: ctx.sw.chair_user})

    rows
  end

  defp entries!(ctx, id) do
    {:ok, %{rows: rows}} = CountSheet.entries(ctx.schema, id, %{}, %{actor_id: ctx.sw.chair_user})
    rows
  end

  defp record(ctx, id, no, body, who \\ member()),
    do: CountSheet.record_line(ctx.schema, id, no, body, who.(ctx))

  defp count_all!(ctx, id) do
    for l <- lines!(ctx, id) do
      body =
        if l["asset_kind"] == "low_value",
          do: %{"counted_quantity" => l["book_quantity"]},
          else: %{"found" => true}

      assert {:ok, _} = record(ctx, id, l["line_no"], body)
    end
  end

  defp live(s, type),
    do:
      Repo.aggregate(from(l in Latest, where: l.entity_type == ^type and not l.deleted), :count,
        prefix: s
      )

  defp audits(s, id),
    do: Repo.all(from(e in Entry, where: e.resource_id == ^id, order_by: e.timestamp), prefix: s)

  defp commission!(ctx, lines, drop \\ []) do
    body = D.body(ctx.ma, %{"lines" => lines}) |> Map.drop(drop)
    D.commission!(ctx, body)
  end

  defp card_text(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp card_text(v), do: v

  # --- criterion 1 ------------------------------------------------------------------------------

  describe "criterion 1: the book lines" do
    test "K2-B1: lines are the ledger at the cut-off inside the scope; a later hand over is not in",
         ctx do
      m = ctx.ma
      s = ctx.schema
      p2 = D.place!(s)
      x = D.card!(s, "fixed", p2.unit)

      commission!(ctx, [
        %{"asset_id" => m.fixed, "quantity" => "1"},
        %{"asset_id" => m.fixed2, "quantity" => "1"}
      ])

      D.commission!(
        ctx,
        D.body(Map.merge(p2, %{employee2: p2.employee, fixed: x}), %{
          "org_unit_id" => p2.unit,
          "location_id" => p2.location,
          "material_responsible_id" => p2.employee,
          "actual_user_id" => p2.employee,
          "lines" => [%{"asset_id" => x, "quantity" => "1"}]
        })
      )

      id = ordered!(ctx, %{"location_ids" => [m.location]})

      # a hand over of fixed2 to place 2 that happens AFTER the cut-off (event time in the future)
      later = DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 240))

      doc =
        D.issue!(
          ctx,
          D.handover_body(m, p2, %{
            "event_time" => later,
            "lines" => [%{"asset_id" => m.fixed2, "quantity" => "1"}]
          })
        )

      D.run_task!(ctx, doc["id"])
      assert [%{"location" => loc}] = D.balances(ctx, m.fixed2)
      assert loc == p2.location

      view = open!(ctx, id)
      assert view["status"] == "counting"
      assert is_binary(view["cut_off_at"]) and is_integer(view["cutoff_seq"])

      rows = lines!(ctx, id)
      assert Enum.sort(Enum.map(rows, & &1["asset_id"])) == Enum.sort([m.fixed, m.fixed2])
      refute x in Enum.map(rows, & &1["asset_id"])

      for l <- rows do
        {:ok, card} = ReadApi.lookup(s, l["asset_id"], ["assets_card"])
        assert l["book_location_id"] == m.location
        assert l["book_material_responsible_id"] == m.employee
        assert l["book_quantity"] == "1" and l["kind"] == "book"
        assert l["inventory_number"] == card["inventory_number"]
        assert l["book_value"] == card_text(card["book_value"])
        assert l["acquisition_cost"] == card_text(card["acquisition_cost"])
        assert l["counted_quantity"] == nil
      end

      assert Enum.map(rows, & &1["line_no"]) == [1, 2]
    end
  end

  # --- criterion 2 ------------------------------------------------------------------------------

  describe "criterion 2: kinds" do
    test "K2-B2: only the kinds of the order are lines", ctx do
      m = ctx.ma

      commission!(ctx, [
        %{"asset_id" => m.fixed, "quantity" => "1"},
        %{"asset_id" => m.low, "quantity" => "5"}
      ])

      id = ordered!(ctx, %{"kinds" => ["fixed"]})
      open!(ctx, id)
      assert [%{"asset_id" => asset, "asset_kind" => "fixed"}] = lines!(ctx, id)
      assert asset == m.fixed
    end

    test "K2-B3: an intangible has no location and is a line only when the kinds hold it", ctx do
      m = ctx.ma
      s = ctx.schema

      commission!(ctx, [%{"asset_id" => m.intangible, "quantity" => "1"}], ["location_id"])

      id = ordered!(ctx, %{"kinds" => ["fixed", "intangible"], "location_ids" => [m.location]})
      open!(ctx, id)
      assert [%{"asset_id" => asset, "book_location_id" => nil}] = lines!(ctx, id)
      assert asset == m.intangible

      assert {:ok, %{"status" => "cancelled"}} =
               Counts.cancel(s, id, %{actor_id: ctx.sw.chair_user})

      id2 = ordered!(ctx, %{"kinds" => ["fixed"], "location_ids" => [m.location]})
      open!(ctx, id2)
      assert lines!(ctx, id2) == []
    end
  end

  # --- criterion 3 ------------------------------------------------------------------------------

  describe "criterion 3: typed input" do
    setup ctx do
      m = ctx.ma

      commission!(ctx, [
        %{"asset_id" => m.fixed, "quantity" => "1"},
        %{"asset_id" => m.low, "quantity" => "5"}
      ])

      id = ordered!(ctx, %{"kinds" => ["fixed", "low_value"]})
      open!(ctx, id)
      rows = lines!(ctx, id)
      {:ok, id: id, fixed_no: no_of(rows, "fixed"), low_no: no_of(rows, "low_value")}
    end

    defp no_of(rows, kind), do: Enum.find(rows, &(&1["asset_kind"] == kind))["line_no"]

    defp state(ctx, id),
      do:
        {live(ctx.schema, "assets_count_entry"), length(audits(ctx.schema, id)), lines!(ctx, id)}

    test "K2-T1: found false is stored as 0 and found true as 1", ctx do
      assert {:ok, %{"counted_quantity" => "0"}} =
               record(ctx, ctx.id, ctx.fixed_no, %{"found" => false})

      assert {:ok, %{"counted_quantity" => "1"}} =
               record(ctx, ctx.id, ctx.fixed_no, %{"found" => true})

      assert Enum.find(lines!(ctx, ctx.id), &(&1["line_no"] == ctx.fixed_no))["counted_quantity"] ==
               "1"
    end

    test "K2-T2: a low value count must be a whole number; nothing is stored on refusal", ctx do
      before = state(ctx, ctx.id)

      for bad <- ["-1", "1.5x", "1.5", "2.0", "", "01", 3] do
        assert {:error, {:field_invalid, "counted_quantity"}} =
                 record(ctx, ctx.id, ctx.low_no, %{"counted_quantity" => bad})
      end

      assert {:error, {:field_not_allowed, "found"}} =
               record(ctx, ctx.id, ctx.low_no, %{"found" => true})

      assert {:error, {:field_not_allowed, "counted_quantity"}} =
               record(ctx, ctx.id, ctx.fixed_no, %{"counted_quantity" => "1"})

      assert {:error, {:field_invalid, "found"}} =
               record(ctx, ctx.id, ctx.fixed_no, %{"found" => "true"})

      assert {:error, {:field_not_allowed, "tenant_id"}} =
               record(ctx, ctx.id, ctx.fixed_no, %{"found" => true, "tenant_id" => "x"})

      assert state(ctx, ctx.id) == before

      assert {:ok, %{"counted_quantity" => "0"}} =
               record(ctx, ctx.id, ctx.low_no, %{"counted_quantity" => "0"})
    end

    test "K2-T3: an observed location outside the roots is refused", ctx do
      before = state(ctx, ctx.id)

      assert {:error, :location_not_in_count} =
               record(ctx, ctx.id, ctx.fixed_no, %{
                 "found" => true,
                 "observed_location_id" => ctx.sw.loc2
               })

      assert state(ctx, ctx.id) == before

      assert {:ok, %{"observed_location_id" => loc}} =
               record(ctx, ctx.id, ctx.fixed_no, %{
                 "found" => true,
                 "observed_location_id" => ctx.ma.location
               })

      assert loc == ctx.ma.location
    end

    test "K2-T4: a condition outside the set is refused, an inactive employee too", ctx do
      before = state(ctx, ctx.id)

      assert {:error, {:field_invalid, "condition"}} =
               record(ctx, ctx.id, ctx.fixed_no, %{"found" => true, "condition" => "broken"})

      assert {:error, :employee_inactive} =
               record(ctx, ctx.id, ctx.fixed_no, %{
                 "found" => true,
                 "observed_actual_user_id" => Ecto.UUID.generate()
               })

      assert state(ctx, ctx.id) == before

      assert {:ok, %{"condition" => "damaged"}} =
               record(ctx, ctx.id, ctx.fixed_no, %{"found" => true, "condition" => "damaged"})
    end

    test "K2-T5: a later input replaces the first and both stay in the log", ctx do
      assert {:ok, _} = record(ctx, ctx.id, ctx.low_no, %{"counted_quantity" => "3"})
      assert {:ok, _} = record(ctx, ctx.id, ctx.low_no, %{"counted_quantity" => "4"})

      assert Enum.find(lines!(ctx, ctx.id), &(&1["line_no"] == ctx.low_no))["counted_quantity"] ==
               "4"

      assert [e1, e2] = entries!(ctx, ctx.id)

      assert e1["value_before"] == nil
      assert e1["value_after"]["counted_quantity"] == "3"
      assert e2["value_before"]["counted_quantity"] == "3"
      assert e2["value_after"]["counted_quantity"] == "4"

      for e <- [e1, e2] do
        assert e["entered_by"] == ctx.sw.member_user
        assert e["entered_by_employee_id"] == ctx.sw.member
        assert {:ok, _, _} = DateTime.from_iso8601(e["entered_at"])
        assert e["method"] == "typed" and e["action"] == "recorded"
      end

      assert [1, 2] == Enum.map([e1, e2], & &1["entry_no"])
    end

    test "K2-L1: line numbers, a closed count and the read parameters", ctx do
      assert {:error, :line_not_found} = record(ctx, ctx.id, 99, %{"found" => true})
      assert {:error, :line_not_found} = record(ctx, ctx.id, "01", %{"found" => true})
      assert {:error, :line_not_found} = record(ctx, ctx.id, "x", %{"found" => true})

      assert {:ok, %{rows: [_], next_cursor: "1"}} =
               CountSheet.lines(ctx.schema, ctx.id, %{"limit" => "1"}, chair().(ctx))

      assert {:error, {:field_not_allowed, "x"}} =
               CountSheet.lines(ctx.schema, ctx.id, %{"x" => "1"}, chair().(ctx))

      assert {:error, {:field_invalid, "limit"}} =
               CountSheet.entries(ctx.schema, ctx.id, %{"limit" => "0"}, chair().(ctx))
    end
  end

  # --- criterion 4 ------------------------------------------------------------------------------

  describe "criterion 4: surplus lines" do
    setup ctx do
      m = ctx.ma
      commission!(ctx, [%{"asset_id" => m.fixed, "quantity" => "1"}])
      id = ordered!(ctx, %{"kinds" => ["fixed", "low_value"]})
      open!(ctx, id)
      {:ok, id: id}
    end

    defp surplus(ctx, body, who \\ member()),
      do: CountSheet.add_surplus_line(ctx.schema, ctx.id, body, who.(ctx))

    test "K2-S1: a card that has a book line cannot be a surplus line", ctx do
      before = length(lines!(ctx, ctx.id))

      assert {:error, :count_line_exists} =
               surplus(ctx, %{
                 "asset_id" => ctx.ma.fixed,
                 "observed_location_id" => ctx.ma.location
               })

      assert length(lines!(ctx, ctx.id)) == before
    end

    test "K2-S2: a description of 501 codepoints is refused", ctx do
      body = %{"description" => String.duplicate("я", 501), "counted_quantity" => "1"}
      assert {:error, {:field_invalid, "description"}} = surplus(ctx, body)

      assert {:error, {:field_invalid, "description"}} =
               surplus(ctx, %{body | "description" => ""})

      assert {:error, {:field_invalid, "asset_id"}} = surplus(ctx, %{"counted_quantity" => "1"})

      assert {:error, {:field_invalid, "asset_id"}} =
               surplus(ctx, Map.put(body, "asset_id", ctx.ma.low) |> Map.put("description", "x"))

      assert length(lines!(ctx, ctx.id)) == 1
    end

    test "K2-S3: a 500 codepoint description is stored as line n + 1 with one entry", ctx do
      n = length(lines!(ctx, ctx.id))
      text = String.duplicate("я", 500)

      assert {:ok, line} = surplus(ctx, %{"description" => text, "counted_quantity" => "2"})
      assert line["kind"] == "surplus" and line["book_quantity"] == "0"
      assert line["line_no"] == n + 1 and line["description"] == text
      assert line["counted_quantity"] == "2" and line["asset_id"] == nil

      assert [%{"action" => "surplus_added", "line_no" => no, "value_before" => nil}] =
               entries!(ctx, ctx.id)

      assert no == n + 1
    end

    test "K2-S4: a card without a line is a surplus line with its card values", ctx do
      assert {:ok, line} =
               surplus(ctx, %{
                 "asset_id" => ctx.ma.fixed2,
                 "observed_location_id" => ctx.ma.location
               })

      assert line["asset_id"] == ctx.ma.fixed2 and line["counted_quantity"] == "1"
      assert line["asset_kind"] == "fixed" and is_binary(line["inventory_number"])

      assert {:error, :count_line_exists} =
               surplus(ctx, %{
                 "asset_id" => ctx.ma.fixed2,
                 "observed_location_id" => ctx.ma.location
               })

      assert {:error, :kind_not_in_count} =
               surplus(ctx, %{"asset_id" => ctx.ma.intangible})

      assert {:error, {:field_invalid, "observed_location_id"}} =
               surplus(ctx, %{"asset_id" => ctx.ma.low, "counted_quantity" => "2"})
    end
  end

  # --- criterion 5 ------------------------------------------------------------------------------

  describe "criterion 5: close and sheet marks" do
    setup ctx do
      m = ctx.ma

      commission!(ctx, [
        %{"asset_id" => m.fixed, "quantity" => "1"},
        %{"asset_id" => m.fixed2, "quantity" => "1"}
      ])

      id = ordered!(ctx)
      open!(ctx, id)
      {:ok, id: id}
    end

    defp close(ctx), do: CountSheet.close(ctx.schema, ctx.id, chair().(ctx))

    defp mark(ctx, ids),
      do:
        CountSheet.mark_sheet_signed(
          ctx.schema,
          ctx.id,
          %{"signer_employee_ids" => ids},
          chair().(ctx)
        )

    defp required(ctx), do: [ctx.sw.chair, ctx.sw.member, ctx.ma.employee]

    test "K2-C1: close issues the sheet document whose lines are the line records", ctx do
      s = ctx.schema
      count_all!(ctx, ctx.id)
      assert {:ok, %{"status" => "counted", "sheet_number" => number} = v} = close(ctx)
      assert String.starts_with?(number, "ACS")
      assert is_binary(v["sheet_document_id"]) and is_binary(v["closed_at"])

      issued = Posting.issued(s, v["sheet_document_id"])
      assert issued.content["lines"] == lines!(ctx, ctx.id)
      assert issued.content["count_order_id"] == ctx.id
      assert issued.content["chair_employee_id"] == ctx.sw.chair

      assert {:ok, %{number_label: ^number, document_id: doc}} =
               CountSheet.sheet_document(s, ctx.id, chair().(ctx))

      assert doc == v["sheet_document_id"]
      assert {:error, :count_state_invalid} = record(ctx, ctx.id, 1, %{"found" => true})
      assert {:error, :count_state_invalid} = close(ctx)
    end

    test "K2-M1: marks without one member are refused, nothing is stored", ctx do
      count_all!(ctx, ctx.id)
      assert {:ok, _} = close(ctx)
      assert {:error, :signers_incomplete} = mark(ctx, [ctx.sw.chair, ctx.ma.employee])
      assert {:ok, %{"status" => "counted"}} = Counts.get(ctx.schema, ctx.id, chair().(ctx))
      assert live(ctx.schema, "assets_count_signature") == 0
    end

    test "K2-M2: an extra employee in the marks is refused", ctx do
      count_all!(ctx, ctx.id)
      assert {:ok, _} = close(ctx)

      assert {:error, {:field_invalid, "signer_employee_ids"}} =
               mark(ctx, required(ctx) ++ [ctx.sw.other])

      assert {:error, {:field_invalid, "signer_employee_ids"}} = mark(ctx, ["x"])

      assert {:error, {:field_invalid, "signer_employee_ids"}} =
               mark(ctx, [ctx.sw.chair, ctx.sw.chair])

      assert {:error, {:field_not_allowed, "x"}} =
               CountSheet.mark_sheet_signed(ctx.schema, ctx.id, %{"x" => 1}, chair().(ctx))

      assert live(ctx.schema, "assets_count_signature") == 0
    end

    test "K2-M3: the exact set moves the count to sheet_signed with one row per signer", ctx do
      count_all!(ctx, ctx.id)
      assert {:ok, _} = close(ctx)

      assert {:ok, %{"status" => "sheet_signed", "sheet_signed_by" => by}} =
               mark(ctx, Enum.reverse(required(ctx)))

      assert by == ctx.sw.chair_user

      rows =
        Repo.all(
          from(l in Latest, where: l.entity_type == "assets_count_signature" and not l.deleted),
          prefix: ctx.schema
        )
        |> Enum.map(&{&1.field_values["employee_id"], &1.field_values["signer_role"]})

      assert Enum.sort(rows) ==
               Enum.sort([
                 {ctx.sw.chair, "chair"},
                 {ctx.sw.member, "member"},
                 {ctx.ma.employee, "responsible"}
               ])

      assert {:error, :count_state_invalid} = mark(ctx, required(ctx))
    end
  end

  # --- criterion 6 ------------------------------------------------------------------------------

  describe "criterion 6: roles and the close rule" do
    setup ctx do
      commission!(ctx, [%{"asset_id" => ctx.ma.fixed, "quantity" => "1"}])
      id = ordered!(ctx)
      {:ok, id: id}
    end

    test "K2-R1: an employee that is neither chair nor member may not record", ctx do
      open!(ctx, ctx.id)
      other = fn c -> %{actor_id: c.sw.other_user} end
      assert {:error, :not_commission_member} = record(ctx, ctx.id, 1, %{"found" => true}, other)

      assert {:error, :not_commission_member} =
               surplus(ctx, %{"description" => "x", "counted_quantity" => "1"}, other)

      nobody = fn _ -> %{actor_id: Ecto.UUID.generate()} end
      assert {:error, :not_commission_member} = record(ctx, ctx.id, 1, %{"found" => true}, nobody)
    end

    test "K2-R2: a member is not the chair for open and close", ctx do
      opts = %{actor_id: ctx.sw.member_user, authorized: authorized!(ctx)}
      assert {:error, :not_chair} = CountSheet.open(ctx.schema, ctx.id, opts)
      open!(ctx, ctx.id)
      assert {:error, :not_chair} = CountSheet.close(ctx.schema, ctx.id, member().(ctx))
    end

    test "K2-R3: close with an uncounted line is refused", ctx do
      open!(ctx, ctx.id)
      assert {:error, :lines_not_counted} = CountSheet.close(ctx.schema, ctx.id, chair().(ctx))
      assert {:ok, %{"status" => "counting"}} = Counts.get(ctx.schema, ctx.id, chair().(ctx))
      assert live(ctx.schema, "assets_count_signature") == 0
    end

    test "K2-R5: an unknown or malformed id and a scoped reader answer not_found", ctx do
      opts = %{actor_id: ctx.sw.chair_user, authorized: authorized!(ctx)}
      assert {:error, :not_found} = CountSheet.open(ctx.schema, Ecto.UUID.generate(), opts)
      assert {:error, :not_found} = CountSheet.open(ctx.schema, "nope", opts)
      scoped = %{authorized!(ctx) | scope: {:nodes, [ctx.ma.unit]}}

      assert {:error, :not_found} =
               CountSheet.open(ctx.schema, ctx.id, %{opts | authorized: scoped})

      assert {:error, :not_found} =
               CountSheet.open(ctx.schema, ctx.id, %{actor_id: ctx.sw.chair_user})

      assert {:error, :not_found} = CountSheet.sheet_document(ctx.schema, ctx.id, chair().(ctx))
    end
  end

  # --- period, freeze, audit --------------------------------------------------------------------

  describe "open refusals and audit" do
    test "K2-D1: an open outside the planned period is refused", ctx do
      {:ok, %{"id" => id}} = Counts.create(ctx.schema, F.input(ctx.sw.w), F.opts())
      {:ok, _} = Counts.issue(ctx.schema, id, F.opts())
      opts = %{actor_id: ctx.sw.chair_user, authorized: authorized!(ctx)}
      assert {:error, :count_not_due} = CountSheet.open(ctx.schema, id, opts)
      assert live(ctx.schema, "assets_count_line") == 0
    end

    test "K5-O1: opening a freeze order stores the fixed scope", ctx do
      id = ordered!(ctx, %{"freeze_locations" => true})
      open!(ctx, id)
      {:ok, h} = Letflow.Modules.ReadApi.lookup(ctx.schema, id, ["assets_count_order"])
      assert h["status"] == "counting" and h["freeze_started_at"] == h["cut_off_at"]
      assert h["freeze_whole_unit"] == false
      assert h["freeze_location_ids"] == [ctx.sw.w.a]
    end

    test "K5-O2: a whole-unit freeze order stores no location set", ctx do
      id = ordered!(ctx, %{"freeze_locations" => true, "location_ids" => []})
      open!(ctx, id)
      {:ok, h} = Letflow.Modules.ReadApi.lookup(ctx.schema, id, ["assets_count_order"])
      assert h["freeze_whole_unit"] == true and h["freeze_location_ids"] == []
    end

    test "K2-A1: the audit entries of a life carry status and line number only", ctx do
      commission!(ctx, [%{"asset_id" => ctx.ma.fixed, "quantity" => "1"}])
      id = ordered!(ctx)
      open!(ctx, id)
      assert {:ok, _} = record(ctx, id, 1, %{"found" => true, "condition" => "damaged"})

      assert {:ok, _} =
               CountSheet.add_surplus_line(
                 ctx.schema,
                 id,
                 %{"description" => "secret text", "counted_quantity" => "7"},
                 member().(ctx)
               )

      assert {:ok, _} = CountSheet.close(ctx.schema, id, chair().(ctx))

      assert {:ok, _} =
               CountSheet.mark_sheet_signed(
                 ctx.schema,
                 id,
                 %{"signer_employee_ids" => [ctx.sw.chair, ctx.sw.member, ctx.ma.employee]},
                 chair().(ctx)
               )

      entries =
        audits(ctx.schema, id) |> Enum.filter(&String.starts_with?(&1.action, "assets_count."))

      assert Enum.map(entries, & &1.action) ==
               [
                 "assets_count.created",
                 "assets_count.issued",
                 "assets_count.opened",
                 "assets_count.entry_recorded",
                 "assets_count.entry_recorded",
                 "assets_count.closed",
                 "assets_count.sheet_signed"
               ]

      text = inspect(Enum.map(entries, &{&1.before_state, &1.after_state}))
      refute text =~ "secret text"
      refute text =~ "damaged"
      assert Enum.at(entries, 3).after_state == %{"status" => "counting", "line_no" => 1}
    end

    test "K2-A2: an audit failure rolls the open back", ctx do
      commission!(ctx, [%{"asset_id" => ctx.ma.fixed, "quantity" => "1"}])
      id = ordered!(ctx)
      s = ctx.schema
      Repo.query!(~s|DROP TABLE "#{s}".audit_entries CASCADE|)
      opts = %{actor_id: ctx.sw.chair_user, authorized: authorized!(ctx)}

      assert {:error, :audit_failed} = CountSheet.open(s, id, opts)
      assert {:ok, %{"status" => "ordered"}} = Counts.get(s, id, chair().(ctx))
      assert live(s, "assets_count_line") == 0
    end
  end
end
