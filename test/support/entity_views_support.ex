defmodule Letflow.EntityViewsSupport do
  @moduledoc """
  Fixtures shared by the saved-view tests (REQ-555): a provisioned tenant, users with a token each,
  an active `answer_option` entity type (restricted fields seeded by `Exam.on_install/2`, exactly as
  production does), and the HTTP helpers. Tests only; no model call.
  """

  import Plug.Conn
  import Plug.Test

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Records
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.Modules.Exam
  alias Letflow.Repo
  alias Letflow.TenantFixture

  @volatile_headers ~w(x-trace-id)

  @doc "A provisioned tenant with the event types seeded."
  def tenant!(slug_prefix) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)
    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)

    %{tenant_id: tenant.tenant_id, schema_name: tenant.schema_name, slug: tenant.tenant.slug}
  end

  @doc "A user of the tenant with one bearer token carrying `roles`; merged into the tenant map."
  def add_user!(ctx, roles) do
    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "views-#{Ecto.UUID.generate()}",
        display_name: "Views Test User",
        email: "views-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: ctx.schema_name)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: ctx.schema_name)

    Map.merge(ctx, %{plaintext: plaintext, user_id: user.id})
  end

  @doc "Creates and activates the `answer_option` type, restricts its sensitive fields, seeds rows."
  def answer_option!(ctx) do
    definition = %{
      name: "answer_option",
      display_name: "Answer Option",
      fields: [
        %{name: "question_id", type: :string, queried: true},
        %{name: "text", type: :string, queried: true},
        %{name: "is_correct", type: :boolean, queried: true},
        %{
          name: "score",
          type: :decimal,
          decimal_strict: true,
          decimal_precision: 5,
          decimal_scale: 2,
          queried: true
        },
        %{
          name: "likert_weight",
          type: :decimal,
          decimal_precision: 5,
          decimal_scale: 2,
          queried: false
        }
      ]
    }

    {:ok, entity_definition} =
      Letflow.ManagedTypesSupport.create_definition(
        %{definition: definition, created_by: ctx.user_id},
        ctx.schema_name
      )

    {:ok, _} =
      Definitions.activate_definition(
        entity_definition.name,
        ctx.user_id,
        "views go-live",
        ctx.schema_name
      )

    :ok = Exam.on_install(ctx.schema_name, %{})

    for text <- ["A", "B", "C"] do
      {:ok, _} =
        Records.create_record(
          %{
            entity_type: "answer_option",
            field_values: %{
              "question_id" => Ecto.UUID.generate(),
              "text" => text,
              "is_correct" => text == "A"
            },
            actor_id: ctx.user_id,
            idempotency_key: Ecto.UUID.generate()
          },
          ctx.schema_name
        )
    end

    ctx
  end

  @doc "Restricts the type for everyone without a `user_entity_type_grants` row."
  def restrict_type!(ctx, type) do
    Repo.insert_all(
      "entity_type_restrictions",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          entity_type: type,
          inserted_at: NaiveDateTime.utc_now(),
          updated_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: ctx.schema_name
    )
  end

  def request(method, path, ctx, body \\ nil) do
    payload = if body == nil, do: "", else: Jason.encode!(body)

    conn(method, path, payload)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  def body_of(conn), do: Jason.decode!(conn.resp_body)

  @doc "Status, stable headers and raw body without the per-request trace id."
  def norm(conn) do
    headers =
      conn.resp_headers
      |> Enum.reject(fn {name, _} -> name in @volatile_headers end)
      |> Enum.sort()

    body =
      case Jason.decode(conn.resp_body) do
        {:ok, %{} = map} -> map |> Map.delete("trace_id") |> Jason.encode!()
        _ -> conn.resp_body
      end

    {conn.status, headers, body}
  end

  def valid_view(overrides \\ %{}) do
    Map.merge(
      %{
        "entity_type" => "answer_option",
        "name" => "Correct first",
        "columns" => ["text", "is_correct"],
        "filter" => [%{"field" => "text", "op" => "neq", "value" => "Z"}],
        "sort" => [%{"field" => "text", "dir" => "asc"}]
      },
      overrides
    )
  end

  @doc "A valid pivot body over `answer_option` (REQ-598): count and max by question_id."
  def pivot_view(overrides \\ %{}) do
    Map.merge(
      %{
        "entity_type" => "answer_option",
        "name" => "Options by correctness",
        "kind" => "pivot",
        "filter" => [%{"field" => "text", "op" => "neq", "value" => "Z"}],
        "group_by" => [%{"field" => "question_id"}],
        "aggregates" => [%{"fn" => "count"}, %{"fn" => "max", "field" => "text"}]
      },
      overrides
    )
  end

  def view_count(ctx), do: Repo.aggregate("entity_views", :count, prefix: ctx.schema_name)

  def audit_count(ctx, action) do
    import Ecto.Query, only: [from: 2]

    from(e in Letflow.Audit.Entry, where: e.action == ^action)
    |> Repo.aggregate(:count, prefix: ctx.schema_name)
  end
end
