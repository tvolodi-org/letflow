defmodule Letflow.Routers.EntitiesDecimalStrictTest do
  @moduledoc """
  GH #2654 PR-1 -- HTTP-level tests for `decimal_strict` decimal fields
  (`lib/letflow/design/gh2654-decimal-exact-strings.md`, decision 0060).
  Full pipeline (`Letflow.Router.call/2`, real API-token bearer), like
  `Letflow.Routers.EntitiesTest`.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.TenantFixture

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp request(method, path, ctx, body \\ nil) do
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

  defp tenant_ctx(slug_prefix) do
    tenant =
      TenantFixture.provisioned_tenant!(
        slug_prefix: slug_prefix,
        display_name: "GH-2654 decimal strict test tenant"
      )

    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "gh2654-user-#{Ecto.UUID.generate()}",
        display_name: "GH-2654 test user",
        email: "gh2654-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: tenant.schema_name)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
        prefix: tenant.schema_name
      )

    %{
      schema_name: tenant.schema_name,
      slug: tenant.tenant.slug,
      plaintext: plaintext,
      user_id: user.id
    }
  end

  defp seed_active!(ctx, name, fields) do
    {:ok, _} =
      Definitions.create_definition(
        %{
          definition: %{name: name, display_name: String.capitalize(name), fields: fields},
          created_by: ctx.user_id
        },
        ctx.schema_name
      )

    {:ok, activated} =
      Definitions.activate_definition(name, ctx.user_id, "test go-live", ctx.schema_name)

    activated
  end

  defp body_of(conn), do: Jason.decode!(conn.resp_body)

  defp strict_field,
    do: %{
      name: "qty",
      type: :decimal,
      decimal_precision: 10,
      decimal_scale: 2,
      decimal_strict: true
    }

  defp strict_body(name, overrides \\ %{}) do
    %{
      "name" => name,
      "display_name" => String.capitalize(name),
      "fields" => [
        Map.merge(
          %{
            "name" => "qty",
            "type" => "decimal",
            "decimal_precision" => 10,
            "decimal_scale" => 2,
            "decimal_strict" => true
          },
          overrides
        )
      ]
    }
  end

  defp post_record(ctx, type, field_values),
    do: request(:post, "/api/v1/entities/records/#{type}", ctx, %{"field_values" => field_values})

  describe "T0 -- the legacy (non-strict) field, as reproduced on main before the change" do
    # Recorded on unmodified origin/main c10f95c7:
    #   "2.50" -> 422 {"errors":[{"code":"type","message":"/qty violates type","path":"/qty"}], ...}
    #   2.5    -> 201 field_values {"qty":2.5}
    #   2.505  -> 201 field_values {"qty":2.505}   (scale 2 not enforced)
    test "a decimal field WITHOUT the flag still refuses the string, takes the number, ignores the scale" do
      ctx = tenant_ctx("gh2654-t0")

      seed_active!(ctx, "widget", [
        %{name: "qty", type: :decimal, decimal_precision: 10, decimal_scale: 2}
      ])

      string = post_record(ctx, "widget", %{"qty" => "2.50"})
      assert string.status == 422
      assert [%{"code" => "type", "path" => "/qty"}] = body_of(string)["errors"]

      number = post_record(ctx, "widget", %{"qty" => 2.5})
      assert number.status == 201
      assert body_of(number)["field_values"] == %{"qty" => 2.5}

      scale = post_record(ctx, "widget", %{"qty" => 2.505})
      assert scale.status == 201
      assert body_of(scale)["field_values"] == %{"qty" => 2.505}
    end
  end

  describe "strict field over HTTP (T1, T2, T4, T10)" do
    test "definition create -> GET -> activate keeps decimal_strict, then writes are exact strings" do
      ctx = tenant_ctx("gh2654-http")

      created = request(:post, "/api/v1/entities/definitions", ctx, strict_body("gadget"))
      assert created.status == 201
      assert [%{"decimal_strict" => true}] = body_of(created)["definition"]["fields"]

      assert request(:post, "/api/v1/entities/definitions/gadget/activate", ctx, %{
               "rationale" => "go"
             }).status ==
               200

      active = request(:get, "/api/v1/entities/definitions/active/gadget", ctx)
      assert [%{"decimal_strict" => true}] = body_of(active)["definition"]["fields"]

      ok = post_record(ctx, "gadget", %{"qty" => "2.5"})
      assert ok.status == 201
      assert body_of(ok)["field_values"] == %{"qty" => "2.50"}

      float = post_record(ctx, "gadget", %{"qty" => 2.5})
      assert float.status == 422
      assert [%{"code" => "type", "path" => "/qty"}] = body_of(float)["errors"]

      scale = post_record(ctx, "gadget", %{"qty" => "2.505"})
      assert scale.status == 422

      assert [%{"code" => "scale", "path" => "/qty", "message" => "/qty violates scale"}] =
               body_of(scale)["errors"]

      precision = post_record(ctx, "gadget", %{"qty" => "123456789.12"})
      assert [%{"code" => "precision", "path" => "/qty"}] = body_of(precision)["errors"]
    end

    test "an invalid decimal_strict is a definition 422 and a non-boolean never reaches storage" do
      ctx = tenant_ctx("gh2654-badflag")

      conn =
        request(
          :post,
          "/api/v1/entities/definitions",
          ctx,
          strict_body("w", %{"decimal_strict" => "yes"})
        )

      assert conn.status == 422

      conn =
        request(
          :post,
          "/api/v1/entities/definitions",
          ctx,
          strict_body("w", %{"min" => "1", "max" => "0.5"})
        )

      assert conn.status == 422

      conn =
        request(
          :post,
          "/api/v1/entities/definitions",
          ctx,
          strict_body("w", %{"decimal_strict" => false, "min" => "0.5"})
        )

      assert conn.status == 422
    end
  end

  describe "immutability gate over HTTP (A1)" do
    test "flipping the flag with records is a 409 naming the field, no value; allowed on an empty type" do
      ctx = tenant_ctx("gh2654-409")

      seed_active!(ctx, "widget", [
        %{
          name: "qty",
          type: :decimal,
          decimal_precision: 10,
          decimal_scale: 2,
          decimal_strict: false
        }
      ])

      assert post_record(ctx, "widget", %{"qty" => 123.45}).status == 201

      flipped = request(:post, "/api/v1/entities/definitions", ctx, strict_body("widget"))
      assert flipped.status == 201

      conn =
        request(:post, "/api/v1/entities/definitions/widget/activate", ctx, %{
          "rationale" => "flip"
        })

      assert conn.status == 409
      body = body_of(conn)
      assert body["detail"] == "decimal_strict cannot change while records exist: qty"
      refute conn.resp_body =~ "123.45"

      # still the old definition
      active = request(:get, "/api/v1/entities/definitions/active/widget", ctx)
      assert [%{"decimal_strict" => false}] = body_of(active)["definition"]["fields"]

      # an empty type may flip
      seed_active!(ctx, "empty_one", [
        %{
          name: "qty",
          type: :decimal,
          decimal_precision: 10,
          decimal_scale: 2,
          decimal_strict: false
        }
      ])

      assert request(:post, "/api/v1/entities/definitions", ctx, strict_body("empty_one")).status ==
               201

      assert request(:post, "/api/v1/entities/definitions/empty_one/activate", ctx, %{
               "rationale" => "flip"
             }).status ==
               200
    end
  end

  describe "strict integer over HTTP (T10)" do
    test "a JSON integer is stored and returned as the padded string; a negative one keeps its sign" do
      ctx = tenant_ctx("gh2654-int")
      seed_active!(ctx, "gadget", [strict_field()])

      assert body_of(post_record(ctx, "gadget", %{"qty" => 3}))["field_values"] == %{
               "qty" => "3.00"
             }

      assert body_of(post_record(ctx, "gadget", %{"qty" => -3}))["field_values"] == %{
               "qty" => "-3.00"
             }
    end
  end

  describe "{:definition_changed, _} over HTTP (T2)" do
    @handler "gh2654-http-recheck"

    # After the writer's type-sequence-lock statement, activate a NEW version inside the
    # writer's own transaction (the Plug call runs in the test process), so the recheck
    # must refuse and the activation rolls back with the writer's transaction.
    defp activate_after_sequence_lock!(ctx, name) do
      parent = self()
      once = :atomics.new(1, [])

      :telemetry.attach(
        @handler,
        [:letflow, :repo, :query],
        fn _event, _measurements, %{query: query}, _config ->
          if self() == parent and String.contains?(query, "\"instance_sequence\" AS") and
               String.contains?(query, "FOR UPDATE") and :atomics.add_get(once, 1, 1) == 1 do
            {:ok, _} =
              Definitions.activate_definition(name, ctx.user_id, "concurrent", ctx.schema_name)
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(@handler) end)
    end

    defp new_version!(ctx, name, extra_field_name) do
      {:ok, _} =
        Definitions.create_definition(
          %{
            definition: %{
              name: name,
              display_name: name,
              fields: [%{name: "title", type: :string}, %{name: extra_field_name, type: :string}]
            },
            created_by: ctx.user_id
          },
          ctx.schema_name
        )
    end

    defp seed_title!(ctx),
      do: seed_active!(ctx, "widget", [%{name: "title", type: :string}])

    @body "entity definition changed during the write; retry"

    test "create, update and delete answer the constant 409 and append nothing" do
      ctx = tenant_ctx("gh2654-409w")
      seed_title!(ctx)
      created = body_of(post_record(ctx, "widget", %{"title" => "x"}))
      id = created["record_id"]

      new_version!(ctx, "widget", "extra1")
      activate_after_sequence_lock!(ctx, "widget")
      conn = post_record(ctx, "widget", %{"title" => "y"})
      assert conn.status == 409
      assert body_of(conn)["detail"] == @body
      :telemetry.detach(@handler)

      new_version!(ctx, "widget", "extra2")
      activate_after_sequence_lock!(ctx, "widget")

      conn =
        request(:put, "/api/v1/entities/records/widget/#{id}", ctx, %{
          "field_values" => %{"title" => "z"}
        })

      assert conn.status == 409
      assert body_of(conn)["detail"] == @body
      :telemetry.detach(@handler)

      new_version!(ctx, "widget", "extra3")
      activate_after_sequence_lock!(ctx, "widget")
      conn = request(:delete, "/api/v1/entities/records/widget/#{id}", ctx)
      assert conn.status == 409
      assert body_of(conn)["detail"] == @body
      :telemetry.detach(@handler)

      # nothing was appended by the three refused writes
      assert {:ok, %{field_values: %{"title" => "x"}, deleted: false}} =
               Letflow.Entities.Record.Latest.get(id, "widget", ctx.schema_name)
    end

    test "a bulk-import entry that overlaps an activation reports the constant reason" do
      ctx = tenant_ctx("gh2654-409i")
      seed_title!(ctx)
      new_version!(ctx, "widget", "extra1")
      activate_after_sequence_lock!(ctx, "widget")

      conn =
        request(:post, "/api/v1/entities/records/widget/import", ctx, %{
          "record_export_schema_version" => "entities/record-export/v1",
          "entity_type" => "widget",
          "records" => [%{"record_id" => "src-1", "field_values" => %{"title" => "a"}}]
        })

      assert conn.status == 200

      assert [%{"status" => "error", "reason" => %{"type" => "definition_changed"}}] =
               body_of(conn)["results"]
    end
  end
end
