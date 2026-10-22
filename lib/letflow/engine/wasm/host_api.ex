defmodule Letflow.Engine.Wasm.HostApi do
  @moduledoc """
  REQ-171 (WASM-12 read half) — the WASM ABI's equivalent of
  `Letflow.Engine.Lua.Platform`'s `do_read_variable/do_log/now` trio, for the four
  functions this requirement owns: `read_variable`, `log`, `now`, `uuid`. REQ-172 adds
  `do_write_variable`/`do_call_service`/`do_fail` to this same module (mirroring
  `platform.ex` hosting both REQ-159's and REQ-160's implementations in one file).

  See `lib/letflow/design/req171-wasm-host-api-read.md` (gate-approved) for the full
  design this module implements, in particular §1's live-verified `wasmex` v0.15.1
  callback ABI findings this module's shape depends on.

  ## Per decision 0014 (4): the Lua host API is the definition WASM conforms to

  Every semantic rule this module restates is read from
  `lib/letflow/engine/lua/platform.ex`, never re-derived. This module does not modify
  that file or any file under `lib/letflow/engine/lua/`.

  ## Capability source — REQ-167

  Gating for every function this module defines comes exclusively from
  `Letflow.Engine.Wasm.CapabilityGate`'s manifest-derived import-table whitelist
  (`build_import_table/1,2`) — no second capability model is introduced here.
  `read_variable` requires `"var:read"`, `log` requires `"audit:log"`, `now`/`uuid` are
  `:none`-gated (always installed, never denied) — see `capability_gate.ex`'s
  `@known_imports`. No function in this module performs a capability check itself; by
  the time any `do_*` function below runs, `CapabilityGate`'s import-table membership
  has already been the only gate applied (design §4.7).

  ## Tenant boundary (AC8, decision 0014 (e))

  Identical statement to REQ-159's own: host functions receive already-resolved
  values; the tenant prefix is supplied by the calling engine code, never derived
  inside a script. **No function this module defines calls `Letflow.Repo`, ever** —
  none of `read_variable`/`log`/`now`/`uuid` touches persistence. `execution_context`
  is supplied by whatever future dispatch-integration requirement calls
  `Letflow.Engine.Wasm.CapabilityGate.build_import_table/2` — never derived from a
  guest-supplied argument, never read from guest memory.

  ## Number marshalling (AC6) — REQ-150 §2.2, no second rule

  `read_variable`'s value is routed through
  `Letflow.Engine.LuaNumberMarshalling.to_lua/1` (REQ-150 §2.2, the read-direction
  identity rule for `integer()`/`float()`/`nil`) before being JSON-encoded onto the
  wire — exactly the same call `platform.ex`'s own `do_read_variable/3` makes before
  its `Lua.encode!/2` step. `Jason.encode!/1` is what makes the integer/float subtype
  visible on the wire; `to_lua/1`'s job is only to guarantee no coercion happened
  before that encoding step. One function, one call site pattern, reused verbatim —
  no WASM-specific numeric companion module exists or is needed.

  ## `uuid` has no Lua counterpart (AC5)

  PROVENANCE (historical, not current decision authority):
  `uuid` does not appear in `platform.ex`'s 8-row `@capability_matrix` — R-Co's
  `src/wasm/host_api/uuid.zig` had no Lua-side sibling either, an asymmetry that
  predates Letflow's migration. This requirement implements `uuid` as a **documented
  WASM-side addition, with no Lua-side counterpart introduced**: it shares `now`'s own
  capability rationale (a pure
  computation with no state reach, no tenant-data touch, no side effect), requires no
  Lua-side file edit, and reuses the existing `:none` gating mechanism. Whether Lua
  scripts should also gain a `platform.uuid()` is flagged as a candidate finding for
  ORCH, not resolved by this requirement.

  ## Callback ABI (Findings 1/4, design §1)

  Every `do_*` function's first argument is the raw `wasmex_callback_context()` map
  `wasmex` hands every callback — never narrowed or renamed — so
  `Letflow.Engine.Wasm.MemoryGuard.read/4`/`.write/4` are called with
  `context.caller`/`context.memory` directly, fetched fresh on every invocation (never
  a store/memory handle captured at import-table-construction time — `wasmex`'s own
  moduledoc warns a captured `store` can deadlock the call). `execution_context` is
  always the last argument, closed over by
  `Letflow.Engine.Wasm.CapabilityGate.build_import_table/2`'s fold — never part of the
  guest-visible call signature.

  ## Shared string-return buffer protocol (§5.2)

  Every function here that returns a string-shaped value to the guest
  (`read_variable`, `now`, `uuid`) shares one protocol: the **guest**, not the host,
  owns buffer allocation (`out_ptr`, `out_cap`), which avoids ever needing to call the
  guest's own `alloc` export mid-callback (a re-entrant-guest-call hazard `wasmex`'s
  `GenServer.call`-shaped dispatch makes dangerous). One `i32` result, three disjoint
  ranges:

    * `n >= 0` — `n` is the exact byte length of the UTF-8-encoded result. If
      `out_cap >= n`, the host has already written those `n` bytes to `out_ptr`. If
      `out_cap < n`, the host has written nothing — the guest must call again with a
      buffer of at least `n` bytes.
    * `-1` — **`read_variable`-only.** The variable is not present in
      `execution_context.variables` (the same convention Lua's own `nil` represents
      for an unset variable).
      Never returned by `now`/`uuid` (both always have a value).
    * `-2` — invalid argument: an input or output pointer/length pair failed
      `MemoryGuard`'s bounds check, or (`read_variable` only) the name bytes read back
      are not valid UTF-8. No bytes are written.

  ## Semantic differences from Lua (AC6, design §9)

  WASM-12 limits this module's differences from `platform.ex` to ABI only (string
  encoding, return-envelope shape) — so an unlisted non-ABI difference means the
  requirement is unmet. Five are known, each with its justification:

    * **9.1 — `write_variable`'s wall-clock-timeout discard arm is abandonment, not
      destruction.** The observable guarantee (no caller ever commits the write) is
      identical to Lua's; the underlying mechanism is not — a timed-out WASM
      invocation's process is leaked, never killed, because no BEAM-side mechanism can
      terminate it (inherited from `CallTimeout`'s already-accepted REQ-170/decision
      0014 WASM-11 finding; this requirement only states the consequence for staged
      writes honestly rather than implying a uniform "process death" story).
    * **9.2 — `write_variable`'s "malformed name" arm has no WASM equivalent.** Lua's
      `do_write_variable/2` has a real non-binary-`name`-argument arm because Lua is
      dynamically typed; WASM's ABI only ever delivers a `(ptr, len)` byte pair for
      `name`, which is inherently string-shaped, so the only ways it can be malformed
      are already covered by the `-2` (bad pointer / invalid UTF-8) code. A consequence
      of the two languages' own type systems, not a design choice.
    * **9.3 — the capability token is `"var:write"`, not Lua's `"variable:write"`.**
      Pre-existing token-space divergence inherited from REQ-167/171 (`"var:read"` vs.
      `"variable:read"` already diverged before this requirement) — not introduced or
      newly decided here.
    * **9.4 — `call_service`'s missing-capability granularity is coarser on WASM than
      on Lua.** Lua's `"service:call:<id>"` is parameterized per service, checked at
      call time; WASM's `"service:call"` is a single, unparameterized capability
      checked once at import-table-construction time — once granted, a WASM guest may
      call `call_service` for any `service_id`, where an equivalently-configured Lua
      script would still be denied per-service. This is **accepted, not fixed**:
      closing the granularity gap inside `do_call_service`'s body would require either
      raising (forbidden by INV-HOSTAPI-2) or a second structured-error shape
      indistinguishable from an ordinary service failure (defeating AC4's requirement
      that the two be assertable distinctly).
    * **9.5 — `fail`'s discard/observation mechanism is structurally different on WASM
      than on Lua, not merely differently wrapped.** On Lua, `exit/1` crashes the
      process actually running the script, observed directly. On WASM, `exit/1` inside
      `do_fail/5` is caught internally by `wasmex`'s own callback dispatch — the
      instance process never crashes at all — so `fail` is distinguishable from a guest
      trap or an accidental callback bug only via the `@fail_signal_pdict_key`
      process-dictionary signal stashed before `exit/1`, a mechanism with no Lua-side
      analogue. The underlying mechanisms are genuinely different in kind, not just in
      return-value depth.

  No other non-ABI semantic difference is known. Any ELIXIR-DEV's implementation
  discovers that is not listed here is a defect against the design.

  ## Invariants

    * INV-HOSTAPI-1: no function this module defines calls `Letflow.Repo`, ever.
    * INV-HOSTAPI-2: no function this module defines raises, ever (a callback that
      raises produces the same opaque, indistinguishable-from-a-trap
      `{:error, binary()}` from `Wasmex.call_function/4` as a type-mismatched return —
      design §1 Finding 3 — so correctness must come from every callback body always
      returning a well-typed value). **One explicit, permanent exception (REQ-172
      design §7): `do_fail/5`.** Its entire purpose is a deliberate `exit/1` call —
      live-verified (REQ-172 design §2.1/§2.2) to NOT crash the Wasmex instance
      process, instead aborting the guest's in-flight call via Wasmtime's own
      host-function-failure propagation, made distinguishable from a trap/accidental
      bug via a process-dictionary signal (`@fail_signal_pdict_key`) stashed
      immediately before the `exit/1` call.
    * INV-HOSTAPI-3: every guest memory access goes through
      `Letflow.Engine.Wasm.MemoryGuard.read/4` or `.write/4` — never `Wasmex.Memory.*`
      directly.
    * INV-HOSTAPI-4: `execution_context` is never constructed from guest-supplied
      bytes — always the value closed over at
      `Letflow.Engine.Wasm.CapabilityGate.build_import_table/2` call time.
  """

  alias Letflow.Engine.Lua.Platform
  alias Letflow.Engine.LuaNumberMarshalling
  alias Letflow.Engine.VariableLabels
  alias Letflow.Engine.VariableMerge
  alias Letflow.Engine.Wasm.MemoryGuard

  require Logger

  @typedoc """
  The context map `wasmex` hands every callback (design §1 Finding 1/4) — never
  constructed by this module, only pattern-matched.
  """
  @type wasmex_callback_context :: %{
          memory: Wasmex.Memory.t(),
          caller: Wasmex.StoreOrCaller.t(),
          pid: pid(),
          instance: Wasmex.Instance.t()
        }

  @typedoc """
  WASM's own execution context (design §5.1) — same field semantics as
  `Letflow.Engine.Lua.Platform.execution_context()` minus `actor_id` (not needed until
  a future `emit_event`-equivalent, if one is ever added), but a **separate type**, not
  an alias or reuse of the Lua-side type — decision 0014 frames Lua and WASM as two
  independent handler families, and this is a bare map shape with no behavior
  attached.
  """
  @type execution_context :: %{
          instance_id: String.t() | nil,
          prefix: String.t() | nil,
          trace_id: String.t() | nil,
          script_identity: String.t() | nil,
          variables: map(),
          # GH #2616 part 2 (decision 0062 R8): the labels of `variables` and the caller's hidden set.
          # A missing hidden set (`nil`) hides every labelled variable (fail closed).
          variable_labels: map(),
          hidden_labels: MapSet.t(String.t()) | nil
        }

  @doc """
  Returns the empty `execution_context()` sentinel: every field `nil` except
  `variables` (`%{}`). `read_variable` returns `-1` (not present) for every lookup
  against it, `log` still emits an entry with every correlation field `nil`, and
  `now`/`uuid` are unaffected (neither reads `execution_context` at all).
  """
  @spec empty_execution_context() :: execution_context()
  def empty_execution_context do
    %{
      instance_id: nil,
      prefix: nil,
      trace_id: nil,
      script_identity: nil,
      variables: %{},
      variable_labels: %{},
      hidden_labels: nil
    }
  end

  # Known log levels (design §5.4 step 4, mirrors platform.ex's map_log_level/1) --
  # declared here, ahead of every function referencing it below.
  @known_log_levels ~w(debug info warn error)

  # ── REQ-172 §3.2/§7 -- write-staging pdict key, private to this module, never
  # read or written anywhere else under lib/. Mirrors platform.ex's own
  # @staged_writes_pdict_key naming exactly but is a SEPARATE key/module -- the two
  # runtimes' process-dictionary entries can never collide because host-function
  # callbacks execute in physically different processes per runtime.
  @staged_writes_pdict_key {Letflow.Engine.Wasm.HostApi, :staged_writes}
  @type staged_writes :: %{optional(String.t()) => term()}

  # ── REQ-172 §2.2/§5.2 -- the out-of-band distinguishability signal do_fail/5
  # stashes immediately before exit/1, read by PluginHandler.call_export/3 (and
  # Letflow.Test.HostApiParity's own run_wasm/0 closure for the fail scenario) via
  # Process.info(pid, :dictionary) strictly BEFORE that pid is stopped. A SEPARATE
  # key from staged writes, written only by do_fail/5.
  @fail_signal_pdict_key {Letflow.Engine.Wasm.HostApi, :fail_signal}
  @type fail_signal :: %{reason: String.t(), details: term()}

  # ── read_variable (design §5.3) ───────────────────────────────────────────────────
  #
  # Restates platform.ex's do_read_variable/3 (lines 596-607) under the same ABI
  # contract: a plain
  # lookup on the closed-over, already-resolved execution_context.variables -- no
  # Letflow.Repo call, ever.
  @spec do_read_variable(
          context :: wasmex_callback_context(),
          name_ptr :: integer(),
          name_len :: integer(),
          out_ptr :: integer(),
          out_cap :: integer(),
          execution_context :: execution_context()
        ) :: integer()
  def do_read_variable(context, name_ptr, name_len, out_ptr, out_cap, execution_context) do
    with {:ok, name_bytes} <- MemoryGuard.read(context.caller, context.memory, name_ptr, name_len),
         {:ok, name} <- validate_utf8(name_bytes) do
      # GH #2587 PR B3 (INV-2): engine-written `_sys.*` bookkeeping is never readable by a guest.
      case execution_context.variables |> VariableMerge.drop_reserved() |> Map.fetch(name) do
        {:ok, value} ->
          # GH #2616 part 2 (decision 0062 R8): a hidden labelled variable reads as not present.
          if hidden?(execution_context, name) do
            -1
          else
            json_bytes =
              value
              |> LuaNumberMarshalling.to_lua()
              |> Jason.encode!()

            write_buffer_result(context, json_bytes, out_ptr, out_cap)
          end

        :error ->
          -1
      end
    else
      {:error, _reason} -> -2
    end
  end

  # A context from before part 2 has no label fields; a missing hidden set fails closed.
  defp hidden?(execution_context, name) do
    VariableLabels.hidden?(
      Map.get(execution_context, :variable_labels, %{}),
      name,
      Map.get(execution_context, :hidden_labels)
    )
  end

  # ── log (design §5.4) ─────────────────────────────────────────────────────────────
  #
  # Restates platform.ex's do_log/3 (lines 681-727) under the same ABI contract. Identity fields are
  # sourced EXCLUSIVELY from execution_context, never from guest-supplied bytes. Never
  # raises, on any input (results: [] -- log has no return-value channel to report a
  # failure through, so degrading gracefully is the only option that keeps "never
  # raises" true).
  @spec do_log(
          context :: wasmex_callback_context(),
          level_ptr :: integer(),
          level_len :: integer(),
          message_ptr :: integer(),
          message_len :: integer(),
          context_ptr :: integer(),
          context_len :: integer(),
          execution_context :: execution_context()
        ) :: nil
  def do_log(
        context,
        level_ptr,
        level_len,
        message_ptr,
        message_len,
        context_ptr,
        context_len,
        execution_context
      ) do
    {level_text, level_invalid_utf8?} =
      read_log_field(context, level_ptr, level_len, "<invalid level pointer>")

    {message_text, message_invalid_utf8?} =
      read_log_field(context, message_ptr, message_len, "<invalid message pointer>")

    {decoded_context, context_decode_error?} =
      read_log_context(context, context_ptr, context_len)

    level = map_log_level(level_text)

    metadata =
      [
        script_identity: execution_context.script_identity,
        instance_id: execution_context.instance_id,
        trace_id: execution_context.trace_id,
        context: decoded_context
      ]
      |> maybe_put(:original_level, level_text, level_text not in @known_log_levels)
      |> maybe_put(:raw_encoding, :invalid_utf8, level_invalid_utf8? or message_invalid_utf8?)
      |> maybe_put(:context_decode_error, true, context_decode_error?)

    Logger.log(level, message_text, metadata)

    nil
  end

  # ── now (design §5.5) ─────────────────────────────────────────────────────────────
  #
  # Calls Letflow.Engine.Lua.Platform.now/0 directly -- not a reimplementation, not a
  # second TimeSource resolution. This guarantees byte-for-byte identical output
  # between the Lua and WASM call paths under the same injected clock double, the
  # strongest possible guarantee that the two call paths agree. Does not modify platform.ex (a new caller, not
  # a change to the function) and does not violate decision 0014's "neither runtime is
  # given database access" boundary.
  @spec do_now(
          context :: wasmex_callback_context(),
          out_ptr :: integer(),
          out_cap :: integer()
        ) :: integer()
  def do_now(context, out_ptr, out_cap) do
    iso8601 = Platform.now()
    write_buffer_result(context, iso8601, out_ptr, out_cap)
  end

  # ── uuid (design §5.6/§3) ─────────────────────────────────────────────────────────
  #
  # No Lua counterpart -- see moduledoc. Ecto.UUID.generate/0's canonical form is
  # always exactly 36 bytes UTF-8, fixed length.
  @spec do_uuid(
          context :: wasmex_callback_context(),
          out_ptr :: integer(),
          out_cap :: integer()
        ) :: integer()
  def do_uuid(context, out_ptr, out_cap) do
    uuid = Ecto.UUID.generate()
    write_buffer_result(context, uuid, out_ptr, out_cap)
  end

  # ── write_variable (REQ-172 design §3) ────────────────────────────────────────────
  #
  # Restates platform.ex's do_write_variable/2 (lines 736-755) under the same ABI
  # contract: stages
  # into a process-dictionary buffer private to the Wasmex instance process running
  # this callback (design §2) -- never into any shared/VM state. Both buffers are read
  # via MemoryGuard.read/4 (INV-HOSTAPI-3); any bounds failure on either, invalid UTF-8
  # on `name`, or malformed JSON on `value` -> -2, no write staged. On success, the
  # decoded value crosses LuaNumberMarshalling.from_lua/1 (REQ-150 §2.1, identical
  # call-site pattern to platform.ex's own stage_write(name,
  # LuaNumberMarshalling.from_lua(value))), then is staged via stage_write/2 -> 0.
  @spec do_write_variable(
          context :: wasmex_callback_context(),
          name_ptr :: integer(),
          name_len :: integer(),
          value_ptr :: integer(),
          value_len :: integer(),
          execution_context :: execution_context()
        ) :: integer()
  def do_write_variable(context, name_ptr, name_len, value_ptr, value_len, _execution_context) do
    with {:ok, name_bytes} <- MemoryGuard.read(context.caller, context.memory, name_ptr, name_len),
         {:ok, name} <- validate_utf8(name_bytes),
         {:ok, value_bytes} <-
           MemoryGuard.read(context.caller, context.memory, value_ptr, value_len),
         {:ok, value} <- Jason.decode(value_bytes) do
      stage_write(name, LuaNumberMarshalling.from_lua(value))
      0
    else
      _error -> -2
    end
  end

  @doc """
  Reads and CLEARS the calling process's write-staging buffer (`%{}` if none was ever
  staged) -- the WASM analogue of `Platform.take_staged_writes/0`, same read-and-clear
  contract, same "never called from anywhere in this module itself" discipline (design
  §7 OQ-1: a future dispatch-integration requirement is the first real caller, and MUST
  call this from inside the SAME Wasmex instance process that ran the guest call --
  i.e. from a callback invoked via `handle_info/2` -- strictly after
  `Wasmex.call_function/4` has returned a success outcome to the ORIGINAL caller.
  Calling it from any other process observes an empty map, by construction (process
  dictionaries are per-process, never shared).
  """
  @spec take_staged_writes() :: staged_writes()
  def take_staged_writes do
    writes = Process.get(@staged_writes_pdict_key, %{})
    Process.delete(@staged_writes_pdict_key)
    writes
  end

  # design §3.2 -- reads the current buffer from the process dictionary (defaulting to
  # %{} on the first write of a given execution), and writes the updated map back to
  # the same process-dictionary key. Last write wins (Map.put/3 semantics), identical
  # to platform.ex's own stage_write/2.
  @spec stage_write(name :: String.t(), value :: term()) :: :ok
  defp stage_write(name, value) do
    current = Process.get(@staged_writes_pdict_key, %{})
    Process.put(@staged_writes_pdict_key, Map.put(current, name, value))
    :ok
  end

  # ── call_service (REQ-172 design §4) ──────────────────────────────────────────────
  #
  # `service_id` and `payload` are read via MemoryGuard.read/4 and UTF-8/JSON-decoded.
  # `payload` decode failure or a missing payload (payload_len = 0) both default to
  # nil, mirroring platform.ex's own List.first(rest) default -- NOT a -2, since a
  # malformed/absent second argument is not an ABI-level failure on this path.
  # `service_id` must be valid UTF-8 and non-empty; a decode/UTF-8/emptiness failure on
  # `service_id` itself -> -2 (an ABI-level malformed call, distinct from both a
  # service failure and a missing-capability denial, design §4.3). The response is
  # written as one JSON envelope via the existing write_buffer_result/4 shared
  # protocol: {"ok": true, "value": ...} on success, {"ok": false, "error": {"reason":
  # ...}} on a service failure -- n >= 0 either way, since both are a well-formed host
  # -call return, never a trap. A missing "service:call" capability is NOT handled
  # here at all -- it fails at instantiation (capability_gate.ex), before this
  # function's body is ever entered (design §4.3).
  @spec do_call_service(
          context :: wasmex_callback_context(),
          service_id_ptr :: integer(),
          service_id_len :: integer(),
          payload_ptr :: integer(),
          payload_len :: integer(),
          out_ptr :: integer(),
          out_cap :: integer(),
          execution_context :: execution_context()
        ) :: integer()
  def do_call_service(
        context,
        service_id_ptr,
        service_id_len,
        payload_ptr,
        payload_len,
        out_ptr,
        out_cap,
        _execution_context
      ) do
    with {:ok, service_id_bytes} <-
           MemoryGuard.read(context.caller, context.memory, service_id_ptr, service_id_len),
         {:ok, service_id} <- validate_utf8(service_id_bytes),
         {:ok, service_id} <- validate_non_empty(service_id) do
      payload =
        context
        |> read_optional_json(payload_ptr, payload_len)
        |> normalize_from_lua_shallow()

      caller_module =
        Application.get_env(:letflow, :lua_platform_service_caller, Platform.NoServiceCaller)

      envelope =
        case caller_module.call(service_id, payload) do
          {:ok, response} when is_map(response) ->
            %{"ok" => true, "value" => convert_map_to_lua_shallow(response)}

          {:error, reason} ->
            %{"ok" => false, "error" => %{"reason" => stringify_reason(reason)}}
        end

      write_buffer_result(context, Jason.encode!(envelope), out_ptr, out_cap)
    else
      _error -> -2
    end
  end

  @spec validate_non_empty(String.t()) :: {:ok, String.t()} | {:error, :empty}
  defp validate_non_empty(""), do: {:error, :empty}
  defp validate_non_empty(service_id), do: {:ok, service_id}

  # payload_len = 0 is the ABI's way of omitting the (optional) second argument --
  # mirrors platform.ex's own List.first(rest) default of nil. A MemoryGuard failure
  # or undecodable JSON also default to nil -- payload malformation is never a -2 on
  # this call path (design §4.1).
  @spec read_optional_json(wasmex_callback_context(), integer(), integer()) :: term()
  defp read_optional_json(_context, _ptr, 0), do: nil

  defp read_optional_json(context, ptr, len) do
    with {:ok, bytes} <- MemoryGuard.read(context.caller, context.memory, ptr, len),
         {:ok, decoded} <- Jason.decode(bytes) do
      decoded
    else
      _error -> nil
    end
  end

  # REQ-150 §2.1 (write direction), one level deep -- mirrors platform.ex's own
  # normalize_from_lua/1, minus the object-shaped-proplist detection (a decoded JSON
  # object is already a plain Elixir map, an ABI/encoding simplification, not a
  # semantic one, design §4.4).
  @spec normalize_from_lua_shallow(term()) :: term()
  defp normalize_from_lua_shallow(value) when is_map(value) do
    Map.new(value, fn {key, v} -> {key, LuaNumberMarshalling.from_lua(v)} end)
  end

  defp normalize_from_lua_shallow(value), do: LuaNumberMarshalling.from_lua(value)

  # REQ-150 §2.2 (read direction), symmetric with normalize_from_lua_shallow/1 above --
  # mirrors platform.ex's own convert_map_to_lua/1. Only ever called with a map (the
  # is_map(response) guard at the one call site, §4.4), so unlike
  # normalize_from_lua_shallow/1 this has no non-map fallback clause to keep.
  @spec convert_map_to_lua_shallow(map()) :: map()
  defp convert_map_to_lua_shallow(value) when is_map(value) do
    Map.new(value, fn {key, v} -> {key, LuaNumberMarshalling.to_lua(v)} end)
  end

  # Renders a call_service failure reason as a JSON-encodable string -- mirrors
  # platform.ex's own stringify_reason/1 exactly.
  @spec stringify_reason(term()) :: String.t()
  defp stringify_reason(reason) when is_binary(reason), do: reason
  defp stringify_reason(reason) when is_atom(reason), do: to_string(reason)

  defp stringify_reason(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    reason |> elem(0) |> stringify_reason()
  end

  defp stringify_reason(reason), do: inspect(reason)

  # ── fail (REQ-172 design §5) ───────────────────────────────────────────────────────
  #
  # Never returns. The callback body stashes %{reason:, details:} into this process's
  # own dictionary via stash_fail_signal/2 (design §2.2/§5.2) IMMEDIATELY BEFORE
  # calling exit/1 -- this ordering is load-bearing (design §5.2/§7): the stash must
  # happen first so the signal is present the instant exit/1 triggers wasmex's own
  # handle_info/2 catch clause. reason_len = 0 defaults to the same fallback string
  # platform.ex uses; details_len = 0 defaults to nil. Decoded details cross
  # LuaNumberMarshalling.from_lua/1 one level deep, mirroring platform.ex's own
  # decode_fail_details/2. do_fail/5 ALWAYS terminates, regardless of whether its own
  # inputs are well-formed (design §5.1).
  @spec do_fail(
          context :: wasmex_callback_context(),
          reason_ptr :: integer(),
          reason_len :: integer(),
          details_ptr :: integer(),
          details_len :: integer()
        ) :: no_return()
  def do_fail(context, reason_ptr, reason_len, details_ptr, details_len) do
    reason_string = read_fail_reason(context, reason_ptr, reason_len)
    details = read_fail_details(context, details_ptr, details_len)

    stash_fail_signal(reason_string, details)
    exit({:script_failed, %{reason: reason_string, details: details}})
  end

  @default_fail_reason "script called platform.fail with no reason"

  # reason_len = 0 -> the fixed fallback (design §5.1). Otherwise reuses
  # read_log_field/4's established fallback pattern (design §5.1: "mirroring
  # read_log_field/4's established fallback pattern from REQ-171") -- a bad pointer
  # substitutes the same fallback string, invalid UTF-8 renders via inspect/1.
  @spec read_fail_reason(wasmex_callback_context(), integer(), integer()) :: String.t()
  defp read_fail_reason(_context, _ptr, 0), do: @default_fail_reason

  defp read_fail_reason(context, ptr, len) do
    {text, _invalid_utf8?} = read_log_field(context, ptr, len, @default_fail_reason)
    text
  end

  # details_len = 0 -> nil (design §5.1). A MemoryGuard failure or undecodable JSON
  # also substitutes nil, never changing do_fail/5's own uninterceptable-termination
  # behavior in any way.
  @spec read_fail_details(wasmex_callback_context(), integer(), integer()) :: term()
  defp read_fail_details(_context, _ptr, 0), do: nil

  defp read_fail_details(context, ptr, len) do
    with {:ok, bytes} <- MemoryGuard.read(context.caller, context.memory, ptr, len),
         {:ok, decoded} <- Jason.decode(bytes) do
      normalize_from_lua_shallow(decoded)
    else
      _error -> nil
    end
  end

  # design §2.2/§5.2 -- the fail-uninterceptability mechanism itself: a positive,
  # deliberate signal left in this process's OWN dictionary, under a key nothing else
  # in this module ever writes, immediately before exit/1. Read by
  # PluginHandler.call_export/3 (and Letflow.Test.HostApiParity) via
  # Process.info(pid, :dictionary), strictly BEFORE that pid is stopped.
  @spec stash_fail_signal(String.t(), term()) :: :ok
  defp stash_fail_signal(reason, details) do
    Process.put(@fail_signal_pdict_key, %{reason: reason, details: details})
    :ok
  end

  # ── §5.2's shared buffer protocol ─────────────────────────────────────────────────
  #
  # When out_cap >= byte_size(bytes), writes the full value and returns its length.
  # When out_cap is too small (including the out_cap = 0 length-probe case), writes
  # nothing but still validates out_ptr via a zero-length MemoryGuard.write/4 call
  # (design §5.2: "the host still validates out_ptr/0 via MemoryGuard before
  # returning n... a probe call with a genuinely invalid out_ptr still surfaces -2")
  # -- this keeps every guest memory touch, including the validate-only path, routed
  # through MemoryGuard (INV-HOSTAPI-3), never a direct Wasmex.Memory call.
  @spec write_buffer_result(wasmex_callback_context(), binary(), integer(), integer()) ::
          integer()
  defp write_buffer_result(context, bytes, out_ptr, out_cap) do
    n = byte_size(bytes)

    write_result =
      if out_cap >= n do
        MemoryGuard.write(context.caller, context.memory, out_ptr, bytes)
      else
        MemoryGuard.write(context.caller, context.memory, out_ptr, <<>>)
      end

    case write_result do
      :ok -> n
      {:error, _reason} -> -2
    end
  end

  @spec validate_utf8(binary()) :: {:ok, String.t()} | {:error, :invalid_utf8}
  defp validate_utf8(bytes) do
    if String.valid?(bytes) do
      {:ok, bytes}
    else
      {:error, :invalid_utf8}
    end
  end

  # Reads one log field (level/message). A MemoryGuard failure substitutes the given
  # fixed placeholder string and proceeds (design §5.4 step 1) rather than aborting --
  # log has no return-value channel to report a failure through. Invalid UTF-8 bytes
  # are rendered via inspect/1, mirroring platform.ex's own log_text/1 fallback.
  @spec read_log_field(wasmex_callback_context(), integer(), integer(), String.t()) ::
          {String.t(), boolean()}
  defp read_log_field(context, ptr, len, placeholder) do
    case MemoryGuard.read(context.caller, context.memory, ptr, len) do
      {:ok, bytes} ->
        if String.valid?(bytes) do
          {bytes, false}
        else
          {inspect(bytes), true}
        end

      {:error, _reason} ->
        {placeholder, false}
    end
  end

  # design §5.4 step 2 -- a zero context_len signals "no context" (WASM's arity is
  # fixed, unlike Lua's variable-arity call, so this is how a guest omits the
  # argument). Otherwise reads and JSON-decodes the bytes; either a MemoryGuard
  # failure or malformed JSON logs context as nil with context_decode_error: true,
  # never raising -- Jason.decode/1 (not decode!/1) is used here specifically to keep
  # this call site non-raising (INV-HOSTAPI-2).
  @spec read_log_context(wasmex_callback_context(), integer(), integer()) ::
          {term() | nil, boolean()}
  defp read_log_context(_context, _ptr, 0), do: {nil, false}

  defp read_log_context(context, ptr, len) do
    with {:ok, bytes} <- MemoryGuard.read(context.caller, context.memory, ptr, len),
         {:ok, decoded} <- Jason.decode(bytes) do
      {decoded, false}
    else
      _error -> {nil, true}
    end
  end

  defp map_log_level("debug"), do: :debug
  defp map_log_level("info"), do: :info
  defp map_log_level("warn"), do: :warning
  defp map_log_level("error"), do: :error
  defp map_log_level(_unrecognized), do: :info

  defp maybe_put(keyword, _key, _value, false), do: keyword
  defp maybe_put(keyword, key, value, true), do: keyword ++ [{key, value}]
end
