defmodule Letflow.Engine.Wasm.ModuleRegistryTest do
  @moduledoc """
  REQ-166 -- coverage for `Letflow.Engine.Wasm.ModuleRegistry`. See
  `lib/letflow/design/req166-wasm-module-abi-validation.md` (gate-approved)
  for the full two-stage algorithm this suite exercises.

  `async: false`: several tests here build a real Wasmtime instance via
  `wasmex`'s NIF (stage 2's instantiation attempt), including the
  unresolved-import case that deliberately reproduces the crash-propagation
  hazard design §1.5 documents. Keeping the file serial avoids any risk of
  overlapping native-NIF activity across `async: true` test processes,
  mirroring `plugin_handler_test.exs`'s own rationale.
  """

  use ExUnit.Case, async: false

  alias Letflow.Engine.Wasm.ModuleRegistry

  defp fixture(name) do
    Application.app_dir(:letflow, "priv")
    |> Path.join("wasm_fixtures/#{name}")
    |> File.read!()
  end

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

  # ---------------------------------------------------------------------
  # AC1: missing `execute` -> {:error, {:invalid_abi, defects}} naming
  # {:missing, "execute"}.
  # ---------------------------------------------------------------------

  describe "AC1: a module missing the execute export is rejected" do
    test "returns {:error, {:invalid_abi, defects}} naming {:missing, \"execute\"}" do
      bytes = fixture("req166_missing_execute.wat")

      assert {:error, {:invalid_abi, defects}} = ModuleRegistry.register(bytes)
      assert {:missing, "execute"} in defects
    end
  end

  # ---------------------------------------------------------------------
  # AC2: each of the other 5 required exports rejected individually, plus a
  # multiple-simultaneous-missing-exports case.
  # ---------------------------------------------------------------------

  describe "AC2: each other required export is rejected individually" do
    test "missing init" do
      assert {:error, {:invalid_abi, defects}} =
               ModuleRegistry.register(fixture("req166_missing_init.wat"))

      assert {:missing, "init"} in defects
    end

    test "missing deinit" do
      assert {:error, {:invalid_abi, defects}} =
               ModuleRegistry.register(fixture("req166_missing_deinit.wat"))

      assert {:missing, "deinit"} in defects
    end

    test "missing get_capabilities" do
      assert {:error, {:invalid_abi, defects}} =
               ModuleRegistry.register(fixture("req166_missing_get_capabilities.wat"))

      assert {:missing, "get_capabilities"} in defects
    end

    test "missing alloc" do
      assert {:error, {:invalid_abi, defects}} =
               ModuleRegistry.register(fixture("req166_missing_alloc.wat"))

      assert {:missing, "alloc"} in defects
    end

    test "missing memory" do
      assert {:error, {:invalid_abi, defects}} =
               ModuleRegistry.register(fixture("req166_missing_memory.wat"))

      assert {:missing, "memory"} in defects
    end

    test "multiple simultaneously-missing exports (init AND get_capabilities) all appear" do
      assert {:error, {:invalid_abi, defects}} =
               ModuleRegistry.register(fixture("req166_missing_multiple.wat"))

      assert {:missing, "init"} in defects
      assert {:missing, "get_capabilities"} in defects
      assert length(defects) == 2
    end

    test "a wrong-signature execute export is rejected as :wrong_signature, not :missing" do
      assert {:error, {:invalid_abi, defects}} =
               ModuleRegistry.register(fixture("req166_wrong_signature_execute.wat"))

      assert [
               {:wrong_signature, "execute",
                expected: {[:i32, :i32], [:i32]}, actual: {[:i32], [:i32]}}
             ] =
               defects
    end

    test "an execute export whose params/results are exactly TRANSPOSED (mutation-guard) is rejected as :wrong_signature, distinct from :missing" do
      # Mutation-guard test: a defect_for/2 that matched the exported
      # signature against {actual_results, actual_params} instead of
      # {actual_params, actual_results} (a plausible copy/paste swap of the
      # two pinned variables on the `{:ok, {:fn, ^params, ^results}} -> nil`
      # clause at module_registry.ex around line 200) would incorrectly treat
      # this fixture's execute export -- (param i32) (result i32 i32), i.e.
      # exactly {expected_results, expected_params} -- as conforming. Neither
      # req166_wrong_signature_execute.wat (arity-mismatched, not a true
      # transpose) nor any other existing fixture has this exact
      # {actual_params, actual_results} == {expected_results, expected_params}
      # shape, so this is the only fixture that distinguishes the two clause
      # orderings.
      assert {:error, {:invalid_abi, defects}} =
               ModuleRegistry.register(fixture("req166_swapped_signature_execute.wat"))

      assert [
               {:wrong_signature, "execute",
                expected: {[:i32, :i32], [:i32]}, actual: {[:i32], [:i32, :i32]}}
             ] =
               defects

      refute {:missing, "execute"} in defects
    end
  end

  # ---------------------------------------------------------------------
  # AC3: rejection happens at registration, never at invocation; the opaque
  # type means no test can construct a registered_module() for a
  # non-conforming module. Also covers the NEW stage-2 rejection case: an
  # unresolved WASI import in an otherwise export-conforming module.
  # ---------------------------------------------------------------------

  describe "AC3: rejection is structural (registration-time), including stage-2 instantiation failures" do
    test "a non-conforming module never produces a registered_module() value" do
      assert {:error, _} = ModuleRegistry.register(fixture("req166_missing_execute.wat"))
      # No public constructor exists other than register/1's own success
      # branch (@opaque, enforced at compile time by
      # `mix compile --warnings-as-errors`) -- there is no expression this
      # test (or any code outside ModuleRegistry) could write to forge a
      # registered_module() from these bytes instead.
    end

    test "an export-conforming module with an unresolved WASI import is rejected at stage 2" do
      bytes = fixture("req166_unresolved_import.wat")

      assert {:error, {:instantiation_failed, {:unresolved_import, namespace, function}}} =
               ModuleRegistry.register(bytes)

      assert namespace == "wasi_snapshot_preview1"
      assert function == "path_open"
    end

    test "stage-gating guard: a module with BOTH a missing export AND an unresolved import is reported only via the stage-1 :invalid_abi path, never :instantiation_failed" do
      # Mutation-guard test: a `register/1` whose `with` gate stopped hard-gating
      # stage 2 on stage 1's result (e.g. running `instantiate/2` unconditionally
      # instead of only inside the `with`'s success branch) would still often
      # LOOK correct on the single-defect fixtures elsewhere in this suite, because
      # a lone stage-2 failure or a lone stage-1 failure each still produces *a*
      # `{:error, _}` tuple either way. This fixture is the one case that actually
      # distinguishes the two: it fails BOTH stages, so a broken gate that ran
      # stage 2 anyway would surface the stage-2 {:instantiation_failed, ...}
      # result (or, depending on the mutant's shape, race/duplicate work) instead
      # of design §5.1's required stage-1-only {:invalid_abi, [{:missing, ...}]}.
      bytes = fixture("req166_missing_execute_and_unresolved_import.wat")

      assert {:error, {:invalid_abi, defects}} = ModuleRegistry.register(bytes)
      assert {:missing, "execute"} in defects
    end
  end

  # ---------------------------------------------------------------------
  # AC4: a conforming module registers successfully, and the proving Wasmex
  # instance is stopped (not leaked) before register/1 returns.
  # ---------------------------------------------------------------------

  describe "AC4: a conforming module registers successfully with no leaked instance" do
    test "returns {:ok, registered_module()}" do
      assert {:ok, _registered} = ModuleRegistry.register(fixture("req166_conforming.wat"))
    end

    test "the proving Wasmex instance started during stage 2 is stopped before register/1 returns" do
      before_pids = wasmex_pids()

      assert {:ok, _registered} = ModuleRegistry.register(fixture("req166_conforming.wat"))

      leaked = wasmex_pids() -- before_pids

      assert leaked == [],
             "expected no leaked Wasmex GenServer after a successful registration, got: #{inspect(leaked)}"
    end
  end

  # ---------------------------------------------------------------------
  # Additional (not a numbered AC, but the single most important test given
  # the whole design's rework): register/1 on an unresolved-import module
  # must NOT crash the calling test process. This directly proves the
  # Task.Supervisor.async_nolink/2 wrapping (design §1.5/§2.2) actually
  # works -- an inline Wasmex.start_link/1 call on this same fixture would
  # deliver a linked :EXIT signal and kill this very test process.
  # ---------------------------------------------------------------------

  describe "the crash-propagation hazard design §1.5 identified is contained" do
    test "register/1 on an unresolved-import module does not crash the calling process" do
      test_pid = self()
      bytes = fixture("req166_unresolved_import.wat")

      # AC5 (handoff step-03): this test's whole point is that
      # Task.Supervisor.async_nolink/2 contains a crash that WOULD otherwise
      # propagate via a linked :EXIT signal. That containment claim is only
      # meaningful if this test process is a plain, non-trapping caller at
      # the point of the call -- an ordinary `register/1` caller in
      # production is not trap_exit, and if ExUnit (or a prior test in this
      # file) had left this process with trap_exit set to true, an inline
      # (non-nolink) crash would ALSO be survived, silently passing this test
      # for the wrong reason and telling us nothing about async_nolink/2
      # actually doing its job. Confirm the real precondition before relying
      # on Process.alive?/1 below to mean anything.
      assert Process.info(test_pid, :trap_exit) == {:trap_exit, false}

      assert {:error, {:instantiation_failed, {:unresolved_import, _, _}}} =
               ModuleRegistry.register(bytes)

      assert Process.alive?(test_pid)
      # If register/1 called Wasmex.start_link/1 inline instead of inside a
      # Task.Supervisor.async_nolink/2 task, this whole test process (linked
      # to the crashing instance during init/1) would have exited before
      # reaching this line at all -- there would be no assertion failure to
      # report, the test run itself would abort.
    end
  end

  # ---------------------------------------------------------------------
  # AC4 (handoff step-03): instantiate/2's timeout branch
  # (`Task.shutdown(task, :brutal_kill)` on a `Task.yield/2` timeout) had no
  # existing coverage at all. instantiate/2 is a private function -- it
  # cannot be called directly from a test -- so the only way to exercise
  # this branch through the public API is a `register/1` call whose
  # instantiation attempt genuinely exceeds @instantiation_timeout_ms
  # (5_000ms, a private module attribute, not injectable from a test).
  #
  # That WAS reliably achieved live during this pass (not merely attempted):
  # a WAT fixture whose module has a `(start $spin)` function containing an
  # unconditional infinite loop was compiled and passed through the real
  # `register/1`. It genuinely blocked in `Wasmex.start_link/1` (confirmed
  # separately not to return even after 3s via a raw `Task.yield/2` probe)
  # and `register/1` correctly returned
  # `{:error, {:instantiation_failed, {:timeout, 5000}}}` after ~5043ms /
  # ~5061ms across two live runs -- so the timeout branch itself, and its
  # return value, ARE real and reachable, and were directly observed, not
  # inferred.
  #
  # It is NOT used as a committed automated test, for a reason discovered
  # during this same verification, not a hypothetical one: killing the Task
  # (`Task.shutdown(task, :brutal_kill)`, the correct code's own call) removes
  # the Elixir-side bookkeeping -- `Task.Supervisor.children/1` on
  # `Letflow.Engine.Wasm.ModuleRegistryTaskSupervisor` does drop back to `[]`
  # -- but the underlying native Wasmtime execution thread the NIF call
  # started keeps spinning. Measured directly: reading
  # `/proc/<beam_pid>/stat` fields 14/15 (utime/stime) immediately after
  # `register/1` returned and again after a 3-second `Process.sleep/1` with
  # nothing else running showed ~305 additional clock ticks of CPU consumed
  # during that "idle" window -- i.e. a real OS thread was still busy-looping
  # at full tilt, invisibly, after the Erlang-level cleanup this test would
  # otherwise be asserting "worked". Committing that fixture as a live
  # `mix test` case would leave a permanently CPU-spinning orphaned thread
  # for the remainder of that `mix test` BEAM process's life on every run
  # that reaches it -- a resource leak the test itself would cause, not
  # verify the absence of. This is reported to ORCH as a candidate issue
  # (REQ-166's `Task.shutdown(:brutal_kill)` does not, and by the nature of
  # a non-preemptible dirty-NIF busy loop without engine epoch interruption
  # arguably cannot, reclaim the native thread on this exact pathological
  # input) rather than fixed here -- fixing it would mean editing
  # module_registry.ex, out of TEST-DESIGNER's scope for this handoff.
  #
  # Per the handoff's own instruction to use a proxy and document the
  # limitation explicitly rather than silently skip it: the test below
  # exercises the identical `Task.Supervisor.async_nolink/2` +
  # `Task.yield/2` timeout + `Task.shutdown(task, :brutal_kill)` pattern
  # against the SAME named, running `ModuleRegistryTaskSupervisor`, with an
  # ordinary hanging BEAM process (`Process.sleep(:infinity)`, safely
  # killable, no native thread involved) standing in for the hung
  # `Wasmex.start_link/1`. It proves the shutdown call's mechanism is real
  # and does terminate an orphaned task/process of the general shape
  # instantiate/2 produces. What it does NOT prove -- stated plainly because
  # it is a real gap, not a formality -- is that `instantiate/2`'s own
  # `nil ->` branch specifically still contains that call: a mutant that
  # deleted `Task.shutdown(task, :brutal_kill)` from that exact branch
  # would NOT be caught by this proxy test, because the proxy never calls
  # through `instantiate/2` at all (it is private and unreachable from
  # outside the module). Confirmed by actually applying that mutation and
  # re-running this file: `mix test` still reported this proxy test (and
  # all 19 others) passing -- 20/20 green with the mutant in place. The
  # only mutation-sensitive evidence available for that exact line, with the
  # constraints above, is the live end-to-end verification recorded above,
  # not an automated regression test.
  # ---------------------------------------------------------------------

  describe "AC4 timeout-branch proxy: Task.shutdown(:brutal_kill) genuinely terminates an orphaned task" do
    test "a task that hangs past Task.yield/2's timeout is alive until shutdown, then dead" do
      task =
        Task.Supervisor.async_nolink(Letflow.Engine.Wasm.ModuleRegistryTaskSupervisor, fn ->
          Process.sleep(:infinity)
        end)

      assert Task.yield(task, 50) == nil, "expected the hanging task to still be running"

      assert Process.alive?(task.pid),
             "expected the orphaned task process to be alive pre-shutdown"

      # This is exactly instantiate/2's `nil ->` branch's own call.
      Task.shutdown(task, :brutal_kill)

      refute Process.alive?(task.pid),
             "expected Task.shutdown(task, :brutal_kill) to have terminated the orphaned task " <>
               "process -- a mutant that skipped or softened this call (a no-op, or a " <>
               "non-brutal Task.shutdown(task, :normal)) would leave it running"
    end
  end

  # ---------------------------------------------------------------------
  # AC5 (moduledoc): names the export contract and cites req163.
  # ---------------------------------------------------------------------

  describe "moduledoc content" do
    test "AC5: names the export contract and cites req163-wasm-abi-choice.md's sections" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(ModuleRegistry)

      assert moduledoc =~ "req163-wasm-abi-choice.md"
      assert moduledoc =~ "§3.1"
      assert moduledoc =~ "§3.2"
      assert moduledoc =~ "§4"
      assert moduledoc =~ "init"
      assert moduledoc =~ "execute"
      assert moduledoc =~ "deinit"
      assert moduledoc =~ "get_capabilities"
      assert moduledoc =~ "alloc"
      assert moduledoc =~ "memory"
      assert moduledoc =~ "two-stage"
      assert moduledoc =~ "Components"
    end
  end

  # ---------------------------------------------------------------------
  # Handoff step-03 AC6: register/1 has a `when is_binary(bytes)` guard
  # (module_registry.ex:160) -- no existing test in this suite ever calls
  # register/1 with a non-binary argument, so nothing here previously proved
  # that guard is reached rather than, say, some other code path crashing
  # first or silently coercing the input.
  # ---------------------------------------------------------------------

  describe "register/1 rejects non-binary input via its documented FunctionClauseError guard" do
    test "nil raises FunctionClauseError" do
      assert_raise FunctionClauseError, fn ->
        apply(ModuleRegistry, :register, [nil])
      end
    end

    test "an integer raises FunctionClauseError" do
      assert_raise FunctionClauseError, fn ->
        apply(ModuleRegistry, :register, [42])
      end
    end
  end

  # ---------------------------------------------------------------------
  # AC6 sanity: a plain syntactically-invalid module is rejected at stage 1's
  # compile step, before any export check.
  # ---------------------------------------------------------------------

  describe "a syntactically-invalid module is rejected at compile" do
    test "returns {:error, {:compile_error, reason}}" do
      assert {:error, {:compile_error, reason}} = ModuleRegistry.register("not valid wasm")
      assert is_binary(reason)
    end
  end
end
