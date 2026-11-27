defmodule Letflow.Obs.QueryLogFilterTest do
  use ExUnit.Case, async: true

  alias Letflow.Obs.QueryLogFilter

  defp event(text), do: %{msg: {:string, [text]}, level: :debug, meta: %{}}

  test "a write statement keeps its SQL and loses its parameters" do
    ev = event("QUERY OK db=1ms\nINSERT INTO \"t\" (\"a\") VALUES ($1) [\"owner@example.com\"]")
    {:string, out} = QueryLogFilter.filter(ev, []).msg
    out = IO.iodata_to_binary(out)
    assert out =~ "INSERT INTO"
    assert out =~ "[redacted]"
    refute out =~ "owner@example.com"
  end

  test "a select loses its parameters, canary included" do
    sel = event("QUERY OK source=\"t\" db=1ms\nSELECT 1 WHERE a = $1 [\"canary@example.com\"]")
    {:string, out} = QueryLogFilter.filter(sel, []).msg
    out = IO.iodata_to_binary(out)
    assert out =~ "SELECT 1 WHERE a = $1 [redacted]"
    assert out =~ "source="
    refute out =~ "canary"
  end

  test "a non-query message is left alone" do
    plain = event("hello INSERT [\"x\"]")
    assert QueryLogFilter.filter(plain, []) == plain
    assert QueryLogFilter.filter(%{msg: {:report, %{}}}, []) == %{msg: {:report, %{}}}
  end
end
