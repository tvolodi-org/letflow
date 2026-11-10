defmodule Letflow.Routers.IdentityUsersImportTest do
  @moduledoc """
  T-1609 / REQ-791: the xlsx user import (`GET /users/import-template`, `POST /users/import`).
  Dispatch as in `identity_test.exs` (direct `Letflow.Routers.Identity.call/2` with an
  `auth_context`); the xlsx bytes sit in `body_params["_xlsx"]` as the body parser leaves them.
  Test ids T-1..T-14 are those of the design; T-15 is in `audit_dispositions_test.exs`, T-13
  in `plugs/xlsx_body_parser_test.exs`.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Elixlsx.{Sheet, Workbook}
  alias Letflow.Entities.XlsxImport
  alias Letflow.Identity.User
  alias Letflow.Identity.UserImport
  alias Letflow.Test.LoginDirectoryFixture, as: Fx

  @opts Letflow.Routers.Identity.init([])
  @header ["username", "display_name", "email"]

  defp xlsx(rows) do
    {:ok, {_name, bin}} =
      Elixlsx.write_to_memory(%Workbook{sheets: [%Sheet{name: "users", rows: rows}]}, "u.xlsx")

    bin
  end

  defp call(method, path, tenant, roles, bytes \\ nil) do
    conn(method, path)
    |> Map.put(:body_params, if(bytes, do: %{"_xlsx" => bytes}, else: %{}))
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant.tenant_id,
      roles: roles
    })
    |> assign(:trace_id, "t1609-trace")
    |> Letflow.Routers.Identity.call(@opts)
  end

  defp import!(tenant, rows, query \\ "") do
    conn = call(:post, "/users/import" <> query, tenant, ["TENANT_ADMIN"], xlsx([@header | rows]))
    {conn, if(conn.resp_body != "", do: Jason.decode!(conn.resp_body))}
  end

  defp row(n, extra \\ []) do
    [
      Keyword.get(extra, :username, "imp-#{n}"),
      Keyword.get(extra, :name, "Person #{n}"),
      Keyword.get(extra, :email, "imp-#{n}@example.test")
    ]
  end

  defp users(tenant), do: Fx.user_count(tenant.schema_name)

  setup do
    %{tenant: Fx.tenant!()}
  end

  describe "template" do
    test "T-1: header row is username, display_name, email", %{tenant: tenant} do
      conn = call(:get, "/users/import-template", tenant, ["TENANT_ADMIN"])
      assert conn.status == 200

      assert {:ok, []} =
               XlsxImport.convert_detailed(conn.resp_body, UserImport.fields(),
                 required_headers: @header
               )

      # only these three columns: a file with a fourth declared field would not be needed
      two = Enum.take(UserImport.fields(), 2)

      assert {:error, :xlsx_unknown_header, %{headers: ["email"]}} =
               XlsxImport.convert_detailed(conn.resp_body, two)
    end

    test "T-2: a caller without UsersManage gets 403", %{tenant: tenant} do
      assert call(:get, "/users/import-template", tenant, ["VIEWER"]).status == 403
      conn = call(:post, "/users/import", tenant, ["VIEWER"], xlsx([@header]))
      assert conn.status == 403
      assert users(tenant) == 0
    end
  end

  describe "report" do
    test "T-3: each refusal reason names line and header", %{tenant: tenant} do
      for name <- ["taken", "kept"] do
        {:ok, _} =
          Letflow.Identity.create_user(
            %{
              "username" => name,
              "display_name" => String.capitalize(name),
              "email" => "#{name}@example.test"
            },
            prefix: tenant.schema_name,
            tenant_id: tenant.tenant_id
          )
      end

      rows = [
        row(1),
        ["", "No Name", "x@example.test"],
        ["imp-3", "Bad Mail", "not-an-email"],
        row(1),
        ["imp-5", "Same Mail", "imp-1@example.test"],
        ["taken", "Other Name", "taken@example.test"],
        ["kept", "Kept", "kept@example.test"],
        [String.duplicate("a", 256), "Long", "long@example.test"]
      ]

      {conn, body} = import!(tenant, rows, "?dry_run=true")
      assert conn.status == 200
      assert %{"dry_run" => true, "results" => results} = body

      reasons = Map.new(results, &{&1["line"], &1})
      assert %{"status" => "ok", "outcome" => "created"} = reasons[2]
      assert reasons[3]["reason"] == %{"type" => "user_field_required", "header" => "username"}
      assert reasons[4]["reason"] == %{"type" => "user_field_invalid", "header" => "email"}
      assert reasons[5]["reason"] == %{"type" => "user_duplicate_in_file", "header" => "username"}
      assert reasons[6]["reason"] == %{"type" => "user_duplicate_in_file", "header" => "email"}
      assert reasons[7]["reason"] == %{"type" => "user_exists_different", "header" => "username"}
      assert %{"status" => "ok", "outcome" => "unchanged"} = reasons[8]
      assert reasons[9]["reason"] == %{"type" => "user_field_invalid", "header" => "username"}
    end

    test "T-4: the answer holds no cell text of a refused row", %{tenant: tenant} do
      rows = [["secret-name", "Secret Person", "secret-not-mail"]]

      conn =
        call(
          :post,
          "/users/import?dry_run=true",
          tenant,
          ["TENANT_ADMIN"],
          xlsx([@header | rows])
        )

      refute conn.resp_body =~ "secret"
    end
  end

  describe "whole-file refusals" do
    test "T-5: unknown, missing, too many rows, not an xlsx", %{tenant: tenant} do
      conn = call(:post, "/users/import", tenant, ["TENANT_ADMIN"], xlsx([["username", "nick"]]))
      assert conn.status == 422
      assert %{"headers" => ["nick"]} = Jason.decode!(conn.resp_body)

      conn =
        call(
          :post,
          "/users/import",
          tenant,
          ["TENANT_ADMIN"],
          xlsx([["username", "email"], ["a", "b"]])
        )

      assert conn.status == 422
      body = Jason.decode!(conn.resp_body)
      assert body["headers"] == ["display_name"]

      many = for n <- 1..201, do: row(n)
      conn = call(:post, "/users/import", tenant, ["TENANT_ADMIN"], xlsx([@header | many]))
      assert conn.status == 413

      conn = call(:post, "/users/import", tenant, ["TENANT_ADMIN"], "not a zip")
      assert conn.status == 422

      conn = call(:post, "/users/import?dry_run=maybe", tenant, ["TENANT_ADMIN"], xlsx([@header]))
      assert conn.status == 422
      assert users(tenant) == 0
    end

    test "T-12: a password or roles column is an unknown header", %{tenant: tenant} do
      for extra <- ["password", "roles"] do
        bytes = xlsx([@header ++ [extra], row(1) ++ ["x"]])
        conn = call(:post, "/users/import", tenant, ["TENANT_ADMIN"], bytes)
        assert conn.status == 422
        assert %{"headers" => [^extra]} = Jason.decode!(conn.resp_body)
      end

      assert users(tenant) == 0
    end
  end

  describe "writes" do
    test "T-6: a dry run writes nothing", %{tenant: tenant} do
      {conn, body} = import!(tenant, [row(1), row(2)], "?dry_run=true")
      assert conn.status == 200
      assert Enum.all?(body["results"], &(&1["outcome"] == "created"))
      assert users(tenant) == 0
    end

    test "T-7: one refused row leaves nothing written", %{tenant: tenant} do
      {conn, body} = import!(tenant, [row(1), ["", "x", "y@example.test"], row(3)])
      assert conn.status == 200
      assert body["applied"] == false
      assert users(tenant) == 0
    end

    test "T-8: all valid rows are created active with audit actor and directory entry", %{
      tenant: tenant
    } do
      {conn, body} = import!(tenant, [row(1), row(2)])
      assert body["applied"] == true
      assert conn.status == 200
      assert users(tenant) == 2

      user = Repo.get_by!(User, [username: "imp-1"], prefix: tenant.schema_name)
      assert user.status == :active

      %{rows: [[actor, trace]]} =
        Repo.query!(
          ~s(SELECT actor_id::text, trace_id FROM "#{tenant.schema_name}".audit_entries WHERE action = 'user.create' AND resource_id::text = $1 LIMIT 1),
          [user.id]
        )

      assert is_binary(actor)
      assert trace == "t1609-trace"
      assert length(Fx.entries(tenant.tenant_id)) == 2
    end

    test "T-9: partial fix and re-upload", %{tenant: tenant} do
      bad = [row(1), ["imp-2", "", "imp-2@example.test"], row(3)]
      {_, body} = import!(tenant, bad)
      assert body["applied"] == false
      assert users(tenant) == 0

      good = [row(1), row(2), row(3)]
      {_, body} = import!(tenant, good)
      assert body["applied"] == true
      assert users(tenant) == 3

      {_, body} = import!(tenant, good)
      assert body["applied"] == true
      assert Enum.all?(body["results"], &(&1["outcome"] == "unchanged"))
      assert users(tenant) == 3
    end

    test "T-10: an existing user is never modified", %{tenant: tenant} do
      {_, _} = import!(tenant, [row(1)])
      {_, body} = import!(tenant, [row(1, email: "changed@example.test")])
      assert body["applied"] == false
      assert [%{"reason" => %{"type" => "user_exists_different"}}] = body["results"]
      user = Repo.get_by!(User, [username: "imp-1"], prefix: tenant.schema_name)
      assert user.email == "imp-1@example.test"
    end

    test "T-11: a username that exists only in tenant B is created in A", %{tenant: a} do
      b = Fx.tenant!()
      {_, _} = import!(b, [row(1, email: "b-owner@example.test")])

      {_, body} = import!(a, [row(1)])
      assert body["applied"] == true
      assert [%{"outcome" => "created"}] = body["results"]

      b_user = Repo.get_by!(User, [username: "imp-1"], prefix: b.schema_name)
      assert b_user.email == "b-owner@example.test"
      assert users(a) == 1 and users(b) == 1
    end

    test "T-14: a failure while writing rolls the whole file back", %{tenant: tenant} do
      Fx.swap_keys!(:unset, nil)
      {conn, body} = import!(tenant, [row(1), row(2)])
      assert conn.status == 200
      assert body["applied"] == false
      assert Enum.any?(body["results"], &(&1["reason"] == %{"type" => "internal_error"}))
      assert users(tenant) == 0
    end
  end
end
