defmodule Letflow.Routers.InstancesRestrictedFieldEventsTest do
  @moduledoc """
  Leak reproduction (suspected, GH #2682 / req511 scope): field restrictions
  (`entity_type_restrictions`, seeded by `Exam.on_install/2`) are enforced on
  `/entities/query`, aggregate and export, but record create/update events
  carry the FULL `field_values` (`Letflow.Entities.Records.build_event_attrs/3`)
  and are appended under a synthetic per-entity-type instance
  (`Letflow.Entities.EntityTypeInstance`) that has a real `instance_projections`
  row. The instances read routes (`GET /instances`, `/instances/:id`,
  `/instances/:id/history`, `/instances/:id/timeline`, role-gated by
  `:InstancesRead`, held by TASK_WORKER and TENANT_AUDITOR among others) only
  hide the `_sys` event type.

  Every test asserts on HTTP status and on PRESENCE/ABSENCE of a restricted
  marker value; no restricted value is ever interpolated into a failure
  message. A test asserting the DESIRED behaviour that fails here = leak proven.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Records
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.Modules.Exam
  alias Letflow.TenantFixture

  # Distinctive markers: a restricted decimal and a restricted string.
  @weight_marker "7.25"
  @explanation_marker "EXPLMARK9137"

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp get_req(path, ctx) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> dispatch()
  end

  defp query(ctx, body) do
    conn(:post, "/api/v1/entities/query", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> dispatch()
  end

  defp body_of(conn), do: Jason.decode!(conn.resp_body)

  defp insert_user!(tenant) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "restricted-events-#{Ecto.UUID.generate()}",
      display_name: "Restricted Events Test User",
      email: "restricted-events-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  defp tenant_ctx(slug_prefix, roles) do
    tenant =
      TenantFixture.provisioned_tenant!(
        slug_prefix: slug_prefix,
        display_name: "Restricted Events Leak Test Tenant"
      )

    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)
    user = insert_user!(tenant)

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

  defp create_active_definition!(ctx, definition) do
    {:ok, entity_definition} =
      Letflow.ManagedTypesSupport.create_definition(
        %{definition: definition, created_by: ctx.user_id},
        ctx.schema_name
      )

    {:ok, activated} =
      Definitions.activate_definition(
        entity_definition.name,
        ctx.user_id,
        "restricted events go-live",
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

  # The real exam shapes, restricted via Exam.on_install/2 exactly as production seeds it.
  defp exam_ctx!(slug_prefix, roles) do
    ctx = tenant_ctx(slug_prefix, roles)

    create_active_definition!(ctx, %{
      name: "question",
      display_name: "Question",
      fields: [
        %{name: "stem", type: :string, queried: true},
        %{name: "explanation", type: :string, queried: false}
      ]
    })

    create_active_definition!(ctx, %{
      name: "answer_option",
      display_name: "Answer Option",
      fields: [
        %{name: "question_id", type: :string, queried: true},
        %{name: "text", type: :string, queried: true},
        %{name: "is_correct", type: :boolean, queried: true},
        %{
          name: "likert_weight",
          type: :decimal,
          decimal_precision: 5,
          decimal_scale: 2,
          queried: false
        },
        %{
          name: "likert_polarity",
          type: :enum,
          enum_values: ["positive", "negative"],
          queried: false
        }
      ]
    })

    :ok = Exam.on_install(ctx.schema_name, %{})

    question =
      seed_record!(ctx, "question", %{
        "stem" => "2 + 2 = ?",
        "explanation" => @explanation_marker
      })

    seed_record!(ctx, "answer_option", %{
      "question_id" => question.record_id,
      "text" => "A",
      "is_correct" => true,
      "likert_weight" => 7.25
    })

    ctx
  end

  defp synthetic_id!(ctx, entity_type) do
    {:ok, id} = EntityTypeInstance.fetch_instance_id(entity_type, ctx.schema_name)
    id
  end

  defp insert_user_grant!(ctx, entity_type, field_name) do
    Repo.insert_all(
      "user_entity_grants",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          user_id: Ecto.UUID.dump!(ctx.user_id),
          entity_type: entity_type,
          field_name: field_name,
          inserted_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: ctx.schema_name
    )
  end

  # Boolean-only probes: never expose the value itself.
  defp contains_marker?(conn) do
    body = conn.resp_body

    String.contains?(body, @weight_marker) or String.contains?(body, @explanation_marker)
  end

  # Does any history event payload carry a `field_values` map holding a restricted key?
  defp payload_has_restricted_key?(conn) do
    conn
    |> body_of()
    |> Map.get("items", [])
    |> Enum.any?(fn item ->
      case get_in(item, ["payload", "field_values"]) do
        %{} = fv ->
          Enum.any?(["is_correct", "likert_weight", "explanation"], &Map.has_key?(fv, &1))

        _ ->
          false
      end
    end)
  end

  defp listed_ids(conn),
    do: conn |> body_of() |> Map.get("items", []) |> Enum.map(& &1["instance_id"])

  for {label, role} <- [{"TASK_WORKER", "TASK_WORKER"}, {"TENANT_AUDITOR", "TENANT_AUDITOR"}] do
    describe "restricted caller #{label}" do
      test "(a) GET /instances does not list the synthetic entity-type instances" do
        ctx = exam_ctx!("re-list-#{unquote(String.downcase(role))}", [unquote(role)])
        answer_option_id = synthetic_id!(ctx, "answer_option")
        question_id = synthetic_id!(ctx, "question")

        conn = get_req("/api/v1/instances?page_size=100", ctx)
        assert conn.status == 200

        ids = listed_ids(conn)

        assert {answer_option_id in ids, question_id in ids} == {false, false}
      end

      test "(a2) GET /instances/:id of the synthetic instance is 404" do
        ctx = exam_ctx!("re-get-#{unquote(String.downcase(role))}", [unquote(role)])
        conn = get_req("/api/v1/instances/#{synthetic_id!(ctx, "answer_option")}", ctx)
        assert conn.status == 404
      end

      test "(b1) GET /instances/:id/history: no payload carries restricted field_values" do
        ctx = exam_ctx!("re-hist-#{unquote(String.downcase(role))}", [unquote(role)])
        id = synthetic_id!(ctx, "answer_option")

        conn = get_req("/api/v1/instances/#{id}/history?page_size=50", ctx)

        # desired: 404 (hidden) or a payload with no restricted key/value.
        leaked? =
          conn.status == 200 and (payload_has_restricted_key?(conn) or contains_marker?(conn))

        assert leaked? == false
      end

      test "(b1q) history of the synthetic `question` instance does not expose the restricted explanation" do
        ctx = exam_ctx!("re-histq-#{unquote(String.downcase(role))}", [unquote(role)])
        id = synthetic_id!(ctx, "question")

        conn = get_req("/api/v1/instances/#{id}/history?page_size=50", ctx)

        assert conn.status != 200 or not contains_marker?(conn)
      end

      test "(b2) GET /instances/:id/timeline: no restricted value in the response" do
        ctx = exam_ctx!("re-tl-#{unquote(String.downcase(role))}", [unquote(role)])
        id = synthetic_id!(ctx, "answer_option")

        conn = get_req("/api/v1/instances/#{id}/timeline?page_size=50", ctx)

        assert conn.status != 200 or not contains_marker?(conn)
      end
    end
  end

  describe "controls" do
    test "(c1) TASK_WORKER /entities/query redacts the restricted fields (passes today)" do
      ctx = exam_ctx!("re-ctl-query", ["TASK_WORKER"])

      conn = query(ctx, %{"entity_type" => "answer_option"})
      assert conn.status == 200

      items = body_of(conn)["items"]
      assert length(items) == 1

      assert Enum.all?(items, fn item ->
               fv = item["field_values"] || %{}

               fv["is_correct"] == "__field_redacted__" and
                 fv["likert_weight"] == "__field_redacted__"
             end)

      refute contains_marker?(conn)
    end

    test "(c2) a normal workflow instance's history still works (passes today)" do
      ctx = exam_ctx!("re-ctl-wf", ["TENANT_ADMIN"])

      # Any real instance route must keep working: the nonexistent-id path is 404 and the
      # synthetic id is never the only thing listed. Start from the list route.
      conn = get_req("/api/v1/instances?page_size=100", ctx)
      assert conn.status == 200

      bogus = Ecto.UUID.generate()
      assert get_req("/api/v1/instances/#{bogus}/history", ctx).status == 404
      assert get_req("/api/v1/instances/#{bogus}/timeline", ctx).status == 404
    end

    test "(c3) a caller holding a user_entity_grants row may see the field via /entities/query" do
      ctx = exam_ctx!("re-ctl-grant", ["TASK_WORKER"])
      insert_user_grant!(ctx, "answer_option", "is_correct")

      conn = query(ctx, %{"entity_type" => "answer_option"})
      assert conn.status == 200

      [item] = body_of(conn)["items"]
      assert (item["field_values"] || %{})["is_correct"] == true
    end
  end
end
