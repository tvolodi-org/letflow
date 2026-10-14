defmodule Letflow.Engine.Lua.ScriptRunner do
  @moduledoc """
  GH 2534 (decision 0053 D7, D8, F-A, F-C, F-D, F-E Admission part): runs ONE tenant script
  and returns a stable outcome. Design: `lib/letflow/design/gh2534-7a-script-runtime.md`
  section 4. No tenant-facing caller in 7a; 7b (dry-run, publish tests) and 7c (SERVICE_TASK
  handler) call `run/3`.

  ## Processes (all under `Letflow.Engine.Lua.TaskSupervisor`, started from closures)

    * the caller starts a WATCHDOG with `Task.Supervisor.async_nolink/2` and monitors it;
    * the watchdog takes a `Letflow.Engine.Lua.ScriptAdmission` slot (that server monitors the
      watchdog, so its death releases the slot), monitors the caller, starts the WORKER with
      `Task.Supervisor.async/2` (linked), and enforces the deadline from outside the worker
      (a script's `pcall` cannot catch it); it kills the worker on caller death, deadline or
      supervisor shutdown;
    * the worker sets the heap limit on itself first (`max_heap_size`, `kill: true`,
      `error_logger: false`, `include_shared_binaries: true`), builds a fresh script VM
      (`Sandbox.new_script/1`), runs the chunk and decodes its first return value.

  Neither process ever crashes: each body is one `try`/`rescue`/`catch` that returns a tagged
  tuple, so no Task error report (which could carry tenant values) is ever logged. `run/3`
  never raises.

  ## Outcomes (0053 D7, the eight stable codes)

  `{:ok, %{output, stats}}` or `{:error, code, detail}`, `code` one of `:script_error`,
  `:budget_exceeded`, `:memory_limit_exceeded`, `:output_invalid`, `:timeout`,
  `:script_failed`, `:script_rejected` (never produced here; 7b/7c), `:script_busy`.
  `detail` is `%{}`, or `%{fail: %{code, details}}` for `:script_failed`, plus `:author`
  (sanitised message, line, print buffer) only when `author_detail: true` (dry-run).
  """

  alias Letflow.Admission
  alias Letflow.Engine.Lua.Sandbox
  alias Letflow.Engine.Lua.ScriptHost
  alias Letflow.Engine.Lua.ScriptValue

  @task_supervisor Letflow.Engine.Lua.TaskSupervisor
  @admission Letflow.Engine.Lua.ScriptAdmission

  # 0053 D7 defaults and platform maxima (Q11: measured; see the design note section 8).
  @default_instructions 1_000_000
  @max_instructions 10_000_000
  @default_timeout_ms 1_000
  @max_timeout_ms 5_000
  @default_heap_words 4_194_304
  @max_heap_words 8_388_608
  @caller_margin_ms 2_000
  @author_message_bytes 200

  @type code ::
          :script_error
          | :budget_exceeded
          | :memory_limit_exceeded
          | :output_invalid
          | :timeout
          | :script_failed
          | :script_rejected
          | :script_busy

  @type stats :: %{
          duration_us: non_neg_integer(),
          instructions_used: non_neg_integer(),
          instructions_budget: pos_integer(),
          heap_words_at_end: non_neg_integer(),
          heap_words_limit: pos_integer(),
          input_dropped: non_neg_integer()
        }

  @doc "The platform defaults and maxima (for 7b/7c and the tests)."
  @spec limits() :: map()
  def limits do
    %{
      default_instructions: @default_instructions,
      max_instructions: @max_instructions,
      default_timeout_ms: @default_timeout_ms,
      max_timeout_ms: @max_timeout_ms,
      default_heap_words: @default_heap_words,
      max_heap_words: @max_heap_words,
      max_string_bytes: Sandbox.script_max_string_bytes(),
      max_output_bytes: ScriptValue.max_output_bytes()
    }
  end

  @doc """
  Runs `source` with `input`. Required opts: `:tenant` (schema prefix) and `:ctx`
  (`%{instance_id, node_id, token_id}` strings and `now` as a `DateTime`). Optional, clamped
  to the platform maxima: `:instructions`, `:timeout_ms`, `:heap_words`; `:fail_codes`
  (allowed `fail` codes, nil = any well-formed code); `:author_detail` (dry-run only);
  `:admission` (server name, default `Letflow.Engine.Lua.ScriptAdmission`).
  """
  @spec run(String.t(), map(), keyword()) ::
          {:ok, %{output: map() | list(), stats: stats()}} | {:error, code(), map()}
  def run(source, input, opts) do
    config = config!(source, input, opts)
    caller = self()
    watchdog = Task.Supervisor.async_nolink(@task_supervisor, fn -> watchdog(caller, config) end)

    case Task.yield(watchdog, config.timeout_ms + @caller_margin_ms) ||
           Task.shutdown(watchdog, :brutal_kill) do
      {:ok, {:ok, _result} = ok} ->
        ok

      {:ok, {:error, code, detail}} when is_atom(code) and is_map(detail) ->
        {:error, code, detail}

      {:ok, _unexpected} ->
        {:error, :script_error, %{}}

      nil ->
        {:error, :timeout, %{}}

      {:exit, _reason} ->
        {:error, :script_error, %{}}
    end
  rescue
    _ -> {:error, :script_error, %{}}
  catch
    _kind, _reason -> {:error, :script_error, %{}}
  end

  defp config!(source, input, opts) when is_binary(source) and is_map(input) do
    %{instance_id: i, node_id: n, token_id: t, now: %DateTime{} = now} =
      Keyword.fetch!(opts, :ctx)

    true = is_binary(i) and is_binary(n) and is_binary(t)
    tenant = Keyword.fetch!(opts, :tenant)
    true = is_binary(tenant)

    %{
      source: source,
      input: input,
      tenant: tenant,
      ctx: %{instance_id: i, node_id: n, token_id: t, now: now},
      instructions:
        clamp(Keyword.get(opts, :instructions), @default_instructions, @max_instructions),
      timeout_ms: clamp(Keyword.get(opts, :timeout_ms), @default_timeout_ms, @max_timeout_ms),
      heap_words: clamp(Keyword.get(opts, :heap_words), @default_heap_words, @max_heap_words),
      fail_codes: Keyword.get(opts, :fail_codes),
      author_detail: Keyword.get(opts, :author_detail, false) == true,
      admission: Keyword.get(opts, :admission, @admission)
    }
  end

  defp clamp(nil, default, _max), do: default
  defp clamp(value, _default, max) when is_integer(value) and value > 0, do: min(value, max)

  # ── watchdog ───────────────────────────────────────────────────────────────

  defp watchdog(caller, config) do
    parent = Enum.find(Process.get(:"$ancestors", []), &is_pid/1)
    Process.flag(:trap_exit, true)

    result =
      try do
        guard(caller, parent, config)
      rescue
        _ -> {:error, :script_error, %{}}
      catch
        _kind, _reason -> {:error, :script_error, %{}}
      end

    # exit/1 is called OUTSIDE the try, so `catch :exit` above cannot swallow it.
    case result do
      {:exit_now, reason} -> exit(reason)
      tuple -> tuple
    end
  end

  defp guard(caller, parent, config) do
    case Admission.try_acquire({:tenant, config.tenant}, config.admission) do
      {:error, :capacity} ->
        {:error, :script_busy, %{}}

      {:ok, slot} ->
        try do
          caller_monitor = Process.monitor(caller)
          deadline = System.monotonic_time(:millisecond) + config.timeout_ms
          worker = Task.Supervisor.async(@task_supervisor, fn -> worker(config) end)
          await(worker, caller_monitor, parent, deadline)
        after
          # The ScriptAdmission :DOWN release is the backstop if this never runs.
          Admission.release(slot, config.admission)
        end
    end
  end

  defp await(%Task{ref: ref, pid: worker_pid} = worker, caller_monitor, parent, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, _pid, :killed} ->
        {:error, :memory_limit_exceeded, %{}}

      {:DOWN, ^ref, :process, _pid, _reason} ->
        {:error, :script_error, %{}}

      {:DOWN, ^caller_monitor, :process, _pid, _reason} ->
        Task.shutdown(worker, :brutal_kill)
        {:exit_now, :normal}

      {:EXIT, ^parent, reason} when is_pid(parent) ->
        Task.shutdown(worker, :brutal_kill)
        {:exit_now, reason}

      {:EXIT, ^worker_pid, _reason} ->
        # The :DOWN of the same worker carries the outcome.
        await(worker, caller_monitor, parent, deadline)
    after
      remaining ->
        Task.shutdown(worker, :brutal_kill)
        {:error, :timeout, %{}}
    end
  end

  # ── worker ─────────────────────────────────────────────────────────────────

  defp worker(config) do
    # FIRST statement: the heap limit (0053 D7 / F-A). error_logger: false keeps the kill
    # report (which would carry process state) out of the logs.
    Process.flag(:max_heap_size, %{
      size: config.heap_words,
      kill: true,
      error_logger: false,
      include_shared_binaries: true
    })

    started = System.monotonic_time(:microsecond)
    run_ref = make_ref()

    host_run = %{
      run_ref: run_ref,
      ctx: config.ctx,
      input: config.input,
      fail_codes: config.fail_codes
    }

    try do
      lua =
        Sandbox.new_script(
          max_instructions: config.instructions,
          host: &ScriptHost.install(&1, host_run)
        )

      {results, state} = execute(config.source, lua)

      case ScriptValue.decode(List.first(results), state) do
        {:ok, output} ->
          {:ok,
           %{output: output, stats: stats(config, started, state.instruction_count, run_ref)}}

        :error ->
          {:error, :output_invalid, author(config, run_ref, nil)}
      end
    rescue
      exception ->
        classify(exception, config, run_ref)
    catch
      :throw, {:script_fail, ^run_ref, payload} ->
        {:error, :script_failed, Map.put(author(config, run_ref, nil), :fail, payload)}

      :throw, :script_syntax_error ->
        {:error, :script_error, author(config, run_ref, %{value: "syntax error"})}

      _kind, _reason ->
        {:error, :script_error, author(config, run_ref, nil)}
    end
  end

  defp execute(source, lua) do
    with {:ok, ast} <- Lua.Parser.parse_structured(source),
         {:ok, proto} <- Lua.Compiler.compile(ast, source: "script") do
      {:ok, results, state} = Lua.VM.execute(proto, lua.state)
      {results, state}
    else
      _parse_or_compile_error -> throw(:script_syntax_error)
    end
  end

  # Budget exhaustion is recognised by the VM's own instruction tally, never by the message
  # text alone (a script can raise the same text with error(...)).
  defp classify(
         %Lua.VM.RuntimeError{value: "instruction budget exceeded", state: %{} = state},
         config,
         run_ref
       )
       when state.instruction_count >= config.instructions do
    {:error, :budget_exceeded, author(config, run_ref, nil)}
  end

  defp classify(exception, config, run_ref) do
    {:error, :script_error, author(config, run_ref, exception)}
  end

  defp stats(config, started, instructions_used, run_ref) do
    {:total_heap_size, heap} = Process.info(self(), :total_heap_size)

    %{
      duration_us: System.monotonic_time(:microsecond) - started,
      instructions_used: instructions_used || 0,
      instructions_budget: config.instructions,
      heap_words_at_end: heap,
      heap_words_limit: config.heap_words,
      input_dropped: ScriptHost.run_state(run_ref).input_dropped
    }
  end

  # Dry-run only (0053 D10, F-D): an ALLOW-LIST shape. The first line of a string error
  # value, truncated; else fixed text. Never inspect/1, Exception.format/* or a stack trace.
  defp author(%{author_detail: false}, _run_ref, _exception), do: %{}

  defp author(%{author_detail: true}, run_ref, exception) do
    run_state = ScriptHost.run_state(run_ref)

    %{
      author: %{
        message: author_message(exception),
        line: author_line(exception),
        prints: run_state.prints,
        prints_dropped: run_state.prints_dropped
      }
    }
  end

  defp author_message(nil), do: nil

  defp author_message(%{value: value}) when is_binary(value) do
    value |> String.split("\n", parts: 2) |> hd() |> truncate(@author_message_bytes)
  end

  defp author_message(_exception), do: "script error (non-string error value)"

  defp author_line(%{line: line}) when is_integer(line), do: line
  defp author_line(_exception), do: nil

  defp truncate(text, max) when byte_size(text) <= max, do: text

  defp truncate(text, max) do
    text
    |> binary_part(0, max)
    |> String.chunk(:valid)
    |> Enum.filter(&String.valid?/1)
    |> Enum.join()
  end
end
