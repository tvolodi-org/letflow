defmodule Letflow.Definitions.EntityWritesActivatorTest do
  @moduledoc """
  GH #2587 / REQ-499 PR B1 (design `gh2587-req499-pr-b-human-task-writes.md` D-B.14, D-B.24,
  I-B11; tests B-13 recording half, B-19): the activator authority is derived from the server
  side `auth_context` and recorded on the activated row; it can never be supplied by a request.

    * B-13: activation by a principal without `:EntitiesRecordsWrite` -> 422
      `entity_writes_invalid` / `entity_write_activator_required`; with it, `activated_by`
      holds user, roles, evaluated permissions and the authorised pairs; the serialised
      definition never carries it.
    * B-19: `POST /definitions`, `PUT /definitions/:id` and `PATCH /definitions/:id` with an
      `activated_by` body key (also nested in `graph`) store NULL; only an activation sets it.

  Driven through the real `Letflow.Routers.Definitions` (dispatch helpers mirror
  `script_binding_routes_test.exs`). `async: false`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import Plug.Conn
  import Plug.Test

  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Entities.Definitions, as: EntityDefinitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Identity.User
  alias Letflow.TenantFixture

  @definitions_opts Letflow.Routers.Definitions.init([])

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2587-b1-http")
    schema = tenant.schema_name
    {:ok, _} = EventTypes.seed!(schema)

    {:ok, row} =
      EntityDefinitions.create_definition(
        %{
          definition: %{
            name: "stock_move",
            display_name: "stock_move",
            fields: [%{name: "label", type: :string}],
            writable_by_process: true,
            append_only: true
          },
          created_by: Ecto.UUID.generate()
        },
        schema
      )

    {:ok, _} = EntityDefinitions.activate_definition(row.name, Ecto.UUID.generate(), "go", schema)

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "gh2587-b1-#{Ecto.UUID.generate()}",
        display_name: "GH-2587 B1 HTTP User",
        email: "gh2587-b1-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: schema)

    %{tenant: tenant, schema: schema, user: user}
  end

  defp call(method, path, ctx, roles, body) do
    conn = conn(method, path)

    conn =
      if body,
        do: put_req_header(%{conn | body_params: body}, "content-type", "application/json"),
        else: conn

    conn
    |> assign(:auth_context, %{
      user_id: ctx.user.id,
      tenant_id: ctx.tenant.tenant_id,
      roles: roles
    })
    |> assign(:trace_id, "gh2587-b1-http")
    |> then(&Letflow.Routers.Definitions.call(&1, @definitions_opts))
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp graph(extra \\ %{}) do
    Map.merge(
      %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{
            "id" => "ht",
            "node_type" => "HUMAN_TASK",
            "attributes" => %{
              "role" => "REVIEWER",
              "entity_writes" => [
                %{
                  "op" => "create",
                  "entity_type" => "stock_move",
                  "fields" => %{"label" => %{"const" => "x"}}
                }
              ]
            }
          },
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [
          %{"id" => "e1", "source" => "start", "target" => "ht"},
          %{"id" => "e2", "source" => "ht", "target" => "end"}
        ]
      },
      extra
    )
  end

  defp create!(ctx, extra_body \\ %{}, graph \\ nil) do
    request =
      Map.merge(
        %{"name" => unique("b1"), "version" => "1", "graph" => graph || graph()},
        extra_body
      )

    resp = call(:post, "/", ctx, ["TENANT_ADMIN"], request)
    assert resp.status == 201, resp.resp_body
    body(resp)["id"]
  end

  defp stored(schema, id), do: Repo.get!(ProcessDefinition, id, prefix: schema)

  describe "B-13: authority recorded at activation" do
    test "a principal holding DefinitionsWrite but not EntitiesRecordsWrite is refused", ctx do
      id = create!(ctx)

      resp = call(:post, "/#{id}/activate", ctx, ["PROCESS_DESIGNER"], nil)

      assert resp.status == 422, resp.resp_body

      assert body(resp) == %{
               "error" => "entity_writes_invalid",
               "violations" => [
                 %{"node_id" => "ht", "index" => 0, "code" => "entity_write_activator_required"}
               ]
             }

      assert %{status: :draft, activated_by: nil} = stored(ctx.schema, id)
    end

    test "with :EntitiesRecordsWrite it activates and records the authority", ctx do
      id = create!(ctx)

      resp = call(:post, "/#{id}/activate", ctx, ["TENANT_ADMIN"], nil)
      assert resp.status == 200, resp.resp_body

      refute Map.has_key?(body(resp), "activated_by"),
             "the serialised definition never carries it"

      user_id = ctx.user.id

      assert %{
               status: :active,
               activated_by: %{
                 "user_id" => ^user_id,
                 "roles" => ["TENANT_ADMIN"],
                 "permissions" => ["DefinitionsActivate", "EntitiesRecordsWrite"],
                 "authorized" => [%{"entity_type" => "stock_move", "op" => "create"}]
               }
             } = stored(ctx.schema, id)
    end

    test "GET responses never carry activated_by", ctx do
      id = create!(ctx)
      assert call(:post, "/#{id}/activate", ctx, ["TENANT_ADMIN"], nil).status == 200

      resp = call(:get, "/#{id}", ctx, ["TENANT_ADMIN"], nil)
      assert resp.status == 200
      refute Map.has_key?(body(resp), "activated_by")
    end

    test "rollback re-records the re-activating principal's authority", ctx do
      key = unique("rb")
      v1 = create!(ctx, %{"name" => key, "version" => "1"})
      assert call(:post, "/#{v1}/activate", ctx, ["TENANT_ADMIN"], nil).status == 200

      # simulate an earlier activator: the recorded authority must be replaced, not kept
      earlier = %{"user_id" => Ecto.UUID.generate(), "roles" => ["TENANT_ADMIN"]}

      from(d in ProcessDefinition, where: d.id == ^v1)
      |> Repo.update_all([set: [activated_by: earlier]], prefix: ctx.schema)

      trivial = %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
      }

      v2 = create!(ctx, %{"name" => key, "version" => "2"}, trivial)
      assert call(:post, "/#{v2}/activate", ctx, ["TENANT_ADMIN"], nil).status == 200
      assert %{activated_by: nil} = stored(ctx.schema, v2)

      resp = call(:post, "/#{key}/rollback", ctx, ["TENANT_ADMIN"], %{"target_version" => "1"})
      assert resp.status == 200, resp.resp_body

      user_id = ctx.user.id
      assert %{status: :active, activated_by: %{"user_id" => ^user_id}} = stored(ctx.schema, v1)
      assert %{status: :deprecated} = stored(ctx.schema, v2)
    end
  end

  describe "B-19: activated_by is not forgeable (I-B11)" do
    @forged %{"user_id" => "00000000-0000-0000-0000-000000000000", "roles" => ["PLATFORM_ADMIN"]}

    # GH #2590 / REQ-501 R2 (design 4.8, labelled SCOPE EXTENSION): a top-level
    # `activated_by` body key is now refused 422 (it used to be silently dropped). A graph key
    # is part of the graph document and is still just dropped by the cast.
    test "POST /definitions refuses a body key (422) and drops a graph key", ctx do
      resp =
        call(:post, "/", ctx, ["TENANT_ADMIN"], %{
          "name" => unique("b1"),
          "version" => "1",
          "graph" => graph(),
          "activated_by" => @forged
        })

      assert resp.status == 422, resp.resp_body

      nested = create!(ctx, %{}, graph(%{"activated_by" => @forged}))
      assert %{activated_by: nil} = stored(ctx.schema, nested)
    end

    test "PUT and PATCH /definitions/:id refuse it too (R2 scope extension)", ctx do
      id = create!(ctx)

      put =
        call(:put, "/#{id}", ctx, ["TENANT_ADMIN"], %{
          "name" => unique("b1"),
          "version" => "1",
          "graph" => graph(),
          "activated_by" => @forged
        })

      assert put.status == 422, put.resp_body
      assert %{activated_by: nil} = stored(ctx.schema, id)

      patch = call(:patch, "/#{id}", ctx, ["TENANT_ADMIN"], %{"activated_by" => @forged})
      assert patch.status == 422, patch.resp_body
      assert %{activated_by: nil} = stored(ctx.schema, id)
    end

    test "the Ecto changesets do not cast it" do
      attrs = %{
        name: "n",
        version: "1",
        graph: %{"nodes" => [], "edges" => []},
        created_by: Ecto.UUID.generate(),
        activated_by: @forged
      }

      for changeset <- [
            ProcessDefinition.create_changeset(%ProcessDefinition{}, attrs),
            ProcessDefinition.update_changeset(%ProcessDefinition{}, attrs)
          ] do
        refute Map.has_key?(changeset.changes, :activated_by)
      end
    end

    test "Definitions.create/2 with the attribute in the map stores NULL", ctx do
      assert {:ok, row} =
               Letflow.Definitions.create(
                 %{
                   name: unique("b1"),
                   version: "1",
                   graph: graph(),
                   created_by: ctx.user.id,
                   activated_by: @forged
                 },
                 prefix: ctx.schema
               )

      assert %{activated_by: nil} = stored(ctx.schema, row.id)
    end
  end
end
