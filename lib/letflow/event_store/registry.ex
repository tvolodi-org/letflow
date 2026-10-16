defmodule Letflow.EventStore.Registry do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Context module for the event type registry (ES-05), implementing the
  interface specified in `src/event_store/registry.zig`: `register_type/2`, `validate_payload/3`,
  `get_type/2`, backed by the tenant-scoped `event_type_registry` table
  (`Letflow.EventStore.Registry.EventType`). See
  `lib/letflow/design/req024-event-type-registry.md` for the full design
  this module implements.

  ## Arity/interface divergence from REQ-024's literal `/1`/`/2` text

  REQ-024's own description names `register_type/2 (or /3)`,
  `validate_payload/2`, `get_type/1` — those numbers describe R-Co's call
  shape after dropping Zig's `self`/`allocator` parameters, where `Registry`
  is a struct already bound to one pool/schema at `init/2` time. Letflow's
  `Registry` is a stateless context module (the same shape as
  `Letflow.Identity`/`Letflow.TenantProvisioning`), and this table is
  schema-per-tenant (AC1), so every DB call this module makes must resolve a
  tenant's physical schema before querying. Concretely: `register_type/2`
  stays literally `/2` (the second argument is `tenant_id`, not an
  additional record field); `validate_payload/2` becomes `validate_payload/3`
  and `get_type/1` becomes `get_type/2`, each gaining `tenant_id` as their
  last argument. The tenant-scope argument is **`tenant_id :: Ecto.UUID.t()`,
  not a raw prefix string** — each function resolves the physical
  `schema_name` internally via `Letflow.TenantProvisioning.Registration`
  (`Repo.get_by(Registration, tenant_id: tenant_id)`, the same lookup
  `Letflow.TenantProvisioning.replay_migrations/2` performs inline), and
  returns `{:error, :tenant_not_provisioned}` if no `Registration` row exists
  for that tenant. See the design doc section 4 for the full rationale
  (including rework iteration 1's correction of an earlier, factually wrong
  citation of `replay_migrations/2`'s own convention).

  ## JSON Schema validation library choice (a real decision, not a silent
  one — REQ-024's own acceptance criterion 5)

  `validate_payload/3`'s payload validation is implemented by this project's
  own hand-rolled `Letflow.EventStore.Registry.JsonSchema`, **not** by an
  external library such as `ex_json_schema`. This choice was made explicitly
  at CODE-DESIGNER design time — see
  `lib/letflow/design/req024-event-type-registry.md` section 1 for the full
  reasoning (in short: this project intentionally implements only a
  narrow keyword subset and treats every other keyword as inert, matching
  the exact contract this codebase's registered event-type schemas are
  written against; a general-purpose draft-04/06/07 library would enforce
  additional keywords those schemas don't expect, a real behavioral
  divergence rather than a cosmetic one, and the library's own error
  taxonomy doesn't match this platform's required `(field_path, constraint,
  actual)` shape without an adapter layer of comparable size to just writing
  the validator directly).
  No new `mix.exs` dependency was added for this — see section 1.4 for why
  this doesn't rise to a new `docs/migration/decisions/` record. See
  `Letflow.EventStore.Registry.JsonSchema`'s own moduledoc for the exact
  supported keyword table (`type`, `minimum`/`maximum`, `minLength`/
  `maxLength`, `enum`, `required`, `properties`, `items`,
  `additionalProperties` — every other keyword, including `$ref`/`pattern`/
  `format`/`allOf`/`anyOf`/`oneOf`/`not`/`patternProperties`, is silently
  ignored, per that module's own documented "permitted and inert" contract).

  ## No `last_validation_failures/1`-equivalent function

  By design, not omission: `validate_payload/3` returns validation failures
  alongside its error tuple (`{:error, {:payload_validation_failed,
  failures}}`) rather than exposing a second, stateful accessor call. R-Co's
  `Registry.last_failures` field only exists because Zig's
  `RegistryError!void` return type has no room to carry a payload alongside
  the error; Elixir's tagged-tuple return has no such constraint.
  """

  import Ecto.Query

  alias Letflow.Engine.VariableMerge
  alias Letflow.EventStore.Registry.{EventType, JsonSchema, ValidationFailure}
  alias Letflow.Repo
  alias Letflow.TenantProvisioning.Registration

  @doc """
  Registers a new event type version. `attrs` bundles `name`/`schema_version`/
  `json_schema`/`description` (string or atom keys, standard
  `Ecto.Changeset.cast/4` tolerance — matches every other `attrs`-taking
  function in this codebase); `tenant_id` resolves the physical schema this
  row is inserted into.

  Validates `attrs` shape first (no DB round-trip on a changeset failure),
  then enforces two DB-backed invariants in order: `schema_version` must be
  strictly greater than every existing version already registered for
  `name` (`{:error, :schema_version_not_monotonic}` otherwise — a
  Letflow-specific tightening beyond R-Co, see the design doc section 4.1's
  callout), and an exact `(name, schema_version)` collision is rejected as
  `{:error, :duplicate_event_type_version}` — both via an explicit
  pre-check and, as a race-safe backstop for concurrent registrations, the
  table's own unique index.
  """
  @spec register_type(attrs :: map(), tenant_id :: Ecto.UUID.t()) ::
          {:ok, EventType.t()}
          | {:error, :tenant_not_provisioned}
          | {:error, :tenant_schema_missing}
          | {:error, Ecto.Changeset.t()}
          | {:error, :duplicate_event_type_version}
          | {:error, :schema_version_not_monotonic}
          | {:error, term()}
  def register_type(attrs, tenant_id) do
    with {:ok, schema_name} <- resolve_schema_name(tenant_id) do
      case EventType.changeset(%EventType{}, attrs) do
        %Ecto.Changeset{valid?: true} = changeset ->
          insert_with_monotonicity_check(changeset, schema_name)

        %Ecto.Changeset{valid?: false} = changeset ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Validates a raw JSON-encoded payload string against `event_type`'s most
  recently registered schema version (there is no exact-version parameter
  by design, not omission — see the design doc section 4.2: validation
  always targets the most recently registered version, resolved via
  `getType`'s `ORDER BY schema_version DESC LIMIT 1` result).

  GH #2621: after the schema step passes, a new payload of the engine-only sys-variables event
  additionally goes through `Letflow.Engine.VariableMerge.check_sys_values/1` (strict key
  shapes and value types, at most 40 keys); a refusal is the same
  `{:payload_validation_failed, [...]}` envelope, constraints `sys_key_shape`,
  `sys_value_type`, `sys_values_count`, never echoing a value.

  PROVENANCE (historical, not current decision authority):
  `payload` is a raw, not-yet-decoded JSON string, matching this function's
  realistic caller — an HTTP request body before any decoding happens.
  Decoding failure, or a
  successfully-decoded non-object payload (JSON array/string/number/bool/
  null at the root) is reported the same way an ordinary schema violation
  is: `{:error, {:payload_validation_failed, [%ValidationFailure{field_path:
  "/", constraint: "type", actual: payload}]}}` — this is a platform-level
  invariant about event payload shape (payloads are always JSON objects),
  enforced here rather than inside `JsonSchema`, since it is a payload-shape
  invariant, not a schema-driven check — the same boundary
  `registry.zig`'s `validatePayloadAgainstSchema` draws against the generic,
  schema-driven `json_schema.zig`.
  """
  @spec validate_payload(
          event_type :: String.t(),
          payload :: String.t(),
          tenant_id :: Ecto.UUID.t()
        ) ::
          :ok
          | {:error, :tenant_not_provisioned}
          | {:error, :unknown_event_type}
          | {:error, {:payload_validation_failed, [ValidationFailure.t()]}}
          | {:error, term()}
  def validate_payload(event_type, payload, tenant_id) when is_binary(payload) do
    case decode_object_payload(payload) do
      {:error, failure} ->
        {:error, {:payload_validation_failed, [failure]}}

      {:ok, decoded} ->
        case get_type(event_type, tenant_id) do
          {:ok, %EventType{json_schema: schema}} ->
            case JsonSchema.validate(decoded, schema) do
              [] -> sys_values_guard(event_type, decoded)
              failures -> {:error, {:payload_validation_failed, failures}}
            end

          {:error, _reason} = error ->
            error
        end
    end
  end

  # GH #2621 (design D-2, D-9, D-10): a code guard, not a schema keyword (the JSON-Schema
  # subset ignores `patternProperties`, and a seed edit would not reach existing tenants).
  # Runs only after the schema step passed, and only for the engine-only
  # INSTANCE_SYS_VARIABLES_SET event, so it covers every append entry point with one
  # change. No failure echoes a value (`actual: nil`).
  defp sys_values_guard(event_type, decoded) do
    if event_type == VariableMerge.sys_event_type() do
      # Fail closed (INV-8): decode_object_payload/1 yields a map, but a non-map must never
      # raise here; it reads as a missing `values`, which is refused as a type failure.
      values = if is_map(decoded), do: Map.get(decoded, "values"), else: nil

      case VariableMerge.check_sys_values(values) do
        :ok ->
          :ok

        {:error, :not_a_map} ->
          {:error,
           {:payload_validation_failed,
            [%ValidationFailure{field_path: "/values", constraint: "type", actual: nil}]}}

        {:error, offending} ->
          {:error, {:payload_validation_failed, Enum.map(offending, &sys_failure/1)}}
      end
    else
      :ok
    end
  end

  defp sys_failure({:values, :too_many_keys}),
    do: %ValidationFailure{field_path: "/values", constraint: "sys_values_count", actual: nil}

  defp sys_failure({key, reason}) do
    %ValidationFailure{
      field_path: sys_failure_path(key),
      constraint: sys_constraint(reason),
      actual: nil
    }
  end

  defp sys_constraint(:invalid_sys_key_shape), do: "sys_key_shape"
  defp sys_constraint(:invalid_sys_value_type), do: "sys_value_type"

  # RFC 6901 escaping; an over-long or non-binary key is reported at "/values" only.
  defp sys_failure_path(key) when is_binary(key) and byte_size(key) <= 160 do
    escaped = key |> String.replace("~", "~0") |> String.replace("/", "~1")
    "/values/" <> escaped
  end

  defp sys_failure_path(_key), do: "/values"

  @doc """
  Fetches `event_type`'s most recently registered version (highest
  `schema_version`), scoped to `tenant_id`'s own schema. Returns
  `{:error, :unknown_event_type}` — never `nil`, never a raised exception —
  when no row exists for `event_type` under that schema.
  """
  @spec get_type(event_type :: String.t(), tenant_id :: Ecto.UUID.t()) ::
          {:ok, EventType.t()}
          | {:error, :tenant_not_provisioned}
          | {:error, :tenant_schema_missing}
          | {:error, :unknown_event_type}
          | {:error, term()}
  def get_type(event_type, tenant_id) do
    with {:ok, schema_name} <- resolve_schema_name(tenant_id) do
      rescue_missing_schema(fn ->
        EventType
        |> where([e], e.name == ^event_type)
        |> order_by([e], desc: e.schema_version)
        |> limit(1)
        |> Repo.one(prefix: schema_name)
        |> case do
          nil -> {:error, :unknown_event_type}
          %EventType{} = event_type -> {:ok, event_type}
        end
      end)
    end
  end

  @doc """
  The highest registered `schema_version` of `event_type` in the tenant schema `prefix`, or `nil`
  when none is registered (GH #2590 R4b: the engine refuses a handler completion whose tenant
  has not been replayed to the v2 schema of the instance "entity writes applied" event). One read, no lock.
  """
  @spec max_schema_version(event_type :: String.t(), prefix :: String.t()) ::
          pos_integer() | nil
  def max_schema_version(event_type, prefix) when is_binary(event_type) and is_binary(prefix) do
    EventType
    |> where([e], e.name == ^event_type)
    |> select([e], max(e.schema_version))
    |> Repo.one(prefix: prefix)
  end

  # Resolves tenant_id -> physical schema_name, or {:error, :tenant_not_provisioned}
  # if no Registration row exists yet. Both register_type/2 and get_type/2 call
  # this (validate_payload/3 does not -- it has no direct Repo call of its own,
  # and forwards tenant_id to get_type/2 instead, per this module's moduledoc).
  # This duplicates -- rather than reuses -- the exact lookup
  # Letflow.TenantProvisioning.replay_migrations/2 performs inline, because
  # Letflow.TenantProvisioning currently exposes no public function with this
  # standalone contract; extracting one would mean reaching into a sibling,
  # already-merged requirement's module beyond the one edit already anticipated
  # there (tenant_scoped_migrations/0). See design doc sections 4 and 7.3 --
  # left for REVIEWER to decide whether a future fast-follow should extract a
  # shared Letflow.TenantProvisioning function. Factored into one private
  # helper here (rather than inlined twice) purely to avoid literal duplicate
  # code within this module -- this is local to Registry and does not touch
  # TenantProvisioning, so it doesn't reopen that question.
  defp resolve_schema_name(tenant_id) do
    case Repo.get_by(Registration, tenant_id: tenant_id) do
      nil -> {:error, :tenant_not_provisioned}
      %Registration{schema_name: schema_name} -> {:ok, schema_name}
    end
  end

  # Narrow tolerance for a schema that vanished between resolve_schema_name/1
  # succeeding (a Registration row exists) and this query actually running
  # against it (ISS-0343: a concurrent teardown/offboarding race can drop the
  # physical schema in that window). Matches only the exact Postgrex.Error
  # shape %Postgrex.Error{postgres: %{code: :undefined_table}} -- confirmed
  # empirically (not assumed from the SQLSTATE 42P01 mnemonic) against this
  # project's test database that this is the atom Postgrex raises for a query
  # against a dropped schema/table. Any other exception is re-raised
  # unchanged -- this must stay a narrow, diagnosed-failure-mode rescue, not a
  # blanket one (see design doc section 2.2 and docs/anti-patterns.md).
  @spec rescue_missing_schema(fun :: (-> result)) ::
          result | {:error, :tenant_schema_missing}
        when result: var
  defp rescue_missing_schema(fun) do
    fun.()
  rescue
    e in Postgrex.Error ->
      case e do
        %Postgrex.Error{postgres: %{code: :undefined_table}} ->
          {:error, :tenant_schema_missing}

        _other ->
          reraise e, __STACKTRACE__
      end
  end

  # Ported from R-Co's isJsonObject pre-check + malformed-JSON fallback,
  # collapsed into one check since Jason.decode/1 already fully parses
  # (unlike Zig's cheap leading-byte peek).
  defp decode_object_payload(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, _not_an_object} ->
        {:error, %ValidationFailure{field_path: "/", constraint: "type", actual: payload}}

      {:error, _reason} ->
        {:error, %ValidationFailure{field_path: "/", constraint: "type", actual: payload}}
    end
  end

  # Steps 4-5 of register_type/2 (design doc section 4.1): a monotonicity
  # pre-check (Letflow-specific, no R-Co equivalent -- see the moduledoc/design
  # doc callout) followed by the insert, with the table's own unique index as
  # a race-safe backstop the pre-check alone can't fully close.
  defp insert_with_monotonicity_check(changeset, schema_name) do
    name = Ecto.Changeset.get_field(changeset, :name)
    version = Ecto.Changeset.get_field(changeset, :schema_version)

    with {:ok, current_max} <- fetch_current_max(name, schema_name) do
      cond do
        version < current_max ->
          {:error, :schema_version_not_monotonic}

        # Only reachable when current_max > 0 (schema_version is validated
        # > 0, so it can never equal a current_max of 0) -- an exact
        # (name, schema_version) collision, known before even attempting the
        # insert.
        version == current_max ->
          {:error, :duplicate_event_type_version}

        true ->
          rescue_missing_schema(fn ->
            case Repo.insert(changeset, prefix: schema_name) do
              {:ok, %EventType{} = event_type} ->
                {:ok, event_type}

              {:error, %Ecto.Changeset{} = failed_changeset} ->
                if unique_violation?(failed_changeset, :name) do
                  {:error, :duplicate_event_type_version}
                else
                  {:error, failed_changeset}
                end
            end
          end)
      end
    end
  end

  defp fetch_current_max(name, schema_name) do
    rescue_missing_schema(fn ->
      current_max =
        EventType
        |> where([e], e.name == ^name)
        |> select([e], max(e.schema_version))
        |> Repo.one(prefix: schema_name) || 0

      {:ok, current_max}
    end)
  end

  defp unique_violation?(%Ecto.Changeset{errors: errors}, field) do
    Enum.any?(errors, fn
      {^field, {_message, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end
end
