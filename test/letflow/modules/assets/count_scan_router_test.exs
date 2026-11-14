Code.require_file("counts_fixture.exs", __DIR__)
Code.require_file("../codes/codes_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.CountScanRouterTest do
  @moduledoc """
  REQ-818 / GH #4373 (asset count K3) through the full `Letflow.Router` with real OIDC bearer tokens:
  K3-RT1 (a scan life), K3-RT2 (cross tenant, INV-10), K3-RT3 (permission), K3-RT4 (the flag).
  Committed tenants, Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.AssetsCountsFixture, as: F
  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.AssetsRegisterFixture, as: S
  alias Letflow.CodesFixture, as: K
  alias Letflow.Identity.User
  alias Letflow.Modules.Assets.Counts
  alias Letflow.Modules.ReadApi

  setup do
    ctx = D.setup!([:a, :b, :n])
    n = S.tenant!("ast-ck3n", ctx.names.n, install: false)
    F.enable!(ctx.schema)
    b = D.tenant_b!(ctx)
    F.enable!(b.b.schema_name)
    {:ok, Map.merge(ctx, Map.merge(b, %{n: n, tok_n: S.token(ctx, :n, ["TENANT_ADMIN"])}))}
  end

  defp strip(conn) do
    case Jason.decode(conn.resp_body) do
      {:ok, %{} = map} -> Map.delete(map, "trace_id")
      _ -> conn.resp_body
    end
  end

  defp user_token(ctx, sub) do
    tok = S.token(ctx, :a, ["TENANT_ADMIN"], sub: sub)
    assert D.request(:get, "/counts", tok).status == 200
    {tok, Repo.one!(from(u in User, where: u.username == ^sub), prefix: ctx.schema).id}
  end

  defp code!(s, type, target) do
    value = "C-#{System.unique_integer([:positive])}"
    tag = K.tag!(s, value, %{"status" => "assigned"})
    K.assign!(s, tag, type, target)
    value
  end

  defp number(s, card) do
    {:ok, c} = ReadApi.lookup(s, card, ["assets_card"])
    c["inventory_number"]
  end

  # A counting count of tenant A through the routes; returns its id and the tokens.
  defp counting!(ctx) do
    s = ctx.schema
    m = ctx.ma
    {chair_tok, chair_user} = user_token(ctx, "chair-k3")
    {member_tok, member_user} = user_token(ctx, "member-k3")
    chair = F.employee!(s, m.unit, chair_user)
    member = F.employee!(s, m.unit, member_user)
    D.commission!(ctx, D.body(m))
    loc2 = D.location!(s, m.unit)

    w = %{unit: m.unit, chair: chair, members: [member], a: m.location}
    input = F.input(w, F.window(%{"location_ids" => [m.location, loc2]}))
    id = D.request(:post, "/counts", chair_tok, input) |> D.status!(201) |> Map.get("id")
    D.request(:post, "/counts/#{id}/issue", chair_tok, %{}) |> D.status!(200)
    D.request(:post, "/counts/#{id}/open", chair_tok, %{}) |> D.status!(200)
    %{id: id, chair_tok: chair_tok, member_tok: member_tok, loc2: loc2}
  end

  defp scan(ctx, c, text, tok \\ nil),
    do: D.request(:post, "/counts/#{c.id}/scan", tok || c.member_tok, %{"text" => text})

  test "K3-RT1: a location, a number twice, unknown and out of scope, through the router", ctx do
    s = ctx.schema
    c = counting!(ctx)
    loc_code = code!(s, "location_node", c.loc2)

    assert %{"outcome" => "location_set", "location_id" => loc} =
             scan(ctx, c, loc_code) |> D.status!(200)

    assert loc == c.loc2

    n = number(s, ctx.ma.fixed)

    assert %{"outcome" => "counted", "line" => %{"observed_location_id" => ^loc}} =
             scan(ctx, c, n) |> D.status!(200)

    assert %{"outcome" => "already_counted"} = scan(ctx, c, n) |> D.status!(200)

    outside = code!(s, "location_node", D.location!(s, ctx.ma.unit))
    unknown = scan(ctx, c, "NO-SUCH-TEXT-1")
    foreign = scan(ctx, c, outside)
    assert unknown.status == 422 and foreign.status == 422
    assert %{"reason" => "unknown_code"} = Jason.decode!(unknown.resp_body)
    assert strip(unknown) == strip(foreign)

    item = scan(ctx, c, code!(s, "catalog_item", Ecto.UUID.generate()))
    assert item.status == 422 and Jason.decode!(item.resp_body)["reason"] == "not_countable_here"

    assert %{"rows" => rows} =
             D.request(:get, "/counts/#{c.id}/entries", c.member_tok) |> D.status!(200)

    assert Enum.all?(rows, &(&1["method"] == "scan"))
    assert Enum.map(rows, & &1["scan_outcome"]) == ["location_set", "counted", "already_counted"]
  end

  test "K3-RT2: tenant A's member cannot scan tenant B's count, B is unchanged", ctx do
    sb = ctx.b.schema_name
    chair_b = F.employee!(sb, ctx.mb.unit, Ecto.UUID.generate())
    w = %{unit: ctx.mb.unit, chair: chair_b, members: [], a: ctx.mb.location}
    {:ok, %{"id" => b_id}} = Counts.create(sb, F.input(w, F.window()), F.opts())
    {:ok, _} = Counts.issue(sb, b_id, F.opts())

    body = %{"text" => number(sb, ctx.mb.fixed)}
    unknown = D.request(:post, "/counts/#{Ecto.UUID.generate()}/scan", ctx.tok_a, body)
    foreign = D.request(:post, "/counts/#{b_id}/scan", ctx.tok_a, body)
    assert unknown.status == 404 and foreign.status == 404
    assert strip(foreign) == strip(unknown)

    assert D.request(:get, "/counts/#{b_id}/entries", ctx.tok_b)
           |> D.status!(200)
           |> Map.get("rows") ==
             []
  end

  test "K3-RT3: a TASK_WORKER is refused 403", ctx do
    worker = S.token(ctx, :a, ["TASK_WORKER"], sub: "worker-k3")
    id = Ecto.UUID.generate()
    assert D.request(:post, "/counts/#{id}/scan", worker, %{"text" => "X"}).status == 403
  end

  test "K3-RT4: with the flag off the scan answers the 404 of a tenant without the module", ctx do
    F.disable!(ctx.schema)
    path = "/counts/#{Ecto.UUID.generate()}/scan"
    mine = D.request(:post, path, ctx.tok_a, %{"text" => "X"})
    theirs = D.request(:post, path, ctx.tok_n, %{"text" => "X"})
    assert mine.status == 404 and theirs.status == 404
    assert strip(mine) == strip(theirs)
  end
end
