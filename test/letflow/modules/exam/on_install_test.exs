defmodule Letflow.Modules.Exam.OnInstallTest do
  @moduledoc """
  REQ-411 AC2 — installs the exam module into a fresh tenant via
  `Letflow.Modules.Installs.install/3` and asserts:

    1. The pack's entity definitions exist as `:inactive` rows.
    2. The answer-key `entity_field_restrictions` rows are seeded by
       `on_install/2` (called inside the Installs.install/3 transaction).

  This is the authoritative test that the module-install path provides the
  same protection that `SolutionPack.install/3`'s now-deleted
  `seed_pack_specific_field_restrictions/2` hook used to provide.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.EventTypes
  alias Letflow.Modules.Exam
  alias Letflow.Modules.Installs
  alias Letflow.Repo
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning.ColumnPromotion

  defp tenant_ctx do
    fixture =
      TenantFixture.provisioned_tenant!(
        slug_prefix: "req411-on-install",
        display_name: "REQ-411 on_install Test Tenant"
      )

    on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^fixture.tenant_id))

      Repo.delete_all(
        from(b in SolutionPackArtefactBase, where: b.tenant_id == ^fixture.tenant_id)
      )

      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^fixture.tenant_id))
    end)

    {:ok, _seeded} = EventTypes.seed!(fixture.schema_name)

    %{
      tenant_id: fixture.tenant_id,
      schema_name: fixture.schema_name
    }
  end

  describe "Installs.install/3 for the exam module" do
    test "installs the pack entity definitions as :inactive and seeds answer-key restrictions" do
      ctx = tenant_ctx()
      actor_id = Ecto.UUID.generate()

      # AC2: a real Installs.install/3 call -- on_install/2 is NOT called
      # directly anywhere in this test.
      assert {:ok, tenant_module} =
               Installs.install("exam", actor_id,
                 prefix: ctx.schema_name,
                 rationale: "test: module install"
               )

      assert tenant_module.module_id == "exam"

      # Pack's entity definitions exist (created as :inactive by SolutionPack.install/3).
      entity_types =
        Repo.all(
          from(ed in EntityDefinition, select: ed.name),
          prefix: ctx.schema_name
        )

      # The bilimbaga pack ships these entity types (REQ-326 / REQ-327).
      for expected_type <- ~w(category question answer_option exam exam_section) do
        assert expected_type in entity_types,
               "expected entity type #{expected_type} to exist after module install"
      end

      # All installed entity definitions are :inactive (0026 §2).
      statuses =
        Repo.all(
          from(ed in EntityDefinition, select: ed.status),
          prefix: ctx.schema_name
        )

      assert Enum.all?(statuses, &(&1 == :inactive)),
             "expected all entity definitions to be :inactive after pack install"

      # Answer-key field restrictions are seeded by on_install/2.
      restrictions =
        Repo.all(
          from(r in "entity_field_restrictions",
            select: {r.entity_type, r.field_name}
          ),
          prefix: ctx.schema_name
        )

      expected_restrictions = Exam.answer_key_fields()

      for {entity_type, field_name} <- expected_restrictions do
        assert {entity_type, field_name} in restrictions,
               "expected restriction for #{entity_type}.#{field_name} to be seeded by on_install/2"
      end

      # GH #2682 / REQ-511: the literal list, not only the module's own function: the four REQ-411
      # pairs plus session.exam_snapshot -- FIVE rows, and no other row.
      assert Enum.sort(restrictions) == [
               {"answer_option", "is_correct"},
               {"answer_option", "likert_polarity"},
               {"answer_option", "likert_weight"},
               {"question", "explanation"},
               {"session", "exam_snapshot"}
             ]
    end

    test "on_install/2 is idempotent -- calling Installs.install/3 twice on the same module raises :already_installed, not a DB error" do
      ctx = tenant_ctx()
      actor_id = Ecto.UUID.generate()

      assert {:ok, _} =
               Installs.install("exam", actor_id,
                 prefix: ctx.schema_name,
                 rationale: "test: module install"
               )

      assert {:error, :already_installed} =
               Installs.install("exam", actor_id,
                 prefix: ctx.schema_name,
                 rationale: "test: module install"
               )
    end
  end
end
