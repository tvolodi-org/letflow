defmodule Letflow.Test.TenantTemplate do
  @moduledoc """
  Builds a "tenant_template" Postgres schema once per BEAM VM / test-partition
  database, then materialises per-test tenant schemas from it via
  `CREATE TABLE (LIKE ... INCLUDING ALL)` plus the fix-ups Postgres's `LIKE`
  does not perform (foreign keys, sequence ownership) and the table data it
  never copies at all (`event_type_registry`, `schema_migrations`).

  Implements `lib/letflow/design/iss0427-tenant-test-schema-template-clone.md`
  — build from that design, don't invent a different shape. Test-only
  (`test/support/`, compiled under `elixirc_paths(:test)`), **not** referenced
  from `lib/`, **not** added to `lib/letflow/application.ex`'s supervision
  tree, **not** a GenServer — a plain module, matching `Letflow.TenantFixture`'s
  and `Letflow.TenantSchemaReaper`'s established shape for this directory.

  ## Production path untouched (design §7)

  `Letflow.TenantProvisioning.provision_tenant_schema/1` and
  `replay_migrations/2` are not modified and are not called by this module —
  see `ensure_template!/0`'s own moduledoc note for why. Zero new code is
  reachable from real tenant onboarding.

  ## No silent fallback (design §5)

  Every function here either succeeds or raises/returns a tagged error. There
  is no path that falls back to migration replay on failure — a broken
  template must never silently serve broken clones.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @typedoc "Design §2.1's template_state type — informational only, not stored as such."
  @type template_state :: :not_built | :built | :stale

  # Fixed literal name (design §2.2) -- deliberately NOT of the
  # "tenant_" <> 32-hex shape schema_name_for_tenant/1 produces, so
  # tenant_id_for_schema_name/1 can never resolve it as a real tenant (INV-1).
  @template_schema "tenant_template"

  # Advisory-lock key (design §4.3), same idiom as
  # TenantProvisioning.provision_tenant_schema/1's own
  # `pg_advisory_xact_lock(hashtext($1))` call -- keyed on this literal string
  # rather than a per-tenant schema name, since there is exactly one template.
  @advisory_lock_key @template_schema

  # Process-local idempotency marker (design §4.2) -- a persistent_term, not a
  # cross-VM mechanism. "Once" is scoped per BEAM VM / per test-partition
  # database, which is what persistent_term already gives for free within one
  # VM's lifetime.
  @built_marker_key {__MODULE__, :template_built}

  # ISS-0842: fingerprint stored as a COMMENT ON SCHEMA "tenant_template".
  # Records which tenant migration versions the template was built from.
  # Excluded from cloning (schema-level comments are not part of the data
  # schema itself and are never LIKE-copied into tenant schemas). Read back by
  # template_db_state/0 to decide whether a reused test DB's existing template
  # is still current or must be dropped and rebuilt.
  @fingerprint_comment_prefix "letflow_migrations_v1:"

  # ISS-0578 design §1.1/§1.2: bounded retry-with-backoff around
  # do_clone/2's whole clone transaction, for the narrow class of transient
  # connection failure named there. 3 total attempts (initial + 2 retries),
  # fixed (not exponential) 200ms backoff between attempts -- see the design
  # doc for why these values are reasoned, not measured.
  @clone_max_attempts 3
  @clone_retry_backoff_ms 200

  @doc """
  Idempotent. Builds the `"tenant_template"` schema exactly once per BEAM VM /
  test-partition database (design §4.2). Safe to call from many tests; see
  §4.3's advisory-lock concurrency guard.

  Raises (`ExUnit.AssertionError`, matching `TenantFixture.report_and_raise/3`'s
  convention) if the template cannot be built or fails its own post-build
  self-check (design §2.3 step 3) or parity self-check (design §3.4 use site
  1). Never falls back to anything else — see design §5.

  ## ISS-0515: pre-built synchronously from `test/test_helper.exs`

  As of ISS-0515, `test/test_helper.exs` calls this function once, directly,
  as a synchronous top-level statement — before `ExUnit.start/1` ever
  dispatches a single test in that partition process. See
  `lib/letflow/design/iss0515-tenant-template-build-race-fix.md` for the
  full rationale; in short, this eliminates the concurrent-first-caller race
  that previously let 2+ async tests in the same `scripts/test_parallel.sh`
  partition collide on this function's advisory-lock acquisition
  (`Repo.query!/2` below, subject to Ecto's default 15000ms client timeout)
  and raise `Postgrex.Error: query_canceled`. After that pre-build call
  completes, every real test's own call into this function takes the
  `template_ready?/0` fast path below — no logic in this function changed to
  make that true.
  """
  @spec ensure_template!() :: :ok
  def ensure_template! do
    # The template schema is SHARED, long-lived state -- it must survive the
    # calling test's own sandbox transaction, or its DDL is rolled back and
    # the next caller finds a half-built schema. Measured symptom when this
    # was left to the caller: partition databases ended up with a
    # tenant_template holding 1 table instead of ~39, and every dependent
    # test failed TENANT_TEMPLATE_SELF_CHECK_FAILED with the full table set
    # reported missing.
    #
    # tenant_fixture.ex's provisioned_tenant!/1 already sets :auto before it
    # reaches here, but ensure_template!/0 is public and must not depend on
    # its caller having done so. Setting it here is idempotent and matches
    # what tenant_fixture.ex itself does (and deliberately does not restore,
    # for the same reason -- see its own note at line 171).
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    if template_ready?() do
      :ok
    else
      # ISS-0842: wrap the entire advisory lock acquire/release section in
      # Repo.checkout/2, which pins ONE physical connection to this process
      # for the duration of the callback. Without this, two separate
      # Repo.query!/2 calls (acquire and release) could be dispatched to
      # different pool connections -- acquiring the SESSION-level advisory
      # lock on connection A, then attempting to release it on connection B,
      # leaving A's lock orphaned until the connection is recycled. This was
      # harmless under the original design (ensure_template!/0 was called
      # exactly once from test_helper.exs, so the lock path ran at most once
      # per VM lifetime), but the ISS-0842 stale-rebuild path can enter the
      # lock section multiple times per VM lifetime (once to detect stale,
      # once to rebuild). Repo.checkout/2 pins connection A for the entire
      # callback, so acquire, check, build, and release all use session A.
      #
      # unboxed_run is NOT needed inside this block: Repo.checkout/2 already
      # provides a real (non-sandboxed) connection when Sandbox mode is :auto.
      # All Repo.query!/2 calls in the callback -- including those inside
      # build_template!/0 and replay_migrations/2's own nested Repo.checkout --
      # reuse connection A (DBConnection's re-entrant checkout). DDL committed
      # on connection A survives the process's own sandbox transaction cleanup
      # because connection A is not sandbox-managed.
      Repo.checkout(fn ->
        # SESSION-level advisory lock (pg_advisory_lock/pg_advisory_unlock), not
        # the transaction-scoped pg_advisory_xact_lock provision_tenant_schema/1
        # uses -- deliberately, because build_template!/0 below calls
        # replay_migrations/2, whose Ecto.Migrator.run/4 checks out its OWN
        # connection. With Repo.checkout, that nested checkout reuses connection A
        # (DBConnection re-entrant), so the advisory lock is active for the full
        # migration replay. Explicitly unlocked in an `after` block so a raise
        # inside the case arms still releases it (design §4.3's concurrency guard,
        # adapted to this function's own I/O shape).
        Repo.query!("SELECT pg_advisory_lock(hashtext($1))", [@advisory_lock_key])

        try do
          # Re-check inside the lock: a concurrent first-caller may have already
          # built the template while this call waited on the advisory lock.
          # ISS-0842: also check fingerprint — treat a stale template the same
          # as no template (drop it and rebuild). template_db_state/0 returns
          # :missing, :stale, or :current; :current is the only path that skips
          # the build.
          case template_db_state() do
            :current ->
              :ok

            :stale ->
              # Drop the stale schema first, then rebuild. DROP before BUILD:
              # build_template!/0 starts with CREATE SCHEMA, which would fail on
              # an already-existing name. INV-8 is preserved: the stale schema is
              # fully dropped before the new build starts its own
              # rename-into-place sequence.
              Repo.query!(~s(DROP SCHEMA "#{@template_schema}" CASCADE))
              build_template!()

            :missing ->
              # Build fresh. All operations run on the same connection A that
              # holds the advisory lock (via Repo.checkout's re-entrant pinning).
              # The pre-ISS-0842 note about needing unboxed_run to prevent DDL
              # rollback no longer applies: Repo.checkout/2 in :auto mode gives a
              # non-sandboxed connection, and DDL it commits is not wrapped in an
              # outer sandbox transaction.
              build_template!()
          end
        after
          Repo.query!("SELECT pg_advisory_unlock(hashtext($1))", [@advisory_lock_key])
        end
      end)

      :persistent_term.put(@built_marker_key, true)
      :ok
    end
  end

  @doc """
  Pure, no I/O beyond a fast local check (design §2.1) — lets a caller ask
  whether a prior `ensure_template!/0` call in THIS process already completed
  successfully, without forcing a build.
  """
  @spec template_ready?() :: boolean()
  def template_ready? do
    :persistent_term.get(@built_marker_key, false)
  end

  @doc """
  The fixed physical schema name the template lives under. Pure, no I/O.
  """
  @spec template_schema_name() :: String.t()
  def template_schema_name, do: @template_schema

  @doc """
  Clones `"tenant_template"` into a fresh schema for `source_tenant_id`, via
  the full sequence design §2.3 specifies: `CREATE SCHEMA`, `CREATE TABLE
  (LIKE ... INCLUDING ALL)` per table, foreign-key re-add with schema-qualifier
  rewrite, sequence recreation + default repoint + `OWNED BY`, seed-data copy
  (`event_type_registry`, `schema_migrations`), and the caller's `Registration`
  row insert.

  Preconditions: `ensure_template!/0` has already succeeded in this process's
  lifetime — this function does NOT call it implicitly (design §2.1, "no
  implicit chaining", matching `TenantProvisioning`'s own established
  precedent between `provision_tenant_schema/1` and `replay_migrations/2`).

  Returns `{:error, {:clone_failed, reason}}` on any failure instead of
  raising, so `TenantFixture`'s own `report_and_raise/3` call sites can wrap
  it uniformly. Never falls back to migration replay (design §5).
  """
  @spec clone_tenant_schema!(source_tenant_id :: Ecto.UUID.t()) ::
          {:ok, schema_name :: String.t()}
          | {:error, {:clone_failed, term()}}
  def clone_tenant_schema!(source_tenant_id) do
    with {:ok, clone_schema} <- TenantProvisioning.schema_name_for_tenant(source_tenant_id) do
      do_clone_with_retry(source_tenant_id, clone_schema)
    else
      {:error, reason} -> {:error, {:clone_failed, reason}}
    end
  rescue
    exception -> {:error, {:clone_failed, exception}}
  end

  @doc """
  The parity check (design §3, the crux). Raises `ExUnit.AssertionError` with
  a full diff report on any mismatch across the thirteen structural
  dimensions design §3.2 specifies. `reference_schema`/`candidate_schema` are
  each normalized (schema-qualifier stripped) before comparison, so the same
  function serves both of design §3.4's use sites regardless of which side is
  "the real one".

  Every dimension raises on its OWN first mismatch found (fail fast, full
  diff assembled from every dimension's own findings) so a caller sees every
  divergence in one run rather than one-at-a-time across repeated fixes.
  """
  @spec assert_clone_parity!(
          reference_schema :: String.t(),
          candidate_schema :: String.t(),
          opts :: Keyword.t()
        ) :: :ok
  def assert_clone_parity!(reference_schema, candidate_schema, opts \\ []) do
    dimensions = Keyword.get(opts, :dimensions, :all)

    diffs =
      dimension_checks()
      |> Enum.filter(fn {n, _fun} -> dimensions == :all or n in dimensions end)
      |> Enum.flat_map(fn {n, fun} ->
        fun.(reference_schema, candidate_schema)
        |> Enum.map(&"  [dim ##{n}] #{&1}")
      end)

    case diffs do
      [] ->
        :ok

      _ ->
        message =
          "TENANT_TEMPLATE_PARITY reference=#{reference_schema} candidate=#{candidate_schema}\n" <>
            Enum.join(diffs, "\n")

        raise ExUnit.AssertionError, message: message
    end
  end

  # ---------------------------------------------------------------------------
  # ISS-1042 -- pooled-tenant support (`Letflow.TenantFixture.start_pool!/2`)
  #
  # Design: lib/letflow/design/iss1042-pooled-tenant-fixture.md section 2.2 and 4.
  # This module owns the knowledge of what a clone looks like, so the baseline, the
  # probe (row presence + definitional digest), the dirty-only reset and the rebuild
  # live here; the pool worker in `Letflow.TenantFixture.Pool` only orchestrates them.
  #
  # Nothing above this block changes behaviour. `clone_tenant_schema!/1` is reused
  # unchanged by `rebuild_clone_schema!/1`.
  # ---------------------------------------------------------------------------

  # The tables that legitimately hold rows in a pristine clone (GH 2534 7b-2a added
  # script_policy: its singleton row is inserted by its migration). `do_clone/2`
  # steps 7-8 copy them from the live template; a reset restores them the same way.
  @seed_tables ["event_type_registry", "schema_migrations", "script_policy"]

  # REQ-500 / GH #2588 (PR A): the document tables carry BEFORE TRUNCATE triggers (decision
  # 0056 D4), so a reset can never empty them. A clone where any of them is dirty is therefore
  # unprovable and the caller rebuilds the schema, the same as any other drift.
  @immutable_document_tables [
    "document_external_registrations",
    "document_print_overrides",
    "document_sequences",
    "document_types",
    "document_versions",
    "documents"
  ]

  # Bounds for the reset transaction (design 3.5): a test that died holding a lock
  # must make the reset time out (-> unprovable -> rebuild), not hang the module.
  @reset_lock_timeout "3s"
  @reset_statement_timeout "30s"

  # The definitional digest (design 4.2 item 1). One statement over the catalogs of
  # ONE schema ($1) returning `{"<class>:<key>", md5(definition text)}` per definition
  # row. Classes: N schema, T relations (all relkinds), C columns, K constraints,
  # I indexes, G triggers (user triggers: enabled flag + definition; internal FK RI
  # triggers: enabled flag only, ISS-1042 M1(b)), F functions, Q sequences (parameters
  # AND owning column, ISS-1042 M1(a)), P policies, R rules, Y domains/enums/ranges,
  # X extended statistics, H inheritance / partition bounds.
  #
  # The schema's own name is deliberately left in place inside definition text: the
  # baseline and every later probe read the SAME schema, and a rebuilt slot replaces
  # its baseline.
  @definition_sql """
  WITH ns AS (SELECT oid, nspname FROM pg_namespace WHERE nspname = $1),
  defs AS (
    SELECT 'N' AS cls, ns.nspname AS key,
           concat_ws('|', pg_get_userbyid(n.nspowner), coalesce(n.nspacl::text, '~'),
                     coalesce(obj_description(n.oid, 'pg_namespace'), '~')) AS def
    FROM ns JOIN pg_namespace n ON n.oid = ns.oid
    UNION ALL
    SELECT 'T', c.relname,
           concat_ws('|', c.relkind, coalesce(c.reloptions::text, '~'), c.relrowsecurity,
                     c.relforcerowsecurity, c.relpersistence, pg_get_userbyid(c.relowner),
                     coalesce(c.relacl::text, '~'), c.reltablespace, c.relispartition,
                     c.relreplident, c.relam, coalesce(pg_get_partkeydef(c.oid), '~'),
                     coalesce(obj_description(c.oid, 'pg_class'), '~'))
    FROM pg_class c JOIN ns ON ns.oid = c.relnamespace
    UNION ALL
    SELECT 'C', c.relname || '.' || a.attname,
           concat_ws('|', a.attnum, format_type(a.atttypid, a.atttypmod), a.attnotnull,
                     a.attidentity, a.attgenerated, coalesce(a.attstattarget::text, '~'),
                     a.attcollation, a.attstorage, coalesce(a.attacl::text, '~'),
                     coalesce(pg_get_expr(d.adbin, d.adrelid), '~'),
                     coalesce(col_description(c.oid, a.attnum), '~'))
    FROM pg_attribute a
    JOIN pg_class c ON c.oid = a.attrelid
    JOIN ns ON ns.oid = c.relnamespace
    LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
    WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f') AND a.attnum > 0 AND NOT a.attisdropped
    UNION ALL
    SELECT 'K', c.relname || '.' || k.conname,
           concat_ws('|', k.contype, k.convalidated, k.condeferrable, k.condeferred,
                     pg_get_constraintdef(k.oid))
    FROM pg_constraint k
    JOIN pg_class c ON c.oid = k.conrelid
    JOIN ns ON ns.oid = c.relnamespace
    UNION ALL
    SELECT 'I', ic.relname,
           concat_ws('|', i.indisvalid, i.indisready, i.indisclustered,
                     pg_get_indexdef(i.indexrelid))
    FROM pg_index i
    JOIN pg_class ic ON ic.oid = i.indexrelid
    JOIN ns ON ns.oid = ic.relnamespace
    UNION ALL
    SELECT 'G', c.relname || '.' || t.tgname,
           concat_ws('|', t.tgenabled, pg_get_triggerdef(t.oid))
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN ns ON ns.oid = c.relnamespace
    WHERE NOT t.tgisinternal
    UNION ALL
    SELECT 'G', c.relname || '#internal#' || coalesce(k.conname, t.tgname) || '#' || t.tgtype
           || '#' || t.tgfoid::regproc::text,
           concat_ws('|', t.tgenabled, t.tgfoid::regproc::text)
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN ns ON ns.oid = c.relnamespace
    LEFT JOIN pg_constraint k ON k.oid = t.tgconstraint
    WHERE t.tgisinternal
    UNION ALL
    SELECT 'F', p.proname || '(' || oidvectortypes(p.proargtypes) || ')',
           concat_ws('|', pg_get_userbyid(p.proowner), coalesce(p.proacl::text, '~'),
                     md5(pg_get_functiondef(p.oid)))
    FROM pg_proc p JOIN ns ON ns.oid = p.pronamespace
    WHERE p.prokind IN ('f', 'p')
    UNION ALL
    SELECT 'Q', c.relname,
           concat_ws('|', s.seqtypid::regtype, s.seqstart, s.seqincrement, s.seqmax, s.seqmin,
                     s.seqcache, s.seqcycle,
                     coalesce((SELECT string_agg(rc.relname || '.' || ra.attname || ':' || d.deptype::text,
                                                 ',' ORDER BY rc.relname, ra.attname)
                               FROM pg_depend d
                               JOIN pg_class rc ON rc.oid = d.refobjid
                               JOIN pg_attribute ra ON ra.attrelid = d.refobjid AND ra.attnum = d.refobjsubid
                               WHERE d.classid = 'pg_class'::regclass AND d.objid = s.seqrelid
                                 AND d.refclassid = 'pg_class'::regclass
                                 AND d.deptype IN ('a', 'i')), 'NONE'))
    FROM pg_sequence s
    JOIN pg_class c ON c.oid = s.seqrelid
    JOIN ns ON ns.oid = c.relnamespace
    UNION ALL
    SELECT 'P', c.relname || '.' || po.polname,
           concat_ws('|', po.polcmd, po.polpermissive, po.polroles::regrole[]::text,
                     coalesce(pg_get_expr(po.polqual, po.polrelid), '~'),
                     coalesce(pg_get_expr(po.polwithcheck, po.polrelid), '~'))
    FROM pg_policy po
    JOIN pg_class c ON c.oid = po.polrelid
    JOIN ns ON ns.oid = c.relnamespace
    UNION ALL
    SELECT 'R', c.relname || '.' || r.rulename, pg_get_ruledef(r.oid)
    FROM pg_rewrite r
    JOIN pg_class c ON c.oid = r.ev_class
    JOIN ns ON ns.oid = c.relnamespace
    UNION ALL
    SELECT 'Y', ty.typname,
           concat_ws('|', ty.typtype, format_type(ty.typbasetype, ty.typtypmod), ty.typnotnull,
                     coalesce(pg_get_expr(ty.typdefaultbin, 0), '~'),
                     coalesce((SELECT string_agg(e.enumlabel, ',' ORDER BY e.enumsortorder)
                               FROM pg_enum e WHERE e.enumtypid = ty.oid), '~'),
                     coalesce((SELECT string_agg(pg_get_constraintdef(k.oid), ',' ORDER BY k.conname)
                               FROM pg_constraint k WHERE k.contypid = ty.oid), '~'))
    FROM pg_type ty JOIN ns ON ns.oid = ty.typnamespace
    WHERE ty.typtype IN ('d', 'e', 'r', 'm')
    UNION ALL
    SELECT 'X', se.stxname, pg_get_statisticsobjdef(se.oid)
    FROM pg_statistic_ext se JOIN ns ON ns.oid = se.stxnamespace
    UNION ALL
    SELECT 'H', c.relname,
           concat_ws('|', pc.relname, coalesce(pg_get_expr(c.relpartbound, c.oid), '~'))
    FROM pg_inherits h
    JOIN pg_class c ON c.oid = h.inhrelid
    JOIN pg_class pc ON pc.oid = h.inhparent
    JOIN ns ON ns.oid = c.relnamespace
  )
  SELECT cls || ':' || key, md5(string_agg(def, chr(10) ORDER BY def)) FROM defs GROUP BY 1 ORDER BY 1
  """

  @typedoc """
  What a probe reads from one clone schema. `definition_index` (`"<class>:<key>" => md5`) and the
  two `*_ms` fields are additive to design 2.2's shape: the index is what lets a drift report name
  the rows that differ rather than only say "the digest changed".
  """
  @type clone_state :: %{
          tables: [String.t()],
          dirty_tables: [String.t()],
          dirty_sequences: [{table :: String.t() | nil, sequence :: String.t()}],
          seed_digests: %{String.t() => {non_neg_integer(), String.t()}},
          definition_digest: String.t(),
          definition_rows: non_neg_integer(),
          definition_index: %{String.t() => String.t()},
          digest_ms: non_neg_integer(),
          probe_ms: non_neg_integer()
        }

  @typedoc "Captured right after a verified-complete clone; opaque to callers."
  @opaque clone_baseline :: %{schema_name: String.t(), state: clone_state()}

  @type reset_report :: %{
          probe_ms: non_neg_integer(),
          digest_ms: non_neg_integer(),
          truncated: [String.t()],
          closure_added: [String.t()],
          sequences_restarted: [String.t()],
          seeds_restored: [String.t()],
          verify_ms: non_neg_integer(),
          total_ms: non_neg_integer()
        }

  @typedoc "What differs between a probed state and the baseline (all empty == clean)."
  @type clone_diff :: %{
          drift: [String.t()],
          dirty_tables: [String.t()],
          dirty_sequences: [{String.t() | nil, String.t()}],
          seeds_diverged: [String.t()]
        }

  @doc """
  Captures the baseline of a freshly cloned (and completeness-asserted) schema: its table
  set, definitional digest and seed digests. Raises `ArgumentError` if the schema is not
  pristine (a row in a non-seed table or a called sequence), because a baseline taken from
  a dirty schema would bless that dirt as clean.
  """
  @spec capture_clone_baseline!(schema_name :: String.t()) :: clone_baseline()
  def capture_clone_baseline!(schema_name) when is_binary(schema_name) do
    case probe_clone_state(schema_name) do
      {:ok, %{dirty_tables: [], dirty_sequences: []} = state} ->
        %{schema_name: schema_name, state: state}

      {:ok, state} ->
        raise ArgumentError,
              "cannot capture a baseline of #{schema_name}: not pristine " <>
                "(dirty_tables=#{inspect(state.dirty_tables)} " <>
                "dirty_sequences=#{inspect(state.dirty_sequences)})"

      {:error, reason} ->
        raise ArgumentError,
              "cannot capture a baseline of #{schema_name}: #{inspect(reason)}"
    end
  end

  @doc "The table set (relkind r/p, sorted) recorded in `baseline`."
  @spec baseline_tables(clone_baseline()) :: [String.t()]
  def baseline_tables(%{state: %{tables: tables}}), do: tables

  @doc """
  Reads the current state of one clone schema: row presence of every table, called
  sequences, seed digests and the definitional digest. Read-only. The one-argument form
  discovers the table set from the catalog; the two-argument form probes exactly `tables`
  (the pool passes the baseline's set).
  """
  @spec probe_clone_state(schema_name :: String.t()) :: {:ok, clone_state()} | {:error, term()}
  def probe_clone_state(schema_name) do
    probe_clone_state(schema_name, discover_tables(schema_name))
  rescue
    exception -> {:error, exception}
  end

  @spec probe_clone_state(schema_name :: String.t(), tables :: [String.t()]) ::
          {:ok, clone_state()} | {:error, term()}
  def probe_clone_state(schema_name, tables) when is_list(tables) do
    with {:ok, index, digest_ms} <- probe_definitions(schema_name),
         {:ok, data} <- probe_clone_data(schema_name, tables) do
      {:ok,
       Map.merge(data, %{
         tables: Enum.sort(tables),
         definition_digest: digest_of(index),
         definition_rows: map_size(index),
         definition_index: index,
         digest_ms: digest_ms
       })}
    end
  end

  @doc """
  The row-level half of a probe only (design 4.2 items 2-4, "probe P"): which non-seed
  tables hold rows, which sequences have been called (with the table that owns each), and
  the `{count, md5}` of each seed table. One round trip. Used by the pool's final guard.
  """
  @spec probe_clone_data(schema_name :: String.t(), tables :: [String.t()]) ::
          {:ok,
           %{
             dirty_tables: [String.t()],
             dirty_sequences: [{String.t() | nil, String.t()}],
             seed_digests: %{String.t() => {non_neg_integer(), String.t()}},
             probe_ms: non_neg_integer()
           }}
          | {:error, term()}
  def probe_clone_data(schema_name, tables) do
    started = System.monotonic_time(:millisecond)
    quoted_schema = quote_ident(schema_name)

    presence =
      for table <- Enum.sort(tables), table not in @seed_tables do
        "SELECT 'row', #{quote_literal(table)}, NULL::text, NULL::text " <>
          "WHERE EXISTS (SELECT 1 FROM #{quoted_schema}.#{quote_ident(table)})"
      end

    seeds =
      for table <- @seed_tables, table in tables do
        "SELECT 'seed', #{quote_literal(table)}, count(*)::text, " <>
          "md5(coalesce(string_agg(t::text, '|' ORDER BY t::text), '')) " <>
          "FROM #{quoted_schema}.#{quote_ident(table)} t"
      end

    sequences = """
    SELECT 'seq', ps.sequencename,
           (SELECT rc.relname
              FROM pg_class sc
              JOIN pg_namespace sn ON sn.oid = sc.relnamespace AND sn.nspname = ps.schemaname
              JOIN pg_depend d ON d.objid = sc.oid AND d.classid = 'pg_class'::regclass
                              AND d.refclassid = 'pg_class'::regclass AND d.deptype IN ('a', 'i')
              JOIN pg_class rc ON rc.oid = d.refobjid
             WHERE sc.relname = ps.sequencename
             LIMIT 1),
           NULL::text
      FROM pg_sequences ps
     WHERE ps.schemaname = $1 AND ps.last_value IS NOT NULL
    """

    sql = Enum.join(presence ++ seeds ++ [sequences], "\nUNION ALL\n")

    %{rows: rows} = Repo.query!(sql, [schema_name])

    {:ok,
     %{
       dirty_tables: for(["row", table, _, _] <- rows, do: table) |> Enum.sort(),
       dirty_sequences:
         for(["seq", sequence, owner, _] <- rows, do: {owner, sequence}) |> Enum.sort(),
       seed_digests:
         for(["seed", table, count, md5] <- rows, into: %{}) do
           {table, {String.to_integer(count), md5}}
         end,
       probe_ms: System.monotonic_time(:millisecond) - started
     }}
  rescue
    exception -> {:error, exception}
  end

  @doc """
  Compares a probed `clone_state` with `baseline`. Pure. `drift` lists one entry per
  definition row that was added, removed or changed.
  """
  @spec diff_clone_state(map(), clone_baseline()) :: clone_diff()
  def diff_clone_state(state, %{state: base}) do
    drift =
      case Map.get(state, :definition_index) do
        nil -> []
        index -> index_drift(base.definition_index, index)
      end

    seeds_diverged =
      for {table, digest} <- base.seed_digests,
          Map.get(state.seed_digests, table) != digest,
          do: table

    %{
      drift: drift,
      dirty_tables: state.dirty_tables,
      dirty_sequences: state.dirty_sequences,
      seeds_diverged: Enum.sort(seeds_diverged)
    }
  end

  @doc "True when `diff` shows neither drift, dirt nor diverged seeds."
  @spec clean_diff?(clone_diff()) :: boolean()
  def clean_diff?(%{drift: [], dirty_tables: [], dirty_sequences: [], seeds_diverged: []}),
    do: true

  def clean_diff?(_diff), do: false

  @doc """
  Dirty-only reset of one clone schema (design 4.3 steps 2-6).

  Test-only bypass, stated once and deliberately: `audit_entries`, `repository_artifacts` and
  `artifact_versions` carry BEFORE UPDATE / BEFORE DELETE immutability triggers, and there is
  no BEFORE TRUNCATE trigger, so `TRUNCATE` is the one way to empty them. That is acceptable
  only because this runs against throwaway test schemas; the triggers themselves are never
  dropped, disabled or modified here (a test that does so is detected as definition drift and
  the schema is rebuilt, never repaired).

  Steps: probe; if the definitional digest differs from `baseline` return `unprovable`
  BEFORE any DML (drift is never repaired in place); otherwise, in one transaction with
  bounded lock and statement timeouts, `TRUNCATE` exactly the dirty tables plus the tables
  whose foreign keys reference them (explicit closure, **no CASCADE**) `RESTART IDENTITY`,
  restart called sequences that no truncated table owns, re-copy the seed tables from the
  live template, then run `opts[:extra]` (a zero-arity function for state outside this
  schema, e.g. public rows keyed to the tenant) in the SAME transaction; finally probe again
  and require equality with `baseline`.

  Never raises for an unproven result: returns `{:error, {:unprovable, reasons}}` and the
  caller rebuilds.
  """
  @spec reset_clone_schema!(schema_name :: String.t(), clone_baseline(), keyword()) ::
          {:ok, reset_report()} | {:error, {:unprovable, [String.t()]}}
  def reset_clone_schema!(schema_name, baseline, opts \\ []) do
    started = System.monotonic_time(:millisecond)
    extra = Keyword.get(opts, :extra)
    tables = baseline_tables(baseline)

    case probe_clone_state(schema_name, tables) do
      {:error, reason} ->
        {:error, {:unprovable, ["probe_failed: " <> inspect_error(reason)]}}

      {:ok, state} ->
        diff = diff_clone_state(state, baseline)

        immutable_dirt = Enum.filter(diff.dirty_tables, &(&1 in @immutable_document_tables))

        cond do
          diff.drift != [] ->
            {:error, {:unprovable, ["definition_drift" | diff.drift]}}

          immutable_dirt != [] ->
            {:error,
             {:unprovable, Enum.map(immutable_dirt, &"immutable_document_table_dirty #{&1}")}}

          true ->
            do_reset(schema_name, baseline, state, diff, extra, started)
        end
    end
  end

  defp do_reset(schema_name, baseline, state, diff, extra, started) do
    tables = baseline_tables(baseline)
    base = Enum.uniq(diff.dirty_tables ++ diff.seeds_diverged)
    {truncate_set, closure_added} = fk_closure(base, fk_referencing_graph(schema_name), tables)
    seeds_to_restore = Enum.filter(@seed_tables, &(&1 in truncate_set))

    to_restart =
      for {owner, sequence} <- diff.dirty_sequences, owner == nil or owner not in truncate_set do
        sequence
      end

    quoted_schema = quote_ident(schema_name)

    result =
      try do
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL lock_timeout = '#{@reset_lock_timeout}'")
          Repo.query!("SET LOCAL statement_timeout = '#{@reset_statement_timeout}'")

          if truncate_set != [] do
            list = Enum.map_join(truncate_set, ", ", &"#{quoted_schema}.#{quote_ident(&1)}")
            Repo.query!("TRUNCATE #{list} RESTART IDENTITY")
          end

          Enum.each(to_restart, fn sequence ->
            Repo.query!("ALTER SEQUENCE #{quoted_schema}.#{quote_ident(sequence)} RESTART")
          end)

          Enum.each(seeds_to_restore, fn seed ->
            Repo.query!(
              "INSERT INTO #{quoted_schema}.#{quote_ident(seed)} " <>
                "SELECT * FROM #{quote_ident(@template_schema)}.#{quote_ident(seed)}"
            )
          end)

          if is_function(extra, 0), do: extra.()
          :ok
        end)
      rescue
        exception -> {:error, {:reset_failed, exception}}
      end

    case result do
      {:ok, :ok} ->
        verify_reset(schema_name, baseline, state, started, %{
          truncated: truncate_set,
          closure_added: closure_added,
          sequences_restarted: to_restart,
          seeds_restored: seeds_to_restore
        })

      {:error, reason} ->
        {:error, {:unprovable, ["reset_failed: " <> inspect_error(reason)]}}
    end
  end

  defp verify_reset(schema_name, baseline, before, started, parts) do
    verify_started = System.monotonic_time(:millisecond)

    case probe_clone_state(schema_name, baseline_tables(baseline)) do
      {:ok, after_state} ->
        diff = diff_clone_state(after_state, baseline)

        if clean_diff?(diff) do
          now = System.monotonic_time(:millisecond)

          {:ok,
           Map.merge(parts, %{
             probe_ms: before.probe_ms,
             digest_ms: before.digest_ms,
             verify_ms: now - verify_started,
             total_ms: now - started
           })}
        else
          {:error, {:unprovable, ["verify_failed" | describe_diff(diff)]}}
        end

      {:error, reason} ->
        {:error, {:unprovable, ["verify_probe_failed: " <> inspect_error(reason)]}}
    end
  end

  @doc """
  Drops the tenant's clone schema, deletes its `Registration` row, then runs the existing
  `clone_tenant_schema!/1` (which inserts a NEW `Registration` row). Does not assert
  completeness, capture a baseline or snapshot anything: those are the pool worker's job.
  """
  @spec rebuild_clone_schema!(source_tenant_id :: Ecto.UUID.t()) ::
          {:ok, schema_name :: String.t()} | {:error, {:clone_failed, term()}}
  def rebuild_clone_schema!(source_tenant_id) do
    case TenantProvisioning.schema_name_for_tenant(source_tenant_id) do
      {:ok, schema_name} ->
        Repo.query!("DROP SCHEMA IF EXISTS #{quote_ident(schema_name)} CASCADE")
        Repo.delete_all(from(r in Registration, where: r.tenant_id == ^source_tenant_id))
        clone_tenant_schema!(source_tenant_id)

      {:error, reason} ->
        {:error, {:clone_failed, reason}}
    end
  rescue
    exception -> {:error, {:clone_failed, exception}}
  end

  @doc "Human-readable one-line-per-finding description of a non-clean `clone_diff`."
  @spec describe_diff(clone_diff()) :: [String.t()]
  def describe_diff(diff) do
    Enum.map(diff.drift, &"definition_drift #{&1}") ++
      Enum.map(diff.dirty_tables, &"dirty_table #{&1}") ++
      Enum.map(diff.dirty_sequences, fn {owner, seq} -> "dirty_sequence #{owner}.#{seq}" end) ++
      Enum.map(diff.seeds_diverged, &"seed_diverged #{&1}")
  end

  defp probe_definitions(schema_name) do
    started = System.monotonic_time(:millisecond)
    %{rows: rows} = Repo.query!(@definition_sql, [schema_name])
    index = Map.new(rows, fn [key, md5] -> {key, md5} end)
    {:ok, index, System.monotonic_time(:millisecond) - started}
  rescue
    exception -> {:error, exception}
  end

  defp digest_of(index) do
    index
    |> Enum.sort()
    |> Enum.map_join("\n", fn {key, md5} -> key <> "=" <> md5 end)
    |> then(&Base.encode16(:crypto.hash(:md5, &1), case: :lower))
  end

  defp index_drift(base, current) do
    changed =
      for {key, md5} <- current, Map.get(base, key) != md5 do
        if Map.has_key?(base, key), do: "changed #{key}", else: "added #{key}"
      end

    removed = for key <- Map.keys(base), not Map.has_key?(current, key), do: "removed #{key}"
    Enum.sort(changed ++ removed)
  end

  defp discover_tables(schema_name) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = $1 AND c.relkind IN ('r', 'p') ORDER BY 1
        """,
        [schema_name]
      )

    Enum.map(rows, fn [table] -> table end)
  end

  # %{referenced_table => [referencing tables]} for FKs wholly inside the clone schema.
  defp fk_referencing_graph(schema_name) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT cr.relname, pr.relname
        FROM pg_constraint k
        JOIN pg_class cr ON cr.oid = k.conrelid
        JOIN pg_class pr ON pr.oid = k.confrelid
        JOIN pg_namespace n ON n.oid = cr.relnamespace
        WHERE k.contype = 'f' AND n.nspname = $1 AND pr.relnamespace = n.oid
        """,
        [schema_name]
      )

    Enum.reduce(rows, %{}, fn [referencing, referenced], acc ->
      Map.update(acc, referenced, [referencing], &[referencing | &1])
    end)
  end

  # `base` closed under "tables whose FK references a member". Returns {sorted set,
  # members added only for closure}. Restricted to `tables` (the clone's own table set).
  defp fk_closure(base, graph, tables) do
    allowed = MapSet.new(tables)
    closed = do_closure(base, MapSet.new(base), graph, allowed)
    set = closed |> MapSet.to_list() |> Enum.sort()
    {set, set -- base}
  end

  defp do_closure([], seen, _graph, _allowed), do: seen

  defp do_closure([table | rest], seen, graph, allowed) do
    new =
      graph
      |> Map.get(table, [])
      |> Enum.filter(&(MapSet.member?(allowed, &1) and not MapSet.member?(seen, &1)))
      |> Enum.uniq()

    do_closure(rest ++ new, Enum.reduce(new, seen, &MapSet.put(&2, &1)), graph, allowed)
  end

  defp inspect_error({:reset_failed, %{__exception__: true} = exception}),
    do: Exception.message(exception)

  defp inspect_error(%{__exception__: true} = exception), do: Exception.message(exception)
  defp inspect_error(other), do: inspect(other)

  # Identifiers here come from the catalog or from `schema_name_for_tenant/1`, never from
  # tenant or user input; quoting (with embedded-quote doubling) is belt and braces (INV-7).
  defp quote_ident(identifier) when is_binary(identifier),
    do: ~s("#{String.replace(identifier, ~s("), ~s(""))}")

  defp quote_literal(value) when is_binary(value), do: "'#{String.replace(value, "'", "''")}'"

  # ---------------------------------------------------------------------------
  # Template build (design §2.3, ensure_template!/0's build sequence)
  # ---------------------------------------------------------------------------

  # ISS-0842: three-state check replacing the binary template_built_in_db?/0
  # fast-path inside the advisory lock. Queries the schema comment to detect
  # whether the template exists, is current, or is stale (built from a
  # different tenant migration set than the one currently compiled).
  #
  # :missing  — no schema named "tenant_template" in pg_namespace.
  # :stale    — schema exists but its comment is absent or does not match
  #             the current migration fingerprint (e.g. after pulling a new
  #             migration, in a reused test DB).
  # :current  — schema exists and its comment matches the current fingerprint.
  #
  # INV-8 is unaffected: template_db_state/0 is read-only. The rename-into-
  # place invariant is still only produced by build_template!/0's step 5.
  #
  # design §0.7/INV-8: because build_template!/0 now builds the WHOLE
  # sequence under a randomized staging schema and only renames it to
  # "tenant_template" as the LAST step (after the self-check has already
  # passed against the staging name), the literal name "tenant_template"
  # can never be observed half-built -- its existence under that exact name
  # IS the completeness proof. So this check does not need to re-run the
  # self-check defensively "just in case" the schema exists but is broken:
  # that state is structurally impossible to produce. A bare existence/comment
  # check (:missing vs. :stale vs. :current, above) is therefore correct, not
  # merely convenient.
  #
  # (ISS-0853: this comment previously lived on a now-deleted sibling function,
  # template_built_in_db?/0 -- a binary existence check ISS-0842 replaced with
  # this three-state one but initially left defined, unused, purely to keep
  # this rationale in context. That left an unused-function compile warning
  # fatal under `mix compile --warnings-as-errors`; the function added nothing
  # this call site didn't already retire, so it was deleted and the rationale
  # moved here, onto the function that actually performs the check it
  # describes.)
  defp template_db_state do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT obj_description(n.oid, 'pg_namespace')
        FROM pg_namespace n
        WHERE n.nspname = $1
        """,
        [@template_schema]
      )

    case rows do
      [] ->
        :missing

      [[comment]] ->
        expected = migration_fingerprint_comment()

        if comment == expected, do: :current, else: :stale
    end
  end

  # Computes the expected fingerprint comment string for the current compiled
  # tenant migration set. Deterministic for a given compilation: the version
  # list comes from the manifest constant compiled into TenantProvisioning, so
  # it is stable within one BEAM VM and changes only when migrations are added
  # or removed (which requires a recompile, hence a new BEAM VM).
  defp migration_fingerprint_comment do
    fingerprint =
      TenantProvisioning.tenant_scoped_migrations()
      |> Enum.map(fn {version, _module} -> version end)
      |> Enum.sort()
      |> Enum.join(",")
      |> Kernel.<>("|" <> inspect(TenantProvisioning.platform_event_type_seed_versions()))
      |> then(&:crypto.hash(:md5, &1))
      |> Base.encode16(case: :lower)

    @fingerprint_comment_prefix <> fingerprint
  end

  # design §0.7/§2.3 steps 0-6 (rework 4): ATOMIC BUILD-THEN-RENAME-INTO-PLACE.
  # The entire build (schema, migrations, self-check) runs under a fresh,
  # RANDOMIZED STAGING schema name -- never the literal "tenant_template" --
  # and only the LAST statement, `ALTER SCHEMA ... RENAME TO "tenant_template"`,
  # makes the well-known name exist at all. This is what makes INV-8 true: a
  # crash, exception, or interruption at any point before the rename leaves
  # behind only inert, randomly-named debris, never a half-built schema
  # sitting under the name every other function in this module looks up. No
  # detect-and-repair path is needed for this failure mode, because the
  # failure mode (a same-named, incomplete "tenant_template") is now
  # structurally impossible to produce -- see design §0.7 for the full
  # comparison against the rejected detect-and-repair alternative.
  #
  # This also subsumes ISSUE-FIXER's MINOR finding (step-05 handoff): the
  # throwaway Registration row's schema_name is now the FRESH staging name
  # on every attempt (never a reused literal), so a stale row surviving a
  # prior crashed attempt can never collide with a new attempt's insert --
  # no upsert is needed, not because upserts are unnecessary in general, but
  # because collision is structurally impossible once each attempt's own
  # schema_name value is unique by construction.
  #
  # Reuses design OQ-1 option (b) exactly as before (build via the REAL,
  # unmodified replay_migrations/2 against a throwaway Tenant/Registration
  # row targeting the staging schema, not tenant_template.ex's own
  # provision_tenant_schema/1 call, which would issue a redundant CREATE
  # SCHEMA IF NOT EXISTS) -- only the schema name each step targets has
  # changed, not the underlying mechanism.
  defp build_template! do
    staging_schema = generate_staging_schema_name()

    # OQ-7 / SECURITY-REVIEWER re-gate MAJOR (process hygiene, not a security
    # exposure): every path out of the build between CREATE SCHEMA and the
    # step-5 rename must drop the staging schema, or a failed build leaks a
    # randomly-named, fully-populated schema that nothing will ever clean up.
    # Unlike the pre-INV-8 failure mode this replaces, such debris does NOT
    # wedge later runs (the next attempt mints a fresh random name), but it
    # accumulates silently across runs -- and leftover state of exactly this
    # class already cost this run hours of misdiagnosis, so it is worth
    # closing rather than deferring.
    #
    # The rescue re-raises the ORIGINAL exception after cleanup: the build's
    # own failure is the information the caller needs, and a cleanup failure
    # must never mask it. Cleanup is itself best-effort for the same reason.
    try do
      do_build_template!(staging_schema)
    rescue
      exception ->
        try do
          Repo.query!(~s(DROP SCHEMA IF EXISTS "#{staging_schema}" CASCADE))
        rescue
          _cleanup_failure -> :ok
        end

        reraise(exception, __STACKTRACE__)
    end
  end

  defp do_build_template!(staging_schema) do
    # Step 1: no IF NOT EXISTS -- a freshly-randomized name colliding with an
    # existing schema would itself indicate a random-name-generation bug, not
    # a legitimate re-attempt case (design §2.3 step 1).
    Repo.query!(~s(CREATE SCHEMA "#{staging_schema}"))

    throwaway_tenant_id = insert_throwaway_tenant_and_registration!(staging_schema)

    # CONNECTION-BOUNDARY FIX (ORCH, preserved from the pre-rework-4
    # implementation). replay_migrations/2 delegates to Ecto.Migrator.run/4,
    # which CHECKS OUT ITS OWN CONNECTION rather than using this one. Under a
    # partitioned run (MIX_TEST_PARTITION set, i.e. scripts/test_parallel.sh)
    # that connection is still sandbox-owned unless the whole build runs
    # unboxed together (see ensure_template!/0's caller-side wrap) -- see
    # that function's own comment for the full symptom/fix history. Step 2.
    case TenantProvisioning.replay_migrations(throwaway_tenant_id) do
      {:ok, _applied_versions} ->
        clear_migrations_applied_flag!(throwaway_tenant_id)
        :ok

      {:error, reason} ->
        raise ExUnit.AssertionError,
          message: "TENANT_TEMPLATE_BUILD_FAILED replay_migrations/2 returned #{inspect(reason)}"
    end

    # Step 3: self-check runs against the STAGING schema -- if it raises,
    # execution never reaches step 5's rename, and "tenant_template" is never
    # observed to exist at all (design §0.7, INV-8).
    template_self_check!(staging_schema)

    # Step 4: bookkeeping-row cleanup, targeting the staging schema's own
    # throwaway row (mirrors the pre-rework-4 delete_throwaway_tenant_and_registration!/1
    # call, unchanged in substance).
    delete_throwaway_tenant_and_registration!(throwaway_tenant_id)

    # Step 5: THE ATOMIC COMMIT POINT. A single catalog-level statement, no
    # table/index rebuild -- only after this succeeds does "tenant_template"
    # exist under its well-known name.
    Repo.query!(~s(ALTER SCHEMA "#{staging_schema}" RENAME TO "#{@template_schema}"))

    # Step 6 (ISS-0842): stamp the fingerprint as a schema comment. Runs AFTER
    # the rename so the comment is set on "tenant_template" (not the staging
    # name). If this fails, the template is left without a comment, which
    # template_db_state/0 treats as :stale, triggering a rebuild on the next
    # call — never a silent partial-build.
    fingerprint = migration_fingerprint_comment()
    Repo.query!(~s(COMMENT ON SCHEMA "#{@template_schema}" IS '#{fingerprint}'))

    :ok
  end

  # design §2.3 step 0: any collision-resistant per-attempt token: uniqueness
  # per attempt is the requirement, not cryptographic strength.
  defp generate_staging_schema_name do
    suffix = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    "tenant_template_build_" <> suffix
  end

  defp insert_throwaway_tenant_and_registration!(schema_name) do
    tenant =
      %Tenant{}
      |> Tenant.create_changeset(
        %{
          slug: Letflow.TenantSlugFixture.unique_slug("tenant-template-build"),
          display_name: "Tenant Template Build (throwaway)"
        },
        :disabled
      )
      |> Repo.insert!()

    # Registration.changeset/2's validate_format/3 deliberately REJECTS every
    # schema_name this function is ever called with -- the randomized staging
    # name (design §0.7) and the refcheck's own randomized reference name
    # (ISS-0468, same generate_staging_schema_name/0 helper) alike -- it only
    # accepts the "tenant_" <> 32-hex shape schema_name_for_tenant/1 produces.
    # That rejection is INV-1 working exactly as designed (design §2.2): no
    # code path that goes through the normal changeset can ever register a
    # synthetic build/refcheck schema as if it were a real tenant schema.
    # This insert deliberately bypasses that changeset via Repo.insert_all/3
    # with a literal map (not Registration.changeset/2), because this row is
    # required only transiently, to satisfy replay_migrations/2's own
    # Registration-row lookup precondition, and is deleted again by
    # delete_throwaway_tenant_and_registration!/1 before the caller returns
    # -- see design §2.2's OQ-1 option (b), reused here (§3.4 use site 1) for
    # the independent reference-schema build too. No Registration row naming
    # any synthetic schema ever survives outside this one function's own
    # caller. §0.7's MINOR fix: since schema_name is now the FRESH,
    # per-attempt staging name rather than a reused literal, this insert can
    # never collide with a stale row from a prior crashed attempt -- no
    # upsert needed, by construction.
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.insert_all(Registration, [
      %{
        id: Ecto.UUID.generate(),
        tenant_id: tenant.id,
        schema_name: schema_name,
        provisioned_at: now
      }
    ])

    tenant.id
  end

  defp delete_throwaway_tenant_and_registration!(tenant_id) do
    Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant_id))
    Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))
  end

  # ISS-0879 design §2.2: mirror image of
  # Letflow.TenantProvisioning's private mark_migrations_applied/1
  # (tenant_provisioning.ex:797-802) -- nulls the throwaway row's
  # migrations_applied_at instead of stamping it, immediately after
  # replay_migrations/2 returns success and before any other work runs in
  # that branch. Narrows (does not fully close, §2.3) the window during
  # which provisioned_tenant_schemas/0's platform-wide,
  # `where: not is_nil(r.migrations_applied_at)` fanout query could observe
  # this throwaway row as a real, provisioned tenant schema.
  defp clear_migrations_applied_flag!(tenant_id) do
    from(r in Registration, where: r.tenant_id == ^tenant_id)
    |> Repo.update_all(set: [migrations_applied_at: nil])

    :ok
  end

  # design §2.3 step 3: assert the STAGING schema's own table set and
  # migration version set are complete, THEN (opt-in) run the full parity
  # self-check (design §3.4 use site 1) against a genuinely independent
  # replay_migrations/2 build. Raise immediately rather than renaming an
  # incomplete build into place (design §5, §0.7 -- this is what makes
  # INV-8 true: the rename in build_template!/0 only ever runs AFTER this
  # function returns :ok).
  #
  # `schema_name` is the schema to check -- the STAGING schema during a
  # normal build (design §0.7's "Naming detail": every §2.3 step before the
  # rename targets the staging name, never the literal "tenant_template").
  #
  # The two cheap MapSet diffs below (table-set, migration-version-set) are
  # NOT the parity self-check -- they are a fast pre-check that fails loudly
  # before paying for a whole second migration replay if the build is
  # obviously broken. The actual design §3.4 use-site-1 check is the
  # assert_clone_parity!/2 call at the end of this function, against a
  # SECOND schema built independently via the real, unmodified
  # replay_migrations/2 (not derived from or compared against itself).
  defp template_self_check!(schema_name) do
    expected = MapSet.new(Letflow.TenantFixture.expected_tenant_tables())

    # REQ-376: the STAGING schema is built via a genuine replay_migrations/2
    # (do_build_template!/1, step 2, above), so it carries real
    # events_default/events_archive_default/*_pre_partition_20260922/
    # events_y<year>m<month> physical tables that
    # Letflow.TenantFixture.expected_tenant_tables/0 deliberately does not
    # enumerate (see that function's own doc). Filtered out of the "extra"
    # side only -- see Letflow.TenantFixture.req376_partition_management_table?/1's
    # own doc for why these specifically cannot be hard-coded the way every
    # other table is. The "missing" side is unaffected: none of these were
    # ever expected, so they can never appear there.
    actual =
      schema_name
      |> tables_in()
      |> Enum.reject(&Letflow.TenantFixture.req376_partition_management_table?/1)
      |> MapSet.new()

    missing = MapSet.difference(expected, actual)
    extra = MapSet.difference(actual, expected)

    if MapSet.size(missing) > 0 or MapSet.size(extra) > 0 do
      raise ExUnit.AssertionError,
        message:
          "TENANT_TEMPLATE_SELF_CHECK_FAILED table set mismatch: " <>
            "missing=#{inspect(MapSet.to_list(missing))} extra=#{inspect(MapSet.to_list(extra))}"
    end

    manifest_versions =
      TenantProvisioning.tenant_scoped_migrations()
      |> Enum.map(fn {version, _module} -> version end)
      |> MapSet.new()

    applied_versions = MapSet.new(applied_versions_in(schema_name))

    versions_missing = MapSet.difference(manifest_versions, applied_versions)

    if MapSet.size(versions_missing) > 0 do
      raise ExUnit.AssertionError,
        message:
          "TENANT_TEMPLATE_SELF_CHECK_FAILED versions_missing=" <>
            inspect(MapSet.to_list(versions_missing))
    end

    # COST PLACEMENT (ORCH, after measuring a real full-suite run): this
    # reference check builds a SECOND complete schema by replaying all 53
    # migrations via the real replay_migrations/2. Running it on every
    # template build means once per PARTITION -- and scripts/test_parallel.sh
    # runs up to 16 partitions with TEST_POOL_SIZE=5. Measured on this branch
    # with it unconditionally on: 393 failures out of 3204, dominated by
    # DBConnection.ConnectionError and TENANT_TEMPLATE_BUILD_FAILED, because
    # every partition doubled its provisioning work at exactly the moment all
    # of them were starting up and exhausted the connection pool. The check
    # itself is correct and valuable -- it is what proves the TEMPLATE is
    # faithful to a genuine migration build -- but paying for it once per
    # partition is not affordable.
    #
    # So it is opt-in, defaulting OFF. It still runs for real in
    # test/support/tenant_template_test.exs, which exercises it explicitly,
    # and can be turned on suite-wide with LETFLOW_TEMPLATE_REFCHECK=1 when
    # someone wants the stronger guarantee and can afford the connections.
    if System.get_env("LETFLOW_TEMPLATE_REFCHECK") == "1" do
      assert_template_parity_against_independent_reference!(schema_name)
    end

    :ok
  end

  # design §3.4 use site 1: build a SECOND schema via the real, unmodified
  # replay_migrations/2 (a genuine migration-built reference, structurally
  # independent of the template's own build -- its own throwaway
  # Tenant/Registration row, its own schema) and compare the template against
  # it across dimensions #1-6 and #8-13 (NOT #7 -- design §3.4 item 1's own
  # text: a fresh replay and the template's own build both seed
  # event_type_registry identically by construction, so #7's row-for-row
  # comparison there is moot, not skipped for cost reasons). Runs ONCE per
  # template build (§4.2), not once per clone -- amortized across every test
  # in the run. Raises (via assert_clone_parity!/2, uncaught here) rather
  # than serving clones from an unproven template -- design §5's no-silent-
  # fallback rule.
  @doc """
  Builds an independent, genuinely migration-built reference schema and
  asserts the template matches it.

  Public so `test/support/tenant_template_test.exs` can exercise it directly.
  It is deliberately NOT on `ensure_template!/0`'s default path -- see the
  cost-placement comment there -- because paying for a second full
  53-migration replay once per partition exhausts the connection pool under
  `scripts/test_parallel.sh`. Raises on divergence; returns `:ok` otherwise.
  """
  @spec assert_template_parity_against_independent_reference!() :: :ok
  def assert_template_parity_against_independent_reference!() do
    assert_template_parity_against_independent_reference!(@template_schema)
  end

  # `candidate_schema` is the schema under test -- @template_schema for the
  # public 0-arity API's own use (comparing the REAL, already-renamed
  # template), or the STAGING schema when called from template_self_check!/1
  # during a build (§0.7 -- the rename to "tenant_template" has not
  # happened yet at that point, so the candidate is still under its
  # randomized staging name).
  defp assert_template_parity_against_independent_reference!(candidate_schema) do
    reference_schema = generate_staging_schema_name()

    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{reference_schema}" CASCADE))
    Repo.query!(~s(CREATE SCHEMA "#{reference_schema}"))

    reference_tenant_id = insert_throwaway_tenant_and_registration!(reference_schema)

    try do
      case TenantProvisioning.replay_migrations(reference_tenant_id) do
        {:ok, _applied_versions} ->
          clear_migrations_applied_flag!(reference_tenant_id)
          :ok

        {:error, reason} ->
          raise ExUnit.AssertionError,
            message:
              "TENANT_TEMPLATE_SELF_CHECK_FAILED reference build via replay_migrations/2 " <>
                "returned #{inspect(reason)}"
      end

      assert_clone_parity!(reference_schema, candidate_schema,
        dimensions: [1, 2, 3, 4, 5, 6, 8, 9, 10, 11, 12, 13]
      )
    after
      delete_throwaway_tenant_and_registration!(reference_tenant_id)
      Repo.query!(~s(DROP SCHEMA IF EXISTS "#{reference_schema}" CASCADE))
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Clone (design §2.3 steps 1-8)
  # ---------------------------------------------------------------------------

  # ISS-0578 design §3.1: bounded retry-with-backoff wrapper around
  # do_clone/2's whole clone transaction. do_clone/2 itself is unchanged --
  # this function only inspects the outer {:error, {:clone_failed, reason}}
  # tuple do_clone/2 already normalizes every failure mode down to (its own
  # rescue / Repo.transaction/1-error-branch, `:636-642` area), and only ever
  # retries when `reason` is a %Postgrex.Error{}/%DBConnection.ConnectionError{}
  # struct (design §1.3 -- struct/module match, never a message-substring
  # match). Any other error, or the success case, returns immediately with no
  # cleanup and no added latency (design INV-1/INV-2).
  @spec do_clone_with_retry(source_tenant_id :: Ecto.UUID.t(), clone_schema :: String.t()) ::
          {:ok, schema_name :: String.t()}
          | {:error, {:clone_failed, term()}}
  defp do_clone_with_retry(source_tenant_id, clone_schema) do
    do_clone_with_retry(source_tenant_id, clone_schema, 1)
  end

  defp do_clone_with_retry(source_tenant_id, clone_schema, attempt) do
    case do_clone(source_tenant_id, clone_schema) do
      {:ok, schema_name} ->
        {:ok, schema_name}

      {:error, {:clone_failed, reason}} = error ->
        if retryable?(reason) and attempt < @clone_max_attempts do
          cleanup_before_retry(clone_schema)
          Process.sleep(@clone_retry_backoff_ms)
          do_clone_with_retry(source_tenant_id, clone_schema, attempt + 1)
        else
          error
        end
    end
  end

  # design §1.3: match by exception struct/module alone, never by
  # Exception.message/1 text.
  defp retryable?(%Postgrex.Error{}), do: true
  defp retryable?(%DBConnection.ConnectionError{}), do: true
  defp retryable?(_other), do: false

  # design §2.1/§2.2: plain top-level Repo.query!/1 call, outside any
  # Repo.transaction/1 block, against the failed attempt's own deterministic
  # clone_schema name -- best-effort, single rescue-and-discard, no nested
  # retry (matches build_template!/0's own cleanup shape, `:304-307`).
  defp cleanup_before_retry(clone_schema) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{clone_schema}" CASCADE))
  rescue
    _cleanup_failure -> :ok
  end

  defp do_clone(source_tenant_id, clone_schema) do
    Repo.transaction(fn ->
      # Step 2: no IF NOT EXISTS -- a collision means a caller reused a
      # tenant_id that already has a live schema, a caller bug, not
      # something to paper over (design §2.3 step 2).
      Repo.query!(~s(CREATE SCHEMA "#{clone_schema}"))

      tables = Letflow.TenantFixture.expected_tenant_tables() |> Enum.sort()

      # Step 3: CREATE TABLE (LIKE ... INCLUDING ALL) per table, deterministic
      # lexical order.
      Enum.each(tables, fn table ->
        Repo.query!(
          ~s|CREATE TABLE "#{clone_schema}"."#{table}" (LIKE "#{@template_schema}"."#{table}" INCLUDING ALL)|
        )
      end)

      # Step 3.5: index/constraint rename to template names -- REWORK 4
      # ADDITION, mandatory (design §0.6/§2.3 step 3.5, INV-7). LIKE ...
      # INCLUDING ALL auto-renames every non-primary-key index, and
      # Ecto.Changeset.unique_constraint/3 (and foreign_key_constraint/3,
      # check_constraint/3) match a Postgres constraint violation back to a
      # changeset field by NAME -- a structurally-correct but differently-
      # named index is invisible to that error-mapping layer, so
      # Repo.insert/1 lets a raw Ecto.ConstraintError propagate instead of
      # returning {:error, changeset}. Must run BEFORE step 4 (FK re-add):
      # no ordering dependency between them (they touch different catalog
      # objects), but the design places renaming first since it has no
      # dependency on anything after it either.
      rename_indexes_to_template_names!(clone_schema, tables)

      # Step 4: foreign-key re-add, with the TEMPLATE schema's own qualifier
      # textually rewritten to the CLONE schema's qualifier throughout the
      # constraint definition (design §0.1 finding 1 -- NOT optional).
      readd_foreign_keys!(clone_schema)

      # Step 5: sequence re-creation, default repoint, OWNED BY, starting at 1.
      recreate_sequences!(clone_schema)

      # Step 6: trigger and trigger-function re-add (design §2.3 step 6,
      # rework 3 addition -- mandatory, not optional. LIKE ... INCLUDING ALL
      # does NOT copy triggers; five real triggers backed by three real
      # functions currently enforce audit-log/artifact-repository
      # IMMUTABILITY -- a security property, not a cosmetic one). ALL
      # functions before ANY trigger -- CREATE TRIGGER resolves its EXECUTE
      # FUNCTION target at creation time.
      readd_triggers_and_functions!(clone_schema)

      # Step 7: seed-data copy (event_type_registry).
      Repo.query!(
        ~s(INSERT INTO "#{clone_schema}".event_type_registry SELECT * FROM "#{@template_schema}".event_type_registry)
      )

      # Step 7b (GH 2534 7b-2a): the script_policy singleton row, which its migration inserts
      # (a missing row reads as "kill switch on", design gh2534-7b2a-script-policy.md P7).
      Repo.query!(
        ~s(INSERT INTO "#{clone_schema}".script_policy SELECT * FROM "#{@template_schema}".script_policy)
      )

      # Step 8: schema_migrations row copy. schema_migrations itself is the
      # migrator's own bookkeeping table (deliberately excluded from
      # expected_tenant_tables/0's list, see that module attribute's own
      # comment) and is never created by the per-table LIKE loop above, so it
      # is cloned here explicitly, immediately before the row copy that needs
      # it to exist.
      Repo.query!(
        ~s|CREATE TABLE "#{clone_schema}".schema_migrations (LIKE "#{@template_schema}".schema_migrations INCLUDING ALL)|
      )

      Repo.query!(
        ~s(INSERT INTO "#{clone_schema}".schema_migrations SELECT * FROM "#{@template_schema}".schema_migrations)
      )

      # Step 9: the caller's Registration row, exactly as
      # provision_tenant_schema/1 would have produced (plain Repo.insert!, not
      # a call to provision_tenant_schema/1 itself -- design §2.3 step 8).
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      %Registration{}
      |> Registration.changeset(%{
        tenant_id: source_tenant_id,
        schema_name: clone_schema,
        migrations_applied_at: now
      })
      |> Repo.insert!()

      clone_schema
    end)
    |> case do
      {:ok, ^clone_schema} -> {:ok, clone_schema}
      {:error, reason} -> {:error, {:clone_failed, reason}}
    end
  rescue
    exception -> {:error, {:clone_failed, exception}}
  end

  # design §0.6/§2.3 step 3.5, INV-7. Pairs each clone index to its template
  # counterpart STRUCTURALLY (name-blind -- reuses structural_indexdef/1 and
  # the single-schema normalize/2 already established for dimension #4, per
  # the design's own instruction not to reinvent the pairing technique), then
  # ALTER INDEX ... RENAME TO for every pair whose auto-generated clone name
  # differs from the template's own name. A coincidentally-already-matching
  # pair (in practice, at most one per table: the primary key, whose clone
  # name regenerates identically to the template's per §0.6.1) is left alone
  # -- renaming a name to itself is wasteful and, per the coordinator's own
  # note, may be an error on some Postgres versions for a no-op rename.
  #
  # Per §0.6.2, a single ALTER INDEX ... RENAME on a constraint-backed index
  # atomically renames the owning pg_constraint row too -- no separate
  # ALTER TABLE ... RENAME CONSTRAINT is issued or needed.
  #
  # Discovery is batched into TWO round trips total (one per schema), not one
  # per table -- the same round-trip-count lever ISS-0427 itself exists to
  # pull, applied here for the same reason recreate_sequences!/1's own
  # per-column discovery was batched: a per-table query for ~39 tables would
  # add ~78 extra round trips (plus the ~60-100 rename statements themselves)
  # on top of everything else, materially eating the clone/replay speedup on
  # a host with real per-round-trip latency -- measured directly: the
  # per-table form cost this mechanism an extra ~100-150ms per clone,
  # dropping the ratio from ~2.0x to ~1.4x median before this fix.
  defp rename_indexes_to_template_names!(clone_schema, tables) do
    template_by_table = index_name_defs_by_table(@template_schema)
    clone_by_table = index_name_defs_by_table(clone_schema)

    Enum.each(tables, fn table ->
      template_indexes = Map.get(template_by_table, table, [])
      clone_indexes = Map.get(clone_by_table, table, [])

      # Structural pairing: group each side by its name-stripped, own-schema-
      # normalized indexdef. §0.6.3's probe confirmed this yields an
      # unambiguous 1:1 correspondence on the real schema -- every normalized
      # definition value appears exactly once per side.
      template_by_def = Map.new(template_indexes, fn {name, def} -> {def, name} end)

      Enum.each(clone_indexes, fn {clone_name, def} ->
        case Map.fetch(template_by_def, def) do
          {:ok, ^clone_name} ->
            # Names already match (the primary-key coincidence, §0.6.1) --
            # no-op, do not issue a rename-to-self.
            :ok

          {:ok, template_name} ->
            Repo.query!(
              ~s(ALTER INDEX "#{clone_schema}"."#{clone_name}" RENAME TO "#{template_name}")
            )

          :error ->
            # No structural counterpart found on the template side for this
            # table -- cannot happen for a genuine LIKE-produced clone (every
            # clone index is a copy of a template index by construction), so
            # this would indicate a real bug rather than an expected case;
            # left unhandled deliberately so it surfaces as a raised
            # KeyError-shaped failure rather than being silently skipped.
            raise ExUnit.AssertionError,
              message:
                "TENANT_TEMPLATE_CLONE_FAILED no template index found matching clone index " <>
                  "#{clone_name} on table=#{table} (normalized def=#{inspect(def)})"
        end
      end)
    end)
  end

  # design §3.2 dimension #4(b)'s own pairing helper (check_index_names/2)
  # still calls the per-table index_name_defs/2 below -- kept separate from
  # this batched form because the parity check runs across common_tables
  # derived independently and is not on the hot provisioning path this
  # optimization targets (it runs once per template build / once per
  # dedicated parity test, not once per clone).
  defp index_name_defs_by_table(schema_name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT tablename, indexname, indexdef FROM pg_indexes WHERE schemaname = $1",
        [schema_name]
      )

    Enum.group_by(
      rows,
      fn [table, _name, _def] -> table end,
      fn [_table, name, def_sql] ->
        {name, structural_indexdef(normalize(def_sql, schema_name))}
      end
    )
  end

  defp index_name_defs(schema_name, table_name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = $1 AND tablename = $2",
        [schema_name, table_name]
      )

    Enum.map(rows, fn [name, def_sql] ->
      {name, structural_indexdef(normalize(def_sql, schema_name))}
    end)
  end

  # design §0.1 finding 1: pg_get_constraintdef emits TEMPLATE-qualified
  # references. The template schema's own qualifier is textually replaced by
  # the clone schema's qualifier throughout the definition string BEFORE
  # execution -- skipping this reproduces the FK object but points it at the
  # template's own tables.
  #
  # REQ-376 addition: `AND con.conparentid = 0` excludes Postgres's own
  # INTERNAL per-partition child constraints. A foreign key that references a
  # PARTITIONED table (event_payload_store -> events, since REQ-376) is
  # represented in pg_constraint as one top-level constraint PLUS one
  # additional child constraint per partition of the REFERENCED table
  # (conparentid pointing back at the top-level row) -- an undocumented-in-
  # application-terms Postgres implementation detail for validating the FK
  # against each partition individually, not a second logical FK. Without
  # this filter, this query returned one row per events_y<year>m<month>/
  # events_default partition in addition to the real
  # event_payload_store_event_id_fkey row, and blindly replaying every one of
  # them here failed outright: a CLONED tenant's events table is deliberately
  # plain/unpartitioned (this module's own do_clone/2 uses `CREATE TABLE
  # (LIKE ... INCLUDING ALL)`, which does not copy PARTITION BY -- see
  # Letflow.TenantFixture.req376_partition_management_table?/1's doc), so it
  # has no events_default/events_y... children for those child constraints to
  # reference ("relation events_default does not exist"). `conparentid = 0`
  # is the standard Postgres idiom for "this constraint has no parent
  # constraint" (pg_constraint.conparentid is 0, never NULL, when absent).
  defp readd_foreign_keys!(clone_schema) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT rel.relname AS table_name, con.conname, pg_get_constraintdef(con.oid) AS def
        FROM pg_constraint con
        JOIN pg_class rel ON rel.oid = con.conrelid
        JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
        WHERE nsp.nspname = $1 AND con.contype = 'f' AND con.conparentid = 0
        """,
        [@template_schema]
      )

    Enum.each(rows, fn [table_name, conname, def_sql] ->
      rewritten = String.replace(def_sql, ~s(#{@template_schema}.), ~s(#{clone_schema}.))

      Repo.query!(
        ~s(ALTER TABLE "#{clone_schema}"."#{table_name}" ADD CONSTRAINT "#{conname}" #{rewritten})
      )
    end)
  end

  # design §2.3 step 6 (rework 3 addition, mandatory -- five real triggers
  # backed by three real functions currently enforce audit-log/artifact-
  # repository IMMUTABILITY, a security property LIKE ... INCLUDING ALL does
  # NOT preserve). Same qualifier-rewrite hazard class already solved for FKs
  # (§0.1 finding 1) -- pg_get_functiondef/pg_get_triggerdef both emit text
  # literally qualified to the TEMPLATE schema, UNQUOTED (design §0.5 --
  # NOT the quoted `"tenant_template".` form; Postgres emits schema
  # qualifiers unquoted whenever the identifier needs no quoting, which
  # `tenant_template` never does, so a quoted search pattern would silently
  # match nothing and the rewrite would become a no-op).
  #
  # ORDERING IS LOAD-BEARING: ALL functions across ALL tables are created
  # before ANY trigger, because CREATE TRIGGER resolves its EXECUTE FUNCTION
  # target at creation time and fails outright if the function does not yet
  # exist in the clone's own schema.
  defp readd_triggers_and_functions!(clone_schema) do
    %{rows: trigger_rows} =
      Repo.query!(
        """
        SELECT DISTINCT t.tgname, t.oid AS trigger_oid, p.oid AS func_oid,
               rel.relname, t.tgenabled
        FROM pg_trigger t
        JOIN pg_class rel ON rel.oid = t.tgrelid
        JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
        JOIN pg_proc p ON p.oid = t.tgfoid
        WHERE nsp.nspname = $1 AND NOT t.tgisinternal
        """,
        [@template_schema]
      )

    # All DISTINCT function OIDs first (a function backing more than one
    # trigger must be created exactly once), then all triggers.
    trigger_rows
    |> Enum.map(fn [_tgname, _trigger_oid, func_oid, _table, _enabled] -> func_oid end)
    |> Enum.uniq()
    |> Enum.each(fn func_oid ->
      %{rows: [[def_sql]]} =
        Repo.query!("SELECT pg_get_functiondef($1)", [func_oid])

      rewritten = String.replace(def_sql, ~s(#{@template_schema}.), ~s(#{clone_schema}.))
      Repo.query!(rewritten)
    end)

    Enum.each(trigger_rows, fn [tgname, trigger_oid, _func_oid, table, enabled] ->
      %{rows: [[def_sql]]} =
        Repo.query!("SELECT pg_get_triggerdef($1)", [trigger_oid])

      rewritten = String.replace(def_sql, ~s(#{@template_schema}.), ~s(#{clone_schema}.))
      Repo.query!(rewritten)
      restore_enable_mode!(clone_schema, table, tgname, enabled)
    end)
  end

  # REQ-500 / GH #2588 (decision 0056 D4): CREATE TRIGGER always leaves a trigger ENABLE ORIGIN,
  # so a clone would silently drop the template's ENABLE ALWAYS. The template's mode (pg_trigger
  # tgenabled) is replayed here: 'A' ALWAYS, 'R' REPLICA, 'D' DISABLE; 'O' is the default.
  defp restore_enable_mode!(clone_schema, table, tgname, enabled) do
    mode =
      case enabled do
        "A" -> "ALWAYS"
        "R" -> "REPLICA"
        "D" -> "DISABLE"
        "O" -> nil
      end

    if mode do
      Repo.query!(
        "ALTER TABLE #{quote_ident(clone_schema)}.#{quote_ident(table)} " <>
          "ENABLE #{mode} TRIGGER #{quote_ident(tgname)}"
      )
    end
  end

  # design §0.1 finding 3 (pg_get_serial_sequence is the robust primitive,
  # not pg_depend walking) and §0.1 finding 4 (end-to-end verified: after
  # this fix-up, an insert into the clone advances ONLY the clone's own
  # sequence). Design §2.3 step 5, INV-3: new sequence starts at its default
  # (1), never inherits the template's current last_value.
  defp recreate_sequences!(clone_schema) do
    # Batched into ONE round trip for discovery, rather than one
    # pg_get_serial_sequence call per table x column pair (39 tables x up to
    # ~9 columns each = hundreds of round trips, which on a host with real
    # per-round-trip latency dominates the whole mechanism's cost -- exactly
    # the round-trip-count lever this issue exists to pull). Still uses
    # pg_get_serial_sequence as the discovery primitive per design §0.1
    # finding 3 (the robust one, not pg_depend walking) -- just invoked once,
    # set-based, over every column in information_schema.columns for this
    # schema, instead of once per column from Elixir.
    #
    # REQ-376 addition: `tenant_template` physically also holds
    # `events_pre_partition_20260922`/`events_archive_pre_partition_20260922`
    # (the rollback-safety-net tables migration 4/8 rename aside) and the
    # dynamic `events_y<year>m<month>`/`events_default` partition set --
    # real physical tables in `information_schema.columns` for this schema,
    # but deliberately NOT part of `expected_tenant_tables/0`, so step 3
    # above never `CREATE TABLE (LIKE ...)`s them into `clone_schema`. Both
    # renamed-aside tables carry their own `global_seq` sequence (migration
    # 4/8's own rename-in-place), which this query picked up unfiltered and
    # tried to recreate against a clone table that was never created --
    # "relation events_pre_partition_20260922 does not exist" on every
    # :clone-path test tenant provisioned after tenant_template was built
    # from the REQ-376 migration set (same defect class as
    # readd_foreign_keys!/1's own conparentid fix, just a different catalog
    # view). Filtered to exactly the table set step 3 actually clones.
    clone_table_names = MapSet.new(Letflow.TenantFixture.expected_tenant_tables())

    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.table_name, c.column_name,
               pg_get_serial_sequence(quote_ident($1) || '.' || quote_ident(c.table_name), c.column_name)
        FROM information_schema.columns c
        WHERE c.table_schema = $1
        """,
        [@template_schema]
      )

    rows
    |> Enum.reject(fn [_table, _column, seq] -> is_nil(seq) end)
    |> Enum.filter(fn [table, _column, _seq] -> MapSet.member?(clone_table_names, table) end)
    |> Enum.each(fn [table, column, qualified_seq] ->
      # qualified_seq is schema-qualified, e.g. "tenant_template.events_global_seq_seq"
      # (double-quoted per Postgres's own rendering when needed). Extract
      # the LOCAL sequence name so the clone gets a same-named,
      # clone-local sequence object (design §2.3 step 5).
      seq_local_name = local_identifier_name(qualified_seq)

      Repo.query!(~s(CREATE SEQUENCE "#{clone_schema}"."#{seq_local_name}"))

      Repo.query!(
        ~s(ALTER TABLE "#{clone_schema}"."#{table}" ALTER COLUMN "#{column}" ) <>
          ~s|SET DEFAULT nextval('"#{clone_schema}"."#{seq_local_name}"')|
      )

      Repo.query!(
        ~s(ALTER SEQUENCE "#{clone_schema}"."#{seq_local_name}" OWNED BY ) <>
          ~s("#{clone_schema}"."#{table}"."#{column}")
      )
    end)
  end

  # pg_get_serial_sequence returns a value like `tenant_template.foo_seq` or,
  # if the local name needs quoting, `tenant_template."Foo Seq"`. Every
  # sequence name in this codebase's own migrations is a plain lowercase
  # identifier (verified: no quoting needed in the real schema), so a plain
  # split on the first "." is sufficient and matches what design §2.3 step 5
  # specifies ("same local sequence name as the template's, re-qualified to
  # the clone schema").
  defp local_identifier_name(qualified_name) do
    qualified_name
    |> String.split(".", parts: 2)
    |> List.last()
    |> String.trim("\"")
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
  end

  defp applied_versions_in(schema_name) do
    %{rows: rows} = Repo.query!(~s(SELECT version FROM "#{schema_name}".schema_migrations))
    Enum.map(rows, fn [version] -> version end)
  end

  # ---------------------------------------------------------------------------
  # Parity dimensions (design §3.2, thirteen dimensions)
  # ---------------------------------------------------------------------------

  defp dimension_checks do
    [
      {1, &check_table_set/2},
      {2, &check_columns/2},
      {3, &check_constraints/2},
      {4, &check_indexes/2},
      {5, &check_sequences/2},
      {6, &check_identity/2},
      {7, &check_row_counts/2},
      {8, &check_triggers_comments/2},
      {9, &check_reloptions/2},
      {10, &check_attstattarget/2},
      {11, &check_statistics_ext/2},
      {12, &check_ruled_out_properties/2},
      {13, &check_type_collation_namespace/2}
    ]
  end

  # ISS-0427 MAJOR fix (found by TEST-DESIGNER at step 4, confirmed by ORCH):
  # this used to strip BOTH schema qualifiers from BOTH sides. That made the
  # whole parity check structurally blind to the PRIMARY hazard this design
  # exists to catch -- an object that is PRESENT in the clone but still
  # REPOINTED AT THE TEMPLATE. A clone FK reading
  # `REFERENCES tenant_template.parents(id)` stripped to `REFERENCES
  # parents(id)`, which is byte-identical to what a CORRECT clone's own
  # `REFERENCES tenant_abc.parents(id)` stripped to, so the comparison
  # reported :ok on a genuinely coupled clone. Reproduced three ways (FK
  # repoint, sequence-DEFAULT repoint, trigger-function repoint), all of
  # which passed before this fix.
  #
  # The correct rule: normalize each side against ITS OWN schema only. Text
  # read out of the reference schema strips the reference's qualifier; text
  # read out of the candidate strips the candidate's. Every other qualifier
  # SURVIVES normalization, so a leftover `tenant_template.` inside a
  # candidate definition no longer collapses into a match -- it stays as a
  # visible textual difference and fails the comparison, which is exactly
  # the signal we need.
  #
  # `own_schema` is the schema the text was actually read from. Do not
  # reintroduce a second strip here "for symmetry" -- the asymmetry IS the
  # check.
  defp normalize(text, own_schema) do
    String.replace(text, ~s(#{own_schema}.), "")
  end

  # dimension #1: table set, set-equal, both directions.
  #
  # REQ-376 rework3 fix: `tables_in/1` on the REFERENCE (template) side
  # includes the 7 partition-management artifacts
  # `Letflow.TenantFixture.req376_partition_management_table?/1` recognizes
  # (`events_default`/`events_archive_default`, the two
  # `*_pre_partition_20260922` rollback-safety-net tables, and the dynamic
  # `events_y<year>m<month>`/`events_archive_y<year>m<month>` calendar-month
  # children) -- physical objects that exist ONLY because `tenant_template`
  # is built via a genuine `replay_migrations/2` (which runs REQ-376's
  # partitioning migrations for real). A `:clone`-provisioned schema is, BY
  # DESIGN, plain/unpartitioned (`do_clone/2`'s own `CREATE TABLE (LIKE ...
  # INCLUDING ALL)` does not and cannot copy `PARTITION BY` -- a documented
  # Postgres limitation, not a bug; see `readd_foreign_keys!/1`'s and
  # `structural_indexdef/1`'s own comments, and
  # `req376_partition_management_table?/1`'s doc, for the same fact
  # established at each of this module's other catalog-query sites) and so
  # never has these tables at all -- their absence from a clone is the
  # CORRECT, intended output of provisioning, not something this dimension
  # should ever have flagged as "missing". The `missing` side is therefore
  # rejected through the full `req376_partition_management_table?/1` oracle
  # (the same one `template_self_check!/1`, use site 1, trusts) for the
  # `:clone` case.
  #
  # The DYNAMIC calendar-month tables (`events_yYYYYmMM` /
  # `events_archive_yYYYYmMM`) are additionally ignored on BOTH sides before
  # either set is computed: their names depend on the UTC date the
  # migration ran, so a template built in month N and a reference replayed
  # in month N+1 legitimately hold different ones (ISS-0937). Removing them
  # from both sets leaves no false "extra". The four FIXED tables
  # (`events_default`, `events_archive_default`, the two `*_pre_partition_*`)
  # are not date-dependent and stay in the comparison, so a missing or extra
  # fixed table is still real drift.
  defp check_table_set(reference_schema, candidate_schema) do
    ref_tables = reference_schema |> tables_in() |> reject_dynamic_partitions() |> MapSet.new()
    cand_tables = candidate_schema |> tables_in() |> reject_dynamic_partitions() |> MapSet.new()

    missing =
      ref_tables
      |> MapSet.difference(cand_tables)
      |> Enum.reject(&Letflow.TenantFixture.req376_partition_management_table?/1)
      |> MapSet.new()

    extra = MapSet.difference(cand_tables, ref_tables)

    []
    |> add_if(MapSet.size(missing) > 0, "table set: missing=#{inspect(MapSet.to_list(missing))}")
    |> add_if(MapSet.size(extra) > 0, "table set: extra=#{inspect(MapSet.to_list(extra))}")
  end

  defp reject_dynamic_partitions(tables),
    do: Enum.reject(tables, &Letflow.TenantFixture.req376_dynamic_partition_table?/1)

  # dimension #2: columns -- name, data type, is_nullable, column_default
  # (schema-qualifier-normalized), ordinal position.
  defp check_columns(reference_schema, candidate_schema) do
    common_tables =
      MapSet.intersection(
        MapSet.new(tables_in(reference_schema)),
        MapSet.new(tables_in(candidate_schema))
      )

    Enum.flat_map(common_tables, fn table ->
      ref_cols = column_rows(reference_schema, table)
      cand_cols = column_rows(candidate_schema, table)

      ref_norm =
        ref_cols
        |> reindex_ordinal()
        |> Enum.map(&normalize_column_row(&1, reference_schema))

      cand_norm =
        cand_cols
        |> reindex_ordinal()
        |> Enum.map(&normalize_column_row(&1, candidate_schema))

      if ref_norm != cand_norm do
        [
          "columns mismatch on table=#{table}: reference=#{inspect(ref_norm)} candidate=#{inspect(cand_norm)}"
        ]
      else
        []
      end
    end)
  end

  defp column_rows(schema_name, table_name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name, data_type, is_nullable, column_default, ordinal_position " <>
          "FROM information_schema.columns WHERE table_schema = $1 AND table_name = $2 " <>
          "ORDER BY ordinal_position",
        [schema_name, table_name]
      )

    rows
  end

  # ordinal_position is absolute and includes gaps left by dropped columns
  # (e.g. REQ-064's tenant_id-drop migrations) -- LIKE ... INCLUDING ALL does
  # NOT preserve those gaps in the clone (Postgres renumbers to consecutive
  # positions), which is cosmetically irrelevant: the RELATIVE order among
  # live columns is what the clone must match, not the raw integer. Rows
  # arrive already ordered by the query's own ORDER BY ordinal_position, so
  # re-ranking here (1, 2, 3, ... over live columns only) makes the two sides
  # comparable without asserting something LIKE was never meant to preserve.
  defp reindex_ordinal(rows) do
    rows
    |> Enum.with_index(1)
    |> Enum.map(fn {[name, data_type, nullable, default, _ordinal], index} ->
      [name, data_type, nullable, default, index]
    end)
  end

  defp normalize_column_row(
         [name, data_type, nullable, default, ordinal],
         own_schema
       ) do
    normalized_default =
      case default do
        nil -> nil
        text -> normalize(text, own_schema)
      end

    [name, data_type, nullable, normalized_default, ordinal]
  end

  # dimension #3: constraint kinds and definitions -- pg_constraint grouped by
  # contype over the full six-member set {c,f,p,u,x,t}, compared as a
  # multiset of normalized definitions per table (never by conname, per
  # design §0.1 finding 2).
  defp check_constraints(reference_schema, candidate_schema) do
    ref = constraint_rows(reference_schema)
    cand = constraint_rows(candidate_schema)

    ref_norm =
      ref
      |> Enum.map(fn [table, contype, def_sql] ->
        {table, contype, normalize(def_sql, reference_schema)}
      end)
      |> Enum.frequencies()

    cand_norm =
      cand
      |> Enum.map(fn [table, contype, def_sql] ->
        {table, contype, normalize(def_sql, candidate_schema)}
      end)
      |> Enum.frequencies()

    if ref_norm == cand_norm do
      []
    else
      missing = Map.drop(ref_norm, Map.keys(cand_norm)) |> Map.keys()
      extra = Map.drop(cand_norm, Map.keys(ref_norm)) |> Map.keys()

      []
      |> add_if(missing != [], "constraints: missing=#{inspect(missing)}")
      |> add_if(extra != [], "constraints: extra=#{inspect(extra)}")
      |> add_if(
        missing == [] and extra == [],
        "constraints: frequency mismatch #{inspect(ref_norm)} vs #{inspect(cand_norm)}"
      )
    end
  end

  # REQ-376 rework3 fix, two filters, same reasoning as
  # `check_table_set/2`'s and `readd_foreign_keys!/1`'s own comments:
  #
  #   1. `con.conparentid = 0` -- excludes Postgres's own INTERNAL
  #      per-partition child constraints (the same `pg_constraint`
  #      implementation detail `readd_foreign_keys!/1` already filters when
  #      REPLAYING constraints into a clone; unfiltered here, dimension #3
  #      also READ them straight off the reference schema and reported them
  #      as "missing" from every clone, since a clone's own
  #      `event_payload_store` FK never gets these Postgres-internal child
  #      rows in the first place -- reused, not reinvented).
  #   2. `req376_partition_management_table?/1` -- rejects constraint rows
  #      belonging to the 7 partition-management tables themselves (their
  #      own local PK/CHECK constraints, e.g. `events_default`'s own
  #      primary key), which a `:clone`-provisioned schema never has at all
  #      (see `check_table_set/2`'s comment for why that absence is
  #      correct, not a defect).
  defp constraint_rows(schema_name) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT rel.relname, con.contype::text, pg_get_constraintdef(con.oid)
        FROM pg_constraint con
        JOIN pg_class rel ON rel.oid = con.conrelid
        JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
        WHERE nsp.nspname = $1 AND con.conparentid = 0
        """,
        [schema_name]
      )

    Enum.reject(rows, fn [table_name, _contype, _def_sql] ->
      Letflow.TenantFixture.req376_partition_management_table?(table_name)
    end)
  end

  # dimension #4: indexes -- TWO separate assertions, both mandatory
  # (design §3.2 dimension #4, rework 4 / §0.6). (a) STRUCTURE:
  # pg_indexes.indexdef, schema-qualifier-normalized, own-name-stripped,
  # compared as a multiset per table, explicitly NOT by indexname (design
  # §0.1 finding 2, rework-3 gate correction). (b) NAME (NEW, rework 4,
  # INV-7): after pairing each candidate index to its reference counterpart
  # via (a)'s structural, name-blind comparison, assert `indexname` is
  # IDENTICAL between the paired reference and candidate indexes. Ordering
  # matters and is why this is not one combined check: (a) pairs first
  # (structure, name-blind), THEN (b) asserts on the now-paired objects
  # (name, structure-blind) -- never the reverse, per the design's own
  # explicit instruction not to collapse the two steps.
  defp check_indexes(reference_schema, candidate_schema) do
    structure_diffs = check_index_structure(reference_schema, candidate_schema)
    name_diffs = check_index_names(reference_schema, candidate_schema)
    structure_diffs ++ name_diffs
  end

  defp check_index_structure(reference_schema, candidate_schema) do
    ref = index_defs(reference_schema)
    cand = index_defs(candidate_schema)

    ref_freq = Enum.frequencies(ref)
    cand_freq = Enum.frequencies(cand)

    if ref_freq == cand_freq do
      []
    else
      ["indexes: reference=#{inspect(ref_freq)} candidate=#{inspect(cand_freq)}"]
    end
  end

  # design §3.2 dimension #4(b), INV-7. For each table common to both
  # schemas, pair reference/candidate indexes STRUCTURALLY (same technique
  # §2.3 step 3.5's own mechanism uses, reused rather than reinvented), then
  # assert the paired indexes' own catalog names are identical. This is what
  # would have caught ISS-0427's post-merge defect (a structurally-correct
  # but differently-named clone) at parity-check time rather than as a raw
  # Ecto.ConstraintError seven application tests away.
  defp check_index_names(reference_schema, candidate_schema) do
    common_tables =
      MapSet.intersection(
        MapSet.new(tables_in(reference_schema)),
        MapSet.new(tables_in(candidate_schema))
      )

    Enum.flat_map(common_tables, fn table ->
      ref_by_def =
        Map.new(index_name_defs(reference_schema, table), fn {name, def} -> {def, name} end)

      cand_indexes = index_name_defs(candidate_schema, table)

      Enum.flat_map(cand_indexes, fn {cand_name, def} ->
        case Map.fetch(ref_by_def, def) do
          {:ok, ^cand_name} ->
            []

          {:ok, ref_name} ->
            [
              "index name mismatch table=#{table} reference_name=#{ref_name} candidate_name=#{cand_name} (structurally paired, def=#{inspect(def)})"
            ]

          :error ->
            # No structural counterpart on the reference side -- already
            # reported as a structure diff by check_index_structure/2 above;
            # not duplicated here.
            []
        end
      end)
    end)
  end

  # REQ-376 rework3 fix: same `req376_partition_management_table?/1` filter
  # as `check_table_set/2` and `constraint_rows/1` above -- `pg_indexes`
  # lists one physical index row PER PARTITION for every index declared on
  # a partitioned parent (each of `events`/`events_archive`'s 7 partition
  # children gets its own physical copy of every parent index), none of
  # which a `:clone`-provisioned schema ever has (see `check_table_set/2`'s
  # comment). `structural_indexdef/1`'s own "ONLY " strip already makes the
  # PARENT table's own index defs agree across the two sides -- this filter
  # only removes the CHILD partitions' own duplicate index rows, which have
  # no clone-side counterpart to agree with at all.
  defp index_defs(schema_name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT tablename, indexdef FROM pg_indexes WHERE schemaname = $1",
        [schema_name]
      )

    rows
    |> Enum.reject(fn [table, _def_sql] ->
      Letflow.TenantFixture.req376_partition_management_table?(table)
    end)
    |> Enum.map(fn [table, def_sql] ->
      {table, structural_indexdef(normalize(def_sql, schema_name))}
    end)
  end

  # design §0.1 finding 2: LIKE ... INCLUDING ALL renames indexes to
  # Postgres's own auto-generated default names, which do not match the
  # template's actual index names -- so the index's OWN NAME (the
  # `CREATE [UNIQUE] INDEX <name>` prefix) must never be part of an equality
  # comparison, only the structural remainder (USING method, columns/
  # expression, WHERE predicate) starting at `ON`. Uniqueness survives
  # separately as the presence/absence of the literal "UNIQUE " token before
  # "INDEX", which this strip preserves since it stays before "ON".
  defp structural_indexdef(def_sql) do
    case String.split(def_sql, " ON ", parts: 2) do
      [prefix, rest] ->
        unique? = String.contains?(prefix, "UNIQUE")
        # REQ-376: `events`/`events_archive` are this codebase's first
        # PARTITION BY tables. Postgres's own pg_indexes.indexdef for an
        # index declared on a partitioned PARENT reads "... ON ONLY
        # <table> ..." (it does not recurse into child partitions), while
        # a `:clone`-provisioned tenant's `events`/`events_archive` are
        # always plain, non-partitioned tables (`CREATE TABLE (LIKE ...
        # INCLUDING ALL)` does not copy `PARTITION BY` — see
        # `req376_partition_management_table?/1`'s own comment in
        # tenant_fixture.ex for the same underlying fact), so a clone's
        # equivalent index never carries "ONLY". Stripping it here is what
        # makes the template (partitioned) and clone (not) sides of this
        # structural comparison agree — without it, EVERY :clone-based
        # tenant fixture in the whole suite fails at
        # rename_indexes_to_template_names!/2, not just REQ-376's own
        # tests (reproduced: 50 failing tests before this fix, all
        # TENANT_TEMPLATE_CLONE_FAILED on events_pkey/events_archive_pkey).
        rest = String.replace_prefix(rest, "ONLY ", "")
        "#{if unique?, do: "UNIQUE", else: "NOT UNIQUE"} ON #{rest}"

      [only] ->
        only
    end
  end

  # dimension #5: sequences reachable from a column default. Both sides must
  # agree on which columns are sequence-backed, and the candidate's sequence
  # must live IN the candidate schema (design §0's "sequence trap" check).
  #
  # REVIEWER's MINOR finding (step-03c): the original per-(table,column)
  # discovery here had the SAME N+1 shape recreate_sequences!/1 was measured
  # to have and fixed (design §0.1 finding 3's pg_get_serial_sequence,
  # invoked once per column instead of once per schema side). Batched into
  # ONE information_schema.columns-driven query per schema side, identical
  # technique to recreate_sequences!/1 -- same discovery primitive
  # (pg_get_serial_sequence, per design §0.1 finding 3), same correctness,
  # far fewer round trips. See the cost-measurement note in this run's own
  # handoff for the measured before/after.
  defp check_sequences(reference_schema, candidate_schema) do
    common_tables =
      MapSet.intersection(
        MapSet.new(tables_in(reference_schema)),
        MapSet.new(tables_in(candidate_schema))
      )

    ref_seqs = serial_sequences_in(reference_schema)
    cand_seqs = serial_sequences_in(candidate_schema)

    Enum.flat_map(common_tables, fn table ->
      ref_columns_for_table =
        ref_seqs |> Map.keys() |> Enum.filter(fn {t, _c} -> t == table end)

      cand_columns_for_table =
        cand_seqs |> Map.keys() |> Enum.filter(fn {t, _c} -> t == table end)

      columns =
        (ref_columns_for_table ++ cand_columns_for_table)
        |> Enum.map(fn {_t, c} -> c end)
        |> Enum.uniq()

      Enum.flat_map(columns, fn column ->
        ref_seq = Map.get(ref_seqs, {table, column})
        cand_seq = Map.get(cand_seqs, {table, column})

        cond do
          is_nil(ref_seq) and is_nil(cand_seq) ->
            []

          is_nil(ref_seq) != is_nil(cand_seq) ->
            [
              "sequence presence mismatch table=#{table} column=#{column} reference=#{inspect(ref_seq)} candidate=#{inspect(cand_seq)}"
            ]

          true ->
            cand_ns = String.split(cand_seq, ".", parts: 2) |> List.first() |> String.trim("\"")

            if cand_ns != candidate_schema do
              [
                "sequence namespace leak table=#{table} column=#{column} candidate_seq=#{cand_seq} expected_ns=#{candidate_schema}"
              ]
            else
              []
            end
        end
      end)
    end)
  end

  # One round trip for the whole schema: `pg_get_serial_sequence` invoked
  # once per (table, column) pair inside the SQL query itself (a set-based
  # scalar-subquery-shaped SELECT over information_schema.columns), not once
  # per pair from Elixir. Returns a map keyed by {table, column} to the
  # schema-qualified sequence name (or absent from the map if that column has
  # no sequence-backed default) -- callers use Map.get/2, which yields nil
  # for a missing key, so is_nil/1 checks downstream behave identically to
  # the pre-fix per-column serial_sequence/3 call's nil return.
  defp serial_sequences_in(schema_name) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT c.table_name, c.column_name,
               pg_get_serial_sequence(quote_ident($1) || '.' || quote_ident(c.table_name), c.column_name)
        FROM information_schema.columns c
        WHERE c.table_schema = $1
        """,
        [schema_name]
      )

    rows
    |> Enum.reject(fn [_table, _column, seq] -> is_nil(seq) end)
    |> Map.new(fn [table, column, seq] -> {{table, column}, seq} end)
  end

  # dimension #6: NOT NULL/identity -- attidentity equality per column
  # (folded is_nullable already lives in dimension #2).
  defp check_identity(reference_schema, candidate_schema) do
    common_tables =
      MapSet.intersection(
        MapSet.new(tables_in(reference_schema)),
        MapSet.new(tables_in(candidate_schema))
      )

    Enum.flat_map(common_tables, fn table ->
      ref = identity_rows(reference_schema, table)
      cand = identity_rows(candidate_schema, table)

      if ref != cand do
        ["identity mismatch table=#{table}: reference=#{inspect(ref)} candidate=#{inspect(cand)}"]
      else
        []
      end
    end)
  end

  defp identity_rows(schema_name, table_name) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT att.attname, att.attidentity
        FROM pg_attribute att
        JOIN pg_class rel ON rel.oid = att.attrelid
        JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
        WHERE nsp.nspname = $1 AND rel.relname = $2 AND att.attnum > 0 AND NOT att.attisdropped
        ORDER BY att.attname
        """,
        [schema_name, table_name]
      )

    rows
  end

  # dimension #7: row counts for seeded tables -- event_type_registry
  # (row count) and schema_migrations (row count AND version set).
  defp check_row_counts(reference_schema, candidate_schema) do
    ref_count = row_count(reference_schema, "event_type_registry")
    cand_count = row_count(candidate_schema, "event_type_registry")

    ref_versions = MapSet.new(applied_versions_in(reference_schema))
    cand_versions = MapSet.new(applied_versions_in(candidate_schema))

    []
    |> add_if(
      ref_count != cand_count,
      "event_type_registry row count reference=#{ref_count} candidate=#{cand_count}"
    )
    |> add_if(
      ref_versions != cand_versions,
      "schema_migrations version set reference=#{inspect(MapSet.to_list(ref_versions))} candidate=#{inspect(MapSet.to_list(cand_versions))}"
    )
  end

  defp row_count(schema_name, table_name) do
    %{rows: [[count]]} = Repo.query!(~s|SELECT count(*) FROM "#{schema_name}"."#{table_name}"|)
    count
  end

  # dimension #8: triggers -- REWORK 3 CORRECTION (design §3.2 item 8). No
  # longer a count-equal-to-zero assertion (that premise was false -- five
  # real triggers backed by three real functions currently enforce
  # audit-log/artifact-repository IMMUTABILITY, a security property). Two
  # separate structural, schema-qualifier-normalized comparisons, per the
  # design: (1) per-table multiset of pg_get_triggerdef text -- catches a
  # trigger missing entirely, one whose definition differs, AND one that is
  # present but still calls the TEMPLATE's own function (the EXECUTE
  # FUNCTION clause is part of the compared text); (2) per-schema multiset
  # of pg_get_functiondef text for every function referenced by a
  # NOT tgisinternal trigger -- catches a function missing, differing in
  # body, or present but not the one the clone's triggers actually invoke.
  # Plus table/column comments (compared, expected NULL/NULL today).
  defp check_triggers_comments(reference_schema, candidate_schema) do
    trigger_diffs = check_trigger_defs(reference_schema, candidate_schema)
    function_diffs = check_trigger_function_defs(reference_schema, candidate_schema)

    common_tables =
      MapSet.intersection(
        MapSet.new(tables_in(reference_schema)),
        MapSet.new(tables_in(candidate_schema))
      )

    comment_diffs =
      Enum.flat_map(common_tables, fn table ->
        ref_comment = table_comment(reference_schema, table)
        cand_comment = table_comment(candidate_schema, table)

        if ref_comment != cand_comment do
          [
            "table comment mismatch table=#{table} reference=#{inspect(ref_comment)} candidate=#{inspect(cand_comment)}"
          ]
        else
          []
        end
      end)

    trigger_diffs ++ function_diffs ++ comment_diffs
  end

  defp check_trigger_defs(reference_schema, candidate_schema) do
    ref = trigger_defs(reference_schema)
    cand = trigger_defs(candidate_schema)

    ref_freq = Enum.frequencies(ref)
    cand_freq = Enum.frequencies(cand)

    if ref_freq == cand_freq do
      []
    else
      ["triggers: reference=#{inspect(ref_freq)} candidate=#{inspect(cand_freq)}"]
    end
  end

  defp trigger_defs(schema_name) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT rel.relname, pg_get_triggerdef(trg.oid)
        FROM pg_trigger trg
        JOIN pg_class rel ON rel.oid = trg.tgrelid
        JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
        WHERE nsp.nspname = $1 AND NOT trg.tgisinternal
        """,
        [schema_name]
      )

    Enum.map(rows, fn [table, def_sql] ->
      {table, normalize(def_sql, schema_name)}
    end)
  end

  defp check_trigger_function_defs(reference_schema, candidate_schema) do
    ref = trigger_function_defs(reference_schema)
    cand = trigger_function_defs(candidate_schema)

    ref_freq = Enum.frequencies(ref)
    cand_freq = Enum.frequencies(cand)

    if ref_freq == cand_freq do
      []
    else
      ["trigger functions: reference=#{inspect(ref_freq)} candidate=#{inspect(cand_freq)}"]
    end
  end

  defp trigger_function_defs(schema_name) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT DISTINCT pg_get_functiondef(p.oid)
        FROM pg_trigger trg
        JOIN pg_class rel ON rel.oid = trg.tgrelid
        JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
        JOIN pg_proc p ON p.oid = trg.tgfoid
        WHERE nsp.nspname = $1 AND NOT trg.tgisinternal
        """,
        [schema_name]
      )

    Enum.map(rows, fn [def_sql] -> normalize(def_sql, schema_name) end)
  end

  defp table_comment(schema_name, table_name) do
    %{rows: [[comment]]} =
      Repo.query!(
        "SELECT obj_description(rel.oid) FROM pg_class rel " <>
          "JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace " <>
          "WHERE nsp.nspname = $1 AND rel.relname = $2",
        [schema_name, table_name]
      )

    comment
  end

  # dimension #9: table-level storage parameters (pg_class.reloptions),
  # set-equal per table.
  defp check_reloptions(reference_schema, candidate_schema) do
    common_tables =
      MapSet.intersection(
        MapSet.new(tables_in(reference_schema)),
        MapSet.new(tables_in(candidate_schema))
      )

    Enum.flat_map(common_tables, fn table ->
      ref = reloptions(reference_schema, table)
      cand = reloptions(candidate_schema, table)

      if MapSet.new(ref) != MapSet.new(cand) do
        [
          "reloptions mismatch table=#{table} reference=#{inspect(ref)} candidate=#{inspect(cand)}"
        ]
      else
        []
      end
    end)
  end

  defp reloptions(schema_name, table_name) do
    %{rows: [[opts]]} =
      Repo.query!(
        "SELECT rel.reloptions FROM pg_class rel " <>
          "JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace " <>
          "WHERE nsp.nspname = $1 AND rel.relname = $2",
        [schema_name, table_name]
      )

    opts || []
  end

  # dimension #10: per-column statistics target (pg_attribute.attstattarget).
  defp check_attstattarget(reference_schema, candidate_schema) do
    common_tables =
      MapSet.intersection(
        MapSet.new(tables_in(reference_schema)),
        MapSet.new(tables_in(candidate_schema))
      )

    Enum.flat_map(common_tables, fn table ->
      ref = attstattarget_rows(reference_schema, table)
      cand = attstattarget_rows(candidate_schema, table)

      if ref != cand do
        [
          "attstattarget mismatch table=#{table}: reference=#{inspect(ref)} candidate=#{inspect(cand)}"
        ]
      else
        []
      end
    end)
  end

  defp attstattarget_rows(schema_name, table_name) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT att.attname, att.attstattarget
        FROM pg_attribute att
        JOIN pg_class rel ON rel.oid = att.attrelid
        JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
        WHERE nsp.nspname = $1 AND rel.relname = $2 AND att.attnum > 0 AND NOT att.attisdropped
        ORDER BY att.attname
        """,
        [schema_name, table_name]
      )

    rows
  end

  # dimension #11: extended statistics objects (pg_statistic_ext),
  # count-equal-to-zero rule-out today, per-table multiset of normalized
  # definitions if any exist (same structural-not-name-based treatment as
  # indexes/constraints).
  defp check_statistics_ext(reference_schema, candidate_schema) do
    ref = statistics_ext_defs(reference_schema)
    cand = statistics_ext_defs(candidate_schema)

    ref_freq = Enum.frequencies(ref)
    cand_freq = Enum.frequencies(cand)

    if ref_freq == cand_freq do
      []
    else
      ["pg_statistic_ext: reference=#{inspect(ref_freq)} candidate=#{inspect(cand_freq)}"]
    end
  end

  defp statistics_ext_defs(schema_name) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT rel.relname, pg_get_statisticsobjdef(st.oid)
        FROM pg_statistic_ext st
        JOIN pg_class rel ON rel.oid = st.stxrelid
        JOIN pg_namespace nsp ON nsp.oid = st.stxnamespace
        WHERE nsp.nspname = $1
        """,
        [schema_name]
      )

    Enum.map(rows, fn [table, def_sql] ->
      {table, structural_statisticsdef(normalize(def_sql, schema_name))}
    end)
  end

  # Same name-independent treatment as structural_indexdef/1 above, per
  # design §0.2 finding 4: LIKE ... INCLUDING ALL auto-renames extended
  # statistics objects too. Format: "CREATE STATISTICS <name> (<kinds>) ON
  # <columns> FROM <table>" -- strip the name, keep everything from "(" on.
  defp structural_statisticsdef(def_sql) do
    case Regex.run(~r/^CREATE STATISTICS \S+ (.*)$/, def_sql) do
      [_, rest] -> rest
      nil -> def_sql
    end
  end

  # dimension #12: RLS, partitioning, tablespace, ownership -- checked and
  # asserted equal (not-applicable today, but a live check, not a silent
  # omission).
  #
  # REQ-376 rework3 fix: `relkind` is the one field in this row this
  # dimension must NOT compare byte-for-byte for `events`/`events_archive`
  # specifically -- the reference (template, genuinely `replay_migrations/2`
  # built) reads "p" (partitioned table) for both, while a `:clone`-
  # provisioned schema's own `events`/`events_archive` are, by design,
  # plain "r" (ordinary) tables (see `check_table_set/2`'s comment for the
  # full reasoning: `CREATE TABLE (LIKE ... INCLUDING ALL)` cannot copy
  # `PARTITION BY` at all). Every OTHER ruled-out property on every table
  # (including `relispartition`, which stays `false` on both sides for
  # these two top-level parents -- only their CHILDREN would read `true`,
  # and no child table is ever a `common_table` here since a clone never
  # has one) is still compared with zero tolerance, exactly as before.
  defp check_ruled_out_properties(reference_schema, candidate_schema) do
    common_tables =
      MapSet.intersection(
        MapSet.new(tables_in(reference_schema)),
        MapSet.new(tables_in(candidate_schema))
      )

    Enum.flat_map(common_tables, fn table ->
      ref = ruled_out_row(reference_schema, table)
      cand = ruled_out_row(candidate_schema, table)

      # relowner is a role OID, identical by construction (single configured
      # role) -- excluded from comparison, not from the query, so a future
      # reader can see it was fetched, per design §0.2 finding 5.
      [_ref_owner | ref_rest] = ref
      [_cand_owner | cand_rest] = cand

      [ref_norm, cand_norm] =
        if table in ["events", "events_archive"] do
          [normalize_relkind(ref_rest), normalize_relkind(cand_rest)]
        else
          [ref_rest, cand_rest]
        end

      if ref_norm != cand_norm do
        [
          "ruled-out property mismatch table=#{table}: reference=#{inspect(ref)} candidate=#{inspect(cand)}"
        ]
      else
        []
      end
    end)
  end

  # `[relrowsecurity, relforcerowsecurity, relkind, relispartition, reltablespace]`
  # -- position 3 (0-indexed) is `relkind`. "p" (partitioned) and "r"
  # (ordinary) are the only two values REQ-376 legitimately produces here
  # (a partitioned parent on the reference side, a plain table on the
  # candidate side); collapse both to a single marker so the two sides can
  # still be compared on every OTHER position.
  defp normalize_relkind(row) do
    List.update_at(row, 2, fn
      kind when kind in ["p", "r"] -> :table_or_partitioned_parent
      other -> other
    end)
  end

  defp ruled_out_row(schema_name, table_name) do
    %{rows: [row]} =
      Repo.query!(
        "SELECT relowner, relrowsecurity, relforcerowsecurity, relkind, relispartition, reltablespace " <>
          "FROM pg_class rel JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace " <>
          "WHERE nsp.nspname = $1 AND rel.relname = $2",
        [schema_name, table_name]
      )

    row
  end

  # dimension #13: column type and collation NAMESPACE -- structural, not
  # name/string based (design §0.3, the rework-2 fix). A non-pg_catalog-owned
  # type/collation's namespace on the CANDIDATE side must equal the
  # candidate's own schema, never the reference's.
  defp check_type_collation_namespace(reference_schema, candidate_schema) do
    common_tables =
      MapSet.intersection(
        MapSet.new(tables_in(reference_schema)),
        MapSet.new(tables_in(candidate_schema))
      )

    Enum.flat_map(common_tables, fn table ->
      ref_rows = type_collation_rows(reference_schema, table)
      cand_rows = type_collation_rows(candidate_schema, table)

      cand_by_name = Map.new(cand_rows, fn [name | rest] -> {name, rest} end)

      Enum.flat_map(ref_rows, fn [name, ref_type_ns, ref_coll_ns] ->
        case Map.fetch(cand_by_name, name) do
          :error ->
            []

          {:ok, [cand_type_ns, cand_coll_ns]} ->
            []
            |> check_namespace_branch(
              table,
              name,
              "type",
              ref_type_ns,
              cand_type_ns,
              reference_schema,
              candidate_schema
            )
            |> check_namespace_branch(
              table,
              name,
              "collation",
              ref_coll_ns,
              cand_coll_ns,
              reference_schema,
              candidate_schema
            )
        end
      end)
    end)
  end

  defp check_namespace_branch(
         acc,
         table,
         column,
         kind,
         ref_ns,
         cand_ns,
         reference_schema,
         candidate_schema
       ) do
    cond do
      ref_ns == "pg_catalog" and cand_ns == "pg_catalog" ->
        acc

      ref_ns == reference_schema and cand_ns == candidate_schema ->
        acc

      true ->
        [
          "column #{kind} namespace mismatch table=#{table} column=#{column} " <>
            "reference_ns=#{ref_ns} candidate_ns=#{cand_ns}"
          | acc
        ]
    end
  end

  defp type_collation_rows(schema_name, table_name) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT att.attname,
               type_nsp.nspname AS type_namespace,
               COALESCE(coll_nsp.nspname, 'pg_catalog') AS collation_namespace
        FROM pg_attribute att
        JOIN pg_class rel ON rel.oid = att.attrelid
        JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
        JOIN pg_type typ ON typ.oid = att.atttypid
        JOIN pg_namespace type_nsp ON type_nsp.oid = typ.typnamespace
        LEFT JOIN pg_collation coll ON coll.oid = att.attcollation
        LEFT JOIN pg_namespace coll_nsp ON coll_nsp.oid = coll.collnamespace
        WHERE nsp.nspname = $1 AND rel.relname = $2 AND att.attnum > 0 AND NOT att.attisdropped
        ORDER BY att.attname
        """,
        [schema_name, table_name]
      )

    rows
  end

  defp add_if(list, true, item), do: [item | list]
  defp add_if(list, false, _item), do: list
end
