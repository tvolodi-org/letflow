defmodule Letflow.NotificationSteps.DispatcherTest do
  @moduledoc """
  T-2592 (pilot gap G4, the "Register a tenant" pilot): the NOTIFICATION STEP --
  a SERVICE_TASK that sends a REGISTERED template to an ADDRESS read from a
  variable of the running instance, through the existing Notifier adapter, into
  the `notification_deliveries` log.

  The tests below are the acceptance of the task:

    * N1 -- the step sends the registered template (the adapter receives the
      message, the log holds one row);
    * N2 -- `outbound_rate_cap_test`: the send over the cap is a `rate_limited`
      row and NOTHING is sent (the threat: a loop in a definition sends
      thousands of messages);
    * N3 -- the log row holds no address, no subject and no body (INV-4);
    * N4..N10 -- the refusals (an address that is not an address, a missing
      address, an unknown template, a CONSTANT recipient -- the address must
      never sit in the stored definition -- a labelled variable, an unknown
      placeholder, a missing value).

  `async: false`: committed tenant writes, application env and the delivery task.
  """

  use Letflow.DataCase, async: false

  alias Letflow.LoginDiscoveryNotifierDouble, as: Double
  alias Letflow.NotificationSteps.Dispatcher
  alias Letflow.Notifications.Delivery
  alias Letflow.Repo
  alias Letflow.Support.PlatformCallFixture, as: PCF
  alias Letflow.Test.SmtpHelpers, as: S

  @notifier Letflow.LoginDiscovery.Notifier

  setup do
    fx = PCF.tenant!("t2592-notify")
    S.put_app_env!(@notifier, adapter: Double, timeout_ms: 100, max_concurrent: 5)
    Double.set_owner(self())
    on_exit(&Double.reset/0)

    {:ok, fx: fx}
  end

  # The step's declaration: a registered template, the address read from a
  # variable and the declared values.
  defp declaration(overrides \\ %{}) do
    Map.merge(
      %{
        "template_key" => "tenant_registered",
        "recipient" => %{"var" => "admin_email"},
        "values" => %{
          "tenant_name" => %{"var" => "tenant_name"},
          "tenant_slug" => %{"const" => "acme"},
          "registered_by" => %{"var" => "registered_by"}
        }
      },
      overrides
    )
  end

  defp variables(overrides \\ %{}) do
    Map.merge(
      %{
        "admin_email" => "admin@example.com",
        "tenant_name" => "Acme",
        "registered_by" => "Vladimir"
      },
      overrides
    )
  end

  defp run(fx, declaration, variables, opts \\ []) do
    Dispatcher.run(
      declaration,
      variables,
      prefix: fx.schema_name,
      tenant_id: fx.tenant_id,
      trigger_ref: Ecto.UUID.generate(),
      labels: Keyword.get(opts, :labels, %{})
    )
  end

  defp rows(fx), do: Repo.all(Delivery, prefix: fx.schema_name)

  defp set_settings!(fx, settings) do
    {:ok, _} =
      Repo.query("UPDATE tenants SET settings = $1::jsonb WHERE id = $2", [
        settings,
        Ecto.UUID.dump!(fx.tenant_id)
      ])

    :ok
  end

  describe "the send (criteria: the registered template reaches the adapter)" do
    test "N1 the step sends the registered template and logs one row", %{fx: fx} do
      assert {:ok, "sent", nil} = run(fx, declaration(), variables())

      assert_receive {:deliver_message, message}, 2000
      assert message.to == "admin@example.com"
      assert message.subject == "Tenant acme is registered"
      assert message.body == "Hello Vladimir, the tenant Acme (acme) is registered."

      assert [%{status: "sent", reason: nil, template_key: "tenant_registered"}] = rows(fx)
    end

    test "N1b the row carries the tenant, the locale and the trigger reference", %{fx: fx} do
      trigger_ref = Ecto.UUID.generate()

      assert {:ok, "sent", nil} =
               Dispatcher.run(
                 declaration(),
                 variables(),
                 prefix: fx.schema_name,
                 tenant_id: fx.tenant_id,
                 trigger_ref: trigger_ref
               )

      assert [%{tenant_id: tenant_id, locale: "en", trigger_ref: ^trigger_ref}] = rows(fx)
      assert tenant_id == fx.tenant_id
    end
  end

  describe "the send cap (S12: outbound_rate_cap_test)" do
    test "N2 outbound_rate_cap_test: the send over the cap is a rate_limited row, nothing sent",
         %{fx: fx} do
      :ok = set_settings!(fx, %{"notifications.outbound_cap_per_hour" => 1})

      # The first send goes out.
      assert {:ok, "sent", nil} = run(fx, declaration(), variables())
      assert_receive {:deliver_message, _message}, 2000

      # The second one is over the cap: the row says so and NOTHING is sent.
      assert {:ok, "skipped", "rate_limited"} = run(fx, declaration(), variables())
      refute_receive {:deliver_message, _message}, 200

      assert [
               %{status: "sent", reason: nil},
               %{status: "skipped", reason: "rate_limited"}
             ] = rows(fx)
    end

    test "N2b the cap is counted per tenant: another tenant's rows do not count", %{fx: fx} do
      :ok = set_settings!(fx, %{"notifications.outbound_cap_per_hour" => 1})

      other = PCF.tenant!("t2592-notify-other")

      assert {:ok, "sent", nil} =
               Dispatcher.run(
                 declaration(),
                 variables(),
                 prefix: other.schema_name,
                 tenant_id: other.tenant_id,
                 trigger_ref: Ecto.UUID.generate()
               )

      # The other tenant's send does not count against this tenant's cap.
      assert {:ok, "sent", nil} = run(fx, declaration(), variables())
    end
  end

  describe "nothing is stored (INV-4)" do
    test "N3 the log row holds no address, no subject and no body", %{fx: fx} do
      assert {:ok, "sent", nil} = run(fx, declaration(), variables())
      assert_receive {:deliver_message, _message}, 2000

      [row] = rows(fx)
      serialized = inspect(row)

      refute serialized =~ "admin@example.com"
      refute serialized =~ "Tenant acme is registered"
      refute serialized =~ "Hello Vladimir"
      assert row.recipient_user_id == nil
    end
  end

  describe "the refusals" do
    test "N4 an address that is not an address is refused and nothing is sent", %{fx: fx} do
      assert {:error, :notify_recipient_invalid} =
               run(fx, declaration(), variables(%{"admin_email" => "not-an-address"}))

      refute_receive {:deliver_message, _message}, 200
      assert [] = rows(fx)
    end

    test "N5 a missing address variable is refused", %{fx: fx} do
      assert {:error, :notify_recipient_missing} =
               run(fx, declaration(), Map.delete(variables(), "admin_email"))

      refute_receive {:deliver_message, _message}, 200
      assert [] = rows(fx)
    end

    test "N6 an unknown template key is refused", %{fx: fx} do
      assert {:error, :notify_template_unknown} =
               run(fx, declaration(%{"template_key" => "no_such_template"}), variables())

      refute_receive {:deliver_message, _message}, 200
      assert [] = rows(fx)
    end

    test "N7 a CONSTANT recipient is refused: the address never sits in the definition",
         %{fx: fx} do
      assert {:error, :notify_recipient_invalid} =
               run(
                 fx,
                 declaration(%{"recipient" => %{"const" => "admin@example.com"}}),
                 variables()
               )

      refute_receive {:deliver_message, _message}, 200
      assert [] = rows(fx)
    end

    test "N8 a labelled variable is refused: a marked value never leaves the process",
         %{fx: fx} do
      labels = %{"admin_email" => ["secret"]}

      assert {:error, :notify_restricted_variable} =
               run(fx, declaration(), variables(), labels: labels)

      refute_receive {:deliver_message, _message}, 200
      assert [] = rows(fx)
    end

    test "N9 a value that the template does not allow is refused", %{fx: fx} do
      declaration =
        declaration(%{"values" => %{"realm_password" => %{"var" => "realm_password"}}})

      assert {:error, :notify_value_unknown} = run(fx, declaration, variables())
      refute_receive {:deliver_message, _message}, 200
      assert [] = rows(fx)
    end

    test "N10 a missing value variable is refused", %{fx: fx} do
      assert {:error, :notify_value_missing} =
               run(fx, declaration(), Map.delete(variables(), "tenant_name"))

      refute_receive {:deliver_message, _message}, 200
      assert [] = rows(fx)
    end
  end
end
