defmodule Letflow.Engine.Wasm.CallTimeoutTest do
  @moduledoc """
  REQ-170 -- coverage for `Letflow.Engine.Wasm.CallTimeout`. See
  `lib/letflow/design/req170-wasm-wallclock-timeout.md` (gate-approved) for
  the full rationale, live-verification findings, and AC traceability
  these tests exercise.

  SAFETY NOTE (design doc §1.5/§5.7): this file deliberately does NOT
  reproduce the design's 32-concurrent-hang worker-pool-saturation
  scenario -- that scenario durably occupies `wasmex`'s shared,
  node-global native thread pool for the remainder of any test run it is
  part of, corrupting every other WASM test's own timing assumptions.
  That finding is recorded as a one-time, this-design-session live result
  only (design §1.5, §8), not an automated regression test here.

  `async: false`: every test here builds a real Wasmtime instance via
  `wasmex`'s NIF, mirroring `plugin_handler_test.exs`'s and
  `resource_limits_test.exs`'s identical rationale for keeping WASM-NIF
  tests serial.
  """

  use ExUnit.Case, async: false
  @moduletag :unit

  alias Letflow.Engine.PluginInterface
  alias Letflow.Engine.PluginInterface.ExecutionContext
  alias Letflow.Engine.Wasm.CallTimeout
  alias Letflow.Engine.Wasm.InvocationLease
  alias Letflow.Engine.Wasm.PluginHandler
  alias Letflow.Engine.Wasm.ResourceLimits

  defp fixture_bytes(name) do
    Application.app_dir(:letflow, "priv")
    |> Path.join("wasm_fixtures/#{name}")
    |> File.read!()
  end

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
  # AC2 (design §1.1/§1.2/§5.3): verify wasmex's documented
  # interrupt-and-keep-Store claim by running it DIRECTLY against
  # Wasmex.call_function/4 (not through PluginHandler) -- and assert the
  # REAL, live-verified behavior: a crash/exit, not a clean {:error, _};
  # a second call on the same pid also never replies.
  # ---------------------------------------------------------------------

  describe "AC2: wasmex's documented interrupt-and-keep-Store claim, tested directly against Wasmex.call_function/4" do
    # ISS-0352: this test genuinely, permanently hangs the wasmex NIF native
    # thread it dispatches to (no BEAM-side mechanism can reclaim it -- see
    # req170's own design doc section 1.1-1.4). Tagged so it runs isolated
    # from the rest of the suite (test_helper.exs excludes :wasm_hang by
    # default; mix letflow.check.test runs it in its own dedicated,
    # short-lived BEAM node afterward) rather than leaking a thread into the
    # shared pool every other WASM NIF test in the same process depends on.
    # ISS-0406/ISS-0352 recurrence mitigation: the internal bound this test
    # waits on is a fixed 500ms/1_000ms wasmex GenServer.call timeout, so it
    # normally completes in well under 2s. Recurring CI failures (PRs #780,
    # #786, #790, #788, #792, #798, #801) hit ExUnit's default 60_000ms
    # per-test timeout not because this mechanism took 60s on its own merits,
    # but because host-level CPU scheduling contention on a busy/shared CI
    # runner delayed BEAM's own timer/message delivery to the caller process.
    # A raised @tag timeout tolerates that jitter without masking a genuine
    # regression: if the wasmex client-side timeout mechanism itself ever
    # broke and truly stopped firing, this test would still eventually hit
    # the (now-later) timeout and fail -- it only buys headroom against
    # scheduling delay, never against an undetected real hang.
    @tag :wasm_hang
    @tag timeout: 180_000
    test "a timed-out call crashes the caller with an ordinary GenServer.call exit, not a clean {:error, _}" do
      # ISS-0418 (design iss0418-wasm-concurrency-cap.md §6.2 Shape C): this lease is
      # TEST-SIDE ONLY -- production dispatch does not acquire one yet (design doc
      # §0/§7). Acquired here, before Wasmex.start_link/1, because this test's own
      # process is never killed by anything (no Task.shutdown(:brutal_kill) anywhere
      # in this shape's call graph -- the test process's own try/catch observes its
      # own exit and survives it), so the acquire/release wraps the whole live-hang
      # dispatch below. Released via on_exit/1, not a bare try/after, so a later
      # assertion failure in this test cannot skip the release (design doc §6.2).
      {:ok, lease} = InvocationLease.try_acquire()
      on_exit(fn -> InvocationLease.release(lease) end)

      {:ok, pid} = Wasmex.start_link(%{bytes: fixture_bytes("req170_hang.wat")})

      first_result =
        try do
          {:clean_return, Wasmex.call_function(pid, "hang", [], 500)}
        catch
          :exit, reason -> {:exit, reason}
        end

      assert {:exit, reason} = first_result,
             "expected wasmex's documented timeout to interrupt cleanly with {:error, _}, but " <>
               "live verification (design §1.1) found it crashes the caller instead with an " <>
               "ordinary GenServer.call exit -- this test asserts the REAL behavior, not the " <>
               "documented claim"

      # {:timeout, {GenServer, :call, [...]}} -- design §1.1's exact shape.
      assert match?({:timeout, {GenServer, :call, _}}, reason)

      # Second half of the documented claim ("keeps the Store available for
      # subsequent calls"): live-verified FALSE (design §1.2) -- a second
      # call on the same pid also never replies, it queues behind the
      # still-running first command inside wasmex's own per-Store executor
      # and never completes.
      second_result =
        try do
          {:clean_return, Wasmex.call_function(pid, "hang", [], 1_000)}
        catch
          :exit, reason2 -> {:exit, reason2}
        end

      assert {:exit, _} = second_result,
             "expected the Store to remain permanently wedged after the first timeout " <>
               "(design §1.2), not become usable again for a subsequent call"
    end
  end

  # ---------------------------------------------------------------------
  # AC5 (design §4.2/§4.4/§5.6): classify/1 distinguishes a
  # wall-clock-timeout outcome from ResourceLimits.classify_call_result/1's
  # fuel-exhaustion/trap outcomes, both by type-shape and by disjoint
  # substring.
  # ---------------------------------------------------------------------

  describe "AC5: classify/1 is distinguishable from ResourceLimits.classify_call_result/1" do
    # CI-hang-footprint reduction (ORCH final-ci-fix handoff,
    # WF02-REQ170-20260828): this test used to dispatch its OWN live hang
    # through PluginInterface.invoke/2 with node_config["timeout_ms"] => 300,
    # duplicating a live end-to-end proof of the exact same mechanism (inner
    # wasmex-level GenServer.call timeout -> PluginInterface {:exit, reason}
    # -> classify/1) that plugin_handler_test.exs's "REQ-170 AC4: the shorter
    # configured timeout_ms binds sooner" test's own first (300ms) dispatch
    # already covers live (same req170_hang.wat fixture, same
    # node_config["timeout_ms"] shape, and it also asserts
    # CallTimeout.classify(result) == :wall_clock_timeout -- ISS-0418, design
    # iss0418-wasm-concurrency-cap.md §6.3.1 item 1, merged what used to be a
    # separate REQ-170 AC1 test's assertions onto this same AC4 dispatch).
    # Converted to a synthetic outcome() value, captured verbatim from one
    # real run of that exact live call (`scratch/req170_capture_outcome.exs`,
    # git-ignored per core-directives.md's scratch rule, same node_config
    # shape as plugin_handler_test.exs's AC4 test's first dispatch): removes
    # one permanently-leaked native wasmex thread with zero loss of coverage,
    # since the live end-to-end proof for this mechanism still exists (in
    # plugin_handler_test.exs).
    test "a real captured wall-clock-timeout PluginInterface outcome (synthetic replay of a live-captured string) classifies as :wall_clock_timeout" do
      # Captured verbatim, 2026-08-28, from a live
      # `PluginInterface.invoke(PluginHandler, hang_context)` call against
      # req170_hang.wat with node_config["timeout_ms"] => 300 -- the exact
      # shape plugin_handler_test.exs's REQ-170 AC4 test's first dispatch
      # still proves live.
      captured_reason =
        "plugin handler Letflow.Engine.Wasm.PluginHandler crashed: " <>
          "{:timeout, {GenServer, :call, [#PID<0.297.0>, {:call_function, \"hang\", [], 300}, 300]}}"

      outcome = {:error, captured_reason}
      assert CallTimeout.classify(outcome) == :wall_clock_timeout
    end

    # ISS-0418 (design iss0418-wasm-concurrency-cap.md §6.3.1 item 2): CONVERTED
    # from a live :wasm_hang dispatch to a synthetic captured-string replay, one
    # of the two dispatches removed from the isolated wasm_hang subprocess (8 -> 6,
    # zero coverage loss). This test's entire purpose is confirming
    # CallTimeout.classify/1 recognizes the OUTER-timeout nil-clause reason string
    # shape as :wall_clock_timeout -- a claim about a STRING PATTERN MATCH, not
    # live timing. The exact live mechanism that produces this string (the outer
    # bound firing) is still proven live elsewhere in this same rework's own
    # wiring, by plugin_handler_test.exs:152 (AC5) -- the sole live source (design
    # doc §6.3.1 item 2's own ATTRIBUTION CORRECTION: :393/AC3 does NOT also
    # produce this string, it never calls invoke/2,3 at all). Mirrors this same
    # file's own existing synthetic-replay precedent immediately above (AC5, "a
    # real captured wall-clock-timeout... outcome").
    test "a real captured outer-timeout PluginInterface outcome (synthetic replay of a live-captured string) classifies as :wall_clock_timeout" do
      # Captured verbatim, 2026-09-05, from a live
      # `PluginInterface.invoke(PluginHandler, hang_context, timeout_ms: 200)` call
      # against req170_hang.wat (no inner node_config["timeout_ms"] configured, so
      # the OUTER Task.yield/2 bound fires first) -- the exact shape
      # plugin_handler_test.exs's REQ-165 AC5 test still proves live.
      captured_reason =
        "plugin handler Letflow.Engine.Wasm.PluginHandler did not respond within 200ms"

      outcome = {:error, captured_reason}
      assert CallTimeout.classify(outcome) == :wall_clock_timeout
    end

    test "a successful outcome classifies as :not_timeout" do
      assert {:complete, _} = outcome = PluginInterface.invoke(PluginHandler, context())
      assert CallTimeout.classify(outcome) == :not_timeout
    end

    test "a real captured fuel-exhaustion ResourceLimits classification is a disjoint type and disjoint substring from :wall_clock_timeout" do
      {:ok, {_engine, store}} =
        ResourceLimits.build_store(%{fuel_budget: 1_000, memory_cap_bytes: 65_536})

      {:ok, pid} = Wasmex.start_link(%{store: store, bytes: fixture_bytes("req169_hang.wat")})
      :ok = ResourceLimits.arm_fuel(store, 1_000)

      task =
        Task.Supervisor.async_nolink(Letflow.Engine.PluginTaskSupervisor, fn ->
          Wasmex.call_function(pid, "hang", [])
        end)

      raw_result =
        case Task.yield(task, 5_000) do
          {:ok, result} -> result
          nil -> Task.shutdown(task, :brutal_kill) && flunk("expected fuel to exhaust, not hang")
        end

      fuel_classification = ResourceLimits.classify_call_result(raw_result)
      assert fuel_classification == :fuel_exhausted

      # (1) type-shape: an atom from a RAW Wasmex.call_function/4 return,
      # never equal to a CallTimeout.classification() value by construction.
      refute fuel_classification in [:wall_clock_timeout, :not_timeout]

      # (2) disjoint substrings, checked in both directions (design §4.4).
      {:error, fuel_reason} = raw_result
      assert String.contains?(fuel_reason, "all fuel consumed by WebAssembly")
      refute String.contains?(fuel_reason, "did not respond within")
      refute String.contains?(fuel_reason, "{:timeout, {GenServer, :call,")
    end

    test "classify/1's own two substrings never appear in a fuel-exhaustion reason string (pure, no live call needed)" do
      fuel_reason = "wasm guest call failed: {:error, \"all fuel consumed by WebAssembly\"}"
      refute String.contains?(fuel_reason, "did not respond within")
      refute String.contains?(fuel_reason, "{:timeout, {GenServer, :call,")
      assert CallTimeout.classify({:error, fuel_reason}) == :not_timeout
    end
  end

  # ---------------------------------------------------------------------
  # AC6 (design §6/§5.7): moduledoc states OQ-5 is not settled by this
  # requirement (naming what would settle it), and files the node-wide
  # worker-pool-exhaustion finding rather than silently absorbing it.
  # ---------------------------------------------------------------------

  describe "AC6: moduledoc content -- OQ-5 discipline" do
    test "moduledoc states OQ-5 is not settled here and names what would settle it" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(CallTimeout)

      assert moduledoc =~ "OQ-5"
      normalized = String.replace(moduledoc, ~r/\s+/, " ")
      assert normalized =~ "NOT settled by this requirement"
      assert normalized =~ "load spike"
      assert normalized =~ "S6"
    end

    test "moduledoc files the node-wide worker-pool-exhaustion finding, not silently absorbed" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(CallTimeout)

      assert moduledoc =~ "worker-pool-exhaustion" or moduledoc =~ "worker-thread pool"
      assert moduledoc =~ "node-global"
      assert moduledoc =~ "filed"
    end

    test "moduledoc states the decision 0014 divergence and that execution itself is not terminated" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(CallTimeout)

      assert moduledoc =~ "DIVERGENCE"
      assert moduledoc =~ "decision 0014"
      normalized = String.replace(moduledoc, ~r/\s+/, " ")
      assert normalized =~ "does **not** hold" or normalized =~ "does not hold"
    end

    # Mutation-driven strengthening (WF-02 Step 3, REQ-170), mirroring
    # REQ-169's own identical precedent (test/specs/REQ-169.md,
    # resource_limits_test.exs's "cites the actual mechanism terms" test):
    # the three loose keyword/substring checks above (this describe block)
    # are individually satisfiable by an adversarial moduledoc that merely
    # scatters "OQ-5"/"NOT settled by this requirement"/"load spike"/"S6"/
    # "worker-pool-exhaustion"/"node-global"/"filed"/"DIVERGENCE"/
    # "decision 0014"/"does **not** hold" across unrelated sentences with no
    # real WASM-11/wasmex context at all. Confirmed locally: temporarily
    # replacing CallTimeout's real moduledoc with a short adversarial
    # paragraph about sourdough bread and bakery staffing (planting every
    # one of those fragments in an unrelated sentence, e.g. "the bakery has
    # a worker-pool-exhaustion problem (too few bakers), described as
    # node-global understaffing, which HR has filed as a complaint") still
    # passed all 3 existing AC6 tests above (13/13 green for the file). This
    # test closes that gap by requiring the real mechanism terms
    # (TOKIO_RUNTIME, wasmex) and the load-bearing citation (design doc
    # filename) to co-occur, in order, with the claims they support --
    # not merely appear anywhere in the moduledoc.
    test "the OQ-5 filing and DIVERGENCE claims cite the actual mechanism terms and design doc, not just isolated keyword fragments" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(CallTimeout)

      # Real mechanism term, not just the generic "worker-thread pool"
      # phrase an adversary could reuse in an unrelated sentence.
      assert moduledoc =~ "TOKIO_RUNTIME"

      # Load-bearing citation of the gate-approved design doc by filename --
      # an adversarial paraphrase satisfying only the loose checks above
      # would not be traceable back to its authorizing source.
      assert moduledoc =~ "req170-wasm-wallclock-timeout.md"

      # The "does not hold" divergence claim must be anchored to the actual
      # dependency it was live-verified against, not floating free.
      assert moduledoc =~ ~r/wasmex.{0,300}(does \*\*not\*\* hold|does not hold)/is

      # The worker-pool-exhaustion finding must be anchored to the actual
      # mechanism name (TOKIO_RUNTIME), which appears after "node-global" in
      # the real moduledoc's own wording.
      assert moduledoc =~ ~r/node-global.{0,150}TOKIO_RUNTIME/is

      # The OQ-5-not-settled statement must co-occur with what would settle
      # it (load spike + S6), not merely both appear anywhere in the doc.
      assert moduledoc =~ ~r/NOT settled by this requirement.{0,200}load spike.{0,100}S6/is
    end
  end

  # ---------------------------------------------------------------------
  # classify/1 pure unit coverage.
  # ---------------------------------------------------------------------

  describe "classify/1 pure unit coverage" do
    test "classifies the {:exit, reason} GenServer.call-timeout shape as :wall_clock_timeout" do
      reason =
        "plugin handler Elixir.Foo crashed: " <>
          inspect(
            {:timeout, {GenServer, :call, [self(), {:call_function, "hang", [], 500}, 500]}}
          )

      assert CallTimeout.classify({:error, reason}) == :wall_clock_timeout
    end

    test "classifies the nil/outer-timeout shape as :wall_clock_timeout" do
      reason = "plugin handler Elixir.Foo did not respond within 100ms"
      assert CallTimeout.classify({:error, reason}) == :wall_clock_timeout
    end

    test "classifies an unrelated {:error, reason} as :not_timeout" do
      assert CallTimeout.classify({:error, "wasm guest call failed: some other reason"}) ==
               :not_timeout
    end

    test "classifies {:complete, _} as :not_timeout" do
      assert CallTimeout.classify({:complete, %{}}) == :not_timeout
    end

    # Mutation-driven strengthening (WF-02 Step 3, REQ-170): loosening
    # @genserver_call_timeout_substring from the exact
    # "{:timeout, {GenServer, :call," shape down to the bare word "timeout"
    # was NOT caught by any of the tests above -- every real timeout string
    # this module actually produces already contains "timeout" as a
    # substring, so the loosened match still agrees with them, and the only
    # "unrelated" fixture above ("wasm guest call failed: some other
    # reason") happens not to contain the word "timeout" either, so it
    # doesn't exercise the loosened match at all. Confirmed locally: with
    # the substring loosened to "timeout", all pre-existing tests in this
    # file and plugin_handler_test.exs still passed (26/26). This test
    # closes the gap with a reason string that DOES contain "timeout" as a
    # substring but is NOT the specific GenServer.call-timeout shape.
    test "a reason containing the word 'timeout' outside the exact GenServer.call-timeout shape classifies as :not_timeout (guards against an over-loosened substring match)" do
      reason = "handler reported a downstream HTTP timeout while querying an external service"
      refute String.contains?(reason, "{:timeout, {GenServer, :call,")
      refute String.contains?(reason, "did not respond within")

      assert CallTimeout.classify({:error, reason}) == :not_timeout
    end

    # Mutation-driven strengthening (WF-02 Step 3, REQ-170): symmetrically,
    # loosening @outer_task_timeout_substring from "did not respond within"
    # down to the bare word "within" was also NOT caught by any of the
    # tests above, for the same reason -- confirmed locally, 26/26 still
    # passed. This test closes that gap with a reason string containing
    # "within" but not the specific outer-Task.yield-timeout shape.
    test "a reason containing the word 'within' outside the exact outer-timeout shape classifies as :not_timeout (guards against an over-loosened substring match)" do
      reason = "handler returned a value within acceptable bounds; no timeout involved"
      refute String.contains?(reason, "{:timeout, {GenServer, :call,")
      refute String.contains?(reason, "did not respond within")

      assert CallTimeout.classify({:error, reason}) == :not_timeout
    end
  end
end
