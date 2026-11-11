defmodule Letflow.SignupAwaitMailTest do
  # Shares the global mail task supervisor, so it cannot run beside other sign-up tests.
  use ExUnit.Case, async: false

  alias Letflow.Test.SignupHelpers

  @supervisor Letflow.LoginDiscovery.TaskSupervisor

  defp start_held do
    parent = self()

    {:ok, pid} =
      Task.Supervisor.start_child(@supervisor, fn ->
        receive do
          :release -> send(parent, :released)
        end
      end)

    pid
  end

  test "A1 returns :ok at once when no child runs" do
    assert SignupHelpers.await_mail() == :ok
  end

  test "A2 times out (bounded) while a child is still running" do
    pid = start_held()
    assert SignupHelpers.await_mail(50) == :timeout
    send(pid, :release)
    assert SignupHelpers.await_mail() == :ok
  end

  @tag timeout: 20_000
  test "A3 default bound outlasts the old 3 s limit and returns on the child exit event" do
    pid = start_held()
    Process.send_after(pid, :release, 3_400)
    assert SignupHelpers.await_mail() == :ok
    assert_received :released
  end
end
