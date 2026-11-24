defmodule Letflow.SecurityProbe.G03SourceProvenanceTest do
  @moduledoc """
  G-03 of the team repository's `docs/security-coverage.md` §4: the **generated
  source-provenance matrix** of the platform-call authority rule (T-2588, gap G2
  of the "Register a tenant" pilot) and of the write-target rule it carries over
  from T-2430.

  The coverage map (§3.2, "New definition step or node attribute") asks for a
  mechanical check that GENERATES the source-class cross-product -- `var`,
  `const`, `person`, a start variable, an earlier trusted step output, an inline
  HTTP output, a script output, a sub-process output, a malformed source and an
  unknown source -- and proves that only the explicitly trusted classes pass for
  a write-like input. §3.3 adds the catalogue half: for a write-like function a
  `person` input must be refused BY THE CATALOGUE VALIDATOR ITSELF, so the check
  cannot pass merely because the shipped catalogue is benign.

  Before this file the source classes were checked by hand-written examples
  (T-2588's `platform_call_source_class_test.exs`) and by a pack scan (T-2430's
  `write_target_sources_scan_test.exs`). An example test covers its example: a
  new source class, a new side-effect class, a new route attribute or a new
  catalogue entry reached main unchecked.

  ## What is derived

  The closed sets and the entries are DERIVED from the shipped source. Two
  parts of the matrix are this file's own fixed lists: the `malformed`
  family's checklist (the coverage map names each of its cases) and the
  argument-shape alphabet (`@arg_shapes`). The reviewed expectation file
  `test/fixtures/security_probes/g03_source_provenance.txt` states what each
  generated cell must be.

  Derived:

    * the closed set of SOURCE CLASSES is read from the shipped catalogue entry
      module (`@type source_class :: ...`);
    * the closed set of SIDE-EFFECT CLASSES is read from the same module
      (`@type class :: ...`);
    * the ROUTE ATTRIBUTES a platform-call node may not carry beside its call
      come from the shipped rule module (`@conflicting_route_attributes`), and
      the LINE ATTRIBUTES it may not carry either (`entity_writes`,
      `module_writes`: the platform route plans no lines, T-2703) from the same
      module (`@platform_call_line_attributes`); both feed the `dual_route`
      family, only the route attributes feed the `foreign_source` family;
    * the node types that merge a value from outside the graph's own trusted
      inputs come from the same module (`@foreign_source_types`);
    * the ENTRIES are the compiled catalogue
      (`Letflow.PlatformFunctions.Catalog`).

  A new source class, a new side-effect class, a new route attribute or a new
  catalogue entry therefore GROWS the matrix, and the expectation file has no
  line for the new cell: the probe fails until a human reviewed it.

  ## The families

    * `catalogue` -- a synthetic catalogue entry per source class and side-effect
      class, through the shipped `Letflow.PlatformFunctions.Entry.validate!/1`.
      The deliberately broken cells (a write-like entry with a `person` input)
      are the seeded failing case: the shipped catalogue is benign, so only the
      validator itself can refuse them.
    * `malformed` -- the entries the shipped validator must refuse: no name, no
      permission, no platform flag, an unknown source class, a duplicate name.
    * `arg_shape` -- every shipped entry and every declared input, with the
      argument's SOURCE shaped as `var`, `const`, a blank or dotted or reserved
      variable, a malformed map and an unknown key.
    * `foreign_source` -- every shipped side-effect class beside every foreign
      source the shipped rule knows (an inline HTTP service task, a catalogue
      service task, a script-bound service task, a sub-process), at activation
      AND at dispatch.
    * `dual_route` -- every route attribute beside the platform call, at
      activation AND at dispatch (the T-2588 finding: a node that carried both
      `platform_call` and `endpoint`).
    * `write_target` -- the variable a catalogue call reads, refused in a
      completion body (the T-2430 rule carried over by source class), and the
      reviewed exception that lets a human task keep it.

  ## Non-vacuity

  Every family of the matrix has an in-tree MUTANT: a variant of the subject
  that is ONE RULE APART -- it is built FROM the shipped rule (every other
  shipped refusal still runs) and it is driven through the SAME aggregate
  entry point (`matrix/2` -> `cells/1` -> `violations/2`), so what catches it
  is the reviewed expectation file and nothing else.

    * `catalogue` -- the shipped catalogue validator with the write-like
      (`person` input) rule removed;
    * `malformed` -- the shipped catalogue validator with the duplicate-name
      rule removed;
    * `arg_shape` -- the shipped activation with the argument-shape refusal
      removed;
    * `foreign_source` -- the shipped activation with the foreign-source
      refusal removed, and its dispatch twin blind;
    * `dual_route` -- the shipped activation with the conflicting-route
      refusal removed, and its dispatch twin blind;
    * `write_target` -- the shipped completion refusal with the catalogue
      call's contribution to the read set dropped.

  A family that does not catch its own mutant fails the probe: every mutant
  test asserts that the probe goes red AND that only that family's cells
  move, so one family cannot mask another. The positive control (a benign
  entry that must be ACCEPTED) keeps "refuse everything" from passing.

  ## Cost

  `@moduletag probe_cost_s: 5` -- pure: no database, no network, no clock, no
  model, no randomness. The only VM-global it touches is the platform-tenant pin
  (application configuration), restored in `on_exit`.

  ## What the probe does not cover

  The probe measures the PLATFORM-TENANT branch of the platform-call rule: it
  pins the platform tenant in its setup, so `PlatformCalls.violations/4` always
  takes the platform branch. The company-tenant branch -- the ONE fixed code
  `:platform_call_not_allowed`, whatever the function is and whether or not it
  exists (INV-5) -- is not measured here; it is covered by T-2588's own test
  `test/letflow/definitions/platform_call_company_tenant_refused_test.exs`.
  """

  use ExUnit.Case, async: false

  @moduletag :security_probe
  @moduletag :unit
  @moduletag probe_cost_s: 5

  alias Letflow.Definitions.Activator
  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.PlatformCalls
  alias Letflow.Engine.WriteTargets
  alias Letflow.PlatformFunctions.Catalog
  alias Letflow.PlatformFunctions.Entry
  alias Letflow.PlatformFunctions.Entry.Input
  alias Letflow.PlatformFunctions.Entry.SideEffect
  alias Letflow.TenantProvisioning

  @root Path.expand("../../..", __DIR__)
  @entry_module Path.join([@root, "lib", "letflow", "platform_functions", "entry.ex"])
  @rule_module Path.join([@root, "lib", "letflow", "definitions", "platform_calls.ex"])
  @expectations Path.join([
                  @root,
                  "test",
                  "fixtures",
                  "security_probes",
                  "g03_source_provenance.txt"
                ])

  # The platform tenant the probe activates in. FIXED: the probe reads no clock
  # and draws no random id, so the same tree always yields the same matrix.
  @platform_tenant_id "11111111-1111-4111-8111-111111111111"
  @activator_user_id "22222222-2222-4222-8222-222222222222"

  # The shape of an argument's SOURCE -- the alphabet of the matrix. The two
  # legal shapes are `var` (a variable of the instance) and `const` (a
  # designer-fixed value, signed with the graph); the rest are the malformed and
  # the unknown ones the shipped rule must refuse.
  @arg_shapes [
    {"var", %{"var" => "probe_value"}},
    {"const", %{"const" => "probe-value"}},
    {"var_blank", %{"var" => ""}},
    {"var_spaces", %{"var" => "   "}},
    {"var_dotted", %{"var" => "probe.value"}},
    {"var_reserved", %{"var" => "_sys"}},
    {"malformed_empty", %{}},
    {"malformed_ambiguous", %{"var" => "probe_value", "const" => "probe-value"}},
    {"malformed_not_a_map", "probe-value"},
    {"unknown_key", %{"value" => "probe-value"}}
  ]

  setup do
    previous = Application.fetch_env(:letflow, Letflow.PlatformTenant)
    Application.put_env(:letflow, Letflow.PlatformTenant, tenant_id: @platform_tenant_id)
    on_exit(fn -> restore_pin(previous) end)

    {:ok, prefix: platform_prefix(), activator: activator()}
  end

  defp restore_pin({:ok, value}), do: Application.put_env(:letflow, Letflow.PlatformTenant, value)
  defp restore_pin(:error), do: Application.delete_env(:letflow, Letflow.PlatformTenant)

  defp platform_prefix do
    {:ok, prefix} = TenantProvisioning.schema_name_for_tenant(@platform_tenant_id)
    prefix
  end

  # The activator of the platform tenant: an operator who holds the catalogue
  # permission, so the activation path reaches the source rules.
  defp activator do
    Activator.from_auth_context(%{user_id: @activator_user_id, roles: ["PLATFORM_ADMIN"]}, true)
  end

  # ── the inventories, derived from the shipped source ─────────────────────────────────────

  # The closed set of source classes the catalogue declares:
  # `@type source_class :: :start | :step | :person`.
  defp source_classes, do: type_union(@entry_module, :source_class)

  # The closed set of side-effect classes: `@type class :: :read | ...`.
  defp side_effect_classes, do: type_union(@entry_module, :class)

  # The route attributes a platform-call node may not carry beside its call.
  defp conflicting_route_attributes,
    do: module_attribute(@rule_module, :conflicting_route_attributes)

  # The line attributes a platform-call node may not carry either: the platform
  # route plans no lines, so `entity_writes` / `module_writes` are refused beside
  # the call with the same code (T-2703). They route nothing by themselves, so
  # they are a dual_route cell, never a foreign source.
  defp platform_call_line_attributes,
    do: module_attribute(@rule_module, :platform_call_line_attributes)

  # Every attribute the dual_route family places beside the call.
  defp dual_route_attributes,
    do: conflicting_route_attributes() ++ platform_call_line_attributes()

  # The node types that merge a value from outside the graph's own trusted inputs.
  defp foreign_source_node_types, do: module_attribute(@rule_module, :foreign_source_types)

  # The union of a `@type` declaration, read from the shipped source.
  defp type_union(path, name) do
    {_ast, unions} =
      path
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {:@, _, [{:type, _, [{:"::", _, [{^name, _, _}, {:|, _, _} = union]}]}]} = node, acc ->
          {node, [union | acc]}

        node, acc ->
          {node, acc}
      end)

    case unions do
      [union | _] -> union |> union_atoms() |> Enum.uniq() |> Enum.sort()
      [] -> []
    end
  end

  defp union_atoms({:|, _, [left, right]}), do: union_atoms(left) ++ union_atoms(right)
  defp union_atoms({:|, _, [left]}), do: union_atoms(left)
  defp union_atoms(atom) when is_atom(atom), do: [atom]
  defp union_atoms(_other), do: []

  # One module attribute of the shipped source.
  defp module_attribute(path, name) do
    {_ast, values} =
      path
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {:@, _, [{^name, _, [value]}]} = node, acc -> {node, [value | acc]}
        node, acc -> {node, acc}
      end)

    case values do
      [value | _] -> value
      [] -> nil
    end
  end

  # The compiled catalogue: the entries the matrix is built from.
  defp shipped_entries, do: Catalog.list(platform_tenant?: true)

  # The SUBJECT under test: the shipped rules the matrix measures. A MUTANT
  # replaces one of them with a one-rule-apart variant, so the probe can prove
  # that a rule which stopped firing would be caught (see the mutants below).
  defp subject do
    %{
      entry_validator: &Entry.validate!/1,
      catalogue_validator: &Entry.validate_catalogue!/1,
      violations: &PlatformCalls.violations/4,
      foreign_source_graph?: &PlatformCalls.foreign_source_graph?/1,
      conflicting_route_graph?: &PlatformCalls.conflicting_route_graph?/1,
      refused_keys: &WriteTargets.refused_keys/3
    }
  end

  # The shipped entry that declares a side effect of the given class -- the
  # representative of that class in the matrix.
  defp representative_entry(side_effect_class) do
    Enum.find(shipped_entries(), fn entry ->
      Enum.any?(entry.side_effects, &(&1.class == side_effect_class))
    end)
  end

  # ── the matrix ───────────────────────────────────────────────────────────────────────────

  # A synthetic catalogue entry: one input of the given source class, one side
  # effect of the given class. It is a DECLARATION, so it is built from the
  # shipped structs -- the probe never re-implements a rule of its own.
  defp synthetic_entry(source_class, side_effect_class) do
    %Entry{
      name: "probe.#{source_class}.#{side_effect_class}",
      family: :platform,
      version: "1",
      inputs: [%Input{name: "value", type: :string, required: true, source_class: source_class}],
      outputs: [],
      permission: :TenantsManage,
      side_effects: [%SideEffect{text: "probe side effect", class: side_effect_class}],
      idempotency_key: ["value"],
      platform_tenant_only: true
    }
  end

  # The catalogue family: one synthetic entry per source class and side-effect
  # class. The subject's entry validator is the shipped `Entry.validate!/1` for
  # the real matrix and the seeded failing variant for the non-vacuity case.
  defp catalogue_observations(subject) do
    for source_class <- source_classes(),
        side_effect_class <- side_effect_classes() do
      entry = synthetic_entry(source_class, side_effect_class)

      %{
        family: "catalogue",
        key: "#{source_class}:#{side_effect_class}",
        path: "catalogue",
        value: catalogue_outcome(entry, subject.entry_validator)
      }
    end
  end

  # The malformed family: the entries the shipped validator must refuse.
  defp malformed_observations(subject) do
    base = synthetic_entry(:start, :read)
    [input | _] = base.inputs

    entries = [
      {"no_name", %{base | name: ""}},
      {"no_permission", %{base | permission: nil}},
      {"no_platform_flag", %{base | platform_tenant_only: nil}},
      {"unknown_source_class", %{base | inputs: [%{input | source_class: :g03_unknown}]}}
    ]

    for {key, entry} <- entries do
      %{
        family: "malformed",
        key: key,
        path: "catalogue",
        value: catalogue_outcome(entry, subject.entry_validator)
      }
    end ++
      [
        %{
          family: "malformed",
          key: "duplicate_name",
          path: "catalogue",
          value: catalogue_outcome([base, base], subject.catalogue_validator)
        }
      ]
  end

  # The outcome of the catalogue validator: a refusal is a raise (the shipped
  # validator refuses by raising), an acceptance is a return.
  defp catalogue_outcome(entry, validator) do
    validator.(entry)
    "accepted"
  rescue
    RuntimeError -> "refused"
  end

  # The arg-shape family: every shipped entry and every declared input, with
  # the argument's source shaped as the cell names.
  defp arg_shape_observations(ctx, subject) do
    for {shape, source} <- @arg_shapes,
        entry <- shipped_entries(),
        input <- entry.inputs do
      args = const_args(entry) |> Map.put(input.name, source)
      node = call_node(entry, args)

      %{
        family: "arg_shape",
        key: shape,
        path: "activation",
        value: activation_codes(node, [node], ctx, subject)
      }
    end
  end

  # The foreign-source family: every shipped side-effect class beside every
  # foreign source the shipped rule knows, at activation and at dispatch.
  defp foreign_source_observations(ctx, subject) do
    for foreign <- foreign_nodes(),
        side_effect_class <- side_effect_classes(),
        reduce: [] do
      acc ->
        entry = representative_entry(side_effect_class)
        node = call_node(entry, const_args(entry))
        nodes = [node, foreign.node]

        acc ++
          [
            %{
              family: "foreign_source",
              key: "#{foreign.key}:#{side_effect_class}",
              path: "activation",
              value: activation_codes(node, nodes, ctx, subject)
            },
            %{
              family: "foreign_source",
              key: "#{foreign.key}:#{side_effect_class}",
              path: "dispatch",
              value: bool_string(subject.foreign_source_graph?.(nodes))
            }
          ]
    end
  end

  # The dual-route family: every route attribute beside the platform call, at
  # activation and at dispatch. The activation must answer with the conflicting
  # route code even for a write-like entry, whose graph also carries a foreign
  # source (the T-2588 finding).
  defp dual_route_observations(ctx, subject) do
    for attribute <- dual_route_attributes(),
        side_effect_class <- side_effect_classes(),
        reduce: [] do
      acc ->
        entry = representative_entry(side_effect_class)
        node = call_node(entry, const_args(entry), %{attribute => foreign_value(attribute)})
        nodes = [node]

        acc ++
          [
            %{
              family: "dual_route",
              key: "#{attribute}:#{side_effect_class}",
              path: "activation",
              value: activation_codes(node, nodes, ctx, subject)
            },
            %{
              family: "dual_route",
              key: "#{attribute}:#{side_effect_class}",
              path: "dispatch",
              value: bool_string(subject.conflicting_route_graph?.(nodes))
            }
          ]
    end
  end

  # The write-target family: the variable a catalogue call reads is refused in
  # a completion body, unless the human task declares it as its own input.
  defp write_target_observations(subject) do
    for entry <- shipped_entries(),
        input <- entry.inputs,
        input.source_class != :person,
        reduce: [] do
      acc ->
        key = input.name
        args = const_args(entry) |> Map.put(input.name, %{"var" => key})
        call = call_node(entry, args)

        refused = subject.refused_keys.(graph_with_human(call, []), "human", %{key => 1})
        allowed = subject.refused_keys.(graph_with_human(call, [key]), "human", %{key => 1})

        acc ++
          [
            %{
              family: "write_target",
              key: "#{entry.name}:#{input.name}",
              path: "write_target",
              value: if(refused == [key], do: "refused", else: "not refused")
            },
            %{
              family: "write_target",
              key: "#{entry.name}:#{input.name}",
              path: "write_target_exception",
              value: if(allowed == [], do: "allowed", else: "refused")
            }
          ]
    end
  end

  # The foreign sources the shipped rule knows: a service task carrying one of
  # the route attributes (an inline HTTP call, a catalogue service call, a
  # script call) and every other foreign node type (a sub-process).
  defp foreign_nodes do
    routes =
      for attribute <- conflicting_route_attributes() do
        %{
          key: attribute,
          node: %Graph.Node{
            id: "foreign-#{attribute}",
            node_type: :SERVICE_TASK,
            attributes: %{attribute => foreign_value(attribute)}
          }
        }
      end

    processes =
      for node_type <- foreign_source_node_types(), node_type != :SERVICE_TASK do
        %{
          key: node_type |> to_string() |> String.downcase(),
          node: %Graph.Node{
            id: "foreign-#{node_type}",
            node_type: node_type,
            attributes: %{"definition_name" => "probe-child"}
          }
        }
      end

    routes ++ processes
  end

  defp foreign_value("endpoint"), do: "https://example.invalid/probe"
  defp foreign_value(_attribute), do: "probe-value"

  # A platform-call node.
  defp call_node(entry, args, extra_attributes \\ %{}) do
    %Graph.Node{
      id: "call",
      node_type: :SERVICE_TASK,
      attributes:
        Map.merge(
          %{"platform_call" => %{"function" => entry.name, "args" => args}},
          extra_attributes
        )
    }
  end

  # Every declared input of an entry, as a designer-fixed constant.
  defp const_args(entry) do
    Map.new(entry.inputs, fn input -> {input.name, %{"const" => "probe-#{input.name}"}} end)
  end

  # The graph of a catalogue call beside a human task, with the given
  # completer inputs.
  defp graph_with_human(call, completer_inputs) do
    human = %Graph.Node{
      id: "human",
      node_type: :HUMAN_TASK,
      attributes: %{"completer_inputs" => completer_inputs}
    }

    %Graph{nodes: [call, human]}
  end

  # The violation codes the activation reports for a node, as a stable string.
  # A code is written the way Elixir writes the atom it is, so the reviewed
  # expectation file names the very atom the shipped rule returns.
  defp activation_codes(node, nodes, ctx, subject) do
    subject.violations.(node, nodes, ctx.prefix, ctx.activator)
    |> Enum.map(& &1.code)
    |> Enum.uniq()
    |> Enum.sort()
    |> case do
      [] -> "none"
      codes -> Enum.map_join(codes, ",", &":#{&1}")
    end
  end

  defp bool_string(true), do: "true"
  defp bool_string(false), do: "false"

  # ── the reviewed expectations ────────────────────────────────────────────────────────────

  # The reviewed expectation file: one line per generated cell,
  # `family | key | expected`, where `expected` is a list of `path=value` pairs.
  defp expectations do
    @expectations
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.map(fn line ->
      case line |> String.split("|") |> Enum.map(&String.trim/1) do
        [family, key, expected] -> {{family, key}, expected_pairs(expected, line)}
        _other -> raise "malformed expectation line: #{line}"
      end
    end)
    |> Map.new()
  end

  defp expected_pairs(text, line) do
    text
    |> String.split(" ")
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn pair ->
      case String.split(pair, "=") do
        [path, value] -> {path, value}
        _other -> raise "malformed expectation in line: #{line}"
      end
    end)
    |> Map.new()
  end

  # ── the aggregate entry point ───────────────────────────────────────────────────────────

  # Fold the observations into one cell per family and key: a cell's value is
  # the SET of outcomes the shipped code gave for that key, so a cell whose
  # pairs disagree is visible.
  defp cells(observations) do
    observations
    |> Enum.group_by(&{&1.family, &1.key})
    |> Enum.map(fn {{family, key}, group} ->
      actual =
        group
        |> Enum.group_by(& &1.path)
        |> Map.new(fn {path, rows} ->
          {path, rows |> Enum.map(& &1.value) |> Enum.uniq() |> Enum.sort() |> Enum.join(",")}
        end)

      %{family: family, key: key, actual: actual}
    end)
  end

  # The cells the probe measured against the reviewed expectations. An empty
  # list means the shipped code does what the reviewed file says.
  defp violations(cells, expectations) do
    Enum.flat_map(cells, fn cell ->
      case Map.fetch(expectations, {cell.family, cell.key}) do
        :error ->
          [
            "#{cell.family} #{cell.key}: the matrix generates this cell and no reviewed expectation names it"
          ]

        {:ok, expected} ->
          missing = Map.keys(expected) -- Map.keys(cell.actual)
          extra = Map.keys(cell.actual) -- Map.keys(expected)

          wrong =
            for {path, value} <- expected,
                Map.get(cell.actual, path) != value,
                do: {path, value, Map.get(cell.actual, path)}

          Enum.map(
            missing,
            &"#{cell.family} #{cell.key}: the expectation names #{&1}, the probe measured no such path"
          ) ++
            Enum.map(
              extra,
              &"#{cell.family} #{cell.key}: the probe measured #{&1}, the expectation does not name it"
            ) ++
            Enum.map(wrong, fn {path, value, actual} ->
              "#{cell.family} #{cell.key}: #{path} is #{inspect(actual)}, the reviewed expectation is #{inspect(value)}"
            end)
      end
    end)
  end

  # The reviewed expectations that name a cell the matrix does not generate: a
  # stale line guards nothing.
  defp stale_expectations(cells, expectations) do
    generated = MapSet.new(cells, &{&1.family, &1.key})

    for {{family, key} = cell, _expected} <- expectations,
        not MapSet.member?(generated, cell),
        do: "#{family} #{key}: the reviewed expectation names a cell the matrix does not generate"
  end

  # The whole matrix of the shipped tree.
  defp matrix(ctx, subject) do
    cells(
      catalogue_observations(subject) ++
        malformed_observations(subject) ++
        arg_shape_observations(ctx, subject) ++
        foreign_source_observations(ctx, subject) ++
        dual_route_observations(ctx, subject) ++
        write_target_observations(subject)
    )
  end

  # ── the tests ────────────────────────────────────────────────────────────────────────────

  describe "the inventory the matrix is generated from" do
    test "the shipped catalogue is not empty" do
      entries = shipped_entries()

      assert entries != []
      assert Enum.all?(entries, &(&1.name != ""))
    end

    test "the closed sets of the shipped source are not empty" do
      assert source_classes() != []
      assert side_effect_classes() != []
      assert conflicting_route_attributes() != []
      assert platform_call_line_attributes() != []
      assert foreign_source_node_types() != []
    end

    test "every shipped entry declares only the known source and side-effect classes" do
      for entry <- shipped_entries() do
        for input <- entry.inputs do
          assert input.source_class in source_classes(),
                 "#{entry.name}.#{input.name} declares an unknown source class"
        end

        for effect <- entry.side_effects do
          assert effect.class in side_effect_classes(),
                 "#{entry.name} declares an unknown side-effect class"
        end
      end
    end

    test "every shipped entry passes the shipped catalogue validator" do
      for entry <- shipped_entries() do
        assert Entry.validate!(entry) == :ok, "#{entry.name} must be a valid entry"
      end

      assert Entry.validate_catalogue!(shipped_entries()) == :ok
    end

    test "the matrix is not empty and every side-effect class has a shipped entry" do
      ctx = %{prefix: platform_prefix(), activator: activator()}

      assert length(matrix(ctx, subject())) > 0

      for side_effect_class <- side_effect_classes() do
        assert representative_entry(side_effect_class) != nil,
               "the shipped catalogue declares no entry with the side-effect class #{side_effect_class}"
      end
    end
  end

  describe "the matrix against the reviewed expectations" do
    test "the shipped code does what the reviewed file says", ctx do
      cells = matrix(ctx, subject())
      expectations = expectations()

      assert violations(cells, expectations) == []
      assert stale_expectations(cells, expectations) == []
    end
  end

  describe "non-vacuity" do
    test "the seeded failing variant (a validator without the write-like rule) is caught", ctx do
      found = violations(matrix(ctx, mutant_subject(:catalogue, subject())), expectations())

      # the cells the mutant breaks are the ones the shipped validator refuses
      assert found != []

      assert Enum.all?(found, fn violation ->
               violation =~ "catalogue" and violation =~ "is \"accepted\""
             end)
    end

    test "the shipped validator refuses the seeded bad entry and accepts the benign one" do
      bad = synthetic_entry(:person, :write_tenant_registry)
      good = synthetic_entry(:step, :write_tenant_registry)

      assert catalogue_outcome(bad, &Entry.validate!/1) == "refused"
      assert catalogue_outcome(good, &Entry.validate!/1) == "accepted"
    end

    test "the mutant differs from the subject in exactly the rule under test" do
      bad = synthetic_entry(:person, :write_tenant_registry)

      assert catalogue_outcome(bad, &Entry.validate!/1) == "refused"
      assert catalogue_outcome(bad, &mutant_validate!/1) == "accepted"

      # every other shipped check still runs in the mutant
      assert catalogue_outcome(synthetic_entry(:start, :read), &mutant_validate!/1) == "accepted"

      assert catalogue_outcome(%{synthetic_entry(:start, :read) | name: ""}, &mutant_validate!/1) ==
               "refused"
    end

    # One mutant per family, each ONE RULE APART from the subject and each
    # driven through the SAME aggregate entry point. A family that does not
    # catch its own mutant is not ratcheted, and a mutant that moves another
    # family's cells would mask it.

    test "the malformed mutant (a catalogue validator without the duplicate-name rule) is caught",
         ctx do
      assert_family_mutant_caught(:malformed, ctx)
    end

    test "the arg_shape mutant (an activation without the argument-shape refusal) is caught",
         ctx do
      assert_family_mutant_caught(:arg_shape, ctx)
    end

    test "the foreign_source mutant (an activation without the foreign-source refusal) is caught",
         ctx do
      assert_family_mutant_caught(:foreign_source, ctx)
    end

    test "the dual_route mutant (an activation without the conflicting-route refusal) is caught",
         ctx do
      assert_family_mutant_caught(:dual_route, ctx)
    end

    test "the write_target mutant (a completion refusal without the catalogue call's read keys) is caught",
         ctx do
      assert_family_mutant_caught(:write_target, ctx)
    end
  end

  # A family's mutant is caught by the reviewed expectations, and it moves
  # ONLY that family's cells.
  defp assert_family_mutant_caught(family, ctx) do
    found = violations(matrix(ctx, mutant_subject(family, subject())), expectations())

    assert found != [], "the #{family} mutant is not caught by the probe"

    assert Enum.all?(found, &String.starts_with?(&1, "#{family} ")),
           "the #{family} mutant moved another family's cells: #{inspect(found)}"
  end

  # ── the mutants ───────────────────────────────────────────────────────────────────────
  #
  # Every mutant is ONE RULE APART from the subject: it is built FROM the
  # shipped rule (every other shipped refusal still runs) and it is driven
  # through the same aggregate entry point, so what catches it is the
  # reviewed expectation file and nothing else.

  # The catalogue family: the shipped catalogue validator with the write-like
  # (`person` input) rule removed.
  defp mutant_subject(:catalogue, subject) do
    %{subject | entry_validator: &mutant_validate!/1}
  end

  # The malformed family: the shipped catalogue validator with the
  # duplicate-name rule removed (every entry's own checks still run).
  defp mutant_subject(:malformed, subject) do
    %{subject | catalogue_validator: &mutant_validate_catalogue!/1}
  end

  # The arg-shape family: the shipped activation with the argument-shape
  # refusal removed -- the source of an argument is no longer checked.
  defp mutant_subject(:arg_shape, subject) do
    %{subject | violations: without_code(:platform_call_arg_source_invalid, subject.violations)}
  end

  # The foreign-source family: the shipped activation with the foreign-source
  # refusal removed, and its dispatch twin blind. The rule is one rule, at
  # its two enforcement points.
  defp mutant_subject(:foreign_source, subject) do
    %{
      subject
      | violations: without_code(:platform_call_foreign_source_refused, subject.violations),
        foreign_source_graph?: fn _nodes -> false end
    }
  end

  # The dual-route family: the shipped activation with the conflicting-route
  # refusal removed, and its dispatch twin blind.
  defp mutant_subject(:dual_route, subject) do
    %{
      subject
      | violations: without_code(:conflicting_platform_call_routes, subject.violations),
        conflicting_route_graph?: fn _nodes -> false end
    }
  end

  # The write-target family: the shipped completion refusal with the
  # catalogue call's contribution to the read set dropped -- the variable a
  # catalogue call reads is no longer refused in a completion body.
  defp mutant_subject(:write_target, subject) do
    %{subject | refused_keys: &mutant_refused_keys/3}
  end

  # The shipped activation with ONE of its refusals dropped.
  defp without_code(code, violations) do
    fn node, nodes, prefix, activator ->
      violations.(node, nodes, prefix, activator)
      |> Enum.reject(&(&1.code == code))
    end
  end

  # The shipped completion refusal without the catalogue call's read keys: the
  # refusal the shipped code gives, minus what the catalogue call reads.
  defp mutant_refused_keys(%Graph{nodes: nodes} = graph, node_id, output_variables) do
    graph
    |> WriteTargets.refused_keys(node_id, output_variables)
    |> Kernel.--(PlatformCalls.read_keys(nodes))
  end

  defp mutant_refused_keys(_graph, _node_id, _output_variables), do: []

  # The seeded failing variant of the SUBJECT: the shipped validator with the
  # write-like/`person` rule removed. It is built FROM the shipped validator --
  # every other shipped check still runs -- so the probe's catalogue rule has
  # to catch it.
  defp mutant_validate!(%Entry{} = entry) do
    Entry.validate!(%{entry | inputs: Enum.reject(entry.inputs, &(&1.source_class == :person))})
  end

  # The shipped catalogue validator with the duplicate-name rule removed: every
  # entry's own checks still run.
  defp mutant_validate_catalogue!(entries) when is_list(entries) do
    Enum.each(entries, &Entry.validate!/1)
    :ok
  end
end
