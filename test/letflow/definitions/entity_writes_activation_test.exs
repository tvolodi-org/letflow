defmodule Letflow.Definitions.EntityWritesActivationTest do
  @moduledoc """
  GH #2587 / REQ-499 PR B1 (design `lib/letflow/design/gh2587-req499-pr-b-human-task-writes.md`
  5.3, 6, 6.3; tests B-1, B-12 activation half, B-13 recording half, B-16, CO-6): a HUMAN_TASK
  node's declared `entity_writes` are validated at EVERY activation path (`activate/2`, version
  rollback, promotion apply) and refused with `:entity_writes_invalid`, every violation
  reported at once as `%{node_id, index, code}`. A refusal writes nothing.

  `Definitions.check_entity_writes/3` is exercised directly for the code table (it is the one
  function the three paths share) and the three paths are then driven end to end.

  `async: false`: tenant provisioning switches the sandbox to `:auto`; the scope-predicate
  seam is application env, set per test and restored in `on_exit`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Audit.Entry
  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.Promotion
  alias Letflow.Definitions.PromotionDigest
  alias Letflow.Definitions.PromotionReview
  alias Letflow.Entities.Definitions, as: EntityDefinitions
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Entities.EventTypes
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Entities.StepWrites
  alias Letflow.Identity.User
  alias Letflow.Modules.FixtureManaged
  alias Letflow.TenantFixture

  # ── helpers ─────────────────────────────────────────────────────────────────────────────────

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp user!(schema, status \\ :active) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "gh2587-b1-#{Ecto.UUID.generate()}",
      display_name: "GH-2587 B1 Test User",
      email: "gh2587-b1-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: status,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema)
  end

  # A tenant with seeded event types, a few entity types and an active user.
  defp tenant!(slug_prefix) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)
    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)
    schema = tenant.schema_name

    type!(schema, "stock_move")
    type!(schema, "plain_type", %{writable_by_process: false})
    type!(schema, "mutable_type", %{append_only: false})
    type!(schema, "catalog_item", %{writable_by_process: false}, FixtureManaged)

    # created, never activated
    {:ok, _row} =
      EntityDefinitions.create_definition(
        %{definition: type_definition("draft_type", %{}), created_by: Ecto.UUID.generate()},
        schema
      )

    user = user!(schema)
    Map.merge(tenant, %{schema: schema, user: user})
  end

  defp type_definition(name, extra) do
    Map.merge(
      %{
        name: name,
        display_name: name,
        fields: [%{name: "label", type: :string}, %{name: "qty", type: :integer}],
        writable_by_process: true,
        append_only: true
      },
      extra
    )
  end

  defp type!(schema, name, extra \\ %{}, owner \\ :tenant) do
    {:ok, row} =
      EntityDefinitions.create_definition(
        %{definition: type_definition(name, extra), created_by: Ecto.UUID.generate()},
        schema,
        if(owner == :tenant, do: :tenant, else: ManagedTypes.module_owner(owner))
      )

    {:ok, _} =
      EntityDefinitions.activate_definition(row.name, Ecto.UUID.generate(), "go-live", schema)

    row
  end

  defp activator(user, roles \\ ["TENANT_ADMIN"]) do
    Activator.from_auth_context(%{user_id: user.id, roles: roles}, false)
  end

  defp trivial_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
    }
  end

  defp line(type, extra \\ %{}) do
    Map.merge(
      %{"op" => "create", "entity_type" => type, "fields" => %{"label" => %{"const" => "x"}}},
      extra
    )
  end

  # START -> ht (HUMAN_TASK carrying `lines`) -> END. GH #2587 PR C1: `node_type` :SERVICE_TASK
  # swaps in an HTTP service node with the SAME id `ht`, so every expected `v/3` is unchanged.
  defp graph(lines, node_extra \\ %{}, node_type \\ :HUMAN_TASK) do
    attributes =
      case node_type do
        :HUMAN_TASK ->
          %{"role" => "REVIEWER", "entity_writes" => lines}

        :SERVICE_TASK ->
          %{
            "endpoint" => "https://example.test/svc",
            "method" => "POST",
            "entity_writes" => lines
          }
      end

    node =
      Map.merge(
        %{"id" => "ht", "node_type" => Atom.to_string(node_type), "attributes" => attributes},
        node_extra
      )

    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        node,
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "ht"},
        %{"id" => "e2", "source" => "ht", "target" => "end"}
      ]
    }
  end

  defp check(t, lines, activator \\ :default) do
    activator = if activator == :default, do: activator(t.user), else: activator
    node_type = Map.get(t, :node_type, :HUMAN_TASK)
    Definitions.check_entity_writes(%{graph: graph(lines, %{}, node_type)}, t.schema, activator)
  end

  defp codes({:error, {:entity_writes_invalid, violations}}), do: violations
  defp codes(other), do: other

  defp v(index, code, node_id \\ "ht"), do: %{node_id: node_id, index: index, code: code}

  defp raw_definition!(schema, name, version, graph, status, extra \\ %{}) do
    row =
      %ProcessDefinition{}
      |> ProcessDefinition.create_changeset(%{
        name: name,
        version: version,
        graph: graph,
        created_by: Ecto.UUID.generate()
      })
      |> Repo.insert!(prefix: schema)

    {1, _} =
      from(d in ProcessDefinition, where: d.id == ^row.id)
      |> Repo.update_all([set: [{:status, status} | Map.to_list(extra)]], prefix: schema)

    row
  end

  defp row(schema, id), do: Repo.get!(ProcessDefinition, id, prefix: schema)

  defp with_env(key, value) do
    previous = Application.fetch_env(:letflow, key)
    Application.put_env(:letflow, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:letflow, key, old)
        :error -> Application.delete_env(:letflow, key)
      end
    end)
  end

  setup ctx do
    %{t: Map.put(tenant!("gh2587-b1-act"), :node_type, Map.get(ctx, :node_type, :HUMAN_TASK))}
  end

  # ── B-1: one case per code, at the exact {node_id, index} ───────────────────────────────────

  describe "validation codes (execution is enabled by activation validation alone, B2)" do
    test "the B1 execution seam is gone: no function, no env key" do
      refute function_exported?(StepWrites, :execution_enabled?, 0)
      assert Application.get_env(:letflow, :entity_writes_execution_enabled, :unset) == :unset
    end

    test "a graph without entity_writes (absent, nil, []) needs no activator", %{t: t} do
      for attrs <- [
            %{"role" => "R"},
            %{"role" => "R", "entity_writes" => nil},
            %{"role" => "R", "entity_writes" => []}
          ] do
        g = graph([]) |> put_in(["nodes", Access.at(1), "attributes"], attrs)
        assert Definitions.check_entity_writes(%{graph: g}, t.schema, nil) == :ok
      end
    end

    test "a fully valid definition passes", %{t: t} do
      assert check(t, [line("stock_move"), line("stock_move")]) == :ok
    end
  end

  # GH #2587 PR C1 (C-7): the whole B 6.2 code table is asserted for BOTH node types, at the exact
  # {node_id, index}.
  for node_type <- [:HUMAN_TASK, :SERVICE_TASK] do
    describe "validation codes (#{node_type})" do
      @describetag node_type: node_type

      test "unknown, draft-only and absent types are :entity_type_not_found", %{t: t} do
        assert codes(check(t, [line("ghost"), line("draft_type")])) ==
                 [v(0, :entity_type_not_found), v(1, :entity_type_not_found)]
      end

      test "a type without the flag", %{t: t} do
        assert codes(check(t, [line("plain_type")])) == [
                 v(0, :entity_type_not_writable_by_process)
               ]
      end

      test "a managed type (B-12, activation half)", %{t: t} do
        assert codes(check(t, [line("catalog_item")])) == [v(0, :entity_type_managed)]
      end

      test "a type that is not append-only", %{t: t} do
        assert codes(check(t, [line("mutable_type")])) == [v(0, :entity_type_not_append_only)]
      end

      test "update and delete lines, record and expected", %{t: t} do
        assert codes(
                 check(t, [
                   line("stock_move", %{"op" => "update", "record" => %{"var" => "x"}}),
                   line("stock_move", %{"op" => "delete"}),
                   line("stock_move", %{"expected" => 3})
                 ])
               ) == [
                 v(0, :entity_write_op_unsupported),
                 v(0, :entity_write_record_not_allowed),
                 v(1, :entity_write_op_unsupported),
                 v(2, :entity_write_expected_not_allowed)
               ]
      end

      test "an unknown field and an unknown line key", %{t: t} do
        assert codes(
                 check(t, [
                   line("stock_move", %{"fields" => %{"nope" => %{"const" => 1}}}),
                   line("stock_move", %{"extra" => true})
                 ])
               ) == [v(0, :entity_write_field_unknown), v(1, :entity_write_unknown_key)]
      end

      test "field sources: malformed and _sys references (B-16)", %{t: t} do
        bad = [
          %{"label" => "plain"},
          %{"label" => %{"var" => ""}},
          %{"label" => %{"var" => "a", "const" => 1}},
          %{"label" => %{"other" => 1}}
        ]

        for fields <- bad do
          assert codes(check(t, [line("stock_move", %{"fields" => fields})])) ==
                   [v(0, :entity_write_field_source_invalid)],
                 inspect(fields)
        end

        assert codes(
                 check(t, [line("stock_move", %{"fields" => %{"label" => %{"var" => "_sys.r"}}})])
               ) ==
                 [v(0, :entity_write_sys_reference)]

        assert codes(
                 check(t, [line("stock_move", %{"fields" => %{"label" => %{"var" => "_sys"}}})])
               ) ==
                 [v(0, :entity_write_sys_reference)]

        assert check(t, [line("stock_move", %{"fields" => %{"label" => %{"var" => "customer"}}})]) ==
                 :ok
      end

      test "a line that is not a map", %{t: t} do
        assert codes(check(t, ["stock_move", 5, nil])) == [
                 v(0, :entity_write_line_malformed),
                 v(1, :entity_write_line_malformed),
                 v(2, :entity_write_line_malformed)
               ]
      end

      test "more than 20 lines: the first excess index is reported", %{t: t} do
        lines = for _ <- 1..21, do: line("stock_move")
        assert codes(check(t, lines)) == [v(20, :entity_writes_too_many_lines)]
        assert check(t, Enum.take(lines, 20)) == :ok
      end

      test "all defects of one line are reported together, in deterministic order", %{t: t} do
        lines = [
          line("mutable_type", %{
            "op" => "delete",
            "fields" => %{"nope" => %{"const" => 1}},
            "output_record_id_var" => "plain"
          })
        ]

        expected = [
          v(0, :entity_type_not_append_only),
          v(0, :entity_write_field_unknown),
          v(0, :entity_write_op_unsupported),
          v(0, :entity_write_output_var_shape)
        ]

        assert codes(check(t, lines)) == expected
        assert codes(check(t, lines)) == expected
      end

      test "scoped type and scope column seam (D-B.18): vacuous by default, live with a key list",
           %{t: t} do
        scoped = type!(t.schema, "scoped_thing")

        from(e in EntityDefinition, where: e.id == ^scoped.id)
        |> Repo.update_all(
          [
            set: [
              definition_json:
                Map.merge(scoped.definition_json, %{
                  "scope_node" => true,
                  "fields" => [
                    %{"name" => "label", "type" => "string", "scope_node" => true},
                    %{"name" => "qty", "type" => "integer"}
                  ]
                })
            ]
          ],
          prefix: t.schema
        )

        # default: empty key list, so both predicates are false
        assert check(t, [line("scoped_thing")]) == :ok

        with_env(:entity_writes_scope_keys, ["scope_node"])

        assert codes(check(t, [line("scoped_thing")])) ==
                 [v(0, :entity_type_scoped), v(0, :entity_write_field_scope_column)]

        assert codes(check(t, [line("scoped_thing", %{"fields" => %{"qty" => %{"const" => 1}}})])) ==
                 [v(0, :entity_type_scoped)]
      end
    end
  end

  describe "output_record_id_var (CO-6)" do
    test "only _sys.<one segment> with both keys within 160 bytes", %{t: t} do
      for ok <- ["_sys.r", "_sys.line_0", "_sys." <> String.duplicate("a", 151)] do
        assert check(t, [line("stock_move", %{"output_record_id_var" => ok})]) == :ok, ok
      end

      for bad <- [
            "_sys.a.b",
            "_sys.a.seq",
            "_sys.",
            "_sys",
            "x",
            "r",
            "_sys.a-b",
            "_sys." <> String.duplicate("a", 152),
            5,
            %{}
          ] do
        assert codes(check(t, [line("stock_move", %{"output_record_id_var" => bad})])) ==
                 [v(0, :entity_write_output_var_shape)],
               inspect(bad)
      end
    end

    test "a duplicate on two lines of a node, or on another node", %{t: t} do
      same = %{"output_record_id_var" => "_sys.r"}

      assert codes(check(t, [line("stock_move", same), line("stock_move", same)])) ==
               [v(1, :entity_write_output_var_duplicate)]

      two_nodes = %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{
            "id" => "a",
            "node_type" => "HUMAN_TASK",
            "attributes" => %{"entity_writes" => [line("stock_move", same)]}
          },
          %{
            "id" => "b",
            "node_type" => "HUMAN_TASK",
            "attributes" => %{"entity_writes" => [line("stock_move", same)]}
          },
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => []
      }

      assert codes(
               Definitions.check_entity_writes(%{graph: two_nodes}, t.schema, activator(t.user))
             ) ==
               [
                 v(0, :entity_write_output_var_duplicate, "a"),
                 v(0, :entity_write_output_var_duplicate, "b")
               ]
    end

    test "a name the graph pre-seeds from a form property or required_outputs", %{t: t} do
      var = %{"output_record_id_var" => "_sys.r"}

      g = graph([line("stock_move", var)])
      form = %{"form_schema" => %{"properties" => %{"_sys.r" => %{"type" => "string"}}}}
      g = update_in(g, ["nodes", Access.at(1), "attributes"], &Map.merge(&1, form))

      assert codes(Definitions.check_entity_writes(%{graph: g}, t.schema, activator(t.user))) ==
               [v(0, :entity_write_output_var_preseeded)]

      g2 =
        update_in(graph([line("stock_move", var)]), ["nodes", Access.at(1), "attributes"], fn a ->
          Map.put(a, "required_outputs", ["_sys.r"])
        end)

      assert codes(Definitions.check_entity_writes(%{graph: g2}, t.schema, activator(t.user))) ==
               [v(0, :entity_write_output_var_preseeded)]
    end

    test "a name registered in variable_schemas for the definition row", %{t: t} do
      row =
        raw_definition!(
          t.schema,
          unique("preseed"),
          "1",
          graph([line("stock_move", %{"output_record_id_var" => "_sys.r"})]),
          :draft
        )

      %Letflow.Engine.VariableSchema{}
      |> Ecto.Changeset.change(%{
        definition_id: row.id,
        variable_key: "_sys.r",
        json_schema: %{"type" => "string"}
      })
      |> Repo.insert!(prefix: t.schema)

      assert codes(Definitions.check_entity_writes(row, t.schema, activator(t.user))) ==
               [v(0, :entity_write_output_var_preseeded)]
    end
  end

  describe "node level" do
    test "entity_writes that is not a list", %{t: t} do
      g = graph("x")

      assert codes(Definitions.check_entity_writes(%{graph: g}, t.schema, activator(t.user))) ==
               [v(0, :entity_writes_not_a_list)]
    end

    test "a graph that does not parse", %{t: t} do
      assert Definitions.check_entity_writes(%{graph: %{"nodes" => "x"}}, t.schema, nil) ==
               {:error, :graph_structure_invalid}
    end
  end

  # ── GH #2587 PR C1 (design 6, D-C.12, C-7): the fence accepts SERVICE_TASK ───────────────────

  describe "SERVICE_TASK nodes (C-7)" do
    defp svc_graph(lines, attributes \\ %{}, id \\ "svc") do
      %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{
            "id" => id,
            "node_type" => "SERVICE_TASK",
            "attributes" => Map.merge(svc_base_attributes(lines, attributes), attributes)
          },
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => [
          %{"id" => "e1", "source" => "start", "target" => id},
          %{"id" => "e2", "source" => id, "target" => "end"}
        ]
      }
    end

    # A script-bound node (`script_key`) carries NO endpoint / method, as in a real definition.
    defp svc_base_attributes(lines, %{"script_key" => _}), do: %{"entity_writes" => lines}

    defp svc_base_attributes(lines, _attributes) do
      %{
        "endpoint" => "https://example.test/svc",
        "method" => "POST",
        "entity_writes" => lines
      }
    end

    defp svc_check(t, lines, attributes \\ %{}, activator \\ :default) do
      activator = if activator == :default, do: activator(t.user), else: activator
      Definitions.check_entity_writes(%{graph: svc_graph(lines, attributes)}, t.schema, activator)
    end

    test "a valid HTTP-route SERVICE_TASK node passes", %{t: t} do
      assert svc_check(t, [line("stock_move"), line("stock_move")]) == :ok
    end

    test "a script-bound SERVICE_TASK node (script_key) passes: both routes compose lines",
         %{t: t} do
      assert svc_check(t, [line("stock_move")], %{"script_key" => "some_script"}) == :ok

      assert codes(svc_check(t, [line("ghost")], %{"script_key" => "some_script"})) ==
               [v(0, :entity_type_not_found, "svc")]
    end

    test "every violation is reported at the exact {svc, index}", %{t: t} do
      assert codes(
               svc_check(t, [
                 line("stock_move"),
                 line("plain_type"),
                 line("catalog_item"),
                 line("mutable_type"),
                 line("stock_move", %{"op" => "delete"}),
                 line("stock_move", %{"fields" => %{"label" => %{"var" => "_sys.r"}}})
               ])
             ) == [
               v(1, :entity_type_not_writable_by_process, "svc"),
               v(2, :entity_type_managed, "svc"),
               v(3, :entity_type_not_append_only, "svc"),
               v(4, :entity_write_op_unsupported, "svc"),
               v(5, :entity_write_sys_reference, "svc")
             ]
    end

    test "a missing, under-privileged or inactive activator is :entity_write_activator_required",
         %{t: t} do
      refused = [v(0, :entity_write_activator_required, "svc")]
      lines = [line("stock_move")]

      assert codes(svc_check(t, lines, %{}, nil)) == refused
      assert codes(svc_check(t, lines, %{}, activator(t.user, ["PROCESS_DESIGNER"]))) == refused

      inactive = user!(t.schema, :inactive)
      assert codes(svc_check(t, lines, %{}, activator(inactive))) == refused
    end

    test "entity_writes that is not a list is refused at the SERVICE node", %{t: t} do
      assert codes(svc_check(t, "x")) == [v(0, :entity_writes_not_a_list, "svc")]
    end

    test "an output_record_id_var duplicated across a HUMAN_TASK and a SERVICE_TASK node",
         %{t: t} do
      same = %{"output_record_id_var" => "_sys.r"}

      g = %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{
            "id" => "a",
            "node_type" => "HUMAN_TASK",
            "attributes" => %{"entity_writes" => [line("stock_move", same)]}
          },
          %{
            "id" => "b",
            "node_type" => "SERVICE_TASK",
            "attributes" => %{
              "endpoint" => "https://example.test/svc",
              "entity_writes" => [line("stock_move", same)]
            }
          },
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => []
      }

      assert codes(Definitions.check_entity_writes(%{graph: g}, t.schema, activator(t.user))) ==
               [
                 v(0, :entity_write_output_var_duplicate, "a"),
                 v(0, :entity_write_output_var_duplicate, "b")
               ]

      # control: distinct variables across the HUMAN and the SERVICE node are accepted
      distinct =
        g
        |> update_in(["nodes", Access.at(1), "attributes", "entity_writes"], fn _ ->
          [line("stock_move", %{"output_record_id_var" => "_sys.a"})]
        end)
        |> update_in(["nodes", Access.at(2), "attributes", "entity_writes"], fn _ ->
          [line("stock_move", %{"output_record_id_var" => "_sys.b"})]
        end)

      assert Definitions.check_entity_writes(%{graph: distinct}, t.schema, activator(t.user)) ==
               :ok
    end

    test "module_writes on a SERVICE_TASK node is still refused at activation (R3)", %{t: t} do
      mline = %{"module" => "ledger", "handler" => "post_entry", "args" => %{}}

      assert codes(svc_check(t, [], %{"module_writes" => [mline]})) ==
               [v(0, :module_writes_node_type_not_supported, "svc")]

      # together with entity_writes: the entity lines pass, the module_writes line is refused
      assert codes(svc_check(t, [line("stock_move")], %{"module_writes" => [mline]})) ==
               [v(0, :module_writes_node_type_not_supported, "svc")]
    end

    test "a node type other than HUMAN_TASK and SERVICE_TASK is still refused", %{t: t} do
      for type <- ["SUB_PROCESS", "EXCLUSIVE_GATEWAY", "PARALLEL_GATEWAY", "TIMER"] do
        g = %{
          "nodes" => [
            %{"id" => "start", "node_type" => "START"},
            %{
              "id" => "n",
              "node_type" => type,
              "attributes" => %{"entity_writes" => [line("stock_move")]}
            },
            %{"id" => "end", "node_type" => "END"}
          ],
          "edges" => []
        }

        assert codes(Definitions.check_entity_writes(%{graph: g}, t.schema, activator(t.user))) ==
                 [v(0, :entity_writes_node_type_not_supported, "n")],
               type
      end
    end

    test "activate/2 accepts it and records activated_by with the SERVICE node's pairs",
         %{t: t} do
      draft =
        raw_definition!(t.schema, unique("svc-act"), "1", svc_graph([line("stock_move")]), :draft)

      assert {:error,
              {:entity_writes_invalid,
               [%{node_id: "svc", code: :entity_write_activator_required}]}} =
               Definitions.activate(draft.id, prefix: t.schema)

      assert %{status: :draft, activated_by: nil} = row(t.schema, draft.id)

      assert {:ok, %{already_active: false}} =
               Definitions.activate(draft.id, prefix: t.schema, activator: activator(t.user))

      user_id = t.user.id

      assert %{
               status: :active,
               activated_by: %{
                 "user_id" => ^user_id,
                 "authorized" => [%{"entity_type" => "stock_move", "op" => "create"}]
               }
             } = row(t.schema, draft.id)
    end

    test "activate/2 reports a violation at the exact {svc, index} and activates nothing",
         %{t: t} do
      draft =
        raw_definition!(
          t.schema,
          unique("svc-act"),
          "1",
          svc_graph([line("stock_move"), line("ghost")]),
          :draft
        )

      assert {:error,
              {:entity_writes_invalid,
               [%{node_id: "svc", index: 1, code: :entity_type_not_found}]}} =
               Definitions.activate(draft.id, prefix: t.schema, activator: activator(t.user))

      assert %{status: :draft, activated_by: nil} = row(t.schema, draft.id)
    end

    test "version rollback accepts it, re-records the NEW activator; a refusal leaves v2 active",
         %{t: t} do
      key = unique("svc-rb")
      old_authority = %{"user_id" => Ecto.UUID.generate(), "roles" => []}

      v1 =
        raw_definition!(t.schema, key, "1", svc_graph([line("stock_move")]), :deprecated, %{
          activated_by: old_authority
        })

      v2 = raw_definition!(t.schema, key, "2", trivial_graph(), :active)

      assert {:error,
              {:entity_writes_invalid,
               [%{node_id: "svc", code: :entity_write_activator_required}]}} =
               rollback(t.schema, key, nil)

      assert %{status: :active} = row(t.schema, v2.id)
      assert %{status: :deprecated, activated_by: ^old_authority} = row(t.schema, v1.id)

      assert {:ok, %{version: "1"}} = rollback(t.schema, key, activator(t.user))
      assert %{status: :active, activated_by: %{"user_id" => user_id}} = row(t.schema, v1.id)
      assert user_id == t.user.id
    end

    test "promotion apply accepts it with a target-tenant activator and refuses without one",
         %{t: t} do
      source = tenant!("gh2587-c1-src")
      g = svc_graph([line("stock_move")])

      assert {{:error,
               {:entity_writes_invalid,
                [%{node_id: "svc", code: :entity_write_activator_required}]}}, []} =
               promote(source, t, g, nil)

      assert {{:ok, _}, [%{status: :active, activated_by: authority}]} =
               promote(source, t, g, activator(t.user))

      assert authority["user_id"] == t.user.id
      assert authority["authorized"] == [%{"entity_type" => "stock_move", "op" => "create"}]

      # a type absent in the TARGET is refused there, at the SERVICE node
      type!(source.schema, "source_only")

      assert {{:error,
               {:entity_writes_invalid, [%{node_id: "svc", code: :entity_type_not_found}]}}, []} =
               promote(source, t, svc_graph([line("source_only")]), activator(t.user))
    end
  end

  describe "activator authority" do
    test "no activator, an activator without :EntitiesRecordsWrite, an inactive user, an absent user row",
         %{t: t} do
      refused = [v(0, :entity_write_activator_required)]
      lines = [line("stock_move")]

      assert codes(check(t, lines, nil)) == refused

      designer = activator(t.user, ["PROCESS_DESIGNER"])
      refute designer.entities_records_write?
      assert codes(check(t, lines, designer)) == refused

      inactive = user!(t.schema, :inactive)
      assert codes(check(t, lines, activator(inactive))) == refused

      ghost = %{activator(t.user) | user_id: Ecto.UUID.generate()}
      assert codes(check(t, lines, ghost)) == refused

      assert check(t, lines) == :ok
    end

    test "from_auth_context/2 is pure in its arguments; PLATFORM_ADMIN is dropped outside the platform tenant" do
      id = Ecto.UUID.generate()
      auth = %{user_id: id, roles: ["PLATFORM_ADMIN", "TENANT_ADMIN"]}

      outside = Activator.from_auth_context(auth, false)
      assert outside.roles == ["TENANT_ADMIN"]
      assert "EntitiesRecordsWrite" in outside.permissions

      inside = Activator.from_auth_context(auth, true)
      assert inside.roles == ["PLATFORM_ADMIN", "TENANT_ADMIN"]

      assert Activator.from_auth_context(%{roles: []}, false) == nil
      assert Activator.from_auth_context(nil, false) == nil
    end
  end

  # ── the three activation paths ──────────────────────────────────────────────────────────────

  describe "activate/2 " do
    test "records activated_by; refusal leaves the draft untouched and writes no audit", %{t: t} do
      graph = graph([line("stock_move"), line("stock_move")])
      draft = raw_definition!(t.schema, unique("act"), "1", graph, :draft)

      assert {:error, {:entity_writes_invalid, [%{code: :entity_write_activator_required} | _]}} =
               Definitions.activate(draft.id, prefix: t.schema)

      assert %{status: :draft, activated_by: nil} = row(t.schema, draft.id)

      assert [] =
               Repo.all(
                 from(e in Entry,
                   where: e.action == "definition.activate" and e.resource_id == ^draft.id
                 ),
                 prefix: t.schema
               )

      assert {:ok, %{already_active: false}} =
               Definitions.activate(draft.id, prefix: t.schema, activator: activator(t.user))

      stored = row(t.schema, draft.id)
      assert stored.status == :active

      assert %{
               "user_id" => user_id,
               "roles" => ["TENANT_ADMIN"],
               "permissions" => ["DefinitionsActivate", "EntitiesRecordsWrite"],
               "authorized" => [%{"entity_type" => "stock_move", "op" => "create"}],
               "activated_at" => at
             } = stored.activated_by

      assert user_id == t.user.id
      assert {:ok, _, _} = DateTime.from_iso8601(at)
    end

    test "a graph without lines leaves activated_by NULL even with an activator", %{t: t} do
      draft = raw_definition!(t.schema, unique("act"), "1", trivial_graph(), :draft)

      assert {:ok, _} =
               Definitions.activate(draft.id, prefix: t.schema, activator: activator(t.user))

      assert %{status: :active, activated_by: nil} = row(t.schema, draft.id)
    end
  end

  describe "version rollback " do
    defp rollback(schema, key, activator) do
      Definitions.rollback_definition_version(key, "1", Ecto.UUID.generate(),
        prefix: schema,
        activator: activator,
        permission_checker: fn _actor, _tenant -> true end,
        event_appender: fn _attrs, _prefix -> {:ok, %{event_id: Ecto.UUID.generate()}} end
      )
    end

    test "re-records the NEW activator; a refusal leaves v2 active", %{t: t} do
      key = unique("rb")
      old_authority = %{"user_id" => Ecto.UUID.generate(), "roles" => []}

      v1 =
        raw_definition!(t.schema, key, "1", graph([line("stock_move")]), :deprecated, %{
          activated_by: old_authority
        })

      v2 = raw_definition!(t.schema, key, "2", trivial_graph(), :active)

      assert {:error, {:entity_writes_invalid, [%{code: :entity_write_activator_required}]}} =
               rollback(t.schema, key, nil)

      assert %{status: :active} = row(t.schema, v2.id)
      assert %{status: :deprecated, activated_by: ^old_authority} = row(t.schema, v1.id)

      assert {:ok, %{version: "1"}} = rollback(t.schema, key, activator(t.user))
      assert %{status: :active, activated_by: %{"user_id" => user_id}} = row(t.schema, v1.id)
      assert user_id == t.user.id
      assert %{status: :deprecated} = row(t.schema, v2.id)
    end

    test "a graph without lines stays NULL", %{t: t} do
      key = unique("rb")
      v1 = raw_definition!(t.schema, key, "1", trivial_graph(), :deprecated)
      raw_definition!(t.schema, key, "2", trivial_graph(), :active)

      assert {:ok, _} = rollback(t.schema, key, activator(t.user))
      assert %{status: :active, activated_by: nil} = row(t.schema, v1.id)
    end
  end

  describe "promotion apply " do
    setup do
      %{source: tenant!("gh2587-b1-src")}
    end

    defp promote(source, target, graph, activator) do
      key = unique("promo")
      source_def = raw_definition!(source.schema, key, "1.0.0", graph, :active)

      plan = %{
        source_tenant_id: source.tenant_id,
        target_tenant_id: target.tenant_id,
        process_key: key,
        source_definition_id: source_def.id,
        target_definition_id: nil,
        base_version: nil,
        entries: []
      }

      review =
        struct(PromotionReview, %{
          id: Ecto.UUID.generate(),
          plan_digest: PromotionDigest.compute_plan_digest(plan),
          def_id: key,
          serialised_plan: Jason.encode!(plan),
          requested_by: Ecto.UUID.generate(),
          status: :approved,
          row_version: 2
        })

      result =
        Promotion.promote_definition(Ecto.UUID.generate(), review,
          activator: activator,
          permission_checker: fn _actor, _tenant -> true end,
          event_appender: fn _attrs, _prefix -> {:ok, %{event_id: Ecto.UUID.generate()}} end
        )

      {result,
       Repo.all(from(d in ProcessDefinition, where: d.name == ^key), prefix: target.schema)}
    end

    test "refused without an activator; recorded with one (target tenant's user)",
         %{t: t, source: source} do
      graph = graph([line("stock_move")])

      assert {{:error, {:entity_writes_invalid, [%{code: :entity_write_activator_required}]}}, []} =
               promote(source, t, graph, nil)

      assert {{:ok, _}, [%{status: :active, activated_by: authority}]} =
               promote(source, t, graph, activator(t.user))

      assert authority["user_id"] == t.user.id

      assert authority["authorized"] == [%{"entity_type" => "stock_move", "op" => "create"}]
    end

    test "a type absent in the TARGET tenant is refused there", %{t: t, source: source} do
      # the target (t) has no such type; the source's own types are irrelevant
      graph = graph([line("source_only")])
      type!(source.schema, "source_only")

      assert {{:error, {:entity_writes_invalid, [%{code: :entity_type_not_found}]}}, []} =
               promote(source, t, graph, activator(t.user))
    end
  end

  # ── review follow-ups: input robustness and type lifecycle (TDV F4/F7/F8) ───────────────────

  describe "input robustness and type lifecycle " do
    test "non-map fields, an atom-key line, a 65-byte type name, missing or upper-case op",
         %{t: t} do
      assert codes(check(t, [line("stock_move", %{"fields" => "label"})])) ==
               [v(0, :entity_write_field_source_invalid)]

      assert codes(check(t, [%{op: "create", entity_type: "stock_move"}])) ==
               [v(0, :entity_write_line_malformed)]

      assert codes(check(t, [line(String.duplicate("a", 65))])) ==
               [v(0, :entity_type_name_invalid)]

      assert codes(check(t, [line(String.duplicate("a", 64))])) ==
               [v(0, :entity_type_not_found)]

      assert codes(check(t, [%{"entity_type" => "stock_move"}])) ==
               [v(0, :entity_write_op_unsupported)]

      assert codes(check(t, [line("stock_move", %{"op" => "CREATE"})])) ==
               [v(0, :entity_write_op_unsupported)]
    end

    test "a type definition with no append_only key is not append-only", %{t: t} do
      definition = Map.delete(type_definition("no_flag_type", %{}), :append_only)

      {:ok, row} =
        EntityDefinitions.create_definition(
          %{definition: definition, created_by: Ecto.UUID.generate()},
          t.schema
        )

      {:ok, _} =
        EntityDefinitions.activate_definition(row.name, Ecto.UUID.generate(), "go", t.schema)

      refute Map.has_key?(row.definition_json, "append_only")

      assert codes(check(t, [line("no_flag_type")])) == [v(0, :entity_type_not_append_only)]
    end

    test "a once-active type whose activation is gone is not found", %{t: t} do
      type!(t.schema, "retired_type")
      assert check(t, [line("retired_type")]) == :ok

      Repo.delete_all(
        from(a in Letflow.Repository.Activation, where: a.artifact_name == "retired_type"),
        prefix: t.schema
      )

      assert codes(check(t, [line("retired_type")])) == [v(0, :entity_type_not_found)]
    end

    test "a node type that is neither HUMAN_TASK nor SERVICE_TASK is refused", %{t: t} do
      g = %{
        "nodes" => [
          %{"id" => "start", "node_type" => "START"},
          %{
            "id" => "sp",
            "node_type" => "SUB_PROCESS",
            "attributes" => %{"entity_writes" => [line("stock_move")]}
          },
          %{"id" => "end", "node_type" => "END"}
        ],
        "edges" => []
      }

      assert codes(Definitions.check_entity_writes(%{graph: g}, t.schema, activator(t.user))) ==
               [v(0, :entity_writes_node_type_not_supported, "sp")]
    end

    test "a refusal on activate/2 leaves the prior ACTIVE version active", %{t: t} do
      name = unique("prior")
      prior = raw_definition!(t.schema, name, "1", trivial_graph(), :active)
      draft = raw_definition!(t.schema, name, "2", graph([line("ghost")]), :draft)

      assert {:error, {:entity_writes_invalid, [%{code: :entity_type_not_found}]}} =
               Definitions.activate(draft.id, prefix: t.schema, activator: activator(t.user))

      assert %{status: :active} = row(t.schema, prior.id)
      assert %{status: :draft} = row(t.schema, draft.id)
    end
  end

  # ── activated_by clearing and no-copy (TDV F2) ──────────────────────────────────────────────

  describe "a stale or forged activated_by never survives re-activation " do
    setup do
      %{forged: %{"user_id" => Ecto.UUID.generate(), "roles" => ["PLATFORM_ADMIN"]}}
    end

    test "activate/2 of a no-lines draft clears a planted value", %{t: t, forged: forged} do
      draft =
        raw_definition!(t.schema, unique("clr"), "1", trivial_graph(), :draft, %{
          activated_by: forged
        })

      assert %{activated_by: ^forged} = row(t.schema, draft.id)
      assert {:ok, _} = Definitions.activate(draft.id, prefix: t.schema)
      assert %{status: :active, activated_by: nil} = row(t.schema, draft.id)
    end

    test "rollback to a no-lines version clears a planted value", %{t: t, forged: forged} do
      key = unique("clr-rb")

      v1 =
        raw_definition!(t.schema, key, "1", trivial_graph(), :deprecated, %{activated_by: forged})

      raw_definition!(t.schema, key, "2", trivial_graph(), :active)

      assert {:ok, _} =
               Definitions.rollback_definition_version(key, "1", Ecto.UUID.generate(),
                 prefix: t.schema,
                 activator: activator(t.user),
                 permission_checker: fn _a, _t -> true end,
                 event_appender: fn _a, _p -> {:ok, %{event_id: Ecto.UUID.generate()}} end
               )

      assert %{status: :active, activated_by: nil} = row(t.schema, v1.id)
    end

    test "promotion never copies the source row's activated_by", %{t: t, forged: forged} do
      source = tenant!("gh2587-b1-clr-src")

      for {g, expect_user} <- [{trivial_graph(), nil}, {graph([line("stock_move")]), t.user.id}] do
        key = unique("clr-promo")
        src = raw_definition!(source.schema, key, "1.0.0", g, :active, %{activated_by: forged})

        plan = %{
          source_tenant_id: source.tenant_id,
          target_tenant_id: t.tenant_id,
          process_key: key,
          source_definition_id: src.id,
          target_definition_id: nil,
          base_version: nil,
          entries: []
        }

        review =
          struct(PromotionReview, %{
            id: Ecto.UUID.generate(),
            plan_digest: PromotionDigest.compute_plan_digest(plan),
            def_id: key,
            serialised_plan: Jason.encode!(plan),
            requested_by: Ecto.UUID.generate(),
            status: :approved,
            row_version: 2
          })

        assert {:ok, _} =
                 Promotion.promote_definition(Ecto.UUID.generate(), review,
                   activator: activator(t.user),
                   permission_checker: fn _a, _t -> true end,
                   event_appender: fn _a, _p -> {:ok, %{event_id: Ecto.UUID.generate()}} end
                 )

        [target_row] =
          Repo.all(from(d in ProcessDefinition, where: d.name == ^key), prefix: t.schema)

        case expect_user do
          nil -> assert target_row.activated_by == nil
          id -> assert %{"user_id" => ^id} = target_row.activated_by
        end

        refute target_row.activated_by == forged
      end
    end
  end
end
