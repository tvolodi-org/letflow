defmodule Letflow.Definitions.SolutionPackTest do
  @moduledoc """
  Tests for REQ-304 (`lib/letflow/design/req304-solution-pack-entity-definitions-export.md`)
  AND REQ-305 (`lib/letflow/design/req305-solution-pack-entity-definitions-install.md`),
  both governed by `docs/migration/decisions/0026-solution-pack-entity-definitions-section.md`
  -- the `entity_definitions` section added to `Letflow.Definitions.SolutionPack`'s
  export path (`export/4`, `pack_each_entity_definition/2`, `pack_entity_definition/1`)
  AND install path (`install/3`'s `parse_entity_definitions/1`,
  `create_packed_entity_definitions/3`). See `test/specs/REQ-304.md` (export) and
  `test/specs/REQ-306.md` (round-trip/install coverage, REQ-306) for the
  acceptance-criterion-to-test-case mapping.

  Extended (not split into a new file) for REQ-306: REQ-306's own scope fence names
  this file explicitly as the default target ("extend
  `test/letflow/definitions/solution_pack_test.exs`, or create a new file only if
  the existing file's structure genuinely doesn't fit"). It fits: REQ-306 tests the
  same module's other half (install) using the identical fixture/tenant conventions
  already established here for export, so a second file would only duplicate the
  helper section below.

  Context-module level (not router level, unlike
  `test/letflow/routers/req078_supporting_routes_test.exs`'s solution-pack coverage):
  0026/REQ-304's own scope fence leaves `lib/letflow/routers/solution_packs.ex`
  untouched, so there is no HTTP surface yet for `export/4` or the
  `entity_definition_names` parameter -- the only way to exercise this behavior is
  to call `Letflow.Definitions.SolutionPack.export/3`, `.export/4`, and `.install/3`
  directly. REQ-305 likewise never touched the router.

  Uses `Letflow.DataCase` (real Postgres, per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1) and `Letflow.TenantFixture` for real provisioned tenant schemas,
  mirroring `req078_supporting_routes_test.exs`'s own fixture conventions.
  `async: false` -- same reasoning as that file (tenant provisioning/migration
  replay needs `Sandbox.mode(Letflow.Repo, :auto)`).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Definitions
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.SolutionPack
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Engine.VariableSchema
  alias Letflow.Entities.Definitions, as: EntityDefinitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Identity.User
  alias Letflow.Repo
  alias Letflow.TenantFixture

  # ── Shared helpers ─────────────────────────────────────────────────────────

  defp unique(prefix),
    do: prefix <> "_" <> to_string(System.unique_integer([:positive, :monotonic]))

  # Mirrors req078_supporting_routes_test.exs's own cleanup_solution_pack_installs!/1
  # exactly, for the same reason: solution_pack_installs is a REQ-041 GLOBAL
  # table TenantFixture has no knowledge of, so any test that calls
  # SolutionPack.install/3 leaves a row referencing tenant_id via
  # solution_pack_installs_tenant_id_fkey. Registered AFTER the tenant
  # fixture's own on_exit (in creation order inside the test body), so
  # ExUnit's LIFO on_exit ordering runs this FIRST -- deleting the global row
  # before TenantFixture's own teardown tries to delete the tenants row it
  # references.
  defp cleanup_solution_pack_installs!(tenant_id) do
    on_exit(fn ->
      Repo.delete_all(from(s in SolutionPackInstall, where: s.tenant_id == ^tenant_id))

      # REQ-379: capture_artefact_bases/4 now writes solution_pack_artefact_bases
      # rows carrying the same tenant_id.tenants FK -- same LIFO on_exit
      # reasoning as the solution_pack_installs delete above, extended to this
      # second GLOBAL table.
      Repo.delete_all(from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant_id))
    end)
  end

  # Process-definition fixture -- mirrors req078_supporting_routes_test.exs's own
  # graph_start_end/0 + create_definition_attrs/2 + active_definition!/2 pattern,
  # trimmed to what this file needs (a definition whose id can be named to
  # export/3's `definition_ids`).
  defp graph_start_end do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
    }
  end

  defp active_process_definition!(schema_name) do
    attrs = %{
      name: unique("req304-pd"),
      version: "1.0.0",
      graph: graph_start_end(),
      created_by: Ecto.UUID.generate()
    }

    assert {:ok, definition} = Letflow.Definitions.create(attrs, prefix: schema_name)

    assert {:ok, %{definition: activated}} =
             Letflow.Definitions.activate(definition.id, prefix: schema_name)

    activated
  end

  # Entity-definition fixture -- same field shape as
  # test/letflow/entities/definitions_test.exs's valid_definition/1, generated
  # under a fresh, name-format-legal (`^[a-z][a-z0-9_]{0,63}$`) unique name per
  # call so tests don't collide with each other (DIRECTIVE 4, no test pollution).
  defp valid_entity_definition(overrides) do
    Map.merge(
      %{
        name: unique("req304_entity"),
        display_name: "REQ-304 Entity Fixture",
        fields: [
          %{name: "email", type: :string, required: true, queried: true}
        ]
      },
      overrides
    )
  end

  defp create_entity_definition!(schema_name, overrides \\ %{}) do
    attrs = %{definition: valid_entity_definition(overrides), created_by: Ecto.UUID.generate()}

    assert {:ok, entity_definition} = EntityDefinitions.create_definition(attrs, schema_name)
    entity_definition
  end

  # ── REQ-305/REQ-306 install-side helpers ─────────────────────────────────────
  #
  # Same hand-built-raw-JSON-document idiom `req078_supporting_routes_test.exs`'s
  # `pack_document/2`/`packed_definition_json/3`/`packed_variable_schema_json/3`
  # already establish for exercising `install/3` (string keys throughout --
  # `install/3`'s own moduledoc: "document is the raw decoded JSON body"), extended
  # with an `entity_definitions` key. `pack_document/1` takes a fields map instead
  # of positional args specifically so a caller can OMIT the `:entity_definitions`
  # key entirely (AC4 old-pack-compatibility -- Map.fetch/2 below only adds the
  # `"entity_definitions"` wire key when the caller supplied one, never defaulting
  # it to `[]` itself).

  defp pack_document(fields) when is_map(fields) do
    base = %{
      "pack_id" => Ecto.UUID.generate(),
      "version" => "1.0.0",
      "bpm_export_schema_version" => Letflow.Definitions.ExportImport.export_schema_version(),
      "exported_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "definitions" => Map.get(fields, :definitions, []),
      "service_catalog_entries" => [],
      "variable_schemas" => Map.get(fields, :variable_schemas, [])
    }

    case Map.fetch(fields, :entity_definitions) do
      {:ok, entity_definitions} -> Map.put(base, "entity_definitions", entity_definitions)
      :error -> base
    end
    |> Map.put("manifest", %{"required_roles" => []})
  end

  defp packed_definition_json(source_id, process_key, graph \\ nil) do
    %{
      "definition_id" => source_id,
      "process_key" => process_key,
      "name" => process_key,
      "version" => "1.0.0",
      "graph" => graph || graph_start_end()
    }
  end

  defp packed_variable_schema_json(definition_id, schema_name, schema_content) do
    %{
      "definition_id" => definition_id,
      "schema_name" => schema_name,
      "schema_content" => schema_content
    }
  end

  # Builds a raw, string-keyed `entity_definitions` wire entry -- the shape
  # `parse_entity_definition/1` (solution_pack.ex) requires. `definition_json`
  # must itself be string-keyed throughout (it is re-atomized on install via
  # `atomize_definition_json/1`'s static whitelist), matching what a real JSON
  # decode or a real `EntityDefinition.definition_json` DB read produces --
  # never an atom-keyed map, which would make `translate_keys/2` reject every
  # key as unrecognized.
  defp packed_entity_definition_json(overrides \\ %{}) do
    default_name = unique("req306_entity")

    Map.merge(
      %{
        "entity_definition_id" => Ecto.UUID.generate(),
        "name" => default_name,
        "display_name" => "REQ-306 Entity Fixture",
        # Must be valid hex -- decode_logical_shape_version/1 (ISS-0582)
        # rejects non-hex strings with {:error, :invalid_pack_document}
        # before this value ever reaches create_definition/2, which
        # recomputes its own logical_shape_version fresh anyway.
        "logical_shape_version" =>
          Base.encode16(:crypto.hash(:sha256, default_name), case: :lower),
        "definition_json" => %{
          "name" => default_name,
          "display_name" => "REQ-306 Entity Fixture",
          "fields" => [
            %{"name" => "email", "type" => "string", "required" => true, "queried" => true}
          ]
        }
      },
      overrides
    )
  end

  # Recursively turns every atom map key into a string key -- what a real JSON
  # decode of a route's request body would hand `install/3` (its own moduledoc:
  # "the raw decoded JSON body"), applied here to `export/4`'s atom-keyed
  # in-process return value so the round-trip test crosses the same key-shape
  # boundary a real export->install trip would. Deliberately NOT
  # `Jason.encode!/1 |> Jason.decode!/1`: `packed_entity_definition/1`
  # (solution_pack.ex) embeds `EntityDefinition.logical_shape_version` --
  # `field(:logical_shape_version, :binary)`, a raw (non-UTF-8-safe) digest
  # from `Letflow.Entities.Definition.Shape.logical_shape_of/1`'s SHA-256 hash
  # -- verbatim into the pack document, which is not valid JSON input and
  # makes `Jason.encode!/1` raise `Jason.EncodeError` on any real entity
  # definition (confirmed: this test raised `** (Jason.EncodeError) invalid
  # byte 0xEC` on first write, before this workaround was added). That is a
  # genuine latent defect in REQ-304's export shape, reported separately per
  # the incidental-issue process (see this requirement's completion report) --
  # not fixed here (scope fence: test code only). `fetch_string/2`
  # (solution_pack.ex, install-side) only requires `is_binary/1`, which a raw
  # byte sequence satisfies regardless of UTF-8 validity, so this stringify
  # step is a faithful stand-in for the key-shape half of real JSON transport
  # without tripping the unrelated encoding bug.
  defp stringify_keys(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_keys(v)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp process_definition_count(schema_name, name) do
    Repo.aggregate(from(d in ProcessDefinition, where: d.name == ^name), :count, :id,
      prefix: schema_name
    )
  end

  defp entity_definition_count(schema_name, name) do
    Repo.aggregate(from(e in EntityDefinition, where: e.name == ^name), :count, :id,
      prefix: schema_name
    )
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC5 -- export/3 (old arity) is byte-for-byte unchanged, entity_definitions: []
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC5: export/3 is unchanged and always carries entity_definitions: []" do
    test "process-definitions-only export/3 call still succeeds, with entity_definitions: [] and no other regression" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req304-ac5")
      definition = active_process_definition!(tenant.schema_name)

      assert {:ok, doc} =
               SolutionPack.export([definition.id], "1.0.0", prefix: tenant.schema_name)

      # Every pre-existing key/shape is untouched -- this is what makes AC5
      # "byte-for-byte compatible" true, not just "still returns 200-shaped
      # data": the exact same assertions req078_supporting_routes_test.exs's
      # AC1 "POST /solution-packs/export" test makes against the route-layer
      # equivalent, plus the new key.
      assert Map.keys(doc) |> Enum.sort() ==
               Enum.sort([
                 :pack_id,
                 :version,
                 :bpm_export_schema_version,
                 :exported_at,
                 :definitions,
                 :service_catalog_entries,
                 :variable_schemas,
                 :entity_definitions,
                 :manifest
               ])

      expected_id = definition.id
      assert [%{definition_id: ^expected_id}] = doc.definitions
      assert doc.service_catalog_entries == []
      assert doc.variable_schemas == []
      assert doc.manifest == %{required_roles: []}

      # The new key: always present, empty when nothing was named.
      assert doc.entity_definitions == []
    end

    test "export/3 with zero definition_ids is still {:error, :empty_definition_ids} (unchanged)" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req304-ac5-empty")

      assert SolutionPack.export([], "1.0.0", prefix: tenant.schema_name) ==
               {:error, :empty_definition_ids}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC1/AC2 -- pack_document's entity_definitions key, packed_entity_definition
  # shape, real data round-tripped through export/4
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC1/AC2: export/4 packs a named entity definition with the designed shape" do
    test "naming one real entity definition returns it under entity_definitions with name/display_name/definition_json (+ id/logical_shape_version)" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req304-ac2")
      created = create_entity_definition!(tenant.schema_name)

      # Re-fetch the same row the way export/4 itself will (through
      # get_definition_by_name/2) rather than comparing against the
      # just-inserted, in-memory `created` struct: `definition_json` is a
      # jsonb column, and Ecto's :map type round-trips it through Postgres
      # with STRING keys on read, whereas the atom-keyed map handed to
      # `create_definition/2` is what Repo.insert/1 hands back unchanged on
      # the insert path itself. Comparing against a real read is also the
      # more faithful assertion: it proves export/4 emits exactly what a
      # fresh read produces, not what the write-path happened to echo back.
      assert {:ok, entity_definition} =
               EntityDefinitions.get_definition_by_name(created.name, tenant.schema_name)

      assert {:ok, doc} =
               SolutionPack.export([], [entity_definition.name], "1.0.0",
                 prefix: tenant.schema_name,
                 user_id: Ecto.UUID.generate()
               )

      assert doc.definitions == []
      assert [packed] = doc.entity_definitions

      # Exact five-field shape the design specifies (§2.2's table) -- a test
      # asserting only `Map.has_key?` would pass even if extra storage-only
      # fields (tenant_id, content_hash, artifact_version_id, status) leaked
      # into the document, which INV-2 forbids; asserting the full key set
      # AND each value catches both a missing field and a leaked one.
      assert Map.keys(packed) |> Enum.sort() ==
               Enum.sort([
                 :entity_definition_id,
                 :name,
                 :display_name,
                 :definition_json,
                 :logical_shape_version
               ])

      assert packed.entity_definition_id == entity_definition.id
      assert packed.name == entity_definition.name
      assert packed.display_name == entity_definition.display_name
      assert packed.definition_json == entity_definition.definition_json

      assert packed.logical_shape_version ==
               Base.encode16(entity_definition.logical_shape_version, case: :lower)

      # And the required-minimum (AC2) fields carry the real, human-authored
      # content -- not just structurally-present placeholders.
      assert packed.name == created.name
      assert packed.display_name == "REQ-304 Entity Fixture"
      assert packed.definition_json["name"] == created.name
    end

    test "naming zero definition_ids but a non-empty entity_definition_names list is a legitimate entity-only export" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req304-ac2-entity-only")
      entity_definition = create_entity_definition!(tenant.schema_name)

      assert {:ok, doc} =
               SolutionPack.export([], [entity_definition.name], nil,
                 prefix: tenant.schema_name,
                 user_id: Ecto.UUID.generate()
               )

      assert doc.definitions == []
      assert [%{name: name}] = doc.entity_definitions
      assert name == entity_definition.name
    end

    test "naming both a process definition and an entity definition populates both lists independently" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req304-ac2-both")
      definition = active_process_definition!(tenant.schema_name)
      entity_definition = create_entity_definition!(tenant.schema_name)

      assert {:ok, doc} =
               SolutionPack.export(
                 [definition.id],
                 [entity_definition.name],
                 "1.0.0",
                 prefix: tenant.schema_name,
                 user_id: Ecto.UUID.generate()
               )

      expected_definition_id = definition.id
      expected_entity_name = entity_definition.name
      assert [%{definition_id: ^expected_definition_id}] = doc.definitions
      assert [%{name: ^expected_entity_name}] = doc.entity_definitions
    end

    test "zero definition_ids and zero entity_definition_names is still {:error, :empty_definition_ids}" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req304-ac2-both-empty")

      assert SolutionPack.export([], [], "1.0.0", prefix: tenant.schema_name) ==
               {:error, :empty_definition_ids}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # AC3/AC4 -- tenant isolation (INV-1) and the not-found error shape
  # ═══════════════════════════════════════════════════════════════════════════

  describe "AC3/AC4: entity-definition export is tenant-isolated; unresolved names are typed not-found errors" do
    test "two tenants each own an entity definition of the SAME name -- export under A's opts returns only A's row, never B's" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req304-ac3-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req304-ac3-b")

      shared_name = unique("req304_shared")

      entity_a =
        create_entity_definition!(tenant_a.schema_name, %{
          name: shared_name,
          display_name: "Tenant A's definition"
        })

      _entity_b =
        create_entity_definition!(tenant_b.schema_name, %{
          name: shared_name,
          display_name: "Tenant B's definition"
        })

      assert {:ok, doc} =
               SolutionPack.export([], [shared_name], "1.0.0",
                 prefix: tenant_a.schema_name,
                 user_id: Ecto.UUID.generate()
               )

      assert [packed] = doc.entity_definitions
      assert packed.entity_definition_id == entity_a.id
      assert packed.display_name == "Tenant A's definition"
      refute packed.display_name == "Tenant B's definition"
    end

    test "naming a wholly nonexistent name -- {:error, :entity_definition_not_found}, no name echo" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req304-ac4-missing")
      missing_name = unique("req304_missing")

      assert SolutionPack.export([], [missing_name], "1.0.0",
               prefix: tenant.schema_name,
               user_id: Ecto.UUID.generate()
             ) == {:error, :entity_definition_not_found}
    end

    test "naming another tenant's entity definition (by name, no definition of that name in the caller's own schema) -- SAME not-found shape, no leak" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req304-ac4-cross-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req304-ac4-cross-b")

      entity_b = create_entity_definition!(tenant_b.schema_name)
      subject = Ecto.UUID.generate()

      result =
        SolutionPack.export([], [entity_b.name], "1.0.0",
          prefix: tenant_a.schema_name,
          user_id: subject
        )

      # Must be the identical typed error a genuine miss produces -- proves
      # this is not a leak of tenant B's row (e.g. no {:ok, doc} branch, and
      # no distinct error shape that would let a caller distinguish "exists
      # elsewhere" from "doesn't exist anywhere").
      assert result == {:error, :entity_definition_not_found}

      assert result ==
               SolutionPack.export([], [entity_b.name], "1.0.0",
                 prefix: tenant_a.schema_name,
                 user_id: subject
               )
    end

    test "first offending name wins deterministically when multiple names are given" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req304-ac4-order")
      real = create_entity_definition!(tenant.schema_name)
      missing_first = unique("req304_missing_first")
      missing_second = unique("req304_missing_second")

      assert SolutionPack.export(
               [],
               [missing_first, real.name, missing_second],
               "1.0.0",
               prefix: tenant.schema_name,
               user_id: Ecto.UUID.generate()
             ) == {:error, :entity_definition_not_found}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # GH #2746 -- entity-definition export reads through TypeAccess (export/4
  # itself, not a route). A denied type and an absent type are the same
  # not-found shape; names without a subject fail closed before any read.
  # ═══════════════════════════════════════════════════════════════════════════

  describe "GH #2746: export/4 applies TypeAccess to every entity definition read" do
    test "T1: a denied name and an absent name give byte-identical export/4 results" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2746-t1")
      restricted = create_entity_definition!(tenant.schema_name)
      user = insert_user!(tenant.schema_name, "t1")
      insert_type_restriction!(tenant.schema_name, restricted.name)
      absent = unique("gh2746_absent")

      denied_result =
        SolutionPack.export([], [restricted.name], "1.0.0",
          prefix: tenant.schema_name,
          user_id: user.id
        )

      absent_result =
        SolutionPack.export([], [absent], "1.0.0", prefix: tenant.schema_name, user_id: user.id)

      assert denied_result == {:error, :entity_definition_not_found}
      assert absent_result == {:error, :entity_definition_not_found}
      assert :erlang.term_to_binary(denied_result) == :erlang.term_to_binary(absent_result)
    end

    test "T2: a granted user packs the restricted entity definition" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2746-t2")
      restricted = create_entity_definition!(tenant.schema_name)
      user = insert_user!(tenant.schema_name, "t2")
      insert_type_restriction!(tenant.schema_name, restricted.name)
      insert_type_grant!(tenant.schema_name, user.id, restricted.name)

      assert {:ok, doc} =
               SolutionPack.export([], [restricted.name], "1.0.0",
                 prefix: tenant.schema_name,
                 user_id: user.id
               )

      assert [%{name: name}] = doc.entity_definitions
      assert name == restricted.name
    end

    test "T3: an unrestricted entity definition packs for any subject" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2746-t3")
      open = create_entity_definition!(tenant.schema_name)

      assert {:ok, doc} =
               SolutionPack.export([], [open.name], "1.0.0",
                 prefix: tenant.schema_name,
                 user_id: Ecto.UUID.generate()
               )

      assert [%{name: name}] = doc.entity_definitions
      assert name == open.name
    end

    test "T4: names without a subject fail closed with :missing_subject before any read" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2746-t4")
      open = create_entity_definition!(tenant.schema_name)

      assert SolutionPack.export([], [open.name], "1.0.0", prefix: tenant.schema_name) ==
               {:error, :missing_subject}
    end

    test "T5: the first hidden name wins whether it is denied or absent" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2746-t5")
      restricted = create_entity_definition!(tenant.schema_name)
      user = insert_user!(tenant.schema_name, "t5")
      insert_type_restriction!(tenant.schema_name, restricted.name)
      absent = unique("gh2746_t5_absent")
      real = create_entity_definition!(tenant.schema_name, %{name: unique("gh2746_t5_real")})

      opts = [prefix: tenant.schema_name, user_id: user.id]

      assert SolutionPack.export([], [absent, real.name], "1.0.0", opts) ==
               {:error, :entity_definition_not_found}

      assert SolutionPack.export([], [restricted.name, absent], "1.0.0", opts) ==
               {:error, :entity_definition_not_found}

      assert SolutionPack.export([], [real.name, restricted.name], "1.0.0", opts) ==
               {:error, :entity_definition_not_found}
    end
  end

  defp insert_user!(schema_name, suffix) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "gh2746-user-#{suffix}-#{Ecto.UUID.generate()}",
      display_name: "GH #2746 Test User",
      email: "gh2746-#{suffix}-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema_name)
  end

  defp insert_type_restriction!(schema_name, entity_type) do
    Repo.insert_all(
      "entity_type_restrictions",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          entity_type: entity_type,
          inserted_at: NaiveDateTime.utc_now(),
          updated_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: schema_name
    )
  end

  defp insert_type_grant!(schema_name, user_id, entity_type) do
    Repo.insert_all(
      "user_entity_type_grants",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          user_id: Ecto.UUID.dump!(user_id),
          entity_type: entity_type,
          inserted_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: schema_name
    )
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # REQ-306 -- REQ-305's install path: round-trip, name-collision rollback,
  # malformed-entry rejection, old-pack compatibility, :inactive-only install.
  # See test/specs/REQ-306.md for the full acceptance-criterion mapping. The
  # cross-tenant-export criterion (REQ-306 AC5) is covered by the existing
  # "AC3/AC4" describe block above (REQ-304's own coverage) rather than
  # duplicated here -- same export/3 code path, same not-found error shape.
  # ═══════════════════════════════════════════════════════════════════════════

  describe "REQ-306 round-trip: export from tenant A, install into tenant B, byte-identical row" do
    test "installed entity definition's definition_json/display_name/logical_shape_version match the exported source exactly, status :inactive" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "req306-roundtrip-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "req306-roundtrip-b")
      cleanup_solution_pack_installs!(tenant_b.tenant_id)

      source = create_entity_definition!(tenant_a.schema_name)

      assert {:ok, source} =
               EntityDefinitions.get_definition_by_name(source.name, tenant_a.schema_name)

      # AC1 -- via REQ-304's real export path.
      assert {:ok, exported} =
               SolutionPack.export([], [source.name], "1.0.0",
                 prefix: tenant_a.schema_name,
                 user_id: Ecto.UUID.generate()
               )

      # Simulate the key-shape boundary between export and install -- the same
      # one a route layer's decoded request body would cross -- rather than
      # handing install/3 the atom-keyed Elixir map export/4 returns
      # in-process. install/3's own moduledoc requires string keys. See
      # stringify_keys/1's own comment for why this is NOT a real
      # Jason.encode!/decode! round-trip.
      wire_document = stringify_keys(exported)

      actor_id = Ecto.UUID.generate()

      # AC1 -- via REQ-305's real install path, into a DIFFERENT tenant schema.
      assert {:ok, result} =
               SolutionPack.install(wire_document, actor_id, prefix: tenant_b.schema_name)

      assert [installed] = result.installed_entity_definitions
      assert installed.source_entity_definition_id == source.id
      assert installed.name == source.name
      assert installed.status == "installed"
      assert is_binary(installed.new_entity_definition_id)
      refute installed.new_entity_definition_id == source.id

      # Query the ACTUAL row Postgres now holds in tenant B, not just the
      # in-memory install result -- proves the write really landed and with
      # the right content, not merely that install/3 claimed success.
      assert {:ok, installed_row} =
               EntityDefinitions.get_definition_by_name(source.name, tenant_b.schema_name)

      assert installed_row.id == installed.new_entity_definition_id
      assert installed_row.definition_json == source.definition_json
      assert installed_row.display_name == source.display_name
      assert installed_row.logical_shape_version == source.logical_shape_version
      assert installed_row.name == source.name

      # AC6 (0026 SS2) -- :inactive-only, no activate_definition/4 call.
      assert installed_row.status == :inactive

      # Never installed into the SOURCE tenant a second time.
      assert entity_definition_count(tenant_a.schema_name, source.name) == 1
    end
  end

  describe "REQ-306 name-collision rollback: whole install fails, nothing from the pack lands" do
    test "an entity_definitions entry colliding with an existing row aborts the WHOLE transaction -- zero new rows in process_definitions, variable_schemas, entity_definitions" do
      target = TenantFixture.provisioned_tenant!(slug_prefix: "req306-collision")
      cleanup_solution_pack_installs!(target.tenant_id)

      # Pre-existing entity definition already in the TARGET tenant.
      existing = create_entity_definition!(target.schema_name)

      assert {:ok, existing} =
               EntityDefinitions.get_definition_by_name(existing.name, target.schema_name)

      # A colliding entry: same name, and IDENTICAL definition_json content as
      # the existing row, so create_definition/2's own freshly-recomputed
      # logical_shape_version (Shape.logical_shape_of/1, derived from content,
      # never from the pack's own logical_shape_version field) matches the
      # existing row's -- the real (tenant_id, name, logical_shape_version)
      # collision 0026 SS2 specifies, not merely a same-name coincidence.
      colliding_entity_json =
        packed_entity_definition_json(%{
          "name" => existing.name,
          "display_name" => existing.display_name,
          "definition_json" => existing.definition_json
        })

      process_key = unique("req306-collision-pd")
      pd_source_id = Ecto.UUID.generate()
      schema_content = Jason.encode!(%{"type" => "string"})

      document =
        pack_document(%{
          definitions: [packed_definition_json(pd_source_id, process_key)],
          variable_schemas: [
            packed_variable_schema_json(pd_source_id, "order_id", schema_content)
          ],
          entity_definitions: [colliding_entity_json]
        })

      actor_id = Ecto.UUID.generate()

      assert {:error, {:persistence, %Ecto.Changeset{}}} =
               SolutionPack.install(document, actor_id, prefix: target.schema_name)

      # Query every affected table directly -- don't just trust the error tuple.
      assert process_definition_count(target.schema_name, process_key) == 0

      assert Repo.aggregate(VariableSchema, :count, :id, prefix: target.schema_name) == 0

      # Still exactly the ONE pre-existing row -- no duplicate, no partial
      # second row from the aborted attempt.
      assert entity_definition_count(target.schema_name, existing.name) == 1

      # The global solution_pack_installs row this install attempted to write
      # also rolled back (same transaction).
      assert Repo.aggregate(
               from(s in SolutionPackInstall, where: s.pack_id == ^document["pack_id"]),
               :count,
               :id
             ) == 0
    end
  end

  describe "REQ-306 malformed entity_definitions entries: typed rejection, zero rows written" do
    test "missing name -- {:error, :invalid_pack_document}, nothing written" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req306-malformed-name")

      bad_entry = packed_entity_definition_json() |> Map.delete("name")
      document = pack_document(%{entity_definitions: [bad_entry]})

      assert SolutionPack.install(document, Ecto.UUID.generate(), prefix: tenant.schema_name) ==
               {:error, :invalid_pack_document}

      assert Repo.aggregate(EntityDefinition, :count, :id, prefix: tenant.schema_name) == 0
    end

    test "missing definition_json -- {:error, :invalid_pack_document}, nothing written" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req306-malformed-defjson")

      bad_entry = packed_entity_definition_json() |> Map.delete("definition_json")
      document = pack_document(%{entity_definitions: [bad_entry]})

      assert SolutionPack.install(document, Ecto.UUID.generate(), prefix: tenant.schema_name) ==
               {:error, :invalid_pack_document}

      assert Repo.aggregate(EntityDefinition, :count, :id, prefix: tenant.schema_name) == 0
    end

    test "wrong field type -- definition_json as a string, not an object -- {:error, :invalid_pack_document}, nothing written" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req306-malformed-type")

      bad_entry = packed_entity_definition_json(%{"definition_json" => "not-an-object"})
      document = pack_document(%{entity_definitions: [bad_entry]})

      assert SolutionPack.install(document, Ecto.UUID.generate(), prefix: tenant.schema_name) ==
               {:error, :invalid_pack_document}

      assert Repo.aggregate(EntityDefinition, :count, :id, prefix: tenant.schema_name) == 0
    end
  end

  describe "REQ-306 old-pack compatibility: entity_definitions key OMITTED entirely (not [])" do
    test "a document with no entity_definitions key at all still installs its other sections exactly as before" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req306-old-pack")
      cleanup_solution_pack_installs!(tenant.tenant_id)

      process_key = unique("req306-oldpack-pd")
      pd_source_id = Ecto.UUID.generate()
      schema_content = Jason.encode!(%{"type" => "string"})

      # Built via pack_document/1 with NO :entity_definitions key in `fields`
      # -- pack_document/1 only adds the "entity_definitions" wire key when a
      # caller supplies one (see its own comment above), so the resulting map
      # genuinely has no such key, not merely an empty list under it.
      document =
        pack_document(%{
          definitions: [packed_definition_json(pd_source_id, process_key)],
          variable_schemas: [
            packed_variable_schema_json(pd_source_id, "customer_id", schema_content)
          ]
        })

      refute Map.has_key?(document, "entity_definitions")

      actor_id = Ecto.UUID.generate()

      assert {:ok, result} = SolutionPack.install(document, actor_id, prefix: tenant.schema_name)

      assert [%{process_key: ^process_key, status: "installed"}] = result.installed_definitions
      assert result.installed_entity_definitions == []
      assert result.variable_schemas_written == 1

      assert process_definition_count(tenant.schema_name, process_key) == 1
      assert Repo.aggregate(VariableSchema, :count, :id, prefix: tenant.schema_name) == 1
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # ISS-0582 regression -- pack_entity_definition/1's logical_shape_version
  # must be JSON-safe, and must decode back to the original raw digest
  # ═══════════════════════════════════════════════════════════════════════════

  describe "ISS-0582 regression: pack_document's logical_shape_version survives a real Jason encode/decode round trip" do
    test "export/4's pack_document is real Jason.encode!/1-safe, and the round-tripped logical_shape_version decodes back to the original raw digest" do
      # GH#1196 / ISS-0582: pack_entity_definition/1 used to embed
      # EntityDefinition.logical_shape_version -- a raw SHA-256 :binary
      # column, arbitrary non-UTF-8 bytes -- directly into the pack document,
      # which is documented (this module's @type pack_document, the
      # SolutionPacks router) to be a JSON-serializable structure. Calling
      # Jason.encode!/1 on a real packed document raised Jason.EncodeError.
      # The fix hex-encodes at pack time (encode_logical_shape_version/1) and
      # hex-decodes at parse time (decode_logical_shape_version/1). This test
      # exercises the REAL export/4 -> Jason.encode!/1 -> Jason.decode!/1
      # round trip end to end, rather than re-implementing encode/decode by
      # hand, so a regression that reintroduces a raw-binary field (or
      # reverts the hex-encoding) fails here exactly the way it failed for
      # real before the fix.
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "iss0582-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "iss0582-b")
      cleanup_solution_pack_installs!(tenant_b.tenant_id)

      created = create_entity_definition!(tenant_a.schema_name)

      assert {:ok, original} =
               EntityDefinitions.get_definition_by_name(created.name, tenant_a.schema_name)

      # The raw digest is genuinely non-UTF-8-safe binary -- a SHA-256 digest
      # of a real column value -- so this isn't a coincidentally-printable
      # fixture that would pass even without hex-encoding.
      refute String.valid?(original.logical_shape_version)

      assert {:ok, doc} =
               SolutionPack.export([], [original.name], "1.0.0",
                 prefix: tenant_a.schema_name,
                 user_id: Ecto.UUID.generate()
               )

      # AC1: pack_document must be real-Jason.encode!/1-safe. This is the
      # exact call that raised Jason.EncodeError before the fix.
      json = Jason.encode!(doc)

      # AC1 (continued): and the JSON is genuinely parseable back.
      assert %{"entity_definitions" => [decoded_packed]} = Jason.decode!(json)

      # AC2: the round-tripped logical_shape_version, hex-decoded, is
      # byte-for-byte identical to the original raw digest -- not just
      # "some string survived JSON", but the exact original bytes.
      assert decoded_packed["logical_shape_version"] ==
               Base.encode16(original.logical_shape_version, case: :lower)

      assert Base.decode16!(decoded_packed["logical_shape_version"], case: :lower) ==
               original.logical_shape_version

      # AC2 (closing the loop): installing the real decoded JSON document
      # into a DIFFERENT tenant via the real install/3 path succeeds, and the
      # installed row's own logical_shape_version (recomputed by
      # create_definition/2 from the same definition_json) matches the
      # original tenant's value byte-for-byte -- proving the whole
      # export -> JSON -> install pipeline is intact, not just the
      # encode/decode helpers in isolation.
      decoded_document = Jason.decode!(json)

      assert {:ok, install_result} =
               SolutionPack.install(decoded_document, Ecto.UUID.generate(),
                 prefix: tenant_b.schema_name
               )

      assert [%{name: installed_name}] = install_result.installed_entity_definitions

      assert {:ok, installed} =
               EntityDefinitions.get_definition_by_name(installed_name, tenant_b.schema_name)

      assert installed.logical_shape_version == original.logical_shape_version
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # REQ-379 -- solution-pack install-tracking write path
  # (lib/letflow/design/req379-solution-pack-install-write-path.md)
  # `solution_pack_installs`/`solution_pack_artefact_bases` capture at real
  # install time, via `run_install/5`'s new `capture_artefact_bases/4` step.
  # See test/specs/REQ-379.md for the full AC -> test-case mapping.
  # ═══════════════════════════════════════════════════════════════════════════

  # Independent, test-local re-implementation of `canonicalize_artefact_content/1`
  # (solution_pack.ex, private) -- same four steps (design §3): recursively sort
  # map keys, rebuild via Jason.OrderedObject.new/1 so sorted order survives
  # encoding, map over lists without reordering, convert atoms via
  # Atom.to_string/1, pass everything else through unchanged, then
  # Jason.encode!/1. Written independently (not by copy-pasting the private
  # function under test) so this test can actually catch a canonicalization bug
  # in the implementation rather than trivially agreeing with it.
  defp req379_canonicalize(value) when is_map(value) and not is_struct(value) do
    value
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(fn key -> {key, req379_canonicalize(Map.get(value, key))} end)
    |> Jason.OrderedObject.new()
  end

  defp req379_canonicalize(value) when is_list(value), do: Enum.map(value, &req379_canonicalize/1)

  defp req379_canonicalize(value)
       when is_atom(value) and not is_boolean(value) and not is_nil(value),
       do: Atom.to_string(value)

  defp req379_canonicalize(value), do: value

  defp req379_canonical_json(value), do: value |> req379_canonicalize() |> Jason.encode!()

  defp process_definition_count_by_id(schema_name, id) do
    Repo.aggregate(from(d in ProcessDefinition, where: d.id == ^id), :count, :id,
      prefix: schema_name
    )
  end

  defp artefact_input(type, id, content),
    do: %{artefact_type: type, artefact_id: id, content: content}

  # >32 entries deliberately escapes BEAM's "flatmap" map representation.
  # TEST-DESIGN-VALIDATOR's own mutation testing found that a <=32-key fixture
  # (this helper's original shape) CANNOT discriminate a broken/deleted
  # canonicalizer: Erlang/Elixir maps with at most 32 keys ("flatmaps") always
  # iterate in term order, which for binary keys is byte-lexicographic --
  # identical to what `Enum.sort/1` produces. So `canonicalize_artefact_content/1`
  # replaced outright by a bare `Jason.encode!/1` (canonicalization deleted
  # entirely) still produced byte-identical output to this file's own
  # independent `req379_canonicalize/1` for every small fixture, and all 21
  # tests kept passing. Above 32 keys, Erlang switches to a hash-array-mapped
  # trie whose iteration order is hash-bucket order, not lexicographic --
  # empirically confirmed for this exact key shape (`elixir -e` against 40
  # "field_NN" keys: `Map.keys/1` came back in a genuinely unsorted order, not
  # ascending field_01..field_40) -- so a missing/broken sort step here is
  # actually observable. See the fail-then-pass mutation re-verification in
  # this describe block's own commit message / handoff for the two concrete
  # mutants this was checked against.
  defp req379_large_unsorted_map(tag) do
    for n <- 40..1//-1, into: %{} do
      {"field_" <> String.pad_leading(Integer.to_string(n), 2, "0"), "#{tag}-#{n}"}
    end
  end

  # A graph whose top-level "metadata" key is NOT part of Graph.from_map/1's
  # validated shape (only "nodes"/"edges" are read there -- graph.ex:282-291)
  # but IS part of the raw map ProcessDefinition.create_changeset/2 casts
  # verbatim into the :graph column (process_definition.ex:97, :graph, :map,
  # no key-filtering) -- so this survives storage untouched and gives AC2's
  # test real, non-trivial nested-key-order data to canonicalize, without
  # needing a HUMAN_TASK/SERVICE_TASK node's own attribute-validation rules.
  # The nested "large" key holds a >32-key map (see
  # req379_large_unsorted_map/1 above) specifically so this fixture can
  # discriminate a broken/missing sort step, not just "some" key reordering.
  defp req379_graph_with_metadata(tag) do
    Map.merge(graph_start_end(), %{
      "metadata" => %{
        "zebra" => tag,
        "apple" => %{"nested_zulu" => true, "nested_alpha" => false, "id" => tag},
        "large" => req379_large_unsorted_map(tag)
      }
    })
  end

  describe "REQ-379 AC1 -- install inserts exactly one solution_pack_installs row" do
    test "exactly one row, installed_version matches, installed_at is real and recent" do
      # Regression test on ALREADY-EXISTING behavior (design §0): insert_install_row/2
      # predates this branch (REQ-078). Still required because REQ-379's AC1 says
      # "proven by a test," and this branch's own refactor (§5.2: insert_install_row/2
      # now takes a shared `captured_at` argument instead of reading the clock itself)
      # must not silently break it.
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req379-ac1")
      cleanup_solution_pack_installs!(tenant.tenant_id)

      before_install = DateTime.utc_now()

      doc =
        pack_document(%{
          definitions: [
            packed_definition_json(Ecto.UUID.generate(), unique("req379-ac1-pd"))
          ]
        })

      assert {:ok, result} =
               SolutionPack.install(doc, Ecto.UUID.generate(), prefix: tenant.schema_name)

      rows =
        Repo.all(
          from(s in SolutionPackInstall,
            where: s.tenant_id == ^tenant.tenant_id and s.pack_id == ^doc["pack_id"]
          )
        )

      assert length(rows) == 1,
             "expected exactly one solution_pack_installs row, got #{length(rows)}"

      [row] = rows
      assert row.installed_version == doc["version"]
      assert row.id == result.install_id
      refute is_nil(row.installed_at)

      # Real, non-sentinel timestamp -- brackets it against a `DateTime.utc_now/0`
      # read taken just before the install call, and against a fresh one taken now.
      assert DateTime.compare(row.installed_at, before_install) in [:gt, :eq]
      assert DateTime.compare(row.installed_at, DateTime.utc_now()) in [:lt, :eq]
    end
  end

  describe "REQ-379 AC2 -- install captures one canonical base row per delivered definition" do
    test "one row per definition, real artefact_id, base_version matches, base_content byte-for-byte canonical" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req379-ac2")
      cleanup_solution_pack_installs!(tenant.tenant_id)

      source_id_1 = Ecto.UUID.generate()
      source_id_2 = Ecto.UUID.generate()
      process_key_1 = unique("req379-ac2-pd1")
      process_key_2 = unique("req379-ac2-pd2")
      graph_1 = req379_graph_with_metadata("graph-one")
      graph_2 = req379_graph_with_metadata("graph-two")

      doc =
        pack_document(%{
          definitions: [
            packed_definition_json(source_id_1, process_key_1, graph_1),
            packed_definition_json(source_id_2, process_key_2, graph_2)
          ]
        })

      assert {:ok, result} =
               SolutionPack.install(doc, Ecto.UUID.generate(), prefix: tenant.schema_name)

      assert length(result.installed_definitions) == 2

      base_rows =
        Repo.all(
          from(b in SolutionPackArtefactBase,
            where: b.tenant_id == ^tenant.tenant_id and b.pack_id == ^doc["pack_id"]
          )
        )

      assert length(base_rows) == 2,
             "expected exactly one solution_pack_artefact_bases row per delivered definition"

      by_new_id =
        Map.new(result.installed_definitions, fn installed ->
          {installed.new_definition_id, installed}
        end)

      graphs_by_process_key = %{process_key_1 => graph_1, process_key_2 => graph_2}

      for row <- base_rows do
        assert row.artefact_type == "process_definition"
        assert row.base_version == doc["version"]
        refute is_nil(row.captured_at)

        installed = Map.fetch!(by_new_id, row.artefact_id)
        expected_graph = Map.fetch!(graphs_by_process_key, installed.process_key)

        # Structural equality via decode -- proves it's valid, semantically-equal JSON
        # (a plain JSON round trip of the expected graph, key order irrelevant to
        # Elixir map equality).
        assert Jason.decode!(row.base_content) == Jason.decode!(Jason.encode!(expected_graph))

        # Byte-for-byte canonical-form equality -- proves SORTED-KEY canonical
        # form specifically, not merely "some valid JSON encoding of the right
        # data." A key-ordering bug in the implementation would pass the
        # structural check above but fail this one.
        assert row.base_content == req379_canonical_json(expected_graph)
      end

      # Every artefact_id this write path used is a real, installed
      # ProcessDefinition.id in the installing tenant's own schema (design §2/INV-ARTB-3)
      # -- not the pack's source-tenant definition_id.
      for row <- base_rows do
        assert process_definition_count_by_id(tenant.schema_name, row.artefact_id) == 1
        refute row.artefact_id in [source_id_1, source_id_2]
      end
    end
  end

  describe "REQ-379 AC3 -- re-capture never overwrites an existing base snapshot" do
    test "second capture_artefact_bases/4 call for the same key is a silent no-op, original base_content survives" do
      # Architectural note (design §10.3): a literal second SolutionPack.install/3
      # call for the same (tenant_id, pack_id) always fails with
      # {:error, :duplicate_pack_install} (uq_solution_pack_install_active,
      # REQ-078) before reaching any artefact-base code -- there is no real
      # HTTP/install/3 re-install path to exercise AC3 through today. This test
      # therefore calls capture_artefact_bases/4 directly, which the design made
      # public specifically for this seam (design §5.1, §10.3).
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req379-ac3")
      cleanup_solution_pack_installs!(tenant.tenant_id)

      pack_id = unique("req379-ac3-pack")
      artefact_id = Ecto.UUID.generate()
      captured_at = ~U[2026-01-02 03:04:05.000000Z]

      content_a = %{"content" => "original", "nested" => %{"z" => 1, "a" => 2}}
      content_b = %{"content" => "attempted-overwrite", "nested" => %{"z" => 99, "a" => 98}}

      snapshot = fn content ->
        [%{artefact_type: "process_definition", artefact_id: artefact_id, content: content}]
      end

      # 1. First capture: content A lands.
      assert {:ok, [base_a]} =
               SolutionPack.capture_artefact_bases(
                 tenant.tenant_id,
                 pack_id,
                 "1.0.0",
                 snapshot.(content_a),
                 captured_at
               )

      assert base_a.base_content == req379_canonical_json(content_a)

      rows_after_first =
        Repo.all(
          from(b in SolutionPackArtefactBase,
            where:
              b.tenant_id == ^tenant.tenant_id and b.pack_id == ^pack_id and
                b.artefact_id == ^artefact_id
          )
        )

      assert length(rows_after_first) == 1
      assert hd(rows_after_first).base_content == req379_canonical_json(content_a)

      # 2. Simulate the tenant having since locally adapted the artefact --
      # this touches only process_definitions in a real install flow (design
      # §10.3 step 2); solution_pack_artefact_bases itself is never touched by
      # a local edit. No DB mutation is required here for this assertion to be
      # meaningful: the point under test is what the SECOND
      # capture_artefact_bases/4 call does to the base row, not the local edit
      # itself.

      # 3. Second capture attempt: SAME key, SAME base_version ("the same
      # version"), DIFFERENT content B -- simulating what a re-delivered pack
      # would attempt to write. Must not raise, and must not error.
      assert {:ok, [base_b_attempted]} =
               SolutionPack.capture_artefact_bases(
                 tenant.tenant_id,
                 pack_id,
                 "1.0.0",
                 snapshot.(content_b),
                 captured_at
               )

      # Per design §5.1: the returned struct reflects the ATTEMPTED snapshot on
      # a no-op conflict, not necessarily DB state -- so this assertion is
      # deliberately about the DB read below, not about base_b_attempted's own
      # base_content field.
      assert is_struct(base_b_attempted, SolutionPackArtefactBase)

      # 4. THE AC3 ASSERTION: still exactly one row for this key, and its
      # base_content is STILL canonical(A) -- never canonical(B).
      rows_after_second =
        Repo.all(
          from(b in SolutionPackArtefactBase,
            where:
              b.tenant_id == ^tenant.tenant_id and b.pack_id == ^pack_id and
                b.artefact_id == ^artefact_id
          )
        )

      assert length(rows_after_second) == 1,
             "a conflicting capture_artefact_bases/4 call must never insert a second row"

      [surviving_row] = rows_after_second
      assert surviving_row.id == hd(rows_after_first).id
      assert surviving_row.base_content == req379_canonical_json(content_a)
      refute surviving_row.base_content == req379_canonical_json(content_b)
    end
  end

  describe "REQ-379 AC4 -- compute_pack_update_plan/5 against real base rows classifies all four outcomes" do
    test "install four real definitions, classify unchanged/clean_update/local_only/conflict end to end" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req379-ac4")
      cleanup_solution_pack_installs!(tenant.tenant_id)

      # Four distinct process keys so each installed definition/base row is
      # unambiguously correlated back to its intended classification bucket.
      keys = %{
        unchanged: unique("req379-ac4-unchanged"),
        clean_update: unique("req379-ac4-clean-update"),
        local_only: unique("req379-ac4-local-only"),
        conflict: unique("req379-ac4-conflict")
      }

      definitions =
        for {bucket, process_key} <- keys do
          packed_definition_json(
            Ecto.UUID.generate(),
            process_key,
            req379_graph_with_metadata(Atom.to_string(bucket))
          )
        end

      doc = pack_document(%{definitions: definitions})

      assert {:ok, result} =
               SolutionPack.install(doc, Ecto.UUID.generate(), prefix: tenant.schema_name)

      assert length(result.installed_definitions) == 4

      new_id_by_process_key =
        Map.new(result.installed_definitions, &{&1.process_key, &1.new_definition_id})

      base_content_by_process_key =
        for {process_key, artefact_id} <- new_id_by_process_key, into: %{} do
          base =
            Repo.one!(
              from(b in SolutionPackArtefactBase,
                where:
                  b.tenant_id == ^tenant.tenant_id and b.pack_id == ^doc["pack_id"] and
                    b.artefact_id == ^artefact_id
              )
            )

          {process_key, base.base_content}
        end

      artefact_id_for = fn bucket ->
        Map.fetch!(new_id_by_process_key, Map.fetch!(keys, bucket))
      end

      base_content_for = fn bucket ->
        Map.fetch!(base_content_by_process_key, Map.fetch!(keys, bucket))
      end

      different_content = fn bucket, tag ->
        req379_canonical_json(%{"different_for" => Atom.to_string(bucket), "tag" => tag})
      end

      artefact_type = "process_definition"

      theirs_artefacts = [
        artefact_input(
          artefact_type,
          artefact_id_for.(:unchanged),
          base_content_for.(:unchanged)
        ),
        artefact_input(
          artefact_type,
          artefact_id_for.(:clean_update),
          base_content_for.(:clean_update)
        ),
        artefact_input(
          artefact_type,
          artefact_id_for.(:local_only),
          different_content.(:local_only, "theirs")
        ),
        artefact_input(
          artefact_type,
          artefact_id_for.(:conflict),
          different_content.(:conflict, "theirs")
        )
      ]

      incoming_artefacts = [
        artefact_input(
          artefact_type,
          artefact_id_for.(:unchanged),
          base_content_for.(:unchanged)
        ),
        artefact_input(
          artefact_type,
          artefact_id_for.(:clean_update),
          different_content.(:clean_update, "incoming")
        ),
        artefact_input(
          artefact_type,
          artefact_id_for.(:local_only),
          base_content_for.(:local_only)
        ),
        artefact_input(
          artefact_type,
          artefact_id_for.(:conflict),
          different_content.(:conflict, "incoming")
        )
      ]

      assert {:ok, plan} =
               Definitions.compute_pack_update_plan(
                 tenant.tenant_id,
                 doc["pack_id"],
                 "2.0.0",
                 theirs_artefacts,
                 incoming_artefacts
               )

      entry_for_bucket = fn bucket ->
        artefact_id = artefact_id_for.(bucket)

        Enum.find(
          plan.entries,
          &(&1.artefact_type == artefact_type and &1.artefact_id == artefact_id)
        )
      end

      unchanged_entry = entry_for_bucket.(:unchanged)
      assert unchanged_entry.classification == :unchanged
      assert unchanged_entry.base == base_content_for.(:unchanged)

      clean_update_entry = entry_for_bucket.(:clean_update)
      assert clean_update_entry.classification == :clean_update
      assert clean_update_entry.base == base_content_for.(:clean_update)

      local_only_entry = entry_for_bucket.(:local_only)
      assert local_only_entry.classification == :local_only
      assert local_only_entry.base == base_content_for.(:local_only)

      conflict_entry = entry_for_bucket.(:conflict)
      assert conflict_entry.classification == :conflict
      assert conflict_entry.base == base_content_for.(:conflict)

      # Sanity guard against a §2 key-choice regression (using the pack's
      # source_definition_id instead of the real installed ProcessDefinition.id
      # as artefact_id): confirms every `base` in the plan really came from
      # THIS write path's own row, correlated by the real installed id, not a
      # coincidental match.
      for bucket <- [:unchanged, :clean_update, :local_only, :conflict] do
        entry = entry_for_bucket.(bucket)
        refute is_nil(entry.base), "#{bucket} artefact unexpectedly had no matching base row"
      end
    end
  end

  # ── GH #2529 -- append_only survives export -> install ─────────────────────

  describe "append_only round-trip (GH #2529)" do
    test "export from tenant A, install into tenant B: definition_json[\"append_only\"] == true" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "gh2529-pack-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "gh2529-pack-b")
      cleanup_solution_pack_installs!(tenant_b.tenant_id)

      source = create_entity_definition!(tenant_a.schema_name, %{append_only: true})

      assert {:ok, source} =
               EntityDefinitions.get_definition_by_name(source.name, tenant_a.schema_name)

      assert source.definition_json["append_only"] == true

      assert {:ok, exported} =
               SolutionPack.export([], [source.name], "1.0.0",
                 prefix: tenant_a.schema_name,
                 user_id: Ecto.UUID.generate()
               )

      wire_document = stringify_keys(exported)

      assert {:ok, %{installed_entity_definitions: [_installed]}} =
               SolutionPack.install(wire_document, Ecto.UUID.generate(),
                 prefix: tenant_b.schema_name
               )

      assert {:ok, installed_row} =
               EntityDefinitions.get_definition_by_name(source.name, tenant_b.schema_name)

      assert installed_row.definition_json["append_only"] == true
      assert installed_row.definition_json == source.definition_json
      assert installed_row.logical_shape_version == source.logical_shape_version
    end

    test "any other unknown top-level key still gives {:error, :invalid_pack_document}" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2529-pack-unknown")

      entry = packed_entity_definition_json()

      bad_entry =
        Map.update!(entry, "definition_json", &Map.put(&1, "frozen", true))

      document = pack_document(%{entity_definitions: [bad_entry]})

      assert SolutionPack.install(document, Ecto.UUID.generate(), prefix: tenant.schema_name) ==
               {:error, :invalid_pack_document}

      assert Repo.aggregate(EntityDefinition, :count, :id, prefix: tenant.schema_name) == 0
    end
  end

  # ── GH #2532 -- min/max/non_negative survive export -> install ─────────────

  defp gh2532_packed_entry_with_qty(qty_field) do
    entry = packed_entity_definition_json()

    Map.update!(entry, "definition_json", fn json ->
      Map.update!(json, "fields", &(&1 ++ [Map.merge(%{"name" => "qty"}, qty_field)]))
    end)
  end

  describe "GH #2532 bounds round-trip" do
    test "export from tenant A, install into tenant B: bounds kept" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "gh2532-pack-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "gh2532-pack-b")
      cleanup_solution_pack_installs!(tenant_b.tenant_id)

      source =
        create_entity_definition!(tenant_a.schema_name, %{
          fields: [
            %{name: "email", type: :string, required: true, queried: true},
            %{name: "qty", type: :integer, min: 1, max: 50},
            %{
              name: "price",
              type: :decimal,
              decimal_precision: 12,
              decimal_scale: 2,
              non_negative: true,
              max: 99.5
            }
          ]
        })

      # Reload so definition_json is the string-keyed JSONB read back from Postgres.
      assert {:ok, source} =
               EntityDefinitions.get_definition_by_name(source.name, tenant_a.schema_name)

      assert {:ok, exported} =
               SolutionPack.export([], [source.name], "1.0.0",
                 prefix: tenant_a.schema_name,
                 user_id: Ecto.UUID.generate()
               )

      assert {:ok, %{installed_entity_definitions: [_installed]}} =
               SolutionPack.install(stringify_keys(exported), Ecto.UUID.generate(),
                 prefix: tenant_b.schema_name
               )

      assert {:ok, installed_row} =
               EntityDefinitions.get_definition_by_name(source.name, tenant_b.schema_name)

      fields = Map.new(installed_row.definition_json["fields"], &{&1["name"], &1})
      assert fields["qty"]["min"] == 1
      assert fields["qty"]["max"] == 50
      assert fields["price"]["non_negative"] == true
      assert fields["price"]["max"] == 99.5
      refute Map.has_key?(fields["price"], "min")
      assert installed_row.definition_json == source.definition_json
      assert installed_row.logical_shape_version == source.logical_shape_version
    end

    # GH #2654 (T10): the decimal_strict key survives export -> install (key map in
    # SolutionPack) and the shape hash, and a string bound on a strict field survives too.
    test "decimal_strict and a string bound round-trip export -> install" do
      tenant_a = TenantFixture.provisioned_tenant!(slug_prefix: "gh2654-pack-a")
      tenant_b = TenantFixture.provisioned_tenant!(slug_prefix: "gh2654-pack-b")
      cleanup_solution_pack_installs!(tenant_b.tenant_id)

      source =
        create_entity_definition!(tenant_a.schema_name, %{
          fields: [
            %{name: "email", type: :string, required: true, queried: true},
            %{
              name: "qty",
              type: :decimal,
              decimal_precision: 12,
              decimal_scale: 3,
              decimal_strict: true,
              min: "0.001"
            }
          ]
        })

      assert {:ok, source} =
               EntityDefinitions.get_definition_by_name(source.name, tenant_a.schema_name)

      assert {:ok, exported} =
               SolutionPack.export([], [source.name], "1.0.0",
                 prefix: tenant_a.schema_name,
                 user_id: Ecto.UUID.generate()
               )

      assert {:ok, %{installed_entity_definitions: [_installed]}} =
               SolutionPack.install(stringify_keys(exported), Ecto.UUID.generate(),
                 prefix: tenant_b.schema_name
               )

      assert {:ok, installed_row} =
               EntityDefinitions.get_definition_by_name(source.name, tenant_b.schema_name)

      qty = Enum.find(installed_row.definition_json["fields"], &(&1["name"] == "qty"))
      assert qty["decimal_strict"] == true
      assert qty["min"] == "0.001"
      assert installed_row.definition_json == source.definition_json
      assert installed_row.logical_shape_version == source.logical_shape_version
    end

    test ~s(unknown field key "minimum" still gives {:error, :invalid_pack_document}) do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2532-pack-unknown")

      entry = gh2532_packed_entry_with_qty(%{"type" => "integer", "minimum" => 0})
      document = pack_document(%{entity_definitions: [entry]})

      assert SolutionPack.install(document, Ecto.UUID.generate(), prefix: tenant.schema_name) ==
               {:error, :invalid_pack_document}

      assert Repo.aggregate(EntityDefinition, :count, :id, prefix: tenant.schema_name) == 0
    end

    test "a JSON null bound in a pack is rejected (:invalid_range), nothing written" do
      tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2532-pack-null")
      cleanup_solution_pack_installs!(tenant.tenant_id)

      entry = gh2532_packed_entry_with_qty(%{"type" => "integer", "min" => nil})
      document = pack_document(%{entity_definitions: [entry]})

      assert {:error, {:validation, violations}} =
               SolutionPack.install(document, Ecto.UUID.generate(), prefix: tenant.schema_name)

      assert Enum.any?(violations, &(&1.rule == :invalid_range and &1.path == [:fields, "qty"]))
      assert Repo.aggregate(EntityDefinition, :count, :id, prefix: tenant.schema_name) == 0
    end
  end
end
