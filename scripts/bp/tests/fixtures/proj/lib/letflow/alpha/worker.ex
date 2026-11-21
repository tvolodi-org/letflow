defmodule Alpha.Worker do
  @moduledoc "A fixture module: one function a caller uses, one only a test uses, one nobody uses."

  def used_by_consumer do
    :used
  end

  def only_in_test do
    :test
  end

  def nobody_calls do
    :nobody
  end

  def with_default(a, b \\ 2), do: a + b

  defdelegate delegated, to: Alpha.Remote

  defp private_helper, do: :private
end
