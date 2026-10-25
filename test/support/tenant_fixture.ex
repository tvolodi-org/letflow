defmodule Letflow.TenantFixture do
  @moduledoc """
  Shared, instrumented tenant-provisioning fixture for tests that need a real
  Postgres tenant schema (ISS-0109 / GH#358).

  Implements
  `lib/letflow/design/iss0109-provisioning-completeness-and-fixture-instrumentation.md`
  exactly — do not add behavior beyond it without a design update.

  Test-only (`test/support/`, compiled under `elixirc_paths(:test)` per `mix.exs`) —
  **not** part of the shipped application, never referenced from `lib/`, and never
  added to `lib/letflow/application.ex`'s supervision tree (design §4 INV-F-1). Not a
  GenServer, not a supervised process of any kind — a plain module, matching
  `Letflow.TenantSchemaReaper`'s established shape for this directory.

  ## Why this exists

  `TenantProvisioning.provision_tenant_schema/1` and
  `TenantProvisioning.replay_migrations/2` are two separate, composable primitives —
  neither calls the other, and that separation is a decided invariant
  (`lib/letflow/design/req022-tenant-schema-provisioning.md` lines 288-294). The
  obligation to verify that the *combination* produced a complete schema therefore
  belongs to whoever sequences them — which, in every ISS-0109 failure, was a test
  fixture that asserted only `{:ok, _}` from replay and never that the resulting schema
  was complete. That is the real gap, and it is at the fixture layer; there is no
  production defect and this module changes no production code (design §2, INV-F-2).

  Ecto's migrator re-applies nothing for an already-recorded version, so a schema can
  have every `schema_migrations` row present and still be missing the table one of them
  created. That is why `assert_schema_complete!/2` checks the *table* oracle and not
  just replay's return value.

  ## Adoption boundary

  Adopted in exactly two modules in this run
  (`test/letflow/definitions/promotion_test.exs`,
  `test/letflow/definitions/promotion_assertion_rerun_test.exs`, design §5). The other
  39 copy-paste fixture sites are ISS-0112 / GH#366 and are out of scope; the module is
  shaped so they can migrate one file at a time later, with all per-site variation
  carried by `opts`.

  ## Deviation from the design's literal `@type`, recorded rather than silent

  Design §3.2 declares `registration_present?` and `schema_present?` as `boolean()`,
  while design §3.5 — which INV-F-4 explicitly names as **normative** for the failure
  boundary — requires a scalar field whose own query failed to degrade to `nil`, so
  that an *unobserved* value is never reported as an observed absence. The two cannot
  both hold. §3.5's precedence is stated in the design itself, so those two fields are
  typed `boolean() | nil` here: `false` means "observed absent", `nil` means "not
  observed". Reported to ORCH as a MINOR design/implementation discrepancy.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]
  import Ecto.Query, only: [from: 2]

  require Logger

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @typedoc """
  What `provisioned_tenant!/1` hands back. Map destructuring is partial in Elixir, so
  the `:tenant` key is additive and non-breaking at call sites that bind only a subset.
  """
  @type tenant_fixture :: %{
          tenant_id: Ecto.UUID.t(),
          schema_name: String.t(),
          tenant: Letflow.Identity.Tenant.t()
        }

  @type opts :: [
          slug_prefix: String.t(),
          display_name: String.t(),
          oidc_mode: :enabled | :disabled,
          idp_realm_id: String.t() | nil,
          expected_tables: [String.t()] | :default,
          teardown: boolean(),
          template: :clone | :replay,
          pool: boolean()
        ]

  @typedoc """
  One-shot snapshot of a tenant's provisioning state at the moment of a failure.

  `registration_present?`/`schema_present?` are `nil` (not `false`) when the query that
  would have observed them failed — see the moduledoc's deviation note and design §3.5.
  """
  @type schema_state :: %{
          schema_name: String.t(),
          tenant_id: Ecto.UUID.t(),
          registration_present?: boolean() | nil,
          provisioned_at: NaiveDateTime.t() | nil,
          migrations_applied_at: NaiveDateTime.t() | nil,
          schema_present?: boolean() | nil,
          tables_present: [String.t()],
          tables_missing: [String.t()],
          applied_versions: [integer()],
          manifest_versions: [integer()],
          versions_missing: [integer()],
          observed_at_utc: NaiveDateTime.t(),
          db_now: NaiveDateTime.t() | nil,
          pg_backend_pid: integer() | nil
        }

  # Fixed and greppable; never assembled at runtime from parts (design §3.6).
  @marker "LETFLOW_TENANT_FIXTURE"

  # Closed phase vocabulary (design §3.6). `teardown` is the ONLY phase the teardown
  # path emits, and the other three are the only phases the failure path emits — so a
  # `phase=teardown` line in a raw log is, by construction, a post-test teardown and
  # never a mid-test drop. That ambiguity is what produced ISS-0109's misdiagnosis.
  @phase_teardown "teardown"
  @phase_provision_failed "provision_failed"
  @phase_replay_failed "replay_failed"
  @phase_incomplete_schema "incomplete_schema"

  # ISS-1042: the pooled-tenant path (Letflow.TenantFixture.Pool) emits ONLY these
  # phases, all distinct from the four above, so the "a phase=teardown line is by
  # construction a post-test teardown" invariant is untouched: pool_clone,
  # pool_acquire, pool_reset, pool_fallback, pool_teardown.

  # The tables the @tenant_scoped_migration_manifest's `create table(..., prefix:
  # prefix())` migrations produce (48 as of REQ-402 -- see
  # test/letflow/support/tenant_fixture_test.exs's own running count comment
  # for the bump history; this list, not that count, is authoritative).
  # `schema_migrations` is deliberately NOT here: it is
  # the migrator's own bookkeeping, and its CONTENTS are captured separately as
  # `applied_versions`. Guarded against rot by this module's own oracle test (design
  # §3.3, INV-F-7) — removing that test invalidates this hard-coded list.
  @expected_tenant_tables [
    "alert_hook_emission_state",
    "alert_trigger_state",
    "api_tokens",
    "artifact_activation_groups",
    "artifact_activation_history",
    "artifact_activations",
    "artifact_versions",
    "audit_chain_locks",
    "audit_entries",
    "correlation_cursors",
    "definition_sequence",
    "dlq_entries",
    "document_external_registrations",
    "document_sequences",
    "document_types",
    "document_versions",
    "documents",
    "effect_completions",
    "entity_definitions",
    "entity_field_restrictions",
    "entity_record_attachments",
    "entity_record_latest",
    "entity_type_hook_bindings",
    "entity_type_instances",
    "entity_type_restrictions",
    "entity_views",
    "event_idempotency",
    "event_payload_store",
    "event_type_registry",
    "events",
    "events_archive",
    "group_members",
    "groups",
    "help_content",
    "integration_mappings",
    "instance_attachments",
    "instance_definition_snapshots",
    "instance_projections",
    "instance_sequence",
    "instance_state_snapshots",
    "label_overrides",
    "lua_script_execution_audit",
    "number_sequence_counters",
    "number_sequence_definitions",
    "number_sequence_numbers",
    "notification_templates",
    "pending_tenant_admin_grants",
    "process_definitions",
    "promotion_assertion_runs",
    "promotion_reviews",
    "repository_artifacts",
    "role_scope_grants",
    "scheduled_jobs",
    "scope_node_paths",
    "scope_shadow_counters",
    "script_policy",
    "script_readable_masters",
    "script_rules",
    "script_task_dispatches",
    "service_task_dispatches",
    "tasks",
    "tenant_modules",
    "tenant_role",
    "timers",
    "tokens",
    "user_entity_grants",
    "user_entity_type_grants",
    "users",
    "variable_schemas",
    "webhook_delivery_attempts",
    "webhook_subscriptions"
  ]

  @doc """
  Provisions a real tenant schema for the calling test and asserts it is complete.

  Reproduces the behaviour of the hand-rolled `provisioned_tenant/0` copies it replaces,
  statement for statement, and then adds the completeness check and the failure capture.
  In order:

  1. `Sandbox.mode(Letflow.Repo, :auto)` — unchanged, and deliberately **not** restored
     to `:manual` (that is ISS-0113, out of scope; INV-F-6).
  2. Inserts a `Letflow.Identity.Tenant` via `Tenant.create_changeset/3` with exactly
     two cast attributes (`slug`, `display_name`) and `opts[:oidc_mode]` (default
     `:disabled`) as the third positional argument. No `:status` is cast, so the row
     gets the schema default `:active` — exactly as both adopted sites do today.
  3. Registers the `on_exit/1` teardown **before** provisioning, so a failure in any
     later step still cleans up.
  4-5. Either `Letflow.Test.TenantTemplate.ensure_template!/0` +
     `clone_tenant_schema!/1` (`opts[:template] == :clone`, the default — ISS-0427), or
     `TenantProvisioning.provision_tenant_schema/1` + `replay_migrations/1`
     (`opts[:template] == :replay`, today's exact original behaviour, kept as an
     explicit escape hatch — design §4.1).
  6. `assert_schema_complete!/2` — unchanged, runs against either path.

  Any failure in 4-6 raises `ExUnit.AssertionError` carrying the full
  `capture_schema_state/1` report, and emits it once more via `Logger.error/1` under the
  marker so it survives assertion-output truncation.

  `opts[:teardown]` defaults to `true`. `false` exists only so the design's fail-first
  tests can construct a broken state without this fixture's own teardown racing their
  assertions; neither adopted module uses it.

  `opts[:template]` defaults to `:clone` (ISS-0427,
  `lib/letflow/design/iss0427-tenant-test-schema-template-clone.md` §4.1, INV-2) —
  cloned from `Letflow.Test.TenantTemplate`'s prepared `"tenant_template"` schema
  instead of replaying all tenant-scoped migrations per call. This changes the
  provisioning *mechanism* for every existing call site by default, not the observable
  schema shape (design §3's parity check exists to guarantee that). Pass
  `template: :replay` for a test with a concrete reason to want a real,
  freshly-migrated-from-scratch schema — in particular any test that also passes a
  non-default `migration_source` downstream, which the clone path cannot serve at all.

  ## `async: true` callers (ISS-0113 / ISS-0423 — no opt-in flag, no `restore_sandbox`)

  This function's own unconditional first line, `Sandbox.mode(Letflow.Repo, :auto)`, is
  sufficient by itself to make a calling test file safe to declare `async: true`,
  *provided* the call site is independently classified safe by
  `lib/letflow/design/iss0113-tenant-fixture-sandbox-restore-opt-in.md` §3's three-
  mechanism procedure (self-checkout, concurrent multi-process DB access, a second
  provisioning call). **No additional flag, checkout, or restore step is needed, and
  none is provided** — a prior design revision (`restore_sandbox: true`, since removed)
  tried to additionally flip the sandbox back to `:manual` with a fresh checkout after
  provisioning, and that made things *worse*, not better: see the design doc's §9 for
  the full trace of why a second mid-test `Sandbox.mode/2` call is actively harmful
  (it discards the connection this function's own provisioning work just established),
  whereas leaving `:auto` mode in effect for the rest of the test (today's original,
  unchanged behavior) is exactly what makes `async: true` work, not what blocks it.
  """
  @spec provisioned_tenant!(opts()) :: tenant_fixture()
  def provisioned_tenant!(opts \\ []) do
    Sandbox.mode(Letflow.Repo, :auto)

    # ISS-1042: the ONE dispatch point. A pool attached to this test process (opt-in,
    # `attach_pool!/1`) serves the call; every other call -- and every call in a module
    # that never opted in -- takes the unchanged default path below.
    case pool_dispatch(opts) do
      {:pooled, fixture} -> fixture
      :default -> default_provisioned_tenant!(opts)
    end
  end

  defp default_provisioned_tenant!(opts) do
    slug_prefix = Keyword.get(opts, :slug_prefix, "tenant-fixture")
    display_name = Keyword.get(opts, :display_name, "Tenant Fixture")
    oidc_mode = Keyword.get(opts, :oidc_mode, :disabled)
    idp_realm_id = Keyword.get(opts, :idp_realm_id, nil)
    expected = Keyword.get(opts, :expected_tables, :default)
    template = Keyword.get(opts, :template, :clone)
    owner = owning_test()

    tenant =
      %Tenant{}
      |> Tenant.create_changeset(
        %{
          slug: Letflow.TenantSlugFixture.unique_slug(slug_prefix),
          display_name: display_name,
          idp_realm_id: idp_realm_id
        },
        oidc_mode
      )
      |> Repo.insert!()

    if Keyword.get(opts, :teardown, true) do
      on_exit(fn -> teardown(tenant.id, owner) end)
    end

    schema_name = provision_schema!(template, tenant.id)
    assert_schema_complete!(tenant.id, expected)

    %{tenant_id: tenant.id, schema_name: schema_name, tenant: tenant}
  end

  # -----------------------------------------------------------------------------------
  # ISS-1042 -- opt-in, module-scoped pooled tenant.
  #
  # Design: lib/letflow/design/iss1042-pooled-tenant-fixture.md. A NON-async test module
  # clones each declared tenant shape ONCE (`start_pool!/2`, in `setup_all`); each test
  # then gets the same schema back after a fence, a detect pass, a dirty-only reset, a
  # verify pass and a final guard (`Letflow.TenantFixture.Pool`). Definitional drift is
  # never repaired in place: the slot is rebuilt by a fresh clone. The default path
  # above is untouched; this section is only reached through `pool_dispatch/1`.
  # -----------------------------------------------------------------------------------

  @pool_key {__MODULE__, :pool}
  @claims_key {__MODULE__, :claims}
  @fence_key {__MODULE__, :end_fence_registered}

  @typedoc "One tenant shape a pool serves. Defaults match `provisioned_tenant!/1`."
  @type slot_spec :: [
          slug_prefix: String.t(),
          display_name: String.t(),
          oidc_mode: :enabled | :disabled,
          idp_realm_id: String.t() | nil,
          expected_tables: [String.t()] | :default
        ]

  @typedoc """
  `slots` is required. `reset_hooks` run in the TEST process after the DB reset (for
  VM-global in-memory tenant-keyed state, design 6.1). `after_verify` / `after_guard` are
  TEST-ONLY seams run in the pool worker. `parity_check: true` additionally runs
  `assert_clone_parity!/3` (all 13 dimensions) on every slot at creation.
  """
  @type pool_opts :: [
          slots: [slot_spec()],
          reset_hooks: [(tenant_fixture() -> any())],
          hooks: [
            after_verify: (schema_name :: String.t() -> any()),
            after_guard: (schema_name :: String.t() -> any())
          ],
          parity_check: boolean(),
          expected_database: String.t() | nil
        ]

  @opaque pool :: %{
            module: module(),
            worker: pid(),
            reset_hooks: [(tenant_fixture() -> any())]
          }

  @type pool_dirty_report :: %{
          dirty_tables: [String.t()],
          dirty_sequences: [String.t()],
          seeds_diverged: [String.t()],
          definition_drift: [String.t()],
          public_keyed_rows: [{String.t(), non_neg_integer()}],
          tenant_row_diverged: boolean(),
          clean?: boolean()
        }

  @type pool_stats :: %{
          slots: non_neg_integer(),
          clones: non_neg_integer(),
          acquires: non_neg_integer(),
          resets: non_neg_integer(),
          rebuilds: non_neg_integer(),
          final_guard_resets: non_neg_integer(),
          fallback_reasons: [atom()],
          dirty_tables_truncated: non_neg_integer(),
          digest_ms_total: non_neg_integer(),
          reset_ms_total: non_neg_integer(),
          generations: %{String.t() => non_neg_integer()}
        }

  @slot_spec_keys [:slug_prefix, :display_name, :oidc_mode, :idp_realm_id, :expected_tables]

  @doc """
  Creates the module's tenant pool. Call from the adopting module's `setup_all`; it returns
  `[tenant_pool: pool]` so the value is merged into every test's context for
  `attach_pool!/1`.

  Raises `ArgumentError` if the module is not explicitly `async: false` (the context must
  carry `async: false`; an absent key is rejected, never defaulted to "ok"), if `slots` is
  missing or empty, or if a pool for the same module already exists in this VM.

  Every slot is cloned once, here, never lazily from a test (INV-P2). Declare the maximum
  number of tenants a single test claims: each declared slot is one clone per module.
  Teardown (`on_exit`) drops every slot's schema and removes its `Registration` and
  `Tenant` rows after the module's last test.

  ## Adopter audit rule (design 6.2) -- read before adopting a module

  A module may adopt the pool only if no process it (or any `lib/` entry point it calls)
  starts can outlive the test and touch the tenant schema: every `Task`/`spawn`/
  `start_supervised`/`GenServer.cast` is awaited or stopped before the test body returns,
  no fire-and-forget `lib/` worker is reachable, and no ETS / `Application.put_env` /
  telemetry / GenServer state keyed by tenant id leaks across tests (use `reset_hooks`
  for the ones that do). Record the result as one line per item in a comment above the
  module's `setup_all`. A module that cannot show this keeps the default fresh clone.

  ## Database guard (ISS-1061 / Q-1054 / GH #2400)

  Before anything is provisioned, cloned, reset or dropped, `assert_test_database!/1`
  refuses (`ArgumentError`) to run unless the connected `current_database()` equals the
  configured `Letflow.Repo` database AND that name is a `letflow_test*` database. The
  `:expected_database` opt is a test-only seam for proving the refusal; the default is the
  configured database, and a non-`letflow_test*` name is refused even when supplied. Only
  the pool's own start-up path is guarded: the fresh-clone / `TenantTemplate` paths are out
  of scope here.
  """
  @spec start_pool!(context :: map(), pool_opts()) :: [tenant_pool: pool()]
  def start_pool!(context, opts) when is_map(context) and is_list(opts) do
    unless Map.get(context, :async) == false do
      raise ArgumentError,
            "Letflow.TenantFixture.start_pool!/2 requires an explicit `async: false` module " <>
              "(context[:async] was #{inspect(Map.get(context, :async))}); a pooled tenant is " <>
              "one mutable schema and cannot serve concurrent tests"
    end

    module =
      case Map.get(context, :module) do
        module when is_atom(module) and not is_nil(module) -> module
        other -> raise ArgumentError, "start_pool!/2: context[:module] is #{inspect(other)}"
      end

    specs =
      case Keyword.get(opts, :slots) do
        [_ | _] = slots ->
          Enum.map(slots, &normalize_spec!/1)

        other ->
          raise ArgumentError, "start_pool!/2 requires a non-empty :slots, got #{inspect(other)}"
      end

    reset_hooks = Keyword.get(opts, :reset_hooks, [])
    hooks = Keyword.get(opts, :hooks, [])

    # `Sandbox.mode(:auto)` first, as `provisioned_tenant!/1` does: the worker's own
    # statements (and the clone's DDL) must commit on ordinary pool connections.
    Sandbox.mode(Letflow.Repo, :auto)

    # ISS-1061: strictly before the worker is started and before any slot is created, so a
    # refusal leaves nothing registered and nothing to tear down.
    expected_database = Keyword.get(opts, :expected_database)
    :ok = assert_test_database!(expected_database)

    init = %{
      module: module,
      hooks: hooks,
      parity_check: Keyword.get(opts, :parity_check, false),
      expected_database: expected_database
    }

    worker =
      case GenServer.start(Letflow.TenantFixture.Pool, init, name: pool_name(module)) do
        {:ok, pid} ->
          pid

        {:error, {:already_started, _pid}} ->
          raise ArgumentError,
                "start_pool!/2: a pool for #{inspect(module)} is already registered in this VM"
      end

    on_exit(fn -> pool_teardown!(worker) end)

    case call_worker!(worker, {:create_slots, specs}) do
      :ok ->
        [tenant_pool: %{module: module, worker: worker, reset_hooks: reset_hooks}]

      {:error, message} ->
        raise ExUnit.AssertionError, message: message
    end
  end

  @doc false
  # ISS-1061 / Q-1054 / GH #2400. Fail-closed database guard for the pool's destructive
  # paths. `expected` defaults to the configured Repo database (never a literal); it must
  # also be a `letflow_test*` name, so a config pointed at a real database is not a
  # tautology. Must run on an ordinary pool connection (after `Sandbox.mode(:auto)`).
  @spec assert_test_database!(expected :: String.t() | nil) :: :ok
  def assert_test_database!(expected \\ nil) do
    expected = expected || Keyword.get(Repo.config(), :database)

    unless is_binary(expected) and String.starts_with?(expected, "letflow_test") do
      raise ArgumentError,
            "LETFLOW_TENANT_FIXTURE phase=pool_database_guard expected database " <>
              "#{inspect(expected)} is not a letflow_test* database; refusing to provision, " <>
              "clone, reset or drop anything"
    end

    %{rows: [[actual]]} = Repo.query!("SELECT current_database()")

    if actual != expected do
      raise ArgumentError,
            "LETFLOW_TENANT_FIXTURE phase=pool_database_guard connected to database " <>
              "#{inspect(actual)} but the configured test database is #{inspect(expected)}; " <>
              "refusing to provision, clone, reset or drop anything"
    end

    :ok
  end

  @doc """
  Attaches the module's pool to the calling TEST process. Call from a `setup` that is
  declared BEFORE every setup that calls `provisioned_tenant!/1` (or a helper that does):
  per-test setups run in the test process, which is where the claim happens.

  Raises `ArgumentError` for an async module, when the context carries no pool, on a second
  call in the same process, or if the process already holds a claim.
  """
  @spec attach_pool!(context :: map()) :: :ok
  def attach_pool!(context) when is_map(context) do
    unless Map.get(context, :async) == false do
      raise ArgumentError,
            "attach_pool!/1 requires an explicit `async: false` module " <>
              "(context[:async] was #{inspect(Map.get(context, :async))})"
    end

    pool =
      case Map.get(context, :tenant_pool) do
        %{worker: worker} = pool when is_pid(worker) ->
          pool

        _other ->
          raise ArgumentError,
                "attach_pool!/1: the context has no :tenant_pool; call " <>
                  "start_pool!/2 from this module's setup_all"
      end

    if Process.get(@pool_key) != nil or Process.get(@claims_key, %{}) != %{} do
      raise ArgumentError,
            "attach_pool!/1 called twice, or after a claim, in the same test process"
    end

    Process.put(@pool_key, pool)
    Process.put(@claims_key, %{})
    :ok
  end

  @doc """
  Read-only report of how far the pooled slot behind `fixture` is from its baseline right
  now (what the next acquire would have to reset). Test-support. Executes in the pool worker.
  """
  @spec pool_dirty_report(tenant_fixture()) :: pool_dirty_report()
  def pool_dirty_report(%{schema_name: schema_name}) when is_binary(schema_name) do
    pool = attached_pool!()
    Sandbox.mode(Letflow.Repo, :auto)

    case call_worker!(pool.worker, {:dirty_report, schema_name}) do
      {:ok, report} -> report
      {:error, message} -> raise ExUnit.AssertionError, message: message
    end
  end

  @doc """
  Test-support: simulates a test boundary inside one test. Clears the per-test claim map
  (so the same slots can be acquired again) and runs the end-of-test fence (see
  `pool_end_fence!/0`).
  """
  @spec recycle_pool!() :: :ok
  def recycle_pool! do
    pool = attached_pool!()
    Process.put(@claims_key, %{})
    run_end_fence!(pool.worker)
  end

  @doc """
  The end-of-test fence: waits (bounded) until no other backend is mid-statement or
  mid-transaction against a pooled slot, and raises `ExUnit.AssertionError` naming the
  schema, backend pid, state and query text if one still is. Changes no data. Registered
  automatically as an `on_exit` at a test's first claim, so it runs after any `on_exit` the
  test registered LATER; an `on_exit` registered EARLIER than the first claim (for example one
  that stops a `start_supervised` process) runs after the fence (ExUnit runs them in reverse
  order).

  Honest limit: the match is on `pg_stat_activity.query` text, which Postgres truncates at
  `track_activity_query_size` (1024 bytes by default). Writers carry the schema name in the
  first bytes; a wide-column `SELECT` can put it past the cut and be invisible here.
  """
  @spec pool_end_fence!() :: :ok
  def pool_end_fence! do
    run_end_fence!(attached_pool!().worker)
  end

  @doc "Counters of the pool's work so far, plus the current generation of every slot."
  @spec pool_stats(pool()) :: pool_stats()
  def pool_stats(%{worker: worker}) do
    Sandbox.mode(Letflow.Repo, :auto)
    call_worker!(worker, :stats)
  end

  @doc false
  # Used by the pool worker: raises the same report-carrying AssertionError the default
  # path raises (and logs it under the marker).
  @spec pool_report_and_raise(String.t(), Ecto.UUID.t(), [String.t()]) :: no_return()
  def pool_report_and_raise(phase, tenant_id, reasons),
    do: report_and_raise(phase, tenant_id, reasons)

  @doc false
  @spec pool_name(module()) :: atom()
  def pool_name(module), do: Module.concat(Letflow.TenantFixture.Pool, module)

  defp attached_pool! do
    case Process.get(@pool_key) do
      %{worker: _} = pool ->
        pool

      _other ->
        raise ArgumentError,
              "no pooled tenant is attached to this process; call attach_pool!/1 first"
    end
  end

  defp normalize_spec!(spec) when is_list(spec) do
    case Keyword.keys(spec) -- @slot_spec_keys do
      [] -> shape_of(spec)
      unknown -> raise ArgumentError, "unknown slot_spec keys: #{inspect(unknown)}"
    end
  end

  defp normalize_spec!(other),
    do: raise(ArgumentError, "a slot_spec is a keyword list, got #{inspect(other)}")

  # The shape of a tenant: the five `slot_spec` fields with defaults applied. Equal shapes
  # are interchangeable; `{shape, k}` (k = occurrence within one test) names a slot.
  defp shape_of(opts) do
    %{
      slug_prefix: Keyword.get(opts, :slug_prefix, "tenant-fixture"),
      display_name: Keyword.get(opts, :display_name, "Tenant Fixture"),
      oidc_mode: Keyword.get(opts, :oidc_mode, :disabled),
      idp_realm_id: Keyword.get(opts, :idp_realm_id, nil),
      expected_tables: Keyword.get(opts, :expected_tables, :default)
    }
  end

  # A call is served from a pool only when ALL of: a pool is attached to this process,
  # template is :clone, teardown is true, and `pool:` is not false (design 7).
  defp pool_dispatch(opts) do
    eligible? =
      Keyword.get(opts, :template, :clone) == :clone and
        Keyword.get(opts, :teardown, true) == true and
        Keyword.get(opts, :pool, true) != false

    cond do
      not eligible? ->
        :default

      pool = Process.get(@pool_key) ->
        {:pooled, claim_pooled!(pool, opts)}

      true ->
        reject_misordered_pool!()
        :default
    end
  end

  defp claim_pooled!(pool, opts) do
    shape = shape_of(opts)
    claims = Process.get(@claims_key, %{})
    k = Map.get(claims, shape, 0)

    case call_worker!(pool.worker, {:acquire, {shape, k}}) do
      {:ok, fixture} ->
        Process.put(@claims_key, Map.put(claims, shape, k + 1))
        register_end_fence!(pool)
        Enum.each(pool.reset_hooks, & &1.(fixture))
        fixture

      {:undeclared, declared} ->
        raise ArgumentError,
              "provisioned_tenant!/1 asked a pooled module for slot #{inspect({shape, k})}, " <>
                "which start_pool!/2 did not declare in #{inspect(pool.module)}. " <>
                "Declared slots: #{inspect(declared)}. Declare it (one more clone per module) " <>
                "or pass `pool: false`."

      {:error, message} ->
        raise ExUnit.AssertionError, message: message
    end
  end

  # The fence runs after any on_exit the test registered LATER (ExUnit runs them in
  # reverse registration order) and is registered once per test, at the first claim.
  defp register_end_fence!(pool) do
    if Process.get(@fence_key) != true do
      Process.put(@fence_key, true)
      worker = pool.worker
      on_exit(fn -> run_end_fence!(worker) end)
    end
  end

  defp run_end_fence!(worker) do
    Sandbox.mode(Letflow.Repo, :auto)

    case call_worker!(worker, :end_fence) do
      :ok -> :ok
      {:error, message} -> raise ExUnit.AssertionError, message: message
    end
  end

  defp pool_teardown!(worker) do
    # FIRST statement (design 3.4): DataCase leaves the mode at {:shared, dead_test_pid}.
    Sandbox.mode(Letflow.Repo, :auto)

    if Process.alive?(worker) do
      result = call_worker!(worker, :teardown)
      GenServer.stop(worker, :normal)

      case result do
        :ok -> :ok
        {:error, message} -> raise ExUnit.AssertionError, message: message
      end
    else
      Logger.warning(
        "#{@marker} phase=pool_teardown pool worker already gone; its schemas are left to " <>
          "Letflow.TenantSchemaReaper's sweep"
      )
    end
  end

  # No call timeout (design review M4): clone + rebuild + final-guard budgets legitimately
  # exceed GenServer's 5 s default on a slow host, and a spurious exit would be flaky, not
  # deterministic. The worker only waits on DB locks bounded by lock_timeout.
  defp call_worker!(worker, message) do
    GenServer.call(worker, message, :infinity)
  catch
    :exit, reason ->
      raise ExUnit.AssertionError,
        message:
          "#{@marker} phase=pool_fallback the pool worker is unavailable: #{inspect(reason)}"
  end

  # A process with no attachment normally takes the default path. The one exception is the
  # TEST process of a pooled module that forgot (or misordered) `attach_pool!/1`: that must
  # fail loudly, never silently clone per test or double-hand a slot.
  defp reject_misordered_pool! do
    with module when not is_nil(module) <- owning_module(),
         true <- test_process?(),
         pid when is_pid(pid) <- Process.whereis(pool_name(module)) do
      raise ArgumentError,
            "provisioned_tenant!/1 was called in #{inspect(module)} (pool worker #{inspect(pid)}) " <>
              "before attach_pool!/1: attach_pool!/1 must be the module's FIRST setup, " <>
              "before any setup that provisions a tenant"
    else
      _no_pool -> :ok
    end
  end

  # ExUnit stores the running test under the `ExUnit.Runner` key in the dictionary of the
  # process that runs the module (see owning_test/0). The module is read from the same key.
  defp owning_module do
    (parent_chain(self(), 4) ++ List.wrap(Process.get(:"$ancestors")))
    |> Enum.find_value(&current_module_of/1)
  rescue
    _exception -> nil
  end

  defp current_module_of(pid) when is_pid(pid) do
    with {:dictionary, dictionary} <- Process.info(pid, :dictionary),
         {ExUnit.Runner, %{__struct__: ExUnit.Test, module: module}} <-
           List.keyfind(dictionary, ExUnit.Runner, 0) do
      module
    else
      _other -> nil
    end
  end

  defp current_module_of(_not_a_pid), do: nil

  # The test process is the direct child of the process holding the runner key and has no
  # `$ancestors`; a Task or spawned helper of the test is not (its parent is the test).
  defp test_process? do
    Process.get(:"$ancestors") == nil and
      case Process.info(self(), :parent) do
        {:parent, parent} when is_pid(parent) -> current_module_of(parent) != nil
        _other -> false
      end
  rescue
    _exception -> false
  end

  @doc """
  Captures, in one shot, everything about a tenant's provisioning state that the
  ISS-0109 diagnosis could not answer after the fact.

  **Never raises to its caller** (INV-F-4) — the caller's own failure must remain the
  reported failure, so a capture that blew up must never replace it. Mirrors
  `Letflow.TenantSchemaReaper.sweep_orphans/2`'s same contract.

  Failure boundary, per design §3.5 (normative):

    * Each field is gathered inside its own guard. If gathering *that field* raises,
      that field alone degrades — `nil` for scalars, `[]` for lists — and the call still
      returns `{:ok, schema_state()}` with every other field populated. **A single
      failing query is always a per-field degradation, never a whole-call failure.**
    * Derived fields follow their inputs: if `tables_present` degraded to `[]`, then
      `tables_missing` is `[]` too — *not* "all 19 missing" — because an unobserved set
      must never be reported as an observed absence. Same for
      `applied_versions`/`versions_missing`.
    * `{:error, {:capture_failed, exception}}` is the **outer safety net only**: a
      failure outside the per-field guards, such as a malformed `tenant_id` for which no
      field can be attempted at all. It is not reachable by any single field's query
      failing.
    * A tenant that simply does not exist, or whose schema is absent, is **not** a
      capture failure: it returns `{:ok, state}` with the `present?` flags `false`.

  One shot: no retry, no polling — a retry would observe a *different* state than the
  one that failed (design §9 item 8).
  """
  @spec capture_schema_state(tenant_id :: Ecto.UUID.t()) ::
          {:ok, schema_state()} | {:error, {:capture_failed, Exception.t()}}
  def capture_schema_state(tenant_id) do
    case do_capture(tenant_id, :default) do
      {:ok, state, _observed} -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Asserts that the tenant's schema exists and is fully migrated. Returns `:ok`, or
  raises `ExUnit.AssertionError` embedding the full `capture_schema_state/1` report.

  Three checks, all required — neither of the last two subsumes the other:

  1. The schema is present in `information_schema.schemata`.
  2. `tables_missing == []` (`expected -- tables_present`, `tables_present` read from
     `information_schema.tables`). This is what catches a *recorded* migration version
     whose table is nonetheless absent — the state Ecto's migrator will never repair,
     because it re-applies nothing for a version already in `schema_migrations`.
  3. `versions_missing == []` (`tenant_scoped_migrations/0`'s versions against
     `"<schema>".schema_migrations`). This is what catches "replay never fully ran".

  Per INV-F-10, a check whose own observation failed is skipped rather than failed: only
  a *genuinely observed* absence turns a test red. A wholly failed capture logs a
  warning and returns `:ok`.
  """
  @spec assert_schema_complete!(
          tenant_id :: Ecto.UUID.t(),
          expected :: [String.t()] | :default
        ) :: :ok
  def assert_schema_complete!(tenant_id, expected \\ :default) do
    case do_capture(tenant_id, expected) do
      {:ok, state, observed} ->
        case incompleteness_reasons(state, observed) do
          [] -> :ok
          reasons -> raise_with_report(@phase_incomplete_schema, state, reasons)
        end

      {:error, {:capture_failed, exception}} ->
        # INV-F-10: a failing capture must never turn a passing test red.
        Logger.warning(
          "#{@marker} phase=#{@phase_incomplete_schema} capture_failed " <>
            "tenant_id=#{inspect(tenant_id)} reason=#{Exception.message(exception)} " <>
            "(assertion skipped, not failed)"
        )

        :ok
    end
  end

  @doc """
  The completeness oracle: the tables a fully replayed tenant schema contains.

  Hard-coded, and safe to hard-code only because of the oracle-rot test that provisions
  a throwaway tenant and asserts set equality against `information_schema.tables` in
  **both** directions (design §3.3, INV-F-7). Without that test, this list must not be
  hard-coded. Excludes `schema_migrations` — see the module attribute's comment.

  Also, as of REQ-376, deliberately excludes every table
  `req376_partition_management_table?/1` recognizes — see that function's own doc for
  why those specifically cannot be enumerated here the same way every other table is.
  """
  @spec expected_tenant_tables() :: [String.t()]
  def expected_tenant_tables, do: @expected_tenant_tables

  # REQ-376 (lib/letflow/design/req376-partition-event-retirement.md §2/§4.3) gave
  # `events`/`events_archive` a set of physical tables this module's static
  # `@expected_tenant_tables` oracle cannot enumerate the same way as every other
  # table, for two distinct reasons:
  #
  #   1. `events_default`, `events_archive_default`, and the two renamed-aside
  #      rollback-safety-net tables (`events_pre_partition_20260922`,
  #      `events_archive_pre_partition_20260922`, design §2.1 migration 4/8) are
  #      FIXED names, but are migration-conversion ARTIFACTS, not part of the
  #      "logical" table set a test tenant is provisioned to expose -- they exist
  #      only because Postgres cannot convert an existing table to partitioned
  #      in place (design §2). Adding them to `@expected_tenant_tables` would also
  #      make `Letflow.Test.TenantTemplate`'s `do_clone/2` try to
  #      `CREATE TABLE (LIKE ... INCLUDING ALL)` them into every cloned test
  #      tenant, which is pointless there: `CREATE TABLE (LIKE partitioned_parent
  #      INCLUDING ALL)` does not itself copy the `PARTITION BY` clause (a
  #      documented Postgres LIKE limitation, not a bug here), so a *cloned*
  #      tenant's `events`/`events_archive` are already plain, unpartitioned
  #      tables with no DEFAULT/dedicated-month children to model.
  #   2. `events_y<year>m<month>` / `events_archive_y<year>m<month>` (design §2.2)
  #      are literally NOT a fixed set of names -- which ones exist after a fresh
  #      `replay_migrations/2` depends on the calendar month at migration-run
  #      time (`Letflow.EventStore.PartitionMaintenance.months_ahead_default/0`'s
  #      own lookahead, migration 2's identical one-time window) -- a hard-coded
  #      list of literal names would go stale every calendar month by
  #      construction, which is exactly the kind of hard-coding INV-F-7's own
  #      oracle-rot test exists to catch, not something to paper over with a
  #      list that is wrong more often than it's right.
  #
  # Both classes are still real, structurally-necessary tables under a genuine
  # `:replay` provisioning (`Letflow.TenantProvisioning.provision_tenant_schema/1`
  # + `replay_migrations/2`, exactly what `Letflow.Test.TenantTemplate`'s own
  # staging-schema build uses) -- callers comparing an ACTUAL replayed schema's
  # table set against `expected_tenant_tables/0` (this module's own C6
  # oracle-rot test; `Letflow.Test.TenantTemplate`'s `template_self_check!/1`)
  # must filter them out of the "extra" side of that comparison via this
  # predicate first, rather than either (a) hard-coding a set of names that
  # goes stale, or (b) weakening the strict-equality check itself for every
  # other table too.
  @req376_fixed_partition_management_tables [
    "events_archive_default",
    "events_archive_pre_partition_20260922",
    "events_default",
    "events_pre_partition_20260922"
  ]

  @req376_dynamic_partition_table_pattern ~r/^events(_archive)?_y\d{4}m(0[1-9]|1[0-2])$/

  @doc """
  True for a table name that is one of REQ-376's partition-management
  artifacts (see this function's neighboring module-attribute comment for the
  two classes and why neither belongs in `expected_tenant_tables/0`) — every
  other table name is `false`, including every table `expected_tenant_tables/0`
  itself lists.
  """
  @spec req376_partition_management_table?(String.t()) :: boolean()
  def req376_partition_management_table?(table_name) when is_binary(table_name) do
    table_name in @req376_fixed_partition_management_tables or
      req376_dynamic_partition_table?(table_name)
  end

  @doc """
  True only for the date-dependent calendar-month partition tables
  (`events_yYYYYmMM` / `events_archive_yYYYYmMM`, month 01-12) -- NOT for the
  four fixed partition-management tables. Their names depend on the UTC date
  the migration ran, so they differ between a template built in one month and
  a reference replayed in another (ISS-0937). Single source of the pattern.
  """
  @spec req376_dynamic_partition_table?(String.t()) :: boolean()
  def req376_dynamic_partition_table?(table_name) when is_binary(table_name) do
    Regex.match?(@req376_dynamic_partition_table_pattern, table_name)
  end

  # -----------------------------------------------------------------------------------
  # Provisioning steps -- the two production primitives (:replay path) are sequenced
  # explicitly here, never chained through each other (INV-F-3, req022 lines 288-294).
  # The :clone path (ISS-0427, default) is a separate, test-only fast path -- see
  # Letflow.Test.TenantTemplate, design §4.1.
  # -----------------------------------------------------------------------------------

  defp provision_schema!(:replay, tenant_id) do
    schema_name = provision!(tenant_id)
    replay!(tenant_id)
    schema_name
  end

  defp provision_schema!(:clone, tenant_id) do
    Letflow.Test.TenantTemplate.ensure_template!()

    case Letflow.Test.TenantTemplate.clone_tenant_schema!(tenant_id) do
      {:ok, schema_name} ->
        schema_name

      {:error, reason} ->
        report_and_raise(@phase_replay_failed, tenant_id, [
          "clone_tenant_schema!/1 returned {:error, #{inspect(reason)}}"
        ])
    end
  end

  defp provision!(tenant_id) do
    case TenantProvisioning.provision_tenant_schema(tenant_id) do
      {:ok, %Registration{schema_name: schema_name}} ->
        schema_name

      other ->
        report_and_raise(@phase_provision_failed, tenant_id, [
          "provision_tenant_schema/1 returned #{inspect(other)}"
        ])
    end
  end

  defp replay!(tenant_id) do
    case TenantProvisioning.replay_migrations(tenant_id) do
      {:ok, _applied_versions} ->
        :ok

      other ->
        report_and_raise(@phase_replay_failed, tenant_id, [
          "replay_migrations/1 returned #{inspect(other)}"
        ])
    end
  end

  # -----------------------------------------------------------------------------------
  # Teardown -- today's three statements, unchanged in content and order (INV-F-5),
  # plus exactly ONE log line before the DROP.
  # -----------------------------------------------------------------------------------

  defp teardown(tenant_id, owner) do
    case TenantProvisioning.schema_name_for_tenant(tenant_id) do
      {:ok, schema_name} ->
        log_teardown(tenant_id, schema_name, owner)
        Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))

      {:error, :invalid_tenant_id} ->
        :ok
    end

    Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant_id))
    Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))
  end

  # `schema_present_before_drop` distinguishes "we tore down a schema that was still
  # there" (normal) from "we tore down a schema that had already vanished" -- the
  # ISS-0109 shape, which `DROP SCHEMA IF EXISTS ... CASCADE` silently succeeds against,
  # telling nobody.
  #
  # OQ-4, settled by measurement rather than assumption: this repo has no `config
  # :logger` in any config file, so under MIX_ENV=test `Logger.level()` is `:debug`,
  # `:logger`'s primary level is `:debug`, and the default handler's level is `:all`.
  # `[debug]` Ecto SQL lines are visibly emitted by `mix test` today. `:info` is
  # therefore NOT filtered, and this line stays at `:info` as the design specifies --
  # no raise to `:warning`, and no logger reconfiguration (which would have changed
  # output for every other test).
  defp log_teardown(tenant_id, schema_name, {test_module, test_name}) do
    present = guarded(fn -> schema_present?(schema_name) end, nil)

    Logger.info(
      "#{@marker} phase=#{@phase_teardown} schema=#{schema_name} tenant_id=#{tenant_id} " <>
        "schema_present_before_drop=#{inspect(present)} " <>
        "test_module=#{test_module} test_name=#{inspect(test_name)}"
    )
  rescue
    # INV-F-10: a failing log call must never turn a passing test red.
    _exception -> :ok
  end

  # -----------------------------------------------------------------------------------
  # Failure reporting -- emitted twice, deliberately (design §3.5): into the raised
  # AssertionError (so CI's preserved test output has it) and via Logger.error under the
  # marker (so it is greppable in a raw run log even when assertion output is truncated).
  # -----------------------------------------------------------------------------------

  defp report_and_raise(phase, tenant_id, reasons) do
    case do_capture(tenant_id, :default) do
      {:ok, state, _observed} ->
        raise_with_report(phase, state, reasons)

      {:error, {:capture_failed, exception}} ->
        message =
          "#{@marker} phase=#{phase} tenant_id=#{inspect(tenant_id)}\n" <>
            Enum.map_join(reasons, "\n", &("  - " <> &1)) <>
            "\n  - capture_schema_state/1 returned {:error, {:capture_failed, " <>
            "#{Exception.message(exception)}}}"

        Logger.error(message)
        raise ExUnit.AssertionError, message: message
    end
  end

  defp raise_with_report(phase, state, reasons) do
    message =
      "#{@marker} phase=#{phase} schema=#{state.schema_name} tenant_id=#{state.tenant_id}\n" <>
        Enum.map_join(reasons, "\n", &("  - " <> &1)) <>
        "\n\n" <> format_report(state)

    Logger.error(message)
    raise ExUnit.AssertionError, message: message
  end

  defp incompleteness_reasons(state, observed) do
    schema_reason =
      if observed.schema and state.schema_present? == false do
        ["schema #{state.schema_name} is absent from information_schema.schemata"]
      else
        []
      end

    tables_reason =
      if observed.tables and state.tables_missing != [] do
        ["tables_missing=#{inspect(state.tables_missing)}"]
      else
        []
      end

    versions_reason =
      if observed.versions and state.versions_missing != [] do
        ["versions_missing=#{inspect(state.versions_missing)}"]
      else
        []
      end

    schema_reason ++ tables_reason ++ versions_reason
  end

  defp format_report(state) do
    """
    schema_state:
      schema_name             = #{state.schema_name}
      tenant_id               = #{state.tenant_id}
      registration_present?   = #{inspect(state.registration_present?)}
      provisioned_at          = #{inspect(state.provisioned_at)}
      migrations_applied_at   = #{inspect(state.migrations_applied_at)}
      schema_present?         = #{inspect(state.schema_present?)}
      tables_present          = #{inspect(state.tables_present)}
      tables_missing          = #{inspect(state.tables_missing)}
      applied_versions        = #{inspect(state.applied_versions)}
      manifest_versions       = #{inspect(state.manifest_versions)}
      versions_missing        = #{inspect(state.versions_missing)}
      observed_at_utc         = #{inspect(state.observed_at_utc)}
      db_now                  = #{inspect(state.db_now)}
      pg_backend_pid          = #{inspect(state.pg_backend_pid)}
    """
  end

  # -----------------------------------------------------------------------------------
  # Capture -- one shot, per-field guards, no retry, no polling.
  #
  # Returns the public `schema_state()` PLUS a private per-field observation map, so
  # assert_schema_complete!/2 can tell "observed absent" from "never observed" without
  # widening the public shape. Every query below is either parameterized and scoped to
  # this one tenant/schema, or a catalog read filtered by `table_schema = $1` (INV-F-8);
  # the only identifier interpolation is `"<schema>".schema_migrations`, and <schema> is
  # always schema_name_for_tenant/1's output, never caller-supplied (INV-F-9).
  # -----------------------------------------------------------------------------------

  defp do_capture(tenant_id, expected) do
    schema_name =
      case TenantProvisioning.schema_name_for_tenant(tenant_id) do
        {:ok, name} ->
          name

        {:error, reason} ->
          # Outside the per-field guards: with no schema name, no field can be attempted.
          raise ArgumentError,
                "cannot derive a schema name for tenant_id=#{inspect(tenant_id)}: " <>
                  inspect(reason)
      end

    registration =
      guarded(fn -> {:observed, Repo.get_by(Registration, tenant_id: tenant_id)} end, nil)

    schema_present = guarded(fn -> schema_present?(schema_name) end, nil)
    tables = guarded(fn -> {:observed, tables_in(schema_name)} end, nil)
    applied = guarded(fn -> {:observed, applied_versions_in(schema_name)} end, nil)
    manifest = guarded(fn -> {:observed, manifest_versions()} end, nil)

    expected_tables =
      case expected do
        :default -> @expected_tenant_tables
        list when is_list(list) -> list
      end

    tables_present = observed_or(tables, [])
    applied_versions = observed_or(applied, [])
    manifest_versions = observed_or(manifest, [])

    versions_observed? = observed?(applied) and observed?(manifest)

    state = %{
      schema_name: schema_name,
      tenant_id: tenant_id,
      registration_present?: registration_present(registration),
      provisioned_at: registration_field(registration, :provisioned_at),
      migrations_applied_at: registration_field(registration, :migrations_applied_at),
      schema_present?: schema_present,
      tables_present: tables_present,
      # Derived fields follow their inputs: an UNOBSERVED set is never reported as an
      # observed absence, so a degraded tables_present yields [] here, not "all missing".
      tables_missing: if(observed?(tables), do: expected_tables -- tables_present, else: []),
      applied_versions: applied_versions,
      manifest_versions: manifest_versions,
      versions_missing:
        if(versions_observed?, do: manifest_versions -- applied_versions, else: []),
      observed_at_utc: NaiveDateTime.utc_now(),
      db_now: guarded(fn -> db_now() end, nil),
      pg_backend_pid: guarded(fn -> pg_backend_pid() end, nil)
    }

    observed = %{
      registration: observed?(registration),
      schema: schema_present != nil,
      tables: observed?(tables),
      versions: versions_observed?
    }

    {:ok, state, observed}
  rescue
    exception -> {:error, {:capture_failed, exception}}
  end

  # Per-field guard: `fun` either returns its value, or raises and that ONE field
  # degrades to `degraded` while every other field is still gathered.
  defp guarded(fun, degraded) do
    fun.()
  rescue
    _exception -> degraded
  end

  defp observed?({:observed, _value}), do: true
  defp observed?(_other), do: false

  defp observed_or({:observed, value}, _degraded), do: value
  defp observed_or(_other, degraded), do: degraded

  defp registration_present({:observed, %Registration{}}), do: true
  defp registration_present({:observed, nil}), do: false
  defp registration_present(_degraded), do: nil

  defp registration_field({:observed, %Registration{} = registration}, field),
    do: Map.fetch!(registration, field)

  defp registration_field(_other, _field), do: nil

  defp schema_present?(schema_name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT 1 FROM information_schema.schemata WHERE schema_name = $1",
        [schema_name]
      )

    rows != []
  end

  defp tables_in(schema_name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT table_name FROM information_schema.tables " <>
          "WHERE table_schema = $1 AND table_type = 'BASE TABLE'",
        [schema_name]
      )

    rows
    |> Enum.map(fn [table_name] -> table_name end)
    |> Enum.reject(&(&1 == "schema_migrations"))
    |> Enum.sort()
  end

  defp applied_versions_in(schema_name) do
    %{rows: rows} = Repo.query!(~s(SELECT version FROM "#{schema_name}".schema_migrations))

    rows |> Enum.map(fn [version] -> version end) |> Enum.sort()
  end

  defp manifest_versions do
    TenantProvisioning.tenant_scoped_migrations()
    |> Enum.map(fn {version, _module} -> version end)
    |> Enum.sort()
  end

  defp db_now do
    %{rows: [[db_now]]} = Repo.query!("SELECT now() at time zone 'utc'")
    db_now
  end

  defp pg_backend_pid do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  # ExUnit stores the currently-running test under the `ExUnit.Runner` key in the
  # dictionary of the process that RUNS the module -- not of the spawned test process
  # itself -- so it is reached by walking `$ancestors`, the same shape ExUnit's own
  # `ExUnit.Runner.safe_pdict_current/1` uses. That is private API, so it is read
  # defensively and degrades to "unknown" rather than ever failing anything (INV-F-10).
  # Read at fixture-construction time and closed over, because `on_exit/1` callbacks run
  # in a process that is not a descendant of the runner at all.
  defp owning_test do
    (parent_chain(self(), 4) ++ List.wrap(Process.get(:"$ancestors")))
    |> Enum.find_value({"unknown", :unknown}, &current_test_of/1)
  rescue
    _exception -> {"unknown", :unknown}
  end

  # ExUnit spawns the test process with a bare `spawn_monitor`, so it carries no
  # `$ancestors`; the runner-held key is reached through the OTP-25+ `:parent` link.
  defp parent_chain(_pid, 0), do: []

  defp parent_chain(pid, depth) when is_pid(pid) do
    case Process.info(pid, :parent) do
      {:parent, parent} when is_pid(parent) -> [pid | parent_chain(parent, depth - 1)]
      _other -> [pid]
    end
  end

  defp parent_chain(_not_a_pid, _depth), do: []

  defp current_test_of(pid) when is_pid(pid) do
    with {:dictionary, dictionary} <- Process.info(pid, :dictionary),
         {ExUnit.Runner, current} <- List.keyfind(dictionary, ExUnit.Runner, 0) do
      case current do
        %{__struct__: ExUnit.Test, module: module, name: name} -> {inspect(module), name}
        %{__struct__: ExUnit.TestModule, name: module} -> {inspect(module), :"(module-level)"}
        _other -> nil
      end
    else
      _other -> nil
    end
  end

  defp current_test_of(_not_a_pid), do: nil
end

defmodule Letflow.TenantFixture.Pool do
  @moduledoc """
  The worker behind `Letflow.TenantFixture.start_pool!/2` (ISS-1042 / Q-1042 / GH #2381).
  Design: `lib/letflow/design/iss1042-pooled-tenant-fixture.md`.

  Test-only (`test/support/`), never referenced from `lib/`, never in the application's
  supervision tree. One plain `GenServer` per adopting module, started unlinked from the
  module's `setup_all` and stopped by that setup's `on_exit` (a link would let the worker
  die with the module process BEFORE the `on_exit` that tears its schemas down runs). It
  exists so reset and rebuild statements run on an ordinary pool connection, not on the
  test's own connection and locks (it has no `$callers`, so under Sandbox `:auto` it is
  not routed onto a `{:shared, pid}` checkout; every entry point sets `:auto` first).

  ## Every acquire runs the full sequence (INV-P12)

      fence A -> detect (probe P + digest D) -> [reset -> verify] -> final guard -> return

  Slot `status` never skips a step. The returned tenant was proven clean, by this worker's
  own session, at the instant of the final guard; foreign writes after that instant are
  detected and bounded to the owning test, not prevented (RR-1, design 9.4).

  ## What "public state" means in detect, verify and the final guard

  Detect and verify read, besides the clone schema (row presence, called sequences, seed
  digests, definitional digest): the count of rows keyed to the tenant in every discovered
  public table, and `public.tenants` / `public.tenant_schemas` row equality with their
  snapshots. The final guard re-reads the row-level half of the schema (probe P) AND the
  public state, but not the definitional digest (a definition change between verify and
  guard is caught by the next acquire's detect, and by the owning test's own assertions).

  ## Database guard (ISS-1061)

  `init/1` re-asserts the test database (`Letflow.TenantFixture.assert_test_database!/1`)
  before any state exists, in case the worker is started without `start_pool!/2`.

  ## Fail-closed (design OQ-8)

  A fence or guard that fires raises; there is no override knob and no downgrade to a log
  line. A false positive is stop-the-line and goes to ORCH.
  """

  use GenServer

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.Test.TenantTemplate
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @typedoc "A tenant shape: the five `slot_spec` fields with defaults applied."
  @type shape :: %{
          slug_prefix: String.t(),
          display_name: String.t(),
          oidc_mode: :enabled | :disabled,
          idp_realm_id: String.t() | nil,
          expected_tables: [String.t()] | :default
        }

  @typedoc "Names a slot: the shape and the occurrence index of that shape within one test."
  @type slot_key :: {shape(), non_neg_integer()}

  @typedoc """
  One pooled tenant. `baseline` and the two snapshots are `nil` until the slot's first
  clone completes; the snapshots are the JSON text of the tenant / registration rows.
  """
  @type slot :: %{
          key: slot_key(),
          shape: shape(),
          tenant: Tenant.t(),
          tenant_id: Ecto.UUID.t(),
          schema_name: String.t(),
          baseline: TenantTemplate.clone_baseline() | nil,
          tenant_snapshot: String.t() | nil,
          registration_snapshot: String.t() | nil,
          status: :creating | :clean | :handed_out,
          generation: non_neg_integer()
        }

  @typedoc "The pool worker's `GenServer` state."
  @type worker_state :: %{
          module: module(),
          hooks: [after_verify: (String.t() -> any()), after_guard: (String.t() -> any())],
          parity_check: boolean(),
          slots: %{optional(slot_key()) => slot()},
          order: [slot_key()],
          public_keyed: [{table :: String.t(), column :: String.t()}],
          public_sql: String.t() | nil,
          tenant_columns: [String.t()],
          registration_columns: [String.t()],
          stats: %{
            clones: non_neg_integer(),
            acquires: non_neg_integer(),
            resets: non_neg_integer(),
            rebuilds: non_neg_integer(),
            final_guard_resets: non_neg_integer(),
            fallback_reasons: [atom()],
            dirty_tables_truncated: non_neg_integer(),
            digest_ms_total: non_neg_integer(),
            reset_ms_total: non_neg_integer()
          }
        }

  @marker "LETFLOW_TENANT_FIXTURE"
  @fence_a_budget_ms 250
  @fence_end_budget_ms 500
  @fence_step_ms 10
  @public_excluded ["tenants", "tenant_schemas", "schema_migrations"]

  # -- GenServer ------------------------------------------------------------------------

  @impl true
  @spec init(%{
          required(:module) => module(),
          optional(:hooks) => keyword(),
          optional(:parity_check) => boolean(),
          optional(:expected_database) => String.t() | nil
        }) :: {:ok, worker_state()}
  def init(%{module: module} = init) do
    # ISS-1061: defense in depth for a direct GenServer.start of this public module; a
    # raise here makes start return {:error, {exception, stacktrace}} with nothing created.
    :ok = TenantFixture.assert_test_database!(Map.get(init, :expected_database))

    {:ok,
     %{
       module: module,
       hooks: Map.get(init, :hooks, []),
       parity_check: Map.get(init, :parity_check, false),
       slots: %{},
       order: [],
       public_keyed: [],
       public_sql: nil,
       tenant_columns: [],
       registration_columns: [],
       stats: %{
         clones: 0,
         acquires: 0,
         resets: 0,
         rebuilds: 0,
         final_guard_resets: 0,
         fallback_reasons: [],
         dirty_tables_truncated: 0,
         digest_ms_total: 0,
         reset_ms_total: 0
       }
     }}
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), worker_state()) ::
          {:reply, term(), worker_state()}
  def handle_call({:create_slots, shapes}, _from, state) do
    state = discover_public(state)

    {_seen, keyed} =
      Enum.reduce(shapes, {%{}, []}, fn shape, {seen, acc} ->
        k = Map.get(seen, shape, 0)
        {Map.put(seen, shape, k + 1), acc ++ [{shape, k}]}
      end)

    result =
      Enum.reduce_while(keyed, {:ok, state}, fn key, {:ok, st} ->
        st = insert_slot(st, key)

        try do
          {:cont, {:ok, clone_slot(st, key)}}
        rescue
          exception -> {:halt, {:error, Exception.message(exception), st}}
        end
      end)

    case result do
      {:ok, state} -> {:reply, :ok, state}
      {:error, message, state} -> {:reply, {:error, message}, state}
    end
  rescue
    exception -> {:reply, {:error, Exception.message(exception)}, state}
  end

  def handle_call({:acquire, key}, _from, state) do
    case Map.fetch(state.slots, key) do
      :error ->
        {:reply, {:undeclared, state.order}, state}

      {:ok, _slot} ->
        try do
          state = do_acquire(state, key)
          state = put_in(state.slots[key].status, :handed_out)
          {:reply, {:ok, fixture_of(Map.fetch!(state.slots, key))}, state}
        rescue
          exception ->
            {:reply, {:error, "#{@marker} phase=pool_fallback #{Exception.message(exception)}"},
             state}
        catch
          {:pool_fail, message, failed_state} -> {:reply, {:error, message}, failed_state}
        end
    end
  end

  def handle_call(:end_fence, _from, state) do
    case wait_quiescent(fence_keys(state), @fence_end_budget_ms) do
      :ok ->
        {:reply, :ok, state}

      {:busy, rows} ->
        slots = Map.new(state.slots, fn {k, s} -> {k, %{s | status: :handed_out}} end)
        state = add_fallback(%{state | slots: slots}, :straggler_at_end)

        message =
          "#{@marker} phase=pool_fallback reason=straggler_at_end a process was still using " <>
            "the pooled tenant after the test finished: #{describe_busy(rows)}"

        {:reply, {:error, message}, state}
    end
  rescue
    exception -> {:reply, {:error, Exception.message(exception)}, state}
  end

  def handle_call({:dirty_report, schema_name}, _from, state) do
    case Enum.find(Map.values(state.slots), &(&1.schema_name == schema_name)) do
      nil ->
        {:reply, {:error, "pool_dirty_report: #{schema_name} is not a pooled slot"}, state}

      slot ->
        {:reply, {:ok, dirty_report(state, slot)}, state}
    end
  rescue
    exception -> {:reply, {:error, Exception.message(exception)}, state}
  end

  def handle_call(:stats, _from, state) do
    stats =
      Map.merge(state.stats, %{
        slots: map_size(state.slots),
        generations:
          Map.new(state.slots, fn {_key, slot} -> {slot.schema_name, slot.generation} end)
      })

    {:reply, stats, state}
  end

  def handle_call(:teardown, _from, state) do
    errors =
      Enum.flat_map(state.order, fn key ->
        case Map.get(state.slots, key) do
          nil -> []
          slot -> teardown_slot(state, slot)
        end
      end)

    state = %{state | slots: %{}, order: []}

    case errors do
      [] -> {:reply, :ok, state}
      errors -> {:reply, {:error, Enum.join(errors, "\n")}, state}
    end
  end

  # -- slot creation --------------------------------------------------------------------

  defp insert_slot(state, {shape, _k} = key) do
    tenant =
      %Tenant{}
      |> Tenant.create_changeset(
        %{
          slug: Letflow.TenantSlugFixture.unique_slug(shape.slug_prefix),
          display_name: shape.display_name,
          idp_realm_id: shape.idp_realm_id
        },
        shape.oidc_mode
      )
      |> Repo.insert!()

    {:ok, schema_name} = TenantProvisioning.schema_name_for_tenant(tenant.id)

    slot = %{
      key: key,
      shape: shape,
      tenant: tenant,
      tenant_id: tenant.id,
      schema_name: schema_name,
      baseline: nil,
      tenant_snapshot: nil,
      registration_snapshot: nil,
      status: :creating,
      generation: 0
    }

    %{state | slots: Map.put(state.slots, key, slot), order: state.order ++ [key]}
  end

  defp clone_slot(state, key) do
    slot = Map.fetch!(state.slots, key)
    started = now_ms()

    TenantTemplate.ensure_template!()

    schema_name =
      case TenantTemplate.clone_tenant_schema!(slot.tenant_id) do
        {:ok, schema_name} ->
          schema_name

        {:error, reason} ->
          TenantFixture.pool_report_and_raise("replay_failed", slot.tenant_id, [
            "clone_tenant_schema!/1 returned {:error, #{inspect(reason)}}"
          ])
      end

    TenantFixture.assert_schema_complete!(slot.tenant_id, slot.shape.expected_tables)

    if state.parity_check do
      TenantTemplate.assert_clone_parity!(TenantTemplate.template_schema_name(), schema_name)
    end

    slot = %{
      slot
      | schema_name: schema_name,
        baseline: TenantTemplate.capture_clone_baseline!(schema_name),
        tenant_snapshot: snapshot_tenant(slot.tenant_id),
        registration_snapshot: snapshot_registration(slot.tenant_id),
        status: :clean
    }

    log(
      "phase=pool_clone schema=#{schema_name} tenant_id=#{slot.tenant_id} " <>
        "tables=#{length(TenantTemplate.baseline_tables(slot.baseline))} " <>
        "ms=#{now_ms() - started}"
    )

    state = bump(state, :clones, 1)
    %{state | slots: Map.put(state.slots, key, slot)}
  end

  defp snapshot_tenant(tenant_id) do
    %{rows: [[json]]} =
      Repo.query!("SELECT to_jsonb(t)::text FROM public.tenants t WHERE t.id = $1", [
        dump(tenant_id)
      ])

    json
  end

  defp snapshot_registration(tenant_id) do
    %{rows: [[json]]} =
      Repo.query!(
        "SELECT to_jsonb(r)::text FROM public.tenant_schemas r WHERE r.tenant_id = $1",
        [dump(tenant_id)]
      )

    json
  end

  # -- public state keyed to the tenant (design 5) ----------------------------------------

  defp discover_public(state) do
    %{rows: pairs} =
      Repo.query!(
        """
        SELECT DISTINCT c.relname, a.attname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
        WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
          AND a.atttypid = 'uuid'::regtype
          AND c.relname <> ALL ($1::text[])
          AND (
            EXISTS (SELECT 1 FROM pg_constraint k
                    WHERE k.conrelid = c.oid AND k.contype = 'f'
                      AND k.confrelid = 'public.tenants'::regclass
                      AND a.attnum = ANY (k.conkey))
            OR a.attname IN ('tenant_id', 'owner_tenant_id')
            OR a.attname LIKE '%\\_tenant\\_id'
          )
        ORDER BY 1, 2
        """,
        [@public_excluded]
      )

    keyed = Enum.map(pairs, fn [table, column] -> {table, column} end)
    tables = keyed |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    %{rows: edges} =
      Repo.query!(
        """
        SELECT cr.relname, pr.relname
        FROM pg_constraint k
        JOIN pg_class cr ON cr.oid = k.conrelid
        JOIN pg_class pr ON pr.oid = k.confrelid
        JOIN pg_namespace cn ON cn.oid = cr.relnamespace AND cn.nspname = 'public'
        JOIN pg_namespace pn ON pn.oid = pr.relnamespace AND pn.nspname = 'public'
        WHERE k.contype = 'f' AND cr.relname = ANY ($1::text[]) AND pr.relname = ANY ($1::text[])
          AND cr.oid <> pr.oid
        """,
        [tables]
      )

    ordered_tables = children_first(tables, Enum.map(edges, fn [c, p] -> {c, p} end))

    ordered =
      Enum.flat_map(ordered_tables, fn table ->
        for {t, c} <- keyed, t == table, do: {t, c}
      end)

    keyed_sql =
      for {table, column} <- ordered do
        "SELECT 'pub', #{literal(table)}, count(*)::text, NULL::text " <>
          "FROM public.#{ident(table)} WHERE #{ident(column)} = $1"
      end

    public_sql =
      Enum.join(
        keyed_sql ++
          [
            "SELECT 'tenant', 'tenants', (to_jsonb(t) = $2::text::jsonb)::text, NULL::text " <>
              "FROM public.tenants t WHERE t.id = $1",
            "SELECT 'registration', 'tenant_schemas', (to_jsonb(r) = $3::text::jsonb)::text, " <>
              "NULL::text FROM public.tenant_schemas r WHERE r.tenant_id = $1"
          ],
        "\nUNION ALL\n"
      )

    %{
      state
      | public_keyed: ordered,
        public_sql: public_sql,
        tenant_columns: columns_of("tenants"),
        registration_columns: columns_of("tenant_schemas")
    }
  end

  defp columns_of(table) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT column_name FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = $1 ORDER BY ordinal_position
        """,
        [table]
      )

    Enum.map(rows, fn [name] -> name end)
  end

  # Children (FK-referencing) tables before the tables they reference. A cycle raises at
  # adoption time instead of guessing.
  defp children_first(tables, edges), do: do_children_first(tables, edges, [])

  defp do_children_first([], _edges, acc), do: Enum.reverse(acc)

  defp do_children_first(remaining, edges, acc) do
    ready =
      Enum.filter(remaining, fn table ->
        not Enum.any?(edges, fn {child, parent} -> parent == table and child in remaining end)
      end)

    if ready == [] do
      raise "public tables keyed to a tenant form a foreign-key cycle: #{inspect(remaining)}"
    end

    do_children_first(remaining -- ready, edges, Enum.reverse(ready) ++ acc)
  end

  defp public_state(state, slot) do
    %{rows: rows} =
      Repo.query!(state.public_sql, [
        dump(slot.tenant_id),
        slot.tenant_snapshot,
        slot.registration_snapshot
      ])

    keyed =
      for ["pub", table, count, _] <- rows, String.to_integer(count) > 0 do
        {table, String.to_integer(count)}
      end

    %{
      keyed_rows: keyed,
      tenant_ok?: Enum.any?(rows, &match?(["tenant", _, "true", _], &1)),
      registration_ok?: Enum.any?(rows, &match?(["registration", _, "true", _], &1))
    }
  end

  defp public_clean?(%{keyed_rows: [], tenant_ok?: true, registration_ok?: true}), do: true
  defp public_clean?(_public), do: false

  # Runs inside the reset transaction (and, after a rebuild, in its own).
  defp reset_public!(state, slot, public) do
    tenant_id = dump(slot.tenant_id)
    dirty = Map.new(public.keyed_rows)

    for {table, column} <- state.public_keyed, Map.has_key?(dirty, table) do
      Repo.query!("DELETE FROM public.#{ident(table)} WHERE #{ident(column)} = $1", [tenant_id])
    end

    unless public.tenant_ok? do
      restore_row!("tenants", "id", state.tenant_columns, slot.tenant_snapshot, tenant_id)
    end

    unless public.registration_ok? do
      restore_row!(
        "tenant_schemas",
        "tenant_id",
        state.registration_columns,
        slot.registration_snapshot,
        tenant_id
      )
    end

    :ok
  end

  defp restore_row!(table, key_column, columns, snapshot, tenant_id) do
    assignments =
      columns
      |> Enum.reject(&(&1 in ["id", key_column]))
      |> Enum.map_join(", ", &"#{ident(&1)} = r.#{ident(&1)}")

    Repo.query!(
      "UPDATE public.#{ident(table)} AS t SET #{assignments} " <>
        "FROM jsonb_populate_record(NULL::public.#{ident(table)}, $1::text::jsonb) AS r " <>
        "WHERE t.#{ident(key_column)} = $2",
      [snapshot, tenant_id]
    )
  end

  # -- acquire --------------------------------------------------------------------------

  defp do_acquire(state, key) do
    started = now_ms()
    state = bump(state, :acquires, 1)

    state = fence_a!(state)
    {state, outcome} = prove_clean(state, key)
    state = final_guard!(state, key, 1)

    slot = Map.fetch!(state.slots, key)

    log(
      "phase=pool_acquire slot=#{slot.schema_name} outcome=#{outcome} " <>
        "generation=#{slot.generation} ms=#{now_ms() - started}"
    )

    state
  end

  # Fence A: no other client backend may be mid-statement / mid-transaction against a
  # pooled slot when the next test starts. A straggler that is still there after the
  # budget is NOT waved through (design review M2): its uncommitted writes are invisible
  # to every probe, so the proof below could not protect the test.
  defp fence_a!(state) do
    case wait_quiescent(fence_keys(state), @fence_a_budget_ms) do
      :ok ->
        state

      {:busy, rows} ->
        state = add_fallback(state, :straggler_at_acquire)

        fail(
          state,
          "#{@marker} phase=pool_fallback reason=pool_straggler a process is still using the " <>
            "pooled tenant at acquire: #{describe_busy(rows)}"
        )
    end
  end

  defp prove_clean(state, key) do
    slot = Map.fetch!(state.slots, key)

    case detect(state, slot) do
      {:error, reason} ->
        state
        |> rebuild(key, :probe_failed, [inspect(reason)])
        |> finish_after_rebuild(key)

      {:ok, %{drift: [_ | _] = drift}, _public, _st} ->
        state
        |> rebuild(key, :definition_drift, drift)
        |> finish_after_rebuild(key)

      {:ok, diff, public, st} ->
        state = add_digest(state, st)

        if TenantTemplate.clean_diff?(diff) and public_clean?(public) do
          {state, :clean}
        else
          reset(state, key, diff, public)
        end
    end
  end

  defp reset(state, key, diff, public) do
    slot = Map.fetch!(state.slots, key)
    started = now_ms()

    result =
      TenantTemplate.reset_clone_schema!(slot.schema_name, slot.baseline,
        extra: fn -> reset_public!(state, slot, public) end
      )

    case result do
      {:ok, report} ->
        if public_clean?(public_state(state, slot)) do
          log(
            "phase=pool_reset slot=#{slot.schema_name} " <>
              "dirty_tables=#{length(report.truncated) - length(report.closure_added)} " <>
              "closure_added=#{length(report.closure_added)} " <>
              "sequences=#{length(report.sequences_restarted)} probe_ms=#{report.probe_ms} " <>
              "verify_ms=#{report.verify_ms} total_ms=#{report.total_ms}"
          )

          state =
            state
            |> bump(:resets, 1)
            |> bump(:dirty_tables_truncated, length(diff.dirty_tables))
            |> bump(:reset_ms_total, report.total_ms)

          {state, :reset}
        else
          state
          |> rebuild(key, :verify_failed, ["public state not clean after reset"])
          |> finish_after_rebuild(key)
        end

      {:error, {:unprovable, reasons}} ->
        state = bump(state, :reset_ms_total, now_ms() - started)

        reason =
          if match?(["definition_drift" | _], reasons),
            do: :definition_drift,
            else: :verify_failed

        state
        |> rebuild(key, reason, reasons)
        |> finish_after_rebuild(key)
    end
  end

  # Design 4.6: a rebuilt slot is never handed out on the strength of the rebuild alone.
  # Re-run detect on it; the schema must be clean, and public state (which a rebuild
  # cannot repair) is reset here, loudly, or the acquire raises.
  defp finish_after_rebuild(state, key) do
    slot = Map.fetch!(state.slots, key)

    case detect(state, slot) do
      {:ok, diff, public, _st} ->
        cond do
          not TenantTemplate.clean_diff?(diff) ->
            fail(
              state,
              "#{@marker} phase=pool_fallback a rebuilt slot is not clean: " <>
                Enum.join(TenantTemplate.describe_diff(diff), "; ")
            )

          public_clean?(public) ->
            {state, :rebuilt}

          true ->
            {:ok, :ok} = Repo.transaction(fn -> reset_public!(state, slot, public) end)

            if public_clean?(public_state(state, slot)) do
              {state, :rebuilt}
            else
              fail(state, "#{@marker} phase=pool_fallback public state could not be reset")
            end
        end

      {:error, reason} ->
        fail(
          state,
          "#{@marker} phase=pool_fallback probe failed after rebuild: #{inspect(reason)}"
        )
    end
  end

  defp detect(state, slot) do
    tables = TenantTemplate.baseline_tables(slot.baseline)

    case TenantTemplate.probe_clone_state(slot.schema_name, tables) do
      {:ok, st} ->
        {:ok, TenantTemplate.diff_clone_state(st, slot.baseline), public_state(state, slot), st}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Design 4.3 step 7. `after_verify` is a TEST-ONLY seam that runs before each guard.
  defp final_guard!(state, key, attempt) do
    slot = Map.fetch!(state.slots, key)
    run_hook(state, :after_verify, slot.schema_name)

    tables = TenantTemplate.baseline_tables(slot.baseline)

    diff =
      case TenantTemplate.probe_clone_data(slot.schema_name, tables) do
        {:ok, data} ->
          TenantTemplate.diff_clone_state(data, slot.baseline)

        {:error, reason} ->
          fail(
            state,
            "#{@marker} phase=pool_fallback final guard probe failed: #{inspect(reason)}"
          )
      end

    public = public_state(state, slot)

    cond do
      TenantTemplate.clean_diff?(diff) and public_clean?(public) ->
        run_hook(state, :after_guard, slot.schema_name)
        state

      attempt == 1 ->
        state = state |> bump(:final_guard_resets, 1) |> add_fallback(:final_guard)
        log("phase=pool_fallback reason=final_guard slot=#{slot.schema_name}")
        {state, _outcome} = prove_clean(state, key)
        final_guard!(state, key, 2)

      true ->
        keyed = Enum.map(public.keyed_rows, fn {t, n} -> "public #{t} rows=#{n}" end)

        fail(
          state,
          "#{@marker} phase=pool_fallback reason=pool_straggler the pooled tenant " <>
            "#{slot.schema_name} was written to again after two resets (a writer is still " <>
            "active): " <> Enum.join(TenantTemplate.describe_diff(diff) ++ keyed, "; ")
        )
    end
  end

  defp run_hook(state, name, schema_name) do
    case Keyword.get(state.hooks, name) do
      fun when is_function(fun, 1) -> fun.(schema_name)
      _none -> :ok
    end
  end

  # -- rebuild (design 4.6) ---------------------------------------------------------------

  defp rebuild(state, key, reason, details) do
    slot = Map.fetch!(state.slots, key)
    started = now_ms()

    log(
      "phase=pool_fallback reason=#{reason} slot=#{slot.schema_name} " <>
        "details=#{inspect(Enum.take(details, 5))}"
    )

    case TenantTemplate.rebuild_clone_schema!(slot.tenant_id) do
      {:ok, schema_name} ->
        TenantFixture.assert_schema_complete!(slot.tenant_id, slot.shape.expected_tables)

        # The tenant snapshot is deliberately NOT re-taken: a rebuild does not touch
        # public.tenants, so re-snapshotting could bless a row a test had corrupted. The
        # registration row IS new (new id and timestamps), so it is re-snapshotted.
        slot = %{
          slot
          | schema_name: schema_name,
            baseline: TenantTemplate.capture_clone_baseline!(schema_name),
            registration_snapshot: snapshot_registration(slot.tenant_id),
            status: :clean,
            generation: slot.generation + 1
        }

        log(
          "phase=pool_clone slot=#{schema_name} rebuilt=true " <>
            "generation=#{slot.generation} ms=#{now_ms() - started}"
        )

        state
        |> Map.update!(:slots, &Map.put(&1, key, slot))
        |> bump(:rebuilds, 1)
        |> bump(:clones, 1)
        |> add_fallback(reason)

      {:error, error} ->
        state = add_fallback(state, reason)

        try do
          TenantFixture.pool_report_and_raise("replay_failed", slot.tenant_id, [
            "rebuild_clone_schema!/1 returned {:error, #{inspect(error)}}"
          ])
        rescue
          exception -> fail(state, Exception.message(exception))
        end
    end
  end

  # -- reports ----------------------------------------------------------------------------

  defp dirty_report(state, slot) do
    {:ok, st} =
      TenantTemplate.probe_clone_state(
        slot.schema_name,
        TenantTemplate.baseline_tables(slot.baseline)
      )

    diff = TenantTemplate.diff_clone_state(st, slot.baseline)
    public = public_state(state, slot)

    %{
      dirty_tables: diff.dirty_tables,
      dirty_sequences: Enum.map(diff.dirty_sequences, fn {_owner, sequence} -> sequence end),
      seeds_diverged: diff.seeds_diverged,
      definition_drift: diff.drift,
      public_keyed_rows: public.keyed_rows,
      tenant_row_diverged: not (public.tenant_ok? and public.registration_ok?),
      clean?: TenantTemplate.clean_diff?(diff) and public_clean?(public)
    }
  end

  defp fixture_of(slot) do
    %{tenant_id: slot.tenant_id, schema_name: slot.schema_name, tenant: slot.tenant}
  end

  # -- quiescence fence (design 3.6 / 4.3 step 1) -----------------------------------------

  defp fence_keys(state) do
    state.slots
    |> Map.values()
    |> Enum.flat_map(fn slot -> [slot.schema_name, slot.tenant_id] end)
    |> Enum.uniq()
  end

  defp wait_quiescent(keys, budget_ms), do: do_wait_quiescent(keys, now_ms() + budget_ms)

  defp do_wait_quiescent(keys, deadline) do
    case busy_backends(keys) do
      [] ->
        :ok

      rows ->
        if now_ms() >= deadline do
          {:busy, rows}
        else
          Process.sleep(@fence_step_ms)
          do_wait_quiescent(keys, deadline)
        end
    end
  end

  # Client backends of this database, other than this worker's current one, that are
  # mid-statement or mid-transaction and whose current/last query text names a pooled
  # slot's schema or tenant id. Honest limit: `track_activity_query_size` truncates the
  # text (1024 bytes by default) and Ecto SELECTs put the schema after the column list,
  # so a wide read can be invisible here; writers carry the schema in the first bytes.
  defp busy_backends(keys) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT pid, state, left(query, 300)
        FROM pg_stat_activity
        WHERE datname = current_database()
          AND backend_type = 'client backend'
          AND pid <> pg_backend_pid()
          AND state IN ('active', 'idle in transaction', 'idle in transaction (aborted)')
          AND EXISTS (SELECT 1 FROM unnest($1::text[]) k WHERE strpos(query, k) > 0)
        """,
        [keys]
      )

    rows
  end

  defp describe_busy(rows) do
    Enum.map_join(rows, "; ", fn [pid, state, query] ->
      "backend pid=#{pid} state=#{state} query=#{inspect(query)}"
    end)
  end

  # -- teardown (design 3.4) ----------------------------------------------------------------

  defp teardown_slot(state, slot) do
    log(
      "phase=pool_teardown schema=#{slot.schema_name} tenant_id=#{slot.tenant_id} " <>
        "test_module=#{inspect(state.module)}"
    )

    dump = dump(slot.tenant_id)

    steps = [
      fn ->
        for {table, column} <- state.public_keyed do
          Repo.query!("DELETE FROM public.#{ident(table)} WHERE #{ident(column)} = $1", [dump])
        end
      end,
      fn -> Repo.query!("DROP SCHEMA IF EXISTS #{ident(slot.schema_name)} CASCADE") end,
      fn -> Repo.delete_all(from(r in Registration, where: r.tenant_id == ^slot.tenant_id)) end,
      fn -> Repo.delete_all(from(t in Tenant, where: t.id == ^slot.tenant_id)) end
    ]

    Enum.flat_map(steps, fn step ->
      try do
        step.()
        []
      rescue
        exception ->
          ["#{@marker} phase=pool_teardown #{slot.schema_name}: #{Exception.message(exception)}"]
      end
    end)
  end

  # -- small helpers ------------------------------------------------------------------------

  defp fail(state, message), do: throw({:pool_fail, message, state})

  defp bump(state, counter, by), do: update_in(state.stats[counter], &(&1 + by))

  defp add_fallback(state, reason),
    do: update_in(state.stats.fallback_reasons, &(&1 ++ [reason]))

  defp add_digest(state, %{digest_ms: digest_ms}), do: bump(state, :digest_ms_total, digest_ms)

  defp log(text), do: Logger.info("#{@marker} #{text}")

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp dump(tenant_id), do: Ecto.UUID.dump!(tenant_id)

  # Identifiers come from the catalog or `schema_name_for_tenant/1`, never from user input
  # (INV-7); quoting with quote-doubling is belt and braces.
  defp ident(name), do: ~s("#{String.replace(name, ~s("), ~s(""))}")

  defp literal(value), do: "'#{String.replace(value, "'", "''")}'"
end
