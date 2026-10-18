defmodule Letflow.Engine.ContentionTest do
  @moduledoc """
  GH #2706 / PR-2 (design section 6, T2): `Letflow.Engine.Contention.contention_code/1` classifies
  exactly the two retryable lock errors; the lock-timeout value and its test override.
  """

  use ExUnit.Case, async: true

  alias Letflow.Engine.Contention

  defp pg_error(code), do: %Postgrex.Error{postgres: %{code: code, message: "secret text"}}

  describe "T2: contention_code/1" do
    test "55P03 and 40P01 are contention" do
      assert Contention.contention_code(pg_error(:lock_not_available)) ==
               {:ok, :lock_not_available}

      assert Contention.contention_code(pg_error(:deadlock_detected)) ==
               {:ok, :deadlock_detected}
    end

    test "everything else is :error" do
      assert Contention.contention_code(pg_error(:unique_violation)) == :error
      assert Contention.contention_code(pg_error(:query_canceled)) == :error
      assert Contention.contention_code(%DBConnection.ConnectionError{message: "x"}) == :error
      assert Contention.contention_code(%RuntimeError{message: "x"}) == :error
      assert Contention.contention_code(:lock_not_available) == :error
      assert Contention.contention_code(nil) == :error
    end
  end

  describe "lock_timeout_ms/0 and lock_timeout_setting/0" do
    test "5 s by default, as text for the bound parameter" do
      assert Contention.lock_timeout_ms() == 5_000
      assert Contention.lock_timeout_setting() == "5000ms"
    end

    test "a positive integer process-local override applies (test-seam builds), nothing else does" do
      Process.put(:contention_lock_timeout_ms_override, 300)
      assert Contention.lock_timeout_ms() == 300
      assert Contention.lock_timeout_setting() == "300ms"

      for bad <- [0, -5, "300", 1.5, nil] do
        Process.put(:contention_lock_timeout_ms_override, bad)
        assert Contention.lock_timeout_ms() == 5_000
      end

      Process.delete(:contention_lock_timeout_ms_override)
      assert Contention.lock_timeout_ms() == 5_000
    end

    test "another process does not see the override" do
      Process.put(:contention_lock_timeout_ms_override, 300)
      assert Task.async(fn -> Contention.lock_timeout_ms() end) |> Task.await() == 5_000
    end
  end
end
