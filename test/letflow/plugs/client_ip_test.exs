defmodule Letflow.Plugs.ClientIpTest do
  @moduledoc """
  REQ-439 (REQ-CIP): tests for `Letflow.Plugs.ClientIp`. Design:
  `lib/letflow/design/req439-trusted-proxy-client-ip.md`; spec: `test/specs/REQ-439.md`.

  Pure and deterministic: no clock, no randomness, no network, no database.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  import Plug.Conn
  import Plug.Test

  alias Letflow.Plugs.ClientIp

  @trusted_v4 {{10, 0, 0, 0}, 8}
  @peer_v4 {10, 0, 0, 7}
  @outsider {203, 0, 113, 9}

  defp cidrs!(string) do
    {:ok, list} = ClientIp.parse_cidrs(string)
    list
  end

  # --- parse_cidrs/1 --------------------------------------------------------

  describe "parse_cidrs/1 accepts" do
    for {input, expected} <- [
          {"", []},
          {"   ", []},
          {" , ,", []},
          {"10.0.0.0/8", [{{10, 0, 0, 0}, 8}]},
          {"10.0.0.1", [{{10, 0, 0, 1}, 32}]},
          {"0.0.0.0/0", [{{0, 0, 0, 0}, 0}]},
          {"1.2.3.4/32", [{{1, 2, 3, 4}, 32}]},
          {"::1", [{{0, 0, 0, 0, 0, 0, 0, 1}, 128}]},
          {"::/0", [{{0, 0, 0, 0, 0, 0, 0, 0}, 0}]},
          {"2001:db8::/32", [{{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 32}]},
          {"2001:db8::1/128", [{{0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}, 128}]},
          # host bits set in the base are accepted (masked at match time)
          {"10.0.0.5/8", [{{10, 0, 0, 5}, 8}]},
          # spaces around segments are trimmed, order is preserved
          {" 10.0.0.0/8 , 2001:db8::/32 ,192.168.0.1",
           [{{10, 0, 0, 0}, 8}, {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 32}, {{192, 168, 0, 1}, 32}]},
          # mapped base with prefix >= 96 is stored as the v4 cidr
          {"::ffff:10.0.0.0/104", [{{10, 0, 0, 0}, 8}]},
          {"::ffff:0:0/96", [{{0, 0, 0, 0}, 0}]},
          # mapped base with prefix < 96 stays v6
          {"::ffff:10.0.0.0/64", [{{0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0}, 64}]}
        ] do
      test "#{inspect(input)}" do
        assert ClientIp.parse_cidrs(unquote(input)) == {:ok, unquote(Macro.escape(expected))}
      end
    end
  end

  describe "parse_cidrs/1 rejects with bare {:error, :invalid_cidr}" do
    for input <- [
          "10.0.0.0/8/8",
          "/8",
          "10.0.0.0/",
          "10.0.0.0/33",
          "::/129",
          "fe80::1%eth0",
          "10.0.0.0/+8",
          "10.0.0.0/-1",
          "10.0.0.0/ 8",
          "10.0.0.0/8x",
          "10.0.0.0/0008",
          "10.0.0.0/٣",
          "256.0.0.1",
          "1.2.3",
          "example.com",
          "localhost",
          "[::1]",
          "10.0.0.1:80",
          "10.0.0.1 10.0.0.2",
          "garbage",
          # one bad segment fails the whole list, no partial result
          "10.0.0.0/8,bogus",
          "bogus,10.0.0.0/8",
          "10.0.0.0/8,,10.0.0.0/33",
          # non-printable / non-ASCII bytes
          "10.0.0.1\n",
          "10.0.0.\u00001",
          "10.0.0.1 ",
          "10.0.0.1/8\r"
        ] do
      test "#{inspect(input)}" do
        assert ClientIp.parse_cidrs(unquote(input)) == {:error, :invalid_cidr}
      end
    end

    test "a non-UTF-8 env value returns the error and does not raise" do
      assert ClientIp.parse_cidrs(<<0xFF>>) == {:error, :invalid_cidr}
      assert ClientIp.parse_cidrs("10.0.0.0/8," <> <<0xFF, 0xFE>>) == {:error, :invalid_cidr}
    end

    test "the error term carries no entry or value" do
      assert ClientIp.parse_cidrs("secret-entry-xyz") == {:error, :invalid_cidr}
    end
  end

  # --- trusted?/2 -----------------------------------------------------------

  describe "trusted?/2 table" do
    for {label, ip, cidr_string, expected} <- [
          {"empty list", {10, 0, 0, 1}, "", false},
          {"v4 /8 first", {10, 0, 0, 0}, "10.0.0.0/8", true},
          {"v4 /8 last", {10, 255, 255, 255}, "10.0.0.0/8", true},
          {"v4 /8 just below", {9, 255, 255, 255}, "10.0.0.0/8", false},
          {"v4 /8 just above", {11, 0, 0, 0}, "10.0.0.0/8", false},
          {"v4 /9 inside", {10, 127, 255, 255}, "10.0.0.0/9", true},
          {"v4 /9 just past", {10, 128, 0, 0}, "10.0.0.0/9", false},
          {"v4 /0 matches any v4", {203, 0, 113, 9}, "0.0.0.0/0", true},
          {"v4 /0 does not match v6", {0, 0, 0, 0, 0, 0, 0, 1}, "0.0.0.0/0", false},
          {"v4 /32 exact", {1, 2, 3, 4}, "1.2.3.4/32", true},
          {"v4 /32 neighbour", {1, 2, 3, 5}, "1.2.3.4/32", false},
          {"v4 bare address is /32", {1, 2, 3, 4}, "1.2.3.4", true},
          {"v4 bare address neighbour", {1, 2, 3, 3}, "1.2.3.4", false},
          {"host bits set in base are masked", {10, 9, 9, 9}, "10.0.0.5/8", true},
          {"v6 /32 first", {0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, "2001:db8::/32", true},
          {"v6 /32 last", {0x2001, 0xDB8, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF},
           "2001:db8::/32", true},
          {"v6 /32 just below", {0x2001, 0xDB7, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF},
           "2001:db8::/32", false},
          {"v6 /32 just above", {0x2001, 0xDB9, 0, 0, 0, 0, 0, 0}, "2001:db8::/32", false},
          {"v6 /33 boundary inside", {0x2001, 0xDB8, 0x7FFF, 0, 0, 0, 0, 0}, "2001:db8::/33",
           true},
          {"v6 /33 boundary outside", {0x2001, 0xDB8, 0x8000, 0, 0, 0, 0, 0}, "2001:db8::/33",
           false},
          {"v6 /0 matches any v6", {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}, "::/0", true},
          {"v6 /0 does not match v4", {1, 2, 3, 4}, "::/0", false},
          {"v6 /128 exact", {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}, "2001:db8::1/128", true},
          {"v6 /128 neighbour", {0x2001, 0xDB8, 0, 0, 0, 0, 0, 2}, "2001:db8::1/128", false},
          {"v6 bare address is /128", {0, 0, 0, 0, 0, 0, 0, 1}, "::1", true},
          {"v6 bare address neighbour", {0, 0, 0, 0, 0, 0, 0, 2}, "::1", false},
          {"v4 cidr does not match a v6 peer", {0x0A00, 0, 0, 0, 0, 0, 0, 1}, "10.0.0.0/8",
           false},
          {"v6 cidr does not match a v4 peer", {10, 0, 0, 1}, "2001:db8::/32", false},
          # IPv4-mapped IPv6 peers are matched as IPv4
          {"mapped peer matches v4 /8", {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0007}, "10.0.0.0/8",
           true},
          {"mapped peer outside v4 /8", {0, 0, 0, 0, 0, 0xFFFF, 0x0B00, 0x0007}, "10.0.0.0/8",
           false},
          {"mapped peer matches v4 /32", {0, 0, 0, 0, 0, 0xFFFF, 0x0102, 0x0304}, "1.2.3.4",
           true},
          {"mapped peer does not match an unrelated v6 cidr",
           {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0007}, "2001:db8::/32", false},
          {"mapped peer is matched by a mapped cidr /104",
           {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0007}, "::ffff:10.0.0.0/104", true},
          {"v4 peer is matched by a mapped cidr /104", {10, 1, 2, 3}, "::ffff:10.0.0.0/104",
           true},
          {"mapped cidr with prefix < 96 never matches a normalised mapped peer",
           {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0007}, "::ffff:10.0.0.0/64", false},
          # any entry of the list may match
          {"second entry matches", {192, 168, 1, 1}, "10.0.0.0/8,192.168.0.0/16", true},
          {"no entry matches", {172, 16, 0, 1}, "10.0.0.0/8,192.168.0.0/16", false}
        ] do
      test label do
        ip = unquote(Macro.escape(ip))
        assert ClientIp.trusted?(ip, cidrs!(unquote(cidr_string))) == unquote(expected)
      end
    end
  end

  # --- resolve/3 ------------------------------------------------------------

  describe "resolve/3 trusted peer, single header value" do
    for {label, value, expected} <- [
          {"ipv4", "198.51.100.23", {198, 51, 100, 23}},
          {"ipv6", "2001:db8::17", {0x2001, 0xDB8, 0, 0, 0, 0, 0, 0x17}},
          {"surrounding spaces and tabs are trimmed", " \t198.51.100.23\t ", {198, 51, 100, 23}},
          # parse_strict_address accepts a mapped address and returns the 8-tuple unnormalised
          {"mapped ipv6 is returned unnormalised", "::ffff:1.2.3.4",
           {0, 0, 0, 0, 0, 0xFFFF, 0x0102, 0x0304}}
        ] do
      test label do
        assert ClientIp.resolve(@peer_v4, [unquote(value)], [@trusted_v4]) ==
                 unquote(Macro.escape(expected))
      end
    end

    test "trusted ipv6 peer with ipv4 header" do
      peer = {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}

      assert ClientIp.resolve(peer, ["198.51.100.23"], cidrs!("2001:db8::/32")) ==
               {198, 51, 100, 23}
    end

    test "mapped trusted peer honours the header" do
      peer = {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0007}
      assert ClientIp.resolve(peer, ["198.51.100.23"], [@trusted_v4]) == {198, 51, 100, 23}
    end

    test "/0 trusts everyone of that family" do
      assert ClientIp.resolve(@outsider, ["198.51.100.23"], cidrs!("0.0.0.0/0")) ==
               {198, 51, 100, 23}
    end
  end

  describe "resolve/3 falls back to the peer (the same term) when" do
    for {label, values} <- [
          {"zero values", []},
          {"two values", ["198.51.100.23", "198.51.100.24"]},
          {"two identical values", ["198.51.100.23", "198.51.100.23"]},
          {"comma list in one value", ["198.51.100.23, 198.51.100.24"]},
          {"comma without space", ["198.51.100.23,198.51.100.24"]},
          {"trailing comma", ["198.51.100.23,"]},
          {"empty value", [""]},
          {"blank value", ["   "]},
          {"garbage", ["not-an-ip"]},
          {"hostname", ["example.com"]},
          {"octet out of range", ["1.2.3.256"]},
          {"too few octets", ["1.2"]},
          {"leading-zero octet (pinned OTP behaviour)", ["010.0.0.1"]},
          {"hex octet", ["0x7f.0.0.1"]},
          {"bracketed ipv6", ["[::1]"]},
          {"with a cidr prefix", ["1.2.3.4/8"]},
          {"with a port", ["1.2.3.4:80"]},
          {"ipv6 zone id", ["fe80::1%eth0"]},
          {"embedded space", ["1.2.3.4 5.6.7.8"]},
          {"trailing newline", ["1.2.3.4\n"]},
          {"embedded NUL", ["1.2.3.4\u0000"]},
          {"non-ASCII unicode", ["1.2.3.4 "]},
          {"non-UTF-8 byte alone", [<<0xFF>>]},
          {"non-UTF-8 byte inside an address", ["1.2.3." <> <<0xFF>>]},
          {"a non-binary list element", [~c"1.2.3.4"]}
        ] do
      test label do
        assert ClientIp.resolve(@peer_v4, unquote(Macro.escape(values)), [@trusted_v4]) ==
                 @peer_v4
      end
    end

    test "two values where both are valid still yields the peer, even for an ipv6 peer" do
      peer = {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
      assert ClientIp.resolve(peer, ["1.2.3.4", "5.6.7.8"], cidrs!("2001:db8::/32")) == peer
    end
  end

  describe "resolve/3 ignores the header entirely when the peer is not trusted" do
    test "empty trust list" do
      assert ClientIp.resolve(@peer_v4, ["198.51.100.23"], []) == @peer_v4
      assert ClientIp.resolve(@peer_v4, [], []) == @peer_v4
    end

    test "peer outside the list" do
      assert ClientIp.resolve(@outsider, ["198.51.100.23"], [@trusted_v4]) == @outsider
    end

    test "a v6 peer outside a v4-only list" do
      peer = {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
      assert ClientIp.resolve(peer, ["198.51.100.23"], [@trusted_v4]) == peer
    end

    test "returns the original mapped peer term, not a normalised one" do
      peer = {0, 0, 0, 0, 0, 0xFFFF, 0x0B00, 0x0007}
      assert ClientIp.resolve(peer, ["198.51.100.23"], [@trusted_v4]) == peer
    end
  end

  # --- boot helpers ---------------------------------------------------------

  describe "parse_enabled/2" do
    test "nil and blank give the default" do
      for default <- [true, false] do
        assert ClientIp.parse_enabled(nil, default) == {:ok, default}
        assert ClientIp.parse_enabled("", default) == {:ok, default}
        assert ClientIp.parse_enabled("  ", default) == {:ok, default}
      end
    end

    test "exactly true and false parse, regardless of the default" do
      for default <- [true, false] do
        assert ClientIp.parse_enabled("true", default) == {:ok, true}
        assert ClientIp.parse_enabled("false", default) == {:ok, false}
      end
    end

    test "anything else is the bare error" do
      for v <- ["TRUE", "False", "yes", "no", "1", "0", "on", "truee", "tru", <<0xFF>>] do
        assert ClientIp.parse_enabled(v, true) == {:error, :invalid_boolean}
        assert ClientIp.parse_enabled(v, false) == {:error, :invalid_boolean}
      end
    end
  end

  describe "boot_check/3 decision table" do
    test "disabled is always :ok whatever the env or list" do
      for env <- [:prod, :dev, :test], list <- [[], [@trusted_v4], cidrs!("0.0.0.0/0")] do
        assert ClientIp.boot_check(env, false, list) == :ok
      end
    end

    test "prod, enabled, empty list is refused" do
      assert ClientIp.boot_check(:prod, true, []) == {:error, :prod_requires_trusted_proxies}
    end

    test "dev and test, enabled, empty list only warn" do
      assert ClientIp.boot_check(:dev, true, []) == :warn
      assert ClientIp.boot_check(:test, true, []) == :warn
    end

    test "enabled with a non-empty list boots in every env" do
      for env <- [:prod, :dev, :test] do
        assert ClientIp.boot_check(env, true, [@trusted_v4]) == :ok
      end
    end

    test "a /0 entry warns in every env (v4, v6, and a normalised mapped /96)" do
      for env <- [:prod, :dev, :test],
          string <- ["0.0.0.0/0", "::/0", "::ffff:0:0/96", "10.0.0.0/8,0.0.0.0/0"] do
        assert ClientIp.boot_check(env, true, cidrs!(string)) == :warn_zero_prefix
      end
    end
  end

  # --- plug: call/2 ---------------------------------------------------------

  defp build_conn(peer, headers) do
    conn = %{conn(:get, "/") | remote_ip: peer}
    Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
  end

  defp run(conn, trusted), do: ClientIp.call(conn, ClientIp.init(trusted_proxies: trusted))

  describe "call/2" do
    test "init/1 is a pass-through" do
      assert ClientIp.init(foo: :bar) == [foo: :bar]
      assert ClientIp.init([]) == []
    end

    test "assigns client_ip, never halts, never rewrites remote_ip" do
      conn = run(build_conn(@peer_v4, [{"x-real-ip", "198.51.100.23"}]), [@trusted_v4])
      assert conn.assigns.client_ip == {198, 51, 100, 23}
      assert conn.remote_ip == @peer_v4
      refute conn.halted
    end

    test "empty trust list: client_ip equals remote_ip whatever the headers say" do
      conn =
        build_conn(@peer_v4, [{"x-real-ip", "198.51.100.23"}, {"x-forwarded-for", "9.9.9.9"}])

      conn = run(conn, [])
      assert conn.assigns.client_ip == @peer_v4
      assert conn.remote_ip == @peer_v4
    end

    test "peer outside the list sending X-Real-IP is ignored" do
      conn = run(build_conn(@outsider, [{"x-real-ip", "198.51.100.23"}]), [@trusted_v4])
      assert conn.assigns.client_ip == @outsider
    end

    test "trusted peer, valid single ipv6 X-Real-IP" do
      conn = run(build_conn(@peer_v4, [{"x-real-ip", "2001:db8::17"}]), [@trusted_v4])
      assert conn.assigns.client_ip == {0x2001, 0xDB8, 0, 0, 0, 0, 0, 0x17}
    end

    test "trusted peer, no X-Real-IP -> remote_ip" do
      assert run(build_conn(@peer_v4, []), [@trusted_v4]).assigns.client_ip == @peer_v4
    end

    test "trusted peer, two X-Real-IP header lines (req_headers set directly) -> remote_ip" do
      # Plug.Test.put_req_header/3 overwrites, so build the duplicate lines by hand.
      conn = build_conn(@peer_v4, [])

      conn = %{
        conn
        | req_headers: [{"x-real-ip", "1.1.1.1"}, {"x-real-ip", "2.2.2.2"} | conn.req_headers]
      }

      assert length(get_req_header(conn, "x-real-ip")) == 2
      result = run(conn, [@trusted_v4])
      assert result.assigns.client_ip == @peer_v4
    end

    test "trusted peer, comma list -> remote_ip" do
      conn = run(build_conn(@peer_v4, [{"x-real-ip", "1.1.1.1, 2.2.2.2"}]), [@trusted_v4])
      assert conn.assigns.client_ip == @peer_v4
    end

    test "trusted peer, unparsable value -> remote_ip" do
      conn = run(build_conn(@peer_v4, [{"x-real-ip", "nope"}]), [@trusted_v4])
      assert conn.assigns.client_ip == @peer_v4
    end

    test "trusted peer, non-UTF-8 header value -> remote_ip and no exception" do
      conn = run(build_conn(@peer_v4, [{"x-real-ip", <<0xFF, 0xFE>>}]), [@trusted_v4])
      assert conn.assigns.client_ip == @peer_v4
    end
  end

  describe "X-Forwarded-For and Forwarded never change the result" do
    @peers [@peer_v4, @outsider, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}]
    @trust_lists [[], [@trusted_v4], [{{0, 0, 0, 0}, 0}]]
    @real_ip_cases [
      :absent,
      "198.51.100.23",
      "2001:db8::17",
      "1.1.1.1, 2.2.2.2",
      "garbage",
      "",
      :two_lines
    ]
    @xff_cases [
      :absent,
      "9.9.9.9",
      "2001:db8::99",
      "9.9.9.9, 8.8.8.8",
      "garbage",
      "198.51.100.23"
    ]

    defp conn_with(peer, real_ip, xff, forwarded) do
      conn = build_conn(peer, [])

      real_headers =
        case real_ip do
          :absent -> []
          :two_lines -> [{"x-real-ip", "1.1.1.1"}, {"x-real-ip", "2.2.2.2"}]
          value -> [{"x-real-ip", value}]
        end

      xff_headers = if xff == :absent, do: [], else: [{"x-forwarded-for", xff}]
      fwd_headers = if forwarded, do: [{"forwarded", "for=7.7.7.7"}], else: []
      %{conn | req_headers: real_headers ++ xff_headers ++ fwd_headers ++ conn.req_headers}
    end

    test "cross-product of peers, trust lists, X-Real-IP shapes and XFF shapes" do
      combos =
        for peer <- @peers,
            trust <- @trust_lists,
            real_ip <- @real_ip_cases,
            xff <- @xff_cases,
            forwarded <- [false, true],
            do: {peer, trust, real_ip, xff, forwarded}

      assert length(combos) == 3 * 3 * 7 * 6 * 2

      for {peer, trust, real_ip, xff, forwarded} <- combos do
        baseline = run(conn_with(peer, real_ip, :absent, false), trust)
        with_xff = run(conn_with(peer, real_ip, xff, forwarded), trust)

        assert with_xff.assigns.client_ip == baseline.assigns.client_ip,
               "XFF changed result for #{inspect({peer, trust, real_ip, xff, forwarded})}"

        assert with_xff.remote_ip == peer
      end
    end

    test "XFF alone, from a trusted peer, is never honoured" do
      conn = run(build_conn(@peer_v4, [{"x-forwarded-for", "198.51.100.23"}]), [@trusted_v4])
      assert conn.assigns.client_ip == @peer_v4
    end

    test "X-Real-IP wins over a different XFF value from a trusted peer" do
      conn =
        build_conn(@peer_v4, [{"x-real-ip", "198.51.100.23"}, {"x-forwarded-for", "9.9.9.9"}])

      assert run(conn, [@trusted_v4]).assigns.client_ip == {198, 51, 100, 23}
    end
  end

  describe "the plug reads no request body" do
    defmodule RaisingAdapter do
      @moduledoc false
      def read_req_body(_state, _opts), do: raise("request body must not be read")
      def get_peer_data(_state), do: %{address: {10, 0, 0, 7}, port: 1, ssl_cert: nil}
    end

    test "a conn whose adapter raises on body read still resolves" do
      conn = build_conn(@peer_v4, [{"x-real-ip", "198.51.100.23"}])
      conn = %{conn | adapter: {RaisingAdapter, :unused}}

      # Sanity: the adapter really does raise if the body is read.
      assert_raise RuntimeError, "request body must not be read", fn -> read_body(conn) end

      assert run(conn, [@trusted_v4]).assigns.client_ip == {198, 51, 100, 23}
      assert run(conn, []).assigns.client_ip == @peer_v4
    end
  end

  # --- stub pipeline --------------------------------------------------------

  defmodule TrustingRouter do
    @moduledoc false
    use Plug.Router
    plug(Letflow.Plugs.ClientIp, trusted_proxies: [{{10, 0, 0, 0}, 8}])
    plug(:match)
    plug(:dispatch)

    get "/probe" do
      send_resp(conn, 200, inspect(conn.assigns.client_ip))
    end
  end

  defmodule EmptyListRouter do
    @moduledoc false
    use Plug.Router
    plug(Letflow.Plugs.ClientIp, trusted_proxies: [])
    plug(:match)
    plug(:dispatch)

    get "/probe" do
      send_resp(conn, 200, inspect(conn.assigns.client_ip))
    end
  end

  describe "stub Plug.Router pipeline" do
    defp probe(router, peer, real_ip) do
      conn = %{conn(:get, "/probe") | remote_ip: peer}
      conn = if real_ip, do: put_req_header(conn, "x-real-ip", real_ip), else: conn
      conn = router.call(conn, router.init([]))
      assert conn.status == 200
      conn.resp_body
    end

    test "two X-Real-IP values behind one trusted peer give two distinct client_ip values" do
      a = probe(TrustingRouter, @peer_v4, "198.51.100.1")
      b = probe(TrustingRouter, @peer_v4, "198.51.100.2")
      assert a == "{198, 51, 100, 1}"
      assert b == "{198, 51, 100, 2}"
      assert a != b
    end

    test "with an empty trust list a spoofed X-Real-IP changes nothing" do
      a = probe(EmptyListRouter, @peer_v4, "198.51.100.1")
      b = probe(EmptyListRouter, @peer_v4, "198.51.100.2")
      none = probe(EmptyListRouter, @peer_v4, nil)
      assert a == b
      assert a == none
      assert a == inspect(@peer_v4)
    end

    test "an untrusted peer behind the trusting router is also not spoofable" do
      assert probe(TrustingRouter, @outsider, "198.51.100.1") == inspect(@outsider)
    end
  end
end
