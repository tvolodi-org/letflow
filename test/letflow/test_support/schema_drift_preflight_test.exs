defmodule Letflow.Test.SchemaDriftPreflightTest do
  use Letflow.DataCase, async: false

  alias Letflow.Repo
  alias Letflow.Test.SchemaDriftPreflight

  test "healthy test DB: no drift" do
    assert SchemaDriftPreflight.drift(Repo) == []
    assert :ok = SchemaDriftPreflight.check!(Repo)
  end

  test "a renamed column is reported with the reset instruction" do
    Repo.query!("ALTER TABLE tenant_login_directory RENAME COLUMN key_id TO key_id_drift")

    assert [{Letflow.Identity.TenantLoginDirectoryEntry, "tenant_login_directory", ["key_id"]}] =
             SchemaDriftPreflight.drift(Repo)

    error = assert_raise RuntimeError, fn -> SchemaDriftPreflight.check!(Repo) end
    assert error.message =~ "(public.tenant_login_directory): missing columns key_id"
    assert error.message =~ "mix ecto.reset"
  end
end
