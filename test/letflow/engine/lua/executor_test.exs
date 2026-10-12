defmodule Letflow.Engine.Lua.ExecutorTest do
  @moduledoc """
  Tests for `Letflow.Engine.Lua.Executor` (REQ-153, LUA-02 restated). Covers all 8
  acceptance criteria from the requirement.

  No database access required — the isolation tests exercise only the Lua VM, and the
  INV-LSA-1 / INV-LSA-2 paths short-circuit before any Repo insert. `async: true` is
  safe.
  """

  use ExUnit.Case, async: true

  alias Letflow.Engine.Lua.Capabilities
  alias Letflow.Engine.Lua.Executor
  alias Letflow.Engine.Lua.Manifest
  alias Letflow.Engine.Lua.Platform
  alias Letflow.Engine.Lua.Sandbox
  alias Letflow.Engine.LuaScriptAudit

  # ---------------------------------------------------------------------------------
  # AC1 -- module exists and implements the Executor behaviour
  # ---------------------------------------------------------------------------------

  describe "behaviour implementation (AC1)" do
    test "Executor implements the Letflow.Engine.LuaScriptAudit.Executor behaviour" do
      behaviours =
        Executor.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Letflow.Engine.LuaScriptAudit.Executor in behaviours
    end

    test "execute_with_manifest/2 is exported" do
      # `function_exported?/3` checks only already-loaded code -- unlike calling a
      # function, it does not implicitly load the module first (see
      # `:erlang.function_exported/3`). Under `mix test --partitions`, ExUnit's
      # random async ordering can make this the very first reference to `Executor`
      # in that partition's VM, so without `Code.ensure_loaded/1` first this
      # assertion is a real, reproduced flake (not a race in the code under test).
      assert {:module, Executor} = Code.ensure_loaded(Executor)
      assert function_exported?(Executor, :execute_with_manifest, 2)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- lua_script_audit.ex does NOT reference the concrete Executor module
  # ---------------------------------------------------------------------------------

  describe "lua_script_audit.ex isolation (AC2)" do
    test "lua_script_audit.ex does not reference Letflow.Engine.Lua.Executor" do
      source = File.read!("lib/letflow/engine/lua_script_audit.ex")

      refute source =~ "Letflow.Engine.Lua.Executor",
             "lua_script_audit.ex must not directly reference the concrete Executor module"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- global isolation: a global set in execution 1 is absent in execution 2
  # ---------------------------------------------------------------------------------

  describe "global isolation (AC3)" do
    test "a global written in execution 1 is absent in execution 2" do
      # Execution 1: set a global
      assert {:ok, _} =
               Executor.run_script_sync(
                 %Manifest{script_id: "", capabilities: []},
                 "MY_GLOBAL = 42",
                 100_000
               )

      # Execution 2 through the same executor: if MY_GLOBAL leaked, Lua's error() fires
      # and the executor returns {:error, _}. assert {:ok, _} therefore PROVES absence.
      # (Asserting {:ok, _} on `return MY_GLOBAL` would be vacuous because execute_with_manifest
      # discards the Lua return value -- both nil and 42 would yield {:ok, _} there.)
      assert {:ok, _} =
               Executor.run_script_sync(
                 %Manifest{script_id: "", capabilities: []},
                 "if MY_GLOBAL ~= nil then error('global_leaked: MY_GLOBAL = ' .. tostring(MY_GLOBAL)) end",
                 100_000
               ),
             "MY_GLOBAL must be absent (nil) in a fresh executor invocation"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- distinct state: table mutated in exec 1 is pristine in exec 2
  # ---------------------------------------------------------------------------------

  describe "distinct state (AC4)" do
    test "a table mutated in execution 1 is pristine in execution 2" do
      # Execution 1: create and populate a table
      assert {:ok, _} =
               Executor.run_script_sync(
                 %Manifest{script_id: "", capabilities: []},
                 "T = {}; T.x = 99",
                 100_000
               )

      # Execution 2 through the same executor: if T leaked, Lua's error() fires and the
      # executor returns {:error, _}. assert {:ok, _} PROVES T is nil/absent.
      assert {:ok, _} =
               Executor.run_script_sync(
                 %Manifest{script_id: "", capabilities: []},
                 "if T ~= nil then error('table_T_leaked: T.x = ' .. tostring(T.x)) end",
                 100_000
               ),
             "table T from execution 1 must not survive into execution 2"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- INV-LSA-1: invalid instance_id short-circuits before executor is invoked
  # ---------------------------------------------------------------------------------

  describe "INV-LSA-1 with real executor (AC5)" do
    test "nil instance_id short-circuits and the real executor is never called" do
      result =
        LuaScriptAudit.execute_script_for_audit(
          Executor,
          nil,
          "return 1",
          "any-hash",
          Ecto.UUID.generate(),
          prefix: "test_schema"
        )

      assert result == {:error, :invalid_instance_id}
    end

    test "malformed instance_id short-circuits and the real executor is never called" do
      result =
        LuaScriptAudit.execute_script_for_audit(
          Executor,
          "not-a-uuid",
          "return 1",
          "any-hash",
          Ecto.UUID.generate(),
          prefix: "test_schema"
        )

      assert result == {:error, :invalid_instance_id}
    end
  end

  # ---------------------------------------------------------------------------------
  # AC6 -- INV-LSA-2: manifest hash mismatch with real executor
  # ---------------------------------------------------------------------------------

  describe "INV-LSA-2 with real executor (AC6)" do
    test "a registered_hash that does not match the script's manifest+script hash returns mismatch error" do
      script = "return 2 + 2"
      # REQ-158: a bare-binary script_ref is paired with an empty manifest
      # (script_id: "", capabilities: []) -- the hash is Manifest.compute_hash/2's
      # output, not the bare SHA-256 of the script source alone.
      real_hash = Manifest.compute_hash(%Manifest{script_id: "", capabilities: []}, script)
      wrong_hash = "0000000000000000000000000000000000000000000000000000000000000000"

      assert wrong_hash != real_hash

      result =
        LuaScriptAudit.execute_script_for_audit(
          Executor,
          Ecto.UUID.generate(),
          script,
          wrong_hash,
          Ecto.UUID.generate(),
          prefix: "test_schema"
        )

      assert {:error, {:manifest_hash_mismatch, ^wrong_hash, ^real_hash}} = result
    end
  end

  # ---------------------------------------------------------------------------------
  # AC7 -- moduledoc documents the script_ref concrete shape
  # ---------------------------------------------------------------------------------

  describe "moduledoc documents script_ref shape (AC7)" do
    test "the module's @moduledoc mentions that script_ref is a binary (Lua source text)" do
      docs = Code.fetch_docs(Executor)
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = docs

      assert moduledoc =~ "binary",
             "moduledoc must state that script_ref is a binary; got:\n#{moduledoc}"
    end
  end

  # ---------------------------------------------------------------------------------
  # Bonus: successful execution returns the correct SHA-256 manifest hash
  # ---------------------------------------------------------------------------------

  describe "manifest hash correctness" do
    test "execute_with_manifest returns Manifest.compute_hash/2's output over an empty manifest for a bare-binary script_ref" do
      script = "return 'hello'"
      expected_hash = Manifest.compute_hash(%Manifest{script_id: "", capabilities: []}, script)

      assert {:ok, %{manifest_hash: ^expected_hash}} =
               Executor.run_script_sync(
                 %Manifest{script_id: "", capabilities: []},
                 script,
                 100_000
               )
    end

    test "a Lua syntax error returns {:error, reason}" do
      assert {:error, _reason} =
               Executor.run_script_sync(
                 %Manifest{script_id: "", capabilities: []},
                 "this is not lua ===",
                 100_000
               )
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-158 -- script_ref widened to optionally carry a Manifest.t() alongside the
  # script source; manifest_hash now covers manifest+script bytes via
  # Manifest.compute_hash/2, not the bare script-source hash alone.
  # ---------------------------------------------------------------------------------

  describe "REQ-158: manifest-aware script_ref" do
    test "a %{manifest:, script_source:} script_ref produces Manifest.compute_hash/2's exact output" do
      manifest = %Manifest{script_id: "script-abc", capabilities: ["variable:read"]}
      script = "return 1 + 1"
      expected_hash = Manifest.compute_hash(manifest, script)

      assert {:ok, %{manifest_hash: ^expected_hash}} =
               Executor.run_script_sync(manifest, script, 100_000)
    end

    test "changing the manifest's capabilities (script source unchanged) changes the returned hash" do
      script = "return 1 + 1"
      manifest_a = %Manifest{script_id: "script-abc", capabilities: ["variable:read"]}

      manifest_b = %Manifest{
        script_id: "script-abc",
        capabilities: ["variable:read", "variable:write"]
      }

      assert {:ok, %{manifest_hash: hash_a}} =
               Executor.run_script_sync(manifest_a, script, 100_000)

      assert {:ok, %{manifest_hash: hash_b}} =
               Executor.run_script_sync(manifest_b, script, 100_000)

      refute hash_a == hash_b,
             "a modified capability list must change the manifest_hash Executor returns"
    end

    test "a script_ref that is neither a binary nor a %{manifest:, script_source:} map returns {:error, :invalid_script_ref}" do
      assert {:error, :invalid_script_ref} = Executor.execute_with_manifest(12345, "h")
      assert {:error, :invalid_script_ref} = Executor.execute_with_manifest(%{}, "h")

      assert {:error, :invalid_script_ref} =
               Executor.execute_with_manifest(
                 %{manifest: :not_a_manifest, script_source: "x"},
                 "h"
               )
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-154 -- instruction budget (LUA-08 layer 1)
  # ---------------------------------------------------------------------------------

  describe "instruction budget (REQ-154)" do
    # AC-1: configurable budget -- two different budgets produce different outcomes
    # for a loop that exceeds 500 instructions but not 5000.
    # ISS-0426 design §2.1.1: no assertion here depends on wall-clock time -- the
    # outcome is fully determined by the workload alone -- so this call is routed
    # through Executor.run_script_sync/3 (no Task/Task.yield in its call chain)
    # instead of racing execute_with_manifest/3's wall-clock kill under contention.
    test "AC-1: smaller budget halts sooner than larger budget on the same loop" do
      # This loop runs many more than 500 instructions but fewer than 50000.
      loop_script = "for i = 1, 5000 do end"
      empty_manifest = %Manifest{script_id: "", capabilities: []}

      assert {:error, {:budget_exceeded, 500}} =
               Executor.run_script_sync(empty_manifest, loop_script, 500)

      assert {:ok, %{manifest_hash: _}} =
               Executor.run_script_sync(empty_manifest, loop_script, 50000)
    end

    # AC-2: while true terminates under a budget rather than hanging.
    # ISS-0426 design §2.1.1: routed through the synchronous seam, see AC-1 above.
    test "AC-2: while true do end terminates with budget_exceeded rather than hanging" do
      assert {:error, {:budget_exceeded, 1000}} =
               Executor.run_script_sync(
                 %Manifest{script_id: "", capabilities: []},
                 "while true do end",
                 1000
               )
    end

    # AC-3: budget exhaustion is distinguishable by pattern match from other error arms.
    # ISS-0426 design §2.1.1: routed through the synchronous seam, see AC-1 above.
    test "AC-3: budget_exceeded is a structured error, not a bare string or atom" do
      result =
        Executor.run_script_sync(
          %Manifest{script_id: "", capabilities: []},
          "while true do end",
          500
        )

      # Must NOT match {:error, msg} (string) or {:error, :invalid_script_ref}
      assert {:error, {:budget_exceeded, _limit}} = result
    end

    # AC-4: REQ-148 spike OQ-2(a) -- pcall catches budget exhaustion inside the script.
    # The inner loop stops, pcall returns {false, "instruction budget exceeded"}, and
    # Lua.eval!/2 returns normally. This is expected layer-1 behavior: the script
    # receives control back after pcall. Layer 2 (REQ-155) provides the non-catchable kill.
    # ISS-0426 design §2.1.1: routed through the synchronous seam, see AC-1 above.
    test "AC-4: pcall-caught budget exhaustion returns {:ok, _} -- layer-1 pcall-catchable" do
      script = """
      local ok, err = pcall(function() while true do end end)
      return ok, tostring(err)
      """

      assert {:ok, %{manifest_hash: _}} =
               Executor.run_script_sync(%Manifest{script_id: "", capabilities: []}, script, 1000)
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-155 -- host-enforced wall-clock kill (LUA-10 layer 2)
  # ---------------------------------------------------------------------------------
  #
  # All tests here target execute_with_manifest/3 so each test drives its own
  # :timeout_ms independent of Application config (test/specs/REQ-155.md's stated
  # rationale). config/test.exs sets a short :lua_wallclock_timeout_ms (5000ms) for
  # any incidental /2-arity default-path use, but no test below relies on it.

  describe "wall-clock timeout (REQ-155)" do
    @infinite_loop "while true do end"

    # T1/AC-1: timeout is configurable -- two different configured timeouts produce
    # measurably different elapsed wall-clock time on the same hanging script, and
    # the shorter one's error carries its own configured value (not a hardcoded
    # constant).
    # ISS-0426 design §2.2: genuinely races the wall-clock kill (numeric elapsed-time
    # comparison) -- tag-isolated into the low-concurrency :lua_wallclock_race
    # partition rather than restructured, since this test's own property requires the
    # race.
    @tag :lua_wallclock_race
    test "AC-1: a shorter configured timeout terminates measurably sooner than a longer one" do
      {short_elapsed_us, short_result} =
        :timer.tc(fn ->
          Executor.execute_with_manifest(@infinite_loop, "h",
            max_instructions: 1_000_000_000,
            timeout_ms: 100,
            max_heap_words: nil
          )
        end)

      {long_elapsed_us, long_result} =
        :timer.tc(fn ->
          Executor.execute_with_manifest(@infinite_loop, "h",
            max_instructions: 1_000_000_000,
            timeout_ms: 600,
            max_heap_words: nil
          )
        end)

      assert {:error, {:wallclock_timeout, 100}} = short_result
      assert {:error, {:wallclock_timeout, 600}} = long_result

      short_elapsed_ms = short_elapsed_us / 1_000
      long_elapsed_ms = long_elapsed_us / 1_000

      # The short call must not have waited anywhere near as long as the long
      # call's configured timeout -- generous margin to keep this non-flaky under
      # CI scheduling jitter while still proving the configured value (not a fixed
      # constant) drives the elapsed time.
      assert short_elapsed_ms < 400,
             "short-timeout call took #{short_elapsed_ms}ms, expected well under 400ms"

      assert long_elapsed_ms > short_elapsed_ms,
             "long-timeout call (#{long_elapsed_ms}ms) should take longer than the " <>
               "short-timeout call (#{short_elapsed_ms}ms)"
    end

    # T2/AC-2: decision 0014's required two-layer test. A script that traps its own
    # :max_instructions exhaustion (via pcall) and re-enters a second unbounded loop
    # must STILL be terminated by the wall-clock layer -- this must fail if layer 2
    # is removed or bypassed, since the script never lets the in-band budget error
    # propagate.
    #
    # Verified empirically against the tv-labs/lua runtime (not assumed): a *second*
    # `while`/`for` loop after the budget trips is NOT a usable reproduction here --
    # this runtime's :max_instructions counter is permanently exhausted once tripped,
    # so any further `while`/`for` iteration re-raises {:budget_exceeded, _} almost
    # immediately (confirmed via scratch probes against
    # Letflow.Engine.Lua.Sandbox/Lua.eval! directly), which layer 1 alone already
    # terminates -- it would not distinguish "layer 2 present" from "layer 2 removed"
    # and so would not be the test decision 0014 requires. A `goto`-based loop,
    # however, is NOT instrumented by this runtime's instruction-budget check at all
    # (confirmed empirically: it hangs indefinitely with no :max_instructions error),
    # which is precisely LUA-10's own point -- a hostile script can always find an
    # in-band escape hatch the counter does not cover, and only a host-external,
    # non-cooperative kill can bound it. This script traps the first while-loop's
    # budget error via pcall (proving the script observed and ignored it), then
    # continues running via `goto`, invisible to :max_instructions, so only the
    # wall-clock layer can end the call.
    # ISS-0426 design §2.2: race outcome (wallclock_timeout must win) is the point of
    # this test -- tag-isolated, not restructured.
    @tag :lua_wallclock_race
    test "AC-2: wall-clock timeout still fires when the script traps its own budget error and loops again via a construct the instruction budget does not instrument" do
      script = """
      local ok, err = pcall(function() while true do end end)
      -- budget error caught and ignored here; script deliberately keeps running
      -- instead of returning, via a construct :max_instructions does not check.
      ::top::
      goto top
      """

      assert {:error, {:wallclock_timeout, 300}} =
               Executor.execute_with_manifest(script, "h",
                 max_instructions: 200,
                 timeout_ms: 300,
                 max_heap_words: nil
               )
    end

    # T3/AC-3: the killed task's process is actually dead, not merely abandoned.
    # ISS-0426 design §2.2: post-kill supervisor state depends on the real timeout
    # kill firing -- tag-isolated, not restructured.
    @tag :lua_wallclock_race
    test "AC-3: the task's process is dead and no longer tracked by the supervisor after a timeout" do
      children_before = Task.Supervisor.children(Letflow.Engine.Lua.TaskSupervisor)

      assert {:error, {:wallclock_timeout, 150}} =
               Executor.execute_with_manifest(@infinite_loop, "h",
                 max_instructions: 1_000_000_000,
                 timeout_ms: 150,
                 max_heap_words: nil
               )

      # Give the (already brutally-killed) task's DOWN bookkeeping a moment to
      # settle inside the supervisor, then confirm no new child lingers relative
      # to before the call -- the kill removed exactly the child it started, not
      # merely abandoned it while the caller stopped waiting.
      Process.sleep(50)

      children_after = Task.Supervisor.children(Letflow.Engine.Lua.TaskSupervisor)

      assert Enum.sort(children_after) == Enum.sort(children_before),
             "no task started by the timed-out call may remain a child of " <>
               "Letflow.Engine.Lua.TaskSupervisor after the call returns"
    end

    # T4/AC-4: the timeout error is a distinct, pattern-matchable shape.
    # ISS-0426 design §2.2: race outcome -- tag-isolated, not restructured.
    @tag :lua_wallclock_race
    test "AC-4: wallclock_timeout does not match budget_exceeded, a bare string, or invalid_script_ref" do
      result =
        Executor.execute_with_manifest(@infinite_loop, "h",
          max_instructions: 1_000_000_000,
          timeout_ms: 100,
          max_heap_words: nil
        )

      assert {:error, {:wallclock_timeout, 100}} = result
      refute match?({:error, {:budget_exceeded, _}}, result)
      refute match?({:error, msg} when is_binary(msg), result)
      refute match?({:error, :invalid_script_ref}, result)
    end

    # T5/AC-4: regression guard -- budget_exceeded remains its own distinct shape
    # and is never confused with wallclock_timeout, even under a generous timeout
    # that plays no role in the outcome.
    # ISS-0426 design §2.1.1: this assertion is fully determined by the workload
    # (budget_exceeded on an infinite loop with a tight budget) and never mentions
    # wall-clock time -- routed through the synchronous seam instead of racing the
    # (irrelevant to this test) wall-clock kill under contention.
    test "AC-4 regression guard: budget_exceeded is unaffected by a generous timeout and stays distinct" do
      result =
        Executor.run_script_sync(%Manifest{script_id: "", capabilities: []}, @infinite_loop, 500)

      assert {:error, {:budget_exceeded, 500}} = result
      refute match?({:error, {:wallclock_timeout, _}}, result)
      refute match?({:error, msg} when is_binary(msg), result)
      refute match?({:error, :invalid_script_ref}, result)
    end

    # T6/AC-5: execution runs under the named, dedicated supervisor.
    # ISS-0426 design §2.2: in-flight task state + eventual timeout -- tag-isolated,
    # not restructured.
    @tag :lua_wallclock_race
    test "AC-5: the running script is a child of Letflow.Engine.Lua.TaskSupervisor while in flight" do
      test_pid = self()

      task =
        Task.async(fn ->
          send(test_pid, :started)

          Executor.execute_with_manifest(@infinite_loop, "h",
            max_instructions: 1_000_000_000,
            timeout_ms: 30_000,
            max_heap_words: nil
          )
        end)

      assert_receive :started, 1_000

      # ISS-1040: locate THIS call's own child (matched via $callers) under a
      # monotonic deadline, then end the script deterministically by killing it.
      # The script's life is bounded by this test (timeout_ms: 30_000 is only a
      # ceiling), never by a fixed ~200 ms poll inside a 300 ms script.
      child = await_own_child(task.pid, 5_000)

      assert is_pid(child), "expected at least one in-flight child while the script is running"

      Process.exit(child, :kill)

      assert {:error, "Letflow.Engine.Lua.Executor task crashed: :killed"} =
               Task.await(task, 5_000)
    end

    test "AC-5: moduledoc names Letflow.Engine.Lua.TaskSupervisor and justifies not reusing PluginTaskSupervisor" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Executor)

      assert moduledoc =~ "Letflow.Engine.Lua.TaskSupervisor"
      assert moduledoc =~ "Letflow.Engine.PluginTaskSupervisor"
    end

    # T7/AC-6: moduledoc restates LUA-10 as layer 2 and the non-interchangeability
    # rationale.
    test "AC-6: moduledoc restates LUA-10 as layer 2 of the LUA-08/LUA-10 pair" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Executor)

      assert moduledoc =~ "LUA-10"
      assert moduledoc =~ "layer 2"
      assert moduledoc =~ "enforced by the host"
      assert moduledoc =~ "cooperate"
      # AC-6 also requires the moduledoc to state that neither LUA-08 nor LUA-10 is
      # satisfied without both layers landed together -- distinct from merely naming
      # "layer 2", which the four assertions above already cover.
      assert moduledoc =~ "Neither LUA-08 nor LUA-10 is met",
             "moduledoc must state that neither LUA-08 nor LUA-10 is met without both layers"
    end

    # T8/AC-7: moduledoc carries forward the BEAM-node-kill / System.halt/0
    # limitation disclosure.
    test "AC-7: moduledoc discloses the BEAM-node-kill / System.halt/0 limitation" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Executor)

      assert moduledoc =~ "System.halt/0"
      assert moduledoc =~ "BEAM node"
      # A bare "NOT" is too weak on its own to prove the disclosure is attached to the
      # right subject -- assert it appears specifically as the negation covering the
      # BEAM-node-kill / System.halt/0 sentence, not merely somewhere unrelated in the
      # moduledoc.
      assert moduledoc =~ "does **NOT** cover a hard kill of the BEAM node",
             "moduledoc must explicitly negate coverage of a BEAM node kill / System.halt/0"
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-156 -- configurable memory limit (LUA-09 restated)
  # ---------------------------------------------------------------------------------
  #
  # All tests here target execute_with_manifest/3 so each test drives its own
  # :max_heap_words explicitly (test/specs/REQ-156.md's stated rationale, mirroring
  # REQ-154/155's own pattern) -- no test relies on config/test.exs's
  # :lua_max_heap_words default.
  #
  # Word/byte conversion: :max_heap_words counts BEAM machine words, not bytes.
  # word_size_bytes comes from :erlang.system_info(:wordsize) (typically 8 on a
  # 64-bit BEAM) rather than a hardcoded `8` literal, per design §3, so the
  # conversion stays correct if this ever runs on a different word size.
  describe "configurable memory limit (REQ-156)" do
    @word_size_bytes :erlang.system_info(:wordsize)

    # LUA-09's own acceptance text names "1 GB attempted / 16 MB limit" as the scale
    # to test at -- both are converted from the literal MB/GB figures via
    # @word_size_bytes rather than picked "for convenience". This script is shared by
    # T2 and T3's third arm (per the design's coverage note), but each test below
    # independently asserts its own outcome rather than depending on the other
    # having run first.
    @sixteen_mb_in_words trunc(16 * 1024 * 1024 / @word_size_bytes)
    @gigabyte_allocating_script """
    local t = {}
    for i = 1, 1000000 do
      -- 1000 x 1024-byte chunks per outer iteration isn't needed -- one 1024-byte
      -- string per iteration, times 1,000,000 iterations, targets ~1 GB total
      -- (1_000_000 * 1024 bytes ~= 976 MB), matching LUA-09's own "1 GB" example.
      t[i] = string.rep("x", 1024)
    end
    return #t
    """

    # AC-1 uses a smaller allocating script than AC-2's literal "1 GB" scale, for test
    # speed only -- running @gigabyte_allocating_script to full, unkilled completion
    # (needed for AC-1's "larger limit succeeds" arm) measured ~18s real time in this
    # environment (tv-labs/lua interpreter throughput, not the memory-limit mechanism
    # under test), which is too slow to run twice per `mix test` invocation across
    # dozens of CI/local runs. This script targets ~20 MB (20,000 x 1024-byte
    # strings) -- a 1:20 attempted/limit ratio against @small_alloc_heap_words below
    # (~1 MB), the same order of magnitude as AC-2's own 1 GB : 16 MB (~1:64) ratio,
    # so it still genuinely exercises the same mechanism rather than being a
    # convenience no-op. AC-2 below keeps the literal "1 GB attempted / 16 MB limit"
    # scale LUA-09's own acceptance criterion names, unscaled.
    @small_alloc_heap_words trunc(1 * 1024 * 1024 / @word_size_bytes)
    @moderate_allocating_script """
    local t = {}
    for i = 1, 20000 do
      t[i] = string.rep("x", 1024)
    end
    return #t
    """

    # AC-1/T1: the memory limit is configurable per call (not hardcoded) -- a smaller
    # configured limit halts the same allocating script with a structured error,
    # while a materially larger limit lets the same script run to completion. This
    # demonstrates the configured value is load-bearing (not a no-op), per design
    # §8 AC-1 and test/specs/REQ-156.md T1's "outcome differs" alternative to a pure
    # timing comparison.
    # ISS-0426 design §2.1.2: neither arm's outcome depends on wall-clock time (both
    # assert memory_limit_exceeded/:ok, never wallclock_timeout), so both calls are
    # routed through Executor.run_with_heap_limit_sync/4 (no `after` clause in its
    # receive block) instead of racing run_with_heap_limit/5's own caller-timeout
    # kill under contention. Both scripts are fixed-iteration loops that terminate
    # either by natural completion or by tripping max_heap_words -- satisfying that
    # seam's binding usage contract (design §2.1.2a, restated in the seam's own
    # @doc false).
    # ISS-0469 (a repeat of ISS-0446's identical file:line flake): this test used to
    # also wrap both calls in :timer.tc/1 and assert small_elapsed_ms < large_elapsed_ms
    # as additional proof the smaller limit takes effect sooner. That wall-clock
    # comparison has been removed -- it was redundant with, not additive to, the
    # deterministic outcome assertions below (small limit errors, large limit
    # succeeds on the identical script), which alone already prove the configured
    # limit is load-bearing per REQ-156.md T1's own accepted "outcome differs"
    # alternative. The timing assertion added nothing but a source of CI-scheduler-
    # contention flakiness (observed 440ms vs 398ms margin on an otherwise-identical
    # rerun) with no test now depending on wall-clock time at all.
    test "AC-1: a smaller configured max_heap_words halts the allocating script while a materially larger one lets the same script complete" do
      empty_manifest = %Manifest{script_id: "", capabilities: []}

      small_result =
        Executor.run_with_heap_limit_sync(
          empty_manifest,
          @moderate_allocating_script,
          1_000_000_000,
          @small_alloc_heap_words
        )

      large_result =
        Executor.run_with_heap_limit_sync(
          empty_manifest,
          @moderate_allocating_script,
          1_000_000_000,
          trunc(200 * 1024 * 1024 / @word_size_bytes)
        )

      assert {:error, :memory_limit_exceeded} = small_result
      assert {:ok, %{manifest_hash: _}} = large_result
    end

    # AC-2/T2: LUA-09's own acceptance criterion, at the scale it names -- a script
    # attempting to allocate ~1 GB under a ~16 MB configured limit fails cleanly with
    # a structured error, rather than hanging, exhausting the test node's memory, or
    # returning success. The outer ExUnit test timeout (default 60s, well above this
    # call's own 5_000ms :timeout_ms) is this test's own safety bound -- if a
    # regression removed the memory-kill path entirely, this call would return
    # {:error, {:wallclock_timeout, 5_000}} instead (still a structured error, not a
    # hang), and the assertion below would fail loudly rather than the suite hanging.
    # ISS-0426 design §2.1.2: routed through the synchronous heap-limited seam, see
    # AC-1 above -- this script's own comment already establishes it terminates via
    # the BEAM heap-kill, satisfying the seam's binding usage contract.
    test "AC-2: a script attempting to allocate 1 GB under a 16 MB configured limit fails cleanly" do
      assert {:error, :memory_limit_exceeded} =
               Executor.run_with_heap_limit_sync(
                 %Manifest{script_id: "", capabilities: []},
                 @gigabyte_allocating_script,
                 1_000_000_000,
                 @sixteen_mb_in_words
               )
    end

    # AC-3/T3: the memory-limit error is pattern-distinguishable from REQ-154's
    # budget_exceeded and REQ-155's wallclock_timeout -- one case/cond construct
    # matches all three arms distinctly, proving no two can unify under one pattern.
    #
    # ISS-0426 design §2.4: mixed test -- one of its three calls (timeout_result)
    # genuinely races the wall-clock kill, so the whole test is tag-isolated. The
    # other two calls (budget_result, memory_result) are deliberately left as
    # literal execute_with_manifest/3 calls rather than converted to §2.1's
    # synchronous seams -- they inherit this tag's contention mitigation "for free"
    # once the whole test is isolated; see design §2.4 for why converting only two of
    # three calls in one test body was rejected.
    @tag :lua_wallclock_race
    test "AC-3: memory_limit_exceeded is pattern-distinguishable from budget_exceeded and wallclock_timeout" do
      budget_result =
        Executor.execute_with_manifest("while true do end", "h",
          max_instructions: 500,
          timeout_ms: 5_000,
          max_heap_words: nil
        )

      timeout_result =
        Executor.execute_with_manifest("while true do end", "h",
          max_instructions: 1_000_000_000,
          timeout_ms: 200,
          max_heap_words: nil
        )

      memory_result =
        Executor.execute_with_manifest(@gigabyte_allocating_script, "h",
          max_instructions: 1_000_000_000,
          timeout_ms: 5_000,
          max_heap_words: @sixteen_mb_in_words
        )

      classify = fn
        {:error, {:budget_exceeded, _}} -> :budget_exceeded
        {:error, {:wallclock_timeout, _}} -> :wallclock_timeout
        {:error, :memory_limit_exceeded} -> :memory_limit_exceeded
        other -> other
      end

      assert classify.(budget_result) == :budget_exceeded
      assert classify.(timeout_result) == :wallclock_timeout
      assert classify.(memory_result) == :memory_limit_exceeded

      classified = Enum.map([budget_result, timeout_result, memory_result], classify)

      assert Enum.uniq(classified) == classified,
             "all three resource-limit arms must classify distinctly; got #{inspect(classified)}"
    end

    # AC-6/T6: no code path in this module uses :max_instructions as a memory-limit
    # proxy -- static/source-level check, since this is a negative claim about the
    # absence of a code path (design §9, test/specs/REQ-156.md T6 item 1).
    test "AC-6: no code path reads max_heap_words when computing max_instructions, or vice versa" do
      source = File.read!("lib/letflow/engine/lua/executor.ex")

      # Sandbox.new/1 (which applies max_instructions to the Lua VM) is called with
      # only `budget`, never mentioning max_heap_words on the same call.
      assert source =~ "Sandbox.new(max_instructions: budget)"

      # The spawn_opt max_heap_size map is built only from max_heap_words, never from
      # budget/max_instructions.
      assert source =~ "max_heap_size: %{size: max_heap_words"
      refute source =~ "max_heap_size: %{size: budget"
    end

    # AC-5/T5: moduledoc restates LUA-09 and states which clause is met and which is
    # not, in those words.
    test "AC-5: moduledoc restates LUA-09 and states 'terminate' MET / 'fail gracefully' NOT MET" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Executor)

      assert moduledoc =~ "LUA-09"
      assert moduledoc =~ ~s("terminate the script" is MET)
      assert moduledoc =~ ~s("fail gracefully" is NOT MET)
    end

    # AC-6/T6: moduledoc records the :max_instructions-as-memory-proxy rejection,
    # citing decision 0014 OQ-1 by name.
    test "AC-6: moduledoc states :max_instructions was rejected as a memory proxy, citing decision 0014 OQ-1" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Executor)

      assert moduledoc =~ "rejected as a memory-limit proxy"
      assert moduledoc =~ "decision 0014"
      assert moduledoc =~ "OQ-1"
    end

    # AC-4: moduledoc states the Task.Supervisor.async_nolink/2,3 finding plainly
    # (§7 item 3 of the design) rather than silently resolving it.
    test "AC-4: moduledoc states Task.Supervisor.async_nolink/2,3 cannot carry max_heap_size" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Executor)

      assert moduledoc =~ "Task.Supervisor.async_nolink/2,3` cannot carry `:max_heap_size`"
      assert moduledoc =~ ":erlang.spawn_opt/2"
    end

    # A configured max_heap_words of nil keeps the REQ-155 supervised-task path
    # observable exactly as before -- a nil-limit execution still shows up as a
    # Letflow.Engine.Lua.TaskSupervisor child while in flight, unlike a
    # memory-limited execution (design §5.4).
    # ISS-0426 design §2.2: in-flight task state + eventual timeout -- tag-isolated,
    # not restructured.
    @tag :lua_wallclock_race
    test "a nil max_heap_words leaves the REQ-155 TaskSupervisor-based path unchanged" do
      test_pid = self()

      task =
        Task.async(fn ->
          send(test_pid, :started)

          Executor.execute_with_manifest("while true do end", "h",
            max_instructions: 1_000_000_000,
            timeout_ms: 30_000,
            max_heap_words: nil
          )
        end)

      assert_receive :started, 1_000

      # ISS-1040: see the AC-5 in-flight test above -- own-child lookup under a
      # monotonic deadline, deterministic release by kill.
      child = await_own_child(task.pid, 5_000)

      assert is_pid(child),
             "a nil max_heap_words call must still run under Letflow.Engine.Lua.TaskSupervisor"

      Process.exit(child, :kill)

      assert {:error, "Letflow.Engine.Lua.Executor task crashed: :killed"} =
               Task.await(task, 5_000)
    end

    # Gap found by TEST-DESIGNER mutation testing: design §5.1's fourth table row and
    # §5.2 specify a caller-issued kill ("this path's Task.shutdown(:brutal_kill)
    # equivalent") when a script hangs WITHOUT tripping the heap limit while a memory
    # limit IS configured -- a materially different code branch inside
    # run_with_heap_limit/4 (the `after timeout_ms -> Process.exit(pid, :kill) ...`
    # clause) than the BEAM-issued heap-kill branch AC-1/AC-2/AC-3 above exercise.
    # Confirmed by mutation: replacing that branch's body with a bogus return value
    # left all 32 then-existing REQ-156/154/155 tests passing (no test exercised this
    # branch), and reverting the mutation restored the pre-mutation pass count -- so
    # this test was added to close that gap, not merely to report it.
    # ISS-0426 design §2.2: race outcome (caller-kill branch, not heap-kill) is the
    # entire point of this test -- tag-isolated, not restructured. Still exercises
    # run_with_heap_limit/5's own `after` clause, untouched by this run's two new
    # seams.
    @tag :lua_wallclock_race
    test "a memory-limited call whose script hangs without tripping the heap limit is terminated by the caller's own timeout kill, not the BEAM heap-kill path" do
      # A tight `while true do end` loop allocates essentially nothing on the Lua
      # heap, so a heap limit generous enough to never trip (200 MB, same order of
      # magnitude as AC-1's "large" limit above) leaves only the caller's own
      # wall-clock bound to end this call.
      generous_heap_words = trunc(200 * 1024 * 1024 / @word_size_bytes)

      assert {:error, {:wallclock_timeout, 250}} =
               Executor.execute_with_manifest("while true do end", "h",
                 max_instructions: 1_000_000_000,
                 timeout_ms: 250,
                 max_heap_words: generous_heap_words
               )
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-162 -- uncaught Lua runtime errors captured as structured SCRIPT_ERROR
  # (LUA-16 restated). Covers all 8 acceptance criteria.
  # ---------------------------------------------------------------------------------

  describe "SCRIPT_ERROR capture (REQ-162)" do
    # AC1: a structured SCRIPT_ERROR carries a stack trace and capability state at
    # failure -- asserted individually.
    # ISS-0426 design §2.1.1: script_error is fully determined by the workload
    # (1 // 0 always raises), no wall-clock assertion here -- routed through the
    # synchronous seam.
    test "AC1: an uncaught runtime error produces SCRIPT_ERROR with a stack trace and capability state, asserted individually" do
      assert {:error, {:script_error, script_error}} =
               Executor.run_script_sync(
                 %Manifest{script_id: "", capabilities: []},
                 "return 1 // 0",
                 1_000_000
               )

      # Stack trace, asserted individually
      assert is_list(script_error.stack_trace)

      # Capability state at failure, asserted individually -- the real
      # execute_with_manifest/2,3 path always installs the empty grant set today
      # (design §4.1, OQ-1: an inherited, pre-existing gap this requirement does not
      # close), so `[]` is the correct value to assert here, not `nil`/omitted.
      assert script_error.capabilities == []
    end

    # AC2: moduledoc names the exact mechanism and cites REQ-148 by section.
    test "AC2: moduledoc names the instruction-count mechanism and cites REQ-148 by section" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Executor)

      assert moduledoc =~ "exception.original.state.instruction_count"
      assert moduledoc =~ "REQ-148"
      assert moduledoc =~ "§5"
    end

    # AC3: when the count is not retrievable, the event does NOT carry a zero-filled
    # or silently-omitted-but-implied-present instruction_count -- it is explicitly
    # budget-labelled instead. Lua.VM.InternalError declares no :state field at all
    # (confirmed by reading deps/lua/lib/lua/vm/internal_error.ex), and its only real
    # raise sites ("goto target not found", "unimplemented instruction", "break
    # outside loop") are unreachable from any Lua source that actually parses -- so
    # this test constructs the exception double directly, per design §4.2's own
    # "shaping-function level" testing precedent, and calls the public
    # (`@doc false`) `Executor.build_script_error/3` seam.
    test "AC3: instruction_count reports {:configured_budget, _} (never zero-filled) when the count is unretrievable" do
      exception = %Lua.RuntimeException{original: %Lua.VM.InternalError{value: "boom"}}

      script_error = Executor.build_script_error(exception, 4242, Capabilities.new())

      assert script_error.instruction_count == {:configured_budget, 4242}
      refute match?({:consumed, _}, script_error.instruction_count)
      refute is_integer(script_error.instruction_count)
    end

    # AC4: 1//0 (integer floor division) raises "attempt to divide by zero" in this
    # Lua 5.3 runtime; 1/0 (float division) does not raise at all -- it evaluates to
    # inf, per Lua 5.3 §3.4.1 (design §8, moduledoc REQ-162 section).
    # ISS-0426 design §2.1.1: both calls' outcomes are fully determined by the
    # workload (1 // 0 raises, 1 / 0 doesn't), no wall-clock assertion -- routed
    # through the synchronous seam.
    test "AC4: 1 // 0 raises 'attempt to divide by zero'; 1 / 0 does not raise" do
      empty_manifest = %Manifest{script_id: "", capabilities: []}

      assert {:error, {:script_error, script_error}} =
               Executor.run_script_sync(empty_manifest, "return 1 // 0", 1_000_000)

      assert script_error.message =~ "attempt to divide by zero"

      assert {:ok, %{manifest_hash: _}} =
               Executor.run_script_sync(empty_manifest, "return 1 / 0", 1_000_000)
    end

    # AC5: SCRIPT_ERROR is pattern-match-distinguishable from all 4 other real arms
    # (SCRIPT_FAILED, budget_exceeded, wallclock_timeout, memory_limit_exceeded) in
    # one case/cond. SCRIPT_FAILED is never observed through
    # execute_with_manifest/2,3 (design §9/platform.ex moduledoc: it collapses into
    # an opaque string there) -- it is represented here as the raw exit-reason shape
    # req161-lua-platform-fail.md establishes, since that raw shape is what a real
    # caller (a Task.yield/2 `{:exit, reason}` clause, or a :DOWN message) actually
    # observes.
    #
    # ISS-0426 design §1.2(b)/§2.4: mixed test -- timeout_result genuinely races the
    # wall-clock kill, so the whole test is tag-isolated rather than restructured.
    # The other calls (script_error_result, budget_result, memory_result) are
    # deliberately left as literal execute_with_manifest/3 calls -- see design §2.4.
    @tag :lua_wallclock_race
    test "AC5: SCRIPT_ERROR is pattern-match-distinguishable from all 4 other real arms" do
      script_error_result =
        Executor.execute_with_manifest("return 1 // 0", "h",
          max_instructions: 1_000_000,
          timeout_ms: 5_000,
          max_heap_words: nil
        )

      budget_result =
        Executor.execute_with_manifest("while true do end", "h",
          max_instructions: 500,
          timeout_ms: 5_000,
          max_heap_words: nil
        )

      timeout_result =
        Executor.execute_with_manifest("while true do end", "h",
          max_instructions: 1_000_000_000,
          timeout_ms: 200,
          max_heap_words: nil
        )

      memory_result =
        Executor.execute_with_manifest(@gigabyte_allocating_script, "h",
          max_instructions: 1_000_000_000,
          timeout_ms: 5_000,
          max_heap_words: @sixteen_mb_in_words
        )

      script_failed_result = {:exit, {:script_failed, %{reason: "deliberate", details: nil}}}

      classify = fn
        {:error, {:script_error, _}} -> :script_error
        {:error, {:budget_exceeded, _}} -> :budget_exceeded
        {:error, {:wallclock_timeout, _}} -> :wallclock_timeout
        {:error, :memory_limit_exceeded} -> :memory_limit_exceeded
        {:exit, {:script_failed, _}} -> :script_failed
        other -> other
      end

      classified =
        Enum.map(
          [
            script_error_result,
            budget_result,
            timeout_result,
            memory_result,
            script_failed_result
          ],
          classify
        )

      assert classified == [
               :script_error,
               :budget_exceeded,
               :wallclock_timeout,
               :memory_limit_exceeded,
               :script_failed
             ]

      assert Enum.uniq(classified) == classified
    end

    # AC6: capability state is read from Capabilities.grant_set(), not re-derived.
    # execute_with_manifest/2,3's real sandbox is hardwired to the empty grant set
    # (Sandbox.new/1 -> Platform.install/1, design §4.1) so this cannot be proven end
    # to end today -- per design §4.2, this test constructs a Lua.t() directly via
    # Lua.new/1 + Platform.install/2 with an explicit non-empty grant set, bypassing
    # Sandbox.new/1's hardcoded empty-set call, and asserts the shaping function
    # produces exactly that one capability.
    test "AC6: capabilities are read from Capabilities.grant_set(), not re-derived" do
      grant_set = Capabilities.new(["some:capability"])

      deny_paths = Enum.map(Sandbox.deny_set(), fn {path, _reason} -> path end)

      lua =
        Lua.new(sandboxed: deny_paths)
        |> Platform.install(grant_set)

      exception =
        try do
          Lua.eval!(lua, "return 1 // 0")
          flunk("expected Lua.RuntimeException to be raised")
        rescue
          e in Lua.RuntimeException -> e
        end

      script_error = Executor.build_script_error(exception, 1_000, grant_set)

      assert script_error.capabilities == ["some:capability"]
    end

    # AC7: no stack trace frame's source/name fields contain a '/' path separator or
    # an 'Elixir.' prefix -- structurally guaranteed (design §6.1/§6.3) but asserted
    # anyway so a future library change that starts populating `source` from a real
    # file path is caught by a failing test.
    # ISS-0426 THE FILED FAILURE (design §2.1's table): script_error is fully
    # determined by the workload (1 // 0 always raises), no wall-clock assertion --
    # routed through the synchronous seam so {:error, {:wallclock_timeout, _}} is
    # unreachable from this call site by construction.
    test "AC7: stack trace frames contain no '/' path separator or 'Elixir.' prefix" do
      assert {:error, {:script_error, script_error}} =
               Executor.run_script_sync(
                 %Manifest{script_id: "", capabilities: []},
                 "local function f() return 1 // 0 end return f()",
                 1_000_000
               )

      for frame <- script_error.stack_trace do
        if frame.source, do: refute(frame.source =~ "/")
        if frame.source, do: refute(frame.source =~ "Elixir.")
        if frame.name, do: refute(frame.name =~ "/")
        if frame.name, do: refute(frame.name =~ "Elixir.")
      end
    end

    # Gap found by TEST-DESIGNER mutation testing: the pre-existing AC7 test only
    # refutes "/" and "Elixir." substrings in each frame's source/name. Mutating
    # script_error_stack_trace/1's typed clause to build frames from
    # `inspect(original.__struct__)` (e.g. "Lua.VM.RuntimeError" -- Elixir's own
    # `inspect/1` strips the "Elixir." prefix for module atoms, so it contains
    # neither "/" nor "Elixir.") and `Exception.message(exception)` (the raw,
    # unsanitized message) left all 44 then-existing tests passing -- no test pinned
    # `stack_trace` to the library's own sanitized `to_map/1` output, so an
    # Elixir-struct-name leak that happens not to contain those two substrings would
    # ship undetected. Confirmed by mutation (44/44 passed with the mutant in place);
    # reverting restored the pre-mutation source and this test passes against it.
    # This test closes that gap by pinning stack_trace to the exact sanitized value.
    test "AC7 regression: typed-case stack_trace is exactly Lua.RuntimeException.to_map/1's own call_stack" do
      exception =
        try do
          Lua.eval!(Sandbox.new(max_instructions: 1_000_000), "return 1 // 0")
          flunk("expected Lua.RuntimeException to be raised")
        rescue
          e in Lua.RuntimeException -> e
        end

      script_error = Executor.build_script_error(exception, 1_000_000, Capabilities.new())
      expected_call_stack = Lua.RuntimeException.to_map(exception).call_stack

      assert script_error.stack_trace == expected_call_stack
    end

    # Gap found by TEST-DESIGNER mutation testing: no test exercised the
    # untyped/fallback script_error_message/1 clause at all. Mutating it from the
    # fixed placeholder to `Exception.message(exception)` (the raw, unsanitized
    # message -- which for an arbitrary wrapped Elixir exception can legitimately
    # embed argument dumps or module names, per the moduledoc's own REQ-162
    # section) left all 45 then-existing tests passing. This test closes that gap.
    test "AC7 fallback case: an untyped wrapped exception yields the fixed placeholder message and empty stack_trace, never the raw exception detail" do
      exception =
        Lua.RuntimeException.exception(%RuntimeError{message: "boom /etc/passwd Elixir.Secret"})

      script_error = Executor.build_script_error(exception, 1_000, Capabilities.new())

      assert script_error.message == "internal script execution error"
      assert script_error.stack_trace == []
      refute script_error.message =~ "boom"
      refute script_error.message =~ "/etc/passwd"
      refute script_error.message =~ "Elixir."
    end

    # design §7 regression guard, mirroring REQ-148 §5's own warning: a real,
    # uncaught VM-opcode error's .original.state must be a populated %Lua.VM.State{}
    # carrying a non-negative :instruction_count. If a future tv-labs/lua upgrade
    # removes or renames either field, this test fails loudly instead of the
    # SCRIPT_ERROR silently reporting {:configured_budget, _} forever with no signal.
    # ISS-0426 design §2.1.1: script_error is fully determined by the workload, no
    # wall-clock assertion -- routed through the synchronous seam.
    test "regression guard (design §7): a real uncaught VM opcode error carries a non-negative consumed instruction_count" do
      assert {:error, {:script_error, script_error}} =
               Executor.run_script_sync(
                 %Manifest{script_id: "", capabilities: []},
                 "return 1 // 0",
                 1_000_000
               )

      assert {:consumed, count} = script_error.instruction_count
      assert is_integer(count)
      assert count >= 0
    end

    # ISS-0426 design §2.2: numeric elapsed-time comparison, genuinely races the
    # wall-clock kill -- tag-isolated, not restructured.
    @tag :lua_wallclock_race
    test "AC-5: shorter wall-clock timeout terminates sooner than a longer one" do
      script = "while true do end"
      huge_budget = 10_000_000_000

      {short_elapsed_ms, short_result} =
        :timer.tc(fn ->
          Executor.execute_with_manifest(script, "h",
            max_instructions: huge_budget,
            timeout_ms: 50,
            max_heap_words: nil
          )
        end)

      {long_elapsed_ms, long_result} =
        :timer.tc(fn ->
          Executor.execute_with_manifest(script, "h",
            max_instructions: huge_budget,
            timeout_ms: 200,
            max_heap_words: nil
          )
        end)

      assert {:error, {:wallclock_timeout, 50}} = short_result
      assert {:error, {:wallclock_timeout, 200}} = long_result
      assert short_elapsed_ms < long_elapsed_ms
    end

    # ISS-0426 design §2.2: race outcome (the timeout must still fire after the
    # script traps its own budget error) -- tag-isolated, not restructured.
    @tag :lua_wallclock_race
    test "AC-6: a timeout still kills a script after it traps its own budget exhaustion" do
      script = """
      local ok, err = pcall(function() while true do end end)
      while true do end
      """

      assert {:error, {:wallclock_timeout, 100}} =
               Executor.execute_with_manifest(script, "h",
                 max_instructions: 10_000_000_000,
                 timeout_ms: 100,
                 max_heap_words: nil
               )
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0426 -- wall-clock test contention fix: seam-equivalence and tag-partition
  # integrity coverage (design lib/letflow/design/iss426-wallclock-test-contention.md)
  # ---------------------------------------------------------------------------------
  #
  # Fourteen Group-1 call sites (REQ-154/155/156/162's own AC tests, above) were
  # repointed from execute_with_manifest/3's wall-clock-racing path onto two new
  # @doc false test-only seams, run_script_sync/3 and run_with_heap_limit_sync/4,
  # whose entire reason to exist is that {:error, {:wallclock_timeout, _}} is
  # unreachable from their call chains BY CONSTRUCTION (design §4) -- no Task.yield
  # anywhere in run_script_sync/3's chain, no `after` clause anywhere in
  # run_with_heap_limit_sync/4's receive block. WF-03's fail-first requirement does
  # not transfer mechanically here: ISSUE-FIXER could not reproduce the filed flake
  # even under 24 concentrated OS-level CPU burners plus 48 runs (step-01 handoff),
  # so a "test that fails pre-fix" would itself be a probabilistic, host-dependent
  # test -- exactly the speculation core-directives.md forbids. Coverage here instead
  # locks in the three properties this fix's own correctness argument depends on:
  #
  #   (a) seam equivalence -- the two new seams return the SAME outcome as their
  #       racing execute_with_manifest/3 counterpart for the same workload, for
  #       every outcome shape Group 1 uses (:ok, budget_exceeded, script_error,
  #       memory_limit_exceeded). This is the highest-value property: 14 call sites
  #       were repointed to new code paths, and a subtly different return shape
  #       (e.g. a seam that silently swallowed an error, or wrapped it differently)
  #       would let the repointed AC tests keep passing for the wrong reason.
  #   (b) the memory limit still binds through run_with_heap_limit_sync/4 -- the
  #       REQ-156/LUA-09 bound must be shown intact through the new path, not
  #       assumed carried over from run_with_heap_limit/5.
  #   (c) the :lua_wallclock_race tag partition is wired correctly, and each of the
  #       11 tagged tests still contains a genuine wallclock_timeout assertion --
  #       i.e. the tagging fix's worst failure mode (tests excluded everywhere,
  #       silently never running again) is structurally guarded against, not just
  #       observed to currently work.
  #
  # Fail-first for THIS coverage is satisfied per WF-03's "when the pre-fix failure
  # is the code under test does not exist" section, via mutation -- not via a
  # pre-fix run of this file, since run_script_sync/3 and run_with_heap_limit_sync/4
  # did not exist before this fix (any test calling them pre-fix fails with
  # UndefinedFunctionError, which proves the functions are new and nothing about
  # whether these tests discriminate a correct seam from a wrong one). The mutants
  # that probe (a)/(b)/(c) below, and their measured per-mutant results, are
  # recorded in test/specs/ISS-0426.md, not in this file (mutants are reverted
  # before commit, per WF-03 -- a mutant left in the tree is a step failure).
  describe "ISS-0426: seam equivalence (property a)" do
    @empty_manifest %Manifest{script_id: "", capabilities: []}

    # (a) :ok outcome -- REQ-154 AC-4's own pcall-catch workload, run through BOTH
    # the seam and its racing counterpart with a timeout generous enough that the
    # racing counterpart's own wall-clock kill cannot plausibly fire first (this
    # comparison call itself is intentionally NOT tagged into the isolated
    # partition -- see the moduletag-scope note below for why that is safe).
    test "run_script_sync/3 returns the same :ok shape as execute_with_manifest/3 for a natural-completion workload" do
      script = "return 1 + 1"

      sync_result = Executor.run_script_sync(@empty_manifest, script, 500_000)

      racing_result =
        Executor.execute_with_manifest(script, "h",
          max_instructions: 500_000,
          timeout_ms: 5_000,
          max_heap_words: nil
        )

      assert {:ok, %{manifest_hash: sync_hash}} = sync_result
      assert {:ok, %{manifest_hash: racing_hash}} = racing_result
      assert sync_hash == racing_hash
    end

    # (a) budget_exceeded outcome -- same workload/budget pair through both paths.
    test "run_script_sync/3 returns the same budget_exceeded shape as execute_with_manifest/3" do
      script = "while true do end"

      sync_result = Executor.run_script_sync(@empty_manifest, script, 500)

      racing_result =
        Executor.execute_with_manifest(script, "h",
          max_instructions: 500,
          timeout_ms: 5_000,
          max_heap_words: nil
        )

      assert {:error, {:budget_exceeded, 500}} = sync_result
      assert sync_result == racing_result
    end

    # (a) script_error outcome -- REQ-162 AC7's own filed-failure workload (the
    # exact script shape ISS-0426's own filing failure hit) through both paths.
    # Compares message/stack_trace/capabilities fields individually rather than a
    # blind structural == because instruction_count's {:consumed, count} arm can
    # legitimately differ by a handful of VM instructions between two independent
    # evaluations of the same script (different sandbox instance per call) -- the
    # design does not claim instruction-for-instruction determinism, only that the
    # ERROR SHAPE and its message/stack_trace content match.
    test "run_script_sync/3 returns the same script_error shape as execute_with_manifest/3" do
      script = """
      local function f()
        return 1 // 0
      end
      f()
      """

      sync_result = Executor.run_script_sync(@empty_manifest, script, 1_000_000)

      racing_result =
        Executor.execute_with_manifest(script, "h",
          max_instructions: 1_000_000,
          timeout_ms: 5_000,
          max_heap_words: nil
        )

      assert {:error, {:script_error, sync_error}} = sync_result
      assert {:error, {:script_error, racing_error}} = racing_result
      assert sync_error.message == racing_error.message
      assert sync_error.stack_trace == racing_error.stack_trace
      assert sync_error.capabilities == racing_error.capabilities
    end

    # (a) memory_limit_exceeded outcome -- REQ-156 AC-2's own gigabyte-allocating
    # workload through both the heap-limited seam and run_with_heap_limit/5 itself
    # (the racing counterpart run_with_heap_limit_sync/4 was carved out of).
    test "run_with_heap_limit_sync/4 returns the same memory_limit_exceeded shape as execute_with_manifest/3's heap-limited path" do
      script = """
      local t = {}
      for i = 1, 1000000 do
        t[i] = string.rep("x", 1024)
      end
      return #t
      """

      word_size_bytes = :erlang.system_info(:wordsize)
      sixteen_mb_in_words = trunc(16 * 1024 * 1024 / word_size_bytes)

      sync_result =
        Executor.run_with_heap_limit_sync(
          @empty_manifest,
          script,
          1_000_000_000,
          sixteen_mb_in_words
        )

      racing_result =
        Executor.execute_with_manifest(script, "h",
          max_instructions: 1_000_000_000,
          timeout_ms: 5_000,
          max_heap_words: sixteen_mb_in_words
        )

      assert {:error, :memory_limit_exceeded} = sync_result
      assert sync_result == racing_result
    end

    # ISS-0876 addition -- non-empty-manifest hash equivalence. Every equivalence test
    # above (this describe block, added by ISS-0426) exercises @empty_manifest
    # (script_id: "", capabilities: []) only. ISS-0876 repointed the 3 REQ-158 call
    # sites (executor_test.exs's "REQ-158: manifest-aware script_ref" describe block,
    # lines ~224-231/242-247) onto run_script_sync/3 with a NON-empty manifest for the
    # first time -- a property ISS-0426's own suite never exercised. Proves
    # run_script_sync/3's returned manifest_hash for a non-empty manifest matches
    # execute_with_manifest/3's racing counterpart (map-shaped script_ref, per
    # normalize_script_ref/1, executor.ex:389-391) for the identical (manifest,
    # script) pair -- same pattern as the :ok-outcome test above, just with a
    # non-empty manifest input.
    test "run_script_sync/3 returns the same manifest_hash as execute_with_manifest/3 for a non-empty manifest" do
      manifest = %Manifest{script_id: "script-abc", capabilities: ["variable:read"]}
      script = "return 1 + 1"

      sync_result = Executor.run_script_sync(manifest, script, 500_000)

      racing_result =
        Executor.execute_with_manifest(%{manifest: manifest, script_source: script}, "h",
          max_instructions: 500_000,
          timeout_ms: 5_000,
          max_heap_words: nil
        )

      assert {:ok, %{manifest_hash: sync_hash}} = sync_result
      assert {:ok, %{manifest_hash: racing_hash}} = racing_result
      assert sync_hash == racing_hash
    end

    # ISS-0876 addition -- Lua.CompilerException / syntax-error shape equivalence.
    # ISS-0426's own equivalence suite (this describe block's leading comment, per the
    # "(a) seam equivalence" property description above) covers :ok, budget_exceeded,
    # script_error, and memory_limit_exceeded only -- never the Lua.CompilerException
    # branch (executor.ex's `rescue e in Lua.CompilerException -> {:error,
    # Exception.message(e)}` arm), which is exactly the outcome shape ISS-0876's site 6
    # (executor_test.exs:209, "a Lua syntax error returns {:error, reason}") now
    # reaches via run_script_sync/3. Proves run_script_sync/3 and
    # execute_with_manifest/3 return the identical {:error, _} value for the same
    # invalid-syntax script -- closing the one outcome-shape gap ISS-0876's
    # conversions introduce beyond what ISS-0426 already proved equivalent.
    test "run_script_sync/3 returns the same {:error, _} shape as execute_with_manifest/3 for a Lua syntax error" do
      script = "this is not lua ==="

      sync_result = Executor.run_script_sync(@empty_manifest, script, 500_000)

      racing_result =
        Executor.execute_with_manifest(script, "h",
          max_instructions: 500_000,
          timeout_ms: 5_000,
          max_heap_words: nil
        )

      assert {:error, _} = sync_result
      assert sync_result == racing_result
    end
  end

  describe "ISS-0426: memory limit still binds through the unbounded-wait seam (property b)" do
    @empty_manifest %Manifest{script_id: "", capabilities: []}

    # (b) REQ-156/LUA-09's own bound, shown intact THROUGH run_with_heap_limit_sync/4
    # specifically -- a smaller configured max_heap_words halts an allocating script
    # (memory_limit_exceeded) while a materially larger one on the SAME script
    # completes successfully. If the fix had accidentally dropped the
    # max_heap_size spawn_opt (per this test spec's mutant 2), both calls below
    # would return :ok and this test would be the one to catch it -- see
    # test/specs/ISS-0426.md's mutant table for the measured proof.
    test "a smaller configured max_heap_words still halts an allocating script; a larger one still lets it complete" do
      script = """
      local t = {}
      for i = 1, 20000 do
        t[i] = string.rep("x", 1024)
      end
      return #t
      """

      word_size_bytes = :erlang.system_info(:wordsize)
      small_heap_words = trunc(1 * 1024 * 1024 / word_size_bytes)
      large_heap_words = trunc(200 * 1024 * 1024 / word_size_bytes)

      small_result =
        Executor.run_with_heap_limit_sync(
          @empty_manifest,
          script,
          1_000_000_000,
          small_heap_words
        )

      large_result =
        Executor.run_with_heap_limit_sync(
          @empty_manifest,
          script,
          1_000_000_000,
          large_heap_words
        )

      assert {:error, :memory_limit_exceeded} = small_result
      assert {:ok, %{manifest_hash: _}} = large_result
    end
  end

  describe "ISS-0426: :lua_wallclock_race tag-partition integrity (property c)" do
    # (c) Structural/mechanism-level check, same idiom as
    # test/support/tenant_slug_test.exs's ISS-0065 regression test: parses THIS
    # file's own source with Code.string_to_quoted/1 and walks the AST rather than
    # scanning text, because this describe block's own comments legitimately
    # mention "@tag :lua_wallclock_race" in prose -- a raw substring count would
    # over-count against its own docstrings. Counts actual @tag :lua_wallclock_race
    # AST nodes (a {:@, _, [{:tag, _, [:lua_wallclock_race]}]} node immediately
    # preceding a test/2 or test/3 call, structurally -- not merely present
    # somewhere in the file) and asserts the count is exactly 11, matching design
    # §2.2/§2.4's own enumerated table (9 pure Group 2 + 2 mixed). A tagging fix's
    # worst failure mode is silent over- or under-tagging -- e.g. a copy/paste that
    # tags a 12th test, or a rebase that drops one of the 11 -- and this guard
    # fails loudly on either.
    test "exactly 11 tests in this file carry @tag :lua_wallclock_race" do
      {:ok, ast} = Code.string_to_quoted(File.read!(__ENV__.file))

      {_ast, tag_count} =
        Macro.prewalk(ast, 0, fn
          {:@, _, [{:tag, _, [:lua_wallclock_race]}]} = node, acc -> {node, acc + 1}
          node, acc -> {node, acc}
        end)

      assert tag_count == 11,
             "expected exactly 11 @tag :lua_wallclock_race nodes (design §2.2/§2.4's " <>
               "9 pure Group 2 + 2 mixed tests) -- found #{tag_count}. A drift here means " <>
               "either a test that should race the wall clock lost its isolation tag (will " <>
               "flake under contention again) or an unrelated test gained one (silently " <>
               "excluded from every default run for no reason)."
    end

    # (c) The exclusion wiring itself -- test/test_helper.exs must actually exclude
    # :lua_wallclock_race by default, mirroring :wasm_hang's own precedent. A tag
    # applied to tests with nothing excluding it by default is not a fix at all
    # (Group 2 would still race under scripts/test_parallel.sh's N-way partitioning
    # exactly as before ISS-0426). Reads the real file, not a copy or a hardcoded
    # expectation of its content.
    test "test/test_helper.exs's ExUnit.start/1 excludes :lua_wallclock_race" do
      helper_path = Path.join([__DIR__, "..", "..", "..", "test_helper.exs"])
      assert File.exists?(helper_path), "test/test_helper.exs not found at #{helper_path}"

      {:ok, ast} = Code.string_to_quoted(File.read!(helper_path))

      {_ast, found?} =
        Macro.prewalk(ast, false, fn
          {{:., _, [{:__aliases__, _, [:ExUnit]}, :start]}, _, [opts]} = node, acc
          when is_list(opts) ->
            excluded = Keyword.get(opts, :exclude, [])
            {node, acc or :lua_wallclock_race in excluded}

          node, acc ->
            {node, acc}
        end)

      assert found?,
             "test/test_helper.exs's ExUnit.start/1 call does not exclude :lua_wallclock_race " <>
               "-- Group 2 tests would race under contention in every default `mix test` and " <>
               "scripts/test_parallel.sh partition again, exactly as before ISS-0426"
    end

    # (c) The 11 tagged tests still genuinely assert wallclock_timeout -- i.e. they
    # can still FAIL if the production wall-clock kill regressed. Runs the isolated
    # partition itself (mix test --only lua_wallclock_race, the same invocation
    # `mix letflow.check.test` uses) as a subprocess and asserts BOTH that it exits
    # 0 (the 11 tests currently pass, matching both reviewers' prior counts) AND
    # that its own output reports exactly 11 tests, not fewer -- catching the
    # "excluded everywhere, so it silently never runs or fails again" failure mode
    # the task description specifically calls out, at the point where it would
    # actually matter (the real isolated run, not just the tag count above).
    # ISS-0515/ISS-0426 follow-up: this subprocess is a brand-new OS process/BEAM VM.
    # It inherits TEST_POOL_SIZE (and every other env var, incl. MIX_TEST_PARTITION --
    # System.cmd/3's :env option ADDS to the inherited environment, it doesn't replace
    # it) from whichever scripts/test_parallel.sh partition spawned it, so left
    # unset here it would start its OWN, separate Ecto pool sized identically to a
    # full sibling partition's -- an entire extra partition's worth of live Postgres
    # connections that scripts/test_parallel.sh's N*TEST_POOL_SIZE budget arithmetic
    # never accounts for, on top of the parent partition's own pool (still open/idle,
    # not closed, while this call blocks). That is what pushed CI over
    # max_connections after ISS-0515 added a synchronous
    # `Letflow.Test.TenantTemplate.ensure_template!()` pre-build call to every
    # `mix test` invocation's test_helper.exs (this nested run included) -- see
    # docs/migration/decisions/0009-test-parallel-pool-sizing.md's ISS-0515 addendum.
    # This module's own moduledoc note (line ~7) already establishes these 11 tests
    # short-circuit before any Repo insert, so a small, fixed pool is genuinely
    # enough -- but NOT a pool of exactly 1. This file's `async: true` (line 11)
    # means this nested subprocess's own test_helper.exs pre-build calls
    # (`sweep_orphans/0`, `sweep_service_catalog_orphans/1`,
    # `ensure_template!/0` -- all real `Letflow.Repo` checkouts) run in that same
    # BEAM VM, and Ecto's Sandbox/DBConnection checkout+checkin machinery can
    # transiently need a second connection concurrently with the first even when
    # the 11 tests themselves never touch the DB (e.g. a prior checkout's
    # asynchronous `on_exit` checkin racing the next caller's checkout, or
    # Postgrex's own internal health/reconnect connection). A pool of exactly 1
    # gave DBConnection's checkout queue nowhere to put that second, genuinely
    # concurrent request, so it queued past the 15s default and the whole
    # subprocess died with a `DBConnection.ConnectionError` (first hit
    # 2026-09-06, this same ISS-0515/ISS-0426 branch, immediately after the
    # TEST_POOL_SIZE=1 cap landed). 4 connections is still tiny next to an
    # uncapped sibling-partition-sized pool (schedulers_online()*2, typically
    # 8-32) but gives enough slack for that kind of transient overlap without
    # reopening the original unbounded-pool problem. See
    # docs/migration/decisions/0009-test-parallel-pool-sizing.md's ISS-0515
    # addendum for the re-derived connection-budget arithmetic this value feeds
    # into (`TEST_NONPOOL_CONNECTION_RESERVE` in scripts/test_parallel.sh).
    @tag timeout: 60_000
    test "the isolated --only lua_wallclock_race partition runs and passes exactly 11 tests" do
      {output, exit_code} =
        System.cmd(
          "mix",
          ["test", "--only", "lua_wallclock_race", "test/letflow/engine/lua/executor_test.exs"],
          stderr_to_stdout: true,
          env: [
            {"TEST_POOL_SIZE", "4"},
            # ISS-0515, fourth rework (2026-09-06): PR #1033 failed CI four times in a
            # row with the identical DBConnection.ConnectionError signature even after
            # doubling Postgres's own max_connections (see this file's env var and
            # docs/migration/decisions/0009-test-parallel-pool-sizing.md's fourth
            # addendum for the live CI evidence that the `services.postgres.command`
            # override did NOT actually raise the server-side ceiling). Rather than
            # attempt a fifth reslice/raise of a connection budget this subprocess
            # never needed to touch in the first place, this env var tells
            # test/test_helper.exs to skip its `Letflow.Test.TenantTemplate
            # .ensure_template!/0` pre-build call entirely inside THIS one nested
            # subprocess. That is safe by construction: this module's own moduledoc
            # already states the 11 `:lua_wallclock_race`-tagged tests need "No
            # database access required ... short-circuit before any Repo insert" --
            # they have no tenant fixture dependency for `ensure_template!/0` to have
            # ever protected them from in the first place. The tenant_template schema
            # was, in any case, already built by THIS partition's own enclosing
            # test_helper.exs run before this test process could even exist -- the
            # nested subprocess re-doing that work from its own empty
            # `:persistent_term` was always pure overhead, never a genuine
            # correctness requirement. `TEST_POOL_SIZE=4` above is left in place
            # (not reduced further) because test_helper.exs's `sweep_orphans/0` and
            # `sweep_service_catalog_orphans/1` calls remain unconditional and still
            # open real `Letflow.Repo` checkouts in this subprocess regardless of
            # this flag -- it removes the heaviest, advisory-lock-contending DB path
            # (`ensure_template!/0`), not all DB access from this process.
            {"LETFLOW_SKIP_TENANT_TEMPLATE_PREBUILD", "1"}
          ]
        )

      assert exit_code == 0,
             "isolated :lua_wallclock_race partition did not exit 0 -- output:\n#{output}"

      assert output =~ ~r/Result: 11 passed/,
             "expected the isolated run to report exactly 11 passed tests -- output:\n#{output}"
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0876 -- bare 2-arity execute_with_manifest/2 elimination (design
  # lib/letflow/design/iss876-wallclock-2arity-gap.md). This design's own "Mutation/
  # fail-first ... does NOT apply here") states the code under test
  # (run_script_sync/3) already existed before this fix -- only its CALLERS changed.
  # Per the design's own prescribed proof (§4 items 1-3): a structural source check
  # that the bare 2-arity form is gone from every at-risk site (test 1 below), two
  # behavioral-equivalence tests closing the two outcome-shape gaps this fix's
  # conversions introduce beyond ISS-0426's own equivalence suite (added to the
  # "ISS-0426: seam equivalence (property a)" describe block above, non-empty-manifest
  # hash equivalence and Lua.CompilerException shape equivalence), and a call-site
  # count regression guard (test 2 below) pinning the total so a future revert of any
  # one of these 9 conversions fails loudly instead of silently reintroducing the
  # race.
  describe "ISS-0876: bare 2-arity execute_with_manifest/2 elimination" do
    # Structural check (design §4 item 1, primary evidence -- no flake reproduction
    # needed): parses THIS file's own source with Code.string_to_quoted/1 and walks
    # the AST for actual `Executor.execute_with_manifest(_, _)` CALL nodes whose
    # argument list has exactly 2 elements -- the bare-2-arity shape that reaches
    # execute_with_manifest/2's unmitigated default-timeout path. AST-based, not a
    # text/regex scan, for the same reason this file's own "exactly 11 tests carry
    # @tag :lua_wallclock_race" self-check (above) uses Macro.prewalk/3 rather than
    # a substring count: this describe block's own comments and the module's
    # moduledoc-style prose above legitimately mention "execute_with_manifest(" and
    # "execute_with_manifest/2" many times over, which a raw substring/regex count
    # would over-count against. `function_exported?(Executor, :execute_with_manifest,
    # 2)` (AC1, line ~42) is an atom argument to a different function, not a call to
    # Executor.execute_with_manifest itself, and is correctly NOT matched by this AST
    # pattern (it has no `{:., _, [{:__aliases__, _, [:Executor]},
    # :execute_with_manifest]}` call node at all).
    #
    # Expected count: exactly 3 -- the 3 short-circuit `normalize_script_ref/1`
    # rejection sites the design (§2, "Not converted" note) explicitly excludes:
    # `Executor.execute_with_manifest(12345, "h")`,
    # `Executor.execute_with_manifest(%{}, "h")`, and
    # `Executor.execute_with_manifest(%{manifest: :not_a_manifest, script_source:
    # "h"}, "h")` (the "a script_ref that is neither a binary nor a %{manifest:,
    # script_source:} map returns {:error, :invalid_script_ref}" test, REQ-158
    # describe block above) -- all three return `{:error, :invalid_script_ref}`
    # synchronously inside normalize_script_ref/1, before execute_with_manifest/3
    # ever reads `opts` or spawns a `Task`, so they are not at risk and this design
    # deliberately leaves them as bare 2-arity calls (converting them would be
    # editing an unreachable-by-the-race path for no safety benefit).
    test "no bare 2-arity Executor.execute_with_manifest/2 call remains except the 3 short-circuit exclusions" do
      {:ok, ast} = Code.string_to_quoted(File.read!(__ENV__.file))

      {_ast, bare_2_arity_count} =
        Macro.prewalk(ast, 0, fn
          {{:., _, [{:__aliases__, _, [:Executor]}, :execute_with_manifest]}, _, args} = node, acc
          when length(args) == 2 ->
            {node, acc + 1}

          node, acc ->
            {node, acc}
        end)

      assert bare_2_arity_count == 3,
             "expected exactly 3 bare 2-arity Executor.execute_with_manifest/2 call " <>
               "sites (the 3 normalize_script_ref/1 short-circuit exclusions design " <>
               "§2 names) -- found #{bare_2_arity_count}. A count above 3 means a " <>
               "call site was reverted (or newly added) onto the unmitigated " <>
               "execute_with_manifest/2 wallclock-racing path; a count below 3 means " <>
               "one of the 3 legitimately-excluded short-circuit sites was converted " <>
               "or removed, which this design does not call for."
    end

    # Call-site count regression guard (design §4 item 3): pins the total number of
    # Executor.run_script_sync/3 and Executor.run_with_heap_limit_sync/4 CALL nodes
    # (not function definitions -- there are none in this test file) in this file to
    # 31, mirroring this file's own "exactly 11 @tag :lua_wallclock_race" self-check
    # idiom (above) -- AST-based so this describe block's own prose mentioning
    # "run_script_sync(" does not inflate the count.
    #
    # The 31 breaks down as: 14 (ISS-0426's own Group-1 conversions) + 9 (this
    # design's conversions, §2's table) = 23 "protected call sites" whose presence as
    # run_script_sync/run_with_heap_limit_sync calls (rather than a bare
    # execute_with_manifest/2 or a racing execute_with_manifest/3) is what keeps
    # {:error, {:wallclock_timeout, _}} unreachable from each of those 23 tests by
    # construction, PLUS 8 comparison calls the "ISS-0426: seam equivalence (property
    # a)" and "ISS-0426: memory limit still binds ... (property b)" describe blocks
    # (above) make deliberately, on the run_script_sync/run_with_heap_limit_sync side
    # of an equivalence assertion against a racing execute_with_manifest/3
    # counterpart -- 6 pre-existing (ISS-0426's own equivalence suite) + 2 added by
    # this design (the non-empty-manifest-hash and Lua.CompilerException equivalence
    # tests added above). 23 + 8 = 31. If a future edit reverts one of the 9 §2
    # conversions back to a bare execute_with_manifest/2 call, this count drops to 30
    # and this test fails loudly -- the same "silently re-widened back to the racing
    # path" guard design §4 item 3 asks for.
    test "the file contains exactly 31 run_script_sync/3 or run_with_heap_limit_sync/4 call sites" do
      {:ok, ast} = Code.string_to_quoted(File.read!(__ENV__.file))

      {_ast, sync_seam_call_count} =
        Macro.prewalk(ast, 0, fn
          {{:., _, [{:__aliases__, _, [:Executor]}, fun]}, _, _args} = node, acc
          when fun in [:run_script_sync, :run_with_heap_limit_sync] ->
            {node, acc + 1}

          node, acc ->
            {node, acc}
        end)

      assert sync_seam_call_count == 31,
             "expected exactly 31 Executor.run_script_sync/3 or " <>
               "Executor.run_with_heap_limit_sync/4 call sites (23 protected " <>
               "conversion sites -- 14 ISS-0426 + 9 ISS-0876 -- plus 8 equivalence-" <>
               "suite comparison calls -- 6 ISS-0426 + 2 ISS-0876) -- found " <>
               "#{sync_seam_call_count}. A drop below 31 likely means one of the 9 " <>
               "ISS-0876 conversions (design §2) was reverted back onto the racing " <>
               "execute_with_manifest/2 path."
    end
  end

  # ISS-1040: finds the supervised Lua child spawned on behalf of `caller_pid` (the
  # process that called execute_with_manifest/3), identified by the `$callers`
  # entry Task.Supervisor.async_nolink/2 records. Scoping to the caller closes the
  # false-positive where a sibling async test's child satisfies a global
  # `children != []` check. Bounded by a monotonic deadline, not an attempt count.
  @spec await_own_child(pid(), pos_integer()) :: pid() | nil
  defp await_own_child(caller_pid, deadline_ms) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_await_own_child(caller_pid, deadline)
  end

  defp do_await_own_child(caller_pid, deadline) do
    found =
      Enum.find(Task.Supervisor.children(Letflow.Engine.Lua.TaskSupervisor), fn pid ->
        case Process.info(pid, :dictionary) do
          {:dictionary, dict} -> caller_pid in Keyword.get(dict, :"$callers", [])
          nil -> false
        end
      end)

    cond do
      found != nil ->
        found

      System.monotonic_time(:millisecond) >= deadline ->
        nil

      true ->
        Process.sleep(5)
        do_await_own_child(caller_pid, deadline)
    end
  end
end
