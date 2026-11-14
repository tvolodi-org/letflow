defmodule Letflow.ErrorCapture.SignatureTest do
  @moduledoc "T-1951 EC-1: the pure signature: no values, stable across messages, split by route/method."

  use ExUnit.Case, async: true

  alias Letflow.ErrorCapture.Signature

  defp entry(overrides \\ %{}) do
    Map.merge(
      %{
        source: "server",
        kind: "exception",
        method: "GET",
        route: "/api/v1/x/:id",
        error_type: "KeyError",
        top_frame: "Letflow.Foo.bar/1",
        status: 500
      },
      overrides
    )
  end

  test "EC-1 same type, frame, route and method give one signature whatever the message" do
    stack = [{Letflow.Foo, :bar, 1, [file: ~c"a.ex", line: 3]}]
    e1 = %KeyError{key: :a, term: %{secret: 1}}
    e2 = %KeyError{key: :b, term: %{other: 2}}

    assert Signature.error_type(:error, e1, stack) == Signature.error_type(:error, e2, stack)

    assert Signature.compute(entry()) == Signature.compute(entry())
    refute Signature.compute(entry()) == Signature.compute(entry(%{route: "/api/v1/y"}))
    refute Signature.compute(entry()) == Signature.compute(entry(%{method: "POST"}))
  end

  test "EC-1 the status counts only for a plain answer" do
    a = entry(%{status: 500})
    b = entry(%{status: 502})
    assert Signature.compute(a) == Signature.compute(b)

    h500 = entry(%{kind: "http_status", error_type: "http_500", status: 500})
    h502 = entry(%{kind: "http_status", error_type: "http_500", status: 502})
    refute Signature.compute(h500) == Signature.compute(h502)
  end

  test "EC-1 a frame with an argument LIST gives its arity and never the values" do
    stack = [{Letflow.Foo, :bar, ["secret_value"], [file: ~c"a.ex", line: 3]}]
    assert Signature.top_frame(stack) == "Letflow.Foo.bar/1"
    refute Signature.top_frame(stack) =~ "secret_value"
  end

  test "EC-1 the first Letflow frame is preferred; an empty stack is unknown" do
    stack = [
      {Enum, :map, 2, []},
      {Letflow.Foo, :baz, 2, []},
      {Letflow.Other, :x, 0, []}
    ]

    assert Signature.top_frame(stack) == "Letflow.Foo.baz/2"
    assert Signature.top_frame([{Enum, :map, 2, []}]) == "Enum.map/2"
    assert Signature.top_frame([]) == "unknown"
    assert Signature.top_frame(:nope) == "unknown"
  end

  test "EC-1 throw and exit have their own types" do
    assert Signature.error_type(:throw, :x, []) == "throw"
    assert Signature.error_type(:exit, :x, []) == "exit"
    assert Signature.error_type(:error, :badarg, []) == "ArgumentError"
  end
end
