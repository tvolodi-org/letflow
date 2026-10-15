defmodule Letflow.EventStore do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Context module for `Store.append()` (ES-01/02/03/05/08/DB-03), implementing the
  append semantics specified in `src/event_store/store.zig`. See
  `lib/letflow/design/req025-event-append.md` for the full design this module
  implements; this moduledoc restates the four points that design's §7 requires
  to be stated here verbatim in substance.

  ## `tenant_id` is always derived, never accepted

  `tenant_id` is always derived from `opts[:prefix]` via
  `Letflow.TenantProvisioning.tenant_id_for_schema_name/1`, never accepted from
  `attrs`. `attrs` containing a `:tenant_id` (or `"tenant_id"`) key is a hard
  error, `{:error, :tenant_id_not_accepted}` — see
  `docs/migration/decisions/0003-ecto-schema-strategy.md`'s 2026-08-17
  addendum, which settles this mechanism project-wide (a caller-supplied
  `tenant_id` can disagree with the schema a row is physically written into,
  which is the attribution defect that addendum exists to close).

  ## `event_id`/`created_at` are minted exactly once

  PROVENANCE (historical, not current decision authority):
  `event_id`/`created_at` are minted exactly once per `append/2` call and bound
  identically into `events`, `event_idempotency`, and (only when the payload is
  oversized) `event_payload_store` — design invariant INV-EV-5. R-Co shipped and
  then fixed the exact bug this prevents: two independent `gen_random_uuid()`
  evaluations orphaning the idempotency sidecar row from the event it points at
  (`store.zig:623-636`, quoted via `req023-event-store-schema.md`).

  ## Registry and metadata validation run before the transaction opens

  Registry validation (`Letflow.EventStore.Registry.validate_payload/3`) and
  metadata validation both complete, with zero DB writes attempted anywhere,
  **before** `Repo.transaction/2` is ever called — not merely as the first
  `Ecto.Multi` step. This is a deliberate reading of invariant 8's "zero rows
  written on failure" as literally as invariant 9's explicit "before the
  transaction opens" (see the design doc §6.1 for the full reasoning:
  avoiding `instance_sequence`'s hot row lock for a call already known to
  fail, and symmetry with metadata validation's own stated principle). Flagged
  there as this design's own interpretation, not a literal quotation of the
  unreachable `event_store.md` "append" section — re-verify against that
  primary source if it ever becomes reachable again.

  ## `instance_sequence` and `event_idempotency` carry no `tenant_id` column

  Unlike `events` and `instance_projections`, `instance_sequence` and
  `event_idempotency` carry **no** `tenant_id` column at all (confirmed
  directly against both the Ecto schema modules and the migration DDL — design
  doc §0/§9 OQ-1). Tenant isolation for those two tables' rows is enforced
  entirely by the Postgres schema (`:prefix`) boundary they are written into,
  not by a column value. This is a known requirement-text/shipped-schema
  mismatch against REQ-025's acceptance criterion 6 — reported to REVIEWER,
  not silently resolved by adding a column REQ-023's own design explicitly
  warns against completing.

  ## Every platform event in a tenant shares one `instance_sequence` row (REQ-140)

  `append_platform_event/2` (below) always writes under `platform_instance_id/0`,
  never any other `instance_id`. That means every platform-scoped event appended
  for a given tenant shares the *same* `instance_sequence` row for that sentinel
  — and therefore the same `FOR UPDATE` lock `lock_and_increment_sequence/3`
  takes on it (M2, reused verbatim from `append/2`). This is a real per-tenant
  serialization point across **every** platform write in that tenant's schema,
  not just the three promotion event types REQ-140 wires up — correct, and fine
  at current traffic volumes (a handful of low-frequency promotion-pipeline
  event types), but a capacity property worth having on record here rather
  than rediscovered the first time platform-event volume grows.

  ## Scope

  `append/2` (REQ-025) and `read/2`/`read_global/1`/`point_in_time/3`/
  `archive/1` plus the three platform sentinel accessors (REQ-026) all live
  here — see `lib/letflow/design/req026-event-read-archive-platform-sentinels.md`
  for the design the latter group implements. Meaningful, engine-driven
  population of `instance_projections`' engine-owned columns (`definition_id`,
  `current_nodes`, ...) belongs to EE-01/S3 — `append/2` never originates an
  `instance_projections` row; it only ever advances the `last_event_seq` of a
  row that already exists (REVIEWER's Step 2d OQ-5 ruling; design doc §6.2.1,
  §6.2.6, §9 OQ-5). A missing row fails the whole call with
  `{:error, :instance_not_started}` instead.

  ## `tenant_id_for_schema_name/1`'s actual error shape (REQ-026 note)

  REQ-026's own design doc (§4.1/§7) describes `read/2`/`read_global/1`/
  `archive/1`'s tenant-resolution step as producing
  `{:error, :tenant_not_provisioned}` on an invalid `prefix`. That is not
  what `Letflow.TenantProvisioning.tenant_id_for_schema_name/1` actually
  returns — confirmed directly against its shipped `@spec` and body
  (`lib/letflow/tenant_provisioning.ex:100-115`): it is a pure,
  no-I/O reversal of `schema_name_for_tenant/1`'s string encoding, and its
  own moduledoc states it "deliberately does **not** confirm the tenant is
  actually provisioned." Its only failure case is
  `{:error, :invalid_schema_name}`, for any input not shaped like
  `"tenant_" <> <32 lowercase hex>`. `append/2`'s own `@type append_error`
  already carries this same latent mismatch (`:tenant_not_provisioned` is
  declared but never produced by its one call to this function). REQ-026's
  functions below match the function's *actual* behavior —
  `{:error, :invalid_schema_name}` — rather than the design doc's stated
  atom, the same "flagged, not silently patched over" divergence this
  project's convention requires (see REQ-026's implementation handoff).
  """

  import Ecto.Query

  alias Ecto.Multi

  alias Letflow.EventStore.{
    ArchivedEvent,
    Event,
    IdempotencyRecord,
    InstanceProjection,
    InstanceSequence,
    RetentionPolicy,
    StoredPayload
  }

  alias Letflow.Api.Pagination
  alias Letflow.EventStore.Registry
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @payload_inline_max_bytes 4096
  @idempotency_key_max_length 255
  @metadata_max_entries 50
  @metadata_key_max_length 128
  @metadata_value_max_length 1024

  # GH #2587 / REQ-499 (design gh2587-req499-pr-a-prerequisites.md D-A2.16, I-5): the
  # server step-key family. Every un-namespaced entry point refuses it; only a namespaced
  # append_multi/3 (whose one caller is Letflow.Entities.Records, static test
  # command_multi_callers_test.exs) accepts it. Same bytes as
  # Letflow.Entities.Records.step_key_prefix/0, which cannot be called from here (the event
  # store does not depend on the entities context); a test pins the two equal.
  @reserved_step_key_prefix "sys:step:"

  @typedoc """
  GH #2587: the `append_multi/3` option that names every added step `{:line, i, step}`
  instead of the bare `step` atom, so several appends compose into one Multi.
  """
  @type step_namespace :: {:line, non_neg_integer()}

  @type append_attrs :: %{
          required(:instance_id) => Ecto.UUID.t(),
          required(:event_type) => String.t(),
          required(:payload) => String.t(),
          required(:actor_id) => Ecto.UUID.t(),
          required(:idempotency_key) => String.t(),
          optional(:metadata) => %{optional(String.t()) => String.t()}
        }

  @type metadata_violation ::
          :not_a_map
          | :too_many_entries
          | {:non_string_key, key :: term()}
          | {:key_too_long, key :: String.t()}
          | {:value_too_long, key :: String.t()}
          | {:non_string_value, key :: String.t()}

  @type append_error ::
          {:error, :tenant_id_not_accepted}
          | {:error, :invalid_schema_name}
          | {:error, :missing_instance_id}
          | {:error, :missing_actor_id}
          | {:error, :missing_payload}
          | {:error, :invalid_payload}
          | {:error, :missing_event_type}
          | {:error, :missing_idempotency_key}
          | {:error, :idempotency_key_too_long}
          | {:error, :reserved_idempotency_key}
          | {:error, {:invalid_metadata, metadata_violation()}}
          | {:error, :tenant_not_provisioned}
          | {:error, :unknown_event_type}
          | {:error, {:payload_validation_failed, [Registry.ValidationFailure.t()]}}
          | {:error, :instance_not_started}
          | {:error, {:instance_terminated, :completed | :cancelled}}
          | {:error, {:sequence_conflict, term()}}
          | {:error, Ecto.Changeset.t()}
          | {:error, term()}

  @type append_result :: %{
          event: Event.t(),
          is_duplicate: boolean(),
          sequence_number: pos_integer(),
          global_seq: pos_integer()
        }

  @type append_platform_attrs :: %{
          required(:instance_id) => Ecto.UUID.t(),
          required(:event_type) => String.t(),
          required(:payload) => String.t(),
          required(:actor_id) => Ecto.UUID.t(),
          required(:idempotency_key) => String.t(),
          optional(:metadata) => %{optional(String.t()) => String.t()}
        }

  @type append_platform_error ::
          {:error, :tenant_id_not_accepted}
          | {:error, :invalid_schema_name}
          | {:error, :not_platform_instance_id}
          | {:error, :missing_instance_id}
          | {:error, :missing_actor_id}
          | {:error, :missing_payload}
          | {:error, :invalid_payload}
          | {:error, :missing_event_type}
          | {:error, :missing_idempotency_key}
          | {:error, :idempotency_key_too_long}
          | {:error, :reserved_idempotency_key}
          | {:error, {:invalid_metadata, metadata_violation()}}
          | {:error, :unknown_event_type}
          | {:error, {:payload_validation_failed, [Registry.ValidationFailure.t()]}}
          | {:error, {:sequence_conflict, term()}}
          | {:error, Ecto.Changeset.t()}
          | {:error, term()}

  @doc """
  Appends one event to `attrs[:instance_id]`'s stream, inside the tenant
  schema named by `opts[:prefix]`. `opts`'s only required key is `:prefix` —
  the tenant's physical Postgres schema name — matching every other
  event-store schema module's `prefix:`-at-call-time contract (INV-EV-8).

  `attrs` never accepts a `:tenant_id` key (see this module's moduledoc);
  `tenant_id` is always derived from `opts[:prefix]`.

  On a fresh append, returns the inserted `events` row with
  `is_duplicate: false`. On a call reusing an already-claimed
  `idempotency_key`, returns the **original** row from the first successful
  append with `is_duplicate: true` — zero net rows change anywhere on that
  path. See `lib/letflow/design/req025-event-append.md` for the full
  behavior, error taxonomy, and locking protocol this implements.

  GH #2587 (D-A2.16): an `idempotency_key` starting `"sys:step:"` is refused with
  `{:error, :reserved_idempotency_key}` before any query; that family is written only
  through a namespaced `append_multi/3`.
  """
  @spec append(attrs :: append_attrs(), opts :: [prefix: String.t()]) ::
          {:ok, append_result()} | append_error()
  def append(attrs, opts) when is_map(attrs) and is_list(opts) do
    prefix = Keyword.get(opts, :prefix)

    with :ok <- reject_tenant_id(attrs),
         {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, instance_id} <- fetch_uuid(attrs, :instance_id, :missing_instance_id),
         {:ok, actor_id} <- fetch_uuid(attrs, :actor_id, :missing_actor_id),
         {:ok, payload} <- fetch_payload(attrs),
         {:ok, idempotency_key} <- fetch_idempotency_key(attrs),
         :ok <- reject_step_key(idempotency_key, nil),
         {:ok, event_type} <- fetch_event_type(attrs),
         {:ok, metadata} <- validate_metadata(Map.get(attrs, :metadata) || %{}),
         :ok <- Registry.validate_payload(event_type, payload, tenant_id) do
      ctx = %{
        schema_name: prefix,
        tenant_id: tenant_id,
        instance_id: instance_id,
        event_type: event_type,
        actor_id: actor_id,
        idempotency_key: idempotency_key,
        metadata: metadata,
        payload_bytes: byte_size(payload),
        # Safe unconditionally: Registry.validate_payload/3 (above) already
        # proved `payload` decodes to a JSON object.
        decoded_payload: Jason.decode!(payload),
        event_id: Ecto.UUID.generate(),
        created_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      }

      # REQ-194 (design req194-prometheus-metrics.md §7, OBS-02 family 3): wraps the
      # existing Repo.transaction/2 call in :telemetry.span/3, event prefix
      # [:letflow, :event_store, :append] -- :telemetry.span/3 automatically emits
      # :start, then :stop (with a :duration measurement it computes itself) or
      # :exception on the wrapped function's return/raise. The metrics registry
      # module attaches to [:letflow, :event_store, :append, :stop] for the
      # letflow_event_append_duration_seconds histogram. Preserves append/2's
      # existing {:ok, _}/{:error, _} return contract exactly -- span/3 re-raises/
      # returns the wrapped function's own result unchanged. This is the ONLY call
      # site referencing this event prefix -- never the registry module directly
      # (AC8: a grep for that module's fully-qualified name over this file's real
      # code must return zero hits).
      :telemetry.span([:letflow, :event_store, :append], %{}, fn ->
        result =
          ctx
          |> build_multi()
          |> Repo.transaction()
          |> interpret_transaction_result()

        {result, %{}}
      end)
    end
  end

  @doc """
  REQ-228 §3.1 — appends one `Multi.run/3` step sequence onto `multi`,
  a caller-supplied, still-open `Ecto.Multi`, WITHOUT opening or committing
  its own `Repo.transaction/1` call. Structurally mirrors
  `Letflow.Engine.TaskActivation.append_multi/6`'s "append onto a
  caller-supplied Multi" idiom.

  Factors the *same* M1-M6 steps `append/2` runs internally
  (`active_instance_guard`, `assign_sequence`, `idempotency`, `insert_event`,
  optionally `store_oversized_payload`, `update_projection`) — reused
  verbatim via `build_multi_composable/2`, not duplicated — onto the given
  `multi`. `append/2` and `append_platform_event/2` are left completely
  unmodified; every existing caller of either is unaffected.

  Runs the exact same pre-transaction validation phase `append/2` runs
  (P0-P6: reject a caller-supplied `tenant_id`, resolve the tenant schema,
  fetch/validate `attrs`' fields, run `Registry.validate_payload/3`) before
  ever touching `multi` — a validation failure here returns the matching
  `append_error()` tuple with `multi` left completely untouched (no step
  added), the same "zero DB writes attempted" discipline `append/2` itself
  documents.

  The caller is responsible for calling `Repo.transaction/1` on the returned
  `Ecto.Multi.t()` exactly once, and for interpreting the transaction result
  itself — the Multi step names/error tuple shapes are byte-identical to
  `append/2`'s own (`:active_instance_guard`, `:assign_sequence`,
  `:idempotency`, `:insert_event`, `:update_projection`, and
  `{:error, :idempotency, {:duplicate_idempotency_key, %Event{}}, _changes}`
  on a duplicate submission), so a caller pattern-matches on the same shapes
  `interpret_transaction_result/1` does, rather than a parallel taxonomy
  being invented here.

  ## `:step_namespace` (GH #2587, decision 0054 D2.1)

  Absent, the Multi is exactly the one described above. `step_namespace:
  {:line, i}` (`i` a non-negative integer) names every added step
  `{:line, i, step}` (`{:line, i, :active_instance_guard}` ...
  `{:line, i, :update_projection}`), so several appends compose into one Multi
  without a duplicate-name raise; each step reads its siblings through a view
  of `changes` holding only this namespace's entries, keyed by the bare step
  atom. Any other value returns `{:error, :invalid_step_namespace}` before any
  other check, with `multi` untouched. The option is deliberately not
  `:prefix`, which already names the tenant schema (INV-1).

  An `idempotency_key` starting `"sys:step:"` is refused with
  `{:error, :reserved_idempotency_key}` unless `:step_namespace` is set
  (D-A2.16): the only `:step_namespace` user is `Letflow.Entities.Records`
  (static rule, `test/letflow/entities/command_multi_callers_test.exs`).
  """
  @spec append_multi(
          multi :: Ecto.Multi.t(),
          attrs :: append_attrs(),
          opts :: [prefix: String.t(), step_namespace: step_namespace()]
        ) ::
          {:ok, Ecto.Multi.t()} | append_error() | {:error, :invalid_step_namespace}
  def append_multi(%Multi{} = multi, attrs, opts) when is_map(attrs) and is_list(opts) do
    prefix = Keyword.get(opts, :prefix)

    with {:ok, namespace} <- fetch_step_namespace(opts),
         :ok <- reject_tenant_id(attrs),
         {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, instance_id} <- fetch_uuid(attrs, :instance_id, :missing_instance_id),
         {:ok, actor_id} <- fetch_uuid(attrs, :actor_id, :missing_actor_id),
         {:ok, payload} <- fetch_payload(attrs),
         {:ok, idempotency_key} <- fetch_idempotency_key(attrs),
         :ok <- reject_step_key(idempotency_key, namespace),
         {:ok, event_type} <- fetch_event_type(attrs),
         {:ok, metadata} <- validate_metadata(Map.get(attrs, :metadata) || %{}),
         :ok <- Registry.validate_payload(event_type, payload, tenant_id) do
      ctx = %{
        schema_name: prefix,
        tenant_id: tenant_id,
        instance_id: instance_id,
        event_type: event_type,
        actor_id: actor_id,
        idempotency_key: idempotency_key,
        metadata: metadata,
        payload_bytes: byte_size(payload),
        # Safe unconditionally: Registry.validate_payload/3 (above) already
        # proved `payload` decodes to a JSON object.
        decoded_payload: Jason.decode!(payload),
        event_id: Ecto.UUID.generate(),
        created_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      }

      {:ok, build_multi_composable(multi, ctx, namespace)}
    end
  end

  @doc """
  Sibling of `append/2` (REQ-140), restricted to `platform_instance_id/0`.
  Skips M1 (`active_instance_guard/3`) and M6 (`update_projection/3`) --
  no `instance_projections` row ever exists for the platform sentinel, so
  both steps are structurally inapplicable, not merely optional. Reuses M2
  `assign_sequence/3`, M3 `claim_idempotency/3`, and M4 `insert_event/3`
  verbatim -- same locking/idempotency/insert protocol `append/2` itself
  relies on, now against the sentinel's own `instance_sequence` row (see
  this module's moduledoc, "Every platform event in a tenant shares one
  `instance_sequence` row").

  `attrs[:instance_id]` MUST equal `platform_instance_id/0` --
  `{:error, :not_platform_instance_id}` for any other value (a random UUID
  or a real started instance's id alike), before any query runs.

  See `lib/letflow/design/req140-platform-event-append-path.md` §3 for the
  full design.

  GH #2587 (D-A2.16): an `idempotency_key` starting `"sys:step:"` is refused
  with `{:error, :reserved_idempotency_key}` before any query.
  """
  @spec append_platform_event(attrs :: append_platform_attrs(), opts :: [prefix: String.t()]) ::
          {:ok, append_result()} | append_platform_error()
  def append_platform_event(attrs, opts) when is_map(attrs) and is_list(opts) do
    prefix = Keyword.get(opts, :prefix)

    with :ok <- reject_tenant_id(attrs),
         {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, instance_id} <- fetch_platform_instance_id(attrs),
         {:ok, actor_id} <- fetch_uuid(attrs, :actor_id, :missing_actor_id),
         {:ok, payload} <- fetch_payload(attrs),
         {:ok, idempotency_key} <- fetch_idempotency_key(attrs),
         :ok <- reject_step_key(idempotency_key, nil),
         {:ok, event_type} <- fetch_event_type(attrs),
         {:ok, metadata} <- validate_metadata(Map.get(attrs, :metadata) || %{}),
         :ok <- Registry.validate_payload(event_type, payload, tenant_id) do
      ctx = %{
        schema_name: prefix,
        tenant_id: tenant_id,
        instance_id: instance_id,
        event_type: event_type,
        actor_id: actor_id,
        idempotency_key: idempotency_key,
        metadata: metadata,
        payload_bytes: byte_size(payload),
        # Safe unconditionally: Registry.validate_payload/3 (above) already
        # proved `payload` decodes to a JSON object.
        decoded_payload: Jason.decode!(payload),
        event_id: Ecto.UUID.generate(),
        created_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      }

      ctx
      |> build_multi_platform()
      |> Repo.transaction()
      |> interpret_transaction_result()
    end
  end

  # REQ-140 §3.4 -- composes with, rather than duplicates, fetch_uuid/3: the
  # missing/malformed-UUID handling is identical to every other fetch_uuid/3
  # call site. Only on a structurally valid UUID does this compare it against
  # platform_instance_id/0 -- equal -> {:ok, instance_id}, anything else
  # (including a real started instance's id) -> {:error,
  # :not_platform_instance_id}, before any query runs. Matches this module's
  # "structural checks fail with zero DB writes" discipline (reject_tenant_id/1
  # is the precedent this mirrors).
  defp fetch_platform_instance_id(attrs) do
    with {:ok, instance_id} <- fetch_uuid(attrs, :instance_id, :missing_instance_id) do
      if instance_id == platform_instance_id() do
        {:ok, instance_id}
      else
        {:error, :not_platform_instance_id}
      end
    end
  end

  # ---------------------------------------------------------------------
  # Pre-transaction phase (design doc §6.1, P0-P6) -- pure or read-only,
  # zero writes attempted before Repo.transaction/2 below is ever called.
  # ---------------------------------------------------------------------

  defp reject_tenant_id(attrs) do
    if Map.has_key?(attrs, :tenant_id) or Map.has_key?(attrs, "tenant_id") do
      {:error, :tenant_id_not_accepted}
    else
      :ok
    end
  end

  defp fetch_uuid(attrs, key, error_reason) do
    case Map.get(attrs, key) do
      nil ->
        {:error, error_reason}

      value ->
        case Ecto.UUID.cast(value) do
          {:ok, uuid} -> {:ok, uuid}
          :error -> {:error, error_reason}
        end
    end
  end

  defp fetch_payload(attrs) do
    case Map.get(attrs, :payload) do
      payload when is_binary(payload) and byte_size(payload) > 0 -> {:ok, payload}
      _ -> {:error, :missing_payload}
    end
  end

  defp fetch_idempotency_key(attrs) do
    case Map.get(attrs, :idempotency_key) do
      key when is_binary(key) and byte_size(key) > 0 ->
        if String.length(key) > @idempotency_key_max_length do
          {:error, :idempotency_key_too_long}
        else
          {:ok, key}
        end

      _ ->
        {:error, :missing_idempotency_key}
    end
  end

  # GH #2587 (design 3.1): absent -> nil (today's Multi); {:line, i} with a non-negative
  # integer i -> that namespace; any other value, nil included, is refused before any other
  # check so the caller's Multi is never touched.
  @spec fetch_step_namespace(keyword()) ::
          {:ok, step_namespace() | nil} | {:error, :invalid_step_namespace}
  defp fetch_step_namespace(opts) do
    case Keyword.fetch(opts, :step_namespace) do
      :error -> {:ok, nil}
      {:ok, {:line, i} = namespace} when is_integer(i) and i >= 0 -> {:ok, namespace}
      {:ok, _other} -> {:error, :invalid_step_namespace}
    end
  end

  # GH #2587 D-A2.16 (I-5): exact bytes, so "SYS:STEP:x" is an ordinary key.
  @spec reject_step_key(String.t(), step_namespace() | nil) ::
          :ok | {:error, :reserved_idempotency_key}
  defp reject_step_key(@reserved_step_key_prefix <> _rest, nil),
    do: {:error, :reserved_idempotency_key}

  defp reject_step_key(_key, _namespace), do: :ok

  # Design doc §6.1 P2/§9 OQ-4 deliberately leaves `event_type`'s structural check
  # out of the pre-transaction phase, on the stated premise that a missing/malformed
  # `event_type` would surface later via `Event.insert_changeset/2`'s ordinary
  # `%Ecto.Changeset{}` path at Multi step M4. That premise doesn't hold: P4
  # (`Registry.validate_payload/3`, right below) runs *before* the `Multi`/M4 ever
  # starts and passes `event_type` straight into an `Ecto.Query` `where` comparison
  # (`Letflow.EventStore.Registry.get_type/2`) — a non-binary value there raises
  # `Ecto.Query.CastError` (or `ArgumentError` for `nil`), not a typed error, which is
  # the exact INV-8 class of bug this rework iteration exists to close, confirmed
  # empirically (a throwaway `mix run` against real Postgres: `event_type: nil` ->
  # `ArgumentError`, `event_type: :an_atom` / `123` -> `Ecto.Query.CastError`). Guarded
  # here instead, matching every other structural field's shape (`:missing_event_type`,
  # symmetric with `:missing_instance_id`/`:missing_actor_id`/`:missing_payload`)
  # rather than leaving OQ-4's now-disproven deferral in place. Flagged for REVIEWER at
  # Step 2d as a deliberate, reasoned divergence from the design doc's literal OQ-4
  # text, not a silent re-decision.
  defp fetch_event_type(attrs) do
    case Map.get(attrs, :event_type) do
      event_type when is_binary(event_type) and byte_size(event_type) > 0 -> {:ok, event_type}
      _ -> {:error, :missing_event_type}
    end
  end

  # `is_map/1` alone is never sufficient to mean "plain map" -- a struct IS a
  # map under the hood (`is_map/1` returns `true` for e.g. `DateTime.utc_now()`,
  # `URI.parse/1`'s result, `MapSet.new/1`, or a `Range` literal like `1..5`),
  # so the guard must explicitly reject `is_struct/1` too. Structs either have
  # no `Enumerable` impl at all (raising `Protocol.UndefinedError` from the
  # `Enum.find_value/3` below) or iterate as bare elements rather than
  # `{key, value}` tuples (raising `FunctionClauseError` inside this
  # function's own anonymous function) -- both are the same INV-8 class of
  # bug as a non-map value, just a shape the first rework iteration's guard
  # didn't anticipate. Confirmed empirically for all four cases -- see this
  # handoff's regression check.
  defp validate_metadata(metadata) when not is_map(metadata) or is_struct(metadata) do
    {:error, {:invalid_metadata, :not_a_map}}
  end

  defp validate_metadata(metadata) when map_size(metadata) > @metadata_max_entries do
    {:error, {:invalid_metadata, :too_many_entries}}
  end

  defp validate_metadata(metadata) do
    Enum.find_value(metadata, {:ok, metadata}, fn {key, value} ->
      cond do
        not is_binary(key) ->
          {:error, {:invalid_metadata, {:non_string_key, key}}}

        String.length(key) > @metadata_key_max_length ->
          {:error, {:invalid_metadata, {:key_too_long, key}}}

        not is_binary(value) ->
          {:error, {:invalid_metadata, {:non_string_value, key}}}

        String.length(value) > @metadata_value_max_length ->
          {:error, {:invalid_metadata, {:value_too_long, key}}}

        true ->
          nil
      end
    end)
  end

  # ---------------------------------------------------------------------
  # Transactional phase (design doc §6.2) -- one Ecto.Multi,
  # prefix: schema_name on every operation.
  # ---------------------------------------------------------------------

  defp build_multi(ctx), do: build_multi_composable(Multi.new(), ctx, nil)

  # REQ-228 §3.1 -- the composable core `append/2`'s own build_multi/1 and
  # append_multi/3 (public, above) both call, so the M1/M2/M3/M4/M5(?)/M6
  # step sequence exists in exactly one place. Appends onto whatever `multi`
  # it is given -- `Multi.new()` for `append/2`'s own internal use,
  # or a caller-supplied, still-open `Multi` for `append_multi/3`.
  #
  # GH #2587: `namespace` nil keeps today's step names; `{:line, i}` names each step
  # `{:line, i, step}` and hands it the namespace-local view of `changes` (run_step/4), so
  # the step functions below keep their fixed-key heads unchanged.
  defp build_multi_composable(multi, ctx, namespace) do
    multi
    |> run_step(namespace, :active_instance_guard, fn repo, changes ->
      active_instance_guard(repo, changes, ctx)
    end)
    |> run_step(namespace, :assign_sequence, fn repo, changes ->
      assign_sequence(repo, changes, ctx)
    end)
    |> run_step(namespace, :idempotency, fn repo, changes ->
      claim_idempotency(repo, changes, ctx)
    end)
    |> run_step(namespace, :insert_event, fn repo, changes -> insert_event(repo, changes, ctx) end)
    |> maybe_store_oversized_payload(ctx, namespace)
    |> run_step(namespace, :update_projection, fn repo, changes ->
      update_projection(repo, changes, ctx)
    end)
  end

  @spec run_step(
          Ecto.Multi.t(),
          step_namespace() | nil,
          atom(),
          (Ecto.Repo.t(), map() -> {:ok, term()} | {:error, term()})
        ) :: Ecto.Multi.t()
  defp run_step(multi, nil, step, fun), do: Multi.run(multi, step, fun)

  defp run_step(multi, {:line, i}, step, fun) do
    Multi.run(multi, {:line, i, step}, fn repo, changes ->
      fun.(repo, namespace_changes(changes, i))
    end)
  end

  # Only this line's entries, keyed by the bare step atom.
  defp namespace_changes(changes, i) do
    for {{:line, ^i, step}, value} <- changes, into: %{}, do: {step, value}
  end

  defp maybe_store_oversized_payload(multi, ctx, namespace \\ nil)

  defp maybe_store_oversized_payload(multi, %{payload_bytes: payload_bytes} = ctx, namespace)
       when payload_bytes > @payload_inline_max_bytes do
    run_step(multi, namespace, :store_oversized_payload, fn repo, changes ->
      store_oversized_payload(repo, changes, ctx)
    end)
  end

  defp maybe_store_oversized_payload(multi, _ctx, _namespace), do: multi

  # REQ-140 §3.5 -- the platform-scoped Multi. M1 (active_instance_guard) and
  # M6 (update_projection) are omitted -- not stubbed, not made conditional,
  # simply never added: no instance_projections row ever exists for the
  # platform sentinel, so both are structurally inapplicable, not a judgement
  # call. M2/M3/M4 are the exact same call shape as build_multi/1's own steps
  # (same private functions, reused verbatim). M5 (maybe_store_oversized_payload/2)
  # stays in for structural symmetry with append/2 -- it is unconditional on
  # instance_projections (a pure function of ctx's payload_bytes/decoded_payload
  # plus the just-inserted events row), so including it costs nothing and
  # avoids a latent gap if a platform payload ever grows past the inline
  # threshold.
  defp build_multi_platform(ctx) do
    Multi.new()
    |> Multi.run(:assign_sequence, fn repo, changes -> assign_sequence(repo, changes, ctx) end)
    |> Multi.run(:idempotency, fn repo, changes -> claim_idempotency(repo, changes, ctx) end)
    |> Multi.run(:insert_event, fn repo, changes -> insert_event(repo, changes, ctx) end)
    |> maybe_store_oversized_payload(ctx)
  end

  # M1 -- active-instance guard (invariant 10, ES-01). A plain, unlocked read
  # (design doc §6.2.1 -- a stronger guarantee, e.g. locking
  # instance_projections for the append's duration, is design doc OQ-6, not
  # built here). Update-only per REVIEWER's Step 2d OQ-5 ruling: append/2
  # never originates an instance_projections row. No row found is a hard
  # failure, {:error, :instance_not_started} -- a DISTINCT case from
  # :instance_terminated below, not an implicit new/active instance. On
  # success, the actual %InstanceProjection{} struct is returned (not a bare
  # atom) so M6 (update_projection/3) can read its current `status` back via
  # `changes.active_instance_guard` and thread it, unchanged, into
  # InstanceProjection.update_changeset/2 without a second DB read.
  defp active_instance_guard(repo, _changes, %{instance_id: instance_id, schema_name: schema_name}) do
    case repo.get(InstanceProjection, instance_id, prefix: schema_name) do
      nil ->
        {:error, :instance_not_started}

      %InstanceProjection{status: status} = projection ->
        if InstanceProjection.terminal?(status) do
          {:error, {:instance_terminated, status}}
        else
          {:ok, projection}
        end
    end
  end

  # M2 -- sequence assignment: the FOR-UPDATE-equivalent locking protocol
  # (invariant 2/4, ES-02, design doc §6.2.2). Three sub-steps: (i)
  # insert-if-absent (on_conflict: :nothing keyed on instance_id -- one
  # atomic statement, not a racy existence-check-then-insert), (ii) a row-lock
  # read (Ecto's `lock: "FOR UPDATE"` query composition, per INV-7 -- never a
  # hand-written SQL string), (iii) increment under the still-held lock.
  defp assign_sequence(repo, _changes, %{instance_id: instance_id, schema_name: schema_name}) do
    insert_changeset =
      InstanceSequence.insert_changeset(%InstanceSequence{}, %{instance_id: instance_id})

    case repo.insert(insert_changeset,
           on_conflict: :nothing,
           conflict_target: :instance_id,
           prefix: schema_name
         ) do
      {:ok, _} -> lock_and_increment_sequence(repo, instance_id, schema_name)
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp lock_and_increment_sequence(repo, instance_id, schema_name) do
    locked =
      InstanceSequence
      |> where([s], s.instance_id == ^instance_id)
      |> lock("FOR UPDATE")
      |> repo.one(prefix: schema_name)

    case locked do
      nil ->
        {:error, {:sequence_conflict, :row_missing_after_insert}}

      %InstanceSequence{next_seq: assigned_sequence_number} ->
        InstanceSequence
        |> where([s], s.instance_id == ^instance_id)
        |> repo.update_all([set: [next_seq: assigned_sequence_number + 1]], prefix: schema_name)
        |> case do
          {1, _} -> {:ok, assigned_sequence_number}
          _ -> {:error, {:sequence_conflict, :unexpected_update_count}}
        end
    end
  end

  # M3 -- idempotency check/insert (invariant 4, ES-03, design doc §6.2.3).
  # Reuses the "attempt an insert, then re-select to disambiguate outcome"
  # idiom already shipped in
  # Letflow.TenantProvisioning.insert_or_fetch_registration/2: `id` is
  # client-generated (well, Ecto-client-side autogenerated) via `binary_id`,
  # so a bare {:ok, struct} from an on_conflict: :nothing insert can't by
  # itself distinguish "really inserted" from "suppressed".
  defp claim_idempotency(repo, _changes, %{
         idempotency_key: idempotency_key,
         event_id: event_id,
         created_at: created_at,
         schema_name: schema_name
       }) do
    changeset =
      IdempotencyRecord.insert_changeset(%IdempotencyRecord{}, %{
        idempotency_key: idempotency_key,
        event_id: event_id,
        event_created_at: created_at
      })

    case repo.insert(changeset,
           on_conflict: :nothing,
           conflict_target: :idempotency_key,
           prefix: schema_name
         ) do
      {:ok, %IdempotencyRecord{id: attempted_id}} ->
        case repo.get(IdempotencyRecord, attempted_id, prefix: schema_name) do
          %IdempotencyRecord{} = claimed -> {:ok, {:claimed, claimed}}
          nil -> resolve_duplicate(repo, idempotency_key, schema_name)
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp resolve_duplicate(repo, idempotency_key, schema_name) do
    case repo.get_by(IdempotencyRecord, [idempotency_key: idempotency_key], prefix: schema_name) do
      nil ->
        {:error, {:idempotency_lookup_failed, :sidecar_row_missing}}

      %IdempotencyRecord{event_id: event_id, event_created_at: event_created_at} ->
        Event
        |> where([e], e.event_id == ^event_id and e.created_at == ^event_created_at)
        |> repo.one(prefix: schema_name)
        |> case do
          nil -> {:error, {:idempotency_lookup_failed, :original_event_missing}}
          %Event{} = original_event -> {:error, {:duplicate_idempotency_key, original_event}}
        end
    end
  end

  # M4 -- insert the `events` row (invariant 5/7, ES-01/02/03/05/08, design
  # doc §6.2.4). event_id/created_at come from ctx (minted once, P6);
  # sequence_number comes from M2's result; tenant_id comes from ctx's
  # derived value -- never anything attrs-supplied.
  # Post-Decision-0006-D2 (REQ-064): ctx's tenant_id key is destructured as
  # _tenant_id (not used) -- events.tenant_id no longer exists as a column, so
  # this function no longer stamps it into attrs below. See build_multi/1 and
  # append/2 for why ctx itself still carries the key (left as harmless dead
  # data, design decision, not restructured).
  defp insert_event(repo, %{assign_sequence: assigned_sequence_number}, %{
         event_id: event_id,
         created_at: created_at,
         instance_id: instance_id,
         event_type: event_type,
         actor_id: actor_id,
         idempotency_key: idempotency_key,
         metadata: metadata,
         tenant_id: _tenant_id,
         schema_name: schema_name,
         payload_bytes: payload_bytes,
         decoded_payload: decoded_payload
       }) do
    payload_field =
      if payload_bytes <= @payload_inline_max_bytes do
        decoded_payload
      else
        %{"$ref" => event_id}
      end

    attrs = %{
      event_id: event_id,
      created_at: created_at,
      instance_id: instance_id,
      event_type: event_type,
      payload: payload_field,
      actor_id: actor_id,
      sequence_number: assigned_sequence_number,
      idempotency_key: idempotency_key,
      metadata: metadata
    }

    %Event{}
    |> Event.insert_changeset(attrs)
    |> repo.insert(prefix: schema_name)
  end

  # M5 -- store the oversized payload (invariant 7, design doc §6.2.5). Only
  # included in the Multi pipeline at all when payload_bytes > 4096 (see
  # maybe_store_oversized_payload/2 above). Must run after M4: the composite
  # FK requires the events row to exist first.
  defp store_oversized_payload(repo, %{insert_event: %Event{} = event}, %{
         payload_bytes: payload_bytes,
         decoded_payload: decoded_payload,
         schema_name: schema_name
       }) do
    attrs = %{
      event_id: event.event_id,
      event_created_at: event.created_at,
      payload: decoded_payload,
      byte_size: payload_bytes
    }

    %Letflow.EventStore.StoredPayload{}
    |> Letflow.EventStore.StoredPayload.insert_changeset(attrs)
    |> repo.insert(prefix: schema_name)
  end

  # M6 -- instance_projections update (invariant 6, DB-03, design doc
  # §6.2.6). Update-only per REVIEWER's Step 2d OQ-5 ruling -- this step
  # never creates a row. M1 (active_instance_guard/3) already guarantees, by
  # the time this step runs, that a row exists and is non-terminal (a
  # missing or terminal row aborts the whole Multi before M6 is ever
  # reached). Uses InstanceProjection.update_changeset/2 -- never
  # insert_changeset/2, never an on_conflict:-based upsert. Only
  # last_event_seq (and, via update_changeset/2's touch of updated_at,
  # the timestamp) actually changes; status is passed through unchanged
  # from the struct M1 already read back, purely to satisfy
  # update_changeset/2's validate_required([:status, :last_event_seq]) --
  # an ordinary append must never itself overwrite status (that belongs to
  # EE-01/S3), and tenant_id is not castable by update_changeset/2 at all.
  defp update_projection(
         repo,
         %{
           assign_sequence: assigned_sequence_number,
           active_instance_guard: %InstanceProjection{} = projection
         },
         %{schema_name: schema_name}
       ) do
    attrs = %{status: projection.status, last_event_seq: assigned_sequence_number}

    projection
    |> InstanceProjection.update_changeset(attrs)
    |> repo.update(prefix: schema_name)
  end

  # ---------------------------------------------------------------------
  # Result assembly (design doc §6.3).
  # ---------------------------------------------------------------------

  defp interpret_transaction_result(
         {:ok, %{insert_event: %Event{} = event, assign_sequence: sequence_number}}
       ) do
    {:ok,
     %{
       event: event,
       is_duplicate: false,
       sequence_number: sequence_number,
       global_seq: event.global_seq
     }}
  end

  defp interpret_transaction_result(
         {:error, :active_instance_guard, {:instance_terminated, status}, _changes}
       ) do
    {:error, {:instance_terminated, status}}
  end

  defp interpret_transaction_result(
         {:error, :idempotency, {:duplicate_idempotency_key, %Event{} = original_event}, _changes}
       ) do
    {:ok,
     %{
       event: original_event,
       is_duplicate: true,
       sequence_number: original_event.sequence_number,
       global_seq: original_event.global_seq
     }}
  end

  defp interpret_transaction_result(
         {:error, :insert_event, %Ecto.Changeset{} = changeset, _changes}
       ) do
    if sequence_conflict?(changeset) do
      {:error, {:sequence_conflict, changeset}}
    else
      {:error, changeset}
    end
  end

  # Catch-all -- also where {:error, :active_instance_guard, :instance_not_started,
  # _changes} (M1's no-row case) lands: no dedicated clause needed above since
  # this generic pass-through already re-surfaces the reason unchanged as
  # {:error, :instance_not_started}, matching append_error()'s explicit tag.
  defp interpret_transaction_result({:error, _failed_operation, reason, _changes}) do
    {:error, reason}
  end

  defp sequence_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, opts}} ->
      Keyword.get(opts, :constraint) == :unique and
        Keyword.get(opts, :constraint_name) == "uq_event_sequence"
    end)
  end

  # =========================================================================
  # REQ-026 -- read/2, read_global/1, point_in_time/3, archive/1, and the
  # three platform sentinel accessors. See
  # lib/letflow/design/req026-event-read-archive-platform-sentinels.md for
  # the full design this section implements.
  # =========================================================================

  # PROVENANCE (historical, not current decision authority):
  # Platform sentinel constants (design doc §3, platform.zig port).
  #
  # VALUES FLAGGED, per the design doc's own §3/§12 OQ-1: `platform.zig` is
  # unreachable from this host (confirmed fresh for this run, same result as
  # the design doc's own §0 check). These are placeholder UUIDs -- pairwise
  # distinct, syntactically valid (Ecto.UUID.cast/1 accepts them) -- not
  # verified against the real values these are meant to stand in for.
  # Substitute the real values if/when platform.zig becomes reachable;
  # nothing in this codebase reads these back yet
  # (requirements.yaml:1119-1121: "this requirement only needs the
  # constants to exist"), so the placeholder values carry no behavioral risk
  # today.
  @platform_instance_id "00000000-0000-0000-0000-000000000001"
  @platform_actor_id "00000000-0000-0000-0000-000000000002"
  @platform_tenant_id "00000000-0000-0000-0000-000000000003"

  @doc """
  PROVENANCE (historical, not current decision authority):
  PLATFORM_INSTANCE_ID sentinel -- ported from `src/event_store/platform.zig`
  (value unverified, see this module's source comment above these three
  accessors). Never inserted into `instance_projections`, per
  `req023-event-store-schema.md` §3.1.3's citation of `platform.zig:5`.
  """
  @spec platform_instance_id() :: Ecto.UUID.t()
  def platform_instance_id, do: @platform_instance_id

  @doc """
  PROVENANCE (historical, not current decision authority):
  PLATFORM_ACTOR_ID sentinel -- ported from `src/event_store/platform.zig`
  (value unverified, see this module's source comment above these three
  accessors). Identifies the platform itself as the acting party for
  non-instance-scoped scheduler events (a later stage's concern to actually
  emit).
  """
  @spec platform_actor_id() :: Ecto.UUID.t()
  def platform_actor_id, do: @platform_actor_id

  @doc """
  PROVENANCE (historical, not current decision authority):
  PLATFORM_TENANT_ID sentinel -- ported from `src/event_store/platform.zig`
  (value unverified, see this module's source comment above these three
  accessors). Identifies the platform itself as the tenant for
  non-instance-scoped scheduler events (a later stage's concern to actually
  emit).
  """
  @spec platform_tenant_id() :: Ecto.UUID.t()
  def platform_tenant_id, do: @platform_tenant_id

  @type read_opts :: [
          prefix: String.t(),
          up_to_sequence: pos_integer() | nil,
          up_to_timestamp: DateTime.t() | nil
        ]

  @type read_error ::
          {:error, :invalid_instance_id}
          | {:error, :invalid_schema_name}
          | {:error, :instance_not_found}
          | {:error, {:payload_resolution_failed, event_id :: Ecto.UUID.t()}}
          | {:error, term()}

  @doc """
  Reads `instance_id`'s events in ascending `sequence_number` order, inside
  the tenant schema named by `opts[:prefix]`. `opts[:up_to_sequence]`/
  `opts[:up_to_timestamp]` filter the result -- `up_to_sequence` wins
  outright if both are given (ES-06, design doc §4.3), never a conjunction
  of the two. Any `$ref` payload pointer is transparently resolved via
  `event_payload_store` before returning.

  Returns `{:error, :instance_not_found}` -- never `{:ok, []}` -- when
  `instance_id` has never had a successful append (no `instance_sequence`
  row). `{:ok, []}` is reserved for an instance that exists but currently
  has zero matching `events` rows (e.g. fully archived, or filtered past) --
  see design doc §4.2's two-step lookup order, INV-RD-1.
  """
  @spec read(instance_id :: Ecto.UUID.t(), opts :: read_opts()) ::
          {:ok, [Event.t()]} | read_error()
  def read(instance_id, opts) when is_list(opts) do
    prefix = Keyword.get(opts, :prefix)

    with {:ok, instance_id} <- cast_instance_id(instance_id),
         {:ok, _} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         :ok <- ensure_instance_started(instance_id, prefix) do
      instance_id
      |> query_instance_events(prefix, read_filter(opts))
      |> resolve_payloads(prefix)
    end
  end

  @doc """
  GH #2550 (design D3), removed by GH #2578: the one-release legacy lookup for
  a pre-namespacing caller key. One query joining `event_idempotency` to
  `events` on `(event_id, event_created_at)`, with every guard in the
  `WHERE`: the event was written before `before`, by `actor_id`, with an
  `event_type` in `event_types`. Selects only the columns a duplicate result
  reads. Archived rows are not searched. The caller (`Letflow.Idempotency`)
  has already excluded server and caller key families.
  """
  @spec get_legacy_original(
          key :: String.t(),
          actor_id :: Ecto.UUID.t(),
          event_types :: [String.t()],
          before :: DateTime.t(),
          opts :: [prefix: String.t()]
        ) :: {:ok, Event.t()} | {:error, :not_found}
  def get_legacy_original(key, actor_id, event_types, %DateTime{} = before, opts)
      when is_binary(key) and is_binary(actor_id) and is_list(event_types) and is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    IdempotencyRecord
    |> join(:inner, [i], e in Event,
      on: e.event_id == i.event_id and e.created_at == i.event_created_at
    )
    |> where(
      [i, e],
      i.idempotency_key == ^key and e.created_at < ^before and e.actor_id == ^actor_id and
        e.event_type in ^event_types
    )
    |> select(
      [_i, e],
      struct(e, [
        :event_id,
        :created_at,
        :instance_id,
        :event_type,
        :actor_id,
        :payload,
        :global_seq
      ])
    )
    |> Repo.one(prefix: prefix)
    |> case do
      %Event{} = event -> {:ok, event}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Convenience wrapper over `read/2` with `opts[:up_to_timestamp]` set to
  `timestamp` (design doc §4.5). `opts[:up_to_sequence]`, if also supplied,
  is not stripped -- `read/2`'s ordinary precedence rule (`up_to_sequence`
  wins) applies unchanged.
  """
  @spec point_in_time(
          instance_id :: Ecto.UUID.t(),
          timestamp :: DateTime.t(),
          opts :: read_opts()
        ) :: {:ok, [Event.t()]} | read_error()
  def point_in_time(instance_id, %DateTime{} = timestamp, opts) when is_list(opts) do
    read(instance_id, Keyword.put(opts, :up_to_timestamp, timestamp))
  end

  @type read_global_opts :: [
          prefix: String.t(),
          after_global_seq: pos_integer() | nil,
          limit: non_neg_integer() | nil,
          actor_id: Ecto.UUID.t() | nil,
          instance_id: Ecto.UUID.t() | nil,
          from: DateTime.t() | nil,
          to: DateTime.t() | nil
        ]

  @type read_global_result :: %{
          events: [Event.t()],
          next_after_global_seq: pos_integer() | nil,
          has_more: boolean()
        }

  @type read_global_error ::
          {:error, :invalid_schema_name}
          | {:error, :invalid_actor_id}
          | {:error, :invalid_instance_id}
          | {:error, {:payload_resolution_failed, event_id :: Ecto.UUID.t()}}
          | {:error, term()}

  @doc """
  Cursor-paginated read across every instance's events in one tenant schema
  (named by `opts[:prefix]`), ordered by `global_seq` ascending. "Global"
  here means global within one tenant's own schema, across that tenant's
  instances -- not a cross-tenant stream (design doc §5's scope note).

  `opts[:after_global_seq]` (`nil` = from the beginning) is a strict lower
  bound (`global_seq > N`). `opts[:limit]` is clamped to `1..1000`; `nil` or
  `0` default to `100` (design doc §5.2, GlobalReadOpts semantics). `$ref`
  payloads are transparently resolved, same as `read/2`.

  `has_more` is a heuristic, not a proof (design doc §5.4): if exactly
  `limit` more rows exist and no others, `has_more` reports `true` but the
  very next call returns zero new rows -- the ordinary cursor-pagination
  boundary case.

  ## Filter opts (REQ-078, `lib/letflow/design/req078-supporting-routes.md` §6.5)

  `:actor_id`, `:instance_id`, `:from` and `:to` were added **additively** so
  that `GET /api/v1/audit` reads through this one function rather than a
  second `list_audit/1` that could drift from it -- **one read path, not
  two.** Every existing caller is unaffected: each new key defaults to `nil`
  and contributes no predicate.

    * All four are `AND`-composed with each other and with
      `:after_global_seq`.
    PROVENANCE (historical, not current decision authority):
    * `:from` / `:to` are **inclusive** bounds on `events.created_at`. The
      `from > to` case is deliberately **not** checked here -- it is the
      route's responsibility, per the handler-level check in
      `src/api/routes/audit.zig:26-30` (`invalid_time_range`).
    * `:actor_id` / `:instance_id` are validated with `Ecto.UUID.cast/1`
      **before any query is constructed**; a malformed value returns
      `{:error, :invalid_actor_id}` / `{:error, :invalid_instance_id}` with
      zero queries issued -- the same validate-then-query ordering
      `Letflow.Engine.VariableSchema.fetch_schemas/3` establishes.
    * Composed with `Ecto.Query` and bound parameters only; no SQL string
      interpolation (INV-7).

  Ordering (`asc: global_seq`), `:prefix` scoping and `$ref` payload
  resolution are unchanged.
  """
  @spec read_global(opts :: read_global_opts()) ::
          {:ok, read_global_result()} | read_global_error()
  def read_global(opts) when is_list(opts) do
    prefix = Keyword.get(opts, :prefix)
    after_global_seq = Keyword.get(opts, :after_global_seq)
    effective_limit = clamp_read_global_limit(Keyword.get(opts, :limit))

    with {:ok, _} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, actor_id} <- cast_optional_uuid(Keyword.get(opts, :actor_id), :invalid_actor_id),
         {:ok, instance_id} <-
           cast_optional_uuid(Keyword.get(opts, :instance_id), :invalid_instance_id) do
      raw_events =
        Event
        |> apply_after_global_seq(after_global_seq)
        |> apply_global_actor_id(actor_id)
        |> apply_global_instance_id(instance_id)
        |> apply_global_from(Keyword.get(opts, :from))
        |> apply_global_to(Keyword.get(opts, :to))
        |> order_by([e], asc: e.global_seq)
        |> limit(^effective_limit)
        |> Repo.all(prefix: prefix)

      case resolve_payloads(raw_events, prefix) do
        {:ok, events} ->
          {:ok,
           %{
             events: events,
             next_after_global_seq: next_after_global_seq(events, after_global_seq),
             has_more: length(events) == effective_limit
           }}

        {:error, _reason} = error ->
          error
      end
    end
  end

  @typedoc """
  ISS-0733 GAP B (`lib/letflow/design/iss0733-promotion-audit-and-platform-events-read.md`
  §2.5) — one row of `list_platform_events/1`'s result. `payload` is already
  a decoded map at the Ecto level (`Event.payload`'s `:map` type) — not
  re-encoded to a JSON string for the response.
  """
  @type platform_event_item :: %{
          event_id: Ecto.UUID.t(),
          event_type: String.t(),
          actor_id: Ecto.UUID.t() | nil,
          timestamp: DateTime.t(),
          sequence_num: integer(),
          payload: map()
        }

  @typedoc """
  Input to `list_platform_events/1`. `:cursor` is an already-decoded
  `{sequence_number, event_id}` seek pair — decoding the opaque cursor
  string itself stays a router-owned concern, matching `Letflow.Audit`'s
  own `list_params()` division of labor (`:cursor` there is likewise
  already-decoded).
  """
  @type list_platform_events_params :: %{
          required(:prefix) => String.t(),
          required(:page_size) => pos_integer(),
          optional(:cursor) => {integer(), Ecto.UUID.t()} | nil,
          optional(:event_type) => String.t() | nil
        }

  @doc """
  ISS-0733 GAP B (design §2.5) — cursor-paginated read of the platform
  sentinel's own event stream (`instance_id == platform_instance_id()`),
  inside the tenant schema named by `params.prefix`. Backs
  `Letflow.Routers.Promotions`'s `GET /platform-events` (R11).

  `params[:event_type]`, when present, narrows to that exact `event_type`
  only (mirrors `Letflow.Routers.Audit`'s `resource_type` filter — narrows
  only, never widens). Ordered `asc: sequence_number` — the same ordering
  `query_instance_events/3` already uses for a real instance's own event
  page, and consistent with `uq_event_sequence`'s
  `(instance_id, sequence_number)` uniqueness (the sentinel's own sequence
  is gap-tolerant-monotone exactly like any real instance's).

  `page_size + 1`/drop-the-extra-row idiom, same as `Letflow.Audit.list_entries/1`
  and `Letflow.ServiceCatalog.list_all/1`.
  """
  @spec list_platform_events(list_platform_events_params()) ::
          {:ok, %{items: [platform_event_item()], next_cursor: String.t() | nil}}
  def list_platform_events(params) when is_map(params) do
    prefix = Map.fetch!(params, :prefix)
    page_size = Map.fetch!(params, :page_size)
    cursor = Map.get(params, :cursor)
    event_type = Map.get(params, :event_type)

    rows =
      Event
      |> where([e], e.instance_id == ^platform_instance_id())
      |> apply_platform_event_type(event_type)
      |> apply_platform_cursor(cursor)
      |> order_by([e], asc: e.sequence_number)
      |> limit(^(page_size + 1))
      |> Repo.all(prefix: prefix)

    {rows, has_more} = split_platform_events_page(rows, page_size)
    items = Enum.map(rows, &platform_event_item/1)

    {:ok, %{items: items, next_cursor: platform_events_next_cursor(items, has_more)}}
  end

  defp apply_platform_event_type(query, nil), do: query
  defp apply_platform_event_type(query, ""), do: query

  defp apply_platform_event_type(query, event_type),
    do: where(query, [e], e.event_type == ^event_type)

  defp apply_platform_cursor(query, nil), do: query

  defp apply_platform_cursor(query, {seq, event_id}) do
    where(
      query,
      [e],
      e.sequence_number > ^seq or (e.sequence_number == ^seq and e.event_id > ^event_id)
    )
  end

  # Same idiom as Letflow.Audit.list_entries/1's split_list_page/2.
  defp split_platform_events_page(rows, page_size) do
    if length(rows) > page_size do
      {Enum.take(rows, page_size), true}
    else
      {rows, false}
    end
  end

  defp platform_event_item(%Event{} = event) do
    %{
      event_id: event.event_id,
      event_type: event.event_type,
      actor_id: event.actor_id,
      timestamp: event.created_at,
      sequence_num: event.sequence_number,
      payload: event.payload
    }
  end

  # Design §2.6 -- a new, distinct cursor-endpoint prefix ("PE:"), so
  # Pagination.decode_cursor/4's {:error, :wrong_endpoint} rejects a cursor
  # minted by another endpoint (does not collide with "A:"/"IL:"/"IH:"/
  # "IT:"/"T:"/"U:" already in use elsewhere in this codebase).
  @platform_events_cursor_prefix "PE:"

  defp platform_events_next_cursor([], _has_more), do: nil
  defp platform_events_next_cursor(_items, false), do: nil

  defp platform_events_next_cursor(items, true) do
    last = List.last(items)
    mint_time_us = System.system_time(:microsecond)
    seek_key = "#{last.sequence_num}:#{last.event_id}"

    @platform_events_cursor_prefix
    |> Pagination.build_raw_cursor(mint_time_us, seek_key)
    |> Pagination.encode_cursor()
  end

  @type archive_opts :: [prefix: String.t(), retention_days: non_neg_integer()]
  @type archive_result :: %{moved_count: non_neg_integer()}

  @doc """
  Moves events past `opts[:retention_days]` (a global fallback) into
  `events_archive`, honoring any per-`event_type` `event_retention_policies`
  row over the global fallback (design doc §7.1's precedence:
  `keep_forever` > `keep_days` > `keep_count` > the global fallback for any
  `event_type` with no policy row). `retention_days: 0` archives nothing for
  event types with no explicit policy row -- `0` is a valid, meaningful
  value ("only explicit policies apply"), never conflated with "absent".
  `opts[:retention_days]` is required -- `{:error, :missing_retention_days}`
  if absent or not a non-negative integer.

  Idempotent (design doc §7.3/INV-AR-1): calling this twice in a row with
  the same `retention_days` moves the eligible set once, then zero rows the
  second time -- the target set is computed once per call from `events` as
  it currently stands, so a row already moved to `events_archive` (and
  deleted from `events`) can never be re-selected by a later call. Never
  queries, joins, or locks `instance_projections`/`instance_sequence`
  (INV-AR-2). `events_archive.payload` always holds the fully-resolved
  payload, never a `$ref` pointer (design doc §7.4, INV-AR-3) -- this
  resolves REQ-023 §9 OQ-2.
  """
  @spec archive(opts :: archive_opts()) ::
          {:ok, archive_result()}
          | {:error, :missing_retention_days}
          | {:error, :invalid_schema_name}
          | {:error, term()}
  def archive(opts) when is_list(opts) do
    prefix = Keyword.get(opts, :prefix)

    with {:ok, retention_days} <- fetch_retention_days(opts),
         {:ok, _} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      event_ids = compute_archive_target_event_ids(prefix, retention_days)

      with :ok <- archive_phase1_insert(prefix, event_ids),
           {:ok, moved_count} <- archive_phase2_delete(prefix, event_ids) do
        {:ok, %{moved_count: moved_count}}
      end
    end
  end

  # -------------------------------------------------------------------------
  # read/2 / point_in_time/3 private helpers
  # -------------------------------------------------------------------------

  defp cast_instance_id(instance_id) do
    case Ecto.UUID.cast(instance_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_instance_id}
    end
  end

  # Design doc §4.2 STEP 1 -- existence check via instance_sequence. A
  # committed row here is proof this instance has had at least one
  # successful append: assign_sequence/3 (append/2's own Multi, above) only
  # ever creates this row inside that same atomic transaction as the
  # matching `events` insert -- so its absence means instance_id has never
  # had one (InstanceNotFound), and its presence means STEP 2 may legitimately
  # return an empty list (e.g. every event since archived).
  defp ensure_instance_started(instance_id, schema_name) do
    InstanceSequence
    |> where([s], s.instance_id == ^instance_id)
    |> Repo.exists?(prefix: schema_name)
    |> case do
      true -> :ok
      false -> {:error, :instance_not_found}
    end
  end

  # Design doc §4.2 STEP 2 -- the real read, filters applied, ordered by
  # sequence_number ASC. May legitimately return [].
  #
  # REQ-376 §6 (EO-003) -- extended to query BOTH `events` and
  # `events_archive` and merge the results, closing the pre-existing gap
  # req026-event-read-archive-platform-sentinels.md §11 OQ-3 already flagged
  # ("no function reads events back out of events_archive"). This is what
  # makes an already-whole-partition-retired month (docs/migration/decisions/
  # 0037-...md) still replay with no gap: retire_month/3 never deletes a row,
  # it only ever changes which table a given month's partition is a child
  # of, so this instance's history is always findable across the union of
  # both tables regardless of which side any given event currently lives on.
  # Correctness does not depend on either query being individually sorted --
  # the merge step below re-sorts the combined set by sequence_number, the
  # same invariant (INV-RD-2) this function already guaranteed pre-REQ-376.
  # ArchivedEvent rows are normalized into %Event{} structs (same field
  # overlap minus `archived_at`) so every existing caller of read/2 keeps
  # seeing a homogeneous list of %Event{} structs, unchanged.
  defp query_instance_events(instance_id, schema_name, filter) do
    live_events =
      Event
      |> where([e], e.instance_id == ^instance_id)
      |> apply_read_filter(filter)
      |> Repo.all(prefix: schema_name)

    archived_events =
      ArchivedEvent
      |> where([e], e.instance_id == ^instance_id)
      |> apply_read_filter(filter)
      |> Repo.all(prefix: schema_name)
      |> Enum.map(&archived_event_to_event/1)

    (live_events ++ archived_events)
    |> Enum.sort_by(& &1.sequence_number)
  end

  defp archived_event_to_event(%ArchivedEvent{} = archived) do
    %Event{
      event_id: archived.event_id,
      created_at: archived.created_at,
      instance_id: archived.instance_id,
      event_type: archived.event_type,
      payload: archived.payload,
      actor_id: archived.actor_id,
      sequence_number: archived.sequence_number,
      idempotency_key: archived.idempotency_key,
      metadata: archived.metadata,
      global_seq: archived.global_seq
    }
  end

  # Design doc §4.3 -- up_to_sequence wins outright over up_to_timestamp if
  # both are given (never ANDed together).
  defp read_filter(opts) do
    cond do
      not is_nil(Keyword.get(opts, :up_to_sequence)) ->
        {:sequence_number, Keyword.get(opts, :up_to_sequence)}

      not is_nil(Keyword.get(opts, :up_to_timestamp)) ->
        {:created_at, Keyword.get(opts, :up_to_timestamp)}

      true ->
        :none
    end
  end

  defp apply_read_filter(query, {:sequence_number, value}),
    do: where(query, [e], e.sequence_number <= ^value)

  defp apply_read_filter(query, {:created_at, value}),
    do: where(query, [e], e.created_at <= ^value)

  defp apply_read_filter(query, :none), do: query

  # -------------------------------------------------------------------------
  # read_global/1 private helpers
  # -------------------------------------------------------------------------

  defp apply_after_global_seq(query, nil), do: query

  defp apply_after_global_seq(query, after_global_seq),
    do: where(query, [e], e.global_seq > ^after_global_seq)

  # REQ-078 §6.5 -- the four additive filter opts. Each is a no-op when nil,
  # so every pre-REQ-078 caller composes to exactly the query it did before.
  defp apply_global_actor_id(query, nil), do: query
  defp apply_global_actor_id(query, actor_id), do: where(query, [e], e.actor_id == ^actor_id)

  defp apply_global_instance_id(query, nil), do: query

  defp apply_global_instance_id(query, instance_id),
    do: where(query, [e], e.instance_id == ^instance_id)

  defp apply_global_from(query, nil), do: query
  defp apply_global_from(query, %DateTime{} = from), do: where(query, [e], e.created_at >= ^from)

  defp apply_global_to(query, nil), do: query
  defp apply_global_to(query, %DateTime{} = to), do: where(query, [e], e.created_at <= ^to)

  # Validate-then-query: a malformed uuid issues zero queries.
  defp cast_optional_uuid(nil, _error), do: {:ok, nil}

  defp cast_optional_uuid(value, error) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, error}
    end
  end

  # Design doc §5.2 -- GlobalReadOpts limit clamping.
  defp clamp_read_global_limit(nil), do: 100
  defp clamp_read_global_limit(0), do: 100
  defp clamp_read_global_limit(limit) when is_integer(limit) and limit < 0, do: 1
  defp clamp_read_global_limit(limit) when is_integer(limit) and limit > 1000, do: 1000
  defp clamp_read_global_limit(limit) when is_integer(limit), do: limit

  # Design doc §5.4 -- ASC order, so the last row (if any) carries the max
  # global_seq seen this call.
  defp next_after_global_seq([], after_global_seq), do: after_global_seq
  defp next_after_global_seq(events, _after_global_seq), do: List.last(events).global_seq

  # -------------------------------------------------------------------------
  # $ref payload resolution -- shared by read/2, read_global/1, and
  # archive/1's phase 1 (design doc §9). Never N+1: one batched query per
  # call, keyed on StoredPayload's own single-column uq_event_payload_event
  # index.
  # -------------------------------------------------------------------------

  defp resolve_payloads(events, schema_name) do
    ref_ids =
      for %{payload: %{"$ref" => ref_id}} <- events, do: ref_id

    case ref_ids do
      [] ->
        {:ok, events}

      _ref_ids ->
        resolved_map =
          StoredPayload
          |> where([sp], sp.event_id in ^ref_ids)
          |> select([sp], {sp.event_id, sp.payload})
          |> Repo.all(prefix: schema_name)
          |> Map.new()

        substitute_resolved_payloads(events, resolved_map)
    end
  end

  defp substitute_resolved_payloads(events, resolved_map) do
    events
    |> Enum.reduce_while({:ok, []}, fn event, {:ok, acc} ->
      case event.payload do
        %{"$ref" => ref_id} ->
          case Map.fetch(resolved_map, ref_id) do
            {:ok, payload} -> {:cont, {:ok, [%{event | payload: payload} | acc]}}
            :error -> {:halt, {:error, {:payload_resolution_failed, ref_id}}}
          end

        _payload ->
          {:cont, {:ok, [event | acc]}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  # -------------------------------------------------------------------------
  # archive/1 private helpers
  # -------------------------------------------------------------------------

  # `0` is a valid, meaningful value distinct from "absent" -- matches
  # fetch_uuid/3's own idiom above (a malformed/absent value collapses to
  # the same typed error) rather than adding a second, undeclared error atom
  # for "present but wrong shape".
  defp fetch_retention_days(opts) do
    case Keyword.fetch(opts, :retention_days) do
      {:ok, retention_days} when is_integer(retention_days) and retention_days >= 0 ->
        {:ok, retention_days}

      _ ->
        {:error, :missing_retention_days}
    end
  end

  # Design doc §7.1's classification predicate, computed as a set of
  # `event_id`s rather than a single SQL statement with a window function --
  # an explicitly-authorized equivalent per the design doc's own §7.1 callout
  # ("ELIXIR-DEV may express it as ... a multi-query Elixir-side computation
  # ... that produces the identical eligible set"). `event_id` alone (rather
  # than the full `(event_id, created_at)` composite PK) is a sufficient
  # target-set key: every `event_id` is minted exactly once via
  # `Ecto.UUID.generate()` (append/2's own INV-EV-5), so it is already
  # globally unique within a tenant schema -- no two rows in `events` ever
  # share one.
  #
  # rule 3 (keep_count) uses `OFFSET keep_count` after `ORDER BY created_at
  # DESC, event_id DESC` -- every row after the top-`keep_count` most recent
  # is exactly the eligible set design doc §7.1 rule 3 describes, with no
  # window function needed at all.
  defp compute_archive_target_event_ids(schema_name, retention_days) do
    policies_by_type = retention_policies_by_type()
    now = DateTime.utc_now()

    keep_days_ids =
      for {event_type, %RetentionPolicy{policy: :keep_days, keep_days: keep_days}} <-
            policies_by_type,
          reduce: [] do
        acc ->
          cutoff = DateTime.add(now, -keep_days * 86_400, :second)
          acc ++ eligible_by_cutoff(schema_name, event_type, cutoff)
      end

    keep_count_ids =
      for {event_type, %RetentionPolicy{policy: :keep_count, keep_count: keep_count}} <-
            policies_by_type,
          reduce: [] do
        acc -> acc ++ eligible_beyond_count(schema_name, event_type, keep_count)
      end

    fallback_ids =
      if retention_days > 0 do
        excluded_types = Map.keys(policies_by_type)
        cutoff = DateTime.add(now, -retention_days * 86_400, :second)
        eligible_by_cutoff_excluding_types(schema_name, excluded_types, cutoff)
      else
        []
      end

    Enum.uniq(keep_days_ids ++ keep_count_ids ++ fallback_ids)
  end

  # GLOBAL table (design doc §6) -- no prefix: at all.
  defp retention_policies_by_type do
    RetentionPolicy
    |> Repo.all()
    |> Map.new(&{&1.event_type, &1})
  end

  defp eligible_by_cutoff(schema_name, event_type, cutoff) do
    Event
    |> where([e], e.event_type == ^event_type and e.created_at < ^cutoff)
    |> select([e], e.event_id)
    |> Repo.all(prefix: schema_name)
  end

  defp eligible_beyond_count(schema_name, event_type, keep_count) do
    Event
    |> where([e], e.event_type == ^event_type)
    |> order_by([e], desc: e.created_at, desc: e.event_id)
    |> offset(^keep_count)
    |> select([e], e.event_id)
    |> Repo.all(prefix: schema_name)
  end

  defp eligible_by_cutoff_excluding_types(schema_name, excluded_types, cutoff) do
    Event
    |> where([e], e.created_at < ^cutoff and e.event_type not in ^excluded_types)
    |> select([e], e.event_id)
    |> Repo.all(prefix: schema_name)
  end

  # Design doc §7.3 phase 1 -- idempotent archive-insert. `Repo.insert_all/3`
  # with `on_conflict: :nothing` keyed on events_archive's own composite PK
  # is this implementation's translation of the design's illustrative
  # `INSERT ... SELECT ... ON CONFLICT DO NOTHING` -- same idempotency
  # property (a re-run after every target row is already archived is a true
  # no-op), expressed via Ecto's bulk-insert primitive instead of a raw SQL
  # string, matching this project's general no-raw-SQL preference (INV-7)
  # where an idiomatic equivalent exists. Wrapped in its own
  # `Repo.transaction/1` (not the caller's `with`) so its lock duration is
  # bounded to this one statement, per design doc §7.3's stated reason for
  # the two-phase split.
  defp archive_phase1_insert(_schema_name, []), do: :ok

  defp archive_phase1_insert(schema_name, event_ids) do
    result =
      Repo.transaction(fn ->
        events = Event |> where([e], e.event_id in ^event_ids) |> Repo.all(prefix: schema_name)

        case resolve_payloads(events, schema_name) do
          {:ok, resolved_events} ->
            archived_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
            entries = Enum.map(resolved_events, &archived_event_entry(&1, archived_at))

            Repo.insert_all(ArchivedEvent, entries,
              on_conflict: :nothing,
              conflict_target: [:event_id, :created_at],
              prefix: schema_name
            )

            :ok

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Post-Decision-0006-D2 (REQ-064): no longer copies tenant_id from the
  # source `events` row -- neither `events.tenant_id` nor
  # `events_archive.tenant_id` exists as a column any more (both dropped by
  # this requirement), and %Event{} itself no longer carries the field to
  # copy from.
  defp archived_event_entry(%Event{} = event, archived_at) do
    %{
      event_id: event.event_id,
      created_at: event.created_at,
      instance_id: event.instance_id,
      event_type: event.event_type,
      payload: event.payload,
      actor_id: event.actor_id,
      sequence_number: event.sequence_number,
      idempotency_key: event.idempotency_key,
      metadata: event.metadata,
      global_seq: event.global_seq,
      archived_at: archived_at
    }
  end

  # Design doc §7.3 phase 2 -- payload-sidecar cleanup + confirmed delete, in
  # ONE transaction (event_payload_store's FK to events is ON DELETE
  # RESTRICT, so the sidecar delete must precede the events delete in the
  # same transaction). "Confirmed": the events delete only ever targets
  # event_ids re-verified present in events_archive by this same call --
  # never event_ids alone from T -- so a crash between phase 1 and phase 2
  # (or a second concurrent archive/1 call) can never delete an `events` row
  # this call hasn't itself just confirmed was durably copied.
  defp archive_phase2_delete(_schema_name, []), do: {:ok, 0}

  defp archive_phase2_delete(schema_name, event_ids) do
    Repo.transaction(fn ->
      StoredPayload
      |> where([sp], sp.event_id in ^event_ids)
      |> Repo.delete_all(prefix: schema_name)

      archived_ids =
        ArchivedEvent
        |> where([a], a.event_id in ^event_ids)
        |> select([a], a.event_id)
        |> Repo.all(prefix: schema_name)

      {deleted_count, _} =
        Event
        |> where([e], e.event_id in ^archived_ids)
        |> Repo.delete_all(prefix: schema_name)

      deleted_count
    end)
  end
end
