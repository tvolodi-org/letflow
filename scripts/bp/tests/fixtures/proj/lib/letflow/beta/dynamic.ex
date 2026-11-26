defmodule Beta.Dynamic do
  @moduledoc "A fixture module: a dynamic dispatch and a function nobody calls."

  def dispatch(mod, fun, args) do
    apply(mod, fun, args)
  end

  def dispatch_line(operation, args) do
    apply(Beta.LineEvents, operation, args)
  end
end
