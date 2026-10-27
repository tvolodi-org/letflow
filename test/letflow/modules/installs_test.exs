defmodule Letflow.Modules.InstallsTest do
  @moduledoc """
  Tests for REQ-402 (`lib/letflow/design/req402-tenant-modules-install-context.md`)
  AC1-AC7 — `Letflow.Modules.Installs.install/3` and `list_installed/1`.

  Uses `Letflow.DataCase` (real Postgres) and `Letflow.TenantFixture` for real
  provisioned tenant schemas, mirroring
  `test/letflow/definitions/solution_pack_test.exs`'s own conventions.
  `async: false` -- same reasoning as that file (tenant provisioning/migration
  replay needs `Sandbox.mode(Letflow.Repo, :auto)`).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Modules.Fixture.MarkerStore
  alias Letflow.Modules.Installs
  alias Letflow.Modules.TenantModule
  alias Letflow.TenantFixture

  describe "AC2 -- install/3 happy path, list_installed/1" do
    test "install(\"fixture\", actor_id, prefix: p) returns {:ok, _}, list_installed/1 returns one entry, on_install/2 marker is readable" do
      %{schema_name: prefix} = TenantFixture.provisioned_tenant!(slug_prefix: "req402-ac2")
      actor_id = Ecto.UUID.generate()

      assert {:ok, %TenantModule{module_id: "fixture", version: "0.1.0"}} =
               Installs.install("fixture", actor_id,
                 prefix: prefix,
                 rationale: "test: module install"
               )

      assert [%TenantModule{module_id: "fixture", version: "0.1.0"}] =
               Installs.list_installed(prefix: prefix)

      assert {:ok, _settings} = MarkerStore.get(prefix)
    end
  end

  describe "AC3 -- tenant isolation" do
    test "installing into tenant A leaves tenant B's tenant_modules empty" do
      %{schema_name: prefix_a} = TenantFixture.provisioned_tenant!(slug_prefix: "req402-ac3-a")
      %{schema_name: prefix_b} = TenantFixture.provisioned_tenant!(slug_prefix: "req402-ac3-b")
      actor_id = Ecto.UUID.generate()

      assert {:ok, _} =
               Installs.install("fixture", actor_id,
                 prefix: prefix_a,
                 rationale: "test: module install"
               )

      assert length(Installs.list_installed(prefix: prefix_a)) == 1
      assert Installs.list_installed(prefix: prefix_b) == []
    end
  end

  describe "AC4 -- rejection cases, no row written" do
    test "unknown module id -> {:error, :unknown_module}, no row written" do
      %{schema_name: prefix} = TenantFixture.provisioned_tenant!(slug_prefix: "req402-ac4-unk")
      actor_id = Ecto.UUID.generate()

      assert {:error, :unknown_module} =
               Installs.install("does_not_exist", actor_id,
                 prefix: prefix,
                 rationale: "test: module install"
               )

      assert Installs.list_installed(prefix: prefix) == []
    end

    test "already installed -> {:error, :already_installed} on the second call, one row remains" do
      %{schema_name: prefix} = TenantFixture.provisioned_tenant!(slug_prefix: "req402-ac4-dup")
      actor_id = Ecto.UUID.generate()

      assert {:ok, _} =
               Installs.install("fixture", actor_id,
                 prefix: prefix,
                 rationale: "test: module install"
               )

      assert {:error, :already_installed} =
               Installs.install("fixture", actor_id,
                 prefix: prefix,
                 rationale: "test: module install"
               )

      assert length(Installs.list_installed(prefix: prefix)) == 1
    end

    test "missing dependency -> {:error, {:dependency_not_installed, \"fixture\"}}, no row written" do
      %{schema_name: prefix} = TenantFixture.provisioned_tenant!(slug_prefix: "req402-ac4-dep")
      actor_id = Ecto.UUID.generate()

      assert {:error, {:dependency_not_installed, "fixture"}} =
               Installs.install("fixture_dependent", actor_id,
                 prefix: prefix,
                 rationale: "test: module install"
               )

      assert Installs.list_installed(prefix: prefix) == []
    end

    test "installing the dependency first lets the dependent module install successfully" do
      %{schema_name: prefix} = TenantFixture.provisioned_tenant!(slug_prefix: "req402-ac4-ok")
      actor_id = Ecto.UUID.generate()

      assert {:ok, _} =
               Installs.install("fixture", actor_id,
                 prefix: prefix,
                 rationale: "test: module install"
               )

      assert {:ok, %TenantModule{module_id: "fixture_dependent"}} =
               Installs.install("fixture_dependent", actor_id,
                 prefix: prefix,
                 rationale: "test: module install"
               )

      assert length(Installs.list_installed(prefix: prefix)) == 2
    end
  end

  describe "AC5 -- config/test.exs registration" do
    test "config/test.exs registers FixtureDependent alongside Fixture" do
      config_source = File.read!(Path.join([File.cwd!(), "config", "test.exs"]))

      assert config_source =~ "Letflow.Modules.FixtureDependent"
    end
  end

  describe "AC6 -- on_install/2 failure rolls back the whole transaction" do
    test "when on_install/2 returns an error, list_installed/1 returns no row for that module afterwards" do
      %{schema_name: prefix} = TenantFixture.provisioned_tenant!(slug_prefix: "req402-ac6")
      actor_id = Ecto.UUID.generate()

      assert {:error, {:on_install_failed, :boom}} =
               Installs.install("fixture_failing_install", actor_id,
                 prefix: prefix,
                 rationale: "test: module install"
               )

      assert Installs.list_installed(prefix: prefix) == []
    end
  end

  describe "R8 -- uninstall never deletes (REQ-578 criterion 10)" do
    test "installs.ex contains no Repo.delete or delete_all" do
      source = File.read!(Path.join([File.cwd!(), "lib", "letflow", "modules", "installs.ex"]))

      refute source =~ "Repo.delete"
      refute source =~ "delete_all"
    end
  end

  describe "AC7 -- prefix-only tenant identification (grep contract)" do
    test "install/3 and list_installed/1 take no tenant_id or schema parameter" do
      source = File.read!(Path.join([File.cwd!(), "lib", "letflow", "modules", "installs.ex"]))

      for line <- String.split(source, "\n"),
          String.match?(line, ~r/def (install|list_installed)\(/) do
        refute line =~ "tenant_id"
        refute line =~ ~r/\bschema\b/
      end
    end
  end
end
