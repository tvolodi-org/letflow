defmodule Letflow.Engine.ScriptInputTest do
  @moduledoc """
  Decision 0062 R4/R6 (GH #2616 part 3), pure: which labelled variables enter a script's input
  (SR-OPT-1, SR-OPT-2) and the taint a run carries.
  """

  use ExUnit.Case, async: true

  alias Letflow.Engine.ScriptInput

  @salary "customer.salary"
  @pair %{"entity_type" => "customer", "field" => "salary"}

  defp manifest(restricted_inputs, required \\ []) do
    %{
      "input_schema" => %{
        "type" => "object",
        "properties" => %{"cid" => %{"type" => "string"}, "amount" => %{"type" => "integer"}},
        "required" => required
      },
      "restricted_inputs" => restricted_inputs
    }
  end

  test "SR-OPT-1: a labelled variable enters when its labels are within the entry's from" do
    m = manifest([%{"name" => "amount", "from" => [@pair]}])

    assert ScriptInput.build(%{"cid" => "c", "amount" => 5}, %{"amount" => [@salary]}, m, nil) ==
             {:ok, %{"cid" => "c", "amount" => 5}, [@salary]}
  end

  test "SR-OPT-2: a labelled variable without an entry is omitted, and fails when required" do
    vars = %{"cid" => "c", "amount" => 5}
    labels = %{"amount" => [@salary]}

    assert ScriptInput.build(vars, labels, manifest([]), nil) == {:ok, %{"cid" => "c"}, []}

    assert ScriptInput.build(vars, labels, manifest([], ["amount"]), nil) ==
             {:error, :input_invalid}
  end

  test "SR-OPT-2: one label outside from omits the variable" do
    m = manifest([%{"name" => "amount", "from" => [@pair]}])
    labels = %{"amount" => [@salary, "customer.ssn"]}

    assert ScriptInput.build(%{"cid" => "c", "amount" => 5}, labels, m, nil) ==
             {:ok, %{"cid" => "c"}, []}
  end

  test "SR-OPT-2: an entry for another name does not admit the variable; a legacy entry delivers nothing" do
    vars = %{"amount" => 5}
    labels = %{"amount" => [@salary]}
    other = manifest([%{"name" => "cid", "from" => [@pair]}])

    assert {:ok, %{}, []} = ScriptInput.build(vars, labels, other, nil)
    assert {:ok, %{}, []} = ScriptInput.build(vars, labels, manifest(["amount"]), nil)
  end

  test "an unlabelled variable enters with an empty taint" do
    assert ScriptInput.build(%{"cid" => "c"}, %{}, manifest([]), nil) ==
             {:ok, %{"cid" => "c"}, []}
  end

  test "an undeclared labelled variable never enters" do
    m = manifest([%{"name" => "amount", "from" => [@pair]}])

    assert ScriptInput.build(%{"other" => 1}, %{"other" => [@salary]}, m, nil) ==
             {:ok, %{}, []}
  end

  test "read_taint/1 lists every declared restricted_fields pair, sorted and unique" do
    reads = [
      %{"entity_type" => "customer", "restricted_fields" => ["ssn", "salary"]},
      %{"entity_type" => "customer", "restricted_fields" => ["salary"]},
      %{"entity_type" => "person"},
      %{"entity_type" => "person", "restricted_fields" => []}
    ]

    assert ScriptInput.read_taint(reads) == ["customer.salary", "customer.ssn"]
    assert ScriptInput.read_taint([]) == []
    assert ScriptInput.read_taint(nil) == []
  end
end
