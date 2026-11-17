defmodule Letflow.Routers.DocumentsOfficialFormTemplatesTest do
  @moduledoc """
  T-2003/T-2004 / decision 0089 D5, slices S4b/S4c: the nine `/documents/official-form-templates` routes of
  `Letflow.Routers.Documents` and their permission `:OfficialFormTemplatesManage`. Design:
  state/tasks/T-2003/design.md, IDs V1–V4, U1, U2, L1, W1, T1, T2, C1, C2, X1, X2, P1, P2, A1 (R10 is in
  `documents_route_classes_test.exs`).

  `async: false`: provisioned tenants and committed writes.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Letflow.DocumentSqlFixture, only: [exec!: 1, exec!: 2, table: 2]

  alias Letflow.Api.Authorization
  alias Letflow.Api.Authorization.AccessContext
  alias Letflow.Documents.FormTemplate
  alias Letflow.Documents.OfficialFormTemplates, as: OFT
  alias Letflow.FormTemplateDocx, as: D
  alias Letflow.Identity
  alias Letflow.Support.ScopeOnFixture, as: On
  alias Letflow.Support.ScopedGrantsFixture, as: S
  alias Letflow.Support.TokenMintFixture

  @moduletag :tmp_dir

  @router Letflow.Routers.Documents
  @admin "TENANT_ADMIN"
  @perm :OfficialFormTemplatesManage
  @sentinel "SENTINEL-2003-literal"
  @go %{"reason_code" => "go_live"}
  @base "/official-form-templates"
  @meta_keys ~w(id form locale version_no status byte_size sha256 rollback_of created_by activated_by
                activated_at retired_at reason_code inserted_at updated_at)
  @absent "00000000-0000-4000-8000-000000000000"
  @audit_like "document.official_form_template_%"

  setup %{tmp_dir: tmp} do
    {:ok, fx: S.tenant!("t2003-oft"), tmp: tmp}
  end

  # -- helpers -----------------------------------------------------------------------------

  defp docx(extra \\ ""), do: D.valid("z2") |> D.body(extra) |> D.zip()

  defp upload_file(tmp, bytes) do
    path = Path.join(tmp, "t#{System.unique_integer([:positive])}.docx")
    File.write!(path, bytes)
    %Plug.Upload{path: path, filename: "t.docx", content_type: "application/octet-stream"}
  end

  defp call(fx, method, path, body \\ %{}, opts \\ []) do
    On.call(
      @router,
      method,
      @base <> path,
      fx,
      opts[:user] || fx.admin.id,
      opts[:roles] || [@admin],
      :off,
      body
    )
  end

  defp upload(fx, tmp, extra \\ %{}, opts \\ []) do
    body =
      Map.merge(
        %{"form" => "z2", "locale" => "ru", "file" => upload_file(tmp, docx())},
        extra
      )

    call(fx, :post, "", body, opts)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp uploaded!(fx, tmp, extra \\ %{}) do
    conn = upload(fx, tmp, extra)
    assert conn.status == 201
    json(conn)
  end

  defp act(fx, id, action, opts \\ []), do: call(fx, :post, "/#{id}/#{action}", @go, opts)

  defp row_count(fx),
    do:
      exec!("SELECT count(*) FROM #{table(fx.schema_name, "official_form_templates")}").rows
      |> hd()
      |> hd()

  defp audit_actions(fx) do
    %{rows: rows} =
      exec!(
        "SELECT action FROM #{table(fx.schema_name, "audit_entries")} WHERE action LIKE $1 ORDER BY timestamp, id",
        [@audit_like]
      )

    Enum.map(rows, fn [a] -> String.replace_prefix(a, "document.official_form_template_", "") end)
  end

  defp dispatch(conn), do: Letflow.Router.call(conn, Letflow.Router.init([]))

  defp token!(fx, user, roles) do
    {:ok, %{plaintext: plaintext}} =
      Identity.create_token(user.id, %{roles: roles, expires_at: nil}, prefix: fx.schema_name)

    plaintext
  end

  defp real(fx, token, method, path, body \\ nil) do
    conn =
      if body,
        do: conn(method, "/api/v1/documents" <> @base <> path, Jason.encode!(body)),
        else: conn(method, "/api/v1/documents" <> @base <> path)

    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("x-tenant-slug", fx.tenant.slug)
    |> put_req_header("content-type", "application/json")
    |> dispatch()
  end

  defp normalised(conn), do: conn |> json() |> Map.delete("trace_id")

  defmodule ScannerDown do
    def scan(_, _), do: {:error, :down}
  end

  defp document_text(bytes) do
    {:ok, tree} =
      bytes |> D.unpack() |> Map.fetch!("word/document.xml") |> FormTemplate.Xml.parse()

    tree |> FormTemplate.Xml.named("w:t") |> Enum.map(&FormTemplate.Xml.text/1)
  end

  defp scanner(scanner) do
    previous = Application.fetch_env(:letflow, :attachment_scanner)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:letflow, :attachment_scanner, value)
        :error -> Application.delete_env(:letflow, :attachment_scanner)
      end
    end)

    Application.put_env(:letflow, :attachment_scanner, scanner)
  end

  describe "preview" do
    test "V1 filled draft attachment is read only; active and retired also preview", %{
      fx: fx,
      tmp: tmp
    } do
      created = uploaded!(fx, tmp)
      {:ok, stored} = OFT.get(fx.schema_name, created["id"])
      conn = call(fx, :get, "/#{created["id"]}/preview")
      assert conn.status == 200

      assert get_resp_header(conn, "content-type") == [
               "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
             ]

      assert get_resp_header(conn, "content-disposition") == [
               ~s(attachment; filename="z2-ru-v1-preview-ru.docx")
             ]

      assert get_resp_header(conn, "cache-control") == ["no-store"]
      {:ok, expected} = FormTemplate.preview("z2", stored.content, "ru")
      assert document_text(conn.resp_body) == document_text(expected)
      refute Enum.join(document_text(conn.resp_body)) =~ "{{"
      refute conn.resp_body == stored.content
      assert OFT.get(fx.schema_name, created["id"]) == {:ok, stored}
      assert row_count(fx) == 1
      assert audit_actions(fx) == ["uploaded"]

      for action <- ["activate", "retire"] do
        assert act(fx, created["id"], action).status == 200
        before = audit_actions(fx)
        assert call(fx, :get, "/#{created["id"]}/preview").status == 200
        assert audit_actions(fx) == before
      end
    end

    test "V2 language is validated before lookup and respects locale", %{fx: fx, tmp: tmp} do
      default = uploaded!(fx, tmp, %{"locale" => "default"})

      for {query, lang} <- [{"", "ru"}, {"?lang=kk", "kk"}, {"?lang=ru&lang=kk", "kk"}] do
        conn = call(fx, :get, "/#{default["id"]}/preview#{query}")
        assert conn.status == 200

        assert get_resp_header(conn, "content-disposition") == [
                 ~s(attachment; filename="z2-default-v1-preview-#{lang}.docx")
               ]
      end

      for query <- ["lang=en", "lang=", "lang[]=ru"] do
        real = call(fx, :get, "/#{default["id"]}/preview?#{query}")
        absent = call(fx, :get, "/#{@absent}/preview?#{query}")
        assert {real.status, absent.status} == {422, 422}
        assert normalised(real) == normalised(absent)
        assert json(real)["detail"] == "invalid lang"
      end

      for {locale, other} <- [{"ru", "kk"}, {"kk", "ru"}] do
        row = uploaded!(fx, tmp, %{"locale" => locale})
        assert call(fx, :get, "/#{row["id"]}/preview").status == 200
        assert call(fx, :get, "/#{row["id"]}/preview?lang=#{locale}").status == 200
        conn = call(fx, :get, "/#{row["id"]}/preview?lang=#{other}")
        assert conn.status == 422
        assert json(conn)["detail"] == "lang does not match the template locale"
      end
    end

    test "V3 two tenants get identical synthetic text without their identities", %{
      fx: fx,
      tmp: tmp
    } do
      other = S.tenant!("t2004-preview-b")
      mine = uploaded!(fx, tmp)
      theirs = uploaded!(other, tmp)
      a = call(fx, :get, "/#{mine["id"]}/preview?tenant_id=#{other.tenant_id}")
      b = call(other, :get, "/#{theirs["id"]}/preview")
      assert {a.status, b.status} == {200, 200}
      assert document_text(a.resp_body) == document_text(b.resp_body)
      text = Enum.join(document_text(a.resp_body))

      for fixture <- [fx, other],
          record <- [fixture.tenant, fixture.admin],
          key <- [:slug, :display_name, :username, :email],
          value = Map.get(record, key),
          is_binary(value),
          value != "" do
        refute text =~ value
      end
    end

    test "V4 scanner refusal is safe and writes nothing", %{fx: fx, tmp: tmp} do
      created = uploaded!(fx, tmp, %{"file" => upload_file(tmp, docx(@sentinel))})
      {:ok, before} = OFT.get(fx.schema_name, created["id"])
      scanner(ScannerDown)
      conn = call(fx, :get, "/#{created["id"]}/preview")
      assert conn.status == 422
      assert [%{"code" => "scan_unavailable"} = refusal] = json(conn)["refusals"]
      assert Enum.sort(Map.keys(refusal)) == ~w(category code name place rule)
      refute conn.resp_body =~ @sentinel
      assert OFT.get(fx.schema_name, created["id"]) == {:ok, before}
      assert audit_actions(fx) == ["uploaded"]
      assert row_count(fx) == 1
    end
  end

  # -- upload ------------------------------------------------------------------------------

  describe "upload" do
    test "U1 multipart upload stores a draft, server fields are ignored", %{fx: fx, tmp: tmp} do
      conn =
        upload(fx, tmp, %{
          "tenant_id" => Ecto.UUID.generate(),
          "status" => "active",
          "version_no" => 9
        })

      assert conn.status == 201
      body = json(conn)
      assert Map.keys(body) |> Enum.sort() == Enum.sort(["summary" | @meta_keys])
      assert body["status"] == "draft"
      assert body["version_no"] == 1
      assert body["form"] == "z2"
      assert is_map(body["summary"])
      refute Map.has_key?(body, "tenant_id")
      refute Map.has_key?(body, "content")
      assert row_count(fx) == 1
      assert audit_actions(fx) == ["uploaded"]

      assert uploaded!(fx, tmp)["version_no"] == 2
    end

    test "U2 refusals write nothing and leak no template text", %{fx: fx, tmp: tmp} do
      conn = call(fx, :post, "", %{"form" => "z2", "locale" => "ru"})
      assert conn.status == 422
      assert json(conn)["detail"] == ~s(a file part named "file" is required)

      {:ok, keys} = FormTemplate.Keys.for_form("z2")
      bad = D.valid("z2") |> D.remove(hd(keys.data)) |> D.body(@sentinel) |> D.zip()

      conn =
        call(fx, :post, "", %{
          "form" => "z2",
          "locale" => "ru",
          "file" => upload_file(tmp, bad)
        })

      assert conn.status == 422
      refusals = json(conn)["refusals"]
      assert Enum.any?(refusals, &(&1["code"] == "missing_data"))

      assert Enum.all?(
               refusals,
               &(Map.keys(&1) |> Enum.sort() == ~w(category code name place rule))
             )

      refute conn.resp_body =~ @sentinel

      assert upload(fx, tmp, %{"form" => "zz"}) |> then(&{&1.status, json(&1)["detail"]}) ==
               {422, "unknown form"}

      assert upload(fx, tmp, %{"locale" => "en"}) |> then(&{&1.status, json(&1)["detail"]}) ==
               {422, "invalid locale"}

      big = :binary.copy("a", FormTemplate.limits().compressed + 1)

      conn =
        call(fx, :post, "", %{
          "form" => "z2",
          "locale" => "ru",
          "file" => upload_file(tmp, big)
        })

      assert conn.status == 422
      assert [%{"code" => "too_large"}] = json(conn)["refusals"]

      assert row_count(fx) == 0
      assert audit_actions(fx) == []
    end
  end

  # -- list, get, download -----------------------------------------------------------------

  describe "reads" do
    test "L1 list is meta only, filters work, get adds the summary", %{fx: fx, tmp: tmp} do
      v1 = uploaded!(fx, tmp)
      v2 = uploaded!(fx, tmp)
      kk = uploaded!(fx, tmp, %{"locale" => "kk"})

      conn = call(fx, :get, "")
      assert conn.status == 200
      list = json(conn)["templates"]
      assert length(list) == 3

      assert Enum.all?(
               list,
               &(Map.keys(&1) |> Enum.sort() == Enum.sort(@meta_keys))
             )

      ru = Enum.filter(list, &(&1["locale"] == "ru"))
      assert Enum.map(ru, & &1["version_no"]) == [2, 1]
      assert Enum.map(ru, & &1["id"]) == [v2["id"], v1["id"]]

      assert [%{"id" => id}] =
               call(fx, :get, "?form=z2&locale=kk") |> json() |> Map.fetch!("templates")

      assert id == kk["id"]

      conn = call(fx, :get, "/#{v1["id"]}")
      assert conn.status == 200
      got = json(conn)
      assert got["id"] == v1["id"]
      assert is_map(got["summary"])
      refute Map.has_key?(got, "content")
      refute Map.has_key?(got, "tenant_id")
    end

    test "W1 download sends the stored bytes as an attachment", %{fx: fx, tmp: tmp} do
      created = uploaded!(fx, tmp)
      conn = call(fx, :get, "/#{created["id"]}/download")

      assert conn.status == 200

      assert get_resp_header(conn, "content-type") == [
               "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
             ]

      assert get_resp_header(conn, "content-disposition") == [
               ~s(attachment; filename="z2-ru-v1.docx")
             ]

      assert get_resp_header(conn, "cache-control") == ["no-store"]
      {:ok, stored} = OFT.get(fx.schema_name, created["id"])
      assert conn.resp_body == stored.content
    end
  end

  # -- transitions -------------------------------------------------------------------------

  describe "transitions" do
    test "T1 activate, retire and rollback answer and audit once each", %{fx: fx, tmp: tmp} do
      v1 = uploaded!(fx, tmp)
      conn = act(fx, v1["id"], "activate")
      assert conn.status == 200
      assert json(conn)["status"] == "active"
      assert json(conn)["reason_code"] == "go_live"

      v2 = uploaded!(fx, tmp)
      assert act(fx, v2["id"], "activate").status == 200
      assert call(fx, :get, "/#{v1["id"]}") |> json() |> Map.fetch!("status") == "retired"

      conn = act(fx, v1["id"], "rollback")
      assert conn.status == 201
      v3 = json(conn)
      assert v3["version_no"] == 3
      assert v3["rollback_of"] == v1["id"]
      assert v3["sha256"] == v1["sha256"]
      assert v3["status"] == "active"

      conn = act(fx, v3["id"], "retire")
      assert conn.status == 200
      assert json(conn)["status"] == "retired"

      assert audit_actions(fx) ==
               ["uploaded", "activated", "uploaded", "activated", "rolled_back", "retired"]
    end

    test "T2 refusals: reason first, then state; nothing audited", %{fx: fx, tmp: tmp} do
      v1 = uploaded!(fx, tmp)
      before = audit_actions(fx)

      bad = %{"reason_code" => "Bad Reason"}

      assert call(fx, :post, "/#{v1["id"]}/activate", bad)
             |> then(&{&1.status, json(&1)["detail"]}) ==
               {422, "invalid reason_code"}

      assert call(fx, :post, "/#{@absent}/activate", bad)
             |> then(&{&1.status, json(&1)["detail"]}) ==
               {422, "invalid reason_code"}

      assert act(fx, v1["id"], "activate").status == 200
      conn = act(fx, v1["id"], "activate")
      assert {conn.status, json(conn)["detail"]} == {409, "template is not a draft"}

      assert act(fx, v1["id"], "retire").status == 200
      conn = act(fx, v1["id"], "retire")
      assert {conn.status, json(conn)["detail"]} == {409, "template is already retired"}

      draft = uploaded!(fx, tmp)
      conn = act(fx, draft["id"], "rollback")
      assert {conn.status, json(conn)["detail"]} == {409, OFT.conflict_reason(:not_rollbackable)}

      assert audit_actions(fx) == before ++ ["activated", "retired", "uploaded"]
    end
  end

  # -- starter download (T-1983, S5) -----------------------------------------------------------

  describe "starter" do
    test "S1 the admin gets the checked language-free starter as an attachment", %{fx: fx} do
      conn = call(fx, :get, "/starter/da1")
      assert conn.status == 200
      assert [type] = get_resp_header(conn, "content-type")
      assert type =~ "wordprocessingml.document"

      assert get_resp_header(conn, "content-disposition") == [
               ~s(attachment; filename="da1-starter.docx")
             ]

      assert get_resp_header(conn, "cache-control") == ["no-store"]
      {:ok, expected} = FormTemplate.starter("da1")
      assert conn.resp_body == expected
      assert {:ok, _} = FormTemplate.check("da1", conn.resp_body)
    end

    test "S2 an unknown form answers 422 and echoes nothing", %{fx: fx} do
      for form <- ["nope", "%2E%2E", "da1%22x"] do
        conn = call(fx, :get, "/starter/#{form}")
        assert conn.status == 422
        assert json(conn)["detail"] == "unknown form"
        refute conn.resp_body =~ "nope"
        assert get_resp_header(conn, "content-disposition") == []
      end
    end

    test "S3 the auditor and the worker get the same 403 as on the list", %{fx: fx} do
      for role <- ["TENANT_AUDITOR", "TASK_WORKER"] do
        user = TokenMintFixture.role_holder!(fx.schema_name, [role])
        list = call(fx, :get, "", %{}, user: user.id, roles: [role])
        starter = call(fx, :get, "/starter/da1", %{}, user: user.id, roles: [role])
        assert {list.status, starter.status} == {403, 403}
        assert normalised(list) == normalised(starter)
      end
    end

    test "S4 two tenants get byte-identical starters with no tenant data" do
      a = S.tenant!("t1983-oft-a")
      b = S.tenant!("t1983-oft-b")
      ca = call(a, :get, "/starter/z1")
      cb = call(b, :get, "/starter/z1")
      assert {ca.status, cb.status} == {200, 200}
      assert ca.resp_body == cb.resp_body
      refute ca.resp_body =~ a.tenant.slug
      refute ca.resp_body =~ a.schema_name
    end

    test "S5 a path under starter is never read as a template id", %{fx: fx} do
      conn = call(fx, :get, "/starter/download")
      assert conn.status == 422
      assert json(conn)["detail"] == "unknown form"
    end
  end

  # -- tenant isolation --------------------------------------------------------------------

  describe "isolation" do
    test "C1 other-tenant, absent and malformed ids answer the same 404", %{fx: fx, tmp: tmp} do
      other = S.tenant!("t2003-oft-b")
      theirs = uploaded!(other, tmp)

      for {method, suffix, body} <- [
            {:get, "", nil},
            {:get, "/download", nil},
            {:get, "/preview", nil},
            {:post, "/activate", @go},
            {:post, "/retire", @go},
            {:post, "/rollback", @go}
          ] do
        path = fn id -> "/#{id}#{suffix}" end
        reply = fn id -> call(fx, method, path.(id), body || %{}) end
        a = reply.(theirs["id"])
        b = reply.(@absent)
        c = reply.("not-a-uuid")
        assert {a.status, b.status, c.status} == {404, 404, 404}
        assert normalised(a) == normalised(b)
        assert normalised(b) == normalised(c)
      end

      assert call(fx, :get, "") |> json() |> Map.fetch!("templates") == []
      assert call(other, :get, "/#{theirs["id"]}") |> json() |> Map.fetch!("status") == "draft"
    end

    test "C2 no tenant parameter anywhere", %{fx: fx, tmp: tmp} do
      other = S.tenant!("t2003-oft-c")

      rows =
        Letflow.Support.RouteInventory.routes()
        |> Enum.filter(&String.contains?(&1.path, "official-form-templates"))

      assert length(rows) == 9
      refute Enum.any?(rows, &String.contains?(&1.path, "tenant"))

      assert upload(fx, tmp, %{"tenant_id" => other.tenant_id}).status == 201
      assert row_count(fx) == 1
      assert row_count(other) == 0

      listed =
        call(fx, :get, "?tenant_id=#{other.tenant_id}") |> json() |> Map.fetch!("templates")

      assert length(listed) == 1
    end

    test "X1 another tenant's admin token cannot reach a real id", %{fx: fx, tmp: tmp} do
      other = S.tenant!("t2003-oft-d")
      mine = uploaded!(fx, tmp)
      token_a = token!(fx, fx.admin, [@admin])
      token_b = token!(other, other.admin, [@admin])

      # control: the id is real for its own tenant
      assert real(fx, token_a, :get, "/#{mine["id"]}").status == 200

      for {method, suffix, body} <- [
            {:get, "", nil},
            {:get, "/download", nil},
            {:get, "/preview", nil},
            {:post, "/activate", @go},
            {:post, "/retire", @go},
            {:post, "/rollback", @go}
          ] do
        real_id = real(other, token_b, method, "/#{mine["id"]}#{suffix}", body)
        absent = real(other, token_b, method, "/#{@absent}#{suffix}", body)
        assert {real_id.status, absent.status} == {404, 404}
        assert normalised(real_id) == normalised(absent)
      end

      assert call(fx, :get, "/#{mine["id"]}") |> json() |> Map.fetch!("status") == "draft"
      assert audit_actions(fx) == ["uploaded"]
    end

    test "X2 a task worker token is refused on list and upload", %{fx: fx, tmp: tmp} do
      worker = TokenMintFixture.role_holder!(fx.schema_name, ["TASK_WORKER"])
      token = token!(fx, worker, ["TASK_WORKER"])

      list = real(fx, token, :get, "")

      up =
        conn(:post, "/api/v1/documents" <> @base, %{
          "form" => "z2",
          "locale" => "ru",
          "file" => upload_file(tmp, docx())
        })
        |> put_req_header("authorization", "Bearer " <> token)
        |> put_req_header("x-tenant-slug", fx.tenant.slug)
        |> dispatch()

      assert {list.status, up.status} == {403, 403}
      assert normalised(list) == normalised(up)
      assert row_count(fx) == 0
    end
  end

  # -- permission --------------------------------------------------------------------------

  describe "permission" do
    test "P1 holders, scope, grantable" do
      assert Authorization.role_allows?(:TENANT_ADMIN, @perm)
      assert Authorization.role_allows?(:PLATFORM_ADMIN, @perm)

      for role <- Authorization.roles(), role not in [:TENANT_ADMIN, :PLATFORM_ADMIN] do
        refute Authorization.role_allows?(role, @perm), "#{role}"
      end

      key = Authorization.endpoint_policy_key("GET", "/documents/official-form-templates")
      assert key == @perm

      ctx = fn role ->
        %AccessContext{user_id: "u-2003", roles: [role], platform_tenant?: false}
      end

      assert Authorization.evaluate_access(ctx.(:PLATFORM_ADMIN), key).kind == :Deny403
      assert Authorization.evaluate_access(ctx.(:TENANT_ADMIN), key).kind == :Allow
      assert Authorization.evaluate_access(ctx.(:TASK_WORKER), key).kind == :Deny403

      refute Enum.any?(Authorization.grantable() |> Map.values(), &(@perm in &1))
      assert Enum.at(Authorization.core_permissions(), -4) == @perm
      assert Authorization.permission_scope(@perm) == :tenant
      assert Authorization.required_permission(@perm) == @perm
    end

    test "P2 auditor and worker get the same 403 on every route", %{fx: fx, tmp: tmp} do
      mine = uploaded!(fx, tmp)

      for role <- ["TENANT_AUDITOR", "TASK_WORKER"] do
        user = TokenMintFixture.role_holder!(fx.schema_name, [role])

        for {method, suffix, body} <- [
              {:get, "", %{}},
              {:get, "/starter/z2", %{}},
              {:get, "/#{mine["id"]}", %{}},
              {:get, "/#{mine["id"]}/download", %{}},
              {:get, "/#{mine["id"]}/preview", %{}},
              {:post, "", %{}},
              {:post, "/#{mine["id"]}/activate", @go},
              {:post, "/#{@absent}/retire", @go},
              {:post, "/#{mine["id"]}/rollback", @go}
            ] do
          conn = call(fx, method, suffix, body, user: user.id, roles: [role])
          assert conn.status == 403, "#{role} #{method} #{suffix}"
        end
      end

      assert audit_actions(fx) == ["uploaded"]
    end
  end

  # -- audit failure -----------------------------------------------------------------------

  describe "audit failure" do
    test "A1 a failing audit write answers a detail-free 500", %{fx: fx, tmp: tmp} do
      draft = uploaded!(fx, tmp)
      rows = row_count(fx)

      exec!(
        "ALTER TABLE #{table(fx.schema_name, "audit_entries")} ADD CONSTRAINT force_fail CHECK (false) NOT VALID"
      )

      up = upload(fx, tmp)
      assert up.status == 500
      refute up.resp_body =~ "force_fail"
      refute up.resp_body =~ "CHECK"

      conn = act(fx, draft["id"], "activate")
      assert conn.status == 500
      refute conn.resp_body =~ "force_fail"

      assert row_count(fx) == rows
      {:ok, stored} = OFT.get(fx.schema_name, draft["id"])
      assert stored.status == "draft"
    end
  end
end
