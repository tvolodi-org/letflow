defmodule Letflow.ServiceCatalog.EndpointUrlDbGuardParityTest do
  @moduledoc """
  GH #2638 T2 + T3: the database CHECK pattern and the Elixir recogniser agree, and a direct
  (changeset-free) write of a `_sys` URL fails with the named constraint on BOTH catalog tables.
  Design: `lib/letflow/design/gh2638-catalog-endpoint-sys-db-guard.md` (rev 2) sections 3 and 6.
  Spec: `test/specs/GH-2638.md`.

  The pattern is read from the LIVE constraint (`pg_get_constraintdef`), never from a copy in
  this file, so the test cannot agree with a stale copy. The verdict is the bound-parameter
  query `SELECT $1::text ~ $2::text`, so neither value is re-escaped.

  `async: false`, `:auto` mode: `service_catalog` is a GLOBAL table; every row written is
  deleted in `on_exit/1` by its `gh2638-par-` service id.
  """

  use Letflow.DataCase, async: false
  use ExUnitProperties

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.ServiceCatalog.Entry
  alias Letflow.ServiceCatalog.Version

  @live_check "chk_service_catalog_endpoint_url_no_reserved_ref"
  @versions_check "chk_service_catalog_versions_endpoint_url_no_reserved_ref"

  @base "https://example.test/"

  # {label, path-after-base, refused?}; the one table every assertion below iterates.
  @table [
    {"bare", "{{variables._sys}}", true},
    {"bare, upper", "{{variables._SYS}}", false},
    {"dotted", "{{variables._sys.x}}", true},
    {"dotted, deep", "{{variables._sys.r.seq}}", true},
    {"dotted, empty tail", "{{variables._sys.}}", true},
    {"whitespace, spaces", "{{ variables._sys }}", true},
    {"whitespace, tab and LF", "{{\tvariables._sys.x\n}}", true},
    {"whitespace, VT FF CR", "{{\vvariables._sys\f\r}}", true},
    {"whitespace, Unicode EM SPACE", "{{ variables._sys}}", false},
    {"similar name _system", "{{variables._system}}", false},
    {"similar name _sysx", "{{variables._sysx}}", false},
    {"nested, not reserved", "{{variables.a._sys}}", false},
    {"suffix", "{{variables.x_sys}}", false},
    {"trailing garbage", "{{variables._sys x}}", false},
    {"unclosed", "{{variables._sys", false},
    {"wrong capitalisation of variables", "{{Variables._sys}}", false},
    {"text outside a placeholder", "_sys/{{variables.a}}", false},
    {"ordinary key", "{{variables.order_id}}", false},
    {"multiple placeholders, one reserved", "{{variables.ok}}/{{variables._sys.b}}", true},
    {"no placeholder", "svc", false}
  ]

  # The one whole-URL row (reserved reference in the host position).
  @host_url "https://{{variables._sys}}.example.test/x"

  setup do
    Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      Repo.query!("DELETE FROM service_catalog_versions WHERE service_id LIKE 'gh2638-par-%'")
      Repo.query!("DELETE FROM service_catalog WHERE service_id LIKE 'gh2638-par-%'")
    end)

    :ok
  end

  # -- pattern extraction -------------------------------------------------

  defp constraint_literal(name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c WHERE c.conname = $1",
        [name]
      )

    assert [[definition]] = rows, "expected exactly one constraint named #{name}"

    assert [[_, literal]] = Regex.scan(~r/!~ '(.*)'::text/s, definition),
           "could not capture a single quoted literal from #{inspect(definition)}"

    literal |> String.replace("''", "'")
  end

  defp live_pattern do
    live = constraint_literal(@live_check)
    versions = constraint_literal(@versions_check)

    assert live == versions, "the two tables must carry a byte-identical pattern"
    refute String.contains?(live, "'")
    refute String.starts_with?(live, "E")
    live
  end

  defp db_refuses?(pattern, template) do
    %{rows: [[verdict]]} = Repo.query!("SELECT $1::text ~ $2::text", [template, pattern])
    verdict
  end

  defp elixir_refuses?(url),
    do: Entry.check_endpoint_url_references(url) == {:error, :endpoint_url_reserved_variable}

  # -- direct writers -----------------------------------------------------

  defp sid, do: "gh2638-par-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp live_row(service_id, url) do
    ts = now()

    %{
      service_id: service_id,
      endpoint_url: url,
      required_auth: :NONE,
      timeout_ms: 5_000,
      scope: :global,
      version: "1",
      version_id: Ecto.UUID.generate(),
      status: :ACTIVE,
      published_at: ts,
      created_at: ts,
      updated_at: ts
    }
  end

  defp version_row(service_id, url) do
    ts = now()

    %{
      version_id: Ecto.UUID.generate(),
      service_id: service_id,
      version: "1",
      endpoint_url: url,
      required_auth: :NONE,
      timeout_ms: 5_000,
      published_at: ts,
      retired_at: ts
    }
  end

  defp insert_live(url), do: Repo.insert_all(Entry, [live_row(sid(), url)])
  defp insert_version(url), do: Repo.insert_all(Version, [version_row(sid(), url)])

  defp assert_check_violation(fun, constraint) do
    error = assert_raise(Postgrex.Error, fun)
    assert error.postgres.code == :check_violation
    assert error.postgres.constraint == constraint
  end

  # -- T2 -----------------------------------------------------------------

  describe "T2 parity (live constraint pattern vs Elixir recogniser)" do
    test "the pattern is read from the live constraint and is identical on both tables" do
      pattern = live_pattern()
      assert pattern =~ "variables"
      assert pattern =~ "_sys"
    end

    test "every parity-table row: Elixir verdict == DB regex verdict == expectation" do
      pattern = live_pattern()

      rows =
        [{"host position", @host_url, true}] ++
          Enum.map(@table, fn {l, p, r} -> {l, @base <> p, r} end)

      for {label, url, refused} <- rows do
        assert elixir_refuses?(url) == refused, "Elixir verdict wrong for #{label}"
        assert db_refuses?(pattern, url) == refused, "DB verdict wrong for #{label}"
      end

      # The table must exercise both verdicts, or the loop above proves nothing.
      assert Enum.any?(rows, fn {_, _, r} -> r end)
      assert Enum.any?(rows, fn {_, _, r} -> not r end)
    end

    test "every parity-table row: a direct insert is refused or accepted accordingly, on both tables" do
      rows =
        [{"host position", @host_url, true}] ++
          Enum.map(@table, fn {l, p, r} -> {l, @base <> p, r} end)

      for {label, url, refused} <- rows do
        if refused do
          assert_check_violation(fn -> insert_live(url) end, @live_check)
          assert_check_violation(fn -> insert_version(url) end, @versions_check)
        else
          assert {1, _} = insert_live(url), "live insert should succeed for #{label}"
          assert {1, _} = insert_version(url), "version insert should succeed for #{label}"
        end
      end
    end

    property "Elixir verdict equals DB verdict over generated placeholder-like templates" do
      pattern = live_pattern()

      ws_chars = [?\s, ?\t, ?\n, 11, 12, ?\r, 0x2003]
      ws = StreamData.string(ws_chars, max_length: 2)

      key =
        StreamData.frequency([
          {3,
           StreamData.member_of(["_sys", "_sys.", "_system", "_SYS", "a._sys", "_sys.x", "_sysx"])},
          {2, StreamData.string([?a..?z, ?0..?9, ?_, ?.], max_length: 6)}
        ])

      opener =
        StreamData.frequency([{5, StreamData.constant("{{")}, {1, StreamData.constant("{")}])

      closer =
        StreamData.frequency([
          {5, StreamData.constant("}}")},
          {1, StreamData.member_of(["}", "", "} }"])}
        ])

      var =
        StreamData.frequency([
          {9, StreamData.constant("variables.")},
          {1, StreamData.constant("Variables.")}
        ])

      outside = StreamData.member_of(["", "x/", "{{variables.ok}}/", "_sys"])

      check all(
              pre <- outside,
              o <- opener,
              w1 <- ws,
              v <- var,
              k <- key,
              w2 <- ws,
              c <- closer,
              post <- outside,
              max_runs: 200
            ) do
        url = @base <> pre <> o <> w1 <> v <> k <> w2 <> c <> post

        assert elixir_refuses?(url) == db_refuses?(pattern, url),
               "Elixir and DB disagree on #{inspect(url)}"
      end
    end
  end

  # -- T3 -----------------------------------------------------------------

  describe "T3 non-changeset writers hit the named CHECK" do
    @refused_url @base <> "{{variables._sys.secret}}"

    test "Repo.insert_all of a reserved URL fails on service_catalog" do
      assert_check_violation(fn -> insert_live(@refused_url) end, @live_check)
    end

    test "Repo.insert_all of a reserved URL fails on service_catalog_versions" do
      assert_check_violation(fn -> insert_version(@refused_url) end, @versions_check)
    end

    test "a clean URL inserts on both tables" do
      assert {1, _} = insert_live(@base <> "{{variables.order_id}}")
      assert {1, _} = insert_version(@base <> "{{variables.order_id}}")
    end

    test "a raw UPDATE of a clean row to a reserved URL fails on both tables" do
      live_id = sid()
      ver_id = sid()
      assert {1, _} = Repo.insert_all(Entry, [live_row(live_id, @base <> "ok")])
      assert {1, _} = Repo.insert_all(Version, [version_row(ver_id, @base <> "ok")])

      assert_check_violation(
        fn ->
          Repo.query!("UPDATE service_catalog SET endpoint_url = $1 WHERE service_id = $2", [
            @refused_url,
            live_id
          ])
        end,
        @live_check
      )

      assert_check_violation(
        fn ->
          Repo.query!(
            "UPDATE service_catalog_versions SET endpoint_url = $1 WHERE service_id = $2",
            [@refused_url, ver_id]
          )
        end,
        @versions_check
      )

      # The rows are unchanged.
      assert %{rows: [[url]]} =
               Repo.query!("SELECT endpoint_url FROM service_catalog WHERE service_id = $1", [
                 live_id
               ])

      assert url == @base <> "ok"
    end
  end
end
