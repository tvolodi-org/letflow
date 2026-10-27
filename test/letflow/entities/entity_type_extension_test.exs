defmodule Letflow.Entities.EntityTypeExtensionTest do
  @moduledoc """
  REQ-576 / GH #3258 -- schema module of `entity_type_extensions`: INV-1/INV-10 two-tenant
  negative test, round trip, and "no changeset, no Repo call, nobody references it".

  `async: false`: `TenantFixture` flips the SQL sandbox to `:auto`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Entities.EntityTypeExtension
  alias Letflow.TenantFixture

  setup do
    %{
      a: TenantFixture.provisioned_tenant!(slug_prefix: "t0663-a"),
      b: TenantFixture.provisioned_tenant!(slug_prefix: "t0663-b")
    }
  end

  defp insert!(tenant, attrs \\ %{}) do
    row =
      struct!(
        EntityTypeExtension,
        Map.merge(
          %{
            tenant_id: tenant.tenant_id,
            entity_type: "order",
            kind: "field",
            name: "x_foo",
            spec: %{"type" => "string"},
            position: 3,
            status: "active"
          },
          attrs
        )
      )

    Repo.insert!(row, prefix: tenant.schema_name)
  end

  test "C6a a row under A is not returned under B", %{a: a, b: b} do
    insert!(a)
    assert [_] = Repo.all(EntityTypeExtension, prefix: a.schema_name)
    assert Repo.all(EntityTypeExtension, prefix: b.schema_name) == []
  end

  test "C6b a row under A is not updated or deleted under B", %{a: a, b: b} do
    row = insert!(a)
    q = from(e in EntityTypeExtension, where: e.id == ^row.id)

    assert {0, _} = Repo.update_all(q, [set: [status: "retired"]], prefix: b.schema_name)
    assert {0, _} = Repo.delete_all(q, prefix: b.schema_name)

    assert %{status: "active"} = Repo.get!(EntityTypeExtension, row.id, prefix: a.schema_name)
  end

  test "C6c the same name inserts independently under B", %{a: a, b: b} do
    insert!(a)
    assert %EntityTypeExtension{} = insert!(b)
  end

  test "C7a round trip under the tenant prefix keeps values", %{a: a} do
    row = insert!(a)
    got = Repo.get!(EntityTypeExtension, row.id, prefix: a.schema_name)

    assert got.tenant_id == a.tenant_id
    assert got.entity_type == "order"
    assert got.kind == "field"
    assert got.name == "x_foo"
    assert got.spec == %{"type" => "string"}
    assert got.position == 3
    assert got.status == "active"
  end

  test "C7b no changeset function and no Repo call in the module" do
    for n <- 0..3, do: refute(function_exported?(EntityTypeExtension, :changeset, n))

    refute Enum.any?(EntityTypeExtension.__info__(:functions), fn {f, _} ->
             String.starts_with?(Atom.to_string(f), "changeset")
           end)

    source = File.read!("lib/letflow/entities/entity_type_extension.ex")
    refute source =~ "Repo."
    refute source =~ "Ecto.Changeset"
  end

  test "C7c no other lib file references the module or the table" do
    own = "lib/letflow/entities/entity_type_extension.ex"
    manifest = "lib/letflow/tenant_provisioning.ex"

    files = Path.wildcard("lib/**/*.ex") |> Enum.map(&String.replace(&1, "\\", "/"))

    alias_hits =
      Enum.filter(files, fn f -> File.read!(f) =~ ~r/\bEntityTypeExtension\b/ end)

    table_hits =
      Enum.filter(files, fn f -> File.read!(f) =~ "entity_type_extensions" end)

    assert alias_hits == [own]
    assert Enum.sort(table_hits) == Enum.sort([own, manifest])
  end
end
