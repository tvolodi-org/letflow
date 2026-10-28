defmodule Letflow.Modules.Procurement.PurchaseRequestTest do
  @moduledoc """
  GH #3162 / REQ-544 part 1, criteria 1, 2 and 3 (spec: state/tasks/T-0745/design.md, tests T-V1
  to T-V9): the pure validation and exact totals of `Letflow.Modules.Procurement.PurchaseRequest`.
  The two reference reads are injected, so no database. `async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Modules.Procurement.PurchaseRequest

  @actor "11111111-1111-4111-8111-111111111111"
  @dept "22222222-2222-4222-8222-222222222222"
  @unit "33333333-3333-4333-8333-333333333333"
  @unit_retired "44444444-4444-4444-8444-444444444444"
  @unit_wrong_type "55555555-5555-4555-8555-555555555555"
  @secret "SENTINEL-CLIENT-TEXT"

  defp lookups(pid \\ nil) do
    unit = fn id ->
      if pid, do: send(pid, {:unit_read, id})

      case id do
        @unit -> {:ok, @unit}
        @unit_retired -> :retired
        _ -> :unknown
      end
    end

    department = fn id ->
      case id do
        @dept -> {:ok, @dept}
        "66666666-6666-4666-8666-666666666666" -> :retired
        _ -> :unknown
      end
    end

    %{unit: unit, department: department}
  end

  defp material(overrides \\ %{}) do
    Map.merge(
      %{
        "kind" => "material",
        "description" => "Bolts",
        "quantity" => "3",
        "unit_id" => @unit,
        "estimated_unit_cost" => "0.10"
      },
      overrides
    )
  end

  defp params(overrides \\ %{}) do
    Map.merge(
      %{
        "department_id" => @dept,
        "justification" => "Needed for the line",
        "required_date" => "2027-03-01",
        "priority" => "normal",
        "lines" => [material()]
      },
      overrides
    )
  end

  defp errors({:error, {:validation, errors}}), do: errors
  defp fields(result), do: result |> errors() |> Enum.map(&{&1.field, &1.code})

  describe "criterion 1: mandatory fields" do
    test "T-V1: every mandatory field missing names each one" do
      assert {:error, {:validation, errs}} = PurchaseRequest.build(%{}, nil, lookups())

      assert Enum.map(errs, & &1.field) ==
               ~w(department_id justification lines priority requester required_date)

      assert Enum.all?(errs, &(&1.code == "required"))
    end

    test "T-V1b: a valid request builds" do
      assert {:ok, content} = PurchaseRequest.build(params(), @actor, lookups())
      assert content["requester"] == @actor
      assert content["department_id"] == @dept
      assert content["priority"] == "normal"
    end

    test "T-V2: line fields missing, bad quantity and cost are named per line" do
      result = PurchaseRequest.build(params(%{"lines" => [%{}]}), @actor, lookups())

      assert fields(result) == [
               {"lines[1].description", "required"},
               {"lines[1].estimated_unit_cost", "required"},
               {"lines[1].kind", "required"},
               {"lines[1].quantity", "required"},
               {"lines[1].unit_id", "required"}
             ]

      for q <- ["0", "-1", "abc", "1.23456", "1e3", "NaN", 0, -1, 1.5, "1x5", " 1", 1_000_000] do
        result =
          PurchaseRequest.build(
            params(%{"lines" => [material(%{"quantity" => q})]}),
            @actor,
            lookups()
          )

        assert fields(result) == [{"lines[1].quantity", "invalid"}], "quantity #{inspect(q)}"
      end

      result =
        PurchaseRequest.build(
          params(%{"lines" => [material(%{"estimated_unit_cost" => "-0.01"})]}),
          @actor,
          lookups()
        )

      assert fields(result) == [{"lines[1].estimated_unit_cost", "invalid"}]

      assert {:ok, content} =
               PurchaseRequest.build(
                 params(%{"lines" => [material(%{"estimated_unit_cost" => "0"})]}),
                 @actor,
                 lookups()
               )

      assert [%{"estimated_unit_cost" => "0", "line_total" => "0"}] = content["lines"]
    end

    test "T-V3: work and service lines need scope, deliverables and completion date" do
      for kind <- ["work", "service"] do
        result =
          PurchaseRequest.build(
            params(%{"lines" => [material(%{"kind" => kind})]}),
            @actor,
            lookups()
          )

        assert fields(result) == [
                 {"lines[1].completion_date", "required"},
                 {"lines[1].deliverables", "required"},
                 {"lines[1].scope", "required"}
               ]
      end

      line =
        material(%{
          "kind" => "service",
          "scope" => "S",
          "deliverables" => "D",
          "completion_date" => "2027-04-01"
        })

      assert {:ok, %{"lines" => [stored]}} =
               PurchaseRequest.build(params(%{"lines" => [line]}), @actor, lookups())

      assert %{"scope" => "S", "deliverables" => "D", "completion_date" => "2027-04-01"} = stored

      # a material line needs none, and a value supplied on it is not stored
      assert {:ok, %{"lines" => [stored]}} =
               PurchaseRequest.build(
                 params(%{"lines" => [material(%{"scope" => "x"})]}),
                 @actor,
                 lookups()
               )

      refute Map.has_key?(stored, "scope")
    end

    test "T-V4: empty and absent lines are rejected" do
      assert fields(PurchaseRequest.build(params(%{"lines" => []}), @actor, lookups())) ==
               [{"lines", "required"}]

      assert fields(PurchaseRequest.build(Map.delete(params(), "lines"), @actor, lookups())) ==
               [{"lines", "required"}]

      assert fields(PurchaseRequest.build(params(%{"lines" => "x"}), @actor, lookups())) ==
               [{"lines", "invalid"}]
    end

    test "T-V8: caps and hostile shapes give validation errors, never a raise" do
      many = List.duplicate(material(), 201)

      assert fields(PurchaseRequest.build(params(%{"lines" => many}), @actor, lookups())) == [
               {"lines", "invalid"}
             ]

      long = String.duplicate("a", 4001)

      assert fields(PurchaseRequest.build(params(%{"justification" => long}), @actor, lookups())) ==
               [{"justification", "invalid"}]

      assert fields(PurchaseRequest.build(%{department_id: @dept}, @actor, lookups())) == [
               {"params", "invalid"}
             ]

      assert fields(PurchaseRequest.build("x", @actor, lookups())) == [{"params", "invalid"}]

      assert fields(PurchaseRequest.build(params(%{"lines" => [1, nil]}), @actor, lookups())) ==
               [{"lines[1]", "invalid"}, {"lines[2]", "invalid"}]

      assert fields(
               PurchaseRequest.build(
                 params(%{"required_date" => "2027-13-45", "priority" => "asap"}),
                 @actor,
                 lookups()
               )
             ) ==
               [{"priority", "invalid"}, {"required_date", "invalid"}]
    end

    test "requester: a differing client value is rejected, the actor is stored" do
      assert fields(PurchaseRequest.build(params(%{"requester" => @dept}), @actor, lookups())) ==
               [{"requester", "mismatch"}]

      assert {:ok, %{"requester" => @actor}} =
               PurchaseRequest.build(
                 params(%{"requester" => String.upcase(@actor)}),
                 @actor,
                 lookups()
               )
    end

    test "unknown keys are not copied into the content" do
      assert {:ok, content} =
               PurchaseRequest.build(
                 params(%{"extra" => "x", "status" => "approved"}),
                 @actor,
                 lookups()
               )

      refute Map.has_key?(content, "extra")
      refute Map.has_key?(content, "status")
    end
  end

  describe "criterion 2: exact totals" do
    test "T-V5: 3 x 0.10 and 2 x 19.99 are exact" do
      lines = [material(), material(%{"quantity" => 2, "estimated_unit_cost" => "19.99"})]

      assert {:ok, content} =
               PurchaseRequest.build(params(%{"lines" => lines}), @actor, lookups())

      assert [%{"line_total" => "0.3"}, %{"line_total" => "39.98"}] = content["lines"]
      assert content["total"] == "40.28"
      assert Decimal.equal?(Decimal.new(content["total"]), Decimal.new("40.28"))
    end

    test "T-V5b: 0.1 x 3 is not the float result" do
      line = material(%{"quantity" => "3", "estimated_unit_cost" => "0.1"})

      assert {:ok, %{"total" => total}} =
               PurchaseRequest.build(params(%{"lines" => [line]}), @actor, lookups())

      assert total == "0.3"
      refute total == "0.30000000000000004"
    end

    test "T-V6: a differing client total is rejected, an equal one is recomputed" do
      assert fields(PurchaseRequest.build(params(%{"total" => "99"}), @actor, lookups())) == [
               {"total", "mismatch"}
             ]

      assert fields(
               PurchaseRequest.build(
                 params(%{"lines" => [material(%{"line_total" => "1"})]}),
                 @actor,
                 lookups()
               )
             ) ==
               [{"lines[1].line_total", "mismatch"}]

      assert {:ok, %{"total" => "0.3", "lines" => [%{"line_total" => "0.3"}]}} =
               PurchaseRequest.build(
                 params(%{"total" => "0.300", "lines" => [material(%{"line_total" => "0.30"})]}),
                 @actor,
                 lookups()
               )

      assert fields(PurchaseRequest.build(params(%{"total" => "1e1"}), @actor, lookups())) == [
               {"total", "invalid"}
             ]
    end

    test "equal values have one byte form" do
      a = params(%{"lines" => [material(%{"estimated_unit_cost" => "0.10"})]})
      b = params(%{"lines" => [material(%{"estimated_unit_cost" => "0.1000"})]})

      assert PurchaseRequest.build(a, @actor, lookups()) ==
               PurchaseRequest.build(b, @actor, lookups())
    end

    test "200 lines at the caps stay exact" do
      line = material(%{"quantity" => "999999.9999", "estimated_unit_cost" => "999999999.9999"})
      lines = List.duplicate(line, 200)

      assert {:ok, content} =
               PurchaseRequest.build(params(%{"lines" => lines}), @actor, lookups())

      one = Decimal.mult(Decimal.new("999999.9999"), Decimal.new("999999999.9999"))
      expected = Enum.reduce(1..200, Decimal.new(0), fn _, acc -> Decimal.add(acc, one) end)
      assert content["total"] == expected |> Decimal.normalize() |> Decimal.to_string(:normal)
      assert Decimal.equal?(Decimal.new(content["total"]), Decimal.mult(one, 200))
    end
  end

  describe "criterion 3: reference data" do
    test "T-V7: unknown, wrong type and retired units; one read per distinct unit" do
      for {id, code} <- [
            {Ecto.UUID.generate(), "unknown"},
            {@unit_wrong_type, "unknown"},
            {@unit_retired, "retired"},
            {"nope", "unknown"}
          ] do
        result =
          PurchaseRequest.build(
            params(%{"lines" => [material(%{"unit_id" => id})]}),
            @actor,
            lookups()
          )

        assert fields(result) == [{"lines[1].unit_id", code}]
      end

      for {id, code} <- [
            {Ecto.UUID.generate(), "unknown"},
            {"66666666-6666-4666-8666-666666666666", "retired"}
          ] do
        result = PurchaseRequest.build(params(%{"department_id" => id}), @actor, lookups())
        assert fields(result) == [{"department_id", code}]
      end

      lines = [material(), material(), material(%{"unit_id" => @unit_retired})]
      PurchaseRequest.build(params(%{"lines" => lines}), @actor, lookups(self()))
      assert_received {:unit_read, @unit}
      assert_received {:unit_read, @unit_retired}
      refute_received {:unit_read, _}
    end

    test "a request missing everything makes no read" do
      PurchaseRequest.build(%{}, nil, lookups(self()))
      refute_received {:unit_read, _}
    end
  end

  test "T-V9: error output never contains a submitted value" do
    bad =
      params(%{
        "priority" => @secret,
        "justification" => 5,
        "required_date" => @secret,
        "department_id" => @secret,
        "lines" => [material(%{"quantity" => @secret, "unit_id" => @secret, "kind" => @secret})]
      })

    result = PurchaseRequest.build(bad, @actor, lookups())
    refute inspect(result) =~ @secret
    assert errors(result) != []
  end
end
