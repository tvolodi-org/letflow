defmodule Letflow.Ledger.Read do
  @moduledoc """
  REQ-637 / GH #3559 part B (slice L2b): the bodies of `Letflow.Ledger.balances/4` and
  `Letflow.Ledger.entries/3`. Read only: SELECT statements built with Ecto composition, bound
  parameters only, no lock option, no `Logger` call. Every statement carries the prefix and the
  ledger id of the `Letflow.Ledger.Authorized` value; a filters or page map cannot name either.

  ## One snapshot (balances)

  A report is ONE SQL statement: the counter row of the ledger id drives a left lateral join of
  the page of balance keys, so the counter value (`ledger_seq`) and the rows come from one
  statement snapshot (read committed gives a statement one snapshot, and this also holds when the
  caller is already inside a transaction). Both bases:

    * as-posted `{:posting_seq, n | :latest}`: the sum of the legs with `posting_seq <= n`. The
      balance row IS that sum when its `last_posting_seq <= n` (it is maintained under the key lock
      together with the legs), so legs are read only for keys that moved past `n`. `:latest` is the
      counter of the same snapshot, so no leg lies beyond it and no leg is read at all;
    * as-of event time `{:event_time, t, n | :latest}`: legs with `event_time <= t AND
      posting_seq <= n`, summed per key.

  The page is a keyset over the balance primary key `(k1..k8)` (the columns are `COLLATE "C"`,
  so the order is byte-wise), `limit + 1` rows decide `next_cursor`. A key with a zero sum is
  returned; a key with no qualifying leg (including the empty balance rows a refused or duplicate
  posting leaves, `last_posting_seq = 0`) is not. Every statement filters on the ledger id, so
  a partitioned table prunes to one partition.

  The cursor is `Base.url_encode64` of JSON with the resolved cutoff `n` and the last key. It is
  unsigned: honest replay only, not a security feature.

  ## Entries

  Two statements: the entries page, then the legs of the returned `posting_seq` range. They are
  consistent without a transaction because writers of one ledger id serialize on the counter
  row until commit, so entries become visible in `posting_seq` order, and an entry is written
  with all its legs and balances in one transaction.

  ## Scoped reads (REQ-693, decision 0073 S3 to S7)

  An `Authorized` value with `scope: {:nodes, ids}` filters on the registration's scope slot
  column (`scope_col`) INSIDE the statement that carries the sums, the limit and the cursor: the
  rows of units outside the set are never selected, counted or summed. Ids are bound `text[]`
  parameters compared by byte equality with the `COLLATE "C"` column. The filter key
  `scope_subtree` (one node id P) narrows to the subtree of P through a subquery on the tenant's
  `scope_node_paths` in the same statement (P and retired descendants included), and the report
  key `coverage` says whether the reader sees the whole subtree (`:complete`) or only its own
  units in it (`:visible_only`). `entries/3` lists an entry only when one of its legs is visible
  and returns the other legs masked: only `leg_no`, `quantity`, `unit_ref` and `masked: true`;
  the key columns and `document_line_id` of a hidden leg are not selected from the database.

  ## What is never returned

  Rows are built field by field from an explicit select list: actor, subject, client op id,
  origin key, payload hash, device and offline columns, scope ref, `bpm_*` columns and the digest
  chain are never read. Refusals are bare atoms (`:invalid_filter`, `:cutoff_in_future`), so no
  slot value or free text can reach a log.
  """

  import Ecto.Query

  alias Letflow.Identity
  alias Letflow.Ledger
  alias Letflow.Ledger.Authorized
  alias Letflow.Ledger.Digest
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @k_fields [:k1, :k2, :k3, :k4, :k5, :k6, :k7, :k8]
  @default_limit 50
  @max_value_bytes 200
  @default_timezone "Asia/Almaty"
  @timezone_form ~r/\A[A-Za-z0-9_+\-\/]{1,64}\z/
  @entry_filters ~w(cause document_type document_id correlation_id from_seq to_seq scope_subtree)
  @subtree_key "scope_subtree"

  # ---- balances ------------------------------------------------------------------------------

  @doc false
  def balances(%Authorized{} = a, basis, filters, page) do
    with {:ok, kind, t, n} <- check_basis(basis),
         {:ok, filt, subtree} <- check_slot_filters(a, filters),
         {:ok, limit, cursor} <- check_page(page, &decode_balance_cursor/1),
         {:ok, n, key} <- apply_cursor(n, cursor) do
      run_balances(a, kind, t, n, filt, subtree, limit, key)
    end
  end

  defp check_basis({:posting_seq, :latest}), do: {:ok, :posted, nil, nil}
  defp check_basis({:posting_seq, n}) when is_integer(n) and n >= 0, do: {:ok, :posted, nil, n}

  defp check_basis({:event_time, %DateTime{} = t, :latest}), do: {:ok, :event, t, nil}

  defp check_basis({:event_time, %DateTime{} = t, n}) when is_integer(n) and n >= 0,
    do: {:ok, :event, t, n}

  defp check_basis(_other), do: {:error, :invalid_filter}

  defp check_slot_filters(%Authorized{slot_names: names} = a, filters) when is_map(filters) do
    {subtree_pairs, slot_filters} =
      Enum.split_with(filters, fn {key, _value} -> key_name(key) == @subtree_key end)

    with {:ok, subtree} <- check_subtree(a, subtree_pairs),
         {:ok, filt} <- check_slot_pairs(names, slot_filters) do
      {:ok, filt, subtree}
    end
  end

  defp check_slot_filters(_a, _filters), do: {:error, :invalid_filter}

  defp check_subtree(_a, []), do: {:ok, nil}

  defp check_subtree(%Authorized{scope_col: col}, [{_key, id}])
       when not is_nil(col) and is_binary(id) do
    if valid_node_id?(id), do: {:ok, id}, else: {:error, :invalid_filter}
  end

  defp check_subtree(_a, _pairs), do: {:error, :invalid_filter}

  # The rule of `Letflow.ScopeNodePaths` for a node id: 1..64 bytes, valid UTF-8, no "/" and no
  # control character. A subtree filter is refused with the same rule before any statement.
  defp valid_node_id?(id) when is_binary(id) do
    byte_size(id) >= 1 and byte_size(id) <= 64 and String.valid?(id) and
      not String.match?(id, ~r/[\/\p{Cc}]/u)
  end

  defp valid_node_id?(_other), do: false

  defp check_slot_pairs(names, filters) do
    Enum.reduce_while(filters, {:ok, []}, fn {key, value}, {:ok, acc} ->
      with name when is_binary(name) <- key_name(key),
           idx when is_integer(idx) <- Enum.find_index(names, &(&1 == name)),
           true <- idx < 8 and valid_value?(value, true),
           false <- List.keymember?(acc, idx, 0) do
        {:cont, {:ok, [{idx, value} | acc]}}
      else
        _bad -> {:halt, {:error, :invalid_filter}}
      end
    end)
    |> case do
      {:ok, acc} ->
        {:ok, acc |> Enum.sort() |> Enum.map(fn {i, v} -> {Enum.at(@k_fields, i), v} end)}

      error ->
        error
    end
  end

  defp key_name(key) when is_binary(key), do: key
  defp key_name(key) when is_atom(key) and not is_nil(key), do: Atom.to_string(key)
  defp key_name(_key), do: nil

  defp valid_value?(value, allow_empty?) when is_binary(value) do
    byte_size(value) <= @max_value_bytes and String.valid?(value) and
      (allow_empty? or value != "")
  end

  defp valid_value?(_value, _allow_empty?), do: false

  defp check_page(page, cursor_decoder) when is_map(page) do
    with true <- Enum.all?(Map.keys(page), &(key_name(&1) in ["limit", "cursor"])),
         {:ok, limit} <- page_limit(fetch_either(page, :limit)),
         {:ok, cursor} <- page_cursor(fetch_either(page, :cursor), cursor_decoder) do
      {:ok, limit, cursor}
    else
      _bad -> {:error, :invalid_filter}
    end
  end

  defp check_page(_page, _decoder), do: {:error, :invalid_filter}

  defp fetch_either(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp page_limit(nil), do: {:ok, @default_limit}
  defp page_limit(n) when is_integer(n) and n >= 1, do: {:ok, min(n, Ledger.page_cap())}
  defp page_limit(_other), do: :error

  defp page_cursor(nil, _decoder), do: {:ok, nil}
  defp page_cursor(cursor, decoder), do: decoder.(cursor)

  defp decode_balance_cursor(cursor) when is_binary(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor),
         {:ok, %{"n" => n, "k" => keys}} when is_integer(n) and n >= 0 and is_list(keys) <-
           Jason.decode(json),
         true <- length(keys) == 8 and Enum.all?(keys, &is_binary/1) do
      {:ok, {n, keys}}
    else
      _bad -> :error
    end
  end

  defp decode_balance_cursor(_other), do: :error

  defp apply_cursor(n, nil), do: {:ok, n, nil}
  defp apply_cursor(nil, {cn, keys}), do: {:ok, cn, keys}
  defp apply_cursor(n, {n, keys}), do: {:ok, n, keys}
  defp apply_cursor(_n, _cursor), do: {:error, :invalid_filter}

  defp run_balances(a, kind, t, n, filt, subtree, limit, key) do
    rows_q = rows_query(a, kind, t, n, filt, subtree, key, limit + 1)

    query =
      from(c in "ledger_counter",
        as: :c,
        left_lateral_join: r in subquery(rows_q),
        on: true,
        where: c.ledger_id == ^a.ledger_id,
        order_by: [r.k1, r.k2, r.k3, r.k4, r.k5, r.k6, r.k7, r.k8],
        select: %{
          ledger_seq: c.last_seq,
          k1: r.k1,
          k2: r.k2,
          k3: r.k3,
          k4: r.k4,
          k5: r.k5,
          k6: r.k6,
          k7: r.k7,
          k8: r.k8,
          unit_ref: r.unit_ref,
          quantity: r.quantity,
          last_posting_seq: r.last_posting_seq
        }
      )

    found = Repo.all(query, prefix: a.prefix)
    ledger_seq = with [%{ledger_seq: s} | _] <- found, do: s, else: (_ -> 0)

    if is_integer(n) and n > ledger_seq do
      {:error, :cutoff_in_future}
    else
      cutoff = n || ledger_seq
      present = Enum.reject(found, &is_nil(&1.k1))
      {page_rows, more} = Enum.split(present, limit)

      next =
        if more != [] and page_rows != [],
          do: encode_cursor(cutoff, balance_key(List.last(page_rows)))

      {:ok,
       %{
         basis: basis_map(kind, t, cutoff),
         ledger_id: a.ledger_id,
         cutoff_seq: cutoff,
         as_of: t,
         timezone: timezone(a.prefix),
         filters: filters_echo(a, filt, subtree),
         coverage: coverage(a, subtree),
         ledger_seq: ledger_seq,
         rows: Enum.map(page_rows, &balance_row/1),
         next_cursor: next
       }}
    end
  end

  defp rows_query(a, kind, t, n, filt, subtree, key, lim) do
    base =
      from(b in "ledger_balance",
        as: :b,
        where: b.ledger_id == ^a.ledger_id,
        order_by: [b.k1, b.k2, b.k3, b.k4, b.k5, b.k6, b.k7, b.k8],
        limit: ^lim,
        select: %{
          k1: b.k1,
          k2: b.k2,
          k3: b.k3,
          k4: b.k4,
          k5: b.k5,
          k6: b.k6,
          k7: b.k7,
          k8: b.k8,
          unit_ref: b.unit_ref
        }
      )

    base =
      Enum.reduce(filt, base, fn {field, value}, q ->
        where(q, [b], field(b, ^field) == ^value)
      end)

    base =
      case scope_condition(a, subtree, :b) do
        nil -> base
        cond_ -> where(base, ^cond_)
      end

    base =
      case key do
        [k1, k2, k3, k4, k5, k6, k7, k8] ->
          where(
            base,
            [b],
            fragment(
              "(?, ?, ?, ?, ?, ?, ?, ?) > (?, ?, ?, ?, ?, ?, ?, ?)",
              b.k1,
              b.k2,
              b.k3,
              b.k4,
              b.k5,
              b.k6,
              b.k7,
              b.k8,
              ^k1,
              ^k2,
              ^k3,
              ^k4,
              ^k5,
              ^k6,
              ^k7,
              ^k8
            )
          )

        nil ->
          base
      end

    base = if is_integer(n), do: where(base, [b], ^n <= parent_as(:c).last_seq), else: base

    case {kind, n} do
      {:posted, nil} ->
        base
        |> where([b], b.last_posting_seq >= 1)
        |> select_merge([b], %{quantity: b.on_hand, last_posting_seq: b.last_posting_seq})

      {:posted, n} ->
        legs = legs_query(n, nil, true)

        base
        |> join(:inner_lateral, [b], g in subquery(legs), as: :g, on: true)
        |> where(
          [b, g],
          (b.last_posting_seq >= 1 and b.last_posting_seq <= ^n) or not is_nil(g.s)
        )
        |> select_merge([b, g], %{
          quantity: coalesce(g.q, b.on_hand),
          last_posting_seq: coalesce(g.s, b.last_posting_seq)
        })

      {:event, n} ->
        legs = legs_query(n, t, false)

        base
        |> join(:inner_lateral, [b], g in subquery(legs), as: :g, on: true)
        |> where([b, g], not is_nil(g.s))
        |> select_merge([b, g], %{quantity: g.q, last_posting_seq: g.s})
    end
  end

  # The legs of the parent balance key: for the as-posted basis only when the balance row moved
  # past the cutoff (otherwise the balance row is the sum and the lateral does no work).
  defp legs_query(n, t, shortcut?) do
    q =
      from(l in "ledger_leg",
        where:
          l.ledger_id == parent_as(:b).ledger_id and l.k1 == parent_as(:b).k1 and
            l.k2 == parent_as(:b).k2 and l.k3 == parent_as(:b).k3 and
            l.k4 == parent_as(:b).k4 and l.k5 == parent_as(:b).k5 and
            l.k6 == parent_as(:b).k6 and l.k7 == parent_as(:b).k7 and
            l.k8 == parent_as(:b).k8,
        select: %{q: sum(l.quantity), s: max(l.posting_seq)}
      )

    q = if is_integer(n), do: where(q, [l], l.posting_seq <= ^n), else: q
    q = if t, do: where(q, [l], l.event_time <= ^t), else: q

    if shortcut?,
      do: where(q, [l], parent_as(:b).last_posting_seq > ^n),
      else: q
  end

  defp balance_key(row), do: Enum.map(@k_fields, &Map.fetch!(row, &1))

  defp balance_row(row) do
    %{
      k: balance_key(row),
      unit_ref: row.unit_ref,
      quantity: Digest.quantity_text(row.quantity),
      last_posting_seq: row.last_posting_seq
    }
  end

  defp encode_cursor(n, keys),
    do: Base.url_encode64(Jason.encode!(%{"n" => n, "k" => keys}))

  defp basis_map(:posted, _t, n), do: %{type: "posting_seq", n: n}
  defp basis_map(:event, t, n), do: %{type: "event_time", t: t, n: n}

  defp filters_echo(%Authorized{slot_names: names}, filt, subtree) do
    echo =
      for {field, value} <- filt, into: %{} do
        {Enum.at(names, Enum.find_index(@k_fields, &(&1 == field))), value}
      end

    if subtree, do: Map.put(echo, @subtree_key, subtree), else: echo
  end

  # ---- scope (REQ-693) -----------------------------------------------------------------------

  # The condition on the scope column of the binding named `as_name`, or nil when the reader is
  # tenant-wide and no subtree is asked. Ids and the subtree are bound parameters only.
  defp scope_condition(%Authorized{scope: scope, scope_col: col, prefix: _}, subtree, as_name) do
    allowed =
      case scope do
        {:nodes, ids} ->
          dynamic(
            [{^as_name, x}],
            fragment("? = ANY(?)", field(x, ^col), type(^ids, {:array, :string}))
          )

        :all ->
          nil
      end

    sub =
      if subtree do
        nodes =
          from(d in Letflow.ScopeNodePaths.Node,
            join: p in Letflow.ScopeNodePaths.Node,
            on: fragment("starts_with(?, ?)", d.path, p.path),
            where: p.node_id == ^subtree,
            select: d.node_id
          )

        dynamic([{^as_name, x}], field(x, ^col) in subquery(nodes))
      end

    case {allowed, sub} do
      {nil, nil} -> nil
      {a, nil} -> a
      {nil, b} -> b
      {a, b} -> dynamic(^a and ^b)
    end
  end

  # `nil` without a subtree; `:complete` when the reader sees all of P's subtree (tenant-wide, or
  # P itself is in the live expanded allowed set: equal to `Scope.allowed?/3` for `{:node, P}`).
  defp coverage(_a, nil), do: nil
  defp coverage(%Authorized{scope: :all}, _subtree), do: :complete

  defp coverage(%Authorized{scope: {:nodes, ids}}, subtree),
    do: if(subtree in ids, do: :complete, else: :visible_only)

  # The tenant timezone is only stated in the report (storage stays UTC). Read from the tenant
  # record's settings when present; the default is the owner's assumption (D-086/D-087).
  defp timezone(prefix) do
    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, tenant} <- Identity.get_tenant(tenant_id),
         %{"timezone" => zone} when is_binary(zone) <- tenant.settings,
         true <- Regex.match?(@timezone_form, zone) do
      zone
    else
      _absent_or_malformed -> @default_timezone
    end
  end

  # ---- entries -------------------------------------------------------------------------------

  @doc false
  def entries(%Authorized{} = a, filters, page) do
    with {:ok, filt} <- check_entry_filters(a, filters),
         {:ok, limit, cursor} <- check_page(page, &decode_entry_cursor/1) do
      run_entries(a, filt, limit, cursor)
    end
  end

  defp check_entry_filters(a, filters) when is_map(filters) do
    Enum.reduce_while(filters, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      name = key_name(key)

      if name in @entry_filters and valid_entry_value?(name, value) and
           (name != @subtree_key or a.scope_col != nil) and
           not Map.has_key?(acc, name),
         do: {:cont, {:ok, Map.put(acc, name, value)}},
         else: {:halt, {:error, :invalid_filter}}
    end)
    |> case do
      {:ok, %{"from_seq" => from, "to_seq" => to}} when from > to -> {:error, :invalid_filter}
      other -> other
    end
  end

  defp check_entry_filters(_a, _filters), do: {:error, :invalid_filter}

  defp valid_entry_value?(name, value) when name in ["from_seq", "to_seq"],
    do: is_integer(value) and value >= 0

  defp valid_entry_value?(@subtree_key, value), do: valid_node_id?(value)
  defp valid_entry_value?(_name, value), do: valid_value?(value, false)

  defp decode_entry_cursor(n) when is_integer(n) and n >= 0, do: {:ok, n}
  defp decode_entry_cursor(_other), do: :error

  defp run_entries(a, filt, limit, cursor) do
    {subtree, filt} = Map.pop(filt, @subtree_key)
    lower = Enum.max([Map.get(filt, "from_seq", 0) - 1, cursor || 0, 0])

    query =
      from(e in "ledger_entry",
        as: :e,
        where: e.ledger_id == ^a.ledger_id and e.posting_seq > ^lower,
        order_by: [asc: e.posting_seq],
        limit: ^(limit + 1),
        select: %{
          entry_id: type(e.id, Ecto.UUID),
          ledger_id: e.ledger_id,
          posting_seq: e.posting_seq,
          cause: e.cause,
          reverses_entry_id: type(e.reverses_entry_id, Ecto.UUID),
          reason_code: e.reason_code,
          document_type: e.document_type,
          document_id: e.document_id,
          related_document_id: e.related_document_id,
          correlation_id: e.correlation_id,
          event_time: e.event_time,
          posting_time: e.posting_time
        }
      )

    query =
      Enum.reduce(filt, query, fn
        {"to_seq", v}, q -> where(q, [e], e.posting_seq <= ^v)
        {"from_seq", _v}, q -> q
        {"cause", v}, q -> where(q, [e], e.cause == ^v)
        {"document_type", v}, q -> where(q, [e], e.document_type == ^v)
        {"document_id", v}, q -> where(q, [e], e.document_id == ^v)
        {"correlation_id", v}, q -> where(q, [e], e.correlation_id == ^v)
      end)

    query =
      case scope_condition(a, subtree, :l) do
        nil ->
          query

        cond_ ->
          visible_leg =
            from(l in "ledger_leg",
              as: :l,
              where:
                l.ledger_id == parent_as(:e).ledger_id and
                  l.posting_seq == parent_as(:e).posting_seq,
              where: ^cond_,
              select: 1
            )

          where(query, exists(subquery(visible_leg)))
      end

    found = Repo.all(query, prefix: a.prefix)
    {page_rows, more} = Enum.split(found, limit)
    legs = legs_by_seq(a, page_rows)

    rows = Enum.map(page_rows, &Map.put(&1, :legs, Map.get(legs, &1.posting_seq, [])))

    next = if more != [] and rows != [], do: List.last(rows).posting_seq

    {:ok, %{rows: rows, next_cursor: next}}
  end

  defp legs_by_seq(_a, []), do: %{}

  defp legs_by_seq(a, page_rows) do
    seqs = Enum.map(page_rows, & &1.posting_seq)

    from(l in "ledger_leg",
      where: l.ledger_id == ^a.ledger_id and l.posting_seq in ^seqs,
      order_by: [asc: l.posting_seq, asc: l.leg_no]
    )
    |> leg_select(a)
    |> Repo.all(prefix: a.prefix)
    |> Enum.group_by(& &1.posting_seq, &leg_map/1)
  end

  # A tenant-wide reader selects the columns as they are. A scoped reader selects every key
  # column and the document line id through a CASE on the scope column, so the values of a hidden
  # leg never leave the database (REQ-693 criterion 6).
  defp leg_select(query, %Authorized{scope: :all}) do
    select(query, [l], %{
      posting_seq: l.posting_seq,
      leg_no: l.leg_no,
      k1: l.k1,
      k2: l.k2,
      k3: l.k3,
      k4: l.k4,
      k5: l.k5,
      k6: l.k6,
      k7: l.k7,
      k8: l.k8,
      quantity: l.quantity,
      unit_ref: l.unit_ref,
      document_line_id: l.document_line_id
    })
  end

  defp leg_select(query, %Authorized{scope: {:nodes, ids}, scope_col: col}) do
    masked = fn column ->
      dynamic(
        [l],
        fragment(
          "CASE WHEN ? = ANY(?) THEN ? END",
          field(l, ^col),
          type(^ids, {:array, :string}),
          field(l, ^column)
        )
      )
    end

    query
    |> select([l], %{
      posting_seq: l.posting_seq,
      leg_no: l.leg_no,
      quantity: l.quantity,
      unit_ref: l.unit_ref,
      visible: fragment("? = ANY(?)", field(l, ^col), type(^ids, {:array, :string}))
    })
    |> select_merge(^Map.new(@k_fields ++ [:document_line_id], &{&1, masked.(&1)}))
  end

  defp leg_map(%{visible: false} = leg) do
    %{
      leg_no: leg.leg_no,
      quantity: Digest.quantity_text(leg.quantity),
      unit_ref: leg.unit_ref,
      masked: true
    }
  end

  defp leg_map(leg) do
    %{
      leg_no: leg.leg_no,
      k: balance_key(leg),
      quantity: Digest.quantity_text(leg.quantity),
      unit_ref: leg.unit_ref,
      document_line_id: leg.document_line_id
    }
  end
end
