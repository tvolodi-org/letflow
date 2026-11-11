defmodule Letflow.Engine.MetricsCountsTest do
  use ExUnit.Case, async: true

  alias Letflow.Engine
  alias Letflow.Engine.MetricsCounts

  test "MC1 Engine keeps the metrics counters API as delegates" do
    Code.ensure_loaded!(Engine)
    assert function_exported?(Engine, :count_instances_by_status, 1)
    assert function_exported?(Engine, :count_tasks_by_status, 1)
    assert function_exported?(MetricsCounts, :count_instances_by_status, 1)
    assert function_exported?(MetricsCounts, :count_tasks_by_status, 1)
  end

  test "MC2 an invalid schema name is refused before any query" do
    assert {:error, :invalid_schema_name} = Engine.count_instances_by_status(prefix: "bad name")
    assert {:error, :invalid_schema_name} = Engine.count_tasks_by_status(prefix: nil)
  end
end
