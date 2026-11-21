defmodule Alpha.WorkerTest do
  use ExUnit.Case

  test "a function only a test calls" do
    assert Alpha.Worker.only_in_test() == :test
  end
end
