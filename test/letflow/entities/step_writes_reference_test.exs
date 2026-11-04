defmodule Letflow.Entities.StepWritesReferenceTest do
  @moduledoc """
  REQ-636 (decision 0070 slice C), process-step and module-handler write paths.

    * P-step: a HUMAN_TASK completion whose `var` source holds a dangling module reference is
      refused `validation_failed` (audit detail `reference`) and nothing is stored; a live id is
      stored. `prepare/2` sees no field values, so it neither refuses nor checks (the check sits
      in `build_line/5`).
    * P-handler: `HandlerWrites` calls the check, but its targets are managed types, which the
      check skips: a managed type that declares a dangling reference is not refused, and the same
      check on an unmanaged type shows the guard would fire.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.ReferenceCheck
  alias Letflow.Entities.StepWrites
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.Modules.FixtureRefTargets
  alias Letflow.Modules.Installs
  alias Letflow.ReferenceFixture

  @ref %{"module_id" => "fixture_ref_targets", "entity_type" => "frt_target"}

  defp case!(slug) do
    base = Fx.tenant_case!(slug)
    ReferenceFixture.cleanup_on_exit(base.tenant.tenant_id)

    {:ok, _} =
      Installs.install("fixture_ref_targets", Ecto.UUID.generate(),
        prefix: base.schema,
        rationale: "REQ-636 step test"
      )

    Fx.define_type!(base.schema, "step_ref", %{
      fields: [
        %{name: "label", type: :string, required: true},
        %{name: "ref", type: :string, reference: @ref}
      ]
    })

    line = Fx.line("step_ref", %{"label" => %{"const" => "x"}, "ref" => %{"var" => "ref"}})
    ctx = Fx.attach!(base, [line])

    {:ok, %{record: target}} =
      FixtureRefTargets.create_record(
        "frt_target",
        %{"name" => "t", "active" => true},
        base.schema
      )

    {ctx, target.record_id}
  end

  test "P-step: dangling refused with nothing stored; live id stored" do
    {ctx, live} = case!("req636-step")

    dangling = Ecto.UUID.generate()

    assert {:error, {:entity_write_refused, 0, :validation_failed}} =
             Fx.complete(ctx, %{"ref" => dangling})

    assert Fx.records(ctx.schema, "step_ref") == []
    assert [entry] = Fx.audit_rows(ctx.schema, "entity_write.refused")
    assert entry.after_state["code"] == "validation_failed"
    assert entry.after_state["detail"] == "reference"
    refute inspect(entry.after_state) =~ dangling

    assert {:ok, _} = Fx.complete(ctx, %{"ref" => live})
    assert [record] = Fx.records(ctx.schema, "step_ref")
    assert record.field_values["ref"] == live
  end

  test "P-step: prepare/2 has no field values, so it neither refuses nor checks" do
    {ctx, _live} = case!("req636-prep")
    line = Fx.line("step_ref", %{"label" => %{"const" => "x"}, "ref" => %{"var" => "ref"}})

    assert :ok = StepWrites.prepare([line], %{prefix: ctx.schema})
    assert Fx.records(ctx.schema, "step_ref") == []
  end

  test "P-handler: a managed type is skipped by the check; an unmanaged type is checked" do
    {ctx, _live} = case!("req636-handler")
    dangling = Ecto.UUID.generate()

    # managed target of a module: skipped (its owner validates its own references)
    assert ReferenceCheck.check("frt_target", %{"ref" => dangling}, ctx.schema) == :ok

    # the unmanaged holder: the same value is refused by the same call
    assert ReferenceCheck.check("step_ref", %{"label" => "x", "ref" => dangling}, ctx.schema) ==
             {:error, {:reference_invalid, ["ref"]}}
  end
end
