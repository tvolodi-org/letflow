defmodule Letflow.Entities.WriteAccessTest do
  @moduledoc "REQ-577 / GH #3261 (W9): `WriteAccess.authorized?/3` and `lost_writers/2`."

  use Letflow.DataCase, async: false

  alias Letflow.Entities.WriteAccess
  alias Letflow.Identity.User
  alias Letflow.TenantFixture
  alias Letflow.Test.SandboxAutoMode

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req577-wa")
    %{schema: tenant.schema_name, user: user!(tenant.schema_name)}
  end

  defp user!(schema, status \\ :active) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "req577-wa-#{Ecto.UUID.generate()}",
      display_name: "REQ-577 unit user",
      email: "req577-wa-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: status,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema)
  end

  defp restrict!(schema, type) do
    Repo.insert_all(
      "entity_type_write_restrictions",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          entity_type: type,
          inserted_at: NaiveDateTime.utc_now(),
          updated_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: schema
    )
  end

  defp grant!(schema, user_id, type) do
    Repo.insert_all(
      "user_entity_type_write_grants",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          user_id: Ecto.UUID.dump!(user_id),
          entity_type: type,
          inserted_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: schema
    )
  end

  test "allowed with no row; denied with a restriction; allowed with the grant", ctx do
    assert WriteAccess.authorized?(ctx.user.id, "t", ctx.schema) == {:ok, :allowed}
    restrict!(ctx.schema, "t")
    assert WriteAccess.authorized?(ctx.user.id, "t", ctx.schema) == {:ok, :denied}
    assert WriteAccess.authorized?(ctx.user.id, "other", ctx.schema) == {:ok, :allowed}
    grant!(ctx.schema, ctx.user.id, "t")
    assert WriteAccess.authorized?(ctx.user.id, "t", ctx.schema) == {:ok, :allowed}
  end

  test "a grant for another user or another type does not open", ctx do
    other = user!(ctx.schema)
    restrict!(ctx.schema, "t")
    restrict!(ctx.schema, "u")
    grant!(ctx.schema, other.id, "t")
    grant!(ctx.schema, ctx.user.id, "u")
    assert WriteAccess.authorized?(ctx.user.id, "t", ctx.schema) == {:ok, :denied}
  end

  test "an invalid schema name is an error", ctx do
    assert WriteAccess.authorized?(ctx.user.id, "t", "no_such_schema") ==
             {:error, :invalid_schema_name}
  end

  test "lost_writers: ordering, exclusions and the empty list", ctx do
    assert WriteAccess.lost_writers([], ctx.schema) == {:ok, [], false}
    granted = user!(ctx.schema)
    inactive = user!(ctx.schema, :inactive)
    restrict!(ctx.schema, "t")
    grant!(ctx.schema, granted.id, "t")

    assert {:ok, pairs, false} = WriteAccess.lost_writers(["t", "t"], ctx.schema)
    ids = Enum.map(pairs, &elem(&1, 0))
    assert ctx.user.id in ids
    refute granted.id in ids
    refute inactive.id in ids
    assert ids == Enum.sort(ids)
    assert Enum.all?(pairs, fn {_u, t} -> t == "t" end)
  end

  test "lost_writers: users failing TypeAccess are excluded, type grantees are kept", ctx do
    hidden = user!(ctx.schema)
    restrict!(ctx.schema, "t")

    now = NaiveDateTime.utc_now()

    Repo.insert_all(
      "entity_type_restrictions",
      [%{id: Ecto.UUID.bingenerate(), entity_type: "t", inserted_at: now, updated_at: now}],
      prefix: ctx.schema
    )

    Repo.insert_all(
      "user_entity_type_grants",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          user_id: Ecto.UUID.dump!(ctx.user.id),
          entity_type: "t",
          inserted_at: now
        }
      ],
      prefix: ctx.schema
    )

    assert {:ok, pairs, false} = WriteAccess.lost_writers(["t"], ctx.schema)
    assert Enum.map(pairs, &elem(&1, 0)) == [ctx.user.id]
    refute hidden.id in Enum.map(pairs, &elem(&1, 0))
  end
end
