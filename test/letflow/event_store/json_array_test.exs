defmodule Letflow.EventStore.JSONArrayTest do
  @moduledoc """
  Pure, no-I/O tests for `Letflow.EventStore.JSONArray`, the custom `Ecto.Type`
  REQ-043's ELIXIR-DEV added (flagged as a deviation from
  `lib/letflow/design/req043-instance-engine-schema.md` §2.4's literal
  `field(:current_nodes, :map, default: [])` text, since REVIEWER-approved) so
  `instance_projections.current_nodes` can hold a JSON **array** rather than the
  JSON **object** the built-in `:map` type's `cast/1`/`dump/1` require. See
  `test/specs/REQ-043.md` for the full test-case rationale.

  This file covers the module's three `Ecto.Type` callbacks directly and in
  isolation -- no schema, no changeset, no database. The real-Postgres
  round-trip (the part a pure unit test cannot prove: that the Postgrex
  encoder/decoder actually round-trips a list through a `jsonb` column tagged
  `type/0 == :map`) lives in `test/letflow/engine/migrations_test.exs`, mirroring
  the existing `schemas_test.exs`/`migrations_test.exs` pure/integration split
  established by REQ-023.

  `async: true` is safe: no database connection, no global `:telemetry` handler.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.EventStore.JSONArray

  describe "type/0" do
    test "reports :map -- identical jsonb wire encoding to a plain :map field" do
      assert JSONArray.type() == :map
    end
  end

  describe "cast/1" do
    test "accepts a list, unchanged" do
      assert JSONArray.cast([]) == {:ok, []}
      assert JSONArray.cast([%{"node_id" => "n1"}]) == {:ok, [%{"node_id" => "n1"}]}
    end

    test "rejects a map -- the built-in :map type's own failure mode does not apply here, but a bare JSON object is still not a JSON array" do
      assert JSONArray.cast(%{}) == :error
      assert JSONArray.cast(%{"a" => 1}) == :error
    end

    test "rejects a scalar" do
      assert JSONArray.cast("not a list") == :error
      assert JSONArray.cast(1) == :error
      assert JSONArray.cast(nil) == :error
    end
  end

  describe "load/1" do
    test "accepts a list read back from the database" do
      assert JSONArray.load([%{"node_id" => "n1", "branch_id" => "b1"}]) ==
               {:ok, [%{"node_id" => "n1", "branch_id" => "b1"}]}
    end

    test "rejects a non-list -- defends against a future column-type change silently corrupting reads" do
      assert JSONArray.load(%{}) == :error
    end
  end

  describe "dump/1" do
    test "accepts a list for writing to jsonb" do
      assert JSONArray.dump([1, 2, 3]) == {:ok, [1, 2, 3]}
    end

    test "rejects a map -- this is the exact failure the built-in :map type's dump/1 (same_map/1) does NOT have, and JSONArray must not gain the mirror-image bug of accepting the wrong shape" do
      assert JSONArray.dump(%{"a" => 1}) == :error
    end
  end
end
