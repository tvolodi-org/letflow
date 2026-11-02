Code.require_file("codes_fixture.exs", __DIR__)

defmodule Letflow.Modules.Codes.BehaviourTest do
  @moduledoc """
  GH #3588 / REQ-648 criterion 4 (B-01..B-07): value uniqueness in the tenant and the real foreign
  keys, through the owner path on a fresh provisioned tenant with the real installed module.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Letflow.CodesFixture

  alias Letflow.Entities.Definition.Validator.Violation
  alias Letflow.Entities.Record.Latest

  setup do
    {:ok, installed_tenant!("gh3588-beh")}
  end

  defp count(schema, type),
    do: Repo.aggregate(from(l in Latest, where: l.entity_type == ^type), :count, prefix: schema)

  describe "criterion 4" do
    test "B-01..B-03: a duplicate value is refused for a different kind, status and a retired original",
         %{schema: schema} do
      tag!(schema, "DUP")

      for {extra, label} <- [
            {%{"kind" => "qr"}, "kind"},
            {%{"status" => "assigned"}, "status"}
          ] do
        assert {:error, {:record_payload_invalid, [%Violation{rule: :unique, path: path}]}} =
                 create(schema, "code_tag", values("code_tag", "DUP", extra)),
               label

        assert path == ["value"]
      end

      tag!(schema, "GONE", %{"status" => "retired"})

      assert {:error, {:record_payload_invalid, [%Violation{rule: :unique, path: ["value"]}]}} =
               create(schema, "code_tag", values("code_tag", "GONE", %{"kind" => "epc"}))

      assert count(schema, "code_tag") == 2
    end

    test "B-04, B-05: a history row whose code_id names no code_tag is a :reference violation",
         %{schema: schema} do
      ghost = Ecto.UUID.generate()

      for type <- ["code_assignment", "code_value_change"] do
        assert {:error, {:record_payload_invalid, violations}} =
                 create(schema, type, values(type, ghost, %{}))

        assert Enum.any?(
                 violations,
                 &match?(%Violation{rule: :reference, path: ["code_id"]}, &1)
               ),
               "#{type}: #{inspect(violations)}"

        assert count(schema, type) == 0
      end
    end

    test "B-06: values differing only in case or in a trailing space are both accepted", %{
      schema: schema
    } do
      tag!(schema, "abc")
      assert {:ok, _} = create(schema, "code_tag", values("code_tag", "ABC", %{}))
      assert {:ok, _} = create(schema, "code_tag", values("code_tag", "abc ", %{}))
    end

    test "B-07: the same value in tenant B's schema is accepted", %{schema: schema} do
      tag!(schema, "SAME")
      other = installed_tenant!("gh3588-beh2")
      assert {:ok, _} = create(other.schema, "code_tag", values("code_tag", "SAME", %{}))
    end
  end
end
