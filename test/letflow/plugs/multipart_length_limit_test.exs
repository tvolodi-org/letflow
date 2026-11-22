defmodule Letflow.Plugs.MultipartLengthLimitTest do
  @moduledoc """
  T-2645: the multipart parser charges the framing against its `:length` limit, so a body
  built from parts without headers -- or from header lines without a name and a value --
  is refused instead of being parsed.

  Before plug 1.20.4 the framing cost nothing: only the part names, the part header
  names and values and the part bodies were charged, so such a body never reached the
  limit, and the parser kept one entry per part until the whole body had been read
  (EEF-CVE-2026-120287, GHSA-qj4r-jh2r-rw3f; the advisory measures 92 MiB held for a
  4.5 MB body). plug 1.20.4 charges the framing too, so the limit bounds it.

  The two option shapes Letflow uses are pinned here: `{:multipart, length: N}` (the
  shared API pipeline, `lib/letflow/plugs/api_pipeline.ex`) and `[:multipart]` with the
  root `length: N` (the old app's voice route,
  `lib/letflow/routers/shared_stock_access.ex`).
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  import Plug.Test

  # The limits and the part count of plug's own upstream tests for this fix.
  @small_limit 10_000
  @headerless_parts 10_000

  # The product's own multipart limits: the shared API pipeline and the old app's voice.
  @api_pipeline_limit 26_214_400
  @old_app_voice_limit 10_485_760

  defp multipart_conn(body, boundary) do
    conn(:post, "/", body)
    |> Plug.Conn.put_req_header("content-type", "multipart/form-data; boundary=#{boundary}")
  end

  # Plug.Parsers raises Plug.Parsers.RequestTooLargeError when a parser answers
  # {:error, :too_large, conn}; every other outcome is returned as it is.
  defp parse_multipart(body, boundary, opts) do
    parsers = Plug.Parsers.init(opts)

    try do
      Plug.Parsers.call(multipart_conn(body, boundary), parsers)
    rescue
      e in Plug.Parsers.RequestTooLargeError -> {:too_large, e}
    end
  end

  # The advisory's first proof of concept: parts without headers.
  defp headerless_body(boundary, parts) do
    "--" <>
      boundary <>
      "\r\n\r\n" <>
      String.duplicate("\r\n--" <> boundary <> "\r\n\r\n", parts) <>
      "\r\n--" <> boundary <> "--\r\n"
  end

  # The advisory's second proof of concept: header lines without a name and a value.
  defp empty_header_body(boundary, parts, headers_per_part) do
    String.duplicate(
      "--" <> boundary <> "\r\n" <> String.duplicate(":\r\n", headers_per_part) <> "\r\n\r\n",
      parts
    ) <> "--" <> boundary <> "--\r\n"
  end

  test "a body of parts without headers is refused: the framing is charged" do
    body = headerless_body("deadbeef", @headerless_parts)

    assert {:too_large, %Plug.Parsers.RequestTooLargeError{}} =
             parse_multipart(body, "deadbeef", parsers: [{:multipart, length: @small_limit}])
  end

  test "a body of header lines without a name and a value is refused" do
    body = empty_header_body("deadbeef", 10, 1_000)

    assert {:too_large, %Plug.Parsers.RequestTooLargeError{}} =
             parse_multipart(body, "deadbeef", parsers: [{:multipart, length: @small_limit}])
  end

  test "the root-length option shape (the old app's voice route) refuses such a body too" do
    body = headerless_body("deadbeef", @headerless_parts)

    assert {:too_large, %Plug.Parsers.RequestTooLargeError{}} =
             parse_multipart(body, "deadbeef", parsers: [:multipart], length: @small_limit)
  end

  test "a normal multipart body with one file part is still parsed" do
    body =
      "--deadbeef\r\n" <>
        "content-disposition: form-data; name=\"file\"; filename=\"a.bin\"\r\n" <>
        "content-type: application/octet-stream\r\n\r\n" <> "abc" <> "\r\n--deadbeef--\r\n"

    parsers = Plug.Parsers.init(parsers: [{:multipart, length: @small_limit}])

    assert %{body_params: %{"file" => %Plug.Upload{filename: "a.bin"}}} =
             Plug.Parsers.call(multipart_conn(body, "deadbeef"), parsers)
  end

  # The product's own multipart cap, at the scale the advisory's proof of concept needs:
  # 36 charged bytes per part means the 25 MiB limit is reached after about 728 000 parts.
  # The parse itself is the cost of this test, hence the timeout.
  @tag timeout: 300_000
  test "the API pipeline refuses the advisory's body at the product's own 25 MiB cap" do
    body = headerless_body("b", 728_200)

    conn = multipart_conn(body, "b")
    {_, %{ref: ref}} = conn.adapter

    try do
      Letflow.Plugs.ApiPipeline.call(conn, Letflow.Plugs.ApiPipeline.init([]))
      flunk("expected the multipart parser to refuse the body")
    rescue
      Plug.Parsers.RequestTooLargeError -> :ok
    end

    assert_received {^ref, {413, headers, resp_body}}
    assert ["application/problem+json" <> _] = for({"content-type", v} <- headers, do: v)
    body = Jason.decode!(resp_body)
    assert body["code"] == "request_too_large"
    assert body["limit_bytes"] == @api_pipeline_limit
  end
end
