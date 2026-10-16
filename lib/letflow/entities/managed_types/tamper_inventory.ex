defmodule Letflow.Entities.ManagedTypes.TamperInventory do
  @moduledoc """
  The read-only tamper inventory infra runs BEFORE the exam stamp (GH #2596; design
  `lib/letflow/design/gh2596-exam-managed-types.md` section 8). Per exam tenant it lists the
  record events of the exam entity types that were probably NOT written by the exam module's own
  paths (the generic records routes or import).

  ## What distinguishes the sources

  A plain record write appends one `events` row (the `ENTITY_RECORD_*` created/updated/deleted types) with the
  actor and an idempotency key, and leaves no route marker and no audit entry. So the sources are
  not distinguishable by one column; the inventory reports the closest proxy as `evidence`:

    * `:import_key` - key starts with `entities-record-import:` (only the import route mints it)
    * `:client_key` - key starts with `client:rec:` (only create/update routes, only when the client
      supplied a key)
    * `:unrecognised_key_shape` - neither a UUID, nor `certificate:issue:<uuid>`, nor one of the two
      route prefixes (a likely pre-namespacing raw client key)
    * `:non_owner_actor` - the actor differs from the owning session's `user_id` (every exam module
      write is made as the session's candidate)
    * `:authoring_type` - an authoring type event (only under `scope: :authoring | :all`)

  Blind spot: a keyless generic write of a runtime type by the SAME user as the session owner is not
  detected (it needs a candidate who also holds `:EntitiesRecordsWrite`); a generic DELETE is
  detected only through `:non_owner_actor`; events moved to `events_archive` by retention are not
  scanned.

  ## Read-only, no payload disclosure

  Each tenant's reads run in a transaction whose first statement is `SET TRANSACTION READ ONLY`; the
  module contains no insert, update or delete. The query extracts only the `entity_type` and
  `record_id` JSON keys of the event body in SQL (resolving an over-size event through the payload
  side table the same way) and never selects the body or any `field_values` into Elixir. Findings hold
  ids, an event type, an actor id and a timestamp (INV-5), go back to the operator (Mix task stdout
  or the `rpc` return value) and are never passed to `Logger`. Every query has an explicit tenant
  `prefix:` (INV-1) and bound parameters (INV-7).

  Called through `Letflow.Release.ManagedTypes.tamper_inventory/1`.
  """

  import Ecto.Query

  alias Letflow.Entities.ManagedTypes.Stamp
  alias Letflow.Repo
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @authoring_names ~w(answer_option category exam exam_manual_question exam_question_rule
                      exam_question_rule_tag exam_section question question_tag tag)

  # Built from the suffixes (read-only module: it only reads these types, never writes them).
  @record_event_types Enum.map(~w(CREATED UPDATED DELETED), &("ENTITY_RECORD_" <> &1))

  @default_cap 10_000

  @type scope :: :runtime | :authoring | :all

  @type finding :: %{
          tenant_id: Ecto.UUID.t() | nil,
          entity_type: String.t(),
          record_id: String.t() | nil,
          event_type: String.t(),
          actor_id: Ecto.UUID.t(),
          occurred_at: DateTime.t(),
          evidence:
            :import_key
            | :client_key
            | :unrecognised_key_shape
            | :non_owner_actor
            | :authoring_type
        }

  @type tenant_findings :: %{
          tenant_id: Ecto.UUID.t() | nil,
          schema_name: String.t(),
          findings: [finding()],
          truncated: boolean(),
          skipped: nil | :schema_missing | :nested_transaction
        }

  @type report :: %{
          scope: scope(),
          tenants: [tenant_findings()],
          finding_total: non_neg_integer()
        }

  @type opts :: [module: String.t(), scope: scope(), cap: pos_integer()]

  # The event body's `entity_type` / `record_id` keys, extracted in SQL: from the inline body, else
  # from the side table row of an over-size event. The body column is never selected.
  defmacrop entity_type_of(inline, stored) do
    quote do
      fragment("COALESCE(?->>'entity_type', ?->>'entity_type')", unquote(inline), unquote(stored))
    end
  end

  defmacrop record_id_of(inline, stored) do
    quote do
      fragment("COALESCE(?->>'record_id', ?->>'record_id')", unquote(inline), unquote(stored))
    end
  end

  # The owning session's user id as text: the session record's own `user_id` for a `session` event,
  # else the `user_id` of the session the record points at (`session_id`).
  defmacrop owner_of(entity_type, record_values, session_values) do
    quote do
      fragment(
        "CASE WHEN ? = 'session' THEN ?->>'user_id' ELSE ?->>'user_id' END",
        unquote(entity_type),
        unquote(record_values),
        unquote(session_values)
      )
    end
  end

  defmacrop non_owner?(actor, owner) do
    quote do
      fragment(
        "(?::text IS NOT NULL AND ?::text IS DISTINCT FROM ?::text)",
        unquote(owner),
        unquote(actor),
        unquote(owner)
      )
    end
  end

  # A key shape the exam module never mints, an authoring type, or a foreign actor.
  defmacrop suspicious?(key, entity_type, actor, owner, authoring) do
    quote do
      fragment(
        """
        (? LIKE 'entities-record-import:%' OR ? LIKE 'client:rec:%' OR
         ? !~* '^(certificate:issue:){0,1}[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' OR
         (?::text IS NOT NULL AND ?::text IS DISTINCT FROM ?::text) OR ? = ANY(?))
        """,
        unquote(key),
        unquote(key),
        unquote(key),
        unquote(owner),
        unquote(actor),
        unquote(owner),
        unquote(entity_type),
        unquote(authoring)
      )
    end
  end

  @doc """
  Runs `run_tenant/2` for every registered tenant that has the exam module installed or any of the
  six runtime type names present. Only `module: "exam"` is supported (the default).
  """
  @spec run(opts()) :: {:ok, report()}
  def run(opts \\ []) do
    scope = Keyword.get(opts, :scope, :runtime)

    tenants =
      for %Registration{schema_name: schema} <- TenantProvisioning.list_registrations(),
          covered?(schema) do
        run_tenant(schema, opts)
      end

    {:ok,
     %{
       scope: scope,
       tenants: tenants,
       finding_total: tenants |> Enum.map(&length(&1.findings)) |> Enum.sum()
     }}
  end

  @doc """
  Lists the suspicious record events of one tenant schema. Strictly read-only: the reads run in a
  `SET TRANSACTION READ ONLY` transaction. Inside an open transaction it returns
  `skipped: :nested_transaction` and reads nothing; a missing schema is `skipped: :schema_missing`.
  Ordered by `occurred_at`, `global_seq`; capped per tenant with `truncated: true`.
  """
  @spec run_tenant(schema_name :: String.t(), opts()) :: tenant_findings()
  def run_tenant(schema_name, opts) when is_binary(schema_name) do
    tenant_id = tenant_id_or_nil(schema_name)

    empty = %{
      tenant_id: tenant_id,
      schema_name: schema_name,
      findings: [],
      truncated: false,
      skipped: nil
    }

    if Repo.in_transaction?() do
      %{empty | skipped: :nested_transaction}
    else
      scan(empty, tenant_id, schema_name, opts)
    end
  end

  defp scan(empty, tenant_id, schema, opts) do
    scope = Keyword.get(opts, :scope, :runtime)
    cap = Keyword.get(opts, :cap, @default_cap)

    {:ok, rows} =
      Repo.transaction(fn ->
        Repo.query!("SET TRANSACTION READ ONLY")
        Repo.all(inventory_query(types_for(scope), cap + 1), prefix: schema)
      end)

    findings = rows |> Enum.take(cap) |> Enum.map(&to_finding(&1, tenant_id))
    %{empty | findings: findings, truncated: length(rows) > cap}
  rescue
    error in Postgrex.Error ->
      case error do
        %Postgrex.Error{postgres: %{code: code}}
        when code in [:undefined_table, :invalid_schema_name] ->
          %{empty | skipped: :schema_missing}

        _other ->
          reraise error, __STACKTRACE__
      end
  end

  defp types_for(:runtime), do: Stamp.stamp_names()
  defp types_for(:authoring), do: @authoring_names
  defp types_for(:all), do: Stamp.stamp_names() ++ @authoring_names

  defp inventory_query(types, limit) do
    from(e in "events",
      left_join: sp in "event_payload_store",
      on: sp.event_id == e.event_id and sp.event_created_at == e.created_at,
      left_join: r in "entity_record_latest",
      on:
        r.entity_type == entity_type_of(e.payload, sp.payload) and
          fragment("?::text", r.record_id) == record_id_of(e.payload, sp.payload),
      left_join: s in "entity_record_latest",
      on:
        s.entity_type == "session" and
          fragment("?::text", s.record_id) == fragment("?->>'session_id'", r.field_values),
      where: e.event_type in ^@record_event_types,
      where: entity_type_of(e.payload, sp.payload) in ^types,
      where:
        suspicious?(
          e.idempotency_key,
          entity_type_of(e.payload, sp.payload),
          e.actor_id,
          owner_of(entity_type_of(e.payload, sp.payload), r.field_values, s.field_values),
          type(^@authoring_names, {:array, :string})
        ),
      order_by: [asc: e.created_at, asc: e.global_seq],
      limit: ^limit,
      select: %{
        entity_type: entity_type_of(e.payload, sp.payload),
        record_id: record_id_of(e.payload, sp.payload),
        event_type: e.event_type,
        actor_id: e.actor_id,
        created_at: e.created_at,
        idempotency_key: e.idempotency_key,
        non_owner:
          non_owner?(
            e.actor_id,
            owner_of(entity_type_of(e.payload, sp.payload), r.field_values, s.field_values)
          )
      }
    )
  end

  defp to_finding(row, tenant_id) do
    %{
      tenant_id: tenant_id,
      entity_type: row.entity_type,
      record_id: row.record_id,
      event_type: row.event_type,
      actor_id: load_uuid(row.actor_id),
      occurred_at: to_datetime(row.created_at),
      evidence: evidence(row)
    }
  end

  defp evidence(%{entity_type: type}) when type in @authoring_names, do: :authoring_type

  defp evidence(%{idempotency_key: "entities-record-import:" <> _rest}), do: :import_key
  defp evidence(%{idempotency_key: "client:rec:" <> _rest}), do: :client_key

  defp evidence(%{idempotency_key: key, non_owner: non_owner}) do
    cond do
      not module_key_shape?(key) -> :unrecognised_key_shape
      non_owner -> :non_owner_actor
      true -> :unrecognised_key_shape
    end
  end

  # A UUID, or `certificate:issue:<uuid>` (the shapes the exam module mints).
  defp module_key_shape?("certificate:issue:" <> rest), do: uuid?(rest)
  defp module_key_shape?(key), do: uuid?(key)

  defp uuid?(value), do: match?({:ok, _}, Ecto.UUID.cast(value)) and byte_size(value) == 36

  defp load_uuid(<<_::binary-size(16)>> = raw), do: Ecto.UUID.load!(raw)
  defp load_uuid(other), do: other

  defp to_datetime(%DateTime{} = dt), do: dt
  defp to_datetime(%NaiveDateTime{} = naive), do: DateTime.from_naive!(naive, "Etc/UTC")

  # Tenants with the exam module installed or any runtime type name present.
  defp covered?(schema) do
    installed? =
      Repo.exists?(from(m in "tenant_modules", where: m.module_id == "exam"), prefix: schema)

    installed? or
      Repo.exists?(
        from(d in "entity_definitions", where: d.name in ^Stamp.stamp_names()),
        prefix: schema
      )
  rescue
    error in Postgrex.Error ->
      case error do
        %Postgrex.Error{postgres: %{code: code}}
        when code in [:undefined_table, :invalid_schema_name] ->
          false

        _other ->
          reraise error, __STACKTRACE__
      end
  end

  defp tenant_id_or_nil(schema) do
    case TenantProvisioning.tenant_id_for_schema_name(schema) do
      {:ok, tenant_id} -> tenant_id
      {:error, _reason} -> nil
    end
  end
end
