defmodule Letflow.Scripts.FormValidationCheckMigrationTest do
  @moduledoc """
  REQ-569 / GH #3246: the tenant migration that widens the `script_rules_hook_kind` CHECK to allow
  `form_validation`. No table, column or row changes. `async: false` (tenant provisioning and DDL).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Scripts.Hash
  alias Letflow.Scripts.ScriptRule
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @version 20_261_026_300_001
  @module Letflow.Repo.Migrations.WidenScriptRulesHookKindFormValidation

  defp script!(schema, hook_kind) do
    key = "mig_#{System.unique_integer([:positive])}"
    manifest = Letflow.Support.ScriptTaskFixture.closed_manifest()
    cases = [%{"name" => "c1", "input" => %{}, "expect" => %{"fail" => "x"}}]

    Repo.insert!(
      %ScriptRule{
        key: key,
        version: 1,
        hook_kind: hook_kind,
        status: :draft,
        source: "return {}",
        manifest: manifest,
        test_cases: cases,
        sha256: Hash.compute(key, 1, hook_kind, manifest, cases, "return {}"),
        contributors: [Ecto.UUID.generate()]
      },
      prefix: schema
    )
  end

  setup do
    {:ok, schema: TenantFixture.provisioned_tenant!(slug_prefix: "r569-mig").schema_name}
  end

  test "M-F1 a provisioned tenant stores form_validation; an unknown kind still violates the CHECK",
       %{schema: schema} do
    assert %ScriptRule{hook_kind: "form_validation"} = script!(schema, "form_validation")
    assert %ScriptRule{hook_kind: "service_task"} = script!(schema, "service_task")
    assert %ScriptRule{hook_kind: "entity_write"} = script!(schema, "entity_write")

    assert_raise Ecto.ConstraintError, ~r/script_rules_hook_kind/, fn ->
      script!(schema, "bogus")
    end
  end

  test "M-F2 the migration is registered for new tenants" do
    assert {@version, @module} in TenantProvisioning.tenant_scoped_migrations()
  end

  test "M-F3 down refuses form_validation again, up restores it (existing tenant)", %{
    schema: schema
  } do
    Ecto.Migrator.run(Repo, [{@version, @module}], :down, all: true, prefix: schema, log: false)

    assert_raise Ecto.ConstraintError, ~r/script_rules_hook_kind/, fn ->
      script!(schema, "form_validation")
    end

    assert %ScriptRule{} = script!(schema, "entity_write")

    Ecto.Migrator.run(Repo, [{@version, @module}], :up, all: true, prefix: schema, log: false)
    assert %ScriptRule{} = script!(schema, "form_validation")
  end
end
