defmodule Letflow.Release.TenantOnboardingCheckTest do
  @moduledoc """
  T-2220: the read-only check of one onboarded tenant (`docs/runbooks/production-tenant-onboarding.md`,
  step 8): PASS on a full tenant, not found, nothing installed, drift of one module / document type / table,
  expectations that differ, an inactive tenant, and no tenant id or schema name in the output (INV-4).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureIO

  alias Letflow.Identity
  alias Letflow.Identity.OnboardingRecord
  alias Letflow.Release.TenantOnboardingCheck, as: Check
  alias Letflow.Repo

  Code.require_file("../modules/stock/stock_fixture.exs", __DIR__)

  @moduletag timeout: 180_000

  defp tenant!(opts \\ []) do
    realm = "t2220-" <> String.slice(Ecto.UUID.generate(), 0, 8)
    fixture = Letflow.StockFixture.tenant!("t2220", realm, opts)
    {Map.put(fixture, :slug, fixture.tenant.slug), realm}
  end

  defp add_host!(tenant, host) do
    record =
      Repo.insert!(
        OnboardingRecord.insert_changeset(%OnboardingRecord{}, %{
          tenant_id: tenant.tenant_id,
          slug: tenant.slug,
          hostname: host
        })
      )

    ExUnit.Callbacks.on_exit(fn ->
      Repo.delete_all(from(r in OnboardingRecord, where: r.id == ^record.id))
    end)

    record
  end

  defp host, do: "t2220-#{System.unique_integer([:positive])}.example.test"

  defp results(report), do: Map.new(report.checks, &{&1.name, {&1.result, &1.detail}})

  defp wrapper(slug, opts) do
    parent = self()

    out =
      capture_io(fn ->
        send(
          parent,
          {:result,
           Letflow.Release.tenant_onboarding_check(slug, [start: false, halt: false] ++ opts)}
        )
      end)

    assert_received {:result, result}
    {result, out}
  end

  test "C1: a full tenant passes and the output carries no ids" do
    {tenant, realm} = tenant!()
    h = host()
    add_host!(tenant, h)

    assert {:ok, report} = Check.run(tenant.slug, realm: realm, host: h)
    assert Enum.all?(report.checks, &(&1.result == :ok))
    res = results(report)

    for id <- Check.default_modules() do
      {:ok, entry} = Letflow.Modules.Catalog.fetch(id)
      assert res["module #{id}"] == {:ok, entry.manifest().version}
    end

    {result, out} = wrapper(tenant.slug, realm: realm, host: h)
    assert {:ok, _} = result
    lines = String.split(out, "\n", trim: true)
    assert List.last(lines) == "tenant_onboarding_check #{tenant.slug}: PASS"
    refute out =~ tenant.tenant_id
    refute out =~ String.replace(tenant.tenant_id, "-", "")
    refute out =~ tenant.schema_name
  end

  test "C2: an unknown slug fails with one tenant check" do
    assert {:error, r} = Check.run("no-such-slug-" <> Ecto.UUID.generate())
    assert [%{name: "tenant", result: {:fail, :tenant_not_found}}] = r.checks
    assert {:error, r} = Check.run(nil)
    assert [%{name: "tenant", result: {:fail, :tenant_not_found}}] = r.checks

    {result, out} = wrapper("no-such-slug-x", [])
    assert {:error, _} = result
    assert out =~ "FAIL (1 failed)"
  end

  test "C3: nothing installed fails every module, document type and table" do
    {tenant, realm} = tenant!(install: false)
    assert {:error, r} = Check.run(tenant.slug, realm: realm)
    res = results(r)

    for id <- Check.default_modules(),
        do: assert(res["module #{id}"] == {{:fail, :module_missing}, nil})

    for k <- Check.document_types(),
        do: assert(elem(res["document_type #{k}"], 0) == {:fail, :document_type_missing})

    for t <- Check.tables(), do: assert(elem(res["table #{t}"], 0) == {:fail, :table_missing})
    assert elem(res["host"], 0) == {:fail, :host_missing}
  end

  test "C4: drift of one module, one document type and one table is named" do
    {tenant, realm} = tenant!()
    h = host()
    add_host!(tenant, h)

    Repo.update_all(
      from(m in Letflow.Modules.TenantModule, where: m.module_id == "codes"),
      [set: [version: "0.0.1"]],
      prefix: tenant.schema_name
    )

    # test-only DDL: the immutability triggers refuse a plain DELETE on document_types
    doc_types = ~s("#{tenant.schema_name}"."document_types")
    Repo.query!("ALTER TABLE #{doc_types} DISABLE TRIGGER USER")
    Repo.query!("DELETE FROM #{doc_types} WHERE key = 'stock_quick_count'")
    Repo.query!("ALTER TABLE #{doc_types} ENABLE TRIGGER USER")

    Repo.query!(~s(DROP TABLE "#{tenant.schema_name}"."entity_stock_quick_count_line"))

    assert {:error, r} = Check.run(tenant.slug, realm: realm, host: h)
    failed = r.checks |> Enum.reject(&(&1.result == :ok)) |> Map.new(&{&1.name, &1})

    assert Map.keys(failed) |> Enum.sort() ==
             Enum.sort([
               "module codes",
               "document_type stock_quick_count",
               "table entity_stock_quick_count_line"
             ])

    {:ok, entry} = Letflow.Modules.Catalog.fetch("codes")
    assert failed["module codes"].result == {:fail, :module_version_differs}
    assert failed["module codes"].detail == "installed 0.0.1 build #{entry.manifest().version}"
    assert failed["document_type stock_quick_count"].result == {:fail, :document_type_missing}
    assert failed["table entity_stock_quick_count_line"].result == {:fail, :table_missing}
  end

  test "C5 and C6: differing expectations, a second host row, then an inactive tenant" do
    {tenant, _realm} = tenant!()
    add_host!(tenant, host())

    assert {:error, r} =
             Check.run(tenant.slug,
               realm: "other-realm",
               host: "other.example.test",
               tenant_type: "production"
             )

    res = results(r)
    assert {{:fail, :realm_differs}, _real} = res["realm"]
    assert {{:fail, :host_differs}, _} = res["host"]
    assert {{:fail, :tenant_type_differs}, "test"} = res["tenant_type"]

    add_host!(tenant, host())
    assert {:error, r} = Check.run(tenant.slug, realm: tenant.tenant.idp_realm_id)
    assert {{:fail, :host_multiple}, nil} = results(r)["host"]

    {:ok, _} = Identity.deactivate_tenant(tenant.slug)
    assert {:error, r} = Check.run(tenant.slug)
    assert [%{name: "tenant", result: {:fail, :tenant_not_active}}] = r.checks
  end
end
