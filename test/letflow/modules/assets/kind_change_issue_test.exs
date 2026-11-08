Code.require_file("kind_change_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.KindChangeIssueTest do
  @moduledoc """
  GH #3902 / REQ-759 (assets C15 part 2), criteria 3 and 4: the master checks at issue of a change of
  kind through the real `Letflow.Router` with an OIDC bearer (I1 one refusal per reason, I2 accepted
  lines, I3 the check order), and the issue itself (B1 numbered once, content equals the saved draft,
  no ledger entry, no card, one pending posting task; B2 reverse is 409 `document_not_posted`). Committed tenants,
  Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.AssetsFixture, as: Cards
  alias Letflow.CatalogItemsFixture, as: Cat
  alias Letflow.Documents.DocumentVersion
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.KindChangeFixture, as: K
  alias Letflow.Repo

  setup do
    ctx = D.setup!([:a])
    {:ok, Map.put(ctx, :ka, K.masters!(ctx.schema))}
  end

  defp at(seconds), do: DateTime.utc_now() |> DateTime.add(seconds) |> DateTime.to_iso8601()

  defp refuse!(ctx, body) do
    doc = D.save!(ctx, body)
    resp = D.request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_a) |> D.status!(422)
    after_doc = D.get!(ctx, doc["id"])
    assert after_doc["state"] == "draft" and after_doc["number"] == nil
    {resp["reason"], resp["field"], resp["side"], resp["line_no"]}
  end

  @tag timeout: 300_000
  test "I1 every refusal names its reason and extras; the draft stays a draft", ctx do
    m = ctx.ka
    uuid = fn -> Ecto.UUID.generate() end
    plain_lot = Cat.lot!(ctx.schema, m.item, "PLAIN#{System.unique_integer([:positive])}")
    Cards.card!(ctx.schema, "KC-TAKEN", %{"kind" => "fixed", "org_unit_id" => m.unit})

    Cards.card!(ctx.schema, "KC-RETIRED", %{
      "kind" => "fixed",
      "org_unit_id" => m.unit,
      "active" => false
    })

    line = &K.body(m, %{}, [K.line(m, &1)])

    cases = [
      {K.body(m, %{"event_time" => at(-97 * 3600)}), {"event_time_too_old", nil, nil, nil}},
      {K.body(m, %{"event_time" => at(600)}), {"event_time_in_future", nil, nil, nil}},
      {line.(%{"catalog_item_id" => uuid.()}), {"item_not_active", nil, nil, 1}},
      {line.(%{"catalog_uom_id" => uuid.()}), {"unit_not_valid", nil, nil, 1}},
      {line.(%{"catalog_lot_id" => m.lot}), {"lot_not_valid", nil, nil, 1}},
      {line.(%{"catalog_item_id" => m.lot_item}), {"lot_required", nil, nil, 1}},
      {line.(%{"catalog_lot_id" => plain_lot.record_id}), {"lot_not_allowed", nil, nil, 1}},
      {line.(%{"stock_location_id" => uuid.()}),
       {"location_not_active", "stock_location_id", nil, 1}},
      {line.(%{"asset_location_id" => uuid.()}),
       {"location_not_active", "asset_location_id", nil, 1}},
      {line.(%{"asset_org_unit_id" => uuid.()}),
       {"org_unit_not_active", "asset_org_unit_id", nil, 1}},
      {line.(%{"asset_org_unit_id" => m.non_unit}),
       {"org_unit_not_active", "asset_org_unit_id", nil, 1}},
      {line.(%{"stock_location_id" => m.other_location}), {"not_linked", nil, "stock", 1}},
      {line.(%{"asset_location_id" => m.other_location}), {"not_linked", nil, "asset", 1}},
      {line.(%{"stock_responsible_id" => uuid.()}),
       {"employee_not_active", "stock_responsible_id", nil, 1}},
      {line.(%{"material_responsible_id" => uuid.()}),
       {"employee_not_active", "material_responsible_id", nil, 1}},
      {line.(%{"actual_user_id" => uuid.()}), {"employee_not_active", "actual_user_id", nil, 1}},
      {line.(%{"quantity" => "0"}), {"quantity_invalid", nil, nil, 1}},
      {line.(%{"quantity" => "1.5"}), {"quantity_invalid", nil, nil, 1}},
      {line.(%{"quantity" => "2", "target_kind" => "fixed"}), {"quantity_invalid", nil, nil, 1}},
      {line.(%{"inventory_number" => "KC-TAKEN"}), {"inventory_number_taken", nil, nil, 1}},
      {line.(%{"inventory_number" => "KC-RETIRED"}), {"inventory_number_taken", nil, nil, 1}},
      {K.body(m, %{}, [
         K.line(m, %{"inventory_number" => "KC-DUP"}),
         K.line(m, %{"inventory_number" => "KC-DUP"})
       ]), {"inventory_number_taken", nil, nil, 2}}
    ]

    for {body, want} <- cases do
      assert refuse!(ctx, body) == want, inspect(want)
    end

    %{rows: [[entries]]} = Repo.query!(~s|SELECT count(*) FROM "#{ctx.schema}".ledger_entry|)
    assert entries == 0
  end

  test "I2 accepted: low value without actual user, fixed of one with a lot, another asset unit",
       ctx do
    m = ctx.ka

    lines = [
      K.line(m),
      K.line(m, %{
        "catalog_item_id" => m.lot_item,
        "catalog_lot_id" => m.lot,
        "quantity" => "1",
        "target_kind" => "fixed",
        "actual_user_id" => m.employee
      }),
      K.line(m, %{
        "asset_org_unit_id" => m.other_unit,
        "asset_location_id" => m.other_location,
        "material_responsible_id" => m.other_employee
      })
    ]

    issued = D.issue!(ctx, K.body(m, %{}, lines))
    assert issued["state"] == "issued" and length(issued["lines"]) == 3
  end

  test "I3 the first failing check wins: line 1 before line 2, item before unit", ctx do
    m = ctx.ka
    uuid = Ecto.UUID.generate()

    both = K.line(m, %{"catalog_item_id" => uuid, "catalog_uom_id" => Ecto.UUID.generate()})
    assert refuse!(ctx, K.body(m, %{}, [both])) == {"item_not_active", nil, nil, 1}

    late = K.line(m, %{"quantity" => "0"})
    early = K.line(m, %{"catalog_item_id" => uuid})
    assert refuse!(ctx, K.body(m, %{}, [late, early])) == {"quantity_invalid", nil, nil, 1}
    assert refuse!(ctx, K.body(m, %{}, [K.line(m), early])) == {"item_not_active", nil, nil, 2}
  end

  test "B1 a passing draft is issued once, numbered AKC, with its content; nothing is posted",
       ctx do
    m = ctx.ka

    cards_before =
      Repo.aggregate(
        from(r in Letflow.Entities.Record.Latest, where: r.entity_type == "assets_card"),
        :count,
        prefix: ctx.schema
      )

    saved = D.save!(ctx, K.body(m, %{"note" => "n1"}))
    issued = D.request(:post, "/documents/#{saved["id"]}/issue", ctx.tok_a) |> D.status!(200)

    assert issued["state"] == "issued" and issued["posting_check"] == nil
    assert issued["number"] =~ ~r/\AAKC-\d{4}-\d{6}\z/ and issued["issued_at"]
    assert issued["posted_at"] == nil and issued["entry_id"] == nil
    assert D.get!(ctx, saved["id"]) == issued

    versions =
      Repo.all(
        from(v in DocumentVersion, where: v.document_id == ^saved["id"] and v.status == :issued),
        prefix: ctx.schema
      )

    assert [version] = versions
    assert version.content["kind"] == "kind_change"
    assert version.content["header"]["org_unit_id"] == saved["org_unit_id"]
    assert version.content["header"]["note"] == "n1"
    assert length(version.content["lines"]) == length(saved["lines"])

    for {content, view} <- Enum.zip(version.content["lines"], saved["lines"]),
        {key, value} <- content do
      assert view[key] == value, key
    end

    assert D.counts(ctx, saved["id"]) == %{entries: %{}, marks: 0}

    cards_after =
      Repo.aggregate(
        from(r in Letflow.Entities.Record.Latest, where: r.entity_type == "assets_card"),
        :count,
        prefix: ctx.schema
      )

    assert cards_after == cards_before

    instances =
      Repo.aggregate(
        from(p in InstanceProjection,
          where: fragment("?->>'document_id' = ?", p.variables, ^saved["id"])
        ),
        :count,
        prefix: ctx.schema
      )

    # REQ-760: the issue now starts the posting instance (one pending `post` task); nothing is posted.
    assert instances == 1
    assert D.pending_task(ctx, saved["id"], "post") != nil

    again = D.request(:post, "/documents/#{saved["id"]}/issue", ctx.tok_a)
    assert D.status!(again, 409)["reason"] == "document_not_draft"
  end

  test "B2 reverse of an issued change of kind is 409 document_not_posted", ctx do
    issued = D.issue!(ctx, K.body(ctx.ka))

    conn =
      D.request(:post, "/documents/#{issued["id"]}/reverse", ctx.tok_a, %{
        "reason_code" => "wrong_document"
      })

    assert D.status!(conn, 409)["reason"] == "document_not_posted"
    assert D.get!(ctx, issued["id"])["state"] == "issued"
  end
end
