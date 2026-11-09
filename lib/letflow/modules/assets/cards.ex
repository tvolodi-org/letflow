defmodule Letflow.Modules.Assets.Cards do
  @moduledoc """
  Write path of the `assets_card` record (GH #3892 / REQ-750, owner decisions D-097, D-098; spec
  `docs/assets/asset-register.md` sections 3, 5 rule 6, 6): `create_card/3`, `update_card/4` and
  `retire_card/3`. The generic record routes answer 403 `entity_type_managed` for the type, so this
  module is the only writer; it writes through `Letflow.Entities.Records` with the module authority,
  in the shape of `Letflow.Modules.Locations.Tree`.

  Rules, in this order, nothing written on a refusal: (update, retire) the card exists
  (`:card_not_found`: not a uuid, unknown, deleted, another type or another tenant, one answer) and is
  active (`:card_inactive`, also for a second retire); the key allow-list (`{:field_not_allowed, key}`;
  `active` is not a caller key); (import only) `org_unit_id`, when present, is a live, active
  `org_unit` (`:org_unit_not_active`); `valid_until` only for kind
  `intangible` (`:valid_until_not_allowed`, judged on the merged document); `currency`, when given,
  equals the tenant currency (`:currency_mismatch`; an empty one is dropped). Then the record errors of
  `Records` pass through: a duplicate `inventory_number` or external reference pair (per tenant,
  D-097), a missing required field or a decimal that is not strict text is
  `{:record_payload_invalid, violations}`. Money and depreciation fields are stored as given, never
  calculated.

  The card has no location, quantity or responsible-person field: those rules belong to the
  commission document (REQ-751).

  Card locks (T-1490 / G3): after the first posted document that names the card, a changed
  `inventory_number` or `kind` is `{:error, :inventory_number_locked | :kind_locked}`
  (`Letflow.Modules.Assets.CardLocks`), judged under the card lock; the other fields stay editable.

  Lock: one transaction per update or retire, under an advisory lock per card, so a concurrent retire
  and update serialize and `card_inactive` is decided under the lock. Create takes no lock; the pack's
  unique constraint arbitrates two creates of one number.

  Audit (decision 0078 D8): each accepted write appends one entry through `Letflow.Audit.insert_entry/3`
  in the write's transaction, `resource_type` `assets_card`: `assets_card.created` (before nil),
  `assets_card.updated`, `assets_card.retired`. A refused call, a no-op and a replay write none; a
  database failure of the entry rolls the write back as `{:error, :audit_failed}`.

  `prefix` must come from the authenticated tenant on the server side, never from attrs or opts. `opts`
  (a map; a missing key raises `ArgumentError`): `:actor_id` (uuid), `:idempotency_key` (text);
  optional `:holder_source`, only `:import` (the xlsx import).

  Card holder (T-1488 / G1-a): `org_unit_id` is optional and is not a caller key: the route write
  path refuses it (`{:field_not_allowed, "org_unit_id"}`), so a new card has no org unit and its
  holder is read from the register. Only the import (`holder_source: :import`) may still carry it; it
  is then a live, active `org_unit`. A card with an empty unit is visible to tenant-wide principals
  only (the scope filter `column IN set` matches no value).
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Records
  alias Letflow.EventStore.IdempotencyRecord
  alias Letflow.Modules.Assets
  alias Letflow.Modules.Assets.CardLocks
  alias Letflow.Modules.Org
  alias Letflow.Modules.ReadApi
  alias Letflow.Repo

  @types ["assets_card"]
  @allowed ~w(inventory_number name kind acquisition_date currency acquisition_cost
              accumulated_depreciation book_value depreciation_as_of depreciation_method depreciation_rate valid_until
              external_ref_system external_ref_id)
  # The import is the one channel that may still carry the unit (D-097; G6 revisits it).
  @import_allowed ["org_unit_id" | @allowed]
  @required ~w(inventory_number name kind)

  @doc """
  Creates an active card in tenant schema `prefix` and returns the live record map (string keys,
  with `record_id`). `attrs` (string keys) are the card fields except `active`; a nil value of an
  optional field is dropped.
  """
  @spec create_card(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def create_card(prefix, attrs, opts)
      when is_binary(prefix) and is_map(attrs) and is_map(opts) do
    {actor_id, idem} = write_opts!(opts, "create_card/3")

    if replay?(prefix, idem) do
      with {:ok, record_id} <- create_doc(prefix, new_doc(attrs), actor_id, idem) do
        ReadApi.lookup(prefix, record_id, @types)
      end
    else
      Repo.transaction(fn ->
        fv = new_doc(attrs)

        with :ok <- check_keys(attrs, opts),
             :ok <- check_org_unit(prefix, attrs, opts),
             :ok <- check_rules(prefix, fv),
             {:ok, record_id} <- create_doc(prefix, fv, actor_id, idem),
             {:ok, card} <- ReadApi.lookup(prefix, record_id, @types),
             {:ok, after_fv} <- stored_fields(prefix, card),
             :ok <- audit(prefix, actor_id, "assets_card.created", record_id, nil, after_fv) do
          card
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @doc """
  Updates fields of card `card_id`. The body is merged onto the stored document (the whole document
  is validated); a nil value removes an optional field. A body that changes nothing is `{:ok, card}`
  with no write and no audit entry.
  """
  @spec update_card(String.t(), term(), map(), map()) :: {:ok, map()} | {:error, term()}
  def update_card(prefix, card_id, attrs, opts)
      when is_binary(prefix) and is_map(attrs) and is_map(opts) do
    {actor_id, idem} = write_opts!(opts, "update_card/4")

    change = fn fv -> merge(fv, attrs) end

    check = fn card, fv, merged ->
      with :ok <- check_keys(attrs, opts),
           :ok <- check_org_unit(prefix, attrs, opts),
           :ok <- CardLocks.check(prefix, card["record_id"], fv, merged),
           :ok <- check_rules(prefix, merged) do
        if merged == fv, do: :noop, else: :ok
      end
    end

    write_locked(prefix, card_id, actor_id, idem, change, check, "assets_card.updated")
  end

  @doc """
  Retires card `card_id` (`active` false). A retired card is `{:error, :card_inactive}`. There is no
  un-retire and no delete.
  """
  @spec retire_card(String.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def retire_card(prefix, card_id, opts) when is_binary(prefix) and is_map(opts) do
    {actor_id, idem} = write_opts!(opts, "retire_card/3")

    write_locked(
      prefix,
      card_id,
      actor_id,
      idem,
      fn fv -> Map.put(fv, "active", false) end,
      fn _card, _fv, _merged -> :ok end,
      "assets_card.retired"
    )
  end

  # ---------------------------------------------------------------------------------------------

  defp write_opts!(opts, fname) do
    actor_id = fetch_opt!(opts, :actor_id, fname)
    idem = fetch_opt!(opts, :idempotency_key, fname)

    unless is_binary(actor_id) and match?({:ok, _}, Ecto.UUID.cast(actor_id)),
      do: raise(ArgumentError, "#{fname} opts :actor_id must be a uuid")

    unless is_binary(idem),
      do: raise(ArgumentError, "#{fname} opts :idempotency_key must be text")

    {actor_id, idem}
  end

  defp fetch_opt!(opts, key, fname) do
    case Map.fetch(opts, key) do
      {:ok, v} when not is_nil(v) -> v
      _ -> raise ArgumentError, "#{fname} opts needs #{inspect(key)}"
    end
  end

  # Records detects a replay by failing its own multi and reading the original afterwards, which a
  # surrounding transaction cannot survive. A claimed key therefore skips lock and checks and goes to
  # Records alone, which answers the original or `:idempotency_key_reuse`.
  defp replay?(prefix, idem) do
    Repo.exists?(from(i in IdempotencyRecord, where: i.idempotency_key == ^idem), prefix: prefix)
  end

  defp write_locked(prefix, card_id, actor_id, idem, change, check, action) do
    if replay?(prefix, idem) do
      with {:ok, card} <- find_card(prefix, card_id),
           {:ok, fv} <- stored_fields(prefix, card),
           {:ok, _} <- update_doc(prefix, card["record_id"], change.(fv), actor_id, idem) do
        ReadApi.lookup(prefix, card["record_id"], @types)
      end
    else
      locked(prefix, card_id, actor_id, idem, change, check, action)
    end
  end

  defp locked(prefix, card_id, actor_id, idem, change, check, action) do
    Repo.transaction(fn ->
      with {:ok, card} <- find_card(prefix, card_id),
           :ok <- lock!(prefix, card["record_id"]),
           {:ok, card} <- find_card(prefix, card["record_id"]),
           :ok <- check_active(card),
           {:ok, fv} <- stored_fields(prefix, card),
           merged = change.(fv),
           {:ok, card} <-
             apply_change(
               prefix,
               card,
               fv,
               merged,
               check.(card, fv, merged),
               actor_id,
               idem,
               action
             ) do
        card
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp apply_change(_prefix, card, _fv, _merged, :noop, _actor, _idem, _action), do: {:ok, card}
  defp apply_change(_prefix, _card, _fv, _merged, {:error, _} = err, _a, _i, _action), do: err

  defp apply_change(prefix, card, before_fv, merged, :ok, actor_id, idem, action) do
    with {:ok, _} <- update_doc(prefix, card["record_id"], merged, actor_id, idem),
         {:ok, updated} <- ReadApi.lookup(prefix, card["record_id"], @types),
         {:ok, after_fv} <- stored_fields(prefix, updated),
         :ok <- audit(prefix, actor_id, action, card["record_id"], before_fv, after_fv) do
      {:ok, updated}
    end
  end

  @doc false
  # One transaction-scoped advisory lock per card, key bound as a parameter (INV-7).
  @spec lock!(String.t(), String.t()) :: :ok
  def lock!(prefix, record_id) when is_binary(prefix) and is_binary(record_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      prefix <> ":assets_card:" <> record_id
    ])

    :ok
  end

  defp find_card(prefix, card_id) do
    case ReadApi.lookup(prefix, card_id, @types) do
      {:ok, card} -> {:ok, card}
      {:error, :not_found} -> {:error, :card_not_found}
    end
  end

  defp check_active(%{"active" => true}), do: :ok
  defp check_active(_card), do: {:error, :card_inactive}

  defp check_keys(attrs, opts) do
    allowed = if import?(opts), do: @import_allowed, else: @allowed

    case attrs |> Map.keys() |> Enum.reject(&(&1 in allowed)) |> Enum.sort() do
      [] -> :ok
      [key | _] -> {:error, {:field_not_allowed, key}}
    end
  end

  defp import?(opts), do: Map.get(opts, :holder_source) == :import

  # Only the import can carry a unit; a present unit must be live and active.
  defp check_org_unit(prefix, attrs, opts) do
    if import?(opts) and not blank?(Map.get(attrs, "org_unit_id")) do
      if org_unit_active?(prefix, attrs["org_unit_id"]),
        do: :ok,
        else: {:error, :org_unit_not_active}
    else
      :ok
    end
  end

  defp org_unit_active?(prefix, id) when is_binary(id) do
    match?({:ok, %{"entity_type" => "org_unit"}}, Org.lookup(prefix, id)) and
      Org.active?(prefix, id)
  end

  defp org_unit_active?(_prefix, _id), do: false

  defp check_rules(prefix, fv) do
    cond do
      Map.has_key?(fv, "valid_until") and fv["kind"] != "intangible" ->
        {:error, :valid_until_not_allowed}

      Map.has_key?(fv, "currency") and fv["currency"] != Assets.currency(prefix) ->
        {:error, :currency_mismatch}

      true ->
        :ok
    end
  end

  defp new_doc(attrs) do
    attrs
    |> Enum.reject(fn {k, v} -> k not in @required and blank?(v) end)
    |> Map.new()
    |> Map.put("active", true)
  end

  defp merge(fv, attrs) do
    Enum.reduce(attrs, fv, fn {k, v}, acc ->
      if k not in @required and blank?(v), do: Map.delete(acc, k), else: Map.put(acc, k, v)
    end)
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  # The stored document without the read-map extras, and without keys the active definition no
  # longer declares (Records validates the whole document with additionalProperties false).
  defp stored_fields(prefix, card) do
    fv = Map.drop(card, ["record_id", "entity_type"])

    case Letflow.Entities.Definitions.get_active_definition_by_name("assets_card", prefix) do
      {:ok, %{definition_json: %{"fields" => fields}}} when is_list(fields) ->
        names = for %{"name" => n} <- fields, do: n
        {:ok, Map.take(fv, names)}

      _ ->
        {:ok, fv}
    end
  end

  defp create_doc(prefix, fv, actor_id, idem) do
    attrs = %{
      entity_type: "assets_card",
      field_values: fv,
      actor_id: actor_id,
      idempotency_key: idem
    }

    # scope-all: SEC-518-R1 (assets module, own-record system path; the caller is checked tenant-wide by Assets.Access)
    case Records.create_record(attrs, prefix, ManagedTypes.owner_for!(Letflow.Modules.Assets)) do
      {:ok, %{record: record}} -> {:ok, record.record_id}
      {:error, _} = err -> err
    end
  end

  defp update_doc(prefix, record_id, fv, actor_id, idem) do
    attrs = %{
      entity_type: "assets_card",
      record_id: record_id,
      field_values: fv,
      actor_id: actor_id,
      idempotency_key: idem
    }

    # scope-all: SEC-518-R1 (assets module, own-record system path; the caller is checked tenant-wide by Assets.Access)
    case Records.update_record(attrs, prefix, ManagedTypes.owner_for!(Letflow.Modules.Assets)) do
      {:ok, %{record: record}} -> {:ok, record.record_id}
      {:error, _} = err -> err
    end
  end

  # INV-8: Audit raises on a database failure; the transaction is already aborted then, so the
  # rescue only turns the raise into a refusal and runs no further query.
  defp audit(prefix, actor_id, action, record_id, before, after_state) do
    entry = %{
      actor_id: actor_id,
      action: action,
      resource_type: "assets_card",
      resource_id: record_id,
      before_state: before,
      after_state: after_state
    }

    case Audit.insert_entry(Repo, entry, prefix) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :audit_failed}
    end
  rescue
    _ -> {:error, :audit_failed}
  end
end
