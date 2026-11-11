defmodule Letflow.Engine.ServiceTaskExhaustionTest do
  use ExUnit.Case, async: true

  alias Letflow.Engine
  alias Letflow.Engine.ServiceTaskExhaustion

  test "STE1 Engine keeps land_service_task_exhaustion/2 as a delegate" do
    Code.ensure_loaded!(Engine)
    assert function_exported?(Engine, :land_service_task_exhaustion, 2)
    assert function_exported?(ServiceTaskExhaustion, :land_service_task_exhaustion, 2)
  end

  test "STE2 a non-retriable failure is not exhaustion and touches nothing" do
    context = %{last_failure_kind: :http_non_2xx, attempt_index: 0, retry_limit: 3}

    assert {:error, :not_exhaustion} =
             Engine.land_service_task_exhaustion(context, prefix: "bad name")
  end
end
