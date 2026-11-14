defmodule Letflow.Ledger.AsOfDateGuardTest do
  @moduledoc """
  Structural guard for the `as_of_date` time-zone defect family (GH #4347,
  `scripts/ci_check.sh`: "as_of_date_test builds today in Tokyo, fails between
  15:00Z and 23:00Z").

  Between 15:00 and 23:00 UTC the tenant's local day (Asia/Almaty, UTC+5) is
  already the following day. A test that passes `Date.utc_today()` as an
  `as_of_date` filter gets a UTC date that is "yesterday" from the tenant's
  point of view, so the backend rejects rows whose event-time falls after
  midnight Almaty-time and the assertion fails. The fix is to use the tenant's
  timezone: `Letflow.TenantDate.today/1` or the UTC+5 offset approach used in
  `test/letflow/modules/stock/router_test.exs`.

  This file is excluded from its own scan via `__ENV__.file`.
  Pure file reads: `async: true`.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  @doc false
  defp test_files do
    Path.wildcard("test/**/*.exs")
  end

  defp source(path), do: File.read!(path)

  # Pattern 1: a bare `Date.utc_today()` piped directly to `Date.to_iso8601()` with
  # no intermediate date arithmetic (like `|> Date.add(N)`). The variable is then used
  # as an `as_of_date` filter value. `tomorrow = Date.utc_today() |> Date.add(2) |> ...`
  # does NOT match because `Date.add` appears before `Date.to_iso8601`.
  @bare_iso ~r/= Date\.utc_today\(\) \|> Date\.to_iso8601\(\)/

  # Pattern 2: `Date.utc_today()` interpolated directly into a URL as_of_date parameter.
  @url_interp ~r/as_of_date=\#\{Date\.utc_today\(\)/

  test "no test file uses Date.utc_today() as a bare as_of_date value" do
    my_path = __ENV__.file |> Path.relative_to(File.cwd!())

    bad =
      for path <- test_files(),
          path != my_path,
          content = source(path),
          (Regex.match?(@bare_iso, content) and content =~ "as_of_date") or
            Regex.match?(@url_interp, content) do
        path
      end

    assert bad == [],
           """
           These test files use Date.utc_today() as an as_of_date filter value.
           Use Letflow.TenantDate.today/1 (or the UTC+5 offset approach for tests
           that manage their own DB connections) instead — Date.utc_today() fails
           between 15:00 and 23:00 UTC when the tenant zone (Asia/Almaty, UTC+5)
           is already the following day:

           #{Enum.join(bad, "\n")}
           """
  end
end
