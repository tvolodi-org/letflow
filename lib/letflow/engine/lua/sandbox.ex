defmodule Letflow.Engine.Lua.Sandbox do
  @moduledoc """
  REQ-151 (LUA-03, LUA-04 restated) — the single sandbox-construction entry point for
  tenant-supplied Lua script execution. Implements
  `lib/letflow/design/req151-lua-sandbox.md` exactly.

  `Sandbox.new/0` and `Sandbox.new/1` are the ONLY permitted call sites of `Lua.new/1`
  anywhere under `lib/` (INV-SBX-1). Every `Lua.t()` value reachable anywhere in this
  codebase that will run tenant-supplied script text MUST have been produced here, and by
  nothing else. This is enforced structurally (single call site), not by a runtime check.

  ## REQ-152 (LUA-14 restated) — additions to this module

  This file also implements the deny-set half of REQ-152 (LUA-14 restated; the
  `platform.now()` half lives in `Letflow.Engine.Lua.Platform`). Of Lua 5.3's 11 `os`
  functions, `Lua.new/1`'s own documented default sandbox denies only 6 — `os.execute`,
  `os.exit`, `os.getenv`, `os.remove`, `os.rename`, `os.tmpname`. It does NOT deny
  `os.clock`, `os.date`, `os.difftime`, `os.setlocale`, or `os.time` — 5 of the 11 are
  left reachable by the library's own defaults. REQ-152 closes all 5: `os.time` is
  LUA-14's own literal, sole-named acceptance criterion; denying `os.date`, `os.clock`,
  and `os.difftime` goes BEYOND LUA-14's literal wording, as a deliberate extension of
  its intent (time is read only from `platform.now()`'s single authoritative source,
  never an ambient one). `os.setlocale` is not a time source, but was left reachable by
  this module's original (REQ-151) deny-set despite REQ-151's own description text
  claiming it fell to "REQ-151's general enumeration" — that claim did not match the
  actual implemented list, so REQ-152 closes this gap here rather than silently leaving
  it, or reopening REQ-151. The deny-set below grew from 28 to 33 entries as a result,
  appended to the same list passed to `Lua.new/1`'s `sandboxed:` option — never a second
  or partial list (see "The `:sandboxed`-replaces-defaults trap" below, which this
  extension is equally subject to).

  Construction never fails: there is no `{:ok, _} | {:error, _}` return shape for `new/0`
  or `new/1` (INV-SBX-4) — there is no external I/O, no config lookup, and no user input
  at construction time.

  ## LUA-03 restatement (design §7)

  This module restates R-Co's LUA-03 rather than satisfying its literal text, for three
  reasons:

  (a) `loadstring` is a Lua 5.1 name absent from Lua 5.3. The runtime this sandbox wraps
  (`tv-labs/lua`) implements Lua 5.3 only; there is no `loadstring` global to remove
  because Lua 5.3 never had one (renamed/merged into `load` upstream). Restated as a
  deny-set entry anyway, for literal-text completeness, though it denies nothing that
  could otherwise be reached.

  PROVENANCE (historical, not current decision authority):
  (b) `jit`, `ffi`, and `bit` do not exist in Lua 5.3 at all — they are LuaJIT-specific.
  R-Co's exclusion of them, including `ffi` (which R-Co's `stdlib.zig` calls "a
  COMPLETE sandbox escape"), is vacuous under this runtime, not satisfied. No deny-set
  entry is added for them because there is nothing at those paths to deny and no library
  file installs them.

  (c) R-Co's SBX-1 invariant ("prune strictly AFTER open") does not transfer as a
  mechanism. `Lua.new/1` sandboxes by construction — the deny-set is applied while
  building the VM state, not by opening a full stdlib and pruning it afterward — so there
  is no open-then-prune ordering for this module to get right or wrong. The property
  SBX-1 protects (no window during which a denied global is reachable) still holds:
  every caller only ever observes a `Lua.t()` already returned by `Sandbox.new/0` or
  `Sandbox.new/1`; no intermediate construction state is ever exposed by this module's
  public API.

  `debug` is additional, not a fourth restatement reason — it is a gap in what the
  library's own default denies, not a gap in what LUA-03's text could name (R-Co's
  LUA-03 does name `debug` as MUST-NOT-load; this module actually satisfies that part of
  LUA-03's literal text where the library's un-amended default does not — see the
  deny-set below).

  ## LUA-04 restatement (design §8)

  This module restates R-Co's LUA-04 ("the sandbox MUST refuse to load Lua bytecode;
  only source text MAY be loaded") rather than satisfying it literally. The adopted
  runtime (`tv-labs/lua`) parses Lua source text only — it has no bytecode format, no
  bytecode loader, and therefore no bytecode-rejection code path to test. LUA-04 holds
  structurally: only source text can ever be loaded because nothing else is
  representable, not because a rejection check runs and returns an error. What this
  module's test suite verifies instead is the absence of every loader capable of
  consuming either form: `load`, `loadfile`, `dofile`, and `string.dump` — the last of
  which is doubly structural, since without a bytecode format there is also nothing for
  `string.dump` to serialize a function *into*, and indeed no such function is installed
  at all in this runtime.

  ## `coroutine` decision (design §6)

  `coroutine` does not exist in this Lua runtime at all — confirmed by reading
  `deps/lua/lib/lua/vm/stdlib.ex`'s installed library list and finding zero references
  to `"coroutine"` anywhere under `deps/lua/lib/`.

  No deny-set entry is added for `[:coroutine]`. Reason: `Lua.sandbox/2` works by
  overwriting a path with a raising function — calling it on a path that does not
  currently exist would CREATE a new global named `coroutine` (a callable that raises),
  where none exists today. That is the opposite of the intended effect: it manufactures
  a global surface rather than removing one, and a future reader diffing `pairs(_G)`
  against this module's deny-set could be misled into thinking `coroutine` is a real,
  sandboxed table rather than nothing at all. What is tested instead is that
  `coroutine == nil` from inside a `Sandbox.new/0` VM, proving the absence directly.

  If a future `tv-labs/lua` upgrade adds a `coroutine` library, the "coroutine is nil"
  test will start FAILING (not silently pass) — that failure is the intended trigger for
  revisiting this decision, and should be read as "the runtime changed a starting
  assumption," not as flakiness.

  ## No custom deny-set list (design §5 AC3 disposition)

  `new/1`'s `opts` do not expose a way for a caller to add or remove individual denied
  paths — the 28-entry deny-set below is fixed by this module. REQ-152 (LUA-14) is the
  requirement that extends this deny-set (the `os` time-surface functions); it consumes
  this module rather than constructing its own `Lua.t()`.

  ## The `:sandboxed`-replaces-defaults trap (design §5)

  `Lua.new/1`'s `sandboxed:` option is NOT merged with the library's own
  `@default_sandbox` — whatever list is passed IS the complete sandboxed set for that VM
  instance. Passing a partial list (e.g. calling the library directly with only
  `sandboxed: [[:os, :time]]`) would deny `os.time` and nothing else, silently reopening
  every other default denial. This module
  avoids that trap by never passing a partial list: the deny-set below restates every one
  of the library's 27 default paths explicitly in source (not by reference to
  `@default_sandbox`, so a future edit to the library's own default cannot silently
  change this module's behavior underneath it), plus this module's own addition
  (`[:debug]`), for a fixed 28-entry list every time.
  """

  @type deny_entry :: {path :: [atom()], reason :: String.t()}
  @type deny_set :: [deny_entry()]

  # 27 entries restated explicitly from `Lua.new/1`'s own `@default_sandbox`
  # (`deps/lua/lib/lua.ex`), verified against the ACTUAL installed Lua 5.3 stdlib
  # (`deps/lua/lib/lua/vm/stdlib*.ex`), not against documentation or R-Co's LuaJIT/5.1
  # module set. Several are "installed?  no" — vacuous, denying a path nothing occupies
  # — and are restated anyway for literal-text completeness with the library default and
  # with R-Co's LUA-03 text; each row says which case it is and why.
  @sandbox_deny_set [
    {[:io, :stdin],
     "Not installed: no `io` global exists anywhere in this runtime (no file installs a " <>
       "global named \"io\"; no Lua.VM.Stdlib.Io module exists). Vacuous, restated because " <>
       "R-Co's LUA-03 names `io` as a MUST-NOT-load module."},
    {[:io, :stdout], "Not installed. Same as `io.stdin` above — no `io` global exists."},
    {[:io, :stderr], "Not installed. Same as `io.stdin` above — no `io` global exists."},
    {[:io, :read], "Not installed. Same as `io.stdin` above — no `io` global exists."},
    {[:io, :write], "Not installed. Same as `io.stdin` above — no `io` global exists."},
    {[:io, :open], "Not installed. Same as `io.stdin` above — no `io` global exists."},
    {[:io, :close], "Not installed. Same as `io.stdin` above — no `io` global exists."},
    {[:io, :lines], "Not installed. Same as `io.stdin` above — no `io` global exists."},
    {[:io, :popen], "Not installed. Same as `io.stdin` above — no `io` global exists."},
    {[:io, :tmpfile], "Not installed. Same as `io.stdin` above — no `io` global exists."},
    {[:io, :output], "Not installed. Same as `io.stdin` above — no `io` global exists."},
    {[:io, :input], "Not installed. Same as `io.stdin` above — no `io` global exists."},
    {[:io, :flush], "Not installed. Same as `io.stdin` above — no `io` global exists."},
    {[:io, :type], "Not installed. Same as `io.stdin` above — no `io` global exists."},
    {[:file],
     "Not installed: no file handle type or global exists. Vacuous, same reasoning as " <>
       "`io.*` above — file-handle methods (`file:read`, etc.) have nothing to attach to " <>
       "since no `io.open` exists to produce a handle."},
    {[:os, :execute],
     "Not installed: `Lua.VM.Stdlib.Os` implements only clock/date/difftime/exit/" <>
       "getenv/setlocale/time/time_ms/time_us/tmpname — no `execute`. Vacuous; the " <>
       "strongest possible form of R-Co's \"if reachable, MUST remove\" for this path."},
    {[:os, :exit],
     "Installed (os_exit/2). Real denial — process-termination side effect must not be " <>
       "reachable from tenant script."},
    {[:os, :getenv], "Installed (os_getenv/2). Real denial — host environment disclosure."},
    {[:os, :remove],
     "Not installed: no `os_remove` function exists. Vacuous; filesystem mutation has " <>
       "nothing to attach to."},
    {[:os, :rename], "Not installed: no `os_rename` function exists. Same as `os.remove`."},
    {[:os, :tmpname],
     "Installed (os_tmpname/2). Real denial — filesystem path disclosure/creation."},
    {[:package],
     "Installed: `install_package_table/1` unconditionally sets a real `package` global " <>
       "table. Real denial — module-loading surface, not part of the MUST-load set " <>
       "(math, string, table)."},
    {[:load],
     "Installed (`base_globals/0` registers \"load\"). Real denial — dynamic source-text " <>
       "compilation from a runtime string, R-Co's LUA-03 explicit removal target."},
    {[:loadfile],
     "Not installed: no \"loadfile\" global is ever registered anywhere in this runtime. " <>
       "Vacuous; filesystem-backed load has nothing to attach to."},
    {[:require],
     "Installed (`base_globals/0` registers \"require\"). Real denial — module-loading " <>
       "surface, pairs with `package`."},
    {[:dofile],
     "Installed (`base_globals/0` registers \"dofile\"). Real denial — filesystem-backed " <>
       "execution."},
    {[:loadstring],
     "Not installed, and structurally cannot be: `loadstring` is a Lua 5.1 name; Lua 5.3 " <>
       "(this runtime's dialect) never had it. Restates LUA-03's literal text even though " <>
       "the name does not exist in this dialect (see moduledoc LUA-03(a))."},
    # Addition beyond `Lua.new/1`'s own `@default_sandbox` — this requirement's central
    # finding. `debug` is a real, installed global (`Lua.VM.Stdlib.Debug`, run
    # unconditionally for every `Lua.new/1` call) exposing `debug.getmetatable/1` and
    # `debug.setmetatable/2` (which bypass `__metatable` protection, per the library's
    # own moduledoc) and `debug.getupvalue/2` / `debug.setupvalue/3` (which read and
    # mutate a Lua closure's captured upvalues directly). This is a real, non-vacuous
    # sandbox gap in the library's own default sandbox that R-Co's LUA-03 (which never
    # opened `debug` at all) would have closed and that `Lua.new/1`'s defaults do not.
    # PROVENANCE (historical, not current decision authority):
    {[:debug],
     "Installed, and NOT in Lua.new/1's own @default_sandbox. Metatable-protection " <>
       "bypass and arbitrary upvalue mutation are capabilities strictly beyond " <>
       "math/string/table's intended surface (LUA-03's MUST-load set) and are exactly " <>
       "the class of introspection primitive R-Co's stdlib.zig excluded by naming " <>
       "`debug` outright."},
    # REQ-152 (LUA-14 restated) additions — appended to this same list, never a second
    # or partial list (the `:sandboxed`-replaces-defaults trap, see moduledoc). Of Lua
    # 5.3's 11 `os` functions, REQ-151 above denied 6 (execute, exit, getenv, remove,
    # rename, tmpname); os.clock, os.date, os.difftime, os.setlocale, and os.time were
    # left reachable. This requirement closes all 5, growing this deny-set 28 -> 33.
    {[:os, :time],
     "Installed (`time`/`time_ms`/`time_us` in os.ex; `time` is the LUA-14-named one). " <>
       "Real denial — LUA-14's own literal, sole-named acceptance criterion: os.time " <>
       "MUST NOT be available. The platform's authoritative time is reachable only " <>
       "through platform.now() (Letflow.Engine.Lua.Platform)."},
    {[:os, :date],
     "Installed (os_date/2). Real denial — an ambient time source reachable by " <>
       "default. Not named by LUA-14's literal text; denied here as a DELIBERATE " <>
       "EXTENSION beyond that literal wording, to serve LUA-14's intent (time read " <>
       "only from the platform's single authoritative source, never an ambient one)."},
    {[:os, :clock],
     "Installed (os_clock/2). Real denial — same beyond-LUA-14-literal-wording " <>
       "extension as os.date: a CPU-time-derived but still ambient, ungoverned time " <>
       "signal a script could otherwise read instead of platform.now()."},
    {[:os, :difftime],
     "Installed (os_difftime/2). Real denial — same beyond-LUA-14-literal-wording " <>
       "extension; computes over two ambient time values, so denying it removes " <>
       "computation over any ambient timestamp a script might otherwise have obtained."},
    {[:os, :setlocale],
     "Installed (os_setlocale/2). Real denial. Not a time source, so not part of the " <>
       "LUA-14 restatement above — this closes a gap REQ-151's own description text " <>
       "claimed (incorrectly) was already covered by its general enumeration; reading " <>
       "REQ-151's implemented deny-set directly showed no `[:os, :setlocale]` entry. " <>
       "Locale-dependent formatting/parsing is a nondeterminism and host-environment- " <>
       "disclosure surface. Closed here (REQ-152) rather than reopening REQ-151."}
  ]

  @doc """
  The full 33-entry deny-set: `{path, reason}` pairs — the 27 restated `Lua.new/1`
  defaults, plus `:debug` (REQ-151), plus the 5 `os` time/locale entries (REQ-152).
  """
  @spec deny_set() :: deny_set()
  def deny_set, do: @sandbox_deny_set

  @doc """
  Builds a sandboxed `Lua.t()` with no construction-time options. Equivalent to
  `new([])`. See moduledoc for the deny-set, the `coroutine` decision, and the LUA-03/
  LUA-04 restatements this construction implements.
  """
  @spec new() :: Lua.t()
  def new, do: new([])

  @doc """
  Builds a sandboxed `Lua.t()`. `opts` currently defines no meaningful keys for this
  requirement — the parameter exists so later requirements (REQ-154..156) can extend
  behavior (e.g. `:max_instructions`) without ever constructing a `Lua.t()` via
  `Lua.new/1` directly. This is the ONLY permitted call site of `Lua.new/1` under `lib/`
  (INV-SBX-1). Construction never fails (INV-SBX-4).

  REQ-152: after `Lua.new/1` constructs the sandboxed VM, `Letflow.Engine.Lua.Platform.
  install/1` is called unconditionally to make `platform.now()` reachable. This is
  additive only — it never touches the deny-set above — and is the ONLY place
  `platform.now` is wired in, so every `Lua.t()` this module produces has it (INV-PLAT-1).
  """
  @spec new(opts :: keyword()) :: Lua.t()
  def new(opts) do
    sandboxed_paths = Enum.map(@sandbox_deny_set, fn {path, _reason} -> path end)
    lua_opts = [sandboxed: sandboxed_paths]

    lua_opts =
      case Keyword.fetch(opts, :max_instructions) do
        {:ok, budget} -> Keyword.put(lua_opts, :max_instructions, budget)
        :error -> lua_opts
      end

    lua_opts
    |> lua_new()
    |> Letflow.Engine.Lua.Platform.install()
  end

  # ── Tenant scripts: exact allow-list (GH 2534, decision 0053 D11, F-C) ──────
  #
  # Design: lib/letflow/design/gh2534-7a-script-runtime.md section 2. Unlike `new/1`
  # (a deny list: `Lua.sandbox/2` only REPLACES a path with a raising function, so the
  # path stays in `_G`), `new_script/1` builds the global environment by REMOVAL: every
  # global and library member not on these lists is deleted, so `_G` of a script VM
  # equals the list exactly (equality-tested). `Platform.install/1` is NOT called.

  @script_globals ~w(string table math pairs ipairs next select type tostring tonumber
                     pcall error assert setmetatable getmetatable rawget rawset rawequal
                     rawlen unpack)
  @script_host_globals ~w(ctx fail print)
  @script_members %{
    "string" => ~w(lower upper len sub rep reverse byte char format find match gsub),
    "table" => ~w(insert remove concat sort unpack),
    "math" => ~w(abs acos asin atan ceil cos deg exp floor fmod log max min modf pi rad sin
                 sqrt tan tointeger type ult huge maxinteger mininteger random randomseed)
  }

  # 0053 D7: platform constants for tenant scripts in stage 1 (not caller-settable).
  @script_max_string_bytes 1_048_576
  @script_max_call_depth 200

  @doc "GH 2534: the exact global names of a script VM (host globals included)."
  @spec script_globals() :: [String.t()]
  def script_globals, do: Enum.sort(@script_globals ++ @script_host_globals)

  @doc "GH 2534: the exact members of the `string`, `table` and `math` libraries."
  @spec script_members() :: %{String.t() => [String.t()]}
  def script_members,
    do: Map.new(@script_members, fn {lib, members} -> {lib, Enum.sort(members)} end)

  @doc "GH 2534: the per-string ceiling of a script VM (0053 D7, 1 MiB)."
  @spec script_max_string_bytes() :: pos_integer()
  def script_max_string_bytes, do: @script_max_string_bytes

  @doc """
  GH 2534 (0053 D11): a FRESH tenant-script VM. Required `opts`: `:max_instructions`
  (positive integer) and `:host` (a function `(Lua.t() -> Lua.t())` that installs the host
  globals `ctx`, `fail`, `print` and the host library members, see
  `Letflow.Engine.Lua.ScriptHost.install/2`). Built for every run, never cached (F-C).
  """
  @spec new_script(keyword()) :: Lua.t()
  def new_script(opts) do
    install_host = Keyword.fetch!(opts, :host)

    lua_new(
      sandboxed: [],
      max_string_bytes: @script_max_string_bytes,
      max_instructions: Keyword.fetch!(opts, :max_instructions),
      max_call_depth: @script_max_call_depth
    )
    |> remove_globals_not_in(@script_globals)
    |> trim_libraries()
    |> install_host.()
  end

  # INV-SBX-1: the ONLY `Lua.new/1` call site under lib/ (both builders go through it).
  defp lua_new(lua_opts), do: Lua.new(lua_opts)

  defp remove_globals_not_in(lua, keep) do
    lua.state
    |> Lua.VM.State.globals()
    |> Map.keys()
    |> Enum.reject(&(is_binary(&1) and &1 in keep))
    |> Enum.reduce(lua, fn key, acc -> Lua.set!(acc, [key], nil) end)
  end

  defp trim_libraries(lua) do
    Enum.reduce(@script_members, lua, fn {library, members}, acc ->
      globals = Lua.VM.State.globals(acc.state)
      table = Lua.VM.State.get_table(acc.state, Map.fetch!(globals, library))

      table
      |> Lua.VM.Table.to_map()
      |> Map.keys()
      |> Enum.reject(&(is_binary(&1) and &1 in members))
      |> Enum.reduce(acc, fn key, inner -> Lua.set!(inner, [library, key], nil) end)
    end)
  end
end
