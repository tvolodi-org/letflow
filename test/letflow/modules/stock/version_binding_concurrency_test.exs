Code.require_file("posting_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.VersionBindingConcurrencyTest do
  @moduledoc """
  REQ-905 / GH #4817 (ledger slice L7 part 2e, decision 0073 D6 and the L7 row): tests only, no lib/ change.
  The posting binding of REQ-903 and the typed codes of REQ-901 and REQ-904 change what a completer can learn
  and what can be written twice; this file proves two properties of the post path:

    * two post tasks of one issued version completed at the same time give exactly one ledger entry and one
      posted mark (VBC-CC-1), and after the first committed a second completion adds nothing (VBC-SEQ-1);
    * a completer of tenant B cannot post tenant A's document (VBC-XT-1), and a master retired in tenant B and
      named in a tenant A posting is judged by A's own state only (VBC-XT-2). INV-1, INV-5, INV-10.

  Committed tenants, Sandbox `:auto`, `async: false` (a lock test cannot run in the shared sandbox mode of the
  router tests). Concurrency is bounded: two processes, a barrier message instead of a sleep, each process
  bounded by a timeout. Authority-before-release (decision 0073) is exercised in `version_binding_test.exs`
  (VB-AUTH-1) and `master_posting_test.exs` (MI-AUTH-1); the cross-tenant tests here use a completer that holds
  the posting permission in ITS OWN tenant.
  """

  use Letflow.DataCase, async: false

  @moduletag timeout: 300_000
  @process_timeout 60_000

  import Ecto.Query, only: [from: 2]

  alias Letflow.Documents
  alias Letflow.Engine
  alias Letflow.EntityWritesFixture, as: Fixture
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Repo
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S
  alias Letflow.StockPostingFixture, as: P

  setup do
    ctx = P.setup!([:a, :b])
    Map.merge(ctx, P.tenant_b!(ctx))
  end

  # -- helpers ------------------------------------------------------------------------------------

  defp one_line_body(ma, quantity \\ "2") do
    D.body(ma, nil, %{
      "kind" => "receipt",
      "lines" => [
        %{"catalog_item_id" => ma.item, "catalog_uom_id" => ma.uom, "quantity" => quantity}
      ]
    })
  end

  defp instance(schema, task), do: Repo.get!(InstanceProjection, task.instance_id, prefix: schema)

  # A second instance of the same issued version, started like the generic instance start route does
  # (`Engine.create/2` with the variables of the first one), by the TENANT_ADMIN holder.
  defp start_second!(ctx, vars) do
    {:ok, _} =
      Engine.create(
        %{
          definition_name: "stock_receipt",
          initial_variables: vars,
          actor_id: ctx.holder.id,
          idempotency_key: "vbc-#{Ecto.UUID.generate()}"
        },
        prefix: ctx.schema,
        module_start: true
      )
  end

  # Every pending post task of the document, oldest first.
  defp post_tasks(schema, id) do
    Repo.all(
      from(t in Letflow.Engine.Task,
        join: p in InstanceProjection,
        on: p.instance_id == t.instance_id,
        where:
          t.status == :pending and t.node_id == "post" and
            fragment("?->>'document_id' = ?", p.variables, ^id),
        order_by: [asc: t.inserted_at, asc: t.id]
      ),
      prefix: schema
    )
  end

  defp task_status(schema, task),
    do: Repo.get!(Letflow.Engine.Task, task.id, prefix: schema).status

  defp quantity_on_hand(ctx, sku) do
    rows = S.get("/balances?sku=#{sku}", ctx.tok_a) |> P.status!(200) |> Map.fetch!("rows")
    rows |> Enum.map(&Decimal.new(&1["quantity"])) |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
  end

  defp complete_route(task, token, body) do
    conn =
      Plug.Test.conn(:post, "/api/v1/tasks/#{task.id}/complete", Jason.encode!(body))
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    Letflow.Router.call(conn, Letflow.Router.init([]))
  end

  # Two processes, each completes its own task as soon as both are ready: no sleep, a barrier message.
  # Each process is bounded by @process_timeout (`Task.yield` then `Task.shutdown`), so a hang fails.
  defp complete_together(ctx, task_1, task_2) do
    parent = self()

    workers =
      for task <- [task_1, task_2] do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> :ok
          after
            @process_timeout -> exit(:no_go)
          end

          try do
            P.complete(ctx, task)
          rescue
            e -> {:raised, e}
          end
        end)
      end

    for _ <- workers do
      assert_receive {:ready, pid}, @process_timeout
      assert is_pid(pid)
    end

    Enum.each(workers, &send(&1.pid, :go))

    for w <- workers do
      case Task.yield(w, @process_timeout) || Task.shutdown(w, :brutal_kill) do
        {:ok, result} -> result
        nil -> flunk("a completion did not finish within #{@process_timeout} ms")
      end
    end
  end

  # -- criterion 1 --------------------------------------------------------------------------------

  test "VBC-CC-1 two concurrent posts of one issued version: one entry, one posted mark, no 500",
       ctx do
    doc = P.issue!(ctx, one_line_body(ctx.ma))
    id = doc["id"]
    first = P.pending_task(ctx, id, "post") || flunk("no post task")
    start_second!(ctx, instance(ctx.schema, first).variables)

    [t1, t2] = post_tasks(ctx.schema, id)
    assert t1.id != t2.id and t1.instance_id != t2.instance_id

    results = complete_together(ctx, t1, t2)

    assert Enum.all?(results, fn
             {:ok, _} -> true
             {:error, {:entity_write_refused, _line, code}} -> code in [:validation_failed]
             _other -> false
           end),
           "no raise, no untyped answer: #{inspect(results)}"

    oks = Enum.filter(results, &match?({:ok, _}, &1))
    assert length(oks) >= 1

    assert P.counts(ctx, id) == %{entries: %{"receipt" => 1}, marks: 1}
    assert [mark] = marks(ctx, id)
    assert mark["mark"] == "posted"
    assert Decimal.equal?(quantity_on_hand(ctx, ctx.ma.item), Decimal.new(2))

    # the losing completion committed nothing: its task is still pending, or it was answered with the
    # ledger's duplicate result (then it is completed and added no second entry, checked above)
    for {result, task} <- Enum.zip(results, [t1, t2]) do
      case result do
        {:error, _typed} -> assert task_status(ctx.schema, task) == :pending
        {:ok, _} -> assert task_status(ctx.schema, task) == :completed
      end
    end

    # and the real route never answers a 5xx for the second completion of a posted version
    for task <- [t1, t2], task_status(ctx.schema, task) == :pending do
      conn = complete_route(task, ctx.tok_a, %{})
      assert conn.status in 400..499, "expected a typed 4xx, got #{conn.status}"
      assert P.counts(ctx, id) == %{entries: %{"receipt" => 1}, marks: 1}
    end
  end

  # -- criterion 2 --------------------------------------------------------------------------------

  test "VBC-SEQ-1 the second instance completed after the first committed adds no entry, no mark",
       ctx do
    doc = P.issue!(ctx, one_line_body(ctx.ma))
    id = doc["id"]
    first = P.pending_task(ctx, id, "post") || flunk("no post task")
    start_second!(ctx, instance(ctx.schema, first).variables)
    [t1, t2] = post_tasks(ctx.schema, id)

    assert {:ok, _} = P.complete(ctx, t1)
    assert P.counts(ctx, id) == %{entries: %{"receipt" => 1}, marks: 1}

    assert {:error, {:entity_write_refused, _line, :validation_failed}} = P.complete(ctx, t2)
    assert P.counts(ctx, id) == %{entries: %{"receipt" => 1}, marks: 1}
    assert task_status(ctx.schema, t2) == :pending

    conn = complete_route(t2, ctx.tok_a, %{})
    assert conn.status == 422
    assert Jason.decode!(conn.resp_body)["error"] == "validation_failed"
    assert P.counts(ctx, id) == %{entries: %{"receipt" => 1}, marks: 1}
    assert Decimal.equal?(quantity_on_hand(ctx, ctx.ma.item), Decimal.new(2))
  end

  # -- criterion 3 --------------------------------------------------------------------------------

  test "VBC-XT-1 a tenant B completer naming tenant A's issued document: 422, nothing moves",
       ctx do
    doc_a = P.issue!(ctx, one_line_body(ctx.ma, "7"))
    task_a = P.pending_task(ctx, doc_a["id"], "post") || flunk("no post task of A")
    vars_a = instance(ctx.schema, task_a).variables
    posting_a = vars_a["posting"]

    # tenant B's own issued receipt and its pending post task
    doc_b =
      D.request(:post, "/documents", ctx.tok_b, D.body(ctx.mb)) |> P.status!(201)

    issued_b = D.request(:post, "/documents/#{doc_b["id"]}/issue", ctx.tok_b) |> P.status!(200)
    schema_b = ctx.b.schema_name

    task_b =
      P.pending_task(%{schema: schema_b}, issued_b["id"], "post") || flunk("no post task of B")

    output = %{
      "document_id" => doc_a["id"],
      "version_no" => vars_a["version_no"],
      "posting" => posting_a
    }

    assert posting_a["document_id"] == doc_a["id"] and is_binary(posting_a["client_op_id"])

    before_a = P.counts(ctx, doc_a["id"])
    before_b = P.counts(%{schema: schema_b}, issued_b["id"])

    # T-2430: the body cannot carry a write target at all (422 `output_refused`, nothing written,
    # no handler reached); the handler's own cross-tenant check is then reached with B's instance
    # variables forged directly, as a second line of defence.
    refused = complete_route(task_b, ctx.tok_b, output)
    assert refused.status == 422, "expected 422, got #{refused.status}: #{refused.resp_body}"
    assert Jason.decode!(refused.resp_body)["code"] == "output_refused"
    refute refused.resp_body =~ doc_a["id"]
    assert Fixture.audit_rows(schema_b, "entity_write.refused") == []
    assert task_status(schema_b, task_b) == :pending

    :ok = P.tamper!(%{schema: schema_b}, task_b, output)
    conn = complete_route(task_b, ctx.tok_b, %{})

    assert conn.status == 422, "expected 422, got #{conn.status}: #{conn.resp_body}"
    assert Jason.decode!(conn.resp_body)["error"] == "validation_failed"
    refute conn.resp_body =~ "record_version_conflict"
    refute conn.resp_body =~ doc_a["id"]
    refute conn.resp_body =~ posting_a["client_op_id"]

    [entry | _] = Enum.reverse(Fixture.audit_rows(schema_b, "entity_write.refused"))
    assert entry.after_state["detail"] == "handler_invalid_arguments"

    # tenant A's document, ledger and marks are unchanged; tenant B's task is still pending
    assert P.counts(ctx, doc_a["id"]) == before_a
    assert before_a == %{entries: %{}, marks: 0}
    assert P.pending_task(ctx, doc_a["id"], "post").id == task_a.id
    assert P.counts(%{schema: schema_b}, issued_b["id"]) == before_b
    assert task_status(schema_b, task_b) == :pending
    assert Fixture.audit_rows(ctx.schema, "entity_write.refused") == []
  end

  # -- criterion 4 --------------------------------------------------------------------------------

  test "VBC-XT-2 an item that exists only in tenant B, retired there, in A's posting: 422, not 409",
       ctx do
    b_item = ctx.mb.item

    r =
      Repo.get_by!(
        Letflow.Entities.Record.Latest,
        [record_id: b_item, entity_type: "catalog_item"],
        prefix: ctx.b.schema_name
      )

    Letflow.CatalogItemsFixture.update!(
      ctx.b.schema_name,
      r,
      Map.put(r.field_values, "active", false)
    )

    assert Repo.get_by(
             Letflow.Entities.Record.Latest,
             [record_id: b_item, entity_type: "catalog_item"],
             prefix: ctx.schema
           ) == nil

    # An issued document of A whose content names B's item. The stock issue route refuses such a document
    # (its masters are checked), so the test builds the version with the core documents context and starts
    # the post the way the generic instance start route does: the binding then holds (the posting equals
    # the issued content) and the handler reaches the master checks of REQ-832 / REQ-904 with B's id.
    good = P.issue!(ctx, one_line_body(ctx.ma))
    good_task = P.pending_task(ctx, good["id"], "post") || flunk("no post task")
    vars = instance(ctx.schema, good_task).variables

    {:ok, good_version} =
      Documents.read_version_for_module(ctx.schema, "stock", good["id"], vars["version_no"])

    content = put_in(good_version["content"], ["lines", Access.at(0), "catalog_item_id"], b_item)

    {:ok, %{document: document}} =
      Documents.create_draft(
        ctx.schema,
        %{
          type_key: good_version["type_key"],
          issuing_org_unit_id: good_version["issuing_org_unit_id"],
          content: content
        },
        ctx.holder.id
      )

    {:ok, _} = Documents.issue(ctx.schema, %{document_id: document.id, actor_id: ctx.holder.id})

    {:ok, issued} =
      Documents.read_version_for_module(ctx.schema, "stock", document.id, 1)

    posting =
      vars["posting"]
      |> Map.put("document_id", document.id)
      |> Map.put("client_op_id", issued["version_id"])
      |> Map.update!("lines", fn [line | rest] -> [Map.put(line, "sku", b_item) | rest] end)

    start_second!(
      ctx,
      Map.merge(vars, %{"document_id" => document.id, "version_no" => 1, "posting" => posting})
    )

    task = P.pending_task(ctx, document.id, "post") || flunk("no post task of the built version")
    conn = complete_route(task, ctx.tok_a, %{})

    assert conn.status == 422, "expected 422, got #{conn.status}: #{conn.resp_body}"
    assert Jason.decode!(conn.resp_body)["error"] == "validation_failed"
    refute conn.resp_body =~ "master_inactive"
    refute conn.resp_body =~ "record_version_conflict"
    refute conn.resp_body =~ b_item

    [entry | _] = Enum.reverse(Fixture.audit_rows(ctx.schema, "entity_write.refused"))
    assert entry.after_state["detail"] == "handler_invalid_arguments"

    assert P.counts(ctx, document.id) == %{entries: %{}, marks: 0}
    assert task_status(ctx.schema, task) == :pending
  end

  # -- support ------------------------------------------------------------------------------------

  defp marks(ctx, id) do
    Repo.all(
      from(r in Letflow.Entities.Record.Latest,
        where:
          r.entity_type == "stock_posting_mark" and not r.deleted and
            fragment("?->>'document_id' = ?", r.field_values, ^id),
        select: r.field_values
      ),
      prefix: ctx.schema
    )
  end
end
