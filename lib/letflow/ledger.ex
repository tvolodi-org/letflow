defmodule Letflow.Ledger do
  @moduledoc """
  REQ-621 / GH #3469 part A (slice L2a of the WMS stock ledger, GH #2657): the posting primitive
  and nothing around it. `post/1` takes one opaque `Letflow.Ledger.Capability` and, inside the
  caller's open transaction, validates the declarative posting, locks the balance rows in
  ascending key order, runs the no-negative / bound / unit guard, and only then takes the counter
  row and writes the entry, its legs and the balances (note gh2657 sections 6, 7.1, 7.3).

  ## Order of work (why it cannot deadlock)

  1. a non-capability is refused before any query; a call outside a transaction raises;
  2. validation and the sign rule (pure, `Letflow.Ledger.Validate`): no lock is taken for a
     malformed or unbalanced posting;
  3. the distinct balance keys, sorted byte-wise on the 8 slot texts; missing rows are inserted
     in that order (`ON CONFLICT DO NOTHING`, with the first-touch unit pin and the minimum
     `max_on_hand` of the matching key bounds), then each row is locked `FOR UPDATE`, one key at
     a time, in the same order;
  4. the guard per key, in key order (unit, then `insufficient_balance`, then
     `balance_bound_exceeded`), reading the pin from the LOCKED row, never from the capability;
  5. as the last ledger lock, the counter row of the ledger id; sequence, digest and chain hash
     are computed from the locked values; the entry, the legs and the balances are written.

  Every statement carries the capability's prefix; every value is a bound parameter. Lock
  timeouts, deadlocks and statement timeouts are not rescued: they leave the transaction.

  ## Not in this part (REQ-621 parts B and C, L2b, L3)

  Idempotency lookups, offline fields, event time and its lateness cap, the isolation assertion
  and reversal. Until part B lands a repeated `(subject_id, client_op_id)` or `origin_key` raises
  a unique violation inside the caller's transaction. No live caller exists before slice L3.

  ## Pilot gate (note 17, quoted)

  The stock module is NOT enabled for a customer tenant until L6 AND L7 are done, and
  serial-tracked goods stay out of the pilot until OQ-23 (serial uniqueness across locations) is
  resolved. Reason: without L7 a typo in an item or location id creates a NEW balance key and the
  first-touch unit_ref and max_on_hand pin on it is permanent; without L6 a scoped storekeeper
  cannot post; without OQ-23 the same serial can be active at two locations (key_bounds are per
  balance key including location). This entry delivers the primitive only and enables nothing.

  ## Contract atoms

  `{:ledger_contract, :invalid_capability}` (not a capability, or a malformed prefix) and
  `{:ledger_contract, :invalid_registration}` (the registration data is not of the expected
  shape: an extra atom beyond note 12.2, chosen here as the fail-closed backstop for the rule
  that L3 will enforce at build time).
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Ledger.Capability
  alias Letflow.Ledger.Digest
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

  @doc false
  @spec post(Capability.t()) ::
          {:ok, posted()} | {:error, refusal()} | {:error, {:ledger_contract, atom()}}
  def post(%Capability{prefix: prefix} = cap) do
    if is_binary(prefix) and Regex.match?(@prefix_form, prefix) do
      unless Repo.in_transaction?() do
        raise ArgumentError, "Letflow.Ledger.post/1 requires an open transaction"
      end

      post_in_transaction(cap)
    else
      {:error, {:ledger_contract, :invalid_capability}}
    end
  end

  def post(_not_a_capability), do: {:error, {:ledger_contract, :invalid_capability}}

  defp post_in_transaction(cap) do
    with {:ok, bounds} <- check_registration(cap.registration),
         {:ok, ids} <- check_identity(cap),
         {:ok, posting} <- Validate.posting(cap.posting, cap.command, cap.registration),
         {:ok, groups} <- group_keys(posting.legs, bounds),
         :ok <- insert_missing_balances(cap.prefix, posting.ledger_id, groups),
         {:ok, locked} <- lock_balances(cap.prefix, posting.ledger_id, groups),
         :ok <- guard(groups, locked, cap.registration.slots) do
      write(cap, ids, posting, groups, locked)
    end
  end

  # -- capability shape ------------------------------------------------------------------------

  defp check_registration(%{slots: slots, causes: causes} = registration)
       when is_list(slots) and is_map(causes) and length(slots) in 1..8 do
    names = for %{name: name} <- slots, is_binary(name), do: name

    slots_ok? =
      length(names) == length(slots) and length(Enum.uniq(names)) == length(names) and
        Enum.all?(slots, &(&1[:format] in [:token, :uuid] and is_boolean(&1[:required])))

    units = Map.get(registration, :units)
    units_ok? = units == nil or (is_list(units) and Enum.all?(units, &is_binary/1))

    with true <- slots_ok? and units_ok?,
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

  defp check_identity(%Capability{subject_id: s, actor_id: a, origin_key: o}) do
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

  defp guard(groups, locked, slots) do
    groups
    |> Enum.zip(locked)
    |> Enum.find_value(:ok, fn {group, row} -> refusal_for(group, row, length(slots)) end)
  end

  defp refusal_for(%{legs: legs}, row, slot_count) do
    new_on_hand = Enum.reduce(legs, row.on_hand, &Decimal.add(&2, &1.quantity))

    cond do
      leg = Enum.find(legs, &(&1.unit_ref != row.unit_ref)) ->
        Validate.refuse(:unit_mismatch, %{leg_no: leg.leg_no})

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

  defp write(cap, ids, posting, groups, locked) do
    prefix = cap.prefix
    ledger_id = posting.ledger_id

    Repo.insert_all(
      "ledger_counter",
      [%{ledger_id: ledger_id, last_seq: 0, last_chain_hash: ""}],
      prefix: prefix,
      on_conflict: :nothing
    )

    counter =
      from(c in "ledger_counter",
        where: c.ledger_id == ^ledger_id,
        select: %{seq: c.last_seq, hash: c.last_chain_hash},
        lock: "FOR UPDATE"
      )
      |> Repo.one!(prefix: prefix)

    %{rows: [[posting_time]]} = Repo.query!("SELECT clock_timestamp()")

    seq = counter.seq + 1
    entry_id = Ecto.UUID.generate()
    client_op_id = cap.command.client_op_id

    header = %{
      id: entry_id,
      ledger_id: ledger_id,
      posting_seq: seq,
      cause: posting.cause,
      sign_rule: posting.sign_rule,
      reason_code: posting.reason_code,
      document_type: posting.document_type,
      document_id: posting.document_id,
      related_document_id: posting.related_document_id,
      actor_id: ids.actor_id,
      subject_id: ids.subject_id,
      correlation_id: posting.correlation_id || client_op_id,
      event_time: posting_time,
      posting_time: posting_time,
      client_op_id: client_op_id,
      origin_key: cap.origin_key,
      payload_hash: Digest.payload_hash(cap.command, ids.subject_id),
      registration_hash: Digest.registration_hash(cap.registration),
      scope_ref: posting.scope_ref,
      leg_count: length(posting.legs)
    }

    leg_maps = Enum.map(posting.legs, &leg_map/1)
    entry_digest = Digest.entry_digest(header, leg_maps)
    chain_hash = Digest.chain_hash(counter.hash, entry_digest)

    from(c in "ledger_counter", where: c.ledger_id == ^ledger_id)
    |> Repo.update_all([set: [last_seq: seq, last_chain_hash: chain_hash]], prefix: prefix)

    entry_row =
      header
      |> Map.merge(%{
        id: Ecto.UUID.dump!(entry_id),
        actor_id: Ecto.UUID.dump!(ids.actor_id),
        subject_id: Ecto.UUID.dump!(ids.subject_id),
        entry_digest: entry_digest,
        chain_hash: chain_hash
      })

    Repo.insert_all("ledger_entry", [entry_row], prefix: prefix)

    leg_rows =
      for {leg, map} <- Enum.zip(posting.legs, leg_maps) do
        key_columns(leg.k)
        |> Map.merge(%{
          id: Ecto.UUID.dump!(Ecto.UUID.generate()),
          entry_id: Ecto.UUID.dump!(entry_id),
          ledger_id: ledger_id,
          posting_seq: seq,
          event_time: posting_time,
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
end
