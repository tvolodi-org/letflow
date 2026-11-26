defmodule Letflow.Definitions.StepMappingTest do
  @moduledoc """
  The TYPED STEP MAPPING rules (T-2594, "Register a tenant" pilot, gap G13).

  A step that maps variables declares what it reads and what it writes, and the
  declaration is checked against the definition's own `variable_schemas`. These
  tests exercise the rules themselves -- pure, no database, no clock.

  The rule set (owner acceptance item 2: "each node declares its reads and
  writes, and activation refuses an undeclared variable or a write to a
  protected variable"):

    * a declared name must be among the definition's variable schemas;
    * the declared type must agree with the schema's type AND with the type
      the step's contract declares;
    * the reserved engine namespace is never read and never written;
    * a write to a variable a human task may write is refused;
    * a write the contract does not produce is refused;
    * every variable the step really reads must be declared;
    * the declaration itself must be there and well formed.
  """

  use ExUnit.Case, async: true

  alias Letflow.Definitions.StepMapping

  # The definition's variable schemas: two variables, one string and one
  # number.
  @schemas %{
    "slug" => %{"type" => "string"},
    "amount" => %{"type" => "number"}
  }

  # A step that reads `slug` and writes `amount`, as the catalogue declares
  # them (both strings in the contract below).
  defp mapping(overrides) do
    Map.merge(
      %{
        node_id: "call",
        reads: %{"slug" => "string"},
        writes: %{"amount" => "number"},
        read_names: ["slug"],
        write_names: ["amount"],
        read_types: %{"slug" => :string},
        write_types: %{"amount" => :number}
      },
      overrides
    )
  end

  defp codes(violations), do: Enum.map(violations, & &1.code)

  defp violations(overrides \\ %{}, schemas \\ @schemas, completer \\ MapSet.new()) do
    StepMapping.violations([mapping(overrides)], schemas, completer)
  end

  test "a well-formed declaration against matching schemas has no violations" do
    assert [] == violations()
  end

  test "a read of a variable the definition does not declare is refused" do
    found = violations(%{reads: %{"slug" => "string", "ghost" => "string"}})

    assert [:step_mapping_variable_undeclared] = codes(found)
    assert %{node_id: "call", side: :reads, name: "ghost"} = hd(found)
  end

  test "a write of a variable the definition does not declare is refused" do
    found = violations(%{writes: %{"amount" => "number", "ghost" => "string"}})

    assert :step_mapping_variable_undeclared in codes(found)
    assert %{side: :writes, name: "ghost"} = Enum.find(found, &(&1.name == "ghost"))
  end

  test "a declared type that differs from the schema's type is refused" do
    found = violations(%{reads: %{"slug" => "number"}})

    assert :step_mapping_type_mismatch in codes(found)

    assert %{side: :reads, name: "slug"} =
             Enum.find(found, &(&1.code == :step_mapping_type_mismatch))
  end

  test "a number and an integer are the same family, so they agree" do
    schemas = %{"slug" => %{"type" => "string"}, "amount" => %{"type" => "integer"}}

    assert [] == violations(%{writes: %{"amount" => "number"}}, schemas)
  end

  test "a schema that declares no type constrains nothing" do
    schemas = %{"slug" => %{"type" => "string"}, "amount" => %{"description" => "no type here"}}

    assert [] == violations(%{writes: %{"amount" => "number"}}, schemas)
  end

  test "a declared type that differs from the contract's type is refused" do
    found = violations(%{read_types: %{"slug" => :number}})

    assert [:step_mapping_entry_type_mismatch] = codes(found)
    assert %{side: :reads, name: "slug"} = hd(found)
  end

  test "the reserved engine namespace is never read" do
    schemas = %{
      "slug" => %{"type" => "string"},
      "amount" => %{"type" => "number"},
      "_sys" => %{"type" => "string"}
    }

    found = violations(%{reads: %{"slug" => "string", "_sys" => "string"}}, schemas)

    assert [:step_mapping_reserved_refused] = codes(found)
    assert %{side: :reads, name: "_sys"} = hd(found)
  end

  test "the reserved engine namespace is never written" do
    schemas = %{
      "slug" => %{"type" => "string"},
      "amount" => %{"type" => "number"},
      "_sys" => %{"type" => "string"}
    }

    found =
      violations(
        %{writes: %{"amount" => "number", "_sys" => "string"}, write_names: ["amount", "_sys"]},
        schemas
      )

    assert [:step_mapping_reserved_refused] = codes(found)
    assert %{side: :writes, name: "_sys"} = hd(found)
  end

  test "a write to a variable a person may write is refused" do
    found = violations(%{}, @schemas, MapSet.new(["amount"]))

    assert [:step_mapping_write_refused] = codes(found)
    assert %{side: :writes, name: "amount"} = hd(found)
  end

  test "a write the contract does not produce is refused" do
    found = violations(%{write_names: ["other"]})

    assert [:step_mapping_write_not_declared] = codes(found)
    assert %{side: :writes, name: "amount"} = hd(found)
  end

  test "a variable the step really reads but does not declare is refused" do
    found = violations(%{read_names: ["slug", "amount"]})

    assert [:step_mapping_read_undeclared] = codes(found)
    assert %{side: :reads, name: "amount"} = hd(found)
  end

  test "a step that declares no mapping at all is refused" do
    found = violations(%{reads: :missing, writes: :missing})

    assert [:step_mapping_declaration_missing, :step_mapping_declaration_missing] = codes(found)
    assert [:reads, :writes] = Enum.map(found, & &1.side)
  end

  test "a declaration that is not a map is malformed" do
    found = violations(%{reads: "slug"})

    assert :step_mapping_declaration_malformed in codes(found)

    assert %{side: :reads, name: nil} =
             Enum.find(found, &(&1.code == :step_mapping_declaration_malformed))
  end

  test "a declaration with an unknown type name is malformed" do
    found = violations(%{reads: %{"slug" => "text"}})

    assert :step_mapping_declaration_malformed in codes(found)

    assert %{side: :reads, name: "slug"} =
             Enum.find(found, &(&1.code == :step_mapping_declaration_malformed))
  end

  test "a declaration with a dotted name is malformed: the variables are one flat namespace" do
    found = violations(%{reads: %{"a.b" => "string"}})

    assert :step_mapping_declaration_malformed in codes(found)
  end

  test "a declaration with a name over the key bound is malformed" do
    long = String.duplicate("x", 256)

    found = violations(%{reads: %{long => "string"}})

    assert :step_mapping_declaration_malformed in codes(found)
  end

  test "a declaration with an empty name is malformed" do
    found = violations(%{reads: %{"" => "string"}})

    assert :step_mapping_declaration_malformed in codes(found)
  end

  test "the rules never raise on a malformed declaration (INV-8): more is refused, never less" do
    for overrides <- [
          %{reads: :missing},
          %{writes: :missing},
          %{reads: %{"a" => nil}},
          %{reads: %{"a" => 1}},
          %{writes: %{"a" => "string"}, write_names: "not-a-list"},
          %{read_names: nil},
          %{read_types: nil},
          %{write_types: nil}
        ] do
      assert is_list(violations(overrides))
    end
  end

  test "the variables a human task may write are the ones WriteTargets names" do
    nodes = [
      %Letflow.Definitions.Graph.Node{
        id: "ht",
        node_type: :HUMAN_TASK,
        attributes: %{
          "completer_inputs" => ["typed_by_hand"],
          "form_schema" => %{"properties" => %{"also_typed" => %{}}}
        }
      },
      %Letflow.Definitions.Graph.Node{
        id: "call",
        node_type: :SERVICE_TASK,
        attributes: %{}
      }
    ]

    assert MapSet.new(["typed_by_hand", "also_typed"]) ==
             StepMapping.completer_writable_keys(nodes)
  end

  test "every violation carries the node it belongs to" do
    found = violations(%{reads: %{"slug" => "string", "ghost" => "string"}})

    assert Enum.all?(found, &(&1.node_id == "call"))
  end
end
