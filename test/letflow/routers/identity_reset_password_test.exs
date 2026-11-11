defmodule Letflow.Routers.IdentityResetPasswordTest do
  @moduledoc """
  REQ-788 (GH #4135): `POST /identity/users/:id/reset-password` sends a "Forgot password"
  instruction mail and nothing else (decisions 0072 D1, 0085 D6). Test ids R1..R10 follow the
  T-1632 design (R11/R12 are the grep and static checks run by hand).

  Dispatch is direct `Letflow.Routers.Identity.call/2` with a hand-assigned `auth_context`, as
  `identity_test.exs` does. `async: false`: committed tenants, application env and delivery tasks.
  """

  use Letflow.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias Letflow.Audit.Entry
  alias Letflow.Identity.Group
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Identity.User
  alias Letflow.LoginDiscovery.Notifier.Noop
  alias Letflow.LoginDiscoveryNotifierDouble, as: Double
  alias Letflow.NotificationTemplates
  alias Letflow.Notifications.Delivery
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Test.SmtpHelpers, as: S

  @opts Letflow.Routers.Identity.init([])
  @notifier Letflow.LoginDiscovery.Notifier
  @action "user.password_reset_requested"

  setup do
    tenants = Fixture.two_tenants!()
    Fixture.unpin!()
    S.put_app_env!(@notifier, adapter: Double, timeout_ms: 500, max_concurrent: 5)
    Double.set_owner(self())
    on_exit(&Double.reset/0)
    tenants
  end

  defp call(tenant, id, roles, body \\ %{}) do
    conn =
      conn(:post, "/users/#{id}/reset-password")
      |> then(fn c ->
        if body,
          do: %{c | body_params: body} |> put_req_header("content-type", "application/json"),
          else: c
      end)
      |> assign(:auth_context, %{
        user_id: Ecto.UUID.generate(),
        tenant_id: tenant.tenant_id,
        roles: roles
      })
      |> assign(:trace_id, "fixed-test-trace-id")

    Letflow.Routers.Identity.call(conn, @opts)
  end

  defp user!(tenant, attrs \\ %{}) do
    default = %{
      username: "u-#{Ecto.UUID.generate()}",
      display_name: "Reset Person",
      email: "reset-#{System.unique_integer([:positive])}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :oidc,
      external_id: "ext-#{Ecto.UUID.generate()}",
      external_realm: "realm-test"
    }

    %User{}
    |> Ecto.Changeset.change(Map.merge(default, attrs))
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  defp audits(tenant),
    do: Repo.all(Entry, prefix: tenant.schema_name) |> Enum.filter(&(&1.action == @action))

  defp deliveries(tenant), do: Repo.all(Delivery, prefix: tenant.schema_name)

  defp await_deliveries(tenant) do
    Enum.reduce_while(1..100, [], fn _i, _acc ->
      found = deliveries(tenant)

      if found != [] do
        {:halt, found}
      else
        Process.sleep(20)
        {:cont, []}
      end
    end)
  end

  # "Nothing written" assertions: give a stray delivery task time to show up first.
  defp assert_nothing_written(tenants) do
    Process.sleep(200)

    for t <- tenants do
      assert audits(t) == []
      assert deliveries(t) == []
    end
  end

  test "R1 the policy key and the route inventory", _ do
    assert Letflow.Api.Authorization.endpoint_policy_key("POST", "/users/:id/reset-password") ==
             :UsersManage

    assert Enum.any?(Letflow.Routers.Identity.__authz_routes__(), fn route ->
             inspect(route) =~ "/users/:id/reset-password"
           end)
  end

  defp old_entry!(tenant, user, minutes_ago, action \\ @action) do
    Letflow.Support.OnGateFixture.raw_entry!(tenant, %{
      action: action,
      resource_type: "user",
      resource_id: user.id,
      timestamp: DateTime.add(DateTime.utc_now(), -minutes_ago * 60, :second),
      after_state: nil
    })
  end

  defp put_window!(value) do
    old = Application.get_env(:letflow, Letflow.Routers.Identity)
    Application.put_env(:letflow, Letflow.Routers.Identity, reset_password_window_minutes: value)

    on_exit(fn ->
      if old,
        do: Application.put_env(:letflow, Letflow.Routers.Identity, old),
        else: Application.delete_env(:letflow, Letflow.Routers.Identity)
    end)
  end

  test "R2 two posts: both 202, one audit entry, one delivery row", %{a: a} do
    user = user!(a)

    for body <- [%{}, %{}] do
      conn = call(a, user.id, ["TENANT_ADMIN"], body)
      assert conn.status == 202
      assert Jason.decode!(conn.resp_body) == %{"status" => "requested"}
    end

    assert [first] = audits(a)
    assert first.resource_type == "user" and first.resource_id == user.id
    assert first.before_state == nil and first.after_state == nil
    assert first.actor_id != nil

    assert [row] = await_deliveries(a)
    Process.sleep(100)
    assert [_one] = deliveries(a)
    assert row.template_key == "password_reset_hint"
    assert row.recipient_user_id == user.id
    assert row.trigger_ref == first.id
  end

  test "R13a an entry 4 minutes old throttles: 202, nothing new", %{a: a} do
    user = user!(a)
    old_entry!(a, user, 4)
    assert call(a, user.id, ["TENANT_ADMIN"]).status == 202
    Process.sleep(200)
    assert length(audits(a)) == 1
    assert deliveries(a) == []
  end

  test "R13b an entry 6 minutes old does not throttle", %{a: a} do
    user = user!(a)
    old_entry!(a, user, 6)
    assert call(a, user.id, ["TENANT_ADMIN"]).status == 202
    assert length(audits(a)) == 2
    assert [_row] = await_deliveries(a)
  end

  test "R14 the window is a setting; bad values fall back to 5", %{a: a} do
    user = user!(a)
    put_window!(10)
    old_entry!(a, user, 6)
    assert call(a, user.id, ["TENANT_ADMIN"]).status == 202
    assert length(audits(a)) == 1

    for bad <- [0, -1, "10", nil] do
      put_window!(bad)
      u = user!(a)
      old_entry!(a, u, 6)
      assert call(a, u.id, ["TENANT_ADMIN"]).status == 202
      assert length(Enum.filter(audits(a), &(&1.resource_id == u.id))) == 2, inspect(bad)

      v = user!(a)
      old_entry!(a, v, 4)
      assert call(a, v.id, ["TENANT_ADMIN"]).status == 202
      assert length(Enum.filter(audits(a), &(&1.resource_id == v.id))) == 1, inspect(bad)
    end
  end

  test "R15 another user's or another action's entry does not throttle", %{a: a} do
    x = user!(a)
    y = user!(a)
    old_entry!(a, x, 1)
    assert call(a, y.id, ["TENANT_ADMIN"]).status == 202
    assert Enum.count(audits(a), &(&1.resource_id == y.id)) == 1

    z = user!(a)
    old_entry!(a, z, 1, "user.update_status")
    assert call(a, z.id, ["TENANT_ADMIN"]).status == 202
    assert Enum.count(audits(a), &(&1.resource_id == z.id)) == 1
  end

  test "R16 refusals still win over the throttle", %{a: a} do
    user = user!(a)
    old_entry!(a, user, 1)
    conn = call(a, user.id, ["TENANT_ADMIN"], %{"k" => "v"})
    assert conn.status == 422 and conn.resp_body =~ "body_not_accepted"

    inactive = user!(a, %{status: :inactive})
    old_entry!(a, inactive, 1)
    conn = call(a, inactive.id, ["TENANT_ADMIN"])
    assert conn.status == 409 and conn.resp_body =~ "user_inactive"
  end

  test "R17 lock, check and insert share one transaction; delivery follows it" do
    src = File.read!("lib/letflow/routers/identity.ex")
    {lock, _} = :binary.match(src, "pg_advisory_xact_lock(hashtext")
    {check, _} = :binary.match(src, "Audit.latest_matching(prefix")
    {insert, _} = :binary.match(src, "Audit.insert_entry(Letflow.Repo")
    {call_at, _} = :binary.match(src, "run_reset_txn(user, attrs")
    {deliver, _} = :binary.match(src, "start_reset_delivery(user, entry.id")
    assert call_at < deliver
    assert lock < check and check < insert
  end

  test "R18 a throttled response equals an accepted one", %{a: a} do
    user = user!(a)
    accepted = call(a, user.id, ["TENANT_ADMIN"])
    throttled = call(a, user.id, ["TENANT_ADMIN"])
    assert {throttled.status, throttled.resp_body} == {accepted.status, accepted.resp_body}

    names = fn c -> c.resp_headers |> Enum.map(&elem(&1, 0)) |> Enum.sort() end
    assert names.(throttled) == names.(accepted)
  end

  test "R19 the setting is documented and read from application config only" do
    src = File.read!("lib/letflow/routers/identity.ex")
    assert src =~ "reset_password_window_minutes"
    refute src =~ "System.get_env(\"RESET"
  end

  test "R3 other roles get 403 and nothing is written", %{a: a, b: b} do
    user = user!(a)

    for role <-
          ~w(PROCESS_DESIGNER PROCESS_OPERATOR TASK_WORKER AGENT_RUNNER CANDIDATE TENANT_AUDITOR STOREKEEPER) do
      assert call(a, user.id, [role]).status == 403, role
    end

    assert call(a, user.id, []).status == 403
    assert_nothing_written([a, b])
  end

  test "R4 cross-tenant id is the same 404 as a random id; non-UUID too", %{a: a, b: b} do
    foreign = user!(b)
    foreign_conn = call(a, foreign.id, ["TENANT_ADMIN"])
    random_conn = call(a, Ecto.UUID.generate(), ["TENANT_ADMIN"])
    assert foreign_conn.status == 404

    assert {random_conn.status, random_conn.resp_body} ==
             {foreign_conn.status, foreign_conn.resp_body}

    assert call(a, "not-a-uuid", ["TENANT_ADMIN"]).status == 404
    assert_nothing_written([a, b])
  end

  test "R5 a platform-admin group member is 403 for a customer-tenant admin", %{a: a, b: b} do
    group =
      %Group{}
      |> Ecto.Changeset.change(%{name: "g-#{Ecto.UUID.generate()}", display_name: "G"})
      |> Repo.insert!(prefix: a.schema_name)

    Fixture.pin!(a.tenant_id)

    {:ok, _role} =
      RoleRegistry.upsert_role("PLATFORM_ADMIN", :platform_role, group.id, prefix: a.schema_name)

    member = user!(a)

    %GroupMember{}
    |> Ecto.Changeset.change(%{group_id: group.id, user_id: member.id})
    |> Repo.insert!(prefix: a.schema_name)

    Fixture.pin!(b.tenant_id)
    conn = call(a, member.id, ["TENANT_ADMIN"])
    assert conn.status == 403
    assert conn.resp_body =~ "insufficient permissions"
    assert_nothing_written([a, b])
  end

  test "R6 any body key is 422 body_not_accepted, before the state checks", %{a: a, b: b} do
    active = user!(a)
    inactive = user!(a, %{status: :inactive})

    for u <- [active, inactive] do
      conn = call(a, u.id, ["TENANT_ADMIN"], %{"password" => "x"})
      assert conn.status == 422
      assert conn.resp_body =~ "body_not_accepted"
    end

    assert_nothing_written([a, b])
  end

  test "R7 state refusals are 409 with a fixed detail and in a fixed order", %{a: a, b: b} do
    internal = %{auth_source: :internal, external_id: nil, external_realm: nil}

    cases = [
      {"user_inactive", user!(a, %{status: :inactive})},
      {"no_identity_provider_login", user!(a, internal)},
      {"no_email", user!(a, %{email: "   "})},
      {"user_inactive", user!(a, Map.put(internal, :status, :inactive))},
      {"no_identity_provider_login", user!(a, Map.put(internal, :email, ""))}
    ]

    for {detail, u} <- cases do
      conn = call(a, u.id, ["TENANT_ADMIN"])
      assert conn.status == 409
      assert conn.resp_body =~ detail
    end

    assert_nothing_written([a, b])
  end

  test "R8a registry key, placeholders and default text" do
    alias Letflow.NotificationTemplates.Registry
    assert Registry.placeholders("password_reset_hint") == ~w(user_name tenant_name)
    assert Registry.default("password_reset_hint", :subject) == "Set a new password"
    body = Registry.default("password_reset_hint", :body)
    assert body =~ "{user_name}" and body =~ "{tenant_name}" and body =~ ~s("Forgot password")
    refute body =~ "http"
  end

  test "R8b a stored template replaces the default", %{a: a} do
    {:ok, _, _} =
      NotificationTemplates.put(
        a.schema_name,
        a.tenant_id,
        nil,
        "password_reset_hint",
        "en",
        "Own subject",
        "Hi {user_name} at {tenant_name}"
      )

    user = user!(a)
    assert call(a, user.id, ["TENANT_ADMIN"]).status == 202
    assert_receive {:deliver_message, msg}, 2000
    assert msg.subject == "Own subject"
    assert msg.body =~ "Hi Reset Person at"
  end

  test "R9a the mail goes to the stored email and holds no link or secret", %{a: a} do
    user = user!(a)
    assert call(a, user.id, ["TENANT_ADMIN"]).status == 202
    assert_receive {:deliver_message, msg}, 2000
    assert msg.to == user.email
    refute msg.subject =~ "http"
    refute msg.body =~ "http"
    refute String.downcase(msg.body) =~ "token"
    assert [%{status: "sent"}] = await_deliveries(a)
  end

  test "R9b the Noop adapter still answers 202, row skipped/adapter_noop", %{a: a} do
    S.put_app_env!(@notifier, adapter: Noop)
    user = user!(a)
    assert call(a, user.id, ["TENANT_ADMIN"]).status == 202
    assert [%{status: "skipped", reason: "adapter_noop"}] = await_deliveries(a)
  end

  test "R9c an adapter error still answers 202, row failed/adapter_error", %{a: a} do
    Double.set_behaviour(:error)
    user = user!(a)
    assert call(a, user.id, ["TENANT_ADMIN"]).status == 202
    assert [%{status: "failed", reason: "adapter_error"}] = await_deliveries(a)
  end

  test "R10 a failing audit write answers 500 and starts no delivery", %{a: a} do
    name = "rp_fault_#{System.unique_integer([:positive])}"
    schema = a.schema_name

    Repo.query!(
      ~s|CREATE FUNCTION "#{schema}".#{name}() RETURNS trigger LANGUAGE plpgsql AS $$ | <>
        ~s|BEGIN IF NEW.action = '#{@action}' THEN | <>
        ~s|RAISE EXCEPTION 'injected fault (REQ-788 test)'; END IF; RETURN NEW; END $$|
    )

    Repo.query!(
      ~s|CREATE TRIGGER #{name} BEFORE INSERT ON "#{schema}".audit_entries | <>
        ~s|FOR EACH ROW EXECUTE FUNCTION "#{schema}".#{name}()|
    )

    on_exit(fn ->
      Repo.query!(~s|DROP TRIGGER IF EXISTS #{name} ON "#{schema}".audit_entries|)
      Repo.query!(~s|DROP FUNCTION IF EXISTS "#{schema}".#{name}()|)
    end)

    user = user!(a)
    assert call(a, user.id, ["TENANT_ADMIN"]).status == 500
    Process.sleep(200)
    assert deliveries(a) == []
    assert audits(a) == []
  end
end
