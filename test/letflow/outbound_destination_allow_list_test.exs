defmodule Letflow.OutboundDestinationAllowListTest do
  @moduledoc """
  T-2597 (pilot gap G14; decision record G2, S6 -- "Exfiltration through a
  notification step"): the per-tenant OUTBOUND ALLOW-LIST is enforced at
  ACTIVATION and at DISPATCH.

  A definition that reaches outside the tenant is refused unless the tenant's
  own list allows its channel and its destination. The list is empty by
  default, so nothing reaches outside until a holder of
  `:OutboundDestinationsManage` opens the door.

  Test ids S6-a..S6-e.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.NotificationSteps.Dispatcher
  alias Letflow.OutboundDestinations
  alias Letflow.Support.PlatformCallFixture, as: Fx
  alias Letflow.Support.PlatformTenantFixture, as: PlatformFx

  setup do
    tenant = Fx.tenant!("t2597-allow-list")
    PlatformFx.pin!(tenant.tenant_id)

    admin = Fx.user!(tenant.schema_name, "allow-list-admin")
    Fx.platform_admin!(tenant.schema_name, admin)

    %{tenant: tenant, admin: admin, prefix: tenant.schema_name}
  end

  # The notification step's declaration: a registered template, the address read
  # from a variable and the declared values.
  defp declaration do
    %{
      "template_key" => "tenant_registered",
      "recipient" => %{"var" => "admin_email"},
      "values" => %{
        "tenant_name" => %{"var" => "tenant_name"},
        "tenant_slug" => %{"const" => "acme"}
      }
    }
  end

  defp schemas do
    [
      %{variable_key: "admin_email", json_schema: %{"type" => "string"}},
      %{variable_key: "tenant_name", json_schema: %{"type" => "string"}}
    ]
  end

  # START -> the step -> END.
  defp graph(attributes) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "step", "node_type" => "SERVICE_TASK", "attributes" => attributes},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "step"},
        %{"id" => "e2", "source" => "step", "target" => "end"}
      ]
    }
  end

  defp notify_graph, do: graph(%{"notify" => declaration()})

  defp http_graph do
    graph(%{
      "endpoint" => "https://api.example.com/hook",
      "method" => "POST",
      "timeout_ms" => 30_000
    })
  end

  defp activate(ctx, definition) do
    activator =
      Activator.from_auth_context(%{user_id: ctx.admin.id, roles: ["PLATFORM_ADMIN"]}, true)

    Definitions.activate(definition.id, prefix: ctx.prefix, activator: activator)
  end

  defp allow(ctx, channel, destination) do
    {:ok, _entry} =
      OutboundDestinations.add(
        ctx.prefix,
        ctx.admin.id,
        channel,
        destination
      )

    :ok
  end

  defp variables do
    %{
      "admin_email" => "admin@example.com",
      "tenant_name" => "Acme"
    }
  end

  describe "S6 activation refuses what the tenant's list does not allow" do
    test "S6-a a notification step is refused while the mail channel is not on the list", ctx do
      draft = Fx.definition_with_schemas!(ctx.prefix, notify_graph(), "t2597-notify", schemas())

      assert {:error, {:outbound_destinations_invalid, violations}} = activate(ctx, draft)
      assert :outbound_channel_not_allowed in Enum.map(violations, & &1.code)
    end

    test "S6-b the same definition is activated once the channel is on the list", ctx do
      allow(ctx, "email", nil)

      draft = Fx.definition_with_schemas!(ctx.prefix, notify_graph(), "t2597-notify", schemas())

      assert {:ok, _definition} = activate(ctx, draft)
    end

    test "S6-i a FILE-channel step is refused while the file channel is not on the list", ctx do
      file_graph =
        graph(%{
          "notify" => %{
            "channel" => "file",
            "template_key" => "tenant_registered",
            "file_name" => "registration-notice",
            "values" => %{"tenant_slug" => %{"const" => "acme"}}
          }
        })

      draft = Fx.definition_with_schemas!(ctx.prefix, file_graph, "t2597-file", [])

      assert {:error, {:outbound_destinations_invalid, violations}} = activate(ctx, draft)
      assert :outbound_channel_not_allowed in Enum.map(violations, & &1.code)

      allow(ctx, "file", nil)
      assert {:ok, _definition} = activate(ctx, draft)
    end

    test "S6-c an inline HTTP step is refused while its host is not on the list", ctx do
      allow(ctx, "http", nil)

      draft = Fx.definition_with_schemas!(ctx.prefix, http_graph(), "t2597-http", [])

      assert {:error, {:outbound_destinations_invalid, violations}} = activate(ctx, draft)
      assert :outbound_destination_not_allowed in Enum.map(violations, & &1.code)
    end

    test "S6-d the same definition is activated once the host is on the list", ctx do
      allow(ctx, "http", nil)
      allow(ctx, "http", "api.example.com")

      draft = Fx.definition_with_schemas!(ctx.prefix, http_graph(), "t2597-http", [])

      assert {:ok, _definition} = activate(ctx, draft)
    end

    test "S6-g an inline HTTP step with a DYNAMIC host is refused even when the channel is on the list",
         ctx do
      # The list names HOSTS. A host that is a placeholder is not one of them,
      # and it cannot be checked at all -- so the step is refused: a target
      # nobody can check is a target nobody may reach (deny by default).
      allow(ctx, "http", nil)

      draft =
        Fx.definition_with_schemas!(
          ctx.prefix,
          graph(%{
            "endpoint" => "https://{{variables.host}}/hook",
            "method" => "POST",
            "timeout_ms" => 30_000
          }),
          "t2597-http-dynamic",
          []
        )

      assert {:error, {:outbound_destinations_invalid, violations}} = activate(ctx, draft)
      assert :outbound_destination_not_allowed in Enum.map(violations, & &1.code)
    end

    test "S6-h a templated PATH with a literal host is activated when the host is on the list",
         ctx do
      # The path is a template, the HOST is not: the request still reaches the
      # one host the list names, so the step is allowed.
      allow(ctx, "http", nil)
      allow(ctx, "http", "api.example.com")

      draft =
        Fx.definition_with_schemas!(
          ctx.prefix,
          graph(%{
            "endpoint" => "https://api.example.com/{{variables.path}}",
            "method" => "POST",
            "timeout_ms" => 30_000
          }),
          "t2597-http-path",
          []
        )

      assert {:ok, _definition} = activate(ctx, draft)
    end
  end

  describe "S6 dispatch refuses what the tenant's list does not allow" do
    test "S6-e a recipient domain that is not on the list is refused and nothing is sent", ctx do
      allow(ctx, "email", nil)

      assert {:error, :notify_destination_not_allowed} =
               Dispatcher.run(
                 declaration(),
                 variables(),
                 prefix: ctx.prefix,
                 trigger_ref: Ecto.UUID.generate(),
                 labels: %{}
               )
    end

    test "S6-f a recipient domain that IS on the list is let through to the send", ctx do
      allow(ctx, "email", nil)
      allow(ctx, "email", "example.com")

      # The send itself is the G4 dispatcher's business; here the step is NOT
      # refused by the allow-list, so the refusal that comes back is the
      # adapter's (no notifier is configured in this test).
      result =
        Dispatcher.run(
          declaration(),
          variables(),
          prefix: ctx.prefix,
          trigger_ref: Ecto.UUID.generate(),
          labels: %{}
        )

      refute result == {:error, :notify_destination_not_allowed}
    end
  end

  describe "S6 grandfathered tenants (G2 (c)): the QA fixtures still activate" do
    test "S6-j the six QA fixture definitions activate through Definitions.activate/2", ctx do
      dir = Path.expand("../fixtures/qa", __DIR__)
      files = Path.wildcard(Path.join(dir, "*_process_definition.json"))
      assert length(files) == 6

      decoded = Enum.map(files, &(&1 |> File.read!() |> Jason.decode!()))

      # The tenant already runs the six (active); the backfill lists their hosts.
      for d <- decoded, do: insert_definition!(ctx, d, "1", :active)
      assert {:ok, count} = OutboundDestinations.grandfather(ctx.prefix)
      assert count > 0

      # The seeding then activates a NEW version of each: the fence lets it through.
      for d <- decoded do
        draft = insert_definition!(ctx, d, "2", :draft)
        assert {:ok, _} = activate(ctx, draft), Map.fetch!(d, "name")
      end
    end
  end

  defp insert_definition!(ctx, decoded, version, status) do
    %Letflow.Definitions.ProcessDefinition{}
    |> Ecto.Changeset.change(%{
      name: Map.fetch!(decoded, "name"),
      version: version,
      status: status,
      graph: Map.fetch!(decoded, "graph"),
      created_by: ctx.admin.id
    })
    |> Letflow.Repo.insert!(prefix: ctx.prefix)
    |> tap(fn row ->
      entries =
        for %{"variable_key" => key, "json_schema" => schema} <-
              Map.get(decoded, "variable_schemas", []) do
          %{variable_key: key, json_schema: schema}
        end

      if status == :draft and entries != [] do
        {:ok, _} = Definitions.register_variable_schemas(row.id, entries, prefix: ctx.prefix)
      end
    end)
  end
end
