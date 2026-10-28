defmodule Letflow.Entities.RecordsWriteHookScopeTest do
  @moduledoc """
  REQ-607 / GH #3413 part A, criterion C7 (decision 0065 D7, 0051 T12): a hooked write is scope
  checked on the document that holds the hook output, and a managed type is never hooked.

  Uses the `fixture_scoped` module of `ScopeSetFixture` (`scoped_item`, `scoped_child` with a
  reference to the item, `scoped_managed_item`). The binding rows are inserted directly; the stub
  runner answers for the script. `async: false`: provisioned tenant, application env.
  """

  use Letflow.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Records
  alias Letflow.Entities.WriteHook
  alias Letflow.EntityTypeHooks.Binding
  alias Letflow.EventStore.Event
  alias Letflow.Support.ScopeSetFixture, as: F
  alias Letflow.Support.ScriptTaskFixture, as: S

  @in_a {:nodes, ["sf-a", "sf-a1", "sf-a2x"]}

  defmodule StubRunner do
    @moduledoc false
    def start, do: Agent.start_link(fn -> %{calls: 0, reply: nil} end, name: __MODULE__)

    def stop do
      Agent.stop(__MODULE__)
    catch
      :exit, _already_gone -> :ok
    end

    def reply(value), do: Agent.update(__MODULE__, &%{&1 | reply: value})
    def calls, do: Agent.get(__MODULE__, & &1.calls)

    def run(_source, _input, _opts) do
      Agent.update(__MODULE__, &%{&1 | calls: &1.calls + 1})
      Agent.get(__MODULE__, & &1.reply)
    end
  end

  setup do
    fx = F.provision!("e3sc")
    _ = Sandbox.checkin(Repo)
    items = F.seed_items!(fx)

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

    {:ok, fx: Map.put(fx, :items, items)}
  end

  defp bind!(fx, type, derived) do
    manifest = %{
      "input_schema" => %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}},
      "output_schema" => %{
        "type" => "object",
        "properties" => Map.new(derived, &{&1, %{"type" => "string"}}),
        "additionalProperties" => false
      },
      "derived_fields" => derived,
      "fail_codes" => [],
      "limits" => %{"timeout_ms" => 5_000}
    }

    rule =
      S.published!(fx.schema_name, "d_#{type}", "return {}", manifest, hook_kind: "entity_write")

    Repo.insert!(
      %Binding{
        tenant_id: fx.tenant_id,
        entity_type: type,
        script_key: rule.key,
        script_version: rule.version,
        script_sha256: rule.sha256,
        bound_by: Ecto.UUID.generate()
      },
      prefix: fx.schema_name
    )

    :ok
  end

  defp output(map),
    do:
      {:ok, %{output: map, stats: %{duration_us: 1, instructions_used: 1, heap_words_at_end: 1}}}

  defp attrs(extra),
    do:
      Map.merge(
        %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()},
        Map.new(extra)
      )

  defp events(fx), do: Repo.aggregate(Event, :count, prefix: fx.schema_name)

  defp item_values(node, name \\ "w"), do: %{"name" => name, "amount" => 1, "scope_node" => node}

  describe "C7 scope on a hooked write" do
    setup %{fx: fx} do
      bind!(fx, "scoped_item", ["name"])
      StubRunner.reply(output(%{"name" => "from-hook"}))
      :ok
    end

    test "C7-new-scope-create the payload scope value outside the set is refused", %{fx: fx} do
      before = events(fx)

      assert Records.create_record(
               attrs(
                 entity_type: "scoped_item",
                 field_values: %{"amount" => 1, "scope_node" => "sf-b"},
                 scope: @in_a
               ),
               fx.schema_name
             ) == {:error, :scope_refused}

      assert events(fx) == before
    end

    test "C7-in-set control: the hook output is stored", %{fx: fx} do
      assert {:ok, %{record: record}} =
               Records.create_record(
                 attrs(
                   entity_type: "scoped_item",
                   field_values: %{"amount" => 1, "scope_node" => "sf-a"},
                   scope: @in_a
                 ),
                 fx.schema_name
               )

      assert record.field_values["name"] == "from-hook"
      assert StubRunner.calls() == 1
    end

    test "C7-old-scope update of a stored value outside the set is refused before the hook", %{
      fx: fx
    } do
      before = events(fx)

      assert Records.update_record(
               attrs(
                 entity_type: "scoped_item",
                 record_id: fx.items.b.record_id,
                 field_values: %{"amount" => 1, "scope_node" => "sf-a"},
                 scope: @in_a
               ),
               fx.schema_name
             ) == {:error, :scope_refused}

      assert StubRunner.calls() == 0
      assert events(fx) == before
    end

    test "C7-new-scope-update the merged new value outside the set is refused", %{fx: fx} do
      before = events(fx)

      assert Records.update_record(
               attrs(
                 entity_type: "scoped_item",
                 record_id: fx.items.a.record_id,
                 field_values: %{"amount" => 1, "scope_node" => "sf-b"},
                 scope: @in_a
               ),
               fx.schema_name
             ) == {:error, :scope_refused}

      assert events(fx) == before
    end

    test "C7-new-scope-upsert created and updated branches", %{fx: fx} do
      before = events(fx)

      assert Records.upsert_record_by_external_ref(
               attrs(
                 entity_type: "scoped_item",
                 external_ref: %{"system" => "s", "id" => "1"},
                 field_values: %{"amount" => 1, "scope_node" => "sf-b"},
                 scope: @in_a
               ),
               fx.schema_name
             ) == {:error, :scope_refused}

      assert events(fx) == before

      assert {:ok, %{outcome: :created}} =
               Records.upsert_record_by_external_ref(
                 attrs(
                   entity_type: "scoped_item",
                   external_ref: %{"system" => "s", "id" => "1"},
                   field_values: %{"amount" => 1, "scope_node" => "sf-a"},
                   scope: @in_a
                 ),
                 fx.schema_name
               )

      mid = events(fx)

      assert Records.upsert_record_by_external_ref(
               attrs(
                 entity_type: "scoped_item",
                 external_ref: %{"system" => "s", "id" => "1"},
                 field_values: %{"amount" => 2, "scope_node" => "sf-b"},
                 scope: @in_a
               ),
               fx.schema_name
             ) == {:error, :scope_refused}

      assert events(fx) == mid
    end
  end

  test "C7-hook-ref-scope a hook-written reference outside the set is refused", %{fx: fx} do
    bind!(fx, "scoped_child", ["item_id"])
    StubRunner.reply(output(%{"item_id" => fx.items.b.record_id}))
    before = events(fx)

    assert Records.create_record(
             attrs(
               entity_type: "scoped_child",
               field_values: %{"name" => "c", "scope_node" => "sf-a"},
               scope: @in_a
             ),
             fx.schema_name
           ) == {:error, :scope_refused}

    assert StubRunner.calls() == 1
    assert events(fx) == before
  end

  describe "C7 managed type" do
    setup %{fx: fx} do
      bind!(fx, "scoped_managed_item", ["name"])
      StubRunner.reply(output(%{"name" => "from-hook"}))
      :ok
    end

    test "C7-managed a non-owner is refused and the runner is not called", %{fx: fx} do
      before = events(fx)

      assert Records.create_record(
               attrs(entity_type: "scoped_managed_item", field_values: %{"scope_node" => "sf-a"}),
               fx.schema_name
             ) == {:error, :entity_type_managed}

      assert StubRunner.calls() == 0
      assert events(fx) == before
    end

    test "C7-managed-owner the owner writes unchanged even with a binding row", %{fx: fx} do
      owner = %ManagedTypes.Owner{
        module_id: "fixture_scoped",
        manages: MapSet.new(["scoped_managed_item"])
      }

      values = %{"name" => "mine", "scope_node" => "sf-a"}

      assert {:ok, %{record: record}} =
               Records.create_record(
                 attrs(entity_type: "scoped_managed_item", field_values: values),
                 fx.schema_name,
                 owner
               )

      assert record.field_values == values
      assert StubRunner.calls() == 0

      {:ok, definition} =
        Letflow.Entities.Definitions.get_active_definition_by_name(
          "scoped_managed_item",
          fx.schema_name
        )

      assert WriteHook.lookup(definition, "scoped_managed_item", fx.schema_name) == :unbound
    end
  end
end
