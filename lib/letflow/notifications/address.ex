defmodule Letflow.Notifications.Address do
  @moduledoc """
  The shape of an e-mail ADDRESS (T-2592, pilot gap G4 -- the notification step of
  the "Register a tenant" pilot).

  The notification step reads the address from a VARIABLE of the running instance,
  so the value is not a fixed string of the code: it is whatever a person typed
  into the start form of the process. This module is the gate that decides
  whether such a value may be handed to the mail adapter.

  ## ONE parse, shared with the consumer

  The gate is the ADAPTER's own allow-list
  (`Letflow.LoginDiscovery.Notifier.Smtp.Message.valid_address?/1` -- the check
  that already guards `LETFLOW_MAIL_FROM` and the recipient of every mail the
  platform sends). A guard and the consumer it protects must share one parse: a
  second copy of the rules is a second opinion, and the two drift (a second
  parser once refused every punycode label and accepted shapes the adapter
  refuses). So this module adds the two checks the adapter cannot make for
  itself -- the byte bound and the UTF-8 check -- and then asks the adapter.

  ## The byte bound comes first

  The address is bounded in BYTES before any per-character work: a value over
  254 bytes (the RFC's limit is in octets) is refused without being scanned,
  validated or split. The check order is the point: `String.length/1`, a split
  and a regex all walk the value, and the value may be long. The UTF-8 check
  comes before the adapter's parse for the same reason: its regular expression
  raises on a binary that is not valid UTF-8, and this module never raises.

  ## What is refused

  Everything the adapter's allow-list refuses:

    * not a binary, empty, or over 254 bytes;
    * not valid UTF-8;
    * anything but EXACTLY one `@`;
    * a local part over 64 bytes, empty, or with a leading, a trailing or a
      doubled dot, or with a character outside `[A-Za-z0-9._+-]`;
    * a domain without a dot, with an empty label, with a label that starts or
      ends with a hyphen, with a label over 63 bytes, or whose last label is all
      digits (an IP literal).

  Pure and total: it never raises, never queries and never logs the value it
  was given (INV-4 -- the address is personal data and the module says nothing
  about it).
  """

  alias Letflow.LoginDiscovery.Notifier.Smtp.Message

  # The RFC 5321 limit is 254 octets for the whole address -- the same bound the
  # adapter's allow-list applies.
  @max_address_bytes 254

  @doc """
  Whether `address` may be handed to the mail adapter.

  `false` for anything that is not a plain `local@domain` address. The value is
  never logged, never echoed and never stored.
  """
  @spec valid?(term()) :: boolean()
  def valid?(address) when is_binary(address) do
    # SF-01: the byte bound comes BEFORE any per-character work, and the UTF-8
    # check comes before the adapter's parse (its regex raises on invalid UTF-8).
    byte_size(address) <= @max_address_bytes and
      String.valid?(address) and
      Message.valid_address?(address)
  end

  def valid?(_address), do: false

  @doc """
  The byte cap of an address, for the caller's own error message.
  """
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_address_bytes
end
