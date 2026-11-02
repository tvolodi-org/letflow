Code.require_file("org_fixture.exs", __DIR__)

defmodule Letflow.Modules.Org.WritersTest do
  @moduledoc """
  GH #3619 / REQ-660: the legal company and site writers of module `org` on real provisioned
  tenants (tests U, B, C, R, A, T, D, S of the design). `async: false`: tenant provisioning
  switches the sandbox to `:auto` and the install runs DDL.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit
  alias Letflow.Entities.Record.Latest
  alias Letflow.Modules.Org
  alias Letflow.OrgFixture

  @bin "123456789012"
  @bin2 "210987654321"
  @masters_path Path.join(File.cwd!(), "lib/letflow/modules/org/masters.ex")

  setup do
    {:ok, OrgFixture.installed_tenant!("gh3619-org")}
  end

  defp opts(key \\ nil),
    do: %{actor_id: Ecto.UUID.generate(), idempotency_key: key || Ecto.UUID.generate()}

  defp count(schema, type),
    do: Repo.aggregate(from(l in Latest, where: l.entity_type == ^type), :count, prefix: schema)

  defp audit_rows(schema) do
    Repo.all(
      from(e in Audit.Entry,
        where: like(e.action, "org_legal_entity.%") or like(e.action, "org_site.%"),
        order_by: e.timestamp
      ),
      prefix: schema
    )
  end

  defp assert_refused(ctx, expected, fun) do
    before = {count(ctx.schema, "org_legal_entity"), count(ctx.schema, "org_site")}
    before_audit = length(audit_rows(ctx.schema))
    assert fun.() == expected
    assert {count(ctx.schema, "org_legal_entity"), count(ctx.schema, "org_site")} == before
    assert length(audit_rows(ctx.schema)) == before_audit
  end

  defp company!(schema, code, bin \\ @bin) do
    {:ok, c} =
      Org.create_legal_entity(
        schema,
        %{"code" => code, "name" => "N #{code}", "bin" => bin},
        opts()
      )

    c
  end

  defp site!(schema, code, company_id) do
    {:ok, s} =
      Org.create_site(
        schema,
        %{"code" => code, "name" => "S #{code}", "legal_entity_id" => company_id},
        opts()
      )

    s
  end

  defp unit!(schema, code, extra) do
    OrgFixture.create!(schema, "org_unit", OrgFixture.values("org_unit", code, extra))
  end

  # --- AC 1 -----------------------------------------------------------------------------------

  test "U-01 six functions are exported, create returns the lookup map with active true", ctx do
    for {f, a} <- [
          create_legal_entity: 3,
          update_legal_entity: 4,
          retire_legal_entity: 3,
          create_site: 3,
          update_site: 4,
          retire_site: 3
        ] do
      assert function_exported?(Org, f, a)
    end

    c = company!(ctx.schema, "C1")
    assert c["active"] == true and c["entity_type"] == "org_legal_entity"
    assert {:ok, c} == Org.lookup(ctx.schema, c["record_id"])
    assert c["bin"] == @bin

    s = site!(ctx.schema, "S1", c["record_id"])
    assert s["active"] == true and s["legal_entity_id"] == c["record_id"]
    assert {:ok, s} == Org.lookup(ctx.schema, s["record_id"])
  end

  test "U-02 update changes each updatable field, nil clears the external reference", ctx do
    c = company!(ctx.schema, "C2")
    c2 = company!(ctx.schema, "C2B", @bin2)

    {:ok, c} =
      Org.update_legal_entity(
        ctx.schema,
        c["record_id"],
        %{
          "name" => "New",
          "bin" => "999999999999",
          "external_ref_system" => "erp",
          "external_ref_id" => "1"
        },
        opts()
      )

    assert c["name"] == "New" and c["bin"] == "999999999999" and c["external_ref_id"] == "1"
    assert c["code"] == "C2" and c["active"] == true

    {:ok, c} =
      Org.update_legal_entity(
        ctx.schema,
        c["record_id"],
        %{"external_ref_system" => nil, "external_ref_id" => nil},
        opts()
      )

    refute Map.has_key?(c, "external_ref_system")

    s = site!(ctx.schema, "S2", c["record_id"])

    {:ok, s} =
      Org.update_site(
        ctx.schema,
        s["record_id"],
        %{"name" => "Other", "legal_entity_id" => c2["record_id"], "external_ref_id" => "9"},
        opts()
      )

    assert s["name"] == "Other" and s["legal_entity_id"] == c2["record_id"]
    assert s["external_ref_id"] == "9" and s["code"] == "S2"
  end

  test "U-03 retire sets active false", ctx do
    c = company!(ctx.schema, "C3")
    s = site!(ctx.schema, "S3", c["record_id"])
    assert {:ok, %{"active" => false}} = Org.retire_site(ctx.schema, s["record_id"], opts())

    assert {:ok, %{"active" => false}} =
             Org.retire_legal_entity(ctx.schema, c["record_id"], opts())
  end

  # --- AC 2 -----------------------------------------------------------------------------------

  test "B-01..B-05, B-10 a malformed bin is field_invalid and writes nothing", ctx do
    for bad <- [
          "12345678901",
          "1234567890123",
          "12345678901a",
          "12345678901 ",
          123_456_789_012,
          nil,
          "123456789012\n",
          "１２３４５６７８９０１２",
          "",
          "12345678901٣"
        ] do
      assert_refused(ctx, {:error, {:field_invalid, "bin"}}, fn ->
        Org.create_legal_entity(ctx.schema, %{"code" => "X", "name" => "X", "bin" => bad}, opts())
      end)
    end

    assert_refused(ctx, {:error, {:field_invalid, "bin"}}, fn ->
      Org.create_legal_entity(ctx.schema, %{"code" => "X", "name" => "X"}, opts())
    end)

    c = company!(ctx.schema, "CB")

    assert_refused(ctx, {:error, {:field_invalid, "bin"}}, fn ->
      Org.update_legal_entity(ctx.schema, c["record_id"], %{"bin" => "123"}, opts())
    end)
  end

  test "B-06 B-07 bin held by another active company is bin_taken", ctx do
    company!(ctx.schema, "C6")

    assert_refused(ctx, {:error, :bin_taken}, fn ->
      Org.create_legal_entity(
        ctx.schema,
        %{"code" => "C6B", "name" => "n", "bin" => @bin},
        opts()
      )
    end)

    other = company!(ctx.schema, "C7", @bin2)

    assert_refused(ctx, {:error, :bin_taken}, fn ->
      Org.update_legal_entity(ctx.schema, other["record_id"], %{"bin" => @bin}, opts())
    end)
  end

  test "B-08 B-09 B-11 retired holders", ctx do
    c = company!(ctx.schema, "C8")
    {:ok, _} = Org.retire_legal_entity(ctx.schema, c["record_id"], opts())
    assert %{"bin" => @bin} = company!(ctx.schema, "C8B")

    # own unchanged bin is accepted
    live = company!(ctx.schema, "C9", @bin2)

    assert {:ok, _} =
             Org.update_legal_entity(ctx.schema, live["record_id"], %{"bin" => @bin2}, opts())

    # the retired one cannot move to a live bin (it still stores its own bin)
    assert_refused(ctx, {:error, :bin_taken}, fn ->
      Org.update_legal_entity(ctx.schema, c["record_id"], %{"bin" => @bin2}, opts())
    end)
  end

  # --- AC 3 -----------------------------------------------------------------------------------

  test "C-01 two concurrent creates with one bin: one ok, one bin_taken", ctx do
    run = fn code ->
      Task.async(fn ->
        Org.create_legal_entity(
          ctx.schema,
          %{"code" => code, "name" => "n", "bin" => @bin},
          opts()
        )
      end)
    end

    results = Enum.map([run.("K1"), run.("K2")], &Task.await(&1, 30_000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :bin_taken})) == 1
    assert count(ctx.schema, "org_legal_entity") == 1
  end

  test "C-02 the lock key text is passed as a bound parameter" do
    src = File.read!(@masters_path)
    assert src =~ ~s(":org_legal_entity_bin")
    assert src =~ "pg_advisory_xact_lock(hashtextextended($1, 0))"

    assert src =~
             ~r/Repo\.query!\("SELECT pg_advisory_xact_lock\(hashtextextended\(\$1, 0\)\)", \[/

    refute src =~ ~r/Repo\.query!?\([^)]*#\{/
  end

  # --- AC 4 -----------------------------------------------------------------------------------

  test "R-01 field_not_allowed", ctx do
    c = company!(ctx.schema, "R1")
    s = site!(ctx.schema, "R1S", c["record_id"])

    assert_refused(ctx, {:error, {:field_not_allowed, "active"}}, fn ->
      Org.create_legal_entity(
        ctx.schema,
        %{"code" => "Z", "name" => "n", "bin" => @bin2, "active" => false},
        opts()
      )
    end)

    assert_refused(ctx, {:error, {:field_not_allowed, "foo"}}, fn ->
      Org.create_site(ctx.schema, %{"foo" => 1}, opts())
    end)

    assert_refused(ctx, {:error, {:field_not_allowed, "code"}}, fn ->
      Org.update_legal_entity(ctx.schema, c["record_id"], %{"code" => "Q"}, opts())
    end)

    assert_refused(ctx, {:error, {:field_not_allowed, "code"}}, fn ->
      Org.update_site(ctx.schema, s["record_id"], %{"code" => "Q"}, opts())
    end)

    assert_refused(ctx, {:error, {:field_not_allowed, "active"}}, fn ->
      Org.update_site(ctx.schema, s["record_id"], %{"active" => false}, opts())
    end)
  end

  test "R-02 blank, missing or non-string code or name is field_invalid", ctx do
    c = company!(ctx.schema, "R2")

    for {attrs, key} <- [
          {%{"name" => "n", "bin" => @bin2}, "code"},
          {%{"code" => " ", "name" => "n", "bin" => @bin2}, "code"},
          {%{"code" => 5, "name" => "n", "bin" => @bin2}, "code"},
          {%{"code" => "A", "bin" => @bin2}, "name"},
          {%{"code" => "A", "name" => "", "bin" => @bin2}, "name"}
        ] do
      assert_refused(ctx, {:error, {:field_invalid, key}}, fn ->
        Org.create_legal_entity(ctx.schema, attrs, opts())
      end)
    end

    assert_refused(ctx, {:error, {:field_invalid, "code"}}, fn ->
      Org.create_site(
        ctx.schema,
        %{"name" => "n", "legal_entity_id" => c["record_id"]},
        opts()
      )
    end)

    assert_refused(ctx, {:error, {:field_invalid, "name"}}, fn ->
      Org.update_legal_entity(ctx.schema, c["record_id"], %{"name" => " "}, opts())
    end)

    assert_refused(ctx, {:error, {:field_invalid, "attrs"}}, fn ->
      Org.create_site(ctx.schema, "nope", opts())
    end)
  end

  test "R-03 a duplicate code is record_payload_invalid", ctx do
    c = company!(ctx.schema, "DUP")

    assert_refused(ctx, nil, fn ->
      {:error, {:record_payload_invalid, _}} =
        Org.create_legal_entity(
          ctx.schema,
          %{"code" => "DUP", "name" => "n", "bin" => @bin2},
          opts()
        )

      nil
    end)

    site!(ctx.schema, "SDUP", c["record_id"])

    assert_refused(ctx, nil, fn ->
      {:error, {:record_payload_invalid, _}} =
        Org.create_site(
          ctx.schema,
          %{"code" => "SDUP", "name" => "n", "legal_entity_id" => c["record_id"]},
          opts()
        )

      nil
    end)
  end

  test "R-04 R-05 site company refusals", ctx do
    live = company!(ctx.schema, "R4")
    site = site!(ctx.schema, "R4S", live["record_id"])
    gone = company!(ctx.schema, "R4G", @bin2)

    OrgFixture.delete!(ctx.schema, %{
      entity_type: "org_legal_entity",
      record_id: gone["record_id"]
    })

    for bad <- [nil, 5, "x", Ecto.UUID.generate(), gone["record_id"], site["record_id"]] do
      assert_refused(ctx, {:error, :legal_entity_not_found}, fn ->
        Org.create_site(
          ctx.schema,
          %{"code" => "Q", "name" => "n", "legal_entity_id" => bad},
          opts()
        )
      end)

      assert_refused(ctx, {:error, :legal_entity_not_found}, fn ->
        Org.update_site(ctx.schema, site["record_id"], %{"legal_entity_id" => bad}, opts())
      end)
    end

    other = company!(ctx.schema, "R5", "555555555555")
    {:ok, _} = Org.retire_legal_entity(ctx.schema, other["record_id"], opts())

    assert_refused(ctx, {:error, :legal_entity_inactive}, fn ->
      Org.create_site(
        ctx.schema,
        %{"code" => "Q", "name" => "n", "legal_entity_id" => other["record_id"]},
        opts()
      )
    end)

    assert_refused(ctx, {:error, :legal_entity_inactive}, fn ->
      Org.update_site(
        ctx.schema,
        site["record_id"],
        %{"legal_entity_id" => other["record_id"]},
        opts()
      )
    end)
  end

  test "R-06 R-07 R-08 in-use refusals", ctx do
    c = company!(ctx.schema, "R6")
    s = site!(ctx.schema, "R6S", c["record_id"])

    assert_refused(ctx, {:error, :legal_entity_in_use}, fn ->
      Org.retire_legal_entity(ctx.schema, c["record_id"], opts())
    end)

    {:ok, _} = Org.retire_site(ctx.schema, s["record_id"], opts())

    c2 = company!(ctx.schema, "R6B", @bin2)
    s2 = site!(ctx.schema, "R6BS", c2["record_id"])
    {:ok, _} = Org.retire_site(ctx.schema, s2["record_id"], opts())

    unit =
      unit!(ctx.schema, "U1", %{"legal_entity_id" => c["record_id"], "site_id" => s2["record_id"]})

    assert_refused(ctx, {:error, :legal_entity_in_use}, fn ->
      Org.retire_legal_entity(ctx.schema, c["record_id"], opts())
    end)

    s3 = site!(ctx.schema, "R6C", c2["record_id"])
    unit!(ctx.schema, "U2", %{"legal_entity_id" => c2["record_id"], "site_id" => s3["record_id"]})

    assert_refused(ctx, {:error, :site_in_use}, fn ->
      Org.retire_site(ctx.schema, s3["record_id"], opts())
    end)

    # R-08: after the unit is deactivated the retire goes through
    {:ok, _} =
      Letflow.Entities.Records.update_record(
        %{
          entity_type: "org_unit",
          record_id: unit.record_id,
          field_values: Map.put(unit.field_values, "active", false),
          actor_id: Ecto.UUID.generate(),
          idempotency_key: Ecto.UUID.generate()
        },
        ctx.schema,
        OrgFixture.owner()
      )

    assert {:ok, %{"active" => false}} =
             Org.retire_legal_entity(ctx.schema, c["record_id"], opts())
  end

  # --- AC 5 -----------------------------------------------------------------------------------

  test "A-01 each accepted call writes exactly one audit row", ctx do
    actor = Ecto.UUID.generate()
    o = fn -> %{actor_id: actor, idempotency_key: Ecto.UUID.generate()} end

    {:ok, c} =
      Org.create_legal_entity(ctx.schema, %{"code" => "A1", "name" => "n", "bin" => @bin}, o.())

    {:ok, c2} = Org.update_legal_entity(ctx.schema, c["record_id"], %{"name" => "m"}, o.())

    {:ok, s} =
      Org.create_site(
        ctx.schema,
        %{"code" => "A1S", "name" => "n", "legal_entity_id" => c["record_id"]},
        o.()
      )

    {:ok, _} = Org.update_site(ctx.schema, s["record_id"], %{"name" => "m"}, o.())
    {:ok, _} = Org.retire_site(ctx.schema, s["record_id"], o.())
    {:ok, _} = Org.retire_legal_entity(ctx.schema, c["record_id"], o.())

    rows = audit_rows(ctx.schema)

    assert Enum.map(rows, & &1.action) |> Enum.sort() ==
             Enum.sort(
               ~w(org_legal_entity.created org_legal_entity.updated org_legal_entity.retired
                          org_site.created org_site.updated org_site.retired)
             )

    assert Enum.all?(rows, &(&1.actor_id == actor))
    created = Enum.find(rows, &(&1.action == "org_legal_entity.created"))
    assert created.resource_id == c["record_id"] and created.before_state in [nil, %{}]
    assert created.after_state["bin"] == @bin
    updated = Enum.find(rows, &(&1.action == "org_legal_entity.updated"))
    assert updated.before_state["name"] == "n" and updated.after_state["name"] == "m"
    assert c2["name"] == "m"
  end

  test "A-02 a failing audit insert rolls the record back" do
    ctx = OrgFixture.installed_tenant!("gh3619-aud")

    Repo.query!(~s(DROP TABLE "#{ctx.schema}".audit_entries))

    assert {:error, :audit_failed} =
             Org.create_legal_entity(
               ctx.schema,
               %{"code" => "AF", "name" => "n", "bin" => @bin},
               opts()
             )

    assert count(ctx.schema, "org_legal_entity") == 0
  end

  test "A-03 A-04 A-06 replay writes nothing twice", ctx do
    key = Ecto.UUID.generate()
    attrs = %{"code" => "RP", "name" => "n", "bin" => @bin}
    o = %{actor_id: Ecto.UUID.generate(), idempotency_key: key}

    {:ok, c} = Org.create_legal_entity(ctx.schema, attrs, o)
    assert {:ok, ^c} = Org.create_legal_entity(ctx.schema, attrs, o)
    assert count(ctx.schema, "org_legal_entity") == 1
    assert length(audit_rows(ctx.schema)) == 1

    assert {:error, :idempotency_key_reuse} =
             Org.create_legal_entity(ctx.schema, Map.put(attrs, "name", "other"), o)

    # a later retire does not break the replay of the create
    {:ok, _} = Org.retire_legal_entity(ctx.schema, c["record_id"], opts())
    # the replay answers the same record (read back as it is now), without a bin_taken or a write
    assert {:ok, %{"record_id" => id}} = Org.create_legal_entity(ctx.schema, attrs, o)
    assert id == c["record_id"]
    assert count(ctx.schema, "org_legal_entity") == 1
    assert length(audit_rows(ctx.schema)) == 2

    # update replay
    c3 = company!(ctx.schema, "RP2", @bin2)
    uk = %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}
    {:ok, up} = Org.update_legal_entity(ctx.schema, c3["record_id"], %{"name" => "z"}, uk)
    n = length(audit_rows(ctx.schema))
    assert {:ok, ^up} = Org.update_legal_entity(ctx.schema, c3["record_id"], %{"name" => "z"}, uk)
    assert length(audit_rows(ctx.schema)) == n

    # retire replay
    rk = %{actor_id: Ecto.UUID.generate(), idempotency_key: Ecto.UUID.generate()}
    {:ok, r} = Org.retire_legal_entity(ctx.schema, c3["record_id"], rk)
    n = length(audit_rows(ctx.schema))
    assert {:ok, ^r} = Org.retire_legal_entity(ctx.schema, c3["record_id"], rk)
    assert length(audit_rows(ctx.schema)) == n
  end

  test "A-05 retiring a retired record writes neither record nor audit entry", ctx do
    c = company!(ctx.schema, "A5")
    s = site!(ctx.schema, "A5S", c["record_id"])
    {:ok, _} = Org.retire_site(ctx.schema, s["record_id"], opts())
    {:ok, r} = Org.retire_legal_entity(ctx.schema, c["record_id"], opts())
    n = length(audit_rows(ctx.schema))
    assert {:ok, ^r} = Org.retire_legal_entity(ctx.schema, c["record_id"], opts())
    assert {:ok, %{"active" => false}} = Org.retire_site(ctx.schema, s["record_id"], opts())
    assert length(audit_rows(ctx.schema)) == n
  end

  # --- AC 6 -----------------------------------------------------------------------------------

  test "T-01..T-03 two tenants" do
    a = OrgFixture.installed_tenant!("gh3619-ta")
    b = OrgFixture.installed_tenant!("gh3619-tb")
    ca = company!(a.schema, "TA")
    sa = site!(a.schema, "TAS", ca["record_id"])
    unknown = Ecto.UUID.generate()

    for id <- [ca["record_id"], unknown] do
      assert {:error, :legal_entity_not_found} =
               Org.update_legal_entity(b.schema, id, %{"name" => "x"}, opts())

      assert {:error, :legal_entity_not_found} = Org.retire_legal_entity(b.schema, id, opts())
    end

    for id <- [sa["record_id"], unknown] do
      assert {:error, :site_not_found} = Org.update_site(b.schema, id, %{"name" => "x"}, opts())
      assert {:error, :site_not_found} = Org.retire_site(b.schema, id, opts())
    end

    assert {:error, :legal_entity_not_found} =
             Org.create_site(
               b.schema,
               %{"code" => "X", "name" => "n", "legal_entity_id" => ca["record_id"]},
               opts()
             )

    assert count(b.schema, "org_legal_entity") == 0 and count(b.schema, "org_site") == 0
    assert {:ok, %{"name" => "N TA", "active" => true}} = Org.lookup(a.schema, ca["record_id"])

    # same bin in both tenants
    assert %{"bin" => @bin} = company!(b.schema, "TB")
  end

  test "T-04 tenant_id is not an attrs key and the module never reads one" do
    ctx = OrgFixture.installed_tenant!("gh3619-t4")

    assert {:error, {:field_not_allowed, "tenant_id"}} =
             Org.create_legal_entity(
               ctx.schema,
               %{"code" => "T", "name" => "n", "bin" => @bin, "tenant_id" => "x"},
               opts()
             )

    refute File.read!(@masters_path) =~ "tenant_id"
  end

  # --- AC 7 / 8 -------------------------------------------------------------------------------

  test "D-02 the org.ex moduledoc names the six functions" do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(Org)

    for f <- ~w(create_legal_entity/3 update_legal_entity/4 retire_legal_entity/3 create_site/3
                update_site/4 retire_site/3) do
      assert doc =~ f
    end
  end

  test "S-01 no writer takes a principal or scope set; arities are 3/4/3" do
    for {f, a} <- [
          create_legal_entity: 3,
          update_legal_entity: 4,
          retire_legal_entity: 3,
          create_site: 3,
          update_site: 4,
          retire_site: 3
        ] do
      assert function_exported?(Letflow.Modules.Org.Masters, f, a)
      refute function_exported?(Letflow.Modules.Org.Masters, f, a + 1)
    end

    src = File.read!(@masters_path)
    refute src =~ ~r/\bprincipal\b/
  end
end
