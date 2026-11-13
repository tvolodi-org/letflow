defmodule Letflow.Modules.PrivateHelpersScanTest do
  @moduledoc """
  CORE slice S9, closing scan (core-extraction-design section 6): the router tests under
  `test/letflow/modules/**` take `json/1`, `strip/1` and `strip_conn/1` from
  `Letflow.ModuleConnCase`. This test fails when a new private copy of one of them, or a new
  private `tenant/1`, appears outside `exam/` (a closed module, left as it was).

  Private `call/3-4` helpers differ per file (path prefix, token or user, trace id), so they are
  pinned by file: a new file with its own `defp call(` that builds the request through
  `Letflow.Router` must use `ModuleConnCase.call/6` or be added here with a reason.
  """

  use ExUnit.Case, async: true

  @root Path.expand("..", __DIR__)

  # Files that kept a private request builder (other shapes or arities than `ModuleConnCase.call/6`).
  @call_exceptions ~w(
    modules/asset_stock_isolation_test.exs
    modules/assets/card_import_test.exs
    modules/assets/storekeeper_assets_test.exs
    modules/catalog_items/router_test.exs
    modules/codes/resolve_router_test.exs
    modules/codes/router_test.exs
    modules/locations/router_test.exs
    modules/org/router_test.exs
    modules/procurement/attachment_routes_test.exs
    modules/procurement/line_cancel_test.exs
    modules/procurement/line_routes_test.exs
    modules/procurement/router_test.exs
    modules/runtime_demo/router_test.exs
    modules/stock/count_differences_router_test.exs
    modules/stock/count_paperwork_router_test.exs
    modules/stock/count_posting_test.exs
    modules/stock/count_print_router_test.exs
    modules/stock/count_scan_router_test.exs
    modules/stock/count_worksheet_router_test.exs
    modules/stock/counts_router_test.exs
    modules/stock/count_sheet_router_test.exs
    modules/stock/form_count_router_test.exs
    modules/stock/storekeeper_test.exs
    modules/stock/voice_router_test.exs
  )

  defp files do
    Path.join([@root, "modules", "**", "*.exs"])
    |> Path.wildcard()
    |> Enum.reject(&String.contains?(&1, "/modules/exam/"))
    |> Enum.reject(&(&1 == __ENV__.file))
  end

  defp lines(file), do: file |> File.read!() |> String.split("\n")

  defp rel(file), do: Path.relative_to(file, @root)

  defp hits(regex) do
    for f <- files(), {line, n} <- Enum.with_index(lines(f), 1), line =~ regex do
      "#{rel(f)}:#{n}: #{String.trim(line)}"
    end
  end

  test "S9-scan-1: no private json/1 copy that decodes the response body" do
    assert hits(~r/^\s*defp json\(.*(resp_body|Jason\.decode)/) == []
  end

  test "S9-scan-2: no private strip/strip_conn copy that deletes trace_id" do
    assert hits(~r/^\s*defp strip(_conn)?\(.*Map\.delete\(.*trace_id/) == []
  end

  test "S9-scan-3: no private tenant/1 helper outside exam" do
    assert hits(~r/^\s*defp tenant\(/) == []
  end

  test "S9-scan-4: a private call helper through Letflow.Router is a listed exception" do
    having_call =
      for f <- files(), text = File.read!(f), text =~ ~r/^\s*defp call\(/m, do: rel(f)

    assert Enum.sort(having_call) -- Enum.sort(@call_exceptions) == []
  end

  test "S9-scan-5: the scan catches a copy (canary on the matchers)" do
    assert "  defp json(conn), do: Jason.decode!(conn.resp_body)" =~
             ~r/^\s*defp json\(.*(resp_body|Jason\.decode)/

    assert ~s|  defp strip(b), do: Map.delete(b, "trace_id")| =~
             ~r/^\s*defp strip(_conn)?\(.*Map\.delete\(.*trace_id/

    refute "  defp json(conn), do: M.json(conn)" =~ ~r/^\s*defp json\(.*(resp_body|Jason\.decode)/
  end
end
