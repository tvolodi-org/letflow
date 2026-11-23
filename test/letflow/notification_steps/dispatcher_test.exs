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
      placeholder, a missing value);
    * N14..N17 -- the refusals of the rework (a missing or malformed trigger
      reference, a number too large to convert) and the cap that holds when
      the delivery row cannot be written (N16: the reservation is taken
      BEFORE the send, so an unwritable log row is not an uncounted send).

  `async: false`: committed tenant writes, application env and the delivery task.
  """

  use Letflow.DataCase, async: false

  alias Letflow.LoginDiscoveryNotifierDouble, as: Double
  alias Letflow.NotificationSteps.Dispatcher
  alias Letflow.Notifications
  alias Letflow.Notifications.Delivery
  alias Letflow.Notifications.OutboundCounter
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
                 trigger_ref: trigger_ref,
                 labels: %{}
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
                 trigger_ref: Ecto.UUID.generate(),
                 labels: %{}
               )

      # The other tenant's send does not count against this tenant's cap.
      assert {:ok, "sent", nil} = run(fx, declaration(), variables())
    end

    test "N2c the cap is per tenant and CHANNEL: the template key does not multiply it",
         %{fx: fx} do
      :ok = set_settings!(fx, %{"notifications.outbound_cap_per_hour" => 1})

      # The first send takes the tenant's only slot of the hour.
      assert {:ok, "sent", nil} = run(fx, declaration(), variables())
      assert_receive {:deliver_message, _message}, 2000

      # A send of ANOTHER template is over the same cap: the cap counts the
      # tenant's outbound CHANNEL, not the template key (the decided rule is a
      # cap per tenant and channel; a definition that rotates keys must not
      # reach 8x the ceiling).
      other = %{
        "template_key" => "task_assigned",
        "recipient" => %{"var" => "admin_email"},
        "values" => %{}
      }

      assert {:ok, "skipped", "rate_limited"} = run(fx, other, variables())
      refute_receive {:deliver_message, _message2}, 200
    end

    test "N2d the reservation is taken BEFORE the send and recorded in the tenant's counter",
         %{fx: fx} do
      :ok = set_settings!(fx, %{"notifications.outbound_cap_per_hour" => 1})

      assert {:ok, "sent", nil} = run(fx, declaration(), variables())
      assert_receive {:deliver_message, _message}, 2000

      # The counter of the tenant's own schema holds the reservation: one row
      # per window (the clock hour and the UTC day), each with one send.
      counters = Repo.all(OutboundCounter, prefix: fx.schema_name)

      assert length(counters) == 2
      assert Enum.all?(counters, &(&1.send_count == 1))
      assert Enum.all?(counters, &(&1.tenant_id == Ecto.UUID.cast!(fx.tenant_id)))
      assert Enum.map(counters, & &1.period) |> Enum.sort() == ["day", "hour"]
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

    test "N11 the labels are required: a step that cannot see them refuses", %{fx: fx} do
      # A labelled variable never leaves the process (decision 0062 R12), so a
      # step that is not told which variables are labelled cannot run at all.
      assert {:error, :notify_labels_missing} =
               Dispatcher.run(
                 declaration(),
                 variables(),
                 prefix: fx.schema_name,
                 trigger_ref: Ecto.UUID.generate()
               )

      refute_receive {:deliver_message, _message}, 200
      assert [] = rows(fx)
    end

    test "N12 the row's tenant is the tenant of the PREFIX, never a field of the caller",
         %{fx: fx} do
      # A row physically sits in ONE tenant's schema, so the tenant it claims to
      # belong to is derived from that schema (decision 0003's addendum). The
      # dispatcher takes no tenant at all: there is nothing for a caller to
      # disagree with.
      assert {:ok, "sent", nil} = run(fx, declaration(), variables())

      assert [%{tenant_id: tenant_id}] = rows(fx)
      assert tenant_id == fx.tenant_id
    end

    test "N13 a prefix that names no tenant is refused: nothing is sent, no row", %{fx: fx} do
      assert {:error, :notify_invalid_schema} =
               Dispatcher.run(
                 declaration(),
                 variables(),
                 prefix: "not_a_tenant_schema",
                 trigger_ref: Ecto.UUID.generate(),
                 labels: %{}
               )

      refute_receive {:deliver_message, _message}, 200
      assert [] = rows(fx)
    end

    test "N14 a missing trigger reference is refused: nothing is sent, no row", %{fx: fx} do
      # The delivery row carries the trigger reference, and a step that cannot
      # write its row cannot account for its send: the reference is required
      # exactly like the labels.
      assert {:error, :notify_trigger_ref_missing} =
               Dispatcher.run(
                 declaration(),
                 variables(),
                 prefix: fx.schema_name,
                 labels: %{}
               )

      refute_receive {:deliver_message, _message}, 200
      assert [] = rows(fx)
    end

    test "N15 a trigger reference that is not a UUID is refused: nothing is sent, no row",
         %{fx: fx} do
      assert {:error, :notify_trigger_ref_missing} =
               Dispatcher.run(
                 declaration(),
                 variables(),
                 prefix: fx.schema_name,
                 trigger_ref: "not-a-uuid",
                 labels: %{}
               )

      refute_receive {:deliver_message, _message}, 200
      assert [] = rows(fx)
    end

    test "N16 the cap holds when the delivery row cannot be written", %{fx: fx} do
      :ok = set_settings!(fx, %{"notifications.outbound_cap_per_hour" => 1})

      # The first send: the delivery row CANNOT be written (the trigger
      # reference is not a UUID, so the changeset raises), so the log stays
      # empty -- but the slot of the cap was RESERVED before the send left, so
      # the send is counted. (The outcome is the log write's failure, not the
      # adapter's: the mail HAS gone out.)
      assert {"failed", "adapter_error"} =
               Notifications.deliver_to_address(
                 "tenant_registered",
                 "admin@example.com",
                 "not-a-uuid",
                 %{
                   "tenant_name" => "Acme",
                   "tenant_slug" => "acme",
                   "registered_by" => "Vladimir"
                 },
                 fx.schema_name
               )

      assert_receive {:deliver_message, _message}, 2000
      assert [] = rows(fx)

      # The second send is over the cap: the reservation counted the first one.
      assert {"skipped", "rate_limited"} =
               Notifications.deliver_to_address(
                 "tenant_registered",
                 "admin@example.com",
                 Ecto.UUID.generate(),
                 %{
                   "tenant_name" => "Acme",
                   "tenant_slug" => "acme",
                   "registered_by" => "Vladimir"
                 },
                 fx.schema_name
               )

      refute_receive {:deliver_message, _message2}, 200
    end

    test "N17 a number too large to convert is refused before the conversion", %{fx: fx} do
      # The bound comes before the conversion: the number is bounded by its
      # magnitude, not by the length of the text it becomes (SF-01).
      assert {:error, :notify_value_invalid} =
               run(fx, declaration(), variables(%{"tenant_name" => 10 ** 40}))

      refute_receive {:deliver_message, _message}, 200
      assert [] = rows(fx)
    end
  end
end
