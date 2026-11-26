Code.require_file("opening_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.InstanceBindingTest do
  @moduledoc """
  T-2431 (audit T-2429): the stock write handlers post only what the instance was STARTED with.
  `post_document`, `post_count`, `post_kind_change_out` and `reverse_document` compare their
  resolved arguments with the `INSTANCE_STARTED` event of the instance they run in
  (`HandlerWrites.read_instance_start/1`), so another document, another posting or another entry
  to reverse is refused (422 `validation_failed`, nothing written, the task stays pending), even
  when the instance variables were changed (here forged in the projection; the completion body
  cannot carry them any more since T-2430, and the tests of this file hold with or without that
  rule). Committed tenants, Sandbox `:auto`, `async: false`, the real router with OIDC tokens.
  Tests: IB-1 `post_document` redirected to another issued document; IB-2 the four-eyes pair of an
  opening across two instances; IB-3 a changed posting; IB-4 `reverse_document` (another entry,
  another reason, another document); IB-5 an honest completion is unchanged; IB-6 cross-tenant
  (tenant B's document and entries); IB-7 the facade refuses a forged context and reads only the
  own instance. `post_count` is IB-C in `count_posting_test.exs`, `post_kind_change_out` is IB-K
  in `assets/kind_change_master_posting_test.exs`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Engine.Task
  alias Letflow.Entities.HandlerWrites
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Repo
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S
  alias Letflow.StockOpeningFixture, as: O
  alias Letflow.StockPostingFixture, as: P

  @target_keys ~w(document_id document_type version_no org_unit_id mark posting)

  setup do
    ctx = P.setup!([:a, :b])
    ctx = Map.merge(ctx, P.tenant_b!(ctx))
    Map.put(ctx, :tok_u2, S.token(ctx, :a, ["TENANT_ADMIN"], sub: "second-admin"))
  end

  # -- helpers ------------------------------------------------------------------------------------

  defp vars(schema, task),
    do: Repo.get!(InstanceProjection, task.instance_id, prefix: schema).variables

  # Forges instance variables in the projection (the state a completer who could set variables, or
  # any other path that changed them, would leave). The start event is not touched.
  defp forge!(schema, task, forged) do
    merged = Map.merge(vars(schema, task), forged)

    {1, _} =
      Repo.update_all(
        from(p in InstanceProjection, where: p.instance_id == ^task.instance_id),
        [set: [variables: merged]],
        prefix: schema
      )

    :ok
  end

  defp complete_route(task, token, body \\ %{}) do
    conn =
      Plug.Test.conn(:post, "/api/v1/tasks/#{task.id}/complete", Jason.encode!(body))
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    Letflow.Router.call(conn, Letflow.Router.init([]))
  end

  defp pending?(schema, task), do: Repo.get!(Task, task.id, prefix: schema).status == :pending

  defp nothing?(ctx, id), do: P.counts(ctx, id) == %{entries: %{}, marks: 0}

  defp refused?(conn),
    do: conn.status in [409, 422] and conn.resp_body =~ ~r/validation_failed|output_refused/

  # -- IB-1 ---------------------------------------------------------------------------------------

  test "IB-1 a receipt task whose variables name another issued document posts nothing", ctx do
    doc_a = P.issue!(ctx)
    doc_b = P.issue!(ctx)
    task_a = P.pending_task(ctx, doc_a["id"], "post")
    task_b = P.pending_task(ctx, doc_b["id"], "post")

    # task A is completed with document B's own (issued, current) content and version
    :ok = forge!(ctx.schema, task_a, Map.take(vars(ctx.schema, task_b), @target_keys))
    conn = complete_route(task_a, ctx.tok_a)

    assert refused?(conn), "#{conn.status} #{conn.resp_body}"
    assert nothing?(ctx, doc_a["id"])
    assert nothing?(ctx, doc_b["id"])
    assert pending?(ctx.schema, task_a)
    assert pending?(ctx.schema, task_b)

    # B's own task still posts B, and only B
    assert complete_route(task_b, ctx.tok_a).status == 200
    assert P.counts(ctx, doc_b["id"]) == %{entries: %{"receipt" => 1}, marks: 1}
    assert nothing?(ctx, doc_a["id"])
  end

  test "IB-1b each target key changed alone is refused", ctx do
    doc_a = P.issue!(ctx)
    doc_b = P.issue!(ctx)
    task_a = P.pending_task(ctx, doc_a["id"], "post")
    vars_b = vars(ctx.schema, P.pending_task(ctx, doc_b["id"], "post"))
    original = vars(ctx.schema, task_a)

    # both documents are version 1 of the same org unit: those two keys get a value of their own
    forged = %{
      "document_id" => vars_b["document_id"],
      "posting" => vars_b["posting"],
      "version_no" => 2,
      "org_unit_id" => Ecto.UUID.generate()
    }

    for {key, value} <- forged do
      :ok = forge!(ctx.schema, task_a, %{key => value})
      conn = complete_route(task_a, ctx.tok_a)
      assert conn.status in [409, 422], "#{key}: #{conn.status} #{conn.resp_body}"
      assert nothing?(ctx, doc_a["id"]) and nothing?(ctx, doc_b["id"])
      :ok = forge!(ctx.schema, task_a, original)
    end

    assert complete_route(task_a, ctx.tok_a).status == 200
    assert P.counts(ctx, doc_a["id"]) == %{entries: %{"receipt" => 1}, marks: 1}
  end

  # -- IB-2 ---------------------------------------------------------------------------------------

  test "IB-2 four-eyes across instances: X cannot approve own opening B through A's task", ctx do
    # X (tok_a) issued opening B and completed its submit; Y (tok_u2) issued opening A.
    doc_b = O.issue!(ctx)
    y_doc = D.request(:post, "/documents", ctx.tok_u2, O.body(ctx.ma)) |> P.status!(201)
    doc_a = D.request(:post, "/documents/#{y_doc["id"]}/issue", ctx.tok_u2) |> P.status!(200)

    approve_a = O.task(ctx, doc_a["id"], "approve", :pending)
    approve_b = O.task(ctx, doc_b["id"], "approve", :pending)

    :ok = forge!(ctx.schema, approve_a, Map.take(vars(ctx.schema, approve_b), @target_keys))
    conn = complete_route(approve_a, ctx.tok_a)

    assert refused?(conn), "#{conn.status} #{conn.resp_body}"
    assert nothing?(ctx, doc_b["id"])
    assert nothing?(ctx, doc_a["id"])
    assert pending?(ctx.schema, approve_a)
    assert pending?(ctx.schema, approve_b)
  end

  # -- IB-3 ---------------------------------------------------------------------------------------

  test "IB-3 a changed posting (a quantity, a line) is refused; the honest posting goes through",
       ctx do
    doc = P.issue!(ctx)
    task = P.pending_task(ctx, doc["id"], "post")
    original = vars(ctx.schema, task)
    posting = original["posting"]

    changed = [
      Map.put(
        posting,
        "lines",
        List.update_at(posting["lines"], 0, &Map.put(&1, "quantity", "99"))
      ),
      Map.put(posting, "lines", posting["lines"] ++ posting["lines"]),
      Map.put(posting, "client_op_id", Ecto.UUID.generate())
    ]

    for forged <- changed do
      :ok = forge!(ctx.schema, task, %{"posting" => forged})
      conn = complete_route(task, ctx.tok_a)
      assert conn.status in [409, 422], "#{conn.status} #{conn.resp_body}"
      assert nothing?(ctx, doc["id"])
      assert pending?(ctx.schema, task)
    end

    :ok = forge!(ctx.schema, task, original)
    assert complete_route(task, ctx.tok_a).status == 200
    assert P.counts(ctx, doc["id"]) == %{entries: %{"receipt" => 1}, marks: 1}
  end

  # -- IB-4 ---------------------------------------------------------------------------------------

  describe "IB-4 reverse_document" do
    defp reversal_task!(ctx, doc) do
      P.post_and_complete!(ctx, doc["id"])

      P.req(ctx, :post, doc["id"], "reverse", %{"reason_code" => "wrong_document"})
      |> P.status!(200)

      P.pending_task(ctx, doc["id"], "reverse")
    end

    defp entry_id(ctx, id) do
      %{rows: [[entry]]} =
        Repo.query!(~s|SELECT id FROM "#{ctx.schema}".ledger_entry WHERE document_id = $1|, [id])

      Ecto.UUID.cast!(entry)
    end

    test "IB-4a another document's entry cannot be reversed from this reversal task", ctx do
      doc_a = P.issue!(ctx)
      doc_b = P.issue!(ctx)
      task_a = reversal_task!(ctx, doc_a)
      P.post_and_complete!(ctx, doc_b["id"])

      forged_posting =
        Map.put(
          vars(ctx.schema, task_a)["posting"],
          "reverses_entry_id",
          entry_id(ctx, doc_b["id"])
        )

      :ok = forge!(ctx.schema, task_a, %{"posting" => forged_posting})

      conn = complete_route(task_a, ctx.tok_a)
      assert refused?(conn), "#{conn.status} #{conn.resp_body}"
      assert pending?(ctx.schema, task_a)
      assert P.counts(ctx, doc_a["id"]) == %{entries: %{"receipt" => 1}, marks: 1}
      assert P.counts(ctx, doc_b["id"]) == %{entries: %{"receipt" => 1}, marks: 1}
    end

    test "IB-4b the mark of another document, another reason: refused, nothing reversed", ctx do
      doc_a = P.issue!(ctx)
      doc_b = P.issue!(ctx)
      task_a = reversal_task!(ctx, doc_a)
      P.post_and_complete!(ctx, doc_b["id"])
      original = vars(ctx.schema, task_a)

      for forged <- [
            %{"document_id" => doc_b["id"]},
            %{"posting" => Map.put(original["posting"], "document_id", doc_b["id"])},
            %{"reason_code" => "other"},
            %{"mark" => "posted"}
          ] do
        :ok = forge!(ctx.schema, task_a, forged)
        conn = complete_route(task_a, ctx.tok_a)
        assert conn.status in [409, 422], "#{inspect(forged)}: #{conn.status} #{conn.resp_body}"
        assert pending?(ctx.schema, task_a)
        assert P.counts(ctx, doc_a["id"]).entries == %{"receipt" => 1}
        assert P.counts(ctx, doc_b["id"]).entries == %{"receipt" => 1}
        :ok = forge!(ctx.schema, task_a, original)
      end

      assert complete_route(task_a, ctx.tok_a).status == 200
      assert P.counts(ctx, doc_a["id"]).entries == %{"receipt" => 1, "reversal" => 1}
      assert P.counts(ctx, doc_b["id"]).entries == %{"receipt" => 1}
    end
  end

  # -- IB-5 ---------------------------------------------------------------------------------------

  test "IB-5 an honest completion posts as before (receipt, opening, reversal)", ctx do
    doc = P.issue!(ctx)
    assert complete_route(P.pending_task(ctx, doc["id"], "post"), ctx.tok_a).status == 200
    assert P.counts(ctx, doc["id"]) == %{entries: %{"receipt" => 1}, marks: 1}

    opening = O.issue!(ctx)
    approve = O.task(ctx, opening["id"], "approve", :pending)
    assert complete_route(approve, ctx.tok_u2).status == 200
    assert P.counts(ctx, opening["id"]) == %{entries: %{"opening" => 1}, marks: 1}
  end

  # -- IB-6 ---------------------------------------------------------------------------------------

  test "IB-6 tenant B's document and entry cannot be posted or reversed from tenant A's task",
       ctx do
    ctx_b = %{ctx | tok_a: ctx.tok_b, schema: ctx.b.schema_name, ma: ctx.mb}
    doc_b = P.issue!(ctx_b)
    task_b = P.pending_task(ctx_b, doc_b["id"], "post")
    vars_b = vars(ctx_b.schema, task_b)

    doc_a = P.issue!(ctx)
    task_a = P.pending_task(ctx, doc_a["id"], "post")

    :ok = forge!(ctx.schema, task_a, Map.take(vars_b, @target_keys))
    conn = complete_route(task_a, ctx.tok_a)
    assert conn.status in [409, 422], "#{conn.status} #{conn.resp_body}"
    assert nothing?(ctx, doc_a["id"])
    assert nothing?(ctx_b, doc_b["id"])
    assert pending?(ctx_b.schema, task_b)
    assert vars(ctx_b.schema, task_b) == vars_b

    # a reversal task of tenant A pointed at tenant B's posted entry
    doc_a2 = P.issue!(ctx)
    task_r = reversal_task!(ctx, doc_a2)
    assert complete_route(P.pending_task(ctx_b, doc_b["id"], "post"), ctx.tok_b).status == 200

    forged =
      Map.put(
        vars(ctx.schema, task_r)["posting"],
        "reverses_entry_id",
        entry_id(ctx_b, doc_b["id"])
      )

    :ok = forge!(ctx.schema, task_r, %{"posting" => forged})
    conn = complete_route(task_r, ctx.tok_a)
    assert conn.status in [409, 422], "#{conn.status} #{conn.resp_body}"
    assert P.counts(ctx_b, doc_b["id"]) == %{entries: %{"receipt" => 1}, marks: 1}
    assert P.counts(ctx, doc_a2["id"]) == %{entries: %{"receipt" => 1}, marks: 1}
  end

  # -- IB-7 ---------------------------------------------------------------------------------------

  test "IB-7 read_instance_start refuses a forged or absent context", ctx do
    forged = %Letflow.Entities.HandlerContext{
      prefix: ctx.schema,
      instance_id: Ecto.UUID.generate(),
      origin: {:task, Ecto.UUID.generate()},
      node_id: "post",
      definition_id: Ecto.UUID.generate(),
      definition_version: "1.0.0",
      line_index: 0,
      actor_id: Ecto.UUID.generate(),
      subject_id: Ecto.UUID.generate(),
      activator_id: Ecto.UUID.generate(),
      handler: %{module_id: "stock", name: "post_document", targets: []}
    }

    # outside a handler call there is no per-call token: the same closed answer as `read/3`
    assert {:error, :invalid_write_command} = HandlerWrites.read_instance_start(forged)
    assert {:error, :invalid_write_command} = HandlerWrites.read_instance_start(%{})
  end
end
