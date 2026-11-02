defmodule Letflow.LoginDiscovery.Notifier.Smtp.MessageTest do
  @moduledoc """
  REQ-441 AC9, unit half (spec `test/specs/REQ-441.md`): the PURE fixed-template
  composer. Hostile tenant text (CR/LF with a `Bcc:` and a blank-line body split,
  markup, URLs, `javascript:`, `www.`, `@`, bidi and zero-width controls, over-length,
  invalid UTF-8, empty) must come out as inert text: the subject is the fixed string,
  the composed map has exactly four keys, no line of the body is anything but a fixed
  line or one of the three tenant-line shapes, and the ONLY URLs are the base-URL links
  (one per tenant). The recipient and sender checks are an allow-list.

  `async: true`: no I/O, no env, no sink. The wire-level half (headers, encoding,
  dot-stuffing, EHLO) is `smtp_encoder_test.exs`.
  """

  use ExUnit.Case, async: true
  @moduletag :unit
  use ExUnitProperties

  alias Letflow.LoginDiscovery.Notifier.Smtp.Message

  @base "https://app.example.org"
  @from "noreply@mail.example.org"
  @recipient "a.b+c@example.org"
  @opts %{from: @from, base_url: @base}

  @intro "You asked for the organisations you can sign in to with this email address."
  @outro [
    "If you did not ask for this, you can ignore this message.",
    "Do not forward this message."
  ]
  @overflow "More organisations match this address; contact your administrator."
  @subject "Your Letflow sign-in options"

  @hostile_names [
    "Evil\r\nBcc: victim@evil.example\r\n\r\nInjected body",
    "Evil\nSubject: pwned",
    "<script>alert(1)</script>",
    "&amp; <b>bold</b> <img src=x onerror=alert(1)>",
    "http://evil.example/x",
    "HTTPS://EVIL.EXAMPLE/login",
    "ftp://evil.example",
    "javascript:alert(1)",
    "www.evil.example",
    "see WWW.Evil.example now",
    "a@evil.example",
    "bidi \u202Eevil\u202C \u2066x\u2069 \u200E\u200F",
    "zero\u200Bwidth\u200C\u200D\u2060\uFEFFname",
    "ctrl\u0000\u0001\u001F\u007F\u0085name",
    "say \"hello\" \"world\"",
    "\r\n.\r\n",
    ".",
    "   ",
    "",
    String.duplicate("x", 500),
    String.duplicate("\u00e9", 500)
  ]

  @hostile_slugs [
    "a/b?c=d&e#f",
    "a%0d%0aBcc: x@evil.example",
    "slug\r\nBcc: x@evil.example",
    "a b",
    "../../etc/passwd",
    "caf\u00e9-\u65e5\u672c",
    "http://evil.example",
    "x@evil.example",
    "a..b",
    String.duplicate("s", 200)
  ]

  defp compose!(tenants), do: elem(Message.compose(@recipient, tenants, @opts), 1)

  # The whole contract of s2.3 / AC9 as assertions over one composed message.
  defp assert_invariants(composed, tenant_count) do
    assert composed |> Map.keys() |> Enum.sort() == [:body, :from, :subject, :to]
    assert composed.subject == @subject
    assert composed.from == @from
    assert composed.to == @recipient

    body = composed.body
    refute body =~ "\r"
    refute String.contains?(body, <<0>>)
    assert String.valid?(body)

    # no control character other than the line feed, and no bidi or zero-width character,
    # survives anywhere in the body (tenant text is inert)
    refute Regex.match?(~r/[\x{0000}-\x{0009}\x{000B}-\x{001F}\x{007F}-\x{009F}]/u, body),
           "a control character survived: #{inspect(body)}"

    refute Regex.match?(
             ~r/[\x{202A}-\x{202E}\x{2066}-\x{2069}\x{200B}-\x{200F}\x{2060}\x{FEFF}]/u,
             body
           ),
           "a bidi/zero-width character survived: #{inspect(body)}"

    for line <- String.split(body, "\n") do
      assert fixed_or_tenant_line?(line), "unexpected body line: #{inspect(line)}"
    end

    urls = Regex.scan(~r/[A-Za-z][A-Za-z0-9+.-]*:\/\/\S+/, body) |> Enum.map(&hd/1)
    assert length(urls) == tenant_count, "expected #{tenant_count} links, got #{inspect(urls)}"
    for url <- urls, do: assert(String.starts_with?(url, @base <> "/?realm="))
  end

  defp fixed_or_tenant_line?(line) do
    line in ["", @intro, @overflow | @outro] or
      Regex.match?(~r/\AOrganisation: "[^"\n]*"\z/, line) or
      (String.starts_with?(line, "Sign in: " <> @base <> "/?realm=") and
         Regex.match?(~r/\ASign in: \S+\z/, line)) or
      Regex.match?(~r/\ACode: [^\n]*\z/, line)
  end

  describe "the fixed template" do
    test "subject and body skeleton are fixed strings; exactly the four keys" do
      assert Message.subject() == @subject

      assert {:ok, composed} =
               Message.compose(@recipient, [%{slug: "acme", display_name: "Acme Corp"}], @opts)

      assert composed.body ==
               Enum.join(
                 [
                   @intro,
                   ~s(Organisation: "Acme Corp"\nSign in: #{@base}/?realm=acme\nCode: acme),
                   Enum.join(@outro, "\n")
                 ],
                 "\n\n"
               )

      assert_invariants(composed, 1)
    end

    test "tenants appear in the order given, one blank line between blocks" do
      tenants = for n <- 1..3, do: %{slug: "t#{n}", display_name: "Name #{n}"}
      composed = compose!(tenants)
      positions = for n <- 1..3, do: :binary.match(composed.body, ~s(Organisation: "Name #{n}"))
      assert positions == Enum.sort(positions)
      assert composed.body =~ "Code: t1\n\nOrganisation: \"Name 2\""
      assert_invariants(composed, 3)
    end

    test "at most 50 tenants are listed; the rest become the fixed overflow line" do
      tenants = for n <- 1..60, do: %{slug: "t#{n}", display_name: "Name #{n}"}
      composed = compose!(tenants)

      assert length(Regex.scan(~r/^Organisation: /m, composed.body)) == 50
      assert composed.body =~ @overflow
      refute composed.body =~ ~s(Organisation: "Name 51")
      assert_invariants(composed, 50)
    end

    test "no tenants, or a malformed tenant, is :invalid_message (never a raise)" do
      assert Message.compose(@recipient, [], @opts) == {:error, :invalid_message}
      assert Message.compose(@recipient, [%{slug: "x"}], @opts) == {:error, :invalid_message}
      assert Message.compose(@recipient, [:nope], @opts) == {:error, :invalid_message}

      assert Message.compose(@recipient, [%{slug: 1, display_name: 2}], @opts) ==
               {:error, :invalid_message}
    end

    test "an invalid sender is :invalid_message" do
      tenants = [%{slug: "a", display_name: "A"}]

      assert Message.compose(@recipient, tenants, %{from: "no at sign", base_url: @base}) ==
               {:error, :invalid_message}
    end
  end

  describe "hostile display names are inert (header and link injection)" do
    for {name, index} <- Enum.with_index(@hostile_names) do
      test "display name ##{index} produces only fixed lines and base-URL links" do
        name = unquote(name)

        case Message.compose(@recipient, [%{slug: "acme", display_name: name}], @opts) do
          {:ok, composed} ->
            assert_invariants(composed, 1)
            refute composed.body =~ ~r/^Bcc:/mi

          {:error, reason} ->
            # only an invalid UTF-8 value may be refused
            assert reason == :invalid_message
            refute String.valid?(name)
        end
      end
    end

    test "markup, URLs and addresses survive only as defanged plain text" do
      body =
        compose!([
          %{slug: "a", display_name: "<b>x</b> http://e.example/p a@e.example www.e.example"}
        ]).body

      assert body =~ "<b>x</b>"
      assert body =~ "http[://]e.example/p"
      assert body =~ "a[at]e.example"
      assert body =~ "www[.]e.example"
      refute body =~ "http://e.example"
    end

    test "a CR/LF/Bcc payload collapses onto one quoted line" do
      body = compose!([%{slug: "a", display_name: "Evil\r\nBcc: v@e.example\r\n\r\nX"}]).body
      assert body =~ ~s(Organisation: "Evil Bcc: v[at]e.example X")
    end

    test "an over-long name is TRUNCATED to 80 characters and the message is still composed" do
      body = compose!([%{slug: "a", display_name: String.duplicate("n", 500)}]).body
      assert body =~ ~s(Organisation: "#{String.duplicate("n", 80)}")
      refute body =~ String.duplicate("n", 81)

      multibyte = compose!([%{slug: "a", display_name: String.duplicate("\u00e9", 500)}]).body
      assert multibyte =~ ~s(Organisation: "#{String.duplicate("\u00e9", 80)}")
    end

    test "an empty or whitespace-only name is the fixed text (unnamed)" do
      for name <- ["", "   ", "\r\n", "\u200B"] do
        assert compose!([%{slug: "a", display_name: name}]).body =~ ~s|Organisation: "(unnamed)"|
      end
    end

    test "invalid UTF-8 in a display name or a slug is :invalid_message" do
      assert Message.compose(@recipient, [%{slug: "a", display_name: <<0xFF, 0xFE>>}], @opts) ==
               {:error, :invalid_message}

      assert Message.compose(@recipient, [%{slug: <<0xC3>>, display_name: "A"}], @opts) ==
               {:error, :invalid_message}
    end
  end

  describe "hostile slugs" do
    for {slug, index} <- Enum.with_index(@hostile_slugs) do
      test "slug ##{index}: printed defanged, linked only through the base URL" do
        slug = unquote(slug)

        assert {:ok, composed} =
                 Message.compose(@recipient, [%{slug: slug, display_name: "Acme"}], @opts)

        assert_invariants(composed, 1)
        [link] = Regex.run(~r/^Sign in: (\S+)$/m, composed.body, capture: :all_but_first)
        assert URI.parse(link).host == "app.example.org"
        assert URI.parse(link).scheme == "https"
        assert URI.parse(link).path == "/"
        assert URI.decode_query(URI.parse(link).query) == %{"realm" => slug}
      end
    end

    test "tenant_link/2 percent-encodes every character outside the unreserved set" do
      link = Message.tenant_link(@base, "a/b?c=d&e#f%0d@x y\u00e9")
      assert link == @base <> "/?realm=a%2Fb%3Fc%3Dd%26e%23f%250d%40x+y%C3%A9"
      refute String.slice(link, String.length(@base <> "/?realm=")..-1//1) =~ ~r{[/?&#@ ]}
    end

    test "tenant_link/2 keeps a path-bearing base URL as the prefix" do
      assert Message.tenant_link("https://x.example/app", "s") == "https://x.example/app/?realm=s"
    end
  end

  describe "sanitize_text/2" do
    test "control characters become spaces, whitespace collapses, the result is trimmed" do
      assert Message.sanitize_text("  a\tb\nc\r\nd  ") == {:ok, "a b c d"}
    end

    test "bidi and zero-width characters are removed" do
      assert Message.sanitize_text("a\u202Eb\u200Bc\uFEFFd") == {:ok, "abcd"}
    end

    test "://, www., @ and double quotes are defanged" do
      assert Message.sanitize_text(~s(x://y www.z a@b "q")) == {:ok, "x[://]y www[.]z a[at]b 'q'"}
    end

    test "truncates at a codepoint boundary, never rejects for length" do
      assert {:ok, text} = Message.sanitize_text(String.duplicate("\u00e9", 100), 80)
      assert String.length(text) == 80
      assert String.valid?(text)
    end

    test "non-binary input and invalid UTF-8 are errors, not raises" do
      assert Message.sanitize_text(<<0xFF>>) == {:error, :invalid_message}
      assert Message.sanitize_text(:atom) == {:error, :invalid_message}
      assert Message.sanitize_text(nil) == {:error, :invalid_message}
    end
  end

  describe "recipient and sender allow-list (valid_address?/1, compose/3)" do
    test "plain addresses pass" do
      for address <- [
            "a.b+c@example.org",
            "x@y.co",
            "A-b_c@sub.domain.example.org",
            "u@x-y.example"
          ] do
        assert Message.valid_address?(address), address
        assert {:ok, _} = Message.compose(address, [%{slug: "a", display_name: "A"}], @opts)
      end
    end

    @bad_addresses [
      {"CR", "a@example.org\r"},
      {"LF", "a@example.org\nBcc: x@y.z"},
      {"CRLF header injection", "a@b.c\r\nBcc: x@y.z"},
      {"NUL", "a\u0000@example.org"},
      {"comma", "a@example.org,b@example.org"},
      {"semicolon", "a@example.org;b@example.org"},
      {"angle brackets", "<a@example.org>"},
      {"display name form", "Name <a@example.org>"},
      {"space", "a b@example.org"},
      {"trailing space", "a@example.org "},
      {"percent", "a%b@example.org"},
      {"bang", "a!b@example.org"},
      {"pipe", "a|b@example.org"},
      {"backtick", "a`b@example.org"},
      {"dollar", "a$b@example.org"},
      {"star", "a*b@example.org"},
      {"double quote", "\"a\"@example.org"},
      {"single quote", "a'b@example.org"},
      {"backslash", "a\\b@example.org"},
      {"parentheses", "a(b)@example.org"},
      {"braces", "a{b}@example.org"},
      {"brackets", "a[b]@example.org"},
      {"colon", "a:b@example.org"},
      {"non-ASCII local", "caf\u00e9@example.org"},
      {"non-ASCII domain", "a@caf\u00e9.example"},
      {"two at signs", "a@b@example.org"},
      {"no at sign", "example.org"},
      {"empty local", "@example.org"},
      {"empty domain", "a@"},
      {"IP literal domain", "a@[127.0.0.1]"},
      {"numeric domain", "a@127.0.0.1"},
      {"leading dot local", ".a@example.org"},
      {"trailing dot local", "a.@example.org"},
      {"double dot local", "a..b@example.org"},
      {"leading dot domain", "a@.example.org"},
      {"trailing dot domain", "a@example.org."},
      {"double dot domain", "a@example..org"},
      {"label starts with hyphen", "a@-example.org"},
      {"label ends with hyphen", "a@example-.org"},
      {"no dot in domain", "a@localhost"},
      {"local over 64 bytes", String.duplicate("a", 65) <> "@example.org"},
      {"label over 63 bytes", "a@" <> String.duplicate("b", 64) <> ".org"},
      {"over 254 bytes", String.duplicate("a", 60) <> "@" <> String.duplicate("b.", 120) <> "org"}
    ]

    for {label, address} <- @bad_addresses do
      test "#{label} is :invalid_recipient" do
        address = unquote(address)
        refute Message.valid_address?(address)

        assert Message.compose(address, [%{slug: "a", display_name: "A"}], @opts) ==
                 {:error, :invalid_recipient}
      end
    end

    test "non-binary input is false, not a raise" do
      for term <- [nil, :a, 1, ~c"a@b.c", %{}] do
        refute Message.valid_address?(term)
      end
    end
  end

  # Half arbitrary bytes, half address-shaped text, so both the accept and the reject
  # branch are exercised.
  defp recipient_generator do
    address_shaped =
      gen all(
            local <- string([?a..?z, ?0..?9, ?., ?+, ?-, ?_], min_length: 1, max_length: 20),
            domain <- string([?a..?z, ?0..?9, ?-], min_length: 1, max_length: 20)
          ) do
        local <> "@" <> domain <> ".org"
      end

    one_of([binary(max_length: 80), address_shaped])
  end

  describe "property: compose/3 never raises and its output always satisfies the invariants" do
    test "property: arbitrary binaries as display name and slug" do
      check all(name <- binary(max_length: 300), slug <- binary(max_length: 100), max_runs: 300) do
        case Message.compose(@recipient, [%{slug: slug, display_name: name}], @opts) do
          {:ok, composed} -> assert_invariants(composed, 1)
          {:error, reason} -> assert reason in [:invalid_message, :invalid_recipient]
        end
      end
    end

    test "property: arbitrary printable strings (mostly valid UTF-8) always compose" do
      check all(
              name <- string(:printable, max_length: 300),
              slug <- string(:printable, max_length: 100),
              max_runs: 300
            ) do
        assert {:ok, composed} =
                 Message.compose(@recipient, [%{slug: slug, display_name: name}], @opts)

        assert_invariants(composed, 1)
      end
    end

    test "property: arbitrary binaries as recipient never raise and only valid addresses compose" do
      check all(recipient <- recipient_generator(), max_runs: 300) do
        result = Message.compose(recipient, [%{slug: "a", display_name: "A"}], @opts)

        if Message.valid_address?(recipient) do
          assert {:ok, %{to: ^recipient}} = result
          refute String.contains?(recipient, ["\r", "\n", <<0>>, " ", ",", "<", ">"])
        else
          assert result == {:error, :invalid_recipient}
        end
      end
    end
  end
end
