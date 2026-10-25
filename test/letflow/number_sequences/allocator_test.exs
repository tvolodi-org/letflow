defmodule Letflow.NumberSequences.AllocatorTest do
  @moduledoc """
  REQ-541 / GH #3160 criteria 3, 4, 5, 6, 7 (A1..A9): the format, the year boundary, tenant
  scoping, the counter-only-grows trigger, and source scans of the allocator and its call sites.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Entities.Records
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.NumberSequences
  alias Letflow.NumberSequences.Counter
  alias Letflow.NumberSequences.Number
  alias Letflow.Repo
  alias Letflow.Test.SandboxAutoMode

  @allocator File.read!("lib/letflow/number_sequences.ex")

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    base = Fx.committed_tenant_case!("gh3160-alloc")

    on_exit(fn ->
      Application.delete_env(:letflow, :number_sequences_clock)
      Fx.drop_committed_tenant!(base.tenant.tenant_id)
      SandboxAutoMode.exit_auto_mode!(Repo)
    end)

    %{base: base}
  end

  defp bind!(schema, overrides \\ %{}) do
    Fx.define_type!(schema, "ns_order", %{append_only: false})

    {:ok, definition} =
      NumberSequences.create_definition(
        Map.merge(
          %{key: "order_no", entity_type: "ns_order", prefix: "ORD", padding: 6, period: "year"},
          overrides
        ),
        schema
      )

    definition
  end

  defp create(schema) do
    {:ok, %{record: record}} =
      Records.create_record(
        %{
          entity_type: "ns_order",
          field_values: %{"label" => "x"},
          actor_id: Ecto.UUID.generate(),
          idempotency_key: Fx.unique("k")
        },
        schema
      )

    record
  end

  defp clock(%DateTime{} = at),
    do: Application.put_env(:letflow, :number_sequences_clock, fn -> at end)

  defp counters(schema) do
    Repo.all(from(c in Counter, order_by: c.period, select: {c.period, c.counter}),
      prefix: schema
    )
  end

  test "A1 year format, consecutive from 1", %{base: base} do
    bind!(base.schema)
    year = Integer.to_string(DateTime.utc_now().year)
    assert create(base.schema).record_number == "ORD-#{year}-000001"
    assert create(base.schema).record_number == "ORD-#{year}-000002"
  end

  test "A2 period none", %{base: base} do
    bind!(base.schema, %{period: "none"})
    assert create(base.schema).record_number == "ORD-000001"
    assert create(base.schema).record_number == "ORD-000002"
  end

  test "A3 the padding width is honoured and never truncates", %{base: base} do
    bind!(base.schema, %{period: "none", padding: 2})

    numbers = for _ <- 1..100, do: create(base.schema).record_number
    assert Enum.at(numbers, 0) == "ORD-01"
    assert Enum.at(numbers, 98) == "ORD-99"
    assert Enum.at(numbers, 99) == "ORD-100"
  end

  test "A4 period_for/2 on both sides of 31 December" do
    year = %NumberSequences.Definition{period: "year"}
    none = %NumberSequences.Definition{period: "none"}
    assert NumberSequences.period_for(year, ~U[2026-12-31 23:59:59Z]) == "2026"
    assert NumberSequences.period_for(year, ~U[2027-01-01 00:00:00Z]) == "2027"
    assert NumberSequences.period_for(none, ~U[2027-01-01 00:00:00Z]) == "none"
  end

  test "A4b the first number after a year change is 1 and the old counter stays", %{base: base} do
    bind!(base.schema)
    clock(~U[2026-12-31 23:59:59Z])
    for _ <- 1..5, do: create(base.schema)
    assert create(base.schema).record_number == "ORD-2026-000006"

    clock(~U[2027-01-01 00:00:00Z])
    assert create(base.schema).record_number == "ORD-2027-000001"
    assert counters(base.schema) == [{"2026", 6}, {"2027", 1}]
  end

  test "A5 two tenants with the same key and type count independently", %{base: base} do
    other = Fx.committed_tenant_case!("gh3160-alloc2")
    on_exit(fn -> Fx.drop_committed_tenant!(other.tenant.tenant_id) end)

    bind!(base.schema, %{period: "none"})
    bind!(other.schema, %{period: "none"})

    assert create(base.schema).record_number == "ORD-000001"
    assert create(base.schema).record_number == "ORD-000002"
    assert create(other.schema).record_number == "ORD-000001"
    assert counters(other.schema) == [{"none", 1}]
    assert counters(base.schema) == [{"none", 2}]
  end

  describe "A6 the database guards" do
    setup %{base: base} do
      bind!(base.schema, %{period: "none"})
      create(base.schema)
      %{s: base.schema}
    end

    test "lowering a counter is refused, raising it works", %{s: s, base: base} do
      assert {:error, %Postgrex.Error{postgres: %{code: :restrict_violation, message: msg}}} =
               Repo.query(~s(UPDATE "#{s}".number_sequence_counters SET counter = counter - 1))

      assert msg =~ "cannot be lowered"
      assert counters(base.schema) == [{"none", 1}]

      assert {:ok, _} =
               Repo.query(~s(UPDATE "#{s}".number_sequence_counters SET counter = counter + 1))

      assert counters(base.schema) == [{"none", 2}]
    end

    test "identity change, deletes and log rewrites are refused", %{s: s} do
      for sql <- [
            ~s(UPDATE "#{s}".number_sequence_counters SET period = '2020'),
            ~s(DELETE FROM "#{s}".number_sequence_counters),
            ~s(UPDATE "#{s}".number_sequence_numbers SET number = 99),
            ~s(DELETE FROM "#{s}".number_sequence_numbers)
          ] do
        assert {:error, %Postgrex.Error{postgres: %{code: :restrict_violation}}} =
                 Repo.query(sql)
      end
    end
  end

  test "A7 the unique index backstops a duplicate number", %{base: base} do
    definition = bind!(base.schema, %{period: "none"})
    record = create(base.schema)

    n =
      Repo.one!(from(n in Number, where: n.record_id == ^record.record_id), prefix: base.schema)

    sql =
      ~s(INSERT INTO "#{base.schema}".number_sequence_numbers) <>
        " (tenant_id, sequence_id, period, number, entity_type, record_id, formatted)" <>
        " VALUES ($1, $2, 'none', $3, 'x', $4, 'x')"

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             Repo.query(sql, [
               Ecto.UUID.dump!(definition.tenant_id),
               Ecto.UUID.dump!(definition.id),
               n.number,
               Ecto.UUID.bingenerate()
             ])
  end

  describe "source scans" do
    test "A8 the FOR UPDATE row lock precedes the increment, which precedes the log insert" do
      # `allocate/6` calls `lock_row/4` (insert-if-absent, then the FOR UPDATE select) first
      {lock, _} = :binary.match(@allocator, "_locked = lock_row(repo, definition, period")
      {inc, _} = :binary.match(@allocator, "inc: [counter: 1]")
      {insert, _} = :binary.match(@allocator, "repo.insert(changeset, prefix: schema_prefix)")
      assert lock < inc and inc < insert
      assert @allocator =~ "lock: \"FOR UPDATE\""
      refute @allocator =~ "document_sequences"
    end

    test "A8b records.ex allocates before the record write, in both builders" do
      src = File.read!("lib/letflow/entities/records.ex")
      pos = fn s -> elem(:binary.match(src, s), 0) end
      assert pos.("|> maybe_allocate_number(ctx)") < pos.("Multi.run(:upsert_record_latest")

      assert pos.("|> maybe_allocate_line_number(") <
               pos.("run_line_step(namespace, :upsert_record_latest")
    end

    test "A8c lock_types takes the counter after the sequence row" do
      src = File.read!("lib/letflow/entities/handler_writes.ex")

      {seq, _} =
        :binary.match(src, "EventStore.lock_instance_sequence(repo, instance_id, prefix)")

      {counter, _} = :binary.match(src, "lock_bound_counter(repo, type, prefix, locked)")
      assert seq < counter
    end

    test "A9 every Repo call of the module family carries the prefix" do
      files = [
        "lib/letflow/number_sequences.ex" | Path.wildcard("lib/letflow/number_sequences/*.ex")
      ]

      for file <- files do
        lines = file |> File.read!() |> String.split("\n")

        for {line, no} <- Enum.with_index(lines, 1),
            line =~ ~r/\b(Repo|repo)\.(one|all|insert|update_all|exists\?|get)\(/ do
          # a multi-line call keeps its option in the following lines
          window = lines |> Enum.slice(no - 1, 10) |> Enum.join("\n")
          assert window =~ "prefix:", "#{file}:#{no} has no prefix: #{line}"
        end
      end
    end
  end
end
