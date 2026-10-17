defmodule Letflow.Routers.EntitiesTypeAccessJoinsTest do
  @moduledoc """
  GH #2700 -- HTTP-level tests that TypeAccess (REQ-394) is applied to the
  primary entity type AND every join target (`entity_type` and `through`) on
  `POST /entities/query`, `POST /entities/records/:entity_type/export` (default
  and `unredacted`) and `POST /entities/query/aggregate`.

  A type-denied type and a nonexistent type must be indistinguishable on every
  route (INV-5): same status, same body bytes, same headers (request id and date
  masked), same number of database queries (T-22). Refusal shape per route:
  /query 200 `{"items": [], "next_cursor": null}`; export and aggregate 404.

  Spec: `test/specs/GH2700-type-access.md`. Design:
  `lib/letflow/design/gh2700-type-access-joins-export-aggregate.md`.
  Unit tests: `request_access_test.exs`, `type_access_test.exs`,
  `query_request_guard_test.exs`. Source-shape tests (T-18) live in
  `entities_query_restricted_walker_test.exs` ("T-39 router architecture").

  Restriction rows are inserted per case; the caller never holds a type grant
  unless a case says so. No restricted VALUE is asserted on.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Records
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @hidden %{"items" => [], "next_cursor" => nil}
  @count [%{"fn" => "count"}]
  @routes [:query, :aggregate, :export, :export_unredacted]

  # -- request plumbing -----------------------------------------------------

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  # trace id pinned so whole-response byte comparisons are genuine
  defp request(method, path, ctx, body) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> put_req_header("x-trace-id", "gh2700-pinned-trace")
    |> dispatch()
  end

  defp query(ctx, body), do: request(:post, "/api/v1/entities/query", ctx, body)
  defp aggregate(ctx, body), do: request(:post, "/api/v1/entities/query/aggregate", ctx, body)

  defp export(ctx, entity_type, body),
    do: request(:post, "/api/v1/entities/records/#{entity_type}/export", ctx, body)

  defp agg_count(entity_type, extra),
    do: Map.merge(%{"entity_type" => entity_type, "aggregates" => @count}, extra)

  defp body_of(conn), do: Jason.decode!(conn.resp_body)

  # status, FULL body bytes, headers (per-request correlation headers masked)
  defp signature(conn) do
    headers =
      conn.resp_headers
      |> Enum.reject(fn {name, _} -> name in ["x-request-id", "date"] end)
      |> Enum.sort()

    {conn.status, conn.resp_body, headers}
  end

  defp with_joins(map, []), do: map
  defp with_joins(map, joins), do: Map.put(map, "join", joins)

  # one request of a route kind for {primary_entity_type, joins}
  defp send_route(ctx, :query, {primary, joins}),
    do: query(ctx, with_joins(%{"entity_type" => primary}, joins))

  defp send_route(ctx, :aggregate, {primary, joins}),
    do: aggregate(ctx, agg_count(primary, with_joins(%{}, joins)))

  defp send_route(ctx, :export, {primary, joins}),
    do: export(ctx, primary, with_joins(%{}, joins))

  defp send_route(ctx, :export_unredacted, {primary, joins}),
    do: export(ctx, primary, with_joins(%{"unredacted" => true}, joins))

  # the refusal a route gives for a hidden OR nonexistent type
  defp assert_not_found_shape(:query, conn) do
    assert conn.status == 200, "expected 200-empty, got #{conn.status}: #{conn.resp_body}"
    assert body_of(conn) == @hidden
  end

  defp assert_not_found_shape(_export_or_aggregate, conn) do
    assert conn.status == 404, "expected 404, got #{conn.status}: #{conn.resp_body}"
    doc = body_of(conn)
    refute Map.has_key?(doc, "results")
    refute Map.has_key?(doc, "records")
    refute Map.has_key?(doc, "items")
  end

  # -- fixtures -------------------------------------------------------------

  defp insert_user!(schema_name) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "tajoin-#{Ecto.UUID.generate()}",
      display_name: "Type Access Join Test User",
      email: "tajoin-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema_name)
  end

  defp token_ctx(tenant, user, roles) do
    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: tenant.schema_name)

    %{
      tenant_id: tenant.tenant_id,
      schema_name: tenant.schema_name,
      slug: tenant.tenant.slug,
      plaintext: plaintext,
      user_id: user.id
    }
  end

  defp tenant_ctx(slug_prefix, roles) do
    tenant =
      TenantFixture.provisioned_tenant!(
        slug_prefix: slug_prefix,
        display_name: "Type Access Joins Test Tenant"
      )

    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)
    token_ctx(tenant, insert_user!(tenant.schema_name), roles)
  end

  # a second user of the SAME tenant (another caller)
  defp other_user_ctx(ctx) do
    tenant = %{
      tenant_id: ctx.tenant_id,
      schema_name: ctx.schema_name,
      tenant: %{slug: ctx.slug}
    }

    token_ctx(tenant, insert_user!(ctx.schema_name), ["TENANT_ADMIN"])
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
        "tajoin go-live",
        ctx.schema_name
      )

    activated
  end

  defp seed_record!(ctx, entity_type, field_values) do
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

  # Replace the tenant's whole type-restriction set; reads are uncached.
  defp set_type_restrictions!(ctx, entity_types) do
    Repo.delete_all("entity_type_restrictions", prefix: ctx.schema_name)
    Enum.each(entity_types, &insert_type_restriction!(ctx, &1))
    :ok
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

  defp audit_count(ctx),
    do: Repo.aggregate(from(e in "audit_entries", select: e.id), :count, prefix: ctx.schema_name)

  defp type_restriction_count(ctx),
    do:
      Repo.aggregate(from(r in "entity_type_restrictions", select: r.id), :count,
        prefix: ctx.schema_name
      )

  defp promote_and_create_table!(ctx, entity_type, attribute, pg_type, references_entity) do
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

  # Fixture (five types, as the design): primary P=p_ent(p_ref); J=j_ent declares
  # fk "j_p_fk" -> P (direct join); T=t_ent (through; "t_p_fk" -> P, "t_f_fk" -> F);
  # F=f_ent (far); N=n_ent (allowed, unrelated). Plus dangling_ent which declares
  # "d_fk" -> ghost_ent, a type that does NOT exist (the primary-declares-the-fk
  # case, T-6). Two P rows: p1 (has a J and a T row) and p2 (has neither), so a
  # join count is 1 where the plain count is 2 (the presence oracle, T-9).
  defp join_ctx!(slug_prefix) do
    ctx = tenant_ctx(slug_prefix, ["TENANT_ADMIN"])

    create_active_definition!(ctx, %{
      name: "p_ent",
      display_name: "P",
      fields: [%{name: "p_ref", type: :string, queried: true}]
    })

    promote_and_create_table!(ctx, "p_ent", "p_ref", "text", nil)

    create_active_definition!(ctx, %{
      name: "f_ent",
      display_name: "F",
      fields: [%{name: "f_id", type: :string, queried: true}]
    })

    promote_and_create_table!(ctx, "f_ent", "f_id", "text", nil)

    create_active_definition!(ctx, %{
      name: "n_ent",
      display_name: "N",
      fields: [%{name: "n_val", type: :string, queried: true}]
    })

    promote_and_create_table!(ctx, "n_ent", "n_val", "text", nil)

    create_active_definition!(ctx, %{
      name: "j_ent",
      display_name: "J",
      fields: [%{name: "p_ref", type: :string}],
      foreign_keys: [%{name: "j_p_fk", field: "p_ref", references_entity: "p_ent"}]
    })

    promote_and_create_table!(ctx, "j_ent", "p_ref", "uuid", "p_ent")

    create_active_definition!(ctx, %{
      name: "t_ent",
      display_name: "T",
      fields: [%{name: "p_id", type: :string}, %{name: "f_id", type: :string}],
      foreign_keys: [
        %{name: "t_p_fk", field: "p_id", references_entity: "p_ent"},
        %{name: "t_f_fk", field: "f_id", references_entity: "f_ent"}
      ]
    })

    promote_and_create_table!(ctx, "t_ent", "p_id", "uuid", "p_ent")
    promote_and_create_table!(ctx, "t_ent", "f_id", "uuid", "f_ent")

    create_active_definition!(ctx, %{
      name: "dangling_ent",
      display_name: "Dangling",
      fields: [%{name: "d_ref", type: :string}],
      foreign_keys: [%{name: "d_fk", field: "d_ref", references_entity: "ghost_ent"}]
    })

    p1 = seed_record!(ctx, "p_ent", %{"p_ref" => "r1"})
    _p2 = seed_record!(ctx, "p_ent", %{"p_ref" => "r2"})
    f1 = seed_record!(ctx, "f_ent", %{"f_id" => "x"})
    seed_record!(ctx, "n_ent", %{"n_val" => "n"})
    seed_record!(ctx, "j_ent", %{"p_ref" => p1.record_id})
    seed_record!(ctx, "t_ent", %{"p_id" => p1.record_id, "f_id" => f1.record_id})
    ctx
  end

  defp j(type, fk), do: %{"entity_type" => type, "fk" => fk}
  defp th(type, via, fk), do: %{"entity_type" => type, "through" => via, "fk" => fk}

  @j_join [%{"entity_type" => "j_ent", "fk" => "j_p_fk"}]
  @t_join [%{"entity_type" => "f_ent", "through" => "t_ent", "fk" => "t_f_fk"}]

  # The indistinguishability matrix: for each position, a DENIED existing type
  # against an ABSENT type name. `restrict` is the only restricted type in the
  # case, so the denied request is refused for that one reason alone.
  defp cases do
    [
      %{
        label: "primary",
        restrict: "p_ent",
        denied: {"p_ent", []},
        absent: {"ghost_ent", []},
        kind: :hidden
      },
      %{
        label: "direct target, valid fk",
        restrict: "j_ent",
        denied: {"p_ent", [j("j_ent", "j_p_fk")]},
        absent: {"p_ent", [j("ghost_ent", "j_p_fk")]},
        kind: :hidden
      },
      %{
        label: "direct target, wrong fk",
        restrict: "j_ent",
        denied: {"p_ent", [j("j_ent", "bogus_fk")]},
        absent: {"p_ent", [j("ghost_ent", "bogus_fk")]},
        kind: :hidden
      },
      %{
        label: "far target, valid fk",
        restrict: "f_ent",
        denied: {"p_ent", [th("f_ent", "t_ent", "t_f_fk")]},
        absent: {"p_ent", [th("ghost_f", "t_ent", "t_f_fk")]},
        kind: :hidden
      },
      %{
        label: "far target, wrong fk",
        restrict: "f_ent",
        denied: {"p_ent", [th("f_ent", "t_ent", "bogus_fk")]},
        absent: {"p_ent", [th("ghost_f", "t_ent", "bogus_fk")]},
        kind: :hidden
      },
      %{
        label: "through entity, valid fk",
        restrict: "t_ent",
        denied: {"p_ent", [th("f_ent", "t_ent", "t_f_fk")]},
        absent: {"p_ent", [th("f_ent", "ghost_t", "t_f_fk")]},
        kind: :hidden
      },
      %{
        label: "through entity, wrong fk",
        restrict: "t_ent",
        denied: {"p_ent", [th("f_ent", "t_ent", "bogus_fk")]},
        absent: {"p_ent", [th("f_ent", "ghost_t", "bogus_fk")]},
        kind: :hidden
      },
      %{
        label: "far target combined with a wrong-fk EARLIER join (M7)",
        restrict: "f_ent",
        denied: {"p_ent", [j("j_ent", "bogus_fk"), th("f_ent", "t_ent", "t_f_fk")]},
        absent: {"p_ent", [j("j_ent", "bogus_fk"), th("ghost_f", "t_ent", "t_f_fk")]},
        kind: :hidden
      },
      %{
        label: "through entity combined with a wrong-fk EARLIER join",
        restrict: "t_ent",
        denied: {"p_ent", [j("j_ent", "bogus_fk"), th("f_ent", "t_ent", "t_f_fk")]},
        absent: {"p_ent", [j("j_ent", "bogus_fk"), th("f_ent", "ghost_t", "t_f_fk")]},
        kind: :hidden
      },
      %{
        label: "primary itself declares the fk to the denied far type",
        restrict: "f_ent",
        denied: {"t_ent", [j("f_ent", "t_f_fk")]},
        absent: {"dangling_ent", [j("ghost_ent", "d_fk")]},
        kind: :hidden
      },
      %{
        label: "duplicate join target (shape error precedes the gate)",
        restrict: "j_ent",
        denied: {"p_ent", [j("j_ent", "j_p_fk"), j("j_ent", "j_p_fk")]},
        absent: {"p_ent", [j("ghost_ent", "j_p_fk"), j("ghost_ent", "j_p_fk")]},
        kind: :shape
      },
      %{
        label: "too many joins (shape error precedes the gate)",
        restrict: "f_ent",
        denied:
          {"p_ent",
           [
             j("j_ent", "j_p_fk"),
             th("f_ent", "t_ent", "t_f_fk"),
             j("g1", "x"),
             j("g2", "x"),
             j("g3", "x")
           ]},
        absent:
          {"p_ent",
           [
             j("j_ent", "j_p_fk"),
             th("ghost_f", "t_ent", "t_f_fk"),
             j("g1", "x"),
             j("g2", "x"),
             j("g3", "x")
           ]},
        kind: :shape
      }
    ]
  end

  # names that may legitimately be echoed by a shape error (the caller's own
  # strings); normalised so a denied/absent pair compares structurally
  @echoable ["j_ent", "ghost_ent", "f_ent", "ghost_f"]

  defp normalised_body(conn) do
    Enum.reduce(@echoable, conn.resp_body, &String.replace(&2, &1, "TYPE"))
  end

  # ==========================================================================
  # T-1 .. T-4 /query: a denied type anywhere hides the whole request
  # ==========================================================================

  describe "T-1..T-4 POST /entities/query" do
    setup do
      {:ok, ctx: join_ctx!("tajq")}
    end

    test "T-1 a restricted DIRECT join target: 200-empty, no row of the target or of the primary",
         %{
           ctx: ctx
         } do
      set_type_restrictions!(ctx, ["j_ent"])
      conn = query(ctx, %{"entity_type" => "p_ent", "join" => @j_join})

      assert conn.status == 200
      assert body_of(conn) == @hidden
      refute conn.resp_body =~ "r1"
      refute conn.resp_body =~ "j_ent"
    end

    test "T-2 a restricted THROUGH entity (near hop) with the far type allowed: 200-empty, no fk presence",
         %{
           ctx: ctx
         } do
      set_type_restrictions!(ctx, ["t_ent"])
      conn = query(ctx, %{"entity_type" => "p_ent", "join" => @t_join})

      assert conn.status == 200
      assert body_of(conn) == @hidden
      refute conn.resp_body =~ "r1"
    end

    test "T-3 through allowed but the FAR target restricted: 200-empty", %{ctx: ctx} do
      set_type_restrictions!(ctx, ["f_ent"])
      conn = query(ctx, %{"entity_type" => "p_ent", "join" => @t_join})

      assert conn.status == 200
      assert body_of(conn) == @hidden
      refute conn.resp_body =~ "r1"
    end

    test "T-4 a restricted PRIMARY with an allowed join: 200-empty, byte-identical to an absent primary",
         %{
           ctx: ctx
         } do
      set_type_restrictions!(ctx, ["p_ent"])
      denied = query(ctx, %{"entity_type" => "p_ent", "join" => @j_join})
      plain = query(ctx, %{"entity_type" => "p_ent"})
      absent = query(ctx, %{"entity_type" => "ghost_ent", "join" => @j_join})

      assert denied.status == 200
      assert body_of(denied) == @hidden
      assert signature(denied) == signature(absent)
      assert signature(plain) == signature(absent)
    end

    test "a restriction on an UNRELATED type changes nothing", %{ctx: ctx} do
      set_type_restrictions!(ctx, ["n_ent"])

      for body <- [
            %{"entity_type" => "p_ent"},
            %{"entity_type" => "p_ent", "join" => @j_join},
            %{"entity_type" => "p_ent", "join" => @t_join}
          ] do
        conn = query(ctx, body)
        assert conn.status == 200
        refute body_of(conn) == @hidden
      end
    end
  end

  # ==========================================================================
  # T-5 / T-11 / T-19 the permitted case still works; no-restriction tenant
  # ==========================================================================

  describe "T-5 / T-11 / T-19 permitted callers" do
    setup do
      {:ok, ctx: join_ctx!("tapermit")}
    end

    defp assert_joined_results(ctx) do
      for join <- [@j_join, @t_join] do
        q = query(ctx, %{"entity_type" => "p_ent", "join" => join})
        assert q.status == 200
        assert [_one] = body_of(q)["items"]
        assert body_of(q)["next_cursor"] == nil

        a = aggregate(ctx, agg_count("p_ent", %{"join" => join}))
        assert a.status == 200
        assert %{"results" => [%{"values" => %{"count_none" => 1}}]} = body_of(a)

        for body <- [%{"join" => join}, %{"join" => join, "unredacted" => true}] do
          e = export(ctx, "p_ent", body)
          assert e.status == 200
          assert [_one] = body_of(e)["records"]
        end
      end

      plain = aggregate(ctx, agg_count("p_ent", %{}))
      assert %{"results" => [%{"values" => %{"count_none" => 2}}]} = body_of(plain)
    end

    test "T-19 a tenant with NO restriction rows: every route returns the unrestricted result, and no row is ever inserted",
         %{ctx: ctx} do
      assert type_restriction_count(ctx) == 0
      assert_joined_results(ctx)

      q = query(ctx, %{"entity_type" => "p_ent"})
      assert q.status == 200
      assert length(body_of(q)["items"]) == 2

      assert type_restriction_count(ctx) == 0
    end

    test "T-5 permitted twin: the caller holds a grant on the restricted join / through / far type",
         %{ctx: ctx} do
      for type <- ["j_ent", "t_ent", "f_ent"] do
        set_type_restrictions!(ctx, [type])
        Repo.delete_all("user_entity_type_grants", prefix: ctx.schema_name)
        insert_type_grant!(ctx, ctx.user_id, type)

        # the grant makes the SAME shapes that the denied tests refuse succeed
        case type do
          "j_ent" -> assert_joined_results_for(ctx, @j_join)
          _ -> assert_joined_results_for(ctx, @t_join)
        end
      end
    end

    defp assert_joined_results_for(ctx, join) do
      q = query(ctx, %{"entity_type" => "p_ent", "join" => join})
      assert q.status == 200
      assert [_one] = body_of(q)["items"]

      a = aggregate(ctx, agg_count("p_ent", %{"join" => join}))
      assert a.status == 200
      assert %{"results" => [%{"values" => %{"count_none" => 1}}]} = body_of(a)

      e = export(ctx, "p_ent", %{"join" => join})
      assert e.status == 200
      assert [_one] = body_of(e)["records"]
    end

    test "T-11 a granted PRIMARY works on every route", %{ctx: ctx} do
      set_type_restrictions!(ctx, ["p_ent"])
      insert_type_grant!(ctx, ctx.user_id, "p_ent")

      assert length(body_of(query(ctx, %{"entity_type" => "p_ent"}))["items"]) == 2

      assert %{"results" => [%{"values" => %{"count_none" => 2}}]} =
               body_of(aggregate(ctx, agg_count("p_ent", %{})))

      assert length(body_of(export(ctx, "p_ent", %{}))["records"]) == 2
      assert length(body_of(export(ctx, "p_ent", %{"unredacted" => true}))["records"]) == 2
    end

    test "ANOTHER user's grant does not lift the denial for the caller (R2)", %{ctx: ctx} do
      other = other_user_ctx(ctx)
      set_type_restrictions!(ctx, ["j_ent"])
      insert_type_grant!(ctx, other.user_id, "j_ent")

      for route <- @routes do
        caller = send_route(ctx, route, {"p_ent", @j_join})
        assert_not_found_shape(route, caller)
      end

      # the grant holder is served
      assert [_one] =
               body_of(query(other, %{"entity_type" => "p_ent", "join" => @j_join}))["items"]
    end
  end

  # ==========================================================================
  # T-6 / T-7 indistinguishability matrix: denied == absent on every route
  # ==========================================================================

  describe "T-6 / T-7 denied and absent types are indistinguishable" do
    setup do
      {:ok, ctx: join_ctx!("taindist")}
    end

    for route <- @routes do
      test "#{route}: every position and combination answers a denied type byte-for-byte as an absent one",
           %{ctx: ctx} do
        route = unquote(route)

        for %{label: label, restrict: restrict, denied: denied, absent: absent, kind: kind} <-
              cases() do
          set_type_restrictions!(ctx, [restrict])

          d = send_route(ctx, route, denied)
          a = send_route(ctx, route, absent)

          case kind do
            :hidden ->
              assert_not_found_shape(route, d)
              assert_not_found_shape(route, a)
              assert signature(d) == signature(a), "[#{route}] #{label}: denied != absent"

            :shape ->
              assert d.status == 422, "[#{route}] #{label}: expected 422, got #{d.status}"
              assert a.status == 422
              assert normalised_body(d) == normalised_body(a), "[#{route}] #{label}"

              assert Enum.sort(d.resp_headers)
                     |> Enum.reject(&(elem(&1, 0) in ["x-request-id", "date"])) ==
                       Enum.sort(a.resp_headers)
                       |> Enum.reject(&(elem(&1, 0) in ["x-request-id", "date"]))
          end
        end
      end
    end

    test "the /query matrix answers 200-empty for both a denied and an absent type (never 403 / 422 for a hidden type)",
         %{ctx: ctx} do
      for %{restrict: restrict, denied: denied, kind: :hidden} <- cases() do
        set_type_restrictions!(ctx, [restrict])
        conn = send_route(ctx, :query, denied)
        assert conn.status == 200
        assert body_of(conn) == @hidden
      end
    end
  end

  # ==========================================================================
  # T-8 / T-9 / T-10 aggregate and export on a denied type
  # ==========================================================================

  describe "T-8 / T-9 aggregate" do
    setup do
      {:ok, ctx: join_ctx!("taagg")}
    end

    test "T-8 a restricted primary, with and without a join: 404 and no number", %{ctx: ctx} do
      set_type_restrictions!(ctx, ["p_ent"])

      for extra <- [%{}, %{"join" => @j_join}, %{"join" => @t_join}] do
        conn = aggregate(ctx, agg_count("p_ent", extra))
        assert conn.status == 404
        refute conn.resp_body =~ "count"
        refute conn.resp_body =~ "results"
      end

      # a restricted type that is NOT the primary leaves the plain count alone
      set_type_restrictions!(ctx, ["j_ent"])
      plain = aggregate(ctx, agg_count("p_ent", %{}))
      assert %{"results" => [%{"values" => %{"count_none" => 2}}]} = body_of(plain)
    end

    test "T-9 presence oracle closed: a join to a restricted target answers 404, not K (1) vs N (2)",
         %{ctx: ctx} do
      # the oracle is real: unrestricted, the join count (1) differs from the plain count (2)
      assert %{"results" => [%{"values" => %{"count_none" => 1}}]} =
               body_of(aggregate(ctx, agg_count("p_ent", %{"join" => @j_join})))

      for {restricted, join} <- [{"j_ent", @j_join}, {"t_ent", @t_join}, {"f_ent", @t_join}] do
        set_type_restrictions!(ctx, [restricted])
        conn = aggregate(ctx, agg_count("p_ent", %{"join" => join}))

        assert conn.status == 404, "#{restricted}: #{conn.resp_body}"
        refute conn.resp_body =~ "count_none"
      end
    end
  end

  describe "T-10 export" do
    setup do
      {:ok, ctx: join_ctx!("taexp")}
    end

    test "a restricted primary (default and unredacted) and a restricted join target: 404, no record, no audit row",
         %{ctx: ctx} do
      for {restricted, body} <- [
            {"p_ent", %{}},
            {"p_ent", %{"join" => @j_join}},
            {"j_ent", %{"join" => @j_join}},
            {"t_ent", %{"join" => @t_join}},
            {"f_ent", %{"join" => @t_join}}
          ],
          unredacted <- [false, true] do
        set_type_restrictions!(ctx, [restricted])
        before = audit_count(ctx)
        body = if unredacted, do: Map.put(body, "unredacted", true), else: body

        conn = export(ctx, "p_ent", body)

        assert conn.status == 404, "#{restricted} #{inspect(body)}: #{conn.resp_body}"
        refute conn.resp_body =~ "records"
        refute conn.resp_body =~ "r1"
        assert audit_count(ctx) == before
      end
    end

    test "T-12 an exempt export on an ALLOWED type with a restricted FIELD still succeeds and is still audited",
         %{ctx: ctx} do
      insert_field_restriction!(ctx, "p_ent", "p_ref")
      before = audit_count(ctx)

      filters = [%{"field" => "p_ref", "op" => "eq", "value" => "r1"}]

      default = export(ctx, "p_ent", %{"filters" => filters})
      assert default.status == 403
      assert audit_count(ctx) == before

      exempt = export(ctx, "p_ent", %{"filters" => filters, "unredacted" => true})
      assert exempt.status == 200
      assert [_one] = body_of(exempt)["records"]
      assert audit_count(ctx) == before + 1

      # and the type gate still applies to an exempt exporter
      set_type_restrictions!(ctx, ["p_ent"])
      denied = export(ctx, "p_ent", %{"filters" => filters, "unredacted" => true})
      assert denied.status == 404
      assert audit_count(ctx) == before + 1
    end
  end

  # ==========================================================================
  # T-13 the type gate precedes the field guard
  # ==========================================================================

  describe "T-13 type gate before the restricted-field guard" do
    setup do
      ctx = join_ctx!("tafield")
      insert_field_restriction!(ctx, "p_ent", "p_ref")
      {:ok, ctx: ctx}
    end

    @restricted_filter [%{"field" => "p_ref", "op" => "eq", "value" => "r1"}]

    test "a restricted field AND a denied join target: the not-found shape, never 403", %{
      ctx: ctx
    } do
      set_type_restrictions!(ctx, ["j_ent"])

      for route <- @routes do
        conn =
          case route do
            :query ->
              query(ctx, %{
                "entity_type" => "p_ent",
                "join" => @j_join,
                "filters" => @restricted_filter
              })

            :aggregate ->
              aggregate(
                ctx,
                agg_count("p_ent", %{"join" => @j_join, "filters" => @restricted_filter})
              )

            :export ->
              export(ctx, "p_ent", %{"join" => @j_join, "filters" => @restricted_filter})

            :export_unredacted ->
              export(ctx, "p_ent", %{
                "join" => @j_join,
                "filters" => @restricted_filter,
                "unredacted" => true
              })
          end

        assert_not_found_shape(route, conn)
      end
    end

    test "with the type visible the same request IS refused 403 by the field guard", %{ctx: ctx} do
      set_type_restrictions!(ctx, [])

      for conn <- [
            query(ctx, %{"entity_type" => "p_ent", "filters" => @restricted_filter}),
            aggregate(ctx, agg_count("p_ent", %{"filters" => @restricted_filter})),
            export(ctx, "p_ent", %{"filters" => @restricted_filter})
          ] do
        assert conn.status == 403
      end
    end
  end

  # ==========================================================================
  # T-20 nothing identifying leaks through logs, audit or telemetry
  # ==========================================================================

  describe "T-20 no log, audit or telemetry carries the denied type" do
    setup do
      {:ok, ctx: join_ctx!("talog")}
    end

    test "a denied request on every route logs nothing about the type, writes no audit row, emits no type-bearing telemetry",
         %{ctx: ctx} do
      set_type_restrictions!(ctx, ["f_ent"])
      before = audit_count(ctx)
      parent = self()
      id = "gh2700-http-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          id,
          [:letflow, :http, :request],
          fn _e, _m, meta, _c -> send(parent, {:http_meta, meta}) end,
          nil
        )

      log =
        try do
          capture_log([level: :info], fn ->
            for route <- @routes do
              conn = send_route(ctx, route, {"p_ent", @t_join})
              assert_not_found_shape(route, conn)
            end
          end)
        after
          :telemetry.detach(id)
        end

      for needle <- ["f_ent", "t_f_fk", "restricted", "denied"] do
        refute log =~ needle, "log mentions #{needle}"
      end

      assert audit_count(ctx) == before

      metas = collect_http_meta([])
      assert length(metas) == length(@routes)

      for meta <- metas do
        refute inspect(meta) =~ "f_ent"
        refute inspect(meta) =~ "t_f_fk"
      end
    end

    defp collect_http_meta(acc) do
      receive do
        {:http_meta, meta} -> collect_http_meta([meta | acc])
      after
        0 -> acc
      end
    end
  end

  # ==========================================================================
  # T-22 equal database work: denied == absent (R1 / R6)
  # ==========================================================================
  #
  # What is equal is the WORK THE GATE DOES: the same number of denied-set reads
  # (`entity_type_restrictions`) and the same number of per-type existence reads
  # (`fk_defs/2`, which always begins with an `artifact_activations` lookup, found
  # or not) for a denied request and an absent request of the same shape. TOTAL
  # query counts are NOT equal and cannot be: a type that exists costs two more
  # queries (artifact version + definition) than a missing one in the very same
  # `fk_defs/2` read. That is the residual the design accepts (R6) and is
  # reported, not asserted equal. Counting the gate's own reads also makes the
  # test independent of the once-per-second `api_tokens.last_used_at` UPDATE
  # (the #2729 wall-clock flake), which none of these matchers touches.

  describe "T-22 equal gate work (denied vs absent)" do
    setup do
      {:ok, ctx: join_ctx!("taqcount")}
    end

    # {denied-set reads, per-type existence reads} the request caused
    defp gate_work(fun) do
      id = "gh2700-work-#{System.unique_integer([:positive])}"
      parent = self()

      :ok =
        :telemetry.attach(
          id,
          [:letflow, :repo, :query],
          fn _event, _m, meta, _cfg ->
            if self() == parent and is_binary(meta[:query]),
              do: send(parent, {:work_sql, meta.query})
          end,
          nil
        )

      try do
        result = fun.()
        sqls = drain_work([])

        {result,
         {Enum.count(sqls, &(&1 =~ "entity_type_restrictions")),
          Enum.count(sqls, &(&1 =~ "artifact_activations"))}}
      after
        :telemetry.detach(id)
      end
    end

    defp drain_work(acc) do
      receive do
        {:work_sql, sql} -> drain_work([sql | acc])
      after
        0 -> acc
      end
    end

    for route <- [:query, :aggregate, :export, :export_unredacted] do
      test "#{route}: a denied and an absent request of the same shape do the same gate work (primary, direct, far, through)",
           %{ctx: ctx} do
        route = unquote(route)

        for %{label: label, restrict: restrict, denied: denied, absent: absent, kind: :hidden} <-
              cases() do
          set_type_restrictions!(ctx, [restrict])

          # warm-up: first request of a route may populate caches
          send_route(ctx, route, denied)
          send_route(ctx, route, absent)

          {d_conn, d_work} = gate_work(fn -> send_route(ctx, route, denied) end)
          {a_conn, a_work} = gate_work(fn -> send_route(ctx, route, absent) end)

          assert_not_found_shape(route, d_conn)
          assert_not_found_shape(route, a_conn)

          {restriction_reads, existence_reads} = d_work
          assert restriction_reads >= 1, "#{label}: no denied-set read observed"
          assert existence_reads >= 1, "#{label}: no existence read observed"
          assert {label, d_work} == {label, a_work}
        end
      end
    end

    test "every distinct type gets an existence read even when the first one is denied (no short-circuit)",
         %{
           ctx: ctx
         } do
      set_type_restrictions!(ctx, ["p_ent"])

      # types: p_ent (denied), j_ent, t_ent, f_ent -> 4 existence reads
      body = {"p_ent", [j("j_ent", "j_p_fk"), th("f_ent", "t_ent", "t_f_fk")]}
      {conn, {1, reads}} = gate_work(fn -> send_route(ctx, :aggregate, body) end)
      assert conn.status == 404
      assert reads == 4
    end
  end
end
