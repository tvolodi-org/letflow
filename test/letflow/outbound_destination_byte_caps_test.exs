defmodule Letflow.OutboundDestinationByteCapsTest do
  @moduledoc """
  T-2597 (SF-01, byte bound first): every byte cap the outbound allow-list adds
  is pinned by a case one byte over it -- the channel, the destination, the URL
  and the recipient address. An over-cap input is refused with the typed error
  and nothing is written.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions
  alias Letflow.NotificationSteps.Dispatcher
  alias Letflow.Notifications.Address
  alias Letflow.OutboundDestinations
  alias Letflow.Support.PlatformCallFixture, as: Fx

  setup do
    tenant = Fx.tenant!("t2597-caps")
    %{prefix: tenant.schema_name}
  end

  test "BC-1 a channel one byte over the cap is refused and nothing is written", ctx do
    over = String.duplicate("a", 17)

    assert {:error, :invalid_channel} = OutboundDestinations.add(ctx.prefix, nil, over, nil)
    assert {:error, :invalid_channel} = OutboundDestinations.remove(ctx.prefix, nil, over, nil)
    assert {:ok, []} = OutboundDestinations.list(ctx.prefix)
  end

  test "BC-1b a huge channel is refused the same way, a channel within the cap still works",
       ctx do
    assert {:error, :invalid_channel} =
             OutboundDestinations.add(ctx.prefix, nil, String.duplicate("E", 1_000_000), nil)

    assert {:ok, _entry} = OutboundDestinations.add(ctx.prefix, nil, "EMAIL", nil)
  end

  test "BC-2 a destination over 253 is refused and nothing is written", ctx do
    assert {:ok, _channel} = OutboundDestinations.add(ctx.prefix, nil, "email", nil)
    # four 63-byte labels (each within the label cap): only the 253 cap refuses
    label = String.duplicate("a", 63)
    over = Enum.join([label, label, label, label], ".")
    assert byte_size(over) == 255

    assert {:error, :invalid_destination} =
             OutboundDestinations.add(ctx.prefix, nil, "email", over)

    assert {:ok, [only]} = OutboundDestinations.list(ctx.prefix)
    assert only.destination == nil
  end

  test "BC-3 a URL one byte over 2048 is unreadable: no host, and the check refuses", ctx do
    assert {:ok, _channel} = OutboundDestinations.add(ctx.prefix, nil, "http", nil)
    assert {:ok, _entry} = OutboundDestinations.add(ctx.prefix, nil, "http", "api.example.com")

    prefix = "https://api.example.com/"
    within = prefix <> String.duplicate("a", 2048 - byte_size(prefix))
    over = within <> "a"
    assert byte_size(within) == 2048
    assert byte_size(over) == 2049

    assert OutboundDestinations.http_host(within) == "api.example.com"
    assert OutboundDestinations.http_host(over) == nil

    graph = fn url ->
      %{
        graph: %{
          "nodes" => [
            %{"id" => "start", "node_type" => "START"},
            %{
              "id" => "step",
              "node_type" => "SERVICE_TASK",
              "attributes" => %{"endpoint" => url, "method" => "POST", "timeout_ms" => 30_000}
            },
            %{"id" => "end", "node_type" => "END"}
          ],
          "edges" => [
            %{"id" => "e1", "source" => "start", "target" => "step"},
            %{"id" => "e2", "source" => "step", "target" => "end"}
          ]
        }
      }
    end

    assert :ok = Definitions.check_outbound_destinations(graph.(within), ctx.prefix)

    assert {:error,
            {:outbound_destinations_invalid, [%{code: :outbound_destination_not_allowed}]}} =
             Definitions.check_outbound_destinations(graph.(over), ctx.prefix)
  end

  test "BC-4 a channel over the cap in a declaration names no channel at dispatch", ctx do
    assert {:ok, _channel} = OutboundDestinations.add(ctx.prefix, nil, "email", nil)

    declaration = %{
      "template_key" => "tenant_registered",
      "channel" => String.duplicate("email", 100),
      "recipient" => %{"var" => "admin_email"},
      "values" => %{}
    }

    assert {:error, _reason} =
             Dispatcher.run(
               declaration,
               %{"admin_email" => "admin@example.com"},
               prefix: ctx.prefix,
               trigger_ref: Ecto.UUID.generate(),
               labels: %{}
             )
  end

  describe "Address.domain/1" do
    test "BC-5 the domain of a plain address, lower-cased" do
      assert {:ok, "example.com"} = Address.domain("Admin@Example.COM")
    end

    test "BC-6 an address one byte over the cap, a non-UTF-8 one and a non-binary are refused" do
      local = String.duplicate("a", 400)
      assert :error = Address.domain(local <> "@example.com")
      assert :error = Address.domain(<<0xFF, "@example.com">>)
      assert :error = Address.domain(nil)
      assert :error = Address.domain("no-at-sign")
      assert :error = Address.domain("a@")
    end
  end
end
