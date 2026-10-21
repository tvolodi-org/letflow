defmodule Letflow.Documents.BootPreconditionTest do
  @moduledoc """
  REQ-500 / GH #2588, PR A, test A-17: the application refuses to start below PostgreSQL 15
  (`server_version_num` 150000), because the document numbering index is NULLS NOT DISTINCT.

  The floor is a pure function, so 140000 (refuse), 150000 and 160000 (accept) are injected
  directly. The live check is `Letflow.Documents.BootCheck.verify/1` against the running
  test server, through the test's own sandboxed connection. The boot child is off under test
  (config :letflow, :document_boot_check, false); `verify/1` is the code path it runs at boot.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Documents.BootCheck
  alias Letflow.Documents.Preconditions

  test "A-17: an injected 140000 is refused" do
    assert Preconditions.check_server_version_num(140_000) ==
             {:error, {:postgres_too_old, 140_000}}

    assert BootCheck.verify(fn -> 140_000 end) == {:error, {:postgres_too_old, 140_000}}
  end

  test "A-17: an injected 150000 (the floor itself) and 160000 are accepted" do
    assert Preconditions.check_server_version_num(150_000) == :ok
    assert Preconditions.check_server_version_num(160_000) == :ok

    assert BootCheck.verify(fn -> 150_000 end) == :ok
    assert BootCheck.verify(fn -> 160_000 end) == :ok
  end

  test "A-17: the floor is 150000" do
    assert Preconditions.min_server_version_num() == 150_000
  end

  test "A-17: the live test server satisfies the floor" do
    assert BootCheck.verify(&BootCheck.server_version_num/0) == :ok
  end
end
