defmodule Letflow.Plugs.XlsxBodyParserTest do
  @moduledoc """
  GH #3603 / REQ-650: `Letflow.Plugs.XlsxBodyParser` claims the `.xlsx` media type for the record
  import route only. `Plug.Test`, no database. P1..P4 as in the CSV parser test.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  import Plug.Test
  import Plug.Conn

  @import_path ["entities", "records", "widget", "import"]
  @xlsx "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

  defp parse(method, path_info, body, content_type \\ @xlsx) do
    conn =
      conn(method, "/", body)
      |> Map.put(:path_info, path_info)
      |> put_req_header("content-type", content_type)

    Plug.Parsers.call(
      conn,
      Plug.Parsers.init(
        parsers: [:json, {:multipart, length: 26_214_400}, Letflow.Plugs.XlsxBodyParser],
        json_decoder: Jason,
        length: 2_097_152
      )
    )
  end

  test "P1: an over-limit xlsx body raises the same error as an oversized JSON body" do
    big = String.duplicate("a", 2_097_153)

    assert_raise Plug.Parsers.RequestTooLargeError, fn -> parse(:post, @import_path, big) end
  end

  test "P2: a body within the limit is kept as raw bytes under \"_xlsx\", also with a parameter" do
    body = <<0, 1, 2, 255, 254>> <> "PK"
    assert parse(:post, @import_path, body).body_params == %{"_xlsx" => body}

    assert parse(:post, @import_path, body, @xlsx <> "; charset=binary").body_params == %{
             "_xlsx" => body
           }
  end

  test "P3: the xlsx media type on any other path is still a 415" do
    for path <- [
          ["entities", "records", "widget"],
          ["definitions"],
          ["entities", "records", "widget", "import", "x"]
        ] do
      assert_raise Plug.Parsers.UnsupportedMediaTypeError, fn -> parse(:post, path, "x") end
    end
  end

  test "P4: a non-POST on the import path is still a 415" do
    assert_raise Plug.Parsers.UnsupportedMediaTypeError, fn -> parse(:put, @import_path, "x") end
  end
end
