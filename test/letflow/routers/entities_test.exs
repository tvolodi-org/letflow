defmodule Letflow.Routers.EntitiesTest do
  @moduledoc """
  Tests for REQ-310's nine `Letflow.Routers.Entities` routes, written by
  ELIXIR-DEV at WF-02 Step 2a to exercise the implementation against a real
  Postgres tenant schema and the REAL `Letflow.Plugs.ApiPipeline` stack. Not
  full 16-AC coverage -- TEST-DESIGNER writes that later in this pipeline
  (Step 2d+). See `lib/letflow/design/req308-entity-http-surface.md` for the
  design these tests spot-check.

  ## Every request goes through the full pipeline, not the router in isolation

  Dispatched via `Letflow.Router.call/2` with a real API-token bearer
  credential (`Authorization: Bearer lf_tok_...` + `X-Tenant-Slug`), so
  `Letflow.Plugs.AuthPipeline` -> `Letflow.Plugs.TenantStatus` ->
  `Letflow.Plugs.Authorize` -> the router all genuinely run and
  `conn.assigns.scoped_opts` is resolved by the production code path from the
  caller's own credential -- never preset by the test. This is
  `test/letflow/api_token_auth_pipeline_test.exs`'s established convention,
  and it is what makes the INV-1 and 403 assertions below mean anything:
  a test that hand-assigned `:scoped_opts` and called
  `Letflow.Routers.Entities.call/2` directly would prove neither.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database.
  `async: false` because `TenantFixture.provisioned_tenant!/1` switches the
  sandbox to global `:auto` mode.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  # REQ-311: only for the ColumnPromotion cleanup in promote_and_create_table!/5
  # below. No test in this file issues a query of its own -- every read and
  # write goes through a context module or through the HTTP routes themselves.
  import Ecto.Query, only: [from: 2]

  alias Letflow.Api.Error
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Query.Cursor
  alias Letflow.Entities.Query.FieldGrants
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  # ── Full-pipeline dispatch ─────────────────────────────────────────────

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp request(method, path, ctx, body \\ nil, opts \\ []) do
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
    |> maybe_pin_trace_id(Keyword.get(opts, :trace_id))
    |> dispatch()
  end

  # `Letflow.Api.Context.assign_trace_id/1` echoes a caller-supplied
  # `x-trace-id` header verbatim, and `Letflow.Api.Error`'s `trace_id` member
  # is the one field in a problem document that is per-REQUEST correlation
  # data rather than per-RESOURCE information. The INV-5 byte-identity tests
  # below pin it to one fixed value across the pair of requests they compare,
  # so `resp_body == resp_body` is a genuine byte-for-byte comparison of the
  # whole document -- rather than dropping or normalising a field, which
  # would be exactly the loophole through which a real INV-5 leak could hide.
  defp maybe_pin_trace_id(conn, nil), do: conn
  defp maybe_pin_trace_id(conn, trace_id), do: put_req_header(conn, "x-trace-id", trace_id)

  # ── Fixtures ───────────────────────────────────────────────────────────

  defp insert_user!(tenant) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "req310-user-#{Ecto.UUID.generate()}",
      display_name: "REQ-310 Entities Router Test User",
      email: "req310-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  # A provisioned tenant plus a real API token carrying `roles`. Every role
  # string below is one of Letflow.Api.Authorization's own five closed roles,
  # so the 403/non-403 assertions are driven by that module's real matrix.
  defp tenant_ctx(slug_prefix, roles \\ ["TENANT_ADMIN"]) do
    tenant =
      TenantFixture.provisioned_tenant!(
        slug_prefix: slug_prefix,
        display_name: "REQ-310 Entities Router Test Tenant"
      )

    # REQ-447 PR 2: a PLATFORM_ADMIN token can only be minted in the pinned platform tenant
    if "PLATFORM_ADMIN" in roles,
      do: Letflow.Support.PlatformTenantFixture.pin!(tenant.tenant_id)

    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)
    user = insert_user!(tenant)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: tenant.schema_name)

    %{
      # REQ-311 added `tenant_id` (needed by
      # TenantProvisioning.register_column_promotion/4, which the join tests
      # use to create real per-entity-type tables) and `tenant` (needed by
      # the INV-5 cross-tenant test, which mints a SECOND credential against
      # an existing tenant).
      tenant_id: tenant.tenant_id,
      schema_name: tenant.schema_name,
      slug: tenant.tenant.slug,
      plaintext: plaintext,
      user_id: user.id
    }
  end

  # A SECOND credential for a tenant that already exists, belonging to a
  # DIFFERENT user in the same schema. REQ-311's INV-1 two-user test needs
  # two callers whose `user_entity_grants` rows differ while every other
  # input -- the request body included -- is byte-identical.
  defp second_user_ctx(ctx, roles \\ ["TENANT_ADMIN"]) do
    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "req311-user2-#{Ecto.UUID.generate()}",
        display_name: "REQ-311 Second User",
        email: "req311-2-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: ctx.schema_name)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: ctx.schema_name)

    %{ctx | plaintext: plaintext, user_id: user.id}
  end

  defp definition_body(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "widget",
        "display_name" => "Widget",
        "fields" => [
          %{"name" => "title", "type" => "string", "required" => true},
          %{"name" => "quantity", "type" => "integer"}
        ]
      },
      overrides
    )
  end

  # Creates + activates a definition through the CONTEXT MODULE (not the
  # routes), so a route test asserting on a pre-existing definition is not
  # implicitly asserting on the create/activate routes as well.
  defp seed_active_definition!(ctx, name \\ "widget") do
    document = %{
      name: name,
      display_name: String.capitalize(name),
      fields: [
        %{name: "title", type: :string, required: true},
        %{name: "quantity", type: :integer}
      ]
    }

    {:ok, definition} =
      Definitions.create_definition(
        %{definition: document, created_by: ctx.user_id},
        ctx.schema_name
      )

    {:ok, activated} =
      Definitions.activate_definition(name, ctx.user_id, "test go-live", ctx.schema_name)

    %{created: definition, activated: activated}
  end

  # Creates an INACTIVE definition through the context module, without
  # activating it -- the precondition for the activate-route tests, which
  # must reach the delegate's activation path rather than short-circuit on
  # :not_found.
  defp seed_definition_only!(ctx, name \\ "widget") do
    {:ok, definition} =
      Definitions.create_definition(
        %{
          definition: %{
            name: name,
            display_name: String.capitalize(name),
            fields: [
              %{name: "title", type: :string, required: true},
              %{name: "quantity", type: :integer}
            ]
          },
          created_by: ctx.user_id
        },
        ctx.schema_name
      )

    definition
  end

  defp seed_record!(ctx, entity_type \\ "widget", field_values \\ %{"title" => "seeded"}) do
    {:ok, %{record: record}} =
      Records.create_record(
        %{
          entity_type: entity_type,
          field_values: field_values,
          actor_id: ctx.user_id,
          idempotency_key: Ecto.UUID.generate()
        },
        ctx.schema_name
      )

    record
  end

  defp body_of(conn), do: Jason.decode!(conn.resp_body)

  # Guards the premise of the blocker-2 parity test below: the "typo" string
  # it sends really must NOT already be an atom in this VM, or the test
  # would silently stop testing the thing it exists to test. Asserted at
  # runtime rather than assumed, because whether an atom exists is exactly
  # the unrelated global state the fix removes from the error contract.
  defp refute_existing_atom!(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> :ok
  else
    atom ->
      flunk("""
      test premise broken: #{inspect(string)} IS already an atom (#{inspect(atom)}) in this VM, \
      so it no longer exercises the to_existing_atom-raises path. Pick another string.\
      """)
  end

  # A problem document minus the one member that is legitimately per-REQUEST
  # rather than per-error (`trace_id`, see maybe_pin_trace_id/2 above). Two
  # requests differing only in a field's spelling must otherwise produce
  # byte-identical documents.
  defp normalise_problem(conn), do: conn |> body_of() |> Map.delete("trace_id")

  # ═══════════════════════════════════════════════════════════════════════
  # AC1 -- __authz_routes__/0 returns exactly the seventeen designed routes.
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC1 -- the declared route table matches design §1" do
    # REQ-311 raised this from nine to TEN (POST /query); REQ-315 raised it
    # from TEN to ELEVEN (POST /query/aggregate); REQ-317 raised it from
    # ELEVEN to FIFTEEN (the four record-attachment routes); REQ-319 and
    # REQ-320 -- the export/import pair, landed concurrently -- together
    # raise it from FIFTEEN to SEVENTEEN (POST /records/:entity_type/export
    # and POST /records/:entity_type/import); ISS-0935 raises it from
    # SEVENTEEN to EIGHTEEN (POST /restrictions/import). The count is
    # asserted explicitly so appending a nineteenth route without updating
    # design §1's table fails here rather than silently.
    test "__authz_routes__/0 returns exactly the nineteen designed routes, with their designed policy keys" do
      expected = [
        {"POST", "/definitions/:name/activate", :EntitiesDefinitionsWrite},
        {"POST", "/definitions", :EntitiesDefinitionsWrite},
        {"GET", "/definitions/active/:name", :EntitiesDefinitionsRead},
        {"GET", "/definitions/by-name/:name", :EntitiesDefinitionsRead},
        {"GET", "/definitions/:id", :EntitiesDefinitionsRead},
        {"GET", "/definitions", :EntitiesDefinitionsRead},
        {"POST", "/records/:entity_type", :EntitiesRecordsWrite},
        {"PUT", "/records/:entity_type/:record_id", :EntitiesRecordsWrite},
        {"DELETE", "/records/:entity_type/:record_id", :EntitiesRecordsWrite},
        {"POST", "/records/:entity_type/import", :EntitiesRecordsImport},
        {"POST", "/restrictions/import", :EntitiesRestrictionsManage},
        {"POST", "/query", :EntitiesQuery},
        {"POST", "/query/aggregate", :EntitiesAggregate},
        {"POST", "/records/:entity_type/:record_id/attachments", :EntitiesAttachmentsManage},
        {"GET", "/records/:entity_type/:record_id/attachments", :EntitiesAttachmentsRead},
        {"GET", "/records/:entity_type/:record_id/attachments/:attachment_id",
         :EntitiesAttachmentsRead},
        {"DELETE", "/records/:entity_type/:record_id/attachments/:attachment_id",
         :EntitiesAttachmentsManage},
        {"POST", "/records/:entity_type/export", :EntitiesRecordsExport},
        {"GET", "/records/:entity_type/:record_id/history", :EntitiesQuery}
      ]

      actual = Letflow.Routers.Entities.__authz_routes__()

      assert length(actual) == 19
      assert Enum.sort(actual) == Enum.sort(expected)
      assert {"POST", "/records/:entity_type/import", :EntitiesRecordsImport} in actual
      assert {"POST", "/query", :EntitiesQuery} in actual
      assert {"POST", "/query/aggregate", :EntitiesAggregate} in actual

      assert {"POST", "/records/:entity_type/:record_id/attachments", :EntitiesAttachmentsManage} in actual

      assert {"DELETE", "/records/:entity_type/:record_id/attachments/:attachment_id",
              :EntitiesAttachmentsManage} in actual

      assert {"POST", "/records/:entity_type/export", :EntitiesRecordsExport} in actual
    end

    test "⛔ no GET route exists under /records for the record itself -- record reads are POST /entities/query only" do
      # REQ-317 legitimately added two GET routes under /records/..., but
      # both are the record's ATTACHMENT sub-resource
      # (/records/:entity_type/:record_id/attachments...), not the record
      # itself -- excluded here so this assertion still proves what it always
      # proved: no GET reads a record's own field_values.
      # REQ-516 S2 adds the record HISTORY GET, excluded by its exact path: its
      # field_values pass through FieldPolicy.redact_event_payload_with_sets/3
      # (proven by H1 in req516_record_history_routes_test.exs), so it is not a
      # redaction bypass. Any other GET under /records still fails here.
      record_gets =
        Letflow.Routers.Entities.__authz_routes__()
        |> Enum.filter(fn {method, path, _key} ->
          method == "GET" and String.starts_with?(path, "/records") and
            not String.contains?(path, "attachments") and
            path != "/records/:entity_type/:record_id/history"
        end)

      assert record_gets == []
    end

    test "route ORDER in the source places /active/:name and /by-name/:name above /definitions/:id" do
      # @authz_routes accumulates in reverse declaration order, so the
      # declared list read back gives declaration order when reversed. This
      # is a readability check only -- the LOAD-BEARING proof that ordering
      # actually works is by request, in the AC2 describe block below.
      declaration_order =
        Letflow.Routers.Entities.__authz_routes__()
        |> Enum.reverse()
        |> Enum.map(fn {method, path, _key} -> {method, path} end)

      active_index =
        Enum.find_index(declaration_order, &(&1 == {"GET", "/definitions/active/:name"}))

      by_name_index =
        Enum.find_index(declaration_order, &(&1 == {"GET", "/definitions/by-name/:name"}))

      id_index = Enum.find_index(declaration_order, &(&1 == {"GET", "/definitions/:id"}))

      assert active_index < id_index
      assert by_name_index < id_index
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC2 -- ⛔ ROUTE ORDER PROVEN BY REQUEST, not by reading source.
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC2 -- /definitions/active/:name and /definitions/by-name/:name are not swallowed by /definitions/:id" do
    test "GET /definitions/active/<name> runs the active-by-name handler, not the :id handler" do
      ctx = tenant_ctx("req310-order-active")
      %{activated: activated} = seed_active_definition!(ctx)

      conn = request(:get, "/api/v1/entities/definitions/active/widget", ctx)

      # The :id clause could not possibly have produced this: it would have
      # cast the literal path segment "active" as a UUID (failing) and
      # returned 404, never a 200 carrying the definition activated under
      # the name "widget".
      assert conn.status == 200
      body = body_of(conn)
      assert body["id"] == activated.id
      assert body["name"] == "widget"
      assert body["status"] == "active"
    end

    test "GET /definitions/by-name/<name> runs the by-name handler, not the :id handler" do
      ctx = tenant_ctx("req310-order-byname")
      %{created: created} = seed_active_definition!(ctx)

      conn = request(:get, "/api/v1/entities/definitions/by-name/widget", ctx)

      assert conn.status == 200
      body = body_of(conn)
      assert body["id"] == created.id
      assert body["name"] == "widget"
    end

    test "THE NEGATIVE, DIRECTLY: no id lookup against the literal string 'active' occurred" do
      ctx = tenant_ctx("req310-order-negative")
      seed_active_definition!(ctx)

      # If the bare /definitions/:id clause had swallowed this path, `id`
      # would have been bound to the literal "active" -- which is not a
      # UUID, so get_definition would have 404'd. Requesting the SAME two
      # paths in one test and comparing their statuses isolates the
      # difference to the routing, not to the fixture:
      by_id_of_literal =
        request(:get, "/api/v1/entities/definitions/#{URI.encode("active")}x", ctx)

      active_by_name = request(:get, "/api/v1/entities/definitions/active/widget", ctx)

      # "activex" IS handled by the :id clause (single segment) -> 404.
      assert by_id_of_literal.status == 404
      # "/active/widget" is NOT -> 200, the observably different status the
      # :id clause could never produce for a non-UUID segment.
      assert active_by_name.status == 200
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC3 -- every one of the nine routes returns its designed success status
  # through the full ApiPipeline stack.
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC3 -- designed success status on every route, full pipeline" do
    test "all nine routes, in sequence, against one real tenant" do
      ctx = tenant_ctx("req310-success")

      # 1. POST /entities/definitions -> 201
      create_conn = request(:post, "/api/v1/entities/definitions", ctx, definition_body())
      assert create_conn.status == 201
      created = body_of(create_conn)
      assert created["name"] == "widget"
      assert created["status"] == "inactive"

      # 2. POST /entities/definitions/:name/activate -> 200
      activate_conn =
        request(:post, "/api/v1/entities/definitions/widget/activate", ctx, %{
          "rationale" => "go-live"
        })

      assert activate_conn.status == 200
      assert body_of(activate_conn)["status"] == "active"

      # 3. GET /entities/definitions/active/:name -> 200
      active_conn = request(:get, "/api/v1/entities/definitions/active/widget", ctx)
      assert active_conn.status == 200

      # 4. GET /entities/definitions/by-name/:name -> 200
      by_name_conn = request(:get, "/api/v1/entities/definitions/by-name/widget", ctx)
      assert by_name_conn.status == 200

      # 5. GET /entities/definitions/:id -> 200
      by_id_conn = request(:get, "/api/v1/entities/definitions/#{created["id"]}", ctx)
      assert by_id_conn.status == 200
      assert body_of(by_id_conn)["id"] == created["id"]

      # 6. GET /entities/definitions -> 200, {"items": [...], "next_cursor": ...}
      list_conn = request(:get, "/api/v1/entities/definitions", ctx)
      assert list_conn.status == 200
      list_body = body_of(list_conn)
      assert is_list(list_body["items"])
      assert Map.has_key?(list_body, "next_cursor")
      refute Map.has_key?(list_body, "count")
      assert Enum.any?(list_body["items"], &(&1["id"] == created["id"]))

      # 7. POST /entities/records/:entity_type -> 201
      create_record_conn =
        request(:post, "/api/v1/entities/records/widget", ctx, %{
          "field_values" => %{"title" => "first", "quantity" => 3}
        })

      assert create_record_conn.status == 201
      record = body_of(create_record_conn)
      assert record["entity_type"] == "widget"
      assert record["field_values"] == %{"title" => "first", "quantity" => 3}
      refute record["deleted"]

      # 8. PUT /entities/records/:entity_type/:record_id -> 200
      update_conn =
        request(:put, "/api/v1/entities/records/widget/#{record["record_id"]}", ctx, %{
          "field_values" => %{"title" => "second", "quantity" => 9}
        })

      assert update_conn.status == 200
      assert body_of(update_conn)["field_values"] == %{"title" => "second", "quantity" => 9}

      # 9. DELETE /entities/records/:entity_type/:record_id -> 200
      delete_conn =
        request(:delete, "/api/v1/entities/records/widget/#{record["record_id"]}", ctx)

      assert delete_conn.status == 200
      assert body_of(delete_conn)["deleted"] == true
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC4 -- permission enforcement, driven by Authorization's real matrix.
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC4 -- 403 without the permission, non-403 with it" do
    # AGENT_RUNNER holds NONE of the four Entities* permissions (its own
    # role_allows?/2 catch-all is `false`), so it is the 403 case for all
    # three distinct permission atoms these nine routes use.
    test ":EntitiesDefinitionsRead -- AGENT_RUNNER 403, TASK_WORKER non-403" do
      denied_ctx = tenant_ctx("req310-perm-read-deny", ["AGENT_RUNNER"])
      allowed_ctx = tenant_ctx("req310-perm-read-allow", ["TASK_WORKER"])

      assert request(:get, "/api/v1/entities/definitions", denied_ctx).status == 403
      assert request(:get, "/api/v1/entities/definitions", allowed_ctx).status != 403
    end

    test ":EntitiesDefinitionsWrite -- PROCESS_OPERATOR 403 (deliberately withheld), PROCESS_DESIGNER non-403" do
      # Per design §3's matrix, PROCESS_OPERATOR deliberately does NOT hold
      # EntitiesDefinitionsWrite -- schema authoring tracks PROCESS_DESIGNER.
      denied_ctx = tenant_ctx("req310-perm-defwrite-deny", ["PROCESS_OPERATOR"])
      allowed_ctx = tenant_ctx("req310-perm-defwrite-allow", ["PROCESS_DESIGNER"])

      denied = request(:post, "/api/v1/entities/definitions", denied_ctx, definition_body())
      assert denied.status == 403

      allowed = request(:post, "/api/v1/entities/definitions", allowed_ctx, definition_body())
      assert allowed.status != 403
      assert allowed.status == 201
    end

    test ":EntitiesRecordsWrite -- PROCESS_DESIGNER 403 (deliberately withheld), PROCESS_OPERATOR non-403" do
      # The mirror image: record authoring tracks PROCESS_OPERATOR, not
      # PROCESS_DESIGNER.
      denied_ctx = tenant_ctx("req310-perm-recwrite-deny", ["PROCESS_DESIGNER"])
      allowed_ctx = tenant_ctx("req310-perm-recwrite-allow", ["PROCESS_OPERATOR"])
      seed_active_definition!(allowed_ctx)

      denied =
        request(:post, "/api/v1/entities/records/widget", denied_ctx, %{
          "field_values" => %{"title" => "x"}
        })

      assert denied.status == 403

      allowed =
        request(:post, "/api/v1/entities/records/widget", allowed_ctx, %{
          "field_values" => %{"title" => "x"}
        })

      assert allowed.status != 403
      assert allowed.status == 201
    end

    test "every one of the nine routes 403s for a caller holding none of the permissions" do
      ctx = tenant_ctx("req310-perm-all-nine", ["AGENT_RUNNER"])
      record_id = Ecto.UUID.generate()
      definition_id = Ecto.UUID.generate()

      requests = [
        {:post, "/api/v1/entities/definitions", definition_body()},
        {:post, "/api/v1/entities/definitions/widget/activate", %{}},
        {:get, "/api/v1/entities/definitions/active/widget", nil},
        {:get, "/api/v1/entities/definitions/by-name/widget", nil},
        {:get, "/api/v1/entities/definitions/#{definition_id}", nil},
        {:get, "/api/v1/entities/definitions", nil},
        {:post, "/api/v1/entities/records/widget", %{"field_values" => %{}}},
        {:put, "/api/v1/entities/records/widget/#{record_id}", %{"field_values" => %{}}},
        {:delete, "/api/v1/entities/records/widget/#{record_id}", nil}
      ]

      for {method, path, body} <- requests do
        conn = request(method, path, ctx, body)

        assert conn.status == 403,
               "#{method |> to_string() |> String.upcase()} #{path} returned #{conn.status}, expected 403"
      end
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC5 -- INV-5: cross-tenant and nonexistent are BYTE-IDENTICAL.
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC5 -- INV-5 byte-identity of cross-tenant and nonexistent" do
    test "GET /definitions/:id -- another tenant's real id and an id that exists nowhere are the same bytes" do
      ctx_a = tenant_ctx("req310-inv5-defs-a")
      ctx_b = tenant_ctx("req310-inv5-defs-b")

      # A real, existing definition id -- in tenant B's schema.
      %{created: b_definition} = seed_active_definition!(ctx_b)
      nowhere_id = Ecto.UUID.generate()
      pinned = [trace_id: "req310-inv5-defs-fixed-trace"]

      cross_tenant =
        request(:get, "/api/v1/entities/definitions/#{b_definition.id}", ctx_a, nil, pinned)

      nonexistent =
        request(:get, "/api/v1/entities/definitions/#{nowhere_id}", ctx_a, nil, pinned)

      # ONE assertion comparing both status AND body, not two separate
      # "assert 404" assertions: a difference in any response byte would
      # be an "exists but forbidden" oracle.
      assert {cross_tenant.status, cross_tenant.resp_body} ==
               {nonexistent.status, nonexistent.resp_body}

      assert cross_tenant.status == 404
    end

    test "PUT /records/:entity_type/:record_id -- another tenant's real record id and one that exists nowhere are the same bytes" do
      ctx_a = tenant_ctx("req310-inv5-put-a")
      ctx_b = tenant_ctx("req310-inv5-put-b")

      seed_active_definition!(ctx_a)
      seed_active_definition!(ctx_b)
      b_record = seed_record!(ctx_b)
      nowhere_id = Ecto.UUID.generate()

      body = %{"field_values" => %{"title" => "attempted"}}
      pinned = [trace_id: "req310-inv5-put-fixed-trace"]

      cross_tenant =
        request(
          :put,
          "/api/v1/entities/records/widget/#{b_record.record_id}",
          ctx_a,
          body,
          pinned
        )

      nonexistent =
        request(:put, "/api/v1/entities/records/widget/#{nowhere_id}", ctx_a, body, pinned)

      assert {cross_tenant.status, cross_tenant.resp_body} ==
               {nonexistent.status, nonexistent.resp_body}

      assert cross_tenant.status == 404
    end

    test "DELETE /records/:entity_type/:record_id -- same byte-identity" do
      ctx_a = tenant_ctx("req310-inv5-del-a")
      ctx_b = tenant_ctx("req310-inv5-del-b")

      seed_active_definition!(ctx_a)
      seed_active_definition!(ctx_b)
      b_record = seed_record!(ctx_b)
      nowhere_id = Ecto.UUID.generate()

      pinned = [trace_id: "req310-inv5-del-fixed-trace"]

      cross_tenant =
        request(
          :delete,
          "/api/v1/entities/records/widget/#{b_record.record_id}",
          ctx_a,
          nil,
          pinned
        )

      nonexistent =
        request(:delete, "/api/v1/entities/records/widget/#{nowhere_id}", ctx_a, nil, pinned)

      assert {cross_tenant.status, cross_tenant.resp_body} ==
               {nonexistent.status, nonexistent.resp_body}

      assert cross_tenant.status == 404
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC6 -- INV-1: no caller-supplied tenant identifier is ever read.
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC6 -- INV-1: tenant id / schema name / slug in body or query changes nothing" do
    test "a WRITE route ignores tenant_id, schema_name and slug in both body and query string" do
      ctx = tenant_ctx("req310-inv1-write")
      other = tenant_ctx("req310-inv1-write-other")

      clean = request(:post, "/api/v1/entities/definitions", ctx, definition_body())
      assert clean.status == 201
      clean_body = body_of(clean)

      # A second, structurally identical create in a SECOND tenant, this
      # time larded with every tenant-identifying field a caller could try,
      # naming the FIRST tenant. If any were read, this request would write
      # into (or read from) tenant one's schema.
      poisoned_body =
        definition_body(%{
          "tenant_id" => Ecto.UUID.generate(),
          "schema_name" => ctx.schema_name,
          "slug" => ctx.slug,
          "prefix" => ctx.schema_name
        })

      poisoned =
        request(
          :post,
          "/api/v1/entities/definitions?tenant_id=#{Ecto.UUID.generate()}" <>
            "&schema_name=#{ctx.schema_name}&slug=#{ctx.slug}&prefix=#{ctx.schema_name}",
          other,
          poisoned_body
        )

      assert poisoned.status == 201
      poisoned_body_out = body_of(poisoned)

      # Same status, same shape -- and the two rows are genuinely distinct
      # (each written into its OWN tenant's schema), which is what proves
      # the poisoned request did not follow the injected schema name.
      assert poisoned.status == clean.status
      assert poisoned_body_out["name"] == clean_body["name"]
      refute poisoned_body_out["id"] == clean_body["id"]

      # The poisoned request's row is NOT visible to the tenant it named.
      visible_to_named_tenant =
        request(:get, "/api/v1/entities/definitions/#{poisoned_body_out["id"]}", ctx)

      assert visible_to_named_tenant.status == 404
    end

    test "a READ route returns an identical response with and without tenant-identifying params" do
      ctx = tenant_ctx("req310-inv1-read")
      other = tenant_ctx("req310-inv1-read-other")
      seed_active_definition!(ctx)

      clean = request(:get, "/api/v1/entities/definitions/by-name/widget", ctx)

      poisoned =
        request(
          :get,
          "/api/v1/entities/definitions/by-name/widget?tenant_id=#{Ecto.UUID.generate()}" <>
            "&schema_name=#{other.schema_name}&slug=#{other.slug}&prefix=#{other.schema_name}",
          ctx
        )

      assert clean.status == 200
      assert {clean.status, clean.resp_body} == {poisoned.status, poisoned.resp_body}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC8 -- the mount reaches the router, not ApiPipeline's `match _` 404.
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC8 -- forward(\"/entities\", to: Letflow.Routers.Entities) is live" do
    test "GET /api/v1/entities/definitions reaches the router (200), not ApiPipeline's catch-all" do
      ctx = tenant_ctx("req310-mount")

      conn = request(:get, "/api/v1/entities/definitions", ctx)

      # ApiPipeline's own `match _` would produce a 404 problem document with
      # no "items" key; a 200 with the list envelope can only come from the
      # forwarded router's own handler.
      assert conn.status == 200
      assert Map.has_key?(body_of(conn), "items")
    end

    test "an unrecognised path UNDER /entities is refused with 403 for a tenant admin (REQ-447 PR 2)" do
      # Mount is live: the request is answered by the ApiPipeline's Authorize plug on the
      # :UnmatchedRoute marker. Only a platform-tenant operator reaches the router's own 404
      # catch-all (the legacy tenant PLATFORM_ADMIN that used to get the 404 pass-through no
      # longer exists outside the platform tenant).
      ctx = tenant_ctx("req310-mount-catchall")

      conn = request(:get, "/api/v1/entities/no-such-thing", ctx)
      assert conn.status == 403

      # control: the platform operator (pinned tenant, PLATFORM_ADMIN) reaches the router's own 404
      op = tenant_ctx("req310-mount-catchall-op", ["PLATFORM_ADMIN"])
      op_conn = request(:get, "/api/v1/entities/no-such-thing", op)
      assert op_conn.status == 404
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC11 -- every error branch in design §7 is reachable at its designed
  # status.
  # ═══════════════════════════════════════════════════════════════════════

  describe "AC11 -- design §7 error mapping" do
    test "create_definition: {:validation, violations} -> 422 with a violation list" do
      ctx = tenant_ctx("req310-err-create-422")

      # A definition name violating Rule 1's ^[a-z][a-z0-9_]{0,63}$ format --
      # the validator's rule is on the DEFINITION's own name, not on a
      # field's, so this is what actually reaches {:validation, violations}.
      conn =
        request(:post, "/api/v1/entities/definitions", ctx, %{
          "name" => "NOT A VALID NAME",
          "display_name" => "Widget",
          "fields" => [%{"name" => "title", "type" => "string"}]
        })

      assert conn.status == 422
      body = body_of(conn)
      assert is_list(body["errors"])
      assert body["errors"] != []
      assert Enum.all?(body["errors"], &Map.has_key?(&1, "code"))
    end

    test "create_definition: {:persistence, changeset} -> 409 on a duplicate name+shape" do
      ctx = tenant_ctx("req310-err-create-409")

      first = request(:post, "/api/v1/entities/definitions", ctx, definition_body())
      assert first.status == 201

      # Byte-identical resubmission: same name, same logical shape -> the
      # (tenant_id, name, logical_shape_version) UNIQUE constraint.
      second = request(:post, "/api/v1/entities/definitions", ctx, definition_body())
      assert second.status == 409
    end

    test "create_definition: a missing required body field -> RFC 9457 field errors, not a 500" do
      ctx = tenant_ctx("req310-err-create-fields")

      conn = request(:post, "/api/v1/entities/definitions", ctx, %{"display_name" => "Widget"})

      assert conn.status == 422
    end

    # ── REWORK ROUND 1, REVIEWER blocker 2 ──────────────────────────────
    #
    # `build_definition_document/1` used to wrap its whole body in a bare
    # `rescue` producing one detail-free 422 with NO `errors` key, because
    # `String.to_existing_atom/1` raises on a string that is not already an
    # atom in the VM. The measured consequence was an error contract that
    # varied with UNRELATED GLOBAL VM STATE: an unknown-atom typo got the
    # detail-free 422, while a typo that happened to collide with an atom
    # loaded by some other module survived conversion and got a proper
    # field error. These tests pin the contract to be the same either way.
    test "⛔ a bad field type produces the SAME well-formed error whether or not it is an existing atom" do
      ctx = tenant_ctx("req310-badtype-atom-parity")

      # "strng" is a typo no module in this application defines as an atom.
      # "ok" is an atom the VM has certainly loaded (it is in the stdlib's
      # own vocabulary) -- but it is NOT a member of Definition.field_type().
      # Under the old rescue these two took DIFFERENT paths. They must not.
      refute_existing_atom!("strng")
      assert :ok == String.to_existing_atom("ok")

      responses =
        for bad_type <- ["strng", "ok"] do
          conn =
            request(:post, "/api/v1/entities/definitions", ctx, %{
              "name" => "widget",
              "display_name" => "Widget",
              "fields" => [%{"name" => "title", "type" => bad_type}]
            })

          {bad_type, conn}
        end

      for {bad_type, conn} <- responses do
        assert conn.status == 422, "type #{inspect(bad_type)} returned #{conn.status}"

        body = body_of(conn)

        # The load-bearing assertion: an `errors` array in BOTH cases. The
        # old code produced this for "ok" and omitted it entirely for
        # "strng".
        assert is_list(body["errors"]) and body["errors"] != [],
               "type #{inspect(bad_type)} produced a detail-free 422: #{conn.resp_body}"

        assert Enum.any?(body["errors"], &(&1["code"] == "malformed")),
               "type #{inspect(bad_type)} errors: #{inspect(body["errors"])}"

        assert Enum.any?(body["errors"], &String.contains?(&1["message"] || "", "field type")),
               "type #{inspect(bad_type)} errors: #{inspect(body["errors"])}"
      end

      # And, stated directly: the two responses are the same document
      # modulo the per-request trace id, which is what "independent of VM
      # atom state" actually means.
      [{_, strng_conn}, {_, ok_conn}] = responses

      assert normalise_problem(strng_conn) == normalise_problem(ok_conn)
    end

    test "a bad search_strategy string is rejected by name, not by a detail-free 422" do
      ctx = tenant_ctx("req310-bad-search-strategy")
      refute_existing_atom!("fulltxt")

      conn =
        request(:post, "/api/v1/entities/definitions", ctx, %{
          "name" => "widget",
          "display_name" => "Widget",
          "fields" => [
            %{
              "name" => "title",
              "type" => "localized_text",
              "locales" => ["en"],
              "search_strategy" => "fulltxt"
            }
          ]
        })

      assert conn.status == 422
      body = body_of(conn)

      assert is_list(body["errors"]) and body["errors"] != [],
             "detail-free 422: #{conn.resp_body}"

      assert Enum.any?(body["errors"], &(&1["code"] == "invalid_search_strategy")),
             inspect(body["errors"])
    end

    test "a bad constraint type string is rejected by name, not by a detail-free 422" do
      ctx = tenant_ctx("req310-bad-constraint-type")
      refute_existing_atom!("uniqe")

      conn =
        request(:post, "/api/v1/entities/definitions", ctx, %{
          "name" => "widget",
          "display_name" => "Widget",
          "fields" => [%{"name" => "title", "type" => "string"}],
          "constraints" => [%{"name" => "c1", "type" => "uniqe", "fields" => ["title"]}]
        })

      assert conn.status == 422
      body = body_of(conn)

      assert is_list(body["errors"]) and body["errors"] != [],
             "detail-free 422: #{conn.resp_body}"

      assert Enum.any?(body["errors"], &String.contains?(&1["message"] || "", "constraint type")),
             inspect(body["errors"])
    end

    test "a structural malformation -- \"fields\": [\"not-a-map\"] -- reaches the caller WITH a field error" do
      ctx = tenant_ctx("req310-fields-not-a-map")

      conn =
        request(:post, "/api/v1/entities/definitions", ctx, %{
          "name" => "widget",
          "display_name" => "Widget",
          "fields" => ["not-a-map"]
        })

      assert conn.status == 422
      body = body_of(conn)

      # Under the old rescue this raised inside Enum.map/2 and collapsed to
      # a 422 with no `errors` key. The Validator's own
      # check_required_list_of_maps/3 has always had a precise violation
      # for it -- the rescue was simply intercepting it first.
      assert is_list(body["errors"]) and body["errors"] != [],
             "detail-free 422: #{conn.resp_body}"

      assert Enum.any?(
               body["errors"],
               &String.contains?(&1["message"] || "", "must all be maps")
             ),
             inspect(body["errors"])
    end

    test "a field object missing \"name\" entirely reaches the caller WITH a field error" do
      ctx = tenant_ctx("req310-field-missing-name")

      conn =
        request(:post, "/api/v1/entities/definitions", ctx, %{
          "name" => "widget",
          "display_name" => "Widget",
          "fields" => [%{"type" => "string"}]
        })

      assert conn.status == 422
      body = body_of(conn)

      assert is_list(body["errors"]) and body["errors"] != [],
             "detail-free 422: #{conn.resp_body}"

      assert Enum.any?(body["errors"], &String.contains?(&1["message"] || "", "field name")),
             inspect(body["errors"])
    end

    test "a non-map entry inside \"indexes\"/\"foreign_keys\"/\"constraints\" also carries a field error" do
      ctx = tenant_ctx("req310-nonmap-optional-lists")

      for key <- ["indexes", "foreign_keys", "constraints"] do
        conn =
          request(:post, "/api/v1/entities/definitions", ctx, %{
            "name" => "widget",
            "display_name" => "Widget",
            "fields" => [%{"name" => "title", "type" => "string"}],
            key => ["not-a-map"]
          })

        assert conn.status == 422, "#{key} returned #{conn.status}"

        assert is_list(body_of(conn)["errors"]) and body_of(conn)["errors"] != [],
               "#{key} produced a detail-free 422: #{conn.resp_body}"
      end
    end

    test "the three getters: {:error, :not_found} -> 404" do
      ctx = tenant_ctx("req310-err-getters-404")

      assert request(:get, "/api/v1/entities/definitions/#{Ecto.UUID.generate()}", ctx).status ==
               404

      assert request(:get, "/api/v1/entities/definitions/active/nope", ctx).status == 404
      assert request(:get, "/api/v1/entities/definitions/by-name/nope", ctx).status == 404
    end

    test "list_definitions: an out-of-range page_size -> 400" do
      ctx = tenant_ctx("req310-err-list-400")

      # Non-numeric -> the router's own parse rejection.
      assert request(:get, "/api/v1/entities/definitions?page_size=abc", ctx).status == 400
      # Numeric but out of range -> list_definitions/2's own
      # :page_size_too_large, mapped to 400 per design §7.
      assert request(:get, "/api/v1/entities/definitions?page_size=100000", ctx).status == 400
    end

    test "list_definitions: an unparseable cursor -> 400" do
      ctx = tenant_ctx("req310-err-list-cursor")

      conn = request(:get, "/api/v1/entities/definitions?cursor=not-a-real-cursor", ctx)
      assert conn.status == 400
    end

    # ── REWORK ROUND 1, REVIEWER blocker 1 ──────────────────────────────
    #
    # The bug these three tests pin: `rationale` was declared
    # `required: false` while every layer below rejects a blank one, so a
    # request the API contract called LEGAL (rationale omitted) failed --
    # and failed OPAQUELY, through the {_tag, %Ecto.Changeset{}} arm's
    # generic "entity definition could not be activated" 422 with no
    # `errors` key, logged as an activation failure rather than a
    # validation one. Every pre-existing activate test above sends
    # "rationale", which is exactly why the gap shipped green.
    test "activate_definition: rationale OMITTED -> 422 RFC 9457 field errors NAMING rationale" do
      ctx = tenant_ctx("req310-activate-no-rationale")
      seed_definition_only!(ctx)

      conn = request(:post, "/api/v1/entities/definitions/widget/activate", ctx, %{})

      assert conn.status == 422
      body = body_of(conn)

      # ⛔ The load-bearing half: an `errors` array naming the field. The
      # old default-to-"" path produced a 422 with NO `errors` key at all,
      # so asserting only on the status would still pass against the bug.
      assert is_list(body["errors"])

      assert Enum.any?(body["errors"], &(&1["field"] == "rationale")),
             "expected a field error naming `rationale`, got: #{inspect(body["errors"])}"

      assert Enum.any?(body["errors"], &(&1["constraint"] == "required"))

      # And the definition genuinely did NOT activate.
      assert request(:get, "/api/v1/entities/definitions/active/widget", ctx).status == 404
    end

    test "activate_definition: a body with NO rationale key takes the same path as an empty object" do
      ctx = tenant_ctx("req310-activate-rationale-other-keys")
      seed_definition_only!(ctx)

      # A non-empty body that simply omits `rationale` -- proving the
      # rejection is about the missing field, not about an empty body.
      conn =
        request(:post, "/api/v1/entities/definitions/widget/activate", ctx, %{
          "note" => "not a rationale"
        })

      assert conn.status == 422
      assert Enum.any?(body_of(conn)["errors"], &(&1["field"] == "rationale"))
    end

    test "activate_definition: a blank/whitespace-only rationale is rejected HERE, not three layers down" do
      ctx = tenant_ctx("req310-activate-blank-rationale")
      seed_definition_only!(ctx)

      for blank <- ["", "   "] do
        conn =
          request(:post, "/api/v1/entities/definitions/widget/activate", ctx, %{
            "rationale" => blank
          })

        assert conn.status == 422,
               "rationale #{inspect(blank)} returned #{conn.status}"

        body = body_of(conn)

        # The distinguishing assertion: a FIELD error naming rationale,
        # not the delegate's opaque "could not be activated" collapse.
        assert is_list(body["errors"]),
               "rationale #{inspect(blank)} produced a detail-free 422: #{conn.resp_body}"

        assert Enum.any?(body["errors"], &(&1["field"] == "rationale"))
      end
    end

    test "activate_definition: a non-blank rationale still activates -- the fix did not break the legal path" do
      ctx = tenant_ctx("req310-activate-with-rationale")
      seed_definition_only!(ctx)

      conn =
        request(:post, "/api/v1/entities/definitions/widget/activate", ctx, %{
          "rationale" => "r"
        })

      assert conn.status == 200
      assert body_of(conn)["status"] == "active"
    end

    test "activate_definition: :not_found -> 404" do
      ctx = tenant_ctx("req310-err-activate-404")

      conn =
        request(:post, "/api/v1/entities/definitions/never-created/activate", ctx, %{
          "rationale" => "x"
        })

      assert conn.status == 404
    end

    test "Records.command_error(): {:definition_not_found, _} -> 404" do
      ctx = tenant_ctx("req310-err-rec-defnotfound")

      conn =
        request(:post, "/api/v1/entities/records/no-such-type", ctx, %{
          "field_values" => %{"title" => "x"}
        })

      assert conn.status == 404
    end

    test "Records.command_error(): {:record_payload_invalid, violations} -> 422" do
      ctx = tenant_ctx("req310-err-rec-422")
      seed_active_definition!(ctx)

      # "title" is required: true in the seeded definition.
      conn =
        request(:post, "/api/v1/entities/records/widget", ctx, %{
          "field_values" => %{"quantity" => 1}
        })

      assert conn.status == 422
      body = body_of(conn)
      assert is_list(body["errors"])
      assert body["errors"] != []
    end

    # REVIEWER finding (re-verifying REQ-336 AC4 after ISS-0648): a genuine
    # duplicate-value write to a promoted-column entity type's own table
    # (e.g. two "tag" records with the same name, now that ISS-0648 makes
    # `uq_tag_name` a real Postgres UNIQUE constraint) used to raise a raw
    # %Postgrex.Error{} that fell through `render_record_command/3`'s own
    # INV-8 catch-all as a bare, detail-free 500 -- this is the missing
    # empirical, end-to-end proof that it now surfaces as a real 422 with a
    # field-level violation instead, exactly like every other
    # `{:record_payload_invalid, _}` case above.
    test "Records.command_error(): a real promoted-column UNIQUE violation -> 422, not a bare 500" do
      ctx = tenant_ctx("req336-ac4-dup-unique-422")

      {:ok, definition} =
        Definitions.create_definition(
          %{
            definition: %{
              name: "tag",
              display_name: "Tag",
              fields: [%{name: "name", type: :string, queried: true, required: true}],
              constraints: [%{name: "uq_tag_name", type: :unique, fields: ["name"]}]
            },
            created_by: ctx.user_id
          },
          ctx.schema_name
        )

      # Activation runs the real ISS-0648 column-promotion trigger
      # synchronously (Definitions.activate_definition/4 ->
      # ensure_column_promotions/2 -> TenantProvisioning.run_column_promotion/1),
      # so the "tag" entity table and its real UNIQUE(name) constraint exist
      # by the time the first POST below runs.
      {:ok, _activated} =
        Definitions.activate_definition(
          definition.name,
          ctx.user_id,
          "req336 go-live",
          ctx.schema_name
        )

      on_exit(fn ->
        Repo.delete_all(
          from(cp in TenantProvisioning.ColumnPromotion,
            where: cp.tenant_id == ^ctx.tenant_id and cp.entity_type == "tag"
          )
        )
      end)

      first =
        request(:post, "/api/v1/entities/records/tag", ctx, %{
          "field_values" => %{"name" => "duplicate-tag"}
        })

      assert first.status == 201

      second =
        request(:post, "/api/v1/entities/records/tag", ctx, %{
          "field_values" => %{"name" => "duplicate-tag"}
        })

      assert second.status == 422

      body = body_of(second)
      assert is_list(body["errors"])

      assert Enum.any?(body["errors"], fn error ->
               error["code"] == "unique" and error["path"] == ["name"]
             end),
             "expected a unique violation naming the \"name\" field, got: #{inspect(body["errors"])}"
    end

    test "Records.command_error(): {:record_not_found, _} -> 404 on update and delete" do
      ctx = tenant_ctx("req310-err-rec-404")
      seed_active_definition!(ctx)
      missing = Ecto.UUID.generate()

      assert request(:put, "/api/v1/entities/records/widget/#{missing}", ctx, %{
               "field_values" => %{"title" => "x"}
             }).status == 404

      assert request(:delete, "/api/v1/entities/records/widget/#{missing}", ctx).status == 404
    end

    test "update_record: {:record_already_deleted, _} -> 409" do
      ctx = tenant_ctx("req310-err-rec-409")
      seed_active_definition!(ctx)
      record = seed_record!(ctx)

      assert request(:delete, "/api/v1/entities/records/widget/#{record.record_id}", ctx).status ==
               200

      conn =
        request(:put, "/api/v1/entities/records/widget/#{record.record_id}", ctx, %{
          "field_values" => %{"title" => "resurrect"}
        })

      assert conn.status == 409
    end

    test "delete_record: deleting an already-deleted record is a no-op 200, not a 409" do
      ctx = tenant_ctx("req310-err-rec-delete-idempotent")
      seed_active_definition!(ctx)
      record = seed_record!(ctx)

      assert request(:delete, "/api/v1/entities/records/widget/#{record.record_id}", ctx).status ==
               200

      second = request(:delete, "/api/v1/entities/records/widget/#{record.record_id}", ctx)
      assert second.status == 200
      assert body_of(second)["deleted"] == true
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # REQ-311 -- POST /entities/query.
  #
  # Fixture helpers below mirror test/letflow/entities/query_joins_test.exs's
  # own (that file is the REQ-300 join suite these routes now front) -- real
  # per-entity-type tables via the real REQ-297 column-promotion mechanism,
  # real entity_field_restrictions/user_entity_grants rows. Nothing is mocked.
  # ═══════════════════════════════════════════════════════════════════════

  defp query(ctx, body, opts \\ []),
    do: request(:post, "/api/v1/entities/query", ctx, body, opts)

  # The "widget" definition the query tests use. Deliberately NOT
  # `seed_active_definition!/2` above (which REQ-310's own route tests share):
  # this one marks both fields `queried: true`, which is what puts them on
  # `Allowlist.load/2`'s output at all. Using the shared fixture here would
  # make every filter in this block fail as {:field_not_allowed, _} and
  # silently stop testing whatever it was written to test, while changing the
  # shared fixture would perturb REQ-310's nine route tests.
  defp seed_queryable_widget!(ctx) do
    create_active_definition!(ctx, %{
      name: "widget",
      display_name: "Widget",
      fields: [
        %{name: "title", type: :string, queried: true},
        %{name: "quantity", type: :integer, queried: true}
      ]
    })
  end

  defp create_active_definition!(ctx, definition) do
    {:ok, entity_definition} =
      Definitions.create_definition(
        %{definition: definition, created_by: ctx.user_id},
        ctx.schema_name
      )

    {:ok, activated} =
      Definitions.activate_definition(
        entity_definition.name,
        ctx.user_id,
        "req311 go-live",
        ctx.schema_name
      )

    activated
  end

  # Promotes one attribute for `entity_type`, creating that entity type's own
  # per-entity-type table on the first promotion -- the real REQ-297 path.
  #
  # ⛔ Registers its OWN on_exit to delete this tenant's `entity_column_promotions`
  # rows. `Letflow.TenantFixture`'s shared teardown deletes the schema, the
  # Registration and the Tenant, but NOT ColumnPromotion rows -- nothing had
  # created any before REQ-311, since none of REQ-310's nine routes promotes a
  # column. Without this, the tenant delete fails on
  # `entity_column_promotions_tenant_id_fkey` and every join test in this file
  # fails in teardown even when its body passed.
  #
  # ExUnit runs on_exit callbacks LIFO, and this one is registered strictly
  # after `provisioned_tenant!/1`'s (a promotion can only happen once a tenant
  # exists), so it runs BEFORE the tenant delete -- which is the order the FK
  # requires. `test/letflow/entities/query_joins_test.exs` does the same
  # cleanup inline in its own hand-rolled tenant fixture.
  defp promote_and_create_table!(ctx, entity_type, attribute, pg_type, opts \\ []) do
    references_entity = Keyword.get(opts, :references_entity)

    on_exit(fn ->
      Repo.delete_all(
        from(cp in Letflow.TenantProvisioning.ColumnPromotion,
          where: cp.tenant_id == ^ctx.tenant_id
        )
      )
    end)

    column_spec =
      if references_entity do
        %{pg_type: pg_type, nullable: true, references_entity: references_entity}
      else
        %{pg_type: pg_type, nullable: true}
      end

    {:ok, [row]} =
      TenantProvisioning.register_column_promotion(
        entity_type,
        attribute,
        column_spec,
        [ctx.tenant_id]
      )

    {:ok, %{status: "ddl_applied"}} = TenantProvisioning.run_column_promotion(row.id)
    :ok
  end

  defp insert_field_restriction!(ctx, entity_type, field_name) do
    Repo.insert_all(
      "entity_field_restrictions",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          entity_type: entity_type,
          field_name: field_name,
          inserted_at: NaiveDateTime.utc_now(),
          updated_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: ctx.schema_name
    )
  end

  defp insert_user_grant!(ctx, user_id, entity_type, field_name) do
    Repo.insert_all(
      "user_entity_grants",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          user_id: Ecto.UUID.dump!(user_id),
          entity_type: entity_type,
          field_name: field_name,
          inserted_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: ctx.schema_name
    )
  end

  # REQ-394: entity-TYPE-level restriction/grant rows -- one layer above
  # insert_field_restriction!/3 and insert_user_grant!/4 above, which
  # operate on individual FIELDS within a visible record. Mirrors those two
  # helpers' own shape exactly (design §1.2's tables reuse FieldGrants'
  # table-pair convention verbatim).
  defp insert_type_restriction!(ctx, entity_type) do
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
      prefix: ctx.schema_name
    )
  end

  defp insert_type_grant!(ctx, user_id, entity_type) do
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
      prefix: ctx.schema_name
    )
  end

  # The redaction sentinel as it appears ON THE WIRE. `FieldGrants`' sentinel
  # is the ATOM `:__field_redacted__` (deliberately an atom, so it cannot
  # collide with any JSON-decoded value -- that module's own moduledoc);
  # Jason encodes an atom as its string name, so a decoded response body
  # carries `"__field_redacted__"`. Derived from `redacted_sentinel/0` rather
  # than hardcoded, so renaming the sentinel cannot leave these tests
  # asserting a stale literal that no longer means "redacted".
  defp wire_sentinel, do: Atom.to_string(FieldGrants.redacted_sentinel())

  # The design's own worked join example: "question" <- "answer_option", the
  # far side carrying BOTH a restricted field and an unrestricted one, so a
  # far-side redaction test can prove redaction happened AND that it was
  # selective.
  defp seed_join_fixture!(ctx) do
    create_active_definition!(ctx, %{
      name: "question",
      display_name: "Question",
      fields: [%{name: "stem", type: :string, queried: true}]
    })

    promote_and_create_table!(ctx, "question", "stem", "text")

    create_active_definition!(ctx, %{
      name: "answer_option",
      display_name: "Answer Option",
      fields: [
        %{name: "text", type: :string, queried: true},
        %{name: "secret_note", type: :string, queried: true},
        %{name: "question_id", type: :string}
      ],
      foreign_keys: [
        %{name: "question_fk", field: "question_id", references_entity: "question"}
      ]
    })

    promote_and_create_table!(ctx, "answer_option", "question_id", "uuid",
      references_entity: "question"
    )

    :ok
  end

  defp seed_query_record!(ctx, entity_type, field_values) do
    {:ok, %{record: record}} =
      Records.create_record(
        %{
          entity_type: entity_type,
          field_values: field_values,
          actor_id: ctx.user_id,
          idempotency_key: Ecto.UUID.generate()
        },
        ctx.schema_name
      )

    record
  end

  # ═══════════════════════════════════════════════════════════════════════
  # ⛔ AC1/AC2/AC3 -- THE JOIN-BEARING REDACTION BRANCH.
  #
  # This is the block SECURITY-REVIEWER's verdict on design §11 exists for:
  # "it would be easy to implement only the simpler branch and let it
  # silently under-redact joined reads." A handler that called
  # redact_page/2 (or nothing) on a joined result would return the far-side
  # entity's restricted field IN CLEAR and still pass every non-join test in
  # this file.
  # ═══════════════════════════════════════════════════════════════════════

  describe "REQ-311 AC1 -- a JOINED far-side entity's restricted field is redacted" do
    test "⛔ far-side restricted field -> sentinel, AND an unrestricted far-side field on the SAME row keeps its real value" do
      ctx = tenant_ctx("req311-join-redact")
      seed_join_fixture!(ctx)

      # The restriction is on the FAR side of the join ("answer_option"),
      # NOT on the primary ("question"). The querying user holds no
      # user_entity_grants row for it, so it is in their redaction set for
      # that entity type -- reachable ONLY through redact_joined_page/2's
      # "answer_option"-keyed restriction set.
      insert_field_restriction!(ctx, "answer_option", "secret_note")

      q = seed_query_record!(ctx, "question", %{"stem" => "2 + 2 = ?"})

      seed_query_record!(ctx, "answer_option", %{
        "text" => "4",
        "secret_note" => "THE ANSWER IS FOUR",
        "question_id" => q.record_id
      })

      conn =
        query(ctx, %{
          "entity_type" => "question",
          "filters" => [%{"field" => "stem", "op" => "eq", "value" => "2 + 2 = ?"}],
          "join" => [%{"entity_type" => "answer_option", "fk" => "question_fk"}]
        })

      assert conn.status == 200
      assert [item] = body_of(conn)["items"]

      far_side = item["answer_option"]

      # HALF 1 -- the restricted far-side field IS redacted.
      assert far_side["field_values"]["secret_note"] == wire_sentinel()
      refute far_side["field_values"]["secret_note"] == "THE ANSWER IS FOUR"

      # HALF 2 -- an UNRESTRICTED far-side field on the SAME row keeps its
      # real value. Without this, the test would pass just as well against a
      # handler that redacted every field of everything.
      assert far_side["field_values"]["text"] == "4"

      # And the primary side, which has no restrictions at all, is untouched.
      assert item["primary"]["field_values"]["stem"] == "2 + 2 = ?"
    end

    test "a far-side restricted field the user DOES hold a grant for is NOT redacted -- proving the grant, not the join, decides" do
      ctx = tenant_ctx("req311-join-granted")
      seed_join_fixture!(ctx)

      insert_field_restriction!(ctx, "answer_option", "secret_note")
      insert_user_grant!(ctx, ctx.user_id, "answer_option", "secret_note")

      q = seed_query_record!(ctx, "question", %{"stem" => "granted?"})

      seed_query_record!(ctx, "answer_option", %{
        "text" => "yes",
        "secret_note" => "VISIBLE TO THE GRANT HOLDER",
        "question_id" => q.record_id
      })

      conn =
        query(ctx, %{
          "entity_type" => "question",
          "join" => [%{"entity_type" => "answer_option", "fk" => "question_fk"}]
        })

      assert conn.status == 200
      assert [item] = body_of(conn)["items"]
      assert item["answer_option"]["field_values"]["secret_note"] == "VISIBLE TO THE GRANT HOLDER"
    end
  end

  describe "REQ-311 AC2 -- the two redaction branches are actually distinct" do
    test "a join-bearing and a non-join request over the same entity type both succeed, and only the join-bearing one carries the joined key" do
      ctx = tenant_ctx("req311-two-branches")
      seed_join_fixture!(ctx)

      insert_field_restriction!(ctx, "question", "stem")
      insert_field_restriction!(ctx, "answer_option", "secret_note")

      q = seed_query_record!(ctx, "question", %{"stem" => "shared question"})

      seed_query_record!(ctx, "answer_option", %{
        "text" => "an option",
        "secret_note" => "hidden",
        "question_id" => q.record_id
      })

      # Branch A -- no join: items are flat entity rows, redact_page/2's
      # shape. A "primary"/"answer_option" key here would mean the joined
      # shape leaked into the non-join path.
      plain = query(ctx, %{"entity_type" => "question"})
      assert plain.status == 200
      assert [plain_item] = body_of(plain)["items"]
      refute Map.has_key?(plain_item, "primary")
      refute Map.has_key?(plain_item, "answer_option")
      assert plain_item["field_values"]["stem"] == wire_sentinel()

      # Branch B -- join-bearing: items ARE the joined shape. The presence of
      # the "answer_option" key is what proves redact_joined_page/2 ran:
      # redact_page/2 on this page would have crashed or passed the joined
      # rows through unredacted, and a redact_page/2-shaped result carries no
      # per-entity keys at all.
      joined =
        query(ctx, %{
          "entity_type" => "question",
          "join" => [%{"entity_type" => "answer_option", "fk" => "question_fk"}]
        })

      assert joined.status == 200
      assert [joined_item] = body_of(joined)["items"]
      assert Map.has_key?(joined_item, "primary")
      assert Map.has_key?(joined_item, "answer_option")

      # BOTH sides redacted, each by its OWN entity type's restriction set.
      assert joined_item["primary"]["field_values"]["stem"] == wire_sentinel()
      assert joined_item["answer_option"]["field_values"]["secret_note"] == wire_sentinel()
      assert joined_item["answer_option"]["field_values"]["text"] == "an option"
    end
  end

  describe "REQ-311 -- the NON-join branch redacts BOTH of its own item shapes" do
    # Regression test for a pre-existing gap this route was the first caller
    # to reach: FieldGrants.redact_page/2's private redact_item/2 used to
    # match %Latest{} only, but Compiler.compile_plain/5 emits a plain
    # Compiler.entity_row() MAP whenever the entity type has a promoted
    # per-entity-type table -- so a non-join query against a PROMOTED entity
    # type raised FunctionClauseError -> 500. REQ-311's scope fence forbade
    # touching lib/letflow/entities/, so it shipped behind a router-local
    # shape adapter and filed the real gap as ISS-0600. That fix has landed
    # (redact_item/2 now has a %{field_values: _} when is_map(item) clause)
    # and the adapter is gone; both shapes below are redacted by
    # FieldGrants.redact_page/2 itself. ⛔ These two tests assert the wire
    # OUTCOME, not which function produced it -- they were unchanged by the
    # adapter's retirement and must stay that way.
    test "a non-join query against a PROMOTED entity type (entity_row() map items, not %Latest{}) still redacts" do
      ctx = tenant_ctx("req311-promoted-plain")
      seed_join_fixture!(ctx)

      insert_field_restriction!(ctx, "question", "stem")
      seed_query_record!(ctx, "question", %{"stem" => "CLEARTEXT STEM"})

      conn = query(ctx, %{"entity_type" => "question"})

      assert conn.status == 200
      assert [item] = body_of(conn)["items"]
      assert item["field_values"]["stem"] == wire_sentinel()
      refute item["field_values"]["stem"] == "CLEARTEXT STEM"
    end

    test "a non-join query against an UNPROMOTED entity type (%Latest{} items) still redacts" do
      ctx = tenant_ctx("req311-unpromoted-plain")
      seed_queryable_widget!(ctx)

      insert_field_restriction!(ctx, "widget", "title")
      seed_record!(ctx, "widget", %{"title" => "CLEARTEXT TITLE"})

      conn = query(ctx, %{"entity_type" => "widget"})

      assert conn.status == 200
      assert [item] = body_of(conn)["items"]
      assert item["field_values"]["title"] == wire_sentinel()
    end

    test "record_id is the SAME canonical UUID-string form on both shapes -- a promotion is not observable in a response body" do
      promoted = tenant_ctx("req311-rid-promoted")
      seed_join_fixture!(promoted)
      seeded = seed_query_record!(promoted, "question", %{"stem" => "x"})

      unpromoted = tenant_ctx("req311-rid-unpromoted")
      seed_queryable_widget!(unpromoted)
      seed_record!(unpromoted, "widget", %{"title" => "y"})

      assert [p_item] = body_of(query(promoted, %{"entity_type" => "question"}))["items"]
      assert [u_item] = body_of(query(unpromoted, %{"entity_type" => "widget"}))["items"]

      # The promoted binding reads record_id back as a raw 16-byte binary;
      # both must reach the wire as the canonical string form.
      assert p_item["record_id"] == seeded.record_id
      assert {:ok, _} = Ecto.UUID.cast(p_item["record_id"])
      assert {:ok, _} = Ecto.UUID.cast(u_item["record_id"])
    end
  end

  describe "REQ-311 AC3 -- the restriction_sets map excludes the `through` entity's type" do
    test "a many-to-many query through a join entity returns rows keyed :primary + the joined type only, never the through type" do
      ctx = tenant_ctx("req311-through")

      create_active_definition!(ctx, %{
        name: "topic",
        display_name: "Topic",
        fields: [%{name: "stem", type: :string, queried: true}]
      })

      promote_and_create_table!(ctx, "topic", "stem", "text")

      create_active_definition!(ctx, %{
        name: "label",
        display_name: "Label",
        fields: [%{name: "caption", type: :string, queried: true}]
      })

      promote_and_create_table!(ctx, "label", "caption", "text")

      create_active_definition!(ctx, %{
        name: "topic_labels",
        display_name: "Topic Labels",
        fields: [
          %{name: "topic_id", type: :string},
          %{name: "label_id", type: :string},
          %{name: "note", type: :string}
        ],
        foreign_keys: [
          %{name: "fk_topic", field: "topic_id", references_entity: "topic"},
          %{name: "fk_label", field: "label_id", references_entity: "label"}
        ]
      })

      promote_and_create_table!(ctx, "topic_labels", "topic_id", "uuid",
        references_entity: "topic"
      )

      promote_and_create_table!(ctx, "topic_labels", "label_id", "uuid",
        references_entity: "label"
      )

      # ⛔ THE TRAP THIS TEST GUARDS: a restriction row on the THROUGH entity.
      # If the handler wrongly keyed a restriction set by the through
      # entity's type, this row would be loaded for a key no joined row
      # carries -- harmless-looking. The real defect it flags is the
      # converse: a through-keyed set means the implementer mis-derived the
      # key list, and the same mis-derivation omits or misnames a key that IS
      # exposed, which Map.fetch!/2 turns into a 500.
      #
      # GH #2697: the restricted field must NOT be one of the through
      # entity's fk fields -- a restricted near/far-hop fk is a join-`on`
      # reference and is now refused with 403 (see
      # entities_query_restricted_walker_test.exs T-13). `note` is a plain
      # non-fk field of the through entity, so the "restriction row on the
      # through type" trap this test guards is preserved.
      insert_field_restriction!(ctx, "topic_labels", "note")

      t = seed_query_record!(ctx, "topic", %{"stem" => "linked topic"})
      l = seed_query_record!(ctx, "label", %{"caption" => "math"})

      seed_query_record!(ctx, "topic_labels", %{
        "topic_id" => t.record_id,
        "label_id" => l.record_id
      })

      conn =
        query(ctx, %{
          "entity_type" => "topic",
          "filters" => [%{"field" => "stem", "op" => "eq", "value" => "linked topic"}],
          "join" => [
            %{"entity_type" => "label", "through" => "topic_labels", "fk" => "fk_label"}
          ]
        })

      assert conn.status == 200
      assert [item] = body_of(conn)["items"]

      # The row's key set is EXACTLY :primary + the joined type. The through
      # entity is absent -- its row is never exposed, so no restriction set
      # is keyed for it either.
      assert MapSet.new(Map.keys(item)) == MapSet.new(["primary", "label"])
      refute Map.has_key?(item, "topic_labels")

      assert item["primary"]["field_values"]["stem"] == "linked topic"
      assert item["label"]["field_values"]["caption"] == "math"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC4 -- the 400-vs-422 error-class split (design §4).
  # ═══════════════════════════════════════════════════════════════════════

  describe "REQ-311 AC4 -- 400 for a malformed literal, 422 for a semantic rejection" do
    setup do
      ctx = tenant_ctx("req311-400-422")
      seed_queryable_widget!(ctx)
      %{ctx: ctx}
    end

    test "400: an unrecognised filter \"op\" string -- Types.parse_filter_op/1 rejects it BEFORE compile/2",
         %{ctx: ctx} do
      conn =
        query(ctx, %{
          "entity_type" => "widget",
          "filters" => [%{"field" => "title", "op" => "SQUIGGLE", "value" => "x"}]
        })

      assert conn.status == 400
      assert body_of(conn)["detail"] =~ "SQUIGGLE"
    end

    test "400: an unrecognised sort \"dir\" string -- Types.parse_sort_dir/1 rejects it BEFORE compile/2",
         %{ctx: ctx} do
      conn =
        query(ctx, %{
          "entity_type" => "widget",
          "sort" => [%{"field" => "title", "dir" => "sideways"}]
        })

      assert conn.status == 400
      assert body_of(conn)["detail"] =~ "sideways"
    end

    test "422: a filter naming a field absent from the allowlist -- well-formed, semantically rejected",
         %{ctx: ctx} do
      conn =
        query(ctx, %{
          "entity_type" => "widget",
          "filters" => [%{"field" => "no_such_field", "op" => "eq", "value" => "x"}]
        })

      assert conn.status == 422
      assert body_of(conn)["detail"] =~ "no_such_field"
    end

    test "422: an :in filter whose value is not a list", %{ctx: ctx} do
      conn =
        query(ctx, %{
          "entity_type" => "widget",
          "filters" => [%{"field" => "title", "op" => "in", "value" => "not-a-list"}]
        })

      assert conn.status == 422
    end

    # The pre-parsing is what makes these two DIFFERENT statuses. A handler
    # that skipped it and let compile/2 reject the operator would answer 422
    # to both -- asserted as one comparison so the distinction cannot be lost
    # by editing either test above alone.
    test "the two classes are genuinely different statuses for the same field", %{ctx: ctx} do
      bad_literal =
        query(ctx, %{
          "entity_type" => "widget",
          "filters" => [%{"field" => "title", "op" => "SQUIGGLE", "value" => "x"}]
        })

      bad_semantics =
        query(ctx, %{
          "entity_type" => "widget",
          "filters" => [%{"field" => "nope", "op" => "eq", "value" => "x"}]
        })

      assert {bad_literal.status, bad_semantics.status} == {400, 422}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC5 -- every caller-reachable compile_error() member maps to its
  # design-§4 status.
  # ═══════════════════════════════════════════════════════════════════════

  describe "REQ-311 AC5 -- compile_error() members map to design §4's statuses" do
    test ":entity_type_not_found -> 200 {\"items\": [], \"next_cursor\": null} (REQ-394 -- deliberately no longer 404, see req394 design §2.2)" do
      ctx = tenant_ctx("req311-ce-404")
      conn = query(ctx, %{"entity_type" => "no-such-entity-type"})
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{"items" => [], "next_cursor" => nil}
    end

    test "{:field_not_allowed, _} -> 422" do
      ctx = tenant_ctx("req311-ce-fna")
      seed_queryable_widget!(ctx)

      conn =
        query(ctx, %{
          "entity_type" => "widget",
          "filters" => [%{"field" => "unknown", "op" => "eq", "value" => 1}]
        })

      assert conn.status == 422
    end

    test "{:value_arity_mismatch, _} -> 422 (an :eq clause with no value at all)" do
      ctx = tenant_ctx("req311-ce-arity")
      seed_queryable_widget!(ctx)

      conn =
        query(ctx, %{
          "entity_type" => "widget",
          "filters" => [%{"field" => "title", "op" => "eq"}]
        })

      assert conn.status == 422
    end

    test "{:invalid_in_value, _} -> 422" do
      ctx = tenant_ctx("req311-ce-in")
      seed_queryable_widget!(ctx)

      conn =
        query(ctx, %{
          "entity_type" => "widget",
          "filters" => [%{"field" => "title", "op" => "not_in", "value" => 7}]
        })

      assert conn.status == 422
    end

    test "{:operator_not_valid_for_type, _, _} -> 422 (a :contains on an integer field)" do
      ctx = tenant_ctx("req311-ce-optype")

      create_active_definition!(ctx, %{
        name: "widget",
        display_name: "Widget",
        fields: [%{name: "quantity", type: :integer, queried: true}]
      })

      conn =
        query(ctx, %{
          "entity_type" => "widget",
          "filters" => [%{"field" => "quantity", "op" => "contains", "value" => "3"}]
        })

      assert conn.status == 422
    end

    test "{:too_many_joins, _} -> 422 (five joins exceeds Compiler's @max_joins of four)" do
      ctx = tenant_ctx("req311-ce-joins")
      seed_queryable_widget!(ctx)

      joins =
        for n <- 1..5, do: %{"entity_type" => "other_#{n}", "fk" => "fk_#{n}"}

      conn = query(ctx, %{"entity_type" => "widget", "join" => joins})

      assert conn.status == 422
      assert body_of(conn)["detail"] =~ "5"
    end

    test "{:duplicate_join_target, _} -> 422" do
      ctx = tenant_ctx("req311-ce-dup")
      seed_queryable_widget!(ctx)

      conn =
        query(ctx, %{
          "entity_type" => "widget",
          "join" => [
            %{"entity_type" => "answer_option", "fk" => "a"},
            %{"entity_type" => "answer_option", "fk" => "b"}
          ]
        })

      assert conn.status == 422
      assert body_of(conn)["detail"] =~ "answer_option"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC6 -- Cursor.paginate/5's own error union.
  # ═══════════════════════════════════════════════════════════════════════

  describe "REQ-311 AC6 -- Cursor.paginate/5's error union maps per design §4" do
    setup do
      ctx = tenant_ctx("req311-cursor")
      seed_queryable_widget!(ctx)
      seed_record!(ctx)
      %{ctx: ctx}
    end

    test ":page_size_too_large -> 400", %{ctx: ctx} do
      conn = query(ctx, %{"entity_type" => "widget", "page_size" => 100_000})
      assert conn.status == 400
      assert body_of(conn)["detail"] =~ "page_size"
    end

    test ":invalid_cursor -> 400", %{ctx: ctx} do
      conn = query(ctx, %{"entity_type" => "widget", "cursor" => "not-a-real-cursor"})
      assert conn.status == 400
    end

    test ":wrong_endpoint -> 400 (a well-formed cursor minted for a DIFFERENT endpoint)", %{
      ctx: ctx
    } do
      # Structurally valid and unexpired -- it differs from this endpoint's
      # own cursors ONLY in its prefix literal, which is exactly what
      # Pagination.decode_cursor/4's prefix check exists to catch.
      foreign_cursor = mint_cursor("DEF:", System.system_time(:microsecond), [])

      conn = query(ctx, %{"entity_type" => "widget", "cursor" => foreign_cursor})

      assert conn.status == 400
      assert body_of(conn)["detail"] =~ "endpoint"
    end

    test ":expired -> the dedicated cursor-expired PROBLEM DOCUMENT, not merely a status", %{
      ctx: ctx
    } do
      # This endpoint's own prefix, but minted a year ago -- so it passes the
      # prefix check and fails the expiry check, isolating :expired from
      # :wrong_endpoint and :invalid_cursor.
      year_ago_us = System.system_time(:microsecond) - 365 * 24 * 60 * 60 * 1_000_000

      expired_cursor = mint_cursor(Cursor.cursor_prefix(), year_ago_us, [0])

      conn = query(ctx, %{"entity_type" => "widget", "cursor" => expired_cursor})

      body = body_of(conn)
      expected = Letflow.Api.Error.cursor_expired()

      # Asserted on the problem document's own type/status members -- the
      # dedicated Error.cursor_expired() path -- not just on conn.status,
      # which a generic bad_request would also satisfy.
      assert body["type"] == expected.type
      assert body["status"] == expected.status
      assert conn.status == expected.status
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC7 -- the success envelope, and real cursor paging.
  # ═══════════════════════════════════════════════════════════════════════

  describe "REQ-311 AC7 -- response envelope is exactly {items, next_cursor}" do
    test "the decoded body's KEY SET is exactly [\"items\", \"next_cursor\"] -- no \"count\" key" do
      ctx = tenant_ctx("req311-envelope")
      seed_queryable_widget!(ctx)
      seed_record!(ctx)

      conn = query(ctx, %{"entity_type" => "widget"})

      assert conn.status == 200
      assert MapSet.new(Map.keys(body_of(conn))) == MapSet.new(["items", "next_cursor"])
      refute Map.has_key?(body_of(conn), "count")
    end

    test "paging with the returned next_cursor walks two pages and the final page's next_cursor is null" do
      ctx = tenant_ctx("req311-paging")
      seed_queryable_widget!(ctx)

      for n <- 1..3, do: seed_record!(ctx, "widget", %{"title" => "row-#{n}"})

      page1 = query(ctx, %{"entity_type" => "widget", "page_size" => 2})
      assert page1.status == 200
      body1 = body_of(page1)
      assert length(body1["items"]) == 2
      assert is_binary(body1["next_cursor"])

      page2 =
        query(ctx, %{
          "entity_type" => "widget",
          "page_size" => 2,
          "cursor" => body1["next_cursor"]
        })

      assert page2.status == 200
      body2 = body_of(page2)
      assert length(body2["items"]) == 1
      assert body2["next_cursor"] == nil

      # Every seeded row was seen exactly once across the two pages.
      ids = Enum.map(body1["items"] ++ body2["items"], & &1["record_id"])
      assert length(Enum.uniq(ids)) == 3
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC8 -- INV-1: nothing tenant- or identity-bearing comes from the body.
  # ═══════════════════════════════════════════════════════════════════════

  describe "REQ-311 AC8 -- INV-1: prefix and user_id are server-resolved only" do
    test "tenant_id/schema/slug sent as BODY FIELDS change nothing -- the response is identical to the same request without them" do
      ctx = tenant_ctx("req311-inv1-body")
      seed_queryable_widget!(ctx)
      seed_record!(ctx, "widget", %{"title" => "only row"})

      trace = "req311-inv1-#{Ecto.UUID.generate()}"

      clean = query(ctx, %{"entity_type" => "widget"}, trace_id: trace)

      spoofed =
        query(
          ctx,
          %{
            "entity_type" => "widget",
            "tenant_id" => Ecto.UUID.generate(),
            "schema" => "some_other_tenant_schema",
            "slug" => "some-other-tenant",
            "prefix" => "public",
            "user_id" => Ecto.UUID.generate()
          },
          trace_id: trace
        )

      assert clean.status == 200
      assert spoofed.status == 200
      assert spoofed.resp_body == clean.resp_body
    end

    test "the user_id used for redaction is the AUTHENTICATED caller's -- the SAME body from two users with different grants is redacted differently" do
      ctx = tenant_ctx("req311-inv1-users")
      seed_queryable_widget!(ctx)

      insert_field_restriction!(ctx, "widget", "title")

      # User 1 holds a grant for the restricted field; user 2 does not.
      insert_user_grant!(ctx, ctx.user_id, "widget", "title")
      other = second_user_ctx(ctx)

      seed_record!(ctx, "widget", %{"title" => "CLEARTEXT TITLE"})

      body = %{"entity_type" => "widget"}

      granted = query(ctx, body)
      ungranted = query(other, body)

      assert granted.status == 200
      assert ungranted.status == 200

      assert [granted_item] = body_of(granted)["items"]
      assert [ungranted_item] = body_of(ungranted)["items"]

      assert granted_item["field_values"]["title"] == "CLEARTEXT TITLE"
      assert ungranted_item["field_values"]["title"] == wire_sentinel()

      # The one identical body producing two different bodies is the proof
      # that user_id came from the credential, not the request.
      refute granted.resp_body == ungranted.resp_body
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC9 -- INV-5: cross-tenant and nonexistent are the same bytes.
  # ═══════════════════════════════════════════════════════════════════════

  describe "REQ-311 AC9 -- INV-5: a cross-tenant entity type is byte-identical to a nonexistent one" do
    test "an entity_type that exists only in ANOTHER tenant's schema produces the same bytes as one that exists nowhere" do
      ctx = tenant_ctx("req311-inv5-a")
      other_tenant = tenant_ctx("req311-inv5-b")

      # "hidden_type" is a real, active entity type -- in the OTHER tenant's
      # schema only. The caller below is scoped to their own schema, where it
      # does not exist.
      create_active_definition!(other_tenant, %{
        name: "hidden_type",
        display_name: "Hidden Type",
        fields: [%{name: "stem", type: :string, queried: true}]
      })

      trace = "req311-inv5-#{Ecto.UUID.generate()}"

      cross_tenant = query(ctx, %{"entity_type" => "hidden_type"}, trace_id: trace)
      nonexistent = query(ctx, %{"entity_type" => "absolutely_no_such_type"}, trace_id: trace)

      # REQ-394 (design §2.2): :entity_type_not_found is no longer a 404 for
      # this route -- it is the same 200 {"items": [], "next_cursor": null}
      # envelope a genuinely-empty, visible type produces. Deliberate change
      # from this test's original 404 assertion.
      assert cross_tenant.status == 200

      # ONE assertion comparing the whole documents -- not two separate
      # "both are 200" assertions, which would pass even if the bodies
      # differed and leaked existence.
      assert {cross_tenant.status, cross_tenant.resp_body} ==
               {nonexistent.status, nonexistent.resp_body}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # AC10 -- authorization: the route is really gated by :EntitiesQuery.
  # ═══════════════════════════════════════════════════════════════════════

  describe "REQ-311 AC10 -- the route is gated by a real, enforced :EntitiesQuery clause" do
    test "endpoint_policy_key/2 resolves POST /entities/query to :EntitiesQuery" do
      assert Letflow.Api.Authorization.endpoint_policy_key("POST", "/entities/query") ==
               :EntitiesQuery
    end

    test "a caller whose role does not hold :EntitiesQuery is refused, and one that holds it is not" do
      seeded = tenant_ctx("req311-authz")
      seed_queryable_widget!(seeded)

      # :AGENT_RUNNER holds NO permission at all (Authorization's own
      # role_allows?(:AGENT_RUNNER, _) -> false); :TASK_WORKER is the
      # narrowest role that DOES hold :EntitiesQuery. Both are members of
      # Authorization's five closed roles, so this is driven by the real
      # matrix, not by a role string invented here.
      denied = %{seeded | plaintext: mint_token!(seeded, ["AGENT_RUNNER"])}
      allowed = %{seeded | plaintext: mint_token!(seeded, ["TASK_WORKER"])}

      assert query(denied, %{"entity_type" => "widget"}).status == 403
      assert query(allowed, %{"entity_type" => "widget"}).status == 200
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # REQ-320 -- POST /entities/records/:entity_type/import
  # ═══════════════════════════════════════════════════════════════════════

  defp import_records(ctx, entity_type, body, opts \\ []),
    do: request(:post, "/api/v1/entities/records/#{entity_type}/import", ctx, body, opts)

  defp import_document(entity_type, records, overrides \\ %{}) do
    Map.merge(
      %{
        "record_export_schema_version" => "entities/record-export/v1",
        "entity_type" => entity_type,
        "exported_at" => "2026-09-12T00:00:00Z",
        "records" => records
      },
      overrides
    )
  end

  defp record_count(ctx, entity_type) do
    Repo.aggregate(
      from(l in Letflow.Entities.Record.Latest, where: l.entity_type == ^entity_type),
      :count,
      prefix: ctx.schema_name
    )
  end

  describe "REQ-320 AC -- the 200-record cap is checked FIRST, before any create_record/2 call" do
    test "413, and zero records are created, for a batch of 201 entries" do
      ctx = tenant_ctx("req320-cap")
      seed_active_definition!(ctx)

      records =
        for _ <- 1..201 do
          %{
            "record_id" => Ecto.UUID.generate(),
            "field_values" => %{"title" => "cap test"},
            "deleted" => false
          }
        end

      resp = import_records(ctx, "widget", import_document("widget", records))

      assert resp.status == 413
      assert record_count(ctx, "widget") == 0
    end

    test "a batch of exactly 200 entries is NOT rejected by the cap" do
      ctx = tenant_ctx("req320-cap-boundary")
      seed_active_definition!(ctx)

      records =
        for _ <- 1..200 do
          %{
            "record_id" => Ecto.UUID.generate(),
            "field_values" => %{"title" => "boundary"},
            "deleted" => false
          }
        end

      resp = import_records(ctx, "widget", import_document("widget", records))

      assert resp.status == 200
      assert record_count(ctx, "widget") == 200
    end
  end

  describe "REQ-320 AC -- the record_export_schema_version gate is checked before tenant resolution/DB touch, as its own distinct error" do
    test "a mismatched schema version is rejected 422 before any database touch" do
      ctx = tenant_ctx("req320-schema-version")
      seed_active_definition!(ctx)

      records = [%{"record_id" => Ecto.UUID.generate(), "field_values" => %{"title" => "x"}}]

      body =
        import_document("widget", records, %{
          "record_export_schema_version" => "entities/record-export/v99"
        })

      resp = import_records(ctx, "widget", body)

      assert resp.status == 422
      body = body_of(resp)
      assert body["detail"] =~ "record_export_schema_version"
      assert record_count(ctx, "widget") == 0
    end
  end

  describe "REQ-320 AC -- entity_type path-vs-body mismatch is rejected 422 before any create_record/2 call" do
    test "the document's entity_type must match the route's :entity_type path segment" do
      ctx = tenant_ctx("req320-entity-type-mismatch")
      seed_active_definition!(ctx, "widget")
      seed_active_definition!(ctx, "gadget")

      records = [%{"record_id" => Ecto.UUID.generate(), "field_values" => %{"title" => "x"}}]

      resp = import_records(ctx, "widget", import_document("gadget", records))

      assert resp.status == 422
      assert record_count(ctx, "widget") == 0
      assert record_count(ctx, "gadget") == 0
    end
  end

  describe "REQ-320 AC -- per-batch partial-success semantics, not whole-batch atomicity" do
    test "a batch with one valid and one invalid entry returns 200 carrying both a success and a failure result" do
      ctx = tenant_ctx("req320-partial")
      seed_active_definition!(ctx)

      valid_id = Ecto.UUID.generate()
      invalid_id = Ecto.UUID.generate()

      records = [
        %{"record_id" => valid_id, "field_values" => %{"title" => "ok"}, "deleted" => false},
        # "title" is required -- omitting it reproduces create_record/2's own
        # standalone {:error, {:record_payload_invalid, _}} rejection.
        %{"record_id" => invalid_id, "field_values" => %{"quantity" => 1}, "deleted" => false}
      ]

      resp = import_records(ctx, "widget", import_document("widget", records))

      assert resp.status == 200
      results = body_of(resp)["results"]
      assert length(results) == 2

      [success, failure] = results

      assert success["status"] == "ok"
      assert success["source_record_id"] == valid_id
      assert is_binary(success["record_id"])
      assert success["record_id"] != success["source_record_id"]

      assert failure["status"] == "error"
      assert failure["source_record_id"] == invalid_id
      assert failure["reason"]["type"] == "record_payload_invalid"

      # Proves this is NOT whole-batch rollback: the valid entry's record
      # really was committed despite the other entry's failure.
      assert record_count(ctx, "widget") == 1

      # The same command_error() create_record/2 would return for that
      # entry submitted alone, standalone -- same violation shape.
      assert {:error, {:record_payload_invalid, standalone_violations}} =
               Records.create_record(
                 %{
                   entity_type: "widget",
                   field_values: %{"quantity" => 1},
                   actor_id: ctx.user_id,
                   idempotency_key: Ecto.UUID.generate()
                 },
                 ctx.schema_name
               )

      standalone_codes = Enum.map(standalone_violations, & &1.constraint)
      batch_codes = Enum.map(failure["reason"]["violations"], & &1["code"])
      assert batch_codes == standalone_codes
    end
  end

  describe "REQ-320 AC -- idempotency is INTRA-CALL ONLY, never cross-call" do
    test "within one call, a repeated entry.record_id dedupes to exactly one created record" do
      ctx = tenant_ctx("req320-intra-call-dedup")
      seed_active_definition!(ctx)

      repeated_id = Ecto.UUID.generate()

      records = [
        %{
          "record_id" => repeated_id,
          "field_values" => %{"title" => "first"},
          "deleted" => false
        },
        %{"record_id" => repeated_id, "field_values" => %{"title" => "first"}, "deleted" => false}
      ]

      resp = import_records(ctx, "widget", import_document("widget", records))

      assert resp.status == 200
      results = body_of(resp)["results"]
      assert length(results) == 2
      assert Enum.all?(results, &(&1["status"] == "ok"))

      [first, second] = results
      # Same import_request_id -> same derived idempotency_key for the
      # second occurrence -> create_record/2's own duplicate-key contract
      # returns the ORIGINAL record, not a second one.
      assert first["record_id"] == second["record_id"]

      assert record_count(ctx, "widget") == 1
    end

    test "two separate calls -- even a byte-identical re-POST -- each create their own independent record(s), with NO cross-call dedup" do
      ctx = tenant_ctx("req320-cross-call-no-dedup")
      seed_active_definition!(ctx)

      record_id = Ecto.UUID.generate()

      body =
        import_document("widget", [
          %{
            "record_id" => record_id,
            "field_values" => %{"title" => "repeat"},
            "deleted" => false
          }
        ])

      resp1 = import_records(ctx, "widget", body)
      assert resp1.status == 200
      assert record_count(ctx, "widget") == 1

      # A literal byte-identical re-POST of the same body.
      resp2 = import_records(ctx, "widget", body)
      assert resp2.status == 200

      [result1] = body_of(resp1)["results"]
      [result2] = body_of(resp2)["results"]

      # Each call mints its OWN import_request_id, so each creates its OWN
      # independent record for the same source_record_id -- proven by the
      # COUNT increasing, not by the second call being a no-op.
      assert result1["record_id"] != result2["record_id"]
      assert record_count(ctx, "widget") == 2
    end
  end

  # GH #2551 -- entries without a record_id used to all derive the key
  # "...:nil" and collapse onto the first entry's record.
  defp import_key_suffixes(ctx) do
    from(i in "event_idempotency",
      where: like(i.idempotency_key, "%entities-record-import:%"),
      select: i.idempotency_key
    )
    |> Repo.all(prefix: ctx.schema_name)
    |> Enum.map(fn key ->
      [_, rest] = String.split(key, "entities-record-import:", parts: 2)
      # rest = "<import_request_id uuid>:<suffix>"
      <<request_id::binary-size(36), ":", suffix::binary>> = rest
      {request_id, suffix}
    end)
  end

  defp import_entry(title, record_id \\ :none) do
    base = %{"field_values" => %{"title" => title}, "deleted" => false}

    case record_id do
      :none -> base
      id -> Map.put(base, "record_id", id)
    end
  end

  describe "GH #2551 -- import entries without a record_id are keyed by entry index" do
    test "AC2: two entries with no record_id are both written as two distinct records" do
      ctx = tenant_ctx("gh2551-two-nil")
      seed_active_definition!(ctx)

      resp =
        import_records(
          ctx,
          "widget",
          import_document("widget", [import_entry("first"), import_entry("second")])
        )

      assert resp.status == 200
      [r1, r2] = body_of(resp)["results"]
      assert r1["status"] == "ok"
      assert r2["status"] == "ok"
      assert r1["record_id"] != r2["record_id"]
      assert r1["source_record_id"] == nil
      assert record_count(ctx, "widget") == 2

      titles =
        from(l in Latest, where: l.entity_type == "widget", select: l.field_values)
        |> Repo.all(prefix: ctx.schema_name)
        |> Enum.map(& &1["title"])
        |> Enum.sort()

      assert titles == ["first", "second"]
    end

    test "an explicit record_id: null is treated like an absent record_id" do
      ctx = tenant_ctx("gh2551-explicit-null")
      seed_active_definition!(ctx)

      records = [import_entry("a", nil), import_entry("b", nil), import_entry("c")]
      resp = import_records(ctx, "widget", import_document("widget", records))

      assert resp.status == 200
      results = body_of(resp)["results"]
      assert Enum.all?(results, &(&1["status"] == "ok"))
      assert results |> Enum.map(& &1["record_id"]) |> Enum.uniq() |> length() == 3
      assert record_count(ctx, "widget") == 3
    end

    test "AC1: stored keys -- no record_id gives idx:<zero-based index over ALL entries>; with record_id keeps the inspect(record_id) key" do
      ctx = tenant_ctx("gh2551-key-shape")
      seed_active_definition!(ctx)

      with_id = Ecto.UUID.generate()

      # index 0: nil, 1: record_id, 2: nil. The index counts every entry, so the
      # nil entries are idx:0 and idx:2 (not idx:0 and idx:1).
      records = [import_entry("a"), import_entry("b", with_id), import_entry("c")]
      resp = import_records(ctx, "widget", import_document("widget", records))

      assert resp.status == 200
      assert record_count(ctx, "widget") == 3

      keys = import_key_suffixes(ctx)
      assert [request_id] = keys |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
      assert {:ok, _} = Ecto.UUID.cast(request_id)

      assert keys |> Enum.map(&elem(&1, 1)) |> Enum.sort() ==
               Enum.sort(["idx:0", "idx:2", inspect(with_id)])
    end

    test "mixed batch: a record_id entry and nil entries at different indexes never collide, and all are written" do
      ctx = tenant_ctx("gh2551-mixed")
      seed_active_definition!(ctx)

      id1 = Ecto.UUID.generate()
      id2 = Ecto.UUID.generate()

      records = [
        import_entry("n0"),
        import_entry("r1", id1),
        import_entry("n2"),
        import_entry("r3", id2),
        import_entry("n4")
      ]

      resp = import_records(ctx, "widget", import_document("widget", records))

      assert resp.status == 200
      results = body_of(resp)["results"]
      assert Enum.all?(results, &(&1["status"] == "ok"))
      assert results |> Enum.map(& &1["record_id"]) |> Enum.uniq() |> length() == 5
      assert Enum.map(results, & &1["source_record_id"]) == [nil, id1, nil, id2, nil]
      assert record_count(ctx, "widget") == 5

      suffixes = import_key_suffixes(ctx) |> Enum.map(&elem(&1, 1))
      assert length(suffixes) == 5
      assert length(Enum.uniq(suffixes)) == 5
    end

    test "a record_id whose text looks like an index key does not collide with a nil entry's idx key" do
      ctx = tenant_ctx("gh2551-lookalike")
      seed_active_definition!(ctx)

      # inspect/1 wraps a binary id in quotes, so "idx:0" as a record_id yields
      # the suffix "\"idx:0\"", never the bare idx:0 of the nil entry at index 0.
      records = [import_entry("nil entry"), import_entry("string id", "idx:0")]
      resp = import_records(ctx, "widget", import_document("widget", records))

      assert resp.status == 200
      results = body_of(resp)["results"]
      assert Enum.all?(results, &(&1["status"] == "ok"))
      [r1, r2] = results
      assert r1["record_id"] != r2["record_id"]
      assert record_count(ctx, "widget") == 2
    end

    test "AC4: when every entry carries a record_id the keys and intra-call dedup are unchanged" do
      ctx = tenant_ctx("gh2551-all-ids")
      seed_active_definition!(ctx)

      a = Ecto.UUID.generate()
      b = Ecto.UUID.generate()

      # a appears twice with identical values -> still dedupes to one record.
      records = [import_entry("x", a), import_entry("y", b), import_entry("x", a)]
      resp = import_records(ctx, "widget", import_document("widget", records))

      assert resp.status == 200
      [r1, r2, r3] = body_of(resp)["results"]
      assert r1["record_id"] == r3["record_id"]
      assert r1["record_id"] != r2["record_id"]
      assert record_count(ctx, "widget") == 2

      suffixes = import_key_suffixes(ctx) |> Enum.map(&elem(&1, 1)) |> Enum.sort()
      assert suffixes == Enum.sort([inspect(a), inspect(b)])
      refute Enum.any?(suffixes, &String.starts_with?(&1, "idx:"))
    end

    # AC3 limit: import_request_id is minted inside handle_import_records/2 and
    # the key builder is private, so a same-request-id replay is not reachable
    # without a production hook. What IS asserted: (a) within one call every
    # entry's key is request_id + a deterministic suffix (idx:<n> / inspect(id)),
    # asserted exactly above, so a replay with the same id derives the same
    # keys; (b) two separate calls mint different request ids, so a re-POST of
    # no-record_id entries writes fresh records and never collides (below).
    test "AC3 (limit): a byte-identical re-POST of nil-record_id entries uses a fresh request id and writes fresh records" do
      ctx = tenant_ctx("gh2551-repost")
      seed_active_definition!(ctx)

      body = import_document("widget", [import_entry("a"), import_entry("b")])

      assert import_records(ctx, "widget", body).status == 200
      assert import_records(ctx, "widget", body).status == 200
      assert record_count(ctx, "widget") == 4

      keys = import_key_suffixes(ctx)
      assert length(keys) == 4
      assert keys |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == 2

      assert keys |> Enum.map(&elem(&1, 1)) |> Enum.sort() == ["idx:0", "idx:0", "idx:1", "idx:1"]
    end
  end

  describe "REQ-320 AC -- a deleted: true entry imports as a live, non-deleted record" do
    test "the created record is not marked deleted, and create_record/2 was called exactly as for a non-deleted entry" do
      ctx = tenant_ctx("req320-deleted-entry")
      seed_active_definition!(ctx)

      record_id = Ecto.UUID.generate()

      records = [
        %{
          "record_id" => record_id,
          "field_values" => %{"title" => "was deleted"},
          "deleted" => true
        }
      ]

      resp = import_records(ctx, "widget", import_document("widget", records))

      assert resp.status == 200
      [result] = body_of(resp)["results"]
      assert result["status"] == "ok"

      imported =
        Repo.get_by!(Letflow.Entities.Record.Latest, [record_id: result["record_id"]],
          prefix: ctx.schema_name
        )

      refute imported.deleted
    end
  end

  describe "REQ-320 AC -- an entity_type with no active definition folds to the same 404 create_record/2's single-write path produces" do
    test "returns 404 with the same shape a standalone write against an undefined entity_type produces" do
      ctx = tenant_ctx("req320-no-definition")

      records = [%{"record_id" => Ecto.UUID.generate(), "field_values" => %{"title" => "x"}}]

      resp = import_records(ctx, "nonexistent_type", import_document("nonexistent_type", records))

      standalone_resp =
        request(:post, "/api/v1/entities/records/nonexistent_type", ctx, %{
          "field_values" => %{"title" => "x"}
        })

      assert resp.status == 404
      assert resp.status == standalone_resp.status
      assert record_count(ctx, "nonexistent_type") == 0
    end
  end

  describe "REQ-320 AC -- a success entry never reuses entry.record_id as the created row's own id" do
    test "record_id differs from source_record_id in every success case" do
      ctx = tenant_ctx("req320-fresh-record-id")
      seed_active_definition!(ctx)

      records =
        for _ <- 1..3 do
          %{"record_id" => Ecto.UUID.generate(), "field_values" => %{"title" => "fresh"}}
        end

      resp = import_records(ctx, "widget", import_document("widget", records))

      assert resp.status == 200
      results = body_of(resp)["results"]
      assert length(results) == 3

      for result <- results do
        assert result["status"] == "ok"
        assert result["record_id"] != result["source_record_id"]
      end
    end
  end

  defp mint_token!(ctx, roles) do
    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(ctx.user_id, %{roles: roles, expires_at: nil},
        prefix: ctx.schema_name
      )

    plaintext
  end

  # Mints a cursor in exactly the wire format `Letflow.Api.Pagination`'s own
  # decoder expects -- `"<prefix><mint_time_us>:<resume_key_json>"`,
  # base64url-encoded -- so a test can isolate the prefix check and the
  # expiry check from each other and from a merely-unparseable string.
  # Built from `Pagination.encode_cursor/1` and `Cursor.cursor_prefix/0`
  # rather than a hardcoded literal.
  defp mint_cursor(prefix, mint_time_us, resume_values) do
    Letflow.Api.Pagination.encode_cursor(
      "#{prefix}#{mint_time_us}:#{Jason.encode!(resume_values)}"
    )
  end

  # ═══════════════════════════════════════════════════════════════════════
  # REQ-394 -- per-entity-type record authorization, denial indistinguishable
  # from a genuinely empty entity type. See
  # lib/letflow/design/req394-per-entity-type-authorization.md for the
  # design these tests cover. Written by TEST-DESIGNER at WF-02 Step 3.
  # ═══════════════════════════════════════════════════════════════════════

  describe "REQ-394 AC1 -- denied-type and genuinely-empty-authorized-type POST /entities/query responses are byte-identical" do
    test "a user denied a restricted type and a user with access to a zero-row type of the same shape get byte-identical 200 envelopes" do
      ctx = tenant_ctx("req394-ac1")
      other = second_user_ctx(ctx)

      create_active_definition!(ctx, %{
        name: "restricted_type",
        display_name: "Restricted Type",
        fields: [%{name: "title", type: :string, queried: true}]
      })

      create_active_definition!(ctx, %{
        name: "empty_type",
        display_name: "Empty Type",
        fields: [%{name: "title", type: :string, queried: true}]
      })

      # "restricted_type" genuinely HAS a row -- this is the load-bearing
      # part of the test: it proves the denial actually filters a real
      # record out, rather than merely happening to coincide with a type
      # that would have been empty anyway (which would pass vacuously even
      # if TypeAccess never ran at all -- see the fail-then-pass mutation
      # check in this requirement's handoff report).
      seed_record!(ctx, "restricted_type", %{"title" => "should never surface"})

      insert_type_restriction!(ctx, "restricted_type")
      # ctx.user_id (the first user) holds NO user_entity_type_grants row
      # for "restricted_type" -- denied. `other` (the second user) never
      # gets a grant either, but queries the unrestricted, genuinely-empty
      # "empty_type" instead, which it is entitled to see in full.

      # Pinned so the byte-comparison below is a genuine whole-document
      # comparison -- x-trace-id is per-REQUEST correlation data (echoed
      # from the caller's own x-trace-id header, Letflow.Api.Context's own
      # contract), not per-RESOURCE information, so two DIFFERENT requests
      # would otherwise differ in this one header even when everything
      # this requirement cares about is identical. Same convention as the
      # REQ-311 AC9 INV-5 test above.
      trace = "req394-ac1-#{Ecto.UUID.generate()}"

      denied = query(ctx, %{"entity_type" => "restricted_type"}, trace_id: trace)
      empty_authorized = query(other, %{"entity_type" => "empty_type"}, trace_id: trace)

      assert denied.status == 200
      assert empty_authorized.status == 200
      assert body_of(denied) == %{"items" => [], "next_cursor" => nil}

      # ONE assertion comparing status + body + headers together -- not
      # three separate assertions that could each pass independently while
      # the responses actually differ (this file's own established
      # convention, see the REQ-311 AC9 INV-5 test above).
      assert {denied.status, denied.resp_body, Enum.sort(denied.resp_headers)} ==
               {empty_authorized.status, empty_authorized.resp_body,
                Enum.sort(empty_authorized.resp_headers)}
    end
  end

  describe "REQ-394 AC2 -- denied-type and nonexistent-type responses are byte-identical on all three definitions-read routes" do
    test "GET /entities/definitions/active/:name" do
      ctx = tenant_ctx("req394-ac2-active")

      create_active_definition!(ctx, %{
        name: "restricted_def",
        display_name: "Restricted Def",
        fields: [%{name: "secret_field", type: :string, queried: true}]
      })

      insert_type_restriction!(ctx, "restricted_def")
      # ctx.user_id holds no grant -- denied.

      trace = "req394-ac2-active-#{Ecto.UUID.generate()}"

      denied =
        request(:get, "/api/v1/entities/definitions/active/restricted_def", ctx, nil,
          trace_id: trace
        )

      nonexistent =
        request(:get, "/api/v1/entities/definitions/active/absolutely-no-such-def", ctx, nil,
          trace_id: trace
        )

      assert denied.status == 404
      assert nonexistent.status == 404
      assert {denied.status, denied.resp_body} == {nonexistent.status, nonexistent.resp_body}

      # The field schema never leaked into the denied response's bytes.
      refute denied.resp_body =~ "secret_field"
    end

    test "GET /entities/definitions/by-name/:name" do
      ctx = tenant_ctx("req394-ac2-by-name")

      create_active_definition!(ctx, %{
        name: "restricted_def",
        display_name: "Restricted Def",
        fields: [%{name: "secret_field", type: :string, queried: true}]
      })

      insert_type_restriction!(ctx, "restricted_def")

      trace = "req394-ac2-by-name-#{Ecto.UUID.generate()}"

      denied =
        request(:get, "/api/v1/entities/definitions/by-name/restricted_def", ctx, nil,
          trace_id: trace
        )

      nonexistent =
        request(:get, "/api/v1/entities/definitions/by-name/absolutely-no-such-def", ctx, nil,
          trace_id: trace
        )

      assert denied.status == 404
      assert {denied.status, denied.resp_body} == {nonexistent.status, nonexistent.resp_body}
      refute denied.resp_body =~ "secret_field"
    end

    test "GET /entities/definitions/:id" do
      ctx = tenant_ctx("req394-ac2-by-id")

      activated =
        create_active_definition!(ctx, %{
          name: "restricted_def",
          display_name: "Restricted Def",
          fields: [%{name: "secret_by_id_field", type: :string, queried: true}]
        })

      insert_type_restriction!(ctx, "restricted_def")

      trace = "req394-ac2-by-id-#{Ecto.UUID.generate()}"

      denied =
        request(:get, "/api/v1/entities/definitions/#{activated.id}", ctx, nil, trace_id: trace)

      nonexistent =
        request(:get, "/api/v1/entities/definitions/#{Ecto.UUID.generate()}", ctx, nil,
          trace_id: trace
        )

      assert denied.status == 404
      assert {denied.status, denied.resp_body} == {nonexistent.status, nonexistent.resp_body}
      refute denied.resp_body =~ "secret_by_id_field"

      # Guard the premise: `activated` really is the same definition being
      # denied (i.e. this test exercises a REAL, existing definition, not
      # one that happened to also not exist).
      assert activated.name == "restricted_def"
    end
  end

  describe "REQ-394 AC3 -- nonexistent type and existing-but-unauthorized type are indistinguishable to the same caller" do
    test "POST /entities/query" do
      ctx = tenant_ctx("req394-ac3-query")

      create_active_definition!(ctx, %{
        name: "restricted_type",
        display_name: "Restricted Type",
        fields: [%{name: "title", type: :string, queried: true}]
      })

      seed_record!(ctx, "restricted_type", %{"title" => "hidden from this caller"})
      insert_type_restriction!(ctx, "restricted_type")

      trace = "req394-ac3-query-#{Ecto.UUID.generate()}"

      unauthorized = query(ctx, %{"entity_type" => "restricted_type"}, trace_id: trace)
      nonexistent = query(ctx, %{"entity_type" => "totally-absent-type"}, trace_id: trace)

      assert unauthorized.status == 200
      assert body_of(unauthorized) == %{"items" => [], "next_cursor" => nil}

      assert {unauthorized.status, unauthorized.resp_body, Enum.sort(unauthorized.resp_headers)} ==
               {nonexistent.status, nonexistent.resp_body, Enum.sort(nonexistent.resp_headers)}
    end

    test "GET /entities/definitions/active/:name" do
      ctx = tenant_ctx("req394-ac3-definitions")

      create_active_definition!(ctx, %{
        name: "restricted_def",
        display_name: "Restricted Def",
        fields: [%{name: "title", type: :string, queried: true}]
      })

      insert_type_restriction!(ctx, "restricted_def")

      trace = "req394-ac3-definitions-#{Ecto.UUID.generate()}"

      unauthorized =
        request(:get, "/api/v1/entities/definitions/active/restricted_def", ctx, nil,
          trace_id: trace
        )

      nonexistent =
        request(:get, "/api/v1/entities/definitions/active/totally-absent-type", ctx, nil,
          trace_id: trace
        )

      assert unauthorized.status == 404

      assert {unauthorized.status, unauthorized.resp_body} ==
               {nonexistent.status, nonexistent.resp_body}
    end
  end

  describe "REQ-394 AC4 -- a caller with only the coarse route-level permission and no per-type restriction rows is completely unaffected" do
    test "a tenant that never inserts an entity_type_restrictions row behaves exactly as before this requirement, on both route families" do
      ctx = tenant_ctx("req394-ac4")
      seed_queryable_widget!(ctx)
      seed_record!(ctx, "widget", %{"title" => "unrestricted"})

      # No insert_type_restriction!/2 call anywhere in this test -- the
      # tenant's entity_type_restrictions table is genuinely empty.

      query_conn = query(ctx, %{"entity_type" => "widget"})
      assert query_conn.status == 200
      assert [item] = body_of(query_conn)["items"]
      assert item["field_values"]["title"] == "unrestricted"

      def_conn = request(:get, "/api/v1/entities/definitions/active/widget", ctx)
      assert def_conn.status == 200
      assert body_of(def_conn)["name"] == "widget"
    end
  end

  describe "REQ-394 -- a per-user grant restores full access to a restricted type, end to end through the real routes" do
    test "a user holding a matching user_entity_type_grants row queries and reads the restricted type normally" do
      ctx = tenant_ctx("req394-grant-restores-access")

      create_active_definition!(ctx, %{
        name: "restricted_type",
        display_name: "Restricted Type",
        fields: [%{name: "title", type: :string, queried: true}]
      })

      seed_record!(ctx, "restricted_type", %{"title" => "now visible"})

      insert_type_restriction!(ctx, "restricted_type")
      insert_type_grant!(ctx, ctx.user_id, "restricted_type")

      query_conn = query(ctx, %{"entity_type" => "restricted_type"})
      assert query_conn.status == 200
      assert [item] = body_of(query_conn)["items"]
      assert item["field_values"]["title"] == "now visible"

      def_conn = request(:get, "/api/v1/entities/definitions/active/restricted_type", ctx)
      assert def_conn.status == 200
      assert body_of(def_conn)["name"] == "restricted_type"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # ISS-0935 -- POST /entities/restrictions/import
  # ═══════════════════════════════════════════════════════════════════════

  defp import_restrictions(ctx, body, opts \\ []),
    do: request(:post, "/api/v1/entities/restrictions/import", ctx, body, opts)

  describe "ISS-0935 AC6 -- POST /entities/restrictions/import happy path" do
    test "200 with per-table inserted counts, and the rows are really there" do
      ctx = tenant_ctx("iss0935-restrictions-ok")
      anna = insert_user!(ctx)

      conn =
        import_restrictions(ctx, %{
          "field_restrictions" => [
            %{"entity_type" => "production_batch", "field_name" => "cost_figure"}
          ],
          "field_grants" => [
            %{
              "user_id" => anna.id,
              "entity_type" => "production_batch",
              "field_name" => "cost_figure"
            }
          ],
          "type_restrictions" => [%{"entity_type" => "shipment_manifest"}],
          "type_grants" => []
        })

      assert conn.status == 200

      assert body_of(conn)["inserted"] == %{
               "field_restrictions" => 1,
               "field_grants" => 1,
               "type_restrictions" => 1,
               "type_grants" => 0
             }

      assert Repo.aggregate("entity_field_restrictions", :count, prefix: ctx.schema_name) == 1
      assert Repo.aggregate("user_entity_grants", :count, prefix: ctx.schema_name) == 1
      assert Repo.aggregate("entity_type_restrictions", :count, prefix: ctx.schema_name) == 1
      assert Repo.aggregate("user_entity_type_grants", :count, prefix: ctx.schema_name) == 0
    end

    test "a second, byte-identical call reports all-zero counts" do
      ctx = tenant_ctx("iss0935-restrictions-idem")
      # GH #2808: the caller is granted in the same request (the seed pattern), so the
      # byte-identical re-run still passes the TypeAccess gate on the now-restricted type.
      body = %{
        "type_restrictions" => [%{"entity_type" => "shipment_manifest"}],
        "type_grants" => [%{"user_id" => ctx.user_id, "entity_type" => "shipment_manifest"}]
      }

      assert body_of(import_restrictions(ctx, body))["inserted"]["type_restrictions"] == 1
      second = body_of(import_restrictions(ctx, body))["inserted"]
      assert second["type_restrictions"] == 0
      assert second["type_grants"] == 0
    end

    test "an absent key for a table inserts nothing for that table, not an error" do
      ctx = tenant_ctx("iss0935-restrictions-absent")

      conn = import_restrictions(ctx, %{"type_restrictions" => [%{"entity_type" => "widget"}]})

      assert conn.status == 200

      assert body_of(conn)["inserted"] == %{
               "field_restrictions" => 0,
               "field_grants" => 0,
               "type_restrictions" => 1,
               "type_grants" => 0
             }
    end
  end

  describe "ISS-0935 AC6 -- 403 without :EntitiesRestrictionsManage" do
    test "a caller without the permission is denied, and nothing is written" do
      ctx = tenant_ctx("iss0935-restrictions-403", ["TASK_WORKER"])

      conn =
        import_restrictions(ctx, %{
          "type_restrictions" => [%{"entity_type" => "shipment_manifest"}]
        })

      assert conn.status == 403
      assert Repo.aggregate("entity_type_restrictions", :count, prefix: ctx.schema_name) == 0
    end

    test "a TENANT_ADMIN caller (holds every tenant permission) succeeds against the same body" do
      ctx = tenant_ctx("iss0935-restrictions-403-control", ["TENANT_ADMIN"])

      conn =
        import_restrictions(ctx, %{
          "type_restrictions" => [%{"entity_type" => "shipment_manifest"}]
        })

      assert conn.status == 200
    end
  end

  describe "ISS-0935 AC6 -- 422 on an invalid row" do
    test "an empty entity_type is rejected with 422, and nothing is written" do
      ctx = tenant_ctx("iss0935-restrictions-422")

      conn =
        import_restrictions(ctx, %{
          "field_restrictions" => [%{"entity_type" => "", "field_name" => "cost_figure"}]
        })

      assert conn.status == 422
      assert Repo.aggregate("entity_field_restrictions", :count, prefix: ctx.schema_name) == 0
    end

    test "a user_id that does not resolve to a user in this tenant is rejected with 422" do
      ctx = tenant_ctx("iss0935-restrictions-422-user")

      conn =
        import_restrictions(ctx, %{
          "field_grants" => [
            %{
              "user_id" => Ecto.UUID.generate(),
              "entity_type" => "production_batch",
              "field_name" => "cost_figure"
            }
          ]
        })

      assert conn.status == 422
      assert Repo.aggregate("user_entity_grants", :count, prefix: ctx.schema_name) == 0
    end

    # Cross-tenant user_id injection -- SECURITY-REVIEWER's checklist (design
    # §7), exercised end-to-end through the real HTTP route this time (the
    # unit-level equivalent lives in
    # test/letflow/entities/restrictions_test.exs). A caller in tenant A,
    # holding :EntitiesRestrictionsManage legitimately in A, must not be able
    # to plant a grant row for a REAL user_id that only exists in tenant B.
    test "a user_id belonging to a different tenant is rejected with 422, not silently accepted" do
      ctx_a = tenant_ctx("iss0935-restrictions-xtenant-a")
      ctx_b = tenant_ctx("iss0935-restrictions-xtenant-b")

      body = %{
        "field_grants" => [
          %{
            "user_id" => ctx_b.user_id,
            "entity_type" => "production_batch",
            "field_name" => "cost_figure"
          }
        ]
      }

      conn = import_restrictions(ctx_a, body)
      assert conn.status == 422
      assert Repo.aggregate("user_entity_grants", :count, prefix: ctx_a.schema_name) == 0

      # The same body is genuinely valid against its OWN tenant -- proving
      # this is a real cross-tenant rejection, not a row that would fail
      # validation anywhere.
      assert import_restrictions(ctx_b, body).status == 200
      assert Repo.aggregate("user_entity_grants", :count, prefix: ctx_b.schema_name) == 1
    end
  end

  describe "ISS-0935 -- 400 on a malformed (non-object) JSON body" do
    test "a JSON array body is rejected with 400" do
      ctx = tenant_ctx("iss0935-restrictions-400")

      conn =
        request(:post, "/api/v1/entities/restrictions/import", ctx, ["not", "an", "object"])

      assert conn.status == 400
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # GH #2528 -- optimistic concurrency on PUT/DELETE
  # (lib/letflow/design/gh2528-record-version-conflict.md §6, §8).
  # ═══════════════════════════════════════════════════════════════════════

  # Seeds a record and moves it on by one plain update, so its creation seq
  # (`stale`) is no longer current (`current`).
  defp gh2528_stale_record!(ctx) do
    seed_active_definition!(ctx)
    record = seed_record!(ctx)

    {:ok, %{record: updated}} =
      Records.update_record(
        %{
          entity_type: "widget",
          record_id: record.record_id,
          field_values: %{"title" => "moved on"},
          actor_id: ctx.user_id,
          idempotency_key: Ecto.UUID.generate()
        },
        ctx.schema_name
      )

    %{
      record_id: record.record_id,
      stale: record.last_event_global_seq,
      current: updated.last_event_global_seq
    }
  end

  defp gh2528_stored!(ctx, record_id) do
    {:ok, record} = Latest.get(record_id, "widget", ctx.schema_name)
    record
  end

  # The 409 body carries no record data and no sequence number: no
  # `field_values`/`last_event_global_seq` member and no integer value equal to
  # either seq anywhere in it.
  defp gh2528_assert_conflict_body!(conn, seqs) do
    assert conn.status == 409
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/problem+json"

    body = body_of(conn)
    assert body["code"] == "record_version_conflict"
    refute Map.has_key?(body, "field_values")
    refute Map.has_key?(body, "last_event_global_seq")

    # `status` (always 409) is excluded so a seq that happens to equal 409
    # cannot false-fail; `detail` is the fixed constant string.
    assert body["detail"] == "the record was changed by someone else; reload it and try again"

    for {key, value} <- body, key != "status", seq <- seqs do
      refute value == seq, "409 body member #{key} carries a sequence number"
    end
  end

  defp gh2528_not_found_body,
    do: Error.not_found() |> Error.serialise() |> Jason.decode!() |> Map.delete("trace_id")

  describe "GH-2528 -- record version conflict" do
    test "PUT with a stale expected_last_event_global_seq -> 409 problem+json, no record data, nothing written" do
      ctx = tenant_ctx("gh2528-put-stale")
      %{record_id: id, stale: stale, current: current} = gh2528_stale_record!(ctx)

      conn =
        request(:put, "/api/v1/entities/records/widget/#{id}", ctx, %{
          "field_values" => %{"title" => "stale write"},
          "expected_last_event_global_seq" => stale
        })

      gh2528_assert_conflict_body!(conn, [stale, current])

      stored = gh2528_stored!(ctx, id)
      assert stored.field_values == %{"title" => "moved on"}
      assert stored.last_event_global_seq == current
    end

    test "PUT with the current expected_last_event_global_seq -> 200" do
      ctx = tenant_ctx("gh2528-put-match")
      %{record_id: id, current: current} = gh2528_stale_record!(ctx)

      conn =
        request(:put, "/api/v1/entities/records/widget/#{id}", ctx, %{
          "field_values" => %{"title" => "fresh write"},
          "expected_last_event_global_seq" => current
        })

      assert conn.status == 200
      body = body_of(conn)
      assert body["field_values"] == %{"title" => "fresh write"}
      assert body["last_event_global_seq"] > current
    end

    test "PUT with a non-integer expected_last_event_global_seq -> 422, nothing written" do
      ctx = tenant_ctx("gh2528-put-422")
      %{record_id: id, current: current} = gh2528_stale_record!(ctx)

      for bad <- ["abc", 1.5, true, -1] do
        conn =
          request(:put, "/api/v1/entities/records/widget/#{id}", ctx, %{
            "field_values" => %{"title" => "typed wrong"},
            "expected_last_event_global_seq" => bad
          })

        assert conn.status == 422, "expected 422 for #{inspect(bad)}, got #{conn.status}"
      end

      assert gh2528_stored!(ctx, id).last_event_global_seq == current
    end

    test "PUT with a stale If-Match header only -> 200 (If-Match stays ignored)" do
      ctx = tenant_ctx("gh2528-put-ifmatch")
      %{record_id: id, stale: stale} = gh2528_stale_record!(ctx)

      conn =
        conn(
          :put,
          "/api/v1/entities/records/widget/#{id}",
          Jason.encode!(%{"field_values" => %{"title" => "if-match only"}})
        )
        |> put_req_header("content-type", "application/json")
        |> put_req_header("if-match", ~s("#{stale}"))
        |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
        |> put_req_header("x-tenant-slug", ctx.slug)
        |> dispatch()

      assert conn.status == 200
      assert body_of(conn)["field_values"] == %{"title" => "if-match only"}
    end

    test "DELETE ?expected_last_event_global_seq=<stale> -> 409, record not deleted" do
      ctx = tenant_ctx("gh2528-del-stale")
      %{record_id: id, stale: stale, current: current} = gh2528_stale_record!(ctx)

      conn =
        request(
          :delete,
          "/api/v1/entities/records/widget/#{id}?expected_last_event_global_seq=#{stale}",
          ctx
        )

      gh2528_assert_conflict_body!(conn, [stale, current])
      refute gh2528_stored!(ctx, id).deleted
    end

    test "DELETE ?expected_last_event_global_seq=<current> -> 200, record deleted" do
      ctx = tenant_ctx("gh2528-del-match")
      %{record_id: id, current: current} = gh2528_stale_record!(ctx)

      conn =
        request(
          :delete,
          "/api/v1/entities/records/widget/#{id}?expected_last_event_global_seq=#{current}",
          ctx
        )

      assert conn.status == 200
      assert gh2528_stored!(ctx, id).deleted
    end

    test "DELETE with a non-integer expected_last_event_global_seq query value -> 400, record not deleted" do
      ctx = tenant_ctx("gh2528-del-400")
      %{record_id: id} = gh2528_stale_record!(ctx)

      for raw <- ["abc", "", "-1", "1.5", "1x", "9223372036854775808"] do
        conn =
          request(
            :delete,
            "/api/v1/entities/records/widget/#{id}?expected_last_event_global_seq=#{URI.encode_www_form(raw)}",
            ctx
          )

        assert conn.status == 400, "expected 400 for #{inspect(raw)}, got #{conn.status}"
        assert body_of(conn)["detail"] == "invalid expected_last_event_global_seq"
      end

      refute gh2528_stored!(ctx, id).deleted
    end

    test "INV-5: PUT with an expected value on a cross-tenant or absent record_id -> the same zero-detail 404" do
      ctx_a = tenant_ctx("gh2528-inv5-put-a")
      ctx_b = tenant_ctx("gh2528-inv5-put-b")
      seed_active_definition!(ctx_a)
      seed_active_definition!(ctx_b)
      b_record = seed_record!(ctx_b)
      pinned = [trace_id: "gh2528-inv5-put-fixed-trace"]

      body = %{
        "field_values" => %{"title" => "attempted"},
        "expected_last_event_global_seq" => b_record.last_event_global_seq
      }

      cross_tenant =
        request(
          :put,
          "/api/v1/entities/records/widget/#{b_record.record_id}",
          ctx_a,
          body,
          pinned
        )

      absent =
        request(
          :put,
          "/api/v1/entities/records/widget/#{Ecto.UUID.generate()}",
          ctx_a,
          body,
          pinned
        )

      assert {cross_tenant.status, cross_tenant.resp_body} == {absent.status, absent.resp_body}
      assert cross_tenant.status == 404
      assert normalise_problem(cross_tenant) == gh2528_not_found_body()

      # Tenant B's record is untouched by tenant A's matching-seq attempt.
      after_b = gh2528_stored!(ctx_b, b_record.record_id)
      refute after_b.deleted
      assert after_b.field_values == b_record.field_values
      assert after_b.last_event_global_seq == b_record.last_event_global_seq
    end

    test "INV-5: DELETE with an expected value on a cross-tenant or absent record_id -> the same zero-detail 404" do
      ctx_a = tenant_ctx("gh2528-inv5-del-a")
      ctx_b = tenant_ctx("gh2528-inv5-del-b")
      seed_active_definition!(ctx_a)
      seed_active_definition!(ctx_b)
      b_record = seed_record!(ctx_b)
      pinned = [trace_id: "gh2528-inv5-del-fixed-trace"]
      query = "?expected_last_event_global_seq=#{b_record.last_event_global_seq}"

      cross_tenant =
        request(
          :delete,
          "/api/v1/entities/records/widget/#{b_record.record_id}#{query}",
          ctx_a,
          nil,
          pinned
        )

      absent =
        request(
          :delete,
          "/api/v1/entities/records/widget/#{Ecto.UUID.generate()}#{query}",
          ctx_a,
          nil,
          pinned
        )

      assert {cross_tenant.status, cross_tenant.resp_body} == {absent.status, absent.resp_body}
      assert cross_tenant.status == 404
      assert normalise_problem(cross_tenant) == gh2528_not_found_body()

      # Tenant B's record is untouched by tenant A's matching-seq attempt.
      after_b = gh2528_stored!(ctx_b, b_record.record_id)
      refute after_b.deleted
      assert after_b.field_values == b_record.field_values
      assert after_b.last_event_global_seq == b_record.last_event_global_seq
    end

    test "DELETE with an array or map expected_last_event_global_seq query param -> 400, record not deleted" do
      ctx = tenant_ctx("gh2528-del-400-shape")
      %{record_id: id, current: current} = gh2528_stale_record!(ctx)

      for query <- [
            "expected_last_event_global_seq[]=#{current}",
            "expected_last_event_global_seq[a]=#{current}"
          ] do
        conn = request(:delete, "/api/v1/entities/records/widget/#{id}?#{query}", ctx)

        assert conn.status == 400, "expected 400 for #{query}, got #{conn.status}"
        assert body_of(conn)["detail"] == "invalid expected_last_event_global_seq"
      end

      stored = gh2528_stored!(ctx, id)
      refute stored.deleted
      assert stored.last_event_global_seq == current
    end

    test "PUT with expected_last_event_global_seq: null -> 200 (treated as absent, last-writer-wins)" do
      ctx = tenant_ctx("gh2528-put-null")
      %{record_id: id, current: current} = gh2528_stale_record!(ctx)

      conn =
        request(:put, "/api/v1/entities/records/widget/#{id}", ctx, %{
          "field_values" => %{"title" => "null expected"},
          "expected_last_event_global_seq" => nil
        })

      assert conn.status == 200
      body = body_of(conn)
      assert body["field_values"] == %{"title" => "null expected"}
      assert body["last_event_global_seq"] > current
    end

    test "PUT with expected_last_event_global_seq one above max int8 -> 422, nothing written" do
      ctx = tenant_ctx("gh2528-put-bignum")
      %{record_id: id, current: current} = gh2528_stale_record!(ctx)

      conn =
        request(:put, "/api/v1/entities/records/widget/#{id}", ctx, %{
          "field_values" => %{"title" => "bignum"},
          "expected_last_event_global_seq" => 9_223_372_036_854_775_808
        })

      assert conn.status == 422

      stored = gh2528_stored!(ctx, id)
      assert stored.field_values == %{"title" => "moved on"}
      assert stored.last_event_global_seq == current
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # GH #2529 -- append-only entity types
  # (lib/letflow/design/gh2529-append-only-entity-types.md §2.1, §4).
  # ═══════════════════════════════════════════════════════════════════════

  # Creates + activates an append-only "ledger" type through the context
  # module (the real string-keyed JSONB round-trip), plus one record.
  defp gh2529_append_only_record!(ctx) do
    {:ok, _row} =
      Definitions.create_definition(
        %{
          definition: %{
            name: "ledger",
            display_name: "Ledger",
            append_only: true,
            fields: [%{name: "title", type: :string, required: true}]
          },
          created_by: ctx.user_id
        },
        ctx.schema_name
      )

    {:ok, _activated} =
      Definitions.activate_definition("ledger", ctx.user_id, "gh2529", ctx.schema_name)

    seed_record!(ctx, "ledger", %{"title" => "entry"})
  end

  defp gh2529_assert_append_only_body!(conn) do
    assert conn.status == 422
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/problem+json"

    body = body_of(conn)
    assert body["code"] == "entity_append_only"
    assert body["status"] == 422

    assert body["detail"] ==
             "records of this entity type are append-only and cannot be updated or deleted"

    refute Map.has_key?(body, "field_values")
    refute conn.resp_body =~ "entry"
  end

  defp gh2529_stored!(ctx, record_id) do
    {:ok, record} = Latest.get(record_id, "ledger", ctx.schema_name)
    record
  end

  # Creates + activates one more "ledger" version through the context module.
  # `overrides` is merged into the base document (e.g. the append_only flag and
  # an extra field, so a second version has a distinct logical shape).
  defp gh2529_activate_ledger!(ctx, overrides) do
    document =
      Map.merge(
        %{
          name: "ledger",
          display_name: "Ledger",
          fields: [%{name: "title", type: :string, required: true}]
        },
        overrides
      )

    {:ok, _row} =
      Definitions.create_definition(
        %{definition: document, created_by: ctx.user_id},
        ctx.schema_name
      )

    {:ok, activated} =
      Definitions.activate_definition("ledger", ctx.user_id, "gh2529", ctx.schema_name)

    activated
  end

  describe "append_only (GH #2529)" do
    test "PUT on an append-only type -> 422 entity_append_only, nothing written" do
      ctx = tenant_ctx("gh2529-put")
      record = gh2529_append_only_record!(ctx)

      conn =
        request(:put, "/api/v1/entities/records/ledger/#{record.record_id}", ctx, %{
          "field_values" => %{"title" => "changed"}
        })

      gh2529_assert_append_only_body!(conn)

      stored = gh2529_stored!(ctx, record.record_id)
      assert stored.field_values == %{"title" => "entry"}
      assert stored.last_event_global_seq == record.last_event_global_seq
    end

    test "DELETE on an append-only type -> 422 entity_append_only, nothing written" do
      ctx = tenant_ctx("gh2529-delete")
      record = gh2529_append_only_record!(ctx)

      conn = request(:delete, "/api/v1/entities/records/ledger/#{record.record_id}", ctx)

      gh2529_assert_append_only_body!(conn)

      stored = gh2529_stored!(ctx, record.record_id)
      refute stored.deleted
      assert stored.last_event_global_seq == record.last_event_global_seq
    end

    test "PUT and DELETE on a non-existent record id of an append-only type -> the same 422" do
      ctx = tenant_ctx("gh2529-missing")
      gh2529_append_only_record!(ctx)
      missing = Ecto.UUID.generate()

      put_conn =
        request(:put, "/api/v1/entities/records/ledger/#{missing}", ctx, %{
          "field_values" => %{"title" => "ghost"}
        })

      gh2529_assert_append_only_body!(put_conn)

      delete_conn = request(:delete, "/api/v1/entities/records/ledger/#{missing}", ctx)
      gh2529_assert_append_only_body!(delete_conn)
    end

    # SECURITY-REVIEWER finding 1 (INV-5): the refusal must not reveal whether
    # an id is unknown, was deleted before the flag went on, or belongs to
    # another tenant. trace_id is pinned so resp_body equality is byte-for-byte.
    test "PUT and DELETE give byte-identical 422s for random, pre-flag-deleted and cross-tenant ids" do
      ctx = tenant_ctx("gh2529-ident-a")
      other = tenant_ctx("gh2529-ident-b")

      # (b) caller tenant: a record deleted while "ledger" was mutable, then
      # the flag is activated in a second version with a distinct shape.
      gh2529_activate_ledger!(ctx, %{})
      deleted = seed_record!(ctx, "ledger", %{"title" => "gone"})

      {:ok, %{record: deleted}} =
        Records.delete_record(
          %{
            entity_type: "ledger",
            record_id: deleted.record_id,
            actor_id: ctx.user_id,
            idempotency_key: Ecto.UUID.generate()
          },
          ctx.schema_name
        )

      assert deleted.deleted

      flagged =
        gh2529_activate_ledger!(ctx, %{
          append_only: true,
          fields: [
            %{name: "title", type: :string, required: true},
            %{name: "note", type: :string}
          ]
        })

      assert flagged.definition_json["append_only"] == true

      # (c) tenant B: same type name, MUTABLE, so a request that leaked across
      # the tenant boundary would succeed and change this row.
      gh2529_activate_ledger!(other, %{})
      foreign = seed_record!(other, "ledger", %{"title" => "tenant b"})

      # (a) a random id.
      ids = %{
        random: Ecto.UUID.generate(),
        deleted: deleted.record_id,
        foreign: foreign.record_id
      }

      trace = "gh2529-ident-#{Ecto.UUID.generate()}"

      responses =
        for {label, id} <- ids, method <- [:put, :delete] do
          body = if method == :put, do: %{"field_values" => %{"title" => "changed"}}

          conn =
            request(method, "/api/v1/entities/records/ledger/#{id}", ctx, body, trace_id: trace)

          gh2529_assert_append_only_body!(conn)
          {{label, method}, conn}
        end

      [{_first_key, reference} | rest] = responses

      for {key, conn} <- rest do
        assert conn.status == reference.status, "status differs for #{inspect(key)}"

        assert get_resp_header(conn, "content-type") ==
                 get_resp_header(reference, "content-type"),
               "content-type differs for #{inspect(key)}"

        assert conn.resp_body == reference.resp_body, "body differs for #{inspect(key)}"
      end

      # Tenant B's record is untouched.
      {:ok, foreign_after} = Latest.get(foreign.record_id, "ledger", other.schema_name)
      assert foreign_after.field_values == %{"title" => "tenant b"}
      refute foreign_after.deleted
      assert foreign_after.last_event_global_seq == foreign.last_event_global_seq

      # The caller's deleted record is untouched (no new event).
      deleted_after = gh2529_stored!(ctx, deleted.record_id)
      assert deleted_after.deleted
      assert deleted_after.field_values == deleted.field_values
      assert deleted_after.last_event_global_seq == deleted.last_event_global_seq

      # Nothing was written into the caller's schema under the other ids.
      assert {:error, :not_found} = Latest.get(ids.random, "ledger", ctx.schema_name)
      assert {:error, :not_found} = Latest.get(ids.foreign, "ledger", ctx.schema_name)
    end

    test "POST record on an append-only type -> 201" do
      ctx = tenant_ctx("gh2529-post")
      gh2529_append_only_record!(ctx)

      conn =
        request(:post, "/api/v1/entities/records/ledger", ctx, %{
          "field_values" => %{"title" => "second entry"}
        })

      assert conn.status == 201
      assert body_of(conn)["field_values"] == %{"title" => "second entry"}
    end

    test "a normal type is unchanged: PUT 200 and DELETE 200" do
      ctx = tenant_ctx("gh2529-normal")
      seed_active_definition!(ctx)
      record = seed_record!(ctx)

      put_conn =
        request(:put, "/api/v1/entities/records/widget/#{record.record_id}", ctx, %{
          "field_values" => %{"title" => "edited"}
        })

      assert put_conn.status == 200
      assert body_of(put_conn)["field_values"] == %{"title" => "edited"}

      delete_conn = request(:delete, "/api/v1/entities/records/widget/#{record.record_id}", ctx)
      assert delete_conn.status == 200
      assert body_of(delete_conn)["deleted"] == true
    end

    test "definition POST with append_only true -> 201; after activate, GET active echoes it" do
      ctx = tenant_ctx("gh2529-def-true")

      create_conn =
        request(
          :post,
          "/api/v1/entities/definitions",
          ctx,
          definition_body(%{"append_only" => true})
        )

      assert create_conn.status == 201

      activate_conn =
        request(:post, "/api/v1/entities/definitions/widget/activate", ctx, %{
          "rationale" => "gh2529 go-live"
        })

      assert activate_conn.status == 200

      active_conn = request(:get, "/api/v1/entities/definitions/active/widget", ctx)
      assert active_conn.status == 200
      assert body_of(active_conn)["definition"]["append_only"] == true
    end

    test "definition POST with append_only null -> 201 and no key stored" do
      ctx = tenant_ctx("gh2529-def-null")

      conn =
        request(
          :post,
          "/api/v1/entities/definitions",
          ctx,
          definition_body(%{"append_only" => nil})
        )

      assert conn.status == 201

      {:ok, stored} = Definitions.get_definition_by_name("widget", ctx.schema_name)
      refute Map.has_key?(stored.definition_json, "append_only")
    end

    test "definition POST with append_only \"yes\" -> 422 malformed at [\"append_only\"]" do
      ctx = tenant_ctx("gh2529-def-yes")

      conn =
        request(
          :post,
          "/api/v1/entities/definitions",
          ctx,
          definition_body(%{"append_only" => "yes"})
        )

      assert conn.status == 422
      body = body_of(conn)
      assert is_list(body["errors"])

      assert Enum.any?(
               body["errors"],
               &(&1["code"] == "malformed" and &1["path"] == ["append_only"])
             ),
             "errors: #{inspect(body["errors"])}"

      assert {:error, :not_found} = Definitions.get_definition_by_name("widget", ctx.schema_name)
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # GH #2543 -- an idempotency_key is bound to the request that first used it
  # (lib/letflow/design/gh2543-idempotency-key-binding.md §5, §8).
  # ═══════════════════════════════════════════════════════════════════════

  defp gh2543_reuse_problem do
    Error.idempotency_key_reuse()
    |> Error.serialise()
    |> Jason.decode!()
    |> Map.delete("trace_id")
  end

  defp gh2543_assert_reuse!(conn) do
    assert conn.status == 422
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/problem+json"
    assert normalise_problem(conn) == gh2543_reuse_problem()
  end

  describe "idempotency key binding (GH #2543)" do
    test "POST reuse -> 422, body is exactly the constant problem, contains neither the original record_id nor its field values" do
      ctx = tenant_ctx("gh2543-post")
      seed_active_definition!(ctx)
      key = "gh2543-" <> Ecto.UUID.generate()

      first =
        request(:post, "/api/v1/entities/records/widget", ctx, %{
          "field_values" => %{"title" => "original-secret-title"},
          "idempotency_key" => key
        })

      assert first.status == 201
      original_id = body_of(first)["record_id"]

      conn =
        request(:post, "/api/v1/entities/records/widget", ctx, %{
          "field_values" => %{"title" => "another"},
          "idempotency_key" => key
        })

      gh2543_assert_reuse!(conn)
      refute conn.resp_body =~ original_id
      refute conn.resp_body =~ "original-secret-title"
      assert record_count(ctx, "widget") == 1
    end

    test "PUT reuse -> 422 idempotency_key_reuse" do
      ctx = tenant_ctx("gh2543-put")
      seed_active_definition!(ctx)
      a = seed_record!(ctx)
      b = seed_record!(ctx)
      key = "gh2543-" <> Ecto.UUID.generate()

      first =
        request(:put, "/api/v1/entities/records/widget/#{a.record_id}", ctx, %{
          "field_values" => %{"title" => "a-secret"},
          "idempotency_key" => key
        })

      assert first.status == 200

      conn =
        request(:put, "/api/v1/entities/records/widget/#{b.record_id}", ctx, %{
          "field_values" => %{"title" => "a-secret"},
          "idempotency_key" => key
        })

      gh2543_assert_reuse!(conn)
      refute conn.resp_body =~ a.record_id

      {:ok, stored_b} = Latest.get(b.record_id, "widget", ctx.schema_name)
      assert stored_b.field_values == b.field_values
      assert stored_b.last_event_global_seq == b.last_event_global_seq
    end

    test "POST replay -> 201 with the same record_id" do
      ctx = tenant_ctx("gh2543-replay")
      seed_active_definition!(ctx)

      body = %{
        "field_values" => %{"title" => "same", "quantity" => 3},
        "idempotency_key" => "gh2543-" <> Ecto.UUID.generate()
      }

      first = request(:post, "/api/v1/entities/records/widget", ctx, body)
      second = request(:post, "/api/v1/entities/records/widget", ctx, body)

      assert first.status == 201
      assert second.status == 201
      assert body_of(first)["record_id"] == body_of(second)["record_id"]
      assert record_count(ctx, "widget") == 1
    end

    test "import: same record_id with different values -> per-entry idempotency_key_reuse" do
      ctx = tenant_ctx("gh2543-import")
      seed_active_definition!(ctx)
      repeated_id = Ecto.UUID.generate()

      records = [
        %{
          "record_id" => repeated_id,
          "field_values" => %{"title" => "first"},
          "deleted" => false
        },
        %{
          "record_id" => repeated_id,
          "field_values" => %{"title" => "second"},
          "deleted" => false
        }
      ]

      resp = import_records(ctx, "widget", import_document("widget", records))

      assert resp.status == 200
      [first, second] = body_of(resp)["results"]
      assert first["status"] == "ok"

      assert second == %{
               "status" => "error",
               "source_record_id" => repeated_id,
               "reason" => %{"type" => "idempotency_key_reuse"}
             }

      assert record_count(ctx, "widget") == 1
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # GH #2532 -- min/max/non_negative over HTTP
  # (lib/letflow/design/gh2532-field-min-max-non-negative.md §2.1, §5).
  # ═══════════════════════════════════════════════════════════════════════

  defp gh2532_definition_body(quantity_overrides) do
    definition_body(%{
      "fields" => [
        %{"name" => "title", "type" => "string", "required" => true},
        Map.merge(%{"name" => "quantity", "type" => "integer"}, quantity_overrides)
      ]
    })
  end

  defp gh2532_activate_via_http!(ctx, quantity_overrides) do
    create_conn =
      request(
        :post,
        "/api/v1/entities/definitions",
        ctx,
        gh2532_definition_body(quantity_overrides)
      )

    assert create_conn.status == 201

    activate_conn =
      request(:post, "/api/v1/entities/definitions/widget/activate", ctx, %{
        "rationale" => "gh2532 go-live"
      })

    assert activate_conn.status == 200
  end

  describe "GH #2532 ranges" do
    test "POST definition with bounds -> 201; GET active returns the keys" do
      ctx = tenant_ctx("gh2532-def-keys")
      gh2532_activate_via_http!(ctx, %{"min" => 0, "max" => 1000, "non_negative" => true})

      active_conn = request(:get, "/api/v1/entities/definitions/active/widget", ctx)
      assert active_conn.status == 200

      quantity =
        Enum.find(body_of(active_conn)["definition"]["fields"], &(&1["name"] == "quantity"))

      assert quantity["min"] == 0
      assert quantity["max"] == 1000
      assert quantity["non_negative"] == true
    end

    test "min > max -> 422 invalid_range at [fields, quantity], nothing stored" do
      ctx = tenant_ctx("gh2532-def-minmax")

      conn =
        request(
          :post,
          "/api/v1/entities/definitions",
          ctx,
          gh2532_definition_body(%{"min" => 987_654, "max" => 1})
        )

      assert conn.status == 422
      body = body_of(conn)

      assert Enum.any?(
               body["errors"],
               &(&1["code"] == "invalid_range" and &1["path"] == ["fields", "quantity"])
             )

      refute conn.resp_body =~ "987654"
      assert {:error, :not_found} = Definitions.get_definition_by_name("widget", ctx.schema_name)
    end

    test "a JSON null bound is dropped (absent): 201 and no key stored" do
      ctx = tenant_ctx("gh2532-def-null")

      conn =
        request(
          :post,
          "/api/v1/entities/definitions",
          ctx,
          gh2532_definition_body(%{"min" => nil, "max" => nil, "non_negative" => nil})
        )

      assert conn.status == 201
      {:ok, stored} = Definitions.get_definition_by_name("widget", ctx.schema_name)
      quantity = Enum.find(stored.definition_json["fields"], &(&1["name"] == "quantity"))
      assert quantity == %{"name" => "quantity", "type" => "integer"}
    end

    test "out-of-range record POST -> 422 code minimum, value not echoed; in-range -> 201" do
      ctx = tenant_ctx("gh2532-rec")
      gh2532_activate_via_http!(ctx, %{"min" => 0, "max" => 1000})

      conn =
        request(:post, "/api/v1/entities/records/widget", ctx, %{
          "field_values" => %{"title" => "t", "quantity" => -987_654}
        })

      assert conn.status == 422
      body = body_of(conn)
      assert [violation] = body["errors"]
      assert violation["code"] == "minimum"
      assert violation["path"] == "/quantity"
      refute conn.resp_body =~ "987654"
      assert record_count(ctx, "widget") == 0

      high_conn =
        request(:post, "/api/v1/entities/records/widget", ctx, %{
          "field_values" => %{"title" => "t", "quantity" => 1001}
        })

      assert high_conn.status == 422
      assert [%{"code" => "maximum"}] = body_of(high_conn)["errors"]

      ok_conn =
        request(:post, "/api/v1/entities/records/widget", ctx, %{
          "field_values" => %{"title" => "t", "quantity" => 1000}
        })

      assert ok_conn.status == 201
      assert record_count(ctx, "widget") == 1
    end
  end
end
