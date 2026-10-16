defmodule Letflow.Idempotency.SquatRemediation do
  @moduledoc """
  GH #2597 -- explicit, audited removal of ONE flagged pre-#2550 idempotency-key squat
  (design `lib/letflow/design/gh2597-pre-namespace-squat-audit.md`, section 5 D1-D6).

  This is the only writer of the squat tooling, split from `Letflow.Idempotency.SquatAudit` so
  "the audit is read-only" is structural. It is for a PLATFORM OPERATOR (release `rpc` / Mix
  task); there is deliberately no HTTP route (D1): the parties who may have planted a squat
  must not be the ones deciding what a squat is.

  ## What one call does (D3), in one transaction

  1. Validates the key and operator, resolves the schema from the tenant id, sets a 2 s
     `lock_timeout`.
  2. Locks the key's `event_idempotency` row (`FOR UPDATE`). No row: `:already_clear`,
     nothing written, no audit entry.
  3. Re-runs the audit's flag rule on the locked row (`SquatAudit.classify_key/3`). Anything
     other than a flag is refused with `{:not_flagged, finding}`.
  4. Writes the audit entry `idempotency_squat.remediated` in the same transaction. It carries
     ids, counts and `finding_ref` only; the key text itself is not recorded.
  5. Deletes exactly that `event_idempotency` row (count must be 1).

  The squatter's `events` row and entity record are left in place (D2); the audit entry names
  the record so an operator can remove it through the normal entity API.
  """

  import Ecto.Query

  alias Letflow.Audit
  alias Letflow.EventStore.IdempotencyRecord
  alias Letflow.Idempotency.SquatAudit
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @action "idempotency_squat.remediated"
  @resource_type "idempotency_key"
  @lock_timeout_sql "SET LOCAL lock_timeout = '2s'"
  @max_key_bytes 255
  @max_operator_bytes 100

  @type error ::
          :invalid_key
          | :invalid_operator
          | :unknown_tenant
          | :lock_conflict
          | {:not_flagged, SquatAudit.finding()}
          | :delete_count_mismatch
          | {:audit_failed, term()}

  @doc """
  Removes the flagged squat row for exact `key` in tenant `tenant_id`, recording `operator`
  (a non-empty printable label, at most #{@max_operator_bytes} bytes) in the audit entry.
  Idempotent: a second call returns `:already_clear`.
  """
  @spec remediate(tenant_id :: Ecto.UUID.t(), key :: String.t(), operator :: String.t()) ::
          {:ok, %{outcome: :removed | :already_clear, key: String.t()}} | {:error, error()}
  def remediate(tenant_id, key, operator) do
    with :ok <- validate_key(key),
         :ok <- validate_operator(operator),
         {:ok, schema} <- resolve_schema(tenant_id) do
      run(schema, key, operator)
    end
  end

  # -------------------------------------------------------------------------

  defp validate_key(key)
       when is_binary(key) and byte_size(key) >= 1 and byte_size(key) <= @max_key_bytes do
    if String.valid?(key) and not String.contains?(key, <<0>>),
      do: :ok,
      else: {:error, :invalid_key}
  end

  defp validate_key(_), do: {:error, :invalid_key}

  defp validate_operator(op)
       when is_binary(op) and byte_size(op) >= 1 and byte_size(op) <= @max_operator_bytes do
    if String.valid?(op) and String.printable?(op) and String.trim(op) != "",
      do: :ok,
      else: {:error, :invalid_operator}
  end

  defp validate_operator(_), do: {:error, :invalid_operator}

  defp resolve_schema(tenant_id) when is_binary(tenant_id) do
    with {:ok, canonical} <- Ecto.UUID.cast(tenant_id),
         {:ok, schema} <- TenantProvisioning.registered_schema(canonical) do
      {:ok, schema}
    else
      _ -> {:error, :unknown_tenant}
    end
  end

  defp resolve_schema(_), do: {:error, :unknown_tenant}

  defp run(schema, key, operator) do
    result =
      Repo.transaction(fn ->
        # Constant SQL. Bounds every wait below; a timeout/deadlock maps to :lock_conflict.
        Repo.query!(@lock_timeout_sql)

        case lock_row(schema, key) do
          nil -> Repo.rollback(:already_clear)
          row -> remediate_locked(schema, key, operator, row)
        end
      end)

    case result do
      {:ok, :removed} -> {:ok, %{outcome: :removed, key: key}}
      {:error, :already_clear} -> {:ok, %{outcome: :already_clear, key: key}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in Postgrex.Error ->
      case e.postgres do
        %{code: code} when code in [:lock_not_available, :deadlock_detected] ->
          {:error, :lock_conflict}

        _ ->
          reraise e, __STACKTRACE__
      end
  end

  defp lock_row(schema, key) do
    from(i in IdempotencyRecord,
      where: i.idempotency_key == ^key,
      lock: "FOR UPDATE",
      select: %{id: i.id}
    )
    |> Repo.one(prefix: schema)
  end

  defp remediate_locked(schema, key, operator, %{id: row_id}) do
    case SquatAudit.classify_key(Repo, schema, key) do
      {:ok, %{verdict: :flagged, row_id: ^row_id} = finding} ->
        with {:ok, _entry} <-
               Audit.insert_entry(Repo, audit_attrs(finding, operator), schema),
             {1, _} <- delete_row(schema, row_id, key) do
          :removed
        else
          {:error, reason} -> Repo.rollback({:audit_failed, reason})
          _count_mismatch -> Repo.rollback(:delete_count_mismatch)
        end

      {:ok, finding} ->
        Repo.rollback({:not_flagged, Map.put(finding, :schema, schema)})

      {:error, :no_such_key} ->
        # Locked a moment ago in this same transaction; cannot vanish. Treated as clear.
        Repo.rollback(:already_clear)
    end
  end

  defp delete_row(schema, row_id, key) do
    from(i in IdempotencyRecord, where: i.id == ^row_id and i.idempotency_key == ^key)
    |> Repo.delete_all(prefix: schema)
  end

  # Ids, types, counts and timestamps only: never a payload, a field value or the key itself
  # (the key is client-chosen text). `resource_id` is the removed row's id. The operator is a
  # platform operator, not a tenant user, so actor_id is nil and the label is in before_state.
  defp audit_attrs(finding, operator) do
    %{
      actor_id: nil,
      action: @action,
      resource_type: @resource_type,
      resource_id: finding.row_id,
      before_state: %{
        "finding_ref" => "GH #2597",
        "operator" => operator,
        "family" => finding.family,
        "row_id" => finding.row_id,
        "event_id" => finding.event_id,
        "event_type" => finding.event_type,
        "event_created_at" => iso(finding.event_created_at),
        "stored_actor" => finding.stored_actor,
        "expected_actor" => finding.expected_actor,
        "reason" => Atom.to_string(finding.reason),
        "squat_entity_type" => finding.squat_entity_type,
        "squat_record_id" => finding.squat_record_id
      },
      after_state: %{"removed" => true, "rows_removed" => 1}
    }
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
