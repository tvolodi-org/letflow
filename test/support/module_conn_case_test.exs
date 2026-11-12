defmodule Letflow.ModuleConnCaseTest do
  @moduledoc """
  Canary for `Letflow.ModuleConnCase` (CORE S9). Expected values are the results of the old
  private copies in `test/letflow/modules/codes/*_test.exs` on main before the move.
  """

  use ExUnit.Case, async: true

  alias Letflow.ModuleConnCase, as: M

  defp conn_with(body), do: %Plug.Conn{resp_body: body}

  test "json/1 decodes the response body like Jason.decode!(conn.resp_body)" do
    assert M.json(conn_with(~s({"a":1,"trace_id":"t"}))) == %{"a" => 1, "trace_id" => "t"}
    assert M.json(conn_with("[1,2]")) == [1, 2]
  end

  test "strip/1 drops only trace_id" do
    assert M.strip(%{"a" => 1, "trace_id" => "t"}) == %{"a" => 1}
    assert M.strip(%{"a" => 1}) == %{"a" => 1}
  end

  test "strip_conn/1 decodes then drops trace_id" do
    assert M.strip_conn(conn_with(~s({"error":"x","trace_id":"t"}))) == %{"error" => "x"}
  end

  test "call/6 sends a JSON request with token, tenant slug and trace id" do
    user = %{plaintext: "nope", slug: "no-such-tenant"}
    conn = M.call(:post, "/api/v1/modules/codes", "/resolve", user, %{"value" => "x"}, "t-s9")

    assert conn.method == "POST"
    assert conn.request_path == "/api/v1/modules/codes/resolve"
    assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer nope"]
    assert Plug.Conn.get_req_header(conn, "x-tenant-slug") == ["no-such-tenant"]
    assert Plug.Conn.get_req_header(conn, "x-trace-id") == ["t-s9"]
    assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
    # an unknown tenant is refused by the pipeline, never served
    assert conn.status in [401, 403, 404]
  end
end
