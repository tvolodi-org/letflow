defmodule Letflow.Engine.Wasm.ResourceLimitsTest do
  @moduledoc """
  REQ-169 -- coverage for `Letflow.Engine.Wasm.ResourceLimits`. See
  `lib/letflow/design/req169-wasm-fuel-and-memory-cap.md` (gate-approved)
  for the full rationale, live-verification findings, and AC traceability
  these tests exercise.

  No REQ-171/172 host function exists yet, so tests exercise `ResourceLimits`
  directly against dedicated fixtures (`priv/wasm_fixtures/req169_*.wat`),
  mirroring `memory_guard_test.exs`'s identical precedent (REQ-168).

  **AC3's memory-cap test is written against the real, live-verified
  behavior, NOT against WASM-10's literal "traps cleanly" wording.**
  `memory.grow` beyond `StoreLimits.memory_size` returns an ordinary
  success (`{:ok, [-1]}`), never a trap -- see design §1.6/§2/§7 for the
  full divergence statement. This is a deliberate, documented departure
  from the acceptance criterion's literal wording, not an oversight.

  `async: false`: every test here builds a real Wasmtime instance via
  `wasmex`'s NIF and dispatches guest calls through the shared
  `Letflow.Engine.PluginTaskSupervisor`, mirroring `plugin_handler_test.exs`'s
  and `memory_guard_test.exs`'s identical rationale for keeping WASM-NIF
  tests serial.
  """

  use ExUnit.Case, async: false
  @moduletag :unit

  alias Letflow.Engine.Wasm.ResourceLimits

  # ---------------------------------------------------------------------
  # Test helpers.
  # ---------------------------------------------------------------------

  defp fixture_bytes(name) do
    Application.app_dir(:letflow, "priv")
    |> Path.join("wasm_fixtures/#{name}")
    |> File.read!()
  end

  # Builds a fresh Engine/Store pair via ResourceLimits.build_store/1, then a
  # fresh Wasmex guest instance against that store, compiled from the named
  # fixture. Mirrors memory_guard_test.exs's start_instance/0 helper, but
  # threads a ResourceLimits config through instead of an unconfigured store.
  defp start_instance(config, fixture_name) do
    {:ok, {_engine, store}} = ResourceLimits.build_store(config)
    {:ok, pid} = Wasmex.start_link(%{store: store, bytes: fixture_bytes(fixture_name)})
    {pid, store}
  end

  # Dispatches a guest call under the existing, unmodified
  # Letflow.Engine.PluginTaskSupervisor, bounded by a generous outer timeout
  # -- mirroring PluginInterface.invoke/3's own async_nolink/yield/shutdown
  # shape (lib/letflow/engine/plugin_interface.ex), never called into
  # directly here since ResourceLimits owns no dispatch responsibility of
  # its own (design §3). Returns the raw Wasmex.call_function/4 result, or
  # :outer_timeout if the outer bound itself fired (which none of these
  # tests expect -- fuel is what is expected to bound every hang case).
  defp dispatch(fun, timeout_ms \\ 10_000) do
    task = Task.Supervisor.async_nolink(Letflow.Engine.PluginTaskSupervisor, fun)

    case Task.yield(task, timeout_ms) do
      {:ok, result} -> result
      {:exit, reason} -> {:exit, reason}
      nil -> Task.shutdown(task, :brutal_kill) && :outer_timeout
    end
  end

  defp call_hang(pid), do: dispatch(fn -> Wasmex.call_function(pid, "hang", []) end)

  defp call_count_forever(pid),
    do: dispatch(fn -> Wasmex.call_function(pid, "count_forever", []) end)

  # Arms a fresh fuel budget immediately before every call, per the design's
  # own contract (arm_fuel/2 MUST run immediately before every single
  # invocation, never once at Store-creation time only) -- fuel-budget-large
  # tests below rely on this so a call is never starved by 0 leftover fuel.
  defp call_grow_by(pid, store, fuel_budget, delta) do
    :ok = ResourceLimits.arm_fuel(store, fuel_budget)
    dispatch(fn -> Wasmex.call_function(pid, "grow_by", [delta]) end)
  end

  # Reads the req169_counting.wat loop-iteration counter back from linear
  # memory offset 0 (a little-endian i32) after the guest has trapped --
  # design §1.4/§5.3: locals are lost on trap, but memory written on every
  # iteration survives and is readable via the still-valid Store/Memory
  # handle (per REQ-168 §1.5/§1.1's already-established finding).
  defp read_counter(pid) do
    {:ok, store} = Wasmex.store(pid)
    {:ok, memory} = Wasmex.memory(pid)
    <<counter::little-integer-size(32)>> = Wasmex.Memory.read_binary(store, memory, 0, 4)
    counter
  end

  # ---------------------------------------------------------------------
  # AC1/AC5 (design §5.2): fuel metering genuinely bounds an infinite loop
  # and is genuinely enabled.
  # ---------------------------------------------------------------------

  describe "AC1/AC5: fuel metering bounds an infinite loop and is genuinely enabled" do
    test "an infinite-loop guest terminates within its configured fuel budget rather than hanging, classified as :fuel_exhausted" do
      {pid, store} =
        start_instance(%{fuel_budget: 1_000, memory_cap_bytes: 65_536}, "req169_hang.wat")

      assert ResourceLimits.arm_fuel(store, 1_000) == :ok

      result = call_hang(pid)

      refute result == :outer_timeout
      assert ResourceLimits.classify_call_result(result) == :fuel_exhausted
    end

    test "arm_fuel/2 against a store built with consume_fuel: false returns {:error, {:fuel_not_configured, _}} -- the canary that fires if fuel metering were ever accidentally left disabled" do
      # Deliberately bypasses ResourceLimits.build_store/1 (which never
      # allows consume_fuel to be anything but true, design §2 item 1) to
      # simulate what a hypothetical future regression would produce --
      # design §5.2 test 2.
      {:ok, engine} = Wasmex.Engine.new(%Wasmex.EngineConfig{consume_fuel: false})
      {:ok, store} = Wasmex.Store.new(nil, engine)

      assert {:error, {:fuel_not_configured, reason}} = ResourceLimits.arm_fuel(store, 10)
      assert is_binary(reason)
    end
  end

  # ---------------------------------------------------------------------
  # AC2 (design §5.3): fuel resets per invocation.
  # ---------------------------------------------------------------------

  describe "AC2: fuel resets per invocation" do
    test "two consecutive invocations of the same store each get the full budget -- not merely 'roughly equal', but byte-for-byte identical surviving iteration counts" do
      {pid, store} =
        start_instance(%{fuel_budget: 2_000, memory_cap_bytes: 65_536}, "req169_counting.wat")

      assert ResourceLimits.arm_fuel(store, 2_000) == :ok
      first_result = call_count_forever(pid)
      assert ResourceLimits.classify_call_result(first_result) == :fuel_exhausted
      first_count = read_counter(pid)

      assert ResourceLimits.arm_fuel(store, 2_000) == :ok
      second_result = call_count_forever(pid)
      assert ResourceLimits.classify_call_result(second_result) == :fuel_exhausted
      second_count = read_counter(pid)

      assert first_count == second_count
      assert first_count > 0
    end
  end

  # ---------------------------------------------------------------------
  # AC3 (design §5.4): memory-cap behavior, tested HONESTLY.
  #
  # AC3's own wording ("traps cleanly") is NOT asserted as written here --
  # design §1.6/§7 live-verified that memory.grow beyond StoreLimits.memory_size
  # does NOT trap; it returns an ordinary success carrying WebAssembly's own
  # standard -1 growth-failure sentinel, and real memory size is left
  # unchanged. This is the honest, load-bearing security guarantee this
  # mechanism actually provides, per this design's own explicit divergence
  # statement -- not an oversight.
  # ---------------------------------------------------------------------

  describe "AC3: memory-cap behavior, tested per the design's honest (non-trapping) finding" do
    test "growing exactly to the cap succeeds as an ordinary call" do
      config = %{fuel_budget: 100_000, memory_cap_bytes: 2 * 65_536}
      {pid, store} = start_instance(config, "req169_grow.wat")

      assert call_grow_by(pid, store, config.fuel_budget, 1) == {:ok, [1]}
      assert ResourceLimits.classify_call_result({:ok, [1]}) == :ok
    end

    test "attempting to grow beyond the cap returns an ordinary success ({:ok, [-1]}) carrying Wasm's own growth-failure sentinel -- NOT an error, and real memory size is left unchanged" do
      config = %{fuel_budget: 100_000, memory_cap_bytes: 2 * 65_536}
      {pid, store} = start_instance(config, "req169_grow.wat")

      # Reach the cap exactly first (1 -> 2 pages), then attempt to exceed it.
      assert call_grow_by(pid, store, config.fuel_budget, 1) == {:ok, [1]}

      {:ok, memory} = Wasmex.memory(pid)
      size_before = Wasmex.Memory.size(store, memory)

      result = call_grow_by(pid, store, config.fuel_budget, 5)

      # This IS WebAssembly's own standard growth-failure sentinel, a clean
      # successful call return -- explicitly NOT miscast as an error here,
      # per design §1.6/§7.
      assert result == {:ok, [-1]}
      assert ResourceLimits.classify_call_result(result) == :ok

      size_after = Wasmex.Memory.size(store, memory)

      # The real, load-bearing security property: physical memory did not
      # grow at all despite the guest's request.
      assert size_after == size_before

      assert ResourceLimits.memory_grew_within_cap?(
               size_before,
               size_after,
               config.memory_cap_bytes
             ) ==
               :within_cap
    end
  end

  # ---------------------------------------------------------------------
  # AC4 (design §5.5): both knobs are configurable, and the tighter one
  # binds sooner.
  # ---------------------------------------------------------------------

  describe "AC4: fuel budget and memory cap are both configurable, and the tighter value binds sooner" do
    test "fuel: a tighter budget yields strictly fewer completed guest iterations than a looser one" do
      {tight_pid, tight_store} =
        start_instance(%{fuel_budget: 20, memory_cap_bytes: 65_536}, "req169_counting.wat")

      assert ResourceLimits.arm_fuel(tight_store, 20) == :ok
      tight_result = call_count_forever(tight_pid)
      assert ResourceLimits.classify_call_result(tight_result) == :fuel_exhausted
      tight_count = read_counter(tight_pid)

      {loose_pid, loose_store} =
        start_instance(%{fuel_budget: 2_000, memory_cap_bytes: 65_536}, "req169_counting.wat")

      assert ResourceLimits.arm_fuel(loose_store, 2_000) == :ok
      loose_result = call_count_forever(loose_pid)
      assert ResourceLimits.classify_call_result(loose_result) == :fuel_exhausted
      loose_count = read_counter(loose_pid)

      assert tight_count < loose_count
    end

    test "memory: a tighter cap permits strictly fewer successful page grows than a looser one" do
      tight_fuel_budget = 100_000
      tight_cap = 2 * 65_536

      {tight_pid, tight_store} =
        start_instance(
          %{fuel_budget: tight_fuel_budget, memory_cap_bytes: tight_cap},
          "req169_grow.wat"
        )

      tight_successes = count_successful_grows(tight_pid, tight_store, tight_fuel_budget)

      loose_fuel_budget = 100_000
      loose_cap = 5 * 65_536

      {loose_pid, loose_store} =
        start_instance(
          %{fuel_budget: loose_fuel_budget, memory_cap_bytes: loose_cap},
          "req169_grow.wat"
        )

      loose_successes = count_successful_grows(loose_pid, loose_store, loose_fuel_budget)

      assert tight_successes < loose_successes
    end
  end

  # Repeatedly grows by 1 page until the guest's call returns the -1
  # growth-failure sentinel; returns the count of successful grows before
  # that first failure.
  defp count_successful_grows(pid, store, fuel_budget),
    do: count_successful_grows(pid, store, fuel_budget, 0)

  defp count_successful_grows(pid, store, fuel_budget, acc) do
    case call_grow_by(pid, store, fuel_budget, 1) do
      {:ok, [-1]} -> acc
      {:ok, [_previous_pages]} -> count_successful_grows(pid, store, fuel_budget, acc + 1)
    end
  end

  # ---------------------------------------------------------------------
  # AC6 (design §5.6): fuel exhaustion, an ordinary trap, and a future
  # wall-clock timeout are pattern-match-distinguishable from each other.
  # ---------------------------------------------------------------------

  describe "AC6: classifications are distinguishable from each other and from a future wall-clock timeout" do
    test "fuel exhaustion, an ordinary guest trap, and PluginInterface's own timeout string never collide" do
      {hang_pid, hang_store} =
        start_instance(%{fuel_budget: 1_000, memory_cap_bytes: 65_536}, "req169_hang.wat")

      assert ResourceLimits.arm_fuel(hang_store, 1_000) == :ok
      fuel_result = call_hang(hang_pid)
      assert ResourceLimits.classify_call_result(fuel_result) == :fuel_exhausted

      # A real ordinary error path unrelated to fuel: calling a
      # non-existent export yields wasmex's own clean {:error, _} shape
      # ("exported function `...` not found"), never containing the word
      # "fuel" -- a distinct code path from §1.1's fuel-trap wrapper string.
      {grow_pid, grow_store} =
        start_instance(%{fuel_budget: 100_000, memory_cap_bytes: 65_536}, "req169_grow.wat")

      assert ResourceLimits.arm_fuel(grow_store, 100_000) == :ok
      trap_result = dispatch(fn -> Wasmex.call_function(grow_pid, "no_such_export", []) end)

      assert {:error, trap_message} = trap_result
      assert is_binary(trap_message)
      refute trap_message =~ "fuel"

      assert ResourceLimits.classify_call_result(trap_result) == {:trap, trap_message}

      assert ResourceLimits.classify_call_result(fuel_result) !=
               ResourceLimits.classify_call_result(trap_result)

      # Neither classification's underlying string can ever textually
      # collide with PluginInterface's own timeout shape
      # (lib/letflow/engine/plugin_interface.ex's handle_yield_result/4 nil
      # clause), asserted by construction rather than by exercising
      # REQ-170's not-yet-built mechanism.
      timeout_message = "plugin handler SomeHandler did not respond within 5000ms"
      refute timeout_message =~ "fuel"
      refute timeout_message == trap_message
    end
  end

  # ---------------------------------------------------------------------
  # Mutation-driven strengthening pass (WF-02 Step 3, REQ-169): classify_call_result/1's
  # fuel-exhaustion match must be the FULL "all fuel consumed by WebAssembly" substring,
  # not a loose "fuel" match. A loose match would misclassify an ordinary trap that
  # merely happens to mention the word "fuel" as :fuel_exhausted -- a false positive
  # that would hide a real, unrelated trap behind the fuel-exhaustion label. Confirmed
  # locally that mutating @fuel_exhausted_substring from the full phrase down to just
  # "fuel" left all 9 pre-existing tests green (none of the fixtures' real trap/error
  # strings happen to contain the bare word "fuel"), so this is a genuine coverage gap
  # this test closes -- it does not depend on any wasmex fixture, only on
  # classify_call_result/1's own pure string-matching logic.
  # ---------------------------------------------------------------------

  describe "classify_call_result/1: fuel-exhaustion match is the full canonical substring, not a loose 'fuel' match" do
    test "an ordinary trap message that incidentally contains the bare word 'fuel' (but not the canonical fuel-exhaustion phrase) classifies as {:trap, _}, never :fuel_exhausted" do
      incidental_message =
        "Error during function excecution (wasm trap: out of fuel-adjacent host resource): error while executing at wasm backtrace"

      refute incidental_message =~ "all fuel consumed by WebAssembly"
      assert incidental_message =~ "fuel"

      assert ResourceLimits.classify_call_result({:error, incidental_message}) ==
               {:trap, incidental_message}
    end

    test "the canonical fuel-exhaustion phrase itself still classifies as :fuel_exhausted (control case, guards against an over-corrected match)" do
      canonical_message =
        "Error during function excecution (wasm trap: all fuel consumed by WebAssembly): error while executing at wasm backtrace"

      assert ResourceLimits.classify_call_result({:error, canonical_message}) == :fuel_exhausted
    end
  end

  # ---------------------------------------------------------------------
  # AC7 (design §5.7): the divergence itself is asserted as documented.
  # ---------------------------------------------------------------------

  describe "AC7: moduledoc discloses the WASM-10 trap-vs-success divergence" do
    test "the moduledoc states memory.grow beyond the cap does NOT trap" do
      {:docs_v1, _anno, _lang, _fmt, %{"en" => moduledoc}, _meta, _docs} =
        Code.fetch_docs(Letflow.Engine.Wasm.ResourceLimits)

      assert moduledoc =~ ~r/does \*\*NOT\*\* trap/
      assert moduledoc =~ "WASM-10"
      assert moduledoc =~ "DIVERGENCE"
    end

    # Mutation-driven strengthening (WF-02 Step 3, REQ-169): the three loose
    # substring/regex checks above are individually satisfiable by a moduledoc whose
    # "DIVERGENCE"/"WASM-10"/"does **NOT** trap" fragments are scattered across
    # unrelated sentences describing something else entirely -- confirmed locally by
    # temporarily replacing the real moduledoc with a short adversarial paragraph
    # that plants all three fragments in an unrelated sentence about "unrelated
    # retries" with no mention of memory.grow/StoreLimits.memory_size at all; the
    # three assertions above still passed against it (11/11 green), a genuine gap.
    # This test closes it by requiring the actual mechanism terms
    # (memory.grow/StoreLimits.memory_size) to co-occur with the divergence
    # language, and by requiring the load-bearing citation (design doc filename +
    # decision 0014) per test/specs/REQ-169.md T7.4 / REQ-168's identical
    # citation-strengthening precedent (test/specs/REQ-168.md T5 item 3).
    test "the divergence statement cites the actual mechanism terms and the design doc/decision record, not just isolated keyword fragments" do
      {:docs_v1, _anno, _lang, _fmt, %{"en" => moduledoc}, _meta, _docs} =
        Code.fetch_docs(Letflow.Engine.Wasm.ResourceLimits)

      # The "does NOT trap" claim must be anchored to the real mechanism names, not
      # floating free in an unrelated sentence.
      assert moduledoc =~ "memory.grow"
      assert moduledoc =~ "StoreLimits.memory_size"

      assert moduledoc =~ ~r/StoreLimits\.memory_size.{0,200}does \*\*NOT\*\* trap/s

      # The disclosure must cite the gate-approved design doc and decision 0014 by
      # name -- a prose paraphrase satisfying only the loose keyword checks above
      # would not be traceable back to its authorizing source.
      assert moduledoc =~ "req169-wasm-fuel-and-memory-cap.md"
      assert moduledoc =~ "0014"

      # The underlying security property (real memory cannot exceed the cap despite
      # the non-trapping divergence) must itself be stated, not merely implied.
      assert moduledoc =~ ~r/physically, unconditionally bounds/
    end
  end
end
