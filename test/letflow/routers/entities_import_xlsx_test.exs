Code.require_file("../modules/catalog_items/catalog_items_fixture.exs", __DIR__)

defmodule Letflow.Routers.EntitiesImportXlsxTest do
  @moduledoc """
  GH #3603 / REQ-650: the `.xlsx` media type as a third body of
  `POST /api/v1/entities/records/:entity_type/import`. Full pipeline (`Letflow.Router.call/2`,
  real API-token bearer), real Postgres, so `async: false` with the sandbox in `:auto` mode.

    * R4a..R4f: rows created with their line, upsert idempotency, a row error on its line,
      the six whole-file refusals (422, fixed detail, nothing written), the 2 MiB limit (413),
      the xlsx media type elsewhere is a 415.
    * R5a/R5b: a module-managed type is 403 `entity_type_managed` before the bytes are read; a
      hidden type answers like the CSV request.
    * R6: a type of another tenant is a nonexistent type; no tenant identifier is read from the file.
    * R8: a scoped caller gets the same answer for the xlsx body as for the JSON body.
    * R11: the route table row names the xlsx media type and the converter.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.CatalogItemsFixture
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Support.ScopeWritesFixture, as: W
  alias Letflow.TenantFixture
  alias Letflow.Test.SandboxAutoMode
  alias Letflow.XlsxFixture

  @xlsx "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  @schema_version "entities/record-export/v1"

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)
    :ok
  end

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp authed(conn, ctx) do
    conn
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> dispatch()
  end

  defp import_path(type, query), do: "/api/v1/entities/records/#{type}/import" <> query

  defp xlsx_import(ctx, type, bytes, query \\ "", content_type \\ @xlsx) do
    conn(:post, import_path(type, query), bytes)
    |> put_req_header("content-type", content_type)
    |> authed(ctx)
  end

  defp csv_import(ctx, type, csv) do
    conn(:post, import_path(type, ""), csv)
    |> put_req_header("content-type", "text/csv")
    |> authed(ctx)
  end

  defp book(rows), do: XlsxFixture.build([rows])

  defp attach_user!(tenant_ctx_base, roles) do
    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "gh3603-user-#{Ecto.UUID.generate()}",
        display_name: "GH-3603 test user",
        email: "gh3603-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: tenant_ctx_base.schema_name)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil},
        prefix: tenant_ctx_base.schema_name
      )

    Map.merge(tenant_ctx_base, %{plaintext: plaintext, user_id: user.id})
  end

  defp tenant_ctx(slug_prefix, roles \\ ["TENANT_ADMIN"]) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)
    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)
    attach_user!(%{schema_name: tenant.schema_name, slug: tenant.tenant.slug}, roles)
  end

  defp seed_type!(ctx, name) do
    fields = [
      %{name: "title", type: :string, required: true},
      %{name: "qty", type: :integer},
      %{name: "kind", type: :enum, enum_values: ["a", "b"]}
    ]

    {:ok, _} =
      Definitions.create_definition(
        %{
          definition: %{name: name, display_name: name, fields: fields},
          created_by: ctx.user_id
        },
        ctx.schema_name
      )

    {:ok, _} = Definitions.activate_definition(name, ctx.user_id, "gh3603", ctx.schema_name)
    :ok
  end

  defp rows(ctx, type) do
    Repo.all(from(l in Latest, where: l.entity_type == ^type, order_by: l.inserted_at),
      prefix: ctx.schema_name
    )
  end

  defp event_count(ctx),
    do: Repo.aggregate(from(e in "events", select: e.id), :count, prefix: ctx.schema_name)

  defp body(conn), do: Jason.decode!(conn.resp_body)
  defp results(conn), do: body(conn)["results"]
  defp strip_trace(conn), do: conn.resp_body |> Jason.decode!() |> Map.delete("trace_id")

  defp too_large_reason(fun) do
    %Plug.Conn.WrapperError{reason: %{__struct__: struct}} =
      try do
        fun.()
      rescue
        e in Plug.Conn.WrapperError -> e
      end

    struct
  end

  describe "R4: the import" do
    test "R4a: rows are created, one result per row with its sheet line" do
      ctx = tenant_ctx("gh3603-r4a")
      seed_type!(ctx, "item")

      conn = xlsx_import(ctx, "item", book([["title", "qty"], ["One", 1], ["Two", 2.0]]))

      assert conn.status == 200
      assert Enum.map(results(conn), & &1["line"]) == [2, 3]
      assert Enum.all?(results(conn), &(&1["status"] == "ok"))

      assert rows(ctx, "item") |> Enum.map(& &1.field_values) |> Enum.sort() ==
               [%{"title" => "One", "qty" => 1}, %{"title" => "Two", "qty" => 2}]
    end

    test "R4b: upsert_by=external_ref twice leaves one record per reference and no new event" do
      ctx = tenant_ctx("gh3603-r4b")
      seed_type!(ctx, "item")

      xlsx =
        book([
          ["title", "external_ref_system", "external_ref_id"],
          ["A", "sap", 1],
          ["B", "sap", 2]
        ])

      first = xlsx_import(ctx, "item", xlsx, "?upsert_by=external_ref")
      assert Enum.map(results(first), & &1["outcome"]) == ["created", "created"]
      before = event_count(ctx)

      second = xlsx_import(ctx, "item", xlsx, "?upsert_by=external_ref")
      assert Enum.map(results(second), & &1["outcome"]) == ["unchanged", "unchanged"]
      assert length(rows(ctx, "item")) == 2
      assert event_count(ctx) == before
    end

    test "R4c: a row error is reported on its line while the other rows are written" do
      ctx = tenant_ctx("gh3603-r4c")
      seed_type!(ctx, "item")

      conn =
        xlsx_import(
          ctx,
          "item",
          book([["title", "qty"], ["Good", 1], ["Bad", "abc"], ["Also", 3]])
        )

      assert conn.status == 200
      assert [ok1, bad, ok2] = results(conn)
      assert ok1["status"] == "ok" and ok1["line"] == 2
      assert bad["status"] == "error" and bad["line"] == 3
      assert bad["reason"] == %{"type" => "csv_invalid_integer", "header" => "qty"}
      assert ok2["status"] == "ok" and ok2["line"] == 4
      refute conn.resp_body =~ "abc"

      assert rows(ctx, "item") |> Enum.map(& &1.field_values["title"]) |> Enum.sort() == [
               "Also",
               "Good"
             ]
    end

    test "R4d: each whole-file refusal is a 422 with its fixed detail and writes nothing" do
      ctx = tenant_ctx("gh3603-r4d")
      seed_type!(ctx, "item")

      too_big =
        XlsxFixture.build([[["title"], ["A"]]],
          extra: [{"xl/big.bin", :binary.copy(<<0>>, 26_214_401)}]
        )

      cases = [
        {"not an xlsx", "xlsx file is not readable"},
        {too_big, "xlsx file is too large when uncompressed"},
        {book([]), "xlsx file has no header row"},
        {book([["title", "title"], ["A", "B"]]), "xlsx header has a duplicate column"},
        {book([["title", "nope"], ["A", "B"]]),
         "xlsx header has a column that is not a field of the entity type"},
        {book([["title", "external_ref_system"], ["A", "sap"]]),
         "xlsx header has a column that is not a field of the entity type"}
      ]

      for {bytes, detail} <- cases do
        conn = xlsx_import(ctx, "item", bytes)
        assert conn.status == 422, detail
        assert conn.resp_body =~ detail
      end

      pair =
        xlsx_import(
          ctx,
          "item",
          book([["title", "external_ref_system"], ["A", "sap"]]),
          "?upsert_by=external_ref"
        )

      assert pair.status == 422
      assert pair.resp_body =~ "external_ref_system and external_ref_id must be given together"
      assert rows(ctx, "item") == []
    end

    test "R4e: a body over 2 MiB and 201 rows give the JSON 413" do
      ctx = tenant_ctx("gh3603-r4e")
      seed_type!(ctx, "item")

      assert too_large_reason(fn ->
               xlsx_import(ctx, "item", String.duplicate("a", 2_097_153))
             end) == Plug.Parsers.RequestTooLargeError

      many = book([["title"] | for(i <- 1..201, do: ["T#{i}"])])
      conn = xlsx_import(ctx, "item", many)
      assert conn.status == 413

      json =
        conn(
          :post,
          import_path("item", ""),
          Jason.encode!(%{
            "record_export_schema_version" => @schema_version,
            "entity_type" => "item",
            "records" => for(i <- 1..201, do: %{"field_values" => %{"title" => "T#{i}"}})
          })
        )
        |> put_req_header("content-type", "application/json")
        |> authed(ctx)

      assert strip_trace(conn) == strip_trace(json)
      assert rows(ctx, "item") == []
    end

    test "R4f: the xlsx media type on a record create route is a 415" do
      ctx = tenant_ctx("gh3603-r4f")
      seed_type!(ctx, "item")

      reason =
        too_large_reason(fn ->
          conn(:post, "/api/v1/entities/records/item", book([["title"], ["A"]]))
          |> put_req_header("content-type", @xlsx)
          |> authed(ctx)
        end)

      assert reason == Plug.Parsers.UnsupportedMediaTypeError
    end
  end

  describe "R5: managed and hidden types" do
    test "R5a: a module-managed type is 403 entity_type_managed and nothing is written" do
      %{schema: schema, tenant_id: tenant_id} =
        CatalogItemsFixture.installed_tenant!("gh3603-r5a")

      slug = Repo.get!(Tenant, tenant_id).slug
      ctx = attach_user!(%{schema_name: schema, slug: slug}, ["TENANT_ADMIN"])

      before = Repo.aggregate(Latest, :count, prefix: schema)
      conn = xlsx_import(ctx, "catalog_item", book([["code"], ["X"]]))

      assert conn.status == 403
      assert conn.resp_body =~ "entity_type_managed"
      assert Repo.aggregate(Latest, :count, prefix: schema) == before

      # garbage bytes give the same answer: the bytes are never read
      garbage = xlsx_import(ctx, "catalog_item", "garbage")
      assert strip_trace(garbage) == strip_trace(conn)
    end

    test "R5b: a type hidden from the caller answers like a nonexistent type, as for CSV" do
      ctx = tenant_ctx("gh3603-r5b")
      xlsx = xlsx_import(ctx, "does_not_exist", book([["title"], ["A"]]))
      csv = csv_import(ctx, "does_not_exist", "title\nA\n")

      assert xlsx.status == 404
      assert strip_trace(xlsx) == strip_trace(csv)
      # a format error cannot reveal that a type exists
      assert xlsx_import(ctx, "does_not_exist", "garbage").status == 404
    end
  end

  describe "R6: tenant isolation" do
    test "R6: a type of another tenant is a nonexistent type; the file names no tenant" do
      a = tenant_ctx("gh3603-r6a")
      b = tenant_ctx("gh3603-r6b")
      seed_type!(b, "only_in_b")
      seed_type!(a, "item")

      cross = xlsx_import(a, "only_in_b", book([["title"], ["Intruder"]]))
      missing = xlsx_import(a, "does_not_exist", book([["title"], ["Intruder"]]))
      assert cross.status == 404
      assert strip_trace(cross) == strip_trace(missing)
      assert rows(b, "only_in_b") == []
      assert rows(a, "only_in_b") == []

      # a column named like a tenant identifier is only an unknown header
      named = xlsx_import(a, "item", book([["title", "tenant_id"], ["A", b.schema_name]]))
      assert named.status == 422
      assert named.resp_body =~ "not a field of the entity type"
      assert rows(a, "item") == []
      assert rows(b, "only_in_b") == []
    end
  end

  describe "R8: a scoped caller" do
    test "R8: the xlsx body gets the same answer as the JSON body of the same rows" do
      fx = W.provision!("gh3603-r8")

      scoped = fn conn_fun ->
        conn_fun.()
        |> put_req_header("authorization", "Bearer realm-token:" <> fx.realm)
        |> dispatch()
      end

      xlsx_for = fn nodes ->
        book([["name", "amount", "scope_node"] | Enum.map(nodes, &["n", 1, &1])])
      end

      xlsx_request = fn nodes ->
        scoped.(fn ->
          conn(:post, W.import_path("scoped_item"), xlsx_for.(nodes))
          |> put_req_header("content-type", @xlsx)
        end)
      end

      json_request = fn nodes ->
        W.request(fx, :post, W.import_path("scoped_item"), W.import_body("scoped_item", nodes))
      end

      before = W.counts(fx)
      xlsx_out = xlsx_request.(["sf-a", "sf-b"])
      json_out = json_request.(["sf-a", "sf-b"])
      assert W.norm(xlsx_out) == W.norm(json_out)
      assert xlsx_out.status in [404, 403]
      assert W.counts(fx) == before

      ok = xlsx_request.(["sf-a", "sf-a1"])
      assert ok.status == 200
      assert length(results(ok)) == 2
    end
  end

  test "R11: the route table row names the xlsx media type and the converter module" do
    row =
      "lib/letflow/routers/entities.ex"
      |> File.read!()
      |> String.split("\n")
      |> Enum.find(&String.starts_with?(&1, "  | import_records |"))

    assert row =~ @xlsx
    assert row =~ "Letflow.Entities.XlsxImport"
    assert row =~ "text/csv"
    assert row =~ "Letflow.Entities.CsvImport"
  end
end
