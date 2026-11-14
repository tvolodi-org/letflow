defmodule Letflow.CreateProblemReportsTest do
  @moduledoc """
  T-1948 MG1: the tenant migration that creates the empty `problem_reports` table: manifest
  registration, shape, the `seq` unique index and the text CHECK. `async: false` (tenant DDL).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Repo.Migrations.CreateProblemReports
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning

  @version 20_261_114_100_001

  setup do
    tenant = TenantFixture.provisioned_tenant!(slug_prefix: "t1948-mig")
    {:ok, schema: tenant.schema_name, tenant_id: tenant.tenant_id}
  end

  test "MG1 registered, in the expected tenant tables, starts empty with the planned columns", %{
    schema: schema
  } do
    assert {@version, CreateProblemReports} =
             List.keyfind(TenantProvisioning.tenant_scoped_migrations(), @version, 0)

    assert "problem_reports" in TenantFixture.expected_tenant_tables()
    assert %{rows: [[0]]} = Repo.query!(~s|SELECT count(*) FROM "#{schema}".problem_reports|)

    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns " <>
          "WHERE table_schema = $1 AND table_name = 'problem_reports'",
        [schema]
      )

    assert rows |> List.flatten() |> Enum.sort() ==
             ~w(consented_at context id inserted_at reporter_name reporter_permissions reporter_roles reporter_tenant_id reporter_tenant_name reporter_user_id seq server_version tenant_id text trace_id)

    %{rows: [[idx]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_indexes WHERE schemaname = $1 AND tablename = 'problem_reports' " <>
          "AND indexname = 'problem_reports_seq_index'",
        [schema]
      )

    assert idx == 1
  end

  test "MG1 the text CHECK refuses an empty and a 4001-character text", %{schema: schema} do
    insert = fn text ->
      Repo.query(
        ~s|INSERT INTO "#{schema}".problem_reports (id, tenant_id, reporter_tenant_id, reporter_user_id, text, consented_at, inserted_at) | <>
          "VALUES (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), $1, now(), now())",
        [text]
      )
    end

    assert {:ok, _} = insert.("x")
    assert {:ok, _} = insert.(String.duplicate("a", 4000))

    assert {:error, %Postgrex.Error{}} =
             Repo.transaction(fn -> insert.("") |> elem_error() end) |> unwrap()

    assert {:error, %Postgrex.Error{}} =
             Repo.transaction(fn -> insert.(String.duplicate("a", 4001)) |> elem_error() end)
             |> unwrap()
  end

  defp elem_error({:error, error}), do: Repo.rollback(error)
  defp unwrap({:error, error}), do: {:error, error}
end
