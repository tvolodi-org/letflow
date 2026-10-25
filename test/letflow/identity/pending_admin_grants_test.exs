defmodule Letflow.Identity.PendingAdminGrantsTest do
  @moduledoc """
  ISS-1030 PR 2 -- `Letflow.Identity.PendingAdminGrants` and the audit split of design
  section 7a: `normalize_email/1`, `create/3`, `list/1`, `revoke/3`, and the
  "who can read what" invariants of the two audit chains.

  Real Postgres, real tenant schemas. The customer tenant's chain is the fixture tenant's own
  schema; the platform chain is a second fixture tenant's schema, pinned as THE platform tenant
  (`Letflow.Support.PendingAdminHelper.world!/1`). `async: false`: the fixture flips the sandbox
  to `:auto`, and the platform pin is VM-global.

  The binding side (`bind_on_login/5`) is in `pending_admin_binding_test.exs`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Identity
  alias Letflow.Identity.PendingAdminGrant
  alias Letflow.Identity.PendingAdminGrants
  alias Letflow.Support.PendingAdminHelper, as: H
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.TenantFixture
  alias Letflow.TenantSlugFixture

  setup do
    %{w: H.world!()}
  end

  defp write_opts(w, extra \\ []) do
    Keyword.merge(
      [
        prefix: w.tenant.schema_name,
        platform_prefix: w.platform.schema_name,
        trace_id: "t-grants",
        onboarding_id: nil
      ],
      extra
    )
  end

  defp ascii_address(total) do
    # 64-character local part, then a domain that brings the total to `total` characters.
    domain_length = total - 64 - 1
    local = String.duplicate("a", 64)
    domain = String.duplicate("d", domain_length - 4) <> ".com"
    local <> "@" <> domain
  end

  # --- normalize_email -------------------------------------------------------

  test "normalize_email trims and lower-cases only: plus tags and dots are preserved" do
    assert {:ok, "ada.admin@example.com"} =
             PendingAdminGrants.normalize_email("Ada.Admin@Example.COM")

    assert {:ok, "ada.admin@example.com"} =
             PendingAdminGrants.normalize_email("  Ada.Admin@Example.com \t")

    # No provider-specific folding: a +tag and the dots are part of the key.
    assert {:ok, "ada+ops@example.com"} =
             PendingAdminGrants.normalize_email("ada+ops@example.com")

    assert {:ok, "a.d.a@example.com"} = PendingAdminGrants.normalize_email("a.d.a@example.com")

    refute PendingAdminGrants.normalize_email("ada+ops@example.com") ==
             PendingAdminGrants.normalize_email("ada@example.com")

    refute PendingAdminGrants.normalize_email("a.d.a@example.com") ==
             PendingAdminGrants.normalize_email("ada@example.com")
  end

  test "normalize_email refuses non-ASCII addresses at creation (an internationalised address must be punycode)" do
    for value <- [
          "adá@example.com",
          "ada@exämple.com",
          # U+212A KELVIN SIGN lower-cases onto an ASCII "k": it must never become a key.
          "Kay@example.com",
          "Ａda@example.com"
        ] do
      assert PendingAdminGrants.normalize_email(value) == :error, inspect(value)
    end

    # The punycode form is the accepted spelling.
    assert {:ok, "ada@xn--exmple-cua.com"} =
             PendingAdminGrants.normalize_email("ada@xn--exmple-cua.com")
  end

  test "normalize_email rejects blank, no @, two @, whitespace and over-long values without echoing them" do
    secret = "zzLEAKzz"

    for value <- [
          "",
          "   ",
          "no-at-sign-#{secret}",
          "two@@example.com#{secret}",
          "a@b@example.com",
          "white space@example.com",
          "tab\t@example.com",
          "nl\n@example.com",
          "ada@example",
          "ada@.example.com",
          "ada@example.com.",
          "@example.com",
          "ada@",
          String.duplicate("a", 65) <> "@example.com",
          42,
          nil,
          ["ada@example.com"],
          %{"email" => "ada@example.com"}
        ] do
      # The result is the bare atom `:error`: no value, tuple or message can carry the input.
      assert PendingAdminGrants.normalize_email(value) == :error, inspect(value)
    end
  end

  test "normalize_email boundary: a 254-character address is accepted and a 255-character address is refused" do
    at_limit = ascii_address(254)
    over = ascii_address(255)

    assert String.length(at_limit) == 254
    assert String.length(over) == 255
    assert {:ok, ^at_limit} = PendingAdminGrants.normalize_email(at_limit)
    assert PendingAdminGrants.normalize_email(over) == :error
  end

  # --- create ----------------------------------------------------------------

  test "create stores the grant, writes the tenant.admin_grant.created entry without any operator id and the platform.tenant_admin_grant.created entry with the operator id, in one transaction",
       %{w: w} do
    onboarding_id = Ecto.UUID.generate()

    assert {:ok, %PendingAdminGrant{} = grant} =
             PendingAdminGrants.create(
               "owner@example.com",
               %{user_id: w.operator_id},
               write_opts(w, onboarding_id: onboarding_id)
             )

    # The row: open, keyed by the normalised address, TENANT_ADMIN, onboarding.
    stored = H.grant(w, grant.id)
    assert stored.email_key == "owner@example.com"
    assert stored.role_name == "TENANT_ADMIN"
    assert stored.created_via == "onboarding"
    assert stored.consumed_at == nil and stored.revoked_at == nil
    assert PendingAdminGrant.state(stored) == :open

    # Tenant chain: NIL actor, no trace id, no operator id, no tenant id of the platform side.
    assert [tenant_entry] = H.entries(w.tenant.schema_name, "tenant.admin_grant.created")
    assert tenant_entry.actor_id == nil
    assert tenant_entry.trace_id == nil
    assert tenant_entry.resource_type == "pending_admin_grant"
    assert tenant_entry.resource_id == grant.id
    assert tenant_entry.before_state == nil

    assert tenant_entry.after_state == %{
             "grant_id" => grant.id,
             "role" => "TENANT_ADMIN",
             "created_via" => "platform_operator_onboarding"
           }

    # Platform chain: the operator, the trace id, the references (and the same grant id).
    assert [platform_entry] =
             H.entries(w.platform.schema_name, "platform.tenant_admin_grant.created")

    assert platform_entry.actor_id == w.operator_id
    assert platform_entry.trace_id == "t-grants"
    assert platform_entry.resource_type == "pending_admin_grant"
    assert platform_entry.resource_id == grant.id
    assert platform_entry.before_state == nil

    assert platform_entry.after_state == %{
             "grant_id" => grant.id,
             "tenant_id" => w.tenant.tenant_id,
             "onboarding_id" => onboarding_id
           }

    # One entry per chain: the single event is exactly one pair, not two writes of either.
    assert length(H.all_entries(w.tenant.schema_name)) == 1
    assert length(H.all_entries(w.platform.schema_name)) == 1
  end

  # G(g): the grant creator is the onboarding handler and nothing else (v1: "creation only by
  # the onboarding call"). A source scan, because a second caller or a second route is exactly
  # what a reviewer cannot see in a diff of unrelated code.
  test "create has exactly one caller: the onboarding handler" do
    lib_files = Path.wildcard("lib/**/*.ex")

    callers =
      for path <- lib_files,
          source = File.read!(path),
          source =~ ~r/PendingAdminGrants\.create\(/ or
            source =~ ~r/PendingAdminGrant\.create_changeset\(/ or
            source =~ ~r/apply\(\s*(Letflow\.Identity\.)?PendingAdminGrants/ or
            source =~ ~r/import\s+(Letflow\.Identity\.)?PendingAdminGrants\b/,
          do: path

    # Definition site: the grants module builds the changeset it inserts; the router calls create/3.
    assert Enum.sort(callers) == [
             "lib/letflow/identity/pending_admin_grants.ex",
             "lib/letflow/routers/onboarding.ex"
           ]

    onboarding = File.read!("lib/letflow/routers/onboarding.ex")
    assert length(Regex.scan(~r/PendingAdminGrants\.create\(/, onboarding)) == 1

    grants_source = File.read!("lib/letflow/identity/pending_admin_grants.ex")
    refute grants_source =~ ~r/PendingAdminGrants\.create\(/, "the context calls its own create/3"

    # No HTTP route creates or changes a grant: the only verbs on the two paths are GET and DELETE.
    for path <- Path.wildcard("lib/letflow/routers/*.ex") do
      refute File.read!(path) =~ ~r/authz_(post|put|patch)\s+"[^"]*pending-admin/,
             "#{path} declares a write route for pending administrator grants"
    end

    refute File.read!("lib/letflow/routers/identity.ex") =~
             ~r/authz_(post|put|patch|delete)\s+"\/pending-admin-grants/
  end

  # PG1 (REQ-572, decision 0072 D5(a)): the second creation path has exactly one caller too.
  test "create_provisioned has exactly one caller: the tenant provisioner" do
    callers =
      for path <- Path.wildcard("lib/**/*.ex"),
          File.read!(path) =~ ~r/PendingAdminGrants\.create_provisioned\(/,
          do: path

    assert callers == ["lib/letflow/tenant_provisioner.ex"]

    provisioner = File.read!("lib/letflow/tenant_provisioner.ex")
    assert length(Regex.scan(~r/PendingAdminGrants\.create_provisioned\(/, provisioner)) == 1

    for path <- Path.wildcard("lib/letflow/routers/**/*.ex") do
      refute File.read!(path) =~ "create_provisioned(", "#{path} calls the provisioned grant path"
    end
  end

  test "an operator-side platform write refuses with 500 and writes nothing when the configured platform prefix differs from the caller's tenant prefix or no platform tenant is configured",
       %{w: w} do
    # The handler (`Letflow.Routers.Onboarding`) computes the platform prefix itself and compares
    # it with the caller's own tenant schema BEFORE any write; the only seam a real request has
    # between the authorization plug and that comparison is a query of the onboarding record, so
    # this goes through the real router on the two operator routes that read it first
    # (list and revoke). The create handler's own comparison runs before its first read and is
    # therefore unreachable except by a race (design 3.2 "Defence in depth", pinned by the 403
    # test of `onboarding_administrator_fields_test.exs`).
    record = H.onboarding_record!(w)
    grant = H.create_grant!(w, "owner@example.com")
    token = Fixture.mint_token!(w.platform, ["PLATFORM_ADMIN"])
    other = TenantFixture.provisioned_tenant!(slug_prefix: "iss1030-gr-other-plat")

    revoke_path = "/api/v1/onboarding/#{record.id}/pending-admins/#{grant.id}"
    list_path = "/api/v1/onboarding/#{record.id}/pending-admins"

    attempts = [
      {{:pin, other.tenant_id}, :delete, revoke_path},
      {:unpin, :delete, revoke_path},
      {{:pin, other.tenant_id}, :get, list_path},
      {:unpin, :get, list_path}
    ]

    for {action, method, path} <- attempts do
      Fixture.pin!(w.platform.tenant_id)

      {conn, log} =
        ExUnit.CaptureLog.with_log(fn ->
          with_pin_change(action, fn ->
            method
            |> Fixture.api_conn(path, token, w.platform.tenant.slug, nil)
            |> Fixture.dispatch_api()
          end)
        end)

      assert conn.status == 500, "#{method} #{path} #{inspect(action)}: #{conn.resp_body}"
      assert Jason.decode!(conn.resp_body)["status"] == 500
      refute conn.resp_body =~ other.tenant_id
      refute conn.resp_body =~ w.platform.tenant_id

      assert log =~
               ~r/\[error\] operator pending-admin (list|revoke) refused: platform prefix check failed/
    end

    # Nothing was written: the grant is still open with its e-mail, and no revoke entry exists.
    stored = H.grant(w, grant.id)
    assert PendingAdminGrant.state(stored) == :open
    assert stored.email_key == "owner@example.com"
    assert H.entries(w.tenant.schema_name, "tenant.admin_grant.revoked") == []
    assert H.entries(w.platform.schema_name, "platform.tenant_admin_grant.revoked") == []
    assert H.entries(other.schema_name, "platform.tenant_admin_grant.revoked") == []
  end

  # Telemetry seam: change the platform pin on the FIRST query that reads `onboarding_registry` in the
  # calling process. The two operator routes read it after the platform-scope gate and before their own
  # prefix comparison. The fixture's `on_exit` restores the original pin.
  defp with_pin_change(action, fun) do
    handler_id = {__MODULE__, make_ref()}
    # One pin change per call: the guard in the handler is per call, not per test.
    Process.delete(:iss1030_pin_changed)

    :telemetry.attach(
      handler_id,
      [:letflow, :repo, :query],
      &__MODULE__.change_pin_on_registry_read/4,
      {self(), action}
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end
  end

  @doc false
  def change_pin_on_registry_read(_event, _measurements, metadata, {test_pid, action}) do
    query = to_string(Map.get(metadata, :query) || "")

    if self() == test_pid and Process.get(:iss1030_pin_changed) != true and
         String.contains?(query, "onboarding_registry") do
      Process.put(:iss1030_pin_changed, true)

      case action do
        {:pin, tenant_id} -> Fixture.pin!(tenant_id)
        :unpin -> Fixture.unpin!()
      end
    end

    :ok
  end

  test "no audit row in the tenant chain or the platform chain contains the e-mail, after create, bind, failed bind and revoke",
       %{w: w} do
    bound_email = "bound.owner@example.com"
    revoked_email = "revoked.owner@example.com"
    failed_email = "failed.owner@example.com"

    _bound = H.create_grant!(w, bound_email)
    revoked = H.create_grant!(w, revoked_email)
    _failed = H.create_grant!(w, failed_email)

    # A successful bind, and a failed one (unverified), then a revoke.
    assert %{result: :bound} = H.login(w, email: bound_email, verified: true)
    assert %{result: :noop} = H.login(w, email: failed_email, verified: false)
    assert :ok = PendingAdminGrants.revoke(revoked.id, %{user_id: w.operator_id}, write_opts(w))

    entries = H.all_entries(w.tenant.schema_name) ++ H.all_entries(w.platform.schema_name)
    assert length(entries) >= 8

    # Every field of every row, encoded: no address, and not even its local part, appears.
    haystack =
      entries
      |> Enum.map(fn entry ->
        entry
        |> Map.from_struct()
        |> Map.delete(:__meta__)
        |> Jason.encode!()
        |> String.downcase()
      end)
      |> Enum.join("\n")

    for email <- [bound_email, revoked_email, failed_email] do
      refute haystack =~ email
      refute haystack =~ hd(String.split(email, "@"))
    end

    refute haystack =~ "@example.com"
  end

  test "no tenant-chain row contains the operator's user id or the platform tenant id, for created, bound, revoked and realm-bound entries",
       %{w: w} do
    bind_email = "bind.owner@example.com"
    revoke_email = "revoke.owner@example.com"
    _bind = H.create_grant!(w, bind_email)
    revoke = H.create_grant!(w, revoke_email)

    assert %{result: :bound} = H.login(w, email: bind_email)
    assert :ok = PendingAdminGrants.revoke(revoke.id, %{user_id: w.operator_id}, write_opts(w))

    # Realm-bound, on a tenant that has no realm yet.
    bare = TenantFixture.provisioned_tenant!(slug_prefix: "iss1030-gr-bare")
    realm = TenantSlugFixture.unique_realm("iss1030gr")

    assert {:ok, _tenant} =
             Identity.bind_tenant_realm(bare.tenant_id, realm,
               actor_id: w.operator_id,
               platform_prefix: w.platform.schema_name,
               trace_id: "t-realm"
             )

    tenant_chains = H.all_entries(w.tenant.schema_name) ++ H.all_entries(bare.schema_name)

    # All four event kinds are present, so each is covered by the scan below.
    actions = Enum.map(tenant_chains, & &1.action)

    for expected <- [
          "tenant.admin_grant.created",
          "tenant.admin_grant.bound",
          "tenant.admin_grant.revoked",
          "tenant.idp_realm.bound"
        ] do
      assert expected in actions, "no #{expected} entry was written"
    end

    forbidden = [w.operator_id, w.platform.tenant_id, w.platform.schema_name, "t-op", "t-realm"]

    for entry <- tenant_chains do
      encoded =
        entry
        |> Map.from_struct()
        |> Map.delete(:__meta__)
        |> Jason.encode!()
        |> String.downcase()

      for value <- forbidden do
        refute encoded =~ String.downcase(value),
               "#{entry.action} carries #{value}: #{encoded}"
      end
    end

    # The platform chain, in contrast, is where the operator is named (the other half of the split).
    platform = H.all_entries(w.platform.schema_name)
    assert Enum.any?(platform, &(&1.actor_id == w.operator_id))
  end

  test "the platform chain entry for a grant names the creating operator and is found by the grant id",
       %{w: w} do
    grant = H.create_grant!(w, "owner@example.com")
    other = H.create_grant!(w, "second.owner@example.com")

    # The tenant side shows only the grant id; the platform chain answers "who onboarded this".
    assert [tenant_entry] =
             Repo.all(
               from(e in Letflow.Audit.Entry,
                 where: e.action == "tenant.admin_grant.created" and e.resource_id == ^grant.id
               ),
               prefix: w.tenant.schema_name
             )

    assert tenant_entry.actor_id == nil

    assert [platform_entry] =
             Repo.all(
               from(e in Letflow.Audit.Entry,
                 where:
                   e.action == "platform.tenant_admin_grant.created" and
                     e.resource_id == ^tenant_entry.resource_id
               ),
               prefix: w.platform.schema_name
             )

    assert platform_entry.actor_id == w.operator_id
    assert platform_entry.after_state["grant_id"] == grant.id

    # The context's own reader of the same fact.
    assert PendingAdminGrants.creators([grant.id, other.id], w.platform.schema_name) ==
             %{grant.id => w.operator_id, other.id => w.operator_id}

    assert PendingAdminGrants.creators([], w.platform.schema_name) == %{}
    assert PendingAdminGrants.creators([Ecto.UUID.generate()], w.platform.schema_name) == %{}
  end

  test "create returns duplicate for the same normalised address", %{w: w} do
    assert {:ok, first} =
             PendingAdminGrants.create(
               "owner@example.com",
               %{user_id: w.operator_id},
               write_opts(w)
             )

    # The caller normalises first, so a differently written address arrives as the same key.
    {:ok, same_key} = PendingAdminGrants.normalize_email("  Owner@Example.COM ")

    assert {:error, :duplicate} =
             PendingAdminGrants.create(same_key, %{user_id: w.operator_id}, write_opts(w))

    # The refused insert rolled back with its audit entries: still exactly one pair.
    assert [%{id: id}] = H.grants(w)
    assert id == first.id
    assert length(H.entries(w.tenant.schema_name, "tenant.admin_grant.created")) == 1
    assert length(H.entries(w.platform.schema_name, "platform.tenant_admin_grant.created")) == 1
  end

  # --- list ------------------------------------------------------------------

  test "list reports age_seconds for open grants and none for bound and revoked ones, oldest first",
       %{w: w} do
    open_old = H.create_grant!(w, "open.old@example.com")
    bound = H.create_grant!(w, "bound@example.com")
    revoked = H.create_grant!(w, "revoked@example.com")
    open_new = H.create_grant!(w, "open.new@example.com")

    assert %{result: :bound} = H.login(w, email: "bound@example.com")
    assert :ok = PendingAdminGrants.revoke(revoked.id, %{user_id: w.operator_id}, write_opts(w))

    # Fixed insertion times and a fixed "now", so the ages are exact and the order is by age.
    times = [
      {open_old.id, ~U[2026-01-01 00:00:00.000000Z]},
      {bound.id, ~U[2026-01-01 06:00:00.000000Z]},
      {revoked.id, ~U[2026-01-01 12:00:00.000000Z]},
      {open_new.id, ~U[2026-01-02 00:00:00.000000Z]}
    ]

    for {id, at} <- times do
      Repo.update_all(from(g in PendingAdminGrant, where: g.id == ^id), [set: [inserted_at: at]],
        prefix: w.tenant.schema_name
      )
    end

    now = ~U[2026-01-03 00:00:00.000000Z]
    rows = PendingAdminGrants.list(prefix: w.tenant.schema_name, now: now)

    assert Enum.map(rows, & &1.grant.id) == [open_old.id, bound.id, revoked.id, open_new.id]
    assert Enum.map(rows, & &1.state) == [:open, :bound, :revoked, :open]
    assert Enum.map(rows, & &1.age_seconds) == [2 * 86_400, nil, nil, 86_400]

    # Scrubbed rows show no e-mail; the open rows still hold theirs.
    assert Enum.map(rows, & &1.grant.email_key) ==
             ["open.old@example.com", nil, nil, "open.new@example.com"]

    # An age is never negative (a clock a little behind the row's own timestamp).
    early = ~U[2025-12-31 00:00:00.000000Z]

    assert [%{age_seconds: 0} | _rest] =
             PendingAdminGrants.list(prefix: w.tenant.schema_name, now: early)
  end

  # --- revoke ----------------------------------------------------------------

  test "revoke audits, scrubs the e-mail and refuses a bound or already revoked grant", %{w: w} do
    open = H.create_grant!(w, "open@example.com")
    bound = H.create_grant!(w, "bound@example.com")
    assert %{result: :bound} = H.login(w, email: "bound@example.com")

    actor = %{user_id: w.operator_id}

    assert :ok = PendingAdminGrants.revoke(open.id, actor, write_opts(w, trace_id: "t-rev"))

    scrubbed = H.grant(w, open.id)
    assert scrubbed.email_key == nil
    assert %DateTime{} = scrubbed.revoked_at
    assert PendingAdminGrant.state(scrubbed) == :revoked

    # Audited in both chains: NIL actor on the tenant side, the operator on the platform side.
    assert [tenant_entry] = H.entries(w.tenant.schema_name, "tenant.admin_grant.revoked")
    assert tenant_entry.actor_id == nil
    assert tenant_entry.resource_id == open.id
    assert tenant_entry.trace_id == nil

    assert tenant_entry.after_state == %{
             "grant_id" => open.id,
             "role" => "TENANT_ADMIN",
             "created_via" => "platform_operator_onboarding"
           }

    assert [platform_entry] =
             H.entries(w.platform.schema_name, "platform.tenant_admin_grant.revoked")

    assert platform_entry.actor_id == w.operator_id
    assert platform_entry.resource_id == open.id
    assert platform_entry.trace_id == "t-rev"

    assert platform_entry.after_state == %{
             "grant_id" => open.id,
             "tenant_id" => w.tenant.tenant_id
           }

    # An already revoked grant, a bound grant and an unknown id are refused and write nothing.
    assert {:error, :not_open} = PendingAdminGrants.revoke(open.id, actor, write_opts(w))
    assert {:error, :not_open} = PendingAdminGrants.revoke(bound.id, actor, write_opts(w))

    assert {:error, :not_found} =
             PendingAdminGrants.revoke(Ecto.UUID.generate(), actor, write_opts(w))

    assert length(H.entries(w.tenant.schema_name, "tenant.admin_grant.revoked")) == 1
    assert length(H.entries(w.platform.schema_name, "platform.tenant_admin_grant.revoked")) == 1

    # The bound grant is untouched by the refused revoke.
    still_bound = H.grant(w, bound.id)
    assert PendingAdminGrant.state(still_bound) == :bound
    assert still_bound.revoked_at == nil
    assert H.member_count(w) == 1
  end
end
