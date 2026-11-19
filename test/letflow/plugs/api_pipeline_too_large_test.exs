defmodule Letflow.Plugs.ApiPipelineTooLargeTest do
  @moduledoc """
  T-2328: a body over the parser cap (`Plug.Parsers` in `Letflow.Plugs.ApiPipeline`) is answered
  with the JSON problem document, status 413, the constant code `request_too_large` and the limit
  in bytes, for every API route (one place: `ApiPipeline.handle_errors/2`). The parser raises
  before authentication, so no database is needed.
  """

  use ExUnit.Case, async: false
  @moduletag :unit

  import Plug.Test

  alias Letflow.Plugs.ApiPipeline

  defp post_over_cap(path, content_type, payload) do
    conn = conn(:post, path, payload) |> Plug.Conn.put_req_header("content-type", content_type)
    {_, %{ref: ref}} = conn.adapter

    try do
      ApiPipeline.call(conn, ApiPipeline.init([]))
      flunk("expected the parser to refuse the body")
    rescue
      Plug.Parsers.RequestTooLargeError -> :ok
    end

    # Plug.ErrorHandler answered through the adapter before it re-raised.
    assert_received {^ref, {status, headers, resp_body}}
    %{status: status, headers: headers, resp_body: resp_body}
  end

  defp header(conn, name), do: for({^name, v} <- conn.headers, do: v)

  defp body(conn), do: Jason.decode!(conn.resp_body)

  test "an over-cap JSON body answers 413 JSON with the code and the 2 MiB limit" do
    conn =
      post_over_cap(
        "/entities/records/x/import",
        "application/json",
        String.duplicate("a", 2_097_153)
      )

    assert conn.status == 413
    assert ["application/problem+json" <> _] = header(conn, "content-type")
    body = body(conn)
    assert body["code"] == "request_too_large"
    assert body["limit_bytes"] == 2_097_152
    assert body["status"] == 413
    assert is_binary(body["detail"])
    assert Map.has_key?(body, "trace_id")
  end

  test "an over-cap multipart body reports the 25 MiB limit" do
    conn =
      post_over_cap(
        "/instances/i/attachments",
        "multipart/form-data; boundary=xx",
        "--xx\r\ncontent-disposition: form-data; name=\"f\"; filename=\"a.bin\"\r\n" <>
          "content-type: application/octet-stream\r\n\r\n" <>
          String.duplicate("a", 26_214_401) <> "\r\n--xx--\r\n"
      )

    assert conn.status == 413
    assert body(conn)["limit_bytes"] == 26_214_400
    assert body(conn)["code"] == "request_too_large"
  end

  test "the body carries nothing from the request" do
    conn =
      post_over_cap("/secret-path-marker", "application/json", String.duplicate("a", 2_097_153))

    refute conn.resp_body =~ "secret-path-marker"

    assert body(conn) |> Map.keys() |> Enum.sort() ==
             ~w(code detail limit_bytes status title trace_id type)
  end
end
