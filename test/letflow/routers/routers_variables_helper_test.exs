defmodule Letflow.Routers.RoutersVariablesHelperTest do
  @moduledoc """
  GH #2587 / REQ-499 PR B3 (decision 0054 CO-1, INV-2): every router response boundary that
  emits an instance variable map or an instance event payload goes through the ONE shaping
  helper, `Letflow.Api.Response.public_variables/1` / `public_event_payload/2`.

  A static AST scan over `lib/letflow/routers/**`:

    * rule 1: a map entry whose key is the literal `"variables"` must be a call to
      `Response.public_variables/1`;
    * rule 2: a map entry whose key is the literal `"payload"` must be a call to
      `Response.public_event_payload/2` (or the platform-event shaper
      `shape_platform_event_payload/3`, which shapes platform events, not instance events);
    * rule 3: a `.payload` field read may appear only in the files of `@payload_readers`
      (a new reader must be added here deliberately, with its shaping reviewed).

  Non-vacuity: synthetic offending and conforming snippets, plus a floor on the number of
  real guarded sites so a rename of a router cannot silently empty the scan.
  """

  use ExUnit.Case, async: true

  @routers_glob "lib/letflow/routers/**/*.ex"
  @payload_readers ["lib/letflow/routers/instances.ex", "lib/letflow/routers/promotions.ex"]

  # -- scan --------------------------------------------------------------------------------

  # Returns %{violations: [...], guarded: n, payload_reads: n}
  defp scan_source(source) do
    ast = Code.string_to_quoted!(source)

    {_ast, acc} =
      Macro.prewalk(ast, %{violations: [], guarded: 0, payload_reads: 0}, fn
        {:%{}, _meta, entries} = node, acc when is_list(entries) ->
          {node, Enum.reduce(entries, acc, &check_entry/2)}

        {{:., _, [_target, :payload]}, _, []} = node, acc ->
          {node, %{acc | payload_reads: acc.payload_reads + 1}}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp check_entry({"variables", value}, acc) do
    if call_to?(value, :public_variables, 1),
      do: %{acc | guarded: acc.guarded + 1},
      else: %{acc | violations: [{"variables", Macro.to_string(value)} | acc.violations]}
  end

  defp check_entry({"payload", value}, acc) do
    if call_to?(value, :public_event_payload, 2) or
         call_to?(value, :shape_platform_event_payload, 3),
       do: %{acc | guarded: acc.guarded + 1},
       else: %{acc | violations: [{"payload", Macro.to_string(value)} | acc.violations]}
  end

  defp check_entry(_other, acc), do: acc

  defp call_to?({{:., _, [{:__aliases__, _, aliases}, fun]}, _, args}, fun, arity),
    do: List.last(aliases) == :Response and length(args) == arity

  defp call_to?({fun, _, args}, fun, arity) when is_atom(fun) and is_list(args),
    do: length(args) == arity

  defp call_to?(_other, _fun, _arity), do: false

  # -- real routers --------------------------------------------------------------------------

  test "every `\"variables\"` and `\"payload\"` response entry in the routers is shaped" do
    files = Path.wildcard(@routers_glob)
    assert files != [], "no router files found: the scan would be vacuous"

    results = for file <- files, do: {file, scan_source(File.read!(file))}

    violations =
      for {file, %{violations: v}} <- results, violation <- v, do: {file, violation}

    assert violations == [],
           "router response entries emitting variables/payload without the shared helper: " <>
             inspect(violations)

    guarded = results |> Enum.map(fn {_f, r} -> r.guarded end) |> Enum.sum()

    # instances.ex: instance_map, render_reconstruct, history item; tasks.ex: completion;
    # promotions.ex: platform event payload.
    assert guarded >= 5, "scan found only #{guarded} guarded sites; a router moved?"

    for {file, r} <- results, r.payload_reads > 0 do
      assert file in @payload_readers,
             "#{file} reads `.payload`; add it to @payload_readers with its shaping reviewed"
    end
  end

  test "the known real sites are present (positive control on the real tree)" do
    instances = scan_source(File.read!("lib/letflow/routers/instances.ex"))
    tasks = scan_source(File.read!("lib/letflow/routers/tasks.ex"))

    assert instances.guarded >= 3
    assert tasks.guarded >= 1
  end

  # -- synthetic non-vacuity -----------------------------------------------------------------

  test "a raw variables entry is flagged" do
    r = scan_source(~S|defp m(p), do: %{"variables" => p.variables}|)
    assert [{"variables", _}] = r.violations
  end

  test "a raw payload entry is flagged" do
    r = scan_source(~S|defp m(e), do: %{"payload" => e.payload}|)
    assert [{"payload", _}] = r.violations
    assert r.payload_reads == 1
  end

  test "a helper-shaped variables entry is accepted" do
    r = scan_source(~S|defp m(p), do: %{"variables" => Response.public_variables(p.variables)}|)
    assert r.violations == []
    assert r.guarded == 1
  end

  test "a helper-shaped payload entry is accepted" do
    r =
      scan_source(
        ~S|defp m(e), do: %{"payload" => Response.public_event_payload(e.event_type, e.payload)}|
      )

    assert r.violations == []
    assert r.guarded == 1
  end

  test "a call to a lookalike function with the same arity is not accepted" do
    r = scan_source(~S|defp m(p), do: %{"variables" => Other.public_variables(p.variables)}|)
    assert [{"variables", _}] = r.violations
  end

  # -- the helper itself uses the single reserved-key predicate ---------------------------------

  test "public_variables/1 is exactly VariableMerge.drop_reserved/1 (no second predicate)" do
    vars = %{"a" => 1, "_sys" => 1, "_sys.r" => "x", "_system" => 2, "n" => %{"_sys.x" => 1}}

    assert Letflow.Api.Response.public_variables(vars) ==
             Letflow.Engine.VariableMerge.drop_reserved(vars)

    assert Letflow.Api.Response.public_variables(vars) ==
             %{"a" => 1, "_system" => 2, "n" => %{"_sys.x" => 1}}

    refute File.read!("lib/letflow/api/response.ex") =~ ~s|"_sys|
  end
end
