defmodule Letflow.TenantHostsTest do
  use Letflow.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  alias Letflow.{Repo, TenantFixture, TenantHosts}
  alias Letflow.Identity.{OnboardingRecord, Tenant}
  alias Letflow.Audit.Entry

  setup do
    platform = tenant!()
    target = tenant!()
    original = Application.fetch_env(:letflow, Letflow.TenantProvisioner)

    Application.put_env(:letflow, Letflow.TenantProvisioner,
      allowed_hostname_suffixes: ["qa.example", "example.com"]
    )

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:letflow, Letflow.TenantProvisioner, value)
        :error -> Application.delete_env(:letflow, Letflow.TenantProvisioner)
      end
    end)

    %{
      platform: platform,
      target: target,
      opts: [
        actor_id: Ecto.UUID.generate(),
        platform_prefix: platform.schema_name,
        trace_id: "host-trace"
      ]
    }
  end

  defp tenant! do
    t = TenantFixture.provisioned_tenant!(slug_prefix: "hosts")

    on_exit(fn ->
      Repo.delete_all(from(r in OnboardingRecord, where: r.tenant_id == ^t.tenant_id))
    end)

    t
  end

  defp host, do: "h#{System.unique_integer([:positive])}.qa.example"
  defp rows(t), do: Repo.all(from(r in OnboardingRecord, where: r.tenant_id == ^t.tenant_id))

  defp entries(t, id),
    do:
      Repo.all(
        from(e in Entry,
          where: e.resource_id == ^id and like(e.action, "%hostname%")
        ),
        prefix: t.schema_name
      )

  defp legacy!(t, host),
    do:
      Repo.insert!(
        OnboardingRecord.insert_changeset(
          %OnboardingRecord{},
          %{tenant_id: t.tenant_id, slug: t.tenant.slug, hostname: host}
        )
      )

  test "H1 H2 H3 creation, repeat and replacement preserve identity and audit attribution", c do
    h = host()

    assert {:ok, :created, r} =
             TenantHosts.set_host(c.target.tenant_id, "  " <> String.upcase(h) <> " ", c.opts)

    assert r.hostname == h
    assert r.slug == c.target.tenant.slug
    [tenant_entry] = entries(c.target, c.target.tenant_id)
    assert tenant_entry.actor_id == nil
    assert tenant_entry.trace_id == nil
    assert tenant_entry.before_state == nil
    assert tenant_entry.after_state == %{"hostname" => h, "actor_class" => "platform_operator"}
    [platform_entry] = entries(c.platform, c.target.tenant_id)
    assert platform_entry.actor_id == c.opts[:actor_id]
    assert platform_entry.trace_id == "host-trace"
    assert platform_entry.before_state == %{"hostname" => nil}

    assert platform_entry.after_state == %{
             "hostname" => h,
             "tenant_id" => c.target.tenant_id,
             "onboarding_id" => r.id,
             "outcome" => "created"
           }

    assert {:ok, :unchanged, ^r} = TenantHosts.set_host(c.target.tenant_id, h, c.opts)
    assert entries(c.target, c.target.tenant_id) == [tenant_entry]
    assert entries(c.platform, c.target.tenant_id) == [platform_entry]
    next = host()
    assert {:ok, :changed, updated} = TenantHosts.set_host(c.target.tenant_id, next, c.opts)
    assert updated.id == r.id
    assert updated.hostname == next

    assert Enum.any?(
             entries(c.platform, c.target.tenant_id),
             &(&1.before_state == %{"hostname" => h})
           )
  end

  test "H3 legacy row is normalized without changing its id", c do
    h = host()
    r = legacy!(c.target, "  " <> String.upcase(h))
    assert {:ok, :changed, updated} = TenantHosts.set_host(c.target.tenant_id, h, c.opts)
    assert updated.id == r.id
    assert updated.hostname == h
  end

  test "H4 normalized and legacy holders are refused without audit", c do
    holder = tenant!()

    for stored <- [host(), "  " <> String.upcase(host()) <> " "] do
      legacy!(holder, stored)
      normalized = stored |> String.trim() |> String.downcase()
      assert TenantHosts.taken?(normalized, nil)
      refute TenantHosts.taken?(normalized, holder.tenant_id)

      assert {:error, :hostname_taken} =
               TenantHosts.set_host(c.target.tenant_id, normalized, c.opts)
    end

    assert rows(c.target) == []
    assert entries(c.target, c.target.tenant_id) == []
    assert entries(c.platform, c.target.tenant_id) == []
  end

  @tag timeout: 60_000
  test "H5 H12 validation is bounded, fail closed, and longest suffix wins", c do
    Application.put_env(:letflow, Letflow.TenantProvisioner,
      allowed_hostname_suffixes: ["qa.example.com", "example.com"]
    )

    assert {:ok, "acme.qa.example.com"} = TenantHosts.normalize("Acme.QA.Example.com")
    assert {:ok, "acme.example.com"} = TenantHosts.normalize("Acme.Example.com")

    Application.put_env(:letflow, Letflow.TenantProvisioner,
      allowed_hostname_suffixes: ["qa.example"]
    )

    for raw <- [nil, "", "   ", 42] do
      assert {:error, :required} = TenantHosts.set_host(c.target.tenant_id, raw, c.opts)
    end

    for raw <- [
          "x.other.test",
          "a.b.qa.example",
          "*.qa.example",
          "-a.qa.example",
          String.duplicate("a", 243) <> ".qa.example",
          String.duplicate("a", 301),
          <<255, 254>> <> ".qa.example"
        ] do
      assert {:error, :invalid_hostname} = TenantHosts.set_host(c.target.tenant_id, raw, c.opts)
    end

    for slug <- Tenant.reserved_slugs() do
      assert {:error, :reserved_hostname} =
               TenantHosts.set_host(c.target.tenant_id, slug <> ".qa.example", c.opts)
    end

    # Reserved-label validation precedes suffix shape validation.
    assert {:error, :reserved_hostname} = TenantHosts.normalize("qa.example")
    assert {:error, :invalid_hostname} = TenantHosts.normalize("example")

    Application.put_env(:letflow, Letflow.TenantProvisioner, allowed_hostname_suffixes: [])
    assert {:error, :invalid_hostname} = TenantHosts.set_host(c.target.tenant_id, host(), c.opts)
    assert rows(c.target) == []
    assert entries(c.target, c.target.tenant_id) == []
  end

  test "H6 missing, unprovisioned and purged tenants cannot write", c do
    missing = Ecto.UUID.generate()
    assert {:error, :not_found} = TenantHosts.set_host(missing, host(), c.opts)
    assert {:error, :not_found} = TenantHosts.remove_host(missing, c.opts)

    {:ok, bare} =
      Letflow.Identity.create_tenant(%{
        slug: "bare-#{System.unique_integer([:positive])}",
        display_name: "Bare"
      })

    on_exit(fn -> Repo.delete!(bare) end)
    assert {:error, :not_provisioned} = TenantHosts.set_host(bare.id, host(), c.opts)
    assert {:error, :not_provisioned} = TenantHosts.remove_host(bare.id, c.opts)
    legacy!(c.target, host())
    now = DateTime.utc_now()

    Repo.insert!(
      struct(Letflow.TenantProvisioner.Lifecycle, %{
        tenant_id: c.target.tenant_id,
        lifecycle: "deleted",
        tier: "demo",
        language: "en",
        expires_at: now,
        purged_at: now
      })
    )

    on_exit(fn ->
      Repo.delete_all(
        from(l in Letflow.TenantProvisioner.Lifecycle, where: l.tenant_id == ^c.target.tenant_id)
      )
    end)

    before = rows(c.target)
    assert {:error, :tenant_purged} = TenantHosts.set_host(c.target.tenant_id, host(), c.opts)
    assert {:error, :tenant_purged} = TenantHosts.remove_host(c.target.tenant_id, c.opts)
    assert rows(c.target) == before
    assert entries(c.target, c.target.tenant_id) == []
  end

  test "H7 ambiguous legacy rows must be removed together", c do
    hosts = [host(), host()]
    Enum.each(hosts, &legacy!(c.target, &1))
    assert {:error, :ambiguous_host} = TenantHosts.set_host(c.target.tenant_id, host(), c.opts)
    assert length(rows(c.target)) == 2
    assert {:ok, :removed} = TenantHosts.remove_host(c.target.tenant_id, c.opts)
    assert rows(c.target) == []
    [entry] = entries(c.platform, c.target.tenant_id)
    assert entry.before_state == %{"hostname" => Enum.sort(hosts)}
  end

  test "H8 removal is audited, repeat is inert and frees the host", c do
    h = host()
    assert {:ok, :created, _} = TenantHosts.set_host(c.target.tenant_id, h, c.opts)
    assert {:ok, :removed} = TenantHosts.remove_host(c.target.tenant_id, c.opts)
    assert rows(c.target) == []
    tenant_entries = entries(c.target, c.target.tenant_id)
    platform_entries = entries(c.platform, c.target.tenant_id)

    assert Enum.any?(
             tenant_entries,
             &(&1.action == "tenant.hostname.removed" and
                 &1.after_state == %{"hostname" => nil, "actor_class" => "platform_operator"})
           )

    assert Enum.any?(
             platform_entries,
             &(&1.action == "platform.tenant_hostname.removed" and
                 &1.after_state == %{"hostname" => nil, "tenant_id" => c.target.tenant_id})
           )

    assert {:ok, :unchanged} = TenantHosts.remove_host(c.target.tenant_id, c.opts)
    assert entries(c.target, c.target.tenant_id) == tenant_entries
    assert entries(c.platform, c.target.tenant_id) == platform_entries
    other = tenant!()
    assert {:ok, :created, _} = TenantHosts.set_host(other.tenant_id, h, c.opts)
  end

  test "H9 H10 missing attribution and unregistered platform chain fail closed", c do
    for key <- [:actor_id, :platform_prefix] do
      opts = Keyword.delete(c.opts, key)
      assert {:error, :audit_failed} = TenantHosts.set_host(c.target.tenant_id, host(), opts)
      assert {:error, :audit_failed} = TenantHosts.remove_host(c.target.tenant_id, opts)
    end

    opts = Keyword.put(c.opts, :platform_prefix, "no_such_schema")
    assert {:error, :audit_failed} = TenantHosts.set_host(c.target.tenant_id, host(), opts)
    assert rows(c.target) == []
    assert entries(c.target, c.target.tenant_id) == []
  end

  for chain <- [:target, :platform] do
    @tag timeout: 60_000
    test "H10 #{chain} audit exception rolls back and hides the host", c do
      t = Map.fetch!(c, unquote(chain))
      Repo.query!(~s(DROP TABLE "#{t.schema_name}".audit_entries))

      on_exit(fn ->
        Repo.query!(~s"""
        CREATE TABLE IF NOT EXISTS "#{t.schema_name}".audit_entries (
          id uuid PRIMARY KEY, tenant_id uuid NOT NULL, actor_id uuid, action text NOT NULL,
          resource_type text NOT NULL, resource_id text NOT NULL,
          "timestamp" timestamp(6) without time zone NOT NULL, before_state jsonb, after_state jsonb,
          trace_id text, chain_hash text NOT NULL, prev_chain_hash text,
          inserted_at timestamp(6) without time zone NOT NULL)
        """)
      end)

      h = host()

      log =
        capture_log([level: :error], fn ->
          assert {:error, :internal} = TenantHosts.set_host(c.target.tenant_id, h, c.opts)
        end)

      assert log =~ c.target.tenant_id
      assert log =~ "Postgrex.Error"
      refute log =~ h
      assert rows(c.target) == []
      if unquote(chain) == :platform, do: assert(entries(c.target, c.target.tenant_id) == [])
    end
  end

  @tag timeout: 60_000
  test "H11 competing tenants yield one winner", c do
    other = tenant!()
    h = host()

    results =
      [c.target, other]
      |> Enum.map(fn t -> Task.async(fn -> TenantHosts.set_host(t.tenant_id, h, c.opts) end) end)
      |> Enum.map(&Task.await(&1, 30_000))

    assert Enum.count(results, &match?({:ok, :created, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :hostname_taken})) == 1
    assert Repo.aggregate(from(r in OnboardingRecord, where: r.hostname == ^h), :count) == 1
  end
end
