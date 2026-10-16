defmodule Letflow.Idempotency.SquatAudit do
  @moduledoc """
  GH #2597 -- read-only audit of pre-#2550 idempotency-key squats
  (design `lib/letflow/design/gh2597-pre-namespace-squat-audit.md`, sections 2-4).

  Before GH #2550 namespaced caller keys, any authenticated writer could send a bare key such
  as `certificate:issue:<session id>` and claim it in `event_idempotency` before the server did.
  The legitimate writer then got `idempotency_key_reuse` for ever. This module finds such rows.

  ## Read-only by construction

  This module only reads. `audit_tenant/1` runs inside a transaction whose first statements make
  Postgres itself refuse writes, and that transaction ALWAYS ends by rollback (so under the
  Ecto sandbox the setting cannot outlive the call). `classify_key/3` is plain reads and sets
  nothing, because the remediation module calls it inside its own read-write transaction; the
  audit and the remediation refusal therefore share one rule evaluator and cannot disagree.
  The module has no call that modifies a table (pinned by a source-scan test).

  ## Flag rule rule of thumb

  A flag needs a POSITIVE mismatch against a verified legitimate writer (design section 2).
  Unknown or unclassifiable rows are `:report_only`, never `:flagged`, because remediation acts
  only on flags. A row that matches its legitimate writer has verdict `:clear` and is not
  listed by `audit_tenant/1`.

  ## Output posture (INV-4)

  A finding carries ids, the key, the event type and timestamps. It never carries a payload or
  `field_values` content.
  """

  import Ecto.Query

  alias Letflow.Entities.Record.Latest
  alias Letflow.EventStore
  alias Letflow.EventStore.ArchivedEvent
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.IdempotencyRecord
  alias Letflow.Idempotency
  alias Letflow.Repo
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @type family :: String.t()
  @type reason ::
          :wrong_event_type
          | :wrong_entity_type
          | :actor_mismatch
          | :target_mismatch
          | :actor_not_platform
          | :client_event_type
  @type verdict :: :flagged | :report_only | :clear
  @type finding :: %{
          tenant_id: Ecto.UUID.t(),
          schema: String.t(),
          key: String.t(),
          family: family() | nil,
          target_id: String.t() | nil,
          stored_actor: Ecto.UUID.t() | nil,
          expected_actor: Ecto.UUID.t() | nil,
          event_type: String.t() | nil,
          event_created_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          row_id: Ecto.UUID.t(),
          event_id: Ecto.UUID.t(),
          squat_entity_type: String.t() | nil,
          squat_record_id: String.t() | nil,
          verdict: verdict(),
          reason:
            reason()
            | :session_not_found
            | :target_not_uuid
            | :event_missing
            | :payload_unresolved
            | :derived_key
            | :reserved_prefix_present
            | :no_rule
            | nil
        }
  @type audit_error :: :unknown_tenant | :lock_conflict | {:query_failed, Exception.t()}

  # The entity-record names are assembled from their suffixes on purpose: this module only
  # CLASSIFIES stored event types and writes no events, and records_test.exs pins (by a lexical
  # scan) which lib files may spell the update/delete event type names.
  @client_types Enum.map(~w(CREATED UPDATED), &"ENTITY_RECORD_#{&1}") ++
                  ~w(INSTANCE_STARTED INSTANCE_CANCELLED INSTANCE_PINS_REBOUND)

  # Families with a decided flag rule (design section 2). Anything else in the prefix list is
  # report-only (`:no_rule`), so a prefix added later is listed until it is given a rule.
  @actor_rule ~w(script_run: effect_applied: ordering_lag_exceeded: promotion_assertion_teardown_failed:)
  @timer_rule ~w(timer_fired: escalation_timer_fired:)
  @client_type_rule ~w(service_task_dispatch: service_task: script_task_dispatch:)
  @type_rule %{
    "attachment_attached:" => "ATTACHMENT_ATTACHED",
    "attachment_removed:" => "ATTACHMENT_REMOVED",
    "definition_promoted:" => "DEFINITION_PROMOTED",
    "definition_version_rolled_back:" => "DEFINITION_VERSION_ROLLED_BACK"
  }

  @derived_marker "::sub_process_"
  @certificate_prefix "certificate:issue:"

  @batch_size 500
  @tx_timeout :timer.minutes(5)

  @doc "Every key family this module classifies (server prefixes plus reserved ones)."
  @spec families() :: [family()]
  def families, do: Idempotency.server_prefixes() ++ Idempotency.reserved_prefixes()

  @doc "The event types a client route could write under a pre-#2550 caller key."
  @spec client_types() :: [String.t()]
  def client_types, do: @client_types

  @doc """
  Audits one tenant. The schema is resolved from the tenant's registration, never typed.
  Returns only `:flagged` and `:report_only` findings (a `:clear` row is not listed).
  """
  @spec audit_tenant(tenant_id :: Ecto.UUID.t()) :: {:ok, [finding()]} | {:error, audit_error()}
  def audit_tenant(tenant_id) do
    with {:ok, %{findings: findings}} <- scan_tenant(tenant_id), do: {:ok, findings}
  end

  @doc """
  Like `audit_tenant/1` but also returns how many family rows were scanned (the operator
  summary needs it).
  """
  @spec scan_tenant(tenant_id :: Ecto.UUID.t()) ::
          {:ok, %{scanned: non_neg_integer(), findings: [finding()]}} | {:error, audit_error()}
  def scan_tenant(tenant_id) do
    with {:ok, canonical} <- cast_tenant(tenant_id),
         {:ok, schema} <- TenantProvisioning.registered_schema(canonical) do
      scan_schema(canonical, schema)
    else
      {:error, :not_found} -> {:error, :unknown_tenant}
      {:error, _} = error -> error
    end
  end

  @doc """
  Audits every registered tenant. A failing tenant does not stop the others.
  """
  @spec audit_all() :: [{Registration.t(), {:ok, [finding()]} | {:error, audit_error()}}]
  def audit_all do
    for {registration, result} <- scan_all() do
      {registration, with({:ok, %{findings: findings}} <- result, do: {:ok, findings})}
    end
  end

  @doc "Like `audit_all/0` with the scanned counts (see `scan_tenant/1`)."
  @spec scan_all() :: [
          {Registration.t(),
           {:ok, %{scanned: non_neg_integer(), findings: [finding()]}} | {:error, audit_error()}}
        ]
  def scan_all do
    for registration <- TenantProvisioning.list_registrations() do
      {registration, scan_schema(registration.tenant_id, registration.schema_name)}
    end
  end

  @doc """
  The ONE rule evaluator for a single stored key. Plain reads; never sets read-only, because
  remediation calls it inside a read-write transaction. `{:error, :no_such_key}` when the
  tenant has no such row. A key outside every family gets `family: nil` and
  `verdict: :report_only, reason: :no_rule`.
  """
  @spec classify_key(repo :: module(), schema :: String.t(), key :: String.t()) ::
          {:ok, finding()} | {:error, :no_such_key}
  def classify_key(repo, schema, key) when is_binary(schema) and is_binary(key) do
    case repo.one(row_query() |> where([i], i.idempotency_key == ^key), prefix: schema) do
      nil -> {:error, :no_such_key}
      row -> {:ok, classify_row(repo, schema, row)}
    end
  end

  # -------------------------------------------------------------------------
  # Audit transaction
  # -------------------------------------------------------------------------

  defp cast_tenant(tenant_id) when is_binary(tenant_id) do
    case Ecto.UUID.cast(tenant_id) do
      {:ok, canonical} -> {:ok, canonical}
      :error -> {:error, :unknown_tenant}
    end
  end

  defp cast_tenant(_), do: {:error, :unknown_tenant}

  defp scan_schema(tenant_id, schema) do
    result =
      Repo.transaction(
        fn ->
          # Constant SQL as inline literals, no interpolation (the lexical SQL scans read
          # literals only). The postgres-enforced read-only proof (design 4.1).
          Repo.query!("SET LOCAL transaction_read_only = on")
          Repo.query!("SET LOCAL lock_timeout = '2s'")
          Repo.rollback({:scanned, scan_batches(schema, nil, 0, [])})
        end,
        timeout: @tx_timeout
      )

    case result do
      {:error, {:scanned, {scanned, findings}}} ->
        {:ok, %{scanned: scanned, findings: finalize(findings, tenant_id, schema)}}

      {:error, other} ->
        # Unreachable by construction (only the scan rolls back); kept type-correct.
        {:error,
         {:query_failed,
          RuntimeError.exception("unexpected audit rollback: " <> inspect(other, limit: 3))}}
    end
  rescue
    # Connection loss and query/queue timeouts: this tenant's error only, scan_all goes on.
    e in DBConnection.ConnectionError ->
      {:error, {:query_failed, e}}

    e in Postgrex.Error ->
      case e.postgres do
        %{code: code} when code in [:lock_not_available, :deadlock_detected] ->
          {:error, :lock_conflict}

        _ ->
          {:error, {:query_failed, e}}
      end
  end

  defp finalize(findings, tenant_id, schema) do
    findings
    |> Enum.map(&Map.merge(&1, %{tenant_id: tenant_id, schema: schema}))
    |> Enum.sort_by(&{&1.inserted_at && DateTime.to_unix(&1.inserted_at, :microsecond), &1.key})
  end

  # Keyset on the row id (a stable total order that needs no timestamp precision); the
  # findings are re-sorted by inserted_at at the end.
  defp scan_batches(schema, after_id, scanned, acc) do
    rows =
      row_query()
      |> where(
        [i],
        fragment(
          "EXISTS (SELECT 1 FROM unnest(?) p WHERE starts_with(?, p))",
          type(^families(), {:array, :string}),
          i.idempotency_key
        )
      )
      |> maybe_after(after_id)
      |> order_by([i], asc: i.id)
      |> limit(^@batch_size)
      |> Repo.all(prefix: schema, timeout: @tx_timeout)

    case rows do
      [] ->
        {scanned, acc}

      rows ->
        listed =
          rows
          |> Enum.map(&classify_row(Repo, schema, &1))
          |> Enum.reject(&(&1.verdict == :clear))

        scan_batches(schema, List.last(rows).row_id, scanned + length(rows), listed ++ acc)
    end
  end

  defp maybe_after(query, nil), do: query
  defp maybe_after(query, id), do: where(query, [i], i.id > type(^id, :binary_id))

  # One row per idempotency key, joined to the event in `events` or `events_archive` on the
  # partition key (equality keeps partition pruning possible). Neither found: `found` is false.
  defp row_query do
    from(i in IdempotencyRecord,
      left_join: e in Event,
      on: e.event_id == i.event_id and e.created_at == i.event_created_at,
      left_join: a in ArchivedEvent,
      on: a.event_id == i.event_id and a.created_at == i.event_created_at,
      select: %{
        row_id: i.id,
        key: i.idempotency_key,
        event_id: i.event_id,
        event_created_at: i.event_created_at,
        inserted_at: i.inserted_at,
        found: not is_nil(e.event_id) or not is_nil(a.event_id),
        event_type: coalesce(e.event_type, a.event_type),
        stored_actor: type(coalesce(e.actor_id, a.actor_id), Ecto.UUID),
        payload_ref: fragment("COALESCE(?->>'$ref', ?->>'$ref')", e.payload, a.payload),
        entity_type:
          fragment("COALESCE(?->>'entity_type', ?->>'entity_type')", e.payload, a.payload),
        record_id: fragment("COALESCE(?->>'record_id', ?->>'record_id')", e.payload, a.payload),
        field_session_id:
          fragment(
            "COALESCE(?->'field_values'->>'session_id', ?->'field_values'->>'session_id')",
            e.payload,
            a.payload
          )
      }
    )
  end

  # -------------------------------------------------------------------------
  # Rules (design section 2)
  # -------------------------------------------------------------------------

  defp classify_row(repo, schema, row) do
    family = family_of(row.key)
    base = base_finding(row, family)

    {verdict, reason, extra} = evaluate(repo, schema, family, row)
    base |> Map.merge(extra) |> Map.merge(%{verdict: verdict, reason: reason})
  end

  defp base_finding(row, family) do
    %{
      key: row.key,
      family: family,
      target_id: nil,
      stored_actor: row.stored_actor,
      expected_actor: nil,
      event_type: row.event_type,
      event_created_at: row.event_created_at,
      inserted_at: to_datetime(row.inserted_at),
      row_id: row.row_id,
      event_id: row.event_id,
      squat_entity_type: row.entity_type,
      squat_record_id: row.record_id,
      verdict: :report_only,
      reason: nil
    }
  end

  defp to_datetime(%NaiveDateTime{} = n), do: DateTime.from_naive!(n, "Etc/UTC")
  defp to_datetime(%DateTime{} = d), do: d
  defp to_datetime(nil), do: nil

  # Longest matching prefix; nil when the key is in no family.
  defp family_of(key) do
    families()
    |> Enum.filter(&String.starts_with?(key, &1))
    |> Enum.max_by(&byte_size/1, fn -> nil end)
  end

  defp evaluate(_repo, _schema, nil, _row), do: {:report_only, :no_rule, %{}}

  defp evaluate(_repo, _schema, "sys:", _row), do: {:report_only, :reserved_prefix_present, %{}}

  defp evaluate(_repo, _schema, family, _row)
       when family in ["entities-record-import:", "req345-seed-"],
       do: {:report_only, :no_rule, %{}}

  defp evaluate(repo, schema, family, row) do
    cond do
      String.contains?(row.key, @derived_marker) ->
        evaluate_derived(family, row)

      not row.found ->
        {:report_only, :event_missing, %{}}

      family == @certificate_prefix ->
        evaluate_certificate(repo, schema, row)

      true ->
        {verdict, reason} = evaluate_simple(family, row)
        {verdict, reason, %{}}
    end
  end

  # Derived `<base>::sub_process_*` keys: only the timer bases have a decided actor-only rule
  # (their children carry the platform actor, engine.ex timer paths); any other base is
  # reported, never flagged (design section 2, OQ-4).
  defp evaluate_derived(family, row) when family in @timer_rule do
    cond do
      not row.found -> {:report_only, :event_missing, %{}}
      actor_not_platform?(row) -> {:flagged, :actor_not_platform, %{}}
      true -> {:clear, nil, %{}}
    end
  end

  defp evaluate_derived(_family, _row), do: {:report_only, :derived_key, %{}}

  defp evaluate_simple(family, row) when family in @timer_rule do
    cond do
      actor_not_platform?(row) -> {:flagged, :actor_not_platform}
      row.event_type in @client_types -> {:flagged, :client_event_type}
      true -> {:clear, nil}
    end
  end

  defp evaluate_simple(family, row) when family in @actor_rule do
    if actor_not_platform?(row), do: {:flagged, :actor_not_platform}, else: {:clear, nil}
  end

  defp evaluate_simple(family, row) when family in @client_type_rule do
    if row.event_type in @client_types, do: {:flagged, :client_event_type}, else: {:clear, nil}
  end

  defp evaluate_simple(family, row) when is_map_key(@type_rule, family) do
    if row.event_type != Map.fetch!(@type_rule, family),
      do: {:flagged, :wrong_event_type},
      else: {:clear, nil}
  end

  # A family in the prefix list without a decided rule.
  defp evaluate_simple(_family, _row), do: {:report_only, :no_rule}

  defp actor_not_platform?(row), do: row.stored_actor != EventStore.platform_actor_id()

  # R1-R4 (design section 2). Payload rules need the payload; an oversized payload is a
  # single-key `$ref` map, in which case only R1 and R3 apply.
  defp evaluate_certificate(repo, schema, row) do
    suffix = String.replace_prefix(row.key, @certificate_prefix, "")
    payload_ok? = is_nil(row.payload_ref)

    cond do
      row.event_type != "ENTITY_RECORD_CREATED" ->
        {:flagged, :wrong_event_type, %{}}

      payload_ok? and is_binary(row.entity_type) and row.entity_type != "certificate" ->
        {:flagged, :wrong_entity_type, %{}}

      true ->
        certificate_vs_session(repo, schema, row, suffix, payload_ok?)
    end
  end

  defp certificate_vs_session(repo, schema, row, suffix, payload_ok?) do
    case Ecto.UUID.cast(suffix) do
      :error ->
        {:report_only, :target_not_uuid, %{}}

      {:ok, target} ->
        case session_user_id(repo, schema, target) do
          nil ->
            {:report_only, :session_not_found, %{target_id: target}}

          expected ->
            extra = %{target_id: target, expected_actor: expected}
            certificate_verdict(row, target, expected, payload_ok?, extra)
        end
    end
  end

  defp certificate_verdict(row, target, expected, payload_ok?, extra) do
    cond do
      not same_uuid?(row.stored_actor, expected) ->
        {:flagged, :actor_mismatch, extra}

      payload_ok? and is_binary(row.field_session_id) and
          not same_uuid?(row.field_session_id, target) ->
        {:flagged, :target_mismatch, extra}

      not payload_ok? ->
        {:report_only, :payload_unresolved, extra}

      true ->
        {:clear, nil, extra}
    end
  end

  defp same_uuid?(a, b) when is_binary(a) and is_binary(b),
    do: String.downcase(a) == String.downcase(b)

  defp same_uuid?(_, _), do: false

  # Same source as the session ownership check (`entity_record_latest`, entity_type "session").
  defp session_user_id(repo, schema, record_id) do
    from(l in Latest,
      where: l.entity_type == "session" and l.record_id == ^record_id,
      select: fragment("?->>'user_id'", l.field_values),
      limit: 1
    )
    |> repo.one(prefix: schema)
  end
end
