defmodule Letflow.Plugs.CsvBodyParserTest do
  @moduledoc """
  GH #3182 / REQ-557: `Letflow.Plugs.CsvBodyParser` claims `text/csv` for the record import
  route only. `Plug.Test`, no database. P1..P4 of the T-0498 design.
  """

  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  @import_path ["entities", "records", "widget", "import"]

  # The same parser list and `length:` as the API pipeline, called with the path the router's
  # `forward` leaves in `path_info`.
  defp parse(method, path_info, body, content_type \\ "text/csv") do
    conn =
      conn(method, "/", body)
      |> Map.put(:path_info, path_info)
      |> put_req_header("content-type", content_type)

    Plug.Parsers.call(
      conn,
      Plug.Parsers.init(
        parsers: [:json, {:multipart, length: 26_214_400}, Letflow.Plugs.CsvBodyParser],
        json_decoder: Jason,
        length: 2_097_152
      )
    )
  end

  test "P1: an over-limit text/csv body raises the same error as an oversized JSON body" do
    big = String.duplicate("a", 2_097_153)

    assert_raise Plug.Parsers.RequestTooLargeError, fn ->
      parse(:post, @import_path, big)
    end

    assert_raise Plug.Parsers.RequestTooLargeError, fn ->
      parse(:post, @import_path, ~s({"x":"#{big}"}), "application/json")
    end
  end

  test "P2: a body within the limit is kept as raw text under \"_csv\"" do
    body = "title\nA\n"
    conn = parse(:post, @import_path, body)
    assert conn.body_params == %{"_csv" => body}

    ok = String.duplicate("a", 2_000_000)
    assert %{"_csv" => ^ok} = parse(:post, @import_path, ok).body_params
  end

  test "P3: text/csv on any other path is still a 415" do
    for path <- [
          ["entities", "records", "widget"],
          ["definitions"],
          ["entities", "records", "widget", "import", "x"]
        ] do
      assert_raise Plug.Parsers.UnsupportedMediaTypeError, fn ->
        parse(:post, path, "a\n1\n")
      end
    end
  end

  test "P4: a non-POST on the import path is still a 415" do
    assert_raise Plug.Parsers.UnsupportedMediaTypeError, fn ->
      parse(:put, @import_path, "a\n1\n")
    end
  end
end
