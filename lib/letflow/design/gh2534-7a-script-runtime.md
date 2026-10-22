# GH 2534 PR 7a: tenant-script runtime (decision 0053 D4, D5 subset, D7, D8, D11; F-A..F-E)

Decision: `docs/migration/decisions/0053-tenant-scripted-rules.md` (ratified, #2538). Split
accepted by the supervisor 2026-10-14: 7a runtime (this), 7b registry, 7c handler; serial
merges, SECURITY-REVIEWER + REVIEWER on each. 7a adds NO tenant-facing surface: no route, no
table, no engine caller. It adds the runtime 7b (dry-run, publish tests) and 7c (SERVICE_TASK
handler) call. Revision 2: CODE-DESIGN-VALIDATOR (9 blocking) and SECURITY-REVIEWER (B1-B3)
findings resolved; each resolution is tagged [CDV n] / [SEC Bn] / [SEC nb n].

## 0. Verified facts (spikes on OTP 29.0 / Elixir 1.20.3 / `lua` 1.0.2, 2026-10-14)

* `Lua.new(sandboxed: [], max_string_bytes: b, max_instructions: n, max_call_depth: d)`
  builds a VM; `Lua.VM.State.globals(state)` is the globals map; `Lua.set!(lua, [k], nil)`
  REMOVES a global. `Lua.sandbox/2` only replaces a path with a raising function.
* Raw execution path: `Lua.Parser.parse_structured/1` -> `Lua.Compiler.compile/2` ->
  `Lua.VM.execute(proto, state)` returns `{:ok, results, state}` with RAW values: tables are
  `{:tref, id}`, read via `Lua.VM.State.get_table(state, tref)` -> `%Lua.VM.Table{}`
  (`arr`/`arr_n` + `data`, `metatable`), `Lua.VM.Table.to_map/1` merges both. This path does
  NOT run `Display.wrap_results` (which walks the whole graph) [CDV 1, CDV 2].
* Instruction budget: raises `Lua.VM.RuntimeError` with `value: "instruction budget
  exceeded"` and `state.instruction_count == max_instructions`; a forged
  `error("instruction budget exceeded")` has the same `value` but `instruction_count` 0
  [CDV 16]. `pcall` catches the budget error, so the wall clock is the real stop.
* `max_call_depth: 200` turns runaway recursion into `Lua.VM.RuntimeError` "stack overflow"
  [SEC nb 1].
* A host function that `throw`s is NOT caught by `pcall`: the throw reaches the caller of
  `Lua.VM.execute/2` [CDV 4, SEC B3].
* `max_string_bytes` is enforced ONLY by `..`, `string.rep` and `load`: with a 1 MiB cap,
  `table.concat` of 300 x 1 MiB returned a 300 MB string and `string.format` with 200 `%s`
  returned 200 MB [SEC B1]. Host versions are required (section 2).
* `Process.flag(:max_heap_size, %{size, kill: true, error_logger: false,
  include_shared_binaries: true})` is accepted inside a process on OTP 29. Whether it bounds
  refc binaries is the F-A test, not assumed.

## 1. Modules

| Module | Role |
|---|---|
| `Letflow.Engine.Lua.Sandbox.new_script/1` (new function; `sandbox.ex` stays the only `Lua.new/1` call site, INV-SBX-1) | exact-allow-list VM |
| `Letflow.Engine.Lua.ScriptHost` (new) | host functions: `ctx`, `fail`, `print`, `math.random`, size-checked `table.concat` / `string.format` / `string.gsub` / `string.char` |
| `Letflow.Engine.Lua.ScriptRunner` (new) | `run/3`: watchdog + worker, stable codes |
| `Letflow.Engine.Lua.ScriptValue` (new) | input encoding, budgeted raw output decoding |
| `Letflow.Admission` (changed, additive) | opt-in caller monitoring |
| `Letflow.Supervisor.Infrastructure` (changed) | `ScriptAdmission` child |
| `Letflow.Routers.Tenants` deactivation path (changed, 1 line) | `forget_tenant/2` also on `ScriptAdmission` [CDV 11, SEC nb 5] |

`Executor`, `Sandbox.new/0,1`, `Platform` and `LuaScriptAudit` are unchanged; `Platform.install`
is NOT called by `new_script/1` [CDV 10]. 7c retires the old tenant-script path.

## 2. Sandbox `new_script(opts)` (D11, F-C) [CDV 10, SEC B1, SEC nb 7]

1. `Lua.new(sandboxed: [], max_string_bytes: 1_048_576, max_instructions: opts.instructions,
   max_call_depth: 200)`.
2. Globals: exactly `@script_globals` = `string table math pairs ipairs next select type
   tostring tonumber pcall error assert setmetatable getmetatable rawget rawset rawequal
   rawlen unpack` plus host `ctx fail print`. Every other key of `State.globals/1` is removed
   with `Lua.set!(lua, [k], nil)` (removes `_G`, `_ENV`, `_VERSION`, `os`, `io`, `debug`,
   `load*`, `dofile`, `require`, `package`, `collectgarbage`, `coroutine`, `utf8`, `xpcall`,
   and anything a future `lua` bump adds).
3. Library members, exact (1.0.2 inventory minus removals):
   * `string`: `lower upper len sub rep reverse byte char format find match gsub` (host
     versions for `char`, `format`, `gsub`); REMOVED: `dump gmatch pack packsize unpack`.
   * `table`: `insert remove concat sort unpack` (host `concat`); REMOVED: `pack move`.
   * `math`: `abs acos asin atan ceil cos deg exp floor fmod log max min modf pi rad sin sqrt
     tan tointeger type ult huge maxinteger mininteger random randomseed` (host `random`,
     no-op `randomseed`).
4. Size-checked host versions (all error with the fixed text "resulting string too large",
   checked BEFORE building the result, against 1 MiB):
   * `table.concat(t, sep, i, j)`: reads each element ONCE via raw table storage (never
     `__index`), sums byte sizes (strings; numbers via their decimal form) + separators, and
     builds the result from exactly those values (never hands off to the library's
     metatable path); non-string/number element -> fixed-text error [SEC r2-2].
   * `string.format(fmt, ...)`: upper bound = `byte_size(fmt)` + sum of `byte_size` of string
     args (x4 for an arg consumed by `%q`, whose escaping expands up to 4x) + 64 per
     non-string arg + width/precision digits parsed from `fmt`; over the cap -> error; else
     delegate to the library function [SEC r2-1].
   * `string.gsub(s, pat, repl, n)`: ONLY a string `repl` is allowed (a function or table
     `repl` -> fixed-text error "string.gsub: only string replacement allowed"); bound =
     `byte_size(s) + max_matches * (byte_size(repl) + refs * byte_size(s))`, `refs` = number of `%0`-`%9` in `repl` (each expands to a whole match or capture, at most `byte_size(s)`), `max_matches` = `n` when given else `byte_size(s) + 1` [SEC code B2].
     This deliberately narrows F-B's "string.gsub callback" to a test that the callback form is
     refused (no host re-entry); confirmed by SECURITY-REVIEWER. Known limit for authors: the
     bound is conservative (e.g. a 400 KiB subject with a 2-byte replacement is refused); a
     later version may count matches first [SEC r2-3].
   * `string.char(...)`: argument count over the cap -> error.
5. Fresh VM per run, built inside the worker; nothing cached across runs, scripts or tenants
   (F-C). `getmetatable("")` is mutable within a run only.
6. `script_globals/0` and `script_members/0` are public for the equality test.

## 3. Script contract [CDV 15]

The source is a chunk. Input is `ctx.input` (the encoded input map). The chunk's FIRST return
value is the output; it must be a table (decoded as a map or list) or nil (= empty map);
further return values are ignored; any other first value -> `output_invalid`.

## 4. Runner `ScriptRunner.run(source, input, opts)` [CDV 5, 6, 7, 12, SEC B2, nb 6]

```
@spec run(String.t(), map(), keyword()) ::
        {:ok, %{output: map() | list(), stats: stats()}} | {:error, code(), detail()}
code  :: :script_error | :budget_exceeded | :memory_limit_exceeded | :output_invalid
       | :timeout | :script_failed | :script_rejected | :script_busy
stats :: %{duration_us, instructions_used, instructions_budget, heap_words_at_end,
           heap_words_limit, input_dropped}
detail :: %{} | %{fail: %{code: String.t(), details: map()}} | %{author: author_detail()}
```

Invalid opts (missing or ill-typed `:tenant`/`:ctx`, non-positive limits) are a CALLER bug and raise `ArgumentError` before anything runs; nothing the script does raises. Required opts: `:tenant` (schema prefix), `:ctx` (`instance_id`, `node_id`, `token_id` as
strings, `now` as `DateTime`). Optional (clamped): `:instructions` (default 1_000_000, max
10_000_000), `:timeout_ms` (default 1_000, max 5_000), `:heap_words` (default 4_194_304, max
8_388_608), `:fail_codes` (list of allowed `fail` codes; nil = any well-formed code; 7c passes
the manifest's list) [CDV 8], `:author_detail` (dry-run only), `:admission` (server, default
`Letflow.Engine.Lua.ScriptAdmission`). `script_rejected` is never produced by 7a (7b/7c use it).

Processes, all under `Letflow.Engine.Lua.TaskSupervisor`, both started with ZERO-ARITY CLOSURES
(never `async(sup, M, f, args)`) [SEC B2]:

```
caller ── Task.Supervisor.async_nolink(fn -> Watchdog.run(caller, ...) end)   (caller monitors it)
  WATCHDOG (traps exits; parent_pid = first pid of Process.get(:"$ancestors"), read at start;
            steps 1-6 compute the reply inside ONE try/rescue/catch that returns a tagged tuple;
            the exit(...) calls of step 5 are made OUTSIDE that try: the receive returns
            {:exit_now, reason} and the code after the try calls exit(reason) [CDV r2-2])
    1. try_acquire({:tenant, t}, admission)   {:error, :capacity} -> {:error, :script_busy, %{}}
       (Admission monitors the watchdog pid)
    2. Process.monitor(caller)                caller pid passed explicitly
    3. deadline = now + timeout_ms             starts AFTER admission, BEFORE sandbox build
    4. Task.Supervisor.async(fn -> Worker.run(...) end)   WORKER, linked
    5. receive
         {worker_ref, result}                 -> result
         {:DOWN, worker_mon, ..., :killed}    -> {:error, :memory_limit_exceeded, %{}}
         {:DOWN, worker_mon, ..., _other}     -> {:error, :script_error, %{}}
         {:DOWN, caller_mon, ...}             -> kill worker; {:exit_now, :normal}
         {:EXIT, ^parent_pid, reason}         -> kill worker; {:exit_now, reason}  [CDV 6, SEC r2-5]
         {:EXIT, ^worker_pid, _}              -> ignored (the :DOWN carries the outcome)
         after deadline                       -> kill worker; {:error, :timeout, %{}}
       (kill = Task.shutdown(worker, :brutal_kill))
    6. Admission.release (the :DOWN release is the backstop); return the tuple
  caller: Task.yield(watchdog, timeout_ms + 2_000) || Task.shutdown(watchdog, :brutal_kill)
          {:ok, tuple} -> tuple; nil -> {:error, :timeout, %{}};
          {:exit, _reason} -> {:error, :script_error, %{}} (reason never inspected) [SEC r2-4]
WORKER (body = one try/rescue/catch; returns a tagged tuple; never raises or exits abnormally)
    Process.flag(:max_heap_size, %{size: heap_words, kill: true, error_logger: false,
                                   include_shared_binaries: true})        FIRST statement
    Sandbox.new_script -> ScriptHost.install(ctx, input) -> parse/compile/VM.execute
    -> ScriptValue.decode(first result, state) -> {:ok, %{output, stats}}
```

Outcome mapping (worker), never by message text alone:

| Observed | Code |
|---|---|
| `throw({:script_fail, run_ref, payload})` from `fail` (run_ref = this run's `make_ref()`) | `script_failed` with the validated payload |
| `Lua.VM.RuntimeError` with `value == "instruction budget exceeded"` AND `state.instruction_count >= budget` | `budget_exceeded` |
| parse/compile error, any other `Lua.VM.*Error`, any other raise/throw/exit inside the worker | `script_error` |
| decode problem | `output_invalid` |

Stats: `instructions_used` from the final `state.instruction_count` (or the exception's
state), `heap_words_at_end` from `Process.info(self(), :total_heap_size)` at the end of the
worker (the current size, not a peak; the limit is enforced by the heap flag) [CDV 7, r2-3];
`input_dropped` = `ScriptValue.encode/1`'s dropped count: the run continues, the count is
reported so 7b/7c can surface it [CDV r2-5].

F-A fallback (implemented only if the F-A test fails): the watchdog samples
`Process.info(worker, :binary)` every 50 ms and kills above `heap_words * 8` bytes, code
`memory_limit_exceeded` [CDV 12].

## 5. Host API (D4, D5 subset, D11) [CDV 9, SEC nb 3]

Per-run host state lives in the WORKER's process dictionary under keys namespaced by the
run's `make_ref()` (uuid counter, rand state, print buffer, fail flag); the worker is a fresh
process per run. Every host function catches every exception internally and raises only
fixed-text Lua errors ("invalid argument to <name>") [SEC nb 3]; the ONE exemption is
`fail`'s own `throw({:script_fail, run_ref, payload})`, which is thrown after its validation
and never caught by host code [CDV r2-7].

* lua 1.0.2's `table.sort` WITHOUT a comparator does not dispatch `__lt` on tables (it
  raises an ordinary Lua error: `script_error`, fail closed); with a comparator it works and
  the wall clock / budget bounds a looping comparator (F-B test).
* `ctx.now`: ISO-8601 UTC string of `opts.ctx.now`; `ctx.input`: encoded input.
* `ctx.uuid()`: UUIDv5 (RFC 9562, SHA-1) with namespace
  `@script_uuid_namespace = "7c5a1e3b-2f4d-5a6b-8c9d-0e1f2a3b4c5d"` (a fixed constant of this
  module) and name = `instance_id <> ":" <> node_id <> ":" <> token_id <> ":" <>
  Integer.to_string(counter)`, counter starting at 1 per run.
* `math.random(m, n)`: `:rand` algorithm `:exsss`, seeded with the first 3 x 32-bit words of
  `sha256(instance_id <> ":" <> node_id <> ":" <> token_id <> ":rand")`; Lua semantics for 0,
  1 or 2 args; `math.randomseed` is a no-op.
* `fail(code, details)`: `code` must match `^[a-z][a-z0-9_]{0,63}$` and, when `:fail_codes`
  is given, be in it; `details` optional, a map with string keys and SCALAR values only
  (string up to 256 bytes, number, boolean), at most 16 keys [CDV 8]. A malformed call ->
  fixed-text Lua error (catchable, ordinary `script_error` path). A valid call stores the
  payload in the run's host state and `throw`s `{:script_fail, run_ref, payload}`, which
  `pcall` does not catch; the worker matches `run_ref`. A forged `error(...)` string can never
  produce `script_failed` [SEC B3].
* `print(...)`: appends the args, tab-separated and collected only up to the line cap (never a full join) [SEC code B1], to the run's buffer, at most 20
  lines x 256 bytes (extra dropped, counted). NEVER sent to Logger or stdout; returned only
  in `author_detail`. Deliberate deviation from 0053's "capped host log line": stricter
  (no log at all) [CDV 17].
* Not installed: `call_service`, `read_variable`, `write_variable`, `log`, `emit_event`,
  `get_instance_state`, `now`.

## 6. Values (F-B, F-D) [CDV 1, 2, 3, 17, SEC nb 2]

`ScriptValue.encode(map)`: string keys; values nil, boolean, integer, finite float, valid
UTF-8 string, list, string-keyed map -> Lua values/tables WITHOUT metatables. Any other term
(atom other than nil/true/false, struct, non-finite float, non-string key) -> the key/value is
dropped and counted (`encode/1` returns `{lua_value, dropped_count}`; never raises) [CDV 17].

`ScriptValue.decode(raw, state, budget)` runs INSIDE the worker, before anything is sent to
the watchdog [SEC nb 2]:
* reads tables only via `State.get_table/2` + `Table.to_map/1` (raw storage, no `__index`,
  `__pairs`, `__len` or any metamethod runs);
* map = all keys strings; list = keys exactly `1..n`; values nil/boolean/integer/finite
  float/valid-UTF-8 string/`{:tref, _}`; tags `{:native_func, _}`, `{:lua_closure, ...}`,
  `{:compiled_closure, ...}`, `{:udref, _}` and anything else -> `output_invalid`;
* a running budget: at most 10_000 nodes, depth 32, and an accumulated JSON-size estimate
  (keys + scalars + punctuation) checked at every node against 64 KiB; any table id seen
  twice on the current path -> `output_invalid` (cycle); total nodes bound shared subtables
  [CDV 3];
* strings stay binaries; no atom is ever created (named test: fresh unique keys, string
  values, nested keys and list items are not existing atoms after the run; GH 2561 replaced
  the VM-global `atom_count` check, which code loading also moves).

Author detail (dry-run only) [SEC nb 4]: an ALLOW-LIST shape: the first line of the Lua
error message when the error value is a string, otherwise the fixed text "script error
(non-string error value)" [CDV r2-6], truncated to 200 bytes, plus `script:<line>` when the exception carries a
line; plus the print buffer. Never `inspect/1`, `Exception.format/*` or a stack trace
(grep test over the three new modules).

## 7. Admission (D8) [CDV 11, 13, 14]

`Letflow.Admission.start_link(monitor_callers: true)`: state gains `monitors`
(monitor_ref -> id) and `ref_monitors` (id -> monitor_ref); `try_acquire` monitors the
`GenServer.call` caller pid inside `handle_call` before replying; `release/2` demonitors with
`:flush`; `handle_info({:DOWN, ...})` releases. Default `false` (HTTP admission unchanged).
Implemented already on the branch.

`ScriptAdmission` child, inserted directly after `{Task.Supervisor, name:
Letflow.Engine.Lua.TaskSupervisor}` in `infrastructure.ex` (children 23 -> 24; the child list
comment and `test/letflow/supervisor/infrastructure_test.exs` updated):
`Supervisor.child_spec({Letflow.Admission, name: Letflow.Engine.Lua.ScriptAdmission,
monitor_callers: true, pool_size: slots, reserved_headroom: 1}, id:
Letflow.Engine.Lua.ScriptAdmission)` with `slots = min(configured || 8, repo_pool - 2) + 1`
(so `global_cap = slots - 1 >= 1`, at most `repo_pool - 2`; keeps `reserved_headroom` a
`pos_integer`). Tenant deactivation calls `forget_tenant/2` on both servers.

## 8. Budgets (Q11: measure, set defaults from data, never exceed D7 maxima)

`test/letflow/engine/lua/script_runtime_test.exs` ("budget measurement" describe, default suite,
so it runs on CI): 50 runs of a trivial script; prints one line `GH2534 budget measurement (us):`
with median and p95 of (a) `Sandbox.new_script/1` and (b) full `ScriptRunner.run/3` including
both spawns; asserts only a loose sanity bound (p95 < 1 s). `mix letflow.check.test` echoes that
line from the partition log on a passing run (GH #2615).

Local measurement (Windows dev host, 2026-10-14, LOCAL, not CI): `new_script/1` median ~0.1 ms,
full run median ~0.1 ms, p95 ~0.2 ms.

CI measurement (GH #2615, microseconds; the figures are the median and p95 of 50 runs):

| Source | `new_script/1` median | `new_script/1` p95 | full `ScriptRunner.run/3` median | full run p95 |
|---|---|---|---|---|
| CI, run 39751360045 (`CI`, head 9ad51b2ac), job 119732555322 `Backend shard 3/3`, partition 12 | 115 us | 547 us | 283 us | 893 us |
| Local, Windows dev host, 2026-10-14 | ~100 us | ~200 us | ~100 us | ~200 us |

Job 119732555322 completed `success`; its partition 12 reported `1545 tests, 0 failures`, and
`mix letflow.check.test: OK`. The line is absent from the older main runs
(39749312449, 39748928199, 39748855576): the echo landed with #3031 (9ad51b2ac).

Threshold comparison against the section-4 defaults (10% = a 100 ms budget for the 1_000 ms
wall clock default):

| Default | 10% of default | CI p95 | Exceeded? |
|---|---|---|---|
| `timeout_ms` 1_000 ms | 100 ms (100_000 us) | full run p95 893 us (0.89 ms); new_script p95 547 us | No (under 1% of the default) |
| `instructions` 1_000_000 | not measured by this test | n/a | n/a |
| `heap_words` 4_194_304 | not measured by this test | n/a | n/a |

The section-4 defaults stand; no default changes. The instruction and heap defaults are not
covered by this timing measurement and are not judged by it. The sample is a single trivial
script over 50 runs, so the p95 is a weak tail estimate; the 1_000 ms default has about 1,100x
headroom over the CI p95, so this does not move the conclusion.

Rule (unchanged): if the CI p95 of (b) exceeds 10% of the 1_000 ms default, the PR raises the
default wall clock to `ceil(p95 * 10)` ms capped at 5_000, else the defaults of section 4 stand.
Not triggered here. [CDV 12]

## 9. Tests (TEST-DESIGNER brief, GH 2534 AC numbers)

1. AC1/AC14: equality of `_G` keys and of `string`/`table`/`math` members for every
   `new_script` option set; named absences incl. `coroutine`, `utf8`, `_G`, `_ENV`, `xpcall`,
   `string.dump`, `os.time_ms`.
2. AC2: doubling concat and `string.rep` rejected; `table.concat` 300 x 1 MiB, `string.format`
   with 200 `%s` of 1 MiB, `string.gsub` with a 1 MiB repl, and `string.char` with too many args
   each rejected BEFORE allocation (peak `:memory` of the worker stays below 64 MiB); gsub with a
   function repl refused; `%q` of a control-byte string counted at 4x; a `table.concat`
   whose `__index` returns a different value on a second read cannot pass the size check;
   busy loop -> `budget_exceeded`; `pcall`-wrapped busy loop -> `timeout`
   at the wall clock; default 1 s and clamp 5 s; output over 64 KiB -> `output_invalid`; deep
   recursion -> `script_error`; grep: no `spawn_opt`, no nil heap path in the new modules.
3. AC3 (F-A, blocking): refc-binary-heavy script (many 1 MiB strings in a table) ->
   `memory_limit_exceeded`; capture_log shows no tenant value.
4. AC4 (F-B): `__index` function loop; `__lt` in `table.sort`; gsub callback refused;
   string-metatable mutation not visible in the next run; decoding a table with
   `__index`/`__pairs`/`__len` metamethods runs none of them (a metamethod that would `fail`
   if called).
5. AC5 (F-C): consecutive runs (same and different tenants) share no globals.
6. AC6 (F-D + SEC B2): decode creates no atoms; `error(<input value>)`, a forced host crash and
   a heap kill each log nothing containing the value (capture_log); non-dry-run results carry
   only codes; author detail has no host frames/paths.
7. AC7 (Admission part): killed watchdog releases its slot; `monitor_callers` releases a
   killed holder; capacity -> `script_busy`; killing the caller kills the worker (no orphan);
   supervisor shutdown of the watchdog kills the worker.
8. `fail`: `pcall(fail, ...)` still ends `script_failed`; forged `error` text ends
   `script_error`; malformed code/details -> `script_error`; `:fail_codes` enforced; forged
   budget message -> `script_error`.
9. ctx: `ctx.uuid()` deterministic and distinct per counter; `math.random` deterministic;
   `print` never reaches Logger.
10. Budget measurement (section 8).

## 10. Out of scope for 7a

Registry, permissions, kill switch, HMAC secret, per-run record (7b); route_kind, pins,
dispatcher lease/CAS, pre-fetched reads, VariableMerge validation, LuaScriptAudit retirement
(7c).
