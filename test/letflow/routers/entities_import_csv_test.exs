defmodule Letflow.Routers.EntitiesImportCsvTest do
  @moduledoc """
  GH #3182 / REQ-557: `text/csv` as a second content type of
  `POST /api/v1/entities/records/:entity_type/import`. Full pipeline (`Letflow.Router.call/2`,
  real API-token bearer), real Postgres, so `async: false` with the sandbox in `:auto` mode.

    * R1: valid rows give the same records and response shape as the equivalent JSON document,
      plus a `line` on each result.
    * R2/R6: a row refused by the existing path keeps that path's result and gains the line.
    * R3/R4: whole-file refusals (header mapping, invalid UTF-8) are 422 with a constant
      reason and nothing is written.
    * R5: decimal strict and non-strict end to end; a bad cell is never echoed.
    * R7: upsert mode by `?upsert_by=external_ref`.
    * R8/R9: INV-10 (a type of another tenant is a nonexistent type) and the permission gate.
    * R10: the 2 MiB body limit and the 200-row cap give the JSON 413.
    * R11: the route table row of `Letflow.Routers.Entities` names text/csv and the converter.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Plug.Conn
  import Plug.Test

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Record.Latest
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.TenantFixture
  alias Letflow.Test.SandboxAutoMode

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

  defp csv_import(ctx, type, csv, query \\ "", content_type \\ "text/csv") do
    conn(:post, import_path(type, query), csv)
    |> put_req_header("content-type", content_type)
    |> authed(ctx)
  end

  defp json_import(ctx, type, entries) do
    body = %{
      "record_export_schema_version" => @schema_version,
      "entity_type" => type,
      "records" => entries
    }

    conn(:post, import_path(type, ""), Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> authed(ctx)
  end

  defp tenant_ctx(slug_prefix, roles \\ ["TENANT_ADMIN"]) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)
    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "gh3182-user-#{Ecto.UUID.generate()}",
        display_name: "GH-3182 test user",
        email: "gh3182-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: tenant.schema_name)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: tenant.schema_name)

    %{
      schema_name: tenant.schema_name,
      slug: tenant.tenant.slug,
      plaintext: plaintext,
      user_id: user.id
    }
  end

  defp seed_type!(ctx, name) do
    fields = [
      %{name: "title", type: :string, required: true},
      %{name: "qty", type: :integer},
      %{
        name: "price",
        type: :decimal,
        decimal_precision: 20,
        decimal_scale: 2,
        decimal_strict: true
      },
      %{name: "ratio", type: :decimal, decimal_precision: 10, decimal_scale: 2},
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

    {:ok, _} = Definitions.activate_definition(name, ctx.user_id, "gh3182", ctx.schema_name)
    :ok
  end

  defp rows(ctx, type) do
    Repo.all(from(l in Latest, where: l.entity_type == ^type, order_by: l.inserted_at),
      prefix: ctx.schema_name
    )
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)
  defp results(conn), do: body(conn)["results"]
  defp strip_trace(conn), do: conn.resp_body |> Jason.decode!() |> Map.delete("trace_id")

  # The pipeline wraps the parser error (the 413 comes from its plug_status).
  defp too_large_reason(fun) do
    %Plug.Conn.WrapperError{reason: %{__struct__: struct}} =
      try do
        fun.()
      rescue
        e in Plug.Conn.WrapperError -> e
      end

    struct
  end

  defp titles(ctx, type),
    do: ctx |> rows(type) |> Enum.map(& &1.field_values["title"]) |> Enum.sort()

  describe "R1/R2/R6: create mode" do
    test "R1: the same records and response shape as the JSON document, plus a line" do
      ctx = tenant_ctx("gh3182-r1")
      seed_type!(ctx, "item")

      csv = "title,qty\nOne,1\n\"Two, with comma\",2\n"
      csv_conn = csv_import(ctx, "item", csv)

      json_conn =
        json_import(ctx, "item", [
          %{"field_values" => %{"title" => "One", "qty" => 1}},
          %{"field_values" => %{"title" => "Two, with comma", "qty" => 2}}
        ])

      assert csv_conn.status == 200
      assert json_conn.status == 200

      assert Enum.map(rows(ctx, "item"), & &1.field_values) |> Enum.sort() ==
               Enum.sort([
                 %{"title" => "One", "qty" => 1},
                 %{"title" => "Two, with comma", "qty" => 2},
                 %{"title" => "One", "qty" => 1},
                 %{"title" => "Two, with comma", "qty" => 2}
               ])

      assert csv_conn |> results() |> Enum.map(&(&1 |> Map.delete("line") |> Map.keys())) ==
               json_conn |> results() |> Enum.map(&Map.keys/1)

      assert Enum.map(results(csv_conn), & &1["line"]) == [2, 3]

      assert Enum.all?(
               results(csv_conn),
               &(&1["status"] == "ok" and is_nil(&1["source_record_id"]))
             )
    end

    test "R2: a row the existing path refuses keeps its result and gains the line" do
      ctx = tenant_ctx("gh3182-r2")
      seed_type!(ctx, "item")

      conn = csv_import(ctx, "item", "title,qty\nGood,1\n,2\nAlso,3\n")
      assert conn.status == 200
      assert [ok1, bad, ok2] = results(conn)
      assert ok1["status"] == "ok" and ok1["line"] == 2
      assert bad["status"] == "error" and bad["line"] == 3
      assert bad["reason"]["type"] == "record_payload_invalid"
      assert ok2["status"] == "ok" and ok2["line"] == 4
      assert titles(ctx, "item") == ["Also", "Good"]
    end

    test "R6: an enum value outside enum_values is refused by the existing path with the line" do
      ctx = tenant_ctx("gh3182-r6")
      seed_type!(ctx, "item")

      conn = csv_import(ctx, "item", "title,kind\nA,a\nB,zzz\n")
      assert [%{"status" => "ok"}, bad] = results(conn)
      assert bad["status"] == "error" and bad["line"] == 3
      assert bad["reason"]["type"] == "record_payload_invalid"
      assert titles(ctx, "item") == ["A"]
    end
  end

  describe "R3/R4: whole-file refusals write nothing" do
    test "R3: unknown header, duplicate header, half a reference pair" do
      ctx = tenant_ctx("gh3182-r3")
      seed_type!(ctx, "item")

      for {csv, query} <- [
            {"title,nope\nA,B\n", ""},
            {"title,title\nA,B\n", ""},
            {"title,external_ref_system\nA,B\n", "?upsert_by=external_ref"},
            {"title,external_ref_id\nA,B\n", "?upsert_by=external_ref"}
          ] do
        conn = csv_import(ctx, "item", csv, query)
        assert conn.status == 422
        refute conn.resp_body =~ "nope"
        assert rows(ctx, "item") == []
      end
    end

    test "R4: invalid UTF-8, empty body and a malformed quote are 422 with nothing written" do
      ctx = tenant_ctx("gh3182-r4")
      seed_type!(ctx, "item")

      for csv <- ["title\nA" <> <<0xFF>> <> "\n", "", "title\n\"open\n"] do
        conn = csv_import(ctx, "item", csv)
        assert conn.status == 422
        assert rows(ctx, "item") == []
      end

      # BOM and charset parameter are accepted
      conn = csv_import(ctx, "item", "﻿title\nA\n", "", "text/csv; charset=utf-8")
      assert conn.status == 200
      assert titles(ctx, "item") == ["A"]
    end
  end

  describe "R5: coercion end to end" do
    test "decimal strict keeps the string, non-strict becomes the JSON number" do
      ctx = tenant_ctx("gh3182-r5")
      seed_type!(ctx, "item")

      conn = csv_import(ctx, "item", "title,price,ratio\nA,12345678901234567.50,1.5\n")
      assert [%{"status" => "ok"}] = results(conn)
      assert [row] = rows(ctx, "item")
      assert row.field_values["price"] == "12345678901234567.50"
      assert row.field_values["ratio"] == 1.5
    end

    test "a bad cell is a row error with the line and the header, never the cell text" do
      ctx = tenant_ctx("gh3182-r5b")
      seed_type!(ctx, "item")

      csv = "title,qty\n\"multi\nline\",1\nB,LEAKMARK\nC,3\n"
      conn = csv_import(ctx, "item", csv)
      assert conn.status == 200
      refute conn.resp_body =~ "LEAKMARK"
      assert [ok, bad, ok2] = results(conn)
      assert ok["line"] == 2
      assert bad["line"] == 4
      assert bad["reason"] == %{"type" => "csv_invalid_integer", "header" => "qty"}
      assert ok2["line"] == 5
      assert titles(ctx, "item") == ["C", "multi\nline"]
    end
  end

  describe "R7: upsert mode" do
    test "posting twice leaves one record per reference; missing columns are external_ref_invalid" do
      ctx = tenant_ctx("gh3182-r7")
      seed_type!(ctx, "item")

      csv = "title,external_ref_system,external_ref_id\nA,sap,1\nB,sap,2\n"
      first = csv_import(ctx, "item", csv, "?upsert_by=external_ref")
      assert Enum.map(results(first), & &1["outcome"]) == ["created", "created"]
      assert Enum.map(results(first), & &1["line"]) == [2, 3]

      second = csv_import(ctx, "item", csv, "?upsert_by=external_ref")
      assert Enum.map(results(second), & &1["outcome"]) == ["unchanged", "unchanged"]
      assert length(rows(ctx, "item")) == 2

      bare = csv_import(ctx, "item", "title\nC\n", "?upsert_by=external_ref")

      assert [
               %{
                 "status" => "error",
                 "line" => 2,
                 "reason" => %{"type" => "external_ref_invalid"}
               }
             ] = results(bare)

      assert length(rows(ctx, "item")) == 2
    end

    test "an unknown upsert_by value is the existing 422, whatever the columns" do
      ctx = tenant_ctx("gh3182-r7b")
      seed_type!(ctx, "item")

      conn =
        csv_import(
          ctx,
          "item",
          "title,external_ref_system,external_ref_id\nA,s,1\n",
          "?upsert_by=foo"
        )

      assert conn.status == 422
      assert conn.resp_body =~ "upsert_by must be"
      assert rows(ctx, "item") == []
    end
  end

  describe "R8/R9: INV-10 and the permission gate" do
    test "R8: a type of another tenant answers as a nonexistent type; tenant B is untouched" do
      a = tenant_ctx("gh3182-r8a")
      b = tenant_ctx("gh3182-r8b")
      seed_type!(b, "only_in_b")

      csv = "title\nIntruder\n"
      cross = csv_import(a, "only_in_b", csv)
      missing = csv_import(a, "does_not_exist", csv)

      assert cross.status == 404
      assert missing.status == 404
      assert strip_trace(cross) == strip_trace(missing)
      assert rows(b, "only_in_b") == []

      # a format error cannot reveal the type either
      broken = csv_import(a, "only_in_b", "nope\nx\n")
      assert broken.status == 404
    end

    test "R9: a caller without the import permission is refused as for JSON" do
      ctx = tenant_ctx("gh3182-r9", ["PROCESS_OPERATOR"])
      seed_type!(ctx, "item")

      csv = csv_import(ctx, "item", "title\nA\n")
      json = json_import(ctx, "item", [%{"field_values" => %{"title" => "A"}}])

      assert csv.status == 403
      assert json.status == 403
      assert strip_trace(csv) == strip_trace(json)
      assert rows(ctx, "item") == []
    end
  end

  describe "R10: limits" do
    test "an over-limit body raises the JSON parser's error, nothing is written" do
      ctx = tenant_ctx("gh3182-r10")
      seed_type!(ctx, "item")
      big = "title\n" <> String.duplicate("a", 2_097_153)

      assert too_large_reason(fn -> csv_import(ctx, "item", big) end) ==
               Plug.Parsers.RequestTooLargeError

      json_reason =
        too_large_reason(fn ->
          conn(:post, import_path("item", ""), ~s({"x":"#{big}"}))
          |> put_req_header("content-type", "application/json")
          |> authed(ctx)
        end)

      assert json_reason == Plug.Parsers.RequestTooLargeError

      assert rows(ctx, "item") == []
    end

    test "201 data rows give the 413 of 201 JSON entries" do
      ctx = tenant_ctx("gh3182-r10b")
      seed_type!(ctx, "item")

      csv = "title\n" <> Enum.map_join(1..201, "", &"T#{&1}\n")
      conn = csv_import(ctx, "item", csv)

      json =
        json_import(ctx, "item", for(i <- 1..201, do: %{"field_values" => %{"title" => "T#{i}"}}))

      assert conn.status == 413
      assert json.status == 413
      assert strip_trace(conn) == strip_trace(json)
      assert rows(ctx, "item") == []
    end
  end

  test "R11: the route table row names text/csv and the converter module" do
    row =
      "lib/letflow/routers/entities.ex"
      |> File.read!()
      |> String.split("\n")
      |> Enum.find(&String.starts_with?(&1, "  | import_records |"))

    assert row =~ "text/csv"
    assert row =~ "Letflow.Entities.CsvImport"
  end
end
