defmodule Letflow.Entities.WritableByProcessTest do
  @moduledoc """
  GH #2587 / REQ-499 PR A4 (design `lib/letflow/design/gh2587-req499-pr-a-prerequisites.md`
  section 5, test brief section 11 "A4", invariant I-11): the `writable_by_process` flag on an
  entity definition document.

    * HTTP: `POST /entities/definitions` and `POST /entities/definitions/:name/activate` through
      the REAL `Letflow.Router` pipeline with a real API token, so the 403s are decided by the
      production permission matrix (`:EntitiesDefinitionsWrite`).
    * Write path: `Definitions.create_definition/3` refuses the flag on a managed type and on a
      type whose write class is not `ordinary` (GH #2618), with the stable rule
      `:writable_by_process_not_permitted` and a message that names the refusal.
    * Solution packs carry the flag only for an EntitiesDefinitionsWrite installer (GH #2619).
    * `ProcessWritable` is pure: `declared?/1`, `classes/0`, `check_settable/3`, `writable?/1`.

  `async: false`: tenant provisioning switches the sandbox to `:auto`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.Api.Authorization
  alias Letflow.Definitions.SolutionPack
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Entities.Definition.Shape
  alias Letflow.Entities.Definition.Validator.Violation
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.ProcessWritable
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.Modules.FixtureManaged
  alias Letflow.Repository
  alias Letflow.TenantFixture

  @rule :writable_by_process_not_permitted

  # ── helpers ─────────────────────────────────────────────────────────────────────────────────

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp request(method, path, ctx, body) do
    conn =
      case body do
        nil ->
          conn(method, path)

        body ->
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
      end

    conn
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> dispatch()
  end

  defp body_of(conn), do: Jason.decode!(conn.resp_body)

  defp tenant_ctx(slug_prefix, roles) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)

    on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant.tenant_id))

      Repo.delete_all(
        from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant.tenant_id)
      )
    end)

    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "gh2587-a4-#{Ecto.UUID.generate()}",
        display_name: "GH-2587 A4 Test User",
        email: "gh2587-a4-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: tenant.schema_name)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: tenant.schema_name)

    %{
      tenant_id: tenant.tenant_id,
      schema: tenant.schema_name,
      slug: tenant.tenant.slug,
      plaintext: plaintext,
      user_id: user.id
    }
  end

  defp http_definition(name, extra \\ %{}) do
    Map.merge(
      %{
        "name" => name,
        "display_name" => "A4 #{name}",
        "fields" => [%{"name" => "title", "type" => "string", "required" => true}]
      },
      extra
    )
  end

  defp attrs(name, extra \\ %{}) do
    %{
      definition:
        Map.merge(
          %{
            name: name,
            display_name: "A4 #{name}",
            fields: [%{name: "title", type: :string, required: true}]
          },
          extra
        ),
      created_by: Ecto.UUID.generate()
    }
  end

  defp row_count(schema, name) do
    Repo.aggregate(from(d in EntityDefinition, where: d.name == ^name), :count, prefix: schema)
  end

  defp stored_row(schema, name),
    do: Repo.one!(from(d in EntityDefinition, where: d.name == ^name), prefix: schema)

  # ── HTTP: permission, create, activate, malformed ───────────────────────────────────────────

  describe "POST /entities/definitions and activate (:EntitiesDefinitionsWrite only)" do
    test "the two write routes are keyed :EntitiesDefinitionsWrite" do
      assert Authorization.endpoint_policy_key("POST", "/entities/definitions") ==
               :EntitiesDefinitionsWrite

      assert Authorization.endpoint_policy_key("POST", "/entities/definitions/:name/activate") ==
               :EntitiesDefinitionsWrite
    end

    test "a principal holding :EntitiesRecordsWrite but not :EntitiesDefinitionsWrite gets 403" do
      ctx = tenant_ctx("gh2587-a4-deny", ["PROCESS_OPERATOR"])

      assert Authorization.role_allows?(:PROCESS_OPERATOR, :EntitiesRecordsWrite)
      refute Authorization.role_allows?(:PROCESS_OPERATOR, :EntitiesDefinitionsWrite)

      conn =
        request(
          :post,
          "/api/v1/entities/definitions",
          ctx,
          http_definition("flag_deny", %{"writable_by_process" => true})
        )

      assert conn.status == 403
      assert row_count(ctx.schema, "flag_deny") == 0
    end

    test "with :EntitiesDefinitionsWrite: create 201 stores true, activation 200, active row carries it" do
      ctx = tenant_ctx("gh2587-a4-ok", ["PROCESS_DESIGNER"])
      assert Authorization.role_allows?(:PROCESS_DESIGNER, :EntitiesDefinitionsWrite)

      created =
        request(
          :post,
          "/api/v1/entities/definitions",
          ctx,
          http_definition("flag_ok", %{"writable_by_process" => true})
        )

      assert created.status == 201
      assert stored_row(ctx.schema, "flag_ok").definition_json["writable_by_process"] == true

      activated =
        request(:post, "/api/v1/entities/definitions/flag_ok/activate", ctx, %{
          "rationale" => "go-live"
        })

      assert activated.status == 200

      assert {:ok, %EntityDefinition{} = active} =
               Definitions.get_active_definition_by_name("flag_ok", ctx.schema)

      assert active.definition_json["writable_by_process"] == true
      assert ProcessWritable.writable?(active)
    end

    test "absent key stays absent and false is stored as false (neither is writable)" do
      ctx = tenant_ctx("gh2587-a4-absent", ["PROCESS_DESIGNER"])

      assert request(:post, "/api/v1/entities/definitions", ctx, http_definition("flag_absent")).status ==
               201

      assert request(
               :post,
               "/api/v1/entities/definitions",
               ctx,
               http_definition("flag_false", %{"writable_by_process" => false})
             ).status == 201

      absent = stored_row(ctx.schema, "flag_absent")
      false_row = stored_row(ctx.schema, "flag_false")

      refute Map.has_key?(absent.definition_json, "writable_by_process")
      assert false_row.definition_json["writable_by_process"] == false
      refute ProcessWritable.writable?(absent)
      refute ProcessWritable.writable?(false_row)
    end

    test "a non-boolean value is 422 malformed at writable_by_process, no row" do
      ctx = tenant_ctx("gh2587-a4-malformed", ["PROCESS_DESIGNER"])

      for bad <- ["true", 1, %{"a" => 1}] do
        conn =
          request(
            :post,
            "/api/v1/entities/definitions",
            ctx,
            http_definition("flag_bad", %{"writable_by_process" => bad})
          )

        assert conn.status == 422, "#{inspect(bad)}: #{conn.resp_body}"
        assert [error] = body_of(conn)["errors"]
        assert error["code"] == "malformed"
        assert error["path"] == ["writable_by_process"]
      end

      assert row_count(ctx.schema, "flag_bad") == 0
    end

    test "a name the old denied list refused as a false positive (user_feedback) takes the flag: 201, ordinary, writable" do
      ctx = tenant_ctx("gh2618-false-positive", ["PROCESS_DESIGNER"])

      conn =
        request(
          :post,
          "/api/v1/entities/definitions",
          ctx,
          http_definition("user_feedback", %{"writable_by_process" => true})
        )

      assert conn.status == 201, conn.resp_body

      row = stored_row(ctx.schema, "user_feedback")
      assert row.write_class == "ordinary"
      assert ProcessWritable.writable?(row)
    end

    test "a tenant body cannot choose the write class: a write_class key in the body is ignored (201, ordinary)" do
      ctx = tenant_ctx("gh2618-body-class", ["PROCESS_DESIGNER"])

      conn =
        request(
          :post,
          "/api/v1/entities/definitions",
          ctx,
          http_definition("feedback_note", %{
            "writable_by_process" => true,
            "write_class" => "managed",
            "classification" => "org_tree"
          })
        )

      assert conn.status == 201, conn.resp_body

      row = stored_row(ctx.schema, "feedback_note")
      assert row.write_class == "ordinary"
      refute Map.has_key?(row.definition_json, "write_class")
      refute Map.has_key?(row.definition_json, "classification")
    end

    test "JSON null for the flag is dropped by the router (treated as absent): 201, key not stored" do
      ctx = tenant_ctx("gh2587-a4-null", ["PROCESS_DESIGNER"])

      conn =
        request(
          :post,
          "/api/v1/entities/definitions",
          ctx,
          http_definition("flag_null", %{"writable_by_process" => nil})
        )

      assert conn.status == 201, conn.resp_body

      refute Map.has_key?(
               stored_row(ctx.schema, "flag_null").definition_json,
               "writable_by_process"
             )
    end

    test "a mixed-case denied exact name with the flag is refused through the write path" do
      %{schema: schema} = tenant_ctx("gh2587-a4-case", ["PROCESS_DESIGNER"])

      # The name format is lower-case only, so the validator refuses "Role" first (malformed
      # name); the policy itself is case-insensitive and is pinned at pure level below.
      assert {:error, {:validation, [%Violation{} | _]}} =
               Definitions.create_definition(
                 attrs("Role", %{writable_by_process: true}),
                 schema
               )

      assert row_count(schema, "Role") == 0
    end

    test "PROCESS_OPERATOR gets a real 403 on the activate route" do
      ctx = tenant_ctx("gh2587-a4-act403", ["PROCESS_OPERATOR"])

      conn =
        request(:post, "/api/v1/entities/definitions/anything/activate", ctx, %{
          "rationale" => "x"
        })

      assert conn.status == 403
    end

    test "the same denied names WITHOUT the flag (and with false) still create" do
      ctx = tenant_ctx("gh2587-a4-noflag", ["PROCESS_DESIGNER"])

      for name <- ["org_gh2581_probe", "user_profile", "role", "attachment_meta"] do
        assert request(:post, "/api/v1/entities/definitions", ctx, http_definition(name)).status ==
                 201,
               name
      end

      assert request(
               :post,
               "/api/v1/entities/definitions",
               ctx,
               http_definition("users_false", %{"writable_by_process" => false})
             ).status == 201
    end
  end

  # ── context module: managed types ───────────────────────────────────────────────────────────

  describe "Definitions.create_definition/3" do
    test "a managed type with the flag is refused with the managed message, no row" do
      %{schema: schema} = tenant_ctx("gh2587-a4-managed", ["PROCESS_DESIGNER"])
      owner = ManagedTypes.module_owner(FixtureManaged)
      assert MapSet.member?(owner.manages, "fxm_item")

      assert {:error, {:validation, [%Violation{} = violation]}} =
               Definitions.create_definition(
                 attrs("fxm_item", %{writable_by_process: true}),
                 schema,
                 owner
               )

      assert violation.rule == @rule
      assert violation.path == [:writable_by_process]
      assert violation.message =~ "the entity type is managed by a module"
      assert row_count(schema, "fxm_item") == 0
    end

    test "positive control: the same managed type WITHOUT the flag is created and stamped" do
      %{schema: schema} = tenant_ctx("gh2587-a4-managed-ok", ["PROCESS_DESIGNER"])
      owner = ManagedTypes.module_owner(FixtureManaged)

      assert {:ok, %EntityDefinition{managed_by: "fixture_managed"}} =
               Definitions.create_definition(attrs("fxm_item"), schema, owner)
    end

    test "an unmanaged, allowed name with the flag is created" do
      %{schema: schema} = tenant_ctx("gh2587-a4-allowed", ["PROCESS_DESIGNER"])

      assert {:ok, %EntityDefinition{name: "invoice_line"}} =
               Definitions.create_definition(
                 attrs("invoice_line", %{writable_by_process: true}),
                 schema
               )
    end

    test "logical shape differs with the flag, so adopting it is a new version" do
      without = attrs("shape_probe").definition
      with_flag = Map.put(without, :writable_by_process, true)

      refute Shape.logical_shape_of(without) == Shape.logical_shape_of(with_flag)
      refute Shape.content_hash(without) == Shape.content_hash(with_flag)
    end
  end

  # ── solution packs ──────────────────────────────────────────────────────────────────────────

  describe "solution-pack install" do
    defp pack_entity(name, extra) do
      Map.merge(
        %{
          "name" => name,
          "display_name" => "A4 #{name}",
          "fields" => [%{"name" => "title", "type" => "string", "required" => true}]
        },
        extra
      )
    end

    defp pack_document(entity_json) when is_map(entity_json), do: pack_document([entity_json])

    defp pack_document(entity_jsons) when is_list(entity_jsons) do
      %{
        "pack_id" => "gh2587-a4-pack-#{System.unique_integer([:positive])}",
        "version" => "1.0.0",
        "bpm_export_schema_version" => "bpm/definition/v1",
        "exported_at" => "2026-10-15T00:00:00Z",
        "manifest" => %{"required_roles" => []},
        "definitions" => [],
        "variable_schemas" => [],
        "service_catalog_entries" => [],
        "entity_definitions" =>
          Enum.map(entity_jsons, fn entity_json ->
            name = entity_json["name"]

            %{
              "entity_definition_id" => Ecto.UUID.generate(),
              "name" => name,
              "display_name" => "A4 #{name}",
              "logical_shape_version" => Base.encode16(:crypto.hash(:sha256, name), case: :lower),
              "definition_json" => entity_json
            }
          end)
      }
    end

    # A type whose latest version is classed `org_tree`, inserted directly: the write_class
    # trigger rejects an UPDATE, and a tenant body cannot set the class (core assigns it).
    defp seed_org_class(ctx, name) do
      unique = System.unique_integer([:positive])
      hash = :crypto.hash(:sha256, "gh2619-#{name}-#{unique}")

      {:ok, %Repository.ArtifactVersion{version_id: version_id}} =
        Repository.create(
          %{
            artifact_kind: :entity,
            artifact_name: "gh2619_fixture_#{unique}",
            content_type: "application/json",
            content: "{}",
            created_by: Ecto.UUID.generate()
          },
          ctx.schema
        )

      Repo.insert!(
        %EntityDefinition{
          tenant_id: ctx.tenant_id,
          name: name,
          display_name: "seed #{name}",
          definition_json: %{"name" => name, "display_name" => "seed #{name}"},
          content_hash: hash,
          logical_shape_version: hash,
          artifact_version_id: version_id,
          status: :inactive,
          write_class: "org_tree"
        },
        prefix: ctx.schema
      )
    end

    test "T5 all-or-nothing: a clean entity followed by a flagged one create_definition/3 refuses installs neither (422)" do
      ctx = tenant_ctx("gh2587-a4-pack-aon", ["TENANT_ADMIN"])
      seed_org_class(ctx, "pack_org_seeded")

      doc =
        pack_document([
          pack_entity("pack_clean_first", %{}),
          pack_entity("pack_org_seeded", %{"writable_by_process" => true})
        ])

      conn = request(:post, "/api/v1/solution-packs/install", ctx, doc)
      assert conn.status == 422, conn.resp_body
      assert row_count(ctx.schema, "pack_clean_first") == 0
      assert row_count(ctx.schema, "pack_org_seeded") == 1
    end

    test "T1 a pack entity definition carrying writable_by_process: true is refused without the option, nothing installed" do
      %{schema: schema} = tenant_ctx("gh2587-a4-pack-deny", ["TENANT_ADMIN"])
      doc = pack_document(pack_entity("pack_flagged", %{"writable_by_process" => true}))

      assert {:error, {:validation, [%Violation{rule: @rule, path: [:writable_by_process]}]}} =
               SolutionPack.install(doc, Ecto.UUID.generate(), prefix: schema)

      assert row_count(schema, "pack_flagged") == 0
    end

    test "T2 only the literal true authorises: false, nil, \"true\" and 1 are refused" do
      %{schema: schema} = tenant_ctx("gh2619-pack-t2", ["TENANT_ADMIN"])
      doc = pack_document(pack_entity("pack_t2", %{"writable_by_process" => true}))

      for value <- [false, nil, "true", 1] do
        assert {:error, {:validation, [%Violation{rule: @rule}]}} =
                 SolutionPack.install(doc, Ecto.UUID.generate(),
                   prefix: schema,
                   process_writable_authorized: value
                 ),
               inspect(value)
      end

      assert row_count(schema, "pack_t2") == 0
    end

    test "T3 with the option true a flagged ordinary pack installs inactive, never active" do
      %{schema: schema} = tenant_ctx("gh2619-pack-t3", ["TENANT_ADMIN"])
      doc = pack_document(pack_entity("pack_t3", %{"writable_by_process" => true}))

      assert {:ok, _} =
               SolutionPack.install(doc, Ecto.UUID.generate(),
                 prefix: schema,
                 process_writable_authorized: true
               )

      row = stored_row(schema, "pack_t3")
      assert row.status == :inactive
      assert ProcessWritable.declared?(row.definition_json)

      assert Repo.aggregate(
               from(d in EntityDefinition, where: d.name == "pack_t3" and d.status == :active),
               :count,
               prefix: schema
             ) == 0
    end

    test "T4 with the option true a module-managed type still refuses the flag" do
      %{schema: schema} = tenant_ctx("gh2619-pack-t4", ["TENANT_ADMIN"])
      owner = ManagedTypes.module_owner(FixtureManaged)
      doc = pack_document(pack_entity("fxm_item", %{"writable_by_process" => true}))

      assert {:error, {:validation, [%Violation{rule: @rule}]}} =
               SolutionPack.install(
                 doc,
                 Ecto.UUID.generate(),
                 [prefix: schema, process_writable_authorized: true],
                 owner
               )

      assert row_count(schema, "fxm_item") == 0
    end

    test "positive control: the same pack without the flag, and with false, installs" do
      %{schema: schema} = tenant_ctx("gh2587-a4-pack-ok", ["TENANT_ADMIN"])

      assert {:ok, _} =
               SolutionPack.install(
                 pack_document(pack_entity("pack_plain", %{})),
                 Ecto.UUID.generate(),
                 prefix: schema
               )

      assert {:ok, _} =
               SolutionPack.install(
                 pack_document(pack_entity("pack_false", %{"writable_by_process" => false})),
                 Ecto.UUID.generate(),
                 prefix: schema
               )

      assert row_count(schema, "pack_plain") == 1
      assert row_count(schema, "pack_false") == 1
    end

    test "T6a HTTP: TENANT_ADMIN and PROCESS_DESIGNER (EDW holders) install a flagged ordinary pack" do
      for {role, n} <- [{"TENANT_ADMIN", 1}, {"PROCESS_DESIGNER", 2}] do
        ctx = tenant_ctx("gh2619-pack-t6a#{n}", [role])
        name = "pack_t6a_#{n}"
        doc = pack_document(pack_entity(name, %{"writable_by_process" => true}))

        conn = request(:post, "/api/v1/solution-packs/install", ctx, doc)
        assert conn.status == 200, "#{role}: #{conn.resp_body}"
        assert stored_row(ctx.schema, name).status == :inactive
      end
    end

    test "T6b HTTP install refused by create_definition/3 is a generic 422 that echoes nothing" do
      ctx = tenant_ctx("gh2587-a4-pack-http", ["TENANT_ADMIN"])
      seed_org_class(ctx, "pack_http_flagged")
      doc = pack_document(pack_entity("pack_http_flagged", %{"writable_by_process" => true}))

      conn = request(:post, "/api/v1/solution-packs/install", ctx, doc)
      assert conn.status == 422, conn.resp_body
      assert row_count(ctx.schema, "pack_http_flagged") == 1

      # The generic install-route body: neither the rule, the property name nor the
      # entity name is echoed.
      assert conn.resp_body =~ "validation failed"
      refute conn.resp_body =~ "writable_by_process"
      refute conn.resp_body =~ "pack_http_flagged"
    end

    test "T7 a body key or query parameter cannot authorise the flag" do
      ctx = tenant_ctx("gh2619-pack-t7", ["TENANT_ADMIN"])
      seed_org_class(ctx, "pack_t7")

      doc =
        "pack_t7"
        |> pack_entity(%{"writable_by_process" => true})
        |> pack_document()
        |> Map.put("process_writable_authorized", true)

      conn =
        request(
          :post,
          "/api/v1/solution-packs/install?process_writable_authorized=true",
          ctx,
          doc
        )

      refute conn.status == 200, conn.resp_body
      assert row_count(ctx.schema, "pack_t7") == 1
    end

    test "T7 role matrix: every core role that can install a pack also holds EntitiesDefinitionsWrite" do
      for role <- Authorization.roles(),
          Authorization.has_permission?([role], :DefinitionsWrite) do
        assert Authorization.has_permission?([role], :EntitiesDefinitionsWrite),
               "#{role} can install packs without :EntitiesDefinitionsWrite"
      end
    end

    test "T8 :process_writable_authorized is set only by the pack router, from EntitiesDefinitionsWrite" do
      hits =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.filter(&(File.read!(&1) =~ "process_writable_authorized"))
        |> Enum.map(&Path.basename/1)
        |> Enum.sort()

      assert hits == ["process_writable.ex", "solution_pack.ex", "solution_packs.ex"]

      router = File.read!("lib/letflow/routers/solution_packs.ex")
      assert router =~ ":EntitiesDefinitionsWrite"
      assert router =~ "has_permission_in_scope?"
    end
  end

  # ── ProcessWritable (pure) ──────────────────────────────────────────────────────────────────

  describe "ProcessWritable" do
    @classes ~w(managed org_tree identity_adjacent attachment_metadata ordinary)

    test "declared?/1 is true only for a literal true under either key form" do
      assert ProcessWritable.declared?(%{writable_by_process: true})
      assert ProcessWritable.declared?(%{"writable_by_process" => true})
      refute ProcessWritable.declared?(%{writable_by_process: false})
      refute ProcessWritable.declared?(%{"writable_by_process" => "true"})
      refute ProcessWritable.declared?(%{})
      refute ProcessWritable.declared?(nil)
    end

    test "classes/0 is the closed vocabulary of GH #2618" do
      assert ProcessWritable.classes() == @classes
    end

    test "check_settable/3: not declared is :ok for every class and every stamp" do
      for class <- @classes ++ [nil], stamp <- [nil, "fixture_managed"] do
        assert ProcessWritable.check_settable(%{name: "org_unit"}, stamp, class) == :ok,
               inspect({stamp, class})

        assert ProcessWritable.check_settable(
                 %{name: "org_unit", writable_by_process: false},
                 stamp,
                 class
               ) == :ok
      end
    end

    test "T1: check_settable/3 refuses the flag for every class except ordinary, with the stable rule code" do
      for class <- ~w(managed org_tree identity_adjacent attachment_metadata) do
        assert {:error, {:validation, [%Violation{} = violation]}} =
                 ProcessWritable.check_settable(
                   %{name: "t", writable_by_process: true},
                   nil,
                   class
                 ),
               class

        assert violation.rule == @rule
        assert violation.path == [:writable_by_process]

        expected =
          if class == "managed",
            do: "writable_by_process cannot be set: the entity type is managed by a module",
            else: ~s(writable_by_process cannot be set: the entity type is classified "#{class}")

        assert violation.message == expected, class
      end

      assert ProcessWritable.check_settable(
               %{name: "t", writable_by_process: true},
               nil,
               "ordinary"
             ) ==
               :ok
    end

    test "T1: a module stamp refuses the flag even on an ordinary class" do
      assert {:error, {:validation, [%Violation{message: m}]}} =
               ProcessWritable.check_settable(
                 %{name: "t", writable_by_process: true},
                 "fixture_managed",
                 "ordinary"
               )

      assert m == "writable_by_process cannot be set: the entity type is managed by a module"
    end

    test "check_settable/3 reads a string-keyed definition the same way" do
      assert {:error, {:validation, [%Violation{}]}} =
               ProcessWritable.check_settable(
                 %{"name" => "t", "writable_by_process" => true},
                 nil,
                 "identity_adjacent"
               )

      assert ProcessWritable.check_settable(
               %{"name" => "t", "writable_by_process" => true},
               nil,
               "ordinary"
             ) == :ok
    end

    test "writable?/1 truth table: flag x managed x class (only ordinary, unmanaged, flagged)" do
      for flag <- [:absent, false, true],
          managed <- [nil, "fixture_managed"],
          class <- @classes do
        json = if flag == :absent, do: %{}, else: %{"writable_by_process" => flag}

        row = %EntityDefinition{
          name: "t",
          write_class: class,
          managed_by: managed,
          definition_json: json
        }

        expected = flag == true and managed == nil and class == "ordinary"
        assert ProcessWritable.writable?(row) == expected, inspect({flag, managed, class})
      end
    end
  end
end
