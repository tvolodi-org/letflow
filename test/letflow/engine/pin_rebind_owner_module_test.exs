defmodule Letflow.Engine.PinRebindOwnerModuleTest do
  @moduledoc """
  GH #2590 / REQ-501 PR R3 (decision 0054 D6 property 4; design 4.9 Option N, D-R.14, OQ-R1,
  section 11 row "PinRebind"): a `:module` (sub-process reference) pin entry is refused ONLY for
  an instance whose PINNED definition is module-stamped AND whose pinned snapshot declares
  `module_writes`. Every other request is unchanged.

  Also the tripwire the design asks for: PinRebind never writes the instance's pinned
  `definition_id`, and the engine does not consume `:module` pins, so no rebind can move an
  instance to another definition version.

  A `:module` entry that passes the guard continues to the effective-pin lookup, which answers
  `{:unknown_pin_ref, :module, ref}` for an instance that has no such pin; that is how these
  tests tell "guard let it through" from "guard refused".

  `async: false`: the module install and tenant provisioning run DDL.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions.InstanceDefinitionSnapshot
  alias Letflow.Engine.PinRebind
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.ModuleWritesFixture, as: Mw

  @module_entry %{kind: :module, ref: "sub-a", version: "2"}

  defp attrs(entries) do
    %{
      entries: entries,
      reason: "GH 2590 R3 test",
      actor_id: Ecto.UUID.generate(),
      idempotency_key: Fx.unique("r3-rebind")
    }
  end

  defp rebind(ctx, entries),
    do: PinRebind.rebind_pins(ctx.instance_id, attrs(entries), prefix: ctx.schema)

  defp pins_events(ctx),
    do: length(Fx.instance_events(ctx.schema, ctx.instance_id, "INSTANCE_PINS_REBOUND"))

  defp pinned_definition(ctx) do
    projection =
      Repo.get_by!(InstanceProjection, [instance_id: ctx.instance_id], prefix: ctx.schema)

    snapshot =
      Repo.get!(InstanceDefinitionSnapshot, ctx.instance_id, prefix: ctx.schema)

    {Map.get(projection, :definition_id), snapshot.definition_id}
  end

  test "a stamped definition whose snapshot declares module_writes: the :module entry is refused" do
    ctx = Mw.case!("gh2590-r3-pin-a", :module)
    before = pins_events(ctx)

    assert {:error, {:rebind_refused_owned_definition, :module, "sub-a"}} =
             rebind(ctx, [@module_entry])

    assert pins_events(ctx) == before
  end

  test "the refusal is all-or-nothing: other entries of the request are not applied" do
    ctx = Mw.case!("gh2590-r3-pin-b", :module)
    before = pins_events(ctx)

    entries = [
      %{kind: :variable_schema, ref: ctx.definition.name, version: "v2"},
      @module_entry
    ]

    assert {:error, {:rebind_refused_owned_definition, :module, "sub-a"}} = rebind(ctx, entries)
    assert pins_events(ctx) == before
  end

  test "non-:module entries on that same instance are unchanged" do
    ctx = Mw.case!("gh2590-r3-pin-c", :module)
    {projection_def, snapshot_def} = pinned_definition(ctx)

    assert {:ok, result} =
             rebind(ctx, [%{kind: :variable_schema, ref: ctx.definition.name, version: "v9"}])

    assert [%{kind: :variable_schema, new_version: "v9"}] = result.changed
    assert pinned_definition(ctx) == {projection_def, snapshot_def}
  end

  test "a stamped definition WITHOUT module_writes: the :module entry passes the guard" do
    ctx = Mw.case!("gh2590-r3-pin-d", :plain)

    assert {:error, {:unknown_pin_ref, :module, "sub-a"}} = rebind(ctx, [@module_entry])
  end

  test "an unstamped definition that declares module_writes (legacy row): the guard lets it through" do
    base = Fx.tenant_case!("gh2590-r3-pin-e")
    definition = Fx.legacy_activate!(base.schema, base.user, Mw.graph([Mw.line()]), [])
    {instance_id, _task} = Fx.start!(base.schema, definition)
    ctx = Map.put(base, :instance_id, instance_id)

    assert {:error, {:unknown_pin_ref, :module, "sub-a"}} = rebind(ctx, [@module_entry])
  end

  test "fail closed: the pinned snapshot declares module_writes and the definition row is gone" do
    ctx = Mw.case!("gh2590-r3-pin-f", :module)

    Repo.query!(
      ~s(ALTER TABLE "#{ctx.schema}"."instance_definition_snapshots" ) <>
        "DROP CONSTRAINT instance_definition_snapshots_definition_id_fkey"
    )

    Repo.delete_all(
      from(d in Letflow.Definitions.ProcessDefinition, where: d.id == ^ctx.definition.id),
      prefix: ctx.schema
    )

    assert {:error, {:rebind_refused_owned_definition, :module, "sub-a"}} =
             rebind(ctx, [@module_entry])
  end

  test "the router answers 409 with a constant detail (no module, no ref)" do
    ctx = Mw.case!("gh2590-r3-pin-r", :module)

    conn =
      Plug.Test.conn(:post, "/#{ctx.instance_id}/rebind-pins")
      |> Map.put(:body_params, %{
        "reason" => "GH 2590 R3 router",
        "entries" => [%{"kind" => "module", "ref" => "sub-a", "version" => "2"}]
      })
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.assign(:auth_context, %{
        user_id: Ecto.UUID.generate(),
        tenant_id: ctx.tenant.tenant_id,
        roles: ["TENANT_ADMIN"]
      })
      |> Plug.Conn.assign(:trace_id, "gh2590-r3-trace")
      |> Letflow.Routers.Instances.call(Letflow.Routers.Instances.init([]))

    assert conn.status == 409
    refute conn.resp_body =~ "sub-a"
    refute conn.resp_body =~ "fixture_ledger"
  end

  describe "tripwire (OQ-R1)" do
    test "a successful rebind never changes the pinned definition_id" do
      ctx = Mw.case!("gh2590-r3-pin-t", :plain)
      before = pinned_definition(ctx)

      assert {:ok, _} =
               rebind(ctx, [%{kind: :variable_schema, ref: ctx.definition.name, version: "v3"}])

      assert pinned_definition(ctx) == before
    end

    test "PinRebind has no write to definition_id and the engine consumes no :module pin" do
      rebind_src = File.read!("lib/letflow/engine/pin_rebind.ex")
      engine_src = File.read!("lib/letflow/engine.ex")

      refute rebind_src =~ ~r/set:\s*\[[^\]]*definition_id/,
             "PinRebind must never write an instance's definition_id"

      refute engine_src =~ ~r/pin_for\([^)]*:module/,
             "the engine started consuming :module pins: revisit the PinRebind owner guard (0054 D6)"
    end
  end
end
