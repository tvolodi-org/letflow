defmodule Alpha.Consumer do
  @moduledoc "A fixture module: it calls one function of Alpha.Worker through an alias."

  alias Alpha.Worker

  def run do
    Worker.used_by_consumer()
  end
end
