defmodule Letflow.Definitions.ModuleWriteActivationTest do
  @moduledoc """
  GH #2590 / REQ-501 PR R3 (design `lib/letflow/design/gh2590-req501-module-write-handlers.md`
  5.1, 5.2, 11 rows "Unknown/unregistered handler refused at activation", "Stamp required",
  "Hash check at activation", OQ-R3, OQ-R6, OQ-R7): a HUMAN_TASK node's `module_writes` are
  validated at EVERY activation path (`activate/2`, version rollback, promotion apply) and
  refused with `:entity_writes_invalid`, every violation at once as `%{node_id, index, code}`.

  `Definitions.check_entity_writes/3` is exercised directly for the code table (the one
  function the three paths share); the three paths are then driven end to end. A refusal
  writes nothing. Hashes never appear in a violation.

  `async: false`: tenant provisioning switches the sandbox to `:auto`; the module install runs
  DDL.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Definitions.Activator
  alias Letflow.Definitions.OwnerStamp
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.Promotion
  alias Letflow.Definitions.PromotionDigest
  alias Letflow.Definitions.PromotionReview
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Entities.EventTypes
  alias Letflow.EntityWritesFixture, as: Fx
  alias Letflow.Entities.ManagedTypes
  alias Letflow.Identity.User
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.FixtureLedger
  alias Letflow.Modules.Installs
  alias Letflow.Modules.TenantModule
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning.ColumnPromotion

  # ── helpers ─────────────────────────────────────────────────────────────────────────────────

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp user!(schema) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "gh2590-r3-#{Ecto.UUID.generate()}",
      display_name: "GH-2590 R3 Test User",
      email: "gh2590-r3-#{Ecto.UUID.generate()}@example.com",
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema)
  end

  defp tenant!(slug_prefix) do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)

    on_exit(fn ->
      Repo.delete_all(from(i in SolutionPackInstall, where: i.tenant_id == ^tenant.tenant_id))

      Repo.delete_all(
        from(b in SolutionPackArtefactBase, where: b.tenant_id == ^tenant.tenant_id)
      )

      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant.tenant_id))
    end)

    {:ok, _seeded} = EventTypes.seed!(tenant.schema_name)
    Map.merge(tenant, %{schema: tenant.schema_name, user: user!(tenant.schema_name)})
  end

  defp install_ledger!(schema) do
    assert {:ok, %TenantModule{} = tm} =
             Installs.install("fixture_ledger", Ecto.UUID.generate(),
               prefix: schema,
               rationale: "GH 2590 R3 activation test"
             )

    tm
  end

  defp activator(user, roles \\ ["TENANT_ADMIN"]),
    do: Activator.from_auth_context(%{user_id: user.id, roles: roles}, false)

  defp trivial_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
    }
  end

  defp mline(handler \\ "post_entry", extra \\ %{}) do
    Map.merge(
      %{
        "module" => "fixture_ledger",
        "handler" => handler,
        "args" => %{"item" => %{"var" => "item"}, "quantity" => %{"const" => 1}}
      },
      extra
    )
  end

  # the `post_balance_only` handler declares the single required argument `item`
  defp bline, do: mline("post_balance_only", %{"args" => %{"item" => %{"var" => "item"}}})

  # START -> ht (HUMAN_TASK carrying `module_writes`) -> END
  defp graph(module_lines, attrs \\ %{}, node_type \\ "HUMAN_TASK") do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "ht",
          "node_type" => node_type,
          "attributes" =>
            Map.merge(%{"role" => "REVIEWER", "module_writes" => module_lines}, attrs)
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "ht"},
        %{"id" => "e2", "source" => "ht", "target" => "end"}
      ]
    }
  end

  defp owner(overrides \\ %{}),
    do: Map.merge(ManagedTypes.module_owner(FixtureLedger), overrides)

  defp stamped!(schema, graph, owner \\ nil, name \\ nil) do
    assert {:ok, %ProcessDefinition{} = row} =
             Definitions.create_owned(
               %{
                 name: name || unique("gh2590-r3"),
                 version: "1",
                 graph: graph,
                 created_by: Ecto.UUID.generate()
               },
               [prefix: schema],
               owner || owner()
             )

    row
  end

  defp plain!(schema, graph, name \\ nil, version \\ "1") do
    assert {:ok, %ProcessDefinition{} = row} =
             Definitions.create(
               %{
                 name: name || unique("gh2590-r3-plain"),
                 version: version,
                 graph: graph,
                 created_by: Ecto.UUID.generate()
               },
               prefix: schema
             )

    row
  end

  defp check(t, definition, activator \\ :default) do
    activator = if activator == :default, do: activator(t.user), else: activator
    Definitions.check_entity_writes(definition, t.schema, activator)
  end

  defp codes({:error, {:entity_writes_invalid, violations}}), do: violations
  defp codes(other), do: other

  defp v(index, code, node_id \\ "ht"), do: %{node_id: node_id, index: index, code: code}

  defp row(schema, id), do: Repo.get!(ProcessDefinition, id, prefix: schema)

  defp set_installed_hash!(schema, hash) do
    {1, _} =
      Repo.update_all(
        from(m in TenantModule, where: m.module_id == "fixture_ledger"),
        [set: [manifest_hash: hash]],
        prefix: schema
      )
  end

  # A map carrying a valid stamp over `graph` without any database row (the stamp inputs are
  # the compiled manifest's, the body hash is the graph's), for the code table.
  defp stamped_map(graph, overrides \\ %{}) do
    {:ok, manifest_hash} = Catalog.manifest_hash(FixtureLedger)

    Map.merge(
      %{
        graph: graph,
        owner_module: "fixture_ledger",
        owner_module_version: FixtureLedger.manifest().version,
        owner_manifest_hash: manifest_hash,
        owner_body_hash: OwnerStamp.graph_hash(graph)
      },
      overrides
    )
  end

  defp line_codes(t, lines) do
    map = stamped_map(graph(lines))
    codes(check(t, map))
  end

  defp extra_arg do
    %{
      "item" => %{"const" => "a"},
      "quantity" => %{"const" => 1},
      "bogus" => %{"const" => 2}
    }
  end

  # `n` declarative stock_move lines (the type must exist in the tenant)
  defp entity_lines(n) do
    List.duplicate(Fx.line("stock_move", %{"label" => %{"const" => "x"}}), n)
  end

  defp rollback(schema, key, activator) do
    Definitions.rollback_definition_version(key, "1", Ecto.UUID.generate(),
      prefix: schema,
      activator: activator,
      permission_checker: fn _actor, _tenant -> true end,
      event_appender: fn _attrs, _prefix -> {:ok, %{event_id: Ecto.UUID.generate()}} end
    )
  end

  defp deprecate!(schema, id) do
    {1, _} =
      Repo.update_all(
        from(d in ProcessDefinition, where: d.id == ^id),
        [set: [status: :deprecated]],
        prefix: schema
      )
  end

  defp promote(source, target, graph, activator) do
    key = unique("promo")

    source_def =
      %ProcessDefinition{}
      |> ProcessDefinition.create_changeset(%{
        name: key,
        version: "1.0.0",
        graph: graph,
        created_by: Ecto.UUID.generate()
      })
      |> Repo.insert!(prefix: source.schema)

    {1, _} =
      Repo.update_all(
        from(d in ProcessDefinition, where: d.id == ^source_def.id),
        [set: [status: :active]],
        prefix: source.schema
      )

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

    {result, Repo.all(from(d in ProcessDefinition, where: d.name == ^key), prefix: target.schema)}
  end

  setup do
    t = tenant!("gh2590-r3-act")
    %{t: t}
  end

  # ── the code table (check_entity_writes/3) ──────────────────────────────────────────────────

  describe "a legitimate definition" do
    test "a stamped, installed, unchanged definition with a valid line passes", %{t: t} do
      install_ledger!(t.schema)
      g = graph([mline()])
      assert :ok = check(t, stamped!(t.schema, g))
      assert :ok = check(t, stamped!(t.schema, graph([bline()])))
    end

    test "an absent, nil or empty module_writes needs nothing", %{t: t} do
      for attrs <- [%{}, %{"module_writes" => nil}, %{"module_writes" => []}] do
        g = %{
          "nodes" => [
            %{"id" => "start", "node_type" => "START"},
            %{"id" => "ht", "node_type" => "HUMAN_TASK", "attributes" => attrs},
            %{"id" => "end", "node_type" => "END"}
          ],
          "edges" => [
            %{"id" => "e1", "source" => "start", "target" => "ht"},
            %{"id" => "e2", "source" => "ht", "target" => "end"}
          ]
        }

        assert :ok = check(t, %{graph: g}, nil)
      end
    end
  end

  describe "stamp (OQ-R5 / D-R.8)" do
    test "a tenant-created version of the same graph has no stamp", %{t: t} do
      install_ledger!(t.schema)

      assert [v(0, :module_write_stamp_missing)] ==
               codes(check(t, plain!(t.schema, graph([mline()]))))
    end

    test "a plain map without stamp keys is unstamped", %{t: t} do
      install_ledger!(t.schema)
      assert [v(0, :module_write_stamp_missing)] == codes(check(t, %{graph: graph([mline()])}))
    end

    test "a line naming another module than the stamp's", %{t: t} do
      install_ledger!(t.schema)
      line = mline("post_entry", %{"module" => "fixture_ledger_other"})

      assert [v(0, :module_write_stamp_mismatch)] ==
               codes(check(t, stamped!(t.schema, graph([line]))))
    end
  end

  describe "installation, registration, hash and body" do
    test "the module is not installed in this tenant", %{t: t} do
      assert [v(0, :module_write_module_not_installed)] ==
               codes(check(t, stamped!(t.schema, graph([mline()]))))
    end

    test "a handler that is not registered (module compiled in)", %{t: t} do
      install_ledger!(t.schema)

      assert [v(0, :module_write_handler_unknown)] ==
               codes(check(t, stamped!(t.schema, graph([mline("no_such_handler")]))))
    end

    test "a stamp naming a module that is not compiled in", %{t: t} do
      g = graph([mline("post_entry", %{"module" => "ghost"})])

      map =
        stamped_map(g, %{owner_module: "ghost", owner_manifest_hash: String.duplicate("a", 64)})

      assert [
               v(0, :module_write_handler_unknown),
               v(0, :module_write_module_not_installed)
             ] == codes(check(t, map))
    end

    test "the stamp's manifest hash differs from the installed one", %{t: t} do
      install_ledger!(t.schema)
      stale = owner(%{manifest_hash: String.duplicate("c", 64)})

      assert [v(0, :module_write_hash_mismatch)] ==
               codes(check(t, stamped!(t.schema, graph([mline()]), stale)))
    end

    test "OQ-R7: an install with no recorded hash (pre-R2 install) cannot activate a handler caller",
         %{t: t} do
      install_ledger!(t.schema)
      set_installed_hash!(t.schema, nil)

      assert [v(0, :module_write_hash_mismatch)] ==
               codes(check(t, stamped!(t.schema, graph([mline()]))))
    end

    test "OQ-R3: stamp == installed but the compiled manifest differs (strict equality)",
         %{t: t} do
      install_ledger!(t.schema)
      drifted = String.duplicate("d", 64)
      set_installed_hash!(t.schema, drifted)
      row = stamped!(t.schema, graph([mline()]), owner(%{manifest_hash: drifted}))

      assert [v(0, :module_write_hash_mismatch)] == codes(check(t, row))
    end

    test "the graph no longer hashes to the stamp's body hash", %{t: t} do
      install_ledger!(t.schema)
      row = stamped!(t.schema, graph([mline()]))
      edited = %{row | graph: graph([mline(), bline()])}

      assert [v(0, :module_write_body_changed), v(1, :module_write_body_changed)] ==
               codes(check(t, edited))
    end

    test "no violation ever carries a hash", %{t: t} do
      install_ledger!(t.schema)
      stale = owner(%{manifest_hash: String.duplicate("c", 64)})
      result = check(t, stamped!(t.schema, graph([mline()]), stale))

      refute inspect(result) =~ String.duplicate("c", 64)
      {:ok, compiled} = Catalog.manifest_hash(FixtureLedger)
      refute inspect(result) =~ compiled
    end
  end

  describe "line shape and arguments" do
    setup %{t: t} do
      install_ledger!(t.schema)
      :ok
    end

    test "module_writes that is not a list, and a node that is not a HUMAN_TASK", %{t: t} do
      assert [v(0, :module_writes_not_a_list)] ==
               codes(check(t, stamped_map(graph("nope"))))

      assert [v(0, :module_writes_node_type_not_supported)] ==
               codes(check(t, stamped_map(graph([mline()], %{}, "SERVICE_TASK"))))
    end

    test "malformed lines, unknown keys, missing module or handler", %{t: t} do
      assert [v(0, :module_write_line_malformed)] == line_codes(t, ["x"])

      assert [v(0, :module_write_unknown_key)] ==
               line_codes(t, [mline("post_entry", %{"x" => 1})])

      assert [v(0, :module_write_module_missing)] ==
               line_codes(t, [Map.delete(mline(), "module")])

      assert [v(0, :module_write_handler_missing)] ==
               line_codes(t, [Map.put(mline(), "handler", "  ")])
    end

    test "unknown and missing arguments", %{t: t} do
      assert [v(0, :module_write_arg_unknown)] ==
               line_codes(t, [mline("post_entry", %{"args" => extra_arg()})])

      assert [v(0, :module_write_arg_missing)] ==
               line_codes(t, [mline("post_entry", %{"args" => %{"item" => %{"const" => "a"}}})])

      assert [v(0, :module_write_arg_missing)] ==
               line_codes(t, [Map.delete(bline(), "args")])
    end

    test "argument sources: exactly one of var/const, a non-blank var, never _sys", %{t: t} do
      for bad <- [
            %{"var" => ""},
            %{"var" => 7},
            %{"const" => 1, "var" => "x"},
            %{"sys" => "x"},
            %{},
            "plain"
          ] do
        assert [v(0, :module_write_arg_source_invalid)] ==
                 line_codes(t, [
                   mline("post_entry", %{
                     "args" => %{"item" => bad, "quantity" => %{"const" => 1}}
                   })
                 ])
      end

      assert [v(0, :module_write_arg_sys_reference)] ==
               line_codes(t, [
                 mline("post_entry", %{
                   "args" => %{"item" => %{"var" => "_sys.id"}, "quantity" => %{"const" => 1}}
                 })
               ])

      assert :ok = check(t, stamped_map(graph([mline()])))
    end

    test "the combined cap of declarative and handler lines is 20", %{t: t} do
      assert [v(20, :entity_writes_too_many_lines)] ==
               line_codes(t, List.duplicate(mline(), 21))

      assert :ok = check(t, stamped_map(graph(List.duplicate(mline(), 20))))
    end

    test "T1: the cap counts declarative lines too: 19 + 2 is exactly one violation at 20, 18 + 2 passes",
         %{t: t} do
      Fx.define_type!(t.schema, "stock_move", %{})

      over = stamped_map(graph([mline(), mline()], %{"entity_writes" => entity_lines(19)}))
      assert [v(20, :entity_writes_too_many_lines)] == codes(check(t, over))

      at_cap = stamped_map(graph([mline(), mline()], %{"entity_writes" => entity_lines(18)}))
      assert :ok = check(t, at_cap)
    end

    test "T2: a module-line violation index is the declared index after the declarative lines",
         %{t: t} do
      Fx.define_type!(t.schema, "stock_move", %{})

      mixed =
        stamped_map(graph([mline(), mline("nope")], %{"entity_writes" => entity_lines(2)}))

      # entity_writes[0..1] are valid; module_writes[1] is declared line 2 + 1 = 3
      assert [v(3, :module_write_handler_unknown)] == codes(check(t, mixed))
    end

    test "all defects of one line are reported together, in code order", %{t: t} do
      line = mline("post_entry", %{"args" => %{"zzz" => %{"var" => ""}}})

      assert [
               v(0, :module_write_arg_missing),
               v(0, :module_write_arg_source_invalid),
               v(0, :module_write_arg_unknown)
             ] == line_codes(t, [line])
    end
  end

  describe "activator authority (OQ-R6)" do
    test "no activator, one without :EntitiesRecordsWrite, an inactive user, an absent user row",
         %{t: t} do
      install_ledger!(t.schema)
      row = stamped!(t.schema, graph([mline()]))

      inactive = user!(t.schema)

      {1, _} =
        Repo.update_all(from(u in User, where: u.id == ^inactive.id), [set: [status: :inactive]],
          prefix: t.schema
        )

      ghost = %{
        user_id: Ecto.UUID.generate(),
        roles: ["TENANT_ADMIN"],
        entities_records_write?: true,
        permissions: ["EntitiesRecordsWrite"]
      }

      for activator <- [
            nil,
            activator(t.user, ["REVIEWER"]),
            activator(inactive),
            ghost
          ] do
        assert [v(0, :entity_write_activator_required)] == codes(check(t, row, activator))
      end
    end
  end

  # ── the three activation paths ──────────────────────────────────────────────────────────────

  describe "activate/2" do
    test "records module_handlers in activated_by; the pairs list stays empty", %{t: t} do
      install_ledger!(t.schema)
      draft = stamped!(t.schema, graph([mline(), bline()]))

      assert {:ok, %{already_active: false}} =
               Definitions.activate(draft.id, prefix: t.schema, activator: activator(t.user))

      stored = row(t.schema, draft.id)
      assert stored.status == :active

      assert %{
               "user_id" => user_id,
               "authorized" => [],
               "module_handlers" => [
                 "fixture_ledger/post_balance_only",
                 "fixture_ledger/post_entry"
               ]
             } = stored.activated_by

      assert user_id == t.user.id
    end

    test "a tenant copy of the graph is refused and the draft is untouched", %{t: t} do
      install_ledger!(t.schema)
      copy = plain!(t.schema, graph([mline()]))

      assert {:error, {:entity_writes_invalid, [v(0, :module_write_stamp_missing)]}} ==
               Definitions.activate(copy.id, prefix: t.schema, activator: activator(t.user))

      assert %{status: :draft, activated_by: nil} = row(t.schema, copy.id)
    end

    test "T2: a MIXED node records the declarative pairs AND the handlers", %{t: t} do
      install_ledger!(t.schema)
      Fx.define_type!(t.schema, "stock_move", %{})

      draft =
        stamped!(
          t.schema,
          graph([mline()], %{"entity_writes" => entity_lines(1)})
        )

      assert {:ok, %{already_active: false}} =
               Definitions.activate(draft.id, prefix: t.schema, activator: activator(t.user))

      assert %{
               "authorized" => [%{"entity_type" => "stock_move", "op" => "create"}],
               "module_handlers" => ["fixture_ledger/post_entry"]
             } = row(t.schema, draft.id).activated_by
    end

    test "T3: no hash reaches the activation error, whatever caused the mismatch", %{t: t} do
      install_ledger!(t.schema)
      {:ok, compiled} = Catalog.manifest_hash(FixtureLedger)
      drifted = String.duplicate("e", 64)
      stale = String.duplicate("c", 64)

      for {installed, stamp_hash} <- [{drifted, compiled}, {nil, compiled}, {stale, stale}] do
        set_installed_hash!(t.schema, installed)
        draft = stamped!(t.schema, graph([mline()]), owner(%{manifest_hash: stamp_hash}))

        result =
          Definitions.activate(draft.id, prefix: t.schema, activator: activator(t.user))

        assert {:error, {:entity_writes_invalid, [_one] = violations}} = result

        body =
          Plug.Test.conn(:post, "/")
          |> Letflow.Api.Response.entity_writes_invalid(violations)
          |> Map.fetch!(:resp_body)

        for hash <- [compiled, drifted, stale, OwnerStamp.graph_hash(draft.graph)] do
          refute inspect(result) =~ hash
          refute body =~ hash
        end
      end
    end

    test "a hash drift after the stamp is refused with module_write_hash_mismatch", %{t: t} do
      install_ledger!(t.schema)
      draft = stamped!(t.schema, graph([mline()]))
      set_installed_hash!(t.schema, String.duplicate("e", 64))

      assert {:error, {:entity_writes_invalid, [v(0, :module_write_hash_mismatch)]}} ==
               Definitions.activate(draft.id, prefix: t.schema, activator: activator(t.user))

      assert %{status: :draft} = row(t.schema, draft.id)
    end

    test "a graph without module_writes leaves activated_by NULL", %{t: t} do
      draft = plain!(t.schema, trivial_graph())

      assert {:ok, _} =
               Definitions.activate(draft.id, prefix: t.schema, activator: activator(t.user))

      assert %{status: :active, activated_by: nil} = row(t.schema, draft.id)
    end

    test "same-name supersession cannot transfer the stamp: version 1.1 made by the tenant",
         %{t: t} do
      install_ledger!(t.schema)
      name = unique("supersede")
      v1 = stamped!(t.schema, graph([mline()]), nil, name)

      assert {:ok, _} =
               Definitions.activate(v1.id, prefix: t.schema, activator: activator(t.user))

      assert {:ok, %ProcessDefinition{} = v11} =
               Definitions.create(
                 %{
                   name: name,
                   version: "1.1",
                   graph: graph([mline()]),
                   created_by: Ecto.UUID.generate()
                 },
                 prefix: t.schema
               )

      assert v11.owner_module == nil

      assert {:error, {:entity_writes_invalid, [v(0, :module_write_stamp_missing)]}} ==
               Definitions.activate(v11.id, prefix: t.schema, activator: activator(t.user))

      assert %{status: :active} = row(t.schema, v1.id)
    end
  end

  describe "version rollback" do
    test "rolling back to a stamped version re-runs the checks; a drift leaves v2 active",
         %{t: t} do
      install_ledger!(t.schema)
      key = unique("rb")
      v1 = stamped!(t.schema, graph([mline()]), nil, key)
      deprecate!(t.schema, v1.id)

      v2 = plain!(t.schema, trivial_graph(), key, "2")

      {1, _} =
        Repo.update_all(
          from(d in ProcessDefinition, where: d.id == ^v2.id),
          [set: [status: :active]],
          prefix: t.schema
        )

      count_before = Repo.aggregate(ProcessDefinition, :count, prefix: t.schema)
      set_installed_hash!(t.schema, String.duplicate("f", 64))

      assert {:error, {:entity_writes_invalid, [v(0, :module_write_hash_mismatch)]}} ==
               rollback(t.schema, key, activator(t.user))

      assert %{status: :active} = row(t.schema, v2.id)
      assert %{status: :deprecated} = row(t.schema, v1.id)

      {:ok, compiled} = Catalog.manifest_hash(FixtureLedger)
      set_installed_hash!(t.schema, compiled)

      assert {:ok, %{version: "1"}} = rollback(t.schema, key, activator(t.user))
      assert %{status: :active, activated_by: %{"module_handlers" => [_]}} = row(t.schema, v1.id)
      # rollback swaps the active pointer to the EXISTING stamped row: no copy is made, so the
      # row keeps its stamp and the table gains no row
      assert Repo.aggregate(ProcessDefinition, :count, prefix: t.schema) == count_before
      assert {:ok, _stamp} = OwnerStamp.from_row(row(t.schema, v1.id))
    end
  end

  describe "promotion apply" do
    setup do
      %{source: tenant!("gh2590-r3-src")}
    end

    test "a promoted copy is a new unstamped row: its handler line is refused in the target",
         %{t: t, source: source} do
      install_ledger!(t.schema)
      install_ledger!(source.schema)
      handler_graph = graph([mline()])

      # Promotion creates a NEW row in the target from the source graph; a new row never
      # carries a stamp, whatever the source row was.
      assert {{:error,
               {:entity_writes_invalid, [%{index: 0, code: :module_write_stamp_missing}]}}, []} =
               promote(source, t, handler_graph, activator(t.user))
    end

    test "positive control: the same promotion of a graph WITHOUT module_writes succeeds",
         %{t: t, source: source} do
      install_ledger!(t.schema)
      install_ledger!(source.schema)

      assert {{:ok, _}, [%{status: :active, activated_by: nil}]} =
               promote(source, t, trivial_graph(), activator(t.user))
    end
  end
end
