defmodule Letflow.Engine.CompleteTaskFormHookCrashTest do
  @moduledoc """
  REQ-632 / GH #3524 (decision 0067 D5 + D9, slice F-4 part A), crash rows. Sandbox `:auto` mode
  (real commits, real second connections), hence `async: false`.

    * F4-08a/b/c (criterion 2): the sandbox worker, or its watchdog, is killed while the completion
      transaction holds its locks; nothing is committed and the locks are free afterwards. The
      worker killed with `:kill` gives `:memory_limit_exceeded`, not `:script_error`:
      `ScriptRunner.await/4` cannot tell an external `:kill` from a heap kill (both end with the
      reason `:killed`), and remapping it would misreport real memory kills. A worker that exits
      with another reason (F4-08b) and a killed watchdog (F4-08c) give `:script_error`.
    * F4-09 (criterion 3): the caller process is killed while inside the hook; no committed row and
      the locks are released.
    * F4-13b (criterion 9, locks half): a raising runner gives `{:form_hook_failed, :script_error}`
      without raising, and the locks are free.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Engine
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.Scripts.HmacSecret
  alias Letflow.Support.ScriptTaskFixture, as: F
  alias Letflow.Test.SandboxAutoMode

  @supervisor Letflow.Engine.Lua.TaskSupervisor
  @spin "while true do local s = string.rep('x', 1000000) end"

  defmodule CrashRunner do
    @moduledoc false
    # `fun.(source, input, opts)` lives in the application env.
    def run(source, input, opts),
      do: Application.fetch_env!(:letflow, :f4_crash_fun).(source, input, opts)
  end

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)

    base = Fx.committed_tenant_case!("f4-cr")
    tenant_id = base.tenant.tenant_id
    :ok = HmacSecret.ensure(%{id: tenant_id})

    on_exit(fn ->
      Repo.delete_all(from(s in Letflow.Secrets.Secret, where: s.tenant_id == ^tenant_id))
      Fx.drop_committed_tenant!(tenant_id)
    end)

    set_env(:form_validation_hook_enabled, true)
    set_env(:form_validation_script_runner, CrashRunner)
    Fx.define_type!(base.schema, "stock_move", %{})
    %{base: base}
  end

  defp set_env(key, value) do
    previous = Application.fetch_env(:letflow, key)
    Application.put_env(:letflow, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:letflow, key, old)
        :error -> Application.delete_env(:letflow, key)
      end
    end)
  end

  defp manifest(limits) do
    %{
      "input_schema" => %{
        "type" => "object",
        "properties" => %{"amount" => %{"type" => "integer"}}
      },
      "output_schema" => %{
        "type" => "object",
        "properties" => %{
          "ok" => %{"type" => "boolean"},
          "code" => %{"type" => "string"},
          "fields" => %{"type" => "array"}
        },
        "additionalProperties" => false
      },
      "fail_codes" => [],
      "refusal_codes" => ["too_small"],
      "fields" => ["amount"],
      "limits" => Map.merge(%{"timeout_ms" => 50}, limits)
    }
  end

  defp accept,
    do:
      {:ok,
       %{
         output: %{"ok" => true},
         stats: %{duration_us: 7, instructions_used: 3, heap_words_at_end: 9}
       }}

  # START -> ht (hook + one entity-write line, so the later steps lock the type rows) -> END.
  defp start_case!(base, source, limits \\ %{}) do
    rule =
      F.published!(
        base.schema,
        "fv_f4_#{System.unique_integer([:positive])}",
        source,
        manifest(limits),
        hook_kind: "form_validation"
      )

    graph =
      Fx.graph([Fx.line("stock_move", %{"label" => %{"const" => "x"}})])
      |> update_in(["nodes"], fn nodes ->
        Enum.map(nodes, fn
          %{"id" => "ht"} = node ->
            update_in(node, ["attributes"], fn attrs ->
              Map.merge(attrs, %{
                "validation_script_key" => rule.key,
                "validation_script_version" => rule.version
              })
            end)

          node ->
            node
        end)
      end)

    definition = Fx.activate!(base.schema, base.user, graph)
    {instance_id, task} = Fx.start!(base.schema, definition)
    %{instance_id: instance_id, task: task}
  end

  defp complete(base, task) do
    Engine.complete_task(
      task.id,
      %{
        output_variables: %{"amount" => 5},
        actor_id: base.user.id,
        idempotency_key: Fx.unique("f4-complete")
      },
      prefix: base.schema
    )
  end

  defp snapshot(base, c) do
    %{
      status: Repo.get!(Letflow.Engine.Task, c.task.id, prefix: base.schema).status,
      projection: F.projection(base.schema, c.instance_id),
      events: F.event_types(base.schema, c.instance_id)
    }
  end

  defp nowait(schema, sql_tail, params) do
    Task.async(fn ->
      case Repo.query(~s(SELECT 1 FROM "#{schema}".#{sql_tail} FOR UPDATE NOWAIT), params) do
        {:ok, %{num_rows: n}} -> {:granted, n}
        {:error, %{postgres: %{code: code}}} -> {:refused, code}
      end
    end)
    |> Task.await(10_000)
  end

  defp locks_free?(base, c) do
    nowait(base.schema, ~s("tasks" WHERE id = $1), [Ecto.UUID.dump!(c.task.id)]) ==
      {:granted, 1} and
      nowait(base.schema, ~s("instance_projections" WHERE instance_id = $1), [
        Ecto.UUID.dump!(c.instance_id)
      ]) == {:granted, 1}
  end

  # Delegates to the real sandbox runner after arming a killer for the worker (or the watchdog).
  # The worker is the new supervisor child whose `$callers` head is the other new child.
  defp killing_runner(test_pid, variant) do
    fn source, input, opts ->
      before = MapSet.new(Task.Supervisor.children(@supervisor))

      spawn(fn -> kill_when_ready(test_pid, variant, before, 2_000) end)
      Letflow.Engine.Lua.ScriptRunner.run(source, input, opts)
    end
  end

  defp kill_when_ready(test_pid, _variant, _before, budget) when budget <= 0,
    do: send(test_pid, :killer_gave_up)

  defp kill_when_ready(test_pid, variant, before, budget) do
    fresh = Task.Supervisor.children(@supervisor) |> Enum.reject(&MapSet.member?(before, &1))

    with [_, _] <- fresh,
         [worker] <- Enum.filter(fresh, &(hd_callers(&1) in fresh)),
         [watchdog] <- fresh -- [worker] do
      case variant do
        {:worker, reason} -> Process.exit(worker, reason)
        :watchdog -> Process.exit(watchdog, :kill)
      end

      send(test_pid, {:killed, variant})
    else
      _not_yet ->
        Process.sleep(1)
        kill_when_ready(test_pid, variant, before, budget - 1)
    end
  end

  defp hd_callers(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> dict |> Keyword.get(:"$callers", []) |> List.first()
      nil -> nil
    end
  end

  describe "criterion 2: sandbox process killed while the locks are held" do
    for {id, variant, code} <- [
          {"F4-08a worker killed with :kill (deviation A1)", {:worker, :kill},
           :memory_limit_exceeded},
          {"F4-08b worker exits with a non-kill reason", {:worker, :boom}, :script_error},
          {"F4-08c watchdog killed", :watchdog, :script_error}
        ] do
      test "#{id} gives #{code}, nothing committed, locks free", %{base: base} do
        c = start_case!(base, @spin, %{"instructions" => 10_000_000})
        before = snapshot(base, c)
        set_env(:f4_crash_fun, killing_runner(self(), unquote(Macro.escape(variant))))

        assert {:error, {:form_hook_failed, unquote(code)}} = complete(base, c.task)

        # the kill really happened (a lost race would show :timeout instead)
        assert_received {:killed, unquote(Macro.escape(variant))}
        refute_received :killer_gave_up
        refute Repo.in_transaction?()
        assert snapshot(base, c) == before
        assert snapshot(base, c).status == :pending
        assert locks_free?(base, c)
        assert F.eventually(fn -> F.slots_in_use(base.schema) == 0 end, 100)
      end
    end
  end

  describe "criterion 3: caller crash inside the hook" do
    test "F4-09 no committed row, locks released, a later completion succeeds", %{base: base} do
      c = start_case!(base, "return { ok = true }")
      before = snapshot(base, c)
      test_pid = self()

      # Real sandbox run first (so the admission path is the real one), then block with no timeout:
      # the caller can only die inside the hook, and :hook_returned is never sent.
      set_env(:f4_crash_fun, fn source, input, opts ->
        _ = Letflow.Engine.Lua.ScriptRunner.run(source, input, opts)
        send(test_pid, {:in_hook, self()})

        receive do
          :never_sent -> send(test_pid, :hook_returned)
        end
      end)

      caller = spawn(fn -> send(test_pid, {:result, complete(base, c.task)}) end)
      monitor = Process.monitor(caller)

      assert_receive {:in_hook, ^caller}, 5_000
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}, 5_000

      refute Process.alive?(caller)
      refute_received :hook_returned
      refute_received {:result, _}

      # Postgres cleans up the aborted session asynchronously.
      assert F.eventually(fn -> locks_free?(base, c) end, 100)
      assert snapshot(base, c) == before
      assert snapshot(base, c).status == :pending
      # sanity check only: the run had returned before the block, so no slot was held at the kill
      assert F.eventually(fn -> F.slots_in_use(base.schema) == 0 end, 100)

      set_env(:f4_crash_fun, fn _source, _input, _opts -> accept() end)
      assert {:ok, _} = complete(base, c.task)
    end
  end

  describe "criterion 9: unexpected exception in the hook" do
    test "F4-13b a raising runner gives script_error, does not raise, and the locks are free",
         %{base: base} do
      c = start_case!(base, "return { ok = true }")
      before = snapshot(base, c)
      set_env(:f4_crash_fun, fn _source, _input, _opts -> raise "BOOM-SECRET" end)

      assert {:error, {:form_hook_failed, :script_error}} = complete(base, c.task)

      refute Repo.in_transaction?()
      assert snapshot(base, c) == before
      assert snapshot(base, c).status == :pending
      assert locks_free?(base, c)
    end
  end
end
