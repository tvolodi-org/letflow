defmodule Letflow.Ledger.StorageTest do
  @moduledoc """
  REQ-710 criteria 4 and 5: `Letflow.Ledger.Storage` (ST-1..ST-7) and the typed refusal of a
  posting to a ledger id without partitions (ST-8). Committed tenants, Sandbox `:auto`, hence
  `async: false`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Ledger
  alias Letflow.Ledger.Storage
  alias Letflow.LedgerFixture, as: Fx
  alias Letflow.Repo

  @parents ~w(ledger_entry ledger_leg ledger_balance)

  setup do
    Fx.setup_auto_mode!()
    %{schema: Fx.tenant!()}
  end

  defp ensure(schema, id), do: Repo.transaction(fn -> Storage.ensure(schema, id) end)

  defp q!(sql, params), do: Repo.query!(sql, params)

  defp partitions(schema) do
    q!(
      "SELECT c.relname, p.relname, pg_get_expr(c.relpartbound, c.oid) FROM pg_class c " <>
        "JOIN pg_inherits i ON i.inhrelid = c.oid JOIN pg_class p ON p.oid = i.inhparent " <>
        "JOIN pg_namespace n ON n.oid = c.relnamespace " <>
        "WHERE n.nspname = $1 AND c.relispartition AND c.relkind = 'r' ORDER BY 1",
      [schema]
    ).rows
  end

  test "ST-1 ensure creates three attached partitions with renamed indexes and ALWAYS triggers",
       %{schema: schema} do
    assert {:ok, :ok} = ensure(schema, "stock:main-1")
    assert {:ok, :ok} = ensure(schema, "other_ledger")

    names = Storage.partition_names("stock:main-1")
    h = names["ledger_entry"] |> String.split("_p") |> List.last()

    parts = partitions(schema)

    for parent <- @parents do
      assert [names[parent], parent, "FOR VALUES IN ('stock:main-1')"] in parts
    end

    # every index of every partition ends in its ledger id hash
    %{rows: idx} =
      q!(
        "SELECT ci.relname FROM pg_index x JOIN pg_class ci ON ci.oid = x.indexrelid " <>
          "JOIN pg_class ct ON ct.oid = x.indrelid WHERE ct.relname = ANY($1) AND ct.relnamespace = " <>
          "(SELECT oid FROM pg_namespace WHERE nspname = $2)",
        [Map.values(names), schema]
      )

    assert length(idx) >= 3
    assert Enum.all?(idx, fn [name] -> String.ends_with?(name, "_" <> h) end)

    %{rows: trg} =
      q!(
        "SELECT t.tgname, t.tgenabled::text FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid " <>
          "WHERE NOT t.tgisinternal AND c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = $2) " <>
          "AND c.relname = ANY($1)",
        [Map.values(names), schema]
      )

    assert trg != []
    assert Enum.all?(trg, fn [_, enabled] -> enabled == "A" end)
    assert ["ledger_entry_guard_truncate", "A"] in trg
    assert ["ledger_leg_guard_truncate", "A"] in trg
    assert ["ledger_balance_guard_truncate", "A"] in trg
  end

  test "ST-2 TRUNCATE on a partition is refused", %{schema: schema} do
    assert {:ok, :ok} = ensure(schema, "stock:main-1")
    names = Storage.partition_names("stock:main-1")

    for parent <- @parents do
      assert {:error,
              %Postgrex.Error{
                postgres: %{
                  code: :restrict_violation,
                  message: "ledger data is append-only: this statement is refused"
                }
              }} = Repo.query(~s|TRUNCATE "#{schema}"."#{names[parent]}" CASCADE|)
    end

    # an entry partition is also protected by the leg foreign key, without CASCADE
    assert {:error, %Postgrex.Error{postgres: %{code: :feature_not_supported}}} =
             Repo.query(~s|TRUNCATE "#{schema}"."#{names["ledger_entry"]}"|)
  end

  test "ST-3 a second ensure runs no CREATE or ALTER", %{schema: schema} do
    assert {:ok, :ok} = ensure(schema, "stock:main-1")

    {result, statements} = Fx.record(fn -> ensure(schema, "stock:main-1") end)
    assert result == {:ok, :ok}
    refute Enum.any?(statements, fn {sql, _} -> sql =~ ~r/\b(CREATE|ALTER|DROP)\b/i end)
  end

  test "ST-4 invalid input is refused before any statement; an inconsistent state creates nothing",
       %{schema: schema} do
    for prefix <- [
          "public",
          "tenant_" <> String.upcase(String.duplicate("a", 32)),
          "tenant_" <> String.duplicate("a", 31),
          schema <> "; DROP",
          nil
        ] do
      {result, statements} = Fx.record(fn -> ensure(prefix, "ok_ledger") end)
      assert result == {:ok, {:error, {:ledger_contract, :invalid_prefix}}}

      assert statements |> Enum.reject(fn {sql, _} -> sql =~ ~r/^(begin|commit|rollback)/i end) ==
               []
    end

    for id <- ["Ab", "a;b", String.duplicate("a", 65), "", "a:b:c", nil, 7] do
      {result, statements} = Fx.record(fn -> ensure(schema, id) end)
      assert result == {:ok, {:error, {:ledger_contract, :invalid_ledger_id}}}

      assert statements |> Enum.reject(fn {sql, _} -> sql =~ ~r/^(begin|commit|rollback)/i end) ==
               []
    end

    assert_raise ArgumentError, ~r/open transaction/, fn ->
      Storage.ensure(schema, "ok_ledger")
    end

    # (i) only the entry partition exists
    names = Storage.partition_names("half")

    Repo.query!(
      ~s|CREATE TABLE "#{schema}"."#{names["ledger_entry"]}" (LIKE "#{schema}".ledger_entry INCLUDING ALL)|
    )

    Repo.query!(
      ~s|ALTER TABLE "#{schema}".ledger_entry ATTACH PARTITION "#{schema}"."#{names["ledger_entry"]}" FOR VALUES IN ('half')|
    )

    assert {:ok, {:error, {:ledger_contract, :ledger_storage_inconsistent}}} =
             ensure(schema, "half")

    refute Enum.any?(partitions(schema), fn [name | _] -> name == names["ledger_leg"] end)

    # (ii) a plain table of the leg partition's name exists, not attached
    names2 = Storage.partition_names("loose")
    Repo.query!(~s|CREATE TABLE "#{schema}"."#{names2["ledger_leg"]}" (x int)|)

    assert {:ok, {:error, {:ledger_contract, :ledger_storage_inconsistent}}} =
             ensure(schema, "loose")

    refute Enum.any?(partitions(schema), fn [name | _] -> name == names2["ledger_entry"] end)
  end

  test "ST-5 partition names are deterministic, 16 hex, and hide the ledger id" do
    a = Storage.partition_names("stock:main-1")
    assert a == Storage.partition_names("stock:main-1")
    refute a == Storage.partition_names("stock_main-1")

    for {parent, name} <- a do
      assert name =~ ~r/\A#{parent}_p[0-9a-f]{16}\z/
      refute name =~ "stock"
      assert byte_size(name) <= 63
    end

    assert Map.keys(a) |> Enum.sort() == Enum.sort(@parents)
  end

  test "ST-6 ensure for one tenant creates nothing in another", %{schema: a} do
    b = Fx.tenant!()
    assert {:ok, :ok} = ensure(a, "only_in_a")
    assert partitions(b) |> Enum.reject(fn [_, _, bound] -> bound =~ "'test_ledger'" end) == []
    assert Enum.any?(partitions(a), fn [_, _, bound] -> bound =~ "'only_in_a'" end)
  end

  test "ST-7 two concurrent ensures of one new ledger id both succeed with one partition set",
       %{schema: schema} do
    tasks = for _ <- 1..2, do: Task.async(fn -> ensure(schema, "racing_ledger") end)
    assert [{:ok, :ok}, {:ok, :ok}] = Task.await_many(tasks, 30_000)

    assert partitions(schema)
           |> Enum.filter(fn [_, _, bound] -> bound =~ "'racing_ledger'" end)
           |> length() == 3
  end

  test "ST-8 a posting to a ledger id without partitions is refused before any write",
       %{schema: schema} do
    cap =
      Fx.capability(schema, "receipt", [Fx.leg(["a"], 5)],
        ledger_id: "no_partitions",
        ensure_storage: false
      )

    {result, statements} =
      Fx.record(fn ->
        Repo.transaction(fn ->
          reply = Ledger.post(cap)
          assert %{rows: [[1]]} = Repo.query!("SELECT 1")
          reply
        end)
      end)

    assert {:ok, {:error, {:ledger_contract, :ledger_storage_missing}}} = result

    refute Enum.any?(statements, fn {sql, _} ->
             sql =~ ~r/\b(INSERT|UPDATE|DELETE)\b/i
           end)

    for t <- ~w(ledger_counter ledger_entry ledger_leg ledger_balance) do
      assert Fx.count(schema, t) == 0, t
    end

    # a plan of two postings with one id missing: the same refusal, nothing written
    two_a = plan_cap(schema, "has_partitions", true)
    two_b = plan_cap(schema, "no_partitions_2", false)

    assert {:error, {:ledger_contract, :ledger_storage_missing}} =
             Repo.transaction(fn -> Ledger.lock_postings([two_a, two_b]) end) |> unwrap()

    for t <- ~w(ledger_counter ledger_entry ledger_leg ledger_balance) do
      assert Fx.count(schema, t) == 0, t
    end
  end

  defp unwrap({:ok, reply}), do: reply

  defp plan_cap(schema, ledger_id, ensure?) do
    Fx.capability(schema, "receipt", [Fx.leg(["a"], 1)],
      ledger_id: ledger_id,
      ensure_storage: ensure?,
      posting: %{document_type: "doc", document_id: "d-1"}
    )
  end
end
