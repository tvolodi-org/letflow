Code.require_file("register_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.StorekeeperAssetsTest do
  @moduledoc """
  C19 / D-097 (GH #3893 follow-up, plan key C19): the STOREKEEPER role reads and posts assets
  (`AssetsRead`, `AssetsPost`), through the `assets` manifest `role_grants`; `AssetsReverse`,
  `AssetsReconcile` and `AssetsCardWrite` stay with the administrators. SA-1 is pure; SA-2..SA-5 go
  through the full `Letflow.Router` with real OIDC bearer tokens on committed tenants (Sandbox `:auto`).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Api.Authorization
  alias Letflow.AssetsRegisterFixture, as: S
  alias Letflow.Identity.User
  alias Letflow.ScopeNodePaths
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG

  @a1 "11111111-1111-4111-8111-111111111111"
  @a2 "12121212-1212-4212-8212-121212121212"
  @u1 "44444444-4444-4444-8444-444444444444"
  @u2 "46464646-4646-4646-8646-464646464646"
  @p "47474747-4747-4747-8747-474747474747"
  @l1 "33333333-3333-4333-8333-333333333333"
  @r1 "55555555-5555-4555-8555-555555555555"

  @granted [:AssetsRead, :AssetsPost]
  @withheld [:AssetsReverse, :AssetsReconcile, :AssetsCardWrite]

  test "SA-1 the role matrix: storekeeper reads and posts; the administrators hold all five" do
    for p <- @granted, do: assert(Authorization.role_allows?(:STOREKEEPER, p), inspect(p))
    for p <- @withheld, do: refute(Authorization.role_allows?(:STOREKEEPER, p), inspect(p))

    for role <- [:TENANT_ADMIN, :PLATFORM_ADMIN], p <- @granted ++ @withheld do
      assert Authorization.role_allows?(role, p), "#{role} #{p}"
    end
  end

  setup do
    ctx = S.setup_oidc!([:a, :b, :s])
    a = S.tenant!("sk-a", ctx.names.a)
    b = S.tenant!("sk-b", ctx.names.b)

    Map.merge(ctx, %{
      a: a,
      b: b,
      sk_a: S.token(ctx, :a, ["STOREKEEPER"], sub: "sk-a"),
      sk_b: S.token(ctx, :b, ["STOREKEEPER"], sub: "sk-b")
    })
  end

  defp seed!(schema) do
    here = S.side(@u1, @r1, %{location: @l1})

    S.post!(schema, "commission", %{
      document_type: "commission_doc",
      document_id: "doc-1",
      lines: [S.line(@a1, "3", %{to: here})]
    })

    S.post!(schema, "commission", %{
      document_id: "doc-2",
      lines: [S.line(@a2, "2", %{to: S.side(@u2, @r1)})]
    })
  end

  defp call(method, path, token, body \\ %{}) do
    Plug.Test.conn(method, S.base() <> path, Jason.encode!(body))
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  test "SA-2 the storekeeper reads the register and documents, and passes the post gate", ctx do
    seed!(ctx.a.schema_name)

    for path <- ["/balances", "/movements", "/documents"] do
      conn = S.get(path, ctx.sk_a)
      assert conn.status == 200, "#{path}: #{conn.status} #{conn.resp_body}"
    end

    assert length(S.json(S.get("/balances", ctx.sk_a))["rows"]) == 2

    # an empty body is refused for its content, never for the caller's permission
    for {method, path} <- [{:post, "/documents"}, {:post, "/documents/#{S.uuid()}/issue"}] do
      conn = call(method, path, ctx.sk_a)
      refute conn.status in [401, 403], "#{path}: #{conn.status} #{conn.resp_body}"
    end
  end

  test "SA-3 the storekeeper is refused reconcile, reverse and card writes", ctx do
    id = S.uuid()

    for {method, path} <- [
          {:get, "/reconcile"},
          {:post, "/documents/#{id}/reverse"},
          {:post, "/cards"},
          {:patch, "/cards/#{id}"},
          {:post, "/cards/#{id}/retire"}
        ] do
      conn = call(method, path, ctx.sk_a)
      assert conn.status == 403, "#{method} #{path}: #{conn.status} #{conn.resp_body}"
    end

    # the administrator is not refused the same routes by permission
    admin = S.token(ctx, :a, ["TENANT_ADMIN"], sub: "admin-a")
    assert S.get("/reconcile", admin).status != 403
  end

  test "SA-4 INV-10: B's storekeeper sees none of A's rows, also by A's ids", ctx do
    seed!(ctx.a.schema_name)
    seed!(ctx.b.schema_name)

    doc_a = S.json(S.get("/documents", ctx.sk_a))["rows"] |> List.wrap()
    ids_a = for d <- doc_a, is_map(d), do: d["id"]

    for path <- ["/balances?asset=#{@a1}", "/movements", "/documents"] do
      body = S.json(S.get(path, ctx.sk_b))
      refute inspect(body) =~ ctx.a.schema_name, path
    end

    for id <- ids_a do
      assert S.get("/documents/#{id}", ctx.sk_b).status in [403, 404]
    end

    # a token of A's realm does not open B: it names no user of B's tenant
    unknown = S.get("/documents/#{S.uuid()}", ctx.sk_b)
    assert unknown.status in [403, 404]
  end

  test "SA-5 scoped caller: a storekeeper granted on U1 reads U1 only", ctx do
    s = S.tenant!("sk-s", ctx.names.s)
    schema = s.schema_name
    seed!(schema)

    {:ok, _} = ScopeNodePaths.write({:insert, @p, nil}, schema)
    {:ok, _} = ScopeNodePaths.write({:insert, @u1, @p}, schema)
    {:ok, _} = ScopeNodePaths.write({:insert, @u2, @p}, schema)

    tok = S.token(ctx, :s, ["STOREKEEPER"], sub: "sk-scoped")
    assert S.get("/balances", tok).status == 200

    _ = RSG.raw_delete_rows!(schema, RSG.group_of!(schema, "STOREKEEPER"), "STOREKEEPER")
    user = Letflow.Repo.one!(from(u in User, where: u.username == "sk-scoped"), prefix: schema)
    :ok = RSG.raw_user_row!(schema, user.id, "STOREKEEPER", @u1)

    rows = S.json(S.get("/balances", tok))["rows"]
    assert rows != []
    assert Enum.map(rows, & &1["org_unit"]) |> Enum.uniq() == [@u1]
    assert S.get("/reconcile", tok).status in [403, 404]
  end
end
