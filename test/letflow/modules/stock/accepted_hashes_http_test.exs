Code.require_file("posting_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.AcceptedHashesHttpTest do
  @moduledoc """
  REQ-769 / T-1371 (A2, A6): a stock receipt whose `post` task belongs to a definition stamped with
  an EARLIER manifest hash completes through the real HTTP path (bearer token, `Letflow.Router`,
  claim then complete) when that hash is in `tenant_modules.accepted_manifest_hashes`, and is
  refused when it is not or when the list belongs to another tenant (INV-1).
  Committed tenants, Sandbox `:auto`, `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.ModuleWritesFixture, as: Mw
  alias Letflow.Repo
  alias Letflow.StockPostingFixture, as: P

  @old_hash String.duplicate("7", 64)

  setup do
    P.setup!([:a, :b])
  end

  # The stock definition is stamped with the compiled hash at install; make it look stamped by an
  # older manifest. The stamp is immutable by trigger, so the throwaway tenant's trigger is
  # disabled for the update and re-enabled at once.
  defp restamp!(schema, hash) do
    Repo.query!(~s(ALTER TABLE "#{schema}"."process_definitions" DISABLE TRIGGER USER))

    {n, _} =
      Repo.update_all(
        from(d in ProcessDefinition, where: not is_nil(d.owner_manifest_hash)),
        [set: [owner_manifest_hash: hash]],
        prefix: schema
      )

    Repo.query!(~s(ALTER TABLE "#{schema}"."process_definitions" ENABLE TRIGGER USER))
    assert n >= 1
  end

  defp route(ctx, tok, task, action, body) do
    Plug.Test.conn(:post, "/api/v1/tasks/#{task.id}/#{action}", body)
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> tok)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Letflow.Router.call(Letflow.Router.init([]))
    |> tap(fn _ -> ctx end)
  end

  defp issued_receipt_with_old_stamp!(ctx) do
    doc = P.issue!(ctx)
    restamp!(ctx.schema, @old_hash)
    {doc, P.pending_task(ctx, doc["id"], "post")}
  end

  test "A2 an older stamp in the accepted list: claim and complete answer 200, balance is right",
       ctx do
    {doc, task} = issued_receipt_with_old_stamp!(ctx)
    Mw.set_accepted_hashes!(ctx.schema, "stock", [@old_hash])

    assert route(ctx, ctx.tok_a, task, "claim", "{}").status == 200
    conn = route(ctx, ctx.tok_a, task, "complete", ~s({"output_variables":{}}))
    assert conn.status == 200, conn.resp_body
    assert P.get!(ctx, doc["id"])["state"] == "posted"
    assert P.counts(ctx, doc["id"]) == %{entries: %{"receipt" => 1}, marks: 1}
  end

  test "A3 an older stamp that is not in the list is refused with 403, nothing posted", ctx do
    {doc, task} = issued_receipt_with_old_stamp!(ctx)
    Mw.set_accepted_hashes!(ctx.schema, "stock", ["other"])

    assert route(ctx, ctx.tok_a, task, "claim", "{}").status == 200
    conn = route(ctx, ctx.tok_a, task, "complete", ~s({"output_variables":{}}))
    assert conn.status == 403, conn.resp_body
    assert P.counts(ctx, doc["id"]) == %{entries: %{}, marks: 0}
  end

  test "A6 the hash accepted by tenant B does not help tenant A (INV-1)", ctx do
    b = P.tenant_b!(ctx)
    {doc, task} = issued_receipt_with_old_stamp!(ctx)
    Mw.set_accepted_hashes!(b.b.schema_name, "stock", [@old_hash])

    assert route(ctx, ctx.tok_a, task, "claim", "{}").status == 200
    conn = route(ctx, ctx.tok_a, task, "complete", ~s({"output_variables":{}}))
    assert conn.status == 403, conn.resp_body
    assert P.counts(ctx, doc["id"]) == %{entries: %{}, marks: 0}
  end
end
