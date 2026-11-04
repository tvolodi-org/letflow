defmodule Letflow.Modules.Stock.Router do
  @moduledoc """
  REQ-687 / GH #3707: the read routes of module `stock`, mounted by `Letflow.Routers.Modules` at
  `/api/v1/modules/stock`. A thin layer over `Letflow.Ledger.authorize/3`, `balances/4`, `entries/3`
  and `reconcile/2`; no SQL here (boundary Rule 8).

  | Route | Permission | Ledger call | 200 body |
  |---|---|---|---|
  | `GET /balances` | `StockRead` | `authorize(:read)`, `balances/4` | `basis, ledger_id, cutoff_seq, as_of, timezone, filters, ledger_seq, next_cursor, coverage, rows` |
  | `GET /movements` | `StockRead` | `authorize(:read)`, `entries/3` | `rows, next_cursor` |
  | `GET /reconcile` | `StockReconcile` | `authorize(:reconcile)`, `reconcile/2` | `ledger_id, checked_through_seq, mismatches, gap_check, chain_check, audit_check, next_cursor` |

  Both read routes take `format=json|xlsx` (REQ-728 / GH #3772; default `json`). `xlsx` renders the same
  body through `Letflow.Modules.Stock.XlsxExport` (one page per file, a `report` sheet with the time basis);
  any other value is 422 `invalid_filter` before the ledger is read.

  The tenant comes only from `conn.assigns.scoped_opts` (through `authorize/3`); a tenant key in the
  query is refused 422 `invalid_filter` and never read. `authorize/3` runs first: a caller who may not
  read gets the same 404 as an unknown path (INV-5) and never learns which query keys exist.

  Scoped readers (REQ-682, P25): `authorize/3` serves a reader granted on org units; balances and
  movements then hold the rows of those units only (the filter runs inside the core statement).
  The query key `scope_subtree` (one org unit id P) narrows both routes to the subtree of P;
  `/balances` then carries `coverage`: `complete` or `visible_only`. A client shows `visible_only`
  as "your units in P", never as the total of P. A movement leg in a hidden unit is passed through
  as the core returns it: `leg_no, quantity, unit_ref, masked: true` and nothing else
  (`Views.stock_movement_leg/1`). Without a subtree filter `coverage` is `null`. `reconcile` stays
  tenant-wide only.

  Refusals: 422 `invalid_filter` / `cutoff_in_future` / `run_expired`, 409 `reconcile_busy`, 503
  `ledger_read_timeout` (a statement timeout 57014 of the core). Each carries only the extension key
  `reason`. The optional app env `:stock_reconcile_statement_timeout_ms` (1..10000, unset everywhere
  but a test) can only lower the reconcile statement timeout; it is the seam that lets a test force 57014.
  The renderer idioms are copied from `Letflow.Modules.Codes.Router`.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Error
  alias Letflow.Api.Response
  alias Letflow.Ledger
  alias Letflow.Modules.Stock.Views
  alias Letflow.Modules.Stock.XlsxExport

  require Logger

  @ledger "stock"
  @uint ~r/\A(0|[1-9][0-9]{0,14})\z/
  @limit ~r/\A[1-9][0-9]{0,5}\z/
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @slots ~w(sku location org_unit responsible lot)
  @optional_empty ~w(responsible lot)
  @text_filters ~w(cause document_type document_id correlation_id)
  @balance_keys ~w(basis cutoff_seq as_of limit cursor format scope_subtree) ++ @slots
  @movement_keys ~w(from_seq to_seq limit cursor format scope_subtree) ++ @text_filters

  authz_get "/balances", :StockRead do
    with_read(conn, fn conn, authorized ->
      with {:ok, params} <- params(conn, @balance_keys),
           {:ok, format} <- format(params),
           {:ok, basis} <- basis(params),
           {:ok, filters} <- slot_filters(params),
           {:ok, filters} <- subtree_filter(params, filters),
           {:ok, page} <- page(params, :text) do
        case Ledger.balances(authorized, basis, filters, page) do
          {:ok, report} ->
            body = balances_body(report)

            respond(conn, format, body, "stock-balances.xlsx", fn -> XlsxExport.balances(body) end)

          {:error, reason} ->
            refuse(conn, reason)
        end
      else
        {:error, reason} -> refuse(conn, reason)
      end
    end)
  end

  authz_get "/movements", :StockRead do
    with_read(conn, fn conn, authorized ->
      with {:ok, params} <- params(conn, @movement_keys),
           {:ok, format} <- format(params),
           {:ok, filters} <- entry_filters(params),
           {:ok, filters} <- subtree_filter(params, filters),
           {:ok, page} <- page(params, :integer) do
        case Ledger.entries(authorized, filters, page) do
          {:ok, %{rows: rows, next_cursor: next}} ->
            body = %{
              rows: Enum.map(rows, &Views.stock_movement/1),
              next_cursor: if(next, do: Integer.to_string(next))
            }

            respond(conn, format, body, "stock-movements.xlsx", fn ->
              XlsxExport.movements(body, filters)
            end)

          {:error, reason} ->
            refuse(conn, reason)
        end
      else
        {:error, reason} -> refuse(conn, reason)
      end
    end)
  end

  authz_get "/reconcile", :StockReconcile do
    case Ledger.authorize(conn, @ledger, :reconcile) do
      :error ->
        Response.not_found(conn)

      {:ok, authorized} ->
        with {:ok, params} <- params(conn, ["cursor"]),
             {:ok, opts} <- reconcile_opts(params) do
          reconcile(conn, authorized, opts)
        else
          {:error, reason} -> refuse(conn, reason)
        end
    end
  end

  authz_unmatched(:ordinary)

  # -- handlers -----------------------------------------------------------------------------------

  defp with_read(conn, fun) do
    case Ledger.authorize(conn, @ledger, :read) do
      {:ok, authorized} -> fun.(conn, authorized)
      :error -> Response.not_found(conn)
    end
  end

  defp reconcile(conn, authorized, opts) do
    case Ledger.reconcile(authorized, opts) do
      {:ok, r} ->
        Response.ok(conn, %{
          ledger_id: r.ledger_id,
          checked_through_seq: r.checked_through_seq,
          mismatches: Enum.map(r.mismatches, &Views.mismatch/1),
          gap_check: check(r.gap_check),
          chain_check: check(r.chain_check),
          audit_check: check(r.audit_check),
          next_cursor: r.next_cursor
        })

      {:error, reason} ->
        refuse(conn, reason)
    end
  rescue
    error in Postgrex.Error ->
      case error do
        %Postgrex.Error{postgres: %{code: :query_canceled}} -> refuse(conn, :ledger_read_timeout)
        other -> reraise other, __STACKTRACE__
      end
  end

  defp check(:ok), do: "ok"
  defp check({:gap, seqs}), do: %{gap: seqs}
  defp check({:broken_at, n}), do: %{broken_at: n}
  defp check({:mismatch_at, n}), do: %{mismatch_at: n}

  defp respond(conn, :json, body, _name, _render), do: Response.ok(conn, body)

  defp respond(conn, :xlsx, _body, name, render) do
    case render.() do
      {:ok, binary} ->
        send_xlsx(conn, binary, name)

      {:error, :xlsx_write_failed} ->
        Logger.error("stock xlsx write failed")
        Response.internal_error(conn)
    end
  end

  @xlsx_content_type "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

  defp send_xlsx(conn, binary, name) do
    conn
    |> Plug.Conn.put_resp_content_type(@xlsx_content_type, nil)
    |> Plug.Conn.put_resp_header("content-disposition", ~s(attachment; filename="#{name}"))
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> Plug.Conn.send_resp(200, binary)
  end

  defp format(params) do
    case Map.get(params, "format", "json") do
      "json" -> {:ok, :json}
      "xlsx" -> {:ok, :xlsx}
      _other -> {:error, :invalid_filter}
    end
  end

  defp balances_body(report) do
    %{
      basis: report.basis.type,
      ledger_id: report.ledger_id,
      cutoff_seq: report.cutoff_seq,
      as_of: report.as_of,
      timezone: report.timezone,
      filters: report.filters,
      ledger_seq: report.ledger_seq,
      next_cursor: report.next_cursor,
      coverage: if(report.coverage, do: Atom.to_string(report.coverage)),
      rows: Enum.map(report.rows, &Views.stock_balance/1)
    }
  end

  # -- query parsing ------------------------------------------------------------------------------

  defp params(conn, allowed) do
    params = Plug.Conn.fetch_query_params(conn).query_params

    if Enum.all?(params, fn {key, value} -> key in allowed and is_binary(value) end),
      do: {:ok, params},
      else: {:error, :invalid_filter}
  end

  defp basis(params) do
    kind = Map.get(params, "basis", "posting_seq")

    with {:ok, cutoff} <- optional_uint(params, "cutoff_seq") do
      case {kind, cutoff, Map.get(params, "as_of")} do
        {"posting_seq", nil, nil} -> {:ok, {:posting_seq, :latest}}
        {"posting_seq", n, nil} -> {:ok, {:posting_seq, n}}
        {"event_time", n, as_of} when is_integer(n) and is_binary(as_of) -> event_basis(as_of, n)
        _other -> {:error, :invalid_filter}
      end
    end
  end

  defp event_basis(as_of, n) do
    case DateTime.from_iso8601(as_of) do
      {:ok, at, _offset} -> {:ok, {:event_time, at, n}}
      _error -> {:error, :invalid_filter}
    end
  end

  defp optional_uint(params, key) do
    case Map.fetch(params, key) do
      :error -> {:ok, nil}
      {:ok, text} -> uint(text)
    end
  end

  defp uint(text) do
    if Regex.match?(@uint, text),
      do: {:ok, String.to_integer(text)},
      else: {:error, :invalid_filter}
  end

  defp slot_filters(params) do
    Enum.reduce_while(@slots, {:ok, %{}}, fn slot, {:ok, acc} ->
      case Map.fetch(params, slot) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, value} ->
          if Regex.match?(@uuid, value) or (value == "" and slot in @optional_empty),
            do: {:cont, {:ok, Map.put(acc, slot, value)}},
            else: {:halt, {:error, :invalid_filter}}
      end
    end)
  end

  defp entry_filters(params) do
    with {:ok, from} <- optional_uint(params, "from_seq"),
         {:ok, to} <- optional_uint(params, "to_seq"),
         true <- is_nil(from) or is_nil(to) or from <= to,
         {:ok, texts} <- text_filters(params) do
      {:ok,
       texts
       |> put_unless_nil("from_seq", from)
       |> put_unless_nil("to_seq", to)}
    else
      _bad -> {:error, :invalid_filter}
    end
  end

  # The core filter key is the atom-free string "scope_subtree"; the id is checked by the core
  # (a bad id answers invalid_filter), the route only bounds the text.
  defp subtree_filter(params, filters) do
    case Map.fetch(params, "scope_subtree") do
      :error ->
        {:ok, filters}

      {:ok, id} ->
        if id != "" and byte_size(id) <= 64 and String.valid?(id),
          do: {:ok, Map.put(filters, "scope_subtree", id)},
          else: {:error, :invalid_filter}
    end
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  defp text_filters(params) do
    Enum.reduce_while(@text_filters, {:ok, %{}}, fn key, {:ok, acc} ->
      case Map.fetch(params, key) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, value} ->
          if value != "" and byte_size(value) <= 200 and String.valid?(value),
            do: {:cont, {:ok, Map.put(acc, key, value)}},
            else: {:halt, {:error, :invalid_filter}}
      end
    end)
  end

  defp page(params, cursor_kind) do
    with {:ok, limit} <- optional_limit(params),
         {:ok, cursor} <- cursor(params, cursor_kind) do
      {:ok, %{} |> put_unless_nil(:limit, limit) |> put_unless_nil(:cursor, cursor)}
    end
  end

  defp optional_limit(params) do
    case Map.fetch(params, "limit") do
      :error ->
        {:ok, nil}

      {:ok, text} ->
        if Regex.match?(@limit, text),
          do: {:ok, String.to_integer(text)},
          else: {:error, :invalid_filter}
    end
  end

  defp cursor(params, :text) do
    case Map.fetch(params, "cursor") do
      :error -> {:ok, nil}
      {:ok, text} when byte_size(text) in 1..4096 -> {:ok, text}
      _bad -> {:error, :invalid_filter}
    end
  end

  defp cursor(params, :integer) do
    case Map.fetch(params, "cursor") do
      :error -> {:ok, nil}
      {:ok, text} -> uint(text)
    end
  end

  defp reconcile_opts(params) do
    opts =
      case Map.fetch(params, "cursor") do
        {:ok, cursor} -> %{cursor: cursor}
        :error -> %{}
      end

    case Application.get_env(:letflow, :stock_reconcile_statement_timeout_ms) do
      ms when is_integer(ms) and ms in 1..10_000 ->
        {:ok, Map.put(opts, :statement_timeout_ms, ms)}

      _unset ->
        {:ok, opts}
    end
  end

  # -- rendering ----------------------------------------------------------------------------------

  defp refuse(conn, :reconcile_busy),
    do: problem(conn, Error.conflict("request refused"), "reconcile_busy")

  defp refuse(conn, :ledger_read_timeout),
    do: problem(conn, Error.service_unavailable("request refused"), "ledger_read_timeout")

  defp refuse(conn, :cutoff_in_future), do: unprocessable(conn, "cutoff_in_future")
  defp refuse(conn, :run_expired), do: unprocessable(conn, "run_expired")
  defp refuse(conn, _invalid), do: unprocessable(conn, "invalid_filter")

  defp unprocessable(conn, reason),
    do: problem(conn, Error.unprocessable("request refused"), reason)

  defp problem(conn, problem, reason),
    do: Response.send_problem(conn, %{problem | extensions: %{"reason" => reason}})
end
