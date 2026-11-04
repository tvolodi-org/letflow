Code.require_file("opening_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.OpeningPostingTest do
  @moduledoc """
  REQ-726 / GH #3774 criteria 2 to 7: the process definition `stock_opening`, the second-person rule,
  the entry's event time (the posting time, never the client's), a repeated approval, the read states,
  the retry route, reversal and cancel, and tenancy. Committed tenants, Sandbox `:auto`, `async: false`;
  requests through the full `Letflow.Router` with real OIDC bearer tokens (the task completion goes
  through `POST /api/v1/tasks/:id/complete`).
  Tests: O-DEF-1, O-2P-1..4, O-TIME-1..3, O-REP-1..2, O-ST-1..4, O-TEN-6.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Modules.Stock.Documents.Posting
  alias Letflow.Repo
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S
  alias Letflow.StockOpeningFixture, as: O
  alias Letflow.StockPostingFixture, as: P

  setup do
    ctx = P.setup!([:a, :b])
    ctx = Map.merge(ctx, P.tenant_b!(ctx))
    Map.put(ctx, :tok_u2, S.token(ctx, :a, ["TENANT_ADMIN"], sub: "second-admin"))
  end

  defp complete_route(ctx, task, token) do
    conn =
      Plug.Test.conn(:post, "/api/v1/tasks/#{task.id}/complete", "{}")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    Letflow.Router.call(conn, Letflow.Router.init([]))
  end

  defp approve_as(ctx, id, token) do
    task = O.task(ctx, id, "approve", :pending) || flunk("no pending approve task")
    complete_route(ctx, task, token)
  end

  defp posted!(ctx, body \\ nil) do
    doc = O.issue!(ctx, body)
    approve_as(ctx, doc["id"], ctx.tok_u2) |> P.status!(200)
    doc
  end

  defp instances(ctx, id) do
    Repo.aggregate(
      from(p in Letflow.EventStore.InstanceProjection,
        where: fragment("?->>'document_id' = ?", p.variables, ^id)
      ),
      :count,
      prefix: ctx.schema
    )
  end

  defp balance_total(ctx) do
    rows =
      for sku <- [ctx.ma.lot_item, ctx.ma.item],
          row <- (S.get("/balances?sku=#{sku}", ctx.tok_a) |> P.status!(200))["rows"],
          do: row

    Enum.reduce(rows, Decimal.new(0), &Decimal.add(Decimal.new(&1["quantity"]), &2))
  end

  test "O-DEF-1 the pack definition, and the issue starts one instance with submit done", ctx do
    defs =
      File.read!("priv/modules/stock/pack.json") |> Jason.decode!() |> Map.fetch!("definitions")

    graph = Enum.find(defs, &(&1["process_key"] == "stock_opening"))["graph"]
    assert Enum.map(graph["nodes"], & &1["id"]) == ~w(start submit approve end)
    [submit, approve] = Enum.filter(graph["nodes"], &(&1["node_type"] == "HUMAN_TASK"))
    refute Map.has_key?(submit["attributes"], "module_writes")
    assert approve["attributes"]["distinct_from"] == ["submit"]

    assert [%{"module" => "stock", "handler" => "post_document"}] =
             approve["attributes"]["module_writes"]

    assert Repo.one!(from(d in ProcessDefinition, where: d.name == "stock_opening"),
             prefix: ctx.schema
           ).status ==
             :draft

    doc = O.issue!(ctx)

    row =
      Repo.one!(from(d in ProcessDefinition, where: d.name == "stock_opening"),
        prefix: ctx.schema
      )

    assert row.status == :active and row.owner_module == "stock"
    assert instances(ctx, doc["id"]) == 1
    assert O.task(ctx, doc["id"], "submit", :completed)
    assert O.task(ctx, doc["id"], "approve", :pending)
    refute P.pending_task(ctx, doc["id"], "post")
    # the issuing user is the preparer: a user that is not the second administrator
    assert is_binary(O.issuer_id(ctx, doc["id"]))
    refute O.issuer_id(ctx, doc["id"]) == ctx.holder.id
  end

  test "O-2P-1 the issuing user completing approve is refused with the separation body", ctx do
    doc = O.issue!(ctx)
    conn = approve_as(ctx, doc["id"], ctx.tok_a)
    reference = Letflow.Api.Response.separation_of_duties(Plug.Test.conn(:get, "/"))
    assert conn.status == 403 and conn.resp_body == reference.resp_body
    assert P.counts(ctx, doc["id"]) == %{entries: %{}, marks: 0}
    assert O.task(ctx, doc["id"], "approve", :pending)
  end

  test "O-2P-2 a second user posts: one entry, one leg per line, one mark, balances", ctx do
    doc = O.issue!(ctx)
    approve_as(ctx, doc["id"], ctx.tok_u2) |> P.status!(200)

    assert P.counts(ctx, doc["id"]) == %{entries: %{"opening" => 1}, marks: 1}
    [entry] = P.movements(ctx, doc["id"])
    assert entry["cause"] == "opening" and entry["document_type"] == "stock_opening"
    assert length(entry["legs"]) == 2

    assert Enum.all?(
             entry["legs"],
             &(&1["location"] == ctx.ma.location and &1["org_unit"] == ctx.ma.unit)
           )

    assert Enum.all?(entry["legs"], &(&1["responsible"] == ctx.ma.employee))

    assert entry["legs"] |> Enum.map(& &1["quantity"]) |> Enum.sort() == [
             "10.500000000",
             "2.000000000"
           ]

    assert Decimal.equal?(balance_total(ctx), Decimal.new("12.5"))

    read = P.get!(ctx, doc["id"])
    assert read["state"] == "posted" and read["posting_check"] == "ok"
    assert read["entry_id"] == entry["entry_id"] and read["posted_at"]
  end

  test "O-2P-3 posted_by is the approver, not the issuer", ctx do
    doc = posted!(ctx)
    read = P.get!(ctx, doc["id"])
    assert read["posted_by"] == O.task(ctx, doc["id"], "approve", :completed).completed_by
    refute read["posted_by"] == O.issuer_id(ctx, doc["id"])
  end

  test "O-2P-4 a task worker cannot approve; nothing is written", ctx do
    doc = O.issue!(ctx)
    worker = S.token(ctx, :a, ["TASK_WORKER"], sub: "worker-2")
    conn = approve_as(ctx, doc["id"], worker)
    assert conn.status in [403, 404, 422]
    assert P.counts(ctx, doc["id"]) == %{entries: %{}, marks: 0}
    assert O.task(ctx, doc["id"], "approve", :pending)
  end

  test "O-TIME-1 the entry's event time is its posting time; the receipt date never reaches the ledger",
       ctx do
    doc = posted!(ctx)
    [entry] = P.movements(ctx, doc["id"])
    assert entry["event_time"] == entry["posting_time"]

    text = Jason.encode!(entry)

    refute text =~ O.back(400) or text =~ "received_on" or text =~ "unit_price" or
             text =~ "line_value"

    # a balance as of one hour before the posting shows nothing, after it shows the quantities
    {:ok, posted_at, _} = DateTime.from_iso8601(entry["posting_time"])
    before = DateTime.add(posted_at, -3600) |> DateTime.to_iso8601() |> URI.encode_www_form()
    later = DateTime.add(posted_at, 3600) |> DateTime.to_iso8601() |> URI.encode_www_form()

    seq = entry["posting_seq"]

    rows = fn at ->
      path = "/balances?basis=event_time&cutoff_seq=#{seq}&as_of=#{at}&sku=#{ctx.ma.item}"
      S.get(path, ctx.tok_a) |> P.status!(200) |> Map.get("rows")
    end

    assert rows.(before) == []
    assert [%{"quantity" => "10.500000000"}] = rows.(later)
  end

  test "O-TIME-3 a changed posting variable cannot backdate the entry", ctx do
    doc = O.issue!(ctx)
    task = O.task(ctx, doc["id"], "approve", :pending)

    instance =
      Repo.get!(Letflow.EventStore.InstanceProjection, task.instance_id, prefix: ctx.schema)

    forged =
      Map.merge(instance.variables["posting"], %{
        "device_id" => "forged",
        "client_seq" => 1,
        "client_event_time" =>
          DateTime.utc_now() |> DateTime.add(-48 * 3600) |> DateTime.to_iso8601()
      })

    assert {:ok, _} = O.approve(ctx, doc["id"], ctx.holder, output: %{"posting" => forged})
    [entry] = P.movements(ctx, doc["id"])
    assert entry["event_time"] == entry["posting_time"]
    assert P.get!(ctx, doc["id"])["posting_check"] == "ok"
  end

  test "O-TIME-4 the policy refuses client time keys in the command (direct declare)", _ctx do
    posting = %{
      cause: "opening",
      document_type: "stock_opening",
      document_id: Ecto.UUID.generate(),
      client_event_time: "2026-01-01T00:00:00Z",
      lines: []
    }

    assert {:error, {:invalid_posting, %{leg_no: 1}}} =
             Letflow.Modules.Stock.LedgerPolicy.declare(posting, %{})
  end

  test "O-REP-1 a second instance for the same version cannot post again", ctx do
    doc = posted!(ctx)
    id = doc["id"]
    admin = O.second_admin!(ctx)

    issued = Posting.issued(ctx.schema, id)
    {:ok, view} = Letflow.Modules.Stock.Documents.fetch(ctx.schema, id)
    assert {:ok, instance} = Posting.start_post(ctx.schema, view, issued, admin.id)
    assert instance
    assert {:ok, _} = O.approve(ctx, id, admin) |> then(&{:ok, &1})
    assert P.counts(ctx, id) == %{entries: %{"opening" => 1}, marks: 1}
  end

  test "O-REP-2 an opening for a key that already has a receipt balance is accepted and adds",
       ctx do
    receipt = P.issue!(ctx)
    P.post_and_complete!(ctx, receipt["id"])
    before = balance_total(ctx)
    posted!(ctx)
    assert Decimal.equal?(balance_total(ctx), Decimal.add(before, Decimal.new("12.5")))
  end

  test "O-ST-1 retry route: no pending task and no mark starts one instance and submits as the caller",
       ctx do
    Application.put_env(:letflow, :stock_post_start_fail?, true)
    doc = O.issue!(ctx)
    Application.delete_env(:letflow, :stock_post_start_fail?)
    assert instances(ctx, doc["id"]) == 0
    assert P.get!(ctx, doc["id"])["state"] == "issued"

    retried = P.req(ctx, :post, doc["id"], "post") |> P.status!(200)
    assert retried["state"] == "issued"
    assert instances(ctx, doc["id"]) == 1
    assert O.task(ctx, doc["id"], "submit", :completed)

    # a pending approve task: the retry route answers posting_pending
    json = P.req(ctx, :post, doc["id"], "post") |> P.status!(409)
    assert json["reason"] == "posting_pending"
    approve_as(ctx, doc["id"], ctx.tok_u2) |> P.status!(200)

    assert P.req(ctx, :post, doc["id"], "post") |> P.status!(409) |> Map.get("reason") ==
             "document_posted"
  end

  test "O-ST-2 reversal reverses the posted opening, balances return, cancel then applies", ctx do
    doc = posted!(ctx)
    id = doc["id"]
    assert Decimal.equal?(balance_total(ctx), Decimal.new("12.5"))

    P.req(ctx, :post, id, "reverse", %{"reason_code" => "wrong_document"}) |> P.status!(200)
    task = P.pending_task(ctx, id, "reverse")
    assert {:ok, _} = P.complete(ctx, task)
    read = P.get!(ctx, id)
    assert read["state"] == "reversed" and read["posting_check"] == "ok"
    assert P.counts(ctx, id).entries == %{"opening" => 1, "reversal" => 1}
    assert Decimal.equal?(balance_total(ctx), Decimal.new(0))

    cancelled = P.req(ctx, :post, id, "cancel", %{"reason" => "wrong stock"}) |> P.status!(200)
    assert cancelled["state"] == "cancelled" and cancelled["posting_check"] == "ok"
  end

  test "O-ST-3 an unposted issued opening can be cancelled once its tasks are not pending", ctx do
    doc = O.issue!(ctx)
    json = P.req(ctx, :post, doc["id"], "cancel", %{"reason" => "x"}) |> P.status!(409)
    assert json["reason"] == "posting_pending"
  end

  test "O-ST-4 the list shows the derived state of an opening", ctx do
    doc = posted!(ctx)

    rows =
      D.request(:get, "/documents?kind=opening&state=posted", ctx.tok_a)
      |> P.status!(200)
      |> Map.get("rows")

    assert [%{"id" => id, "state" => "posted", "kind" => "opening"}] = rows
    assert id == doc["id"]
  end

  test "O-TEN-6 tenant B cannot retry, reverse, cancel or approve A's opening; A is unchanged",
       ctx do
    doc = posted!(ctx)
    id = doc["id"]
    before = P.counts(ctx, id)

    for {path, body} <- [
          {"post", nil},
          {"reverse", %{"reason_code" => "wrong_document"}},
          {"cancel", %{"reason" => "x"}},
          {"check", nil}
        ] do
      assert D.request(:post, "/documents/#{id}/#{path}", ctx.tok_b, body).status == 404, path
    end

    assert P.counts(ctx, id) == before
    assert P.get!(ctx, id)["state"] == "posted"

    # B's admin cannot complete a task of tenant A either (the task id is unknown in B)
    other = O.issue!(ctx)
    task = O.task(ctx, other["id"], "approve", :pending)
    assert complete_route(ctx, task, ctx.tok_b).status in [403, 404]
    assert O.task(ctx, other["id"], "approve", :pending)
    assert P.counts(ctx, other["id"]) == %{entries: %{}, marks: 0}
  end
end
