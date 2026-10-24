defmodule Letflow.Documents.Hold do
  @moduledoc """
  Document legal hold, part (b) of decision 0063 (REQ-536, GH #3106).

  `set/5` puts a not-held document on hold; `release/5` clears a hold. Both take the tenant
  schema name as `prefix` (INV-1), the raw path `document_id`, the caller's 0051 scope set
  (`Letflow.Entities.Query.Types.scope_set/0`, from `Letflow.Api.ScopeGate.scope_set/2`), the
  body attrs (`:reason_code`, `:reason_note`) and the acting user id.

  Order inside each call (0063 S5, S7):

    1. body validation, no query: a bad `reason_code`, a blank `reason_note` or a bad actor is
       `{:error, {:unprocessable, reason}}` whatever the state of the document, so the 422 is
       the same for a held, a not-held, an absent and an out-of-scope document;
    2. one transaction that first takes the `documents` row with
       `SELECT ... FOR UPDATE` (id, tenant prefix and the caller's scope in the same query),
       then reads `on_hold` from the locked row, then writes the columns, then the audit
       entry. The audit chain row is therefore always taken after the documents row (0061
       lock order); nothing here takes it first.

  An absent id, a malformed id, an out-of-scope document and (by prefix) a document of
  another tenant are all `{:error, :not_found}` (INV-5). A refusal writes no audit entry.
  The note is stored on the row only; the event payload carries `document_id`, `reason_code`
  and `actor` (decision 0056 D9: no free text in events).

  `reason_code` is checked by format only; the closed list of values is the owner's
  (decision 0063, "Not decided here").
  """

  import Ecto.Query

  alias Letflow.Audit
  alias Letflow.Documents.Document
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @reason_code_re ~r/^[a-z][a-z0-9_]{0,63}$/
  @max_note_length 2000

  @type scope :: :all | :none | {:nodes, [String.t()]}
  @type result ::
          {:ok, %{document_id: String.t(), on_hold: boolean(), reason_code: String.t()}}
          | {:error, {:unprocessable, atom()}}
          | {:error, :not_found | :conflict | :invalid_schema_name}
          | {:error, term()}

  @doc "Sets a hold on a not-held document (`document.hold_set`)."
  @spec set(String.t(), term(), scope(), map(), term()) :: result()
  def set(prefix, document_id, scope, attrs, actor_id),
    do: transition(:set, prefix, document_id, scope, attrs, actor_id)

  @doc "Clears the hold of a held document (`document.hold_cleared`)."
  @spec release(String.t(), term(), scope(), map(), term()) :: result()
  def release(prefix, document_id, scope, attrs, actor_id),
    do: transition(:release, prefix, document_id, scope, attrs, actor_id)

  defp transition(kind, prefix, document_id, scope, attrs, actor_id) when is_binary(prefix) do
    with {:ok, reason_code, reason_note} <- validate_attrs(attrs),
         :ok <- validate_actor(actor_id),
         {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, id} <- cast_id(document_id),
         {:ok, filter} <- scope_filter(scope) do
      Repo.transaction(fn ->
        case apply_transition(kind, prefix, id, filter, reason_code, reason_note, actor_id) do
          {:ok, result} -> result
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  # The one scoped, locking query. The FOR UPDATE row is read BEFORE `on_hold` is looked at.
  defp lock_document(prefix, id, filter) do
    query = from(d in Document, where: d.id == ^id, lock: "FOR UPDATE", select: d)

    query =
      case filter do
        :all -> query
        {:nodes, uuids} -> where(query, [d], d.issuing_org_unit_id in ^uuids)
      end

    Repo.one(query, prefix: prefix)
  end

  defp apply_transition(kind, prefix, id, filter, reason_code, reason_note, actor_id) do
    case lock_document(prefix, id, filter) do
      nil ->
        {:error, :not_found}

      %Document{on_hold: on_hold}
      when (kind == :set and on_hold) or (kind == :release and not on_hold) ->
        {:error, :conflict}

      %Document{} ->
        now = DateTime.utc_now()
        write_columns(kind, prefix, id, reason_code, reason_note, actor_id, now)
        write_event(kind, prefix, id, reason_code, actor_id)
    end
  end

  defp write_columns(:set, prefix, id, reason_code, reason_note, actor_id, now) do
    from(d in Document, where: d.id == ^id)
    |> Repo.update_all(
      [
        set: [
          on_hold: true,
          hold_set_at: now,
          hold_set_by: actor_id,
          hold_reason_code: reason_code,
          hold_reason_note: reason_note,
          hold_cleared_at: nil,
          hold_cleared_by: nil,
          hold_clear_reason_code: nil,
          hold_clear_reason_note: nil
        ]
      ],
      prefix: prefix
    )
  end

  defp write_columns(:release, prefix, id, reason_code, reason_note, actor_id, now) do
    from(d in Document, where: d.id == ^id)
    |> Repo.update_all(
      [
        set: [
          on_hold: false,
          hold_cleared_at: now,
          hold_cleared_by: actor_id,
          hold_clear_reason_code: reason_code,
          hold_clear_reason_note: reason_note
        ]
      ],
      prefix: prefix
    )
  end

  defp write_event(kind, prefix, id, reason_code, actor_id) do
    entry = %{
      actor_id: actor_id,
      action: action(kind),
      resource_type: "document",
      resource_id: id,
      before_state: nil,
      after_state: %{"document_id" => id, "reason_code" => reason_code, "actor" => actor_id}
    }

    case Audit.insert_entry(Repo, entry, prefix) do
      {:ok, _entry} ->
        {:ok, %{document_id: id, on_hold: kind == :set, reason_code: reason_code}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp action(:set), do: "document.hold_set"
  defp action(:release), do: "document.hold_cleared"

  defp validate_attrs(attrs) when is_map(attrs) do
    code = Map.get(attrs, :reason_code)
    note = Map.get(attrs, :reason_note)

    cond do
      not (is_binary(code) and Regex.match?(@reason_code_re, code)) ->
        {:error, {:unprocessable, :invalid_reason_code}}

      not (is_binary(note) and String.trim(note) != "" and
               String.length(note) <= @max_note_length) ->
        {:error, {:unprocessable, :invalid_reason_note}}

      true ->
        {:ok, code, note}
    end
  end

  defp validate_attrs(_attrs), do: {:error, {:unprocessable, :invalid_reason_code}}

  defp validate_actor(actor) when is_binary(actor) do
    case Ecto.UUID.cast(actor) do
      {:ok, _} -> :ok
      :error -> {:error, {:unprocessable, :invalid_actor}}
    end
  end

  defp validate_actor(_), do: {:error, {:unprocessable, :invalid_actor}}

  defp cast_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp cast_id(_), do: {:error, :not_found}

  # scope_node_paths.node_id is a free string while issuing_org_unit_id is a uuid column: a
  # non-UUID node can never match, so it is dropped (binding it raw would raise, INV-8).
  defp scope_filter(:all), do: {:ok, :all}
  defp scope_filter(:none), do: {:error, :not_found}

  defp scope_filter({:nodes, ids}) when is_list(ids) do
    case Enum.filter(ids, &match?({:ok, _}, Ecto.UUID.cast(&1))) do
      [] -> {:error, :not_found}
      uuids -> {:ok, {:nodes, uuids}}
    end
  end

  defp scope_filter(_other), do: {:error, :not_found}
end
