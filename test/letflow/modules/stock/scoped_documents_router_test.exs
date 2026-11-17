Code.require_file("two_side_fixture.exs", __DIR__)
Code.require_file("opening_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.ScopedDocumentsRouterTest do
  @moduledoc """
  REQ-831 / GH #4532 (slice L6 part 2): the stock document write routes for a STOREKEEPER whose
  StockPost / StockReverse grant is scoped to org units. Committed tenants, Sandbox `:auto`,
  `async: false`. Criteria 3 (SW-*), 4 (TS-*), 5 (PI-1), 6 (UN-*), 7 (XT-1), 8 (the route class and
  `document_scope/1`, SW-9 here and in `route_scope_resolver_test.exs`).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Engine.Task
  alias Letflow.Identity.User
  alias Letflow.ModuleConnCase, as: M
  alias Letflow.Modules.Stock.Access
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S
  alias Letflow.StockOpeningFixture, as: O
  alias Letflow.StockPostingFixture, as: P
  alias Letflow.StockTwoSideFixture, as: T
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopeOnFixture, as: SO

  setup do
    ctx = P.setup!([:a, :b])
    m2 = D.masters!(ctx.schema)
    mh = D.masters!(ctx.schema)

    # a tenant-wide admin activates the stock definitions first (a storekeeper does not hold
    # DefinitionsActivate, Posting.ensure_active/3)
    first = P.issue!(ctx)
    P.post_and_complete!(ctx, first["id"])
    # the reversal definition is activated by the first reversal, made by the admin
    P.req(ctx, :post, first["id"], "reverse", %{"reason_code" => "other", "reason_text" => "x"})
    |> P.status!(200)

    T.kinds() |> Enum.each(&create_issue!(ctx, T.body(&1, ctx.ma, ctx.ma, m2, %{})))

    tok = S.token(ctx, :a, ["STOREKEEPER"], sub: "sk-scoped")
    D.request(:get, "/documents", tok) |> P.status!(200)

    user =
      Letflow.Repo.one!(from(u in User, where: u.username == "sk-scoped"), prefix: ctx.schema)

    _ = RSG.raw_delete_rows!(ctx.schema, RSG.group_of!(ctx.schema, "STOREKEEPER"), "STOREKEEPER")
    :ok = RSG.raw_user_row!(ctx.schema, user.id, "STOREKEEPER", ctx.ma.unit)
    :ok = RSG.raw_user_row!(ctx.schema, user.id, "STOREKEEPER", m2.unit)

    Map.merge(ctx, %{m2: m2, mh: mh, sk: tok, sk_user: user, b: P.tenant_b!(ctx)})
  end

  defp create_issue!(ctx, body) do
    doc = D.request(:post, "/documents", ctx.tok_a, body) |> P.status!(201)
    D.request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_a) |> P.status!(200)
  end

  defp unknown(ctx),
    do:
      D.request(:get, "/documents/#{Ecto.UUID.generate()}", ctx.tok_a)
      |> P.status!(404)
      |> M.strip()

  defp not_found!(conn, reference) do
    assert conn.status == 404, "expected 404, got #{conn.status}: #{conn.resp_body}"
    assert M.strip(S.json(conn)) == reference
  end

  defp admin_doc!(ctx, m) do
    D.request(:post, "/documents", ctx.tok_a, D.body(m)) |> P.status!(201)
  end

  defp routes(id) do
    [
      {:put, "/documents/#{id}", :body},
      {:delete, "/documents/#{id}", nil},
      {:post, "/documents/#{id}/issue", nil},
      {:post, "/documents/#{id}/check", nil},
      {:post, "/documents/#{id}/post", nil},
      {:post, "/documents/#{id}/reverse", %{"reason_code" => "other", "reason_text" => "x"}},
      {:post, "/documents/#{id}/cancel", %{"reason_code" => "other", "reason_text" => "x"}}
    ]
  end

  for mode <- [:on, :off] do
    describe "scoped storekeeper, stored mode #{mode}" do
      setup ctx do
        :ok = SO.store_mode!(ctx.a, unquote(mode))
        :ok
      end

      test "SW-1..8 a unit of the grant: the routes answer as for a tenant-wide caller", ctx do
        created = D.request(:post, "/documents", ctx.sk, D.body(ctx.ma)) |> P.status!(201)
        id = created["id"]
        assert created["org_unit_id"] == ctx.ma.unit

        replaced =
          D.request(:put, "/documents/#{id}", ctx.sk, D.body(ctx.ma, nil, %{"note" => "changed"}))
          |> P.status!(200)

        assert replaced["note"] == "changed"

        # the check route answers a receipt like it does for the admin (a refusal, not a 404/500)
        admin_check = D.request(:post, "/documents/#{id}/check", ctx.tok_a)
        sk_check = D.request(:post, "/documents/#{id}/check", ctx.sk)
        assert sk_check.status == admin_check.status
        assert M.strip(S.json(sk_check)) == M.strip(S.json(admin_check))

        issued = D.request(:post, "/documents/#{id}/issue", ctx.sk) |> P.status!(200)
        assert issued["state"] == "issued"
        # the issue started the posting: the post route answers as it does for the admin
        post = D.request(:post, "/documents/#{id}/post", ctx.sk) |> P.status!(409)
        assert post["reason"] == "posting_pending"

        # a second draft: discard
        d2 = D.request(:post, "/documents", ctx.sk, D.body(ctx.ma)) |> P.status!(201)
        assert D.request(:delete, "/documents/#{d2["id"]}", ctx.sk).status == 204

        # reverse and cancel of a posted document of the unit
        posted = P.issue!(ctx)
        P.post_and_complete!(ctx, posted["id"])

        rev =
          D.request(:post, "/documents/#{posted["id"]}/reverse", ctx.sk, %{
            "reason_code" => "other",
            "reason_text" => "wrong"
          })

        assert rev.status == 200, rev.resp_body

        issued2 = P.issue!(ctx)

        cancel =
          D.request(:post, "/documents/#{issued2["id"]}/cancel", ctx.sk, %{
            "reason_code" => "other",
            "reason_text" => "wrong"
          })

        assert cancel.status in [200, 409, 422], cancel.resp_body
        refute cancel.status in [403, 404, 500]
      end

      test "SW-9 a unit outside the grant: the unknown-document 404 on every route, nothing written",
           ctx do
        reference = unknown(ctx)
        doc = admin_doc!(ctx, ctx.mh)
        before = D.counts(ctx.schema)

        not_found!(D.request(:post, "/documents", ctx.sk, D.body(ctx.mh)), reference)
        assert D.counts(ctx.schema) == before

        for {method, path, body} <- routes(doc["id"]) do
          body = if body == :body, do: D.body(ctx.ma), else: body
          not_found!(D.request(method, path, ctx.sk, body), reference)
          assert D.counts(ctx.schema) == before, "#{method} #{path}"
        end

        assert D.request(:get, "/documents/#{doc["id"]}", ctx.tok_a)
               |> P.status!(200)
               |> Map.get("state") ==
                 "draft"
      end

      test "UN-1 an opening document is the not-found answer for a scoped caller", ctx do
        reference = unknown(ctx)

        not_found!(D.request(:post, "/documents", ctx.sk, O.body(ctx.ma)), reference)

        stored = O.save!(ctx)
        before = D.counts(ctx.schema)

        for {method, path, body} <- routes(stored["id"]) do
          body = if body == :body, do: O.body(ctx.ma), else: body
          not_found!(D.request(method, path, ctx.sk, body), reference)
        end

        assert D.counts(ctx.schema) == before
      end
    end
  end

  # REQ-847, INV-5: a client key bound to an in-scope document must not tell an unknown document
  # id from an existing one outside the grant (both are the unknown-document 404 without a key).
  describe "REQ-847 a bound issue/post key is no existence oracle" do
    setup ctx do
      :ok = SO.store_mode!(ctx.a, :on)
      :ok
    end

    defp keyed(ctx, id, action, key) do
      Plug.Test.conn(:post, "/api/v1/modules/stock/documents/#{id}/#{action}")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> ctx.sk)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("idempotency-key", key)
      |> Letflow.Router.call(Letflow.Router.init([]))
    end

    defp fresh_key, do: "k-#{System.unique_integer([:positive])}"

    # an issued document whose posting instance was not started (the case the post route is for)
    defp issued_unstarted!(ctx, masters) do
      Application.put_env(:letflow, :stock_post_start_fail?, true)
      doc = admin_doc!(ctx, masters)
      D.request(:post, "/documents/#{doc["id"]}/issue", ctx.tok_a) |> P.status!(200)
      Application.delete_env(:letflow, :stock_post_start_fail?)
      doc
    end

    test "OR-1 issue: key bound on an in-scope document; unknown id and out-of-scope id alike",
         ctx do
      reference = unknown(ctx)
      k = fresh_key()
      mine = D.request(:post, "/documents", ctx.sk, D.body(ctx.ma)) |> P.status!(201)
      assert keyed(ctx, mine["id"], "issue", k).status == 200

      outside = admin_doc!(ctx, ctx.mh)
      not_found!(keyed(ctx, Ecto.UUID.generate(), "issue", k), reference)
      not_found!(keyed(ctx, outside["id"], "issue", k), reference)

      # the refusal for a document the caller can read is unchanged
      other = D.request(:post, "/documents", ctx.sk, D.body(ctx.ma)) |> P.status!(201)
      conn = keyed(ctx, other["id"], "issue", k)
      assert conn.status == 409
      assert S.json(conn)["reason"] == "idempotency_key_reuse"
    end

    test "OR-2 post: key bound on an in-scope document; unknown id and out-of-scope id alike",
         ctx do
      reference = unknown(ctx)
      k = fresh_key()
      mine = issued_unstarted!(ctx, ctx.ma)
      assert keyed(ctx, mine["id"], "post", k).status == 200

      outside = issued_unstarted!(ctx, ctx.mh)
      not_found!(keyed(ctx, Ecto.UUID.generate(), "post", k), reference)
      not_found!(keyed(ctx, outside["id"], "post", k), reference)

      other = issued_unstarted!(ctx, ctx.ma)
      conn = keyed(ctx, other["id"], "post", k)
      assert conn.status == 409
      assert S.json(conn)["reason"] == "idempotency_key_reuse"
    end

    # D7 of decision 0051: no 422 that reveals existence. A malformed key is a 422 only for a
    # document the caller can read; an unknown id and an out-of-scope one both stay the 404.
    test "OR-3 issue and post: a malformed key is no existence oracle", ctx do
      reference = unknown(ctx)
      outside_draft = admin_doc!(ctx, ctx.mh)
      outside_issued = issued_unstarted!(ctx, ctx.mh)
      mine_draft = D.request(:post, "/documents", ctx.sk, D.body(ctx.ma)) |> P.status!(201)
      mine_issued = issued_unstarted!(ctx, ctx.ma)

      for bad <- [String.duplicate("k", 200), "k\0nul"] do
        not_found!(keyed(ctx, Ecto.UUID.generate(), "issue", bad), reference)
        not_found!(keyed(ctx, outside_draft["id"], "issue", bad), reference)
        not_found!(keyed(ctx, Ecto.UUID.generate(), "post", bad), reference)
        not_found!(keyed(ctx, outside_issued["id"], "post", bad), reference)

        # a document the caller can read still gets the 422
        assert keyed(ctx, mine_draft["id"], "issue", bad).status == 422
        assert keyed(ctx, mine_issued["id"], "post", bad).status == 422
      end
    end
  end

  describe "two-sided kinds (mode on)" do
    setup ctx do
      :ok = SO.store_mode!(ctx.a, :on)
      :ok
    end

    test "TS-1 transfer U to U2 saved, issued and its post starts an instance", ctx do
      body = T.body("transfer", ctx.ma, ctx.ma, ctx.m2, %{})
      doc = D.request(:post, "/documents", ctx.sk, body) |> P.status!(201)
      D.request(:post, "/documents/#{doc["id"]}/issue", ctx.sk) |> P.status!(200)

      assert D.request(:post, "/documents/#{doc["id"]}/post", ctx.sk)
             |> P.status!(409)
             |> Map.get("reason") == "posting_pending"

      assert P.pending_task(ctx, doc["id"], "post")
    end

    test "TS-2 a transfer to H and a return from H are 404 on save", ctx do
      reference = unknown(ctx)
      to_h = T.body("transfer", ctx.ma, ctx.ma, ctx.mh, %{})
      from_h = T.body("return", ctx.ma, ctx.mh, ctx.ma, %{})
      before = D.counts(ctx.schema)
      not_found!(D.request(:post, "/documents", ctx.sk, to_h), reference)
      not_found!(D.request(:post, "/documents", ctx.sk, from_h), reference)
      assert D.counts(ctx.schema) == before
    end

    test "TS-3 a PUT moving a saved U-to-U2 transfer to H is 404 and the document is unchanged",
         ctx do
      reference = unknown(ctx)

      doc =
        D.request(:post, "/documents", ctx.sk, T.body("transfer", ctx.ma, ctx.ma, ctx.m2, %{}))
        |> P.status!(201)

      moved = T.body("transfer", ctx.ma, ctx.ma, ctx.mh, %{})
      not_found!(D.request(:put, "/documents/#{doc["id"]}", ctx.sk, moved), reference)

      stored = D.request(:get, "/documents/#{doc["id"]}", ctx.tok_a) |> P.status!(200)
      assert stored["to_org_unit_id"] == ctx.m2.unit
    end
  end

  describe "REQ-846 replay of a keyed create (mode on)" do
    setup ctx do
      :ok = SO.store_mode!(ctx.a, :on)
      :ok
    end

    defp keyed_create(token, body, key) do
      Plug.Test.conn(:post, "/api/v1/modules/stock/documents", Jason.encode!(body))
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("idempotency-key", key)
      |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
    end

    test "RP-1 a replay whose stored units stay in the grant is 201 with the document", ctx do
      key = "rp1-#{System.unique_integer([:positive])}"
      body = T.body("transfer", ctx.ma, ctx.ma, ctx.m2, %{})

      first = keyed_create(ctx.sk, body, key) |> P.status!(201)
      before = D.counts(ctx.schema)
      replay = keyed_create(ctx.sk, body, key) |> P.status!(201)

      assert replay["id"] == first["id"]
      assert D.counts(ctx.schema) == before
    end

    test "RP-2 a replay after a tenant-wide replace moved the transfer out of the grant is the 404",
         ctx do
      reference = unknown(ctx)
      key = "rp2-#{System.unique_integer([:positive])}"
      body = T.body("transfer", ctx.ma, ctx.ma, ctx.m2, %{})

      first = keyed_create(ctx.sk, body, key) |> P.status!(201)

      # the tenant-wide admin moves the destination to the unit H (outside the grant)
      moved = T.body("transfer", ctx.ma, ctx.ma, ctx.mh, %{})
      D.request(:put, "/documents/#{first["id"]}", ctx.tok_a, moved) |> P.status!(200)

      before = D.counts(ctx.schema)
      not_found!(keyed_create(ctx.sk, body, key), reference)
      assert D.counts(ctx.schema) == before

      # the document itself is untouched (read here with the tenant-wide admin token)
      stored = D.request(:get, "/documents/#{first["id"]}", ctx.tok_a) |> P.status!(200)
      assert stored["to_org_unit_id"] == ctx.mh.unit
    end
  end

  describe "other routes and tenants" do
    test "UN-2 a scoped caller on the read routes: 403 under on, the 404 under off", ctx do
      id = P.issue!(ctx)["id"]

      for {mode, status} <- [on: 403, off: 404], path <- ["/documents", "/documents/#{id}"] do
        :ok = SO.store_mode!(ctx.a, mode)
        conn = D.request(:get, path, ctx.sk)
        assert conn.status == status, "#{mode} #{path}: #{conn.status}"
      end

      for {mode, status} <- [on: 403, off: 404] do
        :ok = SO.store_mode!(ctx.a, mode)
        conn = D.request(:post, "/counts/#{Ecto.UUID.generate()}/post", ctx.sk, %{})
        assert conn.status == status, "counts #{mode}: #{conn.status}"
      end
    end

    test "VO-1 the voice draft routes stay tenant-wide only: a scoped caller 403 on, 404 off",
         ctx do
      Letflow.Support.VoiceDoubles.install!()

      for {mode, status} <- [on: 403, off: 404],
          path <- ["/voice/draft", "/voice/draft-text"] do
        :ok = SO.store_mode!(ctx.a, mode)
        conn = D.request(:post, path, ctx.sk, %{"text" => "x", "lang" => "ru"})
        assert conn.status == status, "#{mode} #{path}: #{conn.status}"
      end

      for mode <- [:on, :off] do
        :ok = SO.store_mode!(ctx.a, mode)

        D.request(:post, "/voice/draft-text", ctx.tok_a, %{"text" => "hello", "lang" => "ru"})
        |> P.status!(200)
      end
    end

    test "UK-1 every kind's header carries a unit key (units_allowed? is never vacuously true)" do
      for spec <- Letflow.Modules.Stock.Documents.Kinds.all() do
        assert Enum.any?(
                 spec.header_keys,
                 &(&1 in ~w(org_unit_id to_org_unit_id from_org_unit_id))
               ),
               "kind #{spec.kind} has no unit key"
      end
    end

    test "XT-1 the scoped storekeeper of tenant B cannot reach a document of tenant A", ctx do
      b = ctx.b
      doc = admin_doc!(ctx, ctx.ma)
      before_a = D.counts(ctx.schema)
      before_b = D.counts(b.b.schema_name)

      tok = S.token(ctx, :b, ["STOREKEEPER"], sub: "sk-b")
      D.request(:get, "/documents", tok) |> P.status!(200)

      user =
        Letflow.Repo.one!(from(u in User, where: u.username == "sk-b"), prefix: b.b.schema_name)

      _ =
        RSG.raw_delete_rows!(
          b.b.schema_name,
          RSG.group_of!(b.b.schema_name, "STOREKEEPER"),
          "STOREKEEPER"
        )

      :ok = RSG.raw_user_row!(b.b.schema_name, user.id, "STOREKEEPER", b.mb.unit)

      :ok = SO.store_mode!(b.b, :on)
      reference = unknown(ctx)

      for {method, path, body} <- [{:post, "/documents", D.body(ctx.ma)} | routes(doc["id"])] do
        body = if body == :body, do: D.body(ctx.ma), else: body
        not_found!(D.request(method, path, tok, body), reference)
      end

      assert D.counts(ctx.schema) == before_a
      assert D.counts(b.b.schema_name) == before_b
    end
  end

  describe "posting instance and the core check" do
    test "PI-1 the instance and its post task carry the unit; the storekeeper completes it",
         ctx do
      :ok = SO.store_mode!(ctx.a, :on)
      doc = D.request(:post, "/documents", ctx.sk, D.body(ctx.ma)) |> P.status!(201)
      D.request(:post, "/documents/#{doc["id"]}/issue", ctx.sk) |> P.status!(200)

      task = P.pending_task(ctx, doc["id"], "post") || flunk("no pending post task")
      assert %Task{scope_node_id: node} = task
      assert node == ctx.ma.unit

      projection =
        Letflow.Repo.one!(
          from(p in Letflow.EventStore.InstanceProjection,
            where: p.instance_id == ^task.instance_id,
            select: p.scope_node_id
          ),
          prefix: ctx.schema
        )

      assert projection == ctx.ma.unit

      assert {:ok, _} = P.complete(ctx, task, user: ctx.sk_user)

      assert D.request(:get, "/documents/#{doc["id"]}", ctx.tok_a)
             |> P.status!(200)
             |> Map.get("posted_at")
    end
  end

  describe "document_scope/1" do
    test "SW-10 {:node, id} for a map with a unit, :unresolvable for none or an empty string" do
      assert function_exported?(Access, :document_scope, 1)
      assert Access.document_scope(%{org_unit_id: "u-1"}) == {:node, "u-1"}
      assert Access.document_scope(%{}) == :unresolvable
      assert Access.document_scope(%{org_unit_id: ""}) == :unresolvable
    end
  end
end
