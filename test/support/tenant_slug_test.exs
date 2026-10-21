defmodule Letflow.TenantSlugFixtureTest do
  @moduledoc """
  Regression test for ISS-0059 ("Flaky slug collision in migrations_test.exs's
  insert_tenant!/0 (:auto sandbox, real commits)") — proves both halves of the
  fix:

  1. The PRE-FIX mechanism (`"<prefix>-\#{System.unique_integer([:positive,
     :monotonic])}"`) really does collide across two independent BEAM VM
     runs — not a hypothetical, mechanically demonstrated below by spawning
     genuinely separate OS processes, each a fresh VM, and showing their
     first `unique_integer/1` call returns the identical value every time.
     This is precisely ISS-0059's failure mode: a prior `mix test` invocation
     crashes before its `on_exit` cleanup runs (leaving a `tenants` row with
     slug `"req027-1"` committed for real, since these modules run
     `Sandbox.mode(Letflow.Repo, :auto)`), and the next `mix test` VM's
     counter restarts from 1, generating the identical slug and colliding
     against the real `tenants_slug_index` unique constraint.

  2. The POST-FIX mechanism (`Letflow.TenantSlugFixture.unique_slug/1`, an
     `Ecto.UUID.generate/0`-derived suffix) does NOT exhibit this failure —
     shown two ways: (a) the exact same "spawn independent fresh VMs" method
     used to prove the old mechanism collides, applied to the new mechanism,
     produces distinct slugs every time, because `Ecto.UUID.generate/0`'s
     122 bits of randomness are not seeded from any counter or value that
     resets across VM restarts; and (b) a `StreamData` property test
     generating thousands of `unique_slug/1` calls within a single run and
     asserting zero collisions.

  ## Why this is proven by spawning real OS processes, not "simulated"

  `System.unique_integer/1`'s own documentation states its uniqueness
  guarantee is scoped to "the current runtime system instance" — i.e. one
  BEAM VM run, not across runs. There is no supported way to reset that
  counter within a single running VM to fake a "VM restart", and faking one
  with a hand-picked low integer would only be *asserting* the bug, not
  *proving* it. Spawning `elixir -e ...` as a separate OS process is not a
  simulation — each invocation genuinely is a fresh BEAM VM, mechanically
  identical (for this counter's purposes) to what happens when a killed
  `mix test` run is followed by a fresh one. This gives a literal
  fail-then-pass demonstration for this specific bug class, rather than the
  property-test-only fallback this class of VM-restart bug would otherwise
  require.

  See `lib/letflow/design/iss059-flaky-slug-collision-fix.md` for the full
  fix design and the 30-file edit-pattern table, and
  `test/support/tenant_slug.ex` for the fixed helper itself.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Letflow.TenantSlugFixture

  # A bare `elixir -e` script (no Mix/app boot needed) computing exactly the
  # expression every one of the 30 affected files' pre-fix `insert_tenant!/0`
  # used: the first `unique_integer/1` call in a fresh VM.
  @old_mechanism_script "IO.write(System.unique_integer([:positive, :monotonic]))"

  # Regression for ISS-0059: proves the pre-fix `unique_integer/1` slug
  # mechanism collides across independent BEAM VM runs.
  describe "pre-fix mechanism collides across VM runs" do
    # Three independent, freshly-started BEAM VMs produce the identical
    # first unique_integer/1 value, i.e. the identical slug.
    test "collides across three fresh VMs" do
      # Each System.cmd call below launches a brand-new OS process running a
      # brand-new BEAM VM -- this is a real VM restart, not a stand-in for
      # one.
      results =
        for _ <- 1..3 do
          {output, 0} = write_script_and_run("elixir", @old_mechanism_script)
          output
        end

      old_slug = fn counter_value -> "req027-#{counter_value}" end
      slugs = Enum.map(results, old_slug)

      # This IS the bug: every "VM run" (crash-before-cleanup, then a fresh
      # `mix test` invocation) produces the same slug for the same file
      # prefix. Against a real `tenants_slug_index` unique constraint, the
      # second and third of these would each raise
      # `Ecto.InvalidChangesetError, tenants_slug_index has already been
      # taken` if the first run's row was never rolled back -- exactly
      # ISS-0059's observed symptom.
      assert Enum.uniq(slugs) == [hd(slugs)],
             "expected the pre-fix mechanism to collide across independent VM runs (that is the bug), got distinct slugs: #{inspect(slugs)}"
    end
  end

  # Proves the POST-FIX mechanism does not exhibit the same failure, using
  # the identical "spawn independent fresh VMs" method as the pre-fix case
  # above, applied to Letflow.TenantSlugFixture.unique_slug/1 instead.
  describe "post-fix unique_slug/1 avoids the cross-VM collision" do
    # Three independent, freshly-started BEAM VMs each computing
    # unique_slug/1 produce three distinct slugs.
    #
    # Heavier than the pre-fix case's bare `elixir -e` script because
    # Ecto.UUID.generate/0 needs `:ecto` on the code path, so each of the
    # three subprocesses boots via `mix run --no-start` instead of a raw
    # `elixir` invocation. Tagged :slow so a leaner CI profile can exclude it.
    @tag :slow
    test "distinct slugs across three fresh VMs" do
      script = ~s|IO.write(Letflow.TenantSlugFixture.unique_slug("req027"))|

      results =
        for _ <- 1..3 do
          {output, 0} = write_script_and_run("mix", script)
          output
        end

      # Every result has the fixed "req027-" prefix and a 36-character UUID
      # suffix, and -- unlike the old mechanism above -- all three are
      # distinct, because Ecto.UUID.generate/0's randomness is not seeded
      # from any counter or value that resets across VM restarts.
      assert Enum.all?(results, &String.starts_with?(&1, "req027-"))
      assert length(Enum.uniq(results)) == 3
    end
  end

  # Property coverage: no collisions across a large number of calls within a
  # single VM run (complements the cross-VM cases above).
  describe "unique_slug/1 property coverage" do
    # Generating thousands of slugs from arbitrary prefixes never produces a
    # duplicate.
    test "no duplicates across thousands of calls" do
      check all(
              prefixes <-
                StreamData.list_of(
                  StreamData.string(:alphanumeric, min_length: 1, max_length: 12),
                  length: 2_000
                ),
              max_runs: 1
            ) do
        slugs = Enum.map(prefixes, &TenantSlugFixture.unique_slug/1)

        assert length(Enum.uniq(slugs)) == length(slugs)
      end
    end

    # unique_slug/1 always returns "<prefix>-<36-char UUID>", regardless of
    # call order or repetition count.
    test "stable \"<prefix>-<uuid>\" format regardless of call order/count" do
      check all(
              prefix <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
              repeat_count <- StreamData.integer(1..25),
              max_runs: 30
            ) do
        slugs = for _ <- 1..repeat_count, do: TenantSlugFixture.unique_slug(prefix)

        assert Enum.all?(slugs, &String.starts_with?(&1, prefix <> "-"))

        assert Enum.all?(slugs, fn slug ->
                 String.length(slug) == String.length(prefix) + 1 + 36
               end)

        assert length(Enum.uniq(slugs)) == length(slugs)
      end
    end
  end

  # ISS-0065 WF-03 regression tests.
  #
  # Fail-then-pass boundary for BOTH tests below: `write_script_and_run/2` did not
  # exist before commit f90919f (design: ef888b5). Before that commit both
  # VM-spawning call sites passed the script inline as a `-e <script>` argv element
  # directly to `System.cmd/3` (confirmed: `git show ef888b5:test/support/tenant_slug_test.exs
  # | grep -c '"-e"'` returns 2, at the exact two call sites this fix touched). Neither
  # test below could even compile against that pre-fix source (test (a) would find
  # the literal `"-e"` and fail its assertion; test (b) calls a private function that
  # did not exist, a compile error) -- so both give a real fail-then-pass boundary
  # against the actual pre-fix commit, not an assumption.
  describe "ISS-0065 regression: no literal \"-e\" argv element passed to System.cmd" do
    # Structural/mechanism-level check: the Windows-unsafe pattern ISS-0065 fixed is
    # a literal "-e" element inside a System.cmd/2,3 call's argv list, at either
    # VM-spawning call site above. This parses this file's own source into an AST
    # and inspects only the argument lists of actual System.cmd/2,3 call nodes --
    # deliberately NOT a raw substring/regex scan of the file text, because this
    # test file's own comments and assertion messages legitimately discuss `"-e"`
    # in prose (see above) and would make a text-level scan self-defeating (a raw
    # `File.read!(__ENV__.file) =~ "-e"` scan was tried first and failed against
    # its own describe/test names and comments -- not a hypothetical concern, an
    # earlier draft of this test hit it). Verified against real commits: `git show
    # ef888b5:test/support/tenant_slug_test.exs` (pre-fix) parsed through this same
    # AST walk yields 2 offending call nodes (the exact two call sites the fix
    # touched); this file (post-fix, current HEAD) yields 0. This complements
    # (does not replace) the empirical cleanup test below: this test proves the
    # unsafe *pattern* is gone from the source; the test below proves the
    # *replacement* mechanism's cleanup guarantee actually holds at runtime.
    test "no System.cmd/2,3 call node in this file's AST has a literal \"-e\" argv element" do
      {:ok, ast} = Code.string_to_quoted(File.read!(__ENV__.file))

      {_ast, offending_calls} =
        Macro.prewalk(ast, [], fn
          {{:., _, [{:__aliases__, _, [:System]}, :cmd]}, _, args} = node, acc ->
            if Enum.any?(args, &(is_list(&1) and "-e" in &1)) do
              {node, [node | acc]}
            else
              {node, acc}
            end

          node, acc ->
            {node, acc}
        end)

      assert offending_calls == [],
             "found a System.cmd/2,3 call passing a literal \"-e\" argv element -- ISS-0065 " <>
               "replaced both VM-spawning call sites with write_script_and_run/2, which passes " <>
               "a bare temp-file path instead; a \"-e\" argv element here would reintroduce the " <>
               "Windows cmd.exe argv-mangling bug (mix.bat/elixir.bat re-parse `(`, `)`, `\"` " <>
               "inside an inline -e script -- see " <>
               "lib/letflow/design/iss065-windows-cmd-script-tempfile-fix.md)"
    end
  end

  describe "ISS-0065 regression: write_script_and_run/2 cleans up its temp file even when the subprocess fails" do
    # Negative-path/empirical check on write_script_and_run/2 itself (per the design
    # doc's acceptance criterion 5): forces a subprocess that exits nonzero (a
    # deliberate `raise` in the spawned script) and asserts no `letflow_iss0065_*`
    # temp file is left behind in System.tmp_dir!/0 afterward -- proving the
    # try/after cleanup guarantee empirically, not just by reading the code.
    test "temp file removed after a nonzero-exit subprocess (try/after runs on the failure path too)" do
      tmp_dir = System.tmp_dir!()
      before_files = Path.wildcard(Path.join(tmp_dir, "letflow_iss0065_*"))

      {_output, exit_status} =
        write_script_and_run(
          "elixir",
          ~s|raise "ISS-0065 negative-path cleanup test: forced failure"|
        )

      assert exit_status != 0,
             "expected the deliberate `raise` in the spawned script to produce a nonzero exit " <>
               "status; got 0 -- the negative path this test relies on didn't actually trigger"

      after_files = Path.wildcard(Path.join(tmp_dir, "letflow_iss0065_*"))

      assert after_files == before_files,
             "write_script_and_run/2 left a temp file behind after a failing subprocess -- the " <>
               "try/after cleanup (File.rm/1) must run unconditionally on both the success and " <>
               "failure paths, per iss065-windows-cmd-script-tempfile-fix.md's \"Cleanup " <>
               "semantics\" section"
    end
  end

  # ISS-0878 regression: unique_realm/1 must be built on Ecto.UUID.generate/0,
  # not any process-local/VM-local counter, since scripts/test_parallel.sh
  # shards the suite across independent OS processes (separate BEAM VMs)
  # against one shared Postgres instance -- see
  # lib/letflow/design/iss0878-unique-realm-cross-process-fix.md.
  #
  # The original bug (a cross-process race between two independently-started
  # BEAM VMs both making their first `unique_realm(same_prefix)` call in the
  # same window) is inherently timing-dependent and cannot be reliably
  # triggered on demand within a single test run -- unlike ISS-0059 above,
  # which the "spawn independent fresh VMs" technique can reproduce directly
  # because it only needs ONE fresh VM's first call to observe the counter
  # restart. A cross-process *collision* additionally needs two VMs' calls to
  # land in the same narrow window, which is not reliably reproducible on
  # demand. So this suite instead proves the fix's DISCRIMINATING property:
  # does the generated string embed a UUID (collision-proof across processes
  # and VMs by construction, since Ecto.UUID.generate/0's 122 bits of
  # randomness are not derived from any counter or value that resets), or a
  # small monotonic integer (guaranteed to eventually repeat across fresh
  # VMs, exactly as unique_slug/1's own ISS-0059 tests above demonstrate for
  # the identical underlying mechanism)? A System.unique_integer/1-based
  # suffix could never satisfy the UUID-format assertion below, so this is
  # sensitive to exactly the trap ISS-0878 fixes -- see this file's own
  # mutation-based fail-then-pass proof recorded in
  # handoffs/WF03-ISS0878-20260929/step-05-test-designer.json (unique_realm/1
  # is a NEW function; a naive "run against the pre-fix commit" only proves
  # the function didn't exist yet, which is a step failure per
  # docs/agents/workflows/WF-03_issue_resolving.md's "When the pre-fix
  # failure is 'the code under test does not exist'").
  describe "unique_realm/1 uses a UUID suffix, not a process-local counter (ISS-0878)" do
    @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

    # Trivially true for both the old and new implementation (any generator
    # with enough entropy passes this within a single process) -- included
    # only as a baseline sanity check, NOT as the discriminating assertion.
    # A test module calling unique_realm/1 hundreds of times per run (e.g.
    # provider_registry_multi_realm_test.exs's 12 call sites) needs this
    # in-process guarantee too, even though it alone doesn't prove the fix.
    test "no duplicates across a thousand calls in the same process" do
      check all(
              prefixes <-
                StreamData.list_of(
                  StreamData.string(:alphanumeric, min_length: 1, max_length: 12),
                  length: 1_000
                ),
              max_runs: 1
            ) do
        realms = Enum.map(prefixes, &TenantSlugFixture.unique_realm/1)

        assert length(Enum.uniq(realms)) == length(realms)
      end
    end

    # The DISCRIMINATING assertion: the suffix after "<prefix>-" must match
    # the exact format Ecto.UUID.generate/0 produces (8-4-4-4-12 lowercase
    # hex, hyphenated, 36 characters). This is what actually guarantees
    # cross-process/cross-VM uniqueness. A System.unique_integer/1-based
    # suffix (the pre-fix ISS-0878 mechanism, and the pre-fix ISS-0059
    # mechanism `unique_slug/1` replaced) produces bare decimal digits and
    # can never match this regex -- see the mutation proof in this run's
    # handoff for a direct demonstration against unique_realm/1 itself.
    test "the generated suffix matches the Ecto.UUID.generate/0 format" do
      check all(
              prefix <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
              repeat_count <- StreamData.integer(1..25),
              max_runs: 30
            ) do
        realms = for _ <- 1..repeat_count, do: TenantSlugFixture.unique_realm(prefix)

        assert Enum.all?(realms, &String.starts_with?(&1, prefix <> "-"))

        suffixes = Enum.map(realms, &String.replace_prefix(&1, prefix <> "-", ""))

        assert Enum.all?(suffixes, &(&1 =~ @uuid_regex)),
               "expected every unique_realm/1 suffix to match the Ecto.UUID.generate/0 " <>
                 "format #{inspect(@uuid_regex)} -- a System.unique_integer/1-based suffix " <>
                 "(the pre-fix ISS-0878 mechanism) produces bare decimal digits instead and " <>
                 "would fail this assertion: #{inspect(suffixes)}"

        assert length(Enum.uniq(realms)) == length(realms)
      end
    end

    # identity_test.exs calls unique_realm() with no argument at several
    # sites (design doc: lines 592, 599, 653, 765), so the default argument
    # path must independently get a UUID-format suffix too, not just the
    # explicit-prefix path exercised above.
    test "default prefix (\"realm\") also gets a UUID-format suffix" do
      realm = TenantSlugFixture.unique_realm()

      assert String.starts_with?(realm, "realm-")

      assert String.replace_prefix(realm, "realm-", "") =~ @uuid_regex,
             "expected the default-prefix call to also produce a UUID-format suffix, got: " <>
               realm
    end
  end

  # ISS-0065: writes `script_body` to a uniquely-named temp `.exs` file and
  # invokes `cmd` with that file's path as a plain argv element instead of
  # `-e <script>`. A bare path has none of the `(`, `)`, `"` characters that
  # `cmd.exe` re-parses on Windows when `mix`/`elixir` resolve to
  # `mix.bat`/`elixir.bat` -- see
  # `lib/letflow/design/iss065-windows-cmd-script-tempfile-fix.md` for the
  # full rationale. Behaves identically to today's `-e` invocation on Linux.
  @spec write_script_and_run(cmd :: String.t(), script_body :: String.t()) ::
          {output :: String.t(), exit_status :: non_neg_integer()}
  defp write_script_and_run(cmd, script_body) do
    filename =
      "letflow_iss0065_#{System.unique_integer([:positive, :monotonic])}_#{:erlang.unique_integer([:positive])}.exs"

    path = Path.join(System.tmp_dir!(), filename)

    File.write!(path, script_body)

    try do
      case cmd do
        "mix" ->
          System.cmd("mix", ["run", "--no-start", path],
            env: [{"MIX_ENV", "test"}],
            stderr_to_stdout: false
          )

        _ ->
          System.cmd(cmd, [path])
      end
    after
      File.rm(path)
    end
  end
end
