defmodule Letflow.Simulation.Req208MeridianTest do
  @moduledoc """
  REQ-208 acceptance criteria: 3 Meridian scenario YAMLs run through
  `Letflow.Simulation.Runner`.

  ## FIXED by ISS-0397 (2026-09-01) -- formerly a CRITICAL FINDING blocking full
  AC1/AC2 verification; superseding note added rather than deleting the
  original finding, per this project's discipline of not silently erasing a
  documented defect's own history

  `Letflow.Engine.complete_task/3`'s real, per-call state-rebuild
  (`lib/letflow/engine.ex`'s `build_instance_state/3`) used to hardcode
  `join_counters: %{}` on EVERY call, confirmed reproduced against a real
  running instance in the session that wrote this test (`Letflow.Engine.create/2`
  for the initial split, then a SEPARATE `Letflow.Engine.complete_task/3` call
  for the first branch's own completion -- real HTTP 500,
  `{:error, {:activation_failed, {:unknown_branch_id, _}}}` internally). A
  `PARALLEL_GATEWAY` join could therefore only ever fire within the SAME
  hop-chain call as its own split. **ISS-0397**
  (`lib/letflow/design/iss0397-join-counters-fix.md`) fixed this by adding a
  durable `instance_projections.join_counters` column, read/written under the
  same `FOR UPDATE` lock `complete_task/3`/`advance_after_timer_fired/3` already
  hold on that row -- a join cohort opened by one call is now durably readable
  (and closeable) by a later, separate call. The two tests below were updated
  accordingly (see each `describe` block's own comments) to assert the now-real,
  now-successful second-call behavior instead of the pre-fix HTTP 500 -- they no
  longer reproduce a defect, they lock in its fix.

  **Still NOT fully verified by this file's ORIGINAL two describe blocks below
  (unchanged since REQ-208, kept for their own historical/ISS-0397-fix-locking
  value, not rewritten):** AC1/AC2's own fuller claims (full quorum across all
  3 branches through to disbursement, EO-002's negative assertion) remain out
  of reach of a real end-to-end run there -- `disburse-loan`/
  `credit-committee-vote`/`l1-approval` sit behind `SERVICE_TASK` nodes this
  engine did not yet dispatch at the time those two describe blocks were
  written (§0.8/§3 below, a platform-wide gap REQ-206/207 already found,
  unrelated to ISS-0397).

  ## REQ-433 (2026-10-02) -- the "meridian-loan-origination-above-threshold"
  describe block IS rewritten, over this file's own prior "not rewritten"
  note above -- and surfaces a NEW, previously-undiscovered engine defect
  `lib/letflow/design/req433-committee-quorum.md`'s own §4.2 "Required
  follow-on" flagged this test module by name: the old single-HUMAN_TASK
  `credit-committee-vote`/`committee_outcome` shape is gone from both real
  fixtures and from `@simple_loan_origination_graph` below, replaced by a
  real 2-of-3 quorum subgraph (`committee-vote-fork`/
  `committee-vote-{cro,director,ceo}`/`committee-vote-join`/
  `committee-tally`). The extended
  `test/fixtures/simulation/meridian/scenarios/loan-origination-above-
  threshold.yaml` now carries 9 real steps (through the remaining assessment
  branch, both gateways, and all three committee votes) instead of 3.

  **All 9 steps are now real and pass.** 2 of 3 committee votes complete for
  real (steps 6/7), reaching 2-of-3 quorum at the variable level (the join
  has not fired yet -- one branch still outstanding). Step 8 (the 3rd,
  join-firing vote) used to reproduce a genuine, newly-discovered engine
  limitation: a `PARALLEL_GATEWAY` join whose own downstream edge leads
  directly to a `SERVICE_TASK`, when that join fires within the same hop
  chain as the triggering task completion, could not create that
  `SERVICE_TASK`'s dispatch row (`build_complete_task_tail_multi/6`'s
  identity-`id_map` assumption for `prepared_service_task_dispatches` did
  not hold for a hop-chain-local, join-minted token). That finding was filed
  as **ISS-0974** and is now **FIXED** (merged to `main` at `a53858e0`,
  `lib/letflow/design/iss0974-join-dispatch-id-map-fix.md`) -- the real
  hop-chain `id_map` is now threaded into the timer-arm/service-task-dispatch
  `Multi.merge` siblings, so a join-minted continuation token resolves to a
  real, persisted id. Step 8's own assertion (below) is flipped accordingly,
  over this moduledoc's own prior note, to lock in the fix rather than keep
  documenting the now-closed defect (same "a later fix flips the assertion
  that used to document the bug" discipline this file's own ISS-0397 section
  above already established): the join fires, `committee-tally` structurally
  tallies 2-of-3 approve, and the token parks for real at `create-facility`
  (a real, pending `service_task_dispatches` row) -- REQ-433's AC4 is closed
  by this describe block for the test-local graph's own honest stopping
  point (create-facility, per REQ-215's own no-auto-traversal precedent and
  this requirement's own design §4.2 call); AC4's "reaches `end-disbursed`"
  text names the separate real UAT scenario (design §4.1) against
  `process_claim_intake.yaml`, not this Runner-driven test-local-graph
  describe block. The "meridian-loan-origination-below-threshold" describe
  block is NOT touched -- that scenario never reaches the committee branch
  at all.

  ## CLOSED by REQ-215 (2026-09-03) -- the SERVICE_TASK dispatch gap itself

  `Letflow.Engine.Transition.dispatch_node/4` now has a real `:SERVICE_TASK`
  clause (`lib/letflow/design/req215-service-task-engine-wiring.md`); REQ-214
  built the dispatch-core poller this requirement's re-entry function
  (`Letflow.Engine.advance_after_service_task_outcome/4`) hands a resolved
  outcome to. **REQ-215's own AC2 is exactly this file's own long-standing
  gap:** "`req208_meridian_test.exs`'s committee-vote/quorum-2-of-3/
  disbursement paths (previously unreached) are reached and pass end to
  end." The new `"meridian-loan-origination-above-threshold, full committee-
  vote quorum through disbursement (REQ-215 AC2)"` describe block below
  closes it -- a THIRD describe block, added rather than rewriting the first
  two (which independently lock in ISS-0397's own fix and stay valid,
  unchanged, on their own narrower claim). It exercises the real
  `credit-committee-vote` (HUMAN_TASK) -> `create-facility` (a REAL
  `SERVICE_TASK` node now, not elided) -> `disburse-loan` (HUMAN_TASK) path,
  driven via direct `Letflow.Engine`/`Letflow.Tasks` API calls (not
  `Runner.run/1` against the existing scenario YAMLs, which have no step
  primitive for "resolve a pending SERVICE_TASK dispatch" and were never
  updated past the point they originally truncated at -- extending the YAML
  format itself is out of REQ-215's own scope). `attempt_dispatch/2` +
  `advance_after_service_task_outcome/4` are called directly rather than via
  `ServiceTaskDispatcher.poll_and_dispatch/1`, since `poll_and_dispatch/1`
  currently crashes on a genuine `:advance` outcome -- see
  `test/letflow/engine/service_task_wiring_test.exs`'s own "DEFECT" describe
  block for the full report; not re-derived here, just avoided the same way
  that file's own working tests avoid it.

  ## SERVICE_TASK limitation (design §0.8/§3, same platform-wide gap REQ-206/207
  already found) -- applies ONLY to the original two describe blocks below,
  NOT to the new third one (which restores a real SERVICE_TASK node, above)
  `Letflow.Engine` did not yet dispatch SERVICE_TASK nodes as of REQ-208. The
  real `process_claim_intake.yaml`/`process_policy_binding.yaml` fixtures have
  SERVICE_TASKs on their critical paths. Test-local simplified process graphs
  (`@simple_loan_origination_graph`, `@simple_regulatory_review_graph`) replace
  them with direct edges/END nodes, mirroring REQ-206/207's own precedent
  exactly -- unchanged, since rewriting those two would lose their own
  historical ISS-0397-fix-locking value.

  ## Token roles are a separate namespace from process `attributes.role` strings
  (design §0.7, re-confirmed this session)
  `HUMAN_TASK` node `attributes.role` values (e.g. `"role-credit-manager"`,
  `"role-committee-member"`) are engine-internal `assignee_ref` strings, never
  a token permission -- `Identity.create_token/3` (`lib/letflow/identity.ex`)
  accepts ONLY `Authorization.roles/0`'s 5 literal values
  (PLATFORM_ADMIN/PROCESS_DESIGNER/PROCESS_OPERATOR/TASK_WORKER/AGENT_RUNNER),
  confirmed empirically this session (`{:error, :invalid_role_set}` on a
  `role-*` string). Every actor below is granted `PROCESS_OPERATOR`
  (matching REQ-206/207's own precedent) -- per §0.7, claim is not required
  before complete.

  (ISS-0942 update: the sentence this note used to end on --
  "`:TasksComplete` unconditionally allows any `PROCESS_OPERATOR`-permissioned
  actor to complete any task regardless of its `assignee_ref`" -- was the
  exact gap ISS-0942 closed (this fixture's own `role-*` HUMAN_TASK
  attributes were the live-UAT-exploited case, meridian/regulatory-
  compliance-review-bafin). `POST /tasks/:id/complete` now additionally
  enforces `Tasks.authorize_completion/3` ahead of
  `Engine.complete_task/3` -- a `PROCESS_OPERATOR` token alone is no longer
  sufficient; the calling user must also actually hold/belong to the
  task's `USER`/`GROUP`/`ROLE` assignee. This is why the setup below now
  also seeds each `org_structure.yaml` department as a real group and binds
  the `role-*` names this fixture's HUMAN_TASK nodes use to the department
  whose member actually drives that step.)

  ## REQ-199 status at execution time (AC4)
  `docs/requirements.yaml` REQ-199 entry: `status: done`, stage S6 (re-confirmed
  this session, design §0.5). Material caveat stated regardless: `Runner.run_steps/1`
  dispatches every `:api` step sequentially -- this run does not itself generate
  genuinely concurrent out-of-band completions and therefore does not
  independently re-exercise REQ-199's ORD-01/02/03 guards under real concurrent
  load. It exercises only that the parallel-fork/join graph SHAPE transitions
  correctly under one-at-a-time completions (a real, valuable engine-instance-shape
  test, not the same claim as "no lost update under concurrent completions"). See
  design §0.5/§7 -- a follow-up issue recommendation is reported via
  `result.issues` at handoff time (checked against ISS-0388..0393 first, per
  the requirement's own instruction; not a duplicate).

  Real Postgres, `async: false` -- tenant provisioning needs `Sandbox.mode(:auto)`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.ServiceTaskDispatcher
  alias Letflow.Engine.ServiceTaskDispatcher.ServiceTaskDispatch
  alias Letflow.Identity
  alias Letflow.Identity.OnboardingRecord
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.Tenant
  alias Letflow.Instances
  alias Letflow.Repo
  alias Letflow.Simulation.Runner
  alias Letflow.Simulation.ScenarioFixture
  alias Letflow.Simulation.Seed
  alias Letflow.Tasks
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @fixtures_dir Path.expand("../../fixtures/simulation/meridian", __DIR__)
  @scenarios_dir Path.join(@fixtures_dir, "scenarios")

  # ── §3.1: @simple_loan_origination_graph ──────────────────────────────────
  # Derived from process_claim_intake.yaml (design §0.2), SERVICE_TASK nodes
  # elided/replaced: credit-memo-timeout/risk-assessment-timeout/kyc-timeout
  # (on_timeout fallbacks) elided entirely; l2-approval's approve branch
  # replaced by a direct edge straight to disburse-loan; decline-application
  # replaced by a direct edge to end-declined. Every HUMAN_TASK/
  # EXCLUSIVE_GATEWAY/PARALLEL_GATEWAY node and every condition string on the
  # real, exercised path kept verbatim -- EXCEPT the KYC/AML branch, per the
  # ELIXIR-DEV finding below.
  #
  # REQ-433 update: the old single-HUMAN_TASK `credit-committee-vote`/
  # `committee_outcome` shape is replaced by the real 2-of-3 quorum subgraph
  # (`committee-vote-fork`/`committee-vote-{cro,director,ceo}`/
  # `committee-vote-join`/`committee-tally`), mirroring
  # lib/letflow/design/req433-committee-quorum.md §2 exactly (minus the
  # per-voter timeout SERVICE_TASK siblings, elided consistent with this
  # graph's own convention). `create-facility` is the one exception to this
  # graph's SERVICE_TASK elision: it is kept real so the committee-tally
  # approve path (`e39`) parks there for real, matching
  # @loan_origination_graph_with_service_task's own already-proven shape.
  #
  # ELIXIR-DEV finding, over the design's own §3.1 plan (design proposed
  # replacing kyc-aml-check with a direct edge from parallel-assessment-fork
  # to kyc-routing, an EXCLUSIVE_GATEWAY, keeping kyc-routing/kyc-manual-review
  # real): empirically, this does not activate. `Letflow.Engine.create/2`
  # returns `{:error, {:activation_failed, {:no_matching_join_found,
  # "parallel-assessment-fork"}}}` -- confirmed this session by direct
  # reproduction against a real running instance. Reading
  # `lib/letflow/engine/transition.ex`'s `find_matching_join/2` and
  # `walk_to_gateway/3` (REQ-051's own fork/join implementation) shows every
  # fork branch must be a chain of SINGLE-outgoing-edge nodes until it reaches
  # the PARALLEL_GATEWAY join -- a node with more than one outgoing edge
  # (kyc-routing, an EXCLUSIVE_GATEWAY with 3 outgoing edges) makes
  # `walk_to_gateway/3` return `:error` before ever reaching assessment-join,
  # which fails the WHOLE split (not just that branch) at instance-creation
  # time. This is a genuine, previously-undocumented Engine limitation --
  # distinct from the SERVICE_TASK-not-dispatched gap REQ-206/207/208's design
  # docs already record -- reported via `result.issues` at handoff time (new
  # finding, checked against ISS-0388..0393 first; not a duplicate).
  #
  # Resolution here: the KYC/AML branch is a single, unconditioned, immediate
  # edge from parallel-assessment-fork straight to assessment-join (no
  # kyc-routing/kyc-manual-review nodes in this simplified graph at all) --
  # both scenarios' own `kyc_status: "clear"` value would have taken
  # kyc-routing's own `== 'clear'` edge straight to assessment-join anyway
  # (design §3.1's own edge table), so no scenario-observable behavior is
  # lost; only the (never-exercised-by-either-scenario, per design §3.1's own
  # table) kyc-manual-review branch is now structurally absent rather than
  # present-but-unreached. `kyc_status` is dropped from both scenarios'
  # `initial_variables` accordingly (it would be inert dead data otherwise).
  @simple_loan_origination_graph %{
    "nodes" => [
      %{"id" => "start", "node_type" => "START"},
      %{"id" => "parallel-assessment-fork", "node_type" => "PARALLEL_GATEWAY"},
      %{
        "id" => "credit-memo-review",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-credit-manager"}
      },
      %{
        "id" => "risk-assessment",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-risk-manager"}
      },
      %{"id" => "assessment-join", "node_type" => "PARALLEL_GATEWAY"},
      %{"id" => "eligibility-gate", "node_type" => "EXCLUSIVE_GATEWAY"},
      %{"id" => "authority-routing", "node_type" => "EXCLUSIVE_GATEWAY"},
      %{
        "id" => "l1-approval",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-credit-manager"}
      },
      %{
        "id" => "l2-approval",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-credit-director"}
      },
      %{"id" => "committee-vote-fork", "node_type" => "PARALLEL_GATEWAY"},
      %{
        "id" => "committee-vote-cro",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-committee-member"}
      },
      %{
        "id" => "committee-vote-director",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-committee-member"}
      },
      %{
        "id" => "committee-vote-ceo",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-committee-member"}
      },
      %{"id" => "committee-vote-join", "node_type" => "PARALLEL_GATEWAY"},
      %{"id" => "committee-tally", "node_type" => "EXCLUSIVE_GATEWAY"},
      # Unlike every other SERVICE_TASK in this simplified graph, create-facility
      # is kept REAL (not elided) here -- REQ-433's own test-local-graph follow-on
      # requires the committee-tally approve path to park at a real SERVICE_TASK
      # (current_nodes == ["create-facility"], a real pending ServiceTaskDispatch
      # row) rather than cascading straight to disburse-loan, matching
      # @loan_origination_graph_with_service_task's own already-proven
      # create-facility shape below.
      %{
        "id" => "create-facility",
        "node_type" => "SERVICE_TASK",
        "attributes" => %{
          "endpoint" => "https://httpbin.org/anything/core-banking/facilities",
          "method" => "POST",
          "timeout_ms" => 300_000
        }
      },
      %{
        "id" => "disburse-loan",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-loan-ops"}
      },
      %{"id" => "end-disbursed", "node_type" => "END"},
      %{"id" => "end-declined", "node_type" => "END"}
    ],
    "edges" => [
      %{"id" => "e0", "source" => "start", "target" => "parallel-assessment-fork"},
      %{"id" => "e1", "source" => "parallel-assessment-fork", "target" => "credit-memo-review"},
      %{"id" => "e2", "source" => "parallel-assessment-fork", "target" => "risk-assessment"},
      # e3: the KYC/AML track's own branch, direct to assessment-join (see the
      # ELIXIR-DEV finding above -- no gateway node survives mid-branch here).
      %{"id" => "e3", "source" => "parallel-assessment-fork", "target" => "assessment-join"},
      %{"id" => "e4", "source" => "credit-memo-review", "target" => "assessment-join"},
      %{"id" => "e6", "source" => "risk-assessment", "target" => "assessment-join"},
      %{"id" => "e14", "source" => "assessment-join", "target" => "eligibility-gate"},
      %{
        "id" => "eligibility-gate-default",
        "source" => "eligibility-gate",
        "target" => "end-declined",
        "is_default" => true
      },
      %{
        "id" => "e15",
        "source" => "eligibility-gate",
        "target" => "authority-routing",
        "condition" =>
          "variables.credit_decision == 'pass' && variables.risk_rating != 'unacceptable'"
      },
      %{
        "id" => "e16",
        "source" => "eligibility-gate",
        "target" => "end-declined",
        "condition" =>
          "variables.credit_decision == 'fail' || variables.risk_rating == 'unacceptable'"
      },
      %{
        "id" => "authority-routing-default",
        "source" => "authority-routing",
        "target" => "end-declined",
        "is_default" => true
      },
      %{
        "id" => "e17",
        "source" => "authority-routing",
        "target" => "l1-approval",
        "condition" => "variables.requested_amount_eur <= 500000"
      },
      %{
        "id" => "e18",
        "source" => "authority-routing",
        "target" => "committee-vote-fork",
        "condition" => "variables.requested_amount_eur > 500000"
      },
      %{
        "id" => "e19",
        "source" => "l1-approval",
        "target" => "l2-approval",
        "condition" => "variables.l1_decision == 'approve' || variables.l1_decision == 'escalate'"
      },
      %{
        "id" => "e20",
        "source" => "l1-approval",
        "target" => "end-declined",
        "condition" => "variables.l1_decision == 'reject'"
      },
      %{
        "id" => "e21",
        "source" => "l2-approval",
        "target" => "disburse-loan",
        "condition" => "variables.l2_decision == 'approve'"
      },
      %{
        "id" => "e22",
        "source" => "l2-approval",
        "target" => "end-declined",
        "condition" => "variables.l2_decision == 'reject'"
      },
      # REQ-433: real 2-of-3 committee quorum subgraph (committee-vote-fork ->
      # 3 real HUMAN_TASKs -> committee-vote-join -> committee-tally), mirroring
      # the same node/edge ids and edge conditions §2/§2.3 of
      # lib/letflow/design/req433-committee-quorum.md add to both real fixtures
      # -- per-voter SERVICE_TASK timeout siblings are elided here, consistent
      # with this graph's own existing elision convention for every other
      # SERVICE_TASK (credit-memo-timeout/risk-assessment-timeout/kyc-timeout
      # above). create-facility is the one SERVICE_TASK kept real in this graph
      # (see its own node comment above) so the committee-tally approve path
      # (e39) parks there for real, exactly like REQ-433's own extended
      # simulation scenario expects.
      %{"id" => "e29", "source" => "committee-vote-fork", "target" => "committee-vote-cro"},
      %{"id" => "e30", "source" => "committee-vote-fork", "target" => "committee-vote-director"},
      %{"id" => "e31", "source" => "committee-vote-fork", "target" => "committee-vote-ceo"},
      %{"id" => "e32", "source" => "committee-vote-cro", "target" => "committee-vote-join"},
      %{"id" => "e33", "source" => "committee-vote-director", "target" => "committee-vote-join"},
      %{"id" => "e34", "source" => "committee-vote-ceo", "target" => "committee-vote-join"},
      %{"id" => "e38", "source" => "committee-vote-join", "target" => "committee-tally"},
      %{
        "id" => "e39",
        "source" => "committee-tally",
        "target" => "create-facility",
        "condition" =>
          "(variables.committee_vote_cro == 'approve' && variables.committee_vote_director == 'approve') || (variables.committee_vote_cro == 'approve' && variables.committee_vote_ceo == 'approve') || (variables.committee_vote_director == 'approve' && variables.committee_vote_ceo == 'approve')"
      },
      %{
        "id" => "e40",
        "source" => "committee-tally",
        "target" => "end-declined",
        "condition" =>
          "(variables.committee_vote_cro == 'reject' && variables.committee_vote_director == 'reject') || (variables.committee_vote_cro == 'reject' && variables.committee_vote_ceo == 'reject') || (variables.committee_vote_director == 'reject' && variables.committee_vote_ceo == 'reject')"
      },
      %{
        "id" => "e40-default",
        "source" => "committee-tally",
        "target" => "end-declined",
        "is_default" => true
      },
      # Fallback edges (REQ-208's own graph-validation-driven addition, over the
      # design's literal §3.1 edge set): Letflow.Definitions.Graph's validator
      # requires every HUMAN_TASK with at least one really-conditioned outgoing
      # edge to also have an unconditioned fallback edge. The real fixture's own
      # fallback-l1-approval/fallback-l2-approval edges served this role
      # (targeting l2-approval/create-facility respectively) -- kept here,
      # verbatim in shape: l1-approval's fallback still targets l2-approval (this graph
      # is a test-local snapshot of the pre-v1.16 chain, not a parity copy of the shipped
      # fixture, whose fallback-l1-approval targets escalate-l1-approval-to-cro since
      # v1.16); l2-approval's fallback now targets
      # disburse-loan directly, since create-facility no longer exists as an
      # intermediate node on that path in this simplified graph. The three
      # committee-vote-* HUMAN_TASKs need no fallback of their own: each has
      # exactly one, already-unconditioned outgoing edge (e32/e33/e34), the
      # same reason credit-memo-review/risk-assessment above need none either.
      # Never exercised by either scenario (both always set a
      # condition-satisfying decision variable).
      %{"id" => "fallback-l1-approval", "source" => "l1-approval", "target" => "l2-approval"},
      %{"id" => "fallback-l2-approval", "source" => "l2-approval", "target" => "disburse-loan"},
      %{"id" => "e26", "source" => "create-facility", "target" => "disburse-loan"},
      %{"id" => "e27", "source" => "disburse-loan", "target" => "end-disbursed"}
    ]
  }

  # ── REQ-215 AC2: @loan_origination_graph_with_service_task ────────────────
  # A second variant of the above graph, for the new describe block this
  # requirement adds below: `create-facility` is restored as a REAL
  # SERVICE_TASK node (process_claim_intake.yaml's own real node,
  # process_claim_intake.yaml:74-78, `endpoint: POST /core-banking/facilities`)
  # instead of being elided the way @simple_loan_origination_graph elides
  # every SERVICE_TASK. Every other node/edge (the parallel-assessment-fork,
  # KYC/AML track's own edge, eligibility-gate, authority-routing, l1/l2
  # approval chain, credit-committee-vote) is kept identical to
  # @simple_loan_origination_graph above -- this graph exists ONLY to prove
  # REQ-215's own AC2 (committee-vote/quorum-2-of-3/disbursement paths
  # reached and passing end to end), not to re-prove anything the original
  # two describe blocks below already lock in.
  @loan_origination_graph_with_service_task %{
    "nodes" => [
      %{"id" => "start", "node_type" => "START"},
      %{"id" => "parallel-assessment-fork", "node_type" => "PARALLEL_GATEWAY"},
      %{
        "id" => "credit-memo-review",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-credit-manager"}
      },
      %{
        "id" => "risk-assessment",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-risk-manager"}
      },
      %{"id" => "assessment-join", "node_type" => "PARALLEL_GATEWAY"},
      %{"id" => "eligibility-gate", "node_type" => "EXCLUSIVE_GATEWAY"},
      %{"id" => "authority-routing", "node_type" => "EXCLUSIVE_GATEWAY"},
      %{
        "id" => "l1-approval",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-credit-manager"}
      },
      %{
        "id" => "l2-approval",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-credit-director"}
      },
      %{
        "id" => "credit-committee-vote",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-committee-member"}
      },
      # REAL SERVICE_TASK node, unlike @simple_loan_origination_graph's own
      # direct-edge elision -- endpoint is a test-time placeholder, patched to
      # a real local WebhookTestServer URL at test setup time (this graph
      # constant itself cannot know the server's OS-assigned port).
      %{
        "id" => "create-facility",
        "node_type" => "SERVICE_TASK",
        "attributes" => %{
          "endpoint" => "SERVICE_TASK_ENDPOINT_PLACEHOLDER",
          "timeout_ms" => 5_000
        }
      },
      %{
        "id" => "disburse-loan",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-loan-ops"}
      },
      %{"id" => "end-disbursed", "node_type" => "END"},
      %{"id" => "end-declined", "node_type" => "END"}
    ],
    "edges" => [
      %{"id" => "e0", "source" => "start", "target" => "parallel-assessment-fork"},
      %{"id" => "e1", "source" => "parallel-assessment-fork", "target" => "credit-memo-review"},
      %{"id" => "e2", "source" => "parallel-assessment-fork", "target" => "risk-assessment"},
      %{"id" => "e3", "source" => "parallel-assessment-fork", "target" => "assessment-join"},
      %{"id" => "e4", "source" => "credit-memo-review", "target" => "assessment-join"},
      %{"id" => "e6", "source" => "risk-assessment", "target" => "assessment-join"},
      %{"id" => "e14", "source" => "assessment-join", "target" => "eligibility-gate"},
      %{
        "id" => "eligibility-gate-default",
        "source" => "eligibility-gate",
        "target" => "end-declined",
        "is_default" => true
      },
      %{
        "id" => "e15",
        "source" => "eligibility-gate",
        "target" => "authority-routing",
        "condition" =>
          "variables.credit_decision == 'pass' && variables.risk_rating != 'unacceptable'"
      },
      %{
        "id" => "e16",
        "source" => "eligibility-gate",
        "target" => "end-declined",
        "condition" =>
          "variables.credit_decision == 'fail' || variables.risk_rating == 'unacceptable'"
      },
      %{
        "id" => "authority-routing-default",
        "source" => "authority-routing",
        "target" => "credit-committee-vote",
        "is_default" => true
      },
      %{
        "id" => "e17",
        "source" => "authority-routing",
        "target" => "l1-approval",
        "condition" => "variables.requested_amount_eur <= 500000"
      },
      %{
        "id" => "e18",
        "source" => "authority-routing",
        "target" => "credit-committee-vote",
        "condition" => "variables.requested_amount_eur > 500000"
      },
      %{
        "id" => "e19",
        "source" => "l1-approval",
        "target" => "l2-approval",
        "condition" => "variables.l1_decision == 'approve' || variables.l1_decision == 'escalate'"
      },
      %{
        "id" => "e20",
        "source" => "l1-approval",
        "target" => "end-declined",
        "condition" => "variables.l1_decision == 'reject'"
      },
      %{
        "id" => "e21",
        "source" => "l2-approval",
        "target" => "create-facility",
        "condition" => "variables.l2_decision == 'approve'"
      },
      %{
        "id" => "e22",
        "source" => "l2-approval",
        "target" => "end-declined",
        "condition" => "variables.l2_decision == 'reject'"
      },
      %{
        "id" => "e23",
        "source" => "credit-committee-vote",
        "target" => "create-facility",
        "condition" => "variables.committee_outcome == 'approved'"
      },
      %{
        "id" => "e24",
        "source" => "credit-committee-vote",
        "target" => "end-declined",
        "condition" => "variables.committee_outcome == 'rejected'"
      },
      %{"id" => "fallback-l1-approval", "source" => "l1-approval", "target" => "l2-approval"},
      %{"id" => "fallback-l2-approval", "source" => "l2-approval", "target" => "create-facility"},
      %{
        "id" => "fallback-credit-committee-vote",
        "source" => "credit-committee-vote",
        "target" => "create-facility"
      },
      %{"id" => "e26", "source" => "create-facility", "target" => "disburse-loan"},
      %{"id" => "e27", "source" => "disburse-loan", "target" => "end-disbursed"}
    ]
  }

  # ── §3.2: @simple_regulatory_review_graph ─────────────────────────────────
  # Derived from process_policy_binding.yaml (design §0.2). No SERVICE_TASK on this
  # scenario's own actually-exercised path (start -> evidence-collection ->
  # risk-evaluation, then blocked) needs elision -- the on_timeout-fallback
  # SERVICE_TASKs are elided anyway for structural cleanliness (never exercised),
  # every other node kept for structural completeness only.
  @simple_regulatory_review_graph %{
    "nodes" => [
      %{"id" => "start", "node_type" => "START"},
      %{
        "id" => "evidence-collection",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-compliance-officer"}
      },
      %{
        "id" => "risk-evaluation",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-risk-manager"}
      },
      %{"id" => "severity-routing", "node_type" => "EXCLUSIVE_GATEWAY"},
      %{
        "id" => "findings-sign-off",
        "node_type" => "HUMAN_TASK",
        "attributes" => %{"role" => "role-cro"}
      },
      %{"id" => "end-closed", "node_type" => "END"}
    ],
    "edges" => [
      %{"id" => "e0", "source" => "start", "target" => "evidence-collection"},
      %{"id" => "e1", "source" => "evidence-collection", "target" => "risk-evaluation"},
      %{"id" => "e3", "source" => "risk-evaluation", "target" => "severity-routing"},
      %{
        "id" => "severity-routing-default",
        "source" => "severity-routing",
        "target" => "findings-sign-off",
        "is_default" => true
      },
      %{
        "id" => "e7",
        "source" => "severity-routing",
        "target" => "findings-sign-off",
        "condition" =>
          "variables.highest_severity == 'none' || variables.highest_severity == 'low' || variables.highest_severity == 'medium' || variables.highest_severity == 'high'"
      },
      # findings-sign-off's own outgoing edge is left unconditioned here (the real
      # fixture's e11/e12 pair -- sign_off/reject_and_reopen -- collapsed to one
      # edge): findings-sign-off is present only for structural completeness
      # (design §3.2, never exercised by this scenario's 3 steps), and
      # Letflow.Definitions.Graph's validator requires every HUMAN_TASK with a
      # really-conditioned outgoing edge to also carry an unconditioned fallback;
      # since this node is never reached, a single unconditioned edge is
      # simpler and equally inert.
      %{"id" => "e11", "source" => "findings-sign-off", "target" => "end-closed"}
    ]
  }

  setup do
    Sandbox.mode(Letflow.Repo, :auto)

    unique = Letflow.TenantSlugFixture.unique_slug("req208")

    company = %{
      "slug" => unique,
      "display_name" => "Meridian Capital AG",
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

    lars = Map.fetch!(users_by_actor_id, "actor-meridian-lars")
    julia = Map.fetch!(users_by_actor_id, "actor-meridian-julia")
    thomas = Map.fetch!(users_by_actor_id, "actor-meridian-thomas")
    ben = Map.fetch!(users_by_actor_id, "actor-meridian-ben")
    eva = Map.fetch!(users_by_actor_id, "actor-meridian-eva")
    marcus = Map.fetch!(users_by_actor_id, "actor-meridian-marcus")
    claudia = Map.fetch!(users_by_actor_id, "actor-meridian-claudia")

    # ISS-0942: org_structure.yaml's departments were seeded as plain groups
    # but never bound to the "role-*" process_routing_role names the
    # @simple_loan_origination_graph/@simple_regulatory_review_graph
    # HUMAN_TASK nodes assign to -- harmless before this fix (this
    # moduledoc's own now-superseded "Token roles are a separate namespace"
    # note documented `:TasksComplete` as unconditionally allowing any
    # PROCESS_OPERATOR to complete any task regardless of assignee_ref), but
    # POST /tasks/:id/complete now enforces that check
    # (Tasks.authorize_completion/3) -- the scenario's own actors must
    # actually hold the role their step completes, same as a real tenant
    # would be configured.
    {:ok, groups} = Seed.seed_groups(org_structure, tenant)
    group_by_name = Map.new(groups, &{&1.name, &1})

    {:ok, _} =
      RoleRegistry.upsert_role(
        "role-credit-manager",
        :process_routing_role,
        Map.fetch!(group_by_name, "dept-credit-de").id,
        prefix: schema_name
      )

    {:ok, _} =
      RoleRegistry.upsert_role(
        "role-risk-manager",
        :process_routing_role,
        Map.fetch!(group_by_name, "dept-risk").id,
        prefix: schema_name
      )

    {:ok, _} =
      RoleRegistry.upsert_role(
        "role-compliance-officer",
        :process_routing_role,
        Map.fetch!(group_by_name, "dept-compliance").id,
        prefix: schema_name
      )

    # julia (dept-credit-de) drives both loan-origination scenarios' step 2b,
    # which the test's own pre-existing comment (describe "meridian-loan-
    # origination-above-threshold") documents as actually completing
    # `items.0` of `GET /tasks?status=PENDING` -- the risk-assessment task
    # (role-risk-manager), not credit-memo-review as the scenario YAML's step
    # name assumes, because of `list_tasks/2`'s `inserted_at DESC` ordering.
    # That ordering quirk predates ISS-0942 and is unrelated to it; julia is
    # added to dept-risk here only so this pre-existing scenario quirk
    # continues to complete successfully under the newly-enforced assignee
    # check, without rewriting the scenario's own documented behavior.
    {:ok, _} =
      Identity.add_group_member(Map.fetch!(group_by_name, "dept-risk").id, julia.id,
        prefix: schema_name
      )

    # REQ-433: role-committee-member has no dedicated department group in
    # org_structure.yaml (unlike role-credit-manager/role-risk-manager/
    # role-compliance-officer above, each backed by one pre-existing dept-*
    # group) -- the three committee voters (thomas, julia, eva) span 3
    # different existing departments (dept-risk, dept-credit-de, dept-exec).
    # `RoleRegistry.upsert_role/4` binds one role name to exactly ONE group
    # id, so a new, test-local group is created here (not added to the
    # shared org_structure.yaml fixture, which test/fixtures/simulation/
    # fixture_shape_test.exs also validates structurally and which
    # req206/207's own scenarios do not touch) containing exactly the 3
    # committee-vote actors this scenario drives, then bound to
    # role-committee-member -- same effect as a real tenant designating a
    # standing "Credit Committee" group, scoped to this test only.
    {:ok, committee_group} =
      Identity.create_group(
        %{"name" => "dept-credit-committee-" <> unique, "display_name" => "Credit Committee"},
        prefix: schema_name
      )

    {:ok, _} =
      RoleRegistry.upsert_role(
        "role-committee-member",
        :process_routing_role,
        committee_group.id,
        prefix: schema_name
      )

    for member <- [thomas, julia, eva] do
      {:ok, _} = Identity.add_group_member(committee_group.id, member.id, prefix: schema_name)
    end

    # Seed simplified loan-origination process (no SERVICE_TASKs; shared by both
    # above-threshold and below-threshold scenarios, per the requirement text).
    simple_loan_name = "SimpleLoanOrigination-" <> unique

    {:ok, definition_loan} =
      case Letflow.Definitions.get_active_by_name(simple_loan_name, prefix: schema_name) do
        {:ok, d} ->
          {:ok, d}

        {:error, :not_found} ->
          with {:ok, d} <-
                 Letflow.Definitions.create(
                   %{
                     name: simple_loan_name,
                     version: "1.0",
                     description:
                       "REQ-208 test-local process: exercises parallel-fork/join and authority-routing EXCLUSIVE_GATEWAY branches (l1/l2 chain vs. committee vote) without SERVICE_TASKs.",
                     graph: @simple_loan_origination_graph,
                     created_by: lars.id
                   },
                   prefix: schema_name
                 ),
               {:ok, %{definition: activated}} <-
                 Letflow.Definitions.activate(d.id, prefix: schema_name) do
            {:ok, activated}
          end
      end

    # Seed simplified regulatory-review process (no SERVICE_TASKs on the exercised
    # path; for the BaFin scenario).
    simple_review_name = "SimpleRegulatoryComplianceReview-" <> unique

    {:ok, definition_review} =
      case Letflow.Definitions.get_active_by_name(simple_review_name, prefix: schema_name) do
        {:ok, d} ->
          {:ok, d}

        {:error, :not_found} ->
          with {:ok, d} <-
                 Letflow.Definitions.create(
                   %{
                     name: simple_review_name,
                     version: "1.0",
                     description:
                       "REQ-208 test-local process: exercises evidence-collection -> risk-evaluation, the node whose on_timeout boundary the (missing, ISS-0389) advance-timer endpoint would advance.",
                     graph: @simple_regulatory_review_graph,
                     created_by: claudia.id
                   },
                   prefix: schema_name
                 ),
               {:ok, %{definition: activated}} <-
                 Letflow.Definitions.activate(d.id, prefix: schema_name) do
            {:ok, activated}
          end
      end

    # Deviation from the design's literal §4.1 token-role wording (recorded, not
    # silent): `Identity.create_token/3` (lib/letflow/identity.ex, re-confirmed
    # this session) accepts ONLY `Letflow.Api.Authorization.roles/0`'s five
    # literal role-name strings (PLATFORM_ADMIN/PROCESS_DESIGNER/
    # PROCESS_OPERATOR/TASK_WORKER/AGENT_RUNNER) as `attrs.roles` -- an
    # unrecognized entry (e.g. the process-attribute strings "role-credit-manager"
    # etc., which the design's own §4.1 text used) is rejected loudly,
    # `{:error, :invalid_role_set}`, confirmed empirically this session. Those
    # `role-*` strings are `HUMAN_TASK` node `attributes.role` values -- a
    # completely separate namespace the engine uses only for `assignee_ref`
    # resolution (design §0.7), never a token permission. Per §0.7, claim is not
    # required before complete -- every actor below is granted `PROCESS_OPERATOR`
    # (matching REQ-206/207's own precedent, `req206_swiftroute_test.exs`/
    # `req207_vortex_test.exs`), satisfying the coarse `:TasksComplete` RBAC gate.
    # `task_assigned` checks against a role-attributed task still assert
    # `outcome in [:pass, :fail]` with the real `observed.assignee_ref` string as
    # evidence, same limitation REQ-206/207 already recorded (design §0.7).
    #
    # (ISS-0942 update: `:TasksComplete` passing is no longer sufficient on its
    # own -- `PROCESS_OPERATOR` here only satisfies the RBAC permission check;
    # the group/role bindings seeded just above additionally satisfy
    # `Tasks.authorize_completion/3`'s per-task assignee check, now enforced
    # ahead of `Engine.complete_task/3`.)
    {:ok, %{plaintext: lars_token}} =
      Identity.create_token(lars.id, %{roles: ["PROCESS_OPERATOR"]}, prefix: schema_name)

    {:ok, %{plaintext: julia_token}} =
      Identity.create_token(julia.id, %{roles: ["PROCESS_OPERATOR"]}, prefix: schema_name)

    {:ok, %{plaintext: thomas_token}} =
      Identity.create_token(thomas.id, %{roles: ["PROCESS_OPERATOR"]}, prefix: schema_name)

    {:ok, %{plaintext: ben_token}} =
      Identity.create_token(ben.id, %{roles: ["PROCESS_OPERATOR"]}, prefix: schema_name)

    {:ok, %{plaintext: eva_token}} =
      Identity.create_token(eva.id, %{roles: ["PROCESS_OPERATOR"]}, prefix: schema_name)

    {:ok, %{plaintext: marcus_token}} =
      Identity.create_token(marcus.id, %{roles: ["PROCESS_OPERATOR"]}, prefix: schema_name)

    {:ok, %{plaintext: claudia_token}} =
      Identity.create_token(claudia.id, %{roles: ["PROCESS_OPERATOR"]}, prefix: schema_name)

    actors = %{
      "actor-meridian-lars" => %{"token" => lars_token, "tenant_slug" => unique},
      "actor-meridian-julia" => %{"token" => julia_token, "tenant_slug" => unique},
      "actor-meridian-thomas" => %{"token" => thomas_token, "tenant_slug" => unique},
      "actor-meridian-ben" => %{"token" => ben_token, "tenant_slug" => unique},
      "actor-meridian-eva" => %{"token" => eva_token, "tenant_slug" => unique},
      "actor-meridian-marcus" => %{"token" => marcus_token, "tenant_slug" => unique},
      "actor-meridian-claudia" => %{"token" => claudia_token, "tenant_slug" => unique}
    }

    on_exit(fn -> teardown(unique) end)

    %{
      tenant: tenant,
      schema_name: schema_name,
      unique: unique,
      actors: actors,
      definitions: %{loan: definition_loan, review: definition_review},
      # REQ-215 AC2's own new describe block drives its steps via direct
      # Letflow.Engine/Letflow.Tasks calls (not Runner.run/1 -- see this
      # module's own moduledoc, "CLOSED by REQ-215" section, for why) and
      # needs real actor_id UUIDs, not just API tokens.
      actor_ids: %{
        lars: lars.id,
        julia: julia.id,
        thomas: thomas.id,
        ben: ben.id,
        eva: eva.id,
        marcus: marcus.id,
        claudia: claudia.id
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

  # Replaces "TENANT_PREFIX" in precondition/outcome args, "DEFINITION_NAME" in
  # process_id/step params, with real test-time values. Mirrors
  # req207_vortex_test.exs's patch_scenario/2 exactly (no :audit_event_ordering
  # method here, so no "first"/"second" nested-prefix branch is needed).
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
      put_in(outcome, [:verification, :args], Map.put(args, "prefix", schema_name))
    end)
  end

  # ─── AC1: meridian-loan-origination-above-threshold ──────────────────────

  describe "meridian-loan-origination-above-threshold" do
    test "real 2-of-3 committee quorum: all 3 votes complete, join fires, committee-tally routes to create-facility (REQ-433, ISS-0974 fix)",
         %{schema_name: schema_name, actors: actors, definitions: %{loan: definition}} do
      scenario_raw =
        ScenarioFixture.load!(Path.join(@scenarios_dir, "loan-origination-above-threshold.yaml"))

      scenario =
        patch_scenario(scenario_raw,
          schema_name: schema_name,
          definition_name: definition.name,
          actors: actors
        )

      assert {:ok, report} = Runner.run(scenario)

      assert length(report.step_results) == 9

      [
        step1,
        step2a,
        step2b,
        step3,
        step4,
        step5,
        step6,
        step7,
        step8
      ] = report.step_results

      instance_id = step1.captured["instance_id"]

      assert step1.outcome == :ok, "step 1 (POST /instances) failed — #{inspect(step1.detail)}"
      assert %{"instance_id" => _, "status" => "ACTIVE"} = step1.captured

      assert step2a.outcome == :ok, "step 2a (GET credit-memo lookup) — #{inspect(step2a.detail)}"

      # AC1's own "3 parallel assessment tracks confirmed created from real
      # queried task state" -- real: the split itself happens within
      # instance-creation's own single hop-chain, so both real HUMAN_TASKs
      # (credit-memo-review, risk-assessment) exist as task rows from that
      # point on regardless of what happens next; the KYC/AML track is the
      # immediate, unconditioned edge straight to assessment-join (test
      # module's own @simple_loan_origination_graph comment).
      {:ok, %{items: all_tasks}} =
        Letflow.Tasks.list_tasks(
          %{instance_id: instance_id, page_size: 10},
          prefix: schema_name
        )

      all_task_node_ids = Enum.map(all_tasks, fn {task, _form_version} -> task.node_id end)
      assert "credit-memo-review" in all_task_node_ids
      assert "risk-assessment" in all_task_node_ids

      # Step 2b (ISS-0397 fix, now locked in further by REQ-433's own extension
      # below): a real, separate HTTP call completing one parallel branch
      # durably reads the cohort create/2's own split left behind
      # (instance_projections.join_counters) and succeeds: one of the 3
      # expected branches is received, two remain outstanding (the join does
      # not fire yet).
      assert step2b.outcome == :ok,
             "step 2b (POST task complete) failed — #{inspect(step2b.detail)}"

      assert %{"instance_status" => "ACTIVE"} = step2b.detail

      # Step 3 -- looks up the one remaining pending assessment task
      # (credit-memo-review, per items.0's own risk-assessment-first ordering
      # quirk noted above).
      assert step3.outcome == :ok,
             "step 3 (GET remaining assessment lookup) — #{inspect(step3.detail)}"

      # Step 4 -- completes the last assessment branch. Real: fires
      # assessment-join (3 of 3 received) and cascades, in this one call,
      # through eligibility-gate and authority-routing (750000 > 500000 ->
      # committee-vote-fork), landing 3 real HUMAN_TASKs
      # (committee-vote-cro/director/ceo) in one hop-chain -- the same
      # single-call multi-hop cascade the REQ-215 AC2 describe block below
      # already proves against this exact gateway shape.
      assert step4.outcome == :ok,
             "step 4 (POST last assessment branch complete) — #{inspect(step4.detail)}"

      assert %{"instance_status" => "ACTIVE"} = step4.detail

      # NOTE (same single-shot-execution property this test module's own
      # pre-existing comments already document for step1/2a/2b above):
      # `Runner.run/1` executes this scenario's ENTIRE step list before
      # returning -- there is no way to observe instance state as of "right
      # after step 4" specifically; any query issued here necessarily
      # observes state as of the LAST step (step 8). Real per-step pass/fail
      # evidence for steps 4 through 8 individually still comes from each
      # step's own `outcome`/`detail` below -- real, not fabricated, just not
      # independently re-queryable mid-scenario.

      # Step 5 -- looks up the 3 committee-vote-* tasks created by step 4's
      # cascade. Real. Order is NOT assumed to correspond to a specific node
      # id (the Runner's template substitution is purely positional, and
      # `list_tasks/2`'s `inserted_at DESC, id DESC` ordering means whichever
      # of the 3 committee-vote-* tasks was created LAST comes back as
      # items.0) -- this does not matter: output_variables are
      # instance-global and unvalidated against the completing task's own
      # node id, so assigning the 3 required committee_vote_* variable names
      # to whichever 3 tasks come back in whatever order still produces the
      # exact same quorum tally (2 approve, 1 reject) regardless of which
      # physical committee-vote-{cro,director,ceo} node each one structurally
      # is -- asserted structurally below, not against a specific binding.
      assert step5.outcome == :ok, "step 5 (GET committee task lookup) — #{inspect(step5.detail)}"

      # Steps 6/7 -- two committee members vote approve, reaching 2-of-3
      # quorum (join has not fired yet -- only 2 of 3 branches received).
      assert step6.outcome == :ok, "step 6 (1st committee vote) — #{inspect(step6.detail)}"
      assert step7.outcome == :ok, "step 7 (2nd committee vote) — #{inspect(step7.detail)}"

      # Step 8 -- the third committee member dissents, the 3rd-of-3 arrival
      # at committee-vote-join (a set-based wait-for-all-expected join).
      #
      # FIXED by ISS-0974 (2026-10-02, `a53858e0`,
      # `lib/letflow/design/iss0974-join-dispatch-id-map-fix.md`) -- the
      # previously-documented defect this step used to assert (a join firing
      # within the same hop chain as its own triggering completion, cascading
      # straight into a SERVICE_TASK, minted a non-persisted token_id that
      # `build_complete_task_tail_multi/6`'s identity `id_map` could not
      # resolve, surfacing as a real 422/`Ecto.UUID` cast failure) is gone:
      # ISS-0974 threads the real hop-chain `id_map` (built from
      # `insert_hop_chain_new_token_records/5`'s own rewritten ids) into the
      # timer-arm/service-task-dispatch `Multi.merge` siblings, so a
      # join-minted continuation token is now a real, resolvable id by the
      # time `create-facility`'s dispatch row is built. Re-run against this
      # exact graph shape (confirmed this session, not assumed): step 8 now
      # succeeds for real.
      #
      # `committee-vote-join` fires (3 of 3 received), cascades through
      # `committee-tally` (EXCLUSIVE_GATEWAY pass-through -- e39's condition,
      # "2 of 3 == 'approve'", is true even with this dissent) onto
      # `create-facility`, a real SERVICE_TASK. Per REQ-215's own AC2 describe
      # block (below), a SERVICE_TASK parks the token with no automatic
      # outgoing traversal -- this is the real, honestly-reached end state for
      # this test-local graph (REQ-433's own design doc §4.2 calls this out
      # explicitly: this Runner-driven scenario format has no step primitive
      # to resolve a pending SERVICE_TASK dispatch, so it stops here by
      # design, not truncation; `end-disbursed` is reached only by the
      # separate real UAT scenario against `process_claim_intake.yaml`,
      # REQ-433's design §4.1).
      assert step8.outcome == :ok, "step 8 (3rd committee vote) — #{inspect(step8.detail)}"

      assert %{
               "current_nodes" => ["create-facility"],
               "instance_status" => "ACTIVE"
             } = step8.detail

      assert %{
               "committee_vote_cro" => "approve",
               "committee_vote_director" => "approve",
               "committee_vote_ceo" => "reject"
             } =
               Map.take(step8.detail["variables"], [
                 "committee_vote_cro",
                 "committee_vote_director",
                 "committee_vote_ceo"
               ])

      # Real-state evidence the join genuinely fired and committee-tally's
      # structural 2-of-3 quorum tally (not a supplied committee_outcome
      # variable, per REQ-433's own AC2) routed the token to create-facility
      # for real: current_nodes shows exactly that one SERVICE_TASK, all
      # three committee_vote_* variables are persisted (2 approve, 1 reject),
      # and a real, pending service_task_dispatches row exists for it with a
      # genuine, persisted (UUID-valid) token_id -- the exact field ISS-0974
      # fixed.
      {:ok, final_projection} = Instances.get_by_id(instance_id, prefix: schema_name)
      assert final_projection.status == :active
      assert final_projection.current_nodes == ["create-facility"]

      assert %{
               "committee_vote_cro" => "approve",
               "committee_vote_director" => "approve",
               "committee_vote_ceo" => "reject"
             } =
               Map.take(final_projection.variables, [
                 "committee_vote_cro",
                 "committee_vote_director",
                 "committee_vote_ceo"
               ])

      assert [dispatch] =
               ServiceTaskDispatch
               |> Ecto.Query.where([d], d.instance_id == ^instance_id)
               |> Repo.all(prefix: schema_name),
             "Expected exactly one real service_task_dispatches row for create-facility, " <>
               "the join's own continuation token now being a real, persisted token_id " <>
               "(ISS-0974's fix) rather than failing the Ecto.UUID cast as it did before"

      assert dispatch.node_id == "create-facility"
      assert dispatch.status == "pending"
      assert dispatch.instance_id == instance_id
      assert {:ok, _} = Ecto.UUID.cast(dispatch.token_id)
    end
  end

  # ─── AC2: meridian-loan-origination-below-threshold ──────────────────────

  describe "meridian-loan-origination-below-threshold" do
    test "3 parallel tracks fork for real; second, separate task-completion call now succeeds (ISS-0397)",
         %{schema_name: schema_name, actors: actors, definitions: %{loan: definition}} do
      scenario_raw =
        ScenarioFixture.load!(Path.join(@scenarios_dir, "loan-origination-below-threshold.yaml"))

      scenario =
        patch_scenario(scenario_raw,
          schema_name: schema_name,
          definition_name: definition.name,
          actors: actors
        )

      assert {:ok, report} = Runner.run(scenario)

      assert length(report.step_results) == 3
      [step1, step2a, step2b] = report.step_results

      instance_id = step1.captured["instance_id"]

      assert step1.outcome == :ok, "step 1 (POST /instances) failed — #{inspect(step1.detail)}"
      assert %{"instance_id" => _, "status" => "ACTIVE"} = step1.captured

      assert step2a.outcome == :ok, "step 2a (GET credit-memo lookup) — #{inspect(step2a.detail)}"

      # Same "3 real HUMAN_TASKs created" evidence as the above-threshold test
      # above -- queried by existence (any status), not "still pending", since
      # `Runner.run/1` already executed step 2b (below) by the time this
      # returns (see that test's own comment on why).
      {:ok, %{items: all_tasks}} =
        Letflow.Tasks.list_tasks(
          %{instance_id: instance_id, page_size: 10},
          prefix: schema_name
        )

      all_task_node_ids = Enum.map(all_tasks, fn {task, _form_version} -> task.node_id end)
      assert "credit-memo-review" in all_task_node_ids
      assert "risk-assessment" in all_task_node_ids

      # Same fix as the above-threshold scenario (moduledoc, top) -- this
      # scenario's own graph is identical up to this point, so it behaves
      # identically post-fix. EO-002's own literal design point (no
      # committee-vote task exists) still cannot be verified via a full
      # end-to-end run (SERVICE_TASK dispatch gap, unrelated to ISS-0397) --
      # stated explicitly here, not silently assumed to hold.
      assert step2b.outcome == :ok,
             "step 2b (POST task complete) was expected to succeed now that " <>
               "ISS-0397 durably persists join_counters across calls; " <>
               "instead got outcome #{inspect(step2b.outcome)}, detail: #{inspect(step2b.detail)}"

      assert %{"instance_status" => "ACTIVE"} = step2b.detail

      assert report.outcome_results == []

      {:ok, final_projection} = Instances.get_by_id(instance_id, prefix: schema_name)
      assert final_projection.status == :active
      assert final_projection.current_nodes == ["credit-memo-review"]

      assert %{"assessment-join" => cohort} = final_projection.join_counters
      assert length(cohort["received_from_branches"]) == 2
      assert length(cohort["expected_from_branches"]) == 3
    end
  end

  # ─── AC3: meridian-regulatory-compliance-review-bafin ────────────────────

  describe "meridian-regulatory-compliance-review-bafin" do
    test "steps 1/2 real against real queried state; step 3 :blocked, blocked_by ISS-0389",
         %{schema_name: schema_name, actors: actors, definitions: %{review: definition}} do
      scenario_raw =
        ScenarioFixture.load!(
          Path.join(@scenarios_dir, "regulatory-compliance-review-bafin.yaml")
        )

      scenario =
        patch_scenario(scenario_raw,
          schema_name: schema_name,
          definition_name: definition.name,
          actors: actors
        )

      assert {:ok, report} = Runner.run(scenario)

      assert length(report.step_results) == 4
      [step1, step2a, step2b, step3] = report.step_results

      instance_id = step1.captured["instance_id"]

      assert step1.outcome == :ok, "step 1 (POST /instances) failed — #{inspect(step1.detail)}"
      assert %{"instance_id" => _, "status" => "ACTIVE"} = step1.captured

      assert step2a.outcome == :ok,
             "step 2a (GET evidence-collection lookup) — #{inspect(step2a.detail)}"

      # Step 1's own real-queried-state verification (design §4.3): since
      # Runner.run/1 dispatches every step through to completion before this test
      # body ever inspects anything (there is no intermediate-state hook), the
      # ONLY real evidence of state "right after step 1" is step 2a's own
      # already-captured real HTTP response (a GET /tasks call dispatched before
      # step 2b ever runs) -- not a fresh query issued now, after step 2b has
      # already moved the instance on to risk-evaluation. That real response
      # confirms an evidence-collection HUMAN_TASK existed at that point.
      assert %{"items" => [%{"node_id" => "evidence-collection"} | _]} = step2a.captured

      assert step2b.outcome == :ok,
             "step 2b (POST evidence-collection complete) — #{inspect(step2b.detail)}"

      assert step2b.outcome == :ok,
             "step 2b (POST evidence-collection complete) — #{inspect(step2b.detail)}"

      # Step 2's own real-queried-state verification (design §4.3, primary
      # mechanism, superseding the task-list-inference workaround the design
      # originally proposed, per OQ-1): current_nodes contains "risk-evaluation"
      # after evidence-collection completes -- direct, real-queried-state evidence
      # the instance is genuinely paused exactly at the node whose timer boundary
      # step 3 would need to advance.
      {:ok, projection_after_step2} = Instances.get_by_id(instance_id, prefix: schema_name)
      assert projection_after_step2.status == :active
      assert "risk-evaluation" in projection_after_step2.current_nodes

      # Kept alongside (not replacing) current_nodes: the risk-evaluation
      # HUMAN_TASK (role-risk-manager) exists and is PENDING -- distinct evidence
      # (task existence, role assignment) current_nodes alone cannot express.
      {:ok, %{items: pending_items}} =
        Letflow.Tasks.list_tasks(
          %{instance_id: instance_id, status: :pending, page_size: 10},
          prefix: schema_name
        )

      risk_evaluation_task =
        Enum.find(pending_items, fn {task, _form_version} -> task.node_id == "risk-evaluation" end)

      assert risk_evaluation_task != nil,
             "Expected a real, pending risk-evaluation HUMAN_TASK to exist for this instance"

      {risk_task, _form_version} = risk_evaluation_task
      assert risk_task.assignee_ref == "role-risk-manager"

      # Step 3: :blocked, not :skip (design §2.1's rationale) -- a regression
      # detector: if a later merge ships advance-timer, this assertion should be
      # the first thing to force someone to revisit this scenario's disposition
      # (same "disposition doubles as a regression detector" precedent REQ-207 §5
      # established for its own BLOCKED_ON_DEPENDENCY entity-scenario test).
      assert step3.outcome == :blocked,
             "step 3 expected :blocked, got #{inspect(step3.outcome)}"

      assert step3.blocked_by == "ISS-0389"
      assert step3.severity == :blocker
      assert step3.captured == nil

      # TEST-DESIGNER coverage-verification addition (this session): the
      # :no_task_of_type verification method (design §2.2, EO-002's own
      # negative-assertion primitive) was implemented by ELIXIR-DEV but never
      # actually exercised anywhere -- both loan-origination scenarios were
      # truncated before EO-002 could run (join_counters BLOCKER, see moduledoc).
      # Exercised here instead, on real queried state unaffected by that defect
      # (this scenario has no PARALLEL_GATEWAY), so the new verification method's
      # own logic gets real coverage rather than shipping untested.
      assert length(report.outcome_results) == 2
      [eo_no_task_absent, eo_no_task_present] = report.outcome_results

      # EO-NO-TASK-001: findings-sign-off is never reached on this scenario's
      # exercised path -- genuine :pass (real absence, not an unresolved
      # template or a not-found error mistaken for absence).
      assert eo_no_task_absent.outcome == :pass,
             "expected :no_task_of_type(findings-sign-off) to PASS (real absence) — " <>
               "observed: #{inspect(eo_no_task_absent.observed)}"

      refute Enum.any?(eo_no_task_absent.observed, fn {node_id, _status} ->
               node_id == "findings-sign-off"
             end)

      # EO-NO-TASK-002: negative control proving EO-NO-TASK-001 is not vacuously
      # true. evidence-collection DOES exist (COMPLETED by step 2b) -- queried
      # across every status, per design §2.2's "absence must hold regardless of
      # status" rule, so a status-blind implementation bug (e.g. only checking
      # :pending) cannot silently pass here. Real :fail expected.
      assert eo_no_task_present.outcome == :fail,
             "expected :no_task_of_type(evidence-collection) to FAIL (task genuinely " <>
               "exists, COMPLETED) — observed: #{inspect(eo_no_task_present.observed)}"

      assert Enum.any?(eo_no_task_present.observed, fn {node_id, _status} ->
               node_id == "evidence-collection"
             end)

      {:ok, final_projection} = Instances.get_by_id(instance_id, prefix: schema_name)
      assert final_projection.status == :active
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # REQ-215 AC2 -- committee-vote/quorum-2-of-3/disbursement paths reached
  # and passing end to end, now that SERVICE_TASK dispatch is wired. See this
  # module's own moduledoc, "CLOSED by REQ-215" section.
  # ═══════════════════════════════════════════════════════════════════════

  describe "loan-origination above-threshold, full committee-vote through disbursement (REQ-215 AC2)" do
    setup %{schema_name: schema_name, actor_ids: actor_ids} do
      Application.put_env(:letflow, :service_task_ssrf_validation_enabled, false)
      on_exit(fn -> Application.delete_env(:letflow, :service_task_ssrf_validation_enabled) end)

      %{url: server_url} =
        Letflow.WebhookTestServer.start(200, ~s({"facility_id":"FAC-9001"}))

      graph =
        put_in(
          @loan_origination_graph_with_service_task["nodes"],
          Enum.map(@loan_origination_graph_with_service_task["nodes"], fn
            %{"id" => "create-facility"} = node ->
              put_in(node, ["attributes", "endpoint"], server_url)

            node ->
              node
          end)
        )

      name =
        "LoanOriginationWithServiceTask-" <>
          to_string(System.unique_integer([:positive, :monotonic]))

      {:ok, d} =
        Definitions.create(
          %{
            name: name,
            version: "1.0",
            description:
              "REQ-215 AC2 test-local process: same shape as SimpleLoanOrigination but " <>
                "keeps create-facility as a real SERVICE_TASK node instead of eliding it.",
            graph: graph,
            created_by: actor_ids.lars
          },
          prefix: schema_name
        )

      {:ok, %{definition: activated}} = Definitions.activate(d.id, prefix: schema_name)

      %{definition: activated, server_url: server_url}
    end

    test "quorum-2-of-3 join fires, committee approves, create-facility SERVICE_TASK dispatches and resolves, disbursement completes the instance",
         %{schema_name: schema_name, actor_ids: actor_ids, definition: definition} do
      # Step 1 -- above-threshold amount (750000 > 500000), same as
      # loan-origination-above-threshold.yaml's own initial_variables.
      assert {:ok, create_result} =
               Engine.create(
                 %{
                   definition_id: definition.id,
                   initial_variables: %{"requested_amount_eur" => 750_000},
                   actor_id: actor_ids.lars,
                   idempotency_key: "req215-ac2-create-" <> Ecto.UUID.generate()
                 },
                 prefix: schema_name
               )

      instance_id = create_result.instance_id

      # 2 real HUMAN_TASKs from the fork (the KYC/AML track is the immediate,
      # unconditioned edge straight to assessment-join, same as
      # @simple_loan_origination_graph -- see that graph's own comment).
      {:ok, %{items: fork_tasks}} =
        Tasks.list_tasks(%{instance_id: instance_id, status: :pending, page_size: 10},
          prefix: schema_name
        )

      fork_task_node_ids = Enum.map(fork_tasks, fn {task, _fv} -> task.node_id end) |> Enum.sort()
      assert fork_task_node_ids == ["credit-memo-review", "risk-assessment"]

      credit_memo_task =
        Enum.find(fork_tasks, fn {t, _fv} -> t.node_id == "credit-memo-review" end) |> elem(0)

      risk_task =
        Enum.find(fork_tasks, fn {t, _fv} -> t.node_id == "risk-assessment" end) |> elem(0)

      # Complete both real, separate branches -- ISS-0397's own durable
      # join_counters fix (moduledoc) lets each SEPARATE complete_task/3
      # call route through assessment-join correctly. The join fires on the
      # SECOND completion (2-of-3 already received from credit-memo-review +
      # risk-assessment + the KYC/AML track's own immediate edge = quorum
      # reached at assessment-join, a real PARALLEL_GATEWAY join, in-degree 3).
      assert {:ok, _} =
               Engine.complete_task(
                 credit_memo_task.id,
                 %{
                   output_variables: %{"credit_decision" => "pass"},
                   actor_id: actor_ids.julia,
                   idempotency_key: "req215-ac2-credit-memo-" <> Ecto.UUID.generate()
                 },
                 prefix: schema_name
               )

      assert {:ok, risk_complete_result} =
               Engine.complete_task(
                 risk_task.id,
                 %{
                   output_variables: %{"risk_rating" => "acceptable"},
                   actor_id: actor_ids.thomas,
                   idempotency_key: "req215-ac2-risk-" <> Ecto.UUID.generate()
                 },
                 prefix: schema_name
               )

      # The join fired -- current_nodes narrows past assessment-join, past
      # eligibility-gate (pass/acceptable -> authority-routing), past
      # authority-routing (750000 > 500000 -> credit-committee-vote), landing
      # the token at credit-committee-vote -- real, quorum-driven multi-hop
      # advance in one complete_task/3 call, proving quorum-2-of-3 genuinely
      # fired (not just "the join counter incremented").
      assert risk_complete_result.instance_status == :active
      assert risk_complete_result.current_nodes == ["credit-committee-vote"]

      {:ok, %{items: committee_tasks}} =
        Tasks.list_tasks(%{instance_id: instance_id, status: :pending, page_size: 10},
          prefix: schema_name
        )

      assert [{committee_task, _fv}] = committee_tasks
      assert committee_task.node_id == "credit-committee-vote"
      assert committee_task.assignee_ref == "role-committee-member"

      # Committee votes "approved" -- routes to create-facility, a REAL
      # SERVICE_TASK node. The token PARKS there (no automatic outgoing
      # traversal, design doc §1.4) -- a real service_task_dispatches row is
      # created in the SAME transaction (REQ-215 AC3's own guarantee, proven
      # generically in service_task_wiring_test.exs; here proven in the
      # context AC2 actually names: the real Meridian committee-vote path).
      assert {:ok, committee_complete_result} =
               Engine.complete_task(
                 committee_task.id,
                 %{
                   output_variables: %{"committee_outcome" => "approved"},
                   actor_id: actor_ids.eva,
                   idempotency_key: "req215-ac2-committee-" <> Ecto.UUID.generate()
                 },
                 prefix: schema_name
               )

      assert committee_complete_result.instance_status == :active
      assert committee_complete_result.current_nodes == ["create-facility"]

      assert [dispatch] =
               ServiceTaskDispatch
               |> Ecto.Query.where([d], d.instance_id == ^instance_id)
               |> Repo.all(prefix: schema_name)

      assert dispatch.status == "pending"
      assert dispatch.node_id == "create-facility"

      # REQ-214's already-shipped transport call resolves it -- a real 2xx
      # JSON response from the real local server (facility_id, the exact
      # kind of downstream-system response create-facility's own real
      # endpoint, POST /core-banking/facilities, would return).
      assert {:ok, {:advance, decoded_body}} =
               ServiceTaskDispatcher.attempt_dispatch(dispatch.id, schema_name)

      assert decoded_body == %{"facility_id" => "FAC-9001"}

      # This requirement's own re-entry function -- advances the token off
      # create-facility onto disburse-loan, merging the decoded body into
      # instance variables (REQ-049's VariableMerge.merge/3, exercised here
      # in the real Meridian committee-vote/disbursement context AC2 names,
      # not just a synthetic graph).
      assert {:ok, :advanced} =
               Engine.advance_after_service_task_outcome(
                 dispatch.id,
                 {:advance, decoded_body},
                 Repo,
                 schema_name
               )

      {:ok, projection_after_advance} = Instances.get_by_id(instance_id, prefix: schema_name)
      assert projection_after_advance.status == :active
      assert projection_after_advance.current_nodes == ["disburse-loan"]
      assert projection_after_advance.variables["facility_id"] == "FAC-9001"

      {:ok, %{items: disburse_tasks}} =
        Tasks.list_tasks(%{instance_id: instance_id, status: :pending, page_size: 10},
          prefix: schema_name
        )

      assert [{disburse_task, _fv}] = disburse_tasks
      assert disburse_task.node_id == "disburse-loan"
      assert disburse_task.assignee_ref == "role-loan-ops"

      # Disbursement itself -- the loan-ops actor completes disburse-loan,
      # reaching end-disbursed. This is AC2's own literal "disbursement path
      # ... reached and pass end to end" claim, closed for real: the
      # instance actually COMPLETES.
      assert {:ok, disburse_complete_result} =
               Engine.complete_task(
                 disburse_task.id,
                 %{
                   output_variables: %{},
                   actor_id: actor_ids.marcus,
                   idempotency_key: "req215-ac2-disburse-" <> Ecto.UUID.generate()
                 },
                 prefix: schema_name
               )

      assert disburse_complete_result.instance_status == :completed

      {:ok, final_projection} = Instances.get_by_id(instance_id, prefix: schema_name)
      assert final_projection.status == :completed
      assert final_projection.current_nodes == []
    end
  end
end
