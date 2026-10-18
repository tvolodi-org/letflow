defmodule Letflow.Entities.EntityTypeInstanceAtomicCreateTest do
  @moduledoc """
  GH #2702 (F8) follow-up: `EntityTypeInstance.get_or_create/2` must make the registry row and
  its `instance_projections` row visible together (one transaction) and must heal a registry row
  whose projection is missing, so a first writer never sees `{:error, :instance_not_started}`.

  Observed in CI as `records_upsert_by_external_ref_test` "two workers import the same ref set"
  returning `{:error, :instance_not_started}`: the creator committed the registry row, a second
  writer took the fast path and appended before the creator's SEPARATE projection insert ran.

  Real concurrency needs real connections, so this follows `records_upsert_by_external_ref_test`:
  Sandbox `:auto` mode (entered/exited in pairs) and a committed tenant fixture.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Records
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Repo
  alias Letflow.TenantFixture
  alias Letflow.Test.SandboxAutoMode

  @actor "00000000-0000-0000-0000-0000000000a5"
  @type_name "atomic_widget"
  @barrier_key 27_020_001

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)

    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2702-atomic")
    schema = tenant.schema_name
    {:ok, _seeded} = EventTypes.seed!(schema)

    {:ok, row} =
      Definitions.create_definition(
        %{
          definition: %{
            name: @type_name,
            display_name: @type_name,
            fields: [%{name: "title", type: :string, required: true}]
          },
          created_by: @actor
        },
        schema
      )

    {:ok, _} = Definitions.activate_definition(row.name, @actor, "gh2702", schema)

    # Whatever preparation the definition steps did, the type starts brand-new.
    Repo.delete_all(from(e in EntityTypeInstance, where: e.entity_type == @type_name),
      prefix: schema
    )

    Repo.delete_all(from(p in InstanceProjection, where: p.definition_id == p.instance_id),
      prefix: schema
    )

    {:ok, schema: schema}
  end

  defp create(schema, title \\ "t") do
    Records.create_record(
      %{
        entity_type: @type_name,
        field_values: %{"title" => title},
        actor_id: @actor,
        idempotency_key: Ecto.UUID.generate()
      },
      schema
    )
  end

  defp registry_ids(schema),
    do: Repo.all(from(e in EntityTypeInstance, select: e.instance_id), prefix: schema)

  defp projection_ids(schema) do
    Repo.all(
      from(p in InstanceProjection,
        where: p.definition_id == p.instance_id,
        select: p.instance_id
      ),
      prefix: schema
    )
  end

  defp insert_registry_row_alone!(schema) do
    instance_id = Ecto.UUID.generate()

    %EntityTypeInstance{}
    |> EntityTypeInstance.insert_changeset(%{entity_type: @type_name, instance_id: instance_id})
    |> Repo.insert!(prefix: schema)

    instance_id
  end

  defp projection_rows(schema) do
    Repo.all(from(p in InstanceProjection, where: p.definition_id == p.instance_id),
      prefix: schema
    )
  end

  defp assert_synthetic_projection!(schema, instance_id) do
    assert [%InstanceProjection{instance_id: ^instance_id, definition_id: ^instance_id} = row] =
             projection_rows(schema)

    assert row.status == :active
  end

  test "crash hole: a registry row with no projection is healed by a create", %{schema: schema} do
    instance_id = insert_registry_row_alone!(schema)
    assert projection_ids(schema) == []

    assert {:ok, _result} = create(schema)

    assert registry_ids(schema) == [instance_id]
    assert_synthetic_projection!(schema, instance_id)
  end

  test "crash hole: get_or_create/2 on the fast path ensures the missing projection", %{
    schema: schema
  } do
    instance_id = insert_registry_row_alone!(schema)

    assert {:ok, ^instance_id} = EntityTypeInstance.get_or_create(@type_name, schema)
    assert_synthetic_projection!(schema, instance_id)
    assert {:ok, ^instance_id} = EntityTypeInstance.get_or_create(@type_name, schema)
    assert_synthetic_projection!(schema, instance_id)

    # the healed projection is usable: an append against it succeeds
    assert {:ok, _result} = create(schema)
  end

  test "fetch_instance_id/2 stays read-only: no registry row is created", %{schema: schema} do
    assert {:error, :not_found} = EntityTypeInstance.fetch_instance_id(@type_name, schema)
    assert registry_ids(schema) == []
    assert projection_ids(schema) == []
  end

  test "nesting: get_or_create/2 inside an outer transaction creates both rows on commit", %{
    schema: schema
  } do
    assert {:ok, instance_id} =
             Repo.transaction(fn ->
               {:ok, id} = EntityTypeInstance.get_or_create(@type_name, schema)
               assert registry_ids(schema) == [id]
               id
             end)

    assert registry_ids(schema) == [instance_id]
    assert_synthetic_projection!(schema, instance_id)
    assert {:ok, ^instance_id} = EntityTypeInstance.get_or_create(@type_name, schema)
  end

  test "forced overlap: a second writer never observes the registry row without a projection",
       %{schema: schema} do
    hold_barrier!(schema)

    # The creator parks on the barrier at its projection insert.
    creator = Task.async(fn -> EntityTypeInstance.get_or_create(@type_name, schema) end)
    wait_until!(fn -> barrier_waiters() == 1 end, "the creator never parked on the barrier")

    # Atomicity, sleep-free: while the creator is parked another connection sees neither row
    # (on the unfixed code the registry row is already committed and visible here).
    assert registry_ids(schema) == []
    assert projection_ids(schema) == []

    # The second writer starts while the creator is parked mid-creation. Unfixed code: the
    # registry row is committed, so it takes the fast path and returns an error at once.
    # Fixed code: it parks on the registry unique key (lock waiters reach 2).
    test_pid = self()

    second =
      Task.async(fn ->
        result = create(schema, "second")
        send(test_pid, :second_done)
        result
      end)

    wait_until!(
      fn -> second_done?() or lock_waiters() >= 2 end,
      "the second writer neither returned nor parked behind the creator"
    )

    # the invariant holds at the observation point
    registry = registry_ids(schema)
    assert registry == [] or projection_ids(schema) != []

    release_barrier!()

    assert {:ok, instance_id} = Task.await(creator, 30_000)
    assert {:ok, _result} = Task.await(second, 30_000)

    assert registry_ids(schema) == [instance_id]
    assert projection_ids(schema) == [instance_id]
  end

  test "N writers parked behind the barrier: one registry row, one projection, all succeed", %{
    schema: schema
  } do
    n = 6
    hold_barrier!(schema)

    tasks = for i <- 1..n, do: Task.async(fn -> create(schema, "w#{i}") end)

    # 1 writer on the advisory barrier + (n - 1) on the registry unique key
    wait_until!(
      fn -> barrier_waiters() == 1 and lock_waiters() == n end,
      "the writers did not all park (1 on the barrier, n-1 on the registry key)"
    )

    assert registry_ids(schema) == []
    release_barrier!()

    results = Enum.map(tasks, &Task.await(&1, 60_000))
    assert Enum.all?(results, &match?({:ok, _}, &1)), inspect(results)
    assert [instance_id] = registry_ids(schema)
    assert projection_ids(schema) == [instance_id]
  end

  test "smoke: 8 unsynchronised concurrent first writers all succeed with one row each", %{
    schema: schema
  } do
    tasks =
      for n <- 1..8 do
        Task.async(fn ->
          receive do
            :go -> create(schema, "w#{n}")
          end
        end)
      end

    for task <- tasks, do: send(task.pid, :go)
    results = Enum.map(tasks, &Task.await(&1, 60_000))

    assert Enum.all?(results, &match?({:ok, _}, &1)), inspect(results)
    assert [instance_id] = registry_ids(schema)
    assert projection_ids(schema) == [instance_id]
  end

  # ---- barrier helpers -----------------------------------------------------------------------

  # Every projection insert in this tenant waits on an advisory lock the test holds.
  defp hold_barrier!(schema) do
    Repo.query!("""
    CREATE FUNCTION "#{schema}".gh2702_barrier() RETURNS trigger AS $$
    BEGIN
      PERFORM pg_advisory_xact_lock(#{@barrier_key});
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER gh2702_barrier BEFORE INSERT ON "#{schema}".instance_projections
    FOR EACH ROW EXECUTE FUNCTION "#{schema}".gh2702_barrier()
    """)

    test_pid = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock($1)", [@barrier_key])
          send(test_pid, :barrier_held)

          receive do
            :release -> :ok
          after
            30_000 -> :ok
          end
        end)
      end)

    Process.put(:barrier_holder, holder)
    on_exit(fn -> send(holder.pid, :release) end)
    assert_receive :barrier_held, 10_000
  end

  defp release_barrier! do
    holder = Process.get(:barrier_holder)
    send(holder.pid, :release)
    assert {:ok, _} = Task.await(holder, 30_000)
  end

  defp second_done? do
    receive do
      :second_done -> true
    after
      0 -> false
    end
  end

  # Backends of this database waiting on OUR advisory lock (not any other lock).
  defp barrier_waiters do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*) FROM pg_locks l JOIN pg_database d ON d.oid = l.database
        WHERE l.locktype = 'advisory' AND NOT l.granted AND l.objid = $1::bigint::oid
          AND d.datname = current_database()
        """,
        [@barrier_key]
      )

    count
  end

  # All backends of this database blocked on any lock.
  defp lock_waiters do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock' AND pid <> pg_backend_pid()"
      )

    count
  end

  defp wait_until!(fun, message, attempts \\ 400) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk(message)

      true ->
        Process.sleep(25)
        wait_until!(fun, message, attempts - 1)
    end
  end
end
