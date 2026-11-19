Code.require_file("../modules/stock/posting_fixture.exs", __DIR__)

defmodule Letflow.Routers.SharedStockAccessWritesTest do
  @moduledoc """
  REQ-860 / GH #4571 (decision 0091 sections 5, 7 and 11b; Qoimeks parity G13 part 4): the two write
  calls of the old-app address `/qoimeks/:tenant_slug`, through the full `Letflow.Router` over
  committed tenants with real ledger postings. IDs follow the acceptance criteria: C1 receipt, issue and
  transfer post and are read by a TENANT_ADMIN, C2 the operator name and `posted_via_shared_access`,
  C3 reverse (second reverse and a reversal's reverse are 409), C4 operator refusals write nothing, C5 the
  shared access reaches nothing else, C6 another tenant's location number writes nothing (INV-1,
  INV-10), C7 runbook, plus W-x extras (refused posting leaves nothing, a revoked value, the authority
  step, a personal account cannot fake an operator). `async: false`: committed tenants, VM-global config.
  """

  # impl_order: REQ-860
  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.Engine
  alias Letflow.Modules.Locations
  alias Letflow.Plugs.AuthAttemptLimit
  alias Letflow.Plugs.AuthAttemptLimit.Bucket
  alias Letflow.Repo
  alias Letflow.SharedStockAccess
  alias Letflow.SharedStockAccess.IntIds
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockPostingFixture, as: P

  setup do
    ctx = P.setup!([:a, :b])
    b = P.tenant_b!(ctx)
    a = ctx.a

    originals = %{
      tenants: Application.fetch_env(:letflow, :shared_stock_access_tenants),
      limits: Application.fetch_env(:letflow, AuthAttemptLimit)
    }

    on_exit(fn ->
      restore(:shared_stock_access_tenants, originals.tenants)
      restore(AuthAttemptLimit, originals.limits)
      Bucket.reset()
    end)

    Application.put_env(:letflow, :shared_stock_access_tenants, [a.tenant.slug, b.b.tenant.slug])

    Application.put_env(:letflow, AuthAttemptLimit,
      failure_capacity: 1000,
      request_capacity: 1000
    )

    Bucket.reset()

    schema = ctx.schema
    m = ctx.ma

    # A second place linked to the same org unit, for transfers.
    {:ok, node2} =
      Locations.create_node(
        schema,
        %{
          "code" => "L2-#{System.unique_integer([:positive])}",
          "name" => "L2",
          "node_kind" => "zone"
        },
        %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}
      )

    {:ok, _} =
      Locations.link_unit_location(
        schema,
        m.unit,
        node2["record_id"],
        %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}
      )

    [sku] = Map.values(IntIds.assign(schema, :sku, [m.item]))
    locs = IntIds.assign(schema, :location, [m.location, node2["record_id"]])

    {:ok,
     ctx: ctx,
     b: b,
     a: a,
     m: m,
     sku: sku,
     loc1: locs[m.location],
     loc2: locs[node2["record_id"]],
     value: access!(a)}
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:letflow, key, value)
  defp restore(key, :error), do: Application.delete_env(:letflow, key)

  defp access!(fx) do
    {:ok, _kind, value} =
      SharedStockAccess.put(fx.schema_name, fx.tenant.slug, %{}, %{
        user_id: Ecto.UUID.generate(),
        trace_id: nil
      })

    value
  end

  defp call(method, slug, path, value, body \\ nil, headers \\ []) do
    conn =
      case body do
        nil -> Plug.Test.conn(method, "/qoimeks/#{slug}#{path}")
        body -> Plug.Test.conn(method, "/qoimeks/#{slug}#{path}", Jason.encode!(body))
      end

    conn = if value, do: put_req_header(conn, "authorization", "Bearer " <> value), else: conn
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    Letflow.Router.call(conn, Letflow.Router.init([]))
  end

  defp post_movement(fx, value, body, headers \\ []),
    do: call(:post, fx.tenant.slug, "/movements", value, body, headers)

  defp reverse(fx, value, id, body, headers \\ []),
    do: call(:post, fx.tenant.slug, "/movements/#{id}/reverse", value, body, headers)

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp credential_actor!(schema) do
    Repo.one!(from(c in SharedStockAccess.Credential, select: c.actor_id), prefix: schema)
  end

  defp shared_complete(schema, task, actor_id) do
    Engine.complete_task(
      task.id,
      %{
        output_variables: %{"operator" => "X"},
        actor_id: actor_id,
        idempotency_key: Ecto.UUID.generate()
      },
      prefix: schema,
      credential: :shared_access
    )
  end

  defp status!(conn, status) do
    assert conn.status == status, "expected #{status}, got #{conn.status}: #{conn.resp_body}"
    json(conn)
  end

  defp movement(t, kind, qty, operator, extra \\ %{}) do
    Map.merge(
      %{
        "id" => 1,
        "kind" => kind,
        "sku_id" => t.sku,
        "location_id" => t.loc1,
        "qty" => qty,
        "operator" => operator
      },
      extra
    )
  end

  defp balance_at(t, location) do
    rows = call(:get, t.a.tenant.slug, "/balances", t.value) |> status!(200)

    case Enum.filter(rows, &(&1["location_id"] == location and &1["sku_id"] == t.sku)) do
      [row] -> row["quantity"]
      [] -> 0
    end
  end

  defp written(schema) do
    %{rows: [[entries]]} = Repo.query!(~s|SELECT count(*) FROM "#{schema}".ledger_entry|)
    {entries, D.counts(schema)}
  end

  defp receive!(t, qty \\ 10, operator \\ "Aigul"),
    do: post_movement(t.a, t.value, movement(t, "receipt", qty, operator)) |> status!(201)

  # -- C1 -----------------------------------------------------------------------------------------

  describe "C1 receipt, issue and transfer" do
    test "C1 each answers 201 with the movement fields, shows as posted, balances change", t do
      fields = ~w(created_at id kind location_id operator quantity sku_id)

      rec = receive!(t, 10, "Айгуль")
      assert Map.keys(rec) |> Enum.sort() == fields
      assert %{"kind" => "stock_receipt", "quantity" => 10, "operator" => "Айгуль"} = rec
      assert rec["sku_id"] == t.sku and rec["location_id"] == t.loc1
      assert balance_at(t, t.loc1) == 10

      iss =
        post_movement(t.a, t.value, movement(t, "issue", 3, "Айгуль")) |> status!(201)

      assert %{"kind" => "stock_issue", "quantity" => 3} = iss
      assert balance_at(t, t.loc1) == 7

      trf =
        post_movement(
          t.a,
          t.value,
          movement(t, "transfer", "2.5", "Айгуль", %{"to_location_id" => t.loc2})
        )
        |> status!(201)

      assert %{"kind" => "stock_transfer", "quantity" => 2.5} = trf
      assert balance_at(t, t.loc1) == 4.5
      assert balance_at(t, t.loc2) == 2.5

      ids = [rec["id"], iss["id"], trf["id"]]
      assert length(Enum.uniq(ids)) == 3

      docs = D.request(:get, "/documents?limit=50", t.ctx.tok_a) |> P.status!(200)

      posted =
        docs["rows"] |> Enum.filter(&(&1["state"] == "posted")) |> Enum.map(& &1["kind"])

      assert Enum.sort(posted) == ["issue", "receipt", "transfer"]

      # the movements read shows the same rows with the typed operator
      list = call(:get, t.a.tenant.slug, "/movements", t.value) |> status!(200)
      assert length(list) == 3 and Enum.all?(list, &(&1["operator"] == "Айгуль"))
    end

    test "C1 the X-Operator header is accepted when the body has no operator", t do
      body = movement(t, "receipt", 1, nil) |> Map.delete("operator")
      conn = post_movement(t.a, t.value, body, [{"x-operator", "  Header Name  "}])
      assert %{"operator" => "Header Name"} = status!(conn, 201)
    end

    test "C1 an unknown kind (adjustment) and a bad quantity are 400, nothing is written", t do
      before = written(t.ctx.schema)

      for body <- [
            movement(t, "adjustment", 1, "X"),
            movement(t, "receipt", 0, "X"),
            movement(t, "receipt", -1, "X"),
            movement(t, "receipt", "abc", "X"),
            Map.delete(movement(t, "receipt", 1, "X"), "sku_id")
          ] do
        assert %{"error" => _} = post_movement(t.a, t.value, body) |> status!(400)
      end

      assert written(t.ctx.schema) == before
    end
  end

  # -- C2 -----------------------------------------------------------------------------------------

  describe "C2 the operator name is kept" do
    test "C2 the document read shows the name and posted_via_shared_access true; personal false",
         t do
      receive!(t, 5, "Айгуль")

      doc =
        D.request(:get, "/documents?limit=50", t.ctx.tok_a)
        |> P.status!(200)
        |> Map.fetch!("rows")
        |> Enum.find(&(&1["state"] == "posted"))

      one = P.get!(t.ctx, doc["id"])
      assert one["posted_by_label"] == "Айгуль"
      assert one["posted_via_shared_access"] == true
      assert one["reversed_via_shared_access"] == false
      assert one["posted_by"] != nil and one["reversed_by_label"] == nil

      personal = P.issue!(t.ctx)
      assert %{"state" => "posted"} = P.post_and_complete!(t.ctx, personal["id"])
      p = P.get!(t.ctx, personal["id"])
      assert p["posted_via_shared_access"] == false
      assert p["posted_by"] == t.ctx.holder.id
      assert p["posted_by_label"] == nil or p["posted_by_label"] != "Айгуль"
    end

    test "W-2 a personal account cannot fake an operator through an output variable", t do
      personal = P.issue!(t.ctx)
      task = P.pending_task(t.ctx, personal["id"], "post")
      assert {:ok, _} = P.complete(t.ctx, task, output: %{"operator" => "Fake Name"})
      p = P.get!(t.ctx, personal["id"])
      assert p["posted_via_shared_access"] == false
      assert p["posted_by_label"] != "Fake Name"
    end
  end

  # -- C3 -----------------------------------------------------------------------------------------

  describe "C3 reverse" do
    test "C3 reverse answers 201, labels the reverser, a second reverse and a reversal's reverse are 409",
         t do
      rec = receive!(t, 10, "Айгуль")
      assert balance_at(t, t.loc1) == 10

      rev = reverse(t.a, t.value, rec["id"], %{"operator" => "Ерлан"}) |> status!(201)
      assert %{"kind" => "reversal", "operator" => "Ерлан"} = rev
      assert rev["id"] != rec["id"]
      assert balance_at(t, t.loc1) == 0

      doc =
        D.request(:get, "/documents?limit=50", t.ctx.tok_a)
        |> P.status!(200)
        |> Map.fetch!("rows")
        |> Enum.find(&(&1["kind"] == "receipt"))

      one = P.get!(t.ctx, doc["id"])
      assert one["state"] == "reversed"
      assert one["reversed_by_label"] == "Ерлан" and one["reversed_via_shared_access"] == true
      assert one["posted_by_label"] == "Айгуль"

      before = written(t.ctx.schema)

      assert %{"error" => "document_reversed"} =
               reverse(t.a, t.value, rec["id"], %{"operator" => "Ерлан"}) |> status!(409)

      assert %{"error" => "reversal_cannot_be_reversed"} =
               reverse(t.a, t.value, rev["id"], %{"operator" => "Ерлан"}) |> status!(409)

      assert written(t.ctx.schema) == before
    end

    test "C3 an unknown movement id is 404 and writes nothing", t do
      before = written(t.ctx.schema)

      for id <- ["999999", "0", "-1", "abc"] do
        assert %{"error" => _} =
                 reverse(t.a, t.value, id, %{"operator" => "X"}) |> status!(404)
      end

      assert written(t.ctx.schema) == before
    end

    test "W-3 reversing a receipt whose stock was issued is refused and leaves nothing pending",
         t do
      rec = receive!(t, 5)
      post_movement(t.a, t.value, movement(t, "issue", 4, "X")) |> status!(201)
      before = written(t.ctx.schema)

      assert %{"error" => error} =
               reverse(t.a, t.value, rec["id"], %{"operator" => "X"}) |> status!(409)

      assert error in ["insufficient_stock", "insufficient_balance"]
      assert written(t.ctx.schema) == before
      assert balance_at(t, t.loc1) == 1

      # nothing is stuck: after the issue is reversed, the receipt reverses
      issue_row =
        call(:get, t.a.tenant.slug, "/movements", t.value)
        |> status!(200)
        |> Enum.find(&(&1["kind"] == "stock_issue"))

      reverse(t.a, t.value, issue_row["id"], %{"operator" => "X"}) |> status!(201)
      reverse(t.a, t.value, rec["id"], %{"operator" => "X"}) |> status!(201)
    end
  end

  # -- C4 -----------------------------------------------------------------------------------------

  describe "C4 the operator is required" do
    test "C4 none, blank, control characters and over 200 characters are 400, nothing written",
         t do
      rec = receive!(t, 5)
      before = written(t.ctx.schema)
      too_long = String.duplicate("я", 201)

      for operator <- [nil, "", "   ", "a\nb", too_long] do
        body = movement(t, "receipt", 1, operator)
        assert %{"error" => _} = post_movement(t.a, t.value, body) |> status!(400)

        assert %{"error" => _} =
                 reverse(t.a, t.value, rec["id"], %{"operator" => operator}) |> status!(400)
      end

      assert written(t.ctx.schema) == before
      assert balance_at(t, t.loc1) == 5
      # 200 characters is accepted
      ok = post_movement(t.a, t.value, movement(t, "receipt", 1, String.duplicate("я", 200)))
      assert ok.status == 201
    end
  end

  # -- C5 -----------------------------------------------------------------------------------------

  describe "C5 the shared access reaches nothing else" do
    test "C5 /api/v1 routes answer 401 with the value, the address serves only five calls", t do
      for {method, path} <- [
            {:post, "/api/v1/tasks/#{Ecto.UUID.generate()}/complete"},
            {:get, "/api/v1/modules/stock/documents"},
            {:post, "/api/v1/modules/stock/documents"},
            {:post, "/api/v1/modules/stock/quick-counts"},
            {:get, "/api/v1/modules/stock/counts"},
            {:get, "/api/v1/modules/stock/reconcile"},
            {:get, "/api/v1/users"},
            {:get, "/api/v1/tokens"}
          ] do
        conn =
          Plug.Test.conn(method, path)
          |> put_req_header("authorization", "Bearer " <> t.value)
          |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))

        assert conn.status == 401, "#{path}: #{conn.status}"
      end

      for {method, path} <- [
            {:get, "/codes"},
            {:post, "/feedback"},
            {:post, "/voice"},
            {:post, "/parse"},
            {:get, "/documents"},
            {:post, "/counts"},
            {:post, "/tasks/#{Ecto.UUID.generate()}/complete"},
            {:delete, "/movements/1"},
            {:get, "/movements/1/reverse"}
          ] do
        assert call(
                 method,
                 t.a.tenant.slug,
                 path,
                 t.value,
                 if(method == :post, do: %{}, else: nil)
               ).status ==
                 404,
               "#{method} #{path}"
      end
    end

    test "C5 no value, a wrong value or another tenant's value is the same 401", t do
      vb = access!(t.b.b)
      body = movement(t, "receipt", 1, "X")
      before = written(t.ctx.schema)

      for value <- [nil, "wrong-value-" <> String.duplicate("z", 40), vb] do
        conn = post_movement(t.a, value, body)
        assert conn.status == 401
      end

      assert written(t.ctx.schema) == before
    end

    test "W-5 a revoked value is refused and writes nothing", t do
      rec = receive!(t)

      :ok =
        SharedStockAccess.revoke(t.ctx.schema, %{user_id: Ecto.UUID.generate(), trace_id: nil})

      before = written(t.ctx.schema)
      assert post_movement(t.a, t.value, movement(t, "receipt", 1, "X")).status == 401
      assert reverse(t.a, t.value, rec["id"], %{"operator" => "X"}).status == 401
      assert written(t.ctx.schema) == before
    end

    test "W-6 the ledger authority refuses a stranger actor and an API token", t do
      doc = P.issue!(t.ctx)
      task = P.pending_task(t.ctx, doc["id"], "post")

      assert {:error, _} =
               Engine.complete_task(
                 task.id,
                 %{
                   output_variables: %{"operator" => "X"},
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: Ecto.UUID.generate()
                 },
                 prefix: t.ctx.schema,
                 credential: :shared_access
               )

      assert P.pending_task(t.ctx, doc["id"], "post") != nil
      assert P.counts(t.ctx, doc["id"]) == %{entries: %{}, marks: 0}

      # an API-token credential still cannot post
      assert {:error, _} = P.complete(t.ctx, task, credential: :api_token)
    end

    test "W-6b the authority refuses a credential revoked after the router proved it", t do
      doc = P.issue!(t.ctx)
      task = P.pending_task(t.ctx, doc["id"], "post")
      actor = credential_actor!(t.ctx.schema)

      # the credential is live now: the authority would accept this actor ...
      assert SharedStockAccess.active_actor?(t.ctx.schema, actor)

      # ... and is revoked between the request and the posting
      :ok =
        SharedStockAccess.revoke(t.ctx.schema, %{user_id: Ecto.UUID.generate(), trace_id: nil})

      refute SharedStockAccess.active_actor?(t.ctx.schema, actor)
      assert {:error, _} = shared_complete(t.ctx.schema, task, actor)
      assert P.pending_task(t.ctx, doc["id"], "post") != nil
      assert P.counts(t.ctx, doc["id"]) == %{entries: %{}, marks: 0}
    end

    test "W-6c the authority refuses the actor of another tenant's credential", t do
      _value_b = access!(t.b.b)
      actor_b = credential_actor!(t.b.b.schema_name)
      doc = P.issue!(t.ctx)
      task = P.pending_task(t.ctx, doc["id"], "post")

      assert SharedStockAccess.active_actor?(t.b.b.schema_name, actor_b)
      refute SharedStockAccess.active_actor?(t.ctx.schema, actor_b)
      assert {:error, _} = shared_complete(t.ctx.schema, task, actor_b)
      assert P.pending_task(t.ctx, doc["id"], "post") != nil
      assert P.counts(t.ctx, doc["id"]) == %{entries: %{}, marks: 0}
    end
  end

  # -- C6 -----------------------------------------------------------------------------------------

  describe "C6 another tenant's number" do
    test "C6 a transfer to a location number of tenant B is 404 and writes nothing anywhere", t do
      receive!(t, 5)
      b_schema = t.b.b.schema_name
      b_uuids = for _ <- 1..12, do: Ecto.UUID.generate()
      numbers = IntIds.assign(b_schema, :location, b_uuids) |> Map.values()
      b_number = Enum.max(numbers)
      assert b_number > t.loc2

      before = {written(t.ctx.schema), written(b_schema)}
      body = movement(t, "transfer", 1, "X", %{"to_location_id" => b_number})
      assert %{"error" => "unknown location"} = post_movement(t.a, t.value, body) |> status!(404)

      # also as the source place and as a receipt place
      for key <- ["location_id"] do
        body = movement(t, "receipt", 1, "X", %{key => b_number})
        assert post_movement(t.a, t.value, body).status == 404
      end

      assert {written(t.ctx.schema), written(b_schema)} == before
      assert balance_at(t, t.loc1) == 5
    end
  end

  # -- W: refusals leave nothing -------------------------------------------------------------------

  describe "W refused postings" do
    test "W-1 an issue over the balance is 409 and leaves no document, no entry, no pending task",
         t do
      receive!(t, 2)
      before = written(t.ctx.schema)

      assert %{"error" => error} =
               post_movement(t.a, t.value, movement(t, "issue", 5, "X")) |> status!(409)

      assert error in ["insufficient_stock", "insufficient_balance"]
      {entries_before, _docs} = before
      {entries_after, _} = written(t.ctx.schema)
      assert entries_after == entries_before
      assert balance_at(t, t.loc1) == 2

      # the draft left behind is cancelled, nothing is pending
      docs = D.request(:get, "/documents?limit=50", t.ctx.tok_a) |> P.status!(200)
      issue = Enum.find(docs["rows"], &(&1["kind"] == "issue"))
      assert issue["state"] == "cancelled"
      assert P.pending_task(t.ctx, issue["id"], "post") == nil
    end

    test "W-4 a deprecated process definition is 409 before any number is taken", t do
      import Ecto.Query, only: [from: 2]

      Repo.update_all(
        from(d in Letflow.Definitions.ProcessDefinition, where: d.name == "stock_issue"),
        [set: [status: :deprecated]],
        prefix: t.ctx.schema
      )

      before = written(t.ctx.schema)

      assert %{"error" => "definition_not_active"} =
               post_movement(t.a, t.value, movement(t, "issue", 1, "X")) |> status!(409)

      assert written(t.ctx.schema) == before
    end

    test "W-7 a body over the cap is 413 and a non-object body is 400", t do
      big = movement(t, "receipt", 1, String.duplicate("a", 9000))
      assert post_movement(t.a, t.value, big).status in [400, 413]

      conn =
        Plug.Test.conn(
          :post,
          "/qoimeks/#{t.a.tenant.slug}/movements",
          String.duplicate("a", 9000)
        )
        |> put_req_header("authorization", "Bearer " <> t.value)
        |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))

      assert conn.status == 413

      conn =
        Plug.Test.conn(:post, "/qoimeks/#{t.a.tenant.slug}/movements", "[1,2]")
        |> put_req_header("authorization", "Bearer " <> t.value)
        |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))

      assert conn.status == 400
    end
  end

  # C7 (runbook) is checked in test/letflow/pilot_rollout_runbook_test.exs, which already reads the
  # runbook, so this file stays out of the bounded docs test list (ci_docs_only_test D6).
end
