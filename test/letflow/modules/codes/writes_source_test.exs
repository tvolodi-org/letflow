defmodule Letflow.Modules.Codes.WritesSourceTest do
  @moduledoc """
  GH #3615 / REQ-663 source checks (R1, A1, X3, D1): the precondition names, the advisory lock keyed
  by the tenant and the text `codes` as a bound parameter, no tenant id argument, and the moduledoc
  naming the five functions. No database.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  @root Path.expand("../../../..", __DIR__)
  @writes File.read!(Path.join(@root, "lib/letflow/modules/codes/writes.ex"))
  @codes File.read!(Path.join(@root, "lib/letflow/modules/codes/codes.ex"))

  defp definition(name),
    do: Path.join(@root, "priv/modules/codes/entity_definitions/#{name}.json") |> File.read!()

  test "R1: the three definition files declare the type, field and status names the writers use" do
    tag = definition("code_tag")

    for word <- ~w(value kind status not_assigned assigned retired barcode qr epc tid),
        do: assert(tag =~ word)

    for word <- ~w(code_id target_type target_id assigned_at assigned_by released_at released_by),
        do: assert(definition("code_assignment") =~ word)

    for word <- ~w(code_id old_value new_value changed_at changed_by),
        do: assert(definition("code_value_change") =~ word)
  end

  test "A1: the lock key is the tenant schema plus codes, passed as a bound parameter" do
    assert @writes =~ ~s|pg_advisory_xact_lock(hashtextextended($1, 0))|
    assert @writes =~ ~s|[prefix <> ":codes"]|
    refute @writes =~ ~r/Repo\.query!?\([^\n]*\#\{/
  end

  test "X3: no writer takes a tenant id, the only tenant input is prefix" do
    for {name, arity} <- [
          receive_codes: 3,
          assign_code: 5,
          release_code: 3,
          retire_code: 3,
          change_code_value: 4
        ] do
      assert Code.ensure_loaded?(Letflow.Modules.Codes)
      assert function_exported?(Letflow.Modules.Codes, name, arity)
    end

    refute @writes =~ "tenant_id"
  end

  test "D1: the moduledoc names the five functions and the three target types" do
    for word <-
          ~w(receive_codes/3 assign_code/5 release_code/3 retire_code/3 change_code_value/4 location_node catalog_item catalog_lot),
        do: assert(@codes =~ word)

    refute @codes =~ "no write\n  functions"
  end
end
