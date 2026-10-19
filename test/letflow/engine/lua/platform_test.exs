defmodule Letflow.Engine.Lua.PlatformTest do
  @moduledoc """
  Tests for `Letflow.Engine.Lua.Platform` (REQ-152, LUA-14 restated). See
  `test/specs/REQ-152.md` for the full test-case rationale and the acceptance-criteria
  mapping.

  Every script-visible assertion constructs its `Lua.t()` exclusively via
  `Letflow.Engine.Lua.Sandbox.new/0` (never `Lua.new/1` directly, never
  `Letflow.Engine.Lua.Platform.install/1` called by hand) so each assertion exercises
  the real production composition path -- `platform.now` is reachable from a script only
  because `Sandbox.new/1` calls `Platform.install/1` itself.

  The `Application.put_env(:letflow, :lua_platform_time_source, ...)` swap used below
  is reverted in `on_exit` in every test that sets it, so tests remain order-independent
  and never leak a fixed clock into an unrelated test. `async: false` because these
  tests mutate a shared, process-independent piece of state (application env) that
  `Platform.now/0` reads fresh on every call -- running them concurrently with each
  other (or with any other test that happens to call `Platform.now/0` while a swap is
  active) would race.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Engine.Lua.Capabilities
  alias Letflow.Engine.Lua.Platform
  alias Letflow.Engine.Lua.Sandbox
  alias Letflow.Engine.VariableMerge
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.TenantFixture

  defmodule FixedTimeSource do
    @moduledoc false
    @behaviour Platform.TimeSource

    @impl Platform.TimeSource
    def now, do: ~U[2026-01-01 00:00:00.000000Z]
  end

  describe "platform.now() returns an ISO 8601 UTC string parseable by DateTime.from_iso8601/1 (AC4)" do
    test "called from inside a script" do
      {[result], _lua} = Lua.eval!(Sandbox.new(), "return platform.now()")

      assert is_binary(result)
      assert {:ok, %DateTime{} = dt, 0} = DateTime.from_iso8601(result)
      assert dt.time_zone == "Etc/UTC"
    end

    test "Platform.now/0 called directly also returns a DateTime.from_iso8601/1-parseable string" do
      result = Platform.now()

      assert is_binary(result)
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(result)
    end
  end

  describe "the time source is injectable -- exact pre-set timestamp, not merely well-formed (AC5)" do
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

    test "Platform.now/0 returns the exact fixed timestamp, not a merely well-formed one" do
      expected = DateTime.to_iso8601(~U[2026-01-01 00:00:00.000000Z])

      assert Platform.now() == expected
    end

    test "platform.now() called from inside a script also returns the exact fixed timestamp" do
      expected = DateTime.to_iso8601(~U[2026-01-01 00:00:00.000000Z])

      {[result], _lua} = Lua.eval!(Sandbox.new(), "return platform.now()")

      assert result == expected
    end

    test "swapping the fixed source back out restores real, non-fixed values" do
      fixed = Platform.now()

      Application.put_env(:letflow, :lua_platform_time_source, Platform.SystemClock)

      real = Platform.now()

      refute real == fixed
    end
  end

  describe "moduledoc content (AC7)" do
    setup do
      {:docs_v1, _anno, _lang, _fmt, moduledoc, _meta, _docs} =
        Code.fetch_docs(Letflow.Engine.Lua.Platform)

      %{"en" => text} = moduledoc
      %{moduledoc: text}
    end

    test "states platform.now is ungated by design, not an omission", %{moduledoc: text} do
      assert text =~ "ungated by design"
      assert text =~ "not an omission"
    end

    test "states no capability check, gate, or permission lookup exists in now's call path", %{
      moduledoc: text
    } do
      assert text =~ "no capability"
      assert text =~ "gate"
    end

    test "states a future requirement adding a capability gate to platform.now by symmetry is wrong",
         %{moduledoc: text} do
      assert text =~ "REQ-157"
      assert text =~ "symmetry"
    end

    test "states the injection mechanism -- behaviour + application-env resolution", %{
      moduledoc: text
    } do
      assert text =~ "TimeSource"
      assert text =~ "application env"
    end

    test "states install/1's composition point -- Sandbox.new calls it", %{moduledoc: text} do
      assert text =~ "Sandbox.new"
      assert text =~ "install"
    end
  end

  describe "REQ-157: closed-set enumeration (AC1)" do
    test "a script enumerates exactly the 8 platform.* names via pairs(platform), no more, no fewer" do
      script = """
      local names = {}
      for k, _v in pairs(platform) do
        table.insert(names, k)
      end
      table.sort(names)
      return table.concat(names, ",")
      """

      {[result], _lua} = Lua.eval!(Sandbox.new(), script)

      expected =
        ~w(call_service emit_event fail get_instance_state log now read_variable write_variable)
        |> Enum.sort()
        |> Enum.join(",")

      assert result == expected
    end

    test "platform.ex's source contains exactly one Lua.set!(_, [:platform, occurrence (the single fold)" do
      source = File.read!("lib/letflow/engine/lua/platform.ex")

      # Matches only an actual call-site pattern (`Lua.set!(<accumulator>, [:platform,`),
      # not the moduledoc/comment prose describing the invariant in words -- guards
      # against a future hand-added 9th `Lua.set!` call bypassing the matrix fold,
      # regardless of what the fold's own accumulator variable happens to be named.
      occurrences =
        ~r/Lua\.set!\([a-z_]+,\s*\[:platform,/
        |> Regex.scan(source)
        |> length()

      assert occurrences == 1
    end
  end

  describe "REQ-157: per-function capability-denial tests, empty grant set (AC2)" do
    setup do
      lua = Platform.install(Sandbox.new(), Capabilities.new())
      %{lua: lua}
    end

    # Each case below asserts not merely "some Lua.RuntimeException was raised" but that
    # the raised exception's `capability_required` field is present and matches the exact
    # capability the row's own matrix entry names. This distinguishes a genuine capability
    # DENIAL from that function's own "not yet implemented" stub raise (which never carries
    # a `capability_required` field, per `run_stub(:not_yet_implemented, ...)`). Without
    # this distinction, a bug that skipped `Capabilities.check!/3` entirely for one row
    # (the stub still raises "not implemented" either way, granted or not) would pass a
    # bare `assert_raise Lua.RuntimeException` unnoticed -- confirmed by mutation-testing
    # the shipped code: temporarily short-circuiting the `check!/3` call for
    # `write_variable` left every test in this file passing until this field assertion
    # was added.
    test "platform.read_variable(...) raises a capability denial for variable:read", %{
      lua: lua
    } do
      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.read_variable('x')")
        end

      assert exception.original[:function] == :read_variable
      assert exception.original[:capability_required] == "variable:read"
      assert exception.original[:capabilities_granted] == []
    end

    test "platform.write_variable(...) raises a capability denial for variable:write", %{
      lua: lua
    } do
      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.write_variable('x', 'y')")
        end

      assert exception.original[:function] == :write_variable
      assert exception.original[:capability_required] == "variable:write"
      assert exception.original[:capabilities_granted] == []
    end

    test "platform.log(...) raises a capability denial for audit:log", %{lua: lua} do
      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.log('hello')")
        end

      assert exception.original[:function] == :log
      assert exception.original[:capability_required] == "audit:log"
      assert exception.original[:capabilities_granted] == []
    end

    test "platform.emit_event(...) raises a capability denial for event:emit", %{lua: lua} do
      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.emit_event('evt')")
        end

      assert exception.original[:function] == :emit_event
      assert exception.original[:capability_required] == "event:emit"
      assert exception.original[:capabilities_granted] == []
    end

    test "platform.get_instance_state(...) raises a capability denial for instance:read", %{
      lua: lua
    } do
      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.get_instance_state()")
        end

      assert exception.original[:function] == :get_instance_state
      assert exception.original[:capability_required] == "instance:read"
      assert exception.original[:capabilities_granted] == []
    end

    test "platform.call_service(\"any-service\") raises a capability denial for service:call:any-service",
         %{lua: lua} do
      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.call_service('any-service')")
        end

      assert exception.original[:function] == :call_service
      assert exception.original[:capability_required] == "service:call:any-service"
      assert exception.original[:capabilities_granted] == []
    end
  end

  describe "REQ-157: structured denial fields (AC3)" do
    test "rescuing read_variable's denial exposes function, required, and granted" do
      lua = Platform.install(Sandbox.new(), Capabilities.new())

      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.read_variable('x')")
        end

      assert exception.original[:function] == :read_variable
      assert exception.original[:capability_required] == "variable:read"
      assert exception.original[:capabilities_granted] == []
    end
  end

  describe "REQ-157: call_service denial without any grant (AC4)" do
    test "platform.call_service(\"billing\") without a service:call:billing grant raises with the exact required capability" do
      lua = Platform.install(Sandbox.new(), Capabilities.new())

      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.call_service('billing')")
        end

      assert exception.original[:capability_required] == "service:call:billing"
    end
  end

  describe "REQ-157: call_service grant is parameterised, not blanket (AC5)" do
    setup do
      lua = Platform.install(Sandbox.new(), Capabilities.new(["service:call:alpha"]))
      %{lua: lua}
    end

    test "a service:call:alpha grant lets platform.call_service('alpha') pass the gate (reaches the real body, never raises)",
         %{lua: lua} do
      # Passed the gate: call_service's real body (REQ-160) never raises -- the default
      # NoServiceCaller returns a structured error instead.
      script = """
      local response, err = platform.call_service('alpha')
      return response, err.reason
      """

      assert {[nil, "service_caller_not_configured"], _lua} = Lua.eval!(lua, script)
    end

    test "the same grant does NOT authorise platform.call_service('beta')", %{lua: lua} do
      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.call_service('beta')")
        end

      assert exception.original[:capability_required] == "service:call:beta"
      assert exception.original[:capabilities_granted] == ["service:call:alpha"]
    end
  end

  describe "REQ-157: now and fail are callable with an empty capability set (AC6)" do
    test "platform.now() returns its normal value with no raise at all" do
      lua = Platform.install(Sandbox.new(), Capabilities.new())

      {[result], _lua} = Lua.eval!(lua, "return platform.now()")

      assert is_binary(result)
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(result)
    end

    test "platform.fail() terminates the process via exit, not a capability denial (REQ-161 AC4)" do
      lua = Platform.install(Sandbox.new(), Capabilities.new())

      task =
        Task.Supervisor.async_nolink(Letflow.Engine.Lua.TaskSupervisor, fn ->
          Lua.eval!(lua, "return platform.fail()")
        end)

      assert {:exit, {:script_failed, %{reason: _, details: nil}}} = Task.yield(task, 1_000)
    end
  end

  describe "REQ-157: moduledoc content (AC7)" do
    setup do
      {:docs_v1, _anno, _lang, _fmt, moduledoc, _meta, _docs} =
        Code.fetch_docs(Letflow.Engine.Lua.Platform)

      %{"en" => text} = moduledoc
      %{moduledoc: text}
    end

    test "reproduces the 8-row capability matrix in substance", %{moduledoc: text} do
      for name <-
            ~w(call_service read_variable write_variable log emit_event get_instance_state now fail) do
        assert text =~ name
      end

      assert text =~ "service:call:"
      assert text =~ "variable:read"
      assert text =~ "variable:write"
      assert text =~ "audit:log"
      assert text =~ "event:emit"
      assert text =~ "instance:read"
    end

    test "states the now/fail ungated rationale", %{moduledoc: text} do
      assert text =~ "pure time read with no state reach"
      assert text =~ "may always terminate itself"
    end

    test "carries the binding statement guarding against a future gate on now or fail", %{
      moduledoc: text
    } do
      assert text =~ "A test that expects a gate on `now` or `fail` is reading the matrix wrong"
    end
  end

  # =====================================================================================
  # REQ-159 -- lib/letflow/design/req159-lua-host-api-read.md
  # =====================================================================================

  # ---------------------------------------------------------------------------------
  # Fixtures -- provisions via Letflow.TenantFixture (ISS-0112 / GH#366), trimmed to
  # what this file's REQ-159 tests need.
  # ---------------------------------------------------------------------------------

  defp provisioned_tenant do
    TenantFixture.provisioned_tenant!(
      slug_prefix: "req159",
      display_name: "REQ-159 Test Tenant"
    )
  end

  defp seed_projection!(schema_name, instance_id, attrs \\ %{}) do
    %InstanceProjection{}
    |> InstanceProjection.insert_changeset(
      Map.merge(
        %{
          instance_id: instance_id,
          status: :active,
          last_event_seq: 0,
          definition_id: Ecto.UUID.generate(),
          variables: %{}
        },
        attrs
      )
    )
    |> Repo.insert!(prefix: schema_name)
  end

  defp execution_context(overrides \\ %{}) do
    Map.merge(Platform.empty_execution_context(), overrides)
  end

  # ---------------------------------------------------------------------------------
  # platform.read_variable -- current value or nil (AC1), number-marshalling round trip
  # (AC6), malformed argument, capability denial (AC4)
  # ---------------------------------------------------------------------------------

  describe "REQ-159: platform.read_variable" do
    test "returns the current value for a set variable" do
      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["variable:read"]),
          execution_context(%{variables: %{"greeting" => "hello"}})
        )

      assert {["hello"], _lua} = Lua.eval!(lua, "return platform.read_variable('greeting')")
    end

    test "returns nil for an unset variable" do
      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["variable:read"]),
          execution_context(%{variables: %{"greeting" => "hello"}})
        )

      assert {[nil], _lua} = Lua.eval!(lua, "return platform.read_variable('missing')")
    end

    test "returns nil for a malformed (non-string) argument, rather than raising" do
      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["variable:read"]),
          execution_context(%{variables: %{"x" => 1}})
        )

      assert {[nil], _lua} = Lua.eval!(lua, "return platform.read_variable(42)")
    end

    test "round-trips an integer AND a float, proving LuaNumberMarshalling.to_lua/1 is genuinely applied (AC6)" do
      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["variable:read"]),
          execution_context(%{variables: %{"int_var" => 3, "float_var" => 3.0}})
        )

      script = """
      local int_val = platform.read_variable('int_var')
      local float_val = platform.read_variable('float_var')
      return math.type(int_val), math.type(float_val), int_val, float_val
      """

      assert {["integer", "float", 3, 3.0], _lua} = Lua.eval!(lua, script)
    end

    test "capability denial for variable:read (AC4)" do
      lua = Platform.install(Sandbox.new(), Capabilities.new(), execution_context())

      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.read_variable('x')")
        end

      assert exception.original[:function] == :read_variable
      assert exception.original[:capability_required] == "variable:read"
    end

    test "capability denial happens even when a real execution context is supplied" do
      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(),
          execution_context(%{variables: %{"x" => 1}})
        )

      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.read_variable('x')")
        end

      assert exception.original[:capability_required] == "variable:read"
    end
  end

  # ---------------------------------------------------------------------------------
  # platform.get_instance_state -- valid self instance (AC3), structured errors (AC3),
  # the self-instance-only security proof, capability denial (AC4)
  # ---------------------------------------------------------------------------------

  describe "REQ-159: platform.get_instance_state -- valid instance, scoped to self" do
    setup do
      %{tenant_id: _tenant_id, schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()

      seed_projection!(schema_name, instance_id, %{
        status: :active,
        variables: %{"count" => 1, "ratio" => 2.5}
      })

      %{schema_name: schema_name, instance_id: instance_id}
    end

    test "returns state for the script's own valid instance", %{
      schema_name: schema_name,
      instance_id: instance_id
    } do
      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["instance:read"]),
          execution_context(%{instance_id: instance_id, prefix: schema_name})
        )

      script = """
      local state = platform.get_instance_state('#{instance_id}')
      return state.status, math.type(state.variables.count), state.variables.count,
             math.type(state.variables.ratio), state.variables.ratio
      """

      assert {["ACTIVE", "integer", 1, "float", 2.5], _lua} = Lua.eval!(lua, script)
    end
  end

  describe "GH #2587 PR B3 (INV-2): engine-written _sys values are never script-readable" do
    test "read_variable returns nil for a reserved key, and still reads ordinary ones" do
      {:ok, vars} = VariableMerge.put_sys(%{"plain" => "ok"}, "_sys.r", Ecto.UUID.generate())

      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["variable:read"]),
          execution_context(%{variables: vars})
        )

      assert {[nil], _} = Lua.eval!(lua, "return platform.read_variable('_sys.r')")
      assert {["ok"], _} = Lua.eval!(lua, "return platform.read_variable('plain')")
    end

    test "get_instance_state omits reserved keys from variables" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      {:ok, vars} = VariableMerge.put_sys(%{"plain" => "ok"}, "_sys.r", Ecto.UUID.generate())
      {:ok, vars} = VariableMerge.put_sys(vars, "_sys.r.seq", 5)
      seed_projection!(schema_name, instance_id, %{status: :active, variables: vars})

      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["instance:read"]),
          execution_context(%{instance_id: instance_id, prefix: schema_name})
        )

      script = """
      local state = platform.get_instance_state('#{instance_id}')
      local n = 0
      for _ in pairs(state.variables) do n = n + 1 end
      return n, state.variables.plain, state.variables['_sys.r']
      """

      assert {[1, "ok", nil], _lua} = Lua.eval!(lua, script)
    end
  end

  describe "REQ-159: platform.get_instance_state -- structured errors, never a raise" do
    test "non-UUID-shaped argument returns {nil, reason: invalid_id}, even with a valid own instance_id set" do
      own_id = Ecto.UUID.generate()

      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["instance:read"]),
          execution_context(%{instance_id: own_id, prefix: "irrelevant_schema"})
        )

      script = """
      local state, err = platform.get_instance_state('not-a-uuid')
      return state, err.reason
      """

      assert {[nil, "invalid_id"], _lua} = Lua.eval!(lua, script)
    end

    test "empty-context sentinel (prefix == nil) returns {nil, reason: no_execution_context}, no Repo call attempted" do
      lua =
        Platform.install(Sandbox.new(), Capabilities.new(["instance:read"]), execution_context())

      script = """
      local state, err = platform.get_instance_state('#{Ecto.UUID.generate()}')
      return state, err.reason
      """

      assert {[nil, "no_execution_context"], _lua} = Lua.eval!(lua, script)
    end

    test "own instance_id with no corresponding row returns {nil, reason: not_found}" do
      %{schema_name: schema_name} = provisioned_tenant()
      own_id = Ecto.UUID.generate()

      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["instance:read"]),
          execution_context(%{instance_id: own_id, prefix: schema_name})
        )

      script = """
      local state, err = platform.get_instance_state('#{own_id}')
      return state, err.reason
      """

      assert {[nil, "not_found"], _lua} = Lua.eval!(lua, script)
    end

    test "a real same-tenant sibling instance AND a nonexistent instance id both return the IDENTICAL forbidden result" do
      %{schema_name: schema_name} = provisioned_tenant()
      own_id = Ecto.UUID.generate()
      sibling_id = Ecto.UUID.generate()
      nonexistent_id = Ecto.UUID.generate()

      seed_projection!(schema_name, own_id)
      seed_projection!(schema_name, sibling_id)

      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["instance:read"]),
          execution_context(%{instance_id: own_id, prefix: schema_name})
        )

      script = fn target_id ->
        """
        local state, err = platform.get_instance_state('#{target_id}')
        return state, err.reason
        """
      end

      sibling_result = Lua.eval!(lua, script.(sibling_id))
      nonexistent_result = Lua.eval!(lua, script.(nonexistent_id))

      assert {[nil, "forbidden"], _lua} = sibling_result
      assert {[nil, "forbidden"], _lua} = nonexistent_result

      # The key security proof: identical outcome for a real sibling vs. a fabricated
      # id -- a script cannot use this response to probe which other ids exist.
      {sibling_values, _} = sibling_result
      {nonexistent_values, _} = nonexistent_result
      assert sibling_values == nonexistent_values
    end

    # Mutation-testing finding (TEST-DESIGNER, REQ-159 Step 3): the design and moduledoc
    # both state "forbidden" is returned with NO `Repo` call attempted at all -- but
    # every test above only asserts the RETURN VALUE. A mutation that runs
    # `fetch_instance_state/3` (i.e. calls `Repo.get/3`) UNCONDITIONALLY and only
    # afterward substitutes the "forbidden" error for a non-matching id produces the
    # exact same return values on every test above and is caught by none of them --
    # confirmed directly: reordering `do_get_instance_state/3`'s self-instance equality
    # check to run after `fetch_instance_state/3` rather than before it left all
    # pre-existing tests in this file passing (56/56). This test closes that gap by
    # asserting, via `:telemetry`, that the `[:letflow, :repo, :query]` event never
    # fires for a same-tenant-sibling id -- the same telemetry-counter idiom
    # `test/letflow/api/context_test.exs` already uses to prove a `Repo` call did or
    # did not happen.
    test "no Repo.get/3 (no [:letflow, :repo, :query] telemetry event) fires for a same-tenant sibling id" do
      %{schema_name: schema_name} = provisioned_tenant()
      own_id = Ecto.UUID.generate()
      sibling_id = Ecto.UUID.generate()

      seed_projection!(schema_name, own_id)
      seed_projection!(schema_name, sibling_id)

      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["instance:read"]),
          execution_context(%{instance_id: own_id, prefix: schema_name})
        )

      handler_id = {__MODULE__, :get_instance_state_query_counter, make_ref()}
      counter = :counters.new(1, [])

      :telemetry.attach(
        handler_id,
        [:letflow, :repo, :query],
        fn _event, _measurements, _metadata, _config -> :counters.add(counter, 1, 1) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      script = """
      local state, err = platform.get_instance_state('#{sibling_id}')
      return state, err.reason
      """

      assert {[nil, "forbidden"], _lua} = Lua.eval!(lua, script)

      assert :counters.get(counter, 1) == 0
    end
  end

  describe "REQ-159: platform.get_instance_state -- capability denial (AC4)" do
    test "raises a capability denial for instance:read" do
      lua = Platform.install(Sandbox.new(), Capabilities.new(), execution_context())

      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.get_instance_state('#{Ecto.UUID.generate()}')")
        end

      assert exception.original[:function] == :get_instance_state
      assert exception.original[:capability_required] == "instance:read"
    end
  end

  # ---------------------------------------------------------------------------------
  # platform.log -- structured entry with correlation IDs (AC2), level mapping, never
  # raises, capability denial (AC4)
  # ---------------------------------------------------------------------------------

  describe "REQ-159: platform.log -- structured entry with correlation IDs" do
    setup do
      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["audit:log"]),
          execution_context(%{
            script_identity: "req159-script-abc",
            instance_id: "req159-instance-xyz",
            trace_id: "req159-trace-123"
          })
        )

      %{lua: lua}
    end

    test "emits an entry with all three correlation fields, asserted individually, plus the message text",
         %{lua: lua} do
      log =
        ExUnit.CaptureLog.capture_log(
          [metadata: [:script_identity, :instance_id, :trace_id]],
          fn ->
            Lua.eval!(lua, "return platform.log('info', 'a message', nil)")
          end
        )

      assert log =~ "script_identity=req159-script-abc"
      assert log =~ "instance_id=req159-instance-xyz"
      assert log =~ "trace_id=req159-trace-123"
      assert log =~ "a message"
    end

    test "a table context argument is present on the emitted entry's metadata, not silently dropped",
         %{lua: lua} do
      # Elixir's default `Logger` text formatter only knows how to render
      # binary/integer/float/pid/atom/ref/port metadata values (confirmed directly
      # against `logger/formatter.ex:494-536`) -- a map value like `context` is silently
      # omitted from the *formatted text*, even though it IS present on the raw log
      # event's metadata. A raw `:logger` handler (below) asserts against that raw
      # metadata directly, rather than against the lossy formatted string.
      %{context: context} =
        capture_raw_log_meta(fn ->
          Lua.eval!(lua, "return platform.log('info', 'ctx message', {reason = 'test'})")
        end)

      # `Lua.decode!/2` decodes a table into a proplist (`[{key, value}]`), not a map --
      # see `Lua.decode_list!/2`'s own doctest (`deps/lua/lib/lua.ex:1057-1064`).
      assert context == [{"reason", "test"}]
    end
  end

  # Adds a temporary raw `:logger` handler for the duration of `fun`, returning the
  # metadata map of the first log event it observes. Used only where the default
  # `Logger` text formatter would lossily drop a non-scalar metadata value (see above) --
  # every other assertion in this file uses `ExUnit.CaptureLog` against the formatted
  # text, which is sufficient for every scalar (string) correlation field.
  defp capture_raw_log_meta(fun) do
    ref = make_ref()
    parent = self()
    handler_id = :"platform_test_raw_log_#{System.unique_integer([:positive])}"

    :logger.add_handler(handler_id, Letflow.Engine.Lua.PlatformTest.RawLogCapture, %{
      config: %{parent: parent, ref: ref}
    })

    try do
      fun.()
    after
      :logger.remove_handler(handler_id)
    end

    receive do
      {^ref, meta} -> meta
    after
      1_000 -> flunk("no log event captured by the raw :logger handler")
    end
  end

  defmodule RawLogCapture do
    @moduledoc false
    def log(%{meta: meta}, %{config: %{parent: parent, ref: ref}}) do
      send(parent, {ref, meta})
      :ok
    end
  end

  describe "REQ-159: platform.log -- level mapping and malformed input" do
    setup do
      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["audit:log"]),
          execution_context(%{script_identity: "s", instance_id: "i", trace_id: "t"})
        )

      %{lua: lua}
    end

    for {lua_level, elixir_level} <- [
          {"debug", "[debug]"},
          {"info", "[info]"},
          {"warn", "[warning]"},
          {"error", "[error]"}
        ] do
      test "'#{lua_level}' maps to Elixir Logger level #{elixir_level}", %{lua: lua} do
        log =
          ExUnit.CaptureLog.capture_log([level: :debug], fn ->
            Lua.eval!(lua, "return platform.log('#{unquote(lua_level)}', 'lvl-msg', nil)")
          end)

        assert log =~ unquote(elixir_level)
      end
    end

    test "an unrecognized level string produces an :info entry tagged with original_level", %{
      lua: lua
    } do
      log =
        ExUnit.CaptureLog.capture_log(
          [level: :debug, metadata: [:original_level]],
          fn ->
            Lua.eval!(lua, "return platform.log('bogus_level', 'weird', nil)")
          end
        )

      assert log =~ "[info]"
      assert log =~ "original_level=bogus_level"
    end

    test "never raises for malformed argument shapes", %{lua: lua} do
      ExUnit.CaptureLog.capture_log(fn ->
        assert {[], _lua} = Lua.eval!(lua, "return platform.log(42, nil)")
        assert {[], _lua} = Lua.eval!(lua, "return platform.log()")
      end)
    end
  end

  describe "REQ-159: platform.log -- capability denial (AC4)" do
    test "raises a capability denial for audit:log" do
      lua = Platform.install(Sandbox.new(), Capabilities.new(), execution_context())

      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.log('info', 'x', nil)")
        end

      assert exception.original[:function] == :log
      assert exception.original[:capability_required] == "audit:log"
    end
  end

  # ---------------------------------------------------------------------------------
  # Matrix/stub-tag regression guards
  # ---------------------------------------------------------------------------------

  describe "REQ-159: matrix/stub-tag regression guards" do
    test "required capability strings for the 3 edited rows are unchanged" do
      matrix = Platform.capability_matrix()

      assert Enum.find(matrix, &(&1.name == :read_variable)).required == "variable:read"
      assert Enum.find(matrix, &(&1.name == :get_instance_state)).required == "instance:read"
      assert Enum.find(matrix, &(&1.name == :log)).required == "audit:log"
    end

    test "write_variable, call_service, emit_event are real (REQ-160) -- none raises when granted" do
      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["variable:write", "service:call:x", "event:emit"]),
          execution_context()
        )

      assert {[], _lua} = Lua.eval!(lua, "return platform.write_variable('x', 'y')")

      assert {[nil, "service_caller_not_configured"], _lua} =
               Lua.eval!(lua, """
               local r, err = platform.call_service('x')
               return r, err.reason
               """)

      assert {[nil, "no_execution_context"], _lua} =
               Lua.eval!(lua, """
               local r, err = platform.emit_event('evt', nil, 'idem-1')
               return r, err.reason
               """)
    end

    test "now and fail remain callable with an empty grant set, unaffected by execution_context" do
      lua = Platform.install(Sandbox.new(), Capabilities.new(), execution_context())

      assert {[result], _lua} = Lua.eval!(lua, "return platform.now()")
      assert is_binary(result)

      task =
        Task.Supervisor.async_nolink(Letflow.Engine.Lua.TaskSupervisor, fn ->
          Lua.eval!(lua, "return platform.fail()")
        end)

      assert {:exit, {:script_failed, %{reason: _, details: nil}}} = Task.yield(task, 1_000)
    end
  end

  # ---------------------------------------------------------------------------------
  # install/1, install/2 backward compatibility
  # ---------------------------------------------------------------------------------

  describe "REQ-159: install/1, install/2 backward compatibility" do
    test "a granted call to read_variable through install/2 (empty context) returns nil, not a crash" do
      lua = Platform.install(Sandbox.new(), Capabilities.new(["variable:read"]))

      assert {[nil], _lua} = Lua.eval!(lua, "return platform.read_variable('x')")
    end

    test "a granted call to get_instance_state through install/2 (empty context) returns the structured no_execution_context error" do
      lua = Platform.install(Sandbox.new(), Capabilities.new(["instance:read"]))

      script = """
      local state, err = platform.get_instance_state('#{Ecto.UUID.generate()}')
      return state, err.reason
      """

      assert {[nil, "no_execution_context"], _lua} = Lua.eval!(lua, script)
    end

    test "a granted call to log through install/2 (empty context) still emits an entry with nil correlation fields" do
      lua = Platform.install(Sandbox.new(), Capabilities.new(["audit:log"]))

      log =
        ExUnit.CaptureLog.capture_log(
          [metadata: [:script_identity, :instance_id, :trace_id]],
          fn ->
            assert {[], _lua} = Lua.eval!(lua, "return platform.log('info', 'msg', nil)")
          end
        )

      assert log =~ "msg"
    end

    test "install/1 (production default) exposes all 8 names with an empty execution context, unaffected" do
      lua = Sandbox.new()

      assert {[nil], _lua} =
               Lua.eval!(
                 Platform.install(lua, Capabilities.new(["variable:read"])),
                 "return platform.read_variable('anything')"
               )
    end
  end

  # ---------------------------------------------------------------------------------
  # Structural guard: no Repo call in this diff uses a prefix derived from
  # script-supplied input (REQ-159 AC7) -- mirrors REQ-157's own single-Lua.set!
  # source-level guard.
  # ---------------------------------------------------------------------------------

  describe "REQ-159: structural guard -- Repo.get/3's prefix is always execution_context.prefix" do
    test "platform.ex's only Repo call site passes prefix: execution_context's own prefix, never a script-supplied value" do
      source = File.read!("lib/letflow/engine/lua/platform.ex")

      repo_call_occurrences =
        ~r/Repo\.get\(/
        |> Regex.scan(source)
        |> length()

      assert repo_call_occurrences == 1

      assert source =~ "Repo.get(InstanceProjection, instance_id, prefix: prefix)"

      # `prefix` at that call site is only ever bound from
      # `execution_context.prefix` (fetch_instance_state/3's own parameter, itself
      # only ever called with `execution_context.prefix`) -- never from the Lua
      # call's own argument list (`raw_id`/`instance_id`).
      assert source =~ "fetch_instance_state(instance_id, execution_context.prefix, lua)"
      refute source =~ "prefix: raw_id"
      refute source =~ "prefix: instance_id"
    end
  end

  # =====================================================================================
  # REQ-160 -- lib/letflow/design/req160-lua-host-api-write.md
  # =====================================================================================

  defmodule FakeServiceCaller do
    @moduledoc false
    @behaviour Platform.ServiceCaller

    @impl Platform.ServiceCaller
    def call("billing", %{"amount" => amount}), do: {:ok, %{"charged" => amount}}
    def call("billing", _payload), do: {:error, :bad_payload}
    def call(_service_id, _payload), do: {:error, :unknown_service}
  end

  # Mutation-testing finding (TEST-DESIGNER, REQ-160 Step 3): reordering `install/3`'s
  # fold wrapper so `run_stub/5` executes BEFORE `Capabilities.check!/3` (instead of
  # after), while leaving `check!/3`'s own raise in place afterward, left every
  # pre-existing test in this file passing (82/82) -- every capability-denial test here
  # only asserts that SOME `Lua.RuntimeException` was eventually raised, never that the
  # stub body was never entered. A spy `ServiceCaller` that records whether it was ever
  # invoked closes this gap for `call_service` specifically (design §4.3's own "a denied
  # call never reaches this function's body" claim).
  defmodule SpyServiceCaller do
    @moduledoc false
    @behaviour Platform.ServiceCaller

    @impl Platform.ServiceCaller
    def call(service_id, payload) do
      # `call_service` runs synchronously inline in the calling (test) process --
      # `Lua.eval!/2` does not spawn a separate process -- so `self()` here IS the test
      # process that will assert on this mailbox.
      send(self(), {:spy_service_caller_called, service_id, payload})
      {:ok, %{}}
    end
  end

  defp put_service_caller!(module) do
    previous = Application.get_env(:letflow, :lua_platform_service_caller)
    Application.put_env(:letflow, :lua_platform_service_caller, module)

    on_exit(fn ->
      if previous do
        Application.put_env(:letflow, :lua_platform_service_caller, previous)
      else
        Application.delete_env(:letflow, :lua_platform_service_caller)
      end
    end)

    :ok
  end

  # Registers a minimal, permissive event type (accepts any JSON object) so
  # `Registry.validate_payload/3` passes -- mirrors event_store_test.exs's own
  # `register_event_type!/2` fixture.
  defp register_event_type!(tenant_id, json_schema \\ %{"type" => "object"}) do
    name = "req160_evt_" <> to_string(System.unique_integer([:positive, :monotonic]))

    assert {:ok, _event_type} =
             Letflow.EventStore.Registry.register_type(
               %{
                 "name" => name,
                 "schema_version" => 1,
                 "json_schema" => json_schema,
                 "description" => "REQ-160 test fixture"
               },
               tenant_id
             )

    name
  end

  # ---------------------------------------------------------------------------------
  # platform.write_variable -- staging, accumulation, discard-on-failure (AC1, AC2)
  # ---------------------------------------------------------------------------------

  describe "REQ-160: platform.write_variable stages into a process-local buffer" do
    test "a single write is retrievable via take_staged_writes/0 (AC2)" do
      lua =
        Platform.install(Sandbox.new(), Capabilities.new(["variable:write"]), execution_context())

      assert {[], _lua} = Lua.eval!(lua, "return platform.write_variable('x', 42)")
      assert Platform.take_staged_writes() == %{"x" => 42}
    end

    test "several writes in one script accumulate, last-write-wins on a duplicate key, no partial state (AC2)" do
      lua =
        Platform.install(Sandbox.new(), Capabilities.new(["variable:write"]), execution_context())

      script = """
      platform.write_variable('a', 1)
      platform.write_variable('b', 2)
      platform.write_variable('a', 3)
      return true
      """

      assert {[true], _lua} = Lua.eval!(lua, script)
      assert Platform.take_staged_writes() == %{"a" => 3, "b" => 2}
    end

    test "take_staged_writes/0 clears the buffer -- a second call observes an empty map" do
      lua =
        Platform.install(Sandbox.new(), Capabilities.new(["variable:write"]), execution_context())

      assert {[], _lua} = Lua.eval!(lua, "return platform.write_variable('x', 1)")
      assert Platform.take_staged_writes() == %{"x" => 1}
      assert Platform.take_staged_writes() == %{}
    end

    test "a script execution that never calls write_variable leaves an empty buffer" do
      assert Platform.take_staged_writes() == %{}
    end

    test "a malformed (non-string) name is a no-op -- returns nil, stages nothing" do
      lua =
        Platform.install(Sandbox.new(), Capabilities.new(["variable:write"]), execution_context())

      assert {[nil], _lua} = Lua.eval!(lua, "return platform.write_variable(42, 'y')")
      assert Platform.take_staged_writes() == %{}
    end

    test "round-trips an integer AND a float via LuaNumberMarshalling.from_lua/1 (AC6)" do
      lua =
        Platform.install(Sandbox.new(), Capabilities.new(["variable:write"]), execution_context())

      script = """
      platform.write_variable('int_var', 3)
      platform.write_variable('float_var', 3.0)
      return true
      """

      assert {[true], _lua} = Lua.eval!(lua, script)
      assert %{"int_var" => 3, "float_var" => 3.0} = Platform.take_staged_writes()
    end

    test "a script that writes then raises leaves the buffer un-drained by anything in platform.ex itself (AC1)" do
      lua =
        Platform.install(Sandbox.new(), Capabilities.new(["variable:write"]), execution_context())

      script = """
      platform.write_variable('x', 1)
      error('boom')
      """

      assert_raise Lua.RuntimeException, fn -> Lua.eval!(lua, script) end

      # The buffer still exists in THIS process's dictionary (nothing here proves it was
      # "discarded" by magic) -- the discard guarantee (AC1) is that no code path in
      # platform.ex itself ever reads this out and forwards it anywhere on a failure
      # path (see the structural guard test below); a killed/crashed process's own
      # process dictionary is destroyed with the process (design §2.2/2.3), which this
      # module has no code path that could circumvent.
      assert Platform.take_staged_writes() == %{"x" => 1}
    end

    # TEST-DESIGN-VALIDATOR rework (handoffs/WF02-REQ160-20260827/step-03-test-designer-rework1.json,
    # fix 1): the raised-error test above only proves the SAME process's buffer is
    # untouched -- it does not exercise REQ-154/155/156's three harder failure arms
    # AC1's own text names by name, nor does it prove the write is unobservable from any
    # OTHER process. Each test below drives the real REQ-154/155/156 mechanism (mirroring
    # test/letflow/engine/lua/executor_test.exs's own harness for each) against a script
    # that first stages a write via `platform.write_variable`, then asserts THIS (test)
    # process's own `take_staged_writes/0` -- a process wholly distinct from whichever
    # process actually ran the script -- returns an empty map. Process dictionaries are
    # strictly per-process (never inherited, copied, or merged across processes by the
    # BEAM), so this is not an inference: it is a direct observation that the staged
    # write never reached anywhere outside the process that died/raised.
    test "REQ-154's instruction-budget exhaustion discards the staged write -- never observed from any other process (AC1)" do
      lua =
        Platform.install(
          Sandbox.new(max_instructions: 500),
          Capabilities.new(["variable:write"]),
          execution_context()
        )

      script = """
      platform.write_variable('x', 1)
      while true do end
      """

      test_pid = self()

      task =
        Task.async(fn ->
          outcome =
            try do
              Lua.eval!(lua, script)
              :did_not_raise
            rescue
              e in Lua.RuntimeException -> {:raised, Exception.message(e)}
            end

          # Read from INSIDE the process that ran the script -- confirms the write did
          # reach the staging buffer (so the assertion below is a genuine cross-process
          # discard, not a script that never staged anything in the first place).
          send(test_pid, {:budget_task_result, outcome, Platform.take_staged_writes()})
        end)

      Task.await(task)

      assert_receive {:budget_task_result, {:raised, message}, staged_inside_task_process}
      assert message =~ "instruction budget exceeded"
      assert staged_inside_task_process == %{"x" => 1}

      # This (test) process is a DIFFERENT process from the one that ran the script --
      # its own take_staged_writes/0 must never observe the write.
      assert Platform.take_staged_writes() == %{}
    end

    test "REQ-155's wall-clock kill discards the staged write -- the killed process's buffer is simply gone (AC1)" do
      lua =
        Platform.install(
          Sandbox.new(max_instructions: 1_000_000_000),
          Capabilities.new(["variable:write"]),
          execution_context()
        )

      script = """
      platform.write_variable('x', 1)
      while true do end
      """

      # Mirrors executor_test.exs's own REQ-155 harness (Task.async -> Task.yield ->
      # Task.shutdown(task, :brutal_kill) on a nil yield) rather than inventing a new
      # mechanism.
      task = Task.async(fn -> Lua.eval!(lua, script) end)

      assert Task.yield(task, 150) == nil,
             "the infinite loop must not have returned within the wall-clock window"

      Task.shutdown(task, :brutal_kill)

      # The process is genuinely dead -- not merely abandoned -- so its process
      # dictionary (where the staged write lived) no longer exists anywhere to read.
      refute Process.alive?(task.pid)

      assert Platform.take_staged_writes() == %{},
             "no other process (including this test process) ever observed the write " <>
               "the killed process staged"
    end

    test "REQ-156's memory-limit kill discards the staged write -- the killed process's buffer is simply gone (AC1)" do
      lua =
        Platform.install(
          Sandbox.new(max_instructions: 1_000_000_000),
          Capabilities.new(["variable:write"]),
          execution_context()
        )

      script = """
      platform.write_variable('x', 1)
      local t = {}
      for i = 1, 1000000 do
        t[i] = string.rep('x', 1024)
      end
      return #t
      """

      # Mirrors executor_test.exs's own REQ-156 harness: Task.Supervisor/Task.async
      # cannot carry a max_heap_size spawn_opt, so the script runs in a process spawned
      # directly via :erlang.spawn_opt/2 with :monitor plus max_heap_size: kill: true --
      # the same mechanism lib/letflow/engine/lua/executor.ex's run_with_heap_limit/4
      # uses.
      small_heap_words = trunc(1 * 1024 * 1024 / :erlang.system_info(:wordsize))
      parent = self()

      {pid, monitor_ref} =
        :erlang.spawn_opt(
          fn -> send(parent, {:heap_task_done, Lua.eval!(lua, script)}) end,
          [:monitor, max_heap_size: %{size: small_heap_words, kill: true, error_logger: false}]
        )

      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, :killed}, 5_000

      refute_received {:heap_task_done, _}
      refute Process.alive?(pid)

      assert Platform.take_staged_writes() == %{},
             "no other process (including this test process) ever observed the write " <>
               "the memory-limit-killed process staged"
    end

    test "REQ-160/AC2: VariableMerge.merge/3 applies all staged writes atomically in a single call (design §2.6)" do
      lua =
        Platform.install(Sandbox.new(), Capabilities.new(["variable:write"]), execution_context())

      script = """
      platform.write_variable('a', 1)
      platform.write_variable('b', 2)
      platform.write_variable('c', 3)
      return true
      """

      assert {[true], _lua} = Lua.eval!(lua, script)
      staged = Platform.take_staged_writes()
      assert map_size(staged) == 3

      # There is no intermediate call, no partial map, and no way to observe a state
      # with only one or two of the three keys applied -- merge/3 is a single,
      # non-yielding function call over the WHOLE staged map at once.
      assert {:ok, new_variables, events} = VariableMerge.merge(%{}, staged, nil)
      assert %{"a" => 1, "b" => 2, "c" => 3} = new_variables
      assert is_list(events)
    end

    test "write_variable makes zero Repo calls (AC7)" do
      lua =
        Platform.install(Sandbox.new(), Capabilities.new(["variable:write"]), execution_context())

      handler_id = {__MODULE__, :write_variable_query_counter, make_ref()}
      counter = :counters.new(1, [])

      :telemetry.attach(
        handler_id,
        [:letflow, :repo, :query],
        fn _event, _measurements, _metadata, _config -> :counters.add(counter, 1, 1) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {[], _lua} = Lua.eval!(lua, "return platform.write_variable('x', 1)")
      assert :counters.get(counter, 1) == 0
    end

    test "capability denial for variable:write, unaffected by execution_context (AC4-analogue)" do
      lua = Platform.install(Sandbox.new(), Capabilities.new(), execution_context())

      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.write_variable('x', 1)")
        end

      assert exception.original[:function] == :write_variable
      assert exception.original[:capability_required] == "variable:write"
    end
  end

  describe "REQ-160: structural guard -- take_staged_writes/0 is never called from inside platform.ex itself" do
    test "platform.ex's source has zero call sites of take_staged_writes() other than its own @spec/def lines (AC1)" do
      source = File.read!("lib/letflow/engine/lua/platform.ex")

      # The function is defined with `def take_staged_writes do` (no parens, 0-arity) --
      # any actual CALL site would use parens: `take_staged_writes()`. Excluding this
      # function's own `@spec`/`def` lines (which also spell the name with parens as
      # part of their signature, not a call), zero occurrences of the call pattern
      # proves no code path in this module (including every write_variable/run_stub/
      # install path) ever reads the buffer out itself; only an external caller
      # (deliberately out of scope for this requirement, design §2.5 OQ-1) can ever
      # invoke it.
      call_site_lines =
        source
        |> String.split("\n")
        |> Enum.reject(fn line ->
          String.starts_with?(String.trim(line), "@spec take_staged_writes") or
            String.starts_with?(String.trim(line), "def take_staged_writes")
        end)
        |> Enum.filter(&(&1 =~ "take_staged_writes()"))

      assert call_site_lines == []
    end
  end

  # ---------------------------------------------------------------------------------
  # platform.call_service -- round trip (AC3), failure vs. missing-capability (AC4)
  # ---------------------------------------------------------------------------------

  describe "REQ-160: platform.call_service -- round trip through an injected ServiceCaller (AC3)" do
    setup do
      put_service_caller!(FakeServiceCaller)
      :ok
    end

    test "a successful call returns the response as a Lua table readable from inside the script" do
      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["service:call:billing"]),
          execution_context()
        )

      script = """
      local response = platform.call_service('billing', {amount = 100})
      return response.charged
      """

      assert {[100], _lua} = Lua.eval!(lua, script)
    end

    test "an integer/float payload round-trips via LuaNumberMarshalling (AC6)" do
      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["service:call:billing"]),
          execution_context()
        )

      script = """
      local response = platform.call_service('billing', {amount = 2.5})
      return math.type(response.charged), response.charged
      """

      assert {["float", 2.5], _lua} = Lua.eval!(lua, script)
    end
  end

  # TEST-DESIGN-VALIDATOR rework (handoffs/WF02-REQ160-20260827/step-03-test-designer-rework1.json,
  # fix 3): the AC6 test above only proves the READ direction (`to_lua/1` on the
  # response). Spec section 6's second bullet also requires a WRITE-direction
  # assertion -- the double must assert directly on the Elixir-side types
  # (`is_integer/1`/`is_float/1`) of what it actually received, not merely on a value
  # that survived a round trip back through Lua. `SpyServiceCaller` (already defined
  # above for the mutation-testing gap on capability-gate ordering) already captures
  # its raw received payload via `send/2` -- reused here for its actual received-types
  # shape instead of inventing a second double.
  describe "REQ-160: platform.call_service -- write-direction marshalling (AC6)" do
    setup do
      put_service_caller!(SpyServiceCaller)
      :ok
    end

    test "the double receives real Elixir integer()/float() types for an integer- and a whole-number-float-valued argument, not collapsed" do
      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["service:call:billing"]),
          execution_context()
        )

      script = """
      platform.call_service('billing', {amount = 7, rate = 2.0})
      return true
      """

      assert {[true], _lua} = Lua.eval!(lua, script)

      assert_received {:spy_service_caller_called, "billing", payload}

      assert is_integer(payload["amount"])
      assert payload["amount"] == 7

      assert is_float(payload["rate"])
      assert payload["rate"] == 2.0
    end
  end

  describe "REQ-160: platform.call_service -- failure returns a structured error, never raises (AC4)" do
    setup do
      put_service_caller!(FakeServiceCaller)
      :ok
    end

    test "a service-side failure returns [nil, error_table], not a raise" do
      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["service:call:billing"]),
          execution_context()
        )

      script = """
      local response, err = platform.call_service('billing', {wrong_key = 1})
      return response, err.reason
      """

      assert {[nil, "bad_payload"], _lua} = Lua.eval!(lua, script)
    end

    test "an invalid (non-string) service_id argument returns a structured error, not a raise" do
      # `required_capability/2`'s `:call_service_arg0` resolution for a non-binary
      # first arg falls back to `service_capability("")` (`"service:call:"`) -- grant
      # exactly that so the call passes the gate and reaches the real body, exercising
      # the "invalid_arguments" structured-return path specifically, not the gate.
      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["service:call:"]),
          execution_context()
        )

      script = """
      local response, err = platform.call_service(42, {})
      return response, err.reason
      """

      assert {[nil, "invalid_arguments"], _lua} = Lua.eval!(lua, script)
    end

    test "the default NoServiceCaller returns service_caller_not_configured when nothing is injected" do
      Application.delete_env(:letflow, :lua_platform_service_caller)

      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["service:call:anything"]),
          execution_context()
        )

      script = """
      local response, err = platform.call_service('anything', {})
      return response, err.reason
      """

      assert {[nil, "service_caller_not_configured"], _lua} = Lua.eval!(lua, script)
    end
  end

  describe "REQ-160: call_service -- missing capability raises; is a genuinely distinct path from a service failure (AC4)" do
    test "a MISSING service:call:<id> capability raises via the fold-level gate, never reaching call_service's body" do
      put_service_caller!(FakeServiceCaller)

      lua = Platform.install(Sandbox.new(), Capabilities.new(), execution_context())

      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.call_service('billing', {amount = 1})")
        end

      # Distinguishing field: a capability denial carries `capability_required`; a
      # service-call failure (asserted separately above) never raises at all, so it
      # could never carry this field either way -- these are structurally two
      # different outcomes (raise vs. return), not merely two different messages.
      assert exception.original[:function] == :call_service
      assert exception.original[:capability_required] == "service:call:billing"
    end

    test "call_service makes zero Repo calls (AC7)" do
      put_service_caller!(FakeServiceCaller)

      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["service:call:billing"]),
          execution_context()
        )

      handler_id = {__MODULE__, :call_service_query_counter, make_ref()}
      counter = :counters.new(1, [])

      :telemetry.attach(
        handler_id,
        [:letflow, :repo, :query],
        fn _event, _measurements, _metadata, _config -> :counters.add(counter, 1, 1) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {[100], _lua} =
               Lua.eval!(lua, "return platform.call_service('billing', {amount = 100}).charged")

      assert :counters.get(counter, 1) == 0
    end

    # Mutation-testing finding (TEST-DESIGNER, REQ-160 Step 3): reordering `install/3`'s
    # fold wrapper to run `run_stub/5` BEFORE `Capabilities.check!/3` (rather than
    # after) leaves every pre-existing capability-denial test in this file passing,
    # because `check!/3`'s raise still eventually happens -- it just happens too late,
    # after the stub body already ran. `SpyServiceCaller` proves the body was never
    # entered at all for a denied call, closing that gap directly (design §4.3).
    test "a MISSING capability means the ServiceCaller spy is never invoked at all" do
      put_service_caller!(SpyServiceCaller)

      lua = Platform.install(Sandbox.new(), Capabilities.new(), execution_context())

      assert_raise Lua.RuntimeException, fn ->
        Lua.eval!(lua, "return platform.call_service('billing', {amount = 1})")
      end

      refute_received {:spy_service_caller_called, _service_id, _payload}
    end
  end

  # ---------------------------------------------------------------------------------
  # platform.emit_event -- real EventStore.append/2 hook (AC5), structured errors,
  # tenant-prefix discipline (AC7)
  # ---------------------------------------------------------------------------------

  describe "REQ-160: platform.emit_event -- granted, hooks into the real EventStore.append/2 (AC5)" do
    setup do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      event_type = register_event_type!(tenant_id)
      instance_id = Ecto.UUID.generate()
      actor_id = Ecto.UUID.generate()

      seed_projection!(schema_name, instance_id)

      %{
        schema_name: schema_name,
        instance_id: instance_id,
        actor_id: actor_id,
        event_type: event_type
      }
    end

    test "a granted emit_event call succeeds and the event is observable via a direct read", %{
      schema_name: schema_name,
      instance_id: instance_id,
      actor_id: actor_id,
      event_type: event_type
    } do
      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["event:emit"]),
          execution_context(%{instance_id: instance_id, prefix: schema_name, actor_id: actor_id})
        )

      script = """
      return platform.emit_event('#{event_type}', {reason = 'test'}, 'idem-req160-1')
      """

      assert {[true], _lua} = Lua.eval!(lua, script)

      assert {:ok, [event]} = Letflow.EventStore.read(instance_id, prefix: schema_name)
      assert event.event_type == event_type
      assert event.actor_id == actor_id
      assert event.payload["reason"] == "test"
    end

    test "an unknown event_type returns a structured error, never raises", %{
      instance_id: instance_id,
      schema_name: schema_name,
      actor_id: actor_id
    } do
      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["event:emit"]),
          execution_context(%{instance_id: instance_id, prefix: schema_name, actor_id: actor_id})
        )

      script = """
      local ok, err = platform.emit_event('nonexistent_event_type', nil, 'idem-req160-2')
      return ok, err.reason
      """

      assert {[nil, "unknown_event_type"], _lua} = Lua.eval!(lua, script)
    end

    test "emit_event's one Repo call always uses execution_context.prefix, never a script-supplied argument (AC7)",
         %{
           schema_name: schema_name,
           instance_id: instance_id,
           actor_id: actor_id,
           event_type: event_type
         } do
      source = File.read!("lib/letflow/engine/lua/platform.ex")

      # GH #2707 PR-2: the call also carries the cold-append `lock_timeout_ms:` option; the prefix
      # is still, and only, `execution_context.prefix`.
      assert source =~ ~r/EventStore\.append\(attrs,\s*prefix: execution_context\.prefix,/
      refute source =~ "prefix: event_type"
      refute source =~ "prefix: idempotency_key"

      # Functional confirmation: the real, provisioned tenant schema (never a
      # script-supplied value) is genuinely what gets used -- the call succeeds
      # against it.
      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["event:emit"]),
          execution_context(%{instance_id: instance_id, prefix: schema_name, actor_id: actor_id})
        )

      script = """
      return platform.emit_event('#{event_type}', nil, 'idem-req160-3')
      """

      assert {[true], _lua} = Lua.eval!(lua, script)
    end
  end

  describe "REQ-160: platform.emit_event -- missing execution context fields (AC5-adjacent)" do
    test "nil actor_id (populated context otherwise) returns no_execution_context, no EventStore call attempted" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      seed_projection!(schema_name, instance_id)

      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["event:emit"]),
          execution_context(%{instance_id: instance_id, prefix: schema_name, actor_id: nil})
        )

      script = """
      local ok, err = platform.emit_event('whatever', nil, 'idem-req160-4')
      return ok, err.reason
      """

      assert {[nil, "no_execution_context"], _lua} = Lua.eval!(lua, script)
    end

    test "empty-context sentinel returns no_execution_context, unaffected by which args are passed" do
      lua = Platform.install(Sandbox.new(), Capabilities.new(["event:emit"]), execution_context())

      script = """
      local ok, err = platform.emit_event('whatever', nil, 'idem-req160-5')
      return ok, err.reason
      """

      assert {[nil, "no_execution_context"], _lua} = Lua.eval!(lua, script)
    end

    test "an invalid (non-string) idempotency_key argument returns invalid_arguments, not no_execution_context" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      actor_id = Ecto.UUID.generate()
      seed_projection!(schema_name, instance_id)

      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["event:emit"]),
          execution_context(%{instance_id: instance_id, prefix: schema_name, actor_id: actor_id})
        )

      script = """
      local ok, err = platform.emit_event('whatever', nil, 42)
      return ok, err.reason
      """

      assert {[nil, "invalid_arguments"], _lua} = Lua.eval!(lua, script)
    end
  end

  describe "REQ-160: emit_event -- capability denial is distinct from a granted call's failure (AC5)" do
    test "a MISSING event:emit capability raises via the fold-level gate" do
      lua = Platform.install(Sandbox.new(), Capabilities.new(), execution_context())

      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.emit_event('evt', nil, 'idem')")
        end

      assert exception.original[:function] == :emit_event
      assert exception.original[:capability_required] == "event:emit"
    end

    # Mutation-testing finding (TEST-DESIGNER, REQ-160 Step 3), mirrors the equivalent
    # `call_service` spy test above: a fully populated `execution_context` (prefix,
    # instance_id, actor_id all set, a real registered event type) is used here
    # specifically so that IF `run_stub/5` were reordered ahead of `Capabilities.check!/3`,
    # `do_emit_event/3` would actually reach `EventStore.append/2` (a real `Repo` call) --
    # an empty execution context would not distinguish the two orderings, since
    # `do_emit_event/3`'s own "no_execution_context" short-circuit would make it look
    # like the body was never entered either way. The telemetry counter proves zero
    # `Repo` queries fire for a denied call with a context that WOULD otherwise reach
    # `Repo`.
    test "a MISSING capability means EventStore.append/2 is never reached (Repo-query spy)" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      event_type = register_event_type!(tenant_id)
      instance_id = Ecto.UUID.generate()
      actor_id = Ecto.UUID.generate()
      seed_projection!(schema_name, instance_id)

      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(),
          execution_context(%{instance_id: instance_id, prefix: schema_name, actor_id: actor_id})
        )

      handler_id = {__MODULE__, :emit_event_denial_query_counter, make_ref()}
      counter = :counters.new(1, [])

      :telemetry.attach(
        handler_id,
        [:letflow, :repo, :query],
        fn _event, _measurements, _metadata, _config -> :counters.add(counter, 1, 1) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert_raise Lua.RuntimeException, fn ->
        Lua.eval!(lua, "return platform.emit_event('#{event_type}', nil, 'idem-spy-1')")
      end

      assert :counters.get(counter, 1) == 0
    end
  end

  describe "REQ-160: matrix regression guard" do
    test "the 3 edited rows carry their new stub tags; required capabilities unchanged" do
      matrix = Platform.capability_matrix()

      assert Enum.find(matrix, &(&1.name == :write_variable)) ==
               %{name: :write_variable, required: "variable:write", stub: :write_variable}

      assert Enum.find(matrix, &(&1.name == :call_service)) ==
               %{name: :call_service, required: :call_service_arg0, stub: :call_service}

      assert Enum.find(matrix, &(&1.name == :emit_event)) ==
               %{name: :emit_event, required: "event:emit", stub: :emit_event}
    end
  end

  # ---------------------------------------------------------------------------------
  # Structural guard: LuaNumberMarshalling call sites (AC6) genuinely present.
  # ---------------------------------------------------------------------------------

  # Mutation-testing finding (TEST-DESIGNER, REQ-160 Step 3):
  # `LuaNumberMarshalling.from_lua/1` and `.to_lua/1` are BOTH literal identity
  # functions (`def from_lua(value), do: value` / `def to_lua(value), do: value`,
  # `lib/letflow/engine/lua_number_marshalling.ex`, REQ-150 §2.1/§2.2's own normative
  # rule). Because of that, deleting a call to either one from any REQ-160 call site
  # (`do_write_variable/2`, `do_call_service/3`, `normalize_from_lua/1`,
  # `convert_map_to_lua/1`) produces IDENTICAL runtime behavior for every input,
  # including a whole-number float -- confirmed directly: removing
  # `LuaNumberMarshalling.from_lua/1` from `do_write_variable/2`'s call site left every
  # one of this file's 84 tests passing (84/84), even the float-specific round-trip
  # test. No behavioral test, of any input shape, can ever catch this mutation --
  # REQ-150's own identity rule makes it structurally undetectable at the value level.
  # The only test that CAN catch "a call site quietly stopped routing through the
  # named module/function" (REQ-150 §3's actual requirement -- not "the value must
  # come out unchanged," but "every numeric-touching call site must use this one named
  # conversion, not invent its own") is a structural/source-level one, mirroring this
  # file's own established convention for the Repo-prefix and single-Lua.set!
  # invariants above.
  describe "REQ-160: structural guard -- LuaNumberMarshalling call sites are genuinely present" do
    test "every REQ-160 numeric-crossing call site routes through LuaNumberMarshalling.from_lua/1 or .to_lua/1 by name" do
      source = File.read!("lib/letflow/engine/lua/platform.ex")

      # write_variable (write direction)
      assert source =~ "stage_write(name, LuaNumberMarshalling.from_lua(value))"

      # call_service / emit_event payload decoding (write direction, one level deep)
      assert source =~
               "Map.new(value, fn {key, v} -> {key, LuaNumberMarshalling.from_lua(v)} end)"

      assert source =~ "defp normalize_from_lua(value), do: LuaNumberMarshalling.from_lua(value)"

      # call_service response encoding (read direction, one level deep)
      assert source =~
               "Map.new(map, fn {key, value} -> {key, LuaNumberMarshalling.to_lua(value)} end)"

      assert source =~ "defp convert_map_to_lua(other), do: LuaNumberMarshalling.to_lua(other)"

      # Total occurrence count is a floor, not just individual substrings -- guards
      # against a future edit that keeps these exact strings elsewhere (e.g. in a
      # comment) while deleting the real call.
      from_lua_call_sites =
        ~r/LuaNumberMarshalling\.from_lua\(/ |> Regex.scan(source) |> length()

      to_lua_call_sites = ~r/LuaNumberMarshalling\.to_lua\(/ |> Regex.scan(source) |> length()

      assert from_lua_call_sites >= 3
      assert to_lua_call_sites >= 3
    end
  end

  # ---------------------------------------------------------------------------------
  # REQ-161 (LUA-15 restated): platform.fail terminates uninterceptably
  # ---------------------------------------------------------------------------------
  #
  # Every test in this section asserts at the RAW Task/process boundary -- never
  # through `Letflow.Engine.Lua.Executor.execute_with_manifest/2,3` -- because the
  # design's own §4 documents that `Executor`'s `handle_yield_result/3` stringifies any
  # non-`:killed` exit reason (including a deliberate `{:script_failed, _}` one) via
  # `format_exit_reason/1` before it ever reaches an `Executor` caller. Asserting through
  # `Executor` would prove nothing about the pattern-matchability this requirement's own
  # acceptance criteria require.
  describe "REQ-161: platform.fail terminates by exit/1, not by a pcall-catchable raise" do
    # `Task.async/1` LINKS the new process to the caller -- an abnormal exit from a
    # linked, non-trapping process would crash this test process too. Every test below
    # therefore submits its script via `Task.Supervisor.async_nolink/2` against the same
    # `Letflow.Engine.Lua.TaskSupervisor` production code already uses
    # (`Letflow.Engine.Lua.Executor`'s `:max_heap_words == nil` path), exactly mirroring
    # the real, shipped mechanism rather than inventing a test-only one.
    defp async_fail(fun) do
      Task.Supervisor.async_nolink(Letflow.Engine.Lua.TaskSupervisor, fun)
    end

    test "AC1: a script that wraps platform.fail in pcall and continues STILL yields SCRIPT_FAILED and does not run to completion" do
      script = """
      local ok, err = pcall(function()
        platform.fail("boom")
      end)

      -- If pcall could actually catch this, execution would reach here and this
      -- return would be observed by the caller. It must never be observed.
      return "script continued past pcall -- REQ-161 REGRESSION"
      """

      task = async_fail(fn -> Lua.eval!(Sandbox.new(), script) end)

      assert {:exit, {:script_failed, %{reason: "boom", details: nil}}} =
               Task.yield(task, 1_000)
    end

    test "AC2: the structured failure carries the reason/details the script passed, readable by the host" do
      script = """
      platform.fail("bad input", {code = 42, note = "x"})
      """

      task = async_fail(fn -> Lua.eval!(Sandbox.new(), script) end)

      assert {:exit, {:script_failed, %{reason: "bad input", details: details}}} =
               Task.yield(task, 1_000)

      assert details["code"] == 42
      assert details["note"] == "x"
    end

    test "AC2: a missing reason/details pair defaults to the documented fallback string and nil" do
      task = async_fail(fn -> Lua.eval!(Sandbox.new(), "platform.fail()") end)

      assert {:exit, {:script_failed, %{reason: reason, details: nil}}} = Task.yield(task, 1_000)
      assert reason == "script called platform.fail with no reason"
    end

    test "AC3: {:script_failed, _} is pattern-match-distinguishable from a real, unrelated crash" do
      fail_task = async_fail(fn -> Lua.eval!(Sandbox.new(), "platform.fail('deliberate')") end)
      assert {:exit, fail_reason} = Task.yield(fail_task, 1_000)
      assert match?({:script_failed, %{reason: "deliberate", details: nil}}, fail_reason)

      # A genuine uncaught Lua runtime error -- NOT a `platform.fail` call at all --
      # propagates out of `Lua.eval!/2` as a raised `Lua.RuntimeException`, which Task
      # reports as an `{:exit, {exception, stacktrace}}` tuple, never as `:exit/1`.
      crash_task = async_fail(fn -> Lua.eval!(Sandbox.new(), "error('boom')") end)
      assert {:exit, crash_reason} = Task.yield(crash_task, 1_000)
      refute match?({:script_failed, _}, crash_reason)
      assert {%Lua.RuntimeException{}, _stacktrace} = crash_reason

      # A forcibly killed process -- the other real crash shape `executor.ex` already
      # handles specially (`:killed`, the BEAM-reserved rewrite of `exit(pid, :kill)`).
      killed_task = async_fail(fn -> Process.sleep(:infinity) end)
      Process.exit(killed_task.pid, :kill)
      # bound, not a literal: matching a literal :killed is a compile-time "clause will never
      # match" type warning, which aborts `mix test --warnings-as-errors` (GH #2587 A1).
      assert {:exit, killed_reason} = Task.yield(killed_task, 1_000)
      assert killed_reason == :killed
      refute match?({:script_failed, _}, killed_reason)
    end

    test "AC4: platform.fail is callable with an EMPTY capability grant set and still terminates the process" do
      lua = Platform.install(Sandbox.new(), Capabilities.new())

      task = async_fail(fn -> Lua.eval!(lua, "platform.fail('no capability needed')") end)

      assert {:exit, {:script_failed, %{reason: "no capability needed", details: nil}}} =
               Task.yield(task, 1_000)
    end

    test "a table-shaped reason argument is decoded then rendered via inspect/1, not left as a raw table reference" do
      task = async_fail(fn -> Lua.eval!(Sandbox.new(), "platform.fail({oops = true})") end)

      assert {:exit, {:script_failed, %{reason: reason, details: nil}}} = Task.yield(task, 1_000)
      assert reason =~ "oops"
      refute reason =~ "tref"
    end
  end

  describe "REQ-161: moduledoc content (AC5, AC6)" do
    test "restates LUA-15 and explains the pcall-continuation hazard, naming exit/1 as the mechanism" do
      {:docs_v1, _, _, _, %{"en" => text}, _, _} =
        Code.fetch_docs(Letflow.Engine.Lua.Platform)

      assert text =~ "LUA-15"
      assert text =~ "pcall"
      assert text =~ "exit({:script_failed"
      assert text =~ "rescue"
    end

    test "states plainly that LUA-15's engine-side half has no real call site today" do
      {:docs_v1, _, _, _, %{"en" => text}, _, _} =
        Code.fetch_docs(Letflow.Engine.Lua.Platform)

      assert text =~ "no real call site today"
      assert text =~ "plugin_interface.ex"
      assert text =~ "lua_script_audit.ex"
    end

    test "states the SCRIPT_FAILED/SCRIPT_ERROR non-collapse property, reserving :script_failed" do
      {:docs_v1, _, _, _, %{"en" => text}, _, _} =
        Code.fetch_docs(Letflow.Engine.Lua.Platform)

      assert text =~ "SCRIPT_ERROR"
      assert text =~ "reserved"
    end

    test "states the honest executor.ex stringification gap" do
      {:docs_v1, _, _, _, %{"en" => text}, _, _} =
        Code.fetch_docs(Letflow.Engine.Lua.Platform)

      assert text =~ "format_exit_reason"
      assert text =~ "process/monitor boundary"
    end
  end

  # ---------------------------------------------------------------------------------
  # GH #2587 / REQ-499 PR A1 (design gh2587-req499-pr-a-prerequisites.md 2.7, D-A1.9):
  # emit_event refuses every event type reconstruction folds as an engine fact.
  # ---------------------------------------------------------------------------------

  describe "GH #2587: platform.emit_event refuses every reconstruction-folded event type" do
    setup do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()
      actor_id = Ecto.UUID.generate()
      seed_projection!(schema_name, instance_id)

      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["event:emit"]),
          execution_context(%{instance_id: instance_id, prefix: schema_name, actor_id: actor_id})
        )

      %{tenant_id: tenant_id, schema_name: schema_name, instance_id: instance_id, lua: lua}
    end

    test "each folded type -> [nil, invalid_arguments], no event, no event_idempotency row", %{
      schema_name: schema_name,
      instance_id: instance_id,
      lua: lua
    } do
      folded = Letflow.Engine.Reconstruction.folded_event_types()
      # the list itself (and its non-emptiness) is pinned to the replay clause heads by
      # put_sys_callers_test.exs R4

      idempotency_rows = fn ->
        Repo.aggregate("event_idempotency", :count, prefix: schema_name)
      end

      rows_before = idempotency_rows.()

      for {type, i} <- Enum.with_index(folded) do
        script = """
        local ok, err = platform.emit_event('#{type}', {}, 'gh2587-folded-#{i}')
        return ok, err.reason
        """

        assert {[nil, "invalid_arguments"], _lua} = Lua.eval!(lua, script), type
      end

      # a payload the registry WOULD accept for the engine-only type is refused all the same
      script = """
      local ok, err = platform.emit_event('INSTANCE_SYS_VARIABLES_SET',
        {node_id = 't', cause = 'entity_writes', values = {['_sys.r'] = 'x'}}, 'gh2587-sys')
      return ok, err.reason
      """

      assert {[nil, "invalid_arguments"], _lua} = Lua.eval!(lua, script)

      # no event at all for the instance (read/2 answers :instance_not_found for an empty stream)
      assert {:error, :instance_not_found} =
               Letflow.EventStore.read(instance_id, prefix: schema_name)

      assert idempotency_rows.() == rows_before
    end

    test "regression: a fixture-registered (unfolded) type still appends", %{
      tenant_id: tenant_id,
      schema_name: schema_name,
      instance_id: instance_id,
      lua: lua
    } do
      event_type = register_event_type!(tenant_id)
      refute event_type in Letflow.Engine.Reconstruction.folded_event_types()

      assert {[true], _lua} =
               Lua.eval!(lua, "return platform.emit_event('#{event_type}', nil, 'gh2587-ok')")

      assert {:ok, [event]} = Letflow.EventStore.read(instance_id, prefix: schema_name)
      assert event.event_type == event_type
    end
  end
end
