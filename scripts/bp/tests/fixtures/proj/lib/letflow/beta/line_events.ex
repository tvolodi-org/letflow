defmodule Beta.LineEvents do
  @moduledoc "A fixture module: the target of a dynamic dispatch with an unknown function."

  def record(prefix, summary), do: {prefix, summary}

  def unused_helper, do: :unused
end
