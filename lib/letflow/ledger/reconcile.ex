defmodule Letflow.Ledger.Reconcile do
  @moduledoc """
  REQ-637 part C (GH #3559, criteria 7 and 8): `Letflow.Ledger.reconcile/2`. It re-derives what the
  ledger caches or chains and reports what differs; it repairs nothing and sends no write
  statement (every chunk is a READ ONLY transaction).

  ## One call, one chunk

  Each call runs one chunk in its own `REPEATABLE READ READ ONLY` transaction: the statement
  timeout is set transaction-locally (default 10 s, can only be lowered through the
  `:statement_timeout_ms` option), then `pg_try_advisory_xact_lock` keyed by a hash of the tenant
  schema name and the ledger id (bound parameters) is tried. A busy lock is
  `{:error, :reconcile_busy}`. The lock is transaction-scoped, so it caps concurrent CHUNKS of one
  ledger id; it does not exclude two whole runs, and no whole-run exclusivity is claimed. A database
  error (a statement timeout 57014 included) propagates unrescued; the caller maps it.

  A chunk works through three phases, carried in the opaque `next_cursor`:

    * `keys`: per balance key, the sum of the legs with `posting_seq <= N` against the balance row,
      compared only when the row's `last_posting_seq <= N`; also every key that has legs but no
      balance row (`balance: nil`). `N` is the counter value in the FIRST chunk's snapshot and is
      returned as `checked_through_seq` by every chunk of the run.
    * `recheck`: the keys whose balance moved past `N` are compared again at a new `N2` (the
      counter value of the first recheck chunk). A key whose row moved past `N2` as well (a posting
      between two recheck chunks) is skipped: it stays UNVERIFIED in this run and the next run
      covers it at its higher N. A posting between chunks is therefore never reported as a mismatch.
    * `chain`: entry by entry, the digest and the chain hash are recomputed with
      `Letflow.Ledger.Digest` from the stored rows and compared with the stored values; at the end
      of the range the last stored chain hash is compared with the counter's `last_chain_hash`.
      The first difference ends the run as `{:broken_at, posting_seq}`; a missing tail entry is
      `{:broken_at, last_walked_seq + 1}`.

  The sequence check (`gap_check`) runs once, in the first chunk, and is repeated unchanged in every
  later result. Only the LAST result (`next_cursor: nil`) carries the verdict of `chain_check`;
  earlier results show `:ok` for it. The `mismatches` of a result are that chunk's only; the
  mismatches of a run are the union over its chunks.

  The cursor is base64 of JSON, unsigned and validated on decode. It can only make a caller
  reconcile its own authorised ledger differently; it is not a security feature. A run is bounded
  at 60 seconds by a deadline in the cursor (`{:error, :run_expired}`). Entries and balances are
  read through Ecto with the prefix of the authorised value and a bound ledger id; the only literal
  SQL is the isolation statement, the timeout setting and the advisory lock.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Ledger
  alias Letflow.Ledger.Authorized
  alias Letflow.Ledger.Digest
  alias Letflow.Repo

  @prefix_form ~r/\Atenant_[0-9a-f]{32}\z/
  @hex64 ~r/\A[0-9a-f]{64}\z/
  @run_ms 60_000
  @default_timeout_ms 10_000
  @cursor_limit 16_384
  @phases ~w(keys recheck chain done)
  @uuid_fields ~w(id reverses_entry_id actor_id subject_id bpm_instance_id bpm_task_id
                  bpm_definition_id)a

  @type reconciliation :: %{
          ledger_id: String.t(),
          checked_through_seq: non_neg_integer(),
          mismatches: [%{key: [String.t()], balance: String.t() | nil, ledger_sum: String.t()}],
          gap_check: :ok | {:gap, [pos_integer()]},
          chain_check: :ok | {:broken_at, non_neg_integer()},
          next_cursor: String.t() | nil
        }

  @doc false
  @spec reconcile(Authorized.t(), map()) ::
          {:ok, reconciliation()}
          | {:error, :reconcile_busy | :invalid_cursor | :invalid_opts | :run_expired}
  def reconcile(%Authorized{purpose: :reconcile} = authorized, opts) when is_map(opts) do
    if Repo.in_transaction?() do
      raise ArgumentError, "Letflow.Ledger.reconcile/2 starts its own transaction"
    end

    unless is_binary(authorized.prefix) and Regex.match?(@prefix_form, authorized.prefix) and
             is_binary(authorized.ledger_id) do
      raise ArgumentError, "Letflow.Ledger.reconcile/2: malformed authorized value"
    end

    with {:ok, cap, timeout_ms} <- check_opts(opts),
         {:ok, cursor} <- check_cursor(Map.get(opts, :cursor), authorized.ledger_id) do
      chunk(authorized, cap, timeout_ms, cursor)
    end
  end

  # -- options and cursor ----------------------------------------------------------------------

  defp check_opts(opts) do
    cap = Ledger.page_cap()
    size = Map.get(opts, :chunk_size, cap)
    timeout = Map.get(opts, :statement_timeout_ms, @default_timeout_ms)

    if is_integer(size) and size >= 1 and is_integer(timeout) and
         timeout in 1..@default_timeout_ms do
      {:ok, min(size, cap), timeout}
    else
      {:error, :invalid_opts}
    end
  end

  defp check_cursor(nil, _lid), do: {:ok, nil}

  defp check_cursor(cursor, lid) when is_binary(cursor) and byte_size(cursor) <= @cursor_limit do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{} = map} <- Jason.decode(json),
         {:ok, state} <- cursor_state(map, lid) do
      {:ok, state}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp check_cursor(_cursor, _lid), do: {:error, :invalid_cursor}

  defp cursor_state(map, lid) do
    state = %{
      ph: map["ph"],
      n: map["n"],
      n2: map["n2"],
      after: map["after"],
      seq: map["seq"],
      prev: map["prev"],
      head: map["head"],
      gap: map["gap"],
      dl: map["dl"],
      chain: nil
    }

    if map["v"] == 1 and map["lid"] == lid and cursor_shape?(state),
      do: {:ok, state},
      else: :error
  end

  defp cursor_shape?(st) do
    st.ph in @phases and st.ph != "done" and nat?(st.n) and (st.n2 == nil or nat?(st.n2)) and
      (st.after == nil or key?(st.after)) and nat?(st.seq) and st.seq <= st.n and
      hash_or_empty?(st.prev) and hash_or_empty?(st.head) and gap?(st.gap) and nat?(st.dl)
  end

  defp nat?(v), do: is_integer(v) and v >= 0

  defp key?(key) do
    is_list(key) and length(key) == 8 and
      Enum.all?(key, &(is_binary(&1) and byte_size(&1) <= 128 and String.valid?(&1)))
  end

  defp hash_or_empty?(v), do: v == "" or (is_binary(v) and Regex.match?(@hex64, v))

  defp gap?("ok"), do: true

  defp gap?(list),
    do:
      is_list(list) and length(list) <= Ledger.page_cap() and
        Enum.all?(list, &(is_integer(&1) and &1 >= 1))

  defp encode_cursor(lid, st) do
    %{
      "v" => 1,
      "lid" => lid,
      "ph" => st.ph,
      "n" => st.n,
      "n2" => st.n2,
      "after" => st.after,
      "seq" => st.seq,
      "prev" => st.prev,
      "head" => st.head,
      "gap" => st.gap,
      "dl" => st.dl
    }
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  # -- one chunk -------------------------------------------------------------------------------

  defp chunk(%Authorized{prefix: prefix, ledger_id: lid}, cap, timeout_ms, cursor) do
    result =
      Repo.transaction(fn ->
        Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")

        Repo.query!("SELECT set_config('statement_timeout', $1, true)", [
          Integer.to_string(timeout_ms)
        ])

        case Repo.query!("SELECT pg_try_advisory_xact_lock(hashtext($1), hashtext($2))", [
               prefix,
               lid
             ]) do
          %{rows: [[true]]} -> :ok
          _busy -> Repo.rollback(:reconcile_busy)
        end

        {last_seq, last_hash} = counter(prefix, lid)
        ctx = %{prefix: prefix, lid: lid, last_seq: last_seq}
        state = start_state(ctx, cursor, cap, last_hash)

        {state, mismatches} = run_phases(ctx, state, cap, [], 0)

        %{
          ledger_id: lid,
          checked_through_seq: state.n,
          mismatches: mismatches,
          gap_check: if(state.gap == "ok", do: :ok, else: {:gap, state.gap}),
          chain_check: state.chain || :ok,
          next_cursor: if(state.ph == "done", do: nil, else: encode_cursor(lid, state))
        }
      end)

    result
  end

  defp counter(prefix, lid) do
    from(c in "ledger_counter",
      where: c.ledger_id == ^lid,
      select: {c.last_seq, c.last_chain_hash}
    )
    |> Repo.one(prefix: prefix)
    |> case do
      nil -> {0, ""}
      row -> row
    end
  end

  defp start_state(ctx, nil, cap, last_hash) do
    %{
      ph: "keys",
      n: ctx.last_seq,
      n2: nil,
      after: nil,
      seq: 0,
      prev: "",
      head: last_hash,
      gap: gap_check(ctx, cap),
      dl: System.system_time(:millisecond) + @run_ms,
      chain: nil
    }
  end

  defp start_state(ctx, cursor, _cap, _last_hash) do
    cond do
      System.system_time(:millisecond) > cursor.dl -> Repo.rollback(:run_expired)
      cursor.n > ctx.last_seq or (cursor.n2 || 0) > ctx.last_seq -> Repo.rollback(:invalid_cursor)
      true -> cursor
    end
  end

  # -- sequence check --------------------------------------------------------------------------

  defp gap_check(%{prefix: prefix, lid: lid, last_seq: last_seq}, cap) do
    entries = from(e in "ledger_entry", where: e.ledger_id == ^lid)
    count = from(e in entries, select: count(e.posting_seq)) |> Repo.one!(prefix: prefix)

    top =
      from(e in entries, order_by: [desc: e.posting_seq], limit: 1, select: e.posting_seq)
      |> Repo.one(prefix: prefix) || 0

    if count == last_seq and top == last_seq do
      "ok"
    else
      upper = Kernel.max(last_seq, top)

      from(s in fragment("SELECT generate_series(1, ?::bigint) AS seq", ^upper),
        left_join: e in "ledger_entry",
        on: e.ledger_id == ^lid and e.posting_seq == s.seq,
        where: is_nil(e.posting_seq),
        order_by: s.seq,
        limit: ^cap,
        select: s.seq
      )
      |> Repo.all(prefix: prefix)
    end
  end

  # -- phase driver ----------------------------------------------------------------------------

  defp run_phases(_ctx, %{ph: "done"} = st, _cap, acc, _used), do: {st, acc}
  defp run_phases(_ctx, st, cap, acc, used) when used >= cap, do: {st, acc}

  defp run_phases(ctx, %{ph: "keys"} = st, cap, acc, used) do
    case keys_phase(ctx, st, cap - used) do
      {:done, mm, u} ->
        run_phases(ctx, %{st | ph: "recheck", after: nil, n2: nil}, cap, acc ++ mm, used + u)

      {:more, st, mm} ->
        {st, acc ++ mm}
    end
  end

  defp run_phases(ctx, %{ph: "recheck"} = st, cap, acc, used) do
    n2 = st.n2 || ctx.last_seq
    st = %{st | n2: n2}

    if n2 <= st.n do
      run_phases(ctx, %{st | ph: "chain", after: nil}, cap, acc, used)
    else
      case recheck_phase(ctx, st, cap - used) do
        {:done, mm, u} ->
          run_phases(ctx, %{st | ph: "chain", after: nil}, cap, acc ++ mm, used + u)

        {:more, st, mm} ->
          {st, acc ++ mm}
      end
    end
  end

  defp run_phases(ctx, %{ph: "chain"} = st, cap, acc, used) do
    case chain_phase(ctx, st, cap - used) do
      {:done, st} -> {%{st | ph: "done"}, acc}
      {:more, st} -> {st, acc}
    end
  end

  # -- keys and recheck ------------------------------------------------------------------------

  defp keys_phase(ctx, st, budget) do
    a = balance_keys(ctx, st.after, budget)
    b = leg_keys(ctx, st.after, {0, st.n}, budget)

    compare_page(ctx, st, a, b, budget, st.n, :keys)
  end

  defp recheck_phase(ctx, st, budget) do
    b = leg_keys(ctx, st.after, {st.n, st.n2}, budget)

    compare_page(ctx, st, [], b, budget, st.n2, :recheck)
  end

  defp compare_page(ctx, st, a, b, budget, hi, mode) do
    {page, upper, more?} = page_of(a, b, budget)

    if page == [] do
      {:done, [], 0}
    else
      sums = leg_sums(ctx, st.after, upper, hi)
      balances = balance_rows(ctx, st.after, upper)

      mismatches =
        Enum.flat_map(page, &key_mismatch(&1, sums, balances, {mode, st.n, hi, ctx.last_seq}))

      if more?,
        do: {:more, %{st | after: List.last(page)}, mismatches},
        else: {:done, mismatches, length(page)}
    end
  end

  # The smallest keys of both lists that are not beyond the last key of a FULL list (a full list is
  # incomplete past its last key). Neither full: everything left, and the phase ends.
  defp page_of(a, b, budget) do
    limits = for list <- [a, b], length(list) == budget, do: List.last(list)
    keys = Enum.sort(Enum.uniq(a ++ b))

    case limits do
      [] ->
        {keys, nil, false}

      _ ->
        limit = Enum.min(limits)
        {Enum.filter(keys, &(&1 <= limit)), limit, true}
    end
  end

  defp key_mismatch(key, sums, balances, rule) do
    sum = Map.get(sums, key, Decimal.new(0))
    ledger_sum = Digest.quantity_text(sum)

    case Map.get(balances, key) do
      nil ->
        [%{key: trim(key), balance: nil, ledger_sum: ledger_sum}]

      {on_hand, last_posting_seq} ->
        cond do
          skip?(rule, last_posting_seq) ->
            []

          Decimal.equal?(on_hand, sum) ->
            []

          true ->
            [%{key: trim(key), balance: Digest.quantity_text(on_hand), ledger_sum: ledger_sum}]
        end
    end
  end

  # keys: a row that moved past N is left to the recheck; a row past the snapshot counter is a
  # corrupt cache and is compared. recheck: a row past N2 is skipped (unverified in this run).
  defp skip?({:keys, n, _hi, snapshot_seq}, lps), do: lps > n and lps <= snapshot_seq
  defp skip?({:recheck, _n, hi, _snapshot_seq}, lps), do: lps > hi

  defp trim(key), do: key |> Enum.reverse() |> Enum.drop_while(&(&1 == "")) |> Enum.reverse()

  defp balance_keys(ctx, after_key, limit) do
    from(b in "ledger_balance",
      where: b.ledger_id == ^ctx.lid,
      order_by: [b.k1, b.k2, b.k3, b.k4, b.k5, b.k6, b.k7, b.k8],
      limit: ^limit,
      select: [b.k1, b.k2, b.k3, b.k4, b.k5, b.k6, b.k7, b.k8]
    )
    |> after_key(after_key)
    |> Repo.all(prefix: ctx.prefix)
  end

  defp leg_keys(ctx, after_key, {lo, hi}, limit) do
    lid = ctx.lid

    from(l in "ledger_leg",
      where: l.ledger_id == ^lid and l.posting_seq > ^lo and l.posting_seq <= ^hi,
      distinct: true,
      order_by: [l.k1, l.k2, l.k3, l.k4, l.k5, l.k6, l.k7, l.k8],
      limit: ^limit,
      select: [l.k1, l.k2, l.k3, l.k4, l.k5, l.k6, l.k7, l.k8]
    )
    |> after_key(after_key)
    |> Repo.all(prefix: ctx.prefix)
  end

  defp leg_sums(ctx, after_key, upper, hi) do
    lid = ctx.lid

    from(l in "ledger_leg",
      where: l.ledger_id == ^lid and l.posting_seq <= ^hi,
      group_by: [l.k1, l.k2, l.k3, l.k4, l.k5, l.k6, l.k7, l.k8],
      select: [l.k1, l.k2, l.k3, l.k4, l.k5, l.k6, l.k7, l.k8, sum(l.quantity)]
    )
    |> after_key(after_key)
    |> upper_key(upper)
    |> Repo.all(prefix: ctx.prefix)
    |> Map.new(fn row ->
      {key, [sum]} = Enum.split(row, 8)
      {key, sum}
    end)
  end

  defp balance_rows(ctx, after_key, upper) do
    from(b in "ledger_balance",
      where: b.ledger_id == ^ctx.lid,
      select: [b.k1, b.k2, b.k3, b.k4, b.k5, b.k6, b.k7, b.k8, b.on_hand, b.last_posting_seq]
    )
    |> after_key(after_key)
    |> upper_key(upper)
    |> Repo.all(prefix: ctx.prefix)
    |> Map.new(fn row ->
      {key, [on_hand, seq]} = Enum.split(row, 8)
      {key, {on_hand, seq}}
    end)
  end

  defp after_key(query, nil), do: query

  defp after_key(query, [a1, a2, a3, a4, a5, a6, a7, a8]) do
    from(q in query,
      where:
        fragment(
          "(?,?,?,?,?,?,?,?) > (?,?,?,?,?,?,?,?)",
          q.k1,
          q.k2,
          q.k3,
          q.k4,
          q.k5,
          q.k6,
          q.k7,
          q.k8,
          ^a1,
          ^a2,
          ^a3,
          ^a4,
          ^a5,
          ^a6,
          ^a7,
          ^a8
        )
    )
  end

  defp upper_key(query, nil), do: query

  defp upper_key(query, [u1, u2, u3, u4, u5, u6, u7, u8]) do
    from(q in query,
      where:
        fragment(
          "(?,?,?,?,?,?,?,?) <= (?,?,?,?,?,?,?,?)",
          q.k1,
          q.k2,
          q.k3,
          q.k4,
          q.k5,
          q.k6,
          q.k7,
          q.k8,
          ^u1,
          ^u2,
          ^u3,
          ^u4,
          ^u5,
          ^u6,
          ^u7,
          ^u8
        )
    )
  end

  # -- chain -----------------------------------------------------------------------------------

  defp chain_phase(ctx, st, budget) do
    %{prefix: prefix, lid: lid} = ctx
    fields = Digest.header_fields() ++ [:entry_digest, :chain_hash]

    entries =
      from(e in "ledger_entry",
        where: e.ledger_id == ^lid and e.posting_seq > ^st.seq and e.posting_seq <= ^st.n,
        order_by: e.posting_seq,
        limit: ^budget,
        select: map(e, ^fields)
      )
      |> Repo.all(prefix: prefix)

    legs = legs_by_seq(ctx, st.seq, entries)

    case walk(entries, legs, st.prev) do
      {:broken, seq} ->
        {:done, %{st | chain: {:broken_at, seq}, seq: seq}}

      {:ok, prev, last} ->
        seq = if last == nil, do: st.seq, else: last
        st = %{st | prev: prev, seq: seq}

        if length(entries) < budget or seq == st.n,
          do: {:done, tail_check(st)},
          else: {:more, st}
    end
  end

  defp legs_by_seq(_ctx, _from_seq, []), do: %{}

  defp legs_by_seq(ctx, from_seq, entries) do
    lid = ctx.lid
    top = entries |> List.last() |> Map.fetch!(:posting_seq)

    from(l in "ledger_leg",
      where: l.ledger_id == ^lid and l.posting_seq > ^from_seq and l.posting_seq <= ^top,
      order_by: [l.posting_seq, l.leg_no],
      select: {l.posting_seq, map(l, ^Digest.leg_fields())}
    )
    |> Repo.all(prefix: ctx.prefix)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp walk(entries, legs, prev) do
    Enum.reduce_while(entries, {:ok, prev, nil}, fn entry, {:ok, prev, _last} ->
      seq = entry.posting_seq
      header = Enum.reduce(@uuid_fields, entry, &Map.update!(&2, &1, fn v -> load_uuid(v) end))
      leg_maps = Map.get(legs, seq, [])
      digest = Digest.entry_digest(header, leg_maps)

      if digest == entry.entry_digest and Digest.chain_hash(prev, digest) == entry.chain_hash,
        do: {:cont, {:ok, entry.chain_hash, seq}},
        else: {:halt, {:broken, seq}}
    end)
  end

  defp load_uuid(nil), do: nil

  defp load_uuid(raw) do
    {:ok, text} = Ecto.UUID.load(raw)
    text
  end

  defp tail_check(%{seq: seq, n: n} = st) when seq != n, do: %{st | chain: {:broken_at, seq + 1}}

  defp tail_check(%{prev: prev, head: head, n: n} = st) when prev != head,
    do: %{st | chain: {:broken_at, n}}

  defp tail_check(st), do: %{st | chain: :ok}
end
