defmodule Letflow.ProblemReports.ExportConfigTest do
  @moduledoc "T-1948 E1: the parser of LETFLOW_PROBLEM_REPORT_EXPORT_SHA256."

  use ExUnit.Case, async: true

  alias Letflow.ProblemReports.ExportConfig

  @hash String.duplicate("ab", 32)

  test "E1 blank or unset is nil, 64 lowercase hex is ok, anything else errors without the value" do
    assert ExportConfig.parse_hash(nil) == {:ok, nil}
    assert ExportConfig.parse_hash("") == {:ok, nil}
    assert ExportConfig.parse_hash("  ") == {:ok, nil}
    assert ExportConfig.parse_hash(@hash) == {:ok, @hash}
    assert ExportConfig.parse_hash(" " <> @hash <> "\n") == {:ok, @hash}

    for bad <- [String.upcase(@hash), "abc", @hash <> "0", "plain-secret-value"] do
      assert {:error, message} = ExportConfig.parse_hash(bad)
      assert message =~ "LETFLOW_PROBLEM_REPORT_EXPORT_SHA256"
      refute message =~ bad
    end
  end

  test "EC1 parse_hash/2 names its own variable and never the value" do
    assert ExportConfig.parse_hash(@hash, ExportConfig.owner_list_var()) == {:ok, @hash}
    assert ExportConfig.parse_hash(nil, "X") == {:ok, nil}

    assert {:error, message} =
             ExportConfig.parse_hash("plain-secret", ExportConfig.owner_list_var())

    assert message =~ "LETFLOW_OWNER_LIST_SHA256"
    refute message =~ "plain-secret"
  end

  test "EC2 distinct/2 refuses equal hashes without echoing either" do
    other = String.duplicate("cd", 32)
    assert ExportConfig.distinct(@hash, other) == :ok
    assert ExportConfig.distinct(nil, @hash) == :ok
    assert ExportConfig.distinct(@hash, nil) == :ok
    assert ExportConfig.distinct(nil, nil) == :ok
    assert {:error, message} = ExportConfig.distinct(@hash, @hash)
    refute message =~ @hash
    assert message =~ "LETFLOW_OWNER_LIST_SHA256"
  end
end
