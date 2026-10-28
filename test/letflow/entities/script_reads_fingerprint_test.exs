defmodule Letflow.Entities.ScriptReadsFingerprintTest do
  @moduledoc """
  REQ-601 / GH #3380 criteria 2-4 (decision 0065 D2, slice E-2 part A):
  `Letflow.Entities.ScriptReads.prefetch_with_fingerprint/3`.

  Queries are captured with Ecto telemetry scoped to the test pid. The capture also holds the
  transaction control statements (`begin`, `commit`, `SET TRANSACTION`), so "no write" is
  checked by the absence of INSERT/UPDATE/DELETE statements, not by "SELECT only".

  `async: false`: provisioning switches the sandbox to `:auto`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Entities.Records
  alias Letflow.Entities.ScriptReads
  alias Letflow.EventStore.InstanceSequence
  alias Letflow.Support.PlatformTenantFixture, as: QueryCapture
  alias Letflow.Support.ScriptPolicyFixture, as: SP
  alias Letflow.Support.ScriptTaskFixture, as: F

  # Sorted byte order is "customer" < "member"; the reads name them the other way round.
  @a "customer"
  @b "member"

  setup do
    t = F.tenant!("req601-fp")
    assert {:ok, _} = Letflow.Entities.EventTypes.seed!(t.schema_name)

    for type <- [@a, @b] do
      SP.active_definition!(t.schema_name, type)
      SP.flag!(t.schema_name, type)
    end

    %{schema: t.schema_name}
  end

  defp record!(schema, type, values \\ %{"name" => "Ann", "tier" => "gold"}) do
    assert {:ok, %{record: record}} =
             Records.create_record(
               %{
                 entity_type: type,
                 field_values: values,
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: Ecto.UUID.generate()
               },
               schema
             )

    record.record_id
  end

  defp read(name, type, fields \\ ["name"]), do: SP.id_read(name, type, fields)

  defp counter(schema, type) do
    Repo.one(
      from(i in "entity_type_instances",
        join: s in InstanceSequence,
        on: s.instance_id == i.instance_id,
        where: i.entity_type == ^type,
        select: s.next_seq
      ),
      prefix: schema
    )
  end

  defp sql(metadata), do: Map.get(metadata, :query) || ""
  defp sequence_query?(m), do: sql(m) =~ "instance_sequence"
  defp record_query?(m), do: sql(m) =~ ~r/"entity_(record_latest|customer|member)"/

  defp count(schema, table),
    do: Repo.aggregate(from(r in table), :count, prefix: schema)

  describe "criterion 2: read order" do
    test "C-O1 counters before rows, types in ascending byte order", %{schema: schema} do
      a_id = record!(schema, @a)
      b_id = record!(schema, @b)
      reads = [read("rb", @b) |> Map.put("match", %{"id_from" => "bid"}), read("ra", @a)]
      vars = %{"cid" => a_id, "bid" => b_id}

      {result, queries} =
        QueryCapture.capture_repo_queries(fn ->
          ScriptReads.prefetch_with_fingerprint(schema, reads, vars)
        end)

      assert {:ok, %{"ra" => [_], "rb" => [_]}, %{@a => _, @b => _}} = result

      seq_idx = for {m, i} <- Enum.with_index(queries), sequence_query?(m), do: i
      first_record = Enum.find_index(queries, &record_query?/1)

      assert length(seq_idx) == 2
      assert is_integer(first_record)
      assert Enum.all?(seq_idx, &(&1 < first_record))

      # the registry lookups (bound to the type name) happen in ascending type order
      registry_types =
        queries
        |> Enum.filter(&(sql(&1) =~ "entity_type_instances"))
        |> Enum.flat_map(&(Map.get(&1, :params) || []))
        |> Enum.filter(&(&1 in [@a, @b]))

      assert registry_types == [@a, @b]
    end

    test "C-O2 a commit after the counter read leaves the fingerprint stale, never ahead",
         %{schema: schema} do
      cid = record!(schema, @a)
      before = counter(schema, @a)
      ref = make_ref()
      test_pid = self()
      handler_id = {__MODULE__, ref}

      :telemetry.attach(
        handler_id,
        [:letflow, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == test_pid and sequence_query?(metadata) and
               Process.get(:injected) == nil do
            Process.put(:injected, true)
            Task.await(Task.async(fn -> record!(schema, @a) end))
          end

          :ok
        end,
        nil
      )

      result =
        try do
          ScriptReads.prefetch_with_fingerprint(schema, [read("r", @a)], %{"cid" => cid})
        after
          :telemetry.detach(handler_id)
        end

      assert Process.get(:injected)
      assert {:ok, %{"r" => [_]}, %{@a => fingerprint}} = result
      assert fingerprint == before
      assert counter(schema, @a) > fingerprint
    end
  end

  describe "criterion 3: fingerprint values" do
    test "C-F1 the fingerprint is the sequence row's next_seq", %{schema: schema} do
      cid = record!(schema, @a)

      assert {:ok, _rows, %{@a => n}} =
               ScriptReads.prefetch_with_fingerprint(schema, [read("r", @a)], %{"cid" => cid})

      assert n == counter(schema, @a)
    end

    test "C-F2 a type with no registry row gets the default and nothing is inserted",
         %{schema: schema} do
      before = {count(schema, "entity_type_instances"), count(schema, "instance_sequence")}

      assert {:ok, %{"r" => []}, %{@b => n}} =
               ScriptReads.prefetch_with_fingerprint(schema, [read("r", @b)], %{"cid" => "x"})

      assert n == %InstanceSequence{}.next_seq

      assert {count(schema, "entity_type_instances"), count(schema, "instance_sequence")} ==
               before
    end

    test "C-F3 a registry row without a sequence row gets the default, no insert",
         %{schema: schema} do
      record!(schema, @a)
      Repo.delete_all(from(s in InstanceSequence), prefix: schema)
      before = {count(schema, "entity_type_instances"), count(schema, "instance_sequence")}

      assert {:ok, _rows, %{@a => n}} =
               ScriptReads.prefetch_with_fingerprint(schema, [read("r", @a)], %{"cid" => "x"})

      assert n == %InstanceSequence{}.next_seq

      assert {count(schema, "entity_type_instances"), count(schema, "instance_sequence")} ==
               before
    end

    test "C-F4 a committed create moves the next fingerprint", %{schema: schema} do
      cid = record!(schema, @a)
      reads = [read("r", @a)]

      assert {:ok, _, %{@a => first}} =
               ScriptReads.prefetch_with_fingerprint(schema, reads, %{"cid" => cid})

      record!(schema, @a)

      assert {:ok, _, %{@a => second}} =
               ScriptReads.prefetch_with_fingerprint(schema, reads, %{"cid" => cid})

      assert second > first
    end

    test "C-F5 a type named twice appears once and its counter is read once", %{schema: schema} do
      cid = record!(schema, @a)
      reads = [read("r1", @a), read("r2", @a, ["name", "tier"])]

      {result, queries} =
        QueryCapture.capture_repo_queries(fn ->
          ScriptReads.prefetch_with_fingerprint(schema, reads, %{"cid" => cid})
        end)

      assert {:ok, %{"r1" => [_], "r2" => [_]}, fingerprint} = result
      assert Map.keys(fingerprint) == [@a]
      assert Enum.count(queries, &sequence_query?/1) == 1
    end

    test "C-T1 the caller is not in a transaction after any exit", %{schema: schema} do
      cid = record!(schema, @a)
      refute Repo.in_transaction?()

      assert {:ok, _, _} =
               ScriptReads.prefetch_with_fingerprint(schema, [read("r", @a)], %{"cid" => cid})

      refute Repo.in_transaction?()

      assert {:error, :reads_not_allowed} =
               ScriptReads.prefetch_with_fingerprint(schema, [read("r", "nope")], %{})

      refute Repo.in_transaction?()

      # a data exception raised by the record query (a stored value the cast cannot read)
      assert {:ok, _, _} =
               ScriptReads.prefetch_with_fingerprint(schema, [], %{})

      refute Repo.in_transaction?()
    end

    test "C-T2 the call issues no INSERT, UPDATE or DELETE", %{schema: schema} do
      cid = record!(schema, @a)

      {result, queries} =
        QueryCapture.capture_repo_queries(fn ->
          ScriptReads.prefetch_with_fingerprint(schema, [read("r", @a)], %{"cid" => cid})
        end)

      assert {:ok, _, _} = result
      assert Enum.any?(queries, &(sql(&1) =~ ~r/\bselect\b/i))
      refute Enum.any?(queries, &(sql(&1) =~ ~r/\A\s*(insert|update|delete)\b/i))
    end
  end

  describe "criterion 4: same refusals and rows as prefetch/3" do
    defp both(schema, reads, vars) do
      {ScriptReads.prefetch(schema, reads, vars),
       ScriptReads.prefetch_with_fingerprint(schema, reads, vars)}
    end

    test "C-R1 an unflagged type", %{schema: schema} do
      Repo.delete_all(from(m in "script_readable_masters", where: m.entity_type == ^@a),
        prefix: schema
      )

      assert {{:error, :reads_not_allowed}, {:error, :reads_not_allowed}} =
               both(schema, [read("r", @a)], %{"cid" => "x"})
    end

    test "C-R2 a type without an active definition", %{schema: schema} do
      assert {{:error, :reads_not_allowed}, {:error, :reads_not_allowed}} =
               both(schema, [read("r", "ghost")], %{})
    end

    test "C-R3 a restricted type", %{schema: schema} do
      SP.restrict_type!(schema, @a)

      assert {{:error, :reads_not_allowed}, {:error, :reads_not_allowed}} =
               both(schema, [read("r", @a)], %{"cid" => "x"})
    end

    test "C-R4 an unknown field", %{schema: schema} do
      assert {{:error, :reads_not_allowed}, {:error, :reads_not_allowed}} =
               both(schema, [read("r", @a, ["nope"])], %{"cid" => "x"})
    end

    test "C-R5 a match on a restricted field", %{schema: schema} do
      SP.restrict_field!(schema, @a, "tier")
      tier_read = SP.field_read("r", @a, "tier", %{})

      assert {{:error, :reads_not_allowed}, {:error, :reads_not_allowed}} =
               both(schema, [tier_read], %{"tier" => "gold"})
    end

    test "C-R6 rows equal prefetch/3 on the same data", %{schema: schema} do
      cid = record!(schema, @a)
      record!(schema, @a)

      reads = [
        read("by_id", @a, ["name", "tier"]),
        SP.field_read("by_tier", @a, "tier", %{"fields" => ["name", "tier"]})
      ]

      assert {{:ok, rows}, {:ok, rows2, _fingerprint}} =
               both(schema, reads, %{"cid" => cid, "tier" => "gold"})

      assert rows == rows2
      assert [_, _] = rows2["by_tier"]
    end

    test "C-R7 a restricted field is omitted unless named in restricted_fields",
         %{schema: schema} do
      cid = record!(schema, @a, %{"name" => "Ann", "ssn" => "111"})
      SP.restrict_field!(schema, @a, "ssn")
      vars = %{"cid" => cid}

      assert {:ok, %{"r" => [omitted]}, _} =
               ScriptReads.prefetch_with_fingerprint(
                 schema,
                 [read("r", @a, ["name", "ssn"])],
                 vars
               )

      refute Map.has_key?(omitted, "ssn")

      declared = Map.put(read("r", @a, ["name", "ssn"]), "restricted_fields", ["ssn"])

      assert {:ok, %{"r" => [%{"ssn" => "111"}]}, _} =
               ScriptReads.prefetch_with_fingerprint(schema, [declared], vars)
    end

    test "C-R8 bad arguments are refused and empty reads give empty results", %{schema: schema} do
      assert ScriptReads.prefetch_with_fingerprint(schema, :nope, %{}) ==
               {:error, :reads_not_allowed}

      assert ScriptReads.prefetch_with_fingerprint(schema, [], :nope) ==
               {:error, :reads_not_allowed}

      assert ScriptReads.prefetch_with_fingerprint(schema, [], %{}) == {:ok, %{}, %{}}
    end
  end
end
