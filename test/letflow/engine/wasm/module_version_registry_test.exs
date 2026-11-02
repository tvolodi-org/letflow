defmodule Letflow.Engine.Wasm.ModuleVersionRegistryTest do
  @moduledoc """
  REQ-173 (WASM-14) -- coverage for `Letflow.Engine.Wasm.ModuleVersionRegistry`.
  See `lib/letflow/design/req173-wasm-module-hot-reload.md` (gate-approved,
  reworked at commit 721930a) and `test/specs/REQ-173.md` for the full
  design/spec this suite exercises.

  **Note (ELIXIR-DEV, WF02-REQ173-20260828 step-02a fix2):** this file's
  first `describe` block originally reproduced and documented a real defect
  (`register_version/3` could never register ANY module declaring a host
  import, regardless of manifest, because `ModuleRegistry.register/1`'s
  stage-2 proof always instantiates with NO import table at all). The design
  was reworked (§5.3) to add a second, capability-aware proving path inside
  `register_version/3` itself, entered only when `register/1`'s own
  zero-import stage 2 is the specific thing that fails -- so a
  capability-requiring module now registers successfully when its manifest
  grants what it needs. That fix makes the original assertions below
  (`{:error, {:instantiation_failed, ...}}` for `req173_v1_gated.wat`/
  `req173_v2_gated.wat`) factually wrong now that the defect they documented
  is fixed, so they are updated here (by ELIXIR-DEV, not TEST-DESIGNER) to
  assert the now-correct `{:ok, _version_id}` outcome -- this is exactly the
  "fix's return shape genuinely differs from what TEST-DESIGNER guessed"
  case the handoff calls out (TEST-DESIGNER wrote these against the
  pre-rework design, before commit 721930a existed), not a re-litigation of
  TEST-DESIGNER's own judgment. The `describe "SS8.4: the one overlapping
  scenario ..."` block, and every other block below, were already written
  correctly against the target (post-fix) behavior and needed no changes;
  they exercise WASM-14/AC1-AC5 in full, including the previously-blocked
  overlapping-activation scenario, which now passes.

  `async: false`: builds real Wasmtime instances via `wasmex`'s NIF (mirrors
  every other WASM-NIF test file in this suite), AND drives the single,
  supervised `ModuleVersionRegistry` GenServer singleton shared by the whole
  test run -- every test uses a fresh, unique `module_name` (via
  `unique_module_name/1`) so no test can observe another test's state.
  """

  use ExUnit.Case, async: false
  @moduletag :unit

  alias Letflow.Engine.Wasm.CapabilityGate
  alias Letflow.Engine.Wasm.HostApi
  alias Letflow.Engine.Wasm.ModuleVersionRegistry
  alias Letflow.Test.Req173BlockingServiceCaller

  @v1_manifest %{capabilities: ["service:call"]}
  @v2_manifest %{capabilities: ["var:write"]}
  @capless_manifest %{capabilities: []}

  defp fixture_bytes(name) do
    Application.app_dir(:letflow, "priv")
    |> Path.join("wasm_fixtures/#{name}")
    |> File.read!()
  end

  # Fresh module_name per test -- this GenServer is a single, long-lived
  # singleton shared by the whole test run (never reset between tests), per
  # design SS2's "registry_state()" being a straightforward, permanent map --
  # so cross-test isolation depends entirely on using a unique key per test,
  # exactly as TEST-DESIGN-VALIDATOR's own checklist requires.
  defp unique_module_name(tag) do
    "req173-#{tag}-#{System.unique_integer([:positive, :monotonic])}"
  end

  # ---------------------------------------------------------------------
  # Fixed defect (design §5.3): register_version/3 now successfully
  # registers a module declaring a host import, PROVIDED its manifest
  # grants the capability that import needs -- via its own capability-aware
  # proof, entered only when register/1's zero-import stage 2 fails.
  # ---------------------------------------------------------------------

  describe "register_version/3's capability-aware proof (design §5.3) registers a module requiring a host capability" do
    test "req173_v1_gated.wat (imports platform_call_service) registers successfully when the manifest grants \"service:call\"" do
      module_name = unique_module_name("gated-v1")

      assert {:ok, _version_id} =
               ModuleVersionRegistry.register_version(
                 module_name,
                 fixture_bytes("req173_v1_gated.wat"),
                 @v1_manifest
               )
    end

    test "req173_v2_gated.wat (imports write_variable) registers successfully when the manifest grants \"var:write\"" do
      module_name = unique_module_name("gated-v2")

      assert {:ok, _version_id} =
               ModuleVersionRegistry.register_version(
                 module_name,
                 fixture_bytes("req173_v2_gated.wat"),
                 @v2_manifest
               )
    end

    test "the same v1 bytes also register successfully when the module declares zero imports (req173_v1_capless.wat), confirming both registration paths (step 1's zero-import success, step 2's capability-aware proof) reach the same outcome" do
      module_name = unique_module_name("capless-control")

      assert {:ok, _version_id} =
               ModuleVersionRegistry.register_version(
                 module_name,
                 fixture_bytes("req173_v1_capless.wat"),
                 @capless_manifest
               )
    end
  end

  # ---------------------------------------------------------------------
  # design SS8.4 -- the ONE overlapping scenario, written exactly per the
  # design's own prescribed mechanism. Expected (and, at time of writing,
  # confirmed) to fail at step 1 for the reason documented above and in
  # test/specs/REQ-173.md -- kept because it correctly encodes WASM-14/AC5
  # and needs no edit once the blocking finding above is fixed.
  # ---------------------------------------------------------------------

  describe "design SS8.4: the one overlapping scenario (held invocation completes against OLD version, concurrent invocation observes NEW version, capability isolation both directions)" do
    setup do
      {:ok, _gate} = Req173BlockingServiceCaller.start_gate()
      previous = Req173BlockingServiceCaller.arm()
      on_exit(fn -> Req173BlockingServiceCaller.restore(previous) end)
      :ok
    end

    test "AC1+AC2+AC3+AC4+AC5 in one overlapping scenario" do
      module_name = unique_module_name("overlap")

      # Step 1
      assert {:ok, v1_id} =
               ModuleVersionRegistry.register_version(
                 module_name,
                 fixture_bytes("req173_v1_gated.wat"),
                 @v1_manifest
               )

      assert :ok = ModuleVersionRegistry.activate(module_name, v1_id)

      # Step 3 -- invocation A, asynchronous: this call will not return until
      # the gate is released.
      task_a =
        Task.async(fn ->
          ModuleVersionRegistry.invoke(
            module_name,
            "run",
            [],
            HostApi.empty_execution_context(),
            5_000
          )
        end)

      # Step 4 -- synchronous wait on the gate, never a sleep.
      assert :ok = Req173BlockingServiceCaller.await_parked(5_000)

      # Step 5
      assert ModuleVersionRegistry.version_status(module_name, v1_id) == :active

      # Step 6
      assert {:ok, v2_id} =
               ModuleVersionRegistry.register_version(
                 module_name,
                 fixture_bytes("req173_v2_gated.wat"),
                 @v2_manifest
               )

      assert :ok = ModuleVersionRegistry.activate(module_name, v2_id)

      # Step 7
      assert ModuleVersionRegistry.current_version(module_name) == {:ok, v2_id}

      # Step 8 -- AC4 (release timing): superseded, NOT released, while A is
      # still parked.
      assert ModuleVersionRegistry.version_status(module_name, v1_id) == :superseded

      # Step 9 -- AC2: a new invocation started AFTER activation observes the
      # NEW version, and (per the disjoint manifests) only succeeds because it
      # was instantiated against v2_manifest's grant of "var:write".
      result_b =
        ModuleVersionRegistry.invoke(
          module_name,
          "run",
          [],
          HostApi.empty_execution_context(),
          5_000
        )

      assert {:ok, ^v2_id, [222]} = result_b

      # Step 10
      :ok = Req173BlockingServiceCaller.release()

      # Step 11 -- AC1: the held invocation completes against the OLD
      # version's behaviour, only reachable via v1_manifest's grant of
      # "service:call".
      result_a = Task.await(task_a, 5_000)
      assert {:ok, ^v1_id, [111]} = result_a

      # Step 12 -- AC4: release actually fires now, immediately after A's own
      # release call, with no further external action.
      assert ModuleVersionRegistry.version_status(module_name, v1_id) == :released

      # Step 13 -- AC3, explicit.
      assert result_a != result_b

      # Step 14 -- AC5 defense-in-depth: the manifests themselves are as
      # disjoint as claimed, independent of invoke/4's own code.
      table_v1 =
        CapabilityGate.build_import_table(@v1_manifest, HostApi.empty_execution_context())

      table_v2 =
        CapabilityGate.build_import_table(@v2_manifest, HostApi.empty_execution_context())

      assert Map.has_key?(table_v1["env"], "platform_call_service")
      refute Map.has_key?(table_v1["env"], "write_variable")
      assert Map.has_key?(table_v2["env"], "write_variable")
      refute Map.has_key?(table_v2["env"], "platform_call_service")
    end
  end

  # ---------------------------------------------------------------------
  # What IS testable without a held-open invocation: sequential version
  # switching, error-path contracts, idempotent activation, and the
  # "nothing to wait for" release trigger (design SS6 trigger point 2).
  # ---------------------------------------------------------------------

  describe "register_version/3 + activate/2 + current_version/1 + version_status/2 -- sequential (non-overlapping) mechanics" do
    test "a brand-new module has no current version until activate/2 is called" do
      module_name = unique_module_name("no-auto-activate")

      assert {:ok, v1_id} =
               ModuleVersionRegistry.register_version(
                 module_name,
                 fixture_bytes("req173_v1_capless.wat"),
                 @capless_manifest
               )

      assert ModuleVersionRegistry.current_version(module_name) ==
               {:error, {:no_active_version, module_name}}

      assert ModuleVersionRegistry.version_status(module_name, v1_id) == :superseded
    end

    test "activate/2 makes a version current, and a later invocation resolves to it, returning its own distinct literal" do
      module_name = unique_module_name("activate-then-invoke")

      {:ok, v1_id} =
        ModuleVersionRegistry.register_version(
          module_name,
          fixture_bytes("req173_v1_capless.wat"),
          @capless_manifest
        )

      :ok = ModuleVersionRegistry.activate(module_name, v1_id)

      assert ModuleVersionRegistry.current_version(module_name) == {:ok, v1_id}

      assert {:ok, ^v1_id, [111]} =
               ModuleVersionRegistry.invoke(
                 module_name,
                 "run",
                 [],
                 HostApi.empty_execution_context(),
                 5_000
               )
    end

    test "activating a second version supersedes the first; a new invocation observes the new version and its own distinct literal (AC2/AC3, non-overlapping case)" do
      module_name = unique_module_name("second-version")

      {:ok, v1_id} =
        ModuleVersionRegistry.register_version(
          module_name,
          fixture_bytes("req173_v1_capless.wat"),
          @capless_manifest
        )

      :ok = ModuleVersionRegistry.activate(module_name, v1_id)

      assert {:ok, ^v1_id, [111]} =
               ModuleVersionRegistry.invoke(
                 module_name,
                 "run",
                 [],
                 HostApi.empty_execution_context(),
                 5_000
               )

      {:ok, v2_id} =
        ModuleVersionRegistry.register_version(
          module_name,
          fixture_bytes("req173_v2_capless.wat"),
          @capless_manifest
        )

      :ok = ModuleVersionRegistry.activate(module_name, v2_id)

      assert ModuleVersionRegistry.current_version(module_name) == {:ok, v2_id}

      assert {:ok, ^v2_id, [222]} =
               ModuleVersionRegistry.invoke(
                 module_name,
                 "run",
                 [],
                 HostApi.empty_execution_context(),
                 5_000
               )
    end

    test "design SS6 trigger point 2: activating away from a version whose ref_count is already 0 releases it IMMEDIATELY, inside the same activate/2 call -- the \"nothing to wait for\" case" do
      module_name = unique_module_name("immediate-release")

      {:ok, v1_id} =
        ModuleVersionRegistry.register_version(
          module_name,
          fixture_bytes("req173_v1_capless.wat"),
          @capless_manifest
        )

      :ok = ModuleVersionRegistry.activate(module_name, v1_id)

      # No invocation was ever made against v1 -- ref_count is still 0.
      assert ModuleVersionRegistry.version_status(module_name, v1_id) == :active

      {:ok, v2_id} =
        ModuleVersionRegistry.register_version(
          module_name,
          fixture_bytes("req173_v2_capless.wat"),
          @capless_manifest
        )

      :ok = ModuleVersionRegistry.activate(module_name, v2_id)

      assert ModuleVersionRegistry.version_status(module_name, v1_id) == :released
    end

    test "a no-op activation (activating the already-current version) is idempotent and does not release it" do
      module_name = unique_module_name("noop-activate")

      {:ok, v1_id} =
        ModuleVersionRegistry.register_version(
          module_name,
          fixture_bytes("req173_v1_capless.wat"),
          @capless_manifest
        )

      :ok = ModuleVersionRegistry.activate(module_name, v1_id)
      :ok = ModuleVersionRegistry.activate(module_name, v1_id)

      assert ModuleVersionRegistry.current_version(module_name) == {:ok, v1_id}
      assert ModuleVersionRegistry.version_status(module_name, v1_id) == :active
    end

    test "current_version/1 for an unknown module_name" do
      module_name = unique_module_name("unknown")

      assert ModuleVersionRegistry.current_version(module_name) ==
               {:error, {:unknown_module, module_name}}
    end

    test "activate/2 for an unknown module_name" do
      module_name = unique_module_name("unknown-activate")

      assert ModuleVersionRegistry.activate(module_name, 1) ==
               {:error, {:unknown_module, module_name}}
    end

    test "activate/2 for a known module but an unregistered version_id" do
      module_name = unique_module_name("unknown-version")

      {:ok, v1_id} =
        ModuleVersionRegistry.register_version(
          module_name,
          fixture_bytes("req173_v1_capless.wat"),
          @capless_manifest
        )

      bogus_version_id = v1_id + 100

      assert ModuleVersionRegistry.activate(module_name, bogus_version_id) ==
               {:error, {:unknown_version, module_name, bogus_version_id}}
    end

    test "version_status/2 for an unknown module_name and unknown version_id" do
      module_name = unique_module_name("status-unknown")

      assert ModuleVersionRegistry.version_status(module_name, 1) ==
               {:unknown_module, module_name}

      {:ok, v1_id} =
        ModuleVersionRegistry.register_version(
          module_name,
          fixture_bytes("req173_v1_capless.wat"),
          @capless_manifest
        )

      assert ModuleVersionRegistry.version_status(module_name, v1_id + 100) ==
               {:unknown_version, module_name}
    end

    test "invoke/4 against a module with no active version" do
      module_name = unique_module_name("no-active")

      {:ok, _v1_id} =
        ModuleVersionRegistry.register_version(
          module_name,
          fixture_bytes("req173_v1_capless.wat"),
          @capless_manifest
        )

      assert ModuleVersionRegistry.invoke(
               module_name,
               "run",
               [],
               HostApi.empty_execution_context(),
               5_000
             ) == {:error, {:no_active_version, module_name}}
    end

    test "invoke/4 against a wholly unknown module_name" do
      module_name = unique_module_name("wholly-unknown")

      assert ModuleVersionRegistry.invoke(
               module_name,
               "run",
               [],
               HostApi.empty_execution_context(),
               5_000
             ) == {:error, {:unknown_module, module_name}}
    end
  end

  # ---------------------------------------------------------------------
  # AC5 (design SS8.4 step 14) -- the manifest-disjointness "defense in
  # depth" check needs no WASM execution at all, so it is unaffected by the
  # blocking finding above.
  # ---------------------------------------------------------------------

  describe "AC5 defense in depth: v1_manifest/v2_manifest are disjoint, independent of invoke/4's own code" do
    test "v1_manifest grants platform_call_service only" do
      table = CapabilityGate.build_import_table(@v1_manifest, HostApi.empty_execution_context())

      assert Map.has_key?(table["env"], "platform_call_service")
      refute Map.has_key?(table["env"], "write_variable")
    end

    test "v2_manifest grants write_variable only" do
      table = CapabilityGate.build_import_table(@v2_manifest, HostApi.empty_execution_context())

      assert Map.has_key?(table["env"], "write_variable")
      refute Map.has_key?(table["env"], "platform_call_service")
    end
  end

  # ---------------------------------------------------------------------
  # REQ-174 (WASM-13 restated) -- per-invocation isolation via invoke/4.
  # See lib/letflow/design/req174-wasm-instance-pooling-or-decline.md §4.2.
  # Pooling is DECLINED (no pooling module exists); this test proves the
  # isolation property that decision holds on -- INV-174-1 -- namely that
  # invocation N+1 of the SAME registered/activated module never observes
  # linear-memory state written by invocation N, because invoke/4's
  # checkout -> instantiate -> call -> release sequence allocates a brand
  # new Wasmex.Store (and therefore brand new zero-initialized linear
  # memory) for every single invocation -- it never reuses one across
  # calls. req174_memory_write.wat's write_marker/read_marker pair makes
  # this observable: write_marker stores byte 1 at offset 0 and returns 0;
  # read_marker reads offset 0 back without mutating it. If invoke/4 ever
  # started sharing a Store/instance across invocations (the exact defect
  # this requirement's decision record warns a hand-built pool could
  # introduce), read_marker at invocation N+1 would observe the byte 1
  # written by write_marker at invocation N -- see this file's mutation
  # verification note below for how that discriminating power was
  # confirmed rather than assumed.
  # ---------------------------------------------------------------------

  describe "REQ-174 INV-174-1: per-invocation isolation via ModuleVersionRegistry.invoke/4" do
    test "invocation N's write_marker is NOT observable in invocation N+1's read_marker, on the same registered/activated module" do
      module_name = unique_module_name("req174-isolation")

      assert {:ok, version_id} =
               ModuleVersionRegistry.register_version(
                 module_name,
                 fixture_bytes("req174_memory_write.wat"),
                 @capless_manifest
               )

      assert :ok = ModuleVersionRegistry.activate(module_name, version_id)

      # Invocation N: writes byte 1 at offset 0 of THIS invocation's own
      # fresh linear memory, and returns 0 (its own, unrelated return
      # value -- proof it ran, not a read of the marker).
      assert {:ok, ^version_id, [0]} =
               ModuleVersionRegistry.invoke(
                 module_name,
                 "write_marker",
                 [],
                 HostApi.empty_execution_context(),
                 5_000
               )

      # Invocation N+1: reads offset 0 of a DIFFERENT invocation's linear
      # memory. If it were the same Store invocation N wrote to, this
      # would read back [1]. It must read [0] -- zero-initialized memory
      # that invocation N's write never touched, because invoke/4 never
      # shares a Store between invocations (design SS1.2/SS3, INV-174-1).
      assert {:ok, ^version_id, [0]} =
               ModuleVersionRegistry.invoke(
                 module_name,
                 "read_marker",
                 [],
                 HostApi.empty_execution_context(),
                 5_000
               )
    end
  end
end
