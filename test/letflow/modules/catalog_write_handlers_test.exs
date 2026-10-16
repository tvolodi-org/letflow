defmodule Letflow.Modules.CatalogWriteHandlersTest do
  @moduledoc """
  GH #2590 / REQ-501 R1: the `:write_handlers` manifest key, Catalog rule 10,
  `Catalog.write_handler/2` (string lookup, re-validated on every resolution,
  F-6), `Catalog.call_write_handler/4` and `Catalog.manifest_hash/1` /
  `Letflow.Modules.ManifestHash` (design section 4.1, section 11 rows
  "Manifest validation", "Registration only from module code", F-6).

  Pure, no database: `async: true`. Unvalidated manifests are served by
  `ProbeEntry`, a module whose `manifest/0` reads the calling process's
  dictionary, and resolved through the `write_handler_in/3` seam.
  """

  use ExUnit.Case, async: true

  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Catalog.WriteHandler
  alias Letflow.Modules.FixtureLedger
  alias Letflow.Modules.FixtureLedgerOther
  alias Letflow.Modules.ManifestHash

  defmodule ProbeEntry do
    @moduledoc false
    def manifest, do: Process.get(:wh_manifest)
    # the entry module itself exports an arity-3 function (like on_install/3)
    def on_install(_prefix, _settings, _ctx), do: :ok

    defmodule Handlers do
      @moduledoc false
      def handle(multi, _ctx, _args), do: {:ok, multi}
      def handle_two(multi, _ctx, _args), do: {:ok, multi}
      def not_arity_three(_multi, _ctx), do: :ok

      defmodule Nested do
        @moduledoc false
        def handle(multi, _ctx, _args), do: {:ok, multi}
      end
    end
  end

  defmodule ProbeEntryTwin do
    @moduledoc false
    def manifest, do: Process.get(:wh_manifest)
  end

  defp probe_manifest(overrides \\ %{}) do
    Map.merge(
      %{
        id: "probe_wh",
        version: "0.1.0",
        depends_on: [],
        pack: nil,
        permissions: [],
        role_grants: %{},
        required_roles: [],
        settings_schema: nil,
        route_policies: [],
        manages_entity_types: ["pw_one", "pw_two"],
        write_handlers: [probe_handler()]
      },
      overrides
    )
  end

  defp probe_handler(overrides \\ %{}) do
    Map.merge(
      %{
        name: "do_it",
        function: {ProbeEntry.Handlers, :handle},
        targets: ["pw_one"],
        args: %{"item" => %{required: true}}
      },
      overrides
    )
  end

  # Resolves against the ProbeEntry manifest (never passed through validate/2).
  defp resolve(manifest, name \\ "do_it") do
    Process.put(:wh_manifest, manifest)
    Catalog.write_handler_in([ProbeEntry], manifest.id, name)
  end

  # validate/2 locates the entry module by id; FixtureLedger's manifest is the base.
  defp validate_ledger(overrides),
    do: Catalog.validate(Map.merge(FixtureLedger.manifest(), overrides), [])

  defp ledger_handler, do: hd(FixtureLedger.manifest().write_handlers)

  describe "validate/2 rule 10" do
    test "registered fixtures with handlers validate; absent and [] are valid" do
      assert Catalog.validate(FixtureLedger.manifest()) == :ok
      assert Catalog.validate(FixtureLedgerOther.manifest()) == :ok
      assert validate_ledger(%{write_handlers: []}) == :ok
      assert Catalog.validate(Letflow.Modules.Fixture.manifest()) == :ok
    end

    test "handler module may be nested under the entry module" do
      handler = %{ledger_handler() | function: {FixtureLedger.Handlers, :post_entry}}
      assert validate_ledger(%{write_handlers: [handler]}) == :ok
    end

    @malformed [
      not_a_list: :nope,
      nil_value: nil,
      not_maps: ["x"],
      extra_key: [%{name: "a", function: {Foo, :f}, targets: ["t"], args: %{}, extra: 1}],
      missing_key: [%{name: "a", function: {Foo, :f}, targets: ["t"]}],
      bad_name: [%{name: "Bad-Name", function: {Foo, :f}, targets: ["t"], args: %{}}],
      non_binary_name: [%{name: :atom, function: {Foo, :f}, targets: ["t"], args: %{}}],
      bad_function: [%{name: "a", function: :f, targets: ["t"], args: %{}}],
      targets_not_list: [%{name: "a", function: {Foo, :f}, targets: "t", args: %{}}],
      target_not_binary: [%{name: "a", function: {Foo, :f}, targets: [:t], args: %{}}],
      args_not_map: [%{name: "a", function: {Foo, :f}, targets: ["t"], args: ["x"]}],
      arg_value_malformed: [
        %{name: "a", function: {Foo, :f}, targets: ["t"], args: %{"x" => %{required: "yes"}}}
      ],
      arg_name_not_binary: [
        %{name: "a", function: {Foo, :f}, targets: ["t"], args: %{x: %{required: true}}}
      ]
    ]

    for {label, value} <- @malformed do
      test "malformed registration (#{label}) -> invalid_write_handlers" do
        value = unquote(Macro.escape(value))

        assert {:error, {:invalid_write_handlers, ^value}} =
                 validate_ledger(%{write_handlers: value})
      end
    end

    test "duplicate handler name" do
      handler = ledger_handler()

      assert {:error, {:duplicate_write_handler, "post_entry"}} =
               validate_ledger(%{write_handlers: [handler, handler]})
    end

    test "module id outside the name format while handlers are declared" do
      assert {:error, {:invalid_module_id_for_handlers, "Bad Id"}} =
               validate_ledger(%{id: "Bad Id"})
    end

    test "handlers without managed types (absent, or empty)" do
      manifest = Map.delete(FixtureLedger.manifest(), :manages_entity_types)

      assert {:error, {:write_handler_without_managed_types, "post_entry"}} =
               Catalog.validate(manifest, [])

      assert {:error, {:write_handler_without_managed_types, "post_entry"}} =
               validate_ledger(%{manages_entity_types: []})
    end

    test "empty targets" do
      handler = %{ledger_handler() | targets: []}

      assert {:error, {:write_handler_no_targets, "post_entry"}} =
               validate_ledger(%{write_handlers: [handler]})
    end

    test "target not in the same manifest's manages_entity_types" do
      handler = %{ledger_handler() | targets: ["fxl_ledger", "fxo_other"]}

      assert {:error, {:write_handler_target_not_managed, "post_entry", "fxo_other"}} =
               validate_ledger(%{write_handlers: [handler]})
    end

    test "handler module outside the entry module's namespace" do
      repo = %{ledger_handler() | function: {Letflow.Repo, :all}}

      assert {:error, {:write_handler_outside_module, "post_entry"}} =
               validate_ledger(%{write_handlers: [repo]})

      other = %{repo | function: {FixtureLedgerOther.Handlers, :post_other}}

      assert {:error, {:write_handler_outside_module, "post_entry"}} =
               validate_ledger(%{write_handlers: [other]})

      sibling = %{repo | function: {Letflow.Modules.FixtureLedgerOther, :manifest}}

      assert {:error, {:write_handler_outside_module, "post_entry"}} =
               validate_ledger(%{write_handlers: [sibling]})
    end

    test "a manifest no registered module carries fails closed (no entry module)" do
      assert {:error, {:write_handler_outside_module, "do_it"}} =
               Catalog.validate(probe_manifest(), [])
    end

    test "function not exported (missing, wrong arity, module not loadable)" do
      for function <- [
            {FixtureLedger.Handlers, :nope},
            {FixtureLedger.Handlers, :__info__},
            {FixtureLedger.NotLoadable, :post_entry}
          ] do
        handler = %{ledger_handler() | function: function}

        assert {:error, {:write_handler_function_not_exported, "post_entry"}} =
                 validate_ledger(%{write_handlers: [handler]})
      end
    end
  end

  describe "write_handler/2 resolution" do
    test "resolves a registered handler by manifest id and name" do
      assert {:ok, %WriteHandler{} = handler} =
               Catalog.write_handler("fixture_ledger", "post_entry")

      assert handler.module_id == "fixture_ledger"
      assert handler.name == "post_entry"
      assert handler.entry_module == FixtureLedger
      assert handler.entry_module == FixtureLedger
      refute Map.has_key?(Map.from_struct(handler), :function)
      assert handler.targets == ["fxl_balance", "fxl_ledger"]
      assert handler.args == %{"item" => %{required: true}, "quantity" => %{required: true}}

      assert {:ok, %WriteHandler{targets: ["fxl_balance"]}} =
               Catalog.write_handler("fixture_ledger", "post_balance_only")
    end

    test "a handler of one module is not resolvable under another module's id" do
      assert {:ok, _} = Catalog.write_handler("fixture_ledger_other", "post_other")
      assert Catalog.write_handler("fixture_ledger", "post_other") == {:error, :not_found}
      assert Catalog.write_handler("fixture_ledger_other", "post_entry") == {:error, :not_found}
    end

    test "unknown module, unknown name, module without handlers" do
      assert Catalog.write_handler("nope", "post_entry") == {:error, :not_found}
      assert Catalog.write_handler("fixture_ledger", "nope") == {:error, :not_found}
      assert Catalog.write_handler("fixture", "post_entry") == {:error, :not_found}
    end

    test "non-binary arguments answer :not_found (atoms, nil, lists, maps, entry module atom)" do
      for bad <- [:fixture_ledger, nil, ["fixture_ledger"], %{}, 7, FixtureLedger] do
        assert Catalog.write_handler(bad, "post_entry") == {:error, :not_found}
        assert Catalog.write_handler("fixture_ledger", bad) == {:error, :not_found}
      end

      assert Catalog.write_handler(:post_entry, :post_entry) == {:error, :not_found}
    end

    test "resolution is exact string comparison, no normalisation" do
      for name <- ["Post_entry", "post_entry ", " post_entry", "post_entry\n", ""] do
        assert Catalog.write_handler("fixture_ledger", name) == {:error, :not_found}
      end

      assert Catalog.write_handler("Fixture_Ledger", "post_entry") == {:error, :not_found}
    end

    test "resolution creates no atom from the arguments" do
      unique = "wh_never_an_atom_#{System.unique_integer([:positive])}"
      assert Catalog.write_handler(unique, unique) == {:error, :not_found}
      assert_raise ArgumentError, fn -> String.to_existing_atom(unique) end
    end
  end

  describe "write_handler/2 re-validates on every resolution (F-6)" do
    test "a valid, never-validated manifest resolves (seam sanity)" do
      assert {:ok, %WriteHandler{entry_module: ProbeEntry, targets: ["pw_one"]}} =
               resolve(probe_manifest())
    end

    test "handler in a nested module of the entry resolves" do
      handler = probe_handler(%{function: {ProbeEntry.Handlers.Nested, :handle}})
      assert {:ok, _} = resolve(probe_manifest(%{write_handlers: [handler]}))
    end

    @broken [
      wrong_keys: %{write_handlers: [%{name: "do_it"}]},
      not_a_list: %{write_handlers: %{}},
      bad_name_format: %{
        write_handlers: [
          %{
            name: "do-it",
            function: {ProbeEntry.Handlers, :handle},
            targets: ["pw_one"],
            args: %{}
          }
        ]
      },
      target_not_managed: %{
        write_handlers: [
          %{
            name: "do_it",
            function: {ProbeEntry.Handlers, :handle},
            targets: ["other"],
            args: %{}
          }
        ]
      },
      empty_targets: %{
        write_handlers: [
          %{name: "do_it", function: {ProbeEntry.Handlers, :handle}, targets: [], args: %{}}
        ]
      },
      no_managed_types: %{manages_entity_types: []},
      outside_module: %{
        write_handlers: [
          %{name: "do_it", function: {Letflow.Repo, :all}, targets: ["pw_one"], args: %{}}
        ]
      },
      not_exported: %{
        write_handlers: [
          %{name: "do_it", function: {ProbeEntry.Handlers, :nope}, targets: ["pw_one"], args: %{}}
        ]
      },
      wrong_arity: %{
        write_handlers: [
          %{
            name: "do_it",
            function: {ProbeEntry.Handlers, :not_arity_three},
            targets: ["pw_one"],
            args: %{}
          }
        ]
      },
      bad_module_id: %{id: "Probe Wh"}
    ]

    for {label, overrides} <- @broken do
      test "broken shape (#{label}) resolves to :not_found" do
        manifest = probe_manifest(unquote(Macro.escape(overrides)))
        assert resolve(manifest, "do_it") == {:error, :not_found}
      end
    end

    test "a duplicate name is :not_found (ambiguous registration)" do
      manifest =
        probe_manifest(%{
          write_handlers: [
            probe_handler(),
            probe_handler(%{function: {ProbeEntry.Handlers, :handle_two}})
          ]
        })

      assert resolve(manifest, "do_it") == {:error, :not_found}
    end

    test "one broken sibling fails the whole module closed" do
      manifest =
        probe_manifest(%{
          write_handlers: [
            probe_handler(),
            probe_handler(%{name: "second", function: {ProbeEntry.Handlers, :missing}})
          ]
        })

      assert resolve(manifest, "do_it") == {:error, :not_found}
    end

    test "module not in the supplied entry list, or a non-binary name, is :not_found" do
      Process.put(:wh_manifest, probe_manifest())
      assert Catalog.write_handler_in([], "probe_wh", "do_it") == {:error, :not_found}
      assert Catalog.write_handler_in([ProbeEntry], "probe_wh", :do_it) == {:error, :not_found}
    end
  end

  describe "call_write_handler/4" do
    test "applies the registered function and returns its raw result" do
      {:ok, handler} = Catalog.write_handler("fixture_ledger", "post_entry")
      multi = Ecto.Multi.new()

      # R4a: the fixture handler really writes through HandlerWrites.create/3, which refuses
      # the bogus `%{}` context (not a HandlerContext): the handler's own raw return.
      assert {:error, :not_permitted} =
               Catalog.call_write_handler(handler, multi, %{}, %{"item" => "a", "quantity" => 2})

      assert {:error, :invalid_arguments} =
               Catalog.call_write_handler(handler, multi, %{}, %{"item" => "a"})
    end

    test "a forged struct's other fields are ignored (re-resolved by id and name)" do
      {:ok, handler} = Catalog.write_handler("fixture_ledger", "post_balance_only")
      forged = %{handler | entry_module: System, targets: ["forged"], args: %{}}
      multi = Ecto.Multi.new()

      # the registered function ran (it checked its arguments, then refused the bogus context)
      assert {:error, :not_permitted} =
               Catalog.call_write_handler(forged, multi, %{}, %{"item" => "a"})

      assert {:error, :invalid_arguments} = Catalog.call_write_handler(forged, multi, %{}, %{})
    end

    test "a forged struct naming an unknown handler is :not_found, nothing applied" do
      {:ok, handler} = Catalog.write_handler("fixture_ledger", "post_entry")
      forged = %{handler | name: "ghost"}

      assert Catalog.call_write_handler(forged, Ecto.Multi.new(), %{}, %{}) ==
               {:error, :not_found}
    end

    test "only a %WriteHandler{} is accepted" do
      assert_raise FunctionClauseError, fn ->
        apply(Catalog, :call_write_handler, [
          %{module_id: "fixture_ledger", name: "post_entry"},
          Ecto.Multi.new(),
          %{},
          %{}
        ])
      end
    end
  end

  describe "manifest_hash/1 and ManifestHash.compute/1" do
    test "returns a 64-char lowercase hex digest by module atom and by id; equal" do
      assert {:ok, hash} = Catalog.manifest_hash(FixtureLedger)
      assert hash =~ ~r/\A[0-9a-f]{64}\z/
      assert Catalog.manifest_hash("fixture_ledger") == {:ok, hash}
      assert ManifestHash.compute(FixtureLedger.manifest()) == hash
    end

    test "unknown id, unregistered module, junk" do
      assert Catalog.manifest_hash("nope") == {:error, :not_found}
      assert Catalog.manifest_hash(Letflow.Repo) == {:error, :not_found}
      assert Catalog.manifest_hash(nil) == {:error, :not_found}
      assert Catalog.manifest_hash(7) == {:error, :not_found}
    end

    test "independent of declaration order of handlers, targets and managed types" do
      base = FixtureLedger.manifest()
      [first, second] = base.write_handlers

      reordered = %{
        base
        | write_handlers: [
            %{second | targets: Enum.reverse(second.targets)},
            %{first | targets: Enum.reverse(first.targets)}
          ],
          manages_entity_types: Enum.reverse(base.manages_entity_types)
      }

      assert ManifestHash.compute(reordered) == ManifestHash.compute(base)
    end

    test "absent :write_handlers and [] hash equal" do
      base = Map.delete(FixtureLedger.manifest(), :write_handlers)

      assert ManifestHash.compute(base) ==
               ManifestHash.compute(Map.put(base, :write_handlers, []))
    end

    test "every hashed field changes the hash; unhashed fields do not" do
      base = FixtureLedger.manifest()
      hash = ManifestHash.compute(base)
      [first, second] = base.write_handlers

      with_first = fn changes -> %{base | write_handlers: [Map.merge(first, changes), second]} end

      changed = [
        %{base | id: "fixture_ledger_x"},
        %{base | version: "0.2.0"},
        %{base | manages_entity_types: ["fxl_ledger"]},
        %{base | write_handlers: [second]},
        with_first.(%{name: "post_entry2"}),
        with_first.(%{function: {FixtureLedger.Handlers, :post_balance_only}}),
        with_first.(%{function: {FixtureLedgerOther.Handlers, :post_entry}}),
        with_first.(%{targets: ["fxl_ledger"]}),
        with_first.(%{args: %{"item" => %{required: false}, "quantity" => %{required: true}}})
      ]

      for manifest <- changed, do: refute(ManifestHash.compute(manifest) == hash)

      unhashed = [
        %{base | permissions: [:SomethingElse]},
        %{base | settings_schema: %{"type" => "object"}},
        %{base | pack: "module_fixtures/other.json"},
        %{base | route_policies: [{"GET", "/x", :SomethingElse}]}
      ]

      for manifest <- unhashed, do: assert(ManifestHash.compute(manifest) == hash)
    end

    test "two different registered modules hash differently" do
      refute ManifestHash.compute(FixtureLedger.manifest()) ==
               ManifestHash.compute(FixtureLedgerOther.manifest())
    end
  end

  describe "review follow-ups (SEC F1/F2, REVIEWER 7/8, TDV L-1..L-3)" do
    test "duplicate module ids across entries fail closed (not first-wins)" do
      Process.put(:wh_manifest, probe_manifest())
      assert {:ok, _} = Catalog.write_handler_in([ProbeEntry], "probe_wh", "do_it")

      assert Catalog.write_handler_in([ProbeEntry, ProbeEntryTwin], "probe_wh", "do_it") ==
               {:error, :not_found}

      assert Catalog.write_handler_in([ProbeEntryTwin, ProbeEntry], "probe_wh", "do_it") ==
               {:error, :not_found}
    end

    test "the entry module itself is refused as a handler module (validate and resolve)" do
      managed = Letflow.Modules.FixtureManaged.manifest()

      handler = %{
        name: "boot",
        function: {Letflow.Modules.FixtureManaged, :on_install},
        targets: ["fxm_ledger"],
        args: %{}
      }

      assert {:error, {:write_handler_outside_module, "boot"}} =
               Catalog.validate(Map.put(managed, :write_handlers, [handler]), [])

      manifest =
        probe_manifest(%{write_handlers: [probe_handler(%{function: {ProbeEntry, :on_install}})]})

      assert resolve(manifest) == {:error, :not_found}
    end

    test "non-atom tuple elements are malformed" do
      for function <- [{"Foo", :f}, {ProbeEntry.Handlers, "handle"}, {1, 2}] do
        handler = %{ledger_handler() | function: function}
        value = [handler]

        assert {:error, {:invalid_write_handlers, ^value}} =
                 validate_ledger(%{write_handlers: value})
      end
    end

    test "an arg spec with an extra key is malformed" do
      handler = %{ledger_handler() | args: %{"item" => %{required: true, x: 1}}}
      value = [handler]

      assert {:error, {:invalid_write_handlers, ^value}} =
               validate_ledger(%{write_handlers: value})
    end

    test "name length: 64 characters valid, 65 malformed" do
      ok = %{ledger_handler() | name: String.duplicate("a", 64)}
      assert validate_ledger(%{write_handlers: [ok]}) == :ok
      bad = %{ledger_handler() | name: String.duplicate("a", 65)}
      assert {:error, {:invalid_write_handlers, _}} = validate_ledger(%{write_handlers: [bad]})
    end

    test "duplicate targets are rejected by validation and unresolvable" do
      value = [%{ledger_handler() | targets: ["fxl_ledger", "fxl_ledger"]}]

      assert {:error, {:invalid_write_handlers, ^value}} =
               validate_ledger(%{write_handlers: value})

      manifest =
        probe_manifest(%{write_handlers: [probe_handler(%{targets: ["pw_one", "pw_one"]})]})

      assert resolve(manifest) == {:error, :not_found}
    end

    test "the hash normalises duplicate targets (compute is total over unvalidated input)" do
      base = FixtureLedger.manifest()
      [first | rest] = base.write_handlers
      dup = %{base | write_handlers: [%{first | targets: first.targets ++ first.targets} | rest]}
      assert ManifestHash.compute(dup) == ManifestHash.compute(base)
    end

    test "golden manifest hash of the FixtureLedger manifest" do
      assert ManifestHash.compute(FixtureLedger.manifest()) ==
               "6394cff92f1f30f14e74d59a45bb7e272087160c7596e6078571fbfb6d8d866d"
    end
  end
end
