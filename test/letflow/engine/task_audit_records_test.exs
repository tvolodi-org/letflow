defmodule Letflow.Engine.TaskAuditRecordsTest do
  use ExUnit.Case, async: true

  alias Letflow.Engine
  alias Letflow.Engine.TaskAuditRecords

  test "TAR1 Engine keeps the three task-audit writers as delegates" do
    Code.ensure_loaded!(Engine)
    assert function_exported?(Engine, :record_task_activation_rejection_audit, 5)
    assert function_exported?(Engine, :record_completion_refusal_audit, 6)
    assert function_exported?(Engine, :record_service_task_advance_failure_audit, 5)
    assert function_exported?(TaskAuditRecords, :record_task_activation_rejection_audit, 5)
    assert function_exported?(TaskAuditRecords, :record_completion_refusal_audit, 6)
    assert function_exported?(TaskAuditRecords, :record_service_task_advance_failure_audit, 5)
  end

  test "TAR2 record_task_activation_rejection_audit/5 is rescue-hardened with an invalid schema" do
    # An invalid schema name means no DB is reachable: the function must still return :ok.
    assert :ok =
             Engine.record_task_activation_rejection_audit(
               Ecto.UUID.generate(),
               "node1",
               :too_deep,
               nil,
               "bad_schema_name"
             )
  end

  test "TAR3 record_service_task_advance_failure_audit/5 is rescue-hardened with an invalid schema" do
    assert :ok =
             Engine.record_service_task_advance_failure_audit(
               Ecto.UUID.generate(),
               "node1",
               :hop_limit_exceeded,
               nil,
               "bad_schema_name"
             )
  end
end
