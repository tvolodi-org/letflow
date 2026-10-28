defmodule Letflow.Api.FormHookRefusedTest do
  @moduledoc """
  REQ-605 / GH #3409 (decision 0067 D8, slice F-3 part A), test T4u: `Error.form_hook_refused/2` and
  `Response.form_hook_refused/3`. Pure; no database. `Error.output_refused/2` keeps its body.
  """

  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Letflow.Api.Error
  alias Letflow.Api.Response

  @fields [%{field: "amount", code: "too_small"}, %{field: "note", code: "bad"}]

  test "Error.form_hook_refused/2 is a 422 with the constant code and the manifest code apart" do
    error = Error.form_hook_refused("too_small", @fields)

    assert error.status == 422
    assert error.title == "Form Hook Refused"
    assert error.type =~ "form-hook-refused"

    body = error |> Error.serialise() |> Jason.decode!()
    assert body["code"] == "form_hook_refused"
    assert body["hook_code"] == "too_small"
    assert body["status"] == 422

    assert body["fields"] == [
             %{"field" => "amount", "code" => "too_small"},
             %{"field" => "note", "code" => "bad"}
           ]
  end

  test "the serialised body holds exactly the fixed members" do
    body = "bad" |> Error.form_hook_refused([]) |> Error.serialise() |> Jason.decode!()

    assert body |> Map.keys() |> Enum.sort() ==
             ~w(code detail fields hook_code status title trace_id type)
  end

  test "Response.form_hook_refused/3 sends application/problem+json with the conn's trace id" do
    conn =
      conn(:post, "/x")
      |> assign(:trace_id, "trace-3409")
      |> Response.form_hook_refused("too_small", @fields)

    assert conn.status == 422
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/problem+json"

    body = Jason.decode!(conn.resp_body)
    assert body["code"] == "form_hook_refused"
    assert body["trace_id"] == "trace-3409"
  end

  test "Error.output_refused/2 is unchanged" do
    body = ["a"] |> Error.output_refused(["b"]) |> Error.serialise() |> Jason.decode!()
    assert body["code"] == "output_refused"
    assert body["missing_keys"] == ["a"]
    assert body["rejected_keys"] == ["b"]
  end
end
