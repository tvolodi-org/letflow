defmodule Letflow.Release.PlatformAdminTokenRunbookTest do
  @moduledoc """
  GH 2579 (T14): the operator runbook `docs/runbooks/platform-admin-token-reissue.md` names the
  two release wrappers, the audit events and keys the act writes, and the `DELETE` path for a
  failure, and it never tells an operator to revoke or re-mint in bulk. Spec: `test/specs/GH-2579.md`.
  """

  use ExUnit.Case, async: true

  @path "docs/runbooks/platform-admin-token-reissue.md"

  test "T14: the runbook names the wrappers, the events, the cause, the file and the DELETE path" do
    assert File.exists?(@path)
    doc = File.read!(@path)

    assert doc =~ "Letflow.Release.platform_admin_token_inventory()"
    assert doc =~ "Letflow.Release.reissue_platform_admin_token("
    assert doc =~ "token.revoke"
    assert doc =~ "token.create"
    assert doc =~ "cause"
    assert doc =~ "plaintext_file"
    assert doc =~ "DELETE /identity/tokens/"
    assert String.downcase(doc) =~ "no automatic mass revoke"
  end

  test "T14: the runbook has no bulk or looping instruction" do
    doc = String.downcase(File.read!(@path))

    refute doc =~ "all tokens"
    refute doc =~ "every token"
    refute doc =~ "in a loop"
    refute doc =~ "for each token id"
  end
end
