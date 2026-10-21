defmodule Letflow.Identity.RoleRevocationsTest do
  @moduledoc """
  GH 2558: the fold of `Letflow.Identity.RoleRevocations` over a tenant's audit chain and
  current memberships. Real Postgres, real tenant schema.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Identity
  alias Letflow.Identity.Group
  alias Letflow.Identity.RoleRevocations
  alias Letflow.Identity.User
  alias Letflow.TenantFixture

  setup do
    fx = TenantFixture.provisioned_tenant!(slug_prefix: "gh2558-rr")
    %{schema: fx.schema_name}
  end

  defp user!(schema) do
    n = System.unique_integer([:positive])

    %User{}
    |> Ecto.Changeset.change(%{
      username: "gh2558-rr-#{n}",
      display_name: "RR #{n}",
      email: "gh2558-rr-#{n}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema)
  end

  defp group!(schema) do
    %Group{}
    |> Ecto.Changeset.change(%{name: "gh2558-g-#{System.unique_integer([:positive])}"})
    |> Repo.insert!(prefix: schema)
  end

  defp add!(schema, g, u), do: {:ok, _} = Identity.add_group_member(g.id, u.id, prefix: schema)
  defp remove!(schema, g, u), do: :ok = Identity.remove_group_member(g.id, u.id, prefix: schema)

  defp revoked(schema, u), do: RoleRevocations.revoked_group_ids(u.id, schema)

  test "never added or removed: nothing revoked", %{schema: s} do
    u = user!(s)
    _g = group!(s)
    assert revoked(s, u) == MapSet.new()
  end

  test "added then removed: revoked", %{schema: s} do
    {u, g} = {user!(s), group!(s)}
    add!(s, g, u)
    remove!(s, g, u)
    assert revoked(s, u) == MapSet.new([g.id])
  end

  test "added, removed, added: not revoked", %{schema: s} do
    {u, g} = {user!(s), group!(s)}
    add!(s, g, u)
    remove!(s, g, u)
    add!(s, g, u)
    assert revoked(s, u) == MapSet.new()
  end

  test "added, removed, added, removed: revoked", %{schema: s} do
    {u, g} = {user!(s), group!(s)}

    for _ <- 1..2 do
      add!(s, g, u)
      remove!(s, g, u)
    end

    assert revoked(s, u) == MapSet.new([g.id])
  end

  test "removed, then a membership written without an added row: not revoked", %{schema: s} do
    {u, g} = {user!(s), group!(s)}
    add!(s, g, u)
    remove!(s, g, u)
    Repo.insert!(%Letflow.Identity.GroupMember{group_id: g.id, user_id: u.id}, prefix: s)
    assert revoked(s, u) == MapSet.new()
  end

  test "other users' and other groups' entries are ignored", %{schema: s} do
    {u, other} = {user!(s), user!(s)}
    {g1, g2} = {group!(s), group!(s)}
    add!(s, g1, other)
    remove!(s, g1, other)
    add!(s, g1, u)
    add!(s, g2, u)
    remove!(s, g2, u)

    assert revoked(s, u) == MapSet.new([g2.id])
    assert revoked(s, other) == MapSet.new([g1.id])

    assert RoleRevocations.users_with_revocation([u.id, other.id], s) ==
             MapSet.new([u.id, other.id])

    assert RoleRevocations.users_with_revocation([], s) == MapSet.new()
  end

  test "users_with_revocation/2 returns only users with a revocation in force", %{schema: s} do
    {a, b} = {user!(s), user!(s)}
    g = group!(s)
    add!(s, g, a)
    remove!(s, g, a)
    add!(s, g, b)

    assert RoleRevocations.users_with_revocation([a.id, b.id], s) == MapSet.new([a.id])
    assert Repo.exists?(from(u in User, where: u.id == ^a.id), prefix: s)
  end
end
