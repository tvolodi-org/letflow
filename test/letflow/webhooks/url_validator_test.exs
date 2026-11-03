defmodule Letflow.Webhooks.UrlValidatorTest do
  @moduledoc """
  Unit tests for `Letflow.Webhooks.UrlValidator`. See `test/specs/REQ-204.md`
  for the full acceptance-criterion -> test-case mapping and rationale.

  No database access. All hostname-based tests use injected DNS resolvers
  (`validate/2`) rather than real DNS lookups. IP-literal tests use `validate/1`
  safely because `check_ip_literal/1` short-circuits before any DNS call.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.Webhooks.UrlValidator

  # ---------------------------------------------------------------------------
  # AC1 — non-https scheme is rejected before IP/DNS check
  # ---------------------------------------------------------------------------

  test "http:// scheme is rejected" do
    assert {:error, :target_url_not_allowed} = UrlValidator.validate("http://example.com/hook")
  end

  test "ftp:// scheme is rejected" do
    assert {:error, :target_url_not_allowed} = UrlValidator.validate("ftp://example.com/hook")
  end

  test "schemeless URL is rejected" do
    assert {:error, :target_url_not_allowed} = UrlValidator.validate("example.com/hook")
  end

  test "empty string is rejected" do
    assert {:error, :target_url_not_allowed} = UrlValidator.validate("")
  end

  # ---------------------------------------------------------------------------
  # AC2 — IPv4 private / loopback / link-local literals (no DNS needed)
  # ---------------------------------------------------------------------------

  test "IPv4 loopback 127.0.0.1 is rejected" do
    assert {:error, :target_url_not_allowed} = UrlValidator.validate("https://127.0.0.1/hook")
  end

  # 169.254.169.254 is the cloud instance-metadata service address; rejected
  # by the 169.254.0.0/16 link-local range.
  test "IPv4 link-local / cloud metadata 169.254.169.254 is rejected by name" do
    assert {:error, :target_url_not_allowed} =
             UrlValidator.validate("https://169.254.169.254/hook")
  end

  test "RFC-1918 10.0.0.5 is rejected" do
    assert {:error, :target_url_not_allowed} = UrlValidator.validate("https://10.0.0.5/hook")
  end

  test "RFC-1918 172.16.0.5 is rejected" do
    assert {:error, :target_url_not_allowed} = UrlValidator.validate("https://172.16.0.5/hook")
  end

  test "RFC-1918 192.168.0.5 is rejected" do
    assert {:error, :target_url_not_allowed} = UrlValidator.validate("https://192.168.0.5/hook")
  end

  # ---------------------------------------------------------------------------
  # IPv6 literals — all blocked
  # ---------------------------------------------------------------------------

  test "IPv6 loopback ::1 is rejected" do
    assert {:error, :target_url_not_allowed} = UrlValidator.validate("https://[::1]/hook")
  end

  test "IPv6 ULA fc00::1 is rejected (fc00::/7)" do
    assert {:error, :target_url_not_allowed} = UrlValidator.validate("https://[fc00::1]/hook")
  end

  # fe80::/10 is IPv6 link-local (same attack class as 169.254.0.0/16);
  # added to the blocklist per REVIEWER OQ-1 approval.
  test "IPv6 link-local fe80::1 is rejected (fe80::/10, REVIEWER OQ-1)" do
    assert {:error, :target_url_not_allowed} = UrlValidator.validate("https://[fe80::1]/hook")
  end

  test "IPv4-mapped IPv6 ::ffff:10.0.0.1 is rejected" do
    assert {:error, :target_url_not_allowed} =
             UrlValidator.validate("https://[::ffff:10.0.0.1]/hook")
  end

  test "IPv4-mapped IPv6 ::ffff:169.254.169.254 is rejected" do
    assert {:error, :target_url_not_allowed} =
             UrlValidator.validate("https://[::ffff:169.254.169.254]/hook")
  end

  # ---------------------------------------------------------------------------
  # AC3 — legitimate https public IP via injected resolver
  # ---------------------------------------------------------------------------

  test "hostname resolving to public IP via injected resolver is allowed" do
    resolver = fn _host -> {:ok, [{:inet, {93, 184, 216, 34}, []}]} end
    assert :ok = UrlValidator.validate("https://example.com/hook", resolver)
  end

  test "public IP literal (no DNS needed) is allowed" do
    assert :ok = UrlValidator.validate("https://93.184.216.34/hook")
  end

  # ---------------------------------------------------------------------------
  # AC4 — DNS rebinding via injected resolver
  # ---------------------------------------------------------------------------

  # The injected resolver simulates a hostname that resolved to a public IP
  # at subscription-creation time but now resolves to the cloud metadata
  # address at delivery time (DNS rebinding).
  test "hostname resolving to 169.254.169.254 at validation time is rejected (DNS rebinding)" do
    resolver = fn _host -> {:ok, [{:inet, {169, 254, 169, 254}, []}]} end

    assert {:error, :target_url_not_allowed} =
             UrlValidator.validate("https://example.com/hook", resolver)
  end

  test "hostname resolving to loopback 127.0.0.1 via injected resolver is rejected" do
    resolver = fn _host -> {:ok, [{:inet, {127, 0, 0, 1}, []}]} end

    assert {:error, :target_url_not_allowed} =
             UrlValidator.validate("https://example.com/hook", resolver)
  end

  test "hostname resolving to private RFC-1918 via injected resolver is rejected" do
    resolver = fn _host -> {:ok, [{:inet, {10, 0, 0, 1}, []}]} end

    assert {:error, :target_url_not_allowed} =
             UrlValidator.validate("https://example.com/hook", resolver)
  end

  # ---------------------------------------------------------------------------
  # OQ-3 — DNS failure treated as blocked
  # ---------------------------------------------------------------------------

  test "DNS NXDOMAIN is treated as blocked" do
    resolver = fn _host -> {:error, :nxdomain} end

    assert {:error, :target_url_not_allowed} =
             UrlValidator.validate("https://nxdomain.example.com/hook", resolver)
  end

  test "DNS timeout is treated as blocked" do
    resolver = fn _host -> {:error, :timeout} end

    assert {:error, :target_url_not_allowed} =
             UrlValidator.validate("https://timeout.example.com/hook", resolver)
  end

  # ---------------------------------------------------------------------------
  # ISS-0950 -- validate_syntactic/1 (no-DNS variant used for write-time feedback)
  # See test/specs/ISS-0950.md.
  # ---------------------------------------------------------------------------

  describe "validate_syntactic/1" do
    @non_https_or_malformed [
      "http://example.test/x",
      "ftp://example.test/x",
      "example.test/x",
      "not a url",
      "",
      "https://",
      "https:///x"
    ]

    @blocked_ip_literals [
      "https://127.0.0.1/x",
      "https://127.255.255.254/x",
      "https://10.0.0.5/x",
      "https://172.16.0.1/x",
      "https://172.31.255.255/x",
      "https://192.168.1.1/x",
      "https://169.254.0.1/x",
      "https://169.254.169.254/latest/meta-data",
      "https://[::1]/x",
      "https://[fc00::1]/x",
      "https://[fd00::1]/x",
      "https://[fe80::1]/x",
      "https://[::ffff:127.0.0.1]/x",
      "https://[::ffff:10.0.0.1]/x",
      "https://[::ffff:169.254.169.254]/x",
      "https://[::127.0.0.1]/x",
      "https://good.example@127.0.0.1/x"
    ]

    @allowed_urls [
      "https://example.test/x",
      "https://example.test:8443/x",
      "https://203.0.113.10/x",
      "https://172.32.0.1/x",
      "https://172.15.255.255/x",
      "HTTPS://example.test/x"
    ]

    test "U-SCHEME/U-HOSTNIL: non-https, schemeless, empty and host-less URLs are rejected" do
      for url <- @non_https_or_malformed do
        assert {:error, :target_url_not_allowed} = UrlValidator.validate_syntactic(url),
               "expected #{inspect(url)} to be rejected"
      end
    end

    test "U-BLOCKLIST: every blocked IP-literal range is rejected" do
      for url <- @blocked_ip_literals do
        assert {:error, :target_url_not_allowed} = UrlValidator.validate_syntactic(url),
               "expected #{inspect(url)} to be rejected"
      end
    end

    test "U-BLOCKLIST: cloud metadata 169.254.169.254 is rejected by name" do
      assert {:error, :target_url_not_allowed} =
               UrlValidator.validate_syntactic("https://169.254.169.254/latest/meta-data")
    end

    test "hostnames, ports, public IP literals and range-edge-outside addresses are accepted" do
      for url <- @allowed_urls do
        assert :ok = UrlValidator.validate_syntactic(url), "expected #{inspect(url)} accepted"
      end
    end

    test "U-PARITY: for every scheme/IP-literal case, validate_syntactic/1 == validate/1 (blocklist is shared, not copied)" do
      # validate/1 short-circuits on IP literals before any DNS call, so this is
      # safe. Hostname-only URLs are deliberately excluded (that is the one
      # intended difference).
      parity_cases =
        @non_https_or_malformed ++
          @blocked_ip_literals ++
          ["https://203.0.113.10/x", "https://172.32.0.1/x", "https://172.15.255.255/x"]

      for url <- parity_cases do
        assert UrlValidator.validate_syntactic(url) == UrlValidator.validate(url),
               "validate_syntactic/1 and validate/1 disagree for #{inspect(url)}"
      end
    end

    test "U-NODNS (a): a hostname that fails real resolution is accepted syntactically but refused by validate/2" do
      assert :ok = UrlValidator.validate_syntactic("https://example.test/x")

      assert {:error, :target_url_not_allowed} =
               UrlValidator.validate("https://example.test/x", fn _ -> {:error, :nxdomain} end)
    end

    test "localhost is accepted by design (a hostname is never resolved here; the dispatch gate stops it after resolution)" do
      # Documented on purpose (design OQ-2): do not "fix" by special-casing names.
      assert :ok = UrlValidator.validate_syntactic("https://localhost/x")
    end

    test "U-NODNS (b): validate_syntactic/1 never reaches :inet / :inet_res (call trace)" do
      Code.ensure_loaded!(:inet)
      Code.ensure_loaded!(:inet_res)

      # A process cannot receive its own trace messages, so a separate tracer
      # process forwards them to the test process.
      test_pid = self()

      tracer =
        spawn(fn ->
          forward = fn forward ->
            receive do
              msg ->
                send(test_pid, msg)
                forward.(forward)
            end
          end

          forward.(forward)
        end)

      on_exit(fn ->
        Process.exit(tracer, :kill)
        :erlang.trace_pattern({:inet, :getaddrs, 2}, false, [:local])
        :erlang.trace_pattern({:inet, :gethostbyname, 1}, false, [:local])
        :erlang.trace_pattern({:inet, :gethostbyname, 2}, false, [:local])
        :erlang.trace_pattern({:inet_res, :_, :_}, false, [:local])
      end)

      for pattern <- [
            {:inet, :getaddrs, 2},
            {:inet, :gethostbyname, 1},
            {:inet, :gethostbyname, 2},
            {:inet_res, :_, :_}
          ] do
        assert is_integer(:erlang.trace_pattern(pattern, true, [:local]))
      end

      :erlang.trace(self(), true, [:call, {:tracer, tracer}])

      for url <- [
            "https://example.test/x",
            "https://localhost/x",
            "https://internal.corp/x"
          ] do
        assert :ok = UrlValidator.validate_syntactic(url)
      end

      :erlang.trace(self(), false, [:call])

      refute_receive {:trace, _, :call, {:inet, _, _}}, 100
      refute_receive {:trace, _, :call, {:inet_res, _, _}}, 100

      # Sanity: the trace harness works -- the real resolver DOES hit :inet, so
      # the refutes above are not vacuous.
      :erlang.trace(self(), true, [:call, {:tracer, tracer}])
      _ = UrlValidator.default_resolver(~c"localhost")
      :erlang.trace(self(), false, [:call])

      assert_receive {:trace, _, :call, {:inet, :getaddrs, _}}, 1_000
    end

    test "validate/1,2 are unchanged: hostname still goes through the resolver" do
      parent = self()

      resolver = fn host ->
        send(parent, {:resolved, host})
        {:ok, [{:inet, {203, 0, 113, 10}, []}]}
      end

      assert :ok = UrlValidator.validate("https://example.test/x", resolver)
      assert_received {:resolved, ~c"example.test"}

      assert {:error, :target_url_not_allowed} =
               UrlValidator.validate("https://example.test/x", fn _ ->
                 {:ok, [{:inet, {10, 0, 0, 1}, []}]}
               end)
    end
  end
end
