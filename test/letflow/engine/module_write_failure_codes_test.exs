defmodule Letflow.Engine.ModuleWriteFailureCodesTest do
  @moduledoc """
  GH #2590 / REQ-501 PR R4b (design section 8, section 11 rows "Codes" and "Handler runs inside
  the step Multi"): the failure mapping of a handler call during the completion transaction.

    * the handler said "not permitted", or tried a type outside its registered targets: ONE
      public refusal `write_not_permitted` (403), audit detail `handler_not_permitted`;
    * the handler said "invalid arguments", or a required argument resolved to nothing:
      `validation_failed` (422), audit detail `handler_invalid_arguments`;
    * the handler raised, THREW, EXITED, returned a non-Multi, smuggled in a step with a live
      repo, used a loose step name, or dropped a write's `:policy` step: an INTERNAL failure
      `{:entity_write_failed, index, :handler}` (500, no body detail), and no exception text
      reaches a log line.

  Every case: nothing committed, the task stays `pending`. The misbehaving handlers are the
  `FixtureLedgerRogue` negative controls (their pack ships one stamped definition per handler).

  `async: false`: the module installs and tenant provisioning run DDL.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog

  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.ModuleWritesFixture, as: Mw

  defp written(ctx) do
    %{
      records: length(Fx.all_records(ctx.schema)),
      entity_events: length(Fx.entity_events(ctx.schema)),
      step_keys: Fx.step_idempotency_count(ctx.schema),
      line_audit: length(Fx.audit_rows(ctx.schema, "entity_write.process_step")),
      instance_events: Fx.all_instance_event_count(ctx.schema, ctx.instance_id)
    }
  end

  defp assert_nothing_committed(ctx, before) do
    assert written(ctx) == before
    assert Fx.task!(ctx.schema, ctx.task.id).status == :pending
    assert Fx.projection!(ctx.schema, ctx.instance_id).status == :active
  end

  describe "refusals (a public code)" do
    for {handler, code, detail} <- [
          {"denies", :write_not_permitted, "handler_not_permitted"},
          {"writes_foreign_type", :write_not_permitted, "handler_not_permitted"},
          {"invalid", :validation_failed, "handler_invalid_arguments"}
        ] do
      test "rogue handler #{handler}: #{code}, detail #{detail}, nothing committed" do
        ctx = Mw.rogue_case!("gh2590-r4b-fc-#{unquote(handler)}", unquote(handler))
        before = written(ctx)

        assert {:error, {:entity_write_refused, 0, unquote(code)}} =
                 Fx.complete(ctx, %{})

        assert_nothing_committed(ctx, before)
        assert [entry] = Fx.audit_rows(ctx.schema, "entity_write.refused")
        assert entry.after_state["detail"] == unquote(detail)
        assert entry.after_state["line_index"] == 0
      end
    end

    test "a required argument that resolves to nothing is validation_failed" do
      ctx = Mw.case!("gh2590-r4b-fc-missingarg", :module)
      before = written(ctx)

      # the node reads its `item` from variable `label`, which this completion does not supply
      assert {:error, {:entity_write_refused, 0, :validation_failed}} = Fx.complete(ctx, %{})

      assert_nothing_committed(ctx, before)
      assert [entry] = Fx.audit_rows(ctx.schema, "entity_write.refused")
      assert entry.after_state["detail"] == "handler_invalid_arguments"
    end

    test "a handler that rejects the resolved value is validation_failed" do
      ctx = Mw.case!("gh2590-r4b-fc-badvalue", :module)
      before = written(ctx)

      # `item` must be a string: the handler answers :invalid_arguments for an integer
      assert {:error, {:entity_write_refused, 0, :validation_failed}} =
               Fx.complete(ctx, %{"label" => 5})

      assert_nothing_committed(ctx, before)
    end

    test "a MIXED node whose handler fails rolls the declarative record back too" do
      ctx = Mw.case!("gh2590-r4b-fc-mixed", :mixed)
      before = written(ctx)

      # the declarative line (index 0) would succeed; the handler call (index 1) fails
      assert {:error, {:entity_write_refused, 1, :validation_failed}} = Fx.complete(ctx, %{})

      assert_nothing_committed(ctx, before)
      assert Fx.records(ctx.schema, "stock_move") == []
      assert [entry] = Fx.audit_rows(ctx.schema, "entity_write.refused")
      assert entry.after_state["line_index"] == 1
    end

    test "the refused completion is repeatable and succeeds once the arguments are supplied" do
      ctx = Mw.case!("gh2590-r4b-fc-retry", :module)

      assert {:error, {:entity_write_refused, 0, :validation_failed}} = Fx.complete(ctx, %{})
      assert {:error, {:entity_write_refused, 0, :validation_failed}} = Fx.complete(ctx, %{})
      assert {:ok, _} = Fx.complete(ctx, %{"label" => "L1"})
      assert [_one] = Fx.records(ctx.schema, "fxl_ledger")
    end
  end

  describe "internal failures (a contract violation or a raise)" do
    for handler <- [
          "raises",
          "throws",
          "exits",
          "bad_return",
          "out_of_range_step",
          "loose_step",
          "run_after_create",
          "drop_policy"
        ] do
      test "rogue handler #{handler}: entity_write_failed :handler, nothing committed" do
        ctx = Mw.rogue_case!("gh2590-r4b-fi-#{unquote(handler)}", unquote(handler))
        before = written(ctx)

        log =
          capture_log(fn ->
            assert {:error, {:entity_write_failed, 0, :handler}} = Fx.complete(ctx, %{})
          end)

        assert_nothing_committed(ctx, before)

        # no exception text, no secret detail in the log line (INV-4)
        refute log =~ "secret detail"

        # an internal failure is not a client refusal: no refusal audit entry
        assert Fx.audit_rows(ctx.schema, "entity_write.refused") == []
      end
    end
  end
end
