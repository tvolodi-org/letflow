defmodule Letflow.Simulation.Req207VortexTest do
  @moduledoc """
  REQ-207 acceptance criteria: 4 Vortex scenario YAMLs run through
  `Letflow.Simulation.Runner`, each returning a closed disposition:
  EXECUTED/PASS-or-FAIL (production-order-above-threshold, supplier-quality-deviation
  critical/false-positive), BLOCKED_ON_DEPENDENCY (entity-list-filter-and-page).

  ## entity-list-filter-and-page disposition, re-derived 2026-09-11 (REQ-311)

  Still BLOCKED_ON_DEPENDENCY -- but the blocker has now moved OUT of `lib/`
  entirely, and its owner has changed from S10 to S8.

  The dependency has been re-derived twice on 2026-09-11, each time because a
  deliberately-armed tripwire fired on real code rather than on a status field:

    1. REQ-310 landed `Letflow.Routers.Entities` with nine routes and mounted
       it at `/entities`, falsifying the original "the entity subsystem has no
       HTTP surface" reason. The blocker narrowed to the missing record-read
       route.
    2. REQ-311 appended the tenth route, `POST /entities/query`, completing the
       record READ path. Every HTTP surface this scenario's six `:gui` steps
       need now exists and serves.

  What remains is not a missing subsystem at all: `Letflow.Simulation.Runner`
  matches a bare `:gui ->` clause and records `:deferred_to_s8` unconditionally,
  dispatching no GUI step whatsoever, so the six steps still cannot execute.
  That is S8's frontend-cutover work. **Nothing under `lib/` blocks this
  scenario any longer.** `Letflow.Entities.Records` remaining command-only is
  now evidence of correctness (reads belong exclusively to the query route,
  where `FieldGrants` redaction is enforced) rather than evidence of a gap.

  ## Allowlist triage round, 2026-09-11 (S10 fourth batch: REQ-312/313/314)

  REQ-312 (S10 gap 2, aggregation/reporting query, pending), REQ-313 (S10 gap
  3, entity-record attachments, done) and REQ-314 (S10 gap 12, bulk
  import/export, pending) tripped the entity-title tripwire and were admitted
  to `allowed_ids` unconditionally, not `pending_only_ids` -- all three are
  design-only, scoped identically to REQ-308's own precedent (design artefact
  under `lib/letflow/design/`, no route, no context module, no migration, no
  test), so attaching a future design to the landed HTTP surface is not the
  same as building on it. REQ-313's `status: done` was independently
  re-verified against its actual landed commits (not the requirement text)
  before admission -- see the comment on the allowlist entry for the full
  verification trail. Disposition unaffected; this scenario's blocker
  remains the S8 harness (Signal 5), unchanged by this round.

  ## REQ-315 lands, 2026-09-12 (eleventh route -- re-derived, not waved through)

  REQ-315 ("Implement the aggregation/reporting query route for entity
  records (S10 gap 2)") is the IMPLEMENTATION of REQ-312's design, and unlike
  REQ-312/313/314 it is not design-only: it lands real code -- a new
  `Letflow.Api.Authorization` permission atom `:EntitiesAggregate`, a new
  `Letflow.Entities.Query.Compiler.run_aggregate/2`, and an eleventh route,
  `POST /entities/query/aggregate`, mounted on `Letflow.Routers.Entities`
  (confirmed live via `__authz_routes__/0`, not trusted from the requirement
  text). That makes it look like the REQ-310/311 case (builds the HTTP
  surface) rather than the REQ-312/313/314 case (attaches nothing), so per
  the ⛔ block below it was NOT dropped straight into `allowed_ids` --  it was
  re-derived first, the same procedure REQ-310 and REQ-311 were put through.

  The re-derivation's finding: this scenario's six `:gui` steps are list,
  filter x2, sort, page and field-redaction reads over individual entity
  records, and all six read through `POST /entities/query` (REQ-311's
  route) -- none of them aggregates anything. `POST /entities/query/aggregate`
  is a DIFFERENT read shape (aggregate result rows, no `next_cursor`, gated
  by the DISTINCT `:EntitiesAggregate` permission, per the route's own
  design §2/§4) that this scenario's fixture never calls and has no reason
  to. So, unlike REQ-310 (closed the "no HTTP surface" gap) and REQ-311
  (closed the "no record-read route" gap), REQ-315 closes no gap this
  scenario was waiting on. Signal 3'' below was updated to assert the real,
  now-eleven-route set by equality (never membership, so a twelfth route or a
  dropped one lands back here too), and the disposition itself is
  UNCHANGED: still `BLOCKED_ON_DEPENDENCY`, still on S8's GUI-step harness
  (Signal 5), still nothing under `lib/` left for this scenario to wait on.
  REQ-315 was then admitted to `allowed_ids` on the strength of that
  completed re-derivation -- the same basis REQ-310/311 were, not the
  "never builds anything" basis REQ-308/312/313/314 were.

  ## REQ-317/318/319/320 triaged the same day, discovered while fixing REQ-315

  Filing REQ-315 landing also exposed that REQ-317 (attachment routes),
  REQ-318 (export/import permission atoms), REQ-319 (export route) and
  REQ-320 (import route) -- filed on `main` alongside REQ-315 in the same
  S10 gap 3/12 batch -- also trip this tripwire and had not yet been
  triaged. All four are `status: pending` (nothing landed) and none of
  their planned routes serves this scenario's six `:gui` steps (individual-
  record list/filter/sort/page/redaction, exclusively through REQ-311's
  `POST /entities/query`), so all four were admitted to `allowed_ids`
  unconditionally -- see the allowlist entries themselves for why this is
  safe even for the two (REQ-317, REQ-319/320) that plan to extend
  `Letflow.Routers.Entities`: Signal 3'' below already asserts that
  router's route set by equality, so their eventual landing is caught
  structurally regardless of this allowlist's state.

  ## REQ-317 lands, 2026-09-12 (fifteenth route -- re-derived, not waved through)

  REQ-317 ("Add the entity-attachment permission atoms and the four record-
  attachment routes to Letflow.Routers.Entities (S10 gap 3, part 2)") lands
  real code on `Letflow.Routers.Entities`: two new
  `Letflow.Api.Authorization` permission atoms
  (`:EntitiesAttachmentsManage`/`:EntitiesAttachmentsRead`) and four new
  routes -- `POST`/`GET /records/:entity_type/:record_id/attachments` and
  `GET`/`DELETE /records/:entity_type/:record_id/attachments/:attachment_id`
  -- confirmed live via `__authz_routes__/0`, not trusted from the
  requirement text. Re-derived the same way REQ-315 was: this scenario's six
  `:gui` steps are list/filter x2/sort/page/field-redaction reads over
  individual entity records' `field_values`, all exclusively through
  `POST /entities/query` (REQ-311's route) -- none of them uploads, lists,
  downloads, or deletes a binary file attached to a record. The four new
  routes are a DIFFERENT capability (record-attachment lifecycle, gated by
  the DISTINCT `:EntitiesAttachmentsManage`/`:EntitiesAttachmentsRead`
  permissions, per design req313-entity-record-attachments.md §3/§4) that
  this scenario's fixture never calls and has no reason to. So, like REQ-315
  (and unlike REQ-310/311), REQ-317 closes no gap this scenario was waiting
  on. Signal 3'' below was updated to assert the real, now-fifteen-route set
  by equality, and the disposition itself is UNCHANGED: still
  `BLOCKED_ON_DEPENDENCY`, still on S8's GUI-step harness (Signal 5), still
  nothing under `lib/` left for this scenario to wait on.

  ## REQ-394 lands, 2026-09-23 (re-derived, not waved through)

  REQ-394 ("Per-entity-type record authorization, with denial indistinguishable
  from a genuinely empty entity type") flipped `status: done` and the
  `pending_only_ids` tripwire fired exactly as armed. Re-derivation, not a
  guess: read the requirement text, its design doc
  (`lib/letflow/design/req394-per-entity-type-authorization.md`), and diffed
  its landed commit (`bd77a129`) against `main` for
  `lib/letflow/routers/entities.ex`.

  Finding: REQ-394 layers a new `Letflow.Entities.TypeAccess.authorized?/3`
  check ONTO the two EXISTING routes this scenario's six `:gui` steps already
  depend on (`POST /entities/query`, `GET /entities/definitions/active/:name`)
  -- it adds no route, removes no route, renames no route, and mints no new
  permission atom consumed by `Letflow.Routers.Entities`. Confirmed live, not
  assumed: `git diff main..bd77a129 -- lib/letflow/routers/entities.ex` touches
  only handler bodies (threading `conn.assigns.auth_context.user_id` through
  and a `TypeAccess.authorized?/3` call before `Compiler.compile/2`'s result is
  used) -- no `authz_post`/`authz_get` declaration is added, removed, or
  retargeted, so Signal 3'' below (asserting `__authz_routes__/0`'s route set
  by EQUALITY) never moved and required no edit. `runner.ex` is untouched by
  REQ-394's commit (its own diff stat lists only
  `lib/letflow/routers/entities.ex` and `test/letflow/routers/entities_test.exs`)
  and remains absent from this branch's diff, so Signal 5's harness blocker is
  likewise untouched.

  So, exactly like REQ-315/317/319/320 before it, REQ-394 closes no gap this
  scenario was waiting on: its own denial-vs-empty-type behavior only changes
  what an UNAUTHORIZED caller sees, and this scenario's fixture (per PW-10 /
  the sister UAT scenario at
  `test/fixtures/uat/scenarios/vortex/entity-list-filter-and-page.yaml`) never
  exercises a denied type. The disposition itself is UNCHANGED: still
  `BLOCKED_ON_DEPENDENCY`, still on S8's GUI-step harness (Signal 5), still
  nothing under `lib/` left for this scenario to wait on. REQ-394 was admitted
  to `allowed_ids` on the strength of this completed re-derivation, the same
  basis REQ-315/317/319/320 were -- not silenced by deletion or by a blind move
  into `allowed_ids` without re-checking Signals 3''/5 first.

  ## ISS-0935 lands, 2026-10-01 (eighteenth route -- re-derived, not waved through)

  ISS-0935 ("Seed Vortex production_batch/shipment_manifest entity types")
  lands real code on `Letflow.Routers.Entities`: a new
  `Letflow.Entities.Restrictions.import_restrictions/2` context function and
  an eighteenth route, `POST /entities/restrictions/import`, gated by a new,
  distinct `Letflow.Api.Authorization` permission atom
  `:EntitiesRestrictionsManage` (not `:EntitiesRecordsWrite` or
  `:EntitiesRecordsImport`) -- confirmed live via `__authz_routes__/0`, not
  trusted from the requirement text or PR description. Re-derived the same
  way REQ-315/317/319/320/394 were: this scenario's six `:gui` steps are
  list/filter x2/sort/page/field-redaction reads over individual entity
  records' `field_values`, all exclusively through `POST /entities/query`
  (REQ-311's route) -- none of them imports a restriction, manages a
  restriction, or touches `Letflow.Entities.Restrictions` in any way. The new
  route is a one-time, seed-time admin operation (bulk-loading field-level
  restriction rules ahead of a tenant's entity-record traffic), not a route
  the scenario's own `:gui` steps, or the fixture behind them, ever call --
  confirmed by reading `test/fixtures/uat/scenarios/vortex/entity-list-filter-and-page.yaml`
  and the simulation fixture driving this describe block, neither of which
  references `/restrictions/import` or `Letflow.Entities.Restrictions`
  anywhere. So, exactly like REQ-315/317/319/320/394 before it, ISS-0935
  closes no gap this scenario was waiting on. Signal 3'' below was updated to
  assert the real, now-eighteen-route set by equality (never membership, so
  a nineteenth route or a dropped one lands back here too), and the
  disposition itself is UNCHANGED: still `BLOCKED_ON_DEPENDENCY`, still on
  S8's GUI-step harness (Signal 5), still nothing under `lib/` left for this
  scenario to wait on.

  ## REQ-516 S2 lands (nineteenth route, GH #2701)

  REQ-516 S2 adds a nineteenth route on `Letflow.Routers.Entities`,
  `GET /entities/records/:entity_type/:record_id/history`, gated by
  `:EntitiesQuery`. It returns a record's create/update history with
  `field_values` masked at read time. Re-derived the same way as ISS-0935: this
  scenario's six `:gui` steps (list, filter x2, sort, page, field redaction) all
  read through `POST /entities/query`, and none reads a record's history. So the
  route closes none of the six `:gui` gaps, and the disposition is UNCHANGED:
  still `BLOCKED_ON_DEPENDENCY`. The equality assertion now expects nineteen routes.

  Full reasoning and the complete re-derivation history live in that describe
  block's own comments; `test/specs/REQ-310.md` states the test cases.

  ## SERVICE_TASK limitation (affects all 3 real scenarios, design §0.3/§2)
  `Letflow.Engine` does not yet dispatch SERVICE_TASK nodes. The real
  `process_quality_check.yaml`/`process_work_order.yaml` fixtures have SERVICE_TASKs on
  their critical paths. Test-local simplified process graphs
  (`@simple_production_order_graph`, `@simple_supplier_deviation_graph`) replace them
  with direct edges/END nodes (production-order) or a HUMAN_TASK substitute
  (quarantine-batch, so EO-001's audit-event-ordering claim has real evidence) --
  mirrors REQ-206's `@simple_approval_graph` precedent exactly.

  ## OQ-2 (design §7) -- RESOLVED: no by-parent-instance-id lookup function exists on
  `Letflow.Instances`/`Letflow.Engine` (confirmed by reading both modules this session).
  `Letflow.EventStore.InstanceProjection.parent_instance_id` IS a real, populated column
  (`Letflow.Engine.SubProcess.insert_child_instance_projection/8` sets it on every
  sub-process child row) -- resolved here via a direct, test-local `Repo` query against
  that column (`find_child_by_parent_instance_id/2`, below), the narrowest read
  consistent with "no by-parent context function exists yet."

  ## OQ-3 (design §7) -- RESOLVED, differently than either candidate the design named:
  `InstanceProjection.current_nodes` is NOT usable for terminal-node identity --
  `Letflow.Engine.Transition`'s `dispatch_end/3` (transition.ex:373-379)
  unconditionally drops a token the instant it reaches an END node, so
  `current_nodes` is always `[]` once `status == :completed`, for every terminal END
  node alike (confirmed empirically this session: both scenarios below hit this).
  The real, queryable distinguishing signal is each scenario's own last real
  `TASK_COMPLETED`/`SUB_PROCESS_COMPLETED` event payload's `"activated_nodes"` field
  (via `Letflow.Instances.history/3`) -- see each describe block below for the exact
  per-scenario reasoning.

  Real Postgres, `async: false` -- tenant provisioning needs `Sandbox.mode(:auto)`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Identity
  alias Letflow.Identity.OnboardingRecord
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.Simulation.Runner
  alias Letflow.Simulation.ScenarioFixture
  alias Letflow.Simulation.Seed
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @fixtures_dir Path.expand("../../fixtures/simulation/vortex", __DIR__)
  @scenarios_dir Path.join(@fixtures_dir, "scenarios")

  # ── §2.1: @simple_production_order_graph ──────────────────────────────────
  # Derived from process_quality_check.yaml (design §0.3), SERVICE_TASK nodes elided:
  # assign-line/auto-reject-order replaced by direct edges to end-released/end-rejected;
  # notify-planner elided entirely. capacity-review/escalate-to-ceo/budget-gate/
  # budget-approval kept verbatim, same conditions.
  @simple_production_order_graph %{
    "nodes" => [
      %{"id" => "start", "node_type" => "START"},
      %{
        "id" => "capacity-review",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-production-manager"}
      },
      %{
        "id" => "escalate-to-ceo",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-ceo"}
      },
      %{"id" => "budget-gate", "node_type" => "EXCLUSIVE_GATEWAY"},
      %{
        "id" => "budget-approval",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-controller"}
      },
      %{"id" => "end-released", "node_type" => "END"},
      %{"id" => "end-rejected", "node_type" => "END"}
    ],
    "edges" => [
      %{"id" => "e0", "source" => "start", "target" => "capacity-review"},
      %{
        "id" => "e1",
        "source" => "capacity-review",
        "target" => "budget-gate",
        "condition" => "variables.capacity_decision == 'approve'"
      },
      %{
        "id" => "e2",
        "source" => "capacity-review",
        "target" => "end-rejected",
        "condition" => "variables.capacity_decision == 'reject'"
      },
      # on_timeout fallback for capacity-review
      %{
        "id" => "fallback-capacity-review",
        "source" => "capacity-review",
        "target" => "escalate-to-ceo"
      },
      %{
        "id" => "e3",
        "source" => "escalate-to-ceo",
        "target" => "budget-gate",
        "condition" => "variables.capacity_decision == 'approve'"
      },
      %{
        "id" => "e4",
        "source" => "escalate-to-ceo",
        "target" => "end-rejected",
        "condition" => "variables.capacity_decision == 'reject'"
      },
      # on_timeout fallback for escalate-to-ceo
      %{
        "id" => "timeout-escalate-to-ceo",
        "source" => "escalate-to-ceo",
        "target" => "end-rejected"
      },
      %{
        "id" => "budget-gate-default",
        "source" => "budget-gate",
        "target" => "budget-approval",
        "is_default" => true
      },
      %{
        "id" => "e5",
        "source" => "budget-gate",
        "target" => "budget-approval",
        "condition" => "variables.order_value_eur > 10000"
      },
      %{
        "id" => "e6",
        "source" => "budget-gate",
        "target" => "end-released",
        "condition" => "variables.order_value_eur <= 10000"
      },
      %{
        "id" => "e7",
        "source" => "budget-approval",
        "target" => "end-released",
        "condition" => "variables.budget_decision == 'approve'"
      },
      %{
        "id" => "e8",
        "source" => "budget-approval",
        "target" => "end-rejected",
        "condition" => "variables.budget_decision == 'reject'"
      },
      # on_timeout fallback for budget-approval
      %{
        "id" => "timeout-budget-approval",
        "source" => "budget-approval",
        "target" => "end-rejected"
      }
    ]
  }

  # ── §2.2: @simple_supplier_deviation_graph ────────────────────────────────
  # Derived from process_work_order.yaml (design §0.3). quarantine-batch (SERVICE_TASK)
  # substituted to a HUMAN_TASK (design §2.2/§2.3 rationale: EO-001's audit-event
  # ordering claim needs real, timestamped task.create/task.complete evidence).
  # severity-classification/false-positive-check/severity-routing/
  # corrective-action-subprocess kept real. release-quarantine/supplier-warning/
  # supplier-notification/close-deviation/default-to-critical elided, folded into
  # neighboring edges.
  @simple_supplier_deviation_graph %{
    "nodes" => [
      %{"id" => "start", "node_type" => "START"},
      %{
        "id" => "quarantine-batch",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-quality-manager"}
      },
      %{
        "id" => "severity-classification",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-quality-manager"}
      },
      %{"id" => "false-positive-check", "node_type" => "EXCLUSIVE_GATEWAY"},
      %{"id" => "severity-routing", "node_type" => "EXCLUSIVE_GATEWAY"},
      %{
        "id" => "corrective-action-subprocess",
        "node_type" => "SUB_PROCESS",
        "attributes" => %{"definition_name" => "CHILD_DEFINITION_NAME"}
      },
      %{"id" => "end-closed", "node_type" => "END"},
      %{"id" => "end-false-positive", "node_type" => "END"}
    ],
    "edges" => [
      %{"id" => "e0", "source" => "start", "target" => "quarantine-batch"},
      %{"id" => "e1", "source" => "quarantine-batch", "target" => "severity-classification"},
      %{"id" => "e2", "source" => "severity-classification", "target" => "false-positive-check"},
      %{
        "id" => "false-positive-check-default",
        "source" => "false-positive-check",
        "target" => "severity-routing",
        "is_default" => true
      },
      %{
        "id" => "e3",
        "source" => "false-positive-check",
        "target" => "end-false-positive",
        "condition" => "variables.false_positive == true"
      },
      %{
        "id" => "e4",
        "source" => "false-positive-check",
        "target" => "severity-routing",
        "condition" => "variables.false_positive == false"
      },
      %{
        "id" => "severity-routing-default",
        "source" => "severity-routing",
        "target" => "corrective-action-subprocess",
        "is_default" => true
      },
      %{
        "id" => "e5",
        "source" => "severity-routing",
        "target" => "corrective-action-subprocess",
        "condition" => "variables.severity == 'critical'"
      },
      %{"id" => "e6", "source" => "corrective-action-subprocess", "target" => "end-closed"}
    ]
  }

  # Child definition graph for corrective-action-subprocess -- START -> HUMAN_TASK ->
  # END, NOT a synchronously-completing START->END graph. A synchronously-completing
  # child cascades its own completion multi (Letflow.Engine.SubProcess.
  # append_completion_multi/5, via maybe_chain_synchronous_completion/6) back into the
  # SAME transaction as the parent hop-chain that spawned it -- both append a
  # {:task_records, parent_instance_id} Multi step for the same parent instance_id,
  # which raises `cannot merge Multi` (Ecto.Multi.merge_results/3), a real pre-existing
  # Engine defect (lib/letflow/engine.ex's append_sub_process_children_creation_multi/5
  # chaining into Letflow.Engine.SubProcess.append_start_multi/7's own synchronous-
  # completion branch), out of this requirement's scope to fix (REQ-062 already
  # shipped/reviewed; flagged for REVIEWER/a follow-up issue, not silently worked
  # around by re-designing Engine here). A pending HUMAN_TASK child, completed by its
  # own separate Engine.complete_task/3 call (the scenario's own extra step, below),
  # avoids the collision entirely -- this is the SAME class of test-local workaround
  # REQ-206 already used for the SERVICE_TASK gap (design §2), applied to a different
  # real Engine limitation this scenario happened to be the first to exercise.
  @simple_child_graph %{
    "nodes" => [
      %{"id" => "start", "node_type" => "START"},
      %{
        "id" => "corrective-work",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-quality-manager"}
      },
      %{"id" => "end", "node_type" => "END"}
    ],
    "edges" => [
      %{"id" => "e0", "source" => "start", "target" => "corrective-work"},
      %{"id" => "e1", "source" => "corrective-work", "target" => "end"}
    ]
  }

  setup do
    Sandbox.mode(Letflow.Repo, :auto)

    unique = Letflow.TenantSlugFixture.unique_slug("req207")

    company = %{
      "slug" => unique,
      "display_name" => "Vortex Manufacturing GmbH",
      "hostname" => unique <> ".simulation.test"
    }

    {:ok, %{tenant: tenant}} = Seed.seed_company(company)
    {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(tenant.id)

    {:ok, org_structure} =
      YamlElixir.read_from_file(Path.join(@fixtures_dir, "org_structure.yaml"))

    org_structure =
      update_in(org_structure["people"], fn people ->
        Enum.map(people, fn person ->
          Map.update!(person, "username", &(&1 <> "-" <> unique))
        end)
      end)

    {:ok, users} = Seed.seed_users(org_structure, tenant)

    users_by_actor_id =
      org_structure["people"]
      |> Enum.zip(users)
      |> Map.new(fn {person, user} -> {Map.fetch!(person, "actor_id"), user} end)

    anna = Map.fetch!(users_by_actor_id, "actor-vortex-anna")
    sabine = Map.fetch!(users_by_actor_id, "actor-vortex-sabine")
    stefan = Map.fetch!(users_by_actor_id, "actor-vortex-stefan")
    karl = Map.fetch!(users_by_actor_id, "actor-vortex-karl")
    nina = Map.fetch!(users_by_actor_id, "actor-vortex-nina")

    # ISS-0942: org_structure.yaml's departments were seeded as plain groups
    # but never bound to the "role-*" process_routing_role names the
    # @simple_production_order_graph/@simple_supplier_deviation_graph
    # HUMAN_TASK nodes assign to -- harmless before this fix (POST
    # /tasks/:id/complete enforced no assignee check at all), but now that
    # it does, the scenario's own actors (sabine production, stefan
    # controller, karl/nina quality) must actually hold the role their step
    # completes, same as a real tenant would be configured.
    {:ok, groups} = Seed.seed_groups(org_structure, tenant)
    group_by_name = Map.new(groups, &{&1.name, &1})

    {:ok, _} =
      RoleRegistry.upsert_role(
        "role-production-manager",
        :process_routing_role,
        Map.fetch!(group_by_name, "dept-production").id,
        prefix: schema_name
      )

    {:ok, _} =
      RoleRegistry.upsert_role(
        "role-controller",
        :process_routing_role,
        Map.fetch!(group_by_name, "dept-finance").id,
        prefix: schema_name
      )

    {:ok, _} =
      RoleRegistry.upsert_role(
        "role-quality-manager",
        :process_routing_role,
        Map.fetch!(group_by_name, "dept-quality").id,
        prefix: schema_name
      )

    # Seed the trivial sub-process child definition first, so the parent simplified
    # graph can reference its real name.
    child_definition_name = "SimpleCorrectiveAction-" <> unique

    {:ok, definition_child} =
      case Letflow.Definitions.get_active_by_name(child_definition_name, prefix: schema_name) do
        {:ok, d} ->
          {:ok, d}

        {:error, :not_found} ->
          with {:ok, d} <-
                 Letflow.Definitions.create(
                   %{
                     name: child_definition_name,
                     version: "1.0",
                     description: "REQ-207 test-local trivial sub-process child (start->end).",
                     graph: @simple_child_graph,
                     created_by: anna.id
                   },
                   prefix: schema_name
                 ),
               {:ok, %{definition: activated}} <-
                 Letflow.Definitions.activate(d.id, prefix: schema_name) do
            {:ok, activated}
          end
      end

    # Seed simplified production-order process (no SERVICE_TASKs; for
    # production-order-above-threshold).
    simple_production_order_name = "SimpleProductionOrderRelease-" <> unique

    {:ok, definition_production_order} =
      case Letflow.Definitions.get_active_by_name(simple_production_order_name,
             prefix: schema_name
           ) do
        {:ok, d} ->
          {:ok, d}

        {:error, :not_found} ->
          with {:ok, d} <-
                 Letflow.Definitions.create(
                   %{
                     name: simple_production_order_name,
                     version: "1.0",
                     description:
                       "REQ-207 test-local process: exercises budget-gate CEL EXCLUSIVE_GATEWAY branch without SERVICE_TASKs.",
                     graph: @simple_production_order_graph,
                     created_by: anna.id
                   },
                   prefix: schema_name
                 ),
               {:ok, %{definition: activated}} <-
                 Letflow.Definitions.activate(d.id, prefix: schema_name) do
            {:ok, activated}
          end
      end

    # Seed simplified supplier-deviation process (no SERVICE_TASKs except the
    # quarantine-batch HUMAN_TASK substitute; for both critical and false-positive
    # scenarios -- same seeded definition, per the requirement text).
    simple_deviation_name = "SimpleSupplierQualityDeviation-" <> unique

    graph_with_child =
      put_in(
        @simple_supplier_deviation_graph,
        ["nodes"],
        Enum.map(@simple_supplier_deviation_graph["nodes"], fn
          %{"id" => "corrective-action-subprocess"} = node ->
            put_in(node, ["attributes", "definition_name"], definition_child.name)

          node ->
            node
        end)
      )

    {:ok, definition_deviation} =
      case Letflow.Definitions.get_active_by_name(simple_deviation_name, prefix: schema_name) do
        {:ok, d} ->
          {:ok, d}

        {:error, :not_found} ->
          with {:ok, d} <-
                 Letflow.Definitions.create(
                   %{
                     name: simple_deviation_name,
                     version: "1.0",
                     description:
                       "REQ-207 test-local process: exercises severity-routing CEL EXCLUSIVE_GATEWAY branch and real SUB_PROCESS spawn without other SERVICE_TASKs.",
                     graph: graph_with_child,
                     created_by: karl.id
                   },
                   prefix: schema_name
                 ),
               {:ok, %{definition: activated}} <-
                 Letflow.Definitions.activate(d.id, prefix: schema_name) do
            {:ok, activated}
          end
      end

    {:ok, %{plaintext: anna_token}} =
      Identity.create_token(anna.id, %{roles: ["PROCESS_OPERATOR"]}, prefix: schema_name)

    {:ok, %{plaintext: sabine_token}} =
      Identity.create_token(sabine.id, %{roles: ["PROCESS_OPERATOR"]}, prefix: schema_name)

    {:ok, %{plaintext: stefan_token}} =
      Identity.create_token(stefan.id, %{roles: ["PROCESS_OPERATOR"]}, prefix: schema_name)

    {:ok, %{plaintext: karl_token}} =
      Identity.create_token(karl.id, %{roles: ["PROCESS_OPERATOR"]}, prefix: schema_name)

    {:ok, %{plaintext: nina_token}} =
      Identity.create_token(nina.id, %{roles: ["PROCESS_OPERATOR"]}, prefix: schema_name)

    actors = %{
      "actor-vortex-anna" => %{"token" => anna_token, "tenant_slug" => unique},
      "actor-vortex-sabine" => %{"token" => sabine_token, "tenant_slug" => unique},
      "actor-vortex-stefan" => %{"token" => stefan_token, "tenant_slug" => unique},
      "actor-vortex-karl" => %{"token" => karl_token, "tenant_slug" => unique},
      "actor-vortex-nina" => %{"token" => nina_token, "tenant_slug" => unique}
    }

    on_exit(fn -> teardown(unique) end)

    %{
      tenant: tenant,
      schema_name: schema_name,
      unique: unique,
      actors: actors,
      definitions: %{
        production_order: definition_production_order,
        deviation: definition_deviation,
        child: definition_child
      }
    }
  end

  defp teardown(slug) do
    case Identity.get_tenant_by_slug(slug) do
      {:ok, tenant} ->
        case TenantProvisioning.schema_name_for_tenant(tenant.id) do
          {:ok, schema_name} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
          {:error, _reason} -> :ok
        end

        Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))
        Repo.delete_all(from(o in OnboardingRecord, where: o.tenant_id == ^tenant.id))
        Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))

      {:error, :not_found} ->
        :ok
    end
  end

  # Replaces "TENANT_PREFIX" in precondition/outcome args (top-level and, for
  # :audit_event_ordering's nested "first"/"second" shape, one level deep),
  # "DEFINITION_NAME" in process_id/step params, with real test-time values.
  defp patch_scenario(scenario, schema_name: schema_name, definition_name: defn, actors: actors) do
    %{
      scenario
      | process_id: defn,
        actors: actors,
        preconditions: patch_preconditions(scenario.preconditions, schema_name, defn),
        steps: patch_step_params(scenario.steps, defn),
        expected_outcomes: patch_outcome_prefix(scenario.expected_outcomes, schema_name)
    }
  end

  defp patch_preconditions(preconditions, schema_name, defn) do
    Enum.map(preconditions, fn p ->
      args = Map.get(p, :args, %{})

      args =
        args
        |> Map.put("prefix", schema_name)
        |> then(fn a ->
          if Map.get(a, "name") == "DEFINITION_NAME", do: Map.put(a, "name", defn), else: a
        end)

      Map.put(p, :args, args)
    end)
  end

  defp patch_step_params(steps, defn) do
    Enum.map(steps, fn step ->
      case Map.get(step, :params) do
        %{"definition_name" => "DEFINITION_NAME"} = params ->
          Map.put(step, :params, Map.put(params, "definition_name", defn))

        _ ->
          step
      end
    end)
  end

  defp patch_outcome_prefix(outcomes, schema_name) do
    Enum.map(outcomes, fn outcome ->
      args = outcome.verification.args

      patched_args =
        case Map.take(args, ["first", "second"]) do
          %{} = sides when map_size(sides) > 0 ->
            Enum.reduce(["first", "second"], args, fn key, acc ->
              case Map.get(acc, key) do
                nil -> acc
                side -> Map.put(acc, key, Map.put(side, "prefix", schema_name))
              end
            end)

          _ ->
            Map.put(args, "prefix", schema_name)
        end

      put_in(outcome, [:verification, :args], patched_args)
    end)
  end

  # OQ-2: no by-parent-instance-id context function exists on Instances/Engine (see
  # moduledoc). Direct, test-local Repo query against InstanceProjection.parent_instance_id
  # -- the narrowest read consistent with that finding.
  defp find_child_by_parent_instance_id(parent_instance_id, schema_name) do
    InstanceProjection
    |> Ecto.Query.where([p], p.parent_instance_id == ^parent_instance_id)
    |> Repo.one(prefix: schema_name)
  end

  # Bounded walk-back for Signal 2 (entity/entity-query title: -> id: adjacency check).
  # REQ-257 inserted a `# PROVENANCE (...)` comment line between id: and title: for
  # several requirements.yaml entries, breaking the old exact idx - 1 adjacency
  # assumption. This walks upward from `idx`, skipping only blank or comment lines
  # (trimmed of trailing \r and whitespace, matching /^#/), and stops at the first
  # real content line. It deliberately does NOT keep searching past a real content
  # line for an id: further up -- a genuinely wrong or missing id: line must still
  # be returned here so the caller's assertion fails on it, exactly as before.
  defp nearest_preceding_id_line(title_lines, idx) when idx >= 0 do
    line = Enum.at(title_lines, idx)
    trimmed = line |> to_string() |> String.trim_trailing("\r") |> String.trim()

    if trimmed == "" or Regex.match?(~r/^#/, trimmed) do
      nearest_preceding_id_line(title_lines, idx - 1)
    else
      line
    end
  end

  defp nearest_preceding_id_line(_title_lines, idx) when idx < 0, do: nil

  # Returns the `status:` value of the requirement whose entry starts at the
  # `- id: <req_id>` line, as a string ("pending", "done", ...), or nil if the
  # id or its status key is not found. Scans forward from the id line only to
  # the NEXT `- id:` line, so a malformed/missing status never silently picks
  # up the following requirement's status.
  defp requirement_status(lines, req_id) do
    lines
    |> Enum.drop_while(fn line ->
      not Regex.match?(
        ~r/^\s*-\s+id:\s*#{Regex.escape(req_id)}\s*$/,
        String.trim_trailing(line, "\r")
      )
    end)
    |> Enum.drop(1)
    |> Enum.take_while(fn line -> not Regex.match?(~r/^\s*-\s+id:\s*REQ-/, line) end)
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^\s*status:\s*(\S+)\s*$/, String.trim_trailing(line, "\r")) do
        [_, status] -> status
        nil -> nil
      end
    end)
  end

  # ─── AC1: vortex-production-order-above-threshold ───────────────────────

  describe "vortex-production-order-above-threshold" do
    test "planner submits -> capacity-review -> budget-approval; 4 expected_outcomes with evidence",
         %{
           schema_name: schema_name,
           actors: actors,
           definitions: %{production_order: definition}
         } do
      scenario_raw =
        ScenarioFixture.load!(Path.join(@scenarios_dir, "production-order-above-threshold.yaml"))

      scenario =
        patch_scenario(scenario_raw,
          schema_name: schema_name,
          definition_name: definition.name,
          actors: actors
        )

      assert {:ok, report} = Runner.run(scenario)

      assert length(report.step_results) == 5
      [step1, step2a, step2b, step3a, step3b] = report.step_results

      assert step1.outcome == :ok,
             "step 1 (POST /instances) failed — detail: #{inspect(step1.detail)}"

      assert %{"instance_id" => _, "status" => "ACTIVE"} = step1.captured

      assert step2a.outcome == :ok,
             "step 2a (GET /tasks capacity-lookup) failed — detail: #{inspect(step2a.detail)}"

      assert step2b.outcome == :ok,
             "step 2b (POST /tasks capacity-complete) failed — detail: #{inspect(step2b.detail)}"

      assert step3a.outcome == :ok,
             "step 3a (GET /tasks budget-lookup) failed — detail: #{inspect(step3a.detail)}"

      assert step3b.outcome == :ok,
             "step 3b (POST /tasks budget-complete) failed — detail: #{inspect(step3b.detail)}"

      assert length(report.outcome_results) == 4
      [eo1, eo2, eo3, eo4] = report.outcome_results

      # EO-1: task_assigned — budget-approval task existence proves edge e5
      # (order_value_eur > 10000) was taken, not e6.
      assert eo1.outcome in [:pass, :fail],
             "EO-1 task_assigned result must be :pass or :fail"

      assert %{assignee_ref: "role-controller"} = eo1.observed,
             "Expected budget-approval task assignee_ref to be 'role-controller'; observed: #{inspect(eo1.observed)}"

      assert eo2.outcome == :pass,
             "EO-2 instance_state (COMPLETED) failed — observed: #{inspect(eo2.observed)}"

      assert eo3.outcome == :pass,
             "EO-3 instance_state (variables) failed — observed: #{inspect(eo3.observed)}"

      assert eo4.outcome == :pass,
             "EO-4 audit_event (task.complete) failed — observed: #{inspect(eo4.observed)}"
    end
  end

  # ─── AC2: vortex-supplier-quality-deviation-critical ─────────────────────

  describe "vortex-supplier-quality-deviation-critical" do
    test "quarantine -> severity CRITICAL -> sub-process spawn; EO-001 ordering + sub-process outcome",
         %{
           schema_name: schema_name,
           actors: actors,
           definitions: %{deviation: definition}
         } do
      scenario_raw =
        ScenarioFixture.load!(
          Path.join(@scenarios_dir, "supplier-quality-deviation-critical.yaml")
        )

      scenario =
        patch_scenario(scenario_raw,
          schema_name: schema_name,
          definition_name: definition.name,
          actors: actors
        )

      assert {:ok, report} = Runner.run(scenario)

      assert length(report.step_results) == 5
      [step1, step2a, step2b, step3a, step3b] = report.step_results

      assert step1.outcome == :ok,
             "step 1 (POST /instances) failed — detail: #{inspect(step1.detail)}"

      instance_id = step1.captured["instance_id"]

      assert step2a.outcome == :ok,
             "step 2a (GET /tasks quarantine-lookup) failed — detail: #{inspect(step2a.detail)}"

      assert step2b.outcome == :ok,
             "step 2b (POST /tasks quarantine-complete) failed — detail: #{inspect(step2b.detail)}"

      assert step3a.outcome == :ok,
             "step 3a (GET /tasks severity-lookup) failed — detail: #{inspect(step3a.detail)}"

      assert step3b.outcome == :ok,
             "step 3b (POST /tasks severity-complete: critical) failed — detail: #{inspect(step3b.detail)}"

      # 5 expected_outcomes declared in the YAML: task_assigned, instance_state x2,
      # sub-process-spawn placeholder (verified for real below, not through the YAML's
      # own verification block), and audit_event_ordering. instance_state's own
      # `status: "COMPLETED"` checks (eo_completed/eo_variables) necessarily :fail at
      # this point in the run -- the parent instance is still :active, parked on
      # corrective-action-subprocess, waiting on the child's own pending HUMAN_TASK
      # (see @simple_child_graph's moduledoc comment for why the child is NOT
      # synchronously-completing). Re-verified for real, post-child-completion, below.
      assert length(report.outcome_results) == 5

      [eo_task_assigned, _eo_completed, _eo_variables, _eo_subprocess_placeholder, eo_ordering] =
        report.outcome_results

      assert eo_task_assigned.outcome in [:pass, :fail]

      assert %{assignee_ref: "role-quality-manager"} = eo_task_assigned.observed,
             "Expected severity-classification task assignee_ref to be 'role-quality-manager'; observed: #{inspect(eo_task_assigned.observed)}"

      # EO-001 ordering: quarantine-batch's task.create precedes severity-classification's
      # task.create -- verified via real audit hash-chain linkage via `prev_chain_hash`
      # (ISS-0972), not timestamp comparison: audit_entries has no sequence_number/
      # global_seq-equivalent column, so ordering is proven by walking the chain rather
      # than comparing `timestamp`. Both task.create events already exist by this point
      # (steps 2a/3a), independent of the child's own completion below.
      assert eo_ordering.outcome == :pass,
             "audit_event_ordering (quarantine task.create precedes severity task.create) failed — observed: #{inspect(eo_ordering.observed)}"

      assert %{
               first: %Letflow.Audit.Entry{} = first_entry,
               second: %Letflow.Audit.Entry{} = second_entry
             } =
               eo_ordering.observed

      assert first_entry.id != second_entry.id

      # Independent re-derivation of the ordering claim (don't just trust the flag) --
      # a second, independent call against real DB state, re-proving the claim via the
      # same chain-walk primitive the runner itself now uses.
      assert {:ok, true} =
               Letflow.Audit.chain_precedes?(schema_name, first_entry, second_entry)

      # Sub-process spawn verification (OQ-2): a real child instance exists, parented to
      # this instance, real (non-nil) status, :active -- waiting on its own pending
      # corrective-work HUMAN_TASK (@simple_child_graph).
      child = find_child_by_parent_instance_id(instance_id, schema_name)

      assert child != nil,
             "Expected a real child InstanceProjection row parented to #{instance_id}"

      assert child.status != nil
      assert child.status == :active

      # Drive the child's own completion independently (own transaction, matching
      # test/letflow/engine_sub_process_test.exs's own established pattern for a
      # non-synchronously-completing child) -- this is what actually reaches
      # end-closed and cascades the parent's own completion.
      {:ok, %{items: [{child_task, _definition_ver}]}} =
        Letflow.Tasks.list_tasks(
          %{instance_id: child.instance_id, status: :pending, page_size: 10},
          prefix: schema_name
        )

      assert {:ok, _} =
               Letflow.Engine.complete_task(
                 child_task.id,
                 %{
                   output_variables: %{},
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: "req207-corrective-work-" <> to_string(child_task.id)
                 },
                 prefix: schema_name
               )

      {:ok, final_projection} = Letflow.Instances.get_by_id(instance_id, prefix: schema_name)

      assert final_projection.status == :completed,
             "Expected parent instance to reach COMPLETED after child completion; observed: #{inspect(final_projection.status)}"

      # Terminal-node-identity (OQ-3, same re-resolution as the false-positive test):
      # current_nodes is [] once completed regardless of which END node was reached
      # (dispatch_end/3 unconditionally drops the token). The real, queryable signal
      # here is the parent's own SUB_PROCESS_COMPLETED event payload's
      # "activated_nodes" field (Letflow.Engine.SubProcess.append_sub_process_completed_event/8)
      # -- empty here too, since corrective-action-subprocess routes directly to
      # end-closed with no further real node. Confirms the same COMPLETED-with-no-
      # remaining-tokens shape as the false-positive scenario, via a different (parent-
      # stream) event, and confirms this is genuinely end-closed by construction (the
      # simplified graph's only edge out of corrective-action-subprocess, §2.2) rather
      # than by re-deriving it from current_nodes.
      {:ok, %{items: parent_history}} =
        Letflow.Instances.history(instance_id, %{page_size: 100}, prefix: schema_name)

      sub_process_completed_event =
        Enum.find(parent_history, &(&1.event_type == "SUB_PROCESS_COMPLETED"))

      assert sub_process_completed_event != nil,
             "Expected a SUB_PROCESS_COMPLETED event on the parent instance's stream"

      assert sub_process_completed_event.payload["activated_nodes"] == [],
             "Expected the parent's SUB_PROCESS_COMPLETED event to show activated_nodes == [] " <>
               "(corrective-action-subprocess routes directly to end-closed); observed: #{inspect(sub_process_completed_event.payload["activated_nodes"])}"

      assert final_projection.current_nodes == []
      assert final_projection.variables["false_positive"] == false
      assert final_projection.variables["severity"] == "critical"

      {:ok, final_child} = Letflow.Instances.get_by_id(child.instance_id, prefix: schema_name)
      assert final_child.status == :completed
    end
  end

  # ─── AC3: vortex-supplier-quality-deviation-false-positive ───────────────

  describe "vortex-supplier-quality-deviation-false-positive" do
    test "quarantine -> severity false-positive; reaches end-false-positive specifically",
         %{
           schema_name: schema_name,
           actors: actors,
           definitions: %{deviation: definition}
         } do
      scenario_raw =
        ScenarioFixture.load!(
          Path.join(@scenarios_dir, "supplier-quality-deviation-false-positive.yaml")
        )

      scenario =
        patch_scenario(scenario_raw,
          schema_name: schema_name,
          definition_name: definition.name,
          actors: actors
        )

      assert {:ok, report} = Runner.run(scenario)

      # 5 declared steps (design §3.3: 1 + quarantine lookup/complete pair + severity
      # lookup/complete pair).
      assert length(report.step_results) == 5
      [step1, step2a, step2b, step3a, step3b] = report.step_results

      assert step1.outcome == :ok,
             "step 1 (POST /instances) failed — detail: #{inspect(step1.detail)}"

      instance_id = step1.captured["instance_id"]

      assert step2a.outcome == :ok,
             "step 1b (GET /tasks quarantine-lookup) failed — detail: #{inspect(step2a.detail)}"

      assert step2b.outcome == :ok,
             "step 1b (POST /tasks quarantine-complete) failed — detail: #{inspect(step2b.detail)}"

      assert step3a.outcome == :ok,
             "step 2a (GET /tasks severity-lookup) failed — detail: #{inspect(step3a.detail)}"

      assert step3b.outcome == :ok,
             "step 2b (POST /tasks severity-complete: false_positive) failed — detail: #{inspect(step3b.detail)}"

      assert length(report.outcome_results) == 3
      [eo1, eo2, eo3] = report.outcome_results

      assert eo1.outcome == :pass,
             "EO-1 instance_state (COMPLETED) failed — observed: #{inspect(eo1.observed)}"

      assert eo2.outcome == :pass,
             "EO-2 instance_state (variables) failed — observed: #{inspect(eo2.observed)}"

      assert eo3.outcome == :pass,
             "EO-3 instance_state (status placeholder) failed — observed: #{inspect(eo3.observed)}"

      # Terminal-node-identity check (OQ-3, RE-RESOLVED against the real projection
      # shape -- current_nodes/activated_nodes are NOT usable: dispatch_end/3
      # (lib/letflow/engine/transition.ex:373-379) unconditionally drops a token the
      # instant it reaches an END node, so current_nodes is always [] once
      # status == :completed, for EVERY terminal END node alike -- it cannot
      # distinguish end-false-positive from end-closed. The real, queryable signal is
      # the severity-classification task's own TASK_COMPLETED event payload's
      # "activated_nodes" field (lib/letflow/engine.ex append_task_completed_event/5):
      # on the false-positive path, false-positive-check routes directly to
      # end-false-positive with no further real node in between, so
      # activated_nodes == [] for the SAME reason current_nodes is [] afterward --
      # BUT distinctly from the critical scenario, where severity-classification's own
      # completion routes onward to corrective-action-subprocess (a SUB_PROCESS node
      # that PARKS a :waiting token, not an END node), so that scenario's own
      # severity-classification TASK_COMPLETED event has a NON-empty activated_nodes
      # (["corrective-action-subprocess"]) at the same point in the hop chain. This
      # asymmetry -- empty vs. non-empty activated_nodes on the severity-classification
      # completion event specifically -- is the real, re-derived distinguishing
      # evidence between the two scenarios' terminal outcomes.
      {:ok, %{items: history_items}} =
        Letflow.Instances.history(instance_id, %{page_size: 100}, prefix: schema_name)

      severity_task_id = step3a.captured["items"] |> List.first() |> Map.fetch!("id")

      severity_completed_event =
        Enum.find(history_items, fn event ->
          event.event_type == "TASK_COMPLETED" and event.payload["task_id"] == severity_task_id
        end)

      assert severity_completed_event != nil,
             "Expected a TASK_COMPLETED event for the severity-classification task"

      assert severity_completed_event.payload["activated_nodes"] == [],
             "Expected severity-classification's own TASK_COMPLETED event to show " <>
               "activated_nodes == [] (direct route to end-false-positive, no " <>
               "intervening real node); observed: #{inspect(severity_completed_event.payload["activated_nodes"])}"

      {:ok, projection} = Letflow.Instances.get_by_id(instance_id, prefix: schema_name)
      assert projection.status == :completed
      assert projection.current_nodes == []

      # Structural cross-check closing the gap left by activated_nodes == [] alone:
      # empty activated_nodes is consistent with EITHER a same-node-count-of-hops route
      # to end-false-positive OR a (bugged) direct route to end-closed -- no persisted
      # event anywhere in this codebase records the literal target END node id
      # (confirmed this session: grepped every event_type: "..." append site under
      # lib/letflow/ -- none carries a target-node field; dispatch_end/3 discards
      # token.node_id, the one place it briefly holds the real END id, without
      # recording it). The seeded graph (`@simple_supplier_deviation_graph`, this
      # module) is itself the ground truth for which literal node a given edge/condition
      # leads to, since it's the actual definition the instance ran against -- so assert
      # directly against it, not against a separately-typed literal, closing the loop:
      # this run took the `false_positive == true` edge (the only variable set on this
      # scenario's instance, `false_positive: true` with no `severity` -- confirmed
      # above via eo2's variables assertion) out of `false-positive-check`, and that
      # edge's own recorded target is the literal string "end-false-positive", never
      # "end-closed". A future edit that pointed the `false_positive == true` edge at
      # "end-closed" instead would flip this assertion, even though activated_nodes
      # would still read [] either way.
      false_positive_edge =
        Enum.find(@simple_supplier_deviation_graph["edges"], fn edge ->
          edge["source"] == "false-positive-check" and
            edge["condition"] == "variables.false_positive == true"
        end)

      assert false_positive_edge != nil,
             "Expected the seeded graph to declare an edge out of false-positive-check " <>
               "conditioned on variables.false_positive == true"

      assert false_positive_edge["target"] == "end-false-positive",
             "Expected the false_positive == true edge to target end-false-positive " <>
               "specifically, not end-closed (both are END nodes in this graph, and " <>
               "activated_nodes == [] alone cannot distinguish them); observed target: " <>
               inspect(false_positive_edge["target"])

      refute false_positive_edge["target"] == "end-closed",
             "The false_positive == true edge must not target end-closed -- that is " <>
               "the critical scenario's own terminal node and AC3's whole point is " <>
               "that these two scenarios reach genuinely distinct terminal states"
    end
  end

  # ─── AC4: vortex-entity-list-filter-and-page ─────────────────────────────

  describe "vortex-entity-list-filter-and-page" do
    test "disposition is BLOCKED_ON_DEPENDENCY on the S8 simulation harness' :gui dispatch, re-derived live after REQ-311 completed the record read path" do
      # ══════════════════════════════════════════════════════════════════════
      # ⛔ DISPOSITION RE-DERIVED 2026-09-11 (SECOND TIME THE SAME DAY), AFTER
      # REQ-311 LANDED. THE TRIPWIRE FIRED A SECOND TIME, EXACTLY AS ARMED.
      #
      # What fired: Signal 3'''s nine-route equality assertion, with
      #   "Unexpected: [{\"POST\", \"/query\", :EntitiesQuery}]; missing: []."
      # -- the literal failure message the previous round wrote for this
      # moment. Once again it fired on the CODE, not on the status list:
      # docs/requirements.yaml still reads REQ-311 `status: pending` because
      # DOC-UPDATER has not run yet. That is the same one-pipeline-step lag the
      # 2026-09-11 (first) block already recorded as this mechanism's single
      # blind spot, now observed a second time -- and once again a
      # code-derived signal, not the status list, is what caught it. Two
      # independent firings, same mechanism, same lag. The redundancy is doing
      # exactly the work it was built for.
      #
      # WHAT THE RE-DERIVATION FOUND -- the disposition stays
      # :blocked_on_dependency, but the BLOCKER AND ITS OWNER HAVE CHANGED,
      # for the second time:
      #
      #   2026-09-09: blocked on "the entity subsystem has no HTTP surface"
      #                 (no router, no mount, no context module)  -- owner S10
      #   2026-09-11: blocked on "POST /entities/query does not exist"
      #                 (REQ-310 shipped definition CRUD + record WRITES only)
      #                                                            -- owner S10
      #   2026-09-11: blocked on "Letflow.Simulation.Runner dispatches no
      #    (this)      :gui step at all"                            -- owner S8
      #
      # The record READ path is now COMPLETE. Verified live, not assumed:
      #
      #   * Letflow.Routers.Entities.__authz_routes__/0 returns TEN routes,
      #     including {"POST", "/query", :EntitiesQuery} -- asserted positively
      #     below (Signal 3'' inverted);
      #   * that route is a real composing handler (Types -> Compiler ->
      #     Allowlist -> Cursor -> FieldGrants), not a stub;
      #   * :EntitiesQuery, REQ-309's vocabulary minted ahead of its route, is
      #     now CONSUMED by that route -- the "specified but unserved" state
      #     Signal 3''' existed to detect is over, so that signal is inverted
      #     too rather than deleted.
      #
      # ⛔ Letflow.Entities.Records STILL exports no read function, and that is
      # now EVIDENCE OF CORRECTNESS, not evidence of a gap. It is a
      # command-only context module BY DESIGN (design §1's "no route reads a
      # record by id"); the read path is the QUERY ROUTE, never a Records read
      # function. The previous round's Signal 3' asserted that absence as proof
      # the subsystem could not serve reads. That inference is now FALSE -- the
      # absence holds and reads ARE served -- so the assertion is KEPT but its
      # MEANING IS RESTATED (Signal 3' below): it now pins the design rule
      # itself, which a future `list_records/2` would violate.
      #
      # THE REMAINING BLOCKER IS THE HARNESS, AND IT IS GENUINELY INDEPENDENT.
      # The previous round deliberately recorded it as a SEPARATE evidence line
      # precisely so REQ-311 landing could not silently green this test. That
      # separation is what made this re-derivation honest instead of automatic:
      # the route blocker cleared, the harness blocker did not, and the two
      # were never conflated. test/support/simulation/runner.ex's run_steps/1
      # matches a bare `:gui ->` clause in `case step.via do`, with NO guard and
      # NO condition, building `outcome: :deferred_to_s8` and returning without
      # ever calling dispatch_api_step/4. Confirmed live this session:
      # runner.ex is not in this branch's diff, is unmodified in the working
      # tree, and all six of this scenario's fixture steps are `via: gui`.
      #
      # So the scenario STILL cannot execute -- but no longer because anything
      # is missing from lib/. Everything the six steps need over HTTP now
      # exists; the harness simply refuses to make the calls. That is S8's
      # frontend-cutover work, NOT S10's.
      #
      # ⛔ THE NEXT TRIPWIRE IS ARMED AGAINST THE RUNNER (Signal 5 below), not
      # against a route or a requirement id. See that signal for why it asserts
      # on OBSERVED BEHAVIOUR rather than on runner.ex's source text.
      #
      # ── PRESERVED HISTORY: the 2026-09-11 (first) re-derivation block ─────
      # Everything from here to the end of this banner is the previous round's
      # own reasoning, kept verbatim as the record of why THAT disposition held.
      # Its factual claims were true when written; the ones REQ-311 has since
      # falsified are marked, never deleted.
      #
      # DISPOSITION RE-DERIVED 2026-09-11, AFTER REQ-310 LANDED (f6e0ae64).
      #
      # The 2026-09-11 ⛔ block preserved below predicted exactly this moment
      # and instructed that the right response is to re-derive, never to
      # allowlist REQ-310. That is what happened here. The old disposition --
      # "the entity subsystem has no HTTP surface" -- is now FACTUALLY FALSE
      # and has been replaced, not patched:
      #
      #   * /entities IS mounted (api_pipeline.ex), Signal 1's old assertion
      #     inverted accordingly (Signal 1' below asserts the mount POSITIVELY);
      #   * both deferred-routes rows ARE gone from router.ex (Signal 1'');
      #   * Letflow.Routers.Entities exists and serves NINE real routes.
      #     [SUPERSEDED 2026-09-11 by REQ-311: it now serves TEN.]
      #
      # The scenario is nonetheless STILL BLOCKED, for a different and much
      # narrower reason, and the assertions below are correspondingly sharper
      # than the ones they replace:
      #
      #   ⇒ All six of this scenario's :gui steps are RECORD READS (list,
      #     filter x2, sort, page, field-level redaction -- see the fixture).
      #     Record reads happen ONLY through POST /entities/query
      #     (lib/letflow/design/req308-entity-http-surface.md:182, verbatim:
      #     "record reads only happen via /entities/query"), and that route is
      #     REQ-311's, still unbuilt. REQ-310 shipped definition CRUD plus
      #     record WRITES; there is no record read path anywhere -- not a
      #     route, and not even a context function to hang one off
      #     (Letflow.Entities.Records is command-only).
      #     [SUPERSEDED 2026-09-11 by REQ-311: POST /entities/query IS built
      #     and served, so the record read path IS complete. The clause about
      #     Records being command-only remains TRUE and is now correctness,
      #     not a gap -- see the banner above.]
      #
      # Signal 3 was ALSO rewritten rather than kept, because REQ-310 made it
      # a tautology: it asserted lib/letflow/entities.ex and
      # lib/letflow/entity_query.ex do not exist, and they still do not -- but
      # the subsystem shipped under lib/letflow/entities/ (a DIRECTORY:
      # definitions.ex, records.ex, entity_definition.ex, query/) and was never
      # going to occupy those two flat paths. Asserting their absence proved
      # the subsystem was unbuilt in 2026-09-09 and proves nothing at all
      # today. It is replaced by a capability check (Signal 3'): no read
      # function is exported by Letflow.Entities.Records.
      #
      # This test now also RUNS the scenario (Runner.run/1) rather than
      # recording steps_executed: 0 -- see Signal 4 and the disposition_report
      # at the bottom.
      # ══════════════════════════════════════════════════════════════════════

      # ── Signal 1' (INVERTED): /entities IS mounted. ───────────────────────
      # The old test asserted the opposite. Asserting the mount POSITIVELY
      # means this file can never silently drift back into certifying that a
      # serving subsystem is absent.
      api_pipeline_content =
        File.read!(Path.expand("../../../lib/letflow/plugs/api_pipeline.ex", __DIR__))

      assert api_pipeline_content =~ ~s|forward("/entities", to: Letflow.Routers.Entities)|,
             "Expected api_pipeline.ex to mount Letflow.Routers.Entities at /entities " <>
               "(REQ-310 point 5). If this fails, the mount was reverted and this " <>
               "scenario's disposition must be re-derived AGAIN -- it would be blocked " <>
               "on the whole HTTP surface once more, not just on the query route."

      # ── Signal 1'' : the deferred-routes rows are RETIRED from router.ex. ─
      # REQ-310 point 7 deleted both outright ("REMOVED outright, not
      # annotated"). Pinning their absence pins that retirement.
      router_content = File.read!(Path.expand("../../../lib/letflow/router.ex", __DIR__))

      refute router_content =~ "Letflow.Routers.Entities",
             "Expected router.ex's deferred-routes row for Letflow.Routers.Entities to be " <>
               "GONE (REQ-310 point 7 removed it outright); a reappearance means the mount " <>
               "was reverted"

      refute router_content =~ "Letflow.Routers.EntityQuery",
             "Expected router.ex's deferred-routes row for Letflow.Routers.EntityQuery to be " <>
               "GONE (REQ-310 point 7 removed it outright)"

      # Signal 2: every docs/requirements.yaml title: claiming the entity/entity-query
      # subsystem (word-bounded entity/entities match, not the bare "entit" substring
      # which false-positives on "identity") traces back to either REQ-207's own
      # self-referential title, or one of REQ-225..231 -- the scoping requirements
      # ISS-0438 registered to plan the subsystem's build-out (design doc
      # lib/letflow/design/iss0438-entity-subsystem-scoping.md). REQ-225..231 *plan*
      # the subsystem; none of them *build* it -- that's still gated on Signal 3 below,
      # so their presence here doesn't change the BLOCKED_ON_DEPENDENCY disposition.
      #
      # UPDATE (S10 expansion, 2026-09-09): REQ-295, REQ-296, REQ-299, REQ-300 and
      # REQ-302 were filed against
      # docs/migration/decisions/0023-entity-storage-hybrid.md (entity storage as
      # per-entity-type tables with a hybrid promoted-column/blob shape) and match
      # this same word-bounded pattern, so they join the allowlist. They do NOT
      # change the disposition, for the same reason REQ-225..231 do not: they
      # re-shape how entity records are STORED (and REQ-295/REQ-302 only answer
      # design questions -- 0023 forbids filing any implementation requirement
      # against it until its DDL-execution open question is answered and gated).
      # None of them mounts Letflow.Routers.Entities or Letflow.Routers.EntityQuery
      # -- that HTTP surface is S10's own gap 1. (That gap was unowned and unfiled
      # when this block was written on 2026-09-09; it is owned by REQ-308 as of
      # 2026-09-11 -- see the third UPDATE below. Still unmounted either way.)
      # Signal 3 below remains the real gate, and it was re-verified live rather
      # than assumed when this allowlist was extended: neither context module
      # exists, and both router rows are still in the reserved/unbuilt table.
      #
      # UPDATE (S10 gap 13, 2026-09-10): REQ-304 joins the allowlist. It adds an
      # entity_definitions section to Letflow.Definitions.SolutionPack's pack
      # document so a solution pack can CARRY an entity definition -- delivery,
      # not runtime. It mounts no route and builds no context module, so the
      # disposition is unaffected for the same reason as the entries above.
      # Signal 3 was re-verified live again here rather than assumed: still no
      # lib/letflow/entities.ex, no lib/letflow/entity_query.ex, no entity
      # router module under lib/letflow/routers/, and Letflow.Routers.Entities
      # still present only as a reserved/unbuilt row in router.ex.
      #
      # UPDATE (S10 gap 1, 2026-09-11): REQ-308 joins the allowlist. It is the
      # first requirement to actually OWN gap 1 -- the entity HTTP surface the
      # 2026-09-09 block above called "still unowned and unfiled" (that sentence
      # was true when written and is corrected in place above). REQ-308 is a
      # DESIGN requirement and nothing more: owner CODE-DESIGNER, its sole
      # artefact is a design document under lib/letflow/design/, and its own
      # description scopes it "exactly as REQ-295 and REQ-303 were: a design
      # artefact under lib/letflow/design/, no lib/ implementation, no route
      # mounted, no test". A design artefact mounts no route and builds no
      # context module, so the disposition is unaffected -- deciding the shape
      # of a surface is not the same as serving it. The requirement that
      # implements REQ-308's design is the one that will flip this scenario,
      # and it is not filed yet. Signal 3 was re-verified live here rather than
      # assumed, for the third time: no lib/letflow/entities.ex, no
      # lib/letflow/entity_query.ex, no entity router module among the sixteen
      # files under lib/letflow/routers/, both Entities/EntityQuery still only
      # reserved/unbuilt rows in router.ex, and api_pipeline.ex's forward list
      # still has no entities entry.
      #
      # UPDATE (S10 gap 1, 2026-09-11, second block of the same day): REQ-309
      # joins the allowlist, and this block additionally records a DATED WARNING
      # about REQ-310, which is the requirement that finally flips this test.
      #
      # REQ-309 first. It is the first implementation requirement built from
      # REQ-308's design (lib/letflow/design/req308-entity-http-surface.md §3),
      # and it is deliberately the vocabulary half of that design and nothing
      # more: it adds four permission atoms (:EntitiesDefinitionsRead,
      # :EntitiesDefinitionsWrite, :EntitiesRecordsWrite, :EntitiesQuery), the
      # matching endpoint_policy_key/2 clauses and the role_allows?/2 matrix
      # arms, all inside lib/letflow/api/authorization.ex. Its own scope fence
      # says it in as many words: "It creates no router, mounts no route,
      # touches no file under lib/letflow/routers/, does not edit
      # lib/letflow/router.ex or lib/letflow/plugs/api_pipeline.ex". A policy
      # key with no route consuming it is unreachable over HTTP -- the same
      # "ported ahead of its consuming route" state :DlqOperate and
      # :WebhooksManage already sat in. So the disposition is unaffected:
      # naming the permission that WOULD gate a surface is not serving that
      # surface. All three signals were re-verified live here rather than
      # assumed, for the fourth time: router.ex lines 82-83 still carry
      # `Letflow.Routers.Entities` / entities.zig and
      # `Letflow.Routers.EntityQuery` / entity_query.zig as rows in the
      # "## Deferred routes (not yet mounted -- added by owning stage)" table
      # and nowhere else; no lib/letflow/entities.ex; no
      # lib/letflow/entity_query.ex; no entity router among the sixteen files
      # under lib/letflow/routers/; and api_pipeline.ex's forward list (lines
      # 141-153) still forwards only identity, tenants, instances, definitions,
      # tasks, promotions, onboarding, solution-packs, audit, dlq, webhooks,
      # services and admin/services -- no /entities.
      #
      # ⛔⛔ NOW THE WARNING. READ THIS BEFORE TOUCHING THE ALLOWLIST AGAIN. ⛔⛔
      #
      # REQ-310 ("Create Letflow.Routers.Entities with the nine definition and
      # record routes, mount it at /entities, and retire the two deferred-routes
      # rows" -- filed, status pending, letflow-queue task 597) IS THE
      # REQUIREMENT THAT FLIPS THIS TEST. Its description, points 1, 5 and 7,
      # commits to exactly the three things this scenario's disposition rests on
      # being absent:
      #
      #   * point 1 creates lib/letflow/routers/entities.ex -> Signal 3 goes
      #     false (the context/router surface exists);
      #   * point 5 adds `forward("/entities", to: Letflow.Routers.Entities)` to
      #     lib/letflow/plugs/api_pipeline.ex -> the subsystem becomes reachable
      #     over HTTP;
      #   * point 7 DELETES both the `Letflow.Routers.Entities` and
      #     `Letflow.Routers.EntityQuery` rows from router.ex's deferred-routes
      #     table outright ("REMOVED outright, not annotated") -> Signal 1 goes
      #     false, and this test's two `router_content =~ ...` assertions above
      #     will fail on their own.
      #
      # WHEN REQ-310 LANDS, THIS SCENARIO'S BLOCKED_ON_DEPENDENCY DISPOSITION
      # BECOMES FACTUALLY WRONG. The entity list/filter/page surface the vortex
      # scenario exercises will be live, so the scenario should actually RUN --
      # Runner.run/1 against entity-list-filter-and-page.yaml, its six :gui
      # steps executed and asserted -- rather than be recorded as blocked with
      # steps_executed == 0.
      #
      # ⛔ DO NOT "FIX" THE REQ-310 FAILURE BY ADDING "REQ-310" TO allowed_ids.
      # That is the wrong reflex and it is precisely the failure mode this
      # tripwire exists to prevent. The allowlist triages a requirement whose
      # TITLE mentions entities but which does not BUILD the subsystem; REQ-310
      # builds it. Admitting it to the allowlist would silence the title
      # assertion while leaving Signals 1 and 3 to fail anyway, and anyone who
      # then also "fixed" those would be left with a green test asserting a
      # disposition that is false -- a test actively certifying that a shipped,
      # mounted, HTTP-reachable subsystem is missing. That is worse than no test.
      #
      # WHOEVER IMPLEMENTS REQ-310 MUST RE-EVALUATE THIS SCENARIO'S DISPOSITION
      # ITSELF: re-derive it against the three signals as they then stand (all
      # false), replace this whole describe block's blocked-on-dependency
      # bookkeeping with a real execution of the scenario, and update
      # lib/letflow/design/ §4.1/§4.3's disposition table to match. Route it
      # through TEST-DESIGNER rather than patching it inline: the change is a
      # new test, not an allowlist edit.
      #
      # NOTE ON WHY REQ-310 AND REQ-311 APPEAR BELOW ANYWAY. Both are already
      # FILED in docs/requirements.yaml (pending, queue tasks 597 and 598), and
      # both carry entity titles, so this tripwire fires on them TODAY -- on the
      # mere filing, years before the code lands. Filing builds nothing, so the
      # disposition is still correct and they must be admitted. But admitting
      # them flatly would burn the warning above: the test would then stay green
      # straight through REQ-310 landing, and the only thing standing between a
      # mounted /entities and a test asserting it does not exist would be
      # whether someone read this comment. So they are admitted CONDITIONALLY,
      # in a second list the test checks against their live `status:` -- pending
      # passes, anything else fails loudly with these instructions. REQ-311
      # ("POST /entities/query", which REQ-310's §SCOPE explicitly defers to it)
      # is armed the same way and for the same reason.
      requirements_content =
        File.read!(Path.expand("../../../docs/requirements.yaml", __DIR__))

      title_lines = String.split(requirements_content, "\n")

      entity_title_matches =
        title_lines
        |> Enum.with_index()
        |> Enum.filter(fn {line, _idx} ->
          Regex.match?(~r/title:.*\bentit(y|ies)\b/i, line)
        end)

      allowed_ids =
        MapSet.new([
          "REQ-207",
          "REQ-225",
          "REQ-226",
          "REQ-227",
          "REQ-228",
          "REQ-229",
          "REQ-230",
          "REQ-231",
          "REQ-295",
          "REQ-296",
          "REQ-299",
          "REQ-300",
          "REQ-302",
          "REQ-304",
          "REQ-308",
          "REQ-309",
          # Promoted from pending_only_ids on 2026-09-11 -- see the block below
          # the list for why each promotion is a triage result, not a silencing.
          "REQ-310",
          # Promoted from pending_only_ids on 2026-09-11 (second re-derivation
          # of the same day), for exactly the same reason REQ-310 was: its code
          # has landed, the tripwire fired on it, its disposition consequence
          # was re-derived in full, and THIS REWRITE is that re-derivation's
          # output. REQ-311 built POST /entities/query; the record read path is
          # now complete and every assertion in this block that spoke of it as
          # missing has been inverted to assert its presence. It is not being
          # waved through -- it was triaged, and the triage changed the test.
          "REQ-311",
          # UPDATE (S10 fourth batch, 2026-09-11): REQ-312, REQ-313 and REQ-314
          # join the allowlist -- design-only requirements for S10 gaps 2
          # (aggregation/reporting query), 3 (entity-record attachments) and 12
          # (bulk import/export), scoped IDENTICALLY to REQ-308's own precedent:
          # owner CODE-DESIGNER, sole artefact a design document under
          # lib/letflow/design/, and a scope fence that in as many words
          # forbids touching lib/letflow/routers/, lib/letflow/entities/,
          # lib/letflow/api/ (lib/letflow/repository/ too, for REQ-313) or
          # test/. All three depend_on REQ-311 (they attach to the concrete
          # route surface REQ-309/310/311 landed) but attaching-to is not
          # building; none of the three mounts a route or adds a context
          # module of its own.
          #
          # This is NOT the REQ-310 reflex the ⛔ block above warns against.
          # REQ-310/311 build the HTTP surface itself; these three only design
          # what might attach to it later, exactly as REQ-308 designed the
          # surface itself before REQ-309/310/311 built it. Signal 3'/3''
          # below stay the real gate.
          #
          # REQ-312 and REQ-314 are `status: pending` -- filing builds
          # nothing, so admitting them unconditionally (rather than via
          # pending_only_ids) is still correct for this class, the same as
          # REQ-295/296/299/300/302/304/308/309 above: none of those was ever
          # placed in pending_only_ids either, because pending_only_ids exists
          # specifically for requirements that DO build the HTTP surface and
          # simply have not landed yet -- these three never build it, filed or
          # not, so there is nothing to re-derive once they flip to done.
          #
          # REQ-313 is `status: done` -- independently re-verified this
          # session, not trusted from its requirement text: `git show
          # --name-only` across all four of its commits (d21b6aea, 75b72172,
          # d34bb30f, 8891132c) touches only
          # lib/letflow/design/req313-entity-record-attachments.md plus
          # docs/requirements.yaml and docs/status/ bookkeeping; `git diff
          # --name-only main design/REQ313-20260911 -- lib/letflow/routers/
          # lib/letflow/entities/ lib/letflow/api/
          # lib/letflow/plugs/api_pipeline.ex lib/letflow/router.ex test/` is
          # empty; and api_pipeline.ex's forward list still reads exactly
          # `forward("/entities", to: Letflow.Routers.Entities)` with no
          # attachments-specific mount added. Signal 3''/the route-equality
          # assertion below were re-checked live and still hold exactly REQ-
          # 311's ten routes -- no eleventh route for attachments exists.
          "REQ-312",
          "REQ-313",
          "REQ-314",
          # REQ-315, admitted 2026-09-12 -- NOT via the REQ-312/313/314 route.
          # REQ-315 lands real code (a new :EntitiesAggregate permission, a
          # new Compiler.run_aggregate/2, and an eleventh route mounted on
          # Letflow.Routers.Entities: POST /entities/query/aggregate,
          # confirmed live against __authz_routes__/0). That builds the HTTP
          # surface, the REQ-310/311 shape the ⛔ block below warns against
          # silencing -- so it was re-derived first, not admitted on sight.
          # The re-derivation (full account in the moduledoc above): this
          # scenario's six :gui steps are individual-record list/filter/
          # sort/page/redaction reads, every one of them served by REQ-311's
          # POST /entities/query; none aggregates anything, so the new
          # aggregate route (a different read shape, gated by the DISTINCT
          # :EntitiesAggregate permission) closes no gap this scenario was
          # waiting on. Signal 3'' below now asserts the real eleven-route
          # set by equality; the disposition is unchanged -- still blocked
          # on S8's GUI harness (Signal 5). Admitted here only because that
          # re-derivation is complete and its output is what Signal 3''
          # below now asserts, exactly the REQ-310/311 precedent.
          "REQ-315",
          # REQ-394, promoted from pending_only_ids on 2026-09-23 after its status
          # flipped to done and the tripwire fired exactly as armed. Re-derived
          # in full (see the moduledoc's "REQ-394 lands" section above), not
          # waved through: it layers a new per-entity-type authorization check
          # onto the two EXISTING routes this scenario depends on (POST
          # /entities/query, GET /entities/definitions/active/:name) -- no
          # route added, removed, or renamed on Letflow.Routers.Entities
          # (confirmed live via `git diff main..bd77a129 --
          # lib/letflow/routers/entities.ex`, which touches only handler
          # bodies, never an authz_post/authz_get declaration), and
          # test/support/simulation/runner.ex is untouched by its commit. So
          # neither Signal 3'' (route-set equality) nor Signal 5 (the harness
          # blocker) moved, and this scenario's fixture never exercises a
          # denied entity type, so REQ-394's own denial-vs-empty-type behavior
          # change is never observed by these six steps either way. Disposition
          # unchanged: still blocked on S8's GUI harness (Signal 5).
          "REQ-394",
          # REQ-317/318/319/320, admitted 2026-09-12 -- the S10 gap 3
          # part-2/gap 12 batch filed alongside REQ-315..320 (main commits
          # ac492a25/6fdcbcd8/9cf2c177). All four are `status: pending` --
          # filing builds nothing, so unconditional admission is correct
          # regardless of tier for THAT reason alone, matching
          # REQ-295/296/299/300/302/304/308/309/312/314's precedent. But two
          # of them (REQ-317: four record-attachment routes; REQ-319/320:
          # the export/import routes) DO plan to build real HTTP surface on
          # Letflow.Routers.Entities once implemented, which is the
          # REQ-310/311 shape the pending_only_ids tier exists for -- so the
          # honest question is whether they belong there instead.
          #
          # They do not, and here is why admitting them straight to
          # allowed_ids is still safe, not the wrong reflex: none of the
          # three routes they plan (attachments CRUD, bulk export, bulk
          # import) is anything this scenario's six :gui steps read through
          # -- those six are individual-record list/filter/sort/page/
          # redaction, served exclusively by REQ-311's POST /entities/query,
          # exactly the same reasoning that put REQ-315's aggregate route in
          # allowed_ids above. AND, unlike when REQ-310/311 were filed (the
          # equality check Signal 3'' now runs did not exist yet, so nothing
          # would have caught their landing except this very allowlist),
          # Signal 3'' already asserts Letflow.Routers.Entities'
          # __authz_routes__/0 by EQUALITY today. Any route REQ-317/319/320
          # add will change that set and fail Signal 3'' the moment it lands,
          # forcing exactly the re-derivation pending_only_ids was built to
          # force -- with or without this entity-title tripwire's help. The
          # structural backstop already exists for this router; the
          # two-tier mechanism's stated purpose (kept above, empty, for
          # "the next such requirement") is for a requirement that builds
          # surface OUTSIDE what Signal 3'' already watches, and none of
          # these four do. REQ-318 builds no route at all (permission atoms
          # only, the REQ-309 shape).
          "REQ-317",
          "REQ-318",
          "REQ-319",
          "REQ-320",
          # REQ-324, admitted 2026-09-12 -- lifts Definition.Validator Rule 9
          # (self-referential fk_def) and fixes a Query.Compiler self-join
          # ambiguity this exposed (main commit 87fb4d6f). Re-derived, not
          # waved through: `git show --stat 87fb4d6f` touches only
          # lib/letflow/entities/definition/validator.ex and
          # lib/letflow/entities/query/compiler.ex plus their tests -- no
          # file under lib/letflow/routers/ or lib/letflow/api/, no new
          # permission atom, no route added to or removed from
          # Letflow.Routers.Entities, so Signal 3''s eleven/fifteen-route
          # equality assertion is untouched by this commit. The
          # Query.Compiler change only matters for a self-referential join
          # (same physical table on both sides of a fk-column condition);
          # this scenario's fixture (entity-list-filter-and-page.yaml) uses
          # ordinary, non-self-referential entity types and never exercises
          # a self-join, so the fix changes nothing this scenario's six
          # :gui steps read through. Those six remain individual-record
          # list/filter/sort/page/redaction reads, all served exclusively by
          # REQ-311's POST /entities/query, unaffected by Rule 9's lift.
          # Disposition unchanged: still BLOCKED_ON_DEPENDENCY on S8's
          # :gui-dispatch stub (Signal 5), nothing under lib/ left for this
          # scenario to wait on.
          "REQ-324",
          # REQ-326/327/328, admitted 2026-09-13 -- filed on `main`
          # (chore/WF01-REQ326-328-20260912, commits 4215fd21/bb5080d5,
          # merged via #1304) and discovered when rebasing
          # feature/WF02-REQ324-20260912 onto the moved `main`. All three
          # are bucket A per decision 0022 (each description's own first
          # line: "AUTHORS PACK CONTENT, NOT PLATFORM CODE"), owner
          # REQ-ANALYST, `status: pending` at admission time (filing builds
          # nothing, same basis as REQ-295/296/299/300/302/304/308/309/
          # 312/314's precedent above). Their own scope fences/acceptance
          # criteria state the diff lands ONLY under priv/packs/bilimbaga/
          # and a new test/letflow/packs/ file -- no lib/letflow/routers/,
          # no lib/letflow/entities/, no lib/letflow/api/, no route added
          # to or removed from Letflow.Routers.Entities. None of them is
          # the REQ-310/311 shape: REQ-326/327 author entity_definitions
          # pack content (question-bank / exam-configuration), REQ-328
          # authors and installs the pack document via a real
          # SolutionPack.install/3 -- none mounts, extends or reads through
          # an HTTP route this scenario's six :gui steps depend on (those
          # six remain individual-record list/filter/sort/page/redaction
          # reads, served exclusively by REQ-311's POST /entities/query).
          # Disposition unaffected either way -- still BLOCKED_ON_DEPENDENCY
          # on S8's :gui-dispatch stub.
          "REQ-326",
          "REQ-327",
          "REQ-328",
          # REQ-329, admitted 2026-09-13 -- same shape as REQ-326/327/328
          # directly above: bucket A per decision 0022 (description's own
          # first line: "AUTHORS PACK CONTENT" -- session/session_question/
          # session_answer/session_event/session_question_score entity
          # definitions), owner REQ-ANALYST, `status: pending` at admission
          # time. `git diff --name-only` on feature/WF02-REQ329-20260913
          # confirms the change lands ONLY under
          # priv/packs/bilimbaga/entity_definitions/ and
          # test/letflow/packs/bilimbaga_entity_definitions_test.exs -- no
          # lib/letflow/routers/, no lib/letflow/entities/, no
          # lib/letflow/api/, no route added to or removed from
          # Letflow.Routers.Entities. Does not mount, extend or read
          # through any HTTP route this scenario's six :gui steps depend
          # on. Disposition unaffected: still BLOCKED_ON_DEPENDENCY on S8's
          # :gui-dispatch stub.
          "REQ-329",
          # REQ-331, admitted 2026-09-13, unconditionally rather than via
          # the pending-only tier -- unlike REQ-310/311, this one does NOT
          # build the entity HTTP surface even once it lands. Bucket B: a
          # generic deadline-driven record-transition sweep added to the
          # EXISTING lib/letflow/scheduler/poller.ex (own acceptance
          # criteria: "no new GenServer module, no new supervisor child, no
          # second ticker"). It writes through Letflow.Entities.Records'
          # existing transactional contract but mounts no route, extends no
          # route, and does not touch Letflow.Routers.Entities or
          # POST /entities/query -- the route this scenario's six :gui
          # steps depend on. `status: pending` at admission time (also
          # `depends_on: [REQ-330]`), same basis as REQ-309's precedent
          # above ("shipped permission vocabulary only, which its own scope
          # fence confirms builds no route"). Disposition unaffected either
          # way -- still BLOCKED_ON_DEPENDENCY on S8's :gui-dispatch stub.
          "REQ-331",
          # REQ-336, admitted 2026-09-13. `status: pending` at admission
          # time (filing builds nothing). Owner FRONTEND-DEV, bucket C
          # (client) -- a generic admin-CRUD screen engine entirely under
          # web/src/, driven by an entity definition already served over
          # the existing POST /entities/query route (REQ-311). It adds no
          # backend route, no lib/letflow/routers/ change, and does not
          # touch Letflow.Routers.Entities or the :gui-dispatch stub this
          # scenario's six steps depend on -- it is a consumer of the
          # already-built backend surface, not a change to it. Disposition
          # unaffected -- still BLOCKED_ON_DEPENDENCY on S8's :gui-dispatch
          # stub.
          "REQ-336",
          # REQ-338/339/340/342/343, admitted 2026-09-13, filed together
          # as part of S10 P4's registration batch. `status: pending` at
          # admission time (filing builds nothing). REQ-338/340/342/343
          # are owner FRONTEND-DEV, bucket C (client) -- the candidate
          # exam-taking UI and admin-CRUD field-registry/screen-wiring
          # work, entirely under web/src/, consuming REQ-335's exam-
          # session routes and REQ-311's existing POST /entities/query
          # -- none adds a backend route or touches
          # Letflow.Routers.Entities. REQ-339 is owner DOC-UPDATER, pure
          # stage-file bookkeeping (bucket-C inventory update), same
          # basis as REQ-334's own precedent two entries above this
          # scenario's tripwire (filing/doc-only, zero lib/ footprint).
          # None of the five touches the :gui-dispatch stub this
          # scenario's six steps depend on. Disposition unaffected --
          # still BLOCKED_ON_DEPENDENCY on S8's :gui-dispatch stub.
          "REQ-338",
          "REQ-339",
          "REQ-340",
          "REQ-342",
          "REQ-343",
          # REQ-347, promoted from pending_only_ids on 2026-09-15 after its
          # status flipped to done and this tripwire fired exactly as armed
          # (the failure message quoted in this commit's own history). Same
          # promotion shape as REQ-310/311: NOT waved through -- re-derived
          # first. `git show --stat 822b3021` (REQ-347's own commit) touches
          # only docs/issues/ISS-0662.yaml and four new
          # web/tests/e2e/*.e2e.spec.ts files; no lib/letflow/routers/, no
          # lib/letflow/entities/, no lib/letflow/api/, no
          # lib/letflow/plugs/api_pipeline.ex, no lib/letflow/router.ex, and
          # -- the part that actually matters for THIS scenario's disposition
          # -- no test/support/simulation/runner.ex. REQ-347 is a Playwright
          # spec PORT consuming the already-built EntityCrudPage/
          # POST-/entities/query surface (its own description: "bucket: C,
          # client test artefacts"); it does not touch Signal 3''/3'''s route
          # surface (re-verified live this session: __authz_routes__/0 still
          # returns exactly the same 17-route set asserted below, unchanged
          # by REQ-347) and it does not touch Signal 5's harness (runner.ex's
          # `:gui ->` clause is unmodified -- confirmed live, see Signal 5).
          # So unlike REQ-310/311, REQ-347 landing changes NOTHING this
          # scenario's disposition rests on: it is unconditionally admitted,
          # not because filing builds nothing (it already shipped) but
          # because what it shipped is orthogonal to both remaining signals.
          # Disposition unchanged: still BLOCKED_ON_DEPENDENCY, still on S8's
          # :gui-dispatch stub (Signal 5), nothing under lib/ or
          # test/support/simulation/ left for this scenario to wait on.
          "REQ-347",
          # REQ-355, promoted from pending_only_ids on 2026-09-15 after its
          # status flipped to done and this tripwire fired exactly as armed
          # (the failure message quoted in this commit's own history: "the
          # record-read route ALL SIX of this scenario's :gui steps need...
          # HAS NOW BEEN BUILT", which is the generic pending_only_ids
          # message, not a claim specific to this requirement -- REQ-355
          # never touches that route). Same promotion shape as REQ-347: NOT
          # waved through -- re-derived first. `git show --stat 1fd89bb1`
          # (REQ-355's merge commit) touches
          # docs/migration/stage-10-bilimbaga-vertical.md,
          # lib/letflow/api/authorization.ex, lib/letflow/modules/exam/certificate.ex,
          # lib/letflow/modules/exam/router.ex,
          # lib/letflow/routers/tenant_config.ex,
          # priv/packs/bilimbaga/entity_definitions/certificate.json, and
          # their tests -- no lib/letflow/routers/entities.ex, no
          # lib/letflow/entities/, and -- the part that actually matters for
          # THIS scenario's disposition -- no test/support/simulation/
          # runner.ex. REQ-355 is a certificate-issuance context module and
          # route wired onto Letflow.Modules.Exam.Router (its own commit
          # message: "Wires an authenticated POST
          # /modules/exam/exam-sessions/:id/certificate route"), a DIFFERENT router from
          # Letflow.Routers.Entities that Signal 3''/3''' watch; it does not
          # touch Signal 3''s route surface (re-verified live this session:
          # Letflow.Routers.Entities.__authz_routes__/0 still returns exactly
          # the same 17-route set asserted below, unchanged by REQ-355) and
          # it does not touch Signal 5's harness (runner.ex's `:gui ->`
          # clause is unmodified since REQ-208, commit 69f508c3 -- confirmed
          # live, see Signal 5). So unlike REQ-310/311, REQ-355 landing
          # changes NOTHING this scenario's disposition rests on: it is
          # unconditionally admitted, not because filing builds nothing (it
          # already shipped) but because what it shipped is orthogonal to
          # both remaining signals. Disposition unchanged: still
          # BLOCKED_ON_DEPENDENCY, still on S8's :gui-dispatch stub
          # (Signal 5), nothing under lib/ or test/support/simulation/ left
          # for this scenario to wait on.
          "REQ-355",
          # REQ-393, promoted from pending_only_ids on 2026-09-23 after its
          # status flipped to done and this tripwire fired exactly as armed.
          # Same promotion shape as REQ-347/355: NOT waved through -- re-derived
          # first. REQ-393 is owner FRONTEND-DEV, bucket C (client): it adds
          # EntityListBrowserPage (a React component) and EntityFilterBuilder
          # under web/src/pages/entities/ and web/src/components/entities/,
          # a new queryKeys.entities.browserRecords key in web/src/api/queryKeys.ts,
          # and an entities/:entityType route entry in web/src/router.tsx. None
          # of those touches lib/letflow/routers/, lib/letflow/entities/,
          # lib/letflow/api/, lib/letflow/plugs/api_pipeline.ex,
          # lib/letflow/router.ex, or test/support/simulation/runner.ex.
          # Signal 3''s route surface is unaffected: __authz_routes__/0 still
          # returns exactly the same 17-route set (re-verified: no new backend
          # route was added by REQ-393, confirmed via git diff --name-only).
          # Signal 5's harness is unaffected: runner.ex's `:gui ->` clause is
          # unmodified (REQ-393 adds no test/support/simulation/ file).
          # REQ-393 is a consumer of the already-built POST /entities/query
          # surface (REQ-311), not a change to it -- the same reasoning that put
          # REQ-336/347 in allowed_ids. Disposition unchanged: still
          # BLOCKED_ON_DEPENDENCY, still on S8's :gui-dispatch stub (Signal 5),
          # nothing under lib/ or test/support/simulation/ left for this
          # scenario to wait on.
          "REQ-393"
        ])

      # SECOND-TIER ALLOWLIST -- admitted ONLY WHILE `status: pending`.
      #
      # Every id in allowed_ids above is `status: done`: each was triaged by
      # reading what it actually shipped and confirming it did not build the
      # subsystem. REQ-310 and REQ-311 cannot be triaged that way, because they
      # are the requirements that DO build it -- they are simply not built yet.
      # Filing a requirement changes nothing about what is reachable over HTTP,
      # so a pending REQ-310 leaves the disposition correct; a done REQ-310
      # makes it false.
      #
      # Rather than record that in a comment and trust the next reader, this
      # list is conditional and the test enforces the condition: the moment
      # either id's status flips to done, the assertion below fails with an
      # explicit instruction. That is why admitting them here is not the
      # "wrong reflex" the ⛔ block warns about -- they are not being waved
      # through, they are being armed.
      #
      # ⛔ THE FIX WHEN THIS FIRES IS NOT TO MOVE THE ID INTO allowed_ids ABOVE.
      # It is to re-derive this scenario's disposition against Signals 1 and 3
      # as they then stand, and to make the scenario RUN. See the ⛔ block above.
      #
      # ── 2026-09-11, AFTER REQ-310 LANDED: THIS TIER FIRED AS DESIGNED. ────
      #
      # It fired via Signal 1 rather than via the status check -- REQ-310's
      # CODE landed (f6e0ae64) while docs/requirements.yaml still reads
      # `status: pending`, because DOC-UPDATER had not yet run. Worth recording
      # plainly, because it is the mechanism's one real blind spot: `status:`
      # lags the code by one pipeline step, so the status check alone would NOT
      # have caught REQ-310. Signal 1 caught it. That redundancy is why the
      # tripwire was built with three independent signals and not just the
      # status list, and it is why Signal 1' above is now a POSITIVE assertion
      # on the mount rather than a negative one on the deferred rows.
      #
      # REQ-310 was NOT moved into allowed_ids to silence anything -- the ⛔
      # block above is explicit that doing so is the wrong reflex. It was moved
      # there only AFTER its disposition consequence was re-derived in full and
      # this whole describe block was rewritten to assert the new truth. The
      # pending-only tier's contract ("admitted only while it builds nothing")
      # no longer describes it: it HAS built something, that something was
      # triaged, and the triage is what produced the assertions above. REQ-309
      # moved for the ordinary reason -- it shipped permission vocabulary only,
      # which its own scope fence confirms builds no route.
      #
      # REQ-311 stays here, re-armed. It is now the sole remaining tripwire and
      # the requirement that will flip this scenario for real: it adds
      # POST /entities/query, the record-read route all six :gui steps need.
      #
      # ── 2026-09-11, AFTER REQ-311 LANDED: THIS TIER IS NOW EMPTY. ─────────
      #
      # REQ-311 was its last member, and it has been promoted to allowed_ids
      # above -- again on the strength of a completed re-derivation, never to
      # silence anything. So the honest question this round had to answer is
      # whether an empty tier still has a purpose, or whether it is dead code
      # dressed as a safety mechanism.
      #
      # ⛔ IT IS KEPT, EMPTY AND STILL ENFORCED, and that is a deliberate call
      # with a concrete reason -- not inertia.
      #
      # The tier's purpose was never "hold REQ-310 and REQ-311 specifically."
      # It is the mechanism by which a requirement that BUILDS this subsystem
      # can be admitted to the entity-title check WITHOUT its mere filing being
      # mistaken for its landing. That situation is not historical: S10's own
      # entity work is not finished (the query surface is one route of a larger
      # subsystem, and 0023's DDL-execution open question is still unanswered
      # and still gates further implementation requirements), so the NEXT such
      # requirement is a matter of when, not whether. Deleting the tier would
      # mean whoever files it has to reinvent this two-tier shape from scratch,
      # or -- far likelier, and the failure mode the ⛔ block above exists to
      # prevent -- drop the id straight into allowed_ids because that is the
      # path of least resistance and nothing structural argues otherwise.
      #
      # Kept empty, the tier costs one empty list and one `cond` arm that
      # currently never matches, and it keeps the correct procedure visible and
      # executable at the exact moment someone needs it. The `flunk` arm below
      # is what actually stops an unadmitted id either way, so an empty tier
      # weakens nothing.
      #
      # ⛔ WHAT TO DO WHEN YOU NEED THIS TIER AGAIN: add the id HERE, not to
      # allowed_ids, while it is still `status: pending`. The assertion below
      # then fires the moment it flips to done, handing the next agent these
      # instructions. Note the lag this mechanism has now demonstrated TWICE
      # (REQ-310, REQ-311): `status:` trails the code by one pipeline step, so
      # the status check is a BACKSTOP, never the primary detector. The primary
      # detectors are the code-derived signals below -- and Signal 5 in
      # particular, which is this round's new tripwire.
      # REQ-315..320 (S10 fifth batch, 2026-09-11): the IMPLEMENTATION
      # requirements for REQ-312/313/314's own designs (aggregation route,
      # attachments table+context+routes, export/import atoms+routes). Unlike
      # REQ-312/313/314 themselves, these are owner: ELIXIR-DEV and will land
      # real code -- REQ-317/319/320 each explicitly add new routes to
      # Letflow.Routers.Entities, which will invalidate whatever
      # "exactly ten routes" assertion currently holds elsewhere in this
      # file. This scenario's OWN disposition is unaffected regardless (the
      # moduledoc above already established the blocker moved entirely to
      # S8's :gui-dispatch stub, decoupled from lib/ entity work of any
      # kind) -- but a route-count assertion is a different signal than this
      # scenario's disposition, and per this tier's own purpose, landed code
      # gets re-derived here rather than silently waved into allowed_ids.
      # All six are `status: pending` at admission time.
      #
      # REQ-347 (S10 P5, filed 2026-09-14, owner FRONTEND-DEV) was admitted
      # HERE while `status: pending` -- filing builds nothing, so it was
      # armed rather than waved through. It has SINCE flipped to `status:
      # done` (2026-09-15), this tripwire fired exactly as armed, and the
      # re-derivation it demanded is complete: REQ-347 shipped a Playwright
      # spec port under web/tests/e2e/ that touches neither the route surface
      # (Signal 3''/3''') nor the harness (Signal 5), so it was promoted to
      # allowed_ids above with the full account of why. See that entry for
      # the re-derivation; it is no longer listed in this tier.
      #
      # REQ-355 (S10 P3, discovered here 2026-09-15 filed by a sibling
      # session, owner ELIXIR-DEV) was admitted HERE while `status: pending`:
      # "Certificate issuance: author the certificate entity definition and
      # the idempotent issue-on-first-request context module...". Its title
      # matches the word-bounded entity/entities check via "certificate
      # entity definition". It has SINCE flipped to `status: done`
      # (2026-09-15, merge commit 1fd89bb1), this tripwire fired exactly as
      # armed, and the re-derivation it demanded is complete: REQ-355 shipped
      # a context module and route under Letflow.Modules.Exam.Router that
      # touches neither the Letflow.Routers.Entities route surface (Signal
      # 3''/3''') nor the harness (Signal 5), so it was promoted to
      # allowed_ids above with the full account of why. See that entry for
      # the re-derivation; it is no longer listed in this tier.
      #
      # REQ-393/REQ-394 (filed 2026-09-20 by ORCH, from the GUI-review UAT
      # pass on the SISTER scenario -- the narrative UAT-RUNNER fixture at
      # test/fixtures/uat/scenarios/vortex/entity-list-filter-and-page.yaml,
      # NOT this test's own Letflow.Simulation.Runner fixture, but the exact
      # same underlying scenario concept -- see
      # test/uat-reports/gui-review-2026-09-20-entity-list-filter-and-page.md)
      # were admitted HERE while `status: pending`, per this tier's own rule:
      # filing builds nothing, so they were armed rather than waved through.
      #
      # REQ-393 (owner FRONTEND-DEV) built a generic filter/sort/page-size
      # entity-LIST SCREEN under `web/` -- a browser-rendered React
      # component, not anything under `lib/letflow/` or
      # `test/support/simulation/`. It flipped `status: done` on 2026-09-23
      # (PR #1754, merge commit ac751a7d) and this tripwire fired exactly as
      # armed. Re-derivation, confirmed rather than assumed: its diff touches
      # neither Signal 3''/3'''s route equality (it adds no HTTP route; it
      # consumes the existing `POST /entities/query`) nor Signal 5 (it has no
      # relationship whatsoever to `Letflow.Simulation.Runner`, which this
      # test's scenario runs against -- that module has no concept of `web/`
      # at all). It was promoted to allowed_ids above (DOC-UPDATER's own
      # WF02-REQ393-20260923 Step Final pass) with that account; it is no
      # longer listed in this tier.
      #
      # REQ-394 (owner ELIXIR-DEV, security-relevant) flipped `status: done`
      # on 2026-09-23 and this tripwire fired exactly as armed. The
      # re-derivation the prediction below called for is complete -- see the
      # moduledoc's "REQ-394 lands" section and the allowed_ids entry above --
      # and confirmed the prediction: it layers a per-entity-type
      # authorization CHECK onto the two EXISTING routes (`POST
      # /entities/query`, `GET /entities/definitions/active/:name`) without
      # adding, removing, or renaming any route, so Signal 3''/3''' stayed
      # untouched, and it has no relationship to `Letflow.Simulation.Runner`'s
      # `:gui ->` dispatch clause (runner.ex absent from its diff), so Signal 5
      # stayed untouched too. It was promoted to allowed_ids above with the
      # full re-derivation account; it is no longer listed in this tier.
      #
      # Both predictions were recorded here, not assumed permanently, per
      # this tier's own contract: the moment either flipped to `status: done`
      # this tripwire fires again and the disposition must be RE-DERIVED
      # LIVE against Signals 3''/3'''/5 as they then stand -- not waved into
      # allowed_ids on the strength of a comment alone. Both re-derivations
      # above are complete and neither id remains in this tier.
      pending_only_ids = [
        "REQ-315",
        "REQ-316",
        "REQ-317",
        "REQ-318",
        "REQ-319",
        "REQ-320"
      ]

      refute Enum.empty?(entity_title_matches),
             "Expected at least 1 title: match for word-bounded entity/entities (REQ-207's own), got none"

      matched_ids =
        Enum.map(entity_title_matches, fn {_line, idx} ->
          nearest_preceding_id_line(title_lines, idx - 1)
        end)

      Enum.each(matched_ids, fn preceding_line ->
        pending_only_id =
          Enum.find(pending_only_ids, &(preceding_line =~ "id: #{&1}"))

        cond do
          Enum.any?(allowed_ids, &(preceding_line =~ "id: #{&1}")) ->
            :ok

          pending_only_id != nil ->
            assert requirement_status(title_lines, pending_only_id) == "pending",
                   "#{pending_only_id} is allowed to carry an entity title ONLY while it is " <>
                     "status: pending -- filing it builds nothing, so the " <>
                     "BLOCKED_ON_DEPENDENCY disposition survives. Its status is now " <>
                     "#{inspect(requirement_status(title_lines, pending_only_id))}, which means " <>
                     "POST /entities/query -- the record-read route ALL SIX of this scenario's " <>
                     ":gui steps need (list, filter x2, sort, page, field redaction) -- HAS NOW " <>
                     "BEEN BUILT, and the one remaining reason this scenario is blocked is gone. " <>
                     "Do NOT silence this by moving #{pending_only_id} into allowed_ids -- that " <>
                     "would leave a green test asserting a route is missing when it is mounted " <>
                     "and serving, which is worse than no test. Re-derive the disposition " <>
                     "against Signals 3' and 4 as they then stand: Records/Query will expose a " <>
                     "read path and __authz_routes__/0 will carry a tenth {\"POST\", \"/query\", " <>
                     ":EntitiesQuery} entry. NOTE the remaining independent blocker documented " <>
                     "at Signal 4: Letflow.Simulation.Runner records EVERY :gui step as " <>
                     ":deferred_to_s8 and never dispatches one, so even a complete query route " <>
                     "does not by itself make these six steps execute -- that needs S8's " <>
                     "harness work. Judge whether the disposition becomes :executed or stays " <>
                     "blocked on the HARNESS rather than on the route, and say which in the " <>
                     "disposition_report. Route it through TEST-DESIGNER; see the ⛔ block above."

          true ->
            flunk(
              "Expected the line preceding each entity title: match to carry one of " <>
                "#{inspect(MapSet.to_list(allowed_ids))} (unconditional) or " <>
                "#{inspect(pending_only_ids)} (only while pending), got: #{inspect(preceding_line)}"
            )
        end
      end)

      # ── Signal 3' (MEANING RESTATED 2026-09-11, assertion unchanged) ──────
      #
      # History, so the restatement is legible. The ORIGINAL Signal 3 asserted
      # lib/letflow/entities.ex and lib/letflow/entity_query.ex do not exist;
      # REQ-310 made that a tautology (the subsystem shipped under the
      # lib/letflow/entities/ DIRECTORY and was never going to occupy those two
      # flat paths), so the previous round replaced it with this capability
      # check and read it as: "no context function can read a record, therefore
      # no route can serve one, therefore the scenario is blocked."
      #
      # ⛔ THAT INFERENCE IS NOW FALSE, AND THE ASSERTION IS STILL RIGHT.
      # REQ-311's POST /entities/query serves record reads without any read
      # function on Letflow.Entities.Records -- it composes
      # Query.{Types,Compiler,Allowlist,Cursor,FieldGrants} instead. So the
      # premise "no read function ⇒ no read path" is dead, while the fact it
      # tested is not merely still true but is now a DESIGN RULE the shipped
      # code depends on.
      #
      # This assertion is therefore KEPT, with its meaning inverted from
      # evidence-of-a-gap to evidence-of-correctness: Letflow.Entities.Records
      # is command-only BY DESIGN (its own moduledoc; Letflow.Routers.Entities'
      # "No route reads a record by id, and none lists records"; design §1),
      # and record reads belong exclusively to the query route. A later
      # list_records/2 or get_record/3 appearing here would mean that rule was
      # abandoned -- a second, competing read path alongside /entities/query,
      # bypassing the FieldGrants redaction both of that route's branches
      # enforce (INV-2). That is worth failing on for its own sake, entirely
      # apart from this scenario's disposition.
      #
      # Deleting it once its original inference expired would have discarded a
      # live invariant because the reason it was first written had changed.
      Code.ensure_loaded!(Letflow.Entities.Records)

      record_read_exports =
        Letflow.Entities.Records.__info__(:functions)
        |> Enum.filter(fn {name, _arity} ->
          name_string = Atom.to_string(name)

          String.starts_with?(name_string, "list_") or String.starts_with?(name_string, "get_") or
            String.starts_with?(name_string, "query_") or
            String.starts_with?(name_string, "fetch_")
        end)

      assert record_read_exports == [],
             "Letflow.Entities.Records is command-only by design (create/update/delete and " <>
               "NO read function) -- record reads belong exclusively to POST /entities/query " <>
               "(design req308-entity-http-surface.md:182), which REQ-311 built and which " <>
               "applies FieldGrants redaction on both of its branches (INV-2). A read " <>
               "function appearing here is a SECOND read path that bypasses that redaction, " <>
               "not merely a disposition change; observed: #{inspect(record_read_exports)}"

      # ── Signal 3'' (INVERTED 2026-09-11): TEN routes, INCLUDING POST /query.
      #
      # This is the assertion that fired and brought this whole re-derivation
      # about. It is still the sharpest one in the block, still structural
      # (against the router's own compiled __authz_routes__/0 table, never
      # textual), and it now proves the OPPOSITE of what it proved this
      # morning: that the record READ path is COMPLETE.
      #
      # The set is asserted by EQUALITY, not by membership, and that is the
      # load-bearing choice. Membership ("POST /query is present") would go
      # green for a tenth route and stay green for an eleventh, a twelfth, or a
      # silently-dropped ninth -- which is precisely how this test would have
      # drifted into certifying a stale route table. Equality means ANY change
      # to this router's surface, in either direction, lands back here for a
      # human-grade decision about what it means for this scenario.
      expected_routes =
        MapSet.new([
          {"POST", "/definitions", :EntitiesDefinitionsWrite},
          {"POST", "/definitions/:name/activate", :EntitiesDefinitionsWrite},
          {"GET", "/definitions", :EntitiesDefinitionsRead},
          {"GET", "/definitions/:id", :EntitiesDefinitionsRead},
          {"GET", "/definitions/active/:name", :EntitiesDefinitionsRead},
          {"GET", "/definitions/by-name/:name", :EntitiesDefinitionsRead},
          {"POST", "/records/:entity_type", :EntitiesRecordsWrite},
          {"PUT", "/records/:entity_type/:record_id", :EntitiesRecordsWrite},
          {"DELETE", "/records/:entity_type/:record_id", :EntitiesRecordsWrite},
          # REQ-311's tenth row -- the record read path. Its ARRIVAL is what
          # fired this tripwire; its DEPARTURE would now fire it too.
          {"POST", "/query", :EntitiesQuery},
          # REQ-315's eleventh row (2026-09-12) -- the aggregation/reporting
          # route, a DIFFERENT read shape gated by the DISTINCT
          # :EntitiesAggregate permission. Re-derived (moduledoc above) and
          # found to close no gap this scenario's six :gui steps were
          # waiting on -- none of them aggregates anything, all six read
          # through POST /entities/query above. Included here so this
          # equality assertion reflects the router's real, live surface;
          # its DEPARTURE would fire this tripwire same as any other row's.
          {"POST", "/query/aggregate", :EntitiesAggregate},
          # REQ-317's twelfth through fifteenth rows (2026-09-12) -- the
          # record-attachment lifecycle routes, gated by the two DISTINCT
          # :EntitiesAttachmentsManage/:EntitiesAttachmentsRead permissions.
          # Re-derived (moduledoc above) and found to close no gap this
          # scenario's six :gui steps were waiting on -- none of them
          # uploads, lists, downloads, or deletes a record's attachment;
          # all six read a record's field_values through POST
          # /entities/query above. Included here so this equality assertion
          # reflects the router's real, live surface; their DEPARTURE would
          # fire this tripwire same as any other row's.
          {"POST", "/records/:entity_type/:record_id/attachments", :EntitiesAttachmentsManage},
          {"GET", "/records/:entity_type/:record_id/attachments", :EntitiesAttachmentsRead},
          {"GET", "/records/:entity_type/:record_id/attachments/:attachment_id",
           :EntitiesAttachmentsRead},
          {"DELETE", "/records/:entity_type/:record_id/attachments/:attachment_id",
           :EntitiesAttachmentsManage},
          # REQ-319's sixteenth row (2026-09-12) -- the bulk record export
          # route, gated by the two-tier :EntitiesRecordsExport /
          # :EntitiesRecordsExportUnredacted mechanism (its own 15-test
          # coverage). Re-derived same as REQ-315 was, and it closes no gap
          # this scenario's six :gui steps were waiting on either: none of
          # them exports anything, all six still read through
          # POST /entities/query above. Included here so this equality
          # assertion reflects the router's real, live surface; its
          # DEPARTURE would fire this tripwire same as any other row's.
          {"POST", "/records/:entity_type/export", :EntitiesRecordsExport},
          # REQ-320's seventeenth row (2026-09-12, landed concurrently with
          # REQ-319 above) -- the per-record-type batch IMPORT route, gated
          # by its own DISTINCT :EntitiesRecordsImport permission (not
          # :EntitiesRecordsWrite). Re-derived (moduledoc above) and found to
          # close no gap this scenario's six :gui steps were waiting on --
          # none of them import anything; all six read a record's
          # field_values through POST /entities/query above. Included here
          # so this equality assertion reflects the router's real, live
          # surface; its DEPARTURE would fire this tripwire same as any
          # other row's.
          {"POST", "/records/:entity_type/import", :EntitiesRecordsImport},
          # ISS-0935's eighteenth row (2026-10-01) -- a one-time, seed-time
          # admin route for bulk-loading field-level restriction rules,
          # gated by its own DISTINCT :EntitiesRestrictionsManage permission
          # (not :EntitiesRecordsWrite or :EntitiesRecordsImport). Re-derived
          # (moduledoc above) and found to close no gap this scenario's six
          # :gui steps were waiting on -- none of them imports or manages a
          # restriction; all six still read through POST /entities/query
          # above. Included here so this equality assertion reflects the
          # router's real, live surface; its DEPARTURE would fire this
          # tripwire same as any other row's.
          {"POST", "/restrictions/import", :EntitiesRestrictionsManage},
          # REQ-516 S2's nineteenth row (GH #2701) -- the record history read, gated by
          # :EntitiesQuery. It closes none of this scenario's six :gui gaps: the steps read
          # records through POST /entities/query, and none of them reads history. Its
          # field_values pass through FieldPolicy.redact_event_payload_with_sets/3.
          {"GET", "/records/:entity_type/:record_id/history", :EntitiesQuery}
        ])

      actual_routes = MapSet.new(Letflow.Routers.Entities.__authz_routes__())

      assert MapSet.equal?(actual_routes, expected_routes),
             "Letflow.Routers.Entities must serve exactly REQ-310's nine routes plus " <>
               "REQ-311's POST /query, REQ-315's POST /query/aggregate, REQ-317's four " <>
               "record-attachment routes, REQ-319's POST /records/:entity_type/export, " <>
               "REQ-320's POST /records/:entity_type/import, and ISS-0935's " <>
               "POST /restrictions/import. " <>
               "Unexpected: #{inspect(MapSet.to_list(MapSet.difference(actual_routes, expected_routes)))}; " <>
               "missing: #{inspect(MapSet.to_list(MapSet.difference(expected_routes, actual_routes)))}. " <>
               "A NINETEENTH route, or a MISSING one, means this router's surface changed " <>
               "again and this scenario's disposition must be re-derived once more -- " <>
               "see the banner at the top of this test. In particular, {\"POST\", \"/query\", " <>
               ":EntitiesQuery} going MISSING would mean the record read path was reverted, " <>
               "which would move the blocker back to S10 from S8."

      assert MapSet.size(actual_routes) == 19

      # POSITIVE now, where the previous round refuted it. The record read
      # route exists, and it carries the read permission REQ-309 minted for it.
      assert {"POST", "/query", :EntitiesQuery} in actual_routes,
             "POST /entities/query MUST exist and MUST be gated by :EntitiesQuery -- it is " <>
               "REQ-311's route and the single HTTP surface all six of this scenario's :gui " <>
               "steps (list, filter x2, sort, page, field redaction) read records through. " <>
               "Its absence would move this scenario's blocker back to the missing route"

      # UNCHANGED from the previous round, and still a refute: the query route
      # being the read path is exactly why no GET may appear under /records
      # FOR THE RECORD ITSELF. This is design §1's rule, not a statement
      # about what is unbuilt. REQ-317 legitimately added two GET routes
      # under /records/..., but both are the record's ATTACHMENT
      # sub-resource (/records/:entity_type/:record_id/attachments...), not
      # the record's own field_values -- excluded here so this assertion
      # still proves what it always proved.
      # REQ-516 S2 adds the record HISTORY GET, excluded by its exact path: its field_values
      # pass through FieldPolicy.redact_event_payload_with_sets/3 (H1 proves it), so it is
      # not a redaction bypass. Any other GET under /records still fails this refute.
      refute Enum.any?(actual_routes, fn {method, path, _perm} ->
               method == "GET" and String.starts_with?(path, "/records") and
                 not String.contains?(path, "attachments") and
                 path != "/records/:entity_type/:record_id/history"
             end),
             "No GET route may exist under /records for the record itself (REQ-516 S2's history " <>
               "route excepted) -- record reads are POST /entities/query only (design §1). A GET " <>
               "here would be a second read path bypassing the query route's FieldGrants redaction"

      # ── Signal 3''' (INVERTED 2026-09-11): the permission is CONSUMED. ────
      #
      # The previous round asserted the policy key existed while refuting that
      # any route carried it -- the signature of "specified but unserved," the
      # precise state REQ-311 was filed to end. It has ended. Both halves are
      # now asserted POSITIVELY: the key resolves, AND a real route carries it.
      #
      # Kept as its own signal rather than folded into Signal 3'' because it
      # checks a DIFFERENT module: Letflow.Api.Authorization's routing table
      # must agree with the router's own. The two are maintained separately and
      # can disagree -- a route gated by a policy key the authorization module
      # resolves differently (or as :Unknown) is a real and silent failure mode.
      assert Letflow.Api.Authorization.endpoint_policy_key("POST", "/entities/query") ==
               :EntitiesQuery,
             "Letflow.Api.Authorization must resolve POST /entities/query to :EntitiesQuery " <>
               "-- REQ-309 minted that key and REQ-311's route now consumes it. A mismatch " <>
               "here means the router and the authorization table disagree about how this " <>
               "route is gated"

      assert Enum.any?(actual_routes, fn {_method, _path, perm} -> perm == :EntitiesQuery end),
             ":EntitiesQuery must now be CONSUMED by a real route -- REQ-309 minted it as " <>
               "vocabulary ahead of REQ-311's route, and REQ-311 landed. A permission with " <>
               "no route behind it is the signature of a surface that is specified but " <>
               "unserved, which is the state this scenario was previously blocked on"

      # ── Signal 4: the scenario's six steps are all :gui record reads. ─────
      #
      # Introduced by the previous round as supporting context for the harness
      # blocker; now it is the SETUP for Signal 5, which carries the
      # disposition. Pinning the fixture's own shape matters because the whole
      # harness argument below is conditional on every step being :gui -- if a
      # future edit converted these six to :api steps, Signal 5's premise would
      # be gone and this test must not quietly keep asserting it.
      scenario =
        ScenarioFixture.load!(Path.join(@scenarios_dir, "entity-list-filter-and-page.yaml"))

      assert scenario.id == "vortex-entity-list-filter-and-page"
      assert length(scenario.steps) == 6

      assert Enum.all?(scenario.steps, &(&1.via == :gui)),
             "All six steps must be via: :gui -- Signal 5's whole argument is about how the " <>
               "harness treats :gui steps. Observed: " <>
               inspect(Enum.map(scenario.steps, & &1.via))

      # ══ Signal 5: THE NEW TRIPWIRE -- the harness dispatches no :gui step. ══
      #
      # ⛔ THIS IS THE ASSERTION THAT NOW CARRIES THE DISPOSITION, and the one
      # armed to fire when S8 makes :gui steps executable. Read the next three
      # paragraphs before touching it.
      #
      # THE BLOCKER. Letflow.Simulation.Runner.run_steps/1
      # (test/support/simulation/runner.ex) reduces over the scenario's steps
      # with `case step.via do`, and its `:gui ->` clause is a bare pattern
      # match -- no guard, no condition, no feature flag. It builds
      # `outcome: :deferred_to_s8` and returns, never reaching
      # dispatch_api_step/4. Every :gui step, in every scenario, unconditionally.
      # So even though POST /entities/query is now built, mounted and serving,
      # these six steps STILL do not execute: the harness will not make the
      # calls. That is S8's frontend-cutover work, a different owner and a
      # different stage from the S10 route work that just completed.
      #
      # WHY THIS ASSERTS ON OBSERVED BEHAVIOUR, NOT ON runner.ex's SOURCE TEXT.
      # The tempting version is `File.read!("runner.ex") =~ ":deferred_to_s8"`,
      # matching how Signals 1'/1'' read api_pipeline.ex and router.ex. It was
      # deliberately NOT written that way, for two reasons:
      #
      #   (a) BRITTLE IN THE WRONG DIRECTION -- it fires on edits that change
      #       nothing. A reformat, a renamed variable, a moved clause, a
      #       reworded detail string would all trip a text match while the
      #       harness behaves identically. A tripwire that cries wolf gets
      #       disarmed by the third person who hits it.
      #   (b) BLIND IN THE WRONG DIRECTION -- and this is the worse half. The
      #       text `:deferred_to_s8` would STILL APPEAR in runner.ex after S8
      #       makes GUI steps executable, because the natural shape of that
      #       change is a CONDITIONAL: dispatch when a GUI driver is available,
      #       fall back to :deferred_to_s8 when it is not. The literal would
      #       survive, the text assertion would stay green, and the exact
      #       transition this tripwire exists to catch would pass unnoticed.
      #
      # Asserting on what Runner.run/1 ACTUALLY DID to THIS scenario's steps
      # inverts both properties: it is silent through any refactor that
      # preserves behaviour, and it fires on any change that makes even ONE of
      # these six steps execute -- however that change is implemented, whether
      # by deleting the clause, guarding it, flagging it, or routing :gui
      # through a new driver. It tests the capability, not the spelling.
      #
      # SCOPE OF THE CLAIM. This asserts the harness defers THESE SIX STEPS, in
      # THIS scenario -- the steps whose deferral is the actual reason for the
      # disposition below. It deliberately does not assert a global property of
      # every :gui step everywhere; that would be a test of runner.ex belonging
      # in runner.ex's own test, not a re-derivation of this scenario's
      # disposition.
      assert {:ok, run_report} = Runner.run(scenario)

      assert length(run_report.step_results) == 6

      gui_outcomes = Enum.map(run_report.step_results, & &1.outcome)

      assert Enum.all?(gui_outcomes, &(&1 == :deferred_to_s8)),
             "⛔ TRIPWIRE (Signal 5). Every one of this scenario's six :gui steps must come " <>
               "back :deferred_to_s8. Observed: #{inspect(gui_outcomes)}.\n\n" <>
               "If a step now reports :ok, THE HARNESS HAS LEARNED TO DISPATCH :gui STEPS " <>
               "-- S8's frontend cutover has landed, and this scenario's " <>
               "BLOCKED_ON_DEPENDENCY disposition is FACTUALLY WRONG. The record read path " <>
               "(POST /entities/query) has been complete since REQ-311, so the harness was " <>
               "the LAST remaining blocker: with it cleared, this scenario should EXECUTE.\n\n" <>
               "DO NOT weaken, allowlist or delete this assertion to make it pass. Re-derive " <>
               "the disposition: run the six steps for real against POST /entities/query, " <>
               "assert their results and the EO-001 field-redaction outcome, and replace the " <>
               "disposition_report below with :executed. Route it through TEST-DESIGNER; see " <>
               "the banner at the top of this test for the full history of the two previous " <>
               "re-derivations and why each replaced its assertions rather than silencing them."

      # The complementary half, stated separately so the failure message says
      # which direction broke: nothing was dispatched, so nothing was really
      # exercised, so the disposition below is not contradicted by run/1 having
      # returned {:ok, report}.
      refute Enum.any?(run_report.step_results, &(&1.outcome == :ok)),
             "⛔ TRIPWIRE (Signal 5). No :gui step may report :ok -- the harness dispatches " <>
               "none of them. A single :ok means S8 GUI-step dispatch is live and this " <>
               "scenario must be re-derived to :executed; see the assertion above."

      # And the steps must still be deferred for the HARNESS' reason, not
      # because something upstream failed: an :error outcome here would mean a
      # different failure wearing the same disposition.
      refute Enum.any?(run_report.step_results, &(&1.outcome == :error)),
             "No :gui step may report :error -- these steps are not dispatched at all, so " <>
               "there is nothing that could fail. An :error means the harness DID attempt " <>
               "something, which contradicts the unconditional-deferral premise this " <>
               "scenario's whole disposition rests on"

      # ── Disposition (RE-DERIVED 2026-09-11, second time that day) ────────
      #
      # Still BLOCKED_ON_DEPENDENCY -- but the blocker has moved OUT of lib/
      # entirely. Every HTTP surface these six steps need now exists and
      # serves. What is missing is the test harness' ability to drive a :gui
      # step at all, which is S8's frontend-cutover scope, not S10's.
      #
      # ⛔ THE OWNER CHANGED, AND THAT IS THE HEADLINE. The previous two
      # dispositions were both blocked on S10 backend work (first the whole
      # entity HTTP surface, then the record query route). This one is blocked
      # on S8. Anyone scanning for "what does S10 still owe this scenario"
      # should read: nothing.
      disposition_report = %{
        scenario_id: "vortex-entity-list-filter-and-page",
        disposition: :blocked_on_dependency,
        missing_subsystem:
          "S8 simulation-harness GUI-step dispatch -- Letflow.Simulation.Runner.run_steps/1 " <>
            "(test/support/simulation/runner.ex) defers EVERY :gui step unconditionally and " <>
            "dispatches none. NOT the entity HTTP surface, which REQ-310 landed and mounted, " <>
            "and NOT the record read route, which REQ-311 completed -- both on 2026-09-11. " <>
            "Nothing under lib/ blocks this scenario any longer.",
        evidence: [
          "Letflow.Routers.Entities.__authz_routes__/0 returns exactly 11 routes: 6 definition CRUD + 3 record WRITES + REQ-311's {\"POST\", \"/query\", :EntitiesQuery} + REQ-315's {\"POST\", \"/query/aggregate\", :EntitiesAggregate}. The record READ path is COMPLETE, and REQ-315's aggregate route (re-derived 2026-09-12) reads nothing this scenario's six steps need -- asserted by set EQUALITY above, so a route added or dropped in either direction re-fires this re-derivation",
          "POST /entities/query is a real composing handler (Types -> Compiler -> Allowlist -> Cursor -> FieldGrants, with both the plain and the join-bearing redaction branches), not a stub -- it is the single surface all six of this scenario's :gui steps (list, filter x2, sort, page, field redaction) would read records through",
          "Letflow.Api.Authorization.endpoint_policy_key(\"POST\", \"/entities/query\") == :EntitiesQuery AND a real route now carries that permission -- the 'specified but unserved' state the previous disposition rested on has ENDED (REQ-309 minted the vocabulary; REQ-311's route consumes it)",
          "lib/letflow/plugs/api_pipeline.ex: forward(\"/entities\", to: Letflow.Routers.Entities) IS mounted (REQ-310 point 5) -- the 2026-09-09 'no HTTP surface' evidence line has been false since REQ-310 and is retained only as history",
          "lib/letflow/router.ex: both deferred-routes rows RETIRED outright (REQ-310 point 7) -- likewise no longer evidence of anything missing",
          "Letflow.Entities.Records still exports no list_/get_/query_/fetch_ function -- and this is now CORRECTNESS, not a gap: it is command-only by design (design §1) because reads belong exclusively to the query route, where FieldGrants redaction is enforced on both branches (INV-2). A read function here would be a second read path bypassing that redaction",
          "THE SOLE REMAINING BLOCKER: Letflow.Simulation.Runner.run_steps/1 matches a bare `:gui ->` clause with no guard or condition, records :deferred_to_s8 and never reaches dispatch_api_step/4. Asserted LIVE above (Signal 5) against the real Runner.run/1 result for this scenario's own six steps -- all 6 came back :deferred_to_s8, none :ok, none :error. runner.ex is unmodified in the working tree and absent from this branch's diff",
          "test/fixtures/simulation/vortex/scenarios/entity-list-filter-and-page.yaml: all six steps are `via: gui` (asserted above), which is what makes the harness' unconditional :gui deferral dispositive for this scenario specifically",
          "docs/requirements.yaml: every word-bounded entity/entities title: traces to REQ-207's own, REQ-225..231 (ISS-0438 scoping), REQ-295..302 (decision 0023 storage), REQ-304 (solution-pack delivery), REQ-308 (design artefact), REQ-309 (permission vocabulary only), REQ-310 (the nine routes) or REQ-311 (the tenth, the query route) -- the last two triaged by the two re-derivations of 2026-09-11 and promoted to the unconditional list only as those triages' output"
        ],
        # NOT a requirement id this time, and that is the substantive change.
        # The two previous dispositions each named a filed, queued S10
        # requirement (REQ-310, then REQ-311). This one names a STAGE's
        # capability: S8 must make the simulation harness able to drive a :gui
        # step. No requirement is filed for it at the time of writing, and the
        # honest report says so rather than inventing an id.
        flips_when: "S8 simulation-harness GUI-step dispatch (runner.ex run_steps/1)",
        # Deliberately nil, not a placeholder id: with the harness cleared,
        # nothing else is known to stand between this scenario and execution --
        # every route it needs is live. If that turns out to be wrong, the
        # re-derivation that discovers it should say so here rather than
        # inheriting a guess made today.
        then_gated_on: nil,
        blocker_owner: :s8_frontend_cutover,
        previous_blocker_owner: :s10_entity_http_surface,
        steps_executed: 0,
        steps_deferred: 6
      }

      assert disposition_report.disposition == :blocked_on_dependency
      assert disposition_report.blocker_owner == :s8_frontend_cutover

      assert disposition_report.flips_when ==
               "S8 simulation-harness GUI-step dispatch (runner.ex run_steps/1)"

      assert disposition_report.steps_executed == 0
      assert disposition_report.steps_deferred == length(run_report.step_results)

      # The disposition_report must agree with what Signal 5 actually observed
      # -- a hand-written report that drifted from the live run would be the
      # exact "certifying a stale fact" failure this whole block exists to
      # prevent. steps_deferred is checked against the real result above; this
      # checks the complementary count, so the two cannot both be wrong in the
      # same direction.
      assert disposition_report.steps_executed ==
               Enum.count(run_report.step_results, &(&1.outcome == :ok))
    end
  end
end
