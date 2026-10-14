defmodule Letflow.IdempotencyTest do
  @moduledoc """
  GH #2550 -- unit and source-scan coverage for `Letflow.Idempotency`
  (design `lib/letflow/design/gh2550-client-idempotency-key-namespace.md`
  D1, D3 (iv), D5 and the AC5 scan/prefix rows of §3). Pure: no database.
  The real-Postgres coverage is `test/letflow/client_key_namespace_test.exs`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Plug.Test, only: [conn: 2]
  import Plug.Conn, only: [put_req_header: 3]

  alias Letflow.Api.Validation.FieldError
  alias Letflow.Idempotency

  @actor "11111111-2222-3333-4444-555555555555"
  @instance "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

  # Design §1b, each family with the file whose literal builds it.
  @server_families %{
    "timer_fired:" => ["lib/letflow/engine.ex", "lib/letflow/scheduler.ex"],
    "escalation_timer_fired:" => ["lib/letflow/engine.ex"],
    "service_task_dispatch:" => ["lib/letflow/engine.ex"],
    "service_task:" => ["lib/letflow/engine/service_task.ex"],
    "script_task_dispatch:" => ["lib/letflow/engine.ex"],
    "script_run:" => ["lib/letflow/engine.ex"],
    "certificate:issue:" => ["lib/letflow/modules/exam/certificate.ex"],
    "entities-record-import:" => ["lib/letflow/routers/entities.ex"],
    "attachment_attached:" => ["lib/letflow/repository/attachments.ex"],
    "attachment_removed:" => ["lib/letflow/repository/attachments.ex"],
    "effect_applied:" => ["lib/letflow/ordering/consumer.ex"],
    "ordering_lag_exceeded:" => ["lib/letflow/ordering/metrics.ex"],
    "definition_promoted:" => ["lib/letflow/event_store/platform_events.ex"],
    "definition_version_rolled_back:" => ["lib/letflow/event_store/platform_events.ex"],
    "promotion_assertion_teardown_failed:" => ["lib/letflow/event_store/platform_events.ex"],
    "req345-seed-" => ["lib/mix/tasks/letflow.seed.exam_fixtures.ex"]
  }

  describe "client_key/4 and raw_max/1 (D1, D5)" do
    test "builds every route's shape exactly" do
      assert Idempotency.client_key(:rec, @actor, nil, "K") == "client:rec:#{@actor}:K"

      assert Idempotency.client_key(:inst_start, @actor, nil, "K") ==
               "client:inst_start:#{@actor}:K"

      assert Idempotency.client_key(:inst_cancel, @actor, @instance, "K") ==
               "client:inst_cancel:#{@actor}:#{@instance}:K"

      assert Idempotency.client_key(:inst_rebind, @actor, @instance, "K") ==
               "client:inst_rebind:#{@actor}:#{@instance}:K"
    end

    test "raw_max is 199 for rec/inst_start/script and 162 for cancel/rebind" do
      assert Idempotency.raw_max(:rec) == 199
      assert Idempotency.raw_max(:inst_start) == 199
      assert Idempotency.raw_max(:script) == 199
      assert Idempotency.raw_max(:inst_cancel) == 162
      assert Idempotency.raw_max(:inst_rebind) == 162
    end

    test "the longest raw key on every route still fits varchar(255)" do
      for route <- [:rec, :inst_start] do
        key = Idempotency.client_key(route, @actor, nil, String.duplicate("k", 199))
        assert byte_size(key) <= 255
      end

      for route <- [:inst_cancel, :inst_rebind] do
        key = Idempotency.client_key(route, @actor, @instance, String.duplicate("k", 162))
        assert byte_size(key) == 255
      end
    end

    test "raises FunctionClauseError on wrong instance arity, bad uuid size, empty or over-long raw" do
      bad_calls = [
        [:rec, @actor, @instance, "K"],
        [:inst_cancel, @actor, nil, "K"],
        [:rec, "short", nil, "K"],
        [:inst_rebind, @actor, "short", "K"],
        [:rec, @actor, nil, ""],
        [:rec, @actor, nil, String.duplicate("k", 200)],
        [:inst_cancel, @actor, @instance, String.duplicate("k", 163)]
      ]

      # apply/3 keeps the compiler's type checker from flagging the deliberate misuse.
      for args <- bad_calls do
        assert_raise FunctionClauseError, fn -> apply(Idempotency, :client_key, args) end
      end
    end

    property "a client key never starts with a server or script family" do
      check all(
              route <- member_of([:rec, :inst_start, :inst_cancel, :inst_rebind]),
              # 40 codepoints <= 160 bytes, inside every route's raw_max/1.
              raw <- string(:printable, min_length: 1, max_length: 40)
            ) do
        instance = if route in [:inst_cancel, :inst_rebind], do: @instance, else: nil
        key = Idempotency.client_key(route, @actor, instance, raw)

        refute String.starts_with?(key, Idempotency.server_prefixes())
        refute String.starts_with?(key, "script:")
        assert String.starts_with?(key, "client:")
      end
    end
  end

  describe "from_body/3 (D1, D3 guard (iv))" do
    test "absent key -> a bare minted UUID, no legacy lookup" do
      assert {:ok, %{key: key, legacy_raw: nil}} = Idempotency.from_body(%{}, :rec, @actor)
      assert {:ok, _uuid} = Ecto.UUID.cast(key)
    end

    test "a plain key is namespaced and is a legacy candidate" do
      assert {:ok, %{key: key, legacy_raw: "legacy-k"}} =
               Idempotency.from_body(%{"idempotency_key" => "legacy-k"}, :rec, @actor)

      assert key == "client:rec:#{@actor}:legacy-k"
    end

    test "a key in any server, reserved or caller family is namespaced and never a legacy candidate" do
      for prefix <-
            Idempotency.server_prefixes() ++
              Idempotency.reserved_prefixes() ++ Idempotency.caller_prefixes() do
        raw = prefix <> "x"

        assert {:ok, %{key: key, legacy_raw: nil}} =
                 Idempotency.from_body(%{"idempotency_key" => raw}, :rec, @actor)

        assert key == "client:rec:#{@actor}:" <> raw
      end
    end

    test "199 bytes is accepted, 200 bytes is refused (bytes, not codepoints)" do
      raw_199 = String.duplicate("é", 99) <> "a"
      assert byte_size(raw_199) == 199

      assert {:ok, %{key: key}} =
               Idempotency.from_body(%{"idempotency_key" => raw_199}, :rec, @actor)

      assert byte_size(key) <= 255

      raw_200 = String.duplicate("é", 100)
      assert String.length(raw_200) == 100

      assert {:error, :idempotency_key_too_long} =
               Idempotency.from_body(%{"idempotency_key" => raw_200}, :rec, @actor)
    end
  end

  describe "invalid keys (F1): not valid UTF-8 or containing NUL, refused before any I/O" do
    @invalid_raws ["a" <> <<0>> <> "b", <<0xFF, 0xFE>>, "ok" <> <<0xC3>>]

    test "from_body/3 refuses them, even when they would also be too long" do
      for raw <- @invalid_raws ++ [String.duplicate("k", 250) <> <<0>>] do
        assert {:error, :idempotency_key_invalid} =
                 Idempotency.from_body(%{"idempotency_key" => raw}, :rec, @actor)
      end
    end

    test "from_header/4 refuses them on every route" do
      for raw <- @invalid_raws, route <- [:inst_start, :inst_cancel, :inst_rebind] do
        c = conn(:post, "/") |> put_req_header("idempotency-key", raw)
        instance = if route == :inst_start, do: nil, else: @instance

        assert {:error, :idempotency_key_invalid} =
                 Idempotency.from_header(c, route, @actor, instance)
      end
    end

    test "script_key/2 refuses them" do
      for raw <- @invalid_raws do
        assert {:error, :idempotency_key_invalid} = Idempotency.script_key(raw, @actor)
      end
    end

    test "invalid_error/1 is a stable format error with no received echo" do
      assert %FieldError{field: "idempotency_key", constraint: "format", received: nil} =
               Idempotency.invalid_error(:body)

      assert %FieldError{field: "idempotency-key", constraint: "format", received: nil} =
               Idempotency.invalid_error(:header)
    end
  end

  describe "from_body/3 non-binary key (nit 5)" do
    test "only a missing key or nil mints a UUID; any other non-binary is invalid" do
      for attrs <- [%{}, %{"idempotency_key" => nil}] do
        assert {:ok, %{key: key, legacy_raw: nil}} = Idempotency.from_body(attrs, :rec, @actor)
        assert {:ok, _uuid} = Ecto.UUID.cast(key)
      end

      for bad <- [42, 1.5, true, false, [], ["k"], %{"k" => "v"}, ""] do
        assert {:error, :idempotency_key_invalid} =
                 Idempotency.from_body(%{"idempotency_key" => bad}, :rec, @actor)
      end
    end
  end

  describe "from_header/4 (D1, D5)" do
    test "absent or empty header -> a bare minted UUID" do
      assert {:ok, key} = Idempotency.from_header(conn(:post, "/"), :inst_start, @actor, nil)
      assert {:ok, _uuid} = Ecto.UUID.cast(key)

      empty = conn(:post, "/") |> put_req_header("idempotency-key", "")
      assert {:ok, key} = Idempotency.from_header(empty, :inst_start, @actor, nil)
      assert {:ok, _uuid} = Ecto.UUID.cast(key)
    end

    test "a supplied header is namespaced per route" do
      c = conn(:post, "/") |> put_req_header("idempotency-key", "K")

      assert {:ok, "client:inst_start:#{@actor}:K"} ==
               Idempotency.from_header(c, :inst_start, @actor, nil)

      assert {:ok, "client:inst_cancel:#{@actor}:#{@instance}:K"} ==
               Idempotency.from_header(c, :inst_cancel, @actor, @instance)
    end

    test "over the route's limit is refused, never truncated" do
      long = conn(:post, "/") |> put_req_header("idempotency-key", String.duplicate("k", 200))

      assert {:error, :idempotency_key_too_long} =
               Idempotency.from_header(long, :inst_start, @actor, nil)

      c163 = conn(:post, "/") |> put_req_header("idempotency-key", String.duplicate("k", 163))

      assert {:error, :idempotency_key_too_long} =
               Idempotency.from_header(c163, :inst_rebind, @actor, @instance)

      c162 = conn(:post, "/") |> put_req_header("idempotency-key", String.duplicate("k", 162))
      assert {:ok, key} = Idempotency.from_header(c162, :inst_rebind, @actor, @instance)
      assert byte_size(key) == 255
    end
  end

  describe "script_key/2, too_long_error/1" do
    test "script keys are namespaced; empty, non-binary and over-199-byte keys are refused" do
      assert {:ok, "script:#{@actor}:K"} == Idempotency.script_key("K", @actor)
      assert {:ok, _} = Idempotency.script_key(String.duplicate("k", 199), @actor)

      for bad <- ["", 42, nil, String.duplicate("k", 200), String.duplicate("k", 300)] do
        assert {:error, :idempotency_key_invalid} = Idempotency.script_key(bad, @actor)
      end
    end

    test "script_key/2 has client_key/4's 36-byte actor guard (F5)" do
      for bad_actor <- ["short", @actor <> "x", nil, 42] do
        assert {:error, :idempotency_key_invalid} = Idempotency.script_key("K", bad_actor)
      end
    end

    test "too_long_error names the body field or the header, max_length, no received echo" do
      assert %FieldError{
               field: "idempotency_key",
               constraint: "max_length",
               received: nil
             } = Idempotency.too_long_error(:body)

      assert %FieldError{
               field: "idempotency-key",
               constraint: "max_length",
               received: nil
             } = Idempotency.too_long_error(:header)
    end
  end

  describe "prefixes (AC5)" do
    test "caller, server and reserved prefixes do not overlap in either direction" do
      families = [
        caller: Idempotency.caller_prefixes(),
        server: Idempotency.server_prefixes(),
        reserved: Idempotency.reserved_prefixes()
      ]

      for {fa, as} <- families, {fb, bs} <- families, fa != fb, a <- as, b <- bs do
        refute String.starts_with?(a, b), "#{fa} #{a} starts with #{fb} prefix #{b}"
      end

      assert Idempotency.caller_prefixes() == ["client:", "script:"]
      assert Idempotency.reserved_prefixes() == ["sys:"]
    end

    test "sys:step:x is namespaced like any caller key and never a legacy candidate" do
      assert {:ok, %{key: key, legacy_raw: nil}} =
               Idempotency.from_body(%{"idempotency_key" => "sys:step:x"}, :rec, @actor)

      assert key == "client:rec:#{@actor}:sys:step:x"
    end

    test "server_prefixes/0 is exactly design §1b, and each literal is still built in its file" do
      assert Enum.sort(Idempotency.server_prefixes()) == Enum.sort(Map.keys(@server_families))

      for {prefix, files} <- @server_families, file <- files do
        assert File.read!(file) =~ "\"" <> prefix,
               "#{file} no longer builds a #{inspect(prefix)} key; update server_prefixes/0"
      end
    end
  end

  describe "legacy cutoff (D3 (i), GH #2578)" do
    test "legacy cutoff is pinned" do
      assert Idempotency.legacy_cutoff() == ~U[2026-11-16 00:00:00.000000Z]
    end
  end

  describe "caller key is read only in Idempotency (AC5 scan)" do
    # Exact quoted literals only: `"idempotency_key_reuse"`, the CORS header
    # list and `idempotency-key-reuse` are longer strings and do not match.
    @literals ["\"idempotency_key\"", "\"idempotency-key\""]

    # {file, trimmed line} -- the FieldConstraint name is a schema entry, not a read.
    @allowlist [{"lib/letflow/routers/entities.ex", "name: \"idempotency_key\","}]

    test "caller key is read only in Idempotency" do
      hits =
        for file <- Path.wildcard("lib/**/*.ex"),
            file != "lib/letflow/idempotency.ex",
            not String.starts_with?(file, "lib/letflow/design/"),
            {line, n} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
            Enum.any?(@literals, &String.contains?(line, &1)),
            {file, String.trim(line)} not in @allowlist,
            do: "#{file}:#{n}: #{String.trim(line)}"

      assert hits == [],
             "caller idempotency key read outside Letflow.Idempotency:\n" <> Enum.join(hits, "\n")
    end

    test "the allowlisted FieldConstraint entry is still present (the allowlist is not stale)" do
      assert File.read!("lib/letflow/routers/entities.ex") =~ ~s(name: "idempotency_key",)
    end
  end
end
