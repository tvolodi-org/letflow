defmodule Letflow.SecurityAdvisoriesTest do
  @moduledoc """
  T-2645: the dependency advisory register (`docs/security-advisories.md`) and the
  patched plug release it records.

  Three structural facts that no behavioural test can prove: the lock file pins plug at
  the patched release of EEF-CVE-2026-120287, the register records the advisory with its
  status, and the register states the exposure of every route that accepts a multipart
  body together with what bounds it.

  Pure file reads: `async: true`.
  """

  use ExUnit.Case, async: true
  @moduletag :unit

  @advisory "EEF-CVE-2026-120287"
  @patched_plug "1.20.4"
  @register "docs/security-advisories.md"

  # The routes that accept a multipart body. Keep in step with the register: a new
  # upload route must be named there with its bounds.
  @multipart_routes [
    "/api/v1/instances/:id/attachments",
    "/api/v1/entities/records/:entity_type/:record_id/attachments",
    "/api/v1/modules/maintenance/requests/:id/photos",
    "/api/v1/modules/assets/cards/:id/photos",
    "/api/v1/modules/stock/voice/draft",
    "/api/v1/documents/official-form-templates",
    "/api/v1/platform-problem-reports/:id/comments",
    "/qoimeks/:tenant_slug/api/voice"
  ]

  test "mix.lock pins plug at the patched release of the advisory" do
    lock = File.read!("mix.lock")

    assert [_, version] = Regex.run(~r/"plug": \{:hex, :plug, "([^"]+)"/, lock)
    assert Version.compare(version, @patched_plug) in [:eq, :gt]
  end

  test "the register records the advisory, its status and the patched release" do
    register = File.read!(@register)

    assert register =~ @advisory
    assert register =~ "fixed-in-version"
    assert register =~ @patched_plug
  end

  test "the register states the exposure of every route that accepts a multipart body" do
    register = File.read!(@register)

    for route <- @multipart_routes, do: assert(register =~ route)

    # The parser limits and the statement that the reverse proxy's configuration is
    # not in this repository.
    assert register =~ "26_214_400"
    assert register =~ "10_485_760"
    assert register =~ "not in this repository"
  end
end
