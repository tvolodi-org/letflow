defmodule Letflow.Notifications.AddressTest do
  @moduledoc """
  T-2592 (pilot gap G4): the shape of an e-mail ADDRESS -- the gate the
  notification step puts between a variable of the running instance and the mail
  adapter.

  Test ids A1..A8.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

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
end
