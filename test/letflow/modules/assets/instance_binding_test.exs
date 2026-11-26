Code.require_file("documents_fixture.exs", __DIR__)

defmodule Letflow.Modules.Assets.InstanceBindingTest do
  @moduledoc """
  T-2432 (audit T-2429, decision 0078 D5 gap): the assets write handlers post only what the instance
  was STARTED with (`HandlerWrites.read_instance_start/1`, the `INSTANCE_STARTED` event). Instance
  variables are forged in the projection (the completion body cannot carry them since T-2430), so the
  tests hold with or without that rule.
  Tests: AB-1 `post_document` redirected to another document's variables; AB-2 a changed posting;
  AB-3 the cross-instance four-eyes bypass of an opening; AB-4 `reverse_document` with another
  reason; AB-5 an honest completion is unchanged.
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
    ctx = D.setup!([:a])
    {:ok, Map.put(ctx, :tok_u2, S.token(ctx, :a, ["TENANT_ADMIN"], sub: "second-admin"))}
  end

  defp variables(ctx, task),
    do: Repo.get!(InstanceProjection, task.instance_id, prefix: ctx.schema).variables

  defp pending?(ctx, task), do: Repo.get!(Task, task.id, prefix: ctx.schema).status == :pending

  defp complete(task, token), do: D.task_route(task, token, "complete", "{}")

  defp refused?(conn), do: conn.status in [409, 422] and conn.resp_body =~ "validation_failed"

  test "AB-1 a post task whose variables name another document posts nothing", ctx do
    doc = D.issue!(ctx)

    other =
      D.issue!(
        ctx,
        D.body(ctx.ma, %{"lines" => [%{"asset_id" => ctx.ma.low, "quantity" => "5"}]})
      )

    task = D.pending_task(ctx, doc["id"], "post")
    other_task = D.pending_task(ctx, other["id"], "post")
    own = variables(ctx, task)
    assert D.task_route(task, ctx.tok_a, "claim", "{}").status == 200

    :ok = D.tamper!(ctx, task, Map.take(variables(ctx, other_task), @post_keys))

    assert refused?(complete(task, ctx.tok_a))
    assert D.counts(ctx, doc["id"]) == %{entries: %{}, marks: 0}
    assert D.counts(ctx, other["id"]) == %{entries: %{}, marks: 0}
    assert pending?(ctx, task)

    # AB-5: with the variables restored the same completion posts the task's own document
    :ok = D.tamper!(ctx, task, own)
    assert complete(task, ctx.tok_a).status == 200
    assert D.counts(ctx, doc["id"]).marks == 1
    assert D.counts(ctx, other["id"]) == %{entries: %{}, marks: 0}
  end

  test "AB-2 a changed posting quantity is refused", ctx do
    doc = D.issue!(ctx)
    task = D.pending_task(ctx, doc["id"], "post")
    own = variables(ctx, task)
    posting = own["posting"]
    lines = List.update_at(posting["lines"], 0, &Map.put(&1, "quantity", "9"))
    assert D.task_route(task, ctx.tok_a, "claim", "{}").status == 200

    :ok = D.tamper!(ctx, task, %{"posting" => Map.put(posting, "lines", lines)})
    assert refused?(complete(task, ctx.tok_a))
    assert D.counts(ctx, doc["id"]) == %{entries: %{}, marks: 0}
    assert pending?(ctx, task)
  end

  test "AB-3 the issuer of opening B cannot post B through A's approve task", ctx do
    doc_b =
      D.save!(ctx, D.opening_body(ctx.ma, %{"lines" => [D.opening_line(ctx.ma, ctx.ma.low)]}))

    doc_b = D.request(:post, "/documents/#{doc_b["id"]}/issue", ctx.tok_a) |> D.status!(200)

    doc_a =
      D.request(:post, "/documents", ctx.tok_u2, D.opening_body(ctx.ma, %{})) |> D.status!(201)

    doc_a = D.request(:post, "/documents/#{doc_a["id"]}/issue", ctx.tok_u2) |> D.status!(200)

    approve_a = D.pending_task(ctx, doc_a["id"], "approve")
    approve_b = D.pending_task(ctx, doc_b["id"], "approve")
    :ok = D.tamper!(ctx, approve_a, Map.take(variables(ctx, approve_b), @post_keys))

    assert refused?(complete(approve_a, ctx.tok_a))
    assert D.counts(ctx, doc_b["id"]) == %{entries: %{}, marks: 0}
    assert D.counts(ctx, doc_a["id"]) == %{entries: %{}, marks: 0}
    assert pending?(ctx, approve_a) and pending?(ctx, approve_b)
  end

  test "AB-4 a reversal with another reason_code is refused", ctx do
    id = D.commission!(ctx)["id"]

    D.request(:post, "/documents/#{id}/reverse", ctx.tok_a, %{"reason_code" => "wrong_document"})
    |> D.status!(200)

    task = D.pending_task(ctx, id, "reverse") || flunk("no reverse task")
    assert D.task_route(task, ctx.tok_a, "claim", "{}").status == 200
    :ok = D.tamper!(ctx, task, %{"reason_code" => "other_reason"})
    assert refused?(complete(task, ctx.tok_a))
    assert pending?(ctx, task)

    :ok = D.tamper!(ctx, task, %{"reason_code" => "wrong_document"})
    assert complete(task, ctx.tok_a).status == 200
  end
end
