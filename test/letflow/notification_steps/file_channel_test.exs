defmodule Letflow.NotificationSteps.FileChannelTest do
  @moduledoc """
  T-2596 (pilot gap G12): the "file" CHANNEL of the notification step -- the
  step renders the registered template and writes it into the tenant's own
  file area instead of sending it to an address.

  The tests below are the acceptance of the channel:

    * FC1 -- the step writes the rendered template into the tenant's area and
      answers the step result the way the mail channel does;
    * FC2 -- the name of the file is the SERVER's: the declared name is the
      stem of it and never the name itself;
    * FC3 -- the cap of the tenant holds the file channel too: over the cap
      NOTHING is written and the step says `rate_limited`;
    * FC4 -- the refusals of the mail channel hold here as well: a labelled
      variable, a missing trigger reference, a prefix that names no tenant;
    * FC5 -- the file channel sends no mail (the address channel is the only
      one that leaves the platform);
    * FC6 -- the file of one tenant is not in another tenant's schema
      (INV-1).

  `async: false`: committed tenant writes.
  """

  use Letflow.DataCase, async: false

  alias Letflow.LoginDiscoveryNotifierDouble, as: Double
  alias Letflow.NotificationSteps.Dispatcher
  alias Letflow.Notifications.File
  alias Letflow.Notifications.Files
  alias Letflow.Repo
  alias Letflow.Support.PlatformCallFixture, as: PCF
  alias Letflow.Test.SandboxAutoMode
  alias Letflow.Test.SmtpHelpers, as: S

  @notifier Letflow.LoginDiscovery.Notifier

  setup do
    # registered first, so it runs LAST (after the tenant fixture's own cleanup)
    on_exit(fn -> SandboxAutoMode.exit_auto_mode!(Repo) end)
    fx = PCF.tenant!("t2596-file")
    S.put_app_env!(@notifier, adapter: Double, timeout_ms: 100, max_concurrent: 5)
    Double.set_owner(self())
    on_exit(&Double.reset/0)

    {:ok, fx: fx}
  end

  # The file channel's declaration: the registered template, the NAME of the
  # file (a constant, never a variable) and the declared values. There is no
  # recipient: a file has no address.
  defp declaration(overrides \\ %{}) do
    Map.merge(
      %{
        "channel" => "file",
        "template_key" => "tenant_registered",
        "file_name" => "registration-notice",
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
      prefix: Keyword.get(opts, :prefix, fx.schema_name),
      trigger_ref: Keyword.get(opts, :trigger_ref, Ecto.UUID.generate()),
      labels: Keyword.get(opts, :labels, %{})
    )
  end

  defp rows(fx), do: Repo.all(File, prefix: fx.schema_name)

  defp set_settings!(fx, settings) do
    {:ok, _} =
      Repo.query("UPDATE tenants SET settings = $1::jsonb WHERE id = $2", [
        settings,
        Ecto.UUID.dump!(fx.tenant_id)
      ])

    :ok
  end

  describe "the file channel (the acceptance of gap G12)" do
    test "FC1 the step writes the rendered template into the tenant's area", %{fx: fx} do
      assert {:ok, "sent", nil} = run(fx, declaration(), variables())

      assert [row] = rows(fx)
      assert row.template_key == "tenant_registered"
      assert row.tenant_id == fx.tenant_id
      assert row.byte_size > 0
      assert row.content_type == Files.content_type()
      assert row.expires_at != nil
      assert row.bytes =~ "Tenant acme is registered"
      assert row.bytes =~ "the tenant Acme (acme) is registered"
    end

    test "FC2 the name of the file is the server's, never the declared one", %{fx: fx} do
      assert {:ok, "sent", nil} = run(fx, declaration(), variables())

      assert [row] = rows(fx)
      assert row.name =~ ~r/\Aregistration-notice-[0-9a-f]{12}\.txt\z/
      refute row.name == "registration-notice"
      refute row.name =~ "/"
      refute row.name =~ ".."
    end

    test "FC3 the cap of the tenant holds the file channel too", %{fx: fx} do
      set_settings!(fx, %{"notifications.outbound_cap_per_hour" => 1})

      assert {:ok, "sent", nil} = run(fx, declaration(), variables())
      assert [_row] = rows(fx)

      # The second file of the hour is over the cap: nothing is written.
      assert {:ok, "skipped", "rate_limited"} = run(fx, declaration(), variables())
      assert [_row] = rows(fx)
    end

    test "FC4a a labelled variable is refused and nothing is written", %{fx: fx} do
      labels = %{"tenant_name" => ["secret"]}

      assert {:error, :notify_restricted_variable} =
               run(fx, declaration(), variables(), labels: labels)

      assert [] == rows(fx)
    end

    test "FC4b a missing trigger reference is refused and nothing is written", %{fx: fx} do
      assert {:error, :notify_trigger_ref_missing} =
               run(fx, declaration(), variables(), trigger_ref: nil)

      assert [] == rows(fx)
    end

    test "FC4c a prefix that names no tenant is refused and nothing is written", %{fx: fx} do
      assert {:error, :notify_invalid_schema} =
               run(fx, declaration(), variables(), prefix: "tenant_not_a_tenant")

      assert [] == rows(fx)
    end

    test "FC5 the file channel sends no mail", %{fx: fx} do
      assert {:ok, "sent", nil} = run(fx, declaration(), variables())

      refute_receive {:deliver_message, _message}, 200
    end

    test "FC6 the file of one tenant is not in another tenant's schema", %{fx: fx} do
      other = PCF.tenant!("t2596-file-other")

      assert {:ok, "sent", nil} = run(fx, declaration(), variables())

      assert [_row] = rows(fx)
      assert [] == Repo.all(File, prefix: other.schema_name)
    end
  end
end
