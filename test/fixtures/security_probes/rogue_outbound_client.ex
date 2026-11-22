defmodule Letflow.Security.Fixtures.RogueOutboundClient do
  @moduledoc """
  The seeded failing case of the G-06 outbound probe (NOT compiled, NOT run:
  this file is text under `test/fixtures/`, read by
  `test/letflow/security/outbound_http_inventory_test.exs`).

  It is a deliberately broken outbound channel. It breaks four of the probe's
  rules at once, so the probe cannot pass on an empty or partial scan:

    * it reaches a DIFFERENT HTTP client (`Req.get/1`) than the one the
      product is allowed to use -- an adapter that never passes the shared
      `Letflow.Webhooks.UrlValidator`, so an SSRF check on it is impossible;
    * it asks `:httpc` to FOLLOW a redirect (`autoredirect: true`), so a 3xx
      answered by a validated host would become a request to an unvalidated
      one;
    * its tenant-supplied URL reaches `:httpc.request/4` with no
      `UrlValidator.validate/1,2` on the path at all (rule I5a);
    * and it offers a second, unchecked entry point to the same request
      (rule I5b).

  Every defect here is a defect the probe must catch on the real tree.
  """

  @spec rogue_fetch(String.t()) :: term()
  def rogue_fetch(url) do
    :httpc.request(
      :get,
      {String.to_charlist(url), []},
      [timeout: 5_000, autoredirect: true],
      []
    )
  end

  @spec unchecked_fetch(String.t()) :: term()
  def unchecked_fetch(url) do
    Req.get(url)
  end
end
