defmodule Letflow.Modules.Exam.ExamAssignmentTest do
  @moduledoc """
  REQ-582 part A, criterion 1: the `exam_assignment` managed type. The record write refuses an
  `assignee_type` outside `all|user|group|org_unit` and a missing `exam_id`, and only the exam
  module's authority may write the type (D1-D4). Tenant: `Fx.full_tenant!/1`, which holds the
  definition owner-stamped and active, as a tenant does after
  `Letflow.Release.ManagedTypes.ensure_assignment_definition/1`.

  Runs outside the Ecto sandbox transaction (`async: false`), like the other exam tenant tests.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Records
  alias Letflow.ExamStampFixtures, as: Fx
  alias Letflow.Modules.Exam

  defp attrs(overrides) do
    field_values =
      %{
        "exam_id" => Ecto.UUID.generate(),
        "assignee_type" => "all",
        "assigned_by" => Ecto.UUID.generate(),
        "active" => true
      }
      |> Map.merge(overrides)
      |> Enum.reject(fn {_k, v} -> v == :drop end)
      |> Map.new()

    %{
      entity_type: "exam_assignment",
      field_values: field_values,
      actor_id: Ecto.UUID.generate(),
      idempotency_key: Ecto.UUID.generate()
    }
  end

  defp create(overrides, schema),
    do: Records.create_record(attrs(overrides), schema, ManagedTypes.owner_for!(Exam))

  setup do
    %{schema_name: schema} = Fx.full_tenant!("req582-assign")
    {:ok, schema: schema}
  end

  test "D1 each of all, user, group and org_unit is accepted with the exam authority", %{
    schema: schema
  } do
    for type <- ~w(all user group org_unit) do
      overrides =
        if type == "all",
          do: %{"assignee_type" => type},
          else: %{"assignee_type" => type, "assignee_id" => Ecto.UUID.generate()}

      assert {:ok, %{record: _record}} = create(overrides, schema), type
    end
  end

  test "D2 another assignee_type, an empty one, or none is refused by the record write", %{
    schema: schema
  } do
    for bad <- ["department", "", "ALL", :drop] do
      assert {:error, {:record_payload_invalid, [failure]}} =
               create(%{"assignee_type" => bad}, schema),
             inspect(bad)

      assert failure.field_path == "/assignee_type"
      assert failure.constraint == if(bad == :drop, do: "required", else: "enum")
    end
  end

  test "D3 a record without exam_id is refused", %{schema: schema} do
    assert {:error, {:record_payload_invalid, [failure]}} = create(%{"exam_id" => :drop}, schema)
    assert failure.field_path == "/exam_id"
    assert failure.constraint == "required"
  end

  test "D4 without the module authority the write is refused; with it, it succeeds", %{
    schema: schema
  } do
    assert {:error, :entity_type_managed} = Records.create_record(attrs(%{}), schema, :tenant)
    assert {:error, :entity_type_managed} = Records.create_record(attrs(%{}), schema)

    assert {:ok, %{record: _record}} = create(%{}, schema)
  end

  test "M1 the exam manifest manages exam_assignment" do
    assert "exam_assignment" in Exam.manifest().manages_entity_types
  end
end
