Code.require_file("../modules/stock/stock_fixture.exs", __DIR__)

defmodule Letflow.Routers.LedgerSettingsTest do
  @moduledoc """
  REQ-835 / GH #4546 (decision 0090 section 5), criteria 1, 2, 3 (route half), 4 and 5: the negative
  balance switch `GET /ledger-settings` and `PUT /ledger-settings/:registration` through the full
  `Letflow.Router` with real OIDC bearer tokens, on committed tenants (Sandbox `:auto`,
  `async: false`). The registry holds the boot registrations plus ONE test registration named
  "test" that declares `negative_balance: :tenant_setting` and belongs to module `stock`
  (installed on the tenants); no compiled module declares the key before REQ-836.

  IDs: LS-1 read and switch with audit, LS-2 repeated PUT writes nothing, LS-3 body, reason and
  registration refusals, LS-4 refused callers (uniform 403), LS-5 scoped grant and non-interactive
  credential, LS-6 cross-tenant (INV-10), LS-7 a posting follows the switch, LS-8 switch back.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Api.Scope.Grants
  alias Letflow.Audit.Entry
  alias Letflow.Identity.User
  alias Letflow.LedgerFixture, as: Fx
  alias Letflow.Modules.Catalog
  alias Letflow.Repo
  alias Letflow.StockFixture, as: S

  @key ["item-1", "loc-1"]
  @base "/api/v1/ledger-settings"
  @on %{"allow_negative" => true, "reason" => "Qoimeks counts after the shipment"}

  setup do
    ctx = S.setup_oidc!([:a, :b, :p])
    a = S.tenant!("lset-a", ctx.names.a)
    b = S.tenant!("lset-b", ctx.names.b)
    p = S.tenant!("lset-p", ctx.names.p, platform: true, install: false)

    # S.setup_oidc! installed the boot registry; add the settable test registration under module stock.
    registry =
      Fx.registry()
      |> Map.new(fn {id, entry} ->
        {id, Map.merge(entry, %{module_id: "stock", registration: Fx.settable_registration()})}
      end)

    Fx.put_registry!(Map.merge(Catalog.ledger_registry(), registry))

    Map.merge(ctx, %{
      a: a,
      b: b,
      p: p,
      adm_a: S.token(ctx, :a, ["TENANT_ADMIN"], sub: "ledger-admin-a"),
      adm_b: S.token(ctx, :b, ["TENANT_ADMIN"], sub: "ledger-admin-b")
    })
  end

  defp request(method, path, token, body \\ nil) do
    conn =
      case body do
        nil -> Plug.Test.conn(method, @base <> path)
        body -> Plug.Test.conn(method, @base <> path, Jason.encode!(body))
      end

    conn
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> then(&Letflow.Router.call(&1, Letflow.Router.init([])))
  end

  defp items(token) do
    conn = request(:get, "", token)
    assert conn.status == 200, conn.resp_body
    S.json(conn)["items"]
  end

  defp settings_rows(schema),
    do: Repo.aggregate("ledger_balance_settings", :count, prefix: schema)

  defp changed(schema),
    do: Repo.all(from(e in Entry, where: e.action == "ledger_setting.changed"), prefix: schema)

  defp issue(schema, qty \\ -1) do
    Fx.post_tx(
      Fx.capability(schema, "issue", [Fx.leg(@key, qty)],
        registration: Fx.settable_registration()
      )
    )
  end

  test "LS-1 GET lists the one switchable registration as refuse; PUT allow shows the caller and the reason; one audit entry",
       ctx do
    assert [item] = items(ctx.adm_a)

    assert item == %{
             "registration" => "test",
             "allow_negative" => false,
             "changed_by" => nil,
             "changed_by_name" => nil,
             "changed_at" => nil,
             "reason" => nil
           }

    conn = request(:put, "/test", ctx.adm_a, @on)
    assert conn.status == 200, conn.resp_body

    caller =
      Repo.one!(from(u in User, where: u.username == "ledger-admin-a"), prefix: ctx.a.schema_name)

    assert %{"allow_negative" => true, "changed_by" => changed_by, "reason" => reason} =
             S.json(conn)

    assert changed_by == caller.id
    assert reason == @on["reason"]

    assert [%{"allow_negative" => true, "changed_by" => ^changed_by, "reason" => ^reason}] =
             items(ctx.adm_a)

    assert [entry] = changed(ctx.a.schema_name)
    assert entry.actor_id == caller.id
    assert entry.before_state == %{"registration" => "test", "allow_negative" => false}

    assert entry.after_state ==
             %{"registration" => "test", "allow_negative" => true, "reason" => @on["reason"]}
  end

  test "LS-2 a repeated identical PUT writes no row and no audit entry; a PUT of refuse with no row writes nothing",
       ctx do
    s = ctx.a.schema_name

    assert request(:put, "/test", ctx.adm_a, %{"allow_negative" => false, "reason" => "same"}).status ==
             200

    assert settings_rows(s) == 0 and changed(s) == []

    assert request(:put, "/test", ctx.adm_a, @on).status == 200
    assert settings_rows(s) == 1 and length(changed(s)) == 1

    assert request(:put, "/test", ctx.adm_a, %{@on | "reason" => "second text"}).status == 200
    assert settings_rows(s) == 1 and length(changed(s)) == 1
    assert [%{"reason" => "Qoimeks counts after the shipment"}] = items(ctx.adm_a)
  end

  test "LS-3 refusals write nothing: invalid_body, invalid_reason, not_switchable, reason never echoed",
       ctx do
    s = ctx.a.schema_name
    secret = "SECRET-REASON-TEXT"

    cases = [
      {"/test", Map.put(@on, "extra", 1), "invalid_body"},
      {"/test", %{"allow_negative" => "yes", "reason" => "ok"}, "invalid_body"},
      {"/test", %{"reason" => "ok"}, "invalid_body"},
      {"/test", %{"allow_negative" => true}, "invalid_reason"},
      {"/test", %{"allow_negative" => true, "reason" => "   "}, "invalid_reason"},
      {"/test", %{"allow_negative" => true, "reason" => secret <> <<0x202E::utf8>>},
       "invalid_reason"},
      {"/nope", @on, "not_switchable"},
      # installed module, registration does not declare the key
      {"/stock", @on, "not_switchable"},
      # the assets registration declares no key (and its module is not installed here)
      {"/assets", @on, "not_switchable"}
    ]

    for {path, body, text} <- cases do
      conn = request(:put, path, ctx.adm_a, body)
      assert conn.status == 422, "#{path} #{inspect(body)} -> #{conn.status}"
      assert conn.resp_body =~ text
      refute conn.resp_body =~ secret
    end

    assert settings_rows(s) == 0
    assert changed(s) == []
  end

  test "LS-4 STOREKEEPER, TENANT_AUDITOR and the platform tenant's PLATFORM_ADMIN get the same 403 on both routes",
       ctx do
    s = ctx.a.schema_name

    refused = [
      {:a, ["STOREKEEPER"]},
      {:a, ["TENANT_AUDITOR"]},
      {:a, ["TASK_WORKER"]},
      {:p, ["PLATFORM_ADMIN"]}
    ]

    bodies =
      for {name, roles} <- refused,
          {method, path, body} <- [{:get, "", nil}, {:put, "/test", @on}] do
        conn = request(method, path, S.token(ctx, name, roles), body)
        assert conn.status == 403, "#{name} #{inspect(roles)} #{method}: #{conn.status}"
        conn.resp_body
      end

    # the bodies differ only in the request's trace_id
    stripped = Enum.map(bodies, &String.replace(&1, ~r/"trace_id":"[^"]*"/, ""))
    assert stripped |> Enum.uniq() |> length() == 1
    assert settings_rows(s) == 0 and changed(s) == []
    assert settings_rows(ctx.p.schema_name) == 0
  end

  test "LS-5 a scoped TENANT_ADMIN grant and a non-interactive credential are refused by the handler",
       ctx do
    uid = Ecto.UUID.generate()

    scoped = %Grants{
      user_id: uid,
      rows_by_role: %{
        "TENANT_ADMIN" => [%{principal_type: :group, tenant_wide: false, scope_node_id: "n1"}]
      }
    }

    wide = %Grants{
      user_id: uid,
      rows_by_role: %{
        "TENANT_ADMIN" => [%{principal_type: :group, tenant_wide: true, scope_node_id: nil}]
      }
    }

    call = fn method, path, credential, grants ->
      auth = %{
        user_id: uid,
        tenant_id: ctx.a.tenant_id,
        roles: ["TENANT_ADMIN"],
        credential: credential,
        scope_grants: grants
      }

      Plug.Test.conn(method, path)
      |> Map.put(:body_params, @on)
      |> Plug.Conn.assign(:auth_context, auth)
      |> Letflow.Routers.LedgerSettings.call(Letflow.Routers.LedgerSettings.init([]))
    end

    for {credential, grants} <- [{:oidc, scoped}, {:api_token, wide}, {nil, wide}],
        {method, path} <- [{:get, "/"}, {:put, "/test"}] do
      conn = call.(method, path, credential, grants)
      assert conn.status == 403, "#{inspect(credential)} #{method}"
      assert conn.resp_body =~ "insufficient permissions"
    end

    assert settings_rows(ctx.a.schema_name) == 0
  end

  test "LS-6 tenant B's admin switches only B's row; A's list and A's posting below zero are unchanged",
       ctx do
    assert request(:put, "/test", ctx.adm_b, @on).status == 200

    assert settings_rows(ctx.b.schema_name) == 1
    assert settings_rows(ctx.a.schema_name) == 0
    assert [%{"allow_negative" => false}] = items(ctx.adm_a)
    assert [%{"allow_negative" => true}] = items(ctx.adm_b)
    assert changed(ctx.a.schema_name) == []

    # a tenant_id in the body is refused as an extra key and writes nothing anywhere
    conn = request(:put, "/test", ctx.adm_a, Map.put(@on, "tenant_id", ctx.b.tenant_id))
    assert conn.status == 422
    assert settings_rows(ctx.a.schema_name) == 0

    assert {:error, {:ledger_refused, :insufficient_balance, _, _}} = issue(ctx.a.schema_name)
    assert {:ok, _} = issue(ctx.b.schema_name)
  end

  test "LS-7 after the switch through the route a posting below zero is accepted (real token, real router); LS-8 switching back refuses again",
       ctx do
    s = ctx.a.schema_name
    assert {:error, {:ledger_refused, :insufficient_balance, _, _}} = issue(s)

    assert request(:put, "/test", ctx.adm_a, @on).status == 200
    assert {:ok, _} = issue(s, -2)
    assert Fx.balance(s, @key).on_hand |> Decimal.eq?(-2)

    back = %{"allow_negative" => false, "reason" => "counts are done"}
    assert request(:put, "/test", ctx.adm_a, back).status == 200
    assert length(changed(s)) == 2
    assert {:error, {:ledger_refused, :insufficient_balance, _, _}} = issue(s)
  end
end
