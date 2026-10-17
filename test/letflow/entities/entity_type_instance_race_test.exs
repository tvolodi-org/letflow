defmodule Letflow.Entities.EntityTypeInstanceRaceTest do
  @moduledoc """
  GH #2702 (T9, security review R1/F8): `EntityTypeInstance.get_or_create/2` must not
  leave an ORPHAN `instance_projections` row (`definition_id = instance_id`, id not in
  `entity_type_instances`) when two first writes for one entity type race.

  Real concurrency needs real, separate connections, so this file follows
  `test/letflow/engine_concurrency_test.exs`: Sandbox `:auto` mode for the whole test
  body, a non-torn-down tenant fixture, and an explicit `DROP SCHEMA` cleanup.

  Two tests:

    * deterministic loser: the test process holds an UNCOMMITTED registry row (the
      "winner"), a second process calls `get_or_create/2` for the same type, blocks on the
      registry insert, and only then does the winner commit. The loser MUST adopt the
      winner's id and create no projection for its own minted id (kills mutant M9).
    * stress: N concurrent first calls for several brand-new types; afterwards the
      projection rows and registry rows agree one-to-one and every caller got one id.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Identity.Tenant
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration
  alias Letflow.Test.SandboxAutoMode

  @callers 8

  defp provisioned_tenant do
    SandboxAutoMode.enter_auto_mode!(Letflow.Repo)

    # Release the sandbox ownership DataCase checked out: an owned (and never committed)
    # connection would be shared with Task children via `$callers`, which would both hide
    # the race and make the deterministic test wait on a transaction that never commits.
    :ok = Ecto.Adapters.SQL.Sandbox.checkin(Letflow.Repo)

    %{tenant_id: tenant_id, schema_name: schema_name} =
      TenantFixture.provisioned_tenant!(
        slug_prefix: "gh2702-race",
        display_name: "GH2702 Race Test Tenant",
        teardown: false
      )

    # Registered FIRST so it runs LAST (LIFO): the cleanup below still needs :auto mode.
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Letflow.Repo) end)

    on_exit(fn ->
      case TenantProvisioning.schema_name_for_tenant(tenant_id) do
        {:ok, name} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{name}" CASCADE))
        {:error, :invalid_tenant_id} -> :ok
      end

      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant_id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))
    end)

    schema_name
  end

  # Every projection row shaped like a synthetic one (definition_id == instance_id).
  defp synthetic_shaped_projection_ids(prefix) do
    from(p in InstanceProjection, where: p.definition_id == p.instance_id, select: p.instance_id)
    |> Repo.all(prefix: prefix)
    |> Enum.sort()
  end

  defp registry_ids(prefix) do
    from(e in EntityTypeInstance, select: e.instance_id)
    |> Repo.all(prefix: prefix)
    |> Enum.sort()
  end

  # Bounded poll (no wall-clock assumption about HOW LONG; this database only, pg_locks is
  # cluster-wide and counted waiters of other parallel partitions): waits until some backend is
  # blocked waiting for a lock, i.e. the loser is parked on the winner's uncommitted row.
  defp wait_until_a_lock_waiter_exists!(attempts \\ 200) do
    %{rows: [[waiting]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock' AND pid <> pg_backend_pid()"
      )

    cond do
      waiting > 0 ->
        :ok

      attempts == 0 ->
        flunk("the second caller never blocked on the uncommitted registry row")

      true ->
        Process.sleep(25)
        wait_until_a_lock_waiter_exists!(attempts - 1)
    end
  end

  test "deterministic loser: adopts the winner's id and creates no orphan projection" do
    prefix = provisioned_tenant()
    entity_type = "race_widget"
    winner_id = Ecto.UUID.generate()

    {:ok, loser_task} =
      Repo.transaction(fn ->
        # The winner's registry row is written but NOT committed yet.
        %EntityTypeInstance{}
        |> EntityTypeInstance.insert_changeset(%{
          entity_type: entity_type,
          instance_id: winner_id
        })
        |> Repo.insert!(prefix: prefix)

        # The loser does not see the uncommitted row, takes the create path and parks on
        # the registry unique key.
        task = Task.async(fn -> EntityTypeInstance.get_or_create(entity_type, prefix) end)
        wait_until_a_lock_waiter_exists!()

        # The winner ensures its own projection and commits.
        %InstanceProjection{}
        |> InstanceProjection.insert_changeset(%{
          instance_id: winner_id,
          status: :active,
          definition_id: winner_id
        })
        |> Repo.insert!(prefix: prefix, on_conflict: :nothing, conflict_target: :instance_id)

        task
      end)

    assert {:ok, ^winner_id} = Task.await(loser_task, 30_000)

    assert registry_ids(prefix) == [winner_id]
    assert synthetic_shaped_projection_ids(prefix) == [winner_id]
  end

  test "stress: concurrent first writes for several new types leave exactly one projection per type" do
    prefix = provisioned_tenant()
    types = for n <- 1..4, do: "stress_type_#{n}"

    results =
      for type <- types do
        ids =
          1..@callers
          |> Task.async_stream(fn _ -> EntityTypeInstance.get_or_create(type, prefix) end,
            max_concurrency: @callers,
            ordered: false,
            timeout: 30_000
          )
          |> Enum.map(fn {:ok, {:ok, id}} -> id end)

        {type, Enum.uniq(ids)}
      end

    assert Enum.all?(results, fn {_type, ids} -> length(ids) == 1 end)

    assert length(registry_ids(prefix)) == length(types)
    assert synthetic_shaped_projection_ids(prefix) == registry_ids(prefix)
  end
end
