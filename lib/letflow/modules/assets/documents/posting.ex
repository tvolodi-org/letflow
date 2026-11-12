defmodule Letflow.Modules.Assets.Documents.Posting do
  @moduledoc """
  GH #3890 / REQ-752 (assets C10): posting and reversal of an issued asset document. Mirrors
  `Letflow.Modules.Stock.Documents.Posting` reduced to the commission (module `assets` cannot call
  `stock`, boundary Rule 4). Public functions: `ensure_active/3`, `issued/2`, `start_post/4`,
  `start_reversal/5`, `reverse/6` (the route's work), `state_fields/3` and `states_for/2` (the read
  side), `marks/2`, `pending/2`. The tenant is the `prefix` argument and nothing else (INV-1).

  ## How a document posts

  The issue step starts ONE instance of the module's process definition `assets_commission`
  (`Letflow.Engine.create/2`, no correlation key; the idempotency key `assets-post:<version id>:<n>`
  is used). Completing its HUMAN_TASK `post` runs the write handler `post_document`
  (`Letflow.Modules.Assets.Handlers`): the ledger entry and the `assets_posting_mark` record commit
  together or not at all. The command is built here ONLY from the issued version's frozen content. It
  carries the offline triple `device_id`, `client_seq`, `client_event_time` so the entry gets the
  header's event time, not the posting time; a reversal is posted online. Cancel and the post-retry
  route are not built (the runbook says so): a lost start leaves an issued document with no instance.

  ## Lazy activation

  Install leaves the pack's process definitions as module-stamped drafts. `ensure_active/3`
  activates the draft with the REQUEST's activator; it answers `:error` (the routes' 409
  `definition_not_active`) when there is none, the activator lacks `DefinitionsActivate` or
  `EntitiesRecordsWrite`, the activation is refused, or an active definition of that name is not
  this module's.

  ## Read states

  `state_fields/3` derives `posted_at`, `posted_by`, `entry_id`, `reversed_at`, `reversed_by` and
  `posting_check` from the marks, the completed tasks and the ledger entries of the document.
  `posting_check` is `"ok"`, `"mismatch"` or `nil` and never carries a detail (decision 0078 D5: the
  binding of the posting to the issued content is detected here, not enforced, until L7).
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Letflow.Definitions
  alias Letflow.Definitions.OwnerStamp
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Documents.Document
  alias Letflow.Documents.DocumentVersion
  alias Letflow.Engine
  alias Letflow.Engine.Task
  alias Letflow.Entities.Record.Latest
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Ledger
  alias Letflow.Modules.Assets.Documents.CardMoves
  alias Letflow.Modules.Assets.Documents.KindChangePosting
  alias Letflow.Modules.Assets.Documents.Kinds
  alias Letflow.Modules.KeyHelpers
  alias Letflow.Repo

  @reversal_definition "assets_reversal"
  @mark_type "assets_posting_mark"
  @reasons ~w(wrong_document wrong_quantity wrong_master_data other)
  @reason_text_max 500
  @max_number 10_000_000
  @unit "pcs"

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
      {:ok, row} -> if assets_stamped?(row), do: :ok, else: :error
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
        Logger.warning("assets definition activation refused: #{inspect(tag(reason))}")
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
        where: d.name == ^name and d.status == :draft and d.owner_module == "assets",
        order_by: [desc: d.created_at],
        limit: 1
      ),
      prefix: prefix
    )
  end

  defp assets_stamped?(row), do: match?({:ok, %{module_id: "assets"}}, OwnerStamp.from_row(row))

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
  Starts one `assets_commission` instance for the issued document `view` (as `Documents.fetch/3`
  renders it) with `issued` (from `issued/2`). `{:ok, instance_id}` or `{:error, reason}`.
  """
  @spec start_post(String.t(), map(), map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def start_post(prefix, view, issued, actor) do
    spec = Kinds.get(view.kind)

    with :ok <- start_seam(),
         {:ok, command, extra} <- post_commands(prefix, spec, view, issued) do
      vars =
        Map.merge(extra, %{
          "document_id" => view.id,
          "document_type" => spec.type_key,
          "version_no" => issued.version_no,
          "org_unit_id" => view.org_unit_id,
          "mark" => "posted",
          "posting" => command
        })

      start(prefix, spec.definition, "assets-post", issued.version_id, view.id, vars, actor)
    end
  end

  # A change of kind posts two entries: the asset command is `posting`, the stock one `stock_posting`.
  defp post_commands(_prefix, %{kind: "kind_change"}, view, issued) do
    with {:ok, %{assets: assets, stock: stock}} <- KindChangePosting.commands(view, issued),
         do: {:ok, assets, %{"stock_posting" => stock}}
  end

  defp post_commands(prefix, spec, view, issued) do
    with {:ok, command} <- post_command(spec, view, issued),
         {:ok, command} <- with_card_moves(prefix, spec, issued, command),
         do: {:ok, command, %{}}
  end

  # G2: a hand over carries the moves of its cards (`CardMoves`), read now and pinned by the handler.
  defp with_card_moves(prefix, %{kind: "handover"}, %{content: content}, command) do
    with {:ok, moves} <-
           CardMoves.forward(
             prefix,
             Map.get(content, "header", %{}),
             Map.get(content, "lines", [])
           ) do
      {:ok, if(moves == [], do: command, else: Map.put(command, "card_moves", moves))}
    end
  end

  defp with_card_moves(_prefix, _spec, _issued, command), do: {:ok, command}

  @doc "Starts one `assets_reversal` instance (see the moduledoc)."
  @spec start_reversal(String.t(), map(), map(), map(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def start_reversal(prefix, view, issued, reversal, actor) do
    type_key = Kinds.get(view.kind).type_key

    with {:ok, command} <- reversal_command(prefix, view, issued, reversal, type_key) do
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

      start(prefix, @reversal_definition, "assets-rev", issued.version_id, view.id, vars, actor)
    end
  end

  # G2: the reversal of a hand over carries the moves that restore the cards still at the destination.
  defp reversal_command(prefix, view, %{content: content}, reversal, type_key) do
    command = %{
      "cause" => "reversal",
      "reverses_entry_id" => reversal.entry_id,
      "reason_code" => reversal.reason_code,
      "document_type" => type_key,
      "document_id" => view.id,
      "client_op_id" => reversal.mark_id
    }

    if view.kind == "handover" do
      with {:ok, moves} <-
             CardMoves.backward(
               prefix,
               Map.get(content, "header", %{}),
               Map.get(content, "lines", [])
             ) do
        {:ok, if(moves == [], do: command, else: Map.put(command, "card_moves", moves))}
      end
    else
      {:ok, command}
    end
  end

  # Test seam: forces a start failure after the issue committed. Read here only.
  defp start_seam do
    if Application.get_env(:letflow, :assets_post_start_fail?) == true,
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
        Logger.warning("assets posting start refused: #{inspect(tag(reason))}")
        {:error, :start_failed}
    end
  end

  defp definition_ids(prefix, name) do
    Repo.all(
      from(d in ProcessDefinition,
        where: d.name == ^name and d.owner_module == "assets",
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
  # RECORD ids (`view.lines` are the records; nothing changes after issue). The `to` side of every
  # line comes from `Kinds.sides/2`.
  defp post_command(spec, view, %{content: content, number: number, period: period} = issued) do
    header = Map.get(content, "header", %{})
    lines = Map.get(content, "lines", [])
    line_ids = Map.new(view.lines, &{&1.line_no, &1.line_id})

    with {:ok, seq} <- client_seq(period, number),
         {:ok, built} <- build_lines(lines, Kinds.sides(spec, header), line_ids) do
      {:ok,
       with_reason(spec, header, %{
         "cause" => spec.cause,
         "document_type" => spec.type_key,
         "document_id" => view.id,
         "client_op_id" => issued.version_id,
         "device_id" => spec.device_id,
         "client_seq" => seq,
         "client_event_time" => Map.get(header, "event_time"),
         "lines" => built
       })}
    end
  end

  # The write off carries its reason code (the ledger policy refuses it without); other kinds none.
  defp with_reason(%{kind: "writeoff"}, header, command),
    do: Map.put(command, "reason_code", Map.get(header, "reason_code"))

  defp with_reason(_spec, _header, command), do: command

  @doc false
  def client_seq(period, number) when is_binary(period) and is_integer(number) do
    with {year, ""} <- Integer.parse(period),
         true <- number >= 0 and number < @max_number do
      {:ok, year * @max_number + number}
    else
      _bad -> {:error, :number_out_of_range}
    end
  end

  def client_seq(_period, _number), do: {:error, :number_out_of_range}

  defp build_lines(lines, {from, to}, line_ids) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      with {:ok, line_id} <- Map.fetch(line_ids, Map.get(line, "line_no")),
           {:ok, quantity} <- whole_text(Map.get(line, "quantity")) do
        built = %{
          "line_id" => line_id,
          "asset" => Map.get(line, "asset_id"),
          "quantity" => quantity,
          "from" => side_map(from),
          "to" => side_map(to)
        }

        {:cont, {:ok, [built | acc]}}
      else
        :error -> {:halt, {:error, :line_record_missing}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  # The ledger policy takes whole-number text ("200"), the record holds "200.000000000".
  @doc false
  def whole_text(text) do
    case Decimal.parse(to_string(text)) do
      {%Decimal{} = d, ""} ->
        if Decimal.equal?(Decimal.round(d, 0), d),
          do: {:ok, d |> Decimal.to_integer() |> Integer.to_string()},
          else: {:error, :quantity_not_whole}

      _bad ->
        {:error, :quantity_not_whole}
    end
  end

  defp side_map(nil), do: nil

  defp side_map(side) do
    %{
      "org_unit" => side.org_unit,
      "location" => side.location,
      "material_responsible" => side.material_responsible,
      "actual_user" => side.actual_user
    }
  end

  # -- the reverse route's work -------------------------------------------------------------------

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
         # REQ-760 part A: the pair reversal of a change of kind is part B; the plain reversal
         # would reverse only the asset entry and the ledger refuses a half of a pair.
         :ok <- not_kind_change(view),
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

  defp not_kind_change(%{kind: "kind_change"}), do: {:error, :posting_inconsistent}
  defp not_kind_change(_view), do: :ok

  defp active(prefix, name, activator) do
    case ensure_active(prefix, name, activator) do
      :ok -> :ok
      :error -> {:error, :definition_not_active}
    end
  end

  @doc false
  def reversal_reason(%{"reason_code" => code} = body) when code in @reasons do
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

  def reversal_reason(_body), do: {:error, :reason_invalid}

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
            t.status == :pending and t.node_id in ^["post", "reverse"] and
              p.status == :active and
              p.definition_id in ^ids and fragment("?->>'document_id' = ?", p.variables, ^id),
          select: t.node_id
        ),
        prefix: prefix
      )

    %{post: "post" in nodes, reverse: "reverse" in nodes}
  end

  @doc false
  def completer(prefix, id, node) do
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

  @doc false
  def entries(authorized, id) do
    case Ledger.entries(authorized, %{"document_id" => id}, %{limit: 100}) do
      {:ok, %{rows: rows, next_cursor: nil}} -> {:ok, rows}
      {:ok, %{rows: _rows}} -> :truncated
      {:error, _reason} -> :error
    end
  end

  # -- read side ----------------------------------------------------------------------------------

  @doc """
  The posting fields of one document view: `state, posted_at, posted_by, entry_id, reversed_at,
  reversed_by, posting_check`. `authorized` is the caller's ledger read authorization (or `nil`:
  `posting_check` is then `nil`).
  """
  @spec state_fields(String.t(), map(), term(), keyword()) :: map()
  def state_fields(prefix, base, authorized, opts \\ []) do
    marks = marks(prefix, [base.id]) |> Map.get(base.id, %{})
    state = derive_state(base.state, marks)
    rows = if authorized, do: entries(authorized, base.id), else: :error
    kind = Kinds.get(base.kind)
    posted = posted_row(rows, kind.cause)

    Map.merge(
      %{
        state: state,
        posted_at: marks |> Map.get("posted") |> mark_at(),
        posted_by: if(marks["posted"], do: completer(prefix, base.id, kind.completion_node)),
        entry_id: posted && posted.entry_id,
        reversed_at: marks |> Map.get("reversed") |> mark_at(),
        reversed_by: if(marks["reversed"], do: completer(prefix, base.id, "reverse")),
        posting_check: posting_check(base, state, marks, rows, prefix, kind, opts)
      },
      card_lines(base, posted)
    )
  end

  # REQ-760 part A: the card of each line of a posted change of kind, derived from the asset entry
  # (the stored `asset_card_id` is empty until part B). Other kinds and unposted documents: no change.
  defp card_lines(%{kind: "kind_change", lines: lines}, %{} = posted) do
    ids = KindChangePosting.card_ids(posted)
    %{lines: Enum.map(lines, &Map.put(&1, :asset_card_id, Map.get(ids, &1.line_id)))}
  end

  defp card_lines(_base, _posted), do: %{}

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

  defp posted_row({:ok, rows}, cause) do
    case Enum.filter(rows, &(&1.cause == cause)) do
      [one] -> one
      _none_or_many -> nil
    end
  end

  defp posted_row(_unavailable, _cause), do: nil

  defp posting_check(_base, _state, _marks, :error, _prefix, _kind, _opts), do: nil
  defp posting_check(_base, _state, _marks, :truncated, _prefix, _kind, _opts), do: "mismatch"

  # A change of kind: two registers. Without the stock read authorization the check is unavailable.
  defp posting_check(
         base,
         state,
         marks,
         {:ok, rows} = asset_rows,
         prefix,
         %{kind: "kind_change"},
         opts
       ) do
    stock_rows =
      if opts[:stock_authorized], do: entries(opts[:stock_authorized], base.id), else: :error

    cond do
      rows == [] and marks == %{} -> nil
      state == "draft" -> "mismatch"
      stock_rows == :error -> nil
      not Map.has_key?(marks, "posted") -> "mismatch"
      true -> KindChangePosting.check(prefix, base, asset_rows, stock_rows)
    end
  end

  defp posting_check(base, state, marks, {:ok, rows}, prefix, kind, _opts) do
    postings = Enum.filter(rows, &(&1.cause == kind.cause))
    reversals = Enum.filter(rows, &(&1.cause == "reversal"))

    cond do
      rows == [] and marks == %{} -> nil
      state == "draft" -> "mismatch"
      consistent?(base, state, marks, postings, reversals, prefix) -> "ok"
      true -> "mismatch"
    end
  end

  defp consistent?(base, state, marks, [posting], reversals, prefix) do
    legs_match?(posting, expected_legs(prefix, base)) and
      Map.has_key?(marks, "posted") and
      reversal_consistent?(state, marks, posting, reversals)
  end

  defp consistent?(_base, _state, _marks, _none_or_many, _reversals, _prefix), do: false

  defp reversal_consistent?("reversed", marks, posting, [reversal]),
    do: Map.has_key?(marks, "reversed") and reversal.reverses_entry_id == posting.entry_id

  defp reversal_consistent?("reversed", _marks, _posting, _reversals), do: false

  defp reversal_consistent?(_state, marks, _posting, reversals),
    do: reversals == [] and not Map.has_key?(marks, "reversed")

  # Expected legs from the frozen content: a sorted multiset of {asset, org_unit, location,
  # responsible, actual_user, unit, signed quantity}, quantity as a normalised Decimal text. Per
  # line a `+q` leg at the `to` side and a `-q` leg at the `from` side, where the kind has them
  # (`Kinds.sides/2`, the same function the posting command uses).
  defp expected_legs(prefix, base) do
    case issued(prefix, base.id) do
      %{content: content} ->
        {from, to} = Kinds.sides(Kinds.get(base.kind), Map.get(content, "header", %{}))

        content
        |> Map.get("lines", [])
        |> Enum.flat_map(fn line ->
          quantity = Map.get(line, "quantity")
          asset = Map.get(line, "asset_id")

          [
            expected_leg(asset, to, quantity),
            expected_leg(asset, from, negate(quantity))
          ]
          |> Enum.reject(&is_nil/1)
        end)
        |> Enum.sort()

      _none ->
        :none
    end
  end

  defp expected_leg(_asset, nil, _quantity), do: nil

  defp expected_leg(asset, side, quantity) do
    leg_key(
      asset,
      side.org_unit,
      side.location,
      side.material_responsible,
      side.actual_user,
      @unit,
      quantity
    )
  end

  defp negate(quantity) do
    case Decimal.parse(to_string(quantity)) do
      {%Decimal{} = d, ""} -> Decimal.negate(d)
      _bad -> "invalid"
    end
  end

  @doc false
  def legs_match?(_posting, :none), do: false

  def legs_match?(posting, expected) do
    actual =
      posting.legs
      |> Enum.map(fn leg ->
        [asset, unit, location, responsible, actual_user] = pad(Map.get(leg, :k, []))
        leg_key(asset, unit, location, responsible, actual_user, leg.unit_ref, leg.quantity)
      end)
      |> Enum.sort()

    actual == expected
  end

  defp pad(k), do: KeyHelpers.pad(k)

  defp leg_key(asset, org_unit, location, responsible, actual_user, unit, quantity) do
    {asset, org_unit, blank(location), responsible, blank(actual_user), unit,
     decimal_text(quantity)}
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
