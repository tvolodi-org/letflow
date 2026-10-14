defmodule Letflow.Engine.Transition do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Pure transition kernel — ports `transition.zig`'s `transition()` (EE-02,
  `lib/letflow/design/req044-transition-kernel.md`, the gate-approved design
  this module implements). `transition/3`'s own header contract, quoted from
  `transition.zig`'s own header: **"All state is passed in; all output is
  returned. No DB, no network, no clock."**

  REQ-044 built the skeleton plus the 3 non-gateway node-type transitions
  (`:START`, `:END`, `:HUMAN_TASK`). REQ-050 (this requirement) replaces the
  `:EXCLUSIVE_GATEWAY` stub with the real declared-order, default-last,
  CEL-condition dispatch (`dispatch_exclusive_gateway/4`, EE-05,
  `lib/letflow/design/req050-exclusive-gateway-cel.md`), evaluating each
  condition via `Letflow.Engine.Expr.evaluate_condition/2`. `:PARALLEL_GATEWAY`
  (REQ-051) remains a named stub extension point (`dispatch_parallel_gateway/4`)
  that a later requirement's `ELIXIR-DEV` replaces without touching
  `dispatch_node/4`'s outer dispatch structure. `:SERVICE_TASK`, `:TIMER`,
  and `:SUB_PROCESS` (the 3 remaining variants of
  `Letflow.Definitions.Graph.node_type()`) fall through a single generic
  catch-all clause, kept total rather than raising.

  See `Letflow.Engine.InstanceState`'s moduledoc for two verbatim notes this
  design carries forward from the requirement text: the Zig `std.json.ObjectMap`
  allocator-ownership divergence, and the explicit REQ-043 dependency-ordering
  statement (this module and its two sibling files depend on REQ-028/REQ-029
  only, not on REQ-043's not-yet-built schema modules).

  ## Purity (AC1)

  `Letflow.Engine.Transition`, `Letflow.Engine.InstanceState`, and
  `Letflow.Engine.Token` depend on Elixir/Erlang stdlib only (`Enum`, `Map`,
  `Kernel`). No `alias Letflow.Repo`, no `import Ecto.Query`, no
  `Ecto.Changeset` anywhere in any of the 3 files. No `Logger.*` call. No
  clock read (`DateTime.utc_now/0`, `System.os_time/1`, `System.system_time/1`,
  or equivalent). No `File.*`/`HTTPoison`/`Req.*`/`:httpc`/process-mailbox call
  (`GenServer.call`, `send`, `receive`) anywhere in `transition/3`'s call
  graph, including every private `dispatch_*` function it calls into.
  REQ-187 extends `pending_event()` with a fourth variant,
  `{:timer_armed, token_id, node_id}` — SCH-01's timer-arming description
  travels through this same shape, exactly like `{:sub_process_start, ...}`
  before it; `dispatch_timer_arrival/3` reads only its own already-supplied
  `token`/`node.id` arguments and never resolves `node.attributes["duration_iso8601"]`
  or reads a clock, so this extension adds no new `Repo`/clock call.
  REQ-215 extends `pending_event()` with a fifth variant,
  `{:service_task_dispatch_requested, token_id, node_id}` — the token is
  appended to `InstanceState.pending_service_task_nodes`, a new list field
  disjoint from `pending_task_nodes` (§1.1 of
  `lib/letflow/design/req215-service-task-engine-wiring.md`).
  `dispatch_service_task/3` reads only its own already-supplied
  `token`/`node.id` arguments and never resolves `node.attributes`, renders a
  URL, or performs any HTTP/file call, so this extension adds no new impure
  dependency.

  Verification (grep/`mix xref`-checkable, matching the precedent
  `Letflow.Definitions.Graph`'s own design already established):

  ```bash
  grep -n "Repo\\.\\|Logger\\.\\|DateTime\\.\\|System\\.os_time\\|System\\.system_time\\|HTTPoison\\|Req\\.\\|File\\.\\|:rand\\.\\|:crypto\\." lib/letflow/engine/instance_state.ex lib/letflow/engine/token.ex lib/letflow/engine/transition.ex
  ```

  must return zero matches.

  ## Determinism (AC2)

  Calling `transition(definition_snapshot, instance_state, event)` twice with
  `==`-equal arguments returns `==`-equal results, both times. Every decision
  inside the dispatch is a pure function of its typed input alone: token/node
  lookups are ordinary linear scans over argument-supplied lists (no external
  state, no randomness, no `:ets`/process-mailbox read); `:START`'s "first
  outgoing edge in declaration order" is a deterministic function of
  `definition_snapshot.edges`'s own list order, itself part of the argument;
  no clock/`:rand`/`:crypto`/UUID-generation call appears anywhere in this
  module's call graph — every id (`token_id`, `instance_id`) is always
  supplied by the caller, never minted here.

  ## Single hop per call

  One `transition/3` call processes exactly one token through exactly one
  node-type dispatch and returns — it never recursively cascades a token
  through a chain of nodes within one call. A `:START` node whose outgoing
  edge leads directly into another pass-through node requires two separate
  `transition/3` calls, each driven by its own `{:advance_token, token_id}`
  event from the caller (design doc §5).
  """

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.Graph.Node
  alias Letflow.Engine.Expr
  alias Letflow.Engine.InstanceState
  alias Letflow.Engine.JoinCounter
  alias Letflow.Engine.Token
  alias Letflow.Engine.VariableMerge

  @typedoc """
  One event this module's dispatch reacts to. `{:advance_token, token_id}`
  is REQ-044's original constructor: "move the token identified by
  `token_id` one step according to whatever node type it currently
  occupies." `{:cancel_branch, branch_id}` is REQ-051's own addition (design
  doc §3.4) — the concrete, pure cancelled-branch representation this
  requirement itself defines (not deferred to REQ-052). `{:complete_task,
  token_id}` is REQ-048's own addition (EE-04,
  `lib/letflow/design/req048-task-completion.md` §5) — a token sitting on a
  `:HUMAN_TASK` node has no automatic outgoing traversal
  (`dispatch_human_task/3`'s own contract), so `{:advance_token, token_id}`
  cannot move it off that node; this constructor is the caller's explicit
  "this token's human task just completed, evaluate its outgoing edges"
  signal. `{:timer_fired, token_id}` is REQ-187's own addition
  (`lib/letflow/design/req187-timer-engine-wiring.md` §1.2) — mirrors
  `{:complete_task, token_id}` exactly: a token parked on a `:TIMER` node
  (no automatic outgoing traversal either) is moved off it only by this
  caller's explicit "this token's timer just fired, evaluate its outgoing
  edge" signal. Deliberately not a closed enumeration beyond these four —
  every later EE-* requirement that needs its own event shape adds its own
  tagged-tuple constructor to this same union (design doc §4, §12.5).
  """
  @type transition_event ::
          {:advance_token, token_id :: String.t()}
          | {:cancel_branch, branch_id :: String.t()}
          | {:complete_task, token_id :: String.t()}
          | {:sub_process_completed, token_id :: String.t()}
          | {:timer_fired, token_id :: String.t()}
          | {:escalation_timer_fired, token_id :: String.t()}

  @typedoc """
  PROVENANCE (historical, not current decision authority):
  The tagged union `transition.zig` declares for EE-06/EE-07 split/join
  payloads — narrowed here (design doc §5) from REQ-044's `term()`
  placeholder to a real closed union of the pending-event shapes various
  requirements' dispatch clauses construct: `{:parallel_split, ...}` (design
  doc §5.1), `{:parallel_join_fired, ...}` (§5.2), and
  `{:parallel_join_cancelled, ...}` (§5.3). `{:sub_process_start, token_id,
  node_id}` is req062's own addition — `dispatch_sub_process_entry/4` leaves
  the token in place and returns this instead of writing anything itself,
  the impure caller turning it into real child-instance rows.
  `{:timer_armed, token_id, node_id}` is REQ-187's own addition
  (`lib/letflow/design/req187-timer-engine-wiring.md` §1.1) — the same
  pattern's fourth variant: `dispatch_timer_arrival/3` leaves the token in
  place and returns this instead of resolving `duration_iso8601`/reading a
  clock itself; the impure caller re-resolves `node_id` against its own
  `Graph.t()` to compute `fire_at` and calls `Letflow.Scheduler.create/2`.
  It deliberately carries no duration and no timestamp.
  `{:service_task_dispatch_requested, token_id, node_id}` is REQ-215's own
  addition (`lib/letflow/design/req215-service-task-engine-wiring.md` §1.2)
  — the same pattern's fifth variant: `dispatch_service_task/3` leaves the
  token in place and returns this instead of parsing `node.attributes`,
  rendering a URL template, or performing any HTTP call itself; the impure
  caller re-resolves `node_id` against its own `Graph.t()`, parses the
  SERVICE_TASK config, renders/validates the URL, and INSERTs the first
  `service_task_dispatches` row. It carries no config and no HTTP detail.
  `{:reminder_timer_armed, token_id, node_id}` is REQ-494's own addition
  (`lib/letflow/design/req494-human-task-reminder-timer.md` §2.1) — emitted
  by `dispatch_human_task/3` after any `{:escalation_timer_armed, ...}` when
  the node carries both `reminder_timer_duration` and a non-blank
  `reminder_role`; the impure caller arms a non-cancelling `"reminder"` timer.
  """
  @type pending_event ::
          {:parallel_split, origin_token_id :: String.t(), gateway_node_id :: String.t(),
           branch_ids :: [String.t()]}
          | {:parallel_join_fired, join_node_id :: String.t(), origin_token_id :: String.t(),
             new_token_id :: String.t(), merge_events :: [VariableMerge.merge_event()]}
          | {:parallel_join_cancelled, join_node_id :: String.t(), origin_token_id :: String.t()}
          | {:sub_process_start, token_id :: String.t(), node_id :: String.t()}
          | {:timer_armed, token_id :: String.t(), node_id :: String.t()}
          | {:service_task_dispatch_requested, token_id :: String.t(), node_id :: String.t()}
          | {:escalation_timer_armed, token_id :: String.t(), node_id :: String.t()}
          | {:reminder_timer_armed, token_id :: String.t(), node_id :: String.t()}

  @typedoc """
  Every failure `transition/3` can return. `:unknown_event_type` and
  `:unknown_node_id` are the two explicit error paths the requirement text
  names; `:unknown_token_id` is this module's own defensive totality
  addition (a stale/nonexistent `token_id` is exactly as plausible an input
  as a stale/nonexistent `node_id`); `:gateway_not_yet_implemented` is
  retired from this module's own possible return values for
  `:PARALLEL_GATEWAY` (REQ-044's stub is fully replaced) but stays in the
  type union unchanged since `:EXCLUSIVE_GATEWAY` (REQ-050) still uses it;
  `:node_type_not_yet_implemented` is the generic node-type catch-all's
  error (design doc §4, §7). `:unknown_branch_id`, `:no_matching_join_found`,
  and `:combined_split_join_not_supported` are REQ-051's own additions
  (design doc §7). `:token_not_at_human_task` is REQ-048's own defensive
  addition — `{:complete_task, token_id}` dispatched against a token not
  currently sitting on a `:HUMAN_TASK` node (req048 design doc §5 point 1).
  `{:token_not_at_timer, node_type, node_id}` is REQ-187's own defensive
  addition, the same role for `{:timer_fired, token_id}` dispatched against
  a token not currently sitting on a `:TIMER` node (design doc §1.3).
  """
  @type transition_error ::
          {:unknown_event_type, event :: term()}
          | {:unknown_token_id, token_id :: String.t()}
          | {:unknown_node_id, node_id :: String.t()}
          | {:gateway_not_yet_implemented, node_type :: atom(), node_id :: String.t()}
          | {:node_type_not_yet_implemented, node_type :: atom(), node_id :: String.t()}
          | {:no_matching_edge, node_id :: String.t(),
             evaluated_conditions :: [evaluated_condition()]}
          | {:unknown_branch_id, branch_id :: String.t()}
          | {:no_matching_join_found, split_node_id :: String.t()}
          | {:combined_split_join_not_supported, node_id :: String.t()}
          | {:token_not_at_human_task, node_type :: atom(), node_id :: String.t()}
          | {:token_not_waiting_on_child, node_type :: atom(), node_id :: String.t()}
          | {:token_not_at_timer, node_type :: atom(), node_id :: String.t()}
          | {:token_not_at_human_task_for_escalation, node_type :: atom(), node_id :: String.t()}

  @typedoc """
  One entry per non-default outgoing edge of an `:EXCLUSIVE_GATEWAY` whose
  condition was actually evaluated before dispatch gave up (REQ-050 design
  doc §3). `condition` is always the edge's original CEL-syntax string
  (`Edge.t().condition`), never the translated expr-syntax string or the
  parsed AST — an operator reading a persisted error tuple sees the same
  condition text authored in the definition graph.
  """
  @type evaluated_condition :: %{
          edge_id: String.t(),
          condition: String.t(),
          result: boolean()
        }

  @doc """
  Advances one token by one hop according to `event`, resolving its current
  node against `definition_snapshot` and dispatching on that node's
  `node_type`. Never raises: an unrecognized `event` shape, an unknown
  `token_id`, or a token positioned on a `node_id` absent from
  `definition_snapshot` all return a named `{:error, transition_error()}`
  tuple instead of crashing (design doc §6, §7).
  """
  @spec transition(Graph.t(), InstanceState.t(), transition_event()) ::
          {:ok, InstanceState.t(), [pending_event()]}
          | {:error, transition_error()}
  def transition(%Graph{} = definition_snapshot, %InstanceState{} = instance_state, event) do
    case event do
      {:advance_token, token_id} ->
        case find_token(instance_state.tokens, token_id) do
          nil ->
            {:error, {:unknown_token_id, token_id}}

          token ->
            case find_node(definition_snapshot.nodes, token.node_id) do
              nil ->
                {:error, {:unknown_node_id, token.node_id}}

              node ->
                dispatch_node(definition_snapshot, instance_state, token, node)
            end
        end

      {:cancel_branch, branch_id} ->
        dispatch_cancel_branch(definition_snapshot, instance_state, branch_id)

      {:complete_task, token_id} ->
        case find_token(instance_state.tokens, token_id) do
          nil ->
            {:error, {:unknown_token_id, token_id}}

          token ->
            case find_node(definition_snapshot.nodes, token.node_id) do
              nil ->
                {:error, {:unknown_node_id, token.node_id}}

              node ->
                dispatch_task_completion(definition_snapshot, instance_state, token, node)
            end
        end

      {:sub_process_completed, token_id} ->
        case find_token(instance_state.tokens, token_id) do
          nil ->
            {:error, {:unknown_token_id, token_id}}

          token ->
            case find_node(definition_snapshot.nodes, token.node_id) do
              nil ->
                {:error, {:unknown_node_id, token.node_id}}

              node ->
                dispatch_sub_process_completion(definition_snapshot, instance_state, token, node)
            end
        end

      {:timer_fired, token_id} ->
        case find_token(instance_state.tokens, token_id) do
          nil ->
            {:error, {:unknown_token_id, token_id}}

          token ->
            case find_node(definition_snapshot.nodes, token.node_id) do
              nil ->
                {:error, {:unknown_node_id, token.node_id}}

              node ->
                dispatch_timer_fired(definition_snapshot, instance_state, token, node)
            end
        end

      {:escalation_timer_fired, token_id} ->
        case find_token(instance_state.tokens, token_id) do
          nil ->
            {:error, {:unknown_token_id, token_id}}

          token ->
            case find_node(definition_snapshot.nodes, token.node_id) do
              nil ->
                {:error, {:unknown_node_id, token.node_id}}

              node ->
                dispatch_escalation_timer_fired(definition_snapshot, instance_state, token, node)
            end
        end

      other ->
        {:error, {:unknown_event_type, other}}
    end
  end

  # Dispatches one already-resolved `token`/`node` pair to the behavior for
  # `node.node_type` -- the 5-way (+1 catch-all) table from design doc §6.
  # Every clause below is a specialization of this one @spec -- no per-clause
  # @spec is separately declared, matching graph.ex's one-@spec-per-function-
  # name convention even where the implementation has multiple pattern-
  # matched clauses.
  @spec dispatch_node(Graph.t(), InstanceState.t(), Token.t(), Node.t()) ::
          {:ok, InstanceState.t(), [pending_event()]}
          | {:error, transition_error()}
  defp dispatch_node(definition_snapshot, instance_state, token, %Node{node_type: :START} = node) do
    dispatch_start(definition_snapshot, instance_state, token, node)
  end

  defp dispatch_node(_definition_snapshot, instance_state, token, %Node{node_type: :END} = node) do
    dispatch_end(instance_state, token, node)
  end

  defp dispatch_node(
         _definition_snapshot,
         instance_state,
         token,
         %Node{node_type: :HUMAN_TASK} = node
       ) do
    dispatch_human_task(instance_state, token, node)
  end

  defp dispatch_node(
         definition_snapshot,
         instance_state,
         token,
         %Node{node_type: :EXCLUSIVE_GATEWAY} = node
       ) do
    dispatch_exclusive_gateway(definition_snapshot, instance_state, token, node)
  end

  defp dispatch_node(
         definition_snapshot,
         instance_state,
         token,
         %Node{node_type: :PARALLEL_GATEWAY} = node
       ) do
    dispatch_parallel_gateway(definition_snapshot, instance_state, token, node)
  end

  defp dispatch_node(
         definition_snapshot,
         instance_state,
         token,
         %Node{node_type: :SUB_PROCESS} = node
       ) do
    dispatch_sub_process_entry(definition_snapshot, instance_state, token, node)
  end

  defp dispatch_node(_definition_snapshot, instance_state, token, %Node{node_type: :TIMER} = node) do
    dispatch_timer_arrival(instance_state, token, node)
  end

  defp dispatch_node(
         _definition_snapshot,
         instance_state,
         token,
         %Node{node_type: :SERVICE_TASK} = node
       ) do
    dispatch_service_task(instance_state, token, node)
  end

  # Catch-all: any node whose node_type is not one of the 8 known atoms at
  # all (every real Letflow.Definitions.Graph.node_type() variant now has
  # its own dispatch_node/4 clause above, REQ-215's :SERVICE_TASK clause
  # being the last). Necessary for transition/3 to be total over every value
  # Node.t().node_type can actually hold -- a partial match with no
  # catch-all clause would raise on any of these, violating the purity
  # contract's "never raise" bar (design doc §6.6).
  defp dispatch_node(_definition_snapshot, _instance_state, _token, %Node{
         node_type: node_type,
         id: node_id
       }) do
    {:error, {:node_type_not_yet_implemented, node_type, node_id}}
  end

  # --- :START (design doc §6.1) ----------------------------------------------

  # Advances the token onto the target of its first outgoing edge in
  # declaration order. A structurally-valid graph (CHK-04, REQ-028)
  # guarantees at least one outgoing edge from START; the `nil` branch below
  # is a defensive, never-raising fallback for a `definition_snapshot` that
  # violates that upstream invariant, not a literal AC3 case -- flagged here
  # per the design doc's own §7.3 precedent for defensive additions beyond
  # the literal acceptance criteria.
  defp dispatch_start(
         definition_snapshot,
         %InstanceState{} = instance_state,
         %Token{} = token,
         node
       ) do
    case Enum.find(definition_snapshot.edges, &(&1.source == node.id)) do
      nil ->
        {:error, {:unknown_node_id, node.id}}

      edge ->
        new_token = %Token{token | node_id: edge.target}
        new_tokens = replace_token(instance_state.tokens, new_token)
        {:ok, %InstanceState{instance_state | tokens: new_tokens}, []}
    end
  end

  # --- :END (design doc §6.2) -------------------------------------------------

  # Removes the affected token from `tokens`. Instance status becomes
  # `:completed` iff no token remains live afterward; otherwise unchanged
  # (other branches may still be executing, relevant once REQ-051's
  # PARALLEL_GATEWAY split can produce more than one live token).
  defp dispatch_end(%InstanceState{} = instance_state, token, _node) do
    remaining_tokens = Enum.reject(instance_state.tokens, &(&1.token_id == token.token_id))

    new_status = if remaining_tokens == [], do: :completed, else: instance_state.status

    {:ok, %InstanceState{instance_state | tokens: remaining_tokens, status: new_status}, []}
  end

  # --- :HUMAN_TASK (design doc §6.3) ------------------------------------------

  # The token's position is not changed -- a HUMAN_TASK node has no
  # automatic outgoing traversal. The same Token.t() value is appended to
  # pending_task_nodes; this is the only dispatch clause that ever appends
  # to it (the guard for REQ-047's future tasks-row materialization).
  # REQ-396: if the node carries escalation_timer_duration, also emits an
  # {:escalation_timer_armed, token_id, node_id} pending_event so the impure
  # caller (Letflow.Engine) can arm the escalation timer via
  # Letflow.Scheduler.create/2 -- mirrors {:timer_armed, ...}'s pattern.
  defp dispatch_human_task(%InstanceState{} = instance_state, token, node) do
    new_pending = instance_state.pending_task_nodes ++ [token]
    new_state = %InstanceState{instance_state | pending_task_nodes: new_pending}

    escalation_events =
      case get_in(node, [Access.key(:attributes), Access.key("escalation_timer_duration")]) do
        value when is_binary(value) and byte_size(value) > 0 ->
          [{:escalation_timer_armed, token.token_id, node.id}]

        _ ->
          []
      end

    # REQ-494: a reminder is armed only when BOTH the duration and a
    # non-blank reminder_role are present (design §2.1) -- a stray duration
    # on a definition activated before CHK-28 stays inert.
    attributes = Map.get(node, :attributes)

    reminder_events =
      with %{} <- attributes,
           duration when is_binary(duration) and byte_size(duration) > 0 <-
             Map.get(attributes, "reminder_timer_duration"),
           role when is_binary(role) <- Map.get(attributes, "reminder_role"),
           false <- String.trim(role) == "" do
        [{:reminder_timer_armed, token.token_id, node.id}]
      else
        _ -> []
      end

    {:ok, new_state, escalation_events ++ reminder_events}
  end

  # --- {:complete_task, token_id} (REQ-048 design doc §5, EE-04) -------------

  # Moves a token off the :HUMAN_TASK node it is currently sitting on, once
  # its task has completed -- the caller's own explicit signal that the
  # "no automatic outgoing traversal" stop dispatch_human_task/3 left it at
  # is now over. Never appends to pending_task_nodes (design doc §5 point 3,
  # INV-EE48-6) -- only dispatch_human_task/3 does that.
  #
  # Deliberate, empirically-forced divergence from req048 design doc §5
  # point 2's literal text: that section claimed reusing
  # dispatch_exclusive_gateway/4's exact partition-by-is_default algorithm
  # "degrades to the one default/unconditioned edge wins" for a HUMAN_TASK's
  # single, unconditioned outgoing edge. Confirmed FALSE by direct execution
  # against real Postgres while implementing this requirement: REQ-029's
  # CHK-13 (which forces every non-default EXCLUSIVE_GATEWAY edge to carry a
  # real, non-empty condition, making dispatch_exclusive_gateway/4's
  # is_default-only partition safe there) is scoped to :EXCLUSIVE_GATEWAY
  # sources only (confirmed against graph.ex's own exclusive_gateway_source?/3
  # guard) -- a :HUMAN_TASK's own outgoing edges carry no such guarantee. The
  # ordinary, structurally-valid, single-unconditioned-edge HUMAN_TASK (no
  # `is_default`, no `condition`) is the overwhelmingly common real-world
  # shape and is exactly AC1's own scenario; reusing the exact
  # is_default-only partition sent that edge into the "conditioned" bucket,
  # evaluated Expr.evaluate_condition(nil, _) (always false), found no match,
  # found no default_edge (is_default was never set), and returned
  # {:error, {:no_matching_edge, ...}} on every ordinary completion -- not an
  # edge case, the common path. Fixed here by partitioning on "carries a
  # real, non-empty condition and isn't explicitly is_default" instead of on
  # is_default alone: an edge with `condition: nil` (or `""`), same as one
  # explicitly marked `is_default: true`, is treated as a default/fallback
  # candidate. dispatch_exclusive_gateway/4 itself is left completely
  # unmodified (this fix is local to this new function only). Flagged
  # prominently for REVIEWER -- this is a correctness fix to newly-added
  # logic discovered via direct smoke testing, not a silent re-decision of
  # any already-shipped, gate-approved behavior.
  @spec dispatch_task_completion(Graph.t(), InstanceState.t(), Token.t(), Node.t()) ::
          {:ok, InstanceState.t(), [pending_event()]}
          | {:error, {:token_not_at_human_task, node_type :: atom(), node_id :: String.t()}}
          | {:error,
             {:no_matching_edge, node_id :: String.t(),
              evaluated_conditions :: [evaluated_condition()]}}
  defp dispatch_task_completion(
         definition_snapshot,
         %InstanceState{} = instance_state,
         %Token{} = token,
         %Node{node_type: :HUMAN_TASK} = node
       ) do
    outgoing_edges = Enum.filter(definition_snapshot.edges, &(&1.source == node.id))
    advance_off_completed_node(definition_snapshot, instance_state, token, outgoing_edges)
  end

  # Defensive guard against a stale/mismatched task.token_id <-> token_record
  # node_id pairing -- should be unreachable given Letflow.Engine's own
  # reconstruction invariant, kept for this codebase's "never raise" totality
  # discipline (design doc §5 point 1).
  defp dispatch_task_completion(_definition_snapshot, _instance_state, _token, %Node{
         node_type: node_type,
         id: node_id
       }) do
    {:error, {:token_not_at_human_task, node_type, node_id}}
  end

  # Shared edge-partition/advance step (req062 design doc §2.4) -- extracted
  # from dispatch_task_completion/4's own body so dispatch_sub_process_completion/4
  # (below) reuses the exact same "declared-order, default-last" completion
  # algorithm instead of a second copy of the partition rule. `token` is
  # already the caller's own post-clear/pre-advance value (dispatch_task_completion/4
  # passes the token unchanged; dispatch_sub_process_completion/4 passes a
  # struct-updated copy with waiting_child_instance_id already cleared) --
  # this function itself performs no clearing, only edge evaluation +
  # advance_token/3.
  #
  # REQ-215 design doc §1.5 -- widened from `defp` to `@doc false def` so
  # Letflow.Engine.advance_after_service_task_outcome/4 (a different module)
  # can reuse this exact algorithm directly, rather than adding a second,
  # redundant public wrapper with no new logic (Decision (a), matching
  # advance_after_timer_fired/3's own technically-public-but-undocumented
  # cross-module precedent, engine.ex:1895). Body unchanged.
  @doc false
  @spec advance_off_completed_node(Graph.t(), InstanceState.t(), Token.t(), [Graph.Edge.t()]) ::
          {:ok, InstanceState.t(), [pending_event()]}
          | {:error,
             {:no_matching_edge, node_id :: String.t(),
              evaluated_conditions :: [evaluated_condition()]}}
  def advance_off_completed_node(_definition_snapshot, instance_state, token, outgoing_edges) do
    {conditioned_edges, default_candidates} =
      Enum.split_with(outgoing_edges, &really_conditioned?/1)

    default_edge = List.first(default_candidates)

    case evaluate_conditioned_edges(conditioned_edges, instance_state.variables) do
      {:match, edge} ->
        advance_token(instance_state, token, edge.target)

      {:no_match, evaluated_conditions} ->
        case default_edge do
          nil ->
            {:error, {:no_matching_edge, token.node_id, evaluated_conditions}}

          edge ->
            advance_token(instance_state, token, edge.target)
        end
    end
  end

  # An edge is "really conditioned" only if it isn't explicitly is_default
  # AND it carries a real, non-empty CEL condition string -- everything else
  # (is_default: true, or condition nil/"") is a default/fallback candidate.
  # See dispatch_task_completion/4's own comment above for why this
  # partition (rather than dispatch_exclusive_gateway/4's is_default-only
  # one) is needed for a :HUMAN_TASK's outgoing edges specifically.
  @spec really_conditioned?(Graph.Edge.t()) :: boolean()
  defp really_conditioned?(%Graph.Edge{is_default: is_default, condition: condition}) do
    is_default != true and is_binary(condition) and condition != ""
  end

  # --- :SUB_PROCESS (req062 design doc §2.3, §2.4, SPC-01) -------------------

  # Entry: a token landing on (or already re-dispatched against) a
  # :SUB_PROCESS node. Zero I/O, zero child creation here -- Letflow.Engine.Transition
  # may never perform a DB write (this module's own "Purity" moduledoc
  # section); all actual child-instance work happens at the Letflow.Engine
  # layer, triggered by the {:sub_process_start, ...} pending_event() this
  # clause emits. Guards a caller re-dispatching a token that already has a
  # child running (defensive -- tokens_needing_dispatch/3 should never
  # re-select this token_id anyway since its node_id never changes once
  # parked here, but this clause does not rely on that caller discipline).
  @spec dispatch_sub_process_entry(Graph.t(), InstanceState.t(), Token.t(), Node.t()) ::
          {:ok, InstanceState.t(), [pending_event()]}
  defp dispatch_sub_process_entry(
         _definition_snapshot,
         %InstanceState{} = instance_state,
         %Token{waiting_child_instance_id: waiting_child_instance_id},
         _node
       )
       when not is_nil(waiting_child_instance_id) do
    {:ok, instance_state, []}
  end

  defp dispatch_sub_process_entry(
         _definition_snapshot,
         %InstanceState{} = instance_state,
         %Token{} = token,
         %Node{} = node
       ) do
    {:ok, instance_state, [{:sub_process_start, token.token_id, node.id}]}
  end

  # Completion: the caller's explicit "this token's child instance finished,
  # and instance_state.variables already reflects the already-filtered
  # (interface.outputs-only, or full-map under EXT-05) merged output" signal
  # -- parallel to dispatch_task_completion/4's own contract. Defensive guard
  # mirrors dispatch_task_completion/4's own defensive clause: a token not
  # currently waiting on a child, or a node that isn't :SUB_PROCESS, is a
  # typed error rather than a raise (should be unreachable given
  # Letflow.Engine's own lookup invariant, kept for this codebase's "never
  # raise" totality discipline).
  @spec dispatch_sub_process_completion(Graph.t(), InstanceState.t(), Token.t(), Node.t()) ::
          {:ok, InstanceState.t(), [pending_event()]}
          | {:error, {:token_not_waiting_on_child, node_type :: atom(), node_id :: String.t()}}
          | {:error,
             {:no_matching_edge, node_id :: String.t(),
              evaluated_conditions :: [evaluated_condition()]}}
  defp dispatch_sub_process_completion(
         definition_snapshot,
         %InstanceState{} = instance_state,
         %Token{} = token,
         %Node{} = node
       ) do
    if is_nil(token.waiting_child_instance_id) or node.node_type != :SUB_PROCESS do
      {:error, {:token_not_waiting_on_child, node.node_type, node.id}}
    else
      cleared_token = %Token{token | waiting_child_instance_id: nil}
      outgoing_edges = Enum.filter(definition_snapshot.edges, &(&1.source == node.id))

      advance_off_completed_node(
        definition_snapshot,
        instance_state,
        cleared_token,
        outgoing_edges
      )
    end
  end

  # --- :TIMER (REQ-187 design doc §1.4) ---------------------------------------

  # Entry: a token landing on a :TIMER node. The token's position is not
  # changed -- a :TIMER node has no automatic outgoing traversal, exactly
  # like :HUMAN_TASK. Zero I/O, zero clock read here -- this module's own
  # "Purity" moduledoc section; resolving node.attributes["duration_iso8601"]
  # into a fire_at timestamp is entirely the impure caller's job
  # (Letflow.Engine's prepare_timer_arms/4), triggered by the
  # {:timer_armed, ...} pending_event() this clause emits. Unlike
  # dispatch_human_task/3, does not touch pending_task_nodes -- that list is
  # :HUMAN_TASK-specific bookkeeping for TaskActivation's own tasks-row
  # materialization; a :TIMER node needs no tasks row.
  @spec dispatch_timer_arrival(InstanceState.t(), Token.t(), Node.t()) ::
          {:ok, InstanceState.t(), [pending_event()]}
  defp dispatch_timer_arrival(%InstanceState{} = instance_state, %Token{} = token, %Node{} = node) do
    {:ok, instance_state, [{:timer_armed, token.token_id, node.id}]}
  end

  # {:timer_fired, token_id} (design doc §1.4) -- the caller's explicit
  # "this token's timer just fired, evaluate its outgoing edge" signal,
  # mirroring dispatch_task_completion/4's own shape and contract exactly.
  @spec dispatch_timer_fired(Graph.t(), InstanceState.t(), Token.t(), Node.t()) ::
          {:ok, InstanceState.t(), [pending_event()]}
          | {:error, {:token_not_at_timer, node_type :: atom(), node_id :: String.t()}}
          | {:error,
             {:no_matching_edge, node_id :: String.t(),
              evaluated_conditions :: [evaluated_condition()]}}
  defp dispatch_timer_fired(
         definition_snapshot,
         %InstanceState{} = instance_state,
         %Token{} = token,
         %Node{node_type: :TIMER} = node
       ) do
    outgoing_edges = Enum.filter(definition_snapshot.edges, &(&1.source == node.id))
    advance_off_completed_node(definition_snapshot, instance_state, token, outgoing_edges)
  end

  # Defensive guard, mirroring dispatch_task_completion/4's own second
  # clause -- should be unreachable given Letflow.Engine's own reconstruction
  # invariant, kept for this codebase's "never raise" totality discipline
  # (design doc §1.4).
  defp dispatch_timer_fired(_definition_snapshot, _instance_state, _token, %Node{
         node_type: node_type,
         id: node_id
       }) do
    {:error, {:token_not_at_timer, node_type, node_id}}
  end

  # {:escalation_timer_fired, token_id} (REQ-396 design doc §4.1) -- the
  # caller's explicit "this escalation timer just fired, advance token off
  # the :HUMAN_TASK via its default/fallback edge" signal. Unlike
  # {:complete_task, token_id}, conditioned edges are skipped entirely --
  # escalation fires unconditionally via the fallback path (the human did not
  # act within the deadline, so no decision variable is set).
  @spec dispatch_escalation_timer_fired(Graph.t(), InstanceState.t(), Token.t(), Node.t()) ::
          {:ok, InstanceState.t(), [pending_event()]}
          | {:error,
             {:token_not_at_human_task_for_escalation, node_type :: atom(), node_id :: String.t()}}
          | {:error,
             {:no_matching_edge, node_id :: String.t(),
              evaluated_conditions :: [evaluated_condition()]}}
  defp dispatch_escalation_timer_fired(
         definition_snapshot,
         %InstanceState{} = instance_state,
         %Token{} = token,
         %Node{node_type: :HUMAN_TASK} = node
       ) do
    # Skip conditioned edges entirely -- unconditionally follow the fallback edge.
    outgoing_edges = Enum.filter(definition_snapshot.edges, &(&1.source == node.id))

    {_conditioned, default_edges} =
      Enum.split_with(outgoing_edges, &really_conditioned?/1)

    case List.first(default_edges) do
      nil ->
        {:error, {:no_matching_edge, node.id, []}}

      edge ->
        advance_token(instance_state, token, edge.target)
    end
  end

  # Defensive guard -- should be unreachable (advance_after_escalation_timer_fired/3
  # in Letflow.Engine verifies the token is at a :HUMAN_TASK before dispatching),
  # kept for totality discipline.
  defp dispatch_escalation_timer_fired(
         _definition_snapshot,
         _instance_state,
         _token,
         %Node{node_type: node_type, id: node_id}
       ) do
    {:error, {:token_not_at_human_task_for_escalation, node_type, node_id}}
  end

  # --- :SERVICE_TASK (REQ-215 design doc §1.4) --------------------------------

  # Entry: a token landing on a :SERVICE_TASK node. The token's position is
  # not changed -- a :SERVICE_TASK node has no automatic outgoing traversal,
  # the same async-park shape as dispatch_human_task/3 (§0 precedent table).
  # Zero I/O, zero HTTP call here -- this module's own "Purity" moduledoc
  # section; resolving node.attributes into a Config.t(), rendering the URL
  # template, and INSERTing the first service_task_dispatches row is
  # entirely the impure caller's job (Letflow.Engine's
  # prepare_service_task_dispatch/5), triggered by the
  # {:service_task_dispatch_requested, ...} pending_event() this clause
  # emits. The token is appended to pending_service_task_nodes (§1.1's new
  # InstanceState field, disjoint from pending_task_nodes) -- mirrors
  # dispatch_human_task/3's exact "append to a list field, emit one park
  # event, unchanged token position" shape, with pending_task_nodes swapped
  # for pending_service_task_nodes.
  @spec dispatch_service_task(InstanceState.t(), Token.t(), Node.t()) ::
          {:ok, InstanceState.t(), [pending_event()]}
  defp dispatch_service_task(%InstanceState{} = instance_state, %Token{} = token, %Node{} = node) do
    new_pending = instance_state.pending_service_task_nodes ++ [token]

    {:ok, %InstanceState{instance_state | pending_service_task_nodes: new_pending},
     [{:service_task_dispatch_requested, token.token_id, node.id}]}
  end

  # --- :EXCLUSIVE_GATEWAY (REQ-050 design doc §5, EE-05) ----------------------

  # Declared-order, default-last, first-true-wins dispatch. Relies on
  # REQ-029's CHK-13..CHK-16 invariants (design doc §6) without
  # re-validating them here: a default edge never carries a condition, at
  # most one default edge exists per gateway, and every non-default
  # outgoing edge carries a non-empty condition string.
  @spec dispatch_exclusive_gateway(Graph.t(), InstanceState.t(), Token.t(), Node.t()) ::
          {:ok, InstanceState.t(), [pending_event()]}
          | {:error,
             {:no_matching_edge, node_id :: String.t(),
              evaluated_conditions :: [evaluated_condition()]}}
  defp dispatch_exclusive_gateway(
         definition_snapshot,
         %InstanceState{} = instance_state,
         %Token{} = token,
         node
       ) do
    outgoing_edges = Enum.filter(definition_snapshot.edges, &(&1.source == node.id))
    {conditioned_edges, default_edges} = Enum.split_with(outgoing_edges, &(&1.is_default != true))
    default_edge = List.first(default_edges)

    case evaluate_conditioned_edges(conditioned_edges, instance_state.variables) do
      {:match, edge} ->
        advance_token(instance_state, token, edge.target)

      {:no_match, evaluated_conditions} ->
        case default_edge do
          nil ->
            {:error, {:no_matching_edge, node.id, evaluated_conditions}}

          edge ->
            advance_token(instance_state, token, edge.target)
        end
    end
  end

  # Walks conditioned_edges in declared order, short-circuiting on the
  # first edge whose Expr.evaluate_condition/2 call returns true. A
  # condition that raises a runtime error (translation, parse, or eval
  # error, including the unsupported-CEL-feature case) is folded into
  # `false` by Expr.evaluate_condition/2 itself -- there is no separate
  # "error" branch here, matching design doc §5.2's uniform catch-false
  # rule.
  @spec evaluate_conditioned_edges([Graph.Edge.t()], map()) ::
          {:match, Graph.Edge.t()} | {:no_match, [evaluated_condition()]}
  defp evaluate_conditioned_edges(conditioned_edges, variables) do
    evaluate_conditioned_edges(conditioned_edges, variables, [])
  end

  @spec evaluate_conditioned_edges([Graph.Edge.t()], map(), [evaluated_condition()]) ::
          {:match, Graph.Edge.t()} | {:no_match, [evaluated_condition()]}
  defp evaluate_conditioned_edges([], _variables, acc), do: {:no_match, Enum.reverse(acc)}

  defp evaluate_conditioned_edges([edge | rest], variables, acc) do
    if Expr.evaluate_condition(edge.condition, variables) do
      {:match, edge}
    else
      entry = %{edge_id: edge.id, condition: edge.condition, result: false}
      evaluate_conditioned_edges(rest, variables, [entry | acc])
    end
  end

  # Advances token onto target_node_id, preserving instance_state's other
  # fields -- same shape as dispatch_start/4's success path.
  @spec advance_token(InstanceState.t(), Token.t(), String.t()) ::
          {:ok, InstanceState.t(), [pending_event()]}
  defp advance_token(%InstanceState{} = instance_state, %Token{} = token, target_node_id) do
    new_token = %Token{token | node_id: target_node_id}
    new_tokens = replace_token(instance_state.tokens, new_token)
    {:ok, %InstanceState{instance_state | tokens: new_tokens}, []}
  end

  # --- :PARALLEL_GATEWAY (design doc §3-§4, REQ-051's EE-06/EE-07 body) ------

  # Replaces REQ-044's stub. Routes on gateway_role/2's classification of
  # this node's own in/out-degree -- never raises for any of the 4 possible
  # roles (design doc §3).
  @spec dispatch_parallel_gateway(Graph.t(), InstanceState.t(), Token.t(), Node.t()) ::
          {:ok, InstanceState.t(), [pending_event()]}
          | {:error, transition_error()}
  defp dispatch_parallel_gateway(
         definition_snapshot,
         %InstanceState{} = instance_state,
         %Token{} = token,
         node
       ) do
    case gateway_role(definition_snapshot, node) do
      :split ->
        dispatch_parallel_split(definition_snapshot, instance_state, token, node)

      :join ->
        dispatch_parallel_join(definition_snapshot, instance_state, token, node)

      :pass_through ->
        case Enum.find(definition_snapshot.edges, &(&1.source == node.id)) do
          nil ->
            {:error, {:unknown_node_id, node.id}}

          edge ->
            new_token = %Token{token | node_id: edge.target}
            new_tokens = replace_token(instance_state.tokens, new_token)
            {:ok, %InstanceState{instance_state | tokens: new_tokens}, []}
        end

      :combined_unsupported ->
        {:error, {:combined_split_join_not_supported, node.id}}
    end
  end

  # design doc §3 -- classifies a PARALLEL_GATEWAY node's role purely from
  # its own in/out-degree within definition_snapshot.edges.
  @type gateway_role :: :split | :join | :pass_through | :combined_unsupported

  @spec gateway_role(Graph.t(), Node.t()) :: gateway_role()
  defp gateway_role(definition_snapshot, node) do
    out_degree = Enum.count(definition_snapshot.edges, &(&1.source == node.id))
    in_degree = Enum.count(definition_snapshot.edges, &(&1.target == node.id))

    cond do
      out_degree > 1 and in_degree > 1 -> :combined_unsupported
      out_degree > 1 -> :split
      in_degree > 1 -> :join
      true -> :pass_through
    end
  end

  # --- SPLIT (design doc §3.1, EE-06 AC1-AC3) ---------------------------------

  @spec dispatch_parallel_split(Graph.t(), InstanceState.t(), Token.t(), Node.t()) ::
          {:ok, InstanceState.t(), [pending_event()]}
          | {:error, transition_error()}
  defp dispatch_parallel_split(
         definition_snapshot,
         %InstanceState{} = instance_state,
         token,
         node
       ) do
    edges_out = Enum.filter(definition_snapshot.edges, &(&1.source == node.id))

    new_tokens =
      edges_out
      |> Enum.with_index()
      |> Enum.map(fn {edge, index} ->
        derived_id = token.token_id <> "/" <> Integer.to_string(index)

        %Token{
          token_id: derived_id,
          branch_id: derived_id,
          node_id: edge.target,
          waiting_child_instance_id: nil
        }
      end)

    branch_ids = Enum.map(new_tokens, & &1.branch_id)

    case find_matching_join(definition_snapshot, node) do
      {:error, :no_matching_join} ->
        {:error, {:no_matching_join_found, node.id}}

      {:ok, join_node_id} ->
        new_counter = %JoinCounter{
          join_node_id: join_node_id,
          origin_token_id: token.token_id,
          expected_from_branches: MapSet.new(branch_ids),
          received_from_branches: MapSet.new(),
          cancelled_branches: MapSet.new()
        }

        updated_join_counters = Map.put(instance_state.join_counters, join_node_id, new_counter)

        updated_tokens =
          Enum.reject(instance_state.tokens, &(&1.token_id == token.token_id)) ++ new_tokens

        pending_event = {:parallel_split, token.token_id, node.id, branch_ids}

        {:ok,
         %InstanceState{
           instance_state
           | tokens: updated_tokens,
             join_counters: updated_join_counters
         }, [pending_event]}
    end
  end

  # design doc (lib/letflow/design/iss0398-walk-to-gateway-fix.md) §2.5 -- for
  # each split-edge's target, collect_leaf_gateways/3 explores every path
  # forward through the branch's subtree; a branch resolves only if its leaf
  # set is a singleton {:gateway, id} (any dead end, or any internal
  # disagreement between its own paths, fails the branch). Cross-branch
  # agreement (every branch must resolve to the *same* gateway id) is
  # unchanged from the original design (req051 §3.3). Threads a single
  # leaf_search_state() across the split node's sibling branches: `memo`
  # genuinely survives from one branch to the next (§2.2.3 proves this is
  # always safe -- a top-level call's own Tarjan stack is always fully
  # unwound by the time it returns), while `index`/`lowlink`/`stack`/
  # `stack_set`/`next_index` are reset to empty/`0` before every branch (a
  # previous branch's index numbering is meaningless to a fresh top-level
  # call).
  @spec find_matching_join(Graph.t(), Node.t()) ::
          {:ok, join_node_id :: String.t()} | {:error, :no_matching_join}
  defp find_matching_join(definition_snapshot, node) do
    edges_out = Enum.filter(definition_snapshot.edges, &(&1.source == node.id))

    edges_out
    |> Enum.reduce_while({:ok, nil, fresh_leaf_search_state()}, fn edge,
                                                                   {:ok, acc_join_id, state} ->
      state = reset_stack_bookkeeping(state)
      {_tag, leaves, state} = collect_leaf_gateways(definition_snapshot, edge.target, state)

      case MapSet.to_list(leaves) do
        [{:gateway, gateway_id}] ->
          cond do
            acc_join_id == nil -> {:cont, {:ok, gateway_id, state}}
            acc_join_id == gateway_id -> {:cont, {:ok, acc_join_id, state}}
            true -> {:halt, {:error, :no_matching_join}}
          end

        _not_a_singleton_gateway ->
          {:halt, {:error, :no_matching_join}}
      end
    end)
    |> case do
      {:ok, nil, _state} -> {:error, :no_matching_join}
      {:ok, gateway_id, _state} -> {:ok, gateway_id}
      {:error, :no_matching_join} -> {:error, :no_matching_join}
    end
  end

  @type branch_leaf :: {:gateway, String.t()} | :dead_end

  @typedoc """
  design doc §2.2.2 -- the memoized-Tarjan-SCC-DFS accumulator threaded
  through `collect_leaf_gateways/3`. `memo` is the only field that survives
  across sibling top-level branch calls (`find_matching_join/2`'s own fold);
  `index`/`lowlink`/`stack`/`stack_set`/`next_index` are Tarjan's own
  single-pass bookkeeping, reset to empty/`0` at the start of every
  top-level branch call.
  """
  @type leaf_search_state :: %{
          memo: %{optional(String.t()) => MapSet.t(branch_leaf())},
          index: %{optional(String.t()) => non_neg_integer()},
          lowlink: %{optional(String.t()) => non_neg_integer()},
          stack: [String.t()],
          stack_set: MapSet.t(String.t()),
          next_index: non_neg_integer()
        }

  @typedoc """
  design doc §2.2.2 -- `:finished` means `node_id`'s SCC has closed and its
  aggregate leaf set is final (safe to memoize/reuse forever); `{:open,
  lowlink}` means `node_id` is still on the Tarjan stack (part of a
  not-yet-closed SCC further up the call chain), carrying the lowest `index`
  reachable so far so the caller can fold it into its own `local_lowlink`.
  """
  @type leaf_search_result :: :finished | {:open, lowlink :: non_neg_integer()}

  @spec fresh_leaf_search_state() :: leaf_search_state()
  defp fresh_leaf_search_state do
    %{memo: %{}, index: %{}, lowlink: %{}, stack: [], stack_set: MapSet.new(), next_index: 0}
  end

  # §2.2.2/§2.5 -- resets Tarjan's own per-top-level-call bookkeeping while
  # carrying `memo` (the only cross-branch-safe field) forward unchanged.
  @spec reset_stack_bookkeeping(leaf_search_state()) :: leaf_search_state()
  defp reset_stack_bookkeeping(state) do
    %{state | index: %{}, lowlink: %{}, stack: [], stack_set: MapSet.new(), next_index: 0}
  end

  # design doc §2.2-§2.2.3 -- memoized Tarjan-style single-pass DFS over
  # every path forward from `node_id`, returning the aggregate set of
  # leaves reachable: {:gateway, id} for every PARALLEL_GATEWAY node reached
  # that is a real join/pass-through (gateway_role/2 in [:join,
  # :pass_through]) -- an immediate terminal, never traversed past, since a
  # PARALLEL_GATEWAY node is never pushed onto `stack`. A PARALLEL_GATEWAY
  # node classified :split is a *nested* split (design doc
  # lib/letflow/design/iss0400-nested-parallel-gateway-fix.md §2.2/§2.3) --
  # resolved recursively via resolve_nested_split/3, which "sees through" it
  # to whatever lies past its own inner join, sharing this call's own
  # leaf_search_state() in full, with no reset at that boundary. A
  # :combined_unsupported PARALLEL_GATEWAY folds into :dead_end (design doc
  # §2.2 point 4/§3.3). :dead_end also covers every path that hits an
  # unresolved node_id or a node with zero outgoing edges (e.g. :END). A live
  # back-edge onto a node still on `stack` contributes no leaf at all (not
  # even :dead_end) -- it is evidence of "no new information from this
  # edge," not a dead end; the SCC's real informational content is captured
  # by its escape edges.
  #
  # Memoized per strongly connected component (SCC), not per node: when a
  # node's own fold finishes with `local_lowlink == index[node_id]`, it is
  # its SCC's root, and every member popped off `stack` at that point
  # (including itself) shares the *same* aggregate `local_leaves` value in
  # `memo` -- this is what makes the scheme sound under cycles-through-
  # gateways (§2.2.1): a plain node-keyed memo can give two different
  # callers two different values for the same node depending on which cycle
  # member was entered first, because plain DFS cycle detection "closes" a
  # back-edge at whichever node happens to be first-repeated on the
  # *current* call chain. SCC-keyed memoization is order-independent by
  # construction because Tarjan never closes (and therefore never writes to
  # `memo`) an SCC until every node reachable back into it has already been
  # explored, so the aggregate value written is always the complete union of
  # every escape edge in the component, never one entry point's partial view.
  #
  # Total (never raises) and terminates in O(nodes + edges) (§2.2.3): `memo`
  # is checked first (O(1) short-circuit for any node whose SCC has already
  # closed, even under an earlier top-level branch call), `stack` grows by
  # at most one element per fresh exploration, and every node is explored
  # fresh at most once across the whole sequence of a split node's sibling
  # branches.
  @spec collect_leaf_gateways(Graph.t(), String.t(), leaf_search_state()) ::
          {leaf_search_result(), MapSet.t(branch_leaf()), leaf_search_state()}
  defp collect_leaf_gateways(definition_snapshot, node_id, state) do
    cond do
      Map.has_key?(state.memo, node_id) ->
        {:finished, Map.fetch!(state.memo, node_id), state}

      MapSet.member?(state.stack_set, node_id) ->
        {{:open, Map.fetch!(state.index, node_id)}, MapSet.new(), state}

      true ->
        case find_node(definition_snapshot.nodes, node_id) do
          nil ->
            leaves = MapSet.new([:dead_end])
            {:finished, leaves, put_leaf_memo(state, node_id, leaves)}

          %Node{node_type: :PARALLEL_GATEWAY} = gw_node ->
            case gateway_role(definition_snapshot, gw_node) do
              role when role in [:join, :pass_through] ->
                leaves = MapSet.new([{:gateway, node_id}])
                {:finished, leaves, put_leaf_memo(state, node_id, leaves)}

              :split ->
                own_index = state.next_index

                state = %{
                  state
                  | index: Map.put(state.index, node_id, own_index),
                    lowlink: Map.put(state.lowlink, node_id, own_index),
                    stack: [node_id | state.stack],
                    stack_set: MapSet.put(state.stack_set, node_id),
                    next_index: own_index + 1
                }

                resolve_nested_split(definition_snapshot, gw_node, state)

              :combined_unsupported ->
                leaves = MapSet.new([:dead_end])
                {:finished, leaves, put_leaf_memo(state, node_id, leaves)}
            end

          %Node{} ->
            explore_branching_node(definition_snapshot, node_id, state)
        end
    end
  end

  # design doc lib/letflow/design/iss0400-nested-parallel-gateway-fix.md §2.3,
  # §3.2, §3.3 -- resolves a *nested* PARALLEL_GATEWAY split (gateway_role/2
  # == :split) reached mid-flight, inside an already-open outer-walk call
  # frame. Threads the exact, unmodified incoming `state` (all six
  # leaf_search_state() fields -- memo *and* index/lowlink/stack/stack_set/
  # next_index) into and back out of its own fold over `gw_node`'s own
  # outgoing edges -- structurally the same fold fold_outgoing_edges/4
  # already performs for any branching node's own sibling edges (§2.3), and
  # in fact reuses that same helper rather than reimplementing it. There is
  # NO reset of stack bookkeeping at this boundary, in either direction: this
  # call is not a top-level find_matching_join/2 branch entry (whose own
  # reset is safe only because §2.2.3 proves a top-level call's stack is
  # always fully unwound by the time it returns) -- it is a mid-flight
  # continuation of a walk already in progress, and resetting here would
  # erase a still-open ancestor's own on-stack membership, breaking live
  # back-edge detection into that ancestor (the exact BLOCKER
  # CODE-DESIGN-VALIDATOR found in iteration 1 -- infinite recursion).
  # reset_stack_bookkeeping/1 must never be called here or anywhere in the
  # call chain this function drives.
  #
  # On agreement (gw_node's own branches singleton-agree on one finished
  # {:gateway, inner_join_id}, modulo any number of live-back-edge {:open, _}
  # branches contributing no leaf): does not stop at inner_join_id -- resolves
  # its own single outgoing edge and recurses collect_leaf_gateways/3 on that
  # edge's target, returning *that* call's result as-is (no repackaging).
  # inner_join_id with zero outgoing edges, or gw_node's own branches failing
  # to agree with nothing left open, folds to :dead_end (§3.3). Not memoized
  # under gw_node.id directly (§3.1) -- every node this function resolves is
  # memoized individually, under its own node_id, by the ordinary
  # collect_leaf_gateways/3 calls this function makes; this function is a
  # pure pass-through of already-computed, already-memoized results.
  @spec resolve_nested_split(Graph.t(), Node.t(), leaf_search_state()) ::
          {leaf_search_result(), MapSet.t(branch_leaf()), leaf_search_state()}
  defp resolve_nested_split(definition_snapshot, %Node{} = gw_node, state) do
    own_index = Map.fetch!(state.index, gw_node.id)
    outgoing_edges = Enum.filter(definition_snapshot.edges, &(&1.source == gw_node.id))

    {local_leaves, local_lowlink, state} =
      fold_outgoing_edges(definition_snapshot, outgoing_edges, own_index, state)

    case MapSet.to_list(local_leaves) do
      [{:gateway, inner_join_id}] ->
        {continuation_tag, continuation_leaves, state} =
          case Enum.find(definition_snapshot.edges, &(&1.source == inner_join_id)) do
            nil ->
              {:finished, MapSet.new([:dead_end]), state}

            edge ->
              collect_leaf_gateways(definition_snapshot, edge.target, state)
          end

        propagated_lowlink =
          case continuation_tag do
            :finished -> local_lowlink
            {:open, continuation_lowlink} -> min(local_lowlink, continuation_lowlink)
          end

        close_scc_or_defer(
          gw_node.id,
          own_index,
          continuation_leaves,
          propagated_lowlink,
          state
        )

      _no_singleton_agreement ->
        close_scc_or_defer(gw_node.id, own_index, MapSet.new([:dead_end]), local_lowlink, state)
    end
  end

  @spec put_leaf_memo(leaf_search_state(), String.t(), MapSet.t(branch_leaf())) ::
          leaf_search_state()
  defp put_leaf_memo(state, node_id, leaves) do
    %{state | memo: Map.put(state.memo, node_id, leaves)}
  end

  # §2.2.2 step 5 -- a real branching/chaining node (not a memo hit, not
  # on-stack, not a PARALLEL_GATEWAY): assigns it a fresh Tarjan index,
  # pushes it onto the stack, folds sequentially (threading `state`, never
  # an independent Enum.map) over its own outgoing edges, then runs the
  # SCC-closure check.
  @spec explore_branching_node(Graph.t(), String.t(), leaf_search_state()) ::
          {leaf_search_result(), MapSet.t(branch_leaf()), leaf_search_state()}
  defp explore_branching_node(definition_snapshot, node_id, state) do
    own_index = state.next_index

    state = %{
      state
      | index: Map.put(state.index, node_id, own_index),
        lowlink: Map.put(state.lowlink, node_id, own_index),
        stack: [node_id | state.stack],
        stack_set: MapSet.put(state.stack_set, node_id),
        next_index: own_index + 1
    }

    outgoing_edges = Enum.filter(definition_snapshot.edges, &(&1.source == node_id))

    {local_leaves, local_lowlink, state} =
      fold_outgoing_edges(definition_snapshot, outgoing_edges, own_index, state)

    close_scc_or_defer(node_id, own_index, local_leaves, local_lowlink, state)
  end

  # Zero outgoing edges is a true terminal (:END-shaped dead end, no cycle
  # involved) -- local_lowlink stays own_index, since an edge-less node can
  # never be part of a larger SCC. One or more edges: sequential fold,
  # unioning every edge's leaves and taking the min lowlink seen.
  @spec fold_outgoing_edges(Graph.t(), [Graph.Edge.t()], non_neg_integer(), leaf_search_state()) ::
          {MapSet.t(branch_leaf()), non_neg_integer(), leaf_search_state()}
  defp fold_outgoing_edges(_definition_snapshot, [], own_index, state) do
    {MapSet.new([:dead_end]), own_index, state}
  end

  defp fold_outgoing_edges(definition_snapshot, outgoing_edges, own_index, state) do
    Enum.reduce(outgoing_edges, {MapSet.new(), own_index, state}, fn edge,
                                                                     {leaves_acc, lowlink_acc,
                                                                      state} ->
      {tag, edge_leaves, state} =
        collect_leaf_gateways(definition_snapshot, edge.target, state)

      leaves_acc = MapSet.union(leaves_acc, edge_leaves)

      lowlink_acc =
        case tag do
          :finished -> lowlink_acc
          {:open, child_lowlink} -> min(lowlink_acc, child_lowlink)
        end

      {leaves_acc, lowlink_acc, state}
    end)
  end

  # §2.2.2's closure check: if local_lowlink == own_index, node_id is its
  # SCC's root -- pop the stack down through and including node_id, write
  # the *same* local_leaves aggregate to memo for every popped member (the
  # property that makes this scheme order-independent), and report
  # :finished. Otherwise node_id is part of a larger SCC still being
  # discovered further up the call chain -- leave it on the stack, do not
  # write memo yet, and report {:open, local_lowlink}.
  @spec close_scc_or_defer(
          String.t(),
          non_neg_integer(),
          MapSet.t(branch_leaf()),
          non_neg_integer(),
          leaf_search_state()
        ) :: {leaf_search_result(), MapSet.t(branch_leaf()), leaf_search_state()}
  defp close_scc_or_defer(node_id, own_index, local_leaves, local_lowlink, state)
       when local_lowlink == own_index do
    {above, [^node_id | rest_stack]} = Enum.split_while(state.stack, &(&1 != node_id))
    scc_members = [node_id | above]

    memo = Enum.reduce(scc_members, state.memo, &Map.put(&2, &1, local_leaves))
    stack_set = Enum.reduce(scc_members, state.stack_set, &MapSet.delete(&2, &1))

    state = %{state | memo: memo, stack: rest_stack, stack_set: stack_set}

    {:finished, local_leaves, state}
  end

  defp close_scc_or_defer(_node_id, _own_index, local_leaves, local_lowlink, state) do
    {{:open, local_lowlink}, local_leaves, state}
  end

  # --- JOIN (design doc §4, EE-07 AC1-AC3, AC5) -------------------------------

  @spec dispatch_parallel_join(Graph.t(), InstanceState.t(), Token.t(), Node.t()) ::
          {:ok, InstanceState.t(), [pending_event()]}
          | {:error, transition_error()}
  defp dispatch_parallel_join(definition_snapshot, %InstanceState{} = instance_state, token, node) do
    with %JoinCounter{} = counter <- Map.get(instance_state.join_counters, node.id),
         true <- MapSet.member?(counter.expected_from_branches, token.branch_id) do
      tokens_without = Enum.reject(instance_state.tokens, &(&1.token_id == token.token_id))
      updated_received = MapSet.put(counter.received_from_branches, token.branch_id)
      updated_counter = %JoinCounter{counter | received_from_branches: updated_received}

      case join_outcome(updated_counter) do
        :wait ->
          updated_join_counters = Map.put(instance_state.join_counters, node.id, updated_counter)

          {:ok,
           %InstanceState{
             instance_state
             | tokens: tokens_without,
               join_counters: updated_join_counters
           }, []}

        :fire ->
          fire_join(definition_snapshot, instance_state, tokens_without, updated_counter, node)
      end
    else
      _ -> {:error, {:unknown_branch_id, token.branch_id}}
    end
  end

  # design doc §4.1 -- the single shared fire/wait/cancel decision, used by
  # both the arrival path (dispatch_parallel_join/4) and the cancellation
  # path (dispatch_cancel_branch/3).
  @type join_outcome :: :wait | :fire | :cancel_join

  @spec join_outcome(JoinCounter.t()) :: join_outcome()
  defp join_outcome(%JoinCounter{} = counter) do
    still_outstanding =
      MapSet.difference(
        counter.expected_from_branches,
        MapSet.union(counter.received_from_branches, counter.cancelled_branches)
      )

    cond do
      MapSet.size(still_outstanding) > 0 ->
        :wait

      MapSet.size(counter.received_from_branches) == 0 ->
        :cancel_join

      true ->
        :fire
    end
  end

  # design doc §4.3 -- shared fire construction, called from both fire paths
  # (arrival-triggered and cancellation-triggered).
  @spec fire_join(Graph.t(), InstanceState.t(), [Token.t()], JoinCounter.t(), Node.t()) ::
          {:ok, InstanceState.t(), [pending_event()]}
          | {:error, transition_error()}
  defp fire_join(
         definition_snapshot,
         %InstanceState{} = instance_state,
         tokens_without,
         counter,
         node
       ) do
    {_merge_status, merged_variables, merge_events} =
      VariableMerge.merge(instance_state.variables, %{}, nil)

    case Enum.find(definition_snapshot.edges, &(&1.source == node.id)) do
      nil ->
        {:error, {:unknown_node_id, node.id}}

      join_outgoing_edge ->
        new_token_id = counter.origin_token_id <> "/" <> node.id <> "/joined"

        new_token = %Token{
          token_id: new_token_id,
          node_id: join_outgoing_edge.target,
          branch_id: nil,
          waiting_child_instance_id: nil
        }

        final_tokens = tokens_without ++ [new_token]

        updated_join_counters = Map.delete(instance_state.join_counters, node.id)

        new_instance_state = %InstanceState{
          instance_state
          | tokens: final_tokens,
            join_counters: updated_join_counters,
            variables: merged_variables
        }

        pending_event =
          {:parallel_join_fired, node.id, counter.origin_token_id, new_token_id, merge_events}

        {:ok, new_instance_state, [pending_event]}
    end
  end

  # --- {:cancel_branch, branch_id} (design doc §3.4, EE-07 AC4) --------------

  @spec dispatch_cancel_branch(Graph.t(), InstanceState.t(), String.t()) ::
          {:ok, InstanceState.t(), [pending_event()]}
          | {:error, transition_error()}
  defp dispatch_cancel_branch(definition_snapshot, %InstanceState{} = instance_state, branch_id) do
    case Enum.find(instance_state.tokens, &(&1.branch_id == branch_id)) do
      nil ->
        {:error, {:unknown_branch_id, branch_id}}

      token ->
        tokens_without = Enum.reject(instance_state.tokens, &(&1.token_id == token.token_id))

        case Enum.find(Map.values(instance_state.join_counters), fn counter ->
               MapSet.member?(counter.expected_from_branches, branch_id)
             end) do
          nil ->
            {:ok, %InstanceState{instance_state | tokens: tokens_without}, []}

          %JoinCounter{} = counter ->
            join_node_id = counter.join_node_id
            updated_cancelled = MapSet.put(counter.cancelled_branches, branch_id)
            updated_counter = %JoinCounter{counter | cancelled_branches: updated_cancelled}

            case join_outcome(updated_counter) do
              :wait ->
                updated_join_counters =
                  Map.put(instance_state.join_counters, join_node_id, updated_counter)

                {:ok,
                 %InstanceState{
                   instance_state
                   | tokens: tokens_without,
                     join_counters: updated_join_counters
                 }, []}

              :cancel_join ->
                updated_join_counters = Map.delete(instance_state.join_counters, join_node_id)

                new_instance_state = %InstanceState{
                  instance_state
                  | tokens: tokens_without,
                    join_counters: updated_join_counters,
                    status: :cancelled
                }

                pending_event = {:parallel_join_cancelled, join_node_id, counter.origin_token_id}

                {:ok, new_instance_state, [pending_event]}

              :fire ->
                case find_node(definition_snapshot.nodes, join_node_id) do
                  nil ->
                    {:error, {:unknown_node_id, join_node_id}}

                  join_node ->
                    fire_join(
                      definition_snapshot,
                      instance_state,
                      tokens_without,
                      updated_counter,
                      join_node
                    )
                end
            end
        end
    end
  end

  # --- shared lookups (design doc §6, §7.2, §7.3) -----------------------------

  @spec find_token([Token.t()], String.t()) :: Token.t() | nil
  defp find_token(tokens, token_id), do: Enum.find(tokens, &(&1.token_id == token_id))

  @spec find_node([Node.t()], String.t()) :: Node.t() | nil
  defp find_node(nodes, node_id), do: Enum.find(nodes, &(&1.id == node_id))

  # Replaces the token in `tokens` whose token_id matches `new_token`'s,
  # preserving list order otherwise.
  @spec replace_token([Token.t()], Token.t()) :: [Token.t()]
  defp replace_token(tokens, %Token{token_id: token_id} = new_token) do
    Enum.map(tokens, fn
      %Token{token_id: ^token_id} -> new_token
      other -> other
    end)
  end
end
