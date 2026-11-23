defmodule Letflow.Support.PlatformCallFixture do
  @moduledoc """
  Fixtures for the platform-call authority rule (T-2588, "Register a tenant"
  pilot, gap G2; decision record
  `docs/migration/decisions/0094-platform-call-authority.md`).

  A `platform_call` step is a SERVICE_TASK bound to a platform function of the
  compiled catalogue. These helpers build the pieces the authority rule needs:

    * `tenant!/1` -- a provisioned tenant (the platform tenant is pinned by the
      caller, so `Letflow.PlatformTenant.platform_prefix?/1` answers for it);
    * `user!/2` -- an active user;
    * `platform_admin!/2` -- a user holding the `PLATFORM_ADMIN` platform role
      (a `:platform_role` binding, the only role that holds `:TenantsManage`);
    * `graph/1` -- START -> the platform-call SERVICE_TASK -> END;
    * `definition!/3` -- a DRAFT carrying that graph.

  Real Postgres, no mocks. Every helper takes no optional argument (the
  project's anti-pattern ISS-0069).
  """

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Identity.Group
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User
  alias Letflow.PlatformFunctions.Catalog
  alias Letflow.Repo
  alias Letflow.TenantFixture

  @doc "A provisioned tenant: `%{tenant_id, schema_name}`."
  @spec tenant!(String.t()) :: %{tenant_id: String.t(), schema_name: String.t()}
  def tenant!(slug_prefix) do
    %{tenant_id: tenant_id, schema_name: schema_name} =
      TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)

    %{tenant_id: tenant_id, schema_name: schema_name}
  end

  @doc "An active user of `schema_name`."
  @spec user!(String.t(), String.t()) :: User.t()
  def user!(schema_name, label) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "pcf-#{label}-#{Ecto.UUID.generate()}",
      display_name: "PCF #{label}",
      email: "pcf-#{label}-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema_name)
  end

  @doc """
  Gives `user` the `PLATFORM_ADMIN` platform role in `schema_name` (a
  `:platform_role` binding -- the kind `Identity.list_effective_role_names/2`
  reads).
  """
  @spec platform_admin!(String.t(), User.t()) :: :ok
  def platform_admin!(schema_name, user) do
    group =
      %Group{}
      |> Ecto.Changeset.change(%{
        name: "pcf-platform-admin-#{Ecto.UUID.generate()}",
        display_name: "PCF Platform Admin"
      })
      |> Repo.insert!(prefix: schema_name)

    %TenantRole{}
    |> Ecto.Changeset.change(%{name: "PLATFORM_ADMIN", kind: :platform_role, group_id: group.id})
    |> Repo.insert!(prefix: schema_name)

    %GroupMember{}
    |> Ecto.Changeset.change(%{group_id: group.id, user_id: user.id})
    |> Repo.insert!(prefix: schema_name)

    :ok
  end

  @doc "Removes every platform-role binding of `user` in `schema_name` (a revoked role)."
  @spec revoke_platform_roles!(String.t(), User.t()) :: :ok
  def revoke_platform_roles!(schema_name, user) do
    Repo.delete_all(
      from(gm in GroupMember, where: gm.user_id == ^user.id),
      prefix: schema_name
    )

    :ok
  end

  @doc """
  The `platform_call` attribute of a step: `%{"function" => name, "args" => args}`
  plus the step's TYPED MAPPING (T-2594, pilot gap G13): the `reads` and the
  `writes` of the step, each a map of a variable name to its type.

  The mapping is derived from the compiled catalogue: the reads are the
  arguments the step takes from a VARIABLE, the writes are the outputs the
  function produces. A function that is not in the catalogue has neither -- the
  catalogue refuses the call itself with `:platform_call_function_unknown`.
  """
  @spec call(String.t(), map()) :: map()
  def call(function, args) do
    %{
      "function" => function,
      "args" => args,
      "reads" => reads_for(function, args),
      "writes" => writes_for(function)
    }
  end

  # The variables the step reads: the catalogue inputs the arguments take from
  # a VARIABLE. A constant argument reads nothing.
  defp reads_for(function, args) do
    case Catalog.fetch(function) do
      {:ok, entry} ->
        entry.inputs
        |> Enum.filter(fn input -> match?(%{"var" => _}, Map.get(args, input.name)) end)
        |> Map.new(fn input -> {input.name, type_name(input.type)} end)

      {:error, :not_found} ->
        %{}
    end
  end

  # The variables the step writes: the outputs the function produces.
  defp writes_for(function) do
    case Catalog.fetch(function) do
      {:ok, entry} ->
        Map.new(entry.outputs, fn output -> {output.name, type_name(output.type)} end)

      {:error, :not_found} ->
        %{}
    end
  end

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

  @doc """
  START -> a SERVICE_TASK carrying the `platform_call` `call` -> END. `extra`
  is merged into the SERVICE_TASK's attributes.
  """
  @spec graph(map(), map()) :: map()
  def graph(call, extra \\ %{}) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "call",
          "node_type" => "SERVICE_TASK",
          "attributes" => Map.merge(%{"platform_call" => call}, extra)
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "call"},
        %{"id" => "e2", "source" => "call", "target" => "end"}
      ]
    }
  end

  @doc """
  A DRAFT definition carrying `graph`. `name` must be unique in the tenant.

  The definition also carries the VARIABLE SCHEMAS of the step's typed
  mapping (T-2594, pilot gap G13): one schema per declared read and per
  declared write, of the type the step declared. The activation fence checks
  the mapping against these schemas, so a definition that declares a variable
  it does not declare is refused -- and a fixture that does not declare the
  schemas would be refused for the wrong reason.
  """
  @spec definition!(String.t(), map(), String.t()) :: Definitions.ProcessDefinition.t()
  def definition!(schema_name, graph, name), do: version!(schema_name, graph, name, "1")

  @doc """
  A DRAFT definition carrying `graph` at `version` -- the second version of a
  key, with the same variable schemas as the first.
  """
  @spec version!(String.t(), map(), String.t(), String.t()) :: Definitions.ProcessDefinition.t()
  def version!(schema_name, graph, name, version) do
    {:ok, definition} =
      Definitions.create_with_variable_schemas(
        %{
          name: name,
          version: version,
          graph: graph,
          created_by: Ecto.UUID.generate()
        },
        variable_schemas(graph),
        prefix: schema_name
      )

    definition
  end

  @doc """
  A DRAFT definition carrying `graph` and EXACTLY the given variable schemas.

  The schemas are a list of `%{variable_key: key, json_schema: schema}` maps,
  the shape `Letflow.Definitions.register_variable_schemas/3` takes. A test
  that needs a variable the step declares but the definition does NOT needs
  this helper: `definition!/3` derives the schemas from the step's own
  declaration.
  """
  @spec definition_with_schemas!(String.t(), map(), String.t(), [map()]) ::
          Definitions.ProcessDefinition.t()
  def definition_with_schemas!(schema_name, graph, name, schemas) do
    {:ok, definition} =
      Definitions.create_with_variable_schemas(
        %{
          name: name,
          version: "1",
          graph: graph,
          created_by: Ecto.UUID.generate()
        },
        schemas,
        prefix: schema_name
      )

    definition
  end

  # The variable schemas of the graph's platform-call steps: one per declared
  # read and per declared write, of the type the step declared.
  defp variable_schemas(graph) do
    graph
    |> Map.get("nodes", [])
    |> Enum.flat_map(fn node ->
      case get_in(node, ["attributes", "platform_call"]) do
        call when is_map(call) ->
          Map.merge(Map.get(call, "reads", %{}), Map.get(call, "writes", %{}))
          |> Enum.map(fn {key, type} ->
            %{variable_key: key, json_schema: %{"type" => type}}
          end)

        _not_a_call ->
          []
      end
    end)
    |> Enum.uniq_by(& &1.variable_key)
  end
end
