defmodule Letflow.LoginDirectory.KeyRotationTest do
  @moduledoc """
  REQ-443 -- `Letflow.LoginDirectory.KeyRotation` (`key_status/0`, `retire_key/2`)
  and the runbook guards. The rotation exercise is the runbook executed as a test:
  rows are seeded under key id A through the real writer (`upsert_entry/2`), the
  configuration is swapped to current = B / previous = A, the real backfill runs,
  then A is retired. See `test/specs/REQ-443.md`.

  `Backfill.run/1` iterates EVERY registered tenant (including other sessions'
  committed tenants in the shared test DB), so counts that the backfill can inflate
  (the B id) are asserted as `>=` for the global table and exactly for this test's
  own tenants; the A id is only ever written by this test and is asserted exactly.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.LoginDirectory
  alias Letflow.LoginDirectory.Backfill
  alias Letflow.LoginDirectory.KeyRotation
  alias Letflow.Test.LoggerCollector
  alias Letflow.Test.LoginDirectoryFixture, as: Fx

  @id_a "rot443-a"
  @id_b "rot443-b"
  @alice "rot-alice@example.test"
  @shared "rot-shared@example.test"

  defp insert_user!(tenant, email) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "rot-#{System.unique_integer([:positive])}",
      display_name: "Rotation Person",
      email: email,
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  defp seed_under_current!(tenant, email) do
    assert {:ok, {:ok, :inserted}} =
             Repo.transaction(fn -> LoginDirectory.upsert_entry(tenant.tenant_id, email) end)
  end

  defp slug(tenant), do: Repo.get!(Tenant, tenant.tenant_id).slug

  defp mine(%{a: a, b: b}), do: Fx.entries(a.tenant_id) ++ Fx.entries(b.tenant_id)
  defp mine_under(ctx, id), do: Enum.filter(mine(ctx), &(&1.key_id == id))

  defp status_map! do
    assert {:ok, rows} = KeyRotation.key_status()
    Map.new(rows)
  end

  # Runs `fun`, returning {result, number_of_repo_query_telemetry_events_by_this_process,
  # sources}. Telemetry fires even for `log: false` calls, so zero events proves no query.
  defp with_queries(fun) do
    ref = make_ref()
    me = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:letflow, :repo, :query],
      fn _e, _m, meta, _c -> if self() == me, do: send(me, {:q, ref, meta.source}) end,
      nil
    )

    try do
      result = fun.()
      {result, drain(ref, [])}
    after
      :telemetry.detach({__MODULE__, ref})
    end
  end

  defp drain(ref, acc) do
    receive do
      {:q, ^ref, source} -> drain(ref, [source | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  setup do
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)

    a = Fx.tenant!()
    b = Fx.tenant!()
    insert_user!(a, @alice)
    insert_user!(a, @shared)
    insert_user!(b, @shared)

    # Phase 1: current = A, no previous. Seed through the real writer.
    Fx.swap_keys!({@id_a, Fx.pepper(1)}, nil)
    seed_under_current!(a, @alice)
    seed_under_current!(a, @shared)
    seed_under_current!(b, @shared)

    %{a: a, b: b}
  end

  defp rotate_to_b! do
    Fx.swap_keys!({@id_b, Fx.pepper(2)}, {@id_a, Fx.pepper(1)})
  end

  describe "the rotation exercise (runbook executed as a test)" do
    test "seed under A, rotate to B/A, backfill, status, retire A, lookup still finds the person",
         %{a: a, b: b} = ctx do
      assert length(mine_under(ctx, @id_a)) == 3
      assert {:ok, [%{slug: slug_a}]} = LoginDirectory.lookup_by_email(@alice)
      assert slug_a == slug(a)

      rotate_to_b!()

      # Previous key still resolves rows written under A.
      assert {:ok, [%{slug: ^slug_a}]} = LoginDirectory.lookup_by_email(@alice)

      assert {:ok, %{key_id: @id_b} = _report} = Backfill.run()

      # Own tenants: 3 rows under each id; the B rows are the independent HMAC oracle's keys.
      assert length(mine_under(ctx, @id_a)) == 3
      b_rows = mine_under(ctx, @id_b)
      assert length(b_rows) == 3
      assert Fx.key_under(Fx.pepper(2), @alice) in Enum.map(b_rows, & &1.email_key)

      status = status_map!()
      assert status[@id_a] == 3
      assert status[@id_b] >= 3

      # Dry run: reports exactly the A count and deletes nothing.
      assert {:ok, %{key_id: @id_a, rows: 3, dry_run: true}} =
               KeyRotation.retire_key(@id_a, dry_run: true)

      assert length(mine_under(ctx, @id_a)) == 3
      assert status_map!() == status

      # Real retire: exactly the A rows go; B rows are untouched.
      b_before = status[@id_b]
      assert {:ok, %{key_id: @id_a, rows: 3, dry_run: false}} = KeyRotation.retire_key(@id_a)
      assert mine_under(ctx, @id_a) == []
      assert length(mine_under(ctx, @id_b)) == 3

      after_status = status_map!()
      refute Map.has_key?(after_status, @id_a)
      assert after_status[@id_b] == b_before

      # Lookup under B alone (previous removed), for the person in both tenants.
      Fx.swap_keys!({@id_b, Fx.pepper(2)}, nil)
      assert {:ok, [%{slug: ^slug_a}]} = LoginDirectory.lookup_by_email(@alice)
      assert {:ok, found} = LoginDirectory.lookup_by_email(@shared)
      assert found |> Enum.map(& &1.slug) |> Enum.sort() == Enum.sort([slug_a, slug(b)])

      # The id is gone, so retiring again is a refusal, not a silent zero.
      assert KeyRotation.retire_key(@id_a) == {:error, :not_found}
    end

    test "retire_key leaves a different key id's rows alone even when the id is a prefix of it",
         ctx do
      rotate_to_b!()
      assert {:ok, _} = Backfill.run()
      b_rows = length(mine_under(ctx, @id_b))

      assert KeyRotation.retire_key("rot443") == {:error, :not_found}
      assert length(mine_under(ctx, @id_a)) == 3
      assert length(mine_under(ctx, @id_b)) == b_rows
    end
  end

  describe "refusals" do
    test "the CURRENT key id is refused and nothing is deleted (also under --dry-run)", ctx do
      rotate_to_b!()
      assert {:ok, _} = Backfill.run()
      before = length(mine(ctx))

      assert KeyRotation.retire_key(@id_b) == {:error, :current_key_id}
      assert KeyRotation.retire_key(@id_b, dry_run: true) == {:error, :current_key_id}
      assert length(mine(ctx)) == before
    end

    test "an absent key id is refused (real and dry run) and nothing is deleted", ctx do
      before = length(mine(ctx))

      assert KeyRotation.retire_key("rot443-absent") == {:error, :not_found}
      assert KeyRotation.retire_key("rot443-absent", dry_run: true) == {:error, :not_found}
      assert length(mine(ctx)) == before
    end

    test "an invalid key id is refused before ANY query is issued", ctx do
      before = length(mine(ctx))

      invalid = [
        "",
        "UPPER",
        "Rot443-a",
        String.duplicate("a", 33),
        "has space",
        "semi;colon",
        "a\nb",
        "rot443-a\n",
        "é",
        nil,
        :rot443,
        123
      ]

      {results, queries} =
        with_queries(fn -> Enum.map(invalid, &KeyRotation.retire_key/1) end)

      assert Enum.all?(results, &(&1 == {:error, :invalid_key_id})), inspect(results)
      assert queries == []

      {dry, queries} =
        with_queries(fn -> Enum.map(invalid, &KeyRotation.retire_key(&1, dry_run: true)) end)

      assert Enum.all?(dry, &(&1 == {:error, :invalid_key_id}))
      assert queries == []
      assert length(mine(ctx)) == before
    end

    test "the boundary lengths 1 and 32 are VALID ids (reach the query, then :not_found)" do
      assert KeyRotation.retire_key("a") == {:error, :not_found}
      assert KeyRotation.retire_key(String.duplicate("a", 32)) == {:error, :not_found}
      assert KeyRotation.retire_key("a-b_9") == {:error, :not_found}
    end

    test "current/invalid refusals do not touch the table either", ctx do
      rotate_to_b!()

      {result, queries} = with_queries(fn -> KeyRotation.retire_key(@id_b) end)
      assert result == {:error, :current_key_id}
      assert queries == []
      assert length(mine_under(ctx, @id_a)) == 3
    end

    test "unconfigured keys: {:error, :pepper_unavailable} and nothing is deleted", ctx do
      before = length(mine(ctx))
      Fx.swap_keys!(:unset, nil)

      assert KeyRotation.retire_key(@id_a) == {:error, :pepper_unavailable}
      assert KeyRotation.retire_key(@id_a, dry_run: true) == {:error, :pepper_unavailable}
      assert length(mine(ctx)) == before
    end

    test "a failing query (no DB connection owned) is a fixed atom, not an exception", _ctx do
      :ok = Ecto.Adapters.SQL.Sandbox.checkin(Repo)

      assert KeyRotation.key_status() == {:error, :status_failed}
      assert KeyRotation.retire_key("rot443-x") == {:error, :retire_failed}
      assert KeyRotation.retire_key("rot443-x", dry_run: true) == {:error, :retire_failed}
    end
  end

  describe "key_status" do
    test "returns {key_id, count} tuples ordered by key id; counts only", ctx do
      rotate_to_b!()
      assert {:ok, _} = Backfill.run()

      assert {:ok, rows} = KeyRotation.key_status()
      assert rows == Enum.sort_by(rows, &elem(&1, 0))
      assert Enum.all?(rows, fn {id, n} -> is_binary(id) and is_integer(n) and n > 0 end)
      assert {@id_a, 3} in rows
      assert Enum.any?(rows, fn {id, n} -> id == @id_b and n >= 3 end)
      assert length(mine(ctx)) == 6
    end
  end

  describe "INV-4 / INV-7" do
    test "no email, key (hex/base64/inspect), pepper or directory query reaches Logger at :debug",
         %{a: a} do
      rotate_to_b!()
      assert {:ok, _} = Backfill.run()
      key = Fx.key_under(Fx.pepper(1), @alice)
      key_b = Fx.key_under(Fx.pepper(2), @alice)

      {results, entries} =
        LoggerCollector.capture(
          fn ->
            [
              KeyRotation.key_status(),
              KeyRotation.retire_key(@id_a, dry_run: true),
              KeyRotation.retire_key(@id_b),
              KeyRotation.retire_key("rot443-absent"),
              KeyRotation.retire_key("BAD"),
              KeyRotation.retire_key(@id_a)
            ]
          end,
          attribute_to: self()
        )

      log = LoggerCollector.text(entries)

      secrets = [key, key_b, Fx.pepper(1), Fx.pepper(2)]
      dumped = inspect(results, limit: :infinity)

      for secret <- secrets, haystack <- [log, dumped] do
        refute haystack =~ Base.encode16(secret, case: :lower)
        refute haystack =~ Base.encode16(secret, case: :upper)
        refute haystack =~ Base.encode64(secret)
        refute haystack =~ inspect(secret, limit: :infinity)
      end

      for haystack <- [log, dumped] do
        refute haystack =~ "example.test"
        refute haystack =~ "rot-alice"
        refute haystack =~ "@"
      end

      # `log: false` effect: no QUERY line at all and no directory table name.
      refute log =~ "QUERY"
      refute log =~ "tenant_login_directory"
      assert Fx.entries(a.tenant_id) != []
    end

    test "control: telemetry DOES see the directory queries (so the empty log is log: false, not silence)" do
      {_results, queries} =
        with_queries(fn ->
          KeyRotation.key_status()
          KeyRotation.retire_key(@id_a, dry_run: true)
        end)

      assert "tenant_login_directory" in queries
    end

    test "control: an ordinary Ecto query IS logged at :debug by this harness" do
      {_, entries} =
        LoggerCollector.capture(
          fn ->
            Repo.all(from(t in Tenant, where: t.slug == ^"control-slug-443", select: t.id))
          end,
          attribute_to: self()
        )

      log = LoggerCollector.text(entries)

      # QueryLogFilter (#5118) redacts the parameter values of personal-value SELECTs, so the
      # control asserts the query itself is logged (text and source), not the bound value.
      assert log =~ "QUERY"
      assert log =~ ~s(source="tenants")
      assert log =~ "[redacted]"
      refute log =~ "control-slug-443"
    end

    test "source: every Repo call in key_rotation.ex carries log: false (balanced-paren scan)" do
      source = File.read!("lib/letflow/login_directory/key_rotation.ex")
      calls = Regex.scan(~r/Repo\.[a-z_]+[!?]?\(/, source, return: :index)

      assert length(calls) >= 3

      for [{start, len}] <- calls do
        args = balanced_args(source, start + len, 1)
        assert args =~ "log: false", "a Repo call at byte #{start} lacks log: false"
      end
    end

    test "source: no string-built SQL in the module or the two tasks (INV-7)" do
      paths = [
        "lib/letflow/login_directory/key_rotation.ex",
        "lib/mix/tasks/letflow.login_directory.key_status.ex",
        "lib/mix/tasks/letflow.login_directory.retire_key.ex"
      ]

      for path <- paths do
        source = File.read!(path)
        refute source =~ ~r/Repo\.query!?\(/, "#{path} issues raw SQL"
        refute source =~ ~r/fragment\(/, "#{path} uses a fragment"
        refute source =~ ~r/search_path|DROP |DELETE FROM|SELECT /i, "#{path} embeds SQL text"
      end

      # The query module never interpolates at all; the tasks do not touch Repo.
      refute File.read!("lib/letflow/login_directory/key_rotation.ex") =~ "\#{"
      refute File.read!("lib/mix/tasks/letflow.login_directory.key_status.ex") =~ "Repo."
      refute File.read!("lib/mix/tasks/letflow.login_directory.retire_key.ex") =~ "Repo."
    end
  end

  describe "runbook (docs/runbooks/login-directory-pepper-rotation.md)" do
    @runbook "docs/runbooks/login-directory-pepper-rotation.md"
    @hex64 ~r/(?<![0-9A-Fa-f])[0-9A-Fa-f]{64}(?![0-9A-Fa-f])/

    test "exists and has the four procedure sections and the EXTERNAL dependency" do
      assert File.regular?(@runbook)
      text = File.read!(@runbook)

      assert text =~ ~r/^## 1\. First provisioning/m
      assert text =~ ~r/^## 2\. Planned rotation/m
      assert text =~ ~r/^## 3\. Emergency rotation/m
      assert text =~ ~r/^## 4\. Rollback/m
      assert text =~ ~r/^## 5\. EXTERNAL dependency/m
      assert text =~ "secrets-inventory"
      assert text =~ "ai-dala-infra"
      assert text =~ "LETFLOW_LOGIN_DIRECTORY_PEPPER"

      # It names the tools it relies on, so a rename of a task breaks this test.
      assert text =~ "mix letflow.login_directory.key_status"
      assert text =~ "mix letflow.login_directory.retire_key"
      assert text =~ "mix letflow.backfill_login_directory"
    end

    test "the named mix tasks exist" do
      for task <- ["letflow.login_directory.key_status", "letflow.login_directory.retire_key"] do
        assert Mix.Task.get(task), "#{task} is not a Mix task"
      end
    end

    test "contains no 64-hex string (no secret value)" do
      refute File.read!(@runbook) =~ @hex64
    end

    test "contains no command that prints or expands a pepper variable" do
      lines = @runbook |> File.read!() |> String.split(~r/\r?\n/)

      for line <- lines do
        refute line =~ ~r/\b(echo|printenv|cat|type|Get-Content|Write-Host)\b/ and
                 line =~ "PEPPER",
               "prints a pepper variable: #{line}"

        refute line =~ ~r/\$\{?LETFLOW_LOGIN_DIRECTORY_PEPPER/,
               "expands a pepper variable: #{line}"

        refute line =~ ~r/\bprintenv\b/, "printenv: #{line}"
        refute line =~ ~r/^\s*(echo|cat)\s/, "echo/cat command: #{line}"
      end

      # The one command that generates a secret must be redirected, not printed.
      for line <- lines, line =~ "openssl rand" do
        assert line =~ ~r/redirect|>/, "generator not redirected: #{line}"
      end
    end

    test "the 64-hex guard can fail (seeded violation)" do
      hex = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
      assert "value: #{hex}\n" =~ @hex64
      assert "value: #{String.upcase(hex)}\n" =~ @hex64
      refute "value: #{String.slice(hex, 0, 63)}\n" =~ @hex64
    end
  end

  # Text of the balanced-paren argument list starting just after an opening "(".
  defp balanced_args(source, from, depth) do
    rest = binary_part(source, from, byte_size(source) - from)
    take_balanced(rest, depth, [])
  end

  defp take_balanced(<<>>, _depth, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp take_balanced(<<")", _::binary>>, 1, acc),
    do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp take_balanced(<<")", r::binary>>, d, acc), do: take_balanced(r, d - 1, [")" | acc])
  defp take_balanced(<<"(", r::binary>>, d, acc), do: take_balanced(r, d + 1, ["(" | acc])
  defp take_balanced(<<c, r::binary>>, d, acc), do: take_balanced(r, d, [<<c>> | acc])
end
