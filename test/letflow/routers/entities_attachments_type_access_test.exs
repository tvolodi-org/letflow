defmodule Letflow.Routers.EntitiesAttachmentsTypeAccessTest do
  @moduledoc """
  GH #2784 PR B (design `lib/letflow/design/gh2784-write-routes-typeaccess.md` sections 7, 10):
  the four record ATTACHMENT routes honour TypeAccess, and a type denied to the caller answers
  byte-identically to an ABSENT one.

    * T1: well-formed upload / list / content GET / delete on a denied type (with a real record
      and a real attachment) equal the answers of a tenant where the type does not exist.
    * T2: malformed requests (missing file part, bad record id, bad page size / cursor) give the
      same answer for a denied and an absent type: validation runs first in both cases.
    * T3: a VISIBLE type with an absent record or attachment gives the same answer as a denied
      type (denied == absent == visible-type-absent-record).
    * T4: a denied upload / delete writes and removes nothing (attachment, artifact, event and
      audit rows are counted), and a denied content GET never reads `repository_artifacts`.
    * T5: an allowed caller (no restriction rows, or unrelated ones) is unchanged.

  Full pipeline (`Letflow.Router.call/2`, real bearer token and multipart parse), real Postgres,
  real commits, so `async: false` with the sandbox pinned to `:auto` for the whole test.
  """

  use Letflow.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Records
  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.Repository.EntityAttachments
  alias Letflow.TenantFixture
  alias Letflow.Test.SandboxAutoMode

  @boundary "gh2784bboundary"
  @bytes "TOP-SECRET-ATTACHMENT-BYTES"

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

  defp get_req(path, ctx), do: :get |> conn(path) |> authed(ctx) |> dispatch()
  defp delete_req(path, ctx), do: :delete |> conn(path) |> authed(ctx) |> dispatch()

  defp upload_req(path, ctx, file_part \\ :file) do
    name = if file_part == :file, do: "file", else: "notfile"

    body =
      "--#{@boundary}\r\n" <>
        "Content-Disposition: form-data; name=\"#{name}\"; filename=\"note.txt\"\r\n" <>
        "Content-Type: text/plain\r\n\r\n" <>
        "UPLOADED-BYTES\r\n--#{@boundary}--\r\n"

    :post
    |> conn(path, body)
    |> put_req_header("content-type", "multipart/form-data; boundary=#{@boundary}")
    |> authed(ctx)
    |> dispatch()
  end

  defp tenant_ctx(slug_prefix) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)
    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "gh2784b-user-#{Ecto.UUID.generate()}",
        display_name: "GH-2784 PR B test user",
        email: "gh2784b-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: tenant.schema_name)

    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: ["TENANT_ADMIN"], expires_at: nil},
        prefix: tenant.schema_name
      )

    %{
      schema_name: tenant.schema_name,
      slug: tenant.tenant.slug,
      plaintext: plaintext,
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

    {:ok, _} = Definitions.activate_definition(name, ctx.user_id, "gh2784b", ctx.schema_name)
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

  defp upload_direct!(ctx, type, record_id) do
    {:ok, attachment} =
      EntityAttachments.upload(
        %{
          entity_type: type,
          record_id: record_id,
          raw_bytes: @bytes,
          file_name: "secret.txt",
          content_type: "text/plain",
          uploaded_by: ctx.user_id,
          description: nil
        },
        prefix: ctx.schema_name
      )

    attachment
  end

  defp insert_type_restriction!(ctx, type) do
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

  # status, the stable headers, and the decoded body without the per-request trace id.
  defp norm(conn) do
    headers =
      conn.resp_headers
      |> Enum.reject(fn {name, _} -> name =~ ~r/id|trace|date|time/ end)
      |> Enum.sort()

    body =
      case Jason.decode(conn.resp_body) do
        {:ok, %{} = map} -> Map.delete(map, "trace_id")
        _ -> conn.resp_body
      end

    {conn.status, headers, body}
  end

  defp counts(ctx) do
    for table <-
          ~w(entity_record_attachments repository_artifacts events entity_record_latest audit_entries),
        into: %{} do
      {table, Repo.aggregate(table, :count, prefix: ctx.schema_name)}
    end
  end

  defp list_path(type, id), do: "/api/v1/entities/records/#{type}/#{id}/attachments"
  defp item_path(type, id, att), do: list_path(type, id) <> "/#{att}"

  # D: type "widget" restricted with no grant for the caller, one real record + one real
  # attachment. A: a tenant where the type does not exist at all. Same path and body to both.
  defp denied_and_absent(slug) do
    denied = tenant_ctx("#{slug}-d")
    seed_type!(denied, "widget")
    record = seed_record!(denied, "widget")
    attachment = upload_direct!(denied, "widget", record.record_id)
    insert_type_restriction!(denied, "widget")

    absent = tenant_ctx("#{slug}-a")
    {denied, absent, record.record_id, attachment.id}
  end

  # ---- T1 ------------------------------------------------------------------------------------

  describe "T1: a well-formed request to a denied type equals the absent type's answer" do
    test "upload 404" do
      {denied, absent, rid, _aid} = denied_and_absent("gh2784b-t1u")
      d = upload_req(list_path("widget", rid), denied)
      a = upload_req(list_path("widget", rid), absent)
      assert d.status == 404, "denied upload: #{d.status} #{d.resp_body}"
      assert norm(d) == norm(a)
    end

    test "list is the 200 empty page" do
      {denied, absent, rid, _aid} = denied_and_absent("gh2784b-t1l")
      d = get_req(list_path("widget", rid), denied)
      a = get_req(list_path("widget", rid), absent)
      assert {200, _, %{"items" => [], "next_cursor" => nil}} = norm(d)
      assert norm(d) == norm(a)
    end

    test "content GET 404 with no bytes" do
      {denied, absent, rid, aid} = denied_and_absent("gh2784b-t1c")
      d = get_req(item_path("widget", rid, aid), denied)
      a = get_req(item_path("widget", rid, aid), absent)
      assert d.status == 404, "denied content: #{d.status}"
      refute d.resp_body =~ @bytes
      assert norm(d) == norm(a)
    end

    test "delete 404 and the attachment survives" do
      {denied, absent, rid, aid} = denied_and_absent("gh2784b-t1d")
      before = counts(denied)
      d = delete_req(item_path("widget", rid, aid), denied)
      a = delete_req(item_path("widget", rid, aid), absent)
      assert d.status == 404, "denied delete: #{d.status}"
      assert norm(d) == norm(a)
      assert counts(denied) == before
      assert {:ok, _} = EntityAttachments.get(aid, prefix: denied.schema_name)
    end
  end

  # ---- T2 ------------------------------------------------------------------------------------

  describe "T2: validation precedes the hidden answer exactly as for an absent type" do
    test "malformed requests give the same answer for a denied and an absent type" do
      {denied, absent, rid, aid} = denied_and_absent("gh2784b-t2")

      cases = [
        {:post, list_path("widget", rid), :nofile, 422},
        {:post, list_path("widget", "not-a-uuid"), :file, 404},
        {:get, list_path("widget", "not-a-uuid"), nil, 404},
        {:get, list_path("widget", rid) <> "?page_size=abc", nil, 400},
        {:get, list_path("widget", rid) <> "?page_size=99999", nil, 400},
        {:get, list_path("widget", rid) <> "?cursor=garbage", nil, nil},
        {:get, item_path("widget", "not-a-uuid", aid), nil, 404},
        {:get, item_path("widget", rid, "not-a-uuid"), nil, 404},
        {:delete, item_path("widget", "not-a-uuid", aid), nil, 404},
        {:delete, item_path("widget", rid, "not-a-uuid"), nil, 404}
      ]

      for {method, p, kind, expected} <- cases do
        {d, a} =
          case method do
            :post -> {upload_req(p, denied, kind), upload_req(p, absent, kind)}
            :get -> {get_req(p, denied), get_req(p, absent)}
            :delete -> {delete_req(p, denied), delete_req(p, absent)}
          end

        if expected, do: assert(a.status == expected, "absent #{method} #{p}: #{a.status}")
        assert norm(d) == norm(a), "#{method} #{p}: denied differs from absent"
      end
    end
  end

  # ---- T3 ------------------------------------------------------------------------------------

  describe "T3: denied == absent == visible type with an absent record / attachment" do
    test "every route" do
      {denied, absent, rid, aid} = denied_and_absent("gh2784b-t3")
      visible = tenant_ctx("gh2784b-t3v")
      seed_type!(visible, "widget")
      # an unrelated restriction row must not change anything
      insert_type_restriction!(visible, "other")

      for fun <- [
            fn ctx -> upload_req(list_path("widget", rid), ctx) end,
            fn ctx -> get_req(list_path("widget", rid), ctx) end,
            fn ctx -> get_req(item_path("widget", rid, aid), ctx) end,
            fn ctx -> delete_req(item_path("widget", rid, aid), ctx) end
          ] do
        d = fun.(denied)
        a = fun.(absent)
        v = fun.(visible)
        assert norm(d) == norm(a)
        assert norm(d) == norm(v)
      end
    end
  end

  # ---- T4 ------------------------------------------------------------------------------------

  describe "T4: no side effects on a denied request" do
    test "upload creates no attachment, artifact, event or audit row" do
      {denied, _absent, rid, _aid} = denied_and_absent("gh2784b-t4")
      before = counts(denied)
      assert upload_req(list_path("widget", rid), denied).status == 404
      assert counts(denied) == before
    end

    test "a denied content GET issues no repository_artifacts query" do
      {denied, _absent, rid, aid} = denied_and_absent("gh2784b-t4c")

      queries =
        recorded_queries(fn -> get_req(item_path("widget", rid, aid), denied) end)

      refute Enum.any?(queries, &(&1 =~ "repository_artifacts")), inspect(queries)
    end
  end

  # ---- T5 ------------------------------------------------------------------------------------

  describe "T5: an allowed caller is unchanged" do
    test "upload, list, content, delete with an unrelated restriction row" do
      ctx = tenant_ctx("gh2784b-t5")
      seed_type!(ctx, "widget")
      record = seed_record!(ctx, "widget")
      insert_type_restriction!(ctx, "other")
      p = list_path("widget", record.record_id)

      created = upload_req(p, ctx)
      assert created.status == 201, created.resp_body
      %{"id" => id} = Jason.decode!(created.resp_body)

      listed = get_req(p, ctx)
      assert listed.status == 200
      assert [%{"id" => ^id}] = Jason.decode!(listed.resp_body)["items"]

      content = get_req(p <> "/#{id}", ctx)
      assert content.status == 200
      assert content.resp_body == "UPLOADED-BYTES"

      assert delete_req(p <> "/#{id}", ctx).status == 204
      assert get_req(p <> "/#{id}", ctx).status == 404
    end
  end

  defp recorded_queries(fun) do
    parent = self()
    handler = "gh2784b-queries-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      Repo.config()[:telemetry_prefix] ++ [:query],
      fn _event, _measurements, metadata, _config ->
        if self() == parent, do: send(parent, {:query, Map.get(metadata, :query, "")})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    drain_queries([])
  end

  defp drain_queries(acc) do
    receive do
      {:query, q} -> drain_queries([q | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
