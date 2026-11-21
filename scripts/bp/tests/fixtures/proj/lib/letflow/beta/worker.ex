defmodule Beta.Worker do
  @moduledoc "A fixture module: a behaviour implementation and a public function nobody calls."

  use GenServer

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call(:ping, _from, state), do: {:reply, :pong, state}

  def orphan, do: :orphan
end
