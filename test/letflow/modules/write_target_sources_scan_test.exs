defmodule Letflow.Modules.WriteTargetSourcesScanTest do
  @moduledoc """
  T-2430 (audit T-2429), the closing scan of the rule "a `module_writes` target comes from
  engine-owned data, never from a variable the completer of a human task can set".

  The engine half is `Letflow.Engine.WriteTargets` (a completion output key that any `module_writes`
  `var` argument of the pinned definition reads is refused, 422 `output_refused`, unless the completing
  node declares it in `completer_inputs` or in its own `form_schema` properties). This scan walks the GENERATED `priv/modules/*/pack.json`
  (the args are built by closures such as `posting_args` in the generators, so the `.exs` is not
  read) and fails when a pack passes a target through a source the engine rule does not cover:

    * every arg source is exactly `%{"var" => string}` or `%{"const" => _}` (any other shape is a
      source the engine rule cannot see);
    * every `var` key is refused to the completer by `WriteTargets.refused_keys/3` at its own node;
    * no node declares an input (`completer_inputs`, `form_schema` property) over a key a
      `module_writes` line reads, except the pairs in `@completer_provided` (explicit and reviewed;
      today the maintenance `work_done` text only: every other pack supplies its write inputs at
      instance start from module code).

  Failing examples (WTS-3): the real nodes of the stock handlers `post_document`, `post_count`,
  `reverse_document` and the assets-owned change of kind with the stock handler `post_kind_change_out`,
  each with one argument rewired to a source the rule cannot see, or declared completer-provided.
  """

  use ExUnit.Case, async: true

  alias Letflow.Definitions.Graph
  alias Letflow.Engine.WriteTargets
  alias Letflow.PlatformFunctions.Catalog
  alias Letflow.PlatformFunctions.Entry

  @root Path.expand("../../..", __DIR__)

  # {pack, process_key, node_id, key}: a key a person supplies at that node through the completion
  # body. Adding a row is a reviewed security decision (the handler must validate it itself).
  @completer_provided [
    # REQ-897: the technician types the work done in the task form; record_done stores the text
    {"maintenance", "maintenance_work_order", "maintenance_work", "work_done"}
  ]

  defp packs do
    for path <- Path.wildcard(Path.join([@root, "priv", "modules", "*", "pack.json"])) do
      {path |> Path.dirname() |> Path.basename(), path |> File.read!() |> Jason.decode!()}
    end
  end

  defp nodes_with_writes(pack) do
    for definition <- Map.get(pack, "definitions", []),
        node <- get_in(definition, ["graph", "nodes"]) || [],
        writes = get_in(node, ["attributes", "module_writes"]),
        is_list(writes) and writes != [],
        do: {definition, node, writes}
  end

  # The violations of ONE definition (a decoded pack entry), as strings.
  #
  # T-2588 (pilot gap G2): the scan covers the `platform_call` steps too. A
  # catalogue call reads its arguments from the start variables or from an earlier
  # platform step's output, never from a person, so a WRITE-LIKE call reads no
  # variable the completer of a human task may write -- the same rule as a module
  # handler's write target, carried over by source class.
  defp violations(definition, pack_name) do
    {:ok, graph} = Graph.from_map(definition["graph"])

    module =
      for node <- definition["graph"]["nodes"],
          writes = get_in(node, ["attributes", "module_writes"]),
          is_list(writes),
          line <- writes,
          {arg, source} <- line["args"] || %{},
          violation <-
            source_violations(definition, pack_name, graph, node, line, arg, source),
          do: violation

    platform =
      for node <- definition["graph"]["nodes"],
          call = get_in(node, ["attributes", "platform_call"]),
          is_map(call),
          {arg, source} <- call["args"] || %{},
          violation <-
            platform_source_violations(definition, pack_name, graph, node, call, arg, source),
          do: violation

    module ++ platform
  end

  # The source rule of one `platform_call` argument: exactly %{"var" => key} or
  # %{"const" => _}, and -- for a write-like call -- a var the engine refuses to the
  # completer at its own node.
  defp platform_source_violations(definition, pack, graph, node, call, arg, source) do
    where = "#{pack}/#{definition["process_key"]}/#{node["id"]}/platform_call.#{arg}"

    case source do
      %{"const" => _} = only when map_size(only) == 1 ->
        []

      %{"var" => key} = only when is_binary(key) and map_size(only) == 1 ->
        cond do
          not write_like?(call) ->
            []

          refused_at_every_human_task?(graph, key) ->
            []

          true ->
            ["#{where}: var #{inspect(key)} is completer-writable at its own node"]
        end

      other ->
        ["#{where}: source #{inspect(other)} is not %{\"var\" => key} or %{\"const\" => _}"]
    end
  end

  # The key is refused to the completer at EVERY human task of the graph: a
  # human task that declares the key as its own input could write it, and the
  # call would read what the person wrote.
  defp refused_at_every_human_task?(graph, key) do
    graph.nodes
    |> Enum.filter(&(&1.node_type == :HUMAN_TASK))
    |> Enum.all?(&(WriteTargets.refused_keys(graph, &1.id, %{key => 1}) == [key]))
  end

  # A call is write-like when its catalogue entry declares a side effect that is
  # more than a read. An unknown function is treated as write-like: the
  # activation refuses it anyway, and the scan must not be the softer of the two.
  defp write_like?(call) do
    case Catalog.fetch(call["function"]) do
      {:ok, entry} -> Entry.write_like?(entry)
      {:error, :not_found} -> true
    end
  end

  defp source_violations(definition, pack, graph, node, line, arg, source) do
    where = "#{pack}/#{definition["process_key"]}/#{node["id"]}/#{line["handler"]}.#{arg}"

    case source do
      %{"const" => _} = only when map_size(only) == 1 ->
        []

      %{"var" => key} = only when is_binary(key) and map_size(only) == 1 ->
        cond do
          WriteTargets.refused_keys(graph, node["id"], %{key => 1}) == [key] ->
            []

          Enum.member?(@completer_provided, {pack, definition["process_key"], node["id"], key}) ->
            []

          true ->
            ["#{where}: var #{inspect(key)} is completer-writable at its own node"]
        end

      other ->
        ["#{where}: source #{inspect(other)} is not %{\"var\" => key} or %{\"const\" => _}"]
    end
  end

  test "WTS-1 the generated packs have module_writes lines to scan (the scan is not vacuous)" do
    handlers =
      for {_pack, p} <- packs(),
          {_d, _n, writes} <- nodes_with_writes(p),
          line <- writes,
          do: line["handler"]

    for handler <- ~w(post_document post_count reverse_document post_kind_change_out) do
      assert handler in handlers, "no pack node calls #{handler}"
    end
  end

  test "WTS-2 every module_writes argument of every pack comes from engine-owned data" do
    found =
      for {name, pack} <- packs(),
          definition <- Map.get(pack, "definitions", []),
          v <- violations(definition, name),
          do: v

    assert found == []
  end

  test "WTS-2b a node input over a key a module_writes line reads is a listed decision" do
    declared =
      for {name, pack} <- packs(),
          definition <- Map.get(pack, "definitions", []),
          {:ok, graph} = Graph.from_map(definition["graph"]),
          read = WriteTargets.write_read_keys(graph),
          node <- graph.nodes,
          key <- WriteTargets.completer_inputs(node),
          key in read,
          do: {name, definition["process_key"], node.id, key}

    assert Enum.sort(declared) == Enum.sort(@completer_provided)
  end

  test "WTS-4 (T-2444) every module_writes definition is module-only at start, and has no foreign source" do
    found =
      for {name, pack} <- packs(),
          definition <- Map.get(pack, "definitions", []),
          {:ok, graph} = Graph.from_map(definition["graph"]),
          WriteTargets.module_writes?(graph),
          do: {name, definition["process_key"], graph}

    # not vacuous: the stock and assets documents, openings, reversals, counts and the maintenance order
    keys = Enum.map(found, fn {_p, key, _g} -> key end)

    for key <- ~w(stock_receipt stock_opening stock_reversal stock_count_posting assets_commission
                  assets_reversal maintenance_work_order) do
      assert key in keys, "#{key} is not seen as module-only"
    end

    # a write definition has no node that merges a value from outside (the start variables are
    # module-built, a completion body is refused by key): a service, script or sub-process node would
    # add a source `WriteTargets` cannot see (route map T-2445, C6, C7, S2)
    for {pack, key, graph} <- found,
        node <- graph.nodes,
        to_string(node.node_type) in ~w(SERVICE_TASK SCRIPT_TASK SUB_PROCESS) do
      flunk("#{pack}/#{key}/#{node.id}: #{node.node_type} in a module_writes definition")
    end
  end

  describe "WTS-3 failing examples: the scan names each rewired argument" do
    defp real(pack, key, node, handler) do
      definition =
        packs()
        |> Map.new()
        |> Map.fetch!(pack)
        |> Map.fetch!("definitions")
        |> Enum.find(&(&1["process_key"] == key))

      assert definition, "no #{pack}/#{key}"

      line =
        definition["graph"]["nodes"]
        |> Enum.find(&(&1["id"] == node))
        |> then(&get_in(&1, ["attributes", "module_writes"]))

      assert Enum.any?(line, &(&1["handler"] == handler)), "no #{handler} on #{key}/#{node}"
      definition
    end

    defp rewire(definition, node_id, handler, arg, source) do
      update_in(definition, ["graph", "nodes"], fn nodes ->
        Enum.map(nodes, fn
          %{"id" => ^node_id} = node ->
            update_in(node, ["attributes", "module_writes"], fn lines ->
              Enum.map(lines, fn
                %{"handler" => ^handler} = line -> put_in(line, ["args", arg], source)
                line -> line
              end)
            end)

          node ->
            node
        end)
      end)
    end

    defp declare(definition, node_id, keys) do
      update_in(definition, ["graph", "nodes"], fn nodes ->
        Enum.map(nodes, fn
          %{"id" => ^node_id} = node -> put_in(node, ["attributes", "completer_inputs"], keys)
          node -> node
        end)
      end)
    end

    @examples [
      {"stock", "stock_receipt", "post", "post_document", "posting"},
      {"stock", "stock_count_posting", "post", "post_count", "posting"},
      {"stock", "stock_reversal", "reverse", "reverse_document", "document_id"},
      {"assets", "assets_kind_change", "post", "post_kind_change_out", "posting"}
    ]

    for {pack, key, node, handler, arg} <- @examples do
      test "#{handler}: a source shape the engine rule cannot see is reported" do
        d = real(unquote(pack), unquote(key), unquote(node), unquote(handler))
        assert violations(d, unquote(pack)) == []

        for bad <- [%{"variable" => unquote(arg)}, %{"var" => [unquote(arg)]}, "posting", nil] do
          rewired = rewire(d, unquote(node), unquote(handler), unquote(arg), bad)
          assert [message] = violations(rewired, unquote(pack))
          assert message =~ "#{unquote(handler)}.#{unquote(arg)}"
        end
      end

      test "#{handler}: a var the completing node declares completer-provided is reported" do
        d = real(unquote(pack), unquote(key), unquote(node), unquote(handler))
        source = get_in(d, ["graph", "nodes"]) |> Enum.find(&(&1["id"] == unquote(node)))

        var =
          source["attributes"]["module_writes"]
          |> Enum.find(&(&1["handler"] == unquote(handler)))
          |> get_in(["args", unquote(arg), "var"])

        declared = declare(d, unquote(node), [var])
        assert Enum.any?(violations(declared, unquote(pack)), &(&1 =~ "completer-writable"))
      end
    end
  end

  describe "T-2588: a platform_call step reads no variable a person may write" do
    defp platform_call_fixture(name) do
      [@root, "test", "fixtures", "platform_call", name]
      |> Path.join()
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("definitions")
      |> hd()
    end

    test "the fixed form (the call reads engine-owned data) passes the scan" do
      assert violations(platform_call_fixture("fixed_pack.json"), "platform") == []
    end

    test "the hole form (the human task may write the call's read key) is reported by the scan" do
      found = violations(platform_call_fixture("hole_pack.json"), "platform")
      assert [message] = found
      assert message =~ "platform_call"
      assert message =~ "slug"
      assert message =~ "completer-writable"
    end

    test "the scan is not vacuous: the fixed fixture really carries a platform_call" do
      definition = platform_call_fixture("fixed_pack.json")

      assert [node] =
               for(
                 node <- definition["graph"]["nodes"],
                 call = get_in(node, ["attributes", "platform_call"]),
                 is_map(call),
                 do: node
               )

      assert get_in(node, ["attributes", "platform_call", "function"]) == "tenant.create"
    end
  end

  describe "t2299_hole: a pack whose handlers read the target from a completer-writable variable" do
    # T-2494 (D-170): record_done / record_closed read the work order from the instance variable
    # `maintenance_order_id`. The hole form lets the completer write it (the node declares it a
    # completer input); the fixed form takes it from engine-owned data (supplied at instance start
    # by module code, refused to the completer by `WriteTargets`).
    defp fixture_definition(name) do
      [@root, "test", "fixtures", "t2299_hole", name]
      |> Path.join()
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("definitions")
      |> hd()
    end

    test "t2299_hole: the hole form is reported by the scan, naming the variable and the node" do
      found = violations(fixture_definition("hole_pack.json"), "maintenance")
      assert [message] = found
      assert message =~ "maintenance_work"
      assert message =~ "maintenance_order_id"
      assert message =~ "completer-writable"
    end

    test "t2299_hole: the fixed form (target from engine-owned data) passes the scan" do
      assert violations(fixture_definition("fixed_pack.json"), "maintenance") == []
    end
  end
end
