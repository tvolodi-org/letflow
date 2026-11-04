defmodule Letflow.Ledger do
  @moduledoc """
  REQ-621 / GH #3469 part A (slice L2a of the WMS stock ledger, GH #2657): the posting primitive
  and nothing around it. `post/1` takes one opaque `Letflow.Ledger.Capability` and, inside the
  caller's open transaction, validates the declarative posting, locks the balance rows in
  ascending key order, runs the no-negative / bound / unit guard, and only then takes the counter
  row and writes the entry, its legs and the balances (note gh2657 sections 6, 7.1, 7.3).

  ## Order of work (why it cannot deadlock)

  REQ-692 / GH #3725 (L2a rework, decision 0073 A2, A3, A5): one transaction carries a posting plan
  of one or two postings. `lock_postings/1` is the one core lock step and writes nothing;
  `write_posting/2` writes one locked posting; `post/1` is `lock_postings([cap])` followed by
  `write_posting/2`. Only `lock_postings/1` returns refusals; `write_posting/2` returns contract
  atoms only (`:not_in_plan`, `:plan_already_written`).

  1. a non-list, an empty list, a non-capability, a malformed prefix or two different prefixes is
     `:invalid_capability`, more than two capabilities `:ledger_too_many_postings`, both before any
     query; a call outside a transaction raises; the first statement is the isolation check;
  2. validation and the sign rule (pure, `Letflow.Ledger.Validate`) per capability: no lock is
     taken for a malformed or unbalanced posting; then the plan rules (two postings on one
     ledger id: `:ledger_duplicate_ledger_in_transaction`; document type or id differing or
     empty: `:ledger_document_mismatch`);
  3. the postings are sorted by ledger id; the idempotency lookup of each; the distinct balance
     keys of all postings, sorted by `(ledger_id, k1..k8)` byte-wise, are inserted if absent
     (`ON CONFLICT DO NOTHING`, with the first-touch unit pin and the minimum `max_on_hand` of the
     matching key bounds), then each row is locked `FOR UPDATE`, one key at a time, in the same
     order;
  4. the lookup again, then the guard per posting in ledger-id order (unit, then
     `insufficient_balance`, then `balance_bound_exceeded`), reading the pin from the LOCKED row;
  5. as the last ledger locks, the counter rows (insert pass, then `FOR UPDATE` pass, ascending);
     the lookup a third time; the event-time check of each posting under the counter locks;
  6. `write_posting/2` per ledger id: sequence, digest and chain hash from the locked values; the
     counter update carries the locked `last_seq` in its WHERE term; the entry, its legs and the
     balances are written. The only refusal that can follow the counter update is
     `posting_already_reversed` from the unique-index backstop of a reversal (see Reversal).

  Every ledger lock of every plan is taken in one ascending total order, so two plans (or a plan
  and a single posting) cannot form a cycle. Every statement carries the capability's prefix;
  every value is a bound parameter. Lock timeouts, deadlocks and statement timeouts are not
  rescued: they leave the transaction.

  ## Idempotency and isolation (part B)

  The first statement of `lock_postings/1` after the shape checks is
  `SELECT current_setting('transaction_isolation')`: anything but `read committed` is refused as
  `{:ledger_contract, :isolation_not_read_committed}` before a row is read or locked, because the
  rechecks below rely on every statement seeing a fresh snapshot.

  The idempotency keys are per ledger id (0073 A5): every disjunct of the lookup carries the
  posting's ledger id, so the same `(subject_id, client_op_id)`, `origin_key` or
  `(subject_id, device_id, client_seq)` on another ledger id is another posting. A repeated
  `(ledger_id, subject_id, client_op_id)` with the same `payload_hash` returns the first entry
  with `duplicate: true` and writes nothing; the same key with another payload, an `origin_key`
  already used by another entry of that ledger id, or a `client_op_id` and an `origin_key` that
  match two different entries is `idempotency_key_reuse`. In a plan, when every posting is a
  duplicate the lock step stops and `write_posting/2` returns the existing entries; when only
  some are, the plan is `idempotency_key_reuse` ("both or neither"). The lookup runs at three
  places: before the balance rows are created, right after the balance locks and before the
  guard (so a retry never sees the balance the first posting left), and right after the counter
  locks (no `last_seq` change on a duplicate). A duplicate found at the second or third place may
  leave zero-quantity balance rows, or a counter row at `last_seq` 0 for a fresh ledger id; no
  entry, leg or `last_seq` change is written. The entry insert rescues
  only the reversal-target unique index (see Reversal): every other key includes the ledger id and
  all writers of one ledger id serialize on its counter row, so a unique violation on them after
  the third lookup is unreachable.
  `unique_violation_refusal/1` stays as a pure mapper of the three constraint names.

  ## Offline fields and event time (part C)

  `device_id`, `client_seq` and `client_event_time` come from the raw command only (so they are
  part of the `payload_hash`; a retry with other offline values is `idempotency_key_reuse`). A
  second `client_op_id` that reuses a `(subject, device_id, client_seq)` is `client_seq_conflict`;
  the unique index is the backstop. `event_time` is the client time or, online, the posting time.
  It is checked under the counter lock, before the counter is updated: more than 5 minutes after
  the posting time is `event_time_in_future`, more than `max_event_lateness_hours` before it is
  `event_time_too_old` (the registration must carry that integer, 1..8760, else
  `invalid_registration`). A duplicate is answered before this check. The offline columns are in
  the entry digest.

  ## Unrescued errors

  Nothing is rescued: lock timeout (55P03), deadlock (40P01), statement timeout (57014) and a
  CHECK violation (23514, unreachable under the validation; its mapping is slice L3) propagate
  and leave the transaction.

  ## Reconcile (REQ-637 part C)

  `reconcile/2` re-derives balances, the sequence and the digest chain, chunked and read-only; see
  `Letflow.Ledger.Reconcile`. The audit-entry comparison belongs to slice L3.

  ## Reversal (REQ-637 part A, slice L2b)

  A reversal is a NEW posting (cause `reversal`, sign rule `reversal`, `reverses_entry_id`) in the
  target's ledger id; its legs are derived here by negating the target's legs, never supplied. The
  target and its legs are read before any lock (rows are immutable) and always filtered by the
  posting's ledger id and the capability's prefix: an unknown id, a malformed id, a target of
  another ledger id and a target of another tenant give the one refusal
  `validation_failed` / `movement_not_found`. A target that is itself a reversal is
  `posting_is_reversal`. `document_type`, `document_id` and `correlation_id` default to the
  target's. The "already reversed" re-read (`posting_already_reversed`) runs in the lock step after
  the second idempotency lookup and before the counter locks; the unique index on
  `(ledger_id, reverses_entry_id)` is its backstop, mapped by `insert_entry/2` (the caller rolls
  the transaction back on every refusal, so a refusal after the counter update leaves nothing).
  The guard applies; for a reversal `insufficient_balance` carries only `leg_nos` and `count`.

  Pairs (criterion 11): an entry is PAIRED when an entry of another ledger id, not a reversal, has
  the same non-empty document_type, document_id and correlation_id. A single reversal of a paired
  entry is `posting_is_paired`; a plan of two reversals whose targets are not siblings is
  `ledger_document_mismatch`; both before any lock. The single-reversal sibling read is the only
  read that crosses ledger ids. No live caller exists before slice L3.

  ## Pilot gate (note 17, quoted)

  The stock module is NOT enabled for a customer tenant until L6 AND L7 are done, and
  serial-tracked goods stay out of the pilot until OQ-23 (serial uniqueness across locations) is
  resolved. Reason: without L7 a typo in an part or location id creates a NEW balance key and the
  first-touch unit_ref and max_on_hand pin on it is permanent; without L6 a scoped storekeeper
  cannot post; without OQ-23 the same serial can be active at two locations (key_bounds are per
  balance key including location). This entry delivers the primitive only and enables nothing.

  ## Contract atoms

  `{:ledger_contract, :invalid_capability}` (not a capability, or a malformed prefix) and
  `{:ledger_contract, :ledger_too_many_postings}`, `:ledger_duplicate_ledger_in_transaction`,
  `:ledger_document_mismatch`, `:not_in_plan`, `:plan_already_written` (REQ-692) and
  `{:ledger_contract, :invalid_registration}` (the registration data is not of the expected
  shape: an extra atom beyond note 12.2, chosen here as the fail-closed backstop for the rule
  that L3 will enforce at build time) and `{:ledger_contract, :isolation_not_read_committed}`.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Api.Authorization
  alias Letflow.Api.Scope
  alias Letflow.Api.Scope.Principal
  alias Letflow.Ledger.Authorized
  alias Letflow.Ledger.Capability
  alias Letflow.Ledger.Digest
  alias Letflow.Ledger.LockedPlan
  alias Letflow.Ledger.Reconcile
  alias Letflow.Ledger.Validate
  alias Letflow.Repo

  @type posted :: %{
          entry_id: Ecto.UUID.t(),
          ledger_id: String.t(),
          posting_seq: pos_integer(),
          chain_hash: String.t(),
          duplicate: boolean()
        }
  @type refusal :: {:ledger_refused, atom(), String.t(), map()}

  @prefix_form ~r/\Atenant_[0-9a-f]{32}\z/
  @control ~r/[\x00-\x1f\x7f]/
  @limit Decimal.new("1.0E+21")
  @page_cap 200

  @type reconciliation :: Reconcile.reconciliation()

  @doc "The one page cap of the read side: the most legs one posting can carry."
  @spec page_cap() :: pos_integer()
  def page_cap, do: @page_cap

  @doc """
  One chunk of a reconciliation of the authorised ledger id (see `Letflow.Ledger.Reconcile`).
  A value not minted for `:reconcile` raises `FunctionClauseError`.
  """
  @spec reconcile(Authorized.t(), map()) ::
          {:ok, reconciliation()}
          | {:error, :reconcile_busy | :invalid_cursor | :invalid_opts | :run_expired}
  defdelegate reconcile(authorized, opts), to: Reconcile

  @doc false
  @spec post(Capability.t()) ::
          {:ok, posted()} | {:error, refusal()} | {:error, {:ledger_contract, atom()}}
  def post(cap) when is_struct(cap, Capability) do
    with {:ok, plan} <- lock_postings([cap]),
         [ledger_id] <- Map.keys(plan.postings) do
      write_posting(plan, ledger_id)
    end
  end

  def post(_not_a_capability), do: {:error, {:ledger_contract, :invalid_capability}}

  @doc false
  @spec lock_postings([Capability.t()]) ::
          {:ok, LockedPlan.t()} | {:error, refusal()} | {:error, {:ledger_contract, atom()}}
  def lock_postings(caps) do
    with :ok <- check_plan_shape(caps) do
      unless Repo.in_transaction?() do
        raise ArgumentError, "Letflow.Ledger.post/1 requires an open transaction"
      end

      case Repo.query!("SELECT current_setting('transaction_isolation')") do
        %{rows: [["read committed"]]} -> lock_in_transaction(caps)
        _other -> {:error, {:ledger_contract, :isolation_not_read_committed}}
      end
    end
  end

  # No database statement: a list of one or two capabilities of one well-formed prefix.
  defp check_plan_shape(caps) when is_list(caps) and caps != [] do
    prefixes = for cap <- caps, is_struct(cap, Capability), do: cap.prefix

    cond do
      length(prefixes) != length(caps) -> {:error, {:ledger_contract, :invalid_capability}}
      not Enum.all?(prefixes, &(is_binary(&1) and Regex.match?(@prefix_form, &1))) -> invalid()
      length(Enum.uniq(prefixes)) != 1 -> invalid()
      length(caps) > 2 -> {:error, {:ledger_contract, :ledger_too_many_postings}}
      true -> :ok
    end
  end

  defp check_plan_shape(_caps), do: invalid()

  defp invalid, do: {:error, {:ledger_contract, :invalid_capability}}

  defp lock_in_transaction(caps) do
    prefix = hd(caps).prefix

    with {:ok, parts} <- prepare_all(caps),
         {:ok, parts} <- resolve_reversals(prefix, parts),
         :ok <- check_plan_rules(parts),
         :ok <- check_pairing(prefix, parts) do
      parts = Enum.sort_by(parts, & &1.ledger_id)
      lock_parts(prefix, parts)
    end
  end

  # Pure per-capability validation, in list order, first failure returned.
  defp prepare_all(caps) do
    caps
    |> Enum.reduce_while({:ok, []}, fn cap, {:ok, acc} ->
      case prepare(cap) do
        {:ok, part} -> {:cont, {:ok, [part | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      error -> error
    end
  end

  defp prepare(cap) do
    with {:ok, bounds} <- check_registration(cap.registration),
         {:ok, ids} <- check_identity(cap),
         {:ok, posting} <- Validate.posting(cap.posting, cap.command, cap.registration),
         {:ok, groups} <- prepare_groups(posting, bounds) do
      {:ok,
       %{
         cap: cap,
         ids: ids,
         posting: posting,
         groups: groups,
         bounds: bounds,
         reversal: posting.reversal,
         ledger_id: posting.ledger_id,
         payload_hash: Digest.payload_hash(cap.command, ids.subject_id)
       }}
    end
  end

  # A reversal has no legs yet: `resolve_reversals/2` derives them from the target.
  defp prepare_groups(%{reversal: true}, _bounds), do: {:ok, []}
  defp prepare_groups(posting, bounds), do: group_keys(posting.legs, bounds)

  # -- reversal: target resolution and pairing (no lock) -----------------------------------------

  # Reads each reversal's target and legs WITHOUT a lock (the rows are immutable) and derives the
  # reversal's legs by negation. Every read carries the posting's ledger id, so a target of another
  # ledger id or another tenant (the prefix) is "no row", the same refusal as an unknown id.
  defp resolve_reversals(prefix, parts) do
    parts
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case resolve_reversal(prefix, part) do
        {:ok, resolved} -> {:cont, {:ok, [resolved | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      error -> error
    end
  end

  defp resolve_reversal(_prefix, %{reversal: false} = part), do: {:ok, part}

  defp resolve_reversal(prefix, %{posting: posting} = part) do
    ledger_id = posting.ledger_id
    target_id = posting.reverses_entry_id

    target =
      from(e in "ledger_entry",
        where: e.ledger_id == ^ledger_id and e.id == type(^target_id, Ecto.UUID),
        select: %{
          cause: e.cause,
          reverses_entry_id: type(e.reverses_entry_id, Ecto.UUID),
          document_type: e.document_type,
          document_id: e.document_id,
          correlation_id: e.correlation_id
        }
      )
      |> Repo.one(prefix: prefix)

    cond do
      target == nil ->
        Validate.movement_not_found()

      target.cause == "reversal" or target.reverses_entry_id != nil ->
        Validate.refuse(:posting_is_reversal, %{entry_id: target_id})

      true ->
        legs = derive_legs(prefix, ledger_id, target_id)

        posting =
          Map.merge(posting, %{
            legs: legs,
            document_type: posting.document_type || target.document_type,
            document_id: posting.document_id || target.document_id,
            correlation_id: posting.correlation_id || target.correlation_id
          })

        with {:ok, groups} <- group_keys(legs, part.bounds) do
          {:ok, %{part | posting: posting, groups: groups, reversal: %{target: target}}}
        end
    end
  end

  # The exact negation of the target's legs: same slots, unit, attrs and line id, leg_no order kept.
  defp derive_legs(prefix, ledger_id, target_id) do
    from(l in "ledger_leg",
      where: l.ledger_id == ^ledger_id and l.entry_id == type(^target_id, Ecto.UUID),
      order_by: l.leg_no,
      select: %{
        leg_no: l.leg_no,
        k: [l.k1, l.k2, l.k3, l.k4, l.k5, l.k6, l.k7, l.k8],
        quantity: l.quantity,
        unit_ref: l.unit_ref,
        attrs: l.attrs,
        document_line_id: l.document_line_id
      }
    )
    |> Repo.all(prefix: prefix)
    |> Enum.map(&%{&1 | quantity: Decimal.negate(&1.quantity)})
  end

  # Criterion 11 (two-posting document). An entry is PAIRED when another entry of the tenant, not a
  # reversal, in a DIFFERENT ledger id, has the same non-empty document_type, document_id and
  # correlation_id. A single reversal of a paired entry is refused; two reversals must target
  # siblings of each other. Both refusals precede every lock. The single-reversal sibling read is
  # the one read that crosses ledger ids (index on document_type, document_id); it runs once per
  # single reversal, outside the lock step, and never for an ordinary posting.
  defp check_pairing(prefix, parts) do
    case Enum.filter(parts, & &1.reversal) do
      [] ->
        :ok

      [single] ->
        if paired?(prefix, single),
          do: Validate.refuse(:posting_is_paired, %{entry_id: single.posting.reverses_entry_id}),
          else: :ok

      [a, b] ->
        if siblings?(a.reversal.target, b.reversal.target),
          do: :ok,
          else: {:error, {:ledger_contract, :ledger_document_mismatch}}
    end
  end

  defp siblings?(a, b) do
    triple?(a) and triple?(b) and
      {a.document_type, a.document_id, a.correlation_id} ==
        {b.document_type, b.document_id, b.correlation_id}
  end

  defp triple?(target),
    do: Enum.all?([target.document_type, target.document_id, target.correlation_id], &filled?/1)

  defp filled?(value), do: is_binary(value) and value != ""

  defp paired?(prefix, %{reversal: %{target: target}, ledger_id: ledger_id}) do
    triple?(target) and
      from(e in "ledger_entry",
        where:
          e.document_type == ^target.document_type and e.document_id == ^target.document_id and
            e.correlation_id == ^target.correlation_id and e.ledger_id != ^ledger_id and
            e.cause != "reversal",
        select: 1,
        limit: 1
      )
      |> Repo.one(prefix: prefix) != nil
  end

  defp check_plan_rules([_single]), do: :ok

  defp check_plan_rules([a, b]) do
    cond do
      a.ledger_id == b.ledger_id ->
        {:error, {:ledger_contract, :ledger_duplicate_ledger_in_transaction}}

      not document_ref?(a.posting) or not document_ref?(b.posting) or
        a.posting.document_type != b.posting.document_type or
          a.posting.document_id != b.posting.document_id ->
        {:error, {:ledger_contract, :ledger_document_mismatch}}

      true ->
        :ok
    end
  end

  defp document_ref?(posting) do
    Enum.all?([posting.document_type, posting.document_id], &(is_binary(&1) and &1 != ""))
  end

  # The one lock step (decision 0073 A3). `parts` are sorted by ledger id; every loop below runs
  # over that order, and inside one posting over the sorted keys, so the union is taken in
  # ascending (ledger_id, k1..k8) order. Nothing is written here.
  defp lock_parts(prefix, parts) do
    with :none <- lookup_all(prefix, parts),
         :ok <- insert_all_balances(prefix, parts),
         {:ok, parts} <- lock_all_balances(prefix, parts),
         :none <- lookup_all(prefix, parts),
         :ok <- check_not_reversed(prefix, parts),
         :ok <- guard_all(parts),
         {:ok, parts} <- lock_counters(prefix, parts),
         :none <- lookup_all(prefix, parts),
         {:ok, parts} <- stamp_event_times(parts) do
      {:ok,
       %LockedPlan{
         prefix: prefix,
         postings: Map.new(parts, &{&1.ledger_id, Map.put(&1, :duplicate, nil)})
       }}
    else
      {:duplicate, posted_by_ledger} ->
        postings =
          Map.new(
            parts,
            &{&1.ledger_id, %{duplicate: Map.fetch!(posted_by_ledger, &1.ledger_id)}}
          )

        {:ok, %LockedPlan{prefix: prefix, postings: postings}}

      {:error, _} = error ->
        error
    end
  end

  defp insert_all_balances(prefix, parts) do
    Enum.each(parts, &insert_missing_balances(prefix, &1.ledger_id, &1.groups))
  end

  defp lock_all_balances(prefix, parts) do
    {:ok,
     Enum.map(parts, fn part ->
       {:ok, locked} = lock_balances(prefix, part.ledger_id, part.groups)
       Map.put(part, :locked, locked)
     end)}
  end

  # Step 8: the "already reversed" re-read, after the key locks and the second idempotency lookup
  # (an identical retry is answered as a duplicate first) and before the counter lock (the loser of
  # two concurrent reversals never touches `ledger_counter`). Read committed: a fresh snapshot.
  defp check_not_reversed(prefix, parts) do
    Enum.find_value(parts, :ok, fn
      %{reversal: %{}, ledger_id: ledger_id, posting: %{reverses_entry_id: target_id}} ->
        reversed? =
          from(e in "ledger_entry",
            where:
              e.ledger_id == ^ledger_id and e.reverses_entry_id == type(^target_id, Ecto.UUID),
            select: 1,
            limit: 1
          )
          |> Repo.one(prefix: prefix)

        if reversed?, do: Validate.refuse(:posting_already_reversed, %{entry_id: target_id})

      _ordinary ->
        nil
    end)
  end

  defp guard_all(parts) do
    Enum.find_value(parts, :ok, fn part ->
      case guard(part.groups, part.locked, part.cap.registration.slots, part.reversal != false) do
        :ok -> nil
        {:error, _} = refusal -> refusal
      end
    end)
  end

  defp lock_counters(prefix, parts) do
    for part <- parts do
      Repo.insert_all(
        "ledger_counter",
        [%{ledger_id: part.ledger_id, last_seq: 0, last_chain_hash: ""}],
        prefix: prefix,
        on_conflict: :nothing
      )
    end

    {:ok,
     Enum.map(parts, fn part ->
       ledger_id = part.ledger_id

       counter =
         from(c in "ledger_counter",
           where: c.ledger_id == ^ledger_id,
           select: %{seq: c.last_seq, hash: c.last_chain_hash},
           lock: "FOR UPDATE"
         )
         |> Repo.one!(prefix: prefix)

       Map.put(part, :counter, counter)
     end)}
  end

  # Under the counter locks, before any write: a refusal here writes nothing.
  defp stamp_event_times(parts) do
    Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, acc} ->
      %{rows: [[posting_time]]} = Repo.query!("SELECT clock_timestamp()")
      event_time = part.posting.client_event_time || posting_time

      case check_event_time(event_time, posting_time, part.cap.registration) do
        :ok ->
          stamped = Map.merge(part, %{event_time: event_time, posting_time: posting_time})
          {:cont, {:ok, [stamped | acc]}}

        {:error, _} = refusal ->
          {:halt, refusal}
      end
    end)
    |> case do
      {:ok, stamped} -> {:ok, Enum.reverse(stamped)}
      refusal -> refusal
    end
  end

  # -- idempotency -----------------------------------------------------------------------------

  # The one classification of a plan's lookups, used at all three lookup places.
  # :none | {:duplicate, %{ledger_id => posted}} | {:error, refusal}. Every posting is looked up;
  # all duplicates -> :duplicate; a mix of duplicate and new postings is refused (both or neither).
  defp lookup_all(prefix, parts) do
    results = for part <- parts, do: {part.ledger_id, lookup(prefix, part)}

    cond do
      error = Enum.find_value(results, fn {_, r} -> match?({:error, _}, r) && r end) ->
        error

      Enum.all?(results, fn {_, r} -> r == :none end) ->
        :none

      Enum.all?(results, fn {_, r} -> match?({:duplicate, _}, r) end) ->
        {:duplicate, Map.new(results, fn {id, {:duplicate, posted}} -> {id, posted} end)}

      true ->
        Validate.refuse(:idempotency_key_reuse, %{})
    end
  end

  # :none | {:duplicate, posted} | {:error, refusal}. One bound-parameter read, scoped by prefix,
  # by the posting's ledger id (in every disjunct) and by the capability's subject: another
  # ledger id's or subject's entry never appears in a result.
  defp lookup(prefix, %{cap: cap, ids: ids, ledger_id: ledger_id, payload_hash: payload_hash}) do
    subject = ids.subject_id
    op = cap.command.client_op_id
    origin = cap.origin_key
    device = Map.get(cap.command, :device_id)
    seq = Map.get(cap.command, :client_seq)

    base =
      from(e in "ledger_entry",
        where:
          (e.ledger_id == ^ledger_id and e.subject_id == type(^subject, Ecto.UUID) and
             e.client_op_id == ^op) or
            (e.ledger_id == ^ledger_id and e.origin_key == ^origin)
      )

    query =
      if is_binary(device) and is_integer(seq) do
        from(e in base,
          or_where:
            e.ledger_id == ^ledger_id and e.subject_id == type(^subject, Ecto.UUID) and
              e.device_id == ^device and e.client_seq == ^seq
        )
      else
        base
      end

    rows =
      from(e in query,
        select: %{
          id: type(e.id, Ecto.UUID),
          ledger_id: e.ledger_id,
          posting_seq: e.posting_seq,
          chain_hash: e.chain_hash,
          subject_id: type(e.subject_id, Ecto.UUID),
          client_op_id: e.client_op_id,
          origin_key: e.origin_key,
          payload_hash: e.payload_hash,
          device_id: e.device_id,
          client_seq: e.client_seq
        }
      )
      |> Repo.all(prefix: prefix)

    by_key = Enum.find(rows, &(&1.subject_id == subject and &1.client_op_id == op))
    by_origin = Enum.find(rows, &(&1.origin_key == origin))

    by_device =
      is_binary(device) and
        Enum.find(
          rows,
          &(&1.subject_id == subject and &1.device_id == device and &1.client_seq == seq)
        )

    idempotency_decision(by_key, by_origin, by_device || nil, payload_hash)
  end

  defp idempotency_decision(nil, nil, nil, _hash), do: :none

  defp idempotency_decision(nil, nil, _by_device, _hash),
    do: Validate.refuse(:client_seq_conflict, %{})

  defp idempotency_decision(nil, _by_origin, _by_device, _hash),
    do: Validate.refuse(:idempotency_key_reuse, %{})

  defp idempotency_decision(by_key, by_origin, _by_device, hash) do
    cond do
      by_origin != nil and by_origin.id != by_key.id ->
        Validate.refuse(:idempotency_key_reuse, %{})

      by_key.payload_hash != hash ->
        Validate.refuse(:idempotency_key_reuse, %{})

      true ->
        {:duplicate, duplicate_of(by_key)}
    end
  end

  defp duplicate_of(row) do
    %{
      entry_id: row.id,
      ledger_id: row.ledger_id,
      posting_seq: row.posting_seq,
      chain_hash: row.chain_hash,
      duplicate: true
    }
  end

  @doc false
  # Maps a unique violation of the entry insert to a refusal; :unknown for any other error.
  @spec unique_violation_refusal(Exception.t()) :: {:error, refusal()} | :unknown
  def unique_violation_refusal(%Postgrex.Error{
        postgres: %{code: :unique_violation, constraint: constraint}
      }) do
    case constraint do
      c when c in ["ledger_entry_subject_op_key", "ledger_entry_origin_key_key"] ->
        Validate.refuse(:idempotency_key_reuse, %{})

      "ledger_entry_device_seq_unique_index" ->
        Validate.refuse(:client_seq_conflict, %{})

      _other ->
        :unknown
    end
  end

  def unique_violation_refusal(_other), do: :unknown

  # The one rescue: the unique index of the reversal target (decision 0073 A5) is the backstop of
  # the step 8 re-read. A violation on it is `posting_already_reversed`; any other error is
  # re-raised. The caller rolls the whole transaction back on every refusal, so a refusal after
  # the counter update leaves nothing. No message, constraint name or detail is copied out.
  defp insert_entry(prefix, entry_row) do
    Repo.insert_all("ledger_entry", [entry_row], prefix: prefix)
    :ok
  rescue
    e in Postgrex.Error ->
      case reversal_unique_violation_refusal(e, entry_row) do
        :unknown -> reraise e, __STACKTRACE__
        refusal -> refusal
      end
  end

  @doc false
  # Maps a unique violation on the reversal index of `entry_row` to `posting_already_reversed`;
  # :unknown for anything else. Under a partitioned parent the index name may be generated, so the
  # detail text is matched as well.
  @spec reversal_unique_violation_refusal(Exception.t(), map()) :: {:error, refusal()} | :unknown
  def reversal_unique_violation_refusal(
        %Postgrex.Error{postgres: %{code: :unique_violation} = pg},
        %{reverses_entry_id: target} = _row
      )
      when is_binary(target) do
    constraint = to_string(Map.get(pg, :constraint))
    detail = to_string(Map.get(pg, :detail))

    if String.starts_with?(constraint, "ledger_entry_reverses_unique_index") or
         String.contains?(detail, "reverses_entry_id") do
      Validate.refuse(:posting_already_reversed, %{entry_id: Ecto.UUID.load!(target)})
    else
      :unknown
    end
  end

  def reversal_unique_violation_refusal(_error, _row), do: :unknown

  # -- capability shape ------------------------------------------------------------------------

  defp check_registration(%{slots: slots, causes: causes} = registration)
       when is_list(slots) and is_map(causes) and length(slots) in 1..8 do
    names = for %{name: name} <- slots, is_binary(name), do: name

    slots_ok? =
      length(names) == length(slots) and length(Enum.uniq(names)) == length(names) and
        Enum.all?(slots, &(&1[:format] in [:token, :uuid] and is_boolean(&1[:required])))

    units = Map.get(registration, :units)
    units_ok? = units == nil or (is_list(units) and Enum.all?(units, &is_binary/1))
    lateness = Map.get(registration, :max_event_lateness_hours)
    lateness_ok? = is_integer(lateness) and lateness in 1..8760

    with true <- slots_ok? and units_ok? and lateness_ok?,
         {:ok, bounds} <- check_bounds(Map.get(registration, :key_bounds, []), names) do
      {:ok, bounds}
    else
      _ -> {:error, {:ledger_contract, :invalid_registration}}
    end
  end

  defp check_registration(_registration), do: {:error, {:ledger_contract, :invalid_registration}}

  defp check_bounds(bounds, names) when is_list(bounds) do
    Enum.reduce_while(bounds, {:ok, []}, fn
      %{when_slot_nonempty: slot, max_on_hand: max}, {:ok, acc}
      when is_binary(slot) and is_binary(max) ->
        with true <- slot in names,
             {%Decimal{} = value, ""} <- Decimal.parse(max),
             true <- Decimal.gt?(value, 0) and Decimal.lt?(value, @limit),
             true <- Decimal.normalize(value).exp >= -9 do
          {:cont, {:ok, [{Enum.find_index(names, &(&1 == slot)), value} | acc]}}
        else
          _ -> {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
  end

  defp check_bounds(_bounds, _names), do: :error

  defp check_identity(cap) do
    %{subject_id: s, actor_id: a, origin_key: o} = cap

    with {:ok, subject} <- cast_uuid(s),
         {:ok, actor} <- cast_uuid(a),
         true <- is_binary(o) and byte_size(o) in 1..200 and String.valid?(o),
         false <- Regex.match?(@control, o) do
      {:ok, %{subject_id: subject, actor_id: actor}}
    else
      _ -> Validate.refuse(:invalid_posting, %{leg_no: nil, reason: :posting_shape})
    end
  end

  defp cast_uuid(value) when is_binary(value), do: Ecto.UUID.cast(value)
  defp cast_uuid(_value), do: :error

  # -- keys ------------------------------------------------------------------------------------

  # [%{key: [8 texts], legs: [leg], pin: Decimal | nil}] sorted by key (byte-wise on the texts)
  defp group_keys(legs, bounds) do
    groups =
      legs
      |> Enum.group_by(& &1.k)
      |> Enum.map(fn {key, key_legs} ->
        pins = for {index, max} <- bounds, Enum.at(key, index) not in [nil, ""], do: max
        %{key: key, legs: key_legs, pin: min_decimal(pins)}
      end)
      |> Enum.sort_by(& &1.key)

    case Enum.find_value(groups, &mixed_unit/1) do
      nil -> {:ok, groups}
      leg_no -> Validate.refuse(:unit_mismatch, %{leg_no: leg_no})
    end
  end

  defp mixed_unit(%{legs: [first | rest]}) do
    case Enum.find(rest, &(&1.unit_ref != first.unit_ref)) do
      nil -> nil
      leg -> leg.leg_no
    end
  end

  defp min_decimal([]), do: nil
  defp min_decimal(values), do: Enum.reduce(values, &if(Decimal.lt?(&1, &2), do: &1, else: &2))

  defp insert_missing_balances(prefix, ledger_id, groups) do
    for %{key: key, legs: [first | _], pin: pin} <- groups do
      row =
        key_columns(key)
        |> Map.merge(%{
          ledger_id: ledger_id,
          on_hand: Decimal.new(0),
          unit_ref: first.unit_ref,
          max_on_hand: pin,
          last_posting_seq: 0
        })

      Repo.insert_all("ledger_balance", [row], prefix: prefix, on_conflict: :nothing)
    end

    :ok
  end

  defp lock_balances(prefix, ledger_id, groups) do
    locked =
      for %{key: [k1, k2, k3, k4, k5, k6, k7, k8]} <- groups do
        query =
          from(b in "ledger_balance",
            where:
              b.ledger_id == ^ledger_id and b.k1 == ^k1 and b.k2 == ^k2 and b.k3 == ^k3 and
                b.k4 == ^k4 and b.k5 == ^k5 and b.k6 == ^k6 and b.k7 == ^k7 and b.k8 == ^k8,
            select: %{on_hand: b.on_hand, unit_ref: b.unit_ref, max_on_hand: b.max_on_hand},
            lock: "FOR UPDATE"
          )

        Repo.one!(query, prefix: prefix)
      end

    {:ok, locked}
  end

  defp key_columns(key),
    do: key |> Enum.with_index(1) |> Map.new(fn {text, i} -> {:"k#{i}", text} end)

  # -- guard -----------------------------------------------------------------------------------

  defp guard(groups, locked, slots, reversal?) do
    groups
    |> Enum.zip(locked)
    |> Enum.find_value(:ok, fn {group, row} ->
      refusal_for(group, row, length(slots), reversal?)
    end)
  end

  defp refusal_for(%{legs: legs}, row, slot_count, reversal?) do
    new_on_hand = Enum.reduce(legs, row.on_hand, &Decimal.add(&2, &1.quantity))

    cond do
      leg = Enum.find(legs, &(&1.unit_ref != row.unit_ref)) ->
        Validate.refuse(:unit_mismatch, %{leg_no: leg.leg_no})

      Decimal.lt?(new_on_hand, 0) and reversal? ->
        # nothing of the target's contents: leg numbers and a count only
        leg_nos = for leg <- legs, Decimal.lt?(leg.quantity, 0), do: leg.leg_no

        Validate.refuse(:insufficient_balance, %{
          leg_nos: Enum.sort(leg_nos),
          count: length(leg_nos)
        })

      Decimal.lt?(new_on_hand, 0) ->
        requested =
          for leg <- legs, Decimal.lt?(leg.quantity, 0) do
            %{
              leg_no: leg.leg_no,
              k: Enum.take(leg.k, slot_count),
              requested: leg.quantity |> Decimal.abs() |> Digest.quantity_text()
            }
          end

        Validate.refuse(:insufficient_balance, %{legs: requested})

      over_bound?(new_on_hand, row.max_on_hand) ->
        Validate.refuse(:balance_bound_exceeded, %{legs: Enum.map(legs, &%{leg_no: &1.leg_no})})

      true ->
        nil
    end
  end

  defp over_bound?(new_on_hand, max_on_hand) do
    Decimal.compare(new_on_hand, @limit) != :lt or
      (max_on_hand != nil and Decimal.gt?(new_on_hand, max_on_hand))
  end

  # -- write -----------------------------------------------------------------------------------

  # Under the counter lock, before any write: a refusal writes nothing.
  defp check_event_time(event_time, posting_time, registration),
    do: Validate.check_event_window(event_time, posting_time, registration)

  @doc false
  @spec write_posting(LockedPlan.t(), String.t()) ::
          {:ok, posted()} | {:error, refusal()} | {:error, {:ledger_contract, atom()}}
  def write_posting(%LockedPlan{prefix: prefix, postings: postings}, ledger_id) do
    case Map.fetch(postings, ledger_id) do
      :error -> {:error, {:ledger_contract, :not_in_plan}}
      {:ok, %{duplicate: posted}} when posted != nil -> {:ok, posted}
      {:ok, entry} -> write_entry(prefix, entry)
    end
  end

  # Writes one locked posting. The counter update carries the locked `last_seq`: a second call
  # for the same ledger id finds it moved and writes nothing more.
  defp write_entry(prefix, entry) do
    %{cap: cap, ids: ids, posting: posting, groups: groups, locked: locked} = entry
    %{payload_hash: payload_hash, counter: counter} = entry
    %{event_time: event_time, posting_time: posting_time} = entry
    ledger_id = posting.ledger_id

    seq = counter.seq + 1
    entry_id = Ecto.UUID.generate()
    client_op_id = cap.command.client_op_id

    header = %{
      id: entry_id,
      ledger_id: ledger_id,
      posting_seq: seq,
      cause: posting.cause,
      sign_rule: posting.sign_rule,
      reverses_entry_id: posting.reverses_entry_id,
      reason_code: posting.reason_code,
      document_type: posting.document_type,
      document_id: posting.document_id,
      related_document_id: posting.related_document_id,
      actor_id: ids.actor_id,
      subject_id: ids.subject_id,
      correlation_id: posting.correlation_id || client_op_id,
      event_time: event_time,
      posting_time: posting_time,
      device_id: posting.device_id,
      client_seq: posting.client_seq,
      client_event_time: posting.client_event_time,
      client_op_id: client_op_id,
      origin_key: cap.origin_key,
      payload_hash: payload_hash,
      registration_hash: Digest.registration_hash(cap.registration),
      scope_ref: posting.scope_ref,
      leg_count: length(posting.legs)
    }

    leg_maps = Enum.map(posting.legs, &leg_map/1)
    entry_digest = Digest.entry_digest(header, leg_maps)
    chain_hash = Digest.chain_hash(counter.hash, entry_digest)

    {updated, _} =
      from(c in "ledger_counter", where: c.ledger_id == ^ledger_id and c.last_seq == ^counter.seq)
      |> Repo.update_all([set: [last_seq: seq, last_chain_hash: chain_hash]], prefix: prefix)

    if updated == 0 do
      {:error, {:ledger_contract, :plan_already_written}}
    else
      entry_row =
        header
        |> Map.merge(%{
          id: Ecto.UUID.dump!(entry_id),
          actor_id: Ecto.UUID.dump!(ids.actor_id),
          subject_id: Ecto.UUID.dump!(ids.subject_id),
          reverses_entry_id:
            posting.reverses_entry_id && Ecto.UUID.dump!(posting.reverses_entry_id),
          entry_digest: entry_digest,
          chain_hash: chain_hash
        })

      with :ok <- insert_entry(prefix, entry_row) do
        write_legs_and_balances(
          {prefix, ledger_id, seq, {event_time, posting_time}},
          {entry_id, chain_hash},
          {posting, groups, locked, leg_maps}
        )
      end
    end
  end

  defp write_legs_and_balances(
         {prefix, ledger_id, seq, {event_time, posting_time}},
         {entry_id, chain_hash},
         {posting, groups, locked, leg_maps}
       ) do
    leg_rows =
      for {leg, map} <- Enum.zip(posting.legs, leg_maps) do
        key_columns(leg.k)
        |> Map.merge(%{
          id: Ecto.UUID.dump!(Ecto.UUID.generate()),
          entry_id: Ecto.UUID.dump!(entry_id),
          ledger_id: ledger_id,
          posting_seq: seq,
          event_time: event_time,
          leg_no: leg.leg_no,
          quantity: leg.quantity,
          unit_ref: leg.unit_ref,
          attrs: leg.attrs,
          document_line_id: leg.document_line_id,
          quantity_scale: map.quantity_scale
        })
      end

    Repo.insert_all("ledger_leg", leg_rows, prefix: prefix)

    for {%{key: [k1, k2, k3, k4, k5, k6, k7, k8], legs: legs}, row} <- Enum.zip(groups, locked) do
      new_on_hand = Enum.reduce(legs, row.on_hand, &Decimal.add(&2, &1.quantity))

      from(b in "ledger_balance",
        where:
          b.ledger_id == ^ledger_id and b.k1 == ^k1 and b.k2 == ^k2 and b.k3 == ^k3 and
            b.k4 == ^k4 and b.k5 == ^k5 and b.k6 == ^k6 and b.k7 == ^k7 and b.k8 == ^k8
      )
      |> Repo.update_all(
        [set: [on_hand: new_on_hand, last_posting_seq: seq, updated_at: posting_time]],
        prefix: prefix
      )
    end

    {:ok,
     %{
       entry_id: entry_id,
       ledger_id: ledger_id,
       posting_seq: seq,
       chain_hash: chain_hash,
       duplicate: false
     }}
  end

  defp leg_map(leg) do
    scale = max(0, -Decimal.normalize(leg.quantity).exp)

    leg.k
    |> key_columns()
    |> Map.merge(%{
      leg_no: leg.leg_no,
      quantity: leg.quantity,
      unit_ref: leg.unit_ref,
      attrs: leg.attrs,
      document_line_id: leg.document_line_id,
      quantity_scale: scale
    })
  end

  # ---- read side (REQ-637 / GH #3559 part B) ---------------------------------------------------

  @doc """
  The one place the registration of a ledger id comes from (REQ-637 criterion 3, open question 1):
  `Application.get_env(:letflow, :ledger_registry, %{})`, a map `ledger_id => %{name, registration,
  read_permission, reconcile_permission}`. The default is empty, so `authorize/3` answers `:error`
  for every ledger id in production until slice L3 points this function at the manifest catalog.
  """
  @spec registration_for(term()) :: {:ok, map()} | :error
  def registration_for(ledger_id) when is_binary(ledger_id) do
    case Application.get_env(:letflow, :ledger_registry, %{}) do
      %{} = registry -> Map.fetch(registry, ledger_id)
      _other -> :error
    end
  end

  def registration_for(_ledger_id), do: :error

  @doc """
  The only way to get a `Letflow.Ledger.Authorized` value. The principal is built here from the
  conn (never supplied by the caller); the answer is the bare atom `:error` for every failure
  (INV-5): unknown ledger id, no principal, any credential other than an interactive one, a role
  without the registration's permission for `purpose`, a scoped (not tenant-wide) grant, grants
  that cannot be loaded, a node-expansion failure (`ScopeSetError`, fail closed, INV-8). No log
  line and no telemetry carries the ledger id or the grants. The prefix is the plug's own.
  """
  @spec authorize(Plug.Conn.t(), String.t(), :read | :reconcile) :: {:ok, Authorized.t()} | :error
  def authorize(%Plug.Conn{} = conn, ledger_id, purpose)
      when is_binary(ledger_id) and purpose in [:read, :reconcile] do
    with {:ok, entry} <- registration_for(ledger_id),
         {:ok, permission} <- permission_for(entry, purpose),
         {:ok, _conn, %Principal{kind: :user} = principal} <- Scope.principal_from_conn(conn),
         true <- Enum.any?(principal.roles, &Authorization.role_allows?(&1, permission)),
         {:ok, :all} <- tenant_wide_set(principal, permission),
         {:ok, names} <- slot_names(entry) do
      {:ok,
       %Authorized{
         prefix: principal.prefix,
         ledger_id: ledger_id,
         registration_name: entry.name,
         purpose: purpose,
         slot_names: names
       }}
    else
      _refused -> :error
    end
  end

  def authorize(_conn, _ledger_id, _purpose), do: :error

  defp permission_for(entry, purpose) do
    key = if purpose == :read, do: :read_permission, else: :reconcile_permission

    with %{^key => permission} when is_atom(permission) <- entry,
         true <- permission in Authorization.permissions() do
      {:ok, permission}
    else
      _no_permission -> :error
    end
  end

  # REQ-637: ScopeSetError, fail closed, is the one rescue of the ledger files.
  defp tenant_wide_set(principal, permission) do
    Scope.allowed_set(principal, permission)
  rescue
    Scope.ScopeSetError -> :error
  end

  defp slot_names(%{name: name, registration: %{slots: slots}})
       when is_binary(name) and is_list(slots) and length(slots) <= 8 do
    names = for %{name: slot} <- slots, is_binary(slot), do: slot
    if length(names) == length(slots), do: {:ok, names}, else: :error
  end

  defp slot_names(_entry), do: :error

  @doc """
  REQ-637 criteria 4 and 5: the balance report of an authorized ledger id on one of two bases,
  `{:posting_seq, n | :latest}` or `{:event_time, t, n | :latest}`. See `Letflow.Ledger.Read`.
  Returns `{:ok, report}`, `{:error, :cutoff_in_future}` or `{:error, :invalid_filter}`.
  """
  @spec balances(Authorized.t(), tuple(), map(), map()) ::
          {:ok, map()} | {:error, :cutoff_in_future | :invalid_filter}
  defdelegate balances(authorized, basis, filters, page), to: Letflow.Ledger.Read

  @doc """
  REQ-637 criterion 6: the entries of an authorized ledger id in ascending `posting_seq` order.
  Returns `{:ok, %{rows: [map], next_cursor: term | nil}}` or `{:error, :invalid_filter}`.
  """
  @spec entries(Authorized.t(), map(), map()) ::
          {:ok, %{rows: [map()], next_cursor: term() | nil}} | {:error, :invalid_filter}
  defdelegate entries(authorized, filters, page), to: Letflow.Ledger.Read
end
