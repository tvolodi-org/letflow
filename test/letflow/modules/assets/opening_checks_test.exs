Code.require_file("documents_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.OpeningChecksTest do
  @moduledoc """
  GH #4037 (assets G5 part 1): the checks of the asset opening document through the full router.
  C2 every reason per line, I1 the first failure at issue, O1/O2 the "once" rule between commission and
  opening documents, O3 the low-value split. Committed tenant, Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.OrgFixture

  @moduletag timeout: 240_000

  setup do
    D.setup!()
  end

  defp line(ctx, asset, extra \\ %{}), do: D.opening_line(ctx.ma, asset, extra)

  defp draft!(ctx, lines, extra \\ %{}),
    do: D.save!(ctx, D.opening_body(ctx.ma, Map.put(extra, "lines", lines)))

  defp check!(ctx, doc),
    do: D.request(:post, "/documents/#{doc["id"]}/check", ctx.tok_a) |> D.status!(200)

  defp reasons(json), do: Enum.map(json["lines"], & &1["reasons"])

  defp inactive_employee!(ctx) do
    OrgFixture.create!(
      ctx.schema,
      "org_employee",
      OrgFixture.values("org_employee", "RET#{System.unique_integer([:positive])}", %{
        "org_unit_id" => ctx.ma.unit,
        "active" => false
      })
    ).record_id
  end

  test "C2 each reason is reported on its own line, all lines are checked", ctx do
    m = ctx.ma
    other_unit = D.unit!(ctx.schema)
    foreign = D.card!(ctx.schema, "fixed", other_unit)
    retired = D.card!(ctx.schema, "fixed", m.unit, %{"active" => false})
    unlinked = D.location!(ctx.schema, other_unit)
    retired_employee = inactive_employee!(ctx)

    lines = [
      line(ctx, retired),
      line(ctx, m.fixed, %{"quantity" => "2"}),
      line(ctx, m.fixed2, %{"location_id" => ""}),
      line(ctx, m.intangible),
      line(ctx, foreign),
      line(ctx, m.low, %{"location_id" => unlinked}),
      line(ctx, m.low, %{"material_responsible_id" => retired_employee}),
      line(ctx, Ecto.UUID.generate()),
      line(ctx, m.low, %{"quantity" => "1.5"})
    ]

    json = check!(ctx, draft!(ctx, lines))
    assert json["ok"] == false and json["header"] == []

    assert reasons(json) == [
             ["card_not_active"],
             ["quantity_invalid"],
             ["location_required"],
             ["location_not_allowed"],
             ["org_unit_mismatch"],
             ["not_linked"],
             ["employee_not_active"],
             ["card_not_active"],
             ["quantity_invalid"]
           ]

    assert Enum.at(json["lines"], 6)["fields"] == ["material_responsible_id"]
    assert Enum.map(json["lines"], & &1["line_no"]) == Enum.to_list(1..9)
  end

  test "C2 an inactive actual user names its own field; an inactive org unit is a header reason",
       ctx do
    retired_employee = inactive_employee!(ctx)
    doc = draft!(ctx, [line(ctx, ctx.ma.fixed, %{"actual_user_id" => retired_employee})])
    json = check!(ctx, doc)

    assert [%{"reasons" => ["employee_not_active"], "fields" => ["actual_user_id"]}] =
             json["lines"]

    # a unit without staff is retired after the draft is saved: the header reason
    unit = D.unit!(ctx.schema)
    card = D.card!(ctx.schema, "fixed", unit)
    place = Map.put(ctx.ma, :unit, unit)
    doc2 = D.save!(ctx, D.opening_body(place, %{"lines" => [line(ctx, card)]}))

    {:ok, _} =
      Letflow.Modules.Org.retire_unit(ctx.schema, unit, %{
        actor_id: Ecto.UUID.generate(),
        idempotency_key: Ecto.UUID.generate()
      })

    assert check!(ctx, doc2)["header"] == ["org_unit_not_active"]
  end

  test "I1 issue refuses with the first failing line's reason, line_no and field", ctx do
    m = ctx.ma
    retired_employee = inactive_employee!(ctx)

    doc =
      draft!(ctx, [
        line(ctx, m.fixed),
        line(ctx, m.low, %{"actual_user_id" => retired_employee})
      ])

    before = D.written(ctx.schema)
    json = D.request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_a) |> D.status!(422)

    assert json["reason"] == "employee_not_active"
    assert json["line_no"] == 2 and json["field"] == "actual_user_id"
    assert D.get!(ctx, doc["id"])["state"] == "draft"
    assert D.get!(ctx, doc["id"])["number"] == nil
    assert D.written(ctx.schema) == before
  end

  test "O3 low value may be split over placements; the same placement and a repeated fixed card are duplicates",
       ctx do
    m = ctx.ma
    place2 = D.location!(ctx.schema, m.unit)

    split = draft!(ctx, [line(ctx, m.low), line(ctx, m.low, %{"location_id" => place2})])
    assert reasons(check!(ctx, split)) == [[], []]

    same = draft!(ctx, [line(ctx, m.low), line(ctx, m.low)])
    assert reasons(check!(ctx, same)) == [[], ["duplicate_asset"]]

    fixed = draft!(ctx, [line(ctx, m.fixed), line(ctx, m.fixed, %{"location_id" => place2})])
    assert reasons(check!(ctx, fixed)) == [[], ["duplicate_asset"]]
  end

  test "O1 once: an issued commission holds a fixed card until its reversal mark", ctx do
    m = ctx.ma
    commission = D.issue!(ctx)
    draft = draft!(ctx, [line(ctx, m.fixed)])
    assert reasons(check!(ctx, draft)) == [["asset_already_in_register"]]

    D.mark_reversed!(ctx, commission["id"], "assets_commission", m.unit)
    assert reasons(check!(ctx, draft)) == [[]]
  end

  test "O1 once: an issued opening holds a low-value card; a draft commission and a draft opening do not",
       ctx do
    m = ctx.ma
    D.save!(ctx, D.body(m, %{"lines" => [%{"asset_id" => m.low, "quantity" => "1"}]}))
    other_draft = draft!(ctx, [line(ctx, m.low)])
    assert reasons(check!(ctx, other_draft)) == [[]]

    opening = draft!(ctx, [line(ctx, m.low)])
    D.issue_directly!(ctx, opening["id"])
    assert reasons(check!(ctx, other_draft)) == [["asset_already_in_register"]]

    D.mark_reversed!(ctx, opening["id"], "assets_opening", m.unit)
    assert reasons(check!(ctx, other_draft)) == [[]]
  end

  test "O2 once, commission side: a commission naming a fixed card held by an issued opening is refused",
       ctx do
    m = ctx.ma
    opening = draft!(ctx, [line(ctx, m.fixed)])
    D.issue_directly!(ctx, opening["id"])

    doc = D.save!(ctx)
    json = D.request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_a) |> D.status!(422)
    assert json["reason"] == "asset_already_in_register" and json["line_no"] == 1
    assert D.get!(ctx, doc["id"])["state"] == "draft"
  end
end
