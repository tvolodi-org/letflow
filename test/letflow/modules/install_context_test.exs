defmodule Letflow.Modules.InstallContextTest do
  @moduledoc """
  GH 2541: `Letflow.Modules.InstallContext` is a struct whose required fields are
  enforced at construction. A missing key fails in `struct!/2`, not inside a module's
  `on_install/3`. Pure, no database: `async: true` is safe.
  """

  use ExUnit.Case, async: true

  alias Letflow.Modules.InstallContext

  @complete %{
    actor_id: "00000000-0000-0000-0000-000000000001",
    rationale: "test install",
    tenant_prefix: "tenant_test",
    pack_entity_definition_ids: %{}
  }

  describe "GH 2541 -- enforced keys" do
    test "a context with every required key builds" do
      ctx = struct!(InstallContext, @complete)

      assert %InstallContext{
               actor_id: actor_id,
               rationale: "test install",
               tenant_prefix: "tenant_test"
             } =
               ctx

      assert actor_id == @complete.actor_id
      assert ctx.pack_entity_definition_ids == %{}
    end

    test "each required key is enforced: a missing one raises ArgumentError at construction" do
      for key <- [:actor_id, :rationale, :tenant_prefix, :pack_entity_definition_ids] do
        attrs = Map.delete(@complete, key)

        error = assert_raise ArgumentError, fn -> struct!(InstallContext, attrs) end

        assert error.message =~ inspect(key)
      end
    end

    test "a context with no keys at all raises ArgumentError at construction" do
      assert_raise ArgumentError, fn -> struct!(InstallContext, []) end
    end
  end
end
