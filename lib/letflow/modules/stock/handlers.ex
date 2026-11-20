defmodule Letflow.Modules.Stock.Handlers do
  @moduledoc """
  REQ-713 / GH #3748: the write handlers of module `stock`, called from the `module_writes` line of
  the HUMAN_TASK nodes of the process definitions `stock_receipt` (`post_document`) and
  `stock_reversal` (`reverse_document`). Each does exactly two things in the completion
  transaction of the task: one `Letflow.Entities.HandlerWrites.create/3` of the bookkeeping record
  `stock_posting_mark`, and one `Letflow.Entities.HandlerWrites.post/3` of the posting.

  Contract: `(multi, ctx, args) :: {:ok, multi} | {:error, :invalid_arguments | :not_permitted | {:refused, code}}`
  (`code` is `:record_version_conflict` or `:master_inactive`).
  The posting command is rebuilt here from LITERAL keys of the string-keyed `posting` argument
  (no `String.to_atom`, scans H4); `ledger_id` is always `"stock"`, and a `prefix`, `subject_id`
  or `credential` in the arguments is never copied: the platform fills them from the context.
  The platform scans (`handler_writes_callers_test.exs`, H4) cover this file.

  The cause `count_difference` (REQ-718, process definition `stock_count_posting`) has its own handler
  `post_count`; `post_document` refuses that cause and `post_count` refuses every other. A posting
  carries `related_document_id` (the `count.order` document id) and `correlation_id`.

  The cause `opening` (REQ-726, process definition `stock_opening`, node `approve`) is built without
  the offline keys `device_id`, `client_seq` and `client_event_time`.

  A second mark of the same kind for one document violates the unique constraint of the mark type,
  so the completion rolls back before any ledger write (criterion 5 of REQ-713).

  The cause `count_set` (REQ-854, process definition `stock_quick_count`, node `approve`) is built without
  the offline keys, with its `reason_code`, and its line carries `expected_on_hand`.

  ## Binding to the issued version (REQ-903 / GH #4819; decision 0073 D6, version 0.24.0)

  `post_document` (it alone: it declares `reads_documents: true`; `post_count`, `post_kind_change_out` and
  `reverse_document` do not) first reads the version named by its arguments `document_id` and `version_no`
  with `HandlerWrites.read_document_version/3`, BEFORE the master checks and before any step is added.
  An unknown, malformed, other-tenant or other-module document (`{:error, :not_found}`) is the closed
  `{:error, :invalid_arguments}` (422). The posting is refused with `{:error, {:refused,
  :record_version_conflict}}` (409) when the version is not `issued`, is not the current one, when the
  posting's `client_op_id` is not the version id, when the argument or posting `document_type` is not the
  version's type, the posting's `document_id` is not the argument, the argument `org_unit_id` is not the
  document's issuing org unit, the posting's cause is not a cause of the kind (`Kinds.causes/1`), its
  `client_event_time` is not the header `event_time` (not for an opening or quick count, which carry none),
  a write-off's `reason_code` is not the header's, or its legs differ from the issued content's legs
  (`Letflow.Modules.Stock.Documents.Legs`, the same comparison as the read-side `posting_check`).
  On a dry build (`{:error, :dry_build}`) the check is skipped and the real build runs it.
  The read takes no lock. That is enough: stock documents are never re-versioned, and the only cancel
  path (`Documents.Posting.cancel/5`) withdraws every pending post instance through
  `Letflow.Engine.cancel_instance` before `Letflow.Documents.cancel/3`, so a cancel and a post of one
  document are serialised by the instance. The binding of `post_count` and `post_kind_change_out` stays
  detected on read only.

  ## Master checks at posting (REQ-832 / GH #4535; version 0.18.0)

  `post_document`, `post_count` and `post_kind_change_out` check every master named by a posting line
  before building any write step, using the read facade `HandlerWrites.read/3`. The rules follow the
  cause table of `lib/letflow/modules/stock/ledger_policy/declare.ex` (the `to` side adds stock, the
  `from` side removes it):

  - **Line with a `to` side (adds stock):** `sku` must be a live active `catalog_item`; `unit` a live
    active `catalog_uom` whose id equals the item's `base_uom_id`; a given `lot` a live active
    `catalog_lot` whose `item_id` equals `sku`; the to-side `location` a live active `location_node`;
    `org_unit` a live active `org_unit`; a given `responsible` a live active `org_employee`. The from
    side of the same line (transfer / hand over / return) is checked for liveness only (active false
    accepted; the quantity is leaving that master, not arriving at it).
  - **Line with only a `from` side (removes stock):** each of `sku`, `unit`, a given `lot`, the from
    `location`, `org_unit` and a given `responsible` must be a live record of its type (`read/3`
    answers `{:ok, _}`); active false is accepted (retired masters can still be drawn down).
  - **Retired master on an adding side (REQ-904 / GH #4818; decision 0073 note 9.5):** a master that IS a
    live record of its type (`read/3` answers `{:ok, map}`) but whose `active` field is not true (the
    item, the unit, a given lot, the to location, the org unit, a given responsible) makes the handler
    answer `{:error, {:refused, :master_inactive}}`, which the engine maps to 409 `master_inactive`
    (REQ-901, the closed platform list). The refusal carries no detail: no slot name and no id.
    Only the check of a `to` side can say it; the from side and a removing line never do.
  - **Everything else REQ-832 refuses stays untyped:** a non-uuid or unknown id, a record of another type
    or another tenant, a soft-deleted record, a unit that is not the item's base unit and a lot of
    another item return `{:error, :invalid_arguments}`, which the engine maps to 422
    `validation_failed` with audit detail `handler_invalid_arguments`; nothing of the completion
    commits and the post task stays pending.
  - **First failure wins**, in the order the checks run: item, unit (and its base unit), lot (and its
    item), to location, org unit, responsible, then the from side (liveness only).
  - **`not_linked` (org unit to location link) is checked at issue only**
    (`Letflow.Modules.Stock.Documents.Checks`), not at posting: decision 0073 does not list it in D6 or in
    the L7 row, and it cannot be built on the current facade, because `Letflow.Modules.Locations.linked?/3`
    finds the link record by field values and `HandlerWrites.read/3` reads by id only.
  - **Cache:** each distinct `{type, id}` pair is read at most once per handler call; no lock is
    taken.
  - **Dry build:** when `read/3` answers `{:error, :dry_build}`, all checks are skipped and the
    posting is built normally (the real build runs them).
  - **Reversal:** `reverse_document` reads nothing (decision 0073 note 9.5); reversing a posting
    whose masters were retired since issue stays accepted. `reverse_document` declares no reads in
    the manifest and this module does not call the checks for it.
  """

  alias Letflow.Entities.HandlerWrites
  alias Letflow.Modules.Stock.Documents.Kinds
  alias Letflow.Modules.Stock.Documents.Legs

  @type result ::
          {:ok, Ecto.Multi.t()}
          | {:error,
             :invalid_arguments
             | :not_permitted
             | {:refused, :record_version_conflict | :master_inactive}}

  @spec post_document(Ecto.Multi.t(), Letflow.Entities.HandlerContext.t(), map()) :: result()
  def post_document(_multi, _ctx, %{"posting" => %{"cause" => cause}})
      when cause in ["count_difference", "kind_change_out"],
      do: {:error, :invalid_arguments}

  def post_document(multi, ctx, args), do: run(multi, ctx, args, "posted", [], true)

  # REQ-718: the posting of a signed count. Only a `count.differences` document and the cause
  # `count_difference` are accepted; `post_document` refuses that cause in return.
  @spec post_count(Ecto.Multi.t(), Letflow.Entities.HandlerContext.t(), map()) :: result()
  def post_count(
        multi,
        ctx,
        %{"document_type" => "count.differences", "posting" => posting} = args
      )
      when is_map(posting) do
    if Map.get(posting, "cause") == "count_difference",
      do: run(multi, ctx, args, "posted", [], false),
      else: {:error, :invalid_arguments}
  end

  def post_count(_multi, _ctx, _args), do: {:error, :invalid_arguments}

  # REQ-760: the stock leg of a change of kind. Only the cause `kind_change_out` is accepted;
  # `post_document` refuses it in return. The posting carries the shared `correlation_id`.
  @spec post_kind_change_out(Ecto.Multi.t(), Letflow.Entities.HandlerContext.t(), map()) ::
          result()
  def post_kind_change_out(multi, ctx, %{"posting" => %{"cause" => "kind_change_out"}} = args),
    do: run(multi, ctx, args, "posted", [], false)

  def post_kind_change_out(_multi, _ctx, _args), do: {:error, :invalid_arguments}

  @spec reverse_document(Ecto.Multi.t(), Letflow.Entities.HandlerContext.t(), map()) :: result()
  def reverse_document(multi, ctx, args),
    do: run(multi, ctx, args, "reversed", ["reason_code"], false)

  defp run(multi, ctx, args, mark, extra_keys, binding?) when is_map(args) do
    with true <- valid_args?(args, {mark, extra_keys}),
         {:ok, command} <- command(Map.get(args, "posting")),
         :ok <- check_binding(binding?, ctx, args, Map.get(args, "posting")),
         :ok <- check_masters(ctx, command),
         {:ok, multi} <- create_mark(multi, ctx, args, extra_keys) do
      case HandlerWrites.post(multi, ctx, command) do
        {:ok, multi} -> {:ok, multi}
        {:error, _contract_error} -> {:error, :not_permitted}
      end
    else
      false -> {:error, :invalid_arguments}
      :error -> {:error, :invalid_arguments}
      {:error, _reason} = error -> error
    end
  end

  defp run(_multi, _ctx, _args, _mark, _extra, _binding?), do: {:error, :invalid_arguments}

  defp valid_args?(args, {mark, extra_keys}) do
    Enum.all?(~w(document_id document_type org_unit_id) ++ extra_keys, fn key ->
      is_binary(Map.get(args, key))
    end) and is_integer(Map.get(args, "version_no")) and Map.get(args, "mark") == mark and
      is_map(Map.get(args, "posting"))
  end

  defp create_mark(multi, ctx, args, extra_keys) do
    values = %{
      "document_id" => Map.get(args, "document_id"),
      "document_type" => Map.get(args, "document_type"),
      "version_no" => Map.get(args, "version_no"),
      "org_unit_id" => Map.get(args, "org_unit_id"),
      "mark" => Map.get(args, "mark")
    }

    values =
      if "reason_code" in extra_keys,
        do: Map.merge(values, %{"reason_code" => Map.get(args, "reason_code")}),
        else: values

    case HandlerWrites.create(multi, ctx, %{
           entity_type: "stock_posting_mark",
           field_values: values
         }) do
      {:ok, multi} -> {:ok, multi}
      {:error, _contract_error} -> {:error, :not_permitted}
    end
  end

  # -- the binding to the issued document (REQ-903) --------------------------------------------

  # The posting must be the issued, current version of its document, with its content. A read
  # that answers not_found (unknown, malformed, another tenant's, another module's) is the closed
  # invalid_arguments; any other mismatch is the typed 409. A dry build skips it.
  defp check_binding(false, _ctx, _args, _posting), do: :ok

  defp check_binding(true, ctx, args, posting) do
    case HandlerWrites.read_document_version(
           ctx,
           Map.get(args, "document_id"),
           Map.get(args, "version_no")
         ) do
      {:ok, version} -> binding_verdict(version, args, posting)
      {:error, :dry_build} -> :ok
      {:error, :invalid_write_command} -> {:error, :not_permitted}
      {:error, _not_found_or_not_registered} -> {:error, :invalid_arguments}
    end
  end

  defp binding_verdict(version, args, posting) do
    spec = Kinds.by_type_key(Map.get(version, "type_key"))
    content = Map.get(version, "content", %{})
    header = Map.get(content, "header", %{})

    ok? =
      spec != nil and Map.get(version, "status") == "issued" and
        Map.get(version, "current") == true and
        Map.get(posting, "client_op_id") == Map.get(version, "version_id") and
        Map.get(args, "document_type") == Map.get(spec, :type_key) and
        Map.get(posting, "document_type") == Map.get(spec, :type_key) and
        Map.get(posting, "document_id") == Map.get(args, "document_id") and
        Map.get(args, "org_unit_id") == Map.get(version, "issuing_org_unit_id") and
        Map.get(posting, "cause") in Kinds.causes(spec) and
        time_bound?(spec, posting, header) and reason_bound?(spec, posting, header) and
        legs_bound?(spec, posting, content)

    if ok?, do: :ok, else: {:error, {:refused, :record_version_conflict}}
  end

  # An opening and a quick count carry no client time (the ledger stamps the posting time).
  defp time_bound?(%{kind: kind}, _posting, _header) when kind in ["opening", "quick_count"],
    do: true

  defp time_bound?(_spec, posting, header),
    do: Map.get(posting, "client_event_time") == Map.get(header, "event_time")

  defp reason_bound?(%{kind: "write_off"}, posting, header),
    do: Map.get(posting, "reason_code") == Map.get(header, "reason_code")

  defp reason_bound?(%{kind: "quick_count"}, posting, header),
    do: Map.get(posting, "reason_code") == Map.get(header, "reason_code")

  defp reason_bound?(_spec, _posting, _header), do: true

  defp legs_bound?(spec, posting, content) do
    case Legs.from_posting(posting) do
      :invalid -> false
      actual -> actual == Legs.expected(spec, content, Map.get(posting, "record_zero") == true)
    end
  end

  # -- the posting command: literal keys only -----------------------------------------------------

  defp command(%{"cause" => "reversal"} = posting) do
    {:ok,
     %{
       ledger_id: "stock",
       cause: "reversal",
       document_type: Map.get(posting, "document_type"),
       document_id: Map.get(posting, "document_id"),
       related_document_id: Map.get(posting, "related_document_id"),
       client_op_id: Map.get(posting, "client_op_id"),
       reverses_entry_id: Map.get(posting, "reverses_entry_id"),
       reason_code: Map.get(posting, "reason_code")
     }}
  end

  # REQ-726: an opening has NO event time from the client. The three offline keys are never copied
  # for it (a changed `posting` variable cannot backdate it); the ledger stamps the posting time.
  defp command(%{"cause" => cause, "lines" => lines} = posting)
       when cause in ["opening", "opening_negative"] and is_list(lines) do
    with {:ok, lines} <- lines(lines) do
      {:ok,
       %{
         ledger_id: "stock",
         cause: cause,
         document_type: Map.get(posting, "document_type"),
         document_id: Map.get(posting, "document_id"),
         client_op_id: Map.get(posting, "client_op_id"),
         lines: lines
       }}
    end
  end

  # REQ-854: a quick count (`count_set`) is online too (no offline keys) and carries its reason code;
  # each line keeps the `expected_on_hand` (the book quantity) for the core's compare-and-set.
  defp command(%{"cause" => "count_set", "lines" => lines} = posting) when is_list(lines) do
    with {:ok, lines} <- lines(lines) do
      {:ok,
       %{
         ledger_id: "stock",
         cause: "count_set",
         document_type: Map.get(posting, "document_type"),
         document_id: Map.get(posting, "document_id"),
         client_op_id: Map.get(posting, "client_op_id"),
         reason_code: Map.get(posting, "reason_code"),
         lines: lines
       }}
    end
  end

  defp command(%{"cause" => cause, "lines" => lines} = posting)
       when is_binary(cause) and is_list(lines) do
    with {:ok, lines} <- lines(lines) do
      {:ok,
       %{
         ledger_id: "stock",
         cause: cause,
         document_type: Map.get(posting, "document_type"),
         document_id: Map.get(posting, "document_id"),
         related_document_id: Map.get(posting, "related_document_id"),
         correlation_id: Map.get(posting, "correlation_id"),
         client_op_id: Map.get(posting, "client_op_id"),
         reason_code: Map.get(posting, "reason_code"),
         device_id: Map.get(posting, "device_id"),
         client_seq: Map.get(posting, "client_seq"),
         client_event_time: Map.get(posting, "client_event_time"),
         lines: lines
       }}
    end
  end

  defp command(_other), do: :error

  defp lines(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      case line(line) do
        {:ok, built} -> {:cont, {:ok, [built | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp line(%{} = line) do
    built = %{
      line_id: Map.get(line, "line_id"),
      sku: Map.get(line, "sku"),
      lot: Map.get(line, "lot"),
      unit: Map.get(line, "unit"),
      quantity: Map.get(line, "quantity"),
      from: side(Map.get(line, "from")),
      to: side(Map.get(line, "to"))
    }

    # REQ-854: the key is copied only when the line carries it, so the command of every other
    # cause (and its payload hash) is unchanged.
    case Map.fetch(line, "expected_on_hand") do
      {:ok, expected} -> {:ok, Map.put(built, :expected_on_hand, expected)}
      :error -> {:ok, built}
    end
  end

  defp line(_other), do: :error

  defp side(%{} = side) do
    %{
      org_unit: Map.get(side, "org_unit"),
      location: Map.get(side, "location"),
      responsible: Map.get(side, "responsible")
    }
  end

  defp side(other), do: other

  # -- master checks at posting (REQ-832) --------------------------------------------------------

  defp check_masters(_ctx, %{cause: "reversal"}), do: :ok

  defp check_masters(ctx, command) do
    result =
      Enum.reduce_while(Map.get(command, :lines, []), {:ok, %{}}, fn line, {:ok, cache} ->
        case check_line(ctx, line, cache) do
          {:ok, cache} -> {:cont, {:ok, cache}}
          err -> {:halt, err}
        end
      end)

    case result do
      {:ok, _} -> :ok
      {:error, :dry_build} -> :ok
      {:error, :invalid_arguments} = err -> err
      {:error, {:refused, :master_inactive}} = err -> err
    end
  end

  defp check_line(ctx, %{sku: sku, unit: unit, lot: lot, to: to, from: from}, cache)
       when is_map(to) do
    with {:ok, item, cache} <- check_active(ctx, "catalog_item", sku, cache),
         {:ok, _uom, cache} <- check_active(ctx, "catalog_uom", unit, cache),
         :ok <- check_base_uom(unit, item),
         {:ok, cache} <- check_lot_active(ctx, lot, sku, cache),
         {:ok, _loc, cache} <- check_active(ctx, "location_node", to.location, cache),
         {:ok, _ou, cache} <- check_active(ctx, "org_unit", to.org_unit, cache),
         {:ok, cache} <- check_optional_active(ctx, "org_employee", to.responsible, cache),
         {:ok, cache} <- check_from_live(ctx, from, cache) do
      {:ok, cache}
    end
  end

  defp check_line(ctx, %{sku: sku, unit: unit, lot: lot, to: nil, from: from}, cache)
       when is_map(from) do
    with {:ok, _item, cache} <- check_live(ctx, "catalog_item", sku, cache),
         {:ok, _uom, cache} <- check_live(ctx, "catalog_uom", unit, cache),
         {:ok, cache} <- check_lot_live(ctx, lot, cache),
         {:ok, cache} <- check_from_live(ctx, from, cache) do
      {:ok, cache}
    end
  end

  # A line with no usable side (not a map on either side) names no master the posting could add or remove:
  # refuse it here, as the ledger would at the build.
  defp check_line(_ctx, _line, _cache), do: {:error, :invalid_arguments}

  defp check_from_live(_ctx, nil, cache), do: {:ok, cache}

  defp check_from_live(ctx, from, cache) when is_map(from) do
    with {:ok, _loc, cache} <- check_live(ctx, "location_node", from.location, cache),
         {:ok, _ou, cache} <- check_live(ctx, "org_unit", from.org_unit, cache),
         {:ok, cache} <- check_optional_live(ctx, "org_employee", from.responsible, cache) do
      {:ok, cache}
    end
  end

  defp check_from_live(_ctx, _not_a_side, _cache), do: {:error, :invalid_arguments}

  defp check_lot_active(_ctx, nil, _sku, cache), do: {:ok, cache}

  defp check_lot_active(ctx, lot_id, sku, cache) do
    with {:ok, lot, cache} <- check_active(ctx, "catalog_lot", lot_id, cache),
         :ok <- check_lot_item(lot, sku) do
      {:ok, cache}
    end
  end

  defp check_lot_live(_ctx, nil, cache), do: {:ok, cache}

  defp check_lot_live(ctx, lot_id, cache) do
    with {:ok, _lot, cache} <- check_live(ctx, "catalog_lot", lot_id, cache) do
      {:ok, cache}
    end
  end

  defp check_optional_active(_ctx, _type, nil, cache), do: {:ok, cache}

  defp check_optional_active(ctx, type, id, cache) do
    with {:ok, _, cache} <- check_active(ctx, type, id, cache), do: {:ok, cache}
  end

  defp check_optional_live(_ctx, _type, nil, cache), do: {:ok, cache}

  defp check_optional_live(ctx, type, id, cache) do
    with {:ok, _, cache} <- check_live(ctx, type, id, cache), do: {:ok, cache}
  end

  defp check_active(ctx, type, id, cache) do
    case read_cached(ctx, type, id, cache) do
      {{:ok, %{"active" => true} = map}, cache} -> {:ok, map, cache}
      {{:ok, _inactive}, _cache} -> {:error, {:refused, :master_inactive}}
      {{:error, :dry_build}, _cache} -> {:error, :dry_build}
      {{:error, _}, _cache} -> {:error, :invalid_arguments}
    end
  end

  defp check_live(ctx, type, id, cache) do
    case read_cached(ctx, type, id, cache) do
      {{:ok, map}, cache} -> {:ok, map, cache}
      {{:error, :dry_build}, _cache} -> {:error, :dry_build}
      {{:error, _}, _cache} -> {:error, :invalid_arguments}
    end
  end

  defp read_cached(ctx, type, id, cache) do
    key = {type, id}

    case Map.fetch(cache, key) do
      {:ok, result} ->
        {result, cache}

      :error ->
        result = HandlerWrites.read(ctx, type, id)
        {result, Map.put(cache, key, result)}
    end
  end

  defp check_base_uom(unit, %{"base_uom_id" => base_uom_id}) when is_binary(base_uom_id) do
    case Ecto.UUID.cast(unit) do
      {:ok, uuid} when uuid == base_uom_id -> :ok
      _ -> {:error, :invalid_arguments}
    end
  end

  defp check_base_uom(_unit, _item), do: {:error, :invalid_arguments}

  defp check_lot_item(%{"item_id" => item_id}, sku) when is_binary(item_id) do
    case Ecto.UUID.cast(sku) do
      {:ok, uuid} when uuid == item_id -> :ok
      _ -> {:error, :invalid_arguments}
    end
  end

  defp check_lot_item(_lot, _sku), do: {:error, :invalid_arguments}
end
