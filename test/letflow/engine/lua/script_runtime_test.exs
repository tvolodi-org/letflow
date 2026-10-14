defmodule Letflow.Engine.Lua.ScriptRuntimeTest do
  @moduledoc """
  GH 2534 PR 7a (decision 0053 D4, D5 subset, D7, D8, D11; F-A..F-E), design
  `lib/letflow/design/gh2534-7a-script-runtime.md` section 9: the tenant-script runtime
  (`Sandbox.new_script/1`, `ScriptHost`, `ScriptValue`, `ScriptRunner`) and
  `Letflow.Admission`'s opt-in caller monitoring.

  `async: false`: tests count children of `Letflow.Engine.Lua.TaskSupervisor`, read the VM-wide
  atom count and capture logs.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Letflow.Admission
  alias Letflow.Engine.Lua.Sandbox
  alias Letflow.Engine.Lua.ScriptHost
  alias Letflow.Engine.Lua.ScriptRunner

  @ctx %{
    instance_id: "11111111-1111-1111-1111-111111111111",
    node_id: "node_a",
    token_id: "token_1",
    now: ~U[2026-10-14 12:00:00Z]
  }

  defp run(source, input \\ %{}, opts \\ []) do
    ScriptRunner.run(
      source,
      input,
      Keyword.merge([tenant: "tenant_script_test", ctx: @ctx], opts)
    )
  end

  defp host_run do
    %{run_ref: make_ref(), ctx: @ctx, input: %{}, fail_codes: nil}
  end

  defp script_vm(instructions) do
    Sandbox.new_script(max_instructions: instructions, host: &ScriptHost.install(&1, host_run()))
  end

  defp library_keys(lua, library) do
    globals = Lua.VM.State.globals(lua.state)

    lua.state
    |> Lua.VM.State.get_table(Map.fetch!(globals, library))
    |> Lua.VM.Table.to_map()
    |> Map.keys()
    |> Enum.sort()
  end

  defp lua_task_children, do: length(Task.Supervisor.children(Letflow.Engine.Lua.TaskSupervisor))

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  # ── AC1 / AC14: exact allow-list (equality, not subset) ────────────────────

  describe "AC1/AC14 sandbox allow-list (equality)" do
    test "the globals of a script VM equal the allow-list exactly, for every option set" do
      for instructions <- [1, 1_000, 1_000_000, 10_000_000] do
        lua = script_vm(instructions)

        keys = lua.state |> Lua.VM.State.globals() |> Map.keys() |> Enum.sort()
        assert keys == Sandbox.script_globals(), "max_instructions=#{instructions}"

        for {library, members} <- Sandbox.script_members() do
          assert library_keys(lua, library) == members,
                 "#{library} (max_instructions=#{instructions})"
        end
      end
    end

    test "named absences: os (incl. time_ms), io, debug, load*, require, package, collectgarbage, coroutine, utf8, _G, _ENV, xpcall, string.dump, string.pack, gmatch, table.pack, table.move" do
      lua = script_vm(1_000)
      globals = Lua.VM.State.globals(lua.state)

      for name <- ~w(os io debug load loadstring loadfile dofile require package collectgarbage
                     coroutine utf8 _G _ENV _VERSION xpcall) do
        refute Map.has_key?(globals, name), name
      end

      refute "dump" in library_keys(lua, "string")
      refute "pack" in library_keys(lua, "string")
      refute "gmatch" in library_keys(lua, "string")
      refute "pack" in library_keys(lua, "table")
      refute "move" in library_keys(lua, "table")

      assert {:error, :script_error, _} = run("return {v = os.time_ms()}")
      assert {:error, :script_error, _} = run("return {v = coroutine.create(function() end)}")
      assert {:error, :script_error, _} = run("return {v = string.dump(print)}")
      assert {:error, :script_error, _} = run("local f = load('return 1') return {}")
    end

    test "a removed member is also gone from string method syntax" do
      assert {:error, :script_error, _} = run("return {v = ('x'):pack()}")
      assert {:ok, %{output: %{"v" => "X"}}} = run("return {v = ('x'):upper()}")
    end
  end

  # ── AC2: limits ────────────────────────────────────────────────────────────

  describe "AC2 limits" do
    test "a doubling concat loop and an oversized string.rep are refused" do
      assert {:error, :script_error, %{author: %{message: msg}}} =
               run("local s = 'x' for i = 1, 40 do s = s .. s end return {}", %{},
                 author_detail: true
               )

      assert msg =~ "too large"

      assert {:error, :script_error, _} = run("local s = string.rep('x', 2000000) return {}")
    end

    test "table.concat, string.format (incl. %q at 4x), string.gsub and string.char refuse an oversized result before building it" do
      cases = [
        "local s = string.rep('x', 1000000) local t = {} for i = 1, 300 do t[i] = s end return {n = #table.concat(t)}",
        "local s = string.rep('x', 1000000) local a = {} for i = 1, 200 do a[i] = s end return {n = #string.format(string.rep('%s', 200), unpack(a))}",
        "return {n = #string.format('%q', string.rep(string.char(1), 300000))}",
        "return {n = #(string.gsub('aaaa', 'a', string.rep('x', 1000000)))}"
      ]

      for source <- cases do
        started = System.monotonic_time(:millisecond)

        assert {:error, :script_error, %{author: %{message: msg}}} =
                 run(source, %{}, author_detail: true, instructions: 10_000_000),
               source

        assert msg =~ "too large", source
        assert System.monotonic_time(:millisecond) - started < 4_000, source
      end

      # the same %q argument size passes as %s (counted at 1x)
      assert {:ok, %{output: %{"n" => 300_000}}} =
               run("return {n = #string.format('%s', string.rep(string.char(1), 300000))}")
    end

    test "string.gsub accepts a string replacement only (a function or table replacement is refused)" do
      assert {:ok, %{output: %{"v" => "axc"}}} =
               run("return {v = (string.gsub('abc', 'b', 'x'))}")

      assert {:error, :script_error, %{author: %{message: msg}}} =
               run("return {v = (string.gsub('abc', 'b', function() return 'x' end))}", %{},
                 author_detail: true
               )

      assert msg =~ "string.gsub"
      assert {:error, :script_error, _} = run("return {v = (string.gsub('abc', 'b', {b = 'x'}))}")
    end

    test "table.concat reads raw storage once: an __index that would supply huge strings is never consulted" do
      source = """
      local t = setmetatable({}, {__index = function(_, i) return string.rep('x', 1000000) end})
      return {n = #table.concat(t, '', 1, 300)}
      """

      assert {:error, :script_error, _} = run(source)
    end

    test "an instruction loop ends budget_exceeded" do
      assert {:error, :budget_exceeded, %{}} = run("while true do end", %{}, instructions: 10_000)
    end

    test "pcall cannot outlive the wall clock: a pcall-wrapped busy loop ends timeout" do
      source = "while true do pcall(function() while true do end end) end"
      started = System.monotonic_time(:millisecond)

      assert {:error, code, _} = run(source, %{}, instructions: 10_000_000, timeout_ms: 300)
      assert code in [:timeout, :budget_exceeded]
      assert System.monotonic_time(:millisecond) - started < 3_000
    end

    test "the wall clock defaults to 1 s and is clamped at 5 s" do
      assert ScriptRunner.limits().default_timeout_ms == 1_000
      assert ScriptRunner.limits().max_timeout_ms == 5_000

      # an over-max request is clamped (the run below would otherwise wait 60 s)
      started = System.monotonic_time(:millisecond)

      assert {:error, :timeout, _} =
               run("local x = 0 while true do x = x + 1 end", %{},
                 instructions: 10_000_000,
                 timeout_ms: 60_000,
                 heap_words: 8_388_608
               )
               |> then(fn
                 {:error, :budget_exceeded, d} -> {:error, :timeout, d}
                 other -> other
               end)

      assert System.monotonic_time(:millisecond) - started < 9_000
    end

    test "output over 64 KiB is output_invalid" do
      source = "local t = {} for i = 1, 100 do t[i] = string.rep('x', 1000) end return {list = t}"
      assert {:error, :output_invalid, _} = run(source)
      assert {:ok, %{output: %{"list" => list}}} = run(String.replace(source, "1, 100", "1, 10"))
      assert length(list) == 10
    end

    test "runaway recursion is a script_error (finite call depth)" do
      assert {:error, :script_error, _} =
               run("local function f(n) return 1 + f(n + 1) end return {v = f(1)}", %{},
                 instructions: 10_000_000
               )
    end

    test "the runtime modules contain no spawn_opt and no nil-heap path" do
      for file <- ~w(script_runner.ex script_host.ex script_value.ex) do
        source = File.read!(Path.join("lib/letflow/engine/lua", file))
        refute source =~ "spawn_opt", file
        refute source =~ ~r/max_heap_size.{0,40}nil/s, file
      end
    end
  end

  # ── AC3 / F-A: refc binaries and log hygiene ───────────────────────────────

  describe "AC3 (F-A) binary memory" do
    test "a refc-binary-heavy script ends memory_limit_exceeded and logs no tenant value" do
      source = """
      local t = {}
      for i = 1, 400 do t[i] = string.rep('S', 1000000) .. ctx.input.marker .. i end
      return {}
      """

      log =
        capture_log(fn ->
          assert {:error, :memory_limit_exceeded, %{}} =
                   run(source, %{"marker" => "TENANTVALUE"},
                     heap_words: 1_000_000,
                     instructions: 10_000_000,
                     timeout_ms: 5_000
                   )
        end)

      refute log =~ "TENANTVALUE"
      refute log =~ "SSSSSSSSSS"
    end
  end

  # ── AC4 / F-B: metamethods ─────────────────────────────────────────────────

  describe "AC4 (F-B) metamethods" do
    test "an __index function loop ends with an error, not a host hang" do
      source = """
      local t = setmetatable({}, {__index = function(t, k) return t[k] end})
      return {v = t.x}
      """

      assert {:error, code, _} = run(source, %{}, instructions: 10_000_000)
      assert code in [:script_error, :budget_exceeded, :memory_limit_exceeded, :timeout]
    end

    test "__lt and a comparator inside table.sort stay inside the sandbox and end with a stable outcome" do
      # lua 1.0.2's table.sort without a comparator does not dispatch __lt on tables: it
      # raises an ordinary Lua error, which fails closed as script_error (no hang, no leak).
      with_lt = """
      local mt = {__lt = function(a, b) return a.v < b.v end}
      local t = {}
      for i = 1, 10 do t[i] = setmetatable({v = 11 - i}, mt) end
      table.sort(t)
      return {first = t[1].v, last = t[10].v}
      """

      result = run(with_lt)

      assert result == {:error, :script_error, %{}} or
               match?({:ok, %{output: %{"first" => 1, "last" => 10}}}, result),
             inspect(result)

      # __lt itself runs for an explicit comparison, and a comparator callback works
      assert {:ok, %{output: %{"r" => true}}} =
               run(
                 "local mt = {__lt = function(a, b) return a.v < b.v end} return {r = setmetatable({v = 1}, mt) < setmetatable({v = 2}, mt)}"
               )

      comparator = """
      local t = {}
      for i = 1, 10 do t[i] = {v = 11 - i} end
      table.sort(t, function(a, b) return a.v < b.v end)
      return {first = t[1].v, last = t[10].v}
      """

      assert {:ok, %{output: %{"first" => 1, "last" => 10}}} = run(comparator)

      # a comparator that loops forever is stopped by the budget or the wall clock
      assert {:error, code, _} =
               run(
                 "local t = {3, 2, 1} table.sort(t, function(a, b) while true do end end) return {}",
                 %{},
                 timeout_ms: 500
               )

      assert code in [:budget_exceeded, :timeout]
    end

    test "string-metatable mutation does not survive to the next run" do
      assert {:ok, _} =
               run(
                 "local mt = getmetatable('') mt.__index = {upper = function() return 'pwned' end} return {}"
               )

      assert {:ok, %{output: %{"v" => "A"}}} = run("return {v = ('a'):upper()}")
    end

    test "output decoding calls no metamethod (__index, __pairs, __len would fail the run if called)" do
      source = """
      local trap = function() fail('metamethod_called') end
      return setmetatable({a = 1, b = setmetatable({2, 3}, {__len = trap, __index = trap})},
                          {__index = trap, __pairs = trap, __len = trap})
      """

      assert {:ok, %{output: %{"a" => 1, "b" => [2, 3]}}} = run(source)
    end
  end

  # ── AC5 / F-C: fresh VM per run ────────────────────────────────────────────

  describe "AC5 (F-C) fresh VM per run" do
    test "consecutive runs, same and different tenants, share no globals" do
      assert {:ok, _} = run("leak = 'from run 1' string.leak = 1 return {}")
      assert {:ok, %{output: out}} = run("return {v = leak, s = string.leak}")
      assert out == %{}

      assert {:ok, %{output: %{}}} =
               run("return {v = leak}", %{}, tenant: "tenant_script_other")
    end
  end

  # ── AC6 / F-D: atoms, error text, logs ─────────────────────────────────────

  describe "AC6 (F-D) values, error text and logs" do
    test "decoding creates no atoms" do
      keys = for i <- 1..300, do: "zz_gh2534_key_#{System.unique_integer([:positive])}_#{i}"
      body = keys |> Enum.map(&"#{&1} = 1") |> Enum.join(", ")
      before = :erlang.system_info(:atom_count)

      assert {:ok, %{output: out}} = run("return {#{body}}")
      assert map_size(out) == 300
      assert :erlang.system_info(:atom_count) - before < 50
    end

    test "error(<input value>), a host-function failure and a heap kill log nothing containing the value; results carry only the code" do
      log =
        capture_log(fn ->
          assert {:error, :script_error, %{}} =
                   run("error(ctx.input.secret)", %{"secret" => "SECRET-VALUE-77"})

          assert {:error, :script_error, %{}} =
                   run("return {v = string.format(ctx.input.secret, {})}", %{
                     "secret" => "%d SECRET-VALUE-77"
                   })

          assert {:error, :memory_limit_exceeded, %{}} =
                   run(
                     "local t = {} for i = 1, 400 do t[i] = string.rep(ctx.input.secret, 60000) end return {}",
                     %{"secret" => "SECRET-VALUE-77"},
                     heap_words: 1_000_000,
                     instructions: 10_000_000,
                     timeout_ms: 5_000
                   )
        end)

      refute log =~ "SECRET-VALUE-77"
    end

    test "author detail (dry-run only) is the first line of the message plus the line, no host frames or paths" do
      assert {:error, :script_error, %{author: author}} =
               run("local x = 1\nerror('first line\\nsecond line')", %{}, author_detail: true)

      assert author.message =~ "first line"
      refute author.message =~ "second line"
      refute author.message =~ ~r/lib\/|deps\/|\.ex:|Elixir\./

      assert {:error, :script_error,
              %{author: %{message: "script error (non-string error value)"}}} =
               run("error({})", %{}, author_detail: true)

      assert {:error, :script_error, %{}} = run("error('x')")
    end
  end

  # ── AC7 (Admission part) ───────────────────────────────────────────────────

  describe "AC7 Admission and process lifecycle" do
    test "Admission with monitor_callers releases a killed holder's slot; without it the slot leaks" do
      {:ok, monitored} =
        Admission.start_link(
          name: :gh2534_mon,
          pool_size: 2,
          reserved_headroom: 1,
          monitor_callers: true
        )

      {:ok, plain} = Admission.start_link(name: :gh2534_plain, pool_size: 2, reserved_headroom: 1)

      for {server, expect_free} <- [{:gh2534_mon, true}, {:gh2534_plain, false}] do
        test_pid = self()

        holder =
          spawn(fn ->
            {:ok, _ref} = Admission.try_acquire(:global, server)
            send(test_pid, :holding)
            Process.sleep(:infinity)
          end)

        assert_receive :holding, 1_000
        assert Admission.try_acquire(:global, server) == {:error, :capacity}
        Process.exit(holder, :kill)

        freed = eventually(fn -> match?({:ok, _}, Admission.try_acquire(:global, server)) end, 10)
        assert freed == expect_free, inspect(server)
      end

      GenServer.stop(monitored)
      GenServer.stop(plain)
    end

    test "capacity is script_busy; the slot comes back when its holder dies" do
      {:ok, server} =
        Admission.start_link(
          name: :gh2534_cap,
          pool_size: 2,
          reserved_headroom: 1,
          monitor_callers: true
        )

      test_pid = self()

      holder =
        spawn(fn ->
          {:ok, _ref} = Admission.try_acquire({:tenant, "tenant_script_test"}, :gh2534_cap)
          send(test_pid, :holding)
          Process.sleep(:infinity)
        end)

      assert_receive :holding, 1_000
      assert {:error, :script_busy, %{}} = run("return {}", %{}, admission: :gh2534_cap)

      Process.exit(holder, :kill)
      assert eventually(fn -> match?({:ok, _}, run("return {}", %{}, admission: :gh2534_cap)) end)

      # and a completed run released its own slot (the next run is admitted)
      assert {:ok, _} = run("return {}", %{}, admission: :gh2534_cap)
      GenServer.stop(server)
    end

    test "killing the caller kills the worker: no script process is left running" do
      baseline = lua_task_children()

      caller =
        spawn(fn ->
          run("local x = 0 while true do x = x + 1 end", %{},
            instructions: 10_000_000,
            timeout_ms: 5_000
          )
        end)

      assert eventually(fn -> lua_task_children() >= baseline + 2 end)
      Process.exit(caller, :kill)
      assert eventually(fn -> lua_task_children() <= baseline end, 100)
    end
  end

  # ── fail (0053 D5, SEC B3) ─────────────────────────────────────────────────

  describe "fail()" do
    test "a valid fail is script_failed with the validated payload" do
      assert {:error, :script_failed,
              %{fail: %{code: "bad_input", details: %{"field" => "amount", "n" => 3}}}} =
               run("fail('bad_input', {field = 'amount', n = 3})")
    end

    test "pcall cannot swallow fail" do
      assert {:error, :script_failed, %{fail: %{code: "stop_here"}}} =
               run("local ok = pcall(fail, 'stop_here') return {after = true}")
    end

    test "a forged fail marker or budget message in error() text is a plain script_error" do
      assert {:error, :script_error, _} = run("error('script_fail')")
      assert {:error, :script_error, _} = run("error({code = 'x'})")
      assert {:error, :script_error, _} = run("error('instruction budget exceeded')")
    end

    test "malformed code or details, and a code outside :fail_codes, are script_error" do
      assert {:error, :script_error, _} = run("fail('Bad Code')")
      assert {:error, :script_error, _} = run("fail('ok_code', {nested = {1}})")
      assert {:error, :script_error, _} = run("fail('ok_code', {s = string.rep('x', 300)})")

      assert {:error, :script_error, _} =
               run("fail('not_declared')", %{}, fail_codes: ["declared"])

      assert {:error, :script_failed, %{fail: %{code: "declared"}}} =
               run("fail('declared')", %{}, fail_codes: ["declared"])
    end
  end

  # ── ctx (0053 D5, D11) ─────────────────────────────────────────────────────

  describe "ctx, math.random and print" do
    test "ctx.now, ctx.input, deterministic ctx.uuid and math.random" do
      source =
        "return {now = ctx.now, x = ctx.input.x, u1 = ctx.uuid(), u2 = ctx.uuid(), r = math.random(1, 1000000)}"

      assert {:ok, %{output: a}} = run(source, %{"x" => 7})
      assert {:ok, %{output: b}} = run(source, %{"x" => 7})
      assert a == b
      assert a["now"] == "2026-10-14T12:00:00Z"
      assert a["x"] == 7
      assert a["u1"] != a["u2"]

      assert a["u1"] =~
               ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

      assert a["u1"] ==
               ScriptHost.uuid_v5(
                 ScriptHost.uuid_namespace(),
                 "#{@ctx.instance_id}:node_a:token_1:1"
               )
    end

    test "print never reaches the log; it is returned only as author detail" do
      log =
        capture_log(fn ->
          assert {:ok, _} = run("print('PRINTED-VALUE-9') return {}")

          assert {:error, :script_error, %{author: %{prints: ["PRINTED-VALUE-9"]}}} =
                   run("print('PRINTED-VALUE-9') error('x')", %{}, author_detail: true)
        end)

      refute log =~ "PRINTED-VALUE-9"
    end

    test "stats report the budget, the instructions used and the dropped input terms" do
      assert {:ok, %{stats: stats}} =
               run("local x = 0 for i = 1, 100 do x = x + i end return {}", %{
                 "bad" => :atom_value,
                 "ok" => 1
               })

      assert stats.instructions_budget == 1_000_000
      assert stats.instructions_used > 0
      assert stats.heap_words_limit == 4_194_304
      assert stats.input_dropped == 1
    end
  end

  # ── Budget measurement (Q11 ruling; numbers go into the PR body) ───────────

  describe "budget measurement" do
    test "Sandbox.new_script and a full trivial run: median and p95 over 50 runs" do
      time = fn fun ->
        for _ <- 1..50 do
          started = System.monotonic_time(:microsecond)
          fun.()
          System.monotonic_time(:microsecond) - started
        end
        |> Enum.sort()
      end

      sandbox = time.(fn -> script_vm(1_000_000) end)
      full = time.(fn -> {:ok, _} = run("return {ok = true}") end)
      pct = fn list, p -> Enum.at(list, trunc(length(list) * p)) end

      IO.puts(
        "GH2534 budget measurement (us): new_script median=#{pct.(sandbox, 0.5)} p95=#{pct.(sandbox, 0.95)}; " <>
          "full run median=#{pct.(full, 0.5)} p95=#{pct.(full, 0.95)}"
      )

      assert pct.(full, 0.95) < 1_000_000
    end
  end
end
