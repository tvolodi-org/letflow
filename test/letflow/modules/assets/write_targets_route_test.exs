Code.require_file("documents_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.WriteTargetsRouteTest do
  @moduledoc """
  T-2430 (audit T-2429, `Letflow.Engine.WriteTargets`), assets side: `POST /tasks/:id/complete`
  refuses (422 `output_refused`, nothing written, the task stays pending) any output key a
  `module_writes` `var` argument of the pinned definition reads. The stock leg of a change of kind
  (`post_kind_change_out`) is MK-3 in `kind_change_master_posting_test.exs`.
  Tests: WT-A1 `post_document` (commission), WT-A2 `reverse_document`, WT-A3 the cross-instance
  four-eyes case of an opening, WT-A4 a legitimate completion is unchanged, WT-A5 a foreign tenant's
  task answers as an unknown one and the refusal never echoes a value, WT-A5b a body carrying
  tenant B's document (cross-tenant, B untouched).
  Committed tenants, Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.AssetsDocsFixture, as: D
  alias Letflow.AssetsRegisterFixture, as: S
  alias Letflow.Engine.Task
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Repo

  @post_keys ~w(document_id document_type version_no org_unit_id mark posting)

  setup do
    ctx = D.setup!([:a, :b])
    ctx = Map.merge(ctx, D.tenant_b!(ctx))
    {:ok, Map.put(ctx, :tok_u2, S.token(ctx, :a, ["TENANT_ADMIN"], sub: "second-admin"))}
  end

  defp complete(task, token, body), do: D.task_route(task, token, "complete", Jason.encode!(body))

  defp variables(ctx, task),
    do: Repo.get!(InstanceProjection, task.instance_id, prefix: ctx.schema).variables

  defp assert_refused(conn, key) do
    assert conn.status == 422, "#{key}: #{conn.status} #{conn.resp_body}"
    body = Jason.decode!(conn.resp_body)
    assert body["code"] == "output_refused"
    assert body["rejected_keys"] == [key]
  end

  defp pending?(ctx, task), do: Repo.get!(Task, task.id, prefix: ctx.schema).status == :pending

  test "WT-A1 post_document: each var key in the body is refused, nothing is written", ctx do
    doc = D.issue!(ctx)
    task = D.pending_task(ctx, doc["id"], "post")
    before = variables(ctx, task)
    assert D.task_route(task, ctx.tok_a, "claim", "{}").status == 200

    for key <- @post_keys do
      assert_refused(complete(task, ctx.tok_a, %{key => Map.fetch!(before, key)}), key)
      assert D.counts(ctx, doc["id"]) == %{entries: %{}, marks: 0}
      assert pending?(ctx, task)
      assert variables(ctx, task) == before
    end

    # a target of another document is the redirect the rule exists for
    other =
      D.issue!(
        ctx,
        D.body(ctx.ma, %{"lines" => [%{"asset_id" => ctx.ma.low, "quantity" => "5"}]})
      )

    conn = complete(task, ctx.tok_a, %{"document_id" => other["id"], "note" => "x"})
    assert conn.status == 422
    assert D.counts(ctx, other["id"]) == %{entries: %{}, marks: 0}
  end

  test "WT-A2 reverse_document: the entry to reverse and the reason are refused", ctx do
    doc = D.issue!(ctx)
    D.run_task!(ctx, doc["id"])

    D.request(:post, "/documents/#{doc["id"]}/reverse", ctx.tok_a, %{
      "reason_code" => "wrong_document"
    })
    |> D.status!(200)

    task = D.pending_task(ctx, doc["id"], "reverse")
    before = variables(ctx, task)
    assert D.task_route(task, ctx.tok_a, "claim", "{}").status == 200

    for key <- @post_keys ++ ["reason_code"] do
      assert_refused(complete(task, ctx.tok_a, %{key => Map.get(before, key, "x")}), key)
    end

    assert pending?(ctx, task)
    assert variables(ctx, task) == before
    assert D.counts(ctx, doc["id"]) == %{entries: %{"commission" => 1}, marks: 1}
    assert D.get!(ctx, doc["id"])["state"] == "posted"
  end

  test "WT-A3 four-eyes: the issuer of opening B cannot post B by completing A's approve", ctx do
    # X (tok_a) issues opening B; Y (tok_u2) issues opening A, so A's approve passes distinct_from for X
    doc_b =
      D.save!(ctx, D.opening_body(ctx.ma, %{"lines" => [D.opening_line(ctx.ma, ctx.ma.low)]}))

    doc_b =
      D.request(:post, "/documents/#{doc_b["id"]}/issue", ctx.tok_a) |> D.status!(200)

    doc_a = D.request(:post, "/documents", ctx.tok_u2, D.opening_body(ctx.ma, %{}))
    doc_a = doc_a |> D.status!(201)
    doc_a = D.request(:post, "/documents/#{doc_a["id"]}/issue", ctx.tok_u2) |> D.status!(200)

    approve_a = D.pending_task(ctx, doc_a["id"], "approve")
    approve_b = D.pending_task(ctx, doc_b["id"], "approve")
    forged = Map.take(variables(ctx, approve_b), @post_keys)

    conn = complete(approve_a, ctx.tok_a, forged)
    assert conn.status == 422
    assert Jason.decode!(conn.resp_body)["code"] == "output_refused"
    assert D.counts(ctx, doc_b["id"]) == %{entries: %{}, marks: 0}
    assert D.counts(ctx, doc_a["id"]) == %{entries: %{}, marks: 0}
    assert pending?(ctx, approve_a) and pending?(ctx, approve_b)

    # the honest completion decides by distinct_from alone: X may approve A (issued by Y), only A posts
    assert complete(approve_a, ctx.tok_a, %{}).status == 200
    assert D.counts(ctx, doc_a["id"]).marks == 1
    assert D.counts(ctx, doc_b["id"]) == %{entries: %{}, marks: 0}
  end

  test "WT-A4 a legitimate completion is unchanged (empty body, or the legacy wrapper key)",
       ctx do
    doc = D.issue!(ctx)
    task = D.pending_task(ctx, doc["id"], "post")
    assert D.task_route(task, ctx.tok_a, "claim", "{}").status == 200
    assert complete(task, ctx.tok_a, %{"output_variables" => %{}}).status == 200
    assert D.counts(ctx, doc["id"]) == %{entries: %{"commission" => 1}, marks: 1}
  end

  test "WT-A5 another tenant's task answers as unknown and the refusal names no value", ctx do
    doc = D.issue!(ctx)
    task = D.pending_task(ctx, doc["id"], "post")

    unknown = %{id: Ecto.UUID.generate(), instance_id: task.instance_id}
    foreign = complete(task, ctx.tok_b, %{"document_id" => doc["id"]})
    missing = complete(unknown, ctx.tok_b, %{"document_id" => doc["id"]})
    assert foreign.status == missing.status and foreign.status in [403, 404]
    assert D.counts(ctx, doc["id"]) == %{entries: %{}, marks: 0}
    assert pending?(ctx, task)

    refused = complete(task, ctx.tok_a, %{"document_id" => "value-must-not-echo"})
    assert refused.status == 422
    refute refused.resp_body =~ "value-must-not-echo"
  end

  test "WT-A5b a completion in tenant A carrying tenant B's document is refused, B untouched",
       ctx do
    ctx_b = %{ctx | tok_a: ctx.tok_b, schema: ctx.b.schema_name, ma: ctx.mb}
    doc_b = D.issue!(ctx_b)
    task_b = D.pending_task(ctx_b, doc_b["id"], "post")
    vars_b = variables(ctx_b, task_b)

    doc = D.issue!(ctx)
    task = D.pending_task(ctx, doc["id"], "post")
    assert D.task_route(task, ctx.tok_a, "claim", "{}").status == 200

    conn = complete(task, ctx.tok_a, Map.take(vars_b, @post_keys))
    assert conn.status == 422
    assert Jason.decode!(conn.resp_body)["code"] == "output_refused"
    assert D.counts(ctx, doc["id"]) == %{entries: %{}, marks: 0}
    assert pending?(ctx, task)
    assert D.counts(ctx_b, doc_b["id"]) == %{entries: %{}, marks: 0}
    assert pending?(ctx_b, task_b)
    assert variables(ctx_b, task_b) == vars_b
  end
end
