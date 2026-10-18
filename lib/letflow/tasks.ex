defmodule Letflow.Tasks do
  @moduledoc """
  Context module for the `tasks` table's non-engine-transition surface.
  REQ-083 built the read path (`get_task/2`, `list_tasks/2`,
  `resolve_principal_scope/2`) backing `GET /tasks`, `GET /tasks/inbox`,
  `GET /tasks/:id`. REQ-085 (`lib/letflow/design/req085-task-routes-write.md`)
  adds the claim/assign/reassign write path (`claim_task/3`, `assign_task/4`,
  `reassign_task/4`) backing `POST /tasks/:id/claim`, `.../assign`,
  `.../reassign`. Plain Ecto context module, no process, no `gen_statem` — a
  surface over the already-shipped `tasks` table (`Letflow.Engine.Task`,
  REQ-043/047).

  ## Why claim/assign/reassign live here, not in `Letflow.Engine` (REQ-085 design §3.0)

  `Letflow.Engine.complete_task/3` alone drives a real transition — output
  variables merge into instance variables, the token advances — so
  `POST /tasks/:id/complete` routes there instead (see
  `Letflow.Routers.Tasks`). Claim/assign/reassign do neither: none of the
  three touches `instance_projections` or `tokens`, only this one `tasks`
  row's `assignee_type`/`assignee_ref` columns. `Letflow.Engine`'s own EE-12
  lock inventory is scoped to `create/2`/`complete_task/3`/`cancel_instance/3`
  — three functions that all drive instance/token state — so these three
  functions belong on this module instead, alongside the
  `resolve_principal_scope/2` group/role resolution `claim_task/3` needs
  directly.

  **This module's own lock inventory** (mirroring `Letflow.Engine`'s own
  EE-12 statement): every `lock("FOR UPDATE")` acquired by `claim_task/3`/
  `assign_task/4`/`reassign_task/4` is `fetch_and_lock_task/3` (private,
  below — a distinct function from `Letflow.Engine`'s own private function of
  the same name), filtered `where t.id == ^task_id`. Single-row, scoped to
  exactly the one `tasks` row the path parameter names. No lock here ever
  touches `instance_projections` or `tokens`. No global or table-level lock.
  Each of the three functions runs its lock-then-check inside one
  `Ecto.Multi`/`Repo.transaction/1` — the same row-lock-then-check-in-Elixir
  concurrency idiom `Letflow.Engine.complete_task/3` already established, not
  a bare `UPDATE ... WHERE` racing without an application-level lock (see
  `claim_task/3`'s own doc for why two concurrent claims produce exactly one
  winner).

  ## Form version pinning (REQ-126, MOB-3) — a new read, not new pin machinery

  `get_task/2`/`list_tasks/2` also surface `form_id`/`form_version` (REQ-126,
  `lib/letflow/design/req126-form-version-pinning.md`) so a task payload
  names the exact pinned form version MOB-3 requires, and never silently
  substitutes the currently-active one. `form_id` is the task's own
  `node_id` (§4.3 of that design — every `tasks` row is activated only from
  a `:HUMAN_TASK` node, `Letflow.Engine.TaskActivation`'s own moduledoc, so
  the node the task was activated from already *is* the form's identity;
  no new node attribute, no forms catalog). `form_version` is
  `instance_definition_snapshots.definition_ver` (`Letflow.Definitions.InstanceDefinitionSnapshot`,
  REQ-027/033), looked up by the task's `instance_id` via a `left_join`.

  **This is deliberately not an instance of `Letflow.Engine.PinResolver`
  (REQ-059).** `PinResolver` pins *external, mutable-catalog* references —
  `catalog_entry`/`module` — things that live outside a process
  definition's own row and need an active `resolve/4` step against an
  injectable `Lookup`, recorded into the `INSTANCE_STARTED` event payload
  because no other durable place exists to freeze them. A form reference has
  no such external catalog: it is already *inside* the definition's own
  `instance_definition_snapshots` row, a write-once record
  (`InstanceDefinitionSnapshot` exposes no `update_changeset/2` at all) that
  was already immutable and already frozen at instance-start time for an
  unrelated reason (REQ-027/033's PD-08 "read-only after creation"
  contract) — one that shipped before `PinResolver` (REQ-059) existed.
  Promoting a new `process_definitions` version afterward creates a new row
  there and never touches an existing instance's snapshot, so there is
  nothing left to actively pin: none of `PinResolver`'s four concerns
  (`resolve/4`, `merge_effective_pins/3`, `apply_inheritance/2`,
  `pin_for/3` — override, inheritance, rebind) has a form counterpart to
  build. `get_form_version/2` below is a single scalar read of an
  already-pinned column, nothing more.

  PROVENANCE (historical, not current decision authority):
  ## `src/tasks/store.zig` boundary — ported vs. not ported (AC6)

  PROVENANCE (historical, not current decision authority):
  R-Co's task query/filter/list logic lives in `src/tasks/store.zig` (1,202
  lines), outside `src/api/`. This module ports only the query operations the
  three read-path route handlers (`handleList`/`handleGetById`/`handleInbox`)
  actually invoke — every other `store.zig` operation is a deliberate
  non-port, enumerated below so the boundary is explicit rather than
  approximate.

  **Ported by this module:**

  | R-Co function | This module's equivalent | Notes |
  |---|---|---|
  | `TaskStore.getById` (L239-283) | `get_task/2` | Adds the `instance_projections` join for `correlation_key`, as a `LEFT JOIN` (keeps the query resilient even if a task's instance row is ever missing) |
  | `TaskStore.listCursor` (L579-737) | `list_tasks/2` | Cursor prefix `"T:"`, keyset `(inserted_at, id)`; **extended** to add ROLE-held-task scoping beyond the ported baseline's `USER`/`GROUP`-only scoping (see `resolve_principal_scope/2`'s own doc; this requirement's own text and acceptance criteria require all three arms) |
  | `taskStatusToString`/`parseTaskStatus` (L1150-1163, L1143-1149) | `Letflow.Engine.Task`'s existing `Ecto.Enum` cast/dump (already shipped, REQ-043) | No new function needed — `Ecto.Enum` already does this |
  | `parseUuid`/`uuidToHex` | `Ecto.UUID.cast/1` / Ecto's native string-form UUIDs | No raw 16-byte UUID type in ordinary use elsewhere in this codebase |
  | `TaskStore.claimTask` (L761-849) | `claim_task/3` (REQ-085) | **Not** a port of `claimed_by`-column semantics — see `claim_task/3`'s own doc and the REQ-085 design doc §1 for the full resolution (Letflow has no `claimed_by` column; claim is atomic conditional self-assignment against `assignee_type`/`assignee_ref` instead) |
  | `TaskStore.assign` (L851-908) | `assign_task/4` (REQ-085) | Same `WHERE ... assignee_ref IS NULL` precondition: an assign only succeeds against a task with no current assignee, so two concurrent assigns can't silently overwrite each other's effect |
  | `TaskStore.reassign`/`reassignInTx` (L910-1002) | `reassign_task/4` (REQ-085) | Same `WHERE ... assignee_ref IS NOT NULL` precondition: a reassign requires an existing assignee to reassign away from, distinguishing it from a first-time assign |

  PROVENANCE (historical, not current decision authority):
  **Not ported by this module** (every other `pub fn`/error set in
  `store.zig`):

  | R-Co function/type | Why not ported here |
  |---|---|
  | `TaskStore.list` (L443-577, offset-based) | Superseded entirely by `listCursor` — never called by any of the three read handlers |
  | `TaskStore.createInTx` (L161-237) | Task-activation write path — already covered by REQ-047's `Letflow.Engine.TaskActivation.append_multi/6`, a different module entirely |
  | `TaskStore.completeInTx` (L304-379), `cancelInTx` (L381-441) | EE-04 task-completion write path — `Letflow.Engine.complete_task/3` (REQ-048), not this module |
  | `TaskError`'s `AlreadyTerminated`, `ClaimError`, `AssignError` variants | Not ported by name — this module's `claim_error()`/`assign_error()`/`reassign_error()` unions (REQ-085) cover the same outcomes with Letflow-native atoms, since Letflow's claim has no separate `claimed_by` boolean to be independently true |
  | `insertTaskWaitDescriptorInTx` (L1025-1141) | SCH-03 timer-wait bookkeeping — S6 scope, not invoked by any read handler |

  ## Error handling — matches this project's established residual-risk precedent

  Every function below returns `{:ok, _} | {:error, atom}` for its *expected*
  failure modes (invalid UUID, not found, malformed cursor). A genuine
  DB/connection-level failure is not caught and converted anywhere in this
  module — it propagates as a raised exception. Only this module's three
  *read* functions (`get_task/2`, `list_tasks/2`, `resolve_principal_scope/2`)
  match `Letflow.Identity`'s own established precedent for simple reads —
  `Letflow.Identity`'s read functions (`list_users/2`, `get_user/2`,
  `list_groups/1`, `list_group_members/3`, `list_tokens/1`,
  `verify_api_token/2`, and friends) are likewise left un-rescued.
  `assign_task/3`/`reassign_task/4` are WRITE functions (each builds its own
  `Ecto.Multi` with an `Audit.append_multi/4` step, same shape as
  `Letflow.Identity`'s write functions used to have) and are deliberately
  left un-rescued here too, but this is no longer "matching an established
  Identity precedent" — ISS-0983 rescue-hardened every comparable
  `Letflow.Identity` write path (`create_user/2`, `update_user_profile/3`,
  `update_user_status/3`, `create_group/2`, `create_token/3`,
  `revoke_token/2`), so there is no longer an un-rescued write-path precedent
  on that module for these two functions to match. Leaving
  `assign_task/3`/`reassign_task/4` un-rescued is now a standing, separate
  decision specific to this module, not something inherited from elsewhere —
  revisit as its own issue if that asymmetry needs closing, rather than
  reading this comment as still justifying it by analogy.

  ## Tenant scoping (INV-1)

  Every function below takes `opts :: [prefix: String.t()]`. This module
  never itself decides tenant scope or authorization — `prefix` is supplied
  by the caller (the router, via `Letflow.Api.Context.scoped_repo_opts/1`),
  exactly like every other REQ-072+ context module in this codebase.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Letflow.Audit
  alias Letflow.Api.Authorization
  alias Letflow.Api.Pagination
  alias Letflow.Api.Scope
  alias Letflow.Entities.Query.Types
  alias Letflow.Definitions.InstanceDefinitionSnapshot
  alias Letflow.Engine.SeparationOfDuties
  alias Letflow.Engine.Task
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.TenantRole
  alias Letflow.Tasks.ScopeResolver
  alias Letflow.Repo

  @typedoc "Threaded into every `Repo` call below — `:prefix` derived by the caller from `Letflow.Api.Context.scoped_repo_opts/1`, never from request data."
  @type opts :: [prefix: String.t()]

  @type task_status :: :pending | :completed | :cancelled

  @type principal_scope :: %{
          user_id: String.t(),
          group_ids: [Ecto.UUID.t()],
          role_names: [String.t()]
        }

  @type assignee_scope ::
          :unfiltered
          | {:explicit_user, user_id :: String.t()}
          | {:principal, principal_scope()}

  @type list_tasks_params :: %{
          optional(:status) => task_status() | nil,
          optional(:instance_id) => Ecto.UUID.t() | nil,
          optional(:scope) => Types.scope_set(),
          assignee_scope: assignee_scope(),
          cursor: String.t() | nil,
          page_size: pos_integer()
        }

  @list_cursor_prefix "T:"

  @doc """
  Cursor-paginated task listing — backs `GET /tasks` and (via a
  caller-supplied `assignee_scope`) `GET /tasks/inbox`. One function backs
  both endpoints — this function has no notion of "which endpoint called
  me"; the caller (the router) decides `assignee_scope` before calling.

  `assignee_scope`:

    * `:unfiltered` — no assignee filter at all (every task in the tenant's
      schema, subject only to `status`/`instance_id`).
    * `{:explicit_user, user_id}` — `assignee_type == "USER" and assignee_ref
      == user_id` — a caller-supplied `?assignee_id=` filter.
    * `{:principal, principal_scope}` — a task assigned directly to
      `principal_scope.user_id`, OR to a group in `principal_scope.group_ids`,
      OR to a role in `principal_scope.role_names`. Built via
      `resolve_principal_scope/2`.

  Sorted by `inserted_at` descending, then `id` descending — `id` as
  tiebreaker keeps the sort (and therefore the cursor) deterministic when
  two tasks share the same `inserted_at` timestamp — cursor-paginated via
  `Letflow.Api.Pagination` with prefix `"T:"`.

  Always returns `{:error, :invalid_cursor}` for a malformed/wrong-endpoint
  cursor (collapsing `Letflow.Api.Pagination.decode_cursor/4`'s
  `:invalid_base64`/`:invalid_cursor` atoms into one — a cursor is opaque to
  callers, so there's no caller-actionable difference between "not valid
  base64" and "valid base64 but the wrong shape") and `{:error, :expired}`
  for one past its freshness window.

  Each item is a `{Task.t(), form_version}` pair (REQ-126) — `form_version`
  comes from a `left_join` against `instance_definition_snapshots`, added
  purely for the pinned-form-version read (see this module's moduledoc);
  pagination itself is still keyed on the `Task` half only
  (`inserted_at`/`id`), unaffected by the join.
  """
  @spec list_tasks(list_tasks_params(), opts()) ::
          {:ok,
           %{
             items: [{Task.t(), form_version :: String.t() | nil}],
             next_cursor: String.t() | nil
           }}
          | {:error, :invalid_cursor | :wrong_endpoint | :expired}
  def list_tasks(params, opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    page_size = Map.fetch!(params, :page_size)

    with {:ok, cursor_seek} <- decode_list_cursor(Map.get(params, :cursor)) do
      query =
        Task
        |> filter_by_status(Map.get(params, :status))
        |> filter_by_instance_id(Map.get(params, :instance_id))
        |> filter_by_assignee_scope(Map.get(params, :assignee_scope, :unfiltered))
        |> filter_by_scope(Map.get(params, :scope, :all))
        |> filter_by_list_cursor(cursor_seek)
        |> order_by([t], desc: t.inserted_at, desc: t.id)
        |> limit(^(page_size + 1))
        |> join(:left, [t], s in InstanceDefinitionSnapshot, on: s.instance_id == t.instance_id)
        |> select([t, s], {t, s.definition_ver})

      rows = Repo.all(query, prefix: prefix)
      {page, next_cursor} = split_list_page(rows, page_size)

      {:ok, %{items: page, next_cursor: next_cursor}}
    end
  end

  @doc """
  Fetches a single task by id, joined to `instance_projections` for
  `correlation_key` (a plain `left_join`, kept nullable-safe in case a
  task's instance row is ever missing), and to `instance_definition_snapshots`
  for `form_version` (REQ-126 — see
  this module's moduledoc "Form version pinning" section).

  `Ecto.UUID.cast/1` is checked first — an invalid UUID never reaches the DB
  (`{:error, :invalid_id}`, no round-trip). A cross-tenant `id` and a
  genuinely nonexistent `id` resolve through this same single code path to
  `{:error, :not_found}` — no branch exists that could tell them apart
  (INV-5/AC3), the identical structural mechanism REQ-072's own AC4
  demonstration established.

  REQ-518 PR 2d (design C.2): the optional `opts[:scope]` (a
  `t:Letflow.Entities.Query.Types.scope_set/0`, default `:all` = today's single statement)
  adds the node predicate `scope_node_id IN (ids)` to that SAME statement; `:none` and a NULL
  node never match, so an out-of-scope task resolves to `{:error, :not_found}` exactly like a
  nonexistent one. `list_tasks/2` takes the same set as `params[:scope]` and ANDs it with the
  assignee scope (intersection).

  This function does not itself decide tenant scope or authorization —
  `prefix` is supplied by the caller.
  """
  @spec get_task(id :: String.t(), opts()) ::
          {:ok, {Task.t(), correlation_key :: String.t() | nil, form_version :: String.t() | nil}}
          | {:error, :not_found | :invalid_id}
  def get_task(id, opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    scope = Keyword.get(opts, :scope, :all)

    case Ecto.UUID.cast(id) do
      :error ->
        {:error, :invalid_id}

      {:ok, id} ->
        query =
          from(t in Task,
            left_join: ip in InstanceProjection,
            on: ip.instance_id == t.instance_id,
            left_join: s in InstanceDefinitionSnapshot,
            on: s.instance_id == t.instance_id,
            where: t.id == ^id,
            select: {t, ip.correlation_key, s.definition_ver}
          )
          |> filter_by_scope(scope)

        case Repo.one(query, prefix: prefix) do
          nil -> {:error, :not_found}
          {task, correlation_key, form_version} -> {:ok, {task, correlation_key, form_version}}
        end
    end
  end

  @doc """
  Fetches the pinned form version (REQ-126) for a task's owning instance,
  independent of `get_task/2`/`list_tasks/2` — used by the claim/assign/
  reassign write-path handlers below, which only get a bare `Task.t()` back
  from `Repo.update/2` (no join already in hand the way `get_task/2` has
  one). A narrow, single-column `select` (not
  `Letflow.Definitions.SnapshotStore.get_by_instance_id/2`, which would
  additionally pull the full `graph` map over the wire for a response that
  never reads it — see `lib/letflow/design/req126-form-version-pinning.md`
  §9 OQ-2).

  Returns `nil`, never raises, when no snapshot row exists for
  `instance_id` (INV-8) — the same near-impossible-in-practice, non-crashing
  fallback `get_task/2`'s own `left_join` already establishes for this
  column.
  """
  @spec get_form_version(instance_id :: Ecto.UUID.t(), opts()) :: String.t() | nil
  def get_form_version(instance_id, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    Repo.one(
      from(s in InstanceDefinitionSnapshot,
        where: s.instance_id == ^instance_id,
        select: s.definition_ver
      ),
      prefix: prefix
    )
  end

  @doc """
  Resolves the group ids and role names a user holds — the requirement's own
  explicit instruction ("resolve group and role membership through
  `Letflow.Identity` rather than reimplementing the resolution"), and the one
  place this module's read path goes beyond what the ported baseline's
  `listCursor` SQL actually does: **the ported baseline's
  `include_group_membership_for_user` branch covers `USER`/`GROUP` only —
  there is no `ROLE` arm anywhere in that shipped query.** REQ-083's own
  requirement text names all three ("assigned directly to X, ... to a group
  X belongs to, and ... to a role X holds") and tests all three explicitly —
  this module implements the requirement's text, not that earlier partial
  implementation of it.

  Group ids: a direct read of the `group_members` table
  (`Letflow.Identity.GroupMember`, REQ-074's schema), inverted from
  `Letflow.Identity.list_group_members/3`'s own `group_id`-keyed direction —
  a read of an `Identity`-owned table, not a reimplementation of
  `Letflow.Identity`'s own membership-management logic (writes to this table
  remain exclusively `Letflow.Identity.add_group_member/3`/
  `remove_group_member/3`'s).

  Role names: derived, not stored directly — a user "holds" a role iff the
  role's bound group is one of the group ids resolved above. Resolved via a
  direct, `:prefix`-scoped read of `Letflow.Identity.TenantRole` (not
  `Letflow.Identity.RoleRegistry.list_roles/0`, which issues an unprefixed
  query — see `lib/letflow/design/req083-task-routes-read.md` §3.4 point 2
  and the Step 2c/rework-1 handoffs this fixes). No new role table, no
  per-user role column anywhere in this schema.

  No caching, no memoization — both queries run fresh on every call,
  consistent with this project's existing per-request-fresh-query precedent
  elsewhere in S4 (REQ-072's `scoped_repo_opts/1`, REQ-074's group-membership
  joins).
  """
  @spec resolve_principal_scope(user_id :: String.t(), opts()) :: principal_scope()
  def resolve_principal_scope(user_id, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    group_ids =
      Repo.all(
        from(m in GroupMember, where: m.user_id == ^user_id, select: m.group_id),
        prefix: prefix
      )

    role_names =
      Repo.all(
        from(t in TenantRole,
          where: t.group_id in ^group_ids,
          select: %{name: t.name, group_id: t.group_id}
        ),
        prefix: prefix
      )
      |> Enum.map(& &1.name)

    %{user_id: user_id, group_ids: group_ids, role_names: role_names}
  end

  # =========================================================================
  # REQ-518 PR 2d (design C.2 to C.4): the approver rule F1.
  # =========================================================================

  @doc """
  Whether the task `task_id` lies in the allowed node set `scope` (design C.2). `:all` -> `:ok`
  with NO statement (today's behaviour; a nonexistent id then fails later as before). `:none` ->
  `{:error, :task_not_found}` with no statement. `{:nodes, ids}` -> ONE statement on the `tasks`
  row `WHERE id = $1 AND scope_node_id IN (ids)`; a task outside the set, with a NULL node, or
  nonexistent all give `{:error, :task_not_found}`. A malformed id gives
  `{:error, :invalid_task_id}` before any statement, as the routes do today.
  """
  @spec in_scope(task_id :: String.t(), Types.scope_set(), opts()) ::
          :ok | {:error, :invalid_task_id | :task_not_found}
  def in_scope(task_id, scope, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, task_id} <- cast_task_id(task_id) do
      case scope do
        :all ->
          :ok

        :none ->
          {:error, :task_not_found}

        {:nodes, ids} ->
          query = from(t in Task, where: t.id == ^task_id and t.scope_node_id in ^ids, select: 1)
          if Repo.exists?(query, prefix: prefix), do: :ok, else: {:error, :task_not_found}
      end
    end
  end

  @doc """
  The F1 grant requirement for one task (design C.3). (1) A principal who holds
  `route_permission` tenant-wide (`Scope.allowed?(principal, route_permission, :tenant_wide)`
  allows: a tenant-wide holder, a token principal, a platform admin) is exempt (RA-13; nothing
  role-name based). (2) Otherwise the principal must hold a TASK_WORKER grant covering the
  task's scope node (`Scope.allowed_for_role?/3`); a NULL node, a retired node, other roles'
  grants and a PROCESS_OPERATOR or TENANT_ADMIN grant never count. The routing-role checks of
  `claim_task/3` and `authorize_completion/3` are separate and unchanged.
  """
  @spec f1_allowed?(Task.t(), Scope.Principal.t(), Authorization.permission() | atom()) ::
          boolean()
  def f1_allowed?(%Task{} = task, %Scope.Principal{} = principal, route_permission) do
    match?({:allow, _basis}, Scope.allowed?(principal, route_permission, :tenant_wide)) or
      match?(
        {:allow, _basis},
        Scope.allowed_for_role?(principal, "TASK_WORKER", ScopeResolver.task_scope(task))
      )
  end

  @doc """
  The in-transaction F1 re-check (design C.4, AC 15), run by `claim_task/3` and
  `Letflow.Engine.complete_task/3` right after the task row lock. A user principal's grants are
  reloaded with `Scope.load_grants(user_id, prefix)` (fresh, not the request memo, so a grant or
  membership revoked since the request began is seen). It is a PLAIN READ: no `FOR SHARE` or
  `FOR UPDATE`, no advisory lock, so the lock orders are untouched. Refusal is
  `{:error, :task_not_found}`, the same answer as a nonexistent task.
  """
  @spec f1_recheck(Task.t(), Scope.Principal.t(), prefix :: String.t()) ::
          {:ok, :f1_allowed} | {:error, :task_not_found}
  def f1_recheck(%Task{} = task, %Scope.Principal{} = principal, prefix) do
    principal =
      case principal.kind do
        :user -> %{principal | grants: Scope.load_grants(principal.user_id, prefix)}
        _token -> principal
      end

    if f1_allowed?(task, principal, Authorization.required_permission(:TasksComplete)),
      do: {:ok, :f1_allowed},
      else: {:error, :task_not_found}
  end

  # =========================================================================
  # claim_task/3, assign_task/4, reassign_task/4 (REQ-085) -- see
  # lib/letflow/design/req085-task-routes-write.md §3 for the full design
  # these implement.
  #
  # Lock inventory (mirrors Letflow.Engine's own EE-12 statement, §3.0 of the
  # design doc): every `lock("FOR UPDATE")` acquired by these three
  # functions is `fetch_and_lock_task/3` below, filtered `where t.id ==
  # ^task_id` -- single-row, scoped to exactly the one `tasks` row the path
  # parameter names. No lock here ever touches `instance_projections` or
  # `tokens` -- none of the three functions drives an engine transition
  # (unlike `Letflow.Engine.complete_task/3`); they mutate exactly one
  # `tasks` row's `assignee_type`/`assignee_ref` columns and nothing else.
  # No global or table-level lock.
  # =========================================================================

  @type claim_attrs :: %{required(:actor_id) => Ecto.UUID.t()}
  @type f1 :: :off | {:enforce, Scope.Principal.t()}
  @type claim_opts :: [prefix: String.t(), f1: f1()]

  @type claim_error ::
          {:error, :invalid_task_id}
          | {:error, :task_not_found}
          | {:error, {:task_not_pending, status :: :completed | :cancelled}}
          | {:error, :assigned_to_other_user}
          | {:error, :assignee_group_not_member}
          | {:error, :assignee_role_not_held}
          | {:error, :not_claimable}
          | {:error, :separation_of_duties}
          | {:error, Ecto.Changeset.t()}
          | {:error, term()}

  @doc """
  Atomic conditional self-assignment (REQ-085 design doc §1, §3.4) -- this
  schema has no separate `claimed_by` column, so claim is implemented as
  atomic conditional self-assignment against `assignee_type`/`assignee_ref`
  instead (see the design doc's §1 for the full resolution). Claimable
  when the task is currently unassigned, or assigned to a group/role
  `attrs.actor_id` belongs to (via `resolve_principal_scope/2`, the same
  group/role resolution `GET /tasks/inbox` already uses -- no second
  resolution path). Rejected when assigned to a specific different user or a
  group/role the caller does not belong to.

  Row-locked via `fetch_and_lock_task/3` (`SELECT ... FOR UPDATE`) inside one
  `Ecto.Multi`, matching `Letflow.Engine.complete_task/3`'s own established
  concurrency idiom (design doc §3.1) -- not a bare `UPDATE ... WHERE`. Two
  concurrent claims of the same task: the second transaction's lock
  acquisition blocks until the first commits, then observes the first
  claimer's write and deterministically lands on `{:error,
  :assigned_to_other_user}` (never a 500).

  Re-claiming a task already claimed by the same caller is a no-op success
  (idempotent), not an error (design doc §3.4, OQ-2).
  """
  @spec claim_task(task_id :: String.t(), attrs :: claim_attrs(), opts :: claim_opts()) ::
          {:ok, Task.t()} | claim_error()
  def claim_task(task_id, attrs, opts) when is_map(attrs) and is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    actor_id = Map.fetch!(attrs, :actor_id)

    with {:ok, task_id} <- cast_task_id(task_id) do
      Multi.new()
      |> Multi.run(:task, fn repo, _changes -> fetch_and_lock_task(repo, task_id, prefix) end)
      |> maybe_f1_scope(Keyword.get(opts, :f1, :off), prefix)
      |> Multi.run(:scope, fn _repo, _changes ->
        {:ok, resolve_principal_scope(actor_id, prefix: prefix)}
      end)
      |> Multi.run(:apply, fn repo, %{task: task, scope: scope} ->
        apply_claim(repo, task, actor_id, scope, prefix)
      end)
      |> Repo.transaction()
      |> unwrap_write_result()
    end
  end

  defp maybe_f1_scope(multi, :off, _prefix), do: multi

  defp maybe_f1_scope(multi, {:enforce, %Scope.Principal{} = principal}, prefix) do
    Multi.run(multi, :f1_scope, fn _repo, %{task: task} -> f1_recheck(task, principal, prefix) end)
  end

  defp apply_claim(_repo, %Task{assignee_type: nil} = task, actor_id, _scope, prefix) do
    with :ok <- SeparationOfDuties.check_for_claim(task, actor_id, prefix) do
      write_assignment(task, "USER", actor_id, prefix)
    end
  end

  defp apply_claim(
         _repo,
         %Task{assignee_type: "USER", assignee_ref: ref} = task,
         actor_id,
         _scope,
         prefix
       )
       when ref == actor_id do
    with :ok <- SeparationOfDuties.check_for_claim(task, actor_id, prefix) do
      {:ok, task}
    end
  end

  defp apply_claim(_repo, %Task{assignee_type: "USER"}, _actor_id, _scope, _prefix) do
    {:error, :assigned_to_other_user}
  end

  defp apply_claim(
         _repo,
         %Task{assignee_type: "GROUP", assignee_ref: ref} = task,
         actor_id,
         scope,
         prefix
       ) do
    if ref in scope.group_ids do
      with :ok <- SeparationOfDuties.check_for_claim(task, actor_id, prefix) do
        write_assignment(task, "USER", actor_id, prefix)
      end
    else
      {:error, :assignee_group_not_member}
    end
  end

  defp apply_claim(
         _repo,
         %Task{assignee_type: "ROLE", assignee_ref: ref} = task,
         actor_id,
         scope,
         prefix
       ) do
    if ref in scope.role_names do
      with :ok <- SeparationOfDuties.check_for_claim(task, actor_id, prefix) do
        write_assignment(task, "USER", actor_id, prefix)
      end
    else
      {:error, :assignee_role_not_held}
    end
  end

  defp apply_claim(_repo, %Task{}, _actor_id, _scope, _prefix), do: {:error, :not_claimable}

  # =========================================================================
  # authorize_completion/3 (ISS-0942) -- see
  # lib/letflow/design/iss0942-task-complete-authorization-gap.md §2 for the
  # full design this implements. Read-only admission check called from
  # Letflow.Routers.Tasks.handle_complete/3 BEFORE Letflow.Engine.complete_task/3
  # -- mirrors apply_claim/5's own precedence table exactly, minus the write.
  # No row lock here (§2.3 of the design doc): this function never mutates
  # anything -- Engine.complete_task/3 still takes its own `SELECT ... FOR
  # UPDATE` inside its own Ecto.Multi, unchanged by this function.
  # =========================================================================

  @type complete_authz_opts :: opts()

  @type complete_authz_error ::
          {:error, :invalid_task_id}
          | {:error, :task_not_found}
          | {:error, :assigned_to_other_user}
          | {:error, :assignee_group_not_member}
          | {:error, :assignee_role_not_held}

  @doc """
  Read-only authorization admission check for `POST /tasks/:id/complete`
  (ISS-0942) -- mirrors `apply_claim/5`'s own precedence table exactly,
  minus the write: unassigned (`nil`) task -> `:ok` (permissive, same as
  `claim_task/3`'s own unassigned case -- any authenticated actor may
  complete a currently-unassigned task, same as they may claim one);
  `USER` assignee matching `actor_id` -> `:ok`, mismatch -> `{:error,
  :assigned_to_other_user}`; `GROUP` assignee the caller belongs to ->
  `:ok`, else `{:error, :assignee_group_not_member}`; `ROLE` assignee the
  caller holds -> `:ok`, else `{:error, :assignee_role_not_held}`.

  Performs no write -- `write_assignment/4` is never called from here. The
  actual completion mutation stays entirely inside
  `Letflow.Engine.complete_task/3`'s own transaction, unchanged by this
  function (REQ-048's module boundary: assignee authorization does not
  live inside `Letflow.Engine`).
  """
  @spec authorize_completion(
          task_id :: String.t(),
          actor_id :: Ecto.UUID.t(),
          opts :: complete_authz_opts()
        ) :: :ok | complete_authz_error()
  def authorize_completion(task_id, actor_id, opts) when is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, task_id} <- cast_task_id(task_id),
         {:ok, task} <- fetch_task_for_completion_authz(task_id, prefix) do
      scope = resolve_principal_scope(actor_id, prefix: prefix)
      apply_completion_authz(task, actor_id, scope)
    end
  end

  defp fetch_task_for_completion_authz(task_id, prefix) do
    case Repo.get(Task, task_id, prefix: prefix) do
      nil -> {:error, :task_not_found}
      %Task{} = task -> {:ok, task}
    end
  end

  defp apply_completion_authz(%Task{assignee_type: nil}, _actor_id, _scope), do: :ok

  defp apply_completion_authz(%Task{assignee_type: "USER", assignee_ref: ref}, actor_id, _scope)
       when ref == actor_id do
    :ok
  end

  defp apply_completion_authz(%Task{assignee_type: "USER"}, _actor_id, _scope) do
    {:error, :assigned_to_other_user}
  end

  defp apply_completion_authz(%Task{assignee_type: "GROUP", assignee_ref: ref}, _actor_id, scope) do
    if ref in scope.group_ids do
      :ok
    else
      {:error, :assignee_group_not_member}
    end
  end

  defp apply_completion_authz(%Task{assignee_type: "ROLE", assignee_ref: ref}, _actor_id, scope) do
    if ref in scope.role_names do
      :ok
    else
      {:error, :assignee_role_not_held}
    end
  end

  @type assign_attrs :: %{required(:user_id) => String.t()}
  @type assign_opts :: opts()

  @type assign_error ::
          {:error, :invalid_task_id}
          | {:error, :missing_user_id}
          | {:error, :task_not_found}
          | {:error, {:task_not_pending, status :: :completed | :cancelled}}
          | {:error, :already_assigned}
          | {:error, Ecto.Changeset.t()}
          | {:error, term()}

  @doc """
  Assigns an unassigned `PENDING` task to `attrs.user_id` (REQ-085 design doc
  §3.5) -- requires the task currently have no assignee (`WHERE ...
  assignee_ref IS NULL`), so two concurrent assigns can't silently overwrite
  each other's effect. No group/role-membership check on the target
  `user_id` -- consistent with REQ-083's own "assignee_ref is unvalidated
  free text" treatment of the read side, applied here to the write side.
  `attrs.user_id`'s presence is this function's own
  belt-and-suspenders guard (INV-8); the router's `Letflow.Api.Validation`
  call is the primary enforcement point.
  """
  @spec assign_task(task_id :: String.t(), attrs :: assign_attrs(), opts :: assign_opts()) ::
          {:ok, Task.t()} | assign_error()
  def assign_task(task_id, attrs, opts) when is_map(attrs) and is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, task_id} <- cast_task_id(task_id),
         {:ok, user_id} <- fetch_target_user_id(attrs) do
      Multi.new()
      |> Multi.run(:task, fn repo, _changes -> fetch_and_lock_task(repo, task_id, prefix) end)
      |> Multi.run(:apply, fn _repo, %{task: task} ->
        case task do
          %Task{assignee_ref: nil} -> write_assignment(task, "USER", user_id, prefix)
          %Task{} -> {:error, :already_assigned}
        end
      end)
      |> Multi.merge(fn changes -> record_task_assign_audit(changes, prefix) end)
      |> Repo.transaction()
      |> unwrap_write_result()
    end
  end

  # REQ-195 -- design §3.2's per-operation table claims `attrs.actor_id` is
  # "already an explicit, required field of assign_attrs"; verified against
  # this module's own `@type assign_attrs :: %{required(:user_id) =>
  # String.t()}` above and this function's body, that claim does not hold --
  # only `claim_attrs` (`claim_task/3`) carries `actor_id`, `assign_attrs`
  # does not. No actor context reaches this function today, and widening
  # `assign_attrs`/this function's signature to add one would need a
  # corresponding caller edit in lib/letflow/routers/tasks.ex, which this
  # requirement's own AC11 forbids (same class of gap as §3.1a/§3.1b) --
  # actor_id: nil. Flagged here rather than silently implemented as if the
  # design's claim were correct; see this requirement's SECURITY-REVIEWER
  # handoff for the explicit callout.
  defp record_task_assign_audit(%{task: before, apply: updated}, prefix) do
    Audit.append_multi(
      Multi.new(),
      :audit,
      %{
        actor_id: nil,
        action: "task.assign",
        resource_type: "task",
        resource_id: before.id,
        before_state: Task.audit_state(before),
        after_state: Task.audit_state(updated),
        trace_id: nil
      },
      prefix
    )
  end

  @type reassign_attrs :: %{required(:user_id) => String.t()}
  @type reassign_opts :: opts()

  @type reassign_error ::
          {:error, :invalid_task_id}
          | {:error, :missing_user_id}
          | {:error, :task_not_found}
          | {:error, {:task_not_pending, status :: :completed | :cancelled}}
          | {:error, :not_currently_assigned}
          | {:error, Ecto.Changeset.t()}
          | {:error, term()}

  @doc """
  Changes the assignee of an already-assigned `PENDING` task to
  `attrs.user_id` (REQ-085 design doc §3.6) -- requires the task currently
  have an assignee (`WHERE ... assignee_ref IS NOT NULL`, distinguishing a
  reassign from a first-time assign), unconditionally overwriting whatever
  `assignee_type`/`assignee_ref` was there before (`"USER"`/`"GROUP"`/`"ROLE"`).
  Same "no group/role check on target `user_id`" note as `assign_task/4`.
  """
  @spec reassign_task(task_id :: String.t(), attrs :: reassign_attrs(), opts :: reassign_opts()) ::
          {:ok, Task.t()} | reassign_error()
  def reassign_task(task_id, attrs, opts) when is_map(attrs) and is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, task_id} <- cast_task_id(task_id),
         {:ok, user_id} <- fetch_target_user_id(attrs) do
      Multi.new()
      |> Multi.run(:task, fn repo, _changes -> fetch_and_lock_task(repo, task_id, prefix) end)
      |> Multi.run(:apply, fn _repo, %{task: task} ->
        case task do
          %Task{assignee_ref: nil} -> {:error, :not_currently_assigned}
          %Task{} -> write_assignment(task, "USER", user_id, prefix)
        end
      end)
      |> Repo.transaction()
      |> unwrap_write_result()
    end
  end

  # ── claim/assign/reassign shared helpers ────────────────────────────────

  # M1 -- row-lock + fetch the tasks row, identical shape to
  # Letflow.Engine's own private fetch_and_lock_task/3 (a distinct function,
  # unreachable outside engine.ex) -- deliberately duplicated (a three-line
  # query, not worth a cross-module extraction for one duplicate), matching
  # this design's own stated reasoning (design doc §3.0).
  defp fetch_and_lock_task(repo, task_id, prefix) do
    Task
    |> where([t], t.id == ^task_id)
    |> lock("FOR UPDATE")
    |> repo.one(prefix: prefix)
    |> case do
      nil -> {:error, :task_not_found}
      %Task{status: :pending} = task -> {:ok, task}
      %Task{status: status} -> {:error, {:task_not_pending, status}}
    end
  end

  defp write_assignment(task, assignee_type, assignee_ref, prefix) do
    task
    |> Task.assignment_changeset(%{assignee_type: assignee_type, assignee_ref: assignee_ref})
    |> Repo.update(prefix: prefix)
  end

  defp fetch_target_user_id(attrs) do
    case Map.get(attrs, :user_id) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :missing_user_id}
    end
  end

  defp cast_task_id(task_id) do
    case Ecto.UUID.cast(task_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_task_id}
    end
  end

  # Unwraps an Ecto.Multi transaction result down to this module's own
  # {:ok, Task.t()} | {:error, reason} contract -- the identical catch-all
  # shape Letflow.Engine's own interpret_complete_result/1 tail establishes
  # (engine.ex), restated here since this is a different module.
  defp unwrap_write_result({:ok, %{apply: task}}), do: {:ok, task}
  defp unwrap_write_result({:error, _failed_step, reason, _changes}), do: {:error, reason}

  # ── list_tasks/2 private helpers ────────────────────────────────────────

  defp filter_by_status(query, nil), do: query
  defp filter_by_status(query, status), do: from(t in query, where: t.status == ^status)

  defp filter_by_instance_id(query, nil), do: query

  defp filter_by_instance_id(query, instance_id) do
    from(t in query, where: t.instance_id == ^instance_id)
  end

  defp filter_by_assignee_scope(query, :unfiltered), do: query

  defp filter_by_assignee_scope(query, {:explicit_user, user_id}) do
    from(t in query, where: t.assignee_type == "USER" and t.assignee_ref == ^user_id)
  end

  defp filter_by_assignee_scope(
         query,
         {:principal,
          %{
            user_id: user_id,
            group_ids: group_ids,
            role_names: role_names
          }}
       ) do
    from(t in query,
      where:
        (t.assignee_type == "USER" and t.assignee_ref == ^user_id) or
          (t.assignee_type == "GROUP" and t.assignee_ref in ^group_ids) or
          (t.assignee_type == "ROLE" and t.assignee_ref in ^role_names)
    )
  end

  defp filter_by_scope(query, :all), do: query
  defp filter_by_scope(query, :none), do: from(t in query, where: false)

  defp filter_by_scope(query, {:nodes, ids}) when is_list(ids),
    do: from(t in query, where: t.scope_node_id in ^ids)

  defp filter_by_list_cursor(query, nil), do: query

  defp filter_by_list_cursor(query, {inserted_at_us, id}) do
    ts = DateTime.from_unix!(inserted_at_us, :microsecond)
    from(t in query, where: {t.inserted_at, t.id} < {^ts, ^id})
  end

  # Decodes the raw encoded cursor string into a `{inserted_at_us, id}` seek
  # tuple, or passes `nil` through unchanged. Collapses
  # Pagination.decode_cursor/4's :invalid_base64/:invalid_cursor into one
  # atom -- a cursor is opaque to callers, so there's no caller-actionable
  # difference between the two failure shapes.
  @spec decode_list_cursor(String.t() | nil) ::
          {:ok, {non_neg_integer(), String.t()} | nil}
          | {:error, :invalid_cursor | :wrong_endpoint | :expired}
  defp decode_list_cursor(nil), do: {:ok, nil}

  defp decode_list_cursor(raw) when is_binary(raw) do
    case Pagination.decode_cursor(raw, @list_cursor_prefix, byte_size(@list_cursor_prefix)) do
      {:ok, %Pagination.Cursor{} = cursor} -> {:ok, decode_seek(cursor)}
      {:error, :wrong_endpoint} -> {:error, :wrong_endpoint}
      {:error, :expired} -> {:error, :expired}
      {:error, _invalid_base64_or_invalid_cursor} -> {:error, :invalid_cursor}
    end
  end

  defp decode_seek(%Pagination.Cursor{inner: inner}) do
    prefix_len = byte_size(@list_cursor_prefix)
    rest = binary_part(inner, prefix_len, byte_size(inner) - prefix_len)
    [ts_str, id_str] = String.split(rest, ":", parts: 2)
    {String.to_integer(ts_str), id_str}
  end

  # `rows` are now `{Task.t(), form_version}` pairs (REQ-126's
  # instance_definition_snapshots left_join) -- pagination itself stays keyed
  # on the Task half only; the tuple just rides along unchanged.
  defp split_list_page(rows, page_size) when length(rows) > page_size do
    {page, [_extra_row]} = Enum.split(rows, page_size)
    {page, build_list_next_cursor(List.last(page))}
  end

  defp split_list_page(rows, _page_size), do: {rows, nil}

  defp build_list_next_cursor({%Task{id: id, inserted_at: inserted_at}, _form_version}) do
    inserted_at_us = DateTime.to_unix(inserted_at, :microsecond)

    @list_cursor_prefix
    |> Pagination.build_raw_cursor(inserted_at_us, id)
    |> Pagination.encode_cursor()
  end
end
