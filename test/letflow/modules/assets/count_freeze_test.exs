Code.require_file("counts_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.CountFreezeTest do
  @moduledoc """
  REQ-820 / GH #4371 (asset count K5): the freeze of the counted scope, through the full
  `Letflow.Router` with real OIDC bearer tokens. K5-F1/F2 (an issue in the scope is refused and takes no
  number, one outside is issued), K5-E1/E2/E3 (the freeze ends on signed, cancel and the limit), K5-N1/N2/N3
  (no freeze, drafts and an unopened order block nothing), K5-I1 (intangibles), K5-L1 (the set is fixed at
  open), K5-V1 (the view), K5-X1 (tenant isolation). Committed tenants, Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.AssetsCountsFixture, as: F
  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.AssetsRegisterFixture, as: S
  alias Letflow.Identity.User
  alias Letflow.Modules.Locations

  setup do
    ctx = D.setup!([:a, :b])
    F.enable!(ctx.schema)
    b = D.tenant_b!(ctx)
    F.enable!(b.b.schema_name)
    ctx = Map.merge(ctx, b)

    sub = "chair-k5-#{System.unique_integer([:positive])}"
    tok = S.token(ctx, :a, ["TENANT_ADMIN"], sub: sub)
    assert D.request(:get, "/counts", tok).status == 200
    user = Repo.one!(from(u in User, where: u.username == ^sub), prefix: ctx.schema).id
    m = ctx.ma
    chair = F.employee!(ctx.schema, m.unit, user)
    loc2 = D.location!(ctx.schema, m.unit)
    p = D.place!(ctx.schema)
    D.commission!(ctx, D.body(m))
    w = %{unit: m.unit, chair: chair, members: [], a: m.location}

    {:ok, Map.merge(ctx, %{chair_tok: tok, w: w, loc2: loc2, p: p})}
  end

  # An issued and opened count over the root `m.location`; returns the open answer.
  defp open_count!(ctx, extra) do
    created =
      D.request(:post, "/counts", ctx.chair_tok, F.input(ctx.w, F.window(extra)))
      |> D.status!(201)

    id = created["id"]
    D.request(:post, "/counts/#{id}/issue", ctx.chair_tok, %{}) |> D.status!(200)
    D.request(:post, "/counts/#{id}/open", ctx.chair_tok, %{}) |> D.status!(200)
  end

  defp freeze!(ctx, extra \\ %{}),
    do: open_count!(ctx, Map.merge(%{"freeze_locations" => true}, extra))

  defp handover(ctx, extra \\ %{}), do: D.handover_body(ctx.ma, ctx.p, extra)

  defp save!(ctx, body), do: D.request(:post, "/documents", ctx.tok_a, body) |> D.status!(201)
  defp issue(ctx, id), do: D.request(:post, "/documents/#{id}/issue", ctx.tok_a)

  defp assert_refused(ctx, id, order) do
    refused = issue(ctx, id) |> D.status!(422)
    assert %{"reason" => "count_in_progress", "held_by" => held} = refused
    assert held == order["number"]
    draft = D.get!(ctx, id)
    assert draft["state"] == "draft" and draft["number"] == nil
  end

  describe "criterion 1: the freeze refuses an issue in scope" do
    test "K5-F1: a hand over from the scope is refused, one outside is issued", ctx do
      order = freeze!(ctx)
      assert is_binary(order["number"])
      inside = save!(ctx, handover(ctx))
      assert_refused(ctx, inside["id"], order)

      outside = save!(ctx, handover(ctx, %{"from_location_id" => ctx.loc2}))
      assert %{"state" => "issued"} = issue(ctx, outside["id"]) |> D.status!(200)
    end

    test "K5-F2: the to side and a second kind are refused", ctx do
      order = freeze!(ctx)
      off = save!(ctx, D.writeoff_body(ctx.ma))
      assert_refused(ctx, off["id"], order)

      to_side =
        save!(ctx, D.body(ctx.ma, %{"lines" => [%{"asset_id" => ctx.ma.low, "quantity" => "1"}]}))

      assert_refused(ctx, to_side["id"], order)
    end
  end

  describe "criterion 2: the freeze ends" do
    test "K5-E1: signed ends the freeze", ctx do
      order = freeze!(ctx)
      doc = save!(ctx, handover(ctx))
      assert_refused(ctx, doc["id"], order)
      F.set_status!(ctx.schema, order["id"], "signed")
      assert %{"state" => "issued"} = issue(ctx, doc["id"]) |> D.status!(200)
    end

    test "K5-E2: a cancel ends the freeze", ctx do
      order = freeze!(ctx)
      doc = save!(ctx, handover(ctx))
      assert_refused(ctx, doc["id"], order)
      D.request(:post, "/counts/#{order["id"]}/cancel", ctx.chair_tok, %{}) |> D.status!(200)
      assert %{"state" => "issued"} = issue(ctx, doc["id"]) |> D.status!(200)
    end

    test "K5-E3: the limit ends the freeze, both sides of the boundary", ctx do
      F.put_setting!(ctx.schema, "count_freeze_limit_minutes", 1)
      order = freeze!(ctx)
      {:ok, cut_off, _} = DateTime.from_iso8601(order["cut_off_at"])
      {:ok, until, _} = DateTime.from_iso8601(order["freeze_until"])
      assert DateTime.diff(until, cut_off) == 60

      doc =
        save!(ctx, handover(ctx, %{"event_time" => DateTime.to_iso8601(cut_off)}))

      clock(DateTime.add(cut_off, 59))
      assert_refused(ctx, doc["id"], order)
      clock(DateTime.add(cut_off, 60))
      assert %{"state" => "issued"} = issue(ctx, doc["id"]) |> D.status!(200)
    end
  end

  describe "criterion 3: nothing else is blocked" do
    test "K5-N1: a count without the freeze blocks nothing", ctx do
      open_count!(ctx, %{"freeze_locations" => false})
      doc = save!(ctx, handover(ctx))
      assert %{"state" => "issued"} = issue(ctx, doc["id"]) |> D.status!(200)
    end

    test "K5-N2: save and replace of a draft in the scope succeed", ctx do
      freeze!(ctx)
      doc = save!(ctx, handover(ctx))

      D.request(:put, "/documents/#{doc["id"]}", ctx.tok_a, handover(ctx, %{"note" => "again"}))
      |> D.status!(200)
    end

    test "K5-N3: an ordered count that is not opened blocks nothing", ctx do
      created =
        D.request(
          :post,
          "/counts",
          ctx.chair_tok,
          F.input(ctx.w, F.window(%{"freeze_locations" => true}))
        )
        |> D.status!(201)

      D.request(:post, "/counts/#{created["id"]}/issue", ctx.chair_tok, %{}) |> D.status!(200)
      doc = save!(ctx, handover(ctx))
      assert %{"state" => "issued"} = issue(ctx, doc["id"]) |> D.status!(200)
    end
  end

  describe "edges" do
    test "K5-I1: intangibles are frozen only when the order counts them", ctx do
      m = ctx.ma
      body = D.body(m, %{"lines" => [%{"asset_id" => m.intangible, "quantity" => "1"}]})
      body = Map.delete(body, "location_id")

      order = freeze!(ctx, %{"kinds" => ["fixed", "intangible"]})
      doc = save!(ctx, body)
      assert_refused(ctx, doc["id"], order)
    end

    test "K5-I2: a count of fixed assets only leaves intangibles free", ctx do
      m = ctx.ma
      body = D.body(m, %{"lines" => [%{"asset_id" => m.intangible, "quantity" => "1"}]})
      body = Map.delete(body, "location_id")

      freeze!(ctx, %{"kinds" => ["fixed"]})
      doc = save!(ctx, body)
      assert %{"state" => "issued"} = issue(ctx, doc["id"]) |> D.status!(200)
    end

    test "K5-L1: a location created under the root after the open is not frozen", ctx do
      freeze!(ctx)
      n = System.unique_integer([:positive])
      wopts = %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}

      {:ok, node} =
        Locations.create_node(
          ctx.schema,
          %{
            "code" => "N#{n}",
            "name" => "N",
            "node_kind" => "zone",
            "parent_id" => ctx.ma.location
          },
          wopts
        )

      {:ok, _} =
        Locations.link_unit_location(
          ctx.schema,
          ctx.ma.unit,
          node["record_id"],
          %{wopts | idempotency_key: Ecto.UUID.generate()}
        )

      body =
        D.body(ctx.ma, %{
          "location_id" => node["record_id"],
          "lines" => [%{"asset_id" => ctx.ma.low, "quantity" => "1"}]
        })

      doc = save!(ctx, body)
      assert %{"state" => "issued"} = issue(ctx, doc["id"]) |> D.status!(200)
    end

    test "K5-V1: the order view shows the freeze state", ctx do
      created =
        D.request(
          :post,
          "/counts",
          ctx.chair_tok,
          F.input(ctx.w, F.window(%{"freeze_locations" => true}))
        )
        |> D.status!(201)

      id = created["id"]
      D.request(:post, "/counts/#{id}/issue", ctx.chair_tok, %{}) |> D.status!(200)
      assert get_order(ctx, id)["freeze_state"] == "none"

      D.request(:post, "/counts/#{id}/open", ctx.chair_tok, %{}) |> D.status!(200)
      view = get_order(ctx, id)
      assert view["freeze_state"] == "active" and is_binary(view["freeze_until"])
      refute Map.has_key?(view, "freeze_location_ids")

      D.request(:post, "/counts/#{id}/cancel", ctx.chair_tok, %{}) |> D.status!(200)
      assert get_order(ctx, id)["freeze_state"] == "ended"
    end
  end

  describe "tenant isolation" do
    test "K5-X1: tenant B neither sees nor is blocked by tenant A's freeze", ctx do
      order = freeze!(ctx)
      id = order["id"]
      assert D.request(:get, "/counts/#{id}", ctx.tok_b).status == 404
      assert D.request(:post, "/counts/#{id}/open", ctx.tok_b, %{}).status == 404

      pb = D.place!(ctx.b.schema_name)

      D.commission!(
        %{ctx | schema: ctx.b.schema_name, tok_a: ctx.tok_b, ma: ctx.mb},
        D.body(ctx.mb)
      )

      doc =
        D.request(:post, "/documents", ctx.tok_b, D.handover_body(ctx.mb, pb)) |> D.status!(201)

      assert %{"state" => "issued"} =
               D.request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_b) |> D.status!(200)
    end
  end

  defp get_order(ctx, id), do: D.request(:get, "/counts/#{id}", ctx.chair_tok) |> D.status!(200)

  defp clock(at), do: Application.put_env(:letflow, :assets_documents_clock, fn -> at end)
end
