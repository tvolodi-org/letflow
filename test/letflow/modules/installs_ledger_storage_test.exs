defmodule Letflow.Modules.InstallsLedgerStorageTest do
  @moduledoc """
  REQ-711 / GH #3751 (decision 0073 A6): module install and reactivate create the partitions of the
  module's ledger ids in the same transaction (IL-1..IL-10). Committed tenants, Sandbox `:auto`,
  hence `async: false`; the uninstall flag is VM-global.

  Criterion 5 reading (IL-9): `ledger.ex` has the text "Storage.ensure/2 makes it" in its
  moduledoc, so a plain text scan cannot pass; the scan walks the AST for the remote call instead.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias Letflow.Ledger
  alias Letflow.Ledger.Storage
  alias Letflow.LedgerFixture, as: Fx
  alias Letflow.Modules.Installs
  alias Letflow.Repo
  alias Letflow.TenantFixture

  @module "fixture_ledger_storage"
  @ids ["fixture_ledger_storage", "fixture_ledger_storage:b"]
  @parents ~w(ledger_entry ledger_leg ledger_balance)
  @why "test: REQ-711"

  setup do
    Fx.setup_auto_mode!()

    previous = Application.fetch_env(:letflow, :modules_uninstall_enabled)
    Application.put_env(:letflow, :modules_uninstall_enabled, true)
    Application.delete_env(:letflow, :fixture_ledger_storage_fail)

    on_exit(fn ->
      Application.delete_env(:letflow, :fixture_ledger_storage_fail)

      case previous do
        {:ok, value} -> Application.put_env(:letflow, :modules_uninstall_enabled, value)
        :error -> Application.delete_env(:letflow, :modules_uninstall_enabled)
      end
    end)

    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "r711", teardown: false)
    on_exit(fn -> Letflow.EntityWritesFixture.drop_committed_tenant!(tenant.tenant_id) end)
    %{schema: tenant.schema_name, tenant_id: tenant.tenant_id}
  end

  # -- helpers ---------------------------------------------------------------------------------------

  defp q!(sql, params \\ []), do: Repo.query!(sql, params)

  defp install(schema, id \\ @module),
    do: Installs.install(id, Ecto.UUID.generate(), prefix: schema, rationale: @why)

  defp opts(schema), do: [prefix: schema, rationale: @why]

  defp partition_rows(schema) do
    q!(
      "SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace " <>
        "WHERE n.nspname = $1 AND c.relispartition AND c.relkind = 'r' ORDER BY 1",
      [schema]
    ).rows
    |> List.flatten()
  end

  defp module_rows(schema),
    do: q!(~s|SELECT status FROM "#{schema}".tenant_modules WHERE module_id = $1|, [@module]).rows

  defp expected_partitions(ids) do
    ids |> Enum.flat_map(&Map.values(Storage.partition_names(&1))) |> Enum.sort()
  end

  # Statement texts run by this process while `fun` runs.
  defp record_queries(fun) do
    ref = make_ref()
    id = {__MODULE__, ref}
    test = self()

    :telemetry.attach(
      id,
      [:letflow, :repo, :query],
      fn _event, _measure, meta, _config -> send(test, {ref, meta.query}) end,
      nil
    )

    try do
      result = fun.()
      {result, drain(ref, [])}
    after
      :telemetry.detach(id)
    end
  end

  defp drain(ref, acc) do
    receive do
      {^ref, query} -> drain(ref, [query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp post(schema, ledger_id) do
    Fx.post!(
      Fx.capability(schema, "receipt", [Fx.leg(["item-1"], 5)],
        ledger_id: ledger_id,
        ensure_storage: false
      )
    )
  end

  # -- IL-1 ------------------------------------------------------------------------------------------

  test "IL-1 install creates the three partitions of each id; a posting to each commits", %{
    schema: schema
  } do
    assert partition_rows(schema) == []

    {{:ok, _}, queries} = record_queries(fn -> install(schema) end)

    assert partition_rows(schema) == expected_partitions(@ids)

    for id <- @ids do
      assert %{} = post(schema, id)
    end

    creates = for {q, i} <- Enum.with_index(queries), q =~ ~r/CREATE TABLE/, do: i
    insert_module = Enum.find_index(queries, &(&1 =~ "tenant_modules" and &1 =~ "INSERT"))
    assert is_integer(insert_module)
    assert creates != []
    assert insert_module < hd(creates)

    # ids are created ascending: one advisory lock per id, `fixture_ledger_storage` first
    assert Enum.count(queries, &(&1 =~ "pg_advisory_xact_lock")) == 2
  end

  # -- IL-2 .. IL-5 ----------------------------------------------------------------------------------

  test "IL-2 a failing on_install rolls the partitions back", %{schema: schema} do
    Application.put_env(:letflow, :fixture_ledger_storage_fail, true)

    assert {:error, {:on_install_failed, :boom}} = install(schema)
    assert partition_rows(schema) == []
    assert module_rows(schema) == []
  end

  test "IL-3 a half-made partition set is refused as :module_install_ddl_failed", %{
    schema: schema
  } do
    id = hd(@ids)

    Fx.exec!(
      ~s|CREATE TABLE "#{schema}".#{Storage.partition_names(id)["ledger_balance"]} (LIKE "#{schema}".ledger_balance INCLUDING ALL)|
    )

    before = partition_rows(schema)

    assert {:error, :module_install_ddl_failed} = install(schema)
    assert module_rows(schema) == []
    assert partition_rows(schema) == before
  end

  test "IL-4 a Postgrex error from the DDL is mapped, with the SQLSTATE and no relation name", %{
    schema: schema
  } do
    Fx.exec!(~s|DROP TABLE "#{schema}".ledger_entry CASCADE|)

    log =
      capture_log(fn ->
        assert {:error, :module_install_ddl_failed} = install(schema)
      end)

    assert module_rows(schema) == []
    # the debug query log names relations; the install's own error line carries the SQLSTATE only
    [line] = for l <- String.split(log, "\n"), l =~ "module install failed", do: l
    assert line =~ "sqlstate=undefined_table"
    refute line =~ "ledger_entry"
    refute line =~ schema
  end

  test "IL-5 a module without a :ledger key runs no statement on a ledger table", %{
    schema: schema
  } do
    {{:ok, _}, queries} = record_queries(fn -> install(schema, "fixture") end)
    refute Enum.any?(queries, &(&1 =~ "ledger_"))
  end

  # -- IL-6, IL-7 ------------------------------------------------------------------------------------

  test "IL-6 uninstall keeps the partitions and rows; reactivate runs no CREATE or ALTER", %{
    schema: schema
  } do
    assert {:ok, _} = install(schema)
    id = hd(@ids)
    post(schema, id)
    parts = partition_rows(schema)
    rows = Fx.count(schema, "ledger_entry")

    assert {:ok, _} = Installs.uninstall(@module, Ecto.UUID.generate(), opts(schema))
    assert partition_rows(schema) == parts
    assert Fx.count(schema, "ledger_entry") == rows

    {result, queries} =
      record_queries(fn -> Installs.reactivate(@module, Ecto.UUID.generate(), opts(schema)) end)

    assert {:ok, _} = result
    assert partition_rows(schema) == parts
    assert Fx.count(schema, "ledger_entry") == rows
    refute Enum.any?(queries, &(&1 =~ ~r/\b(CREATE|ALTER)\b/))
  end

  test "IL-7 reactivate refuses a damaged partition set; the module stays uninstalled", %{
    schema: schema
  } do
    assert {:ok, _} = install(schema)
    assert {:ok, _} = Installs.uninstall(@module, Ecto.UUID.generate(), opts(schema))

    id = hd(@ids)
    leg = Storage.partition_names(id)["ledger_leg"]
    Fx.exec!(~s|ALTER TABLE "#{schema}".ledger_leg DETACH PARTITION "#{schema}"."#{leg}"|)

    assert {:error, {:ledger_contract, :ledger_storage_inconsistent}} =
             Installs.reactivate(@module, Ecto.UUID.generate(), opts(schema))

    assert module_rows(schema) == [["uninstalled"]]
  end

  test "IL-7b reactivate refuses a partition whose foreign key was dropped", %{schema: schema} do
    assert {:ok, _} = install(schema)
    assert {:ok, _} = Installs.uninstall(@module, Ecto.UUID.generate(), opts(schema))

    id = hd(@ids)
    leg = Storage.partition_names(id)["ledger_leg"]
    h = String.replace_prefix(leg, "ledger_leg_p", "")

    Fx.exec!(~s|ALTER TABLE "#{schema}"."#{leg}" DROP CONSTRAINT "ledger_leg_entry_fk_#{h}"|)

    assert {:error, {:ledger_contract, :ledger_storage_inconsistent}} =
             Installs.reactivate(@module, Ecto.UUID.generate(), opts(schema))

    assert module_rows(schema) == [["uninstalled"]]
  end

  test "IL-11 the reactivate route answers the typed ddl-failed problem for a damaged partition set",
       %{
         schema: schema,
         tenant_id: tenant_id
       } do
    assert {:ok, _} = install(schema)
    assert {:ok, _} = Installs.uninstall(@module, Ecto.UUID.generate(), opts(schema))

    leg = Storage.partition_names(hd(@ids))["ledger_leg"]
    Fx.exec!(~s|ALTER TABLE "#{schema}".ledger_leg DETACH PARTITION "#{schema}"."#{leg}"|)

    conn =
      conn(:post, "/#{@module}/reactivate")
      |> Map.put(:body_params, %{"rationale" => @why})
      |> put_req_header("content-type", "application/json")
      |> assign(:auth_context, %{
        user_id: Ecto.UUID.generate(),
        tenant_id: tenant_id,
        roles: ["TENANT_ADMIN"]
      })
      |> assign(:trace_id, "il11-trace")
      |> Letflow.Routers.TenantModules.call(Letflow.Routers.TenantModules.init([]))

    assert conn.status == 422
    assert conn.resp_body =~ "module-install-ddl-failed"
    refute conn.resp_body =~ "ledger_storage_inconsistent"
    assert module_rows(schema) == [["uninstalled"]]
  end

  # -- IL-8 ------------------------------------------------------------------------------------------

  test "IL-8 ensure for a new ledger id holds no conflicting lock on the parents" do
    schema = Fx.tenant!()
    existing = Fx.post!(Fx.capability(schema, "receipt", [Fx.leg(["item-1"], 5)]))
    assert existing

    test = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          %{rows: [[pid]]} = q!("SELECT pg_backend_pid()")
          :ok = Storage.ensure(schema, "lock_new")
          send(test, {:open, pid})

          receive do
            :commit -> :ok
          after
            30_000 -> Repo.rollback(:timeout)
          end
        end)
      end)

    pid =
      receive do
        {:open, pid} -> pid
      after
        30_000 -> flunk("ensure did not return")
      end

    locks =
      q!(
        "SELECT c.relname, l.mode FROM pg_locks l JOIN pg_class c ON c.oid = l.relation " <>
          "JOIN pg_namespace n ON n.oid = c.relnamespace " <>
          "WHERE l.pid = $1 AND l.granted AND n.nspname = $2 AND c.relname = ANY($3) ORDER BY 1, 2",
        [pid, schema, @parents ++ ["ledger_counter"]]
      ).rows

    message = "pg_locks of the open ensure/2 transaction: " <> inspect(locks)

    for parent <- @parents do
      assert [parent, "ShareUpdateExclusiveLock"] in locks, message
      refute [parent, "ShareRowExclusiveLock"] in locks, message
      refute [parent, "AccessExclusiveLock"] in locks, message
    end

    refute ["ledger_counter", "AccessExclusiveLock"] in locks, message

    # while that transaction is open, a read and a posting of test_ledger succeed within 2 s
    assert {:ok, :read} =
             Repo.transaction(fn ->
               q!("SET LOCAL lock_timeout = '2s'")

               assert q!(
                        ~s|SELECT 1 FROM "#{schema}".ledger_balance WHERE ledger_id = 'test_ledger'|
                      ).rows != []

               assert q!(
                        ~s|SELECT 1 FROM "#{schema}".ledger_entry WHERE ledger_id = 'test_ledger'|
                      ).rows != []

               :read
             end)

    cap = Fx.capability(schema, "receipt", [Fx.leg(["item-2"], 3)])

    assert {:ok, _} =
             Repo.transaction(fn ->
               q!("SET LOCAL lock_timeout = '2s'")

               case Ledger.post(cap) do
                 {:ok, posted} -> posted
                 {:error, reason} -> Repo.rollback(reason)
               end
             end)

    send(holder.pid, :commit)
    assert {:ok, :ok} = Task.await(holder, 30_000)
    assert Storage.missing(schema, ["lock_new"]) == []
  end

  # -- IL-9, IL-10 -----------------------------------------------------------------------------------

  test "IL-9 only installs.ex calls Storage.ensure; the posting code never does" do
    callers =
      for file <- Path.wildcard("lib/**/*.ex"),
          file != "lib/letflow/ledger/storage.ex",
          calls_ensure?(File.read!(file)),
          do: file

    assert callers == ["lib/letflow/modules/installs.ex"]

    posting = ["lib/letflow/ledger.ex" | Path.wildcard("lib/letflow/ledger/*.ex")]
    refute Enum.any?(posting, &calls_ensure?(File.read!(&1)))
  end

  test "IL-10 the installer moduledoc states the creation" do
    assert File.read!("lib/letflow/modules/installs.ex") =~ "REQ-711"
  end

  defp calls_ensure?(source) do
    {:ok, ast} = Code.string_to_quoted(source)

    {_, found} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, parts}, :ensure]}, _, _args} = node, acc ->
          {node, acc or List.last(parts) == :Storage}

        node, acc ->
          {node, acc}
      end)

    found
  end
end
