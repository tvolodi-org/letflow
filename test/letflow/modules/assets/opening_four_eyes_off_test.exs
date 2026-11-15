Code.require_file("documents_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.OpeningFourEyesOffTest do
  @moduledoc """
  T-1987 (four-eyes switch slice 2): asset opening end to end for a one-person tenant. FE-1 one
  person issues, switches the step OFF, approves their own opening (it posts, audit note
  "self-approved, four-eyes off"), FE-2 default ON unchanged, FE-3 switched back ON refuses again,
  FE-5 INV-1 (tenant B's OFF row does not apply in tenant A), FE-6 the pack is unchanged. Full
  `Letflow.Router`, real tokens, committed tenants, Sandbox `:auto`.

  FE-4 (an API token stays four-eyes) is not run through the router: the fixtures cannot mint an
  API token that reaches the assets approve route. Its two halves are pinned where they are
  decided: the field is false for any non-`:oidc` credential (`approval_rules_test.exs` FE-R1) and
  the engine refuses a non-interactive self-approval (`separation_of_duties_test.exs`).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.Audit.Entry
  alias Letflow.Engine.Task
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Repo

  @moduletag timeout: 240_000

  setup do
    ctx = D.setup!([:a, :b])
    Map.merge(ctx, D.tenant_b!(ctx))
  end

  defp issue!(ctx, extra \\ %{}), do: D.issue!(ctx, D.opening_body(ctx.ma, extra))

  defp task(schema, id, node, status) do
    Repo.one(
      from(t in Task,
        join: p in InstanceProjection,
        on: p.instance_id == t.instance_id,
        where:
          t.status == ^status and t.node_id == ^node and
            fragment("?->>'document_id' = ?", p.variables, ^id),
        order_by: [desc: t.inserted_at],
        limit: 1
      ),
      prefix: schema
    )
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
    api(:put, "/approval-rules/assets_opening/approve", token, %{
      "four_eyes" => four_eyes,
      "reason" => "one-person company"
    })
  end

  defp field(token, task) do
    api(:get, "/tasks/#{task.id}", token) |> D.status!(200) |> Map.fetch!("self_approval_allowed")
  end

  defp complete(task, token), do: D.task_route(task, token, "complete", "{}")

  defp audit(schema, action) do
    Repo.all(from(e in Entry, where: e.action == ^action), prefix: schema)
  end

  test "FE-1 one person issues, switches OFF, approves their own opening; it posts", ctx do
    doc = issue!(ctx)
    approve = task(ctx.schema, doc["id"], "approve", :pending)
    assert approve

    switch(ctx.tok_a, false) |> D.status!(200) |> then(&assert(&1["four_eyes"] == false))

    assert field(ctx.tok_a, approve) == true
    complete(approve, ctx.tok_a) |> D.status!(200)

    read = D.get!(ctx, doc["id"])
    assert read["state"] == "posted"
    done = task(ctx.schema, doc["id"], "approve", :completed)
    assert read["posted_by"] == done.completed_by
    assert done.completed_by == task(ctx.schema, doc["id"], "submit", :completed).completed_by

    assert [self] = audit(ctx.schema, "task.self_approved")
    assert self.resource_id == approve.id
    assert self.after_state["note"] == "self-approved, four-eyes off"
    assert self.after_state["definition_name"] == "assets_opening"
    assert self.after_state["node_id"] == "approve"
    assert self.after_state["same_person_as"] == ["submit"]
    assert [_] = audit(ctx.schema, "approval_rule.changed")
    assert [_] = D.balances(ctx, ctx.ma.fixed)
  end

  test "FE-2 default ON: field false, the issuer is still refused", ctx do
    doc = issue!(ctx)
    approve = task(ctx.schema, doc["id"], "approve", :pending)
    assert field(ctx.tok_a, approve) == false

    conn = complete(approve, ctx.tok_a)
    reference = Letflow.Api.Response.separation_of_duties(Plug.Test.conn(:get, "/"))
    assert conn.status == 403 and conn.resp_body == reference.resp_body
    assert task(ctx.schema, doc["id"], "approve", :pending)
    assert audit(ctx.schema, "task.self_approved") == []
  end

  test "FE-3 switched back ON, the next self-approval is refused", ctx do
    first = issue!(ctx)
    t1 = task(ctx.schema, first["id"], "approve", :pending)
    switch(ctx.tok_a, false) |> D.status!(200)
    complete(t1, ctx.tok_a) |> D.status!(200)

    switch(ctx.tok_a, true) |> D.status!(200)
    # an asset is opened once: the second opening takes another asset
    line = Map.delete(D.opening_line(ctx.ma, ctx.ma.intangible), "location_id")
    second = issue!(ctx, %{"lines" => [line]})
    t2 = task(ctx.schema, second["id"], "approve", :pending)
    assert field(ctx.tok_a, t2) == false

    conn = complete(t2, ctx.tok_a)
    reference = Letflow.Api.Response.separation_of_duties(Plug.Test.conn(:get, "/"))
    assert conn.status == 403 and conn.resp_body == reference.resp_body
    assert [_] = audit(ctx.schema, "task.self_approved")
  end

  test "FE-5 INV-1: tenant B's OFF row does not apply in tenant A", ctx do
    D.issue!(%{ctx | tok_a: ctx.tok_b, ma: ctx.mb}, D.opening_body(ctx.mb))
    switch(ctx.tok_b, false) |> D.status!(200)

    doc = issue!(ctx)
    approve = task(ctx.schema, doc["id"], "approve", :pending)
    assert field(ctx.tok_a, approve) == false
    assert complete(approve, ctx.tok_a).status == 403
    assert audit(ctx.schema, "task.self_approved") == []
  end

  test "FE-6 the pack keeps distinct_from on approve" do
    pack = "priv/modules/assets/pack.json" |> File.read!() |> Jason.decode!()
    defn = Enum.find(pack["definitions"], &(&1["process_key"] == "assets_opening"))
    approve = Enum.find(defn["graph"]["nodes"], &(&1["id"] == "approve"))
    assert approve["attributes"]["distinct_from"] == ["submit"]
  end
end
