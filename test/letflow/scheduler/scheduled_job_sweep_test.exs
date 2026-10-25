defmodule Letflow.Scheduler.ScheduledJobSweepTest do
  @moduledoc """
  REQ-561 / GH #3194 -- `Letflow.Scheduler.ScheduledJobSweep`: due run (D1), missed runs (M1, M2),
  duplicate claim (C1, C2), failure behaviour (F1..F5), tenancy of the sweep (T1) and the source
  scan of the sweep and context modules (S7).

  `async: false`: `TenantFixture.provisioned_tenant!/1` switches the sandbox to global auto mode,
  which also makes the two-connection claim tests real races rather than one shared transaction.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit.Entry
  alias Letflow.Engine
  alias Letflow.EventStore.Event
  alias Letflow.Identity.User
  alias Letflow.Repo
  alias Letflow.ScheduledJobs
  alias Letflow.ScheduledJobs.Job
  alias Letflow.Scheduler.ScheduledJobSweep
  alias Letflow.Support.RoleScopeGrantsFixture, as: Rsg
  alias Letflow.TenantFixture
  alias Letflow.TestSupport.ScheduledJobFixture, as: Fx

  @now ~U[2026-06-01 12:30:00.000000Z]
  @due ~U[2026-06-01 12:00:00.000000Z]
  @next ~U[2026-06-01 13:00:00.000000Z]

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "sj-sweep")
    schema = tenant.schema_name
    actor = Fx.actor!(schema)
    %{schema: schema, actor: actor.id, name: Fx.definition!(schema)}
  end

  defp reload(schema, job), do: Repo.get!(Job, job.id, prefix: schema)

  defp audits(schema, action),
    do: Repo.all(from(e in Entry, where: e.action == ^action), prefix: schema)

  defp started_events(schema),
    do: Repo.all(from(e in Event, where: e.event_type == "INSTANCE_STARTED"), prefix: schema)

  test "D1 runs the one due job and leaves the other", %{schema: schema, actor: actor, name: name} do
    due = Fx.job!(schema, actor, name, %{variables: %{"batch" => "marker-4412"}}, @due)
    other = Fx.job!(schema, actor, name, %{}, @next)

    assert :ok = ScheduledJobSweep.run(schema, @now)

    assert Fx.instance_count(schema) == 1
    assert [event] = started_events(schema)
    assert inspect(event.payload) =~ "marker-4412"
    assert event.actor_id == actor

    ran = reload(schema, due)
    assert ran.last_outcome == "ok"
    assert ran.last_run_at == @due
    assert ran.next_run_at == @next
    assert ran.consecutive_failures == 0
    assert reload(schema, other) == other
    assert [run_entry] = audits(schema, "scheduled_job.run")
    assert run_entry.after_state["slot"] == DateTime.to_iso8601(@due)
    assert run_entry.after_state["outcome"] == "ok"
  end

  test "M1 a job 3.5 intervals behind runs once, skips 3, and is quiet on a second sweep", %{
    schema: schema,
    actor: actor,
    name: name
  } do
    job = Fx.job!(schema, actor, name, %{}, ~U[2026-06-01 09:00:00.000000Z])

    assert :ok = ScheduledJobSweep.run(schema, @now)
    assert Fx.instance_count(schema) == 1
    ran = reload(schema, job)
    assert ran.next_run_at == @next
    assert ran.last_run_at == @due
    assert ran.last_outcome_details == %{"skipped_slots" => 3}

    assert :ok = ScheduledJobSweep.run(schema, @now)
    assert Fx.instance_count(schema) == 1
  end

  test "M2 a disabled job is not run", %{schema: schema, actor: actor, name: name} do
    job = Fx.job!(schema, actor, name, %{}, @due)
    {:ok, _} = ScheduledJobs.disable(schema, job.id, actor)
    before = reload(schema, job)

    assert :ok = ScheduledJobSweep.run(schema, @now)
    assert Fx.instance_count(schema) == 0
    assert reload(schema, job) == before
  end

  test "C1 two concurrent sweeps start at most one instance for one slot", %{
    schema: schema,
    actor: actor,
    name: name
  } do
    Fx.job!(schema, actor, name, %{}, @due)

    1..2
    |> Enum.map(fn _ -> Task.async(fn -> ScheduledJobSweep.run(schema, @now) end) end)
    |> Task.await_many(30_000)

    assert Fx.instance_count(schema) == 1
  end

  test "C2 a row locked by another claim is skipped and a replayed key starts nothing new", %{
    schema: schema,
    actor: actor,
    name: name
  } do
    job = Fx.job!(schema, actor, name, %{}, @due)
    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.one(from(j in Job, where: j.id == ^job.id, lock: "FOR UPDATE"), prefix: schema)
          send(parent, :locked)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :locked, 10_000
    assert :ok = ScheduledJobSweep.run(schema, @now)
    assert Fx.instance_count(schema) == 0
    send(holder.pid, :release)
    Task.await(holder, 10_000)

    assert :ok = ScheduledJobSweep.run(schema, @now)
    assert :ok = ScheduledJobSweep.run(schema, @now)
    assert Fx.instance_count(schema) == 1

    key = "scheduled_job:#{job.id}:#{DateTime.to_iso8601(@due)}"

    assert {:ok, %{replayed: true}} =
             Engine.create(
               %{
                 definition_name: name,
                 initial_variables: job.variables,
                 actor_id: actor,
                 idempotency_key: key
               },
               prefix: schema
             )

    assert Fx.instance_count(schema) == 1
  end

  describe "F failure behaviour: a closed code, next_run_at advances, audit written" do
    defp assert_failed(schema, job, code, failures \\ 1) do
      row = reload(schema, job)
      assert row.last_outcome == code
      assert row.consecutive_failures == failures
      assert row.next_run_at == @next
    end

    test "F1 unknown, draft, retired, needs reactivation", %{schema: schema, actor: actor} do
      draft = Fx.definition!(schema, nil, false)
      retired = Fx.definition!(schema)
      Fx.set_status!(schema, retired, :deprecated)
      reactivate = Fx.definition!(schema)
      Fx.needs_reactivation!(schema, reactivate)

      expectations = [
        {"no-such-definition", "definition_not_found"},
        {draft, "definition_not_found"},
        {retired, "definition_not_found"},
        {reactivate, "definition_needs_reactivation"}
      ]

      jobs =
        for {def_name, code} <- expectations do
          {Fx.job!(schema, actor, def_name, %{}, @due), code}
        end

      assert :ok = ScheduledJobSweep.run(schema, @now)

      for {job, code} <- jobs, do: assert_failed(schema, job, code)
      assert Fx.instance_count(schema) == 0
      assert length(audits(schema, "scheduled_job.run")) == 4
    end

    test "F2 the creating user is re-checked", %{schema: schema, name: name} do
      inactive = Fx.actor!(schema)

      Repo.update_all(from(u in User, where: u.id == ^inactive.id), [set: [status: :inactive]],
        prefix: schema
      )

      no_role = Fx.actor!(schema)
      Fx.drop_roles!(schema, no_role.id)

      worker = Fx.actor!(schema, "TASK_WORKER")

      scoped = Fx.actor!(schema)
      Fx.drop_roles!(schema, scoped.id)
      group = Rsg.fresh_group!(schema)
      Rsg.member!(schema, group.id, scoped)
      Rsg.raw_binding!(schema, "PROCESS_OPERATOR", :platform_role, group.id)
      Rsg.raw_scoped_row!(schema, group.id, "PROCESS_OPERATOR", Rsg.node!(schema))

      jobs = [
        Fx.job!(schema, inactive.id, name, %{}, @due),
        Fx.job!(schema, no_role.id, name, %{}, @due),
        Fx.job!(schema, worker.id, name, %{}, @due),
        Fx.job!(schema, scoped.id, name, %{scope_node_id: Rsg.node!(schema)}, @due)
      ]

      assert :ok = ScheduledJobSweep.run(schema, @now)

      for job <- jobs, do: assert_failed(schema, job, "actor_not_allowed")
      assert Fx.instance_count(schema) == 0
    end

    test "F3 start_failed and raised through the seam; the next job still runs", %{
      schema: schema,
      actor: actor,
      name: name
    } do
      raising = Fx.job!(schema, actor, name, %{}, ~U[2026-06-01 10:00:00.000000Z])
      failing = Fx.job!(schema, actor, name, %{}, ~U[2026-06-01 11:00:00.000000Z])
      good = Fx.job!(schema, actor, name, %{}, @due)

      start_fun = fn attrs, opts ->
        cond do
          attrs.idempotency_key =~ raising.id -> raise "boom with detail 99"
          attrs.idempotency_key =~ failing.id -> {:error, {:detail, "do not store me"}}
          true -> Engine.create(attrs, opts)
        end
      end

      assert :ok = ScheduledJobSweep.run(schema, @now, start_fun: start_fun)

      assert reload(schema, raising).last_outcome == "raised"
      assert reload(schema, failing).last_outcome == "start_failed"
      assert reload(schema, good).last_outcome == "ok"
      assert Fx.instance_count(schema) == 1

      stored =
        Repo.all(from(j in Job, select: [j.last_outcome, j.last_outcome_details]), prefix: schema)

      refute inspect(stored) =~ "boom"
      refute inspect(stored) =~ "do not store"
    end

    test "F4 the 5th consecutive failure disables with audit; a success resets", %{
      schema: schema,
      actor: actor,
      name: name
    } do
      bad = Fx.job!(schema, actor, "missing-def", %{}, @due)
      flaky = Fx.job!(schema, actor, name, %{}, @due)

      for _ <- 1..4 do
        Repo.update_all(from(j in Job, where: j.id == ^bad.id), [set: [next_run_at: @due]],
          prefix: schema
        )

        ScheduledJobSweep.run(schema, @now, start_fun: &Engine.create/2)
      end

      row = reload(schema, bad)
      assert row.enabled
      assert row.consecutive_failures == 4
      assert audits(schema, "scheduled_job.auto_disabled") == []

      Repo.update_all(from(j in Job, where: j.id == ^bad.id), [set: [next_run_at: @due]],
        prefix: schema
      )

      ScheduledJobSweep.run(schema, @now)

      row = reload(schema, bad)
      refute row.enabled
      assert row.consecutive_failures == 5
      assert [entry] = audits(schema, "scheduled_job.auto_disabled")
      assert entry.resource_id == bad.id
      assert entry.after_state["key"] == bad.key

      # success after failures resets the counter
      Repo.update_all(from(j in Job, where: j.id == ^flaky.id), [set: [consecutive_failures: 2]],
        prefix: schema
      )

      Repo.update_all(from(j in Job, where: j.id == ^flaky.id), [set: [next_run_at: @due]],
        prefix: schema
      )

      ScheduledJobSweep.run(schema, @now)
      assert reload(schema, flaky).consecutive_failures == 0
    end
  end

  test "F5 a raising tenant does not stop the next tenant", %{
    schema: schema_a,
    actor: actor,
    name: name
  } do
    b = TenantFixture.provisioned_tenant!(slug_prefix: "sj-sweep-b")
    actor_b = Fx.actor!(b.schema_name)
    name_b = Fx.definition!(b.schema_name)
    Fx.job!(schema_a, actor, name, %{}, @due)
    Fx.job!(b.schema_name, actor_b.id, name_b, %{}, @due)

    raising = fn _attrs, _opts -> raise "tenant a is broken" end

    results =
      for {schema, fun} <- [{schema_a, raising}, {b.schema_name, &Engine.create/2}] do
        ScheduledJobSweep.run(schema, @now, start_fun: fun)
      end

    assert results == [:ok, :ok]
    assert Fx.instance_count(schema_a) == 0
    assert Fx.instance_count(b.schema_name) == 1
  end

  test "T1 a sweep of tenant B never touches tenant A", %{
    schema: schema_a,
    actor: actor,
    name: name
  } do
    b = TenantFixture.provisioned_tenant!(slug_prefix: "sj-sweep-b")
    job = Fx.job!(schema_a, actor, name, %{}, @due)

    assert :ok = ScheduledJobSweep.run(b.schema_name, @now)
    assert Fx.instance_count(schema_a) == 0
    assert Fx.instance_count(b.schema_name) == 0
    assert reload(schema_a, job) == job
  end

  test "S7 the sweep and the context carry no process, evaluation or secret path" do
    files =
      ["lib/letflow/scheduler/scheduled_job_sweep.ex", "lib/letflow/scheduled_jobs.ex"] ++
        Path.wildcard("lib/letflow/scheduled_jobs/*.ex")

    forbidden = ~w(GenServer Task. Supervisor Code.eval System.cmd Req. :httpc Secrets Lua)

    for file <- files do
      source = File.read!(file)
      code = Regex.replace(~r/@moduledoc """.*?"""/s, source, "")
      code = Regex.replace(~r/@doc """.*?"""/s, code, "")

      for token <- forbidden do
        refute code =~ token, "#{file} contains #{token}"
      end
    end

    sweep = File.read!("lib/letflow/scheduler/scheduled_job_sweep.ex")
    assert sweep =~ "platform timer"
    assert sweep =~ "record transition sweep"

    users =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(&(File.read!(&1) =~ "start_fun"))

    assert users == ["lib/letflow/scheduler/scheduled_job_sweep.ex"]
  end
end
