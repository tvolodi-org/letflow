defmodule Letflow.Plugs.ContentTypeTest do
  @moduledoc """
  Tests for `Letflow.Plugs.ContentType` (REQ-068). `Plug.Test`-driven,
  exercising `call/2` directly — same convention as
  `test/letflow/plugs/tenant_status_test.exs`. No database.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  import Plug.Test
  import Plug.Conn

  alias Letflow.Plugs.ContentType

  defp call(method, path, opts \\ []) do
    conn = conn(method, path)

    conn =
      case Keyword.get(opts, :content_type) do
        nil -> conn
        ct -> put_req_header(conn, "content-type", ct)
      end

    conn =
      case Keyword.get(opts, :content_length) do
        nil -> conn
        len -> put_req_header(conn, "content-length", to_string(len))
      end

    conn =
      if Keyword.get(opts, :chunked, false) do
        put_req_header(conn, "transfer-encoding", "chunked")
      else
        conn
      end

    ContentType.call(conn, ContentType.init([]))
  end

  defp status(conn), do: conn.status
  defp halted?(conn), do: conn.halted

  describe "GET/HEAD/DELETE — unaffected regardless of Content-Type (AC1)" do
    test "GET with no Content-Type header passes through untouched" do
      conn = call(:get, "/x")
      refute halted?(conn)
      assert conn.status == nil
    end

    test "DELETE with no Content-Type passes through" do
      conn = call(:delete, "/x")
      refute halted?(conn)
    end

    test "HEAD with no Content-Type passes through" do
      conn = call(:head, "/x")
      refute halted?(conn)
    end

    test "GET with a body and a wrong Content-Type still passes through -- not subject to enforcement" do
      conn = call(:get, "/x", content_type: "text/plain", content_length: 10)
      refute halted?(conn)
    end
  end

  describe "POST with a body — rejects missing/wrong Content-Type with 415 (AC1)" do
    test "POST with a body and no Content-Type header -> 415" do
      conn = call(:post, "/x", content_length: 10)
      assert halted?(conn)
      assert status(conn) == 415
    end

    test "POST with Content-Type: text/plain -> 415" do
      conn = call(:post, "/x", content_type: "text/plain", content_length: 10)
      assert halted?(conn)
      assert status(conn) == 415
    end

    test "POST with Content-Type: application/json -> passes" do
      conn = call(:post, "/x", content_type: "application/json", content_length: 10)
      refute halted?(conn)
    end

    test "POST with Content-Type: application/json; charset=utf-8 -> passes (charset stripped)" do
      conn =
        call(:post, "/x", content_type: "application/json; charset=utf-8", content_length: 10)

      refute halted?(conn)
    end

    test "reject sends an application/problem+json body naming the requirement" do
      conn = call(:post, "/x", content_length: 10)
      assert get_resp_header(conn, "content-type") == ["application/problem+json; charset=utf-8"]
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == 415
      assert body["detail"] =~ "application/json"
    end
  end

  describe "PATCH — same rules as POST" do
    test "PATCH with no Content-Type and a body -> 415" do
      conn = call(:patch, "/x", content_length: 10)
      assert status(conn) == 415
    end

    test "PATCH with application/json -> passes" do
      conn = call(:patch, "/x", content_type: "application/json", content_length: 10)
      refute halted?(conn)
    end
  end

  describe "PUT — the one case NOT in the naive '415 on missing body' reading (design doc §0.2)" do
    test "PUT with no body -> 400, not 415 (full replacement requires a body)" do
      conn = call(:put, "/x")
      assert halted?(conn)
      assert status(conn) == 400
      assert Jason.decode!(conn.resp_body)["detail"] =~ "PUT"
    end

    test "PUT with Content-Length: 0 -> treated as no body -> 400" do
      conn = call(:put, "/x", content_length: 0)
      assert status(conn) == 400
    end

    test "PUT with a body and no Content-Type -> 415" do
      conn = call(:put, "/x", content_length: 10)
      assert status(conn) == 415
    end

    test "PUT with a body and application/json -> passes" do
      conn = call(:put, "/x", content_type: "application/json", content_length: 10)
      refute halted?(conn)
    end
  end

  describe "chunked transfer-encoding counts as having a body (defensive, no Content-Length present)" do
    test "POST, chunked, no Content-Type -> 415, not treated as bodyless" do
      conn = call(:post, "/x", chunked: true)
      assert status(conn) == 415
    end
  end

  describe "adversarial Content-Type header shapes" do
    test "uppercase media type is rejected -- exact match, per content_type.zig, not case-folded" do
      conn = call(:post, "/x", content_type: "APPLICATION/JSON", content_length: 10)
      assert status(conn) == 415
    end

    test "application/json with extra whitespace before the semicolon param" do
      conn =
        call(:post, "/x", content_type: "application/json ; charset=utf-8", content_length: 10)

      refute halted?(conn)
    end

    test "a Content-Type with multiple semicolons does not crash the strip" do
      conn =
        call(:post, "/x",
          content_type: "application/json; charset=utf-8; boundary=x",
          content_length: 10
        )

      refute halted?(conn)
    end

    test "an empty-string Content-Type header is rejected, not treated as absent-and-crashing" do
      conn = call(:post, "/x", content_type: "", content_length: 10)
      assert status(conn) == 415
    end

    test "application/json+something is rejected -- suffix must match exactly" do
      conn = call(:post, "/x", content_type: "application/json+special", content_length: 10)
      assert status(conn) == 415
    end
  end
end
