defmodule Letflow.Release.RestoreSmokeTest do
  @moduledoc """
  T-1568 -- `Letflow.Release.RestoreSmoke` (S1-S3), the app-side smoke of
  `scripts/backup/restore_test.sh`. Called in-process with `halt: false, start: false`: a
  `System.halt` would kill the test VM, so each test that returns is itself proof of no halt.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureIO

  alias Letflow.Release
  alias Letflow.Release.RestoreSmoke
  alias Letflow.Repo
  alias Letflow.TenantFixture

  defp opts(registrations), do: [registrations: registrations, halt: false, start: false]

  describe "run/1" do
    test "S1 readable tenant schema: ok, counts the tenant, prints one smoke=ok line" do
      %{schema_name: schema} = TenantFixture.provisioned_tenant!(slug_prefix: "t1568-ok")

      {result, out} =
        with_io(fn -> Release.restore_smoke(opts([%{schema_name: schema}])) end)

      assert {:ok, %{tenants: tenants, schemas: 1, failures: []}} = result
      assert tenants >= 1
      assert [line] = String.split(out, "\n", trim: true)
      assert line =~ ~r/\Asmoke=ok tenants=\d+ schemas=1 pending_migrations=\d+\z/
    end

    test "S2 a registered tenant whose tables are gone: error with a token, no exception text" do
      %{schema_name: schema} = TenantFixture.provisioned_tenant!(slug_prefix: "t1568-bad")
      Repo.query!(~s(DROP SCHEMA "#{schema}" CASCADE))

      {result, out} =
        with_io(fn -> Release.restore_smoke(opts([%{schema_name: schema}])) end)

      assert {:error, %{failures: failures}} = result
      assert :tenant_schema_unreadable in failures
      assert out =~ "smoke=failed"
      assert out =~ "tenant_schema_unreadable"
      refute out =~ "undefined_table"
      refute out =~ "does not exist"
      refute out =~ schema
    end

    test "S3 a schema name with a quote or a semicolon is refused and never executed" do
      evil = ~s(x"; DROP TABLE public.tenants; --)
      before = Repo.query!("SELECT count(*) FROM public.tenants").rows

      assert {:error, %{failures: [:tenant_schema_name_refused], schemas: 0}} =
               RestoreSmoke.run(registrations: [%{schema_name: evil}])

      assert Repo.query!("SELECT count(*) FROM public.tenants").rows == before
    end
  end

  test "format_line carries counts and tokens only" do
    line =
      RestoreSmoke.format_line(
        {:error, %{tenants: 2, schemas: 1, pending_migrations: 0, failures: [:a_token]}}
      )

    assert line == "smoke=failed tenants=2 schemas=1 pending_migrations=0 reasons=a_token"
  end
end
