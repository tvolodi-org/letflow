defmodule Letflow.Definitions.ExtensionSiteActivationTest do
  @moduledoc """
  REQ-574 / GH #3256 (decision 0071 D9 slice X1): `Definitions.activate/2` refuses a draft whose
  owner module version declares an extension point naming a node the graph lacks
  (`:extension_site_unknown_node`), and checks nothing for a draft without an owner, whose owner
  declares no points, or whose owner version is not registered.

  Lives in its own file, not in `test/letflow/definitions_test.exs`, because that file is a pure
  `async: true` module without a database sandbox; this one needs a provisioned tenant.

  `async: false`: tenant provisioning switches the sandbox to `:auto`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Identity.User
  alias Letflow.Modules.Fixture
  alias Letflow.Modules.FixturePoints
  alias Letflow.TenantFixture

  # the fixture's point names definition "fx_points_def" and node "review"
  @definition "fx_points_def"

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "req574-act")
    schema = tenant.schema_name

    user =
      %User{}
      |> Ecto.Changeset.change(%{
        username: "req574-#{Ecto.UUID.generate()}",
        display_name: "REQ-574 Test User",
        email: "req574-#{Ecto.UUID.generate()}@example.com",
        password_hash: "__NO_PASSWORD_SET__",
        status: :active,
        auth_source: :internal
      })
      |> Repo.insert!(prefix: schema)

    %{schema: schema, user: user}
  end

  defp activator(user),
    do: Activator.from_auth_context(%{user_id: user.id, roles: ["TENANT_ADMIN"]}, false)

  # START -> (node `id`) -> END, a plain valid graph
  defp graph(node_id) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => node_id,
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "REVIEWER"}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => node_id},
        %{"id" => "e2", "source" => node_id, "target" => "end"}
      ]
    }
  end

  defp draft!(schema, graph, owner) do
    attrs = %{name: @definition, version: "1", graph: graph, created_by: Ecto.UUID.generate()}

    result =
      if owner,
        do: Definitions.create_owned(attrs, [prefix: schema], owner),
        else: Definitions.create(attrs, prefix: schema)

    assert {:ok, %ProcessDefinition{status: :draft} = row} = result
    row
  end

  defp activate(ctx, draft),
    do: Definitions.activate(draft.id, prefix: ctx.schema, activator: activator(ctx.user))

  defp status(ctx, draft), do: Repo.get!(ProcessDefinition, draft.id, prefix: ctx.schema).status

  defp points_owner(overrides \\ %{}),
    do: Map.merge(ManagedTypes.module_owner(FixturePoints), overrides)

  test "A1: an unknown site node refuses activation and the draft stays draft", ctx do
    draft = draft!(ctx.schema, graph("other"), points_owner())

    assert {:error, {:semantic_validation_failed, violations}} = activate(ctx, draft)
    assert Enum.any?(violations, &(&1.code == :extension_site_unknown_node))
    assert status(ctx, draft) == :draft
  end

  # The fixture manifest is fixed at compile time, so "the node id corrected" is done on the
  # graph side: the graph gets the node `review` the point names.
  test "A2: with the node in the graph the draft activates", ctx do
    draft = draft!(ctx.schema, graph("review"), points_owner())

    assert {:ok, %{already_active: false}} = activate(ctx, draft)
    assert status(ctx, draft) == :active
  end

  test "A3: a draft with no owner module activates, no extension violation", ctx do
    draft = draft!(ctx.schema, graph("other"), nil)

    assert {:ok, %{already_active: false}} = activate(ctx, draft)
  end

  test "A4: an owner module that declares no points activates", ctx do
    draft = draft!(ctx.schema, graph("other"), ManagedTypes.module_owner(Fixture))

    assert {:ok, %{already_active: false}} = activate(ctx, draft)
  end

  test "A5: an owner version no registered manifest has is not checked", ctx do
    draft = draft!(ctx.schema, graph("other"), points_owner(%{version: "9.9.9"}))

    assert {:ok, %{already_active: false}} = activate(ctx, draft)
  end
end
