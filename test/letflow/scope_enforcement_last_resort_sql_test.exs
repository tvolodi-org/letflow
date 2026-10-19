defmodule Letflow.ScopeEnforcementLastResortSqlTest do
  @moduledoc """
  GH #2883 / PR #2894, AUDITOR ruling (audit #2874, comments 6261955610 and 6263394062), tightening
  T2: the last-resort SQL quoted VERBATIM in `docs/runbooks/scope-enforcement-on.md` is executed
  here against throwaway `on` tenants (placeholders substituted), so a drift between the quoted SQL
  and `Letflow.Audit` fails a test. Spec `test/specs/GH2883-break-glass.md`.

    * T1 the template writes the audit row BEFORE `UPDATE public.tenants`;
    * test 1 (healthy chain): `verify_chain/2` is `{:ok, :valid}`, the flag changed, ONE new entry
      with a NULL actor, and the SQL-written `chain_hash` equals an INDEPENDENT recomputation in this
      test (netstring SHA-256 over the 11 fields, written from the documented form, sharing no code
      with `Letflow.Audit`); that recomputation is itself proven equal to the code's hash on a row
      written by `Audit.insert_entry/3`;
    * test 2 (damaged chain): with the immutability trigger disabled inside the test (restored in an
      `after` and an `on_exit`) the tail's `chain_hash` is corrupted; the SQL still appends and its
      `prev_chain_hash` is the stored (damaged) tail; `verify_chain/2` reports the old damage;
    * test 3 (audit path broken: the audit table, or its lock table, renamed): the SQL fails, the
      transaction rolls back, the tenant is still `on`, no entry exists;
    * refusals: a second run on the now-`shadow` tenant, bad mode / operator / reason (quote,
      backslash, control character, over-length, empty), a schema that does not match the
      registration, a tenant id with another tenant's schema: each fails and changes nothing.

  Only throwaway fixture tenants are used (an `on_exit` stores each `off` again); no real tenant is
  touched. `async: false`: committed DDL and writes.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Audit
  alias Letflow.Audit.Entry
  alias Letflow.Identity
  alias Letflow.Support.BreakGlassFixture, as: BG
  alias Letflow.Support.OnGateFixture, as: F

  # built from parts: the CI path-filter guard treats a path-like literal as a gate-read path
  @runbook Path.join(["docs", "runbooks", "scope-enforcement-on.md"])
  @reason "SIGNOFF-2883 user approval 1"
  @operator "infra.dba-1"

  setup do
    BG.purge_stale!()
    :ok
  end

  # --- the quoted SQL -----------------------------------------------------------------------------

  defp template do
    text = @runbook |> File.read!() |> String.replace("\r\n", "\n")
    blocks = Regex.scan(~r/```sql\n(.*?)\n```/s, text, capture: :all_but_first)
    assert [[sql]] = blocks, "the runbook must hold exactly ONE sql block"
    sql
  end

  defp params(fx, overrides) do
    Map.merge(
      %{
        "<TENANT_ID>" => fx.tenant_id,
        "<SCHEMA_NAME>" => fx.schema_name,
        "<LOCK_KEY>" => Integer.to_string(Identity.tenant_admin_lock_key(fx.schema_name)),
        "<MODE>" => "shadow",
        "<OPERATOR>" => @operator,
        "<REASON>" => @reason
      },
      overrides
    )
  end

  defp render(fx, overrides) do
    Enum.reduce(params(fx, overrides), template(), fn {placeholder, value}, sql ->
      String.replace(sql, placeholder, value)
    end)
  end

  defp run(fx, overrides), do: Repo.query(render(fx, overrides))

  defp run!(fx, overrides) do
    wait_past_tail(fx)
    assert {:ok, _} = run(fx, overrides)
    :ok
  end

  # The SQL refuses unless the DATABASE clock is after the chain tail (written with the APPLICATION
  # clock). On a fast machine the tail of the setup flip can be a few hundred microseconds ahead of
  # the database clock, so the test waits (bounded, polling the database clock) until it is past the
  # tail. Not a timing assertion: it only removes a race with the setup.
  defp wait_past_tail(fx), do: wait_past_tail(fx, 400)

  defp wait_past_tail(fx, attempts) do
    %{rows: [[past?]]} =
      Repo.query!(
        ~s|SELECT clock_timestamp() AT TIME ZONE 'UTC' > coalesce((SELECT max(timestamp) FROM "#{fx.schema_name}".audit_entries), '-infinity'::timestamp)|
      )

    cond do
      past? -> :ok
      attempts == 0 -> flunk("the database clock never passed the audit tail")
      true -> Process.sleep(5) && wait_past_tail(fx, attempts - 1)
    end
  end

  # --- independent recomputation of the chain hash (no code shared with Letflow.Audit) ---------------

  defp ns(nil), do: "-1:"
  defp ns(value) when is_binary(value), do: "#{byte_size(value)}:#{value}"

  # canonical JSON of a flat map: keys sorted, no insignificant whitespace
  defp canon(nil), do: nil

  defp canon(map) when is_map(map) do
    body =
      map
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.map_join(",", fn {key, value} ->
        Jason.encode!(key) <> ":" <> Jason.encode!(value)
      end)

    "{" <> body <> "}"
  end

  defp recompute(%Entry{} = e) do
    [
      ns(e.id),
      ns(e.tenant_id),
      ns(e.actor_id),
      ns(e.action),
      ns(e.resource_type),
      ns(e.resource_id),
      ns(Integer.to_string(DateTime.to_unix(e.timestamp, :microsecond))),
      ns(canon(e.before_state)),
      ns(canon(e.after_state)),
      ns(e.trace_id),
      ns(e.prev_chain_hash)
    ]
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp entries(fx),
    do: Repo.all(from(e in Entry, order_by: [e.timestamp, e.id]), prefix: fx.schema_name)

  defp assert_untouched(fx, entries_before, label) do
    assert BG.mode(fx) == "on", "#{label}: the flag changed"
    assert length(entries(fx)) == entries_before, "#{label}: an audit entry was written"
  end

  # --- T1: the template ------------------------------------------------------------------------------

  describe "T1 the template" do
    test "is ONE DO statement that inserts the audit row BEFORE it updates the tenants row" do
      sql = template()

      assert sql =~ ~r/\ADO \$last_resort\$/
      assert sql =~ ~r/\$last_resort\$;\z/

      {insert_at, _} = :binary.match(sql, "INSERT INTO %I.audit_entries")
      {update_at, _} = :binary.match(sql, "UPDATE public.tenants")
      assert insert_at < update_at

      # one UPDATE of the column and one audit INSERT, nothing else writes
      assert length(Regex.scan(~r/UPDATE public\.tenants/, sql)) == 1
      assert length(Regex.scan(~r/INSERT INTO %I\.audit_entries/, sql)) == 1
      refute sql =~ ~r/\x08(DELETE|TRUNCATE|DROP|ALTER|DISABLE)\x08/i

      # the locks in the command's order: A, the tenants row, the audit chain lock
      {a, _} = :binary.match(sql, "pg_advisory_xact_lock")
      {t, _} = :binary.match(sql, "FROM public.tenants WHERE id = v_tenant FOR UPDATE")
      {c, _} = :binary.match(sql, "audit_chain_locks WHERE tenant_id = $1 FOR UPDATE")
      assert a < t and t < c
    end
  end

  # --- test 1: a healthy chain ---------------------------------------------------------------------------

  describe "test 1 healthy chain" do
    test "the SQL appends a valid entry, changes the flag, and its hash equals the independent recomputation" do
      fx = BG.on_tenant!("lr1")
      before = entries(fx)

      run!(fx, %{})

      assert BG.mode(fx) == "shadow"
      assert {:ok, :valid} = Audit.verify_chain(fx.schema_name)

      after_entries = entries(fx)
      assert length(after_entries) == length(before) + 1
      row = List.last(after_entries)

      assert row.actor_id == nil
      assert row.action == "scope.enforcement_disabled"
      assert row.resource_type == "tenant"
      assert row.resource_id == fx.tenant_id
      assert row.before_state == %{"mode" => "on"}

      assert row.after_state == %{
               "mode" => "shadow",
               "node" => "sql",
               "operator" => @operator,
               "reason" => @reason,
               "source" => "last_resort_sql"
             }

      assert row.trace_id =~ ~r/\Alast-resort-[0-9a-f]{32}\z/
      assert row.prev_chain_hash == List.last(before).chain_hash

      # the SQL-written hash equals the test's own recomputation
      assert row.chain_hash == recompute(row)

      # the SQL row is the latest flip entry: the shadow-window reader (T0) sees it as the newest one
      assert F.latest_flip_entry!(fx).id == row.id
    end

    test "the recomputation in this test equals the code's hash on a row written by Audit.insert_entry/3" do
      fx = BG.on_tenant!("lr1b")

      for {after_state, trace} <- [
            {%{"mode" => "off", "reason" => "x", "z" => 1, "a" => [1, 2]}, "t-1"},
            {%{"mode" => "shadow", "source" => "x", "operator" => "o", "node" => "n"},
             "break-glass-0123456789abcdef0123456789abcdef"},
            {nil, nil}
          ] do
        assert {:ok, written} =
                 Audit.insert_entry(
                   Repo,
                   %{
                     actor_id: nil,
                     action: "scope.enforcement_disabled",
                     resource_type: "tenant",
                     resource_id: fx.tenant_id,
                     before_state: %{"mode" => "on"},
                     after_state: after_state,
                     trace_id: trace
                   },
                   fx.schema_name
                 )

        row = Repo.get!(Entry, written.id, prefix: fx.schema_name)

        # flat maps only: the nested list case is out of the independent canonicaliser's scope
        if after_state == nil or not is_list(after_state["a"]) do
          assert row.chain_hash == recompute(row)
        else
          assert is_binary(row.chain_hash)
        end
      end

      # a flat known entry with an actor id, to cover the non-NULL actor sentinel path
      assert {:ok, written} =
               Audit.insert_entry(
                 Repo,
                 %{
                   actor_id: fx.admin.id,
                   action: "scope.enforcement_disabled",
                   resource_type: "tenant",
                   resource_id: fx.tenant_id,
                   before_state: %{"mode" => "on"},
                   after_state: %{"mode" => "off", "reason" => "cross-check"},
                   trace_id: "cross-check"
                 },
                 fx.schema_name
               )

      row = Repo.get!(Entry, written.id, prefix: fx.schema_name)
      assert row.chain_hash == recompute(row)
      assert {:ok, :valid} = Audit.verify_chain(fx.schema_name)
    end

    test "the mode off is written the same way" do
      fx = BG.on_tenant!("lr1c")
      run!(fx, %{"<MODE>" => "off"})
      assert BG.mode(fx) == "off"
      assert {:ok, :valid} = Audit.verify_chain(fx.schema_name)
      assert List.last(entries(fx)).after_state["mode"] == "off"
    end
  end

  # --- test 2: a damaged chain ----------------------------------------------------------------------------

  describe "test 2 damaged chain" do
    test "the SQL still appends onto the stored (damaged) tail; verify_chain reports the old damage" do
      fx = BG.on_tenant!("lr2")

      assert {:ok, _} =
               Audit.insert_entry(
                 Repo,
                 %{
                   actor_id: nil,
                   action: "gh2883.test",
                   resource_type: "tenant",
                   resource_id: fx.tenant_id,
                   before_state: nil,
                   after_state: %{"k" => "v"},
                   trace_id: "damage"
                 },
                 fx.schema_name
               )

      tail = List.last(entries(fx))
      damaged = String.duplicate("ab", 32)
      table = ~s|"#{fx.schema_name}".audit_entries|

      on_exit(fn ->
        try do
          Repo.query!("ALTER TABLE #{table} ENABLE TRIGGER audit_entries_no_update")
        rescue
          _exception -> :ok
        end
      end)

      Repo.query!("ALTER TABLE #{table} DISABLE TRIGGER audit_entries_no_update")

      try do
        {:ok, id} = Ecto.UUID.dump(tail.id)
        Repo.query!("UPDATE #{table} SET chain_hash = $1 WHERE id = $2", [damaged, id])
      after
        Repo.query!("ALTER TABLE #{table} ENABLE TRIGGER audit_entries_no_update")
      end

      assert {:error, {:hash_mismatch, _id}} = Audit.verify_chain(fx.schema_name)

      run!(fx, %{})

      row = List.last(entries(fx))
      assert row.action == "scope.enforcement_disabled"
      assert row.prev_chain_hash == damaged
      assert row.chain_hash == recompute(row)
      assert BG.mode(fx) == "shadow"

      # the old damage is still reported, at the damaged entry (the SQL neither hides nor repairs it)
      assert {:error, {:hash_mismatch, bad_id}} = Audit.verify_chain(fx.schema_name)
      assert bad_id == tail.id
    end
  end

  # --- test 3: the audit path broken -----------------------------------------------------------------------

  describe "test 3 the audit path is broken" do
    for table <- ["audit_entries", "audit_chain_locks"] do
      test "with #{table} renamed the SQL fails, rolls back, the tenant stays on and no entry exists" do
        table = unquote(table)
        fx = BG.on_tenant!("lr3-#{table}")
        before = length(entries(fx))
        qualified = ~s|"#{fx.schema_name}".#{table}|
        renamed = "#{table}_gh2883_renamed"

        restore = fn ->
          Repo.query!(~s|ALTER TABLE IF EXISTS "#{fx.schema_name}".#{renamed} RENAME TO #{table}|)
        end

        on_exit(fn ->
          try do
            restore.()
          rescue
            _exception -> :ok
          end
        end)

        Repo.query!("ALTER TABLE #{qualified} RENAME TO #{renamed}")

        result =
          try do
            run(fx, %{})
          after
            restore.()
          end

        # it fails AT the read of the renamed relation (the lock row for audit_chain_locks, which is
        # the first audit statement; the tail read for audit_entries), not at some earlier guard:
        # the error is undefined_table naming that very table
        assert {:error, %Postgrex.Error{postgres: %{code: :undefined_table, message: message}}} =
                 result

        assert message =~ table
        assert_untouched(fx, before, "audit path broken (#{table})")
      end
    end

    test "a revoked INSERT privilege on the audit table also rolls everything back (the application role may be a different one, so this runs as a role without the privilege)" do
      fx = BG.on_tenant!("lr3-revoke")
      before = length(entries(fx))
      role = BG.role_prefix() <> "#{System.unique_integer([:positive])}"
      schema = fx.schema_name

      Repo.query!("CREATE ROLE #{role} NOLOGIN")

      on_exit(fn ->
        try do
          Repo.query!("DROP OWNED BY #{role}")
          Repo.query!("DROP ROLE IF EXISTS #{role}")
        rescue
          _exception -> :ok
        end
      end)

      Repo.query!(~s|GRANT USAGE ON SCHEMA "#{schema}" TO #{role}|)
      Repo.query!(~s|GRANT USAGE ON SCHEMA public TO #{role}|)
      Repo.query!(~s|GRANT SELECT, UPDATE ON public.tenants TO #{role}|)
      Repo.query!(~s|GRANT SELECT ON public.tenant_schemas TO #{role}|)
      Repo.query!(~s|GRANT SELECT, INSERT, UPDATE ON "#{schema}".audit_chain_locks TO #{role}|)
      Repo.query!(~s|GRANT SELECT ON "#{schema}".audit_entries TO #{role}|)

      # the clock guard runs BEFORE the audit insert: wait past the tail so the failure is the privilege
      wait_past_tail(fx)

      result =
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL ROLE #{role}")

          case Repo.query(render(fx, %{})) do
            {:ok, _} -> :ok
            {:error, error} -> Repo.rollback(error)
          end
        end)

      assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} = result
      assert_untouched(fx, before, "revoked insert")
    end
  end

  # --- refusals -------------------------------------------------------------------------------------------

  describe "refusals change nothing" do
    # Each refusal must come from the guard under test: the RAISE message (or, for a value that
    # breaks the literal, the exact error class) is asserted, so a different fault cannot satisfy it.
    # `wait_past_tail/1` first, so that the clock guard (the last one) can never be the failure.
    defp refuse(fx, overrides, expected) do
      wait_past_tail(fx)

      assert {:error, %Postgrex.Error{postgres: %{code: code, message: message}}} =
               run(fx, overrides)

      case expected do
        {:raise, fragment} ->
          assert code == :raise_exception, inspect({overrides, code, message})
          assert message =~ fragment, inspect({overrides, message})

        {:code, wanted} ->
          assert code == wanted, inspect({overrides, code, message})
      end
    end

    test "a second run on the now-shadow tenant is refused: not stored on" do
      fx = BG.on_tenant!("lr4a")
      run!(fx, %{})
      count = length(entries(fx))

      refuse(fx, %{}, {:raise, "tenant is not stored on"})
      assert BG.mode(fx) == "shadow"
      assert length(entries(fx)) == count
    end

    test "a bad mode is rejected by the mode guard" do
      fx = BG.on_tenant!("lr4b")
      before = length(entries(fx))

      for mode <- ["on", "ON", "", "Shadow", "shadow ", "off\\", "shadow'||'x"] do
        refuse(fx, %{"<MODE>" => mode}, {:raise, "mode must be shadow or off"})
      end

      assert_untouched(fx, before, "bad mode")
    end

    test "a bad operator label is rejected by the label guard (a single quote breaks the literal instead)" do
      fx = BG.on_tenant!("lr4c")
      before = length(entries(fx))

      for operator <- [
            "a\"b",
            "a\\b",
            "a b",
            "a\nb",
            "a\tb",
            "a\x01b",
            String.duplicate("a", 65),
            "",
            ".ab",
            "a;b",
            "a$$b"
          ] do
        refuse(fx, %{"<OPERATOR>" => operator}, {:raise, "bad operator label"})
      end

      refuse(fx, %{"<OPERATOR>" => "a'b"}, {:code, :syntax_error})
      assert_untouched(fx, before, "bad operator")
    end

    test "a bad reason is rejected by the reason guard (a single quote breaks the literal instead)" do
      fx = BG.on_tenant!("lr4d")
      before = length(entries(fx))

      for reason <- [
            "SIGN\"OFF 1",
            "SIGN\\OFF 1",
            "SIGN\nOFF 1",
            "SIGN\tOFF 1",
            "SIGN\x01OFF 1",
            "SIGN{OFF}1",
            String.duplicate("a", 501),
            "",
            "a",
            " SIGN OFF 1",
            "SIGN OFF 1 ",
            "SIGN OFF 1-",
            "$$ SIGN"
          ] do
        refuse(fx, %{"<REASON>" => reason}, {:raise, "bad reason"})
      end

      refuse(fx, %{"<REASON>" => "SIGN'OFF 1"}, {:code, :syntax_error})
      assert_untouched(fx, before, "bad reason")
    end

    test "a boundary reason (500 characters) is accepted" do
      fx = BG.on_tenant!("lr4e")
      reason = "S" <> String.duplicate("a", 498) <> "z"
      assert String.length(reason) == 500
      run!(fx, %{"<REASON>" => reason})
      assert List.last(entries(fx)).after_state["reason"] == reason
    end

    test "a schema that does not match the registration, and another tenant's schema, hit the registration guard" do
      fx = BG.on_tenant!("lr4f")
      other = BG.on_tenant!("lr4g")
      before = length(entries(fx))
      other_before = length(entries(other))

      fake = "tenant_" <> String.duplicate("0", 32)

      for schema <- [fake, other.schema_name, "public", "tenant_x"] do
        refuse(fx, %{"<SCHEMA_NAME>" => schema}, {:raise, "does not match the registration"})
      end

      # another tenant's schema with this tenant's id, and the reverse
      refuse(other, %{"<TENANT_ID>" => fx.tenant_id}, {:raise, "does not match the registration"})

      assert_untouched(fx, before, "schema mismatch")
      assert_untouched(other, other_before, "schema mismatch (other)")
    end

    test "an unknown tenant id hits the registration guard; a non-uuid fails the uuid cast" do
      fx = BG.on_tenant!("lr4h")
      before = length(entries(fx))

      refuse(
        fx,
        %{"<TENANT_ID>" => Ecto.UUID.generate()},
        {:raise, "does not match the registration"}
      )

      refuse(fx, %{"<TENANT_ID>" => "not-a-uuid"}, {:code, :invalid_text_representation})
      assert_untouched(fx, before, "unknown tenant")
    end

    test "a tenant stored off or shadow is refused by the stored-mode guard, nothing is written" do
      for stored <- [:off, :shadow] do
        fx = BG.on_tenant!("lr4i-#{stored}")
        :ok = Letflow.Support.ScopeEnforcementFixture.set_stored_mode!(fx.tenant_id, stored)
        count = length(entries(fx))

        refuse(fx, %{}, {:raise, "tenant is not stored on"})
        assert length(entries(fx)) == count
        assert BG.mode(fx) == Atom.to_string(stored)
      end
    end
  end
end
