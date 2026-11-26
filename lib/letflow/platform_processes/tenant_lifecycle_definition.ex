defmodule Letflow.PlatformProcesses.TenantLifecycleDefinition do
  @moduledoc """
  The DOCUMENT of `platform.tenant_lifecycle` version "1" (T-2972, BP-PLATFORM-02 G2): suspend,
  reactivate or purge ONE tenant as a platform process. Seeded like `DefinitionV2`
  (`Letflow.PlatformProcesses.Seed`, `definition:` option).

  ## The graph

      start -> action_gate
      action_gate --[variables.action == "suspend"]-->    suspend    -> end
      action_gate --[variables.action == "reactivate"]--> reactivate -> end
      action_gate --[variables.action == "purge"]-->      purge      -> end
      action_gate --(default)--> end

  ONE process per start: the caller picks the action. `action` is a closed enum, so a start with
  any other value is refused by the typed start variables; the default edge is never taken for a
  valid start and never reaches a destructive node. The purge node is the only destructive one
  and its guard (confirmation equal to the slug, suspended tenant, not a production tenant) lives
  in `Letflow.PlatformFunctions.Impl.TenantPurge`, not in this graph.

  ## The start variables

  `slug` (the tenant), `request_id` (fresh per start: part of the call key, so suspend, reactivate and
  suspend again of one tenant are three calls), `action` (`suspend` | `reactivate` | `purge`), `confirm` (purge only: must
  equal the slug). The start permission is `TenantsManage`, the catalogue's own. The graph has no
  HUMAN_TASK, no SUB_PROCESS and no script (decision 0094 (b)). Step log, retry and the dead-letter
  queue are the engine's own for every `platform_call` node.
  """

  alias Letflow.PlatformFunctions.TenantFamily

  @name "platform.tenant_lifecycle"
  @version "1"
  @start_permission "TenantsManage"
  @description "Suspend, reactivate or purge a tenant (purge: only a suspended, non-production tenant, with a typed confirmation)."

  @spec name() :: String.t()
  def name, do: @name

  @spec version() :: String.t()
  def version, do: @version

  @spec description() :: String.t()
  def description, do: @description

  @spec start_permission() :: String.t()
  def start_permission, do: @start_permission

  @doc "The graph. Pure."
  @spec graph() :: map()
  def graph do
    slug = %{"slug" => %{"var" => "slug"}, "request_id" => %{"var" => "request_id"}}

    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "action_gate", "node_type" => "EXCLUSIVE_GATEWAY"},
        call_node("suspend", "tenant.suspend", slug),
        call_node("reactivate", "tenant.reactivate", slug),
        call_node("purge", "tenant.purge", Map.put(slug, "confirm", %{"var" => "confirm"})),
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        edge("e1", "start", "action_gate"),
        Map.put(
          edge("e2", "action_gate", "suspend"),
          "condition",
          ~s(variables.action == "suspend")
        ),
        Map.put(
          edge("e3", "action_gate", "reactivate"),
          "condition",
          ~s(variables.action == "reactivate")
        ),
        Map.put(
          edge("e4", "action_gate", "purge"),
          "condition",
          ~s(variables.action == "purge")
        ),
        Map.put(edge("e5", "action_gate", "end"), "is_default", true),
        edge("e6", "suspend", "end"),
        edge("e7", "reactivate", "end"),
        edge("e8", "purge", "end")
      ]
    }
  end

  @doc "The typed start variables."
  @spec variable_schemas() :: [%{variable_key: String.t(), json_schema: map()}]
  def variable_schemas do
    [
      %{variable_key: "slug", json_schema: %{"type" => "string"}},
      %{variable_key: "confirm", json_schema: %{"type" => "string"}},
      %{variable_key: "request_id", json_schema: %{"type" => "string"}},
      %{
        variable_key: "action",
        json_schema: %{"type" => "string", "enum" => ["suspend", "reactivate", "purge"]}
      }
    ]
  end

  @doc "The attributes of a definition of this document (no `created_by`)."
  @spec attrs() :: map()
  def attrs do
    %{
      name: @name,
      version: @version,
      description: @description,
      graph: graph(),
      start_permission: @start_permission
    }
  end

  defp edge(id, source, target), do: %{"id" => id, "source" => source, "target" => target}

  defp call_node(id, function, args) do
    entry = Enum.find(TenantFamily.entries(), &(&1.name == function))

    reads =
      entry.inputs
      |> Enum.filter(fn input -> match?(%{"var" => _}, Map.get(args, input.name)) end)
      |> Map.new(fn input -> {input.name, "string"} end)

    %{
      "id" => id,
      "node_type" => "SERVICE_TASK",
      "attributes" => %{
        "platform_call" => %{
          "function" => function,
          "args" => args,
          "reads" => reads,
          "writes" => %{}
        }
      }
    }
  end
end
