defmodule Letflow.Definitions.PackUpdateOverridesTest do
  @moduledoc """
  REQ-617 / GH #3443: the pure outcome rules of `PackUpdateOverrides.evaluate/5` (U1..U6), the read of a
  tenant without an override schema, and the status migration (M1, M2). The HTTP side is in
  `Letflow.Routers.SolutionPacksUpdateOverridesTest`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions.PackUpdateOverrides, as: PUO
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  defp graph(label, n2 \\ "Two") do
    Jason.encode!(%{
      "nodes" => [
        %{
          "id" => "n1",
          "label" => label,
          "node_type" => "task",
          "attributes" => %{"role" => "r"}
        },
        %{"id" => "n2", "label" => n2, "node_type" => "task"}
      ]
    })
  end

  defp override(patch, type \\ "process_definition"),
    do: %{
      override_id: Ecto.UUID.generate(),
      override_version: 1,
      made_against: "1.0.0",
      artefact_type: type,
      patch: patch
    }

  @label %{"nodes.n1.label" => "Mine"}

  test "U1: an artefact absent from incoming is orphaned" do
    assert %{outcome: :orphaned} = PUO.evaluate(override(@label), :conflict, graph("A"), nil)
  end

  test "U2: a path off the closed list is property_gone, also with a shortened list" do
    assert %{outcome: :property_gone} =
             PUO.evaluate(
               override(%{"nodes.n1.node_type" => "x"}),
               :unchanged,
               graph("A"),
               graph("A")
             )

    shortened = %{"process_definition" => [{"\\Anodes\\.n1\\.attributes\\.role\\z", :text}]}

    assert %{outcome: :property_gone, warning: nil} =
             PUO.evaluate(override(@label), :unchanged, graph("A"), graph("A"), shortened)

    assert %{outcome: :property_gone} =
             PUO.evaluate(override(@label, "variable_schema"), :unchanged, "a", "a")
  end

  test "U3: unchanged and local_only are kept without a warning" do
    for classification <- [:unchanged, :local_only] do
      assert %{outcome: :kept, warning: nil} =
               PUO.evaluate(override(@label), classification, graph("A"), graph("A"))
    end
  end

  test "U4: a patched path that differs between base and incoming is an override_conflict" do
    assert %{outcome: :override_conflict} =
             PUO.evaluate(override(@label), :clean_update, graph("A"), graph("B"))

    # present in one side, absent in the other
    assert %{outcome: :override_conflict} =
             PUO.evaluate(
               override(%{"nodes.n2.attributes.role" => "x"}),
               :clean_update,
               graph("A"),
               Jason.encode!(%{
                 "nodes" => [%{"id" => "n2", "attributes" => %{"role" => "new"}}]
               })
             )
  end

  test "U5: unparsable content and a missing base count as touched" do
    assert %{outcome: :override_conflict} =
             PUO.evaluate(override(@label), :clean_update, "not json", graph("B"))

    assert %{outcome: :override_conflict} =
             PUO.evaluate(override(@label), :conflict, nil, graph("B"))
  end

  test "U6: untouched paths keep the override with a warning; settings paths are never touched" do
    assert %{outcome: :kept, warning: :override_kept_pack_changed} =
             PUO.evaluate(override(@label), :clean_update, graph("A", "Two"), graph("A", "New"))

    assert %{outcome: :kept, warning: :override_kept_pack_changed} =
             PUO.evaluate(
               override(%{"settings.threshold" => 5}),
               :clean_update,
               graph("A"),
               graph("B")
             )
  end

  test "override_map never carries the patch" do
    row = override(@label)
    map = PUO.override_map(row, %{outcome: :kept, warning: nil})

    assert Map.keys(map) |> Enum.sort() == [
             :made_against,
             :outcome,
             :override_id,
             :override_version
           ]

    map = PUO.override_map(row, %{outcome: :kept, warning: :override_kept_pack_changed})
    assert map.warning == :override_kept_pack_changed
  end

  test "read_active: a tenant id with no tenant schema has no overrides" do
    assert PUO.read_active(Ecto.UUID.generate(), "p", [{"process_definition", "a"}]) == %{}
    assert PUO.read_active("not-a-uuid", "p", [{"process_definition", "a"}]) == %{}
  end

  describe "M status migration" do
    test "M1: the migration is registered after the override table migration" do
      versions = Enum.map(TenantProvisioning.tenant_scoped_migrations(), &elem(&1, 0))
      assert 20_261_030_100_001 in versions

      assert Enum.find_index(versions, &(&1 == 20_261_029_100_001)) <
               Enum.find_index(versions, &(&1 == 20_261_030_100_001))
    end

    test "M2: orphaned is accepted, an unknown status is still refused" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "s4mig")

      insert = fn status ->
        Repo.query(
          ~s|INSERT INTO "#{tenant.schema_name}".solution_pack_overrides (id, override_id, override_version, pack_id, artefact_type, artefact_id, made_against, patch, patch_hash, status, reason, created_by, inserted_at) VALUES (gen_random_uuid(), gen_random_uuid(), 1, 'p', 'process_definition', 'a', '1.0.0', '{}'::jsonb, 'h', $1, 'r', gen_random_uuid(), now())|,
          [status]
        )
      end

      assert {:ok, _} = insert.("orphaned")
      assert {:error, %Postgrex.Error{}} = insert.("bogus")
    end
  end
end
