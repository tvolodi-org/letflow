defmodule Letflow.Scripts.VortexKarlEntitiesAccessTest do
  @moduledoc """
  T-1300 (follow-up of GH #2039): `actor-vortex-karl` got 403 on `/entities` on QA.

  The roster gives karl `builtin_roles: [TASK_WORKER]` only (BA decision GH #3121: no
  PROCESS_OPERATOR). This test pins what that roster role may and may not do on the
  `/entities` routes, so a 403 can be told from a missing grant:

    * reads (`EntitiesDefinitionsRead`, `EntitiesQuery`, `EntitiesAggregate`) are allowed
      to TASK_WORKER, so a 403 on a read means karl holds NO TASK_WORKER membership on QA
      (seed_vortex_persona_actors.sh did not reach him), not a wrong fixture;
    * writes, import, export, restrictions and views are refused to TASK_WORKER by design
      (403 is the correct answer there; the fixture and scenarios do not expect otherwise);
    * the shipment_manifest denial of karl is an absent type-grant row (type denial is
      404, never 403, INV-5), so it cannot be the 403.

  Pure file I/O plus `Authorization.role_allows?/2`, `async: true`.
  """

  use ExUnit.Case, async: true

  @moduletag :unit

  alias Letflow.Api.Authorization

  @root Path.expand("../../..", __DIR__)
  @actors_path Path.join(@root, "test/fixtures/uat/actors.yaml")
  @entities_seed Path.join(@root, "scripts/seed_vortex_entities.sh")
  @entities_router Path.join(@root, "lib/letflow/routers/entities.ex")

  @read_permissions [
    :EntitiesDefinitionsRead,
    :EntitiesQuery,
    :EntitiesAggregate,
    :EntitiesAttachmentsRead
  ]

  @refused_permissions [
    :EntitiesDefinitionsWrite,
    :EntitiesRecordsWrite,
    :EntitiesRecordsImport,
    :EntitiesRecordsExport,
    :EntitiesRecordsExportUnredacted,
    :EntitiesRestrictionsManage,
    :EntitiesViewsManage
  ]

  defp karl, do: YamlElixir.read_from_file!(@actors_path)["actors"]["actor-vortex-karl"]

  test "K1: roster gives karl TASK_WORKER only, in the vortex tenant" do
    assert karl()["tenant"] == "vortex"
    assert karl()["builtin_roles"] == ["TASK_WORKER"]
  end

  test "K2: every roster role of karl may use the entity read routes" do
    for role <- karl()["builtin_roles"], perm <- @read_permissions do
      assert Authorization.role_allows?(String.to_existing_atom(role), perm),
             "#{role} must hold #{perm}"
    end
  end

  test "K3: the entity write, import, export and admin routes are refused to karl's roles" do
    for role <- karl()["builtin_roles"], perm <- @refused_permissions do
      refute Authorization.role_allows?(String.to_existing_atom(role), perm),
             "#{role} must not hold #{perm}"
    end
  end

  test "K4: the entities router gates the routes with exactly these permissions" do
    src = File.read!(@entities_router)

    for perm <- @read_permissions -- [:EntitiesAttachmentsRead] do
      assert src =~ ":#{perm}"
    end

    assert src =~ ~s|authz_post "/query", :EntitiesQuery|
    assert src =~ ~s|authz_get "/definitions", :EntitiesDefinitionsRead|
    assert src =~ ":EntitiesRecordsWrite"
  end

  test "K5: karl's shipment_manifest denial is an absent type grant, not a permission" do
    src = File.read!(@entities_seed)
    # the seed grants only the dedicated seeding account for the restricted type ...
    assert src =~ ~r/type_grants: \[\s*\{user_id: \$seed, entity_type: "shipment_manifest"\}\s*\]/
    # ... and refuses to run as karl
    assert src =~ ~s|SEED_ID}" == "${KARL_ID}"|
  end
end
