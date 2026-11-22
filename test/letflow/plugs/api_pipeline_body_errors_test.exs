defmodule Letflow.Plugs.ApiPipelineBodyErrorsTest do
  @moduledoc """
  T-2658 (split of T-2633, security probe G-13): a request body the pipeline's
  `Plug.Parsers` cannot read answers a TYPED problem document instead of escaping the
  pipeline as an unhandled error (a bare 500 at the adapter):

    * a malformed JSON body answers 400 (`Letflow.Api.Response.bad_request/2`);
    * a media type none of the pipeline's parsers claims answers 415
      (`Letflow.Api.Response.unsupported_media_type/2`).

  Both are answered in `Letflow.Plugs.ApiPipeline.handle_errors/2` -- the one place every
  API route shares, next to the 413 of an over-cap body -- and both carry a CONSTANT
  detail: nothing from the request is echoed back.

  The parser raises before authentication, so no database is needed. The request goes
  through the pipeline's real entry point (`ApiPipeline.call/2`) and the answer is read
  from the test adapter's mailbox, because `Plug.ErrorHandler` re-raises after the
  handler has answered -- the same shape `Letflow.Plugs.ApiPipelineTooLargeTest` uses
  for the 413.
  """

  use ExUnit.Case, async: false
  @moduletag :unit

  import Plug.Test

  alias Letflow.Plugs.ApiPipeline

  @import_path "/entities/records/x/import"
  @create_path "/entities/records/item"
  @xlsx "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

  # The pipeline answers the request itself and then re-raises it (Plug.ErrorHandler's
  # contract), so the response is read from the test adapter's mailbox.
  defp refused(path, content_type, payload, expected) do
    conn = conn(:post, path, payload) |> Plug.Conn.put_req_header("content-type", content_type)
    {_, %{ref: ref}} = conn.adapter

    try do
      ApiPipeline.call(conn, ApiPipeline.init([]))
      flunk("expected the parser to refuse the body")
    rescue
      error in [
        Plug.Parsers.ParseError,
        Plug.Parsers.BadEncodingError,
        Plug.Parsers.UnsupportedMediaTypeError
      ] ->
        assert error.__struct__ == expected
    end

    assert_received {^ref, {status, headers, resp_body}}
    %{status: status, headers: headers, resp_body: resp_body}
  end

  defp header(conn, name), do: for({^name, v} <- conn.headers, do: v)

  defp body(conn), do: Jason.decode!(conn.resp_body)

  describe "a malformed body" do
    test "answers 400 with the problem document" do
      conn = refused(@import_path, "application/json", "{not json", Plug.Parsers.ParseError)

      assert conn.status == 400
      assert ["application/problem+json" <> _] = header(conn, "content-type")

      body = body(conn)
      assert body["status"] == 400
      assert body["title"] == "Bad Request"
      assert body["type"] =~ "bad-request"
      assert body["detail"] == "request body is not valid JSON"
      assert Map.has_key?(body, "trace_id")
    end

    test "the answer carries nothing from the request" do
      conn =
        refused(
          @import_path,
          "application/json",
          ~s({"canary":"#{String.duplicate("a", 40)}"),
          Plug.Parsers.ParseError
        )

      refute conn.resp_body =~ "canary"
      refute conn.resp_body =~ String.duplicate("a", 40)
      assert body(conn) |> Map.keys() |> Enum.sort() == ~w(detail status title trace_id type)
    end
  end

  describe "a body that is not valid UTF-8" do
    test "answers 400 with the problem document" do
      multipart_body =
        "--xx\r\ncontent-disposition: form-data; name=\"f\"\r\n\r\n" <>
          <<0xFF>> <> "\r\n--xx--\r\n"

      conn =
        refused(
          "/instances/i/attachments",
          "multipart/form-data; boundary=xx",
          multipart_body,
          Plug.Parsers.BadEncodingError
        )

      assert conn.status == 400

      problem = body(conn)
      assert problem["status"] == 400
      assert problem["title"] == "Bad Request"
      assert problem["detail"] == "request body is not valid JSON"
    end
  end

  describe "a media type no parser claims" do
    test "answers 415 with the problem document" do
      conn =
        refused(@create_path, "application/xml", "<a/>", Plug.Parsers.UnsupportedMediaTypeError)

      assert conn.status == 415
      assert ["application/problem+json" <> _] = header(conn, "content-type")

      body = body(conn)
      assert body["status"] == 415
      assert body["title"] == "Unsupported Media Type"
      assert body["type"] =~ "unsupported-media-type"
      assert body["detail"] == "the request content type is not supported by this endpoint"
      assert Map.has_key?(body, "trace_id")
    end

    test "the xlsx media type on a record create route answers 415 too" do
      conn =
        refused(@create_path, @xlsx, "not a workbook", Plug.Parsers.UnsupportedMediaTypeError)

      assert conn.status == 415
      assert body(conn)["status"] == 415
    end

    test "the answer carries nothing from the request" do
      conn =
        refused(
          @create_path,
          "application/canary-secret",
          "canary-secret-body",
          Plug.Parsers.UnsupportedMediaTypeError
        )

      refute conn.resp_body =~ "canary"
      assert body(conn) |> Map.keys() |> Enum.sort() == ~w(detail status title trace_id type)
    end
  end

  describe "one place, every route" do
    test "the same body is refused the same way on two different routes" do
      first = refused(@import_path, "application/json", "{not json", Plug.Parsers.ParseError)
      second = refused(@create_path, "application/json", "{not json", Plug.Parsers.ParseError)

      assert first.status == second.status
      assert first.resp_body == second.resp_body
    end
  end
end
