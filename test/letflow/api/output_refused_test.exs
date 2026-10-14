defmodule Letflow.Api.OutputRefusedTest do
  @moduledoc """
  REQ-460 -- `Letflow.Api.Error.output_refused/2` and `Letflow.Api.Response.output_refused/3`
  (design req459 section 3.2). Pure; no database.
  """

  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Letflow.Api.Error
  alias Letflow.Api.Response

  describe "Error.output_refused/2" do
    test "is a 422 problem with the constant code and the two key lists as extension members" do
      error = Error.output_refused(["decision"], [])

      assert error.status == 422
      assert error.title == "Output Refused"
      assert error.type =~ "output-refused"

      body = error |> Error.serialise() |> Jason.decode!()
      assert body["code"] == "output_refused"
      assert body["missing_keys"] == ["decision"]
      assert body["rejected_keys"] == []
      assert body["status"] == 422
    end

    test "both lists are sorted ascending and deduplicated" do
      body =
        ["z", "a", "z"]
        |> Error.output_refused(["y", "b", "b"])
        |> Error.serialise()
        |> Jason.decode!()

      assert body["missing_keys"] == ["a", "z"]
      assert body["rejected_keys"] == ["b", "y"]
    end

    test "the serialised body holds exactly the fixed members: nothing but names can reach it" do
      body = Error.output_refused([], []) |> Error.serialise() |> Jason.decode!()

      assert body |> Map.keys() |> Enum.sort() ==
               ~w(code detail missing_keys rejected_keys status title trace_id type)
    end
  end

  # GH #2528 (lib/letflow/design/gh2528-record-version-conflict.md §6).
  describe "Error.record_version_conflict/0" do
    test "is a 409 problem with the constant code and a fixed detail" do
      error = Error.record_version_conflict()

      assert error.status == 409
      assert error.title == "Record Version Conflict"
      assert error.type =~ "record-version-conflict"

      body = error |> Error.serialise() |> Jason.decode!()
      assert body["code"] == "record_version_conflict"
      assert body["status"] == 409
      assert body["detail"] == "the record was changed by someone else; reload it and try again"
    end

    test "the serialised body holds exactly the fixed members: no record data or sequence can reach it" do
      body = Error.record_version_conflict() |> Error.serialise() |> Jason.decode!()

      assert body |> Map.keys() |> Enum.sort() == ~w(code detail status title trace_id type)
    end

    test "sent via Response.send_problem/2 as 409 application/problem+json with the conn's trace id" do
      conn =
        conn(:put, "/x")
        |> assign(:trace_id, "trace-2528")
        |> Response.send_problem(Error.record_version_conflict())

      assert conn.status == 409
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/problem+json"

      body = Jason.decode!(conn.resp_body)
      assert body["code"] == "record_version_conflict"
      assert body["trace_id"] == "trace-2528"
    end
  end

  describe "Response.output_refused/3" do
    test "sends 422 application/problem+json carrying the trace id from the conn" do
      conn =
        conn(:post, "/x")
        |> assign(:trace_id, "trace-460")
        |> Response.output_refused(["decision"], ["note"])

      assert conn.status == 422
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/problem+json"

      body = Jason.decode!(conn.resp_body)
      assert body["code"] == "output_refused"
      assert body["missing_keys"] == ["decision"]
      assert body["rejected_keys"] == ["note"]
      assert body["trace_id"] == "trace-460"
    end
  end
end
