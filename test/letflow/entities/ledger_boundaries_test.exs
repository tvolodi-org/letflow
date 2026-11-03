defmodule Letflow.LedgerBoundariesTest do
  @moduledoc """
  REQ-620 / GH #3463 part C, criterion 10: `mix letflow.check_boundaries` Rules 7 (neutral
  vocabulary) and 7b (no module reference but the registration module). Pure, no database.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Letflow.CheckBoundaries, as: CB

  defp scan(source), do: CB.ledger_rule_violations([{"x.ex", source}])
  defp words(source), do: for({_, :rule_7, d} <- scan(source), do: d)

  test "T-SC-1a the real ledger files are clean and both migrations are scanned" do
    paths = CB.ledger_scan_paths()
    assert "priv/repo/migrations/20261031100001_create_ledger_tables.exs" in paths
    assert "priv/repo/migrations/20261031200001_create_ledger_triggers.exs" in paths
    assert CB.ledger_rule_violations(Enum.map(paths, &{&1, File.read!(&1)})) == []
  end

  test "T-SC-1b denylisted words are flagged, neutral look-alikes pass" do
    assert [_] = words("def stock_movement, do: 1")
    assert [_] = words("def insufficient_stock, do: 1")
    assert [_] = words("x = Letflow.StockPost")
    assert [_] = words(~s|x = "items"|)
    assert [_] = words(~s|x = "warehouse_id"|)
    assert [_] = words("x = :Locations")

    assert scan("def insufficient_balance, do: :binary") == []
    assert scan(~s|x = "website lottery"|) == []
  end

  test "T-SC-1c prose is not scanned, code string literals are" do
    prose = ~S'''
    defmodule M do
      @moduledoc "stock item warehouse"
      @doc "lot serial sku"
      @typedoc "pallet"
      # inventory material bin
      def f, do: 1
    end
    '''

    assert scan(prose) == []
    assert [_] = words(~s|defmodule M do\n  def f, do: "stock"\nend|)
  end

  test "T-SC-1d Rule 7b flags module references except the registration module" do
    assert [{_, :rule_7b, _}] = scan("x = Letflow.Modules.Exam.Foo")
    assert [{_, :rule_7b, _}] = scan("alias Letflow.Modules.Catalog")
    assert [{_, :rule_7b, _}] = scan("alias Letflow.Modules")
    assert [{_, :rule_7b, _}] = scan(~s|x = "Elixir.Letflow.Modules.Exam"|)
    assert scan("x = Letflow.Modules.LedgerRegistration") == []
  end

  test "T-SC-1e a syntax error is a violation, not a raise" do
    assert [{"x.ex", :parse_error, _}] = scan("def f(, do: ")
  end

  test "T-SC-1g the allowlist starts empty (a new pair is a reviewed diff)" do
    src = File.read!("lib/mix/tasks/letflow.check_boundaries.ex")
    assert src =~ "@neutral_vocabulary_allowlist []"
  end
end
