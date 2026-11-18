defmodule Letflow.Req442LoginDirectoryDiscloseTest do
  @moduledoc """
  REQ-442 AC4 (the disclose matrix, one test per cell, exactly one query),
  AC5 (the match type) and AC6 (no `:prefix`, `log: false`) for
  `Letflow.LoginDirectory.lookup_by_keys/2`. See `test/specs/REQ-442.md`.

  `async: false`: one test swaps the global `Letflow.LoginDiscovery`
  application env (restored in `on_exit/1`) and tenants are provisioned for real.
  All tenants of a test are provisioned BEFORE any write (fixture rule), and the
  mode column is set through the same Repo the lookup reads.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Letflow.Identity.Tenant
  alias Letflow.LoginDirectory
  alias Letflow.Test.LoginDirectoryFixture, as: Fx

  @login_directory_source "lib/letflow/login_directory.ex"

  defp in_tx(fun) do
    {:ok, result} = Repo.transaction(fn -> fun.() end)
    result
  end

  defp set_mode!(%{tenant_id: tenant_id}, mode) do
    {1, _} =
      Repo.update_all(from(t in Tenant, where: t.id == ^tenant_id),
        set: [login_disclosure_mode: mode]
      )

    :ok
  end

  # One tenant holding a unique email in the directory, with the given stored mode.
  defp tenant_with_entry!(stored_mode) do
    tenant = Fx.tenant!(display_name: "REQ-442 Tenant")
    email = Fx.unique_email("r442")
    {:ok, keys} = LoginDirectory.email_keys(email)
    set_mode!(tenant, stored_mode)
    in_tx(fn -> LoginDirectory.upsert_entry(tenant.tenant_id, email) end)
    slug = Repo.get!(Tenant, tenant.tenant_id).slug
    {tenant, email, keys, slug}
  end

  # Runs fun and returns {result, [telemetry meta of each query issued by this process]}.
  defp capture_queries(fun) do
    ref = make_ref()
    me = self()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      [:letflow, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if self() == me, do: send(me, {:query, ref, meta})
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain(ref, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain(ref, acc) do
    receive do
      {:query, ^ref, meta} -> drain(ref, [meta | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp assert_cell(deployment_mode, stored_mode, expected_disclose) do
    {_tenant, _email, keys, slug} = tenant_with_entry!(stored_mode)

    {result, metas} =
      capture_queries(fn -> LoginDirectory.lookup_by_keys(keys, deployment_mode) end)

    assert {:ok, [%{slug: ^slug, disclose: disclose}]} = result
    assert disclose === expected_disclose
    assert length(metas) == 1
  end

  describe "AC4: deployment :redirect_single (the deployment value is the fallback)" do
    test "tenant NULL -> disclose true (falls back to the deployment mode)" do
      assert_cell(:redirect_single, nil, true)
    end

    test "tenant redirect_single -> disclose true" do
      assert_cell(:redirect_single, "redirect_single", true)
    end

    test "tenant uniform_plus_email -> disclose false (a tenant may opt into uniform)" do
      assert_cell(:redirect_single, "uniform_plus_email", false)
    end
  end

  describe "AC4: deployment :uniform_plus_email (the deployment value is a CEILING / kill switch)" do
    test "tenant NULL -> disclose false" do
      assert_cell(:uniform_plus_email, nil, false)
    end

    test "tenant redirect_single -> disclose false (a tenant cannot opt into disclosure the deployment switched off)" do
      assert_cell(:uniform_plus_email, "redirect_single", false)
    end

    test "tenant uniform_plus_email -> disclose false" do
      assert_cell(:uniform_plus_email, "uniform_plus_email", false)
    end
  end

  describe "AC4: unrecognised deployment terms collapse to uniform (item 4)" do
    test "nil, a junk atom, a string and an integer as the deployment value all give disclose false, even for a redirect_single tenant" do
      {_tenant, _email, keys, slug} = tenant_with_entry!("redirect_single")

      for junk <- [nil, :nonsense, "redirect_single", 1] do
        assert {:ok, [%{slug: ^slug, disclose: false}]} =
                 LoginDirectory.lookup_by_keys(keys, junk)
      end
    end

    test "lookup_by_keys/1 and lookup_by_email/1 read the deployment mode from config: unset -> true, :uniform_plus_email -> false, junk -> false" do
      {_tenant, email, keys, slug} = tenant_with_entry!(nil)
      original = Application.fetch_env(:letflow, Letflow.LoginDiscovery)

      on_exit(fn ->
        case original do
          {:ok, value} -> Application.put_env(:letflow, Letflow.LoginDiscovery, value)
          :error -> Application.delete_env(:letflow, Letflow.LoginDiscovery)
        end
      end)

      Application.delete_env(:letflow, Letflow.LoginDiscovery)
      assert {:ok, [%{slug: ^slug, disclose: true}]} = LoginDirectory.lookup_by_keys(keys)
      assert {:ok, [%{slug: ^slug, disclose: true}]} = LoginDirectory.lookup_by_email(email)

      Application.put_env(:letflow, Letflow.LoginDiscovery, mode: :redirect_single)
      assert {:ok, [%{disclose: true}]} = LoginDirectory.lookup_by_email(email)

      Application.put_env(:letflow, Letflow.LoginDiscovery, mode: :uniform_plus_email)
      assert {:ok, [%{slug: ^slug, disclose: false}]} = LoginDirectory.lookup_by_keys(keys)
      assert {:ok, [%{slug: ^slug, disclose: false}]} = LoginDirectory.lookup_by_email(email)

      Application.put_env(:letflow, Letflow.LoginDiscovery, mode: :bogus)
      assert {:ok, [%{disclose: false}]} = LoginDirectory.lookup_by_email(email)
    end
  end

  describe "AC4: an inactive or unbound-realm tenant yields no row whatever its mode" do
    test "inactive, :migrating and nil-realm tenants, each with each stored mode, under both deployment modes" do
      combos =
        for mode <- [nil, "redirect_single", "uniform_plus_email"],
            kind <- [:inactive, :migrating, :unbound],
            do: {kind, mode}

      email = Fx.unique_email("excl442")

      tenants =
        for {kind, _mode} = combo <- combos do
          tenant =
            case kind do
              :unbound -> Fx.tenant!(idp_realm_id: :none)
              _other -> Fx.tenant!()
            end

          {combo, tenant}
        end

      # Writes only after every provisioning call (see fixture note).
      for {{kind, mode}, tenant} <- tenants do
        set_mode!(tenant, mode)

        case kind do
          :inactive ->
            Fx.set_status!(tenant, :inactive)

          :migrating ->
            Fx.set_status!(tenant, :migrating)

          :unbound ->
            :ok
        end
      end

      in_tx(fn ->
        for {_combo, tenant} <- tenants, do: LoginDirectory.upsert_entry(tenant.tenant_id, email)
      end)

      {:ok, keys} = LoginDirectory.email_keys(email)

      for deployment <- [:redirect_single, :uniform_plus_email] do
        assert LoginDirectory.lookup_by_keys(keys, deployment) == {:ok, []}
      end
    end

    for mode <- [nil, "redirect_single", "uniform_plus_email"] do
      test "an empty-string realm tenant with stored mode #{inspect(mode)} yields no row under both deployment modes" do
        tenant = Fx.tenant!()
        email = Fx.unique_email("empty442")
        set_mode!(tenant, unquote(mode))

        Repo.update_all(from(t in Tenant, where: t.id == ^tenant.tenant_id),
          set: [idp_realm_id: ""]
        )

        in_tx(fn -> LoginDirectory.upsert_entry(tenant.tenant_id, email) end)
        {:ok, keys} = LoginDirectory.email_keys(email)

        for deployment <- [:redirect_single, :uniform_plus_email] do
          assert LoginDirectory.lookup_by_keys(keys, deployment) == {:ok, []}
        end
      end
    end

    test "an active bound tenant next to an inactive one: only the active one is returned, with its own flag" do
      active = Fx.tenant!()
      inactive = Fx.tenant!()
      email = Fx.unique_email("mix442")
      set_mode!(active, "uniform_plus_email")
      set_mode!(inactive, "redirect_single")
      Fx.set_status!(inactive, :inactive)

      in_tx(fn ->
        LoginDirectory.upsert_entry(active.tenant_id, email)
        LoginDirectory.upsert_entry(inactive.tenant_id, email)
      end)

      {:ok, keys} = LoginDirectory.email_keys(email)
      active_slug = Repo.get!(Tenant, active.tenant_id).slug

      assert {:ok, [%{slug: ^active_slug, disclose: false}]} =
               LoginDirectory.lookup_by_keys(keys, :redirect_single)
    end

    test "two matching tenants carry INDEPENDENT flags (per-row, not per-query)" do
      a = Fx.tenant!(display_name: "Aaa 442")
      b = Fx.tenant!(display_name: "Bbb 442")
      email = Fx.unique_email("pair442")
      set_mode!(a, "redirect_single")
      set_mode!(b, "uniform_plus_email")

      in_tx(fn ->
        LoginDirectory.upsert_entry(a.tenant_id, email)
        LoginDirectory.upsert_entry(b.tenant_id, email)
      end)

      {:ok, keys} = LoginDirectory.email_keys(email)

      assert {:ok,
              [
                %{display_name: "Aaa 442", disclose: true},
                %{display_name: "Bbb 442", disclose: false}
              ]} = LoginDirectory.lookup_by_keys(keys, :redirect_single)
    end
  end

  describe "AC5: the internal match type" do
    test "rows carry only slug, display_name, hostname and disclose" do
      {_tenant, email, keys, _slug} = tenant_with_entry!("uniform_plus_email")

      for result <- [
            LoginDirectory.lookup_by_keys(keys, :redirect_single),
            LoginDirectory.lookup_by_email(email)
          ] do
        assert {:ok, [row]} = result
        refute is_struct(row)
        assert row |> Map.keys() |> Enum.sort() == [:disclose, :display_name, :hostname, :slug]
        assert is_boolean(row.disclose)
        refute inspect(row) =~ "login_disclosure_mode"
        refute inspect(row) =~ "idp_realm_id"
      end
    end

    test "lookup_by_keys/2 degrades to {:error, :lookup_failed} for bad key arguments without querying, whatever the mode" do
      key = Fx.key!("a@x.com")

      {results, metas} =
        capture_queries(fn ->
          [
            LoginDirectory.lookup_by_keys("short", :redirect_single),
            LoginDirectory.lookup_by_keys([], :redirect_single),
            LoginDirectory.lookup_by_keys([key, key, key], :uniform_plus_email),
            LoginDirectory.lookup_by_keys([key, "short"], nil)
          ]
        end)

      assert Enum.all?(results, &(&1 == {:error, :lookup_failed}))
      assert metas == []
    end

    test "login_disclosure_mode appears in lib/ only in the four sanctioned files (grep gate)" do
      hits =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.reject(&String.starts_with?(&1, "lib/letflow/design/"))
        |> Enum.filter(&(File.read!(&1) =~ "login_disclosure_mode"))
        |> Enum.sort()

      assert hits == [
               "lib/letflow/identity.ex",
               "lib/letflow/identity/tenant.ex",
               "lib/letflow/login_directory.ex",
               "lib/letflow/routers/tenants.ex"
             ]
    end

    test "the lookup's select never carries the Tenant struct, id, realm or stored mode into the result (source grep)" do
      region = lookup_region()
      [_, select] = String.split(region, "select: %{", parts: 2)
      select_body = select |> String.split("\n        )", parts: 2) |> hd()

      assert select_body =~ "slug: t.slug"
      assert select_body =~ "display_name: t.display_name"
      assert select_body =~ "hostname: onboarding.hostname"
      assert select_body =~ "disclose:"
      refute select_body =~ "t.id"
      refute select_body =~ "idp_realm_id"
      refute select_body =~ "settings"
      # the stored mode appears only INSIDE the disclose fragment, never as its own key
      refute select_body =~ ~r/login_disclosure_mode:/
    end
  end

  describe "AC6: no tenant prefix, log: false, no leak into logs" do
    test "the single lookup query is issued against public tables with no :prefix option, and the mode travels as a bound boolean" do
      {_tenant, _email, keys, _slug} = tenant_with_entry!("redirect_single")

      {_result, [meta]} =
        capture_queries(fn -> LoginDirectory.lookup_by_keys(keys, :redirect_single) end)

      assert meta.source == "tenants"
      assert Keyword.get(meta.options, :prefix) == nil
      refute meta.query =~ "tenant_schemas"
      refute meta.query =~ ~r/"tenant_[0-9a-f]/
      assert meta.query =~ "login_disclosure_mode"
      assert true in meta.params
      refute "redirect_single" in meta.params

      {_result, [meta_off]} =
        capture_queries(fn -> LoginDirectory.lookup_by_keys(keys, :uniform_plus_email) end)

      assert false in meta_off.params
    end

    test "no log output at debug level is produced by the lookup (log: false), for matching and non-matching input" do
      {_tenant, email, keys, _slug} = tenant_with_entry!("uniform_plus_email")
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)

      log =
        capture_log([level: :debug], fn ->
          LoginDirectory.lookup_by_keys(keys, :redirect_single)
          LoginDirectory.lookup_by_email(email)
          LoginDirectory.lookup_by_email("nobody-442@example.test")
        end)

      refute log =~ "login_disclosure_mode"
      refute log =~ email
    end

    test "source gate: the lookup function body holds exactly one Repo call, it is Repo.all(query, log: false), and mentions no prefix" do
      region = lookup_region()

      assert length(Regex.scan(~r/Repo\./, region)) == 1
      assert region =~ "Repo.all(query, log: false)"
      refute region =~ "prefix"
    end
  end

  defp lookup_region do
    source = File.read!(@login_directory_source)

    [_, after_head] =
      String.split(source, "def lookup_by_keys([_ | _] = keys, deployment_mode)", parts: 2)

    [region, _] =
      String.split(after_head, "def lookup_by_keys(_other, _deployment_mode)", parts: 2)

    region
  end
end
