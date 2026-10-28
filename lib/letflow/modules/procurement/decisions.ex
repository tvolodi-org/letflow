defmodule Letflow.Modules.Procurement.Decisions do
  @moduledoc """
  The decision half of the BPM operations of module `procurement` (GH #3162, REQ-544 part 2):
  `record/3` stores one approve, reject or return of one exact version of a purchase request;
  `approved?/3` and `status/2` read it back. `PurchaseRequests.submit_for_bpm/2` is the submit half.

  The module holds no approval route, threshold, assignee or delegation logic: a process definition
  decides who is asked and in what order, and calls these operations when its task completes. This
  module only checks that the performer may decide this request and that the decision names the
  exact issued version.

  `record/3` order, in one transaction (every function takes `prefix` first, INV-1; `performer` is
  the authenticated user and never comes from the body):

    1. shape of the inputs, before the database;
    2. lock the document row (`FOR UPDATE`, the same row `Documents.issue/2` locks), so a decision
       cannot interleave with the issue of the next version; `lock_timeout` 2s and
       `statement_timeout` 15s as in `Documents.issue/2`, a timeout gives `{:error, :busy}`;
    3. replay: the same `idempotency_key` on the document returns the first result with
       `replayed: true` and writes nothing (a different payload under that key is
       `:idempotency_key_reused`);
    4. the performer is not the requester (`:self_decision`);
    5. `Documents.verify_binding/4` (decision 0056 D4): a hash that does not match, a cancelled,
       superseded, draft or non-existent version all give the same `{:error, :binding_refused}`;
    6. a version already rejected or returned takes no further decision (`:version_closed`);
    7. insert the row (`decided_at` is the server clock) and one `procurement.decision_recorded`
       audit entry in the same transaction.

  A refusal writes no per-attempt audit entry (decision 0056 D9): it is counted on
  `[:letflow, :procurement, :refused]` after the transaction, with no id, hash or content in the
  metadata. The refusal leaves the transaction as a commit of nothing, not a rollback, so the
  `document.integrity_failed` entry that `verify_binding/4` may write in a caller's transaction
  survives.

  Permissions are NOT checked here: the router owns `ProcurementRequestDecide`.
  """

  import Ecto.Query

  require Logger

  alias Ecto.Adapters.SQL
  alias Letflow.Audit
  alias Letflow.Documents
  alias Letflow.Documents.Document
  alias Letflow.Documents.DocumentVersion
  alias Letflow.Modules.Procurement.Decision
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @decisions ~w(approve reject return)
  @hash ~r/\A[0-9a-f]{64}\z/
  @key ~r/\A[A-Za-z0-9._:-]{1,128}\z/
  @type_key "purchase_request"

  @doc "Records one decision; see the moduledoc for the order of checks and the error terms."
  def record(prefix, performer, params) when is_binary(prefix) and is_map(params) do
    result =
      with {:ok, performer} <- cast_uuid(performer),
           {:ok, input} <- shape(params),
           {:ok, _tenant_id} <- tenant(prefix),
           {:ok, document_id} <- cast_uuid(Map.get(input, :document_id)) do
        transact(prefix, performer, %{input | document_id: document_id})
      else
        {:error, _reason} = error -> error
        :error -> {:error, :not_found}
      end

    count_refusal(result, :decide, prefix)
  end

  def record(_prefix, _performer, _params), do: {:error, :not_found}

  @doc """
  True only when `version_no` is the issued current version of the request and the latest decision
  on exactly that version is an approval. Any other input, including a non-existent version, is
  false. After the next version is issued the earlier one is superseded, so it is false too.
  """
  def approved?(prefix, document_id, version_no) when is_binary(prefix) do
    with {:ok, id} <- cast_uuid(document_id),
         true <- is_integer(version_no),
         %DocumentVersion{status: :issued, version_no: ^version_no} <-
           current_version(prefix, id),
         %Decision{decision: :approve} <- latest_decision(prefix, id, version_no) do
      true
    else
      _other -> false
    end
  end

  def approved?(_prefix, _document_id, _version_no), do: false

  @doc """
  The request's state for the GET route: `:draft`, `:submitted`, `:approved`, `:rejected`,
  `:returned` or `:cancelled`, the current version and its hash, and the decisions recorded.
  """
  def status(prefix, document_id) when is_binary(prefix) do
    with {:ok, id} <- cast_uuid(document_id),
         %Document{type_key: @type_key} <- Repo.get(Document, id, prefix: prefix),
         %DocumentVersion{} = latest <- latest_version(prefix, id) do
      decisions = decisions_of(prefix, id)
      latest_decision = latest_decision(prefix, id, latest.version_no)

      {:ok,
       %{
         document_id: id,
         current_version_no: latest.version_no,
         content_hash: latest.content_hash,
         state: state_of(latest, latest_decision),
         approved: approved?(prefix, id, latest.version_no),
         decisions: Enum.map(decisions, &public/1)
       }}
    else
      _other -> {:error, :not_found}
    end
  end

  def status(_prefix, _document_id), do: {:error, :not_found}

  @doc "The requester recorded in the newest non-discarded version, or nil."
  def requester_of(prefix, document_id) do
    case latest_version(prefix, document_id) do
      %DocumentVersion{content: %{"requester" => requester}} -> requester
      _other -> nil
    end
  end

  # -- the transaction -----------------------------------------------------------------------

  defp transact(prefix, performer, input) do
    case Repo.transaction(fn -> decide(prefix, performer, input) end) do
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

        # Audit.insert_entry/3 and the insert raise on a database failure; the transaction is
        # already rolled back, nothing was written (INV-8).
        other ->
          Logger.error("procurement decision failed: #{inspect(Map.get(other, :code))}")
          {:error, :audit_failed}
      end
  end

  defp decide(prefix, performer, input) do
    # constant SQL, no table: the same bounds as Documents.issue/2, scoped to this transaction
    SQL.query!(Repo, "SET LOCAL lock_timeout = '2s'")
    SQL.query!(Repo, "SET LOCAL statement_timeout = '15s'")

    with {:ok, document} <- lock_document(prefix, input.document_id),
         :ok <- replay_or_proceed(prefix, performer, input),
         :ok <- not_requester(prefix, document.id, performer),
         :ok <- bound(prefix, input),
         :ok <- open_version(prefix, input) do
      insert(prefix, performer, input)
    else
      {:replay, decision} -> {:accepted, result(decision, true)}
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
      document -> {:ok, document}
    end
  end

  defp replay_or_proceed(prefix, performer, input) do
    case stored(prefix, input.document_id, input.idempotency_key) do
      nil ->
        :ok

      %Decision{} = decision ->
        if same?(decision, performer, input),
          do: {:replay, decision},
          else: {:error, :idempotency_key_reused}
    end
  end

  defp same?(decision, performer, input) do
    Atom.to_string(decision.decision) == input.decision and
      decision.version_no == input.version_no and
      decision.content_hash == input.content_hash and decision.performer == performer
  end

  defp not_requester(prefix, document_id, performer) do
    if requester_of(prefix, document_id) == performer,
      do: {:error, :self_decision},
      else: :ok
  end

  defp bound(prefix, input) do
    if Documents.verify_binding(
         prefix,
         input.document_id,
         input.version_no,
         input.content_hash
       ),
       do: :ok,
       else: {:error, :binding_refused}
  end

  defp open_version(prefix, input) do
    case latest_decision(prefix, input.document_id, input.version_no) do
      %Decision{decision: closed} when closed in [:reject, :return] -> {:error, :version_closed}
      _open -> :ok
    end
  end

  defp insert(prefix, performer, input) do
    now = DateTime.utc_now()

    decision =
      Repo.insert!(
        %Decision{
          id: Ecto.UUID.generate(),
          document_id: input.document_id,
          version_no: input.version_no,
          content_hash: input.content_hash,
          decision: String.to_existing_atom(input.decision),
          performer: performer,
          decided_at: now,
          idempotency_key: input.idempotency_key,
          inserted_at: now
        },
        prefix: prefix
      )

    entry = %{
      actor_id: performer,
      action: "procurement.decision_recorded",
      resource_type: "purchase_request",
      resource_id: input.document_id,
      before_state: nil,
      after_state: %{
        "decision" => input.decision,
        "version_no" => input.version_no,
        "content_hash" => input.content_hash
      }
    }

    case Audit.insert_entry(Repo, entry, prefix) do
      {:ok, _entry} -> {:accepted, result(decision, false)}
      {:error, reason} -> Repo.rollback({:audit_failed, reason})
    end
  end

  # The row lock makes this unreachable between two decisions of one document; kept so a unique
  # violation from any other path answers like a replay and not with a crash (INV-8).
  defp replay_after_race(prefix, performer, input) do
    case stored(prefix, input.document_id, input.idempotency_key) do
      %Decision{} = decision ->
        if same?(decision, performer, input),
          do: {:ok, result(decision, true)},
          else: {:error, :idempotency_key_reused}

      nil ->
        {:error, :busy}
    end
  end

  # -- reads ----------------------------------------------------------------------------------

  defp stored(prefix, document_id, key) do
    Repo.one(
      from(d in Decision, where: d.document_id == ^document_id and d.idempotency_key == ^key),
      prefix: prefix
    )
  end

  defp latest_decision(prefix, document_id, version_no) do
    Repo.one(
      from(d in Decision,
        where: d.document_id == ^document_id and d.version_no == ^version_no,
        order_by: [desc: d.decided_at, desc: d.inserted_at, desc: d.id],
        limit: 1
      ),
      prefix: prefix
    )
  end

  defp decisions_of(prefix, document_id) do
    Repo.all(
      from(d in Decision,
        where: d.document_id == ^document_id,
        order_by: [asc: d.decided_at, asc: d.inserted_at, asc: d.id]
      ),
      prefix: prefix
    )
  end

  defp current_version(prefix, document_id) do
    Repo.one(
      from(v in DocumentVersion,
        join: d in Document,
        on: d.current_version == v.id,
        where: d.id == ^document_id and d.type_key == ^@type_key
      ),
      prefix: prefix
    )
  end

  defp latest_version(prefix, document_id) do
    with {:ok, id} <- cast_uuid(document_id) do
      Repo.one(
        from(v in DocumentVersion,
          where: v.document_id == ^id and v.status != :discarded,
          order_by: [desc: v.version_no],
          limit: 1
        ),
        prefix: prefix
      )
    else
      _error -> nil
    end
  end

  defp state_of(%DocumentVersion{status: :draft}, _decision), do: :draft
  defp state_of(%DocumentVersion{status: :cancelled}, _decision), do: :cancelled
  defp state_of(_version, %Decision{decision: :approve}), do: :approved
  defp state_of(_version, %Decision{decision: :reject}), do: :rejected
  defp state_of(_version, %Decision{decision: :return}), do: :returned
  defp state_of(_version, nil), do: :submitted

  # -- shape ----------------------------------------------------------------------------------

  defp shape(params) do
    get = fn key -> Map.get(params, key, Map.get(params, Atom.to_string(key))) end

    decision =
      case get.(:decision) do
        value when is_atom(value) and not is_nil(value) -> Atom.to_string(value)
        value -> value
      end

    errors =
      [
        {:document_id, is_binary(get.(:document_id))},
        {:version_no, is_integer(get.(:version_no)) and get.(:version_no) > 0},
        {:content_hash,
         is_binary(get.(:content_hash)) and Regex.match?(@hash, get.(:content_hash))},
        {:decision, decision in @decisions},
        {:idempotency_key,
         is_binary(get.(:idempotency_key)) and Regex.match?(@key, get.(:idempotency_key))}
      ]
      |> Enum.reject(fn {_field, ok?} -> ok? end)
      |> Enum.map(fn {field, _ok?} -> %{field: Atom.to_string(field), code: "invalid"} end)

    cond do
      errors == [] ->
        {:ok,
         %{
           document_id: get.(:document_id),
           version_no: get.(:version_no),
           content_hash: get.(:content_hash),
           decision: decision,
           idempotency_key: get.(:idempotency_key)
         }}

      # a malformed document id is the same answer as an absent one (INV-5)
      Enum.any?(errors, &(&1.field == "document_id")) ->
        {:error, :not_found}

      true ->
        {:error, {:validation, errors}}
    end
  end

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp cast_uuid(_value), do: :error

  defp tenant(prefix) do
    case TenantProvisioning.tenant_id_for_schema_name(prefix) do
      {:ok, tenant_id} -> {:ok, tenant_id}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  defp result(%Decision{} = decision, replayed) do
    %{
      decision_id: decision.id,
      document_id: decision.document_id,
      version_no: decision.version_no,
      content_hash: decision.content_hash,
      decision: decision.decision,
      performer: decision.performer,
      decided_at: decision.decided_at,
      replayed: replayed
    }
  end

  defp public(%Decision{} = decision) do
    %{
      decision: decision.decision,
      version_no: decision.version_no,
      performer: decision.performer,
      decided_at: decision.decided_at
    }
  end

  # D9: a refusal is a telemetry count after the transaction, never an audit row. The metadata has
  # no id, hash, key or content.
  @doc """
  Counts a refused operation on `[:letflow, :procurement, :refused]` (decision 0056 D9); returns
  `result` unchanged. Shared with `PurchaseRequests.submit_for_bpm/2`.
  """
  def count_refusal({:error, reason} = result, action, prefix) do
    :telemetry.execute([:letflow, :procurement, :refused], %{count: 1}, %{
      action: action,
      reason: reason_atom(reason),
      prefix: prefix
    })

    result
  end

  def count_refusal(result, _action, _prefix), do: result

  defp reason_atom(reason) when is_atom(reason), do: reason
  defp reason_atom({reason, _detail}) when is_atom(reason), do: reason
  defp reason_atom(_reason), do: :unknown
end
