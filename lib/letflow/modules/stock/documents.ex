defmodule Letflow.Modules.Stock.Documents do
  @moduledoc """
  REQ-712 / GH #3749 (assets B4 part 1): the stock document context. The one writer of the receipt
  header (`stock_receipt`) and line (`stock_receipt_line`) records and of the versioned document
  (`Letflow.Documents`, decision 0056) behind them. REQ-725 adds a second kind, `opening` (header
  `stock_opening`, line `stock_opening_line`, per-line location, responsible and real receipt date, no
  event time), described by `Letflow.Modules.Stock.Documents.Kinds`; the same functions serve both kinds
  and the five `Records` write call sites are parameterised by kind. `check/2` (opening only) runs every
  line check and writes nothing. Public functions: `save/3`, `replace/4`,
  `discard/3`, `issue/4` (writes) and `fetch/3`, `list/2` (reads); posting, reversal and cancel live in
  `Letflow.Modules.Stock.Documents.Posting` (REQ-713). The tenant is the `prefix` argument
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
    REQ-713: before any number is taken the module's `stock_receipt` process definition is made
    active with the request's activator (`{:error, :definition_not_active}` otherwise); after the
    issue committed one posting instance is started, and a failed start is NOT an error (the
    document stays issued; the retry route repairs it).
  * An opening's external reference pair (`external_ref_system`, `external_ref_id`) may be held by one
    live opening header only: save and replace check it in their transaction after a transaction-scoped
    advisory lock on the pair (`{:error, :external_ref_taken}`).
  * The view carries `posted_at`, `posted_by`, `entry_id`, `reversed_at`, `reversed_by` and
    `posting_check`; its `state` is `draft`, `issued`, `posted`, `reversed` or `cancelled`.
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
  alias Letflow.Modules.Stock.Documents.Kinds
  alias Letflow.Modules.Stock.Documents.OpeningChecks
  alias Letflow.Modules.Stock.Documents.Posting
  alias Letflow.Modules.Stock.Documents.Shape
  alias Letflow.Repo

  @states ~w(draft issued posted reversed cancelled)
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
    with {:ok, doc} <- Kinds.parse(body, :create) do
      kind = Kinds.get(doc.kind)

      tx(prefix, fn ->
        unit = doc.header["org_unit_id"]

        draft_attrs = %{
          type_key: kind.type_key,
          issuing_org_unit_id: unit,
          content: content(doc)
        }

        case Documents.create_draft(prefix, draft_attrs, actor) do
          {:ok, %{document: document}} -> write_new(prefix, kind, document.id, doc, actor)
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
         {:ok, doc} <- Kinds.parse(body, {:replace, current.kind}),
         :ok <- same_unit(current, doc) do
      kind = Kinds.get(current.kind)

      tx(prefix, fn ->
        lock!(prefix, id)
        locked = fetch!(prefix, id)
        if locked.state != "draft", do: Repo.rollback(:document_not_draft)

        ref_free!(prefix, kind, id, doc)
        write_header!(prefix, kind, :update, locked.header_id, id, doc, actor)
        write_lines!(prefix, kind, locked, doc, actor)

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

          kind = Kinds.get(locked.kind)
          Enum.each(locked.lines, &delete!(prefix, kind.line_type, &1.line_id, actor))
          delete!(prefix, kind.header_type, locked.header_id, actor)
          :ok
        end)

      with {:ok, :ok} <- result, do: :ok
    end
  end

  @doc """
  Runs the event-time and master checks of draft `id`, makes the `stock_receipt` process definition
  active (`opts[:activator]`, the request's activator), then issues it once and starts its posting
  instance. A refused check or a definition that cannot be activated issues nothing and takes no
  number. Returns the issued document (`opts[:authorized]` is the ledger read authorization for
  `posting_check`).
  """
  @spec issue(String.t(), term(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def issue(prefix, id, actor, opts \\ []) when is_binary(prefix) do
    with {:ok, id} <- cast(id),
         {:ok, view} <- fetch(prefix, id),
         :ok <- draft?(view),
         :ok <- issue_checks(prefix, view),
         :ok <- activate(prefix, Kinds.get(view.kind).definition, Keyword.get(opts, :activator)),
         {:ok, _issued} <- issue_once(prefix, id, actor) do
      start_posting(prefix, id, actor)
      fetch(prefix, id, Keyword.get(opts, :authorized))
    end
  end

  # The receipt stops at its first failure in the order of REQ-712/REQ-714. The opening runs every
  # line check (`OpeningChecks`) and stops at the first failing line in line order.
  defp issue_checks(prefix, %{kind: "receipt"} = view) do
    with :ok <- Checks.event_time(view.event_time, now()),
         :ok <- Checks.received_on(view.received_on, view.event_time) do
      Checks.masters(prefix, view)
    end
  end

  defp issue_checks(prefix, %{kind: "opening"} = view) do
    with {:ok, today} <- today() do
      case prefix |> OpeningChecks.check_all(view, today) |> OpeningChecks.first_failure() do
        :ok -> :ok
        {reason, line_no} -> {:error, {reason, %{"line_no" => line_no}}}
      end
    end
  end

  defp today, do: Checks.event_day(DateTime.to_iso8601(now()))

  @doc """
  The result of every line check of the opening draft `id`: `{:ok, %{ok: boolean, lines: [%{line_no,
  reasons}]}}`. Writes nothing, takes no lock and no number. Other kinds are `unknown_kind` (422), an
  issued or cancelled document `:document_not_draft`.
  """
  @spec check(String.t(), term()) :: {:ok, map()} | {:error, term()}
  def check(prefix, id) when is_binary(prefix) do
    with {:ok, id} <- cast(id),
         {:ok, view} <- fetch(prefix, id),
         :ok <- opening?(view),
         :ok <- draft?(view),
         {:ok, today} <- today() do
      lines = OpeningChecks.check_all(prefix, view, today)
      {:ok, %{ok: Enum.all?(lines, &(&1.reasons == [])), lines: lines}}
    end
  end

  defp opening?(%{kind: "opening"}), do: :ok
  defp opening?(_view), do: {:error, {"unknown_kind", %{}}}

  defp activate(prefix, definition, activator) do
    case Posting.ensure_active(prefix, definition, activator) do
      :ok -> :ok
      :error -> {:error, :definition_not_active}
    end
  end

  # A failed start after the issue committed is not an error: the number is spent (gap-free
  # numbering) and the retry route `post` starts the posting.
  defp start_posting(prefix, id, actor) do
    with {:ok, view} <- fetch(prefix, id),
         %{} = version <- Posting.issued(prefix, id),
         {:ok, _instance} <- Posting.start_post(prefix, view, version, actor) do
      :ok
    else
      other ->
        Logger.warning("stock posting not started after issue: #{inspect(start_tag(other))}")
        :error
    end
  end

  defp start_tag({:error, reason}), do: reason
  defp start_tag(other), do: other

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

  defp write_new(prefix, kind, document_id, doc, actor) do
    ref_free!(prefix, kind, document_id, doc)
    header_id = write_header!(prefix, kind, :create, nil, document_id, doc, actor)

    for line <- doc.lines do
      create_line!(prefix, kind, header_id, doc.header["org_unit_id"], line, actor)
    end

    fetch!(prefix, document_id)
  end

  defp write_header!(prefix, kind, :create, _record_id, document_id, doc, actor) do
    attrs = %{
      entity_type: kind.header_type,
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

  defp write_header!(prefix, kind, :update, record_id, document_id, doc, actor) do
    attrs = %{
      entity_type: kind.header_type,
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

  defp create_line!(prefix, kind, header_id, unit, line, actor) do
    attrs = %{
      entity_type: kind.line_type,
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

  defp update_line!(prefix, kind, line_id, header_id, unit, line, actor) do
    attrs = %{
      entity_type: kind.line_type,
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
  defp write_lines!(prefix, kind, locked, doc, actor) do
    existing = Map.new(locked.lines, &{&1.line_no, &1})
    count = length(doc.lines)
    unit = doc.header["org_unit_id"]

    for line <- doc.lines do
      case Map.fetch(existing, line["line_no"]) do
        {:ok, old} -> update_line!(prefix, kind, old.line_id, locked.header_id, unit, line, actor)
        :error -> create_line!(prefix, kind, locked.header_id, unit, line, actor)
      end
    end

    for old <- locked.lines, old.line_no > count do
      delete!(prefix, kind.line_type, old.line_id, actor)
    end

    :ok
  end

  # REQ-725: the external reference pair of an opening header may be held by one live opening header.
  # Two saves of the same pair serialise on a transaction-scoped advisory lock (a bound parameter,
  # the tenant prefix in the text), then the live headers are searched. A table constraint cannot do
  # this: soft-deleted rows would keep the pair taken.
  defp ref_free!(prefix, %{kind: "opening"} = kind, document_id, doc) do
    with system when is_binary(system) <- doc.header["external_ref_system"],
         ref when is_binary(ref) <- doc.header["external_ref_id"] do
      lock_text = "stock_opening_ref:" <> prefix <> ":" <> system <> ":" <> ref

      case Repo.query("SELECT pg_advisory_xact_lock(hashtext($1))", [lock_text]) do
        {:ok, _result} -> :ok
        {:error, reason} -> Repo.rollback(log_internal(reason))
      end

      taken? =
        Repo.exists?(
          from(r in Latest,
            where:
              r.entity_type == ^kind.header_type and not r.deleted and
                fragment("?->>'external_ref_system' = ?", r.field_values, ^system) and
                fragment("?->>'external_ref_id' = ?", r.field_values, ^ref) and
                fragment("?->>'document_id' <> ?", r.field_values, ^document_id)
          ),
          prefix: prefix
        )

      if taken?, do: Repo.rollback(:external_ref_taken), else: :ok
    else
      _no_pair -> :ok
    end
  end

  defp ref_free!(_prefix, _kind, _document_id, _doc), do: :ok

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
  @spec fetch(String.t(), term(), term()) :: {:ok, map()} | {:error, :not_found}
  def fetch(prefix, id, authorized \\ nil) when is_binary(prefix) do
    with {:ok, id} <- cast(id),
         %Document{} = document <- Repo.get(Document, id, prefix: prefix),
         %{} = kind <- Kinds.for_type_key(document.type_key),
         %DocumentVersion{} = version <- live_version(prefix, id),
         {:ok, header} <- header(prefix, kind, id) do
      base = view(prefix, kind, document, version, header)
      {:ok, Map.merge(base, Posting.state_fields(prefix, base, authorized))}
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

  defp header(prefix, kind, document_id) do
    query =
      from(r in Latest,
        where:
          r.entity_type == ^kind.header_type and not r.deleted and
            fragment("?->>'document_id' = ?", r.field_values, ^document_id),
        select: {r.record_id, r.field_values},
        limit: 1
      )

    case Repo.one(query, prefix: prefix) do
      nil -> :error
      {record_id, fv} -> {:ok, {record_id, fv}}
    end
  end

  defp lines(prefix, kind, header_id) do
    query =
      from(r in Latest,
        where:
          r.entity_type == ^kind.line_type and not r.deleted and
            fragment("?->>'header_id' = ?", r.field_values, ^header_id),
        select: {r.record_id, r.field_values}
      )

    prefix
    |> then(&Repo.all(query, prefix: &1))
    |> Enum.map(&line_view(kind.kind, &1))
    |> Enum.sort_by(& &1.line_no)
  end

  defp line_view("receipt", {record_id, fv}) do
    %{
      line_id: record_id,
      line_no: fv["line_no"],
      catalog_item_id: fv["catalog_item_id"],
      catalog_uom_id: fv["catalog_uom_id"],
      catalog_lot_id: fv["catalog_lot_id"],
      quantity: fv["quantity"],
      unit_price: fv["unit_price"],
      line_value: fv["line_value"]
    }
  end

  defp line_view("opening", {record_id, fv}) do
    %{
      line_id: record_id,
      line_no: fv["line_no"],
      location_id: fv["location_id"],
      responsible_id: fv["responsible_id"],
      catalog_item_id: fv["catalog_item_id"],
      catalog_uom_id: fv["catalog_uom_id"],
      catalog_lot_id: fv["catalog_lot_id"],
      quantity: fv["quantity"],
      received_on: fv["received_on"],
      unit_price: fv["unit_price"],
      line_value: fv["line_value"],
      external_ref_system: fv["external_ref_system"],
      external_ref_id: fv["external_ref_id"]
    }
  end

  defp view(prefix, %{kind: "opening"} = kind, document, version, {header_id, fv}) do
    %{
      id: document.id,
      kind: "opening",
      state: state(version.status),
      number: number_label(prefix, document),
      issued_at: iso(version.issued_at),
      header_id: header_id,
      org_unit_id: fv["org_unit_id"],
      note: fv["note"],
      external_ref_system: fv["external_ref_system"],
      external_ref_id: fv["external_ref_id"],
      lines: lines(prefix, kind, header_id)
    }
  end

  defp view(prefix, kind, document, version, {header_id, fv}) do
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
      supplier_document_ref: fv["supplier_document_ref"],
      received_on: fv["received_on"],
      event_time: fv["event_time"],
      note: fv["note"],
      lines: lines(prefix, kind, header_id)
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

  defp number_label(prefix, %Document{number: number, period: period} = document) do
    type = Repo.get!(DocumentType, document.type_key, prefix: prefix)
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
      states = Posting.states_for(prefix, Enum.map(page, &%{id: &1.id, state: state(&1.status)}))
      types = types_for(prefix, page)

      {:ok,
       %{
         rows: Enum.map(page, &row(&1, headers, types, states)),
         next_cursor: if(rest != [], do: cursor_of(List.last(page)))
       }}
    end
  end

  defp types_for(_prefix, []), do: %{}

  defp types_for(prefix, page) do
    keys = page |> Enum.map(& &1.type_key) |> Enum.uniq()

    Repo.all(from(t in DocumentType, where: t.key in ^keys), prefix: prefix)
    |> Map.new(&{&1.key, &1})
  end

  defp list_filters(params) do
    with true <- Enum.all?(params, fn {k, v} -> k in @list_keys and is_binary(v) end),
         {:ok, kind} <- one_of(params, "kind", Kinds.kinds()),
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
        as: :doc,
        join: v in DocumentVersion,
        on: v.document_id == d.id and v.status in [:draft, :issued, :cancelled],
        where: d.type_key in ^kind_type_keys(filters.kind),
        order_by: [desc: d.inserted_at, desc: d.id],
        limit: ^(filters.limit + 1),
        select: %{
          id: d.id,
          type_key: d.type_key,
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

  defp kind_type_keys(nil), do: Enum.map(Kinds.kinds(), &Kinds.get(&1).type_key)
  defp kind_type_keys(kind), do: [Kinds.get(kind).type_key]

  defp filter_state(query, nil), do: query

  # Marks are `stock_posting_mark` rows matched on the text document id (both sides text: the
  # document id is a uuid column, cast with `::text`; the JSON side is text).
  defp filter_state(query, "issued") do
    from([_d, v] in query, where: v.status == :issued)
    |> where_mark("posted", false)
    |> where_mark("reversed", false)
  end

  defp filter_state(query, "posted") do
    from([_d, v] in query, where: v.status == :issued)
    |> where_mark("posted", true)
    |> where_mark("reversed", false)
  end

  defp filter_state(query, "reversed") do
    from([_d, v] in query, where: v.status == :issued) |> where_mark("reversed", true)
  end

  defp filter_state(query, state),
    do: from([_d, v] in query, where: v.status == ^Map.fetch!(@status_atoms, state))

  defp where_mark(query, mark, true), do: from(query, where: exists(mark_query(mark)))
  defp where_mark(query, mark, false), do: from(query, where: not exists(mark_query(mark)))

  defp mark_query(mark) do
    from(m in Latest,
      where:
        m.entity_type == "stock_posting_mark" and not m.deleted and
          fragment("?->>'document_id' = ?::text", m.field_values, parent_as(:doc).id) and
          fragment("?->>'mark' = ?", m.field_values, ^mark),
      select: 1
    )
  end

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
          r.entity_type in ^Enum.map(Kinds.kinds(), &Kinds.get(&1).header_type) and
            not r.deleted and
            fragment("?->>'document_id' = ANY(?)", r.field_values, type(^ids, {:array, :string})),
        select: r.field_values
      )

    prefix |> then(&Repo.all(query, prefix: &1)) |> Map.new(&{&1["document_id"], &1})
  end

  defp row(r, headers, types, states) do
    type = Map.fetch!(types, r.type_key)
    kind = Kinds.for_type_key(r.type_key)

    number =
      if r.number do
        padded = r.number |> Integer.to_string() |> String.pad_leading(type.number_pad, "0")

        if type.numbering_scope == :none,
          do: type.number_prefix <> "-" <> padded,
          else: type.number_prefix <> "-" <> r.period <> "-" <> padded
      end

    %{
      id: r.id,
      kind: kind.kind,
      state: Map.fetch!(states, r.id),
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
