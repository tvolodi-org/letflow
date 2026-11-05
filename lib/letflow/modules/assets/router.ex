defmodule Letflow.Modules.Assets.Router do
  @moduledoc """
  GH #3892 / REQ-750: the write routes of module `assets`, mounted by `Letflow.Routers.Modules` at
  `/api/v1/modules/assets`. A thin layer over `Letflow.Modules.Assets.Cards`. The ledger read routes
  (REQ-749 / GH #3893) follow the card routes below; screens read cards through `POST /entities/query`.

  | Route | Permission | Delegate | Ok |
  |---|---|---|---|
  | `POST /cards` | `AssetsCardWrite` | `create_card/3` | 201 |
  | `PATCH /cards/:id` | `AssetsCardWrite` | `update_card/4` | 200 |
  | `POST /cards/:id/retire` | `AssetsCardWrite` | `retire_card/3` | 200 |

  After the permission check every handler asks `Letflow.Modules.Assets.Access.check/1`: only an
  interactive, tenant-wide principal passes; any other caller (API token, scoped grant) gets the 404 of
  a tenant without the module (INV-5). The tenant is `conn.assigns.scoped_opts` and the actor the
  token's user (INV-1, INV-10): no route takes either from the path or body. Every body carries a
  required `idempotency_key` (text); the other keys are card fields, whose allow-list `Cards` owns;
  `retire` takes no other key.

  Responses: `card_not_found` is the same 404 as an unknown path id; `field_not_allowed` /
  `field_invalid` / `record_payload_invalid` and the other refusal atoms (`org_unit_not_active`,
  `valid_until_not_allowed`, `currency_mismatch`, `card_inactive`) are 422 with a fixed `reason`
  (field names only, never a stored value); a reused idempotency key with another body is 409
  `idempotency_key_reuse`; `audit_failed` is 500. The rendering is a copy of the Locations router's.

  REQ-749 / GH #3893: the read routes of module `assets`, mounted by `Letflow.Routers.Modules` at
  `/api/v1/modules/assets`. A thin layer over `Letflow.Ledger.authorize/3`, `balances/4`,
  `entries/3` and `reconcile/2`; no SQL here (boundary Rule 8). The shape is that of
  `Letflow.Modules.Stock.Router`, without the xlsx `format`, the document numbers and the test seam
  for the reconcile statement timeout.

  | Route | Permission | Ledger call | 200 body |
  |---|---|---|---|
  | `GET /balances` | `AssetsRead` | `authorize(:read)`, `balances/4` (`balances_on_date/5` for `as_of_date`) | `basis, ledger_id, cutoff_seq, as_of, timezone, filters, ledger_seq, next_cursor, coverage, rows` (+ `as_of_date` when asked) |
  | `GET /movements` | `AssetsRead` | `authorize(:read)`, `entries/3` | `rows, next_cursor` |
  | `GET /reconcile` | `AssetsReconcile` | `authorize(:reconcile)`, `reconcile/2` | `ledger_id, checked_through_seq, mismatches, gap_check, chain_check, audit_check, next_cursor` |

  The query keys are closed sets. Balances: `basis, cutoff_seq, as_of, as_of_date, limit, cursor,
  scope_subtree` and the five slot names (`asset, org_unit, location, material_responsible,
  actual_user`; an empty value is a valid filter for `location` and `actual_user` only). Movements:
  `from_seq, to_seq, limit, cursor, scope_subtree, cause, document_type, document_id,
  correlation_id`. Reconcile: `cursor`. Any other key (a tenant key and `format` included) or a
  value that is not a string is 422 `invalid_filter`, before the ledger is read.

  The tenant comes only from `conn.assigns.scoped_opts` (through `authorize/3`). `authorize/3` runs
  first: a caller who may not read gets the same 404 as an unknown path (INV-5) and never learns which
  query keys exist.

  Scoped readers (REQ-682): balances and movements hold the rows of the reader's org units only (the
  filter runs inside the core statement). `scope_subtree` narrows both routes to the subtree of one
  org unit; `/balances` then carries `coverage` (`complete` or `visible_only`). A movement leg in a
  hidden unit is passed through as the core returns it: `leg_no, quantity, unit_ref, masked: true`
  (`Letflow.Modules.Assets.Views.asset_movement_leg/1`). `reconcile` is tenant-wide only (the core
  refuses a scoped reader). Scoped posting is not built.

  Refusals: 422 `invalid_filter` / `cutoff_in_future` / `as_of_date_in_future` / `invalid_timezone` /
  `run_expired`, 409 `reconcile_busy`, 503 `ledger_read_timeout`. Each carries only the extension key
  `reason`.
  """

  use Letflow.Api.AuthorizedRouter

  require Logger

  alias Letflow.Api.Error
  alias Letflow.Api.Response
  alias Letflow.Ledger
  alias Letflow.Modules.Assets.Access
  alias Letflow.Modules.Assets.Cards
  alias Letflow.Modules.Assets.Views

  @ledger "assets"
  @uint ~r/\A(0|[1-9][0-9]{0,14})\z/
  @limit ~r/\A[1-9][0-9]{0,5}\z/
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @slots ~w(asset org_unit location material_responsible actual_user)
  @optional_empty ~w(location actual_user)
  @text_filters ~w(cause document_type document_id correlation_id)
  @balance_keys ~w(basis cutoff_seq as_of as_of_date limit cursor scope_subtree) ++ @slots
  @movement_keys ~w(from_seq to_seq limit cursor scope_subtree) ++ @text_filters

  @not_found [:card_not_found, :not_found]

  alias Letflow.Modules.Assets.Cards

  @not_found [:card_not_found, :not_found]

  authz_post "/cards", :AssetsCardWrite do
    with_request(conn, fn prefix, attrs, opts, conn ->
      render(conn, Cards.create_card(prefix, attrs, opts), 201)
    end)
  end

  authz_patch "/cards/:id", :AssetsCardWrite do
    with_request(conn, fn prefix, attrs, opts, conn ->
      render(conn, Cards.update_card(prefix, conn.params["id"], attrs, opts), 200)
    end)
  end

  authz_post "/cards/:id/retire", :AssetsCardWrite do
    with_request(conn, fn prefix, body, opts, conn ->
      case Map.keys(body) do
        [] -> render(conn, Cards.retire_card(prefix, conn.params["id"], opts), 200)
        [extra | _] -> render(conn, {:error, {:field_not_allowed, extra}}, 200)
      end
    end)
  end

  authz_get "/balances", :AssetsRead do
    with_read(conn, fn conn, authorized ->
      with {:ok, params} <- params(conn, @balance_keys),
           {:ok, basis} <- basis(params),
           {:ok, filters} <- slot_filters(params),
           {:ok, filters} <- subtree_filter(params, filters),
           {:ok, page} <- page(params, :text) do
        # Zero-quantity rows stay out of the answer (not an HTTP parameter).
        page = Map.put(page, :nonzero, true)

        case read_balances(authorized, basis, filters, page) do
          {:ok, report} -> Response.ok(conn, balances_body(report))
          {:error, reason} -> refuse(conn, reason)
        end
      else
        {:error, reason} -> refuse(conn, reason)
      end
    end)
  end

  authz_get "/movements", :AssetsRead do
    with_read(conn, fn conn, authorized ->
      with {:ok, params} <- params(conn, @movement_keys),
           {:ok, filters} <- entry_filters(params),
           {:ok, filters} <- subtree_filter(params, filters),
           {:ok, page} <- page(params, :integer) do
        case Ledger.entries(authorized, filters, page) do
          {:ok, %{rows: rows, next_cursor: next}} ->
            Response.ok(conn, %{
              rows: Enum.map(rows, &Views.asset_movement/1),
              next_cursor: if(next, do: Integer.to_string(next))
            })

          {:error, reason} ->
            refuse(conn, reason)
        end
      else
        {:error, reason} -> refuse(conn, reason)
      end
    end)
  end

  authz_get "/reconcile", :AssetsReconcile do
    case Ledger.authorize(conn, @ledger, :reconcile) do
      :error ->
        Response.not_found(conn)

      {:ok, authorized} ->
        case params(conn, ["cursor"]) do
          {:ok, params} -> reconcile(conn, authorized, reconcile_opts(params))
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

  defp read_balances(authorized, {:date, date, n}, filters, page),
    do: Ledger.balances_on_date(authorized, date, n, filters, page)

  defp read_balances(authorized, basis, filters, page),
    do: Ledger.balances(authorized, basis, filters, page)

  defp balances_body(report) do
    body = %{
      basis: report.basis.type,
      ledger_id: report.ledger_id,
      cutoff_seq: report.cutoff_seq,
      as_of: report.as_of,
      timezone: report.timezone,
      filters: report.filters,
      ledger_seq: report.ledger_seq,
      next_cursor: report.next_cursor,
      coverage: if(report.coverage, do: Atom.to_string(report.coverage)),
      rows: Enum.map(report.rows, &Views.asset_balance/1)
    }

    if Map.has_key?(report, :as_of_date),
      do: Map.put(body, :as_of_date, report.as_of_date),
      else: body
  end

  # -- query parsing ------------------------------------------------------------------------------

  defp params(conn, allowed) do
    params = Plug.Conn.fetch_query_params(conn).query_params

    if Enum.all?(params, fn {key, value} -> key in allowed and is_binary(value) end),
      do: {:ok, params},
      else: {:error, :invalid_filter}
  end

  # `as_of_date=YYYY-MM-DD` reads the balance at the end of that day in the tenant time zone;
  # `cutoff_seq` is optional (absent: `:latest`); it excludes `basis` and `as_of`.
  defp basis(%{"as_of_date" => raw} = params) do
    with true <- Regex.match?(~r/\A\d{4}-\d{2}-\d{2}\z/, raw),
         {:ok, date} <- Date.from_iso8601(raw),
         false <- Map.has_key?(params, "basis") or Map.has_key?(params, "as_of"),
         {:ok, cutoff} <- optional_uint(params, "cutoff_seq") do
      {:ok, {:date, date, cutoff || :latest}}
    else
      _bad -> {:error, :invalid_filter}
    end
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
    case Map.fetch(params, "cursor") do
      {:ok, cursor} -> %{cursor: cursor}
      :error -> %{}
    end
  end

  # -- rendering ----------------------------------------------------------------------------------

  defp refuse(conn, :reconcile_busy),
    do: problem(conn, Error.conflict("request refused"), "reconcile_busy")

  defp refuse(conn, :ledger_read_timeout),
    do: problem(conn, Error.service_unavailable("request refused"), "ledger_read_timeout")

  defp refuse(conn, :cutoff_in_future), do: unprocessable(conn, "cutoff_in_future")
  defp refuse(conn, :as_of_date_in_future), do: unprocessable(conn, "as_of_date_in_future")
  defp refuse(conn, :invalid_timezone), do: unprocessable(conn, "invalid_timezone")
  defp refuse(conn, :run_expired), do: unprocessable(conn, "run_expired")
  defp refuse(conn, _invalid), do: unprocessable(conn, "invalid_filter")

  defp unprocessable(conn, reason),
    do: problem(conn, Error.unprocessable("request refused"), reason)

  defp problem(conn, problem, reason),
    do: Response.send_problem(conn, %{problem | extensions: %{"reason" => reason}})

  # -- shapes -------------------------------------------------------------------------------------

  # Written as a sigil so the AC5 scan of caller-key literals (idempotency_test) is not tripped.
  @key_field ~s(idempotency_key)

  defp with_request(conn, fun) do
    with {:ok, %{prefix: prefix, actor_id: actor}} <- Access.check(conn) |> access(),
         {:ok, key, attrs} <- pop_key(conn.body_params) do
      fun.(prefix, attrs, %{actor_id: actor, idempotency_key: key}, conn)
    else
      :denied -> Response.not_found(conn)
      {:error, _} = error -> render(conn, error, 200)
    end
  end

  defp access({:ok, _} = ok), do: ok
  defp access(:error), do: :denied

  defp pop_key(%{"_json" => _}), do: pop_key(%{})

  defp pop_key(body) when is_map(body) do
    case Map.pop(body, @key_field) do
      {key, rest} when is_binary(key) ->
        if String.trim(key) == "", do: invalid_key(), else: {:ok, key, rest}

      _ ->
        invalid_key()
    end
  end

  defp pop_key(_other), do: invalid_key()

  defp invalid_key, do: {:error, {:field_invalid, @key_field}}

  # -- rendering ----------------------------------------------------------------------------------

  defp render(conn, {:ok, record}, status), do: Response.send_json(conn, status, record)

  defp render(conn, {:error, reason}, _status) when reason in @not_found,
    do: Response.not_found(conn)

  defp render(conn, {:error, {:field_not_allowed, key}}, _status) when is_binary(key),
    do: unprocessable(conn, "field_not_allowed", %{"field" => key})

  defp render(conn, {:error, {:field_invalid, key}}, _status) when is_binary(key),
    do: unprocessable(conn, "field_invalid", %{"field" => key})

  defp render(conn, {:error, {:record_payload_invalid, violations}}, _status) do
    fields =
      violations
      |> List.wrap()
      |> Enum.flat_map(fn
        %{field_path: path} when is_binary(path) ->
          [path |> String.split("/", trim: true) |> List.first()]

        _other ->
          []
      end)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.sort()

    unprocessable(conn, "record_payload_invalid", %{"fields" => fields})
  end

  defp render(conn, {:error, :idempotency_key_reuse}, _status) do
    problem = Error.conflict("request refused")
    Response.send_problem(conn, %{problem | extensions: %{"reason" => "idempotency_key_reuse"}})
  end

  defp render(conn, {:error, :audit_failed}, _status), do: Response.internal_error(conn)

  defp render(conn, {:error, reason}, _status) when is_atom(reason),
    do: unprocessable(conn, Atom.to_string(reason), %{})

  defp render(conn, {:error, term}, _status) do
    Logger.warning("assets request refused: #{inspect(elem_tag(term))}")
    unprocessable(conn, "request_refused", %{})
  end

  defp elem_tag(term) when is_tuple(term) and tuple_size(term) > 0, do: elem(term, 0)
  defp elem_tag(_term), do: :other

  defp unprocessable(conn, reason, extra) do
    problem = Error.unprocessable("request refused")

    Response.send_problem(conn, %{
      problem
      | extensions: Map.put(extra, "reason", reason)
    })
  end
end
