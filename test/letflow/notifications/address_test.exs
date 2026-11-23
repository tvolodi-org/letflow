defmodule Letflow.Notifications.AddressTest do
  @moduledoc """
  T-2592 (pilot gap G4): the shape of an e-mail ADDRESS -- the gate the
  notification step puts between a variable of the running instance and the mail
  adapter.

  The gate is the ADAPTER's own allow-list (`Letflow.LoginDiscovery.Notifier.Smtp.Message`),
  so A9 proves that the two can never disagree: a guard and the consumer it
  protects must share one parse, not hold two opinions about the same value.

  Test ids A1..A9.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  alias Letflow.LoginDiscovery.Notifier.Smtp.Message
  alias Letflow.Notifications.Address

  test "A1 a plain address is valid" do
    assert Address.valid?("admin@example.com")
    assert Address.valid?("first.last+tag@sub.example.co.uk")
  end

  test "A2 an address over the byte cap is refused (the bound comes first)" do
    # 254 bytes is the cap; 255 is one over. The long part is the DOMAIN (the
    # local part has its own, tighter cap).
    at_cap = "admin@" <> String.duplicate("a.", 123) <> "aa"
    assert byte_size(at_cap) == 254
    assert Address.valid?(at_cap)

    over_cap = "admin@" <> String.duplicate("a.", 124) <> "a"
    assert byte_size(over_cap) == 255
    refute Address.valid?(over_cap)
  end

  test "A2b a local part over 64 bytes is refused" do
    refute Address.valid?(String.duplicate("a", 65) <> "@example.com")
    assert Address.valid?(String.duplicate("a", 64) <> "@example.com")
  end

  test "A3 a value that is not a binary is refused" do
    refute Address.valid?(nil)
    refute Address.valid?(123)
    refute Address.valid?(%{})
    refute Address.valid?(["admin@example.com"])
  end

  test "A4 an empty address is refused" do
    refute Address.valid?("")
  end

  test "A5 an address with the wrong number of @ is refused" do
    refute Address.valid?("admin@@example.com")
    refute Address.valid?("admin@example.com@other.com")
    refute Address.valid?("admin.example.com")
  end

  test "A6 an address with a space or a control character is refused" do
    refute Address.valid?("admin @example.com")
    refute Address.valid?("admin@exa mple.com")
    refute Address.valid?("admin@example.com\nBcc: someone@example.com")
    refute Address.valid?("admin@example.com\r")
  end

  test "A7 a domain without a dot, or with an empty label, is refused" do
    refute Address.valid?("admin@example")
    refute Address.valid?("admin@.example.com")
    refute Address.valid?("admin@example..com")
    refute Address.valid?("admin@example.com.")
  end

  test "A8 an address that is not valid UTF-8 is refused" do
    refute Address.valid?(<<97, 255, 64, 101, 120, 97, 109, 112, 108, 101, 46, 99, 111, 109>>)
  end

  test "A9 the gate and the adapter's allow-list agree on every case (one parse, shared)" do
    # The shapes the two parsers used to disagree on: the old second copy of the
    # rules accepted an IP literal, an underscore and a non-ASCII domain, and
    # refused every punycode label. The gate is now the adapter's own
    # allow-list, so the two cannot disagree at all.
    cases = [
      {"admin@example.com", true},
      {"first.last+tag@sub.example.co.uk", true},
      {"admin@xn--bcher-kva.example", true},
      {"admin@example", false},
      {"admin@192.0.2.1", false},
      {"admin@ex_ample.com", false},
      {"admin@bücher.example", false},
      {"admin@@example.com", false},
      {"admin@example.com\nBcc: someone@example.com", false},
      {"admin @example.com", false},
      {"", false}
    ]

    for {address, expected} <- cases do
      assert Address.valid?(address) == expected,
             "the gate disagrees on #{inspect(address)}"

      assert Message.valid_address?(address) == expected,
             "the adapter disagrees on #{inspect(address)}"
    end
  end
end
