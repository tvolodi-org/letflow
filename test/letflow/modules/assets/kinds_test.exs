Code.require_file("documents_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.KindsTest do
  @moduledoc """
  GH #3889 / REQ-753 (assets C11): save, replace, list and the issue checks of the change, hand over
  and write off documents through the full `Letflow.Router` with real OIDC bearer tokens. Tests: K1
  save and list, K2 replace, K3 every issue refusal (nothing issued, no number), N1 the INV-10
  cross-tenant negatives, S1 the scoped caller and an API token. Committed tenants, Sandbox `:auto`,
  `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.AssetsRegisterFixture, as: S
  alias Letflow.Identity.User
  alias Letflow.Modules.Installs
  alias Letflow.Repo
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG

  @moduletag timeout: 240_000

  setup do
    ctx = D.setup!([:a, :b, :s])
    {:ok, Map.merge(ctx, D.tenant_b!(ctx))}
  end

  defp reason(conn, status), do: conn |> D.status!(status) |> Map.fetch!("reason")
  defp strip(body), do: Map.delete(body, "trace_id")

  defp bodies(ctx) do
    to = D.place!(ctx.schema)
    [D.change_body(ctx.ma), D.handover_body(ctx.ma, to), D.writeoff_body(ctx.ma)]
  end

  # issue answers 422 with `want` and `extras`; nothing is issued, no number is taken
  defp refused!(ctx, body, want, extras \\ %{}) do
    doc = D.save!(ctx, body)
    before = D.written(ctx.schema)
    conn = D.request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_a)
    json = D.status!(conn, 422)
    assert json["reason"] == want, inspect({want, json})
    for {k, v} <- extras, do: assert(json[k] == v, inspect({k, json}))
    assert D.get!(ctx, doc["id"])["state"] == "draft"
    assert D.get!(ctx, doc["id"])["number"] == nil
    assert D.written(ctx.schema) == before
  end

  describe "K1 save, K2 replace" do
    test "each kind is saved as a draft, listed by kind, and replaced as a whole", ctx do
      for body <- bodies(ctx) do
        kind = body["kind"]
        doc = D.save!(ctx, body)
        assert doc["kind"] == kind and doc["state"] == "draft" and doc["number"] == nil

        for {key, value} <- Map.drop(body, ["kind", "lines", "event_time"]) do
          assert doc[key] == value, "#{kind} #{key}"
        end

        list = D.request(:get, "/documents?kind=#{kind}", ctx.tok_a) |> D.status!(200)
        assert Enum.map(list["rows"], & &1["id"]) == [doc["id"]]

        # replace: the whole body, so an omitted optional key is gone
        replaced = Map.delete(body, "note")

        again =
          D.request(:put, "/documents/#{doc["id"]}", ctx.tok_a, replaced) |> D.status!(200)

        assert again["id"] == doc["id"] and length(again["lines"]) == 1

        other = Map.put(body, "org_unit_id", D.unit!(ctx.schema))

        assert reason(D.request(:put, "/documents/#{doc["id"]}", ctx.tok_a, other), 422) ==
                 "field_invalid"
      end
    end

    test "a write off keeps its reason; a reason is refused at save", ctx do
      body = D.writeoff_body(ctx.ma, %{"reason_code" => "other", "reason_text" => "scrapped"})
      doc = D.save!(ctx, body)
      assert doc["reason_code"] == "other" and doc["reason_text"] == "scrapped"

      before = D.written(ctx.schema)

      assert reason(
               D.request(
                 :post,
                 "/documents",
                 ctx.tok_a,
                 D.writeoff_body(ctx.ma, %{"reason_code" => "x"})
               ),
               422
             ) ==
               "reason_invalid"

      assert reason(
               D.request(
                 :post,
                 "/documents",
                 ctx.tok_a,
                 D.writeoff_body(ctx.ma, %{"reason_code" => "other"})
               ),
               422
             ) ==
               "reason_required"

      assert D.written(ctx.schema) == before
    end
  end

  describe "K3 issue refusals" do
    test "sides_equal, inactive masters and the location rules", ctx do
      m = ctx.ma
      to = D.place!(ctx.schema)
      ghost = Ecto.UUID.generate()

      refused!(
        ctx,
        D.change_body(m, %{
          "to_material_responsible_id" => m.employee,
          "to_actual_user_id" => m.employee2
        }),
        "sides_equal"
      )

      same_place = %{unit: m.unit, location: m.location, employee: to.employee}
      refused!(ctx, D.handover_body(m, same_place), "sides_equal")

      refused!(ctx, D.handover_body(m, %{to | unit: ghost}), "org_unit_not_active", %{
        "field" => "to_org_unit_id"
      })

      for {key, body} <- [
            {"from_material_responsible_id",
             D.change_body(m, %{"from_material_responsible_id" => ghost})},
            {"from_actual_user_id", D.change_body(m, %{"from_actual_user_id" => ghost})},
            {"to_material_responsible_id",
             D.change_body(m, %{"to_material_responsible_id" => ghost})},
            {"to_actual_user_id", D.change_body(m, %{"to_actual_user_id" => ghost})},
            {"material_responsible_id", D.writeoff_body(m, %{"material_responsible_id" => ghost})}
          ] do
        refused!(ctx, body, "employee_not_active", %{"field" => key})
      end

      # a location of the other place is not linked to the unit
      refused!(ctx, D.change_body(m, %{"location_id" => to.location}), "not_linked", %{
        "line_no" => 1
      })

      refused!(ctx, D.handover_body(m, %{to | location: m.location}), "not_linked", %{
        "side" => "to",
        "line_no" => 1
      })

      refused!(ctx, D.handover_body(m, to, %{"from_location_id" => to.location}), "not_linked", %{
        "side" => "from"
      })

      # a fixed card needs a location on each side, an intangible one must have none
      refused!(ctx, D.writeoff_body(m, %{"location_id" => ""}), "location_required")

      refused!(ctx, D.handover_body(m, %{to | location: ""}), "location_required", %{
        "side" => "to"
      })

      intangible = [%{"asset_id" => m.intangible, "quantity" => "1"}]
      refused!(ctx, D.writeoff_body(m, %{"lines" => intangible}), "location_not_allowed")

      refused!(
        ctx,
        D.handover_body(m, to, %{"lines" => intangible, "from_location_id" => ""}),
        "location_not_allowed",
        %{"side" => "to"}
      )
    end

    test "line refusals and the event time", ctx do
      m = ctx.ma
      card = &[%{"asset_id" => &1, "quantity" => &2}]

      refused!(ctx, D.change_body(m, %{"lines" => card.(m.fixed, "2")}), "quantity_invalid", %{
        "line_no" => 1
      })

      refused!(ctx, D.writeoff_body(m, %{"lines" => card.(m.low, "1.5")}), "quantity_invalid")
      refused!(ctx, D.writeoff_body(m, %{"lines" => card.(m.low, "0")}), "quantity_invalid")

      refused!(
        ctx,
        D.change_body(m, %{"lines" => card.(Ecto.UUID.generate(), "1")}),
        "card_not_active"
      )

      refused!(
        ctx,
        D.writeoff_body(m, %{"lines" => card.(m.fixed, "1") ++ card.(m.fixed, "1")}),
        "duplicate_asset",
        %{"line_no" => 2}
      )

      retired = D.card!(ctx.schema, "fixed", m.unit)

      D.request(:post, "/cards/#{retired}/retire", ctx.tok_a, %{
        "idempotency_key" => Ecto.UUID.generate()
      })
      |> D.status!(200)

      refused!(ctx, D.change_body(m, %{"lines" => card.(retired, "1")}), "card_not_active")

      old = DateTime.utc_now() |> DateTime.add(-100 * 3600) |> DateTime.to_iso8601()
      soon = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
      refused!(ctx, D.change_body(m, %{"event_time" => old}), "event_time_too_old")
      refused!(ctx, D.writeoff_body(m, %{"event_time" => soon}), "event_time_in_future")
    end

    test "a card whose unit differs, and a held fixed asset, are not refused for the new kinds",
         ctx do
      m = ctx.ma
      other = D.place!(ctx.schema)
      foreign_unit_card = D.card!(ctx.schema, "fixed", other.unit)

      body =
        D.writeoff_body(m, %{"lines" => [%{"asset_id" => foreign_unit_card, "quantity" => "1"}]})

      doc = D.issue!(ctx, body)
      assert doc["state"] == "issued"
    end
  end

  describe "N1 INV-10 cross-tenant" do
    test "tenant B's masters are refused in tenant A and nothing is written", ctx do
      foreign = ctx.mb
      to = %{unit: foreign.unit, location: ctx.ma.location, employee: ctx.ma.employee}

      refused!(ctx, D.handover_body(ctx.ma, to), "org_unit_not_active", %{
        "field" => "to_org_unit_id"
      })

      refused!(
        ctx,
        D.handover_body(ctx.ma, %{
          to
          | unit: ctx.ma.unit,
            employee: foreign.employee,
            location: D.location!(ctx.schema, ctx.ma.unit)
        }),
        "employee_not_active",
        %{"field" => "to_material_responsible_id"}
      )

      refused!(
        ctx,
        D.writeoff_body(ctx.ma, %{"lines" => [%{"asset_id" => foreign.fixed, "quantity" => "1"}]}),
        "card_not_active"
      )

      before_b = D.written(ctx.b.schema_name)
      %{rows: [[n]]} = Repo.query!(~s|SELECT count(*) FROM "#{ctx.b.schema_name}".ledger_entry|)
      assert n == 0
      assert D.written(ctx.b.schema_name) == before_b
    end

    test "tenant B cannot read, replace, discard, issue or reverse A's new documents", ctx do
      for body <- bodies(ctx) do
        id = D.save!(ctx, body)["id"]
        before = D.written(ctx.b.schema_name)

        for {m, p, b} <- [
              {:get, "/documents/#{id}", nil},
              {:put, "/documents/#{id}", D.writeoff_body(ctx.mb)},
              {:delete, "/documents/#{id}", nil},
              {:post, "/documents/#{id}/issue", nil},
              {:post, "/documents/#{id}/reverse", %{"reason_code" => "wrong_document"}}
            ] do
          D.request(m, p, ctx.tok_b, b) |> D.status!(404)
        end

        assert D.written(ctx.b.schema_name) == before
        assert D.get!(ctx, id)["state"] == "draft"
      end
    end
  end

  describe "S1 scope" do
    test "a scoped TENANT_ADMIN cannot save, issue or reverse the new kinds", ctx do
      t = S.tenant!("ast-ds", ctx.names.s, install: false)
      {:ok, _} = Letflow.Entities.EventTypes.seed!(t.schema_name)
      on_exit(fn -> S.drop_pack_rows!(t.tenant_id) end)

      for m <- ["org", "catalog_items", "locations", "codes", "stock", "assets"] do
        {:ok, _} =
          Installs.install(m, Ecto.UUID.generate(),
            prefix: t.schema_name,
            rationale: "test: REQ-753"
          )
      end

      scoped = S.token(ctx, :s, ["TENANT_ADMIN"], sub: "scoped-kinds")
      D.request(:get, "/documents", scoped)

      user =
        Repo.one!(from(u in User, where: u.username == "scoped-kinds"), prefix: t.schema_name)

      _ =
        RSG.raw_delete_rows!(
          t.schema_name,
          RSG.group_of!(t.schema_name, "TENANT_ADMIN"),
          "TENANT_ADMIN"
        )

      :ok = RSG.raw_user_row!(t.schema_name, user.id, "TENANT_ADMIN", RSG.node!(t.schema_name))

      before = D.written(t.schema_name)

      for body <- bodies(ctx) do
        id = Ecto.UUID.generate()
        first = D.request(:post, "/documents", scoped, body) |> D.status!(404) |> strip()

        for {method, path, b} <- [
              {:post, "/documents/#{id}/issue", nil},
              {:post, "/documents/#{id}/reverse", %{"reason_code" => "wrong_document"}}
            ] do
          assert D.request(method, path, scoped, b) |> D.status!(404) |> strip() == first
        end
      end

      assert D.written(t.schema_name) == before
      %{rows: [[n]]} = Repo.query!(~s|SELECT count(*) FROM "#{t.schema_name}".ledger_entry|)
      assert n == 0
    end
  end
end
