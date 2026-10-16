defmodule Letflow.Engine.ServiceTaskPrepareHelpersNoLockTest do
  @moduledoc """
  GH #2587 / REQ-499 PR C2, C-5 (design 7.3, the D-B.2 grep): the helpers that
  `do_persist_service_task_advance/10` runs BEFORE its nested Multi only compute. No row lock
  (`FOR UPDATE`, `lock(`) may be reachable from `prepare_timer_arms/4`,
  `prepare_service_task_dispatch_abort_on_empty_url/6` and
  `prepare_sub_process_children_for_completion/8`, otherwise the type locks taken inside the Multi
  would no longer follow every other lock of the apply in a known order.

  The scan covers the helper bodies AND the private functions they call by name (a bounded,
  transitive text closure). A synthetic non-vacuity check proves the scanner finds a lock hidden
  one call deep, and finds nothing in a clean source.
  """

  use ExUnit.Case, async: true

  @engine Path.expand("../../../lib/letflow/engine.ex", __DIR__)
  @roots [
    "prepare_timer_arms",
    "prepare_service_task_dispatch_abort_on_empty_url",
    "prepare_sub_process_children_for_completion"
  ]
  @lock_pattern ~r/FOR UPDATE|\block\(/

  # Bodies of every `defp name(...)` clause group, keyed by name: from the first clause head to
  # the next top-level `defp`/`def` of a DIFFERENT name. Comment lines and the attribute blocks
  # (`@doc`, `@spec`, ...) that precede the NEXT definition are not part of a body.
  defp function_bodies(source) do
    lines = String.split(source, "\n")

    {groups, current, _detached} =
      Enum.reduce(lines, {[], nil, false}, fn line, {groups, current, detached} ->
        cond do
          match = Regex.run(~r/^  defp? ([a-z_0-9?!]+)\(/, line) ->
            [_, name] = match

            if current != nil and elem(current, 0) == name,
              do: {groups, {name, [line | elem(current, 1)]}, false},
              else: {push(groups, current), {name, [line]}, false}

          Regex.match?(~r/^  (#|@)/, line) ->
            {groups, current, true}

          detached or current == nil ->
            {groups, current, detached}

          true ->
            {groups, {elem(current, 0), [line | elem(current, 1)]}, false}
        end
      end)

    groups |> push(current) |> Map.new()
  end

  defp push(groups, nil), do: groups
  defp push(groups, {name, rev}), do: [{name, rev |> Enum.reverse() |> Enum.join("\n")} | groups]

  # `root` plus every private function of the same module whose name its body mentions followed
  # by `(`, transitively.
  defp reachable(bodies, root) do
    walk([root], bodies, MapSet.new())
  end

  defp walk([], _bodies, seen), do: seen

  defp walk([name | rest], bodies, seen) do
    if MapSet.member?(seen, name) or not Map.has_key?(bodies, name) do
      walk(rest, bodies, seen)
    else
      body = Map.fetch!(bodies, name)

      callees =
        for other <- Map.keys(bodies),
            other != name,
            String.contains?(body, other <> "("),
            do: other

      walk(callees ++ rest, bodies, MapSet.put(seen, name))
    end
  end

  defp locking_functions(source, roots) do
    bodies = function_bodies(source)

    for root <- roots,
        name <- reachable(bodies, root),
        Regex.match?(@lock_pattern, Map.fetch!(bodies, name)),
        do: {root, name}
  end

  test "no row lock is reachable from the prepare helpers of the service apply" do
    source = File.read!(@engine)
    bodies = function_bodies(source)

    # the roots exist (a rename would silently make this test vacuous)
    for root <- @roots, do: assert(Map.has_key?(bodies, root), root)

    assert locking_functions(source, @roots) == []
  end

  test "non-vacuity: the scanner finds a lock one call deep and nothing in a clean source" do
    dirty = """
    defmodule Synthetic do
      defp prepare_timer_arms(a, b, c, d) do
        helper(a)
      end

      defp helper(a) do
        from(t in T) |> lock("FOR UPDATE") |> Repo.all()
      end

      defp unrelated(a), do: a
    end
    """

    clean = """
    defmodule Synthetic do
      defp prepare_timer_arms(a, b, c, d) do
        helper(a)
      end

      defp helper(a), do: a
    end
    """

    assert locking_functions(dirty, ["prepare_timer_arms"]) == [
             {"prepare_timer_arms", "helper"}
           ]

    assert locking_functions(clean, ["prepare_timer_arms"]) == []
  end
end
