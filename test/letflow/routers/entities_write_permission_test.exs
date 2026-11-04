defmodule Letflow.Routers.EntitiesWritePermissionTest do
  @moduledoc """
  REQ-577 / GH #3261 (decision 0070 D2, slice A): the per-type WRITE restriction.

    * W1: each write path (create, update, delete, import create + upsert, attachment upload and
      delete) answers the route-level constant 403 for a user with read access, a restricted type
      and no write grant; nothing is written. With a grant the same requests succeed (W1h).
    * W2: a write grant never opens a TypeAccess-denied type (absent answer) and never opens read.
    * W3: no write-restriction row: unchanged behaviour, both new tables stay empty.
    * W4: the import refuses a module-managed type (managed 403, nothing stored).
    * W5: two tenants: a restriction in A leaves B open; a foreign user id is a 422.
    * W6/W7: the `write_lost` report, permission refusal and the unchanged old response.

  Full pipeline (`Letflow.Router.call/2`, real bearer token), real Postgres, so `async: false`
  with the sandbox pinned to `:auto`.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Records
  alias Letflow.EntityWritesFixture
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.Repository.EntityAttachments
  alias Letflow.TenantFixture
  alias Letflow.Test.SandboxAutoMode

  @schema_version "entities/record-export/v1"
  @boundary "reqw577boundary"
  @forbidden_detail "insufficient permissions"

  setup do
    SandboxAutoMode.enter_auto_mode!(Repo)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)
    :ok
  end

  # ---- helpers -------------------------------------------------------------------------------

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp authed(conn, ctx) do
    conn
    |> put_req_header("authorization", "Bearer " <> ctx.plaintext)
    |> put_req_header("x-tenant-slug", ctx.slug)
  end

  defp request(method, path, ctx, body) do
    case body do
      nil ->
        conn(method, path)

      body ->
        conn(method, path, Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
    end
    |> authed(ctx)
    |> dispatch()
  end

  defp upload_req(path, ctx) do
    body =
      "--#{@boundary}\r\n" <>
        "Content-Disposition: form-data; name=\"file\"; filename=\"note.txt\"\r\n" <>
        "Content-Type: text/plain\r\n\r\n" <>
        "UPLOADED-BYTES\r\n--#{@boundary}--\r\n"

    :post
    |> conn(path, body)
    |> put_req_header("content-type", "multipart/form-data; boundary=#{@boundary}")
    |> authed(ctx)
    |> dispatch()
  end

  defp new_user!(schema_name, status \\ :active) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "req577-user-#{Ecto.UUID.generate()}",
      display_name: "REQ-577 test user",
      email: "req577-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: status,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema_name)
  end

  defp token!(user, schema_name, roles) do
    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: schema_name)

    plaintext
  end

  defp tenant_ctx(slug_prefix, roles \\ ["TENANT_ADMIN"]) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)
    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)
    user = new_user!(tenant.schema_name)

    %{
      schema_name: tenant.schema_name,
      slug: tenant.tenant.slug,
      plaintext: token!(user, tenant.schema_name, roles),
      user_id: user.id
    }
  end

  defp seed_type!(ctx, name) do
    {:ok, _} =
      Definitions.create_definition(
        %{
          definition: %{
            name: name,
            display_name: name,
            fields: [%{name: "title", type: :string, required: true}]
          },
          created_by: ctx.user_id
        },
        ctx.schema_name
      )

    {:ok, _} = Definitions.activate_definition(name, ctx.user_id, "req577", ctx.schema_name)
    :ok
  end

  defp seed_record!(ctx, type) do
    {:ok, %{record: record}} =
      Records.create_record(
        %{
          entity_type: type,
          field_values: %{"title" => "t"},
          actor_id: ctx.user_id,
          idempotency_key: Ecto.UUID.generate()
        },
        ctx.schema_name
      )

    record
  end

  defp seed_attachment!(ctx, type, record_id) do
    {:ok, attachment} =
      EntityAttachments.upload(
        %{
          entity_type: type,
          record_id: record_id,
          raw_bytes: "BYTES",
          file_name: "a.txt",
          content_type: "text/plain",
          uploaded_by: ctx.user_id,
          description: nil
        },
        prefix: ctx.schema_name
      )

    attachment
  end

  defp insert!(ctx, table, row) do
    Repo.insert_all(table, [Map.merge(%{id: Ecto.UUID.bingenerate()}, row)],
      prefix: ctx.schema_name
    )
  end

  defp now, do: NaiveDateTime.utc_now()

  defp write_restrict!(ctx, type),
    do:
      insert!(ctx, "entity_type_write_restrictions", %{
        entity_type: type,
        inserted_at: now(),
        updated_at: now()
      })

  defp write_grant!(ctx, type),
    do:
      insert!(ctx, "user_entity_type_write_grants", %{
        user_id: Ecto.UUID.dump!(ctx.user_id),
        entity_type: type,
        inserted_at: now()
      })

  defp type_restrict!(ctx, type),
    do:
      insert!(ctx, "entity_type_restrictions", %{
        entity_type: type,
        inserted_at: now(),
        updated_at: now()
      })

  defp count(ctx, table), do: Repo.aggregate(table, :count, prefix: ctx.schema_name)

  defp write_counts(ctx) do
    for t <- ~w(events entity_record_latest entity_record_attachments audit_entries), into: %{} do
      {t, count(ctx, t)}
    end
  end

  defp path(type), do: "/api/v1/entities/records/#{type}"
  defp path(type, id), do: "/api/v1/entities/records/#{type}/#{id}"
  defp att_path(type, id), do: path(type, id) <> "/attachments"

  defp import_doc(type, entries),
    do: %{
      "record_export_schema_version" => @schema_version,
      "entity_type" => type,
      "records" => entries
    }

  defp entry(title), do: %{"field_values" => %{"title" => title}}

  defp upsert_entry(id, title),
    do: %{
      "external_ref" => %{"system" => "sap", "id" => id},
      "field_values" => %{"title" => title}
    }

  defp restrictions_path, do: "/api/v1/entities/restrictions/import"

  defp assert_forbidden(conn, label) do
    assert conn.status == 403, "#{label}: #{conn.status} #{conn.resp_body}"
    assert conn.resp_body =~ @forbidden_detail
    conn
  end

  # A tenant with a visible, write-restricted type "widget": the caller has no write grant.
  defp restricted_ctx(slug) do
    ctx = tenant_ctx(slug)
    seed_type!(ctx, "widget")
    record = seed_record!(ctx, "widget")
    attachment = seed_attachment!(ctx, "widget", record.record_id)
    write_restrict!(ctx, "widget")
    {ctx, record.record_id, attachment.id}
  end

  # ---- W1 ------------------------------------------------------------------------------------

  describe "W1: a write-restricted type without a grant refuses every write path" do
    test "W1a create" do
      {ctx, _rid, _aid} = restricted_ctx("req577-w1a")
      before = write_counts(ctx)

      assert_forbidden(
        request(:post, path("widget"), ctx, %{"field_values" => %{"title" => "n"}}),
        "create"
      )

      assert write_counts(ctx) == before
    end

    test "W1b update" do
      {ctx, rid, _aid} = restricted_ctx("req577-w1b")
      before = write_counts(ctx)

      assert_forbidden(
        request(:put, path("widget", rid), ctx, %{"field_values" => %{"title" => "n"}}),
        "update"
      )

      assert write_counts(ctx) == before
    end

    test "W1c delete" do
      {ctx, rid, _aid} = restricted_ctx("req577-w1c")
      before = write_counts(ctx)
      assert_forbidden(request(:delete, path("widget", rid), ctx, nil), "delete")
      # an absent record id gives the same constant 403 (the type is visible to the caller)
      assert_forbidden(
        request(:delete, path("widget", Ecto.UUID.generate()), ctx, nil),
        "delete absent"
      )

      assert write_counts(ctx) == before
    end

    test "W1d import create and upsert" do
      {ctx, _rid, _aid} = restricted_ctx("req577-w1d")
      before = write_counts(ctx)
      p = path("widget") <> "/import"

      assert_forbidden(
        request(:post, p, ctx, import_doc("widget", [entry("A")])),
        "import create"
      )

      upsert =
        import_doc("widget", [upsert_entry("1", "A")]) |> Map.put("upsert_by", "external_ref")

      assert_forbidden(request(:post, p, ctx, upsert), "import upsert")
      assert write_counts(ctx) == before
    end

    test "W1e attachment upload" do
      {ctx, rid, _aid} = restricted_ctx("req577-w1e")
      before = write_counts(ctx)
      assert_forbidden(upload_req(att_path("widget", rid), ctx), "upload")
      assert write_counts(ctx) == before
    end

    test "W1f attachment delete; list and content stay readable" do
      {ctx, rid, aid} = restricted_ctx("req577-w1f")
      before = write_counts(ctx)

      assert_forbidden(
        request(:delete, att_path("widget", rid) <> "/#{aid}", ctx, nil),
        "att delete"
      )

      assert write_counts(ctx) == before

      listed = request(:get, att_path("widget", rid), ctx, nil)
      assert listed.status == 200
      assert [_one] = Jason.decode!(listed.resp_body)["items"]
    end

    test "W1g reads of the record are unaffected" do
      {ctx, _rid, _aid} = restricted_ctx("req577-w1g")
      q = request(:post, "/api/v1/entities/query", ctx, %{"entity_type" => "widget"})
      assert q.status == 200
      assert [_one] = Jason.decode!(q.resp_body)["items"]
    end

    test "W1h with a write grant the same requests succeed" do
      {ctx, rid, aid} = restricted_ctx("req577-w1h")
      write_grant!(ctx, "widget")

      assert request(:post, path("widget"), ctx, %{"field_values" => %{"title" => "n"}}).status ==
               201

      assert request(:put, path("widget", rid), ctx, %{"field_values" => %{"title" => "u"}}).status ==
               200

      imp = request(:post, path("widget") <> "/import", ctx, import_doc("widget", [entry("A")]))
      assert imp.status == 200

      assert upload_req(att_path("widget", rid), ctx).status == 201
      assert request(:delete, att_path("widget", rid) <> "/#{aid}", ctx, nil).status in [200, 204]
      assert request(:delete, path("widget", rid), ctx, nil).status in [200, 204]
    end
  end

  # ---- W2 ------------------------------------------------------------------------------------

  describe "W2: a write grant never opens read" do
    test "grant on a TypeAccess-denied type is the absent answer; reads still follow TypeAccess" do
      ctx = tenant_ctx("req577-w2")
      absent = tenant_ctx("req577-w2a")
      seed_type!(ctx, "widget")
      type_restrict!(ctx, "widget")
      write_restrict!(ctx, "widget")
      write_grant!(ctx, "widget")

      body = %{"field_values" => %{"title" => "n"}}
      d = request(:post, path("widget"), ctx, body)
      a = request(:post, path("widget"), absent, body)
      assert d.status == 404

      assert Jason.decode!(d.resp_body) |> Map.delete("trace_id") ==
               Jason.decode!(a.resp_body) |> Map.delete("trace_id")

      # reads follow TypeAccess only: the query answers exactly as for an absent type
      q = request(:post, "/api/v1/entities/query", ctx, %{"entity_type" => "widget"})
      qa = request(:post, "/api/v1/entities/query", absent, %{"entity_type" => "widget"})
      assert q.status == qa.status
      assert Jason.decode!(q.resp_body)["items"] == Jason.decode!(qa.resp_body)["items"]
    end
  end

  # ---- W3 ------------------------------------------------------------------------------------

  describe "W3: default unchanged" do
    test "no write-restriction row: writes behave as before and the new tables stay empty" do
      ctx = tenant_ctx("req577-w3")
      seed_type!(ctx, "widget")
      seed_type!(ctx, "gadget")
      # a TypeAccess restriction with a type grant still lets the grantee write
      type_restrict!(ctx, "gadget")

      insert!(ctx, "user_entity_type_grants", %{
        user_id: Ecto.UUID.dump!(ctx.user_id),
        entity_type: "gadget",
        inserted_at: now()
      })

      body = %{"field_values" => %{"title" => "n"}}
      assert request(:post, path("widget"), ctx, body).status == 201
      assert request(:post, path("gadget"), ctx, body).status == 201
      assert count(ctx, "entity_type_write_restrictions") == 0
      assert count(ctx, "user_entity_type_write_grants") == 0
      assert count(ctx, "entity_type_restrictions") == 1
      assert count(ctx, "user_entity_type_grants") == 1
    end

    test "a restriction on one type leaves another type writable" do
      ctx = tenant_ctx("req577-w3b")
      seed_type!(ctx, "widget")
      seed_type!(ctx, "gadget")
      write_restrict!(ctx, "widget")
      body = %{"field_values" => %{"title" => "n"}}
      assert_forbidden(request(:post, path("widget"), ctx, body), "restricted")
      assert request(:post, path("gadget"), ctx, body).status == 201
    end
  end

  # ---- W4 ------------------------------------------------------------------------------------

  describe "W4: managed types" do
    test "the import refuses write lists naming a module-managed type; nothing is stored" do
      ctx = tenant_ctx("req577-w4")
      EntityWritesFixture.install_managed_fixture!(ctx.schema_name)
      seed_type!(ctx, "widget")

      body = %{
        "write_restrictions" => [%{"entity_type" => "widget"}, %{"entity_type" => "fxm_unit"}],
        "write_grants" => [%{"user_id" => ctx.user_id, "entity_type" => "fxm_unit"}]
      }

      conn = request(:post, restrictions_path(), ctx, body)
      assert conn.status == 403
      refute conn.resp_body =~ @forbidden_detail
      assert count(ctx, "entity_type_write_restrictions") == 0
      assert count(ctx, "user_entity_type_write_grants") == 0
    end
  end

  # ---- W5 ------------------------------------------------------------------------------------

  describe "W5: two tenants" do
    test "a restriction in A leaves B open; a foreign user id is refused; no tenant_id column" do
      a = tenant_ctx("req577-w5a")
      b = tenant_ctx("req577-w5b")
      for c <- [a, b], do: seed_type!(c, "widget")
      write_restrict!(a, "widget")

      body = %{"field_values" => %{"title" => "n"}}
      assert_forbidden(request(:post, path("widget"), a, body), "tenant A")
      assert request(:post, path("widget"), b, body).status == 201

      foreign = %{"write_grants" => [%{"user_id" => a.user_id, "entity_type" => "widget"}]}
      conn = request(:post, restrictions_path(), b, foreign)
      assert conn.status == 422
      assert count(b, "user_entity_type_write_grants") == 0

      cols =
        Repo.query!(
          "SELECT table_schema, column_name FROM information_schema.columns " <>
            "WHERE table_name IN ('entity_type_write_restrictions','user_entity_type_write_grants')"
        ).rows

      assert cols != []
      refute Enum.any?(cols, fn [_s, c] -> c == "tenant_id" end)
      refute Enum.any?(cols, fn [s, _c] -> s == "public" end)
    end
  end

  # ---- W6 / W7 -------------------------------------------------------------------------------

  describe "W6: import report and permission" do
    test "write_lost lists active users without a grant, not the granted, inactive or hidden ones" do
      ctx = tenant_ctx("req577-w6")
      seed_type!(ctx, "widget")
      granted = new_user!(ctx.schema_name)
      inactive = new_user!(ctx.schema_name, :inactive)
      hidden = new_user!(ctx.schema_name)
      plain = new_user!(ctx.schema_name)
      type_restrict!(ctx, "widget")

      for u <- [ctx.user_id, granted.id, inactive.id, plain.id],
          do:
            insert!(ctx, "user_entity_type_grants", %{
              user_id: Ecto.UUID.dump!(u),
              entity_type: "widget",
              inserted_at: now()
            })

      body = %{
        "write_restrictions" => [%{"entity_type" => "widget"}],
        "write_grants" => [%{"user_id" => granted.id, "entity_type" => "widget"}]
      }

      conn = request(:post, restrictions_path(), ctx, body)
      assert conn.status == 200
      resp = Jason.decode!(conn.resp_body)
      data = resp["data"] || resp
      assert data["inserted"]["write_restrictions"] == 1
      assert data["inserted"]["write_grants"] == 1
      assert data["write_lost_truncated"] == false
      [%{"entity_type" => "widget", "user_ids" => ids}] = data["write_lost"]
      assert Enum.sort(ids) == Enum.sort([ctx.user_id, plain.id])
      refute hidden.id in ids
      refute granted.id in ids
      refute inactive.id in ids

      # re-posting the same restriction reports nothing new
      again = request(:post, restrictions_path(), ctx, Map.delete(body, "write_grants"))
      again_data = Jason.decode!(again.resp_body)
      again_data = again_data["data"] || again_data
      assert again_data["write_lost"] == []
      assert again_data["inserted"]["write_restrictions"] == 0
    end

    test "a role without EntitiesRestrictionsManage is refused and nothing is stored" do
      ctx = tenant_ctx("req577-w6p", ["PROCESS_DESIGNER"])
      body = %{"write_restrictions" => [%{"entity_type" => "widget"}]}
      assert request(:post, restrictions_path(), ctx, body).status == 403
      assert count(ctx, "entity_type_write_restrictions") == 0
    end

    test "W7 a request without the new keys keeps the old response; a bad row inserts nothing" do
      ctx = tenant_ctx("req577-w7")

      ok =
        request(:post, restrictions_path(), ctx, %{
          "type_restrictions" => [%{"entity_type" => "x"}]
        })

      assert ok.status == 200
      data = Jason.decode!(ok.resp_body)
      data = data["data"] || data

      assert Map.keys(data["inserted"]) |> Enum.sort() ==
               ~w(field_grants field_restrictions type_grants type_restrictions)

      refute Map.has_key?(data, "write_lost")

      bad = %{
        "write_restrictions" => [%{"entity_type" => "y"}],
        "write_grants" => [%{"user_id" => "nope", "entity_type" => "y"}]
      }

      assert request(:post, restrictions_path(), ctx, bad).status == 422
      assert count(ctx, "entity_type_write_restrictions") == 0
    end
  end
end
