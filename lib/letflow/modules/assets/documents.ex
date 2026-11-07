defmodule Letflow.Modules.Assets.Documents do
  @moduledoc """
  GH #3891 / REQ-751 and GH #3890 / REQ-752 (assets C10): the asset document context. The one writer
  of the commission header and line records (`assets_commission`, `assets_commission_line`) and of
  the versioned document (`Letflow.Documents`, decision 0056) behind them. It mirrors
  `Letflow.Modules.Stock.Documents`: module `assets` cannot call `stock` (boundary
  Rule 4, and a stock install must not become a precondition of the asset register), so the glue is
  copied, not shared; `Kinds` is a table of five kinds (C10 commission; C11 change, handover, write off; C15 change of kind, which posts nothing, REQ-759), one issue lock for all of them (so the inventory number checks of a change of kind serialise with every other issue). A shared extraction is a follow-up.
  Public functions: `save/3`, `replace/4`, `discard/3`, `issue/4` (writes) and `fetch/3`, `list/2`
  (reads); posting and reversal live in `Letflow.Modules.Assets.Documents.Posting`. The tenant is the
  `prefix` argument and nothing else (INV-1); the router derives it from the token.

  ## Two stores, one writer

  Each save, replace, discard and issue is one `Repo.transaction`; a failed step calls
  `Repo.rollback/1` so nothing partial stays. Record writes use the assets module authority
  (`Letflow.Entities.ManagedTypes.owner_for!/1`), a fresh idempotency key per write and the default
  scope `:all` (only tenant-wide principals reach the routes, see `Letflow.Modules.Assets.Access`).
  `document_id` on the header is the id of the versioned document, which never changes and carries the
  state `draft`, `issued` or `cancelled`, the gap-free number (`ACM-<year>-<n>`) and the issued time.
  Nothing of that is stored on the header; `posted` and `reversed` are derived from the posting marks.
  The id on the routes is this document id.

  ## Rules

  * Save and replace check the shape only (`Documents.Shape`); the event-time window and the master
    data are checked at issue (`Documents.Checks`).
  * A replace takes the WHOLE document: the body replaces the header and all lines; an omitted
    optional key (`location_id`, `actual_user_id`, `note`) is removed and a line left out is deleted.
    A client sends back every header field and every line field it loaded. The issuing org unit of
    the versioned draft cannot change: a body with another `org_unit_id` is `field_invalid`.
  * Replace and discard lock the `documents` row (`FOR UPDATE`) first, the lock `Letflow.Documents`
    takes, so concurrent replace, discard and issue serialise; the draft is re-read under the lock.
  * Issue takes a per-tenant advisory lock (a bound text parameter), runs the checks inside it, makes
    the process definition `assets_commission` active with the request's activator
    (`{:error, :definition_not_active}` otherwise), then calls `Letflow.Documents.issue/2` once, all in
    one transaction, so a refused check takes no number and two simultaneous issues of one fixed card
    cannot both pass `asset_already_in_register`. After the commit one posting instance is started; a
    failed start is NOT an error (the document stays issued).
  * The clock of the event-time window is the app env `:assets_documents_clock` (a zero-arity
    function, default `DateTime.utc_now/0`); it exists only so a test can fix the time.

  Errors: `{:error, :not_found}`, `{:error, :document_not_draft}`, `{:error, :busy}`,
  `{:error, :definition_not_active}`, `{:error, :internal}` or `{:error, {reason, extras}}` (a 422,
  `reason` a string, `extras` a map with the fixed keys `"field"` and `"line_no"`).
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
  alias Letflow.Modules.Assets
  alias Letflow.Modules.Assets.Documents.Checks
  alias Letflow.Modules.Assets.Documents.Kinds
  alias Letflow.Modules.Assets.Documents.Posting
  alias Letflow.Modules.Assets.Documents.Shape
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
  document as `fetch/3` renders it.
  """
  @spec save(String.t(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def save(prefix, body, actor) when is_binary(prefix) do
    with {:ok, doc} <- Shape.parse(body, :create),
         :ok <- ensure_types(prefix, actor) do
      spec = Kinds.get(doc.kind)

      tx(fn ->
        draft_attrs = %{
          type_key: spec.type_key,
          issuing_org_unit_id: doc.header["org_unit_id"],
          content: content(doc)
        }

        case Documents.create_draft(prefix, draft_attrs, actor) do
          {:ok, %{document: document}} -> write_new(prefix, spec, document.id, doc, actor)
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
      tx(fn ->
        lock!(prefix, id)
        locked = fetch!(prefix, id)
        if locked.state != "draft", do: Repo.rollback(:document_not_draft)

        spec = Kinds.get(doc.kind)
        write_header!(prefix, spec, :update, locked.header_id, id, doc, actor)
        write_lines!(prefix, spec, locked, doc, actor)

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
        tx(fn ->
          lock!(prefix, id)
          locked = fetch!(prefix, id)
          if locked.state != "draft", do: Repo.rollback(:document_not_draft)

          case Documents.discard_draft(prefix, id, actor) do
            {:ok, _version} -> :ok
            {:error, reason} -> Repo.rollback(draft_error(reason))
          end

          spec = Kinds.get(locked.kind)
          Enum.each(locked.lines, &delete!(prefix, spec.line_type, &1.line_id, actor))
          delete!(prefix, spec.type_key, locked.header_id, actor)
          :ok
        end)

      with {:ok, :ok} <- result, do: :ok
    end
  end

  @doc """
  Issues draft `id`: under the per-tenant advisory lock runs the event-time and master checks, makes
  the kind's process definition active (`opts[:activator]`) and issues the document once, all in one
  transaction; then starts its posting instance. A refused check or a definition that cannot be
  activated issues nothing and takes no number. Returns the issued document (`opts[:authorized]` is the
  ledger read authorization for `posting_check`).
  """
  @spec issue(String.t(), term(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def issue(prefix, id, actor, opts \\ []) when is_binary(prefix) do
    with {:ok, id} <- cast(id),
         {:ok, view} <- fetch(prefix, id),
         :ok <- draft?(view),
         {:ok, _issued} <- issue_in_lock(prefix, id, actor, Keyword.get(opts, :activator)) do
      if Kinds.get(view.kind).posts?, do: start_posting(prefix, id, actor)

      fetch(prefix, id, Keyword.get(opts, :authorized),
        stock_authorized: Keyword.get(opts, :stock_authorized)
      )
    end
  end

  defp issue_in_lock(prefix, id, actor, activator) do
    tx(fn ->
      lock_issue!(prefix)
      view = fetch!(prefix, id)
      if view.state != "draft", do: Repo.rollback(:document_not_draft)

      case issue_checks(prefix, view) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      if Kinds.get(view.kind).posts? do
        case Posting.ensure_active(prefix, Kinds.get(view.kind).definition, activator) do
          :ok -> :ok
          :error -> Repo.rollback(:definition_not_active)
        end
      end

      case issue_once(prefix, id, actor) do
        {:ok, issued} -> issued
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp lock_issue!(prefix) do
    case Repo.query("SELECT pg_advisory_xact_lock(hashtext($1))", [
           "assets_commission_issue:" <> prefix
         ]) do
      {:ok, _result} -> :ok
      {:error, reason} -> Repo.rollback(log_internal(reason))
    end
  end

  defp issue_checks(prefix, view) do
    with :ok <- Checks.event_time(view.event_time, now()) do
      Checks.masters(prefix, view)
    end
  end

  # A failed start after the issue committed is not an error: the number is spent (gap-free
  # numbering) and the document stays issued (no retry route in C10; the runbook says so).
  defp start_posting(prefix, id, actor) do
    with {:ok, view} <- fetch(prefix, id),
         %{} = version <- Posting.issued(prefix, id),
         {:ok, _instance} <- Posting.start_post(prefix, view, version, actor) do
      :ok
    else
      other ->
        Logger.warning("assets posting not started after issue: #{inspect(start_tag(other))}")
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
      {:error, reason} -> {:error, log_internal(reason)}
    end
  end

  # The document type is registered at install; an install that predates it registers it at the
  # first save (idempotent: an equal registration is a no-op). Outside the write transaction.
  defp ensure_types(prefix, actor) do
    Enum.reduce_while(Assets.document_types(), :ok, fn attrs, :ok ->
      case Documents.register_type(prefix, attrs, %{actor_id: actor}) do
        {:ok, _type} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, log_internal(reason)}}
      end
    end)
  end

  # -- write helpers ------------------------------------------------------------------------------

  defp write_new(prefix, spec, document_id, doc, actor) do
    header_id = write_header!(prefix, spec, :create, nil, document_id, doc, actor)

    for line <- doc.lines do
      create_line!(prefix, spec, header_id, doc.header["org_unit_id"], line, actor)
    end

    fetch!(prefix, document_id)
  end

  defp write_header!(prefix, spec, :create, _record_id, document_id, doc, actor) do
    attrs = %{
      entity_type: spec.type_key,
      field_values: header_values(doc, document_id),
      actor_id: actor,
      idempotency_key: Ecto.UUID.generate()
    }

    # scope-all: SEC-518-R1 (assets module, header type scoped by org_unit_id; own-record system path)
    case Records.create_record(attrs, prefix, ManagedTypes.owner_for!(Assets)) do
      {:ok, %{record: record}} -> record.record_id
      {:error, reason} -> Repo.rollback(log_internal(reason))
    end
  end

  defp write_header!(prefix, spec, :update, record_id, document_id, doc, actor) do
    attrs = %{
      entity_type: spec.type_key,
      record_id: record_id,
      field_values: header_values(doc, document_id),
      actor_id: actor,
      idempotency_key: Ecto.UUID.generate()
    }

    # scope-all: SEC-518-R1 (assets module, header type scoped by org_unit_id; own-record system path)
    case Records.update_record(attrs, prefix, ManagedTypes.owner_for!(Assets)) do
      {:ok, _} -> record_id
      {:error, reason} -> Repo.rollback(log_internal(reason))
    end
  end

  defp create_line!(prefix, spec, header_id, unit, line, actor) do
    attrs = %{
      entity_type: spec.line_type,
      field_values: line_values(line, header_id, unit),
      actor_id: actor,
      idempotency_key: Ecto.UUID.generate()
    }

    # scope-all: SEC-518-R1 (assets module, line type scoped by org_unit_id; own-record system path)
    case Records.create_record(attrs, prefix, ManagedTypes.owner_for!(Assets)) do
      {:ok, %{record: record}} -> record.record_id
      {:error, reason} -> Repo.rollback(log_internal(reason))
    end
  end

  defp update_line!(prefix, spec, line_id, header_id, unit, line, actor) do
    attrs = %{
      entity_type: spec.line_type,
      record_id: line_id,
      field_values: line_values(line, header_id, unit),
      actor_id: actor,
      idempotency_key: Ecto.UUID.generate()
    }

    # scope-all: SEC-518-R1 (assets module, line type scoped by org_unit_id; own-record system path)
    case Records.update_record(attrs, prefix, ManagedTypes.owner_for!(Assets)) do
      {:ok, _} -> line_id
      {:error, reason} -> Repo.rollback(log_internal(reason))
    end
  end

  defp delete!(prefix, type, record_id, actor) do
    attrs = %{
      entity_type: type,
      record_id: record_id,
      actor_id: actor,
      idempotency_key: Ecto.UUID.generate()
    }

    # scope-all: SEC-518-R1 (assets module, own-record system path of a managed type)
    case Records.delete_record(attrs, prefix, ManagedTypes.owner_for!(Assets)) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(log_internal(reason))
    end
  end

  # Line `n` of the new document updates existing line `n`, or is created; lines beyond the new
  # count are deleted. The header's org unit never changes on a draft (checked before).
  defp write_lines!(prefix, spec, locked, doc, actor) do
    existing = Map.new(locked.lines, &{&1.line_no, &1})
    count = length(doc.lines)
    unit = doc.header["org_unit_id"]

    for line <- doc.lines do
      case Map.fetch(existing, line["line_no"]) do
        {:ok, old} -> update_line!(prefix, spec, old.line_id, locked.header_id, unit, line, actor)
        :error -> create_line!(prefix, spec, locked.header_id, unit, line, actor)
      end
    end

    for old <- locked.lines, old.line_no > count do
      delete!(prefix, spec.line_type, old.line_id, actor)
    end

    :ok
  end

  defp header_values(doc, document_id), do: Map.put(doc.header, "document_id", document_id)

  defp line_values(line, header_id, unit),
    do: line |> Map.put("header_id", header_id) |> Map.put("org_unit_id", unit)

  # The versioned content: the saved header and lines, optional keys absent when not given.
  defp content(doc), do: %{"kind" => doc.kind, "header" => doc.header, "lines" => doc.lines}

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

  defp tx(fun) do
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

  defp log_internal(reason) do
    tag = if is_tuple(reason) and tuple_size(reason) > 0, do: elem(reason, 0), else: reason
    Logger.warning("assets document write refused: #{inspect(tag)}")
    :internal
  end

  # -- reads --------------------------------------------------------------------------------------

  @doc """
  The document `id` with its header and lines, or `{:error, :not_found}` (a malformed id, an unknown
  id, a discarded draft and another tenant's id are all that one answer).
  """
  @spec fetch(String.t(), term(), term(), keyword()) :: {:ok, map()} | {:error, :not_found}
  def fetch(prefix, id, authorized \\ nil, opts \\ []) when is_binary(prefix) do
    with {:ok, id} <- cast(id),
         %Document{} = document <- Repo.get(Document, id, prefix: prefix),
         %{} = spec <- Kinds.by_type_key(document.type_key),
         %DocumentVersion{} = version <- live_version(prefix, id),
         {:ok, header} <- header(prefix, spec, id) do
      base = view(prefix, spec, document, version, header)
      {:ok, Map.merge(base, Posting.state_fields(prefix, base, authorized, opts))}
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

  defp header(prefix, spec, document_id) do
    query =
      from(r in Latest,
        where:
          r.entity_type == ^spec.type_key and not r.deleted and
            fragment("?->>'document_id' = ?", r.field_values, ^document_id),
        select: {r.record_id, r.field_values},
        limit: 1
      )

    case Repo.one(query, prefix: prefix) do
      nil -> :error
      {record_id, fv} -> {:ok, {record_id, fv}}
    end
  end

  defp lines(prefix, spec, header_id) do
    query =
      from(r in Latest,
        where:
          r.entity_type == ^spec.line_type and not r.deleted and
            fragment("?->>'header_id' = ?", r.field_values, ^header_id),
        select: {r.record_id, r.field_values}
      )

    prefix
    |> then(&Repo.all(query, prefix: &1))
    |> Enum.map(&line_view(spec, &1))
    |> Enum.sort_by(& &1.line_no)
  end

  # The line keys of the kind (`Kinds`), plus the server-set `asset_card_id` of a change of kind.
  defp line_view(spec, {record_id, fv}) do
    keys =
      if spec.kind == "kind_change", do: spec.line_keys ++ ["asset_card_id"], else: spec.line_keys

    Map.new(keys, fn key -> {Kinds.line_atom(key), fv[key]} end)
    |> Map.merge(%{line_id: record_id, line_no: fv["line_no"]})
  end

  defp view(prefix, spec, document, version, {header_id, fv}) do
    spec
    |> Kinds.view_fields(fv)
    |> Map.merge(%{
      id: document.id,
      kind: spec.kind,
      state: state(version.status),
      number: number_label(prefix, spec, document),
      issued_at: iso(version.issued_at),
      header_id: header_id,
      lines: lines(prefix, spec, header_id)
    })
  end

  defp state(:draft), do: "draft"
  defp state(:issued), do: "issued"
  defp state(:cancelled), do: "cancelled"

  defp iso(nil), do: nil
  defp iso(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  # Same label as the private `number_label/3` of `Letflow.Documents` (prefix, period for a yearly
  # scope, padded number); the type row is the source of prefix and pad.
  defp number_label(_prefix, _spec, %Document{number: nil}), do: nil

  defp number_label(prefix, spec, %Document{number: number, period: period}) do
    type = Repo.get!(DocumentType, spec.type_key, prefix: prefix)
    label(type, number, period)
  end

  defp label(type, number, period) do
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
      type_keys = page |> Enum.map(& &1.type_key) |> Enum.uniq()
      headers = Enum.reduce(type_keys, %{}, &Map.merge(&2, headers_for(prefix, &1, page)))
      states = Posting.states_for(prefix, Enum.map(page, &%{id: &1.id, state: state(&1.status)}))
      types = document_types(prefix, type_keys)

      {:ok,
       %{
         rows: Enum.map(page, &row(&1, headers, Map.fetch!(types, &1.type_key), states)),
         next_cursor: if(rest != [], do: cursor_of(List.last(page)))
       }}
    end
  end

  defp document_types(_prefix, []), do: %{}

  defp document_types(prefix, type_keys) do
    prefix
    |> then(&Repo.all(from(t in DocumentType, where: t.key in ^type_keys), prefix: &1))
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
        where: d.type_key in ^list_type_keys(filters.kind),
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

  defp list_type_keys(nil), do: Kinds.type_keys()
  defp list_type_keys(kind), do: [Kinds.get(kind).type_key]

  defp filter_state(query, nil), do: query

  # Marks are `assets_posting_mark` rows matched on the text document id (both sides text: the
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
        m.entity_type == "assets_posting_mark" and not m.deleted and
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
  defp headers_for(prefix, type_key, page) do
    case for(r <- page, r.type_key == type_key, do: r.id) do
      [] ->
        %{}

      ids ->
        query =
          from(r in Latest,
            where:
              r.entity_type == ^type_key and not r.deleted and
                fragment(
                  "?->>'document_id' = ANY(?)",
                  r.field_values,
                  type(^ids, {:array, :string})
                ),
            select: r.field_values
          )

        prefix |> then(&Repo.all(query, prefix: &1)) |> Map.new(&{&1["document_id"], &1})
    end
  end

  defp row(r, headers, type, states) do
    %{
      id: r.id,
      kind: Kinds.by_type_key(r.type_key).kind,
      state: Map.fetch!(states, r.id),
      number: if(r.number, do: label(type, r.number, r.period)),
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
    case Application.get_env(:letflow, :assets_documents_clock) do
      fun when is_function(fun, 0) -> fun.()
      _default -> DateTime.utc_now()
    end
  end
end
