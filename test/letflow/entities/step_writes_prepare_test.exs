defmodule Letflow.Entities.StepWritesPrepareTest do
  @moduledoc """
  GH 2587 / REQ-499 PR A3 (design `gh2587-req499-pr-a-prerequisites.md` sections 4.3, 11 A3):
  `Letflow.Entities.StepWrites.prepare/2` plus the fail-closed `validate_lines/2` and `multi/3`.

  Runs in Sandbox `:auto` mode (real transactions, explicit cleanup) exactly as
  `engine_concurrency_test.exs` does: under the sandbox a `Repo.transaction/1` is a savepoint,
  so `in_transaction?` and `SET LOCAL` scoping could not be observed faithfully otherwise.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.StepWrites
  alias Letflow.Identity.Tenant
  alias Letflow.Support.PlatformTenantFixture, as: QueryCapture
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration
  alias Letflow.Test.SandboxAutoMode

  setup do
    SandboxAutoMode.enter_auto_mode!(Letflow.Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Letflow.Repo) end)

    %{tenant_id: tenant_id, schema_name: schema} =
      TenantFixture.provisioned_tenant!(
        slug_prefix: "gh2587-a3",
        display_name: "GH 2587 A3 Test Tenant",
        teardown: false
      )

    on_exit(fn ->
      case TenantProvisioning.schema_name_for_tenant(tenant_id) do
        {:ok, name} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{name}" CASCADE))
        {:error, :invalid_tenant_id} -> :ok
      end

      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant_id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))
    end)

    assert {:ok, _} = EventTypes.seed!(schema)
    {:ok, schema: schema}
  end

  defp activate!(schema, name) do
    definition = %{
      name: name,
      display_name: name,
      fields: [%{name: "label", type: :string}]
    }

    assert {:ok, row} =
             Definitions.create_definition(
               %{definition: definition, created_by: Ecto.UUID.generate()},
               schema
             )

    assert {:ok, _} =
             Definitions.activate_definition(row.name, Ecto.UUID.generate(), "go-live", schema)
  end

  defp instance_types(schema) do
    from(i in EntityTypeInstance, select: i.entity_type)
    |> Repo.all(prefix: schema)
    |> Enum.sort()
  end

  defp line(type), do: %{"entity_type" => type}

  test "an empty line list is :ok with zero queries", %{schema: schema} do
    {result, queries} =
      QueryCapture.capture_repo_queries(fn -> StepWrites.prepare([], %{prefix: schema}) end)

    assert result == :ok
    assert queries == []
  end

  test "creates one committed synthetic instance per distinct type", %{schema: schema} do
    activate!(schema, "alpha")
    activate!(schema, "beta")

    assert :ok =
             StepWrites.prepare([line("beta"), line("alpha"), line("alpha")], %{prefix: schema})

    assert instance_types(schema) == ["alpha", "beta"]

    # Committed: visible from a different connection.
    assert Task.await(Task.async(fn -> instance_types(schema) end)) == ["alpha", "beta"]
  end

  test "a type without an active definition (or a malformed line) gets no instance row",
       %{schema: schema} do
    activate!(schema, "alpha")

    lines = [line("alpha"), line("ghost"), %{"entity_type" => 5}, %{}]
    assert :ok = StepWrites.prepare(lines, %{prefix: schema})
    assert instance_types(schema) == ["alpha"]
  end

  test "inside a caller's transaction it refuses and writes nothing", %{schema: schema} do
    activate!(schema, "alpha")

    result = Repo.transaction(fn -> StepWrites.prepare([line("alpha")], %{prefix: schema}) end)

    assert result == {:ok, {:error, :prepare_inside_transaction}}
    assert instance_types(schema) == []
  end

  test "the two SET LOCAL statements precede every entity query in the prepare transaction",
       %{schema: schema} do
    activate!(schema, "alpha")

    {result, queries} =
      QueryCapture.capture_repo_queries(fn ->
        StepWrites.prepare([line("alpha")], %{prefix: schema})
      end)

    assert result == :ok
    sqls = Enum.map(queries, & &1.query)

    lock_idx = Enum.find_index(sqls, &(&1 =~ "SET LOCAL lock_timeout = '2s'"))
    stmt_idx = Enum.find_index(sqls, &(&1 =~ "SET LOCAL statement_timeout = '2s'"))
    first_entity_idx = Enum.find_index(sqls, &(&1 =~ "entity_"))

    assert is_integer(lock_idx) and is_integer(stmt_idx)
    assert is_integer(first_entity_idx)
    assert stmt_idx == lock_idx + 1
    assert first_entity_idx > stmt_idx
  end

  test "types are processed once each in ascending byte order", %{schema: schema} do
    activate!(schema, "alpha")
    activate!(schema, "beta")

    {result, queries} =
      QueryCapture.capture_repo_queries(fn ->
        StepWrites.prepare([line("beta"), line("alpha"), line("alpha")], %{prefix: schema})
      end)

    assert result == :ok

    # Every query that names a type (activation resolve, definition read, get_or_create), in
    # issue order. Types are processed one at a time, so the dedup'd name sequence is exactly
    # one run per type: ["alpha", "beta"] means ascending order and no type handled twice.
    looked_up =
      queries
      |> Enum.flat_map(fn q ->
        q
        |> Map.get(:params, [])
        |> List.wrap()
        |> Enum.filter(&(&1 in ["alpha", "beta"]))
        |> Enum.take(1)
      end)
      |> Enum.dedup()

    assert looked_up != []
    assert looked_up == ["alpha", "beta"]
  end

  test "SET LOCAL does not leak past the prepare transaction", %{schema: schema} do
    activate!(schema, "alpha")
    show = fn name -> Repo.query!("SHOW #{name}").rows end

    before = {show.("lock_timeout"), show.("statement_timeout")}
    assert :ok = StepWrites.prepare([line("alpha")], %{prefix: schema})
    assert {show.("lock_timeout"), show.("statement_timeout")} == before
    refute before == {[["2s"]], [["2s"]]}
  end

  test "a held uncommitted insert of the same type maps to :entity_write_contention",
       %{schema: schema} do
    activate!(schema, "alpha")
    test_pid = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          cs =
            EntityTypeInstance.insert_changeset(%EntityTypeInstance{}, %{
              entity_type: "alpha",
              instance_id: Ecto.UUID.generate()
            })

          Repo.insert!(cs, prefix: schema)
          send(test_pid, :held)

          receive do
            :release -> :ok
          after
            15_000 -> :ok
          end

          Repo.rollback(:done)
        end)
      end)

    assert_receive :held, 5_000
    started = System.monotonic_time(:millisecond)
    result = StepWrites.prepare([line("alpha")], %{prefix: schema})
    elapsed = System.monotonic_time(:millisecond) - started
    send(holder.pid, :release)
    Task.await(holder)

    assert result == {:error, :entity_write_contention}
    assert elapsed < 8_000
    assert instance_types(schema) == []
  end

  describe "fail-closed write callbacks" do
    test "validate_lines/2" do
      assert StepWrites.validate_lines([], %{prefix: "x"}) == :ok

      assert StepWrites.validate_lines([line("a"), line("b")], %{prefix: "x"}) ==
               {:error,
                [
                  %{index: 0, code: :entity_writes_not_enabled},
                  %{index: 1, code: :entity_writes_not_enabled}
                ]}
    end

    test "EntityPortImpl returns what StepWrites returns for the same input" do
      alias Letflow.Entities.EntityPortImpl
      lines = [line("a"), line("b")]
      ctx = %{prefix: "x"}
      m = Ecto.Multi.new()

      assert EntityPortImpl.validate_lines(lines, ctx) == StepWrites.validate_lines(lines, ctx)
      assert EntityPortImpl.validate_lines([], ctx) == StepWrites.validate_lines([], ctx)
      assert EntityPortImpl.prepare([], ctx) == StepWrites.prepare([], ctx)

      assert Ecto.Multi.to_list(EntityPortImpl.multi(m, lines, ctx)) ==
               Ecto.Multi.to_list(StepWrites.multi(m, lines, ctx))

      assert EntityPortImpl.multi(m, [], ctx) == StepWrites.multi(m, [], ctx)
    end

    test "multi/3" do
      m = Ecto.Multi.new()
      assert StepWrites.multi(m, [], %{prefix: "x"}) == m

      out = StepWrites.multi(m, [line("a")], %{prefix: "x"})

      assert [{{:line, 0, :build}, {:error, :entity_writes_not_enabled}}] =
               Ecto.Multi.to_list(out)
    end
  end
end
