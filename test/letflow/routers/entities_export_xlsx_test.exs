defmodule Letflow.Routers.EntitiesExportXlsxTest do
  @moduledoc """
  GH #3600 / REQ-653: `?format=xlsx` on `POST /entities/records/:entity_type/export`. Full
  pipeline (`Letflow.Router.call/2`, real API-token bearer), real Postgres, `async: false`.

    * F1..F3: the format switch (xlsx, json and no parameter, 422 for anything else).
    * C1..C3: sheet `records` (order, cell types, deleted rows) and sheet `export`.
    * X1: a text starting with `=` is a string cell.
    * R1/R2: redaction leaves an empty column; 403 and 404 answer as the JSON export.
    * T1: tenant B never sees tenant A's rows.
    * S1: both formats share the one `run_export` pipeline; the xlsx rows are the JSON live rows.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Records
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.TenantFixture

  @xlsx "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp export(ctx, type, body, query \\ "") do
    conn(:post, "/api/v1/entities/records/#{type}/export" <> query, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
    |> dispatch()
  end

  defp tenant_ctx(prefix, roles \\ ["TENANT_ADMIN"]) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: prefix)
    {:ok, _} = EventTypes.seed!(tenant.schema_name)
    attach_user!(%{schema_name: tenant.schema_name, slug: tenant.tenant.slug}, roles)
  end

  defp attach_user!(base, roles) do
    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "gh3600-user-#{Ecto.UUID.generate()}",
        display_name: "GH-3600 test user",
        email: "gh3600-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: base.schema_name)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: base.schema_name)

    Map.merge(base, %{plaintext: plaintext, user_id: user.id})
  end

  defp seed_type!(ctx, name, fields) do
    {:ok, _} =
      Definitions.create_definition(
        %{
          definition: %{name: name, display_name: name, fields: fields},
          created_by: ctx.user_id
        },
        ctx.schema_name
      )

    {:ok, _} = Definitions.activate_definition(name, ctx.user_id, "gh3600", ctx.schema_name)
  end

  @typed [
    %{name: "title", type: :string, queried: true},
    %{name: "qty", type: :integer},
    %{name: "price", type: :decimal, decimal_precision: 10, decimal_scale: 2},
    %{name: "active", type: :boolean},
    %{name: "born", type: :date},
    %{name: "kind", type: :enum, enum_values: ["a", "b"]}
  ]

  defp seed_record!(ctx, type, values) do
    {:ok, %{record: record}} =
      Records.create_record(
        %{
          entity_type: type,
          field_values: values,
          actor_id: ctx.user_id,
          idempotency_key: Ecto.UUID.generate()
        },
        ctx.schema_name
      )

    record
  end

  defp delete_record!(ctx, type, record_id) do
    {:ok, _} =
      Records.delete_record(
        %{
          entity_type: type,
          record_id: record_id,
          actor_id: ctx.user_id,
          idempotency_key: Ecto.UUID.generate()
        },
        ctx.schema_name
      )
  end

  defp sheets(conn) do
    {:ok, pkg} = XlsxReader.open(conn.resp_body, source: :binary)

    Map.new(XlsxReader.sheet_names(pkg), fn name ->
      {:ok, rows} = XlsxReader.sheet(pkg, name)
      {name, rows}
    end)
  end

  defp restrict!(ctx, type, field) do
    Repo.insert_all(
      "entity_field_restrictions",
      [
        %{
          id: Ecto.UUID.bingenerate(),
          entity_type: type,
          field_name: field,
          inserted_at: NaiveDateTime.utc_now(),
          updated_at: NaiveDateTime.utc_now()
        }
      ],
      prefix: ctx.schema_name
    )
  end

  defp typed_tenant(prefix) do
    ctx = tenant_ctx(prefix)
    seed_type!(ctx, "thing", @typed)
    ctx
  end

  describe "format switch" do
    test "F1 xlsx answers 200 with the content type and the attachment name" do
      ctx = typed_tenant("gh3600-f1")
      seed_record!(ctx, "thing", %{"title" => "a"})
      conn = export(ctx, "thing", %{}, "?format=xlsx")

      assert conn.status == 200
      assert [ct] = get_resp_header(conn, "content-type")
      assert ct == @xlsx

      assert get_resp_header(conn, "content-disposition") == [
               ~s(attachment; filename="thing.xlsx")
             ]

      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert "records" in Map.keys(sheets(conn))
    end

    test "F2 no parameter and format=json answer the same JSON" do
      ctx = typed_tenant("gh3600-f2")
      seed_record!(ctx, "thing", %{"title" => "a"})
      drop = &(&1 |> Map.delete("exported_at") |> Map.delete("trace_id"))

      plain = export(ctx, "thing", %{})
      json = export(ctx, "thing", %{}, "?format=json")
      assert plain.status == 200 and json.status == 200
      assert drop.(Jason.decode!(plain.resp_body)) == drop.(Jason.decode!(json.resp_body))
      assert [json_ct] = get_resp_header(json, "content-type")
      assert json_ct =~ "json"
    end

    test "F3 any other format is 422" do
      ctx = typed_tenant("gh3600-f3")

      for q <- ["?format=csv", "?format=XLSX", "?format=", "?format[]=xlsx"] do
        assert export(ctx, "thing", %{}, q).status == 422, q
      end
    end
  end

  describe "content" do
    test "C1 header in definition order; one row per live record; deleted absent" do
      ctx = typed_tenant("gh3600-c1")
      seed_record!(ctx, "thing", %{"title" => "one"})
      gone = seed_record!(ctx, "thing", %{"title" => "gone"})
      seed_record!(ctx, "thing", %{"title" => "two"})
      delete_record!(ctx, "thing", gone.record_id)

      rows = sheets(export(ctx, "thing", %{}, "?format=xlsx"))["records"]
      assert hd(rows) == ["title", "qty", "price", "active", "born", "kind"]
      assert rows |> tl() |> Enum.map(&hd/1) |> Enum.sort() == ["one", "two"]
    end

    test "C2 cell types" do
      ctx = typed_tenant("gh3600-c2")

      seed_record!(ctx, "thing", %{
        "title" => "t",
        "qty" => 7,
        "price" => 12.5,
        "active" => true,
        "born" => "2026-03-04",
        "kind" => "b"
      })

      [_header, [title, qty, price, active, born, kind]] =
        sheets(export(ctx, "thing", %{}, "?format=xlsx"))["records"]

      assert title == "t"
      assert qty == 7
      assert price == 12.5
      assert active == true
      assert born in [~D[2026-03-04], ~N[2026-03-04 00:00:00]]
      assert kind == "b"
    end

    test "C3 sheet export equals the JSON export of the same body" do
      ctx = typed_tenant("gh3600-c3")
      for t <- ["a", "b"], do: seed_record!(ctx, "thing", %{"title" => t})
      body = %{"page_size" => 1}

      xlsx = export(ctx, "thing", body, "?format=xlsx")

      [["entity_type", "thing"], ["exported_at", at], ["next_cursor", cursor]] =
        sheets(xlsx)["export"]

      assert {:ok, _, _} = DateTime.from_iso8601(at)
      assert is_binary(cursor)
      # cursors are signed with a nonce, so they differ between calls; the xlsx cursor must
      # continue the JSON export where its page stopped
      first = Jason.decode!(export(ctx, "thing", body).resp_body)
      assert is_binary(first["next_cursor"])

      next =
        Jason.decode!(export(ctx, "thing", %{"page_size" => 5, "cursor" => cursor}).resp_body)

      assert length(first["records"]) == 1 and length(next["records"]) == 1
      refute hd(first["records"])["record_id"] == hd(next["records"])["record_id"]

      second = export(ctx, "thing", %{"page_size" => 5, "cursor" => cursor}, "?format=xlsx")
      assert [_, _, ["next_cursor" | rest]] = sheets(second)["export"]
      last = List.first(rest)
      assert last in [nil, ""]
    end

    test "X1 a text starting with = is a string cell" do
      ctx = typed_tenant("gh3600-x1")
      seed_record!(ctx, "thing", %{"title" => "=1+1"})
      [_h, [title | _]] = sheets(export(ctx, "thing", %{}, "?format=xlsx"))["records"]
      assert title == "=1+1"
    end
  end

  describe "access" do
    test "R1 a restricted field is an empty column; JSON shows it redacted" do
      ctx = typed_tenant("gh3600-r1")
      restrict!(ctx, "thing", "qty")
      seed_record!(ctx, "thing", %{"title" => "a", "qty" => 5})
      seed_record!(ctx, "thing", %{"title" => "b", "qty" => 6})

      [header | data] = sheets(export(ctx, "thing", %{}, "?format=xlsx"))["records"]
      assert "qty" in header
      assert Enum.all?(data, fn row -> Enum.at(row, 1) in [nil, ""] end)

      json = Jason.decode!(export(ctx, "thing", %{}).resp_body)

      assert Enum.all?(
               json["records"],
               &(&1["field_values"]["qty"] != 5 and &1["field_values"]["qty"] != 6)
             )
    end

    test "R2 no permission is 403; a hidden type answers as the JSON export" do
      ctx = typed_tenant("gh3600-r2")
      other = attach_user!(Map.take(ctx, [:schema_name, :slug]), ["TENANT_AUDITOR"])

      denied = export(other, "thing", %{}, "?format=xlsx")
      assert denied.status == export(other, "thing", %{}).status

      missing_x = export(ctx, "nope", %{}, "?format=xlsx")
      missing_j = export(ctx, "nope", %{})
      assert missing_x.status == missing_j.status
      drop = &Map.delete(Jason.decode!(&1.resp_body), "trace_id")
      assert drop.(missing_x) == drop.(missing_j)
    end

    test "T1 another tenant gets 404 for a foreign type and never the foreign rows" do
      a = typed_tenant("gh3600-ta")
      b = tenant_ctx("gh3600-tb")
      seed_type!(b, "other", [%{name: "title", type: :string}])
      seed_record!(a, "thing", %{"title" => "A-ROW"})
      seed_record!(b, "other", %{"title" => "B-ROW"})

      assert export(b, "thing", %{}, "?format=xlsx").status == 404
      assert export(b, "thing", %{}).status == 404

      file = export(b, "other", %{}, "?format=xlsx")
      assert file.status == 200
      refute inspect(sheets(file)) =~ "A-ROW"
    end
  end

  describe "scope" do
    test "S1 one pipeline for both formats; xlsx rows are the JSON live rows" do
      ctx = typed_tenant("gh3600-s1")
      for t <- ["a", "b", "c"], do: seed_record!(ctx, "thing", %{"title" => t})
      gone = seed_record!(ctx, "thing", %{"title" => "d"})
      delete_record!(ctx, "thing", gone.record_id)

      json = Jason.decode!(export(ctx, "thing", %{}).resp_body)
      live = for r <- json["records"], not r["deleted"], do: r["field_values"]["title"]
      [_h | data] = sheets(export(ctx, "thing", %{}, "?format=xlsx"))["records"]
      assert Enum.map(data, &hd/1) == live
    end
  end
end
