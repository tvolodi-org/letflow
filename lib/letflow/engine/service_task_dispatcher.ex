defmodule Letflow.Engine.ServiceTaskDispatcher do
  @moduledoc """
  REQ-214 — SERVICE_TASK dispatch-orchestration core: HTTP transport, the
  SSRF gate, and the poll-claim-decide loop
  against the `service_task_dispatches` table. See
  `lib/letflow/design/service_task_dispatcher.md` for the full design this
  module implements (gate-approved after one rework round). Plain Ecto
  context module, no process — same shape as `Letflow.Scheduler`/
  `Letflow.Dlq`. `Letflow.Engine.ServiceTaskDispatcher.Poller` (a separate
  module) calls into this one; this module itself starts no processes and
  owns no state.

  ## Scope boundary (design §1) — restated here, not re-decided

  This module does NOT touch `lib/letflow/engine/transition.ex` or
  `lib/letflow/engine.ex`. It never calls `Letflow.Engine.set_instance_error/2`,
  `Letflow.Engine.VariableMerge.merge/3`, or any token-advancement function —
  every `attempt_dispatch/2` call returns a typed `dispatch_outcome()` and
  stops; a FUTURE requirement (REQ-215) is the caller that acts on that
  outcome. `dispatch_node/4`'s own `:SERVICE_TASK` clause, and the
  activation-time caller that renders a URL template and INSERTs the first
  `service_task_dispatches` row, are both REQ-215's job — not built here.

  ## `route_kind: :catalog_service` — snapshot-driven (ISS-0917)

  Catalog resolution happens at activation, in `Letflow.Engine`: the engine
  resolves the instance's PINNED `service_catalog` version
  (`Letflow.ServiceCatalog.resolve_pinned_version/3`), renders its
  `endpoint_url`, and freezes the result into
  `config_snapshot["rendered_url"]` exactly as for an inline URL. This
  module therefore dispatches the frozen `rendered_url` for BOTH route kinds
  and never calls the catalog (INV-STD-8, restated: a `:catalog_service` row
  is dispatched only from a URL frozen at activation from the instance's
  pinned catalog version). A `:catalog_service` row whose `rendered_url` is
  nil, empty or not a binary can never build a request: it is classified
  `:request_build_error` (deterministic, non-retriable) with zero
  `http_transport/3`/`:httpc.request/4` calls.

  ## SSRF gate placement (INV-9, BLOCKER — design §5.2)

  `http_transport/3` is this module's single `transport_fun()`
  implementation and the ONLY call site in this module (and in
  `Poller`) that reaches `:httpc.request/4`. `Letflow.Webhooks.UrlValidator.validate/2`
  is called immediately before every such call, for BOTH
  `route_kind: :inline_url` and `route_kind: :catalog_service` —
  unconditionally, with no bypass path in production. A blocked URL never
  reaches `:httpc.request/4`; it is classified
  `{:request_build_error, :target_url_not_allowed}` instead (design §5.2,
  §6).

  ## Test-only SSRF-validation bypass seam (TEST-DESIGNER finding, queue
  task 415)

  `http_transport/3` reads `Application.get_env(:letflow,
  :service_task_ssrf_validation_enabled, true)` and, only when explicitly
  set to `false`, delegates to a `dns_resolver()`-injectable `/4` variant
  instead of the real `UrlValidator.validate/1`/`default_resolver/1` path —
  mirroring `Letflow.Webhooks.dispatch_http/3,4`'s own identical mechanism
  (`lib/letflow/webhooks.ex:373-392`) exactly, including the flag name
  pattern (`:webhook_ssrf_validation_enabled` there, `:service_task_ssrf_validation_enabled`
  here). Defaults to `true` (validation ON) in every environment; only
  `test/letflow/engine/service_task_dispatcher_test.exs` ever sets it to
  `false`, scoped to individual tests via `Application.put_env/3` +
  `on_exit/1`, the same way `test/letflow/webhooks_delivery_test.exs` does.
  This is the ONLY way any test in this codebase can reach a genuine 2xx
  `:advance` outcome or a genuine retriable failure kind through this
  module — without it, `UrlValidator`'s unconditional 127.0.0.0/8 block
  makes `test/support/webhook_test_server.ex` (which only ever binds
  `127.0.0.1`) permanently unreachable through the real gate.

  ## URL freeze-at-INSERT / never-re-render / always-re-validate (OQ-3,
  RESOLVED — design §10)

  `config_snapshot["rendered_url"]` is frozen once, at INSERT time, by
  REQ-215's future activation-time caller. This module never renders a URL
  template and never writes `config_snapshot` — it only ever reads
  `row.config_snapshot["rendered_url"]` back, unchanged, on every attempt of
  a given row, first attempt and every `:retry`-driven re-claim alike.
  What changes attempt-to-attempt is only that `http_transport/3`'s own
  `UrlValidator.validate/2` call re-runs against that SAME frozen string
  every time — mirroring `Letflow.Webhooks.dispatch_http/3,4`'s own
  re-validate-every-attempt, never-re-render behavior
  (`lib/letflow/webhooks.ex:373-392`).
  """

  import Ecto.Query

  require Logger

  alias Letflow.Audit
  alias Letflow.Engine.ServiceTask
  alias Letflow.EventStore
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Repo
  alias Letflow.Webhooks.UrlValidator

  @default_poll_interval_ms 5_000
  @default_jitter_ms 0
  @default_max_dispatches_per_cycle 64
  @default_backoff_base_ms 1_000
  @default_backoff_cap_ms 60_000

  @http_content_type ~c"application/json"

  defmodule ServiceTaskDispatch do
    @moduledoc """
    Ecto schema for the `service_task_dispatches` table. See
    `lib/letflow/design/service_task_dispatcher.md` §4. Ordinary
    `Ecto.Schema`, no process, no `gen_statem` — matches
    `Letflow.Scheduler.Timer`'s own plain-CRUD-table precedent. Nested here
    (rather than its own file, unlike `Timer`) per design §2/§10 OQ-1 — a
    deliberate, flagged, non-blocking deviation from the `timers` precedent,
    chosen because this schema has only 3 small changesets, not `Timer`'s 5.

    ## No `@schema_prefix`

    Like every other tenant-scoped table in this codebase, `service_task_dispatches`
    lives in many Postgres schemas — one per tenant — so every read and
    write must pass `prefix: schema_name` explicitly at call time.

    ## `status` — plain `:string`, not `Ecto.Enum` (design §3.1)

    DB-level CHECK constraint (`chk_service_task_dispatches_status`, the
    migration) restricts it to exactly `"pending"`/`"advanced"`/`"given_up"`
    — the DB constraint is the acceptance-criterion-mandated backstop, so
    this schema stays plain `:string` (mirrors `Timer.status`'s own
    rationale).

    ## No `timestamps/1`

    `next_attempt_at`/`dispatched_at`/`created_at` are specific, narrow
    timestamp columns this table's own contract names — not a generic
    last-modified column nothing in the acceptance criteria requires.

    ## Changesets — one per distinct write path (design §4.2)

    `arm_changeset/2` — defined here (this module owns the schema) but
    called only by REQ-215's future activation-time caller, exactly the
    same division-of-labor `Timer.rearm_changeset/2`'s own moduledoc note
    describes. `retry_changeset/2` and `terminal_changeset/2` back
    `attempt_dispatch/2`'s own same-transaction updates.
    """

    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:id, :binary_id, autogenerate: false}
    schema "service_task_dispatches" do
      field(:tenant_id, Ecto.UUID)
      field(:instance_id, Ecto.UUID)
      field(:token_id, Ecto.UUID)

      field(:node_id, :string)
      field(:config_snapshot, :map)

      field(:attempt_index, :integer, default: 0)
      field(:next_attempt_at, :utc_datetime_usec)

      field(:status, :string, default: "pending")
      field(:last_failure_kind, :string)
      field(:dispatched_at, :utc_datetime_usec)

      field(:created_at, :utc_datetime_usec)
    end

    @type config_snapshot :: %{
            required(String.t()) => String.t() | non_neg_integer() | map() | nil
          }

    @type t :: %__MODULE__{
            id: Ecto.UUID.t(),
            tenant_id: Ecto.UUID.t(),
            instance_id: Ecto.UUID.t(),
            token_id: Ecto.UUID.t(),
            node_id: String.t(),
            config_snapshot: config_snapshot(),
            attempt_index: non_neg_integer(),
            next_attempt_at: DateTime.t(),
            status: String.t(),
            last_failure_kind: String.t() | nil,
            dispatched_at: DateTime.t() | nil,
            created_at: DateTime.t()
          }

    @statuses ~w(pending advanced given_up)

    @doc """
    Structural changeset for the (REQ-215-owned) INSERT path — defined here,
    called only by REQ-215's future activation-time caller (design §4.2).
    `attempt_index` and `status` are not castable through this changeset —
    always forced to `0` and `"pending"` respectively by the caller,
    matching `Timer.arm_changeset/2`'s "status is not castable" discipline.
    """
    @spec arm_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
    def arm_changeset(dispatch, attrs) do
      dispatch
      |> cast(attrs, [
        :id,
        :tenant_id,
        :instance_id,
        :token_id,
        :node_id,
        :config_snapshot,
        :next_attempt_at,
        :created_at
      ])
      |> validate_required([
        :id,
        :tenant_id,
        :instance_id,
        :token_id,
        :node_id,
        :config_snapshot,
        :next_attempt_at,
        :created_at
      ])
    end

    @doc """
    Structural changeset for the `:retry` decision's same-transaction update
    (design §5.6). `status` stays `"pending"` — not cast, never changes on a
    retry.
    """
    @spec retry_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
    def retry_changeset(dispatch, attrs) do
      dispatch
      |> cast(attrs, [:attempt_index, :next_attempt_at, :last_failure_kind])
      |> validate_required([:attempt_index, :next_attempt_at])
    end

    @doc """
    Structural changeset for the `:advance`/`:give_up` terminal update
    (design §5.6). `status` must be cast to exactly `"advanced"` or
    `"given_up"` by the caller.
    """
    @spec terminal_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
    def terminal_changeset(dispatch, attrs) do
      dispatch
      |> cast(attrs, [:status, :last_failure_kind, :dispatched_at])
      |> validate_required([:status, :dispatched_at])
      |> validate_inclusion(:status, @statuses)
    end
  end

  # ===========================================================================
  # Config accessors (design §5.1)
  # ===========================================================================

  @spec poll_interval_ms() :: pos_integer()
  def poll_interval_ms do
    dispatcher_config()[:poll_interval_ms] || @default_poll_interval_ms
  end

  @spec jitter_ms() :: non_neg_integer()
  def jitter_ms do
    dispatcher_config()[:jitter_ms] || @default_jitter_ms
  end

  @spec max_dispatches_per_cycle() :: pos_integer()
  def max_dispatches_per_cycle do
    dispatcher_config()[:max_dispatches_per_cycle] || @default_max_dispatches_per_cycle
  end

  @spec default_backoff_base_ms() :: pos_integer()
  def default_backoff_base_ms do
    dispatcher_config()[:default_backoff_base_ms] || @default_backoff_base_ms
  end

  @spec default_backoff_cap_ms() :: pos_integer()
  def default_backoff_cap_ms do
    dispatcher_config()[:default_backoff_cap_ms] || @default_backoff_cap_ms
  end

  defp dispatcher_config, do: Application.get_env(:letflow, :service_task_dispatcher, [])

  # ===========================================================================
  # http_transport/3 -- design §5.2. The single :httpc.request/4 call site.
  # ===========================================================================

  @doc """
  The concrete `Letflow.Engine.ServiceTask.transport_fun()` value this
  module supplies. `rendered_url` is the value frozen once at the claimed
  row's own INSERT time (`row.config_snapshot["rendered_url"]`) — this
  function never renders anything, it only ever receives an
  already-rendered string, on every attempt including every retry.

  SSRF gate (INV-9, BLOCKER): `UrlValidator.validate/2` is called
  IMMEDIATELY before the `do_http_transport/3` step that issues
  `:httpc.request/4` — no intervening code path reaches `:httpc.request/4`
  without passing this check first (the gate lives here, inside the
  transport itself, not duplicated per-`route_kind` — so it is
  structurally unbypassable by construction).

  `:service_task_ssrf_validation_enabled` defaults to `true`; set to
  `false` in tests only so a real local `:gen_tcp` test server's
  `http://127.0.0.1:PORT` URL passes — mirrors
  `Letflow.Webhooks.dispatch_http/3`'s own identical
  `:webhook_ssrf_validation_enabled` mechanism exactly
  (`lib/letflow/webhooks.ex:373-381`).
  """
  @spec http_transport(
          ServiceTask.Config.t(),
          rendered_url :: String.t(),
          rendered_body :: String.t() | nil
        ) ::
          ServiceTask.raw_outcome()
  def http_transport(%ServiceTask.Config{} = config, rendered_url, rendered_body)
      when is_binary(rendered_url) do
    if Application.get_env(:letflow, :service_task_ssrf_validation_enabled, true) do
      http_transport(config, rendered_url, rendered_body, &UrlValidator.default_resolver/1)
    else
      do_http_transport(config, rendered_url, rendered_body)
    end
  end

  @doc """
  Test-injectable variant taking an explicit `dns_resolver()`, mirroring
  `Letflow.Webhooks.dispatch_http/4`'s own identical shape
  (`lib/letflow/webhooks.ex:384-392`). Not part of `transport_fun()`'s
  3-arity contract — used directly only by
  `test/letflow/engine/service_task_dispatcher_test.exs` for DNS-rebinding-
  style coverage; ordinary dispatch always goes through the 3-arity clause
  above.
  """
  @spec http_transport(
          ServiceTask.Config.t(),
          rendered_url :: String.t(),
          rendered_body :: String.t() | nil,
          dns_resolver :: UrlValidator.dns_resolver()
        ) ::
          ServiceTask.raw_outcome()
  def http_transport(%ServiceTask.Config{} = config, rendered_url, rendered_body, dns_resolver)
      when is_binary(rendered_url) do
    case UrlValidator.validate(rendered_url, dns_resolver) do
      {:error, :target_url_not_allowed} ->
        {:request_build_error, :target_url_not_allowed}

      :ok ->
        do_http_transport(config, rendered_url, rendered_body)
    end
  end

  @spec do_http_transport(
          ServiceTask.Config.t(),
          rendered_url :: String.t(),
          rendered_body :: String.t() | nil
        ) ::
          ServiceTask.raw_outcome()
  defp do_http_transport(%ServiceTask.Config{} = config, rendered_url, rendered_body) do
    request =
      {String.to_charlist(rendered_url), headers_from(config), @http_content_type,
       body_or_empty(rendered_body)}

    method_atom(config.method)
    |> :httpc.request(request, [{:timeout, config.timeout_ms}], [])
    |> case do
      {:ok, {{_http_version, status, _reason_phrase}, _resp_headers, resp_body}} ->
        {:http, status, to_string_or_nil(resp_body)}

      {:error, :timeout} ->
        :timeout

      {:error, reason} ->
        {:network, reason}
    end
  end

  @spec method_atom(ServiceTask.Config.http_method()) :: :get | :post | :put | :patch | :delete
  defp method_atom(:GET), do: :get
  defp method_atom(:POST), do: :post
  defp method_atom(:PUT), do: :put
  defp method_atom(:PATCH), do: :patch
  defp method_atom(:DELETE), do: :delete

  # Always injects content-type from config.body_template's presence,
  # mirroring Webhooks.do_dispatch_http/3's own hardcoded
  # `content-type: application/json` header (design §5.2, §10 OQ-2).
  defp headers_from(%ServiceTask.Config{headers: headers, body_template: body_template}) do
    base =
      Enum.map(headers, fn {key, value} ->
        {String.to_charlist(key), String.to_charlist(value)}
      end)

    if body_template do
      [{~c"content-type", @http_content_type} | base]
    else
      base
    end
  end

  defp body_or_empty(nil), do: ~c""
  defp body_or_empty(body) when is_binary(body), do: body

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(body), do: to_string(body)

  # ===========================================================================
  # claim_due_dispatch_ids/2 -- design §5.4, the hot claim query
  # ===========================================================================

  @doc """
  Two-step select-then-lock (design §5.4, reworked per
  CODE-DESIGN-VALIDATOR's BLOCKER finding). Step 1 selects eligible ids via
  an UNLOCKED joined query (`instance_projections.status == :active`
  filter) — no `lock/1` call anywhere in that query. Step 2 locks ONLY
  `service_task_dispatches` rows, by id, in a second, single-table query —
  mirrors `Letflow.Scheduler.claim_due_timer_ids/2`'s own bare
  `lock("FOR UPDATE SKIP LOCKED")` idiom exactly (no join present in the
  locking query at all, so there is no `FOR UPDATE OF <binding>`
  ambiguity to resolve).

  A row whose instance is no longer `:active` is excluded from step 1
  entirely — never selected, never reaches step 2's lock, its own `status`
  column left untouched (INV-STD-4).
  """
  @spec claim_due_dispatch_ids(tenant_schema :: String.t(), limit :: pos_integer()) :: [
          Ecto.UUID.t()
        ]
  def claim_due_dispatch_ids(tenant_schema, limit)
      when is_binary(tenant_schema) and is_integer(limit) and limit > 0 do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    eligible_ids =
      ServiceTaskDispatch
      |> join(:inner, [d], p in InstanceProjection, on: p.instance_id == d.instance_id)
      |> where(
        [d, p],
        d.status == "pending" and d.next_attempt_at <= ^now and p.status == :active
      )
      |> order_by([d], asc: d.next_attempt_at)
      |> limit(^limit)
      |> select([d], d.id)
      |> Repo.all(prefix: tenant_schema)

    ServiceTaskDispatch
    |> where([d], d.id in ^eligible_ids)
    |> select([d], d.id)
    |> lock("FOR UPDATE SKIP LOCKED")
    |> Repo.all(prefix: tenant_schema)
  end

  # ===========================================================================
  # cancel_pending_dispatches/4 -- REQ-215 design doc §4, cancellation wiring
  # ===========================================================================

  @doc """
  `Letflow.Engine.cancel_instance/3`'s own `:service_task_dispatch_cancellations`
  Multi step (design doc §4) — marks every still-`"pending"`
  `service_task_dispatches` row for `instance_id` as `"given_up"`, in the
  SAME transaction as the instance's own status flip. Mirrors
  `Letflow.Engine.TaskActivation.cancel_pending_timers/5`'s own
  `update_all`-on-a-`"pending"`-status-filter shape exactly, placed here
  (the table-owning-adjacent module) rather than on
  `Letflow.Engine.TaskActivation` itself, for the same "table-owning-adjacent
  module, not the schema's own defining module" reason that precedent
  follows.

  `status: "given_up"`, not `"cancelled"` — deliberate, not a typo.
  `service_task_dispatches.status`'s own CHECK constraint
  (`chk_service_task_dispatches_status`) admits only
  `"pending"`/`"advanced"`/`"given_up"`; no `"cancelled"` value exists in
  this table's own domain (the migration's own comment says so explicitly).
  `last_failure_kind: "instance_cancelled"` is the distinguishing marker
  instead, mirroring `cancel_task_rows/3`'s/`cancel_token_rows/3`'s own
  established `cancelled_at`-reuse idiom, adapted to this table's own
  narrower status domain.

  `claim_due_dispatch_ids/2`'s own `WHERE d.status == "pending"` filter
  already excludes any row this function flips to `"given_up"` — REQ-214's
  dispatcher never dispatches a cancelled row, with zero change to that
  query needed (AC5).
  """
  @spec cancel_pending_dispatches(
          repo :: Ecto.Repo.t(),
          instance_id :: Ecto.UUID.t(),
          cancelled_at :: DateTime.t(),
          prefix :: String.t()
        ) :: {:ok, non_neg_integer()}
  def cancel_pending_dispatches(repo, instance_id, cancelled_at, prefix) do
    {count, _updated} =
      ServiceTaskDispatch
      |> where([d], d.instance_id == ^instance_id and d.status == "pending")
      |> repo.update_all(
        [
          set: [
            status: "given_up",
            dispatched_at: cancelled_at,
            last_failure_kind: "instance_cancelled"
          ]
        ],
        prefix: prefix
      )

    {:ok, count}
  end

  # ===========================================================================
  # poll_and_dispatch/1 -- design §5.5, the tick entry point
  # ===========================================================================

  @type dispatch_poll_result :: %{
          tenant_schema: String.t(),
          claimed: non_neg_integer(),
          advanced: non_neg_integer(),
          retried: non_neg_integer(),
          given_up: non_neg_integer()
        }

  @doc """
  Called once per tenant schema per tick by `ServiceTaskDispatcher.Poller`,
  never by application code directly. Never raises — every per-row failure
  is caught internally (`attempt_dispatch/2`'s own `Repo.transaction/1`
  boundary) and folded into the returned counts (design §5.5, INV-STD-5).

  REQ-215 design doc §3.1 -- this reduce loop is the one, sole call site for
  `Letflow.Engine.advance_after_service_task_outcome/4`: strictly AFTER
  `attempt_dispatch/2`'s own transaction for a given `dispatch_id` has
  already committed and returned its typed `dispatch_outcome()`, never from
  inside `handle_success/3`/`handle_give_up/4`'s own bodies (this module's
  own "Scope boundary" moduledoc section — this module never calls
  `Letflow.Engine.*` from inside its own transaction; `poll_and_dispatch/1`
  is this module's own tick-entry orchestration function, not
  `attempt_dispatch/2` itself, so calling out to the engine here, with an
  already-closed transaction and an already-fully-resolved outcome in hand,
  does not violate that boundary). `{:ok, :retry_scheduled}` and
  `{:ok, :already_final}` outcomes need no further action and are NOT
  passed to `advance_after_service_task_outcome/4` at all, matching
  `fold_attempt_result/2`'s own pre-existing handling for both.
  """
  @spec poll_and_dispatch(tenant_schema :: String.t()) :: dispatch_poll_result()
  def poll_and_dispatch(tenant_schema) when is_binary(tenant_schema) do
    dispatch_ids = claim_due_dispatch_ids(tenant_schema, max_dispatches_per_cycle())

    Enum.reduce(
      dispatch_ids,
      %{
        tenant_schema: tenant_schema,
        claimed: length(dispatch_ids),
        advanced: 0,
        retried: 0,
        given_up: 0
      },
      fn dispatch_id, acc ->
        dispatch_id
        |> attempt_dispatch(tenant_schema)
        |> maybe_advance_after_outcome(dispatch_id, tenant_schema)
        |> fold_attempt_result(acc)
      end
    )
  end

  # REQ-215 design doc §3.1's own call-site list: only {:advance, _} and
  # {:give_up, _} outcomes call into Letflow.Engine.advance_after_service_task_outcome/4.
  # An {:error, _} result from that call folds the same defensive way
  # fold_attempt_result/2's own {:error, _reason} clause already does --
  # counted in neither :advanced nor :given_up. Since ISS-0928 such errors are
  # no longer silent: call_advance_after_service_task_outcome/3 logs and audits
  # them, and a no_matching_edge after the node is routed to an ExecutionError
  # by the engine ({:ok, :error_set}, counted under :given_up).
  defp maybe_advance_after_outcome(
         {:ok, {:advance, _decoded_body}} = outcome,
         dispatch_id,
         tenant_schema
       ) do
    call_advance_after_service_task_outcome(outcome, dispatch_id, tenant_schema)
  end

  defp maybe_advance_after_outcome(
         {:ok, {:give_up, _standalone_error_attrs}} = outcome,
         dispatch_id,
         tenant_schema
       ) do
    call_advance_after_service_task_outcome(outcome, dispatch_id, tenant_schema)
  end

  defp maybe_advance_after_outcome(other, _dispatch_id, _tenant_schema), do: other

  defp call_advance_after_service_task_outcome({:ok, engine_outcome}, dispatch_id, tenant_schema) do
    case Letflow.Engine.advance_after_service_task_outcome(
           dispatch_id,
           engine_outcome,
           Repo,
           tenant_schema
         ) do
      {:ok, :advanced} ->
        {:ok, {:advance, :applied}}

      {:ok, :error_set} ->
        {:ok, {:give_up, :applied}}

      {:ok, :already_final} ->
        {:ok, :already_final}

      # ISS-0784 follow-up fix -- a task-activation rejection
      # (`Letflow.Engine.TaskActivation.resolve_form_schema/1`'s
      # `{:invalid_form_schema, node_id, reason}`) surfaces here as
      # `Letflow.Engine.advance_after_service_task_outcome/4`'s own
      # `{:error, reason}` return, AFTER that function's own
      # `repo.transaction/1` has already fully returned (and, since we're in
      # this branch, already rolled back). This is deliberately NOT handled
      # inside `Letflow.Engine.do_persist_service_task_advance/10`'s own
      # inline clause any more -- that clause runs nested inside this same
      # still-open outer transaction, so recording the audit there would
      # have been rolled back right along with the rest of the failed
      # attempt (same defect class TEST-DESIGNER proved for site 3 against
      # real Postgres). Recording it here, once
      # `advance_after_service_task_outcome/4` has genuinely returned, is a
      # real, independent write.
      {:error, {:invalid_form_schema, node_id, form_schema_reason}} = error ->
        maybe_audit_task_activation_rejection(
          dispatch_id,
          node_id,
          form_schema_reason,
          tenant_schema
        )

        error

      # ISS-0928 -- an already-terminal/errored/cancelled instance is a benign
      # race: debug only, no audit.
      {:error, {:instance_not_active, _status}} = error ->
        Logger.debug(
          "service_task advance skipped, instance not active: dispatch_id=#{dispatch_id} " <>
            "tenant_schema=#{tenant_schema}"
        )

        error

      # ISS-0928 -- previously a silent swallow (the dispatch row is already
      # committed "advanced", so the poller never re-claims it). Now loud:
      # log + best-effort audit. Log content is ONLY dispatch id, tenant schema
      # and a classified atom tag -- never `inspect(reason)` (it can carry
      # instance variables and the HTTP response body). The dispatch row is
      # deliberately NOT reverted to retry (at-most-once HTTP dispatch).
      # Note: `{:ok, :error_set}` above counts under :given_up in the poll
      # summary (accepted; no summary-type change).
      {:error, reason} = error ->
        tag = classify_advance_failure(reason)

        Logger.error(
          "service_task advance failed: dispatch_id=#{dispatch_id} " <>
            "tenant_schema=#{tenant_schema} reason=#{tag}"
        )

        maybe_audit_service_task_advance_failure(dispatch_id, tag, tenant_schema)

        error
    end
  end

  # ISS-0928 -- classifier by tuple head; `:other` is the fallback so an
  # unrecognized shape still produces a log + audit row rather than a crash.
  defp classify_advance_failure({:transition_failed, _}), do: :transition_failed
  defp classify_advance_failure({:variable_merge_rejected, _}), do: :variable_merge_rejected
  defp classify_advance_failure({:unknown_token_id, _}), do: :unknown_token_id
  defp classify_advance_failure({:event_append_failed, _}), do: :event_append_failed

  defp classify_advance_failure({:execution_error_not_supported_for_service_task_advance, _}),
    do: :execution_error_not_supported

  # GH #2587 PR C2: entity-write classes. The engine lands these as ERROR itself, so they are
  # unreachable in practice; kept for the function-level rescue residue and the landing that
  # could not commit (D-C.8 d).
  defp classify_advance_failure({:entity_write_landing_failed, _}),
    do: :entity_write_landing_failed

  defp classify_advance_failure({:entity_write_refused, _, _}), do: :entity_write_refused
  defp classify_advance_failure({:entity_write_failed, _, _}), do: :entity_write_failed

  defp classify_advance_failure(:entity_write_needs_reactivation),
    do: :entity_write_needs_reactivation

  defp classify_advance_failure(_other), do: :other

  # Re-fetches the dispatch row (no lock) to recover instance_id/node_id,
  # exactly like `maybe_audit_task_activation_rejection/4`; nil row is a no-op.
  defp maybe_audit_service_task_advance_failure(dispatch_id, tag, tenant_schema) do
    case Repo.get(ServiceTaskDispatch, dispatch_id, prefix: tenant_schema) do
      nil ->
        :ok

      %ServiceTaskDispatch{instance_id: instance_id, node_id: node_id} ->
        Letflow.Engine.record_service_task_advance_failure_audit(
          instance_id,
          node_id,
          tag,
          EventStore.platform_actor_id(),
          tenant_schema
        )
    end
  end

  # ISS-0784 follow-up fix -- re-fetches the dispatch row (no lock; the
  # locked read inside `advance_after_service_task_outcome/4`'s own
  # transaction is long gone by the time this runs, that transaction having
  # already returned) purely to recover `instance_id`, the one piece of
  # context the `{:error, reason}` return does not carry. Best-effort like
  # the helper it calls: a `nil` row is a no-op, not a crash.
  defp maybe_audit_task_activation_rejection(
         dispatch_id,
         node_id,
         form_schema_reason,
         tenant_schema
       ) do
    case Repo.get(ServiceTaskDispatch, dispatch_id, prefix: tenant_schema) do
      nil ->
        :ok

      %ServiceTaskDispatch{instance_id: instance_id} ->
        Letflow.Engine.record_task_activation_rejection_audit(
          instance_id,
          node_id,
          form_schema_reason,
          EventStore.platform_actor_id(),
          tenant_schema
        )
    end
  end

  defp fold_attempt_result({:ok, {:advance, _}}, acc), do: %{acc | advanced: acc.advanced + 1}

  defp fold_attempt_result({:ok, :retry_scheduled}, acc), do: %{acc | retried: acc.retried + 1}

  defp fold_attempt_result({:ok, {:give_up, _}}, acc), do: %{acc | given_up: acc.given_up + 1}

  defp fold_attempt_result({:ok, :already_final}, acc), do: acc
  defp fold_attempt_result({:error, _reason}, acc), do: acc

  # ===========================================================================
  # attempt_dispatch/2 -- design §5.6, one row, one transaction
  # ===========================================================================

  @type dispatch_outcome ::
          {:advance, decoded_body :: map()}
          | {:give_up, Letflow.Engine.standalone_error_attrs()}
          | :retry_scheduled

  @doc """
  Mirrors `Letflow.Scheduler.fire_timer/2`'s one-`Repo.transaction/1`-per-
  claimed-row shape exactly (design §5.6). Never calls
  `Letflow.Engine.set_instance_error/2` or `ExecutionError.append_multi/3`
  anywhere in this function or its helpers (INV-STD-2).

  BLOCKER fix (SECURITY-REVIEWER, queue task 415): the `Repo.transaction/1`
  call is wrapped in an outer `try/rescue`, mirroring
  `Letflow.Scheduler.attempt_fire/2`'s own boundary
  (`lib/letflow/scheduler.ex:415-421`) exactly. `Repo.transaction/1` does
  NOT swallow a raise — only `Repo.rollback/1`'s cooperative throw becomes
  `{:error, reason}` — so this outer boundary is what actually makes
  `poll_and_dispatch/1`'s "never raises" contract (design §5.5, INV-STD-5)
  true, for any raise this function's helpers produce, anticipated or not.
  `config_from_snapshot/1`'s own two helpers (`route_kind_atom/1`,
  `method_from_snapshot/1`) are additionally hardened to return a typed
  error instead of raising in the first place (belt and suspenders) — see
  their own docs below.
  """
  @spec attempt_dispatch(dispatch_id :: Ecto.UUID.t(), tenant_schema :: String.t()) ::
          {:ok, dispatch_outcome()} | {:ok, :already_final} | {:error, term()}
  def attempt_dispatch(dispatch_id, tenant_schema) when is_binary(tenant_schema) do
    try do
      Repo.transaction(fn ->
        case fetch_and_lock_dispatch(dispatch_id, tenant_schema) do
          nil ->
            {:ok, {:already_final, nil}}

          %ServiceTaskDispatch{status: status} when status != "pending" ->
            {:ok, {:already_final, nil}}

          %ServiceTaskDispatch{} = row ->
            do_attempt_dispatch(row, tenant_schema)
        end
        |> case do
          {:ok, result} -> result
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      # ISS-0946 -- everything below this line runs strictly after
      # Repo.transaction/1 has returned (committed or rolled back), still
      # inside this existing try, still before rescue (design
      # lib/letflow/design/iss0946-service-task-audit-decision.md §3.3).
      |> case do
        {:ok, {outcome, audit_context}} ->
          if audit_context, do: audit_outbound_request(audit_context, tenant_schema)
          {:ok, outcome}

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      exception -> {:error, {:raised, exception}}
    end
  end

  defp fetch_and_lock_dispatch(dispatch_id, tenant_schema) do
    ServiceTaskDispatch
    |> where([d], d.id == ^dispatch_id)
    |> lock("FOR UPDATE")
    |> Repo.one(prefix: tenant_schema)
  end

  defp do_attempt_dispatch(%ServiceTaskDispatch{} = row, tenant_schema) do
    case config_from_snapshot(row) do
      {:ok, %ServiceTask.Config{route_kind: :inline_url} = config} ->
        rendered_url = row.config_snapshot["rendered_url"]
        rendered_body = row.config_snapshot["rendered_body"]

        raw_outcome = http_transport(config, rendered_url, rendered_body)

        audit_context =
          if genuine_attempt?(raw_outcome) do
            build_outbound_audit_context(
              row,
              :inline_url,
              config.method,
              rendered_url,
              rendered_body
            )
          end

        case ServiceTask.classify_failure_kind(raw_outcome) do
          {:success, decoded_body} ->
            handle_success(row, tenant_schema, decoded_body)
            |> wrap_with_audit_context(audit_context)

          failure_kind ->
            handle_failure(row, tenant_schema, config.retry_limit, failure_kind)
            |> wrap_with_audit_context(audit_context)
        end

      # ISS-0917: a :catalog_service row is snapshot-driven exactly like an
      # inline row -- Letflow.Engine resolved the instance's pinned catalog
      # version at activation and froze the rendered endpoint into
      # config_snapshot["rendered_url"]; this module never consults the
      # catalog. The same http_transport/3 (and its SSRF gate) runs on every
      # attempt. A row without a usable frozen URL can never build a request:
      # it is classified :request_build_error with zero transport calls.
      {:ok, %ServiceTask.Config{route_kind: :catalog_service} = config} ->
        case row.config_snapshot["rendered_url"] do
          rendered_url when is_binary(rendered_url) and rendered_url != "" ->
            rendered_body = row.config_snapshot["rendered_body"]

            raw_outcome = http_transport(config, rendered_url, rendered_body)

            audit_context =
              if genuine_attempt?(raw_outcome) do
                build_outbound_audit_context(
                  row,
                  :catalog_service,
                  config.method,
                  rendered_url,
                  rendered_body
                )
              end

            case ServiceTask.classify_failure_kind(raw_outcome) do
              {:success, decoded_body} ->
                handle_success(row, tenant_schema, decoded_body)
                |> wrap_with_audit_context(audit_context)

              failure_kind ->
                handle_failure(row, tenant_schema, config.retry_limit, failure_kind)
                |> wrap_with_audit_context(audit_context)
            end

          _missing_or_unusable ->
            # no http_transport call ever happens on this branch -- audit_context
            # is unconditionally nil, same as the original design's intent.
            handle_failure(row, tenant_schema, config.retry_limit, :request_build_error)
            |> wrap_with_audit_context(nil)
        end

      {:error, _malformed_reason} ->
        # BLOCKER fix (SECURITY-REVIEWER, queue task 415) -- a malformed
        # config_snapshot (bad route_kind or bad method string) can never
        # build a request in the first place, so it is classified exactly
        # like ServiceTask.classify_failure_kind/1's own
        # {:request_build_error, _} raw_outcome clause would classify it
        # (design §5.2/§5.6's existing :request_build_error failure_kind) --
        # no new failure_kind is introduced, and http_transport/3 is never
        # called for this row. retry_limit is read directly from the
        # snapshot (never from the Config.t() this branch failed to build)
        # since it does not depend on route_kind/method at all. No
        # http_transport call on this branch either -- nil, same reasoning.
        handle_failure(
          row,
          tenant_schema,
          row.config_snapshot["retry_limit"],
          :request_build_error
        )
        |> wrap_with_audit_context(nil)
    end
  end

  # ===========================================================================
  # ISS-0946 -- SERVICE_TASK outbound-request audit. See
  # lib/letflow/design/iss0946-service-task-audit-decision.md for the full
  # design (§3.1-§3.4). Writes one best-effort Letflow.Audit entry per genuine
  # outbound attempt (never for a :request_build_error, which never reaches
  # http_transport/3), strictly AFTER attempt_dispatch/2's own
  # Repo.transaction/1 has returned -- never nested inside it (design §3.3's
  # SAVEPOINT-hazard finding).
  # ===========================================================================

  @type outbound_audit_context :: %{
          dispatch_id: Ecto.UUID.t(),
          instance_id: Ecto.UUID.t(),
          node_id: String.t(),
          attempt_index: non_neg_integer(),
          route_kind: :inline_url | :catalog_service,
          method: ServiceTask.Config.http_method(),
          rendered_url: String.t(),
          rendered_body: String.t() | nil
        }

  # design §3.1 -- the genuine_attempt?/1 guard: a :request_build_error never
  # reached http_transport/3 at all, so it is never auditable as an outbound
  # request. Every other raw_outcome() shape (:timeout, {:network, _},
  # {:http, _, _}) represents a real attempt that reached the transport.
  @spec genuine_attempt?(ServiceTask.raw_outcome()) :: boolean()
  defp genuine_attempt?({:request_build_error, _reason}), do: false
  defp genuine_attempt?(_other), do: true

  # design §3.3 -- Option (b)'s one new private helper. Wraps
  # do_attempt_dispatch/2's four call-site results (handle_success/3 or
  # handle_failure/4, never handle_retry/3 or handle_give_up/4 directly --
  # those stay reached only through handle_failure/4's own unchanged internal
  # routing) into the uniform {outcome, audit_context} shape attempt_dispatch/2
  # unwraps after its own Repo.transaction/1 returns. handle_success/3,
  # handle_failure/4, handle_retry/3, and handle_give_up/4 are NOT changed by
  # this helper -- it wraps their already-produced result, it does not alter
  # how they are called or what they compute.
  @spec wrap_with_audit_context(
          {:ok, outcome} | {:error, reason},
          audit_context :: outbound_audit_context() | nil
        ) :: {:ok, {outcome, outbound_audit_context() | nil}} | {:error, reason}
        when outcome: var, reason: var
  defp wrap_with_audit_context({:ok, outcome}, audit_context), do: {:ok, {outcome, audit_context}}
  defp wrap_with_audit_context({:error, _} = err, _audit_context), do: err

  # design §3.3 -- built immediately after raw_outcome is computed, inside
  # do_attempt_dispatch/2's existing transaction -- every field is already
  # available at that call site. Returns the context map to thread out of the
  # transaction; callers only invoke this when genuine_attempt?(raw_outcome)
  # is true.
  @spec build_outbound_audit_context(
          row :: ServiceTaskDispatch.t(),
          route_kind :: :inline_url | :catalog_service,
          method :: ServiceTask.Config.http_method(),
          rendered_url :: String.t(),
          rendered_body :: String.t() | nil
        ) :: outbound_audit_context()
  defp build_outbound_audit_context(
         %ServiceTaskDispatch{} = row,
         route_kind,
         method,
         rendered_url,
         rendered_body
       ) do
    %{
      dispatch_id: row.id,
      instance_id: row.instance_id,
      node_id: row.node_id,
      attempt_index: row.attempt_index,
      route_kind: route_kind,
      method: method,
      rendered_url: rendered_url,
      rendered_body: rendered_body
    }
  end

  # design §3.3 -- called from attempt_dispatch/2 strictly AFTER its own
  # Repo.transaction/1 has returned -- opens its own fresh Repo.transaction/1
  # wrapping only Letflow.Audit.insert_entry/3, mirroring
  # record_task_activation_rejection_audit/5's exact shape
  # (engine.ex:4846-4887), plus one added `rescue` to also swallow a raised
  # (not merely {:error, _}-returned) Postgres-level failure. Never raises;
  # never affects the already-committed dispatch row.
  #
  # `@doc false def`, not `defp` -- mirrors the same visibility reasoning
  # `record_task_activation_rejection_audit/5`/`record_service_task_advance_failure_audit/5`
  # (engine.ex) already use: the ONLY reason this is public at all is design
  # §3.6 test case 7a, which calls this directly (unit-level, not through
  # `attempt_dispatch/2`) to exercise the Ecto-changeset-validation-failure
  # branch, a class `attempt_dispatch/2`'s own real call sites never produce
  # (every field they supply is always present and well-typed). No
  # production caller outside this module exists or is intended.
  @doc false
  @spec audit_outbound_request(
          context :: outbound_audit_context(),
          tenant_schema :: String.t()
        ) :: :ok
  def audit_outbound_request(%{} = context, tenant_schema) when is_binary(tenant_schema) do
    attrs = %{
      actor_id: EventStore.platform_actor_id(),
      action: "service_task.outbound_request_sent",
      resource_type: "instance",
      resource_id: context.instance_id,
      before_state: nil,
      after_state: service_task_outbound_audit_state(context),
      trace_id: nil
    }

    case Repo.transaction(fn -> Audit.insert_entry(Repo, attrs, tenant_schema) end) do
      {:ok, {:ok, _entry}} ->
        :ok

      {:ok, {:error, insert_reason}} ->
        Logger.warning(
          "Letflow.Audit.insert_entry/3 failed recording service_task.outbound_request_sent " <>
            "for dispatch #{context.dispatch_id} (instance #{context.instance_id}, " <>
            "tenant_schema #{tenant_schema}): #{inspect(insert_reason)}"
        )

        :ok

      {:error, rollback_reason} ->
        Logger.warning(
          "Repo.transaction/1 failed recording service_task.outbound_request_sent for " <>
            "dispatch #{context.dispatch_id} (instance #{context.instance_id}, " <>
            "tenant_schema #{tenant_schema}): #{inspect(rollback_reason)}"
        )

        :ok
    end
  rescue
    exception ->
      Logger.warning(
        "Repo.transaction/1 raised recording service_task.outbound_request_sent for " <>
          "dispatch #{context.dispatch_id} (instance #{context.instance_id}, " <>
          "tenant_schema #{tenant_schema}): #{inspect(exception)}"
      )

      :ok
  end

  # design §3.1/§3.2 -- after_state shape. Deliberately EXCLUDES headers
  # (config.headers) and decoded_body (the HTTP response, already covered by
  # SERVICE_TASK_COMPLETED) -- see the design's §3.1 "Deliberately excluded"
  # list. Never add either without a fresh SECURITY-REVIEWER pass.
  @spec service_task_outbound_audit_state(context :: outbound_audit_context()) :: %{
          required(String.t()) => String.t() | non_neg_integer() | boolean() | nil
        }
  defp service_task_outbound_audit_state(%{} = context) do
    base = %{
      "dispatch_id" => context.dispatch_id,
      "node_id" => context.node_id,
      "attempt_index" => context.attempt_index,
      "route_kind" => Atom.to_string(context.route_kind),
      "method" => Atom.to_string(context.method),
      "rendered_url" => context.rendered_url
    }

    Map.merge(base, body_preview_fields(context.rendered_body))
  end

  defp body_preview_fields(nil) do
    %{
      "request_body_present" => false,
      "request_body_byte_size" => 0,
      "request_body_truncated" => false,
      "request_body_preview" => nil
    }
  end

  defp body_preview_fields(rendered_body) when is_binary(rendered_body) do
    base = %{
      "request_body_present" => true,
      "request_body_byte_size" => byte_size(rendered_body)
    }

    case redact_and_cap_body_preview(rendered_body) do
      {:ok, preview, truncated?} ->
        Map.merge(base, %{
          "request_body_truncated" => truncated?,
          "request_body_preview" => preview
        })

      :not_json ->
        # SECURITY-REVIEWER fix (PR #2142, OQ-2) -- a body that isn't valid
        # JSON has no key-shaped structure for `redact_secret_shaped_terms/1`
        # to walk, so there is no safe-by-construction way to redact it.
        # Rather than hand a raw, unredacted string through (the prior,
        # vulnerable behavior -- a plaintext credential in a form-encoded
        # body landed verbatim in the audit log) or lean on a regex
        # heuristic that can't enumerate every secret-bearing shape, we
        # record presence/size only and omit body content entirely. This is
        # the more conservative of SECURITY-REVIEWER's two offered fixes,
        # chosen deliberately over the regex-redaction alternative.
        Map.merge(base, %{
          "request_body_truncated" => false,
          "request_body_preview" => nil
        })
    end
  end

  # design §3.2 -- the redaction/capping helper, revised spec (SECURITY-REVIEWER
  # fix, PR #2142):
  #   1. Attempt Jason.decode/1. On success (map, list, or scalar), walk the
  #      FULL decoded structure recursively -- including nested objects and
  #      arrays-of-objects at any depth (design §4 OQ-1, now resolved) -- and
  #      replace the value of any object key whose name matches the
  #      secret-shaped pattern below with the literal string "[REDACTED]".
  #      Re-encode via Jason.encode!/1.
  #   2. On decode failure (not valid JSON), do NOT hand any body content
  #      through (design §4 OQ-2, now resolved the conservative way): the
  #      caller records `request_body_present`/`request_body_byte_size` only
  #      and leaves `request_body_preview` nil. A regex-based key=value
  #      redaction pass was considered and rejected here -- it is a
  #      heuristic that can never enumerate every secret-bearing shape a
  #      non-JSON body might take, which is not an acceptable trade-off for
  #      an audit trail readable via `:AuditRead`.
  #   3. Truncate the (possibly redacted) string to the first 2000 Unicode
  #      codepoints (String.slice/2-safe, never mid-codepoint).
  #      truncated? is true iff the pre-truncation string was longer than
  #      2000 codepoints.
  @secret_key_pattern ~r/secret|token|password|api[_-]?key|authorization|bearer|credential/i
  @body_preview_codepoint_cap 2000

  @spec redact_and_cap_body_preview(rendered_body :: String.t()) ::
          {:ok, preview :: String.t(), truncated? :: boolean()} | :not_json
  defp redact_and_cap_body_preview(rendered_body) when is_binary(rendered_body) do
    case Jason.decode(rendered_body) do
      {:ok, decoded} ->
        {preview, truncated?} =
          decoded
          |> redact_secret_shaped_terms()
          |> Jason.encode!()
          |> cap_to_codepoints(@body_preview_codepoint_cap)

        {:ok, preview, truncated?}

      {:error, _reason} ->
        :not_json
    end
  end

  # Recurses into maps and lists so a secret-shaped key is redacted no
  # matter how deeply it's nested (object, array-of-objects, array of
  # arrays, ...). Scalars pass through unchanged. A matched key's value is
  # replaced outright -- it is never itself recursed into, since
  # "[REDACTED]" already is the final value.
  @spec redact_secret_shaped_terms(term()) :: term()
  defp redact_secret_shaped_terms(%{} = map) do
    map
    |> Enum.map(fn {key, value} ->
      if Regex.match?(@secret_key_pattern, to_string(key)) do
        {key, "[REDACTED]"}
      else
        {key, redact_secret_shaped_terms(value)}
      end
    end)
    |> Map.new()
  end

  defp redact_secret_shaped_terms(list) when is_list(list) do
    Enum.map(list, &redact_secret_shaped_terms/1)
  end

  defp redact_secret_shaped_terms(other), do: other

  defp cap_to_codepoints(string, cap) do
    length = String.length(string)

    if length > cap do
      {String.slice(string, 0, cap), true}
    else
      {string, false}
    end
  end

  # Rebuilds a Config.t() from row.config_snapshot -- a plain map-to-struct
  # projection. Does NOT call parse_config_from_node_attributes/1 again
  # (design §5.6 step 1) -- the snapshot was already parsed once by
  # REQ-215's activation-time caller.
  #
  # BLOCKER fix (SECURITY-REVIEWER, queue task 415): returns {:error, _}
  # instead of raising when the snapshot is malformed -- a single corrupt
  # row (a future bug elsewhere, a manual DB edit, a genuinely-never-
  # interned atom after a BEAM restart) must fold into a per-row outcome,
  # not crash the shared Poller process and take down every other tenant's
  # pending rows in the same poll cycle.
  @spec config_from_snapshot(ServiceTaskDispatch.t()) ::
          {:ok, ServiceTask.Config.t()} | {:error, :invalid_route_kind | :invalid_method}
  defp config_from_snapshot(%ServiceTaskDispatch{config_snapshot: snapshot, node_id: node_id}) do
    with {:ok, route_kind} <- route_kind_atom(snapshot["route_kind"]),
         {:ok, method} <- method_from_snapshot(snapshot["method"]) do
      {:ok,
       %ServiceTask.Config{
         node_id: node_id,
         route_kind: route_kind,
         url_template: snapshot["url_template"],
         service_id: snapshot["service_id"],
         method: method,
         body_template: snapshot["body_template"],
         headers: snapshot["headers"] || %{},
         timeout_ms: snapshot["timeout_ms"],
         retry_limit: snapshot["retry_limit"]
       }}
    end
  end

  @spec route_kind_atom(term()) ::
          {:ok, :inline_url | :catalog_service} | {:error, :invalid_route_kind}
  defp route_kind_atom("inline_url"), do: {:ok, :inline_url}
  defp route_kind_atom("catalog_service"), do: {:ok, :catalog_service}
  defp route_kind_atom(_other), do: {:error, :invalid_route_kind}

  # Bounded, explicit mapping over the known method strings -- never
  # String.to_existing_atom/1 (BLOCKER fix, SECURITY-REVIEWER, queue task
  # 415). Unbounded to_existing_atom on stored/external-adjacent data is a
  # hazard independent of the crash bug: the atom table is finite, and
  # whether a given string was ever interned is not something this module
  # controls or should depend on. Mirrors ServiceTask's own closed
  # @valid_methods ~w(GET POST PUT PATCH DELETE)a set
  # (lib/letflow/engine/service_task.ex:165).
  @spec method_from_snapshot(term()) ::
          {:ok, ServiceTask.Config.http_method()} | {:error, :invalid_method}
  defp method_from_snapshot("GET"), do: {:ok, :GET}
  defp method_from_snapshot("POST"), do: {:ok, :POST}
  defp method_from_snapshot("PUT"), do: {:ok, :PUT}
  defp method_from_snapshot("PATCH"), do: {:ok, :PATCH}
  defp method_from_snapshot("DELETE"), do: {:ok, :DELETE}
  defp method_from_snapshot(_other), do: {:error, :invalid_method}

  defp handle_success(%ServiceTaskDispatch{} = row, tenant_schema, decoded_body) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    row
    |> ServiceTaskDispatch.terminal_changeset(%{status: "advanced", dispatched_at: now})
    |> Repo.update(prefix: tenant_schema)
    |> case do
      {:ok, _updated} -> {:ok, {:advance, decoded_body}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  # Takes retry_limit directly (not a Config.t()) so a malformed-snapshot
  # row -- which never successfully builds a Config.t() -- can still reach
  # this same failure-handling path (BLOCKER fix, SECURITY-REVIEWER, queue
  # task 415). retry_limit does not depend on route_kind/method, so reading
  # it straight from the snapshot is always valid here.
  defp handle_failure(%ServiceTaskDispatch{} = row, tenant_schema, retry_limit, failure_kind) do
    case ServiceTask.decide_failure(failure_kind, row.attempt_index, retry_limit) do
      :retry -> handle_retry(row, tenant_schema, failure_kind)
      :give_up -> handle_give_up(row, tenant_schema, failure_kind, retry_limit)
    end
  end

  defp handle_retry(%ServiceTaskDispatch{} = row, tenant_schema, failure_kind) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    next_delay_ms =
      ServiceTask.compute_service_task_backoff_ms(
        row.attempt_index,
        default_backoff_base_ms(),
        default_backoff_cap_ms()
      )

    retry_attrs = %{
      attempt_index: row.attempt_index + 1,
      next_attempt_at: DateTime.add(now, next_delay_ms, :millisecond),
      last_failure_kind: to_string(failure_kind)
    }

    row
    |> ServiceTaskDispatch.retry_changeset(retry_attrs)
    |> Repo.update(prefix: tenant_schema)
    |> case do
      {:ok, _updated} -> {:ok, :retry_scheduled}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp handle_give_up(%ServiceTaskDispatch{} = row, tenant_schema, failure_kind, retry_limit) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    idempotency_key =
      ServiceTask.build_idempotency_key(
        row.instance_id,
        row.node_id,
        row.token_id,
        row.attempt_index
      )

    # design §10 OQ-4 -- this module holds no InstanceState and calls no
    # Letflow.Engine.Reconstruction/snapshot-reading function; `variables`
    # is populated as %{} and `actor_id` as EventStore.platform_actor_id()
    # (the same "no human/API actor" sentinel Letflow.Scheduler's own
    # TIMER_FIRED event append already uses), both flagged placeholders per
    # the design's own resolution -- not silently invented here.
    give_up_context = %{
      instance_id: row.instance_id,
      node_id: row.node_id,
      actor_id: EventStore.platform_actor_id(),
      idempotency_key: idempotency_key,
      variables: %{},
      last_failure_kind: failure_kind,
      attempt_index: row.attempt_index,
      retry_limit: retry_limit
    }

    standalone_error_attrs = ServiceTask.build_service_task_give_up_error_attrs(give_up_context)

    terminal_attrs = %{
      status: "given_up",
      dispatched_at: now,
      last_failure_kind: to_string(failure_kind)
    }

    row
    |> ServiceTaskDispatch.terminal_changeset(terminal_attrs)
    |> Repo.update(prefix: tenant_schema)
    |> case do
      {:ok, _updated} -> {:ok, {:give_up, standalone_error_attrs}}
      {:error, changeset} -> {:error, changeset}
    end
  end
end
