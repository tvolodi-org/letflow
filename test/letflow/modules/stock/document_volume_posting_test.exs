Code.require_file("volume_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.DocumentVolumePostingTest do
  @moduledoc """
  REQ-774 criteria 5, 6 and 7: a transfer of 1000 lines posts as ONE ledger entry of 2000 legs through the
  real task completion, written in chunks of at most 500 rows per INSERT inside the one transaction; a
  refusal or a forced failure writes nothing; a repeat is one entry; the reversal reads and writes 2000
  legs. Committed tenant, Sandbox `:auto`, `async: false`. Tests: C5-1, C6-a, C6-b, C7-1.
  """

  use Letflow.DataCase, async: false

  alias Letflow.LedgerFixture, as: LF
  alias Letflow.Repo
  alias Letflow.StockFixture, as: S
  alias Letflow.StockPostingFixture, as: P
  alias Letflow.StockVolumeFixture, as: V

  @lines 1000
  @moduletag timeout: 600_000

  setup do
    ctx = P.setup!()
    ctx = Map.put(ctx, :m2, Letflow.StockTwoSideFixture.b2!(ctx))

    # the OIDC verifier loads the issuer metadata at the first token: do it before the slow item setup
    S.get("/balances", ctx.tok_a) |> P.status!(200)
    ctx
  end

  # 1000 catalog items (one per line); a fresh token afterwards, the item setup takes a while
  defp with_items(ctx) do
    items = V.items!(ctx, @lines)
    ctx |> Map.put(:items, items) |> Map.put(:tok_a, S.token(ctx, :a, ["TENANT_ADMIN"]))
  end

  defp complete_recorded(ctx, id) do
    task = P.pending_task(ctx, id, "post") || flunk("no pending post task")
    LF.record(fn -> P.complete(ctx, task) end)
  end

  test "C5-1 + C7-1 1000 lines: one entry of 2000 legs in chunks, a repeat is one entry, reversal",
       ctx do
    ctx = with_items(ctx)
    V.receive_all!(ctx, ctx.items, "5")
    before = V.balances(ctx)
    assert length(before) == @lines

    doc = P.issue!(ctx, V.transfer_body(ctx, ctx.items, "2"))
    assert length(doc["lines"]) == @lines

    completed_task_id = P.pending_task(ctx, doc["id"], "post").id
    {result, statements} = complete_recorded(ctx, doc["id"])
    assert {:ok, _} = result

    # one entry, 2000 legs, one mark
    assert P.counts(ctx, doc["id"]) == %{entries: %{"transfer" => 1}, marks: 1}
    assert V.leg_counts(ctx, doc["id"]) == [2000]

    %{rows: [[legs, distinct]]} =
      Repo.query!(
        ~s|SELECT count(*), count(DISTINCT leg_no) FROM "#{ctx.schema}".ledger_leg WHERE entry_id = (SELECT id FROM "#{ctx.schema}".ledger_entry WHERE document_id = $1)|,
        [doc["id"]]
      )

    assert {legs, distinct} == {2000, 2000}

    # chunking: leg and balance INSERTs carry at most 500 rows each, in the same transaction
    leg_inserts = V.insert_rows(statements, ctx.schema, "ledger_leg")
    assert leg_inserts == [500, 500, 500, 500]

    balance_inserts = V.insert_rows(statements, ctx.schema, "ledger_balance")
    assert Enum.all?(balance_inserts, &(&1 <= 500)) and length(balance_inserts) >= 2
    assert Enum.sum(balance_inserts) == 2 * @lines

    # the view and the reconcile of the ledger agree
    posted = P.get!(ctx, doc["id"])
    assert posted["state"] == "posted" and posted["posting_check"] == "ok"

    assert %{"mismatches" => [], "gap_check" => "ok", "chain_check" => "ok"} =
             S.get("/reconcile", ctx.tok_a) |> P.status!(200)

    # the balances: every from side 3, every to side 2
    after_post = V.balances(ctx)
    assert length(after_post) == 2 * @lines
    quantities = after_post |> Enum.map(&List.last/1) |> Enum.frequencies()
    assert quantities == %{"3" => @lines, "2" => @lines}

    # C6-c: the completed task completed again (refused or answered): still one entry
    task = Repo.get!(Letflow.Engine.Task, completed_task_id, prefix: ctx.schema)
    _ = P.complete(ctx, task)
    assert P.counts(ctx, doc["id"]) == %{entries: %{"transfer" => 1}, marks: 1}

    # C7-1: the reversal posts one entry of 2000 legs and the balances return
    P.req(ctx, :post, doc["id"], "reverse", %{"reason_code" => "wrong_document"})
    |> P.status!(200)

    assert {:ok, _} = P.complete(ctx, P.pending_task(ctx, doc["id"], "reverse"))
    assert V.leg_counts(ctx, doc["id"]) == [2000, 2000]
    assert P.counts(ctx, doc["id"]).entries == %{"transfer" => 1, "reversal" => 1}

    reversed = P.get!(ctx, doc["id"])
    assert reversed["state"] == "reversed" and reversed["posting_check"] == "ok"

    back = V.balances(ctx)
    assert Enum.map(back, &Enum.take(&1, 4)) == Enum.map(after_post, &Enum.take(&1, 4))

    assert back |> Enum.map(&List.last/1) |> Enum.frequencies() == %{"5" => @lines, "0" => @lines}

    assert %{"mismatches" => [], "gap_check" => "ok"} =
             S.get("/reconcile", ctx.tok_a) |> P.status!(200)
  end

  test "C6-a line 1000 above the stock: refused, nothing written, task pending", ctx do
    ctx = with_items(ctx)
    {first, [last]} = Enum.split(ctx.items, @lines - 1)
    V.receive_all!(ctx, first, "5")
    before = V.balances(ctx)

    doc = P.issue!(ctx, V.transfer_body(ctx, ctx.items, "2"))
    task = P.pending_task(ctx, doc["id"], "post")
    assert last in ctx.items
    assert {:error, _} = P.complete(ctx, task)

    assert P.counts(ctx, doc["id"]) == %{entries: %{}, marks: 0}
    assert V.balances(ctx) == before
    assert P.pending_task(ctx, doc["id"], "post").id == task.id
  end

  test "C6-b a failure on the last chunk rolls the whole posting back", ctx do
    ctx = with_items(ctx)
    V.receive_all!(ctx, ctx.items, "5")
    before = V.balances(ctx)
    schema = ctx.schema

    doc = P.issue!(ctx, V.transfer_body(ctx, ctx.items, "2"))
    task = P.pending_task(ctx, doc["id"], "post")

    Repo.query!("""
    CREATE FUNCTION "#{schema}".r774_fail() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'r774 injected failure' USING ERRCODE = 'unique_violation';
    END
    $$
    """)

    # leg 2000 is in the fourth chunk: chunks one to three are already written when it fires
    Repo.query!("""
    CREATE TRIGGER r774_fail BEFORE INSERT ON "#{schema}".ledger_leg
    FOR EACH ROW WHEN (NEW.leg_no = 2000)
    EXECUTE FUNCTION "#{schema}".r774_fail()
    """)

    {result, statements} =
      LF.record(fn ->
        try do
          P.complete(ctx, task)
        rescue
          e in [Postgrex.Error] -> {:raised, e.postgres.code}
        end
      end)

    assert match?({:error, _}, result) or match?({:raised, :unique_violation}, result),
           inspect(result)

    # the first three chunks did run before the failure
    assert V.insert_rows(statements, schema, "ledger_leg") |> Enum.take(3) == [500, 500, 500]

    assert P.counts(ctx, doc["id"]) == %{entries: %{}, marks: 0}
    assert V.balances(ctx) == before

    %{rows: [[legs]]} =
      Repo.query!(~s|SELECT count(*) FROM "#{schema}".ledger_leg WHERE leg_no > 1000|)

    assert legs == 0
    assert P.pending_task(ctx, doc["id"], "post").id == task.id
    assert P.get!(ctx, doc["id"])["state"] == "issued"
  end

  test "P4-1 the command of a 1000-line transfer with the widest quantities fits 1 MiB and posts",
       ctx do
    # one item on every line: the size of the command does not depend on the number of balance keys
    item = ctx.ma.item
    one = V.lines(ctx, [item], "5000")
    V.receive_all!(ctx, [item], "5000") |> then(fn _ -> one end)

    lines = V.lines(ctx, List.duplicate(item, @lines), "1.123456789")

    body =
      Letflow.StockTwoSideFixture.body("transfer", ctx.ma, ctx.ma, ctx.m2, %{"lines" => lines})

    doc = P.issue!(ctx, body)
    task = P.pending_task(ctx, doc["id"], "post")

    instance =
      Repo.get!(Letflow.EventStore.InstanceProjection, task.instance_id, prefix: ctx.schema)

    posting = instance.variables["posting"]
    assert length(posting["lines"]) == @lines
    size = byte_size(:erlang.term_to_binary(posting))
    assert size <= 1_048_576, "the stored posting variable is #{size} bytes"
    assert size > 262_144, "the old 256 KiB cap would refuse it (#{size} bytes)"

    assert {:ok, _} = P.complete(ctx, task)
    assert V.leg_counts(ctx, doc["id"]) == [2000]
  end
end
