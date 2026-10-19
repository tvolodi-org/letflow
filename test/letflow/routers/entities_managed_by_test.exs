defmodule Letflow.Routers.EntitiesManagedByTest do
  @moduledoc """
  REQ-496 / GH #2530 (decision 0050 D7, M4; design
  `lib/letflow/design/req496-managed-by-and-scope-node-paths.md` §3.1-§3.2, §4, §9 T-01..T-12,
  T-20; spec `test/specs/REQ-496.md`): the generic record routes and the entity-definition routes
  of `Letflow.Routers.Entities` refuse a module-managed entity type with ONE constant 403
  (`Letflow.Api.Error.entity_type_managed/0`), decided before anything else of the request is read,
  while the owning module's own `Records` calls succeed.

  Every test installs the test-only `Letflow.Modules.FixtureManaged` (`fixture_managed`) through
  the real `Letflow.Modules.Installs.install/3`, which stamps `managed_by` on seven of its eight
  pack types (`fxm_free` is the unmanaged control; `fxm_ledger` is managed AND append-only).

  Requests go straight into `Letflow.Routers.Entities` with a hand-assigned `auth_context` (the
  `Letflow.Plugs.Authorize` pass inside the router still runs and resolves `scoped_opts` from it),
  and `trace_id` is pinned to one constant, so a refusal body can be compared byte for byte with
  `Error.serialise/1` of the constant problem: `trace_id` is the only per-request member (design F6).

  `async: false`: tenant provisioning switches the sandbox to `:auto` and the install runs DDL.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn

  alias Letflow.Api.Error
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.EventStore.Event
  alias Letflow.Identity.User
  alias Letflow.Modules.FixtureManaged
  alias Letflow.Modules.Installs
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning.ColumnPromotion

  @entities_opts Letflow.Routers.Entities.init([])
  @trace "req496-managed-by-fixed-trace"

  # The six 0050 foundation names, all declared by fixture_managed.
  @six [
    "fxm_legal_entity",
    "fxm_site",
    "fxm_unit",
    "fxm_unit_membership",
    "fxm_item",
    "fxm_uom"
  ]

  @operator ["PROCESS_OPERATOR"]
  @admin ["TENANT_ADMIN"]
  @designer ["PROCESS_DESIGNER"]

  @bypass_headers [
    {"x-letflow-module", "fixture_managed"},
    {"x-letflow-owner", "fixture_managed"}
  ]
  @bypass_query "?module=fixture_managed&managed_by=fixture_managed"

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req496-ent")

    # GLOBAL rows with an FK onto the tenant, written by the pack install; registered after the
    # fixture's own on_exit so it runs first (LIFO), as install_activation_test.exs does.
    on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant.tenant_id))

      Repo.delete_all(
        from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant.tenant_id)
      )

      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant.tenant_id))
    end)

    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)
    user = insert_user!(tenant.schema_name)

    {:ok, _tenant_module} =
      Installs.install("fixture_managed", user.id,
        prefix: tenant.schema_name,
        rationale: "REQ-496 test install"
      )

    {:ok, tenant_id: tenant.tenant_id, schema: tenant.schema_name, actor_id: user.id}
  end

  # ── helpers ─────────────────────────────────────────────────────────────────────────────────

  defp insert_user!(schema) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "req496-user-#{Ecto.UUID.generate()}",
      display_name: "REQ-496 Managed-By Test User",
      email: "req496-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema)
  end

  # `body` nil sends no body; `%{"_json" => list}` is what Plug.Parsers hands a router for a
  # non-object JSON body.
  defp call_entities(ctx, roles, method, path, body, headers) do
    conn = Plug.Test.conn(method, path)

    conn =
      case body do
        nil ->
          conn

        body ->
          %{conn | body_params: body} |> put_req_header("content-type", "application/json")
      end

    headers
    |> Enum.reduce(conn, fn {name, value}, acc -> put_req_header(acc, name, value) end)
    |> assign(:auth_context, %{user_id: ctx.actor_id, tenant_id: ctx.tenant_id, roles: roles})
    |> assign(:trace_id, @trace)
    |> Letflow.Routers.Entities.call(@entities_opts)
  end

  # The constant refusal, serialised exactly as Response.send_problem/2 does with the pinned
  # trace id: the only member that may differ between two requests.
  defp managed_body, do: Error.serialise(%{Error.entity_type_managed() | trace_id: @trace})

  defp assert_managed!(conn, label) do
    assert conn.status == 403, "#{label}: #{conn.status} #{conn.resp_body}"
    assert conn.resp_body == managed_body(), "#{label}: #{conn.resp_body}"
  end

  defp record_count(schema, entity_type) do
    Repo.aggregate(from(l in Latest, where: l.entity_type == ^entity_type), :count,
      prefix: schema
    )
  end

  defp definition_count(schema, name) do
    Repo.aggregate(from(d in EntityDefinition, where: d.name == ^name), :count, prefix: schema)
  end

  defp table_count(schema, table) do
    %{rows: [[n]]} = Repo.query!(~s|SELECT count(*) FROM "#{schema}"."#{table}"|)
    n
  end

  defp owner_record!(ctx, entity_type) do
    {:ok, %{record: record}} =
      FixtureManaged.create_record(entity_type, %{"name" => "seeded by owner"}, ctx.schema)

    record
  end

  defp stored(ctx, entity_type, record_id) do
    {:ok, record} = Latest.get(record_id, entity_type, ctx.schema)
    Map.take(record, [:field_values, :deleted, :last_event_global_seq])
  end

  defp import_document(entity_type, count) do
    %{
      "record_export_schema_version" => "entities/record-export/v1",
      "entity_type" => entity_type,
      "exported_at" => "2026-10-14T00:00:00Z",
      "records" =>
        for i <- 1..count do
          %{
            "record_id" => Ecto.UUID.generate(),
            "field_values" => %{"name" => "imported #{i}"},
            "deleted" => false
          }
        end
    }
  end

  defp definition_body(name) do
    %{
      "name" => name,
      "display_name" => "Tenant attempt",
      "fields" => [%{"name" => "name", "type" => "string", "required" => true}]
    }
  end

  defp active_id(ctx, name) do
    {:ok, active} = Definitions.get_active_definition_by_name(name, ctx.schema)
    active.id
  end

  # ── AC1: generic record routes ──────────────────────────────────────────────────────────────

  describe "T-01..T-04 (AC1): every generic write route refuses each managed type with the uniform 403" do
    test "T-01: POST /records/:type as PROCESS_OPERATOR and TENANT_ADMIN -> 403, no record row",
         ctx do
      for type <- @six, roles <- [@operator, @admin] do
        conn =
          call_entities(
            ctx,
            roles,
            :post,
            "/records/#{type}",
            %{"field_values" => %{"name" => "tenant write"}},
            []
          )

        assert_managed!(conn, "POST #{type} as #{inspect(roles)}")
        assert record_count(ctx.schema, type) == 0
      end
    end

    test "T-02: PUT on an existing, an absent and a malformed id -> the same 403 bytes, record unchanged",
         ctx do
      for type <- @six, roles <- [@operator, @admin] do
        record = owner_record!(ctx, type)
        before = stored(ctx, type, record.record_id)
        body = %{"field_values" => %{"name" => "tenant overwrite"}}

        existing =
          call_entities(ctx, roles, :put, "/records/#{type}/#{record.record_id}", body, [])

        absent =
          call_entities(ctx, roles, :put, "/records/#{type}/#{Ecto.UUID.generate()}", body, [])

        malformed = call_entities(ctx, roles, :put, "/records/#{type}/not-a-uuid", body, [])

        assert_managed!(existing, "PUT existing #{type}")
        assert_managed!(absent, "PUT absent #{type}")
        assert_managed!(malformed, "PUT malformed #{type}")
        # AC1: byte-identical for an existing and an absent record id (INV-5).
        assert existing.resp_body == absent.resp_body
        assert stored(ctx, type, record.record_id) == before
      end
    end

    test "T-03: DELETE on an existing, an absent and a malformed id -> the same 403 bytes, record not deleted",
         ctx do
      for type <- @six, roles <- [@operator, @admin] do
        record = owner_record!(ctx, type)
        before = stored(ctx, type, record.record_id)

        existing =
          call_entities(ctx, roles, :delete, "/records/#{type}/#{record.record_id}", nil, [])

        absent =
          call_entities(ctx, roles, :delete, "/records/#{type}/#{Ecto.UUID.generate()}", nil, [])

        malformed = call_entities(ctx, roles, :delete, "/records/#{type}/not-a-uuid", nil, [])

        assert_managed!(existing, "DELETE existing #{type}")
        assert_managed!(absent, "DELETE absent #{type}")
        assert_managed!(malformed, "DELETE malformed #{type}")
        assert existing.resp_body == absent.resp_body
        assert stored(ctx, type, record.record_id) == before
        refute before.deleted
      end
    end

    test "T-04: POST /records/:type/import with a valid two-entry batch -> 403, zero records",
         ctx do
      for type <- @six do
        conn =
          call_entities(
            ctx,
            @admin,
            :post,
            "/records/#{type}/import",
            import_document(type, 2),
            []
          )

        assert_managed!(conn, "import #{type}")
        assert record_count(ctx.schema, type) == 0
      end
    end

    # GH #2659 (design section 1, T8): `upsert_by` does not open a managed type to the HTTP
    # import; the constant 403 is decided before the body (so before `upsert_by`) is read.
    test "T-04b: import with upsert_by external_ref on a managed type -> the same constant 403, zero records",
         ctx do
      for type <- @six do
        document =
          type
          |> import_document(2)
          |> Map.put("upsert_by", "external_ref")
          |> Map.update!("records", fn records ->
            records
            |> Enum.with_index()
            |> Enum.map(fn {entry, i} ->
              Map.put(entry, "external_ref", %{"system" => "sap", "id" => "#{type}-#{i}"})
            end)
          end)

        conn = call_entities(ctx, @admin, :post, "/records/#{type}/import", document, [])

        assert_managed!(conn, "upsert import #{type}")
        assert record_count(ctx.schema, type) == 0
      end
    end
  end

  describe "T-05 (AC1): neither request data nor request shape changes the answer" do
    test "a body key, a header or a query parameter naming the owner module does not bypass, on all four routes",
         ctx do
      for type <- @six do
        record = owner_record!(ctx, type)
        before = stored(ctx, type, record.record_id)

        claim = %{
          "field_values" => %{"name" => "claims to be the module"},
          "managed_by" => "fixture_managed",
          "module" => "fixture_managed",
          "owner" => "fixture_managed"
        }

        import_claim =
          import_document(type, 2)
          |> Map.put("managed_by", "fixture_managed")
          |> Map.put("module", "fixture_managed")

        conns = [
          create:
            call_entities(
              ctx,
              @admin,
              :post,
              "/records/#{type}" <> @bypass_query,
              claim,
              @bypass_headers
            ),
          update:
            call_entities(
              ctx,
              @admin,
              :put,
              "/records/#{type}/#{record.record_id}" <> @bypass_query,
              claim,
              @bypass_headers
            ),
          delete:
            call_entities(
              ctx,
              @admin,
              :delete,
              "/records/#{type}/#{record.record_id}" <> @bypass_query,
              nil,
              @bypass_headers
            ),
          import:
            call_entities(
              ctx,
              @admin,
              :post,
              "/records/#{type}/import" <> @bypass_query,
              import_claim,
              @bypass_headers
            )
        ]

        for {route, conn} <- conns,
            do: assert_managed!(conn, "#{route} #{type} with owner claims")

        # Only the owner's own record exists; it is untouched.
        assert record_count(ctx.schema, type) == 1
        assert stored(ctx, type, record.record_id) == before
      end
    end

    test "Revision 1 B2 order pin: malformed shapes on a managed type get the 403, not 400/413/422",
         ctx do
      type = "fxm_unit"
      record = owner_record!(ctx, type)
      id = record.record_id
      non_object = %{"_json" => ["not", "an", "object"]}

      cases = [
        {"POST non-object", :post, "/records/#{type}", non_object},
        {"POST missing field_values", :post, "/records/#{type}", %{}},
        {"POST field_values not an object", :post, "/records/#{type}",
         %{"field_values" => "nope"}},
        {"PUT non-object", :put, "/records/#{type}/#{id}", non_object},
        {"PUT missing field_values", :put, "/records/#{type}/#{id}", %{}},
        {"import non-object", :post, "/records/#{type}/import", non_object},
        {"import over the 200 cap", :post, "/records/#{type}/import", import_document(type, 201)},
        {"import records not an array", :post, "/records/#{type}/import",
         Map.put(import_document(type, 1), "records", "nope")},
        {"import unknown schema version", :post, "/records/#{type}/import",
         Map.put(import_document(type, 1), "record_export_schema_version", "v99")},
        {"import entity_type mismatch", :post, "/records/#{type}/import",
         Map.put(import_document(type, 1), "entity_type", "fxm_free")},
        {"DELETE invalid expected seq", :delete,
         "/records/#{type}/#{id}?expected_last_event_global_seq=abc", nil}
      ]

      for {label, method, path, body} <- cases do
        assert_managed!(call_entities(ctx, @admin, method, path, body, []), label)
      end

      assert record_count(ctx.schema, type) == 1
    end

    test "control: the same malformed shapes on the unmanaged fxm_free keep their existing answers",
         ctx do
      {:ok, %{record: record}} =
        FixtureManaged.create_record("fxm_free", %{"name" => "free"}, ctx.schema)

      non_object = %{"_json" => ["not", "an", "object"]}

      assert call_entities(ctx, @admin, :post, "/records/fxm_free", non_object, []).status == 400
      assert call_entities(ctx, @admin, :post, "/records/fxm_free", %{}, []).status == 422

      assert call_entities(
               ctx,
               @admin,
               :post,
               "/records/fxm_free/import",
               import_document("fxm_free", 201),
               []
             ).status == 413

      assert call_entities(
               ctx,
               @admin,
               :delete,
               "/records/fxm_free/#{record.record_id}?expected_last_event_global_seq=abc",
               nil,
               []
             ).status == 400

      assert call_entities(ctx, @admin, :put, "/records/fxm_free/not-a-uuid", %{}, []).status ==
               404
    end
  end

  describe "T-06/T-07 (AC1): the owner path succeeds; unmanaged types are unchanged" do
    test "T-06: the owning module's own Records calls create and update every managed type",
         ctx do
      for type <- @six ++ ["fxm_ledger"] do
        assert {:ok, %{record: record}} =
                 FixtureManaged.create_record(type, %{"name" => "owner create"}, ctx.schema)

        assert record.field_values == %{"name" => "owner create"}

        if type != "fxm_ledger" do
          assert {:ok, %{record: updated}} =
                   FixtureManaged.update_record(
                     type,
                     record.record_id,
                     %{"name" => "owner update"},
                     ctx.schema
                   )

          assert updated.field_values == %{"name" => "owner update"}
        end
      end
    end

    test "T-07: the four HTTP calls on fxm_free answer 201 / 200 / 200 / 200", ctx do
      create =
        call_entities(
          ctx,
          @operator,
          :post,
          "/records/fxm_free",
          %{"field_values" => %{"name" => "free"}},
          []
        )

      assert create.status == 201, create.resp_body
      record_id = Jason.decode!(create.resp_body)["record_id"]
      assert is_binary(record_id)

      update =
        call_entities(
          ctx,
          @operator,
          :put,
          "/records/fxm_free/#{record_id}",
          %{"field_values" => %{"name" => "free 2"}},
          []
        )

      assert update.status == 200, update.resp_body

      delete = call_entities(ctx, @operator, :delete, "/records/fxm_free/#{record_id}", nil, [])
      assert delete.status == 200, delete.resp_body

      import =
        call_entities(
          ctx,
          @admin,
          :post,
          "/records/fxm_free/import",
          import_document("fxm_free", 2),
          []
        )

      assert import.status == 200, import.resp_body
      assert record_count(ctx.schema, "fxm_free") == 3
    end
  end

  describe "T-08 (AC1, AC2): route coverage" do
    test "every record/definition write route of the Entities router is in the guarded set" do
      guarded =
        MapSet.new([
          {"POST", "/records/:entity_type"},
          {"PUT", "/records/:entity_type/:record_id"},
          {"DELETE", "/records/:entity_type/:record_id"},
          {"POST", "/records/:entity_type/import"},
          {"POST", "/definitions"},
          {"POST", "/definitions/:name/activate"}
        ])

      write_routes =
        for {method, path, _key} <- Letflow.Routers.Entities.__authz_routes__(),
            method in ["POST", "PUT", "PATCH", "DELETE"],
            record_write_path?(path) or String.starts_with?(path, "/definitions"),
            into: MapSet.new(),
            do: {method, path}

      # A new write route under /records/:entity_type or /definitions fails here until it is
      # guarded (design §3.2 inheritance rule) and added to this set.
      assert write_routes == guarded
    end
  end

  defp record_write_path?(path) do
    String.starts_with?(path, "/records/:entity_type") and
      not String.contains?(path, "/attachments") and not String.ends_with?(path, "/export")
  end

  # ── AC2: definitions API ────────────────────────────────────────────────────────────────────

  describe "T-09..T-12 (AC2): the entity-definition routes refuse a managed name" do
    test "T-09: POST /definitions with a managed name -> 403 whatever the body holds; nothing written",
         ctx do
      for name <- @six do
        active_before = active_id(ctx, name)
        rows_before = definition_count(ctx.schema, name)

        bodies = [
          valid: definition_body(name),
          missing_fields: %{"name" => name},
          invalid_field_type: %{
            "name" => name,
            "display_name" => "Bad",
            "fields" => [%{"name" => "x", "type" => "not-a-type"}]
          },
          managed_by_key: Map.put(definition_body(name), "managed_by", "fixture_managed")
        ]

        for {label, body} <- bodies do
          conn = call_entities(ctx, @designer, :post, "/definitions", body, [])
          assert_managed!(conn, "create #{name} (#{label})")
        end

        assert active_id(ctx, name) == active_before
        assert definition_count(ctx.schema, name) == rows_before
      end
    end

    test "T-09 control: an invalid body with an unmanaged or a non-string name keeps its 422",
         ctx do
      unmanaged =
        call_entities(ctx, @designer, :post, "/definitions", %{"name" => "fxm_new"}, [])

      assert unmanaged.status == 422, unmanaged.resp_body
      assert Map.has_key?(Jason.decode!(unmanaged.resp_body), "errors")

      non_binary =
        call_entities(ctx, @designer, :post, "/definitions", %{"name" => 123}, [])

      assert non_binary.status == 422, non_binary.resp_body
      assert definition_count(ctx.schema, "fxm_new") == 0
    end

    test "T-10: POST /definitions/:name/activate for each managed name -> 403, activation unchanged",
         ctx do
      activations = table_count(ctx.schema, "artifact_activations")
      history = table_count(ctx.schema, "artifact_activation_history")

      for name <- @six do
        before = active_id(ctx, name)

        conn =
          call_entities(
            ctx,
            @designer,
            :post,
            "/definitions/#{name}/activate",
            %{"rationale" => "tenant tries to activate"},
            []
          )

        assert_managed!(conn, "activate #{name}")
        assert active_id(ctx, name) == before
      end

      assert table_count(ctx.schema, "artifact_activations") == activations
      assert table_count(ctx.schema, "artifact_activation_history") == history
    end

    test "T-11: a NEW shape named like a managed type (fxm_uom) -> 403, no row", ctx do
      before = definition_count(ctx.schema, "fxm_uom")

      body = %{
        "name" => "fxm_uom",
        "display_name" => "Tenant UoM",
        "fields" => [
          %{"name" => "code", "type" => "string", "required" => true},
          %{"name" => "label", "type" => "string"}
        ]
      }

      assert_managed!(call_entities(ctx, @designer, :post, "/definitions", body, []), "new shape")
      assert definition_count(ctx.schema, "fxm_uom") == before
    end

    test "T-12: a body carrying managed_by is refused for a new unmanaged name, a managed name and a null value",
         ctx do
      cases = [
        {"fxm_brand_new", "fixture_managed"},
        {"fxm_unit", "fixture_managed"},
        {"fxm_null_claim", nil}
      ]

      for {name, value} <- cases do
        before = definition_count(ctx.schema, name)
        body = Map.put(definition_body(name), "managed_by", value)

        assert_managed!(
          call_entities(ctx, @designer, :post, "/definitions", body, []),
          "managed_by #{inspect(value)} on #{name}"
        )

        assert definition_count(ctx.schema, name) == before
      end

      # Control: the same body WITHOUT the key creates the unmanaged type, unstamped.
      created =
        call_entities(ctx, @designer, :post, "/definitions", definition_body("fxm_brand_new"), [])

      assert created.status == 201, created.resp_body

      assert [nil] =
               Repo.all(
                 from(d in EntityDefinition,
                   where: d.name == "fxm_brand_new",
                   select: d.managed_by
                 ),
                 prefix: ctx.schema
               )
    end
  end

  # ── AC4: ordering with append_only ──────────────────────────────────────────────────────────

  describe "T-20 (AC4): a managed AND append-only type" do
    test "a non-owner gets the uniform 403 that reveals nothing about append-only; the owner gets entity_append_only",
         ctx do
      record = owner_record!(ctx, "fxm_ledger")
      before = stored(ctx, "fxm_ledger", record.record_id)
      body = %{"field_values" => %{"name" => "rewrite history"}}

      for roles <- [@operator, @admin] do
        put = call_entities(ctx, roles, :put, "/records/fxm_ledger/#{record.record_id}", body, [])

        delete =
          call_entities(ctx, roles, :delete, "/records/fxm_ledger/#{record.record_id}", nil, [])

        for conn <- [put, delete] do
          assert_managed!(conn, "fxm_ledger as #{inspect(roles)}")
          refute conn.resp_body =~ "append"
          refute conn.resp_body =~ "entity_append_only"
        end
      end

      # Byte-identical to a plain managed type's refusal (T-02's body).
      other = owner_record!(ctx, "fxm_unit")
      plain = call_entities(ctx, @admin, :put, "/records/fxm_unit/#{other.record_id}", body, [])

      ledger =
        call_entities(ctx, @admin, :put, "/records/fxm_ledger/#{record.record_id}", body, [])

      assert plain.resp_body == ledger.resp_body

      assert stored(ctx, "fxm_ledger", record.record_id) == before

      # The owner reaches Records and gets the append-only refusal, which the router maps to
      # the 422 Error.entity_append_only/0 (design OQ-10: no owner HTTP route exists).
      assert {:error, {:entity_append_only, "fxm_ledger"}} =
               FixtureManaged.update_record(
                 "fxm_ledger",
                 record.record_id,
                 %{"name" => "owner rewrite"},
                 ctx.schema
               )

      assert {:error, {:entity_append_only, "fxm_ledger"}} =
               FixtureManaged.delete_record("fxm_ledger", record.record_id, ctx.schema)

      assert Error.entity_append_only().status == 422
      assert stored(ctx, "fxm_ledger", record.record_id) == before
    end
  end

  # ── GH #2583 T-15/T-16: the race-only router clauses ────────────────────────────────────────
  #
  # Design `lib/letflow/design/gh2583-records-managed-type-guard.md` section 5, T-15/T-16 (spec
  # `test/specs/GH-2583.md`). The race (the guard's `owner_of/2` read and the row `Records`
  # resolves disagree) is simulated deterministically: with the no-update trigger disabled inside
  # ONE transaction, fxm_free's definition row is stamped AND renamed, so the guard (keyed by
  # `entity_definitions.name`) sees no stamped `fxm_free` row while `Records` resolves `fxm_free`
  # through `Activation.resolve/3` (keyed by artifact name) to the stamped row. Teardown: the
  # tenant fixture's `DROP SCHEMA ... CASCADE` fires no row-level trigger, so the stamped row does
  # not block it.

  @guard_triggers [
    "entity_definitions_managed_by_no_delete",
    "entity_definitions_managed_by_no_update"
  ]

  defp race_stamp_fxm_free!(schema) do
    table = ~s|"#{schema}".entity_definitions|

    {:ok, updated} =
      Repo.transaction(fn ->
        Repo.query!(
          "ALTER TABLE #{table} DISABLE TRIGGER entity_definitions_managed_by_no_update"
        )

        %{num_rows: n} =
          Repo.query!(
            "UPDATE #{table} SET managed_by = 'fixture_managed', name = 'fxm_free_raced' " <>
              "WHERE name = 'fxm_free'"
          )

        Repo.query!("ALTER TABLE #{table} ENABLE TRIGGER entity_definitions_managed_by_no_update")
        n
      end)

    assert updated >= 1

    # SEC A4: both guard triggers are enabled ('O' = origin/local) after the toggle.
    %{rows: rows} =
      Repo.query!(
        "SELECT tgname::text, tgenabled::text FROM pg_trigger " <>
          "WHERE tgrelid = $1::text::regclass AND tgname::text = ANY($2::text[]) " <>
          "ORDER BY tgname",
        [table, @guard_triggers]
      )

    assert rows == Enum.map(@guard_triggers, &[&1, "O"])

    # The race precondition: the guard now sees fxm_free as unmanaged ...
    assert ManagedTypes.check_tenant_write("fxm_free", schema) == :ok
    # ... while the definition Records resolves for fxm_free carries the stamp.
    {:ok, resolved} = Definitions.get_active_definition_by_name("fxm_free", schema)
    assert resolved.managed_by == "fixture_managed"
  end

  defp record_event_count(schema) do
    Repo.one!(
      from(e in Event, where: like(e.event_type, "ENTITY_RECORD_%"), select: count(e.event_id)),
      prefix: schema
    )
  end

  describe "GH #2583 T-15/T-16 (AC2): Records' refusal in a guard race renders the guard's answer" do
    test "T-15: POST/PUT/DELETE on a raced fxm_free -> the guard's constant 403 bytes, no write",
         ctx do
      {:ok, %{record: record}} =
        FixtureManaged.create_record("fxm_free", %{"name" => "before race"}, ctx.schema)

      race_stamp_fxm_free!(ctx.schema)
      before = stored(ctx, "fxm_free", record.record_id)
      events = record_event_count(ctx.schema)
      body = %{"field_values" => %{"name" => "tenant write"}}

      conns = [
        post: call_entities(ctx, @admin, :post, "/records/fxm_free", body, []),
        put: call_entities(ctx, @admin, :put, "/records/fxm_free/#{record.record_id}", body, []),
        delete:
          call_entities(ctx, @admin, :delete, "/records/fxm_free/#{record.record_id}", nil, [])
      ]

      for {route, conn} <- conns, do: assert_managed!(conn, "raced #{route} fxm_free")

      # Byte-identical to the guard's own refusal of a plainly managed type (REQ-496 T-01 body).
      guarded = call_entities(ctx, @admin, :post, "/records/fxm_unit", body, [])
      assert_managed!(guarded, "guarded fxm_unit")
      for {_route, conn} <- conns, do: assert(conn.resp_body == guarded.resp_body)

      assert stored(ctx, "fxm_free", record.record_id) == before
      assert record_count(ctx.schema, "fxm_free") == 1
      assert record_event_count(ctx.schema) == events
    end

    test "T-16: import on a raced fxm_free -> 200, every entry entity_type_managed, no record, no internal-error log",
         ctx do
      race_stamp_fxm_free!(ctx.schema)
      events = record_event_count(ctx.schema)

      {conn, log} =
        ExUnit.CaptureLog.with_log(fn ->
          call_entities(
            ctx,
            @admin,
            :post,
            "/records/fxm_free/import",
            import_document("fxm_free", 2),
            []
          )
        end)

      assert conn.status == 200, conn.resp_body
      results = Jason.decode!(conn.resp_body)["results"]
      assert length(results) == 2

      for result <- results do
        assert %{"status" => "error", "reason" => %{"type" => "entity_type_managed"}} = result
        assert result["reason"] == %{"type" => "entity_type_managed"}
      end

      refute log =~ "entity record import entry failed"
      assert record_count(ctx.schema, "fxm_free") == 0
      assert record_event_count(ctx.schema) == events
    end
  end
end
