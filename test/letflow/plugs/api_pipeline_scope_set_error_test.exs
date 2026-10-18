defmodule Letflow.Plugs.ApiPipelineScopeSetErrorTest do
  @moduledoc """
  REQ-518 / GH #2535 slice 2c-i-a, SEC code-gate condition (design
  `lib/letflow/design/req518-compiler-scope-filter.md` 3.3, T-C13 branch half; spec
  `test/specs/REQ-518-2c-i-a.md`): the `Letflow.Plugs.ApiPipeline.handle_errors/2` branch that
  turns `Letflow.Api.Scope.ScopeSetError` into the constant, detail-free 500.

  T-C13 over HTTP (a route that calls the scope gate) belongs to slice 2c-i-b, because no route
  calls `Scope.allowed_set/2` yet; until then the branch is tested directly, as the SEC gate
  required:

    * `ScopeSetError` (any reason) while no response has been sent: 500, the same body bytes as
      `Response.internal_error/1`, no reason atom, no id, no schema;
    * every other exception leaves the conn untouched (no response), as before the change;
    * a response that was already sent is not touched or doubled;
    * the exception itself: constant message, status 500, no actions.

  No database: `async: true`.
  """

  use ExUnit.Case, async: true

  import Plug.Test

  alias Letflow.Api.Response
  alias Letflow.Api.Scope.ScopeSetError
  alias Letflow.Plugs.ApiPipeline

  @reasons [:invalid_node_id, :invalid_schema_name, :too_many_ids, :anything_else]

  defp conn, do: :get |> conn("/entities/query") |> Plug.Conn.assign(:trace_id, "trace-518-aaaa")

  defp handle(conn, reason),
    do: ApiPipeline.handle_errors(conn, %{kind: :error, reason: reason, stack: []})

  describe "ScopeSetError" do
    test "answers the same detail-free 500 as Response.internal_error/1, byte for byte" do
      expected = Response.internal_error(conn())

      for reason <- @reasons do
        result = handle(conn(), %ScopeSetError{reason: reason})

        assert result.state == :sent
        assert result.status == 500
        assert result.resp_body == expected.resp_body

        assert Plug.Conn.get_resp_header(result, "content-type") ==
                 Plug.Conn.get_resp_header(expected, "content-type")
      end
    end

    test "the body names no reason, no schema, no node id" do
      for reason <- @reasons do
        body = conn() |> handle(%ScopeSetError{reason: reason}) |> Map.fetch!(:resp_body)

        refute body =~ Atom.to_string(reason)
        refute body =~ "scope_set"
        refute body =~ "tenant_"
        refute body =~ "node"
        assert %{"status" => 500} = Jason.decode!(body)
      end
    end

    test "a response already sent is left alone (no second send, no raise)" do
      sent = Response.ok(conn(), %{"ok" => true})
      result = handle(sent, %ScopeSetError{reason: :too_many_ids})

      assert result.status == 200
      assert result.resp_body == sent.resp_body
    end

    test "also while the response is only set (state :set)" do
      set = Plug.Conn.resp(conn(), 200, "pending")
      assert set.state == :set

      result = handle(set, %ScopeSetError{reason: :too_many_ids})
      assert result.state == :sent and result.status == 500
    end
  end

  describe "every other error leaves the conn untouched" do
    test "plain exceptions, throws and exits get no response from the handler" do
      for {kind, reason} <- [
            {:error, %RuntimeError{message: "boom"}},
            {:error, %ArgumentError{message: "bad"}},
            {:error, %KeyError{key: :scope, term: []}},
            {:error, :undef},
            {:throw, :ball},
            {:exit, :shutdown}
          ] do
        c = conn()
        result = ApiPipeline.handle_errors(c, %{kind: kind, reason: reason, stack: []})

        assert result.state == :unset, inspect(reason)
        assert result.resp_body == nil
        assert result == c
      end
    end

    test "a Postgrex.Error (the database error of a scope read) is NOT mapped here: it propagates as before (SEC F-1, 2c-i-b follow-up)" do
      c = conn()
      error = %Postgrex.Error{message: "relation missing"}

      assert ApiPipeline.handle_errors(c, %{kind: :error, reason: error, stack: []}) == c
    end
  end

  describe "the exception" do
    test "message is constant whatever the reason, and carries no value" do
      for reason <- @reasons do
        assert Exception.message(%ScopeSetError{reason: reason}) == "scope_set_failed"
      end

      assert Exception.message(%ScopeSetError{}) == "scope_set_failed"
    end

    test "Plug.Exception: status 500, no actions" do
      for reason <- @reasons do
        assert Plug.Exception.status(%ScopeSetError{reason: reason}) == 500
        assert Plug.Exception.actions(%ScopeSetError{reason: reason}) == []
      end
    end

    test "it can be raised and rescued with its reason (the carrier of the closed reason atom)" do
      assert_raise ScopeSetError, "scope_set_failed", fn ->
        raise ScopeSetError, reason: :too_many_ids
      end

      error = catch_error(raise(ScopeSetError, reason: :invalid_node_id))
      assert error.reason == :invalid_node_id
    end
  end
end
