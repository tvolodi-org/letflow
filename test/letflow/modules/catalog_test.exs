defmodule Letflow.Modules.CatalogTest do
  @moduledoc """
  REQ-400 AC2 — `Letflow.Modules.Catalog`'s module list/lookup in the test env,
  and AC3 — the six manifest-validation rules. See `test/specs/REQ-400.md` for
  the full rationale.

  Pure, no I/O: `Catalog` reads only compile-time `Application.compile_env/3`
  data and `Authorization.roles/0`/`permissions/0` (also pure, compile-time
  module attributes) — no `Letflow.Repo` connection is checked out, so
  `async: true` is safe.
  """

  use ExUnit.Case, async: true

  alias Letflow.Modules.Catalog

  # A manifest that passes all six validation rules on its own (mirrors the
  # real fixture's own manifest shape, design §4.2) -- each bad-manifest test
  # below overrides exactly one field to break exactly one rule.
  defp valid_manifest do
    %{
      id: "probe",
      version: "0.1.0",
      depends_on: [],
      pack: nil,
      permissions: [:ProbeRead],
      role_grants: %{TASK_WORKER: [:ProbeRead]},
      required_roles: [],
      settings_schema: nil,
      route_policies: [{"GET", "/items/:id", :ProbeRead}]
    }
  end

  describe "REQ-400 AC2 — Catalog module list and lookup" do
    test "entry_modules/0 returns the registered test-only fixtures, in config order" do
      # REQ-402 design §4.2/§9: appends FixtureDependent (depends_on
      # rejection coverage) and FixtureFailingInstall (on_install/2
      # rollback coverage, design §9 open question 1 option (a)) to
      # config/test.exs's :modules list, alongside REQ-400's original
      # Fixture entry. REQ-408 prepends Letflow.Modules.Exam (the real
      # exam module). GH 2531 (decision 0052 D3/D7) appends FixtureFkPack,
      # FixtureFkPackFailing and FixtureCtxRecorder (on_install/3 coverage), so
      # the full list in config order is:
      assert Catalog.entry_modules() == [
               Letflow.Modules.Exam,
               Letflow.Modules.Fixture,
               Letflow.Modules.FixtureDependent,
               Letflow.Modules.FixtureFailingInstall,
               Letflow.Modules.FixtureFkPack,
               Letflow.Modules.FixtureFkPackFailing,
               Letflow.Modules.FixtureCtxRecorder
             ]
    end

    test "fetch/1 looks the fixture up by its id string" do
      assert Catalog.fetch("fixture") == {:ok, Letflow.Modules.Fixture}
    end

    test "fetch/1 returns {:error, :not_found} for an unregistered id" do
      assert Catalog.fetch("does-not-exist") == {:error, :not_found}
    end

    test "config/config.exs registers exactly [Letflow.Modules.Exam]" do
      # REQ-408 added Letflow.Modules.Exam to config/config.exs; the test
      # env (config/test.exs) adds the fixture modules for test coverage.
      config_source = File.read!(Path.join([File.cwd!(), "config", "config.exs"]))

      assert config_source =~ ~r/config :letflow, :modules, \[Letflow\.Modules\.Exam\]/
    end
  end

  describe "REQ-400 AC3 — manifest validation, six deliberately-bad inline manifests" do
    test "rejects a role_grants key not in Authorization.roles/0" do
      manifest = %{valid_manifest() | role_grants: %{NOT_A_ROLE: [:ProbeRead]}}

      assert Catalog.validate(manifest) == {:error, {:unknown_role, :NOT_A_ROLE}}
    end

    test "rejects a role_grants value not in the module's own permissions" do
      manifest = %{valid_manifest() | role_grants: %{TASK_WORKER: [:NotDeclared]}}

      assert Catalog.validate(manifest) ==
               {:error, {:ungranted_permission_declared, :NotDeclared}}
    end

    test "rejects a permissions atom that collides with a core permission" do
      # role_grants cleared so this manifest isolates rule 3 -- otherwise
      # rule 2 (:ungranted_permission_declared) would fire first, since
      # role_grants still points at the now-removed :ProbeRead permission.
      manifest = %{valid_manifest() | permissions: [:InstancesRead], role_grants: %{}}

      assert Catalog.validate(manifest) ==
               {:error, {:core_permission_collision, :InstancesRead}}
    end

    test "rejects a depends_on id that is not registered" do
      manifest = %{valid_manifest() | depends_on: ["nonexistent"]}

      assert Catalog.validate(manifest) ==
               {:error, {:unknown_dependency, "nonexistent"}}
    end

    test "rejects a duplicate module id" do
      manifest_a = %{valid_manifest() | id: "dup"}
      manifest_b = %{valid_manifest() | id: "dup"}

      # Both distinct manifests are passed in the known set (design §3.2 rule
      # 5's "pair appended" shape) -- passing only [manifest_b] would let
      # validate_unique_id/2 mistake manifest_b's matching id for "manifest_a
      # already counted", undercounting the real duplicate.
      assert Catalog.validate(manifest_a, [manifest_a, manifest_b]) ==
               {:error, {:duplicate_module_id, "dup"}}
    end

    test "rejects a route_policies entry whose permission is undeclared" do
      manifest = %{valid_manifest() | route_policies: [{"GET", "/x", :NotDeclared}]}

      assert Catalog.validate(manifest) ==
               {:error, {:undeclared_route_permission, :NotDeclared}}
    end

    test "returns :ok for every module the real Catalog lists" do
      manifests = Catalog.all_manifests()

      assert manifests != []

      for manifest <- manifests do
        assert Catalog.validate(manifest) == :ok,
               "expected #{inspect(manifest.id)}'s manifest to pass validation"
      end
    end

    # REQ-401 §1a regression: Authorization.permissions/0 now folds every
    # registered module's own permissions (including the manifest under
    # test) into its result, so validate_no_core_permission_collision/1 was
    # repointed to Authorization.core_permissions/0 -- a closed, core-only
    # list that never contains a module's own atoms. This proves the check
    # still catches a GENUINE core collision after being repointed, not just
    # that it stopped false-flagging every module against itself.
    test "still rejects a permissions atom that collides with a real core permission, after the core_permissions/0 repoint" do
      manifest = %{valid_manifest() | permissions: [:DefinitionsRead], role_grants: %{}}

      assert Catalog.validate(manifest) ==
               {:error, {:core_permission_collision, :DefinitionsRead}}
    end
  end
end
