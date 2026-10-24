defmodule Letflow.Migrations.TasksScopeNodeIdBackfillMigrationTest do
  @moduledoc """
  REQ-532 / GH #3091 (AC 5): the tenant-scoped data migration
  `20261024200001_backfill_tasks_scope_node_id.exs`.

    * T5a the up run gives each NULL task of a scoped instance its instance's node, leaves a task of
      an unscoped instance NULL, and logs the changed-row count (one row);
    * T5b the down run changes no data (the copied values stay);
    * T5c a tenant with no scoped instance changes zero rows (the logged count says 0);
    * T5d a second run is a no-op: a task that already has a node is never changed.

  Seeding: a task whose instance has a scope node is made with `TaskScopeFixture.insert_task!/3`, and
  the instance's `scope_node_id` is set raw, because the backfill reads the instance side. Real
  Postgres, tenant schemas: `async: false`.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog

  alias Letflow.Repo
  alias Letflow.Support.ScopeSetFixture, as: F
  alias Letflow.Support.TaskScopeFixture, as: T
  alias Letflow.TenantFixture

  @version 20_261_024_200_001

  # the migration module lives in priv/ and is loaded by the manifest, not compiled into the app
  defp migration, do: Module.concat(Letflow.Repo.Migrations, BackfillTasksScopeNodeId)

  defp migrate(schema, direction) do
    Ecto.Migrator.run(Repo, [{@version, migration()}], direction,
      all: true,
      prefix: schema,
      log: false
    )
  end

  # the backfill is the last step of the manifest: take its version off, seed, then run it again
  # returns the captured log of the up run
  defp run_up(schema) do
    assert [@version] == migrate(schema, :down)

    capture_log(fn ->
      assert [@version] == migrate(schema, :up)
    end)
  end

  # a task of an instance scoped at `instance_node` (nil: unscoped), with its own node `task_node`
  defp seed_task!(fx, instance_node, task_node \\ nil) do
    task = T.insert_task!(fx, task_node)

    if instance_node do
      {:ok, instance_id} = Ecto.UUID.dump(task.instance_id)

      Repo.query!(
        ~s|UPDATE "#{fx.schema_name}".instance_projections SET scope_node_id = $1 WHERE instance_id = $2|,
        [Map.fetch!(F.nodes(), instance_node), instance_id]
      )
    end

    task
  end

  defp count_line(schema, n),
    do: "tasks.scope_node_id backfill: #{n} row(s) changed in #{schema}"

  setup do
    fx = T.provision!("req532-bf")
    {:ok, fx: fx, schema: fx.schema_name}
  end

  describe "AC 5 the backfill" do
    test "T5a copies the instance's node into NULL tasks, leaves unscoped ones NULL, logs one changed row",
         %{fx: fx, schema: schema} do
      scoped = seed_task!(fx, :a1)
      plain = seed_task!(fx, nil)
      assert T.stored_scope_node(scoped.id, schema) == nil

      log = run_up(schema)

      assert log =~ count_line(schema, 1)
      assert T.stored_scope_node(scoped.id, schema) == F.nodes().a1
      assert T.stored_scope_node(plain.id, schema) == nil
    end

    test "T5b the down run changes no data: the copied values stay", %{fx: fx, schema: schema} do
      scoped = seed_task!(fx, :a1)
      _ = run_up(schema)
      assert T.stored_scope_node(scoped.id, schema) == F.nodes().a1

      assert [@version] == migrate(schema, :down)
      assert T.stored_scope_node(scoped.id, schema) == F.nodes().a1
    end

    test "T5c a tenant with no scoped instance changes zero rows" do
      %{schema_name: plain_schema} = TenantFixture.provisioned_tenant!(slug_prefix: "req532-bf0")
      _plain = T.insert_task!(%{schema_name: plain_schema}, nil)

      log = run_up(plain_schema)

      assert log =~ count_line(plain_schema, 0)
    end

    test "T5d a second run is a no-op: a task that already has a node is not changed", %{
      fx: fx,
      schema: schema
    } do
      scoped = seed_task!(fx, :a1)
      # a node already set on the task, different from its instance's: it is kept
      T.set_scope_node!(scoped.id, F.nodes().b1, schema)

      log = run_up(schema)

      assert log =~ count_line(schema, 0)
      assert T.stored_scope_node(scoped.id, schema) == F.nodes().b1

      log_again = run_up(schema)
      assert log_again =~ count_line(schema, 0)
      assert T.stored_scope_node(scoped.id, schema) == F.nodes().b1
    end
  end
end
