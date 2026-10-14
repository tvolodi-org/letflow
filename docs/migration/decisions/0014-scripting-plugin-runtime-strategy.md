# 0014 — Scripting & plugin runtime strategy: bind Lua in pure Elixir, bind WASM via a NIF behind a process boundary

Amended by 0053 (`0053-tenant-scripted-rules.md`): point (e) and point 4 (WASM host-API parity) as listed in 0053's supersession section.

Status: decided (2026-08-23). Owner: CODE-DESIGNER (S5 requirement expansion executes it).

## Question

`docs/migration/stage-5-scripting-plugins.md` names this record as a hard prerequisite:

> Needs its own decision record before requirements are expanded: build-vs-bind —
> Elixir NIFs/Ports/Rustler wrapping existing Lua/WASM runtimes, vs. reimplementing
> scripting support natively. This is a materially different kind of decision than
> S0's (library ecosystem maturity and NIF safety/crash-isolation tradeoffs matter
> more here than for, say, OIDC).

Two shipped S3 modules deferred to this record by name and are blocked on it:

| Module | What it deferred |
|---|---|
| `lib/letflow/engine/lua_script_audit.ex` (REQ-058, LUA-07) | Types `Executor.script_ref` as opaque `term()` because "S5's build-vs-bind decision record … is a prerequisite for whoever supplies a real Executor implementation; this module does not pre-empt that choice." |
| `lib/letflow/engine/plugin_interface.ex` (REQ-057, EXT-03) | Supports "**only in-process Elixir modules** … no WASM sandboxing (R-Co's `src/wasm/`, S5, needs its own build-vs-bind decision record first)." |

S5 covers **both halves** — Lua and WASM/plugins. That scoping is settled by the user
and is not reopened here.

## Evidence — R-Co source, verified directly against the live tree

PROVENANCE (historical, not current decision authority):
Counted with `find … -name '*.zig' -exec wc -l {} +` against
`c:\Users\tvolo\dev\ai-dala\R-Co\` on 2026-08-23:

```
src/lua/    29 files   8,365 lines
src/wasm/   19 files   1,396 lines
                       -----
                       9,761 lines
```

This matches `stage-5-scripting-plugins.md`'s file counts (29 / 19). The line split does
not: **86% of the Zig is the Lua half.** That asymmetry is the first thing this record
turns on, and it is not a measure of relative complexity — it is a measure of how much
of each half actually exists.

### The Lua half is real code

PROVENANCE (historical, not current decision authority):
`src/lua/luajit_bindings.zig` (318 lines) binds a real, statically-linked LuaJIT 2.1,
vendored at `vendor/luajit/` (`COPYRIGHT`, `build.zig`, `dynasm/`, `src/` all present)
and built through the upstream three-stage bootstrap (minilua → dynasm → buildvm). Its
header records a subsystem that rotted for three months:

> Stage 9 (commit 113bdb3, May 2026) wrote this file as `@cImport` + `pub extern fn
> lua_*`, but no LuaJIT existed in the repo, so any target that pulled it in failed at
> translate-C time. That is why the subsystem stayed unreferenced and rotted unobserved
> for three months while LUA-01..16 sat marked RELEASED.

ISS-0153 / GH #471 replaced the unresolvable surface with honest failing stubs; ISS-0161
/ GH #485 vendored the real LuaJIT. Line 285 reads "ISS-0161: now `true` — LuaJIT is
vendored and statically linked," and line 288 opens a test named "ISS-0161: a real
LuaJIT is linked and executes Lua."

Two hard-won invariant sets live in that half and must survive any port:

PROVENANCE (historical, not current decision authority):
- `src/lua/stdlib.zig` (143 lines) — **SBX-1: prune strictly AFTER open** ("open base
  FIRST, prune AFTER"; line 111 warns that reordering breaks it). Never opened: `io`,
  `os`, `package`, `debug`, `jit`, `ffi`, `bit`, `coroutine`. Line 57 states `ffi` is
  "a COMPLETE sandbox escape (arbitrary memory …)".
PROVENANCE (historical, not current decision authority):
- `src/lua/instruction_limiter.zig` (126 lines) — **INV-2**: the registry is not
  reachable from script code ("Lua source syntax has no way to name a pseudo-index").
  **INV-4**: one combined `LUA_MASKCOUNT` hook (line 72,
  `bindings.lua_sethook(L, hookCallback, bindings.LUA_MASKCOUNT, …)`), folding the
  elapsed-time check into the instruction hook because it is "the only mechanism in the
  codebase that can interrupt a tight `while true do end` loop."

### The WASM half is entirely stubs

PROVENANCE (historical, not current decision authority):
`src/wasm/wasmtime_bindings.zig` (250 lines) header:

> NOTE: Actual C FFI integration deferred to Stage 10.
> For now, provide type stubs to allow module testing and compilation.

PROVENANCE (historical, not current decision authority):
`Engine`, `Store`, `Instance`, `Module`, `Func`, `Trap`, `Memory` are all declared
`extern struct {}` — empty. Line 54: "Stub functions (will be replaced with real C FFI
in Stage 10)". Line 58: `return null; // Stub: actual implementation in Stage 10`.
`grep -rn "Stage 10" src/wasm/` returns 12 hits across eight files, including
`src/wasm/timeout.zig` (46 lines, lines 10 and 42: "will use real clock in Stage 10"),
`src/wasm/module_registry.zig:72` ("Placeholder: use constant time"),
`src/wasm/executor.zig:117`, and four `host_api/` placeholders
(`call_service.zig`, `read_variable.zig`, `write_variable.zig`, `uuid.zig`).

PROVENANCE (historical, not current decision authority):
**There is no working Wasmtime integration in R-Co.** This is load-bearing and must not
be papered over: the WASM half of S5 is a **specification port** from
`R-Co/docs/addon-1/02-functional-requirements.md` (WASM-01..14, Stage 9), not a code
port. No Zig behaviour exists to be faithful to, and `timeout.zig`'s placeholder clock
means even its resource-limit semantics were never exercised.

### There is no existing script corpus — script authoring is greenfield

This is the finding that decides the Lua version question, so it was checked directly:

```
find R-Co -name '*.lua' -not -path '*/vendor/*' -not -path '*/.git/*'   → 0 files
find R-Co -name '*.lua' -not -path '*/.git/*'                           → 145 files
find letflow-2 -name '*.lua' -not -path '*/.git/*'                      → 0 files
find R-Co -name '*.wasm' -not -path '*/.git/*'                          → 0 files
```

All 145 `.lua` files are LuaJIT's own vendored build and test sources under
`vendor/luajit/`. **Zero workflow scripts exist** — not in R-Co, not in Letflow. Zero
compiled `.wasm` artifacts exist. Both requirement families were built as runtime
capability with no content ever authored against them. Per LUA-01..16's own framing,
scripts are "generated by the Developer Agent" — i.e. authored in future, against
whatever dialect Letflow ships.

### Letflow today

`mix.exs` deps: `ecto_sql`, `postgrex`, `plug`, `bandit`, `jason`, `stream_data` (test
only), `ueberauth_oidcc`. **No Lua, WASM, NIF, or Rustler dependency of any kind.**
`.tool-versions` pins `elixir 1.20.3-otp-29` / `erlang 29.0.5`. `lib/letflow/application.ex:45`
already supervises `{Task.Supervisor, name: Letflow.Engine.PluginTaskSupervisor}`.

## Evidence — Elixir ecosystem, from published documentation

**No dependency was added, compiled, or executed in producing this record.** Each fact
below is read from the library's published documentation on 2026-08-23 and is cited as
documentation, not as an observed result. S5's first requirement must verify these
behaviours by actually running them.

**On what is verifiable here (corrected 2026-08-23, REVIEWER re-gate).** An earlier
revision of this record justified the above by asserting the sandbox has no network
access for `mix deps.get`. **That is false and was removed.** `hex.pm` and
`repo.hex.pm` were both reached over HTTPS while gating this record (`repo.hex.pm`
serves package tarballs, so a dependency fetch is very likely to succeed), and the
published docs cited throughout were fetched live. The distinction that actually holds
is narrower and is the one stated above: nothing was *run*. Do not read this section as
licence to skip a check that can in fact be performed here — in particular, OQ-2's
"validate the selection against a real spike" is plausibly tractable in this
environment, and an agent picking up that spike should attempt it rather than assume it
is blocked. Whether `mix deps.get` actually completes was not tested; assert it only
after running it.

**`tv-labs/lua` v1.0.2** (Apache-2.0, ~392k all-time downloads, updated 2026-07-29,
github.com/tv-labs/lua). Per `lua.hexdocs.pm/Lua.html`: a **Lua 5.3** runtime with "no
NIFs, no C, no Erlang runtime dependency" — "the lexer, parser, register-based VM, and
standard library all run directly on the BEAM." `Lua.new/1` sandboxes 27 paths by
default, including all `io.*`, `os.execute`, `os.exit`, `os.getenv`, `os.remove`,
`os.rename`, `os.tmpname`, `package`, `load`, `loadfile`, `loadstring`, `require`,
`dofile`. Resource limits: `:max_instructions` (raises "instruction budget exceeded")
and `:max_call_depth` (raises "stack overflow"), both defaulting to `:infinity` and both
catchable in-band via `pcall`. Host functions via `Lua.set!/3`, the `deflua` macro, or
`Lua.load_api/2`. Opaque host terms round-trip as `{:userdata, term}` — "Lua can hold the
reference and hand it back, but cannot inspect or dereference it." It began as a Luerl
wrapper; as of 1.0.0 it is a full Elixir-native reimplementation.

**`luerl` v1.5.1** (Apache-2.0, ~726k downloads) — Robert Virding's Erlang Lua
implementation, the older and more-downloaded alternative, also pure BEAM.

**`wasmex` v0.15.1** (MIT, ~73k downloads, updated 2026-08-07). Per
`wasmex.hexdocs.pm/Wasmex.html`: "It uses wasmtime to execute Wasm binaries through a
Rust NIF." Modules are instantiated inside a GenServer. "If a call times out, Wasmex
interrupts its WebAssembly execution and keeps the Store available for subsequent
calls." `Wasmex.EngineConfig` exposes `:consume_fuel` (default `false`) and
`:cranelift_opt_level`; `Wasmex.StoreLimits` exposes `memory_size` ("maximum number of
bytes a linear memory can grow to"), `table_elements`, `instances`, `tables`, `memories`.

**`rustler` v0.38.0** — required for any hand-rolled NIF path.

## Decision

**Bind, on both halves — but bind at two different depths, chosen per half.**

1. **Lua: adopt `tv-labs/lua` (pure-Elixir Lua 5.3 VM). No NIF, no Port, no C, no
   reimplementation.** The `LuaScriptAudit.Executor` behaviour is implemented against
   it, resolving `script_ref` to a concrete type at that point.
2. **WASM: adopt `wasmex` (Wasmtime via Rust NIF) — but every guest invocation must
   cross a process boundary first**, dispatched through a supervised task exactly as
   `PluginInterface.invoke/2,3` already does, never called inline from an engine or
   request process.
3. **Neither runtime is reimplemented.** "Build" is rejected on both halves.
4. **Lua lands first; WASM lands second and depends on it.** WASM-12 defines the WASM
   host API by *parity with Lua's*, so the Lua host API is the definition WASM conforms
   to. Expansion must order the requirements that way.

`PluginInterface` stays in-process-Elixir-only. WASM plugins arrive as a **separate**
handler family — a `wasmex`-backed module that itself implements the existing
`@behaviour` — not as a change to `PluginInterface`'s contract.

## Reasoning

### (a) The crash-isolation argument splits the two halves — it does not resolve them the same way

This is the tradeoff the stage doc says matters most here, and it is genuinely
asymmetric between Lua and WASM.

A NIF crash takes down the **entire BEAM node**. No supervisor recovers it, because
supervision is a process-level mechanism and a NIF segfault is a process-level event
only in the sense that the OS process *is* the node. A NIF that runs long **blocks a
BEAM scheduler thread** unless it is a dirty NIF or yields cooperatively. Both hazards
are strictly worse for code paths that execute **tenant-supplied, adversarial-by-default
input** — which is exactly what a workflow script is.

PROVENANCE (historical, not current decision authority):
For **Lua**, `tv-labs/lua` removes the hazard class entirely rather than mitigating it.
There is no native code: a runaway script is BEAM bytecode executing in an ordinary
BEAM process, killable by ordinary BEAM means. Note precisely what this replaces.
R-Co had to hand-build `instruction_limiter.zig` and route elapsed-time checking through
a single `LUA_MASKCOUNT` hook (INV-4) specifically because that hook is "the only
mechanism in the codebase that can interrupt a tight `while true do end` loop." The BEAM
equivalent is not a hook at all: a preemptively-scheduled process is interruptible by
construction, so `Process.exit(pid, :kill)` from a supervising process terminates a tight
loop with no cooperation from the script and no in-VM instrumentation. `:max_instructions`
then serves as the *in-band, catchable* limit (LUA-08), and the enclosing process kill
serves as the *out-of-band, host-enforced* limit (LUA-10 — whose text explicitly demands
enforcement "by the host (not relying on Lua to cooperate)"). Getting both layers for
free, on a runtime whose whole failure surface is a supervised process, is a strictly
better position than R-Co reached after ISS-0153 and ISS-0161.

For **WASM**, no pure-BEAM option exists at all — the only credible path is a NIF, so
the hazard cannot be designed away and must be **contained** instead. Three facts make
containment adequate: (i) Wasmtime is a mature, sandboxing-focused runtime whose entire
design goal is safely executing untrusted guests, so the trust argument is far stronger
than for an arbitrary NIF; (ii) `wasmex` documents that a timed-out call is interrupted
and its Store stays usable, which is the interruption primitive WASM-11 needs; (iii)
placing every invocation behind a supervised task means a hang degrades one task rather
than an engine process, and the scheduler-blocking risk is bounded to whatever the guest
does between fuel checks. This is a real, accepted residual risk — a Wasmtime or NIF-layer
bug can still take the node down, and no supervisor will save it. It is stated here
rather than hidden, and it is the price of WASM support at all.

**Correction to point (ii) — REVIEWER, WF-02 Step 2d, REQ-170, 2026-08-28.** Point (ii)
as written above is **live-verified false**, not merely imprecisely worded (contrast
WASM-10's correction, which found the security property held even though the "trap"
wording did not): a genuinely hanging guest is never interrupted by `wasmex`'s documented
mechanism at any bound tested up to 30 seconds, and the Store does not stay usable — it
is permanently wedged (`lib/letflow/design/req170-wasm-wallclock-timeout.md` §1.1-§1.4).
Point (iii)'s "a hang degrades one task" is also incomplete in light of the same
verification: the *task* is bounded, but the underlying native compute is not degraded,
it is **leaked** — permanently, into `wasmex`'s node-global, CPU-count-sized worker-thread
pool, a resource shared by every tenant's WASM calls on the node — and enough leaked
invocations stall unrelated, non-hanging guest calls (§1.5). This is filed here as a
correction to the *evidence* this reasoning cites, not as a re-derivation of the
paragraph's overall adequacy conclusion: whether the *containment argument as a whole*
still holds — given (i) still stands unmodified, the caller-facing guarantee in (iii)
still holds for the calling process/task even though the native-compute claim does not,
and no bug or crash is required to reach this exhaustion surface (only an ordinary
adversarial-by-default guest, WASM-11's own threat model) — is exactly OQ-5's question,
not settled here. See OQ-5's amendment below and REQ-170's design doc §2/§7/§8 for the
full evidence. This correction narrows what (ii)/(iii) may be cited for; it does not by
itself reverse the Decision.

The two conclusions differ because the evidence differs, not because a uniform answer
was avoided.

### (b) The Lua 5.1 → 5.3 gap costs approximately nothing, because there is nothing to port

R-Co targets Lua 5.1 (LuaJIT); `tv-labs/lua` implements Lua 5.3. That is a real dialect
difference, and the honest question is what it costs *here*.

The differences that matter to a workflow-scripting use case:

| 5.1 → 5.3 change | Impact on this use case |
|---|---|
| Integer/float subtype distinction | The only one with real semantic weight — `3/2` is `1.5`, and integer division needs `//`. Affects how numbers round-trip into JSON/Ecto variable storage; must be settled once in the variable-marshalling layer, not per script. |
| `unpack` → `table.unpack` | Naming only. |
| `setfenv`/`getfenv` removed (5.2) | **Beneficial.** These were the classic sandbox-escape and sandbox-construction primitive; the `_ENV` upvalue model is stricter. |
| Bitwise operators, `goto`, `//` | Additions. Nothing to lose. |
| `__ipairs` deprecated | Irrelevant absent 5.1 metatable-heavy library code. |

Crucially, **the migration cost of a dialect gap is proportional to the volume of
existing script content, and that volume is zero.** No `.lua` file exists outside
LuaJIT's own vendored sources — not in R-Co, not in Letflow. LUA-01..16 shipped as
capability with no corpus authored against it, and the requirements themselves describe
scripts as generated by the Developer Agent in future. There is no legacy dialect to
preserve compatibility with; there is only a dialect to choose for scripts not yet
written. Choosing the newer, stricter one with no `setfenv` is the better default.
This gap would be a serious objection against a large existing corpus. Here it is close
to free, and it is only because the corpus was actually checked that this can be said
rather than assumed.

### (c) LuaJIT-via-Rustler and the Port option, and why both lose

**LuaJIT via a Rustler/C NIF** would satisfy LUA-01's literal text, and would keep the
5.1 dialect. It also imports every hazard in (a) onto the tenant-script path, and
requires Letflow to re-derive R-Co's entire sandbox invariant set — SBX-1's open-then-prune
ordering, INV-2's registry unreachability, INV-4's combined hook — in a second language,
against a runtime whose `ffi` library is documented in R-Co's own source as "a COMPLETE
sandbox escape." R-Co needed 8,365 lines of Zig to reach that position and lost three
months to the subsystem rotting unobserved. Re-deriving it in Rust/C to gain a dialect
nobody has written a line of code in is a poor trade.

**An external Port process** (Lua or WASM in an OS subprocess) gives genuine crash
isolation — a segfault kills the port, not the node. It costs a serialization boundary
on every host-API call. That is the disqualifier: LUA-11's `read_variable`/`write_variable`
and LUA-12's `call_service` are *chatty*, per-call host round-trips, and a script doing
a dozen variable reads would pay a dozen IPC round-trips. It also adds OS-process
lifecycle management, orphan reaping, and a per-tenant process-accounting problem the
BEAM otherwise solves. For Lua, a Port buys isolation that `tv-labs/lua` already provides
more cheaply. For WASM, a Port remains the fallback if `wasmex` proves unstable under
load — recorded in Open questions, not adopted now.

**Reimplementing either runtime natively** is rejected without extended argument: a Lua
VM already exists on the BEAM in two independent implementations, and hand-writing a
WASM interpreter is a multi-year project wholly disproportionate to S5.

### (d) The existing seams survive unchanged — verified against the actual code

This was checked by reading both modules in full, not inferred.

`LuaScriptAudit.Executor`'s callback is:

```
@callback execute_with_manifest(script_ref(), registered_hash :: String.t()) ::
            {:ok, manifest_result()} | {:error, term()}
```

with `@type script_ref :: term()` and `@type manifest_result :: %{manifest_hash: String.t()}`.
A `tv-labs/lua`-backed executor implements this **with no change to the behaviour**:
`script_ref` resolves to a script-identity term (S5 fixes its concrete shape; the
behaviour's `term()` accommodates whatever is chosen), and every failure mode — sandbox
violation, instruction-budget exhaustion, wall-clock kill, `platform.fail` — folds into
the existing `{:error, term()}` arm. The module's ordering guarantees are untouched:
`instance_id` is still validated before the executor is invoked (INV-LSA-1), and the
mismatch check (INV-LSA-2) is performed by `LuaScriptAudit` itself "regardless of what
this callback does with `registered_hash`," so a non-conforming executor still cannot
bypass it. **The opaque `term()` was the right call and is now cashed in, not amended.**

`PluginInterface` also needs no contract change. Its `@callback handle_node(context) ::
{:complete, map()} | {:error, String.t()}` and its `invoke/2,3` crash-safe dispatch —
`Task.Supervisor.async_nolink/2` under the already-supervised
`Letflow.Engine.PluginTaskSupervisor`, then `Task.yield/2`, then `Task.shutdown(task,
:brutal_kill)` on timeout — are exactly the process boundary decision (2) requires for
WASM. A WASM plugin handler is an ordinary Elixir module implementing the existing
behaviour that happens to call `wasmex` inside `handle_node/1`. Its moduledoc's stated
scope boundary ("only in-process Elixir modules … no WASM sandboxing") remains literally
true and needs no rewrite: the handler module *is* in-process Elixir; the guest it
delegates to is not a dynamically-loaded Elixir plugin.

One limitation must be carried forward honestly. `PluginInterface`'s moduledoc already
discloses that it does **not** cover "a hard kill of the BEAM node itself, or
`System.halt/0`." Under decision (2), a Wasmtime-layer NIF crash falls into precisely
that disclosed-and-uncovered class. The process boundary bounds hangs and guest traps,
not native crashes. S5 must not claim otherwise.

### (e) Multi-tenancy composes with decision 0006 rather than complicating it

Letflow is schema-per-tenant (`decisions/0006`), and `LuaScriptAudit` already enforces
the discipline: no `@schema_prefix`, every `Repo` call passes `prefix:` explicitly, no
`tenant_id` column, and a missing `:prefix` fails closed with `{:error, :missing_prefix}`
rather than silently resolving to `public` (INV-LSA-6).

Neither runtime choice touches that boundary, because **neither runtime is given
database access at all.** Host functions receive already-resolved values; the tenant
prefix is supplied by the calling engine code, never derived inside a script. LUA-02's
state isolation ("fresh `lua_State` or a fully reset state") maps to constructing a new
`Lua.new/1` state per invocation — a fresh immutable BEAM term, so cross-invocation
global leakage is not merely prevented but unrepresentable. WASM-08/WASM-13's per-invocation
isolation is the harder case: `wasmex` pooling deliberately reuses a Store, so if
WASM-13's pooling optimization is taken up, memory reset between invocations becomes a
correctness requirement rather than a performance nicety. Recorded in Open questions.

### (f) Nothing here contradicts an existing decision record

Checked against the S0 records. `0001-web-framework.md` (Plug/Bandit per its **Addendum
(2026-08-20) at line 159, which reverses the original Decision** — that record's Decision
heading still reads "Letflow migrates to **Phoenix**", so a reader checking only the
heading will get the superseded answer) is unaffected — neither `tv-labs/lua` nor
`wasmex` is Phoenix-coupled, and
neither participates in the HTTP layer. `0006` composes as described in (e). `0003`
(Ecto schema strategy) is untouched; `LuaScriptAudit.AuditRecord` already conforms.
No S0 record settled a scripting runtime, a NIF policy, or a native-dependency policy,
so nothing is being silently re-decided.

`wasmex` does introduce Letflow's **first native-code build dependency** (a Rust
toolchain), against a repo whose current dep list is pure BEAM and whose `.tool-versions`
pins only Elixir and Erlang. That is a genuine new cost — CI must gain a Rust toolchain,
and `0005-pin-formatting-toolchain.md`'s pinning discipline argues that toolchain should
be pinned too. It is a consequence, not a contradiction, and it is one more reason the
Lua half is better served without a NIF.

## Requirements NOT satisfiable as literally worded

PROVENANCE (historical, not current decision authority):
S5's expansion **must restate these rather than claim them met.** Silently marking a
requirement RELEASED against a runtime that does not satisfy its literal text is exactly
the failure mode `luajit_bindings.zig`'s header records — LUA-01..16 sat "marked
RELEASED" for three months while nothing executed.

**LUA-01 — LuaJIT Integration.** Literal text: "The platform MUST embed LuaJIT and
expose it through Zig C-interop. Linking MUST be static." A pure-Elixir Lua 5.3 VM
satisfies **none** of the three clauses: it is not LuaJIT, there is no Zig, and there is
no linking. *Intent restatement:* the platform must embed a Lua runtime in-process, with
no external Lua runtime dependency at deploy time. `tv-labs/lua` satisfies that intent
more completely than static linking does — a BEAM-only dependency means no shared
library, no C toolchain, and no ABI surface whatsoever.

**LUA-03 — Stdlib Restriction.** Names a LuaJIT/5.1 module set and specific functions:
"MUST NOT load `io`, `os`, `package`, `debug`"; "MUST remove `string.dump`,
`os.execute`, `loadstring`, `load`, `loadfile`, `dofile`." Partly satisfied by
`Lua.new/1`'s documented 27-path default sandbox, but not congruent: `loadstring` is a
5.1 name, and R-Co additionally never opens `jit`, `ffi`, `bit`, and `coroutine` —
`jit`, `ffi`, and `bit` are **LuaJIT-specific and do not exist in Lua 5.3 at all**, so
three of R-Co's most security-critical exclusions are vacuous under the chosen runtime,
including the `ffi` "COMPLETE sandbox escape." *Intent restatement:* enumerate the
denied surface against Lua 5.3's actual stdlib, verify each denial by test, and treat
`coroutine` as an explicit decision rather than an inherited one. R-Co's SBX-1
open-then-prune ordering constraint does not transfer as-is, since `Lua.new/1` sandboxes
by construction rather than by post-hoc pruning — the *property* SBX-1 protects (no
window in which a dangerous global is reachable) must still be asserted by test.

**The `os` surface is the concrete instance of that enumeration, and it is wider than
the default deny-set.** Lua 5.3's `os` library contains eleven functions (verified
against the Lua 5.3 reference manual index): `os.clock`, `os.date`, `os.difftime`,
`os.execute`, `os.exit`, `os.getenv`, `os.remove`, `os.rename`, `os.setlocale`,
`os.time`, `os.tmpname`. `Lua.new/1`'s documented default sandbox denies **six** of
them — `execute`, `exit`, `getenv`, `remove`, `rename`, `tmpname`. It does **not** deny
`os.clock`, `os.date`, `os.difftime`, `os.setlocale`, or `os.time`; none of those five
appears anywhere in the documented default list. R-Co, by contrast, never opened the
`os` table at all, so all eleven were unreachable. Whoever expands LUA-03 must close
that five-function gap explicitly — it is not inherited from the library's defaults.
`os.time` in particular is LUA-14's entire acceptance criterion; see LUA-14 below.

**A trap in the mechanism, for whoever implements the enumeration:** per `Lua.new/1`'s
documentation, the `:sandboxed` option **replaces** the default list rather than adding
to it ("Alternatively, you can pass your own list of functions to sandbox"), while
`:exclude` removes paths from the sandbox. So denying `os.time` by passing
`sandboxed: [[:os, :time]]` would silently **un-deny** the twenty-seven paths the default
list covers, including `os.execute` and `load`. Any custom list must restate the full
deny-set, and a test must assert the *default* denials still hold afterward — not merely
that the newly added ones do.

**LUA-04 — Bytecode Loading Disabled.** "The sandbox MUST refuse to load Lua bytecode."
`tv-labs/lua` parses Lua **source text** and has no bytecode loader to disable; there is
no LuaJIT bytecode format in play. *Intent restatement:* only source text is accepted —
satisfied structurally, but must be restated as such rather than claimed as an
implemented refusal, because there is no rejection path to test.

**LUA-08 / LUA-10 — Instruction Limit / Wall Clock Timeout.** Satisfiable, but **not by
one mechanism**, and the requirements are not interchangeable. `:max_instructions` is
in-band and, per the docs, raises a **catchable** error recoverable via `pcall` — meaning
a hostile script can `pcall` its own budget exhaustion and continue. LUA-10 demands
enforcement "by the host (not relying on Lua to cooperate)." *Restatement:* both layers
are mandatory — `:max_instructions` for LUA-08, and an out-of-band supervising-process
kill for LUA-10 — and a test must confirm a script that traps its own instruction error
is still terminated by the outer kill.

**LUA-09 — Memory Limit.** "Each script execution MUST have a configurable memory limit.
Allocations exceeding the limit MUST fail gracefully." `tv-labs/lua` documents
`:max_instructions` and `:max_call_depth` — **no memory limit option is documented.**
LuaJIT had a custom allocator hook; a pure-BEAM VM allocates as ordinary BEAM terms. The
BEAM's nearest primitive is a per-process heap limit (`max_heap_size`), which kills the
process rather than failing an allocation gracefully. *This is the weakest point of the
Lua decision and must not be glossed.* **Open question OQ-1** below; S5 must not mark
LUA-09 met without resolving it.

**LUA-14 — Time Source.** "`platform.now()` MUST return the platform's authoritative
time as ISO 8601 UTC. **Lua's `os.time` MUST NOT be available.**" *Acceptance:*
"**`os.time` is `nil`**; `platform.now()` returns valid timestamp." The `platform.now()`
half is straightforward. The second half is **not satisfied by the chosen runtime's
defaults**: as established under LUA-03, `os.time` is not in `Lua.new/1`'s documented
default deny-set, so it is reachable unless denied explicitly — and it is the sole
subject of the requirement's acceptance criterion. *Restatement:* `os.time` must be
denied explicitly (subject to the `:sandboxed`-replaces-defaults trap noted under
LUA-03), and the denial asserted by a test that evaluates `os.time` from inside a script
and requires `nil`-or-error. The requirement's intent — that scripts read time only from
the platform's authoritative source, never from an ambient one — extends further than
its literal text: `os.date`, `os.clock`, and `os.difftime` are also reachable by default
and are also ambient time sources. Expansion should deny all four, and should say plainly
that doing so goes **beyond** LUA-14's literal wording rather than pretending the extra
three were always in scope.

**LUA-15 — Structured Failure.** "`platform.fail(reason, details)` MUST **terminate the
script** and propagate a structured failure to the engine." Satisfiable, but carrying the
same hazard identified for LUA-08 under (a), which must be designed for rather than
assumed away. If `platform.fail` is implemented as an ordinary raised Lua error, a
hostile or merely careless script can wrap its own failure in `pcall` and continue
executing — the script would not terminate, and the engine would receive no failure,
defeating the requirement's central verb. This is the identical in-band/out-of-band
question as `:max_instructions`, and the answer must be the same in shape: termination
cannot depend on the script declining to catch the error. *Restatement:* `platform.fail`
must terminate the invocation by a mechanism the script cannot intercept — recording the
failure host-side at call time so that a swallowed error is still reported, terminating
the enclosing process, or both — and a test must assert that a script which `pcall`s its
own `platform.fail` still yields a `SCRIPT_FAILED` outcome and does not run to
completion. Tracked in OQ-2 alongside the `:max_instructions` `pcall` question, since one
spike settles both.

**LUA-16 — Runtime Error Capture.** Requires uncaught errors be converted to structured
`SCRIPT_ERROR` events carrying "stack trace, **instruction count consumed**, and
capability state at failure." Stack trace and capability state are host-side concerns
Letflow controls. The **instruction count consumed** is not: this record found **no
documentation** that `tv-labs/lua` exposes a consumed-instruction count, either as a
return value or on the error raised when `:max_instructions` is exceeded — the option is
documented only as raising "instruction budget exceeded". Absence of documentation is
not proof the capability is absent, and no code was run here to check. *Restatement:*
expansion must first determine empirically whether a consumed-instruction count is
retrievable. If it is not, LUA-16 must be restated to drop that field (or to report the
configured budget rather than the consumed count), and the restatement must say so —
**not** silently emit an event with the field omitted or zero-filled while claiming the
requirement met.

**WASM-01 — Wasmtime Integration.** "MUST embed Wasmtime via its C API, linked
statically into the platform binary." `wasmex` embeds Wasmtime through a **Rust** NIF,
not the C API, and there is no "platform binary" — the BEAM loads a shared library at
runtime. *Intent restatement:* the platform embeds Wasmtime in-process with no external
Wasm runtime dependency at deploy time. The *acceptance criterion* ("No external Wasm
runtime dependency at deploy time") is satisfiable as literally worded; the *mechanism
clause* is not.

**WASM-03 / WASM-04 / WASM-05 — Source Compilation Job, Compile Caching, Build
Reproducibility.** All three specify a pipeline compiling **Zig source** to `.wasm`.
Letflow has no Zig toolchain and no reason to acquire one. *Restatement:* the pipeline
must be language-agnostic, accepting a `.wasm` artifact and keying its cache on artifact
hash plus toolchain identity. Whether Letflow hosts guest compilation **at all** is
OQ-3 below — R-Co never built this (`src/wasm/` is stubs; zero `.wasm` artifacts exist),
so there is no working pipeline to port.

**WASM-07 — No Filesystem Access.** "Module attempting to import `wasi:filesystem/types`
is rejected." Names a WASI Preview 2 component-model interface. Satisfiable in intent —
grant no WASI filesystem capability — but the concrete import name depends on whether
S5 targets core modules or components, which is unsettled (OQ-4). *Restatement:* deny by
default and assert the denial against whichever ABI is chosen.

**WASM-13 — Instance Pooling (SHOULD).** Retained as SHOULD, with an added constraint
absent from the original: if pooling is adopted, per-invocation memory reset is a
**correctness** requirement (isolation), not a performance detail. Per (e).

**WASM-10 — Memory Limits (correction: REVIEWER, WF-02 Step 2d, REQ-169,
2026-08-28).** Literal text: "Attempt to grow beyond cap MUST TRAP." This record's own
evidence section above called `StoreLimits.memory_size`/`table_elements` "direct
analogues" and this requirement was originally carried on the "satisfiable
substantially as worded" list below on that basis — **without live-verifying the trap
claim**, the same category of gap this record's own caution paragraph already warns
about for LUA-14. REQ-169's live verification
(`lib/letflow/design/req169-wasm-fuel-and-memory-cap.md` §1.5-§1.6, real installed
`wasmex` v0.15.1) found the literal wording does **not** hold: `memory.grow` beyond
`StoreLimits.memory_size` does not trap — it returns WebAssembly's own standard `-1`
growth-failure sentinel as an ordinary successful call return, and the guest's
execution continues normally. *Intent restatement:* the SECURITY property WASM-10
actually cares about — a guest's real linear memory cannot be made to exceed the
configured cap — is live-verified true and unaffected; only the FAILURE-VISIBILITY
mechanism ("traps") is wrong. A caller wanting to know whether the cap bound a growth
attempt must compare real memory size before/after (`ResourceLimits.memory_grew_within_cap?/3`),
not pattern-match a trap that will not occur. WASM-09 (`:consume_fuel`) has no such
gap — REQ-169 confirmed fuel metering behaves exactly as this record and WASM-09
describe (§1.1-§1.4 of that design), so only WASM-10 moves to this section.

Requirements judged satisfiable substantially as worded, subject to the above:
LUA-02, LUA-05, LUA-06, LUA-07, LUA-11, LUA-12, LUA-13;
WASM-02, WASM-06, WASM-08, WASM-09 (`:consume_fuel` is a direct analogue, live-verified
by REQ-169), WASM-12, WASM-14. Each still needs its own acceptance test;
"satisfiable" is not "satisfied." (WASM-11 removed 2026-08-28, REVIEWER, REQ-170 —
see the entry below.)

**WASM-11 — Wall-Clock Timeout (correction: REVIEWER, WF-02 Step 2d, REQ-170,
2026-08-28).** Literal text: "Exceeding the timeout MUST INTERRUPT EXECUTION." This
record's own containment argument, reasoning (a) point (ii) above, cited `wasmex`'s
documentation — "a timed-out call is interrupted and its Store stays usable" — as "the
interruption primitive WASM-11 needs," and WASM-11 was carried on the "satisfiable
substantially as worded" list on that basis, again without live-verifying the claim, the
same category of gap as WASM-10's. REQ-170's live verification
(`lib/letflow/design/req170-wasm-wallclock-timeout.md` §1.1-§1.4, real installed
`wasmex` v0.15.1) found the literal wording, and the cited primitive itself, do **not**
hold: a genuinely hanging guest is never interrupted at any bound tested up to 30
seconds; the calling process instead crashes with an ordinary `GenServer.call` timeout
`exit`; the `Store` becomes permanently unusable for subsequent calls, not merely "not
proven usable"; and no BEAM-side mechanism (link death, `Process.exit/2`,
`Task.shutdown/2`, `GenServer.stop/1`) can reach or terminate the already-dispatched
native execution once started, because `wasmex`'s per-`Store` executor task discards its
own `JoinHandle`. *Intent restatement:* the property WASM-11's own acceptance criterion
actually names — "Host-blocking call respects timeout" — is live-verified true: the
*caller* (the host) reliably stops waiting within a configured bound, via
`Letflow.Engine.PluginInterface.invoke/2,3`'s existing, unmodified supervised-task
boundary (REQ-057/165), independent of whether `wasmex`'s own interrupt fires. What is
not true is the body clause's literal claim that the guest's *execution* is interrupted.
A caller needing to know whether the underlying native compute was reclaimed cannot —
REQ-170's design doc §1.4/§1.5 additionally live-verified a **more severe** consequence
than WASM-10's: the leaked native execution permanently consumes one thread of
`wasmex`'s node-global, CPU-count-sized worker-thread pool per timed-out invocation,
with no reclamation mechanism, and a saturated pool was live-observed to stall an
unrelated, non-hanging guest call belonging to no tenant involved in the original hangs
(§1.5). This node-wide, cross-tenant exhaustion surface bears directly on OQ-5 below and
is filed there, not resolved here — see OQ-5's amendment.

**A caution on this list.** LUA-14 sat on it in this record's first revision, asserted
satisfiable while this record's own LUA-03 evidence listed a default deny-set that leaves
`os.time` reachable — the exact "this one's fine" that is more dangerous than an honestly
restated gap, because a requirement absent from the watchlist below is policed by nothing
downstream. REVIEWER caught it. **WASM-10 repeated the identical pattern** — carried on
this list from documentation alone ("direct analogue"), and only shown wrong once
REQ-169 actually ran the mechanism; REVIEWER caught it too and moved it to the section
above rather than leaving the requirement's own design doc as the only place the gap is
recorded. **WASM-11 repeated the identical pattern a third time, and more severely** —
carried on this list on the strength of this record's own reasoning (a) point (ii), which
REQ-170 live-verified is itself false, not merely imprecisely worded; REVIEWER moved it
to the section above in the same edit rather than leaving REQ-170's design doc as the
only place the gap is recorded. Every entry above is a judgement made from documentation
that was read, not from software that was run; expansion should treat the list as a
starting position to verify, not a clearance.

## Open questions

**OQ-1 — Memory limiting for Lua (LUA-09). Blocks LUA-09's expansion.** No memory-limit
option is documented for `tv-labs/lua`. Candidate approaches: run each script in a
process with a bounded `max_heap_size` (kills rather than fails gracefully — LUA-09 says
"fail gracefully and terminate," so a kill may satisfy the second clause but not the
first); approximate via `:max_instructions` (unsound — allocation is not proportional to
instruction count); or upstream a limit. S5 must resolve this before claiming LUA-09,
and must not treat instruction limiting as a proxy for memory limiting.

**OQ-2 — `tv-labs/lua` vs. `luerl`.** `tv-labs/lua` is selected on documented sandbox
defaults, documented resource limits, `{:userdata, term}` opaque passing, and the more
ergonomic `deflua` host-API surface — all directly relevant to LUA-03/05/06/08. `luerl`
has ~1.85× the downloads and a much longer history. Neither was run here. S5's first
requirement should validate the selection against a real spike and may reverse it on
evidence without reopening this record's build-vs-bind conclusion, since both are
pure-BEAM binds. That spike must cover four things this record could settle only from
documentation:

1. **`pcall` vs. `:max_instructions`** — can a script catch its own budget exhaustion
   and continue? (LUA-08 / LUA-10.)
2. **`pcall` vs. `platform.fail`** — the identical hazard for LUA-15's "MUST terminate
   the script"; see that entry above. One spike settles both, which is why they are
   tracked together here.
3. **Consumed-instruction count** — is one retrievable after execution or on error?
   LUA-16 requires it and no documentation of it was found.
4. **Whatever OQ-1 concludes** about memory limiting.

**OQ-3 — Does Letflow host guest compilation at all (WASM-03/04/05)?** Accepting
pre-compiled `.wasm` artifacts and never running a compiler would eliminate three
requirements' worth of scope plus a build-farm security surface. R-Co never built this,
so nothing is lost by declining. Needs S6's operational input (artifact storage,
retention, job execution).

**OQ-4 — Core modules or the component model?** `Wasmex.EngineConfig` exposes
`:wasm_component_model`. WASM-02's ABI (`init`, `execute`, `deinit`,
`get_capabilities`) is core-module shaped; WASM-07's `wasi:filesystem/types` is
component-model shaped. R-Co's own spec is internally inconsistent here, and its stub
code settles nothing. S5 must pick one explicitly.

**OQ-5 — Scheduler safety under real load.** `wasmex` documents call timeouts and Store
survival but this record found no documentation of dirty-NIF usage or scheduler-yielding
guarantees, and none was measured. If a fuel-bounded guest still blocks a scheduler long
enough to degrade the node, the Port fallback from (c) returns. Needs a load spike, and
likely S6 operational thresholds.

**OQ-5 amendment — REVIEWER, WF-02 Step 2d, REQ-170, 2026-08-28.** REQ-170's live
verification (`lib/letflow/design/req170-wasm-wallclock-timeout.md` §1.4/§1.5/§8)
measured the specific mechanism OQ-5 names — a BEAM scheduler thread itself blocked — and
did **not** observe it (near-zero `:erlang.statistics(:scheduler_wall_time)` utilization
during a live hang). It found a **different, arguably more severe** mechanism bearing on
OQ-5's underlying concern instead: `wasmex`'s own native worker-thread pool
(`TOKIO_RUNTIME`, node-global, sized to `available_parallelism()`) is a shared,
cross-tenant resource that a hung guest permanently consumes one thread of, with no
BEAM-side reclamation possible; 32 concurrent hangs (2x this host's
`System.schedulers_online()`) exhausted it and stalled a subsequently dispatched,
completely unrelated, non-hanging guest call. This does not settle OQ-5 — it still needs
a real load spike plus S6's operational thresholds, exactly as originally scoped — but it
is new, load-bearing evidence for whoever does settle it, and for the reasoning (a)
point (ii)/(iii) correction above: candidate mitigations named by REQ-170 §8 include an
operator-configurable cap on concurrently in-flight WASM invocations, independent of the
per-invocation wall-clock bound WASM-11 already provides. Whether this evidence changes
the containment argument's overall adequacy conclusion is not decided here — that
judgement needs the load spike this open question already calls for, not a single
design-session's probe.

**OQ-6 — Number marshalling across the 5.1→5.3 integer/float split. SETTLED by REQ-150,
`lib/letflow/design/req150-lua-number-marshalling.md`.** Per (b), the one dialect
difference with semantic weight. How Lua integers and floats round-trip through
`Letflow.Engine.VariableMerge` and JSONB variable storage is now settled once, centrally,
by that design's §2 normative rule (cited as "REQ-150 §2.n"), with the owning module and
function named in §3, before LUA-11 (REQ-159/REQ-160) is expanded — not rediscovered per
host function. §4 of that design records the interaction with WASM-12's parity
requirement, since the WASM ABI has its own numeric representation.

**OQ-7 — Rust toolchain pinning in CI.** `wasmex` requires a Rust toolchain to build,
which Letflow's CI does not have today. Per (f) and `0005-pin-formatting-toolchain.md`'s
precedent, that version should be pinned. Mechanism is S6 operational scope.

## Scope

**This record decides** the runtime strategy for both halves of S5: bind rather than
build on both; `tv-labs/lua` for Lua with no native code; `wasmex` for WASM behind a
mandatory process boundary; Lua before WASM; and the restatement obligations above.

**This record does not:**

- Add any `mix.exs` dependency, or change any `lib/` code. It is a `docs/` change only.
  No dependency was fetched, compiled, or executed in producing this record. (This is a
  statement about what was done, not about what is possible here — see the correction
  under "Evidence — Elixir ecosystem": this environment *does* have network access.)
- Change the `LuaScriptAudit.Executor` behaviour or `PluginInterface`'s contract. Per
  (d), both survive as written; that is a finding, not a deferral.
- Assign `REQ-xxx` numbers. S5 requirements are not expanded; this record refers only to
  R-Co's own LUA-xx/WASM-xx IDs, and expansion assigns Letflow numbers.
- Design the host API surface (`platform.*`). LUA-05/11/12/13/14/15 and WASM-12 are
  requirement-level work for expansion, against this record's Decision as premise.
- Settle anything in Open questions above, several of which need S6's operational
  decisions.
- Reopen whether S5 covers WASM. It does; that is settled by the user.

## Ownership of execution

**S5's requirement expansion** owns execution. REQ-ANALYST expands LUA-01..16 and
WASM-01..14 into Letflow requirements **against this record's Decision as a settled
premise**, applying every restatement in "Requirements NOT satisfiable as literally
worded" — each restated requirement must say plainly that it is a restatement and why,
so no future reader mistakes a satisfied intent for a satisfied literal text.
REQ-VALIDATOR should treat an unrestated **LUA-01, LUA-03, LUA-04, LUA-08/LUA-10 (as a
two-layer pair), LUA-09, LUA-14, LUA-15, LUA-16, WASM-01, WASM-03/04/05, WASM-07,
WASM-10, WASM-11, or WASM-13** as a validation failure. That is the full watchlist; it is
the same set as the "Requirements NOT satisfiable as literally worded" section above, and
the two must be kept in sync — if a later pass moves a requirement onto that list, it
belongs here in the same edit, because a requirement that is restated but unwatched is
policed by nothing. (WASM-10 added 2026-08-28, REVIEWER, REQ-169 — see that section's
entry for why. WASM-11 added 2026-08-28, REVIEWER, REQ-170 — see that section's entry;
this is the third instance of this pattern and the most severe.)

Sequencing per Decision (4): the Lua half lands first and defines the host API; the WASM
half follows and conforms to it per WASM-12. OQ-1 blocks LUA-09; OQ-3 and OQ-4 block the
WASM half's expansion and should be resolved first.

REVIEWER owns sign-off on the first requirement that adds `tv-labs/lua` to `mix.exs`
(Letflow's first scripting dependency) and on the first that adds `wasmex` (Letflow's
first native-code build dependency, per (f)). SECURITY-REVIEWER is a hard gate on both
halves: scripts and plugins execute tenant-supplied input, which is a tenant-data path
by definition.
