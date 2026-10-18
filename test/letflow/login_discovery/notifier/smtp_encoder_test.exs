defmodule Letflow.LoginDiscovery.Notifier.Smtp.EncoderTest do
  @moduledoc """
  REQ-441 AC9, wire half, and REVIEWER finding 3 (step 02d): `Smtp.Transport` builds the
  RFC 5322 message itself (it does not call `:mimemail`, which logs the `To` header at
  debug), so this small hand-written encoder is tested at the WIRE, against the
  in-process sink, with hostile tenant text.

  Covered: exactly the allow-listed headers (no `Bcc`, no folding, no extra header from
  tenant text), the exact `From`/`To`/`Subject`/`MIME-Version`/`Content-Type` values,
  `Date` and `Message-ID` shape (the `Message-ID` domain and the EHLO identity are the
  SENDER's domain, never the node's), the 7bit versus base64 choice with a non-ASCII
  round trip, no lone-dot line / no dot-stuffing needed, no link other than the
  base-URL links, markup inert, and an invalid recipient making no connection at all.

  `async: false`: application env and the sink.
  """

  use ExUnit.Case, async: false

  alias Letflow.LoginDiscovery.Notifier.Smtp
  alias Letflow.LoginDiscovery.Notifier.Smtp.Message
  alias Letflow.Test.SmtpHelpers, as: S
  alias Letflow.Test.SmtpSink

  @recipient "typed.address@example.org"
  @allowed_headers ~w(Date From To Subject Message-ID MIME-Version Content-Type Content-Transfer-Encoding)

  # Header NAMES that must never appear (anchored to line start, multiline, case-insensitive).
  @forbidden_header_names ~r/^(bcc|reply-to|cc|sender|x-[a-z0-9-]+):/mi

  @hostile_tenants [
    %{slug: "acme", display_name: "Evil\r\nBcc: victim@evil.example\r\n\r\nInjected body"},
    %{slug: "slug\r\nBcc: x@evil.example", display_name: "<script>alert(1)</script>"},
    %{slug: "globex", display_name: "http://evil.example/x javascript:alert(1) www.evil.example"},
    %{slug: "dots", display_name: "\r\n.\r\n"},
    %{slug: ".", display_name: "."},
    %{slug: "initech", display_name: "a@evil.example \u202Ereversed\u202C"}
  ]

  setup do
    sink = S.start_sink!(:accept)
    S.configure_smtp!(sink, [])
    {:ok, sink: sink}
  end

  defp deliver!(sink, tenants) do
    assert Smtp.deliver_tenant_list(@recipient, tenants) == :ok
    assert [%{data: data}] = SmtpSink.messages(sink)
    [header_block, body] = String.split(data, "\r\n\r\n", parts: 2)
    {data, header_block, body}
  end

  defp headers(header_block) do
    for line <- String.split(header_block, "\r\n") do
      [name, value] = String.split(line, ": ", parts: 2)
      {name, value}
    end
  end

  describe "headers" do
    test "exactly the allow-listed headers, once each, no folding, nothing from tenant text",
         %{sink: sink} do
      {_data, header_block, _body} = deliver!(sink, @hostile_tenants)

      # no folded (continuation) line and every line is `Name: value`
      refute header_block =~ ~r/\r\n[ \t]/
      names = header_block |> headers() |> Enum.map(&elem(&1, 0))
      assert Enum.sort(names) == Enum.sort(@allowed_headers)
      assert names == Enum.uniq(names)
      refute header_block =~ @forbidden_header_names
    end

    # The Message-ID local part is random hex, so an unanchored `bcc` (or any other word) can
    # appear inside a legitimate header VALUE. The pattern is anchored to header-name position.
    test "the forbidden-header pattern matches header NAMES only, never a value" do
      legitimate =
        "Date: Sun, 18 Oct 2026 22:17:15 +0000\r\nMessage-ID: <18f46a814db815d884cbcc9a@mail.example.org>\r\nSubject: reply-to x-ray cc: sender: bcc"

      refute legitimate =~ @forbidden_header_names

      for line <- [
            "Bcc: victim@evil.example",
            "Reply-To: a@evil.example",
            "Cc: a@evil.example",
            "Sender: a@evil.example",
            "X-Mailer: evil",
            "x-custom-header: 1"
          ] do
        assert "From: a@b.example\r\n" <> line =~ @forbidden_header_names, line
      end
    end

    test "exact fixed header values", %{sink: sink} do
      {_data, header_block, _body} = deliver!(sink, S.tenants())
      headers = Map.new(headers(header_block))

      assert headers["From"] == S.sender()
      assert headers["To"] == @recipient
      assert headers["Subject"] == Message.subject()
      assert headers["MIME-Version"] == "1.0"
      assert headers["Content-Type"] == "text/plain; charset=UTF-8"
      assert headers["Content-Transfer-Encoding"] == "7bit"
    end

    test "Message-ID is <24 hex>@<sender domain> and unique per message; EHLO is the sender domain",
         %{sink: sink} do
      {_data, header_block, _body} = deliver!(sink, S.tenants())
      id = header_block |> headers() |> Map.new() |> Map.fetch!("Message-ID")

      assert id =~ ~r/\A<[0-9a-f]{24}@mail\.example\.org>\z/
      refute id =~ to_string(node())

      SmtpSink.await_closed(sink)
      assert [%{ehlo: "mail.example.org"}] = SmtpSink.transcripts(sink)

      second = S.start_sink!(:accept)
      S.configure_smtp!(second, [])
      assert Smtp.deliver_tenant_list(@recipient, S.tenants()) == :ok
      [%{data: data2}] = SmtpSink.messages(second)
      [hb2, _] = String.split(data2, "\r\n\r\n", parts: 2)
      refute headers(hb2) |> Map.new() |> Map.fetch!("Message-ID") == id
    end

    test "Date is a well-formed RFC 5322 UTC date: real weekday, valid fields, close to now",
         %{sink: sink} do
      {_data, header_block, _body} = deliver!(sink, S.tenants())
      date = header_block |> headers() |> Map.new() |> Map.fetch!("Date")

      assert [_, wday, day, mon, year, h, m, s] =
               Regex.run(
                 ~r/\A(Mon|Tue|Wed|Thu|Fri|Sat|Sun), (\d{2}) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) (\d{4}) (\d{2}):(\d{2}):(\d{2}) \+0000\z/,
                 date
               )

      month =
        Enum.find_index(~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec), &(&1 == mon)) + 1

      {:ok, parsed_date} = Date.new(String.to_integer(year), month, String.to_integer(day))
      assert Enum.at(~w(Mon Tue Wed Thu Fri Sat Sun), Date.day_of_week(parsed_date) - 1) == wday

      {:ok, parsed} =
        NaiveDateTime.new(
          parsed_date,
          Time.new!(String.to_integer(h), String.to_integer(m), String.to_integer(s))
        )

      # generous: a clock sanity check, not a timing assertion
      assert abs(NaiveDateTime.diff(NaiveDateTime.utc_now(), parsed)) < 3_600
    end
  end

  describe "body encoding" do
    test "an all-ASCII body travels as 7bit and is readable on the wire", %{sink: sink} do
      {_data, header_block, body} = deliver!(sink, S.tenants())
      assert header_block =~ "Content-Transfer-Encoding: 7bit"
      assert body =~ ~s(Organisation: "Acme Corp")
      assert body =~ "\r\nSign in: https://app.example.org/?realm=acme-co\r\n"
      # CRLF line endings throughout, no bare LF
      refute body =~ ~r/(?<!\r)\n/
    end

    test "a non-ASCII body is base64 and round-trips to the composed body exactly", %{sink: sink} do
      tenants = [
        %{slug: "zurich", display_name: "Zürich Gesellschaft 日本語 \u{1F600}"},
        %{slug: "café", display_name: "Café Ångström"}
      ]

      {_data, header_block, body} = deliver!(sink, tenants)
      assert header_block =~ "Content-Transfer-Encoding: base64"
      assert header_block =~ "Content-Type: text/plain; charset=UTF-8"

      encoded_lines = String.split(String.trim_trailing(body, "\r\n"), "\r\n")
      assert Enum.all?(encoded_lines, &(byte_size(&1) <= 76))
      assert Enum.all?(encoded_lines, &Regex.match?(~r/\A[A-Za-z0-9+\/=]+\z/, &1))

      {:ok, composed} =
        Message.compose(@recipient, tenants, %{from: S.sender(), base_url: S.base_url()})

      decoded = encoded_lines |> Enum.join() |> Base.decode64!()
      assert decoded == String.replace(composed.body, "\n", "\r\n")
      assert decoded =~ "Zürich Gesellschaft 日本語 \u{1F600}"
      assert String.valid?(decoded)
    end
  end

  describe "SMTP DATA framing" do
    test "no line is a lone dot or starts with a dot (nothing needs dot-stuffing), one terminator",
         %{sink: sink} do
      {data, _header_block, _body} = deliver!(sink, @hostile_tenants)

      lines = String.split(data, "\r\n")
      refute Enum.any?(lines, &(&1 == "."))
      refute Enum.any?(lines, &String.starts_with?(&1, "."))
      refute data =~ "\r\n.\r\n"

      # the transaction really completed after the hostile content: one message, QUIT sent
      assert [%{rcpts: [@recipient]}] = SmtpSink.messages(sink)
      SmtpSink.await_closed(sink)
      assert [%{commands: ["QUIT" | _]}] = SmtpSink.transcripts(sink)
    end

    test "the hostile payload adds no recipient, no header and no second message", %{sink: sink} do
      {data, header_block, _body} = deliver!(sink, @hostile_tenants)

      SmtpSink.await_closed(sink)
      assert SmtpSink.transcripts(sink) |> Enum.flat_map(& &1.rcpts) == [@recipient]
      assert SmtpSink.connections(sink) == 1

      assert header_block |> headers() |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
               Enum.sort(@allowed_headers)

      refute data =~ ~r/^Bcc:/mi
      refute data =~ ~r/^Subject: pwned/mi
    end
  end

  describe "links and markup" do
    test "the only URLs on the wire are the base-URL links, one per tenant", %{sink: sink} do
      {data, _header_block, _body} = deliver!(sink, @hostile_tenants)

      urls = Regex.scan(~r/[A-Za-z][A-Za-z0-9+.-]*:\/\/\S+/, data) |> Enum.map(&hd/1)
      assert length(urls) == length(@hostile_tenants)
      for url <- urls, do: assert(String.starts_with?(url, "https://app.example.org/?realm="))
    end

    test "markup, javascript: and mail-looking text are plain text in a text/plain message",
         %{sink: sink} do
      {data, header_block, body} = deliver!(sink, @hostile_tenants)

      assert header_block =~ "Content-Type: text/plain; charset=UTF-8"
      refute header_block =~ ~r/multipart|text\/html/i
      assert body =~ "<script>alert(1)</script>"
      assert body =~ "javascript:alert(1)"
      refute data =~ "http://evil.example"
      refute data =~ "@evil.example"
    end
  end

  describe "an invalid recipient never reaches the wire" do
    for {label, recipient} <- [
          crlf: "a@example.org\r\nBcc: x@y.z",
          comma: "a@example.org,b@example.org",
          angle: "<a@example.org>",
          non_ascii: "café@example.org",
          ip_literal: "a@[127.0.0.1]",
          two_at: "a@b@example.org"
        ] do
      test "#{label}: {:error, :invalid_recipient} and ZERO connections", %{sink: sink} do
        assert Smtp.deliver_tenant_list(unquote(recipient), S.tenants()) ==
                 {:error, :invalid_recipient}

        assert SmtpSink.connections(sink) == 0
      end
    end
  end
end
