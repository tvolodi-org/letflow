defmodule Letflow.PlatformProcesses.DefinitionV2 do
  @moduledoc """
  The DOCUMENT of version "2" of `platform.register_tenant` (T-2727, pilot gap G17c;
  `docs/platform-register-tenant-v2.md` sections 1, 3 and 10). `Letflow.PlatformProcesses.Definition`
  still holds the v1 document; the seed writes this one.

  ## The graph

      start -> validate -> create -> provision -> record_lifecycle -> record_onboarding ->
      bind_realm -> grant_first_admins -> install_default_modules -> notify_gate
      notify_gate --[variables.notify_admin == true]--> notify -> end
      notify_gate --(default)--> end

  Every SERVICE_TASK but `notify` is a `platform_call` node whose reads and writes are DERIVED from the
  compiled catalogue, so the activation fence and the document cannot disagree. The graph has no
  HUMAN_TASK, no SUB_PROCESS and no script: the foreign-source rule of decision 0094 (b) holds and the
  system start's "no child" condition holds.

  ## The start variables

  `slug name requested_tenant_id tenant_type hostname realm_id admin_email notify_admin tenant_id
  schema_name`. `notify_admin` is a boolean, `tenant_type` carries the closed enum `test`/`production`,
  the rest are strings. The system start is admitted only for a version that declares
  `requested_tenant_id`, `tenant_type` and `notify_admin` (condition C1).
  """

  alias Letflow.PlatformFunctions.TenantFamily

  @name "platform.register_tenant"
  @version "2"
  @start_permission "TenantsManage"
  @description "Register a tenant (v2): validate, create, provision, lifecycle, onboarding record, realm, first administrator, default modules, notify."

  @spec name() :: String.t()
  def name, do: @name

  @spec version() :: String.t()
  def version, do: @version

  @spec description() :: String.t()
  def description, do: @description

  @spec start_permission() :: String.t()
  def start_permission, do: @start_permission

  @doc "The graph of v2. Pure."
  @spec graph() :: map()
  def graph do
    tenant = %{"tenant_id" => %{"var" => "tenant_id"}}

    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        call_node("validate", "tenant.validate", %{
          "slug" => %{"var" => "slug"},
          "name" => %{"var" => "name"}
        }),
        call_node("create", "tenant.create", %{
          "slug" => %{"var" => "slug"},
          "name" => %{"var" => "name"},
          "requested_tenant_id" => %{"var" => "requested_tenant_id"},
          "tenant_type" => %{"var" => "tenant_type"}
        }),
        call_node("provision", "tenant.provision", tenant),
        call_node(
          "record_lifecycle",
          "tenant.record_lifecycle",
          Map.put(tenant, "requested_tenant_id", %{"var" => "requested_tenant_id"})
        ),
        call_node(
          "record_onboarding",
          "tenant.record_onboarding",
          Map.put(tenant, "hostname", %{"var" => "hostname"})
        ),
        call_node(
          "bind_realm",
          "tenant.bind_realm",
          Map.put(tenant, "realm_id", %{"var" => "realm_id"})
        ),
        call_node(
          "grant_first_admins",
          "tenant.grant_first_admins",
          Map.put(tenant, "admin_email", %{"var" => "admin_email"})
        ),
        call_node("install_default_modules", "tenant.install_default_modules", tenant),
        %{"id" => "notify_gate", "node_type" => "EXCLUSIVE_GATEWAY"},
        notify_node(),
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        edge("e1", "start", "validate"),
        edge("e2", "validate", "create"),
        edge("e3", "create", "provision"),
        edge("e4", "provision", "record_lifecycle"),
        edge("e5", "record_lifecycle", "record_onboarding"),
        edge("e6", "record_onboarding", "bind_realm"),
        edge("e7", "bind_realm", "grant_first_admins"),
        edge("e8", "grant_first_admins", "install_default_modules"),
        edge("e9", "install_default_modules", "notify_gate"),
        Map.put(
          edge("e10", "notify_gate", "notify"),
          "condition",
          "variables.notify_admin == true"
        ),
        Map.put(edge("e11", "notify_gate", "end"), "is_default", true),
        edge("e12", "notify", "end")
      ]
    }
  end

  @doc "The typed context: one schema per start variable and step output."
  @spec variable_schemas() :: [%{variable_key: String.t(), json_schema: map()}]
  def variable_schemas do
    strings =
      ~w(slug name requested_tenant_id hostname realm_id admin_email tenant_id schema_name)
      |> Enum.map(&%{variable_key: &1, json_schema: %{"type" => "string"}})

    strings ++
      [
        %{
          variable_key: "tenant_type",
          json_schema: %{"type" => "string", "enum" => ["test", "production"]}
        },
        %{variable_key: "notify_admin", json_schema: %{"type" => "boolean"}}
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
    %{
      "id" => id,
      "node_type" => "SERVICE_TASK",
      "attributes" => %{
        "platform_call" => %{
          "function" => function,
          "args" => args,
          "reads" => reads_for(function, args),
          "writes" => writes_for(function)
        }
      }
    }
  end

  # v1's notification node, unchanged.
  defp notify_node do
    %{
      "id" => "notify",
      "node_type" => "SERVICE_TASK",
      "attributes" => %{
        "notify" => %{
          "template_key" => "tenant_registered",
          "recipient" => %{"var" => "admin_email"},
          "values" => %{
            "tenant_name" => %{"var" => "name"},
            "tenant_slug" => %{"var" => "slug"},
            "registered_by" => %{"var" => "admin_email"}
          }
        }
      }
    }
  end

  defp reads_for(function, args) do
    function
    |> entry()
    |> inputs()
    |> Enum.filter(fn input -> match?(%{"var" => _}, Map.get(args, input.name)) end)
    |> Map.new(fn input -> {input.name, type_name(input.type)} end)
  end

  defp writes_for(function) do
    function
    |> entry()
    |> outputs()
    |> Map.new(fn output -> {output.name, type_name(output.type)} end)
  end

  defp entry(function), do: Enum.find(TenantFamily.entries(), &(&1.name == function))

  defp inputs(nil), do: []
  defp inputs(entry), do: entry.inputs

  defp outputs(nil), do: []
  defp outputs(entry), do: entry.outputs

  defp type_name(:number), do: "number"
  defp type_name(:integer), do: "integer"
  defp type_name(:boolean), do: "boolean"
  defp type_name(:object), do: "object"
  defp type_name(:array), do: "array"
  defp type_name(_string_like), do: "string"
end
