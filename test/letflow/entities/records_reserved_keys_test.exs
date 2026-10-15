defmodule Letflow.Entities.RecordsReservedKeysTest do
  @moduledoc """
  GH #2587 / REQ-499 PR A2 (design `lib/letflow/design/gh2587-req499-pr-a-prerequisites.md`
  D-A2.1, D-A2.2, D-A2.4, section 11 A2 row "sys:step: (a), source (b), #2550 regression"):

    * (a) the single-command entry points (`create_record`, `update_record`, `delete_record`, `/2`
      and `/3`) refuse a raw `"sys:step:"` idempotency key with `{:error,
      :reserved_idempotency_key}` before any query; other server key families and a different
      case still write; `Records.command_multi/3` is the one Records path that accepts the
      family.
    * (b) a top-level `source` / `metadata` attribute is `{:error, :reserved_attribute}` before
      any query; a record FIELD named `source` is unaffected.
    * #2550 regression over HTTP: a client `sys:step:` key is stored namespaced; DELETE and
      import store server-built keys that never start `sys:`.

  `async: false`: tenant provisioning switches the sandbox to `:auto`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Ecto.Multi
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Entities.Records
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.IdempotencyRecord
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.TenantFixture

  @type_name "rk_widget"

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2587-rk")
    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)
    user = insert_user!(tenant.schema_name)

    {:ok, _} =
      Definitions.create_definition(
        %{
          definition: %{
            name: @type_name,
            display_name: "RK Widget",
            fields: [
              %{name: "title", type: :string, required: true},
              %{name: "source", type: :string}
            ]
          },
          created_by: user.id
        },
        tenant.schema_name
      )

    {:ok, _} = Definitions.activate_definition(@type_name, user.id, "gh2587", tenant.schema_name)

    {:ok, schema: tenant.schema_name, tenant_id: tenant.tenant_id, user_id: user.id}
  end

  # ── helpers ─────────────────────────────────────────────────────────────────────────────────

  defp insert_user!(schema_name) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "gh2587-user-#{Ecto.UUID.generate()}",
      display_name: "GH-2587 User",
      email: "gh2587-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema_name)
  end

  defp create_attrs(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        entity_type: @type_name,
        field_values: %{"title" => "t"},
        actor_id: ctx.user_id,
        idempotency_key: Ecto.UUID.generate()
      },
      overrides
    )
  end

  defp update_attrs(ctx, record_id, overrides) do
    ctx |> create_attrs(overrides) |> Map.put_new(:record_id, record_id)
  end

  defp delete_attrs(ctx, record_id, overrides) do
    ctx |> update_attrs(record_id, overrides) |> Map.delete(:field_values)
  end

  defp seed_record!(ctx) do
    {:ok, %{record: record}} = Records.create_record(create_attrs(ctx), ctx.schema)
    record
  end

  defp counts(schema) do
    {Repo.aggregate(Event, :count, prefix: schema),
     Repo.aggregate(IdempotencyRecord, :count, prefix: schema),
     Repo.aggregate(Latest, :count, prefix: schema)}
  end

  # Every single-command entry point, /2 and /3 (:tenant), with the given attrs overrides.
  defp all_commands(ctx, record_id, overrides) do
    [
      {"create/2", fn -> Records.create_record(create_attrs(ctx, overrides), ctx.schema) end},
      {"create/3",
       fn -> Records.create_record(create_attrs(ctx, overrides), ctx.schema, :tenant) end},
      {"update/2",
       fn -> Records.update_record(update_attrs(ctx, record_id, overrides), ctx.schema) end},
      {"update/3",
       fn ->
         Records.update_record(update_attrs(ctx, record_id, overrides), ctx.schema, :tenant)
       end},
      {"delete/2",
       fn -> Records.delete_record(delete_attrs(ctx, record_id, overrides), ctx.schema) end},
      {"delete/3",
       fn ->
         Records.delete_record(delete_attrs(ctx, record_id, overrides), ctx.schema, :tenant)
       end}
    ]
  end

  defp assert_refused_without_query(ctx, overrides, expected) do
    record = seed_record!(ctx)
    before = counts(ctx.schema)

    for {label, fun} <- all_commands(ctx, record.record_id, overrides) do
      {result, queries} = PlatformTenantFixture.capture_repo_queries(fun)
      assert result == expected, "#{label}: #{inspect(result)}"
      assert queries == [], "#{label} issued #{length(queries)} queries"
    end

    assert counts(ctx.schema) == before
  end

  # ── (a) sys:step: ───────────────────────────────────────────────────────────────────────────

  describe "(a) a raw sys:step: key on the single-command entry points" do
    test "positive control: a successful create_record issues queries, so the zero-query asserts bite",
         ctx do
      {result, queries} =
        PlatformTenantFixture.capture_repo_queries(fn ->
          Records.create_record(create_attrs(ctx), ctx.schema)
        end)

      assert {:ok, %{is_duplicate: false}} = result
      assert queries != []
    end

    test "is :reserved_idempotency_key on all six, with zero queries and nothing written", ctx do
      assert_refused_without_query(
        ctx,
        %{idempotency_key: "sys:step:abc:0"},
        {:error, :reserved_idempotency_key}
      )

      assert Repo.all(
               from(i in IdempotencyRecord, where: like(i.idempotency_key, "sys:step:%")),
               prefix: ctx.schema
             ) == []
    end

    test "other server families, a bare UUID and another case still write", ctx do
      for key <- [
            "certificate:issue:#{Ecto.UUID.generate()}",
            "entities-record-import:#{Ecto.UUID.generate()}",
            "req345-seed-#{Ecto.UUID.generate()}",
            Ecto.UUID.generate(),
            "SYS:STEP:x",
            "sys:stepx"
          ] do
        assert {:ok, %{is_duplicate: false}} =
                 Records.create_record(create_attrs(ctx, %{idempotency_key: key}), ctx.schema),
               key
      end
    end

    test "command_multi/3 is the Records path that accepts the family (StepWrites stand-in)",
         ctx do
      {:ok, _} = EntityTypeInstance.get_or_create(@type_name, ctx.schema)
      task_id = Ecto.UUID.generate()
      key = Records.step_key_prefix() <> "#{task_id}:0"

      command = %{
        kind: :create,
        line_key: 0,
        entity_type: @type_name,
        field_values: %{"title" => "from a step"},
        actor_id: ctx.user_id,
        idempotency_key: key,
        source: %{
          kind: "process_step",
          instance_id: Ecto.UUID.generate(),
          task_id: task_id,
          node_id: "n",
          definition_id: Ecto.UUID.generate(),
          definition_version: 1,
          line_index: 0,
          activator_id: ctx.user_id
        }
      }

      assert {:ok, multi} = Records.command_multi(command, ctx.schema, :tenant)
      assert {:ok, _changes} = Repo.transaction(Multi.append(Multi.new(), multi))

      assert [%Event{event_type: "ENTITY_RECORD_CREATED"}] =
               Repo.all(from(e in Event, where: e.idempotency_key == ^key), prefix: ctx.schema)
    end
  end

  # ── (b) source / metadata ───────────────────────────────────────────────────────────────────

  describe "(b) a top-level source or metadata attribute" do
    test "is :reserved_attribute on all six, with zero queries and nothing written", ctx do
      for overrides <- [
            %{source: %{}},
            %{"source" => "x"},
            %{metadata: %{"source" => "y"}},
            %{"metadata" => %{}}
          ] do
        assert_refused_without_query(ctx, overrides, {:error, :reserved_attribute})
      end
    end

    test "a record FIELD named source writes normally", ctx do
      assert {:ok, %{record: %Latest{field_values: %{"source" => "manual"}}}} =
               Records.create_record(
                 create_attrs(ctx, %{field_values: %{"title" => "t", "source" => "manual"}}),
                 ctx.schema
               )
    end
  end

  # ── #2550 regression over HTTP ──────────────────────────────────────────────────────────────

  defp request(method, path, ctx, body) do
    conn =
      case body do
        nil ->
          conn(method, path)

        body ->
          method
          |> conn(path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
      end

    conn
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> Letflow.Router.call(Letflow.Router.init([]))
  end

  defp keys_of(schema, event_type) do
    Repo.all(
      from(e in Event, where: e.event_type == ^event_type, select: e.idempotency_key),
      prefix: schema
    )
  end

  describe "#2550 regression over HTTP" do
    setup ctx do
      {:ok, %{plaintext: plaintext}} =
        Identity.create_token(ctx.user_id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
          prefix: ctx.schema
        )

      {:ok, plaintext: plaintext, slug: Repo.get!(Tenant, ctx.tenant_id).slug}
    end

    test "POST and PUT with a sys:step: body key are stored as client:rec:<actor>:<key>", ctx do
      path = "/api/v1/entities/records/#{@type_name}"

      post =
        request(:post, path, ctx, %{
          "field_values" => %{"title" => "p"},
          "idempotency_key" => "sys:step:abc:0"
        })

      assert post.status == 201
      record_id = Jason.decode!(post.resp_body)["record_id"]

      put =
        request(:put, "#{path}/#{record_id}", ctx, %{
          "field_values" => %{"title" => "q"},
          "idempotency_key" => "sys:step:abc:1"
        })

      assert put.status == 200

      assert keys_of(ctx.schema, "ENTITY_RECORD_CREATED") == [
               "client:rec:#{ctx.user_id}:sys:step:abc:0"
             ]

      assert keys_of(ctx.schema, "ENTITY_RECORD_UPDATED") == [
               "client:rec:#{ctx.user_id}:sys:step:abc:1"
             ]
    end

    test "DELETE and import store server-built keys that never start with sys:", ctx do
      record = seed_record!(ctx)

      delete =
        request(:delete, "/api/v1/entities/records/#{@type_name}/#{record.record_id}", ctx, nil)

      assert delete.status == 200

      import =
        request(:post, "/api/v1/entities/records/#{@type_name}/import", ctx, %{
          "record_export_schema_version" => "entities/record-export/v1",
          "entity_type" => @type_name,
          "exported_at" => "2026-10-15T00:00:00Z",
          "records" => [
            %{
              "record_id" => Ecto.UUID.generate(),
              "field_values" => %{"title" => "imported"},
              "deleted" => false
            }
          ]
        })

      assert import.status == 200

      [delete_key] = keys_of(ctx.schema, "ENTITY_RECORD_DELETED")
      import_keys = keys_of(ctx.schema, "ENTITY_RECORD_CREATED") -- [nil]

      assert {:ok, _} = Ecto.UUID.cast(delete_key)
      assert Enum.any?(import_keys, &String.starts_with?(&1, "entities-record-import:"))

      for key <- [delete_key | import_keys] do
        refute String.starts_with?(key, "sys:"), key
      end
    end
  end
end
