defmodule Letflow.PlatformProcesses.DefinitionV3 do
  @moduledoc """
  The DOCUMENT of version "3" of `platform.register_tenant` (T-3154, owner item 11 / D-195, slice G2;
  `docs/platform-register-tenant-v2.md` section 11). It is v2's graph with ONE change: the realm is
  OPTIONAL. After `record_onboarding` a gateway looks at the start variable `provision_realm`:

      record_onboarding -> realm_gate
      realm_gate --[variables.provision_realm == true]--> provision_realm -> bind_realm
      realm_gate --(default)--> bind_realm

  `provision_realm` is `true` when no realm was supplied and the process must make it: the
  `tenant.provision_realm_and_invite` step (the provisioner makes the realm and the first administrator,
  ONE mail carries the temporary password) writes the output `realm_id`, which `bind_realm` then binds.
  With a realm supplied (or none and nobody to invite) the default edge goes to `bind_realm` as in v2.

  Two new start variables: `provision_realm` (boolean) and `language` (`ru`/`kk`/`en`, the language of the
  invitation; absent means `en`). The rest of v2 (variables, steps, the notification gate) is unchanged:
  the document is built FROM `DefinitionV2`, so the two cannot drift.
  """

  alias Letflow.PlatformProcesses.DefinitionV2

  @version "3"
  @description "Register a tenant (v3): validate, create, provision, lifecycle, onboarding record, realm (supplied, or made by the provisioner with the first administrator), first administrator, default modules, notify."

  @spec name() :: String.t()
  def name, do: DefinitionV2.name()

  @spec version() :: String.t()
  def version, do: @version

  @spec description() :: String.t()
  def description, do: @description

  @spec start_permission() :: String.t()
  def start_permission, do: DefinitionV2.start_permission()

  @doc "The graph of v3. Pure."
  @spec graph() :: map()
  def graph do
    v2 = DefinitionV2.graph()

    provision =
      DefinitionV2.call_node("provision_realm", "tenant.provision_realm_and_invite", %{
        "tenant_id" => %{"var" => "tenant_id"},
        "admin_email" => %{"var" => "admin_email"},
        "name" => %{"var" => "name"},
        "slug" => %{"var" => "slug"},
        "language" => %{"var" => "language"},
        "hostname" => %{"var" => "hostname"}
      })

    nodes =
      Enum.flat_map(v2["nodes"], fn
        %{"id" => "bind_realm"} = bind ->
          [%{"id" => "realm_gate", "node_type" => "EXCLUSIVE_GATEWAY"}, provision, bind]

        node ->
          [node]
      end)

    edges =
      Enum.flat_map(v2["edges"], fn
        %{"id" => "e6"} ->
          [
            DefinitionV2.edge("e6", "record_onboarding", "realm_gate"),
            Map.put(
              DefinitionV2.edge("e13", "realm_gate", "provision_realm"),
              "condition",
              "variables.provision_realm == true"
            ),
            Map.put(DefinitionV2.edge("e14", "realm_gate", "bind_realm"), "is_default", true),
            DefinitionV2.edge("e15", "provision_realm", "bind_realm")
          ]

        edge ->
          [edge]
      end)

    %{"nodes" => nodes, "edges" => edges}
  end

  @doc "The typed context: v2's schemas plus `provision_realm` and `language`."
  @spec variable_schemas() :: [%{variable_key: String.t(), json_schema: map()}]
  def variable_schemas do
    DefinitionV2.variable_schemas() ++
      [
        %{variable_key: "provision_realm", json_schema: %{"type" => "boolean"}},
        %{variable_key: "language", json_schema: %{"type" => "string"}}
      ]
  end

  @doc "The attributes of a definition of this document (no `created_by`)."
  @spec attrs() :: map()
  def attrs do
    %{
      name: name(),
      version: @version,
      description: @description,
      graph: graph(),
      start_permission: start_permission()
    }
  end
end
