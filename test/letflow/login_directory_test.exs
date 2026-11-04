defmodule Letflow.LoginDirectoryTest do
  @moduledoc """
  REQ-435 -- the `Letflow.LoginDirectory` data layer: table placement, key form,
  the single-query lookup, cross-tenant isolation, FK cascade and the writers'
  own contracts. See `test/specs/REQ-435.md` for the criterion -> test mapping.

  `async: false`: tests swap the global `:login_directory_keys` application
  env (restored in `on_exit/1`, 0043 D-C) and provision real tenant schemas.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Letflow.Identity.Tenant
  alias Letflow.Identity.TenantLoginDirectoryEntry
  alias Letflow.Identity.User
  alias Letflow.LoginDirectory
  alias Letflow.TenantProvisioning.Registration
  alias Letflow.Test.LoginDirectoryFixture, as: Fx

  defp in_tx(fun) do
    {:ok, result} = Repo.transaction(fn -> fun.() end)
    result
  end

  defp insert_user!(schema_name, email) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "u-#{System.unique_integer([:positive])}",
      display_name: "Some Person",
      email: email,
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema_name)
  end

  # Counts queries issued by the calling process via the Repo telemetry event.
  defp count_queries(fun) do
    ref = make_ref()
    me = self()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      [:letflow, :repo, :query],
      fn _event, _measurements, _meta, _config ->
        if self() == me, do: send(me, {:query, ref})
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain(ref, 0)}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain(ref, n) do
    receive do
      {:query, ^ref} -> drain(ref, n + 1)
    after
      0 -> n
    end
  end

  describe "AC1: table lives in the public schema only" do
    test "information_schema shows exactly one schema holding the table: public" do
      %{rows: rows} =
        Repo.query!(
          "SELECT table_schema FROM information_schema.tables WHERE table_name = 'tenant_login_directory'"
        )

      assert rows == [["public"]]
    end

    test "a freshly provisioned tenant schema does not contain the table" do
      %{schema_name: schema_name} = Fx.tenant!()

      %{rows: rows} =
        Repo.query!(
          "SELECT 1 FROM information_schema.tables WHERE table_schema = $1 AND table_name = 'tenant_login_directory'",
          [schema_name]
        )

      assert rows == []
    end

    test "the table holds only (email_key, key_id, tenant_id, inserted_at): no credential, role, user or profile column" do
      %{rows: rows} =
        Repo.query!(
          "SELECT column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'tenant_login_directory'"
        )

      assert rows |> List.flatten() |> Enum.sort() ==
               ["email_key", "inserted_at", "key_id", "tenant_id"]
    end

    test "the Ecto schema exposes exactly the same fields (no password/role/user_id/external_id/display_name)" do
      assert Enum.sort(TenantLoginDirectoryEntry.__schema__(:fields)) ==
               [:email_key, :inserted_at, :key_id, :tenant_id]
    end

    test "the DB rejects a key that is not 32 bytes (CHECK octet_length = 32)" do
      %{tenant_id: tenant_id} = Fx.tenant!()

      assert_raise Postgrex.Error, fn ->
        Repo.insert_all(TenantLoginDirectoryEntry, [
          %{
            email_key: :crypto.strong_rand_bytes(31),
            key_id: "test-a",
            tenant_id: tenant_id,
            inserted_at: ~N[2026-01-01 00:00:00]
          }
        ])
      end
    end
  end

  describe "AC8: key form" do
    test "key is the 32-byte domain-separated HMAC-SHA256 of the normalised email (independent oracle)" do
      %{pepper: pepper} = Application.fetch_env!(:letflow, :login_directory_keys)[:current]
      expected = :crypto.mac(:hmac, :sha256, pepper, "letflow:login-directory:v1:" <> "a@x.com")

      assert {:ok, key} = LoginDirectory.email_key("A@X.com ")
      assert byte_size(key) == 32
      assert key == expected
    end

    test "key is never the plaintext (or lowercased) email and does not contain it" do
      assert {:ok, key} = LoginDirectory.email_key("alice@example.test")
      refute key == "alice@example.test"
      refute String.contains?(key, "alice")
    end

    test "the stored directory row carries the key, never the plaintext" do
      %{tenant_id: tenant_id} = Fx.tenant!()
      email = "stored-plain@example.test"

      assert {:ok, :inserted} = in_tx(fn -> LoginDirectory.upsert_entry(tenant_id, email) end)

      assert [%{email_key: stored, key_id: stored_id}] = Fx.entries(tenant_id)
      assert stored == Fx.key!(email)
      assert byte_size(stored) == 32
      assert {:ok, ^stored_id} = LoginDirectory.current_key_id()
      refute String.contains?(stored, "stored-plain")
    end

    test "a different pepper yields a different key" do
      {:ok, key_a} = LoginDirectory.email_key("alice@example.test")
      Fx.swap_keys!({"test-b", Fx.pepper(2)}, nil)
      {:ok, key_b} = LoginDirectory.email_key("alice@example.test")

      assert key_a != key_b
    end

    test "normalisation equivalence: 'A@X.com ' and 'a@x.com' collide to one key" do
      assert LoginDirectory.email_key("A@X.com ") == LoginDirectory.email_key("a@x.com")

      assert LoginDirectory.email_key("  MiXeD@Example.TEST") ==
               LoginDirectory.email_key("mixed@example.test")

      refute LoginDirectory.email_key("a@x.com") == LoginDirectory.email_key("b@x.com")
    end

    test "invalid input is :invalid, not a key" do
      assert LoginDirectory.email_key("not-an-email") == :invalid
      assert LoginDirectory.email_key("") == :invalid
      assert LoginDirectory.email_key(nil) == :invalid
      assert LoginDirectory.email_key(123) == :invalid
      assert LoginDirectory.email_key("a@" <> String.duplicate("x", 260) <> ".com") == :invalid
    end

    test "an absent pepper is {:error, :pepper_unavailable}; a wrong-size pepper too" do
      Fx.swap_keys!(:unset, nil)
      assert LoginDirectory.email_key("a@x.com") == {:error, :pepper_unavailable}
      assert LoginDirectory.email_keys("a@x.com") == {:error, :pepper_unavailable}
      assert LoginDirectory.sentinel_key() == {:error, :pepper_unavailable}
      assert LoginDirectory.sentinel_keys() == {:error, :pepper_unavailable}
      assert LoginDirectory.current_key_id() == {:error, :pepper_unavailable}

      Fx.swap_keys!({"test-s", "short"}, nil)
      assert LoginDirectory.email_key("a@x.com") == {:error, :pepper_unavailable}
    end

    test "the sentinel key is a 32-byte key distinct from any real address's key" do
      sentinel = LoginDirectory.sentinel_key()
      assert byte_size(sentinel) == 32
      refute sentinel == Fx.key!("sentinel-no-at-sign@example.test")
    end
  end

  describe "AC6: lookup" do
    test "same email in tenants A and B yields two entries and lookup returns both in deterministic order" do
      a = Fx.tenant!(display_name: "Zzz Tenant")
      b = Fx.tenant!(display_name: "Aaa Tenant")
      email = Fx.unique_email("dual")

      in_tx(fn ->
        assert {:ok, :inserted} = LoginDirectory.upsert_entry(a.tenant_id, email)
        assert {:ok, :inserted} = LoginDirectory.upsert_entry(b.tenant_id, email)
      end)

      key = Fx.key!(email)

      assert Repo.aggregate(
               from(d in TenantLoginDirectoryEntry, where: d.email_key == ^key),
               :count
             ) ==
               2

      assert {:ok, result} = LoginDirectory.lookup_by_email(email)
      assert Enum.map(result, & &1.display_name) == ["Aaa Tenant", "Zzz Tenant"]
      assert LoginDirectory.lookup_by_email(email) == {:ok, result}
      assert LoginDirectory.lookup_by_email(" " <> String.upcase(email)) == {:ok, result}
    end

    test "equal display names are tie-broken by slug" do
      a = Fx.tenant!(display_name: "Same Name")
      b = Fx.tenant!(display_name: "Same Name")
      email = Fx.unique_email("tie")

      in_tx(fn ->
        LoginDirectory.upsert_entry(a.tenant_id, email)
        LoginDirectory.upsert_entry(b.tenant_id, email)
      end)

      %{rows: rows} =
        Repo.query!(
          "SELECT slug FROM tenants WHERE id = ANY($1) ORDER BY display_name, slug",
          [[Ecto.UUID.dump!(a.tenant_id), Ecto.UUID.dump!(b.tenant_id)]]
        )

      assert {:ok, result} = LoginDirectory.lookup_by_email(email)
      assert Enum.map(result, & &1.slug) == List.flatten(rows)
    end

    test "returns only slug and display_name per row (closed projection)" do
      a = Fx.tenant!()
      email = Fx.unique_email("proj")
      in_tx(fn -> LoginDirectory.upsert_entry(a.tenant_id, email) end)

      assert {:ok, [row]} = LoginDirectory.lookup_by_email(email)
      assert Map.keys(row) |> Enum.sort() == [:disclose, :display_name, :slug]
      refute is_struct(row)
    end

    test "excludes :inactive and :migrating tenants and tenants without a bound realm" do
      active = Fx.tenant!()
      inactive = Fx.tenant!()
      migrating = Fx.tenant!()
      unbound = Fx.tenant!(idp_realm_id: :none)
      empty_realm = Fx.tenant!()
      email = Fx.unique_email("excl")

      Fx.set_status!(inactive, :inactive)
      Fx.set_status!(migrating, :migrating)

      {1, _} =
        Repo.update_all(from(t in Tenant, where: t.id == ^empty_realm.tenant_id),
          set: [idp_realm_id: ""]
        )

      in_tx(fn ->
        for t <- [active, inactive, migrating, unbound, empty_realm] do
          assert {:ok, :inserted} = LoginDirectory.upsert_entry(t.tenant_id, email)
        end
      end)

      active_slug = Repo.get!(Tenant, active.tenant_id).slug
      assert {:ok, [%{slug: ^active_slug}]} = LoginDirectory.lookup_by_email(email)
    end

    test "the lookup is exactly ONE query, and telemetry still fires with log: false" do
      a = Fx.tenant!()
      b = Fx.tenant!()
      email = Fx.unique_email("one")

      in_tx(fn ->
        LoginDirectory.upsert_entry(a.tenant_id, email)
        LoginDirectory.upsert_entry(b.tenant_id, email)
      end)

      {result, count} = count_queries(fn -> LoginDirectory.lookup_by_email(email) end)

      assert {:ok, [_, _]} = result
      assert count == 1
    end

    test "invalid and unknown inputs return {:ok, []} (sentinel key, never matches)" do
      assert LoginDirectory.lookup_by_email("not-an-email") == {:ok, []}
      assert LoginDirectory.lookup_by_email(nil) == {:ok, []}
      assert LoginDirectory.lookup_by_email(Fx.unique_email("nobody")) == {:ok, []}
    end

    test "the sentinel is never written, so it matches no row even after a write attempt" do
      %{tenant_id: tenant_id} = Fx.tenant!()

      assert {:error, :invalid_email} =
               in_tx(fn -> LoginDirectory.upsert_entry(tenant_id, "sentinel-no-at-sign") end)

      assert Fx.entries(tenant_id) == []
      assert LoginDirectory.lookup_by_keys(LoginDirectory.sentinel_keys()) == {:ok, []}
    end

    test "a missing pepper degrades to {:error, :lookup_failed}, never a raise" do
      Fx.swap_keys!(:unset, nil)
      assert LoginDirectory.lookup_by_email("a@x.com") == {:error, :lookup_failed}
      assert LoginDirectory.lookup_by_email("not-an-email") == {:error, :lookup_failed}
    end

    test "lookup_by_keys/1 rejects a non-list, an empty list, 3 keys and a non-32-byte key without querying" do
      key = Fx.key!("a@x.com")

      {result, count} =
        count_queries(fn ->
          [
            LoginDirectory.lookup_by_keys("short"),
            LoginDirectory.lookup_by_keys(["short"]),
            LoginDirectory.lookup_by_keys([]),
            LoginDirectory.lookup_by_keys([key, key, key]),
            LoginDirectory.lookup_by_keys([key, "short"])
          ]
        end)

      assert Enum.all?(result, &(&1 == {:error, :lookup_failed}))
      assert count == 0
    end
  end

  describe "AC7: cross-tenant isolation" do
    test "an address that exists only in tenant A never returns anything tied to tenant B" do
      a = Fx.tenant!(display_name: "Tenant Alpha")
      b = Fx.tenant!(display_name: "Tenant Beta")
      only_a = Fx.unique_email("only-a")
      only_b = Fx.unique_email("only-b")

      in_tx(fn ->
        LoginDirectory.upsert_entry(a.tenant_id, only_a)
        LoginDirectory.upsert_entry(b.tenant_id, only_b)
      end)

      assert {:ok, [%{display_name: "Tenant Alpha"}]} = LoginDirectory.lookup_by_email(only_a)
      assert {:ok, [%{display_name: "Tenant Beta"}]} = LoginDirectory.lookup_by_email(only_b)

      # The directory holds only (key, tenant_id) pairs for each tenant.
      assert [%{email_key: ka, tenant_id: ta}] = Fx.entries(a.tenant_id)
      assert {ka, ta} == {Fx.key!(only_a), a.tenant_id}
      assert [%{tenant_id: tb}] = Fx.entries(b.tenant_id)
      assert tb == b.tenant_id
    end
  end

  describe "AC11: FK cascade" do
    test "deleting a tenant row cascades its directory entries" do
      a = Fx.tenant!()
      b = Fx.tenant!()
      email = Fx.unique_email("cascade")

      in_tx(fn ->
        LoginDirectory.upsert_entry(a.tenant_id, email)
        LoginDirectory.upsert_entry(b.tenant_id, email)
      end)

      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^a.tenant_id))
      assert {1, _} = Repo.delete_all(from(t in Tenant, where: t.id == ^a.tenant_id))

      assert Fx.entries(a.tenant_id) == []
      assert [_] = Fx.entries(b.tenant_id)
    end
  end

  describe "writers" do
    test "upsert_entry/2 is idempotent: :inserted then :exists, one row" do
      %{tenant_id: tenant_id} = Fx.tenant!()
      email = Fx.unique_email("idem")

      assert {:ok, :inserted} = in_tx(fn -> LoginDirectory.upsert_entry(tenant_id, email) end)

      assert {:ok, :exists} =
               in_tx(fn ->
                 LoginDirectory.upsert_entry(tenant_id, " " <> String.upcase(email))
               end)

      assert [_] = Fx.entries(tenant_id)
    end

    test "writers refuse to run outside a transaction" do
      %{tenant_id: tenant_id, schema_name: schema_name} = Fx.tenant!()

      # The sandbox checkout wraps the test in a transaction; leave it by using a
      # pooled :auto connection for just these two calls.
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual) end)

      task =
        Task.async(fn ->
          {LoginDirectory.upsert_entry(tenant_id, "a@x.com"),
           LoginDirectory.remove_entry_if_unreferenced(tenant_id, "a@x.com", schema_name)}
        end)

      assert Task.await(task) == {{:error, :not_in_transaction}, {:error, :not_in_transaction}}
      assert Fx.entries(tenant_id) == []
    end

    test "upsert_entry/2 with a missing pepper returns :pepper_unavailable and writes nothing" do
      %{tenant_id: tenant_id} = Fx.tenant!()
      Fx.swap_keys!(:unset, nil)

      assert {:error, :pepper_unavailable} =
               in_tx(fn -> LoginDirectory.upsert_entry(tenant_id, "a@x.com") end)

      assert Fx.entries(tenant_id) == []
    end

    test "upsert_entry/2 never leaks exception text: a bad tenant_id is the fixed :write_failed" do
      # FK violation (no such tenant) raises inside insert_all; reason must be fixed.
      assert {:error, :write_failed} =
               in_tx(fn ->
                 Repo.query!("SAVEPOINT s")
                 result = LoginDirectory.upsert_entry(Ecto.UUID.generate(), "a@x.com")
                 Repo.query!("ROLLBACK TO SAVEPOINT s")
                 result
               end)
    end

    test "GH #2498: an undefined column is the fixed :directory_unavailable, no exception text" do
      %{tenant_id: tenant_id} = Fx.tenant!()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          result =
            in_tx(fn ->
              Repo.query!("SAVEPOINT s")

              Repo.query!(
                "ALTER TABLE tenant_login_directory RENAME COLUMN key_id TO key_id_drift"
              )

              r = LoginDirectory.upsert_entry(tenant_id, "drift@x.com")
              Repo.query!("ROLLBACK TO SAVEPOINT s")
              r
            end)

          send(self(), {:result, result})
        end)

      assert_received {:result, {:error, :directory_unavailable}}
      refute log =~ "does not exist"
      refute log =~ "undefined_column"
      refute log =~ "Postgrex.Error"
    end

    test "remove_entry_if_unreferenced/3: :absent, :kept while another active user holds the email, then :removed" do
      %{tenant_id: tenant_id, schema_name: schema_name} = Fx.tenant!()
      email = Fx.unique_email("rm")

      assert {:ok, :absent} =
               in_tx(fn ->
                 LoginDirectory.remove_entry_if_unreferenced(tenant_id, email, schema_name)
               end)

      in_tx(fn -> LoginDirectory.upsert_entry(tenant_id, email) end)
      other = insert_user!(schema_name, String.upcase(email))

      assert {:ok, :kept} =
               in_tx(fn ->
                 LoginDirectory.remove_entry_if_unreferenced(tenant_id, email, schema_name)
               end)

      assert [_] = Fx.entries(tenant_id)

      Repo.update!(Ecto.Changeset.change(other, status: :inactive), prefix: schema_name)

      assert {:ok, :removed} =
               in_tx(fn ->
                 LoginDirectory.remove_entry_if_unreferenced(tenant_id, email, schema_name)
               end)

      assert Fx.entries(tenant_id) == []
    end

    test "remove_entry_if_unreferenced/3 only deletes the entry of the named tenant" do
      a = Fx.tenant!()
      b = Fx.tenant!()
      email = Fx.unique_email("rm-scope")

      in_tx(fn ->
        LoginDirectory.upsert_entry(a.tenant_id, email)
        LoginDirectory.upsert_entry(b.tenant_id, email)
      end)

      assert {:ok, :removed} =
               in_tx(fn ->
                 LoginDirectory.remove_entry_if_unreferenced(a.tenant_id, email, a.schema_name)
               end)

      assert Fx.entries(a.tenant_id) == []
      assert [_] = Fx.entries(b.tenant_id)
    end
  end

  # ── 0043 D-C additions (design §15.1 "Additional tests", items 1-4) ────────

  # Reports whether Postgres rejected `fun`. The SQL sandbox already confines a
  # failed statement to its own savepoint, so the transaction stays usable.
  defp rejected?(fun) do
    fun.()
    false
  rescue
    Postgrex.Error -> true
  end

  defp raw_row(tenant_id, key, key_id) do
    %{email_key: key, key_id: key_id, tenant_id: tenant_id, inserted_at: ~N[2026-01-01 00:00:00]}
  end

  # Mirrors the private hash in LoginDirectory.acquire_key_lock/2 (namespace 435_001).
  defp advisory_lock_held?(tenant_id, key) do
    hash = :erlang.phash2({tenant_id, key}, 2_147_483_647)

    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND classid = 435001 AND objid = $1 AND pid = pg_backend_pid()",
        [hash]
      )

    n > 0
  end

  # Counts the :crypto.mac/4 calls the calling process makes while `fun` runs.
  # A separate tracer process is required: a process does not receive its own
  # call-trace messages.
  defp count_hmac_calls(fun) do
    me = self()
    tracer = spawn(fn -> collect_mac(0) end)
    :erlang.trace_pattern({:crypto, :mac, 4}, true, [:global])
    :erlang.trace(me, true, [:call, {:tracer, tracer}])

    try do
      result = fun.()
      ref = :erlang.trace_delivered(me)

      receive do
        {:trace_delivered, ^me, ^ref} -> :ok
      end

      send(tracer, {:count, me})

      receive do
        {:mac_count, n} -> {result, n}
      end
    after
      :erlang.trace(me, false, [:call])
      :erlang.trace_pattern({:crypto, :mac, 4}, false, [:global])
      Process.exit(tracer, :kill)
    end
  end

  defp collect_mac(n) do
    receive do
      {:trace, _pid, :call, {:crypto, :mac, [:hmac, :sha256, _, _]}} -> collect_mac(n + 1)
      {:count, from} -> send(from, {:mac_count, n})
    end
  end

  # Returns the bound parameter list of each Repo query the calling process issues.
  defp query_params(fun) do
    ref = make_ref()
    me = self()
    handler_id = {__MODULE__, :params, ref}

    :telemetry.attach(
      handler_id,
      [:letflow, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if self() == me, do: send(me, {:params, ref, meta.params})
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain_params(ref, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_params(ref, acc) do
    receive do
      {:params, ^ref, params} -> drain_params(ref, [params | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "D-C catalog: key_id column and primary key" do
    test "key_id is NOT NULL varchar(32); the primary key is exactly (email_key, tenant_id)" do
      %{rows: [[nullable, type, length]]} =
        Repo.query!(
          "SELECT is_nullable, data_type, character_maximum_length FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'tenant_login_directory' AND column_name = 'key_id'"
        )

      assert {nullable, type, length} == {"NO", "character varying", 32}

      %{rows: pk} =
        Repo.query!("""
        SELECT a.attname FROM pg_index i
        JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
        WHERE i.indrelid = 'public.tenant_login_directory'::regclass AND i.indisprimary
        """)

      assert pk |> List.flatten() |> Enum.sort() == ["email_key", "tenant_id"]
    end

    test "the key_id_format CHECK exists and rejects uppercase, empty and 33-character ids" do
      %{rows: [[1]]} =
        Repo.query!(
          "SELECT 1 FROM pg_constraint WHERE conname = 'key_id_format' AND conrelid = 'public.tenant_login_directory'::regclass AND contype = 'c'"
        )

      %{tenant_id: tenant_id} = Fx.tenant!()

      for bad <- ["UPPER", "", String.duplicate("a", 33), "has space", "new\nline"] do
        assert rejected?(fn ->
                 Repo.insert_all(TenantLoginDirectoryEntry, [
                   raw_row(tenant_id, :crypto.strong_rand_bytes(32), bad)
                 ])
               end),
               "expected key_id #{inspect(bad)} to be rejected"
      end

      assert :ok = Fx.insert_row!(tenant_id, :crypto.strong_rand_bytes(32), "ok_id-1")

      assert :ok =
               Fx.insert_row!(tenant_id, :crypto.strong_rand_bytes(32), String.duplicate("a", 32))
    end

    test "NULL key_id is rejected (NOT NULL)" do
      %{tenant_id: tenant_id} = Fx.tenant!()

      assert rejected?(fn ->
               Repo.query!(
                 "INSERT INTO tenant_login_directory (email_key, key_id, tenant_id, inserted_at) VALUES ($1, NULL, $2, now())",
                 [:crypto.strong_rand_bytes(32), Ecto.UUID.dump!(tenant_id)]
               )
             end)
    end

    test "a duplicate (email_key, tenant_id) violates the key, even with a different key_id" do
      %{tenant_id: tenant_id} = Fx.tenant!()
      key = :crypto.strong_rand_bytes(32)
      :ok = Fx.insert_row!(tenant_id, key, "id-a")

      assert rejected?(fn -> Fx.insert_row!(tenant_id, key, "id-a") end)
      assert rejected?(fn -> Fx.insert_row!(tenant_id, key, "id-b") end)
      assert [%{key_id: "id-a"}] = Fx.entries(tenant_id)
    end

    test "the same person under two pepper/key-id pairs is two rows for one tenant" do
      %{tenant_id: tenant_id} = Fx.tenant!()
      key_a = Fx.key_under(Fx.pepper(1), "person@example.test")
      key_b = Fx.key_under(Fx.pepper(2), "person@example.test")
      refute key_a == key_b

      :ok = Fx.insert_row!(tenant_id, key_a, "id-a")
      :ok = Fx.insert_row!(tenant_id, key_b, "id-b")

      assert Fx.entries(tenant_id) |> Enum.map(& &1.key_id) |> Enum.sort() == ["id-a", "id-b"]
    end

    test "the changeset requires key_id and validates its format" do
      attrs = %{email_key: :crypto.strong_rand_bytes(32), tenant_id: Ecto.UUID.generate()}
      blank = %TenantLoginDirectoryEntry{}

      refute TenantLoginDirectoryEntry.create_changeset(blank, attrs).valid?

      refute TenantLoginDirectoryEntry.create_changeset(blank, Map.put(attrs, :key_id, "BAD")).valid?

      assert TenantLoginDirectoryEntry.create_changeset(blank, Map.put(attrs, :key_id, "good-1")).valid?
    end
  end

  describe "D-C dual-read (previous pepper configured)" do
    setup do
      a = Fx.tenant!(display_name: "Aaa Dual")
      b = Fx.tenant!(display_name: "Bbb Dual")
      Fx.swap_keys!({"id-b", Fx.pepper(2)}, {"id-a", Fx.pepper(1)})
      %{a: a, b: b, email: Fx.unique_email("dual-read")}
    end

    test "one row per key id for the SAME (email, tenant) returns that tenant exactly once, in ONE query",
         %{a: a, b: b, email: email} do
      :ok = Fx.insert_row!(a.tenant_id, Fx.key_under(Fx.pepper(1), email), "id-a")
      :ok = Fx.insert_row!(a.tenant_id, Fx.key_under(Fx.pepper(2), email), "id-b")
      # tenant B holds the person under the previous key only (not yet re-keyed)
      :ok = Fx.insert_row!(b.tenant_id, Fx.key_under(Fx.pepper(1), email), "id-a")

      {result, count} = count_queries(fn -> LoginDirectory.lookup_by_email(email) end)

      assert {:ok, [%{display_name: "Aaa Dual"}, %{display_name: "Bbb Dual"}]} = result
      assert count == 1

      assert {:ok, keys} = LoginDirectory.email_keys(email)
      assert length(keys) == 2
      assert LoginDirectory.lookup_by_keys(keys) == result
      assert {:ok, [%{display_name: "Aaa Dual"}]} = LoginDirectory.lookup_by_keys([hd(keys)])
    end

    test "a person with rows under both keys in only one tenant yields length 1", %{
      a: a,
      email: email
    } do
      :ok = Fx.insert_row!(a.tenant_id, Fx.key_under(Fx.pepper(1), email), "id-a")
      :ok = Fx.insert_row!(a.tenant_id, Fx.key_under(Fx.pepper(2), email), "id-b")

      assert {:ok, [%{display_name: "Aaa Dual"}]} = LoginDirectory.lookup_by_email(email)
    end

    test "with only the current pepper configured, a row under the previous key id alone is not found",
         %{a: a, email: email} do
      :ok = Fx.insert_row!(a.tenant_id, Fx.key_under(Fx.pepper(1), email), "id-a")
      assert {:ok, [%{}]} = LoginDirectory.lookup_by_email(email)

      Fx.swap_keys!({"id-b", Fx.pepper(2)}, nil)
      assert LoginDirectory.lookup_by_email(email) == {:ok, []}
      assert {:ok, [_current_only]} = LoginDirectory.email_keys(email)
    end

    test "email_keys/1 is current first, then previous; email_key/1 is the current key", %{
      email: email
    } do
      assert {:ok, [current, previous]} = LoginDirectory.email_keys(email)
      assert current == Fx.key_under(Fx.pepper(2), email)
      assert previous == Fx.key_under(Fx.pepper(1), email)
      assert LoginDirectory.email_key(email) == {:ok, current}
      assert LoginDirectory.current_key_id() == {:ok, "id-b"}
      assert [sentinel_current, _sentinel_previous] = LoginDirectory.sentinel_keys()
      assert sentinel_current == LoginDirectory.sentinel_key()
    end
  end

  describe "D-C sentinel constancy: one query and the same HMAC count for every input" do
    setup do
      a = Fx.tenant!()
      known = Fx.unique_email("known")
      in_tx(fn -> LoginDirectory.upsert_entry(a.tenant_id, known) end)
      %{known: known}
    end

    defp sentinel_inputs(known) do
      [
        known,
        Fx.unique_email("unknown"),
        "not-an-email",
        nil,
        123,
        "a@" <> String.duplicate("x", 260) <> ".com"
      ]
    end

    for {label, rotation?} <- [{"current only", false}, {"current + previous", true}] do
      test "#{label}: each input issues one query with equal parameter shape and the same HMAC count",
           %{known: known} do
        expected =
          if unquote(rotation?) do
            Fx.swap_keys!({"id-b", Fx.pepper(2)}, {"id-a", Fx.pepper(1)})
            2
          else
            1
          end

        observed =
          for input <- sentinel_inputs(known) do
            {{result, params}, hmacs} =
              count_hmac_calls(fn ->
                query_params(fn -> LoginDirectory.lookup_by_email(input) end)
              end)

            assert {:ok, _} = result
            assert [one_query] = params
            {hmacs, Enum.map(one_query, &if(is_list(&1), do: length(&1), else: :scalar))}
          end

        assert observed |> Enum.map(&elem(&1, 0)) |> Enum.uniq() == [expected]
        assert observed |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 1
        assert observed |> hd() |> elem(1) |> Enum.any?(&(&1 == expected))
      end
    end

    test "sentinel keys never equal a real key and the writers refuse to write them", %{
      known: known
    } do
      Fx.swap_keys!({"id-b", Fx.pepper(2)}, {"id-a", Fx.pepper(1)})
      %{tenant_id: tenant_id} = Fx.tenant!()

      assert {:ok, real_keys} = LoginDirectory.email_keys(known)
      assert LoginDirectory.sentinel_keys() |> Enum.all?(&(&1 not in real_keys))

      assert {:error, :invalid_email} =
               in_tx(fn -> LoginDirectory.upsert_entry(tenant_id, "sentinel-no-at-sign") end)

      assert Fx.entries(tenant_id) == []
    end
  end

  describe "D-C removal under every candidate key; lock on the current key" do
    setup do
      %{tenant_id: tenant_id, schema_name: schema_name} = Fx.tenant!()
      other = Fx.tenant!()
      Fx.swap_keys!({"id-b", Fx.pepper(2)}, {"id-a", Fx.pepper(1)})
      email = Fx.unique_email("rm-rot")
      :ok = Fx.insert_row!(tenant_id, Fx.key_under(Fx.pepper(1), email), "id-a")
      :ok = Fx.insert_row!(tenant_id, Fx.key_under(Fx.pepper(2), email), "id-b")
      :ok = Fx.insert_row!(other.tenant_id, Fx.key_under(Fx.pepper(1), email), "id-a")
      %{tenant_id: tenant_id, schema_name: schema_name, other: other, email: email}
    end

    test "with no other active holder, both rows of the tenant are deleted (:removed); other tenants keep theirs",
         %{tenant_id: tenant_id, schema_name: schema_name, other: other, email: email} do
      assert {:ok, :removed} =
               in_tx(fn ->
                 LoginDirectory.remove_entry_if_unreferenced(tenant_id, email, schema_name)
               end)

      assert Fx.entries(tenant_id) == []
      assert [%{key_id: "id-a"}] = Fx.entries(other.tenant_id)
    end

    test "with another active user sharing the email, both rows are kept (:kept)", %{
      tenant_id: tenant_id,
      schema_name: schema_name,
      email: email
    } do
      insert_user!(schema_name, String.upcase(email))

      assert {:ok, :kept} =
               in_tx(fn ->
                 LoginDirectory.remove_entry_if_unreferenced(tenant_id, email, schema_name)
               end)

      assert length(Fx.entries(tenant_id)) == 2
    end

    test "a row under the previous key only is still removed", %{other: other, email: email} do
      assert {:ok, :removed} =
               in_tx(fn ->
                 LoginDirectory.remove_entry_if_unreferenced(
                   other.tenant_id,
                   email,
                   other.schema_name
                 )
               end)

      assert Fx.entries(other.tenant_id) == []
    end

    test "the advisory lock is taken on the CURRENT key only", %{
      tenant_id: tenant_id,
      schema_name: schema_name,
      email: email
    } do
      refute advisory_lock_held?(tenant_id, Fx.key_under(Fx.pepper(2), email))

      in_tx(fn ->
        LoginDirectory.remove_entry_if_unreferenced(tenant_id, email, schema_name)
      end)

      assert advisory_lock_held?(tenant_id, Fx.key_under(Fx.pepper(2), email))
      refute advisory_lock_held?(tenant_id, Fx.key_under(Fx.pepper(1), email))
    end
  end

  describe "D-C writers record the current key id" do
    test "upsert_entry/2 stores key_id of the current pepper, under the current key" do
      %{tenant_id: tenant_id} = Fx.tenant!()
      Fx.swap_keys!({"id-b", Fx.pepper(2)}, {"id-a", Fx.pepper(1)})
      email = Fx.unique_email("write-id")

      assert {:ok, :inserted} = in_tx(fn -> LoginDirectory.upsert_entry(tenant_id, email) end)
      assert [%{key_id: "id-b", email_key: key}] = Fx.entries(tenant_id)
      assert key == Fx.key_under(Fx.pepper(2), email)
    end
  end

  describe "D-C logging: rotation configuration leaks nothing at :debug" do
    test "write, lookup (known, unknown, invalid) and removal log no email, key (hex/base64/inspect) or pepper" do
      %{tenant_id: tenant_id, schema_name: schema_name} = Fx.tenant!()
      Fx.swap_keys!({"id-b", Fx.pepper(2)}, {"id-a", Fx.pepper(1)})
      level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: level) end)

      email = Fx.unique_email("logleak")
      :ok = Fx.insert_row!(tenant_id, Fx.key_under(Fx.pepper(1), email), "id-a")

      log =
        capture_log([level: :debug], fn ->
          in_tx(fn -> LoginDirectory.upsert_entry(tenant_id, email) end)
          LoginDirectory.lookup_by_email(email)
          LoginDirectory.lookup_by_email(Fx.unique_email("nobody"))
          LoginDirectory.lookup_by_email("not-an-email")

          in_tx(fn ->
            LoginDirectory.remove_entry_if_unreferenced(tenant_id, email, schema_name)
          end)
        end)

      secrets =
        for n <- [1, 2], bin <- [Fx.pepper(n), Fx.key_under(Fx.pepper(n), email)], do: bin

      for secret <- secrets do
        refute log =~ Base.encode16(secret, case: :lower)
        refute log =~ Base.encode16(secret, case: :upper)
        refute log =~ Base.encode64(secret)
        refute log =~ inspect(secret, limit: :infinity)
      end

      refute log =~ email
      refute log =~ "tenant_login_directory"
    end
  end
end
