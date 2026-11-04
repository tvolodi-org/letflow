defmodule Letflow.Ledger.CredentialCallersTest do
  @moduledoc """
  REQ-686 criterion 4 (T-SEC-3): the credential kind of the request reaches `Engine.complete_task/3`.
  An AST scan of `lib/` pins that the tasks router is the only caller of `complete_task` and that
  it passes `:credential` taken from the request's auth context; the HTTP tests dispatch into
  the real tasks router: an OIDC completion posts, an API token and an auth context without a
  credential are refused `write_not_permitted` and write nothing.
  """

  use Letflow.DataCase, async: false
  @moduletag :integration

  import Plug.Conn
  import Plug.Test

  alias Letflow.LedgerPostFixture, as: Fx

  @allowed %{"lib/letflow/routers/tasks.ex" => :request_credential}

  defp complete_calls(ast) do
    {_ast, calls} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, mods}, :complete_task]}, _, _} = node, acc ->
          {node, if(List.last(mods) == :Engine, do: [node | acc], else: acc)}

        {:&, _, [{:/, _, [{{:., _, [{:__aliases__, _, mods}, :complete_task]}, _, _}, _]}]} =
            node,
        acc ->
          {node, if(List.last(mods) == :Engine, do: [node | acc], else: acc)}

        {:apply, _, [{:__aliases__, _, mods}, :complete_task | _]} = node, acc ->
          {node, if(List.last(mods) == :Engine, do: [node | acc], else: acc)}

        node, acc ->
          {node, acc}
      end)

    calls
  end

  test "T-SEC-3a only the tasks router calls Engine.complete_task, and it passes the credential" do
    callers =
      for path <- Path.wildcard("lib/**/*.ex"),
          not String.starts_with?(path, "lib/letflow/design/"),
          path != "lib/letflow/engine.ex",
          source = File.read!(path),
          source =~ "complete_task",
          {:ok, ast} = Code.string_to_quoted(source),
          complete_calls(ast) != [],
          into: %{} do
        {path, ast}
      end

    assert Map.keys(callers) -- Map.keys(@allowed) == [],
           "a new caller of Engine.complete_task must pass :credential and be listed here"

    ast = Map.fetch!(callers, "lib/letflow/routers/tasks.ex")

    {_ast, found} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, [:Keyword]}, :put]}, _, args} = node, acc ->
          {node, acc or Enum.any?(args, &credential_from_context?/1)}

        node, acc ->
          {node, acc}
      end)

    assert found, "tasks.ex must put :credential from the request's auth context"
  end

  # `Keyword.put(opts, :credential, Map.get(conn.assigns.auth_context, :credential))`, in or out of a pipe
  defp credential_from_context?(node),
    do: Macro.to_string(node) == "Map.get(conn.assigns.auth_context, :credential)"

  defp complete(ctx, auth_extra) do
    :ok = Letflow.SodSupport.grant_role!(ctx.schema, "REVIEWER", [ctx.completer.id])

    conn(:post, "/#{ctx.task.id}/complete")
    |> Map.put(:body_params, %{})
    |> put_req_header("content-type", "application/json")
    |> assign(
      :auth_context,
      Map.merge(
        %{
          user_id: ctx.completer.id,
          tenant_id: ctx.tenant.tenant_id,
          roles: ["TENANT_ADMIN", "REVIEWER"]
        },
        auth_extra
      )
    )
    |> assign(:trace_id, "req686-sec3")
    |> then(&Letflow.Routers.Tasks.call(&1, Letflow.Routers.Tasks.init([])))
  end

  defp posting_case(slug),
    do: Fx.case!(slug, [Fx.line("post_alpha", %{"posting" => Fx.posting("receipt", "a", "5")})])

  test "T-SEC-3b an OIDC completion through the router posts" do
    ctx = posting_case("req686-sec3b")
    assert complete(ctx, %{credential: :oidc}).status == 200
    assert {1, 1, 1, 1} = Fx.ledger_counts(ctx.schema)
  end

  test "T-SEC-3c an API token completion is refused and nothing is written" do
    ctx = posting_case("req686-sec3c")
    conn = complete(ctx, %{credential: :api_token})

    assert conn.status == 403
    assert Jason.decode!(conn.resp_body) == %{"error" => "write_not_permitted", "line_index" => 0}
    assert {0, 0, 0, 0} = Fx.ledger_counts(ctx.schema)
  end

  test "T-SEC-3d an auth context with no credential fails closed" do
    ctx = posting_case("req686-sec3d")
    assert complete(ctx, %{}).status == 403
    assert {0, 0, 0, 0} = Fx.ledger_counts(ctx.schema)
  end
end
