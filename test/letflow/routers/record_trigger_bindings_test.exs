defmodule Letflow.Routers.RecordTriggerBindingsTest do
  @moduledoc """
  REQ-570 slice T-1 part 2 (GH #3248, decision 0067 D9): the `/record-trigger-bindings` routes. F: the
  route half of `:record_triggers_enabled`; R: statuses and refusal codes; P: credential and
  permission rules; L: the list shape; X: INV-10 cross-tenant negative tests; M: route inventory.

  `async: false`: the platform tenant pin is VM-global, tenants are provisioned and the flag is
  application-wide.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Api.Authorization
  alias Letflow.Audit.Entry
  alias Letflow.EntityWritesFixture, as: EW
  alias Letflow.RecordTriggers
  alias Letflow.RecordTriggers.Binding
  alias Letflow.RecordTriggersFixture, as: RF
  alias Letflow.Routers.RecordTriggerBindings, as: Router
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.ScriptTaskFixture, as: F

  @admin ["TENANT_ADMIN"]
  @designer ["PROCESS_DESIGNER"]
  @auditor ["TENANT_AUDITOR"]
  @base "/api/v1/record-trigger-bindings"

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    type_a = EW.define_type!(tenants.a.schema_name, "r570_order", %{}).name
    set_flag(true)
    {:ok, Map.merge(tenants, %{type_a: type_a})}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp set_flag(value) do
    previous = Application.fetch_env(:letflow, :record_triggers_enabled)
    Application.put_env(:letflow, :record_triggers_enabled, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:letflow, :record_triggers_enabled, old)
        :error -> Application.delete_env(:letflow, :record_triggers_enabled)
      end
    end)
  end

  defp call(method, path, fixture, roles, body \\ nil, opts \\ []) do
    conn =
      Fixture.router_conn(method, path, fixture, roles, body)
      |> Plug.Conn.assign(:auth_context, %{
        user_id: Keyword.get(opts, :user_id, Ecto.UUID.generate()),
        tenant_id: fixture.tenant_id,
        roles: roles,
        credential: Keyword.get(opts, :credential, :oidc)
      })

    Router.call(conn, Router.init([]))
  end

  defp put_trigger(fixture, type, event, body, roles \\ @admin, opts \\ []),
    do: call(:put, "/#{type}/#{event}", fixture, roles, body, opts)

  defp del_trigger(fixture, type, event, roles \\ @admin, opts \\ []),
    do: call(:delete, "/#{type}/#{event}", fixture, roles, nil, opts)

  defp json(conn), do: Jason.decode!(conn.resp_body)

  # Status and decoded body without the per-request trace_id member.
  defp shape(conn), do: {conn.status, conn.resp_body |> Jason.decode!() |> Map.delete("trace_id")}

  defp pin(rule),
    do: %{
      "script_key" => rule.key,
      "script_version" => rule.version,
      "script_sha256" => rule.sha256
    }

  defp published!(schema, manifest \\ nil),
    do: RF.script!(schema, "entity_event", :published, manifest)

  defp bindings(schema), do: Repo.aggregate(Binding, :count, :id, prefix: schema)
  defp audits(schema), do: Repo.aggregate(Entry, :count, :id, prefix: schema)

  defp trigger_actions(schema),
    do:
      Repo.all(
        from(e in Entry,
          where: like(e.action, "record_trigger.%"),
          order_by: e.inserted_at,
          select: e.action
        ),
        prefix: schema
      )

  # A refused write leaves the binding table and the audit trail unchanged.
  defp refused(fixture, type, event, body, status, code, opts \\ []) do
    schema = fixture.schema_name
    {b, a} = {bindings(schema), audits(schema)}
    conn = put_trigger(fixture, type, event, body, @admin, opts)
    assert conn.status == status, conn.resp_body
    assert json(conn)["detail"] == code or json(conn)["code"] == code, conn.resp_body
    assert {bindings(schema), audits(schema)} == {b, a}
    conn
  end

  defp full(method, path, fixture, roles, body) do
    token = Fixture.mint_token!(fixture, roles)

    Fixture.api_conn(method, path, token, fixture.tenant.slug, body)
    |> Fixture.dispatch_api()
  end

  # ── F: the route half of the flag ──────────────────────────────────────────

  describe "F flag" do
    test "F1 flag false: the three routes answer as an unknown route", %{a: a, type_a: type} do
      set_flag(false)
      s = a.schema_name
      body = pin(published!(s))
      unknown = full(:get, @base <> "-nope", a, @admin, nil)
      assert unknown.status == 404
      before = {bindings(s), trigger_actions(s)}

      for {method, path, payload} <- [
            {:get, @base, nil},
            {:put, "#{@base}/#{type}/created", body},
            {:delete, "#{@base}/#{type}/created", nil}
          ] do
        conn = full(method, path, a, @admin, payload)
        assert shape(conn) == shape(unknown)
      end

      assert {bindings(s), trigger_actions(s)} == before
    end

    test "F2 flag true: the routes are reached (API token refused on writes, OIDC binds)", %{
      a: a,
      type_a: type
    } do
      body = pin(published!(a.schema_name))
      conn = full(:put, "#{@base}/#{type}/created", a, @admin, body)
      assert {conn.status, json(conn)["detail"]} == {403, "api_token_not_allowed"}
      assert full(:delete, "#{@base}/#{type}/created", a, @admin, nil).status == 403
      assert full(:get, @base, a, @admin, nil).status == 200

      assert put_trigger(a, type, "created", body).status == 201

      assert [%{"entity_type" => ^type, "event" => "created"}] =
               json(call(:get, "/", a, @admin))["items"]

      assert del_trigger(a, type, "created").status == 204
    end

    test "F3 enabled?/0 follows the application env and defaults to false" do
      set_flag(false)
      refute RecordTriggers.enabled?()
      Application.put_env(:letflow, :record_triggers_enabled, true)
      assert RecordTriggers.enabled?()
      Application.delete_env(:letflow, :record_triggers_enabled)
      refute RecordTriggers.enabled?()
    end
  end

  # ── R: routes and statuses ─────────────────────────────────────────────────

  describe "R routes and statuses" do
    test "R1 bind 201 with the allowlist and one audit entry", %{a: a, type_a: type} do
      rule = published!(a.schema_name)
      user_id = Ecto.UUID.generate()

      conn = put_trigger(a, type, "updated", pin(rule), @admin, user_id: user_id)
      assert conn.status == 201, conn.resp_body
      body = json(conn)

      assert body |> Map.keys() |> Enum.sort() ==
               ~w(bound_at bound_by entity_type event script_key script_sha256 script_version status updated_at)

      assert {body["entity_type"], body["event"], body["status"], body["bound_by"]} ==
               {type, "updated", "active", user_id}

      assert trigger_actions(a.schema_name) == ["record_trigger.bound"]
    end

    test "R2 rebind 200 replaces the row; rebind of an unbound pair is 404", %{
      a: a,
      type_a: type
    } do
      s = a.schema_name
      first = published!(s)
      second = published!(s)

      conn = put_trigger(a, type, "created", Map.put(pin(first), "rebind", true))
      assert conn.status == 404
      assert bindings(s) == 0

      assert put_trigger(a, type, "created", pin(first)).status == 201
      conn = put_trigger(a, type, "created", Map.put(pin(second), "rebind", true))
      assert conn.status == 200, conn.resp_body
      assert json(conn)["script_key"] == second.key
      assert List.last(trigger_actions(s)) == "record_trigger.rebound"
    end

    test "R3 unbind 204; a second unbind is 404", %{a: a, type_a: type} do
      assert put_trigger(a, type, "deleted", pin(published!(a.schema_name))).status == 201
      conn = del_trigger(a, type, "deleted")
      assert conn.status == 204
      assert conn.resp_body == ""
      assert del_trigger(a, type, "deleted").status == 404
      assert trigger_actions(a.schema_name) == ["record_trigger.bound", "record_trigger.unbound"]
    end

    test "R4a 404 and 422 refusals write nothing", %{a: a, type_a: type} do
      s = a.schema_name
      rule = published!(s)
      assert put_trigger(a, "no_such_type", "created", pin(rule)).status == 404

      refused(a, type, "created", Map.delete(pin(rule), "script_key"), 422, "invalid_input")

      refused(
        a,
        type,
        "created",
        Map.put(pin(rule), "script_sha256", "xyz"),
        422,
        "invalid_input"
      )

      refused(a, type, "created", Map.put(pin(rule), "rebind", "yes"), 422, "invalid_input")
      refused(a, type, "sometimes", pin(rule), 422, "invalid_input")

      refused(
        a,
        type,
        "created",
        Map.put(pin(rule), "script_key", "missing_key"),
        422,
        "script_not_found"
      )

      other = pin(published!(s))
      assert bindings(s) == 0
      assert put_trigger(a, "no_such_type", "sometimes", other).status == 422
    end

    test "R4b hook_kind_mismatch 422, script_not_published 409, sha_mismatch 409", %{
      a: a,
      type_a: type
    } do
      s = a.schema_name
      kind = pin(RF.script!(s, "service_task", :published))
      refused(a, type, "created", kind, 422, "hook_kind_mismatch")
      draft = pin(RF.script!(s, "entity_event", :draft))
      refused(a, type, "created", draft, 409, "script_not_published")
      wrong = Map.put(pin(published!(s)), "script_sha256", String.duplicate("0", 64))
      refused(a, type, "created", wrong, 409, "sha_mismatch")
    end

    test "R4c already_bound 409", %{a: a, type_a: type} do
      s = a.schema_name
      assert put_trigger(a, type, "created", pin(published!(s))).status == 201
      refused(a, type, "created", pin(published!(s)), 409, "already_bound")

      refused(
        a,
        type,
        "created",
        Map.put(pin(published!(s)), "rebind", false),
        409,
        "already_bound"
      )
    end

    test "R4d write-line refusals answer 422", %{a: a, type_a: type} do
      s = a.schema_name

      line = fn t, fields ->
        %{"entity_type" => t, "mode" => "update_self", "fields" => fields}
      end

      manifest = fn lines -> F.closed_manifest() |> Map.put("writes", lines) end

      refused(
        a,
        type,
        "created",
        pin(published!(s, manifest.([line.("ghost", ["note"])]))),
        422,
        "write_target_invalid"
      )

      refused(
        a,
        type,
        "created",
        pin(published!(s, manifest.([line.(type, ["nope"])]))),
        422,
        "write_field_forbidden"
      )

      widened =
        manifest.([line.(type, ["note"])])
        |> Map.put("restricted_inputs", [
          %{"name" => "amount", "from" => [%{"entity_type" => type, "field" => "label"}]}
        ])

      refused(a, type, "created", pin(published!(s, widened)), 422, "write_restriction_widened")
    end

    test "R4e entity_type_managed 403", %{a: a, type_a: type} do
      s = a.schema_name

      base =
        Repo.one!(from(d in Letflow.Entities.EntityDefinition, where: d.name == ^type), prefix: s)

      attrs =
        base
        |> Map.from_struct()
        |> Map.drop([:id, :__meta__])
        |> Map.merge(%{name: "r570_managed", managed_by: "fixture_managed"})

      Repo.insert!(struct(Letflow.Entities.EntityDefinition, attrs), prefix: s)
      conn = refused(a, "r570_managed", "created", pin(published!(s)), 403, "entity_type_managed")
      assert json(conn)["code"] == "entity_type_managed"
    end
  end

  # ── P: credential and permission rules ─────────────────────────────────────

  describe "P credential and permissions" do
    test "P1 an API-token caller gets api_token_not_allowed on bind", %{a: a, type_a: type} do
      refused(a, type, "created", pin(published!(a.schema_name)), 403, "api_token_not_allowed",
        credential: :api_token
      )
    end

    test "P2 an API-token caller gets api_token_not_allowed on rebind", %{a: a, type_a: type} do
      s = a.schema_name
      assert put_trigger(a, type, "created", pin(published!(s))).status == 201
      body = Map.put(pin(published!(s)), "rebind", true)
      refused(a, type, "created", body, 403, "api_token_not_allowed", credential: :api_token)
    end

    test "P3 an API-token caller gets api_token_not_allowed on unbind", %{a: a, type_a: type} do
      assert put_trigger(a, type, "created", pin(published!(a.schema_name))).status == 201
      conn = del_trigger(a, type, "created", @admin, credential: :api_token)
      assert conn.status == 403
      assert json(conn)["detail"] == "api_token_not_allowed"
      assert bindings(a.schema_name) == 1
    end

    test "P4 PROCESS_DESIGNER lists but cannot bind, rebind or unbind", %{a: a, type_a: type} do
      s = a.schema_name
      rule = published!(s)
      before = audits(s)
      assert call(:get, "/", a, @designer).status == 200

      assert put_trigger(a, type, "created", pin(rule), @designer).status == 403
      rebind = Map.put(pin(rule), "rebind", true)
      assert put_trigger(a, type, "created", rebind, @designer).status == 403
      assert del_trigger(a, type, "created", @designer).status == 403
      assert {bindings(s), audits(s)} == {0, before}
    end

    test "P5 roles without ScriptsWrite cannot list; only TENANT_ADMIN binds", %{
      a: a,
      type_a: type
    } do
      assert call(:get, "/", a, @auditor).status == 403
      assert call(:get, "/", a, ["TASK_WORKER"]).status == 403

      rule = published!(a.schema_name)

      for role <- Authorization.roles(),
          to_string(role) not in ["TENANT_ADMIN", "PLATFORM_ADMIN"] do
        assert put_trigger(a, type, "created", pin(rule), [to_string(role)]).status == 403,
               to_string(role)
      end

      assert bindings(a.schema_name) == 0
    end

    test "P6 the policy keys map to existing permissions" do
      assert Authorization.required_permission(:RecordTriggerBindingsList) == :ScriptsWrite
      assert Authorization.required_permission(:RecordTriggerBindingsManage) == :ScriptsPublish
    end
  end

  # ── L: list shape ──────────────────────────────────────────────────────────

  describe "L list" do
    test "L1 only the caller's bindings, ordered, allowlisted", %{a: a, b: b} do
      sa = a.schema_name
      sb = b.schema_name
      for name <- ["r570_zeta", "r570_alpha"], do: EW.define_type!(sa, name, %{})
      EW.define_type!(sb, "r570_other", %{})

      for {name, event} <- [
            {"r570_zeta", "created"},
            {"r570_alpha", "updated"},
            {"r570_alpha", "created"}
          ],
          do: assert(put_trigger(a, name, event, pin(published!(sa))).status == 201)

      assert put_trigger(b, "r570_other", "created", pin(published!(sb))).status == 201

      conn = call(:get, "/", a, @admin)
      assert conn.status == 200
      items = json(conn)["items"]

      assert Enum.map(items, &{&1["entity_type"], &1["event"]}) ==
               [{"r570_alpha", "created"}, {"r570_alpha", "updated"}, {"r570_zeta", "created"}]

      for item <- items do
        assert item |> Map.keys() |> Enum.sort() ==
                 ~w(bound_at bound_by entity_type event script_key script_sha256 script_version status updated_at)
      end

      refute conn.resp_body =~ F.doubling_source()
      refute conn.resp_body =~ "manifest"
      refute conn.resp_body =~ "tenant_id"
      refute conn.resp_body =~ "r570_other"
    end
  end

  # ── X: INV-10 ──────────────────────────────────────────────────────────────

  describe "X cross-tenant" do
    test "X1 tenant B naming tenant A's bound type equals an absent type", %{
      a: a,
      b: b,
      type_a: type
    } do
      sa = a.schema_name
      assert put_trigger(a, type, "created", pin(published!(sa))).status == 201
      {rows, audit_count} = {Repo.all(Binding, prefix: sa), audits(sa)}

      bind = pin(published!(b.schema_name))
      rebind = Map.put(bind, "rebind", true)

      for {method, body} <- [{:put, bind}, {:put, rebind}, {:delete, nil}] do
        real = call(method, "/#{type}/created", b, @admin, body)
        absent = call(method, "/nowhere_at_all/created", b, @admin, body)

        assert real.status == 404
        assert shape(real) == shape(absent)
      end

      assert Repo.all(Binding, prefix: sa) == rows
      assert audits(sa) == audit_count
      assert bindings(b.schema_name) == 0
    end

    test "X2 B's list does not contain A's binding", %{a: a, b: b, type_a: type} do
      assert put_trigger(a, type, "created", pin(published!(a.schema_name))).status == 201
      assert json(call(:get, "/", b, @admin))["items"] == []
    end

    test "X3 a same-named type in B binds independently", %{a: a, b: b, type_a: type} do
      EW.define_type!(b.schema_name, type, %{})
      assert put_trigger(a, type, "created", pin(published!(a.schema_name))).status == 201
      assert put_trigger(b, type, "created", pin(published!(b.schema_name))).status == 201

      assert [%{"script_key" => ka}] = json(call(:get, "/", a, @admin))["items"]
      assert [%{"script_key" => kb}] = json(call(:get, "/", b, @admin))["items"]
      assert ka != kb
      assert del_trigger(b, type, "created").status == 204
      assert bindings(a.schema_name) == 1
    end
  end

  # ── M: route inventory ─────────────────────────────────────────────────────

  describe "M route inventory" do
    test "M1 the router declares exactly the three routes" do
      assert Enum.sort(Router.__authz_routes__()) ==
               Enum.sort([
                 {"GET", "/", :RecordTriggerBindingsList},
                 {"PUT", "/:entity_type/:event", :RecordTriggerBindingsManage},
                 {"DELETE", "/:entity_type/:event", :RecordTriggerBindingsManage}
               ])
    end

    test "M2 the full pipeline mounts the router and enforces the permission", %{a: a} do
      conn = full(:get, @base, a, @designer, nil)
      assert conn.status == 200, conn.resp_body
      assert json(conn)["items"] == []
      assert full(:get, @base, a, @auditor, nil).status == 403
    end
  end
end
