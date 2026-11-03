defmodule Letflow.Modules.DefmanifestTest do
  @moduledoc """
  ISS-0806 AC1 — `defmanifest/1` raises a `CompileError` at macro-expansion
  time when a `role_grants` value atom is absent from `permissions`.

  Tests use `Code.compile_string/1` to exercise the compile-time check in
  isolation, so no running application or database is needed (`async: true`).
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  # F3 fix (ISS-0806 WF03-ISS0806-20260925): each negative-path compile_string
  # call now uses a distinct module name to eliminate the async: true race on
  # shared module-name redefinition that REVIEWER flagged.
  @bad_module_source_raises """
  defmodule Letflow.Test.BadManifestModule1 do
    @behaviour Letflow.Modules.Module
    import Letflow.Modules.Module, only: [defmanifest: 1]

    defmanifest(
      id: "bad",
      version: "0.0.1",
      depends_on: [],
      pack: nil,
      permissions: [:DeclaredPerm],
      role_grants: %{TASK_WORKER: [:UndeclaredPerm]},
      required_roles: [],
      settings_schema: nil,
      route_policies: []
    )
  end
  """

  @bad_module_source_names_caller """
  defmodule Letflow.Test.BadManifestModule2 do
    @behaviour Letflow.Modules.Module
    import Letflow.Modules.Module, only: [defmanifest: 1]

    defmanifest(
      id: "bad",
      version: "0.0.1",
      depends_on: [],
      pack: nil,
      permissions: [:DeclaredPerm],
      role_grants: %{TASK_WORKER: [:UndeclaredPerm]},
      required_roles: [],
      settings_schema: nil,
      route_policies: []
    )
  end
  """

  @good_module_source """
  defmodule Letflow.Test.GoodManifestModule do
    @behaviour Letflow.Modules.Module
    import Letflow.Modules.Module, only: [defmanifest: 1]

    defmanifest(
      id: "good",
      version: "0.0.1",
      depends_on: [],
      pack: nil,
      permissions: [:DeclaredPerm],
      role_grants: %{TASK_WORKER: [:DeclaredPerm]},
      required_roles: [],
      settings_schema: nil,
      route_policies: []
    )
  end
  """

  describe "ISS-0806 AC1 — compile-time role_grants ⊆ permissions check" do
    test "raises CompileError when a role_grants atom is absent from permissions" do
      error =
        assert_raise CompileError, fn ->
          Code.compile_string(@bad_module_source_raises)
        end

      assert error.description =~
               "role_grants atom :UndeclaredPerm is not declared in permissions"
    end

    test "CompileError message names the caller module" do
      error =
        assert_raise CompileError, fn ->
          Code.compile_string(@bad_module_source_names_caller)
        end

      assert error.description =~ "Letflow.Test.BadManifestModule2"
    end

    test "compiles cleanly when all role_grants atoms are in permissions" do
      # Should not raise — if it does, the test fails automatically.
      assert [{Letflow.Test.GoodManifestModule, _binary}] =
               Code.compile_string(@good_module_source)
    end

    test "Letflow.Modules.Fixture (uses defmanifest) satisfies @behaviour and returns correct manifest" do
      # AC1 positive path via the fixture that already uses defmanifest after ISS-0806.
      manifest = Letflow.Modules.Fixture.manifest()

      assert manifest.id == "fixture"
      assert manifest.permissions == [:FixtureRead]
      assert manifest.role_grants == %{TASK_WORKER: [:FixtureRead]}
      assert manifest.route_policies == [{"GET", "/items/:id", :FixtureRead}]
    end
  end
end
