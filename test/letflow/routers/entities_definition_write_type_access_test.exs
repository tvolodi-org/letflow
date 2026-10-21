defmodule Letflow.Routers.EntitiesDefinitionWriteTypeAccessTest do
  @moduledoc """
  GH #2808 (design: task note, sections 3.1-3.3 and 5): TypeAccess on the entity-definition
  write routes and the restrictions import.

    * R1 `POST /entities/definitions/:name/activate`: a type denied to the caller answers
      byte-identically to an ABSENT name (404, after the same validation), writes nothing; an
      allowed caller is unchanged.
    * R2 `POST /entities/definitions`: "denied equals absent" is impossible (an absent name
      answers 201), so a denied name answers the constant permission-403 bytes; no row written.
    * R3 `POST /entities/restrictions/import`: any denied type named by any row is the same
      constant 403 with ZERO rows written, before row validation; self-grant is blocked.

  Full pipeline (`Letflow.Router.call/2`, real bearer token), real Postgres.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Letflow.Entities.DefinitionAccess
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Restrictions
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.TenantFixture
  alias Letflow.Test.SandboxAutoMode

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)
    :ok
  end

  # ---- helpers -------------------------------------------------------------------------------

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp request(method, path, ctx, body, token \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        {:raw, raw} ->
          conn(method, path, raw) |> put_req_header("content-type", "application/json")

        body ->
          conn(method, path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json")
      end

    conn
    |> put_req_header("authorization", "Bearer " <> (token || ctx.plaintext))
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> dispatch()
  end

  defp tenant_ctx(slug_prefix) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)
    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)
    user = insert_user!(tenant.schema_name)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
        prefix: tenant.schema_name
      )

    {:ok, %{plaintext: auditor_token}} =
      Identity.create_token(user.id, %{roles: ["TENANT_AUDITOR"], expires_at: nil},
        prefix: tenant.schema_name
      )

    %{
      schema_name: tenant.schema_name,
      slug: tenant.tenant.slug,
      plaintext: plaintext,
      auditor_token: auditor_token,
      user_id: user.id
    }
  end

  defp insert_user!(schema) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "gh2808-user-#{Ecto.UUID.generate()}",
      display_name: "GH-2808 test user",
      email: "gh2808-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema)
  end

  defp definition(name),
    do: %{name: name, display_name: name, fields: [%{name: "title", type: :string}]}

  defp seed_type!(ctx, name, activate? \\ true) do
    {:ok, _} =
      Definitions.create_definition(
        %{definition: definition(name), created_by: ctx.user_id},
        ctx.schema_name
      )

    if activate?,
      do: {:ok, _} = Definitions.activate_definition(name, ctx.user_id, "seed", ctx.schema_name)

    :ok
  end

  defp restrict!(ctx, type) do
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

  defp grant!(ctx, type, user_id \\ nil) do
    Repo.insert_all(
      "user_entity_type_grants",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          user_id: Ecto.UUID.dump!(user_id || ctx.user_id),
          entity_type: type,
          inserted_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: ctx.schema_name
    )
  end

  defp norm(conn) do
    headers =
      conn.resp_headers
      |> Enum.reject(fn {name, _} -> name =~ ~r/id|trace|date|time/ end)
      |> Enum.sort()

    {conn.status, headers, conn.resp_body |> Jason.decode!() |> Map.delete("trace_id")}
  end

  defp def_counts(ctx) do
    for table <- ~w(entity_definitions artifact_versions repository_artifacts), into: %{} do
      {table, Repo.aggregate(table, :count, prefix: ctx.schema_name)}
    end
  end

  defp restriction_counts(ctx) do
    for table <-
          ~w(entity_field_restrictions user_entity_grants entity_type_restrictions user_entity_type_grants),
        into: %{} do
      {table, Repo.aggregate(table, :count, prefix: ctx.schema_name)}
    end
  end

  defp activate(ctx, name, body \\ %{"rationale" => "because"}, token \\ nil),
    do: request(:post, "/api/v1/entities/definitions/#{name}/activate", ctx, body, token)

  defp create(ctx, name, token \\ nil),
    do: request(:post, "/api/v1/entities/definitions", ctx, create_body(name), token)

  defp create_body(name) do
    %{
      "name" => name,
      "display_name" => name,
      "fields" => [%{"name" => "title", "type" => "string"}]
    }
  end

  defp import_rows(ctx, body, token \\ nil),
    do: request(:post, "/api/v1/entities/restrictions/import", ctx, body, token)

  # ---- R1 activate ---------------------------------------------------------------------------

  describe "R1 activate" do
    test "denied name is byte-identical to an absent name, for every body shape" do
      ctx = tenant_ctx("gh2808-r1a")
      other = tenant_ctx("gh2808-r1b")
      seed_type!(ctx, "secret_x", false)
      restrict!(ctx, "secret_x")

      bodies = [
        %{"rationale" => "because"},
        {:raw, "[1,2]"},
        %{},
        %{"rationale" => "   "}
      ]

      for body <- bodies do
        denied = activate(ctx, "secret_x", body)
        absent_same_tenant = activate(ctx, "never_existed", body)
        absent_other_tenant = activate(other, "secret_x", body)
        assert norm(denied) == norm(absent_same_tenant)
        assert norm(denied) == norm(absent_other_tenant)
      end

      assert {404, _, _} = norm(activate(ctx, "secret_x"))
    end

    test "a denied activation changes nothing; a granted caller activates" do
      ctx = tenant_ctx("gh2808-r1c")
      seed_type!(ctx, "secret_y", false)
      restrict!(ctx, "secret_y")
      before = def_counts(ctx)

      assert {404, _, _} = norm(activate(ctx, "secret_y"))
      assert def_counts(ctx) == before
      assert {:error, _} = Definitions.get_active_definition_by_name("secret_y", ctx.schema_name)

      grant!(ctx, "secret_y")
      assert {200, _, _} = norm(activate(ctx, "secret_y"))
      assert {:ok, _} = Definitions.get_active_definition_by_name("secret_y", ctx.schema_name)
    end

    test "an unrestricted type and unrelated restriction rows leave activation unchanged" do
      ctx = tenant_ctx("gh2808-r1d")
      seed_type!(ctx, "plain_t", false)
      seed_type!(ctx, "other_t")
      restrict!(ctx, "other_t")
      assert {200, _, body} = norm(activate(ctx, "plain_t"))
      assert body["name"] == "plain_t"
    end

    test "DefinitionAccess.activate/3 decisions" do
      ctx = tenant_ctx("gh2808-r1e")
      seed_type!(ctx, "dx")
      assert DefinitionAccess.activate(ctx.user_id, "dx", ctx.schema_name) == :open
      restrict!(ctx, "dx")
      assert DefinitionAccess.activate(ctx.user_id, "dx", ctx.schema_name) == :hidden
      assert DefinitionAccess.activate(ctx.user_id, "absent", ctx.schema_name) == :open
      assert DefinitionAccess.activate(ctx.user_id, "dx", "not_a_tenant_schema") == :hidden
      grant!(ctx, "dx")
      assert DefinitionAccess.activate(ctx.user_id, "dx", ctx.schema_name) == :open
    end
  end

  # ---- R2 create -----------------------------------------------------------------------------

  describe "R2 create" do
    test "denied name is the permission-403 bytes and writes nothing" do
      ctx = tenant_ctx("gh2808-r2a")
      seed_type!(ctx, "locked_t")
      restrict!(ctx, "locked_t")
      before = def_counts(ctx)

      denied = norm(create(ctx, "locked_t"))
      lacking = norm(create(ctx, "locked_t", ctx.auditor_token))
      assert {403, _, %{"detail" => "insufficient permissions"}} = denied
      assert denied == lacking
      assert def_counts(ctx) == before

      # schema-invalid body: the check precedes validation
      invalid = request(:post, "/api/v1/entities/definitions", ctx, %{"name" => "locked_t"})
      assert norm(invalid) == denied
      assert def_counts(ctx) == before
    end

    test "a restriction row alone (no definition) is also refused, no existence signal" do
      ctx = tenant_ctx("gh2808-r2b")
      restrict!(ctx, "ghost_t")
      assert {403, _, _} = norm(create(ctx, "ghost_t"))
      assert Repo.aggregate("entity_definitions", :count, prefix: ctx.schema_name) == 0
    end

    test "allowed callers are unchanged; malformed and nameless bodies keep their answers" do
      ctx = tenant_ctx("gh2808-r2c")
      assert {201, _, _} = norm(create(ctx, "free_t"))
      restrict!(ctx, "gated_t")
      grant!(ctx, "gated_t")
      assert {201, _, _} = norm(create(ctx, "gated_t"))

      assert {400, _, _} =
               norm(request(:post, "/api/v1/entities/definitions", ctx, {:raw, "[1]"}))

      assert {422, _, _} =
               norm(request(:post, "/api/v1/entities/definitions", ctx, %{"display_name" => "x"}))
    end

    test "a managed_by body is refused whether the name is denied or not" do
      ctx = tenant_ctx("gh2808-r2d")
      restrict!(ctx, "mgd_t")
      body = Map.put(create_body("mgd_t"), "managed_by", "some-module")

      assert {403, _, %{"detail" => "insufficient permissions"}} =
               norm(request(:post, "/api/v1/entities/definitions", ctx, body))

      open = Map.put(create_body("open_t"), "managed_by", "some-module")
      assert {403, _, detail} = norm(request(:post, "/api/v1/entities/definitions", ctx, open))
      refute detail["detail"] == "insufficient permissions"
    end
  end

  # ---- R3 restrictions import ----------------------------------------------------------------

  describe "R3 restrictions import" do
    test "a denied type in any of the four lists is a constant 403 and writes nothing" do
      ctx = tenant_ctx("gh2808-r3a")
      restrict!(ctx, "locked_r")
      before = restriction_counts(ctx)
      lacking = norm(import_rows(ctx, %{"type_restrictions" => []}, ctx.auditor_token))
      assert {403, _, %{"detail" => "insufficient permissions"}} = lacking

      rows = %{
        "field_restrictions" => [%{"entity_type" => "locked_r", "field_name" => "f"}],
        "field_grants" => [
          %{"user_id" => ctx.user_id, "entity_type" => "locked_r", "field_name" => "f"}
        ],
        "type_restrictions" => [%{"entity_type" => "locked_r"}],
        "type_grants" => [%{"user_id" => ctx.user_id, "entity_type" => "locked_r"}]
      }

      for {key, list} <- rows do
        body = Map.put(%{"type_restrictions" => [%{"entity_type" => "fresh_ok"}]}, key, list)
        assert norm(import_rows(ctx, body)) == lacking
        assert restriction_counts(ctx) == before
      end

      # the 403 beats the 422 of an invalid sibling row
      invalid = %{
        "type_grants" => [%{"user_id" => Ecto.UUID.generate(), "entity_type" => "locked_r"}]
      }

      assert norm(import_rows(ctx, invalid)) == lacking
      assert restriction_counts(ctx) == before
    end

    test "self-grant on a restricted type is blocked; a granted caller may extend grants" do
      ctx = tenant_ctx("gh2808-r3b")
      restrict!(ctx, "locked_s")
      other = insert_user!(ctx.schema_name)
      before = restriction_counts(ctx)
      body = %{"type_grants" => [%{"user_id" => ctx.user_id, "entity_type" => "locked_s"}]}
      assert {403, _, _} = norm(import_rows(ctx, body))
      assert restriction_counts(ctx) == before

      grant!(ctx, "locked_s")
      ext = %{"type_grants" => [%{"user_id" => other.id, "entity_type" => "locked_s"}]}
      assert {200, _, %{"inserted" => %{"type_grants" => 1}}} = norm(import_rows(ctx, ext))
    end

    test "first-time restrict-and-grant in one request works; validation answers are unchanged" do
      ctx = tenant_ctx("gh2808-r3c")

      body = %{
        "type_restrictions" => [%{"entity_type" => "new_t"}],
        "type_grants" => [%{"user_id" => ctx.user_id, "entity_type" => "new_t"}]
      }

      assert {200, _, %{"inserted" => %{"type_restrictions" => 1, "type_grants" => 1}}} =
               norm(import_rows(ctx, body))

      assert {422, _, _} =
               norm(
                 import_rows(ctx, %{
                   "type_grants" => [%{"user_id" => Ecto.UUID.generate(), "entity_type" => "t2"}]
                 })
               )

      assert {400, _, _} = norm(import_rows(ctx, {:raw, "[1]"}))

      assert {422, _, _} =
               norm(import_rows(ctx, %{"type_restrictions" => ["x", 5, %{"entity_type" => 3}]}))
    end

    test "a user id of another tenant is still refused for an allowed type" do
      ctx = tenant_ctx("gh2808-r3d")
      other = tenant_ctx("gh2808-r3e")
      before = restriction_counts(ctx)

      body = %{"type_grants" => [%{"user_id" => other.user_id, "entity_type" => "open_t"}]}
      assert {422, _, _} = norm(import_rows(ctx, body))
      assert restriction_counts(ctx) == before
    end

    test "Restrictions.entity_types/1 collects binary types and ignores malformed entries" do
      attrs = %{
        "field_restrictions" => [%{"entity_type" => "a", "field_name" => "f"}, "junk", 7],
        "type_grants" => [%{"entity_type" => "b"}, %{"entity_type" => "a"}, %{"entity_type" => 1}],
        "type_restrictions" => "not a list",
        "field_grants" => nil
      }

      assert Enum.sort(Restrictions.entity_types(attrs)) == ["a", "b"]
      assert Restrictions.entity_types(%{}) == []
    end
  end
end
