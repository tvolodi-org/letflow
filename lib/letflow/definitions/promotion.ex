defmodule Letflow.Definitions.Promotion do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  `promote_definition/3` — the version-pointer-move + event-append operation
  `Letflow.Definitions.PromotionReviewStore.mark_review_applied/2`'s *caller*
  invokes (some future orchestrator, REQ-040 or later, calls this function
  first, then `mark_review_applied/2` on success or `mark_review_failed/2` on
  failure). Ported from R-Co's `src/definition/promotion.zig` (ENV-03). See
  `lib/letflow/design/promotion_review_state_machine.md` §3 for the full
  gate-approved design this module implements; this moduledoc restates the
  invariants that design requires to be stated here verbatim in substance.

  ## Reuse, not reinvention (INV-PRM04-5)

  `promote_opts()`'s `permission_checker`/`tenant_classifier` are the exact
  same shape as `Letflow.Definitions.PromotionPlan.promotion_opts()`'s —
  same arities, same semantics. `permission_checker` has **no built-in
  default** (`Keyword.fetch!/2`, raises `KeyError` if omitted; silently
  defaulting to "allowed" would be worse than crashing). The HTTP call sites
  pass `Letflow.Definitions.PromotionAccess.checker_for/1` (ISS-0993; the old
  allow-all default was deleted). `tenant_classifier`
  defaults by **delegating** to
  `Letflow.Definitions.PromotionPlan.default_tenant_classifier/1` — not a
  duplicated copy of the same one-line function, so the two modules can never
  silently drift apart on what "test tenant" means. `variable_schema_fetcher`
  is not carried over — it has no meaning here.

  ## `opts[:event_appender]` — a new opt, deliberately with no built-in
  default (design §3.2 step 9, OQ-1)

  There is no data path from this function to a working
  `Letflow.EventStore.append/2` call today: no `DEFINITION_PROMOTED`-shaped
  event type is registered in any tenant's `event_type_registry`, and
  `append/2`'s `instance_id` guard has no non-instance-scoped path (even the
  `platform_instance_id/0` sentinel doesn't resolve to a real
  `instance_projections` row). This function does not paper over that gap
  with a silently-no-op or a silently-always-failing default —
  `opts[:event_appender]` is `Keyword.fetch!/2`'d, raises `KeyError` if
  omitted, same reasoning as `permission_checker`. The caller supplies
  whatever mechanism is actually wired up by the time this function is
  really invoked. Step 9 (the event-append) runs *after* the transaction in
  steps 7/8 commits, not nested inside it — this function does not assume
  anything about how an arbitrary injected `event_appender` manages its own
  transactionality, and it does not roll back the already-committed
  version-pointer move if the event-append fails. That is a real gap, stated
  here rather than hidden.

  ## Algorithm, in order (each step short-circuits on failure)

    1. `Jason.decode!/1` `review.serialised_plan` — a plain string-keyed map,
       never re-hydrated into the atom-keyed `PromotionPlan.t()` shape.
       Extracts `source_tenant_id`, `process_key`, `base_version`,
       `target_tenant_id` from it. **Post-Decision-0006-D2 note (REQ-064):**
       `target_tenant_id` used to be read from `review.tenant_id` directly
       (already a trusted, typed value on the struct); `promotion_reviews.tenant_id`
       no longer exists as a column (D2 dropped it — the per-tenant Postgres
       schema the row lives in already identifies the tenant), so this now reads
       `plan["target_tenant_id"]` instead — the same trusted value, already
       present in `serialised_plan` via `PromotionPlan.t().target_tenant_id`
       (`compute_promotion_plan/5`'s own output), not a new or less-trusted
       source.
    2. `opts[:permission_checker].(actor_id, source_tenant_id)` -> `false` ->
       `{:error, :forbidden}`.
    3. `opts[:tenant_classifier].(source_tenant_id) == :production` ->
       `{:error, :invalid_promotion_source}`.
    4. `Letflow.TenantProvisioning.schema_name_for_tenant/1` on both
       `source_tenant_id` and `target_tenant_id` -> `{:error,
       :invalid_tenant_id}` on either failure.
    5. Fresh plain read of the source's ACTIVE `process_definitions` row.
       `nil` -> `{:error, :source_definition_missing}` — a hard failure (this
       function has nothing to copy if the source has since been
       deactivated/archived between plan-compute time and approval time).
    6. **Conflict re-check** — resolves REQ-036's own forward-reference
       (`base_version` fed verbatim into
       `Letflow.Definitions.PromotionConflict.reject_if_conflicts/4`'s
       `base_version` argument at approval time): `{:error, {:conflicts,
       list}}` propagates unchanged. Deliberately placed here, not in
       `approve_review/4` — REQ-037's own text names only 3 gates for
       `approve_review/4`.
    7. Build the new target row's attrs from the freshly-read source row,
       via `ProcessDefinition.create_changeset/2`, inside one
       `Repo.transaction/1` together with step 8's swap. A
       `uq_definition_version` unique-constraint violation ->
       `{:error, :duplicate_version}` (mapped explicitly, never a leaked
       changeset for this one case).
    8. Three-step swap, inside the same transaction as step 7 (PD-03
       ordering — deprecate before activate): (a) guarded `UPDATE` deprecates
       whatever row is currently `active` for this `(target_tenant_id,
       process_key)`; (b) guarded `UPDATE` activates the row this function
       itself just inserted (still `:draft`, since `create_changeset/2`
       never casts `:status`); (c) **(ISS-0733 GAP A)** `Audit.insert_entry/3`
       for a `resource_type: "definition"`, `action: "definition.promote"`
       row describing this swap, `after_state` reusing step 9's own
       `event_attrs` shape field-for-field (see
       `lib/letflow/design/iss0733-promotion-audit-and-platform-events-read.md`
       §1.4) — still inside this same transaction, so a failure here rolls
       back the whole swap, exactly like `activate_draft_row/4`
       (`definitions.ex`) already accepts for `"definition.activate"`.
       (a)/(b) are inlined here rather than delegated to a real
       `activate/1` — REQ-030 (that function's owner) is not a dependency of
       REQ-037 and has not shipped (see moduledoc OQ-5 in the design doc).
    9. Event-append, after the transaction commits:
       `opts[:event_appender].(event_attrs, target_prefix)`.
    10. `{:ok, promote_result()}` if step 9 succeeds; step 9's own error
        propagates unchanged otherwise.
  """

  import Ecto.Query

  alias Letflow.Audit
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.PromotionConflict
  alias Letflow.Definitions.PromotionDigest
  alias Letflow.Definitions.PromotionPlan
  alias Letflow.Definitions.PromotionReview
  alias Letflow.Definitions.PromotionReviewStore
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @type promote_opts :: [
          permission_checker: (Ecto.UUID.t(), Ecto.UUID.t() -> boolean()),
          tenant_classifier: (Ecto.UUID.t() -> :production | :test),
          event_appender: (map(), String.t() -> {:ok, term()} | {:error, term()}),
          # GH #2587 PR B1: the promoting principal's authority a graph with `entity_writes`
          # is activated under in the TARGET tenant; absent (nil) refuses such a graph.
          activator: Letflow.Engine.EntityPort.activator() | nil
        ]

  @type promote_result :: %{
          source_definition_id: Ecto.UUID.t(),
          target_definition_id: Ecto.UUID.t(),
          process_key: String.t()
        }

  @type promote_error ::
          :forbidden
          | :invalid_promotion_source
          | :invalid_tenant_id
          | :source_definition_missing
          | :duplicate_version
          | {:conflicts, [PromotionConflict.conflict_detail()]}
          | {:expression_references_reserved_variable,
             [Letflow.Definitions.ReservedReferences.reserved_reference()]}
          | {:entity_writes_invalid, [Letflow.Definitions.entity_writes_violation()]}
          | Ecto.Changeset.t()
          | term()

  @doc """
  Performs the version-pointer move (deprecate current active, activate the
  newly-copied target row) plus event-append for `review`'s already-approved
  promotion plan. See moduledoc for the full 10-step algorithm and the
  `opts[:event_appender]` gap this function deliberately does not paper over.
  """
  @spec promote_definition(
          actor_id :: Ecto.UUID.t(),
          review :: PromotionReview.t(),
          opts :: promote_opts()
        ) :: {:ok, promote_result()} | {:error, promote_error()}
  def promote_definition(actor_id, %PromotionReview{} = review, opts) do
    permission_checker = Keyword.fetch!(opts, :permission_checker)

    tenant_classifier =
      Keyword.get(opts, :tenant_classifier, &PromotionPlan.default_tenant_classifier/1)

    event_appender = Keyword.fetch!(opts, :event_appender)
    activator = Keyword.get(opts, :activator)

    plan = Jason.decode!(review.serialised_plan)
    source_tenant_id = plan["source_tenant_id"]
    process_key = plan["process_key"]
    base_version = plan["base_version"]
    # Post-Decision-0006-D2 (REQ-064): was `review.tenant_id` -- that column no
    # longer exists on `promotion_reviews`. `plan["target_tenant_id"]` is the
    # same trusted value (PromotionPlan.t().target_tenant_id, already
    # serialised into this review at insert_review/2 time), not a new source.
    target_tenant_id = plan["target_tenant_id"]

    cond do
      not permission_checker.(actor_id, source_tenant_id) ->
        {:error, :forbidden}

      tenant_classifier.(source_tenant_id) == :production ->
        {:error, :invalid_promotion_source}

      true ->
        case do_promote_definition(
               actor_id,
               review.id,
               source_tenant_id,
               target_tenant_id,
               process_key,
               base_version,
               event_appender,
               activator
             ) do
          {:ok, result} ->
            {:ok, Map.take(result, [:source_definition_id, :target_definition_id, :process_key])}

          {:error, _} = error ->
            error
        end
    end
  end

  @doc """
  ENV-03/R10 entry point (NEW, REQ-077 design §9.5) — a promotion with no
  review at all: `test_tenant_id` + `process_key` straight into the target
  tenant, used by `Letflow.Routers.Tenants`' `POST
  /tenants/:test_tenant_id/promote/:process_key`. `promote_definition/3`
  takes a `%PromotionReview{}` and derives source/target/process_key/
  base_version by decoding `review.serialised_plan`; this function has none
  of that, so it re-implements the same permission/classifier gate and then
  shares `do_promote_definition/7`'s core with `review_id: nil` — see that
  function's own comment for why `nil` is safe to thread all the way through
  to the appended event's payload.

  `base_version` for the conflict re-check is read from the **target
  tenant's own current ACTIVE row** (`nil` when it has none) — R10 parses no
  request body, so there is nothing else it could be.
  """
  @spec promote_active_definition(
          actor_id :: Ecto.UUID.t(),
          source_tenant_id :: Ecto.UUID.t(),
          target_tenant_id :: Ecto.UUID.t(),
          process_key :: String.t(),
          opts :: promote_opts()
        ) ::
          {:ok,
           %{
             definition_id: Ecto.UUID.t(),
             version: String.t(),
             status: ProcessDefinition.status(),
             source_definition_id: Ecto.UUID.t()
           }}
          | {:error, promote_error()}
  def promote_active_definition(actor_id, source_tenant_id, target_tenant_id, process_key, opts) do
    permission_checker = Keyword.fetch!(opts, :permission_checker)

    tenant_classifier =
      Keyword.get(opts, :tenant_classifier, &PromotionPlan.default_tenant_classifier/1)

    event_appender = Keyword.fetch!(opts, :event_appender)
    activator = Keyword.get(opts, :activator)

    cond do
      not permission_checker.(actor_id, source_tenant_id) ->
        {:error, :forbidden}

      tenant_classifier.(source_tenant_id) == :production ->
        {:error, :invalid_promotion_source}

      true ->
        with {:ok, target_prefix} <- TenantProvisioning.schema_name_for_tenant(target_tenant_id) do
          base_version = current_active_version(process_key, target_prefix)

          case do_promote_definition(
                 actor_id,
                 nil,
                 source_tenant_id,
                 target_tenant_id,
                 process_key,
                 base_version,
                 event_appender,
                 activator
               ) do
            {:ok, %{new_row: new_row, source_definition_id: source_definition_id}} ->
              {:ok,
               %{
                 definition_id: new_row.id,
                 version: new_row.version,
                 status: new_row.status,
                 source_definition_id: source_definition_id
               }}

            {:error, _} = error ->
              error
          end
        end
    end
  end

  @spec current_active_version(String.t(), String.t()) :: String.t() | nil
  defp current_active_version(process_key, target_prefix) do
    case Repo.get_by(ProcessDefinition, [name: process_key, status: :active],
           prefix: target_prefix
         ) do
      nil -> nil
      %ProcessDefinition{version: version} -> version
    end
  end

  # Generalised core shared by promote_definition/3 and
  # promote_active_definition/5 (REQ-077 design §9.5) -- takes `review_id ::
  # Ecto.UUID.t() | nil` rather than a `%PromotionReview{}`, because the only
  # thing the original body needed from the review was `review.id`, threaded
  # down to append_promotion_event/9's event payload. `nil` there means "no
  # review exists for this promotion" (R10/ENV-03), and is admitted by the
  # DEFINITION_PROMOTED event-type schema from schema_version 2 on (REQ-140's
  # seed, widened by this requirement -- see tenant_provisioning.ex).
  # Zero behaviour change for promote_definition/3's own callers: its public
  # promote_result() contract (source_definition_id/target_definition_id/
  # process_key, exactly those 3 keys) is unchanged, produced by
  # Map.take/2 over this function's now-slightly-richer {:ok, ...} map.
  defp do_promote_definition(
         actor_id,
         review_id,
         source_tenant_id,
         target_tenant_id,
         process_key,
         base_version,
         event_appender,
         activator
       ) do
    with {:ok, source_prefix} <- TenantProvisioning.schema_name_for_tenant(source_tenant_id),
         {:ok, target_prefix} <- TenantProvisioning.schema_name_for_tenant(target_tenant_id),
         {:ok, source_row} <- fetch_source_definition(process_key, source_prefix),
         :ok <-
           PromotionConflict.reject_if_conflicts(actor_id, target_tenant_id, [process_key], [
             base_version
           ]),
         {:ok, new_row} <-
           write_target_definition(
             source_row,
             process_key,
             actor_id,
             target_prefix,
             %{
               review_id: review_id,
               source_tenant_id: source_tenant_id,
               target_tenant_id: target_tenant_id
             },
             activator
           ) do
      append_promotion_event(
        event_appender,
        target_prefix,
        actor_id,
        review_id,
        source_tenant_id,
        target_tenant_id,
        source_row,
        new_row,
        process_key
      )
    end
  end

  @spec fetch_source_definition(String.t(), String.t()) ::
          {:ok, ProcessDefinition.t()} | {:error, :source_definition_missing}
  defp fetch_source_definition(process_key, source_prefix) do
    case Repo.get_by(ProcessDefinition, [name: process_key, status: :active],
           prefix: source_prefix
         ) do
      nil -> {:error, :source_definition_missing}
      %ProcessDefinition{} = row -> {:ok, row}
    end
  end

  # Design §3.2 steps 7-8, both inside one Repo.transaction/1: insert the
  # target row (still :draft, uq_definition_version mapped to
  # :duplicate_version), then the guarded deprecate-then-activate swap
  # (PD-03 ordering). No longer takes target_tenant_id (Decision 0006 D2,
  # REQ-064) -- it was only ever forwarded to deprecate_previous_active/3's
  # now-removed tenant_id filter; target_prefix alone already scopes every
  # write in this function to the correct tenant schema.
  #
  # ISS-0733 GAP A (design `lib/letflow/design/iss0733-promotion-audit-and-
  # platform-events-read.md` §1) -- new step 8(c), inside this same
  # transaction: Audit.insert_entry/3 for the version-pointer swap this
  # function just performed, using `audit_context`'s review_id/
  # source_tenant_id/target_tenant_id (do_promote_definition/7's own
  # arguments, no new data threaded in from further up the call chain).
  # {:error, reason} -> Repo.rollback(reason), the exact pattern
  # activate_draft_row/4 (definitions.ex) already uses for its own
  # Audit.insert_entry/3 call.
  @spec write_target_definition(
          ProcessDefinition.t(),
          String.t(),
          Ecto.UUID.t(),
          String.t(),
          %{
            review_id: Ecto.UUID.t() | nil,
            source_tenant_id: Ecto.UUID.t(),
            target_tenant_id: Ecto.UUID.t()
          },
          Letflow.Engine.EntityPort.activator() | nil
        ) ::
          {:ok, ProcessDefinition.t()}
          | {:error, :duplicate_version | Ecto.Changeset.t() | term()}
          | {:error, {:transaction_failed, Exception.t()}}
  defp write_target_definition(
         source_row,
         process_key,
         actor_id,
         target_prefix,
         audit_context,
         activator
       ) do
    attrs = %{
      name: process_key,
      version: source_row.version,
      description: source_row.description,
      stage: source_row.stage,
      graph: source_row.graph,
      created_by: actor_id
    }

    try do
      Repo.transaction(fn ->
        %ProcessDefinition{}
        |> ProcessDefinition.create_changeset(attrs)
        |> Repo.insert(prefix: target_prefix)
        |> case do
          {:ok, new_row} ->
            # GH 2534 PR 7c-1 (decision 0053 D2, F8; design 4.5): the promoted graph's script
            # bindings are checked in the TARGET prefix, inside this transaction, before the
            # status write. GH #2587 PR A1b (design 2A.3): the reserved-namespace references
            # first, so a refused graph takes no script-row lock.
            with :ok <- Letflow.Definitions.check_reserved_references(new_row),
                 :ok <- Letflow.Definitions.check_entity_writes(new_row, target_prefix, activator),
                 :ok <- Letflow.Definitions.check_script_bindings(new_row, target_prefix) do
              :ok
            else
              {:error, reason} -> Repo.rollback(reason)
            end

            deprecate_previous_active(process_key, target_prefix)
            activated_row = activate_new_definition(new_row, target_prefix, activator)

            case Audit.insert_entry(
                   Repo,
                   promotion_audit_attrs(
                     actor_id,
                     activated_row,
                     source_row,
                     process_key,
                     audit_context
                   ),
                   target_prefix
                 ) do
              {:ok, _entry} -> activated_row
              {:error, reason} -> Repo.rollback(reason)
            end

          {:error, %Ecto.Changeset{} = changeset} ->
            if duplicate_version_error?(changeset) do
              Repo.rollback(:duplicate_version)
            else
              Repo.rollback(changeset)
            end
        end
      end)
    rescue
      exception -> {:error, {:transaction_failed, exception}}
    end
  end

  # ISS-0733 design §1.4 -- reuses append_promotion_event/9's own
  # event_attrs shape field-for-field as `after_state`, not a second,
  # independently-drifting schema. `before_state: nil` and `trace_id: nil`
  # are both deliberate (design §1.4), matching definitions.ex's own
  # "no meaningful before-state" precedent (record_definition_audit/5's
  # `"definition.create"` call).
  @spec promotion_audit_attrs(
          Ecto.UUID.t(),
          ProcessDefinition.t(),
          ProcessDefinition.t(),
          String.t(),
          %{
            review_id: Ecto.UUID.t() | nil,
            source_tenant_id: Ecto.UUID.t(),
            target_tenant_id: Ecto.UUID.t()
          }
        ) :: Audit.entry_attrs()
  defp promotion_audit_attrs(actor_id, new_row, source_row, process_key, %{
         review_id: review_id,
         source_tenant_id: source_tenant_id,
         target_tenant_id: target_tenant_id
       }) do
    %{
      actor_id: actor_id,
      action: "definition.promote",
      resource_type: "definition",
      resource_id: new_row.id,
      before_state: nil,
      after_state: %{
        event_type: "DEFINITION_PROMOTED",
        actor_id: actor_id,
        review_id: review_id,
        source_tenant_id: source_tenant_id,
        target_tenant_id: target_tenant_id,
        source_definition_id: source_row.id,
        target_definition_id: new_row.id,
        process_key: process_key
      },
      trace_id: nil
    }
  end

  # Step 8(a) -- deprecate whatever row is currently active for this
  # process_key, within target_prefix's own tenant schema. 0 or 1 row, never
  # more -- uq_active_definition guarantees at most one. Post-Decision-0006-D2
  # (REQ-064): was additionally filtered on `d.tenant_id == ^target_tenant_id`;
  # that column no longer exists on `process_definitions` -- `target_prefix`
  # (the schema this Repo.update_all/3 call is scoped to via `prefix:`) already
  # confines this query to exactly one tenant, so the extra predicate was
  # redundant with the schema boundary and is dropped along with the column.
  defp deprecate_previous_active(process_key, target_prefix) do
    from(d in ProcessDefinition,
      where: d.name == ^process_key and d.status == :active
    )
    |> Repo.update_all([set: [status: :deprecated]], prefix: target_prefix)
  end

  # Step 8(b) -- activate the row this function itself just inserted, still
  # :draft (create_changeset/2 never casts :status). Exactly 1 row, always --
  # this is the same transaction that inserted it, nothing else can have
  # touched it yet.
  defp activate_new_definition(new_row, target_prefix, activator) do
    query =
      from(d in ProcessDefinition, where: d.id == ^new_row.id and d.status == :draft, select: d)

    # GH #2587 PR B1: the promoting principal's authority, recorded in the same write that
    # activates the row (NULL for a graph without `entity_writes`).
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    activated_by = Letflow.Definitions.entity_writes_activated_by(new_row, activator, now)

    {1, [activated_row]} =
      Repo.update_all(query, [set: [status: :active, activated_by: activated_by]],
        prefix: target_prefix
      )

    activated_row
  end

  @spec duplicate_version_error?(Ecto.Changeset.t()) :: boolean()
  defp duplicate_version_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, opts}} ->
      Keyword.get(opts, :constraint) == :unique and
        Keyword.get(opts, :constraint_name) == "uq_definition_version"
    end)
  end

  # Step 9 -- after the transaction commits (design §3.2 step 9, OQ-1: no
  # built-in default, no nesting inside the transaction above).
  defp append_promotion_event(
         event_appender,
         target_prefix,
         actor_id,
         review_id,
         source_tenant_id,
         target_tenant_id,
         source_row,
         new_row,
         process_key
       ) do
    event_attrs = %{
      event_type: "DEFINITION_PROMOTED",
      actor_id: actor_id,
      review_id: review_id,
      source_tenant_id: source_tenant_id,
      target_tenant_id: target_tenant_id,
      source_definition_id: source_row.id,
      target_definition_id: new_row.id,
      process_key: process_key
    }

    case event_appender.(event_attrs, target_prefix) do
      {:ok, _} ->
        {:ok,
         %{
           source_definition_id: source_row.id,
           target_definition_id: new_row.id,
           process_key: process_key,
           new_row: new_row
         }}

      {:error, _reason} = error ->
        error
    end
  end

  @type apply_review_error ::
          :review_not_found
          | :digest_mismatch
          | :invalid_transition
          | :assertion_run_missing
          | :assertion_run_digest_mismatch
          | :assertion_run_in_progress
          | :assertion_run_failed
          | {:promotion_failed, promote_error()}

  @doc """
  R7's apply *orchestration* (NEW, REQ-077 design §9.3) — `PromotionReviewStore`
  deliberately does not call `promote_definition/3` (see its own moduledoc); this
  is that orchestrator. Five steps, each short-circuiting:

    1. `PromotionReviewStore.get_review/2`. `{:error, :review_not_found}` ->
       return unchanged. Nothing written.
    2. `PromotionDigest.verify_digest/2` (constant-time). Mismatch ->
       `{:error, :digest_mismatch}`. Nothing written.
    3. `review.status == :approved`? No -> `{:error, :invalid_transition}`.
       Nothing written, and critically no `process_definitions` row touched --
       this is what makes AC4's "does not re-apply" true, not
       `mark_review_applied/2`'s own status guard (which would only fire AFTER
       the promotion already committed).
    4. `verify_rehearsed/2` (NEW, ISS-0732 design §2, amended §9) -- a
       matching-digest, terminal, zero-failure `promotion_assertion_runs` row
       must exist for this review before the promotion may proceed:
       * no run recorded at all -> `{:error, :assertion_run_missing}`.
       * latest run's `plan_digest` doesn't match the digest being applied
         (constant-time compare) -> `{:error, :assertion_run_digest_mismatch}`.
       * latest matching-digest run is still `status: :running` (in-flight) ->
         `{:error, :assertion_run_in_progress}`.
       * latest matching-digest, terminal run has `assertions_failed > 0` ->
         `{:error, :assertion_run_failed}`.
       Nothing written on any of these four paths.
    5. `promote_definition/3`.
       * `{:error, reason}` -> `PromotionReviewStore.mark_review_failed/2`
         (result ignored — a concurrent transition there must not mask the
         real failure), then `{:error, {:promotion_failed, reason}}`.
       * `{:ok, result}` -> `PromotionReviewStore.mark_review_applied/2`.
         `{:error, :invalid_transition}` there is treated as success too
         (OQ-8): the promotion already durably committed by this point, and
         reporting failure for an operation that succeeded would be worse
         than a stale status — the only way this fires is a concurrent
         transition moving the row out of `:approved` after step 3.
  """
  @spec apply_review(
          review_id :: Ecto.UUID.t() | String.t(),
          actor_id :: Ecto.UUID.t(),
          plan_digest :: String.t(),
          opts :: [
            prefix: String.t(),
            permission_checker: (Ecto.UUID.t(), Ecto.UUID.t() -> boolean()),
            tenant_classifier: (Ecto.UUID.t() -> :production | :test),
            event_appender: (map(), String.t() -> {:ok, term()} | {:error, term()})
          ]
        ) ::
          {:ok,
           %{
             review_id: Ecto.UUID.t(),
             source_definition_id: Ecto.UUID.t(),
             target_definition_id: Ecto.UUID.t(),
             process_key: String.t()
           }}
          | {:error, apply_review_error()}
  def apply_review(review_id, actor_id, plan_digest, opts) do
    with {:ok, review} <- PromotionReviewStore.get_review(review_id, opts),
         :ok <- verify_apply_digest(review, plan_digest),
         :ok <- verify_approved(review),
         :ok <- verify_rehearsed(review, plan_digest, opts) do
      do_apply_review(review, actor_id, opts)
    end
  end

  defp verify_apply_digest(review, plan_digest) do
    if PromotionDigest.verify_digest(review.plan_digest, plan_digest) do
      :ok
    else
      {:error, :digest_mismatch}
    end
  end

  defp verify_approved(%PromotionReview{status: :approved}), do: :ok
  defp verify_approved(_review), do: {:error, :invalid_transition}

  # ISS-0732 design §2.1 (amended §9) -- gates apply_review/4 on a
  # matching-digest, terminal (not :running), zero-failure assertion run.
  # Pure read-then-branch, no writes, same shape as verify_apply_digest/2
  # and verify_approved/1 above. The status check (step 3) runs strictly
  # before the assertions_failed check (step 4, unchanged from the original
  # step 3) -- see design §9.2's rationale: a :running row's
  # assertions_failed is always 0 by construction, so checking it first
  # would never catch an in-flight rehearsal.
  @spec verify_rehearsed(
          review :: PromotionReview.t(),
          plan_digest :: String.t(),
          opts :: [prefix: String.t()]
        ) :: :ok | {:error, apply_review_error()}
  defp verify_rehearsed(review, plan_digest, opts) do
    case Letflow.Definitions.get_latest_assertion_run(review.id, opts) do
      {:error, :not_found} ->
        {:error, :assertion_run_missing}

      {:ok, assertion_run} ->
        if PromotionDigest.verify_digest(assertion_run.plan_digest, plan_digest) do
          if assertion_run.status not in [:running] do
            if assertion_run.assertions_failed == 0 do
              :ok
            else
              {:error, :assertion_run_failed}
            end
          else
            {:error, :assertion_run_in_progress}
          end
        else
          {:error, :assertion_run_digest_mismatch}
        end
    end
  end

  defp do_apply_review(review, actor_id, opts) do
    case promote_definition(actor_id, review, opts) do
      {:ok, result} ->
        # OQ-8: a concurrent {:error, :invalid_transition} here does not undo
        # an already-durable promotion -- deliberately ignored.
        PromotionReviewStore.mark_review_applied(review.id, opts)
        {:ok, Map.put(result, :review_id, review.id)}

      {:error, reason} ->
        # Result ignored -- a concurrent transition here must not mask the
        # real failure this function is about to return.
        PromotionReviewStore.mark_review_failed(review.id, opts)
        {:error, {:promotion_failed, reason}}
    end
  end
end
