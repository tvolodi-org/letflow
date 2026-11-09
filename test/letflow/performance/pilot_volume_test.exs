Code.require_file("../modules/assets/register_fixture.exs", __DIR__)
Code.require_file("../modules/assets/assets_fixture.exs", __DIR__)

defmodule Letflow.Performance.PilotVolumeTest do
  @moduledoc """
  GH T-1562 (BA batch 2 item 10): the common reads of the assets application on a pilot-size data set
  (20 000 asset cards, 200 000 register rows = ledger legs, 50 users) and the index review of the SQL they run.

  `@moduletag :pilot_volume`: excluded by default (`test/test_helper.exs`), run on demand with
  `MIX_TEST_PARTITION=<n> mix test --only pilot_volume test/letflow/performance/pilot_volume_test.exs`.
  Local test stack only, never QA. The test asserts nothing about the limits: a miss is printed (OVER) and
  recorded in the status note, it does not fail the file. One sequential test (`P-measure` rows P1..P12, then
  `P-index-review`), because seeding is the expensive part and a second test would seed again.

  The set is deterministic (`:rand` seeded below). Cards go through `Records` (the AssetsFixture owner path, 4 workers);
  register rows go through `Ledger.post/1` with the real assets registration and `LedgerPolicy.declare/2`
  (`AssetsRegisterFixture.post!/4`), so the append-only guards, balances and chain hash are the real ones.
  Reads go through the full `Letflow.Router` with a real bearer token. `@scale` is changed by editing, for a
  reduced dry run (1 = pilot size).
  """

  use Letflow.DataCase, async: false

  alias Letflow.AssetsFixture, as: A
  alias Letflow.AssetsRegisterFixture, as: S
  alias Letflow.Repo
  alias Letflow.Support.TokenMintFixture

  @moduletag :pilot_volume
  @moduletag timeout: 600_000

  @scale 1
  @cards div(20_000, @scale)
  @legs div(200_000, @scale)
  @users 50
  @runs 5
  @units 50
  @locations 10
  @entity "/api/v1/entities/query"

  # limits in ms (median unless noted); UAT assumptions, editable here and in the status note
  @limit_list 1_000
  @limit_max 2_000
  @limit_balance 2_000
  @limit_report 5_000
  @limit_page_open 3_000

  # In :auto mode the first query of a process checks a connection out, owned for 120 s at most; the run lasts
  # minutes, so the connection is returned between steps (outside every timed section).
  defp fresh_conn, do: Ecto.Adapters.SQL.Sandbox.checkin(Repo)

  defp ms(fun) do
    {micros, result} = :timer.tc(fun)
    {micros / 1000, result}
  end

  defp median(values), do: values |> Enum.sort() |> then(&Enum.at(&1, div(length(&1), 2)))

  defp uuid(prefix, n) do
    hex = n |> Integer.to_string(16) |> String.pad_leading(12, "0")
    "#{prefix}000000-0000-4000-8000-#{hex}"
  end

  defp get(path, tok), do: S.get(String.replace_prefix(path, S.base(), ""), tok)

  defp post_json(path, tok, body) do
    import Plug.Conn

    Plug.Test.conn(:post, path, Jason.encode!(body))
    |> put_req_header("authorization", "Bearer " <> tok)
    |> put_req_header("content-type", "application/json")
    |> Letflow.Router.call(Letflow.Router.init([]))
  end

  defp ok!(conn, what) do
    assert conn.status == 200, "#{what}: #{conn.status} #{String.slice(conn.resp_body, 0, 300)}"
    conn
  end

  # 1 warm-up, then @runs timed runs; returns {median, max, last_conn}
  defp measure(id, label, fun) do
    ok!(fun.(), label)

    timed =
      for _ <- 1..@runs do
        fresh_conn()
        ms(fn -> ok!(fun.(), label) end)
      end

    values = Enum.map(timed, &elem(&1, 0))
    {_, conn} = List.last(timed)
    row = {id, label, median(values), Enum.max(values)}
    {row, conn}
  end

  # 4 workers (the machine rule); names are a pure function of the number, so the set is identical every run
  defp seed_cards!(schema) do
    1..@cards
    |> Task.async_stream(
      fn i ->
        name = Enum.map_join([7, 13, 31], " ", fn m -> "word#{rem(i * m, 200)}" end)

        A.card!(schema, "PERF-" <> String.pad_leading("#{i}", 6, "0"), %{
          "name" => name,
          "kind" => if(rem(i, 3) == 0, do: "low_value", else: "fixed"),
          "org_unit_id" => uuid("0a", rem(i, @units)),
          "active" => rem(i, 10) != 0
        }).record_id
      end,
      max_concurrency: 4,
      ordered: true,
      timeout: 120_000
    )
    |> Enum.map(fn {:ok, id} -> id end)
  end

  # commission one leg per card, then change rounds (2 legs per line) until @legs legs are posted
  defp seed_register!(schema, ids) do
    ids = List.to_tuple(ids)
    n = tuple_size(ids)

    side = fn i, phase ->
      S.side(uuid("0a", rem(i, @units)), uuid("0b", rem(i + phase, 2) * 1000 + rem(i, 97)), %{
        location: uuid("0c", rem(i, @locations))
      })
    end

    # commission, up to 100 lines per entry (declare/2 cap)
    chunks(0, n - 1, 100, fn from_i, to_i ->
      lines = for i <- from_i..to_i, do: S.line(elem(ids, i), "1", %{to: side.(i, 0)})

      S.post!(
        schema,
        "commission",
        %{
          document_type: "commission_doc",
          document_id: "perf-c-#{from_i}",
          lines: lines
        },
        audit: false
      )
    end)

    rounds(schema, ids, n, side, @legs - n, 1)
  end

  defp rounds(_schema, _ids, _n, _side, left, _phase) when left < 2, do: :ok

  defp rounds(schema, ids, n, side, left, phase) do
    lines_this_round = min(n, div(left, 2))

    chunks(0, lines_this_round - 1, 100, fn from_i, to_i ->
      lines =
        for i <- from_i..to_i,
            do: S.line(elem(ids, i), "1", %{from: side.(i, phase - 1), to: side.(i, phase)})

      S.post!(schema, "change", %{document_id: "perf-r#{phase}-#{from_i}", lines: lines},
        audit: false
      )
    end)

    rounds(schema, ids, n, side, left - 2 * lines_this_round, phase + 1)
  end

  defp chunks(from_i, last, _size, _fun) when from_i > last, do: :ok

  defp chunks(from_i, last, size, fun) do
    to_i = min(from_i + size - 1, last)
    fresh_conn()
    fun.(from_i, to_i)
    chunks(to_i + 1, last, size, fun)
  end

  defp count(schema, table),
    do: Repo.query!(~s|SELECT count(*) FROM "#{schema}".#{table}|).rows |> hd() |> hd()

  defp verdict(median, max) do
    if median > @limit_list or max > @limit_max, do: "OVER", else: "OK"
  end

  test "P-measure and P-index-review: assets reads at pilot size" do
    ctx = S.setup_oidc!([:a])

    a = S.tenant!("pilot", ctx.names.a)
    schema = a.schema_name
    tok = S.token(ctx, :a, ["TENANT_ADMIN"])
    # make the caller a known user of the tenant
    ok!(get("/api/v1/modules/assets/balances", tok), "first call")

    {t_users, _} =
      ms(fn ->
        for _ <- 1..(@users - 1), do: TokenMintFixture.role_holder!(schema, ["TENANT_ADMIN"])
      end)

    {t_cards, ids} = ms(fn -> seed_cards!(schema) end)
    {t_reg, _} = ms(fn -> seed_register!(schema, ids) end)
    # the mock tokens are short-lived and the seeding takes minutes: mint after it
    tok = S.token(ctx, :a, ["TENANT_ADMIN"])
    Repo.query!(~s|ANALYZE "#{schema}".ledger_leg|)
    Repo.query!(~s|ANALYZE "#{schema}".ledger_balance|)
    Repo.query!(~s|ANALYZE "#{schema}".ledger_entry|)

    IO.puts(
      "\nPILOT-VOLUME seed: users #{count(schema, "users")}, cards #{count(schema, "entity_record_latest")} (latest rows), " <>
        "ledger_leg #{count(schema, "ledger_leg")}, ledger_entry #{count(schema, "ledger_entry")}, " <>
        "ledger_balance #{count(schema, "ledger_balance")}; seeding users #{round(t_users / 1000)} s, " <>
        "cards #{round(t_cards / 1000)} s, register #{round(t_reg / 1000)} s"
    )

    IO.puts("PILOT-VOLUME host: " <> inspect(Repo.query!("SELECT version()").rows))

    base = "/api/v1/modules/assets"

    card_q = fn extra ->
      Map.merge(
        %{
          entity_type: "assets_card",
          sort: [%{field: "inventory_number", dir: "asc"}],
          page_size: 50
        },
        extra
      )
    end

    live = [
      %{field: "deleted", op: "eq", value: false},
      %{field: "active", op: "eq", value: true}
    ]

    # cursor of page 49 of 200 (the deep page of the screen's own loop)
    {pages, deep_cursor, loop_ms} = page_loop(tok, live)

    rows = []

    {r, _} =
      measure("P1", "card list first page (50)", fn ->
        post_json(@entity, tok, card_q.(%{filters: live}))
      end)

    rows = [r | rows]

    {r, _} =
      measure("P2", "card list deep page (200 rows, page 49)", fn ->
        post_json(@entity, tok, card_q.(%{filters: live, page_size: 200, cursor: deep_cursor}))
      end)

    rows = [r | rows]

    f3 =
      live ++
        [
          %{field: "kind", op: "eq", value: "fixed"},
          %{field: "org_unit_id", op: "eq", value: uuid("0a", 7)}
        ]

    {r, _} =
      measure("P3", "card list filtered kind + org unit", fn ->
        post_json(@entity, tok, card_q.(%{filters: f3, page_size: 200}))
      end)

    rows = [r | rows]

    {r, _} =
      measure("P4a", "card search by name (contains)", fn ->
        post_json(
          @entity,
          tok,
          card_q.(%{filters: live ++ [%{field: "name", op: "contains", value: "word17"}]})
        )
      end)

    rows = [r | rows]

    {r, _} =
      measure("P4b", "card lookup by inventory number (eq)", fn ->
        post_json(
          @entity,
          tok,
          card_q.(%{
            filters: live ++ [%{field: "inventory_number", op: "eq", value: "PERF-012345"}]
          })
        )
      end)

    rows = [r | rows]

    {r, _} = measure("P5a", "assets balances first page", fn -> get(base <> "/balances", tok) end)
    rows = [r | rows]

    {r, _} =
      measure("P5b", "assets balances one location", fn ->
        get(base <> "/balances?location=#{uuid("0c", 3)}", tok)
      end)

    rows = [r | rows]

    {r, _} =
      measure("P5c", "assets balances one card", fn ->
        get(base <> "/balances?asset=#{Enum.at(ids, 777)}", tok)
      end)

    rows = [r | rows]

    {r, _} =
      measure("P5d", "assets balances at cutoff (as_of_date)", fn ->
        get(base <> "/balances?as_of_date=#{Date.utc_today()}", tok)
      end)

    rows = [r | rows]

    {r, _} =
      measure("P6a", "assets movements first page", fn -> get(base <> "/movements", tok) end)

    rows = [r | rows]

    {r, _} =
      measure("P6b", "assets movements one document", fn ->
        get(base <> "/movements?document_id=perf-c-0", tok)
      end)

    rows = [r | rows]
    {r, _} = measure("P7", "assets documents list", fn -> get(base <> "/documents", tok) end)
    rows = [r | rows]

    {r, _} =
      measure("P8a", "saved report Asset list (sorted, first page)", fn ->
        post_json(
          @entity,
          tok,
          card_q.(%{filters: [%{field: "deleted", op: "eq", value: false}], page_size: 200})
        )
      end)

    rows = [r | rows]

    {r, _} =
      measure("P8b", "balances export xlsx (one page)", fn ->
        get(base <> "/balances?format=xlsx", tok)
      end)

    rows = [r | rows]

    {r, _} = measure("P10", "reconcile (one chunk)", fn -> get(base <> "/reconcile", tok) end)
    rows = [r | rows]

    # P11: page open = the screen's loop (all pages of 200, max 50 pages) + the org units
    {units_ms, _} =
      ms(fn ->
        post_json(@entity, tok, %{
          entity_type: "org_unit",
          filters: [%{field: "deleted", op: "eq", value: false}],
          sort: [%{field: "code", dir: "asc"}],
          page_size: 200
        })
      end)

    rows = [
      {"P11", "page open: #{pages} pages of 200 cards + org units (screen loop)",
       loop_ms + units_ms, loop_ms + units_ms}
      | rows
    ]

    # P12: 4 concurrent callers on P1 and P5a, 10 s
    rows = [concurrency(tok, base, card_q, live) | rows] |> List.flatten()

    IO.puts("\nPILOT-VOLUME results (ms; median / max of #{@runs} runs after 1 warm-up)")
    IO.puts("| id | read | median | max | verdict |\n|---|---|---|---|---|")

    for {id, label, med, max} <- Enum.reverse(rows) do
      v =
        cond do
          id == "P10" -> "n/a (no limit)"
          id == "P11" -> if med > @limit_page_open, do: "OVER", else: "OK"
          String.starts_with?(id, "P5") -> if med > @limit_balance, do: "OVER", else: "OK"
          String.starts_with?(id, "P8") -> if med > @limit_report, do: "OVER", else: "OK"
          String.starts_with?(id, "P12") -> "see note"
          true -> verdict(med, max)
        end

      IO.puts("| #{id} | #{label} | #{round(med)} | #{round(max)} | #{v} |")
    end

    index_review(schema, tok, base, card_q, live, f3, ids)
    assert length(rows) > 10
  end

  # walks the screen's loop (page_size 200, up to 50 pages); returns {pages, cursor of page 49, total ms}
  defp page_loop(tok, filters) do
    body = %{
      entity_type: "assets_card",
      filters: filters,
      sort: [%{field: "inventory_number", dir: "asc"}],
      page_size: 200
    }

    Enum.reduce_while(1..50, {nil, nil, 0, 0}, fn page, {cursor, deep, total, _} ->
      b = if cursor, do: Map.put(body, :cursor, cursor), else: body
      fresh_conn()
      {t, conn} = ms(fn -> post_json(@entity, tok, b) |> ok!("page loop #{page}") end)
      next = Jason.decode!(conn.resp_body)["next_cursor"]
      deep = if page == 48, do: next, else: deep
      acc = {next, deep, total + t, page}
      if next, do: {:cont, acc}, else: {:halt, acc}
    end)
    |> then(fn {next, deep, total, page} ->
      IO.puts(
        "PILOT-VOLUME page loop: #{page} pages, next_cursor after the last page: #{inspect(next != nil)} (the screen stops at 50 pages = 10 000 cards)"
      )

      {page, deep || next, total}
    end)
  end

  defp concurrency(tok, base, card_q, live) do
    for {id, label, fun} <- [
          {"P12a", "4 callers: card list first page",
           fn -> post_json(@entity, tok, card_q.(%{filters: live})) end},
          {"P12b", "4 callers: assets balances first page",
           fn -> get(base <> "/balances", tok) end}
        ] do
      deadline = System.monotonic_time(:millisecond) + 5_000

      times =
        1..4
        |> Task.async_stream(
          fn _ ->
            Stream.repeatedly(fn -> elem(ms(fn -> ok!(fun.(), label) end), 0) end)
            |> Enum.take_while(fn _ -> System.monotonic_time(:millisecond) < deadline end)
          end,
          timeout: 30_000
        )
        |> Enum.flat_map(fn {:ok, t} -> t end)

      {id, label, median(times), Enum.max(times)}
    end
  end

  # every SQL text the repo runs while `fun` runs, from any process (the read path may hop processes)
  defp capture(fun) do
    id = {__MODULE__, make_ref()}
    me = self()

    :telemetry.attach(
      id,
      Repo.config()[:telemetry_prefix] ++ [:query],
      fn _event, _measure, meta, _config -> send(me, {:stmt, id, meta.query, meta.params}) end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    drain(id, [])
  end

  defp drain(id, acc) do
    receive do
      {:stmt, ^id, sql, params} -> drain(id, [{sql, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp index_review(schema, tok, base, card_q, live, f3, ids) do
    cases = [
      {"P1", fn -> post_json(@entity, tok, card_q.(%{filters: live})) end},
      {"P3", fn -> post_json(@entity, tok, card_q.(%{filters: f3, page_size: 200})) end},
      {"P4a",
       fn ->
         post_json(
           @entity,
           tok,
           card_q.(%{filters: live ++ [%{field: "name", op: "contains", value: "word17"}]})
         )
       end},
      {"P4b",
       fn ->
         post_json(
           @entity,
           tok,
           card_q.(%{
             filters: live ++ [%{field: "inventory_number", op: "eq", value: "PERF-012345"}]
           })
         )
       end},
      {"P5a", fn -> get(base <> "/balances", tok) end},
      {"P5b", fn -> get(base <> "/balances?location=#{uuid("0c", 3)}", tok) end},
      {"P5c", fn -> get(base <> "/balances?asset=#{Enum.at(ids, 777)}", tok) end},
      {"P6a", fn -> get(base <> "/movements", tok) end},
      {"P6b", fn -> get(base <> "/movements?document_id=perf-c-0", tok) end},
      {"P7", fn -> get(base <> "/documents", tok) end}
    ]

    IO.puts("\nPILOT-VOLUME index review (EXPLAIN ANALYZE of the SELECTs each read really runs)")

    for {id, fun} <- cases do
      statements = capture(fun)

      selects =
        Enum.filter(statements, fn {sql, _} ->
          sql =~ ~r/\A\s*(SELECT|WITH)/i and sql =~ ~r/field_values|ledger_|documents/i
        end)

      if selects == [],
        do:
          IO.puts(
            "#{id}: no SELECT matched; statements: #{inspect(Enum.map(statements, fn {q, _} -> String.slice(q, 0, 80) end))}"
          )

      for {sql, params} <- selects do
        plan =
          try do
            Repo.query!("EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) " <> sql, params).rows
            |> List.flatten()
          rescue
            e -> [("explain failed: " <> Exception.message(e)) |> String.slice(0, 200)]
          end

        seq = plan |> Enum.filter(&(&1 =~ "Seq Scan")) |> Enum.map(&String.trim/1)
        exec = Enum.find(plan, "", &(&1 =~ "Execution Time"))

        IO.puts(
          "#{id}: #{String.slice(sql, 0, 110) |> String.replace(~r/\s+/, " ")} ... | seq scans: #{inspect(seq)} | #{String.trim(exec)}"
        )
      end
    end

    IO.puts("\nPILOT-VOLUME indexes (table, index, idx_scan, definition)")

    %{rows: idx} =
      Repo.query!(
        """
        SELECT s.relname, s.indexrelname, s.idx_scan, i.indexdef
        FROM pg_stat_user_indexes s JOIN pg_indexes i ON i.schemaname = s.schemaname AND i.indexname = s.indexrelname
        WHERE s.schemaname = $1 AND s.relname ~ '^(entity_assets_card|ledger_leg.*|ledger_entry.*|ledger_balance.*|documents.*)$'
        ORDER BY 1, 2
        """,
        [schema]
      )

    for [t, n, c, d] <- idx, do: IO.puts("| #{t} | #{n} | #{c} | #{d} |")
  end
end
