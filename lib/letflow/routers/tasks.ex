defmodule Letflow.Routers.Tasks do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Task read+write sub-router, mounted at `/tasks` by
  `Letflow.Plugs.ApiPipeline`. REQ-083 built the read path (`handleList`
  L89, `handleGetById` L290, `handleInbox` L960 of `src/api/routes/tasks.zig`,
  `lib/letflow/design/req083-task-routes-read.md`). REQ-085 adds the write
  path (`handleComplete` L341, `handleClaim` L551, `handleAssign` L628,
  `handleReassign` L736 — same source file — `lib/letflow/design/req085-task-routes-write.md`).

  * GET  /tasks             -> `Letflow.Tasks.list_tasks/2` (`:TasksList` policy key)
  * GET  /tasks/inbox       -> `Letflow.Tasks.list_tasks/2`, forced per-principal scope (`:TasksList` policy key)
  * GET  /tasks/:id         -> `Letflow.Tasks.get_task/2` (`:TasksGetById` policy key)
  * POST /tasks/:id/complete -> `Letflow.Engine.complete_task/3` (`:TasksComplete` policy key) — the ONLY call this router makes to drive completion; zero `Repo.` calls anywhere in this module (INV-TW85-2). Completion is an engine transition (output variables merge, token advances) — a handler that flipped the `tasks` row to `COMPLETED` directly would leave the owning instance permanently stalled.
  * POST /tasks/:id/claim   -> `Letflow.Tasks.claim_task/3` (`:TasksComplete` policy key, REQ-085 design §2 — not `:TasksAssign`, since claiming your own inbox item is a completion-track action, not an assignment one)
  * POST /tasks/:id/assign  -> `Letflow.Tasks.assign_task/4` (`:TasksAssign` policy key)
  * POST /tasks/:id/reassign -> `Letflow.Tasks.reassign_task/4` (`:TasksAssign` policy key — `required_permission/1` maps both `:TasksAssign`/`:TasksReassign` endpoint keys to the same `:TasksAssign` permission)

  Every route is deliberately thin — scoped-prefix resolution, authorization,
  request validation, and a response-shape allowlist, with all persistence
  delegated to `Letflow.Tasks`/`Letflow.Engine`. All unmatched requests
  return the RFC 9457 404 problem document.

  ## Authorization (REQ-131)

  Every route below is declared via `authz_get`/`authz_post`
  (`Letflow.Api.AuthorizedRouter`) with its own policy key —
  `Letflow.Plugs.Authorize` evaluates it before this module's handler ever
  runs. The route-local `with_authorized_scope/4` copy that used to live
  here (the same established pattern `Letflow.Routers.Identity` and
  `Letflow.Routers.Tenants` also used to have) is deleted, not adapted, per
  REQ-130's design §2.4.

  ## Concurrency (`claim`/`assign`/`reassign`, AC4)

  `Letflow.Tasks.claim_task/3`/`assign_task/4`/`reassign_task/4` each acquire
  `SELECT ... FOR UPDATE` on the single `tasks` row via `Letflow.Tasks`'s own
  private `fetch_and_lock_task/3`, inside one `Ecto.Multi` per call — the
  same row-lock-then-check-in-Elixir idiom `Letflow.Engine.complete_task/3`
  already established. This router adds no second locking/concurrency
  scheme of its own; it only calls those functions and maps their results.

  ## Route-match ordering — `/inbox` before `/:id`

  PROVENANCE (historical, not current decision authority):
  `Plug.Router`'s `get "/:id"` would otherwise also match the literal path
  segment `"inbox"` as `id = "inbox"`, which would then fail
  `Ecto.UUID.cast/1` and misreport as `{:error, :invalid_id}` (400) instead of
  serving the inbox. `get "/inbox"` is declared textually **before**
  `get "/:id"` below, so `Plug.Router`'s documented first-match-wins
  semantics resolve the literal path before the parameterized one gets a
  chance to swallow it (`main.zig`'s dispatch order does the same for the
  same reason).

  ## `endpoint_policy_key/2` — one new clause on `Letflow.Api.Authorization` (OQ-8)

  PROVENANCE (historical, not current decision authority):
  `Letflow.Api.Authorization.endpoint_policy_key/2` had no `("GET",
  "/tasks/inbox")` clause before this requirement — one was added, mapping to
  the same `:TasksList` policy key `GET /tasks` already uses, since inbox
  listing is only a forced-scope variant of the same list operation and has
  no reason to be gated by a different permission (the historical
  `handleInbox` delegates to `handleList` the same way, with the *only*
  `evaluateAccess` call for that whole flow happening inside it —
  `tasks.zig` L960-982). Additive-only,
  changes no existing clause's behavior (every existing `endpoint_policy_key/2`
  call site is pattern-matched by exact string).

  ## Inbox scoping — per-principal, not merely per-tenant

  For a task-worker-only caller (`Authorization.is_task_worker_only?/1`),
  `GET /tasks` (via `evaluate_access/2`'s own `AllowWithRowFilter`
  decision), `GET /tasks/inbox` and `GET /tasks/:id` (a task outside the
  scope answers the 404 of a nonexistent id) force `assignee_scope` to
  `{:principal, Letflow.Tasks.resolve_principal_scope(user_id, opts)}` —
  never a caller-supplied filter (INV-2: a task-worker's row scope can never
  be widened by a request-supplied `assignee_id`/`status`/`instance_id`
  param). For any other caller (operator, designer, admin), `GET
  /tasks/inbox` returns `:unfiltered` — **every** task in the tenant, not
  merely "assigned to me." This is deliberate, not a bug: an operator sits
  above individual assignment, so an operator's "inbox" is the whole queue,
  not a per-principal filter that would hide work from the people
  responsible for the tenant's whole task backlog.

  ## Response allowlists (INV-2, AC5)

  `task_list_item_map/2` (11 keys) / `task_detail_map/3` (14 keys, adds
  `correlation_key`/`updated_at`/`form_schema`) are hand-built maps, never a
  `Jason.Encoder`/struct-wholesale encoding — matching
  `Letflow.Routers.Identity`'s `user_map/1` discipline exactly. `claimed_by`
  is omitted entirely (no Letflow schema column exists yet — REQ-085's own
  concern). `output_variables`/`completed_by`/`completed_at`/`cancelled_at`
  remain excluded — none is named by any REQ-083 or REQ-286 acceptance
  criterion. `form_schema` (REQ-286) is exposed on the task-detail response
  only, not on `task_list_item_map/2` (so `GET /tasks`/`GET /tasks/inbox` do
  not carry it) — sourced directly from the task's own `form_schema` column,
  which `Letflow.Engine.TaskActivation` (REQ-273) populates once, at
  activation, from the node's `form_schema` attribute in the version-pinned
  graph the instance was created or last promoted against. No `Task`
  changeset ever writes this column a second time (`insert_changeset/2` is
  the only one that casts it), so reading the column back is automatically
  the version pinned at activation — no live re-fetch of the current process
  definition, and no additional pinning mechanism, is involved. `null` is
  served, not omitted, when a task's node carries no `form_schema` (the
  common case until definitions start authoring one). This requirement
  introduces no validation of submitted task-completion output against this
  schema; `variable_schemas` (REQ-109) remains the sole server-side
  validation authority — `form_schema` here is a rendering payload only,
  never fed into `Letflow.Engine.VariableMerge` or any output-variable check.

  `form_id`/`form_version` (REQ-126, `lib/letflow/design/req126-form-version-pinning.md`)
  are the two new keys as of this requirement — `form_id` is the task's own
  `node_id`, `form_version` is the pinned `instance_definition_snapshots.definition_ver`
  `Letflow.Tasks.get_task/2`/`list_tasks/2`/`get_form_version/2` now surface.
  See `Letflow.Tasks`'s own moduledoc ("Form version pinning") for why this
  is a new read rather than a new instance of `Letflow.Engine.PinResolver`'s
  machinery.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.ScopeGate
  alias Letflow.Tasks.ScopeResolver

  alias Letflow.Api.Authorization
  alias Letflow.Api.Error
  alias Letflow.Api.Pagination
  alias Letflow.Api.Response
  alias Letflow.Api.Validation
  alias Letflow.Api.Validation.FieldConstraint
  alias Letflow.Engine
  alias Letflow.Tasks

  # REQ-518 PR 2d (AC 20, design 7.1 T1-T7): the two list routes are `:filter` (the handler passes
  # the caller's allowed node set to `Tasks.list_tasks/2`); the five single-task routes are
  # `{:resolver, {ScopeResolver, :task_scope}}` (the handler gates through `ScopeGate` and
  # `Tasks.in_scope/3`, or `Tasks.get_task/2` with the set). Approver rule F1: a scoped caller
  # needs a covering TASK_WORKER grant (docs/roles.md "Known limitation: scoped approvers").
  authz_get "/inbox", :TasksList, scope: :filter do
    handle_inbox(conn, conn.assigns.scoped_opts, conn.assigns.access_decision)
  end

  authz_get "/", :TasksList, scope: :filter do
    handle_list(conn, conn.assigns.scoped_opts, conn.assigns.access_decision)
  end

  authz_get "/:id", :TasksGetById, scope: {:resolver, {ScopeResolver, :task_scope}} do
    handle_get_by_id(conn, conn.params["id"], conn.assigns.scoped_opts)
  end

  authz_post "/:id/complete", :TasksComplete, scope: {:resolver, {ScopeResolver, :task_scope}} do
    handle_complete(conn, conn.params["id"], conn.assigns.scoped_opts)
  end

  authz_post "/:id/claim", :TasksComplete, scope: {:resolver, {ScopeResolver, :task_scope}} do
    handle_claim(conn, conn.params["id"], conn.assigns.scoped_opts)
  end

  authz_post "/:id/assign", :TasksAssign, scope: {:resolver, {ScopeResolver, :task_scope}} do
    handle_assign(conn, conn.params["id"], conn.assigns.scoped_opts)
  end

  authz_post "/:id/reassign", :TasksReassign, scope: {:resolver, {ScopeResolver, :task_scope}} do
    handle_reassign(conn, conn.params["id"], conn.assigns.scoped_opts)
  end

  authz_unmatched(:ordinary)

  # ── GET /tasks (design §5.2) ────────────────────────────────────────────

  defp handle_list(conn, opts, decision) do
    conn = fetch_query_params(conn)
    query = conn.query_params

    with {:ok, status} <- parse_status_param(Map.get(query, "status")),
         {:ok, instance_id} <- parse_instance_id_param(Map.get(query, "instance_id")),
         {:ok, raw_page_size} <- Pagination.parse_page_size_param(Map.get(query, "page_size")),
         {:ok, page_size} <- Pagination.validate_page_size(raw_page_size) do
      assignee_id = non_empty(Map.get(query, "assignee_id"))
      assignee_scope = build_list_assignee_scope(decision, assignee_id, opts)
      {conn, scope} = ScopeGate.scope_set_for_role(conn, :TasksList, "TASK_WORKER")

      Tasks.list_tasks(
        %{
          status: status,
          instance_id: instance_id,
          assignee_scope: assignee_scope,
          scope: scope,
          cursor: Map.get(query, "cursor"),
          page_size: page_size
        },
        opts
      )
      |> handle_list_result(conn)
    else
      {:error, :invalid_status} ->
        Response.bad_request(conn, "status must be one of PENDING, COMPLETED, CANCELLED")

      {:error, :invalid_instance_id} ->
        Response.bad_request(conn, "instance_id is not a valid UUID")

      {:error, :invalid_page_size} ->
        Response.bad_request(conn, "invalid page_size")

      {:error, :page_size_too_large} ->
        Response.bad_request(conn, "page_size out of range")
    end
  end

  # A task-worker-only caller's scope is always forced to their own
  # principal scope, regardless of any assignee_id the caller supplied
  # (INV-2 -- AllowWithRowFilter's row scope can never be widened by a
  # request-supplied filter).
  defp build_list_assignee_scope(
         %Authorization.AccessDecision{task_scope: {:own_user_and_groups, user_id}},
         _assignee_id,
         opts
       ) do
    {:principal, Tasks.resolve_principal_scope(user_id, opts)}
  end

  defp build_list_assignee_scope(%Authorization.AccessDecision{task_scope: :all}, nil, _opts) do
    :unfiltered
  end

  defp build_list_assignee_scope(
         %Authorization.AccessDecision{task_scope: :all},
         assignee_id,
         _opts
       ) do
    {:explicit_user, assignee_id}
  end

  # ── GET /tasks/inbox (design §5.3) ──────────────────────────────────────

  defp handle_inbox(conn, opts, _decision) do
    conn = fetch_query_params(conn)
    query = conn.query_params

    with {:ok, raw_page_size} <- Pagination.parse_page_size_param(Map.get(query, "page_size")),
         {:ok, page_size} <- Pagination.validate_page_size(raw_page_size) do
      user_id = conn.assigns.auth_context.user_id
      assignee_scope = build_inbox_assignee_scope(conn, user_id, opts)
      {conn, scope} = ScopeGate.scope_set_for_role(conn, :TasksList, "TASK_WORKER")

      Tasks.list_tasks(
        %{
          assignee_scope: assignee_scope,
          scope: scope,
          cursor: Map.get(query, "cursor"),
          page_size: page_size
        },
        opts
      )
      |> handle_list_result(conn)
    else
      {:error, :invalid_page_size} ->
        Response.bad_request(conn, "invalid page_size")

      {:error, :page_size_too_large} ->
        Response.bad_request(conn, "page_size out of range")
    end
  end

  # PROVENANCE (historical, not current decision authority):
  # `status`/`instance_id`/`assignee_id` query params, if present, are
  # silently ignored for this endpoint -- inbox's assignee scope is always
  # forced (per-principal or unfiltered, see INV-2 above), so a
  # caller-supplied filter on these fields would have no effect regardless
  # (main.zig's inbox branch never populates them either, for the same
  # reason).
  defp build_inbox_assignee_scope(conn, user_id, opts) do
    # REQ-447 PR 2 (design 3.5): without the drop, a non-platform context carrying
    # PLATFORM_ADMIN + TASK_WORKER would get an UNFILTERED inbox.
    platform_tenant? =
      Letflow.PlatformTenant.platform_tenant?(Map.get(conn.assigns.auth_context, :tenant_id))

    roles = Authorization.effective_roles(conn.assigns.auth_context.roles, platform_tenant?)

    if Authorization.is_task_worker_only?(roles) do
      {:principal, Tasks.resolve_principal_scope(user_id, opts)}
    else
      :unfiltered
    end
  end

  # ── Shared list/inbox result handling (design §5.2 points 5-6) ─────────

  defp handle_list_result({:ok, %{items: items, next_cursor: next_cursor}}, conn) do
    Response.ok(conn, %{
      "items" =>
        Enum.map(items, fn {task, form_version} -> task_list_item_map(task, form_version) end),
      "next_cursor" => next_cursor,
      "count" => length(items)
    })
  end

  defp handle_list_result({:error, :invalid_cursor}, conn) do
    Response.unprocessable(conn, "cursor is not valid for this endpoint")
  end

  defp handle_list_result({:error, :wrong_endpoint}, conn) do
    Response.unprocessable(conn, "cursor is not valid for this endpoint")
  end

  defp handle_list_result({:error, :expired}, conn) do
    Response.send_problem(conn, Error.cursor_expired())
  end

  # ── GET /tasks/:id (design §5.4) ────────────────────────────────────────

  defp handle_get_by_id(conn, id, opts) do
    {conn, scope} = ScopeGate.scope_set_for_role(conn, :TasksGetById, "TASK_WORKER")

    # Same per-principal row scope as GET /tasks/inbox: a task-worker-only caller reads only
    # tasks assigned to them, their groups or their roles; anything else answers 404 (INV-2/5).
    assignee_scope = build_inbox_assignee_scope(conn, conn.assigns.auth_context.user_id, opts)

    get_opts = opts |> Keyword.put(:scope, scope) |> Keyword.put(:assignee_scope, assignee_scope)

    case Tasks.get_task(id, get_opts) do
      {:ok, {task, correlation_key, form_version}} ->
        Response.ok(conn, task_detail_map(task, correlation_key, form_version))

      {:error, :not_found} ->
        Response.not_found(conn)

      {:error, :invalid_id} ->
        Response.bad_request(conn, "task_id is not a valid UUID")
    end
  end

  # ── POST /tasks/:id/complete (REQ-085 design §5.2, ISS-0942) ────────────
  #
  # INV-TW85-2: this handler performs ZERO Repo. calls and ZERO
  # Task.complete_changeset/2 calls -- completion is driven entirely by
  # Letflow.Engine.complete_task/3 (REQ-048), the engine entry point. A
  # handler that flipped the tasks row to COMPLETED directly, without going
  # through that function, would leave the owning instance permanently
  # stalled (output variables never merged, token never advanced) -- the
  # single most damaging way to get this route wrong. Do not add a Repo call
  # here under any circumstance.
  #
  # ISS-0942: `Tasks.authorize_completion/3` runs BEFORE
  # `Engine.complete_task/3` on every path -- a caller who is not the
  # task's `USER`/`GROUP`/`ROLE` assignee is rejected with 403 here and
  # `Engine.complete_task/3` is never reached (no transaction opened, no
  # idempotency_key even generated). See
  # lib/letflow/design/iss0942-task-complete-authorization-gap.md §3.
  defp handle_complete(conn, id, opts) do
    actor_id = conn.assigns.auth_context.user_id
    {conn, scope} = ScopeGate.scope_set_for_role(conn, :TasksComplete, "TASK_WORKER")
    {conn, f1} = ScopeGate.f1_principal(conn, :TasksComplete)

    # REQ-518 PR 2d: the scope gate comes first; an out-of-scope task answers like a nonexistent
    # one, and the routing-role errors below stay as they were (AC 14).
    with :ok <- Tasks.in_scope(id, scope, opts),
         :ok <- Tasks.authorize_completion(id, actor_id, opts) do
      output_variables = conn.body_params
      idempotency_key = Ecto.UUID.generate()

      attrs = %{
        output_variables: output_variables,
        actor_id: actor_id,
        idempotency_key: idempotency_key
      }

      id
      |> Engine.complete_task(attrs, Keyword.put(opts, :f1, f1))
      |> handle_complete_result(conn)
    else
      {:error, reason} ->
        handle_complete_result({:error, reason}, conn)
    end
  end

  defp handle_complete_result({:ok, result}, conn) do
    Response.ok(conn, complete_result_map(result))
  end

  defp handle_complete_result({:error, :invalid_task_id}, conn) do
    Response.bad_request(conn, "task_id is not a valid UUID")
  end

  defp handle_complete_result({:error, :invalid_output_variables}, conn) do
    Response.unprocessable(conn, "output_variables must be a JSON object")
  end

  defp handle_complete_result({:error, :task_not_found}, conn) do
    Response.not_found(conn)
  end

  defp handle_complete_result({:error, {:task_not_pending, _status}}, conn) do
    Response.conflict(conn, "task is not pending")
  end

  # ISS-0944: the owning InstanceProjection is no longer :active (it is
  # :completed, :cancelled, or :error -- see Engine.complete_error/0's
  # {:instance_not_active, status} member). One clause covers all three
  # status values, same reasoning as {:task_not_pending, _status} above.
  defp handle_complete_result({:error, {:instance_not_active, status}}, conn) do
    Response.conflict(conn, "instance is #{status}")
  end

  defp handle_complete_result({:error, %Ecto.Changeset{}}, conn) do
    Response.unprocessable(conn, "validation failed")
  end

  # REQ-460 (design req459 §3): the completion was refused before any state change
  # (required_outputs key missing, or a variable_schema rejected a value). 422, not
  # 409: the same caller can fix it by resending the whole corrected body. Names
  # only; the body never carries a value.
  defp handle_complete_result(
         {:error, {:output_refused, %{missing_keys: missing, rejected_keys: rejected}}},
         conn
       ) do
    Response.output_refused(conn, missing, rejected)
  end

  # REQ-463 (design req459 §4): separation of duties -- the caller most recently
  # completed a node this one names in distinct_from. 403 with ONE constant body
  # (Response.separation_of_duties/1), identical on complete and claim.
  defp handle_complete_result({:error, :separation_of_duties}, conn) do
    Response.separation_of_duties(conn)
  end

  # ISS-0942: Tasks.authorize_completion/3's three assignee-mismatch atoms.
  # Deliberately 403 (Response.forbidden/2), NOT 409 -- a divergence from
  # handle_claim_result/3's own mapping of these exact same atoms to 409
  # Conflict. claim is a self-assignment attempt whose failure is a state
  # conflict; complete is an authorization decision -- IDN-03's role matrix
  # is explicit that this is 403 Forbidden. Detail strings copied verbatim
  # from handle_claim_result/3's matching clauses for message consistency
  # between the two endpoints -- only the status code differs. See
  # lib/letflow/design/iss0942-task-complete-authorization-gap.md §4.
  defp handle_complete_result({:error, :assigned_to_other_user}, conn) do
    Response.forbidden(conn, "task is assigned to a different user")
  end

  defp handle_complete_result({:error, :assignee_group_not_member}, conn) do
    Response.forbidden(conn, "caller is not a member of the assigned group")
  end

  defp handle_complete_result({:error, :assignee_role_not_held}, conn) do
    Response.forbidden(conn, "caller does not hold the assigned role")
  end

  # ISS-0917 amendment to req085 design §5.5.1: complete_task/3 returns
  # {:instance_execution_error, error_type, affected} AFTER its Multi has
  # committed -- the instance is durably parked in ERROR for an operator
  # (req061 §5.4), the request itself was valid and authorised. That is a
  # resource-state conflict (409), not a platform malfunction (500). The
  # detail names ONLY the error_type atom: `affected`, variables, reason text
  # and details are never echoed (INV-2). Uniform for every error_type.
  defp handle_complete_result({:error, {:instance_execution_error, error_type, _affected}}, conn)
       when is_atom(error_type) do
    Response.conflict(conn, "instance entered ERROR status: " <> Atom.to_string(error_type))
  end

  # GH #2587 PR B2: a declarative entity write was refused. One stable code and the declared
  # line index (null for contention); the status is a function of the code alone. Index 20 with
  # `validation_failed` means "the 20-line cap was exceeded", not a declared line.
  defp handle_complete_result({:error, {:entity_write_refused, :contention, code}}, conn)
       when is_atom(code) do
    Response.entity_write_refused(conn, code, nil)
  end

  defp handle_complete_result({:error, {:entity_write_refused, index, code}}, conn)
       when is_integer(index) and is_atom(code) do
    Response.entity_write_refused(conn, code, index)
  end

  # The activator is deactivated: a refusal stub, the task stays pending.
  defp handle_complete_result({:error, :entity_write_needs_reactivation}, conn) do
    Response.entity_write_needs_reactivation(conn)
  end

  # An internal fault of a line step: the step atom is logged by the engine, never rendered.
  defp handle_complete_result({:error, {:entity_write_failed, _index, _step}}, conn) do
    Response.internal_error(conn)
  end

  # Catch-all: every other complete_error() member (:invalid_schema_name,
  # :instance_not_found, :snapshot_not_found,
  # {:graph_structure_invalid, _}, {:missing_token_record, _},
  # {:transition_failed, _}, {:new_token_during_resume_not_supported, _},
  # {:task_activation_failed, _}, {:event_append_failed, _},
  # :missing_actor_id, :missing_idempotency_key,
  # {:error, term()}) -- either
  # structurally unreachable given this handler's own router-derived inputs,
  # or a genuine data-integrity/downstream failure this caller cannot fix by
  # retrying (design §5.5.1). complete_task/3's own catch-all already
  # guarantees it never raises, so this is a typed-tuple match, not a bare
  # pattern that can raise (INV-8).
  defp handle_complete_result({:error, _reason}, conn) do
    Response.internal_error(conn)
  end

  # ── POST /tasks/:id/claim (REQ-085 design §5.3) ─────────────────────────

  defp handle_claim(conn, id, opts) do
    attrs = %{actor_id: conn.assigns.auth_context.user_id}
    {conn, scope} = ScopeGate.scope_set_for_role(conn, :TasksComplete, "TASK_WORKER")
    {conn, f1} = ScopeGate.f1_principal(conn, :TasksComplete)

    case Tasks.in_scope(id, scope, opts) do
      :ok ->
        id
        |> Tasks.claim_task(attrs, Keyword.put(opts, :f1, f1))
        |> handle_claim_result(conn, opts)

      {:error, _reason} = error ->
        handle_claim_result(error, conn, opts)
    end
  end

  defp handle_claim_result({:ok, task}, conn, opts) do
    Response.ok(conn, task_detail_map(task, nil, Tasks.get_form_version(task.instance_id, opts)))
  end

  defp handle_claim_result({:error, :invalid_task_id}, conn, _opts) do
    Response.bad_request(conn, "task_id is not a valid UUID")
  end

  defp handle_claim_result({:error, :task_not_found}, conn, _opts) do
    Response.not_found(conn)
  end

  defp handle_claim_result({:error, {:task_not_pending, _status}}, conn, _opts) do
    Response.conflict(conn, "task is not pending")
  end

  defp handle_claim_result({:error, :assigned_to_other_user}, conn, _opts) do
    Response.conflict(conn, "task is assigned to a different user")
  end

  defp handle_claim_result({:error, :assignee_group_not_member}, conn, _opts) do
    Response.conflict(conn, "caller is not a member of the assigned group")
  end

  defp handle_claim_result({:error, :assignee_role_not_held}, conn, _opts) do
    Response.conflict(conn, "caller does not hold the assigned role")
  end

  defp handle_claim_result({:error, :not_claimable}, conn, _opts) do
    Response.conflict(conn, "task cannot be claimed")
  end

  # REQ-463 (design req459 §4, §6, D-2): deliberately 403 with the constant body,
  # unlike the 409 of the eligibility refusals above, so both endpoints answer
  # byte-identically.
  defp handle_claim_result({:error, :separation_of_duties}, conn, _opts) do
    Response.separation_of_duties(conn)
  end

  defp handle_claim_result({:error, _reason}, conn, _opts) do
    Response.internal_error(conn)
  end

  # ── POST /tasks/:id/assign, POST /tasks/:id/reassign (REQ-085 design §5.4) ─

  @user_id_schema [
    %FieldConstraint{name: "user_id", required: true, type: :string, reject_empty_string: true}
  ]

  defp handle_assign(conn, id, opts) do
    case Validation.validate(@user_id_schema, conn.body_params) do
      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))

      {:ok, %{"user_id" => user_id}} ->
        # Scope after validation: a nonexistent and an out-of-scope task with an invalid body
        # both answer the validation error, a valid body both answer 404 (no existence oracle).
        {conn, scope} = ScopeGate.scope_set(conn, :TasksAssign)

        with :ok <- Tasks.in_scope(id, scope, opts) do
          id
          |> Tasks.assign_task(%{user_id: user_id}, opts)
          |> handle_assign_result(conn, opts)
        else
          {:error, _reason} = error -> handle_assign_result(error, conn, opts)
        end
    end
  end

  defp handle_reassign(conn, id, opts) do
    case Validation.validate(@user_id_schema, conn.body_params) do
      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))

      {:ok, %{"user_id" => user_id}} ->
        {conn, scope} = ScopeGate.scope_set(conn, :TasksReassign)

        with :ok <- Tasks.in_scope(id, scope, opts) do
          id
          |> Tasks.reassign_task(%{user_id: user_id}, opts)
          |> handle_reassign_result(conn, opts)
        else
          {:error, _reason} = error -> handle_reassign_result(error, conn, opts)
        end
    end
  end

  defp handle_assign_result({:ok, task}, conn, opts) do
    Response.ok(conn, task_detail_map(task, nil, Tasks.get_form_version(task.instance_id, opts)))
  end

  defp handle_assign_result({:error, :invalid_task_id}, conn, _opts) do
    Response.bad_request(conn, "task_id is not a valid UUID")
  end

  # Belt-and-suspenders -- Validation.validate/2 above is expected to
  # already have rejected a missing/empty user_id before assign_task/4 is
  # ever reached.
  defp handle_assign_result({:error, :missing_user_id}, conn, _opts) do
    Response.unprocessable(conn, "user_id is required")
  end

  defp handle_assign_result({:error, :task_not_found}, conn, _opts) do
    Response.not_found(conn)
  end

  defp handle_assign_result({:error, {:task_not_pending, _status}}, conn, _opts) do
    Response.conflict(conn, "task is not pending")
  end

  defp handle_assign_result({:error, :already_assigned}, conn, _opts) do
    Response.conflict(conn, "task is already assigned")
  end

  defp handle_assign_result({:error, _reason}, conn, _opts) do
    Response.internal_error(conn)
  end

  defp handle_reassign_result({:ok, task}, conn, opts) do
    Response.ok(conn, task_detail_map(task, nil, Tasks.get_form_version(task.instance_id, opts)))
  end

  defp handle_reassign_result({:error, :invalid_task_id}, conn, _opts) do
    Response.bad_request(conn, "task_id is not a valid UUID")
  end

  defp handle_reassign_result({:error, :missing_user_id}, conn, _opts) do
    Response.unprocessable(conn, "user_id is required")
  end

  defp handle_reassign_result({:error, :task_not_found}, conn, _opts) do
    Response.not_found(conn)
  end

  defp handle_reassign_result({:error, {:task_not_pending, _status}}, conn, _opts) do
    Response.conflict(conn, "task is not pending")
  end

  defp handle_reassign_result({:error, :not_currently_assigned}, conn, _opts) do
    Response.conflict(conn, "task is not currently assigned")
  end

  defp handle_reassign_result({:error, _reason}, conn, _opts) do
    Response.internal_error(conn)
  end

  # ── Query-param parsing helpers ─────────────────────────────────────────

  defp parse_status_param(nil), do: {:ok, nil}
  defp parse_status_param("PENDING"), do: {:ok, :pending}
  defp parse_status_param("COMPLETED"), do: {:ok, :completed}
  defp parse_status_param("CANCELLED"), do: {:ok, :cancelled}
  defp parse_status_param(_other), do: {:error, :invalid_status}

  defp parse_instance_id_param(nil), do: {:ok, nil}

  defp parse_instance_id_param(raw) when is_binary(raw) do
    case Ecto.UUID.cast(raw) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_instance_id}
    end
  end

  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(value) when is_binary(value), do: value

  # ── Response allowlists (design §5.5, INV-2, AC5) ───────────────────────

  @doc false
  # Nine base keys, hand-built -- never a Jason.Encoder derivation over
  # %Letflow.Engine.Task{} -- plus form_id/form_version (REQ-126), eleven
  # keys total. output_variables/completed_by/completed_at/cancelled_at/
  # inserted_at/updated_at are deliberately excluded from this function (see
  # moduledoc, design §5.5); tasks.form_schema is likewise excluded from this
  # function specifically -- it is exposed only on task_detail_map/3's output
  # (REQ-286), not here, so GET /tasks and GET /tasks/inbox do not carry it.
  #
  # form_id is task.node_id itself (no join needed -- REQ-126 design §4.3);
  # form_version is threaded in by the caller, sourced from the
  # instance_definition_snapshots left_join Letflow.Tasks.get_task/2 /
  # list_tasks/2 / get_form_version/2 already performed.
  @spec task_list_item_map(Letflow.Engine.Task.t(), form_version :: String.t() | nil) :: map()
  defp task_list_item_map(%Letflow.Engine.Task{} = task, form_version) do
    %{
      "id" => task.id,
      "instance_id" => task.instance_id,
      "node_id" => task.node_id,
      "node_name" => task.node_name,
      "status" => task_status_string(task.status),
      "assignee_type" => task.assignee_type,
      "assignee_ref" => task.assignee_ref,
      "created_at" => DateTime.to_iso8601(task.inserted_at),
      "token_id" => task.token_id,
      "form_id" => task.node_id,
      "form_version" => form_version
    }
  end

  @doc false
  # Same eleven keys as task_list_item_map/2, plus correlation_key,
  # updated_at, and form_schema (REQ-286) -- fourteen keys total. No
  # claimed_by (no Letflow schema column exists yet; see moduledoc).
  @spec task_detail_map(
          Letflow.Engine.Task.t(),
          correlation_key :: String.t() | nil,
          form_version :: String.t() | nil
        ) :: map()
  defp task_detail_map(%Letflow.Engine.Task{} = task, correlation_key, form_version) do
    task
    |> task_list_item_map(form_version)
    |> Map.put("correlation_key", correlation_key)
    |> Map.put("updated_at", DateTime.to_iso8601(task.updated_at))
    |> Map.put("form_schema", task.form_schema)
  end

  # task.status is loaded as one of :pending/:completed/:cancelled; the
  # schema's own Ecto.Enum mapping dumps each to its uppercase DB string
  # ("PENDING"/"COMPLETED"/"CANCELLED", see Letflow.Engine.Task's moduledoc
  # INV-EE43-4) -- Atom.to_string/1 |> String.upcase/1 reproduces exactly
  # that mapping without re-deriving it via a second lookup table.
  defp task_status_string(status) when is_atom(status) do
    status |> Atom.to_string() |> String.upcase()
  end

  @doc false
  # Six keys, mirroring Letflow.Engine.complete_result()'s own six fields
  # exactly (design §5.6) -- an allowlist restatement of an already-plain
  # map, not a struct-to-map reduction (complete_result() involves no
  # %Task{} struct at all on this path). instance_status uses the same
  # Atom.to_string/1 |> String.upcase/1 convention task_status_string/1
  # already establishes, producing "ACTIVE"/"COMPLETED".
  @spec complete_result_map(Letflow.Engine.complete_result()) :: map()
  defp complete_result_map(%{
         task_id: task_id,
         instance_id: instance_id,
         instance_status: instance_status,
         current_nodes: current_nodes,
         variables: variables,
         completed_at: completed_at
       }) do
    %{
      "task_id" => task_id,
      "instance_id" => instance_id,
      "instance_status" => instance_status |> Atom.to_string() |> String.upcase(),
      "current_nodes" => current_nodes,
      "variables" => Response.public_variables(variables),
      "completed_at" => DateTime.to_iso8601(completed_at)
    }
  end
end
