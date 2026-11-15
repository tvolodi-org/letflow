Code.require_file("opening_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.OpeningFourEyesOffTest do
  @moduledoc """
  T-1988: stock opening with four eyes OFF, default ON, restoration, tenant isolation,
  permission refusal and unchanged pack (FE-S1..FE-S6). Full router, real OIDC tokens,
  committed tenants and Sandbox `:auto`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.StockOpeningFixture, as: O
  alias Letflow.StockPostingFixture, as: P
  alias Letflow.StockFixture, as: S
  alias Letflow.Audit.Entry
  alias Letflow.Repo

  @moduletag timeout: 240_000

  setup do
    ctx = P.setup!([:a, :b])
    Map.merge(ctx, P.tenant_b!(ctx))
  end

  defp api(method, path, token, body \\ nil) do
    conn =
      case body do
        nil -> Plug.Test.conn(method, "/api/v1" <> path)
        body -> Plug.Test.conn(method, "/api/v1" <> path, Jason.encode!(body))
      end

    conn
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp switch(token, four_eyes) do
    api(:put, "/approval-rules/stock_opening/approve", token, %{
      "four_eyes" => four_eyes,
      "reason" => "one-person company"
    })
  end

  defp field(token, task) do
    api(:get, "/tasks/#{task.id}", token) |> P.status!(200) |> Map.fetch!("self_approval_allowed")
  end

  defp complete(task, token), do: api(:post, "/tasks/#{task.id}/complete", token, %{})

  defp audit(schema, action) do
    Repo.all(from(e in Entry, where: e.action == ^action), prefix: schema)
  end

  test "FE-S1 one person issues, switches OFF, approves their own opening; it posts", ctx do
    doc = O.issue!(ctx)
    approve = O.task(ctx, doc["id"], "approve", :pending)
    assert approve

    switch(ctx.tok_a, false) |> P.status!(200) |> then(&assert(&1["four_eyes"] == false))

    assert field(ctx.tok_a, approve) == true
    complete(approve, ctx.tok_a) |> P.status!(200)

    read = P.get!(ctx, doc["id"])
    assert read["state"] == "posted"
    done = O.task(ctx, doc["id"], "approve", :completed)
    assert read["posted_by"] == done.completed_by
    assert done.completed_by == O.task(ctx, doc["id"], "submit", :completed).completed_by

    assert [self] = audit(ctx.schema, "task.self_approved")
    assert self.resource_id == approve.id
    assert self.after_state["note"] == "self-approved, four-eyes off"
    assert self.after_state["definition_name"] == "stock_opening"
    assert self.after_state["node_id"] == "approve"
    assert self.after_state["same_person_as"] == ["submit"]
    assert [changed] = audit(ctx.schema, "approval_rule.changed")
    assert changed.after_state["reason"] == "one-person company"
    assert read["posting_check"] == "ok"
    assert done.completed_by == O.issuer_id(ctx, doc["id"])
    assert P.counts(ctx, doc["id"]) == %{entries: %{"opening" => 1}, marks: 1}
  end

  test "FE-S2 default ON: field false, the issuer is still refused", ctx do
    doc = O.issue!(ctx)
    approve = O.task(ctx, doc["id"], "approve", :pending)
    assert field(ctx.tok_a, approve) == false

    conn = complete(approve, ctx.tok_a)
    reference = Letflow.Api.Response.separation_of_duties(Plug.Test.conn(:get, "/"))
    assert conn.status == 403 and conn.resp_body == reference.resp_body
    assert O.task(ctx, doc["id"], "approve", :pending)
    assert audit(ctx.schema, "task.self_approved") == []
    assert P.counts(ctx, doc["id"]) == %{entries: %{}, marks: 0}
  end

  test "FE-S3 switched back ON, the next self-approval is refused", ctx do
    first = O.issue!(ctx)
    t1 = O.task(ctx, first["id"], "approve", :pending)
    switch(ctx.tok_a, false) |> P.status!(200)
    complete(t1, ctx.tok_a) |> P.status!(200)

    switch(ctx.tok_a, true) |> P.status!(200)
    second = O.issue!(ctx)
    t2 = O.task(ctx, second["id"], "approve", :pending)
    assert field(ctx.tok_a, t2) == false

    conn = complete(t2, ctx.tok_a)
    reference = Letflow.Api.Response.separation_of_duties(Plug.Test.conn(:get, "/"))
    assert conn.status == 403 and conn.resp_body == reference.resp_body
    assert [_] = audit(ctx.schema, "task.self_approved")
  end

  test "FE-S4 INV-1: tenant B's OFF row does not apply in tenant A", ctx do
    O.issue!(%{ctx | tok_a: ctx.tok_b}, O.body(ctx.mb))
    switch(ctx.tok_b, false) |> P.status!(200)

    doc = O.issue!(ctx)
    approve = O.task(ctx, doc["id"], "approve", :pending)
    assert field(ctx.tok_a, approve) == false
    assert complete(approve, ctx.tok_a).status == 403
    assert audit(ctx.schema, "task.self_approved") == []
    assert P.counts(ctx, doc["id"]) == %{entries: %{}, marks: 0}
  end

  test "FE-S5 a task worker cannot switch the rule", ctx do
    O.issue!(ctx)
    worker = S.token(ctx, :a, ["TASK_WORKER"], sub: "worker-fe")
    assert switch(worker, false).status == 403
    assert Repo.all(Letflow.Engine.ApprovalRuleSetting, prefix: ctx.schema) == []
    assert audit(ctx.schema, "approval_rule.changed") == []
  end

  test "FE-S6 the pack keeps distinct_from on approve" do
    pack = "priv/modules/stock/pack.json" |> File.read!() |> Jason.decode!()
    defn = Enum.find(pack["definitions"], &(&1["process_key"] == "stock_opening"))
    approve = Enum.find(defn["graph"]["nodes"], &(&1["id"] == "approve"))
    assert approve["attributes"]["distinct_from"] == ["submit"]
  end
end
