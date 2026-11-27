defmodule Letflow.PlatformFunctions.ModuleTenantRuleTest do
  @moduledoc """
  D-204 (the module-process conversion, the team record
  `docs/design-module-process-conversion.md` section 1.2; the platform task P1
  of section 6.1): the INSTALLED-MODULE tenant rule of a module family entry.

  The platform family runs only in the platform tenant (INV-10). A MODULE
  family entry runs somewhere else: in the tenant that has the module
  INSTALLED, with the compiled module's manifest hash accepted. That is the
  check `Letflow.Definitions.ModuleWrites` does today for the OWNER STAMP,
  moved from the stamp to the entry (a tenant-edited definition has no stamp,
  so the stamp could not carry the rule).

  This test proves the rule answers:

    * `:ok` when the module is installed in the tenant and the compiled
      manifest hash is the installed one (or an accepted earlier one);
    * `{:error, :module_write_module_not_installed}` when it is not;
    * `{:error, :module_write_hash_mismatch}` when the install row carries no
      manifest hash;
    * `{:error, :module_write_upgrade_required}` when the tenant has another
      module version than the one compiled into this build;
    * `{:error, :module_call_tenant_rule_not_applicable}` for a PLATFORM
      family entry -- that entry keeps its own rule, and the platform family
      is NOT affected by this one;
    * never a raise (INV-8): every answer is `:ok` or a code out of
      `codes/0`.

  `async: false`: tenant provisioning switches the Ecto sandbox to `:auto`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.TenantModule
  alias Letflow.PlatformFunctions.Catalog, as: PlatformCatalog
  alias Letflow.PlatformFunctions.ModuleTenantRule
  alias Letflow.Repo

  @module_id "fixture_ledger_post"

  setup do
    %{tenant: tenant, schema: schema} = Fx.tenant_case!("d204-tenant-rule")

    %{schema: schema, tenant_id: tenant.tenant_id}
  end

  describe "the rule of a module family entry" do
    test "D-204-P1 the module is not installed in the tenant: the call is refused", %{
      schema: schema
    } do
      {:ok, entry} = PlatformCatalog.fetch("#{@module_id}.post_alpha")

      assert {:error, :module_write_module_not_installed} =
               ModuleTenantRule.check(entry, schema)
    end

    test "D-204-P1 the module is installed with the compiled hash: the call may run", %{
      schema: schema
    } do
      {:ok, entry} = PlatformCatalog.fetch("#{@module_id}.post_alpha")
      install_module!(schema, @module_id, compiled_hash())

      assert ModuleTenantRule.check(entry, schema) == :ok
    end

    test "D-204-P1 the install row carries no manifest hash: the call is refused", %{
      schema: schema
    } do
      {:ok, entry} = PlatformCatalog.fetch("#{@module_id}.post_alpha")
      install_module!(schema, @module_id, nil)

      assert {:error, :module_write_hash_mismatch} = ModuleTenantRule.check(entry, schema)
    end

    test "D-204-P1 the tenant has another module version than this build: the call is refused",
         %{schema: schema} do
      {:ok, entry} = PlatformCatalog.fetch("#{@module_id}.post_alpha")
      install_module!(schema, @module_id, String.duplicate("a", 64))

      assert {:error, :module_write_upgrade_required} = ModuleTenantRule.check(entry, schema)
    end

    test "D-204-P1 the compiled hash is an ACCEPTED earlier one: the call may run", %{
      schema: schema
    } do
      {:ok, entry} = PlatformCatalog.fetch("#{@module_id}.post_alpha")
      install_module!(schema, @module_id, String.duplicate("a", 64))

      Letflow.ModuleWritesFixture.set_accepted_hashes!(schema, @module_id, [compiled_hash()])

      assert ModuleTenantRule.check(entry, schema) == :ok
    end

    test "D-204-P1 an uninstalled module is refused like a module that was never installed",
         %{schema: schema} do
      {:ok, entry} = PlatformCatalog.fetch("#{@module_id}.post_alpha")
      install_module!(schema, @module_id, compiled_hash())

      Repo.update_all(
        from(m in TenantModule, where: m.module_id == ^@module_id),
        [set: [status: :uninstalled]],
        prefix: schema
      )

      assert {:error, :module_write_module_not_installed} =
               ModuleTenantRule.check(entry, schema)
    end
  end

  describe "the platform family is not affected" do
    test "D-204-P1 a platform entry is not a module entry: the module rule does not apply", %{
      schema: schema
    } do
      {:ok, entry} = PlatformCatalog.fetch("tenant.create")

      assert entry.platform_tenant_only == true

      assert {:error, :module_call_tenant_rule_not_applicable} =
               ModuleTenantRule.check(entry, schema)
    end

    test "D-204-P1 the platform family keeps its own rule (the platform tenant only, INV-10)" do
      # The module rule is a NEW rule beside the platform one, never a
      # relaxation of it: every platform entry is still platform_tenant_only.
      for name <- PlatformCatalog.names() do
        {:ok, entry} = PlatformCatalog.fetch(name)

        if entry.family == :platform do
          assert entry.platform_tenant_only == true
        end
      end
    end
  end

  describe "never raises" do
    test "D-204-P1 a rule that cannot answer answers a code, never a raise", %{schema: schema} do
      {:ok, entry} = PlatformCatalog.fetch("#{@module_id}.post_alpha")

      assert {:error, :module_call_tenant_rule_not_applicable} =
               ModuleTenantRule.check(entry, :not_a_prefix)

      assert {:error, :module_call_tenant_rule_not_applicable} =
               ModuleTenantRule.check(:not_an_entry, schema)
    end

    test "D-204-P1 the codes are the closed list of the rule" do
      assert ModuleTenantRule.codes() == [
               :module_call_tenant_rule_not_applicable,
               :module_write_module_not_installed,
               :module_write_hash_mismatch,
               :module_write_upgrade_required
             ]
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────────────────────

  defp compiled_hash do
    {:ok, hash} = Catalog.manifest_hash(@module_id)
    hash
  end

  # The tenant_modules row of an installed module, inserted directly: this test
  # is about the RULE, not about the install path (the pack install of this
  # module is the `Letflow.LedgerPostFixture`'s business).
  defp install_module!(schema, module_id, hash) do
    %TenantModule{}
    |> TenantModule.insert_changeset(%{
      module_id: module_id,
      version: "0.1.0",
      installed_at: DateTime.truncate(DateTime.utc_now(), :microsecond),
      settings: %{},
      manifest_hash: hash
    })
    |> Repo.insert!(prefix: schema)
  end
end
