defmodule Letflow.Modules.Stock.Documents do
  @moduledoc """
  REQ-712 / GH #3749 (assets B4 part 1): the stock document context. The one writer of the receipt
  header (`stock_receipt`) and line (`stock_receipt_line`) records and of the versioned document
  (`Letflow.Documents`, decision 0056) behind them. Public functions: `save/3`, `replace/4`,
  `discard/3`, `issue/3` (writes) and `fetch/2`, `list/2` (reads). The tenant is the `prefix` argument
  and nothing else (INV-1); the router derives it from the token.

  ## Two stores, one writer

  Each save, replace, discard and issue is one `Repo.transaction`; a failed step calls `Repo.rollback/1`
  so nothing partial stays. Record writes use the stock module authority
  (`Letflow.Entities.ManagedTypes.owner_for!/1`), a fresh idempotency key per write and the default
  scope `:all` (only tenant-wide principals reach the routes, see `Letflow.Modules.Stock.Access`).
  `document_id` on the header is the id of the versioned document, which never changes and carries the
  state: `draft`, `issued` or `cancelled` (the status of its live version), the gap-free number and the
  issued time. Nothing of that is stored on the header. The id on the routes is this document id.

  ## Rules

  * Save and replace check the shape only (`Letflow.Modules.Stock.Documents.Shape`); master data are
    checked at issue (`Letflow.Modules.Stock.Documents.Checks`), and the event-time window too.
  * A replace takes the full document and writes the full new field values: an omitted optional key is
    removed, a line left out is deleted (soft delete). The issuing org unit of the versioned document
    cannot change on a draft (`Letflow.Documents.edit_draft/4` keeps it): a body with another
    `org_unit_id` is `field_invalid`; discard the draft and create a new one. Assumption, owner may
    change at GATE B.
  * Replace and discard lock the `documents` row (`FOR UPDATE`) first, the same lock
    `Letflow.Documents` takes, so concurrent replace, discard and issue serialise; a draft re-read under
    the lock decides `document_not_draft`.
  * Issue runs the checks first and calls `Letflow.Documents.issue/2` once, so a refused check takes no
    number. `{:error, :busy}` from it stays `:busy`. After issue replace and discard are refused.
  * The clock of the event-time window is the app env `:stock_documents_clock` (a zero-arity function,
    default `DateTime.utc_now/0`); it exists only so a test can fix the time.

  Errors: `{:error, :not_found}`, `{:error, :document_not_draft}`, `{:error, :busy}`,
  `{:error, :internal}` or `{:error, {reason, extras}}` (a 422, `reason` a string, `extras` a map with
  the fixed keys `"field"` and `"line_no"`).
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Letflow.Documents
  alias Letflow.Documents.Document
  alias Letflow.Documents.DocumentType
  alias Letflow.Documents.DocumentVersion
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.Modules.Stock
  alias Letflow.Modules.Stock.Documents.Checks
  alias Letflow.Modules.Stock.Documents.Shape
  alias Letflow.Repo

  @type_key "stock_receipt"
  @header_type "stock_receipt"
  @line_type "stock_receipt_line"
  @states ~w(draft issued cancelled)
  @status_atoms %{"draft" => :draft, "issued" => :issued, "cancelled" => :cancelled}
  @default_limit 50
  @max_limit 100
  @list_keys ~w(kind state org_unit_id limit cursor)
  @cursor ~r/\A([0-9]{1,18})\.([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\z/
  @limit ~r/\A[1-9][0-9]{0,2}\z/

  @doc "The state names a list filter accepts."
  @spec states() :: [String.t()]
  def states, do: @states

  # -- writes -------------------------------------------------------------------------------------

  @doc """
  Creates the versioned draft, the header and the lines from `body` (string keys). Returns the new
  document as `fetch/2` renders it.
  """
  @spec save(String.t(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def save(prefix, body, actor) when is_binary(prefix) do
    with {:ok, doc} <- Shape.parse(body, :create) do
      tx(prefix, fn ->
        unit = doc.header["org_unit_id"]

        draft_attrs = %{
          type_key: @type_key,
          issuing_org_unit_id: unit,
          content: content(doc)
        }

        case Documents.create_draft(prefix, draft_attrs, actor) do
          {:ok, %{document: document}} -> write_new(prefix, document.id, doc, actor)
          {:error, reason} -> Repo.rollback(draft_error(reason))
        end
      end)
    end
  end

  @doc "Replaces the whole draft `id` with `body`; see the moduledoc."
  @spec replace(String.t(), term(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def replace(prefix, id, body, actor) when is_binary(prefix) do
    with {:ok, id} <- cast(id),
         {:ok, current} <- fetch(prefix, id),
         :ok <- draft?(current),
         {:ok, doc} <- Shape.parse(body, {:replace, current.kind}),
         :ok <- same_unit(current, doc) do
      tx(prefix, fn ->
        lock!(prefix, id)
        locked = fetch!(prefix, id)
        if locked.state != "draft", do: Repo.rollback(:document_not_draft)

        write_header!(prefix, :update, locked.header_id, id, doc, actor)
        write_lines!(prefix, locked, doc, actor)

        case Documents.edit_draft(prefix, id, content(doc), actor) do
          {:ok, _version} -> :ok
          {:error, reason} -> Repo.rollback(draft_error(reason))
        end

        fetch!(prefix, id)
      end)
    end
  end

  @doc "Discards draft `id`: the versioned draft is discarded, the header and lines are soft-deleted."
  @spec discard(String.t(), term(), String.t()) :: :ok | {:error, term()}
  def discard(prefix, id, actor) when is_binary(prefix) do
    with {:ok, id} <- cast(id),
         {:ok, current} <- fetch(prefix, id),
         :ok <- draft?(current) do
      result =
        tx(prefix, fn ->
          lock!(prefix, id)
          locked = fetch!(prefix, id)
          if locked.state != "draft", do: Repo.rollback(:document_not_draft)

          case Documents.discard_draft(prefix, id, actor) do
            {:ok, _version} -> :ok
            {:error, reason} -> Repo.rollback(draft_error(reason))
          end

          Enum.each(locked.lines, &delete!(prefix, @line_type, &1.line_id, actor))
          delete!(prefix, @header_type, locked.header_id, actor)
          :ok
        end)

      with {:ok, :ok} <- result, do: :ok
    end
  end

  @doc """
  Runs the event-time and master checks of draft `id`, then issues it once. A refused check issues
  nothing and takes no number. Returns the issued document.
  """
  @spec issue(String.t(), term(), String.t()) :: {:ok, map()} | {:error, term()}
  def issue(prefix, id, actor) when is_binary(prefix) do
    with {:ok, id} <- cast(id),
         {:ok, view} <- fetch(prefix, id),
         :ok <- draft?(view),
         :ok <- Checks.event_time(view.event_time, now()),
         :ok <- Checks.masters(prefix, view),
         {:ok, _issued} <- issue_once(prefix, id, actor) do
      fetch(prefix, id)
    end
  end

  defp issue_once(prefix, id, actor) do
    case Documents.issue(prefix, %{document_id: id, actor_id: actor}) do
      {:ok, issued} -> {:ok, issued}
      {:error, :busy} -> {:error, :busy}
      {:error, :no_draft} -> {:error, :document_not_draft}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> internal(reason)
    end
  end

  # -- write helpers ------------------------------------------------------------------------------

  defp write_new(prefix, document_id, doc, actor) do
    header_id = write_header!(prefix, :create, nil, document_id, doc, actor)

    for line <- doc.lines do
      create_line!(prefix, header_id, doc.header["org_unit_id"], line, actor)
    end

    fetch!(prefix, document_id)
  end

  defp write_header!(prefix, :create, _record_id, document_id, doc, actor) do
    attrs = %{
      entity_type: @header_type,
      field_values: header_values(doc, document_id),
      actor_id: actor,
      idempotency_key: Ecto.UUID.generate()
    }

    # scope-all: SEC-518-R1 (stock module, header type scoped by org_unit_id; own-record system path)
    case Records.create_record(attrs, prefix, ManagedTypes.owner_for!(Stock)) do
      {:ok, %{record: record}} -> record.record_id
      {:error, reason} -> Repo.rollback(record_error(reason))
    end
  end

  defp write_header!(prefix, :update, record_id, document_id, doc, actor) do
    attrs = %{
      entity_type: @header_type,
      record_id: record_id,
      field_values: header_values(doc, document_id),
      actor_id: actor,
      idempotency_key: Ecto.UUID.generate()
    }

    # scope-all: SEC-518-R1 (stock module, header type scoped by org_unit_id; own-record system path)
    case Records.update_record(attrs, prefix, ManagedTypes.owner_for!(Stock)) do
      {:ok, _} -> record_id
      {:error, reason} -> Repo.rollback(record_error(reason))
    end
  end

  defp create_line!(prefix, header_id, unit, line, actor) do
    attrs = %{
      entity_type: @line_type,
      field_values: line_values(line, header_id, unit),
      actor_id: actor,
      idempotency_key: Ecto.UUID.generate()
    }

    # scope-all: SEC-518-R1 (stock module, line type scoped by org_unit_id; own-record system path)
    case Records.create_record(attrs, prefix, ManagedTypes.owner_for!(Stock)) do
      {:ok, %{record: record}} -> record.record_id
      {:error, reason} -> Repo.rollback(record_error(reason))
    end
  end

  defp update_line!(prefix, line_id, header_id, unit, line, actor) do
    attrs = %{
      entity_type: @line_type,
      record_id: line_id,
      field_values: line_values(line, header_id, unit),
      actor_id: actor,
      idempotency_key: Ecto.UUID.generate()
    }

    # scope-all: SEC-518-R1 (stock module, line type scoped by org_unit_id; own-record system path)
    case Records.update_record(attrs, prefix, ManagedTypes.owner_for!(Stock)) do
      {:ok, _} -> line_id
      {:error, reason} -> Repo.rollback(record_error(reason))
    end
  end

  defp delete!(prefix, type, record_id, actor) do
    attrs = %{
      entity_type: type,
      record_id: record_id,
      actor_id: actor,
      idempotency_key: Ecto.UUID.generate()
    }

    # scope-all: SEC-518-R1 (stock module, own-record system path of a managed type)
    case Records.delete_record(attrs, prefix, ManagedTypes.owner_for!(Stock)) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(record_error(reason))
    end
  end

  # Line `n` of the new document updates existing line `n`, or is created; lines beyond the new
  # count are deleted. The header's org unit never changes on a draft (checked before).
  defp write_lines!(prefix, locked, doc, actor) do
    existing = Map.new(locked.lines, &{&1.line_no, &1})
    count = length(doc.lines)
    unit = doc.header["org_unit_id"]

    for line <- doc.lines do
      case Map.fetch(existing, line["line_no"]) do
        {:ok, old} -> update_line!(prefix, old.line_id, locked.header_id, unit, line, actor)
        :error -> create_line!(prefix, locked.header_id, unit, line, actor)
      end
    end

    for old <- locked.lines, old.line_no > count do
      delete!(prefix, @line_type, old.line_id, actor)
    end

    :ok
  end

  defp header_values(doc, document_id) do
    Map.put(doc.header, "document_id", document_id)
  end

  defp line_values(line, header_id, unit) do
    line |> Map.put("header_id", header_id) |> Map.put("org_unit_id", unit)
  end

  # The versioned content: the saved header and lines, optional keys absent when not given.
  defp content(doc) do
    %{
      "kind" => doc.kind,
      "header" => doc.header,
      "lines" => doc.lines
    }
  end

  defp same_unit(current, doc) do
    if current.org_unit_id == doc.header["org_unit_id"],
      do: :ok,
      else: {:error, {"field_invalid", %{"field" => "org_unit_id"}}}
  end

  defp draft?(%{state: "draft"}), do: :ok
  defp draft?(_view), do: {:error, :document_not_draft}

  defp lock!(prefix, id) do
    case Repo.one(from(d in Document, where: d.id == ^id, lock: "FOR UPDATE"), prefix: prefix) do
      nil -> Repo.rollback(:not_found)
      document -> document
    end
  end

  defp tx(_prefix, fun) do
    Repo.transaction(fun)
  rescue
    error in Postgrex.Error ->
      case error.postgres do
        %{code: code} when code in [:lock_not_available, :query_canceled] -> {:error, :busy}
        _other -> reraise error, __STACKTRACE__
      end
  end

  defp draft_error(reason) when reason in [:org_unit_not_found, :org_unit_required],
    do: {"org_unit_invalid", %{}}

  defp draft_error(:not_found), do: :not_found
  defp draft_error(:no_draft), do: :document_not_draft
  defp draft_error(:busy), do: :busy
  defp draft_error(reason), do: log_internal(reason)

  defp record_error(reason), do: log_internal(reason)

  defp internal(reason), do: {:error, log_internal(reason)}

  defp log_internal(reason) do
    tag = if is_tuple(reason) and tuple_size(reason) > 0, do: elem(reason, 0), else: reason
    Logger.warning("stock document write refused: #{inspect(tag)}")
    :internal
  end

  # -- reads --------------------------------------------------------------------------------------

  @doc """
  The document `id` with its header and lines, or `{:error, :not_found}` (a malformed id, an unknown
  id, a discarded draft and another tenant's id are all that one answer).
  """
  @spec fetch(String.t(), term()) :: {:ok, map()} | {:error, :not_found}
  def fetch(prefix, id) when is_binary(prefix) do
    with {:ok, id} <- cast(id),
         %Document{type_key: @type_key} = document <- Repo.get(Document, id, prefix: prefix),
         %DocumentVersion{} = version <- live_version(prefix, id),
         {:ok, header} <- header(prefix, id) do
      {:ok, view(prefix, document, version, header)}
    else
      _none -> {:error, :not_found}
    end
  end

  defp fetch!(prefix, id) do
    case fetch(prefix, id) do
      {:ok, view} -> view
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp live_version(prefix, id) do
    Repo.one(
      from(v in DocumentVersion,
        where: v.document_id == ^id and v.status in [:draft, :issued, :cancelled],
        order_by: [desc: v.version_no],
        limit: 1
      ),
      prefix: prefix
    )
  end

  defp header(prefix, document_id) do
    query =
      from(r in Latest,
        where:
          r.entity_type == ^@header_type and not r.deleted and
            fragment("?->>'document_id' = ?", r.field_values, ^document_id),
        select: {r.record_id, r.field_values},
        limit: 1
      )

    case Repo.one(query, prefix: prefix) do
      nil -> :error
      {record_id, fv} -> {:ok, {record_id, fv}}
    end
  end

  defp lines(prefix, header_id) do
    query =
      from(r in Latest,
        where:
          r.entity_type == ^@line_type and not r.deleted and
            fragment("?->>'header_id' = ?", r.field_values, ^header_id),
        select: {r.record_id, r.field_values}
      )

    prefix
    |> then(&Repo.all(query, prefix: &1))
    |> Enum.map(fn {record_id, fv} ->
      %{
        line_id: record_id,
        line_no: fv["line_no"],
        catalog_item_id: fv["catalog_item_id"],
        catalog_uom_id: fv["catalog_uom_id"],
        catalog_lot_id: fv["catalog_lot_id"],
        quantity: fv["quantity"]
      }
    end)
    |> Enum.sort_by(& &1.line_no)
  end

  defp view(prefix, document, version, {header_id, fv}) do
    %{
      id: document.id,
      kind: "receipt",
      state: state(version.status),
      number: number_label(prefix, document),
      issued_at: iso(version.issued_at),
      header_id: header_id,
      org_unit_id: fv["org_unit_id"],
      location_id: fv["location_id"],
      responsible_id: fv["responsible_id"],
      counterparty_id: fv["counterparty_id"],
      event_time: fv["event_time"],
      note: fv["note"],
      lines: lines(prefix, header_id)
    }
  end

  defp state(:draft), do: "draft"
  defp state(:issued), do: "issued"
  defp state(:cancelled), do: "cancelled"

  defp iso(nil), do: nil
  defp iso(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  # Same label as the private `number_label/3` of `Letflow.Documents` (prefix, period for a yearly
  # scope, padded number); the type row is the source of prefix and pad.
  defp number_label(_prefix, %Document{number: nil}), do: nil

  defp number_label(prefix, %Document{number: number, period: period}) do
    type = Repo.get!(DocumentType, @type_key, prefix: prefix)
    padded = number |> Integer.to_string() |> String.pad_leading(type.number_pad, "0")

    case type.numbering_scope do
      :none -> type.number_prefix <> "-" <> padded
      _year -> type.number_prefix <> "-" <> period <> "-" <> padded
    end
  end

  @doc """
  One page of documents, newest first. `params` is the string-keyed query map; the closed keys are
  `kind`, `state`, `org_unit_id`, `limit` and `cursor`. Returns `{:ok, %{rows: rows, next_cursor: text | nil}}`
  or `{:error, :invalid_filter}`. The cursor is plain text `"<unix microseconds>.<uuid>"` produced here
  and parsed with a strict pattern; it is unsigned (an honest replay, not a security boundary).
  """
  @spec list(String.t(), map()) :: {:ok, map()} | {:error, :invalid_filter}
  def list(prefix, params) when is_binary(prefix) and is_map(params) do
    with {:ok, filters} <- list_filters(params) do
      rows = Repo.all(list_query(filters), prefix: prefix)
      {page, rest} = Enum.split(rows, filters.limit)
      headers = headers_for(prefix, Enum.map(page, & &1.id))
      type = if page == [], do: nil, else: Repo.get!(DocumentType, @type_key, prefix: prefix)

      {:ok,
       %{
         rows: Enum.map(page, &row(&1, headers, type)),
         next_cursor: if(rest != [], do: cursor_of(List.last(page)))
       }}
    end
  end

  defp list_filters(params) do
    with true <- Enum.all?(params, fn {k, v} -> k in @list_keys and is_binary(v) end),
         {:ok, kind} <- one_of(params, "kind", Shape.kinds()),
         {:ok, state} <- one_of(params, "state", @states),
         {:ok, unit} <- unit_filter(params),
         {:ok, limit} <- limit_filter(params),
         {:ok, cursor} <- cursor_filter(params) do
      {:ok, %{kind: kind, state: state, unit: unit, limit: limit, cursor: cursor}}
    else
      _bad -> {:error, :invalid_filter}
    end
  end

  defp one_of(params, key, allowed) do
    case Map.fetch(params, key) do
      :error -> {:ok, nil}
      {:ok, value} -> if value in allowed, do: {:ok, value}, else: :error
    end
  end

  defp unit_filter(params) do
    case Map.fetch(params, "org_unit_id") do
      :error -> {:ok, nil}
      {:ok, value} -> Shape.uuid(value)
    end
  end

  defp limit_filter(params) do
    case Map.fetch(params, "limit") do
      :error ->
        {:ok, @default_limit}

      {:ok, text} ->
        if Regex.match?(@limit, text) and String.to_integer(text) <= @max_limit,
          do: {:ok, String.to_integer(text)},
          else: :error
    end
  end

  defp cursor_filter(params) do
    with {:ok, text} <- Map.fetch(params, "cursor"),
         [_, micros, id] <- Regex.run(@cursor, text),
         {:ok, at} <- DateTime.from_unix(String.to_integer(micros), :microsecond) do
      {:ok, {at, id}}
    else
      :error -> if Map.has_key?(params, "cursor"), do: :error, else: {:ok, nil}
      _bad -> :error
    end
  end

  defp list_query(filters) do
    base =
      from(d in Document,
        join: v in DocumentVersion,
        on: v.document_id == d.id and v.status in [:draft, :issued, :cancelled],
        where: d.type_key == ^@type_key,
        order_by: [desc: d.inserted_at, desc: d.id],
        limit: ^(filters.limit + 1),
        select: %{
          id: d.id,
          inserted_at: d.inserted_at,
          number: d.number,
          period: d.period,
          org_unit_id: d.issuing_org_unit_id,
          status: v.status,
          issued_at: v.issued_at
        }
      )

    base
    |> filter_state(filters.state)
    |> filter_unit(filters.unit)
    |> filter_cursor(filters.cursor)
  end

  defp filter_state(query, nil), do: query

  defp filter_state(query, state),
    do: from([_d, v] in query, where: v.status == ^Map.fetch!(@status_atoms, state))

  defp filter_unit(query, nil), do: query
  defp filter_unit(query, unit), do: from([d] in query, where: d.issuing_org_unit_id == ^unit)

  defp filter_cursor(query, nil), do: query

  defp filter_cursor(query, {at, id}) do
    from([d] in query,
      where: d.inserted_at < ^at or (d.inserted_at == ^at and d.id < type(^id, :binary_id))
    )
  end

  defp cursor_of(%{inserted_at: at, id: id}),
    do: Integer.to_string(DateTime.to_unix(at, :microsecond)) <> "." <> id

  # One query for the page: header text `document_id` against text ids (both sides text).
  defp headers_for(_prefix, []), do: %{}

  defp headers_for(prefix, ids) do
    query =
      from(r in Latest,
        where:
          r.entity_type == ^@header_type and not r.deleted and
            fragment("?->>'document_id' = ANY(?)", r.field_values, type(^ids, {:array, :string})),
        select: r.field_values
      )

    prefix |> then(&Repo.all(query, prefix: &1)) |> Map.new(&{&1["document_id"], &1})
  end

  defp row(r, headers, type) do
    number =
      if r.number do
        padded = r.number |> Integer.to_string() |> String.pad_leading(type.number_pad, "0")

        if type.numbering_scope == :none,
          do: type.number_prefix <> "-" <> padded,
          else: type.number_prefix <> "-" <> r.period <> "-" <> padded
      end

    %{
      id: r.id,
      kind: "receipt",
      state: state(r.status),
      number: number,
      issued_at: iso(r.issued_at),
      org_unit_id: r.org_unit_id,
      event_time: get_in(headers, [r.id, "event_time"])
    }
  end

  # -- misc ---------------------------------------------------------------------------------------

  defp cast(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp cast(_other), do: {:error, :not_found}

  defp now do
    case Application.get_env(:letflow, :stock_documents_clock) do
      fun when is_function(fun, 0) -> fun.()
      _default -> DateTime.utc_now()
    end
  end
end
