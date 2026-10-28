defmodule Letflow.Modules.Procurement.LineEvents do
  @moduledoc """
  The line half of module `procurement` after approval (GH #3188, REQ-558 part 1, PR-04):
  `record_officer/3`, `record_supplier/3` and `record_reference/3` store one event each for one line
  of an approved purchase request, and `line_view/3` reads the line back.

  A line is `(document_id, line_no)`: the line is an element of the request's version content, not a
  row. The module holds no chooser, queue, escalation or delegation logic: whoever calls the
  operation decides who the officer is and which supplier is chosen. Supplier and reference are
  separate operations and events; a reference may be recorded before any supplier. There is no
  supplier or purchase-order master table: `identifier` is text and `source_system` names the system
  it comes from, for a later mapping (decision 0057 D1). A newer event of a kind replaces the earlier
  one in the view; the earlier ones stay in `history`.

  Every function takes `prefix` first (INV-1); `performer` is the authenticated user and never comes
  from the body. `record/5` order, in one transaction:

    1. shape of the inputs, before the database; all problems are collected, so the error names
       each missing field. A malformed document id or line number is `:not_found` (INV-5);
    2. officer only: the officer must be an existing tenant user;
    3. lock the document row (`FOR UPDATE`, the row `Documents.issue/2` and `Decisions.record/3`
       lock), `lock_timeout` 2s and `statement_timeout` 15s, a timeout gives `{:error, :busy}`;
    4. the line must exist in the newest non-discarded version, else `:not_found`;
    5. replay: the same `idempotency_key` on the document returns the first result with
       `replayed: true` and writes nothing (another payload under that key is
       `:idempotency_key_reused`);
    6. the newest version must be issued and approved (`Decisions.approved?/3`), else `:not_approved`;
    7. insert the event (`recorded_at` is the server clock), make sure the `procurement_lines` row
       exists, and write one `procurement.line_*_recorded` audit entry, all in the transaction.

  A refusal writes no per-attempt audit entry (decision 0056 D9): it is counted on
  `[:letflow, :procurement, :refused]` after the transaction, with no id or content in the metadata.

  `fulfilled_quantity` is only read here: nothing in this module records fulfilment. The
  `procurement_lines` row is created with the column default 0 on the first event of a line, so a line
  without events has no row and reads as "0".

  Permissions are NOT checked here: the router owns `ProcurementLineRecord`.
  """

  import Ecto.Query

  require Logger

  alias Ecto.Adapters.SQL
  alias Letflow.Audit
  alias Letflow.Documents.Document
  alias Letflow.Documents.DocumentVersion
  alias Letflow.Identity
  alias Letflow.Modules.Procurement.Decisions
  alias Letflow.Modules.Procurement.Line
  alias Letflow.Modules.Procurement.LineEvent
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @key ~r/\A[A-Za-z0-9._:-]{1,128}\z/
  @type_key "purchase_request"
  @reference_kinds ~w(purchase_order contract)

  # maximum characters per text field
  @bounds %{source_system: 64, identifier: 128, display_name: 200}

  @doc "Records the officer of a line; see the moduledoc for the order of checks and the errors."
  def record_officer(prefix, performer, params),
    do: record(:officer, prefix, performer, params, :record_officer)

  @doc "Records the supplier chosen for a line."
  def record_supplier(prefix, performer, params),
    do: record(:supplier, prefix, performer, params, :record_supplier)

  @doc "Records the PO or contract reference of a line (`kind`: `purchase_order` or `contract`)."
  def record_reference(prefix, performer, params),
    do: record(:reference, prefix, performer, params, :record_reference)

  @fields %{
    officer: [:officer_id],
    supplier: [:source_system, :identifier, :display_name],
    reference: [:source_system, :identifier, :kind]
  }

  defp record(kind, prefix, performer, params, action)
       when is_binary(prefix) and is_map(params) do
    result =
      with {:ok, performer} <- cast_uuid(performer),
           {:ok, document_id, line_no} <- locate(params),
           {:ok, data, key} <- shape(kind, params),
           {:ok, _tenant_id} <- tenant(prefix),
           :ok <- officer_known(kind, data, prefix) do
        transact(prefix, performer, %{
          kind: kind,
          document_id: document_id,
          line_no: line_no,
          data: data,
          idempotency_key: key
        })
      else
        {:error, _reason} = error -> error
        :error -> {:error, :not_found}
      end

    Decisions.count_refusal(result, action, prefix)
  end

  defp record(_kind, _prefix, _performer, _params, _action), do: {:error, :not_found}

  @doc """
  The line as the router shows it. `officer`, `supplier` and `procurement_document` are `nil` when
  no event of that kind exists (never an empty string); `history` lists every event of the kind in
  the order it was recorded. `fulfilled_quantity` is read, never written, here.
  """
  def line_view(prefix, document_id, line_no) when is_binary(prefix) do
    with {:ok, id} <- cast_uuid(document_id),
         {:ok, n} <- cast_line_no(line_no),
         %Document{type_key: @type_key} <- Repo.get(Document, id, prefix: prefix),
         %DocumentVersion{} = version <- latest_version(prefix, id),
         true <- line_in?(version, n) do
      events = events_of(prefix, id, n)

      history = fn kind ->
        events |> Enum.filter(&(&1.kind == kind)) |> Enum.map(&item/1)
      end

      officer = history.(:officer)
      supplier = history.(:supplier)
      reference = history.(:reference)

      {:ok,
       %{
         document_id: id,
         line_no: n,
         fulfilled_quantity: fulfilled(prefix, id, n),
         officer: List.last(officer),
         supplier: List.last(supplier),
         procurement_document: List.last(reference),
         history: %{officer: officer, supplier: supplier, procurement_document: reference}
       }}
    else
      _other -> {:error, :not_found}
    end
  end

  def line_view(_prefix, _document_id, _line_no), do: {:error, :not_found}

  # -- the transaction -----------------------------------------------------------------------

  defp transact(prefix, performer, input) do
    case Repo.transaction(fn -> write(prefix, performer, input) end) do
      {:ok, {:refused, reason}} -> {:error, reason}
      {:ok, {:accepted, result}} -> {:ok, result}
      {:error, {:audit_failed, _reason}} -> {:error, :audit_failed}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in Postgrex.Error ->
      case error.postgres do
        %{code: :lock_not_available} ->
          {:error, :busy}

        %{code: :query_canceled} ->
          {:error, :busy}

        %{code: :unique_violation} ->
          replay_after_race(prefix, performer, input)

        # The inserts and Audit.insert_entry/3 raise on a database failure; the transaction is
        # already rolled back, nothing was written (INV-8).
        other ->
          Logger.error("procurement line event failed: #{inspect(Map.get(other, :code))}")
          {:error, :audit_failed}
      end
  end

  defp write(prefix, performer, input) do
    # constant SQL, no table: the same bounds as Documents.issue/2, scoped to this transaction
    SQL.query!(Repo, "SET LOCAL lock_timeout = '2s'")
    SQL.query!(Repo, "SET LOCAL statement_timeout = '15s'")

    with :ok <- lock_document(prefix, input.document_id),
         {:ok, version} <- existing_line(prefix, input),
         :ok <- replay_or_proceed(prefix, performer, input),
         :ok <- approved(prefix, input.document_id, version) do
      insert(prefix, performer, input, version)
    else
      {:replay, event} -> {:accepted, result(event, true)}
      {:error, reason} -> {:refused, reason}
    end
  end

  defp lock_document(prefix, document_id) do
    query =
      from(d in Document,
        where: d.id == ^document_id and d.type_key == ^@type_key,
        lock: "FOR UPDATE"
      )

    case Repo.one(query, prefix: prefix) do
      nil -> {:error, :not_found}
      _document -> :ok
    end
  end

  defp existing_line(prefix, input) do
    case latest_version(prefix, input.document_id) do
      %DocumentVersion{} = version ->
        if line_in?(version, input.line_no), do: {:ok, version}, else: {:error, :not_found}

      nil ->
        {:error, :not_found}
    end
  end

  defp replay_or_proceed(prefix, performer, input) do
    case stored(prefix, input.document_id, input.idempotency_key) do
      nil ->
        :ok

      %LineEvent{} = event ->
        if same?(event, performer, input),
          do: {:replay, event},
          else: {:error, :idempotency_key_reused}
    end
  end

  defp same?(event, performer, input) do
    event.kind == input.kind and event.line_no == input.line_no and
      event.performer == performer and event.data == input.data
  end

  defp approved(prefix, document_id, %DocumentVersion{status: :issued, version_no: n}) do
    if Decisions.approved?(prefix, document_id, n), do: :ok, else: {:error, :not_approved}
  end

  defp approved(_prefix, _document_id, _version), do: {:error, :not_approved}

  defp insert(prefix, performer, input, version) do
    now = DateTime.utc_now()

    event =
      Repo.insert!(
        %LineEvent{
          document_id: input.document_id,
          line_no: input.line_no,
          version_no: version.version_no,
          kind: input.kind,
          data: input.data,
          performer: performer,
          recorded_at: now,
          idempotency_key: input.idempotency_key,
          inserted_at: now
        },
        prefix: prefix
      )

    # the column default of fulfilled_quantity (0) applies; nothing in this module sets it
    Repo.insert_all(
      Line,
      [%{document_id: input.document_id, line_no: input.line_no, inserted_at: now}],
      prefix: prefix,
      on_conflict: :nothing,
      conflict_target: [:document_id, :line_no]
    )

    entry = %{
      actor_id: performer,
      action: "procurement.line_#{input.kind}_recorded",
      resource_type: "purchase_request",
      resource_id: input.document_id,
      before_state: nil,
      after_state: %{
        "line_no" => input.line_no,
        "version_no" => version.version_no,
        "kind" => Atom.to_string(input.kind),
        "data" => input.data
      }
    }

    case Audit.insert_entry(Repo, entry, prefix) do
      {:ok, _entry} -> {:accepted, result(event, false)}
      {:error, reason} -> Repo.rollback({:audit_failed, reason})
    end
  end

  # The row lock makes this unreachable between two operations of one document; kept so a unique
  # violation from any other path answers like a replay and not with a crash (INV-8).
  defp replay_after_race(prefix, performer, input) do
    case stored(prefix, input.document_id, input.idempotency_key) do
      %LineEvent{} = event ->
        if same?(event, performer, input),
          do: {:ok, result(event, true)},
          else: {:error, :idempotency_key_reused}

      nil ->
        {:error, :busy}
    end
  end

  # -- reads ----------------------------------------------------------------------------------

  defp stored(prefix, document_id, key) do
    Repo.one(
      from(e in LineEvent, where: e.document_id == ^document_id and e.idempotency_key == ^key),
      prefix: prefix
    )
  end

  defp events_of(prefix, document_id, line_no) do
    Repo.all(
      from(e in LineEvent,
        where: e.document_id == ^document_id and e.line_no == ^line_no,
        order_by: [asc: e.id]
      ),
      prefix: prefix
    )
  end

  defp fulfilled(prefix, document_id, line_no) do
    query =
      from(l in Line,
        where: l.document_id == ^document_id and l.line_no == ^line_no,
        select: l.fulfilled_quantity
      )

    case Repo.one(query, prefix: prefix) do
      nil -> "0"
      %Decimal{} = quantity -> quantity |> Decimal.normalize() |> Decimal.to_string(:normal)
    end
  end

  defp latest_version(prefix, document_id) do
    Repo.one(
      from(v in DocumentVersion,
        where: v.document_id == ^document_id and v.status != :discarded,
        order_by: [desc: v.version_no],
        limit: 1
      ),
      prefix: prefix
    )
  end

  defp line_in?(%DocumentVersion{content: %{"lines" => lines}}, line_no) when is_list(lines),
    do: Enum.any?(lines, &(is_map(&1) and Map.get(&1, "line_no") == line_no))

  defp line_in?(_version, _line_no), do: false

  # -- shape ----------------------------------------------------------------------------------

  defp locate(params) do
    with {:ok, document_id} <- cast_uuid(get(params, :document_id)),
         {:ok, line_no} <- cast_line_no(get(params, :line_no)) do
      {:ok, document_id, line_no}
    end
  end

  defp get(params, key), do: Map.get(params, key, Map.get(params, Atom.to_string(key)))

  # Collects every problem so the error names each missing field (REQ-558 criterion 3). Values are
  # never echoed.
  defp shape(kind, params) do
    key = get(params, :idempotency_key)

    key_errors =
      cond do
        blank?(key) -> [%{field: "idempotency_key", code: "required"}]
        is_binary(key) and Regex.match?(@key, key) -> []
        true -> [%{field: "idempotency_key", code: "invalid"}]
      end

    {data, field_errors} =
      Enum.reduce(Map.fetch!(@fields, kind), {%{}, []}, fn field, {data, errors} ->
        case field_value(field, get(params, field)) do
          {:ok, value} -> {Map.put(data, Atom.to_string(field), value), errors}
          {:error, code} -> {data, errors ++ [%{field: Atom.to_string(field), code: code}]}
        end
      end)

    case field_errors ++ key_errors do
      [] -> {:ok, data, key}
      errors -> {:error, {:validation, errors}}
    end
  end

  defp field_value(field, value) do
    cond do
      blank?(value) -> {:error, "required"}
      not is_binary(value) -> {:error, "invalid"}
      true -> checked(field, String.trim(value))
    end
  end

  defp checked(:officer_id, value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, "invalid"}
    end
  end

  defp checked(:kind, value),
    do: if(value in @reference_kinds, do: {:ok, value}, else: {:error, "invalid"})

  defp checked(field, value),
    do: if(String.length(value) <= @bounds[field], do: {:ok, value}, else: {:error, "invalid"})

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp officer_known(:officer, %{"officer_id" => officer_id}, prefix) do
    if Identity.user_exists?(officer_id, prefix),
      do: :ok,
      else: {:error, {:validation, [%{field: "officer_id", code: "unknown"}]}}
  end

  defp officer_known(_kind, _data, _prefix), do: :ok

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp cast_uuid(_value), do: :error

  defp cast_line_no(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp cast_line_no(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 and n <= 2_147_483_647 -> {:ok, n}
      _other -> :error
    end
  end

  defp cast_line_no(_value), do: :error

  defp tenant(prefix) do
    case TenantProvisioning.tenant_id_for_schema_name(prefix) do
      {:ok, tenant_id} -> {:ok, tenant_id}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  # -- shapes returned -------------------------------------------------------------------------

  defp result(%LineEvent{} = event, replayed) do
    event
    |> item()
    |> Map.merge(%{
      event_id: event.id,
      document_id: event.document_id,
      line_no: event.line_no,
      event_kind: event.kind,
      replayed: replayed
    })
  end

  defp item(%LineEvent{kind: :officer} = event) do
    meta(event, %{user_id: event.data["officer_id"]})
  end

  defp item(%LineEvent{kind: :supplier} = event) do
    meta(event, %{
      source_system: event.data["source_system"],
      identifier: event.data["identifier"],
      display_name: event.data["display_name"]
    })
  end

  defp item(%LineEvent{kind: :reference} = event) do
    meta(event, %{
      source_system: event.data["source_system"],
      identifier: event.data["identifier"],
      kind: event.data["kind"]
    })
  end

  defp meta(event, fields) do
    Map.merge(fields, %{
      performer: event.performer,
      recorded_at: event.recorded_at,
      version_no: event.version_no
    })
  end
end
