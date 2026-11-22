defmodule Letflow.Notifications.Address do
  @moduledoc """
  The shape of an e-mail ADDRESS (T-2592, pilot gap G4 -- the notification step of
  the "Register a tenant" pilot).

  The notification step reads the address from a VARIABLE of the running instance,
  so the value is not a fixed string of the code: it is whatever a person typed
  into the start form of the process. This module is the gate that decides
  whether such a value may be handed to the mail adapter.

  ## The byte bound comes first

  The address is bounded in BYTES before any per-character work: a value over
  254 bytes (the RFC's limit is in octets) is refused without being scanned,
  validated or split. The check order is the point: `String.length/1`, a split
  and a regex all walk the value, and the value may be long.

  ## What is refused

    * not a binary, empty, or over 254 bytes;
    * not valid UTF-8;
    * anything with a space, a control character or a tab in it;
    * anything but EXACTLY one `@`;
    * a local part over 64 bytes, empty, or with a leading, a trailing or a
      doubled dot;
    * a domain over 255 bytes, empty, without a dot, or with an empty label, a
      leading or a trailing dot, or a label that starts or ends with a hyphen.

  Pure and total: it never raises, never queries and never logs the value it
  was given (INV-4 -- the address is personal data and the module says nothing
  about it).
  """

  # The RFC 5321 limit is 254 octets for the whole address.
  @max_address_bytes 254
  @max_local_bytes 64
  @max_domain_bytes 255

  @doc """
  Whether `address` may be handed to the mail adapter.

  `false` for anything that is not a plain `local@domain` address. The value is
  never logged, never echoed and never stored.
  """
  @spec valid?(term()) :: boolean()
  def valid?(address) when is_binary(address) do
    # SF-01: the byte bound comes BEFORE any per-character work.
    byte_size(address) <= @max_address_bytes and
      String.valid?(address) and
      no_forbidden_characters?(address) and
      parts_ok?(address)
  end

  def valid?(_address), do: false

  @doc """
  The byte cap of an address, for the caller's own error message.
  """
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_address_bytes

  # A space, a control character or a tab: an address with one of them is not an
  # address a mail server accepts, and a control character is the classic
  # header-injection carrier.
  defp no_forbidden_characters?(address) do
    not String.contains?(address, [" ", "\t"]) and
      not String.match?(address, ~r/[\x00-\x1F\x7F]/u)
  end

  defp parts_ok?(address) do
    case String.split(address, "@") do
      [local, domain] -> local_ok?(local) and domain_ok?(domain)
      _other -> false
    end
  end

  defp local_ok?(local) do
    byte_size(local) > 0 and byte_size(local) <= @max_local_bytes and
      not String.starts_with?(local, ".") and
      not String.ends_with?(local, ".") and
      not String.contains?(local, "..")
  end

  defp domain_ok?(domain) do
    byte_size(domain) > 0 and byte_size(domain) <= @max_domain_bytes and
      String.contains?(domain, ".") and
      Enum.all?(String.split(domain, "."), &label_ok?/1)
  end

  defp label_ok?(label) do
    label != "" and
      not String.starts_with?(label, "-") and
      not String.ends_with?(label, "-") and
      not String.contains?(label, "--")
  end
end
