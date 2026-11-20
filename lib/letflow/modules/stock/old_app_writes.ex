defmodule Letflow.Modules.Stock.OldAppWrites do
  @moduledoc """
  REQ-860 (decision 0091 sections 5, 7 and 11b): the two write calls of the old Qoimeks app, the
  movement post and the movement reverse, answered in the Qoimeks shape. Each call writes and posts
  ONE stock document through the same functions a personal account uses (`Documents.save/4`,
  `Documents.issue/4`, the posting task of `Posting`, `Posting.reverse/6`), so the ledger rules
  (append-only, one reversal, the master checks, the freeze guard, the negative-balance setting of the
  tenant) apply unchanged.

  The caller is the shared stock access of one tenant: its `actor_id` (the synthetic actor of the
  credential row, not a user) is the actor of every step, and the posting task is completed with the
  credential kind `:shared_access`, which `Letflow.Ledger.Authority` accepts for the stock ledger
  and `StockPost` / `StockReverse` only, after reading now that the actor's credential is not revoked.
  The router (`Letflow.Routers.SharedStockAccess`) proved the credential; the tenant is the `prefix`
  argument and nothing else (INV-1).

  ## The operator name (section 5)

  Required on every write, from the body field `operator` or else the `X-Operator` header; trimmed;
  1 to #{200} characters, valid UTF-8 without control characters; otherwise `{:error, {400, text}}` and
  nothing is written. It is stored as the output variable `operator` of the completed `post` or
  `reverse` task, and `Posting.state_fields/3` and the movements read show it only when the task was
  completed by a shared access actor of the tenant.

  ## What the old app does not send, and what is filled in (assumptions, owner may change)

  * The org unit of a place is the first active org unit linked to it (`Locations.org_unit_ids_for_location/2`);
    a place with none is refused `location_not_linked` (422).
  * The responsible employee is the first active employee of the tenant (`Org.first_active_employee_id/1`);
    none is refused `no_responsible_employee` (422).
  * The event time is now. The item's unit is its base unit of measure.
  * A balance below zero: the negative-balance setting and the freeze guard refuse as they do for a
    personal account. Kind `adjustment` is the count, see "The count" below.
  * Untouched module-owned process drafts are activated on first use by the internal stock activator
    (`Posting.ensure_active/3`); the shared access needs no admin activation step. Tenant-created,
    changed or deprecated definitions are refused `definition_not_active` (409) before a number is taken.

  ## The client operation id (T-2282, decision 0091 "Retry by client id")

  Both writes REQUIRE the body field `id` (constant `@client_id_field`), a UUID string the phone makes
  once per operation and sends again unchanged on every retry (also from its offline queue). Missing or
  not a UUID is `{:error, {400, "id is required"}}` and nothing is written. The id is unique per tenant:
  it is bound, in the tenant's `stock_create_idempotency` table (primary key = the namespaced key
  `client:stock_old_movement:<id>`, the table of `ActionIdempotency`), to the document and to a hash of
  the COMPARED data, only after the whole post (document, issue and posting task) succeeded, under a
  per-key advisory lock held for the whole call.

  * First use: the post runs; the answer is `{:ok, row, :created}` (201).
  * A repeat with the same id and equal data (post: kind, sku, place, destination place, quantity,
    compared as numbers; NOT operator; reverse: the original movement) writes nothing and answers the
    STORED row `{:ok, row, :replayed}` (200); stock is not doubled. A concurrent duplicate waits on the
    lock and then replays, so one document and one set of balances result.
  * The same id with other data, an id that belongs to a reversal used for a post (or the reverse), or
    a post id used for a reverse: `{:error, {409, "this operation was already posted with different data"}}`
    (the `idempotency_key_reuse` of `ActionIdempotency`), nothing changed.
  * A reversal takes its own new id. REQ-909: the refusals of the old server, as 400 (the old app shows
    every 409 as "already posted"): the original already reversed by ANOTHER id is
    `{:error, {400, "already reversed"}}`, a reversal cannot be reversed
    `{:error, {400, "a reversal cannot be reversed; post a new operation instead"}}`, and a quantity that
    is zero or negative `{:error, {400, "quantity must be positive"}}` (`"invalid quantity"` stays for a
    value that is not a number). Nothing is written.

  ## The count (REQ-912, K6a; decision 0091 section 9 amended by the PM decision of 2026-11-20)

  Kind `adjustment`: the storekeeper types the counted number (`qty`, a JSON number or decimal text, 0
  or more, at most 9 decimals; a negative one is `{:error, {400, "quantity must be positive"}}`, and
  receipt, issue and transfer keep refusing 0). The old server REPLACED the balance at once; here the
  count is a quick count document (`Documents.quick_count/4`, the shared access actor is the counter,
  the typed operator name is the output variable `operator` of its submit task, the reason code is
  `recount`). The org unit, the responsible and the unit are filled in as for the other writes.

  The tenant's four-eyes switch for counts decides (the approval rule of process `stock_quick_count`,
  step `approve`, `Letflow.ApprovalRules.four_eyes_off?/3`):

  * Stored `four_eyes: false` (OFF): in the same call the shared access completes the approve task of
    its own count (credential `:shared_access`, the one step `Letflow.Engine.SeparationOfDuties` lets
    it self-approve; the engine writes `task.self_approved`, "self-approved, four-eyes off", with the
    shared access actor), so the count posts cause `count_set` and the balance becomes the counted
    quantity. The answer is the count's movement row (kind `adjustment`, `qty` = the counted quantity,
    `balances` = one entry, the balance after the posting). A count equal to the book starts no process
    and writes no ledger entry: it is answered at once with its row from `OldAppReads.confirmed_count_row/2`
    (an `id` of the document, `operator` `""`), is not in the movement history, and its repeat answers
    the same row (the `balances` of the replay is the balance at that moment).
  * No row, a row `true` or an unreadable setting (ON, REQ-913, K6b): the count is made exactly as above
    and the shared access does NOT complete approve. The answer is
    `{:error, {400, "Подсчёт принят и ждёт подтверждения администратора"}}`; the count document stays
    issued with one pending approve task in My Tasks of a user who holds `StockApprove` (the tenant
    administrator, not the storekeeper). One administrator is enough: the counter is the shared access
    actor, so `distinct_from submit` passes and no `task.self_approved` is written. The balance does not
    change and the count is not in the movement history until it is approved. If the key moves before the
    approval, the approval is refused `quick_count_stale`, the task stays pending, and the administrator
    cancels the count document (`POST /documents/:id/cancel`, `StockReverse`). A count equal to the book
    is answered at once (201), as above.

  The client id of a waiting count is bound to its document (a waiting count is a success of the call,
  not a refusal), under the same per-key lock and compared data. A repeat with the same id and data never
  makes a second count; it answers from the state of the count document: approval pending, the same
  waiting 400; posted (or confirmed), 200 with the count's movement row (`qty` = the counted quantity,
  `operator` = the typed name, `balances` as of that moment); cancelled, 400 "Подсчёт отменён. Посчитайте
  ещё раз". The same id with other data is the 409 of every write. A refusal when the count is made
  (below) binds no id.

  Every refusal of a count is a 400 (the old app reads a 409 as "already posted" and a 422 as "heard
  nothing"), with the old server's Russian texts: `count_in_progress` "На этом месте идёт пересчёт по
  приказу. Подсчёт не принят", `location_frozen` (at the approval) "Место заморожено пересчётом. Подсчёт
  не принят", `balance_in_other_rows` "Этот товар на этом месте числится за другим ответственным или в
  другой партии. Попросите администратора провести пересчёт по ведомости", `quick_count_stale` "Остаток
  изменился, пока подсчёт ждал подтверждения. Посчитайте ещё раз", and for any other refusal of the
  approval "Подсчёт отменён. Посчитайте ещё раз". A refusal at the approval cancels the issued count
  (`undo/4`), so nothing is left pending and no balance changes; a refusal binds no client id. The client
  id of a count is bound and compared (kind, item, place, quantity) exactly as for the other writes.
  A test seam (`:old_app_count_between` in the application environment, set only by tests) runs a
  function between the issue and the approval of a count.

  ## The answer (REQ-909)

  Both writes answer the Qoimeks movement row of `Letflow.Modules.Stock.OldAppReads` (text `id`, old
  `kind`, codes, `unit`, `qty`, `operator`, `created_at`, `reverses` on a reversal) with `balances`: one
  entry per item and place the movement touched, read after the posting at the movement's own posting
  number, so a 200 replay is the stored row with the same values. The reversal row is the row of the
  document that carries `reverses`; the post row is the one without.
  * A refused request binds nothing, so the same id can be sent again after the cause is fixed.

  Refusals are `{:error, {status, text}}`; the text is a closed code, never a value. A failed posting
  leaves no half document: a refused issue discards the draft, a refused ledger posting cancels the
  issued document (a receipt cannot be cancelled while its post task is pending, so a refused receipt
  stays issued; the refusal of a receipt is not a realistic ledger refusal) and a refused reversal
  withdraws its instance.
  """

  require Logger

  alias Letflow.ApprovalRules
  alias Letflow.Engine
  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Org
  alias Letflow.Modules.Stock.Documents
  alias Letflow.Modules.Stock.Documents.ActionIdempotency
  alias Letflow.Modules.Stock.Documents.Kinds
  alias Letflow.Modules.Stock.Documents.Posting
  alias Letflow.Modules.Stock.OldAppReads
  alias Letflow.SharedStockAccess.IntIds

  @operator_max 200
  # The request-body field of the client operation id (the old Qoimeks protocol: `id`, a UUID string).
  @client_id_field "id"
  @client_id ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
  @key_prefix "client:stock_old_movement:"
  @reuse_text "this operation was already posted with different data"
  @kinds ~w(receipt issue transfer adjustment)
  # REQ-912: the count at the old address (kind adjustment). The reason code is `recount` (UAT
  # assumption A2 of the T-2378 note, to be confirmed by the process owner); the switch is the tenant's
  # approval rule of the quick count, step approve.
  @count_reason "recount"
  @count_definition "stock_quick_count"
  @count_node "approve"
  # The old server's own words and the old app's reading of the status (REQ-912 point 7): every
  # refusal of a count is a 400 with a text; a 409 would read as "already posted", a 422 as "heard nothing".
  @count_texts %{
    "count_in_progress" => "На этом месте идёт пересчёт по приказу. Подсчёт не принят",
    "location_frozen" => "Место заморожено пересчётом. Подсчёт не принят",
    "balance_in_other_rows" =>
      "Этот товар на этом месте числится за другим ответственным или в другой партии. " <>
        "Попросите администратора провести пересчёт по ведомости",
    "quick_count_stale" =>
      "Остаток изменился, пока подсчёт ждал подтверждения. Посчитайте ещё раз"
  }
  @count_cancelled "Подсчёт отменён. Посчитайте ещё раз"
  # REQ-913: the answer of a count that waits for the administrator. A 400, as every answer of a count
  # that is not a movement: the phone shows «Ошибка: <text>» and keeps the form filled.
  @count_waiting "Подсчёт принят и ждёт подтверждения администратора"
  @quantity_max 40
  @quantity ~r/\A(0|[1-9][0-9]{0,14})(\.[0-9]{1,9})?\z/

  @type result ::
          {:ok, map(), :created | :replayed} | {:error, {pos_integer(), String.t()}}

  @doc "The client operation id of a write: `{:ok, key}` (the namespaced key) or the 400 refusal."
  @spec client_key(term()) :: {:ok, String.t()} | {:error, {400, String.t()}}
  def client_key(params) do
    value = if is_map(params), do: Map.get(params, @client_id_field), else: nil

    if is_binary(value) and Regex.match?(@client_id, value),
      do: {:ok, @key_prefix <> String.downcase(value)},
      else: {:error, {400, "id is required"}}
  end

  @doc "The operator name of a write: `{:ok, name}` or the 400 refusal (see the moduledoc)."
  @spec operator(map(), String.t() | nil) :: {:ok, String.t()} | {:error, {400, String.t()}}
  def operator(params, header) do
    value = if is_map(params), do: Map.get(params, "operator") || header, else: header

    with true <- is_binary(value),
         true <- String.valid?(value),
         name = String.trim(value),
         true <- name != "",
         false <- String.match?(name, ~r/[\x00-\x1F\x7F]/u) do
      if String.length(name) <= @operator_max,
        do: {:ok, name},
        else: {:error, {400, "operator too long"}}
    else
      _missing -> {:error, {400, "operator required"}}
    end
  end

  @doc """
  The movement post. `actor_id` is the credential's actor, `authorized` the tenant-wide ledger read
  value of the shared access, `params` the decoded JSON body, `header` the `X-Operator` value or nil.
  `{:ok, movement, :created}` (the Qoimeks movement fields) answers 201, `{:ok, movement, :replayed}`
  (the stored movement of a repeated client id) answers 200; see the moduledoc.
  """
  @spec post_movement(String.t(), String.t(), map(), term(), String.t() | nil) :: result()
  def post_movement(prefix, actor_id, authorized, params, header) do
    with {:ok, key} <- client_key(params),
         {:ok, operator} <- operator(params, header),
         {:ok, movement} <- movement_params(prefix, params) do
      bound(
        prefix,
        key,
        movement_hash(movement),
        &replay_post(prefix, authorized, movement.kind, &1),
        fn ->
          if movement.kind == "adjustment",
            do: post_count(prefix, actor_id, authorized, movement, operator),
            else: post_document(prefix, actor_id, authorized, movement, operator)
        end
      )
    end
  rescue
    exception ->
      Logger.error("old_app_post_failed #{inspect(exception.__struct__)}")
      {:error, {500, "internal error"}}
  end

  # The receipt, issue and transfer: one document, issued and posted by the shared access.
  defp post_document(prefix, actor_id, authorized, movement, operator) do
    with :ok <- active(prefix, movement.kind),
         {:ok, body} <- document_body(prefix, movement),
         {:ok, view} <- save(prefix, body, actor_id),
         {:ok, _issued} <- issue(prefix, view.id, actor_id, authorized),
         :ok <- complete(prefix, view, "post", actor_id, operator),
         {:ok, row} <- stored(authorized, view.id, :post) do
      {:ok, view.id, row}
    end
  end

  # -- the count (REQ-912) ------------------------------------------------------------------------

  # A quick count document made through `Documents.quick_count/4` with the shared access as the counter.
  # The tenant's four-eyes switch for counts decides what happens next (REQ-912, REQ-913): OFF, the
  # shared access completes the approve task of its own count in the same call (the engine records
  # `task.self_approved`); ON, the count is left issued with its approve task pending for one
  # administrator in My Tasks and the call answers the waiting 400 (a waiting count is a success of the
  # call, so its client id is bound to it). A count equal to the book is `confirmed`: it needs no
  # approval and is answered at once under either switch.
  defp post_count(prefix, actor_id, authorized, movement, operator) do
    off? = ApprovalRules.four_eyes_off?(prefix, @count_definition, @count_node)

    with :ok <- count_active(prefix),
         {:ok, body} <- count_body(prefix, movement),
         {:ok, view} <- make_count(prefix, body, actor_id, authorized, operator),
         {:ok, outcome} <- settle_count(prefix, view, off?, actor_id, operator) do
      case outcome do
        :posted ->
          with {:ok, row} <- stored(authorized, view.id, :post), do: {:ok, view.id, row}

        :waiting ->
          {:ok, view.id, :waiting}
      end
    end
  end

  # Confirmed (equal to the book): nothing to approve. Switch OFF: the shared access approves now.
  # Switch ON (no row, a row `true` or an unreadable setting: fails closed): the count waits.
  defp settle_count(_prefix, %{state: "confirmed"}, _off?, _actor_id, _operator),
    do: {:ok, :posted}

  defp settle_count(prefix, view, true, actor_id, operator) do
    :ok = count_seam(prefix)

    with :ok <- approve_count(prefix, view, actor_id, operator), do: {:ok, :posted}
  end

  defp settle_count(_prefix, _view, false, _actor_id, _operator), do: {:ok, :waiting}

  # What a repeat of a bound client id answers (REQ-913 point 2): a count answers from the state of its
  # document and never makes a second one. Approval pending is the waiting 400, a cancelled count the
  # cancelled 400, a posted (or confirmed) one its stored row (200). The other kinds answer their row.
  defp replay_post(prefix, authorized, "adjustment", document_id) do
    case Documents.fetch(prefix, document_id) do
      {:ok, %{state: "issued"}} -> {:error, {400, @count_waiting}}
      {:ok, %{state: "cancelled"}} -> {:error, {400, @count_cancelled}}
      {:ok, _posted} -> stored(authorized, document_id, :post)
      {:error, _reason} -> {:error, {500, "internal error"}}
    end
  end

  defp replay_post(_prefix, authorized, _kind, document_id),
    do: stored(authorized, document_id, :post)

  # Test seam, like `:stock_post_start_fail?` of `Posting`: a function in the application environment
  # (set only by tests) runs between the issue of the count and its approval, so a test can move the
  # key or open a count order inside the call. Never set outside tests; read here only.
  defp count_seam(prefix) do
    case Application.get_env(:letflow, :old_app_count_between) do
      fun when is_function(fun, 1) ->
        fun.(prefix)
        :ok

      _none ->
        :ok
    end
  end

  defp count_active(prefix) do
    case Posting.ensure_active(prefix, Kinds.get("quick_count").definition, nil) do
      :ok -> :ok
      :error -> {:error, {400, "definition_not_active"}}
    end
  end

  defp count_body(prefix, movement) do
    with {:ok, item} <- item(prefix, movement.sku),
         {:ok, unit} <- org_unit(prefix, movement.location),
         {:ok, employee} <- employee(prefix) do
      {:ok,
       %{
         "org_unit_id" => unit,
         "location_id" => movement.location,
         "responsible_id" => employee,
         "catalog_item_id" => movement.sku,
         "catalog_uom_id" => item["base_uom_id"],
         "counted_quantity" => movement.quantity,
         "reason_code" => @count_reason
       }}
    end
  end

  defp make_count(prefix, body, actor_id, authorized, operator) do
    case Documents.quick_count(prefix, body, actor_id, authorized: authorized, operator: operator) do
      {:ok, view} -> {:ok, view}
      {:error, reason} -> {:error, count_refusal(reason)}
    end
  end

  # A count equal to the book is `confirmed`: no approval, no ledger entry (REQ-912 point 6).
  defp approve_count(_prefix, %{state: "confirmed"}, _actor_id, _operator), do: :ok

  defp approve_count(prefix, view, actor_id, operator) do
    case complete(prefix, view, "approve", actor_id, operator) do
      :ok ->
        :ok

      # The approval was never started: nothing may stay issued and pending.
      {:error, {503, _text}} ->
        undo(prefix, view.id, "approve", actor_id)
        {:error, {400, @count_cancelled}}

      # `complete/5` already cancelled the issued count; the text is the old server's for the cause
      # (the freeze guard, a key that moved), else the cancel text.
      {:error, {_status, wire}} ->
        {:error, {400, Map.get(@count_texts, wire, @count_cancelled)}}
    end
  end

  # A refusal when the count is made: the old server's text for the known ones, else the closed
  # code of the refusal (never a value), always a 400.
  defp count_refusal({code, _extras}) when is_binary(code),
    do: {400, Map.get(@count_texts, code, code)}

  defp count_refusal(:definition_not_active), do: {400, "definition_not_active"}
  defp count_refusal(reason), do: refusal(reason)

  @doc """
  The movement reverse of the movement whose Qoimeks integer id is `int_id` (the path). `{:ok,
  movement, :created}` is the reversal's own movement row (201); the same reversal `id` again answers
  its stored row `{:ok, row, :replayed}` (200); reversing the original under another id, or reversing a
  reversal, is a 409. See the moduledoc.
  """
  @spec reverse_movement(String.t(), String.t(), map(), term(), term(), String.t() | nil) ::
          result()
  def reverse_movement(prefix, actor_id, authorized, int_id, params, header) do
    with {:ok, key} <- client_key(params),
         {:ok, operator} <- operator(params, header),
         {:ok, entry} <- entry_of(prefix, authorized, int_id),
         :ok <- not_a_reversal(entry) do
      bound(
        prefix,
        key,
        hash(["reverse", entry.document_id]),
        &stored(authorized, &1, :reversal),
        fn ->
          with {:ok, _view} <- reverse(prefix, actor_id, authorized, entry.document_id),
               :ok <-
                 complete(prefix, %{id: entry.document_id}, "reverse", actor_id, operator),
               {:ok, row} <- stored(authorized, entry.document_id, :reversal) do
            {:ok, entry.document_id, row}
          end
        end
      )
    end
  rescue
    exception ->
      Logger.error("old_app_reverse_failed #{inspect(exception.__struct__)}")
      {:error, {500, "internal error"}}
  end

  # -- the client operation id -----------------------------------------------------------------------

  defp bound(prefix, key, hash, replay, action) do
    case ActionIdempotency.run_bound(prefix, key, hash, replay, action) do
      # A waiting count (REQ-913) is a success of the call, bound to its id, answered as a refusal text.
      {:ok, _how, :waiting} -> {:error, {400, @count_waiting}}
      {:ok, how, row} -> {:ok, row, how}
      {:error, :idempotency_key_reuse} -> {:error, {409, @reuse_text}}
      {:error, {status, _text}} = refusal when is_integer(status) -> refusal
      {:error, _other} -> {:error, {500, "internal error"}}
    end
  end

  # The movement row of document `document_id` that the call answers: the document's own movement for
  # a post, the reversal's for a reverse.
  defp stored(authorized, document_id, which) do
    rows = OldAppReads.movements_of_document(authorized, document_id)

    # A reversal row carries the kind of the movement it reverses (REQ-909), so it is told by `reverses`.
    row =
      case which do
        # A count equal to the book has no ledger entry: its row comes from the count document (REQ-912).
        :post ->
          Enum.find(rows, &(not Map.has_key?(&1, :reverses))) ||
            OldAppReads.confirmed_count_row(authorized, document_id)

        :reversal ->
          Enum.find(rows, &Map.has_key?(&1, :reverses))
      end

    if row, do: {:ok, row}, else: {:error, {500, "internal error"}}
  end

  # What a repeat of a post must equal: kind, sku, place, destination place and quantity (as a
  # number: 100 and 100.0 are equal). NOT the operator (nor, in the old protocol, source or transcript).
  defp movement_hash(movement) do
    quantity =
      movement.quantity |> Decimal.new() |> Decimal.normalize() |> Decimal.to_string(:normal)

    hash([
      "post",
      movement.kind,
      movement.sku,
      movement.location,
      movement.to_location || "",
      quantity
    ])
  end

  defp hash(parts),
    do: :crypto.hash(:sha256, Enum.join(parts, <<31>>)) |> Base.encode16(case: :lower)

  # -- the request ---------------------------------------------------------------------------------

  defp movement_params(prefix, params) when is_map(params) do
    with {:ok, kind} <- kind(params),
         {:ok, quantity} <- quantity(params, kind),
         {:ok, sku} <- ref(prefix, params, "sku_id", :sku, "unknown sku"),
         {:ok, location} <- ref(prefix, params, "location_id", :location, "unknown location"),
         {:ok, to_location} <- to_location(prefix, kind, params) do
      {:ok,
       %{kind: kind, quantity: quantity, sku: sku, location: location, to_location: to_location}}
    end
  end

  defp movement_params(_prefix, _params), do: {:error, {400, "invalid body"}}

  defp kind(%{"kind" => kind}) when kind in @kinds, do: {:ok, kind}
  defp kind(_params), do: {:error, {400, "invalid kind"}}

  defp quantity(params, kind) do
    value = Map.get(params, "qty", Map.get(params, "quantity"))

    text =
      case value do
        n when is_integer(n) -> Integer.to_string(n)
        n when is_float(n) -> to_string(n)
        n when is_binary(n) -> n
        _other -> nil
      end

    with true <- is_binary(text) and byte_size(text) <= @quantity_max,
         {%Decimal{coef: coef} = d, ""} when is_integer(coef) <- Decimal.parse(text) do
      cond do
        # The old server's text for a quantity that is zero or negative (REQ-909 point 6); a count
        # (kind adjustment) may be 0 (REQ-912 point 1), never negative.
        zero_or_less?(d, kind) -> {:error, {400, "quantity must be positive"}}
        Regex.match?(@quantity, text) -> {:ok, Decimal.to_string(d, :normal)}
        true -> {:error, {400, "invalid quantity"}}
      end
    else
      _bad -> {:error, {400, "invalid quantity"}}
    end
  end

  defp zero_or_less?(d, "adjustment"), do: Decimal.lt?(d, 0)
  defp zero_or_less?(d, _kind), do: not Decimal.gt?(d, 0)

  # An integer (or integer text) that is a mapped id of THIS tenant; another tenant's number is just an
  # unknown number here (the mapping tables live in the tenant schema, INV-1).
  defp ref(prefix, params, key, kind, unknown) do
    case int(Map.get(params, key)) do
      nil -> {:error, {400, "invalid " <> key}}
      n -> uuid_or_unknown(IntIds.uuid_for(prefix, kind, n), unknown)
    end
  end

  defp uuid_or_unknown(nil, unknown), do: {:error, {404, unknown}}
  defp uuid_or_unknown(uuid, _unknown), do: {:ok, uuid}

  defp to_location(prefix, "transfer", params),
    do: ref(prefix, params, "to_location_id", :location, "unknown location")

  defp to_location(_prefix, _kind, _params), do: {:ok, nil}

  defp int(n) when is_integer(n) and n > 0, do: n

  defp int(text) when is_binary(text) do
    case Integer.parse(text) do
      {n, ""} when n > 0 -> n
      _other -> nil
    end
  end

  defp int(_other), do: nil

  # -- the document ----------------------------------------------------------------------------------

  defp active(prefix, kind) do
    case Posting.ensure_active(prefix, Kinds.get(kind).definition, nil) do
      :ok -> :ok
      :error -> {:error, {409, "definition_not_active"}}
    end
  end

  defp document_body(prefix, movement) do
    with {:ok, item} <- item(prefix, movement.sku),
         {:ok, unit} <- org_unit(prefix, movement.location),
         {:ok, to_unit} <- to_unit(prefix, movement),
         {:ok, employee} <- employee(prefix) do
      line = %{
        "catalog_item_id" => movement.sku,
        "catalog_uom_id" => item["base_uom_id"],
        "quantity" => movement.quantity
      }

      {:ok, header(movement, unit, to_unit, employee) |> Map.put("lines", [line])}
    end
  end

  defp header(%{kind: "transfer"} = movement, unit, to_unit, employee) do
    %{
      "kind" => "transfer",
      "org_unit_id" => unit,
      "from_location_id" => movement.location,
      "from_responsible_id" => employee,
      "to_org_unit_id" => to_unit,
      "to_location_id" => movement.to_location,
      "to_responsible_id" => employee,
      "event_time" => now()
    }
  end

  defp header(movement, unit, _to_unit, employee) do
    %{
      "kind" => movement.kind,
      "org_unit_id" => unit,
      "location_id" => movement.location,
      "responsible_id" => employee,
      "event_time" => now()
    }
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp item(prefix, sku) do
    case CatalogItems.lookup(prefix, sku) do
      {:ok, %{"active" => true, "base_uom_id" => uom} = item} when is_binary(uom) -> {:ok, item}
      {:ok, %{"active" => true}} -> {:error, {422, "item_has_no_unit"}}
      _other -> {:error, {404, "unknown sku"}}
    end
  end

  defp org_unit(prefix, location) do
    case Locations.org_unit_ids_for_location(prefix, location) do
      [unit | _rest] -> {:ok, unit}
      [] -> {:error, {422, "location_not_linked"}}
    end
  end

  defp to_unit(prefix, %{kind: "transfer", to_location: to_location}),
    do: org_unit(prefix, to_location)

  defp to_unit(_prefix, _movement), do: {:ok, nil}

  defp employee(prefix) do
    case Org.first_active_employee_id(prefix) do
      id when is_binary(id) -> {:ok, id}
      _none -> {:error, {422, "no_responsible_employee"}}
    end
  end

  defp save(prefix, body, actor_id) do
    case Documents.save(prefix, body, actor_id) do
      {:ok, view} -> {:ok, view}
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  defp issue(prefix, id, actor_id, authorized) do
    case Documents.issue(prefix, id, actor_id, authorized: authorized) do
      {:ok, view} ->
        {:ok, view}

      {:error, reason} ->
        # A refused issue took no number: the draft is removed so nothing is left behind.
        _ = Documents.discard(prefix, id, actor_id)
        {:error, refusal(reason)}
    end
  end

  # -- the posting task ------------------------------------------------------------------------------

  # Completes the pending `node` task of document `view.id` as the shared access. A refused posting
  # leaves nothing pending: see the moduledoc.
  defp complete(prefix, %{id: document_id}, node, actor_id, operator) do
    case Posting.pending_task_id(prefix, document_id, node) do
      nil ->
        Logger.error("old_app_no_pending_task")
        {:error, {503, "posting_not_started"}}

      task_id ->
        attrs = %{
          output_variables: %{"operator" => operator},
          actor_id: actor_id,
          idempotency_key: Ecto.UUID.generate()
        }

        case Engine.complete_task(task_id, attrs,
               prefix: prefix,
               credential: :shared_access
             ) do
          {:ok, _result} ->
            :ok

          {:error, reason} ->
            undo(prefix, document_id, node, actor_id)
            {:error, completion_refusal(reason)}
        end
    end
  end

  defp undo(prefix, document_id, "reverse", actor_id),
    do: Posting.withdraw_reversal(prefix, document_id, actor_id)

  # A refused count approval (REQ-912) cancels the issued count the same way as a refused post.
  defp undo(prefix, document_id, node, actor_id) when node in ["post", "approve"] do
    fetch = fn p, id -> Documents.fetch(p, id) end

    case Posting.cancel(
           prefix,
           document_id,
           %{"reason" => "refused through the old app"},
           actor_id,
           fetch
         ) do
      {:ok, _view} -> :ok
      {:error, _reason} -> :error
    end
  end

  defp completion_refusal({:entity_write_refused_detailed, _index, _code, wire, _details})
       when is_binary(wire),
       do: {409, wire}

  defp completion_refusal({:instance_execution_error, _type, _affected}),
    do: {409, "posting_failed"}

  defp completion_refusal(_other), do: {500, "internal error"}

  # -- the reverse -----------------------------------------------------------------------------------

  defp entry_of(prefix, authorized, int_id) do
    with n when is_integer(n) <- int(int_id),
         uuid when is_binary(uuid) <- IntIds.uuid_for(prefix, :movement, n),
         %{document_id: document_id} = entry when is_binary(document_id) <-
           OldAppReads.entry(authorized, uuid) do
      {:ok, entry}
    else
      _unknown -> {:error, {404, "unknown movement"}}
    end
  end

  # The old server's text and status (REQ-909 point 6): a 400, not a 409.
  defp not_a_reversal(%{cause: "reversal"}),
    do: {:error, {400, "a reversal cannot be reversed; post a new operation instead"}}

  defp not_a_reversal(_entry), do: :ok

  defp reverse(prefix, actor_id, authorized, document_id) do
    who = %{actor_id: actor_id, activator: nil}
    fetch = fn p, id -> Documents.fetch(p, id, authorized) end
    body = %{"reason_code" => "other", "reason_text" => "reversed through the old app"}

    case Posting.reverse(prefix, document_id, body, who, authorized, fetch) do
      {:ok, view} -> {:ok, view}
      # The movement was reversed under another client id: the old server's text, as a 400 (REQ-909).
      {:error, :document_reversed} -> {:error, {400, "already reversed"}}
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  # -- refusals --------------------------------------------------------------------------------------

  defp refusal(:not_found), do: {404, "not found"}
  defp refusal(:busy), do: {503, "busy"}
  defp refusal(:reason_invalid), do: {500, "internal error"}
  defp refusal({:unprocessable, reason}) when is_atom(reason), do: {422, Atom.to_string(reason)}
  defp refusal({code, _extras}) when is_binary(code), do: {422, code}
  defp refusal(:idempotency_key_reuse), do: {409, "idempotency_key_reuse"}

  defp refusal(reason)
       when reason in ~w(document_not_issued document_cancelled document_posted posting_pending
                         document_not_posted document_reversed reversal_pending
                         posting_inconsistent definition_not_active document_not_draft external_ref_taken)a,
       do: {409, Atom.to_string(reason)}

  defp refusal(_other), do: {500, "internal error"}
end
