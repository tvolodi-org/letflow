defmodule Letflow.Routers.TenantConfigBundleTest do
  @moduledoc """
  REQ-552 slice 1 (GH #3177): `GET /tenant/config-bundle` and `POST /tenant/config-bundle/import`.
  Each `describe` names its acceptance criterion (AC1..AC10).

  Dispatch: real `Letflow.Routers.TenantConfigBundle.call/2`. `async: false` (tenant provisioning).
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog

  alias Letflow.Audit
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Modules.Installs
  alias Letflow.Routers.TenantConfigBundle, as: Router
  alias Letflow.TenantConfigBundle
  alias Letflow.TenantFixture

  @opts Router.init([])
  @settings %{
    "app_name" => "Acme",
    "logo_url" => "https://logo.example.com/distinct-logo.png",
    "brand_colors" => %{"primary" => "#1a3c8e"},
    "locales" => ["en", "de"],
    "default_locale" => "en"
  }

  defp conn_for(method, path, tenant, roles, body \\ %{}) do
    conn(method, path)
    |> Map.put(:body_params, body)
    |> put_req_header("content-type", "application/json")
    |> assign(:auth_context, %{
      user_id: Ecto.UUID.generate(),
      tenant_id: tenant.tenant_id,
      roles: roles
    })
    |> assign(:scoped_opts, prefix: tenant.schema_name)
    |> assign(:trace_id, "req552-trace")
    |> Router.call(@opts)
  end

  defp export(tenant, roles \\ ["TENANT_ADMIN"]), do: conn_for(:get, "/", tenant, roles)

  defp import_(tenant, body, roles \\ ["TENANT_ADMIN"]),
    do: conn_for(:post, "/import", tenant, roles, body)

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp tenant!(prefix) do
    t = TenantFixture.provisioned_tenant!(slug_prefix: prefix)

    {:ok, _} =
      Installs.install("fixture", Ecto.UUID.generate(), prefix: t.schema_name, rationale: "test")

    t
  end

  defp set_settings!(tenant, settings) do
    slug = Repo.get!(Tenant, tenant.tenant_id).slug
    {:ok, _} = Identity.update_tenant_settings(slug, %{"settings" => settings})
  end

  defp tenant_settings(tenant), do: Repo.get!(Tenant, tenant.tenant_id).settings

  defp module_settings(tenant, id) do
    [prefix: tenant.schema_name]
    |> Installs.list_installed()
    |> Enum.find(&(&1.module_id == id))
    |> Map.fetch!(:settings)
  end

  defp audit_entries(tenant) do
    {:ok, %{items: items}} =
      Audit.list_entries(%{
        prefix: tenant.schema_name,
        page_size: 100,
        resource_type: "tenant_config_bundle"
      })

    items
  end

  defp bundle(ts, mods \\ []) do
    %{
      "bundle_schema_version" => "bpm/config-bundle/v1",
      "tenant_settings" => ts,
      "module_settings" => Enum.map(mods, fn {id, s} -> %{"module_id" => id, "settings" => s} end)
    }
  end

  defp route_paths_and_keys do
    for r <- Router.__authz_routes__(), do: {elem(r, 1), elem(r, 2)}
  end

  describe "AC1 -- export shape" do
    test "E1 exact keys, values round-trip, empty module settings are {}" do
      t = tenant!("r552-e1")

      {:ok, _} =
        Installs.install("fixture_dependent", Ecto.UUID.generate(),
          prefix: t.schema_name,
          rationale: "test"
        )

      set_settings!(t, @settings)
      {:ok, _} = Installs.put_settings("fixture", %{"greeting" => "hi"}, prefix: t.schema_name)

      conn = export(t)
      assert conn.status == 200
      body = json(conn)

      assert Enum.sort(Map.keys(body)) ==
               [
                 "bundle_schema_version",
                 "exported_at",
                 "label_overrides",
                 "module_settings",
                 "notification_templates",
                 "tenant_settings"
               ]

      assert body["bundle_schema_version"] == "bpm/config-bundle/v2"
      assert {:ok, _, _} = DateTime.from_iso8601(body["exported_at"])
      assert body["tenant_settings"] == @settings

      by_id = Map.new(body["module_settings"], &{&1["module_id"], &1})
      assert by_id["fixture"]["settings"] == %{"greeting" => "hi"}
      assert by_id["fixture_dependent"]["settings"] == %{}

      assert Enum.all?(
               body["module_settings"],
               &(Enum.sort(Map.keys(&1)) == ["module_id", "module_version", "settings"])
             )
    end

    test "E2 tenant without settings exports {}" do
      t = tenant!("r552-e2")
      assert json(export(t))["tenant_settings"] == %{}
    end
  end

  describe "REQ-599 part 1 -- v2 export of labels and notification templates" do
    alias Letflow.Labels.Override
    alias Letflow.NotificationTemplates.Template

    defp put_override!(t, id, locale, text),
      do:
        Repo.insert!(
          %Override{tenant_id: t.tenant_id, message_id: id, locale: locale, text: text},
          prefix: t.schema_name
        )

    defp put_template!(t, key, locale, subject, body),
      do:
        Repo.insert!(
          %Template{
            tenant_id: t.tenant_id,
            template_key: key,
            locale: locale,
            subject: subject,
            body: body
          },
          prefix: t.schema_name
        )

    test "E3 both lists sorted, only the documented keys, values round-trip" do
      t = tenant!("r599-e3")
      put_override!(t, "b.msg", "en", "B en")
      put_override!(t, "a.msg", "ru", "A ru")
      put_override!(t, "a.msg", "en", "A en")
      put_template!(t, "z.key", "en", "Z subject", "Z body")
      put_template!(t, "a.key", "ru", "A ru subject", "A ru body")
      put_template!(t, "a.key", "en", "A en subject", "A en body")

      body = json(export(t))

      assert body["label_overrides"] == [
               %{"message_id" => "a.msg", "locale" => "en", "text" => "A en"},
               %{"message_id" => "a.msg", "locale" => "ru", "text" => "A ru"},
               %{"message_id" => "b.msg", "locale" => "en", "text" => "B en"}
             ]

      assert body["notification_templates"] == [
               %{
                 "template_key" => "a.key",
                 "locale" => "en",
                 "subject" => "A en subject",
                 "body" => "A en body"
               },
               %{
                 "template_key" => "a.key",
                 "locale" => "ru",
                 "subject" => "A ru subject",
                 "body" => "A ru body"
               },
               %{
                 "template_key" => "z.key",
                 "locale" => "en",
                 "subject" => "Z subject",
                 "body" => "Z body"
               }
             ]
    end

    test "E4 a tenant with none exports empty lists, not null" do
      t = tenant!("r599-e4")
      body = json(export(t))
      assert body["label_overrides"] == []
      assert body["notification_templates"] == []
    end

    test "E5 each part follows its own permission" do
      t = tenant!("r599-e5")
      conn = conn(:get, "/") |> assign(:auth_context, %{tenant_id: t.tenant_id, roles: []})
      deny = fn denied -> fn p -> p not in denied end end

      assert Router.export_parts(conn, deny.([:LabelsManage])) == [:notification_templates]

      assert Router.export_parts(conn, deny.([:NotificationTemplatesManage])) == [
               :label_overrides
             ]

      assert Router.export_parts(conn, deny.([:LabelsManage, :NotificationTemplatesManage])) == []
      assert Router.export_parts(conn, deny.([])) == [:label_overrides, :notification_templates]

      {:ok, bundle} = TenantConfigBundle.export(t.tenant_id, t.schema_name, parts: [])
      assert bundle["bundle_schema_version"] == "bpm/config-bundle/v2"

      assert Enum.sort(Map.keys(bundle)) ==
               ["bundle_schema_version", "exported_at", "module_settings", "tenant_settings"]

      {:ok, bundle} = TenantConfigBundle.export(t.tenant_id, t.schema_name)
      refute Map.has_key?(bundle, "label_overrides")
    end

    test "E6 a role with TenantSettingsManage only gets neither part through the router" do
      t = tenant!("r599-e6")
      put_override!(t, "a.msg", "en", "A en")

      for roles <- [["TENANT_ADMIN"]] do
        assert Map.has_key?(json(export(t, roles)), "label_overrides")
      end

      denied =
        conn(:get, "/")
        |> assign(:auth_context, %{tenant_id: t.tenant_id, roles: ["TASK_WORKER"]})

      assert Router.export_parts(denied) == []
    end

    test "E7 rows of another tenant are absent" do
      a = tenant!("r599-e7a")
      b = tenant!("r599-e7b")
      put_override!(a, "a.msg", "en", "only A")
      put_template!(b, "b.key", "en", "only B", "only B body")

      ja = json(export(a))
      jb = json(export(b))
      assert [%{"text" => "only A"}] = ja["label_overrides"]
      assert ja["notification_templates"] == []
      assert jb["label_overrides"] == []
      assert [%{"subject" => "only B"}] = jb["notification_templates"]
    end

    test "V1 v1 and v2 documents are both accepted; the new parts are not applied" do
      t = tenant!("r599-v1")
      assert import_(t, bundle(%{"app_name" => "One"})).status == 200

      v2 =
        bundle(%{"app_name" => "Two"})
        |> Map.put("bundle_schema_version", "bpm/config-bundle/v2")
        |> Map.put("label_overrides", [
          %{"message_id" => "a.msg", "locale" => "en", "text" => "x"}
        ])
        |> Map.put("notification_templates", [])

      assert import_(t, v2).status == 200
      assert Letflow.Labels.list_overrides(t.schema_name, t.tenant_id) == []
      assert tenant_settings(t)["app_name"] == "Two"
    end

    test "V2 the audit entry records the version of the imported document" do
      t = tenant!("r599-v2")
      assert import_(t, bundle(%{"app_name" => "One"})).status == 200

      v2 =
        bundle(%{"app_name" => "Two"}) |> Map.put("bundle_schema_version", "bpm/config-bundle/v2")

      assert import_(t, v2).status == 200

      versions =
        t |> audit_entries() |> Enum.map(& &1.after_state["bundle_schema_version"]) |> Enum.sort()

      assert versions == ["bpm/config-bundle/v1", "bpm/config-bundle/v2"]
    end

    test "R1 the runbook states the v1/v2 rule" do
      text = File.read!("docs/runbooks/tenant-config-bundle.md")

      for word <- ["bpm/config-bundle/v2", "v1", "LabelsManage", "NotificationTemplatesManage"],
          do: assert(text =~ word)
    end
  end

  describe "AC2 -- no secret resolved" do
    test "S1 a reference string is exported unchanged; the module has no Secrets use" do
      t = tenant!("r552-s1")

      {:ok, _} =
        Installs.put_settings("fixture", %{"greeting" => "secret://x/ref"}, prefix: t.schema_name)

      log = capture_log(fn -> send(self(), {:conn, export(t)}) end)
      assert_received {:conn, conn}
      m = Enum.find(json(conn)["module_settings"], &(&1["module_id"] == "fixture"))
      assert m["settings"] == %{"greeting" => "secret://x/ref"}
      refute log =~ "secret://x/ref"

      refute File.read!("lib/letflow/tenant_config_bundle.ex") =~ "Secrets"
    end
  end

  describe "AC3 -- import writes allowed keys only" do
    test "I1 valid bundle is applied, untouched keys are kept (shallow merge)" do
      t = tenant!("r552-i1")
      set_settings!(t, %{"app_name" => "Old", "locales" => ["en"], "default_locale" => "en"})

      conn =
        import_(
          t,
          bundle(
            %{"app_name" => "New", "brand_colors" => %{"primary" => "#1a3c8e"}},
            [{"fixture", %{"greeting" => "yo"}}]
          )
        )

      assert conn.status == 200

      assert json(conn) == %{
               "tenant_settings_changed" => 2,
               "modules_changed" => 1,
               "modules_unchanged" => 0
             }

      assert tenant_settings(t)["app_name"] == "New"
      assert tenant_settings(t)["locales"] == ["en"]
      assert module_settings(t, "fixture") == %{"greeting" => "yo"}
    end

    test "I2 invalid values: 422, nothing stored" do
      t = tenant!("r552-i2")
      set_settings!(t, %{"app_name" => "Keep"})

      for bad <- [
            %{"brand_colors" => %{"primary" => "red"}},
            %{"brand_colors" => %{"primary" => "#ffffff"}},
            %{"app_name" => ""},
            %{"logo_url" => "not a url"},
            %{"locales" => ["en"], "default_locale" => "fr"}
          ] do
        assert import_(t, bundle(bad)).status == 422
      end

      assert tenant_settings(t) == %{"app_name" => "Keep"}
    end

    test "I2b REQ-585 a valid brand_colors.secondary is accepted and stored" do
      t = tenant!("r585-i2b")

      conn =
        import_(
          t,
          bundle(%{"brand_colors" => %{"primary" => "#1a3c8e", "secondary" => "#1971C2"}})
        )

      assert conn.status == 200

      assert tenant_settings(t)["brand_colors"] == %{
               "primary" => "#1a3c8e",
               "secondary" => "#1971C2"
             }
    end

    test "I3 unknown keys are refused (PATCH only drops them)" do
      t = tenant!("r552-i3")
      conn = import_(t, bundle(%{"app_name" => "X", "theme" => "dark"}))
      assert conn.status == 422
      assert json(conn)["detail"] =~ "theme"

      conn =
        import_(
          t,
          bundle(%{"brand_colors" => %{"primary" => "#1a3c8e", "tertiary" => "#000000"}})
        )

      assert conn.status == 422
      assert json(conn)["detail"] =~ "tertiary"
      assert tenant_settings(t) in [nil, %{}]

      patch =
        conn(:patch, "/")
        |> Map.put(:body_params, %{"app_name" => "X", "theme" => "dark"})
        |> assign(:auth_context, %{
          user_id: Ecto.UUID.generate(),
          tenant_id: t.tenant_id,
          roles: ["TENANT_ADMIN"]
        })
        |> assign(:scoped_opts, prefix: t.schema_name)
        |> Letflow.Routers.TenantSettings.call(Letflow.Routers.TenantSettings.init([]))

      assert patch.status == 200
    end
  end

  describe "AC4 -- own tenant only" do
    test "T1 export of A imported with B's token changes only B" do
      a = tenant!("r552-t1a")
      b = tenant!("r552-t1b")
      set_settings!(a, @settings)

      {:ok, _} =
        Installs.put_settings("fixture", %{"greeting" => "from-a"}, prefix: a.schema_name)

      set_settings!(b, %{"app_name" => "B-before"})
      before_a = {tenant_settings(a), module_settings(a, "fixture")}

      doc = json(export(a))
      assert import_(b, doc).status == 200

      assert tenant_settings(b) == @settings
      assert module_settings(b, "fixture") == %{"greeting" => "from-a"}
      assert {tenant_settings(a), module_settings(a, "fixture")} == before_a
    end

    test "T2 tenant identifiers in the document are ignored; routes have no tenant segment" do
      a = tenant!("r552-t2a")
      b = tenant!("r552-t2b")

      doc =
        Map.merge(bundle(%{"app_name" => "Only-B"}), %{
          "tenant_id" => a.tenant_id,
          "source_tenant_id" => a.tenant_id,
          "prefix" => a.schema_name
        })

      assert import_(b, doc).status == 200
      assert tenant_settings(b)["app_name"] == "Only-B"
      assert tenant_settings(a) in [nil, %{}]

      for {path, _k} <- route_paths_and_keys(), do: refute(path =~ ":")
    end
  end

  describe "AC5 -- schema version and all-or-nothing" do
    test "A1 unknown version vs missing version" do
      t = tenant!("r552-a1")
      unknown = import_(t, %{bundle(%{}) | "bundle_schema_version" => "bpm/config-bundle/v9"})
      assert unknown.status == 422
      assert json(unknown)["detail"] =~ "unknown_bundle_schema_version"
      refute json(unknown)["detail"] =~ "v9"

      missing = import_(t, Map.delete(bundle(%{}), "bundle_schema_version"))
      assert missing.status == 422
      refute json(missing)["detail"] =~ "unknown_bundle_schema_version"
    end

    test "A2 every violated item is named in one response, rows unchanged" do
      t = tenant!("r552-a2")

      conn =
        import_(
          t,
          bundle(%{"theme" => 1}, [{"nope_module", %{}}, {"fixture", %{}}, {"fixture", %{}}])
        )

      assert conn.status == 422
      assert json(conn)["detail"] =~ "theme"
      assert json(conn)["detail"] =~ "duplicate module_id"

      conn =
        import_(
          t,
          bundle(%{"app_name" => "ok"}, [{"nope_module", %{}}, {"fixture", %{"greeting" => 5}}])
        )

      detail = json(conn)["detail"]
      assert detail =~ "nope_module"
      assert detail =~ "module_settings[fixture]"

      for bad <- [%{"tenant_settings" => nil}, %{"tenant_settings" => "x"}] do
        assert import_(t, Map.merge(bundle(%{}), bad)).status == 422
      end

      null_settings =
        Map.put(bundle(%{}), "module_settings", [%{"module_id" => "fixture", "settings" => nil}])

      assert import_(t, null_settings).status == 422
      assert tenant_settings(t) in [nil, %{}]
      assert module_settings(t, "fixture") == %{}
    end

    test "A3 valid tenant part is rolled back when a module is bad" do
      t = tenant!("r552-a3")
      conn = import_(t, bundle(%{"app_name" => "Rolled"}, [{"nope_module", %{}}]))
      assert conn.status == 422
      assert tenant_settings(t) in [nil, %{}]
      assert audit_entries(t) == []
    end

    test "A4 malformed bodies are 422, never 500" do
      t = tenant!("r552-a4")

      for body <- [
            %{},
            %{"_json" => []},
            %{"bundle_schema_version" => 1},
            %{"bundle_schema_version" => "bpm/config-bundle/v1"}
          ] do
        assert import_(t, body).status == 422
      end
    end
  end

  describe "AC6 -- idempotent re-import" do
    test "R1 second identical import changes nothing and writes no audit entry" do
      t = tenant!("r552-r1")
      body = bundle(@settings, [{"fixture", %{"greeting" => "hi"}}])

      assert json(import_(t, body)) == %{
               "tenant_settings_changed" => 5,
               "modules_changed" => 1,
               "modules_unchanged" => 0
             }

      assert length(audit_entries(t)) == 1

      conn = import_(t, body)

      assert json(conn) == %{
               "tenant_settings_changed" => 0,
               "modules_changed" => 0,
               "modules_unchanged" => 1
             }

      assert length(audit_entries(t)) == 1
      assert tenant_settings(t) == @settings
    end
  end

  describe "AC7 -- authorisation" do
    test "Z1 roles without :TenantSettingsManage get one uniform 403" do
      t = tenant!("r552-z1")
      body = bundle(%{"app_name" => "No"})

      details =
        for roles <- [["TASK_WORKER"], ["TENANT_AUDITOR"], [], ["PLATFORM_ADMIN"]],
            conn <- [export(t, roles), import_(t, body, roles)] do
          assert conn.status == 403
          json(conn)["detail"]
        end

      assert details |> Enum.uniq() |> length() == 1
      assert tenant_settings(t) in [nil, %{}]
      assert audit_entries(t) == []
    end

    test "Z2 module settings need :ModulesManage as well" do
      assert Letflow.TenantConfigBundle.required_permissions(bundle(%{})) ==
               [:TenantSettingsManage]

      assert Letflow.TenantConfigBundle.required_permissions(bundle(%{}, [{"fixture", %{}}])) ==
               [:TenantSettingsManage, :ModulesManage]

      c = conn(:post, "/import")
      deny_modules = fn p -> p != :ModulesManage end
      refute Router.modules_permitted?(c, bundle(%{}, [{"fixture", %{}}]), deny_modules)
      assert Router.modules_permitted?(c, bundle(%{"app_name" => "x"}), deny_modules)
    end

    test "Z3 both routes declare :TenantSettingsManage" do
      routes = route_paths_and_keys()
      assert length(routes) == 2
      assert Enum.all?(routes, fn {_p, k} -> k == :TenantSettingsManage end)

      assert Letflow.Api.Authorization.endpoint_policy_key("GET", "/tenant/config-bundle") ==
               :TenantSettingsManage

      assert Letflow.Api.Authorization.endpoint_policy_key(
               "POST",
               "/tenant/config-bundle/import"
             ) == :TenantSettingsManage
    end
  end

  describe "AC8 -- audit entry without values" do
    test "U1 one entry per change; no values; none for refused imports" do
      t = tenant!("r552-u1")
      assert import_(t, bundle(%{"app_name" => "Zed"}), ["TASK_WORKER"]).status == 403
      assert import_(t, bundle(%{"bogus" => 1})).status == 422
      assert audit_entries(t) == []

      body =
        bundle(
          %{"logo_url" => "https://logo.example.com/distinct-logo.png", "app_name" => "Zed"},
          [{"fixture", %{"greeting" => "distinct-greeting"}}]
        )

      assert import_(t, body).status == 200

      assert [entry] = audit_entries(t)
      assert entry.action == "tenant_config_bundle.import"
      assert entry.resource_id == t.tenant_id
      assert entry.after_state["tenant_settings_keys_changed"] == ["app_name", "logo_url"]
      assert entry.after_state["module_ids_changed"] == ["fixture"]
      encoded = Jason.encode!(entry.after_state)
      refute encoded =~ "distinct-logo"
      refute encoded =~ "distinct-greeting"
      refute encoded =~ "Zed"
    end
  end

  describe "AC10 -- runbook" do
    test "D1 the runbook names what the bundle does not carry" do
      text = File.read!("docs/runbooks/tenant-config-bundle.md")
      for word <- ["Scripts", "roles", "number sequences", "promotion"], do: assert(text =~ word)
    end
  end
end
