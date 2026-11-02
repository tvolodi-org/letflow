defmodule Letflow.Engine.Wasm.CapabilityGateTest do
  @moduledoc """
  REQ-167 -- coverage for `Letflow.Engine.Wasm.CapabilityGate`. See
  `lib/letflow/design/req167-wasm-import-whitelist.md` (gate-approved) and
  `test/specs/REQ-167.md` for the full design/spec this suite exercises.

  `async: false`: several tests here build a real Wasmtime instance via
  `wasmex`'s NIF (`start_instance/2`'s instantiation attempt), including
  unresolved-import cases that deliberately reproduce the crash-propagation
  hazard the design documents. Keeping the file serial avoids any risk of
  overlapping native-NIF activity across `async: true` test processes,
  mirroring `module_registry_test.exs`'s own rationale.
  """

  use ExUnit.Case, async: false
  @moduletag :unit

  alias Letflow.Engine.Wasm.CapabilityGate

  defp fixture(name) do
    Application.app_dir(:letflow, "priv")
    |> Path.join("wasm_fixtures/#{name}")
    |> File.read!()
  end

  # ---------------------------------------------------------------------
  # AC1: a module declaring only var:read and importing platform_call_service
  # FAILS TO INSTANTIATE, with a structured error -- and the calling process
  # is never crashed.
  # ---------------------------------------------------------------------

  describe "AC1: a module granted only var:read cannot import platform_call_service" do
    test "returns a structured {:error, {:instantiation_denied, {:unresolved_import, ...}}}" do
      manifest = %{capabilities: ["var:read"]}
      bytes = fixture("req167_platform_call_only.wat")

      assert {:error,
              {:instantiation_denied, {:unresolved_import, "env", "platform_call_service"}}} =
               CapabilityGate.start_instance(bytes, manifest)
    end

    test "does not crash the calling test process (crash-propagation containment)" do
      test_pid = self()
      manifest = %{capabilities: ["var:read"]}
      bytes = fixture("req167_platform_call_only.wat")

      # Mirrors module_registry_test.exs's identical precondition check --
      # this containment claim is only meaningful against a plain,
      # non-trapping caller, matching an ordinary production caller shape.
      assert Process.info(test_pid, :trap_exit) == {:trap_exit, false}

      assert {:error, {:instantiation_denied, {:unresolved_import, _, _}}} =
               CapabilityGate.start_instance(bytes, manifest)

      assert Process.alive?(test_pid)
      # If start_instance/2 called Wasmex.start_link/1 inline instead of
      # inside a Task.Supervisor.async_nolink/2 task under
      # CapabilityGateTaskSupervisor, this test process (linked to the
      # crashing instance during init/1) would have exited before reaching
      # this line -- there would be no assertion failure to report at all.
      refute_received {:EXIT, _, _}
    end

    test "granting service:call as well allows the same module to instantiate cleanly" do
      manifest = %{capabilities: ["var:read", "service:call"]}
      bytes = fixture("req167_platform_call_only.wat")

      assert {:ok, pid} = CapabilityGate.start_instance(bytes, manifest)
      assert is_pid(pid)
      GenServer.stop(pid)
    end

    # Mutation-tested (WF-02 Step 3, REQ-167): mutating the success branch to
    # call GenServer.stop/1 on the pid before returning it (accidentally
    # adopting ModuleRegistry's stage-2-proving-instance pattern, which this
    # module's moduledoc explicitly says it does NOT follow -- see "On
    # success" above) was NOT caught by any pre-existing assertion shape --
    # every other test that gets a pid back happens to call GenServer.stop/1
    # itself afterward, which only fails incidentally (a confusing
    # already-stopped exit, not a clear assertion) rather than actually
    # verifying the returned instance is usable. This test asserts the real
    # property directly.
    test "the returned pid is alive and usable immediately after a successful call" do
      manifest = %{capabilities: ["var:read", "service:call"]}
      bytes = fixture("req167_platform_call_only.wat")

      assert {:ok, pid} = CapabilityGate.start_instance(bytes, manifest)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------------
  # AC2: build_import_table/1 is a genuine whitelist, asserted by inspecting
  # the built map directly -- never by invoking and catching an error.
  # ---------------------------------------------------------------------

  describe "AC2: build_import_table/1 builds a genuine whitelist from the manifest" do
    test "an ungranted host function is absent as a key; a granted one is present" do
      table = CapabilityGate.build_import_table(%{capabilities: ["var:read"]})

      refute Map.has_key?(Map.get(table, "env", %{}), "platform_call_service")
      assert Map.has_key?(Map.get(table, "env", %{}), "read_variable")
    end

    test "symmetric case: granting service:call only exposes platform_call_service" do
      table = CapabilityGate.build_import_table(%{capabilities: ["service:call"]})

      assert Map.has_key?(Map.get(table, "env", %{}), "platform_call_service")
      refute Map.has_key?(Map.get(table, "env", %{}), "read_variable")
    end

    test "an empty capability list produces a table with neither known import present" do
      table = CapabilityGate.build_import_table(%{capabilities: []})

      refute Map.has_key?(Map.get(table, "env", %{}), "read_variable")
      refute Map.has_key?(Map.get(table, "env", %{}), "platform_call_service")
    end

    # Mutation-tested (WF-02 Step 3, REQ-167): seeding the Enum.reduce/3
    # accumulator with %{"env" => %{}} instead of %{} produces a table that
    # still passes every `refute Map.has_key?(Map.get(table, "env", %{}),
    # ...)` assertion above (an absent key is still absent from a
    # namespace-present-but-empty map) -- none of them distinguish "no env
    # namespace at all" from "an empty env namespace." This test asserts the
    # exact top-level shape design §5.1 step 3 calls for: a genuinely empty
    # manifest produces exactly the :none-gated rows and nothing else -- not
    # a partially-empty nested map.
    #
    # REQ-171 design §4.1 changed this exact assertion's expected value: an
    # empty manifest is no longer `%{}` because `now`/`uuid` are `:none`-gated
    # (always installed, regardless of grant state, mirroring platform.ex's
    # own `now`/`fail` rows) -- this is the intended, documented behavior
    # change, not a regression. REQ-172 design §5.4 widens the `:none`-gated
    # set again, adding `fail` (mirroring platform.ex's own `fail` row, also
    # `:none`-gated) -- same intended, documented behavior change.
    test "an empty capability list produces exactly the :none-gated rows, nothing else" do
      table = CapabilityGate.build_import_table(%{capabilities: []})

      assert MapSet.new(Map.keys(table["env"])) == MapSet.new(["now", "uuid", "fail"])
    end

    test "granting both capabilities exposes both imports (additive, not exclusive)" do
      table = CapabilityGate.build_import_table(%{capabilities: ["var:read", "service:call"]})

      assert Map.has_key?(Map.get(table, "env", %{}), "read_variable")
      assert Map.has_key?(Map.get(table, "env", %{}), "platform_call_service")
    end

    test "the returned entry has the exact {:fn, params, results, callback} shape wasmex requires" do
      # REQ-171 design §4.4: read_variable's real signature is the 4-param
      # buffer-out shape (name_ptr, name_len, out_ptr, out_cap), widened from
      # REQ-167's original illustrative 2-param placeholder -- a callback of
      # arity 5 (context + 4 params), not 3.
      table = CapabilityGate.build_import_table(%{capabilities: ["var:read"]})

      assert {:fn, [:i32, :i32, :i32, :i32], [:i32], callback} = table["env"]["read_variable"]
      assert is_function(callback, 5)
    end

    test "REQ-171: :none-gated rows (now/uuid) are present even with an empty manifest" do
      table = CapabilityGate.build_import_table(%{capabilities: []})

      assert Map.has_key?(Map.get(table, "env", %{}), "now")
      assert Map.has_key?(Map.get(table, "env", %{}), "uuid")
    end
  end

  # ---------------------------------------------------------------------
  # AC3: a module attempting the req163-named filesystem surface is rejected
  # under ANY manifest, since no manifest content can grant it.
  # ---------------------------------------------------------------------

  describe "AC3: the req163-named filesystem surface is rejected under any manifest" do
    test "rejected when nothing is granted" do
      bytes = fixture("req167_path_open.wat")

      assert {:error,
              {:instantiation_denied, {:unresolved_import, "wasi_snapshot_preview1", "path_open"}}} =
               CapabilityGate.start_instance(bytes, %{capabilities: []})
    end

    test "rejected even when every capability this registry defines is granted" do
      bytes = fixture("req167_path_open.wat")

      assert {:error,
              {:instantiation_denied, {:unresolved_import, "wasi_snapshot_preview1", "path_open"}}} =
               CapabilityGate.start_instance(bytes, %{capabilities: ["var:read", "service:call"]})
    end

    # Deliberately never asserts against the literal "wasi:filesystem/types"
    # string (WASM-07's own unreplaced acceptance text) -- see this module's
    # moduledoc, AC4: that string is a WASI Preview 2 component-model
    # interface identifier with no meaning under core-module linking, and
    # asserting rejection of it would be a false pass. A future reader must
    # not "fix" this suite to use that literal name.
  end

  # ---------------------------------------------------------------------
  # T5: the whitelist is provably exhaustive -- an import the registry has
  # never heard of at all is denied regardless of manifest.
  # ---------------------------------------------------------------------

  describe "the whitelist is exhaustive, not a by-name special case" do
    test "an entirely unregistered import name is denied under the maximally-permissive manifest" do
      bytes = fixture("req167_unregistered_import.wat")

      assert {:error,
              {:instantiation_denied,
               {:unresolved_import, "env", "totally_unregistered_function"}}} =
               CapabilityGate.start_instance(bytes, %{capabilities: ["var:read", "service:call"]})
    end
  end

  # ---------------------------------------------------------------------
  # A module with no imports at all instantiates cleanly regardless of what
  # is granted (an unused whitelist entry is inert).
  # ---------------------------------------------------------------------

  describe "a module with no imports instantiates cleanly under any manifest" do
    test "with an empty manifest" do
      assert {:ok, pid} =
               CapabilityGate.start_instance(fixture("req167_no_imports.wat"), %{capabilities: []})

      GenServer.stop(pid)
    end

    test "with a fully-granted manifest (unused entries are inert)" do
      manifest = %{capabilities: ["var:read", "service:call"]}

      assert {:ok, pid} =
               CapabilityGate.start_instance(fixture("req167_no_imports.wat"), manifest)

      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------------
  # AC4/AC5/AC6: moduledoc content.
  # ---------------------------------------------------------------------

  describe "moduledoc content restates WASM-07 per design §7" do
    test "AC4: states wasi:filesystem/types is not the tested surface, names what is, and why" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(CapabilityGate)

      assert moduledoc =~ "wasi:filesystem/types"
      assert moduledoc =~ "NOT the surface tested" or moduledoc =~ "not the surface tested"
      assert moduledoc =~ "wasi_snapshot_preview1"
      assert moduledoc =~ "path_open"
      assert moduledoc =~ "false pass"
      assert moduledoc =~ "component-model"
    end

    test "AC5: states this module restates WASM-07" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(CapabilityGate)

      assert moduledoc =~ "restates WASM-07"
      assert moduledoc =~ "req163-wasm-abi-choice.md"
    end

    test "AC6: states plainly that no explicit filesystem-grant path exists today" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(CapabilityGate)

      assert moduledoc =~ "no explicit filesystem-grant path exists today" or
               moduledoc =~ "no code path today" or
               moduledoc =~ "not implemented"
    end
  end
end
