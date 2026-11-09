Code.require_file("assets/documents_fixture.exs", __DIR__)

defmodule Letflow.Modules.AssetDocumentsScopedReadTest do
  @moduledoc """
  T-1534 (design S6a): a reader granted on one org unit U1 cannot read REAL assets documents. The tenant holds a
  draft document for U1 and one for U2 (each with a line, a location and an employee). A tenant-wide reader (control, read before the grants are narrowed) gets both from `GET /documents` and `GET /documents/:id`, so the refusal below is not
  vacuous; the U1-scoped reader gets the same 404 for the real ids as for an unknown id, and neither the list nor
  the by-id answer carries a line, location or employee value. `async: false`, committed tenant, Sandbox `:auto`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.Identity.User
  alias Letflow.AssetsRegisterFixture, as: S
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG

  setup do
    ctx = D.setup!([:a])
    m2 = D.masters!(ctx.schema)
    schema = ctx.schema

    d1 = D.save!(ctx)
    d2 = D.save!(ctx, D.body(m2))

    # control: the tenant-wide reader, read BEFORE the grants are narrowed
    list = D.request(:get, "/documents", ctx.tok_a) |> D.status!(200)
    gets = for d <- [d1, d2], do: D.get!(ctx, d["id"])

    t1 = S.token(ctx, :a, ["TENANT_ADMIN"], sub: "doc-reader-u1")
    D.request(:get, "/documents", t1)

    _ = RSG.raw_delete_rows!(schema, RSG.group_of!(schema, "TENANT_ADMIN"), "TENANT_ADMIN")
    user = Repo.one!(from(u in User, where: u.username == "doc-reader-u1"), prefix: schema)
    :ok = RSG.raw_user_row!(schema, user.id, "TENANT_ADMIN", ctx.ma.unit)

    {:ok, Map.merge(ctx, %{m2: m2, d1: d1, d2: d2, t1: t1, list: list, gets: gets})}
  end

  defp strip(body), do: Map.delete(body, "trace_id")

  test "S6a control: the tenant-wide reader sees both real documents and their lines", ctx do
    assert resp_text(ctx.list) =~ ctx.d1["id"] and resp_text(ctx.list) =~ ctx.d2["id"]

    for {got, m} <- Enum.zip(ctx.gets, [ctx.ma, ctx.m2]) do
      assert got["location_id"] == m.location
      assert [%{"asset_id" => asset}] = got["lines"]
      assert asset == m.fixed
    end
  end

  test "S6a a U1-scoped reader gets the unknown-id 404 for real documents, no values", ctx do
    unknown =
      D.request(:get, "/documents/#{Ecto.UUID.generate()}", ctx.t1) |> D.status!(404) |> strip()

    for doc <- [ctx.d1, ctx.d2] do
      conn = D.request(:get, "/documents/#{doc["id"]}", ctx.t1)
      assert D.status!(conn, 404) |> strip() == unknown
    end

    list = D.request(:get, "/documents", ctx.t1)
    assert list.status == 404
    assert strip(Jason.decode!(list.resp_body)) == unknown

    leaked =
      [ctx.ma, ctx.m2] |> Enum.flat_map(&[&1.location, &1.employee, &1.employee2, &1.fixed])

    for conn <- [D.request(:get, "/documents/#{ctx.d1["id"]}", ctx.t1), list],
        value <- leaked ++ [ctx.d1["id"], ctx.d2["id"]] do
      refute conn.resp_body =~ value, "scoped answer leaks #{value}"
    end
  end

  defp resp_text(body), do: Jason.encode!(body)
end
