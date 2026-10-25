defmodule Letflow.Routers.NotificationTemplatesTest do
  @moduledoc """
  REQ-563 / GH #3199 -- `Letflow.Routers.NotificationTemplates` through its own `call/2` (the real
  Authorize plug), over provisioned tenant schemas. IDs follow T-0518's design: S storage,
  R registry, P placeholders, N secrets, L text and locale rules, AU audit, V preview,
  X cross-tenant, F uniform 403, Q source scans.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit.Entry
  alias Letflow.NotificationTemplates
  alias Letflow.NotificationTemplates.Template
  alias Letflow.TenantFixture

  @opts Letflow.Routers.NotificationTemplates.init([])
  @key "task_assigned"

  defp tenant!, do: TenantFixture.provisioned_tenant!(slug_prefix: "req563")

  defp call(method, path, t, opts) do
    conn(method, path)
    |> Map.put(:body_params, Keyword.get(opts, :body, %{}))
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{
      user_id: Keyword.get(opts, :user_id, Ecto.UUID.generate()),
      tenant_id: t.tenant_id,
      roles: Keyword.get(opts, :roles, ["TENANT_ADMIN"])
    })
    |> assign(:trace_id, "req563-trace")
    |> Letflow.Routers.NotificationTemplates.call(@opts)
  end

  defp put(t, key, locale, subject, body, opts \\ []),
    do:
      call(
        :put,
        "/#{key}",
        t,
        [body: %{"locale" => locale, "subject" => subject, "body" => body}] ++ opts
      )

  defp del(t, key, locale, opts \\ []),
    do: call(:delete, "/#{key}?locale=#{locale}", t, opts)

  defp list(t, opts \\ []) do
    conn = call(:get, "/", t, opts)
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp preview(t, key, body, opts \\ []) do
    conn = call(:post, "/#{key}/preview", t, [body: body] ++ opts)
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp rows(t), do: Repo.all(Template, prefix: t.schema_name)

  describe "storage (S1..S3) and registry (R2, R3)" do
    test "S1 a template of tenant A is in A's table only; B lists none" do
      a = tenant!()
      b = tenant!()
      assert put(a, @key, "ru", "Subj {task_name}", "Body").status == 201
      assert [%{template_key: @key, locale: "ru", tenant_id: tid}] = rows(a)
      assert tid == a.tenant_id
      assert rows(b) == []
      assert {200, %{"templates" => []}} = list(b)
      assert {200, %{"templates" => [%{"locale" => "ru"}]}} = list(a)
    end

    test "S2 second PUT of one pair replaces (200) and keeps one row; a new pair is 201" do
      t = tenant!()
      assert put(t, @key, "ru", "One", "Body").status == 201
      conn = put(t, @key, "ru", "Two", "Body 2")
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["subject"] == "Two"
      assert [%{subject: "Two", body: "Body 2"}] = rows(t)
      assert put(t, @key, "en", "One", "Body").status == 201
      assert length(rows(t)) == 2
    end

    test "S3 the unique index refuses a direct duplicate insert" do
      t = tenant!()
      assert put(t, @key, "ru", "One", "Body").status == 201

      row = %Template{
        tenant_id: t.tenant_id,
        template_key: @key,
        locale: "ru",
        subject: "x",
        body: "y"
      }

      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(
          %{
            row
            | id: Ecto.UUID.generate(),
              inserted_at: DateTime.utc_now(),
              updated_at: DateTime.utc_now()
          },
          prefix: t.schema_name
        )
      end
    end

    test "R2 an unregistered key is 404 and stores nothing; R3 DELETE of it is the same 404" do
      t = tenant!()
      conn = put(t, "other_key", "ru", "x", "y")
      assert conn.status == 404
      assert rows(t) == []
      assert del(t, "other_key", "ru").status == 404
      assert del(t, @key, "ru").status == 404
      assert del(t, "other_key", "ru").resp_body == del(t, @key, "ru").resp_body
    end
  end

  describe "placeholders (P) and secrets (N)" do
    setup do: {:ok, t: tenant!()}

    test "P1..P7 unknown, secret-shaped, malformed and ICU placeholders are 422", %{t: t} do
      bad = [
        "{password}",
        "{api_key}",
        "{secret_ref}",
        "{tenant_id}",
        "{",
        "}",
        "{}",
        "{Task_name}",
        "{task_name1}",
        "{n, plural, one {a} other {b}}"
      ]

      for text <- bad do
        assert put(t, @key, "ru", "S", "Hi " <> text).status == 422, "body #{text}"
        assert put(t, @key, "ru", text <> " S", "Body").status == 422, "subject #{text}"
      end

      assert rows(t) == []
    end

    test "P8 allow-listed, none and repeated placeholders are accepted", %{t: t} do
      assert put(t, @key, "ru", "{task_name} {task_name}", "{assignee_name} {due_date}").status ==
               201

      assert put(t, @key, "en", "plain", "plain body").status == 201
    end

    test "N2/N3 a sec:// reference or {secret_ref} is refused and nothing is stored", %{t: t} do
      assert put(t, @key, "ru", "S", "see sec://tenant/a/b/c#1").status == 422
      assert put(t, @key, "ru", "SEC://tenant/a/b/c#1", "B").status == 422
      assert put(t, @key, "ru", "S", "{secret_ref}").status == 422
      assert rows(t) == []
    end

    test "N5 a sample value that looks like a placeholder is output literally", %{t: t} do
      assert {200, body} =
               preview(t, @key, %{
                 "locale" => "ru",
                 "subject" => "Hi {tenant_name}",
                 "body" => "B {tenant_name}",
                 "values" => %{"tenant_name" => "{task_name}", "task_name" => "T"}
               })

      assert body["subject"] == "Hi {task_name}"
      assert body["body"] == "B {task_name}"
    end
  end

  describe "text and locale rules (L)" do
    setup do: {:ok, t: tenant!()}

    test "L1/L2 length limits", %{t: t} do
      assert put(t, @key, "ru", String.duplicate("a", 201), "b").status == 422
      assert put(t, @key, "ru", String.duplicate("a", 200), "b").status == 201
      assert put(t, @key, "en", "s", String.duplicate("b", 5001)).status == 422
      assert put(t, @key, "en", "s", String.duplicate("b", 5000)).status == 201
    end

    test "L3 empty and whitespace-only text", %{t: t} do
      for bad <- ["", "  \t ", nil] do
        assert put(t, @key, "ru", bad, "b").status == 422
        assert put(t, @key, "ru", "s", bad).status == 422
      end
    end

    test "L4/L5 newline is allowed in the body only; tab and CR never", %{t: t} do
      assert put(t, @key, "ru", "s", "line one\nline two").status == 201
      assert put(t, @key, "ru", "a\nb", "b").status == 422
      assert put(t, @key, "ru", "a\tb", "b").status == 422
      assert put(t, @key, "ru", "s", "a\tb").status == 422
      assert put(t, @key, "ru", "s", "a\r\nb").status == 422
    end

    test "L6 locale shape", %{t: t} do
      for bad <- ["RU", "rusx-RU", "ru-rr", "r", "ru_RU", nil] do
        assert put(t, @key, bad, "s", "b").status == 422, inspect(bad)
      end

      for ok <- ["ru", "kk-KZ", "de"] do
        assert put(t, @key, ok, "s", "b").status == 201, ok
      end
    end
  end

  describe "preview (V)" do
    setup do: {:ok, t: tenant!()}

    @values %{
      "task_name" => "Check",
      "assignee_name" => "Ann",
      "process_name" => "P",
      "due_date" => "d",
      "tenant_name" => "Acme"
    }

    test "V1 stored text is rendered with the values; V5 repeats equal", %{t: t} do
      put(t, @key, "ru", "Hi {assignee_name}", "Task {task_name} for {tenant_name}")
      req = %{"locale" => "ru", "values" => @values}
      assert {200, body} = preview(t, @key, req)
      assert body["subject"] == "Hi Ann"
      assert body["body"] == "Task Check for Acme"
      assert body["source"] == "stored"
      assert {200, ^body} = preview(t, @key, req)
    end

    test "V2 no stored row renders the platform default", %{t: t} do
      assert {200, body} = preview(t, @key, %{"locale" => "de", "values" => @values})
      assert body["source"] == "default"
      assert body["subject"] == "Task assigned: Check"
      assert body["body"] =~ "Hello Ann"
    end

    test "V3 request text is rendered and nothing is written; V4 missing value is empty", %{t: t} do
      assert {200, body} =
               preview(t, @key, %{
                 "locale" => "ru",
                 "subject" => "A {task_name}|{due_date}",
                 "body" => "B",
                 "values" => %{"task_name" => "X"}
               })

      assert body["subject"] == "A X|"
      assert body["source"] == "request"
      assert rows(t) == []
    end

    test "V3b request text is validated like a PUT; bad values are 422", %{t: t} do
      assert {422, _} = preview(t, @key, %{"locale" => "ru", "subject" => "{password}"})
      assert {422, _} = preview(t, @key, %{"locale" => "ru", "body" => "sec://tenant/a/b/c#1"})
      assert {422, _} = preview(t, @key, %{"locale" => "ru", "values" => "x"})
      assert {422, _} = preview(t, @key, %{"locale" => "ru", "values" => %{"task_name" => 5}})

      assert {422, _} =
               preview(t, @key, %{
                 "locale" => "ru",
                 "values" => %{"task_name" => String.duplicate("a", 501)}
               })

      assert {404, _} = preview(t, "other_key", %{"locale" => "ru"})
    end

    test "V3c only the given field comes from the request, the other from the store", %{t: t} do
      put(t, @key, "ru", "Stored subject", "Stored body")
      assert {200, body} = preview(t, @key, %{"locale" => "ru", "subject" => "Own"})
      assert body["subject"] == "Own"
      assert body["body"] == "Stored body"
      assert {200, body} = preview(t, @key, %{"locale" => "de", "body" => "Own body"})
      assert body["subject"] == "Task assigned: "
      assert body["body"] == "Own body"
    end

    test "V6 after DELETE the preview returns the default", %{t: t} do
      put(t, @key, "ru", "Mine", "Mine body")
      assert del(t, @key, "ru").status == 204
      assert {200, %{"source" => "default"}} = preview(t, @key, %{"locale" => "ru"})
    end

    test "V7 unknown sample keys are ignored and never echoed", %{t: t} do
      assert {200, body} =
               preview(t, @key, %{
                 "locale" => "ru",
                 "values" => %{"password" => "hunter2", "task_name" => "T"}
               })

      refute inspect(body) =~ "hunter2"
    end
  end

  describe "audit (AU)" do
    test "AU1 PUT and DELETE each write one entry without the text; AU2 refusals none" do
      t = tenant!()
      actor = Ecto.UUID.generate()
      put(t, @key, "ru", "Secret-ish subject", "Secret-ish body", user_id: actor)
      put(t, @key, "ru", "{password}", "b", user_id: actor)
      put(t, @key, "ru", "s", "b", roles: ["TASK_WORKER"])
      del(t, @key, "ru", user_id: actor)
      del(t, @key, "ru", user_id: actor)

      entries = Repo.all(from(e in Entry, order_by: e.timestamp), prefix: t.schema_name)

      assert Enum.map(entries, & &1.action) ==
               ["notification_templates.put", "notification_templates.delete"]

      assert Enum.all?(entries, &(&1.actor_id == actor and &1.resource_id == "#{@key}:ru"))
      assert hd(entries).after_state == %{"template_key" => @key, "locale" => "ru"}
      refute inspect(entries) =~ "Secret-ish"
    end
  end

  describe "permissions (A2), cross-tenant (X) and uniform 403 (F1)" do
    test "A2 TENANT_ADMIN passes; other roles and no-permission callers get 403 on all four" do
      t = tenant!()
      assert put(t, @key, "ru", "s", "b").status == 201

      for role <- ["TASK_WORKER", "PROCESS_DESIGNER", "TENANT_AUDITOR", "PLATFORM_ADMIN"] do
        assert put(t, @key, "ru", "x", "y", roles: [role]).status == 403, role
        assert del(t, @key, "ru", roles: [role]).status == 403, role
        assert call(:get, "/", t, roles: [role]).status == 403, role

        assert call(:post, "/#{@key}/preview", t, roles: [role], body: %{"locale" => "ru"}).status ==
                 403,
               role
      end

      assert [%{subject: "s"}] = rows(t)
    end

    test "X1..X3 tenant B cannot read or change A's templates; tenant_id input is ignored" do
      a = tenant!()
      b = tenant!()
      put(a, @key, "ru", "A wording", "A body")

      assert {200, %{"templates" => []}} = list(b)
      assert {200, %{"source" => "default"} = prev} = preview(b, @key, %{"locale" => "ru"})
      refute inspect(prev) =~ "A wording"

      nothing = del(tenant!(), @key, "ru")
      conn = del(b, @key, "ru")
      assert {conn.status, conn.resp_body} == {nothing.status, nothing.resp_body}
      assert conn.status == 404

      conn = call(:delete, "/#{@key}?locale=ru&tenant_id=#{a.tenant_id}", b, [])
      assert conn.status == 404

      put(b, @key, "ru", "B wording", "B body") |> then(&assert(&1.status == 201))

      conn =
        call(:put, "/#{@key}", b,
          body: %{
            "locale" => "ru",
            "subject" => "B again",
            "body" => "B",
            "tenant_id" => a.tenant_id
          }
        )

      assert conn.status == 200
      assert [%{subject: "A wording"}] = rows(a)
      assert [%{subject: "B again"}] = rows(b)
    end

    test "F1 TASK_WORKER sees identical 403 whether or not the template exists" do
      t = tenant!()
      put(t, @key, "ru", "s", "b")

      for fun <- [
            fn locale -> put(t, @key, locale, "x", "y", roles: ["TASK_WORKER"]) end,
            fn locale -> del(t, @key, locale, roles: ["TASK_WORKER"]) end
          ] do
        existing = fun.("ru")
        missing = fun.("de")
        assert {existing.status, existing.resp_body} == {missing.status, missing.resp_body}

        assert get_resp_header(existing, "content-type") ==
                 get_resp_header(missing, "content-type")

        assert existing.status == 403
      end
    end
  end

  describe "source scans (N4, Q1)" do
    test "N4 the context and registry read no secret, system or application config" do
      for file <- [
            "lib/letflow/notification_templates.ex",
            "lib/letflow/notification_templates/registry.ex"
          ] do
        src = File.read!(file)
        refute src =~ ~r/Secrets\.|System\.|Application\.(get_env|fetch_env)/, file
      end
    end

    test "Q1 the REQ-441 login notifier does not reference notification templates" do
      for file <- Path.wildcard("lib/letflow/login_discovery/**/*.ex") do
        refute File.read!(file) =~ "NotificationTemplates", file
      end
    end

    test "render/3 is pure and leaves unknown names as written" do
      assert NotificationTemplates.render(@key, "{task_name} {nope}", %{"task_name" => "T"}) ==
               "T {nope}"
    end
  end
end
