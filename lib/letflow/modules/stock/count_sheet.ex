defmodule Letflow.Modules.Stock.CountSheet do
  @moduledoc """
  REQ-701 / GH #3736 (assets phase B counts, decision 0079 sections 2, 4 to 6): the count sheet of a
  count order of module `stock`. `Letflow.Modules.Stock.Counts` delegates its sheet functions here, so
  callers use `Counts.open/3`, `record_count/5`, `add_surplus_line/4`, `close_counting/3`, `lines/4`,
  `entries/4` and `sheet_document/3`.

    * `open/3`: the chair opens an `ordered` count inside its planned period. The cut-off is now; the
      book quantities are read from the stock ledger at that time (`Ledger.authorize/3` is done by
      the router, this module gets the `Authorized` value and calls `Ledger.balances/4` only; no ledger
      SQL, no ledger lock). One line per non-zero balance key of the order's unit inside the order's
      locations (the roots and everything below them). The first read fixes `cutoff_seq` (N); every
      later page and location is read at `{:event_time, cut_off_at, N}`, so the whole sheet is one
      consistent picture. Only a tenant-wide reader opens (`scope == :all`, an explicit guard: a scoped
      open is not phase B); anything else is `:not_found`.
    * `record_count/5`: a commission member types the counted quantity of a line (replace semantics)
      and one `count_entry` is appended. `add_surplus_line/4` adds a line the books do not know.
    * `close_counting/3`: the chair closes a `counting` count when every `stock` line is counted; the
      `count.sheet` document is created and issued and the order becomes `counted`.

  Every write is one transaction whose FIRST statement is a per-order advisory lock (a bound
  parameter, INV-7; `lock_order!/2`, also taken by `Counts.cancel/3`). Records has no public
  `SELECT ... FOR UPDATE`; the advisory lock serialises exactly as the row lock the entry names (same
  mechanism as `issue/3` of REQ-700). Inside it only Records writes and the Documents row and
  sequence locks are taken; no ledger, engine or instance lock (decision 0061 lock classes untouched).

  A refusal is an atom (or `{:field_invalid | :field_not_allowed, key}`) and stores nothing. The
  entry log is append-only: no function of this module updates or deletes a `count_entry`. Audit
  (`stock.count.opened|line_counted|surplus_added|closed`) carries ids, status and line number only.
  Quantities travel as decimal strings. A sheet is capped at 2000 lines (`:count_too_large`).

  Assumptions, owner may change at GATE B: the 2000-line cap; the surplus entry method is `typed`; no
  client idempotency key (a retried count appends a second entry, same final quantity); the freeze
  of postings after the cut-off, scanner input, differences and posting are later slices.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit
  alias Letflow.Documents
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.Ledger
  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Locations.Tree
  alias Letflow.Modules.Org
  alias Letflow.Modules.ReadApi
  alias Letflow.Modules.Stock.Counts
  alias Letflow.Modules.Stock.Views
  alias Letflow.Repo

  @kept ["record_id", "entity_type"]
  @max_lines 2_000
  # The ledger page cap (`Ledger.page_cap/0`, 200); boundary rule 8 allows only authorize/3 and balances/4 here.
  @balance_page 200
  @quantity ~r/\A(0|[1-9][0-9]{0,14})(\.[0-9]{1,9})?\z/
  @surplus_keys ~w(location_id catalog_item_id unit_ref counted_quantity catalog_lot_id responsible_employee_id)
  @read_keys ~w(limit cursor)

  # --- open -------------------------------------------------------------------------------------

  @doc """
  Opens the count at the cut-off. `opts` is `%{actor_id, scope, authorized}`, `authorized` being the
  `Letflow.Ledger.Authorized` the router got from `Ledger.authorize(conn, "stock", :read)` (or `nil`).
  """
  @spec open(String.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def open(prefix, id, opts) when is_binary(prefix) and is_map(opts) do
    {actor, scope} = opts!(opts)

    with {:ok, header} <- fetch(prefix, id, scope),
         {:ok, authorized} <- full_reader(prefix, Map.get(opts, :authorized)),
         :ok <- chair(prefix, header, actor),
         :ok <- status(header, "ordered"),
         now = DateTime.truncate(DateTime.utc_now(), :microsecond),
         :ok <- due(header, now),
         locations = locations(prefix, header["record_id"]),
         {:ok, n, rows} <- read_book(authorized, header["org_unit_id"], locations, now),
         {:ok, lines} <- build_lines(header, rows) do
      Repo.transaction(fn ->
        lock_order!(prefix, header["record_id"])

        with {:ok, fresh} <- fetch(prefix, header["record_id"], scope),
             :ok <- status(fresh, "ordered"),
             :ok <- create_all(prefix, lines, actor),
             fv =
               fresh
               |> Map.drop(@kept)
               |> Map.merge(%{
                 "status" => "counting",
                 "cut_off_at" => DateTime.to_iso8601(now),
                 "cutoff_seq" => n
               }),
             {:ok, _} <- update_record(prefix, fresh["record_id"], "count_order", fv, actor),
             :ok <- audit(prefix, actor, "opened", fresh["record_id"], "ordered", "counting", nil) do
          :ok
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> view_after(prefix, header["record_id"], opts)
    end
  end

  defp full_reader(prefix, %{scope: :all, prefix: prefix} = authorized),
    do: {:ok, authorized}

  defp full_reader(_prefix, _other), do: {:error, :not_found}

  defp due(header, now) do
    with {:ok, a, _} <- DateTime.from_iso8601(to_string(header["planned_start"])),
         {:ok, b, _} <- DateTime.from_iso8601(to_string(header["planned_end"])),
         true <- DateTime.compare(a, now) != :gt and DateTime.compare(now, b) != :gt do
      :ok
    else
      _ -> {:error, :count_not_due}
    end
  end

  # The roots of the order and everything below them, deduplicated and sorted.
  defp locations(prefix, order_id) do
    roots = child_values(prefix, "count_order_scope", order_id, "location_id")

    roots
    |> Enum.flat_map(&[&1 | Tree.descendant_ids(prefix, &1)])
    |> Enum.uniq()
    |> Enum.sort()
  end

  # One chain of balance pages per location. The first read is `:latest` and fixes N; the rest are at N.
  defp read_book(authorized, unit, locations, at) do
    Enum.reduce_while(locations, {:ok, nil, []}, fn loc, {:ok, n, acc} ->
      case read_location(authorized, unit, loc, at, n, nil, acc) do
        {:ok, n, acc} -> {:cont, {:ok, n, acc}}
        {:error, _} -> {:halt, {:error, :ledger_read_failed}}
      end
    end)
    |> case do
      {:ok, nil, rows} -> {:ok, 0, rows}
      other -> other
    end
  end

  defp read_location(authorized, unit, loc, at, n, cursor, acc) do
    basis = {:event_time, at, n || :latest}
    filters = %{"org_unit" => unit, "location" => loc}

    page =
      if cursor,
        do: %{limit: @balance_page, cursor: cursor},
        else: %{limit: @balance_page}

    case Ledger.balances(authorized, basis, filters, page) do
      {:ok, %{cutoff_seq: seq, rows: rows, next_cursor: next}} ->
        n = n || seq
        acc = Enum.reduce(rows, acc, &[&1 | &2])

        if next, do: read_location(authorized, unit, loc, at, n, next, acc), else: {:ok, n, acc}

      {:error, _} = error ->
        error
    end
  end

  defp build_lines(header, rows) do
    lines =
      rows
      |> Enum.map(&Views.stock_balance/1)
      |> Enum.reject(&(Decimal.compare(Decimal.new(&1.quantity), 0) == :eq))
      |> Enum.sort_by(&{&1.location, &1.sku, &1.lot || "", &1.responsible || "", &1.unit_ref})
      |> Enum.with_index(1)
      |> Enum.map(fn {r, no} ->
        %{
          "count_order_id" => header["record_id"],
          "line_no" => no,
          "kind" => "stock",
          "org_unit_id" => header["org_unit_id"],
          "location_id" => r.location,
          "catalog_item_id" => r.sku,
          "unit_ref" => r.unit_ref,
          "book_quantity" => r.quantity
        }
        |> put_present("catalog_lot_id", r.lot)
        |> put_present("responsible_employee_id", r.responsible)
      end)

    if length(lines) > max_lines(), do: {:error, :count_too_large}, else: {:ok, lines}
  end

  # Test seam: the cap can only be lowered (`:stock_count_max_lines`), like the reconcile timeout.
  defp max_lines do
    case Application.get_env(:letflow, :stock_count_max_lines) do
      n when is_integer(n) and n in 1..@max_lines -> n
      _ -> @max_lines
    end
  end

  defp create_all(prefix, lines, actor) do
    Enum.reduce_while(lines, :ok, fn fv, :ok ->
      case create_record(prefix, "count_sheet_line", fv, actor) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # --- typed input ------------------------------------------------------------------------------

  @doc "Records the counted quantity of a line (replace) and appends a `count_entry`. Returns the line view."
  @spec record_count(String.t(), term(), term(), term(), map()) :: {:ok, map()} | {:error, term()}
  def record_count(prefix, id, line_no, quantity, opts) when is_binary(prefix) and is_map(opts) do
    {actor, scope} = opts!(opts)

    with {:ok, header} <- fetch(prefix, id, scope),
         {:ok, employee} <- commission_member(prefix, header, actor),
         :ok <- status(header, "counting"),
         {:ok, text} <- parse_quantity(quantity, "counted_quantity", true),
         {:ok, no} <- parse_line_no(line_no),
         {:ok, _} <- find_line(prefix, header["record_id"], no) do
      Repo.transaction(fn ->
        lock_order!(prefix, header["record_id"])

        with {:ok, fresh} <- fetch(prefix, header["record_id"], scope),
             :ok <- status(fresh, "counting"),
             {:ok, line} <- find_line(prefix, fresh["record_id"], no),
             before = line["counted_quantity"],
             {:ok, _} <-
               update_record(
                 prefix,
                 line["record_id"],
                 "count_sheet_line",
                 line |> Map.drop(@kept) |> Map.put("counted_quantity", text),
                 actor
               ),
             :ok <- append_entry(prefix, fresh, no, before, text, employee, actor),
             :ok <-
               audit(
                 prefix,
                 actor,
                 "line_counted",
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
        {:ok, line} -> {:ok, line_view(line)}
        error -> error
      end
    end
  end

  defp parse_quantity(value, key, allow_zero) when is_binary(value) do
    with true <- Regex.match?(@quantity, value),
         {d, ""} <- Decimal.parse(value),
         true <- allow_zero or Decimal.gt?(d, 0) do
      {:ok, Decimal.to_string(d, :normal)}
    else
      _ -> {:error, {:field_invalid, key}}
    end
  end

  defp parse_quantity(_value, key, _allow_zero), do: {:error, {:field_invalid, key}}

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
            l.entity_type == "count_sheet_line" and l.deleted == false and
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

  defp append_entry(prefix, order, line_no, before, after_text, employee, actor) do
    fv =
      %{
        "count_order_id" => order["record_id"],
        "entry_no" => next_number(prefix, "count_entry", order["record_id"], "entry_no"),
        "line_no" => line_no,
        "org_unit_id" => order["org_unit_id"],
        "method" => "typed",
        "quantity_after" => after_text,
        "entered_by" => actor,
        "entered_at" => DateTime.to_iso8601(DateTime.truncate(DateTime.utc_now(), :microsecond))
      }
      |> put_present("quantity_before", qty_text(before))
      |> put_present("entered_by_employee_id", employee)

    case create_record(prefix, "count_entry", fv, actor) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  # --- surplus lines ----------------------------------------------------------------------------

  @doc "Adds a line for stock the books do not know. Returns the line view."
  @spec add_surplus_line(String.t(), term(), term(), map()) :: {:ok, map()} | {:error, term()}
  def add_surplus_line(prefix, id, input, opts) when is_binary(prefix) and is_map(opts) do
    {actor, scope} = opts!(opts)

    with {:ok, header} <- fetch(prefix, id, scope),
         {:ok, employee} <- commission_member(prefix, header, actor),
         :ok <- status(header, "counting"),
         {:ok, doc} <- surplus_input(input),
         :ok <- surplus_checks(prefix, header, doc),
         :ok <- no_duplicate(prefix, header["record_id"], doc) do
      Repo.transaction(fn ->
        lock_order!(prefix, header["record_id"])

        with {:ok, fresh} <- fetch(prefix, header["record_id"], scope),
             :ok <- status(fresh, "counting"),
             :ok <- no_duplicate(prefix, fresh["record_id"], doc),
             no = next_number(prefix, "count_sheet_line", fresh["record_id"], "line_no"),
             fv = surplus_line(fresh, doc, no),
             {:ok, _} <- create_record(prefix, "count_sheet_line", fv, actor),
             :ok <- append_entry(prefix, fresh, no, nil, doc.counted_quantity, employee, actor),
             :ok <-
               audit(
                 prefix,
                 actor,
                 "surplus_added",
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

  defp surplus_input(input) when is_map(input) do
    with :ok <- no_extra(input, @surplus_keys),
         {:ok, location} <- uuid_field(input, "location_id", true),
         {:ok, item} <- uuid_field(input, "catalog_item_id", true),
         {:ok, unit_ref} <- uuid_field(input, "unit_ref", true),
         {:ok, lot} <- uuid_field(input, "catalog_lot_id", false),
         {:ok, responsible} <- uuid_field(input, "responsible_employee_id", false),
         {:ok, quantity} <-
           parse_quantity(Map.get(input, "counted_quantity"), "counted_quantity", false) do
      {:ok,
       %{
         location_id: location,
         catalog_item_id: item,
         unit_ref: unit_ref,
         catalog_lot_id: lot,
         responsible_employee_id: responsible,
         counted_quantity: quantity
       }}
    end
  end

  defp surplus_input(_), do: {:error, {:field_invalid, "body"}}

  defp uuid_field(input, key, required) do
    case Map.get(input, key) do
      nil when not required ->
        {:ok, nil}

      v when is_binary(v) ->
        case Ecto.UUID.cast(v) do
          {:ok, u} -> {:ok, u}
          :error -> {:error, {:field_invalid, key}}
        end

      _ ->
        {:error, {:field_invalid, key}}
    end
  end

  defp surplus_checks(prefix, header, doc) do
    unit = header["org_unit_id"]

    cond do
      doc.location_id not in locations(prefix, header["record_id"]) or
          not Locations.linked?(prefix, unit, doc.location_id) ->
        {:error, :location_not_in_count}

      not CatalogItems.active?(prefix, doc.catalog_item_id) ->
        {:error, :item_inactive}

      not CatalogItems.item_uom_valid?(prefix, doc.catalog_item_id, doc.unit_ref) ->
        {:error, :unit_invalid}

      doc.catalog_lot_id &&
          not CatalogItems.item_lot_valid?(prefix, doc.catalog_item_id, doc.catalog_lot_id) ->
        {:error, :lot_invalid}

      doc.responsible_employee_id && not Org.active_employee?(prefix, doc.responsible_employee_id) ->
        {:error, :employee_inactive}

      true ->
        :ok
    end
  end

  # A balance key of the order already has a line (any kind).
  defp no_duplicate(prefix, order_id, doc) do
    key =
      {doc.location_id, doc.catalog_item_id, doc.catalog_lot_id || "",
       doc.responsible_employee_id || ""}

    exists? =
      prefix
      |> all_lines(order_id)
      |> Enum.any?(fn l ->
        {l["location_id"], l["catalog_item_id"], l["catalog_lot_id"] || "",
         l["responsible_employee_id"] || ""} ==
          key
      end)

    if exists?, do: {:error, :count_line_exists}, else: :ok
  end

  defp surplus_line(order, doc, no) do
    %{
      "count_order_id" => order["record_id"],
      "line_no" => no,
      "kind" => "surplus",
      "org_unit_id" => order["org_unit_id"],
      "location_id" => doc.location_id,
      "catalog_item_id" => doc.catalog_item_id,
      "unit_ref" => doc.unit_ref,
      "book_quantity" => "0",
      "counted_quantity" => doc.counted_quantity
    }
    |> put_present("catalog_lot_id", doc.catalog_lot_id)
    |> put_present("responsible_employee_id", doc.responsible_employee_id)
  end

  # --- close ------------------------------------------------------------------------------------

  @doc "Closes a `counting` count: every `stock` line counted, `count.sheet` issued, order `counted`."
  @spec close_counting(String.t(), term(), map()) :: {:ok, map()} | {:error, term()}
  def close_counting(prefix, id, opts) when is_binary(prefix) and is_map(opts) do
    {actor, scope} = opts!(opts)

    with {:ok, header} <- fetch(prefix, id, scope),
         :ok <- chair(prefix, header, actor),
         :ok <- status(header, "counting") do
      Repo.transaction(fn ->
        lock_order!(prefix, header["record_id"])

        with {:ok, fresh} <- fetch(prefix, header["record_id"], scope),
             :ok <- status(fresh, "counting"),
             lines = all_lines(prefix, fresh["record_id"]),
             :ok <- all_counted(lines),
             {:ok, issued} <- issue_sheet(prefix, fresh, lines, actor),
             fv =
               fresh
               |> Map.drop(@kept)
               |> Map.merge(%{"status" => "counted", "sheet_document_id" => issued.document_id}),
             {:ok, _} <- update_record(prefix, fresh["record_id"], "count_order", fv, actor),
             :ok <- audit(prefix, actor, "closed", fresh["record_id"], "counting", "counted", nil) do
          :ok
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> view_after(prefix, header["record_id"], opts)
    end
  end

  defp all_counted(lines) do
    if Enum.any?(lines, &(&1["kind"] == "stock" and is_nil(&1["counted_quantity"]))),
      do: {:error, :lines_uncounted},
      else: :ok
  end

  defp issue_sheet(prefix, order, lines, actor) do
    content = %{
      "count_order_id" => order["record_id"],
      "org_unit_id" => order["org_unit_id"],
      "cut_off_at" => order["cut_off_at"],
      "cutoff_seq" => order["cutoff_seq"],
      "lines" => Enum.map(lines, &sheet_content_line/1)
    }

    with {:ok, %{document: document}} <-
           Documents.create_draft(
             prefix,
             %{
               type_key: "count.sheet",
               issuing_org_unit_id: order["org_unit_id"],
               content: content
             },
             actor
           ),
         {:ok, _} <- Documents.issue(prefix, %{document_id: document.id, actor_id: actor}) do
      {:ok, %{document_id: document.id}}
    else
      {:error, reason} -> {:error, {:document, reason}}
    end
  end

  defp sheet_content_line(line) do
    base = %{
      "line_no" => line["line_no"],
      "kind" => line["kind"],
      "location_id" => line["location_id"],
      "catalog_item_id" => line["catalog_item_id"],
      "unit_ref" => line["unit_ref"],
      "book_quantity" => qty_text(line["book_quantity"])
    }

    base
    |> put_present("catalog_lot_id", line["catalog_lot_id"])
    |> put_present("responsible_employee_id", line["responsible_employee_id"])
    |> put_present("counted_quantity", qty_text(line["counted_quantity"]))
  end

  # --- reads ------------------------------------------------------------------------------------

  @doc "The lines of a count, by `line_no`. `params` (string keys): `limit` (1..200, default 50), `cursor`."
  @spec lines(String.t(), term(), term(), map()) :: {:ok, map()} | {:error, term()}
  def lines(prefix, id, params, opts) when is_binary(prefix) and is_map(opts) do
    {_actor, scope} = opts!(opts)

    with {:ok, header} <- fetch(prefix, id, scope),
         {:ok, limit, after_n} <- read_params(params) do
      {:ok,
       page_of(
         prefix,
         "count_sheet_line",
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
    {_actor, scope} = opts!(opts)

    with {:ok, header} <- fetch(prefix, id, scope),
         {:ok, limit, after_n} <- read_params(params) do
      {:ok,
       page_of(
         prefix,
         "count_entry",
         "entry_no",
         header["record_id"],
         limit,
         after_n,
         &entry_view/1
       )}
    end
  end

  @doc "The issued `count.sheet` summary (number, version, time, hash; no content bytes)."
  @spec sheet_document(String.t(), term(), map()) :: {:ok, map()} | {:error, :not_found}
  def sheet_document(prefix, id, opts) when is_binary(prefix) and is_map(opts) do
    {_actor, scope} = opts!(opts)

    with {:ok, header} <- fetch(prefix, id, scope),
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
      :error -> {:ok, 50}
      {:ok, v} when is_integer(v) and v in 1..200 -> {:ok, v}
      {:ok, v} when is_binary(v) -> limit_text(v)
      _ -> {:error, {:field_invalid, "limit"}}
    end
  end

  defp limit_text(v) do
    case Integer.parse(v) do
      {n, ""} when n in 1..200 -> {:ok, n}
      _ -> {:error, {:field_invalid, "limit"}}
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

  # INV-2: the wire shapes are built field by field.
  defp line_view(l) do
    %{
      "line_no" => l["line_no"],
      "kind" => l["kind"],
      "location_id" => l["location_id"],
      "catalog_item_id" => l["catalog_item_id"],
      "catalog_lot_id" => l["catalog_lot_id"],
      "responsible_employee_id" => l["responsible_employee_id"],
      "unit_ref" => l["unit_ref"],
      "book_quantity" => qty_text(l["book_quantity"]),
      "counted_quantity" => qty_text(l["counted_quantity"])
    }
  end

  defp entry_view(e) do
    %{
      "entry_no" => e["entry_no"],
      "line_no" => e["line_no"],
      "method" => e["method"],
      "quantity_before" => qty_text(e["quantity_before"]),
      "quantity_after" => qty_text(e["quantity_after"]),
      "entered_by" => e["entered_by"],
      "entered_by_employee_id" => e["entered_by_employee_id"],
      "entered_at" => e["entered_at"]
    }
  end

  defp qty_text(nil), do: nil
  defp qty_text(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp qty_text(text) when is_binary(text), do: text
  defp qty_text(n) when is_integer(n), do: Integer.to_string(n)

  # --- shared -----------------------------------------------------------------------------------

  @doc false
  # The first statement of every write transaction on an order, also taken by `Counts.cancel/3`.
  def lock_order!(prefix, order_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      prefix <> ":stock_count_sheet:" <> order_id
    ])

    :ok
  end

  defp view_after({:ok, _}, prefix, id, opts), do: Counts.get(prefix, id, opts)
  defp view_after({:error, _} = error, _prefix, _id, _opts), do: error

  defp fetch(prefix, id, scope) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, header} <- ReadApi.lookup(prefix, uuid, ["count_order"]),
         :ok <- in_scope(scope, header["org_unit_id"]) do
      {:ok, header}
    else
      _ -> {:error, :not_found}
    end
  end

  defp in_scope(:all, _unit), do: :ok

  defp in_scope({:nodes, ids}, unit) when is_list(ids),
    do: if(unit in ids, do: :ok, else: {:error, :not_found})

  defp in_scope(_, _), do: {:error, :not_found}

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
           employee == header["chair_employee_id"] or
             employee in child_values(
               prefix,
               "count_commission_member",
               header["record_id"],
               "employee_id"
             ) do
      {:ok, employee}
    else
      _ -> {:error, :not_commission_member}
    end
  end

  defp all_lines(prefix, order_id) do
    Repo.all(
      from(l in Latest,
        where:
          l.entity_type == "count_sheet_line" and l.deleted == false and
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

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp no_extra(map, allowed) do
    case Enum.find(Map.keys(map), &(&1 not in allowed)) do
      nil -> :ok
      key -> {:error, {:field_not_allowed, to_string(key)}}
    end
  end

  defp create_record(prefix, type, fv, actor) do
    attrs = %{entity_type: type, field_values: fv, actor_id: actor, idempotency_key: key()}

    # scope-all: SEC-518-R1 (stock module, own-record system path; the caller's scope was checked first)
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

    # scope-all: SEC-518-R1 (stock module, own-record system path; the caller's scope was checked first)
    case Records.update_record(attrs, prefix, owner()) do
      {:ok, _} -> {:ok, id}
      {:error, _} = error -> error
    end
  end

  defp owner, do: ManagedTypes.owner_for!(Letflow.Modules.Stock)

  defp key, do: "stock.count_sheet:" <> Ecto.UUID.generate()

  # INV-8: Audit raises on a database failure; the rescue turns the raise into a refusal.
  defp audit(prefix, actor, action, order_id, before, after_status, line_no) do
    entry = %{
      actor_id: actor,
      action: "stock.count." <> action,
      resource_type: "count_order",
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

  defp opts!(opts) do
    actor = Map.get(opts, :actor_id)
    scope = Map.get(opts, :scope)

    unless is_binary(actor) and match?({:ok, _}, Ecto.UUID.cast(actor)),
      do: raise(ArgumentError, "opts :actor_id must be a uuid")

    unless scope == :all or scope == :none or match?({:nodes, l} when is_list(l), scope),
      do: raise(ArgumentError, "opts :scope must be :all, :none or {:nodes, ids}")

    {actor, scope}
  end
end
