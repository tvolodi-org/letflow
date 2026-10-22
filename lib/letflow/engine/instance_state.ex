defmodule Letflow.Engine.InstanceState do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  The full state of one running process instance — ports `transition.zig`'s
  `InstanceState` (EE-02, `lib/letflow/design/req044-transition-kernel.md`
  §2). Plain struct, not an `Ecto.Schema` — this module has zero
  `Ecto`/`Letflow.Repo` dependency (see `Letflow.Engine.Transition`'s purity
  contract, which this module's fields participate in even though the
  dispatch logic itself lives in that sibling module).

  ## Variable storage: no ObjectMap allocator-ownership equivalent (REQ-044)

  PROVENANCE (historical, not current decision authority):
  `transition.zig`'s `InstanceState.variables` is a `std.json.ObjectMap`, a
  mutable hash map whose entries are heap-allocated through an explicit
  `std.mem.Allocator` the caller owns and must free — Zig's manual-memory
  model requires every map read/write site to reason about who allocated a
  given entry and who is responsible for freeing it. This module represents
  `variables` as a plain Elixir `map()` instead. Elixir has no allocator to
  own: a map value is immutable, garbage-collected, and copied-on-write by
  ordinary language semantics, so there is no allocation-ownership discipline
  to port and none is invented here — the same divergence REQ-029's design
  (`lib/letflow/design/req029-node-attribute-edge-condition-validators.md`
  §8) already noted for `GraphError.OutOfMemory`: Zig's allocator-failure
  error case has no Elixir equivalent, and this module does not fabricate one.

  ## Dependency ordering: this module does not depend on REQ-043

  `InstanceState.status`'s four values (`:active`, `:completed`, `:cancelled`,
  `:error`) are chosen to be source-compatible with the `status` `Ecto.Enum`
  `Letflow.EventStore.InstanceProjection` (REQ-023, already shipped) already
  declares — `values: [active: "ACTIVE", completed: "COMPLETED", cancelled:
  "CANCELLED", error: "ERROR"]` — and with what REQ-043's own future ALTER-
  TABLE migration and any instance-engine schema modules will reuse. This
  module depends on REQ-028 (`Letflow.Definitions.Graph`) and REQ-029, both
  `status: done`. It does **not** depend on REQ-043 (`instance_projections`
  ALTER, `tasks`, `tokens` tables — `status: pending` at the time this design
  was written) or on any not-yet-existing `Ecto.Schema` module REQ-043 will
  add. This module is pure (see the purity section above) — it performs zero
  `Letflow.Repo` calls and holds no reference, direct or aliased, to any
  REQ-043 schema module. `status` is declared here as a plain atom type
  (`:active | :completed | :cancelled | :error`), not as `Ecto.Enum` and not
  as a call into a REQ-043-owned module that does not yet exist.

  ## `join_counters` (REQ-051)

  Added by `lib/letflow/design/req051-parallel-gateway-split-join.md` §2.1:
  one outstanding `Letflow.Engine.JoinCounter` cohort per PARALLEL_GATEWAY
  join node currently awaiting some of its branches, keyed by `join_node_id`
  alone — **not** by `{join_node_id, origin_token_id}`. This means at most
  one cohort can be outstanding per join node at a time; a second split
  reaching the same join node while an earlier cohort is still outstanding
  (e.g. loop re-entry) would overwrite the earlier entry — out of scope for
  this requirement, flagged as an open question (design doc §12.1).

  ## `pending_service_task_nodes` (REQ-215)

  Added by `lib/letflow/design/req215-service-task-engine-wiring.md` §1.1:
  the `:SERVICE_TASK`-node analogue of `pending_task_nodes`, appended to by
  `Letflow.Engine.Transition`'s `dispatch_service_task/3` alone. Deliberately
  a second, disjoint list field rather than an overload of
  `pending_task_nodes` — `pending_task_nodes` is documented (below) as the
  guard for REQ-047's `tasks`-row materialization, and every one of its
  existing consumers assumes every entry becomes a human-facing `tasks` row.
  A SERVICE_TASK dispatch never becomes a `tasks` row (it becomes a
  `service_task_dispatches` row, a distinct schema with distinct
  pending/advanced/given_up lifecycle semantics, no human actor) — a token
  parked here never appears in `pending_task_nodes` and vice versa.

  ## `variable_labels` (decision 0062, GH #2616)

  Per-variable restriction labels (`"entity_type.field_name"` lists) beside `variables`. Written
  only by `Letflow.Engine.VariableMerge.merge/5`; a struct update that replaces `variables` must
  replace `variable_labels` in the same update (`Letflow.Engine.VariableLabels.put_merged/3`).
  An absent key means unlabelled.
  """

  alias Letflow.Engine.JoinCounter
  alias Letflow.Engine.Token

  @enforce_keys [:instance_id]
  defstruct [
    :instance_id,
    status: :active,
    tokens: [],
    variables: %{},
    pending_task_nodes: [],
    pending_service_task_nodes: [],
    join_counters: %{},
    variable_labels: %{}
  ]

  @type status :: :active | :completed | :cancelled | :error

  @type t :: %__MODULE__{
          instance_id: String.t(),
          status: status(),
          tokens: [Token.t()],
          variables: map(),
          pending_task_nodes: [Token.t()],
          pending_service_task_nodes: [Token.t()],
          join_counters: %{optional(String.t()) => JoinCounter.t()},
          variable_labels: %{optional(String.t()) => [String.t()]}
        }
end
