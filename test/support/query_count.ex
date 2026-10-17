defmodule Letflow.TestSupport.QueryCount do
  @moduledoc """
  Counts the `Letflow.Repo` statements a function issues in the calling process
  (GH #2739, T-9).

  Attaches a telemetry handler to `[:letflow, :repo, :query]`, counts only events
  emitted from the test process (so concurrent background work is not counted)
  and detaches in an `after`. Returns `{result, statement_count}`.

  Used to pin "equal database work per request shape" (INV-5, gh2700 Q7): a
  denied-type request must issue exactly as many statements as the same request
  in a world where the type does not exist.

  Test-only; compiled under `elixirc_paths(:test)`, never referenced from `lib/`.
  """

  @doc "Runs `fun` and returns `{fun_result, repo_statement_count}`."
  @spec count_statements((-> result)) :: {result, non_neg_integer()} when result: var
  def count_statements(fun) when is_function(fun, 0) do
    counter = :counters.new(1, [])
    handler = "query-count-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler,
        [:letflow, :repo, :query],
        fn _event, _measurements, _meta, _config ->
          if self() == test_pid, do: :counters.add(counter, 1, 1)
        end,
        nil
      )

    try do
      result = fun.()
      {result, :counters.get(counter, 1)}
    after
      :telemetry.detach(handler)
    end
  end
end
