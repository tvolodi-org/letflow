defmodule Letflow.Migrations.CreatePendingTenantAdminGrantsTest do
  @moduledoc """
  ISS-1030 PR 2 -- the tenant-scoped migration
  `priv/repo/migrations/20261008000001_create_pending_tenant_admin_grants.exs`
  (design `lib/letflow/design/iss1030-onboarding-administrator.md` sections 4.1, 4.2, 10.2).

  Real Postgres, real tenant schemas (`Letflow.TenantFixture`). The constraints are
  asserted through raw SQL on purpose: an application changeset would refuse most of these
  rows before the database saw them, so a raw INSERT is the only way to prove the DATABASE
  enforces "TENANT_ADMIN only" and the open/bound/revoked row lifecycle (design 4.1).

  `async: false`: `TenantFixture` flips the SQL sandbox to `:auto`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @version 20_261_008_000_001
  @module Letflow.Repo.Migrations.CreatePendingTenantAdminGrants
  @filename "20261008000001_create_pending_tenant_admin_grants.exs"

  setup do
    %{tenant: TenantFixture.provisioned_tenant!(slug_prefix: "iss1030-mig")}
  end

  # --- helpers ---------------------------------------------------------------

  defp table_exists?(schema_name) do
    %{rows: [[present]]} =
      Repo.query!(
        "SELECT EXISTS (SELECT 1 FROM information_schema.tables " <>
          "WHERE table_schema = $1 AND table_name = 'pending_tenant_admin_grants')",
        [schema_name]
      )

    present
  end

  # Raw INSERT, so only the database's own constraints decide. Returns :ok or the violated
  # constraint's name (a column-level NOT NULL violation is reported by its column).
  defp insert_row(schema_name, opts) do
    now = NaiveDateTime.utc_now()

    params = [
      Ecto.UUID.bingenerate(),
      Keyword.get(opts, :email_key),
      Keyword.get(opts, :role_name, "TENANT_ADMIN"),
      Keyword.get(opts, :created_via, "onboarding"),
      now,
      Keyword.get(opts, :consumed_at),
      Keyword.get(opts, :revoked_at),
      Keyword.get(opts, :consumed_by_user_id)
    ]

    sql =
      ~s(INSERT INTO "#{schema_name}".pending_tenant_admin_grants ) <>
        "(id, email_key, role_name, created_via, inserted_at, consumed_at, revoked_at, " <>
        "consumed_by_user_id) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)"

    case Repo.query(sql, params) do
      {:ok, _result} ->
        :ok

      {:error, %Postgrex.Error{postgres: %{constraint: constraint}}} when is_binary(constraint) ->
        constraint

      {:error, %Postgrex.Error{postgres: %{code: code}}} ->
        code
    end
  end

  # --- manifest and guard ----------------------------------------------------

  test "the migration is in the tenant-scoped manifest and is guarded by prefix()" do
    # Half one: the manifest entry (loaded by the same function replay uses).
    assert {@version, @module} in TenantProvisioning.tenant_scoped_migrations()

    # Half two: the file carries the mandatory guard, and creates nothing outside it.
    source = File.read!(Path.join(["priv", "repo", "migrations", @filename]))
    assert source =~ "TENANT-SCOPED MIGRATION"

    [_header, body] = String.split(source, "def change do", parts: 2)
    {guard_at, _len} = :binary.match(body, "if prefix() do")
    {create_at, _len} = :binary.match(body, "create table(")
    assert guard_at < create_at, "a create table appears before the `if prefix() do` guard"

    # Every create/constraint/index in the body sits inside the guard, so the public schema is
    # never touched by a plain `mix ecto.migrate`.
    unguarded = body |> String.split("if prefix() do", parts: 2) |> hd()
    refute unguarded =~ "create "

    # The version integer in the manifest equals the file's timestamp prefix.
    assert String.starts_with?(@filename, Integer.to_string(@version))
  end

  # --- replay ----------------------------------------------------------------

  test "replay_migrations creates the table in an existing tenant schema and a second replay is a no-op",
       %{tenant: tenant} do
    # The fixture's clone already carries the table (it is in the manifest).
    assert table_exists?(tenant.schema_name)

    # Put the schema back into the state of a tenant that existed BEFORE this migration merged.
    Repo.query!(~s(DROP TABLE "#{tenant.schema_name}".pending_tenant_admin_grants))

    Repo.query!(~s(DELETE FROM "#{tenant.schema_name}".schema_migrations WHERE version = $1), [
      @version
    ])

    refute table_exists?(tenant.schema_name)

    # The boot-time rollout path: the same function `replay_all_pending/0` calls per tenant.
    only_this = [{@version, @module}]
    assert {:ok, [@version]} = TenantProvisioning.replay_migrations(tenant.tenant_id, only_this)
    assert table_exists?(tenant.schema_name)

    # A second replay applies nothing and does not fail.
    assert {:ok, []} = TenantProvisioning.replay_migrations(tenant.tenant_id, only_this)
    assert table_exists?(tenant.schema_name)

    # The table starts empty (no backfill for existing tenants).
    assert %{rows: [[0]]} =
             Repo.query!(
               ~s|SELECT count(*) FROM "#{tenant.schema_name}".pending_tenant_admin_grants|
             )
  end

  # --- constraints -----------------------------------------------------------

  test "role_name other than TENANT_ADMIN is rejected by the CHECK constraint", %{tenant: tenant} do
    schema = tenant.schema_name

    for role <- ["PLATFORM_ADMIN", "PROCESS_DESIGNER", "tenant_admin", ""] do
      assert insert_row(schema, email_key: "owner@example.com", role_name: role) ==
               "pending_tenant_admin_grants_role_name_chk",
             "role #{inspect(role)} was accepted"
    end

    # The only other pinned column: a later source of grants must widen the CHECK in its own migration.
    assert insert_row(schema, email_key: "owner@example.com", created_via: "api") ==
             "pending_tenant_admin_grants_created_via_chk"

    # The one accepted row, so the rejections above are about the value and not the harness.
    assert insert_row(schema, email_key: "owner@example.com") == :ok
  end

  test "email_key is unique per tenant schema and the same address is allowed in two tenants",
       %{tenant: tenant} do
    other = TenantFixture.provisioned_tenant!(slug_prefix: "iss1030-mig-other")

    assert insert_row(tenant.schema_name, email_key: "owner@example.com") == :ok
    assert insert_row(other.schema_name, email_key: "owner@example.com") == :ok

    assert insert_row(tenant.schema_name, email_key: "owner@example.com") ==
             "pending_tenant_admin_grants_email_key_idx"

    # A scrubbed (NULL) key never collides, so any number of bound/revoked rows may coexist.
    now = NaiveDateTime.utc_now()
    assert insert_row(tenant.schema_name, consumed_at: now) == :ok
    assert insert_row(tenant.schema_name, consumed_at: now) == :ok
    assert insert_row(tenant.schema_name, revoked_at: now) == :ok
  end

  test "email_key CHECK: an open row has a non-null email_key, a bound row and a revoked row have NULL, and a row with both consumed_at and revoked_at set is rejected",
       %{tenant: tenant} do
    schema = tenant.schema_name
    now = NaiveDateTime.utc_now()
    state_chk = "pending_tenant_admin_grants_state_chk"

    # open: e-mail required
    assert insert_row(schema, email_key: nil) == state_chk
    assert insert_row(schema, email_key: "open@example.com") == :ok

    # bound: e-mail must have been scrubbed
    assert insert_row(schema, email_key: "bound@example.com", consumed_at: now) == state_chk
    assert insert_row(schema, email_key: nil, consumed_at: now) == :ok

    # revoked: e-mail must have been scrubbed
    assert insert_row(schema, email_key: "revoked@example.com", revoked_at: now) == state_chk
    assert insert_row(schema, email_key: nil, revoked_at: now) == :ok

    # never both
    assert insert_row(schema, email_key: nil, consumed_at: now, revoked_at: now) == state_chk

    # a consuming user may only be recorded together with a consumption
    assert insert_row(schema,
             email_key: "stray@example.com",
             consumed_by_user_id: Ecto.UUID.bingenerate()
           ) == state_chk

    # the key's own shape: 3..254 characters, trimmed, ASCII only
    assert insert_row(schema, email_key: "ab") == state_chk
    assert insert_row(schema, email_key: String.duplicate("a", 255)) == state_chk
    assert insert_row(schema, email_key: " padded@example.com") == state_chk
    assert insert_row(schema, email_key: "kéy@example.com") == state_chk
    assert insert_row(schema, email_key: String.duplicate("a", 254)) == :ok
  end
end
