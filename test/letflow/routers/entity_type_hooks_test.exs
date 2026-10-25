defmodule Letflow.Routers.EntityTypeHooksTest do
  @moduledoc """
  REQ-567 slice E-1 part 2 (GH #3217, decision 0065 D4, D7): the `/entity-type-hooks` routes. R: the
  status of every route and refusal code; P: credential and permission rules; L: the list shape;
  X: INV-10 cross-tenant negative tests; E: the router is mounted in the full pipeline.

  `async: false`: the platform tenant pin is VM-global and tenants are provisioned.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.Entities.EntityDefinition
  alias Letflow.EntityTypeHooks.Binding
  alias Letflow.EntityWritesFixture, as: EW
  alias Letflow.Routers.EntityTypeHooks, as: Router
  alias Letflow.Scripts.Hash
  alias Letflow.Scripts.ScriptRule
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.ScriptTaskFixture, as: F

  @admin ["TENANT_ADMIN"]
  @designer ["PROCESS_DESIGNER"]
  @auditor ["TENANT_AUDITOR"]

  setup do
    tenants = Fixture.three_tenants!()
    Fixture.pin!(tenants.p.tenant_id)
    type_a = EW.define_type!(tenants.a.schema_name, "r567_order", %{}).name
    {:ok, Map.merge(tenants, %{type_a: type_a})}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

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

  defp put_hook(fixture, type, body, roles \\ @admin, opts \\ []),
    do: call(:put, "/#{type}", fixture, roles, body, opts)

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp pin(rule),
    do: %{
      "script_key" => rule.key,
      "script_version" => rule.version,
      "script_sha256" => rule.sha256
    }

  # A script row of `hook_kind` / `status`, hashed over its own content (the legal INSERT shape).
  defp script!(schema, hook_kind, status) do
    key = "hk#{System.unique_integer([:positive])}"
    test_cases = [%{"name" => "c1", "input" => %{}, "expect" => %{"fail" => "x"}}]
    manifest = F.closed_manifest()
    source = F.doubling_source()

    rule =
      Repo.insert!(
        %ScriptRule{
          key: key,
          version: 1,
          hook_kind: hook_kind,
          status: :draft,
          source: source,
          manifest: manifest,
          test_cases: test_cases,
          sha256: "pending",
          contributors: [Ecto.UUID.generate()]
        },
        prefix: schema
      )

    sha = Hash.compute(key, 1, hook_kind, manifest, test_cases, source)
    rule = rule |> Ecto.Changeset.change(sha256: sha) |> Repo.update!(prefix: schema)

    if status == :published do
      publisher = Ecto.UUID.generate()

      rule
      |> Ecto.Changeset.change(
        status: :published,
        publisher_id: publisher,
        published_at: DateTime.utc_now(),
        sod_excluded: rule.contributors ++ [publisher]
      )
      |> Repo.update!(prefix: schema)
    else
      rule
    end
  end

  defp published!(schema), do: script!(schema, "entity_write", :published)

  defp bindings(schema), do: Repo.aggregate(Binding, :count, :id, prefix: schema)
  defp audits(schema), do: Repo.aggregate(Entry, :count, :id, prefix: schema)

  defp hook_actions(schema),
    do:
      Repo.all(
        from(e in Entry,
          where: like(e.action, "entity_type_hook.%"),
          order_by: e.inserted_at,
          select: e.action
        ),
        prefix: schema
      )

  # A refused write leaves the binding table and the audit trail unchanged.
  defp refused(fixture, type, body, status, code, opts \\ []) do
    schema = fixture.schema_name
    {b, a} = {bindings(schema), audits(schema)}
    conn = put_hook(fixture, type, body, @admin, opts)
    assert conn.status == status, conn.resp_body
    assert json(conn)["detail"] == code or json(conn)["code"] == code, conn.resp_body
    assert {bindings(schema), audits(schema)} == {b, a}
    conn
  end

  # ── R: routes and statuses ─────────────────────────────────────────────────

  describe "R routes and statuses" do
    test "R1 bind 201, list 200, unbind 204", %{a: a, type_a: type} do
      rule = published!(a.schema_name)
      user_id = Ecto.UUID.generate()

      conn = put_hook(a, type, pin(rule), @admin, user_id: user_id)
      assert conn.status == 201, conn.resp_body
      body = json(conn)
      assert body["entity_type"] == type
      assert body["script_key"] == rule.key
      assert body["script_version"] == rule.version
      assert body["script_sha256"] == rule.sha256
      assert body["bound_by"] == user_id

      conn = call(:get, "/", a, @admin)
      assert conn.status == 200
      assert [%{"entity_type" => ^type}] = json(conn)["items"]

      conn = call(:delete, "/#{type}", a, @admin)
      assert conn.status == 204
      assert conn.resp_body == ""
      assert bindings(a.schema_name) == 0

      assert hook_actions(a.schema_name) == [
               "entity_type_hook.bound",
               "entity_type_hook.unbound"
             ]
    end

    test "R1a to R1c not_found 404, invalid_input 422, script_not_found 422", %{
      a: a,
      type_a: type
    } do
      rule = published!(a.schema_name)
      schema = a.schema_name

      conn = put_hook(a, "no_such_type", pin(rule))
      assert conn.status == 404

      refused(a, type, Map.delete(pin(rule), "script_key"), 422, "invalid_input")
      refused(a, type, Map.put(pin(rule), "script_sha256", "xyz"), 422, "invalid_input")
      refused(a, type, Map.put(pin(rule), "rebind", "yes"), 422, "invalid_input")
      refused(a, type, %{}, 422, "invalid_input")
      refused(a, type, Map.put(pin(rule), "script_key", "missing_key"), 422, "script_not_found")
      assert bindings(schema) == 0
    end

    test "R1d to R1f hook_kind_mismatch 422, script_not_published 409, sha_mismatch 409", %{
      a: a,
      type_a: type
    } do
      s = a.schema_name
      refused(a, type, pin(script!(s, "service_task", :published)), 422, "hook_kind_mismatch")
      refused(a, type, pin(script!(s, "entity_write", :draft)), 409, "script_not_published")

      other = Map.put(pin(published!(s)), "script_sha256", String.duplicate("0", 64))
      refused(a, type, other, 409, "sha_mismatch")
    end

    test "R1g already_bound 409 on a second bind without the rebind form", %{a: a, type_a: type} do
      s = a.schema_name
      assert put_hook(a, type, pin(published!(s))).status == 201
      refused(a, type, pin(published!(s)), 409, "already_bound")
      refused(a, type, Map.put(pin(published!(s)), "rebind", false), 409, "already_bound")
    end

    test "R1h entity_type_hooked 409", %{a: a, type_a: type} do
      s = a.schema_name
      user = EW.user!(s, "r567")
      EW.activate!(s, user, EW.graph([EW.line(type, %{"label" => %{"const" => "x"}})]))
      refused(a, type, pin(published!(s)), 409, "entity_type_hooked")
    end

    test "R1i entity_type_managed 403", %{a: a} do
      s = a.schema_name
      base = Repo.one!(from(d in EntityDefinition, where: d.name == "r567_order"), prefix: s)

      attrs =
        base
        |> Map.from_struct()
        |> Map.drop([:id, :__meta__])
        |> Map.merge(%{name: "r567_managed", managed_by: "fixture_managed"})

      Repo.insert!(struct(EntityDefinition, attrs), prefix: s)
      conn = refused(a, "r567_managed", pin(published!(s)), 403, "entity_type_managed")
      assert json(conn)["code"] == "entity_type_managed"
    end

    test "R1j unbind and rebind of an unbound type are 404", %{a: a, type_a: type} do
      assert call(:delete, "/#{type}", a, @admin).status == 404

      conn = put_hook(a, type, Map.put(pin(published!(a.schema_name)), "rebind", true))
      assert conn.status == 404
      assert bindings(a.schema_name) == 0
    end

    test "R2 rebind with a second published version returns 200 and replaces the row", %{
      a: a,
      type_a: type
    } do
      s = a.schema_name
      first = published!(s)
      second = published!(s)
      assert put_hook(a, type, pin(first)).status == 201

      conn = put_hook(a, type, Map.put(pin(second), "rebind", true))
      assert conn.status == 200, conn.resp_body
      assert json(conn)["script_key"] == second.key
      assert [%Binding{script_key: key}] = Repo.all(Binding, prefix: s)
      assert key == second.key
      assert List.last(hook_actions(s)) == "entity_type_hook.rebound"
    end
  end

  # ── P: credential and permission rules ─────────────────────────────────────

  describe "P credential and permissions" do
    test "P1 an API-token caller gets api_token_not_allowed on bind", %{a: a, type_a: type} do
      refused(a, type, pin(published!(a.schema_name)), 403, "api_token_not_allowed",
        credential: :api_token
      )
    end

    test "P2 an API-token caller gets api_token_not_allowed on rebind", %{a: a, type_a: type} do
      s = a.schema_name
      assert put_hook(a, type, pin(published!(s))).status == 201

      body = Map.put(pin(published!(s)), "rebind", true)
      refused(a, type, body, 403, "api_token_not_allowed", credential: :api_token)
    end

    test "P3 an API-token caller gets api_token_not_allowed on unbind", %{a: a, type_a: type} do
      assert put_hook(a, type, pin(published!(a.schema_name))).status == 201

      conn = call(:delete, "/#{type}", a, @admin, nil, credential: :api_token)
      assert conn.status == 403
      assert json(conn)["detail"] == "api_token_not_allowed"
      assert bindings(a.schema_name) == 1
    end

    test "P4 PROCESS_DESIGNER lists but cannot bind, rebind or unbind", %{a: a, type_a: type} do
      s = a.schema_name
      rule = published!(s)
      before = audits(s)
      assert call(:get, "/", a, @designer).status == 200

      assert put_hook(a, type, pin(rule), @designer).status == 403
      assert put_hook(a, type, Map.put(pin(rule), "rebind", true), @designer).status == 403
      assert call(:delete, "/#{type}", a, @designer).status == 403
      assert {bindings(s), audits(s)} == {0, before}
    end

    test "P5 a role without ScriptsWrite cannot list", %{a: a} do
      assert call(:get, "/", a, @auditor).status == 403
      assert call(:get, "/", a, ["TASK_WORKER"]).status == 403
    end
  end

  # ── L: list shape ──────────────────────────────────────────────────────────

  describe "L list" do
    test "L1 only the caller's bindings, ordered, allowlisted, no source or manifest", %{
      a: a,
      b: b
    } do
      sa = a.schema_name
      sb = b.schema_name
      for name <- ["r567_zeta", "r567_alpha"], do: EW.define_type!(sa, name, %{})
      EW.define_type!(sb, "r567_other", %{})

      for name <- ["r567_zeta", "r567_alpha"],
          do: assert(put_hook(a, name, pin(published!(sa))).status == 201)

      assert put_hook(b, "r567_other", pin(published!(sb))).status == 201

      conn = call(:get, "/", a, @admin)
      assert conn.status == 200
      items = json(conn)["items"]
      assert Enum.map(items, & &1["entity_type"]) == ["r567_alpha", "r567_zeta"]

      for item <- items do
        assert item |> Map.keys() |> Enum.sort() ==
                 ~w(bound_at bound_by entity_type script_key script_sha256 script_version updated_at)
      end

      refute conn.resp_body =~ F.doubling_source()
      refute conn.resp_body =~ "manifest"
      refute conn.resp_body =~ "r567_other"
    end
  end

  # ── X: INV-10 ──────────────────────────────────────────────────────────────

  describe "X cross-tenant" do
    test "X1 tenant B naming tenant A's bound type is byte-identical to an absent type", %{
      a: a,
      b: b,
      type_a: type
    } do
      sa = a.schema_name
      rule_a = published!(sa)
      assert put_hook(a, type, pin(rule_a)).status == 201
      {rows, audit_count} = {Repo.all(Binding, prefix: sa), audits(sa)}

      rule_b = published!(b.schema_name)
      bind = pin(rule_b)
      rebind = Map.put(bind, "rebind", true)

      for {method, body} <- [{:put, bind}, {:put, rebind}, {:delete, nil}] do
        real = call(method, "/#{type}", b, @admin, body)
        absent = call(method, "/nowhere_at_all", b, @admin, body)

        assert real.status == 404
        assert {real.status, real.resp_body} == {absent.status, absent.resp_body}
      end

      assert Repo.all(Binding, prefix: sa) == rows
      assert audits(sa) == audit_count
      assert bindings(b.schema_name) == 0
      assert json(call(:get, "/", b, @admin))["items"] == []
    end

    test "X2 a same-named type in B binds independently", %{a: a, b: b, type_a: type} do
      EW.define_type!(b.schema_name, type, %{})
      assert put_hook(a, type, pin(published!(a.schema_name))).status == 201
      assert put_hook(b, type, pin(published!(b.schema_name))).status == 201

      assert [%{"script_key" => ka}] = json(call(:get, "/", a, @admin))["items"]
      assert [%{"script_key" => kb}] = json(call(:get, "/", b, @admin))["items"]
      assert ka != kb
      assert call(:delete, "/#{type}", b, @admin).status == 204
      assert bindings(a.schema_name) == 1
    end
  end

  # ── E: mounted in the full pipeline ────────────────────────────────────────

  describe "E mounted in ApiPipeline" do
    test "E2E1 GET /api/v1/entity-type-hooks answers 200 to ScriptsWrite and 403 without", %{
      a: a
    } do
      ok = Fixture.mint_token!(a, @designer)

      conn =
        Fixture.api_conn(:get, "/api/v1/entity-type-hooks", ok, a.tenant.slug, nil)
        |> Fixture.dispatch_api()

      assert conn.status == 200, conn.resp_body
      assert json(conn)["items"] == []

      denied = Fixture.mint_token!(a, @auditor)

      conn =
        Fixture.api_conn(:get, "/api/v1/entity-type-hooks", denied, a.tenant.slug, nil)
        |> Fixture.dispatch_api()

      assert conn.status == 403
    end
  end
end
