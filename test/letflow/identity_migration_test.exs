defmodule Letflow.IdentityMigrationTest do
  @moduledoc """
  Tests for `Letflow.IdentityMigration.copy_all_tenants/0`/`copy_tenant/2` (REQ-063
  §4) and `priv/repo/migrations/20260819000004_drop_legacy_public_identity_tables.exs`'s
  guard-skip/guard-proceed behavior (REQ-063 §5). See `test/specs/REQ-063.md` for the
  full test-case rationale.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 — no mocked database anywhere in this file.

  ## Why this file recreates `public.users`/`public.groups`/`public.tenant_role`

  This branch's own `mix ecto.migrate` run already applied
  `20260819000004_drop_legacy_public_identity_tables.exs` against this test
  database — the legacy `public.users`/`public.groups`/`public.tenant_role` tables
  are already gone (confirmed via `to_regclass('public.users')` returning `NULL`
  before this file was drafted), which is the correct, permanent end state for a
  real environment. To exercise `copy_all_tenants/0` (which reads FROM those legacy
  tables) and the drop migration's guard (which checks them) at all, this file
  recreates minimal, throwaway versions of the three tables directly via
  `Repo.query!/2` DDL, seeds them with realistic pre-cutover rows, runs the code
  under test against that throwaway state, and drops the throwaway tables again in
  `on_exit/1`. This does not touch any shipped migration file or change what a real
  `mix ecto.migrate` run does — it reconstructs the exact pre-cutover physical shape
  those three legacy migrations originally created (confirmed against
  `priv/repo/migrations/20260816000002_create_groups.exs`,
  `20260816000003_create_tenant_role.exs`, `20260816000004_create_users.exs`'s own
  column lists), scoped to only the columns this file's tests actually touch.

  `Ecto.Migrator.run/4`'s explicit `[{version, module}]` form needs the drop
  migration's module genuinely loaded into this run's BEAM VM first —
  `priv/repo/migrations/*.exs` is outside `:test`'s `elixirc_paths`, and (per
  `test/letflow/event_store/registry_test.exs`'s own documented finding, ISS-0017/
  ELIXIR-DEV's Step 2a handoff) once a migration's version is already recorded in
  `schema_migrations` (true here, since this branch's own `mix ecto.migrate` already
  ran it once), `Ecto.Migrator`'s directory scan never re-loads the module on a
  later `mix ecto.migrate`, so calling `Ecto.Migrator.run/4` directly with an
  explicit `{version, module}` tuple raises `Ecto.MigrationError` unless the module
  is `Code.require_file/1`'d first — `ensure_drop_migration_loaded!/0` below mirrors
  `registry_test.exs`'s exact, already-established workaround for this same
  documented gap.

  Follows the same `Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)` + manual
  `on_exit/1` cleanup pattern `test/letflow/tenant_provisioning_test.exs` and
  `test/letflow/identity_test.exs` already establish (`Ecto.Migrator` cannot run
  under the sandbox's single shared connection). `async: false` for the whole module
  (ExUnit's `async` setting is module-wide).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  require Logger

  alias Letflow.Identity.Tenant
  alias Letflow.IdentityMigration
  alias Letflow.TenantFixture

  @drop_migration_file Path.expand(
                         "../../priv/repo/migrations/20260819000004_drop_legacy_public_identity_tables.exs",
                         __DIR__
                       )

  # Deliberately implausible version numbers, matching
  # test/letflow/tenant_provisioning_test.exs's @guard_probe_version convention --
  # avoids any chance of colliding with a real timestamp-based
  # priv/repo/migrations/ version already recorded in this DB's real
  # public.schema_migrations table. A fresh, unique version per test (via
  # System.unique_integer/1) so repeated runs of this file never collide with a
  # version this same file recorded on a prior run.
  defp unique_drop_migration_version do
    900_000_000 + System.unique_integer([:positive, :monotonic])
  end

  defp ensure_drop_migration_loaded! do
    Code.require_file(@drop_migration_file)
  end

  defp unique_slug, do: Letflow.TenantSlugFixture.unique_slug("req063-idmig")

  # ISS-0111: single fixed lock key shared by every caller in this module
  # (with_only_this_tenant_visible!/2 and restore_orphaned_guard_backup_rows!/0
  # alike) -- see lib/letflow/design/iss0111-with-only-this-tenant-visible-advisory-lock-fix.md
  # section 3.1. Passed to Postgres via hashtext/1, the same idiom
  # lib/letflow/tenant_provisioning.ex already uses for
  # pg_advisory_xact_lock(hashtext($1)). A compile-time literal, not
  # tenant/user input, so it is inlined into the SQL text directly rather than
  # bound as a parameter.
  @guard_lock_key "letflow:test:iss0060_tenant_schemas_guard"

  # ISS-0111 section 3.1: session-scoped, blocking acquire. Must only ever be
  # called from inside a Repo.checkout/2 (or Repo.transaction/2) callback so
  # it lands on the same physical connection release_guard_lock!/0 will later
  # use -- see design section 1's process-pinned-connection finding.
  @spec acquire_guard_lock!() :: :ok
  defp acquire_guard_lock! do
    Repo.query!("SELECT pg_advisory_lock(hashtext($1))", [@guard_lock_key])
    :ok
  end

  # ISS-0111 section 3.1: paired release, issued from the same
  # Repo.checkout/2 callback as the matching acquire_guard_lock!/0 call.
  @spec release_guard_lock!() :: :ok
  defp release_guard_lock! do
    Repo.query!("SELECT pg_advisory_unlock(hashtext($1))", [@guard_lock_key])
    :ok
  end

  # Provisions a real tenant (row + schema + full migration replay, including the
  # three per-tenant identity tables) -- the copy/guard target every test in this
  # file needs. Provisioned via Letflow.TenantFixture (ISS-0112 / GH#366).
  defp provisioned_tenant! do
    %{tenant: tenant, schema_name: schema_name} =
      TenantFixture.provisioned_tenant!(
        slug_prefix: "req063-idmig",
        display_name: "REQ-063 Copy Test"
      )

    %{tenant: tenant, schema_name: schema_name}
  end

  # Recreates minimal (only the columns this file touches), throwaway
  # public.users/groups/tenant_role tables -- see moduledoc for why. Idempotent
  # (CREATE TABLE IF NOT EXISTS) so multiple tests in this file can share one
  # recreation without conflict; on_exit/1 below drops them again.
  defp recreate_legacy_public_tables! do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.groups (
      id uuid PRIMARY KEY,
      tenant_id uuid NOT NULL,
      name text NOT NULL,
      inserted_at timestamp NOT NULL DEFAULT now(),
      updated_at timestamp NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.users (
      id uuid PRIMARY KEY,
      tenant_id uuid NOT NULL,
      username text NOT NULL,
      display_name text NOT NULL,
      email text NOT NULL,
      password_hash text NOT NULL,
      status text NOT NULL DEFAULT 'active',
      auth_source text NOT NULL DEFAULT 'internal',
      external_id text,
      external_realm text,
      inserted_at timestamp NOT NULL DEFAULT now(),
      updated_at timestamp NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.tenant_role (
      id uuid PRIMARY KEY,
      name text NOT NULL,
      group_id uuid NOT NULL,
      inserted_at timestamp NOT NULL DEFAULT now()
    )
    """)

    on_exit(fn ->
      Repo.query!("DROP TABLE IF EXISTS public.tenant_role")
      Repo.query!("DROP TABLE IF EXISTS public.users")
      Repo.query!("DROP TABLE IF EXISTS public.groups")
    end)

    :ok
  end

  defp insert_legacy_group!(tenant_id, name \\ "legacy-group") do
    id = Ecto.UUID.generate()

    Repo.query!("INSERT INTO public.groups (id, tenant_id, name) VALUES ($1, $2, $3)", [
      Ecto.UUID.dump!(id),
      Ecto.UUID.dump!(tenant_id),
      name
    ])

    id
  end

  defp insert_legacy_user!(tenant_id, username \\ nil) do
    id = Ecto.UUID.generate()
    username = username || "legacy-user-#{System.unique_integer([:positive])}"

    Repo.query!(
      """
      INSERT INTO public.users (id, tenant_id, username, display_name, email, password_hash)
      VALUES ($1, $2, $3, $4, $5, $6)
      """,
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(tenant_id),
        username,
        "Legacy User",
        "legacy-#{System.unique_integer([:positive])}@example.com",
        "hash"
      ]
    )

    id
  end

  defp insert_legacy_tenant_role!(group_id, name \\ nil) do
    id = Ecto.UUID.generate()
    name = name || "legacy-role-#{System.unique_integer([:positive])}"

    Repo.query!("INSERT INTO public.tenant_role (id, name, group_id) VALUES ($1, $2, $3)", [
      Ecto.UUID.dump!(id),
      name,
      Ecto.UUID.dump!(group_id)
    ])

    id
  end

  # ISS-0060: crash-durable backup table used by
  # with_only_this_tenant_visible!/2 below to snapshot/restore OTHER tenants'
  # public.tenant_schemas rows around the guard-PROCEEDS test's
  # Ecto.Migrator.run/4 call, so a concurrently-provisioning tenant elsewhere
  # in the suite can never force a false SKIP in that one test. Column set is
  # an exact structural mirror of public.tenant_schemas (see
  # priv/repo/migrations/20260816090045_create_tenant_schemas.exs lines
  # 28-37) so the restore INSERT can be a bare `SELECT *` -- see
  # lib/letflow/design/iss060-migration-guard-test-race-fix.md section 3.
  # Never dropped by on_exit/1: it must survive a BEAM crash to do its job
  # (section 5's crash-safety argument).
  #
  # ISS-0229 section 2.3(a): the inline CONSTRAINT below closes the referential
  # blind spot for FRESH databases. public.tenant_schemas carries
  # tenant_schemas_tenant_id_fkey, so a tenant cannot be deleted while a
  # registry row still points at it -- but a row PARKED here used to carry no
  # such protection, suspending that invariant for every tenant but one for the
  # duration of with_only_this_tenant_visible!/2's critical section. A parked
  # row must carry its protection with it. NO ACTION (no ON DELETE clause) is
  # deliberate: byte-for-byte the same semantics tenant_schemas_tenant_id_fkey
  # already has (ISS-0229 section 2.2 rules out CASCADE -- which would silently
  # vaporise the parked row -- and SET NULL/RESTRICT). The two replay-status
  # columns were appended after provisioned_at with GH #2727 (same order and
  # types as that migration), so this stays the exact structural mirror of
  # public.tenant_schemas that the `SELECT *` restore depends on; a named table
  # constraint adds no column.
  #
  # Because this is CREATE TABLE IF NOT EXISTS, it is a no-op on every database
  # where the table already exists -- those converge via
  # ensure_backup_table_fk!/0 instead. This helper deliberately does NOT call
  # that one; see restore_orphaned_guard_backup_rows!/0 for why the ordering
  # matters.
  @spec ensure_backup_table!() :: :ok
  defp ensure_backup_table! do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.iss060_tenant_schemas_guard_backup (
      id uuid PRIMARY KEY,
      tenant_id uuid NOT NULL,
      schema_name text NOT NULL,
      migrations_applied_at timestamp,
      provisioned_at timestamp NOT NULL,
      migration_replay_failed_at timestamp(0),
      migration_replay_failure_code varchar(255),
      CONSTRAINT iss060_tenant_schemas_guard_backup_tenant_id_fkey
        FOREIGN KEY (tenant_id) REFERENCES public.tenants (id)
    )
    """)

    # GH #2727: databases whose backup table predates the two replay-status
    # columns keep the old five-column shape (the CREATE above is a no-op), which
    # would break the positional `SELECT *` moves. Pre-checked so the common path
    # runs no DDL; ADD COLUMN IF NOT EXISTS so a race cannot fail on a duplicate.
    for column <- [
          "migration_replay_failed_at timestamp(0)",
          "migration_replay_failure_code varchar(255)"
        ] do
      [name | _] = String.split(column, " ")

      Repo.query!("""
      DO $$
      BEGIN
        IF NOT EXISTS (
             SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'public'
               AND table_name = 'iss060_tenant_schemas_guard_backup'
               AND column_name = '#{name}'
           ) THEN
          ALTER TABLE public.iss060_tenant_schemas_guard_backup
            ADD COLUMN IF NOT EXISTS #{column};
        END IF;
      END
      $$
      """)
    end

    :ok
  end

  # ISS-0229 section 2.3(b): convergence path for ALREADY-EXISTING databases,
  # where ensure_backup_table!/0's CREATE TABLE IF NOT EXISTS is a no-op and the
  # table would otherwise never gain the constraint.
  #
  # The pg_constraint pre-check is load-bearing, not decoration: it makes the
  # second and every later call execute no DDL at all, rather than merely
  # swallowing a 42710 after the fact. ALTER TABLE ... ADD CONSTRAINT ... FOREIGN
  # KEY takes ACCESS EXCLUSIVE on the backup table AND SHARE ROW EXCLUSIVE on
  # public.tenants, which conflicts with the ROW EXCLUSIVE every concurrent
  # INSERT/UPDATE/DELETE on tenants holds -- unguarded, it would briefly block
  # every concurrent invocation's tenant writes on every test in this file.
  # Guarded, it is a genuinely one-time cost per database.
  #
  # to_regclass/1 (rather than '...'::regclass) so the block is inert, not an
  # error, if the table somehow does not exist yet. Plain ADD CONSTRAINT, NOT
  # `NOT VALID`: the validating scan is over a table with single-digit rows, and
  # NOT VALID would leave the constraint permanently unvalidated without a second
  # VALIDATE CONSTRAINT while reducing no lock. The check-then-act is not atomic
  # against a concurrent identical ALTER, which is acceptable and bounded: every
  # caller first holds @guard_lock_key, and no code outside this module touches
  # this table.
  @spec ensure_backup_table_fk!() :: :ok
  defp ensure_backup_table_fk! do
    Repo.query!("""
    DO $$
    DECLARE
      v_rel regclass := to_regclass('public.iss060_tenant_schemas_guard_backup');
    BEGIN
      IF v_rel IS NOT NULL AND NOT EXISTS (
           SELECT 1
           FROM pg_constraint
           WHERE conrelid = v_rel
             AND conname  = 'iss060_tenant_schemas_guard_backup_tenant_id_fkey'
         ) THEN
        ALTER TABLE public.iss060_tenant_schemas_guard_backup
          ADD CONSTRAINT iss060_tenant_schemas_guard_backup_tenant_id_fkey
          FOREIGN KEY (tenant_id) REFERENCES public.tenants (id);
      END IF;
    END
    $$;
    """)

    :ok
  end

  # ISS-0229 section 4.1: the single, total move-back statement, defined once as
  # a module attribute so its two call sites
  # (restore_orphaned_guard_backup_rows!/0 and with_only_this_tenant_visible!/2's
  # after block) cannot drift -- they previously held byte-identical copies of a
  # weaker CTE.
  #
  # `taken` empties the backup table UNCONDITIONALLY, exactly as the old CTE's
  # `restored` step did; restorable and unrestorable rows leave by the same
  # DELETE and differ only in whether they are re-inserted. That is what makes
  # the helper total: afterwards the table is empty in every case, so the
  # poisoned state cannot persist. `restorable` expresses "restorable iff the
  # parent tenant is still there"; AS MATERIALIZED (PG 12+) because it is
  # referenced twice. `restored` keeps `INSERT ... SELECT * FROM restorable` with
  # no explicit column list, preserving
  # iss060-migration-guard-test-race-fix.md section 3's column-drift safety --
  # the classification is a FILTER, never an added column, precisely so that
  # stays true. ON CONFLICT (id) DO NOTHING is retained unchanged (the
  # duplicate-PK case ISS-0060 section 6 reasoned about, orthogonal to the FK
  # case). `restored` is never referenced by the outer query and that is fine:
  # PostgreSQL executes data-modifying WITH sub-statements exactly once and
  # always to completion regardless of whether the primary query reads their
  # output. The final SELECT returns exactly the DISCARDED rows (taken minus
  # restorable); NOT IN is safe because restorable.id is the primary key and can
  # never be NULL, and the ::text casts spare the caller any Ecto.UUID handling.
  # Still one statement, hence one implicit transaction -- delete, restore and
  # discard commit together or not at all, so section 5's crash-safety argument
  # carries over verbatim.
  @restore_or_discard_sql """
  WITH taken AS (
    DELETE FROM public.iss060_tenant_schemas_guard_backup
    RETURNING *
  ),
  restorable AS MATERIALIZED (
    SELECT t.*
    FROM taken t
    WHERE EXISTS (SELECT 1 FROM public.tenants tn WHERE tn.id = t.tenant_id)
  ),
  restored AS (
    INSERT INTO public.tenant_schemas
    SELECT * FROM restorable
    ON CONFLICT (id) DO NOTHING
    RETURNING id
  )
  SELECT t.id::text, t.tenant_id::text, t.schema_name
  FROM taken t
  WHERE t.id NOT IN (SELECT id FROM restorable)
  """

  # ISS-0229 section 3.4: the total move-back. Restores every parked row whose
  # parent tenant still exists and DISCARDS every row whose parent is gone,
  # logging each discard. Never raises on an unrestorable row.
  #
  # A row whose parent tenant no longer exists cannot be restored into
  # public.tenant_schemas (tenant_schemas_tenant_id_fkey forbids it) and
  # describes a schema some teardown has already dropped -- it is meaningless
  # data. Discarding it costs nothing; raising costs the enclosing test, and at
  # the setup call site it cost EVERY test in this file, on every run, forever
  # (ISS-0229 section 7: a self-heal wired into setup carries a stricter
  # totality obligation than one called from a test body).
  #
  # Preconditions, which both call sites already satisfy: executing inside a
  # Repo.checkout/2 callback, holding @guard_lock_key.
  @spec restore_or_discard_backup_rows!() :: :ok
  defp restore_or_discard_backup_rows! do
    discarded = run_restore_or_discard_with_one_retry!()

    Enum.each(discarded, fn [id, tenant_id, schema_name] ->
      Logger.warning(
        "ISS-0229: discarded unrestorable guard-backup row id=#{id} " <>
          "tenant_id=#{tenant_id} schema_name=#{schema_name} -- parent tenant " <>
          "no longer exists in public.tenants"
      )
    end)

    :ok
  end

  # ISS-0229 section 3.4's bounded retry: exactly once, on 23503 only.
  #
  # @restore_or_discard_sql is a single statement, so a failure rolled the whole
  # thing back and the rows are still in the backup table -- the retry is a
  # genuine, side-effect-free redo, not a blanket rescue. The only way the first
  # attempt can raise 23503 is section 8.1's snapshot race (a tenant deleted and
  # committed between this statement's snapshot and the FK trigger's own, which
  # is reachable only BEFORE the backup table's own FK has converged); the
  # retry's fresh snapshot then sees the tenant as absent and classifies the row
  # as a discard. Rescuing only :foreign_key_violation, and only once, means a
  # genuine defect (a typo'd column, a missing table, a lock timeout) -- and a
  # 23503 from the retry itself -- still fails loudly.
  @spec run_restore_or_discard_with_one_retry!() :: [[String.t()]]
  defp run_restore_or_discard_with_one_retry! do
    Repo.query!(@restore_or_discard_sql).rows
  rescue
    error in Postgrex.Error ->
      case error do
        %Postgrex.Error{postgres: %{code: :foreign_key_violation}} ->
          Logger.warning(
            "ISS-0229: guard-backup move-back raised a foreign_key_violation " <>
              "(a parent tenant was deleted and committed between this " <>
              "statement's snapshot and the FK trigger's own) -- retrying once " <>
              "with a fresh snapshot"
          )

          Repo.query!(@restore_or_discard_sql).rows

        _other ->
          reraise(error, __STACKTRACE__)
      end
  end

  # ISS-0060 section 5 self-heal: if the backup table is non-empty when any
  # test in this file starts, that non-emptiness IS the signal that a prior
  # run crashed between with_only_this_tenant_visible!/2's move-out and
  # move-back statements -- restore those orphaned rows before the next test
  # proceeds, mirroring ISS-0048's reaper pattern (detect-and-heal-on-next-run
  # rather than an unbounded, growing-until-noticed orphan).
  @spec restore_orphaned_guard_backup_rows!() :: :ok
  defp restore_orphaned_guard_backup_rows! do
    ensure_backup_table!()

    # ISS-0111 section 3.3: this helper must acquire the same @guard_lock_key
    # lock with_only_this_tenant_visible!/2 holds, in its own Repo.checkout/2
    # wrapper, or a genuinely-mid-critical-section invocation's just-moved
    # rows could be seen and restored here while that invocation still
    # believes them safely hidden -- reintroducing the exact race ISS-0060
    # fixed. If no other invocation holds the lock, this proceeds immediately
    # exactly as before (healing any genuinely orphaned rows left by a past
    # crash); if another invocation is genuinely mid-critical-section, this
    # blocks until its release_guard_lock!/0 runs, at which point the backup
    # table is legitimately empty and the restore below is a correct no-op.
    Repo.checkout(fn ->
      acquire_guard_lock!()

      try do
        # ISS-0229 section 3.3: heal FIRST, constrain SECOND. This ordering is
        # load-bearing and reversing it breaks the fix. ALTER TABLE ... ADD
        # CONSTRAINT ... FOREIGN KEY validates existing rows, so on a
        # currently-poisoned database an ALTER attempted BEFORE the heal would
        # itself raise 23503 on the orphan row -- turning the convergence step
        # into a second, new way for setup to fail all 10 tests in this file.
        # Healing first guarantees the table is empty (or holds only restorable
        # rows) when the validating scan runs. This is also why
        # ensure_backup_table_fk!/0 is not folded into ensure_backup_table!/0:
        # that helper is also called from with_only_this_tenant_visible!/2 and
        # directly from a test, neither of which is preceded by a heal.
        #
        # Both steps run while @guard_lock_key is held, on the single connection
        # pinned by Repo.checkout/2, so a concurrent invocation of this module
        # can be neither mid-move-out during the ALTER nor racing the
        # pg_constraint pre-check.
        restore_or_discard_backup_rows!()
        ensure_backup_table_fk!()

        :ok
      after
        release_guard_lock!()
      end
    end)
  end

  # ISS-0060: wraps `fun` (the guarded Ecto.Migrator.run/4 call plus its
  # follow-up assertions) so that, for the duration of `fun`, public.tenant_schemas
  # contains at most one row -- `tenant_id`'s own row. Every other tenant's row is
  # moved out (single atomic data-modifying CTE, one round trip -- no
  # Elixir-side window between snapshot and delete) into the crash-durable
  # backup table for the duration of `fun`, then moved back (another single
  # atomic CTE) in an `after` block so the restore runs whether `fun` succeeds
  # or raises. See design section 4 for the full sequence/rationale.
  defp with_only_this_tenant_visible!(tenant_id, fun) do
    # ISS-0111 section 3.2: the entire body executes inside one
    # Repo.checkout/2 call -- this pins one physical connection to the
    # calling process for the whole critical section (lock acquire ->
    # move-out -> fun.() -> move-back -> lock release), which is what makes
    # the guard lock's acquire and release land on the same Postgres
    # session (design section 1's finding). Repo.checkout/2's callback is a
    # zero-arity function returning its result directly (confirmed against
    # deps/ecto/lib/ecto/repo.ex's generated checkout/2 -- no special
    # return-value wrapping), so this preserves this function's existing
    # contract unchanged: it returns whatever fun.() returns, and propagates
    # any exception fun.() raises after running its cleanup, exactly as the
    # previous bare try/after did (design section 5).
    Repo.checkout(fn ->
      ensure_backup_table!()

      acquire_guard_lock!()

      try do
        Repo.query!(
          """
          WITH moved AS (
            DELETE FROM public.tenant_schemas
            WHERE tenant_id <> $1
            RETURNING *
          )
          INSERT INTO public.iss060_tenant_schemas_guard_backup
          SELECT * FROM moved
          """,
          [Ecto.UUID.dump!(tenant_id)]
        )

        try do
          fun.()
        after
          # ISS-0229 section 4.2: this site ran a byte-identical copy of the old
          # move-back CTE against the same table under the same conditions, and
          # it is in fact the FIRST site to raise in the real sequence -- a
          # concurrent teardown destroys the tenant while this snapshot is held,
          # so the very next thing to touch the row is this move-back, whose
          # 23503 is what strands the row in the first place (setup's failure on
          # every later run is the second-order symptom). Fixing only setup would
          # leave this raising from an `after` block mid-test, masking the test's
          # real result. Same total helper, same discard rule.
          #
          # Note this site deliberately does NOT call ensure_backup_table_fk!/0:
          # convergence belongs to the composed heal-then-constrain entry point
          # (section 3.3), not to the middle of a critical section.
          restore_or_discard_backup_rows!()
        end
      after
        release_guard_lock!()
      end
    end)
  end

  defp tenant_schema_has_row?(schema_name, table, id) do
    sql = "SELECT count(*) FROM \"#{schema_name}\".\"#{table}\" WHERE id = $1"
    %{rows: [[count]]} = Repo.query!(sql, [Ecto.UUID.dump!(id)])

    count == 1
  end

  defp count_rows_in_schema(schema_name, table) do
    sql = "SELECT count(*) FROM \"#{schema_name}\".\"#{table}\""
    %{rows: [[count]]} = Repo.query!(sql)
    count
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)
    recreate_legacy_public_tables!()
    restore_orphaned_guard_backup_rows!()
    :ok
  end

  describe "IdentityMigration.copy_tenant/2 and copy_all_tenants/0 (REQ-063 §4)" do
    test "copies groups/users/tenant_role from public into the tenant's own schema, preserving id, ordering tenant_role after groups (FK dependency)" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()

      group_id = insert_legacy_group!(tenant.id)
      user_id = insert_legacy_user!(tenant.id)
      role_id = insert_legacy_tenant_role!(group_id)

      assert {:ok, %{groups: 1, users: 1, tenant_roles: 1}} =
               IdentityMigration.copy_tenant(tenant.id, schema_name)

      assert tenant_schema_has_row?(schema_name, "groups", group_id)
      assert tenant_schema_has_row?(schema_name, "users", user_id)
      assert tenant_schema_has_row?(schema_name, "tenant_role", role_id)
    end

    test "copy_tenant/2 is idempotent: re-running after a successful copy re-copies nothing (on_conflict: :nothing), same counts settle at zero on the second call" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()

      group_id = insert_legacy_group!(tenant.id)
      _user_id = insert_legacy_user!(tenant.id)
      _role_id = insert_legacy_tenant_role!(group_id)

      assert {:ok, %{groups: 1, users: 1, tenant_roles: 1}} =
               IdentityMigration.copy_tenant(tenant.id, schema_name)

      # Second call: on_conflict: :nothing + conflict_target: :id means every row
      # is already present, so every insert this time is suppressed. The public
      # legacy rows are unchanged (this function never deletes them), so the
      # query result set is identical -- the function's OWN counter increments
      # on every attempted insert (the design's copy_tenant/2 body counts
      # {:ok, _} results from Repo.insert/2, which on_conflict: :nothing still
      # returns even when suppressed -- see identity.ex's own documented finding
      # that a client-generated-id insert can't distinguish a real vs suppressed
      # insert from the bare {:ok, _} shape alone), so this asserts the
      # functionally important invariant instead: re-running does not raise, and
      # the destination schema still has exactly one row of each kind (not
      # duplicated).
      assert {:ok, _} = IdentityMigration.copy_tenant(tenant.id, schema_name)

      assert count_rows_in_schema(schema_name, "groups") == 1
      assert count_rows_in_schema(schema_name, "users") == 1
      assert count_rows_in_schema(schema_name, "tenant_role") == 1
    end

    test "copy_all_tenants/0 processes every registered tenant and aggregates counts" do
      %{tenant: tenant_a, schema_name: schema_a} = provisioned_tenant!()
      %{tenant: tenant_b, schema_name: schema_b} = provisioned_tenant!()

      group_a = insert_legacy_group!(tenant_a.id)
      _user_a = insert_legacy_user!(tenant_a.id)
      insert_legacy_tenant_role!(group_a)

      group_b = insert_legacy_group!(tenant_b.id)
      insert_legacy_tenant_role!(group_b)

      assert {:ok, summary} = IdentityMigration.copy_all_tenants()

      assert summary.tenants_processed >= 2
      assert summary.groups_copied >= 2
      assert summary.users_copied >= 1
      assert summary.tenant_roles_copied >= 2

      assert count_rows_in_schema(schema_a, "groups") == 1
      assert count_rows_in_schema(schema_b, "groups") == 1
    end

    test "an orphaned tenant_role (group_id matching no groups row) aborts that tenant's copy with {:error, {:orphaned_tenant_role, id}}, and no partial rows are committed for that tenant" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()

      # A tenant_role whose group_id matches no public.groups row at all -- the
      # design's own documented "should not exist given the FK constraint on the
      # current public schema, but the copy function must not silently drop data
      # if one somehow does" case (design §4 step 3). This file's throwaway
      # public.tenant_role table has no FK constraint (deliberately, so this
      # exact scenario can be constructed), unlike the real, now-dropped
      # migration-created one.
      orphan_group_id = Ecto.UUID.generate()
      orphan_role_id = insert_legacy_tenant_role!(orphan_group_id)

      assert {:error, {:orphaned_tenant_role, ^orphan_role_id}} =
               IdentityMigration.copy_tenant(tenant.id, schema_name)

      # Repo.transaction/1 wraps copy_tenant/2's body in copy_all_tenants/0 (not
      # exercised directly here, but copy_tenant/2 itself is called directly by
      # this test) -- confirm no tenant_role row landed in the tenant schema as a
      # side effect of the aborted copy.
      assert count_rows_in_schema(schema_name, "tenant_role") == 0
    end
  end

  describe "DropLegacyPublicIdentityTables migration guard (REQ-063 §5) -- skip-on-uncopied-row" do
    test "an uncopied row (present in public, absent from the tenant's schema copy) makes the guard SKIP the drop entirely -- all three public tables survive" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()

      # Fully copy groups/users/tenant_role FIRST (a clean, complete copy)...
      group_id = insert_legacy_group!(tenant.id)
      insert_legacy_user!(tenant.id)
      insert_legacy_tenant_role!(group_id)

      assert {:ok, %{groups: 1, users: 1, tenant_roles: 1}} =
               IdentityMigration.copy_tenant(tenant.id, schema_name)

      # ...then insert ONE MORE public.users row directly (bypassing
      # copy_tenant/2 entirely) -- simulating a row that arrived/was missed
      # after the copy ran, present in public but genuinely absent from the
      # tenant's schema copy. An uncopied row in exactly one of the three
      # tables must still block the drop for ALL THREE tables (the migration's
      # own documented "skipped entirely for ALL THREE tables... rather than
      # partially dropping" behavior), not just the table with the gap.
      _uncopied_user_id = insert_legacy_user!(tenant.id)

      ensure_drop_migration_loaded!()
      version = unique_drop_migration_version()

      on_exit(fn ->
        Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [version])
      end)

      assert [^version] =
               Ecto.Migrator.run(
                 Letflow.Repo,
                 [{version, Letflow.Repo.Migrations.DropLegacyPublicIdentityTables}],
                 :up,
                 all: true,
                 log: false
               )

      # The guard skipped: all three legacy public tables must still exist.
      for table <- ["groups", "users", "tenant_role"] do
        %{rows: [[regclass]]} = Repo.query!("SELECT to_regclass('public.#{table}')::text")
        assert regclass != nil, "expected public.#{table} to survive the skipped drop"
      end

      # And both public.users rows (the copied one and the uncopied one) are
      # still exactly where they were -- nothing lost.
      %{rows: [[users_count]]} = Repo.query!("SELECT count(*) FROM public.users")
      assert users_count == 2
    end

    test "once the copy is completed for every registered tenant, the guard PROCEEDS and drops all three public tables" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()

      group_id = insert_legacy_group!(tenant.id)
      insert_legacy_user!(tenant.id)
      insert_legacy_tenant_role!(group_id)

      assert {:ok, %{groups: 1, users: 1, tenant_roles: 1}} =
               IdentityMigration.copy_tenant(tenant.id, schema_name)

      ensure_drop_migration_loaded!()
      version = unique_drop_migration_version()

      on_exit(fn ->
        Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [version])
      end)

      # ISS-0060: only this test's own tenant may be visible in
      # public.tenant_schemas for the duration of the guarded migration run --
      # otherwise a concurrently-provisioning tenant elsewhere in the suite
      # (registered but not yet copied) can make the guard's global per-tenant
      # scan see an uncopied row that has nothing to do with this test and
      # flip a correct PROCEED into a false SKIP. See
      # lib/letflow/design/iss060-migration-guard-test-race-fix.md.
      with_only_this_tenant_visible!(tenant.id, fn ->
        assert [^version] =
                 Ecto.Migrator.run(
                   Letflow.Repo,
                   [{version, Letflow.Repo.Migrations.DropLegacyPublicIdentityTables}],
                   :up,
                   all: true,
                   log: false
                 )

        # The guard proceeded: all three legacy public tables are gone.
        for table <- ["groups", "users", "tenant_role"] do
          %{rows: [[regclass]]} = Repo.query!("SELECT to_regclass('public.#{table}')::text")
          assert regclass == nil, "expected public.#{table} to be dropped"
        end
      end)

      # Recreate them immediately so this test's own on_exit/1 cleanup (which
      # unconditionally issues DROP TABLE IF EXISTS) and any other test in this
      # file relying on recreate_legacy_public_tables!/0's CREATE TABLE IF NOT
      # EXISTS still behave correctly regardless of ExUnit's test ordering
      # within this describe block.
      recreate_legacy_public_tables!()
    end

    test "ISS-0050 regression: a tenant schema missing one identity table makes the guard SKIP the drop, not raise 42P01" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()

      # Simulate the ISS-0050 scenario: a tenant_schemas registry row exists and
      # its schema is genuinely CREATE SCHEMA'd (provisioned_tenant!/0 already did
      # both), but ONE of the three identity tables the guard's dynamic
      # EXECUTE format('%I.<table>', ...) touches is missing from that schema --
      # e.g. TenantProvisioning.replay_migrations/2 was interrupted mid-flight
      # before creating it, or a leaked fixture row's schema was never fully
      # replayed. Dropping the tenant's own groups table directly reproduces
      # exactly that physical shape without needing to fabricate a whole
      # incomplete-replay code path.
      Repo.query!(~s(DROP TABLE IF EXISTS "#{schema_name}".groups CASCADE))

      ensure_drop_migration_loaded!()
      version = unique_drop_migration_version()

      on_exit(fn ->
        Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [version])
      end)

      # Pre-fix, this Ecto.Migrator.run/4 call itself raises
      # `** (Postgrex.Error) ERROR 42P01 (undefined_table) relation
      # "<schema>.groups" does not exist` from inside the guard's dynamic EXECUTE
      # -- see ISSUE-FIXER's diagnosis in
      # handoffs/WF03-ISS0050-20260818/step-01-issue-fixer.json. Post-fix, the
      # guard's to_regclass(...) IS NULL existence check catches the missing
      # table first, logs a RAISE NOTICE, and folds it into v_all_copied := FALSE
      # instead -- so this call must complete normally and return the applied
      # version, exactly like the "skip-on-uncopied-row" test above.
      assert [^version] =
               Ecto.Migrator.run(
                 Letflow.Repo,
                 [{version, Letflow.Repo.Migrations.DropLegacyPublicIdentityTables}],
                 :up,
                 all: true,
                 log: false
               )

      # The guard skipped: all three legacy public tables must still exist (same
      # "skip, don't partially drop" invariant as the uncopied-row test above).
      for table <- ["groups", "users", "tenant_role"] do
        %{rows: [[regclass]]} = Repo.query!("SELECT to_regclass('public.#{table}')::text")
        assert regclass != nil, "expected public.#{table} to survive the skipped drop"
      end
    end
  end

  # ISS-0060: end-to-end proof that with_only_this_tenant_visible!/2 fixes the
  # reported bug, not just that its helper functions individually behave.
  # Reproduces the exact race first: a second, real (FK-satisfying) tenant row
  # registered in public.tenant_schemas with migrations_applied_at still NULL
  # (i.e. mid-copy, exactly what a concurrently-running provisioning test looks
  # like) makes the unwrapped guard's global per-tenant scan see an uncopied
  # row that has nothing to do with this test and false-SKIP the drop. Then
  # re-runs the identical scenario wrapped in with_only_this_tenant_visible!/2
  # and shows the guard now PROCEEDS, and that the racer's row is restored
  # to public.tenant_schemas afterward, untouched (still NULL), with the
  # backup table left empty. See
  # lib/letflow/design/iss060-migration-guard-test-race-fix.md.
  describe "ISS-0060: with_only_this_tenant_visible!/2 guard fix" do
    test "hides the racer tenant, flips guard SKIP into PROCEED" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()

      group_id = insert_legacy_group!(tenant.id)
      insert_legacy_user!(tenant.id)
      insert_legacy_tenant_role!(group_id)

      assert {:ok, %{groups: 1, users: 1, tenant_roles: 1}} =
               IdentityMigration.copy_tenant(tenant.id, schema_name)

      # ISS-0060's exact race condition, constructed directly rather than
      # relying on genuine test-suite concurrency to hit the window by luck:
      # a second, real (FK-satisfying) tenant row is registered in
      # public.tenant_schemas but its copy is still in flight --
      # migrations_applied_at is NULL, exactly what a concurrently-running
      # provisioning test looks like mid-flight.
      racer_tenant =
        %Tenant{}
        |> Tenant.create_changeset(
          %{slug: unique_slug(), display_name: "ISS-0060 racer"},
          :disabled
        )
        |> Repo.insert!()

      on_exit(fn ->
        # tenant_schemas.tenant_id carries a real DB foreign key to
        # tenants.id -- delete the (by then restored) tenant_schemas row
        # first, or this Tenant delete would raise a foreign-key violation.
        Repo.query!("DELETE FROM public.tenant_schemas WHERE tenant_id = $1", [
          Ecto.UUID.dump!(racer_tenant.id)
        ])

        Repo.delete_all(from(t in Tenant, where: t.id == ^racer_tenant.id))
      end)

      racer_schema_row_id = Ecto.UUID.generate()

      Repo.query!(
        """
        INSERT INTO public.tenant_schemas
          (id, tenant_id, schema_name, migrations_applied_at, provisioned_at)
        VALUES ($1, $2, $3, NULL, now())
        """,
        [
          Ecto.UUID.dump!(racer_schema_row_id),
          Ecto.UUID.dump!(racer_tenant.id),
          "iss0060_fake_racer_schema"
        ]
      )

      ensure_drop_migration_loaded!()

      # Step 1: reproduce the bug, live. With the racer's incomplete row
      # genuinely visible in public.tenant_schemas and nothing hiding it, the
      # guard's own global per-tenant scan sees an uncopied tenant that has
      # NOTHING to do with this test and folds it into v_all_copied := FALSE
      # -- a false SKIP, exactly ISS-0060's reported failure mode, reproduced
      # on demand rather than asserted from memory or from suite-timing luck.
      version_unwrapped = unique_drop_migration_version()

      on_exit(fn ->
        Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [version_unwrapped])
      end)

      assert [^version_unwrapped] =
               Ecto.Migrator.run(
                 Letflow.Repo,
                 [{version_unwrapped, Letflow.Repo.Migrations.DropLegacyPublicIdentityTables}],
                 :up,
                 all: true,
                 log: false
               )

      for table <- ["groups", "users", "tenant_role"] do
        %{rows: [[regclass]]} = Repo.query!("SELECT to_regclass('public.#{table}')::text")

        assert regclass != nil,
               "expected public.#{table} to survive -- unwrapped guard should have " <>
                 "false-SKIPped because of the racer's uncopied row"
      end

      # Step 2: same fake racer row, still sitting in public.tenant_schemas,
      # completely untouched -- but this run is wrapped in the fix's
      # with_only_this_tenant_visible!/2. The guard now PROCEEDS, because the
      # racer's row is moved out of public.tenant_schemas for the duration of
      # the guarded call, so the guard's scan only ever sees this test's own
      # fully-copied tenant.
      version_wrapped = unique_drop_migration_version()

      on_exit(fn ->
        Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [version_wrapped])
      end)

      with_only_this_tenant_visible!(tenant.id, fn ->
        assert [^version_wrapped] =
                 Ecto.Migrator.run(
                   Letflow.Repo,
                   [{version_wrapped, Letflow.Repo.Migrations.DropLegacyPublicIdentityTables}],
                   :up,
                   all: true,
                   log: false
                 )

        for table <- ["groups", "users", "tenant_role"] do
          %{rows: [[regclass]]} = Repo.query!("SELECT to_regclass('public.#{table}')::text")

          assert regclass == nil,
                 "expected public.#{table} to be dropped -- with_only_this_tenant_visible!/2 " <>
                   "should have hidden the racer's row for the duration of this call"
        end
      end)

      recreate_legacy_public_tables!()

      # The racer's row must be exactly as it was before the wrap -- restored
      # to public.tenant_schemas, migrations_applied_at still NULL (untouched,
      # not silently "completed"), and the backup table left empty. This is
      # the exact behavior the pre-fix code had no mechanism for at all (it
      # never moved anything, so there was nothing to restore).
      %{rows: [[restored_count]]} =
        Repo.query!(
          """
          SELECT count(*) FROM public.tenant_schemas
          WHERE id = $1 AND tenant_id = $2 AND migrations_applied_at IS NULL
          """,
          [Ecto.UUID.dump!(racer_schema_row_id), Ecto.UUID.dump!(racer_tenant.id)]
        )

      assert restored_count == 1

      %{rows: [[backup_count]]} =
        Repo.query!("SELECT count(*) FROM public.iss060_tenant_schemas_guard_backup")

      assert backup_count == 0
    end
  end

  describe "DropLegacyPublicIdentityTables migration guard (REQ-063 §5) -- idempotency" do
    # No tenant/copy needed for this one -- exercises the migration's own
    # "already absent -- nothing to do" RAISE NOTICE branch directly, i.e.
    # re-running the drop after it already succeeded is a clean no-op per its
    # own to_regclass IS NULL guard.
    test "re-running after it already succeeded is a no-op" do
      Repo.query!("DROP TABLE IF EXISTS public.tenant_role")
      Repo.query!("DROP TABLE IF EXISTS public.users")
      Repo.query!("DROP TABLE IF EXISTS public.groups")

      ensure_drop_migration_loaded!()
      version = unique_drop_migration_version()

      on_exit(fn ->
        Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [version])
      end)

      assert [^version] =
               Ecto.Migrator.run(
                 Letflow.Repo,
                 [{version, Letflow.Repo.Migrations.DropLegacyPublicIdentityTables}],
                 :up,
                 all: true,
                 log: false
               )

      for table <- ["groups", "users", "tenant_role"] do
        %{rows: [[regclass]]} = Repo.query!("SELECT to_regclass('public.#{table}')::text")
        assert regclass == nil
      end

      recreate_legacy_public_tables!()
    end
  end

  # ISS-0060: restore_orphaned_guard_backup_rows!/0 is the exact helper this
  # file's own test setup calls to self-heal after a crash mid-guard (one that
  # dies after moving a row into the backup table but before restoring it).
  # Proves it restores a stale backup row back to public.tenant_schemas and
  # leaves the backup table empty afterward -- exercised directly here rather
  # than only indirectly via setup, so a regression in the helper itself fails
  # with a clear signal instead of surfacing as unrelated failures elsewhere.
  describe "ISS-0060: self-heal of an interrupted guard run" do
    test "restore_orphaned_guard_backup_rows!/0 restores the stale row" do
      # A real, FK-satisfying tenant with no tenant_schemas row of its own yet
      # (deliberately NOT provisioned_tenant!/0 -- provisioning would insert
      # tenant_schemas' own row for it, and tenant_schemas has a unique index
      # on tenant_id, which would make the restore below collide).
      orphan_owner =
        %Tenant{}
        |> Tenant.create_changeset(
          %{slug: unique_slug(), display_name: "ISS-0060 self-heal owner"},
          :disabled
        )
        |> Repo.insert!()

      on_exit(fn ->
        # tenant_schemas.tenant_id carries a real DB foreign key to
        # tenants.id -- delete the (by then restored) tenant_schemas row
        # first, or this Tenant delete would raise a foreign-key violation.
        # Single on_exit callback covering both deletes in the correct order
        # so this cleanup does not depend on ExUnit's on_exit ordering.
        Repo.query!("DELETE FROM public.tenant_schemas WHERE tenant_id = $1", [
          Ecto.UUID.dump!(orphan_owner.id)
        ])

        Repo.delete_all(from(t in Tenant, where: t.id == ^orphan_owner.id))
      end)

      ensure_backup_table!()

      stale_id = Ecto.UUID.generate()

      # Simulate exactly the crash window design section 5 describes: a
      # process died between with_only_this_tenant_visible!/2's move-out
      # (which already committed, atomically, per its own single CTE) and its
      # move-back -- leaving a row sitting in the backup table with no
      # corresponding row in public.tenant_schemas.
      Repo.query!(
        """
        INSERT INTO public.iss060_tenant_schemas_guard_backup
          (id, tenant_id, schema_name, migrations_applied_at, provisioned_at)
        VALUES ($1, $2, $3, NULL, now())
        """,
        [
          Ecto.UUID.dump!(stale_id),
          Ecto.UUID.dump!(orphan_owner.id),
          "iss0060_stale_backup_schema"
        ]
      )

      %{rows: [[pre_heal_visible_count]]} =
        Repo.query!("SELECT count(*) FROM public.tenant_schemas WHERE id = $1", [
          Ecto.UUID.dump!(stale_id)
        ])

      assert pre_heal_visible_count == 0,
             "sanity check: the stale row must not already be visible in tenant_schemas"

      # This file's own `setup` block (see setup/0 above) calls
      # restore_orphaned_guard_backup_rows!/0 unconditionally before every
      # test in this file -- this call exercises that exact same helper
      # directly, rather than relying on a second, later test run to observe
      # its effect, since the stale row above could only be constructed
      # *after* this test's own setup had already run once.
      restore_orphaned_guard_backup_rows!()

      %{rows: [[post_heal_visible_count]]} =
        Repo.query!(
          "SELECT count(*) FROM public.tenant_schemas WHERE id = $1 AND tenant_id = $2 AND migrations_applied_at IS NULL",
          [Ecto.UUID.dump!(stale_id), Ecto.UUID.dump!(orphan_owner.id)]
        )

      assert post_heal_visible_count == 1

      %{rows: [[backup_count]]} =
        Repo.query!(
          "SELECT count(*) FROM public.iss060_tenant_schemas_guard_backup WHERE id = $1",
          [
            Ecto.UUID.dump!(stale_id)
          ]
        )

      assert backup_count == 0
    end
  end

  # ISS-0229 section 5: regression coverage for the guard-backup table's
  # referential blind spot. A row parked in
  # public.iss060_tenant_schemas_guard_backup had no foreign key of its own
  # while public.tenant_schemas.tenant_id did, so a concurrent teardown could
  # destroy the parked row's parent tenant; the move-back then raised 23503 and
  # -- because it runs from this file's own setup -- failed every test in this
  # file, permanently, on every later run.
  #
  # The failing state cannot be built by simply INSERTing an orphan row once the
  # constraint exists (the seeding INSERT would itself raise 23503). These tests
  # therefore reproduce the real pre-convergence shape -- constraint dropped,
  # orphan parked -- exactly as ISS-0229 section 5.1 prescribes.
  #
  # Nothing here names ensure_backup_table_fk!/0 or
  # restore_or_discard_backup_rows!/0 (section 5.1.1's naming rule): the block
  # names only helpers that already existed before the fix, so it still compiles
  # against reverted helper bodies and the fail-first demonstration is a
  # behavioural 23503 rather than a compile error. Everything the new helpers
  # own is observed without naming them -- constraint presence, confdeltype and
  # enforcement are read straight out of pg_constraint / proven by a rejected
  # INSERT.
  #
  # Cleanup follows section 5.1.1's mandated three-callback shape. on_exit/1 is
  # LIFO (ExUnit.OnExitHandler.add/3 appends, run/2 reverses), so callbacks are
  # registered in the reverse of the order they must run: (A) first, carrying
  # step 4; (B) after the real Tenant insert, carrying steps 2-3; (C) after the
  # backup-row ids exist and before any DDL/DML, carrying step 1. Execution is
  # (C) -> (B) -> (A) = backup rows removed, then the tenant, then
  # heal-then-constrain last over an already-empty table -- which is the
  # precondition the validating ALTER needs. Each is a BARE on_exit/1 with no
  # name argument: ExUnit.OnExitHandler.add/3 keys on name_or_ref, so reusing a
  # name would silently REPLACE the previous callback instead of appending and
  # collapse the whole scheme.
  describe "ISS-0229: total guard-backup heal" do
    test "orphan discarded+logged, live row restored, FK converged and enforced" do
      # (A) -- cleanup step 4. Registered before anything else in the body so it
      # runs however early the body fails, and runs LAST. It is deliberately
      # restore_orphaned_guard_backup_rows!/0, the composed heal-then-constrain
      # entry point, never a direct ALTER: healing first is what stops the
      # validating scan from raising 23503 on anything still parked.
      on_exit(fn -> restore_orphaned_guard_backup_rows!() end)

      # A real, FK-satisfying tenant with no tenant_schemas row of its own
      # (deliberately not provisioned_tenant!/0 -- tenant_schemas has a UNIQUE
      # index on tenant_id, which a provisioned tenant's own row would collide
      # with when the restorable backup row below is moved back). Its id is only
      # knowable after the insert: Tenant's :id is autogenerate: true and is not
      # castable by create_changeset/3.
      live_owner =
        %Tenant{}
        |> Tenant.create_changeset(
          %{slug: unique_slug(), display_name: "ISS-0229 restorable owner"},
          :disabled
        )
        |> Repo.insert!()

      # (B) -- cleanup steps 2 and 3, in that order: the restored
      # tenant_schemas row carries a real FK to tenants.id, so it must go first.
      on_exit(fn ->
        Repo.query!("DELETE FROM public.tenant_schemas WHERE tenant_id = $1", [
          Ecto.UUID.dump!(live_owner.id)
        ])

        Repo.delete_all(from(t in Tenant, where: t.id == ^live_owner.id))
      end)

      # Every id this test can put into the backup table, generated BEFORE any
      # DDL or DML so cleanup step 1 covers them regardless of how far the body
      # got. Ecto.UUID.generate/0 touches no database.
      orphan_id = Ecto.UUID.generate()
      absent_tenant_id = Ecto.UUID.generate()
      restorable_id = Ecto.UUID.generate()
      rejected_id = Ecto.UUID.generate()

      seeded_backup_ids =
        Enum.map([orphan_id, restorable_id, rejected_id], &Ecto.UUID.dump!/1)

      # (C) -- cleanup step 1, closing over the FULL pre-generated id list, not
      # over whatever the body managed to insert. A targeted DELETE on the
      # REFERENCING side is never FK-checked, so this cannot raise whatever
      # state the body left, and ids that were never inserted are a no-op.
      on_exit(fn ->
        Repo.query!(
          "DELETE FROM public.iss060_tenant_schemas_guard_backup WHERE id = ANY($1)",
          [seeded_backup_ids]
        )
      end)

      ensure_backup_table!()

      %{rows: [[absent_parent_count]]} =
        Repo.query!("SELECT count(*) FROM public.tenants WHERE id = $1", [
          Ecto.UUID.dump!(absent_tenant_id)
        ])

      assert absent_parent_count == 0,
             "fixture premise: the orphan's parent tenant must genuinely not exist"

      Repo.query!("""
      ALTER TABLE public.iss060_tenant_schemas_guard_backup
        DROP CONSTRAINT IF EXISTS iss060_tenant_schemas_guard_backup_tenant_id_fkey
      """)

      orphan_schema_name = "iss0229_orphan_" <> String.replace(orphan_id, "-", "")
      restorable_schema_name = "iss0229_restorable_" <> String.replace(restorable_id, "-", "")
      provisioned_at = ~N[2026-08-22 12:34:56]
      migrations_applied_at = ~N[2026-08-22 12:35:57]

      insert_backup_row = fn id, tenant_id, schema_name ->
        Repo.query!(
          """
          INSERT INTO public.iss060_tenant_schemas_guard_backup
            (id, tenant_id, schema_name, migrations_applied_at, provisioned_at)
          VALUES ($1, $2, $3, $4, $5)
          """,
          [
            Ecto.UUID.dump!(id),
            Ecto.UUID.dump!(tenant_id),
            schema_name,
            migrations_applied_at,
            provisioned_at
          ]
        )
      end

      # Both rows seeded in the SAME call, so the assertions below also prove
      # the restore/discard classification is per-row, not per-call.
      insert_backup_row.(orphan_id, absent_tenant_id, orphan_schema_name)
      insert_backup_row.(restorable_id, live_owner.id, restorable_schema_name)

      # Assertion 1 (no raise) + assertion 4 (the discard is logged and names
      # the row). Pre-fix this call raises Postgrex.Error 23503 from
      # tenant_schemas_tenant_id_fkey.
      discard_log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert restore_orphaned_guard_backup_rows!() == :ok
        end)

      assert discard_log =~ orphan_id
      assert discard_log =~ absent_tenant_id

      # Assertion 2: discarded, not left parked.
      %{rows: [[orphan_backup_count]]} =
        Repo.query!(
          "SELECT count(*) FROM public.iss060_tenant_schemas_guard_backup WHERE id = $1",
          [Ecto.UUID.dump!(orphan_id)]
        )

      assert orphan_backup_count == 0

      # Assertion 3: discarded, not force-inserted into tenant_schemas.
      %{rows: [[orphan_visible_count]]} =
        Repo.query!("SELECT count(*) FROM public.tenant_schemas WHERE tenant_id = $1", [
          Ecto.UUID.dump!(absent_tenant_id)
        ])

      assert orphan_visible_count == 0

      # Assertion 5, the anti-regression that matters most: a row whose parent
      # genuinely exists is still RESTORED, with every column preserved. An
      # implementation that simply DELETEs the whole backup table passes 1-4
      # while destroying live data; it cannot pass this.
      %{rows: [[got_tenant_id, got_schema_name, got_migrations_applied_at, got_provisioned_at]]} =
        Repo.query!(
          """
          SELECT tenant_id::text, schema_name, migrations_applied_at, provisioned_at
          FROM public.tenant_schemas
          WHERE id = $1
          """,
          [Ecto.UUID.dump!(restorable_id)]
        )

      assert got_tenant_id == live_owner.id
      assert got_schema_name == restorable_schema_name
      assert got_migrations_applied_at == migrations_applied_at
      assert got_provisioned_at == provisioned_at

      %{rows: [[restorable_backup_count]]} =
        Repo.query!(
          "SELECT count(*) FROM public.iss060_tenant_schemas_guard_backup WHERE id = $1",
          [Ecto.UUID.dump!(restorable_id)]
        )

      assert restorable_backup_count == 0

      # Assertion 6: the FK converged, and it is the RIGHT one. confdeltype 'a'
      # is NO ACTION -- asserting it is what stops a later "fix" from quietly
      # switching to CASCADE, which section 2.2 rejects.
      %{rows: [[contype, references_tenants, confdeltype, convalidated]]} =
        Repo.query!("""
        SELECT contype::text,
               (confrelid = 'public.tenants'::regclass),
               confdeltype::text,
               convalidated
        FROM pg_constraint
        WHERE conrelid = 'public.iss060_tenant_schemas_guard_backup'::regclass
          AND conname = 'iss060_tenant_schemas_guard_backup_tenant_id_fkey'
        """)

      assert contype == "f"
      assert references_tenants == true
      assert confdeltype == "a"
      assert convalidated == true

      # Assertion 7: the FK is actually ENFORCED (not left NOT VALID) -- the
      # very INSERT that succeeded above, replayed against an absent parent, is
      # now rejected. Repo.query/3 (non-bang) so the rejection is asserted
      # rather than aborting the test.
      assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
               Repo.query(
                 """
                 INSERT INTO public.iss060_tenant_schemas_guard_backup
                   (id, tenant_id, schema_name, migrations_applied_at, provisioned_at)
                 VALUES ($1, $2, $3, NULL, now())
                 """,
                 [
                   Ecto.UUID.dump!(rejected_id),
                   Ecto.UUID.dump!(absent_tenant_id),
                   "iss0229_rejected_" <> String.replace(rejected_id, "-", "")
                 ]
               )

      # Assertion 8: idempotence -- a second call is a no-op, discards nothing
      # (so logs nothing), and does not add a second constraint.
      second_log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert restore_orphaned_guard_backup_rows!() == :ok
        end)

      refute second_log =~ "discarded unrestorable guard-backup row"

      %{rows: [[constraint_count]]} =
        Repo.query!("""
        SELECT count(*)
        FROM pg_constraint
        WHERE conrelid = 'public.iss060_tenant_schemas_guard_backup'::regclass
          AND conname = 'iss060_tenant_schemas_guard_backup_tenant_id_fkey'
        """)

      assert constraint_count == 1
    end

    # Assertion 9 (section 4.2): the SECOND call site inherits the totality.
    # This is in fact the first site to raise in the real sequence -- the
    # concurrent teardown destroys the tenant while this critical section holds
    # its snapshot, so the move-back in the inner `after` block is what strands
    # the row; setup's failure on every later run is the second-order symptom.
    #
    # This path deliberately does NOT converge the constraint (section 3.3), so
    # it finishes with the constraint still dropped -- which is exactly why the
    # full three-callback cleanup, and in particular step 4, is mandatory here:
    # a test that asserts this property and leaves the constraint off would
    # silently disarm the FK for every test that runs after it.
    test "with_only_this_tenant_visible!/2 completes with an orphan parked" do
      # (A) -- cleanup step 4, and the only thing that puts the constraint back.
      on_exit(fn -> restore_orphaned_guard_backup_rows!() end)

      focus_tenant =
        %Tenant{}
        |> Tenant.create_changeset(
          %{slug: unique_slug(), display_name: "ISS-0229 visibility focus"},
          :disabled
        )
        |> Repo.insert!()

      # (B) -- cleanup steps 2 and 3.
      on_exit(fn ->
        Repo.query!("DELETE FROM public.tenant_schemas WHERE tenant_id = $1", [
          Ecto.UUID.dump!(focus_tenant.id)
        ])

        Repo.delete_all(from(t in Tenant, where: t.id == ^focus_tenant.id))
      end)

      orphan_id = Ecto.UUID.generate()
      absent_tenant_id = Ecto.UUID.generate()
      seeded_backup_ids = [Ecto.UUID.dump!(orphan_id)]

      # (C) -- cleanup step 1.
      on_exit(fn ->
        Repo.query!(
          "DELETE FROM public.iss060_tenant_schemas_guard_backup WHERE id = ANY($1)",
          [seeded_backup_ids]
        )
      end)

      ensure_backup_table!()

      %{rows: [[absent_parent_count]]} =
        Repo.query!("SELECT count(*) FROM public.tenants WHERE id = $1", [
          Ecto.UUID.dump!(absent_tenant_id)
        ])

      assert absent_parent_count == 0,
             "fixture premise: the orphan's parent tenant must genuinely not exist"

      Repo.query!("""
      ALTER TABLE public.iss060_tenant_schemas_guard_backup
        DROP CONSTRAINT IF EXISTS iss060_tenant_schemas_guard_backup_tenant_id_fkey
      """)

      Repo.query!(
        """
        INSERT INTO public.iss060_tenant_schemas_guard_backup
          (id, tenant_id, schema_name, migrations_applied_at, provisioned_at)
        VALUES ($1, $2, $3, NULL, now())
        """,
        [
          Ecto.UUID.dump!(orphan_id),
          Ecto.UUID.dump!(absent_tenant_id),
          "iss0229_visorphan_" <> String.replace(orphan_id, "-", "")
        ]
      )

      # Pre-fix, the inner `after` block's move-back CTE raises 23503 here and
      # the return value is never produced. The contract under test is
      # unchanged: it returns whatever fun.() returned.
      assert with_only_this_tenant_visible!(focus_tenant.id, fn -> :guard_ran end) == :guard_ran

      %{rows: [[orphan_backup_count]]} =
        Repo.query!(
          "SELECT count(*) FROM public.iss060_tenant_schemas_guard_backup WHERE id = $1",
          [Ecto.UUID.dump!(orphan_id)]
        )

      assert orphan_backup_count == 0

      %{rows: [[orphan_visible_count]]} =
        Repo.query!("SELECT count(*) FROM public.tenant_schemas WHERE tenant_id = $1", [
          Ecto.UUID.dump!(absent_tenant_id)
        ])

      assert orphan_visible_count == 0
    end
  end
end
