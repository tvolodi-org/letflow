defmodule Letflow.Modules.InstallsPutSettingsTest do
  @moduledoc """
  Tests for `Letflow.Modules.Installs.put_settings/3` (REQ-414).

  AC6 — module with `settings_schema: nil` accepts `%{}` and rejects any
  non-empty map. Uses `fixture_dependent` (registered in `config/test.exs`),
  whose manifest has `settings_schema: nil`.

  Also tests the happy path (valid schema → ok), and error paths
  (module not installed, schema validation failures) at the context layer,
  independent of HTTP.

  `async: false` — tenant provisioning needs `Sandbox.mode(:auto)`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Modules.Installs
  alias Letflow.TenantFixture

  # ═══════════════════════════════════════════════════════════════════════
  # Happy path — fixture module with a real schema
  # ═══════════════════════════════════════════════════════════════════════

  describe "put_settings/3 -- fixture module (settings_schema present)" do
    test "valid settings conforming to schema → {:ok, updated tenant_module}" do
      %{schema_name: prefix} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req414-ps-ok")

      actor_id = Ecto.UUID.generate()

      {:ok, _} =
        Installs.install("fixture", actor_id, prefix: prefix, rationale: "test: module install")

      assert {:ok, tm} =
               Installs.put_settings("fixture", %{"greeting" => "hello"}, prefix: prefix)

      assert tm.settings == %{"greeting" => "hello"}
    end

    test "empty map → {:ok, _} (empty object satisfies the schema)" do
      %{schema_name: prefix} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req414-ps-empty")

      actor_id = Ecto.UUID.generate()

      {:ok, _} =
        Installs.install("fixture", actor_id, prefix: prefix, rationale: "test: module install")

      assert {:ok, tm} = Installs.put_settings("fixture", %{}, prefix: prefix)
      assert tm.settings == %{}
    end

    test "wrong type for declared property → {:error, {:settings_validation_failed, _failures}}" do
      %{schema_name: prefix} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req414-ps-type")

      actor_id = Ecto.UUID.generate()

      {:ok, _} =
        Installs.install("fixture", actor_id, prefix: prefix, rationale: "test: module install")

      assert {:error, {:settings_validation_failed, failures}} =
               Installs.put_settings("fixture", %{"greeting" => 99}, prefix: prefix)

      assert is_list(failures)
      assert Enum.any?(failures, fn f -> f.constraint == "type" end)
    end

    test "undeclared key (additionalProperties: false) → {:error, {:settings_validation_failed, _}}" do
      %{schema_name: prefix} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req414-ps-addl")

      actor_id = Ecto.UUID.generate()

      {:ok, _} =
        Installs.install("fixture", actor_id, prefix: prefix, rationale: "test: module install")

      assert {:error, {:settings_validation_failed, failures}} =
               Installs.put_settings("fixture", %{"unknown_key" => "value"}, prefix: prefix)

      assert is_list(failures)
      assert Enum.any?(failures, fn f -> f.constraint == "additionalProperties" end)
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC6 — nil settings_schema (fixture_dependent module)
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC6 -- put_settings/3 with settings_schema: nil (fixture_dependent)" do
    test "empty map %{} is accepted when settings_schema is nil" do
      %{schema_name: prefix} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req414-ac6-nil-ok")

      actor_id = Ecto.UUID.generate()
      # fixture_dependent depends on fixture; install both
      {:ok, _} =
        Installs.install("fixture", actor_id, prefix: prefix, rationale: "test: module install")

      {:ok, _} =
        Installs.install("fixture_dependent", actor_id,
          prefix: prefix,
          rationale: "test: module install"
        )

      assert {:ok, tm} =
               Installs.put_settings("fixture_dependent", %{}, prefix: prefix)

      assert tm.settings == %{}
    end

    test "non-empty map is rejected when settings_schema is nil" do
      %{schema_name: prefix} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req414-ac6-nil-err")

      actor_id = Ecto.UUID.generate()

      {:ok, _} =
        Installs.install("fixture", actor_id, prefix: prefix, rationale: "test: module install")

      {:ok, _} =
        Installs.install("fixture_dependent", actor_id,
          prefix: prefix,
          rationale: "test: module install"
        )

      assert {:error, {:settings_validation_failed, :no_schema}} =
               Installs.put_settings("fixture_dependent", %{"some_key" => "value"},
                 prefix: prefix
               )
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Error paths — unknown module; module not installed in tenant
  # ═══════════════════════════════════════════════════════════════════════

  describe "put_settings/3 -- error paths" do
    test "unknown module id → {:error, {:module_not_installed, module_id}}" do
      %{schema_name: prefix} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req414-ps-unk")

      assert {:error, {:module_not_installed, "does_not_exist"}} =
               Installs.put_settings("does_not_exist", %{}, prefix: prefix)
    end

    test "known module not installed in tenant → {:error, {:module_not_installed, module_id}}" do
      %{schema_name: prefix} =
        TenantFixture.provisioned_tenant!(slug_prefix: "req414-ps-notinst")

      # fixture is a known module but has not been installed in this tenant
      assert {:error, {:module_not_installed, "fixture"}} =
               Installs.put_settings("fixture", %{}, prefix: prefix)
    end
  end
end
