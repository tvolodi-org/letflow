defmodule Letflow.Scheduler.ScheduledJobPollerTest do
  @moduledoc """
  REQ-561 / GH #3194 -- FL1: the ninth Poller sweep is gated by `config :letflow, :scheduled_jobs,
  enabled:` (default false). With the flag off a due job is neither claimed nor run; with it on
  one tick runs it. `Poller.handle_info(:tick, state)` is called directly as a plain function, as
  `poller_test.exs` does.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Repo
  alias Letflow.ScheduledJobs
  alias Letflow.ScheduledJobs.Job
  alias Letflow.Scheduler.Poller
  alias Letflow.TenantFixture
  alias Letflow.TestSupport.ScheduledJobFixture, as: Fx

  # Read before any test of this module changes it: the compiled default from config/config.exs.
  @compiled_default Application.compile_env(:letflow, :scheduled_jobs)

  setup do
    original = Application.get_env(:letflow, :scheduled_jobs)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:letflow, :scheduled_jobs)
        val -> Application.put_env(:letflow, :scheduled_jobs, val)
      end
    end)

    :ok
  end

  defp tick,
    do:
      Poller.handle_info(:tick, %{
        last_retention_run_at: nil,
        last_partition_maintenance_run_at: nil
      })

  test "the shipped default is off" do
    assert @compiled_default == [enabled: false]
  end

  test "FL1 flag false: nothing runs; flag true: one tick runs the due job" do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "sj-poll")
    schema = tenant.schema_name
    actor = Fx.actor!(schema)
    name = Fx.definition!(schema)
    due = ~U[2026-01-01 00:00:00.000000Z]
    job = Fx.job!(schema, actor.id, name, %{}, due)

    Application.put_env(:letflow, :scheduled_jobs, enabled: false)
    refute ScheduledJobs.enabled?()
    assert {:noreply, _state} = tick()
    assert Fx.instance_count(schema) == 0
    assert Repo.get!(Job, job.id, prefix: schema) == job

    Application.put_env(:letflow, :scheduled_jobs, enabled: true)
    assert ScheduledJobs.enabled?()
    assert {:noreply, _state} = tick()
    assert Fx.instance_count(schema) == 1
    assert Repo.get!(Job, job.id, prefix: schema).last_outcome == "ok"
  end
end
