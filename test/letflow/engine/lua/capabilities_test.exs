defmodule Letflow.Engine.Lua.CapabilitiesTest do
  @moduledoc """
  Tests for `Letflow.Engine.Lua.Capabilities` (REQ-157, LUA-05/LUA-06 restated). See
  `test/specs/REQ-157.md` §1 and `lib/letflow/design/req157-lua-capability-model.md` §2,
  §9 for the full rationale and acceptance-criteria mapping.

  No Lua VM is involved in this file — pure grant-set/denial-shape logic, independent of
  any `Lua.t()`.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Engine.Lua.Capabilities

  describe "new/0, new/1, add/2, has?/2" do
    test "new/0 returns an empty grant set; has?/2 is false for any capability" do
      grants = Capabilities.new()

      refute Capabilities.has?(grants, "variable:read")
      refute Capabilities.has?(grants, "service:call:billing")
    end

    test "new/1 builds a grant set from a list" do
      grants = Capabilities.new(["variable:read", "audit:log"])

      assert Capabilities.has?(grants, "variable:read")
      assert Capabilities.has?(grants, "audit:log")
      refute Capabilities.has?(grants, "variable:write")
    end

    test "add/2 returns a new grant set containing the added capability; original unchanged" do
      original = Capabilities.new()
      updated = Capabilities.add(original, "variable:read")

      assert Capabilities.has?(updated, "variable:read")
      refute Capabilities.has?(original, "variable:read")
    end
  end

  describe "check/3" do
    test "returns :ok when the grant set has the required capability" do
      grants = Capabilities.new(["variable:read"])

      assert Capabilities.check(grants, :read_variable, "variable:read") == :ok
    end

    test "returns {:error, denial} with all three fields when the grant is missing" do
      grants = Capabilities.new()

      assert {:error, denial} = Capabilities.check(grants, :read_variable, "variable:read")
      assert denial.function == :read_variable
      assert denial.required == "variable:read"
      assert denial.granted == []
    end

    test "denial's granted field reflects a non-empty grant set that still lacks the required capability" do
      grants = Capabilities.new(["service:call:alpha"])

      assert {:error, denial} =
               Capabilities.check(grants, :call_service, "service:call:beta")

      assert denial.function == :call_service
      assert denial.required == "service:call:beta"
      assert denial.granted == ["service:call:alpha"]
    end

    test "returns :ok unconditionally when required is :none, regardless of grant set content" do
      assert Capabilities.check(Capabilities.new(), :now, :none) == :ok
      assert Capabilities.check(Capabilities.new(["variable:read"]), :fail, :none) == :ok
    end
  end

  describe "check!/3" do
    test "returns :ok on grant" do
      grants = Capabilities.new(["variable:read"])

      assert Capabilities.check!(grants, :read_variable, "variable:read") == :ok
    end

    test "returns :ok unconditionally when required is :none" do
      assert Capabilities.check!(Capabilities.new(), :now, :none) == :ok
    end

    test "raises Lua.RuntimeException on denial, carrying the three denial fields" do
      grants = Capabilities.new()

      exception =
        assert_raise Lua.RuntimeException, fn ->
          Capabilities.check!(grants, :read_variable, "variable:read")
        end

      assert exception.original[:function] == :read_variable
      assert exception.original[:capability_required] == "variable:read"
      assert exception.original[:capabilities_granted] == []
    end
  end

  describe "service_capability/1" do
    test "returns the exact string \"service:call:\" <> svc_id" do
      assert Capabilities.service_capability("billing") == "service:call:billing"
      assert Capabilities.service_capability("alpha") == "service:call:alpha"
    end

    test "does not escape or parse a svc_id containing a colon" do
      assert Capabilities.service_capability("weird:svc:id") == "service:call:weird:svc:id"
    end
  end
end
