Code.require_file("opening_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.WriteTargetsRouteTest do
  @moduledoc """
  T-2430 (audit T-2429, `Letflow.Engine.WriteTargets`): `POST /tasks/:id/complete` refuses (422
  `output_refused`, nothing written, the task stays pending) any output key that a `module_writes`
  `var` argument of the instance's pinned definition reads, so the completer cannot choose what a
  stock handler posts. Committed tenants, Sandbox `:auto`, `async: false`, the full `Letflow.Router`
  with real OIDC bearer tokens.
  Tests: WT-S1 `post_document` (every var key), WT-S2 `reverse_document`, WT-S3 the cross-instance
  four-eyes case of an opening, WT-S4 legitimate completions unchanged, WT-S5 a foreign tenant's
  task, WT-S5b a body carrying tenant B's document (cross-tenant, B untouched). `post_count` is
  WT-S6 in `count_posting_test.exs`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Engine.Task
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Repo
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S
  alias Letflow.StockOpeningFixture, as: O
  alias Letflow.StockPostingFixture, as: P

  @post_keys ~w(document_id document_type version_no org_unit_id mark posting)

  setup do
    ctx = P.setup!([:a, :b])
    ctx = Map.merge(ctx, P.tenant_b!(ctx))
    Map.put(ctx, :tok_u2, S.token(ctx, :a, ["TENANT_ADMIN"], sub: "second-admin"))
  end

  defp complete(task, token, body) do
    conn =
      Plug.Test.conn(:post, "/api/v1/tasks/#{task.id}/complete", Jason.encode!(body))
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    Letflow.Router.call(conn, Letflow.Router.init([]))
  end

  defp variables(ctx, task),
    do: Repo.get!(InstanceProjection, task.instance_id, prefix: ctx.schema).variables

  defp assert_refused(conn, key) do
    assert conn.status == 422, "#{key}: #{conn.status} #{conn.resp_body}"
    body = Jason.decode!(conn.resp_body)
    assert body["code"] == "output_refused"
    assert body["rejected_keys"] == [key]
    assert body["missing_keys"] == []
  end

  defp assert_untouched(ctx, id, task) do
    assert P.counts(ctx, id) == %{entries: %{}, marks: 0}
    assert Repo.get!(Task, task.id, prefix: ctx.schema).status == :pending
  end

  test "WT-S1 post_document: each var key in the body is refused, nothing is written", ctx do
    doc = P.issue!(ctx)
    task = P.pending_task(ctx, doc["id"], "post")
    before = variables(ctx, task)

    for key <- @post_keys do
      conn = complete(task, ctx.tok_a, %{key => Map.fetch!(before, key)})
      assert_refused(conn, key)
      assert_untouched(ctx, doc["id"], task)
      assert variables(ctx, task) == before
    end

    # a body that mixes an unrelated key with a target is refused as a whole
    conn = complete(task, ctx.tok_a, %{"note" => "x", "document_id" => Ecto.UUID.generate()})
    assert conn.status == 422
    assert_untouched(ctx, doc["id"], task)
    refute Map.has_key?(variables(ctx, task), "note")
  end

  test "WT-S2 reverse_document: the reversal target and reason_code are refused", ctx do
    doc = P.issue!(ctx)
    P.post_and_complete!(ctx, doc["id"])

    P.req(ctx, :post, doc["id"], "reverse", %{"reason_code" => "wrong_document"})
    |> P.status!(200)

    task = P.pending_task(ctx, doc["id"], "reverse")
    before = variables(ctx, task)

    for key <- @post_keys ++ ["reason_code"] do
      assert_refused(complete(task, ctx.tok_a, %{key => Map.get(before, key, "x")}), key)
    end

    assert Repo.get!(Task, task.id, prefix: ctx.schema).status == :pending
    assert variables(ctx, task) == before
    assert P.get!(ctx, doc["id"])["state"] == "posted"
    assert P.counts(ctx, doc["id"]).entries == %{"receipt" => 1}
  end

  test "WT-S3 four-eyes: the issuer of opening B cannot post B by completing A's approve", ctx do
    # X (tok_a) issued opening B and is its submit completer; Y (tok_u2) issued opening A.
    doc_b = O.issue!(ctx)
    y_doc = D.request(:post, "/documents", ctx.tok_u2, O.body(ctx.ma)) |> P.status!(201)
    doc_y = D.request(:post, "/documents/#{y_doc["id"]}/issue", ctx.tok_u2) |> P.status!(200)

    approve_a = O.task(ctx, doc_y["id"], "approve", :pending)
    approve_b = O.task(ctx, doc_b["id"], "approve", :pending)
    vars_b = variables(ctx, approve_b)

    forged = Map.take(vars_b, @post_keys)
    conn = complete(approve_a, ctx.tok_a, forged)

    assert conn.status == 422
    assert Jason.decode!(conn.resp_body)["code"] == "output_refused"
    assert P.counts(ctx, doc_b["id"]) == %{entries: %{}, marks: 0}
    assert P.counts(ctx, doc_y["id"]) == %{entries: %{}, marks: 0}
    assert Repo.get!(Task, approve_a.id, prefix: ctx.schema).status == :pending
    assert Repo.get!(Task, approve_b.id, prefix: ctx.schema).status == :pending

    # the honest completion of A by X (empty body) is still decided by distinct_from alone: Y
    # issued A, X is another person, so it posts A and only A
    assert complete(approve_a, ctx.tok_a, %{}).status == 200
    assert P.counts(ctx, doc_y["id"]).marks == 1
    assert P.counts(ctx, doc_b["id"]) == %{entries: %{}, marks: 0}
  end

  test "WT-S4 legitimate completions are unchanged: empty body, and keys the form never reads",
       ctx do
    doc = P.issue!(ctx)
    task = P.pending_task(ctx, doc["id"], "post")

    # `output_variables` is only the legacy wrapper some clients send: no write argument reads it
    assert complete(task, ctx.tok_a, %{"output_variables" => %{}}).status == 200
    assert P.counts(ctx, doc["id"]) == %{entries: %{"receipt" => 1}, marks: 1}

    opening = O.issue!(ctx)
    approve = O.task(ctx, opening["id"], "approve", :pending)
    assert complete(approve, ctx.tok_u2, %{}).status == 200
    assert P.counts(ctx, opening["id"]) == %{entries: %{"opening" => 1}, marks: 1}
  end

  test "WT-S5 another tenant's task answers as before and the refusal names no value", ctx do
    doc = P.issue!(ctx)
    task = P.pending_task(ctx, doc["id"], "post")

    # tenant B's administrator cannot see tenant A's task at all (INV-5: same answer as unknown)
    unknown = %{id: Ecto.UUID.generate()}
    foreign = complete(task, ctx.tok_b, %{"document_id" => doc["id"]})
    missing = complete(unknown, ctx.tok_b, %{"document_id" => doc["id"]})
    assert foreign.status == missing.status and foreign.status in [403, 404]
    assert_untouched(ctx, doc["id"], task)

    # the refusal to the owner names the key only, never the value
    refused = complete(task, ctx.tok_a, %{"document_id" => "value-must-not-echo"})
    assert refused.status == 422
    refute refused.resp_body =~ "value-must-not-echo"
  end

  test "WT-S5b a completion in tenant A carrying tenant B's document is refused, B untouched",
       ctx do
    ctx_b = %{ctx | tok_a: ctx.tok_b, schema: ctx.b.schema_name, ma: ctx.mb}
    doc_b = P.issue!(ctx_b)
    task_b = P.pending_task(ctx_b, doc_b["id"], "post")
    vars_b = variables(ctx_b, task_b)

    doc = P.issue!(ctx)
    task = P.pending_task(ctx, doc["id"], "post")

    conn = complete(task, ctx.tok_a, Map.take(vars_b, @post_keys))
    assert conn.status == 422
    assert Jason.decode!(conn.resp_body)["code"] == "output_refused"
    assert_untouched(ctx, doc["id"], task)
    assert_untouched(ctx_b, doc_b["id"], task_b)
    assert variables(ctx_b, task_b) == vars_b
  end
end
