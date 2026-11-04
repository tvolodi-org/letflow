defmodule Letflow.Test.TenantTemplateTest do
  @moduledoc """
  Permanent regression test for ISS-0427 — design
  `lib/letflow/design/iss0427-tenant-test-schema-template-clone.md` §3.4 use
  site 2: "a dedicated test file ... that clones a throwaway tenant and calls
  `assert_clone_parity!("tenant_template", <clone's own schema_name>)` across
  ALL thirteen dimensions #1-13. This is the test that stays green build
  after build and is what 'constraint parity must be ASSERTED, not assumed'
  ... cashes out to as an actual, permanent, always-run regression test."

  Before this file existed, `assert_clone_parity!/2` was reachable from
  exactly one runnable place (`ensure_template!/0`'s own build-time
  self-check, use site 1 — see `test/support/tenant_template.ex`'s
  `assert_template_parity_against_independent_reference!/0`), which proves
  the TEMPLATE is faithful to a migration-built reference but never proves
  that an actual `clone_tenant_schema!/1` output — the thing every real test
  in this suite consumes via `TenantFixture.provisioned_tenant!/1`'s default
  `template: :clone` — stays in parity with the template build after build,
  on every suite run. This file closes that gap: it is a real, always-run
  ExUnit test (no `@tag :skip`, no manual/one-off script), not a one-time
  manual verification.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 — no mocked database.
  `async: false`, matching every other tenant-schema-provisioning test in
  this suite (`promotion_test.exs`, `tenant_fixture` itself) — schema-level
  DDL (`CREATE SCHEMA`, `DROP SCHEMA ... CASCADE`) and the shared
  `"tenant_template"` schema this test builds against are not per-connection
  sandboxed state, so concurrent runs of this file's own tests, or of any
  other file that also calls `ensure_template!/0`/`clone_tenant_schema!/1`
  concurrently, would race on the SAME physical schema names — this is the
  same reasoning `Letflow.Test.TenantTemplate`'s own design §4.2 gives for
  why template-building calls are already serialized by
  `Sandbox.mode(Letflow.Repo, :auto)` defeating `async: true` suite-wide the
  moment any test using this fixture runs.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.Test.TenantTemplate

  # `Letflow.DataCase`'s own setup checks out a connection under
  # `{:shared, self()}` mode (async: false), which is the WRONG mode for
  # anything that calls `ensure_template!/0`/`clone_tenant_schema!/1`:
  # `Ecto.Migrator.run/4` (invoked by `replay_migrations/2`, per design §4.3's
  # own finding) checks out its OWN separate connection from the pool rather
  # than participating in the shared/ambient one, so under shared mode that
  # second checkout starves against a single shared connection. Switch to
  # `:auto` mode first, exactly what `Letflow.TenantFixture.provisioned_tenant!/1`
  # already does as its own first statement for the identical reason (design
  # §4.1) — every test in this file needs this, so it is done once here
  # rather than repeated per test.
  setup do
    Sandbox.mode(Letflow.Repo, :auto)
    :ok
  end

  describe "clone-vs-template parity (design §3.4 use site 2)" do
    test "a real clone matches the template across all 13 dimensions" do
      :ok = TenantTemplate.ensure_template!()

      tenant = insert_throwaway_tenant!()
      on_exit(fn -> cleanup_tenant!(tenant) end)

      assert {:ok, clone_schema} = TenantTemplate.clone_tenant_schema!(tenant.id)

      # The actual acceptance criterion: "constraint parity must be ASSERTED,
      # not assumed" (ISS-0427's own words, design §11). No :dimensions
      # restriction here — this is the ONE place in the whole suite that
      # exercises every one of the 13 dimensions against a genuine
      # clone_tenant_schema!/1 output, every time this file runs.
      assert :ok = TenantTemplate.assert_clone_parity!("tenant_template", clone_schema)
    end
  end

  describe "REQ-710 -- the ledger parents are partitioned in a clone" do
    test "a clone has LIST (ledger_id) parents, takes partitions, and a partitioned clone is not clean" do
      :ok = TenantTemplate.ensure_template!()

      tenant = insert_throwaway_tenant!()
      on_exit(fn -> cleanup_tenant!(tenant) end)

      assert {:ok, clone} = TenantTemplate.clone_tenant_schema!(tenant.id)

      for t <- ~w(ledger_entry ledger_leg ledger_balance) do
        assert %{rows: [["p", "LIST (ledger_id)"]]} =
                 Repo.query!(
                   "SELECT c.relkind::text, pg_get_partkeydef(c.oid) FROM pg_class c " <>
                     "JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = $1 AND c.relname = $2",
                   [clone, t]
                 )
      end

      baseline = TenantTemplate.capture_clone_baseline!(clone)
      refute "ledger_entry_p" in TenantTemplate.baseline_tables(baseline)

      # Storage.ensure/2 works on a clone (the clone carries the TRUNCATE guard function)
      assert {:ok, :ok} =
               Repo.transaction(fn -> Letflow.Ledger.Storage.ensure(clone, "clone_ledger") end)

      assert {:ok, state} = TenantTemplate.probe_clone_state(clone)
      refute TenantTemplate.clean_diff?(TenantTemplate.diff_clone_state(state, baseline))
    end
  end

  describe "the template itself is faithful to a genuine migration build" do
    # design §3.4 use site 1. This is what proves the TEMPLATE is not merely
    # self-consistent but actually equivalent to a schema built by replaying
    # all 53 migrations -- without it, every clone could be a faithful copy
    # of a wrong template.
    #
    # It is exercised HERE, explicitly, rather than on ensure_template!/0's
    # default path: it replays the full migration set a second time, and
    # paying that once per partition under scripts/test_parallel.sh's 16
    # partitions (TEST_POOL_SIZE=5) exhausted the connection pool and broke
    # the suite outright (measured: 393 failures). Running it once, here,
    # gets the same guarantee at a cost the suite can afford.
    test "template matches an independently migration-built reference schema" do
      :ok = TenantTemplate.ensure_template!()

      assert :ok = TenantTemplate.assert_template_parity_against_independent_reference!()
    end

    # ISS-0468 regression: before this fix, the reference schema's name was
    # the fixed literal "tenant_template_refcheck" -- two concurrent
    # invocations both racing CREATE SCHEMA against tenant_schemas'
    # UNIQUE(schema_name) index would collide. Reproduced against the
    # pre-fix code (git stash the fix, run this test) as an Ecto/Postgrex
    # unique-violation exception; passes cleanly post-fix because
    # generate_staging_schema_name/0 mints a fresh, collision-resistant
    # name per invocation, matching ISS-0427's own fix for the staging
    # build name.
    test "two concurrent reference-schema builds do not collide" do
      :ok = TenantTemplate.ensure_template!()

      results =
        [
          Task.async(&TenantTemplate.assert_template_parity_against_independent_reference!/0),
          Task.async(&TenantTemplate.assert_template_parity_against_independent_reference!/0)
        ]
        |> Task.await_many(30_000)

      assert results == [:ok, :ok]
    end
  end

  describe "ISS-0842 — stale template detection and rebuild" do
    # Regression tests for the fingerprint-based staleness check. The key
    # failure mode this covers: a reused test DB (from a prior `mix test`
    # run) holds a "tenant_template" schema built from an older migration set.
    # After pulling a new migration (e.g. REQ-402's tenant_modules table),
    # template_db_state/0 must detect the mismatch and rebuild — which
    # build_template!/0's rename-into-place already does atomically, with the
    # old schema dropped first in ensure_template!/0's :stale branch.

    test "stale fingerprint comment triggers rebuild and clone succeeds" do
      # Phase 1: ensure a current template exists, then corrupt its fingerprint
      # to simulate a stale-DB scenario (wrong fingerprint = built from a
      # different migration set than the currently-compiled one).
      :ok = TenantTemplate.ensure_template!()

      Repo.query!(
        "COMMENT ON SCHEMA tenant_template IS 'letflow_migrations_v1:000000000000000000000000stale'"
      )

      # Phase 2: clear the per-VM persistent_term marker so ensure_template!/0
      # re-enters the advisory-lock path on the next call. The key is the
      # private module attribute value — {Letflow.Test.TenantTemplate, :template_built}.
      :persistent_term.erase({Letflow.Test.TenantTemplate, :template_built})

      # Phase 3: ensure_template!/0 must detect :stale, drop the old schema,
      # and rebuild a fresh one with the correct fingerprint.
      assert :ok = TenantTemplate.ensure_template!()

      # Phase 4: the rebuilt template must be clonable and produce a valid schema.
      tenant = insert_throwaway_tenant!()
      on_exit(fn -> cleanup_tenant!(tenant) end)

      assert {:ok, clone_schema} = TenantTemplate.clone_tenant_schema!(tenant.id)
      assert :ok = TenantTemplate.assert_clone_parity!("tenant_template", clone_schema)
    end

    test "missing fingerprint comment (no COMMENT set) is treated as stale and triggers rebuild" do
      # Simulates a template built by an older version of this code that did
      # not set a comment. template_db_state/0 must treat nil/no-comment as
      # :stale (the fingerprint never matches the current one), not :current.
      :ok = TenantTemplate.ensure_template!()

      Repo.query!("COMMENT ON SCHEMA tenant_template IS NULL")
      :persistent_term.erase({Letflow.Test.TenantTemplate, :template_built})

      assert :ok = TenantTemplate.ensure_template!()

      tenant = insert_throwaway_tenant!()
      on_exit(fn -> cleanup_tenant!(tenant) end)

      assert {:ok, _clone_schema} = TenantTemplate.clone_tenant_schema!(tenant.id)
    end
  end

  describe "non-vacuity — a genuinely divergent clone must fail this same check" do
    # These three tests are this file's own proof that the assertion above
    # is not a tautology. Each independently reproduces one of the three
    # cross-schema-coupling hazards design §0/§0.1/§0.4 names, by tampering
    # a real clone directly (bypassing clone_tenant_schema!/1's own
    # mechanism entirely) and confirming assert_clone_parity!/2 raises. This
    # mirrors ELIXIR-DEV's own ad-hoc tamper-and-detect proofs (step-03
    # continued handoff) as PERMANENT, always-run coverage instead of a
    # one-off script — REVIEWER's own finding-8(a) explicitly asked for
    # exactly this ("do not treat ELIXIR-DEV's own tamper-and-detect proofs
    # ... as sufficient coverage on their own").

    test "a clone missing a real foreign key fails dimension #3" do
      :ok = TenantTemplate.ensure_template!()

      tenant = insert_throwaway_tenant!()
      clone_schema = clone_schema_name(tenant.id)
      on_exit(fn -> cleanup_tenant!(tenant) end)

      {:ok, ^clone_schema} = TenantTemplate.clone_tenant_schema!(tenant.id)

      {:ok, conname, table} = a_foreign_key_in(clone_schema)
      Repo.query!(~s(ALTER TABLE "#{clone_schema}"."#{table}" DROP CONSTRAINT "#{conname}"))

      assert_raise ExUnit.AssertionError, ~r/\[dim #3\]/, fn ->
        TenantTemplate.assert_clone_parity!("tenant_template", clone_schema)
      end
    end

    # HISTORICAL NOTE (kept because the reasoning is still worth reading):
    # this test and the two below were originally committed `@tag :skip`,
    # because normalize/3 stripped BOTH schema qualifiers from BOTH sides and
    # was therefore structurally blind to this exact tamper -- a FK that is
    # PRESENT but repointed at the template (as opposed to the ABOVE test's
    # "missing entirely" shape, which the check catches correctly) is
    # invisible to dimension #3 for the identical normalize/3 reason. This
    # is the exact hazard design §0.1 finding 1 names ("FK present but
    # pointing at the template's own tables") and it is NOT actually caught
    # today, contrary to design §3.2 item 3's own claim ("catches both 'FK
    # missing entirely' ... and 'FK present but pointing at the wrong
    # schema'"). Independently reproduced this step via a throwaway probe:
    # dropping a real FK and re-adding it with its qualifier rewritten to
    # `tenant_template.` instead of the clone's own schema left
    # assert_clone_parity!/2 returning :ok.
    test "a clone FK present but repointed at the template fails dimension #3" do
      :ok = TenantTemplate.ensure_template!()

      tenant = insert_throwaway_tenant!()
      clone_schema = clone_schema_name(tenant.id)
      on_exit(fn -> cleanup_tenant!(tenant) end)

      {:ok, ^clone_schema} = TenantTemplate.clone_tenant_schema!(tenant.id)

      {:ok, conname, table} = a_foreign_key_in(clone_schema)

      %{rows: [[def_sql]]} =
        Repo.query!(
          """
          SELECT pg_get_constraintdef(con.oid)
          FROM pg_constraint con
          JOIN pg_class rel ON rel.oid = con.conrelid
          JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
          WHERE nsp.nspname = $1 AND con.conname = $2
          """,
          [clone_schema, conname]
        )

      Repo.query!(~s(ALTER TABLE "#{clone_schema}"."#{table}" DROP CONSTRAINT "#{conname}"))

      repointed = String.replace(def_sql, ~s(#{clone_schema}.), "tenant_template.")

      assert repointed != def_sql,
             "test bug: qualifier substitution did not match anything in #{inspect(def_sql)}"

      Repo.query!(
        ~s(ALTER TABLE "#{clone_schema}"."#{table}" ADD CONSTRAINT "#{conname}" #{repointed})
      )

      assert_raise ExUnit.AssertionError, ~r/\[dim #3\]/, fn ->
        TenantTemplate.assert_clone_parity!("tenant_template", clone_schema)
      end
    end

    # HISTORICAL NOTE, as above: both tests below were originally `@tag :skip`
    # and are now live and passing, because normalize/3 was fixed to strip
    # only each side's OWN schema qualifier. What follows is the original
    # report of
    # WHY rather than deleted or silently made to pass. Run against this
    # step's own wiring (2026-09-04), both actually FAILED with "Expected
    # exception ExUnit.AssertionError but nothing was raised" -- i.e.
    # assert_clone_parity!/2 returned :ok on a clone with a REAL,
    # confirmed-live cross-schema coupling. This is a MAJOR finding,
    # reported per this run's own instruction to stop and report rather than
    # adjust the check to pass, NOT fixed here (see this step's handoff for
    # the full writeup) -- fixing normalize/3 is out of this step's own
    # scope (TEST-DESIGNER does not modify parity-check logic; that is
    # ELIXIR-DEV's / a follow-up issue's job). Left present, not deleted,
    # because they are exactly the regression proof whoever fixes
    # normalize/3 needed -- the fix landed, the skips are gone, and both
    # pass.
    #
    # ROOT CAUSE (independently reproduced via throwaway `mix run` probes
    # this step, not merely asserted): `normalize/3`
    # (test/support/tenant_template.ex) strips BOTH `reference_schema.` and
    # `candidate_schema.` qualifiers from a definition string before
    # comparing reference vs candidate. This is correct for the ORDINARY
    # case (a genuinely clone-local object correctly qualified to its own
    # schema on each side) but is BLIND to the exact hazard dimensions
    # #2/#3/#5/#8 exist to catch: a candidate-side object that still
    # literally contains the REFERENCE schema's own qualifier (i.e. is
    # present but points at the template, not a clone-local copy) gets that
    # exact evidence silently erased by the same normalization step that
    # legitimately strips it from the correct case. A `pg_get_serial_sequence`
    # -based check (dimension #5's OTHER assertion, the "sequence namespace
    # leak" check in check_sequences/2) is unaffected -- it resolves the
    # sequence OWNED BY relationship structurally (pg_depend), not by text
    # comparison -- but that check only fires when the DEFAULT and the
    # sequence's OWNED BY diverge, which a plain `ALTER ... SET DEFAULT
    # nextval(...)` repoint (this test's own tamper, and the shape a real
    # clone-mechanism regression forgetting the repoint step would produce)
    # does NOT do: it changes only the DEFAULT text, not sequence ownership.
    # So the ONE dimension-#5 assertion built specifically to survive
    # qualifier-normalization blindness (see design §0's "sequence trap"
    # framing) is not reached by this tamper shape at all.
    # POST-FIX UPDATE (ORCH, after normalize/3 was corrected to strip only
    # each side's OWN schema qualifier): this tamper IS now caught, and is
    # caught EARLIER than dimension #5 -- dimension #2's column comparison
    # sees the surviving qualifier directly, reference reading
    # `nextval('events_global_seq_seq'::regclass)` against candidate
    # `nextval('tenant_template.events_global_seq_seq'::regclass)`. The
    # assertion below therefore matches [dim #2], not [dim #5]. Catching it
    # at #2 is strictly better than at #5 (the leak is visible in the raw
    # column default, no pg_depend resolution needed); the original [dim #5]
    # expectation was written against the pre-fix blind behaviour.
    test "a clone whose sequence-backed default is repointed at the template is caught (dimension #2 sees the surviving qualifier)" do
      :ok = TenantTemplate.ensure_template!()

      tenant = insert_throwaway_tenant!()
      clone_schema = clone_schema_name(tenant.id)
      on_exit(fn -> cleanup_tenant!(tenant) end)

      {:ok, ^clone_schema} = TenantTemplate.clone_tenant_schema!(tenant.id)

      {:ok, table, column, clone_seq} = a_sequence_backed_column_in(clone_schema)
      template_seq_local = local_identifier_name(clone_seq)

      # Repoint the clone column's DEFAULT at the TEMPLATE's own sequence
      # object (the exact "sequence trap" hazard design §0/§0.1 finding 3-4
      # names) -- simulates a clone mechanism regression that forgot the
      # sequence-recreation-and-repoint step.
      Repo.query!(
        ~s(ALTER TABLE "#{clone_schema}"."#{table}" ALTER COLUMN "#{column}" ) <>
          ~s|SET DEFAULT nextval('"tenant_template"."#{template_seq_local}"')|
      )

      error =
        assert_raise ExUnit.AssertionError, fn ->
          TenantTemplate.assert_clone_parity!("tenant_template", clone_schema)
        end

      # The surviving `tenant_template.` qualifier is the whole point: after
      # the normalize/3 fix it is no longer stripped out of the candidate,
      # so it shows up as a real textual difference rather than collapsing
      # into a false match.
      assert error.message =~ "[dim #2]"
      assert error.message =~ "tenant_template.#{template_seq_local}"
    end

    test "a clone trigger repointed at the template's own function fails dimension #8" do
      :ok = TenantTemplate.ensure_template!()

      tenant = insert_throwaway_tenant!()
      clone_schema = clone_schema_name(tenant.id)
      on_exit(fn -> cleanup_tenant!(tenant) end)

      {:ok, ^clone_schema} = TenantTemplate.clone_tenant_schema!(tenant.id)

      {:ok, tgname, table, _func_name} = a_trigger_in(clone_schema)

      # Read this trigger's OWN definition straight off the clone (it is
      # already correctly clone-qualified, per design §2.3 step 6), drop it,
      # then recreate it with its EXECUTE FUNCTION clause repointed at the
      # TEMPLATE's own function object instead of the clone's own
      # (correctly-recreated) copy -- the exact cross-schema-coupling hazard
      # design §0.4/§2.3 step 6 exists to prevent: a trigger present but
      # still invoking the template's function, which dimension #8's
      # EXECUTE FUNCTION clause comparison must catch, and currently does
      # not (see this describe block's own leading comment).
      %{rows: [[clone_trigger_ddl]]} =
        Repo.query!(
          """
          SELECT pg_get_triggerdef(trg.oid)
          FROM pg_trigger trg
          JOIN pg_class rel ON rel.oid = trg.tgrelid
          JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
          WHERE nsp.nspname = $1 AND rel.relname = $2 AND trg.tgname = $3
          """,
          [clone_schema, table, tgname]
        )

      Repo.query!(~s(DROP TRIGGER "#{tgname}" ON "#{clone_schema}"."#{table}"))

      repointed =
        String.replace(
          clone_trigger_ddl,
          ~s(EXECUTE FUNCTION #{clone_schema}.),
          ~s(EXECUTE FUNCTION tenant_template.)
        )

      assert repointed != clone_trigger_ddl,
             "test bug: qualifier substitution did not match anything in #{inspect(clone_trigger_ddl)}"

      Repo.query!(repointed)

      assert_raise ExUnit.AssertionError, ~r/\[dim #8\]/, fn ->
        TenantTemplate.assert_clone_parity!("tenant_template", clone_schema)
      end
    end
  end

  describe "ISS-0879 regression — throwaway build row's visibility window" do
    # Regression test for ISS-0879 (design
    # lib/letflow/design/iss0879-retention-fanout-fixture-leak.md). The bug:
    # do_build_template!/1's throwaway `tenant_template_build_<hex>`
    # Registration row goes through the REAL TenantProvisioning.replay_migrations/2,
    # whose own committed side effect (mark_migrations_applied/1) stamps
    # migrations_applied_at with a real, committed, cross-process-visible
    # timestamp -- satisfying RetentionOperations.provisioned_tenant_schemas/0's
    # platform-wide `where: not is_nil(r.migrations_applied_at)` predicate for
    # as long as that row survives (previously: the whole duration of
    # template_self_check!/1, ended only by delete_throwaway_tenant_and_registration!/1).
    # The fix (already implemented, commit 9e0fa90d, NOT modified by this
    # test): a new private clear_migrations_applied_flag!/1 nulls
    # migrations_applied_at immediately after replay_migrations/2 returns
    # {:ok, _}, at both throwaway-row call sites -- narrowing (per the design's
    # own §2.3, explicitly NOT fully closing) the window.
    #
    # THREE APPROACHES WERE TRIED AND REJECTED BEFORE THIS ONE, IN ORDER,
    # EACH FOR A CONCRETE, MEASURED REASON (kept here, not deleted, because
    # the reasoning is load-bearing for why this file's own regression test
    # takes the shape it does):
    #
    # 1. Direct unit test of clear_migrations_applied_flag!/1 itself. Rejected:
    #    it is a brand-new PRIVATE function (`defp`) of this module, not
    #    exported at the BEAM level -- calling it from this external test
    #    module raises UndefinedFunctionError. There is no existing seam this
    #    module exposes for reaching private helpers (checked: the only
    #    precedent, assert_template_parity_against_independent_reference!/1,
    #    is public specifically because ITS OWN design intended it to be
    #    tested directly -- clear_migrations_applied_flag!/1 was not given
    #    the same treatment, and this test must not modify the already-
    #    implemented fix to add one).
    # 2/3. Force a real rebuild (via the same fingerprint-corruption
    #    technique the "ISS-0842" describe block above already uses) and
    #    busy-poll `tenant_schemas` from a separate connection for the
    #    throwaway row's `migrations_applied_at`, asserting either "never
    #    observed" or "observed for at most N ms". Both rejected after
    #    actually measuring, not assumed:
    #    - post-fix, the window is NOT zero-width even in principle: the two
    #      `maybe_seed_platform_event_types/2`/`maybe_seed_entity_event_types/2`
    #      calls run INSIDE `replay_migrations/2`, AFTER `mark_migrations_applied/1`
    #      commits and BEFORE `replay_migrations/2` returns -- i.e. still
    #      inside the stamped window even post-fix, by design (§2.3's own
    #      "not eliminated"). Measured directly at ~40-50ms per rebuild. So
    #      "never observed" is not a valid post-fix expectation.
    #    - a duration-bound variant (amplifying the discriminator via a
    #      temporary `LETFLOW_TEMPLATE_REFCHECK=1`, which makes the pre-fix
    #      window include a second full 53-migration replay) DID discriminate
    #      cleanly in an isolated single-file run (fixed: ~91-93ms; a
    #      temporary local revert of both call sites: ~2.7-2.8s) -- but
    #      failed when actually run as part of the full
    #      `mix letflow.check.test` suite: under real connection-pool
    #      contention from concurrently-running tests, the FIXED code's own
    #      measured window ballooned to 9895-14916ms, blowing through any
    #      sane fixed bound. This is exactly the documented cost-placement
    #      hazard `template_self_check!/1`'s own comment already warns about
    #      for `LETFLOW_TEMPLATE_REFCHECK` under load, and it is also exactly
    #      what this project's own core directives forbid ("don't depend on
    #      wall-clock time") -- a timing-based assertion is fundamentally
    #      the wrong tool here, not merely hard to calibrate.
    #
    # WHAT THIS TEST DOES INSTEAD: a deterministic, load-independent
    # STRUCTURAL check on `test/support/tenant_template.ex`'s own AST,
    # verifying the exact code shape the fix's design (§2.2) specifies at
    # both throwaway-row call sites: `clear_migrations_applied_flag!(...)` is
    # the FIRST expression evaluated in the `{:ok, _applied_versions} ->`
    # branch of the `case TenantProvisioning.replay_migrations(...) do`
    # clause, i.e. it runs before any other work (before
    # `template_self_check!/1` at call site 1, before `assert_clone_parity!/2`
    # at call site 2) -- which is precisely the property §2.3's window-
    # narrowing argument depends on. This has zero timing dependence and is
    # not "testing the declaration" in the disfavored, no-real-logic sense
    # (`docs/anti-patterns.md`'s mix.exs-alias example): it exercises
    # `Code.string_to_quoted!/1` against the file's REAL, currently-compiled
    # source and pattern-matches the REAL parsed AST of the two `case`
    # clauses that make up the fix -- not the mere presence of a string, and
    # it demonstrably discriminates fixed from reverted code (see the FAIL
    # evidence in this run's own handoff report: reverting the two call
    # sites, exactly as ELIXIR-DEV's commit added them, makes this test fail
    # with a clear "clear_migrations_applied_flag! is not the first
    # expression" message; restoring them makes it pass).
    test "clear_migrations_applied_flag!/1 is the first expression after both throwaway-row replay_migrations/2 successes" do
      source = File.read!(Path.join(__DIR__, "tenant_template.ex"))
      {:ok, ast} = Code.string_to_quoted(source, columns: true)

      replay_migrations_ok_branches = find_replay_migrations_ok_branches(ast)

      assert length(replay_migrations_ok_branches) == 2,
             "ISS-0879 regression helper: expected exactly 2 " <>
               "`case TenantProvisioning.replay_migrations(...) do {:ok, _} -> ...` " <>
               "clauses in test/support/tenant_template.ex (one in do_build_template!/1, " <>
               "one in assert_template_parity_against_independent_reference!/1) -- found " <>
               "#{length(replay_migrations_ok_branches)}. This helper itself may need " <>
               "updating if the surrounding code was intentionally restructured."

      Enum.each(replay_migrations_ok_branches, fn first_expr ->
        assert first_expr_calls_clear_migrations_applied_flag?(first_expr),
               "ISS-0879 regression: a `{:ok, _applied_versions} ->` branch of a " <>
                 "`TenantProvisioning.replay_migrations/2` case in test/support/tenant_template.ex " <>
                 "does not call clear_migrations_applied_flag!(...) as its first expression " <>
                 "(found first expression: #{Macro.to_string(first_expr)}). This is the exact " <>
                 "regression ISS-0879 fixed: the throwaway row's migrations_applied_at stays " <>
                 "set for the whole duration of whatever runs next (template_self_check!/1 or " <>
                 "assert_clone_parity!/2), visible to RetentionOperations.provisioned_tenant_schemas/0's " <>
                 "platform-wide fanout."
      end)
    end
  end

  describe "ISS-0937 -- dynamic month partition tables are ignored on both sides of the table-set dimension" do
    # Regression for the parity half of ISS-0937. The migration that creates
    # events_yYYYYmMM runs at RUN time, so a template built in month N and a
    # reference replayed in month N+1 hold different dynamic partition tables.
    # check_table_set/2 used to filter them only from the `missing` side, so
    # the stale month showed up as `extra`. These tests hand-build two schemas
    # with FIXED table names (no wall-clock) and call the real public
    # assert_clone_parity!/3 restricted to dimension #1, so they fail on every
    # real date against the pre-fix code.

    test "stale dynamic partition on the candidate side is not reported as extra" do
      {ref, cand} =
        build_schemas!(
          ["shared_t", "events_y2026m10", "events_y2026m11"],
          ["shared_t", "events_y2026m09", "events_y2026m10"]
        )

      assert :ok = TenantTemplate.assert_clone_parity!(ref, cand, dimensions: [1])
    end

    test "dynamic partition only on the reference side is not reported as missing" do
      {ref, cand} =
        build_schemas!(
          ["shared_t", "events_y2026m09", "events_y2026m10"],
          ["shared_t", "events_y2026m10", "events_y2026m11"]
        )

      assert :ok = TenantTemplate.assert_clone_parity!(ref, cand, dimensions: [1])
    end

    test "events_archive dynamic partitions are ignored on both sides" do
      {ref, cand} =
        build_schemas!(
          ["shared_t", "events_archive_y2026m10"],
          ["shared_t", "events_archive_y2026m09"]
        )

      assert :ok = TenantTemplate.assert_clone_parity!(ref, cand, dimensions: [1])
    end

    test "a non-partition extra table still raises" do
      {ref, cand} =
        build_schemas!(
          ["shared_t", "events_y2026m10"],
          ["shared_t", "events_y2026m09", "widgets_extra"]
        )

      error =
        assert_raise ExUnit.AssertionError, fn ->
          TenantTemplate.assert_clone_parity!(ref, cand, dimensions: [1])
        end

      assert error.message =~ ~s(table set: extra=["widgets_extra"])
      refute error.message =~ "events_y2026m09"
    end

    test "a genuinely missing non-partition table still raises" do
      {ref, cand} =
        build_schemas!(["shared_t", "widgets_missing"], ["shared_t"])

      error =
        assert_raise ExUnit.AssertionError, fn ->
          TenantTemplate.assert_clone_parity!(ref, cand, dimensions: [1])
        end

      assert error.message =~ ~s(table set: missing=["widgets_missing"])
    end

    test "names that are not valid month partitions are not ignored" do
      for bad <- ["events_y2026m13", "events_y26m09", "eventsx_y2026m09", "events_extra"] do
        {ref, cand} = build_schemas!(["shared_t"], ["shared_t", bad])

        error =
          assert_raise ExUnit.AssertionError, fn ->
            TenantTemplate.assert_clone_parity!(ref, cand, dimensions: [1])
          end

        assert error.message =~ bad
      end
    end

    test "a fixed partition-management table extra on the candidate side is still reported" do
      # Pins the dynamic-only decision: events_default is date-independent, so
      # it stays in the comparison on the extra direction.
      {ref, cand} = build_schemas!(["shared_t"], ["shared_t", "events_default"])

      error =
        assert_raise ExUnit.AssertionError, fn ->
          TenantTemplate.assert_clone_parity!(ref, cand, dimensions: [1])
        end

      assert error.message =~ ~s(table set: extra=["events_default"])
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers -- deliberately independent of Letflow.TenantFixture/
  # Letflow.Test.TenantTemplate's own private machinery: this test proves the
  # PUBLIC contract (clone_tenant_schema!/1 + assert_clone_parity!/2), so it
  # builds its own minimal throwaway tenant rather than reusing
  # TenantFixture.provisioned_tenant!/1 (which would itself call
  # clone_tenant_schema!/1 AND assert_schema_complete!/2, muddying what this
  # file's own failures would mean).
  # ---------------------------------------------------------------------------

  defp insert_throwaway_tenant! do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: Letflow.TenantSlugFixture.unique_slug("tenant-template-parity-test"),
        display_name: "Tenant Template Parity Test (throwaway)"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  # ISS-0937: builds two throwaway schemas with unique names, each holding
  # the given plain (empty, one-column) tables, and drops both on exit.
  defp build_schemas!(ref_tables, cand_tables) do
    suffix = System.unique_integer([:positive])
    ref = "iss0937_ref_#{suffix}"
    cand = "iss0937_cand_#{suffix}"

    on_exit(fn ->
      drop_schema_if_exists(ref)
      drop_schema_if_exists(cand)
    end)

    for {schema, tables} <- [{ref, ref_tables}, {cand, cand_tables}] do
      Repo.query!(~s(CREATE SCHEMA "#{schema}"))

      for table <- tables do
        Repo.query!(~s|CREATE TABLE "#{schema}"."#{table}" (id integer)|)
      end
    end

    {ref, cand}
  end

  defp clone_schema_name(tenant_id) do
    {:ok, schema_name} = Letflow.TenantProvisioning.schema_name_for_tenant(tenant_id)
    schema_name
  end

  defp drop_schema_if_exists(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  # Full teardown: schema + the throwaway Tenant/Registration rows
  # insert_throwaway_tenant!/0 and clone_tenant_schema!/1 create — matching
  # Letflow.TenantFixture.provisioned_tenant!/1's own teardown/3 shape, so
  # this test file leaves nothing behind for a future suite run to trip
  # over (this module deliberately does not call TenantFixture itself, per
  # the comment above, but its own cleanup should still be complete).
  defp cleanup_tenant!(tenant) do
    schema_name = clone_schema_name(tenant.id)
    drop_schema_if_exists(schema_name)

    Repo.delete_all(
      from(r in Letflow.TenantProvisioning.Registration, where: r.tenant_id == ^tenant.id)
    )

    Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
  end

  defp a_foreign_key_in(schema_name) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT con.conname, rel.relname
        FROM pg_constraint con
        JOIN pg_class rel ON rel.oid = con.conrelid
        JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
        WHERE nsp.nspname = $1 AND con.contype = 'f'
        LIMIT 1
        """,
        [schema_name]
      )

    case rows do
      [[conname, table]] -> {:ok, conname, table}
      [] -> {:error, :no_foreign_key_found}
    end
  end

  defp a_sequence_backed_column_in(schema_name) do
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
    |> Enum.reject(fn [_t, _c, seq] -> is_nil(seq) end)
    |> case do
      [[table, column, seq] | _] -> {:ok, table, column, seq}
      [] -> {:error, :no_sequence_backed_column_found}
    end
  end

  defp local_identifier_name(qualified_name) do
    qualified_name
    |> String.split(".", parts: 2)
    |> List.last()
    |> String.trim("\"")
  end

  # ISS-0879 regression helpers -----------------------------------------------
  #
  # Walks the parsed AST of test/support/tenant_template.ex looking for every
  # `case TenantProvisioning.replay_migrations(...) do ... {:ok, _} -> <body> ... end`
  # clause, and returns the FIRST expression of each such `{:ok, _} -> <body>`
  # branch (a `{:ok, _applied_versions} ->` two-element `{args, body}` tuple
  # per Elixir's own `case/2` AST shape, `body` itself either a single
  # expression or a `{:__block__, _, [expr | _]}` for a multi-statement
  # branch -- both are handled below).

  defp find_replay_migrations_ok_branches(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {:case, _meta,
         [
           {{:., _, [{:__aliases__, _, [:TenantProvisioning]}, :replay_migrations]}, _, _args},
           [do: clauses]
         ]} =
            node,
        acc ->
          first_exprs =
            clauses
            |> Enum.filter(fn {:->, _, [[pattern], _body]} ->
              ok_applied_versions_pattern?(pattern)
            end)
            |> Enum.map(fn {:->, _, [_pattern, body]} -> first_expression_of(body) end)

          {node, acc ++ first_exprs}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # Matches the `{:ok, _applied_versions}` pattern (a 2-tuple whose first
  # element is the literal atom :ok) -- deliberately not matching on the
  # second element's own name, since that is a pattern-variable choice, not
  # part of the shape this test cares about.
  defp ok_applied_versions_pattern?({:{}, _, [:ok, _]}), do: true
  defp ok_applied_versions_pattern?({:ok, _}), do: true
  defp ok_applied_versions_pattern?(_), do: false

  defp first_expression_of({:__block__, _, [first | _rest]}), do: first
  defp first_expression_of(single_expr), do: single_expr

  # True when `expr` is a call to `clear_migrations_applied_flag!(...)`
  # (with any single argument -- the throwaway tenant_id, which differs by
  # call site).
  defp first_expr_calls_clear_migrations_applied_flag?(
         {:clear_migrations_applied_flag!, _meta, [_arg]}
       ),
       do: true

  defp first_expr_calls_clear_migrations_applied_flag?(_other), do: false

  defp a_trigger_in(schema_name) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT trg.tgname, rel.relname, p.proname
        FROM pg_trigger trg
        JOIN pg_class rel ON rel.oid = trg.tgrelid
        JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
        JOIN pg_proc p ON p.oid = trg.tgfoid
        WHERE nsp.nspname = $1 AND NOT trg.tgisinternal
        LIMIT 1
        """,
        [schema_name]
      )

    case rows do
      [[tgname, table, func_name]] -> {:ok, tgname, table, func_name}
      [] -> {:error, :no_trigger_found}
    end
  end
end
