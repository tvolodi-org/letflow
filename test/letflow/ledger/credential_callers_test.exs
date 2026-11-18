defmodule Letflow.Ledger.CredentialCallersTest do
  @moduledoc """
  REQ-686 criterion 4 (T-SEC-3): the credential kind of the request reaches `Engine.complete_task/3`.
  An AST scan of `lib/` pins the callers of `complete_task`: the tasks router passes `:credential`
  taken from the request's auth context; the old-app write address (REQ-860,
  `Letflow.Modules.Stock.OldAppWrites`) passes the literal `:shared_access`, pinned by T-SEC-3g;
  the two opening postings complete only `submit` nodes. The HTTP tests dispatch into
  the real tasks router: an OIDC completion posts, an API token and an auth context without a
  credential are refused `write_not_permitted` and write nothing.
  """

  use Letflow.DataCase, async: false
  @moduletag :integration

  import Plug.Conn
  import Plug.Test

  alias Letflow.LedgerPostFixture, as: Fx

  # The stock opening posting completes its own `submit` node as the issuing user, after the
  # route has passed StockPost; that node has no module write, so it carries no credential.
  @allowed %{
    "lib/letflow/routers/tasks.ex" => :request_credential,
    "lib/letflow/modules/stock/old_app_writes.ex" => :shared_access_credential,
    "lib/letflow/modules/stock/documents/posting.ex" => :submit_node_no_write,
    "lib/letflow/modules/assets/documents/posting.ex" => :submit_node_no_write
  }

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

  test "T-SEC-3a every caller of Engine.complete_task is classified, the tasks router passes the credential" do
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

  # The reason of the posting.ex entry: it completes only `submit` nodes, and no `submit` node of the
  # stock pack carries a module write (so a missing credential refuses nothing it would need).
  test "T-SEC-3e posting.ex completes only submit, and no submit node of the stock pack writes" do
    source = File.read!("lib/letflow/modules/stock/documents/posting.ex")

    assert Regex.scan(~r/t\.node_id == "(\w+)"/, source) == [
             [~s(t.node_id == "submit"), "submit"]
           ]

    submits =
      for d <-
            "priv/modules/stock/pack.json"
            |> File.read!()
            |> Jason.decode!()
            |> Map.fetch!("definitions"),
          node <- d["graph"]["nodes"],
          node["id"] == "submit",
          do: {d["process_key"], node}

    assert [{"stock_opening", _}, {"stock_quick_count", _}] = submits

    for {_key, node} <- submits,
        do: refute(Map.has_key?(node["attributes"] || %{}, "module_writes"))
  end

  # REQ-860: the old-app address completes the `post` / `reverse` task of a stock document with the
  # literal credential kind `:shared_access` (no request value reaches it: the HTTP auth context holds
  # only :oidc or :api_token). `Ledger.Authority` accepts that kind only through
  # `SharedStockAccess.may_post?/4` (module stock, StockPost / StockReverse, a live credential actor).
  test "T-SEC-3g old_app_writes.ex completes only the task of Posting.pending_task_id, with :shared_access" do
    path = "lib/letflow/modules/stock/old_app_writes.ex"
    source = File.read!(path)
    {:ok, ast} = Code.string_to_quoted(source)

    assert [call] = complete_calls(ast)
    assert {{:., _, _}, _, [{:task_id, _, _}, {:attrs, _, _}, opts]} = call
    assert Keyword.get(opts, :credential) == :shared_access
    assert Keyword.keys(opts) |> Enum.sort() == [:credential, :prefix]

    # the task id comes from the pending-task lookup, whose nodes are only post and reverse
    assert source =~ "task_id ->"
    assert source =~ "Posting.pending_task_id(prefix, document_id, node)"

    posting = File.read!("lib/letflow/modules/stock/documents/posting.ex")
    assert posting =~ ~s|def pending_task_id(prefix, id, node) when node in ["post", "reverse"]|

    # :shared_access is minted in this one file, nowhere else in lib/
    minters =
      for path <- Path.wildcard("lib/**/*.ex"),
          not String.starts_with?(path, "lib/letflow/design/"),
          File.read!(path) =~ "credential: :shared_access",
          do: path

    assert minters == [path]

    # and its only callers are the catalog's two old-app functions, which only the old-app router calls
    callers =
      for path <- Path.wildcard("lib/**/*.ex"),
          path != "lib/letflow/modules/stock/old_app_writes.ex",
          File.read!(path) =~ ~r/OldAppWrites\.(post_movement|reverse_movement)/,
          do: path

    assert callers == ["lib/letflow/modules/catalog.ex"]

    catalog_callers =
      for path <- Path.wildcard("lib/**/*.ex"),
          path != "lib/letflow/modules/catalog.ex",
          File.read!(path) =~ ~r/Catalog\.old_app_(post|reverse)\(/,
          do: path

    assert catalog_callers == ["lib/letflow/routers/shared_stock_access.ex"]
  end

  # Same reason for the assets opening posting: it completes only `submit`, which has no module write.
  test "T-SEC-3f assets posting.ex completes only submit, and the assets submit node does not write" do
    source = File.read!("lib/letflow/modules/assets/documents/posting.ex")
    assert source =~ ~s(t.node_id == "submit" and t.status == :pending)

    submits =
      for d <-
            "priv/modules/assets/pack.json"
            |> File.read!()
            |> Jason.decode!()
            |> Map.fetch!("definitions"),
          node <- d["graph"]["nodes"],
          node["id"] == "submit",
          do: {d["process_key"], node}

    assert [{"assets_opening", _}] = submits

    for {_key, node} <- submits,
        do: refute(Map.has_key?(node["attributes"] || %{}, "module_writes"))
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
