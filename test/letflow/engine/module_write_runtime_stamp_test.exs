defmodule Letflow.Engine.ModuleWriteRuntimeStampTest do
  @moduledoc """
  GH #2590 / REQ-501 PR R4b (design 6.1 P0b, section 8, section 11 row "Stamp check at run time
  from the pinned snapshot"): every pre-transaction authorization refusal of a completion that
  carries `module_writes` is ONE public refusal, `{:entity_write_refused, line_index,
  :write_not_permitted}` (403), the task stays `pending`, nothing is committed (no record, no
  entity event, no step key, no instance event) and the tenant audit log carries an
  `entity_write.refused` entry whose closed `detail` atom names the cause (and no hash).

  The TOCTOU `owner_recheck` (a hash changed between the authorization and the transaction) is
  driven through an entity-port double that flips the installed hash in `prepare/2`.

  `async: false`: the module install, tenant provisioning and the port double (application env)
  are process-wide.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Entities.EntityPortImpl
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.ModuleWritesFixture, as: Mw
  alias Letflow.Support.ScriptTaskFixture

  defmodule FlipHashPort do
    @moduledoc false
    # Delegates everything to the real port, but changes the installed manifest hash after the
    # pre-transaction authorization and `prepare/2` ran (a hash drift inside the window).
    @behaviour Letflow.Engine.EntityPort

    @impl true
    def prefetch(prefix, reads, vars), do: EntityPortImpl.prefetch(prefix, reads, vars)

    @impl true
    def authorize_module_writes(lines, ctx),
      do: EntityPortImpl.authorize_module_writes(lines, ctx)

    @impl true
    def prepare(lines, ctx) do
      result = EntityPortImpl.prepare(lines, ctx)

      case Application.get_env(:letflow, :flip_hash_target) do
        {schema, module_id} ->
          Mw.set_installed_hash!(schema, module_id, String.duplicate("0", 64))

        _none ->
          :ok
      end

      result
    end

    @impl true
    def validate_lines(lines, ctx), do: EntityPortImpl.validate_lines(lines, ctx)

    @impl true
    def multi(multi, lines, ctx), do: EntityPortImpl.multi(multi, lines, ctx)

    @impl true
    def interpret_failure(step, reason), do: EntityPortImpl.interpret_failure(step, reason)
  end

  defp written(ctx) do
    %{
      records: length(Fx.all_records(ctx.schema)),
      entity_events: length(Fx.entity_events(ctx.schema)),
      step_keys: Fx.step_idempotency_count(ctx.schema),
      applied:
        length(Fx.instance_events(ctx.schema, ctx.instance_id, "TASK_ENTITY_WRITES_APPLIED")),
      instance_events: Fx.all_instance_event_count(ctx.schema, ctx.instance_id)
    }
  end

  # The completion is refused as `write_not_permitted` at `index`, nothing is committed, the
  # task stays pending, and the refusal audit entry carries `detail` (and nothing else).
  defp assert_refused(ctx, index, detail) do
    before = written(ctx)

    assert {:error, {:entity_write_refused, ^index, :write_not_permitted}} =
             Fx.complete(ctx, %{"label" => "L1"})

    assert written(ctx) == before
    assert Fx.task!(ctx.schema, ctx.task.id).status == :pending
    assert Fx.projection!(ctx.schema, ctx.instance_id).status == :active

    assert [entry] = Fx.audit_rows(ctx.schema, "entity_write.refused")
    assert entry.after_state["line_index"] == index
    assert entry.after_state["code"] == "write_not_permitted"
    assert entry.after_state["detail"] == Atom.to_string(detail)
    refute inspect(entry.after_state) =~ ~r/[0-9a-f]{64}/
  end

  test "a hand-edited pinned snapshot (the body hash) is refused: body_changed" do
    ctx = Mw.case!("gh2590-r4b-rs-body", :module)

    Mw.tamper_snapshot!(ctx, fn graph ->
      update_in(graph, ["nodes"], fn nodes ->
        Enum.map(nodes, fn
          %{"id" => "ht"} = node ->
            put_in(node, ["attributes", "module_writes"], [
              %{
                "module" => "fixture_ledger",
                "handler" => "post_entry",
                "args" => %{"item" => %{"var" => "label"}, "quantity" => %{"const" => 99}}
              }
            ])

          node ->
            node
        end)
      end)
    end)

    assert_refused(ctx, 0, :body_changed)
  end

  test "the same snapshot edit on a MIXED node reports the DECLARED handler index (1)" do
    ctx = Mw.case!("gh2590-r4b-rs-mixed", :mixed)

    Mw.tamper_snapshot!(ctx, fn graph ->
      update_in(graph, ["nodes"], fn nodes ->
        Enum.map(nodes, fn
          %{"id" => "ht"} = node ->
            put_in(node, ["attributes", "entity_writes"], [
              Fx.line("stock_move", %{"label" => %{"const" => "tampered"}})
            ])

          node ->
            node
        end)
      end)
    end)

    assert_refused(ctx, 1, :body_changed)
    assert Fx.records(ctx.schema, "stock_move") == []
  end

  test "a definition row with no stamp (a tenant-created copy) is refused: stamp_missing" do
    base = Mw.tenant!("gh2590-r4b-rs-nostamp")
    graph = Mw.graph([Mw.line()])

    # inserted past activation validation (which refuses it), the way a forged/legacy row could be
    definition = Fx.legacy_activate!(base.schema, base.user, graph, [])
    {instance_id, task} = Fx.start!(base.schema, definition)
    ctx = Map.merge(base, %{definition: definition, instance_id: instance_id, task: task})

    assert_refused(ctx, 0, :stamp_missing)
  end

  test "a tampered installed manifest hash is refused: hash_mismatch" do
    ctx = Mw.case!("gh2590-r4b-rs-hash", :module)
    Mw.set_installed_hash!(ctx.schema, "fixture_ledger", String.duplicate("a", 64))
    assert_refused(ctx, 0, :hash_mismatch)
  end

  test "an install with no recorded hash is refused: hash_mismatch" do
    ctx = Mw.case!("gh2590-r4b-rs-nohash", :module)
    Mw.set_installed_hash!(ctx.schema, "fixture_ledger", nil)
    assert_refused(ctx, 0, :hash_mismatch)
  end

  test "a module that is no longer installed is refused: module_not_installed" do
    ctx = Mw.case!("gh2590-r4b-rs-uninstalled", :module)

    {1, _} =
      Repo.delete_all(
        from(m in Letflow.Modules.TenantModule, where: m.module_id == "fixture_ledger"),
        prefix: ctx.schema
      )

    assert_refused(ctx, 0, :module_not_installed)
  end

  test "a tenant not replayed to TASK_ENTITY_WRITES_APPLIED v3 is refused: event_schema_outdated" do
    ctx = Mw.case!("gh2590-r4b-rs-schema", :module)

    {1, _} =
      Repo.delete_all(
        from(e in "event_type_registry",
          where: e.name == "TASK_ENTITY_WRITES_APPLIED" and e.schema_version == 3
        ),
        prefix: ctx.schema
      )

    assert_refused(ctx, 0, :event_schema_outdated)
  end

  test "a tenant still at the R4a v2 row is refused: event_schema_outdated" do
    ctx = Mw.case!("gh2671-rs-stale-v2", :module)

    {1, _} =
      Repo.update_all(
        from(e in "event_type_registry",
          where: e.name == "TASK_ENTITY_WRITES_APPLIED" and e.schema_version == 3
        ),
        [set: [schema_version: 2]],
        prefix: ctx.schema
      )

    assert_refused(ctx, 0, :event_schema_outdated)
  end

  test "a hash that drifts AFTER the authorization is refused inside the transaction (owner_recheck)" do
    ctx = Mw.case!("gh2590-r4b-rs-toctou", :module)
    ScriptTaskFixture.put_env!(:entity_port, FlipHashPort)
    ScriptTaskFixture.put_env!(:flip_hash_target, {ctx.schema, "fixture_ledger"})

    # the authorization passed (nothing was refused up front), then the recheck failed: the
    # handler was never invoked, so no record exists and the instance stream is unchanged
    assert_refused(ctx, 0, :hash_mismatch)
    assert Fx.records(ctx.schema, "fxl_ledger") == []
  end

  test "the COMBINED line cap is enforced at run time on the pinned snapshot (20 + 1 is refused)" do
    ctx = Mw.case!("gh2590-r4b-rs-cap", :module)

    Mw.tamper_snapshot!(ctx, fn graph ->
      update_in(graph, ["nodes"], fn nodes ->
        Enum.map(nodes, fn
          %{"id" => "ht"} = node ->
            put_in(
              node,
              ["attributes", "entity_writes"],
              List.duplicate(Fx.line("stock_move", %{"label" => %{"const" => "v"}}), 20)
            )

          node ->
            node
        end)
      end)
    end)

    before = written(ctx)

    assert {:error, {:entity_write_refused, 20, :validation_failed}} =
             Fx.complete(ctx, %{"label" => "L1"})

    assert written(ctx) == before
    assert Fx.task!(ctx.schema, ctx.task.id).status == :pending
    assert [entry] = Fx.audit_rows(ctx.schema, "entity_write.refused")
    assert entry.after_state["detail"] == "too_many_lines"
  end

  test "after the refusal the same task completes once the cause is fixed (no state was lost)" do
    ctx = Mw.case!("gh2590-r4b-rs-recover", :module)
    {:ok, good_hash} = Letflow.Modules.Catalog.manifest_hash("fixture_ledger")
    Mw.set_installed_hash!(ctx.schema, "fixture_ledger", String.duplicate("b", 64))

    assert {:error, {:entity_write_refused, 0, :write_not_permitted}} =
             Fx.complete(ctx, %{"label" => "L1"})

    Mw.set_installed_hash!(ctx.schema, "fixture_ledger", good_hash)
    assert {:ok, _result} = Fx.complete(ctx, %{"label" => "L1"})
    assert [_one] = Fx.records(ctx.schema, "fxl_ledger")
  end

  describe "the hash triple at run time (TDV T2)" do
    test "installed == stamp but != the compiled manifest hash is refused" do
      ctx = Mw.case!("gh2590-r4b-rs-compiled", :module)
      other = String.duplicate("d", 64)

      Mw.set_stamp_hash!(ctx, other)
      Mw.set_installed_hash!(ctx.schema, "fixture_ledger", other)

      assert_refused(ctx, 0, :hash_mismatch)
    end

    test "installed == compiled but != the stamp is refused" do
      ctx = Mw.case!("gh2590-r4b-rs-stamp", :module)
      Mw.set_stamp_hash!(ctx, String.duplicate("e", 64))

      assert_refused(ctx, 0, :hash_mismatch)
    end
  end
end
