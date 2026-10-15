defmodule Letflow.Entities.EntityTypeMissingTest do
  @moduledoc """
  GH #2587 / REQ-499 PR B1, carry-over CO-5 / GH #2633 (design
  `gh2587-req499-pr-b-human-task-writes.md` 6.1, 6.2, D-B.7): `validate_lines/2` refuses a line
  whose `entity_type` is missing, not a string, empty or blank with
  `%{index: i, code: :entity_type_missing}` BEFORE `prepare/2` could silently skip it;
  `prepare/2` stays lenient; that is pinned in `step_writes_prepare_test.exs` (it needs the
  sandbox in `:auto` mode, because `prepare/2` refuses to run inside a caller's transaction).

  The ordering test injects a spy as the `:entity_port` (the same config key `EntityPort.impl/0`
  reads): it delegates to the real implementation and reports every call, so a `prepare/2` call
  at activation would be seen.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Entities.Definitions, as: EntityDefinitions
  alias Letflow.Entities.EntityPortImpl
  alias Letflow.Entities.EntityTypeInstance
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.StepWrites
  alias Letflow.Identity.User
  alias Letflow.TenantFixture

  defmodule SpyPort do
    @moduledoc false
    @behaviour Letflow.Engine.EntityPort

    defp report(call), do: send(:persistent_term.get({__MODULE__, :pid}), {:port_call, call})

    @impl true
    def prefetch(prefix, reads, vars), do: EntityPortImpl.prefetch(prefix, reads, vars)

    @impl true
    def prepare(lines, ctx) do
      report(:prepare)
      EntityPortImpl.prepare(lines, ctx)
    end

    @impl true
    def validate_lines(lines, ctx) do
      report(:validate_lines)
      EntityPortImpl.validate_lines(lines, ctx)
    end

    @impl true
    def multi(multi, lines, ctx) do
      report(:multi)
      EntityPortImpl.multi(multi, lines, ctx)
    end

    @impl true
    def interpret_failure(step, reason), do: EntityPortImpl.interpret_failure(step, reason)
  end

  setup do
    env = [:entity_port]
    previous = Enum.map(env, &{&1, Application.fetch_env(:letflow, &1)})

    on_exit(fn ->
      for {key, saved} <- previous do
        case saved do
          {:ok, value} -> Application.put_env(:letflow, key, value)
          :error -> Application.delete_env(:letflow, key)
        end
      end

      :persistent_term.erase({SpyPort, :pid})
    end)

    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "gh2587-b1-co5")
    schema = tenant.schema_name
    {:ok, _} = EventTypes.seed!(schema)

    {:ok, row} =
      EntityDefinitions.create_definition(
        %{
          definition: %{
            name: "stock_move",
            display_name: "stock_move",
            fields: [%{name: "label", type: :string}],
            writable_by_process: true,
            append_only: true
          },
          created_by: Ecto.UUID.generate()
        },
        schema
      )

    {:ok, _} = EntityDefinitions.activate_definition(row.name, Ecto.UUID.generate(), "go", schema)

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "gh2587-b1-#{Ecto.UUID.generate()}",
        display_name: "GH-2587 B1 CO-5 User",
        email: "gh2587-b1-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: schema)

    %{schema: schema, user: user}
  end

  defp valid_line, do: %{"op" => "create", "entity_type" => "stock_move"}

  defp graph(lines) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "ht",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "R", "entity_writes" => lines}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "ht"},
        %{"id" => "e2", "source" => "ht", "target" => "end"}
      ]
    }
  end

  test "each missing / non-string / blank entity_type is refused with :entity_type_missing",
       %{schema: schema} do
    bad_lines = [
      %{"op" => "create"},
      %{"op" => "create", "entity_type" => nil},
      %{"op" => "create", "entity_type" => 7},
      %{"op" => "create", "entity_type" => ""},
      %{"op" => "create", "entity_type" => "   "}
    ]

    for {bad, i} <- Enum.with_index(bad_lines) do
      assert {:error, [%{index: 0, code: :entity_type_missing}]} =
               StepWrites.validate_lines([bad], %{prefix: schema}),
             "case #{i}: #{inspect(bad)}"
    end

    # the index is the declared position
    assert {:error, [%{index: 1, code: :entity_type_missing}]} =
             StepWrites.validate_lines([valid_line(), %{"op" => "create"}], %{prefix: schema})
  end

  test "an invalid type NAME is a different code", %{schema: schema} do
    assert {:error, [%{index: 0, code: :entity_type_name_invalid}]} =
             StepWrites.validate_lines(
               [%{"op" => "create", "entity_type" => "Stock-Move"}],
               %{prefix: schema}
             )
  end

  test "ordering: activation fails at validate_lines/2; prepare/2 is never called; no instance row",
       %{schema: schema, user: user} do
    :persistent_term.put({SpyPort, :pid}, self())
    Application.put_env(:letflow, :entity_port, SpyPort)

    draft =
      %ProcessDefinition{}
      |> ProcessDefinition.create_changeset(%{
        name: "co5-#{System.unique_integer([:positive])}",
        version: "1",
        graph: graph([valid_line(), %{"op" => "create"}]),
        created_by: user.id
      })
      |> Repo.insert!(prefix: schema)

    activator = Activator.from_auth_context(%{user_id: user.id, roles: ["TENANT_ADMIN"]}, false)

    assert {:error,
            {:entity_writes_invalid, [%{node_id: "ht", index: 1, code: :entity_type_missing}]}} =
             Definitions.activate(draft.id, prefix: schema, activator: activator)

    assert_received {:port_call, :validate_lines}
    refute_received {:port_call, :prepare}
    refute_received {:port_call, :multi}

    assert Repo.all(from(i in EntityTypeInstance, select: i.entity_type), prefix: schema) == []

    assert %{status: :draft, activated_by: nil} =
             Repo.get!(ProcessDefinition, draft.id, prefix: schema)
  end

  test "valid lines behave as before: validate_lines/2 is :ok once the gate is open",
       %{schema: schema} do
    assert StepWrites.validate_lines([valid_line()], %{prefix: schema}) == :ok
    assert StepWrites.validate_lines([], %{prefix: schema}) == :ok
  end
end
