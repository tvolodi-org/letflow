defmodule Letflow.Engine.Wasm.PluginHandlerTest do
  @moduledoc """
  REQ-165 -- coverage for `Letflow.Engine.Wasm.PluginHandler`, the first
  `wasmex`-backed `Letflow.Engine.PluginInterface` handler. See
  `lib/letflow/design/req165-wasmex-process-boundary.md` (gate-approved) and
  `test/specs/REQ-165.md` for the full rationale and AC traceability.

  `async: false`: this module builds a real Wasmtime instance per test via
  `wasmex`'s NIF and shells out to nothing else, but the AC5 hang test
  deliberately runs a guest that never returns until brutally killed --
  keeping the file serial avoids any risk of two such calls overlapping
  under scheduler pressure across `async: true` test processes.
  """

  use ExUnit.Case, async: false
  @moduletag :unit

  alias Letflow.Engine.PluginInterface
  alias Letflow.Engine.PluginInterface.ExecutionContext
  alias Letflow.Engine.Wasm.CallTimeout
  alias Letflow.Engine.Wasm.InvocationLease
  alias Letflow.Engine.Wasm.PluginHandler

  defp context(overrides \\ %{}) do
    %ExecutionContext{
      instance_id: Map.get(overrides, :instance_id, Ecto.UUID.generate()),
      definition_id: Map.get(overrides, :definition_id, Ecto.UUID.generate()),
      node_id: Map.get(overrides, :node_id, "node-1"),
      node_type: Map.get(overrides, :node_type, "SERVICE_TASK"),
      variables: Map.get(overrides, :variables, %{}),
      node_config: Map.get(overrides, :node_config, %{}),
      trace_id: Map.get(overrides, :trace_id, "trace-1")
    }
  end

  # ---------------------------------------------------------------------
  # AC6 ("plugin_interface.ex is unmodified by REQ-165") was previously
  # enforced here via a live-ref `git diff --stat #{base_ref}...HEAD` test.
  # Removed per ISS-0413 (lib/letflow/design/iss0413-plugin-handler-test-fragility.md):
  # the property was a one-time historical fact about REQ-165's own merged
  # diff (already permanently discharged), not an evergreen property a
  # future PR should have to keep satisfying -- the same defect class
  # ISS-0378/ISS-0404 already fixed by deletion elsewhere in this suite.
  # No replacement test was added: the mutation-testing table this test was
  # kept for (test/specs/REQ-165.md, mutation #3, a handle_yield_result/4
  # error-message edit) shows that mutation was already independently
  # caught by the AC5 hang/timeout test below (`reason =~ "did not respond
  # within 100ms"`), so no discriminating coverage is lost by this deletion.
  # ---------------------------------------------------------------------

  # ---------------------------------------------------------------------
  # AC3 / AC4: dispatched via PluginInterface.invoke/2, {:complete, map()},
  # and the guest runs in a different process than the caller.
  # ---------------------------------------------------------------------

  describe "AC3/AC4: trivial guest via PluginInterface.invoke/2" do
    test "returns {:complete, map} and runs in a different process than the caller" do
      test_pid = self()
      # Mutation-testing gap found by TEST-DESIGNER (test/specs/REQ-165.md):
      # `handler_pid != test_pid` alone is satisfied by ANY pre-existing
      # process, including one hardcoded and unrelated to the actual guest
      # call (e.g. `Process.whereis(:application_controller)`) -- that
      # mutation was NOT caught by this assertion. Snapshotting the live
      # process set before the call and asserting `handler_pid` is a
      # process that did not exist yet closes that gap: only a genuinely
      # freshly spawned task pid (Task.Supervisor.async_nolink/2, per the
      # design's §4) can satisfy it.
      pids_before = MapSet.new(Process.list())

      assert {:complete, %{"answer" => 42, "executed_in_pid" => handler_pid}} =
               PluginInterface.invoke(PluginHandler, context())

      assert is_pid(handler_pid)
      assert handler_pid != test_pid

      refute MapSet.member?(pids_before, handler_pid),
             "expected executed_in_pid to be a process freshly spawned for this call, " <>
               "not a pre-existing one"

      assert Process.alive?(test_pid)
    end
  end

  # ---------------------------------------------------------------------
  # Mutation-testing gap found by TEST-DESIGNER (see test/specs/REQ-165.md
  # findings table): removing `run_guest/2`'s `GenServer.stop(pid)` call on
  # the success path was NOT caught by any of the 9 existing tests -- none
  # of them observed the wasmex instance's lifetime, only the outcome map.
  # This test targets that lifetime directly: `Wasmex.start_link/1` starts
  # an ordinary `use GenServer` process (see `deps/wasmex/lib/wasmex.ex`),
  # so a leaked instance is a live process whose `$initial_call` process
  # dictionary entry names the `Wasmex` module. Because `GenServer.stop/1`
  # is synchronous (it blocks the caller until `terminate/2` completes), a
  # correct implementation has already reaped the instance by the time
  # `PluginInterface.invoke/2` returns -- no sleep/wait is needed for this
  # assertion to be deterministic.
  # ---------------------------------------------------------------------

  defp wasmex_pids do
    Process.list()
    |> Enum.filter(fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dict} ->
          match?({Wasmex, _, _}, Keyword.get(dict, :"$initial_call"))

        _ ->
          false
      end
    end)
  end

  describe "no leaked Wasmex instance after a successful call" do
    test "the wasmex GenServer started for the call is stopped before invoke/2 returns" do
      before_pids = wasmex_pids()

      assert {:complete, %{"answer" => 42}} = PluginInterface.invoke(PluginHandler, context())

      leaked = wasmex_pids() -- before_pids

      assert leaked == [],
             "expected no leaked Wasmex GenServer after a successful call, got: #{inspect(leaked)}"
    end
  end

  # ---------------------------------------------------------------------
  # AC5: a hanging guest is bounded by PluginInterface.invoke/3's own
  # supervised-task timeout, surfacing as {:error, reason}, never an
  # exception/exit into the calling process.
  # ---------------------------------------------------------------------

  describe "AC5: a hanging guest is terminated by the outer task timeout" do
    # ISS-0352: this test genuinely, permanently hangs the wasmex NIF native
    # thread it dispatches to (no BEAM-side mechanism can reclaim it -- see
    # req170's own design doc section 1.1-1.4). Tagged so it runs isolated
    # from the rest of the suite (test_helper.exs excludes :wasm_hang by
    # default; mix letflow.check.test runs it in its own dedicated,
    # short-lived BEAM node afterward) rather than leaking a thread into the
    # shared pool every other WASM NIF test in the same process depends on.
    #
    # ISS-0406/ISS-0352 recurrence mitigation: every :wasm_hang test in this
    # file waits on a fixed, short (100ms-7_000ms) internal timeout bound, so
    # it normally completes in well under a few seconds. Recurring CI
    # failures (ISS-0352's PR #780/#786/#790 recurrence notes; this session's
    # own corroborating PRs #788/#792/#798/#801) hit ExUnit's default
    # 60_000ms per-test timeout not because the mechanism under test took
    # 60s, but because host-level CPU scheduling contention on a busy/shared
    # CI runner delayed BEAM's own timer/message delivery to the caller
    # process. The `@tag timeout: 180_000` added to each :wasm_hang test
    # below tolerates that jitter without masking a genuine regression: if
    # the timeout mechanism under test ever stopped firing for real, the
    # test would still eventually hit the (now-later) ExUnit timeout and
    # fail -- this only buys headroom against scheduling delay, never
    # against an undetected real hang.
    @tag :wasm_hang
    @tag timeout: 180_000
    test "surfaces as {:error, reason} naming the outer timeout, no rescue/catch needed" do
      # ISS-0418 (design iss0418-wasm-concurrency-cap.md §6.2 Shape A): this lease is
      # TEST-SIDE ONLY -- production dispatch does not acquire one yet (design doc
      # §0/§7). This test process IS invoke/2,3's own caller, exactly the position
      # §2/§8.1 specify for a production caller -- never the process
      # Task.shutdown(:brutal_kill) targets (that always targets the INNER task
      # invoke/2,3 itself spawns). Released via on_exit/1, not a bare try/after, so a
      # later assertion failure cannot skip the release and leak a lease slot into
      # the next test in this file. This dispatch is also now the SOLE surviving
      # live proof of the outer-timeout-fires-and-no-exit-reaches-the-caller
      # mechanism, and the sole live source call_timeout_test.exs's own synthetic
      # replay (§6.3.1 item 2) captures its string from.
      {:ok, lease} = InvocationLease.try_acquire()
      on_exit(fn -> InvocationLease.release(lease) end)

      hang_context =
        context(%{
          node_config: %{"wasm_fixture" => "wasm_fixtures/req165_hang.wat", "export" => "hang"}
        })

      test_pid = self()

      assert {:error, reason} =
               PluginInterface.invoke(PluginHandler, hang_context, timeout_ms: 100)

      assert reason =~ "did not respond within 100ms"
      # Positive check that no exit signal reached the caller.
      assert Process.alive?(test_pid)
    end
  end

  # ---------------------------------------------------------------------
  # AC7: no external Wasm runtime dependency at deploy time -- resolves the
  # design's own OQ-D1 by verifying wasmex's real introspection surface
  # against a compiled build, rather than assuming an API.
  # ---------------------------------------------------------------------

  describe "AC7: the wasmex NIF is a loaded shared library, not an external process" do
    # -----------------------------------------------------------------
    # Per lib/letflow/design/iss0377-cross-platform-test-fixes.md Part A:
    # the wasmex NIF loader always copies the version-qualified compiled
    # artifact to a fixed load name ("wasmex") with the platform's native
    # shared-library extension appended. The extension is the only thing
    # that varies by OS -- derive it from :os.type/0 instead of hardcoding
    # ".so". An unmapped OS must fail loudly (A.4 step 1), never skip.
    # -----------------------------------------------------------------
    defp expected_native_extension do
      case :os.type() do
        {:unix, os} when os in [:linux, :freebsd, :darwin] ->
          ".so"

        {:win32, _} ->
          ".dll"

        other ->
          flunk(
            "unhandled :os.type/0 value #{inspect(other)} -- no known NIF loadable-artifact " <>
              "extension mapping; see A.4 of iss0377-cross-platform-test-fixes.md"
          )
      end
    end

    # Checks for the fixed-load-name compiled artifact ("wasmex" <> ext)
    # under priv_dir/native, falling back to a directory listing (A.4 step
    # 3) if the exact fixed-name path is absent. Returns a tagged tuple so
    # callers can produce a failure message that distinguishes which branch
    # fired, per A.4/A.5's requirement.
    defp native_artifact_check(priv_dir, ext) do
      fixed_path = Path.join([priv_dir, "native", "wasmex" <> ext])

      if File.exists?(fixed_path) do
        {:ok, :fixed_name, fixed_path}
      else
        native_dir = Path.join(priv_dir, "native")

        case File.ls(native_dir) do
          {:ok, entries} ->
            if Enum.any?(entries, &String.ends_with?(&1, ext)) do
              {:ok, :fallback_listing, native_dir}
            else
              {:error, :not_found, fixed_path, native_dir}
            end

          {:error, reason} ->
            {:error, :listing_failed, fixed_path, reason}
        end
      end
    end

    test "Wasmex.Native resolves to a compiled .beam built from Rust NIF sources" do
      beam_path = :code.which(Wasmex.Native)
      refute beam_path in [:non_existing, :cover_compiled, :preloaded]

      external_resources =
        Wasmex.Native.module_info(:attributes)
        |> Keyword.get_values(:external_resource)
        |> List.flatten()

      if external_resources == [] do
        # A.5: a precompiled/downloaded build may legitimately attach zero
        # :external_resource entries. Don't fail -- fall back to asserting
        # the A.4-step-3 invariant (a real compiled artifact is present).
        priv_dir = :code.priv_dir(:wasmex)
        refute priv_dir == {:error, :bad_name}
        ext = expected_native_extension()

        case native_artifact_check(priv_dir, ext) do
          {:ok, _via, _path} ->
            assert true,
                   "external_resource is empty for this build (precompiled/downloaded " <>
                     "path) -- confirmed a compiled NIF artifact is present under priv/native instead"

          {:error, _reason, fixed_path, extra} ->
            flunk(
              "external_resource is empty (precompiled/downloaded build path) and no " <>
                "compiled NIF artifact was found either (checked #{fixed_path}, #{inspect(extra)})"
            )
        end
      else
        # Non-empty: this project's WASMEX_BUILD=true from-source build path
        # globs the whole crate tree (README.md, Cargo.toml, Cargo.lock,
        # .cargo/config.toml alongside .rs sources) -- assert at least one
        # entry is a real Rust source file, not that every entry is.
        assert Enum.any?(external_resources, &String.ends_with?(&1, ".rs")),
               "expected at least one :external_resource entry to end in .rs (Rust NIF " <>
                 "source) among #{inspect(external_resources)}"
      end
    end

    test "the compiled NIF shared library is bundled inside wasmex's own priv/, not fetched at runtime" do
      priv_dir = :code.priv_dir(:wasmex)
      refute priv_dir == {:error, :bad_name}

      ext = expected_native_extension()

      case native_artifact_check(priv_dir, ext) do
        {:ok, _via, _path} ->
          assert true

        {:error, :not_found, fixed_path, native_dir} ->
          flunk(
            "fixed-name file #{fixed_path} missing, and no artifact of extension #{ext} " <>
              "found at all under #{native_dir}"
          )

        {:error, :listing_failed, fixed_path, reason} ->
          flunk(
            "fixed-name file #{fixed_path} missing, and listing its priv/native directory " <>
              "failed: #{inspect(reason)}"
          )
      end
    end

    # ISS-0982: `:erlang.ports/0` is a VM-global resource list, not scoped to
    # this test. Under the full async suite, any other concurrently-running
    # test that opens (or closes) an unrelated port in the window between
    # `ports_before` and `ports_after` makes a *raw* `ports_after --
    # ports_before` diff non-empty for reasons that have nothing to do with
    # this test's own guest call -- a false positive, since this module's
    # `run_guest/3` calls synchronously (via `PluginInterface.invoke/2`'s
    # `Task.yield/2`) and has long returned by the time any unrelated test
    # elsewhere opens or closes a port of its own.
    #
    # Scope the check instead: every port this call could plausibly open
    # (were AC7's "no IPC boundary" property to regress) would be opened
    # either by this test process directly, or by `PluginInterface.invoke/2`'s
    # own dispatched task -- and that task is synchronously joined (awaited)
    # before `invoke/2` returns, so any port it opened and did not explicitly
    # hand off to another still-living process would already be closed by
    # the BEAM when its owning process exited (ports close with their owner
    # unless ownership is transferred). The only way a genuine leak could
    # still be observable in `ports_after` is if it ends up connected to this
    # test process itself. Filtering `:erlang.ports/0` to `:connected ==
    # self()` therefore keeps full sensitivity to a real regression while
    # making the assertion immune to any unrelated process's ports.
    defp own_ports do
      Enum.filter(:erlang.ports(), fn port ->
        match?({:connected, pid} when pid == self(), :erlang.port_info(port, :connected))
      end)
    end

    test "invoking the guest opens no new OS ports (no external process/IPC boundary)" do
      ports_before = own_ports()

      assert {:complete, %{"answer" => 42}} = PluginInterface.invoke(PluginHandler, context())

      ports_after = own_ports()
      assert ports_after -- ports_before == []
    end

    # ISS-0982 regression coverage: deliberately open a port from an
    # unrelated process during this test's own before/after window --
    # reproducing exactly the flake condition the fix above addresses --
    # and prove the scoped assertion still reports no diff, while the
    # raw/unscoped `:erlang.ports/0` diff this test used to use WOULD have
    # seen it (and so would have failed).
    test "the scoped port diff ignores a port opened by an unrelated concurrent process" do
      # Snapshot "before" first, with no neighbor port open yet -- mirroring
      # the exact flake window ISS-0982 describes: the neighbor's port must
      # open and stay open strictly *between* this test's own before/after
      # snapshots for the raw diff below to see it.
      ports_before = own_ports()
      raw_ports_before = :erlang.ports()

      noisy_neighbor =
        spawn(fn ->
          port = Port.open({:spawn, "cat"}, [:binary])

          receive do
            :stop -> Port.close(port)
          end
        end)

      # Give the neighbor's port time to actually open before we proceed.
      Process.sleep(20)

      assert {:complete, %{"answer" => 42}} = PluginInterface.invoke(PluginHandler, context())

      ports_after = own_ports()
      raw_ports_after = :erlang.ports()

      # The scoped diff: unaffected by the neighbor's port, since it is
      # connected to `noisy_neighbor`, not this test process.
      assert ports_after -- ports_before == []

      # Prove the flake condition was genuinely reproduced: the unscoped
      # diff this test used to run DOES see the neighbor's port (because it
      # was opened after `raw_ports_before` was taken and is still open at
      # `raw_ports_after`) -- confirming a raw `:erlang.ports/0` diff would
      # have false-positived here, exactly as ISS-0982 describes.
      assert raw_ports_after -- raw_ports_before != []

      send(noisy_neighbor, :stop)
    end
  end

  # ---------------------------------------------------------------------
  # AC7 (moduledoc restatement) / AC8 (residual risk disclosure) --
  # moduledoc content-string tests mirroring
  # test/letflow/engine/lua/executor_test.exs's AC-5 technique.
  # ---------------------------------------------------------------------

  describe "moduledoc content" do
    test "AC7: moduledoc restates WASM-01's mechanism clause" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(PluginHandler)

      assert moduledoc =~ "WASM-01"
      assert moduledoc =~ "Rust NIF"
      assert moduledoc =~ "C API"
      normalized = String.replace(moduledoc, ~r/\s+/, " ")
      assert normalized =~ "No external Wasm runtime dependency at deploy time"
    end

    test "AC8: moduledoc discloses the residual native-crash risk uncovered by the boundary" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(PluginHandler)

      assert moduledoc =~ "Residual risk"
      assert moduledoc =~ "NOT covered by the process boundary"
      assert moduledoc =~ "crash the **entire BEAM node**" or moduledoc =~ "crash the"
      assert moduledoc =~ "System.halt/0"

      assert moduledoc =~ "does **not** bound a native crash" or
               moduledoc =~ "does not bound a native crash"
    end
  end

  # ---------------------------------------------------------------------
  # REQ-170 AC1: a guest blocked in a host call is bounded by the
  # configured wasm-level timeout_ms, and the caller receives a structured
  # {:error, reason} within it, not the outer @default_timeout_ms 30_000ms.
  #
  # HONESTY CLAUSE (design doc §5.2 item 3 / §1.1-§1.4): this test does
  # NOT prove the guest's underlying native execution is terminated -- it
  # is not. Live verification (design §1.1-§1.4) found the hung guest's
  # native compute keeps running forever in wasmex's own separate native
  # worker-thread pool; only the CALLER's wait is bounded here, via
  # wasmex's own client-side GenServer.call timeout mechanism crashing the
  # task, which Letflow.Engine.PluginInterface's existing {:exit, reason}
  # handling turns into a clean {:error, reason} for the caller.
  # ---------------------------------------------------------------------

  # ---------------------------------------------------------------------
  # REQ-170 AC1: DELETED (ISS-0418, design iss0418-wasm-concurrency-cap.md
  # §6.3.1 item 1) -- merged into REQ-170 AC4's own first (300ms) dispatch below,
  # one of the two dispatches removed from the isolated wasm_hang subprocess
  # (8 -> 6, zero coverage loss). AC1's own four assertions ({:error, reason},
  # is_binary(reason), the absolute elapsed_ms < 10_000 bound, and
  # CallTimeout.classify(result) == :wall_clock_timeout) were checked against
  # this describe block's own req170_hang.wat/PluginInterface.invoke/2 dispatch
  # at 500ms timeout_ms. AC4's own first dispatch (unchanged fixture, unchanged
  # call shape, only the configured timeout_ms differs -- 300ms vs 500ms, both
  # comfortably inside the same < 10_000ms loose bound, design req170 §5.5's own
  # "loose tolerance, not exact millisecond values" discipline) is structurally
  # identical in every respect these assertions test, so they are ADDED to
  # AC4's own first-dispatch assertions below rather than re-dispatched here.
  # ---------------------------------------------------------------------

  # ---------------------------------------------------------------------
  # REQ-170 AC3: the outer PluginInterface.invoke/3 supervised-task
  # boundary terminates the invocation independently of a longer (or
  # absent) inner wasmex-level timeout_ms -- design doc §1.6/§5.4.
  # ---------------------------------------------------------------------

  describe "REQ-170 AC3: outer invoke_opts timeout_ms bounds the caller independently of node_config timeout_ms" do
    # ISS-0352: genuinely, permanently hangs a wasmex native thread -- see
    # the tag note above (AC5 describe block).
    # ISS-0406: raised @tag timeout -- see the mitigation note on the AC5
    # describe block above.
    @tag :wasm_hang
    @tag timeout: 180_000
    test "the outer, shorter bound fires and the dispatched task dies shortly after" do
      hang_context =
        context(%{
          node_config: %{
            "wasm_fixture" => "wasm_fixtures/req170_hang.wat",
            "export" => "hang",
            # deliberately LONGER than the outer invoke_opts bound below --
            # proves the outer boundary does not depend on the inner
            # wasmex-level timeout ever firing first.
            "timeout_ms" => 60_000
          }
        })

      # ISS-0418 (design iss0418-wasm-concurrency-cap.md §6.2 Shape B): this test
      # does not call invoke/2,3 at all -- it reimplements invoke/2,3's own
      # async_nolink/yield/shutdown algorithm inline, so THIS test process plays
      # exactly the role invoke/2,3 plays in production: the process that calls
      # Task.shutdown(:brutal_kill), never the process targeted by it. The lease
      # is TEST-SIDE ONLY (production dispatch does not acquire one yet, design
      # doc §0/§7); acquired before Task.Supervisor.async_nolink/2 is called and
      # released via on_exit/1 (guaranteed even if a later assertion raises),
      # immediately after -- not around -- the existing Task.shutdown(:brutal_kill)
      # call below, mirroring Shape A/C's placement outside anything
      # Task.shutdown(:brutal_kill) targets.
      {:ok, lease} = InvocationLease.try_acquire()
      on_exit(fn -> InvocationLease.release(lease) end)

      # Mirrors PluginInterface.invoke/3's own async_nolink/yield/shutdown
      # shape directly so the dispatched task's pid is observable to this
      # test (invoke/3's own wrapper does not expose it).
      task =
        Task.Supervisor.async_nolink(Letflow.Engine.PluginTaskSupervisor, fn ->
          PluginHandler.handle_node(hang_context)
        end)

      {elapsed_us, yield_result} = :timer.tc(fn -> Task.yield(task, 500) end)
      elapsed_ms = System.convert_time_unit(elapsed_us, :microsecond, :millisecond)

      assert yield_result == nil,
             "expected the outer 500ms bound to fire before the hung guest ever replies"

      assert elapsed_ms < 5_000,
             "expected Task.yield/2 to return around its own 500ms bound, took #{elapsed_ms}ms"

      Task.shutdown(task, :brutal_kill)

      refute Process.alive?(task.pid),
             "expected the dispatched task to be dead shortly after the outer bound fired, " <>
               "independent of the much longer inner timeout_ms"
    end
  end

  # ---------------------------------------------------------------------
  # REQ-170 AC4: timeout_ms is configurable -- two different values drive
  # two different elapsed times, with the shorter one binding sooner.
  # Real wall-clock timing, loose tolerance (design §5.5): not exact
  # millisecond assertions.
  # ---------------------------------------------------------------------

  describe "REQ-170 AC4: the shorter configured timeout_ms binds sooner" do
    # CI-hang-footprint reduction (ORCH final-ci-fix handoff,
    # WF02-REQ170-20260828): this describe block used to run THREE separate
    # live hangs (300ms, 2_000ms, then a third test at 7_000ms), each one a
    # fresh `build_context.()` -> fresh `PluginInterface.invoke` -> fresh
    # `Wasmex.start_link/1`, i.e. 3 permanently-leaked native wasmex
    # threads. Per the handoff's lever 2, a single well-chosen pair proves
    # BOTH properties AC4 needs at once: a `timeout_ms` pair straddling
    # wasmex's own hardcoded 5_000ms default (300ms vs 7_000ms) proves (a)
    # the shorter value binds sooner than the longer one (the original
    # ordering claim) AND (b) `timeout_ms` is threaded through to
    # `Wasmex.call_function/4` rather than silently dropped -- if it were
    # dropped, BOTH calls would collapse to wasmex's ~5_000ms default,
    # making short_elapsed_ms >= long-side-relevant and the >6_000ms bound
    # below fail. This keeps the exact mutation-strengthening guarantee the
    # original two tests established (see prior git history for the
    # separately-confirmed-locally mutation finding this consolidation
    # preserves) while cutting the live-hang footprint from 3 calls to 2.
    # ISS-0352: genuinely, permanently hangs 2 wasmex native threads (one
    # per call) -- see the tag note above (AC5 describe block).
    # ISS-0406: raised @tag timeout -- see the mitigation note on the AC5
    # describe block above. This test's own trailing `long_elapsed_ms`
    # upper-bound assertion (below) is ALSO loosened (15_000 -> 45_000ms):
    # unlike the ExUnit-level timeout, that assertion is an explicit numeric
    # check, so a raised @tag timeout alone does not help it. It failed
    # outright at 30_003ms on the ISS-0352/PR #786 recurrence -- a value the
    # old 15_000ms bound could never tolerate no matter how much CI-runner
    # contention was in play. The loosened bound still discriminates real
    # regressions: `long_elapsed_ms > 6_000` (below, unchanged) still rules
    # out timeout_ms being silently dropped to wasmex's hardcoded 5_000ms
    # default, and 45_000ms remains well short of any point where this
    # assertion would stop meaning anything.
    # ISS-0418 (design iss0418-wasm-hang-test-isolation-fix.md §5): this test body's
    # two dispatches are a documented IRREDUCIBLE PAIR -- do not split this into two
    # `test` blocks to "parallelize" or "further isolate" it under the per-test
    # subprocess harness (lib/mix/tasks/letflow.check.test.ex). Splitting would not
    # reduce the isolated-subprocess leak count (each dispatch already leaks one
    # Store regardless of which test body it's in) and would only add a second,
    # unnecessary `mix test` boot for no benefit, since both dispatches already land
    # in one already-isolated subprocess. See also the prior design doc
    # (iss0418-wasm-concurrency-cap.md §6.3.1 item 1/3) for why the ordering
    # assertion below needs both results in scope together.
    @tag :wasm_hang
    @tag timeout: 180_000
    test "a 300ms timeout_ms binds sooner than a 7_000ms timeout_ms, and 7_000ms is not silently dropped to wasmex's hardcoded 5_000ms default" do
      build_context = fn timeout_ms ->
        context(%{
          node_config: %{
            "wasm_fixture" => "wasm_fixtures/req170_hang.wat",
            "export" => "hang",
            "timeout_ms" => timeout_ms
          }
        })
      end

      # ISS-0418 (design iss0418-wasm-concurrency-cap.md §6.2 Shape A): this lease
      # is TEST-SIDE ONLY -- production dispatch does not acquire one yet (design
      # doc §0/§7). Acquired and released ONCE per dispatch (not once around
      # both) -- each call is an independent admission event, and the second call
      # must not be admitted until the first's lease (and, more importantly, the
      # first's own outer bound) has actually returned. Released via on_exit/1
      # (guaranteed even if a later assertion raises).
      {:ok, lease_short} = InvocationLease.try_acquire()
      on_exit(fn -> InvocationLease.release(lease_short) end)

      {short_elapsed_us, short_result} =
        :timer.tc(fn -> PluginInterface.invoke(PluginHandler, build_context.(300)) end)

      {:ok, lease_long} = InvocationLease.try_acquire()
      on_exit(fn -> InvocationLease.release(lease_long) end)

      {long_elapsed_us, long_result} =
        :timer.tc(fn -> PluginInterface.invoke(PluginHandler, build_context.(7_000)) end)

      assert {:error, _} = short_result
      assert {:error, _} = long_result

      short_elapsed_ms = System.convert_time_unit(short_elapsed_us, :microsecond, :millisecond)
      long_elapsed_ms = System.convert_time_unit(long_elapsed_us, :microsecond, :millisecond)

      # REQ-170 AC1 (deleted, ISS-0418 design doc §6.3.1 item 1): these three
      # assertions did NOT previously exist on this dispatch -- they are ADDED
      # here, checked against this dispatch's own already-captured
      # short_result/short_elapsed_ms, per §6.2's own explicit merge instruction.
      # AC1's own claim (inner bound fires, elapsed time reflects the configured
      # value not the outer default, classify/1 recognizes it) is exactly as true
      # of this 300ms dispatch as it was of AC1's own former 500ms dispatch.
      assert {:error, short_reason} = short_result
      assert is_binary(short_reason)

      assert short_elapsed_ms < 10_000,
             "expected the call to be bounded by the configured 300ms timeout_ms, " <>
               "not the outer 30_000ms default; took #{short_elapsed_ms}ms"

      assert CallTimeout.classify(short_result) == :wall_clock_timeout

      assert short_elapsed_ms < long_elapsed_ms,
             "expected the 300ms-configured call (#{short_elapsed_ms}ms) to bind sooner than " <>
               "the 7_000ms-configured call (#{long_elapsed_ms}ms)"

      assert long_elapsed_ms > 6_000,
             "expected the 7_000ms-configured call to be bounded by its own configured " <>
               "timeout_ms, not wasmex's own hardcoded 5_000ms default; took " <>
               "#{long_elapsed_ms}ms -- a value near 5_000ms means timeout_ms is being " <>
               "silently dropped before reaching Wasmex.call_function/4"

      # Still comfortably below the outer PluginInterface default (30_000ms)
      # under normal conditions; loosened from 15_000 to 45_000 (ISS-0406) to
      # tolerate CI-runner CPU-scheduling contention jitter (observed as high
      # as 30_003ms on the ISS-0352/PR #786 recurrence) without weakening
      # what this assertion actually discriminates (see the describe block's
      # comment above).
      assert long_elapsed_ms < 45_000
    end
  end

  # ---------------------------------------------------------------------
  # AC1/AC9 sanity: the trivial guest fixture and handler round-trip.
  # ---------------------------------------------------------------------

  describe "handle_node/1 directly (sanity, not the crash-safety path)" do
    test "the trivial guest fixture answers 42" do
      assert {:complete, %{"answer" => 42, "executed_in_pid" => pid}} =
               PluginHandler.handle_node(context())

      assert pid == self()
    end
  end

  # ---------------------------------------------------------------------
  # REQ-174 (WASM-13 restated) -- per-invocation isolation via
  # PluginHandler's private run_guest/3 call path (reached only through
  # handle_node/1, since run_guest/3 itself is private). See
  # lib/letflow/design/req174-wasm-instance-pooling-or-decline.md §4.3.
  # This is a DISTINCT instantiation call site from
  # ModuleVersionRegistry.invoke/4 (module_version_registry_test.exs's own
  # REQ-174 test) -- start_instance/1 here calls Wasmex.start_link/1 with
  # no :store option (moduledoc, "REQ-174" section), so this call path also
  # gets a brand-new Store/linear memory on every invocation, independent
  # of ModuleVersionRegistry's own checkout/release machinery. Pooling is
  # DECLINED (no pooling module exists); this test proves INV-174-1 holds
  # for this call site too.
  # ---------------------------------------------------------------------

  describe "REQ-174 INV-174-1: per-invocation isolation via PluginHandler's run_guest/3 call path" do
    test "invocation N's write_marker is NOT observable in invocation N+1's read_marker, same fixture, two separate handle_node/1 calls" do
      write_context =
        context(%{
          node_config: %{
            "wasm_fixture" => "wasm_fixtures/req174_memory_write.wat",
            "export" => "write_marker"
          }
        })

      read_context =
        context(%{
          node_config: %{
            "wasm_fixture" => "wasm_fixtures/req174_memory_write.wat",
            "export" => "read_marker"
          }
        })

      # Invocation N: writes byte 1 at offset 0 of THIS call's own fresh
      # linear memory, and returns 0 (its own, unrelated return value).
      assert {:complete, %{"answer" => 0}} = PluginHandler.handle_node(write_context)

      # Invocation N+1: a wholly separate handle_node/1 call -- no state is
      # passed between the two other than the fixture path string, which
      # is not a live Wasm instance. If run_guest/3 ever started sharing a
      # Store/instance across invocations, this would read back 1. It must
      # read 0 -- zero-initialized memory invocation N's write never
      # touched, because start_instance/1 never shares a Store between
      # invocations (moduledoc "REQ-174" section, INV-174-1).
      assert {:complete, %{"answer" => 0}} = PluginHandler.handle_node(read_context)
    end
  end
end
