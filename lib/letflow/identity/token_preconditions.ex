defmodule Letflow.Identity.TokenPreconditions do
  @moduledoc """
  The flip-precondition token listing (REQ-497 PR 1b, 0051 M2 (d), N2; design
  `lib/letflow/design/req497-1b-allowed-flag-shadow-n1.md` section 7.1).

  Read-only. Only tokens whose effective status (`Letflow.Identity.token_effective_status/3`)
  is `:active` or `:owner_inactive` are considered: revoked and expired tokens can never
  authenticate again, while an inactive owner's token comes back on reactivation. Three
  categories, a token may be in several:

    * `roles_exceed_owner` (BLOCKS the off -> shadow flip): the token's roles are not a
      subset of the owner's tenant-wide role names (`Identity.tenant_wide_role_names/2`,
      called once per distinct owner);
    * `non_expiring_platform_admin` (information): `PLATFORM_ADMIN` with no expiry;
    * `null_issuer` (information): minted by the trusted path, no issuer recorded.

  Each list keeps `Identity.list_tokens/1`'s order (newest first).
  """

  alias Letflow.Identity
  alias Letflow.Identity.ApiToken

  @type item :: %{token: ApiToken.t(), status: :active | :owner_inactive}
  @type findings :: %{
          roles_exceed_owner: [item()],
          non_expiring_platform_admin: [item()],
          null_issuer: [item()]
        }

  @doc "The three categories for the tenant schema `prefix` (see the moduledoc)."
  @spec findings(prefix :: String.t()) :: findings()
  def findings(prefix) when is_binary(prefix) do
    {:ok, rows} = Identity.list_tokens(prefix: prefix)
    now = DateTime.utc_now()

    items =
      for %{token: token, owner_active: owner_active} <- rows,
          status = Identity.token_effective_status(token, owner_active, now),
          status in [:active, :owner_inactive],
          do: %{token: token, status: status}

    owner_roles =
      items
      |> Enum.map(& &1.token.user_id)
      |> Enum.uniq()
      |> Map.new(&{&1, Identity.tenant_wide_role_names(&1, prefix: prefix)})

    %{
      roles_exceed_owner:
        Enum.reject(items, fn %{token: t} ->
          MapSet.subset?(MapSet.new(t.roles || []), Map.fetch!(owner_roles, t.user_id))
        end),
      non_expiring_platform_admin:
        Enum.filter(items, fn %{token: t} ->
          "PLATFORM_ADMIN" in (t.roles || []) and is_nil(t.expires_at)
        end),
      null_issuer: Enum.filter(items, fn %{token: t} -> is_nil(t.issuer_user_id) end)
    }
  end

  @doc """
  The number of tokens whose roles exceed their owner's tenant-wide roles: the off ->
  shadow flip precondition. Writes no audit entry (it discloses nothing).
  """
  @spec exceeding_owner_count(prefix :: String.t()) :: non_neg_integer()
  def exceeding_owner_count(prefix) when is_binary(prefix),
    do: length(findings(prefix).roles_exceed_owner)
end
