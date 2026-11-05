defmodule Letflow.Modules.Stock.Router do
  @moduledoc """
  REQ-687 / GH #3707: the read routes of module `stock`, mounted by `Letflow.Routers.Modules` at
  `/api/v1/modules/stock`. A thin layer over `Letflow.Ledger.authorize/3`, `balances/4`, `entries/3`
  and `reconcile/2`; no SQL here (boundary Rule 8).

  | Route | Permission | Ledger call | 200 body |
  |---|---|---|---|
  | `GET /balances` | `StockRead` | `authorize(:read)`, `balances/4` | `basis, ledger_id, cutoff_seq, as_of, timezone, filters, ledger_seq, next_cursor, coverage, rows` (+ `as_of_date` when asked) |
  | `GET /movements` | `StockRead` | `authorize(:read)`, `entries/3` | `rows, next_cursor` |
  | `GET /reconcile` | `StockReconcile` | `authorize(:reconcile)`, `reconcile/2` | `ledger_id, checked_through_seq, mismatches, gap_check, chain_check, audit_check, next_cursor` |

  REQ-713 / GH #3748 adds three more (`post` retries a lost posting start, `reverse` starts the reversal
  of a posted document, `cancel` cancels the issued version) and makes `issue` start the posting
  instance; see `Letflow.Modules.Stock.Documents.Posting`.

  REQ-712 / GH #3749 adds six document routes over `Letflow.Modules.Stock.Documents` (no SQL here):

  | Route | Permission | Ok |
  |---|---|---|
  | `POST /documents` | `StockPost` | 201 document |
  | `PUT /documents/:id` | `StockPost` | 200 document (replaces the whole draft) |
  | `DELETE /documents/:id` | `StockPost` | 204 |
  | `POST /documents/:id/issue` | `StockPost` | 200 document |
  | `POST /documents/:id/check` | `StockPost` | 200 `ok, lines` (opening only, writes nothing) |
  | `POST /documents/:id/post` | `StockPost` | 200 document (starts the posting instance) |
  | `POST /documents/:id/reverse` | `StockReverse` | 200 document (starts the reversal instance) |
  | `POST /documents/:id/cancel` | `StockReverse` | 200 document (state `cancelled`) |
  | `GET /documents` | `StockRead` | 200 `rows, next_cursor` |
  | `GET /documents/:id` | `StockRead` | 200 document |

  `:id` is the id of the versioned document. The guard is `Letflow.Modules.Stock.Access`: an interactive
  tenant-wide principal only; an API token or a scoped principal gets the same 404 as a tenant without the
  module. Refusals: 404 (unknown, malformed or another tenant's id), 409 with a `reason`
  (`document_not_draft`, `definition_not_active`, `document_not_issued`, `document_cancelled`,
  `document_posted`, `posting_pending`, `document_not_posted`, `document_reversed`, `reversal_pending`,
  `posting_inconsistent`), 422 with a `reason` (shape reasons, `invalid_filter`, the issue checks,
  `reason_invalid`, `reason_required`, `reason_too_long`), 503 `busy`.

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

  `GET /balances?as_of_date=YYYY-MM-DD[&cutoff_seq=N]` (REQ-704) answers the balance at the end of that
  day in the tenant time zone through `Ledger.balances_on_date/5`; without `cutoff_seq` the cutoff is
  the current posting counter, stated in `cutoff_seq`. It is refused with `basis` or `as_of`.

  Refusals: 422 `invalid_filter` / `cutoff_in_future` / `as_of_date_in_future` / `invalid_timezone` / `run_expired`, 409 `reconcile_busy`, 503
  `ledger_read_timeout` (a statement timeout 57014 of the core). Each carries only the extension key
  `reason`. The optional app env `:stock_reconcile_statement_timeout_ms` (1..10000, unset everywhere
  but a test) can only lower the reconcile statement timeout; it is the seam that lets a test force 57014.
  The renderer idioms are copied from `Letflow.Modules.Codes.Router`.

  ## Voice draft (REQ-741, GH #3879; `Letflow.Modules.Stock.VoiceService`)

  | Route | Permission | Ok |
  |---|---|---|
  | `POST /voice/draft` (multipart `audio` m4a or WebM up to 10 MB, `lang` `ru` or `kk`) | `StockPost` | 200 `kind, items, location, to_location, quantity, transcript, dropped` |
  | `POST /voice/draft-text` (JSON `text`, optional `lang`) | `StockPost` | 200 the same body |

  Same guard as the document routes (`Access`). Read only: nothing is stored. Refusals carry `reason`
  (and `source` `speech` or `llm` for a provider step): 413 `audio_too_large`, 415 `audio_format`, 422
  `field_invalid` / `field_not_allowed` / `bad_language`, 502/504 provider failures, 503 `speech_off`.
  Model step off answers 200 with `notice: "llm_off"`.

  ## Count orders (REQ-700, GH #3737; `Letflow.Modules.Stock.Counts`)

  | Route | Permission | Ok |
  |---|---|---|
  | `POST /counts` | `StockCountOrder` | 201 order view |
  | `PUT /counts/:id` (whole-document replace of a draft: header, `location_ids`, `member_employee_ids`) | `StockCountOrder` | 200 |
  | `POST /counts/:id/issue`, `POST /counts/:id/cancel` (empty body) | `StockCountOrder` | 200 |
  | `GET /counts` (`status`, `org_unit_id`, `limit`, `cursor`) | `StockRead` | 200 `rows, next_cursor` |
  | `GET /counts/:id` | `StockRead` | 200 order view |
  | `GET /counts/:id/document` | `StockRead` | 200 issued summary, no content bytes |
  | `GET /counts/:id/paperwork/:kind` (`kind` exactly `order`, `sheet` or `differences`) | `StockRead` | 200 `.xlsx` of the issued document, 422 `document_not_issued` |
  | `GET /documents/:id/print[?lang=ru\|kk\|en]` (REQ-737; transfer, hand over, return; `lang` default `ru`; with `form=z2&format=pdf\|docx&lang=ru\|kk` the official form Z-2 / Q-2 of an issued `issue`, T-1416; `form=z5` the form Z-5 / Q-5 of an issued `transfer`, T-1417) | `StockRead` | 200 `application/pdf` (or `.docx`) of the issued version, 404 as `GET /documents/:id`, 422 `invalid_lang`, `invalid_form`, `invalid_format`, `print_not_available`, `document_not_issued`, `print_unsupported_character` |
  | `GET /stock-card/print?sku&location[&lot]&format=pdf\|docx&lang=ru\|kk` (T-1417; official form Z-3 / Q-3, the stock card of one item at one place, from the ledger movements the caller may read) | `StockRead` | 200 `application/pdf` (or `.docx`), 404 when the caller sees no movement (absent and hidden look the same), 422 `invalid_filter`, `invalid_format`, `invalid_lang`, `card_too_long` (more than 1000 entries), `print_unsupported_character` |
  | `GET /counts/:id/print/:kind[?lang=ru\|kk\|en]` (REQ-736; `kind` as above, `lang` default `ru`) | `StockRead` | 200 `application/pdf` of the issued document, 422 `invalid_lang`, `document_not_issued`, `print_unsupported_character` |

  The scope is the caller's allowed org-unit set for the route permission (`Scope.allowed_set/2`),
  so a scoped caller gets the same 404 for an order of another unit as for an unknown id. When the
  tenant's scope enforcement is `on`, the default-class route answers a scoped caller 403 first.
  REQ-701 / GH #3736 adds seven routes over `Letflow.Modules.Stock.CountSheet` (the count sheet):

  | Route | Permission | Ok |
  |---|---|---|
  | `POST /counts/:id/open` (empty body; `Ledger.authorize(:read)` here, a refusal is 404) | `StockCountRecord` | 200 order view |
  | `GET /counts/:id/lines` (`limit`, `cursor`) | `StockRead` | 200 `rows, next_cursor` |
  | `PUT /counts/:id/lines/:line_no/count` (body exactly `counted_quantity`, a decimal string) | `StockCountRecord` | 200 line |
  | `POST /counts/:id/surplus-lines` | `StockCountRecord` | 201 line |
  | `POST /counts/:id/scan` (REQ-716; body `scanned_text`, `location_id`, `scan_id`) | `StockCountRecord` | 200 line with `duplicate`, or `kind: location` |
  | `GET /counts/:id/entries` (`limit`, `cursor`) | `StockRead` | 200 `rows, next_cursor` |
  | `POST /counts/:id/close` (empty body) | `StockCountRecord` | 200 order view |
  | `GET /counts/:id/sheet-document` | `StockRead` | 200 issued summary, no content bytes |

  Extra refusal reasons: `not_commission_member`, `count_not_due`, `line_not_found`, `lines_uncounted`,
  `location_not_in_count`, `item_inactive`, `unit_invalid`, `lot_invalid`, `count_line_exists`,
  `count_too_large`, `ledger_read_failed`. Opening needs a tenant-wide reader: any other principal is 404.

  REQ-717 / GH #3764 adds five routes over `Letflow.Modules.Stock.CountDifferences` (signing and the
  differences sheet; the posting is REQ-718):

  | Route | Permission | OK |
  |---|---|---|
  | `POST /counts/:id/sheet-signatures` (body exactly `signer_employee_ids`) | `StockCountRecord` | 200 order view |
  | `POST /counts/:id/differences` (empty body) | `StockCountRecord` | 200 order view |
  | `POST /counts/:id/differences-signatures` (body exactly `signer_employee_ids`) | `StockCountRecord` | 200 order view |
  | `GET /counts/:id/differences` | `StockRead` | 200 number, version, hash, `lines` |
  | `GET /counts/:id/signatures` | `StockRead` | 200 `rows` |

  REQ-718 / GH #3763 adds four routes over `Letflow.Modules.Stock.CountPosting` (the posting of a signed count,
  built without the count freeze, assumption D-086):

  | Route | Permission | Ok |
  |---|---|---|
  | `POST /counts/:id/post` (empty body) | `StockPost` | 200 order view (starts the posting instance) |
  | `POST /counts/:id/reverse` (`reason_code`, `reason_text`) | `StockReverse` | 200 order view (starts the reversal instance) |
  | `POST /counts/:id/posting-record` (empty body) | `StockCountRecord` | 200 order view, status `posted` |
  | `GET /counts/:id/posting-document` | `StockRead` | 200 issued summary, no content bytes |

  `GET /counts/:id` also carries the posting fields (`posting_state`, `entry_id`, `posting_check` ...) of a `signed` or
  `posted` count. Conflicts (409): `posting_pending`, `count_posted`, `count_not_posted`, `count_reversed`,
  `reversal_pending`, `posting_inconsistent`, `definition_not_active`, `posting_record_exists`; 422: `no_differences`,
  `reason_invalid`, `not_chair`, `count_state_invalid`.

  Extra refusal reasons: `not_chair`, `signers_incomplete`, `sheet_already_signed`, `sheet_not_signed`,
  `differences_already_issued`, `differences_not_issued`, `differences_too_many`, `count_window_expired`.

  A refusal is 422 with `extensions.reason` (`count_state_invalid`, `count_scope_not_linked`,
  `count_scope_overlaps`, `count_scope_incomplete`, `count_too_long`, `org_unit_inactive`,
  `employee_inactive`, `chair_without_user`, `not_chair`, `field_not_allowed`, `field_invalid`,
  `shortage_exceeds_balance`).
  """

  use Letflow.Api.AuthorizedRouter

  require Logger

  alias Letflow.Api.Error
  alias Letflow.Api.Response
  alias Letflow.Api.Scope
  alias Letflow.Documents.FormPrint
  alias Letflow.Ledger
  alias Letflow.Modules.Stock.Access
  alias Letflow.Modules.Stock.Counts
  alias Letflow.Modules.Stock.CountPaperworkSource
  alias Letflow.Modules.Stock.CountPrint
  alias Letflow.Modules.Stock.DocumentPrint
  alias Letflow.Modules.Stock.DocumentPrintSource
  alias Letflow.Modules.Stock.DocumentNumbers
  alias Letflow.Modules.Stock.Documents
  alias Letflow.Modules.Stock.Documents.Posting
  alias Letflow.Modules.Stock.FormZ2
  alias Letflow.Modules.Stock.FormZ3
  alias Letflow.Modules.Stock.FormZ5
  alias Letflow.Modules.Stock.StockCardSource
  alias Letflow.Modules.Stock.Views
  alias Letflow.Modules.Stock.VoiceService
  alias Letflow.Modules.Stock.XlsxExport

  @ledger "stock"
  @uint ~r/\A(0|[1-9][0-9]{0,14})\z/
  @limit ~r/\A[1-9][0-9]{0,5}\z/
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @slots ~w(sku location org_unit responsible lot)
  @optional_empty ~w(responsible lot)
  @text_filters ~w(cause document_type document_id correlation_id)
  @balance_keys ~w(basis cutoff_seq as_of as_of_date limit cursor format scope_subtree) ++ @slots
  @movement_keys ~w(from_seq to_seq limit cursor format scope_subtree sku) ++ @text_filters
  @card_keys ~w(sku location lot format lang)
  # T-1416/T-1417: the official forms printed from a document: kinds it may print, mapper, file suffix.
  @document_forms %{
    "z2" => {["issue"], &FormZ2.data/2, "_Z-2"},
    "z5" => {["transfer"], &FormZ5.data/2, "_Z-5"}
  }

  authz_get "/balances", :StockRead do
    with_read(conn, fn conn, authorized ->
      with {:ok, params} <- params(conn, @balance_keys),
           {:ok, format} <- format(params),
           {:ok, basis} <- basis(params),
           {:ok, filters} <- slot_filters(params),
           {:ok, filters} <- subtree_filter(params, filters),
           {:ok, page} <- page(params, :text) do
        # Zero-quantity rows stay out of the JSON, the screen and the xlsx (not an HTTP parameter).
        page = Map.put(page, :nonzero, true)

        case read_balances(authorized, basis, filters, page) do
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
           {:ok, filters} <- movement_sku_filter(params, filters),
           {:ok, filters} <- subtree_filter(params, filters),
           {:ok, page} <- page(params, :integer) do
        case Ledger.entries(authorized, filters, page) do
          {:ok, %{rows: rows, next_cursor: next}} ->
            body = %{
              rows:
                DocumentNumbers.put_numbers(
                  authorized.prefix,
                  Enum.map(rows, &Views.stock_movement/1)
                ),
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

  # T-1417 (E5c): the stock card (official form Z-3 / Q-3) of one item at one place, built from the
  # ledger movements the caller may read. Same guard as `/movements`.
  authz_get "/stock-card/print", :StockRead do
    with_read(conn, fn conn, authorized ->
      with {:ok, params} <- params(conn, @card_keys),
           {:ok, format} <- form_format(params["format"]),
           {:ok, lang} <- form_lang(params["lang"]),
           {:ok, filters} <- slot_filters(Map.take(params, ["sku", "location", "lot"])),
           true <- Map.has_key?(filters, "sku") and Map.has_key?(filters, "location"),
           {:ok, card} <-
             StockCardSource.read(
               authorized,
               filters["sku"],
               filters["location"],
               non_empty(filters["lot"])
             ),
           {:ok, bin} <- FormPrint.build("z3", FormZ3.data(card), lang, format) do
        {type, ext} = form_type(format)
        code = card.header.nom |> to_string()

        send_binary(
          conn,
          bin,
          type,
          CountPaperworkSource.file_name("stock-card_#{code}_Z-3", ext)
        )
      else
        {:invalid, reason} -> unprocessable(conn, reason)
        false -> refuse(conn, :invalid_filter)
        {:error, :not_found} -> Response.not_found(conn)
        {:error, :card_too_long} -> unprocessable(conn, "card_too_long")
        {:error, reason} -> form_failure(conn, reason)
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

  authz_post "/documents", :StockPost do
    with_access(conn, :post, fn conn, access ->
      render_document(conn, Documents.save(access.prefix, body(conn), access.actor_id), 201)
    end)
  end

  authz_put "/documents/:id", :StockPost do
    with_access(conn, :post, fn conn, access ->
      result = Documents.replace(access.prefix, conn.params["id"], body(conn), access.actor_id)
      render_document(conn, result, 200)
    end)
  end

  authz_delete "/documents/:id", :StockPost do
    with_access(conn, :post, fn conn, access ->
      case Documents.discard(access.prefix, conn.params["id"], access.actor_id) do
        :ok -> Response.no_content(conn)
        {:error, reason} -> refuse_document(conn, reason)
      end
    end)
  end

  authz_post "/documents/:id/issue", :StockPost do
    with_access(conn, :post, fn conn, access ->
      opts = [activator: Letflow.Api.Context.activator(conn), authorized: read_authorized(conn)]

      render_document(
        conn,
        Documents.issue(access.prefix, conn.params["id"], access.actor_id, opts),
        200
      )
    end)
  end

  authz_post "/documents/:id/check", :StockPost do
    with_access(conn, :post, fn conn, access ->
      case Documents.check(access.prefix, conn.params["id"]) do
        {:ok, result} -> Response.ok(conn, result)
        {:error, reason} -> refuse_document(conn, reason)
      end
    end)
  end

  authz_post "/documents/:id/post", :StockPost do
    with_access(conn, :post, fn conn, access ->
      who = %{actor_id: access.actor_id, activator: Letflow.Api.Context.activator(conn)}
      authorized = read_authorized(conn)
      fetch = fn prefix, id -> Documents.fetch(prefix, id, authorized) end
      render_document(conn, Posting.post(access.prefix, conn.params["id"], who, fetch), 200)
    end)
  end

  authz_post "/documents/:id/reverse", :StockReverse do
    with_access(conn, :reverse, fn conn, access ->
      who = %{actor_id: access.actor_id, activator: Letflow.Api.Context.activator(conn)}
      authorized = read_authorized(conn)
      fetch = fn prefix, id -> Documents.fetch(prefix, id, authorized) end

      result =
        Posting.reverse(access.prefix, conn.params["id"], body(conn), who, authorized, fetch)

      render_document(conn, result, 200)
    end)
  end

  authz_post "/documents/:id/cancel", :StockReverse do
    with_access(conn, :reverse, fn conn, access ->
      authorized = read_authorized(conn)
      fetch = fn prefix, id -> Documents.fetch(prefix, id, authorized) end

      result =
        Posting.cancel(access.prefix, conn.params["id"], body(conn), access.actor_id, fetch)

      render_document(conn, result, 200)
    end)
  end

  authz_get "/documents", :StockRead do
    with_access(conn, :read, fn conn, access ->
      case Documents.list(access.prefix, list_params(conn)) do
        {:ok, page} -> Response.ok(conn, page)
        {:error, reason} -> refuse_document(conn, reason)
      end
    end)
  end

  authz_get "/documents/:id", :StockRead do
    with_access(conn, :read, fn conn, access ->
      authorized = read_authorized(conn)
      render_document(conn, Documents.fetch(access.prefix, conn.params["id"], authorized), 200)
    end)
  end

  # -- voice draft (REQ-741) ----------------------------------------------------------------------

  authz_post "/voice/draft", :StockPost do
    with_access(conn, :post, fn conn, access ->
      voice_render(conn, VoiceService.draft_audio(access.prefix, voice_params(conn)))
    end)
  end

  authz_post "/voice/draft-text", :StockPost do
    with_access(conn, :post, fn conn, access ->
      voice_render(conn, VoiceService.draft_text(access.prefix, voice_params(conn)))
    end)
  end

  # REQ-737: the printed act of an issued transfer, hand over or return; same guard as the read.
  authz_get "/documents/:id/print", :StockRead do
    with_access(conn, :read, fn conn, access ->
      query = query_params(conn)

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

  # -- count orders (REQ-700) ---------------------------------------------------------------------

  authz_post "/counts", :StockCountOrder do
    count_write(conn, :StockCountOrder, 201, fn prefix, opts ->
      Counts.create(prefix, conn.body_params, opts)
    end)
  end

  authz_put "/counts/:id", :StockCountOrder do
    count_write(conn, :StockCountOrder, 200, fn prefix, opts ->
      Counts.update(prefix, conn.params["id"], conn.body_params, opts)
    end)
  end

  authz_post "/counts/:id/issue", :StockCountOrder do
    count_write(conn, :StockCountOrder, 200, fn prefix, opts ->
      if empty_body?(conn),
        do: Counts.issue(prefix, conn.params["id"], opts),
        else: {:error, {:field_not_allowed, first_key(conn.body_params)}}
    end)
  end

  authz_post "/counts/:id/cancel", :StockCountOrder do
    count_write(conn, :StockCountOrder, 200, fn prefix, opts ->
      if empty_body?(conn),
        do: Counts.cancel(prefix, conn.params["id"], opts),
        else: {:error, {:field_not_allowed, first_key(conn.body_params)}}
    end)
  end

  authz_get "/counts", :StockRead do
    count_write(conn, :StockRead, 200, fn prefix, opts ->
      Counts.list(prefix, Plug.Conn.fetch_query_params(conn).query_params, opts)
    end)
  end

  authz_get "/counts/:id", :StockRead do
    count_posting_write(conn, :StockRead, 200, fn prefix, opts ->
      Counts.get(prefix, conn.params["id"], opts)
    end)
  end

  authz_get "/counts/:id/document", :StockRead do
    count_write(conn, :StockRead, 200, fn prefix, opts ->
      Counts.document(prefix, conn.params["id"], opts)
    end)
  end

  # -- count sheet (REQ-701) ----------------------------------------------------------------------

  # `Ledger.authorize/3` is done here; a refusal reaches the module as `authorized: nil` and answers 404.
  authz_post "/counts/:id/open", :StockCountRecord do
    authorized =
      case Ledger.authorize(conn, @ledger, :read) do
        {:ok, authorized} -> authorized
        :error -> nil
      end

    count_write(conn, :StockCountRecord, 200, fn prefix, opts ->
      if empty_body?(conn),
        do: Counts.open(prefix, conn.params["id"], Map.put(opts, :authorized, authorized)),
        else: {:error, {:field_not_allowed, first_key(conn.body_params)}}
    end)
  end

  authz_get "/counts/:id/lines", :StockRead do
    count_write(conn, :StockRead, 200, fn prefix, opts ->
      Counts.lines(prefix, conn.params["id"], query_params(conn), opts)
    end)
  end

  authz_put "/counts/:id/lines/:line_no/count", :StockCountRecord do
    count_write(conn, :StockCountRecord, 200, fn prefix, opts ->
      case conn.body_params do
        %{"_json" => _} ->
          {:error, {:field_invalid, "body"}}

        %{"counted_quantity" => quantity} = body when map_size(body) == 1 ->
          Counts.record_count(prefix, conn.params["id"], conn.params["line_no"], quantity, opts)

        %{} = body when map_size(body) == 0 ->
          {:error, {:field_invalid, "counted_quantity"}}

        %{} = body ->
          {:error, {:field_not_allowed, body |> Map.delete("counted_quantity") |> first_key()}}
      end
    end)
  end

  authz_post "/counts/:id/scan", :StockCountRecord do
    count_write(conn, :StockCountRecord, 200, fn prefix, opts ->
      case conn.body_params do
        %{"_json" => _} -> {:error, {:field_invalid, "body"}}
        body -> Counts.scan(prefix, conn.params["id"], body, opts)
      end
    end)
  end

  authz_post "/counts/:id/surplus-lines", :StockCountRecord do
    count_write(conn, :StockCountRecord, 201, fn prefix, opts ->
      case conn.body_params do
        %{"_json" => _} -> {:error, {:field_invalid, "body"}}
        body -> Counts.add_surplus_line(prefix, conn.params["id"], body, opts)
      end
    end)
  end

  authz_get "/counts/:id/entries", :StockRead do
    count_write(conn, :StockRead, 200, fn prefix, opts ->
      Counts.entries(prefix, conn.params["id"], query_params(conn), opts)
    end)
  end

  authz_post "/counts/:id/close", :StockCountRecord do
    count_write(conn, :StockCountRecord, 200, fn prefix, opts ->
      if empty_body?(conn),
        do: Counts.close_counting(prefix, conn.params["id"], opts),
        else: {:error, {:field_not_allowed, first_key(conn.body_params)}}
    end)
  end

  authz_get "/counts/:id/sheet-document", :StockRead do
    count_write(conn, :StockRead, 200, fn prefix, opts ->
      Counts.sheet_document(prefix, conn.params["id"], opts)
    end)
  end

  # -- signing and the differences sheet (REQ-717) -------------------------------------------------

  authz_post "/counts/:id/sheet-signatures", :StockCountRecord do
    count_write(conn, :StockCountRecord, 200, fn prefix, opts ->
      with {:ok, ids} <- signer_body(conn.body_params) do
        Counts.mark_sheet_signed(prefix, conn.params["id"], ids, opts)
      end
    end)
  end

  authz_post "/counts/:id/differences", :StockCountRecord do
    count_write(conn, :StockCountRecord, 200, fn prefix, opts ->
      if empty_body?(conn),
        do: Counts.issue_differences(prefix, conn.params["id"], opts),
        else: {:error, {:field_not_allowed, first_key(conn.body_params)}}
    end)
  end

  authz_post "/counts/:id/differences-signatures", :StockCountRecord do
    count_write(conn, :StockCountRecord, 200, fn prefix, opts ->
      with {:ok, ids} <- signer_body(conn.body_params) do
        Counts.mark_differences_signed(prefix, conn.params["id"], ids, opts)
      end
    end)
  end

  authz_get "/counts/:id/differences", :StockRead do
    count_write(conn, :StockRead, 200, fn prefix, opts ->
      Counts.differences(prefix, conn.params["id"], opts)
    end)
  end

  # -- posting and reversal of a signed count (REQ-718) --------------------------------------------

  authz_post "/counts/:id/post", :StockPost do
    count_posting_write(conn, :StockPost, 200, fn prefix, opts ->
      if empty_body?(conn),
        do: Counts.post(prefix, conn.params["id"], opts),
        else: {:error, {:field_not_allowed, first_key(conn.body_params)}}
    end)
  end

  authz_post "/counts/:id/reverse", :StockReverse do
    count_posting_write(conn, :StockReverse, 200, fn prefix, opts ->
      Counts.reverse(prefix, conn.params["id"], body(conn), opts)
    end)
  end

  authz_post "/counts/:id/posting-record", :StockCountRecord do
    count_posting_write(conn, :StockCountRecord, 200, fn prefix, opts ->
      if empty_body?(conn),
        do: Counts.issue_posting_record(prefix, conn.params["id"], opts),
        else: {:error, {:field_not_allowed, first_key(conn.body_params)}}
    end)
  end

  authz_get "/counts/:id/posting-document", :StockRead do
    count_posting_write(conn, :StockRead, 200, fn prefix, opts ->
      Counts.posting_document(prefix, conn.params["id"], opts)
    end)
  end

  authz_get "/counts/:id/signatures", :StockRead do
    count_write(conn, :StockRead, 200, fn prefix, opts ->
      Counts.signatures(prefix, conn.params["id"], opts)
    end)
  end

  # REQ-719: the count paperwork as xlsx, rendered from the issued document version.
  @paperwork_kinds %{"order" => :order, "sheet" => :sheet, "differences" => :differences}

  authz_get "/counts/:id/paperwork/:kind", :StockRead do
    case Map.fetch(@paperwork_kinds, conn.params["kind"]) do
      {:ok, kind} -> paperwork(conn, kind)
      :error -> Response.not_found(conn)
    end
  end

  # REQ-736: the same three documents as an A4 PDF, same read path as the xlsx.
  @print_langs %{"ru" => :ru, "kk" => :kk, "en" => :en}

  authz_get "/counts/:id/print/:kind", :StockRead do
    with {:ok, kind} <- Map.fetch(@paperwork_kinds, conn.params["kind"]),
         {:ok, lang} <- print_lang(query_params(conn)["lang"]) do
      print(conn, kind, lang)
    else
      :error -> Response.not_found(conn)
      :invalid_lang -> unprocessable(conn, "invalid_lang")
    end
  end

  authz_unmatched(:ordinary)

  # -- document handlers ---------------------------------------------------------------------------

  defp with_access(conn, purpose, fun) do
    case Access.check(conn, purpose) do
      {:ok, access} -> fun.(conn, access)
      :error -> Response.not_found(conn)
    end
  end

  # The ledger read authorization of the caller (tenant-wide: `Access` has proved it) for
  # `posting_check`; `nil` when the ledger refuses, and the check is then `nil` too.
  defp read_authorized(conn) do
    case Ledger.authorize(conn, @ledger, :read) do
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
  defp body(conn) do
    case conn.body_params do
      %{"_json" => _} -> :not_an_object
      %Plug.Conn.Unfetched{} -> :not_an_object
      params -> params
    end
  end

  defp voice_params(conn) do
    case body(conn) do
      %{} = params when not is_struct(params) -> params
      _ -> :not_an_object
    end
  end

  defp voice_render(conn, {:ok, body}), do: Response.ok(conn, body)
  defp voice_render(conn, {:error, :not_found}), do: Response.not_found(conn)

  defp voice_render(conn, {:error, {:refuse, status, reason, extras}}) do
    problem = voice_problem(status)
    Response.send_problem(conn, %{problem | extensions: Map.put(extras, "reason", reason)})
  end

  defp voice_render(conn, {:error, _internal}), do: Response.internal_error(conn)

  defp voice_problem(413), do: Error.payload_too_large("request refused")
  defp voice_problem(415), do: Error.unsupported_media_type("request refused")
  defp voice_problem(422), do: Error.unprocessable("request refused")
  defp voice_problem(502), do: Error.bad_gateway("upstream provider failed")
  defp voice_problem(503), do: Error.service_unavailable("request refused")
  defp voice_problem(504), do: Error.gateway_timeout("upstream provider timed out")

  defp render_document(conn, {:ok, document}, status),
    do: Response.send_json(conn, status, document)

  defp render_document(conn, {:error, reason}, _status), do: refuse_document(conn, reason)

  defp refuse_document(conn, :not_found), do: Response.not_found(conn)

  defp refuse_document(conn, :document_not_draft),
    do: problem(conn, Error.conflict("request refused"), "document_not_draft")

  @conflicts ~w(document_not_issued document_cancelled document_posted posting_pending
                document_not_posted document_reversed reversal_pending posting_inconsistent
                definition_not_active external_ref_taken)a

  defp refuse_document(conn, reason) when reason in @conflicts,
    do: problem(conn, Error.conflict("request refused"), Atom.to_string(reason))

  defp refuse_document(conn, :reason_invalid), do: unprocessable(conn, "reason_invalid")

  defp refuse_document(conn, {:unprocessable, reason}) when is_atom(reason),
    do: unprocessable(conn, Atom.to_string(reason))

  defp refuse_document(conn, :busy),
    do: problem(conn, Error.service_unavailable("request refused"), "busy")

  defp refuse_document(conn, :invalid_filter), do: unprocessable(conn, "invalid_filter")

  defp refuse_document(conn, {reason, extras}) when is_binary(reason) and is_map(extras) do
    problem = Error.unprocessable("request refused")
    Response.send_problem(conn, %{problem | extensions: Map.put(extras, "reason", reason)})
  end

  defp refuse_document(conn, _internal), do: Response.internal_error(conn)

  # -- count order handlers (REQ-700) -------------------------------------------------------------

  # The tenant is `scoped_opts`, the actor `auth_context.user_id`, the scope is the caller's allowed
  # set for `permission`, computed here and not through ScopeGate (which answers :all when the
  # tenant's enforcement mode is not `on`). A scope that cannot be computed fails closed as 404.
  defp count_write(conn, permission, status, fun) do
    prefix = Keyword.fetch!(conn.assigns.scoped_opts, :prefix)

    with {:ok, actor} <- Ecto.UUID.cast(conn.assigns.auth_context.user_id),
         {:ok, conn, principal} <- Scope.principal_from_conn(conn),
         {:ok, scope} <- allowed_set(principal, permission) do
      render(conn, fun.(prefix, %{actor_id: actor, scope: scope}), status)
    else
      :none -> Response.not_found(conn)
      _ -> Response.send_problem(conn, Error.forbidden("not permitted"))
    end
  end

  # REQ-718: `count_write/4` plus the request's activator and ledger read authorization, which the
  # posting, the reversal and the posting check on the count view need.
  defp count_posting_write(conn, permission, status, fun) do
    extra = %{activator: Letflow.Api.Context.activator(conn), authorized: read_authorized(conn)}

    count_write(conn, permission, status, fn prefix, opts ->
      fun.(prefix, Map.merge(opts, extra))
    end)
  end

  # REQ-719: the same prologue as `count_write/4`, answering a workbook instead of JSON.
  defp paperwork(conn, kind) do
    with_paperwork_ctx(conn, fn prefix, ctx ->
      case CountPaperworkSource.fetch(prefix, conn.params["id"], kind, ctx) do
        {:ok, binary, name} ->
          send_xlsx(conn, binary, name)

        {:error, :not_found} ->
          Response.not_found(conn)

        {:error, :document_not_issued} ->
          unprocessable(conn, "document_not_issued")

        {:error, :xlsx_write_failed} ->
          Logger.error("stock paperwork xlsx write failed")
          Response.internal_error(conn)
      end
    end)
  end

  # REQ-736: the PDF of the same issued document; `read/4` is the one scope and name path.
  defp print(conn, kind, lang) do
    with_paperwork_ctx(conn, fn prefix, ctx ->
      with {:ok, %{issued: issued, names: names}} <-
             CountPaperworkSource.read(prefix, conn.params["id"], kind, ctx),
           {:ok, pdf} <- CountPrint.build(kind, issued, names, lang) do
        send_pdf(conn, pdf, CountPaperworkSource.file_name(issued.number_label, "pdf"))
      else
        {:error, :not_found} ->
          Response.not_found(conn)

        {:error, :document_not_issued} ->
          unprocessable(conn, "document_not_issued")

        {:error, :unsupported_glyph} ->
          unprocessable(conn, "print_unsupported_character")

        {:error, {:render_failed, rules}} ->
          Logger.error(
            "stock count print render failed: " <> Enum.map_join(rules, ",", &inspect/1)
          )

          Response.internal_error(conn)
      end
    end)
  end

  defp print_document(conn, prefix, lang) do
    tenant_id = conn.assigns |> Map.get(:auth_context, %{}) |> Map.get(:tenant_id)

    with {:ok, %{issued: issued, names: names}} <-
           DocumentPrintSource.read(prefix, conn.params["id"], tenant_id),
         {:ok, pdf} <- DocumentPrint.build(issued, names, lang) do
      send_pdf(conn, pdf, CountPaperworkSource.file_name(issued.number_label, "pdf"))
    else
      {:error, :not_found} ->
        Response.not_found(conn)

      {:error, reason} when reason in [:print_not_available, :document_not_issued] ->
        unprocessable(conn, Atom.to_string(reason))

      {:error, :unsupported_glyph} ->
        unprocessable(conn, "print_unsupported_character")

      {:error, {:render_failed, rules}} ->
        Logger.error(
          "stock document print render failed: " <> Enum.map_join(rules, ",", &inspect/1)
        )

        Response.internal_error(conn)
    end
  end

  # T-1416/T-1417: `?form=z2|z5&format=pdf|docx&lang=ru|kk`, the official form Z-2 / Q-2 of an issued
  # `issue` or Z-5 / Q-5 of an issued `transfer`.
  defp print_form(conn, prefix, query) do
    with {:ok, form} <- form_param(query["form"]),
         {:ok, format} <- form_format(query["format"]),
         {:ok, lang} <- form_lang(query["lang"]) do
      {kinds, mapper, suffix} = Map.fetch!(@document_forms, form)
      tenant_id = conn.assigns |> Map.get(:auth_context, %{}) |> Map.get(:tenant_id)

      with {:ok, %{issued: issued, names: names}} <-
             DocumentPrintSource.read(prefix, conn.params["id"], tenant_id,
               kinds: kinds,
               legal_entities: true
             ),
           {:ok, bin} <- FormPrint.build(form, mapper.(issued, names), lang, format) do
        {type, ext} = form_type(format)
        name = CountPaperworkSource.file_name(to_string(issued.number_label) <> suffix, ext)
        send_binary(conn, bin, type, name)
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
    Logger.error("stock form print render failed: " <> Enum.map_join(rules, ",", &inspect/1))
    Response.internal_error(conn)
  end

  defp form_failure(conn, :invalid_filter), do: refuse(conn, :invalid_filter)
  defp form_failure(conn, _internal), do: Response.internal_error(conn)

  defp non_empty(""), do: nil
  defp non_empty(value), do: value

  defp form_param(form) when form in ["z2", "z5"], do: {:ok, form}
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

  defp print_lang(nil), do: {:ok, :ru}

  defp print_lang(lang) when is_binary(lang) do
    case Map.fetch(@print_langs, lang) do
      {:ok, l} -> {:ok, l}
      :error -> :invalid_lang
    end
  end

  defp print_lang(_), do: :invalid_lang

  defp with_paperwork_ctx(conn, fun) do
    prefix = Keyword.fetch!(conn.assigns.scoped_opts, :prefix)

    with {:ok, _actor} <- Ecto.UUID.cast(conn.assigns.auth_context.user_id),
         {:ok, conn, principal} <- Scope.principal_from_conn(conn),
         {:ok, scope} <- allowed_set(principal, :StockRead) do
      ctx = %{scope: scope, principal: principal, tenant_id: conn.assigns.auth_context.tenant_id}
      fun.(prefix, ctx)
    else
      :none -> Response.not_found(conn)
      _ -> Response.send_problem(conn, Error.forbidden("not permitted"))
    end
  end

  defp allowed_set(principal, permission) do
    case Scope.allowed_set(principal, permission) do
      {:ok, :none} -> :none
      {:ok, scope} -> {:ok, scope}
    end
  rescue
    Scope.ScopeSetError -> :none
  end

  # The body is exactly `signer_employee_ids`; the shape of the value is checked in the context.
  defp signer_body(%{"signer_employee_ids" => ids} = body) when map_size(body) == 1,
    do: {:ok, ids}

  defp signer_body(%{"signer_employee_ids" => _} = body),
    do: {:error, {:field_not_allowed, body |> Map.delete("signer_employee_ids") |> first_key()}}

  defp signer_body(_), do: {:error, {:field_invalid, "signer_employee_ids"}}

  defp query_params(conn), do: Plug.Conn.fetch_query_params(conn).query_params

  defp empty_body?(conn), do: conn.body_params in [%{}, nil]

  defp first_key(%{} = body), do: body |> Map.keys() |> Enum.sort() |> List.first() |> to_string()
  defp first_key(_), do: "body"

  defp render(conn, {:ok, body}, status), do: Response.send_json(conn, status, body)
  defp render(conn, {:error, :not_found}, _status), do: Response.not_found(conn)

  # REQ-716: an unknown code and a location outside the count look the same as an unknown count id.
  defp render(conn, {:error, :code_unknown}, _status), do: Response.not_found(conn)
  defp render(conn, {:error, :audit_failed}, _status), do: Response.internal_error(conn)
  defp render(conn, {:error, :internal}, _status), do: Response.internal_error(conn)

  defp render(conn, {:error, {:unprocessable, reason}}, _status) when is_atom(reason),
    do: unprocessable(conn, Atom.to_string(reason))

  # REQ-718: the refusals that are a conflict of state, not an invalid request.
  @count_conflicts ~w(posting_pending count_posted count_not_posted count_reversed reversal_pending
                      posting_inconsistent definition_not_active posting_record_exists)a

  defp render(conn, {:error, reason}, _status) when reason in @count_conflicts,
    do: problem(conn, Error.conflict("request refused"), Atom.to_string(reason))

  defp render(conn, {:error, {:field_not_allowed, key}}, _status) when is_binary(key),
    do:
      problem(conn, Error.unprocessable("request refused"), "field_not_allowed", %{"field" => key})

  defp render(conn, {:error, {:shortage_exceeds_balance, details}}, _status) when is_map(details),
    do: problem(conn, Error.unprocessable("request refused"), "shortage_exceeds_balance", details)

  defp render(conn, {:error, {:field_invalid, key}}, _status) when is_binary(key),
    do: problem(conn, Error.unprocessable("request refused"), "field_invalid", %{"field" => key})

  defp render(conn, {:error, reason}, _status) when is_atom(reason),
    do: unprocessable(conn, Atom.to_string(reason))

  defp render(conn, {:error, term}, _status) do
    Logger.warning("stock count request refused: #{inspect(elem_tag(term))}")
    unprocessable(conn, "request_refused")
  end

  defp elem_tag(term) when is_tuple(term) and tuple_size(term) > 0, do: elem(term, 0)
  defp elem_tag(_term), do: :other

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

  defp send_pdf(conn, binary, name), do: send_binary(conn, binary, "application/pdf", name)

  defp send_binary(conn, binary, type, name) do
    conn
    |> Plug.Conn.put_resp_content_type(type, nil)
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
    body = balances_body_base(report)

    if Map.has_key?(report, :as_of_date),
      do: Map.put(body, :as_of_date, report.as_of_date),
      else: body
  end

  defp balances_body_base(report) do
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

  # REQ-704: `as_of_date=YYYY-MM-DD` reads the balance at the end of that day in the tenant time
  # zone; `cutoff_seq` is optional (absent: `:latest`, stated in the answer); it excludes `basis`
  # and `as_of`. Assumption, owner may change at GATE B.
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

  # `sku` narrows the movements to entries with a leg on that item (the core `leg_slots` filter).
  defp movement_sku_filter(params, filters) do
    case Map.fetch(params, "sku") do
      :error ->
        {:ok, filters}

      {:ok, value} ->
        if Regex.match?(@uuid, value),
          do: {:ok, Map.put(filters, "leg_slots", %{"sku" => value})},
          else: {:error, :invalid_filter}
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
  defp refuse(conn, :as_of_date_in_future), do: unprocessable(conn, "as_of_date_in_future")
  defp refuse(conn, :invalid_timezone), do: unprocessable(conn, "invalid_timezone")
  defp refuse(conn, :run_expired), do: unprocessable(conn, "run_expired")
  defp refuse(conn, _invalid), do: unprocessable(conn, "invalid_filter")

  defp unprocessable(conn, reason),
    do: problem(conn, Error.unprocessable("request refused"), reason)

  defp problem(conn, problem, reason, extra \\ %{}),
    do: Response.send_problem(conn, %{problem | extensions: Map.put(extra, "reason", reason)})
end
