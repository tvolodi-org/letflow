defmodule Letflow.Modules.Assets.Router do
  @moduledoc """
  Tenant isolation proof (T-1534): `test/letflow/modules/asset_stock_isolation_test.exs` lists every id route of this
  router and of its sibling and proves the uniform cross-tenant 404; `asset_stock_scope_exports_test.exs` proves hidden
  legs stay out of the scoped reader's files.

  GH #3892 / REQ-750: the write routes of module `assets`, mounted by `Letflow.Routers.Modules` at
  `/api/v1/modules/assets`. A thin layer over `Letflow.Modules.Assets.Cards`. The ledger read routes
  (REQ-749 / GH #3893) follow the card routes below; screens read cards through `POST /entities/query`.

  | Route | Permission | Delegate | Ok |
  |---|---|---|---|
  | `POST /cards` | `AssetsCardWrite` | `create_card/3` | 201 |
  | `PATCH /cards/:id` | `AssetsCardWrite` | `update_card/4` | 200 |
  | `POST /cards/:id/retire` | `AssetsCardWrite` | `retire_card/3` | 200 |
  | `GET /cards/:id/lock` | `AssetsRead` | `CardLocks.posted?/2` | 200 `{"posted": bool, "held": bool}` |

  Card locks (T-1490): a changed `inventory_number` or `kind` of a card with a posted document is 422
  `inventory_number_locked` / `kind_locked`; `GET /cards/:id/lock` tells the screen which case it is.

  GH #3890 / #3891 (C10): the document routes of the commission. A thin layer over
  `Letflow.Modules.Assets.Documents` and `Documents.Posting`; the guard is `Access.check/2`.
  `PUT` replaces the WHOLE document: the body replaces the header and all lines, an omitted optional
  key (`location_id`, `actual_user_id`, `note`) is removed and a line left out is deleted, so a client
  sends back every header field and every line field (`asset_id`, `quantity`) it loaded.

  | Route | Permission | Delegate | Ok |
  |---|---|---|---|
  | `POST /documents` | `AssetsPost` | `Documents.save/3` | 201 document |
  | `PUT /documents/:id` | `AssetsPost` | `Documents.replace/4` | 200 document |
  | `DELETE /documents/:id` | `AssetsPost` | `Documents.discard/3` | 204 |
  | `POST /documents/:id/issue` | `AssetsPost` | `Documents.issue/4` | 200 document (starts the posting instance) |
  | `POST /documents/:id/check` | `AssetsPost` | `Documents.check/3` | 200 `ok, header, lines` (opening drafts only; writes nothing) |
  | `POST /documents/:id/reverse` | `AssetsReverse` | `Posting.reverse/6` | 200 document (starts the reversal instance) |
  | `GET /documents` | `AssetsRead` | `Documents.list/2` | 200 `rows, next_cursor` |
  | `GET /documents/:id` | `AssetsRead` | `Documents.fetch/3` | 200 document |
  | `POST /counts`, `PUT /counts/:id` (whole-document replace of a draft), `POST /counts/:id/issue`, `POST /counts/:id/cancel` (empty bodies; REQ-816) | `AssetsCountOrder` | 201 / 200 `Counts` order view |
  | `GET /counts` (`status`, `org_unit_id`, `limit`, `cursor`), `GET /counts/:id` (REQ-816) | `AssetsRead` | 200 `rows, next_cursor` / order view |
  | `GET /documents/:id/print[?lang=ru\|kk\|en]` (T-1915) | `AssetsRead` | `DocumentPrintSource.read/4`, `DocumentPrint.build/3`; with `form=da1\|da3\|da4&format=pdf\|docx&lang=ru\|kk` (T-1921, T-1922) `FormDa1.data/3`, `FormDa3.data/3`, `FormDa4.data/3`, `FormPrint.build/4` | 200 `application/pdf` (or `.docx` for the form) of the issued version; 404 as `GET /documents/:id`; 422 `invalid_lang`, `invalid_form`, `invalid_format`, `print_not_available`, `document_not_issued`, `print_unsupported_character` |

  Asset count routes (REQ-816, K1): after the `authz_*` permission check (403 for a caller whose roles lack it) every
  count route asks `Access.check/2` and then the flag `Settings.count_enabled?/1`; a refusal or a flag that is off is
  the same 404 `Response.not_found/1` as a tenant without the module (INV-5). Refusals of `Letflow.Modules.Assets.Counts`
  are 422 with a fixed `reason` (`count_scope_overlaps`, `count_state_invalid`, `not_chair`, ...), `audit_failed` is 500.

  REQ-817 (K2) count sheet routes, a thin layer over `Letflow.Modules.Assets.CountSheet`, same guard order:

  | Route | Permission | Delegate | Ok |
  |---|---|---|---|
  | `POST /counts/:id/open` (empty body; also needs a tenant-wide ledger read) | `AssetsCountRecord` | `CountSheet.open/3` | 200 order view |
  | `PUT /counts/:id/lines/:line_no` (replaces the line's input) | `AssetsCountRecord` | `record_line/5` | 200 line view |
  | `POST /counts/:id/surplus-lines` | `AssetsCountRecord` | `add_surplus_line/4` | 201 line view |
  | `POST /counts/:id/close` (empty body) | `AssetsCountRecord` | `close/3` | 200 order view |
  | `POST /counts/:id/sheet-signatures` | `AssetsCountRecord` | `mark_sheet_signed/4` | 200 order view |
  | `GET /counts/:id/lines`, `GET /counts/:id/entries` (`limit`, `cursor`) | `AssetsRead` | `lines/4`, `entries/4` | 200 `rows, next_cursor` |
  | `GET /counts/:id/sheet-document` | `AssetsRead` | `sheet_document/3` | 200 summary / 404 |

  Refusals: not found (malformed, unknown, discarded and other-tenant ids, one body) 404; 409
  `document_not_draft`, `document_not_posted`, `document_reversed`, `reversal_pending`,
  `posting_inconsistent`, `definition_not_active`, `register_unreadable` (an opening needs a tenant-wide ledger read); 503 `busy`; 422 with a fixed `reason` (and only the
  extension keys `field` / `line_no`) for shape, master and reason refusals; 500 without detail. The
  tenant is `Access.check/2`'s prefix only, never a path or body key (INV-1, INV-10).

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
  `Letflow.Modules.Stock.Router`, without the document numbers and the test seam for the reconcile
  statement timeout. `GET /balances` alone takes `format=json|xlsx` (REQ-763 / GH #3898; default
  `json`): `xlsx` renders the same body through `Letflow.Modules.Assets.XlsxExport` as
  `asset-balances.xlsx` (sheets `balances` and `report`, one page per file).

  | Route | Permission | Ledger call | 200 body |
  |---|---|---|---|
  | `GET /balances` | `AssetsRead` | `authorize(:read)`, `balances/4` (`balances_on_date/5` for `as_of_date`) | `basis, ledger_id, cutoff_seq, as_of, timezone, filters, ledger_seq, next_cursor, coverage, rows` (+ `as_of_date` when asked) |
  | `GET /movements` | `AssetsRead` | `authorize(:read)`, `entries/3` | `rows, next_cursor` |
  | `GET /reconcile` | `AssetsReconcile` | `authorize(:reconcile)`, `reconcile/2` | `ledger_id, checked_through_seq, mismatches, gap_check, chain_check, audit_check, next_cursor` |

  The query keys are closed sets. Balances: `basis, cutoff_seq, as_of, as_of_date, limit, cursor,
  format, scope_subtree` and the five slot names (`asset, org_unit, location, material_responsible,
  actual_user`; an empty value is a valid filter for `location` and `actual_user` only). Movements:
  `from_seq, to_seq, limit, cursor, scope_subtree, cause, document_type, document_id,
  correlation_id`. Reconcile: `cursor`. Any other key (a tenant key, and `format` on movements and reconcile, included) or a
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
  alias Letflow.Documents.FormPrint
  alias Letflow.Ledger
  alias Letflow.Modules.Assets.Access
  alias Letflow.Modules.Assets.CardLocks
  alias Letflow.Modules.Assets.Cards
  alias Letflow.Modules.Assets.CountSheet
  alias Letflow.Modules.Assets.Counts
  alias Letflow.Modules.Assets.Documents
  alias Letflow.Modules.Assets.Documents.Checks
  alias Letflow.Modules.Assets.Documents.Posting
  alias Letflow.Modules.Assets.FormDa1
  alias Letflow.Modules.Assets.FormDa3
  alias Letflow.Modules.Assets.FormDa4
  alias Letflow.Modules.Assets.DocumentPrint
  alias Letflow.Modules.Assets.DocumentPrintSource
  alias Letflow.Modules.Assets.Settings
  alias Letflow.Modules.Assets.Views
  alias Letflow.Modules.Assets.XlsxExport
  alias Letflow.Modules.ReadApi
  alias Letflow.Modules.RouterKit

  @ledger "assets"
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @slots ~w(asset org_unit location material_responsible actual_user)
  @optional_empty ~w(location actual_user)
  @text_filters ~w(cause document_type document_id correlation_id)
  @balance_keys ~w(basis cutoff_seq as_of as_of_date limit cursor format scope_subtree) ++ @slots
  @movement_keys ~w(from_seq to_seq limit cursor scope_subtree) ++ @text_filters

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

  authz_get "/cards/:id/lock", :AssetsRead do
    case Access.check(conn, :read) do
      {:ok, access} ->
        case ReadApi.lookup(access.prefix, conn.params["id"], ["assets_card"]) do
          {:ok, card} ->
            Response.ok(conn, %{
              "posted" => CardLocks.posted?(access.prefix, card["record_id"]),
              "held" => Checks.held?(access.prefix, card["record_id"])
            })

          {:error, _} ->
            Response.not_found(conn)
        end

      :error ->
        Response.not_found(conn)
    end
  end

  authz_get "/balances", :AssetsRead do
    with_read(conn, fn conn, authorized ->
      with {:ok, params} <- params(conn, @balance_keys),
           {:ok, format} <- format(params),
           {:ok, basis} <- basis(params),
           {:ok, filters} <- slot_filters(params),
           {:ok, filters} <- subtree_filter(params, filters),
           {:ok, page} <- RouterKit.page(params, :text) do
        # Zero-quantity rows stay out of the answer (not an HTTP parameter).
        page = Map.put(page, :nonzero, true)

        case read_balances(authorized, basis, filters, page) do
          {:ok, report} ->
            body = balances_body(report)

            respond(conn, format, body, "asset-balances.xlsx", fn -> XlsxExport.balances(body) end)

          {:error, reason} ->
            refuse(conn, reason)
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
           {:ok, page} <- RouterKit.page(params, :integer) do
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

  authz_post "/documents", :AssetsPost do
    with_doc_access(conn, :post, fn conn, access ->
      doc_render(conn, Documents.save(access.prefix, doc_body(conn), access.actor_id), 201)
    end)
  end

  authz_put "/documents/:id", :AssetsPost do
    with_doc_access(conn, :post, fn conn, access ->
      result =
        Documents.replace(access.prefix, conn.params["id"], doc_body(conn), access.actor_id)

      doc_render(conn, result, 200)
    end)
  end

  authz_delete "/documents/:id", :AssetsPost do
    with_doc_access(conn, :post, fn conn, access ->
      case Documents.discard(access.prefix, conn.params["id"], access.actor_id) do
        :ok -> Response.no_content(conn)
        {:error, reason} -> doc_refuse(conn, reason)
      end
    end)
  end

  authz_post "/documents/:id/issue", :AssetsPost do
    with_doc_access(conn, :post, fn conn, access ->
      opts = [
        activator: Letflow.Api.Context.activator(conn),
        authorized: read_authorized(conn),
        stock_authorized: read_authorized_stock(conn)
      ]

      doc_render(
        conn,
        Documents.issue(access.prefix, conn.params["id"], access.actor_id, opts),
        200
      )
    end)
  end

  authz_post "/documents/:id/check", :AssetsPost do
    with_doc_access(conn, :post, fn conn, access ->
      case Documents.check(access.prefix, conn.params["id"], read_authorized(conn)) do
        {:ok, result} -> Response.ok(conn, result)
        {:error, reason} -> doc_refuse(conn, reason)
      end
    end)
  end

  authz_post "/documents/:id/reverse", :AssetsReverse do
    with_doc_access(conn, :reverse, fn conn, access ->
      case read_authorized(conn) do
        nil ->
          Response.not_found(conn)

        authorized ->
          who = %{actor_id: access.actor_id, activator: Letflow.Api.Context.activator(conn)}
          opts = [stock_authorized: read_authorized_stock(conn)]
          fetch = fn prefix, id -> Documents.fetch(prefix, id, authorized, opts) end

          result =
            Posting.reverse(
              access.prefix,
              conn.params["id"],
              doc_body(conn),
              who,
              authorized,
              fetch
            )

          doc_render(conn, result, 200)
      end
    end)
  end

  authz_get "/documents", :AssetsRead do
    with_doc_access(conn, :read, fn conn, access ->
      case Documents.list(access.prefix, list_params(conn)) do
        {:ok, page} -> Response.ok(conn, page)
        {:error, reason} -> doc_refuse(conn, reason)
      end
    end)
  end

  authz_get "/documents/:id", :AssetsRead do
    with_doc_access(conn, :read, fn conn, access ->
      authorized = read_authorized(conn)
      opts = [stock_authorized: read_authorized_stock(conn)]
      doc_render(conn, Documents.fetch(access.prefix, conn.params["id"], authorized, opts), 200)
    end)
  end

  # T-1915: the printed act of an issued commission, change, hand over or write-off; same guard as the read.
  authz_get "/documents/:id/print", :AssetsRead do
    with_doc_access(conn, :read, fn conn, access ->
      query = Plug.Conn.fetch_query_params(conn).query_params

      if Map.has_key?(query, "form") do
        print_form(conn, access.prefix, query)
      else
        case print_lang(query["lang"]) do
          {:ok, lang} -> print_document(conn, access.prefix, lang)
          :invalid_lang -> unprocessable(conn, "invalid_lang")
        end
      end
    end)
  end

  # REQ-816 (asset count K1): the count order routes, behind the flag `count_enabled`.
  authz_post "/counts", :AssetsCountOrder do
    count_call(conn, :count_order, 201, fn prefix, opts ->
      Counts.create(prefix, conn.body_params, opts)
    end)
  end

  authz_put "/counts/:id", :AssetsCountOrder do
    count_call(conn, :count_order, 200, fn prefix, opts ->
      Counts.update(prefix, conn.params["id"], conn.body_params, opts)
    end)
  end

  authz_post "/counts/:id/issue", :AssetsCountOrder do
    count_call(conn, :count_order, 200, fn prefix, opts ->
      if empty_body?(conn),
        do: Counts.issue(prefix, conn.params["id"], opts),
        else: {:error, {:field_not_allowed, first_key(conn.body_params)}}
    end)
  end

  authz_post "/counts/:id/cancel", :AssetsCountOrder do
    count_call(conn, :count_order, 200, fn prefix, opts ->
      if empty_body?(conn),
        do: Counts.cancel(prefix, conn.params["id"], opts),
        else: {:error, {:field_not_allowed, first_key(conn.body_params)}}
    end)
  end

  authz_get "/counts", :AssetsRead do
    count_call(conn, :read, 200, fn prefix, opts ->
      Counts.list(prefix, Plug.Conn.fetch_query_params(conn).query_params, opts)
    end)
  end

  authz_get "/counts/:id", :AssetsRead do
    count_call(conn, :read, 200, fn prefix, opts ->
      Counts.get(prefix, conn.params["id"], opts)
    end)
  end

  # REQ-817 (asset count K2): the count sheet routes, behind the flag `count_enabled`.
  authz_post "/counts/:id/open", :AssetsCountRecord do
    count_call(conn, :count_record, 200, fn prefix, opts ->
      with true <-
             empty_body?(conn) || {:error, {:field_not_allowed, first_key(conn.body_params)}},
           {:ok, authorized} <- Ledger.authorize(conn, @ledger, :read) do
        CountSheet.open(prefix, conn.params["id"], Map.put(opts, :authorized, authorized))
      else
        :error -> {:error, :not_found}
        {:error, _} = error -> error
      end
    end)
  end

  authz_put "/counts/:id/lines/:line_no", :AssetsCountRecord do
    count_call(conn, :count_record, 200, fn prefix, opts ->
      CountSheet.record_line(
        prefix,
        conn.params["id"],
        conn.params["line_no"],
        conn.body_params,
        opts
      )
    end)
  end

  authz_post "/counts/:id/surplus-lines", :AssetsCountRecord do
    count_call(conn, :count_record, 201, fn prefix, opts ->
      CountSheet.add_surplus_line(prefix, conn.params["id"], conn.body_params, opts)
    end)
  end

  authz_post "/counts/:id/close", :AssetsCountRecord do
    count_call(conn, :count_record, 200, fn prefix, opts ->
      if empty_body?(conn),
        do: CountSheet.close(prefix, conn.params["id"], opts),
        else: {:error, {:field_not_allowed, first_key(conn.body_params)}}
    end)
  end

  authz_post "/counts/:id/sheet-signatures", :AssetsCountRecord do
    count_call(conn, :count_record, 200, fn prefix, opts ->
      CountSheet.mark_sheet_signed(prefix, conn.params["id"], conn.body_params, opts)
    end)
  end

  authz_get "/counts/:id/lines", :AssetsRead do
    count_call(conn, :read, 200, fn prefix, opts ->
      CountSheet.lines(
        prefix,
        conn.params["id"],
        Plug.Conn.fetch_query_params(conn).query_params,
        opts
      )
    end)
  end

  authz_get "/counts/:id/entries", :AssetsRead do
    count_call(conn, :read, 200, fn prefix, opts ->
      CountSheet.entries(
        prefix,
        conn.params["id"],
        Plug.Conn.fetch_query_params(conn).query_params,
        opts
      )
    end)
  end

  authz_get "/counts/:id/sheet-document", :AssetsRead do
    count_call(conn, :read, 200, fn prefix, opts ->
      CountSheet.sheet_document(prefix, conn.params["id"], opts)
    end)
  end

  authz_unmatched(:ordinary)

  # -- count order handler (REQ-816) --------------------------------------------------------------

  # 1. the guard of the purpose (a refusal is the 404 of a tenant without the module, INV-5);
  # 2. the flag `count_enabled` (off is the same 404, equal to the modules gate's answer);
  # 3. the call with the tenant of the token only (INV-1, INV-10).
  defp count_call(conn, purpose, status, fun) do
    with {:ok, access} <- Access.check(conn, purpose),
         true <- Settings.count_enabled?(access.prefix) do
      render(conn, fun.(access.prefix, %{actor_id: access.actor_id}), status)
    else
      _ -> Response.not_found(conn)
    end
  end

  defp empty_body?(conn), do: conn.body_params in [%{}, nil]

  defp first_key(%{} = body), do: body |> Map.keys() |> Enum.sort() |> List.first() |> to_string()
  defp first_key(_), do: "body"

  # -- document handlers (GH #3890 / #3891) ------------------------------------------------------

  defp with_doc_access(conn, purpose, fun) do
    case Access.check(conn, purpose) do
      {:ok, access} -> fun.(conn, access)
      :error -> Response.not_found(conn)
    end
  end

  # The ledger read authorization of the caller for `posting_check`: `nil` when the ledger refuses (the
  # check is then `nil` too), otherwise tenant-wide or scoped (REQ-693). `Access` proves `AssetsPost`
  # only, not the read scope; the opening's "once" rule accepts only a tenant-wide value
  # (`OpeningChecks.register_readable?/1`).
  defp read_authorized(conn) do
    case Ledger.authorize(conn, @ledger, :read) do
      {:ok, authorized} -> authorized
      :error -> nil
    end
  end

  # REQ-760: the stock register read authorization, for the `posting_check` of a change of kind
  # (`nil`, and the check `nil`, when the caller may not read the stock ledger).
  defp read_authorized_stock(conn) do
    case Ledger.authorize(conn, "stock", :read) do
      {:ok, authorized} -> authorized
      :error -> nil
    end
  end

  # A repeated query key is refused: the parsed map would keep only the last value.
  defp list_params(conn) do
    pairs = URI.query_decoder(conn.query_string) |> Enum.to_list()
    keys = Enum.map(pairs, &elem(&1, 0))

    if keys == Enum.uniq(keys),
      do: Plug.Conn.fetch_query_params(conn).query_params,
      else: %{"limit" => "repeated"}
  end

  # A body that is not a JSON object arrives as `%{"_json" => ...}`; the shape check refuses it.
  defp doc_body(conn) do
    case conn.body_params do
      %{"_json" => _} -> :not_an_object
      %Plug.Conn.Unfetched{} -> :not_an_object
      params -> params
    end
  end

  defp doc_render(conn, {:ok, document}, status), do: Response.send_json(conn, status, document)
  defp doc_render(conn, {:error, reason}, _status), do: doc_refuse(conn, reason)

  @doc_conflicts ~w(document_not_draft document_not_posted document_reversed reversal_pending
                    posting_inconsistent definition_not_active register_unreadable
                    external_ref_taken)a

  defp doc_refuse(conn, :not_found), do: Response.not_found(conn)

  defp doc_refuse(conn, reason) when reason in @doc_conflicts,
    do: problem(conn, Error.conflict("request refused"), Atom.to_string(reason))

  defp doc_refuse(conn, :reason_invalid), do: unprocessable(conn, "reason_invalid")
  defp doc_refuse(conn, :too_many_card_moves), do: unprocessable(conn, "too_many_card_moves")
  defp doc_refuse(conn, :invalid_filter), do: unprocessable(conn, "invalid_filter")

  defp doc_refuse(conn, :busy),
    do: problem(conn, Error.service_unavailable("request refused"), "busy")

  defp doc_refuse(conn, {reason, extras}) when is_binary(reason) and is_map(extras) do
    problem = Error.unprocessable("request refused")
    Response.send_problem(conn, %{problem | extensions: Map.put(extras, "reason", reason)})
  end

  defp doc_refuse(conn, _internal), do: Response.internal_error(conn)

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

  defp respond(conn, :json, body, _name, _render), do: Response.ok(conn, body)

  defp respond(conn, :xlsx, _body, name, render) do
    case render.() do
      {:ok, binary} ->
        send_xlsx(conn, binary, name)

      {:error, :xlsx_write_failed} ->
        Logger.error("assets xlsx write failed")
        Response.internal_error(conn)
    end
  end

  @print_langs %{"ru" => :ru, "kk" => :kk, "en" => :en}

  defp print_lang(nil), do: {:ok, :ru}

  defp print_lang(lang) when is_binary(lang) do
    case Map.fetch(@print_langs, lang) do
      {:ok, l} -> {:ok, l}
      :error -> :invalid_lang
    end
  end

  defp print_lang(_), do: :invalid_lang

  defp print_document(conn, prefix, lang) do
    tenant_id = conn.assigns |> Map.get(:auth_context, %{}) |> Map.get(:tenant_id)

    with {:ok, %{issued: issued, names: names}} <-
           DocumentPrintSource.read(prefix, conn.params["id"], tenant_id),
         {:ok, pdf} <- DocumentPrint.build(issued, names, lang) do
      send_pdf(conn, pdf, DocumentPrint.file_name(issued.number_label))
    else
      {:error, :not_found} ->
        Response.not_found(conn)

      {:error, reason} when reason in [:print_not_available, :document_not_issued] ->
        unprocessable(conn, Atom.to_string(reason))

      {:error, :unsupported_glyph} ->
        unprocessable(conn, "print_unsupported_character")

      {:error, {:render_failed, rules}} ->
        Logger.error(
          "assets document print render failed: " <> Enum.map_join(rules, ",", &inspect/1)
        )

        Response.internal_error(conn)
    end
  end

  defp send_pdf(conn, binary, name), do: send_binary(conn, binary, "application/pdf", name)

  defp send_binary(conn, binary, type, name) do
    conn
    |> Plug.Conn.put_resp_content_type(type, nil)
    |> Plug.Conn.put_resp_header("content-disposition", ~s(attachment; filename="#{name}"))
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> Plug.Conn.send_resp(200, binary)
  end

  # T-1921: the official forms printed from an asset document: kinds it may print, mapper, file suffix.
  # T-1922: ДА-4 / ҰМА-4 for a change of responsible and a hand over.
  # T-1923: ДА-3 / ҰМА-3 for a write-off.
  @document_forms %{
    "da1" => {["commission", "handover"], &FormDa1.data/3, "_DA-1"},
    "da3" => {["writeoff"], &FormDa3.data/3, "_DA-3"},
    "da4" => {["change", "handover"], &FormDa4.data/3, "_DA-4"}
  }

  # `?form=da1&format=pdf|docx&lang=ru|kk`: official form ДА-1 / ҰМА-1, ДА-3 / ҰМА-3 or ДА-4 / ҰМА-4.
  # The query is validated before the read, so an unknown and a foreign id answer alike (INV-5).
  defp print_form(conn, prefix, query) do
    with {:ok, form} <- form_param(query["form"]),
         {:ok, format} <- form_format(query["format"]),
         {:ok, lang} <- form_lang(query["lang"]) do
      {kinds, mapper, suffix} = Map.fetch!(@document_forms, form)
      tenant_id = conn.assigns |> Map.get(:auth_context, %{}) |> Map.get(:tenant_id)

      with {:ok, %{issued: issued, names: names}} <-
             DocumentPrintSource.read(prefix, conn.params["id"], tenant_id,
               kinds: kinds,
               form: true
             ),
           {:ok, bin} <- FormPrint.build(form, mapper.(issued, names, lang), lang, format) do
        {type, ext} = form_type(format)
        send_binary(conn, bin, type, form_file_name(issued.number_label, suffix, ext))
      else
        {:error, :not_found} -> Response.not_found(conn)
        {:error, reason} -> form_failure(conn, reason)
      end
    else
      {:invalid, reason} -> unprocessable(conn, reason)
    end
  end

  defp form_failure(conn, reason) when reason in [:print_not_available, :document_not_issued],
    do: unprocessable(conn, Atom.to_string(reason))

  defp form_failure(conn, :unsupported_glyph),
    do: unprocessable(conn, "print_unsupported_character")

  defp form_failure(conn, {:render_failed, rules}) do
    Logger.error("assets form print render failed: " <> Enum.map_join(rules, ",", &inspect/1))
    Response.internal_error(conn)
  end

  defp form_failure(conn, _internal), do: Response.internal_error(conn)

  defp form_param(form) when form in ["da1", "da3", "da4"], do: {:ok, form}
  defp form_param(_), do: {:invalid, "invalid_form"}

  defp form_format(nil), do: {:ok, :pdf}
  defp form_format("pdf"), do: {:ok, :pdf}
  defp form_format("docx"), do: {:ok, :docx}
  defp form_format(_), do: {:invalid, "invalid_format"}

  defp form_lang(nil), do: {:ok, "ru"}
  defp form_lang(lang) when lang in ["ru", "kk"], do: {:ok, lang}
  defp form_lang(_), do: {:invalid, "invalid_lang"}

  defp form_type(:pdf), do: {"application/pdf", "pdf"}

  defp form_type(:docx),
    do: {"application/vnd.openxmlformats-officedocument.wordprocessingml.document", "docx"}

  defp form_file_name(label, suffix, ext) do
    safe = (to_string(label) <> suffix) |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
    safe <> "." <> ext
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
         {:ok, cutoff} <- RouterKit.optional_uint(params, "cutoff_seq") do
      {:ok, {:date, date, cutoff || :latest}}
    else
      _bad -> {:error, :invalid_filter}
    end
  end

  defp basis(params) do
    kind = Map.get(params, "basis", "posting_seq")

    with {:ok, cutoff} <- RouterKit.optional_uint(params, "cutoff_seq") do
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
    with {:ok, from} <- RouterKit.optional_uint(params, "from_seq"),
         {:ok, to} <- RouterKit.optional_uint(params, "to_seq"),
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

  defp with_request(conn, fun) do
    with {:ok, %{prefix: prefix, actor_id: actor}} <- Access.check(conn) |> access(),
         {:ok, key, attrs} <- RouterKit.pop_key(conn.body_params) do
      fun.(prefix, attrs, %{actor_id: actor, idempotency_key: key}, conn)
    else
      :denied -> Response.not_found(conn)
      {:error, _} = error -> render(conn, error, 200)
    end
  end

  defp access({:ok, _} = ok), do: ok
  defp access(:error), do: :denied

  # -- rendering ----------------------------------------------------------------------------------

  defp render(conn, result, status),
    do: RouterKit.render(conn, result, status, "assets", @not_found)
end
