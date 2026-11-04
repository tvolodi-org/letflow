defmodule Letflow.Ledger.CounterThroughputTest do
  @moduledoc """
  REQ-686 criterion 9 (T-LD-1): the throughput of postings through the engine with the short counter
  lock. `@moduletag :ledger_throughput`: excluded by default (`test/test_helper.exs`), run on demand with
  `mix test --only ledger_throughput test/letflow/ledger/counter_throughput_test.exs`.

  Four workers each complete fresh tasks of one module-stamped node in a loop for
  `LEDGER_THROUGHPUT_SECONDS` seconds (default 60), every completion posting one entry to the SAME
  ledger (the worst case for the counter lock). The test prints posts per second, the p95 of the
  completion latency and the share of 503 contention answers, and asserts that nothing was
  committed twice, nothing deadlocked and the counter equals the number of committed entries.
  Sandbox `:auto` with real commits.
  """

  use Letflow.DataCase, async: false
  @moduletag :ledger_throughput
  @moduletag timeout: 300_000

  alias Letflow.EntityWritesFixture, as: EFx
  alias Letflow.LedgerPostFixture, as: Fx
  alias Letflow.LockOrderHelpers, as: H

  @workers 4

  setup do
    Letflow.LedgerFixture.setup_auto_mode!()
    :ok = H.attach_error_handler(__MODULE__)
    :ok
  end

  defp worker(ctx, deadline) do
    Stream.repeatedly(fn -> System.monotonic_time(:millisecond) end)
    |> Enum.reduce_while([], fn now, acc ->
      if now >= deadline do
        {:halt, acc}
      else
        {_instance_id, task} = EFx.start!(ctx.schema, ctx.definition)
        started = System.monotonic_time(:microsecond)
        result = Fx.complete(%{ctx | task: task})
        micros = System.monotonic_time(:microsecond) - started
        {:cont, [{result, micros} | acc]}
      end
    end)
  end

  test "T-LD-1 four workers post to one ledger through the engine" do
    seconds = String.to_integer(System.get_env("LEDGER_THROUGHPUT_SECONDS", "60"))

    ctx =
      Fx.case!(
        "req686-ld1",
        [Fx.post_line("post_alpha", Fx.posting("receipt", "a", "1"))],
        committed: true
      )

    started = System.monotonic_time(:millisecond)
    deadline = started + seconds * 1000

    results =
      1..@workers
      |> Enum.map(fn _ -> Task.async(fn -> worker(ctx, deadline) end) end)
      |> Enum.flat_map(&Task.await(&1, (seconds + 120) * 1000))

    elapsed_s = (System.monotonic_time(:millisecond) - started) / 1000
    ok = for {{:ok, _}, micros} <- results, do: micros

    contention =
      Enum.count(results, fn {r, _} ->
        match?({:error, {:entity_write_refused, :contention, _}}, r)
      end)

    others = length(results) - length(ok) - contention
    sorted = Enum.sort(ok)
    p95 = if sorted == [], do: 0, else: Enum.at(sorted, max(trunc(length(sorted) * 0.95) - 1, 0))

    IO.puts(
      "T-LD-1 workers=#{@workers} seconds=#{Float.round(elapsed_s, 1)} posted=#{length(ok)} " <>
        "posts_per_s=#{Float.round(length(ok) / elapsed_s, 1)} p95_ms=#{Float.round(p95 / 1000, 1)} " <>
        "contention_503=#{contention} other=#{others}"
    )

    refute_receive {:deadlock_detected, _}, 0
    assert others == 0
    assert length(ok) > 0
    assert {n, _, _, 1} = Fx.ledger_counts(ctx.schema)
    assert n == length(ok)

    %{rows: [[last_seq]]} =
      Repo.query!(~s|SELECT last_seq FROM "#{ctx.schema}".ledger_counter|)

    assert last_seq == length(ok)
  end
end
