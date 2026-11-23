defmodule Letflow.PlatformProcesses.SeedTest do
  @moduledoc """
  The SEED of the pilot's registration definition (T-2595, gap G9 of the
  "Register a tenant" pilot).

  The seed writes `platform.register_tenant` v1 into the PLATFORM tenant as an
  ordinary, unstamped, editable definition, switches it on with the authority
  of a real platform administrator, and never overwrites a version an
  administrator already made.

  `async: false`: the platform tenant pin is application configuration, which
  is VM-global.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.PlatformProcesses.Definition
  alias Letflow.PlatformProcesses.Seed
  alias Letflow.Repo
  alias Letflow.Support.PlatformCallFixture, as: Fx
  alias Letflow.Support.PlatformTenantFixture, as: PlatformFx

  setup do
    tenant = Fx.tenant!("t2595-seed")
    PlatformFx.pin!(tenant.tenant_id)

    admin = Fx.user!(tenant.schema_name, "admin")
    Fx.platform_admin!(tenant.schema_name, admin)

    outsider = Fx.user!(tenant.schema_name, "outsider")

    %{tenant: tenant, admin: admin, outsider: outsider}
  end

  test "the seed writes the definition into the platform tenant and switches it on", ctx do
    assert {:ok, %{outcome: :created, definition: definition, version: "1"}} =
             Seed.seed(prefix: ctx.tenant.schema_name, activator_user_id: ctx.admin.id)

    assert definition.name == "platform.register_tenant"
    assert definition.version == "1"
    assert definition.status == :active
    assert definition.graph == Definition.graph()
    assert definition.start_permission == "TenantsManage"

    # the version the seed wrote is the one that runs
    assert {:ok, active} =
             Definitions.get_active_by_name("platform.register_tenant",
               prefix: ctx.tenant.schema_name
             )

    assert active.id == definition.id
  end

  test "the seeded definition is ORDINARY: no owner stamp, so an administrator may edit it",
       ctx do
    assert {:ok, %{outcome: :created, definition: definition}} =
             Seed.seed(prefix: ctx.tenant.schema_name, activator_user_id: ctx.admin.id)

    row = Repo.get!(ProcessDefinition, definition.id, prefix: ctx.tenant.schema_name)

    assert row.owner_module == nil
    assert row.owner_module_version == nil
    assert row.owner_manifest_hash == nil
    assert row.owner_body_hash == nil

    # an edit is a NEW DRAFT of the same key, and it may be switched on
    assert {:ok, draft} =
             Definitions.create_with_variable_schemas(
               %{
                 name: "platform.register_tenant",
                 version: "2",
                 graph: Definition.graph(),
                 created_by: ctx.admin.id
               },
               Definition.variable_schemas(),
               prefix: ctx.tenant.schema_name
             )

    assert draft.status == :draft

    # and the draft itself is editable
    assert {:ok, _edited} =
             Definitions.update(
               draft.id,
               %{description: "edited by the administrator"},
               prefix: ctx.tenant.schema_name
             )
  end

  test "the seed is idempotent: the second run writes nothing", ctx do
    assert {:ok, %{outcome: :created}} =
             Seed.seed(prefix: ctx.tenant.schema_name, activator_user_id: ctx.admin.id)

    assert {:ok, %{outcome: :already_present, version: "1"}} =
             Seed.seed(prefix: ctx.tenant.schema_name, activator_user_id: ctx.admin.id)

    rows =
      Repo.all(
        from(d in ProcessDefinition,
          where: d.name == "platform.register_tenant",
          select: d.version
        ),
        prefix: ctx.tenant.schema_name
      )

    assert rows == ["1"]
  end

  test "the seed never replaces a NEWER version an administrator made", ctx do
    # the administrator's own newer version, switched on
    assert {:ok, theirs} =
             Definitions.create_with_variable_schemas(
               %{
                 name: "platform.register_tenant",
                 version: "7",
                 graph: simple_graph(),
                 created_by: ctx.admin.id
               },
               [],
               prefix: ctx.tenant.schema_name
             )

    assert {:ok, _activated} =
             Definitions.activate(theirs.id, prefix: ctx.tenant.schema_name)

    assert {:ok, %{outcome: :newer_version_kept, version: "7"}} =
             Seed.seed(prefix: ctx.tenant.schema_name, activator_user_id: ctx.admin.id)

    # the administrator's version is still the one that runs, and the seed
    # wrote no version of its own
    assert {:ok, active} =
             Definitions.get_active_by_name("platform.register_tenant",
               prefix: ctx.tenant.schema_name
             )

    assert active.version == "7"

    rows =
      Repo.all(
        from(d in ProcessDefinition,
          where: d.name == "platform.register_tenant",
          select: d.version
        ),
        prefix: ctx.tenant.schema_name
      )

    assert rows == ["7"]
  end

  test "the seed keeps a version it cannot compare with, and writes nothing", ctx do
    # an active version whose number is not a plain number: the seed cannot
    # compare it, so it counts as NEWER and is kept
    assert {:ok, theirs} =
             Definitions.create_with_variable_schemas(
               %{
                 name: "platform.register_tenant",
                 version: "admin-2026-11",
                 graph: simple_graph(),
                 created_by: ctx.admin.id
               },
               [],
               prefix: ctx.tenant.schema_name
             )

    assert {:ok, _activated} =
             Definitions.activate(theirs.id, prefix: ctx.tenant.schema_name)

    assert {:ok, %{outcome: :newer_version_kept, version: "admin-2026-11"}} =
             Seed.seed(prefix: ctx.tenant.schema_name, activator_user_id: ctx.admin.id)

    assert {:ok, active} =
             Definitions.get_active_by_name("platform.register_tenant",
               prefix: ctx.tenant.schema_name
             )

    assert active.version == "admin-2026-11"
  end

  test "the seed does not make its own older draft the running version", ctx do
    # a DRAFT of the seed's own version, carrying the seed's own document: the
    # seed's own switch-on did not finish, so the draft is still there
    assert {:ok, draft} =
             Definitions.create_with_variable_schemas(
               %{
                 name: "platform.register_tenant",
                 version: "1",
                 graph: Definition.graph(),
                 created_by: ctx.admin.id
               },
               Definition.variable_schemas(),
               prefix: ctx.tenant.schema_name
             )

    assert draft.status == :draft

    # the administrator's newer version is switched on
    assert {:ok, theirs} =
             Definitions.create_with_variable_schemas(
               %{
                 name: "platform.register_tenant",
                 version: "2",
                 graph: simple_graph(),
                 created_by: ctx.admin.id
               },
               [],
               prefix: ctx.tenant.schema_name
             )

    assert {:ok, _activated} =
             Definitions.activate(theirs.id, prefix: ctx.tenant.schema_name)

    # the seed must not switch its own OLDER draft on over that version
    assert {:ok, %{outcome: :newer_version_kept, version: "2"}} =
             Seed.seed(prefix: ctx.tenant.schema_name, activator_user_id: ctx.admin.id)

    # the administrator's newer version is still the one that runs
    assert {:ok, active} =
             Definitions.get_active_by_name("platform.register_tenant",
               prefix: ctx.tenant.schema_name
             )

    assert active.version == "2"

    # and the seed wrote nothing: its own draft is still a draft
    rows =
      Repo.all(
        from(d in ProcessDefinition,
          where: d.name == "platform.register_tenant",
          select: {d.version, d.status}
        ),
        prefix: ctx.tenant.schema_name
      )

    assert Enum.sort(rows) == [{"1", :draft}, {"2", :active}]
  end

  test "the seed keeps an existing version of the key and writes nothing", ctx do
    # a DRAFT of the seed's own version, made by somebody else: the seed does
    # not touch it
    assert {:ok, _draft} =
             Definitions.create_with_variable_schemas(
               %{
                 name: "platform.register_tenant",
                 version: "1",
                 graph: simple_graph(),
                 created_by: ctx.admin.id
               },
               [],
               prefix: ctx.tenant.schema_name
             )

    assert {:ok, %{outcome: :already_present}} =
             Seed.seed(prefix: ctx.tenant.schema_name, activator_user_id: ctx.admin.id)

    rows =
      Repo.all(
        from(d in ProcessDefinition,
          where: d.name == "platform.register_tenant",
          select: {d.version, d.status}
        ),
        prefix: ctx.tenant.schema_name
      )

    assert rows == [{"1", :draft}]
  end

  test "the seed finishes its own unfinished switch-on, and leaves an administrator's draft alone",
       ctx do
    # a DRAFT of the seed's own version, carrying the seed's own document: the
    # switch-on did not finish, so the seed finishes it
    assert {:ok, draft} =
             Definitions.create_with_variable_schemas(
               %{
                 name: "platform.register_tenant",
                 version: "1",
                 graph: Definition.graph(),
                 created_by: ctx.admin.id
               },
               Definition.variable_schemas(),
               prefix: ctx.tenant.schema_name
             )

    assert draft.status == :draft

    assert {:ok, %{outcome: :created, definition: definition}} =
             Seed.seed(prefix: ctx.tenant.schema_name, activator_user_id: ctx.admin.id)

    assert definition.status == :active
    assert definition.id == draft.id
  end

  test "the seed refuses a tenant that is not the platform tenant, and writes nothing", ctx do
    other = Fx.tenant!("t2595-other")

    assert {:error, :not_the_platform_tenant} =
             Seed.seed(prefix: other.schema_name, activator_user_id: ctx.admin.id)

    rows =
      Repo.all(
        from(d in ProcessDefinition, where: d.name == "platform.register_tenant", select: d.id),
        prefix: other.schema_name
      )

    assert rows == []
  end

  test "the seed refuses an administrator who does not hold the permission, and writes nothing",
       ctx do
    # a user of the platform tenant WITHOUT the PLATFORM_ADMIN role
    assert {:error, :activator_not_permitted} =
             Seed.seed(prefix: ctx.tenant.schema_name, activator_user_id: ctx.outsider.id)

    rows =
      Repo.all(
        from(d in ProcessDefinition, where: d.name == "platform.register_tenant", select: d.id),
        prefix: ctx.tenant.schema_name
      )

    assert rows == []
  end

  test "the seed signs the switch-on with the administrator's own authority", ctx do
    assert {:ok, %{outcome: :created, definition: definition}} =
             Seed.seed(prefix: ctx.tenant.schema_name, activator_user_id: ctx.admin.id)

    row = Repo.get!(ProcessDefinition, definition.id, prefix: ctx.tenant.schema_name)

    assert row.activated_by["user_id"] == ctx.admin.id
    assert "TenantsManage" in row.activated_by["permissions"]
    assert "PLATFORM_ADMIN" in row.activated_by["roles"]

    # and the audit rows name that administrator, not "nobody"
    actions =
      Repo.all(
        from(e in Entry,
          where: e.resource_id == ^definition.id,
          select: {e.action, e.actor_id, e.actor_kind}
        ),
        prefix: ctx.tenant.schema_name
      )

    assert Enum.any?(actions, fn
             {"definition.create", actor_id, "user"} -> actor_id == ctx.admin.id
             _other -> false
           end)

    assert Enum.any?(actions, fn
             {"definition.activate", actor_id, "user"} -> actor_id == ctx.admin.id
             _other -> false
           end)
  end

  test "the activator is read from the DATABASE, not from the caller's word", ctx do
    # the caller names a user that does not exist
    assert {:error, :activator_not_found} =
             Seed.seed(
               prefix: ctx.tenant.schema_name,
               activator_user_id: Ecto.UUID.generate()
             )

    # and a user of ANOTHER tenant is not an administrator of this one: the
    # user is not in this tenant at all, so the seed cannot find them
    other = Fx.tenant!("t2595-elsewhere")
    stranger = Fx.user!(other.schema_name, "stranger")

    assert {:error, :activator_not_found} =
             Seed.seed(prefix: ctx.tenant.schema_name, activator_user_id: stranger.id)
  end

  test "the administrator is found in the platform tenant when the caller names none", ctx do
    assert {:ok, %{outcome: :created, definition: definition}} =
             Seed.seed(prefix: ctx.tenant.schema_name)

    row = Repo.get!(ProcessDefinition, definition.id, prefix: ctx.tenant.schema_name)

    assert row.activated_by["user_id"] == ctx.admin.id
  end

  test "the seed's own activator is the one the catalogue needs", ctx do
    # the seeded version may be switched on by the platform administrator and
    # by nobody else: the signed document proves the authority
    assert {:ok, %{outcome: :created, definition: definition}} =
             Seed.seed(prefix: ctx.tenant.schema_name, activator_user_id: ctx.admin.id)

    row = Repo.get!(ProcessDefinition, definition.id, prefix: ctx.tenant.schema_name)

    activator =
      Activator.from_auth_context(%{user_id: ctx.admin.id, roles: ["PLATFORM_ADMIN"]}, true)

    assert "TenantsManage" in activator.catalogue_permissions
    assert row.activated_by["permissions"] == Enum.sort(row.activated_by["permissions"])
  end

  defp simple_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
    }
  end
end
