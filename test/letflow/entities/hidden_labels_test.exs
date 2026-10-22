defmodule Letflow.Entities.HiddenLabelsTest do
  @moduledoc """
  The hidden-label loaders of decision 0062 R8 (GH #2616 part 2): `load_hidden_labels/2` is the
  caller's own hidden set (every restricted field the user holds no grant for), and
  `load_platform_hidden_labels/1` is the platform principal's, which holds no grants and so hides
  every restricted field. Both are scoped to the tenant schema named by the prefix (INV-1).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Entities.HiddenLabels
  alias Letflow.Identity.User
  alias Letflow.Support.ScriptTaskFixture, as: F

  setup do
    t = F.tenant!("gh2616-field-grants")

    Repo.insert_all(
      "entity_field_restrictions",
      [
        restriction("customer", "salary"),
        restriction("customer", "ssn")
      ],
      prefix: t.schema_name
    )

    %{t: t}
  end

  defp restriction(entity_type, field_name) do
    %{
      id: Ecto.UUID.bingenerate(),
      entity_type: entity_type,
      field_name: field_name,
      inserted_at: NaiveDateTime.utc_now(),
      updated_at: NaiveDateTime.utc_now()
    }
  end

  defp user!(t) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "field-grants-#{Ecto.UUID.generate()}",
      display_name: "Field Grants Test User",
      email: "field-grants-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: t.schema_name)
  end

  defp grant!(t, user, field_name) do
    Repo.insert_all(
      "user_entity_grants",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          user_id: Ecto.UUID.dump!(user.id),
          entity_type: "customer",
          field_name: field_name,
          inserted_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: t.schema_name
    )
  end

  describe "load_platform_hidden_labels/1" do
    test "returns every restriction row as a label, whoever asks", %{t: t} do
      assert {:ok, hidden} = HiddenLabels.load_platform_hidden_labels(t.schema_name)

      assert hidden == MapSet.new(["customer.salary", "customer.ssn"])
    end
  end

  describe "load_hidden_labels/2" do
    test "omits the pair the user holds a grant for", %{t: t} do
      user = user!(t)
      grant!(t, user, "salary")

      assert {:ok, hidden} = HiddenLabels.load_hidden_labels(user.id, t.schema_name)

      assert hidden == MapSet.new(["customer.ssn"])
    end

    test "a user with no grant hides every restricted field", %{t: t} do
      user = user!(t)

      assert {:ok, hidden} = HiddenLabels.load_hidden_labels(user.id, t.schema_name)

      assert hidden == MapSet.new(["customer.salary", "customer.ssn"])
    end
  end
end
