defmodule Letflow.Modules.Stock.Documents.Posting do
  @moduledoc """
  REQ-713 / GH #3748 (assets B4 part 2): posting, reversal and cancel of an issued stock document.
  Public functions: `ensure_active/3`, `start_post/4`, `post/4`, `reverse/6`, `cancel/5` (the routes'
  work), `state_fields/3` and `states_for/2` (the read side). The tenant is the `prefix` argument
  and nothing else (INV-1); every read and write passes it.

  ## How a document posts

  The issue step (and the retry route `post/4`) starts ONE instance of the module's process
  definition `stock_receipt` (`Letflow.Engine.create/2`, no correlation key: it is unique across
  all statuses and would make a cancelled post unrestartable; the idempotency key
  `stock-post:<version id>:<attempt>` is used instead). Completing its HUMAN_TASK `post` runs the
  write handler `post_document` (`Letflow.Modules.Stock.Handlers`): the ledger entry and the
  `stock_posting_mark` record commit together or not at all. The command is built here ONLY from
  the issued version's frozen content. A receipt's entry carries the offline triple `device_id`,
  `client_seq`, `client_event_time` (derived from the issued number and the header's `event_time`)
  so the core's rule gives the entry the header's event time, not the posting time; a reversal is
  posted online (all three absent), so its event time is its posting time.

  ## Lazy activation

  Install leaves the pack's process definitions as module-stamped drafts and `InstallContext` has
  no activator. `ensure_active/3` activates the draft with the REQUEST's activator (a signed act,
  `Letflow.Definitions.activate/2`); it answers `:error` (the routes' 409 `definition_not_active`)
  when there is no activator, it lacks `DefinitionsActivate` or `EntitiesRecordsWrite`, the
  activation is refused, or an active definition of that name is not this module's.

  ## Read states

  `state_fields/3` derives `posted_at`, `posted_by`, `entry_id`, `reversed_at`, `reversed_by` and
  `posting_check` from the marks, the completed tasks and the ledger entries of the document.
  `posting_check` is `"ok"`, `"mismatch"` or `nil` and never carries a detail (decision 0078 D5:
  the binding of the posting to the issued content is detected here, not enforced, until L7).
  `posted_by` and `reversed_by` come from `tasks.completed_by` (the ledger exposes no subject).
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Letflow.Definitions
  alias Letflow.Definitions.OwnerStamp
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Documents
  alias Letflow.Documents.Document
  alias Letflow.Documents.DocumentVersion
  alias Letflow.Engine
  alias Letflow.Engine.Task
  alias Letflow.Entities.Record.Latest
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Ledger
  alias Letflow.Modules.Stock.Documents.Kinds
  alias Letflow.Repo

  @reversal_definition "stock_reversal"
  @mark_type "stock_posting_mark"
  @reasons ~w(wrong_document wrong_quantity wrong_master_data other)
  @reason_text_max 500
  @max_number 10_000_000

  @doc "The closed list of reversal reason codes."
  @spec reasons() :: [String.t()]
  def reasons, do: @reasons

  # -- lazy activation ----------------------------------------------------------------------------

  @doc """
  Makes sure the module's process definition `name` is active, activating its stamped draft with
  `activator` when needed. `:ok` or `:error`; never raises, logs the reason tag only.
  """
  @spec ensure_active(String.t(), String.t(), map() | nil) :: :ok | :error
  def ensure_active(prefix, name, activator) when is_binary(prefix) and is_binary(name) do
    case Definitions.get_active_by_name(name, prefix: prefix) do
      {:ok, row} -> if stock_stamped?(row), do: :ok, else: :error
      {:error, :not_found} -> activate_draft(prefix, name, activator)
      _other -> :error
    end
  end

  defp activate_draft(prefix, name, activator) do
    with true <- activator?(activator),
         %ProcessDefinition{id: id} <- stamped_draft(prefix, name),
         {:ok, _activated} <- Definitions.activate(id, prefix: prefix, activator: activator) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("stock definition activation refused: #{inspect(tag(reason))}")
        :error

      _refused ->
        :error
    end
  end

  defp activator?(%{permissions: permissions, entities_records_write?: true})
       when is_list(permissions),
       do: "DefinitionsActivate" in permissions

  defp activator?(_other), do: false

  defp stamped_draft(prefix, name) do
    Repo.one(
      from(d in ProcessDefinition,
        where: d.name == ^name and d.status == :draft and d.owner_module == "stock",
        order_by: [desc: d.created_at],
        limit: 1
      ),
      prefix: prefix
    )
  end

  defp stock_stamped?(row), do: match?({:ok, %{module_id: "stock"}}, OwnerStamp.from_row(row))

  defp tag(reason) when is_tuple(reason) and tuple_size(reason) > 0, do: elem(reason, 0)
  defp tag(reason), do: reason

  # -- the issued version -------------------------------------------------------------------------

  @doc """
  The live issued version of document `id` for the posting command: `%{version_id, version_no,
  content, number, period}`, or `nil` when the live version is not issued.
  """
  @spec issued(String.t(), String.t()) :: map() | nil
  def issued(prefix, id) do
    query =
      from(v in DocumentVersion,
        join: d in Document,
        on: d.id == v.document_id,
        where: v.document_id == ^id and v.status == :issued,
        order_by: [desc: v.version_no],
        limit: 1,
        select: %{
          version_id: v.id,
          version_no: v.version_no,
          content: v.content,
          number: d.number,
          period: d.period
        }
      )

    Repo.one(query, prefix: prefix)
  end

  # -- starting the instances ---------------------------------------------------------------------

  @doc """
  Starts one `stock_receipt` instance for the issued document `view` (as `Documents.fetch/2`
  renders it) with `issued` (from `issued/2`). `{:ok, instance_id}` or `{:error, reason}`.
  """
  @spec start_post(String.t(), map(), map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def start_post(prefix, view, issued, actor) do
    spec = Kinds.get(view.kind)

    with :ok <- start_seam(),
         {:ok, command} <- post_command(spec, view, issued) do
      vars = %{
        "document_id" => view.id,
        "document_type" => spec.type_key,
        "version_no" => issued.version_no,
        "org_unit_id" => view.org_unit_id,
        "mark" => "posted",
        "posting" => command
      }

      start(prefix, spec.definition, "stock-post", issued.version_id, view.id, vars, actor)
    end
  end

  @doc "Starts one `stock_reversal` instance (see the moduledoc)."
  @spec start_reversal(String.t(), map(), map(), map(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def start_reversal(prefix, view, issued, reversal, actor) do
    type_key = Kinds.get(view.kind).type_key

    command = %{
      "cause" => "reversal",
      "reverses_entry_id" => reversal.entry_id,
      "reason_code" => reversal.reason_code,
      "document_type" => type_key,
      "document_id" => view.id,
      "client_op_id" => reversal.mark_id
    }

    vars = %{
      "document_id" => view.id,
      "document_type" => type_key,
      "version_no" => issued.version_no,
      "org_unit_id" => view.org_unit_id,
      "mark" => "reversed",
      "reason_code" => reversal.reason_code,
      "reason_text" => reversal.reason_text,
      "posting" => command
    }

    start(prefix, @reversal_definition, "stock-rev", issued.version_id, view.id, vars, actor)
  end

  # Test seam: forces a start failure after the issue committed. Read here only.
  defp start_seam do
    if Application.get_env(:letflow, :stock_post_start_fail?) == true,
      do: {:error, :forced_start_failure},
      else: :ok
  end

  defp start(prefix, name, key_prefix, version_id, doc_id, vars, actor) do
    attempt(prefix, name, key_prefix, version_id, doc_id, vars, actor, 2)
  end

  defp attempt(prefix, name, key_prefix, version_id, doc_id, vars, actor, tries_left) do
    n = 1 + instance_count(prefix, name, doc_id)

    attrs = %{
      definition_name: name,
      initial_variables: vars,
      actor_id: actor,
      idempotency_key: "#{key_prefix}:#{version_id}:#{n}"
    }

    case Engine.create(attrs, prefix: prefix) do
      {:ok, %{replayed: true, status: status}} when status != :active and tries_left > 1 ->
        attempt(prefix, name, key_prefix, version_id, doc_id, vars, actor, tries_left - 1)

      {:ok, %{instance_id: instance_id}} ->
        {:ok, instance_id}

      {:error, :definition_not_active} ->
        {:error, :definition_not_active}

      {:error, reason} ->
        Logger.warning("stock posting start refused: #{inspect(tag(reason))}")
        {:error, :start_failed}
    end
  end

  defp definition_ids(prefix, name) do
    Repo.all(
      from(d in ProcessDefinition,
        where: d.name == ^name and d.owner_module == "stock",
        select: d.id
      ),
      prefix: prefix
    )
  end

  defp instance_count(prefix, name, doc_id) do
    ids = definition_ids(prefix, name)

    Repo.aggregate(
      from(p in InstanceProjection,
        where: p.definition_id in ^ids and fragment("?->>'document_id' = ?", p.variables, ^doc_id)
      ),
      :count,
      prefix: prefix
    )
  end

  # The posting command from the frozen content: the header and lines as issued, plus the line
  # RECORD ids (`view.lines` are the records; nothing changes after issue). The sides of every line
  # come from `Kinds.sides/2` (a receipt has a `to` side only; REQ-721 kinds also a `from` side).
  defp post_command(spec, view, %{content: content, number: number, period: period} = issued) do
    header = Map.get(content, "header", %{})
    lines = Map.get(content, "lines", [])
    line_ids = Map.new(view.lines, &{&1.line_no, &1.line_id})

    with {:ok, seq} <- client_seq(period, number),
         {:ok, built} <- build_lines(lines, Kinds.sides(spec, header), line_ids) do
      {:ok,
       %{
         "cause" => spec.cause,
         "document_type" => spec.type_key,
         "document_id" => view.id,
         "client_op_id" => issued.version_id,
         "device_id" => spec.device_id,
         "client_seq" => seq,
         "client_event_time" => Map.get(header, "event_time"),
         "lines" => built
       }}
    end
  end

  defp client_seq(period, number) when is_binary(period) and is_integer(number) do
    with {year, ""} <- Integer.parse(period),
         true <- number >= 0 and number < @max_number do
      {:ok, year * @max_number + number}
    else
      _bad -> {:error, :number_out_of_range}
    end
  end

  defp client_seq(_period, _number), do: {:error, :number_out_of_range}

  defp build_lines(lines, sides, line_ids) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      case Map.fetch(line_ids, Map.get(line, "line_no")) do
        {:ok, line_id} -> {:cont, {:ok, [leg_line(line, line_id, sides) | acc]}}
        :error -> {:halt, {:error, :line_record_missing}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp leg_line(line, line_id, {from, to}) do
    base = %{
      "line_id" => line_id,
      "sku" => Map.get(line, "catalog_item_id"),
      "lot" => Map.get(line, "catalog_lot_id"),
      "unit" => Map.get(line, "catalog_uom_id"),
      "quantity" => Map.get(line, "quantity"),
      "to" => side_map(to)
    }

    if from, do: Map.put(base, "from", side_map(from)), else: base
  end

  defp side_map(side) do
    %{
      "org_unit" => side.org_unit,
      "location" => side.location,
      "responsible" => side.responsible
    }
  end

  # -- the routes' work ---------------------------------------------------------------------------

  @doc """
  Retry route: starts the posting instance of an issued document that has no mark and no pending
  post task. Returns `{:ok, view}` or `{:error, reason}`, `reason` one of `:not_found`,
  `:document_not_issued`, `:document_cancelled`, `:document_posted`, `:posting_pending`,
  `:definition_not_active`, `:internal`.
  """
  @spec post(String.t(), term(), map(), term()) :: {:ok, map()} | {:error, atom()}
  def post(prefix, id, %{actor_id: actor, activator: activator}, fetch) do
    with {:ok, view} <- fetch.(prefix, id),
         :ok <- postable(prefix, view),
         :ok <- active(prefix, Kinds.get(view.kind).definition, activator),
         %{} = issued <- issued(prefix, view.id) || {:error, :internal},
         {:ok, _instance} <- start_post(prefix, view, issued, actor) do
      fetch.(prefix, id)
    else
      {:error, :definition_not_active} -> {:error, :definition_not_active}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _other -> {:error, :internal}
    end
  end

  defp postable(prefix, view) do
    pending = pending(prefix, view.id)

    cond do
      view.state == "draft" -> {:error, :document_not_issued}
      view.state == "cancelled" -> {:error, :document_cancelled}
      view.state in ["posted", "reversed"] -> {:error, :document_posted}
      pending.post -> {:error, :posting_pending}
      true -> :ok
    end
  end

  defp active(prefix, name, activator) do
    case ensure_active(prefix, name, activator) do
      :ok -> :ok
      :error -> {:error, :definition_not_active}
    end
  end

  @doc """
  Reverse route. `body` is the decoded JSON map. Reasons: `:reason_invalid`, `:not_found`,
  `:document_not_posted`, `:document_reversed`, `:reversal_pending`, `:posting_inconsistent`,
  `:definition_not_active`, `:internal`.
  """
  @spec reverse(String.t(), term(), term(), map(), term(), term()) ::
          {:ok, map()} | {:error, atom()}
  def reverse(prefix, id, body, %{actor_id: actor, activator: activator}, authorized, fetch) do
    with {:ok, reason_code, reason_text} <- reversal_reason(body),
         {:ok, view} <- fetch.(prefix, id),
         marks = marks(prefix, [view.id]) |> Map.get(view.id, %{}),
         :ok <- reversible(prefix, view, marks),
         {:ok, entry_id} <- posting_entry(authorized, view),
         :ok <- active(prefix, @reversal_definition, activator),
         %{} = issued <- issued(prefix, view.id) || {:error, :internal},
         reversal = %{
           entry_id: entry_id,
           mark_id: marks["posted"].record_id,
           reason_code: reason_code,
           reason_text: reason_text
         },
         {:ok, _instance} <- start_reversal(prefix, view, issued, reversal, actor) do
      fetch.(prefix, id)
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _other -> {:error, :internal}
    end
  end

  defp reversal_reason(%{"reason_code" => code} = body) when code in @reasons do
    text = Map.get(body, "reason_text")

    with true <- text == nil or is_binary(text),
         text = normalize(text),
         true <- text == nil or String.length(text) <= @reason_text_max,
         true <- code != "other" or (is_binary(text) and String.trim(text) != "") do
      {:ok, code, text}
    else
      _bad -> {:error, :reason_invalid}
    end
  end

  defp reversal_reason(_body), do: {:error, :reason_invalid}

  defp normalize(nil), do: nil

  defp normalize(text) do
    case :unicode.characters_to_nfc_binary(text) do
      binary when is_binary(binary) -> binary
      _error -> text
    end
  end

  defp reversible(prefix, view, marks) do
    cond do
      Map.has_key?(marks, "reversed") -> {:error, :document_reversed}
      not Map.has_key?(marks, "posted") -> {:error, :document_not_posted}
      pending(prefix, view.id).reverse -> {:error, :reversal_pending}
      true -> :ok
    end
  end

  # The one posting entry (cause of the kind) of the document, read through the caller's
  # tenant-wide authorization.
  defp posting_entry(authorized, view) do
    cause = Kinds.get(view.kind).cause

    case entries(authorized, view.id) do
      {:ok, rows} ->
        case Enum.filter(rows, &(&1.cause == cause)) do
          [%{entry_id: entry_id}] -> {:ok, entry_id}
          _none_or_many -> {:error, :posting_inconsistent}
        end

      :truncated ->
        {:error, :posting_inconsistent}

      :error ->
        {:error, :internal}
    end
  end

  @doc """
  Cancel route: cancels the issued version when the document is reversed, or issued with no mark
  and no pending task. Reasons: `:not_found`, `:document_not_issued`, `:posting_pending`,
  `:reversal_pending`, `:document_posted`, `{:unprocessable, atom}`, `:internal`.
  """
  @spec cancel(String.t(), term(), map(), String.t(), term()) :: {:ok, map()} | {:error, term()}
  def cancel(prefix, id, body, actor, fetch) do
    with {:ok, view} <- fetch.(prefix, id),
         :ok <- cancellable(prefix, view),
         %{} = issued <- issued(prefix, view.id) || {:error, :internal},
         {:ok, reason} <- cancel_reason(body),
         {:ok, _version} <- do_cancel(prefix, view, issued, reason, actor) do
      fetch.(prefix, id)
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :internal}
    end
  end

  defp cancel_reason(%{} = body), do: {:ok, Map.get(body, "reason")}
  defp cancel_reason(_body), do: {:error, :reason_invalid}

  defp cancellable(prefix, view) do
    pending = pending(prefix, view.id)

    cond do
      view.state in ["draft", "cancelled"] -> {:error, :document_not_issued}
      pending.post -> {:error, :posting_pending}
      pending.reverse -> {:error, :reversal_pending}
      view.state == "posted" -> {:error, :document_posted}
      true -> :ok
    end
  end

  defp do_cancel(prefix, view, issued, reason, actor) do
    args = %{document_id: view.id, version_no: issued.version_no, reason: reason}

    case Documents.cancel(prefix, args, actor) do
      {:ok, version} -> {:ok, version}
      {:error, :not_issued} -> {:error, :document_not_issued}
      {:error, :not_found} -> {:error, :not_found}
      {:error, {:unprocessable, reason}} -> {:error, {:unprocessable, reason}}
      {:error, :busy} -> {:error, :busy}
      {:error, other} -> {:error, log_internal(other)}
    end
  end

  defp log_internal(reason) do
    Logger.warning("stock cancel refused: #{inspect(tag(reason))}")
    :internal
  end

  # -- marks, tasks, entries ----------------------------------------------------------------------

  @doc "The live marks of the documents `ids`: `%{doc_id => %{\"posted\" => m, \"reversed\" => m}}`."
  @spec marks(String.t(), [String.t()]) :: map()
  def marks(_prefix, []), do: %{}

  def marks(prefix, ids) do
    query =
      from(r in Latest,
        where:
          r.entity_type == ^@mark_type and not r.deleted and
            fragment("?->>'document_id' = ANY(?)", r.field_values, type(^ids, {:array, :string})),
        select: {r.record_id, r.field_values, r.inserted_at}
      )

    prefix
    |> then(&Repo.all(query, prefix: &1))
    |> Enum.reduce(%{}, fn {record_id, fv, at}, acc ->
      mark = %{record_id: record_id, at: at}
      Map.update(acc, fv["document_id"], %{fv["mark"] => mark}, &Map.put(&1, fv["mark"], mark))
    end)
  end

  @doc "Which post / reverse tasks of the document's active instances are pending."
  @spec pending(String.t(), String.t()) :: %{post: boolean(), reverse: boolean()}
  def pending(prefix, id) do
    ids =
      Enum.flat_map(
        Kinds.definition_names() ++ [@reversal_definition],
        &definition_ids(prefix, &1)
      )

    nodes =
      Repo.all(
        from(t in Task,
          join: p in InstanceProjection,
          on: p.instance_id == t.instance_id,
          where:
            t.status == :pending and t.node_id in ["post", "reverse"] and p.status == :active and
              p.definition_id in ^ids and fragment("?->>'document_id' = ?", p.variables, ^id),
          select: t.node_id
        ),
        prefix: prefix
      )

    %{post: "post" in nodes, reverse: "reverse" in nodes}
  end

  defp completer(prefix, id, node) do
    Repo.one(
      from(t in Task,
        join: p in InstanceProjection,
        on: p.instance_id == t.instance_id,
        where:
          t.status == :completed and t.node_id == ^node and
            fragment("?->>'document_id' = ?", p.variables, ^id),
        order_by: [desc: t.completed_at],
        limit: 1,
        select: t.completed_by
      ),
      prefix: prefix
    )
  end

  defp entries(authorized, id) do
    case Ledger.entries(authorized, %{"document_id" => id}, %{limit: 100}) do
      {:ok, %{rows: rows, next_cursor: nil}} -> {:ok, rows}
      {:ok, %{rows: _rows}} -> :truncated
      {:error, _reason} -> :error
    end
  end

  # -- read side ----------------------------------------------------------------------------------

  @doc """
  The posting fields of one document view: `posted_at, posted_by, entry_id, reversed_at,
  reversed_by, posting_check`, and the derived `state` for a live version status. `authorized` is
  the caller's ledger read authorization (or `nil`: `posting_check` is then `nil`).
  """
  @spec state_fields(String.t(), map(), term()) :: map()
  def state_fields(prefix, base, authorized) do
    marks = marks(prefix, [base.id]) |> Map.get(base.id, %{})
    state = derive_state(base.state, marks)
    rows = if authorized, do: entries(authorized, base.id), else: :error
    receipt = receipt_row(rows, Kinds.get(base.kind).cause)

    %{
      state: state,
      posted_at: marks |> Map.get("posted") |> mark_at(),
      posted_by: if(marks["posted"], do: completer(prefix, base.id, "post")),
      entry_id: receipt && receipt.entry_id,
      reversed_at: marks |> Map.get("reversed") |> mark_at(),
      reversed_by: if(marks["reversed"], do: completer(prefix, base.id, "reverse")),
      posting_check: posting_check(base, state, marks, rows, prefix)
    }
  end

  defp derive_state("issued", marks) do
    cond do
      Map.has_key?(marks, "reversed") -> "reversed"
      Map.has_key?(marks, "posted") -> "posted"
      true -> "issued"
    end
  end

  defp derive_state(state, _marks), do: state

  defp mark_at(nil), do: nil

  defp mark_at(%{at: at}), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  @doc "The derived state of each document of a page: `%{doc_id => state}` for the given rows."
  @spec states_for(String.t(), [map()]) :: map()
  def states_for(prefix, rows) do
    marks = marks(prefix, Enum.map(rows, & &1.id))
    Map.new(rows, &{&1.id, derive_state(&1.state, Map.get(marks, &1.id, %{}))})
  end

  defp receipt_row({:ok, rows}, cause) do
    case Enum.filter(rows, &(&1.cause == cause)) do
      [one] -> one
      _none_or_many -> nil
    end
  end

  defp receipt_row(_unavailable, _cause), do: nil

  defp posting_check(_base, _state, _marks, :error, _prefix), do: nil
  # More than one page of entries for one document cannot happen without a flood.
  defp posting_check(_base, _state, _marks, :truncated, _prefix), do: "mismatch"

  defp posting_check(base, state, marks, {:ok, rows}, prefix) do
    receipts = Enum.filter(rows, &(&1.cause == Kinds.get(base.kind).cause))
    reversals = Enum.filter(rows, &(&1.cause == "reversal"))

    cond do
      state == "cancelled" ->
        if Enum.all?(receipts, fn r ->
             Enum.any?(reversals, &(&1.reverses_entry_id == r.entry_id))
           end),
           do: "ok",
           else: "mismatch"

      rows == [] and marks == %{} ->
        nil

      state == "draft" ->
        "mismatch"

      true ->
        if consistent?(base, state, marks, receipts, reversals, prefix),
          do: "ok",
          else: "mismatch"
    end
  end

  defp consistent?(base, state, marks, receipts, reversals, prefix) do
    case receipts do
      [receipt] ->
        legs_match?(receipt, expected_legs(prefix, base)) and
          Map.has_key?(marks, "posted") and
          reversal_consistent?(state, marks, receipt, reversals)

      _none_or_many ->
        false
    end
  end

  defp reversal_consistent?("reversed", marks, receipt, [reversal]),
    do: Map.has_key?(marks, "reversed") and reversal.reverses_entry_id == receipt.entry_id

  defp reversal_consistent?("reversed", _marks, _receipt, _reversals), do: false

  defp reversal_consistent?(_state, marks, _receipt, reversals),
    do: reversals == [] and not Map.has_key?(marks, "reversed")

  # Expected legs from the frozen content: a multiset of {sku, location, org_unit, responsible,
  # lot, unit, signed quantity}, quantity normalised as a Decimal. A two-sided kind (REQ-721) gives
  # per line a `-q` leg at the from side and a `+q` leg at the to side (`Kinds.sides/2`, the same
  # function the posting command uses).
  defp expected_legs(prefix, base) do
    case issued(prefix, base.id) do
      %{content: content} ->
        spec = Kinds.get(base.kind)
        {from, to} = Kinds.sides(spec, Map.get(content, "header", %{}))

        Enum.flat_map(Map.get(content, "lines", []), fn line ->
          quantity = Map.get(line, "quantity")
          leg = &leg_key(line, &1, &2)

          if from,
            do: [leg.(from, negate(quantity)), leg.(to, quantity)],
            else: [leg.(to, quantity)]
        end)
        |> Enum.sort()

      _none ->
        :none
    end
  end

  defp leg_key(line, side, quantity) do
    leg_key(
      Map.get(line, "catalog_item_id"),
      side.location,
      side.org_unit,
      side.responsible,
      Map.get(line, "catalog_lot_id"),
      Map.get(line, "catalog_uom_id"),
      quantity
    )
  end

  defp negate(quantity) do
    case Decimal.parse(to_string(quantity)) do
      {%Decimal{} = d, ""} -> d |> Decimal.negate() |> Decimal.to_string(:normal)
      _bad -> "invalid"
    end
  end

  defp legs_match?(_receipt, :none), do: false

  defp legs_match?(receipt, expected) do
    actual =
      receipt.legs
      |> Enum.map(fn leg ->
        [sku, location, org_unit, responsible, lot] = pad(Map.get(leg, :k, []))
        leg_key(sku, location, org_unit, responsible, lot, leg.unit_ref, leg.quantity)
      end)
      |> Enum.sort()

    actual == expected
  end

  defp pad(k), do: k |> Enum.take(5) |> then(&(&1 ++ List.duplicate(nil, 5 - length(&1))))

  defp leg_key(sku, location, org_unit, responsible, lot, unit, quantity) do
    {sku, location, org_unit, blank(responsible), blank(lot), unit, decimal_text(quantity)}
  end

  defp blank(nil), do: ""
  defp blank(value), do: value

  defp decimal_text(quantity) do
    case Decimal.parse(to_string(quantity)) do
      {%Decimal{} = d, ""} -> d |> Decimal.normalize() |> Decimal.to_string(:normal)
      _bad -> "invalid"
    end
  end
end
