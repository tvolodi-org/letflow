Code.require_file("count_freeze_fixture.exs", __DIR__)

defmodule Letflow.Modules.Stock.CountFreezeLockTest do
  @moduledoc """
  REQ-765 / GH #3906 criterion 6 (F20 to F22): the lock order of the freeze open. Committed fresh tenant in
  Sandbox `:auto` mode, `async: false`, two processes. The test seams are the two hooks of
  `Letflow.Modules.Stock.FreezeGuard` (`:open_locked` after the exclusive hold of `CountSheet.open/3`,
  `:guard_checked` after the reads of `FreezeGuard.check/2`); a held process is released by a message, and
  every wait is a bounded `receive` or `Task.yield`, no sleep.
  """

  use Letflow.DataCase, async: false

  alias Letflow.CountFreezeFixture, as: C
  alias Letflow.StockDocsFixture, as: D
  alias Letflow.StockFixture, as: S
  alias Letflow.StockPostingFixture, as: P

  @hold_ms 1_500

  setup do
    ctx = S.setup_oidc!([:a])
    on_exit(fn -> Application.delete_env(:letflow, :stock_freeze_test_hook) end)
    Map.put(ctx, :tok_a, S.token(ctx, :a, ["TENANT_ADMIN"]))
  end

  defp hook!(point),
    do: Application.put_env(:letflow, :stock_freeze_test_hook, {:wait, self(), point})

  defp async_open(x, id) do
    Task.async(fn ->
      try do
        C.call(:post, "/counts/#{id}/open", x.chair_tok, %{})
      rescue
        e -> {:raised, e}
      end
    end)
  end

  defp receipt_task!(x, qty) do
    doc = P.issue!(x, D.body(x.ma, nil, %{"lines" => [C.plain_line(x.ma, qty)]}))
    {doc, P.pending_task(x, doc["id"], "post") || flunk("no post task")}
  end

  defp lines(x, id), do: C.status!(C.call(:get, "/counts/#{id}/lines", x.chair_tok), 200)["rows"]

  test "F20 A holds the exclusive hold, B waits and is refused location_frozen after A commits; no sheet line for B",
       ctx do
    x = C.world!(ctx, :a)
    id = C.ordered!(x, %{"freeze_locations" => true})
    number = C.count(x, id)["number"]
    {doc, task} = receipt_task!(x, "5")

    hook!(:open_locked)
    a = async_open(x, id)
    assert_receive {:stock_freeze_hook, :open_locked, a_pid}, 15_000

    b = Task.async(fn -> P.complete(x, task) end)
    assert Task.yield(b, @hold_ms) == nil, "B must wait for the exclusive hold"
    assert P.counts(x, doc["id"]).marks == 0

    send(a_pid, :go)
    assert %Plug.Conn{status: 200} = Task.await(a, 30_000)
    assert C.held_by!(Task.await(b, 30_000)) == number
    assert lines(x, id) == []
    assert P.counts(x, doc["id"]) == %{entries: %{}, marks: 0}
  end

  test "F21 A fails after the lock: nothing is frozen and B's receipt posts", ctx do
    x = C.world!(ctx, :a)
    id = C.ordered!(x, %{"freeze_locations" => true})
    {doc, task} = receipt_task!(x, "5")

    hook!(:open_locked)
    a = async_open(x, id)
    assert_receive {:stock_freeze_hook, :open_locked, a_pid}, 15_000

    b = Task.async(fn -> P.complete(x, task) end)
    assert Task.yield(b, @hold_ms) == nil
    send(a_pid, :fail)

    result = Task.await(a, 30_000)
    refute match?(%Plug.Conn{status: 200}, result)
    assert {:ok, _} = Task.await(b, 30_000)
    assert P.counts(x, doc["id"]).marks == 1
    assert C.count(x, id)["status"] == "ordered" and C.count(x, id)["freeze_state"] == "none"
  end

  test "F22 B holds the shared lock after its guard call while A opens: A's cutoff_seq includes B's posting",
       ctx do
    x = C.world!(ctx, :a)
    id = C.ordered!(x, %{"freeze_locations" => true})
    {doc, task} = receipt_task!(x, "5")

    hook!(:guard_checked)
    b = Task.async(fn -> P.complete(x, task) end)
    assert_receive {:stock_freeze_hook, :guard_checked, b_pid}, 15_000

    a = async_open(x, id)
    assert Task.yield(a, @hold_ms) == nil, "A waits for B's shared hold"

    send(b_pid, :go)
    assert {:ok, _} = Task.await(b, 30_000)
    assert %Plug.Conn{status: 200} = Task.await(a, 30_000)
    assert P.counts(x, doc["id"]).marks == 1

    assert [%{"book_quantity" => qty}] = lines(x, id)
    assert Decimal.equal?(Decimal.new(qty), 5)
    assert C.count(x, id)["cutoff_seq"] >= 1
  end

  test "F22b the moduledoc of FreezeGuard states the lock order" do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(Letflow.Modules.Stock.FreezeGuard)
    assert doc =~ "Lock order"
    assert doc =~ "hold_exclusive!"
    assert doc =~ "INSIDE the transaction"
    assert doc =~ "shared hold lock"
  end
end
