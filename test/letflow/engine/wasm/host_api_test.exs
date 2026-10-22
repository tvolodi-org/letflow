defmodule Letflow.Engine.Wasm.HostApiTest do
  @moduledoc """
  REQ-171 (WASM-12 read half) -- coverage for `Letflow.Engine.Wasm.HostApi` and the
  `Letflow.Engine.Wasm.CapabilityGate` extension it introduces. See
  `lib/letflow/design/req171-wasm-host-api-read.md` (gate-approved) and
  `test/specs/REQ-171.md` for the full design/spec this suite exercises.

  **Parity mechanism (AC1, AC4):** `read_variable`/`log`/`now` are each driven twice
  from the same fixed inputs -- once through `Letflow.Engine.Lua.Sandbox.new/0` +
  `Letflow.Engine.Lua.Platform.install/3` + `Lua.eval!/2` (the Lua side, REQ-159/152),
  once through `CapabilityGate.build_import_table/2` + `req171_host_api.wat` +
  `Wasmex.call_function/4` (the WASM side) -- and the two decoded observable outcomes
  are asserted equal.

  `async: false`: builds real Wasmtime instances via `wasmex`'s NIF, mirroring every
  other WASM-NIF test file in this suite (`capability_gate_test.exs`,
  `memory_guard_test.exs`).
  """

  use ExUnit.Case, async: false

  alias Letflow.Engine.Lua.Capabilities
  alias Letflow.Engine.Lua.Platform
  alias Letflow.Engine.Lua.Sandbox
  alias Letflow.Engine.Wasm.CapabilityGate
  alias Letflow.Engine.Wasm.HostApi

  defmodule FixedTimeSource do
    @moduledoc false
    @behaviour Platform.TimeSource

    @impl Platform.TimeSource
    def now, do: ~U[2026-02-03 04:05:06.000000Z]
  end

  # `req171_host_api.wat` imports all four of read_variable/log/now/uuid
  # unconditionally -- wasmtime requires every DECLARED import to resolve at
  # instantiation time regardless of whether the guest ever calls it (REQ-167's
  # own architecture), so any test using this fixture must grant both
  # "var:read" and "audit:log" even if the scenario under test only exercises
  # now/uuid. `req171_now_uuid_only.wat` imports only now/uuid, specifically so
  # AC7's "an empty manifest still yields working now/uuid" claim can be
  # exercised under a genuinely empty manifest.
  defp fixture_bytes(name) do
    Application.app_dir(:letflow, "priv")
    |> Path.join("wasm_fixtures/#{name}")
    |> File.read!()
  end

  defp wasm_execution_context(overrides \\ %{}) do
    Map.merge(HostApi.empty_execution_context(), overrides)
  end

  defp lua_execution_context(overrides \\ %{}) do
    Map.merge(Platform.empty_execution_context(), overrides)
  end

  # Full manifest granting every capability `req171_host_api.wat` needs to
  # instantiate at all, merged with any scenario-specific capabilities.
  defp full_manifest(extra_capabilities \\ []) do
    %{capabilities: Enum.uniq(["var:read", "audit:log"] ++ extra_capabilities)}
  end

  defp start_instance(manifest, execution_context, fixture \\ "req171_host_api.wat") do
    table = CapabilityGate.build_import_table(manifest, execution_context)
    {:ok, pid} = Wasmex.start_link(%{bytes: fixture_bytes(fixture), imports: table})
    {:ok, store} = Wasmex.store(pid)
    {:ok, memory} = Wasmex.memory(pid)
    {pid, store, memory}
  end

  # Test-driver-only memory access -- these are NOT host functions, they run in the
  # test's own process (never inside a wasmex callback), so no re-entrancy hazard
  # applies and MemoryGuard's INV-HOSTAPI-3 (host-function-only invariant) does not
  # govern this file. Mirrors memory_guard_test.exs's identical pattern.
  defp write_bytes(store, memory, offset, data),
    do: Wasmex.Memory.write_binary(store, memory, offset, data)

  defp read_bytes(store, memory, offset, len),
    do: Wasmex.Memory.read_binary(store, memory, offset, len)

  @out_ptr 8192
  @out_cap 4096

  defp call_string_fn(pid, function_name, args, store, memory) do
    {:ok, [n]} = Wasmex.call_function(pid, function_name, args ++ [@out_ptr, @out_cap])

    if n >= 0 do
      {:ok, n, read_bytes(store, memory, @out_ptr, n)}
    else
      {:error, n}
    end
  end

  # ---------------------------------------------------------------------
  # AC1/AC2: read_variable -- parity with Lua, set/unset outcomes.
  # ---------------------------------------------------------------------

  describe "AC1/AC2: read_variable" do
    test "a set string variable: WASM returns the JSON-encoded value, matching Lua's decoded value" do
      variables = %{"greeting" => "hello"}

      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["variable:read"]),
          lua_execution_context(%{variables: variables})
        )

      {[lua_result], _lua} = Lua.eval!(lua, "return platform.read_variable('greeting')")

      manifest = full_manifest()

      {pid, store, memory} =
        start_instance(manifest, wasm_execution_context(%{variables: variables}))

      :ok = write_bytes(store, memory, 0, "greeting")
      name_ptr = 0

      {:ok, n, bytes} =
        call_string_fn(
          pid,
          "call_read_variable",
          [name_ptr, byte_size("greeting")],
          store,
          memory
        )

      assert n == byte_size(bytes)
      assert Jason.decode!(bytes) == lua_result
      assert lua_result == "hello"

      GenServer.stop(pid)
    end

    test "an unset variable: WASM returns -1 (not-present sentinel), Lua returns nil -- same semantic outcome, different ABI shape" do
      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["variable:read"]),
          lua_execution_context()
        )

      {[lua_result], _lua} = Lua.eval!(lua, "return platform.read_variable('missing')")
      assert lua_result == nil

      manifest = full_manifest()
      {pid, store, memory} = start_instance(manifest, wasm_execution_context())
      write_bytes(store, memory, 0, "missing")

      assert {:ok, [-1]} =
               Wasmex.call_function(pid, "call_read_variable", [
                 0,
                 byte_size("missing"),
                 @out_ptr,
                 @out_cap
               ])

      GenServer.stop(pid)
    end
  end

  # GH #2646 (#2587 PR B3, INV-2): engine-written `_sys.*` bookkeeping is never readable by a
  # guest; `host_api.ex` drops reserved keys before the lookup. A plain key is unchanged.
  describe "GH #2616 part 2: read_variable hides a labelled variable the caller may not read" do
    @salary_label "customer.salary"

    test "a hidden labelled variable reads as not present (-1); an unlabelled one is returned" do
      ctx =
        wasm_execution_context(%{
          variables: %{"x" => 1, "w" => "open"},
          variable_labels: %{"x" => [@salary_label]},
          hidden_labels: MapSet.new([@salary_label])
        })

      {pid, store, memory} = start_instance(full_manifest(), ctx)

      write_bytes(store, memory, 0, "x")

      assert {:ok, [-1]} =
               Wasmex.call_function(pid, "call_read_variable", [0, 1, @out_ptr, @out_cap])

      write_bytes(store, memory, 0, "w")

      {:ok, _n, bytes} = call_string_fn(pid, "call_read_variable", [0, 1], store, memory)
      assert Jason.decode!(bytes) == "open"

      GenServer.stop(pid)
    end

    test "a missing hidden set (nil) hides every labelled variable (fail closed)" do
      ctx =
        wasm_execution_context(%{
          variables: %{"x" => 1},
          variable_labels: %{"x" => [@salary_label]},
          hidden_labels: nil
        })

      {pid, store, memory} = start_instance(full_manifest(), ctx)

      write_bytes(store, memory, 0, "x")

      assert {:ok, [-1]} =
               Wasmex.call_function(pid, "call_read_variable", [0, 1, @out_ptr, @out_cap])

      GenServer.stop(pid)
    end
  end

  describe "GH #2646: read_variable never exposes reserved `_sys.*` keys" do
    test "a `_sys.*` variable reads as absent (-1); a non-reserved key is returned unchanged" do
      variables = %{"_sys.move" => "rec-secret", "_sys.move.seq" => 42, "greeting" => "hello"}

      {pid, store, memory} =
        start_instance(full_manifest(), wasm_execution_context(%{variables: variables}))

      for sys_key <- ["_sys.move", "_sys.move.seq"] do
        write_bytes(store, memory, 0, sys_key)

        assert {:ok, [-1]} =
                 Wasmex.call_function(pid, "call_read_variable", [
                   0,
                   byte_size(sys_key),
                   @out_ptr,
                   @out_cap
                 ])
      end

      write_bytes(store, memory, 0, "greeting")

      {:ok, _n, bytes} =
        call_string_fn(pid, "call_read_variable", [0, byte_size("greeting")], store, memory)

      assert Jason.decode!(bytes) == "hello"

      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------------
  # AC6: number marshalling -- LuaNumberMarshalling, integer/float subtype round-trip.
  # ---------------------------------------------------------------------

  describe "AC6: number conversion round-trips integer/float subtype" do
    test "an integer variable decodes back to an integer" do
      manifest = full_manifest()

      {pid, store, memory} =
        start_instance(manifest, wasm_execution_context(%{variables: %{"n" => 3}}))

      write_bytes(store, memory, 0, "n")

      {:ok, _n, bytes} = call_string_fn(pid, "call_read_variable", [0, 1], store, memory)

      assert Jason.decode!(bytes) |> is_integer()
      assert Jason.decode!(bytes) == 3

      GenServer.stop(pid)
    end

    test "a float variable decodes back to a float, subtype preserved" do
      manifest = full_manifest()

      {pid, store, memory} =
        start_instance(manifest, wasm_execution_context(%{variables: %{"f" => 3.0}}))

      write_bytes(store, memory, 0, "f")

      {:ok, _n, bytes} = call_string_fn(pid, "call_read_variable", [0, 1], store, memory)

      assert Jason.decode!(bytes) |> is_float()
      assert Jason.decode!(bytes) == 3.0

      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------------
  # -2 (invalid argument) case, shared buffer protocol.
  # ---------------------------------------------------------------------

  describe "the -2 invalid-argument case (shared §5.2 buffer protocol)" do
    test "read_variable: an out-of-bounds out_ptr returns -2 and writes nothing" do
      manifest = full_manifest()

      {pid, store, memory} =
        start_instance(manifest, wasm_execution_context(%{variables: %{"x" => 1}}))

      write_bytes(store, memory, 0, "x")
      size = Wasmex.Memory.size(store, memory)

      assert {:ok, [-2]} = Wasmex.call_function(pid, "call_read_variable", [0, 1, size + 100, 10])

      GenServer.stop(pid)
    end

    test "now: an out-of-bounds out_ptr returns -2" do
      {pid, store, memory} =
        start_instance(%{capabilities: []}, wasm_execution_context(), "req171_now_uuid_only.wat")

      size = Wasmex.Memory.size(store, memory)

      assert {:ok, [-2]} = Wasmex.call_function(pid, "call_now", [size + 100, 10])

      GenServer.stop(pid)
    end

    test "uuid: an out-of-bounds out_ptr returns -2" do
      {pid, store, memory} =
        start_instance(%{capabilities: []}, wasm_execution_context(), "req171_now_uuid_only.wat")

      size = Wasmex.Memory.size(store, memory)

      assert {:ok, [-2]} = Wasmex.call_function(pid, "call_uuid", [size + 100, 10])

      GenServer.stop(pid)
    end

    # Mutation-tested (WF-02 Step 3, REQ-171): a mutant that replaces
    # write_buffer_result/4's MemoryGuard.write/4 calls with a raw
    # Wasmex.Memory.write_binary/4 call passes every other -2 test in this describe
    # block unchanged -- a moderately-out-of-bounds positive out_ptr (memory size +
    # 100) is ALSO rejected by wasmex's own internal bounds check, so those tests
    # cannot tell "MemoryGuard ran" apart from "wasmex's own check happened to catch
    # it anyway." A negative i32 out_ptr (the guest's only way to encode an
    # attacker-chosen large *unsigned* address, since wasm i32 params carry no
    # separate signedness) is where the two diverge: MemoryGuard's own
    # check_type_and_sign/2 rejects any negative offset before ever reaching
    # `wasmex`, returning the same clean -2 sentinel every other invalid-argument
    # case returns; skip that check and reach Wasmex.Memory.write_binary/4 directly
    # with a negative offset instead, and wasmex traps, surfacing as an
    # {:error, "...wasm backtrace..."} `Wasmex.call_function/4` return rather than
    # `{:ok, [-2]}` -- a materially different, less safe outcome INV-HOSTAPI-3 exists
    # specifically to prevent.
    test "now: a negative (attacker-chosen large-unsigned) out_ptr is still rejected as -2, not a raw wasmex trap" do
      {pid, _store, _memory} =
        start_instance(%{capabilities: []}, wasm_execution_context(), "req171_now_uuid_only.wat")

      assert {:ok, [-2]} = Wasmex.call_function(pid, "call_now", [-1, 10])

      GenServer.stop(pid)
    end

    test "a capacity smaller than the value's length returns n and writes nothing -- the guest can retry with a bigger buffer" do
      manifest = full_manifest()

      {pid, store, memory} =
        start_instance(manifest, wasm_execution_context(%{variables: %{"x" => "hello"}}))

      write_bytes(store, memory, 0, "x")
      # sentinel byte at a location unaffected by a "writes nothing" call
      write_bytes(store, memory, @out_ptr, <<0xFF>>)

      assert {:ok, [n]} = Wasmex.call_function(pid, "call_read_variable", [0, 1, @out_ptr, 0])
      assert n == byte_size(Jason.encode!("hello"))
      assert read_bytes(store, memory, @out_ptr, 1) == <<0xFF>>

      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------------
  # AC4: now -- parity with Lua under the same injected clock double.
  # ---------------------------------------------------------------------

  describe "AC4: now" do
    setup do
      previous = Application.get_env(:letflow, :lua_platform_time_source)
      Application.put_env(:letflow, :lua_platform_time_source, FixedTimeSource)

      on_exit(fn ->
        if previous do
          Application.put_env(:letflow, :lua_platform_time_source, previous)
        else
          Application.delete_env(:letflow, :lua_platform_time_source)
        end
      end)

      :ok
    end

    test "WASM's now returns the exact same ISO 8601 UTC instant as Lua's platform.now() under the same injected clock" do
      lua = Platform.install(Sandbox.new(), Capabilities.new(), lua_execution_context())
      {[lua_result], _lua} = Lua.eval!(lua, "return platform.now()")

      {pid, store, memory} =
        start_instance(%{capabilities: []}, wasm_execution_context(), "req171_now_uuid_only.wat")

      {:ok, _n, bytes} = call_string_fn(pid, "call_now", [], store, memory)

      assert bytes == lua_result
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(bytes)

      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------------
  # AC5: uuid -- documented WASM-only addition, no Lua counterpart.
  # ---------------------------------------------------------------------

  describe "AC5: uuid" do
    test "returns a well-formed, unique 36-byte UUID string on two successive calls" do
      {pid, store, memory} =
        start_instance(%{capabilities: []}, wasm_execution_context(), "req171_now_uuid_only.wat")

      {:ok, n1, uuid1} = call_string_fn(pid, "call_uuid", [], store, memory)
      {:ok, n2, uuid2} = call_string_fn(pid, "call_uuid", [], store, memory)

      assert n1 == 36
      assert n2 == 36
      assert {:ok, _} = Ecto.UUID.cast(uuid1)
      assert {:ok, _} = Ecto.UUID.cast(uuid2)
      assert uuid1 != uuid2

      GenServer.stop(pid)
    end

    test "moduledoc states uuid has no Lua counterpart and records the WASM-side-addition decision" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(HostApi)

      assert moduledoc =~ "no Lua counterpart"
      assert moduledoc =~ ~r/documented\s+WASM-side addition/
    end
  end

  # ---------------------------------------------------------------------
  # AC3: log -- structured entry carrying script/module identity, instance ID, trace
  # ID, plus Lua/WASM parity on the emitted message text.
  # ---------------------------------------------------------------------

  describe "AC3: log carries script_identity/instance_id/trace_id" do
    test "WASM's log emits all three correlation fields, matching the fixed execution_context" do
      execution_context =
        wasm_execution_context(%{
          script_identity: "req171-script-abc",
          instance_id: "req171-instance-xyz",
          trace_id: "req171-trace-123"
        })

      {pid, store, memory} = start_instance(full_manifest(), execution_context)

      write_bytes(store, memory, 0, "info")
      write_bytes(store, memory, 10, "a wasm message")

      log =
        ExUnit.CaptureLog.capture_log(
          [metadata: [:script_identity, :instance_id, :trace_id]],
          fn ->
            assert {:ok, []} =
                     Wasmex.call_function(pid, "call_log", [0, 4, 10, 14, 0, 0])
          end
        )

      assert log =~ "script_identity=req171-script-abc"
      assert log =~ "instance_id=req171-instance-xyz"
      assert log =~ "trace_id=req171-trace-123"
      assert log =~ "a wasm message"

      GenServer.stop(pid)
    end

    test "AC1 parity: the same level/message/correlation fields produce the same observable log line shape on both runtimes" do
      lua_context =
        lua_execution_context(%{
          script_identity: "req171-parity-script",
          instance_id: "req171-parity-instance",
          trace_id: "req171-parity-trace"
        })

      lua = Platform.install(Sandbox.new(), Capabilities.new(["audit:log"]), lua_context)

      lua_log =
        ExUnit.CaptureLog.capture_log(
          [metadata: [:script_identity, :instance_id, :trace_id]],
          fn ->
            Lua.eval!(lua, "return platform.log('info', 'parity message', nil)")
          end
        )

      wasm_context =
        wasm_execution_context(%{
          script_identity: "req171-parity-script",
          instance_id: "req171-parity-instance",
          trace_id: "req171-parity-trace"
        })

      {pid, store, memory} = start_instance(full_manifest(), wasm_context)
      write_bytes(store, memory, 0, "info")
      write_bytes(store, memory, 10, "parity message")

      wasm_log =
        ExUnit.CaptureLog.capture_log(
          [metadata: [:script_identity, :instance_id, :trace_id]],
          fn ->
            Wasmex.call_function(pid, "call_log", [0, 4, 10, byte_size("parity message"), 0, 0])
          end
        )

      for log <- [lua_log, wasm_log] do
        assert log =~ "script_identity=req171-parity-script"
        assert log =~ "instance_id=req171-parity-instance"
        assert log =~ "trace_id=req171-parity-trace"
        assert log =~ "parity message"
      end

      GenServer.stop(pid)
    end

    # Mutation-tested (WF-02 Step 3, REQ-171): a mutant that sources
    # script_identity/instance_id/trace_id from the guest-decoded `context` JSON
    # payload (falling back to execution_context only when the guest's payload omits
    # the key) passes every other test in this file -- none of them ever sends a
    # context payload shaped like `{"script_identity": ...}`. Per SECURITY-REVIEWER's
    # Step 2c finding, this is the single most security-relevant mutation in this
    # module: it would let an untrusted guest forge its own audit-log identity simply
    # by choosing what bytes to put in the `context` argument. This test drives a
    # guest-supplied context object whose keys collide exactly with the three
    # identity metadata keys, using attacker-chosen values that differ from the real
    # (closure-captured) execution_context on every field, and asserts the emitted
    # log carries ONLY the real execution_context's values -- never the guest's.
    test "identity fields are never sourced from guest-supplied context bytes -- a guest cannot forge script_identity/instance_id/trace_id" do
      real_execution_context =
        wasm_execution_context(%{
          script_identity: "real-script-identity",
          instance_id: "real-instance-id",
          trace_id: "real-trace-id"
        })

      {pid, store, memory} = start_instance(full_manifest(), real_execution_context)

      write_bytes(store, memory, 0, "info")
      write_bytes(store, memory, 10, "identity forgery attempt")

      forged_context_json =
        Jason.encode!(%{
          "script_identity" => "FORGED-script-identity",
          "instance_id" => "FORGED-instance-id",
          "trace_id" => "FORGED-trace-id"
        })

      write_bytes(store, memory, 100, forged_context_json)

      log =
        ExUnit.CaptureLog.capture_log(
          [metadata: [:script_identity, :instance_id, :trace_id]],
          fn ->
            assert {:ok, []} =
                     Wasmex.call_function(pid, "call_log", [
                       0,
                       4,
                       10,
                       byte_size("identity forgery attempt"),
                       100,
                       byte_size(forged_context_json)
                     ])
          end
        )

      assert log =~ "script_identity=real-script-identity"
      assert log =~ "instance_id=real-instance-id"
      assert log =~ "trace_id=real-trace-id"

      refute log =~ "FORGED-script-identity"
      refute log =~ "FORGED-instance-id"
      refute log =~ "FORGED-trace-id"

      GenServer.stop(pid)
    end

    test "log never raises on a malformed context argument -- decode failure logs context: nil with context_decode_error: true" do
      execution_context =
        wasm_execution_context(%{script_identity: "s", instance_id: "i", trace_id: "t"})

      {pid, store, memory} = start_instance(full_manifest(), execution_context)

      write_bytes(store, memory, 0, "info")
      write_bytes(store, memory, 10, "msg")
      malformed_json = "{not valid json"
      write_bytes(store, memory, 20, malformed_json)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, []} =
                   Wasmex.call_function(pid, "call_log", [
                     0,
                     4,
                     10,
                     3,
                     20,
                     byte_size(malformed_json)
                   ])
        end)

      assert log =~ "msg"

      GenServer.stop(pid)
    end
  end

  # ---------------------------------------------------------------------
  # AC7: capability gating comes exclusively from CapabilityGate, no second model.
  # ---------------------------------------------------------------------

  describe "AC7: capability gating comes from CapabilityGate.build_import_table/2, no second model" do
    test "a manifest lacking var:read produces an import table with no read_variable entry" do
      table = CapabilityGate.build_import_table(%{capabilities: []}, wasm_execution_context())
      refute Map.has_key?(Map.get(table, "env", %{}), "read_variable")
    end

    test "a manifest with no capabilities still yields working now/uuid (the :none rows)" do
      {pid, store, memory} =
        start_instance(%{capabilities: []}, wasm_execution_context(), "req171_now_uuid_only.wat")

      assert {:ok, _n, _bytes} = call_string_fn(pid, "call_now", [], store, memory)
      assert {:ok, _n, _bytes} = call_string_fn(pid, "call_uuid", [], store, memory)

      GenServer.stop(pid)
    end

    test "moduledoc names REQ-167/CapabilityGate as the capability source" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(HostApi)

      assert moduledoc =~ "Letflow.Engine.Wasm.CapabilityGate"
      assert moduledoc =~ "REQ-167"
    end
  end

  # ---------------------------------------------------------------------
  # AC8: tenant boundary -- no Letflow.Repo call anywhere in host_api.ex.
  # ---------------------------------------------------------------------

  describe "AC8: no host function calls Letflow.Repo with a guest-derived prefix" do
    test "structural grep: host_api.ex never CALLS Letflow.Repo (a dot-qualified reference, e.g. Letflow.Repo.get) -- moduledoc/comment prose naming the module by name (no trailing dot) is not a call and is expected" do
      {output, exit_code} =
        System.cmd(
          "grep",
          ["-nE", "Letflow\\.Repo\\.", "lib/letflow/engine/wasm/host_api.ex"],
          stderr_to_stdout: true,
          cd: File.cwd!()
        )

      # grep exits 1 when no lines match -- that is the PASSING outcome here.
      assert exit_code == 1
      assert output == ""
    end

    test "moduledoc states the tenant prefix is supplied by the calling engine code, per decision 0014 (e)" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(HostApi)

      assert moduledoc =~ "decision 0014 (e)"
      assert moduledoc =~ "tenant prefix is supplied by the calling engine code"
    end
  end
end
