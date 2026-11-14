defmodule Letflow.Modules.Assets.CountSheet do
  @moduledoc """
  REQ-817 / GH #4374 (asset count slice K2, owner decision D-128, spec `docs/assets/asset-count.md`
  sections 3 and 8): the count SHEET of an asset count order. A copy of the relevant parts of
  `Letflow.Modules.Stock.CountSheet` and `CountDifferences.mark_sheet_signed/4`, applied to the ledger
  `assets` (module `assets` does not call `stock`, boundary Rule 4).

    * `open/3`: the chair opens an `ordered` count inside its planned period. In one transaction:
      the order lock, `Ledger.hold_exclusive!/2`, the cut-off (server time, taken after the hold),
      the book read at `{:event_time, cut_off, N}` with `Ledger.balances/4`, one line per balance
      with a positive quantity whose card kind is in the order's kinds and whose location is under a
      root of the order (a key with no location, an intangible, is kept). Assets has no
      `posting_guard`, so the hold serialises nothing today; K5's freeze is checked at document issue
      (`CountFreeze`), a freeze order takes the asset issue lock between the order lock and the hold.
    * `record_line/5`: a commission member types what was found on a line (replace semantics);
      `add_surplus_line/4` adds a line the book does not know; every input appends one entry to the
      append-only log.
    * `close/3`: the chair closes a `counting` count when every line is counted; the document
      `assets_count.sheet` is issued with the line views as content; the order becomes `counted`.
    * `mark_sheet_signed/4`: the chair records that the exact set of required signers signed the
      printout (paper acknowledged by the chair, the system does not verify it); `sheet_signed`.
    * `lines/4`, `entries/4`, `sheet_document/3`: reads.

  Every write is one transaction whose FIRST statement is `Counts.lock_order!/2` (K1's per-order
  advisory lock, a bound parameter, INV-7); then the ledger hold (open only), then Records and
  Documents locks. A refusal is an atom (or `{:field_invalid | :field_not_allowed, key}`) and stores
  nothing. Audit (`assets_count.opened|entry_recorded|closed|sheet_signed`) carries ids, status and
  line number only. `Audit` raises on a database failure (INV-8): the raise becomes
  `{:error, :audit_failed}` and the transaction rolls back.

  Narrowing of the requirement text: a counted quantity of a low-value line is a WHOLE number, not any
  decimal, because the asset ledger policy refuses fractional quantities (a fractional count could
  never post in K4). Quantities and card money values are stored as text, exactly as the card holds
  them. A sheet is capped at 2000 lines (`count_too_large`). An order that asks for `freeze_locations`
  freezes its scope from the cut-off (`CountFreeze`, K5). Scanner input (K3),
  differences and result (K4) are later slices.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit
  alias Letflow.Documents
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.Ledger
  alias Letflow.Modules.Assets.CountFreeze
  alias Letflow.Modules.Assets.Counts
  alias Letflow.Modules.Assets.Settings
  alias Letflow.Modules.Assets.Documents.Posting
  alias Letflow.Modules.Assets.Views
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Locations.Tree
  alias Letflow.Modules.Org
  alias Letflow.Modules.ReadApi
  alias Letflow.Repo

  @kept ["record_id", "entity_type"]
  @max_lines 2_000
  @balance_page 200
  @max_description 500
  @max_signers 500
  @whole ~r/\A(0|[1-9][0-9]{0,14})\z/
  @conditions ~w(in_use not_in_use damaged)
  @input_keys ~w(found counted_quantity observed_location_id observed_material_responsible_id observed_actual_user_id condition)
  @surplus_keys ~w(asset_id description counted_quantity observed_location_id observed_material_responsible_id observed_actual_user_id condition)
  @read_keys ~w(limit cursor)
  @value_keys ~w(counted_quantity observed_location_id observed_material_responsible_id observed_actual_user_id condition)
  @card_keys ~w(inventory_number name acquisition_date acquisition_cost book_value)

  # --- open -------------------------------------------------------------------------------------

  @doc """
  Opens the count at the cut-off. `opts` is `%{actor_id, authorized}`, `authorized` being the
  `Letflow.Ledger.Authorized` the router got from `Ledger.authorize(conn, "assets", :read)` (or `nil`).
  """
  @spec open(String.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def open(prefix, id, opts) when is_binary(prefix) and is_map(opts) do
    actor = actor!(opts)

    with {:ok, header} <- fetch(prefix, id),
         {:ok, authorized} <- full_reader(prefix, Map.get(opts, :authorized)),
         :ok <- chair(prefix, header, actor),
         :ok <- status(header, "ordered"),
         :ok <- due(header, DateTime.utc_now()) do
      Repo.transaction(fn ->
        Counts.lock_order!(prefix, header["record_id"])
        # A freeze order also takes the asset issue lock: an issue either committed before the
        # cut-off or waits and then sees the freeze (K5). Order lock, issue lock, ledger hold.
        if header["freeze_locations"] == true,
          do: Letflow.Modules.Assets.Documents.lock_issue!(prefix)

        Ledger.hold_exclusive!(prefix, "assets")
        now = DateTime.truncate(DateTime.utc_now(), :microsecond)

        with {:ok, fresh} <- fetch(prefix, header["record_id"]),
             :ok <- status(fresh, "ordered"),
             :ok <- due(fresh, now),
             {:ok, n, rows} <- read_book(authorized, fresh["org_unit_id"], now),
             {:ok, lines} <- build_lines(prefix, fresh, rows),
             :ok <- create_all(prefix, lines, actor),
             {:ok, freeze} <- freeze_fields(prefix, fresh, now),
             fv =
               fresh
               |> Map.drop(@kept)
               |> Map.merge(freeze)
               |> Map.merge(%{
                 "status" => "counting",
                 "cut_off_at" => DateTime.to_iso8601(now),
                 "cutoff_seq" => n,
                 "opened_by" => actor
               }),
             {:ok, _} <-
               update_record(prefix, fresh["record_id"], "assets_count_order", fv, actor),
             :ok <- audit(prefix, actor, "opened", fresh["record_id"], "ordered", "counting", nil) do
          :ok
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> view_after(prefix, header["record_id"], opts)
    end
  end

  defp full_reader(prefix, %{scope: :all, prefix: prefix} = authorized), do: {:ok, authorized}
  defp full_reader(_prefix, _other), do: {:error, :not_found}

  defp freeze_fields(prefix, %{"freeze_locations" => true} = order, cut_off) do
    CountFreeze.open_fields(
      prefix,
      scope_roots(prefix, order["record_id"]),
      cut_off,
      Settings.count_freeze_limit_minutes(prefix)
    )
  end

  defp freeze_fields(_prefix, _order, _cut_off), do: {:ok, %{}}

  defp due(header, now) do
    with {:ok, a, _} <- DateTime.from_iso8601(to_string(header["planned_start"])),
         {:ok, b, _} <- DateTime.from_iso8601(to_string(header["planned_end"])),
         true <- DateTime.compare(a, now) != :gt and DateTime.compare(now, b) != :gt do
      :ok
    else
      _ -> {:error, :count_not_due}
    end
  end

  # One chain of balance pages for the unit. The first page is `:latest` and fixes N; every later page
  # is read at `{:event_time, at, N}`, so the whole sheet is one consistent picture.
  defp read_book(authorized, unit, at), do: read_page(authorized, unit, at, nil, nil, [])

  defp read_page(authorized, unit, at, n, cursor, acc) do
    basis = {:event_time, at, n || :latest}
    page = if cursor, do: %{limit: @balance_page, cursor: cursor}, else: %{limit: @balance_page}

    case Ledger.balances(authorized, basis, %{"org_unit" => unit}, page) do
      {:ok, %{cutoff_seq: seq, rows: rows, next_cursor: next}} ->
        n = n || seq
        acc = Enum.reduce(rows, acc, &[&1 | &2])

        if next,
          do: read_page(authorized, unit, at, n, next, acc),
          else: {:ok, n, acc}

      {:error, _} ->
        {:error, :ledger_read_failed}
    end
  end

  defp build_lines(prefix, header, rows) do
    kinds = List.wrap(header["kinds"])
    roots = scope_roots(prefix, header["record_id"])
    subtree = if roots == [], do: nil, else: subtree(prefix, roots)

    lines =
      rows
      |> Enum.map(&Views.asset_balance/1)
      |> Enum.filter(&positive?(&1.quantity))
      |> Enum.flat_map(fn row ->
        with true <- in_scope?(row.location, subtree),
             {:ok, card} <- ReadApi.lookup(prefix, row.asset, ["assets_card"]),
             true <- card["kind"] in kinds do
          [{row, card}]
        else
          _ -> []
        end
      end)
      |> Enum.sort_by(fn {r, card} ->
        {r.location || "", to_string(card["inventory_number"]), r.asset, r.material_responsible,
         r.actual_user || ""}
      end)
      |> Enum.with_index(1)
      |> Enum.map(fn {{r, card}, no} -> book_line(header, r, card, no) end)

    if length(lines) > @max_lines, do: {:error, :count_too_large}, else: {:ok, lines}
  end

  defp positive?(text) do
    case Decimal.parse(to_string(text)) do
      {d, ""} -> Decimal.gt?(d, 0)
      _ -> false
    end
  end

  defp in_scope?(_location, nil), do: true
  defp in_scope?(nil, _subtree), do: true
  defp in_scope?(location, subtree), do: MapSet.member?(subtree, location)

  defp book_line(header, r, card, no) do
    base = %{
      "count_order_id" => header["record_id"],
      "line_no" => no,
      "kind" => "book",
      "org_unit_id" => header["org_unit_id"],
      "asset_id" => r.asset,
      "asset_kind" => card["kind"],
      "book_material_responsible_id" => r.material_responsible,
      "book_quantity" => whole_text(r.quantity)
    }

    base
    |> put_card(card)
    |> put_present("book_location_id", r.location)
    |> put_present("book_actual_user_id", r.actual_user)
  end

  defp put_card(map, card) do
    Enum.reduce(@card_keys, map, fn key, acc -> put_present(acc, key, text(card[key])) end)
  end

  defp whole_text(quantity) do
    {d, ""} = Decimal.parse(to_string(quantity))
    d |> Decimal.normalize() |> Decimal.to_string(:normal)
  end

  defp create_all(prefix, lines, actor) do
    Enum.reduce_while(lines, :ok, fn fv, :ok ->
      case create_record(prefix, "assets_count_line", fv, actor) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # --- typed input ------------------------------------------------------------------------------

  @doc "Records the input of a line (replace) and appends an `assets_count_entry`. Returns the line view."
  @spec record_line(String.t(), term(), term(), term(), map()) :: {:ok, map()} | {:error, term()}
  def record_line(prefix, id, line_no, input, opts) when is_binary(prefix) and is_map(opts) do
    actor = actor!(opts)

    with {:ok, header} <- fetch(prefix, id),
         {:ok, employee} <- commission_member(prefix, header, actor),
         :ok <- status(header, "counting"),
         {:ok, no} <- parse_line_no(line_no),
         {:ok, line} <- find_line(prefix, header["record_id"], no),
         {:ok, value} <- line_input(prefix, header, line, input) do
      Repo.transaction(fn ->
        Counts.lock_order!(prefix, header["record_id"])

        with {:ok, fresh} <- fetch(prefix, header["record_id"]),
             :ok <- status(fresh, "counting"),
             {:ok, current} <- find_line(prefix, fresh["record_id"], no),
             before = value_of(current),
             fv = current |> Map.drop(@kept ++ @value_keys) |> Map.merge(compact(value)),
             {:ok, _} <-
               update_record(prefix, current["record_id"], "assets_count_line", fv, actor),
             :ok <-
               append_entry(prefix, fresh, no, "recorded", before, value, employee, actor),
             :ok <-
               audit(
                 prefix,
                 actor,
                 "entry_recorded",
                 fresh["record_id"],
                 "counting",
                 "counting",
                 no
               ) do
          {:ok, stored} = find_line(prefix, fresh["record_id"], no)
          stored
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, stored} -> {:ok, line_view(stored)}
        error -> error
      end
    end
  end

  defp line_input(prefix, header, line, input) when is_map(input) do
    kind = counted_kind(line["asset_kind"])

    with :ok <- no_extra(input, @input_keys),
         {:ok, quantity} <- counted(input, kind, false),
         :ok <- observed_location_ok(prefix, header, input, line["asset_kind"]),
         {:ok, rest} <- observations(prefix, input) do
      {:ok, Map.put(rest, "counted_quantity", quantity)}
    end
  end

  defp line_input(_prefix, _header, _line, _input), do: {:error, {:field_invalid, "body"}}

  defp counted_kind(kind) when kind in ["fixed", "intangible"], do: :found
  defp counted_kind(_), do: :quantity

  # `found` for fixed and intangible lines (stored "1" or "0"), a whole number for the others.
  defp counted(input, :found, _positive) do
    cond do
      Map.has_key?(input, "counted_quantity") ->
        {:error, {:field_not_allowed, "counted_quantity"}}

      Map.get(input, "found") == true ->
        {:ok, "1"}

      Map.get(input, "found") == false ->
        {:ok, "0"}

      true ->
        {:error, {:field_invalid, "found"}}
    end
  end

  defp counted(input, :quantity, positive) do
    cond do
      Map.has_key?(input, "found") -> {:error, {:field_not_allowed, "found"}}
      true -> whole_quantity(Map.get(input, "counted_quantity"), positive)
    end
  end

  defp whole_quantity(v, positive) when is_binary(v) do
    if Regex.match?(@whole, v) and not (positive and v == "0"),
      do: {:ok, v},
      else: {:error, {:field_invalid, "counted_quantity"}}
  end

  defp whole_quantity(_v, _positive), do: {:error, {:field_invalid, "counted_quantity"}}

  # Optional observed location: not for an intangible, and inside the count's scope.
  defp observed_location_ok(prefix, header, input, asset_kind) do
    case Map.get(input, "observed_location_id") do
      nil ->
        :ok

      _ when asset_kind == "intangible" ->
        {:error, {:field_not_allowed, "observed_location_id"}}

      v ->
        with {:ok, loc} <- cast_uuid(v, "observed_location_id") do
          location_in_count(prefix, header, loc)
        end
    end
  end

  defp location_in_count(prefix, header, loc) do
    roots = scope_roots(prefix, header["record_id"])

    in_roots? = roots == [] or MapSet.member?(subtree(prefix, roots), loc)

    if in_roots? and Locations.linked?(prefix, header["org_unit_id"], loc),
      do: :ok,
      else: {:error, :location_not_in_count}
  end

  # The optional observed people and the condition; returns the value map without the quantity.
  defp observations(prefix, input) do
    with {:ok, loc} <- opt_uuid(input, "observed_location_id"),
         {:ok, resp} <- opt_employee(prefix, input, "observed_material_responsible_id"),
         {:ok, user} <- opt_employee(prefix, input, "observed_actual_user_id"),
         {:ok, condition} <- opt_condition(input) do
      {:ok,
       %{
         "observed_location_id" => loc,
         "observed_material_responsible_id" => resp,
         "observed_actual_user_id" => user,
         "condition" => condition
       }}
    end
  end

  defp opt_uuid(input, key) do
    case Map.get(input, key) do
      nil -> {:ok, nil}
      v -> cast_uuid(v, key)
    end
  end

  defp opt_employee(prefix, input, key) do
    with {:ok, id} <- opt_uuid(input, key) do
      cond do
        is_nil(id) -> {:ok, nil}
        Org.active_employee?(prefix, id) -> {:ok, id}
        true -> {:error, :employee_inactive}
      end
    end
  end

  defp opt_condition(input) do
    case Map.get(input, "condition") do
      nil -> {:ok, nil}
      c when c in @conditions -> {:ok, c}
      _ -> {:error, {:field_invalid, "condition"}}
    end
  end

  defp parse_line_no(n) when is_integer(n) and n > 0, do: {:ok, n}

  defp parse_line_no(text) when is_binary(text) do
    case Integer.parse(text) do
      {n, ""} when n > 0 -> if Integer.to_string(n) == text, do: {:ok, n}, else: not_a_line()
      _ -> not_a_line()
    end
  end

  defp parse_line_no(_), do: not_a_line()
  defp not_a_line, do: {:error, :line_not_found}

  defp find_line(prefix, order_id, no) do
    row =
      Repo.one(
        from(l in Latest,
          where:
            l.entity_type == "assets_count_line" and l.deleted == false and
              fragment("?->>'count_order_id' = ?", l.field_values, ^order_id) and
              fragment("(?->>'line_no')::int = ?", l.field_values, ^no),
          limit: 1
        ),
        prefix: prefix
      )

    case row do
      nil -> {:error, :line_not_found}
      row -> {:ok, to_map(row)}
    end
  end

  defp value_of(line) do
    if is_nil(line["counted_quantity"]),
      do: nil,
      else: Map.new(@value_keys, &{&1, line[&1]})
  end

  defp compact(value), do: Map.reject(value, fn {_k, v} -> is_nil(v) end)

  # --- surplus lines ----------------------------------------------------------------------------

  @doc "Adds a line the book does not know (a card without a line, or a described thing). Returns the line view."
  @spec add_surplus_line(String.t(), term(), term(), map()) :: {:ok, map()} | {:error, term()}
  def add_surplus_line(prefix, id, input, opts) when is_binary(prefix) and is_map(opts) do
    actor = actor!(opts)

    with {:ok, header} <- fetch(prefix, id),
         {:ok, employee} <- commission_member(prefix, header, actor),
         :ok <- status(header, "counting"),
         {:ok, doc} <- surplus_input(prefix, header, input),
         :ok <- no_duplicate(prefix, header["record_id"], doc.asset_id) do
      Repo.transaction(fn ->
        Counts.lock_order!(prefix, header["record_id"])

        with {:ok, fresh} <- fetch(prefix, header["record_id"]),
             :ok <- status(fresh, "counting"),
             :ok <- no_duplicate(prefix, fresh["record_id"], doc.asset_id),
             no = next_number(prefix, "assets_count_line", fresh["record_id"], "line_no"),
             fv = surplus_line(fresh, doc, no),
             {:ok, _} <- create_record(prefix, "assets_count_line", fv, actor),
             :ok <-
               append_entry(prefix, fresh, no, "surplus_added", nil, doc.value, employee, actor),
             :ok <-
               audit(
                 prefix,
                 actor,
                 "entry_recorded",
                 fresh["record_id"],
                 "counting",
                 "counting",
                 no
               ) do
          {:ok, stored} = find_line(prefix, fresh["record_id"], no)
          stored
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, stored} -> {:ok, line_view(stored)}
        error -> error
      end
    end
  end

  defp surplus_input(prefix, header, input) when is_map(input) do
    with :ok <- no_extra(input, @surplus_keys),
         {:ok, target} <- surplus_target(prefix, header, input),
         {:ok, quantity} <- surplus_quantity(input, target),
         :ok <- surplus_location(prefix, header, input, target),
         {:ok, rest} <- observations(prefix, input) do
      {:ok,
       %{
         asset_id: target.asset_id,
         card: target.card,
         description: target.description,
         value: Map.put(rest, "counted_quantity", quantity)
       }}
    end
  end

  defp surplus_input(_prefix, _header, _input), do: {:error, {:field_invalid, "body"}}

  defp surplus_target(prefix, header, input) do
    asset = Map.get(input, "asset_id")
    description = Map.get(input, "description")

    cond do
      is_nil(asset) == is_nil(description) -> {:error, {:field_invalid, "asset_id"}}
      is_nil(asset) -> description_target(description)
      true -> card_target(prefix, header, asset)
    end
  end

  defp description_target(d) when is_binary(d) do
    if String.length(d) in 1..@max_description and String.valid?(d) and
         not String.contains?(d, <<0>>),
       do: {:ok, %{asset_id: nil, card: nil, description: d}},
       else: {:error, {:field_invalid, "description"}}
  end

  defp description_target(_), do: {:error, {:field_invalid, "description"}}

  defp card_target(prefix, header, asset) do
    with {:ok, id} <- cast_uuid(asset, "asset_id"),
         {:ok, card} <- card_lookup(prefix, id),
         :ok <- card_active(card),
         :ok <- card_kind(header, card) do
      {:ok, %{asset_id: id, card: card, description: nil}}
    end
  end

  defp card_lookup(prefix, id) do
    case ReadApi.lookup(prefix, id, ["assets_card"]) do
      {:ok, card} -> {:ok, card}
      _ -> {:error, :card_not_found}
    end
  end

  defp card_active(%{"active" => true}), do: :ok
  defp card_active(_), do: {:error, :card_inactive}

  defp card_kind(header, card),
    do:
      if(card["kind"] in List.wrap(header["kinds"]),
        do: :ok,
        else: {:error, :kind_not_in_count}
      )

  # A card of kind fixed or intangible is counted once ("1"); the others need a whole number >= 1.
  defp surplus_quantity(input, %{card: %{"kind" => kind}}) when kind in ["fixed", "intangible"] do
    if Map.has_key?(input, "counted_quantity"),
      do: {:error, {:field_not_allowed, "counted_quantity"}},
      else: {:ok, "1"}
  end

  defp surplus_quantity(input, _target),
    do: whole_quantity(Map.get(input, "counted_quantity"), true)

  defp surplus_location(prefix, header, input, %{card: card}) do
    kind = card && card["kind"]

    cond do
      kind == "intangible" ->
        if Map.has_key?(input, "observed_location_id"),
          do: {:error, {:field_not_allowed, "observed_location_id"}},
          else: :ok

      kind != nil and is_nil(Map.get(input, "observed_location_id")) ->
        {:error, {:field_invalid, "observed_location_id"}}

      true ->
        observed_location_ok(prefix, header, input, kind)
    end
  end

  # A card may have only one line in a count (book or surplus).
  defp no_duplicate(_prefix, _order_id, nil), do: :ok

  defp no_duplicate(prefix, order_id, asset_id) do
    if Enum.any?(all_lines(prefix, order_id), &(&1["asset_id"] == asset_id)),
      do: {:error, :count_line_exists},
      else: :ok
  end

  defp surplus_line(order, doc, no) do
    base = %{
      "count_order_id" => order["record_id"],
      "line_no" => no,
      "kind" => "surplus",
      "org_unit_id" => order["org_unit_id"],
      "book_quantity" => "0"
    }

    base =
      if doc.card do
        base
        |> Map.merge(%{"asset_id" => doc.asset_id, "asset_kind" => doc.card["kind"]})
        |> put_card(doc.card)
      else
        Map.put(base, "description", doc.description)
      end

    Map.merge(base, compact(doc.value))
  end

  # --- entry log --------------------------------------------------------------------------------

  defp append_entry(prefix, order, line_no, action, before, value, employee, actor) do
    fv =
      %{
        "count_order_id" => order["record_id"],
        "entry_no" => next_number(prefix, "assets_count_entry", order["record_id"], "entry_no"),
        "line_no" => line_no,
        "org_unit_id" => order["org_unit_id"],
        "action" => action,
        "method" => "typed",
        "value_after" => value,
        "entered_by" => actor,
        "entered_at" => DateTime.to_iso8601(DateTime.truncate(DateTime.utc_now(), :microsecond))
      }
      |> put_present("value_before", before)
      |> put_present("entered_by_employee_id", employee)

    case create_record(prefix, "assets_count_entry", fv, actor) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  # --- close ------------------------------------------------------------------------------------

  @doc "Closes a `counting` count: every line counted, `assets_count.sheet` issued, order `counted`."
  @spec close(String.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def close(prefix, id, opts) when is_binary(prefix) and is_map(opts) do
    actor = actor!(opts)

    with {:ok, header} <- fetch(prefix, id),
         :ok <- chair(prefix, header, actor),
         :ok <- status(header, "counting") do
      Repo.transaction(fn ->
        Counts.lock_order!(prefix, header["record_id"])

        with {:ok, fresh} <- fetch(prefix, header["record_id"]),
             :ok <- status(fresh, "counting"),
             lines = all_lines(prefix, fresh["record_id"]),
             :ok <- all_counted(lines),
             {:ok, issued} <- issue_sheet(prefix, fresh, lines, actor),
             fv =
               fresh
               |> Map.drop(@kept)
               |> Map.merge(%{
                 "status" => "counted",
                 "sheet_document_id" => issued.document_id,
                 "sheet_number" => issued.number_label,
                 "closed_at" =>
                   DateTime.to_iso8601(DateTime.truncate(DateTime.utc_now(), :second)),
                 "closed_by" => actor
               }),
             {:ok, _} <-
               update_record(prefix, fresh["record_id"], "assets_count_order", fv, actor),
             :ok <- audit(prefix, actor, "closed", fresh["record_id"], "counting", "counted", nil) do
          :ok
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> view_after(prefix, header["record_id"], opts)
    end
  end

  defp all_counted(lines),
    do:
      if(Enum.any?(lines, &is_nil(&1["counted_quantity"])),
        do: {:error, :lines_not_counted},
        else: :ok
      )

  defp issue_sheet(prefix, order, lines, actor) do
    content = %{
      "count_order_id" => order["record_id"],
      "order_document_id" => order["document_id"],
      "order_number" => order["number"],
      "org_unit_id" => order["org_unit_id"],
      "kinds" => List.wrap(order["kinds"]),
      "location_ids" => prefix |> scope_roots(order["record_id"]) |> Enum.sort(),
      "cut_off_at" => order["cut_off_at"],
      "cutoff_seq" => order["cutoff_seq"],
      "chair_employee_id" => order["chair_employee_id"],
      "member_employee_ids" => members(prefix, order),
      "lines" => Enum.map(lines, &line_view/1)
    }

    with {:ok, %{document: document}} <-
           Documents.create_draft(
             prefix,
             %{
               type_key: "assets_count.sheet",
               issuing_org_unit_id: order["org_unit_id"],
               content: content
             },
             actor
           ),
         {:ok, _} <- Documents.issue(prefix, %{document_id: document.id, actor_id: actor}),
         {:ok, summary} <- Documents.issued_summary(prefix, document.id) do
      {:ok, Map.put(summary, :document_id, document.id)}
    else
      {:error, reason} -> {:error, {:document, reason}}
    end
  end

  # --- sheet marks ------------------------------------------------------------------------------

  @doc "The chair records the signers of the issued sheet. `body` is `%{\"signer_employee_ids\" => [...]}`, the exact required set."
  @spec mark_sheet_signed(String.t(), term(), term(), map()) :: {:ok, map()} | {:error, term()}
  def mark_sheet_signed(prefix, id, body, opts) when is_binary(prefix) and is_map(opts) do
    actor = actor!(opts)

    with {:ok, header} <- fetch(prefix, id),
         :ok <- chair(prefix, header, actor),
         :ok <- status(header, "counted"),
         {:ok, ids} <- signer_input(body) do
      Repo.transaction(fn ->
        Counts.lock_order!(prefix, header["record_id"])

        with {:ok, fresh} <- fetch(prefix, header["record_id"]),
             :ok <- status(fresh, "counted"),
             {:ok, sheet} <- issued_sheet(prefix, fresh),
             required = required_signers(prefix, fresh, sheet.content["lines"]),
             :ok <- exact_set(ids, required),
             now = DateTime.truncate(DateTime.utc_now(), :microsecond),
             :ok <- append_signatures(prefix, fresh, sheet, required, actor, now),
             fv =
               fresh
               |> Map.drop(@kept)
               |> Map.merge(%{
                 "status" => "sheet_signed",
                 "sheet_signed_at" => DateTime.to_iso8601(now),
                 "sheet_signed_by" => actor
               }),
             {:ok, _} <-
               update_record(prefix, fresh["record_id"], "assets_count_order", fv, actor),
             :ok <-
               audit(
                 prefix,
                 actor,
                 "sheet_signed",
                 fresh["record_id"],
                 "counted",
                 "sheet_signed",
                 nil
               ) do
          :ok
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> view_after(prefix, header["record_id"], opts)
    end
  end

  defp issued_sheet(prefix, %{"sheet_document_id" => doc_id}) when is_binary(doc_id) do
    case Posting.issued(prefix, doc_id) do
      %{content: %{"lines" => lines}} = sheet when is_list(lines) -> {:ok, sheet}
      _ -> {:error, :count_state_invalid}
    end
  end

  defp issued_sheet(_prefix, _order), do: {:error, :count_state_invalid}

  defp signer_input(%{} = body) do
    with :ok <- no_extra(body, ["signer_employee_ids"]),
         ids when is_list(ids) <- Map.get(body, "signer_employee_ids"),
         true <- length(ids) <= @max_signers,
         cast = Enum.map(ids, &cast_signer/1),
         false <- Enum.any?(cast, &(&1 == :error)),
         true <- length(Enum.uniq(cast)) == length(cast) do
      {:ok, cast}
    else
      {:error, _} = error -> error
      _ -> {:error, {:field_invalid, "signer_employee_ids"}}
    end
  end

  defp signer_input(_), do: {:error, {:field_invalid, "signer_employee_ids"}}

  defp cast_signer(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> :error
    end
  end

  defp cast_signer(_), do: :error

  # `[{employee_id, role}]` in a fixed order: chair, members, then the material responsible people of
  # the sheet lines (the book and the observed ones), chair and members removed.
  defp required_signers(prefix, header, lines) do
    chair = header["chair_employee_id"]
    members = prefix |> members(header) |> Enum.reject(&(&1 == chair))

    responsibles =
      lines
      |> Enum.flat_map(
        &[&1["book_material_responsible_id"], &1["observed_material_responsible_id"]]
      )
      |> Enum.filter(&is_binary/1)
      |> Enum.reject(&(&1 == "" or &1 == chair or &1 in members))
      |> Enum.uniq()
      |> Enum.sort()

    [{chair, "chair"}] ++
      Enum.map(members, &{&1, "member"}) ++ Enum.map(responsibles, &{&1, "responsible"})
  end

  defp exact_set(ids, required) do
    wanted = Enum.map(required, &elem(&1, 0))

    cond do
      Enum.any?(ids, &(&1 not in wanted)) -> {:error, {:field_invalid, "signer_employee_ids"}}
      Enum.any?(wanted, &(&1 not in ids)) -> {:error, :signers_incomplete}
      true -> :ok
    end
  end

  defp append_signatures(prefix, order, sheet, required, actor, now) do
    Enum.reduce_while(required, :ok, fn {employee, role}, :ok ->
      fv = %{
        "count_order_id" => order["record_id"],
        "document_kind" => "sheet",
        "document_id" => order["sheet_document_id"],
        "version_no" => sheet.version_no,
        "employee_id" => employee,
        "signer_role" => role,
        "org_unit_id" => order["org_unit_id"],
        "marked_by" => actor,
        "marked_at" => DateTime.to_iso8601(now)
      }

      case create_record(prefix, "assets_count_signature", fv, actor) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # --- reads ------------------------------------------------------------------------------------

  @doc "The lines of a count, by `line_no`. `params` (string keys): `limit` (1..200, default 50), `cursor`."
  @spec lines(String.t(), term(), term(), map()) :: {:ok, map()} | {:error, term()}
  def lines(prefix, id, params, opts) when is_binary(prefix) and is_map(opts) do
    _ = actor!(opts)

    with {:ok, header} <- fetch(prefix, id),
         {:ok, limit, after_n} <- read_params(params) do
      {:ok,
       page_of(
         prefix,
         "assets_count_line",
         "line_no",
         header["record_id"],
         limit,
         after_n,
         &line_view/1
       )}
    end
  end

  @doc "The entry log of a count, by `entry_no`. Same `params` as `lines/4`."
  @spec entries(String.t(), term(), term(), map()) :: {:ok, map()} | {:error, term()}
  def entries(prefix, id, params, opts) when is_binary(prefix) and is_map(opts) do
    _ = actor!(opts)

    with {:ok, header} <- fetch(prefix, id),
         {:ok, limit, after_n} <- read_params(params) do
      {:ok,
       page_of(
         prefix,
         "assets_count_entry",
         "entry_no",
         header["record_id"],
         limit,
         after_n,
         &entry_view/1
       )}
    end
  end

  @doc "The issued `assets_count.sheet` summary (number, version, time, hash; no content bytes)."
  @spec sheet_document(String.t(), term(), map()) :: {:ok, map()} | {:error, :not_found}
  def sheet_document(prefix, id, opts) when is_binary(prefix) and is_map(opts) do
    _ = actor!(opts)

    with {:ok, header} <- fetch(prefix, id),
         doc_id when is_binary(doc_id) <- header["sheet_document_id"],
         {:ok, summary} <- Documents.issued_summary(prefix, doc_id) do
      {:ok, Map.put(summary, :document_id, doc_id)}
    else
      _ -> {:error, :not_found}
    end
  end

  defp read_params(params) when is_map(params) do
    with :ok <- no_extra(params, @read_keys),
         {:ok, limit} <- read_limit(params),
         {:ok, cursor} <- read_cursor(params) do
      {:ok, limit, cursor}
    end
  end

  defp read_params(_), do: {:error, {:field_invalid, "params"}}

  defp read_limit(params) do
    case Map.fetch(params, "limit") do
      :error ->
        {:ok, 50}

      {:ok, v} when is_integer(v) and v in 1..200 ->
        {:ok, v}

      {:ok, v} when is_binary(v) ->
        case Integer.parse(v) do
          {n, ""} when n in 1..200 -> {:ok, n}
          _ -> {:error, {:field_invalid, "limit"}}
        end

      _ ->
        {:error, {:field_invalid, "limit"}}
    end
  end

  defp read_cursor(params) do
    case Map.fetch(params, "cursor") do
      :error ->
        {:ok, 0}

      {:ok, v} when is_binary(v) ->
        case Integer.parse(v) do
          {n, ""} when n >= 0 -> {:ok, n}
          _ -> {:error, {:field_invalid, "cursor"}}
        end

      _ ->
        {:error, {:field_invalid, "cursor"}}
    end
  end

  defp page_of(prefix, type, number_field, order_id, limit, after_n, view) do
    rows =
      Repo.all(
        from(l in Latest,
          where:
            l.entity_type == ^type and l.deleted == false and
              fragment("?->>'count_order_id' = ?", l.field_values, ^order_id) and
              fragment("(?->>?)::int > ?", l.field_values, ^number_field, ^after_n),
          order_by: fragment("(?->>?)::int", l.field_values, ^number_field),
          limit: ^(limit + 1)
        ),
        prefix: prefix
      )

    {page, rest} = Enum.split(rows, limit)

    %{
      rows: Enum.map(page, &(&1 |> to_map() |> view.())),
      next_cursor:
        if(rest == [],
          do: nil,
          else: page |> List.last() |> then(&to_string(&1.field_values[number_field]))
        )
    }
  end

  # INV-2: the wire shapes are built field by field. The line view is also the sheet content line.
  defp line_view(l) do
    %{
      "line_no" => l["line_no"],
      "kind" => l["kind"],
      "asset_id" => l["asset_id"],
      "asset_kind" => l["asset_kind"],
      "inventory_number" => l["inventory_number"],
      "name" => l["name"],
      "acquisition_date" => l["acquisition_date"],
      "acquisition_cost" => l["acquisition_cost"],
      "book_value" => l["book_value"],
      "description" => l["description"],
      "book_location_id" => l["book_location_id"],
      "book_material_responsible_id" => l["book_material_responsible_id"],
      "book_actual_user_id" => l["book_actual_user_id"],
      "book_quantity" => l["book_quantity"],
      "counted_quantity" => l["counted_quantity"],
      "observed_location_id" => l["observed_location_id"],
      "observed_material_responsible_id" => l["observed_material_responsible_id"],
      "observed_actual_user_id" => l["observed_actual_user_id"],
      "condition" => l["condition"]
    }
  end

  defp entry_view(e) do
    %{
      "entry_no" => e["entry_no"],
      "line_no" => e["line_no"],
      "action" => e["action"],
      "method" => e["method"],
      "value_before" => e["value_before"],
      "value_after" => e["value_after"],
      "entered_by" => e["entered_by"],
      "entered_by_employee_id" => e["entered_by_employee_id"],
      "entered_at" => e["entered_at"]
    }
  end

  # --- shared -----------------------------------------------------------------------------------

  defp view_after({:ok, _}, prefix, id, opts), do: Counts.get(prefix, id, opts)
  defp view_after({:error, _} = error, _prefix, _id, _opts), do: error

  defp fetch(prefix, id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, header} <- ReadApi.lookup(prefix, uuid, ["assets_count_order"]) do
      {:ok, header}
    else
      _ -> {:error, :not_found}
    end
  end

  defp status(%{"status" => s}, s), do: :ok
  defp status(_, _), do: {:error, :count_state_invalid}

  defp chair(prefix, header, actor) do
    chair = header["chair_employee_id"]

    case Org.employee_for_user(prefix, actor) do
      {:ok, %{"record_id" => ^chair}} -> :ok
      _ -> {:error, :not_chair}
    end
  end

  # The chair or a member of the commission; returns the caller's employee id.
  defp commission_member(prefix, header, actor) do
    with {:ok, %{"record_id" => employee}} <- Org.employee_for_user(prefix, actor),
         true <-
           employee == header["chair_employee_id"] or employee in members(prefix, header) do
      {:ok, employee}
    else
      _ -> {:error, :not_commission_member}
    end
  end

  defp members(prefix, header),
    do:
      prefix
      |> child_values("assets_count_member", header["record_id"], "employee_id")
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.sort()

  defp scope_roots(prefix, order_id),
    do: child_values(prefix, "assets_count_scope", order_id, "location_id")

  # The roots and everything below them.
  defp subtree(prefix, roots) do
    Enum.reduce(roots, MapSet.new(), fn root, acc ->
      acc |> MapSet.put(root) |> MapSet.union(MapSet.new(Tree.descendant_ids(prefix, root)))
    end)
  end

  defp all_lines(prefix, order_id) do
    Repo.all(
      from(l in Latest,
        where:
          l.entity_type == "assets_count_line" and l.deleted == false and
            fragment("?->>'count_order_id' = ?", l.field_values, ^order_id),
        order_by: fragment("(?->>'line_no')::int", l.field_values)
      ),
      prefix: prefix
    )
    |> Enum.map(&to_map/1)
  end

  defp child_values(prefix, type, order_id, field) do
    Repo.all(
      from(l in Latest,
        where:
          l.entity_type == ^type and l.deleted == false and
            fragment("?->>'count_order_id' = ?", l.field_values, ^order_id),
        select: fragment("?->>?", l.field_values, ^field)
      ),
      prefix: prefix
    )
  end

  # Max + 1 of an integer field over the records of an order; the caller holds the order lock.
  defp next_number(prefix, type, order_id, field) do
    max =
      Repo.one(
        from(l in Latest,
          where:
            l.entity_type == ^type and l.deleted == false and
              fragment("?->>'count_order_id' = ?", l.field_values, ^order_id),
          select: fragment("max((?->>?)::int)", l.field_values, ^field)
        ),
        prefix: prefix
      )

    (max || 0) + 1
  end

  defp to_map(%{record_id: rid, field_values: fv, entity_type: type}),
    do: Map.merge(fv, %{"record_id" => rid, "entity_type" => type})

  defp text(nil), do: nil
  defp text(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp text(value) when is_binary(value), do: value
  defp text(value) when is_integer(value), do: Integer.to_string(value)
  defp text(value), do: to_string(value)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp no_extra(map, allowed) do
    case Enum.find(Map.keys(map), &(&1 not in allowed)) do
      nil -> :ok
      key -> {:error, {:field_not_allowed, to_string(key)}}
    end
  end

  defp cast_uuid(v, key) when is_binary(v) do
    case Ecto.UUID.cast(v) do
      {:ok, u} -> {:ok, u}
      :error -> {:error, {:field_invalid, key}}
    end
  end

  defp cast_uuid(_, key), do: {:error, {:field_invalid, key}}

  defp create_record(prefix, type, fv, actor) do
    attrs = %{entity_type: type, field_values: fv, actor_id: actor, idempotency_key: key()}

    # scope-all: SEC-518-R1 (assets module, own-record system path; the caller passed Assets.Access first)
    case Records.create_record(attrs, prefix, owner()) do
      {:ok, %{record: record}} -> {:ok, record.record_id}
      {:error, _} = error -> error
    end
  end

  defp update_record(prefix, id, type, fv, actor) do
    attrs = %{
      entity_type: type,
      record_id: id,
      field_values: fv,
      actor_id: actor,
      idempotency_key: key()
    }

    # scope-all: SEC-518-R1 (assets module, own-record system path; the caller passed Assets.Access first)
    case Records.update_record(attrs, prefix, owner()) do
      {:ok, _} -> {:ok, id}
      {:error, _} = error -> error
    end
  end

  defp owner, do: ManagedTypes.owner_for!(Letflow.Modules.Assets)

  defp key, do: "assets.count_sheet:" <> Ecto.UUID.generate()

  # INV-8: Audit raises on a database failure; the rescue turns the raise into a refusal.
  defp audit(prefix, actor, action, order_id, before, after_status, line_no) do
    entry = %{
      actor_id: actor,
      action: "assets_count." <> action,
      resource_type: "assets_count_order",
      resource_id: order_id,
      before_state: state(before, line_no),
      after_state: state(after_status, line_no)
    }

    case Audit.insert_entry(Repo, entry, prefix) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :audit_failed}
    end
  rescue
    _ -> {:error, :audit_failed}
  end

  defp state(status, nil), do: %{"status" => status}
  defp state(status, line_no), do: %{"status" => status, "line_no" => line_no}

  defp actor!(opts) do
    actor = Map.get(opts, :actor_id)

    unless is_binary(actor) and match?({:ok, _}, Ecto.UUID.cast(actor)),
      do: raise(ArgumentError, "opts :actor_id must be a uuid")

    actor
  end
end
