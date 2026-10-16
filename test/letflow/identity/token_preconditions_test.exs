defmodule Letflow.Identity.TokenPreconditionsTest do
  @moduledoc """
  REQ-497 PR 1b / GH #2533, AC14 (decision 0051 M2 (d), N2): `Letflow.Identity.TokenPreconditions`
  -- the flip-precondition token categories behind `GET /tenant/scope-enforcement/token-preconditions`
  and the off -> shadow precondition (design `lib/letflow/design/req497-1b-allowed-flag-shadow-n1.md`
  section 7.1; spec `test/specs/REQ-497-1b.md`, T-L1 function level).

  Tokens are inserted RAW (the stored state a mint would leave, with the issuer set explicitly),
  so each category is driven by exactly the column it reads. Owners hold roles through the real
  binding groups (`TokenMintFixture.role_holder!/2`, which also writes the tenant-wide group row).

  `async: false`: dedicated provisioned tenants (sandbox `:auto`) and a VM-global platform pin.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Identity.ApiToken
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.TokenPreconditions
  alias Letflow.Support.PlatformTenantFixture, as: Fixture
  alias Letflow.Support.RoleScopeGrantsFixture, as: RSG
  alias Letflow.Support.TokenMintFixture
  alias Letflow.TenantFixture

  setup do
    Fixture.unpin!()
    :ok
  end

  # --- helpers ---------------------------------------------------------------------------------

  defp tenant!(slug_prefix), do: TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)

  defp seconds_from_now(seconds),
    do: DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)

  # A raw token row. `fields` may set issuer_user_id, expires_at, revoked_at.
  defp token!(schema, owner_id, roles, fields) do
    n = System.unique_integer([:positive])
    plaintext = "lf_tok_" <> Base.encode16(:crypto.hash(:sha256, "req497-tp-#{n}"), case: :lower)

    Repo.insert!(
      struct(
        ApiToken,
        Map.merge(
          %{
            user_id: owner_id,
            name: "req497-tp-#{n}",
            token_hash: Base.encode16(:crypto.hash(:sha256, plaintext), case: :lower),
            roles: roles,
            issuer_user_id: owner_id,
            expires_at: nil,
            revoked_at: nil
          },
          fields
        )
      ),
      prefix: schema
    )
  end

  defp ids(items), do: items |> Enum.map(& &1.token.id) |> Enum.sort()

  defp drop_membership!(schema, user_id) do
    {_n, _} =
      Repo.delete_all(from(m in GroupMember, where: m.user_id == ^user_id), prefix: schema)

    :ok
  end

  # --- T-L1 (function level) -------------------------------------------------------------------

  test "T-L1 a clean tenant has no findings and a zero exceeding count" do
    %{schema_name: s} = tenant!("req497-tp-clean")
    owner = TokenMintFixture.role_holder!(s, ["PROCESS_DESIGNER"])
    _compliant = token!(s, owner.id, ["PROCESS_DESIGNER"], %{expires_at: seconds_from_now(3_600)})

    assert TokenPreconditions.findings(s) == %{
             roles_exceed_owner: [],
             non_expiring_platform_admin: [],
             null_issuer: []
           }

    assert TokenPreconditions.exceeding_owner_count(s) == 0
  end

  test "T-L1 roles_exceed_owner: a token whose owner lost the role's group is found; revoked and expired variants are not" do
    %{schema_name: s} = tenant!("req497-tp-exceed")
    owner = TokenMintFixture.role_holder!(s, ["PROCESS_DESIGNER"])
    compliant_owner = TokenMintFixture.role_holder!(s, ["PROCESS_DESIGNER"])

    exceeding = token!(s, owner.id, ["PROCESS_DESIGNER"], %{})
    _revoked = token!(s, owner.id, ["PROCESS_DESIGNER"], %{revoked_at: seconds_from_now(-60)})
    _expired = token!(s, owner.id, ["PROCESS_DESIGNER"], %{expires_at: seconds_from_now(-60)})
    compliant = token!(s, compliant_owner.id, ["PROCESS_DESIGNER"], %{})

    # Control: before the membership is removed nothing exceeds.
    assert TokenPreconditions.exceeding_owner_count(s) == 0

    :ok = drop_membership!(s, owner.id)

    findings = TokenPreconditions.findings(s)
    assert ids(findings.roles_exceed_owner) == [exceeding.id]
    refute compliant.id in ids(findings.roles_exceed_owner)
    assert findings.non_expiring_platform_admin == []
    assert findings.null_issuer == []
    assert [%{status: :active}] = findings.roles_exceed_owner
    assert TokenPreconditions.exceeding_owner_count(s) == 1
  end

  test "T-L1 roles_exceed_owner: a role held only through a scoped row exceeds (exclude_scoped_role_names/3)" do
    %{schema_name: s} = tenant!("req497-tp-scoped")
    owner = TokenMintFixture.role_holder!(s, ["PROCESS_DESIGNER"])
    token = token!(s, owner.id, ["PROCESS_DESIGNER"], %{})

    assert TokenPreconditions.exceeding_owner_count(s) == 0

    _node =
      RSG.make_group_scoped_only!(s, RSG.group_of!(s, "PROCESS_DESIGNER"), "PROCESS_DESIGNER")

    assert ids(TokenPreconditions.findings(s).roles_exceed_owner) == [token.id]
  end

  test "T-L1 null_issuer: an issuer-less token is listed for information only; an inactive owner's token shows owner_inactive" do
    %{schema_name: s} = tenant!("req497-tp-null")
    owner = TokenMintFixture.role_holder!(s, ["PROCESS_DESIGNER"])
    inactive = TokenMintFixture.role_holder!(s, ["PROCESS_DESIGNER"], status: :inactive)

    null_issuer = token!(s, owner.id, ["PROCESS_DESIGNER"], %{issuer_user_id: nil})
    inactive_null = token!(s, inactive.id, ["PROCESS_DESIGNER"], %{issuer_user_id: nil})

    _revoked_null =
      token!(s, owner.id, ["PROCESS_DESIGNER"], %{
        issuer_user_id: nil,
        revoked_at: seconds_from_now(-60)
      })

    findings = TokenPreconditions.findings(s)
    assert ids(findings.null_issuer) == Enum.sort([null_issuer.id, inactive_null.id])
    assert findings.roles_exceed_owner == []
    assert TokenPreconditions.exceeding_owner_count(s) == 0

    statuses = Map.new(findings.null_issuer, &{&1.token.id, &1.status})
    assert statuses[null_issuer.id] == :active
    assert statuses[inactive_null.id] == :owner_inactive
  end

  test "T-L1 non_expiring_platform_admin (platform tenant): listed for information; a token may be in several categories" do
    p = tenant!("req497-tp-plat")
    :ok = Fixture.pin!(p.tenant_id)
    s = p.schema_name

    pa = TokenMintFixture.role_holder!(s, ["PLATFORM_ADMIN"])
    non_pa_owner = TokenMintFixture.role_holder!(s, ["PROCESS_DESIGNER"])

    non_expiring = token!(s, pa.id, ["PLATFORM_ADMIN"], %{})
    _expiring = token!(s, pa.id, ["PLATFORM_ADMIN"], %{expires_at: seconds_from_now(3_600)})
    # The owner does not hold PLATFORM_ADMIN: exceeds AND non-expiring PA AND null issuer.
    multi = token!(s, non_pa_owner.id, ["PLATFORM_ADMIN"], %{issuer_user_id: nil})

    findings = TokenPreconditions.findings(s)
    assert ids(findings.non_expiring_platform_admin) == Enum.sort([non_expiring.id, multi.id])
    assert ids(findings.roles_exceed_owner) == [multi.id]
    assert ids(findings.null_issuer) == [multi.id]
    assert TokenPreconditions.exceeding_owner_count(s) == 1
  end
end
