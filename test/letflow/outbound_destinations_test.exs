defmodule Letflow.OutboundDestinationsTest do
  @moduledoc """
  T-2597 (pilot gap G14): the per-tenant OUTBOUND ALLOW-LIST -- the channels a
  tenant may use to reach outside itself and the destinations it may reach.

  The list is DENY BY DEFAULT: a fresh tenant may reach nothing outside, and
  only a holder of `:OutboundDestinationsManage` may open the door. Every
  change is an audit row with the actor.

  Test ids O1..O8.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Api.Authorization
  alias Letflow.Audit.Entry
  alias Letflow.OutboundDestinations
  alias Letflow.Repo
  alias Letflow.Support.PlatformCallFixture, as: Fx

  setup do
    tenant = Fx.tenant!("t2597-list")
    %{tenant: tenant, prefix: tenant.schema_name}
  end

  defp add(ctx, channel, destination, actor \\ nil) do
    OutboundDestinations.add(ctx.prefix, actor, channel, destination)
  end

  describe "the list is empty by default (deny by default)" do
    test "O1 a fresh tenant may reach nothing outside", ctx do
      assert {:error, :channel_not_allowed} =
               OutboundDestinations.check(ctx.prefix, "email", nil)

      assert {:error, :channel_not_allowed} =
               OutboundDestinations.check(ctx.prefix, "email", "example.com")

      assert {:ok, []} = OutboundDestinations.list(ctx.prefix)
    end

    test "O2 the check fails CLOSED when the list cannot be read", _ctx do
      # A prefix that names no tenant has no list: the caller's mistake, and
      # the answer says so (nothing is allowed either way).
      assert {:error, :invalid_schema_name} =
               OutboundDestinations.check("not_a_tenant_schema", "email", nil)
    end
  end

  describe "the entries" do
    test "O3 the channel alone opens the door; the destination is still refused", ctx do
      assert {:ok, entry} = add(ctx, "email", nil)
      assert entry.channel == "email"
      assert entry.destination == nil

      assert :ok = OutboundDestinations.check(ctx.prefix, "email", nil)

      assert {:error, :destination_not_allowed} =
               OutboundDestinations.check(ctx.prefix, "email", "example.com")
    end

    test "O4 the destination needs the channel too", ctx do
      assert {:ok, _entry} = add(ctx, "email", "example.com")

      # The destination row alone does not open the door.
      assert {:error, :channel_not_allowed} =
               OutboundDestinations.check(ctx.prefix, "email", "example.com")

      assert {:ok, _channel} = add(ctx, "email", nil)
      assert :ok = OutboundDestinations.check(ctx.prefix, "email", "example.com")
    end

    test "O5 the domain is matched EXACTLY, in lower case", ctx do
      assert {:ok, _channel} = add(ctx, "email", nil)
      assert {:ok, _destination} = add(ctx, "email", "uat.letflow.internal")

      assert :ok = OutboundDestinations.check(ctx.prefix, "email", "uat.letflow.internal")
      assert :ok = OutboundDestinations.check(ctx.prefix, "email", "UAT.LETflow.internal")

      assert {:error, :destination_not_allowed} =
               OutboundDestinations.check(ctx.prefix, "email", "mail.uat.letflow.internal")

      assert {:error, :destination_not_allowed} =
               OutboundDestinations.check(ctx.prefix, "email", "uat.letflow.internal.evil.com")
    end

    test "O6 the file channel has no destination of its own", ctx do
      assert {:error, :invalid_destination} = add(ctx, "file", "example.com")

      assert {:ok, _channel} = add(ctx, "file", nil)
      assert :ok = OutboundDestinations.check(ctx.prefix, "file", nil)
    end

    test "O7 an address of a person and a URL are refused as destinations", ctx do
      assert {:error, :invalid_destination} = add(ctx, "email", "person@example.com")
      assert {:error, :invalid_destination} = add(ctx, "http", "https://example.com/path")
      assert {:error, :invalid_destination} = add(ctx, "email", "not a domain")
      assert {:error, :invalid_destination} = add(ctx, "email", "-bad-.example")
      assert {:error, :invalid_channel} = add(ctx, "telegram", nil)
    end

    test "O7b adding the same entry twice is the same entry, not a second row", ctx do
      assert {:ok, first} = add(ctx, "email", "example.com")
      assert {:ok, second} = add(ctx, "email", "example.com")

      assert first.id == second.id
      assert {:ok, entries} = OutboundDestinations.list(ctx.prefix)
      assert length(entries) == 1
    end

    test "O7c a duplicate add in ANOTHER case is the same entry, not an error", ctx do
      assert {:ok, channel} = add(ctx, "email", nil)
      assert {:ok, same_channel} = add(ctx, "EMAIL", nil)
      assert channel.id == same_channel.id

      assert {:ok, domain} = add(ctx, "email", "example.com")
      assert {:ok, same_domain} = add(ctx, "email", "Example.COM")
      assert domain.id == same_domain.id

      assert {:ok, entries} = OutboundDestinations.list(ctx.prefix)
      assert length(entries) == 2
    end

    test "O7d a destination with a trailing newline is not a name", ctx do
      assert {:error, :invalid_destination} = add(ctx, "email", "example.com\n")
      assert {:ok, []} = OutboundDestinations.list(ctx.prefix)
    end

    test "O8 removing an entry closes the door again, and removes the channel's destinations",
         ctx do
      assert {:ok, _channel} = add(ctx, "email", nil)
      assert {:ok, _destination} = add(ctx, "email", "example.com")
      assert :ok = OutboundDestinations.check(ctx.prefix, "email", "example.com")

      assert {:ok, :removed} =
               OutboundDestinations.remove(ctx.prefix, nil, "email", nil)

      assert {:error, :channel_not_allowed} =
               OutboundDestinations.check(ctx.prefix, "email", "example.com")

      assert {:ok, :absent} =
               OutboundDestinations.remove(ctx.prefix, nil, "email", nil)
    end
  end

  describe "a tenant without the table (not yet migrated, INV-8)" do
    test "O17 list, add and remove answer a typed error and do not raise", ctx do
      Repo.query!(~s(DROP TABLE "#{ctx.prefix}".outbound_destinations CASCADE))

      assert {:error, :allow_list_unavailable} = OutboundDestinations.list(ctx.prefix)
      assert {:error, :allow_list_unavailable} = add(ctx, "email", nil)
      assert {:error, :allow_list_unavailable} = add(ctx, "email", "example.com")

      assert {:error, :allow_list_unavailable} =
               OutboundDestinations.remove(ctx.prefix, nil, "email", nil)
    end
  end

  describe "the authority" do
    test "O9 only TENANT_ADMIN and PLATFORM_ADMIN hold the atom; a PROCESS_DESIGNER does not" do
      assert Authorization.role_allows?(:TENANT_ADMIN, :OutboundDestinationsManage)
      assert Authorization.role_allows?(:PLATFORM_ADMIN, :OutboundDestinationsManage)

      refute Authorization.role_allows?(:PROCESS_DESIGNER, :OutboundDestinationsManage)
      refute Authorization.role_allows?(:PROCESS_OPERATOR, :OutboundDestinationsManage)
      refute Authorization.role_allows?(:TASK_WORKER, :OutboundDestinationsManage)
      refute Authorization.role_allows?(:TENANT_AUDITOR, :OutboundDestinationsManage)
      refute Authorization.role_allows?(:STOREKEEPER, :OutboundDestinationsManage)

      assert Authorization.permission_scope(:OutboundDestinationsManage) == :tenant

      assert Authorization.required_permission(:OutboundDestinationsManage) ==
               :OutboundDestinationsManage
    end
  end

  describe "the audit" do
    test "O10 every change is an audit row with the actor", ctx do
      actor = Ecto.UUID.generate()

      assert {:ok, _entry} = add(ctx, "email", nil, actor)
      assert {:ok, _entry} = add(ctx, "email", "example.com", actor)

      rows = Repo.all(Entry, prefix: ctx.prefix)
      actions = Enum.map(rows, & &1.action)

      assert "outbound_destinations.add" in actions

      added = Enum.find(rows, &(&1.action == "outbound_destinations.add"))
      assert added.actor_id == actor
      assert added.resource_type == "outbound_destination"

      assert {:ok, :removed} =
               OutboundDestinations.remove(ctx.prefix, actor, "email", nil)

      removed =
        Repo.all(Entry, prefix: ctx.prefix)
        |> Enum.find(&(&1.action == "outbound_destinations.remove"))

      assert removed.actor_id == actor
    end
  end

  # The channels of a definition -- what the platform's own SEED opens before
  # it switches its standard version on (a version that cannot send anything is
  # never switched on).
  describe "the channels a definition uses" do
    test "O11 the channels of a graph are the channels of its nodes", _ctx do
      assert OutboundDestinations.channels_of(notify_and_http_graph()) == ["email", "http"]

      # the same channel twice is one channel
      assert OutboundDestinations.channels_of(notify_graph()) == ["email"]

      # a graph that cannot be read reaches nothing
      assert OutboundDestinations.channels_of(%{"nodes" => "not a list"}) == []
      assert OutboundDestinations.channels_of(%{}) == []
    end

    test "O12 opening the channels opens the DOOR and nothing else", ctx do
      actor = Ecto.UUID.generate()

      assert {:ok, ["email", "http"]} =
               OutboundDestinations.open_channels(ctx.prefix, actor, notify_and_http_graph())

      {:ok, entries} = OutboundDestinations.list(ctx.prefix)

      assert Enum.map(entries, & &1.channel) == ["email", "http"]
      assert Enum.all?(entries, &is_nil(&1.destination))

      # the door is open; the address behind it is not
      assert :ok = OutboundDestinations.check(ctx.prefix, "email", nil)
      assert :ok = OutboundDestinations.check(ctx.prefix, "http", nil)

      assert {:error, :destination_not_allowed} =
               OutboundDestinations.check(ctx.prefix, "email", "example.com")

      # the change is an audit row with the actor
      added =
        Repo.all(Entry, prefix: ctx.prefix)
        |> Enum.find(&(&1.action == "outbound_destinations.add"))

      assert added.actor_id == actor
    end

    test "O13 opening the channels twice is the same list; a prefix that names no tenant is refused",
         ctx do
      assert {:ok, ["email"]} =
               OutboundDestinations.open_channels(ctx.prefix, nil, notify_graph())

      assert {:ok, ["email"]} =
               OutboundDestinations.open_channels(ctx.prefix, nil, notify_graph())

      assert {:ok, entries} = OutboundDestinations.list(ctx.prefix)
      assert length(entries) == 1

      assert {:error, :invalid_schema_name} =
               OutboundDestinations.open_channels("not_a_tenant_schema", nil, notify_graph())
    end
  end

  # The notification step's declaration: a registered template, the address read
  # from a variable and the declared values.
  describe "grandfathering of already-active definitions (G2 (c))" do
    defp active_definition!(ctx, name, graph) do
      %Letflow.Definitions.ProcessDefinition{}
      |> Ecto.Changeset.change(%{
        name: name,
        version: "1",
        status: :active,
        graph: graph,
        created_by: Ecto.UUID.generate()
      })
      |> Repo.insert!(prefix: ctx.prefix)
    end

    test "O12 the channels and literal hosts of active definitions are listed, with the reason",
         ctx do
      definition = active_definition!(ctx, "gf-one", notify_and_http_graph())

      assert {:ok, 3} = OutboundDestinations.grandfather(ctx.prefix)
      assert {:ok, entries} = OutboundDestinations.list(ctx.prefix)

      assert Enum.sort(Enum.map(entries, &{&1.channel, &1.destination})) ==
               [{"email", nil}, {"http", nil}, {"http", "api.example.com"}]

      assert Enum.all?(entries, &(&1.definition_id == definition.id))
      assert Enum.all?(entries, &(&1.reason == "grandfathered by G14"))

      # the widening is one system audit row (no person: actor nil)
      audit =
        Repo.all(Entry, prefix: ctx.prefix)
        |> Enum.filter(&(&1.action == "outbound_destinations.grandfathered"))

      assert [%{actor_id: nil, after_state: %{"rows" => 3}}] = audit

      assert :ok = OutboundDestinations.check(ctx.prefix, "http", "api.example.com")
      # only what the definitions used: any other host stays refused
      assert {:error, :destination_not_allowed} =
               OutboundDestinations.check(ctx.prefix, "http", "other.example.com")

      # idempotent
      assert {:ok, 0} = OutboundDestinations.grandfather(ctx.prefix)
    end

    test "O13 a draft definition and a dynamic host are NOT grandfathered", ctx do
      %Letflow.Definitions.ProcessDefinition{}
      |> Ecto.Changeset.change(%{
        name: "gf-draft",
        version: "1",
        status: :draft,
        graph: notify_and_http_graph(),
        created_by: Ecto.UUID.generate()
      })
      |> Repo.insert!(prefix: ctx.prefix)

      dynamic = %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{
            "id" => "call",
            "node_type" => "SERVICE_TASK",
            "attributes" => %{"endpoint" => "https://{{variables.host}}/x"}
          },
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [
          %{"id" => "e1", "source" => "start", "target" => "call"},
          %{"id" => "e2", "source" => "call", "target" => "end"}
        ]
      }

      active_definition!(ctx, "gf-dynamic", dynamic)

      assert {:ok, 1} = OutboundDestinations.grandfather(ctx.prefix)
      assert {:ok, [%{channel: "http", destination: nil}]} = OutboundDestinations.list(ctx.prefix)
    end

    test "O14 a fresh tenant with no active definition gets an empty list", ctx do
      assert {:ok, 0} = OutboundDestinations.grandfather(ctx.prefix)
      assert {:ok, []} = OutboundDestinations.list(ctx.prefix)
    end

    test "O15 the six QA fixture definitions keep activating once grandfathered", ctx do
      dir = Path.expand("../fixtures/qa", __DIR__)
      files = Path.wildcard(Path.join(dir, "*_process_definition.json"))
      assert length(files) == 6

      for file <- files do
        decoded = file |> File.read!() |> Jason.decode!()
        active_definition!(ctx, Map.fetch!(decoded, "name"), Map.fetch!(decoded, "graph"))
      end

      assert {:ok, count} = OutboundDestinations.grandfather(ctx.prefix)
      assert count > 0

      # The activation fence itself, not only the list: every one of the six
      # passes the same fence `Definitions.activate/2` and `reactivate/2` run.
      rows = Repo.all(Letflow.Definitions.ProcessDefinition, prefix: ctx.prefix)
      assert length(rows) == 6

      for row <- rows do
        assert :ok = Letflow.Definitions.check_outbound_destinations(row, ctx.prefix),
               row.name
      end

      for file <- files do
        {:ok, graph} =
          file
          |> File.read!()
          |> Jason.decode!()
          |> Map.fetch!("graph")
          |> Letflow.Definitions.Graph.from_map()

        for node <- graph.nodes, target = OutboundDestinations.node_target(node), target != nil do
          {channel, destination} = target

          if is_binary(destination) do
            assert :ok = OutboundDestinations.check(ctx.prefix, channel, destination),
                   "#{Path.basename(file)}: #{channel} #{destination}"
          end
        end
      end
    end

    test "O17 a listed host covers every port of it; the list never holds host:port", ctx do
      assert OutboundDestinations.http_host("https://api.example.com:8443/x") ==
               "api.example.com"

      assert {:ok, _} = OutboundDestinations.add(ctx.prefix, nil, "http", nil)
      assert {:ok, _} = OutboundDestinations.add(ctx.prefix, nil, "http", "api.example.com")

      assert :ok =
               OutboundDestinations.check(
                 ctx.prefix,
                 "http",
                 OutboundDestinations.http_host("https://api.example.com:8443/x")
               )

      assert {:error, _} =
               OutboundDestinations.add(ctx.prefix, nil, "http", "api.example.com:8443")
    end

    test "O16 a channel an administrator closed after the backfill stays closed", ctx do
      active_definition!(ctx, "gf-closed", notify_graph())
      assert {:ok, 1} = OutboundDestinations.grandfather(ctx.prefix)
      assert {:ok, :removed} = OutboundDestinations.remove(ctx.prefix, nil, "email", nil)

      assert {:error, :channel_not_allowed} =
               OutboundDestinations.check(ctx.prefix, "email", nil)
    end
  end

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

  # START -> the notification step -> END.
  defp notify_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "notify",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"notify" => declaration()}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "notify"},
        %{"id" => "e2", "source" => "notify", "target" => "end"}
      ]
    }
  end

  # The same, plus an inline HTTP step: two channels in one graph.
  defp notify_and_http_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "notify",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"notify" => declaration()}
        },
        %{
          "id" => "call",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"endpoint" => "https://api.example.com/hook"}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "notify"},
        %{"id" => "e2", "source" => "notify", "target" => "call"},
        %{"id" => "e3", "source" => "call", "target" => "end"}
      ]
    }
  end
end
