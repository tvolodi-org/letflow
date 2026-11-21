defmodule Alpha.Remote do
  @moduledoc "A fixture module: nothing in the source calls it, only the xref graph does."

  def only_in_graph do
    :graph
  end

  def delegated do
    :delegated
  end
end
