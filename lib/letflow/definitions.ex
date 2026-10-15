defmodule Letflow.Definitions do
  @moduledoc """
  Context module for definition-related read/compute functions. See
  `lib/letflow/design/req041-pack-update-diff-schema.md` §5.3 for
  `compute_pack_update_plan/5`'s full reasoning.

  **This file did not exist before REQ-041.** The design (§5.3) names
  `Letflow.Definitions` as "the existing context module this batch's
  functions all attach to," citing `req035` §5.1 as having already
  established it as the expected home for `compute_pack_update_plan/5` by
  name — but no `lib/letflow/definitions.ex` context-module file was actually
  present in this codebase prior to this requirement (only schema submodules
  under `lib/letflow/definitions/`, e.g. `ProcessDefinition`,
  `PromotionReview`). REQ-036, whose `compute_promotion_plan/5` would have
  been this module's first function, is still `status: pending`
  (`docs/requirements.yaml`). REQ-041 creates this file; noted here as a
  deviation-from-assumption worth flagging honestly, not a silent one — the
  module name, namespace and this function's placement all match the design
  exactly, only the file's prior existence was assumed incorrectly.

  ## Scope

  `compute_pack_update_plan/5` and `classify_artefact/3` (REQ-041), `create/2`,
  `get_by_id/2`, `get_active_by_name/2`, `list/2`, `activate/2`, `deprecate/2`,
  `archive/2` (REQ-030), and `search/2` (REQ-042) together make up this module's
  current public API. See `lib/letflow/design/req030-definition-store-crud.md` for
  the full design the REQ-030 functions implement, and
  `lib/letflow/design/search.md` for `search/2`'s.

  ## `tenant_id` is always derived, never accepted (REQ-030)

  `create/2`'s `attrs` never accepts a `:tenant_id` (or `"tenant_id"`) key -- a caller
  supplying one gets `{:error, :tenant_id_not_accepted}`, not a silently-overridden value.
  `tenant_id` is always derived from `opts[:prefix]` via
  `Letflow.TenantProvisioning.tenant_id_for_schema_name/1`, mirroring
  `Letflow.EventStore.append/2`'s identical contract (see
  `lib/letflow/design/req025-event-append.md` and
  `docs/migration/decisions/0003-ecto-schema-strategy.md`'s 2026-08-17 addendum).

  ## `activate/2`'s `service_scope_validator` option -- the SVC-03 integration point (REQ-031)

  `activate/2` accepts an optional `:service_scope_validator` key in its `opts`, a 2-arity
  function `(Letflow.Definitions.Graph.t(), tenant_id) -> :ok | {:error, term()}` or `nil`
  (the default). When present, it is called once, only when the target definition's current
  status is `:draft` (never on the already-active no-op path, never on a rejected
  non-draft transition), after the row lock is acquired and before either of the two
  transition UPDATEs run. A `{:error, reason}` return aborts the whole activation with
  `{:error, {:service_scope_violation, reason}}` and writes nothing. **This module builds
  only the injection point** -- the hook's own logic (walking SERVICE_TASK nodes, checking
  tenant/service/plugin scope) is REQ-031's job, not implemented here.

  ## `apply_promotion_assertion_rerun/6`'s gate condition and crash-safety scope (REQ-040)

  The apply pipeline (REQ-037's `mark_review_applied/2` path) gates on this function's
  recorded `assertions_failed == 0` -- NOT on `status == "passed"`. These are not the same
  check: a passing assertion replay whose sandbox teardown itself fails is recorded as
  `status = :teardown_failed` with `assertions_failed` still `0` (the real replay found
  zero failures; only the *teardown* failed, tracked separately via a
  `PROMOTION_ASSERTION_TEARDOWN_FAILED` event, never folded into the assertion counts). A
  `teardown_failed` row is therefore a **green gate** -- a caller that checks
  `status == :passed` instead of `assertions_failed == 0` will read this outcome
  backwards and incorrectly block a promotion that should proceed.

  Crash safety: the claim -> load-fixtures -> replay -> release -> record-outcome span is
  wrapped in a single `try/rescue`. This covers three exit classes -- normal completion,
  a typed error return from any step, and a raised exception anywhere in that span -- and
  on all three, `SandboxPool.release/2` is attempted and the `promotion_assertion_runs`
  row is written with fail-closed accounting (`assertions_failed >= 1`) rather than left
  stuck at `status = :running`. It does **not** cover a hard process kill
  (`Process.exit(pid, :kill)`), a BEAM node crash, or `System.halt/0` -- none of these run
  a `rescue` clause, so a sandbox claimed and a row left `:running` at the moment one of
  those events fires is neither released nor updated by this function. This residual gap
  is a disclosed, deferred limitation, not an oversight: the concrete mitigation (a
  background reaper sweeping stale `:running` rows and orphaned sandbox schemas, mirroring
  R-Co's `reclaimLeakedSandboxes`) is not built here and is left to a dedicated follow-up
  requirement -- the same deferral `Letflow.SandboxPool`'s own moduledoc already carries
  for the analogous owner-crash-detection gap on an already-claimed sandbox.

  ## `search/2` -- full-text search over `name`/`description` (REQ-042)

  PROVENANCE (historical, not current decision authority):
  `search/2` (REQ-042) adds definition full-text search over `process_definitions`'
  `name`/`description` columns via `ILIKE` ranking, ported from `store.zig`'s
  `Store.search()` per `src/design/definition.md`'s PD-10 section. **PD-10 states
  explicitly that search lives inside the existing store -- no new Zig source file or SQL
  migration is required**, and this port adds zero new `priv/repo/migrations/` files and
  zero new indexes (no `idx_def_name`, no GIN/`tsvector` index) -- the query runs against
  `process_definitions` exactly as REQ-027 shipped it.

  ## `delta/2` -- `GET /definitions/delta` cursor semantics (REQ-125, MOB-3)

  See `lib/letflow/design/req125-definitions-delta-sync.md` for the full design.
  `since` is a per-tenant-schema **monotonically increasing integer**
  (`process_definitions.sequence_number`), never a wall-clock timestamp.

  Clock skew is exactly the failure mode this endpoint runs under: a mobile
  device warming an offline cache compares its last-seen watermark against the
  server on every subsequent sync, often after being offline for hours or
  days, on hardware whose clock is not NTP-disciplined the way the server's
  is. Had `since` been `updated_at` (a server-clock-stamped column compared
  against a value the *device* last stored), every device clock's drift,
  timezone misconfiguration, or leap-second smear would become a correctness
  bug in what the device believes it already has. A monotonic integer has no
  notion of "now" on either side -- it is a pure watermark, compared with `>`,
  never interpreted as elapsed time. The counter (`definition_sequence`,
  mirroring `Letflow.EventStore`'s `instance_sequence` at tenant-schema
  granularity instead of per-instance granularity) is server-assigned and
  bumped inside the same transaction as the row mutation it sequences, so "the
  cursor advanced" and "a row actually changed" can never disagree.

  A `since` that "predates retained history" is not a distinguishable error
  state here, unlike `Letflow.Api.Pagination`'s minted cursors (which expire
  24h *by design*): `definition_sequence`'s counter has no expiry and no
  pruning, so `since: nil` (or `0`) is the well-defined "give me full history"
  case (every row that exists), not a special-cased reset response. Only
  syntactic validity is checked -- a negative integer or a non-integer string
  is `{:error, :invalid_since}` (400); a `since` numerically larger than the
  tenant's actual high-water mark simply returns an empty delta,
  indistinguishable from "already caught up," which is deliberately the safe
  behaviour (never fabricates a "full resync required" signal from a value
  that could equally mean "already current").
  """

  import Ecto.Query
  import Bitwise

  alias Ecto.Multi
  alias Letflow.Api.Pagination
  alias Letflow.Audit
  alias Letflow.Definitions.Activator
  alias Letflow.Definitions.DefinitionSequence
  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.JsonSchemaShape
  alias Letflow.Definitions.PackUpdateResolution
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.PromotionArtifact
  alias Letflow.Definitions.PromotionAssertionRun
  alias Letflow.Definitions.PromotionReview
  alias Letflow.Definitions.PromotionReviewStore
  alias Letflow.Definitions.SemanticValidation
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.ValidationWarnings
  alias Letflow.Engine.EntityPort
  alias Letflow.Engine.VariableSchema
  alias Letflow.Repo
  alias Letflow.SandboxPool
  alias Letflow.SandboxPool.FixtureLoader
  alias Letflow.SandboxPool.SandboxClaim
  alias Letflow.TenantProvisioning

  @type artefact_key :: %{artefact_type: String.t(), artefact_id: String.t()}
  @type artefact_input :: %{
          artefact_type: String.t(),
          artefact_id: String.t(),
          # canonical-JSON text, caller's responsibility -- see
          # classify_artefact/3's @doc and design §5.4/OQ-1.
          content: String.t()
        }
  @type classification :: :unchanged | :clean_update | :local_only | :conflict

  @type plan_entry :: %{
          artefact_type: String.t(),
          artefact_id: String.t(),
          classification: classification(),
          # nil iff no solution_pack_artefact_bases row -- AC2.
          base: String.t() | nil,
          # nil iff artefact absent from theirs_artefacts.
          theirs: String.t() | nil,
          # nil iff artefact absent from incoming_artefacts.
          incoming: String.t() | nil,
          # only meaningful when classification == :conflict; true iff a
          # matching pack_update_resolutions row exists (AC4) -- always false
          # for non-conflict entries.
          resolved: boolean()
        }

  @type plan :: %{
          tenant_id: Ecto.UUID.t(),
          pack_id: String.t(),
          incoming_version: String.t(),
          entries: [plan_entry()],
          has_unresolved_conflicts: boolean()
        }

  # ---------------------------------------------------------------------------------
  # REQ-030 types -- lib/letflow/design/req030-definition-store-crud.md §4.0
  # ---------------------------------------------------------------------------------

  @type opts :: [prefix: String.t()]

  @type status :: ProcessDefinition.status()

  @type service_scope_validator_fun ::
          (Graph.t(), tenant_id :: Ecto.UUID.t() -> :ok | {:error, term()})

  @type activate_opts :: [
          prefix: String.t(),
          service_scope_validator: service_scope_validator_fun() | nil,
          # GH #2587 PR B1 (decision 0054 D4a): the activator authority a graph with
          # `entity_writes` is activated under; absent (nil) refuses such a graph.
          activator: EntityPort.activator() | nil
        ]

  @typedoc """
  One `entity_writes` refusal of a graph (GH #2587 PR B1): the node, the declared line index
  (0 for a node-level refusal) and a stable atom code. No field name, no value.
  """
  @type entity_writes_violation :: %{
          node_id: String.t(),
          index: non_neg_integer(),
          code: atom()
        }

  @type common_error ::
          {:error, :invalid_schema_name}
          | {:error, {:transaction_failed, term()}}
          # REQ-125 -- raised by assign_definition_sequence/2's locking
          # protocol (mirrors Letflow.EventStore.assign_sequence/3's own
          # {:sequence_conflict, term()} shape); shared across create/2,
          # activate/2, deprecate/2, archive/2, all of which now assign a
          # definition_sequence number inside their existing transaction.
          | {:error, {:sequence_conflict, term()}}

  @type create_attrs :: %{
          required(:name) => String.t(),
          required(:version) => String.t(),
          optional(:description) => String.t() | nil,
          required(:graph) => map(),
          required(:created_by) => Ecto.UUID.t(),
          optional(:stage) => String.t() | nil
        }

  @type create_error ::
          {:error, :tenant_id_not_accepted}
          | {:error, :initial_status_not_draft}
          | {:error, :name_invalid}
          | {:error, :version_empty}
          | {:error, :graph_structure_invalid}
          | {:error, {:graph_validation_failed, [Graph.Violation.t()]}}
          | {:error, :duplicate_name_version}
          | {:error, Ecto.Changeset.t()}
          | common_error()

  # ---------------------------------------------------------------------------------
  # REQ-082 types -- write/lifecycle routes (design §4)
  # ---------------------------------------------------------------------------------

  @typedoc """
  Attrs for `update/3` -- the SINGLE shared backing function for both
  `PUT /definitions/:id` (full replace, every key present) and
  `PATCH /definitions/:id` (partial, only the keys the caller wants changed).
  A key's PRESENCE, not its value, controls whether that column is touched --
  `update/3` builds its `Repo.update_all/3` `:set` list from
  `Map.has_key?/2`, so `%{description: nil}` clears the column while omitting
  `:description` entirely leaves it unchanged. The router is responsible for
  this distinction: PUT's `FieldConstraint` schema requires every key present
  (so this map always carries all five), PATCH's makes every key optional.
  """
  @type update_attrs :: %{
          optional(:name) => String.t(),
          optional(:version) => String.t(),
          optional(:description) => String.t() | nil,
          optional(:graph) => map(),
          optional(:stage) => String.t() | nil
        }

  @type update_error ::
          {:error, :not_found}
          | {:error, :not_draft}
          | {:error, :name_invalid}
          | {:error, :version_empty}
          | {:error, :graph_structure_invalid}
          | {:error, {:graph_validation_failed, [Graph.Violation.t()]}}
          | {:error, :duplicate_name_version}
          | {:error, variable_schema_error()}
          | common_error()

  @type hard_delete_error ::
          {:error, :not_found} | {:error, :not_draft} | common_error()

  @type list_filters :: %{
          optional(:name) => String.t() | nil,
          optional(:status) => status() | nil,
          optional(:stage) => String.t() | nil,
          optional(:after_created) => DateTime.t() | nil,
          optional(:limit) => pos_integer() | nil
        }

  # ---------------------------------------------------------------------------------
  # REQ-042 types -- lib/letflow/design/search.md §3
  # ---------------------------------------------------------------------------------

  @type search_opts :: [
          prefix: String.t(),
          limit: pos_integer() | nil,
          offset: non_neg_integer() | nil
        ]

  @type search_result :: %{
          definition: ProcessDefinition.t(),
          # 3.0 (exact name match), 2.0 (partial name match) or 1.0
          # (description-only match) -- see search/2's @doc, never any other value.
          rank: float()
        }

  @type search_error ::
          {:error, :query_empty}
          | {:error, :query_too_long}
          # ISS search_paginated exception hardening -- search_paginated/3's own
          # try/rescue catch-all, mirroring activate/2's {:transaction_failed, _}
          # idiom but tagged distinctly: search_paginated/3 runs a single
          # Repo.all/2, never Repo.transaction/1, so ":query_failed" names the
          # actual failure class. Deliberately NOT folded into common_error() --
          # see lib/letflow/design/iss-0739-search-paginated-exception-hardening.md
          # §2.2 (note: that design doc's own filename/ISS number collided with
          # an unrelated issue independently filed under the same ID by a
          # concurrent agent run -- flagged for ORCH/DOC-UPDATER to renumber;
          # the technical content below is unaffected by that collision).
          | {:error, {:query_failed, term()}}
          | common_error()

  # ---------------------------------------------------------------------------------
  # REQ-081 types -- lib/letflow/design/req081-definition-routes-read.md §3
  # ---------------------------------------------------------------------------------

  # `page_size` is REQUIRED here, not optional -- the design doc's own @type
  # says `optional(:page_size)` but its prose (§3.1) describes an
  # already-validated, required page_size the way `Letflow.Instances.list/2`
  # receives it (`Map.fetch!/2`, not `Map.get/2` with a default). This
  # follows the prose/idiom, not the type declaration -- flagged by
  # CODE-DESIGN-VALIDATOR as a minor gap, resolved here per ELIXIR-DEV's
  # handoff instructions.
  @type list_paginated_filters :: %{
          optional(:name) => String.t() | nil,
          optional(:status) => status() | nil,
          optional(:stage) => String.t() | nil,
          optional(:cursor) => String.t() | nil,
          page_size: pos_integer()
        }

  @type paginated_result :: %{items: [ProcessDefinition.t()], next_cursor: String.t() | nil}

  @type search_paginated_opts :: [prefix: String.t()]

  @type search_paginated_result :: %{items: [search_result()], next_cursor: String.t() | nil}

  # ---------------------------------------------------------------------------------
  # REQ-125 types -- lib/letflow/design/req125-definitions-delta-sync.md §6.1
  # ---------------------------------------------------------------------------------

  @type delta_opts :: [prefix: String.t()]

  @typedoc """
  `next_since` is documented `pos_integer()` by the design doc's own §6.1
  literal type. Implemented here as `non_neg_integer()` instead -- a
  deliberate, flagged divergence, not a silent one: a tenant with zero
  `process_definitions` rows and `since: nil` legitimately returns
  `next_since: 0` (no `definition_sequence` row exists yet to read a
  high-water mark from, and `0` is `since`'s own well-defined "give me full
  history" floor per this module's moduledoc). `0` is not a `pos_integer()`,
  so the design doc's literal type cannot hold for that reachable case.
  Flagged for REVIEWER at Step 2d rather than silently narrowing the type to
  paper over it.
  """
  @type delta_result :: %{
          items: [ProcessDefinition.t()],
          next_since: non_neg_integer()
        }

  @type delta_error ::
          {:error, :invalid_since}
          | common_error()

  @doc """
  Computes a solution-pack update three-way diff plan for one tenant's
  install of one pack against an offered incoming version, per
  `lib/letflow/design/req041-pack-update-diff-schema.md` §5.3.

  Read-only — performs no mutation (INV-PU-5). Queries
  `solution_pack_artefact_bases` (the `base` lookup, by `(tenant_id, pack_id,
  artefact_type, artefact_id)`) and `pack_update_resolutions` (the
  `has_unresolved_conflicts` lookup, by `(tenant_id, pack_id, target_version:
  incoming_version, artefact_type, artefact_id)`) but writes neither those nor
  `solution_pack_installs`.

  `theirs_artefacts`/`incoming_artefacts` are caller-supplied — no real
  install/export path exists yet to source them from (SOL-01/02/03, unscoped).
  `base` is never caller-supplied: it is always looked up from
  `solution_pack_artefact_bases` by this function itself, because AC2's core
  assertion (an artefact with no matching base row classifies `:conflict`) is
  a statement about this function's own DB-lookup behavior, not about a value
  a caller chooses to omit.

  The artefact set processed is the union of `theirs_artefacts`' and
  `incoming_artefacts`' `{artefact_type, artefact_id}` keys, in first-seen
  order (theirs first, then incoming) — an artefact named in neither list is
  not represented in the returned plan at all.

  Returns `{:error, :empty_artefact_set}` when both `theirs_artefacts` and
  `incoming_artefacts` are `[]` — an empty result would otherwise be
  ambiguous between "nothing changed" and "caller passed no data by
  mistake" (mirrors REQ-036's `compute_promotion_plan/5`'s empty-plan error;
  design §5.3, flagged there as this design's own addition, not a literal
  REQ-041 acceptance-criterion mandate).
  """
  @spec compute_pack_update_plan(
          tenant_id :: Ecto.UUID.t(),
          pack_id :: String.t(),
          incoming_version :: String.t(),
          theirs_artefacts :: [artefact_input()],
          incoming_artefacts :: [artefact_input()]
        ) :: {:ok, plan()} | {:error, :empty_artefact_set}
  def compute_pack_update_plan(_tenant_id, _pack_id, _incoming_version, [], []) do
    {:error, :empty_artefact_set}
  end

  def compute_pack_update_plan(
        tenant_id,
        pack_id,
        incoming_version,
        theirs_artefacts,
        incoming_artefacts
      ) do
    theirs_by_key = index_by_key(theirs_artefacts)
    incoming_by_key = index_by_key(incoming_artefacts)

    keys =
      (theirs_artefacts ++ incoming_artefacts)
      |> Enum.map(&{&1.artefact_type, &1.artefact_id})
      |> Enum.uniq()

    entries =
      Enum.map(keys, fn {artefact_type, artefact_id} = key ->
        base = fetch_base(tenant_id, pack_id, artefact_type, artefact_id)
        theirs = Map.get(theirs_by_key, key)
        incoming = Map.get(incoming_by_key, key)
        classification = classify_artefact(base, theirs, incoming)

        resolved =
          classification == :conflict and
            resolution_exists?(tenant_id, pack_id, incoming_version, artefact_type, artefact_id)

        %{
          artefact_type: artefact_type,
          artefact_id: artefact_id,
          classification: classification,
          base: base,
          theirs: theirs,
          incoming: incoming,
          resolved: resolved
        }
      end)

    has_unresolved_conflicts =
      Enum.any?(entries, &(&1.classification == :conflict and not &1.resolved))

    {:ok,
     %{
       tenant_id: tenant_id,
       pack_id: pack_id,
       incoming_version: incoming_version,
       entries: entries,
       has_unresolved_conflicts: has_unresolved_conflicts
     }}
  end

  @doc """
  Classifies one artefact's three-way diff, per
  `lib/letflow/design/req041-pack-update-diff-schema.md` §5.3's truth table.
  Pure — no I/O, independently testable without DB fixtures or the full
  5-argument `compute_pack_update_plan/5` orchestration.

  `base`/`theirs`/`incoming` are compared by **byte-level string equality**
  over content that MUST already be canonical-JSON text by the time it
  reaches this function (sorted keys, no insignificant whitespace) —
  REQ-041's own description says this comparison uses "same normalization as
  REQ-036's plan digest," but REQ-036's `compute_plan_digest/1` is
  `status: pending` and has no shared canonicalization helper to call yet
  (design §5.4, OQ-1). This function does not parse, re-serialize, or
  normalize anything itself, and does not reimplement REQ-036's
  canonicalization as a private duplicate — that would risk drifting from
  REQ-036's real implementation once it ships.

  `nil` is never treated as equal to any other value, including another
  `nil` compared against a third non-nil value. A `nil` `base` (no matching
  `solution_pack_artefact_bases` row) always classifies `:conflict`,
  regardless of `theirs`/`incoming` — REQ-041 acceptance criterion 2 /
  INV-PU-2, "cannot prove no modification" (PRM-09 AC5).

  | `base` | `base == theirs` | `base == incoming` | Result |
  |---|---|---|---|
  | non-nil | true | true | `:unchanged` |
  | non-nil | true | false | `:clean_update` |
  | non-nil | false | true | `:local_only` |
  | non-nil | false | false | `:conflict` |
  | `nil` | — | — | `:conflict` (always) |
  """
  @spec classify_artefact(
          base :: String.t() | nil,
          theirs :: String.t() | nil,
          incoming :: String.t() | nil
        ) :: classification()
  def classify_artefact(nil, _theirs, _incoming), do: :conflict
  def classify_artefact(base, base, base), do: :unchanged
  def classify_artefact(base, base, _incoming), do: :clean_update
  def classify_artefact(base, _theirs, base), do: :local_only
  def classify_artefact(_base, _theirs, _incoming), do: :conflict

  defp index_by_key(artefacts) do
    Map.new(artefacts, fn %{artefact_type: type, artefact_id: id, content: content} ->
      {{type, id}, content}
    end)
  end

  defp fetch_base(tenant_id, pack_id, artefact_type, artefact_id) do
    SolutionPackArtefactBase
    |> Repo.get_by(
      tenant_id: tenant_id,
      pack_id: pack_id,
      artefact_type: artefact_type,
      artefact_id: artefact_id
    )
    |> case do
      nil -> nil
      %SolutionPackArtefactBase{base_content: base_content} -> base_content
    end
  end

  defp resolution_exists?(tenant_id, pack_id, target_version, artefact_type, artefact_id) do
    not is_nil(
      Repo.get_by(PackUpdateResolution,
        tenant_id: tenant_id,
        pack_id: pack_id,
        target_version: target_version,
        artefact_type: artefact_type,
        artefact_id: artefact_id
      )
    )
  end

  # ===================================================================================
  # REQ-030 -- Definition store CRUD
  # lib/letflow/design/req030-definition-store-crud.md
  # ===================================================================================

  @doc """
  Creates a new DRAFT process definition, per PD-01/PD-02/PD-05/PD-06.

  `tenant_id` is never accepted in `attrs` -- it is always derived from
  `opts[:prefix]` (see this module's moduledoc). `attrs[:graph]` must pass all three
  of `Letflow.Definitions.Graph.validate_graph/1`, `validate_node_attributes/1` and
  `validate_edge_conditions/1` before anything is written (INV-DS-3): on the first
  failing phase, returns `{:error, {:graph_validation_failed, violations}}` and writes
  zero rows.

  Two concurrent calls with an identical `(name, version)` never both succeed: the
  `uq_definition_version` unique index is the targeted `ON CONFLICT` arbiter, and the
  loser gets `{:error, :duplicate_name_version}` -- neither caller is told which one
  "won" (design §4.1 P11/P12).
  """
  @spec create(attrs :: create_attrs(), opts :: opts()) ::
          {:ok, ProcessDefinition.t()} | create_error()
  def create(attrs, opts) when is_map(attrs) and is_list(opts) do
    prefix = Keyword.get(opts, :prefix)

    with :ok <- reject_key(attrs, :tenant_id, "tenant_id", :tenant_id_not_accepted),
         :ok <- reject_key(attrs, :status, "status", :initial_status_not_draft),
         {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, _name} <- fetch_name(attrs),
         {:ok, _version} <- fetch_version(attrs),
         {:ok, graph_map} <- fetch_graph_map(attrs),
         {:ok, graph} <- convert_graph(graph_map),
         :ok <- check_graph_result(Graph.validate_graph(graph)),
         :ok <- check_graph_result(Graph.validate_node_attributes(graph)),
         :ok <- check_graph_result(Graph.validate_edge_conditions(graph)),
         :ok <- check_graph_result(Graph.validate_flow(graph)) do
      insert_definition(attrs, prefix, tenant_id)
    end
  end

  @doc """
  Fetches one process definition by `id`, within the tenant schema named by
  `opts[:prefix]`. `{:error, :not_found}` both for a missing row and for an `id` that
  isn't a well-formed UUID (design §4.2 step 2).
  """
  @spec get_by_id(id :: Ecto.UUID.t(), opts :: opts()) ::
          {:ok, ProcessDefinition.t()} | {:error, :not_found} | common_error()
  def get_by_id(id, opts) when is_list(opts) do
    prefix = Keyword.get(opts, :prefix)

    with {:ok, _} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, uuid} <- cast_uuid(id) do
      case Repo.get(ProcessDefinition, uuid, prefix: prefix) do
        nil -> {:error, :not_found}
        %ProcessDefinition{} = found -> {:ok, found}
      end
    end
  end

  @doc """
  Fetches the single ACTIVE process definition for `name`, per PD-07. A `name` whose
  only rows are DRAFT/DEPRECATED/ARCHIVED returns `{:error, :not_found}` -- there is no
  fallback to "the most recent non-active row" (design §4.3, AC7).
  """
  @spec get_active_by_name(name :: String.t(), opts :: opts()) ::
          {:ok, ProcessDefinition.t()} | {:error, :not_found} | common_error()
  def get_active_by_name(name, opts) when is_binary(name) and is_list(opts) do
    prefix = Keyword.get(opts, :prefix)

    with {:ok, _} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      ProcessDefinition
      |> where([d], d.name == ^name and d.status == :active)
      |> Repo.all(prefix: prefix)
      |> case do
        [] -> {:error, :not_found}
        [found | _rest] -> {:ok, found}
      end
    end
  end

  @doc """
  Lists process definitions, newest first, filtered by any combination of `:name`
  (substring, `ILIKE`), `:status` (exact), `:stage` (exact -- AC8) and `:after_created`
  (strictly-after cursor, ported skip-risk and all -- design §4.4/§9 OQ-2), each an
  independent `AND`-joined predicate. Always `{:ok, list}`, an empty list on no matches,
  never an error.
  """
  @spec list(filters :: list_filters(), opts :: opts()) ::
          {:ok, [ProcessDefinition.t()]} | common_error()
  def list(filters, opts) when is_map(filters) and is_list(opts) do
    prefix = Keyword.get(opts, :prefix)

    with {:ok, _} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      effective_limit = effective_limit(Map.get(filters, :limit))

      query =
        ProcessDefinition
        |> where_name(Map.get(filters, :name))
        |> where_status(Map.get(filters, :status))
        |> where_stage(Map.get(filters, :stage))
        |> where_after_created(Map.get(filters, :after_created))
        |> order_by([d], desc: d.created_at)
        |> limit(^effective_limit)

      {:ok, Repo.all(query, prefix: prefix)}
    end
  end

  @doc """
  Cursor-paginated sibling of `list/2` -- REQ-081, `GET /definitions`. Reuses
  `where_name/2`/`where_status/2`/`where_stage/2` verbatim; does **not** use
  `list/2`'s `after_created` filter, which is superseded by real keyset
  pagination here (design §3.1/§8 OQ-1 -- `list/2` itself is untouched and
  keeps serving its own non-HTTP callers).

  Sorted `created_at` DESC, `id` DESC (keyset pagination) -- the same
  `(timestamp, id)` compound tiebreak `Letflow.Instances.list/2` and
  `Letflow.Identity.list_users/2` both already use.

  `page_size` is expected already-validated by the caller (the router, via
  `Letflow.Api.Pagination.parse_page_size_param/1` + `validate_page_size/1`),
  the same split of responsibility `Letflow.Instances.list/2` uses -- this
  function does `limit(^(page_size + 1))` internally to detect a next page.
  """
  @spec list_paginated(filters :: list_paginated_filters(), opts :: opts()) ::
          {:ok, paginated_result()}
          | {:error, :invalid_cursor | :wrong_endpoint | :expired}
          | common_error()
  def list_paginated(filters, opts) when is_map(filters) and is_list(opts) do
    prefix = Keyword.get(opts, :prefix)
    page_size = Map.fetch!(filters, :page_size)

    with {:ok, _} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, cursor_seek} <- decode_definitions_list_cursor(Map.get(filters, :cursor)) do
      query =
        ProcessDefinition
        |> where_name(Map.get(filters, :name))
        |> where_status(Map.get(filters, :status))
        |> where_stage(Map.get(filters, :stage))
        |> filter_by_definitions_list_cursor(cursor_seek)
        |> order_by([d], desc: d.created_at, desc: d.id)
        |> limit(^(page_size + 1))

      rows = Repo.all(query, prefix: prefix)
      {page, next_cursor} = split_definitions_list_page(rows, page_size)

      {:ok, %{items: page, next_cursor: next_cursor}}
    end
  end

  @doc """
  Delta-sync read for `GET /definitions/delta` (REQ-125, MOB-3) -- every
  definition in this tenant's schema whose `sequence_number` is strictly
  greater than `since`, ascending. See this module's moduledoc for the full
  cursor-semantics reasoning (AC2).

    * `since` is `nil` or `0` -> full history (`WHERE sequence_number > 0`,
      i.e. every row that exists) -- a device's very first sync, by
      construction, not a special-cased "reset" response shape.
    * `since` a negative integer, or otherwise not a non-negative integer ->
      `{:error, :invalid_since}`.
    * Otherwise: `WHERE sequence_number > since`, ordered `sequence_number
      ASC`, scoped by `opts[:prefix]` exactly like every other function in
      this module (`tenant_id` never a separate argument).

  No page-size limit -- REQ-125's acceptance criteria describe a bounded
  warm-cache/incremental-refresh workload, not an unbounded feed (design doc
  §6.1/§9 OQ-3).

  `next_since` is always the tenant's current high-water mark
  (`definition_sequence.next_seq - 1`), or `since` itself unchanged if that is
  already higher (never returns a value lower than what the caller already
  holds). A zero-change delta (device already caught up) is `{:ok, %{items:
  [], next_since: since}}`, never an error -- mirrors `list_paginated/2`'s
  "empty page is `{:ok, ...}`, never an error" precedent.

  Every definition returned carries its current `status` (AC3) -- the query is
  **not** filtered by status, so a just-created row and a just-deprecated/
  archived row both land in the result set, distinguished only by `status`,
  the same field `Letflow.Routers.Definitions.definition_map/1` already
  renders. There is no separate tombstone record type (design doc §3).

  Read-only, one query (plus the `TenantProvisioning` prefix check every
  function in this module already performs) -- no sequence assignment happens
  on a read, only on the writes `assign_definition_sequence/2` instruments
  (`create/2`, `activate/2`, `deprecate/2`, `archive/2`).
  """
  @spec delta(since :: non_neg_integer() | nil, opts :: delta_opts()) ::
          {:ok, delta_result()} | delta_error()
  def delta(since, opts) when is_list(opts) do
    prefix = Keyword.get(opts, :prefix)

    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, since_floor} <- validate_since(since) do
      items =
        ProcessDefinition
        |> where([d], d.sequence_number > ^since_floor)
        |> order_by([d], asc: d.sequence_number)
        |> Repo.all(prefix: prefix)

      {:ok,
       %{items: items, next_since: definition_high_water_mark(tenant_id, prefix, since_floor)}}
    end
  end

  @doc """
  Activates a DRAFT process definition (PD-03), atomically deprecating any prior
  ACTIVE definition sharing the same `name` in the same transaction (AC3). Called on
  an already-ACTIVE definition, this is a no-op that returns
  `{:ok, %{definition: ..., already_active: true}}` -- never an error, on every call
  (AC4). Rejects every other current status as `{:error, :not_draft}` (PD-04).

  `opts[:service_scope_validator]` is the SVC-03 integration point -- see this
  module's moduledoc.
  """
  @spec activate(id :: Ecto.UUID.t(), opts :: activate_opts()) ::
          {:ok, %{definition: ProcessDefinition.t(), already_active: boolean()}}
          | {:error, :not_found}
          | {:error, :not_draft}
          | {:error, :graph_structure_invalid}
          | {:error, {:service_scope_violation, reason :: term()}}
          | {:error, {:semantic_validation_failed, [Graph.Violation.t()]}}
          | {:error, {:semantic_validation_precondition_failed, term()}}
          | {:error,
             {:script_binding_invalid, String.t(), Letflow.Scripts.Runtime.binding_reason()}}
          | {:error,
             {:expression_references_reserved_variable,
              [Letflow.Definitions.ReservedReferences.reserved_reference()]}}
          | {:error, {:entity_writes_invalid, [entity_writes_violation()]}}
          | common_error()
  def activate(id, opts) when is_list(opts) do
    prefix = Keyword.get(opts, :prefix)
    validator = Keyword.get(opts, :service_scope_validator)
    activator = Keyword.get(opts, :activator)

    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      try do
        id
        |> run_activate_transaction(prefix, tenant_id, validator, activator)
        |> interpret_activate_result()
      rescue
        exception -> {:error, {:transaction_failed, exception}}
      end
    end
  end

  @doc """
  Transitions an ACTIVE process definition to DEPRECATED (PD-04). Every other current
  status is rejected as `{:error, :invalid_status_transition}`; a missing `id` is
  `{:error, :not_found}`.
  """
  @spec deprecate(id :: Ecto.UUID.t(), opts :: opts()) ::
          {:ok, ProcessDefinition.t()}
          | {:error, :not_found}
          | {:error, :invalid_status_transition}
          | common_error()
  def deprecate(id, opts) when is_list(opts) do
    transition(id, opts, :active, :deprecated)
  end

  @doc """
  Transitions a DEPRECATED process definition to ARCHIVED (PD-04), stamping
  `archived_at`. Every other current status is rejected as
  `{:error, :invalid_status_transition}`; a missing `id` is `{:error, :not_found}`.
  """
  @spec archive(id :: Ecto.UUID.t(), opts :: opts()) ::
          {:ok, ProcessDefinition.t()}
          | {:error, :not_found}
          | {:error, :invalid_status_transition}
          | common_error()
  def archive(id, opts) when is_list(opts) do
    transition(id, opts, :deprecated, :archived)
  end

  @doc """
  Searches process definitions by `name`/`description` substring, ranked, per PD-10 --
  see `lib/letflow/design/search.md`. A row matches iff `name` or `description`
  case-insensitively contains `query` (`ILIKE '%query%'`, `%` composed into the bound
  parameter value, never spliced into the query text -- INV-SR-2). Ranked `3.0` for an
  exact case-insensitive `name` match, `2.0` for a partial `name` match, `1.0` for a
  match found only via `description`; ordered `rank DESC, created_at DESC`.

  `query` is validated before any DB access: an empty string is `{:error, :query_empty}`
  (no trimming -- a whitespace-only query is not treated as empty, it simply matches
  nothing), and a query longer than 512 bytes is `{:error, :query_too_long}` (byte
  length, matching this module's other manual checks -- design §4/OQ-1).

  `limit` (default 20) / `offset` (default 0) paginate the ranked result, applied
  unclamped -- unlike `list/2`'s `effective_limit/1`, this function does not cap
  `:limit` to any maximum; rejecting an out-of-range `limit` is the S4 HTTP handler's
  job (design §7). Always `{:ok, list}`, an empty list on no match, never an error for
  that case.
  """
  @spec search(query :: String.t(), opts :: search_opts()) ::
          {:ok, [search_result()]} | search_error()
  def search(query, opts) when is_binary(query) and is_list(opts) do
    prefix = Keyword.get(opts, :prefix)

    with :ok <- check_query_not_empty(query),
         :ok <- check_query_not_too_long(query),
         {:ok, _} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      pattern = "%" <> query <> "%"
      effective_limit = Keyword.get(opts, :limit) || 20
      effective_offset = Keyword.get(opts, :offset) || 0

      ecto_query =
        ProcessDefinition
        |> where_search_match(pattern)
        |> select_with_rank(query, pattern)
        |> order_by_rank(query, pattern)
        |> limit(^effective_limit)
        |> offset(^effective_offset)

      {:ok, Repo.all(ecto_query, prefix: prefix)}
    end
  end

  @doc """
  Cursor-paginated sibling of `search/2` -- REQ-081, `GET /definitions/search`.
  Same result shape (`search_result()` maps: `%{definition: ..., rank:
  ...}`), same `query` validation (`check_query_not_empty/1` then
  `check_query_not_too_long/1`, run before any cursor decode or DB query --
  same order `search/2` already uses).

  Lives in this module (not a separate context module) so it can reference
  `@rank_case_sql` directly -- see this module's `search/2`-adjacent
  `@rank_case_sql` comment for why that has to be a same-module compile-time
  literal, not something a different module's `fragment/1` call could share.
  The keyset WHERE clause reuses the exact same fragment call
  `select_with_rank/3`/`order_by_rank/3` already make (same two bound values,
  `search_query`/`pattern`), so WHERE/SELECT/ORDER BY can never disagree
  about a row's rank.

  `nil` cursor (first page) is a no-op passthrough, same idiom every other
  `filter_by_*_cursor` function in this codebase already uses.
  """
  @spec search_paginated(
          query :: String.t(),
          params :: %{optional(:cursor) => String.t() | nil, page_size: pos_integer()},
          opts :: search_paginated_opts()
        ) ::
          {:ok, search_paginated_result()}
          | search_error()
          | {:error, :invalid_cursor | :wrong_endpoint | :expired}
  def search_paginated(query, params, opts)
      when is_binary(query) and is_map(params) and is_list(opts) do
    prefix = Keyword.get(opts, :prefix)
    page_size = Map.fetch!(params, :page_size)

    try do
      with :ok <- check_query_not_empty(query),
           :ok <- check_query_not_too_long(query),
           {:ok, _} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
           {:ok, cursor_seek} <- decode_definitions_search_cursor(Map.get(params, :cursor)) do
        pattern = "%" <> query <> "%"

        ecto_query =
          ProcessDefinition
          |> where_search_match(pattern)
          |> select_with_rank(query, pattern)
          |> filter_by_search_cursor(query, pattern, cursor_seek)
          |> order_by_rank_paginated(query, pattern)
          |> limit(^(page_size + 1))

        rows = Repo.all(ecto_query, prefix: prefix)
        {page, next_cursor} = split_definitions_search_page(rows, page_size)

        {:ok, %{items: page, next_cursor: next_cursor}}
      end
    rescue
      # search_paginated exception hardening -- mirrors activate/2's own bare
      # catch-all (see this module's activate/2): any exception raised while
      # building/running the query (e.g. a real Postgrex.Error) becomes a
      # typed result instead of an unhandled crash that would otherwise
      # surface as Bandit's raw empty-body HTTP 500. See
      # lib/letflow/design/iss-0739-search-paginated-exception-hardening.md.
      exception -> {:error, {:query_failed, exception}}
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-038 types -- lib/letflow/design/req038-promotion-rollback.md §2
  # ---------------------------------------------------------------------------------

  @type permission_checker_fun ::
          (actor_id :: Ecto.UUID.t(), tenant_id :: Ecto.UUID.t() -> boolean())

  @type event_appender_fun ::
          (event_attrs :: map(), prefix :: String.t() ->
             {:ok, %{event_id: Ecto.UUID.t()}} | {:error, term()})

  @type rollback_opts :: [
          prefix: String.t(),
          permission_checker: permission_checker_fun(),
          event_appender: event_appender_fun(),
          # GH #2587 PR B1: the re-activating principal's authority (see `activate_opts`).
          activator: EntityPort.activator() | nil
        ]

  @type rollback_result :: %{
          definition_id: Ecto.UUID.t(),
          version: String.t(),
          rolled_back_from_version: String.t(),
          superseded_review_id: Ecto.UUID.t() | nil,
          event_id: Ecto.UUID.t()
        }

  @type rollback_error ::
          {:error, :forbidden}
          | {:error, :process_key_not_found}
          | {:error, :version_never_active}
          | {:error, :already_active}
          | {:error,
             {:expression_references_reserved_variable,
              [Letflow.Definitions.ReservedReferences.reserved_reference()]}}
          | {:error, {:entity_writes_invalid, [entity_writes_violation()]}}
          | {:error, term()}
          | common_error()

  @doc """
  PROVENANCE (historical, not current decision authority):
  Rolls back `process_key` to `target_version`, per
  `lib/letflow/design/req038-promotion-rollback.md` (ported from R-Co's
  `src/definition/rollback.zig`, PRM-08).

  `tenant_id` is never a separate argument -- derived from `opts[:prefix]`, same as
  every other function in this module (design §2 arity note). `opts[:permission_checker]`
  and `opts[:event_appender]` are both `Keyword.fetch!/2`'d -- no built-in default for
  either, raises `KeyError` if omitted, same no-default stance `Promotion.promote_definition/3`
  already established (design §4).

  `opts[:permission_checker].(actor_id, tenant_id)` is checked before any row is read or
  locked (AC5, INV-RB-1): a `false` result returns `{:error, :forbidden}` immediately, no
  transaction opened.

  The pointer swap runs inside one `Repo.transaction/1` that locks every
  `process_definitions` row for `(tenant_id, process_key)` `FOR UPDATE` (design §5 step
  2a). Three guard cases, checked in this order, each writing zero rows
  (INV-RB-5):

    PROVENANCE (historical, not current decision authority):
    * no row currently `:active` for this `process_key` -> `{:error, :process_key_not_found}`
      (covers both "process_key never existed" and "every version already
      deprecated/archived" -- design §5 step 2b, a faithful port of `rollback.zig`'s own
      unification).
    * `target_version` already the active version -> `{:error, :already_active}` (checked
      before the target-row lookup, design §5 step 2c).
    * no row matching `target_version` with status in `[:active, :deprecated]` (R-Co's
      `SUPERSEDED` maps onto Letflow's `:deprecated` -- design §3) -> `{:error, :version_never_active}`.

  On success, the previously-active row moves `:active -> :deprecated` and the target row
  moves to `:active` (both `updated_at`-stamped), matching `activate_draft/2`'s own
  deprecate-then-activate swap shape.

  After the transaction commits, `opts[:event_appender]` is called exactly once
  (INV-RB-6) with a `DEFINITION_VERSION_ROLLED_BACK`-shaped payload
  (`process_key`/`from_version`/`to_version`/`actor_id`) -- deliberately outside the
  transaction, same divergence from R-Co's literal "single serializable transaction"
  framing that `promote_definition/3` already established (design §4.2/§8 OQ-3). A
  `{:error, reason}` here propagates unchanged as this function's own result; the pointer
  swap has already durably committed by this point.

  On a successful event-append, any `promotion_reviews` row for `(tenant_id,
  process_key)` with status `:applied` or `:approved` is looked up and, **only when
  exactly one such row matches**, superseded via `PromotionReviewStore.supersede_review/3`
  (INV-RB-10). Zero matches or more than one ambiguous match both resolve to
  `superseded_review_id: nil`, never a guess among several candidates and never a
  blanket-supersede of every match -- design §6 states in full why a naive `def_id`-only
  lookup cannot disambiguate which review corresponds to the specific former-active
  definition, and why guessing would risk corrupting unrelated audit rows (this was the
  defect CODE-DESIGN-VALIDATOR's Rework 1 blocked on). A per-row `supersede_review/3` race
  (`{:error, :invalid_transition}`) is absorbed the same way (design §6/§7, OQ-6) -- never
  fatal to an otherwise-successful rollback, since the pointer swap and event-append have
  already committed by that point.
  """
  @spec rollback_definition_version(
          process_key :: String.t(),
          target_version :: String.t(),
          actor_id :: Ecto.UUID.t(),
          opts :: rollback_opts()
        ) :: {:ok, rollback_result()} | rollback_error()
  def rollback_definition_version(process_key, target_version, actor_id, opts)
      when is_binary(process_key) and is_binary(target_version) and is_list(opts) do
    prefix = Keyword.get(opts, :prefix)
    permission_checker = Keyword.fetch!(opts, :permission_checker)
    event_appender = Keyword.fetch!(opts, :event_appender)
    activator = Keyword.get(opts, :activator)

    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      if permission_checker.(actor_id, tenant_id) do
        do_rollback(
          process_key,
          target_version,
          actor_id,
          tenant_id,
          prefix,
          event_appender,
          activator
        )
      else
        {:error, :forbidden}
      end
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-040 types -- lib/letflow/design/req040-promotion-assertion-rerun.md §3
  # ---------------------------------------------------------------------------------

  @type assertion_rerun_status :: :passed | :failed | :teardown_failed

  @type assertion_evaluator_fun ::
          (assertion :: PromotionArtifact.Assertion.t(),
           injection :: %{frozen_clock_ms: integer(), rng_seed: non_neg_integer()} ->
             {:ok, result_json :: String.t()} | {:error, term()})

  @type assertion_rerun_opts :: [
          prefix: String.t(),
          # REUSED from §0/REQ-038 -- already defined above, not redefined here.
          event_appender: event_appender_fun(),
          # Optional; defaults to default_assertion_evaluator/2 when omitted or nil --
          # a deliberate divergence from the permission_checker/event_appender
          # no-default precedent (design §3): unlike those two, there is a sensible
          # placeholder behavior to fall back to here, so a hard KeyError would only
          # force every caller to pass the same default explicitly.
          assertion_evaluator: assertion_evaluator_fun() | nil
        ]

  @type assertion_rerun_result :: %{
          run_id: Ecto.UUID.t(),
          status: assertion_rerun_status(),
          assertions_total: non_neg_integer(),
          assertions_passed: non_neg_integer(),
          assertions_failed: non_neg_integer(),
          failing_assertion_ids: [String.t()],
          # nil only on the sandbox-claim-failure path (design §7.2).
          sandbox_id: Ecto.UUID.t() | nil,
          teardown_error: String.t() | nil,
          # true iff this call returned a cached row (AC1) and claimed no sandbox.
          idempotent_hit: boolean(),
          # true when no teardown failure occurred (nothing to append) OR the append
          # succeeded; false only when a teardown failure occurred AND
          # opts[:event_appender] itself also failed (design §7.5).
          teardown_event_appended: boolean()
        }

  @type assertion_rerun_error ::
          {:error, :sandbox_unavailable}
          | {:error, :provision_failed}
          | {:error, :fixture_load_failed}
          # FK violation on review_id, mapped (design §4, §7.1).
          | {:error, :review_not_found}
          # Mirrors Letflow.EventStore.claim_idempotency/3's own defensive fallback
          # for the same class of case (the ON CONFLICT DO NOTHING re-fetch finding
          # neither "won the insert" nor "an existing row" -- in practice unreachable,
          # since Postgres's unique-index conflict handling blocks a concurrent
          # inserter until the winner's row is visible, but typed rather than left an
          # undeclared crash). Not present in design §3's literal type list -- flagged
          # in this requirement's own handoff as a small, reasoned addition matching
          # established precedent, not a silent deviation.
          | {:error, {:idempotency_lookup_failed, :sidecar_row_missing}}
          # Unexpected insert_changeset/2 validation failure.
          | {:error, Ecto.Changeset.t()}
          | common_error()

  @doc """
  PROVENANCE (historical, not current decision authority):
  Ports `src/definition/assertion_rerun.zig`'s `applyPromotionAssertionRerun` (PRM-06/07)
  -- idempotent assertion replay against an ephemeral REQ-039 sandbox, keyed by
  `(review_id, plan_digest)`.

  Returns the cached `{:ok, result}` with `idempotent_hit: true` on a second call for the
  same `(review_id, plan_digest)` pair, claiming no sandbox. On a fresh call: claims a
  sandbox (`Letflow.SandboxPool.claim/2`), loads only `artifact.fixtures[]` into it
  (`Letflow.SandboxPool.FixtureLoader.load_fixtures_only/3` -- never organic tenant data),
  replays each assertion twice under a frozen clock and a seeded, reset-between-runs RNG,
  and records `status` + `assertions_total`/`assertions_passed`/`assertions_failed` +
  `failing_assertion_ids` in `promotion_assertion_runs`.

  **Gate condition -- read before wiring this into the apply pipeline:** callers must gate
  on the returned `assertions_failed == 0`, NOT on `status == :passed`. A
  `status = :teardown_failed` result with `assertions_failed == 0` is a green gate -- see
  this module's moduledoc, "`apply_promotion_assertion_rerun/6`'s gate condition and
  crash-safety scope".

  **Crash safety -- also see this module's moduledoc:** the claim-through-release span is
  wrapped in `try/rescue`, covering normal completion, typed errors, and raised
  exceptions. It does NOT cover a hard process kill or a BEAM crash mid-replay -- that
  residual gap is disclosed, not resolved, and left to a deferred reaper follow-up.

  `tenant_id` is never a separate argument -- derived from `opts[:prefix]`, same as every
  other function in this module. `opts[:event_appender]` is `Keyword.fetch!/2`'d -- no
  built-in default, raises `KeyError` if omitted, same no-default stance
  `rollback_definition_version/4` already established. `opts[:assertion_evaluator]` DOES
  have a built-in default (`default_assertion_evaluator/2`, design §3/§6) -- a deliberate
  divergence, since there is a sensible placeholder to fall back to here, unlike
  `event_appender`, which has no data path to a real implementation without
  caller-supplied plumbing.
  """
  @spec apply_promotion_assertion_rerun(
          review_id :: Ecto.UUID.t(),
          plan_digest :: String.t(),
          artifact :: PromotionArtifact.t(),
          sandbox_pool :: GenServer.server(),
          max_wait_ms :: non_neg_integer(),
          opts :: assertion_rerun_opts()
        ) :: {:ok, assertion_rerun_result()} | assertion_rerun_error()
  def apply_promotion_assertion_rerun(
        review_id,
        plan_digest,
        artifact,
        sandbox_pool,
        max_wait_ms,
        opts
      )
      when is_binary(review_id) and is_binary(plan_digest) and is_list(opts) and
             is_integer(max_wait_ms) and max_wait_ms >= 0 do
    prefix = Keyword.get(opts, :prefix)
    event_appender = Keyword.fetch!(opts, :event_appender)

    assertion_evaluator =
      Keyword.get(opts, :assertion_evaluator) || (&default_assertion_evaluator/2)

    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      idempotency_key = build_idempotency_key(review_id, plan_digest)

      case claim_or_fetch_assertion_run(
             tenant_id,
             review_id,
             plan_digest,
             idempotency_key,
             prefix
           ) do
        {:ok, {:idempotent_hit, run}} ->
          {:ok, build_result(run, true, true)}

        {:ok, {:claimed, run}} ->
          claim_sandbox_and_proceed(
            run,
            artifact,
            sandbox_pool,
            max_wait_ms,
            tenant_id,
            prefix,
            event_appender,
            assertion_evaluator
          )

        {:error, _reason} = error ->
          error
      end
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-077 §9.2 -- NEW. Placed here, not on Letflow.Definitions.PromotionAssertionRun
  # itself, because REQ-040 already put every promotion_assertion_runs behaviour in
  # this module -- consistent with apply_promotion_assertion_rerun/6 immediately above.
  # ---------------------------------------------------------------------------------

  @doc """
  Reads the most recent `promotion_assertion_runs` row for `review_id`, scoped to
  `opts[:prefix]` (NEW, REQ-077 design §9.2 -- R3/R4's `GET /promotions/:id`).

  Casts `review_id` with `Ecto.UUID.cast/1` first, same defensive-cast reasoning as
  `Letflow.Definitions.PromotionReviewStore.get_review/2`. Orders
  `[desc: :started_at, desc: :id]` -- `started_at` is `read_after_writes: true` (a DB
  default), so two runs inserted in the same transaction can share a timestamp; the
  `:id` tiebreaker makes "latest" a total, deterministic order rather than one that
  could flap between test runs.

  Returns `{:error, :not_found}` -- deliberately NOT `:review_not_found` -- because
  this answers a different question ("is there a run for this review") than
  `PromotionReviewStore.get_review/2` answers ("does this review exist"), and R3 maps
  the two to different HTTP responses (404 vs. `{"assertion_run": null}`, design §7.4).
  """
  @spec get_latest_assertion_run(
          review_id :: Ecto.UUID.t() | String.t(),
          opts :: [prefix: String.t()]
        ) :: {:ok, PromotionAssertionRun.t()} | {:error, :not_found}
  def get_latest_assertion_run(review_id, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, uuid} <- Ecto.UUID.cast(review_id) do
      query =
        from(r in PromotionAssertionRun,
          where: r.review_id == ^uuid,
          order_by: [desc: r.started_at, desc: r.id],
          limit: 1
        )

      case Repo.one(query, prefix: prefix) do
        nil -> {:error, :not_found}
        %PromotionAssertionRun{} = run -> {:ok, run}
      end
    else
      :error -> {:error, :not_found}
    end
  end

  # ===================================================================================
  # REQ-078 -- definition-graph validation endpoint backing (design §7.2)
  # ===================================================================================

  @typedoc "The merged outcome of REQ-028/029's three graph validators over one stored definition."
  @type graph_validation_result :: %{
          definition_id: Ecto.UUID.t(),
          valid: boolean(),
          violations: [Graph.Violation.t()],
          warnings: [String.t()]
        }

  @doc """
  Runs REQ-028/029's three graph validators over one **stored** definition's
  graph and merges their outcomes. Backs
  `POST /api/v1/definitions/:id/validate` (`Letflow.Routers.Definitions`).

  **The composition lives here, not in the route, and that is the point.**
  REQ-078's AC4 requires the endpoint to produce the same outcome as calling
  REQ-028/029's validators directly on the same graph. That is only
  *structurally* guaranteed if the route contains no validation logic at all —
  so it contains none, and this function contains no rule of its own either.

  Behaviour:

    1. `get_by_id/2` — prefix-scoped. `{:error, :not_found}` propagates
       unchanged; that is also the cross-tenant case (INV-5 — the route
       renders it as a detail-free 404, byte-identical to a genuinely absent
       id, on the same code path and with the same query count).
    2. `Letflow.Definitions.Graph.from_map/1`. `:error` ->
       `{:error, :graph_structure_invalid}` — a stored graph that will not
       even parse.
    3. `Letflow.Engine.VariableSchema.fetch_schemas/3` — a FRESH read, issued
       on every call, no caching layer anywhere in this path (REQ-372 AC6).
       Its own `{:error, :missing_prefix}` / `{:error, :invalid_definition_id}`
       propagate through this function's `with` chain unchanged.
    4. Exactly these five, in this order:
       `Graph.validate_graph/1` (REQ-028 structural),
       `Graph.validate_node_attributes/1` (REQ-029 node attributes),
       `Graph.validate_edge_conditions/1` (REQ-029 edge conditions),
       `Graph.validate_flow/1` (REQ-455 reachability and default route),
       `Letflow.Definitions.SemanticValidation.validate/2` (REQ-372 semantic
       — field-existence and type-compatibility of `EXCLUSIVE_GATEWAY` edge
       conditions against the freshly-fetched declared fields).
    5. The five `:violations` lists are concatenated in that order.
       Duplicates are **not** deduplicated: the five validators produce
       disjoint `Graph.Violation.code()` sets. `valid` is `violations == []`.

  **Adds no rule of its own, and calls no other validator.** In particular it
  does **not** call
  `Letflow.Definitions.ServiceScopeValidator.validate/3`, which `activate/2`
  does call. Service-scope validation needs an injected `Lookup.t()` this
  endpoint has no source for, and including it would break AC4's equality with
  "REQ-028/029's validators directly". That exclusion is deliberate, and
  `activate/2` remains its owning path.

  Issues exactly three queries (`get_by_id/2`, `VariableSchema.fetch_schemas/3` and
  `RoleBinding.bound_role_names/1`, which feeds the advisory `:warnings` list of
  human-task roles with no `tenant_role` binding, REQ-455 check 4);
  everything after that is pure.
  """
  @spec validate_definition_graph(id :: Ecto.UUID.t(), opts :: opts()) ::
          {:ok, graph_validation_result()}
          | {:error, :not_found}
          | {:error, :graph_structure_invalid}
          | {:error, :missing_prefix}
          | {:error, :invalid_definition_id}
          | common_error()
  def validate_definition_graph(id, opts) when is_list(opts) do
    prefix = Keyword.get(opts, :prefix)

    with {:ok, %ProcessDefinition{} = definition} <- get_by_id(id, opts),
         {:ok, graph} <- convert_graph(definition.graph),
         {:ok, declared_fields} <-
           VariableSchema.fetch_schemas(Repo, definition.id, prefix: prefix) do
      violations =
        Graph.validate_graph(graph).violations ++
          Graph.validate_node_attributes(graph).violations ++
          Graph.validate_edge_conditions(graph).violations ++
          Graph.validate_flow(graph).violations ++
          SemanticValidation.validate(graph, declared_fields).violations

      warnings =
        ValidationWarnings.for_definitions([{definition.name, graph}], prefix: prefix)

      {:ok,
       %{
         definition_id: definition.id,
         valid: violations == [],
         violations: violations,
         warnings: warnings
       }}
    end
  end

  # ===================================================================================
  # REQ-078 -- metrics counters (design §11.4)
  # ===================================================================================

  # The closed enum from ProcessDefinition's own `status` field. Declared
  # before its only reader, since a module attribute is read at expansion
  # time.
  @definition_status_zero_fill %{draft: 0, active: 0, deprecated: 0, archived: 0}

  @doc """
  Counts `process_definitions` rows by `status`, scoped to `opts[:prefix]`.
  One query. Backs `GET /api/v1/metrics` (`Letflow.Routers.Metrics`).

  Every status in the closed enum is present in the returned map,
  zero-valued if unseen, so the response shape is stable.

  The `group_by`/`select` is composed over the **schema field**, never the raw
  column, so Ecto's enum loader maps stored values back to atoms before the
  zero-fill sees them. `process_definitions.status` is a bare-atom enum where
  the distinction would not bite, but
  `Letflow.Engine.count_instances_by_status/1` and `count_tasks_by_status/1`
  operate on keyword-mapped enums where it very much does — all three are
  written the same way on purpose.

  `opts[:prefix]` is validated via
  `Letflow.TenantProvisioning.tenant_id_for_schema_name/1` **before** the
  query is constructed, the same guard `Letflow.EventStore.read_global/1`
  uses. Composed with `Ecto.Query` and bound parameters only (INV-7).
  """
  @spec count_definitions_by_status(opts :: opts()) ::
          {:ok, %{status() => non_neg_integer()}} | common_error()
  def count_definitions_by_status(opts) when is_list(opts) do
    prefix = Keyword.get(opts, :prefix)

    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      counts =
        ProcessDefinition
        |> group_by([d], d.status)
        |> select([d], {d.status, count(d.id)})
        |> Repo.all(prefix: prefix)
        |> Map.new()

      {:ok, Map.merge(@definition_status_zero_fill, counts)}
    end
  end

  # ===================================================================================
  # REQ-078 -- the SINGLE shared `variable_schemas` registration path
  # lib/letflow/design/req078-supporting-routes.md §9
  # ===================================================================================

  @typedoc """
  PROVENANCE (historical, not current decision authority):
  One variable-schema registration input. `json_schema` is the ALREADY-DECODED
  document (a `map()` if well formed). Callers that hold JSON text -- the
  solution-pack install path, whose wire format carries `schema_content` as a
  string (R-Co `src/api/routes/solution_packs.zig:299-315`) -- decode it before
  calling and map a decode failure onto their own error, never onto a
  half-decoded value passed through here.
  """
  # The width of `variable_schemas.variable_key`
  # (`priv/repo/migrations/20260821000002_create_variable_schemas.exs`, a
  # `:string` column, i.e. `varchar(255)`).
  @max_variable_key_bytes 255

  @type variable_schema_input :: %{
          required(:variable_key) => String.t(),
          required(:json_schema) => term(),
          optional(:description) => String.t() | nil
        }

  @typedoc "Every distinct, pattern-matchable failure of the registration path."
  @type variable_schema_error ::
          :missing_prefix
          | :invalid_definition_id
          | {:duplicate_variable_key, String.t()}
          | {:blank_variable_key, non_neg_integer()}
          | {:variable_key_too_long, non_neg_integer()}
          | {:not_well_formed, variable_key :: String.t(), path :: [String.t()]}
          | {:schema_too_deep, variable_key :: String.t()}

  @doc """
  The SINGLE insert path into the tenant-scoped `variable_schemas` table
  (`Letflow.Engine.VariableSchema`, REQ-109). REQ-078's solution-pack install
  and REQ-082's definition import both call THIS function; neither adds a
  second insert path.

  The invariant is about INSERT PATHS, not about text: the only `Repo` insert
  against `Letflow.Engine.VariableSchema` anywhere in `lib/` is the one inside
  this function, and no module under `lib/letflow/routers/` performs a `Repo`
  call of any kind. Documentation that NAMES this table or this function is
  not a second insert path -- route moduledocs are required to name both, so
  they point a reader here. See `lib/letflow/design/req078-supporting-routes.md`
  §18.1 for the three mechanical checks that verify this, and INV-VS-1.

  Behaviour, in this exact order (steps 1-5 issue **zero** queries, so a
  malformed request never reaches the database):

    1. `opts[:prefix]` missing/nil/empty -> `{:error, :missing_prefix}`;
       `definition_id` not UUID-shaped -> `{:error, :invalid_definition_id}`.
    2. `entries == []` -> `{:ok, 0}`. (A pack with no `variable_schemas` array
       is normal, not an error.)
    3. A blank or whitespace-only `variable_key` at index `i` ->
       `{:error, {:blank_variable_key, i}}`; a `variable_key` at index `i`
       longer than #{@max_variable_key_bytes} bytes ->
       `{:error, {:variable_key_too_long, i}}`. The bound is the width of the
       `variable_schemas.variable_key` column (`varchar(255)`), applied in
       BYTES, which is the same conservative rule `create/2` applies to a
       definition `name`: Postgres counts `varchar(n)` in characters, so a
       byte bound can never admit a value the column would reject. Without
       this check a caller-supplied pack document reaches the INSERT and
       Postgres raises `Postgrex.Error` (SQLSTATE 22001) -- a bare 500 where
       every comparable pack defect returns a typed 422.
    4. A `variable_key` duplicated **within `entries`** ->
       `{:error, {:duplicate_variable_key, key}}`, checked before any insert --
       the database's `uq_variable_schema_definition_key` would otherwise
       surface it as an opaque changeset error mid-transaction.
    5. Well-formedness of every entry's `json_schema`, via
       `Letflow.Definitions.JsonSchemaShape.check/1` -- the same predicate
       `Letflow.Engine.VariableSchema.changeset/2` itself applies. The first
       failure aborts and nothing is written:
       `{:error, {:not_well_formed, variable_key, path}}` or
       `{:error, {:schema_too_deep, variable_key}}`.
    PROVENANCE (historical, not current decision authority):
    6. Insert via `Letflow.Engine.VariableSchema.changeset/2` -- REQ-109's
       changeset, not a second one -- with `prefix: opts[:prefix]` and
       `on_conflict: :nothing, conflict_target: [:definition_id,
       :variable_key]`, porting R-Co's
       `ON CONFLICT (definition_id, variable_key) DO NOTHING`
       (`src/solution/store.zig:485`) exactly.

  All inserts run in one `Ecto.Multi`, so the function is all-or-nothing.
  `Letflow.Repo.transaction/1` **joins an already-open transaction** rather
  than opening a nested one, so when the solution-pack install calls this
  inside its own transaction, the schema registration and the definitions that
  install created commit or roll back together (design OQ-5's fixed
  guarantee). Called outside a transaction, the same call wraps the inserts in
  one of their own.

  Returns `{:ok, count}`, where `count` counts rows **actually inserted** --
  a row absorbed by `ON CONFLICT DO NOTHING` is not counted. The mechanism is
  `created_at`, a `read_after_writes: true` column: a skipped insert returns no
  row from `RETURNING`, so the field stays `nil`.

  **Row scoping (INV-VS-3).** Rows are keyed to the `definition_id` argument. A
  pack carrying N definitions calls this function N times with N distinct ids,
  so the row sets are disjoint and cannot collide with REQ-082 importing a
  different definition.
  """
  @spec register_variable_schemas(
          definition_id :: Ecto.UUID.t(),
          entries :: [variable_schema_input()],
          opts :: opts()
        ) :: {:ok, non_neg_integer()} | {:error, variable_schema_error()}
  def register_variable_schemas(definition_id, entries, opts)
      when is_list(entries) and is_list(opts) do
    with {:ok, prefix} <- fetch_registration_prefix(opts),
         {:ok, definition_id} <- cast_registration_definition_id(definition_id),
         :ok <- check_registration_entries(entries) do
      insert_variable_schema_rows(definition_id, entries, prefix)
    end
  end

  @spec fetch_registration_prefix(opts()) :: {:ok, String.t()} | {:error, :missing_prefix}
  defp fetch_registration_prefix(opts) do
    case Keyword.get(opts, :prefix) do
      prefix when is_binary(prefix) and byte_size(prefix) > 0 -> {:ok, prefix}
      _missing_or_empty -> {:error, :missing_prefix}
    end
  end

  @spec cast_registration_definition_id(term()) ::
          {:ok, Ecto.UUID.t()} | {:error, :invalid_definition_id}
  defp cast_registration_definition_id(definition_id) do
    case Ecto.UUID.cast(definition_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_definition_id}
    end
  end

  # Steps 3-5. Pure -- no query is constructed, let alone issued, until every
  # entry has passed all three.
  @spec check_registration_entries([variable_schema_input()]) ::
          :ok | {:error, variable_schema_error()}
  defp check_registration_entries(entries) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while(MapSet.new(), fn {entry, index}, seen ->
      key = Map.get(entry, :variable_key)

      cond do
        not is_binary(key) or String.trim(key) == "" ->
          {:halt, {:error, {:blank_variable_key, index}}}

        byte_size(key) > @max_variable_key_bytes ->
          {:halt, {:error, {:variable_key_too_long, index}}}

        MapSet.member?(seen, key) ->
          {:halt, {:error, {:duplicate_variable_key, key}}}

        true ->
          case JsonSchemaShape.check(Map.get(entry, :json_schema)) do
            :ok -> {:cont, MapSet.put(seen, key)}
            {:error, {:not_well_formed, path}} -> {:halt, {:error, {:not_well_formed, key, path}}}
            {:error, :too_deep} -> {:halt, {:error, {:schema_too_deep, key}}}
          end
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      %MapSet{} -> :ok
    end
  end

  # Step 6. The one and only Repo insert against Letflow.Engine.VariableSchema
  # in all of lib/ (INV-VS-1).
  @spec insert_variable_schema_rows(Ecto.UUID.t(), [variable_schema_input()], String.t()) ::
          {:ok, non_neg_integer()}
  defp insert_variable_schema_rows(_definition_id, [], _prefix), do: {:ok, 0}

  defp insert_variable_schema_rows(definition_id, entries, prefix) do
    multi =
      entries
      |> Enum.with_index()
      |> Enum.reduce(Multi.new(), fn {entry, index}, multi ->
        changeset =
          VariableSchema.changeset(%VariableSchema{}, %{
            definition_id: definition_id,
            variable_key: Map.get(entry, :variable_key),
            json_schema: Map.get(entry, :json_schema),
            description: Map.get(entry, :description)
          })

        Multi.insert(multi, {:variable_schema, index}, changeset,
          prefix: prefix,
          on_conflict: :nothing,
          conflict_target: [:definition_id, :variable_key]
        )
      end)

    # Strict match, deliberately: after steps 1-5 the multi cannot return
    # {:error, _, _, _}. `validate_required/2` is satisfied by construction
    # (definition_id was cast, variable_key is non-blank, json_schema is a
    # map), `validate_change(:json_schema, ...)` applies the same predicate
    # step 5 already ran, and `unique_constraint/3` cannot fire because
    # `on_conflict: :nothing` suppresses it. A genuine database failure
    # (missing table, dead connection) raises rather than returning an error
    # tuple, and belongs on the caller's 500 path.
    {:ok, changes} = Repo.transaction(multi)

    inserted =
      Enum.count(changes, fn {_name, %VariableSchema{created_at: created_at}} ->
        not is_nil(created_at)
      end)

    {:ok, inserted}
  end

  # ===================================================================================
  # REQ-082 -- write and lifecycle routes (design §4). `create_with_variable_schemas/3`,
  # `update/3`, `hard_delete/2` below are this requirement's own context-layer additions;
  # `activate/2`/`deprecate/2`/`archive/2` above are REQ-030's and are called AS-IS --
  # this requirement invents no second lifecycle state machine.
  # ===================================================================================

  @doc """
  `create/2` plus, atomically in the same transaction, a `register_variable_schemas/3`
  call for `entries` (REQ-109's obligation on the create write path -- see this
  module's moduledoc pointer and `docs/requirements.yaml`'s REQ-082 entry). `entries`
  is typically `[]` (most creates carry no `variable_schemas`), in which case this is
  exactly `create/2` wrapped in a transaction for no reason other than a uniform
  return shape with the non-empty case.

  A `create/2` failure never reaches `register_variable_schemas/3` (the `with` chain
  short-circuits). A `register_variable_schemas/3` failure rolls back the just-inserted
  definition row too -- a definition is never left on disk with a still-invalid or
  partially-registered `variable_schemas` set (INV-8).

  Returns `create/2`'s error union unchanged on a create failure, or
  `{:error, {:variable_schema_registration_failed, variable_schema_error()}}` on a
  registration failure -- tagged distinctly so the caller (the router) can render each
  differently even though `create_error()` and `variable_schema_error()` are disjoint
  atom-vs-tuple spaces that could not otherwise collide.
  """
  @spec create_with_variable_schemas(
          attrs :: create_attrs(),
          entries :: [variable_schema_input()],
          opts :: opts()
        ) ::
          {:ok, ProcessDefinition.t()}
          | create_error()
          | {:error, {:variable_schema_registration_failed, variable_schema_error()}}
  def create_with_variable_schemas(attrs, entries, opts)
      when is_map(attrs) and is_list(entries) and is_list(opts) do
    prefix = Keyword.get(opts, :prefix)

    Repo.transaction(fn ->
      case create(attrs, opts) do
        {:ok, definition} ->
          case register_variable_schemas(definition.id, entries, prefix: prefix) do
            {:ok, _count} ->
              definition

            {:error, reason} ->
              Repo.rollback({:variable_schema_registration_failed, reason})
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Updates a DRAFT process definition -- the shared backing function for both
  `PUT /definitions/:id` and `PATCH /definitions/:id`. See `update_attrs()`'s own
  typedoc for the presence-controls-touch contract.

  Every subsequent transition off `:draft` is a guarded single-statement
  `WHERE id = $1 AND status = 'draft'` UPDATE (matching
  `Letflow.Definitions.ProcessDefinition`'s own moduledoc, "status is never castable
  from caller input" / "a load-then-update would reintroduce the lost-update race"),
  never a `Repo.get/2`-then-changeset read-modify-write. Steps that only inspect
  `attrs` (name/version presence+shape, graph structural/node/edge validation via the
  same three validators `create/2` runs) issue **zero** queries and run entirely
  before the guarded UPDATE, so a malformed request never reaches the database
  (INV-8, matching `create/2`'s own "zero DB calls on a validation failure" contract).

  A well-formed request against a row that is missing, or present but not `:draft`,
  cannot be told apart by the UPDATE's own row count (`{0, _}` either way) -- resolved
  by a `Repo.get/2` fallback lookup that distinguishes `{:error, :not_found}` (row
  absent -- collapses a cross-tenant id with a genuinely-absent one, INV-5, since
  `Repo.get/2` is itself prefix-scoped) from `{:error, :not_draft}` (row present, wrong
  status), exactly mirroring `run_transition/4`'s own `fallback_lookup/2` above.

  `attrs[:variable_schemas]`, if present (even `[]`), REPLACES this definition's
  entire `variable_schemas` row set inside the SAME transaction as the UPDATE --
  existing rows for this `definition_id` are deleted first, then
  `register_variable_schemas/3` inserts the new set. This is what makes a re-PUT with
  an omitted `variable_key` leave no row for that key (REQ-082's AC9): the delete has
  no "keep unless" branch, it clears every row for this `definition_id` before the
  fresh insert. Absent entirely (no `:variable_schemas` key in `attrs`), the existing
  `variable_schemas` rows are left untouched -- a PUT/PATCH that does not mention
  variable schemas is not a statement that there are none.
  """
  @spec update(id :: Ecto.UUID.t(), attrs :: update_attrs(), opts :: opts()) ::
          {:ok, ProcessDefinition.t()} | update_error()
  def update(id, attrs, opts) when is_map(attrs) and is_list(opts) do
    prefix = Keyword.get(opts, :prefix)

    with {:ok, _} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, uuid} <- cast_update_id(id),
         :ok <- validate_update_name(attrs),
         :ok <- validate_update_version(attrs),
         :ok <- validate_update_graph(attrs) do
      run_update(uuid, prefix, build_update_set(attrs), Map.get(attrs, :variable_schemas))
    end
  end

  defp cast_update_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp validate_update_name(attrs) do
    if Map.has_key?(attrs, :name), do: with({:ok, _} <- fetch_name(attrs), do: :ok), else: :ok
  end

  defp validate_update_version(attrs) do
    if Map.has_key?(attrs, :version),
      do: with({:ok, _} <- fetch_version(attrs), do: :ok),
      else: :ok
  end

  defp validate_update_graph(attrs) do
    if Map.has_key?(attrs, :graph) do
      with {:ok, graph_map} <- fetch_graph_map(attrs),
           {:ok, graph} <- convert_graph(graph_map),
           :ok <- check_graph_result(Graph.validate_graph(graph)),
           :ok <- check_graph_result(Graph.validate_node_attributes(graph)),
           :ok <- check_graph_result(Graph.validate_edge_conditions(graph)),
           :ok <- check_graph_result(Graph.validate_flow(graph)) do
        :ok
      end
    else
      :ok
    end
  end

  defp build_update_set(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    []
    |> maybe_set(:name, attrs)
    |> maybe_set(:version, attrs)
    |> maybe_set(:description, attrs)
    |> maybe_set(:graph, attrs)
    |> maybe_set(:stage, attrs)
    |> Keyword.put(:updated_at, now)
  end

  defp maybe_set(set, key, attrs) do
    if Map.has_key?(attrs, key), do: Keyword.put(set, key, Map.get(attrs, key)), else: set
  end

  defp run_update(id, prefix, set, variable_schema_entries) do
    Repo.transaction(fn ->
      try do
        ProcessDefinition
        |> where([d], d.id == ^id and d.status == :draft)
        |> select([d], d)
        |> Repo.update_all([set: set], prefix: prefix)
        |> case do
          {1, [updated]} ->
            case maybe_replace_variable_schemas(updated.id, variable_schema_entries, prefix) do
              :ok -> updated
              {:error, reason} -> Repo.rollback(reason)
            end

          {0, _count_and_rows} ->
            fallback_lookup_for_update(id, prefix)
        end
      rescue
        error in Postgrex.Error ->
          if match?(%Postgrex.Error{postgres: %{code: :unique_violation}}, error) do
            Repo.rollback(:duplicate_name_version)
          else
            reraise error, __STACKTRACE__
          end
      end
    end)
  end

  defp fallback_lookup_for_update(id, prefix) do
    case Repo.get(ProcessDefinition, id, prefix: prefix) do
      nil -> Repo.rollback(:not_found)
      %ProcessDefinition{} -> Repo.rollback(:not_draft)
    end
  end

  # `nil` (key absent from attrs): leave existing variable_schemas rows untouched.
  defp maybe_replace_variable_schemas(_definition_id, nil, _prefix), do: :ok

  defp maybe_replace_variable_schemas(definition_id, entries, prefix) when is_list(entries) do
    {_count, nil} =
      VariableSchema
      |> where([v], v.definition_id == ^definition_id)
      |> Repo.delete_all(prefix: prefix)

    case register_variable_schemas(definition_id, entries, prefix: prefix) do
      {:ok, _count} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Hard-deletes a DRAFT process definition (PD-04's `DRAFT -> hard delete` branch).
  Every other current status is rejected as `{:error, :not_draft}` -- the router's
  `handle_delete/2` owns dispatching to `deprecate/2`/`archive/2` instead for
  `:active`/`:deprecated` current status, per this module's moduledoc "REQ-082" note:
  it reuses those two functions as-is rather than this one inventing a second
  transition path.

  Same guarded-`WHERE`-clause shape as `update/3`/`run_transition/4`: a single
  `Repo.delete_all/2` scoped to `id AND status == :draft`, so a concurrent
  activate-then-delete race cannot delete a row that is no longer DRAFT by the time
  this statement runs.
  """
  @spec hard_delete(id :: Ecto.UUID.t(), opts :: opts()) :: {:ok, :deleted} | hard_delete_error()
  def hard_delete(id, opts) when is_list(opts) do
    prefix = Keyword.get(opts, :prefix)

    with {:ok, _} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, uuid} <- cast_update_id(id) do
      run_hard_delete(uuid, prefix)
    end
  end

  defp run_hard_delete(id, prefix) do
    Repo.transaction(fn ->
      ProcessDefinition
      |> where([d], d.id == ^id and d.status == :draft)
      |> Repo.delete_all(prefix: prefix)
      |> case do
        {1, _} -> :deleted
        {0, _} -> fallback_lookup_for_update(id, prefix)
      end
    end)
  end

  # -----------------------------------------------------------------------------------
  # create/2 helpers (design §4.1)
  # -----------------------------------------------------------------------------------

  defp reject_key(attrs, atom_key, string_key, error) do
    if Map.has_key?(attrs, atom_key) or Map.has_key?(attrs, string_key) do
      {:error, error}
    else
      :ok
    end
  end

  defp fetch_name(attrs) do
    case Map.get(attrs, :name) do
      name when is_binary(name) and byte_size(name) > 0 and byte_size(name) <= 255 ->
        {:ok, name}

      _ ->
        {:error, :name_invalid}
    end
  end

  defp fetch_version(attrs) do
    case Map.get(attrs, :version) do
      version when is_binary(version) and byte_size(version) > 0 -> {:ok, version}
      _ -> {:error, :version_empty}
    end
  end

  defp fetch_graph_map(attrs) do
    case Map.get(attrs, :graph) do
      graph when is_map(graph) and not is_struct(graph) -> {:ok, graph}
      _ -> {:error, :graph_structure_invalid}
    end
  end

  defp convert_graph(graph_map) do
    case Graph.from_map(graph_map) do
      {:ok, graph} -> {:ok, graph}
      :error -> {:error, :graph_structure_invalid}
    end
  end

  defp check_graph_result(%{valid: true}), do: :ok

  defp check_graph_result(%{valid: false, violations: violations}) do
    {:error, {:graph_validation_failed, violations}}
  end

  # `attrs` is deliberately accessed by atom key only here (not the design's literal
  # "attrs[:name] (or attrs[\"name\"])" phrasing) -- matching create_attrs()'s own
  # atom-keyed @type and the EventStore.append/2 precedent this design cites, whose
  # own field fetchers (fetch_uuid/3, fetch_payload/1, ...) are atom-only; only the
  # tenant_id/status *rejection* checks (reject_key/4 above) check both forms, mirroring
  # EventStore's reject_tenant_id/1 exactly.
  #
  # Post-Decision-0006-D2 (REQ-064): this function no longer merges a
  # caller-derived :tenant_id into attrs before building the changeset --
  # process_definitions.tenant_id no longer exists as a column (the per-tenant
  # Postgres schema, written via `prefix:` in Repo.insert/2 below, already
  # identifies the tenant). tenant_id_for_schema_name/1 is still called at this
  # function's own call site (create/2) purely to validate `prefix` resolves to
  # a real, provisioned tenant before any row is written -- its result is no
  # longer threaded into this function at all.
  # REQ-125 §5.3 -- create/2 now assigns a definition_sequence number inside
  # its own transaction, stamping it via Ecto.Changeset.put_change/3 rather
  # than adding :sequence_number to create_changeset/2's castable field list
  # -- mirrors :status's own "never castable from caller input" protection
  # (this module's moduledoc references ProcessDefinition's INV-DEF-8 note):
  # a caller-supplied sequence_number in attrs must never reach the row,
  # only the server-assigned value from the locked counter may.
  #
  # A duplicate (name, version) conflict still burns the assigned sequence
  # number (the ON CONFLICT DO NOTHING path below never rolls the
  # transaction back) -- an accepted, small counter gap, the same class
  # activate_draft/3's 0-row deprecate update can also produce. The design's
  # own guarantee is monotonic ordering, never gap-free numbering.
  defp insert_definition(attrs, prefix, tenant_id) do
    try do
      Repo.transaction(fn ->
        case assign_definition_sequence(tenant_id, prefix) do
          {:ok, seq} ->
            changeset =
              %ProcessDefinition{}
              |> ProcessDefinition.create_changeset(attrs)
              |> Ecto.Changeset.put_change(:sequence_number, seq)

            changeset
            |> Repo.insert(
              on_conflict: :nothing,
              conflict_target: [:name, :version],
              returning: true,
              prefix: prefix
            )
            |> case do
              {:ok, %ProcessDefinition{id: id}} ->
                case Repo.get(ProcessDefinition, id, prefix: prefix) do
                  %ProcessDefinition{} = found ->
                    case record_definition_audit(
                           "definition.create",
                           found.id,
                           nil,
                           found,
                           prefix
                         ) do
                      {:ok, _entry} -> found
                      {:error, reason} -> Repo.rollback(reason)
                    end

                  nil ->
                    Repo.rollback(:duplicate_name_version)
                end

              {:error, %Ecto.Changeset{} = changeset} ->
                Repo.rollback(changeset)
            end

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, %ProcessDefinition{} = found} -> {:ok, found}
        {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
        {:error, reason} -> {:error, reason}
      end
    rescue
      exception -> {:error, {:transaction_failed, exception}}
    end
  end

  # REQ-195 -- actor_id is nil for every Definitions lifecycle audit row
  # (create/activate/deprecate/archive): none of these four functions'
  # `opts()`/`activate_opts()` carries an actor_id field today, and the one
  # channel that could supply a real one (conn.assigns.auth_context.user_id)
  # is read only inside lib/letflow/routers/definitions.ex, which this
  # requirement's own AC11 forbids touching -- see
  # lib/letflow/design/req195-audit-entry-storage.md §3.1a. Called from
  # inside each function's own Repo.transaction/1 anonymous function, so a
  # failed insert (`{:error, reason}`) rolls back via `Repo.rollback/1` at
  # each call site, same-transaction guarantee (AC3).
  defp record_definition_audit(action, definition_id, before, after_, prefix) do
    Audit.insert_entry(
      Repo,
      %{
        actor_id: nil,
        action: action,
        resource_type: "definition",
        resource_id: definition_id,
        before_state: definition_audit_state(before),
        after_state: definition_audit_state(after_),
        trace_id: nil
      },
      prefix
    )
  end

  defp definition_audit_state(nil), do: nil

  defp definition_audit_state(%ProcessDefinition{} = definition),
    do: Audit.struct_state(definition)

  # -----------------------------------------------------------------------------------
  # get_by_id/2 helper
  # -----------------------------------------------------------------------------------

  defp cast_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  # -----------------------------------------------------------------------------------
  # list/2 helpers (design §4.4)
  # -----------------------------------------------------------------------------------

  defp effective_limit(nil), do: 50
  defp effective_limit(0), do: 50
  defp effective_limit(limit) when is_integer(limit) and limit > 200, do: 200
  defp effective_limit(limit) when is_integer(limit) and limit > 0, do: limit

  defp where_name(query, nil), do: query

  defp where_name(query, name) when is_binary(name) do
    pattern = "%" <> name <> "%"
    where(query, [d], fragment("? ILIKE ?", d.name, ^pattern))
  end

  defp where_status(query, nil), do: query
  defp where_status(query, status), do: where(query, [d], d.status == ^status)

  defp where_stage(query, nil), do: query
  defp where_stage(query, stage), do: where(query, [d], d.stage == ^stage)

  defp where_after_created(query, nil), do: query

  defp where_after_created(query, after_created) do
    where(query, [d], d.created_at > ^after_created)
  end

  # -----------------------------------------------------------------------------------
  # list_paginated/2 helpers (design §3.1/§3.3) -- mirrors
  # Letflow.Instances.list/2's filter_by_list_cursor/2 tuple-comparison
  # keyset pattern (same `(timestamp, id)` compound key, adapted to
  # ProcessDefinition's created_at/id columns), per ELIXIR-DEV's handoff gap
  # resolution.
  # -----------------------------------------------------------------------------------

  @definitions_list_cursor_prefix "DL:"

  defp filter_by_definitions_list_cursor(query, nil), do: query

  defp filter_by_definitions_list_cursor(query, {id, created_at_us}) do
    ts = DateTime.from_unix!(created_at_us, :microsecond)
    from(d in query, where: {d.created_at, d.id} < {^ts, ^id})
  end

  defp decode_definitions_list_cursor(nil), do: {:ok, nil}

  defp decode_definitions_list_cursor(raw) when is_binary(raw) do
    case Pagination.decode_cursor(
           raw,
           @definitions_list_cursor_prefix,
           byte_size(@definitions_list_cursor_prefix)
         ) do
      {:ok, %Pagination.Cursor{} = cursor} -> {:ok, decode_definitions_list_seek(cursor)}
      {:error, :wrong_endpoint} -> {:error, :wrong_endpoint}
      {:error, :expired} -> {:error, :expired}
      {:error, _invalid_base64_or_invalid_cursor} -> {:error, :invalid_cursor}
    end
  end

  # `inner` is `"DL:<mint_time_us>:<id>:<created_at_us>"` -- same
  # Letflow.Identity.list_users/2 field-slot idiom (§0 of the design doc): the
  # first slot after the prefix is always the mint-time timestamp
  # decode_cursor/4's expiry check reads, never a domain value.
  defp decode_definitions_list_seek(%Pagination.Cursor{inner: inner}) do
    prefix_len = byte_size(@definitions_list_cursor_prefix)
    rest = binary_part(inner, prefix_len, byte_size(inner) - prefix_len)
    [_mint_time_us_str, id_str, created_at_us_str] = String.split(rest, ":", parts: 3)
    {id_str, String.to_integer(created_at_us_str)}
  end

  defp split_definitions_list_page(rows, page_size) when length(rows) > page_size do
    {page, [_extra_row]} = Enum.split(rows, page_size)
    {page, build_definitions_list_next_cursor(List.last(page))}
  end

  defp split_definitions_list_page(rows, _page_size), do: {rows, nil}

  defp build_definitions_list_next_cursor(%ProcessDefinition{id: id, created_at: created_at}) do
    mint_time_us = System.system_time(:microsecond)
    created_at_us = DateTime.to_unix(created_at, :microsecond)

    @definitions_list_cursor_prefix
    |> Pagination.build_raw_cursor_timestamp_key(mint_time_us, id, created_at_us)
    |> Pagination.encode_cursor()
  end

  # -----------------------------------------------------------------------------------
  # search/2 helpers (design §4/§5/§7)
  # -----------------------------------------------------------------------------------

  defp check_query_not_empty(query) do
    if byte_size(query) == 0, do: {:error, :query_empty}, else: :ok
  end

  defp check_query_not_too_long(query) do
    if byte_size(query) > 512, do: {:error, :query_too_long}, else: :ok
  end

  # `pattern` (the "%query%" value) matches on `name` OR `description`, both
  # ILIKE'd against the same bound value (design §5/§6, INV-SR-2). `description` is
  # nullable; a NULL ILIKE comparison evaluates to NULL, which the surrounding OR
  # simply doesn't treat as a match -- no explicit `IS NOT NULL` guard needed.
  defp where_search_match(queryable, pattern) do
    where(
      queryable,
      [d],
      fragment("? ILIKE ? OR ? ILIKE ?", d.name, ^pattern, d.description, ^pattern)
    )
  end

  # `search_query` and `pattern` are the same two bound values used in the WHERE
  # clause above, reused unchanged here so the ranking CASE and the matching WHERE
  # can never disagree about what counts as a "name match" (design §5). The CASE
  # expression's SQL shape is a fixed compile-time string literal, shared via the
  # `@rank_case_sql` module attribute below so both call sites can never drift out
  # of sync -- only the `?`-placeholder values (d.name, ^search_query, d.name,
  # ^pattern) vary per call, each compiled by Ecto to a genuine bound Postgres
  # parameter (design §6). A module attribute is inlined as a literal at
  # compile time before Ecto's fragment/1 macro-expansion SQL-injection guard
  # runs, so `fragment(@rank_case_sql, ...)` compiles cleanly here, unlike
  # `fragment(^helper_fun(), ...)` which Ecto's guard rejects even when the
  # helper always returns the same fixed string (confirmed against
  # deps/ecto/lib/ecto/query/builder.ex). WHEN branches evaluated in order:
  # exact case-insensitive name match (3.0), else partial name ILIKE match
  # (2.0), else -- since the surrounding WHERE clause already restricts every
  # row here to a name-or-description match -- the row matched via description
  # alone (1.0), per design §5's "safe unconditional ELSE" rationale. Cast to
  # float8 explicitly (ISS-0038/GH#120): Postgres infers an untyped numeric-literal
  # CASE expression as `numeric`, which Postgrex/Ecto decode as `Decimal.t()`, not
  # the `float()` this module's `@type search_result` and `search/2`'s @doc both
  # promise -- the cast makes the wire type match the documented Elixir type.
  @rank_case_sql "(CASE WHEN lower(?) = lower(?) THEN 3.0 WHEN ? ILIKE ? THEN 2.0 ELSE 1.0 END)::float8"

  defp select_with_rank(queryable, search_query, pattern) do
    select(queryable, [d], %{
      definition: d,
      rank:
        fragment(
          @rank_case_sql,
          d.name,
          ^search_query,
          d.name,
          ^pattern
        )
    })
  end

  defp order_by_rank(queryable, search_query, pattern) do
    order_by(
      queryable,
      [d],
      desc:
        fragment(
          @rank_case_sql,
          d.name,
          ^search_query,
          d.name,
          ^pattern
        ),
      desc: d.created_at
    )
  end

  # -----------------------------------------------------------------------------------
  # search_paginated/3 helpers (design §3.2/§3.3)
  # -----------------------------------------------------------------------------------

  @definitions_search_cursor_prefix "DS:"

  # Same order/tiebreak as order_by_rank_paginated/3 below: rank DESC,
  # created_at DESC, id DESC. Reuses @rank_case_sql a third time (alongside
  # select_with_rank/3's and order_by_rank/3's existing uses) via the exact
  # same fragment call, so WHERE/SELECT/ORDER BY can never disagree about a
  # row's rank (design §3.2).
  defp filter_by_search_cursor(query, _search_query, _pattern, nil), do: query

  defp filter_by_search_cursor(
         query,
         search_query,
         pattern,
         {cursor_rank, cursor_created_at_us, cursor_id}
       ) do
    ts = DateTime.from_unix!(cursor_created_at_us, :microsecond)

    where(
      query,
      [d],
      fragment(@rank_case_sql, d.name, ^search_query, d.name, ^pattern) < ^cursor_rank or
        (fragment(@rank_case_sql, d.name, ^search_query, d.name, ^pattern) == ^cursor_rank and
           d.created_at < ^ts) or
        (fragment(@rank_case_sql, d.name, ^search_query, d.name, ^pattern) == ^cursor_rank and
           d.created_at == ^ts and d.id < ^cursor_id)
    )
  end

  defp order_by_rank_paginated(queryable, search_query, pattern) do
    order_by(
      queryable,
      [d],
      desc:
        fragment(
          @rank_case_sql,
          d.name,
          ^search_query,
          d.name,
          ^pattern
        ),
      desc: d.created_at,
      desc: d.id
    )
  end

  defp decode_definitions_search_cursor(nil), do: {:ok, nil}

  defp decode_definitions_search_cursor(raw) when is_binary(raw) do
    case Pagination.decode_cursor(
           raw,
           @definitions_search_cursor_prefix,
           byte_size(@definitions_search_cursor_prefix)
         ) do
      {:ok, %Pagination.Cursor{} = cursor} -> {:ok, decode_definitions_search_seek(cursor)}
      {:error, :wrong_endpoint} -> {:error, :wrong_endpoint}
      {:error, :expired} -> {:error, :expired}
      {:error, _invalid_base64_or_invalid_cursor} -> {:error, :invalid_cursor}
    end
  end

  # `inner` is `"DS:<mint_time_us>:<rank_int>|<id>:<created_at_us>"` --
  # `rank_int` is `trunc(rank)`, always exactly 1, 2 or 3 per @rank_case_sql's
  # three WHEN/ELSE branches, so no precision is lost storing it as an
  # integer. Two domain values (rank_int, id) share the `key` slot of
  # build_raw_cursor_timestamp_key/4 since only two non-expiry slots exist
  # for three domain values (rank, created_at, id) -- design §3.3.
  defp decode_definitions_search_seek(%Pagination.Cursor{inner: inner}) do
    prefix_len = byte_size(@definitions_search_cursor_prefix)
    rest = binary_part(inner, prefix_len, byte_size(inner) - prefix_len)
    [_mint_time_us_str, rank_and_id_str, created_at_us_str] = String.split(rest, ":", parts: 3)
    [rank_int_str, id_str] = String.split(rank_and_id_str, "|", parts: 2)
    {String.to_integer(rank_int_str) * 1.0, String.to_integer(created_at_us_str), id_str}
  end

  defp split_definitions_search_page(rows, page_size) when length(rows) > page_size do
    {page, [_extra_row]} = Enum.split(rows, page_size)
    {page, build_definitions_search_next_cursor(List.last(page))}
  end

  defp split_definitions_search_page(rows, _page_size), do: {rows, nil}

  defp build_definitions_search_next_cursor(%{
         definition: %ProcessDefinition{id: id, created_at: created_at},
         rank: rank
       }) do
    mint_time_us = System.system_time(:microsecond)
    created_at_us = DateTime.to_unix(created_at, :microsecond)
    rank_int = trunc(rank)

    @definitions_search_cursor_prefix
    |> Pagination.build_raw_cursor_timestamp_key(
      mint_time_us,
      "#{rank_int}|#{id}",
      created_at_us
    )
    |> Pagination.encode_cursor()
  end

  # -----------------------------------------------------------------------------------
  # REQ-125 -- delta/2 helpers (design §4/§6.1)
  # -----------------------------------------------------------------------------------

  defp validate_since(nil), do: {:ok, 0}
  defp validate_since(since) when is_integer(since) and since >= 0, do: {:ok, since}
  defp validate_since(_since), do: {:error, :invalid_since}

  # design §6.1 -- always the tenant's current high-water mark
  # (definition_sequence.next_seq - 1), or since_floor unchanged if that is
  # already higher (e.g. no definition_sequence row exists yet for a
  # brand-new tenant with zero writes -- current_high_water_mark is then 0,
  # and since_floor wins if it is itself already > 0... though a well-formed
  # since can never legitimately exceed a real high-water mark except via a
  # corrupted/foreign client watermark, per this module's moduledoc, and
  # max/2 handles that case safely too: never returns less than what the
  # caller already holds).
  defp definition_high_water_mark(tenant_id, prefix, since_floor) do
    current_high_water_mark =
      case Repo.get(DefinitionSequence, tenant_id, prefix: prefix) do
        nil -> 0
        %DefinitionSequence{next_seq: next_seq} -> next_seq - 1
      end

    max(current_high_water_mark, since_floor)
  end

  # -----------------------------------------------------------------------------------
  # REQ-125 -- shared sequence-assignment protocol (design §5.3), reused by
  # insert_definition/2 (create/2), activate_draft/3 (activate/2), and
  # run_transition/5 (deprecate/2, archive/2). Mirrors
  # Letflow.EventStore.assign_sequence/3's exact three-sub-step shape
  # (insert-if-absent, row-lock read, increment-under-lock), at tenant-schema
  # granularity instead of per-instance granularity. Always called from
  # inside an already-open Repo.transaction/1 (never opens its own), so a
  # rolled-back caller never burns a sequence number it didn't use -- the
  # counter mutation rolls back with everything else in the same DB
  # transaction.
  # -----------------------------------------------------------------------------------

  defp assign_definition_sequence(tenant_id, prefix) do
    insert_changeset =
      DefinitionSequence.insert_changeset(%DefinitionSequence{}, %{tenant_id: tenant_id})

    case Repo.insert(insert_changeset,
           on_conflict: :nothing,
           conflict_target: :tenant_id,
           prefix: prefix
         ) do
      {:ok, _} -> lock_and_increment_definition_sequence(tenant_id, prefix)
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp lock_and_increment_definition_sequence(tenant_id, prefix) do
    locked =
      DefinitionSequence
      |> where([s], s.tenant_id == ^tenant_id)
      |> lock("FOR UPDATE")
      |> Repo.one(prefix: prefix)

    case locked do
      nil ->
        {:error, {:sequence_conflict, :row_missing_after_insert}}

      %DefinitionSequence{next_seq: assigned_sequence_number} ->
        DefinitionSequence
        |> where([s], s.tenant_id == ^tenant_id)
        |> Repo.update_all([set: [next_seq: assigned_sequence_number + 1]], prefix: prefix)
        |> case do
          {1, _} -> {:ok, assigned_sequence_number}
          _ -> {:error, {:sequence_conflict, :unexpected_update_count}}
        end
    end
  end

  # -----------------------------------------------------------------------------------
  # activate/2 helpers (design §6.2)
  # -----------------------------------------------------------------------------------

  defp run_activate_transaction(id, prefix, tenant_id, validator, activator) do
    Repo.transaction(fn ->
      ProcessDefinition
      |> where([d], d.id == ^id)
      |> lock("FOR UPDATE")
      |> Repo.one(prefix: prefix)
      |> case do
        nil ->
          Repo.rollback(:not_found)

        %ProcessDefinition{status: :active} = definition ->
          {:already_active, definition}

        %ProcessDefinition{status: status} when status in [:deprecated, :archived] ->
          Repo.rollback(:not_draft)

        %ProcessDefinition{status: :draft} = definition ->
          case run_service_scope_validator(definition, tenant_id, validator) do
            :ok ->
              with :ok <- run_semantic_validation(definition, prefix),
                   :ok <- check_reserved_references(definition),
                   :ok <- check_entity_writes(definition, prefix, activator),
                   :ok <- check_script_bindings(definition, prefix) do
                activate_draft(definition, prefix, tenant_id, activator)
              else
                {:error, reason} -> Repo.rollback(reason)
              end

            {:error, reason} ->
              Repo.rollback(reason)
          end
      end
    end)
  end

  # GH 2534 PR 7c-1 (decision 0053 D2; design gh2534-7c-script-handler.md 4.5, C8): every
  # tenant-script binding of the graph must be a published service_task version with a closed
  # output schema, no restricted opt-in and (7c-1) no reads. Runs INSIDE the activating
  # transaction (it reads the bound script_rules rows FOR SHARE, serialising with a retire),
  # before the status write. Shared by activate/2, promotion and version rollback.
  @doc false
  @spec check_script_bindings(ProcessDefinition.t() | map(), String.t()) ::
          :ok
          | {:error, :graph_structure_invalid}
          | {:error,
             {:script_binding_invalid, String.t(), Letflow.Scripts.Runtime.binding_reason()}}
          | {:error,
             {:expression_references_reserved_variable,
              [Letflow.Definitions.ReservedReferences.reserved_reference()]}}
  def check_script_bindings(%{graph: graph_map}, prefix) do
    case Graph.from_map(graph_map) do
      {:ok, graph} -> Letflow.Scripts.Runtime.check_bindings(graph, prefix)
      :error -> {:error, :graph_structure_invalid}
    end
  end

  # GH #2587 PR A1b (decision 0054; design gh2587-req499-pr-a-prerequisites.md 2A.3): no
  # expression, template placeholder or sub-process interface entry of the graph may name the
  # reserved engine namespace (L1-L8; L9, a bound script's input, is checked inside
  # check_script_bindings/2). Shared by the three activation paths (activate/2, version
  # rollback, promotion apply) and run BEFORE check_script_bindings/2, so a refused graph takes
  # no FOR SHARE script-row lock. Pure: no query.
  @doc false
  @spec check_reserved_references(ProcessDefinition.t() | map()) ::
          :ok
          | {:error, :graph_structure_invalid}
          | {:error,
             {:expression_references_reserved_variable,
              [Letflow.Definitions.ReservedReferences.reserved_reference()]}}
  def check_reserved_references(%{graph: graph_map}) do
    case Graph.from_map(graph_map) do
      {:ok, graph} ->
        case Letflow.Definitions.ReservedReferences.find(graph) do
          [] -> :ok
          references -> {:error, {:expression_references_reserved_variable, references}}
        end

      :error ->
        {:error, :graph_structure_invalid}
    end
  end

  # GH #2587 / REQ-499 PR B1 (decision 0054 D1, D4a; design
  # gh2587-req499-pr-b-human-task-writes.md 5.3, 6.3): every node's declared `entity_writes`
  # must be a valid, authorised set of lines BEFORE the definition becomes ACTIVE. Shared by
  # the three activation paths (activate/2, version rollback, promotion apply) and run AFTER
  # check_reserved_references/1 and BEFORE check_script_bindings/2, so a refused graph takes
  # no FOR SHARE script-row lock. Reads only (definitions by name, the activator's user row);
  # takes no lock. A graph with no non-empty `entity_writes` attribute is `:ok` and needs no
  # activator.
  #
  # Reports ALL violations at once (`:entity_writes_invalid`), in graph order, each node's
  # sorted by {index, code}. A node-level refusal carries index 0.
  @doc false
  @spec check_entity_writes(
          ProcessDefinition.t() | map(),
          String.t(),
          EntityPort.activator() | nil
        ) ::
          :ok
          | {:error, :graph_structure_invalid}
          | {:error, {:entity_writes_invalid, [entity_writes_violation()]}}
  def check_entity_writes(%{graph: graph_map} = definition, prefix, activator)
      when is_binary(prefix) do
    case entity_write_nodes(graph_map) do
      :error ->
        {:error, :graph_structure_invalid}

      {:ok, [], _nodes} ->
        :ok

      {:ok, declared, nodes} ->
        activator_codes = activator_codes(activator, prefix)

        preseeded =
          MapSet.union(
            preseeded_variable_names(nodes),
            declared_variable_keys(definition, prefix)
          )

        violations =
          Enum.flat_map(declared, fn {node, writes} ->
            node_entity_writes_violations(
              node,
              writes,
              declared,
              preseeded,
              activator_codes,
              prefix
            )
          end)

        case violations do
          [] -> :ok
          violations -> {:error, {:entity_writes_invalid, violations}}
        end
    end
  end

  # The `activated_by` document recorded on the row an activation path makes ACTIVE: the
  # activator's authority plus the (entity_type, "create") pairs of the graph's lines; nil when
  # the graph has no lines (the column stays NULL) or no activator is given (such a graph was
  # refused by check_entity_writes/3 already).
  @doc false
  @spec entity_writes_activated_by(
          ProcessDefinition.t() | map(),
          EntityPort.activator() | nil,
          DateTime.t()
        ) :: map() | nil
  def entity_writes_activated_by(%{graph: graph_map}, activator, %DateTime{} = now) do
    case {entity_write_nodes(graph_map), activator} do
      {{:ok, [_ | _] = declared, _nodes}, %{user_id: _} = activator} ->
        pairs =
          for {_node, writes} <- declared,
              is_list(writes),
              %{"entity_type" => entity_type} <- writes,
              is_binary(entity_type),
              do: {entity_type, "create"}

        Activator.build_record(activator, pairs, now)

      _no_lines_or_activator ->
        nil
    end
  end

  # {:ok, [{node, raw_entity_writes}], all_nodes} for the nodes carrying a non-empty
  # `entity_writes` attribute, in graph order; :error for a graph that does not parse.
  defp entity_write_nodes(graph_map) do
    case Graph.from_map(graph_map) do
      {:ok, %Graph{nodes: nodes}} ->
        declared =
          for %Graph.Node{attributes: %{"entity_writes" => writes}} = node <- nodes,
              writes not in [nil, []],
              do: {node, writes}

        {:ok, declared, nodes}

      :error ->
        :error
    end
  end

  # The activator must hold :EntitiesRecordsWrite AND resolve to an ACTIVE user row of this
  # tenant (decision 0054 D4a.4, open point 9): an absent row fails closed like a deactivated
  # user, because the write would be refused at run time anyway.
  defp activator_codes(%{user_id: user_id, entities_records_write?: true}, prefix)
       when is_binary(user_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(user_id),
         {:ok, %{status: :active}} <- Letflow.Identity.get_user(uuid, prefix: prefix) do
      []
    else
      _inactive_or_absent -> [:entity_write_activator_required]
    end
  end

  defp activator_codes(_activator, _prefix), do: [:entity_write_activator_required]

  defp node_entity_writes_violations(
         %Graph.Node{id: node_id, node_type: node_type},
         writes,
         declared,
         preseeded,
         activator_codes,
         prefix
       ) do
    node_codes =
      cond do
        not is_list(writes) -> [:entity_writes_not_a_list]
        node_type != :HUMAN_TASK -> [:entity_writes_node_type_not_supported]
        true -> []
      end

    activator_node_codes = if is_list(writes), do: activator_codes, else: []

    line_violations =
      if is_list(writes) and node_type == :HUMAN_TASK do
        other_vars =
          for {%Graph.Node{id: other_id}, other_writes} <- declared,
              other_id != node_id,
              is_list(other_writes),
              %{"output_record_id_var" => var} <- other_writes,
              is_binary(var),
              do: var

        ctx = %{
          prefix: prefix,
          node_id: node_id,
          node_type: node_type,
          graph_output_vars: other_vars
        }

        preseeded_violations =
          for {%{"output_record_id_var" => var}, index} <- Enum.with_index(writes),
              is_binary(var),
              MapSet.member?(preseeded, var),
              do: %{index: index, code: :entity_write_output_var_preseeded}

        case EntityPort.impl().validate_lines(writes, ctx) do
          :ok -> preseeded_violations
          {:error, violations} -> violations ++ preseeded_violations
        end
      else
        []
      end

    (Enum.map(node_codes ++ activator_node_codes, &%{index: 0, code: &1}) ++ line_violations)
    |> Enum.sort_by(&{&1.index, &1.code})
    |> Enum.map(&%{node_id: node_id, index: &1.index, code: &1.code})
  end

  # The variable keys registered in `variable_schemas` for this definition row (none for a row
  # that has no id yet, or a prefix the read refuses).
  defp declared_variable_keys(%{id: id}, prefix) when is_binary(id) do
    case VariableSchema.fetch_schemas(Repo, id, prefix: prefix) do
      {:ok, schemas} -> schemas |> Map.keys() |> MapSet.new()
      {:error, _reason} -> MapSet.new()
    end
  end

  defp declared_variable_keys(_definition, _prefix), do: MapSet.new()

  # Variable names the graph itself pre-seeds from authored data: a HUMAN_TASK form property
  # a `required_outputs` entry or a `variable_schemas` key. An `output_record_id_var` must not be one (0054 D1).
  defp preseeded_variable_names(nodes) do
    nodes
    |> Enum.flat_map(fn
      %Graph.Node{node_type: :HUMAN_TASK, attributes: %{} = attrs} ->
        form_properties =
          case attrs do
            %{"form_schema" => %{"properties" => %{} = properties}} -> Map.keys(properties)
            _no_form -> []
          end

        required =
          case attrs do
            %{"required_outputs" => outputs} when is_list(outputs) -> outputs
            _none -> []
          end

        form_properties ++ required

      _other_node ->
        []
    end)
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
  end

  defp run_service_scope_validator(_definition, _tenant_id, nil), do: :ok

  defp run_service_scope_validator(%ProcessDefinition{graph: graph_map}, tenant_id, validator)
       when is_function(validator, 2) do
    case Graph.from_map(graph_map) do
      {:ok, graph} ->
        case validator.(graph, tenant_id) do
          :ok -> :ok
          {:error, reason} -> {:error, {:service_scope_violation, reason}}
        end

      :error ->
        {:error, :graph_structure_invalid}
    end
  end

  # REQ-372 -- the release/promotion submission gate (design §3.2). Runs
  # SemanticValidation.validate/2 against a FRESH VariableSchema.fetch_schemas/3
  # read, issued inside this very transaction (definition's row already
  # locked FOR UPDATE by run_activate_transaction/4) -- there is no cache
  # anywhere in this path, so the only way the result can differ between two
  # calls is if the underlying variable_schemas rows or the graph itself
  # actually changed. REQ-455 adds Graph.validate_flow/1 here; validate_graph/1,
  # validate_node_attributes/1, validate_edge_conditions/1 are deliberately
  # NOT newly wired into activate/2 (REQ-372 design §3.2, §5 OQ-6).
  @spec run_semantic_validation(ProcessDefinition.t(), prefix :: String.t()) ::
          :ok
          | {:error, :graph_structure_invalid}
          | {:error, {:semantic_validation_failed, [Graph.Violation.t()]}}
          | {:error,
             {:semantic_validation_precondition_failed, :missing_prefix | :invalid_definition_id}}
  defp run_semantic_validation(%ProcessDefinition{} = definition, prefix) do
    case Graph.from_map(definition.graph) do
      {:ok, graph} ->
        case VariableSchema.fetch_schemas(Repo, definition.id, prefix: prefix) do
          {:ok, declared_fields} ->
            # REQ-455: the flow checks run here too, so a DRAFT stored before
            # they existed cannot be activated with a dead end or missing default.
            violations =
              Graph.validate_flow(graph).violations ++
                SemanticValidation.validate(graph, declared_fields).violations

            case violations do
              [] -> :ok
              violations -> {:error, {:semantic_validation_failed, violations}}
            end

          {:error, reason} ->
            {:error, {:semantic_validation_precondition_failed, reason}}
        end

      :error ->
        {:error, :graph_structure_invalid}
    end
  end

  # REQ-125 §5.3 -- both writes below (the deprecate-prior-active update AND
  # the activate-this-one update) are "the definition set changed", so both
  # get their own assigned sequence_number, inside this same transaction. The
  # deprecate update touches 0 or 1 rows (uq_active_definition guarantees at
  # most one prior active per name) -- if it touches 0, the sequence number
  # assigned for it is simply unused (a small, harmless gap in the counter,
  # the same class of gap create/2's ON CONFLICT DO NOTHING path can produce;
  # the design's own §2 guarantee is monotonic ordering, never gap-free
  # numbering). Called from inside run_activate_transaction/4's
  # Repo.transaction/1 -- Repo.rollback/1 here aborts that whole transaction,
  # so both this row's writes AND any already-assigned sequence numbers are
  # discarded together on a locking failure.
  defp activate_draft(%ProcessDefinition{name: name} = draft, prefix, tenant_id, activator) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    activated_by = entity_writes_activated_by(draft, activator, now)

    case assign_definition_sequence(tenant_id, prefix) do
      {:ok, deprecate_seq} ->
        ProcessDefinition
        |> where([d], d.name == ^name and d.status == :active)
        |> select([d], d)
        |> Repo.update_all(
          [set: [status: :deprecated, updated_at: now, sequence_number: deprecate_seq]],
          prefix: prefix
        )

        activate_draft_row(draft, prefix, tenant_id, now, activated_by)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  # REQ-195 -- `draft` (the pre-activation row, already fetched/locked by
  # run_activate_transaction/4) is this audit row's before_state; `updated`
  # (the now-ACTIVE row) is its after_state. actor_id: nil, see
  # record_definition_audit/5's own comment.
  defp activate_draft_row(
         %ProcessDefinition{id: id} = draft,
         prefix,
         tenant_id,
         now,
         activated_by
       ) do
    case assign_definition_sequence(tenant_id, prefix) do
      {:ok, activate_seq} ->
        {1, [updated]} =
          ProcessDefinition
          |> where([d], d.id == ^id and d.status == :draft)
          |> select([d], d)
          |> Repo.update_all(
            [
              set: [
                status: :active,
                updated_at: now,
                sequence_number: activate_seq,
                activated_by: activated_by
              ]
            ],
            prefix: prefix
          )

        case record_definition_audit("definition.activate", id, draft, updated, prefix) do
          {:ok, _entry} -> {:activated, updated}
          {:error, reason} -> Repo.rollback(reason)
        end

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp interpret_activate_result({:ok, {:already_active, definition}}) do
    {:ok, %{definition: definition, already_active: true}}
  end

  defp interpret_activate_result({:ok, {:activated, definition}}) do
    {:ok, %{definition: definition, already_active: false}}
  end

  defp interpret_activate_result({:error, :not_found}), do: {:error, :not_found}
  defp interpret_activate_result({:error, :not_draft}), do: {:error, :not_draft}

  defp interpret_activate_result({:error, :graph_structure_invalid}) do
    {:error, :graph_structure_invalid}
  end

  defp interpret_activate_result({:error, {:service_scope_violation, _reason}} = error), do: error

  # REQ-372 -- pure pass-throughs (identical in shape and intent to the
  # {:service_scope_violation, _} clause above), so this function's explicit
  # per-shape matching stays exhaustive over activate/2's enlarged return
  # union (INV-8: no catch-all clause added).
  defp interpret_activate_result({:error, {:semantic_validation_failed, _violations}} = error),
    do: error

  defp interpret_activate_result(
         {:error, {:semantic_validation_precondition_failed, _reason}} = error
       ),
       do: error

  # REQ-125 -- assign_definition_sequence/2's locking-protocol failure,
  # surfaced unchanged (common_error()). Explicit clause rather than relying
  # on activate/2's own outer rescue to catch a FunctionClauseError here
  # (INV-8 -- typed, not incidental).
  defp interpret_activate_result({:error, {:sequence_conflict, _reason}} = error), do: error

  # GH 2534 PR 7c-1 (design 4.5): the script-binding refusal, a pure pass-through.
  defp interpret_activate_result({:error, {:script_binding_invalid, _node_id, _reason}} = error),
    do: error

  # GH #2587 PR A1b (design 2A.4): the reserved-namespace refusal, a pure pass-through.
  defp interpret_activate_result(
         {:error, {:expression_references_reserved_variable, _references}} = error
       ),
       do: error

  # GH #2587 PR B1: the entity_writes refusal, a pure pass-through.
  defp interpret_activate_result({:error, {:entity_writes_invalid, _violations}} = error),
    do: error

  # -----------------------------------------------------------------------------------
  # deprecate/2 & archive/2 helpers (design §6.3) -- identical shape, different
  # from-status/to-status pair; archive/2 additionally stamps archived_at.
  # -----------------------------------------------------------------------------------

  defp transition(id, opts, from_status, to_status) do
    prefix = Keyword.get(opts, :prefix)

    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      try do
        run_transition(id, prefix, tenant_id, from_status, to_status)
      rescue
        exception -> {:error, {:transaction_failed, exception}}
      end
    end
  end

  # REQ-125 §5.3 -- deprecate/2 and archive/2 both gain a sequence_number
  # stamp inside this existing transaction. Unlike activate_draft/3's
  # unconditional deprecate-prior-active update, this one is a genuinely
  # conditional guarded UPDATE (`WHERE id = $1 AND status = $2`) -- if 0 rows
  # match, fallback_lookup/2 rolls the *whole* transaction back (:not_found or
  # :invalid_status_transition), which discards the just-assigned sequence
  # number along with everything else. So this path never burns a number on a
  # rejected transition.
  defp run_transition(id, prefix, tenant_id, from_status, to_status) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    action = transition_action(to_status)

    Repo.transaction(fn ->
      case assign_definition_sequence(tenant_id, prefix) do
        {:ok, seq} ->
          # REQ-195 -- fetched before the update, inside this same
          # transaction, as this audit row's before_state.
          before = Repo.get(ProcessDefinition, id, prefix: prefix)
          set = transition_set(to_status, now, seq)

          ProcessDefinition
          |> where([d], d.id == ^id and d.status == ^from_status)
          |> select([d], d)
          |> Repo.update_all([set: set], prefix: prefix)
          |> case do
            {1, [updated]} ->
              case record_definition_audit(action, id, before, updated, prefix) do
                {:ok, _entry} -> updated
                {:error, reason} -> Repo.rollback(reason)
              end

            {0, _count_and_rows} ->
              fallback_lookup(id, prefix)
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp transition_action(:deprecated), do: "definition.deprecate"
  defp transition_action(:archived), do: "definition.archive"

  defp transition_set(:archived, now, seq),
    do: [status: :archived, updated_at: now, archived_at: now, sequence_number: seq]

  defp transition_set(status, now, seq),
    do: [status: status, updated_at: now, sequence_number: seq]

  defp fallback_lookup(id, prefix) do
    case Repo.get(ProcessDefinition, id, prefix: prefix) do
      nil -> Repo.rollback(:not_found)
      %ProcessDefinition{} -> Repo.rollback(:invalid_status_transition)
    end
  end

  # -----------------------------------------------------------------------------------
  # graph_struct_from_map/1 -- moved to Letflow.Definitions.Graph.from_map/1
  # (lib/letflow/design/req045-instance-start-engine-shell.md §8, REQ-045):
  # Letflow.Engine.create/2 needs the identical conversion and cannot call a
  # private function across module boundaries, so this logic now lives once,
  # on the struct's own module, rather than being duplicated a second time in
  # Letflow.Engine. convert_graph/1 and run_service_scope_validator/3 above
  # call Graph.from_map/1 directly; behavior is unchanged.
  # -----------------------------------------------------------------------------------

  # -----------------------------------------------------------------------------------
  # rollback_definition_version/4 helpers (design §5, §6, §7)
  # -----------------------------------------------------------------------------------

  # Design §5, "Exception safety": the try/rescue wraps only the pointer-swap
  # transaction (Step 2), mirroring activate/2's own try/rescue -> {:transaction_failed,
  # _} shape. Steps 3/4 (event-append, promotion_reviews supersede) run afterward, own
  # errors, and are never folded into :transaction_failed.
  # tenant_id is accepted (and left as a real, non-underscored parameter name in
  # the @spec-less signature below only for symmetry with its call site,
  # rollback_definition_version/4, which the design's §3.1 explicitly keeps
  # unchanged since permission_checker.(actor_id, tenant_id) there is a genuine
  # functional consumer, not stamping) but is no longer used inside this
  # function's own body post-Decision-0006-D2 (REQ-064) -- both
  # run_rollback_transaction/3 and finish_rollback/7 dropped their tenant_id
  # parameters once process_definitions.tenant_id/promotion_reviews.tenant_id
  # stopped existing. Prefixed _tenant_id to avoid an unused-variable warning
  # without changing rollback_definition_version/4's own call shape.
  defp do_rollback(
         process_key,
         target_version,
         actor_id,
         _tenant_id,
         prefix,
         event_appender,
         activator
       ) do
    transaction_result =
      try do
        run_rollback_transaction(process_key, target_version, prefix, activator)
      rescue
        exception -> {:error, {:transaction_failed, exception}}
      end

    with {:ok,
          %{activated_row: activated_row, rolled_back_from_version: rolled_back_from_version}} <-
           transaction_result do
      finish_rollback(
        process_key,
        target_version,
        actor_id,
        prefix,
        event_appender,
        activated_row,
        rolled_back_from_version
      )
    end
  end

  # Design §5 step 2: locks every version row for process_key FOR UPDATE in one
  # statement (generalizes run_activate_transaction/4's single-row lock to the whole
  # set), then the three guard cases in the order §5 step 2c requires (already_active
  # checked before the target-row lookup -- see that section's note on why this
  # ordering can never disagree with checking version_never_active first).
  #
  # Post-Decision-0006-D2 (REQ-064): the row-selection predicate below was
  # `d.tenant_id == ^tenant_id and d.name == ^process_key`; process_definitions.tenant_id
  # no longer exists as a column, so the predicate is now `d.name == ^process_key`
  # alone -- `prefix` (passed to Repo.all/2 below) already confines this query to
  # exactly one tenant's schema, so the dropped tenant_id filter was redundant with
  # that schema boundary, not an independent safety check. tenant_id is no longer
  # needed by this function at all -- dropped from its parameter list.
  defp run_rollback_transaction(process_key, target_version, prefix, activator) do
    Repo.transaction(fn ->
      rows =
        ProcessDefinition
        |> where([d], d.name == ^process_key)
        |> lock("FOR UPDATE")
        |> Repo.all(prefix: prefix)

      current_active = Enum.find(rows, &(&1.status == :active))

      cond do
        is_nil(current_active) ->
          Repo.rollback(:process_key_not_found)

        current_active.version == target_version ->
          Repo.rollback(:already_active)

        true ->
          # :active | :deprecated per design §3's SUPERSEDED -> :deprecated mapping;
          # :archived deliberately excluded (INV-RB-4).
          target_row =
            Enum.find(
              rows,
              &(&1.version == target_version and &1.status in [:active, :deprecated])
            )

          if is_nil(target_row) do
            Repo.rollback(:version_never_active)
          else
            # GH 2534 PR 7c-1 (design 4.5): the re-activated graph's script bindings, inside
            # this transaction, before the pointer swap. GH #2587 PR A1b (design 2A.3): the
            # reserved-namespace references first.
            with :ok <- check_reserved_references(target_row),
                 :ok <- check_entity_writes(target_row, prefix, activator),
                 :ok <- check_script_bindings(target_row, prefix) do
              swap_active_pointer(current_active, target_row, prefix, activator)
            else
              {:error, reason} -> Repo.rollback(reason)
            end
          end
      end
    end)
  end

  # Design §5 step 2e -- mirrors activate_draft/2's exact two-Repo.update_all swap shape,
  # generalized to the specific already-locked row ids (current_active.id/target_row.id)
  # rather than a fresh WHERE name = ... AND status = :active re-match, avoiding a
  # theoretically-possible TOCTOU gap between this transaction's own row-lock and the
  # write. Both rows were locked at the FOR UPDATE read above, so both updates are
  # guaranteed to affect exactly 1 row.
  defp swap_active_pointer(current_active, target_row, prefix, activator) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    # GH #2587 PR B1: the re-activating principal's authority is recorded afresh (NULL for a
    # graph without lines), never carried over from the row's earlier activation.
    activated_by = entity_writes_activated_by(target_row, activator, now)

    ProcessDefinition
    |> where([d], d.id == ^current_active.id)
    |> select([d], d)
    |> Repo.update_all([set: [status: :deprecated, updated_at: now]], prefix: prefix)

    {1, [activated_row]} =
      ProcessDefinition
      |> where([d], d.id == ^target_row.id)
      |> select([d], d)
      |> Repo.update_all(
        [set: [status: :active, updated_at: now, activated_by: activated_by]],
        prefix: prefix
      )

    %{activated_row: activated_row, rolled_back_from_version: current_active.version}
  end

  # Design §5 step 3/4, §4.2: called after TX1 commits, never nested inside it -- this
  # function does not assume anything about opts[:event_appender]'s own transactionality
  # (same stance Promotion.promote_definition/3 already established). A {:error, reason}
  # here propagates unchanged; the pointer swap has already durably committed.
  #
  # Post-Decision-0006-D2 (REQ-064): no longer takes tenant_id -- it was only
  # ever forwarded to supersede_matching_review/4's now-removed tenant_id
  # filter (see that function's own comment).
  defp finish_rollback(
         process_key,
         target_version,
         actor_id,
         prefix,
         event_appender,
         activated_row,
         rolled_back_from_version
       ) do
    event_attrs = %{
      event_type: "DEFINITION_VERSION_ROLLED_BACK",
      process_key: process_key,
      from_version: rolled_back_from_version,
      to_version: target_version,
      actor_id: actor_id
    }

    case event_appender.(event_attrs, prefix) do
      {:ok, %{event_id: event_id}} ->
        superseded_review_id = supersede_matching_review(process_key, event_id, prefix)

        {:ok,
         %{
           definition_id: activated_row.id,
           version: target_version,
           rolled_back_from_version: rolled_back_from_version,
           superseded_review_id: superseded_review_id,
           event_id: event_id
         }}

      {:error, _reason} = error ->
        error
    end
  end

  # Design §6/§7 -- the cardinality-branched promotion_reviews supersede-lookup. Do not
  # "simplify" this into blanket-superseding every match: promotion_reviews.def_id stores
  # plan.process_key (a string), not a process_definitions.id, so there is no way to
  # correlate a review to the *specific* former-active definition once more than one
  # applied/approved review has accumulated for the same process_key (the ordinary state
  # of the table for any process_key promoted more than once, not a rare edge case). This
  # asymmetric handling -- zero matches -> nil, exactly one -> supersede it, more than one
  # -> nil, mutate nothing -- is exactly the fix for the data-integrity defect
  # CODE-DESIGN-VALIDATOR's Rework 1 blocked on (design §0, §6, INV-RB-10).
  #
  # Post-Decision-0006-D2 (REQ-064): the lookup predicate below was
  # `r.tenant_id == ^tenant_id and r.def_id == ^process_key and ...`;
  # promotion_reviews.tenant_id no longer exists as a column, so the predicate is
  # now `r.def_id == ^process_key and ...` alone -- `prefix` (passed to Repo.all/2
  # below) already confines this query to exactly one tenant's schema. tenant_id
  # is no longer needed by this function at all -- dropped from its parameter list.
  defp supersede_matching_review(process_key, event_id, prefix) do
    matching_reviews =
      PromotionReview
      |> where(
        [r],
        r.def_id == ^process_key and r.status in [:applied, :approved]
      )
      |> Repo.all(prefix: prefix)

    case matching_reviews do
      [] ->
        nil

      [single_review] ->
        case PromotionReviewStore.supersede_review(single_review.id, event_id, prefix: prefix) do
          {:ok, %PromotionReview{id: id}} -> id
          # A genuine optimistic-lock race, or (in practice unreachable, since the row
          # was just read above) a since-deleted row -- design §6's own resolution:
          # non-fatal to the overall rollback, since TX1 and the event-append have
          # already durably committed by this point (OQ-6).
          {:error, _reason} -> nil
        end

      [_, _ | _] ->
        # Ambiguous -- more than one applied/approved review exists for this
        # process_key and no genuine version-scoped correlation is recoverable from
        # this schema (design §0's Rework-1 evidence, §6). Mutate nothing rather than
        # heuristically guess among several candidates.
        nil
    end
  end

  # -----------------------------------------------------------------------------------
  # apply_promotion_assertion_rerun/6 helpers (design §6, §7)
  # -----------------------------------------------------------------------------------

  # PROVENANCE (historical, not current decision authority):
  # Design §7.1 -- direct port of buildIdempotencyKey (assertion_rerun.zig:120-122).
  defp build_idempotency_key(review_id, plan_digest) do
    "promotion_rerun:" <> review_id <> ":" <> plan_digest
  end

  # Design §7.1 steps 1-3: reuses the exact "attempt an insert with on_conflict:
  # :nothing, then re-fetch by the client-generated id to disambiguate
  # real-insert-vs-suppressed" idiom already shipped in
  # Letflow.EventStore.claim_idempotency/3 and insert_definition/3 above -- not raw
  # SQL, not a new idiom. status/assertions_*/failing_assertion_ids are never cast
  # here -- a winning insert starts at its column defaults (:running, 0, []).
  # Post-Decision-0006-D2 (REQ-064): tenant_id is still accepted as a
  # parameter (its caller, apply_promotion_assertion_rerun/6, still resolves
  # and threads a real tenant_id -- see that function's own note), but is no
  # longer stamped into attrs or used as an on_conflict/get_by scoping key
  # below -- promotion_assertion_runs.tenant_id no longer exists as a column,
  # and prefix already scopes every one of these calls to exactly one
  # tenant's schema. See PromotionAssertionRun's own moduledoc/migration
  # header for the restated idempotency contract this shape change preserves.
  defp claim_or_fetch_assertion_run(_tenant_id, review_id, plan_digest, idempotency_key, prefix) do
    attrs = %{
      review_id: review_id,
      idempotency_key: idempotency_key,
      plan_digest: plan_digest
    }

    changeset = PromotionAssertionRun.insert_changeset(%PromotionAssertionRun{}, attrs)

    case Repo.insert(changeset,
           on_conflict: :nothing,
           conflict_target: [:idempotency_key],
           prefix: prefix
         ) do
      {:ok, %PromotionAssertionRun{id: attempted_id}} ->
        case Repo.get(PromotionAssertionRun, attempted_id, prefix: prefix) do
          %PromotionAssertionRun{} = won ->
            # Found -- this call genuinely won the insert (a fresh :running row it
            # now owns exclusively -- ON CONFLICT DO NOTHING guarantees exactly one
            # winner for this idempotency_key, within this tenant's schema).
            {:ok, {:claimed, won}}

          nil ->
            fetch_existing_assertion_run(idempotency_key, prefix)
        end

      {:error, %Ecto.Changeset{} = changeset} ->
        if review_not_found_error?(changeset) do
          {:error, :review_not_found}
        else
          {:error, changeset}
        end
    end
  end

  # Not found (suppressed by the unique-index conflict) -- fetch the real existing
  # row. No sandbox is claimed on this path (AC1's own literal wording, INV-AR-4).
  #
  # Post-Decision-0006-D2 (REQ-064): dropped the tenant_id parameter --
  # promotion_assertion_runs.tenant_id no longer exists as a column, so this
  # Repo.get_by/3 filters on idempotency_key alone; prefix already scopes the
  # lookup to one tenant's schema.
  defp fetch_existing_assertion_run(idempotency_key, prefix) do
    case Repo.get_by(
           PromotionAssertionRun,
           [idempotency_key: idempotency_key],
           prefix: prefix
         ) do
      %PromotionAssertionRun{} = existing -> {:ok, {:idempotent_hit, existing}}
      nil -> {:error, {:idempotency_lookup_failed, :sidecar_row_missing}}
    end
  end

  defp review_not_found_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, opts}} ->
      Keyword.get(opts, :constraint) == :foreign and
        Keyword.get(opts, :constraint_name) == "promotion_assertion_runs_review_id_fkey"
    end)
  end

  # Design §7.2 -- SandboxPool.claim/2's own shipped implementation only ever
  # returns these two named error atoms (traced directly, sandbox_pool.ex); no
  # sandbox was ever claimed on either, so no release is needed or possible --
  # write a fail-closed final UPDATE directly (no try needed, nothing here can
  # leak a sandbox), then return the error unchanged (design §7.2 -- see §7.4 for
  # why leaving the row stuck at `running` forever would be a correctness hazard
  # this implementation deliberately avoids).
  defp claim_sandbox_and_proceed(
         run,
         artifact,
         sandbox_pool,
         max_wait_ms,
         tenant_id,
         prefix,
         event_appender,
         assertion_evaluator
       ) do
    case SandboxPool.claim(max_wait_ms, sandbox_pool) do
      {:ok, %SandboxClaim{} = claim} ->
        run_replay_span(
          run,
          artifact,
          claim,
          sandbox_pool,
          tenant_id,
          prefix,
          event_appender,
          assertion_evaluator
        )

      {:error, reason} when reason in [:sandbox_unavailable, :provision_failed] ->
        %{assertions_total: total, assertions_failed: failed, failing_assertion_ids: failing_ids} =
          fail_closed_counts(artifact)

        _ =
          finalize_and_write(
            run,
            tenant_id,
            prefix,
            nil,
            :not_attempted,
            total,
            0,
            failed,
            failing_ids,
            event_appender
          )

        {:error, reason}
    end
  end

  # Design §7.6 -- the try/rescue crash-safety wrapper (§2.3). Wraps Steps 3-6
  # (fixture load, replay, teardown+precedence+eventing, the final UPDATE) --
  # NOT Step 2's claim itself (a claim failure needs no release, matching
  # rollback_definition_version/4's own "try/rescue wraps only the step that can
  # leak a resource" scoping note).
  defp run_replay_span(
         run,
         artifact,
         %SandboxClaim{sandbox_id: sandbox_id, schema_name: schema_name},
         sandbox_pool,
         tenant_id,
         prefix,
         event_appender,
         assertion_evaluator
       ) do
    try do
      case FixtureLoader.load_fixtures_only(schema_name, artifact.fixtures, []) do
        :ok ->
          finish_replay(
            run,
            artifact,
            sandbox_id,
            sandbox_pool,
            tenant_id,
            prefix,
            event_appender,
            assertion_evaluator
          )

        {:error, _reason} ->
          handle_fixture_load_failure(
            run,
            artifact,
            sandbox_id,
            sandbox_pool,
            tenant_id,
            prefix,
            event_appender
          )
      end
    rescue
      exception ->
        # Best-effort release attempt -- may be redundant if teardown already ran
        # and succeeded before the exception fired (e.g. the exception originated
        # in the final UPDATE itself) -- SandboxPool.release/2 on an
        # already-released sandbox_id returns {:error, :not_found}, itself
        # swallowed here, matching provision_sandbox/0's own "cleanup, not the
        # primary error path" stance.
        safe_release(sandbox_id, sandbox_pool)
        # Best-effort fail-closed row update -- swallows its OWN failure too (the
        # DB itself may be unreachable, which is presumably why an exception fired
        # in the first place).
        safe_fail_closed_update(run, artifact, sandbox_id, prefix, exception)
        {:error, {:transaction_failed, exception}}
    end
  end

  # Design §7.3 -- fixtures[] failed to load: the sandbox WAS claimed and must be
  # released. This is a typed return, not a raised exception, so it's handled by
  # ordinary pattern matching inside run_replay_span/8's own try body (still
  # covered by that try's rescue if release or the write itself unexpectedly
  # raises). The underlying FixtureLoader error is deliberately not surfaced
  # verbatim -- :fixture_load_failed is this function's own, coarser, stable
  # error tag: the three underlying FixtureLoadError variants collapse into one
  # so callers can pattern-match on a stable tag instead of an error-type
  # taxonomy that could grow.
  defp handle_fixture_load_failure(
         run,
         artifact,
         sandbox_id,
         sandbox_pool,
         tenant_id,
         prefix,
         event_appender
       ) do
    release_outcome = SandboxPool.release(sandbox_id, sandbox_pool)

    %{assertions_total: total, assertions_failed: failed, failing_assertion_ids: failing_ids} =
      fail_closed_counts(artifact)

    _ =
      finalize_and_write(
        run,
        tenant_id,
        prefix,
        sandbox_id,
        release_outcome,
        total,
        0,
        failed,
        failing_ids,
        event_appender
      )

    {:error, :fixture_load_failed}
  end

  # Design §6/§7.5 -- fixtures loaded successfully: replay every assertion twice
  # under the frozen-clock/seeded-RNG injection, release the sandbox, then apply
  # the teardown precedence rule and write the single final UPDATE.
  defp finish_replay(
         run,
         artifact,
         sandbox_id,
         sandbox_pool,
         tenant_id,
         prefix,
         event_appender,
         assertion_evaluator
       ) do
    %{
      assertions_total: total,
      assertions_passed: passed,
      assertions_failed: failed,
      failing_assertion_ids: failing_ids
    } = replay_assertions(artifact, assertion_evaluator)

    release_outcome = SandboxPool.release(sandbox_id, sandbox_pool)

    finalize_and_write(
      run,
      tenant_id,
      prefix,
      sandbox_id,
      release_outcome,
      total,
      passed,
      failed,
      failing_ids,
      event_appender
    )
  end

  # Design §7.4/§7.5 unified: pre_teardown_status is derived from assertions_failed
  # the same way on every path (real replay counts, or fail-closed counts on an
  # infrastructure-failure path -- fail_closed_counts/1 guarantees assertions_failed
  # is never 0, so pre_teardown_status is always :failed on those paths, which is
  # exactly design §7.4's own literal "status is set to :failed" rule, derived here
  # rather than special-cased). release_outcome is one of :not_attempted (no
  # sandbox was ever claimed, §7.2), :ok, or {:error, reason} -- the single shared
  # precedence + eventing rule (recordTeardownFailure's own CASE WHEN, §7.5)
  # handles all three uniformly.
  defp finalize_and_write(
         run,
         tenant_id,
         prefix,
         sandbox_id,
         release_outcome,
         assertions_total,
         assertions_passed,
         assertions_failed,
         failing_assertion_ids,
         event_appender
       ) do
    pre_teardown_status = if assertions_failed == 0, do: :passed, else: :failed

    {final_status, teardown_error, teardown_event_appended} =
      apply_teardown_precedence(
        run,
        tenant_id,
        sandbox_id,
        prefix,
        pre_teardown_status,
        release_outcome,
        event_appender
      )

    attrs = %{
      status: final_status,
      sandbox_id: sandbox_id,
      assertions_total: assertions_total,
      assertions_passed: assertions_passed,
      assertions_failed: assertions_failed,
      failing_assertion_ids: failing_assertion_ids,
      teardown_error: teardown_error,
      completed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    case run |> PromotionAssertionRun.update_changeset(attrs) |> Repo.update(prefix: prefix) do
      {:ok, %PromotionAssertionRun{} = updated_run} ->
        {:ok, build_result(updated_run, false, teardown_event_appended)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  # No sandbox was ever claimed (§7.2) -- nothing to release, nothing to append.
  defp apply_teardown_precedence(
         _run,
         _tenant_id,
         _sandbox_id,
         _prefix,
         pre_teardown_status,
         :not_attempted,
         _event_appender
       ) do
    {pre_teardown_status, nil, true}
  end

  # Teardown succeeded -- final_status is exactly the pre-teardown status, nothing
  # to append (design §7.5's :ok branch).
  defp apply_teardown_precedence(
         _run,
         _tenant_id,
         _sandbox_id,
         _prefix,
         pre_teardown_status,
         :ok,
         _event_appender
       ) do
    {pre_teardown_status, nil, true}
  end

  # PROVENANCE (historical, not current decision authority):
  # Teardown (release) failed -- the recordTeardownFailure precedence rule
  # (assertion_rerun.zig:620-631, quoted in design §0/§7.5): a teardown failure
  # never demotes an already-failed run, and only ever demotes a passed run into
  # :teardown_failed (PRM-07 AC2's green-gate case, INV-AR-6). The
  # PROMOTION_ASSERTION_TEARDOWN_FAILED event is appended exactly once, regardless
  # of which branch pre_teardown_status took (design §7.5) -- INV-AR-8: a failure
  # here never alters final_status/assertions_failed, only teardown_event_appended.
  defp apply_teardown_precedence(
         run,
         tenant_id,
         sandbox_id,
         prefix,
         pre_teardown_status,
         {:error, release_reason},
         event_appender
       ) do
    final_status = if pre_teardown_status == :failed, do: :failed, else: :teardown_failed
    teardown_error = describe_release_failure(release_reason)

    teardown_event_appended =
      append_teardown_failure_event(
        event_appender,
        run,
        sandbox_id,
        tenant_id,
        prefix,
        teardown_error
      )

    {final_status, teardown_error, teardown_event_appended}
  end

  defp describe_release_failure(release_reason) do
    "sandbox release failed: " <> to_string(release_reason)
  end

  defp append_teardown_failure_event(
         event_appender,
         run,
         sandbox_id,
         tenant_id,
         prefix,
         teardown_error
       ) do
    event_attrs = %{
      event_type: "PROMOTION_ASSERTION_TEARDOWN_FAILED",
      run_id: run.id,
      sandbox_id: sandbox_id,
      tenant_id: tenant_id,
      error: teardown_error
    }

    case event_appender.(event_attrs, prefix) do
      {:ok, _} -> true
      # Absorbed, never propagated as this function's own error (design §7.5,
      # INV-AR-8) -- the same "don't let a side-effect's own failure corrupt an
      # already-computed, already-durable-once-written outcome" resolution
      # finish_rollback/8's own OQ-6 already established for an analogous tension.
      {:error, _reason} -> false
    end
  end

  # Design §7.4 -- every assertion is conservatively treated as failed on an
  # infrastructure failure. Leaving a claim/fixture-load-failure row's
  # assertions_failed at 0 (with no assertions ever attempted) would let a
  # naive future reader checking assertions_failed == 0 without also checking
  # status misread an infrastructure failure as a green gate.
  # max(assertions_total, 1)
  # guarantees assertions_failed is never 0 even for a zero-assertion artifact
  # (INV-AR-7).
  defp fail_closed_counts(%PromotionArtifact{assertions: assertions}) do
    assertions_total = length(assertions)
    assertions_failed = max(assertions_total, 1)

    failing_assertion_ids =
      if assertions_total > 0 do
        Enum.map(assertions, & &1.id)
      else
        ["__infrastructure_failure__"]
      end

    %{
      assertions_total: assertions_total,
      assertions_failed: assertions_failed,
      failing_assertion_ids: failing_assertion_ids
    }
  end

  # Best-effort release attempt for the rescue clause only (run_replay_span/8) --
  # swallows any exception SandboxPool.release/2 itself might raise, since this
  # runs OUTSIDE the try that would otherwise catch it. Its return value is
  # deliberately discarded by the caller (best-effort, not the primary error path).
  defp safe_release(sandbox_id, sandbox_pool) do
    SandboxPool.release(sandbox_id, sandbox_pool)
  rescue
    _exception -> {:error, :release_failed}
  end

  # Best-effort fail-closed row update for the rescue clause only -- swallows its
  # own failure too (design §7.6: "the DB itself may be unreachable, which is
  # presumably why an exception fired in the first place"). Does not attempt to
  # call event_appender -- an external call inside an already-degraded,
  # exception-recovery path would add another thing that could itself raise.
  defp safe_fail_closed_update(run, artifact, sandbox_id, prefix, exception) do
    %{assertions_total: total, assertions_failed: failed, failing_assertion_ids: failing_ids} =
      fail_closed_counts(artifact)

    attrs = %{
      status: :failed,
      sandbox_id: sandbox_id,
      assertions_total: total,
      assertions_passed: 0,
      assertions_failed: failed,
      failing_assertion_ids: failing_ids,
      teardown_error: "assertion rerun crashed: " <> Exception.message(exception),
      completed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    run
    |> PromotionAssertionRun.update_changeset(attrs)
    |> Repo.update(prefix: prefix)

    :ok
  rescue
    _exception -> :ok
  end

  defp build_result(%PromotionAssertionRun{} = run, idempotent_hit, teardown_event_appended) do
    %{
      run_id: run.id,
      status: run.status,
      assertions_total: run.assertions_total,
      assertions_passed: run.assertions_passed,
      assertions_failed: run.assertions_failed,
      failing_assertion_ids: run.failing_assertion_ids,
      sandbox_id: run.sandbox_id,
      teardown_error: run.teardown_error,
      idempotent_hit: idempotent_hit,
      teardown_event_appended: teardown_event_appended
    }
  end

  # Design §6 -- frozen_clock_ms is derived once per call (not per assertion, not
  # per replay-run), as the upper 32 bits of rng_seed treated as Unix epoch-seconds
  # multiplied to milliseconds (prm-batch1's FrozenClockProvider note, restated as
  # this design's §11 OQ-3 -- not resolved here).
  defp frozen_clock_ms(rng_seed) do
    (rng_seed >>> 32) * 1000
  end

  # Design §6.1 -- ports replayAssertions faithfully: for each assertion, in order,
  # run the evaluator twice under the same reset RNG seed, strip
  # non_deterministic_fields from both results, and byte-compare.
  defp replay_assertions(%PromotionArtifact{} = artifact, assertion_evaluator) do
    frozen_clock_ms = frozen_clock_ms(artifact.rng_seed)
    injection = %{frozen_clock_ms: frozen_clock_ms, rng_seed: artifact.rng_seed}

    {passed, failed, failing_ids_rev} =
      Enum.reduce(artifact.assertions, {0, 0, []}, fn assertion, {passed, failed, failing_ids} ->
        case replay_single_assertion(
               assertion,
               injection,
               artifact.rng_seed,
               artifact.non_deterministic_fields,
               assertion_evaluator
             ) do
          :passed -> {passed + 1, failed, failing_ids}
          :failed -> {passed, failed + 1, [assertion.id | failing_ids]}
        end
      end)

    %{
      assertions_total: length(artifact.assertions),
      assertions_passed: passed,
      assertions_failed: failed,
      failing_assertion_ids: Enum.reverse(failing_ids_rev)
    }
  end

  # Design §6.1 steps a-e: :rand.seed/2 immediately before each of the two replay
  # passes (matching Zig's own prng reset before each of its two runs) -- process-
  # scoped Erlang/OTP state, so concurrent calls never interfere with each other's
  # RNG state. Either evaluator call returning {:error, _} counts this assertion as
  # failed (fail-closed) -- an evaluator that cannot produce a result is not
  # silently treated as a pass.
  defp replay_single_assertion(
         assertion,
         injection,
         rng_seed,
         non_deterministic_fields,
         assertion_evaluator
       ) do
    seed_rng(rng_seed)
    result1 = assertion_evaluator.(assertion, injection)

    seed_rng(rng_seed)
    result2 = assertion_evaluator.(assertion, injection)

    with {:ok, result1_json} <- result1,
         {:ok, result2_json} <- result2 do
      compare_replay_results(assertion, result1_json, result2_json, non_deterministic_fields)
    else
      _ -> :failed
    end
  end

  # Splits the 64-bit rng_seed into :exsss's expected 3-integer tuple, matching
  # Zig's own std.Random.DefaultPrng.init(artifact.rng_seed) reset before each run
  # (design §6).
  defp seed_rng(rng_seed) do
    :rand.seed(:exsss, {band(rng_seed, 0xFFFFFFFF), rng_seed >>> 32, 0})
  end

  # Design §6.1 steps f-h: strip non_deterministic_fields from both results, then
  # byte-compare the re-encoded canonical JSON text (Jason.encode!/1 on Elixir maps
  # of identical content always iterates in the same order, so this comparison is
  # equivalent to Zig's own std.mem.eql(u8, ...) on the stripped, re-encoded text --
  # arguably more robust than a literal text diff, since it is insensitive to the
  # two results' original key ordering). A mismatch means this assertion is
  # non-deterministic (AC3's own idempotency check); on a match, assertion.payload's
  # own emptiness decides pass/fail.
  defp compare_replay_results(assertion, result1_json, result2_json, non_deterministic_fields) do
    stripped1 = strip_non_deterministic_fields(result1_json, non_deterministic_fields)
    stripped2 = strip_non_deterministic_fields(result2_json, non_deterministic_fields)

    cond do
      stripped1 != stripped2 -> :failed
      byte_size(assertion.payload) == 0 -> :failed
      true -> :passed
    end
  end

  # PROVENANCE (historical, not current decision authority):
  # Design §6.1 step f -- a direct port of stripDotPath's recursive
  # descend-then-remove-leaf-key algorithm (assertion_rerun.zig:589-601): parse as
  # JSON, for each dot-path descend into nested objects by "."-separated segments
  # and remove the final segment's key if present, re-encode to canonical JSON
  # text. A Jason.DecodeError here (result_json not valid JSON text) propagates as
  # a raised exception, caught by run_replay_span/8's own enclosing try/rescue --
  # this function does not swallow it, matching design §2's "exception anywhere in
  # this span" framing.
  defp strip_non_deterministic_fields(json_text, dot_paths) do
    decoded = Jason.decode!(json_text)

    stripped =
      Enum.reduce(dot_paths, decoded, fn dot_path, acc ->
        strip_dot_path(acc, String.split(dot_path, "."))
      end)

    Jason.encode!(stripped)
  end

  # A path that doesn't exist (missing key, or descends into a non-map value) is
  # silently skipped -- matches Zig's own stripDotPath exactly.
  defp strip_dot_path(value, [last_segment]) when is_map(value) do
    Map.delete(value, last_segment)
  end

  defp strip_dot_path(value, [segment | rest]) when is_map(value) do
    case Map.fetch(value, segment) do
      {:ok, nested} -> Map.put(value, segment, strip_dot_path(nested, rest))
      :error -> value
    end
  end

  defp strip_dot_path(value, _segments), do: value

  # PROVENANCE (historical, not current decision authority):
  # Design §6.1 -- default assertion_evaluator when opts[:assertion_evaluator] is
  # omitted or nil: a placeholder evaluator, not a richer "real" one this
  # codebase has no engine to justify yet (behavior matches
  # assertion_rerun.zig:500-501, 513-514). frozen_clock_ms/rng_seed are accepted
  # but unused, matching that placeholder's own behavior of computing and
  # discarding them.
  defp default_assertion_evaluator(%PromotionArtifact.Assertion{payload: payload}, _injection) do
    if byte_size(payload) > 0 do
      {:ok, payload}
    else
      {:ok, "{}"}
    end
  end
end
