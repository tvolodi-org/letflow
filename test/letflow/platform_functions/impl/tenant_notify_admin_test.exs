defmodule Letflow.PlatformFunctions.Impl.TenantNotifyAdminTest do
  @moduledoc """
  The body of `tenant.notify_admin` (T-2727, finding V8; design
  `docs/design/provision-realm-and-invite-paths.md` rows N2..N7): the
  registration notice of `platform.register_tenant` v2, sent as a platform step
  through the notification dispatcher.

    * NA1 -- the notice is sent once: the adapter receives it, one delivery row
      `sent` with no address (row N2);
    * NA2 -- a second run (a crash takeover, a DLQ retry) after a sent notice
      sends NOTHING and answers success (row N3);
    * NA3 -- a recipient domain that is not on the platform allow-list is
      refused before the send: no mail, no row (row N4);
    * NA4 -- a failed send is `platform_call_notify_failed`, and the retry
      sends it again once (row N5);
    * NA5 -- the Noop adapter (no mail configured) counts as done (row N6);
    * NA6 -- an address that is not a string or is over the byte cap, and an
      instance id that is not a UUID, are refused before anything is read
      (row N7, SF-01);
    * NA7 -- the body is registered and its refusal codes are codes of the
      dispatch row.

  `async: false`: the platform tenant pin, the notifier configuration and
  committed tenant writes.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.LoginDiscoveryNotifierDouble, as: Double
  alias Letflow.Notifications.Delivery
  alias Letflow.OutboundDestinations
  alias Letflow.PlatformFunctions.Dispatcher
  alias Letflow.PlatformFunctions.Impl.TenantNotifyAdmin
  alias Letflow.PlatformFunctions.Registry
  alias Letflow.Support.PlatformCallFixture, as: PCF
  alias Letflow.Support.PlatformTenantFixture
  alias Letflow.Test.SandboxAutoMode
  alias Letflow.Test.SmtpHelpers, as: S

  @notifier Letflow.LoginDiscovery.Notifier

  setup do
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)
    fx = PCF.tenant!("t2727-notify")
    PlatformTenantFixture.pin!(fx.tenant_id)

    {:ok, _entry} = OutboundDestinations.add(fx.schema_name, nil, "email", nil)
    {:ok, _entry} = OutboundDestinations.add(fx.schema_name, nil, "email", "example.com")

    S.put_app_env!(@notifier, adapter: Double, timeout_ms: 100, max_concurrent: 5)
    Double.set_owner(self())
    on_exit(&Double.reset/0)

    {:ok, fx: fx}
  end

  defp context(instance_id, overrides \\ %{}) do
    %{
      inputs:
        Map.merge(
          %{
            "tenant_id" => Ecto.UUID.generate(),
            "admin_email" => "owner@example.com",
            "name" => "Acme",
            "slug" => "acme"
          },
          overrides
        ),
      dispatch: %{instance_id: instance_id}
    }
  end

  defp rows(fx, instance_id) do
    Repo.all(from(d in Delivery, where: d.trigger_ref == ^instance_id), prefix: fx.schema_name)
  end

  test "NA1 the notice is sent once; the row holds no address", %{fx: fx} do
    id = Ecto.UUID.generate()
    assert {:ok, %{}} = TenantNotifyAdmin.run(context(id))

    assert_receive {:deliver_message, message}, 2000
    assert message.to == "owner@example.com"

    assert [%{status: "sent", template_key: "tenant_registered"} = row] = rows(fx, id)
    refute inspect(row) =~ "owner@example.com"
  end

  test "NA2 a second run after a sent notice sends nothing and answers success", %{fx: fx} do
    id = Ecto.UUID.generate()
    assert {:ok, %{}} = TenantNotifyAdmin.run(context(id))
    assert_receive {:deliver_message, _first}, 2000

    assert {:ok, %{}} = TenantNotifyAdmin.run(context(id))
    refute_receive {:deliver_message, _again}, 200
    assert length(rows(fx, id)) == 1
  end

  test "NA3 a domain not on the allow-list is refused before the send", %{fx: fx} do
    id = Ecto.UUID.generate()

    assert {:error, :platform_call_notify_refused} =
             TenantNotifyAdmin.run(context(id, %{"admin_email" => "owner@not-listed.test"}))

    refute_receive {:deliver_message, _message}, 200
    assert rows(fx, id) == []
  end

  test "NA4 a failed send is retryable and the retry sends once", %{fx: fx} do
    id = Ecto.UUID.generate()
    Double.set_behaviour(:error)

    assert {:error, :platform_call_notify_failed} = TenantNotifyAdmin.run(context(id))
    assert [%{status: "failed"}] = rows(fx, id)

    Double.set_behaviour(:ok)
    assert {:ok, %{}} = TenantNotifyAdmin.run(context(id))
    assert Enum.count(rows(fx, id), &(&1.status == "sent")) == 1
  end

  test "NA5 the Noop adapter counts as done", %{fx: fx} do
    id = Ecto.UUID.generate()
    S.put_app_env!(@notifier, adapter: Letflow.LoginDiscovery.Notifier.Noop)

    assert {:ok, %{}} = TenantNotifyAdmin.run(context(id))
    assert [%{status: "skipped", reason: "adapter_noop"}] = rows(fx, id)
  end

  test "NA6 malformed inputs are refused before anything is read", %{fx: fx} do
    id = Ecto.UUID.generate()
    over_cap = String.duplicate("a", 250) <> "@example.com"

    assert {:error, :platform_call_invalid_email} =
             TenantNotifyAdmin.run(context(id, %{"admin_email" => over_cap}))

    assert {:error, :platform_call_invalid_email} =
             TenantNotifyAdmin.run(context(id, %{"admin_email" => nil}))

    assert {:error, :platform_call_arg_invalid} = TenantNotifyAdmin.run(context("not-a-uuid"))

    assert {:error, :platform_call_arg_invalid} =
             TenantNotifyAdmin.run(context(id, %{"tenant_id" => "x"}))

    assert {:error, :platform_call_arg_invalid} = TenantNotifyAdmin.run(%{})
    refute_receive {:deliver_message, _message}, 100
    assert rows(fx, id) == []
  end

  test "NA7 the body is registered and its codes are codes of the dispatch row" do
    assert {:ok, {TenantNotifyAdmin, :run, 1}} = Registry.fetch("tenant.notify_admin")

    for code <- ~w(platform_call_notify_refused platform_call_notify_failed) do
      assert code in Dispatcher.failure_codes()
    end
  end
end
