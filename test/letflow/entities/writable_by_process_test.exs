defmodule Letflow.Entities.WritableByProcessTest do
  @moduledoc """
  GH #2587 / REQ-499 PR A4 (design `lib/letflow/design/gh2587-req499-pr-a-prerequisites.md`
  section 5, test brief section 11 "A4", invariant I-11): the `writable_by_process` flag on an
  entity definition document.

    * HTTP: `POST /entities/definitions` and `POST /entities/definitions/:name/activate` through
      the REAL `Letflow.Router` pipeline with a real API token, so the 403s are decided by the
      production permission matrix (`:EntitiesDefinitionsWrite`).
    * Write path: `Definitions.create_definition/3` refuses the flag on a managed type and on a
      denied name, with the stable rule `:writable_by_process_not_permitted` and a message that
      names the matched rule.
    * Solution packs refuse the flag (D-A4.6), nothing installed.
    * `ProcessWritable` is pure: `declared?/1`, `matched_rule/1`, `check_settable/2`, `writable?/1`.

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

  defp assert_refused(response_body, message_part) do
    assert [error] = response_body["errors"]
    assert error["code"] == "writable_by_process_not_permitted"
    assert error["path"] == ["writable_by_process"]
    assert error["message"] =~ message_part
  end

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

    test "denied names with the flag are 422, rule code stable, message names the rule, no row" do
      ctx = tenant_ctx("gh2587-a4-denied", ["PROCESS_DESIGNER"])

      cases = [
        {"org_gh2581_probe", ~s(denied prefix "org_")},
        {"user_profile", ~s(denied prefix "user_")},
        {"role", ~s(name "role" is denied)},
        {"attachment_meta", ~s(denied prefix "attachment_")}
      ]

      for {name, message_part} <- cases do
        conn =
          request(
            :post,
            "/api/v1/entities/definitions",
            ctx,
            http_definition(name, %{"writable_by_process" => true})
          )

        assert conn.status == 422, "#{name}: #{conn.status} #{conn.resp_body}"
        assert_refused(body_of(conn), message_part)
        assert row_count(ctx.schema, name) == 0, name
      end
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

    test "all-or-nothing: a clean entity followed by a flagged one installs neither (422)" do
      ctx = tenant_ctx("gh2587-a4-pack-aon", ["TENANT_ADMIN"])

      doc =
        pack_document([
          pack_entity("pack_clean_first", %{}),
          pack_entity("pack_flagged_second", %{"writable_by_process" => true})
        ])

      conn = request(:post, "/api/v1/solution-packs/install", ctx, doc)
      assert conn.status == 422, conn.resp_body
      assert row_count(ctx.schema, "pack_clean_first") == 0
      assert row_count(ctx.schema, "pack_flagged_second") == 0
    end

    test "a pack entity definition carrying writable_by_process: true is refused, nothing installed" do
      %{schema: schema} = tenant_ctx("gh2587-a4-pack-deny", ["TENANT_ADMIN"])
      doc = pack_document(pack_entity("pack_flagged", %{"writable_by_process" => true}))

      assert {:error, {:validation, [%Violation{rule: @rule, path: [:writable_by_process]}]}} =
               SolutionPack.install(doc, Ecto.UUID.generate(), prefix: schema)

      assert row_count(schema, "pack_flagged") == 0
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

    test "HTTP install of a flagged pack is 422, not 500" do
      ctx = tenant_ctx("gh2587-a4-pack-http", ["TENANT_ADMIN"])
      doc = pack_document(pack_entity("pack_http_flagged", %{"writable_by_process" => true}))

      conn = request(:post, "/api/v1/solution-packs/install", ctx, doc)
      assert conn.status == 422, conn.resp_body
      assert row_count(ctx.schema, "pack_http_flagged") == 0

      # The generic install-route body: neither the rule, the property name nor the
      # entity name is echoed.
      assert conn.resp_body =~ "validation failed"
      refute conn.resp_body =~ "writable_by_process"
      refute conn.resp_body =~ "pack_http_flagged"
    end
  end

  # ── ProcessWritable (pure) ──────────────────────────────────────────────────────────────────

  describe "ProcessWritable" do
    test "declared?/1 is true only for a literal true under either key form" do
      assert ProcessWritable.declared?(%{writable_by_process: true})
      assert ProcessWritable.declared?(%{"writable_by_process" => true})
      refute ProcessWritable.declared?(%{writable_by_process: false})
      refute ProcessWritable.declared?(%{"writable_by_process" => "true"})
      refute ProcessWritable.declared?(%{})
      refute ProcessWritable.declared?(nil)
    end

    test "matched_rule/1 over every listed prefix and exact name, plus allowed controls" do
      for prefix <- ProcessWritable.denied_prefixes() do
        assert ProcessWritable.matched_rule(prefix <> "x") == {:prefix, prefix}
        assert ProcessWritable.denied_name?(String.upcase(prefix) <> "x")
      end

      for exact <- ProcessWritable.denied_exact() do
        assert ProcessWritable.matched_rule(exact) == {:exact, exact}
      end

      for allowed <- ["invoice", "orgx", "usery", "rolex", "groupie", "fxm_item"] do
        refute ProcessWritable.denied_name?(allowed), allowed
      end

      assert ProcessWritable.matched_rule(:not_a_binary) == nil
      assert length(ProcessWritable.denied_prefixes()) == 14
      assert length(ProcessWritable.denied_exact()) == 16
    end

    test "check_settable/2: not declared is :ok even for a managed denied name" do
      assert ProcessWritable.check_settable(%{name: "org_unit"}, "fixture_managed") == :ok

      assert ProcessWritable.check_settable(
               %{name: "org_unit", writable_by_process: false},
               nil
             ) == :ok
    end

    test "check_settable/2 refuses a string-keyed definition and a mixed-case exact name" do
      assert {:error, {:validation, [%Violation{message: m}]}} =
               ProcessWritable.check_settable(
                 %{"name" => "org_unit", "writable_by_process" => true},
                 nil
               )

      assert m =~ ~s(denied prefix "org_")

      assert {:error, {:validation, [%Violation{message: m2}]}} =
               ProcessWritable.check_settable(%{name: "Role", writable_by_process: true}, nil)

      assert m2 == ~s(writable_by_process cannot be set: the name "role" is denied)
      assert ProcessWritable.matched_rule("ROLES") == {:exact, "roles"}
    end

    test "check_settable/2 messages are the three closed templates" do
      assert {:error, {:validation, [%Violation{message: m1}]}} =
               ProcessWritable.check_settable(%{name: "x", writable_by_process: true}, "mod")

      assert m1 == "writable_by_process cannot be set: the entity type is managed by a module"

      assert {:error, {:validation, [%Violation{message: m2}]}} =
               ProcessWritable.check_settable(
                 %{name: "user_profile", writable_by_process: true},
                 nil
               )

      assert m2 ==
               ~s(writable_by_process cannot be set: the name matches the denied prefix "user_")

      assert {:error, {:validation, [%Violation{message: m3}]}} =
               ProcessWritable.check_settable(%{name: "role", writable_by_process: true}, nil)

      assert m3 == ~s(writable_by_process cannot be set: the name "role" is denied)

      assert ProcessWritable.check_settable(%{name: "invoice", writable_by_process: true}, nil) ==
               :ok
    end

    test "writable?/1 truth table: flag x managed x name" do
      for flag <- [:absent, false, true],
          managed <- [nil, "fixture_managed"],
          name <- ["invoice", "org_unit"] do
        json = if flag == :absent, do: %{}, else: %{"writable_by_process" => flag}
        row = %EntityDefinition{name: name, managed_by: managed, definition_json: json}

        expected = flag == true and managed == nil and name == "invoice"
        assert ProcessWritable.writable?(row) == expected, inspect({flag, managed, name})
      end
    end
  end
end
