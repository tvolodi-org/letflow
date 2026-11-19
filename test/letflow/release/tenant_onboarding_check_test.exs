defmodule Letflow.Release.TenantOnboardingCheckTest do
  @moduledoc """
  T-2220 / T-2257: the read-only first-use report (`docs/runbooks/production-tenant-onboarding.md`,
  step 8): READY on a complete tenant, every stock definition/type/table, role and master-data gaps,
  settings, stable text/JSON, and no personal data or tenant id/schema in the output (INV-4).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureIO

  alias Letflow.ApprovalRules
  alias Letflow.Definitions.Activator
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Identity
  alias Letflow.Identity.OnboardingRecord
  alias Letflow.Identity.TenantRole
  alias Letflow.Identity.User
  alias Letflow.Modules.Locations
  alias Letflow.Modules.Org
  alias Letflow.Modules.Stock.Documents.Posting
  alias Letflow.Release.TenantOnboardingCheck, as: Check
  alias Letflow.Repo
  alias Letflow.Support.ScopeEnforcementFixture
  alias Letflow.Support.TokenMintFixture

  Code.require_file("../modules/stock/documents_fixture.exs", __DIR__)

  @moduletag timeout: 240_000
  @date ~D[2026-11-19]

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
  defp write_opts, do: %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}

  # A complete pilot: active stock processes, one active storekeeper user linked to the one active
  # employee, a legal entity with name/BIN, a linked place, app_name and shared access enabled.
  defp ready!(tenant) do
    admin = TokenMintFixture.role_holder!(tenant.schema_name, ["TENANT_ADMIN"])
    activator = Activator.from_auth_context(%{user_id: admin.id, roles: ["TENANT_ADMIN"]}, false)

    for name <- Check.process_definitions(),
        do: :ok = Posting.ensure_active(tenant.schema_name, name, activator)

    user =
      %User{}
      |> User.create_changeset(%{
        "username" => "private-storekeeper-#{System.unique_integer([:positive])}",
        "display_name" => "Private Storekeeper Name",
        "email" => "private-storekeeper@example.test"
      })
      |> Repo.insert!(prefix: tenant.schema_name)

    role =
      Repo.get_by!(TenantRole, [name: "STOREKEEPER", kind: :platform_role],
        prefix: tenant.schema_name
      )

    {:ok, %{created: true}} =
      Identity.add_group_member(role.group_id, user.id, prefix: tenant.schema_name)

    unit = Letflow.StockDocsFixture.unit!(tenant.schema_name)

    {:ok, place} =
      Locations.create_node(
        tenant.schema_name,
        %{"code" => "READY-PLACE", "name" => "Ready place", "node_kind" => "zone"},
        write_opts()
      )

    {:ok, _link} =
      Locations.link_unit_location(tenant.schema_name, unit, place["record_id"], write_opts())

    {:ok, employee} =
      Org.create_employee(
        tenant.schema_name,
        %{
          "code" => "READY-EMPLOYEE",
          "full_name" => "Private Employee Name",
          "org_unit_id" => unit,
          "user_id" => user.id
        },
        write_opts()
      )

    {:ok, _updated} =
      Identity.update_tenant_settings(tenant.slug, %{
        settings: %{"app_name" => "Private app name"}
      })

    original = Application.get_env(:letflow, :shared_stock_access_tenants, [])

    Application.put_env(
      :letflow,
      :shared_stock_access_tenants,
      Enum.uniq([tenant.slug | original])
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:letflow, :shared_stock_access_tenants, original)
    end)

    %{user: user, employee: employee, unit: unit, place: place["record_id"]}
  end

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

  test "C1: a complete tenant is READY in text and JSON, with a header and no personal data" do
    {tenant, realm} = tenant!()
    h = host()
    add_host!(tenant, h)
    ready = ready!(tenant)

    original_sha = Application.get_env(:letflow, :build_sha)
    Application.put_env(:letflow, :build_sha, "0123abc")

    ExUnit.Callbacks.on_exit(fn ->
      if is_nil(original_sha),
        do: Application.delete_env(:letflow, :build_sha),
        else: Application.put_env(:letflow, :build_sha, original_sha)
    end)

    assert {:ok, report} = Check.run(tenant.slug, realm: realm, host: h, date: @date)
    audit_count = Repo.aggregate(Letflow.Audit.Entry, :count, prefix: tenant.schema_name)
    refute Enum.any?(report.checks, &match?({:fail, _}, &1.result))
    assert report.build_sha == "0123abc"
    assert report.date == @date
    res = results(report)

    for id <- Check.default_modules() do
      {:ok, entry} = Letflow.Modules.Catalog.fetch(id)
      assert res["module #{id}"] == {:ok, entry.manifest().version}
    end

    for name <- Check.process_definitions(),
        do: assert(res["process #{name}"] == {:ok, "active=true"})

    for key <- Check.document_types(), do: assert(res["document_type #{key}"] == {:ok, nil})
    for table <- Check.tables(), do: assert(res["table #{table}"] == {:ok, nil})
    assert res["platform role groups"] |> elem(0) == :ok
    assert res["storekeeper users"] == {:ok, "count=1"}
    assert res["active employees"] == {:ok, "count=1"}
    assert res["employee user links"] == {:ok, "count=1 gaps=0"}
    assert res["place org unit links"] == {:ok, "count=1"}
    assert res["org unit legal entities"] == {:ok, "count=1"}
    assert res["settings app_name"] == {:ok, "set=true"}
    assert res["shared stock access"] == {:info, "enabled=true"}
    assert res["scope enforcement"] == {:ok, "mode=off"}
    assert res["ledger settings"] == {:info, "registration=stock allow_negative=false"}
    assert res["four-eyes"] |> elem(0) == :info

    {result, out} = wrapper(tenant.slug, realm: realm, host: h, date: @date)
    assert {:ok, _} = result
    lines = String.split(out, "\n", trim: true)

    assert Enum.take(lines, 3) == [
             "tenant: #{tenant.slug}",
             "build_sha: 0123abc",
             "date: 2026-11-19"
           ]

    assert Enum.any?(lines, &String.starts_with?(&1, "OK process stock_receipt"))
    assert Enum.any?(lines, &String.starts_with?(&1, "INFO ledger settings"))
    assert List.last(lines) == "READY"

    {json_result, json_out} =
      wrapper(tenant.slug, realm: realm, host: h, date: @date, format: :json)

    assert {:ok, _} = json_result
    decoded = json_out |> Jason.decode!()
    assert decoded["slug"] == tenant.slug
    assert decoded["build_sha"] == "0123abc"
    assert decoded["date"] == "2026-11-19"
    assert decoded["status"] == "ready"
    assert length(decoded["checks"]) == length(report.checks)
    assert Enum.any?(decoded["checks"], &(&1["status"] == "info"))

    for private <- [
          tenant.tenant_id,
          String.replace(tenant.tenant_id, "-", ""),
          tenant.schema_name,
          ready.user.username,
          ready.user.display_name,
          ready.user.email,
          "Private Employee Name",
          "Private app name"
        ] do
      refute out =~ private
      refute json_out =~ private
    end

    assert Repo.aggregate(Letflow.Audit.Entry, :count, prefix: tenant.schema_name) == audit_count
  end

  test "C2: an unknown slug fails with one tenant check and a RED final line" do
    assert {:error, r} = Check.run("no-such-slug-" <> Ecto.UUID.generate())
    assert [%{name: "tenant", result: {:fail, :tenant_not_found}}] = r.checks
    assert {:error, r} = Check.run(nil)
    assert [%{name: "tenant", result: {:fail, :tenant_not_found}}] = r.checks

    {result, out} = wrapper("no-such-slug-x", date: @date)
    assert {:error, _} = result
    assert List.last(String.split(out, "\n", trim: true)) == "RED tenant"

    {json_result, json_out} = wrapper("no-such-slug-x", date: @date, format: :json)
    assert {:error, _} = json_result
    decoded = Jason.decode!(json_out)
    assert decoded["status"] == "red"

    assert [%{"name" => "tenant", "status" => "red", "reason" => "tenant_not_found"}] =
             decoded["checks"]
  end

  test "C3: nothing installed fails every module, process, document type and table" do
    {tenant, realm} = tenant!(install: false)
    assert {:error, r} = Check.run(tenant.slug, realm: realm)
    res = results(r)

    for id <- Check.default_modules(),
        do: assert(res["module #{id}"] == {{:fail, :module_missing}, nil})

    for name <- Check.process_definitions(),
        do: assert(elem(res["process #{name}"], 0) == {:fail, :process_not_active})

    for k <- Check.document_types(),
        do: assert(elem(res["document_type #{k}"], 0) == {:fail, :document_type_missing})

    for t <- Check.tables(), do: assert(elem(res["table #{t}"], 0) == {:fail, :table_missing})
    assert elem(res["host"], 0) == {:fail, :host_missing}
    assert elem(res["active employees"], 0) == {:fail, :active_employee_count}
  end

  test "C4: drift of one module, one document type and one table is named" do
    {tenant, realm} = tenant!()
    h = host()
    add_host!(tenant, h)
    ready!(tenant)

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

    failed =
      r.checks
      |> Enum.reject(&(&1.result == :ok or &1.result == :info))
      |> Map.new(&{&1.name, &1})

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

  test "C7: every first-use gap is RED and four-eyes/ledger values stay informational" do
    {tenant, realm} = tenant!()
    h = host()
    add_host!(tenant, h)
    ready = ready!(tenant)

    Repo.update_all(
      from(d in ProcessDefinition, where: d.name == "stock_receipt"),
      [set: [needs_reactivation_at: DateTime.utc_now(), needs_reactivation_reason: "test"]],
      prefix: tenant.schema_name
    )

    second_storekeeper =
      %User{}
      |> User.create_changeset(%{
        "username" => "second-private-storekeeper-#{System.unique_integer([:positive])}",
        "display_name" => "Second Private Storekeeper",
        "email" => "second-private-storekeeper@example.test"
      })
      |> Repo.insert!(prefix: tenant.schema_name)

    storekeeper_role =
      Repo.get_by!(TenantRole, [name: "STOREKEEPER", kind: :platform_role],
        prefix: tenant.schema_name
      )

    {:ok, %{created: true}} =
      Identity.add_group_member(storekeeper_role.group_id, second_storekeeper.id,
        prefix: tenant.schema_name
      )

    # Membership alone is not enough: /me/access has STOREKEEPER, but the user still needs an
    # active employee mapping for the old address.
    assert {:error, membership_report} = Check.run(tenant.slug, realm: realm, host: h)

    assert results(membership_report)["storekeeper users"] ==
             {{:fail, :storekeeper_link_missing}, "count=2 gaps=1"}

    refute Check.format_lines(membership_report) |> Enum.join("\n") =~
             second_storekeeper.username

    Repo.delete_all(
      from(r in TenantRole, where: r.name == "STOREKEEPER" and r.kind == :platform_role),
      prefix: tenant.schema_name
    )

    {:ok, _} =
      Locations.unlink_unit_location(tenant.schema_name, ready.unit, ready.place, write_opts())

    Letflow.OrgFixture.create!(
      tenant.schema_name,
      "org_unit",
      Letflow.OrgFixture.values("org_unit", "NO-COMPANY", %{
        "name" => "Unit without company",
        "legal_entity_id" => Ecto.UUID.generate()
      })
    )

    {:ok, _} =
      Org.create_employee(
        tenant.schema_name,
        %{
          "code" => "UNLINKED-EMPLOYEE",
          "full_name" => "Second Private Employee",
          "org_unit_id" => ready.unit
        },
        write_opts()
      )

    {:ok, _} = Identity.update_tenant_settings(tenant.slug, %{settings: %{}})
    ScopeEnforcementFixture.set_stored_mode!(tenant.tenant_id, :on)

    {:ok, four_eyes} =
      ApprovalRules.put(
        tenant.schema_name,
        "stock_quick_count",
        "approve",
        %{"four_eyes" => false, "reason" => "readiness report test"},
        %{user_id: ready.user.id, trace_id: nil}
      )

    refute four_eyes.four_eyes

    assert {:error, report} = Check.run(tenant.slug, realm: realm, host: h)

    failed =
      report.checks |> Enum.filter(&match?({:fail, _}, &1.result)) |> Map.new(&{&1.name, &1})

    assert Map.keys(failed) |> Enum.sort() ==
             Enum.sort([
               "process stock_receipt",
               "platform role groups",
               "storekeeper users",
               "place org unit links",
               "org unit legal entities",
               "active employees",
               "employee user links",
               "settings app_name",
               "scope enforcement"
             ])

    assert failed["process stock_receipt"].result == {:fail, :reactivation_required}
    assert failed["platform role groups"].detail == "missing=STOREKEEPER"
    assert failed["storekeeper users"].result == {:fail, :storekeeper_missing}
    assert failed["place org unit links"].detail =~ "Ready place"
    assert failed["org unit legal entities"].detail =~ "Unit without company"
    assert failed["active employees"].detail == "count=2 expected=1"
    assert failed["employee user links"].detail == "count=2 gaps=1"
    assert failed["settings app_name"].result == {:fail, :app_name_missing}
    assert failed["scope enforcement"].result == {:fail, :scope_enforcement_active}

    res = results(report)
    assert res["ledger settings"] == {:info, "registration=stock allow_negative=false"}
    assert {:info, four_eyes_detail} = res["four-eyes"]
    assert four_eyes_detail =~ "off=1"
    assert four_eyes_detail =~ "stock_quick_count.approve=off"

    lines = Check.format_lines(report)
    assert List.last(lines) =~ ~r/^RED /
    assert List.last(lines) =~ "process stock_receipt"
    assert List.last(lines) =~ "employee user links"
    refute Enum.join(lines, "\n") =~ "Second Private Employee"
  end
end
