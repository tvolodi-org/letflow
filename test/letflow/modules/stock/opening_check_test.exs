Code.require_file("opening_fixture.exs", __DIR__)
Code.require_file("../org/org_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.OpeningCheckTest do
  @moduledoc """
  REQ-725 / GH #3775 criteria 5 and 6: the check route (every line, per-line reasons, writes nothing) and
  the issue step of an opening (first failing line, no number on a refusal, content equals the saved
  document, prefix `OPN`). Committed tenants, Sandbox `:auto`, `async: false`.
  Tests: O-CHK-1..14, O-ISS-1..4.
  """

  use Letflow.DataCase, async: false

  alias Letflow.CatalogItemsFixture, as: Cat
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Stock.Documents.Checks
  alias Letflow.Modules.Stock.Documents.Posting
  alias Letflow.OrgFixture
  alias Letflow.Repo
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockOpeningFixture, as: O
  alias Letflow.StockPostingFixture, as: P

  setup do
    ctx = P.setup!()
    on_exit(fn -> Application.delete_env(:letflow, :stock_documents_clock) end)
    ctx
  end

  defp uniq, do: System.unique_integer([:positive])
  defp opts, do: %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}

  defp item(ctx, policy) do
    Cat.item!(ctx.schema, "T#{uniq()}", ctx.ma.uom, %{"tracking_policy" => policy}).record_id
  end

  defp check(ctx, lines) do
    doc = O.save!(ctx, O.body(ctx.ma, %{"lines" => lines}))
    {doc, D.request(:post, "/documents/#{doc["id"]}/check", ctx.tok_a) |> P.status!(200)}
  end

  defp reasons(ctx, lines) do
    {_doc, res} = check(ctx, lines)
    Enum.map(res["lines"], & &1["reasons"])
  end

  test "O-CHK-1 a valid draft is ok with an empty reason list per line", ctx do
    {doc, res} = check(ctx, O.body(ctx.ma)["lines"])

    assert res == %{
             "ok" => true,
             "lines" => [%{"line_no" => 1, "reasons" => []}, %{"line_no" => 2, "reasons" => []}]
           }

    assert P.get!(ctx, doc["id"])["state"] == "draft"
  end

  test "O-CHK-2 not_linked: a location not linked to the document's org unit", ctx do
    {:ok, other} =
      Locations.create_node(
        ctx.schema,
        %{"code" => "X#{uniq()}", "name" => "x", "node_kind" => "zone"},
        opts()
      )

    assert reasons(ctx, [O.line(ctx.ma, %{"location_id" => other["record_id"]})]) == [
             ["not_linked"]
           ]
  end

  test "O-CHK-3 employee_not_active: an inactive and an unknown employee", ctx do
    inactive =
      OrgFixture.create!(
        ctx.schema,
        "org_employee",
        OrgFixture.values("org_employee", "EX#{uniq()}", %{
          "org_unit_id" => ctx.ma.unit,
          "active" => false
        })
      )

    assert reasons(ctx, [
             O.line(ctx.ma, %{"responsible_id" => inactive.record_id}),
             O.line(ctx.ma, %{"responsible_id" => Ecto.UUID.generate()})
           ]) == [["employee_not_active"], ["employee_not_active"]]
  end

  test "O-CHK-4 unit_not_valid: a unit that is not the item's base unit", ctx do
    other = Cat.uom!(ctx.schema, "KG#{uniq()}").record_id
    assert reasons(ctx, [O.line(ctx.ma, %{"catalog_uom_id" => other})]) == [["unit_not_valid"]]
  end

  test "O-CHK-5 the tracking reasons of the receipt, one code path", ctx do
    lot_item = item(ctx, "lot")
    none_item = item(ctx, "none")
    expiry_item = item(ctx, "expiry")
    serial_item = item(ctx, "serial")
    undated = Cat.lot!(ctx.schema, expiry_item, "UL#{uniq()}").record_id
    foreign = Cat.lot!(ctx.schema, none_item, "FL#{uniq()}").record_id

    line = fn item_id, extra ->
      O.line(ctx.ma, Map.merge(%{"catalog_item_id" => item_id}, extra))
    end

    assert reasons(ctx, [
             line.(lot_item, %{}),
             line.(none_item, %{"catalog_lot_id" => foreign}),
             line.(expiry_item, %{"catalog_lot_id" => undated}),
             line.(serial_item, %{})
           ]) == [
             ["lot_required"],
             ["lot_not_allowed"],
             ["lot_expiry_missing"],
             ["tracking_policy_not_supported"]
           ]
  end

  test "O-CHK-6 lot_not_valid: a lot of another item", ctx do
    lot_item = item(ctx, "lot")
    other = item(ctx, "lot")
    foreign = Cat.lot!(ctx.schema, other, "FL#{uniq()}").record_id

    assert reasons(ctx, [
             O.line(ctx.ma, %{"catalog_item_id" => lot_item, "catalog_lot_id" => foreign})
           ]) ==
             [["lot_not_valid"]]
  end

  test "O-CHK-7 received_on_in_future, and a date today passes", ctx do
    tomorrow = Date.utc_today() |> Date.add(2) |> Date.to_iso8601()

    assert reasons(ctx, [
             O.line(ctx.ma, %{"received_on" => tomorrow}),
             O.line(ctx.ma, %{"received_on" => O.back(0)})
           ]) ==
             [["received_on_in_future"], []]
  end

  test "O-CHK-9 every failing line is reported, ok is false", ctx do
    {_doc, res} =
      check(ctx, [
        O.line(ctx.ma, %{"responsible_id" => Ecto.UUID.generate()}),
        O.line(ctx.ma),
        O.line(ctx.ma, %{"catalog_uom_id" => Ecto.UUID.generate()})
      ])

    assert res["ok"] == false

    assert Enum.map(res["lines"], &{&1["line_no"], &1["reasons"]}) ==
             [{1, ["employee_not_active"]}, {2, []}, {3, ["unit_not_valid"]}]
  end

  test "O-CHK-10 the reasons of one line come in the fixed order", ctx do
    {:ok, other} =
      Locations.create_node(
        ctx.schema,
        %{"code" => "Y#{uniq()}", "name" => "x", "node_kind" => "zone"},
        opts()
      )

    tomorrow = Date.utc_today() |> Date.add(2) |> Date.to_iso8601()
    other_uom = Cat.uom!(ctx.schema, "G#{uniq()}").record_id

    line =
      O.line(ctx.ma, %{
        "location_id" => other["record_id"],
        "responsible_id" => Ecto.UUID.generate(),
        "catalog_uom_id" => other_uom,
        "catalog_item_id" => item(ctx, "lot"),
        "received_on" => tomorrow
      })

    assert reasons(ctx, [line]) ==
             [
               [
                 "not_linked",
                 "employee_not_active",
                 "unit_not_valid",
                 "lot_required",
                 "received_on_in_future"
               ]
             ]
  end

  test "O-CHK-11 the check writes nothing: no write statement, no number, no version", ctx do
    doc = O.save!(ctx)
    test_pid = self()
    handler = "opening-check-" <> Ecto.UUID.generate()

    :telemetry.attach(
      handler,
      [:letflow, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == test_pid, do: send(test_pid, {:sql, to_string(metadata[:query])})
      end,
      nil
    )

    before = O.counts(ctx.schema)
    res = D.request(:post, "/documents/#{doc["id"]}/check", ctx.tok_a)
    :telemetry.detach(handler)
    assert res.status == 200

    statements = drain([])
    assert statements != []

    for sql <- statements do
      refute sql =~ ~r/\b(INSERT|UPDATE|DELETE)\b|FOR UPDATE|pg_advisory/i, sql
    end

    assert O.counts(ctx.schema) == before
    read = P.get!(ctx, doc["id"])
    assert read["state"] == "draft" and read["number"] == nil
  end

  defp drain(acc) do
    receive do
      {:sql, sql} -> drain([sql | acc])
    after
      0 -> acc
    end
  end

  test "O-CHK-12 an issued opening is 409 document_not_draft; a receipt is 422 unknown_kind",
       ctx do
    issued = O.issue!(ctx)
    json = D.request(:post, "/documents/#{issued["id"]}/check", ctx.tok_a) |> P.status!(409)
    assert json["reason"] == "document_not_draft"

    receipt = P.save!(ctx)
    json = D.request(:post, "/documents/#{receipt["id"]}/check", ctx.tok_a) |> P.status!(422)
    assert json["reason"] == "unknown_kind"
  end

  test "O-CHK-13 an item whose tracking lookup fails maps to tracking_invalid", ctx do
    assert Checks.tracking_result(ctx.schema, Ecto.UUID.generate(), nil) ==
             {:error, "tracking_invalid"}

    assert Checks.tracking_result(ctx.schema, ctx.ma.item, nil) == :ok
  end

  test "O-CHK-14 received_on is compared with the Asia/Almaty day of the clock", ctx do
    # 2026-06-15 20:30Z is 2026-06-16 01:30 in Almaty (UTC+5)
    fixed = ~U[2026-06-15 20:30:00Z]
    Application.put_env(:letflow, :stock_documents_clock, fn -> fixed end)

    assert reasons(ctx, [
             O.line(ctx.ma, %{"received_on" => "2026-06-16"}),
             O.line(ctx.ma, %{"received_on" => "2026-06-17"})
           ]) == [[], ["received_on_in_future"]]

    # an hour earlier in UTC the Almaty day is still the 15th (19:30Z -> 00:30 of the 16th? no: 14:30Z -> 19:30 15th)
    early = ~U[2026-06-15 14:30:00Z]
    Application.put_env(:letflow, :stock_documents_clock, fn -> early end)

    assert reasons(ctx, [
             O.line(ctx.ma, %{"received_on" => "2026-06-15"}),
             O.line(ctx.ma, %{"received_on" => "2026-06-16"})
           ]) == [[], ["received_on_in_future"]]
  end

  describe "issue" do
    test "O-ISS-1 a failing line refuses the issue with its reason and takes no number", ctx do
      body =
        O.body(ctx.ma, %{
          "lines" => [O.line(ctx.ma), O.line(ctx.ma, %{"responsible_id" => Ecto.UUID.generate()})]
        })

      doc = O.save!(ctx, body)
      json = D.request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_a) |> P.status!(422)
      assert json["reason"] == "employee_not_active" and json["line_no"] == 2
      read = P.get!(ctx, doc["id"])
      assert read["state"] == "draft" and read["number"] == nil
      assert P.counts(ctx, doc["id"]) == %{entries: %{}, marks: 0}
    end

    test "O-ISS-2 a receipt date 400 days back issues; number prefix OPN; a second issue is 409",
         ctx do
      doc = O.save!(ctx)
      issued = D.request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_a) |> P.status!(200)
      assert issued["state"] == "issued" and issued["kind"] == "opening"
      assert issued["number"] =~ ~r/\AOPN-\d{4}-000001\z/
      assert D.request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_a).status == 409
    end

    test "O-ISS-3 the issued content equals the saved header and lines field by field", ctx do
      doc = O.save!(ctx)
      D.request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_a) |> P.status!(200)
      %{content: content} = Posting.issued(ctx.schema, doc["id"])
      assert content["kind"] == "opening"
      assert content["header"] == %{"org_unit_id" => ctx.ma.unit, "note" => "migration stock"}
      assert Enum.map(content["lines"], & &1["line_no"]) == [1, 2]

      for {saved, frozen} <- Enum.zip(doc["lines"], content["lines"]) do
        for key <-
              ~w(location_id responsible_id catalog_item_id catalog_uom_id quantity received_on) do
          assert frozen[key] == saved[key], key
        end

        assert frozen["catalog_lot_id"] == saved["catalog_lot_id"]
      end

      refute Map.has_key?(content["header"], "event_time")
    end

    test "O-ISS-4 the numbers are gap-free across a refused issue", ctx do
      bad =
        O.save!(
          ctx,
          O.body(ctx.ma, %{
            "lines" => [O.line(ctx.ma, %{"responsible_id" => Ecto.UUID.generate()})]
          })
        )

      assert D.request(:post, "/documents/#{bad["id"]}/issue", ctx.tok_a).status == 422
      first = O.issue!(ctx)
      second = O.issue!(ctx)

      assert String.ends_with?(first["number"], "000001") and
               String.ends_with?(second["number"], "000002")

      assert Repo.aggregate(Letflow.Documents.Document, :count, :id, prefix: ctx.schema) >= 3
    end
  end
end
