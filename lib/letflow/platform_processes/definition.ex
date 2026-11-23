defmodule Letflow.PlatformProcesses.Definition do
  @moduledoc """
  The DOCUMENT of the pilot's registration definition (T-2595, gap G9 of the
  "Register a tenant" pilot; the spike is `project/pilot-register-tenant-design.md`
  of the team repository, sections 3 (G9) and 4 (item 1)).

  The pilot's rule is that a business function is a PROCESS, not a code path:
  the registration of a tenant is a definition of the PLATFORM tenant, drawn in
  the designer, with one node per step of the chain, and the engine runs the
  nodes. This module holds the v1 document -- the graph, the typed context and
  the declared start permission -- as DATA, so that the seed
  (`Letflow.PlatformProcesses.Seed`) writes exactly the version this module
  describes, and a test reads the same document the seed writes.

  ## The steps, in order

      validate -> create -> provision -> bind_realm -> grant_first_admins ->
      notify -> end

  The first five nodes are `platform_call` steps: SERVICE_TASK nodes bound to a
  function of the COMPILED catalogue (`Letflow.PlatformFunctions.Catalog`), the
  tenant family (`Letflow.PlatformFunctions.TenantFamily`). The sixth is the
  NOTIFICATION step of gap G4: it sends the registered template
  `tenant_registered` to an address read from a variable of the running
  instance. The last node is the END.

  The steps are the ones the direct route does today
  (`Letflow.Routers.Onboarding`): validate the form, create the tenant,
  provision its schema and migrate it, bind the realm, grant the first
  administrator, tell the administrator. The catalogue's sixth entry,
  `tenant.install_default_modules`, is NOT a step of v1: the direct path does
  not install the default modules either, so the definition carries the same
  business function the route carries today.

  ## The typed context

  Every node declares what it READS and what it WRITES (gap G13), and the
  definition declares the typed context those declarations are checked
  against. The variables are:

    * `slug`, `name` -- the `:start`-class inputs of `tenant.validate` and
      `tenant.create` (the slug is the tenant's identity, the name its display
      name). They are the names the "Register tenant" form sends;
    * `realm_id` -- the `:start`-class input of `tenant.bind_realm`;
    * `admin_email` -- the `:start`-class input of `tenant.grant_first_admins`
      and the RECIPIENT of the notification step;
    * `hostname` -- the platform tenant's own field for the new tenant. No node
      reads it: the catalogue's `tenant.create` takes the slug and the name
      only. It is declared anyway, because the start carries it
      (`Letflow.PlatformProcesses.register_tenant_variables/1`) and a definition
      that renames one of the start's names cannot be started from the screen;
    * `tenant_id` -- the OUTPUT of `tenant.create`, read by the three steps
      after it (a `:step`-class input, never a person's);
    * `schema_name` -- the OUTPUT of `tenant.provision`.

  A write-like catalogue call reads only `:start` and `:step` sources, so no
  node of this graph reads a variable a person may write: the graph has no
  HUMAN_TASK at all.

  ## The start permission

  The definition DECLARES `TenantsManage` as its start permission. The
  declaration is not weaker than the steps need (every catalogue call of the
  tenant family requires `:TenantsManage`), so the activation fence accepts
  it, and it is the same atom the tenant lifecycle routes already use.

  ## D-180 extension point (owner decision, not built here)

  A standard definition is LOCKED for everyone inside its tenant, and a tenant
  may later FORK it into its own copy (`custom`, recording
  `based_on: <standard key>@<version>`); a per-tenant binding then says which
  definition runs, and the right to edit a copy is the PROCESS_DESIGNER's.

  This module adds NO column and NO map for `based_on` and `custom`: the
  lineage of a forked copy belongs to the DEFINITION ROW
  (`Letflow.Definitions.ProcessDefinition`, whose `start_permission` column
  already carries the D-180 note), and the graph travels with the definition
  document, so a forked copy carries this same document in its own copy.

  Nothing here assumes that a definition is editable by whoever sees it, nor
  that a tenant has exactly one definition per key: the seed writes ONE
  version of ONE key in the platform tenant, and it never overwrites a newer
  version an administrator made.
  """

  alias Letflow.PlatformFunctions.TenantFamily

  @name "platform.register_tenant"
  @version "1"
  @start_permission "TenantsManage"

  @description "Register a tenant: validate, create, provision and migrate, bind the realm and the first administrator, notify."

  @doc """
  The key of the registration definition in the platform tenant.
  """
  @spec name() :: String.t()
  def name, do: @name

  @doc """
  The version this document is: "1". A later release ships a newer version of
  the SAME document; the seed never overwrites a version an administrator
  already made (`Letflow.PlatformProcesses.Seed`).
  """
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  The one-sentence description of the definition, shown in the designer's list.
  """
  @spec description() :: String.t()
  def description, do: @description

  @doc """
  The permission a caller must hold to START an instance of this definition:
  `TenantsManage`, the platform atom of the tenant lifecycle.
  """
  @spec start_permission() :: String.t()
  def start_permission, do: @start_permission

  @doc """
  The graph of the definition: the nodes of the chain, in order, and the edges
  between them.

  Pure: the same value on every call, so the seed and the tests read one
  document.
  """
  @spec graph() :: map()
  def graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        call_node("validate", "tenant.validate", %{
          "slug" => %{"var" => "slug"},
          "name" => %{"var" => "name"}
        }),
        call_node("create", "tenant.create", %{
          "slug" => %{"var" => "slug"},
          "name" => %{"var" => "name"}
        }),
        call_node("provision", "tenant.provision", %{"tenant_id" => %{"var" => "tenant_id"}}),
        call_node("bind_realm", "tenant.bind_realm", %{
          "tenant_id" => %{"var" => "tenant_id"},
          "realm_id" => %{"var" => "realm_id"}
        }),
        call_node("grant_first_admins", "tenant.grant_first_admins", %{
          "tenant_id" => %{"var" => "tenant_id"},
          "admin_email" => %{"var" => "admin_email"}
        }),
        notify_node(),
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "validate"},
        %{"id" => "e2", "source" => "validate", "target" => "create"},
        %{"id" => "e3", "source" => "create", "target" => "provision"},
        %{"id" => "e4", "source" => "provision", "target" => "bind_realm"},
        %{"id" => "e5", "source" => "bind_realm", "target" => "grant_first_admins"},
        %{"id" => "e6", "source" => "grant_first_admins", "target" => "notify"},
        %{"id" => "e7", "source" => "notify", "target" => "end"}
      ]
    }
  end

  @doc """
  The typed context of the definition: one schema per variable the steps read
  or write, of the type the step declared.

  The list is the shape `Letflow.Definitions.register_variable_schemas/3`
  takes (`%{variable_key: key, json_schema: schema}`).
  """
  @spec variable_schemas() :: [%{variable_key: String.t(), json_schema: map()}]
  def variable_schemas do
    [
      "slug",
      "name",
      "hostname",
      "realm_id",
      "admin_email",
      "tenant_id",
      "schema_name"
    ]
    |> Enum.map(&%{variable_key: &1, json_schema: %{"type" => "string"}})
  end

  @doc """
  The attributes of a definition of this document: the key, the version, the
  description, the graph and the declared start permission.

  `created_by` is NOT part of it: the caller names the person the version is
  created for (the seed: the platform administrator whose authority signs the
  activation).
  """
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

  # A catalogue call node. Its typed mapping is DERIVED from the compiled
  # catalogue (the same derivation `Letflow.Support.PlatformCallFixture` makes
  # in the tests): the reads are the arguments the step takes from a VARIABLE,
  # the writes are the outputs the function produces. A declaration that did
  # not match the catalogue would be refused by the activation fence
  # (`Letflow.Definitions.StepMapping`), so the two can never disagree.
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

  # The notification step: the registered template, the recipient read from a
  # variable and the values. The recipient is NEVER a constant: an address in
  # the stored definition would be personal data the platform does not store
  # (INV-4, `Letflow.Definitions.NotifyCalls`).
  #
  # The values name placeholders of the template's allow-list
  # (`tenant_registered`: tenant_name, tenant_slug, registered_by). The
  # registrar of the pilot is the person the form was filled in for, and the
  # start carries no separate registrar address: the first administrator's
  # address is the one the start carries, and it is the recipient too.
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

  # The variables the step reads: the catalogue inputs the arguments take from
  # a VARIABLE. A constant argument reads nothing.
  defp reads_for(function, args) do
    function
    |> entry()
    |> inputs()
    |> Enum.filter(fn input -> match?(%{"var" => _}, Map.get(args, input.name)) end)
    |> Map.new(fn input -> {input.name, type_name(input.type)} end)
  end

  # The variables the step writes: the outputs the function produces.
  defp writes_for(function) do
    function
    |> entry()
    |> outputs()
    |> Map.new(fn output -> {output.name, type_name(output.type)} end)
  end

  defp entry(function) do
    Enum.find(TenantFamily.entries(), &(&1.name == function))
  end

  defp inputs(nil), do: []
  defp inputs(entry), do: entry.inputs

  defp outputs(nil), do: []
  defp outputs(entry), do: entry.outputs

  # The JSON-Schema type name of a catalogue type. A uuid is a string in the
  # instance variables, so it is declared as one.
  defp type_name(:string), do: "string"
  defp type_name(:uuid), do: "string"
  defp type_name(:number), do: "number"
  defp type_name(:integer), do: "integer"
  defp type_name(:boolean), do: "boolean"
  defp type_name(:object), do: "object"
  defp type_name(:array), do: "array"
  defp type_name(_other), do: "string"
end
