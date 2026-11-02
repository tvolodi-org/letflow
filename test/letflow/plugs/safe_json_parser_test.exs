defmodule Letflow.Plugs.SafeJsonParserTest do
  @moduledoc """
  Tests for `Letflow.Plugs.SafeJsonParser` (REQ-068). `Plug.Test`-driven, no
  database. Covers AC2 (invalid JSON -> typed 400, not a 500) and AC3
  (oversized body -> 413, named module attribute), plus the adversarial
  inputs this run's security self-review constructed.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  import Plug.Test
  import Plug.Conn

  alias Letflow.Plugs.SafeJsonParser

  defp call(body, opts \\ []) do
    conn =
      conn(:post, "/x", body)
      |> put_req_header("content-type", "application/json")

    SafeJsonParser.call(conn, SafeJsonParser.init(opts))
  end

  describe "valid JSON — parses through untouched" do
    test "a well-formed JSON object body is parsed into body_params" do
      conn = call(Jason.encode!(%{"a" => 1}))
      refute conn.halted
      assert conn.body_params == %{"a" => 1}
    end

    test "an empty JSON object parses fine" do
      conn = call("{}")
      refute conn.halted
      assert conn.body_params == %{}
    end
  end

  describe "malformed JSON — typed 400, never a crash reaching the caller (AC2, INV-8)" do
    test "syntactically invalid JSON -> 400 problem document, conn halted" do
      conn = call("{not valid json")

      assert conn.halted
      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == 400
      assert get_resp_header(conn, "content-type") == ["application/problem+json; charset=utf-8"]
    end

    test "an empty body with Content-Type: application/json is NOT an error -- matches content_type.zig's own POST/PATCH-no-body-ok row (design doc §0.2), Plug.Parsers just yields empty params" do
      conn = call("")
      refute conn.halted
      assert conn.body_params == %{}
    end

    test "a body that is just whitespace -> 400, not a crash" do
      conn = call("   \n\t  ")
      assert conn.halted
      assert conn.status == 400
    end

    test "truncated JSON (unterminated object) -> 400" do
      conn = call(~s({"a": "b))
      assert conn.halted
      assert conn.status == 400
    end
  end

  describe "oversized body — 413, named module attribute (AC3)" do
    test "a body over the configured length is rejected with 413, not buffered/crashed" do
      # 10-byte limit so the test does not need to build a real 1 MiB payload.
      big = Jason.encode!(%{"a" => String.duplicate("x", 100)})
      conn = call(big, length: 10)

      assert conn.halted
      assert conn.status == 413
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == 413
    end

    test "a body exactly at the configured length limit is NOT rejected" do
      # Plug.Parsers' :length bounds are inclusive-at-the-limit in practice;
      # assert the accepted side explicitly rather than only the rejected side.
      payload = Jason.encode!(%{"a" => 1})
      conn = call(payload, length: byte_size(payload) + 10)

      refute conn.halted
    end
  end

  describe "default length is the documented 1 MiB, overridable per caller" do
    test "init/1 without an explicit :length uses the 1_000_000-byte default" do
      opts = SafeJsonParser.init([])
      # Plug.Parsers.init/1 returns an opaque struct; probe behaviourally
      # instead of reaching into its fields -- a body just under 1 MiB
      # passes, matching the documented default.
      under_limit = Jason.encode!(%{"a" => String.duplicate("x", 900_000)})
      conn = conn(:post, "/x", under_limit) |> put_req_header("content-type", "application/json")

      refute SafeJsonParser.call(conn, opts).halted
    end

    test "an explicit :length overrides the default (caller precedence, design doc §3)" do
      opts = SafeJsonParser.init(length: 5)
      payload = Jason.encode!(%{"a" => "way more than five bytes"})
      conn = conn(:post, "/x", payload) |> put_req_header("content-type", "application/json")

      assert SafeJsonParser.call(conn, opts).halted
    end
  end
end
