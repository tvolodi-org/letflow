defmodule Letflow.Ledger.LockOrderTest do
  @moduledoc """
  REQ-621 / GH #3469 part A, criterion 2: T-LK-1a (AB-BA overlap raises no deadlock) and T-LK-1b
  (the statements a posting sends: missing rows inserted ascending, then locked ascending one key at
  a time, the counter last; a refused posting never touches the counter) and, from part C (criterion 9), T-LK-3 (a lock
  timeout on the counter row propagates unrescued, nothing is committed, a retry posts). The counter-order
  assertions are statement-order recordings, not lock probes.
  Sandbox `:auto` with real commits, hence `async: false`.

  REQ-686 (slice L3c) adds the engine-level cases of decision 0061's class 5b, ids `T-LK-1e`,
  `T-LK-2`..`T-LK-6` ("e" = through the engine, to keep them apart from the core cases above):
  completions of a module-stamped HUMAN_TASK on a committed tenant, forced overlaps by a held row.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Ledger.HandlerPost
  alias Letflow.LedgerFixture, as: Fx
  alias Letflow.LedgerPostFixture, as: PFx
  alias Letflow.Ledger
  alias Letflow.LockOrderHelpers, as: H
  alias Letflow.Repo

  setup do
    Fx.setup_auto_mode!()
    :ok = H.attach_error_handler(__MODULE__)
    %{schema: Fx.tenant!()}
  end

  # classify a recorded statement; the key is read from the bound parameters
  defp classify({sql, params}) do
    key = Enum.find(params, &(&1 in ["a1", "b1"]))

    cond do
      sql =~ ~r/INSERT INTO "[^"]+"\."ledger_balance"/ -> {:insert_balance, key}
      sql =~ ~r/FROM "[^"]+"\."ledger_balance".*FOR UPDATE/s -> {:lock_balance, key}
      sql =~ ~r/INSERT INTO "[^"]+"\."ledger_counter"/ -> :insert_counter
      sql =~ ~r/FROM "[^"]+"\."ledger_counter".*FOR UPDATE/s -> :lock_counter
      sql =~ "ledger_counter" -> :counter
      true -> nil
    end
  end

  defp classified(statements), do: statements |> Enum.map(&classify/1) |> Enum.reject(&is_nil/1)

  test "T-LK-1a legs (A,B) and (B,A) in forced overlap: both commit, no deadlock", %{
    schema: schema
  } do
    a = ["a1"]
    b = ["b1"]
    Fx.seed_on_hand!(schema, a, 1)
    Fx.seed_on_hand!(schema, b, 1)

    one = fn -> Fx.post_tx(Fx.capability(schema, "adjust", [Fx.leg(a, 1), Fx.leg(b, 1)])) end
    two = fn -> Fx.post_tx(Fx.capability(schema, "adjust", [Fx.leg(b, 1), Fx.leg(a, 1)])) end

    %{first: r1, second: r2} =
      H.forced_overlap(schema, {:ledger_balance, Fx.ledger_id(), a}, one, two)

    assert {:ok, _} = r1
    assert {:ok, _} = r2
    assert Decimal.eq?(Fx.balance(schema, a).on_hand, 3)
    assert Decimal.eq?(Fx.balance(schema, b).on_hand, 3)
    assert Fx.last_seq(schema) == 4
  end

  test "T-LK-1b statement order: inserts ascending, locks ascending, counter last", %{
    schema: schema
  } do
    legs = [Fx.leg(["b1"], 2), Fx.leg(["a1"], 2)]
    {result, statements} = Fx.record(fn -> Fx.post_tx(Fx.capability(schema, "receipt", legs)) end)
    assert {:ok, _} = result

    order = classified(statements)

    assert Enum.take(order, 5) == [
             {:insert_balance, "a1"},
             {:insert_balance, "b1"},
             {:lock_balance, "a1"},
             {:lock_balance, "b1"},
             :insert_counter
           ]

    assert Enum.at(order, 5) == :lock_counter
  end

  test "T-LK-1c a refused posting records the key locks and no counter statement", %{
    schema: schema
  } do
    Fx.seed_on_hand!(schema, ["a1"], 1)
    legs = [Fx.leg(["b1"], -1), Fx.leg(["a1"], -3)]
    {result, statements} = Fx.record(fn -> Fx.post_tx(Fx.capability(schema, "issue", legs)) end)

    assert {:error, {:ledger_refused, :insufficient_balance, _, _}} = result

    order = classified(statements)
    assert {:lock_balance, "a1"} in order and {:lock_balance, "b1"} in order
    refute Enum.any?(order, &(&1 in [:insert_counter, :lock_counter, :counter]))
    assert Fx.last_seq(schema) == 1
  end

  test "T-LK-3 a lock timeout (55P03) on the counter propagates, nothing is written, retry posts",
       %{schema: schema} do
    Fx.seed_on_hand!(schema, ["a1"], 1)
    entries = Fx.count(schema, "ledger_entry")
    legs = Fx.count(schema, "ledger_leg")
    assert Fx.last_seq(schema) == 1

    {holder, _backend} = H.hold_row(schema, {:ledger_counter, Fx.ledger_id()})
    cap = Fx.capability(schema, "receipt", [Fx.leg(["a1"], 2)])

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL lock_timeout = '200ms'")
          Ledger.post(cap)
        end)
      end

    assert error.postgres.code == :lock_not_available
    assert error.postgres.pg_code == "55P03"
    assert_receive {:deadlock_detected, _}, 5_000

    # the holder is still open: nothing was committed by the timed-out posting
    assert Fx.last_seq(schema) == 1
    assert Fx.count(schema, "ledger_entry") == entries
    assert Fx.count(schema, "ledger_leg") == legs
    assert Decimal.eq?(Fx.balance(schema, ["a1"]).on_hand, 1)

    send(holder.pid, :release)
    Task.await(holder, H.await_ms())

    assert {:ok, %{posting_seq: 2, duplicate: false}} = Fx.post_tx(cap)
    assert Decimal.eq?(Fx.balance(schema, ["a1"]).on_hand, 3)
  end

  # ---------------------------------------------------------------------------------------------
  # REQ-686: engine-level cases
  # ---------------------------------------------------------------------------------------------

  defp post_lines(order, doc \\ "d1") do
    for h <- order do
      ledger = if h == "post_alpha", do: "a", else: "b"
      PFx.post_line(h, PFx.posting("receipt", ledger, "5", %{"document_id" => doc}))
    end
  end

  defp engine_case(slug, lines), do: PFx.case!(slug, lines, committed: true)

  # Seeds one posting per ledger (key "a" in alpha, "b" in beta) so the barrier rows exist.
  defp seed_ledgers!(ctx) do
    seed = fn handler, key ->
      PFx.post_line(handler, PFx.posting("receipt", key, "1", %{"client_op_id" => "seed-#{key}"}))
    end

    assert {:ok, _} =
             PFx.run_lines(ctx, [seed.("post_alpha", "a"), seed.("post_beta", "b")],
               origin: {:task, Ecto.UUID.generate()}
             )
  end

  defp seqs(schema) do
    %{rows: rows} =
      Repo.query!(
        ~s|SELECT ledger_id, last_seq FROM "#{schema}".ledger_counter ORDER BY ledger_id|
      )

    rows
  end

  test "T-LK-1e opposite line orders in forced overlap: both commit, no deadlock" do
    ctx = engine_case("req686-lk1e", post_lines(["post_alpha", "post_beta"]))
    other = PFx.more_task!(ctx, post_lines(["post_beta", "post_alpha"], "d2"))
    seed_ledgers!(ctx)

    %{first: r1, second: r2} =
      H.forced_overlap(
        ctx.schema,
        {:ledger_counter, PFx.alpha()},
        fn -> PFx.complete(ctx) end,
        fn -> PFx.complete(other) end
      )

    assert {:ok, _} = r1
    assert {:ok, _} = r2
    assert seqs(ctx.schema) == [["fixture_ledger_post", 3], ["fixture_ledger_post:beta", 3]]
  end

  test "T-LK-2 a posting and a non-posting completion overlapping on the audit chain row" do
    ctx = engine_case("req686-lk2", post_lines(["post_alpha", "post_beta"]))
    plain = PFx.more_task!(ctx, [PFx.line("plain")])

    # class order of one posting completion: the ledger rows and counter, then the audit chain row
    {result, statements} = lf_record(fn -> PFx.complete(ctx) end)
    assert {:ok, _} = result
    sql = Enum.map(statements, &elem(&1, 0))
    counter = Enum.find_index(sql, &(&1 =~ ~r/UPDATE "[^"]+"\."ledger_counter"/))
    audit = Enum.find_index(sql, &(&1 =~ ~r/INSERT INTO "[^"]+"\."audit_chain_locks"/))
    assert counter && audit && counter < audit

    again = PFx.more_task!(ctx, post_lines(["post_alpha", "post_beta"], "d3"))

    %{first: r1, second: r2} =
      H.forced_overlap(
        ctx.schema,
        :audit_chain,
        fn -> PFx.complete(again) end,
        fn -> PFx.complete(plain) end
      )

    assert {:ok, _} = r1
    assert {:ok, _} = r2
  end

  defp lf_record(fun), do: Fx.record(fun)

  test "T-LK-3e a counter held beyond the lock timeout is the 503 contention, nothing committed" do
    ctx = engine_case("req686-lk3e", post_lines(["post_alpha"]))
    seed_ledgers!(ctx)
    before = seqs(ctx.schema)
    counts = PFx.ledger_counts(ctx.schema)

    {holder, _backend} = H.hold_row(ctx.schema, {:ledger_counter, PFx.alpha()})

    result = PFx.complete(ctx)
    assert {:error, {:entity_write_refused, :contention, :entity_write_contention}} = result

    send(holder.pid, :release)
    Task.await(holder, H.await_ms())

    assert seqs(ctx.schema) == before
    assert PFx.ledger_counts(ctx.schema) == counts
    # the task is still pending: the retry posts
    assert {:ok, _} = PFx.complete(ctx)
  end

  # REQ-688 (inverts the L3c pin "the SERVICE origin posting is refused"): the refusal without the
  # pre-step is still pinned in security_test.exs (T-SEC-1g, S-2); here the consented SERVICE
  # apply and a HUMAN completion overlap and both commit.
  test "T-LK-4a a HUMAN posting and a SERVICE posting on one balance key both commit" do
    ctx = engine_case("req688-lk4a", post_lines(["post_alpha"]))
    svc = PFx.more_service!(ctx, post_lines(["post_alpha"], "d2"))
    seed_ledgers!(ctx)

    %{first: r1, second: r2} =
      H.forced_overlap(
        ctx.schema,
        {:ledger_counter, PFx.alpha()},
        fn -> PFx.complete(ctx) end,
        fn -> Letflow.EntityWritesFixture.apply_http(svc, %{"label" => "x"}) end
      )

    assert {:ok, _} = r1
    assert {:ok, :advanced} = r2
    assert seqs(ctx.schema) |> hd() == ["fixture_ledger_post", 3]
  end

  test "T-LK-4b the SERVICE posting overlapping the balance row of a HUMAN posting commits" do
    ctx = engine_case("req688-lk4b", post_lines(["post_alpha"]))
    svc = PFx.more_service!(ctx, post_lines(["post_alpha"], "d2"))
    seed_ledgers!(ctx)

    %{first: r1, second: r2} =
      H.forced_overlap(
        ctx.schema,
        {:ledger_balance, PFx.alpha(), ["a", ""]},
        fn -> Letflow.EntityWritesFixture.apply_http(svc, %{"label" => "x"}) end,
        fn -> PFx.complete(ctx) end
      )

    assert {:ok, :advanced} = r1
    assert {:ok, _} = r2
  end

  test "T-LK-4c a SERVICE posting overlapping a non-posting HUMAN completion on the audit row" do
    ctx = engine_case("req688-lk4c", post_lines(["post_alpha"]))
    svc = PFx.more_service!(ctx, post_lines(["post_alpha"], "d2"))
    plain = PFx.more_task!(ctx, [PFx.line("plain")])
    seed_ledgers!(ctx)

    %{first: r1, second: r2} =
      H.forced_overlap(
        ctx.schema,
        :audit_chain,
        fn -> Letflow.EntityWritesFixture.apply_http(svc, %{"label" => "x"}) end,
        fn -> PFx.complete(plain) end
      )

    assert {:ok, :advanced} = r1
    assert {:ok, _} = r2
  end

  test "T-LK-4d a counter held beyond the lock timeout stops the SERVICE apply in the pre-step" do
    ctx = engine_case("req688-lk4d", post_lines(["post_alpha"]))
    svc = PFx.more_service!(ctx, post_lines(["post_alpha"], "d2"))
    seed_ledgers!(ctx)
    before = seqs(ctx.schema)
    counts = PFx.ledger_counts(ctx.schema)

    {holder, _backend} = H.hold_row(ctx.schema, {:ledger_counter, PFx.alpha()})
    result = Letflow.EntityWritesFixture.apply_http(svc, %{"label" => "x"})
    send(holder.pid, :release)
    Task.await(holder, H.await_ms())

    # contention is re-applied by the engine and then given up (ERROR + DLQ); nothing was written
    refute match?({:ok, :advanced}, result)
    assert seqs(ctx.schema) == before
    assert PFx.ledger_counts(ctx.schema) == counts
  end

  test "T-LK-5 a third posting line fails with nothing committed; one posting plus a plain line passes" do
    ctx = engine_case("req686-lk5", post_lines(["post_alpha", "post_beta"]))
    three = post_lines(["post_alpha", "post_beta", "post_alpha"])

    assert {:error, _step, {:ledger_contract, :ledger_too_many_postings}, _} =
             PFx.run_lines(ctx, three)

    assert {0, 0, 0, 0} = PFx.ledger_counts(ctx.schema)

    one = post_lines(["post_alpha"])
    assert {:ok, _} = PFx.run_lines(ctx, one)
    assert {1, 1, 1, 1} = PFx.ledger_counts(ctx.schema)

    # one posting line plus a plain create line, through a real completion
    mixed = [
      PFx.line("plain"),
      PFx.line("post_alpha", %{
        "posting" => PFx.posting("receipt", "a", "5", %{"document_id" => "d9"})
      })
    ]

    assert {:ok, _} = PFx.complete(PFx.more_task!(ctx, mixed))
    assert {2, 2, 1, 1} = PFx.ledger_counts(ctx.schema)

    # the lock step stays ONE merge placed once after the last handler call
    source = File.read!("lib/letflow/ledger/handler_post.ex")
    assert length(Regex.scan(~r/Multi\.merge\(/, source)) == 1

    assert HandlerPost.lock_steps(PFx.build_lines(ctx, one), one)
           |> Ecto.Multi.to_list()
           |> List.last()
           |> elem(0) == :merge
  end

  test "T-LK-6 two sequential transactions of one process both post" do
    ctx = engine_case("req686-lk6", post_lines(["post_alpha"]))
    second = PFx.more_task!(ctx, post_lines(["post_alpha"], "d2"))

    assert {:ok, _} = PFx.complete(ctx)
    assert {:ok, _} = PFx.complete(second)
    assert [["fixture_ledger_post", 2]] = seqs(ctx.schema)
  end
end
