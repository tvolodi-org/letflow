defmodule Letflow.ScheduledJobsTest do
  @moduledoc """
  REQ-561 / GH #3194 -- the `Letflow.ScheduledJobs` context: storage and tenancy (criterion 1),
  schedule validation on create AND update (criteria 2 and 4: V1..V5), and audit (criterion 11:
  A1, A2). `async: false`: `TenantFixture.provisioned_tenant!/1` switches the sandbox to global
  auto mode.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit.Entry
  alias Letflow.Repo
  alias Letflow.ScheduledJobs
  alias Letflow.ScheduledJobs.Job
  alias Letflow.TenantFixture
  alias Letflow.TestSupport.ScheduledJobFixture, as: Fx

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "sj-ctx")
    schema = tenant.schema_name
    %{schema: schema, actor: Ecto.UUID.generate(), name: Fx.definition!(schema)}
  end

  defp job_count(schema), do: Repo.aggregate(Job, :count, :id, prefix: schema)

  defp audits(schema, action) do
    Repo.all(from(e in Entry, where: e.action == ^action), prefix: schema)
  end

  describe "V1/V2 create refusals name the field and store nothing" do
    test "V1 interval table", %{schema: schema, actor: actor, name: name} do
      for {value, ok?} <- [{4, false}, {5, true}, {10_080, true}, {10_081, false}] do
        attrs = Fx.attrs(name, %{interval_minutes: value})
        result = ScheduledJobs.create(schema, attrs, actor)

        if ok?,
          do: assert({:ok, _job} = result),
          else: assert({:error, {:validation, [{:interval_minutes, :invalid}]}} = result)
      end

      before = job_count(schema)

      for bad <- [7.5, "10", nil] do
        assert {:error, {:validation, [{:interval_minutes, _}]}} =
                 ScheduledJobs.create(schema, Fx.attrs(name, %{interval_minutes: bad}), actor)
      end

      assert job_count(schema) == before
    end

    test "V2 anchor, key, variables", %{schema: schema, actor: actor, name: name} do
      cases = [
        {%{anchor_at: nil}, {:anchor_at, :required}},
        {%{anchor_at: "2026-01-01T00:00:00"}, {:anchor_at, :not_utc}},
        {%{anchor_at: "2026-01-01T00:00:00+02:00"}, {:anchor_at, :not_utc}},
        {%{anchor_at: "garbage"}, {:anchor_at, :invalid}},
        {%{key: "  "}, {:key, :required}},
        {%{key: String.duplicate("k", 101)}, {:key, :too_long}},
        {%{variables: [1]}, {:variables, :invalid}},
        {%{variables: "x"}, {:variables, :invalid}},
        {%{variables: %URI{}}, {:variables, :invalid}}
      ]

      for {override, expected} <- cases do
        assert {:error, {:validation, [^expected]}} =
                 ScheduledJobs.create(schema, Fx.attrs(name, override), actor)
      end

      assert job_count(schema) == 0
      assert {:ok, _} = ScheduledJobs.create(schema, Fx.attrs(name, %{key: "dup"}), actor)

      assert {:error, {:validation, [{:key, :taken}]}} =
               ScheduledJobs.create(schema, Fx.attrs(name, %{key: "dup"}), actor)

      assert job_count(schema) == 1
    end

    test "tenant_id in attrs is refused", %{schema: schema, actor: actor, name: name} do
      attrs = Map.put(Fx.attrs(name), :tenant_id, Ecto.UUID.generate())

      assert {:error, {:validation, [{:tenant_id, :not_accepted}]}} =
               ScheduledJobs.create(schema, attrs, actor)
    end
  end

  test "V3 next_run_at is the first slot not before creation", %{
    schema: schema,
    actor: actor,
    name: name
  } do
    now = ~U[2026-03-05 10:07:00.000000Z]

    assert {:ok, job} =
             ScheduledJobs.create(schema, Fx.attrs(name, %{interval_minutes: 60}), actor, now)

    assert job.next_run_at == ~U[2026-03-05 11:00:00.000000Z]
    assert job.enabled

    future = ~U[2030-01-01 00:00:00.000000Z]

    assert {:ok, job2} =
             ScheduledJobs.create(schema, Fx.attrs(name, %{anchor_at: future}), actor, now)

    assert job2.next_run_at == future
  end

  test "V4 secret-like variables are refused, empty ones are not", %{
    schema: schema,
    actor: actor,
    name: name
  } do
    for vars <- [
          %{"password" => "x"},
          %{"Token" => "x"},
          %{"nested" => %{"deep" => [%{"api_key" => "x"}]}},
          %{secret: "x"}
        ] do
      assert {:error, {:validation, [{:variables, :secret_like}]}} =
               ScheduledJobs.create(schema, Fx.attrs(name, %{variables: vars}), actor)
    end

    assert {:ok, _} =
             ScheduledJobs.create(
               schema,
               Fx.attrs(name, %{variables: %{"password" => ""}}),
               actor
             )
  end

  test "V5 update refuses bad input, leaves the row and writes no audit", %{
    schema: schema,
    actor: actor,
    name: name
  } do
    {:ok, job} = ScheduledJobs.create(schema, Fx.attrs(name), actor)

    bad = [
      {%{interval_minutes: 4}, {:interval_minutes, :invalid}},
      {%{interval_minutes: 10_081}, {:interval_minutes, :invalid}},
      {%{anchor_at: "2026-01-01T00:00:00+02:00"}, {:anchor_at, :not_utc}},
      {%{anchor_at: "2026-01-01T00:00:00"}, {:anchor_at, :not_utc}},
      {%{anchor_at: nil}, {:anchor_at, :required}},
      {%{variables: [1]}, {:variables, :invalid}},
      {%{variables: %{"api_key" => "x"}}, {:variables, :secret_like}}
    ]

    for {attrs, expected} <- bad do
      assert {:error, {:validation, [^expected]}} =
               ScheduledJobs.update(schema, job.id, attrs, actor)
    end

    assert {:ok, same} = ScheduledJobs.get(schema, job.id)
    assert same == job
    assert audits(schema, "scheduled_job.updated") == []
  end

  test "update recomputes next_run_at and audits changed field names", %{
    schema: schema,
    actor: actor,
    name: name
  } do
    {:ok, job} = ScheduledJobs.create(schema, Fx.attrs(name), actor)
    now = ~U[2026-06-01 00:10:00.000000Z]

    assert {:ok, updated} =
             ScheduledJobs.update(schema, job.id, %{interval_minutes: 30}, actor, now)

    assert updated.next_run_at == ~U[2026-06-01 00:30:00.000000Z]
    assert [entry] = audits(schema, "scheduled_job.updated")
    assert entry.after_state["changed_fields"] == ["interval_minutes"]
    assert {:error, :not_found} = ScheduledJobs.update(schema, "nope", %{title: "x"}, actor)
  end

  test "T1 two tenants never see one another's jobs", %{
    schema: schema_a,
    actor: actor,
    name: name_a
  } do
    b = TenantFixture.provisioned_tenant!(slug_prefix: "sj-ctx-b")
    {:ok, job} = ScheduledJobs.create(schema_a, Fx.attrs(name_a), actor)

    assert ScheduledJobs.list(b.schema_name) == []
    assert {:error, :not_found} = ScheduledJobs.get(b.schema_name, job.id)
    assert {:error, :not_found} = ScheduledJobs.disable(b.schema_name, job.id, actor)
    assert {:error, :not_found} = ScheduledJobs.enable(b.schema_name, job.id, actor)
    assert {:ok, %Job{enabled: true}} = ScheduledJobs.get(schema_a, job.id)
    assert [%Job{id: id}] = ScheduledJobs.list(schema_a)
    assert id == job.id
  end

  test "T2 the migration reached the tenant schema", %{schema: schema} do
    assert "scheduled_jobs" in TenantFixture.expected_tenant_tables()

    assert %{rows: [[1]]} =
             Repo.query!(
               "SELECT count(*)::int FROM information_schema.tables WHERE table_schema = $1 AND table_name = 'scheduled_jobs'",
               [schema]
             )
  end

  test "A1 audit for every action carries key and actor, never variable values", %{
    schema: schema,
    actor: actor,
    name: name
  } do
    value = "distinctive-value-7731"

    {:ok, job} =
      ScheduledJobs.create(schema, Fx.attrs(name, %{variables: %{"b" => value}}), actor)

    {:ok, _} =
      ScheduledJobs.update(
        schema,
        job.id,
        %{variables: %{"b" => value <> "x"}, title: "T2"},
        actor
      )

    {:ok, _} = ScheduledJobs.disable(schema, job.id, actor)
    {:ok, _} = ScheduledJobs.enable(schema, job.id, actor)

    for action <- ~w(created updated disabled enabled) do
      assert [entry] = audits(schema, "scheduled_job." <> action)
      assert entry.actor_id == actor
      assert entry.resource_id == job.id
      assert entry.after_state["key"] == job.key
    end

    all = Repo.all(from(e in Entry, where: like(e.action, "scheduled_job.%")), prefix: schema)
    encoded = Jason.encode!(Enum.map(all, &[&1.before_state, &1.after_state]))
    refute encoded =~ "distinctive-value"
  end

  test "A2 a refused create leaves no audit row, a good one exactly one", %{
    schema: schema,
    actor: actor,
    name: name
  } do
    {:ok, _} = ScheduledJobs.create(schema, Fx.attrs(name, %{key: "once"}), actor)
    assert {:error, _} = ScheduledJobs.create(schema, Fx.attrs(name, %{key: "once"}), actor)

    assert {:error, _} =
             ScheduledJobs.create(schema, Fx.attrs(name, %{interval_minutes: 1}), actor)

    assert length(audits(schema, "scheduled_job.created")) == 1
  end
end
