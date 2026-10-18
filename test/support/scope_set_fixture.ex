defmodule Letflow.Support.ScopeSetFixture do
  @moduledoc """
  Test-only helpers for the REQ-518 / GH #2535 slice 2c-i-a tests (scoped data path: compiler
  scope argument, `ScopeDeclaration`, `Scope.allowed_set/2`, `ScopeNodePaths.allowed_node_ids/2`;
  design `lib/letflow/design/req518-compiler-scope-filter.md` 3.8; spec
  `test/specs/REQ-518-2c-i-a.md`).

  `provision!/1` builds, in one dedicated provisioned tenant (sandbox `:auto`, writes committed,
  cleaned up by the fixture teardown), the whole design-3.8 fixture:

    * the scope-node tree

          root
          |- a  (children a1, a2, a3)      a2 is RETIRED and has a LIVE child a2x;
          |                                a3 is a RETIRED leaf
          '- b  (child b1)

      (node ids are `sf-root`, `sf-a`, `sf-a1`, `sf-a2`, `sf-a2x`, `sf-a3`, `sf-b`, `sf-b1`; the
      map key of `nodes/0` is the short atom);
    * the `fixture_scoped` module INSTALLED (its pack defines `scoped_item`, `scoped_child`,
      `scoped_master`, `scoped_managed_item`, all promoted), and
    * `seed_items!/1` (one `scoped_item` per node plus one with a NULL scope, amounts are
      distinct powers of two so a sum identifies exactly which rows were counted) and
      `seed_children!/1` (the join data).

  Principals are built with `principal/2` (a real user whose role comes from group membership
  of the TASK_WORKER binding group, whose own rows are removed, and whose scope comes from
  USER-level grant rows, so several differently scoped principals coexist in one tenant).
  Callers are `async: false`.
  """

  import Ecto.Query, only: [from: 2]

  alias Letflow.Api.Scope
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.Records
  alias Letflow.Modules.Installs
  alias Letflow.Repo
  alias Letflow.ScopeNodePaths
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.ScopedGrantsFixture, as: S
  alias Letflow.Support.TokenMintFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.ColumnPromotion

  @role "TASK_WORKER"

  @nodes %{
    root: "sf-root",
    a: "sf-a",
    a1: "sf-a1",
    a2: "sf-a2",
    a2x: "sf-a2x",
    a3: "sf-a3",
    b: "sf-b",
    b1: "sf-b1"
  }

  # node key => amount (distinct powers of two; :none is the NULL-scope row)
  @amounts %{
    root: 256,
    a: 1,
    a1: 2,
    a2: 4,
    a2x: 8,
    a3: 16,
    b: 32,
    b1: 64,
    none: 128
  }

  @doc "The node ids by short key."
  @spec nodes() :: %{atom() => String.t()}
  def nodes, do: @nodes

  @doc "The `amount` of the item seeded under each node key (`:none` is the NULL-scope item)."
  @spec amounts() :: %{atom() => pos_integer()}
  def amounts, do: @amounts

  @doc "The role every scoped principal of this fixture holds."
  @spec role() :: String.t()
  def role, do: @role

  @doc "The sum of the amounts of the given node keys."
  @spec sum([atom()]) :: non_neg_integer()
  def sum(keys), do: keys |> Enum.map(&Map.fetch!(@amounts, &1)) |> Enum.sum()

  @doc """
  Provisions the tenant (with `S.tenant!/1`), builds the node tree, seeds the event types and
  installs `fixture_scoped`. Returns the fixture map (`S.tenant!/1`'s keys) plus `:nodes`.
  """
  @spec provision!(String.t(), keyword()) :: map()
  def provision!(slug_prefix, tenant_opts \\ []) do
    fx = S.tenant!(slug_prefix, tenant_opts)
    schema = fx.schema_name

    ExUnit.Callbacks.on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^fx.tenant_id))

      Repo.delete_all(from(b in SolutionPackArtefactBase, where: b.tenant_id == ^fx.tenant_id))

      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^fx.tenant_id))
    end)

    build_tree!(schema)
    {:ok, _seeded} = EventTypes.seed!(schema)

    {:ok, _install} =
      Installs.install("fixture_scoped", Ecto.UUID.generate(),
        prefix: schema,
        rationale: "REQ-518 2c-i-a fixture"
      )

    Map.put(fx, :nodes, @nodes)
  end

  @doc """
  Builds only the scope-node tree (no module, no event types) in `schema`; `provision!/2` calls it.
  Public so that task fixtures (REQ-518 PR 2d, `Letflow.Support.TaskScopeFixture`) can reuse the
  one tree definition instead of duplicating it.
  """
  @spec build_tree!(String.t()) :: :ok
  def build_tree!(schema) do
    for {id, parent} <- [
          {@nodes.root, nil},
          {@nodes.a, @nodes.root},
          {@nodes.a1, @nodes.a},
          {@nodes.a2, @nodes.a},
          {@nodes.a2x, @nodes.a2},
          {@nodes.a3, @nodes.a},
          {@nodes.b, @nodes.root},
          {@nodes.b1, @nodes.b}
        ] do
      {:ok, _node} = ScopeNodePaths.write({:insert, id, parent}, schema)
    end

    # the retired INTERMEDIATE node (it has the live child a2x) and the retired LEAF
    {:ok, _a2} = ScopeNodePaths.write({:retire, @nodes.a2}, schema)
    {:ok, _a3} = ScopeNodePaths.write({:retire, @nodes.a3}, schema)
    :ok
  end

  @doc """
  One `scoped_item` per node key and one with no `scope_node` at all (`:none`), each with
  `name = "item-<key>"` and `amount`. Returns `%{key => record}`.
  """
  @spec seed_items!(map()) :: %{atom() => map()}
  def seed_items!(fx) do
    for {key, amount} <- @amounts, into: %{} do
      values = %{"name" => "item-#{key}", "amount" => amount}
      values = if key == :none, do: values, else: Map.put(values, "scope_node", @nodes[key])
      {key, create!(fx.schema_name, "scoped_item", values)}
    end
  end

  @doc """
  The join data (all `scoped_child`): `ca` (scope a) under the item of `a`, `cb` (scope b, so
  OUT of scope for a subtree-`a` caller) under the item of `a1`, `cb1` (scope b1) under the item
  of `b`. Returns `%{ca:, cb:, cb1:}`.
  """
  @spec seed_children!(map(), %{atom() => map()}) :: %{atom() => map()}
  def seed_children!(fx, items) do
    schema = fx.schema_name

    %{
      ca:
        create!(schema, "scoped_child", %{
          "name" => "child-ca",
          "scope_node" => @nodes.a,
          "item_id" => items.a.record_id
        }),
      cb:
        create!(schema, "scoped_child", %{
          "name" => "child-cb",
          "scope_node" => @nodes.b,
          "item_id" => items.a1.record_id
        }),
      cb1:
        create!(schema, "scoped_child", %{
          "name" => "child-cb1",
          "scope_node" => @nodes.b1,
          "item_id" => items.b.record_id
        })
    }
  end

  @doc "Creates one record of `entity_type` through `Records.create_record/2`."
  @spec create!(String.t(), String.t(), map()) :: map()
  def create!(schema, entity_type, field_values) do
    attrs = %{
      entity_type: entity_type,
      field_values: field_values,
      actor_id: Ecto.UUID.generate(),
      idempotency_key: Ecto.UUID.generate()
    }

    {:ok, %{record: record}} = Records.create_record(attrs, schema)
    record
  end

  @doc """
  A principal holding `TASK_WORKER`, built from the database exactly as the pipeline builds it
  (`S.principal/2`). `spec` is one of

    * `{:nodes, [node_key]}`: scoped-only, one USER-level grant row per node;
    * `:tenant_wide`: one user-level tenant-wide row;
    * `:zero_rows`: holds the role (group membership) and has NO grant row at all.

  The TASK_WORKER binding group's own rows are removed first (idempotent), so the group
  contributes no tenant-wide row to anybody.
  """
  @spec principal(map(), {:nodes, [atom()]} | :tenant_wide | :zero_rows) :: Scope.Principal.t()
  def principal(fx, spec) do
    schema = fx.schema_name
    group = RSG.group_of!(schema, @role)
    _removed = RSG.raw_delete_rows!(schema, group, @role)
    user = TokenMintFixture.role_holder!(schema, [@role])

    case spec do
      {:nodes, keys} ->
        for key <- keys, do: RSG.raw_user_row!(schema, user.id, @role, Map.fetch!(@nodes, key))

      :tenant_wide ->
        RSG.raw_user_row!(schema, user.id, @role, nil)

      :zero_rows ->
        :ok
    end

    S.principal(fx, user.id)
  end

  @doc """
  A real user who holds `role` ONLY through user-level grant rows (no group membership, so no
  group row contributes anything): `{:nodes, [node_key]}` one row per node, `:tenant_wide` one
  tenant-wide row, `:zero_rows` none. The role itself is claimed by the request context
  (`Letflow.Support.ScopeOnFixture.call/8`), as the REQ-517 2b tests do. Used by the REQ-518
  2c-i-b route tests, which need a role other than the fixed `TASK_WORKER` of `principal/2`
  (the export route needs `TENANT_ADMIN`).
  """
  @spec holder!(map(), String.t(), {:nodes, [atom()]} | :tenant_wide | :zero_rows) ::
          Letflow.Identity.User.t()
  def holder!(fx, role, spec) do
    schema = fx.schema_name
    user = RSG.user!(schema)

    case spec do
      {:nodes, keys} ->
        for key <- keys, do: RSG.raw_user_row!(schema, user.id, role, Map.fetch!(@nodes, key))

      :tenant_wide ->
        RSG.raw_user_row!(schema, user.id, role, nil)

      :zero_rows ->
        :ok
    end

    user
  end

  @doc "A token principal (tokens are tenant-wide, design D1): no user, no grants."
  @spec token_principal(map()) :: Scope.Principal.t()
  def token_principal(fx) do
    %Scope.Principal{
      kind: :token,
      user_id: Ecto.UUID.generate(),
      prefix: fx.schema_name,
      platform_tenant?: false,
      roles: [:TASK_WORKER],
      grants: :token
    }
  end

  @doc "A PLATFORM_ADMIN principal of the platform tenant (built directly, no database)."
  @spec platform_admin_principal(map()) :: Scope.Principal.t()
  def platform_admin_principal(fx) do
    %Scope.Principal{
      kind: :user,
      user_id: Ecto.UUID.generate(),
      prefix: fx.schema_name,
      platform_tenant?: true,
      roles: [:PLATFORM_ADMIN],
      grants: nil
    }
  end

  @join_one_hop %{entity_type: "scoped_child", fk: "fk_scoped_child_item_id"}

  @doc """
  The six request shapes of design T-C1 (plus two aggregate shapes), as
  `{name, :compile | :aggregate, request}`. The shape named `"latest_filter"` is for the type
  `scoped_master` AFTER `drop_type_table!/2` (it then reads from `:latest`); every other shape is
  for the promoted per-type tables.
  """
  @spec sql_shapes() :: [{String.t(), :compile | :aggregate, map()}]
  def sql_shapes do
    [
      {"plain", :compile, %{entity_type: "scoped_item"}},
      {"plain_filter_sort", :compile,
       %{
         entity_type: "scoped_item",
         filters: [%{field: "name", op: :eq, value: "item-a"}],
         sort: [%{field: "amount", dir: :asc}]
       }},
      {"latest_filter", :compile,
       %{
         entity_type: "scoped_master",
         filters: [%{field: "name", op: :eq, value: "m"}]
       }},
      {"inner_join", :compile, %{entity_type: "scoped_item", join: [@join_one_hop]}},
      {"left_join", :compile,
       %{entity_type: "scoped_item", join: [Map.put(@join_one_hop, :type, :left)]}},
      {"through_join", :compile,
       %{
         entity_type: "scoped_item",
         join: [
           %{
             entity_type: "scoped_item",
             through: "scoped_child",
             fk: "fk_scoped_child_item_id",
             type: :left
           }
         ]
       }},
      {"aggregate_group_by", :aggregate,
       %{
         entity_type: "scoped_item",
         aggregates: [%{fn: :count}, %{fn: :sum, field: "amount"}],
         group_by: [%{field: "scope_node"}]
       }},
      {"aggregate_join", :aggregate,
       %{
         entity_type: "scoped_item",
         aggregates: [%{fn: :count}],
         join: [@join_one_hop]
       }}
    ]
  end

  @doc """
  The SQL text and the inspected parameter list of the query the compiler builds for `request`
  under `scope` (no execution). `compiler` is the module to call (the real one, or a renamed copy
  of the pre-change source).
  """
  @spec sql_of(module(), :compile | :aggregate, map(), String.t(), term()) ::
          %{String.t() => String.t()}
  def sql_of(compiler, kind, request, schema, scope) do
    {:ok, query} =
      case {kind, scope} do
        {:compile, :pre_change} -> compiler.compile(request, schema)
        {:aggregate, :pre_change} -> compiler.compile_aggregate(request, schema)
        {:compile, _} -> compiler.compile(request, schema, scope)
        {:aggregate, _} -> compiler.compile_aggregate(request, schema, scope)
      end

    {sql, params} = Repo.to_sql(:all, query)
    %{"sql" => sql, "params" => inspect(params)}
  end

  @doc """
  An ordinary tenant type `plain_undeclared` (no module names it, so it is UNDECLARED) with a
  promoted fk `item_id` to `scoped_item`, and one row under the item of scope `a`
  (`name = "pu-a"`). Used for the undeclared-primary and undeclared-joined-target cases.
  """
  @spec create_plain_undeclared!(map(), %{atom() => map()}) :: map()
  def create_plain_undeclared!(fx, items) do
    schema = fx.schema_name

    {:ok, definition} =
      Definitions.create_definition(
        %{
          definition: %{
            name: "plain_undeclared",
            display_name: "Plain Undeclared",
            fields: [
              %{name: "name", type: :string, queried: true},
              %{name: "item_id", type: :string}
            ],
            foreign_keys: [
              %{name: "fk_plain_item", field: "item_id", references_entity: "scoped_item"}
            ]
          },
          created_by: Ecto.UUID.generate()
        },
        schema
      )

    {:ok, _active} =
      Definitions.activate_definition(definition.name, Ecto.UUID.generate(), "go-live", schema)

    for attribute <- ["name", "item_id"] do
      column_spec =
        if attribute == "item_id",
          do: %{pg_type: "uuid", nullable: true, references_entity: "scoped_item"},
          else: %{pg_type: "text", nullable: true}

      {:ok, [row]} =
        TenantProvisioning.register_column_promotion(
          "plain_undeclared",
          attribute,
          column_spec,
          [fx.tenant_id]
        )

      {:ok, _promoted} = TenantProvisioning.run_column_promotion(row.id)
    end

    create!(schema, "plain_undeclared", %{"name" => "pu-a", "item_id" => items.a.record_id})
  end

  @doc "`DROP TABLE` of the per-type table of `entity_type` (the type then reads from `:latest`)."
  @spec drop_type_table!(map(), String.t()) :: :ok
  def drop_type_table!(fx, entity_type) do
    {:ok, table} = Letflow.TenantProvisioning.table_name_for_entity_type(entity_type)
    Repo.query!(~s(DROP TABLE "#{fx.schema_name}"."#{table}" CASCADE))
    :ok
  end

  @doc "`ALTER TABLE ... DROP COLUMN` of the scope column of `entity_type` (declared, not present)."
  @spec drop_scope_column!(map(), String.t()) :: :ok
  def drop_scope_column!(fx, entity_type) do
    {:ok, table} = Letflow.TenantProvisioning.table_name_for_entity_type(entity_type)
    Repo.query!(~s(ALTER TABLE "#{fx.schema_name}"."#{table}" DROP COLUMN "scope_node"))
    :ok
  end
end
