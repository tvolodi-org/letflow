defmodule Letflow.Entities.RecordsWriteHookTenantTest do
  @moduledoc """
  REQ-607 / GH #3413 part B, criterion C9 (INV-1, INV-7, INV-10): the pre-write hook never crosses
  a tenant. Tenants A and B each have the type `customer`, only A binds a script; A's script key
  pinned with B's prefix is the single `script_rejected`; B's token naming a type bound only in A
  gets the answer of a type that exists in no tenant on every record route that reaches the hooked
  write (create, update, import, import with `upsert_by`); every `Repo` call of
  `Letflow.Entities.WriteHook` passes `prefix:`.

  `async: false`: provisioning switches the sandbox to `:auto` and the stub runner is application env.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Records
  alias Letflow.EntityTypeHooks, as: Hooks
  alias Letflow.EntityTypeHooks.Binding
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceSequence
  alias Letflow.Support.ScopeWritesFixture, as: W
  alias Letflow.Support.ScriptPolicyFixture, as: P
  alias Letflow.Support.ScriptTaskFixture, as: F
  alias Letflow.Support.WriteHookProbe, as: Probe

  @actor "00000000-0000-4000-8000-0000000000a1"

  defmodule StubRunner do
    @moduledoc false
    def start, do: Agent.start_link(fn -> 0 end, name: __MODULE__)

    def stop do
      Agent.stop(__MODULE__)
    catch
      :exit, _already_gone -> :ok
    end

    def calls, do: Agent.get(__MODULE__, & &1)

    def run(source, input, opts) do
      Agent.update(__MODULE__, &(&1 + 1))
      Letflow.Engine.Lua.ScriptRunner.run(source, input, opts)
    end
  end

  setup do
    _ = StubRunner.start()
    on_exit(&StubRunner.stop/0)
    previous = Application.fetch_env(:letflow, :entity_write_script_runner)
    Application.put_env(:letflow, :entity_write_script_runner, StubRunner)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:letflow, :entity_write_script_runner, old)
        :error -> Application.delete_env(:letflow, :entity_write_script_runner)
      end
    end)

    :ok
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp manifest do
    %{
      "input_schema" => %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}}
      },
      "output_schema" => %{
        "type" => "object",
        "properties" => %{"total" => %{"type" => "string"}},
        "additionalProperties" => false
      },
      "derived_fields" => ["total"],
      "fail_codes" => [],
      "limits" => %{"timeout_ms" => 5_000}
    }
  end

  defp publish!(schema, key) do
    F.published!(schema, key, ~s|return { total = "T:" .. ctx.input.name }|, manifest(),
      hook_kind: "entity_write"
    )
  end

  defp pin(rule),
    do: %{
      "script_key" => rule.key,
      "script_version" => rule.version,
      "script_sha256" => rule.sha256
    }

  defp tenant_with_customer!(prefix, type \\ "customer") do
    tenant = F.tenant!(prefix)
    schema = tenant.schema_name
    assert {:ok, _} = EventTypes.seed!(schema)
    P.active_definition!(schema, type, ["name", "total"])
    tenant
  end

  defp create(schema, type, values),
    do:
      Records.create_record(
        %{
          actor_id: @actor,
          idempotency_key: Ecto.UUID.generate(),
          entity_type: type,
          field_values: values
        },
        schema
      )

  defp event_count(schema), do: Repo.aggregate(Event, :count, prefix: schema)

  defp sequences(schema),
    do: Repo.all(from(s in InstanceSequence, order_by: s.instance_id), prefix: schema)

  # ── function level ─────────────────────────────────────────────────────────

  describe "C9 function level" do
    test "C9-own-tenant A runs the script, B runs none and touches only its own rows" do
      a = tenant_with_customer!("e3da")
      b = tenant_with_customer!("e3db")
      rule = publish!(a.schema_name, "derive")
      assert {:ok, _} = Hooks.bind(a.schema_name, "customer", pin(rule), P.actor())

      {result_a, _events_a} =
        Probe.capture_all(fn -> create(a.schema_name, "customer", %{"name" => "Ann"}) end)

      assert {:ok, %{record: %{field_values: %{"total" => "T:Ann"}}}} = result_a
      assert StubRunner.calls() == 1

      a_sequences = sequences(a.schema_name)

      {result_b, events_b} =
        Probe.capture_all(fn -> create(b.schema_name, "customer", %{"name" => "Bea"}) end)

      assert {:ok, %{record: %{field_values: values_b}}} = result_b
      assert values_b == %{"name" => "Bea"}
      assert StubRunner.calls() == 1

      mine = Probe.by_pid(events_b, self())
      {:ok, dumped_a} = Ecto.UUID.dump(a.tenant_id)

      for e <- mine, is_binary(e.query) do
        refute e.query =~ a.schema_name
        refute a.tenant_id in e.params
        refute dumped_a in e.params
      end

      assert Enum.any?(mine, &(is_binary(&1.query) and &1.query =~ b.schema_name))

      # B's lock row is B's own `customer` instance, which is not A's
      {:ok, b_id} = EntityTypeInstance.get_or_create("customer", b.schema_name)
      {:ok, a_id} = EntityTypeInstance.get_or_create("customer", a.schema_name)
      assert Probe.lock_ids(Probe.locks(mine)) |> Enum.uniq() == [b_id]
      refute a_id == b_id

      # A's counters were not touched by B's write
      assert sequences(a.schema_name) == a_sequences
      assert Enum.map(sequences(b.schema_name), & &1.instance_id) == [b_id]
    end

    test "C9-foreign-pin A's script key pinned with B's prefix is the single script_rejected" do
      a = tenant_with_customer!("e3dc")
      b = tenant_with_customer!("e3dd")
      rule = publish!(a.schema_name, "derive")

      Repo.insert!(
        %Binding{
          tenant_id: b.tenant_id,
          entity_type: "customer",
          script_key: rule.key,
          script_version: rule.version,
          script_sha256: rule.sha256,
          bound_by: Ecto.UUID.generate()
        },
        prefix: b.schema_name
      )

      before_a = event_count(a.schema_name)
      before_b = event_count(b.schema_name)

      assert create(b.schema_name, "customer", %{"name" => "Bea"}) == {:error, :script_rejected}
      assert StubRunner.calls() == 0
      assert event_count(a.schema_name) == before_a
      assert event_count(b.schema_name) == before_b
    end
  end

  # ── route level ────────────────────────────────────────────────────────────

  describe "C9 routes" do
    setup do
      fx_a = "e3ra" |> W.provision!() |> F.with_hmac!()
      fx_b = W.provision!("e3rb")
      type = "bound_in_a_only"
      P.active_definition!(fx_a.schema_name, type, ["name", "total"])
      rule = publish!(fx_a.schema_name, "derive")
      assert {:ok, _} = Hooks.bind(fx_a.schema_name, type, pin(rule), P.actor())

      # the type is bound in A (the hook runs there) and exists in no way in B
      assert {:ok, %{record: %{field_values: %{"total" => "T:probe"}}}} =
               create(fx_a.schema_name, type, %{"name" => "probe"})

      {:ok, calls: StubRunner.calls(), fx_b: fx_b, type: type}
    end

    # the answer for an unknown type names it in places; mask it so the two answers compare
    defp masked(conn, type), do: conn |> W.norm() |> inspect() |> String.replace(type, "TYPE")

    defp assert_same_as_unknown(fx_b, type, calls, request) do
      known = request.(type) |> then(&masked(&1, type))
      unknown = request.("no_such_type") |> then(&masked(&1, "no_such_type"))
      assert known == unknown
      assert StubRunner.calls() == calls
      _ = fx_b
      :ok
    end

    test "C9-route-create", %{fx_b: fx_b, type: type, calls: calls} do
      body = %{"field_values" => %{"name" => "x"}}

      assert_same_as_unknown(fx_b, type, calls, fn t ->
        W.request(fx_b, :post, W.records_path(t, nil), body)
      end)
    end

    test "C9-route-update", %{fx_b: fx_b, type: type, calls: calls} do
      body = %{"field_values" => %{"name" => "x"}}
      id = Ecto.UUID.generate()

      assert_same_as_unknown(fx_b, type, calls, fn t ->
        W.request(fx_b, :put, W.records_path(t, id), body)
      end)
    end

    test "C9-route-import", %{fx_b: fx_b, type: type, calls: calls} do
      assert_same_as_unknown(fx_b, type, calls, fn t ->
        W.request(fx_b, :post, W.import_path(t), W.import_body(t, [:omit]))
      end)
    end

    test "C9-route-import-upsert", %{fx_b: fx_b, type: type, calls: calls} do
      assert_same_as_unknown(fx_b, type, calls, fn t ->
        body =
          t
          |> W.import_body([:omit])
          |> Map.put("upsert_by", "external_ref")
          |> update_in(["records"], fn records ->
            Enum.map(records, &Map.put(&1, "external_ref", %{"system" => "s", "id" => "1"}))
          end)

        W.request(fx_b, :post, W.import_path(t), body)
      end)
    end
  end

  # ── source scan ────────────────────────────────────────────────────────────

  describe "C9 static" do
    @source File.read!("lib/letflow/entities/write_hook.ex")
    @access ~w(one all get get_by insert insert! update update! aggregate exists? delete_all update_all)

    test "C9-static every data-access Repo call of WriteHook passes prefix" do
      calls = Regex.scan(~r/\b[Rr]epo\.(\w+[!?]?)\(/, @source, return: :index)
      assert calls != []

      names =
        for [{start, len}, {n_start, n_len}] <- calls do
          name = binary_part(@source, n_start, n_len)
          {name, start + len}
        end

      for {name, args_start} <- names, name in @access do
        call = balanced(@source, args_start)
        assert call =~ "prefix:", "Repo.#{name}( call without prefix: #{call}"
      end

      # the exemptions, by name: a transaction check (no tenant data) and the two SET LOCAL literals
      exempt = for {name, _} <- names, name not in @access, uniq: true, do: name
      assert Enum.sort(exempt) == ["in_transaction?", "query!"]

      set_locals = Regex.scan(~r/repo\.query!\(("[^"]*")\)/, @source, capture: :all_but_first)

      assert Enum.map(set_locals, &hd/1) == [
               ~s|"SET LOCAL lock_timeout = '2s'"|,
               ~s|"SET LOCAL statement_timeout = '5s'"|
             ]

      refute Enum.any?(set_locals, fn [text] -> text =~ "\#{" end)
    end

    # the text from just after an opening paren to its matching close paren
    defp balanced(text, from), do: balanced(text, from, from, 1)

    defp balanced(text, from, at, 0), do: binary_part(text, from, at - from)

    defp balanced(text, from, at, depth) do
      case if at < byte_size(text), do: :binary.at(text, at) do
        ?( -> balanced(text, from, at + 1, depth + 1)
        ?) -> balanced(text, from, at + 1, depth - 1)
        nil -> binary_part(text, from, at - from)
        _ -> balanced(text, from, at + 1, depth)
      end
    end
  end
end
