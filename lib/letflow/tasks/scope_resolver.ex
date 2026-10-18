defmodule Letflow.Tasks.ScopeResolver do
  @moduledoc """
  The resource scope of a task (REQ-518 PR 2d / GH #2535; design
  `lib/letflow/design/req518-compiler-scope-filter.md` C.2, decision 0051 D9).

  `task_scope/1` is the `{:resolver, {Letflow.Tasks.ScopeResolver, :task_scope}}` function the
  route walk (`Letflow.Api.RouteScope`) requires to be exported for the five task routes that
  resolve a single task. It is pure (no database): the task's `scope_node_id` is the scope.
  """

  alias Letflow.Api.Scope
  alias Letflow.Engine.Task

  @doc """
  `{:node, id}` for a task whose `scope_node_id` is a non-empty string; `:unresolvable` for a
  task with no scope node (fail closed: only a principal holding the route permission
  tenant-wide reaches such a task) and for anything that is not a task.
  """
  @spec task_scope(Task.t() | term()) :: Scope.resource_scope()
  def task_scope(%Task{scope_node_id: node_id}) when is_binary(node_id) and node_id != "",
    do: {:node, node_id}

  def task_scope(_no_node_or_not_a_task), do: :unresolvable
end
