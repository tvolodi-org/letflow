defmodule Letflow.Modules.CatalogScopeDeclarationsTest do
  @moduledoc """
  REQ-518 / GH #2535 slice 2c-i-a, AC 4 (design
  `lib/letflow/design/req518-compiler-scope-filter.md` 3.2, SEC ruling R-3; spec
  `test/specs/REQ-518-2c-i-a.md`, T-D7, T-D8):

    * `Letflow.Modules.Catalog` rule 11, the optional `:scope_declarations` manifest key: absent
      is valid, every malformed shape and every unmanaged type of a production module is refused
      with a named error, a duplicate across manifests is refused, a malformed
      `:scope_declarations` of ANOTHER manifest does not crash the check (REVIEWER F-4);
    * `Letflow.Modules.ManifestHash` covers `scope_declarations` only when the key is present, so
      the hash of every manifest without it is unchanged (a pinned value computed with the
      pre-change `ManifestHash` source of `main`);
    * T-D8: the test-only allowlist `:scope_declaration_unmanaged_modules` is `[]` after
      evaluating the PRODUCTION configuration (`config/config.exs` + `prod.exs` +
      `runtime.exs`, `Config.Reader`), is set only in `config/test.exs`, is never read from the
      OS environment, and no code under `lib/` sets it.

  `async: false`: `runtime.exs` reads the OS environment (see `RuntimeConfigEval`).
  """

  use ExUnit.Case, async: false

  alias Letflow.Modules.Catalog
  alias Letflow.Modules.FixtureScoped
  alias Letflow.Modules.ManifestHash
  alias Letflow.Test.RuntimeConfigEval

  @key :scope_declaration_unmanaged_modules
  @key_text "scope_declaration_unmanaged_modules"

  defp manifest(overrides) do
    Map.merge(
      %{
        id: "probe",
        version: "0.1.0",
        depends_on: [],
        pack: nil,
        permissions: [:ProbeRead],
        role_grants: %{TASK_WORKER: [:ProbeRead]},
        required_roles: [],
        settings_schema: nil,
        route_policies: [{"GET", "/items/:id", :ProbeRead}],
        manages_entity_types: ["thing"]
      },
      Map.new(overrides)
    )
  end

  defp other_manifest(overrides) do
    manifest(
      Map.merge(
        %{
          id: "probe2",
          permissions: [:Probe2Read],
          role_grants: %{TASK_WORKER: [:Probe2Read]},
          route_policies: [{"GET", "/things/:id", :Probe2Read}]
        },
        Map.new(overrides)
      )
    )
  end

  defp validate(m), do: Catalog.validate(m, [m])

  # ===========================================================================================
  describe "T-D7 Catalog rule 11" do
    test "a manifest without :scope_declarations is valid" do
      assert validate(manifest(%{})) == :ok
    end

    test "a managed type declared {:column, name} or :tenant_wide is valid" do
      for decl <- [{:column, "scope_node"}, :tenant_wide, {:column, "a"}] do
        assert validate(manifest(%{scope_declarations: %{"thing" => decl}})) == :ok, inspect(decl)
      end

      m =
        manifest(%{
          manages_entity_types: ["thing", "other"],
          scope_declarations: %{"thing" => :tenant_wide, "other" => {:column, "scope_node"}}
        })

      assert validate(m) == :ok
    end

    test "an empty map is valid (declares nothing)" do
      assert validate(manifest(%{scope_declarations: %{}})) == :ok
    end

    test "a value that is not a map is {:invalid_scope_declarations, value}" do
      for bad <- [nil, [], [{"thing", :tenant_wide}], "thing", :tenant_wide, 42, {:column, "x"}] do
        assert validate(manifest(%{scope_declarations: bad})) ==
                 {:error, {:invalid_scope_declarations, bad}},
               inspect(bad)
      end
    end

    test "a key that is not a managed-format name is refused" do
      for key <- [
            "",
            "Thing",
            "1thing",
            "thing-x",
            "th ing",
            String.duplicate("a", 65),
            :thing,
            1
          ] do
        decls = %{key => :tenant_wide}
        m = manifest(%{manages_entity_types: ["thing"], scope_declarations: decls})

        assert validate(m) == {:error, {:invalid_scope_declarations, decls}}, inspect(key)
      end
    end

    test "a value that is neither :tenant_wide nor {:column, name} with a managed-format name is refused" do
      for bad <- [
            :column,
            :undeclared,
            "tenant_wide",
            {:column, 1},
            {:column, nil},
            {:column, "Bad Col"},
            {:column, ""},
            {:column, "a;b"},
            {:columns, "scope_node"},
            {:column, "a", "b"},
            %{column: "scope_node"},
            nil
          ] do
        decls = %{"thing" => bad}

        assert validate(manifest(%{scope_declarations: decls})) ==
                 {:error, {:invalid_scope_declarations, decls}},
               inspect(bad)
      end
    end

    test "an UNMANAGED type of a production module is {:scope_declaration_unmanaged_type, name} (R-3, MU37)" do
      m = manifest(%{manages_entity_types: [], scope_declarations: %{"thing" => :tenant_wide}})
      assert validate(m) == {:error, {:scope_declaration_unmanaged_type, "thing"}}

      m =
        manifest(%{
          manages_entity_types: ["other"],
          scope_declarations: %{"thing" => {:column, "scope_node"}}
        })

      assert validate(m) == {:error, {:scope_declaration_unmanaged_type, "thing"}}

      # no manages_entity_types key at all
      m =
        manifest(%{scope_declarations: %{"thing" => :tenant_wide}})
        |> Map.delete(:manages_entity_types)

      assert validate(m) == {:error, {:scope_declaration_unmanaged_type, "thing"}}
    end

    test "the unmanaged exception is the allowlisted MODULE ID, not the type: only fixture_scoped" do
      assert Application.get_env(:letflow, @key) == ["fixture_scoped"]

      decls = %{"loose_type" => {:column, "scope_node"}}

      allowlisted =
        manifest(%{id: "fixture_scoped", manages_entity_types: [], scope_declarations: decls})

      assert Catalog.validate(allowlisted, [allowlisted]) == :ok

      # the same shape under any other module id is refused
      for id <- ["probe", "fixture_scoped2", "Fixture_scoped", "exam", ""] do
        m = manifest(%{id: id, manages_entity_types: [], scope_declarations: decls})

        assert match?(
                 {:error, {:scope_declaration_unmanaged_type, "loose_type"}},
                 Catalog.validate(m, [m])
               ),
               "module id #{inspect(id)} must not be allowlisted"
      end
    end

    test "the allowlist does not excuse a malformed declaration" do
      decls = %{"loose_type" => :nonsense}
      m = manifest(%{id: "fixture_scoped", manages_entity_types: [], scope_declarations: decls})

      assert Catalog.validate(m, [m]) == {:error, {:invalid_scope_declarations, decls}}
    end

    test "a type declared by two manifests is {:duplicate_scope_declaration, name}, seen from either side" do
      a = manifest(%{scope_declarations: %{"thing" => :tenant_wide}})
      b = other_manifest(%{scope_declarations: %{"thing" => {:column, "scope_node"}}})

      assert Catalog.validate(a, [a, b]) == {:error, {:duplicate_scope_declaration, "thing"}}
      assert Catalog.validate(b, [a, b]) == {:error, {:duplicate_scope_declaration, "thing"}}
    end

    test "different types in two manifests are valid; a manifest without the key does not collide" do
      a = manifest(%{scope_declarations: %{"thing" => :tenant_wide}})

      b =
        other_manifest(%{
          manages_entity_types: ["other"],
          scope_declarations: %{"other" => :tenant_wide}
        })

      c =
        other_manifest(%{
          id: "probe3",
          permissions: [:Probe3Read],
          role_grants: %{TASK_WORKER: [:Probe3Read]},
          route_policies: [{"GET", "/c/:id", :Probe3Read}]
        })

      assert Catalog.validate(a, [a, b, c]) == :ok
      assert Catalog.validate(b, [a, b, c]) == :ok
    end

    test "another manifest whose :scope_declarations is not a map does not crash the check (REVIEWER F-4)" do
      a = manifest(%{scope_declarations: %{"thing" => :tenant_wide}})
      broken = other_manifest(%{scope_declarations: :not_a_map})

      assert Catalog.validate(a, [a, broken]) == :ok
    end

    test "every registered module of this configuration validates (fixture_scoped included)" do
      manifests = Catalog.all_manifests()
      assert Enum.any?(manifests, &(&1.id == "fixture_scoped"))

      for m <- manifests do
        assert Catalog.validate(m, manifests) == :ok, "module #{m.id}"
      end
    end

    test "the fixture module declares exactly the four types of the design (3.8)" do
      assert FixtureScoped.manifest().scope_declarations == %{
               "scoped_item" => {:column, "scope_node"},
               "scoped_child" => {:column, "scope_node"},
               "scoped_master" => :tenant_wide,
               "scoped_managed_item" => {:column, "scope_node"}
             }

      assert FixtureScoped.manifest().manages_entity_types == ["scoped_managed_item"]
    end
  end

  # ===========================================================================================
  describe "T-D7 ManifestHash" do
    # computed with the pre-change ManifestHash source (git show HEAD:...) for @plain
    @pinned_plain_hash "8763a9c69e7ca6dc4c901c049ee1120b3b672ad84a11739da4de731e3b0499e5"

    @plain %{
      id: "probe_hash",
      version: "1.2.3",
      depends_on: [],
      pack: nil,
      permissions: [:ProbeRead],
      role_grants: %{TASK_WORKER: [:ProbeRead]},
      required_roles: [],
      settings_schema: nil,
      route_policies: [{"GET", "/items/:id", :ProbeRead}],
      manages_entity_types: ["thing_b", "thing_a"]
    }

    test "a manifest without :scope_declarations hashes exactly as before the change (pinned value)" do
      assert ManifestHash.compute(@plain) == @pinned_plain_hash
    end

    test "an absent key and the key set to an empty map are different declared surfaces; a present key changes the hash" do
      with_empty = Map.put(@plain, :scope_declarations, %{})
      with_decl = Map.put(@plain, :scope_declarations, %{"thing_a" => {:column, "scope_node"}})

      refute ManifestHash.compute(with_decl) == @pinned_plain_hash
      refute ManifestHash.compute(with_decl) == ManifestHash.compute(with_empty)
    end

    test "every part of a declaration is covered: the type, the kind and the column name" do
      base =
        ManifestHash.compute(
          Map.put(@plain, :scope_declarations, %{"thing_a" => {:column, "scope_node"}})
        )

      for changed <- [
            %{"thing_b" => {:column, "scope_node"}},
            %{"thing_a" => {:column, "other_col"}},
            %{"thing_a" => :tenant_wide},
            %{"thing_a" => {:column, "scope_node"}, "thing_b" => :tenant_wide}
          ] do
        refute ManifestHash.compute(Map.put(@plain, :scope_declarations, changed)) == base,
               inspect(changed)
      end
    end

    test "the hash does not depend on map key order and is a 64-char lowercase hex digest" do
      one =
        Map.put(@plain, :scope_declarations, %{
          "thing_a" => :tenant_wide,
          "thing_b" => {:column, "c"}
        })

      two =
        Map.put(@plain, :scope_declarations, %{
          "thing_b" => {:column, "c"},
          "thing_a" => :tenant_wide
        })

      assert ManifestHash.compute(one) == ManifestHash.compute(two)
      assert ManifestHash.compute(one) =~ ~r/\A[0-9a-f]{64}\z/
    end

    test "every registered manifest WITHOUT the key has a hash that ignores any scope key being absent" do
      for m <- Catalog.all_manifests(), not Map.has_key?(m, :scope_declarations) do
        assert ManifestHash.compute(m) == ManifestHash.compute(Map.delete(m, :scope_declarations))
      end
    end
  end

  # ===========================================================================================
  describe "T-D8 the unmanaged-type allowlist exists in test configuration only (R-3)" do
    setup do
      RuntimeConfigEval.isolate_env()
      :ok
    end

    defp prod_config do
      vars =
        Map.put(
          RuntimeConfigEval.valid_base(),
          "DATABASE_URL",
          "ecto://u:p@localhost/letflow_prod"
        )

      {outcome, _stderr} = RuntimeConfigEval.evaluate(vars, :prod)

      case outcome do
        {:ok, runtime} ->
          RuntimeConfigEval.merged(runtime, :prod)

        {:raised, message, _formatted} ->
          flunk("the production runtime configuration did not evaluate: #{message}")
      end
    end

    test "under the PRODUCTION configuration (config.exs + prod.exs + runtime.exs) the key is unset or []" do
      value = prod_config() |> Keyword.get(:letflow, []) |> Keyword.get(@key, [])

      assert value == []
    end

    test "under the production configuration no test-only fixture module is registered" do
      modules = prod_config() |> Keyword.get(:letflow, []) |> Keyword.get(:modules, [])

      refute Letflow.Modules.FixtureScoped in modules
    end

    test "under the test configuration the key is exactly [\"fixture_scoped\"]" do
      test_config = Config.Reader.read!("config/config.exs", env: :test, target: :host)
      assert get_in(test_config, [:letflow, @key]) == ["fixture_scoped"]
      assert Application.get_env(:letflow, @key) == ["fixture_scoped"]
    end

    test "under the dev configuration the key is unset or []" do
      RuntimeConfigEval.merged([], :dev)
      |> Keyword.get(:letflow, [])
      |> Keyword.get(@key, [])
      |> then(&assert(&1 == []))
    end

    test "the key text appears in no config file but config/test.exs, and in no OS-environment read" do
      files = Path.wildcard("config/*.exs") ++ ["mix.exs"] ++ Path.wildcard("rel/**/*.exs")

      carriers = for f <- files, File.read!(f) =~ @key_text, do: Path.basename(f)
      assert carriers == ["test.exs"]

      runtime = File.read!("config/runtime.exs")
      refute runtime =~ "SCOPE_DECLARATION"
      refute runtime =~ ~r/System\.(get_env|fetch_env)[^\n]*(scope_decl|SCOPE_DECL)/i
    end

    test "no code under lib/ sets the key: it is only ever read (AST of every lib file)" do
      offenders =
        for file <- Path.wildcard("lib/**/*.ex"),
            call <- key_calls(file),
            call not in [:get_env, :fetch_env, :fetch_env!],
            do: {file, call}

      assert offenders == [], "lib code that writes the allowlist: #{inspect(offenders)}"

      # control: the reader exists (the scan sees the key at all)
      reads = for file <- Path.wildcard("lib/**/*.ex"), call <- key_calls(file), do: call
      assert :get_env in reads
    end

    # the Application.* function names whose arguments contain the key atom literally
    defp key_calls(file) do
      source = File.read!(file)

      if source =~ @key_text do
        source
        |> Code.string_to_quoted!()
        |> Macro.prewalk([], fn
          {{:., _, [{:__aliases__, _, [:Application]}, fun]}, _, args} = node, acc
          when is_list(args) ->
            if mentions_key?(args), do: {node, [fun | acc]}, else: {node, acc}

          node, acc ->
            {node, acc}
        end)
        |> elem(1)
      else
        []
      end
    end

    defp mentions_key?(ast) do
      ast
      |> Macro.prewalk(false, fn
        @key, _acc -> {@key, true}
        node, acc -> {node, acc}
      end)
      |> elem(1)
    end
  end
end
