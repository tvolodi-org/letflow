defmodule Letflow.NumberSequences.RecordsNumberingTest do
  @moduledoc """
  REQ-541 / GH #3160 criteria 3, 6, 8, 11, 12 (N1..N14): every create path of a bound type
  numbers, one counter is shared by the paths, a replay / unchanged / updated outcome allocates
  nothing, and a rolled-back create releases its number. Runs in Sandbox `:auto` mode.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Entities.Records
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.NumberSequences
  alias Letflow.NumberSequences.Counter
  alias Letflow.NumberSequences.Number
  alias Letflow.Repo
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Test.SandboxAutoMode

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    base = Fx.committed_tenant_case!("gh3160-rec")

    on_exit(fn ->
      Application.delete_env(:letflow, :number_sequences_clock)
      Fx.drop_committed_tenant!(base.tenant.tenant_id)
      SandboxAutoMode.exit_auto_mode!(Repo)
    end)

    Fx.define_type!(base.schema, "stock_move", %{append_only: false})
    Fx.define_type!(base.schema, "stock_free", %{append_only: false})
    Fx.define_type!(base.schema, "stock_note", %{})

    {:ok, _} =
      NumberSequences.create_definition(
        %{key: "move_no", entity_type: "stock_move", prefix: "MV", padding: 4, period: "none"},
        base.schema
      )

    %{base: base}
  end

  defp create(schema, type \\ "stock_move", extra \\ %{}) do
    Records.create_record(
      Map.merge(
        %{
          entity_type: type,
          field_values: %{"label" => "x"},
          actor_id: Ecto.UUID.generate(),
          idempotency_key: Fx.unique("k")
        },
        extra
      ),
      schema
    )
  end

  defp create!(schema, type \\ "stock_move") do
    {:ok, %{record: record}} = create(schema, type)
    record
  end

  defp counters(schema),
    do: Repo.all(from(c in Counter, select: {c.period, c.counter}), prefix: schema)

  defp number_rows(schema), do: Repo.all(Number, prefix: schema)

  # A process step writes only append-only types, which `create_definition/2` refuses (criterion 2),
  # so the engine-path tests bind `stock_note` by inserting the definition row directly.
  defp line, do: Fx.line("stock_note", %{"label" => %{"const" => "v"}})

  defp bind_note!(schema) do
    {:ok, tenant_id} = Letflow.TenantProvisioning.tenant_id_for_schema_name(schema)

    Repo.insert!(
      %NumberSequences.Definition{
        tenant_id: tenant_id,
        key: "note_no",
        entity_type: "stock_note",
        prefix: "NT",
        padding: 4,
        period: "none"
      },
      prefix: schema
    )
  end

  defp numbers_of(schema),
    do: schema |> Fx.records("stock_note") |> Enum.map(& &1.record_id) |> numbers(schema)

  defp numbers(ids, schema) do
    schema
    |> then(&NumberSequences.numbers_for("stock_note", ids, &1))
    |> Map.values()
    |> Enum.sort()
  end

  test "N1 create_record numbers 1; an unbound type is untouched", %{base: base} do
    assert create!(base.schema).record_number == "MV-0001"
    note = create!(base.schema, "stock_free")
    assert note.record_number == nil
    assert counters(base.schema) == [{"none", 1}]
    assert length(number_rows(base.schema)) == 1
  end

  test "N2 the number is not in field_values and no payload can set it", %{base: base} do
    record = create!(base.schema)
    assert record.field_values == %{"label" => "x"}

    for key <- ["record_number", "number"] do
      assert {:error, {:record_payload_invalid, _}} =
               Records.create_record(
                 %{
                   entity_type: "stock_move",
                   field_values: %{"label" => "y", key => "MV-9999"},
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: Fx.unique("k")
                 },
                 base.schema
               )

      assert {:error, {:record_payload_invalid, _}} =
               Records.update_record(
                 %{
                   entity_type: "stock_move",
                   record_id: record.record_id,
                   field_values: %{"label" => "y", key => "MV-9999"},
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: Fx.unique("k")
                 },
                 base.schema
               )
    end

    assert counters(base.schema) == [{"none", 1}]
    assert NumberSequences.number_for("stock_move", record.record_id, base.schema) == "MV-0001"
  end

  test "N3 the :created branch of the external-ref upsert numbers", %{base: base} do
    assert create!(base.schema).record_number == "MV-0001"

    attrs = %{
      entity_type: "stock_move",
      field_values: %{"label" => "ext"},
      actor_id: Ecto.UUID.generate(),
      idempotency_key: Fx.unique("k"),
      external_ref: %{"system" => "erp", "id" => "42"}
    }

    assert {:ok, %{outcome: :created, record: record}} =
             Records.upsert_record_by_external_ref(attrs, base.schema)

    assert record.record_number == "MV-0002"
  end

  test "N4 a HUMAN completion numbers its create line from the same counter", %{base: base} do
    bind_note!(base.schema)
    assert create!(base.schema, "stock_note").record_number == "NT-0001"
    ctx = Fx.attach!(base, [line()])
    assert {:ok, _} = Fx.complete(ctx, %{})

    assert numbers_of(base.schema) == ["NT-0001", "NT-0002"]
    assert counters(base.schema) == [{"none", 2}]
  end

  test "N4b a service apply numbers its create line; the counter row is locked before any audit",
       %{base: base} do
    bind_note!(base.schema)
    ctx = Fx.attach_service!(base, Fx.service_graph([line()]))

    {result, queries} =
      PlatformTenantFixture.capture_repo_queries(fn -> Fx.apply_http(ctx, %{"label" => "x"}) end)

    assert {:ok, :advanced} = result
    assert numbers_of(base.schema) == ["NT-0001"]

    index = fn pred -> Enum.find_index(queries, pred) end
    counter_lock = index.(&(&1.query =~ "number_sequence_counters" and &1.query =~ "FOR UPDATE"))
    first_audit = index.(&(&1.query =~ "audit_chain_locks"))

    assert is_integer(counter_lock), "no counter row lock in the statement log"
    assert is_integer(first_audit), "no audit chain statement in the statement log"
    assert counter_lock < first_audit
  end

  test "N5 direct, upsert :created and engine line share one counter", %{base: base} do
    bind_note!(base.schema)
    assert create!(base.schema, "stock_note").record_number == "NT-0001"

    {:ok, %{record: upserted}} =
      Records.upsert_record_by_external_ref(
        %{
          entity_type: "stock_note",
          field_values: %{"label" => "e"},
          actor_id: Ecto.UUID.generate(),
          idempotency_key: Fx.unique("k"),
          external_ref: %{"system" => "erp", "id" => "n5"}
        },
        base.schema
      )

    ctx = Fx.attach!(base, [line()])
    assert {:ok, _} = Fx.complete(ctx, %{})
    assert upserted.record_number == "NT-0002"
    assert numbers_of(base.schema) == ["NT-0001", "NT-0002", "NT-0003"]
  end

  test "N6 twenty concurrent creates get exactly 1..20", %{base: base} do
    results =
      1..20
      |> Task.async_stream(fn _ -> create(base.schema) end,
        max_concurrency: 20,
        timeout: 60_000,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, %{record: _}}, &1)), inspect(results)

    numbers = for {:ok, %{record: r}} <- results, do: r.record_number
    expected = for n <- 1..20, do: "MV-" <> String.pad_leading(Integer.to_string(n), 4, "0")
    assert Enum.sort(numbers) == Enum.sort(expected)
    assert counters(base.schema) == [{"none", 20}]
  end

  test "N7 a rolled-back create releases its number", %{base: base} do
    # the create runs inside an outer transaction that is rolled back after the allocation, so the
    # counter increment and the log row go with it (the same rollback a failed later step causes)
    assert create!(base.schema).record_number == "MV-0001"
    before = counters(base.schema)

    {:error, _} =
      Repo.transaction(fn ->
        {:ok, _} = create(base.schema)
        Repo.rollback(:forced)
      end)

    assert counters(base.schema) == before
    assert create!(base.schema).record_number == "MV-0002"
  end

  test "N8 a deleted record keeps its number, which is never reused", %{base: base} do
    record = create!(base.schema)

    assert {:ok, _} =
             Records.delete_record(
               %{
                 entity_type: "stock_move",
                 record_id: record.record_id,
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: Fx.unique("k")
               },
               base.schema
             )

    assert NumberSequences.number_for("stock_move", record.record_id, base.schema) == "MV-0001"
    assert create!(base.schema).record_number == "MV-0002"
  end

  test "N9 an idempotent replay allocates nothing and shows the original number", %{base: base} do
    key = Fx.unique("k")
    attrs = %{idempotency_key: key}
    assert {:ok, %{record: first, is_duplicate: false}} = create(base.schema, "stock_move", attrs)
    before = counters(base.schema)

    assert {:ok, %{record: replay, is_duplicate: true}} =
             create(base.schema, "stock_move", %{
               idempotency_key: key,
               actor_id: first_actor(base.schema, first)
             })

    assert replay.record_id == first.record_id
    assert replay.record_number == first.record_number
    assert counters(base.schema) == before
    assert length(number_rows(base.schema)) == 1
  end

  defp first_actor(schema, record) do
    Fx.entity_events(schema)
    |> Enum.find(&(&1.payload["record_id"] == record.record_id))
    |> Map.fetch!(:actor_id)
  end

  test "N10/N11 external-ref :unchanged and :updated leave number and counter", %{base: base} do
    attrs = fn values ->
      %{
        entity_type: "stock_move",
        field_values: values,
        actor_id: Ecto.UUID.generate(),
        idempotency_key: Fx.unique("k"),
        external_ref: %{"system" => "erp", "id" => "n10"}
      }
    end

    assert {:ok, %{outcome: :created, record: created}} =
             Records.upsert_record_by_external_ref(attrs.(%{"label" => "a"}), base.schema)

    before = counters(base.schema)

    assert {:ok, %{outcome: :unchanged}} =
             Records.upsert_record_by_external_ref(attrs.(%{"label" => "a"}), base.schema)

    assert counters(base.schema) == before

    assert {:ok, %{outcome: :updated}} =
             Records.upsert_record_by_external_ref(attrs.(%{"label" => "b"}), base.schema)

    assert counters(base.schema) == before
    assert created.record_number == "MV-0001"
    assert NumberSequences.number_for("stock_move", created.record_id, base.schema) == "MV-0001"
    assert length(number_rows(base.schema)) == 1
  end

  test "N13 a top-level :record_number attr is ignored and a same-named field is separate",
       %{base: base} do
    {:ok, %{record: record}} = create(base.schema, "stock_move", %{record_number: "MV-9999"})
    assert record.record_number == "MV-0001"
    assert NumberSequences.number_for("stock_move", record.record_id, base.schema) == "MV-0001"

    Fx.define_type!(base.schema, "ns_rn", %{
      append_only: false,
      fields: [
        %{name: "label", type: :string, required: true},
        %{name: "record_number", type: :string}
      ]
    })

    {:ok, _} =
      NumberSequences.create_definition(
        %{key: "rn_no", entity_type: "ns_rn", prefix: "RN", padding: 3, period: "none"},
        base.schema
      )

    {:ok, %{record: rn}} =
      Records.create_record(
        %{
          entity_type: "ns_rn",
          field_values: %{"label" => "x", "record_number" => "mine"},
          actor_id: Ecto.UUID.generate(),
          idempotency_key: Fx.unique("k")
        },
        base.schema
      )

    assert rn.field_values["record_number"] == "mine"
    assert rn.record_number == "RN-001"

    {:ok, _} =
      Records.update_record(
        %{
          entity_type: "ns_rn",
          record_id: rn.record_id,
          field_values: %{"label" => "x", "record_number" => "changed"},
          actor_id: Ecto.UUID.generate(),
          idempotency_key: Fx.unique("k")
        },
        base.schema
      )

    assert NumberSequences.number_for("ns_rn", rn.record_id, base.schema) == "RN-001"
  end

  test "N14 the allocation uses the period the lock step took, across 31 December",
       %{base: base} do
    Fx.define_type!(base.schema, "ns_year", %{append_only: false})

    {:ok, _} =
      NumberSequences.create_definition(
        %{key: "yr_no", entity_type: "ns_year", prefix: "YR", padding: 3, period: "year"},
        base.schema
      )

    reads = :counters.new(1, [])

    Application.put_env(:letflow, :number_sequences_clock, fn ->
      :counters.add(reads, 1, 1)

      if :counters.get(reads, 1) == 1,
        do: ~U[2026-12-31 23:59:59Z],
        else: ~U[2027-01-01 00:00:00Z]
    end)

    # the pre-lock step of a real engine path computes the period once and passes it on
    {:ok, {:locked, %{period: locked, definition_id: id}}} =
      Repo.transaction(fn ->
        {:ok, result} = NumberSequences.lock_counter(Repo, "ns_year", base.schema)
        result
      end)

    assert locked == "2026"

    {:ok, definition} = NumberSequences.fetch_binding("ns_year", base.schema)
    assert definition.id == id

    {:ok, allocation} =
      Repo.transaction(fn ->
        {:ok, a} =
          NumberSequences.allocate(Repo, definition, "ns_year", Ecto.UUID.generate(), base.schema,
            period: locked
          )

        a
      end)

    assert allocation.formatted == "YR-2026-001"

    periods =
      Repo.all(from(c in Counter, where: c.sequence_id == ^id, select: c.period),
        prefix: base.schema
      )

    assert periods == ["2026"]
  end
end
