defmodule Letflow.Plugs.Admission do
  @moduledoc """
  HTTP wiring for `Letflow.Admission` (REQ-216, closes ISS-0431/GH#835's PRIMARY
  surface, REQ-217). One parameterized `@behaviour Plug` module, mounted TWICE in
  `Letflow.Plugs.ApiPipeline`'s chain with different `:pool` mount options — see
  design `lib/letflow/design/req217-http-admission-wiring.md` for the full
  rationale; this moduledoc restates only what a caller or future maintainer needs.

  ## Two gates, one module

    * `pool: :global` — mounted as the very FIRST plug in `ApiPipeline`, before
      `Plug.Parsers`. Calls `Letflow.Admission.try_acquire(:global)`. No
      `conn.assigns` read.
    * `pool: :tenant` — mounted immediately after `Letflow.Plugs.AuthPipeline` and
      before `Letflow.Plugs.TenantStatus`. Reads `conn.assigns.auth_context.tenant_id`
      (guaranteed present at this mount point — `AuthPipeline` always assigns it or
      halts first) and resolves it to a schema name via the SAME
      `Letflow.TenantProvisioning.schema_name_for_tenant/1` call `AuthPipeline` itself
      already makes — never re-derived independently. Calls
      `Letflow.Admission.try_acquire({:tenant, schema_name})`.

  **Disclosed limitation:** `AuthPipeline`'s own DB work (bearer-token verification,
  tenant-by-realm/slug resolution, JIT provisioning) is covered only by the GLOBAL
  gate, never a per-tenant one, because tenant identity does not exist yet at the
  point in the chain where `AuthPipeline` runs. This is an accepted, disclosed
  limitation of this requirement's scope, not an oversight — closing it would require
  tenant identity earlier in the chain than this codebase currently resolves it.

  **`release_global_ref/1` (REQ-217 rework, design doc §10.1):** mounted by
  `Letflow.Plugs.ApiPipeline` as `:release_global_admission`, between
  `AuthPipeline` and the `pool: :tenant` mount above. Releases the global
  gate's already-held ref immediately once `AuthPipeline` completes, so the
  tenant gate's own `try_acquire({:tenant, schema})` call — which also
  consumes a global unit, per `Letflow.Admission`'s composing rule — is the
  ONLY global unit a request holds from that point forward, not a second one
  stacked on an already-held first (the original wiring's double-global-
  consumption defect). **Admission at the global gate is therefore a
  re-checked, not reserved, precondition for admission at the tenant gate:**
  a request admitted at the global gate can still receive
  `{:error, :capacity}` at the tenant gate, after `AuthPipeline`'s own work
  has already run, because the global gate's unit is released immediately
  after `AuthPipeline` completes and the tenant gate performs a fresh,
  independent `try_acquire/2` call rather than reusing or extending the
  first grant. This is intentional and must not be "fixed" by
  re-introducing overlap between the two gates' held refs.

  ## `Retry-After` — 1 second, not `TenantStatus`'s 30

  `Letflow.Admission.try_acquire/2` is a single synchronous `GenServer.call/2`
  against in-memory counters with **no wait queue at all** — a rejected caller's
  slot can free up as soon as any other in-flight request's `release/2` runs, which
  for this codebase's request shapes is expected to be low hundreds of milliseconds
  at worst. `Letflow.Plugs.TenantStatus`'s `@retry_after_seconds "30"` is right for
  ITS OWN, structurally different case — a migration-in-progress wait that can
  genuinely take tens of seconds — and is deliberately NOT copied uncritically here.
  Retrying after 1s is far more likely to succeed than waiting 30s, and costs the
  client nothing extra if it doesn't (it can be rejected again immediately). The
  value is a fixed, configured constant (`:letflow, :admission, :retry_after_seconds`,
  default 1) — never a computed estimate, since this admission mechanism has no
  queueing/backoff-timing model to derive one from.

  ## Ref storage and release — two independent, non-exclusive mechanisms

  On a successful `try_acquire/2`, the resulting `admission_ref()` is stored TWICE:

    1. On `conn.assigns` (under `:global_admission_ref` or `:tenant_admission_ref`,
       depending on which gate produced it).
    2. Prepended onto a list held under `@admission_refs_pdict_key` in the process
       dictionary of the process handling this request.

  **Mechanism A — `Plug.Conn.register_before_send/2`** — covers every
  NON-crashing response path (normal completion, a later plug's own halt+response,
  a route handler's ordinary error response). Releases this gate's own
  `conn.assigns` ref if still present, and ALSO clears the process-dictionary key
  entirely (idempotent hygiene: `Letflow.Admission.release/2` is documented
  idempotent, so it does not matter which of Mechanism A's two registered callbacks
  — one per gate — clears the pdict key first, or whether Mechanism B has already
  drained it via a crash on an earlier attempt on a keep-alive-reused process).

  **Mechanism B — `Plug.ErrorHandler` on `Letflow.Plugs.ApiPipeline` (this
  module's `handle_errors/2` callback)** — covers the raise sites Mechanism A
  cannot reach. `register_before_send/2` callbacks are skipped entirely on any
  `catch`/`rescue` in Bandit's own request pipeline, for ANY raise regardless of
  where it originates. Whether `conn.assigns` would even be a reliable read
  channel if something else tried to clean up depends on WHERE the raise
  happened:

    * A raise inside the MATCHED ROUTE HANDLER (during `:dispatch`, after
      `:match`) is wrapped by `Plug.Router`'s own `dispatch/2` into a
      `Plug.Conn.WrapperError` carrying the fully-downstream conn — `conn.assigns`
      IS reliable there, but `register_before_send/2` still never runs on this
      path (Bandit skips it unconditionally on any raise), so a conn-based read
      inside `handle_errors/2` is still needed.
    * A raise inside a PLUG that runs BEFORE `dispatch/2` — `AuthPipeline`,
      `TenantStatus`, or this module's own believed-unreachable branches below —
      is NOT wrapped in `Plug.Conn.WrapperError` at all (`Plug.Builder`'s
      generated pre-dispatch pipeline body has no per-plug `try/catch` of its
      own) and surfaces via `Plug.ErrorHandler`'s plain `catch` clause with the
      PRE-PIPELINE conn — a conn on which NEITHER admission-ref assign is
      visible, since each `assign/3` call happened on a locally-rebound `conn`
      variable inside `Plug.Builder`'s generated function body, invisible to
      `call/2`'s separately-bound outer parameter.

  This is why the process dictionary (process-local, unaffected by which `conn`
  binding is in scope, or by exception unwinding of the conn's own call stack) is
  the single mechanism `handle_errors/2` reads from — it works uniformly for both
  raise sites above, unlike `conn.assigns` which is only reliable for the first.
  This is this requirement's most safety-critical property: the process-dictionary
  mechanism exists specifically for a raise inside a PRE-dispatch plug, not because
  nothing in this codebase's stack ever wraps a raise in `Plug.Conn.WrapperError`
  (it does, for the route-handler case — see above).

  ## The route class and the refusal line (T-3034)

  Every admission carries the ROUTE CLASS of the request: the route PATTERN
  the router compiled in (`/api/v1/instances/:id`), never the request path,
  never a path parameter and never a query value. It is attached to the
  admission when it is acquired, so the admission counters and the refusal
  line can name WHICH kind of request holds the budget — the answer to "the
  503s hit many paths, so who is holding the slots?".

  The route class is available because `Letflow.Plugs.ApiPipeline` matches the
  route BEFORE this plug runs (its own `plug(:match)` is the first plug of the
  chain since T-3034). At the mount level of that pipeline the pattern is the
  MOUNT class (`/api/v1/instances`), because the sub-router of the request
  matches during the dispatch that follows the gate; `"unmatched"` is the
  answer for a request that matched no route at all.

  A refusal emits ONE structured line through `Letflow.Admission.Observability`
  (rate limited to one per second, node-wide): the budget in use, the cap, the
  refused request's route class, its tenant as a keyed pseudonym (`none` at the
  global gate, where the tenant is not known yet — the tenant is resolved
  after authentication) and the oldest in-flight admission with its route
  class and age. The line carries no token, no header, no body, no request
  path and no raw tenant id.

  ## Tenant-derivation-failure branches — deliberately undefended

  `{:error, :invalid_tenant_id}` from `schema_name_for_tenant/1`, and a missing
  `:auth_context` assign, are both believed unreachable in practice (this plug is
  only ever mounted after `AuthPipeline` in `ApiPipeline`'s fixed chain, and
  `AuthPipeline` itself would already have failed before assigning `:auth_context`
  for any `tenant_id` `schema_name_for_tenant/1` would reject). Both are left to
  crash rather than defended against with a fallback response — matching
  `TenantStatus`'s own fail-closed precedent for a comparably "should not occur"
  case (`tenant_status.ex:70-74`). A violation of the stated invariant is loud (a
  500 + logged crash, cleaned up via Mechanism B above) rather than silently
  admitting or silently rejecting every request.
  """

  @behaviour Plug

  import Plug.Conn

  alias Letflow.Admission
  alias Letflow.Admission.Observability
  alias Letflow.Api.Response
  alias Letflow.TenantProvisioning

  @type mount_opt :: [pool: :global | :tenant]

  @default_retry_after_seconds 1

  @global_rejection_detail "server at capacity, retry shortly"
  @tenant_rejection_detail "tenant at capacity, retry shortly"

  # The admission server this plug talks to: the application-supervised
  # singleton (the same one `Letflow.Admission.usage/1` and the metrics
  # exposition read). Named here so the call site below reads as "the default
  # server" instead of repeating the alias.
  @server Letflow.Admission

  # See moduledoc's "Ref storage and release" section, and design doc §5/§9 --
  # follows the SAME {ModuleName, :purpose_atom} convention
  # lib/letflow/engine/wasm/host_api.ex's @staged_writes_pdict_key/
  # @fail_signal_pdict_key and lib/letflow/engine/lua/platform.ex's own
  # @staged_writes_pdict_key already establish in this codebase.
  @admission_refs_pdict_key {__MODULE__, :admission_refs}

  @impl Plug
  @spec init(mount_opt()) :: mount_opt()
  def init(opts) do
    case Keyword.fetch(opts, :pool) do
      {:ok, pool} when pool in [:global, :tenant] ->
        opts

      _other ->
        raise ArgumentError,
              "Letflow.Plugs.Admission requires opts[:pool] to be :global or :tenant, " <>
                "got: #{inspect(opts)}"
    end
  end

  @impl Plug
  @spec call(Plug.Conn.t(), mount_opt()) :: Plug.Conn.t()
  def call(conn, opts) do
    pool = Keyword.fetch!(opts, :pool)
    {pool_selector, assign_key, rejection_detail, tenant_schema} = resolve(pool, conn)

    # T-3034: the ROUTE CLASS of the request (the route pattern the router
    # compiled in -- never the request path) is attached to the admission, so
    # the counters and the refusal line can name WHICH kind of request holds
    # the budget. "unmatched" when the chain has not matched a route yet.
    route = Observability.route_class(conn)

    case Admission.try_acquire(pool_selector, @server, class: route) do
      {:ok, ref} -> admit(conn, ref, assign_key)
      {:error, :capacity} -> reject(conn, rejection_detail, pool, route, tenant_schema)
    end
  end

  # See §2 of the design doc: pool-selector derivation per mount.
  defp resolve(:global, _conn) do
    {:global, :global_admission_ref, @global_rejection_detail, nil}
  end

  defp resolve(:tenant, conn) do
    # Guaranteed present (dot access intentionally left to crash otherwise --
    # see moduledoc's "Tenant-derivation-failure branches" section).
    tenant_id = conn.assigns.auth_context.tenant_id
    {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(tenant_id)
    {{:tenant, schema_name}, :tenant_admission_ref, @tenant_rejection_detail, schema_name}
  end

  # §5: success path -- dual storage (conn.assigns + process dictionary), then
  # Mechanism A's register_before_send/2 cleanup callback.
  defp admit(conn, ref, assign_key) do
    Process.put(@admission_refs_pdict_key, [ref | Process.get(@admission_refs_pdict_key, [])])

    conn
    |> assign(assign_key, ref)
    |> register_before_send(fn conn ->
      release_ref(conn.assigns[assign_key])
      Process.delete(@admission_refs_pdict_key)
      conn
    end)
  end

  defp release_ref(nil), do: :ok
  defp release_ref(ref), do: Admission.release(ref)

  # REQ-217 rework (design doc §10.1) -- releases the GLOBAL gate's already-held
  # ref immediately after Letflow.Plugs.AuthPipeline completes, so the tenant
  # gate's own subsequent try_acquire({:tenant, schema}) call (which, per
  # Letflow.Admission's composing rule, ALSO consumes a global unit) is the
  # ONLY global unit this request holds from that point forward, not a second
  # one stacked on top of an already-held first. Mounted by
  # Letflow.Plugs.ApiPipeline as a thin :release_global_admission wrapper,
  # positioned between AuthPipeline and the `pool: :tenant` mount -- see that
  # module and the design doc §10.1 item 3 for the exact chain position.
  #
  # Defensive nil-check (should not occur on this path: the global gate is
  # mounted first and always assigns this key or halts before this plug is
  # ever reached) rather than assuming the invariant -- matches this module's
  # existing "idempotent, never raise on a no-op release" posture.
  @spec release_global_ref(Plug.Conn.t()) :: Plug.Conn.t()
  def release_global_ref(conn) do
    case conn.assigns[:global_admission_ref] do
      nil ->
        conn

      ref ->
        Admission.release(ref)

        updated_refs =
          @admission_refs_pdict_key
          |> Process.get([])
          |> List.delete(ref)

        Process.put(@admission_refs_pdict_key, updated_refs)

        assign(conn, :global_admission_ref, nil)
    end
  end

  # §3: {:error, :capacity} -- halt and respond.
  #
  # T-3034: one structured line per refusal (rate limited to one per second,
  # node-wide) naming the budget, the refused request's route class and the
  # oldest in-flight admission. The line carries no token, no body, no path and
  # no raw tenant id; the tenant is a keyed pseudonym. A failure of the line
  # never changes the answer: the 503 is still the 503.
  defp reject(conn, detail, kind, route, tenant_schema) do
    Observability.log_rejection(%{kind: kind, tenant: tenant_schema, route: route})

    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after_seconds()))
    |> Response.service_unavailable(detail)
    |> halt()
  end

  # §4: read fresh on every rejection, never cached -- so a test overriding this
  # key via Application.put_env/3 observes the new value with no other code change.
  @spec retry_after_seconds() :: pos_integer()
  defp retry_after_seconds do
    Application.get_env(:letflow, :admission, [])[:retry_after_seconds] ||
      @default_retry_after_seconds
  end

  @doc false
  # Exposed so Letflow.Plugs.ApiPipeline's handle_errors/2 (Mechanism B) can drain
  # and release whatever this process accumulated before the raise that triggered
  # it, without ApiPipeline reaching into this module's private pdict key directly.
  @spec release_pending_refs() :: :ok
  def release_pending_refs do
    @admission_refs_pdict_key
    |> Process.get([])
    |> Enum.each(&Admission.release/1)

    Process.delete(@admission_refs_pdict_key)
    :ok
  end
end
