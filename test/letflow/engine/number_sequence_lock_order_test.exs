defmodule Letflow.Engine.NumberSequenceLockOrderTest do
  @moduledoc """
  REQ-541 / GH #3160 criterion 13 (decision 0061 item 5a): the counter row of a bound type is
  locked only while the type's sequence row is held, so a process-step create line (HUMAN
  completion L1, service apply L1b) racing a direct `create_record/2` of the same type can
  neither deadlock nor duplicate or skip a number. L2 repeats L1 with the opposite start order.

  The forced overlap is the shared `Letflow.LockOrderHelpers`: a third connection holds the
  type's sequence row, the two workers park behind it in start order, and the release lets them
  through in lock-queue (FIFO) order. A deadlock cannot be forced because no cycle exists, so
  the assertion is its absence: the telemetry handler reports any `40P01` / `55P03` and
  `forced_overlap/4` fails on one. Sandbox `:auto` mode, hence `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.Records
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.LockOrderHelpers, as: H
  alias Letflow.NumberSequences
  alias Letflow.NumberSequences.Counter
  alias Letflow.Repo
  alias Letflow.Test.SandboxAutoMode

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)

    base = Fx.committed_tenant_case!("gh3160-lock")
    on_exit(fn -> Fx.drop_committed_tenant!(base.tenant.tenant_id) end)

    :ok = H.attach_error_handler(__MODULE__)

    # A process step writes only append-only types, which create_definition/2 refuses, so the
    # definition row is inserted directly (see records_numbering_test.exs).
    Fx.define_type!(base.schema, "stock_note", %{})
    {:ok, tenant_id} = Letflow.TenantProvisioning.tenant_id_for_schema_name(base.schema)

    Repo.insert!(
      %NumberSequences.Definition{
        tenant_id: tenant_id,
        key: "note_no",
        entity_type: "stock_note",
        prefix: "NT",
        padding: 4,
        period: "none"
      },
      prefix: base.schema
    )

    # warm-up: the first creation of a type's synthetic instance is not the race
    assert {:ok, %{record: %{record_number: "NT-0001"}}} = direct_create(base.schema).()

    {:ok, instance_id} = EntityTypeInstance.fetch_instance_id("stock_note", base.schema)
    %{base: base, barrier: {:sequence, instance_id}}
  end

  defp direct_create(schema) do
    fn ->
      Records.create_record(
        %{
          entity_type: "stock_note",
          field_values: %{"label" => "direct"},
          actor_id: Ecto.UUID.generate(),
          idempotency_key: Fx.unique("k")
        },
        schema
      )
    end
  end

  defp human_worker(base) do
    ctx = Fx.attach!(base, [Fx.line("stock_note", %{"label" => %{"const" => "v"}})])
    fn -> Fx.complete(ctx, %{}) end
  end

  defp service_worker(base) do
    graph = Fx.service_graph([Fx.line("stock_note", %{"label" => %{"const" => "v"}})])
    ctx = Fx.attach_service!(base, graph)
    fn -> Fx.apply_http(ctx, %{"label" => "x"}) end
  end

  defp assert_two_numbers_no_gap(schema) do
    numbers =
      Fx.records(schema, "stock_note")
      |> Enum.map(& &1.record_id)
      |> then(&NumberSequences.numbers_for("stock_note", &1, schema))
      |> Map.values()
      |> Enum.sort()

    assert numbers == ["NT-0001", "NT-0002", "NT-0003"]
    assert Repo.all(from(c in Counter, select: c.counter), prefix: schema) == [3]
  end

  test "L1 a HUMAN completion line vs a direct create: no deadlock, no duplicate, no gap",
       %{base: base, barrier: barrier} do
    %{first: first, second: second} =
      H.forced_overlap(base.schema, barrier, human_worker(base), direct_create(base.schema))

    assert {:ok, _} = first
    assert {:ok, %{record: _}} = second
    assert_two_numbers_no_gap(base.schema)
  end

  test "L1b a service apply line vs a direct create: no deadlock, no duplicate, no gap",
       %{base: base, barrier: barrier} do
    %{first: first, second: second} =
      H.forced_overlap(base.schema, barrier, service_worker(base), direct_create(base.schema))

    assert {:ok, :advanced} = first
    assert {:ok, %{record: _}} = second
    assert_two_numbers_no_gap(base.schema)
  end

  test "L2 the opposite start order: the direct create first, the HUMAN completion second",
       %{base: base, barrier: barrier} do
    %{first: first, second: second} =
      H.forced_overlap(base.schema, barrier, direct_create(base.schema), human_worker(base))

    assert {:ok, %{record: _}} = first
    assert {:ok, _} = second
    assert_two_numbers_no_gap(base.schema)
  end
end
