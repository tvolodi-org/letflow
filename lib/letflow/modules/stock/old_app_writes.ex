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
  * Kind `adjustment` (a count), a balance below zero and a retry with the same client id answer as
    Letflow does today for the stock routes: `adjustment` is `invalid kind` (400); the negative-balance
    setting and the freeze guard refuse as they do for a personal account; the client `id` field is
    accepted and ignored (a retry posts a second document).
  * The process definitions of the kinds must already be active (a personal account activates them on
    first use, `Posting.ensure_active/3`); the shared access has no activator, so an inactive one is
    refused `definition_not_active` (409) before any number is taken.

  Refusals are `{:error, {status, text}}`; the text is a closed code, never a value. A failed posting
  leaves no half document: a refused issue discards the draft, a refused ledger posting cancels the
  issued document (a receipt cannot be cancelled while its post task is pending, so a refused receipt
  stays issued; the refusal of a receipt is not a realistic ledger refusal) and a refused reversal
  withdraws its instance.
  """

  require Logger

  alias Letflow.Engine
  alias Letflow.Modules.CatalogItems
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Org
  alias Letflow.Modules.Stock.Documents
  alias Letflow.Modules.Stock.Documents.Kinds
  alias Letflow.Modules.Stock.Documents.Posting
  alias Letflow.Modules.Stock.OldAppReads
  alias Letflow.SharedStockAccess.IntIds

  @operator_max 200
  @kinds ~w(receipt issue transfer)
  @quantity ~r/\A(0|[1-9][0-9]{0,14})(\.[0-9]{1,9})?\z/

  @type result :: {:ok, map()} | {:error, {pos_integer(), String.t()}}

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
  `{:ok, movement}` (the Qoimeks movement fields) answers 201.
  """
  @spec post_movement(String.t(), String.t(), map(), term(), String.t() | nil) :: result()
  def post_movement(prefix, actor_id, authorized, params, header) do
    with {:ok, operator} <- operator(params, header),
         {:ok, movement} <- movement_params(prefix, params),
         :ok <- active(prefix, movement.kind),
         {:ok, body} <- document_body(prefix, movement),
         {:ok, view} <- save(prefix, body, actor_id),
         {:ok, _issued} <- issue(prefix, view.id, actor_id, authorized),
         :ok <- complete(prefix, view, "post", actor_id, operator) do
      case Enum.find(
             OldAppReads.movements_of_document(authorized, view.id),
             &(&1.kind != "reversal")
           ) do
        nil -> {:error, {500, "internal error"}}
        row -> {:ok, row}
      end
    end
  rescue
    exception ->
      Logger.error("old_app_post_failed #{inspect(exception.__struct__)}")
      {:error, {500, "internal error"}}
  end

  @doc """
  The movement reverse of the movement whose Qoimeks integer id is `int_id` (the path). `{:ok,
  movement}` is the reversal's own movement row (201); reversing it again is a 409.
  """
  @spec reverse_movement(String.t(), String.t(), map(), term(), term(), String.t() | nil) ::
          result()
  def reverse_movement(prefix, actor_id, authorized, int_id, params, header) do
    with {:ok, operator} <- operator(params, header),
         {:ok, entry} <- entry_of(prefix, authorized, int_id),
         :ok <- not_a_reversal(entry),
         {:ok, _view} <- reverse(prefix, actor_id, authorized, entry.document_id),
         :ok <-
           complete(prefix, %{id: entry.document_id}, "reverse", actor_id, operator) do
      case Enum.find(
             OldAppReads.movements_of_document(authorized, entry.document_id),
             &(&1.kind == "reversal")
           ) do
        nil -> {:error, {500, "internal error"}}
        row -> {:ok, row}
      end
    end
  rescue
    exception ->
      Logger.error("old_app_reverse_failed #{inspect(exception.__struct__)}")
      {:error, {500, "internal error"}}
  end

  # -- the request ---------------------------------------------------------------------------------

  defp movement_params(prefix, params) when is_map(params) do
    with {:ok, kind} <- kind(params),
         {:ok, quantity} <- quantity(params),
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

  defp quantity(params) do
    value = Map.get(params, "qty", Map.get(params, "quantity"))

    text =
      case value do
        n when is_integer(n) -> Integer.to_string(n)
        n when is_float(n) -> to_string(n)
        n when is_binary(n) -> n
        _other -> nil
      end

    with true <- is_binary(text),
         true <- Regex.match?(@quantity, text),
         {%Decimal{} = d, ""} <- Decimal.parse(text),
         false <- Decimal.eq?(d, 0) do
      {:ok, Decimal.to_string(d, :normal)}
    else
      _bad -> {:error, {400, "invalid quantity"}}
    end
  end

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

  defp undo(prefix, document_id, "post", actor_id) do
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

  defp not_a_reversal(%{cause: "reversal"}), do: {:error, {409, "reversal_cannot_be_reversed"}}
  defp not_a_reversal(_entry), do: :ok

  defp reverse(prefix, actor_id, authorized, document_id) do
    who = %{actor_id: actor_id, activator: nil}
    fetch = fn p, id -> Documents.fetch(p, id, authorized) end
    body = %{"reason_code" => "other", "reason_text" => "reversed through the old app"}

    case Posting.reverse(prefix, document_id, body, who, authorized, fetch) do
      {:ok, view} -> {:ok, view}
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
