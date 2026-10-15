defmodule Letflow.Engine.Lua.Platform do
  @moduledoc """
  REQ-152 (LUA-14 restated) — implements the `platform.now()` half of LUA-14 ("Time
  Source, MUST"): `platform.now()` MUST return the platform's authoritative time as ISO
  8601 UTC. The other half of LUA-14 (denying `os.time` and its ambient-time siblings) is
  implemented in `Letflow.Engine.Lua.Sandbox`'s deny-set, not here — see that module's
  moduledoc for the restatement of why `os.date`/`os.clock`/`os.difftime`/`os.setlocale`
  are also denied, beyond LUA-14's literal wording.

  This module owns two concerns, deliberately kept together rather than split across
  files: what `platform.now()` returns (`now/0`), and how the entire `platform.*` table
  becomes reachable from a Lua script at all (`install/1`, `install/2`).

  ## `platform.now` is ungated by design — not an omission

  PROVENANCE (historical, not current decision authority):
  Per decision 0014 / R-Co's `src/lua/host_api/mod.zig` capability matrix: `now` is "a
  pure time read with no state reach," and that matrix entry is "a POSITIVE design
  statement, not an omission ... A test that expects a gate on `now` or `fail` is reading
  the matrix wrong."

  **Binding statement for future requirements:** `platform.now/0` has no capability
  check, no gate, no permission lookup, anywhere in its call path — by design,
  permanently, not "not yet implemented." `install/1`/`install/2` wire it unconditionally
  into every `Lua.t()` that `Letflow.Engine.Lua.Sandbox.new/0` or `new/1` produces; there
  is no `Sandbox.new/1` option that can suppress or gate it, and none should ever be
  added. REQ-157's capability-gating work (below) MUST NOT add a gate to `platform.now`
  "by symmetry" with the gating mechanism it introduces for the other six `platform.*`
  functions.

  ## Time-source injection — behaviour + application-env resolution

  `now/0` never reads `DateTime.utc_now/0` directly. It resolves the configured
  `#{inspect(__MODULE__)}.TimeSource` implementation from application env
  (`Application.get_env(:letflow, :lua_platform_time_source, ...)`), read fresh on every
  call (never cached), and calls that implementation's `now/0` callback. This lets a test
  swap in a fixed-value double via `Application.put_env/3` in `setup`/`on_exit`, without
  recompiling or restarting any supervision tree, and asserts `platform.now()` returns
  one exact, pre-set timestamp rather than merely a well-formed one. The default
  implementation, `#{inspect(__MODULE__)}.SystemClock`, is the one and only production
  call site of `DateTime.utc_now/0` this requirement's module set introduces.

  ## Composition point

  `install/1` is called from `Letflow.Engine.Lua.Sandbox.new/1`'s construction pipeline,
  immediately after the sandboxed VM is constructed — every `Lua.t()` produced by
  `Sandbox.new/0` or `Sandbox.new/1` therefore has the full `platform.*` table available
  with no second call any caller must remember to make. `install/1`/`install/2` never
  touch the deny-set: installing globals at `[:platform, _]` and denying paths under
  `[:os, ...]` are independent operations.

  ## REQ-157 (LUA-05, LUA-06 restated) — the capability matrix

  This requirement extends `platform` from the single `now` function (REQ-152) to the
  full, CLOSED set of exactly 8 functions this module's own `@capability_matrix`
  below names — the closed set of what `platform.*` exposes, and nothing else. Every
  `platform.*` global this module ever installs comes from `@capability_matrix` below,
  via a single fold in `install/2` — there is no other place in this module, or anywhere
  else under `lib/`, that installs a `platform.*` global via `Lua.set!/3` (INV-CAP-1).
  Adding a 9th `platform.*` function means adding a 9th row to this matrix; there is no
  other way to expose one.

  | Function | Required capability | Notes |
  |---|---|---|
  | `call_service` | `"service:call:" <> svc_id` (the first call argument, via `Letflow.Engine.Lua.Capabilities.service_capability/1`) | Parameterised — a grant for one service does not authorise another. |
  | `read_variable` | `"variable:read"` | Constant, ignores arguments. |
  | `write_variable` | `"variable:write"` | Constant, ignores arguments. |
  | `log` | `"audit:log"` | Constant, ignores arguments. |
  | `emit_event` | `"event:emit"` | Constant, ignores arguments. |
  | `get_instance_state` | `"instance:read"` | Constant, ignores arguments. |
  | `now` | `:none` — no capability, ever | Ungated by design (see above). A pure time read with no state reach (LUA-14). |
  | `fail` | `:none` — no capability, ever | Ungated by design. A script may always terminate itself: gating self-termination behind a capability would mean a script could be denied the ability to stop itself, which serves no isolation purpose (it does not reach any state, service, or variable) and would only complicate the one guaranteed way a script has of signaling its own failure back to the host. |

  **A test that expects a gate on `now` or `fail` is reading the matrix wrong** — neither
  function's `required` value is ever a capability string, in any row, for any argument;
  both always evaluate to `:none`, which `Letflow.Engine.Lua.Capabilities.check/3` treats
  as an unconditional `:ok` without ever consulting the calling script's grant set
  (INV-CAP-4).

  At the time REQ-157 shipped, every one of the six gated functions was stubbed only
  enough to prove the gate ran (`Letflow.Engine.Lua.Capabilities.check!/3` raises a
  `Lua.RuntimeException` on denial, LUA-06's "MUST raise a Lua error") — none of the six
  had a real implementation yet. REQ-159 and REQ-160 (below) have since replaced all six
  stubs with real implementations. `install/1` remains a thin delegate to `install/2`
  with an empty `Letflow.Engine.Lua.Capabilities.new()` grant set, so every production
  `Sandbox.new/0,1` VM exposes all 8 names with the six gated ones permanently denying
  until a future requirement calls `install/2` directly with a populated grant set.

  ## REQ-159 (LUA-11 read half, LUA-13) — `read_variable`, `get_instance_state`, `log`

  Implements `lib/letflow/design/req159-lua-host-api-read.md`. Three of the six gated
  stubs above become real: `read_variable` (a plain lookup on an already-resolved
  variables map, no `Letflow.Repo` call), `get_instance_state` (the one function in this
  set that reads `Letflow.Repo`, and only ever the calling script's own instance — see
  below), and `log` (emits via `Logger.log/3`, tagged with host-authored correlation
  fields only). `write_variable`, `call_service`, `emit_event` were `:not_yet_implemented`
  at the time this section was written; see the REQ-160 section below for their real
  implementations. `now`/`fail` are untouched by either requirement.

  A new `execution_context` value (`instance_id`, `prefix`, `trace_id`, `script_identity`,
  `variables`) is captured once per `install/3` call, the same closure-capture mechanism
  `capabilities` already uses — never passed as a Lua-visible argument, never read from a
  Lua global. `install/1`/`install/2` stay source-compatible, delegating down to
  `install/3` with `empty_execution_context/0` (design §2.3.1) — every production
  `Sandbox.new/0,1` VM still exposes all 8 names, but the three real functions observe an
  empty context (no variables, no prefix, no trace id) until a future requirement wires a
  real one through `Sandbox.new/1`'s or `Executor`'s call path (design OQ-1, explicitly
  deferred, not this requirement's `owned_modules`).

  **`get_instance_state` is scoped to the calling script's own instance, always** (design
  §5.1, a load-bearing default-scope decision from this design's own rework iteration 1).
  The script-supplied `instance_id` argument is accepted ONLY when it equals
  `execution_context.instance_id`; any other value — a real same-tenant sibling instance
  or a nonexistent id, indistinguishable from each other in the response — is rejected as
  `"forbidden"` with **no `Letflow.Repo` call attempted at all**. Only a match reaches
  `Repo.get/3`, and only ever with `execution_context.prefix` (decision 0014 (e): the
  tenant prefix comes from the calling engine code, never from script-supplied input, on
  every one of this requirement's `Repo` call sites — there is exactly one).

  ## Deviation from the design's literal `run_stub/4` — flagged for REVIEWER

  Design §7.3 specifies `run_stub/3` widening to `run_stub/4` (`stub_spec()`, `atom()`,
  `[term()]`, `execution_context()`) with "no other structural change to the
  `Enum.reduce/3` shape" (§7.4) — implying the installed wrapper stays the single-argument
  `fn args -> ... end` shape already at this file's `install/2`. That literal shape cannot
  actually implement `get_instance_state`'s success case: `tv-labs/lua` requires every
  dynamically-built Lua table to be produced via `Lua.encode!/2` against the *current
  call's* `Lua.t()`/state (confirmed directly against `deps/lua/lib/lua.ex` — a bare
  Elixir map returned from a `Lua.set!/3` callback fails `Util.encoded?/1` and raises
  "maps must be explicitly encoded to tables using `Lua.encode!/2`"), and a
  single-argument callback has no access to that state at all. `Lua.set!/3` itself
  documents a second, `arity/2` callback form (`fn args, lua -> ... end`) precisely for
  this case, so `install/3`'s fold uses that documented arity-2 form instead, and
  `run_stub/3` becomes `run_stub/5` (the same three prior arguments, plus
  `execution_context()` per the design, plus the call's own `Lua.t()`) rather than
  `run_stub/4`. This is the same category of "design text doesn't compile/run against the
  real dependency" gap already on record for this codebase (see
  `Letflow.EventStore.InstanceProjection`'s `JSONArray`/`unique_constraint` deviations) —
  not a shortcut: every other structural property the design actually cares about (one
  fold, one `Lua.set!/3` call site per row, `capabilities` and `execution_context` both
  closed over once, the six unaffected rows unedited beyond ignoring the extra argument)
  is preserved exactly.

  A related, smaller correction to design §6.1 step 1: a Lua-table argument (e.g.
  `log`'s `context`) does **not** arrive at a `Lua.set!/3` callback already decoded into
  a plain Elixir term "by `tv-labs/lua`'s own argument-marshalling at the call boundary"
  — confirmed directly against `deps/lua/lib/lua/vm/value.ex`'s `decode/3`, which only
  runs when something explicitly calls `Lua.decode!/2`/`decode_list!/2`; an un-decoded
  table argument is still its internal `{:tref, id}` reference. `do_log/3` below calls
  `Lua.decode!/2` on `context` explicitly for this reason, rather than passing the raw
  reference through to `Logger.log/3`'s metadata (which would leak a VM-internal,
  process-local id into a log entry — never useful to a reader and not safely
  serializable).

  ## REQ-160 (LUA-11 write half, LUA-12) — `write_variable`, `call_service`, `emit_event`

  Implements `lib/letflow/design/req160-lua-host-api-write.md`. The three remaining
  `:not_yet_implemented` stubs become real. **None of the three ever raises** except via
  the fold-level `Capabilities.check!/3` gate, structurally prior to any of them
  running.

  `write_variable(name, value)` stages the write into a **process-dictionary** buffer
  private to the one BEAM process executing the current script (design §2.2/2.3) — never
  into `Lua.t()`'s own state. Because REQ-155's wall-clock kill and REQ-156's memory-limit
  kill both terminate that same process, and the only two channels a caller ever observes
  a kill through are a payload-less `:DOWN` message or (on the two timeout-specific arms)
  a structured error tuple those two designs' own code returns *unconditionally*
  regardless of what a killed process's own reply might contain
  (`INV-write-discard-on-race`, design §2.2), a staged write is discarded automatically
  by any kill or raised script error, with no special discard mechanism needed here. The
  new public `take_staged_writes/0` reads and clears that buffer; this module never calls
  it itself — some future, out-of-scope caller (design §2.5 OQ-1, `executor.ex`, not in
  this requirement's `owned_modules`) is the first real caller. Makes no `Letflow.Repo`
  call; never raises.

  `call_service(service_id, payload)` resolves an injected `#{inspect(__MODULE__)}.ServiceCaller`
  implementation from application env (`Application.get_env(:letflow,
  :lua_platform_service_caller, ...)`, read fresh on every call — mirrors `TimeSource`'s
  own resolution exactly), defaulting to `#{inspect(__MODULE__)}.NoServiceCaller`, which
  always returns `{:error, :service_caller_not_configured}`. A service-call **failure**
  returns a structured `[nil, error_table]` Lua result; it never raises. This is
  genuinely distinct from a **missing** `service:call:<id>` capability, which raises at
  the fold level, one step before `call_service`'s own body is ever entered — a denied
  call never reaches this function's body, and this function's body never raises (design
  §4.3). Makes no `Letflow.Repo` call.

  `emit_event(event_type, payload, idempotency_key)` hooks into the real, already-shipped
  `Letflow.EventStore.append/2` (`lib/letflow/event_store.ex`). Its `prefix:` option is
  **always** `execution_context.prefix` — never anything derived from `event_type`,
  `payload`, or `idempotency_key`, the three script-supplied arguments (decision 0014
  (e)). This is the one function this requirement adds that calls `Letflow.Repo` at all
  (transitively, via `append/2`). Any `{:error, reason}` from `append/2` becomes a
  structured `[nil, error_table]` Lua result, never a raise; the only raise on this
  function's entire call path is the fold-level `event:emit` capability gate.
  `execution_context` gains one new field for this, `actor_id` — host-authored only,
  exactly like `trace_id`/`script_identity` (REQ-159 §2.3), never taken from a script
  argument. GH #2550: the script's key is stored namespaced as `script:<actor_id>:<key>`
  (`Letflow.Idempotency.script_key/2`), so it can never claim a server or client key;
  an empty, non-string or over-199-byte key, a key that is not valid UTF-8 or contains
  a NUL byte, and an `actor_id` that is not a 36-byte uuid string are all
  `invalid_arguments`, before any database access. GH #2587 (decision 0054 D1a): an
  `event_type` that replay folds as an engine fact
  (`Letflow.Engine.Reconstruction.folded_event_types/0`, e.g. `TASK_COMPLETED` or the
  engine-only reserved-variables event) is `invalid_arguments` too, checked first,
  before the key is namespaced or any database access, so a script can never forge
  replayed instance state. This module holds no event-type literal for it.

  Every numeric value any of these three functions moves across the Elixir/Lua boundary
  goes through `Letflow.Engine.LuaNumberMarshalling.from_lua/1` (write direction) or
  `to_lua/1` (read direction) exclusively — no second, ad hoc numeric-conversion rule is
  introduced anywhere in this section (REQ-150 §2.1/§2.2).

  ## REQ-161 (LUA-15 restated) — `platform.fail` terminates by a mechanism the script cannot intercept

  Implements `lib/letflow/design/req161-lua-platform-fail.md`. LUA-15 reads: "a script may
  call `platform.fail(reason, details)` to deliberately abort its own execution; this MUST
  terminate the script's execution in a way that cannot depend on the script declining to
  catch the error." Decision 0014's LUA-15 watchlist entry names the concrete hazard this
  restatement exists to close: an ordinary Elixir `raise` from inside a host function is
  exactly the shape a Lua `pcall` wrapper can catch, letting the script's own execution
  continue past the point it was supposed to have terminated at.

  **The prior `:fail` stub was that exact hazard, not a placeholder.** It built a message
  and called `raise Lua.RuntimeException, ...` — an ordinary `Exception` struct raised via
  `raise/2`. REQ-148's spike §4 (OQ-2 (b)) proved directly against the real, vendored
  `tv-labs/lua` runtime that a host function's `raise` IS caught by the calling script's own
  `pcall`, and the script's execution continues past the `pcall` block — i.e. a script could
  wrap `platform.fail(...)` in `pcall` and keep running exactly as decision 0014 warns
  against, and nothing in the old stub stopped it.

  **The actual mechanism**: `do_fail/2` calls `exit({:script_failed, %{reason: reason,
  details: details}})` from inside the `platform.fail` native function itself, terminating
  the calling process outright. This is uninterceptable because `tv-labs/lua`'s entire
  `pcall`/`xpcall`/native-call boundary is implemented via Elixir `try/rescue` —
  `deps/lua/lib/lua.ex`'s `do_call_function/3` (the `{:native_func, fun}` call clause) and
  `deps/lua/lib/lua/vm/stdlib.ex`'s `lua_pcall/2`/`lua_xpcall/2` are each `rescue`-only, with
  no `catch` clause of any kind on the call chain a `platform.*` function can reach — and
  `rescue` has no clause pattern that ever matches an `exit/1` call. An unhandled `exit/1`
  ends the calling process immediately; there is no "resume after exit," so a `pcall`
  wrapper cannot "continue past" a call that ends the very process trying to continue.
  (Full trace: this design's §2.2.)

  **LUA-15's engine-side half has no real call site today.** LUA-15 also names two
  engine-side obligations beyond producing the structured failure: recording a SCRIPT_FAILED
  event, and transitioning the instance per the node's error policy. Neither
  `lib/letflow/engine/plugin_interface.ex` (its own moduledoc: no `resolve_*`/`invoke/2,3`
  wiring into the engine's node-dispatch path exists yet) nor
  `lib/letflow/engine/lua_script_audit.ex` (its own moduledoc: "nothing in this codebase
  calls `execute_script_for_audit/6`") has a caller that could consume a script's outcome and
  act on it. `Letflow.Engine.Lua.Executor.execute_with_manifest/2,3` is the closest existing
  caller of `Lua.eval!/2`, and it itself has no caller yet either. This requirement produces
  the structured SCRIPT_FAILED outcome only — it does not, and cannot yet, wire the
  event-recording/error-policy-transition half.

  **SCRIPT_FAILED and a future SCRIPT_ERROR (REQ-162) do not collapse into the same shape.**
  `{:script_failed, %{reason: String.t(), details: term()}}` is produced only by a
  deliberate `platform.fail` call, observed as a process exit reason (a `:DOWN` message, or
  `Task.yield/2`'s `{:exit, reason}` clause) — the evaluating process is dead. A future
  SCRIPT_ERROR (an uncaught Lua runtime error propagating out of `Lua.eval!/2` as a
  `Lua.RuntimeException` or similar, per REQ-153/154/155's existing `rescue` clauses in
  `executor.ex`) is a normal function return/raise, not an `exit/1`, and necessarily carries
  different fields. `:script_failed` is reserved to mean "deliberate `platform.fail` call,"
  specifically so REQ-162 must not reuse this tag.

  **Honest gap: this distinction does not survive `Executor.execute_with_manifest/2,3`
  today.** Read directly, not assumed: `executor.ex`'s `handle_yield_result/3` clause for
  `{:exit, reason}`, and its raw-heap-limit `:DOWN` handling, both collapse every non-`:killed`
  exit reason — including a deliberate `{:script_failed, _}` one — into an opaque,
  `inspect/1`-rendered string via `format_exit_reason/1`, indistinguishable in shape from any
  other task crash. `executor.ex` is not in this requirement's `owned_modules` and is not
  edited to special-case `{:script_failed, _}` ahead of that stringification. This
  requirement's own tests therefore assert the SCRIPT_FAILED distinction at the raw
  process/monitor boundary (a `Task.async`/`Task.yield` or `Process.monitor` observation of
  `Lua.eval!/2` running directly against `Platform.install/3`'s output) — not through
  `Executor.execute_with_manifest/2,3`, whose own `{:error, String.t()}` return shape does
  not preserve it.
  """

  alias Letflow.Engine.Lua.Capabilities
  alias Letflow.Engine.Lua.Platform.TimeSource
  alias Letflow.Engine.LuaNumberMarshalling
  alias Letflow.Engine.Reconstruction
  alias Letflow.EventStore
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Idempotency
  alias Letflow.Repo

  require Logger

  @type iso8601_utc :: String.t()

  @default_time_source Letflow.Engine.Lua.Platform.SystemClock
  @default_service_caller Letflow.Engine.Lua.Platform.NoServiceCaller

  # Process-dictionary key for REQ-160's write_variable staging buffer (design §2.3) --
  # private to this module, never read/written anywhere else under `lib/`.
  @staged_writes_pdict_key {__MODULE__, :staged_writes}

  # `required` is a description of how to compute the required capability from the Lua
  # call's argument list, not a raw closure — Elixir module attributes cannot hold
  # anonymous functions (only literal/escapable terms), so this design's
  # `required_capability_fun`/`stub_fun` shapes are represented here as plain data tags
  # that `required_capability/2` and `run_stub/3` below dispatch on. This keeps
  # `@capability_matrix` itself a literal, inspectable module attribute while preserving
  # the "one fold, one place to add a 9th function" property (INV-CAP-1) the design
  # requires: the tags are resolved only inside `install/2`'s fold, nowhere else.
  @type required_capability_spec :: :none | :call_service_arg0 | Capabilities.capability()
  @type stub_spec ::
          :now
          | :fail
          | :read_variable
          | :get_instance_state
          | :log
          | :write_variable
          | :call_service
          | :emit_event

  @type matrix_row :: %{
          name: atom(),
          required: required_capability_spec(),
          stub: stub_spec()
        }
  @type capability_matrix :: [matrix_row()]

  # REQ-159 design §2.3, extended by REQ-160 design §5.2 with `actor_id`. `nil` is
  # permitted on every field except `variables` (defaults to `%{}`) so `install/1`/
  # `install/2`'s existing callers keep compiling and behaving exactly as before -- see
  # `empty_execution_context/0` and `install/3` below.
  @type execution_context :: %{
          instance_id: String.t() | nil,
          prefix: String.t() | nil,
          trace_id: String.t() | nil,
          script_identity: String.t() | nil,
          actor_id: String.t() | nil,
          variables: map()
        }

  # REQ-160 design §2.4. Key: the variable name exactly as the script's first
  # `write_variable` argument. Value: the write's second argument, after
  # `LuaNumberMarshalling.from_lua/1` has been applied. Last write wins (`Map.put/3`
  # semantics) -- no history, no error on a duplicate key.
  @type staged_writes :: %{optional(String.t()) => term()}

  # REQ-161 design §2.4/§3.3. The structured SCRIPT_FAILED payload carried on the exit
  # signal `do_fail/2` raises via `exit/1` -- never recovered from the terminated
  # process's own memory, since there is no process left to read it from once the exit
  # signal has been sent. `:script_failed` is reserved to mean "a script deliberately
  # called `platform.fail`" -- a future SCRIPT_ERROR (REQ-162) MUST NOT reuse this tag.
  @type script_failure :: %{reason: String.t(), details: term()}
  @type script_failed_exit_reason :: {:script_failed, script_failure()}

  # The entire closed set of `platform.*` functions — exactly 8 rows, no more, no fewer
  # (INV-CAP-2). `install/2` folds over this list; it is the ONLY call site under `lib/`
  # that ever installs a `platform.*` global via `Lua.set!/3` (INV-CAP-1). See moduledoc
  # for the human-readable version of this same table.
  @capability_matrix [
    %{name: :call_service, required: :call_service_arg0, stub: :call_service},
    %{name: :read_variable, required: "variable:read", stub: :read_variable},
    %{name: :write_variable, required: "variable:write", stub: :write_variable},
    %{name: :log, required: "audit:log", stub: :log},
    %{name: :emit_event, required: "event:emit", stub: :emit_event},
    %{name: :get_instance_state, required: "instance:read", stub: :get_instance_state},
    %{name: :now, required: :none, stub: :now},
    %{name: :fail, required: :none, stub: :fail}
  ]

  @doc """
  Returns the current authoritative time as an ISO 8601 UTC string, e.g.
  `"2026-08-26T14:32:07.123456Z"`. Reads the configured `TimeSource` implementation from
  application env on every call (never a direct `DateTime.utc_now/0` read at this call
  site) so the source is injectable for exact-value testing. Never fails: no I/O, no user
  input — reading an injected time source and formatting it cannot fail.
  """
  @spec now() :: iso8601_utc()
  def now do
    source = Application.get_env(:letflow, :lua_platform_time_source, @default_time_source)

    source.now()
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  @doc """
  The full 8-row capability matrix. Exposed for introspection/testing; `install/2` is the
  only caller that uses it to install `platform.*` globals.
  """
  @spec capability_matrix() :: capability_matrix()
  def capability_matrix, do: @capability_matrix

  @doc """
  Installs the full `platform.*` table into `lua` with an EMPTY capability grant set —
  defined as `install(lua, Letflow.Engine.Lua.Capabilities.new())`. Retained for source
  compatibility with `Letflow.Engine.Lua.Sandbox.new/1`'s existing call site, which is
  unchanged by this requirement (design §1.1). Every production `Sandbox.new/0,1` VM
  therefore exposes all 8 `platform.*` names, with the six gated ones permanently denying
  until some future requirement calls `install/2` directly with a populated grant set.

  Additive only — never touches the sandbox deny-set. Not intended to be called directly
  by any caller other than `Sandbox.new/1`.
  """
  @spec install(lua :: Lua.t()) :: Lua.t()
  def install(%Lua{} = lua) do
    install(lua, Capabilities.new())
  end

  @doc """
  Returns the empty `execution_context()` sentinel: every field `nil` except `variables`
  (`%{}`). This is what `install/1` and `install/2` pass down to `install/3` so their
  existing callers keep compiling and behaving exactly as before (REQ-159 design §2.3.1)
  -- `read_variable` returns `nil` for every lookup, `get_instance_state` returns the
  structured `"no_execution_context"` error without attempting a `Repo` call, and `log`
  still emits an entry with every correlation field `nil`, rather than any of the three
  crashing on a missing value.
  """
  @spec empty_execution_context() :: execution_context()
  def empty_execution_context do
    %{
      instance_id: nil,
      prefix: nil,
      trace_id: nil,
      script_identity: nil,
      actor_id: nil,
      variables: %{}
    }
  end

  @doc """
  REQ-160 design §2.4. Reads the current process's `write_variable` staging buffer
  (`%{}` if none was ever staged) and **clears** the process-dictionary entry before
  returning it, so a hypothetical second call in the same process observes an empty
  buffer rather than a stale one. Performs no `Letflow.Repo` call, no
  `Letflow.Engine.VariableMerge.merge/3` call, and no persistence of any kind -- a pure
  read-and-clear of process-local state. Deliberately unwired to any real caller by this
  requirement (design §2.5 OQ-1) -- the future caller must invoke this from inside the
  same process that ran the script, strictly after `Lua.eval!/2` has returned normally.
  """
  @spec take_staged_writes() :: staged_writes()
  def take_staged_writes do
    writes = Process.get(@staged_writes_pdict_key, %{})
    Process.delete(@staged_writes_pdict_key)
    writes
  end

  @doc """
  Same as `install/2`, with an EMPTY `execution_context()` (`empty_execution_context/0`).
  Retained for source compatibility with every existing `install/2` call site (REQ-157's
  own capability-denial tests in particular): `Capabilities.check!/3` still runs, and
  still raises, before any of the three real REQ-159 function bodies ever sees the empty
  context (design §2.3.1) -- only a *granted* call to `read_variable`/`get_instance_state`/
  `log` made through `install/2` rather than `install/3` observes the empty context's
  structured "not wired to production yet" behavior instead of real behavior.
  """
  @spec install(lua :: Lua.t(), capabilities :: Capabilities.grant_set()) :: Lua.t()
  def install(%Lua{} = lua, capabilities) do
    install(lua, capabilities, empty_execution_context())
  end

  @doc """
  The single registration point for the entire `platform.*` table (INV-CAP-1). Folds over
  `@capability_matrix`, calling `Lua.set!/3` once per row to bind `[:platform, row.name]`
  to a Lua-callable wrapper. `capabilities` **and** `execution_context` are each captured
  once per `install/3` call and closed over by every one of the 8 installed wrappers --
  both are fixed for the lifetime of the returned `Lua.t()`. See moduledoc "Deviation from
  the design's literal `run_stub/4`" for why the installed wrapper is the documented
  `fn args, lua -> ... end` (arity-2) form rather than the arity-1 form `install/2`
  previously used, and why that change is necessary rather than cosmetic.

  Each installed wrapper, when invoked with the Lua call's argument list:

    1. computes the capability this particular call requires by applying `row.required`
       to the argument list (a constant string for 6 of the 8 rows, parameterised by the
       first argument for `call_service`, or `:none` for `now`/`fail`);
    2. passes that value, `capabilities`, and `row.name` to
       `Letflow.Engine.Lua.Capabilities.check!/3` — the single gate call every wrapper
       makes; on denial it raises and the wrapper never proceeds to step 3;
    3. only if `check!/3` returns, invokes `row.stub` with the same argument list, the
       closed-over `execution_context`, and the call's own `Lua.t()`, returning its result
       as the Lua call's return value (and, for `read_variable`/`get_instance_state`, a
       possibly-updated `Lua.t()` carrying any newly-encoded table).
  """
  @spec install(
          lua :: Lua.t(),
          capabilities :: Capabilities.grant_set(),
          execution_context :: execution_context()
        ) :: Lua.t()
  def install(%Lua{} = lua, capabilities, execution_context) do
    Enum.reduce(@capability_matrix, lua, fn row, lua_acc ->
      Lua.set!(lua_acc, [:platform, row.name], fn args, call_lua ->
        required = required_capability(row.required, args)
        Capabilities.check!(capabilities, row.name, required)
        run_stub(row.stub, row.name, args, execution_context, call_lua)
      end)
    end)
  end

  # Resolves a `matrix_row.required` tag to the capability string (or `:none`) this
  # particular call requires, given the Lua call's argument list. `:call_service_arg0` is
  # the only row whose required capability depends on the call's arguments (§4.2) —
  # every other row is either a constant string or the unconditional `:none` that makes
  # `now`/`fail` ungated (§5, INV-CAP-4).
  @spec required_capability(required_capability_spec(), [term()]) ::
          Capabilities.capability() | :none
  defp required_capability(:none, _args), do: :none

  defp required_capability(:call_service_arg0, [svc_id | _]) when is_binary(svc_id) do
    Capabilities.service_capability(svc_id)
  end

  defp required_capability(:call_service_arg0, _args) do
    Capabilities.service_capability("")
  end

  defp required_capability(required, _args) when is_binary(required), do: required

  # Runs the stub body for a row, only ever reached after `Capabilities.check!/3` has
  # returned (i.e. the call was permitted, or `required` was `:none`). `now`/`fail`
  # ignore both `execution_context` and `lua` (they neither read tenant context nor
  # build a Lua table); `read_variable`, `get_instance_state`, `log` are REQ-159's three
  # real implementations, and `write_variable`, `call_service`, `emit_event` are
  # REQ-160's -- see moduledoc "Deviation from the design's literal `run_stub/4`" for why
  # this is `run_stub/5`, not the design's literal `run_stub/4`.
  @spec run_stub(stub_spec(), atom(), [term()], execution_context(), Lua.t()) ::
          [term()] | {[term()], Lua.t()} | no_return()
  defp run_stub(:now, _function_name, _args, _execution_context, _lua), do: [__MODULE__.now()]

  defp run_stub(:fail, _function_name, args, _execution_context, lua) do
    do_fail(args, lua)
  end

  defp run_stub(:read_variable, _function_name, args, execution_context, lua) do
    do_read_variable(args, execution_context, lua)
  end

  defp run_stub(:get_instance_state, _function_name, args, execution_context, lua) do
    do_get_instance_state(args, execution_context, lua)
  end

  defp run_stub(:log, _function_name, args, execution_context, lua) do
    {do_log(args, execution_context, lua), lua}
  end

  defp run_stub(:write_variable, _function_name, args, execution_context, _lua) do
    do_write_variable(args, execution_context)
  end

  defp run_stub(:call_service, _function_name, args, execution_context, lua) do
    do_call_service(args, execution_context, lua)
  end

  defp run_stub(:emit_event, _function_name, args, execution_context, lua) do
    do_emit_event(args, execution_context, lua)
  end

  # ── fail (LUA-15 restated, REQ-161 design §3.2) ───────────────────────────────────────
  #
  # Never returns: the only signal this function produces is the `exit/1` call in step
  # 3, which (design §2.2) no part of `tv-labs/lua`'s call chain intercepts -- not
  # `pcall`, not `xpcall`, not any other construct on the call boundary. Reached only
  # once the fold-level `:none` capability check has trivially passed (design §3.1 --
  # `fail` is ungated, never actually denies).
  @spec do_fail(args :: [term()], Lua.t()) :: no_return()
  defp do_fail(args, lua) do
    {reason_arg, details_arg} =
      case args do
        [reason, details | _rest] -> {reason, details}
        [reason] -> {reason, nil}
        [] -> {nil, nil}
      end

    reason_string = coerce_fail_reason(reason_arg, lua)
    details = decode_fail_details(details_arg, lua)

    script_failure = %{reason: reason_string, details: details}
    exit({:script_failed, script_failure})
  end

  # Step 1 (design §3.2): a binary `reason` is used as-is; a table reference (still its
  # internal `{:tref, id}` reference at this boundary -- see moduledoc "A related,
  # smaller correction to design §6.1 step 1") is decoded via `Lua.decode!/2` then
  # rendered via `inspect/1` (mirrors `do_log/3`'s `decode_log_context/2` handling of
  # the identical shape); anything else (a number, a boolean, ...) is rendered via
  # `inspect/1` directly; a missing `reason` defaults to the literal fallback string.
  defp coerce_fail_reason(nil, _lua), do: "script called platform.fail with no reason"
  defp coerce_fail_reason(reason, _lua) when is_binary(reason), do: reason
  defp coerce_fail_reason({:tref, _} = tref, lua), do: inspect(Lua.decode!(lua, tref))
  defp coerce_fail_reason(reason, _lua), do: inspect(reason)

  # Step 2 (design §3.2): a table reference is decoded via `Lua.decode!/2` (mirrors
  # `decode_lua_payload/2` above), then normalized through
  # `LuaNumberMarshalling.from_lua/1` one level deep on any resulting map's values
  # (mirrors `do_call_service/3`'s/`do_emit_event/3`'s own `normalize_from_lua/1`). A
  # missing `details` argument defaults to `nil`.
  defp decode_fail_details(nil, _lua), do: nil

  defp decode_fail_details(details, lua) do
    details
    |> decode_lua_payload(lua)
    |> normalize_from_lua()
  end

  # ── read_variable (LUA-11 read half, REQ-159 design §4) ──────────────────────────────
  #
  # Plain map lookup on the closed-over, already-resolved `execution_context.variables`
  # -- no `Letflow.Repo` call, ever (design §4.1/§2.2(c)). A malformed argument (not a
  # binary) and an unset key both return Lua `nil` -- LUA-11 names only "current value or
  # nil" as the two outcomes.
  @spec do_read_variable(args :: [term()], execution_context :: execution_context(), Lua.t()) ::
          {[term()], Lua.t()}
  defp do_read_variable([name | _rest], %{variables: variables}, lua) when is_binary(name) do
    case Map.fetch(variables, name) do
      {:ok, value} ->
        {encoded, lua} = Lua.encode!(lua, LuaNumberMarshalling.to_lua(value))
        {[encoded], lua}

      :error ->
        {[nil], lua}
    end
  end

  defp do_read_variable(_args, _execution_context, lua), do: {[nil], lua}

  # ── get_instance_state (REQ-159 design §5) ────────────────────────────────────────────
  #
  # Step order matters and is checked in this exact sequence, per design §5.2:
  #   1. `execution_context.prefix == nil` (empty-context sentinel) -> "no_execution_context",
  #      before even inspecting the argument.
  #   2. Argument not a binary, or not a valid UUID -> "invalid_id", before the self-scope
  #      check, so a malformed argument is never reported as "forbidden".
  #   3. Argument (cast) != `execution_context.instance_id` -> "forbidden", NO Repo call --
  #      identical outcome whether or not the id names a real row in this tenant's schema.
  #   4. Only on a match: `Repo.get/3` with `execution_context.prefix` (never anything
  #      derived from the argument). Missing row -> "not_found".
  #   5. Otherwise: success, a Lua table built via `Lua.encode!/2`.
  @spec do_get_instance_state(
          args :: [term()],
          execution_context :: execution_context(),
          Lua.t()
        ) :: {[term()], Lua.t()}
  defp do_get_instance_state(_args, %{prefix: nil}, lua) do
    encode_error(lua, "no_execution_context")
  end

  defp do_get_instance_state([raw_id | _rest], execution_context, lua) when is_binary(raw_id) do
    case Ecto.UUID.cast(raw_id) do
      :error ->
        encode_error(lua, "invalid_id")

      {:ok, instance_id} ->
        if instance_id == execution_context.instance_id do
          fetch_instance_state(instance_id, execution_context.prefix, lua)
        else
          encode_error(lua, "forbidden")
        end
    end
  end

  defp do_get_instance_state(_args, _execution_context, lua) do
    encode_error(lua, "invalid_id")
  end

  defp fetch_instance_state(instance_id, prefix, lua) do
    case Repo.get(InstanceProjection, instance_id, prefix: prefix) do
      nil ->
        encode_error(lua, "not_found")

      %InstanceProjection{} = projection ->
        status_string =
          InstanceProjection
          |> Ecto.Enum.mappings(:status)
          |> Keyword.fetch!(projection.status)

        variables =
          Map.new(projection.variables, fn {key, value} ->
            {key, LuaNumberMarshalling.to_lua(value)}
          end)

        {encoded, lua} = Lua.encode!(lua, %{status: status_string, variables: variables})
        {[encoded], lua}
    end
  end

  defp encode_error(lua, reason) do
    {encoded, lua} = Lua.encode!(lua, %{reason: reason})
    {[nil, encoded], lua}
  end

  # ── log (LUA-13, REQ-159 design §6) ───────────────────────────────────────────────────
  #
  # Correlation identity (`script_identity`/`instance_id`/`trace_id`) is sourced
  # EXCLUSIVELY from `execution_context`, never from the script's own arguments -- a
  # script controlling its own claimed identity would defeat the point of an audit trail
  # (design §6.3). Never raises, regardless of argument shape (design §6.1).
  @spec do_log(args :: [term()], execution_context :: execution_context(), Lua.t()) :: [term()]
  defp do_log(args, execution_context, lua) do
    {level_arg, message_arg, context} = split_log_args(args)
    level = map_log_level(level_arg)

    metadata =
      [
        script_identity: execution_context.script_identity,
        instance_id: execution_context.instance_id,
        trace_id: execution_context.trace_id,
        context: decode_log_context(context, lua)
      ] ++ unrecognized_level_metadata(level_arg, level)

    Logger.log(level, log_text(message_arg), metadata)

    []
  end

  # `context` arrives as whatever the Lua call passed -- `nil`/a string/number are
  # already plain Elixir terms, but a table argument is still its internal
  # `{:tref, id}` reference until explicitly decoded (see moduledoc "A related, smaller
  # correction to design §6.1 step 1").
  defp decode_log_context(nil, _lua), do: nil
  defp decode_log_context(context, lua), do: Lua.decode!(lua, context)

  defp split_log_args([level, message, context | _rest]), do: {level, message, context}
  defp split_log_args([level, message]), do: {level, message, nil}
  defp split_log_args([level]), do: {level, nil, nil}
  defp split_log_args([]), do: {nil, nil, nil}

  @known_log_levels ~w(debug info warn error)

  defp map_log_level("debug"), do: :debug
  defp map_log_level("info"), do: :info
  defp map_log_level("warn"), do: :warning
  defp map_log_level("error"), do: :error
  defp map_log_level(_unrecognized), do: :info

  # An unrecognized `level` string is tagged with `original_level` so it is visible in
  # the emitted entry rather than silently dropped or raised on (design §6.1 step 2).
  defp unrecognized_level_metadata(level_arg, :info) when level_arg not in @known_log_levels do
    [original_level: log_text(level_arg)]
  end

  defp unrecognized_level_metadata(_level_arg, _level), do: []

  defp log_text(value) when is_binary(value), do: value
  defp log_text(value), do: inspect(value)

  # ── write_variable (LUA-11 write half, REQ-160 design §3) ────────────────────────────
  #
  # Stages the write into the CURRENT PROCESS's own process dictionary (design §2.2/2.3)
  # -- never into `Lua.t()`'s own state (§2.3 explicitly rejects that mechanism). Makes
  # no `Letflow.Repo` call, ever. Never raises.
  @spec do_write_variable(args :: [term()], execution_context :: execution_context()) ::
          [term()]
  defp do_write_variable([name | rest], _execution_context) when is_binary(name) do
    value = List.first(rest)
    stage_write(name, LuaNumberMarshalling.from_lua(value))
    []
  end

  # Malformed (non-binary) `name` is a no-op with respect to staging -- `stage_write/2`
  # is never called -- and returns Lua `nil` (design §3.2 step 1).
  defp do_write_variable(_args, _execution_context), do: [nil]

  # `stage_write/2` (design §2.4) -- reads the current buffer from the process
  # dictionary (defaulting to `%{}` on the first write of a given execution), and
  # writes the updated map back to the same process-dictionary key. Last write wins
  # (`Map.put/3` semantics).
  @spec stage_write(name :: String.t(), value :: term()) :: :ok
  defp stage_write(name, value) do
    current = Process.get(@staged_writes_pdict_key, %{})
    Process.put(@staged_writes_pdict_key, Map.put(current, name, value))
    :ok
  end

  # ── call_service (LUA-12, REQ-160 design §4) ──────────────────────────────────────────
  #
  # Only ever reached once `Capabilities.check!/3` has already passed for this specific
  # call (design §4.3) -- no arm below raises for any reason; the only raise on this
  # entire call path is the fold-level capability gate, structurally prior to this
  # function ever running. Makes no `Letflow.Repo` call.
  @spec do_call_service(args :: [term()], execution_context :: execution_context(), Lua.t()) ::
          {[term()], Lua.t()}
  defp do_call_service([service_id | rest], _execution_context, lua) when is_binary(service_id) do
    payload =
      rest
      |> List.first()
      |> decode_lua_payload(lua)
      |> normalize_from_lua()

    caller = Application.get_env(:letflow, :lua_platform_service_caller, @default_service_caller)

    case caller.call(service_id, payload) do
      {:ok, response} when is_map(response) ->
        {encoded, lua} = Lua.encode!(lua, convert_map_to_lua(response))
        {[encoded], lua}

      {:error, reason} ->
        encode_error(lua, stringify_reason(reason))
    end
  end

  defp do_call_service(_args, _execution_context, lua) do
    encode_error(lua, "invalid_arguments")
  end

  # ── emit_event (REQ-160 design §5) ────────────────────────────────────────────────────
  #
  # `prefix:` is ALWAYS `execution_context.prefix` (decision 0014 (e)) -- never anything
  # derived from `event_type`/`payload`/`idempotency_key`, the three script-supplied
  # arguments. This is the one function this requirement adds that calls `Letflow.Repo`
  # at all (transitively, via `EventStore.append/2`). Never raises -- the only raise on
  # this call path is the fold-level `event:emit` capability gate.
  @spec do_emit_event(args :: [term()], execution_context :: execution_context(), Lua.t()) ::
          {[term()], Lua.t()}
  defp do_emit_event(_args, execution_context, lua)
       when is_nil(execution_context.prefix) or is_nil(execution_context.instance_id) or
              is_nil(execution_context.actor_id) do
    encode_error(lua, "no_execution_context")
  end

  defp do_emit_event([event_type, payload, raw_key | _rest], execution_context, lua)
       when is_binary(event_type) do
    # GH #2587: replay applies every folded type as an engine fact, so a script may
    # append none of them (checked before the key is namespaced or any DB access).
    if event_type in Reconstruction.folded_event_types() do
      encode_error(lua, "invalid_arguments")
    else
      emit_unfolded_event(event_type, payload, raw_key, execution_context, lua)
    end
  end

  defp do_emit_event(_args, _execution_context, lua) do
    encode_error(lua, "invalid_arguments")
  end

  defp emit_unfolded_event(event_type, payload, raw_key, execution_context, lua) do
    # GH #2550: the script's key is stored as `script:<actor>:<K>`, so a script
    # cannot claim a server or client key; an empty, non-string, over-199-byte,
    # invalid-UTF-8 or NUL-containing key, or a non-36-byte actor_id, is
    # invalid_arguments, before any database access.
    case Idempotency.script_key(raw_key, execution_context.actor_id) do
      {:ok, idempotency_key} ->
        append_emitted_event(event_type, payload, idempotency_key, execution_context, lua)

      {:error, :idempotency_key_invalid} ->
        encode_error(lua, "invalid_arguments")
    end
  end

  defp append_emitted_event(event_type, payload, idempotency_key, execution_context, lua) do
    decoded_payload =
      payload
      |> decode_lua_payload(lua)
      |> normalize_from_lua()

    json_payload = Jason.encode!(decoded_payload || %{})

    attrs = %{
      instance_id: execution_context.instance_id,
      event_type: event_type,
      payload: json_payload,
      actor_id: execution_context.actor_id,
      idempotency_key: idempotency_key
    }

    case EventStore.append(attrs, prefix: execution_context.prefix) do
      {:ok, _append_result} -> {[true], lua}
      {:error, reason} -> encode_error(lua, stringify_reason(reason))
    end
  end

  # `payload` arrives as whatever the Lua call passed -- `nil`/a string/number are
  # already plain Elixir terms, but a table argument is still its internal `{:tref, id}`
  # reference until explicitly decoded (mirrors `decode_log_context/2` above, same
  # underlying `tv-labs/lua` boundary behaviour, shared here by `call_service` and
  # `emit_event`). Per `Lua.decode_list!/2`'s own doctest, `Lua.decode!/2` decodes a
  # table into a PROPLIST (`[{key, value}]`), not a map -- `normalize_decoded_table/1`
  # below turns an object-shaped proplist (every key a binary -- the shape
  # `call_service`'s/`emit_event`'s payload is documented to be, "typically a table")
  # into an actual `map()`, since `ServiceCaller.call/2`'s callback contract and
  # `Jason.encode!/1` both expect one; this is a shape normalization, not a second
  # numeric-conversion rule (REQ-150's identity rule is applied separately, in
  # `normalize_from_lua/1` below).
  defp decode_lua_payload(nil, _lua), do: nil
  defp decode_lua_payload(payload, lua), do: Lua.decode!(lua, payload)

  # REQ-150 §2.1 (write direction) applied to every value of a decoded table, one level
  # deep -- mirrors `fetch_instance_state/3`'s own per-value application above. A
  # decoded payload that is not an object-shaped proplist has the same identity rule
  # applied directly (REQ-150's rule is identity for every numeric/`nil` shape
  # regardless of surrounding structure, so this is not a second conversion rule).
  defp normalize_from_lua(value) when is_list(value) do
    if object_shaped_proplist?(value) do
      Map.new(value, fn {key, v} -> {key, LuaNumberMarshalling.from_lua(v)} end)
    else
      LuaNumberMarshalling.from_lua(value)
    end
  end

  defp normalize_from_lua(value), do: LuaNumberMarshalling.from_lua(value)

  # `true` for `[]` (the empty table -- treated as an empty object, matching
  # `Jason.encode!(%{})`'s "{}" ) and for a non-empty list where every element is a
  # `{binary(), _}` pair (a Lua table keyed entirely by string keys, e.g.
  # `{amount = 100}`) -- `false` for an array-shaped table (integer keys) or a bare
  # list of scalars, neither of which this requirement's own acceptance criteria (both
  # of which use only string-keyed payloads) require converting to a map.
  defp object_shaped_proplist?([]), do: true

  defp object_shaped_proplist?(list) when is_list(list) do
    Enum.all?(list, fn
      {key, _value} -> is_binary(key)
      _other -> false
    end)
  end

  # REQ-150 §2.2 (read direction), symmetric with `normalize_from_lua/1` above.
  defp convert_map_to_lua(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, LuaNumberMarshalling.to_lua(value)} end)
  end

  defp convert_map_to_lua(other), do: LuaNumberMarshalling.to_lua(other)

  # Renders a `call_service`/`emit_event` failure reason as a Lua-encodable string
  # (design §4.5/§5.4). An atom (e.g. `:service_caller_not_configured`,
  # `:unknown_event_type`) stringifies to its own name; a tagged tuple (e.g.
  # `{:invalid_metadata, _}`, `{:sequence_conflict, _}`) stringifies to its head atom's
  # name (OQ-3: this design does not specify a richer rendering, and none of REQ-160's
  # own acceptance criteria require one); anything else falls back to `inspect/1`.
  defp stringify_reason(reason) when is_binary(reason), do: reason
  defp stringify_reason(reason) when is_atom(reason), do: to_string(reason)

  defp stringify_reason(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    reason |> elem(0) |> stringify_reason()
  end

  defp stringify_reason(reason), do: inspect(reason)

  defmodule ServiceCaller do
    @moduledoc """
    Behaviour for `Letflow.Engine.Lua.Platform.call_service/3`'s injectable service
    dispatcher (REQ-160 design §4.2), mirroring `TimeSource`'s own injection pattern in
    this same file. A real implementation is not built by this requirement -- the
    default, `Letflow.Engine.Lua.Platform.NoServiceCaller`, always returns
    `{:error, :service_caller_not_configured}`. Installed via
    `Application.put_env(:letflow, :lua_platform_service_caller, <module>)`, resolved
    fresh on every `call_service` invocation (never cached).
    """

    @callback call(service_id :: String.t(), payload :: term()) ::
                {:ok, response :: map()} | {:error, reason :: term()}
  end

  defmodule NoServiceCaller do
    @moduledoc """
    Default `ServiceCaller` implementation. Always returns a structured, honest
    "nothing is wired yet" error -- never a crash -- until some future requirement
    configures a real implementation via application env (REQ-160 design §4.2, OQ-2).
    """

    @behaviour ServiceCaller

    @impl ServiceCaller
    @spec call(String.t(), term()) :: {:error, :service_caller_not_configured}
    def call(_service_id, _payload), do: {:error, :service_caller_not_configured}
  end

  defmodule TimeSource do
    @moduledoc """
    Behaviour for `Letflow.Engine.Lua.Platform.now/0`'s injectable time source. A test
    double implements this behaviour and is installed via
    `Application.put_env(:letflow, :lua_platform_time_source, <module>)` to make
    `platform.now()` return one exact, pre-set timestamp.
    """

    @type source_now_result :: DateTime.t()

    @callback now() :: source_now_result()
  end

  defmodule SystemClock do
    @moduledoc """
    Default `TimeSource` implementation. The one and only production call site of
    `DateTime.utc_now/0` this requirement's module set (`platform.ex`) introduces — every
    other read of "now" for Lua-visible time goes through `Platform.now/0`, which
    resolves the configured `TimeSource` rather than reading the system clock directly.
    """

    @behaviour TimeSource

    @impl TimeSource
    @spec now() :: DateTime.t()
    def now, do: DateTime.utc_now()
  end
end
